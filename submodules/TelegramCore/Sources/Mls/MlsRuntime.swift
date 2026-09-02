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
    /// Where a result is handed back once it has left the database's thread.
    ///
    /// Serial, and that is the whole of it. `deliverOn` puts the value and the
    /// completion that follows it on the queue as two separate pieces of work,
    /// so on a *concurrent* queue the completion can overtake the value: the
    /// subscriber is finished before the value reaches it, and `putNext` on a
    /// finished subscriber does nothing and says nothing. It is not a rare race
    /// - it happens whenever whatever receives the value takes a moment, and
    /// reading this device's state back takes a couple of hundred milliseconds,
    /// so it happened every time.
    ///
    /// That is the second half of #144. `reload()` completed without ever
    /// emitting, so nothing hanging off it ever ran: not the pass over stored
    /// messages at startup, not the one behind a welcome, not the one behind a
    /// commit. A message that arrived before the conversation it was written in
    /// stayed sealed for good, and the log said nothing at all, because none of
    /// that code was reached.
    private static let results = Queue(name: "MlsRuntimeResults")
    private let postbox: Postbox
    private let accountPeerId: PeerId
    private var identity: MlsIdentity?
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
            let peers = self.conversationIds.keys.map { PeerId.fromMlsKey($0) }
            self.queue.unlock()
            Logger.shared.log("Mls", "at startup: \(peers.count) conversation(s) to read back")
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

        let key = peerId.mlsKey
        return MlsConversations.start(postbox: self.postbox, accountPeerId: self.accountPeerId, network: network, identity: identity, peerId: peerId)
        |> mapToSignal { [weak self] groupId -> Signal<Void, NoError> in
            guard let self = self else {
                return .complete()
            }
            self.queue.lock()
            if let groupId = groupId {
                self.remember(key: key, groupId: groupId)
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
    /// Takes the filing key rather than the peer, because every caller has
    /// already worked it out - and calling it peerId, as this did, made it look
    /// like one and got `.mlsKey` applied to it twice.
    private func remember(key: Int64, groupId: Data) {
        self.conversationIds[key] = groupId
        // Now, by the server's clock: this was built or joined a moment ago, so
        // no message older than this moment may move the chat out of it (#155).
        self.learntAt[key] = Int32(self.network?.globalTime ?? Date().timeIntervalSince1970)
        MlsRuntime.publishEncrypted([key])
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
        guard let groupId = self.conversationIds[peerId.mlsKey] else {
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
    /// Loaded afresh every time, and deliberately not kept.
    ///
    /// A loaded group is a copy of the state, not a window onto it: a change
    /// made through one handle is invisible to every other, for ever. Keeping
    /// one meant that when the conversation was replaced underneath - which is
    /// what rejoining is, because a welcome forgets the old group and builds a
    /// new one - the copy in hand went on being the group from before. A device
    /// let back in read every message with the state it had when it was thrown
    /// out and said `WrongEpoch` about messages written where it was now
    /// standing, until something restarted the client (#117).
    ///
    /// The cache saved a deserialisation per message and cost a correct answer.
    /// Android has always loaded one per operation and closed it, and this is
    /// now the same shape. `a_loaded_conversation_is_a_copy_and_not_a_window`
    /// in the core holds the property this rests on.
    private func group(named groupId: Data) -> (MlsIdentity, MlsGroup)? {
        guard let identity = self.identity else {
            return nil
        }
        guard let group = try? MlsGroup.load(identity: identity, id: groupId) else {
            return nil
        }
        return (identity, group)
    }

    /// Whether it makes any sense to encrypt to this peer at all.
    ///
    /// A conversation between two people, or a group - which is an MLS group
    /// of n, and what MLS was built for. The protocol does not care whether a
    /// leaf belongs to a second person or to a second phone of the first (#40).
    ///
    /// A channel is not one: broadcasting is a different thing and none of it
    /// is built (#16).
    ///
    /// Saved Messages is excluded for a harder reason: a conversation with
    /// oneself would be one where every message is written by the only person
    /// who cannot read it back, and the notes would go in unreadable.
    private func worthEncrypting(to peerId: PeerId) -> Bool {
        let isPerson = peerId.namespace == Namespaces.Peer.CloudUser && peerId != self.accountPeerId
        let isGroup = peerId.namespace == Namespaces.Peer.CloudGroup
        guard isPerson || isGroup else {
            return false
        }
        // Somebody with no device published - not updated yet, or a bot. Asked
        // about again after a while rather than before every message.
        if let asked = self.withoutDevices[peerId.mlsKey],
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
        if let groupId = self.conversationIds[peerId.mlsKey] {
            Logger.shared.log("Mls", "sending to \(peerId.id._internalGetInt64Value()) in conversation \(mlsShortId(groupId)) at epoch \(group.epoch)")
        }
        // The comparison with the chat that used to be kicked off here, beside
        // the send, runs before it now - in ensureConversation, which is the
        // step ahead of this one on the same path (#158).
        return MlsConversations.encrypt(postbox: self.postbox, accountPeerId: self.accountPeerId, identity: identity, group: group, text: text, entities: entities, forwarded: forwarded, media: media)
    }

    /// When each conversation was last compared with its chat.
    private var comparedAt: [Int64: Double] = [:]

    /// How long to leave between two comparisons of one conversation. Short,
    /// because a change that waits is a change that has not happened; long
    /// enough that a burst of messages does not open the group each time.
    private static let compareNotBefore: Double = 5.0

    /// How long a message may wait for that comparison before it goes anyway.
    /// One round trip and at most one commit, so half the handshake's ten
    /// seconds; past it the message goes as it would have, because a message
    /// that never leaves is worse than one somebody cannot open.
    private static let comparisonWait: Double = 5.0

    /// Compares the conversation with the chat, additively, before a message
    /// goes out - and completes only when the comparison has, so the message
    /// is encrypted at the epoch that holds everybody the chat does.
    ///
    /// Before rather than beside: on 2 September a message went out 109 ms
    /// ahead of the add that let a reinstalled phone in, and that phone holds
    /// it as ciphertext for ever (#158). Within the interval it completes at
    /// once, so a burst of messages pays the round trip once. Called with the
    /// lock held; the work itself runs off this thread.
    private func compareMembershipFirst(with peerId: PeerId) -> Signal<Void, NoError> {
        let key = peerId.mlsKey
        let now = CFAbsoluteTimeGetCurrent()
        if let last = self.comparedAt[key], now - last < MlsRuntime.compareNotBefore {
            return .single(Void())
        }
        self.comparedAt[key] = now
        // A group, and a chat between two - whose membership does not change
        // but whose devices do, which is what this has been about since #142.
        guard peerId.namespace == Namespaces.Peer.CloudGroup || peerId.namespace == Namespaces.Peer.CloudUser,
              let network = self.network else {
            return .single(Void())
        }
        let postbox = self.postbox
        let accountPeerId = self.accountPeerId
        // Off this thread, explicitly: everything below takes the lock again.
        return (Signal<Void, NoError> { subscriber in
            return reconcileMembership(
                postbox: postbox, accountPeerId: accountPeerId, network: network,
                peerId: peerId, listIsFromTheServer: false, named: NamedInTheMessage()
            ).start(completed: {
                subscriber.putNext(Void())
                subscriber.putCompletion()
            })
        }
        |> runOn(Queue.concurrentDefaultQueue())
        |> timeout(MlsRuntime.comparisonWait, queue: Queue.concurrentDefaultQueue(), alternate: .single(Void())))
    }

    /// The network, for the entry points that are called without the lock. Taken
    /// and let go at once, because the lock is not one that can be taken twice
    /// and everything below it runs on another thread anyway.
    private func networkOutsideTheLock() -> Network? {
        self.queue.lock()
        defer { self.queue.unlock() }
        return self.network
    }

    /// Somebody has just been named as joining a chat, by the message every
    /// member of it gets.
    ///
    /// Named rather than worked out by comparison, and that is the whole point:
    /// this arrives before the participant list here catches up, so a comparison
    /// made now finds nobody missing and the newcomer waits for a sweep. It is
    /// what left the first person who followed a link into an encrypted group
    /// sitting in silence (#40, 4.3).
    ///
    /// Every member tries. Whoever wins the epoch makes the change; the rest
    /// find the person already in and stop.
    public func memberAdded(peerId: PeerId, userIds: [PeerId]) {
        let newcomers = userIds.filter { $0 != self.accountPeerId }
        guard !newcomers.isEmpty else {
            // Somebody let us in. We cannot add ourselves to an MLS group; the
            // welcome is on its way from whoever did.
            return
        }
        self.changeMembership(of: peerId, over: self.networkOutsideTheLock(), named: NamedInTheMessage(joined: newcomers))
    }

    /// Somebody has just been named as leaving or being removed.
    ///
    /// The dangerous direction, and the reason this is not left to a comparison:
    /// a removal that waits is a removal that has not happened, and what it
    /// leaves behind is a device reading a conversation it is not in, for as
    /// long as anybody keeps talking, with nothing on any screen to say so.
    public func memberRemoved(peerId: PeerId, userIds: [PeerId]) {
        let leaving = userIds.filter { $0 != self.accountPeerId }
        guard !leaving.isEmpty else {
            // Ourselves. There is nothing to commit: the group is left behind
            // with the chat, and a device that removed itself would hold a
            // conversation it could no longer read or repair.
            return
        }
        self.changeMembership(of: peerId, over: self.networkOutsideTheLock(), named: NamedInTheMessage(gone: leaving))
    }

    /// Runs something that moves this device's encryption state, one at a time,
    /// and writes down what it did.
    ///
    /// The state is one blob: every operation reads all of it, changes a little
    /// and writes all of it back. Two of those at once and the later writer
    /// erases what the earlier one moved - which arrives as `SecretReuseError`
    /// and, on a screen, as a message that never opens (#112).
    ///
    /// The answer is one copy and one way to it. Everything that used to read
    /// its own copy out of storage now borrows this one, so there is nothing
    /// left to disagree with. Android settled on the same shape: one lock,
    /// owned by whoever owns the state.
    ///
    /// Never held across a network call. Every caller does its cryptography,
    /// returns, and only then goes to the server - a lock held for a round trip
    /// stops every other conversation for the length of it.
    ///
    /// Returns nothing when this device has no state yet, which is a client
    /// that has not finished starting rather than an error: the collectors run
    /// on a rhythm and the next round finds it.
    public func withState<T>(_ body: (MlsIdentity) throws -> T) -> T? {
        self.queue.lock()
        defer { self.queue.unlock() }
        guard let identity = self.identity else {
            return nil
        }
        let result: T
        do {
            result = try body(identity)
        } catch {
            Logger.shared.log("Mls", "a change to the state did not happen: \(error)")
            return nil
        }
        // Written back here rather than by the caller, because a caller that
        // forgets is a ratchet that moved in memory and not on disk - and what
        // is lost then is the ability to read.
        if let state = try? identity.export() {
            MlsStateWriter.instance(accountPeerId: self.accountPeerId).write(postbox: self.postbox, state: state)
        }
        return result
    }

    /// How many devices of this account have published anything, as the server
    /// last said.
    ///
    /// The one thing that tells this phone another phone of the same person has
    /// signed in. Comparing a conversation with its chat is about people - a
    /// leaf is named `<user>/<device>` and everything reads the part before the
    /// slash - so a second device of somebody already in it is invisible there.
    /// It is what left a phone signed in beside another one reading nothing but
    /// padlocks (#41).
    ///
    /// Zero means nobody has asked the server yet, and nothing is concluded.
    private var deviceCount: Int32 = 0

    public func noteDevices(_ count: Int32) {
        self.queue.lock()
        let known = self.deviceCount
        self.deviceCount = count
        let conversations = self.conversationIds.keys.map { PeerId.fromMlsKey($0) }
        let network = self.network
        self.queue.unlock()
        guard let network = network else {
            return
        }
        if known > 0 && count < known {
            Logger.shared.log("Mls", "a device of this account is gone")
        }
        // Every time the count is known, and not only when it has just fallen.
        //
        // The trend lives in memory: a phone restarted after the other one was
        // signed out starts from nothing, reads "one device" as a rise, and
        // never looks. It was measured that way - the leaf stayed and the epoch
        // did not move. The pass itself needs no trend, because it compares
        // leaves against the count, so it is asked every time and costs nothing
        // when there is nothing to do (#41).
        do {
            let postbox = self.postbox
            let accountPeerId = self.accountPeerId
            Queue.concurrentDefaultQueue().async {
                let _ = takeOutMyLostDevices(
                    postbox: postbox, accountPeerId: accountPeerId, network: network).start()
            }
        }
        self.slowRound(conversations: conversations, network: network)
        guard count > known else {
            return
        }
        Logger.shared.log("Mls", "this account now has \(count) device(s)")
        // At once, rather than at whatever happens next. The count going up is a
        // phone that has just signed in, and the person holding the old one is
        // watching the new one show padlocks.
        //
        // Every conversation, not only groups: a chat between two is an MLS
        // group of two and the new phone is as absent from it.
        let postbox = self.postbox
        let accountPeerId = self.accountPeerId
        Queue.concurrentDefaultQueue().async {
            for peerId in conversations {
                let _ = reconcileMembership(
                    postbox: postbox, accountPeerId: accountPeerId, network: network,
                    peerId: peerId, listIsFromTheServer: false).start()
            }
        }
    }

    /// The half of a round that does not have to be quick.
    ///
    /// Kept apart from noteDevices' own work on purpose. That is asked every
    /// half minute, because a phone signed out goes on reading until the count
    /// is asked again (#121) - and the two passes below are a request per group
    /// and a piece of cryptography per conversation, for things that change in
    /// hours or once in the life of an install. Every half minute they would be
    /// waste.
    private func slowRound(conversations: [PeerId], network: Network) {
        guard self.onTheSlowRound() else {
            return
        }
        let postbox = self.postbox
        let accountPeerId = self.accountPeerId
        Queue.concurrentDefaultQueue().async {
            // The leaves that belong to nobody at all, which no comparison can
            // claim and no owner will come for (#122).
            let _ = takeOutLeavesThatBelongToNobody(
                postbox: postbox, accountPeerId: accountPeerId, network: network).start()
        }
        // And whatever changed while this phone was not running, which no update
        // will ever tell it about (#124).
        self.catchUpOnMembership(conversations: conversations, network: network)
    }

    /// Asks for the membership of every group this device holds a conversation
    /// for.
    ///
    /// A change that happened while the app was not running never arrives as an
    /// update - it is already in the history by then - and the hook that acts on
    /// membership hangs on updates. So somebody who joined by a link while the
    /// phone was off stayed outside the conversation: in the chat, and in a chat
    /// where nothing would ever appear for them. The other direction is worse:
    /// somebody removed while the phone was off keeps reading (#124).
    ///
    /// Asking for the chat is enough. The answer carries the participant list,
    /// and the comparison already runs when one arrives - which is also why this
    /// is a request rather than a second copy of that logic.
    ///
    /// On every round rather than once at the start, and the Android half was
    /// measured into that shape: the change this is for does not only happen
    /// while the app is down, it also happens while the app is up and the update
    /// never arrives - a phone running, connected, publishing on its rhythm, and
    /// never told that somebody had followed a link into its group. Asking on
    /// each round bounds that at one round rather than for ever.
    ///
    /// Groups only, and for a narrower reason than the sentence that used to
    /// stand here. "A chat between two never changes who is in it" was true of
    /// the participant list and false of everything that was hung on it: how
    /// many devices those two have does change, which is what the comparison is
    /// for and why it covers such a chat as well (#142, `worthComparing`). What
    /// is groups-only is this request - the participant list of a chat of two
    /// cannot differ from one round to the next, so asking for it every round
    /// would buy nothing.
    /// How long to leave between two slow rounds.
    ///
    /// There are two rhythms now and they answer different questions. The count
    /// of this account's devices is asked every half minute, because between
    /// asking and asking again a phone that was signed out goes on reading
    /// (#121) - and the pass that acts on it is a count against a list of leaf
    /// names, which costs nothing.
    ///
    /// The rest is not like that. Asking the server for every group's
    /// participant list, and opening every conversation's state to look for a
    /// leaf that belongs to nobody, are a request per group and a piece of
    /// cryptography per conversation. Every half minute they would be waste:
    /// what they look for changes in hours, or once in the life of an install.
    ///
    /// Four minutes, which is Android's round. The two halves are meant to be
    /// twins and were not - iOS asked every quarter of an hour, so a change lost
    /// on iOS was lost for four times as long (#124).
    private static let slowRoundNotBefore: Double = 4 * 60
    private var slowRoundAt: Double = 0

    /// Whether enough time has passed for the slow half of a round, and marks it
    /// as taken when it has.
    private func onTheSlowRound() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        self.queue.lock()
        defer { self.queue.unlock() }
        if self.slowRoundAt > 0 && now - self.slowRoundAt < MlsRuntime.slowRoundNotBefore {
            return false
        }
        self.slowRoundAt = now
        return true
    }

    private func catchUpOnMembership(conversations: [PeerId], network: Network) {
        let groups = conversations.filter { $0.namespace == Namespaces.Peer.CloudGroup }
        // Counted out loud. Without it a pass over an empty list and a pass that
        // was never called read exactly the same from the log, which is where an
        // evening went on the Android side.
        Logger.shared.log("Mls", "asking for the membership of \(groups.count) group(s)")
        guard !groups.isEmpty else {
            return
        }
        let postbox = self.postbox
        let accountPeerId = self.accountPeerId
        Queue.concurrentDefaultQueue().async {
            for peerId in groups {
                let _ = _internal_fetchAndUpdateCachedPeerData(
                    accountPeerId: accountPeerId, peerId: peerId,
                    network: network, postbox: postbox).start()
            }
        }
    }

    public func devices() -> Int32 {
        self.queue.lock()
        defer { self.queue.unlock() }
        return self.deviceCount
    }

    /// How long to leave between asking again for invitations, and how many
    /// times.
    ///
    /// The invitation is not there when the service message arrives. Joining a
    /// chat and joining its conversation are two different things done by two
    /// different machines: whoever added you has still to claim your key
    /// packages, build the commit, hear from the delivery service that it was
    /// taken, and only then post the welcome. Asking once, as the message lands,
    /// is asking before it exists.
    ///
    /// Without this the box is only read on its own half-minute rhythm, which is
    /// a person joining a group and watching nothing appear for as long as that
    /// takes. The cost is a handful of small requests per membership change.

    /// Somebody joined a chat, and if it was this account there is an invitation
    /// waiting on the server this second.
    public func invited() {
        self.boxHasSomething()
    }

    /// The server says there is a commit or a welcome waiting - fetch both, once
    /// (#156).
    ///
    /// Once, not on a ladder of delays. This used to guess when a welcome had
    /// been posted and ask again four times, further apart each time, because
    /// nothing told it (#110). Now updateMlsMailbox tells it the moment
    /// mls.sendWelcome or mls.sendCommit runs, so the one fetch lands on
    /// something. It is still safe against a dropped push: a message that will
    /// not open triggers a catch-up of its own, and a fetch on the next start.
    ///
    /// Both boxes, because a change of membership leaves a commit for those
    /// already in and a welcome for whoever was added, and one push covers both.
    public func boxHasSomething() {
        guard let network = self.networkOutsideTheLock() else {
            return
        }
        let postbox = self.postbox
        let accountPeerId = self.accountPeerId
        Logger.shared.log("Mls", "the server says the box has something; fetching")

        let _ = (joinPendingWelcomes(postbox: postbox, network: network, accountPeerId: accountPeerId)
        |> mapToSignal { [weak self] joined -> Signal<Void, NoError> in
            guard let self = self, !joined.isEmpty else {
                return .complete()
            }
            return combineLatest(joined.map { repairUnreadableMessages(postbox: postbox, runtime: self, peerId: $0) })
            |> map { _ -> Void in Void() }
        }
        |> then(catchUpWithTheGroup(postbox: postbox, network: network, accountPeerId: accountPeerId))
        |> deliverOn(MlsRuntime.results)).start()
    }

    /// The common half: off this thread, with a copy of the state read from
    /// storage rather than the one held here.
    private func changeMembership(of peerId: PeerId, over network: Network?, named: NamedInTheMessage) {
        guard peerId.namespace == Namespaces.Peer.CloudGroup, let network = network else {
            return
        }
        let postbox = self.postbox
        let accountPeerId = self.accountPeerId
        // Off this thread on purpose, and explicitly: this is called from
        // encrypt(), which holds the lock, and everything below takes it again.
        // A signal that starts on the caller's thread would take it there.
        Queue.concurrentDefaultQueue().async {
            let _ = reconcileMembership(
                postbox: postbox, accountPeerId: accountPeerId, network: network,
                peerId: peerId, listIsFromTheServer: false, named: named).start()
        }
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
        // Before a message goes out is the moment worth checking that the
        // conversation still holds the people the chat does: it is the one
        // moment where being wrong is about to matter (#158).
        let compared: Signal<Void, NoError>? = haveGroup ? self.compareMembershipFirst(with: peerId) : nil
        self.queue.unlock()

        // A value, then completion. Returning only completion is what broke
        // sending outright: the step after this one runs on a value, so a
        // signal that merely completes stops the message before it is built,
        // and the spinner turns for ever with nothing to explain it.
        if let compared = compared {
            return compared
        }
        if !worth {
            return .single(Void())
        }
        guard let network = network, let identity = identity else {
            return .single(Void())
        }

        let key = peerId.mlsKey
        let postbox = self.postbox
        return MlsConversations.start(postbox: postbox, accountPeerId: self.accountPeerId, network: network, identity: identity, peerId: peerId)
        |> mapToSignal { [weak self] groupId -> Signal<Void, NoError> in
            guard let self = self else {
                return .complete()
            }
            self.queue.lock()
            if let groupId = groupId {
                self.remember(key: key, groupId: groupId)
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
        let key = peerId.mlsKey
        guard !self.starting.contains(key), let network = self.network, let identity = self.identity else {
            return
        }
        self.starting.insert(key)

        let postbox = self.postbox
        let _ = (MlsConversations.start(postbox: postbox, accountPeerId: self.accountPeerId, network: network, identity: identity, peerId: peerId)
        |> deliverOn(MlsRuntime.results)).start(next: { [weak self] groupId in
            guard let self = self else {
                return
            }
            self.queue.lock()
            self.starting.remove(key)
            if let groupId = groupId {
                self.remember(key: key, groupId: groupId)
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
    ///
    /// - Parameter at: the date on the message, by the server's clock. It is
    ///   what decides whether this message may move the chat to the conversation
    ///   it names, because that must only ever happen forwards (#155).
    func read(peerId: PeerId, text: String, at: Int32) -> MlsConversations.Reading {
        guard MlsConversations.isCiphertext(text) else {
            return .nothing
        }
        let (reading, toAdopt) = self.readHoldingTheLock(peerId: peerId, text: text, at: at)
        // Outside the lock, which is the whole point of the split: adopt() takes
        // that lock, and it is not one that can be taken twice. Taking it from
        // inside stopped the thread that had just opened a message - and with it
        // every other conversation, because they all queue behind this one lock.
        //
        // It cost an afternoon and looked like anything but a deadlock: the
        // message stayed a padlock on the screen while the log said it had been
        // opened, the accessibility tree came back empty, and taps stopped
        // landing. The first message a device ever opened was the last thing it
        // did.
        if let groupId = toAdopt {
            self.adopt(peerId: peerId, groupId: groupId, learntAt: at)
        }
        return reading
    }

    /// The reading itself, and the conversation this chat turns out to belong
    /// to when that is news - which the caller acts on once the lock is gone.
    private func readHoldingTheLock(peerId: PeerId, text: String, at: Int32) -> (MlsConversations.Reading, Data?) {
        self.queue.lock()
        defer { self.queue.unlock() }

        if let already = self.opened[text] {
            return (.content(already), nil)
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
        let named = MlsConversations.conversation(ofCiphertext: text)

        // Which conversation this chat belongs to, learnt from the message
        // rather than from the welcome.
        //
        // A welcome says who sent it and nothing else. That is enough for a
        // conversation between two and wrong for a group: the joiner would
        // record the group against the person who invited them, and their own
        // first message into the chat would find no conversation and start a
        // second group for the same chat. Every message carries its group id in
        // the clear, so a message says which chat it belongs to - and this is
        // the only place both facts are known at once (#40).
        //
        // Decided before the message is opened rather than after, because the
        // message this matters for is the one that will not open: the one from
        // a conversation this device does not know it is meant to be in.
        // Reading the id needs no key. Asked after opening, it only ever
        // confirmed what was already right, and the device that most needed
        // telling was never told (#155).
        //
        // Forwards only. See learntAt.
        var toAdopt: Data? = nil
        if let named, self.conversationIds[peerId.mlsKey] != named {
            if at >= (self.learntAt[peerId.mlsKey] ?? 0) {
                toAdopt = named
            } else {
                Logger.shared.log("Mls", "a message in \(mlsShortId(named)) is older than what named this chat's conversation, leaving it be")
            }
        }

        let found: (MlsIdentity, MlsGroup)?
        if let named {
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
            return (.unreadable, toAdopt)
        }
        let reading = MlsConversations.decrypt(postbox: self.postbox, accountPeerId: self.accountPeerId, identity: identity, group: group, text: text)
        if case let .content(content) = reading {
            self.remember(text, content)
            // Said as plainly as the failures are, and for the same reason:
            // until now the log could only show that a message did not open,
            // so "it worked" had to be read off a screen by a person. A test
            // that drives two simulators can count these. No text is written
            // out - only that something opened, from whom, and where.
            if let groupId = try? group.id {
                Logger.shared.log("Mls", "opened a message from \(peerId.id._internalGetInt64Value()) in conversation \(mlsShortId(groupId))")
            }
        }
        return (reading, toAdopt)
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
        encryptedPeersLock.lock()
        defer { encryptedPeersLock.unlock() }
        return encryptedPeers.contains(peerId.mlsKey)
    }

    /// Everybody talked to in private, for the search that has to look at all of
    /// them at once rather than at one chat.
    public static func encryptedPeerIds() -> [PeerId] {
        encryptedPeersLock.lock()
        let peers = encryptedPeers
        encryptedPeersLock.unlock()
        return peers.map { PeerId.fromMlsKey($0) }
    }

    /// Everybody any account on this device holds a conversation with.
    ///
    /// A copy of what the runtimes know, behind a lock of its own, because the
    /// question is now asked for every single message written into the database
    /// - it decides whether the words go into the search index. Asking the
    /// runtimes themselves would mean taking the lock a message is opened under,
    /// from inside the transaction that stores that message.
    ///
    /// It only ever grows within a run. A conversation is never given up while
    /// the app is running, and an account signed out leaves ids behind that
    /// belong to nobody until the next launch - which costs a chat being indexed
    /// for search that nobody can open anyway.
    private static let encryptedPeersLock = NSLock()
    private static var encryptedPeers: Set<Int64> = []

    /// Says that these people are talked to in private now. Called with `queue`
    /// held, and takes no other lock than its own.
    private static func publishEncrypted<S: Sequence>(_ peers: S) where S.Element == Int64 {
        encryptedPeersLock.lock()
        encryptedPeers.formUnion(peers)
        encryptedPeersLock.unlock()
    }

    /// - Parameter at: the date on the message, which decides whether it may
    ///   move the chat to the conversation it names. See `read`.
    public static func decryptIncoming(peerId: PeerId, text: String, at: Int32) -> MlsMessageContent? {
        guard MlsConversations.isCiphertext(text) else {
            return nil
        }

        instancesLock.lock()
        let candidates = running
        instancesLock.unlock()

        var writtenHere = false
        for runtime in candidates {
            switch runtime.read(peerId: peerId, text: text, at: at) {
            case let .content(content):
                return content
            case .writtenHere:
                writtenHere = true
            case .nothing, .unreadable, .writtenBeforeThisDeviceCouldRead:
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

    /// How new the thing that taught us each note was, by the server's clock.
    /// See MlsConversationIds.learntAtByPeer, which is where it is kept.
    private var learntAt: [Int64: Int32] = [:]

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
        let key = peerId.mlsKey
        guard !self.recovering.contains(key), let network = self.network else {
            let already = self.recovering.contains(key)
            self.queue.unlock()
            // The other way the repair never runs at all. Silent, it reads from
            // the log exactly like a repair that ran and found nothing.
            Logger.shared.log("Mls", "not going back for \(peerId.id._internalGetInt64Value()): \(already ? "one is already running" : "no network yet")")
            return
        }
        self.recovering.insert(key)
        self.queue.unlock()
        Logger.shared.log("Mls", "going back for what \(peerId.id._internalGetInt64Value()) could not open")

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
            |> mapToSignal { [weak self] _ -> Signal<MlsRepair, NoError> in
                guard let self = self else {
                    return .single(MlsRepair(repaired: 0, inTheSendersConversation: false))
                }
                return repairUnreadableMessages(postbox: postbox, runtime: self, peerId: peerId)
            }
            |> mapToSignal { [weak self] repair -> Signal<Int, NoError> in
                guard let self = self, repair.repaired == 0 else {
                    return .single(repair.repaired)
                }
                if repair.inTheSendersConversation {
                    // Something that would not open reached the secret tree,
                    // which is only possible once the group id and the epoch
                    // have both matched - so the sender is in this very
                    // conversation and it is working. What will not open was
                    // written where this device cannot go, before it joined or
                    // further back than the keys it keeps, and no conversation
                    // that could be built now would open it either.
                    //
                    // Rebuilding on that reading is what this exists to stop.
                    // It fired on the stand three times in twenty minutes: each
                    // time a second conversation was started for a chat that
                    // already had a working one, half the group followed the
                    // welcome and half did not, and the messages of the people
                    // left behind stopped opening. That is issue #139, and its
                    // own log line was mistaken for the fault twice over.
                    return .single(0)
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
                    self.remember(key: peerId.mlsKey, groupId: groupId)
                    self.markRebuilt(key)
                    self.queue.unlock()
                    return .single(0)
                }
            }
            |> deliverOn(MlsRuntime.results)).start(next: { [weak self] _ in
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
    /// Which chats these conversations belong to.
    ///
    /// A commit names a group and nothing else, because that is all the server
    /// knows. This is the only place both facts are held at once - and it can
    /// answer now that a conversation is filed under the whole peer rather than
    /// a bare id (#111).
    public func peers(ofConversations groupIds: [Data]) -> [PeerId] {
        self.queue.lock()
        defer { self.queue.unlock() }
        var found: [PeerId] = []
        for (key, known) in self.conversationIds where groupIds.contains(known) {
            found.append(PeerId.fromMlsKey(key))
        }
        return found
    }

    /// - Parameter learntAt: the date of whatever said so, by the server's
    ///   clock. Nothing means this moment, which is what a conversation just
    ///   built or just joined deserves; a message passes its own date, so that
    ///   an older one cannot undo a newer one (#155).
    public func adopt(peerId: PeerId, groupId: Data, learntAt: Int32? = nil) {
        self.queue.lock()
        let at = learntAt ?? Int32(self.network?.globalTime ?? Date().timeIntervalSince1970)
        self.conversationIds[peerId.mlsKey] = groupId
        self.learntAt[peerId.mlsKey] = at
        self.markRebuilt(peerId.mlsKey)
        MlsRuntime.publishEncrypted([peerId.mlsKey])
        self.queue.unlock()

        // Written down here as well, on its own, rather than by whatever chain
        // happened to be running. It was written by the chain, and the chain did
        // not always get that far: the conversation was live in memory, the app
        // was restarted, and the device came back knowing nothing about it - so
        // it built another one and the two sides diverged again. Twice in one
        // evening, and both times it looked like the join had failed.
        let _ = (self.postbox.transaction { transaction -> Void in
            MlsConversationIds.remember(transaction: transaction, peerId: peerId,
                                        groupId: groupId, learntAt: at)
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
        let now = Int32(self.networkOutsideTheLock()?.globalTime ?? Date().timeIntervalSince1970)
        return postbox.transaction { transaction -> MlsConversationIds in
            return MlsConversationIds.dateWhatHasNoDate(transaction: transaction, at: now)
        }
        |> deliverOn(MlsRuntime.results)
        |> map { [weak self] stored -> Void in
            Logger.shared.log("Mls", "read \(stored.groupIdByPeer.count) conversation(s) off disk")
            guard let self = self else {
                return
            }
            let identity = try? mlsIdentity(postbox: postbox, accountPeerId: accountPeerId)
            self.queue.lock()
            self.conversationIds = stored.groupIdByPeer
            self.rebuilt = stored.rebuiltAtByPeer
            self.learntAt = stored.learntAtByPeer
            self.identity = identity
            MlsRuntime.publishEncrypted(stored.groupIdByPeer.keys)
            self.queue.unlock()
        }
    }
}
