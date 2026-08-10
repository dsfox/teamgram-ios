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

            public static func encode(text: String, entities: [Api.MessageEntity], forwarded: Forwarded? = nil) -> Data {
                let buffer = Buffer()
                buffer.appendInt32(forwarded == nil ? constructor : forwardedConstructor)
                serializeString(text, buffer: buffer, boxed: false)
                buffer.appendInt32(481674261)
                buffer.appendInt32(Int32(entities.count))
                for entity in entities {
                    entity.serialize(buffer, true)
                }
                if let forwarded = forwarded {
                    serializeInt64(forwarded.authorId, buffer: buffer, boxed: false)
                    serializeString(forwarded.authorName, buffer: buffer, boxed: false)
                    serializeInt32(forwarded.date, buffer: buffer, boxed: false)
                }
                return buffer.makeData()
            }

            /// Nothing if this is not one of ours. A message from a version that
            /// encrypted the bare text is exactly that, so the caller falls back
            /// to reading the bytes as text rather than showing nothing.
            public static func decode(_ data: Data) -> (text: String, entities: [Api.MessageEntity], forwarded: Forwarded?)? {
                let reader = BufferReader(Buffer(data: data))
                guard let signature = reader.readInt32(),
                      signature == constructor || signature == forwardedConstructor else {
                    return nil
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
                if signature == constructor {
                    return (text, entities, nil)
                }
                guard let authorId = reader.readInt64(),
                      let authorName = parseString(reader),
                      let date = reader.readInt32() else {
                    return nil
                }
                return (text, entities, Forwarded(authorId: authorId, authorName: authorName, date: date))
            }
        }
    }
}
