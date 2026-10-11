import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi

// What arrives from the server, read the way an encrypted conversation needs.
// StoreMessage_Telegram, ApplyUpdateMessage, AccountStateManagementUtils and
// RequestEditMessage, upstream's files, call these and keep only the call
// (#196).

extension MlsMessageContent {
    /// Read back if this is one of ours and this device is in the
    /// conversation; nil when the text is not a ciphertext at all.
    ///
    /// A message can be ours and still unreadable here - it usually means it
    /// overtook the welcome that lets this device into the conversation, which
    /// happens because the two travel by different routes. Then the ciphertext
    /// is put aside and the text becomes something a person can understand,
    /// rather than `mls1:AAEAAh...` in their chat, their chat list and their
    /// search. `MlsRuntime` goes looking for the welcome and reads the message
    /// back once it has it.
    ///
    /// The formatting is not applied here: see `appliedEntities`.
    static func incoming(_ text: String, peerId: PeerId, date: Int32, attributes: inout [MessageAttribute]) -> MlsMessageContent? {
        guard MlsRuntime.isCiphertext(text) else {
            return nil
        }
        if let content = MlsRuntime.decryptIncoming(peerId: peerId, text: text, at: date) {
            return content
        }
        attributes.append(MlsCiphertextMessageAttribute(ciphertext: text))
        return MlsMessageContent(text: MlsCiphertextMessageAttribute.placeholder, entities: [])
    }

    /// What arrived is a document holding bytes the server cannot read. What it
    /// really is - a picture, a video, a voice message - and the key to it came
    /// inside the message, so the two are put back together here.
    func realMedia(_ medias: [Media]) -> [Media] {
        guard let descriptor = self.media, let real = mlsIncomingMedia(from: medias, descriptor: descriptor) else {
            return medias
        }
        return real
    }

    /// The formatting, applied in the one place it is decided: an empty
    /// attribute is added further on for a message that has no entities, and
    /// that empty one used to land on top of formatting restored earlier, so an
    /// encrypted message arrived in plain type while its entities sat in the
    /// ciphertext, correct and unused. Whatever came in the clear beside a
    /// ciphertext is not the formatting of this message: the formatting
    /// travelled inside it, with the text it indexes into.
    ///
    /// And so did who wrote it first. A forward into an encrypted conversation
    /// travels as a new message - the server cannot copy one somebody here
    /// could read - so without this it would arrive looking like the sender's
    /// own words.
    func appliedEntities(to attributes: inout [MessageAttribute], forwardInfo: inout StoreMessageForwardInfo?) -> TextEntitiesMessageAttribute {
        let attribute = TextEntitiesMessageAttribute(entities: self.entities)
        attributes.append(attribute)
        if forwardInfo == nil {
            forwardInfo = self.storeForwardInfo
        }
        return attribute
    }
}

/// What a sent message keeps when the server confirms it by echoing it back.
///
/// What it echoes is what travelled: for an encrypted message, ciphertext this
/// device cannot read. MLS application messages are not readable by the person
/// who wrote them - measured, see `the_sender_cannot_read_their_own_message` -
/// so taking the server's copy destroys the text the person typed and leaves
/// them looking at their own message as a placeholder, permanently. The local
/// copy is the truth for our own messages; it is the only copy of them that
/// will ever be readable on this device. An album is confirmed by its own path
/// and the same holds there: without it an album arrived in the sender's own
/// chat with a lock where the caption was.
///
/// The formatting is local too, and for the same reason: it went inside the
/// ciphertext, so the copy coming back has none and taking it would strip the
/// bold off a message in the chat of the person who just wrote it.
///
/// The file too: what comes back is the blob of ciphertext the server is
/// holding, and the picture itself is already here - kept on a resource
/// nothing remakes (#225).
///
/// For a forward into an encrypted conversation there is no attribution coming
/// back - it travelled as an ordinary message - so the local one stands.
func mlsAcceptedEcho(_ updated: StoreMessage, current: Message, mediaBox: MediaBox) -> (media: [Media], text: String, attributes: [MessageAttribute], forwardInfo: StoreMessageForwardInfo?) {
    let encrypted = updated.attributes.contains(where: { $0 is MlsCiphertextMessageAttribute })
    let media = encrypted && !current.media.isEmpty ? mlsSteadySentMedia(current.media, mediaBox: mediaBox) : updated.media
    var attributes = updated.attributes
    let text: String
    if encrypted {
        text = current.text
        attributes = attributes.filter {
            !($0 is MlsCiphertextMessageAttribute) && !($0 is TextEntitiesMessageAttribute)
        }
        if let entities = current.attributes.first(where: { $0 is TextEntitiesMessageAttribute }) {
            attributes.append(entities)
        }
    } else {
        text = updated.text
    }
    let forwardInfo = updated.forwardInfo ?? current.forwardInfo.flatMap { info in
        StoreMessageForwardInfo(authorId: info.author?.id, sourceId: info.source?.id, sourceMessageId: info.sourceMessageId, date: info.date, authorSignature: info.authorSignature, psaType: info.psaType, flags: info.flags)
    }
    return (media, text, attributes, forwardInfo)
}

/// The file an edited message keeps. An edit changes the caption, never the
/// file - so the file this device already opened is the right one. What
/// arrives, as the answer to one's own edit or as an update, is the blob the
/// server is holding, and the key that opens it travelled inside the original
/// message; the edited one carries a caption and nothing else. Taking the
/// arriving media left the picture unreadable the moment its caption was
/// changed, on both phones.
func mlsEditedMedia(_ arriving: [Media], previous: [Media], peerId: PeerId) -> [Media] {
    if !previous.isEmpty, MlsRuntime.isEncrypted(peerId: peerId) {
        return previous
    }
    return arriving
}

/// The server has said "you may have missed something". For a client of this
/// fork, one of the things it may have missed is a phone of its own being
/// signed out - and the leaf that phone holds in every conversation goes on
/// reading until another of this person's phones takes it out. Only the count
/// says one has gone, and the count is asked on a rhythm; the server sends this
/// the moment a session ends, so the rhythm stops being the answer (#121).
///
/// An empty publish is the question, so nothing is stored and nothing else is
/// disturbed.
func mlsAfterReset(postbox: Postbox, network: Network, accountPeerId: PeerId) {
    let _ = askHowManyDevices(postbox: postbox, network: network, accountPeerId: accountPeerId).start()
}

extension MlsRuntime {
    /// Who is in the chat decides who can read it, and a service message is the
    /// one thing every member gets. Comparing against the remembered
    /// participant list instead waits for that list to be fetched again, which
    /// nothing guarantees: a person who followed a link sat in a group where
    /// nothing appeared, and a person removed went on reading it (#40, 4.3).
    ///
    /// Every member tries, and that is deliberate: one commit takes the epoch
    /// and the rest find it already done.
    static func noteMembership(_ action: TelegramMediaActionType, peerId: PeerId, authorId: PeerId?, postbox: Postbox, accountPeerId: PeerId) {
        guard peerId.namespace == Namespaces.Peer.CloudGroup else {
            return
        }
        switch action {
        case let .addedMembers(peerIds):
            let runtime = MlsRuntime.instance(postbox: postbox, accountPeerId: accountPeerId)
            if peerIds.contains(accountPeerId) {
                runtime.invited()
            }
            runtime.memberAdded(peerId: peerId, userIds: peerIds)
        case .joinedByLink, .joinedByRequest:
            // Followed alone, so the person who joined is whoever the message
            // is from.
            if let author = authorId {
                let runtime = MlsRuntime.instance(postbox: postbox, accountPeerId: accountPeerId)
                if author == accountPeerId {
                    runtime.invited()
                }
                runtime.memberAdded(peerId: peerId, userIds: [author])
            }
        case let .removedMembers(peerIds):
            MlsRuntime.instance(postbox: postbox, accountPeerId: accountPeerId)
                .memberRemoved(peerId: peerId, userIds: peerIds)
        default:
            break
        }
    }
}
