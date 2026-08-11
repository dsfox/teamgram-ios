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

    // Two parallel arrays of the simplest types there are.
    //
    // A dictionary keyed by Int64 and holding Data looks harmless and is not:
    // Postbox encodes preferences with its own encoder, and that shape trapped
    // inside it, killing the app on the thread that writes messages. This is
    // the shape the rest of this codebase uses, and it is used here for that
    // reason rather than for elegance.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)
        let peers = try container.decodeIfPresent([Int64].self, forKey: "p") ?? []
        let groups = try container.decodeIfPresent([String].self, forKey: "g") ?? []

        var result: [Int64: Data] = [:]
        for (index, peer) in peers.enumerated() where index < groups.count {
            if let groupId = Data(base64Encoded: groups[index]) {
                result[peer] = groupId
            }
        }
        self.groupIdByPeer = result
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)
        // Sorted, so that writing the same thing twice writes the same bytes.
        let sorted = self.groupIdByPeer.sorted(by: { $0.key < $1.key })
        try container.encode(sorted.map({ $0.key }), forKey: "p")
        try container.encode(sorted.map({ $0.value.base64EncodedString() }), forKey: "g")
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
    public static func start(postbox: Postbox, accountPeerId: PeerId, network: Network, identity: MlsIdentity, peerId: PeerId) -> Signal<Data?, NoError> {
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
                //
                // Through the one writer, like every other change to this
                // state: a write that goes its own way lands out of order and
                // takes a spent secret back with it.
                MlsStateWriter.instance(accountPeerId: accountPeerId).write(postbox: postbox, state: state)
                return (postbox.transaction { transaction -> Void in
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

    /// Turns a message into what travels, or nothing if this conversation
    /// cannot carry it - in which case the caller sends as it always did.
    ///
    /// The formatting goes inside rather than beside it. An entity - bold, a
    /// link, a mention - is a pair of offsets into the text, and next to a
    /// ciphertext they point at nothing.
    public static func encrypt(postbox: Postbox, accountPeerId: PeerId, identity: MlsIdentity, group: MlsGroup, text: String, entities: [Api.MessageEntity], forwarded: Api.mls.Content.Forwarded?, media: Api.mls.Content.Media?) -> String? {
        do {
            let ciphertext = try group.encrypt(identity: identity, plaintext: Api.mls.Content.encode(text: text, entities: entities, forwarded: forwarded, media: media))
            let state = try identity.export()

            // The ratchet has moved, so it is written back - through the one
            // queue that writes it, in the order the moves happened. Writing it
            // here would mean opening a transaction inside one that may already
            // be open, on the path every message takes.
            MlsStateWriter.instance(accountPeerId: accountPeerId).write(postbox: postbox, state: state)

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
    /// puts the ciphertext aside rather than showing it.
    public static func decrypt(postbox: Postbox, accountPeerId: PeerId, identity: MlsIdentity, group: MlsGroup, text: String) -> MlsMessageContent? {
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
            MlsStateWriter.instance(accountPeerId: accountPeerId).write(postbox: postbox, state: state)

            if let content = Api.mls.Content.decode(plaintext) {
                return MlsMessageContent(
                    text: content.text,
                    entities: messageTextEntitiesFromApiEntities(content.entities),
                    forwarded: content.forwarded,
                    media: content.media)
            }
            // From a version that encrypted the bare text. Read as text rather
            // than refused: those messages are still in people's chats.
            guard let text = String(data: plaintext, encoding: .utf8) else {
                return nil
            }
            return MlsMessageContent(text: text, entities: [], forwarded: nil)
        } catch {
            Logger.shared.log("Mls", "cannot decrypt: \(error)")
            return nil
        }
    }
}

/// What a message turns out to say once it is read back: the text and the
/// formatting that belongs to it, which travelled together inside the
/// ciphertext and have to be put back together.
public struct MlsMessageContent {
    public let text: String
    public let entities: [MessageTextEntity]
    /// Who wrote it first, when this is a forward. A forward cannot travel as
    /// one here - the server copies a message by its id into a conversation
    /// whose members could never read it - so it is sent as a new message that
    /// says inside itself where it came from.
    public let forwarded: Api.mls.Content.Forwarded?
    /// What the file in this message actually is, when there is one. The server
    /// is holding it as a blob of random bytes and knows nothing else about it.
    public let media: Api.mls.Content.Media?

    public init(text: String, entities: [MessageTextEntity], forwarded: Api.mls.Content.Forwarded? = nil, media: Api.mls.Content.Media? = nil) {
        self.text = text
        self.entities = entities
        self.forwarded = forwarded
        self.media = media
    }
}

/// Reads back the messages of a conversation that arrived before this device
/// could open them, and rewrites the ones it can now read.
///
/// Without this, decryption is a single attempt made at the moment a message is
/// written into the database, and whatever it produced stays there for ever. A
/// message always can arrive before the conversation does - the welcome travels
/// by another route, and the app may not even be running - so the attempt has to
/// be repeatable or the message is lost to a race that nobody can see.
///
/// Our own messages are skipped: nothing on this device will ever read them
/// back, so trying would only waste the walk.
public func repairUnreadableMessages(postbox: Postbox, runtime: MlsRuntime, peerId: PeerId) -> Signal<Int, NoError> {
    return postbox.transaction { transaction -> Int in
        var unreadable: [MessageId] = []
        var examined = 0
        transaction.withAllMessages(peerId: peerId, { message in
            // Either kind: a message put aside on arrival, and one from before
            // any of this existed, when the ciphertext was left in the text
            // itself and every screen showed it.
            if message.attributes.contains(where: { $0 is MlsCiphertextMessageAttribute })
                || MlsConversations.isCiphertext(message.text) {
                unreadable.append(message.id)
            }
            // Bounded by what is looked at, not by what is found: a conversation
            // can hold years of messages, and this runs for every one of them at
            // startup. Stopping only once something is found would mean walking
            // every message of every chat that has nothing wrong with it.
            examined += 1
            return examined < 500
        })

        var repaired = 0
        for id in unreadable {
            guard let message = transaction.getMessage(id) else {
                continue
            }
            let held = message.attributes.first(where: { $0 is MlsCiphertextMessageAttribute }) as? MlsCiphertextMessageAttribute
            let ciphertext = held?.ciphertext ?? message.text

            // Nothing on this device will ever read back a message it wrote
            // itself, so an outgoing one is only tidied: the ciphertext leaves
            // the text and the placeholder takes its place.
            var content: MlsMessageContent?
            if message.flags.contains(.Incoming) {
                content = runtime.decrypt(peerId: peerId, text: ciphertext)
            }
            if content == nil {
                guard held == nil else {
                    // Already put aside and still unreadable: nothing to do
                    // until the conversation this belongs to turns up.
                    continue
                }
                transaction.updateMessage(id, update: { currentMessage in
                    var storeForwardInfo: StoreMessageForwardInfo?
                    if let forwardInfo = currentMessage.forwardInfo {
                        storeForwardInfo = StoreMessageForwardInfo(authorId: forwardInfo.author?.id, sourceId: forwardInfo.source?.id, sourceMessageId: forwardInfo.sourceMessageId, date: forwardInfo.date, authorSignature: forwardInfo.authorSignature, psaType: forwardInfo.psaType, flags: forwardInfo.flags)
                    }
                    let attributes = currentMessage.attributes + [MlsCiphertextMessageAttribute(ciphertext: ciphertext)]
                    return .update(StoreMessage(id: currentMessage.id, customStableId: nil, globallyUniqueId: currentMessage.globallyUniqueId, groupingKey: currentMessage.groupingKey, threadId: currentMessage.threadId, timestamp: currentMessage.timestamp, flags: StoreMessageFlags(currentMessage.flags), tags: currentMessage.tags, globalTags: currentMessage.globalTags, localTags: currentMessage.localTags, forwardInfo: storeForwardInfo, authorId: currentMessage.author?.id, text: MlsCiphertextMessageAttribute.placeholder, attributes: attributes, media: currentMessage.media))
                })
                continue
            }
            let readable = content!
            transaction.updateMessage(id, update: { currentMessage in
                var storeForwardInfo: StoreMessageForwardInfo?
                if let forwardInfo = currentMessage.forwardInfo {
                    storeForwardInfo = StoreMessageForwardInfo(authorId: forwardInfo.author?.id, sourceId: forwardInfo.source?.id, sourceMessageId: forwardInfo.sourceMessageId, date: forwardInfo.date, authorSignature: forwardInfo.authorSignature, psaType: forwardInfo.psaType, flags: forwardInfo.flags)
                }
                // The ciphertext goes with it: what it was holding open is now
                // in the message itself, and a second attempt would only fail.
                // The formatting travelled inside it and is put back with it.
                var attributes = currentMessage.attributes.filter {
                    !($0 is MlsCiphertextMessageAttribute) && !($0 is TextEntitiesMessageAttribute)
                }
                if !readable.entities.isEmpty {
                    attributes.append(TextEntitiesMessageAttribute(entities: readable.entities))
                }
                return .update(StoreMessage(id: currentMessage.id, customStableId: nil, globallyUniqueId: currentMessage.globallyUniqueId, groupingKey: currentMessage.groupingKey, threadId: currentMessage.threadId, timestamp: currentMessage.timestamp, flags: StoreMessageFlags(currentMessage.flags), tags: currentMessage.tags, globalTags: currentMessage.globalTags, localTags: currentMessage.localTags, forwardInfo: storeForwardInfo, authorId: currentMessage.author?.id, text: readable.text, attributes: attributes, media: currentMessage.media))
            })
            repaired += 1
        }

        if repaired > 0 {
            Logger.shared.log("Mls", "read back \(repaired) message(s) from \(peerId) that arrived before the conversation")
        }
        return repaired
    }
}

/// Keeps what this device can already read.
///
/// A message that arrives encrypted and unreadable carries a placeholder and
/// `MlsCiphertextMessageAttribute`. If this device already holds that same
/// message readable, the arriving copy must not replace it - and one always
/// does arrive: the server confirms a sent message by echoing it back, and the
/// person who wrote it is the one person who cannot read it.
///
/// This sits where every update finally reaches the database, rather than at
/// the one path that was found first, because the message came back by a route
/// nobody had thought about and the next one will too.
func mlsKeepingWhatIsReadable(_ messages: [StoreMessage], transaction: Transaction) -> [StoreMessage] {
    var result = messages
    for index in 0 ..< result.count {
        // Readable means text or a file: a picture sent without a caption has
        // nothing to say and is still the thing this device is holding. Asking
        // for text alone left every uncaptioned photo and video replaced by the
        // server's blob in the sender's own chat.
        guard result[index].attributes.contains(where: { $0 is MlsCiphertextMessageAttribute }),
              case let .Id(id) = result[index].id,
              let existing = transaction.getMessage(id),
              !existing.text.isEmpty || !existing.media.isEmpty,
              !existing.attributes.contains(where: { $0 is MlsCiphertextMessageAttribute }) else {
            continue
        }
        let message = result[index]
        // The formatting is kept with the text. It went inside the ciphertext,
        // so the arriving copy carries none, and taking it would leave the
        // message readable but stripped of its bold and its links.
        var attributes = message.attributes.filter {
            !($0 is MlsCiphertextMessageAttribute) && !($0 is TextEntitiesMessageAttribute)
        }
        if let entities = existing.attributes.first(where: { $0 is TextEntitiesMessageAttribute }) {
            attributes.append(entities)
        }
        result[index] = StoreMessage(
            id: message.id, customStableId: message.customStableId,
            globallyUniqueId: message.globallyUniqueId, groupingKey: message.groupingKey,
            threadId: message.threadId, timestamp: message.timestamp, flags: message.flags,
            tags: message.tags, globalTags: message.globalTags, localTags: message.localTags,
            // The attribution is local too: a forward into an encrypted chat
            // travels as an ordinary message, so the copy coming back from the
            // server carries none and taking it would turn somebody else's
            // words into the sender's own.
            forwardInfo: message.forwardInfo ?? existing.forwardInfo.flatMap { info in
                StoreMessageForwardInfo(authorId: info.author?.id, sourceId: info.source?.id, sourceMessageId: info.sourceMessageId, date: info.date, authorSignature: info.authorSignature, psaType: info.psaType, flags: info.flags)
            },
            authorId: message.authorId,
            text: existing.text,
            attributes: attributes,
            // And the file. What comes back is the blob the server is holding;
            // the real picture is the one already here, and this device is the
            // one that made it.
            media: existing.media.isEmpty ? message.media : existing.media)
    }
    return result
}

/// Puts back the text an edit was made of.
///
/// Editing sends the new text encrypted and then applies what the server sends
/// back, which for an encrypted message is a ciphertext the person who wrote it
/// cannot read - so their own message turned into a placeholder the moment they
/// changed it. What they typed is the truth here, and it is right at hand.
func mlsRestoringSentText(_ message: StoreMessage?, text: String, entities: TextEntitiesMessageAttribute?) -> StoreMessage? {
    guard let message = message,
          message.attributes.contains(where: { $0 is MlsCiphertextMessageAttribute }) else {
        return message
    }
    var attributes = message.attributes.filter {
        !($0 is MlsCiphertextMessageAttribute) && !($0 is TextEntitiesMessageAttribute)
    }
    if let entities = entities, !entities.entities.isEmpty {
        attributes.append(entities)
    }
    return StoreMessage(
        id: message.id, customStableId: message.customStableId,
        globallyUniqueId: message.globallyUniqueId, groupingKey: message.groupingKey,
        threadId: message.threadId, timestamp: message.timestamp, flags: message.flags,
        tags: message.tags, globalTags: message.globalTags, localTags: message.localTags,
        forwardInfo: message.forwardInfo, authorId: message.authorId,
        text: text, attributes: attributes, media: message.media)
}

/// Takes whatever welcomes are waiting, joins those conversations, and reads
/// back any message that arrived before them. Returns the people whose
/// conversations were opened.
///
/// A welcome waits on the server until this says the conversation is open and
/// saved. Confirming on arrival would lose it to a crash in between, and the
/// loss would surface much later, as messages that will not open.
func joinPendingWelcomes(postbox: Postbox, network: Network, accountPeerId: PeerId) -> Signal<[PeerId], NoError> {
    return Signal<[PeerId], NoError> { subscriber in
        let identity: MlsIdentity
        do {
            identity = try mlsIdentity(postbox: postbox, accountPeerId: accountPeerId)
        } catch {
            subscriber.putNext([])
            subscriber.putCompletion()
            return EmptyDisposable
        }

        let disposable = (network.request(Api.functions.mls.getWelcomes())
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.mls.Welcomes?, NoError> in
            return .single(nil)
        }
        |> mapToSignal { result -> Signal<[PeerId], NoError> in
            guard let result = result, !result.welcomes.isEmpty else {
                return .single([])
            }

            var opened: [Int64] = []
            var spent: [Int64] = []
            var peers: [Int64: Data] = [:]
            for welcome in result.welcomes {
                do {
                    let group = try MlsGroup.join(identity: identity, welcome: welcome.welcome.makeData())
                    peers[welcome.fromId] = try group.id
                    opened.append(welcome.id)
                    Logger.shared.log("Mls", "joined a conversation started by \(welcome.fromId)")
                } catch {
                    Logger.shared.log("Mls", "cannot join the conversation from \(welcome.fromId): \(error)")
                    // A welcome whose key package has already been spent can
                    // never be opened - it was opened once, which is what spent
                    // it. Left waiting it is offered again every thirty seconds
                    // for ever, and every attempt fails the same way.
                    //
                    // Anything else is left alone: it may be this device that is
                    // not ready, and a welcome dropped in that state is a
                    // conversation that exists on one side only.
                    if "\(error)".contains("NoMatchingKeyPackage") {
                        spent.append(welcome.id)
                    }
                }
            }

            if !spent.isEmpty {
                // Forgotten without ceremony: nothing here can use them.
                let _ = (network.request(Api.functions.mls.confirmWelcomes(ids: spent))
                |> `catch` { _ -> Signal<Api.mls.Ok, NoError> in
                    return .complete()
                }).start()
            }

            guard !opened.isEmpty, let state = try? identity.export() else {
                return .single([])
            }

            let joined = peers.keys.map { PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value($0)) }

            MlsStateWriter.instance(accountPeerId: accountPeerId).write(postbox: postbox, state: state)
            return postbox.transaction { transaction -> Void in
                for (fromId, groupId) in peers {
                    MlsConversationIds.remember(
                        transaction: transaction,
                        peerId: PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(fromId)),
                        groupId: groupId)
                }
            }
            |> mapToSignal { _ -> Signal<[PeerId], NoError> in
                // Only now: the conversation is open and written down. Waited
                // for rather than started and left, because the caller reads
                // messages back with these conversations the moment this
                // returns - and would find none of them.
                return MlsRuntime.instance(postbox: postbox, accountPeerId: accountPeerId).reload()
                |> mapToSignal { _ -> Signal<[PeerId], NoError> in
                    return network.request(Api.functions.mls.confirmWelcomes(ids: opened))
                    |> map { _ -> [PeerId] in joined }
                    |> `catch` { _ -> Signal<[PeerId], NoError> in
                        // The conversations are open here either way, so the
                        // messages waiting in them are worth reading back even
                        // when the server was not told.
                        return .single(joined)
                    }
                }
            }
        }).start(next: { peers in
            subscriber.putNext(peers)
        }, completed: {
            subscriber.putCompletion()
        })

        return ActionDisposable {
            disposable.dispose()
        }
    }
}

/// Joins the conversations other people have started with this device, over and
/// over, and reads back the messages that beat their welcome here.
func managedMlsWelcomes(postbox: Postbox, network: Network, accountPeerId: PeerId) -> Signal<Void, NoError> {
    let poll = joinPendingWelcomes(postbox: postbox, network: network, accountPeerId: accountPeerId)
    |> mapToSignal { peers -> Signal<Void, NoError> in
        guard !peers.isEmpty else {
            return .complete()
        }
        let runtime = MlsRuntime.instance(postbox: postbox, accountPeerId: accountPeerId)
        return combineLatest(peers.map { repairUnreadableMessages(postbox: postbox, runtime: runtime, peerId: $0) })
        |> map { _ -> Void in }
    }

    return (poll |> then(Signal<Void, NoError>.complete() |> suspendAwareDelay(30.0, queue: Queue.concurrentDefaultQueue())))
    |> restart
}
