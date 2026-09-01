import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi
import MlsCore

/// Making the conversation hold the people the chat holds (#40).
///
/// This is the iOS half of what MlsRuntime.java does, and it is deliberately the
/// same shape, because the two have to agree about things no test on one of them
/// can check alone.
///
/// # Why it is a comparison and not a hook
///
/// Membership changes reach a device by more than one route - the reply to
/// whoever pressed the button, a service message, the difference after being
/// away - and hanging the work on one of them is how somebody goes on reading a
/// group they were thrown out of. On Android three separate hooks were tried and
/// two of them were on paths that server never takes. Membership is a fact about
/// the chat, so it is checked as a fact.
///
/// # Why the two halves are not symmetrical
///
/// A wrong addition costs a round trip. A missed removal is somebody reading a
/// conversation they are not in, for ever, with nothing on any screen to say so.
/// So when the two disagree, this takes the side that fails safely.
///
/// Which is also why only a list that came from the server may take somebody
/// out: a remembered one can be missing people who joined while this device was
/// away, and acting on it cuts them out of a conversation nobody asked to remove
/// them from. It happened on the first Android run.

/// How many times a change is rebuilt after losing a race. Bounded because a
/// loop with no end is a client that never stops trying.
private let commitAttempts = 3

/// Who a service message has just named, which the remembered participant list
/// does not know about yet.
///
/// Every member gets these messages, which is why they are the one place a
/// change can be acted on at once. The list is fetched on its own schedule and
/// is behind - so a comparison made now finds nothing to do, and the person
/// waits for a sweep. That is how somebody who followed a link sat in a group
/// where nothing appeared, and how somebody removed went on reading.
public struct NamedInTheMessage {
    public let joined: [PeerId]
    public let gone: [PeerId]

    public init(joined: [PeerId] = [], gone: [PeerId] = []) {
        self.joined = joined
        self.gone = gone
    }

    public var isEmpty: Bool {
        return self.joined.isEmpty && self.gone.isEmpty
    }
}

/// What a change to the membership is, and how to make it again if somebody
/// else's change took the epoch first.
private enum MembershipChange {
    /// Letting people in: a commit for those already here and a welcome for
    /// them, from the one call, because the two have to describe the same group.
    case letIn(newcomers: [PeerId], keyPackages: [Data])
    /// Taking people out, and with each of them every phone they hold.
    case putOut(leaving: [PeerId])
    /// Taking out leaves by their own names, leaving the person's other phones
    /// reading. `putOut` is asked about a person and answers about every leaf
    /// they hold, which is right for somebody leaving and wrong here.
    ///
    /// `what` is whose leaves these are, for the log. The same call takes out a
    /// phone of this account and a leaf of somebody else whose device is gone
    /// (#139), and the two read as opposite things.
    case drop(leaves: [Data], what: String)

    var described: String {
        switch self {
        case let .letIn(newcomers, _):
            return "letting \(newcomers.count) into"
        case let .putOut(leaving):
            return "taking \(leaving.count) out of"
        case let .drop(leaves, what):
            return "taking \(leaves.count) \(what) out of"
        }
    }
}

/// How long to wait before looking again, in seconds.
///
/// The gap being waited out is the server's own: it moves the epoch and then
/// fills the boxes, and a device refused in between is told the group has moved
/// before the commit that moved it can be fetched. Measured at 156 milliseconds
/// on the stand; the ladder is long enough to survive a slow answer and short
/// enough that a device genuinely out of the group hears so while somebody is
/// still looking at it.
private let lookAgainAfter: [Double] = [2.0, 6.0, 15.0]

/// Waits until this device stands where the group does, and says whether it got
/// there.
///
/// The question is where this device is standing, not what this particular call
/// managed to apply (#118). An empty commit box means nothing on its own: it is
/// equally what a device sees when it has already caught up, and that is the
/// common case rather than a rare one - the collector runs on its own rhythm and
/// gets there first. Measured on Android, where the same shape lived: a phone
/// applied the winning commit 45 milliseconds after losing, and twenty-three
/// seconds later was told, wrongly and loudly, that it had fallen out of the
/// conversation and had to be taken out of the chat and let back in.
///
/// Asking the epoch cannot be fooled that way. Ahead of us and nothing arriving
/// is the real thing; standing level is fine however we got there.
private func standWhereTheGroupIs(runtime: MlsRuntime, postbox: Postbox, network: Network,
                                  accountPeerId: PeerId, groupId: Data, ahead: Int64,
                                  attempt: Int) -> Signal<Bool, NoError> {
    return catchUpWithTheGroup(postbox: postbox, network: network, accountPeerId: accountPeerId)
    |> mapToSignal { _ -> Signal<Bool, NoError> in
        let level = runtime.withState { identity -> Bool in
            guard let group = try MlsGroup.load(identity: identity, id: groupId) else {
                return false
            }
            return Int64(group.epoch) >= ahead
        } ?? false
        if level || attempt >= lookAgainAfter.count {
            return .single(level)
        }
        return (.complete() |> suspendAwareDelay(lookAgainAfter[attempt], queue: Queue.concurrentDefaultQueue()))
        |> then(standWhereTheGroupIs(runtime: runtime, postbox: postbox, network: network,
                                     accountPeerId: accountPeerId, groupId: groupId,
                                     ahead: ahead, attempt: attempt + 1))
    }
}

/// Offers a change to the delivery service and does whatever its answer calls
/// for.
///
/// Nothing is applied until that answer comes. Applying first is right exactly
/// until two people change one group at the same moment, and then both move on
/// into groups that hold different memberships and cannot read each other - with
/// nothing anywhere saying so, until a conversation quietly stops working for
/// some of the people in it.
private func offer(
    postbox: Postbox,
    accountPeerId: PeerId,
    network: Network,
    peerId: PeerId,
    groupId: Data,
    audience: [PeerId],
    change: MembershipChange,
    named: NamedInTheMessage,
    attempt: Int
) -> Signal<Void, NoError> {
    guard attempt <= commitAttempts else {
        Logger.shared.log("Mls", "gave up \(change.described) \(peerId) after \(commitAttempts) attempts")
        return .complete()
    }

    let runtime = MlsRuntime.instance(postbox: postbox, accountPeerId: accountPeerId)
    // Built with the one copy of the state, and written down before it is
    // offered: the commit is staged rather than applied, the answer may never
    // arrive, and the way back is the commit box - which can only help a device
    // that still holds what it staged. withState does the writing.
    let built: (commit: Data, welcome: Data?, epoch: Int64)?? = runtime.withState { identity in
        guard let group = try MlsGroup.load(identity: identity, id: groupId) else {
            return nil
        }
        let epoch = Int64(group.epoch)
        switch change {
        case let .letIn(_, keyPackages):
            let invitation = try group.addMembers(identity: identity, keyPackages: keyPackages)
            return (commit: invitation.commit, welcome: invitation.welcome, epoch: epoch)
        case let .putOut(leaving):
            let prefixes = leaving.map { Data("\($0.id._internalGetInt64Value())/".utf8) }
            guard let commit = try group.removeMembers(identity: identity, namePrefixes: prefixes) else {
                // Nobody matched, which is not a failure: two people removing
                // the same person at once is ordinary, and the second is
                // looking at a group that already looks the way they wanted.
                return nil
            }
            return (commit: commit, welcome: nil, epoch: epoch)
        case let .drop(leaves, _):
            // The full name of a leaf, which is a prefix of exactly one of
            // them - so the same call answers "this one phone" as well as it
            // answers "this person".
            guard let commit = try group.removeMembers(identity: identity, namePrefixes: leaves) else {
                return nil
            }
            return (commit: commit, welcome: nil, epoch: epoch)
        }
    }

    guard let built = built else {
        // Usually a commit staged by an earlier attempt that never heard back.
        // Catching up resolves it - the server left us a copy of our own commit
        // for exactly this - and then the change is made again.
        Logger.shared.log("Mls", "cannot build \(change.described) \(peerId)")
        return catchUpWithTheGroup(postbox: postbox, network: network, accountPeerId: accountPeerId)
    }
    guard let offered = built else {
        return .complete()
    }

    // Who the commit has to reach: everybody the conversation holds, read from
    // the conversation itself rather than from this device's copy of the chat's
    // participant list.
    //
    // The list was the obvious source and is wrong: it is fetched on its own
    // schedule, so a device that has just been let in is missing from it, and a
    // commit built here never reaches them. They stay an epoch behind for ever -
    // what would catch them up was never addressed to them, and nothing after it
    // applies without it. It took a group apart on the stand (#116).
    //
    // The leaves are the definition of who must apply a commit. Anybody being
    // let in is added on top, because they are not a leaf until this is applied.
    //
    // The same pass answers what the delivery service is told the group holds,
    // because both come off the same tree and loading it twice is how the two
    // answers come to be about different moments. That one is the roster
    // *after* this commit - staged, not applied, so the tree on its own still
    // shows the membership before it (#147).
    let seen = runtime.withState({ identity -> ([Int64], [Data]) in
        guard let group = try MlsGroup.load(identity: identity, id: groupId) else {
            return ([], [])
        }
        var holders: Set<Int64> = []
        for name in group.memberNames() {
            let text = String(decoding: name, as: UTF8.self)
            // Not the person with id zero: nobody has it, a commit addressed
            // there reaches no device, and the delivery service would be asked
            // to find their phones on every change (#122).
            if let slash = text.firstIndex(of: "/"), let who = Int64(text[text.startIndex ..< slash]),
               who != 0 {
                holders.insert(who)
            }
        }
        return (Array(holders), group.stagedMemberNames())
    })
    var members = seen?.0 ?? audience.map { $0.id._internalGetInt64Value() }
    let holds = seen?.1 ?? []
    if case let .letIn(newcomers, _) = change {
        for newcomer in newcomers {
            let id = newcomer.id._internalGetInt64Value()
            if !members.contains(id) {
                members.append(id)
            }
        }
    }
    // And this account, which is not vanity: the other phones of the person
    // making the change are separate leaves and need the commit as much as
    // anybody, and this phone needs its own copy back to learn the outcome if
    // the answer below never arrives.
    members.removeAll(where: { $0 == accountPeerId.id._internalGetInt64Value() })
    members.append(accountPeerId.id._internalGetInt64Value())

    return network.request(Api.functions.mls.sendCommit(
        groupId: Buffer(data: groupId),
        epoch: offered.epoch,
        members: members,
        commit: Buffer(data: offered.commit),
        holds: holds.map { Buffer(data: $0) }))
    |> map(Optional.init)
    |> `catch` { _ -> Signal<Api.mls.CommitResult?, NoError> in
        // No answer is not the same as a refusal, and must not be treated as
        // one: the commit may well have been taken. It stays staged, and the
        // copy the server left in our own box will say how it ended.
        return .single(nil)
    }
    |> mapToSignal { result -> Signal<Void, NoError> in
        guard let result = result else {
            Logger.shared.log("Mls", "\(change.described) \(peerId) went unanswered")
            return .complete()
        }

        // The state again, and read afresh: between offering and hearing back
        // there was a round trip, and anything may have moved it.
        let settled: Bool? = runtime.withState { identity in
            guard let group = try MlsGroup.load(identity: identity, id: groupId) else {
                return false
            }
            if result.accepted {
                try group.acceptCommit(identity: identity)
            } else {
                try group.abandonCommit(identity: identity)
            }
            return true
        }
        guard settled == true else {
            Logger.shared.log("Mls", "cannot settle \(change.described) \(peerId)")
            return .complete()
        }

        guard result.accepted else {
            Logger.shared.log("Mls", "\(change.described) \(peerId) lost epoch \(offered.epoch); the group is at \(result.epoch), catching up")
            // Losing is ordinary and the way back is the commit box. Losing and
            // still standing behind the group afterwards is not: the change that
            // moved it was never addressed to this device, and nothing after it
            // can be applied without the one that is missing. The device is out
            // of the conversation and will not find its own way back (#116).
            return standWhereTheGroupIs(runtime: runtime, postbox: postbox, network: network,
                                        accountPeerId: accountPeerId, groupId: groupId,
                                        ahead: result.epoch, attempt: 0)
            |> mapToSignal { level -> Signal<Void, NoError> in
                if !level {
                    Logger.shared.log("Mls", "fallen out of \(mlsShortId(groupId)) - staked epoch \(offered.epoch), the group is at \(result.epoch), and nothing arrived to catch up with. This device has to be taken out of the chat and let back in (#116)")
                }
                // Worked out afresh rather than replayed: the change was built
                // against a group that has since moved.
                // Carried through: a change worked out afresh from a list that
                // has still not caught up would forget who the message named.
                return reconcileMembership(
                    postbox: postbox, accountPeerId: accountPeerId, network: network,
                    peerId: peerId,
                    listIsFromTheServer: true, named: named, attempt: attempt + 1)
            }
        }

        Logger.shared.log("Mls", "\(change.described) \(peerId) taken, \(mlsShortId(groupId)) is now at epoch \(result.epoch)")
        guard case let .letIn(newcomers, _) = change, let welcome = offered.welcome else {
            return .complete()
        }
        // After the commit, not before. A welcome describes the group as it is
        // once the commit has been applied, so somebody who acts on it first
        // joins a conversation that does not exist yet.
        return combineLatest(newcomers.map { newcomer in
            network.request(Api.functions.mls.sendWelcome(
                userId: newcomer.id._internalGetInt64Value(),
                peerId: peerId.dialogId,
                welcome: Buffer(data: welcome)))
            |> map(Optional.init)
            |> `catch` { _ -> Signal<Api.mls.Ok?, NoError> in
                Logger.shared.log("Mls", "the welcome for \(newcomer) was not delivered")
                return .single(nil)
            }
        })
        |> mapToSignal { _ -> Signal<Void, NoError> in .complete() }
    }
}

/// Makes the conversation match the chat.
///
/// - Parameter listIsFromTheServer: whether the membership being compared
///   against was just handed over by the server rather than remembered here.
///   Only a fresh list may take somebody out.
/// - Parameter named: people a service message has just named as having joined
///   or gone. The list this device holds has not caught up with them yet - it is
///   fetched on its own schedule - so comparing against it finds nothing and the
///   change waits for a sweep. Naming is also better evidence than the list: it
///   came from the server this second, about this one person.

public func reconcileMembership(
    postbox: Postbox,
    accountPeerId: PeerId,
    network: Network,
    peerId: PeerId,
    listIsFromTheServer: Bool,
    named: NamedInTheMessage = NamedInTheMessage(),
    attempt: Int = 1
) -> Signal<Void, NoError> {
    // The list half reaches a chat between two as well now: who is in one does
    // not change, but how many devices they have does, and until #142 nobody
    // was looking for the pair. The half below is about this account's own
    // phones, which the first cannot see because it is about people.
    return compareWithTheList(
        postbox: postbox, accountPeerId: accountPeerId, network: network,
        peerId: peerId, listIsFromTheServer: listIsFromTheServer,
        named: named, attempt: attempt)
    // And then this account's own other phones, which the comparison above
    // cannot see: it is about people, and they are the same person.
    |> then(letInMyOtherDevices(
        postbox: postbox, accountPeerId: accountPeerId, network: network,
        peerId: peerId, attempt: attempt))
}

/// Lets the other phones of this account into a conversation this one is in.
///
/// A leaf is named `<user>/<device>` and every comparison reads the part before
/// the slash, so a second phone of somebody already in the group is invisible to
/// it. That is right for everybody else - their devices were all added at once
/// when they were - and wrong for this account, whose new phone nobody else is
/// going to notice.
///
/// A phone that signs in publishes key packages, and the server says how many
/// devices this account has published from. More of those than leaves of this
/// account here means a phone that signed in after the conversation started.
///
/// Deliberately without asking anybody. The case this is for is a person adding
/// their own second device while holding the first, and a confirmation there is
/// ceremony: an account somebody else has taken over already reads the messages
/// arriving in it (#41).
private func letInMyOtherDevices(
    postbox: Postbox,
    accountPeerId: PeerId,
    network: Network,
    peerId: PeerId,
    attempt: Int
) -> Signal<Void, NoError> {
    guard attempt <= commitAttempts else {
        return .complete()
    }
    let runtime = MlsRuntime.instance(postbox: postbox, accountPeerId: accountPeerId)
    let devices = runtime.devices()
    guard devices > 1 else {
        // One device, or nobody has asked the server yet. Either way there is
        // nothing here to conclude.
        return .complete()
    }
    let self64 = accountPeerId.id._internalGetInt64Value()

    return postbox.transaction { transaction -> (Data, [PeerId])? in
        let ids = MlsConversationIds.load(transaction: transaction)
        guard let groupId = ids.groupIdByPeer[peerId.mlsKey] else {
            return nil
        }
        // The others, because the commit has to reach them: a leaf added here
        // moves the epoch for the whole conversation, and anybody who does not
        // get it stops being able to read.
        guard peerId.namespace == Namespaces.Peer.CloudGroup else {
            // A chat between two: the other person is the whole audience, and
            // there is no participant list to look it up in.
            return (groupId, [peerId])
        }
        guard let cached = transaction.getPeerCachedData(peerId: peerId) as? CachedGroupData,
              let participants = cached.participants else {
            return nil
        }
        return (groupId, participants.participants.map({ $0.peerId }).filter({ $0 != accountPeerId }))
    }
    |> mapToSignal { found -> Signal<Void, NoError> in
        guard let (groupId, others) = found else {
            return .complete()
        }
        let prefix = "\(self64)/"
        let mine: [Data]? = runtime.withState { identity in
            guard let group = try MlsGroup.load(identity: identity, id: groupId) else {
                return [Data]()
            }
            return group.memberNames().filter {
                String(decoding: $0, as: UTF8.self).hasPrefix(prefix)
            }
        }
        guard let here = mine, here.count < Int(devices) else {
            return .complete()
        }
        Logger.shared.log("Mls", "this account has \(devices) device(s) and \(here.count) of them are in \(mlsShortId(groupId))")

        return network.request(Api.functions.mls.claimKeyPackages(userId: self64))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.mls.KeyPackages?, NoError> in .single(nil) }
        |> mapToSignal { answer -> Signal<Void, NoError> in
            guard let answer = answer else {
                Logger.shared.log("Mls", "cannot reach this account's own devices")
                return .complete()
            }
            // One package per device, this one's among them - the server cannot
            // tell which caller is which leaf. Added back, it would give this
            // device a second leaf it holds no keys for, and every message
            // written to that leaf would go nowhere.
            let wanted = answer.packages.map({ $0.makeData() }).filter { keyPackage in
                guard let name = try? MlsGroup.name(ofKeyPackage: keyPackage) else {
                    return false
                }
                return !here.contains(name)
            }
            guard !wanted.isEmpty else {
                return .complete()
            }
            Logger.shared.log("Mls", "letting \(wanted.count) more device(s) of this account into \(mlsShortId(groupId))")
            // The welcome goes to this account, which is every device of it -
            // the new one among them. The copy that comes back here cannot be
            // opened and says so, which is ordinary and already handled.
            return offer(
                postbox: postbox, accountPeerId: accountPeerId, network: network,
                peerId: peerId, groupId: groupId, audience: others,
                change: .letIn(newcomers: [accountPeerId], keyPackages: wanted),
                named: NamedInTheMessage(), attempt: attempt)
        }
    }
}

/// Takes out the leaves that belong to nobody.
///
/// A device whose identity was made before its account had signed in is named
/// `0/1234`: the id was still zero when the name was built, and a name is part
/// of the cryptography and cannot be changed afterwards. Nothing recognises
/// such a leaf as anybody's - not the pass that lets this account's other
/// phones in, not the one that takes a lost phone out, not the comparison of a
/// chat with its conversation - so it sits there as a member no person owns,
/// reading everything said (#122).
///
/// Making them stopped when the identity learned to refuse a nameless account.
/// The ones already sitting in conversations were left, because there was
/// nobody to claim them - which is why this removes them by name rather than
/// by owner.
///
/// Every conversation, not only groups. The comparison with the chat is about
/// a participant list and a chat between two has none, so it returns at once
/// for those - and the leaf measured on the stand was in one of them, where
/// nothing had ever looked.
///
/// Nobody has the id zero, so this needs no list to be sure: it is true in
/// every conversation, whoever else is in it. And it is recoverable, which
/// removing a leaf usually is not - the phone holding it starts its state over
/// on its next launch, under its real name, and the ordinary comparison lets
/// it back in.
public func takeOutLeavesThatBelongToNobody(
    postbox: Postbox,
    accountPeerId: PeerId,
    network: Network
) -> Signal<Void, NoError> {
    let runtime = MlsRuntime.instance(postbox: postbox, accountPeerId: accountPeerId)
    return postbox.transaction { transaction -> [PeerId] in
        return Array(MlsConversationIds.load(transaction: transaction).groupIdByPeer.keys)
            .map({ PeerId.fromMlsKey($0) })
    }
    |> mapToSignal { peers -> Signal<Void, NoError> in
        var work: Signal<Void, NoError> = .complete()
        for peerId in peers {
            work = work
            |> then(takeOutLeavesThatBelongToNobody(postbox: postbox, accountPeerId: accountPeerId,
                                                    network: network, peerId: peerId,
                                                    runtime: runtime, attempt: 1))
        }
        return work
    }
}

private func takeOutLeavesThatBelongToNobody(
    postbox: Postbox,
    accountPeerId: PeerId,
    network: Network,
    peerId: PeerId,
    runtime: MlsRuntime,
    attempt: Int
) -> Signal<Void, NoError> {
    guard attempt <= commitAttempts else {
        return .complete()
    }
    return postbox.transaction { transaction -> Data? in
        return MlsConversationIds.load(transaction: transaction).groupIdByPeer[peerId.mlsKey]
    }
    |> mapToSignal { found -> Signal<Void, NoError> in
        guard let groupId = found else {
            return .complete()
        }
        let nobody: [Data]? = runtime.withState { identity in
            guard let group = try MlsGroup.load(identity: identity, id: groupId) else {
                return [Data]()
            }
            // Zero and only zero. A name this device cannot read at all is a
            // different thing and needs the opposite answer: it may belong to
            // somebody under a naming scheme this build does not know, and
            // evicting on that guess is the one mistake there is no way back
            // from.
            return group.memberNames().filter { name in
                let text = String(decoding: name, as: UTF8.self)
                guard let slash = text.firstIndex(of: "/") else {
                    return false
                }
                return Int64(text[text.startIndex ..< slash]) == 0
            }
        }
        guard let leaves = nobody, !leaves.isEmpty else {
            return .complete()
        }
        Logger.shared.log("Mls", "\(mlsShortId(groupId)) holds \(leaves.count) leaf/leaves that belong to nobody, taking them out")
        return offer(
            postbox: postbox, accountPeerId: accountPeerId, network: network,
            peerId: peerId, groupId: groupId, audience: [],
            change: .drop(leaves: leaves, what: "device(s) of this account"),
            named: NamedInTheMessage(), attempt: attempt)
    }
}

/// Takes the phones of this account that are gone out of a conversation.
///
/// The mirror of letting them in, and the half that makes losing a phone mean
/// anything. Signing a device out takes its key packages off the server so
/// nobody can add it again - but the leaf it already holds stays, and a leaf is
/// what reading is. Until it is removed and the epoch moves, the phone in the
/// drawer opens everything said afterwards (#41).
///
/// It used to ask this in two pieces and reason about the difference: how many
/// devices the server counted, then which of them it could name, and a leaf of
/// mine in neither was taken for gone. The count had to come first because the
/// names alone were dangerous - a device that had merely run out of key
/// packages looked exactly like one that had left.
///
/// The server answers both halves at once now, about this very conversation
/// (#147). What is left here is the one thing this side must decide: never this
/// device's own leaf, because a phone that could not tell which leaf was its own
/// would evict itself from every conversation it holds.
public func takeOutMyLostDevices(
    postbox: Postbox,
    accountPeerId: PeerId,
    network: Network
) -> Signal<Void, NoError> {
    let runtime = MlsRuntime.instance(postbox: postbox, accountPeerId: accountPeerId)
    return postbox.transaction { transaction -> [PeerId] in
        return Array(MlsConversationIds.load(transaction: transaction).groupIdByPeer.keys)
            .map({ PeerId.fromMlsKey($0) })
    }
    |> mapToSignal { peers -> Signal<Void, NoError> in
        var work: Signal<Void, NoError> = .complete()
        for peerId in peers {
            work = work
            |> then(takeOutMyLostDevices(postbox: postbox, accountPeerId: accountPeerId,
                                         network: network, peerId: peerId,
                                         runtime: runtime, attempt: 1))
        }
        return work
    }
}

private func takeOutMyLostDevices(
    postbox: Postbox,
    accountPeerId: PeerId,
    network: Network,
    peerId: PeerId,
    runtime: MlsRuntime,
    attempt: Int
) -> Signal<Void, NoError> {
    guard attempt <= commitAttempts else {
        return .complete()
    }
    let self64 = accountPeerId.id._internalGetInt64Value()

    return postbox.transaction { transaction -> Data? in
        return MlsConversationIds.load(transaction: transaction).groupIdByPeer[peerId.mlsKey]
    }
    |> mapToSignal { found -> Signal<Void, NoError> in
        guard let groupId = found else {
            return .complete()
        }
        let prefix = "\(self64)/"
        let mine: [Data]? = runtime.withState { identity in
            guard let group = try MlsGroup.load(identity: identity, id: groupId) else {
                return [Data]()
            }
            return group.memberNames().filter {
                String(decoding: $0, as: UTF8.self).hasPrefix(prefix)
            }
        }
        guard let here = mine, here.count > 1 else {
            // One leaf is this device's own, and there is nothing to lose.
            return .complete()
        }
        // This device is never a candidate, whatever the server says about it.
        let ours = runtime.withState { identity in identity.name() } ?? nil

        return network.request(Api.functions.mls.membersOf(
            peerId: peerId.dialogId, groupId: Buffer(data: groupId)))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.mls.Members?, NoError> in .single(nil) }
        |> mapToSignal { held -> Signal<Void, NoError> in
            guard let held = held else {
                Logger.shared.log("Mls", "cannot ask what \(mlsShortId(groupId)) holds, leaving this account's leaves alone")
                return .complete()
            }
            let dead = Set(held.holds.filter({ !$0.alive }).map({ $0.name.makeData() }))
            let gone = here.filter { leaf in
                if let ours = ours, leaf == ours {
                    return false
                }
                return dead.contains(leaf)
            }
            guard !gone.isEmpty else {
                return .complete()
            }
            Logger.shared.log("Mls", "taking \(gone.count) device(s) of this account out of \(mlsShortId(groupId))")
            return offer(
                postbox: postbox, accountPeerId: accountPeerId, network: network,
                peerId: peerId, groupId: groupId, audience: [],
                change: .drop(leaves: gone, what: "device(s) of this account"),
                named: NamedInTheMessage(), attempt: attempt)
        }
    }
}

/// Whether this conversation is one to compare with its chat.
///
/// A group, and a chat between two - which was left out of the comparison with
/// "a chat between two never changes who is in it" written beside it on both
/// clients. Who is in it does not change; how many devices they have does, and
/// that is what this has been about since #132. In a group somebody notices a
/// phone that has been replaced and lets the new one in. In a chat between two
/// nobody was looking, so the person sat there watching padlocks with nothing on
/// any screen to say why - and the settled answer for that chat could never be
/// put right either, because the moment that puts it right is the end of this
/// very comparison (#139, #142).
///
/// A channel is not: broadcasting is a different thing and none of it is built
/// (#16).
///
/// The Android twin is MlsRuntime.worthComparing.
private func worthComparing(_ peerId: PeerId) -> Bool {
    return peerId.namespace == Namespaces.Peer.CloudGroup
        || peerId.namespace == Namespaces.Peer.CloudUser
}

private func compareWithTheList(
    postbox: Postbox,
    accountPeerId: PeerId,
    network: Network,
    peerId: PeerId,
    listIsFromTheServer: Bool,
    named: NamedInTheMessage,
    attempt: Int
) -> Signal<Void, NoError> {
    guard worthComparing(peerId) else {
        // A channel is broadcasting rather than a conversation (#16).
        return .complete()
    }

    return postbox.transaction { transaction -> (Data, [PeerId])? in
        let ids = MlsConversationIds.load(transaction: transaction)
        guard let groupId = ids.groupIdByPeer[peerId.mlsKey] else {
            // Not an encrypted chat, and joining one does not make it so: the
            // rule for a group is all of them or none, and that was settled
            // when the conversation began.
            return nil
        }
        guard peerId.namespace == Namespaces.Peer.CloudGroup else {
            // A chat between two: the other person is the whole membership, and
            // there is no participant list to look it up in. Said the same way
            // the audience lookup above says it.
            return (groupId, [peerId])
        }
        guard let cached = transaction.getPeerCachedData(peerId: peerId) as? CachedGroupData,
              let participants = cached.participants else {
            return nil
        }
        return (groupId, participants.participants.map({ $0.peerId }).filter({ $0 != accountPeerId }))
    }
    |> mapToSignal { found -> Signal<Void, NoError> in
        guard let (groupId, listed) = found else {
            return .complete()
        }
        // Who is in the conversation, read through the one copy of the state.
        let names: [Data]? = MlsRuntime.instance(postbox: postbox, accountPeerId: accountPeerId).withState { identity in
            guard let group = try MlsGroup.load(identity: identity, id: groupId) else {
                return [Data]()
            }
            return group.memberNames()
        }
        guard let memberNames = names, !memberNames.isEmpty else {
            return .complete()
        }
        // What this device's own tree holds, said out loud once a round.
        //
        // The roster the delivery service keeps is what it was told, and this is
        // what is true; the two are compared after a walk, and until this line
        // existed only one side of that comparison could be read at all (#147).
        Logger.shared.log("Mls", "\(mlsShortId(groupId)) here holds: "
            + memberNames.map({ String(decoding: $0, as: UTF8.self) }).sorted().joined(separator: " "))

        // Whoever a message has just named counts as being in the chat, ahead of
        // the list saying so. Anybody it named as gone counts as out of it, and
        // is dropped from the audience as well - a commit that removes somebody
        // is not addressed to them.
        var members = listed
        for newcomer in named.joined where newcomer != accountPeerId && !members.contains(newcomer) {
            members.append(newcomer)
        }
        members.removeAll(where: { named.gone.contains($0) })

        // A leaf is named <user>/<device>, so the person is what comes before
        // the slash, and one person with two phones is two leaves answering to
        // the same id.
        var inside: Set<Int64> = []
        for name in memberNames {
            let text = String(decoding: name, as: UTF8.self)
            if let slash = text.firstIndex(of: "/"), let id = Int64(text[text.startIndex ..< slash]) {
                inside.insert(id)
            }
        }

        var belong = Set(members.map { $0.id._internalGetInt64Value() })
        // This account is never taken out, whatever the list says: a person's
        // own membership is not something they work out by comparison, and a
        // device that removed itself would hold a group it can no longer read
        // or repair.
        belong.insert(accountPeerId.id._internalGetInt64Value())

        let missing = members.filter { !inside.contains($0.id._internalGetInt64Value()) }
        // Named departures first, and without waiting for a list: a removal that
        // waits is a removal that has not happened, and what it leaves behind is
        // somebody reading a conversation they are not in, with nothing on any
        // screen to say so.
        let namedOut = named.gone.filter { inside.contains($0.id._internalGetInt64Value()) }
        if !namedOut.isEmpty {
            Logger.shared.log("Mls", "\(namedOut) were named as gone from \(peerId)")
            return offer(
                postbox: postbox, accountPeerId: accountPeerId, network: network,
                peerId: peerId, groupId: groupId,
                audience: members, change: .putOut(leaving: namedOut),
                named: named, attempt: attempt)
        }

        let extra = members.isEmpty ? [] : inside.subtracting(belong)

        // Only for a group, and only on a fresh list. A chat between two has
        // nobody who could have to leave it - the membership is the two of them
        // and there is no removal to miss - so the half that fails safely by
        // removing has nothing to do here, and every mistake it could make would
        // be a person cut out of their own conversation.
        if listIsFromTheServer, peerId.namespace == Namespaces.Peer.CloudGroup, !extra.isEmpty {
            let leaving = extra.map { PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value($0)) }
            Logger.shared.log("Mls", "\(leaving) are in \(mlsShortId(groupId)) and no longer in \(peerId)")
            return offer(
                postbox: postbox, accountPeerId: accountPeerId, network: network,
                peerId: peerId, groupId: groupId,
                audience: members.filter({ !extra.contains($0.id._internalGetInt64Value()) }),
                change: .putOut(leaving: leaving), named: named, attempt: attempt)
        }

        // Who has fewer leaves here than they have devices. Somebody with none
        // at all is the ordinary newcomer; somebody with one that is dead and a
        // phone that is alive is #132, and until this both looked the same to
        // the half of this that could see them.
        return network.request(Api.functions.mls.membersOf(
            peerId: peerId.dialogId, groupId: Buffer(data: groupId)))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.mls.Members?, NoError> in .single(nil) }
        |> mapToSignal { held -> Signal<Void, NoError> in
            var wanting: [PeerId] = []
            if let held = held {
                // The other direction first: a leaf whose device is gone. Taken
                // before anybody is let in because it is the smaller group that
                // results, and because letting somebody in while the tree still
                // holds their dead leaf is how one person came to hold three.
                //
                // Only leaves this tree actually has. The roster is what the
                // server was told and this tree is what this device can act on;
                // where they differ the tree wins, and the difference is what
                // the gate on the roster is for (#147).
                //
                // And never this account's own: those are another pass's job,
                // with a guard of its own, because a device that could not tell
                // which leaf was its own would evict itself from everything.
                let here = Set(memberNames)
                let ours = "\(accountPeerId.id._internalGetInt64Value())/"
                let dead = held.holds
                    .filter { !$0.alive }
                    .map { $0.name.makeData() }
                    .filter { here.contains($0)
                        && !String(decoding: $0, as: UTF8.self).hasPrefix(ours) }
                if !dead.isEmpty {
                    Logger.shared.log("Mls", "\(dead.count) leaf/leaves in \(mlsShortId(groupId)) belong to devices that are gone")
                    return offer(
                        postbox: postbox, accountPeerId: accountPeerId, network: network,
                        peerId: peerId, groupId: groupId,
                        audience: members, change: .drop(leaves: dead, what: "leaf(es) whose device is gone"),
                        named: named, attempt: attempt)
                }

                // Who the server says has a phone this group has never met.
                // That is the half no client could work out: somebody who has
                // replaced a phone is not absent and is not here either, and
                // until the server answered it both looked the same (#132).
                var short = Set(held.wanting)
                // And whoever is plainly absent, which this side has always
                // been able to see for itself - the chat's list against the
                // tree. The server does not answer it because it does not have
                // the chat's list here.
                for member in missing {
                    short.insert(member.id._internalGetInt64Value())
                }
                wanting = members.filter { short.contains($0.id._internalGetInt64Value()) }
            } else {
                // The server did not say. Falling back to the old question is
                // right rather than tidy: it lets in whoever is plainly absent
                // and does nothing about a leaf that may or may not be dead,
                // which is the safe half.
                Logger.shared.log("Mls", "the server did not say what \(mlsShortId(groupId)) holds, going by who is absent")
                wanting = missing
            }
            guard !wanting.isEmpty else {
                // Nobody missing. There used to be something to say here - this
                // device vouching that the conversation held every device of
                // every member, which was the one thing that could replace an
                // answer already settled (#139). The server keeps the roster now
                // and can see that for itself, so the vouch is gone and this
                // round has nothing left to do (#147).
                return .complete()
            }

            // Somebody with no devices to reach is left out of this round rather
            // than stopping it: the others should not wait for a client that has
            // not published anything yet, and the comparison runs again later.
            return combineLatest(wanting.map { member in
                network.request(Api.functions.mls.claimKeyPackages(userId: member.id._internalGetInt64Value()))
                |> map(Optional.init)
                |> `catch` { _ -> Signal<Api.mls.KeyPackages?, NoError> in .single(nil) }
            })
            |> mapToSignal { answers -> Signal<Void, NoError> in
                let here = Set(memberNames)
                var packages: [Data] = []
                var reachable: [PeerId] = []
                for (index, answer) in answers.enumerated() {
                    guard let answer = answer, !answer.packages.isEmpty else {
                        Logger.shared.log("Mls", "\(wanting[index]) has no devices, so they stay outside \(peerId) for now")
                        continue
                    }
                    // Not the ones already standing here. A person being caught
                    // up has live devices in the group as well as the one that
                    // is missing, and adding a leaf that is already there gives
                    // them two, one of which holds no keys anybody has.
                    let wanted = answer.packages.map({ $0.makeData() }).filter { keyPackage in
                        guard let name = try? MlsGroup.name(ofKeyPackage: keyPackage) else {
                            return false
                        }
                        return !here.contains(name)
                    }
                    guard !wanted.isEmpty else {
                        continue
                    }
                    packages.append(contentsOf: wanted)
                    reachable.append(wanting[index])
                }
                guard !packages.isEmpty else {
                    return .complete()
                }
                Logger.shared.log("Mls", "\(reachable.count) of \(peerId) have a device that \(mlsShortId(groupId)) does not hold")
                return offer(
                    postbox: postbox, accountPeerId: accountPeerId, network: network,
                    peerId: peerId, groupId: groupId,
                    audience: members, change: .letIn(newcomers: reachable, keyPackages: packages),
                    named: named, attempt: attempt)
            }
        }
    }
}
