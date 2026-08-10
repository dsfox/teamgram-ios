import Foundation
import Postbox
import SwiftSignalKit
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

    /// Told which network to use, once, by the account that owns it.
    public func attach(network: Network) {
        self.queue.lock()
        defer { self.queue.unlock() }
        self.network = network
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
    private func group(for peerId: PeerId) -> (MlsIdentity, MlsGroup)? {
        if self.identity == nil {
            self.identity = try? mlsIdentity(postbox: self.postbox, accountPeerId: self.accountPeerId)
        }
        guard let identity = self.identity else {
            return nil
        }

        let key = peerId.id._internalGetInt64Value()
        if let group = self.groups[key] {
            return (identity, group)
        }

        var groupId: Data?
        let loaded = DispatchSemaphore(value: 0)
        let _ = (self.postbox.transaction { transaction -> Data? in
            return MlsConversationIds.load(transaction: transaction).groupIdByPeer[key]
        }).start(next: { value in
            groupId = value
            loaded.signal()
        })
        _ = loaded.wait(timeout: .now() + 2.0)

        guard let groupId = groupId, let group = try? MlsGroup.load(identity: identity, id: groupId) else {
            return nil
        }
        self.groups[key] = group
        return (identity, group)
    }

    /// What to send instead of this text, or nothing when this conversation
    /// cannot carry it - and then the message goes as it always did.
    public func encrypt(peerId: PeerId, text: String) -> String? {
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
            self.startConversation(with: peerId)
            return nil
        }
        return MlsConversations.encrypt(postbox: self.postbox, identity: identity, group: group, text: text)
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
            if groupId != nil {
                // Read from storage next time rather than remembered now: what
                // was written is what the next message must be encrypted with.
                self.groups.removeValue(forKey: key)
                self.identity = nil
            }
            self.queue.unlock()
        })
    }

    /// What this text really says, or nothing if it is not ours or cannot be
    /// read - and then what arrived is shown as it arrived, which is ugly and
    /// honest rather than an empty message.
    public func decrypt(peerId: PeerId, text: String) -> String? {
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

    public static func decryptIncoming(peerId: PeerId, text: String) -> String? {
        guard MlsConversations.isCiphertext(text) else {
            return nil
        }

        instancesLock.lock()
        let candidates = running
        instancesLock.unlock()

        for runtime in candidates {
            if let plaintext = runtime.decrypt(peerId: peerId, text: text) {
                return plaintext
            }
        }
        return nil
    }

    /// Forgets a conversation that has been rebuilt, so the next message is
    /// read with the group that exists rather than the one that did.
    public func forget(peerId: PeerId) {
        self.queue.lock()
        defer { self.queue.unlock() }
        self.groups.removeValue(forKey: peerId.id._internalGetInt64Value())
    }

    /// Drops everything held. Called when a conversation was joined or started
    /// elsewhere, so the next use reads what was written rather than what was
    /// remembered.
    public func forgetAll() {
        self.queue.lock()
        defer { self.queue.unlock() }
        self.identity = nil
        self.groups.removeAll()
    }
}
