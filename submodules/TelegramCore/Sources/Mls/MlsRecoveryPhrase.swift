import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi
import MlsCore

/// The words that get this account back if the phone is gone.
///
/// They are made here and stay here. What the server is told is a one-way
/// derivation - enough to recognise somebody typing them, and nothing else -
/// so that holding the server never means holding the way into an account.
///
/// It used to work the other way round: the server made the phrase and sent it
/// as a message, and thirty-three of them were sitting in its message table in
/// plain text. That is also why the encrypted history backup could not have
/// meant anything until this changed: its key comes from the same words.
public struct MlsRecoveryState: Codable, Equatable {
    public var phrase: String

    public init(phrase: String) {
        self.phrase = phrase
    }

    // Written out by hand, one string under one key. The encoder underneath is
    // Postbox's own, not JSONEncoder, and anything cleverer than this has
    // trapped inside it before - taking the app down on the thread that writes
    // messages.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)
        self.phrase = try container.decode(String.self, forKey: "p")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)
        try container.encode(self.phrase, forKey: "p")
    }
}

public extension MlsRecoveryState {
    static func load(transaction: Transaction) -> MlsRecoveryState? {
        return transaction.getPreferencesEntry(key: PreferencesKeys.mlsRecovery)?
            .get(MlsRecoveryState.self)
    }

    static func save(transaction: Transaction, phrase: String) {
        transaction.updatePreferencesEntry(key: PreferencesKeys.mlsRecovery, { _ in
            return PreferencesEntry(MlsRecoveryState(phrase: phrase))
        })
    }
}

/// Gives this account a way back if it has none.
///
/// Runs once per device: if the words are already here the account is covered,
/// and replacing them silently would turn whatever is written on paper into a
/// worthless piece of paper.
///
/// An account that had a phrase from the old server is a different matter - that
/// one was delivered in a message and is compromised by definition, so this
/// device makes a new one and says so.
func ensureRecoveryPhrase(postbox: Postbox, network: Network, accountPeerId: PeerId) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> MlsRecoveryState? in
        return MlsRecoveryState.load(transaction: transaction)
    }
    |> mapToSignal { existing -> Signal<Void, NoError> in
        if existing != nil {
            return .complete()
        }
        guard let phrase = try? MlsRecovery.phrase(),
              let secret = try? MlsRecovery.authSecret(phrase: phrase) else {
            Logger.shared.log("Mls", "cannot make a recovery phrase")
            return .complete()
        }

        return network.request(Api.functions.mls.setRecoverySecret(secret: secret))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.mls.Ok?, NoError> in
            return .single(nil)
        }
        |> mapToSignal { result -> Signal<Void, NoError> in
            guard result != nil else {
                // Nothing is stored: an account whose server does not know the
                // secret must not be told it has a way back. This runs again
                // next time.
                Logger.shared.log("Mls", "the server did not take a recovery secret")
                return .complete()
            }

            return postbox.transaction { transaction -> Void in
                MlsRecoveryState.save(transaction: transaction, phrase: phrase)
                showRecoveryPhrase(transaction: transaction, accountPeerId: accountPeerId, phrase: phrase)
                Logger.shared.log("Mls", "a recovery phrase was made on this device")
            }
        }
    }
}

/// Puts the words in front of the person, where the server's message used to be.
///
/// The message is local and stays local: it is never sent, which is the entire
/// point. A proper screen that has to be acknowledged would be better and is
/// what this should become - a message can be scrolled past.
private func showRecoveryPhrase(transaction: Transaction, accountPeerId: PeerId, phrase: String) {
    // Into Saved Messages rather than the service chat. The service chat is not
    // there on a freshly registered account - see #45 - and words nobody is
    // shown are an account with no way back at all.
    let servicePeerId = accountPeerId
    guard transaction.getPeer(servicePeerId) != nil else {
        return
    }

    let text = "Recovery phrase:\n\n\(phrase)\n\nWrite it down on paper and keep it. It is the only way back into this account if the phone is lost, it works once, and nobody - including this service - can give it to you again."
    let entities = TextEntitiesMessageAttribute(entities: [
        MessageTextEntity(range: 0 ..< 16, type: .Bold),
        MessageTextEntity(range: 18 ..< (18 + phrase.count), type: .Bold),
    ])

    let _ = transaction.addMessages([StoreMessage(
        peerId: servicePeerId,
        namespace: Namespaces.Message.Local,
        customStableId: nil,
        globallyUniqueId: Int64.random(in: Int64.min ... Int64.max),
        groupingKey: nil,
        threadId: nil,
        timestamp: Int32(Date().timeIntervalSince1970),
        flags: [],
        tags: [],
        globalTags: [],
        localTags: [],
        forwardInfo: nil,
        authorId: servicePeerId,
        text: text,
        attributes: [entities],
        media: [])], location: .Random)
}
