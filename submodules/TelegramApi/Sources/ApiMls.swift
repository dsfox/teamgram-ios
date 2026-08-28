import Foundation

/// Our own methods, for end-to-end encryption on MLS.
///
/// In a file of its own rather than among the generated ones. Everything in
/// Api0…Api49 comes out of Telegram's schema and is replaced wholesale when
/// that schema moves; anything of ours living there would be lost on the next
/// update without a word. Here it survives, and a merge conflict is impossible
/// because upstream never touches this file.
///
/// The constructor ids are the CRC32 of the declarations written above each
/// function - the way TL makes them - and the server computes them from the same
/// text. If the two ever disagree the server answers with a constructor this
/// cannot parse, which is why both sides carry the declaration as a comment
/// rather than only the number.
public extension Api.functions {
    enum mls {
        /// mls.publishKeyPackages key_packages:Vector<bytes> last_resort:bytes = mls.PublishResult;
        public static func publishKeyPackages(keyPackages: [Buffer], lastResort: Buffer) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.mls.PublishResult>) {
            let buffer = Buffer()
            buffer.appendInt32(940659472)
            buffer.appendInt32(481674261)
            buffer.appendInt32(Int32(keyPackages.count))
            for item in keyPackages {
                serializeBytes(item, buffer: buffer, boxed: false)
            }
            serializeBytes(lastResort, buffer: buffer, boxed: false)
            return (FunctionDescription(name: "mls.publishKeyPackages", parameters: [("keyPackages", ConstructorParameterDescription(keyPackages)), ("lastResort", ConstructorParameterDescription(lastResort))]), buffer, DeserializeFunctionResponse { (buffer: Buffer) -> Api.mls.PublishResult? in
                let reader = BufferReader(buffer)
                return Api.mls.PublishResult.parse(reader)
            })
        }

        /// mls.sendWelcome user_id:long peer_id:long welcome:bytes = mls.Ok;
        ///
        /// peerId is which chat the invitation is for, as a dialog id. Without
        /// it a welcome says only who sent it, and the device joining files the
        /// conversation under that person - so a group is recorded as the
        /// conversation with whoever invited them (#115).
        public static func sendWelcome(userId: Int64, peerId: Int64, welcome: Buffer) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.mls.Ok>) {
            let buffer = Buffer()
            buffer.appendInt32(2042714623)
            serializeInt64(userId, buffer: buffer, boxed: false)
            serializeInt64(peerId, buffer: buffer, boxed: false)
            serializeBytes(welcome, buffer: buffer, boxed: false)
            return (FunctionDescription(name: "mls.sendWelcome", parameters: [("userId", ConstructorParameterDescription(userId))]), buffer, DeserializeFunctionResponse { (buffer: Buffer) -> Api.mls.Ok? in
                let reader = BufferReader(buffer)
                return Api.mls.Ok.parse(reader)
            })
        }

        /// mls.getWelcomes = mls.Welcomes;
        public static func getWelcomes() -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.mls.Welcomes>) {
            let buffer = Buffer()
            buffer.appendInt32(-512239425)
            return (FunctionDescription(name: "mls.getWelcomes", parameters: []), buffer, DeserializeFunctionResponse { (buffer: Buffer) -> Api.mls.Welcomes? in
                let reader = BufferReader(buffer)
                return Api.mls.Welcomes.parse(reader)
            })
        }

        /// mls.confirmWelcomes ids:Vector<long> = mls.Ok;
        public static func confirmWelcomes(ids: [Int64]) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.mls.Ok>) {
            let buffer = Buffer()
            buffer.appendInt32(-1226029994)
            buffer.appendInt32(481674261)
            buffer.appendInt32(Int32(ids.count))
            for item in ids {
                serializeInt64(item, buffer: buffer, boxed: false)
            }
            return (FunctionDescription(name: "mls.confirmWelcomes", parameters: [("ids", ConstructorParameterDescription(ids))]), buffer, DeserializeFunctionResponse { (buffer: Buffer) -> Api.mls.Ok? in
                let reader = BufferReader(buffer)
                return Api.mls.Ok.parse(reader)
            })
        }

        /// mls.setRecoverySecret secret:string = mls.Ok;
        ///
        /// The way back into this account, registered by the device that owns
        /// it. What travels is a one-way derivation of the recovery phrase; the
        /// words are made here and never leave. The server used to make them
        /// and send them as a message, which left every one of them in its
        /// message table in plain text.
        public static func setRecoverySecret(secret: String) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.mls.Ok>) {
            let buffer = Buffer()
            buffer.appendInt32(-369099376)
            serializeString(secret, buffer: buffer, boxed: false)
            return (FunctionDescription(name: "mls.setRecoverySecret", parameters: []), buffer, DeserializeFunctionResponse { (buffer: Buffer) -> Api.mls.Ok? in
                let reader = BufferReader(buffer)
                return Api.mls.Ok.parse(reader)
            })
        }

        /// mls.sendCommit group_id:bytes epoch:long members:Vector<long> commit:bytes = mls.CommitResult;
        ///
        /// A membership change, offered to the delivery service. It is the one
        /// place the server has an opinion about a conversation: MLS validates
        /// a commit against the epoch it was made from, so of two made from the
        /// same epoch exactly one can be taken, and RFC 9420 gives that
        /// ordering to the delivery service. The answer says which.
        public static func sendCommit(groupId: Buffer, epoch: Int64, members: [Int64], commit: Buffer) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.mls.CommitResult>) {
            let buffer = Buffer()
            buffer.appendInt32(-945155929)
            serializeBytes(groupId, buffer: buffer, boxed: false)
            serializeInt64(epoch, buffer: buffer, boxed: false)
            buffer.appendInt32(481674261)
            buffer.appendInt32(Int32(members.count))
            for item in members {
                serializeInt64(item, buffer: buffer, boxed: false)
            }
            serializeBytes(commit, buffer: buffer, boxed: false)
            return (FunctionDescription(name: "mls.sendCommit", parameters: [("epoch", ConstructorParameterDescription(epoch))]), buffer, DeserializeFunctionResponse { (buffer: Buffer) -> Api.mls.CommitResult? in
                let reader = BufferReader(buffer)
                return Api.mls.CommitResult.parse(reader)
            })
        }

        /// mls.getCommits = mls.Commits;
        public static func getCommits() -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.mls.Commits>) {
            let buffer = Buffer()
            buffer.appendInt32(1356576713)
            return (FunctionDescription(name: "mls.getCommits", parameters: []), buffer, DeserializeFunctionResponse { (buffer: Buffer) -> Api.mls.Commits? in
                let reader = BufferReader(buffer)
                return Api.mls.Commits.parse(reader)
            })
        }

        /// mls.confirmCommits ids:Vector<long> = mls.Ok;
        ///
        /// Applied, not received. A device that took a commit and stopped
        /// before saving the state it produced has to be given it again, or it
        /// sits an epoch behind and the conversation goes quiet for that person
        /// alone.
        public static func confirmCommits(ids: [Int64]) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.mls.Ok>) {
            let buffer = Buffer()
            buffer.appendInt32(96655983)
            buffer.appendInt32(481674261)
            buffer.appendInt32(Int32(ids.count))
            for item in ids {
                serializeInt64(item, buffer: buffer, boxed: false)
            }
            return (FunctionDescription(name: "mls.confirmCommits", parameters: [("ids", ConstructorParameterDescription(ids))]), buffer, DeserializeFunctionResponse { (buffer: Buffer) -> Api.mls.Ok? in
                let reader = BufferReader(buffer)
                return Api.mls.Ok.parse(reader)
            })
        }

        /// mls.claimKeyPackages user_id:long = mls.KeyPackages;
        public static func claimKeyPackages(userId: Int64) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.mls.KeyPackages>) {
            let buffer = Buffer()
            buffer.appendInt32(88879177)
            serializeInt64(userId, buffer: buffer, boxed: false)
            return (FunctionDescription(name: "mls.claimKeyPackages", parameters: [("userId", ConstructorParameterDescription(userId))]), buffer, DeserializeFunctionResponse { (buffer: Buffer) -> Api.mls.KeyPackages? in
                let reader = BufferReader(buffer)
                return Api.mls.KeyPackages.parse(reader)
            })
        }
    }
}

public extension Api {
    enum mls {
        /// mls.publishResult added:int available:int should_refill:Bool devices:int = mls.PublishResult;
        public struct PublishResult {
            public let added: Int32
            public let available: Int32
            /// Whether this device should make more. The server counts; the
            /// device is the only one that can make them.
            public let shouldRefill: Swift.Bool
            /// How many devices of this account have published anything.
            ///
            /// The one thing that tells this phone another phone of the same
            /// person has signed in: comparing a conversation with its chat is
            /// about people, so a second device of somebody already in it is
            /// invisible there (#41).
            public let devices: Int32

            public static func parse(_ reader: BufferReader) -> PublishResult? {
                guard let signature = reader.readInt32(), signature == -472421573 else {
                    return nil
                }
                guard let added = reader.readInt32(),
                      let available = reader.readInt32(),
                      let refill = reader.readInt32(),
                      let devices = reader.readInt32() else {
                    return nil
                }
                return PublishResult(added: added, available: available,
                                     shouldRefill: refill == -1720552011, devices: devices)
            }
        }

        /// mls.ok ok:Bool = mls.Ok;
        public struct Ok {
            public let ok: Swift.Bool

            public static func parse(_ reader: BufferReader) -> Ok? {
                guard let signature = reader.readInt32(), signature == -1518331278 else {
                    return nil
                }
                guard let value = reader.readInt32() else {
                    return nil
                }
                return Ok(ok: value == -1720552011)
            }
        }

        /// mls.welcome id:long from_id:long peer_id:long welcome:bytes = mls.Welcome;
        public struct Welcome {
            public let id: Int64
            public let fromId: Int64
            /// The chat this invitation is for; zero for one written before
            /// invitations carried it, and then the sender is all there is.
            public let peerId: Int64
            public let welcome: Buffer

            static func parse(_ reader: BufferReader) -> Welcome? {
                guard let signature = reader.readInt32(), signature == 215890102 else {
                    return nil
                }
                guard let id = reader.readInt64(),
                      let fromId = reader.readInt64(),
                      let peerId = reader.readInt64(),
                      let welcome = parseBytes(reader) else {
                    return nil
                }
                return Welcome(id: id, fromId: fromId, peerId: peerId, welcome: welcome)
            }
        }

        /// mls.welcomes welcomes:Vector<mls.Welcome> = mls.Welcomes;
        public struct Welcomes {
            public let welcomes: [Welcome]

            public static func parse(_ reader: BufferReader) -> Welcomes? {
                guard let signature = reader.readInt32(), signature == -1921518262 else {
                    return nil
                }
                guard let vector = reader.readInt32(), vector == 481674261 else {
                    return nil
                }
                guard let count = reader.readInt32() else {
                    return nil
                }
                var welcomes: [Welcome] = []
                for _ in 0 ..< count {
                    guard let item = Welcome.parse(reader) else {
                        return nil
                    }
                    welcomes.append(item)
                }
                return Welcomes(welcomes: welcomes)
            }
        }

        /// mls.commitResult accepted:Bool epoch:long = mls.CommitResult;
        public struct CommitResult {
            public let accepted: Swift.Bool
            /// Where the conversation really is. Present on refusal too, which
            /// is the whole point: it tells the loser of a race how far behind
            /// it is without another round trip.
            public let epoch: Int64

            public static func parse(_ reader: BufferReader) -> CommitResult? {
                guard let signature = reader.readInt32(), signature == 191372459 else {
                    return nil
                }
                guard let accepted = reader.readInt32(),
                      let epoch = reader.readInt64() else {
                    return nil
                }
                return CommitResult(accepted: accepted == -1720552011, epoch: epoch)
            }
        }

        /// mls.commit id:long from_id:long group_id:bytes epoch:long commit:bytes = mls.Commit;
        public struct Commit {
            public let id: Int64
            public let fromId: Int64
            public let groupId: Buffer
            /// The epoch this commit was made from. A device applies them in
            /// this order and can tell at a glance whether one is behind it.
            public let epoch: Int64
            public let commit: Buffer

            static func parse(_ reader: BufferReader) -> Commit? {
                guard let signature = reader.readInt32(), signature == -130530128 else {
                    return nil
                }
                guard let id = reader.readInt64(),
                      let fromId = reader.readInt64(),
                      let groupId = parseBytes(reader),
                      let epoch = reader.readInt64(),
                      let commit = parseBytes(reader) else {
                    return nil
                }
                return Commit(id: id, fromId: fromId, groupId: groupId, epoch: epoch, commit: commit)
            }
        }

        /// mls.commits commits:Vector<mls.Commit> = mls.Commits;
        public struct Commits {
            /// Oldest first, and that is not a nicety: a commit applies only to
            /// the epoch it was made from, so out of order every one but the
            /// first fails.
            public let commits: [Commit]

            public static func parse(_ reader: BufferReader) -> Commits? {
                guard let signature = reader.readInt32(), signature == -902742102 else {
                    return nil
                }
                guard let vector = reader.readInt32(), vector == 481674261 else {
                    return nil
                }
                guard let count = reader.readInt32() else {
                    return nil
                }
                var commits: [Commit] = []
                for _ in 0 ..< count {
                    guard let item = Commit.parse(reader) else {
                        return nil
                    }
                    commits.append(item)
                }
                return Commits(commits: commits)
            }
        }

        /// mls.keyPackages packages:Vector<bytes> = mls.KeyPackages;
        public struct KeyPackages {
            /// One package per device of the person asked about. A device with
            /// nothing left is missing rather than failing the request: one
            /// silent device must not stop a conversation with the rest.
            public let packages: [Buffer]

            public static func parse(_ reader: BufferReader) -> KeyPackages? {
                guard let signature = reader.readInt32(), signature == -548140819 else {
                    return nil
                }
                guard let vector = reader.readInt32(), vector == 481674261 else {
                    return nil
                }
                guard let count = reader.readInt32() else {
                    return nil
                }
                var packages: [Buffer] = []
                for _ in 0 ..< count {
                    guard let item = parseBytes(reader) else {
                        return nil
                    }
                    packages.append(item)
                }
                return KeyPackages(packages: packages)
            }
        }

        /// mls.content text:string entities:Vector<MessageEntity> = mls.Content;
        ///
        /// What actually gets encrypted. Not the text on its own, because an
        /// entity - bold, a link, a mention - is a pair of offsets into the
        /// text, and beside a ciphertext those offsets point at nothing. Sent
        /// unchanged they arrive pointing past the end of what the other side
        /// reads back; dropped, an encrypted message silently loses its
        /// formatting. So they travel inside, where they mean something.
        ///
        /// This never reaches the server - it is the plaintext - but it is
        /// written in TL and its constructor is the CRC32 of the declaration
        /// like everything else, because the other client has to read it and
        /// already knows how to read this.
        public enum Content {
            public static let constructor: Int32 = 1833308697

            /// mls.forwarded text:string entities:Vector<MessageEntity> from_id:long from_name:string date:int = mls.Content;
            ///
            /// The same thing plus who wrote it first. A forward cannot be what
            /// it is on the wire - the server copies a message by its id, and
            /// the copy lands in a conversation whose members were never able
            /// to read it - so an encrypted forward is sent as a new message
            /// and says inside itself where it came from.
            public static let forwardedConstructor: Int32 = 1144791349

            /// Who wrote it first. The id when this device knows it, the name
            /// when the account is hidden and a name is all there is.
            public struct Forwarded {
                public let authorId: Int64
                public let authorName: String
                public let date: Int32

                public init(authorId: Int64, authorName: String, date: Int32) {
                    self.authorId = authorId
                    self.authorName = authorName
                    self.date = date
                }
            }

            /// mls.media kind:int mime:string name:string size:long width:int height:int duration:int key:bytes iv:bytes thumb:bytes = mls.Media;
            ///
            /// Everything needed to show a file that the server is holding as a
            /// blob of random bytes: what it is, how big it is on screen, and
            /// the key that turns it back into a picture. The server generates
            /// no preview for it and knows no filename, because both would
            /// describe what it is not allowed to see.
            public static let mediaConstructor: Int32 = 859009216
            /// mls.message flags:# text:string entities:Vector<MessageEntity> forward:flags.0?mls.Forward media:flags.1?mls.Media = mls.Content;
            public static let messageConstructor: Int32 = 995434673
            /// mls.forward from_id:long from_name:string date:int = mls.Forward;
            public static let forwardConstructor: Int32 = 940936156

            public struct Media {
                /// 0 a file, 1 a picture, 2 a video, 3 a voice message,
                /// 4 a round video message, 5 an animation.
                public let kind: Int32
                public let mime: String
                public let name: String
                public let size: Int64
                public let width: Int32
                public let height: Int32
                public let duration: Int32
                public let key: Data
                public let iv: Data
                /// The blurred placeholder shown until the file has come down,
                /// a couple of hundred bytes of it. It travels here rather than
                /// beside the message because a thumbnail is the picture.
                public let thumb: Data

                public init(kind: Int32, mime: String, name: String, size: Int64, width: Int32, height: Int32, duration: Int32, key: Data, iv: Data, thumb: Data) {
                    self.kind = kind
                    self.mime = mime
                    self.name = name
                    self.size = size
                    self.width = width
                    self.height = height
                    self.duration = duration
                    self.key = key
                    self.iv = iv
                    self.thumb = thumb
                }
            }

            public static func encode(text: String, entities: [Api.MessageEntity], forwarded: Forwarded? = nil, media: Media? = nil) -> Data {
                let buffer = Buffer()
                buffer.appendInt32(messageConstructor)
                var flags: Int32 = 0
                if forwarded != nil { flags |= 1 << 0 }
                if media != nil { flags |= 1 << 1 }
                serializeInt32(flags, buffer: buffer, boxed: false)
                serializeString(text, buffer: buffer, boxed: false)
                buffer.appendInt32(481674261)
                buffer.appendInt32(Int32(entities.count))
                for entity in entities {
                    entity.serialize(buffer, true)
                }
                if let forwarded = forwarded {
                    buffer.appendInt32(forwardConstructor)
                    serializeInt64(forwarded.authorId, buffer: buffer, boxed: false)
                    serializeString(forwarded.authorName, buffer: buffer, boxed: false)
                    serializeInt32(forwarded.date, buffer: buffer, boxed: false)
                }
                if let media = media {
                    buffer.appendInt32(mediaConstructor)
                    serializeInt32(media.kind, buffer: buffer, boxed: false)
                    serializeString(media.mime, buffer: buffer, boxed: false)
                    serializeString(media.name, buffer: buffer, boxed: false)
                    serializeInt64(media.size, buffer: buffer, boxed: false)
                    serializeInt32(media.width, buffer: buffer, boxed: false)
                    serializeInt32(media.height, buffer: buffer, boxed: false)
                    serializeInt32(media.duration, buffer: buffer, boxed: false)
                    serializeBytes(Buffer(data: media.key), buffer: buffer, boxed: false)
                    serializeBytes(Buffer(data: media.iv), buffer: buffer, boxed: false)
                    serializeBytes(Buffer(data: media.thumb), buffer: buffer, boxed: false)
                }
                return buffer.makeData()
            }

            /// Nothing if this is not one of ours. A message from a version that
            /// encrypted the bare text is exactly that, so the caller falls back
            /// to reading the bytes as text rather than showing nothing.
            ///
            /// The two older shapes are still read. They are in people's chats.
            public static func decode(_ data: Data) -> (text: String, entities: [Api.MessageEntity], forwarded: Forwarded?, media: Media?)? {
                let reader = BufferReader(Buffer(data: data))
                guard let signature = reader.readInt32() else {
                    return nil
                }
                guard signature == constructor || signature == forwardedConstructor || signature == messageConstructor else {
                    return nil
                }

                var flags: Int32 = 0
                if signature == messageConstructor {
                    guard let value = reader.readInt32() else {
                        return nil
                    }
                    flags = value
                } else if signature == forwardedConstructor {
                    flags = 1 << 0
                }

                guard let text = parseString(reader) else {
                    return nil
                }
                guard let vector = reader.readInt32(), vector == 481674261 else {
                    return nil
                }
                guard let entities = Api.parseVector(reader, elementSignature: 0, elementType: Api.MessageEntity.self) else {
                    return nil
                }

                var forwarded: Forwarded?
                if (flags & (1 << 0)) != 0 {
                    if signature == messageConstructor {
                        guard let inner = reader.readInt32(), inner == forwardConstructor else {
                            return nil
                        }
                    }
                    guard let authorId = reader.readInt64(),
                          let authorName = parseString(reader),
                          let date = reader.readInt32() else {
                        return nil
                    }
                    forwarded = Forwarded(authorId: authorId, authorName: authorName, date: date)
                }

                var media: Media?
                if (flags & (1 << 1)) != 0 {
                    guard let inner = reader.readInt32(), inner == mediaConstructor,
                          let kind = reader.readInt32(),
                          let mime = parseString(reader),
                          let name = parseString(reader),
                          let size = reader.readInt64(),
                          let width = reader.readInt32(),
                          let height = reader.readInt32(),
                          let duration = reader.readInt32(),
                          let key = parseBytes(reader),
                          let iv = parseBytes(reader),
                          let thumb = parseBytes(reader) else {
                        return nil
                    }
                    media = Media(kind: kind, mime: mime, name: name, size: size, width: width, height: height, duration: duration, key: key.makeData(), iv: iv.makeData(), thumb: thumb.makeData())
                }

                return (text, entities, forwarded, media)
            }
        }
    }
}
