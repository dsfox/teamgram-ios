import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi
import MlsCore

/// Keeps this device reachable for encrypted conversations.
///
/// A key package is what somebody else needs in order to start an encrypted
/// conversation with this device while it is asleep. They are used once, so the
/// supply runs down and has to be refilled; the server counts what is left and
/// says when, because it is the only one that can count and this device is the
/// only one that can make them.
///
/// This runs quietly and changes nothing a person sees. Everything it does is
/// preparation: without it, somebody trying to start an encrypted conversation
/// with this device would find nothing to encrypt to and would fall back to
/// sending in the clear.
private let packagesPerRefill = 30

/// How long to wait before trying again after a failure. The supply is not
/// urgent - it only matters when somebody starts a conversation - so a failure
/// costs nothing until then, and hammering the server would be worse than
/// waiting.
private let retryAfterFailure: Double = 5 * 60

func managedMlsKeyPackages(postbox: Postbox, network: Network, accountPeerId: PeerId) -> Signal<Void, NoError> {
    let refill = Signal<Void, NoError> { subscriber in
        let identity: MlsIdentity
        do {
            identity = try mlsIdentity(postbox: postbox, accountPeerId: accountPeerId)
        } catch {
            Logger.shared.log("Mls", "no device identity, so nothing can be published: \(error)")
            subscriber.putCompletion()
            return EmptyDisposable
        }

        var packages: [Buffer] = []
        var lastResort = Buffer()
        do {
            for _ in 0 ..< packagesPerRefill {
                packages.append(Buffer(data: try identity.keyPackage()))
            }
            // One that is handed out repeatedly once the others run out, so a
            // conversation can still start with a device that has been quiet.
            lastResort = Buffer(data: try identity.keyPackage())
        } catch {
            Logger.shared.log("Mls", "cannot make key packages: \(error)")
            subscriber.putCompletion()
            return EmptyDisposable
        }

        // Through the one writer, so it cannot land after something older.
        if let state = try? identity.export() {
            MlsStateWriter.instance(accountPeerId: accountPeerId).write(postbox: postbox, state: state)
        }
        let saveState = postbox.transaction { transaction -> Void in
        }

        // Saved before publishing, not after. A package published but not
        // saved is one this device cannot answer for - somebody would encrypt
        // to a key that no longer exists here, and the conversation would fail
        // to start with no explanation on either side.
        let disposable = (saveState
        |> mapToSignal { _ -> Signal<Api.mls.PublishResult?, NoError> in
            return network.request(Api.functions.mls.publishKeyPackages(keyPackages: packages, lastResort: lastResort))
            |> map(Optional.init)
            |> `catch` { _ -> Signal<Api.mls.PublishResult?, NoError> in
                return .single(nil)
            }
        }).start(next: { result in
            if let result = result {
                Logger.shared.log("Mls", "published \(result.added), \(result.available) available")
            } else {
                Logger.shared.log("Mls", "the server did not take the key packages")
            }
            subscriber.putCompletion()
        })

        return ActionDisposable {
            disposable.dispose()
        }
    }

    // Once at start, and then only when the server says the supply is low -
    // which it does in the answer to publishing. Until there is a reason to
    // publish again, this stays quiet.
    return (refill |> then(Signal<Void, NoError>.complete() |> suspendAwareDelay(retryAfterFailure, queue: Queue.concurrentDefaultQueue())))
    |> restart
}

/// This device's identity, read from the account's storage or made if there is
/// none yet.
///
/// Per device rather than per person: two phones of the same person are two
/// members of the same conversation, which is what makes several devices
/// possible at all.
/// The one identity object this account uses, shared by everything that touches
/// it.
///
/// Sharing rather than opening a copy each time, because the state is written
/// back whole. Three components used to hold three copies of it - the key
/// package publisher, the runtime, the welcome poll - and each saved its own
/// snapshot over the others. The private keys of freshly published key packages
/// were the usual casualty: somebody claims one, builds a conversation on it,
/// and the welcome arrives at a device that no longer holds the key to open it.
/// That is a lock that never becomes a message, and it is not the same bug as
/// two identities being created - that one is fixed below, and this one hid
/// behind it.
private final class MlsIdentityRegistry {
    static let shared = MlsIdentityRegistry()
    private let lock = NSLock()
    private var identities: [Int64: MlsIdentity] = [:]

    func identity(for accountPeerId: PeerId, make: () throws -> MlsIdentity) throws -> MlsIdentity {
        let key = accountPeerId.id._internalGetInt64Value()

        lock.lock()
        if let existing = identities[key] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let identity = try make()

        lock.lock()
        defer { lock.unlock() }
        // Somebody else may have got there while this one was being made.
        if let existing = identities[key] {
            return existing
        }
        identities[key] = identity
        return identity
    }
}

func mlsIdentity(postbox: Postbox, accountPeerId: PeerId) throws -> MlsIdentity {
    return try MlsIdentityRegistry.shared.identity(for: accountPeerId, make: {
        return try loadOrMakeMlsIdentity(postbox: postbox, accountPeerId: accountPeerId)
    })
}

private func loadOrMakeMlsIdentity(postbox: Postbox, accountPeerId: PeerId) throws -> MlsIdentity {
    // Read and create in one transaction, so that two callers arriving at once
    // cannot both find nothing and both make one.
    //
    // They did. This is called from three places that start together on a fresh
    // account - the key package publisher, the runtime, the welcome poll - and
    // each used to read, see nothing, make an identity and save it. The last
    // save won. The key packages sitting on the server then belonged to an
    // identity the device no longer had, so a conversation built on one of them
    // produced a welcome this device could not open, ever. That is what a lock
    // that never turns into a message actually was.
    //
    // Postbox runs transactions one at a time, so inside one the check and the
    // write cannot be split.
    var result: Result<MlsIdentity, Error>?
    let done = DispatchSemaphore(value: 0)

    let _ = (postbox.transaction { transaction -> Void in
        if let stored = MlsDeviceState.load(transaction: transaction)?.state,
           let identity = try? MlsIdentity.open(state: stored) {
            result = .success(identity)
            return
        }

        do {
            // A name that says which device this is. The account id alone would
            // name the person, and then two phones would look like one member.
            let name = "\(accountPeerId.id._internalGetInt64Value())/\(UInt32.random(in: 0 ... UInt32.max))"
            let identity = try MlsIdentity(name: Data(name.utf8))
            MlsDeviceState.save(transaction: transaction, state: try identity.export())
            Logger.shared.log("Mls", "a device identity was made for this account")
            result = .success(identity)
        } catch {
            result = .failure(error)
        }
    }).start(completed: {
        done.signal()
    })

    // Waited for without a way out. A timeout here used to mean "make another
    // one", which is the very thing that broke: being slow is not the same as
    // having none.
    done.wait()

    switch result {
    case let .success(identity):
        return identity
    case let .failure(error):
        throw error
    case nil:
        throw MlsError.failed("the device identity could not be read or made")
    }
}
