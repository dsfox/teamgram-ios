import Foundation
import MtProtoKit
import SwiftSignalKit
import TelegramApi

/// Which server this phone talks to (ice9 #65).
///
/// A messenger that promises "your server" and compiles ours into the app is
/// promising nothing, and it makes us the one point everybody has to trust. So
/// the address is a thing a person types, ours is only what the field is filled
/// in with, and this is where the answer is kept.
///
/// The twin of `ServerAddress.java` on the other client, with the same defaults
/// and the same parsing rules: somebody moving between their own phones has to
/// be able to type the same line into both.
public struct ServerAddress: Equatable {
    /// Ours, offered as the default. A name rather than an address: an address
    /// baked into a released build and later given up left phones rotating onto
    /// a dead endpoint, showing "Connecting" every other minute, with no way to
    /// reach the ones already installed. A name can be pointed elsewhere.
    public static let defaultHost = "common.ice9.app"
    public static let defaultPort: Int32 = 10443

    public static let `default` = ServerAddress(host: defaultHost, port: defaultPort)

    public let host: String
    public let port: Int32
    /// A server of one's own: the DER of the key fetched from it and checked
    /// against the code the person typed (#244). Nil means the key built into
    /// the app - ours, and the stand's.
    public let key: Data?

    public init(host: String, port: Int32, key: Data? = nil) {
        self.host = host.isEmpty ? ServerAddress.defaultHost : host
        self.port = (port > 0 && port <= 65535) ? port : ServerAddress.defaultPort
        self.key = key
    }

    public func withKey(_ key: Data?) -> ServerAddress {
        return ServerAddress(host: self.host, port: self.port, key: key)
    }

    /// The key a handshake with this server may use, as MtProtoKit takes it.
    public var publicKeyPem: String? {
        return self.key.map(ServerCode.pem)
    }

    /// The code of the key this phone holds for the server, when it holds one.
    public var code: String? {
        return self.key.map(ServerCode.code)
    }

    /// True when this phone is talking to ours.
    public var isOurs: Bool {
        return self == ServerAddress.default
    }

    /// "name" when the port is the usual one, "name:port" when it is not.
    public var described: String {
        return self.port == ServerAddress.defaultPort ? self.host : "\(self.host):\(self.port)"
    }

    /// Splits what a person typed. Accepts "name", "name:port" and a bare
    /// address; returns nil when there is nothing usable in it, so the caller
    /// can say so rather than keep a value that cannot be dialled.
    public static func parse(_ typed: String) -> ServerAddress? {
        // People paste what they were sent, and what they were sent often has
        // a scheme and a trailing slash on it.
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if let schemeEnd = text.range(of: "://"), text[text.startIndex ..< schemeEnd.lowerBound].allSatisfy({ $0.isLetter }), schemeEnd.lowerBound != text.startIndex {
            text = String(text[schemeEnd.upperBound...])
        }
        while text.hasSuffix("/") {
            text.removeLast()
        }
        if text.isEmpty {
            return nil
        }

        var host = text
        var port = ServerAddress.defaultPort
        if let colon = text.lastIndex(of: ":"), colon != text.startIndex, text.index(after: colon) != text.endIndex {
            host = String(text[text.startIndex ..< colon])
            guard let number = Int32(text[text.index(after: colon)...]), number > 0, number <= 65535 else {
                return nil
            }
            port = number
        }
        if host.isEmpty || host.contains(" ") {
            return nil
        }
        return ServerAddress(host: host, port: port)
    }
}

/// Where the answer is kept.
///
/// One line in the container every process of this app opens, rather than the
/// account database: the question is asked before an account exists, and the
/// answer is the same for every account on the phone. A file rather than
/// `UserDefaults` because this module does not know the app group's name,
/// while the root path is handed to it already - it is that same container.
///
/// What it holds is only the *seed*. Once the client has connected it keeps its
/// own address list, refreshed by help.getConfig, and that list is what it dials
/// from then on. Writing here therefore does nothing on its own —
/// `reseedFromAddress` is what makes it take.
public final class ServerAddressStore {
    /// Two lines: the address, and the word below it when somebody has answered
    /// the question. Two states rather than one, because "which address to dial"
    /// and "has anybody been asked" are different questions and the difference
    /// is the whole of changing servers later: somebody who opens that screen
    /// and walks away has to keep dialling the server they were already on.
    private static let answered = "answered"

    private let path: String

    public init(rootPath: String) {
        self.path = rootPath + "/server-address"
    }

    private var lines: [String] {
        guard let text = try? String(contentsOfFile: self.path, encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n").map(String.init)
    }

    /// A server of one's own adds a line after these two: "key <base64 DER>"
    /// (#244). Older files have none, and read as before.
    private static let keyLine = "key "

    /// The address in hand, answered or not.
    public var stored: ServerAddress? {
        let lines = self.lines
        guard let first = lines.first, let address = ServerAddress.parse(first) else {
            return nil
        }
        guard let line = lines.dropFirst().first(where: { $0.hasPrefix(ServerAddressStore.keyLine) }) else {
            return address
        }
        guard let key = Data(base64Encoded: String(line.dropFirst(ServerAddressStore.keyLine.count))), ServerCode.isAcceptable(key) else {
            Logger.shared.log("ServerAddress", "the kept key for \(address.described) is not one the app takes; reaching it with the built-in key")
            return address
        }
        return address.withKey(key)
    }

    /// What somebody answered, or nil when the question is still to be asked.
    /// Note that this is not "is it ours": somebody who looked at the screen and
    /// kept the default has still answered, and is not asked again.
    public var chosen: ServerAddress? {
        guard self.lines.count > 1, self.lines[1] == ServerAddressStore.answered else {
            return nil
        }
        return self.stored
    }

    /// What to dial: what is in hand, or ours until somebody says otherwise.
    public var effective: ServerAddress {
        return self.stored ?? ServerAddress.default
    }

    /// Keeps an address as answered. Says nothing about whether it answers: that
    /// is checked before this is called, because an address that does not answer
    /// turns into a phone stuck on "Connecting" with no way back to it.
    public func store(_ address: ServerAddress) {
        self.write([address.described, ServerAddressStore.answered] + self.keyLines(address))
    }

    /// Puts the question back without changing what is dialled. This is what
    /// changing servers from Settings does before signing out: the screen comes
    /// up again with the current address in it, and until somebody types
    /// another one the client goes on reaching the same server it always did.
    public func askAgain() {
        let effective = self.effective
        self.write([effective.described] + self.keyLines(effective))
    }

    private func keyLines(_ address: ServerAddress) -> [String] {
        guard let key = address.key else {
            return []
        }
        return [ServerAddressStore.keyLine + key.base64EncodedString()]
    }

    private func write(_ lines: [String]) {
        do {
            try lines.joined(separator: "\n").write(toFile: self.path, atomically: true, encoding: .utf8)
        } catch let error {
            Logger.shared.log("ServerAddress", "could not keep \(lines.first ?? ""): \(error)")
        }
    }
}

/// A server link opened when the server screen is not up yet (#244): held in
/// memory for a few minutes and taken by the screen when it appears. Never
/// stored - a link only fills the fields, and nothing is kept until the check.
public final class ServerLinkInbox {
    public static let shared = ServerLinkInbox()

    private let lock = NSLock()
    private var link: (ServerLink, Date)?

    public func put(_ link: ServerLink) {
        self.lock.lock()
        self.link = (link, Date())
        self.lock.unlock()
    }

    public func take() -> ServerLink? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        guard let (link, when) = self.link else {
            return nil
        }
        self.link = nil
        return Date().timeIntervalSince(when) < 600 ? link : nil
    }
}

/// Points a running client at a different server.
///
/// The address list the client dials from is its own, kept between launches and
/// refreshed from the server it is talking to, so changing what is stored does
/// nothing until the list is thrown away and seeded again from the new address.
/// The keys go with it: they were agreed with a different server, which has
/// never heard of them.
///
/// This is the counterpart of `ConnectionsManager.reseedFromAddress` on the
/// other client, minus the restart - on this one the sequence that asks the
/// question owns the network it is asking about.
///
/// Taking a key away is only half of it. MTProto answers a key that has gone by
/// suspending itself and waiting to be handed a new one; nothing in it goes and
/// asks, because everywhere else in MTProto the two are done together. Left
/// undone, the client sits on a live connection to the right address with
/// nothing to send - which is what it did, and it looked exactly like a server
/// that never answered.
public func reseedFromAddress(network: Network, address: ServerAddress) {
    let datacenterId = network.mtProto.datacenterId
    let addressSet: MTDatacenterAddressSet = MTDatacenterAddressSet(addressList: [
        MTDatacenterAddress(ip: address.host, port: UInt16(address.port), preferForMedia: false, restrictToTcp: false, cdn: false, preferForProxy: false, secret: nil)
    ])

    Logger.shared.log("ServerAddress", "reseeding datacenter \(datacenterId) from \(address.described)\(address.key != nil ? " with the server's own key" : "")")

    network.context.performBatchUpdates {
        // Before the keys are thrown away and a new one asked for, so the
        // handshake that follows already uses the key this server's code was
        // checked against (#244) - and a put-back brings the old key back.
        network.context.serverPublicKey = address.publicKeyPem
        for selector in [MTDatacenterAuthInfoSelector.persistent, .ephemeralMain, .ephemeralMedia] {
            network.context.updateAuthInfoForDatacenter(withId: datacenterId, authInfo: nil, selector: selector)
        }
        network.context.setSeedAddressSetForDatacenterWithId(datacenterId, seedAddressSet: addressSet)
        network.context.updateAddressSetForDatacenter(withId: datacenterId, addressSet: addressSet, forceUpdateSchemes: true)
        // The address is in place before the asking, so the handshake goes to
        // the new server. Asking for the ephemeral key asks for the persistent
        // one underneath it when that is missing too, which after the loop above
        // it always is.
        network.context.authInfoForDatacenter(withIdRequired: datacenterId, isCdn: false, selector: .ephemeralMain, allowUnboundEphemeralKeys: false)
    }
}

/// What came back when the client was pointed at an address and asked a question.
public enum ServerAddressAnswer {
    /// A server of ours is there: it agreed a key and answered.
    case answered
    /// Something is there and it said no, in these words.
    case refused(String)
    /// Nothing came back before the time was up, which is what a wrong address
    /// looks like: it does not refuse, it says nothing at all.
    case silent
}

/// Asks an address whether it is a server of ours.
///
/// help.getConfig rather than a connection: something listening on the port is
/// not the same as a server of ours, and the difference is exactly the case
/// worth catching. Getting an answer at all means the handshake went through,
/// which means it holds a key of ours and speaks the protocol.
///
/// The timeout is the point. A wrong address does not refuse - the request waits
/// for as long as somebody is willing to look at a spinner - so the caller says
/// how long it is prepared to wait for silence.
public func askWhetherServerAnswers(network: Network, timeout seconds: Double) -> Signal<ServerAddressAnswer, NoError> {
    return network.request(Api.functions.help.getConfig())
    |> map { _ -> ServerAddressAnswer in
        return .answered
    }
    |> `catch` { error -> Signal<ServerAddressAnswer, NoError> in
        return .single(.refused(error.errorDescription))
    }
    |> timeout(seconds, queue: Queue.mainQueue(), alternate: .single(.silent))
}
