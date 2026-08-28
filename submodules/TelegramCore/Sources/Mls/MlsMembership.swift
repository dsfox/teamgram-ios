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

    var described: String {
        switch self {
        case let .letIn(newcomers, _):
            return "letting \(newcomers.count) into"
        case let .putOut(leaving):
            return "taking \(leaving.count) out of"
        }
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

    // And this account, which is not vanity: the other phones of the person
    // making the change are separate leaves and need the commit as much as
    // anybody, and this phone needs its own copy back to learn the outcome if
    // the answer below never arrives.
    var members = audience.map { $0.id._internalGetInt64Value() }
    members.append(accountPeerId.id._internalGetInt64Value())

    return network.request(Api.functions.mls.sendCommit(
        groupId: Buffer(data: groupId),
        epoch: offered.epoch,
        members: members,
        commit: Buffer(data: offered.commit)))
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
            return catchUpWithTheGroup(postbox: postbox, network: network, accountPeerId: accountPeerId)
            |> mapToSignal { _ -> Signal<Void, NoError> in
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
                userId: newcomer.id._internalGetInt64Value(), welcome: Buffer(data: welcome)))
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
    // The list half is about groups - a chat between two never changes who is in
    // it - and the half below is about this account's own phones, which a chat
    // of two has as much of a problem with.
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

private func compareWithTheList(
    postbox: Postbox,
    accountPeerId: PeerId,
    network: Network,
    peerId: PeerId,
    listIsFromTheServer: Bool,
    named: NamedInTheMessage,
    attempt: Int
) -> Signal<Void, NoError> {
    guard peerId.namespace == Namespaces.Peer.CloudGroup else {
        // A chat between two never changes who is in it, and a channel is
        // broadcasting rather than a conversation (#16).
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

        if listIsFromTheServer, !extra.isEmpty {
            let leaving = extra.map { PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value($0)) }
            Logger.shared.log("Mls", "\(leaving) are in \(mlsShortId(groupId)) and no longer in \(peerId)")
            return offer(
                postbox: postbox, accountPeerId: accountPeerId, network: network,
                peerId: peerId, groupId: groupId,
                audience: members.filter({ !extra.contains($0.id._internalGetInt64Value()) }),
                change: .putOut(leaving: leaving), named: named, attempt: attempt)
        }

        guard !missing.isEmpty else {
            return .complete()
        }

        // Somebody with no devices to reach is left out of this round rather
        // than stopping it: the others should not wait for a client that has
        // not published anything yet, and the comparison runs again later.
        return combineLatest(missing.map { member in
            network.request(Api.functions.mls.claimKeyPackages(userId: member.id._internalGetInt64Value()))
            |> map(Optional.init)
            |> `catch` { _ -> Signal<Api.mls.KeyPackages?, NoError> in .single(nil) }
        })
        |> mapToSignal { answers -> Signal<Void, NoError> in
            var packages: [Data] = []
            var reachable: [PeerId] = []
            for (index, answer) in answers.enumerated() {
                guard let answer = answer, !answer.packages.isEmpty else {
                    Logger.shared.log("Mls", "\(missing[index]) has no devices, so they stay outside \(peerId) for now")
                    continue
                }
                packages.append(contentsOf: answer.packages.map { $0.makeData() })
                reachable.append(missing[index])
            }
            guard !packages.isEmpty else {
                return .complete()
            }
            Logger.shared.log("Mls", "\(reachable.count) of \(peerId) are not in \(mlsShortId(groupId)) yet")
            return offer(
                postbox: postbox, accountPeerId: accountPeerId, network: network,
                peerId: peerId, groupId: groupId,
                audience: members, change: .letIn(newcomers: reachable, keyPackages: packages),
                named: named, attempt: attempt)
        }
    }
}
