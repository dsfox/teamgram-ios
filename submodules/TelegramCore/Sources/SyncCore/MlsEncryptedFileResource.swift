import Foundation
import Postbox

/// A file the server is holding as a blob of random bytes.
///
/// It is an ordinary document as far as the server is concerned - uploaded,
/// stored and served the way any document is - and the bytes inside it are
/// nothing it can open. The key that turns them back into a picture travelled
/// inside the message, encrypted to the two people in the conversation.
///
/// Everything below the surface is already in place: `multipartUpload` encrypts
/// while it uploads and `multipartFetch` decrypts while it downloads, both
/// because secret chats needed them. What this adds is the one thing a secret
/// chat does differently - where the file lives. A secret chat's file is fetched
/// through `inputEncryptedFileLocation`, which only exists inside a secret chat;
/// this one is a document like any other.
///
/// A file that has not finished downloading cannot be opened at all - no half a
/// picture, no video that plays while it arrives. That is the price of
/// encrypting the whole thing as one piece, and it was accepted knowingly.
public final class MlsEncryptedFileResource: TelegramMediaResource {
    public let datacenterId: Int
    public let fileId: Int64
    public let accessHash: Int64
    public let fileReference: Data?
    /// What the server holds: the plaintext rounded up to the cipher's block
    /// size. Needed because the download is that long, not this long.
    public let containerSize: Int64
    public let decryptedSize: Int64
    public let key: SecretFileEncryptionKey

    public var size: Int64? {
        return self.decryptedSize
    }

    public init(datacenterId: Int, fileId: Int64, accessHash: Int64, fileReference: Data?, containerSize: Int64, decryptedSize: Int64, key: SecretFileEncryptionKey) {
        self.datacenterId = datacenterId
        self.fileId = fileId
        self.accessHash = accessHash
        self.fileReference = fileReference
        self.containerSize = containerSize
        self.decryptedSize = decryptedSize
        self.key = key
    }

    public required init(decoder: PostboxDecoder) {
        self.datacenterId = Int(decoder.decodeInt32ForKey("d", orElse: 0))
        self.fileId = decoder.decodeInt64ForKey("f", orElse: 0)
        self.accessHash = decoder.decodeInt64ForKey("a", orElse: 0)
        self.fileReference = decoder.decodeBytesForKey("r")?.makeData()
        self.containerSize = decoder.decodeInt64ForKey("cs", orElse: 0)
        self.decryptedSize = decoder.decodeInt64ForKey("ds", orElse: 0)
        self.key = decoder.decodeObjectForKey("k", decoder: { SecretFileEncryptionKey(decoder: $0) }) as! SecretFileEncryptionKey
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(Int32(self.datacenterId), forKey: "d")
        encoder.encodeInt64(self.fileId, forKey: "f")
        encoder.encodeInt64(self.accessHash, forKey: "a")
        if let fileReference = self.fileReference {
            encoder.encodeBytes(MemoryBuffer(data: fileReference), forKey: "r")
        } else {
            encoder.encodeNil(forKey: "r")
        }
        encoder.encodeInt64(self.containerSize, forKey: "cs")
        encoder.encodeInt64(self.decryptedSize, forKey: "ds")
        encoder.encodeObject(self.key, forKey: "k")
    }

    /// Named by the document it is, not by the key it carries: the same file
    /// downloaded twice is the same file, and the key is not what identifies it.
    public var id: MediaResourceId {
        return MediaResourceId("mls-file-\(self.datacenterId)-\(self.fileId)")
    }

    public func isEqual(to: MediaResource) -> Bool {
        guard let to = to as? MlsEncryptedFileResource else {
            return false
        }
        return self.datacenterId == to.datacenterId
            && self.fileId == to.fileId
            && self.accessHash == to.accessHash
            && self.containerSize == to.containerSize
            && self.decryptedSize == to.decryptedSize
            && self.key == to.key
    }
}
