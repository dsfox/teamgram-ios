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

/// A conversation, short enough to read in a log and long enough to tell two
/// apart.
///
/// Every question worth asking about encryption is which conversation something
/// happened in - which one a message was written in, which one this device is
/// sending in, which one it just joined - and none of it was in the log. A whole
/// evening went on reasoning about which group was which when the answer would
/// have been one line.
func mlsShortId(_ groupId: Data) -> String {
    return groupId.prefix(6).map({ String(format: "%02x", $0) }).joined()
}

public struct MlsConversationIds: Codable, Equatable {
    /// Which MLS group belongs to which peer. Kept beside the account rather
    /// than inside the crypto state, because it is not a secret - it is a note
    /// about which conversation is which.
    public var groupIdByPeer: [Int64: Data]

    /// When a conversation with each peer was last built or joined, in seconds.
    ///
    /// Kept on disk rather than in memory because it is what stops this device
    /// building another one over an old message that will never open. In memory
    /// it was reset by every launch, so a phone that had been set up again built
    /// a fresh conversation - and took a key package of the other side - every
    /// single time the app started.
    public var rebuiltAtByPeer: [Int64: Int32]

    public init(groupIdByPeer: [Int64: Data] = [:], rebuiltAtByPeer: [Int64: Int32] = [:]) {
        self.groupIdByPeer = groupIdByPeer
        self.rebuiltAtByPeer = rebuiltAtByPeer
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

        let rebuiltPeers = try container.decodeIfPresent([Int64].self, forKey: "rp") ?? []
        let rebuiltAt = try container.decodeIfPresent([Int32].self, forKey: "rt") ?? []
        var rebuilt: [Int64: Int32] = [:]
        for (index, peer) in rebuiltPeers.enumerated() where index < rebuiltAt.count {
            rebuilt[peer] = rebuiltAt[index]
        }
        self.rebuiltAtByPeer = rebuilt
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)
        // Sorted, so that writing the same thing twice writes the same bytes.
        let sorted = self.groupIdByPeer.sorted(by: { $0.key < $1.key })
        try container.encode(sorted.map({ $0.key }), forKey: "p")
        try container.encode(sorted.map({ $0.value.base64EncodedString() }), forKey: "g")

        let rebuilt = self.rebuiltAtByPeer.sorted(by: { $0.key < $1.key })
        try container.encode(rebuilt.map({ $0.key }), forKey: "rp")
        try container.encode(rebuilt.map({ $0.value }), forKey: "rt")
    }
}

public extension PeerId {
    /// How a conversation is filed: the whole peer id, namespace and all.
    ///
    /// It used to be the bare id, which is the same number for a person and for
    /// a group - invisible while every encrypted chat was between two people,
    /// and wrong the moment groups arrived: they would overwrite each other,
    /// and a commit naming only a group id could not say which chat to read
    /// back (#111).
    var mlsKey: Int64 {
        return self.toInt64()
    }

    /// The peer a filed conversation belongs to.
    ///
    /// Keys written before the namespace was kept are bare user ids, and for
    /// every id below 2^32 that is bit for bit what toInt64 produces for a
    /// CloudUser - so they read back correctly here without a migration. Above
    /// that they would not, which is why what is written from now on carries
    /// the namespace rather than being assumed to.
    ///
    /// A function rather than an initialiser, and that is not taste: an
    /// `init(mlsKey:)` makes the bare `PeerId.init` ambiguous everywhere it is
    /// passed as a function - `flatMap(PeerId.init)` and its like - and this
    /// codebase does that in dozens of places. Eighty-nine errors, none of them
    /// anywhere near here.
    static func fromMlsKey(_ key: Int64) -> PeerId {
        return PeerId(key)
    }

    /// How a chat is named on the wire between the two clients: the dialog id,
    /// negative for a group and positive for a person.
    ///
    /// Not `mlsKey`, which is this client's packed form and means nothing to the
    /// other one. Sending the packed form and reading it back as a dialog id
    /// crashed on arrival - `PeerId.Id` refuses a negative number, and it does
    /// so with an assertion, on the path every invitation takes.
    var dialogId: Int64 {
        let bare = self.id._internalGetInt64Value()
        return self.namespace == Namespaces.Peer.CloudGroup ? -bare : bare
    }

    static func fromDialogId(_ dialogId: Int64) -> PeerId {
        if dialogId < 0 {
            return PeerId(namespace: Namespaces.Peer.CloudGroup,
                          id: PeerId.Id._internalFromInt64Value(-dialogId))
        }
        return PeerId(namespace: Namespaces.Peer.CloudUser,
                      id: PeerId.Id._internalFromInt64Value(dialogId))
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
            ids.groupIdByPeer[peerId.mlsKey] = groupId
            ids.rebuiltAtByPeer[peerId.mlsKey] = Int32(Date().timeIntervalSince1970)
            return PreferencesEntry(ids)
        })
    }
}

public enum MlsConversations {
    /// The conversation with this person, or nothing if there is not one yet.
    public static func existing(identity: MlsIdentity, transaction: Transaction, peerId: PeerId) -> MlsGroup? {
        let ids = MlsConversationIds.load(transaction: transaction)
        guard let groupId = ids.groupIdByPeer[peerId.mlsKey] else {
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
    /// Everybody who has to be able to read what is written here.
    ///
    /// One person for a conversation between two; every member but this account
    /// for a group. Empty when the membership is not known here yet - the caller
    /// then sends in the clear rather than encrypting to a list it is guessing
    /// at, which would leave somebody out of their own conversation (#40).
    private static func members(postbox: Postbox, accountPeerId: PeerId, peerId: PeerId) -> Signal<[PeerId], NoError> {
        if peerId.namespace == Namespaces.Peer.CloudUser {
            return .single([peerId])
        }
        return postbox.transaction { transaction -> [PeerId] in
            guard let cached = transaction.getPeerCachedData(peerId: peerId) as? CachedGroupData,
                  let participants = cached.participants else {
                return []
            }
            return participants.participants.map { $0.peerId }.filter { $0 != accountPeerId }
        }
    }

    public static func start(postbox: Postbox, accountPeerId: PeerId, network: Network, identity: MlsIdentity, peerId: PeerId) -> Signal<Data?, NoError> {
        return members(postbox: postbox, accountPeerId: accountPeerId, peerId: peerId)
        |> mapToSignal { members -> Signal<Data?, NoError> in
            guard !members.isEmpty else {
                Logger.shared.log("Mls", "no membership for \(peerId), so this goes in the clear")
                return .single(nil)
            }
            // Every member's packages before anything is created. All of them
            // or none: a member whose devices we cannot reach would sit in a
            // chat where every message is unreadable, and unreadable messages
            // are hidden - a silent empty chat rather than an honest
            // unencrypted one.
            return combineLatest(members.map { member in
                network.request(Api.functions.mls.claimKeyPackages(userId: member.id._internalGetInt64Value()))
                |> map(Optional.init)
                |> `catch` { _ -> Signal<Api.mls.KeyPackages?, NoError> in .single(nil) }
            })
            |> mapToSignal { answers -> Signal<Data?, NoError> in
                var packages: [Data] = []
                for (index, answer) in answers.enumerated() {
                    guard let answer = answer, !answer.packages.isEmpty else {
                        Logger.shared.log("Mls", "no key packages for \(members[index]), so this goes in the clear")
                        return .single(nil)
                    }
                    packages.append(contentsOf: answer.packages.map { $0.makeData() })
                }
                return build(postbox: postbox, accountPeerId: accountPeerId, network: network, identity: identity, peerId: peerId, members: members, packages: packages)
            }
        }
    }

    private static func build(postbox: Postbox, accountPeerId: PeerId, network: Network, identity: MlsIdentity, peerId: PeerId, members: [PeerId], packages: [Data]) -> Signal<Data?, NoError> {
            do {
                let group = try MlsGroup.create(identity: identity)
                // Every device of theirs at once, because there is one welcome
                // to send and it has to serve all of them. Added one at a time
                // this kept the last welcome and threw the rest away, so which
                // of their phones could join was chance - and for somebody who
                // has set a phone up more than once, most of those rows belong
                // to devices that no longer exist. Both sides then held a
                // conversation the other was not in.
                let welcome = try group.addMembers(
                    identity: identity,
                    keyPackages: packages).welcome
                // Taken here and not asked about, which is the one place that
                // is right: this group did not exist a moment ago, so there is
                // nobody to have raced with and nothing for the delivery
                // service to order. Every later change waits for its answer.
                //
                // Without this the creator stays at the epoch before its own
                // commit while everybody it invited lands at the epoch after,
                // and not one message opens. It compiles perfectly.
                try group.acceptCommit(identity: identity)

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
                // And only now asked whether this chat is ours to start.
                //
                // Nothing decided which conversation a chat's was, so every
                // device that wanted to send into one without a conversation
                // started its own. Between two people that almost always lands
                // on one; three people beginning a group within a minute ended
                // in two conversations that cannot read each other, with no way
                // back (#135). The devices cannot settle it among themselves -
                // whoever loses has to be told, and when everybody is offline
                // and arrives in a random order there is nobody to tell them.
                //
                // A claim that loses leaves the group made here unused: it is
                // never bound to the chat, so nothing looks at it again, and the
                // way in is the ordinary one - this device is in the chat with
                // no leaf in the conversation that won, and its members let it
                // in.
                //
                // An unanswered claim adopts nothing. Going ahead on a claim
                // that was not granted is exactly the split this exists to stop,
                // and it is the one mistake here with no way back; a chat can
                // wait for the next attempt, and until then a message goes as it
                // always did.
                return (network.request(Api.functions.mls.claimConversation(
                            peerId: peerId.dialogId, groupId: Buffer(data: groupId)))
                |> map(Optional.init)
                |> `catch` { _ -> Signal<Api.mls.Conversation?, NoError> in .single(nil) }
                |> mapToSignal { held -> Signal<Data?, NoError> in
                    guard let held = held else {
                        Logger.shared.log("Mls", "nobody said whose conversation \(peerId) is, not starting one")
                        return .single(nil)
                    }
                    guard held.groupId.makeData() == groupId else {
                        Logger.shared.log("Mls", "\(peerId) already has conversation \(mlsShortId(held.groupId.makeData())), letting go of the one just made and waiting to be let in")
                        // Nobody is bound to it, so nothing would look at it
                        // again - but everything this device knows about
                        // encryption is one blob, read whole and written whole
                        // on every message (#112), and what is never removed is
                        // carried for ever. Somebody typing while they wait to
                        // be let in makes one of these per message.
                        let runtime = MlsRuntime.instance(postbox: postbox, accountPeerId: accountPeerId)
                        let _ = runtime.withState { identity -> Void in
                            MlsGroup.forget(identity: identity, id: groupId)
                        }
                        return .single(nil)
                    }
                    return postbox.transaction { transaction -> Void in
                        MlsConversationIds.remember(transaction: transaction, peerId: peerId, groupId: groupId)
                    }
                |> mapToSignal { _ -> Signal<Data?, NoError> in
                    // One welcome, handed to each member separately: the
                    // mailbox is addressed to a person, and add_members made a
                    // single welcome that serves all of them.
                    return combineLatest(members.map { member in
                        network.request(Api.functions.mls.sendWelcome(
                            userId: member.id._internalGetInt64Value(),
                            peerId: peerId.dialogId,
                            welcome: Buffer(data: welcome)))
                        |> map(Optional.init)
                        |> `catch` { _ -> Signal<Api.mls.Ok?, NoError> in
                            // The group exists here and somebody was never
                            // invited. Sending in the clear from here on is
                            // right: a message they cannot read is worse than
                            // one the server can.
                            Logger.shared.log("Mls", "the welcome for \(member) was not delivered")
                            return .single(nil)
                        }
                    })
                    |> map { _ -> Data? in
                        Logger.shared.log("Mls", "started conversation \(mlsShortId(groupId)) with \(members.count) member(s) of \(peerId.id._internalGetInt64Value())")
                        return groupId
                    }
                }
                })
            } catch {
                Logger.shared.log("Mls", "cannot start a conversation with \(peerId): \(error)")
                return .single(nil)
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

    /// Which conversation this message belongs to, or nothing when it says
    /// nothing this device can use.
    ///
    /// The message is opened with the conversation it names rather than the one
    /// this device happens to keep for the person who sent it, because those are
    /// not always the same conversation. Every reinstall makes them differ: the
    /// phone that was set up again has lost every group it was in and starts a
    /// new one, while the other side goes on sending in the old one until the
    /// welcome arrives. Picking by person there opens neither.
    public static func conversation(ofCiphertext text: String) -> Data? {
        guard isCiphertext(text),
              let ciphertext = Data(base64Encoded: String(text.dropFirst(ciphertextPrefix.count))) else {
            return nil
        }
        return try? MlsGroup.groupId(ofMessage: ciphertext)
    }

    /// What came of trying to read a message.
    ///
    /// Not readable is three different things, and telling them apart decides
    /// what happens next. A message this device wrote is the one that matters:
    /// MLS never lets a sender read their own ciphertext, so an outgoing message
    /// comes back from the server looking exactly like a conversation that is
    /// broken - and the client, believing it, threw the conversation away and
    /// built another one after every message it sent. Both sides chased each
    /// other through new groups all evening.
    public enum Reading {
        case content(MlsMessageContent)
        /// A handshake message, or nothing this device can show.
        case nothing
        /// Written here. Nobody on this device will ever read it back, and that
        /// is the design rather than a fault.
        case writtenHere
        /// Not readable here, and it may mean the conversation needs rebuilding.
        case unreadable

        /// What there is to show, for the callers that only want that.
        public var content: MlsMessageContent? {
            if case let .content(content) = self {
                return content
            }
            return nil
        }
    }

    /// Turns it back, or says why it could not - and the caller puts the
    /// ciphertext aside rather than showing it.
    public static func decrypt(postbox: Postbox, accountPeerId: PeerId, identity: MlsIdentity, group: MlsGroup, text: String) -> Reading {
        guard isCiphertext(text) else {
            return .nothing
        }
        guard let ciphertext = Data(base64Encoded: String(text.dropFirst(ciphertextPrefix.count))) else {
            Logger.shared.log("Mls", "a message marked as ours is not readable base64")
            return .unreadable
        }

        do {
            guard let plaintext = try group.decrypt(identity: identity, ciphertext: ciphertext) else {
                // A handshake message rather than something to show.
                return .nothing
            }

            let state = try identity.export()
            MlsStateWriter.instance(accountPeerId: accountPeerId).write(postbox: postbox, state: state)

            if let content = Api.mls.Content.decode(plaintext) {
                return .content(MlsMessageContent(
                    text: content.text,
                    entities: messageTextEntitiesFromApiEntities(content.entities),
                    forwarded: content.forwarded,
                    media: content.media))
            }
            // From a version that encrypted the bare text. Read as text rather
            // than refused: those messages are still in people's chats.
            guard let text = String(data: plaintext, encoding: .utf8) else {
                return .unreadable
            }
            return .content(MlsMessageContent(text: text, entities: [], forwarded: nil))
        } catch {
            // The sender's own message. Said quietly, because it happens to
            // every message anybody sends and means nothing is wrong.
            if "\(error)".contains("CannotDecryptOwnMessage") {
                return .writtenHere
            }
            // With the epoch this device is at, because the commonest reason a
            // message will not open is that it was written in another one, and
            // the error says which kind of wrong without saying how far.
            Logger.shared.log("Mls", "cannot decrypt at epoch \(group.epoch): \(error)")
            return .unreadable
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
        // The state is borrowed below, once the answer is here, and not before.
        // Reading a copy of it now and using it afterwards meant holding it
        // across a round trip - seconds in which anything else that moved the
        // ratchet was about to be overwritten by this (#112).
        let runtime = MlsRuntime.instance(postbox: postbox, accountPeerId: accountPeerId)

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
            // Keyed by the chat the invitation names, not by whoever sent it.
            var peers: [PeerId: Data] = [:]
            _ = runtime.withState { identity in
                for welcome in result.welcomes {
                    do {
                        let group = try MlsGroup.join(identity: identity, welcome: welcome.welcome.makeData())
                        let joinedId = try group.id
                        // Where the invitation says, and only otherwise under
                        // the person who sent it. That guess is right for a
                        // chat between two and wrong for a group: it recorded
                        // the group as the conversation with whoever invited
                        // them, so a private message to that person went into
                        // the group, and a commit meant for the whole group
                        // went to one member (#115).
                        let belongsTo = welcome.peerId != 0
                            ? PeerId.fromDialogId(welcome.peerId)
                            : PeerId(namespace: Namespaces.Peer.CloudUser,
                                     id: PeerId.Id._internalFromInt64Value(welcome.fromId))
                        peers[belongsTo] = joinedId
                        opened.append(welcome.id)
                        // With the epoch, because without it there is no telling a
                        // welcome that was taken from one that was declined in
                        // favour of a group this device already had: both say
                        // "joined", and only one of them can read what comes next.
                        Logger.shared.log("Mls", "joined conversation \(mlsShortId(joinedId)) for \(belongsTo) at epoch \(group.epoch), invited by \(welcome.fromId)")
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
            }

            if !spent.isEmpty {
                // Forgotten without ceremony: nothing here can use them.
                let _ = (network.request(Api.functions.mls.confirmWelcomes(ids: spent))
                |> `catch` { _ -> Signal<Api.mls.Ok, NoError> in
                    return .complete()
                }).start()
            }

            guard !opened.isEmpty else {
                return .single([])
            }

            let joined = Array(peers.keys)

            // Taken here rather than written down by what follows. Everything
            // after this point is asynchronous and does not always run to the
            // end; a conversation that exists only until the next restart is
            // one the device rebuilds, and then the two sides have one each.
            for (peer, groupId) in peers {
                runtime.adopt(peerId: peer, groupId: groupId)
            }

            return network.request(Api.functions.mls.confirmWelcomes(ids: opened))
            |> map { _ -> [PeerId] in joined }
            |> `catch` { _ -> Signal<[PeerId], NoError> in
                // The conversations are open here either way, so the messages
                // waiting in them are worth reading back even when the server
                // was not told.
                return .single(joined)
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

/// Applies the membership changes waiting for this device, and says which
/// conversations moved.
///
/// The twin of joinPendingWelcomes, for the other box. A commit is what takes a
/// group from one epoch to the next - somebody added, somebody removed - and a
/// device that has not applied one can read nothing said afterwards. It is
/// ordinary to be behind: the commit and the message travel by different routes
/// and the message often wins.
///
/// Order is the whole discipline here. Commits arrive oldest first because a
/// commit applies only to the epoch it was made from, so out of order every one
/// but the first fails. Anything already behind this device's own epoch has
/// been applied before and is dropped on sight - the same commit arrives twice
/// on ordinary routes, through a confirmation that was lost or a device that
/// stopped before saving.
/// Private on purpose: applying a commit without going back for the messages it
/// opens leaves them hidden for good, so the only way in is catchUpWithTheGroup,
/// which does both.
private func applyPendingCommits(postbox: Postbox, network: Network, accountPeerId: PeerId) -> Signal<[Data], NoError> {
    return Signal<[Data], NoError> { subscriber in
        // Borrowed below, once the answer is here. A copy read now and used
        // afterwards is a copy held across a round trip, and whatever else
        // moved the ratchet in those seconds would be overwritten by it (#112).
        let runtime = MlsRuntime.instance(postbox: postbox, accountPeerId: accountPeerId)

        let disposable = (network.request(Api.functions.mls.getCommits())
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.mls.Commits?, NoError> in
            return .single(nil)
        }
        |> mapToSignal { result -> Signal<[Data], NoError> in
            guard let result = result, !result.commits.isEmpty else {
                return .single([])
            }

            var applied: [Int64] = []
            var moved: [Data] = []
            _ = runtime.withState { identity in
                for waiting in result.commits {
                    let groupId = waiting.groupId.makeData()
                    guard let group = try? MlsGroup.load(identity: identity, id: groupId) else {
                        // A conversation this device is not in yet. Ordinary while
                        // the welcome is still travelling, and it must not be
                        // confirmed - that would throw away the only copy.
                        continue
                    }
                    let epoch = Int64(group.epoch)
                    if waiting.epoch < epoch {
                        applied.append(waiting.id)
                        continue
                    }
                    if waiting.epoch > epoch {
                        // Not this one's turn: an earlier commit for this
                        // conversation has still to arrive.
                        continue
                    }
                    do {
                        let somebodyElses = try group.applyCommit(
                            identity: identity, commit: waiting.commit.makeData())
                        applied.append(waiting.id)
                        if somebodyElses {
                            moved.append(groupId)
                            Logger.shared.log("Mls", "\(mlsShortId(groupId)) moved to epoch \(waiting.epoch + 1), changed by \(waiting.fromId)")
                        } else {
                            Logger.shared.log("Mls", "our own change to \(mlsShortId(groupId)) was taken after all")
                        }
                    } catch {
                        // Left unconfirmed on purpose: it may become applicable
                        // once an earlier one arrives.
                        Logger.shared.log("Mls", "cannot apply a commit to \(mlsShortId(groupId)): \(error)")
                    }
                }
            }

            // Saved before anything is confirmed, and in that order. A commit
            // confirmed and then lost leaves this device an epoch behind, where
            // nothing new opens - which surfaces much later as a conversation
            // that went quiet for one person, and looks like anything but a
            // lost commit. The saving is done by withState, on the way out.
            guard !applied.isEmpty else {
                return .single([])
            }

            return network.request(Api.functions.mls.confirmCommits(ids: applied))
            |> map { _ -> [Data] in moved }
            |> `catch` { _ -> Signal<[Data], NoError> in
                // Unconfirmed means they arrive again, which is harmless: one
                // already applied is behind this device's epoch and is dropped
                // on sight.
                return .single(moved)
            }
        }).start(next: { moved in
            subscriber.putNext(moved)
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

/// Applies the membership changes waiting for this device, over and over, and
/// reads back the messages that were written in an epoch it had not reached.
///
/// The twin of managedMlsWelcomes, on the same rhythm and for the same reason:
/// what opens a message travels by a different route from the message, and
/// nothing reliably says when it has arrived. Asking every half minute is what
/// the welcome box already does, and this is the other box.
///
/// A commit says which conversation moved and cannot say which chat that is -
/// the server does not know, and must not. So the chats are found by looking up
/// each group among the ones this device holds; anything that cannot be placed
/// is still applied, and only the reading back is skipped.
func managedMlsCommits(postbox: Postbox, network: Network, accountPeerId: PeerId) -> Signal<Void, NoError> {
    let poll = catchUpWithTheGroup(postbox: postbox, network: network, accountPeerId: accountPeerId)
    // And how many devices this account has, on this rhythm rather than on the
    // key packages' quarter of an hour.
    //
    // That count is the only thing that tells this phone another of its own has
    // been signed out, and taking the signed-out phone's leaf out is what stops
    // it reading. Asked every fifteen minutes, "the session was ended" and "the
    // phone stopped reading" were up to fifteen minutes apart, and the phone in
    // the drawer opened everything said in between (#121).
    //
    // It costs one small request per half minute: an empty publish is the
    // question, so the server counts and stores nothing. The pass it feeds
    // compares leaves against the count and returns at once when they agree,
    // which is every time but one.
    |> then(askHowManyDevices(postbox: postbox, network: network, accountPeerId: accountPeerId))

    return (poll |> then(Signal<Void, NoError>.complete() |> suspendAwareDelay(30.0, queue: Queue.concurrentDefaultQueue())))
    |> restart
}

/// Applies whatever changes are waiting and goes back for the messages they
/// make readable.
///
/// The two halves belong together and were once apart, which is how a message
/// stayed hidden for good: a commit arrived a second after the message that
/// needed it, was applied by somebody rebuilding a change they had lost the
/// race for, and nothing then went back to read the message - the poll that
/// would have has already had that commit taken from under it. Seen on the
/// stand: written at 10:47:44.267, openable from 10:47:44.901, never opened.
///
/// So every path that applies a commit reads back through this one.
func catchUpWithTheGroup(postbox: Postbox, network: Network, accountPeerId: PeerId, applied: Atomic<Bool>? = nil) -> Signal<Void, NoError> {
    return applyPendingCommits(postbox: postbox, network: network, accountPeerId: accountPeerId)
    |> mapToSignal { moved -> Signal<Void, NoError> in
        // Whether there was anything at all, which is what tells a device that
        // lost an epoch apart from one that has fallen out of the group (#116).
        if let applied = applied, !moved.isEmpty {
            let _ = applied.swap(true)
        }
        guard !moved.isEmpty else {
            return .complete()
        }
        let runtime = MlsRuntime.instance(postbox: postbox, accountPeerId: accountPeerId)
        return runtime.reload()
        |> mapToSignal { _ -> Signal<Void, NoError> in
            // A commit says which conversation moved and cannot say which chat
            // that is - the server does not know, and must not. So the chats
            // are found by looking up each group among the ones this device
            // holds; anything that cannot be placed is still applied, and only
            // the reading back is skipped.
            let peers = runtime.peers(ofConversations: moved)
            guard !peers.isEmpty else {
                return .complete()
            }
            return combineLatest(peers.map { repairUnreadableMessages(postbox: postbox, runtime: runtime, peerId: $0) })
            |> map { _ -> Void in }
        }
    }
}
