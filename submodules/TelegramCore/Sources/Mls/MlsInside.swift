import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi

/// A location or a contact, carried inside the ciphertext (#267).
///
/// The server used to be handed both as they were: a point or a place with its
/// coordinates, a contact with its number and card. In a chat that encrypts the
/// message goes as a text instead, its words empty, and what it carries travels
/// in the same ciphertext as mls.geo or mls.contact; the phone that opens it
/// draws the location or the contact again from there. A live location is not
/// carried: it is a stream of edits nothing here encrypts, and it stays off.
extension MlsRuntime {
    /// A contact's card longer than this, in bytes, is left out and the name and
    /// the number go alone: the server keeps a message's text in 6000
    /// characters, and a card can hold a photograph.
    static let vCardLimit = 2000

    /// What a message's own location or contact becomes inside the ciphertext,
    /// or nothing when it carries neither.
    static func inside(of message: Message) -> Api.mls.Content.Inside? {
        for media in message.media {
            if let map = media as? TelegramMediaMap, map.liveBroadcastingTimeout == nil {
                return .geo(Api.mls.Content.Geo(
                    latitude: map.latitude,
                    longitude: map.longitude,
                    accuracyRadius: map.accuracyRadius.map { Int32(clamping: Int($0)) } ?? 0,
                    title: map.venue?.title ?? "",
                    address: map.venue?.address ?? "",
                    provider: map.venue?.provider ?? "",
                    venueId: map.venue?.id ?? "",
                    venueType: map.venue?.type ?? ""))
            }
            if let contact = media as? TelegramMediaContact {
                let vCard = contact.vCardData ?? ""
                return .contact(Api.mls.Content.Contact(
                    phoneNumber: contact.phoneNumber,
                    firstName: contact.firstName,
                    lastName: contact.lastName,
                    vCard: vCard.utf8.count > MlsRuntime.vCardLimit ? "" : vCard,
                    userId: contact.peerId?.id._internalGetInt64Value() ?? 0))
            }
        }
        return nil
    }
}

/// What a location or a contact goes up as in a chat that encrypts: a text,
/// filled in with the ciphertext on its way out, the location or the contact
/// riding inside it. Nothing for anything else, a live location among them.
func mlsCarriedInside(media: Media, text: String) -> Signal<PendingMessageUploadedContentResult, PendingMessageUploadError>? {
    if let map = media as? TelegramMediaMap, map.liveBroadcastingTimeout == nil {
        Logger.shared.log("Mls", "a location goes inside the ciphertext")
    } else if media is TelegramMediaContact {
        Logger.shared.log("Mls", "a contact goes inside the ciphertext")
    } else {
        return nil
    }
    return .single(.content(PendingMessageUploadedContentAndReuploadInfo(content: .text(text), reuploadInfo: nil, cacheReferenceKey: nil)))
}

extension MlsMessageContent {
    /// The location or the contact that came inside, drawn again; nothing when
    /// none did.
    var carriedMedia: Media? {
        switch self.inside {
        case let .geo(geo):
            let venue: MapVenue? = geo.title.isEmpty ? nil : MapVenue(
                title: geo.title,
                address: geo.address.isEmpty ? nil : geo.address,
                provider: geo.provider.isEmpty ? nil : geo.provider,
                id: geo.venueId.isEmpty ? nil : geo.venueId,
                type: geo.venueType.isEmpty ? nil : geo.venueType)
            return TelegramMediaMap(latitude: geo.latitude, longitude: geo.longitude, heading: nil, accuracyRadius: geo.accuracyRadius > 0 ? Double(geo.accuracyRadius) : nil, venue: venue)
        case let .contact(contact):
            let peerId: PeerId? = contact.userId == 0 ? nil : PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(contact.userId))
            return TelegramMediaContact(firstName: contact.firstName, lastName: contact.lastName, phoneNumber: contact.phoneNumber, peerId: peerId, vCardData: contact.vCard.isEmpty ? nil : contact.vCard)
        case .none:
            return nil
        }
    }

    /// What a message read back holds: the location or the contact that came
    /// inside in place of what the server sent beside it - nothing, for the
    /// text it travels as - and otherwise what it had.
    func withInside(_ media: [Media]) -> [Media] {
        if let carried = self.carriedMedia {
            return [carried]
        }
        return media
    }
}
