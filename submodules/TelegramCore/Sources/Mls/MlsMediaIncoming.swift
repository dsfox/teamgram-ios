import Foundation
import Postbox
import TelegramApi

/// Turning what arrived back into a picture, a video or a file.
///
/// What the server sent is a document with no mime type, no name and no
/// dimensions, holding bytes it cannot read. What the message said - inside the
/// ciphertext - is what those bytes are. This puts the two together: the
/// document's location, so it can be downloaded, and the description, so it can
/// be shown and decrypted.

/// The media to store in place of the blob the server described.
///
/// Nothing if the arriving message has no document to attach the key to - which
/// would mean the two halves disagree, and showing the blob is better than
/// showing a picture that cannot exist.
func mlsIncomingMedia(from medias: [Media], descriptor: Api.mls.Content.Media) -> [Media]? {
    guard let file = medias.first(where: { $0 is TelegramMediaFile }) as? TelegramMediaFile,
          let cloud = file.resource as? CloudDocumentMediaResource else {
        return nil
    }

    let resource = MlsEncryptedFileResource(
        datacenterId: cloud.datacenterId,
        fileId: cloud.fileId,
        accessHash: cloud.accessHash,
        fileReference: cloud.fileReference,
        // What the server holds is the plaintext padded up to the cipher's
        // block size; what comes out of the decryption is the original.
        containerSize: file.size ?? cloud.size ?? descriptor.size,
        decryptedSize: descriptor.size,
        key: SecretFileEncryptionKey(aesKey: descriptor.key, aesIv: descriptor.iv))

    let thumbnail: Data? = descriptor.thumb.isEmpty ? nil : descriptor.thumb
    let kind = MlsMediaKind(rawValue: descriptor.kind) ?? .file

    if kind == .image {
        return [TelegramMediaImage(
            imageId: MediaId(namespace: Namespaces.Media.CloudImage, id: cloud.fileId),
            representations: [TelegramMediaImageRepresentation(
                dimensions: PixelDimensions(width: descriptor.width, height: descriptor.height),
                resource: resource,
                progressiveSizes: [],
                immediateThumbnailData: thumbnail,
                hasVideo: false,
                isPersonal: false)],
            immediateThumbnailData: thumbnail,
            reference: nil,
            partialReference: nil,
            flags: [])]
    }

    var attributes: [TelegramMediaFileAttribute] = [.FileName(fileName: descriptor.name)]
    switch kind {
    case .video, .roundVideo:
        var flags: TelegramMediaVideoFlags = [.supportsStreaming]
        // Streaming is exactly what this cannot do: the file is one piece of
        // ciphertext and there is nothing to play until all of it is here.
        flags = []
        if kind == .roundVideo {
            flags.insert(.instantRoundVideo)
        }
        attributes.append(.Video(
            duration: Double(descriptor.duration),
            size: PixelDimensions(width: descriptor.width, height: descriptor.height),
            flags: flags, preloadSize: nil, coverTime: nil, videoCodec: nil))
    case .voice:
        attributes.append(.Audio(isVoice: true, duration: Int(descriptor.duration), title: nil, performer: nil, waveform: nil))
    case .animation:
        attributes.append(.Animated)
        if descriptor.width > 0 {
            attributes.append(.ImageSize(size: PixelDimensions(width: descriptor.width, height: descriptor.height)))
        }
    default:
        if descriptor.width > 0 {
            attributes.append(.ImageSize(size: PixelDimensions(width: descriptor.width, height: descriptor.height)))
        }
    }

    return [TelegramMediaFile(
        fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: cloud.fileId),
        partialReference: nil,
        resource: resource,
        previewRepresentations: [],
        videoThumbnails: [],
        immediateThumbnailData: thumbnail,
        mimeType: descriptor.mime,
        size: descriptor.size,
        attributes: attributes,
        alternativeRepresentations: [])]
}
