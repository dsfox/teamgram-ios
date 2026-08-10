import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi
import MlsCore

/// Encrypted conversations, from the client's side.
///
/// Three things happen here. Starting one: take a key package for every device
/// of the other person, make a group, and leave them a welcome. Sending: turn
/// text into ciphertext. Receiving: turn it back.
///
/// Everything fails soft. If a conversation cannot be started - the other person
/// has no device published, the server is unreachable, anything - the message
/// goes as it always did, in the clear. That is worse for privacy and better
/// than a messenger that will not send, and it means this can be shipped without
/// betting the product on it.

/// What marks a message as ours. Deliberately plain text rather than something
/// invisible: a person who ends up looking at one of these in a database or an
/// old client should be able to tell what it is instead of seeing mojibake.
private let ciphertextPrefix = "mls1:"

public struct MlsConversationIds: Codable, Equatable {
    /// Which MLS group belongs to which peer. Kept beside the account rather
    /// than inside the crypto state, because it is not a secret - it is a note
    /// about which conversation is which.
    public var groupIdByPeer: [Int64: Data]

    public init(groupIdByPeer: [Int64: Data] = [:]) {
        self.groupIdByPeer = groupIdByPeer
    }
}

public extension MlsConversationIds {
    static func load(transaction: Transaction) -> MlsConversationIds {
        return transaction.getPreferencesEntry(key: PreferencesKeys.mlsConversations)?
            .get(MlsConversationIds.self) ?? MlsConversationIds()
    }

    static func remember(transaction: Transaction, peerId: PeerId, groupId: Data) {
        transaction.updatePreferencesEntry(key: PreferencesKeys.mlsConversations, { entry in
            var ids = entry?.get(MlsConversationIds.self) ?? MlsConversationIds()
            ids.groupIdByPeer[peerId.id._internalGetInt64Value()] = groupId
            return PreferencesEntry(ids)
        })
    }
}

public enum MlsConversations {
    /// The conversation with this person, or nothing if there is not one yet.
    public static func existing(identity: MlsIdentity, transaction: Transaction, peerId: PeerId) -> MlsGroup? {
        let ids = MlsConversationIds.load(transaction: transaction)
        guard let groupId = ids.groupIdByPeer[peerId.id._internalGetInt64Value()] else {
            return nil
        }
        return try? MlsGroup.load(identity: identity, id: groupId)
    }

    /// Starts one: a key package per device of the other person, a group, and a
    /// welcome left for them.
    ///
    /// Returns nothing when the other person has published no device. That is
    /// ordinary rather than broken - they may not have opened the app since
    /// this existed - and the caller sends in the clear.
    public static func start(postbox: Postbox, network: Network, identity: MlsIdentity, peerId: PeerId) -> Signal<Data?, NoError> {
        return network.request(Api.functions.mls.claimKeyPackages(userId: peerId.id._internalGetInt64Value()))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.mls.KeyPackages?, NoError> in
            return .single(nil)
        }
        |> mapToSignal { claimed -> Signal<Data?, NoError> in
            guard let claimed = claimed, !claimed.packages.isEmpty else {
                Logger.shared.log("Mls", "no key packages for \(peerId), so this goes in the clear")
                return .single(nil)
            }

            do {
                let group = try MlsGroup.create(identity: identity)
                var welcome: Data?
                // Every device of theirs is a member of its own. Adding only
                // the first would leave their other phones unable to read.
                for package in claimed.packages {
                    welcome = try group.addMember(identity: identity, keyPackage: package.makeData()).welcome
                }
                guard let welcome = welcome else {
                    return .single(nil)
                }

                let groupId = try group.id
                let state = try identity.export()

                // Saved before the welcome is sent. A welcome delivered for a
                // group this device has forgotten is a conversation the other
                // side can join and nobody can talk in.
                return (postbox.transaction { transaction -> Void in
                    MlsDeviceState.save(transaction: transaction, state: state)
                    MlsConversationIds.remember(transaction: transaction, peerId: peerId, groupId: groupId)
                }
                |> mapToSignal { _ -> Signal<Data?, NoError> in
                    return network.request(Api.functions.mls.sendWelcome(userId: peerId.id._internalGetInt64Value(), welcome: Buffer(data: welcome)))
                    |> map { _ -> Data? in
                        Logger.shared.log("Mls", "started a conversation with \(peerId)")
                        return groupId
                    }
                    |> `catch` { _ -> Signal<Data?, NoError> in
                        // The group exists here but they were never invited.
                        // Sending in the clear is right: a message they cannot
                        // read is worse than one the server can.
                        Logger.shared.log("Mls", "the welcome for \(peerId) was not delivered")
                        return .single(nil)
                    }
                })
            } catch {
                Logger.shared.log("Mls", "cannot start a conversation with \(peerId): \(error)")
                return .single(nil)
            }
        }
    }

    /// Turns text into what travels, or nothing if this conversation cannot
    /// carry it - in which case the caller sends as it always did.
    public static func encrypt(postbox: Postbox, identity: MlsIdentity, group: MlsGroup, text: String) -> String? {
        do {
            let ciphertext = try group.encrypt(identity: identity, plaintext: Data(text.utf8))
            let state = try identity.export()

            // The ratchet has moved. Saved on another queue rather than here:
            // this runs where a transaction may already be open, and waiting
            // for a second one there stops the app on the path every message
            // takes.
            Queue.concurrentDefaultQueue().async {
                let _ = (postbox.transaction { transaction -> Void in
                    MlsDeviceState.save(transaction: transaction, state: state)
                }).start()
            }

            return ciphertextPrefix + ciphertext.base64EncodedString()
        } catch {
            Logger.shared.log("Mls", "cannot encrypt: \(error)")
            return nil
        }
    }

    /// Whether this text is one of ours at all.
    public static func isCiphertext(_ text: String) -> Bool {
        return text.hasPrefix(ciphertextPrefix)
    }

    /// Turns it back, or nothing if it cannot be read - and then the caller
    /// shows what arrived rather than nothing at all.
    public static func decrypt(postbox: Postbox, identity: MlsIdentity, group: MlsGroup, text: String) -> String? {
        guard isCiphertext(text) else {
            return nil
        }
        guard let ciphertext = Data(base64Encoded: String(text.dropFirst(ciphertextPrefix.count))) else {
            Logger.shared.log("Mls", "a message marked as ours is not readable base64")
            return nil
        }

        do {
            guard let plaintext = try group.decrypt(identity: identity, ciphertext: ciphertext) else {
                // A handshake message rather than something to show.
                return nil
            }

            let state = try identity.export()
            Queue.concurrentDefaultQueue().async {
                let _ = (postbox.transaction { transaction -> Void in
                    MlsDeviceState.save(transaction: transaction, state: state)
                }).start()
            }

            return String(data: plaintext, encoding: .utf8)
        } catch {
            Logger.shared.log("Mls", "cannot decrypt: \(error)")
            return nil
        }
    }
}

/// Joins the conversations other people have started with this device.
///
/// A welcome waits on the server until this says the conversation is open and
/// saved. Confirming on arrival would lose it to a crash in between, and the
/// loss would surface much later, as messages that will not open.
func managedMlsWelcomes(postbox: Postbox, network: Network, accountPeerId: PeerId) -> Signal<Void, NoError> {
    let poll = Signal<Void, NoError> { subscriber in
        let identity: MlsIdentity
        do {
            identity = try mlsIdentity(postbox: postbox, accountPeerId: accountPeerId)
        } catch {
            subscriber.putCompletion()
            return EmptyDisposable
        }

        let disposable = (network.request(Api.functions.mls.getWelcomes())
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.mls.Welcomes?, NoError> in
            return .single(nil)
        }
        |> mapToSignal { result -> Signal<Void, NoError> in
            guard let result = result, !result.welcomes.isEmpty else {
                return .complete()
            }

            var opened: [Int64] = []
            var peers: [Int64: Data] = [:]
            for welcome in result.welcomes {
                do {
                    let group = try MlsGroup.join(identity: identity, welcome: welcome.welcome.makeData())
                    peers[welcome.fromId] = try group.id
                    opened.append(welcome.id)
                    Logger.shared.log("Mls", "joined a conversation started by \(welcome.fromId)")
                } catch {
                    // Left unconfirmed on purpose: it will be offered again,
                    // and a welcome that cannot be opened is worth noticing
                    // rather than quietly dropping.
                    Logger.shared.log("Mls", "cannot join the conversation from \(welcome.fromId): \(error)")
                }
            }

            guard !opened.isEmpty, let state = try? identity.export() else {
                return .complete()
            }

            return postbox.transaction { transaction -> Void in
                MlsDeviceState.save(transaction: transaction, state: state)
                for (fromId, groupId) in peers {
                    MlsConversationIds.remember(
                        transaction: transaction,
                        peerId: PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(fromId)),
                        groupId: groupId)
                }
            }
            |> mapToSignal { _ -> Signal<Void, NoError> in
                // Only now: the conversation is open and written down.
                MlsRuntime.instance(postbox: postbox, accountPeerId: accountPeerId).reload()
                return network.request(Api.functions.mls.confirmWelcomes(ids: opened))
                |> map { _ -> Void in }
                |> `catch` { _ -> Signal<Void, NoError> in
                    return .complete()
                }
            }
        }).start(completed: {
            subscriber.putCompletion()
        })

        return ActionDisposable {
            disposable.dispose()
        }
    }

    return (poll |> then(Signal<Void, NoError>.complete() |> suspendAwareDelay(30.0, queue: Queue.concurrentDefaultQueue())))
    |> restart
}
