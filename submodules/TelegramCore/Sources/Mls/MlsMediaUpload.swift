import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi
import ImageCompression
import UIKit

/// Sending a file into an encrypted conversation.
///
/// The file is encrypted on the way up and stored by the server as a document
/// full of random bytes - no mime type it recognises, no name, no dimensions,
/// no preview it could generate. Everything needed to make sense of it again
/// travels inside the message, in `mls.media`, encrypted to the two people in
/// the conversation.
///
/// The encryption itself is not new: `multipartUpload(encrypt:)` has been doing
/// this for secret chats for years. What is new is that the result is sent as
/// an ordinary document rather than through the secret-chat methods, so nothing
/// on the server has to change.

/// What kind of thing this is, since the mime type is not going with it.
enum MlsMediaKind: Int32 {
    case file = 0
    case image = 1
    case video = 2
    case voice = 3
    case roundVideo = 4
    case animation = 5
}

/// What has to be uploaded, read off the media that is being sent.
private struct MlsUploadable {
    let resource: MediaResource
    let kind: MlsMediaKind
    let mime: String
    let name: String
    let size: Int64
    let width: Int32
    let height: Int32
    let duration: Int32
}

private func uploadable(from media: Media) -> MlsUploadable? {
    if let image = media as? TelegramMediaImage {
        guard let largest = largestImageRepresentation(image.representations) else {
            return nil
        }
        return MlsUploadable(
            resource: largest.resource, kind: .image, mime: "image/jpeg", name: "photo.jpg",
            size: largest.resource.size ?? 0,
            width: largest.dimensions.width, height: largest.dimensions.height, duration: 0)
    }

    guard let file = media as? TelegramMediaFile else {
        return nil
    }

    var kind: MlsMediaKind = .file
    var width: Int32 = 0
    var height: Int32 = 0
    var duration: Int32 = 0
    var name = "file"
    for attribute in file.attributes {
        switch attribute {
        case let .FileName(fileName):
            name = fileName
        case let .ImageSize(size):
            width = size.width
            height = size.height
            if kind == .file {
                kind = .image
            }
        case .Animated:
            kind = .animation
        case let .Video(videoDuration, size, flags, _, _, _):
            kind = flags.contains(.instantRoundVideo) ? .roundVideo : .video
            width = size.width
            height = size.height
            duration = Int32(videoDuration)
        case let .Audio(isVoice, audioDuration, _, _, _):
            if isVoice {
                kind = .voice
            }
            duration = Int32(audioDuration)
        default:
            break
        }
    }

    return MlsUploadable(
        resource: file.resource, kind: kind, mime: file.mimeType, name: name,
        size: file.size ?? file.resource.size ?? 0,
        width: width, height: height, duration: duration)
}

/// Uploads the file encrypted and hands back a request that sends it as an
/// ordinary document, plus what the other side will need to open it.
///
/// Nothing if this media is not a file at all - a contact, a location, a poll -
/// and then the caller sends it as it always did. Those carry no bytes of their
/// own; what they do leak is a separate question and a separate issue.
func mlsUploadedMediaContent(network: Network, postbox: Postbox, peerId: PeerId, media: Media, text: String) -> Signal<PendingMessageUploadedContentResult, PendingMessageUploadError>? {
    guard let uploadable = uploadable(from: media) else {
        return nil
    }

    // The size of the file as it is on disk, read before anything is sent.
    //
    // It is not the size on the media: an image's representation often does not
    // know it, and what the other side needs is exactly how many bytes come out
    // of the decryption. Get it wrong and the download never finishes - the
    // client waits for bytes that are not coming, which is what happened the
    // first time this was tried.
    // Waited for rather than sampled. A picture just chosen from the library is
    // still being written when the send begins, so the first answer is "not
    // here yet" - and reading a size from that failed the message outright.
    //
    // And the wait alone starts nothing: a video from the library, or a round
    // video just recorded, is not on disk until its converter has run, and
    // nothing else here would run it - the send sat at this line for ever,
    // waiting for a file nobody was writing. So the fetch is started beside
    // the wait, the way the ordinary outgoing-media path starts it, and both
    // are stopped together.
    let whole = Signal<MediaResourceData, NoError> { subscriber in
        let fetch = fetchedMediaResource(mediaBox: postbox.mediaBox, userLocation: .other, userContentType: .video, reference: .standalone(resource: uploadable.resource)).start()
        let data = postbox.mediaBox.resourceData(uploadable.resource, option: .complete(waitUntilFetchStatus: false)).start(next: { next in
            subscriber.putNext(next)
            if next.complete {
                subscriber.putCompletion()
            }
        })
        return ActionDisposable {
            fetch.dispose()
            data.dispose()
        }
    }
    return whole
    |> filter { $0.complete }
    |> take(1)
    |> castError(PendingMessageUploadError.self)
    |> mapToSignal { data -> Signal<PendingMessageUploadedContentResult, PendingMessageUploadError> in
        var decryptedSize = uploadable.size
        if let attributes = try? FileManager.default.attributesOfItem(atPath: data.path), let size = attributes[.size] as? NSNumber {
            decryptedSize = size.int64Value
        }
        guard decryptedSize > 0 else {
            return .fail(.generic)
        }

        // The blurred placeholder, made here because the server cannot make one
        // - it is holding noise. A couple of hundred bytes, which is why it fits
        // inside the message rather than travelling as a file of its own.
        //
        // Only for a picture: pulling a frame out of a video needs the media
        // pipeline and belongs with the rest of the video work.
        var thumbnail = Data()
        if uploadable.kind == .image, let image = UIImage(contentsOfFile: data.path),
           let mini = compressImageMiniThumbnail(image) {
            thumbnail = mini
        }

    return multipartUpload(
        network: network,
        postbox: postbox,
        source: .resource(.standalone(resource: uploadable.resource)),
        encrypt: true,
        tag: TelegramMediaResourceFetchTag(statsCategory: .file, userContentType: nil),
        hintFileSize: uploadable.size == 0 ? nil : uploadable.size,
        hintFileIsLarge: false,
        forceNoBigParts: false
    )
    |> mapError { _ -> PendingMessageUploadError in
        return .generic
    }
    |> mapToSignal { result -> Signal<PendingMessageUploadedContentResult, PendingMessageUploadError> in
        switch result {
        case let .progress(progress):
            return .single(.progress(PendingMessageUploadedContentProgress(progress: progress)))
        case .inputFile:
            // Asked for an encrypted upload and got a plain one. Nothing sane
            // to do with it: sending it would put the file up in the clear.
            return .fail(.generic)
        case let .inputSecretFile(file, containerSize, key):
            guard case let .inputEncryptedFileUploaded(uploaded) = file else {
                return .fail(.generic)
            }

            // The same parts that were just uploaded, named as an ordinary
            // file. `inputEncryptedFileUploaded` differs only in what it is
            // handed to, and what it is handed to lives in secret chats.
            let inputFile = Api.InputFile.inputFile(.init(
                id: uploaded.id, parts: uploaded.parts, name: "file", md5Checksum: ""))

            // No mime type, no name, no dimensions, no thumbnail: every one of
            // those describes what the server is not allowed to see.
            let inputMedia = Api.InputMedia.inputMediaUploadedDocument(.init(
                flags: 0, file: inputFile, thumb: nil,
                mimeType: "application/octet-stream",
                attributes: [.documentAttributeFilename(.init(fileName: "file"))],
                stickers: nil, videoCover: nil, videoTimestamp: nil, ttlSeconds: nil))

            let descriptor = Api.mls.Content.Media(
                kind: uploadable.kind.rawValue,
                mime: uploadable.mime,
                name: uploadable.name,
                size: decryptedSize,
                width: uploadable.width,
                height: uploadable.height,
                duration: uploadable.duration,
                key: key.aesKey,
                iv: key.aesIv,
                thumb: thumbnail)

            Logger.shared.log("Mls", "uploaded \(containerSize) encrypted bytes for \(peerId)")

            return .single(.content(PendingMessageUploadedContentAndReuploadInfo(
                content: .media(inputMedia, text),
                reuploadInfo: nil,
                cacheReferenceKey: nil,
                mlsMedia: descriptor)))
        }
    }
    }
}
