import Foundation
import Postbox

/// A message that arrived encrypted and could not be read here, keeping the
/// ciphertext so it can be read later.
///
/// Without this the ciphertext had to be the message's text, and every part of
/// the app that shows a message showed `mls1:AAEAAh...` - the chat, the chat
/// list, search, a reply quote. A person saw that in their own conversation,
/// which is how this was found.
///
/// So the text becomes something a person can understand and the ciphertext
/// moves here, where only the code that can do something with it will look. It
/// is dropped the moment the message is read back, which usually happens within
/// seconds: a message regularly arrives before the welcome that lets this device
/// into the conversation.
public class MlsCiphertextMessageAttribute: MessageAttribute {
    public let ciphertext: String

    public var associatedMessageIds: [MessageId] = []

    public init(ciphertext: String) {
        self.ciphertext = ciphertext
    }

    required public init(decoder: PostboxDecoder) {
        self.ciphertext = decoder.decodeStringForKey("c", orElse: "")
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeString(self.ciphertext, forKey: "c")
    }
}

public extension MlsCiphertextMessageAttribute {
    /// What stands in for a message this device cannot read yet.
    ///
    /// A lock and nothing else, in every language. The text of a message is
    /// stored, not rendered, and this layer has no access to the app's strings -
    /// so a sentence here would have been English in a Russian app. A phrase
    /// belongs in the render layer if one is ever wanted; meanwhile this is
    /// usually on screen for under a second, until the conversation opens and
    /// the message is read back.
    static let placeholder = "🔒"
}
