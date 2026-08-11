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
    /// The conversations this device is in, by their own id rather than by the
    /// person they are with - because a person can be in more than one of them.
    private var groups: [String: MlsGroup] = [:]
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
            let repair: Signal<Void, NoError>
            if peers.isEmpty {
                repair = .complete()
            } else {
                repair = combineLatest(peers.map { repairUnreadableMessages(postbox: postbox, runtime: self, peerId: $0) })
                |> map { _ -> Void in }
            }
            return repair
            |> then(self.rebuildConversationsOfRecentChats())
        }).start()
    }

    /// How many recent chats a device that has just been set up rebuilds.
    ///
    /// Enough for the people somebody actually writes to, small enough that a
    /// fresh install is not a burst of requests. Everything older is rebuilt the
    /// first time a message arrives from that person, as it always was.
    private static let chatsToRebuild = 20

    /// Starts a conversation with the people this device already has chats with,
    /// when it holds none of its own.
    ///
    /// A phone that has been set up again has the chats - they come from the
    /// server - and none of the encryption behind them. Waiting for a message to
    /// notice that costs exactly one message: the one that arrives, finds no
    /// conversation, sets the rebuild going and can never be read afterwards,
    /// because the keys it was written to never existed here. That message is
    /// usually the first thing somebody says after "I got a new phone".
    ///
    /// So it is done at the start instead, from what the chat list already says.
    /// The other side takes the invitation and sends into the new conversation
    /// from then on, before there is anything to lose.
    private func rebuildConversationsOfRecentChats(attempt: Int = 0) -> Signal<Void, NoError> {
        self.queue.lock()
        let known = !self.conversationIds.isEmpty
        // Conversations written by a client that did not record when it built
        // them. Those were built by inviting the other side's devices one at a
        // time and sending only the last invitation, so most of them are
        // conversations the other phone was never let into - and there is no way
        // to tell which from here. Rebuilt once, on the first run of a client
        // that knows better, and never again: the note this looks at is written
        // by every rebuild from now on.
        let fromAnOlderClient = known && self.rebuilt.isEmpty
        let howMany = self.conversationIds.count
        let noted = self.rebuilt.count
        self.queue.unlock()
        if attempt == 0 {
            Logger.shared.log("Mls", "looking at whether to rebuild: \(howMany) conversation(s) here, \(noted) of them noted")
        }
        // Not a fresh device: it has conversations, so there is nothing here to
        // rebuild and no reason to spend a key package of anybody's.
        if known && !fromAnOlderClient {
            return .complete()
        }

        let accountPeerId = self.accountPeerId
        return self.postbox.transaction { transaction -> [PeerId] in
            return transaction.getTopChatListEntries(groupId: .root, count: MlsRuntime.chatsToRebuild)
                .compactMap { entry -> PeerId? in
                    guard entry.peerId.namespace == Namespaces.Peer.CloudUser, entry.peerId != accountPeerId else {
                        return nil
                    }
                    return entry.peerId
                }
        }
        |> mapToSignal { [weak self] peers -> Signal<Void, NoError> in
            guard let self = self else {
                return .complete()
            }
            if peers.isEmpty {
                // The chat list arrives from the server after this runs, so an
                // empty one here means "not yet" rather than "nobody". Asked
                // again a few times and then left alone: a device with no chats
                // at all is ordinary.
                // Ten minutes of asking, because the list can take a while: on a
                // phone signing in for the first time it arrives from the server
                // after everything here has already run, and a minute of trying
                // was not enough - the rebuild never happened and the first
                // messages were lost exactly as before.
                guard attempt < 20 else {
                    return .complete()
                }
                return Signal<Void, NoError>.complete()
                |> suspendAwareDelay(30.0, queue: Queue.concurrentDefaultQueue())
                |> then(self.rebuildConversationsOfRecentChats(attempt: attempt + 1))
            }
            Logger.shared.log("Mls", "rebuilding \(peers.count) recent chat(s) after \(attempt) wait(s)")
            // One after another rather than all at once: each one claims a key
            // package and leaves a welcome, and a phone that has just been set
            // up has better things to do with the first seconds of its network.
            var work: Signal<Void, NoError> = .complete()
            for peerId in peers {
                work = work |> then(self.rebuildConversation(with: peerId))
            }
            return work
        }
    }

    /// Builds a conversation with somebody whether or not there is one already.
    ///
    /// Unlike ensuring one, which stops the moment it finds any. That is right
    /// before sending and wrong here: the conversations this replaces are ones
    /// the other side was never let into, and they look exactly like healthy
    /// ones from this end.
    private func rebuildConversation(with peerId: PeerId) -> Signal<Void, NoError> {
        self.queue.lock()
        let worth = self.worthEncrypting(to: peerId)
        let network = self.network
        let identity = self.identity
        self.queue.unlock()

        guard worth, let network = network, let identity = identity else {
            return .single(Void())
        }

        let key = peerId.id._internalGetInt64Value()
        return MlsConversations.start(postbox: self.postbox, accountPeerId: self.accountPeerId, network: network, identity: identity, peerId: peerId)
        |> mapToSignal { [weak self] groupId -> Signal<Void, NoError> in
            guard let self = self else {
                return .complete()
            }
            self.queue.lock()
            if let groupId = groupId {
                self.remember(peerId: key, groupId: groupId)
                self.markRebuilt(key)
            } else {
                self.withoutDevices[key] = CFAbsoluteTimeGetCurrent()
            }
            self.queue.unlock()
            return .single(Void())
        }
        |> timeout(20.0, queue: Queue.concurrentDefaultQueue(), alternate: .single(Void()))
    }

    /// Remembers a conversation that has just been started or joined, so the
    /// next message finds it without going back to disk.
    private func remember(peerId: Int64, groupId: Data) {
        self.conversationIds[peerId] = groupId
        // The group itself is not dropped here: it is held by its own id, and a
        // conversation this device is in stays readable whoever it is now
        // sending to.
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
        guard let groupId = self.conversationIds[peerId.id._internalGetInt64Value()] else {
            return nil
        }
        return self.group(named: groupId)
    }

    /// One conversation by its own id, whoever it is with.
    ///
    /// This is what reading a message goes through: the message says which
    /// conversation it belongs to, and a device that is in it can open it. A
    /// device can be in two with the same person - one it started and one it was
    /// invited into - and both are real for as long as messages keep arriving in
    /// them.
    private func group(named groupId: Data) -> (MlsIdentity, MlsGroup)? {
        guard let identity = self.identity else {
            return nil
        }

        let key = groupId.base64EncodedString()
        if let group = self.groups[key] {
            return (identity, group)
        }
        guard let group = try? MlsGroup.load(identity: identity, id: groupId) else {
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
    public func encrypt(peerId: PeerId, text: String, entities: [Api.MessageEntity], forwarded: Api.mls.Content.Forwarded? = nil, media: Api.mls.Content.Media? = nil) -> String? {
        // An empty text is nothing to encrypt - unless something else has to
        // travel inside the message anyway: the key to a picture sent without a
        // caption, or the attribution of a forward.
        guard !text.isEmpty || forwarded != nil || media != nil else {
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
        if let groupId = self.conversationIds[peerId.id._internalGetInt64Value()] {
            Logger.shared.log("Mls", "sending to \(peerId.id._internalGetInt64Value()) in conversation \(mlsShortId(groupId))")
        }
        return MlsConversations.encrypt(postbox: self.postbox, accountPeerId: self.accountPeerId, identity: identity, group: group, text: text, entities: entities, forwarded: forwarded, media: media)
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
        return MlsConversations.start(postbox: postbox, accountPeerId: self.accountPeerId, network: network, identity: identity, peerId: peerId)
        |> mapToSignal { [weak self] groupId -> Signal<Void, NoError> in
            guard let self = self else {
                return .complete()
            }
            self.queue.lock()
            if let groupId = groupId {
                self.remember(peerId: key, groupId: groupId)
                // Counted as a rebuild wherever it happened, so that a message
                // which will not open a moment later does not start another one.
                self.markRebuilt(key)
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
        let _ = (MlsConversations.start(postbox: postbox, accountPeerId: self.accountPeerId, network: network, identity: identity, peerId: peerId)
        |> deliverOn(Queue.concurrentDefaultQueue())).start(next: { [weak self] groupId in
            guard let self = self else {
                return
            }
            self.queue.lock()
            self.starting.remove(key)
            if let groupId = groupId {
                self.remember(peerId: key, groupId: groupId)
                self.markRebuilt(key)
            } else {
                self.withoutDevices[key] = CFAbsoluteTimeGetCurrent()
            }
            self.queue.unlock()
        })
    }

    /// What has already been read, by the ciphertext it came in.
    ///
    /// A message can reach this device twice - once as an update and once when
    /// the history around it is fetched - and each arrival is parsed on its own.
    /// MLS spends a secret to open a message and refuses to spend it twice, so
    /// the second attempt fails with `SecretReuseError` and stores a lock over
    /// the text the first one had just recovered. Reading is therefore
    /// remembered, and a ciphertext is only ever opened once.
    private var opened: [String: MlsMessageContent] = [:]
    private var openedOrder: [String] = []

    private func remember(_ text: String, _ content: MlsMessageContent) {
        self.opened[text] = content
        self.openedOrder.append(text)
        // Bounded: this is a way of not asking twice, not a copy of the chat.
        while self.openedOrder.count > 256 {
            let oldest = self.openedOrder.removeFirst()
            self.opened.removeValue(forKey: oldest)
        }
    }

    /// What this text really says, or nothing if it is not ours or cannot be
    /// read - and then the caller puts the ciphertext aside and comes back to it.
    public func decrypt(peerId: PeerId, text: String) -> MlsMessageContent? {
        return self.read(peerId: peerId, text: text).content
    }

    /// The same, with the reason kept - which the caller needs before deciding
    /// that a conversation has to be rebuilt.
    func read(peerId: PeerId, text: String) -> MlsConversations.Reading {
        guard MlsConversations.isCiphertext(text) else {
            return .nothing
        }

        self.queue.lock()
        defer { self.queue.unlock() }

        if let already = self.opened[text] {
            return .content(already)
        }

        // The conversation the message names, not the one kept for the person
        // who sent it. Those differ for as long as it takes a welcome to cross
        // after a reinstall, and reading with the wrong one fails for ever:
        // MLS answers `ValidationError(WrongGroupId)`, the text never appears,
        // and nothing about it ever changes.
        //
        // An older message from before the group id travelled, or one this
        // device cannot parse, falls back to the conversation kept for the
        // sender - which is what this always did.
        let found: (MlsIdentity, MlsGroup)?
        if let named = MlsConversations.conversation(ofCiphertext: text) {
            found = self.group(named: named)
            if found == nil {
                // Worth saying plainly: this device is not in the conversation
                // the message was written in, so nothing here can ever open it.
                // It is the shape a reinstall leaves, and the answer is a
                // conversation rebuilt rather than another attempt.
                Logger.shared.log("Mls", "a message from \(peerId.id._internalGetInt64Value()) is in conversation \(mlsShortId(named)), which this device is not in")
            }
        } else {
            found = self.group(for: peerId)
        }
        guard let (identity, group) = found else {
            return .unreadable
        }
        let reading = MlsConversations.decrypt(postbox: self.postbox, accountPeerId: self.accountPeerId, identity: identity, group: group, text: text)
        if case let .content(content) = reading {
            self.remember(text, content)
        }
        return reading
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

    /// Who wrote a message first, in the shape the encrypted payload carries -
    /// or nothing when this is not a forward.
    ///
    /// The id when it is known, the name when the account is hidden and a name
    /// is all there is to show.
    public static func forwarded(from message: Message) -> Api.mls.Content.Forwarded? {
        guard let info = message.forwardInfo else {
            return nil
        }
        return Api.mls.Content.Forwarded(
            authorId: info.author?.id.id._internalGetInt64Value() ?? 0,
            authorName: info.author?.debugDisplayTitle ?? info.authorSignature ?? "",
            date: info.date)
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

        var writtenHere = false
        for runtime in candidates {
            switch runtime.read(peerId: peerId, text: text) {
            case let .content(content):
                return content
            case .writtenHere:
                writtenHere = true
            case .nothing, .unreadable:
                break
            }
        }

        // This device wrote it, so of course it cannot read it back - MLS gives
        // a sender no way to. Nothing is wrong and nothing needs rebuilding.
        //
        // Believing otherwise cost the whole evening: every message anybody sent
        // came back from the server, failed to open here, and was taken as proof
        // that the conversation was broken. The client then built another one
        // and invited the other side into it - after every message, on both
        // sides, for ever.
        if writtenHere {
            return nil
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

    /// When a conversation with somebody was last rebuilt from this side.
    ///
    /// A device that has just been set up again cannot read anything that was
    /// sent before it existed, and no new conversation will change that - the
    /// keys those messages were written to never reached this phone. Without
    /// this, every one of those old messages started another conversation: two
    /// were built four tenths of a second apart in the first clean run of the
    /// reinstall scenario, each with its own welcome and its own key package
    /// taken from the other side. A chat with a hundred messages behind it would
    /// have built a hundred.
    /// Read from disk with the conversations, so that restarting the app does
    /// not make this device forget it has just rebuilt and do it again. Seconds
    /// since 1970, like everything else that is written down.
    private var rebuilt: [Int64: Int32] = [:]

    private func markRebuilt(_ key: Int64) {
        self.rebuilt[key] = Int32(Date().timeIntervalSince1970)
    }

    /// How long a rebuilt conversation is given before this side will build
    /// another. Long enough that the old messages of one chat are done with,
    /// short enough that a real second failure is still repaired within a few
    /// minutes.
    private static let betweenRebuilds: Double = 600.0

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
            |> mapToSignal { [weak self] repaired -> Signal<Int, NoError> in
                guard let self = self, repaired == 0 else {
                    return .single(repaired)
                }
                // Still unreadable, and no welcome explains it. The conversation
                // the other side is encrypting to is one this device is not in
                // and will never be invited to again - their client sees a
                // conversation and sends into it, this one can only wait, and
                // the two never meet. It has to be started over, and only this
                // side knows anything is wrong.
                //
                // Starting it here means creating a group and inviting them:
                // their client replaces theirs with it when the welcome
                // arrives, so both ends converge on this one.
                self.queue.lock()
                let identity = self.identity
                let lastRebuild = self.rebuilt[key]
                self.queue.unlock()
                guard let identity = identity else {
                    return .single(0)
                }
                if let lastRebuild = lastRebuild, Date().timeIntervalSince1970 - Double(lastRebuild) < MlsRuntime.betweenRebuilds {
                    // Already rebuilt, and still unreadable - so this message is
                    // older than the rebuild and always will be. Another
                    // conversation would not open it and would cost the other
                    // side a key package to say so.
                    return .single(0)
                }

                Logger.shared.log("Mls", "no welcome explains an unreadable message from \(peerId), so starting the conversation again")
                return MlsConversations.start(postbox: postbox, accountPeerId: self.accountPeerId, network: network, identity: identity, peerId: peerId)
                |> mapToSignal { [weak self] groupId -> Signal<Int, NoError> in
                    guard let self = self, let groupId = groupId else {
                        return .single(0)
                    }
                    self.queue.lock()
                    self.remember(peerId: peerId.id._internalGetInt64Value(), groupId: groupId)
                    self.markRebuilt(key)
                    self.queue.unlock()
                    return .single(0)
                }
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

    /// Takes a conversation that was just joined, at once and without waiting
    /// for anything else.
    ///
    /// The welcome poll writes the conversation down and then reloads
    /// everything, and until that reload lands this device goes on sending in
    /// the conversation it had before - which after a reinstall is one the other
    /// side is no longer in. It was measured: the two phones only agreed after
    /// the app was restarted, because a restart is what reads the note back.
    /// Nothing about a message that will not open should depend on a signal
    /// chain finishing.
    public func adopt(peerId: PeerId, groupId: Data) {
        self.queue.lock()
        self.conversationIds[peerId.id._internalGetInt64Value()] = groupId
        self.markRebuilt(peerId.id._internalGetInt64Value())
        self.queue.unlock()

        // Written down here as well, on its own, rather than by whatever chain
        // happened to be running. It was written by the chain, and the chain did
        // not always get that far: the conversation was live in memory, the app
        // was restarted, and the device came back knowing nothing about it - so
        // it built another one and the two sides diverged again. Twice in one
        // evening, and both times it looked like the join had failed.
        let _ = (self.postbox.transaction { transaction -> Void in
            MlsConversationIds.remember(transaction: transaction, peerId: peerId, groupId: groupId)
        }).start()
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
        return postbox.transaction { transaction -> MlsConversationIds in
            return MlsConversationIds.load(transaction: transaction)
        }
        |> deliverOn(Queue.concurrentDefaultQueue())
        |> map { [weak self] stored -> Void in
            guard let self = self else {
                return
            }
            let identity = try? mlsIdentity(postbox: postbox, accountPeerId: accountPeerId)
            self.queue.lock()
            self.conversationIds = stored.groupIdByPeer
            self.rebuilt = stored.rebuiltAtByPeer
            self.identity = identity
            self.groups.removeAll()
            self.queue.unlock()
        }
    }
}
