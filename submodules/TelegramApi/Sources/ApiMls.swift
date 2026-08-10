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
        static func publishKeyPackages(keyPackages: [Buffer], lastResort: Buffer) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.mls.PublishResult>) {
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

        /// mls.claimKeyPackages user_id:long = mls.KeyPackages;
        static func claimKeyPackages(userId: Int64) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.mls.KeyPackages>) {
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

            static func parse(_ reader: BufferReader) -> PublishResult? {
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

        /// mls.keyPackages packages:Vector<bytes> = mls.KeyPackages;
        public struct KeyPackages {
            /// One package per device of the person asked about. A device with
            /// nothing left is missing rather than failing the request: one
            /// silent device must not stop a conversation with the rest.
            public let packages: [Buffer]

            static func parse(_ reader: BufferReader) -> KeyPackages? {
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
    }
}
