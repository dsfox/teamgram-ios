import Foundation
import Postbox
import SwiftSignalKit

/// The one place this device's encryption state is written back.
///
/// Everything that moves a ratchet - sending, receiving, joining a conversation,
/// making key packages - has to persist what it did, and it used to do that by
/// exporting the whole state and writing it on whatever queue it happened to be
/// on. Two of those in flight at once land in whatever order the system picks,
/// and the older one wins.
///
/// What that costs is not a stale preference. It is a secret that has already
/// been spent coming back to life, and MLS refuses to use it twice - which
/// arrives as `SecretReuseError` and, on screen, as a message that never opens.
/// The same shape swallowed a joined conversation whole: the state that had it
/// was overwritten by one that did not, and the welcome that would have brought
/// it back had already been consumed.
///
/// So writes go through one serial queue, in the order they were made.
final class MlsStateWriter {
    private static var writers: [Int64: MlsStateWriter] = [:]
    private static let lock = NSLock()

    static func instance(accountPeerId: PeerId) -> MlsStateWriter {
        lock.lock()
        defer { lock.unlock() }
        let key = accountPeerId.id._internalGetInt64Value()
        if let existing = writers[key] {
            return existing
        }
        let writer = MlsStateWriter()
        writers[key] = writer
        return writer
    }

    private let queue = Queue(name: "org.2bytes.mls.state", qos: .default)

    /// Writes the state, after everything written before it.
    ///
    /// The caller passes the bytes it has already exported: exporting inside
    /// here would read the identity from another thread while its owner is
    /// using it.
    func write(postbox: Postbox, state: Data) {
        self.queue.async {
            let done = DispatchSemaphore(value: 0)
            let _ = (postbox.transaction { transaction -> Void in
                MlsDeviceState.save(transaction: transaction, state: state)
            }).start(completed: {
                done.signal()
            })
            // Waited for on this queue and only on this queue, so the next
            // write cannot start before this one has landed. That ordering is
            // the entire purpose of the class.
            _ = done.wait(timeout: .now() + 10.0)
        }
    }
}
