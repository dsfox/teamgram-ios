import Foundation

/// Our own method for invitations people send themselves (#47), in a file of
/// its own for the same reason as ApiMls.swift: nothing of ours among the
/// generated files. The ids are the CRC32 of the declarations written above
/// each function; the gate in tests/test_mls_constructors.py recomputes them.
public extension Api.functions {
    enum invite {
        /// invite.mint phone:string = invite.Minted;
        ///
        /// A code bound to this number: only the phone the carrier delivers
        /// the SMS to can sign in with it.
        public static func mint(phone: String) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.invite.Minted>) {
            let buffer = Buffer()
            buffer.appendInt32(-734254852)
            serializeString(phone, buffer: buffer, boxed: false)
            return (FunctionDescription(name: "invite.mint", parameters: [("phone", ConstructorParameterDescription(phone))]), buffer, DeserializeFunctionResponse { (buffer: Buffer) -> Api.invite.Minted? in
                let reader = BufferReader(buffer)
                return Api.invite.Minted.parse(reader)
            })
        }

        /// invite.mintForChat chat_id:long phone:string = invite.Minted;
        ///
        /// The same code, minted from a group: the server puts whoever signs
        /// up with it into the group (#164).
        public static func mintForChat(chatId: Int64, phone: String) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.invite.Minted>) {
            let buffer = Buffer()
            buffer.appendInt32(-1620708375)
            buffer.appendInt64(chatId)
            serializeString(phone, buffer: buffer, boxed: false)
            return (FunctionDescription(name: "invite.mintForChat", parameters: [("chatId", ConstructorParameterDescription(chatId)), ("phone", ConstructorParameterDescription(phone))]), buffer, DeserializeFunctionResponse { (buffer: Buffer) -> Api.invite.Minted? in
                let reader = BufferReader(buffer)
                return Api.invite.Minted.parse(reader)
            })
        }
    }
}

public extension Api {
    enum invite {
        /// invite.minted code:string expires:int = invite.Minted;
        public struct Minted {
            public let code: String
            /// Unix seconds: the moment the code stops working.
            public let expires: Int32

            public static func parse(_ reader: BufferReader) -> Minted? {
                guard let signature = reader.readInt32(), signature == 730805919 else {
                    return nil
                }
                guard let code = parseString(reader), let expires = reader.readInt32() else {
                    return nil
                }
                return Minted(code: code, expires: expires)
            }
        }
    }
}
