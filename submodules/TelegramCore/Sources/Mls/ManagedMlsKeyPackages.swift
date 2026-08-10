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

        let saveState = postbox.transaction { transaction -> Void in
            if let state = try? identity.export() {
                MlsDeviceState.save(transaction: transaction, state: state)
            }
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
func mlsIdentity(postbox: Postbox, accountPeerId: PeerId) throws -> MlsIdentity {
    var stored: Data?
    let loaded = DispatchSemaphore(value: 0)
    let _ = (postbox.transaction { transaction -> Data? in
        return MlsDeviceState.load(transaction: transaction)?.state
    }).start(next: { value in
        stored = value
        loaded.signal()
    })
    // Waited for rather than made asynchronous: this is called once, off the
    // main queue, and an identity that arrives later is an identity the caller
    // has already decided it does not have.
    _ = loaded.wait(timeout: .now() + 5.0)

    if let stored = stored, let identity = try? MlsIdentity.open(state: stored) {
        return identity
    }

    // A name that says which device this is. The account id alone would name
    // the person, and then two phones would look like one member.
    let name = "\(accountPeerId.id._internalGetInt64Value())/\(UInt32.random(in: 0 ... UInt32.max))"
    let identity = try MlsIdentity(name: Data(name.utf8))

    let state = try identity.export()
    let _ = (postbox.transaction { transaction -> Void in
        MlsDeviceState.save(transaction: transaction, state: state)
    }).start()

    Logger.shared.log("Mls", "a device identity was made for this account")
    return identity
}
