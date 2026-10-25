import Foundation
import Postbox

/// Links in a message to a chat that encrypts are marked by the sender (#292).
///
/// A link is a `.Url` entity over the text. In the clear the server found links
/// itself; in an encrypted chat the entities travel inside the ciphertext, so a
/// link the sending device does not mark is plain text on both phones. The
/// composer marks them, but the share extension, Siri and QuickShare enqueue
/// bare text - a link shared from Safari arrived as words.
///
/// Called where every route ends, as the message is enqueued: whatever put the
/// text there, the links in it are marked before it is encrypted, and the
/// sender's own bubble shows the same.
enum MlsLinks {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func mark(text: String, attributes: inout [MessageAttribute], peer: Peer?, peerId: PeerId, accountPeerId: PeerId) {
        guard !text.isEmpty, MlsRuntime.encrypts(peer: peer, peerId: peerId, accountPeerId: accountPeerId) else {
            return
        }
        let existingIndex = attributes.firstIndex(where: { $0 is TextEntitiesMessageAttribute })
        let existing = existingIndex.flatMap { attributes[$0] as? TextEntitiesMessageAttribute }?.entities ?? []
        let marked = links(in: text, besides: existing)
        guard !marked.isEmpty else {
            return
        }
        let entities = (existing + marked).sorted { $0.range.lowerBound < $1.range.lowerBound }
        if let existingIndex = existingIndex {
            attributes[existingIndex] = TextEntitiesMessageAttribute(entities: entities)
        } else {
            attributes.append(TextEntitiesMessageAttribute(entities: entities))
        }
    }

    /// The links in this text that no entity covers yet, as UTF-16 ranges -
    /// the unit entities are counted in.
    static func links(in text: String, besides existing: [MessageTextEntity]) -> [MessageTextEntity] {
        guard let detector = detector else {
            return []
        }
        let length = (text as NSString).length
        var found: [MessageTextEntity] = []
        detector.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: length)) { result, _, _ in
            guard let result = result, result.resultType == .link, result.range.length > 0 else {
                return
            }
            let range = result.range.location ..< (result.range.location + result.range.length)
            // A mail address is a link to NSDataDetector and not one here.
            if let scheme = result.url?.scheme?.lowercased(), scheme == "mailto" {
                return
            }
            if existing.contains(where: { $0.range.overlaps(range) }) {
                return
            }
            found.append(MessageTextEntity(range: range, type: .Url))
        }
        return found
    }
}
