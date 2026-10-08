import Foundation
import Postbox
import SwiftSignalKit

/// Why the share extension sent nothing, or not everything (#230).
public enum MlsSharedSendingError {
    /// These chats have no encrypted conversation yet. The extension starts
    /// none and sends nothing in the clear, so the app has to write first.
    case notEncrypted([PeerId])
    /// Refused on the way - by the encryption, the server, or the clock - and
    /// marked as not sent. Nothing of it went in the clear.
    case notSent
}

/// What the share extension was handed, sent through the app's own path (#230).
///
/// Upstream's extension sent through `standaloneSendEnqueueMessages`, which has
/// no encryption at all: every photo, file and comment shared into ice9 would
/// have reached the server readable. Here the extension holds a whole account
/// and enqueues the messages exactly as the app does, so the same
/// `PendingMessageManager` encrypts the text and uploads the file encrypted.
///
/// What is different about an extension is enforced where it happens, not
/// here: it sends only what it enqueued (`PendingMessageManager.sendOwn`),
/// starts no conversation (`MlsRuntime.ensureConversation`), never sends in the
/// clear (the send path), and reads the device back inside the transaction it
/// encrypts in, so it never spends a key the app spent (`MlsStateWriter`).
public final class MlsSharedSending {
    private let account: Account
    /// Long enough for a large video on a slow network, and still an end.
    private static let patience: Double = 600.0

    public init(account: Account) {
        self.account = account
    }

    /// The fraction of the messages sent, then completion once they are all
    /// sent and the encryption state they moved is on disk.
    public func send(_ batches: [(peerId: PeerId, messages: [EnqueueMessage])]) -> Signal<Float, MlsSharedSendingError> {
        let account = self.account
        let batches = batches.filter { !$0.messages.isEmpty }
        guard !batches.isEmpty else {
            return .complete()
        }
        let runtime = MlsRuntime.instance(postbox: account.postbox, accountPeerId: account.peerId)
        let peerIds = batches.map { $0.peerId }
        // An account opened in an extension starts with its connection paused,
        // and nothing else in the process asks for it: every request, the first
        // read of the group's commits included, waited in the queue for good.
        let keepConnection = account.network.shouldKeepConnection

        // The device and the conversations off disk, as the notification
        // extension reads them, then each chat compared with its conversation
        // the way the app does before a send.
        let woken: Signal<Void, NoError> = runtime.wake(network: account.network)
        |> mapToSignal { _ -> Signal<Void, NoError> in
            return .complete()
        }
        let ready: Signal<Void, NoError> = woken
        |> then(combineLatest(peerIds.map { runtime.ensureConversation(peerId: $0) |> take(1) }) |> map { _ -> Void in
            return Void()
        })

        return ready
        |> take(1)
        |> castError(MlsSharedSendingError.self)
        |> mapToSignal { _ -> Signal<[MessageId], MlsSharedSendingError> in
            let refused = peerIds.filter { !MlsRuntime.isEncrypted(peerId: $0) }
            if !refused.isEmpty {
                Logger.shared.log("Mls", "share: no conversation with \(refused.map { $0.id._internalGetInt64Value() }), nothing sent")
                return .fail(.notEncrypted(refused))
            }
            return combineLatest(batches.map { enqueueMessages(account: account, peerId: $0.peerId, messages: $0.messages) |> take(1) })
            |> map { results -> [MessageId] in
                return results.flatMap { $0.compactMap { $0 } }
            }
            |> castError(MlsSharedSendingError.self)
        }
        |> mapToSignal { ids -> Signal<Float, MlsSharedSendingError> in
            Logger.shared.log("Mls", "share: enqueued \(ids.count) message(s) in \(peerIds.count) chat(s)")
            account.pendingMessageManager.sendOwn(ids)
            return MlsSharedSending.sent(postbox: account.postbox, ids: ids)
        }
        |> then(runtime.settled()
            |> castError(MlsSharedSendingError.self)
            |> mapToSignal { _ -> Signal<Float, MlsSharedSendingError> in
                Logger.shared.log("Mls", "share: sent, and the state it moved is on disk")
                return .complete()
            })
        |> beforeStarted {
            keepConnection.set(.single(true))
        }
        |> afterDisposed {
            // Nothing else in an extension holds the account: the closures that
            // enqueued are let go once they have run, and the account went with
            // them - its sending manager, mid-send, included.
            withExtendedLifetime(account) {
                keepConnection.set(.single(false))
            }
        }
    }

    /// Watches the messages until each has gone - a local message is moved to
    /// its server id once the server has it - or one is marked failed.
    private static func sent(postbox: Postbox, ids: [MessageId]) -> Signal<Float, MlsSharedSendingError> {
        guard !ids.isEmpty else {
            return .single(1.0)
        }
        return Signal { subscriber in
            let disposable = MetaDisposable()
            let queue = Queue.concurrentDefaultQueue()
            let deadline = CFAbsoluteTimeGetCurrent() + MlsSharedSending.patience
            func look() {
                disposable.set((postbox.transaction { transaction -> (gone: Int, failed: Bool) in
                    var gone = 0
                    var failed = false
                    for id in ids {
                        if let message = transaction.getMessage(id) {
                            if message.flags.contains(.Failed) {
                                failed = true
                            }
                        } else {
                            gone += 1
                        }
                    }
                    return (gone, failed)
                }).start(next: { state in
                    if state.failed {
                        Logger.shared.log("Mls", "share: a message was refused and marked as not sent")
                        subscriber.putError(.notSent)
                        return
                    }
                    subscriber.putNext(Float(state.gone) / Float(ids.count))
                    if state.gone == ids.count {
                        subscriber.putCompletion()
                    } else if CFAbsoluteTimeGetCurrent() > deadline {
                        Logger.shared.log("Mls", "share: \(ids.count - state.gone) message(s) still unsent after \(Int(MlsSharedSending.patience)) s")
                        subscriber.putError(.notSent)
                    } else {
                        queue.after(0.5, look)
                    }
                }))
            }
            look()
            return disposable
        }
    }
}
