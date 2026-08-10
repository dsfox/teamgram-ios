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

    public init(state: Data) {
        self.state = state
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
    static func save(transaction: Transaction, state: Data) {
        transaction.updatePreferencesEntry(key: PreferencesKeys.mlsDeviceState, { _ in
            return PreferencesEntry(MlsDeviceState(state: state))
        })
    }
}
