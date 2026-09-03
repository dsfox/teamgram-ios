import Foundation
import Postbox
import SwiftSignalKit
import MlsCore

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

    private let queue = Queue(name: "org.ice9.mls.state", qos: .default)
    /// The generation of the blob the identity this process holds was read
    /// from or last written as. Touched on the queue only.
    private var generation: Int64 = 0

    /// Told by whoever read the blob off disk which generation it was.
    func loaded(generation: Int64) {
        self.queue.async {
            self.generation = generation
            Logger.shared.log("Mls", "state loaded at generation \(generation)")
        }
    }

    /// Writes the state, after everything written before it - unless another
    /// process wrote since this one read (#42).
    ///
    /// The caller passes the bytes it has already exported: exporting inside
    /// here would read the identity from another thread while its owner is
    /// using it. It also passes the identity they came from: one exported from
    /// a device this process has since replaced is stale by construction, and
    /// is not written.
    ///
    /// When the generation on disk is ahead of the one held, the blob in
    /// memory is the stale one - the notification extension advanced a ratchet
    /// while the app slept - and writing it back would bring a spent secret
    /// back to life. So it is not written; the device is read back from disk
    /// instead and put in place of the one held, and what the caller did with
    /// the old one is kept only where it already landed: a message it opened
    /// is text in the database by now.
    func write(postbox: Postbox, state: Data, from identity: MlsIdentity, accountPeerId: PeerId) {
        self.queue.async {
            guard MlsIdentityRegistry.shared.existing(for: accountPeerId) === identity else {
                Logger.shared.log("Mls", "not writing state exported from a device since replaced")
                return
            }
            let next = self.generation + 1
            let done = DispatchSemaphore(value: 0)
            var behind: MlsDeviceState?
            let _ = (postbox.transaction { transaction -> Void in
                if let stored = MlsDeviceState.load(transaction: transaction), stored.generation >= next {
                    behind = stored
                    return
                }
                MlsDeviceState.save(transaction: transaction, state: state, generation: next)
            }).start(completed: {
                done.signal()
            })
            // Waited for on this queue and only on this queue, so the next
            // write cannot start before this one has landed. That ordering is
            // the entire purpose of the class.
            _ = done.wait(timeout: .now() + 10.0)
            if let stored = behind {
                Logger.shared.log("Mls", "not writing state held at generation \(self.generation) over generation \(stored.generation)")
                self.take(stored, accountPeerId: accountPeerId)
            } else {
                self.generation = next
            }
        }
    }

    /// Reads the device back from disk when another process has written since
    /// this one read. Called when the app comes to the front (#42): that is
    /// when the extension has had its turn.
    ///
    /// Answers whether anything changed, so the caller knows to read the
    /// conversations off disk again as well.
    func reloadIfBehind(postbox: Postbox, accountPeerId: PeerId) -> Signal<Bool, NoError> {
        return Signal { subscriber in
            self.queue.async {
                // Nothing read yet, nothing to be behind: the first read is
                // on its way and brings its own generation.
                guard MlsIdentityRegistry.shared.existing(for: accountPeerId) != nil else {
                    subscriber.putNext(false)
                    subscriber.putCompletion()
                    return
                }
                let done = DispatchSemaphore(value: 0)
                var stored: MlsDeviceState?
                let _ = (postbox.transaction { transaction -> Void in
                    stored = MlsDeviceState.load(transaction: transaction)
                }).start(completed: {
                    done.signal()
                })
                _ = done.wait(timeout: .now() + 10.0)
                var changed = false
                if let stored = stored, stored.generation > self.generation {
                    changed = self.take(stored, accountPeerId: accountPeerId)
                }
                subscriber.putNext(changed)
                subscriber.putCompletion()
            }
            return EmptyDisposable
        }
    }

    /// Completes after every write queued before it has landed.
    func drained() -> Signal<Void, NoError> {
        return Signal { subscriber in
            self.queue.async {
                subscriber.putNext(Void())
                subscriber.putCompletion()
            }
            return EmptyDisposable
        }
    }

    /// Puts what is on disk in place of what is held. On the queue.
    @discardableResult
    private func take(_ stored: MlsDeviceState, accountPeerId: PeerId) -> Bool {
        guard let identity = try? MlsIdentity.open(state: stored.state) else {
            Logger.shared.log("Mls", "the state at generation \(stored.generation) did not open; keeping generation \(self.generation)")
            return false
        }
        MlsIdentityRegistry.shared.replace(for: accountPeerId, with: identity)
        Logger.shared.log("Mls", "state reloaded at generation \(stored.generation), was \(self.generation)")
        self.generation = stored.generation
        return true
    }
}
