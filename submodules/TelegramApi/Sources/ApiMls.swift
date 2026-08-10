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
            return (FunctionDescription(name: "mls.publishKeyPackages", parameters: [("keyPackages", String(describing: keyPackages)), ("lastResort", String(describing: lastResort))]), buffer, DeserializeFunctionResponse { (buffer: Buffer) -> Api.mls.PublishResult? in
                let reader = BufferReader(buffer)
                return Api.mls.PublishResult.parse(reader)
            })
        }

        /// mls.sendWelcome user_id:long welcome:bytes = mls.Ok;
        public static func sendWelcome(userId: Int64, welcome: Buffer) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.mls.Ok>) {
            let buffer = Buffer()
            buffer.appendInt32(-773834602)
            serializeInt64(userId, buffer: buffer, boxed: false)
            serializeBytes(welcome, buffer: buffer, boxed: false)
            return (FunctionDescription(name: "mls.sendWelcome", parameters: [("userId", String(describing: userId))]), buffer, DeserializeFunctionResponse { (buffer: Buffer) -> Api.mls.Ok? in
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
            return (FunctionDescription(name: "mls.confirmWelcomes", parameters: [("ids", String(describing: ids))]), buffer, DeserializeFunctionResponse { (buffer: Buffer) -> Api.mls.Ok? in
                let reader = BufferReader(buffer)
                return Api.mls.Ok.parse(reader)
            })
        }

        /// mls.claimKeyPackages user_id:long = mls.KeyPackages;
        public static func claimKeyPackages(userId: Int64) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.mls.KeyPackages>) {
            let buffer = Buffer()
            buffer.appendInt32(88879177)
            serializeInt64(userId, buffer: buffer, boxed: false)
            return (FunctionDescription(name: "mls.claimKeyPackages", parameters: [("userId", String(describing: userId))]), buffer, DeserializeFunctionResponse { (buffer: Buffer) -> Api.mls.KeyPackages? in
                let reader = BufferReader(buffer)
                return Api.mls.KeyPackages.parse(reader)
            })
        }
    }
}

public extension Api {
    enum mls {
        /// mls.publishResult added:int available:int should_refill:Bool = mls.PublishResult;
        public struct PublishResult {
            public let added: Int32
            public let available: Int32
            /// Whether this device should make more. The server counts; the
            /// device is the only one that can make them.
            public let shouldRefill: Swift.Bool

            public static func parse(_ reader: BufferReader) -> PublishResult? {
                guard let signature = reader.readInt32(), signature == -1429473241 else {
                    return nil
                }
                guard let added = reader.readInt32(),
                      let available = reader.readInt32(),
                      let refill = reader.readInt32() else {
                    return nil
                }
                return PublishResult(added: added, available: available, shouldRefill: refill == -1720552011)
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

        /// mls.welcome id:long from_id:long welcome:bytes = mls.Welcome;
        public struct Welcome {
            public let id: Int64
            public let fromId: Int64
            public let welcome: Buffer

            static func parse(_ reader: BufferReader) -> Welcome? {
                guard let signature = reader.readInt32(), signature == -180214709 else {
                    return nil
                }
                guard let id = reader.readInt64(),
                      let fromId = reader.readInt64(),
                      let welcome = parseBytes(reader) else {
                    return nil
                }
                return Welcome(id: id, fromId: fromId, welcome: welcome)
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
