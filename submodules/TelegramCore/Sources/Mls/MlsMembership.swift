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
    identity: MlsIdentity,
    peerId: PeerId,
    groupId: Data,
    audience: [PeerId],
    change: MembershipChange,
    attempt: Int
) -> Signal<Void, NoError> {
    guard attempt <= commitAttempts else {
        Logger.shared.log("Mls", "gave up \(change.described) \(peerId) after \(commitAttempts) attempts")
        return .complete()
    }

    let built: (commit: Data, welcome: Data?, epoch: Int64)?
    do {
        guard let group = try MlsGroup.load(identity: identity, id: groupId) else {
            return .complete()
        }
        let epoch = Int64(group.epoch)
        switch change {
        case let .letIn(_, keyPackages):
            let invitation = try group.addMembers(identity: identity, keyPackages: keyPackages)
            built = (commit: invitation.commit, welcome: invitation.welcome, epoch: epoch)
        case let .putOut(leaving):
            let prefixes = leaving.map { Data("\($0.id._internalGetInt64Value())/".utf8) }
            guard let commit = try group.removeMembers(identity: identity, namePrefixes: prefixes) else {
                // Nobody matched, which is not a failure: two people removing
                // the same person at once is ordinary, and the second is
                // looking at a group that already looks the way they wanted.
                return .complete()
            }
            built = (commit: commit, welcome: nil, epoch: epoch)
        }
        // Written down before it is offered. The commit is staged rather than
        // applied, and the answer may never arrive - so the way back is the
        // commit box, and the box can only help a device that still holds what
        // it staged.
        MlsStateWriter.instance(accountPeerId: accountPeerId).write(postbox: postbox, state: try identity.export())
    } catch {
        // Usually a commit staged by an earlier attempt that never heard back.
        // Catching up resolves it - the server left us a copy of our own commit
        // for exactly this - and then the change is made again.
        Logger.shared.log("Mls", "cannot build \(change.described) \(peerId): \(error)")
        return applyPendingCommits(postbox: postbox, network: network, accountPeerId: accountPeerId)
        |> mapToSignal { _ -> Signal<Void, NoError> in .complete() }
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

        do {
            guard let group = try MlsGroup.load(identity: identity, id: groupId) else {
                return .complete()
            }
            if result.accepted {
                try group.acceptCommit(identity: identity)
            } else {
                try group.abandonCommit(identity: identity)
            }
            MlsStateWriter.instance(accountPeerId: accountPeerId).write(postbox: postbox, state: try identity.export())
        } catch {
            Logger.shared.log("Mls", "cannot settle \(change.described) \(peerId): \(error)")
            return .complete()
        }

        guard result.accepted else {
            Logger.shared.log("Mls", "\(change.described) \(peerId) lost epoch \(offered.epoch); the group is at \(result.epoch), catching up")
            return applyPendingCommits(postbox: postbox, network: network, accountPeerId: accountPeerId)
            |> mapToSignal { _ -> Signal<Void, NoError> in
                // Worked out afresh rather than replayed: the change was built
                // against a group that has since moved.
                return reconcileMembership(
                    postbox: postbox, accountPeerId: accountPeerId, network: network,
                    identity: identity, peerId: peerId,
                    listIsFromTheServer: true, attempt: attempt + 1)
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
public func reconcileMembership(
    postbox: Postbox,
    accountPeerId: PeerId,
    network: Network,
    identity: MlsIdentity,
    peerId: PeerId,
    listIsFromTheServer: Bool,
    attempt: Int = 1
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
        guard let (groupId, members) = found else {
            return .complete()
        }
        guard let group = try? MlsGroup.load(identity: identity, id: groupId) else {
            return .complete()
        }

        // A leaf is named <user>/<device>, so the person is what comes before
        // the slash, and one person with two phones is two leaves answering to
        // the same id.
        var inside: Set<Int64> = []
        for name in group.memberNames() {
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
        let extra = members.isEmpty ? [] : inside.subtracting(belong)

        if listIsFromTheServer, !extra.isEmpty {
            let leaving = extra.map { PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value($0)) }
            Logger.shared.log("Mls", "\(leaving) are in \(mlsShortId(groupId)) and no longer in \(peerId)")
            return offer(
                postbox: postbox, accountPeerId: accountPeerId, network: network,
                identity: identity, peerId: peerId, groupId: groupId,
                audience: members.filter({ !extra.contains($0.id._internalGetInt64Value()) }),
                change: .putOut(leaving: leaving), attempt: attempt)
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
                identity: identity, peerId: peerId, groupId: groupId,
                audience: members, change: .letIn(newcomers: reachable, keyPackages: packages),
                attempt: attempt)
        }
    }
}
