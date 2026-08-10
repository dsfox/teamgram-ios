import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi
import MlsCore

/// The encryption, held in memory so the message path can reach it.
///
/// Sending and receiving both happen where waiting is not an option: a message
/// is turned into what travels while the request is being built, and turned
/// back while an incoming one is being read into the database. Loading the
/// device's state from disk at either of those moments would be wrong twice -
/// too slow, and asynchronous where the code around it is not.
///
/// So the state is loaded once and kept. Everything below is guarded by one
/// lock: MLS state is a ratchet, and two threads moving it at once would leave
/// a conversation that neither can read.
public final class MlsRuntime {
    private static var instances: [Int64: MlsRuntime] = [:]
    private static let instancesLock = NSLock()

    private let queue = NSLock()
    private let postbox: Postbox
    private let accountPeerId: PeerId
    private var identity: MlsIdentity?
    private var groups: [Int64: MlsGroup] = [:]
    /// Conversations being started, so that a burst of messages to somebody new
    /// starts one conversation rather than a race of several - and several
    /// would be worse than slow: each one would replace the last, and the other
    /// side would hold a group nobody talks in.
    private var starting: Set<Int64> = []
    private var network: Network?
    /// Which group belongs to which peer, held in memory.
    ///
    /// Read from storage once rather than on demand, because decrypting happens
    /// while an incoming message is being written into the database - inside a
    /// transaction. Opening another one there and waiting for it is a deadlock:
    /// the app stops, and it stops on the path every message takes.
    private var conversationIds: [Int64: Data] = [:]

    /// Told which network to use, once, by the account that owns it - and the
    /// moment to read everything off disk, which is here rather than at first
    /// use for the reason above.
    public func attach(network: Network) {
        self.queue.lock()
        self.network = network
        self.queue.unlock()

        // Once the state is in place, go over every conversation this device
        // has and read back whatever is still sitting unread in it: messages
        // that arrived while the app was not running, and messages from before
        // the ciphertext was kept apart from the text, which every screen used
        // to show as `mls1:AAEAAh...`.
        let postbox = self.postbox
        let _ = (self.reload()
        |> mapToSignal { [weak self] _ -> Signal<Void, NoError> in
            guard let self = self else {
                return .complete()
            }
            self.queue.lock()
            let peers = self.conversationIds.keys.map {
                PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value($0))
            }
            self.queue.unlock()
            guard !peers.isEmpty else {
                return .complete()
            }
            return combineLatest(peers.map { repairUnreadableMessages(postbox: postbox, runtime: self, peerId: $0) })
            |> map { _ -> Void in }
        }).start()
    }

    /// Remembers a conversation that has just been started or joined, so the
    /// next message finds it without going back to disk.
    private func remember(peerId: Int64, groupId: Data) {
        self.conversationIds[peerId] = groupId
        self.groups.removeValue(forKey: peerId)
    }

    public static func instance(postbox: Postbox, accountPeerId: PeerId) -> MlsRuntime {
        instancesLock.lock()
        defer { instancesLock.unlock() }

        let key = accountPeerId.id._internalGetInt64Value()
        if let existing = instances[key] {
            return existing
        }
        let runtime = MlsRuntime(postbox: postbox, accountPeerId: accountPeerId)
        instances[key] = runtime
        if !running.contains(where: { $0 === runtime }) {
            running.append(runtime)
        }
        return runtime
    }

    private init(postbox: Postbox, accountPeerId: PeerId) {
        self.postbox = postbox
        self.accountPeerId = accountPeerId
    }

    /// The conversation with this peer, or nothing if there is not one on this
    /// device. Nothing is an answer: the caller then sends in the clear rather
    /// than refusing to send.
    /// Nothing here touches the database. Everything it needs was read when the
    /// account attached, because this is called from inside a transaction and
    /// opening another would stop the app on the path every message takes.
    private func group(for peerId: PeerId) -> (MlsIdentity, MlsGroup)? {
        guard let identity = self.identity else {
            return nil
        }

        let key = peerId.id._internalGetInt64Value()
        if let group = self.groups[key] {
            return (identity, group)
        }

        guard let groupId = self.conversationIds[key],
              let group = try? MlsGroup.load(identity: identity, id: groupId) else {
            return nil
        }
        self.groups[key] = group
        return (identity, group)
    }

    /// Whether it makes any sense to encrypt to this peer at all.
    ///
    /// Only conversations between two people. A channel or a group has no
    /// device to encrypt to, so every attempt would cost a round trip and end
    /// in the clear anyway - once per message, for ever, because nothing is
    /// ever remembered.
    ///
    /// Saved Messages is excluded for a harder reason: a conversation with
    /// oneself would be one where every message is written by the only person
    /// who cannot read it back, and the notes would go in unreadable.
    private func worthEncrypting(to peerId: PeerId) -> Bool {
        guard peerId.namespace == Namespaces.Peer.CloudUser, peerId != self.accountPeerId else {
            return false
        }
        // Somebody with no device published - not updated yet, or a bot. Asked
        // about again after a while rather than before every message.
        if let asked = self.withoutDevices[peerId.id._internalGetInt64Value()],
           CFAbsoluteTimeGetCurrent() - asked < 600.0 {
            return false
        }
        return true
    }

    /// When each peer was last found to have no device, so a person who has not
    /// updated does not cost a round trip on every message sent to them.
    private var withoutDevices: [Int64: Double] = [:]

    /// What to send instead of this message, or nothing when this conversation
    /// cannot carry it - and then it goes as it always did.
    public func encrypt(peerId: PeerId, text: String, entities: [Api.MessageEntity]) -> String? {
        guard !text.isEmpty else {
            return nil
        }

        self.queue.lock()
        defer { self.queue.unlock() }

        guard let (identity, group) = self.group(for: peerId) else {
            // Nothing to encrypt to yet. This message goes in the clear and a
            // conversation is started behind it, so the next one does not - the
            // alternative is holding a message until a handshake finishes,
            // which is a messenger that pauses for reasons a person cannot see.
            if self.worthEncrypting(to: peerId) {
                self.startConversation(with: peerId)
            }
            return nil
        }
        return MlsConversations.encrypt(postbox: self.postbox, identity: identity, group: group, text: text, entities: entities)
    }

    /// Makes sure there is a conversation with this person before a message is
    /// sent, so that the first message is encrypted like every one after it.
    ///
    /// A message sent while the handshake is still running would be the one
    /// message in the chat the server could read - and it is usually the one
    /// that says why somebody is writing. Waiting costs a round trip, once per
    /// person, and only the first time.
    ///
    /// It completes rather than fails when a conversation cannot be made: the
    /// caller then sends in the clear, because a messenger that refuses to send
    /// is worse than one whose server can read a message.
    public func ensureConversation(peerId: PeerId) -> Signal<Void, NoError> {
        self.queue.lock()
        let haveGroup = self.group(for: peerId) != nil
        let worth = self.worthEncrypting(to: peerId)
        let network = self.network
        let identity = self.identity
        self.queue.unlock()

        // A value, then completion. Returning only completion is what broke
        // sending outright: the step after this one runs on a value, so a
        // signal that merely completes stops the message before it is built,
        // and the spinner turns for ever with nothing to explain it.
        if haveGroup || !worth {
            return .single(Void())
        }
        guard let network = network, let identity = identity else {
            return .single(Void())
        }

        let key = peerId.id._internalGetInt64Value()
        let postbox = self.postbox
        return MlsConversations.start(postbox: postbox, network: network, identity: identity, peerId: peerId)
        |> mapToSignal { [weak self] groupId -> Signal<Void, NoError> in
            guard let self = self else {
                return .complete()
            }
            self.queue.lock()
            if let groupId = groupId {
                self.remember(peerId: key, groupId: groupId)
            } else {
                self.withoutDevices[key] = CFAbsoluteTimeGetCurrent()
            }
            self.queue.unlock()
            return .single(Void())
        }
        // Encryption must never be able to stop a message. If the handshake has
        // not finished in ten seconds - a slow network, a server that does not
        // answer, anything - the message goes in the clear rather than waiting
        // behind something a person cannot see.
        |> timeout(10.0, queue: Queue.concurrentDefaultQueue(), alternate: .single(Void()))
    }

    /// Starts a conversation with somebody, once. Called from a send, so it
    /// must return at once and leave the work behind it.
    private func startConversation(with peerId: PeerId) {
        let key = peerId.id._internalGetInt64Value()
        guard !self.starting.contains(key), let network = self.network, let identity = self.identity else {
            return
        }
        self.starting.insert(key)

        let postbox = self.postbox
        let _ = (MlsConversations.start(postbox: postbox, network: network, identity: identity, peerId: peerId)
        |> deliverOn(Queue.concurrentDefaultQueue())).start(next: { [weak self] groupId in
            guard let self = self else {
                return
            }
            self.queue.lock()
            self.starting.remove(key)
            if let groupId = groupId {
                self.remember(peerId: key, groupId: groupId)
            } else {
                self.withoutDevices[key] = CFAbsoluteTimeGetCurrent()
            }
            self.queue.unlock()
        })
    }

    /// What this text really says, or nothing if it is not ours or cannot be
    /// read - and then what arrived is shown as it arrived, which is ugly and
    /// honest rather than an empty message.
    public func decrypt(peerId: PeerId, text: String) -> MlsMessageContent? {
        guard MlsConversations.isCiphertext(text) else {
            return nil
        }

        self.queue.lock()
        defer { self.queue.unlock() }

        guard let (identity, group) = self.group(for: peerId) else {
            return nil
        }
        return MlsConversations.decrypt(postbox: self.postbox, identity: identity, group: group, text: text)
    }

    /// The one account that is running, for the places that read a message into
    /// the database and have no account to hand.
    ///
    /// A messenger can hold several accounts, and reading an incoming message
    /// happens where none of them is named. Registering the running one here is
    /// the smallest honest way through: with several accounts signed in, a
    /// message is decrypted by whichever holds that conversation, and one that
    /// holds neither leaves the text alone.
    private static var running: [MlsRuntime] = []

    static func register(_ runtime: MlsRuntime) {
        instancesLock.lock()
        defer { instancesLock.unlock() }
        if !running.contains(where: { $0 === runtime }) {
            running.append(runtime)
        }
    }

    /// Whether this is one of ours, for the places that must not mistake
    /// ciphertext for something to show or to keep.
    public static func isCiphertext(_ text: String) -> Bool {
        return MlsConversations.isCiphertext(text)
    }

    /// Whether messages to this person are encrypted on this device.
    ///
    /// For the places that send text somewhere other than a message - the quote
    /// carried by a reply, the draft synchronised to the server - and would
    /// otherwise hand over in the clear exactly what the message beside it
    /// hides.
    public static func isEncrypted(peerId: PeerId) -> Bool {
        instancesLock.lock()
        let candidates = running
        instancesLock.unlock()

        for runtime in candidates {
            runtime.queue.lock()
            let known = runtime.conversationIds[peerId.id._internalGetInt64Value()] != nil
            runtime.queue.unlock()
            if known {
                return true
            }
        }
        return false
    }

    public static func decryptIncoming(peerId: PeerId, text: String) -> MlsMessageContent? {
        guard MlsConversations.isCiphertext(text) else {
            return nil
        }

        instancesLock.lock()
        let candidates = running
        instancesLock.unlock()

        for runtime in candidates {
            if let content = runtime.decrypt(peerId: peerId, text: text) {
                return content
            }
        }

        // Ours, and unreadable. Almost always because the message overtook the
        // welcome that lets this device into the conversation: one travels as a
        // message, the other is collected by a poll. Rather than leave it as
        // ciphertext for ever - which is what a single attempt at storage time
        // means - go and look for the welcome now, and read the message back
        // once it is found.
        for runtime in candidates {
            runtime.recover(peerId: peerId)
        }
        return nil
    }

    /// Conversations already being looked for, so that a batch of unreadable
    /// messages asks the server once rather than once each.
    private var recovering: Set<Int64> = []

    private func recover(peerId: PeerId) {
        self.queue.lock()
        let key = peerId.id._internalGetInt64Value()
        guard !self.recovering.contains(key), let network = self.network else {
            self.queue.unlock()
            return
        }
        self.recovering.insert(key)
        self.queue.unlock()

        let postbox = self.postbox
        let accountPeerId = self.accountPeerId
        // On another queue on purpose: this is called while an incoming message
        // is being written into the database, inside a transaction. Opening
        // another one here and waiting for it stops the app on the path every
        // message takes.
        Queue.concurrentDefaultQueue().async { [weak self] in
            let _ = (joinPendingWelcomes(postbox: postbox, network: network, accountPeerId: accountPeerId)
            |> mapToSignal { [weak self] _ -> Signal<Void, NoError> in
                guard let self = self else {
                    return .complete()
                }
                // Read again before reading back. A message can also arrive
                // unreadable because this device has not finished loading its
                // own state yet - the first difference after a launch arrives
                // in milliseconds - and then there is no welcome to find and
                // nothing else would ever try again.
                return self.reload()
            }
            |> mapToSignal { [weak self] _ -> Signal<Int, NoError> in
                guard let self = self else {
                    return .single(0)
                }
                return repairUnreadableMessages(postbox: postbox, runtime: self, peerId: peerId)
            }
            |> deliverOn(Queue.concurrentDefaultQueue())).start(next: { [weak self] _ in
                guard let self = self else {
                    return
                }
                self.queue.lock()
                self.recovering.remove(key)
                self.queue.unlock()
            })
        }
    }

    /// Forgets a conversation that has been rebuilt, so the next message is
    /// read with the group that exists rather than the one that did.
    public func forget(peerId: PeerId) {
        self.queue.lock()
        defer { self.queue.unlock() }
        self.groups.removeValue(forKey: peerId.id._internalGetInt64Value())
    }

    /// Drops everything held and reads it again, completing when the new state
    /// is in place. Called when conversations were joined elsewhere - by the
    /// task that polls for welcomes - so the next message is read with what is
    /// on disk rather than what was in memory.
    ///
    /// It completes rather than merely starting because the caller reads
    /// messages back through these conversations as soon as it returns.
    public func reload() -> Signal<Void, NoError> {
        let postbox = self.postbox
        let accountPeerId = self.accountPeerId
        return postbox.transaction { transaction -> [Int64: Data] in
            return MlsConversationIds.load(transaction: transaction).groupIdByPeer
        }
        |> deliverOn(Queue.concurrentDefaultQueue())
        |> map { [weak self] ids -> Void in
            guard let self = self else {
                return
            }
            let identity = try? mlsIdentity(postbox: postbox, accountPeerId: accountPeerId)
            self.queue.lock()
            self.conversationIds = ids
            self.identity = identity
            self.groups.removeAll()
            self.queue.unlock()
        }
    }
}
