import Foundation
import Postbox
import SwiftSignalKit

/// This device's end-to-end encryption state, as the account stores it.
///
/// The blob inside is everything MLS knows about this device: the key it signs
/// with, the conversations it is in, and where each ratchet had got to. Losing
/// it makes every conversation on this device unreadable - by design and for
/// good - so it is written back after anything that moves a ratchet, not at
/// some convenient later moment.
///
/// It lives in the account's own storage rather than the keychain, for the same
/// reason secret chat state does: it grows with the number of conversations,
/// which the keychain is not for, and it has to disappear with the account.
public struct MlsDeviceState: Codable, Equatable {
    public var state: Data
    /// Which write this is: one more than the blob it replaced.
    ///
    /// Two processes open this account - the app and the notification
    /// extension (#42) - and each holds a copy of the blob in memory. Whoever
    /// writes writes the next generation, and nobody writes over a newer one;
    /// that rule lives in `MlsStateWriter`. A blob from before this field
    /// reads as generation 0.
    public var generation: Int64

    public init(state: Data, generation: Int64) {
        self.state = state
        self.generation = generation
    }

    // Written out by hand, with a string key and a string value.
    //
    // The first version let Swift synthesise this and stored Data directly. The
    // encoder underneath is Postbox's own, not JSONEncoder, and it trapped -
    // the app died on the thread that writes messages, taking the message with
    // it and sending it twice on the next launch. Everything here is now the
    // one shape that encoder is used to elsewhere in this codebase.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)
        let encoded = try container.decode(String.self, forKey: "s")
        self.state = Data(base64Encoded: encoded) ?? Data()
        self.generation = (try? container.decodeIfPresent(Int64.self, forKey: "g")) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)
        try container.encode(self.state.base64EncodedString(), forKey: "s")
        try container.encode(self.generation, forKey: "g")
    }
}

public extension MlsDeviceState {
    /// Reads what was stored, or nothing if this account has no device yet.
    static func load(transaction: Transaction) -> MlsDeviceState? {
        return transaction.getPreferencesEntry(key: PreferencesKeys.mlsDeviceState)?
            .get(MlsDeviceState.self)
    }

    /// Writes it back. Called after anything that moves a ratchet: a message
    /// read, a member added, a conversation joined. Saving late is the same as
    /// not saving - the app can be killed at any moment, and what is lost is
    /// not a preference but the ability to read.
    static func save(transaction: Transaction, state: Data, generation: Int64) {
        transaction.updatePreferencesEntry(key: PreferencesKeys.mlsDeviceState, { _ in
            return PreferencesEntry(MlsDeviceState(state: state, generation: generation))
        })
    }
}
