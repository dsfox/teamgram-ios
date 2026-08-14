import Foundation
import Postbox
import SwiftSignalKit

/// Which conversations have already had their history written into the search
/// index.
///
/// Every message is indexed as it is stored, so a chat started after this
/// existed is searchable without any of this. A chat that was already here when
/// it arrived is not: nothing rewrites those messages, and they would stay
/// unfindable for as long as the chat is used. So each one is walked once, and
/// the fact that it has been walked is written down.
public struct MlsSearchIndexState: Codable, Equatable {
    public var indexedPeers: Set<Int64>

    public init(indexedPeers: Set<Int64> = []) {
        self.indexedPeers = indexedPeers
    }

    // One array of one simple type, written out by hand. Postbox encodes
    // preferences with its own encoder, not JSONEncoder, and a shape it does not
    // like traps inside it on the thread that writes messages - which is how
    // this codebase learned to keep these types dull.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)
        self.indexedPeers = Set(try container.decodeIfPresent([Int64].self, forKey: "p") ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)
        // Sorted, so writing the same thing twice writes the same bytes.
        try container.encode(self.indexedPeers.sorted(), forKey: "p")
    }
}

public extension MlsSearchIndexState {
    static func load(transaction: Transaction) -> MlsSearchIndexState {
        return transaction.getPreferencesEntry(key: PreferencesKeys.mlsSearchIndex)?
            .get(MlsSearchIndexState.self) ?? MlsSearchIndexState()
    }

    static func save(transaction: Transaction, state: MlsSearchIndexState) {
        transaction.updatePreferencesEntry(key: PreferencesKeys.mlsSearchIndex, { _ in
            return PreferencesEntry(state)
        })
    }
}

/// How much of one chat's history is written into the index on the first pass.
///
/// A cap rather than everything, because this runs at launch and a chat can hold
/// years. Everything newer than the cap is indexed as it arrives, so the only
/// thing beyond it is old messages nobody has searched for yet.
private let messagesToIndexPerChat = 2000

/// Writes the chats named here into the search index, skipping the ones already
/// done.
///
/// Called from the search itself rather than from anything at startup. It was in
/// the chain that runs when the encryption state loads, and it did not run: the
/// chain stopped somewhere ahead of it and said nothing, which from outside is
/// indistinguishable from a chat with no words in it. Here it cannot be silently
/// skipped, because the thing that needs it is the thing that calls it.
func ensureMlsSearchIndex(transaction: Transaction, peerIds: [PeerId]) {
    guard !peerIds.isEmpty else {
        return
    }
    var state = MlsSearchIndexState.load(transaction: transaction)
    var indexed = 0
    var chats = 0
    for peerId in peerIds {
        let key = peerId.id._internalGetInt64Value()
        if state.indexedPeers.contains(key) {
            continue
        }
        indexed += transaction.indexMessageTextOfPeer(peerId, limit: messagesToIndexPerChat)
        state.indexedPeers.insert(key)
        chats += 1
    }
    guard chats > 0 else {
        return
    }
    MlsSearchIndexState.save(transaction: transaction, state: state)
    Logger.shared.log("Search", "\(indexed) message(s) in \(chats) chat(s) can now be searched for")
}
