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
    /// fails when no conversation can be made yet: then the message waits for
    /// one (#256).
    func beforeSending(to peerId: PeerId, _ send: @escaping () -> Signal<Void, NoError>) -> Signal<Void, NoError> {
        return self.ensureConversation(peerId: peerId)
        |> mapToSignal { _ -> Signal<Void, NoError> in
            return send()
        }
    }

    /// The content of a message, unless the server would read it beside the
    /// ciphertext (#258). In a chat that encrypts, media goes only as the blob
    /// whose key travels inside the ciphertext. A poll, a dice or a live
    /// location - nothing here carries them - waited for good since #256, and
    /// with a caption went beside its ciphertext; an inline bot's result is
    /// made by the server. Each fails instead, where the person sees it. A
    /// location and a contact go inside the ciphertext as a text (#267), and
    /// never reach this as media. A forward is a copy the server makes by id,
    /// of words nobody encrypted for this chat: one queued as a forward fails
    /// here, a forward queued now is a copy (#259).
    static func refusingPlain(_ content: MessageContentToUpload, encrypts: Bool, messageId: MessageId) -> MessageContentToUpload {
        guard encrypts else {
            return content
        }
        func besideTheCiphertext(_ result: PendingMessageUploadedContentResult) -> Bool {
            guard case let .content(uploaded) = result else {
                return false
            }
            switch uploaded.content {
            case .media:
                return uploaded.mlsMedia == nil
            case .chatContextResult, .forward:
                return true
            default:
                return false
            }
        }
        func refusal() -> Signal<PendingMessageUploadedContentResult, PendingMessageUploadError> {
            Logger.shared.log("Mls", "message \(messageId) would go beside the ciphertext, so it fails")
            return .fail(.generic)
        }
        switch content {
        case let .immediate(result, type):
            return besideTheCiphertext(result) ? .signal(refusal(), type) : content
        case let .signal(signal, type):
            return .signal(signal |> mapToSignal { result -> Signal<PendingMessageUploadedContentResult, PendingMessageUploadError> in
                return besideTheCiphertext(result) ? refusal() : .single(result)
            }, type)
        }
    }

    /// The text a message goes out with: encrypted, or as it is in a chat that
    /// does not encrypt at all - a bot, Saved Messages. Nil when the chat
    /// encrypts and this message cannot be encrypted yet: it waits for its
    /// conversation and is never sent in the clear (the owner's word of 12
    /// October, #256). An extension cannot wait, so there nil fails the
    /// message, whatever the chat - a file whose key is not inside a ciphertext
    /// went up readable (#230).
    ///
    /// Inside the transaction the message is sent in (#230). A caption is text
    /// like any other; `media` is the key to its file, which travels inside the
    /// same ciphertext.
    func outgoingText(peerId: PeerId, text: String, entities: inout [Api.MessageEntity]?, flags: inout Int32, forwarded: Api.mls.Content.Forwarded?, media: Api.mls.Content.Media? = nil, inside: Api.mls.Content.Inside? = nil, transaction: Transaction) -> String? {
        if let ciphertext = self.encryptedText(peerId: peerId, text: text, entities: &entities, flags: &flags, forwarded: forwarded, media: media, inside: inside, transaction: transaction) {
            return ciphertext
        }
        if MlsRuntime.inAnExtension || MlsRuntime.encrypts(peer: transaction.getPeer(peerId), peerId: peerId, accountPeerId: self.accountPeerId) {
            return nil
        }
        return text
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
    /// to read. Nil in a chat that encrypts and cannot right now: the edit is
    /// refused rather than kept for later the way a new message is (#256).
    func editedText(peer: Peer, text: String, entities: inout [Api.MessageEntity]?, flags: inout Int32) -> String? {
        // A caption taken away carries nothing to hide.
        if text.isEmpty {
            return text
        }
        if let ciphertext = self.encryptedText(peerId: peer.id, text: text, entities: &entities, flags: &flags, forwarded: nil, media: nil, transaction: nil) {
            return ciphertext
        }
        return MlsRuntime.encrypts(peer: peer, peerId: peer.id, accountPeerId: self.accountPeerId) ? nil : text
    }

    /// Bold, links, mentions are offsets into the text, so they go inside the
    /// ciphertext with it. What would be left beside it points past the end of
    /// what the other side reads back, so the entities are dropped, and with
    /// them bit 3 of `flags`, which says they follow in sendMessage, sendMedia
    /// and editMessage alike.
    private func encryptedText(peerId: PeerId, text: String, entities: inout [Api.MessageEntity]?, flags: inout Int32, forwarded: Api.mls.Content.Forwarded?, media: Api.mls.Content.Media?, inside: Api.mls.Content.Inside? = nil, transaction: Transaction?) -> String? {
        guard let ciphertext = self.encrypt(peerId: peerId, text: text, entities: entities ?? [], forwarded: forwarded, media: media, inside: inside, transaction: transaction) else {
            return nil
        }
        entities = nil
        flags &= ~Int32(1 << 3)
        return ciphertext
    }
}
