import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi

/// What leaves this device in place of a message's text. PendingMessageManager
/// and RequestEditMessage, upstream's files, call these and keep only the call
/// (#196).
extension MlsRuntime {
    /// Before anything is sent, make sure there is a conversation to encrypt
    /// into. Otherwise the first message to somebody - usually the one that
    /// says why you are writing - would be the single message in that chat
    /// the server could read.
    ///
    /// This costs one round trip, once per person, and completes rather than
    /// fails when no conversation can be made: then the message goes in the
    /// clear, as it always did.
    func beforeSending(to peerId: PeerId, _ send: @escaping () -> Signal<Void, NoError>) -> Signal<Void, NoError> {
        return self.ensureConversation(peerId: peerId)
        |> mapToSignal { _ -> Signal<Void, NoError> in
            return send()
        }
    }

    /// The text a message goes out with: encrypted if this conversation can
    /// carry it, and exactly as before if it cannot. A messenger that refuses
    /// to send is worse than one whose server can read a message, so every
    /// failure here falls back rather than stopping - except in an extension,
    /// which sends nothing in the clear, the picture included: a file whose key
    /// is not inside a ciphertext went up readable (#230). Then this is nil and
    /// the caller fails the message.
    ///
    /// Inside the transaction the message is sent in (#230). A caption is text
    /// like any other; `media` is the key to its file, which travels inside the
    /// same ciphertext.
    func outgoingText(peerId: PeerId, text: String, entities: inout [Api.MessageEntity]?, flags: inout Int32, forwarded: Api.mls.Content.Forwarded?, media: Api.mls.Content.Media? = nil, transaction: Transaction) -> String? {
        if let ciphertext = self.encryptedText(peerId: peerId, text: text, entities: &entities, flags: &flags, forwarded: forwarded, media: media, transaction: transaction) {
            return ciphertext
        }
        return MlsRuntime.inAnExtension ? nil : text
    }

    /// The same for one picture of an album, whose flags are worked out from the
    /// entities afterwards. An album's captions go out by their own route, so
    /// they need encrypting too - one of them carries the text of the whole
    /// group, and it used to be the one thing in a picture message the server
    /// could read.
    func outgoingCaption(peerId: PeerId, text: String, entities: inout [Api.MessageEntity]?, forwarded: Api.mls.Content.Forwarded?, media: Api.mls.Content.Media?, transaction: Transaction) -> String? {
        var flagsWorkedOutAfterwards: Int32 = 0
        return self.outgoingText(peerId: peerId, text: text, entities: &entities, flags: &flagsWorkedOutAfterwards, forwarded: forwarded, media: media, transaction: transaction)
    }

    /// The new text of an edit. Editing used to undo the encryption of a
    /// message that had already been sent encrypted: the new text went up in
    /// the clear, and the server ended up holding what it had never been able
    /// to read.
    func editedText(peerId: PeerId, text: String, entities: inout [Api.MessageEntity]?, flags: inout Int32) -> String {
        return self.encryptedText(peerId: peerId, text: text, entities: &entities, flags: &flags, forwarded: nil, media: nil, transaction: nil) ?? text
    }

    /// Bold, links, mentions are offsets into the text, so they go inside the
    /// ciphertext with it. What would be left beside it points past the end of
    /// what the other side reads back, so the entities are dropped, and with
    /// them bit 3 of `flags`, which says they follow in sendMessage, sendMedia
    /// and editMessage alike.
    private func encryptedText(peerId: PeerId, text: String, entities: inout [Api.MessageEntity]?, flags: inout Int32, forwarded: Api.mls.Content.Forwarded?, media: Api.mls.Content.Media?, transaction: Transaction?) -> String? {
        guard let ciphertext = self.encrypt(peerId: peerId, text: text, entities: entities ?? [], forwarded: forwarded, media: media, transaction: transaction) else {
            return nil
        }
        entities = nil
        flags &= ~Int32(1 << 3)
        return ciphertext
    }
}
