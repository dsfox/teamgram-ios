import Foundation
import MtProtoKit
import TelegramCore

/// ice9's MTProtoRustEngine: no Rust engine here (#278). Telegram 13.0 links
/// its Rust MTProto engine into every build, chosen only from Debug Settings;
/// MtProtoKit stays the default. The engine carries Telegram's own hosts in
/// its strings (`.web.telegram.org`), which tools/ipa_gate.py refuses as the
/// infrastructure Apple read in 12.9.2 (#181), so the module compiles this
/// file instead and the factory declines: the network runs MtProtoKit, as it
/// does without a factory.
public struct RustNetworkEngineFactory: NetworkEngineFactory {
    public init() {
    }

    public func makeEngine(context: MTContext, isAppExtension: Bool) -> NetworkEngine? {
        return nil
    }
}
