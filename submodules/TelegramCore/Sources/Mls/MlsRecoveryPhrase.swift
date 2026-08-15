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
    /// Whether the words have been put in front of the person yet.
    ///
    /// Separate from having them, because the two happen at different moments:
    /// the account's own chat does not exist in the first seconds of a
    /// registration, and words nobody was shown are worse than no words - the
    /// account has a way back that nobody knows.
    public var shown: Bool

    /// Which derivation the server was told about.
    ///
    /// The words are turned into what the server holds through a string that
    /// names the project, and the project was renamed. A secret registered
    /// through the old name is not recognised through the new one, and the
    /// failure would arrive at the worst possible moment - somebody typing six
    /// words into a phone they have just bought, and being refused. So the
    /// device registers again, from the words it is still holding, and writes
    /// down that it has. Nothing on paper stops working.
    public var derivation: Int32

    public static let currentDerivation: Int32 = 2

    public init(phrase: String, shown: Bool, derivation: Int32 = MlsRecoveryState.currentDerivation) {
        self.phrase = phrase
        self.shown = shown
        self.derivation = derivation
    }

    // Written out by hand, one string under one key. The encoder underneath is
    // Postbox's own, not JSONEncoder, and anything cleverer than this has
    // trapped inside it before - taking the app down on the thread that writes
    // messages.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)
        self.phrase = try container.decode(String.self, forKey: "p")
        self.shown = (try container.decodeIfPresent(Int32.self, forKey: "s") ?? 0) != 0
        // Absent means it was written before this existed, which is exactly the
        // state that needs re-registering.
        self.derivation = try container.decodeIfPresent(Int32.self, forKey: "d") ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)
        try container.encode(self.phrase, forKey: "p")
        try container.encode(Int32(self.shown ? 1 : 0), forKey: "s")
        try container.encode(self.derivation, forKey: "d")
    }
}

public extension MlsRecoveryState {
    static func load(transaction: Transaction) -> MlsRecoveryState? {
        return transaction.getPreferencesEntry(key: PreferencesKeys.mlsRecovery)?
            .get(MlsRecoveryState.self)
    }

    static func save(transaction: Transaction, phrase: String, shown: Bool,
                     derivation: Int32 = MlsRecoveryState.currentDerivation) {
        transaction.updatePreferencesEntry(key: PreferencesKeys.mlsRecovery, { _ in
            return PreferencesEntry(MlsRecoveryState(phrase: phrase, shown: shown, derivation: derivation))
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
/// Tells the server what a phrase derives to, and writes down that it has been
/// told. Used both when the words are new and when the derivation behind them
/// has changed underneath an account that already had them.
private func registerSecret(postbox: Postbox, network: Network, phrase: String) -> Signal<Void, NoError> {
    guard let secret = try? MlsRecovery.authSecret(phrase: phrase) else {
        Logger.shared.log("Mls", "cannot derive a recovery secret")
        return .complete()
    }
    return network.request(Api.functions.mls.setRecoverySecret(secret: secret))
    |> map(Optional.init)
    |> `catch` { _ -> Signal<Api.mls.Ok?, NoError> in
        return .single(nil)
    }
    |> mapToSignal { result -> Signal<Void, NoError> in
        guard result != nil else {
            // Left as it was, so this runs again next launch. Writing down that
            // the server knows a secret it does not would lose the account.
            Logger.shared.log("Mls", "the server did not take the recovery secret")
            return .complete()
        }
        return postbox.transaction { transaction -> Void in
            guard var state = MlsRecoveryState.load(transaction: transaction) else {
                return
            }
            state.derivation = MlsRecoveryState.currentDerivation
            MlsRecoveryState.save(transaction: transaction, phrase: state.phrase,
                                  shown: state.shown, derivation: state.derivation)
            Logger.shared.log("Mls", "the recovery phrase was registered again after the rename")
        }
    }
}

func ensureRecoveryPhrase(postbox: Postbox, network: Network, accountPeerId: PeerId) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> MlsRecoveryState? in
        return MlsRecoveryState.load(transaction: transaction)
    }
    |> mapToSignal { existing -> Signal<Void, NoError> in
        if let existing = existing {
            // The words are kept; what the server was told about them may be
            // out of date. Registered again from the same words, so the paper
            // in somebody's drawer keeps working.
            let reregister: Signal<Void, NoError>
            if existing.derivation < MlsRecoveryState.currentDerivation {
                reregister = registerSecret(postbox: postbox, network: network, phrase: existing.phrase)
            } else {
                reregister = .complete()
            }

            // Already has words. If they were never shown - the account's own
            // chat did not exist yet when they were made - try again now.
            if existing.shown {
                return reregister
            }
            return reregister
            |> then(showUntilItLands(postbox: postbox, accountPeerId: accountPeerId, phrase: existing.phrase))
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
                MlsRecoveryState.save(transaction: transaction, phrase: phrase, shown: false)
                Logger.shared.log("Mls", "a recovery phrase was made on this device")
            }
            |> then(showUntilItLands(postbox: postbox, accountPeerId: accountPeerId, phrase: phrase))
        }
    }
}

/// How long to keep trying to put the words on screen, and how often.
///
/// The words are written into the account's own chat, and on a freshly
/// registered account that chat does not exist for the first seconds - the
/// record of who this person is arrives from the server after everything here
/// has run. It was tried once per launch, so an account registered and left
/// running never saw them at all: made, never shown, and the person has no way
/// back without knowing it. Found by somebody on step two of a checklist.
private let showAttempts = 30
private let betweenShowAttempts: Double = 5.0

private func showUntilItLands(postbox: Postbox, accountPeerId: PeerId, phrase: String, attempt: Int = 0) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Bool in
        if showRecoveryPhrase(transaction: transaction, accountPeerId: accountPeerId, phrase: phrase) {
            MlsRecoveryState.save(transaction: transaction, phrase: phrase, shown: true)
            return true
        }
        return false
    }
    |> mapToSignal { shown -> Signal<Void, NoError> in
        if shown {
            Logger.shared.log("Mls", "the recovery phrase is in Saved Messages, after \(attempt) wait(s)")
            return .complete()
        }
        guard attempt < showAttempts else {
            // Left for the next launch rather than tried for ever.
            Logger.shared.log("Mls", "the recovery phrase still has nowhere to go; it will be tried again next time")
            return .complete()
        }
        return Signal<Void, NoError>.complete()
        |> suspendAwareDelay(betweenShowAttempts, queue: Queue.concurrentDefaultQueue())
        |> then(showUntilItLands(postbox: postbox, accountPeerId: accountPeerId, phrase: phrase, attempt: attempt + 1))
    }
}

/// Puts the words in front of the person, where the server's message used to be.
///
/// The message is local and stays local: it is never sent, which is the entire
/// point. A proper screen that has to be acknowledged would be better and is
/// what this should become - a message can be scrolled past.
@discardableResult
private func showRecoveryPhrase(transaction: Transaction, accountPeerId: PeerId, phrase: String) -> Bool {
    // Into the service chat, which is the one chat a freshly registered account
    // has and the one its owner is looking at - the sign-in code is in it.
    //
    // It went into Saved Messages before, back when the service chat was
    // invisible on a fresh account (#45, since fixed). That was worse in a way
    // nobody checked: a local message does not put Saved Messages in the chat
    // list, so the words were written where their owner could not see them.
    // Two people registered, looked at their one chat, and reported that no
    // phrase had arrived - twice.
    let servicePeerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(777000))
    guard transaction.getPeer(servicePeerId) != nil else {
        // Not yet - the service chat arrives from the server a moment after
        // registering. Tried again rather than given up on.
        return false
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
    return true
}
