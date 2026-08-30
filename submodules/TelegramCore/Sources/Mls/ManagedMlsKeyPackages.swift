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

/// How long between looks at the supply. It only matters when somebody starts a
/// conversation with this device, and the low-water mark leaves plenty of slack,
/// so there is nothing to gain by asking often.
private let betweenChecks: Double = 15 * 60

/// Asks the server how many devices this account has, now rather than on the
/// rhythm.
///
/// Called when a session has just been ended from this phone. The device that
/// lost a phone is this one, and it is the one that has to take that phone's
/// leaf out of every conversation - left to its own rhythm it notices a quarter
/// of an hour later, and until then the phone that was signed out goes on
/// reading everything said (#121).
///
/// An empty publish is that question: nothing is stored and the count comes
/// back, which is what noteDevices acts on.
/// The leaf name of the identity this device has now.
///
/// Said on every publish, the empty ones included. A device that starts its
/// state over leaves what it published under the old identity on the server;
/// the server counts a supply by the device rather than by the identity, sees a
/// full one, never asks for more - and everybody who starts a conversation with
/// this person builds an invitation it can never open (#136). Naming the
/// identity is what lets the server throw the old ones away.
private func nameOfThisDevice(postbox: Postbox, accountPeerId: PeerId) -> Buffer {
    let runtime = MlsRuntime.instance(postbox: postbox, accountPeerId: accountPeerId)
    let name = runtime.withState { identity -> Data? in identity.name() } ?? nil
    return Buffer(data: name ?? Data())
}

func askHowManyDevices(postbox: Postbox, network: Network, accountPeerId: PeerId) -> Signal<Void, NoError> {
    return network.request(Api.functions.mls.publishKeyPackages(
        keyPackages: [], lastResort: Buffer(),
        name: nameOfThisDevice(postbox: postbox, accountPeerId: accountPeerId)))
    |> map(Optional.init)
    |> `catch` { _ -> Signal<Api.mls.PublishResult?, NoError> in .single(nil) }
    |> map { answer -> Void in
        guard let answer = answer else {
            return
        }
        MlsRuntime.instance(postbox: postbox, accountPeerId: accountPeerId).noteDevices(answer.devices)
    }
}

func managedMlsKeyPackages(postbox: Postbox, network: Network, accountPeerId: PeerId) -> Signal<Void, NoError> {
    let refill = Signal<Void, NoError> { subscriber in
        // The one copy of the state, borrowed for as long as it takes to make
        // the keys and no longer. Reading a copy of its own here and keeping it
        // across the two requests below was a quarter of an hour in which
        // anything else that moved the ratchet could be undone by it (#112).
        let runtime = MlsRuntime.instance(postbox: postbox, accountPeerId: accountPeerId)

        /// What this device has left, asked for rather than assumed.
        ///
        /// Publishing was unconditional and every fifteen minutes, so a device
        /// nobody was starting conversations with reached the hundred it is
        /// allowed to hold within the hour and was refused from then on - once
        /// per wake, for as long as it stayed signed in. On the server that is
        /// an error line every few minutes, which is what the health check was
        /// firing about; on the phone it is work and battery spent making keys
        /// that were thrown away on arrival.
        ///
        /// An empty publish is the question "how many do I have?": nothing is
        /// stored and the count comes back, so no separate method is needed for
        /// it.
        let ask = network.request(Api.functions.mls.publishKeyPackages(
            keyPackages: [], lastResort: Buffer(),
            name: nameOfThisDevice(postbox: postbox, accountPeerId: accountPeerId)))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.mls.PublishResult?, NoError> in
            return .single(nil)
        }

        let disposable = (ask
        |> mapToSignal { asked -> Signal<Api.mls.PublishResult?, NoError> in
            guard let asked = asked else {
                Logger.shared.log("Mls", "the server did not say how many key packages are left")
                return .single(nil)
            }
            guard asked.shouldRefill else {
                return .single(asked)
            }

            // Made and saved before publishing, not after. A package published
            // but not saved is one this device cannot answer for - somebody
            // would encrypt to a key that no longer exists here, and the
            // conversation would fail to start with no explanation on either
            // side. withState writes it on the way out, in order.
            let made: (packages: [Buffer], lastResort: Buffer)? = runtime.withState { identity in
                var packages: [Buffer] = []
                for _ in 0 ..< packagesPerRefill {
                    packages.append(Buffer(data: try identity.keyPackage()))
                }
                // One that is handed out repeatedly once the others run out, so
                // a conversation can still start with a device that has been
                // quiet.
                return (packages, Buffer(data: try identity.keyPackage()))
            }
            guard let (packages, lastResort) = made else {
                Logger.shared.log("Mls", "cannot make key packages")
                return .single(nil)
            }

            return network.request(Api.functions.mls.publishKeyPackages(
                keyPackages: packages, lastResort: lastResort,
                name: nameOfThisDevice(postbox: postbox, accountPeerId: accountPeerId)))
            |> map(Optional.init)
            |> `catch` { _ -> Signal<Api.mls.PublishResult?, NoError> in
                return .single(nil)
            }
        }).start(next: { result in
            if let result = result {
                runtime.noteDevices(result.devices)
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

    return (refill |> then(Signal<Void, NoError>.complete() |> suspendAwareDelay(betweenChecks, queue: Queue.concurrentDefaultQueue())))
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
