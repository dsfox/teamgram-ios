import Foundation
import CommonCrypto

/// A server of one's own has a key of its own, and a person gives the app the
/// server's code beside its address (#244). The app fetches the key from the
/// server and keeps it only if the code is the key's: SHA-256 over the key's
/// canonical DER, its first 10 bytes read as a big-endian number, mod 10^24,
/// written as 24 digits. Only the canonical PKCS#1 encoding of an RSA-2048 key
/// with e 65537 is taken - anything looser would let somebody vary the encoding
/// rather than the key to hit a code - and teamgram's stock key, whose private
/// half is public, never is.
///
/// The reference is server/deploy/check-mtproto.py; this file and Android's
/// ServerCode.java are held to it by tests/test_the_server_code_is_one_rule.py,
/// which compiles and runs both against server/deploy/keys/server_code_vectors.json.
/// Nothing here may import more than Foundation and CommonCrypto.
public enum ServerCode {
    /// The code of ice9's own key, the one built into the handshake.
    public static let builtInKeyCode = "138485278689309020570713"
    /// The code of teamgram's stock key.
    static let stockKeyCode = "021519610579788994498158"

    private static let head: [UInt8] = [0x30, 0x82, 0x01, 0x0a, 0x02, 0x82, 0x01, 0x01, 0x00]
    private static let tail: [UInt8] = [0x02, 0x03, 0x01, 0x00, 0x01]
    private static let length = 270
    private static let pemBegin = "-----BEGIN RSA PUBLIC KEY-----"
    private static let pemEnd = "-----END RSA PUBLIC KEY-----"

    public static func isAcceptable(_ der: Data) -> Bool {
        let bytes = [UInt8](der)
        guard bytes.count == length, Array(bytes.prefix(head.count)) == head, Array(bytes.suffix(tail.count)) == tail, bytes[9] & 0x80 != 0 else {
            return false
        }
        return code(der) != stockKeyCode
    }

    /// The DER of the one RSA PUBLIC KEY block in a text, if it is a key the app may keep.
    public static func derFromPem(_ text: String) -> Data? {
        guard text.components(separatedBy: pemBegin).count == 2, text.components(separatedBy: pemEnd).count == 2,
              let begin = text.range(of: pemBegin), let end = text.range(of: pemEnd), begin.upperBound <= end.lowerBound else {
            return nil
        }
        let body = text[begin.upperBound ..< end.lowerBound].filter { $0 != " " && $0 != "\t" && $0 != "\r" && $0 != "\n" }
        guard body.count == 360, body.unicodeScalars.allSatisfy({ isBase64Character($0) }),
              let der = Data(base64Encoded: String(body)), isAcceptable(der) else {
            return nil
        }
        return der
    }

    private static func isBase64Character(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A" ... "Z", "a" ... "z", "0" ... "9", "+", "/":
            return true
        default:
            return false
        }
    }

    public static func code(_ der: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        der.withUnsafeBytes { raw in
            _ = CC_SHA256(raw.baseAddress, CC_LONG(der.count), &digest)
        }
        // The first 10 bytes as one number, its lowest 24 decimal digits.
        var number = Array(digest.prefix(10))
        var digits: [Character] = []
        for _ in 0 ..< 24 {
            var remainder = 0
            for index in number.indices {
                let value = remainder * 256 + Int(number[index])
                number[index] = UInt8(value / 10)
                remainder = value % 10
            }
            digits.append(Character(String(remainder)))
        }
        return String(digits.reversed())
    }

    /// The key as PEM, rebuilt from the DER the way the built-in key is written.
    public static func pem(_ der: Data) -> String {
        let base64 = der.base64EncodedString()
        var lines: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let next = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index ..< next]))
            index = next
        }
        return "\(pemBegin)\n" + lines.joined(separator: "\n") + "\n\(pemEnd)"
    }

    /// What a person typed as a code: nil if it is not one, "" if nothing.
    public static func digits(_ typed: String) -> String? {
        var bare = ""
        for scalar in typed.unicodeScalars {
            switch scalar {
            case "0" ... "9":
                bare.unicodeScalars.append(scalar)
            case " ", "-":
                continue
            default:
                return nil
            }
        }
        if bare.isEmpty {
            return ""
        }
        return bare.count == 24 ? bare : nil
    }

    public static func grouped(_ code: String) -> String {
        var groups: [String] = []
        var index = code.startIndex
        while index < code.endIndex {
            let next = code.index(index, offsetBy: 4, limitedBy: code.endIndex) ?? code.endIndex
            groups.append(String(code[index ..< next]))
            index = next
        }
        return groups.joined(separator: " ")
    }
}

/// The link the installer prints and draws as a QR code (#244):
/// https://i.ice9.app/server#<host>:<port>/<24 digits>, or tg2://server#...
public enum ServerLink: Equatable {
    case link(host: String, port: Int32, code: String)
    case malformed

    private static let prefixes = ["https://i.ice9.app/server#", "http://i.ice9.app/server#", "tg2://server#"]

    /// The server a link names, .malformed for a server link that cannot be
    /// read, nil for any other link.
    public static func parse(_ url: String) -> ServerLink? {
        guard let prefix = prefixes.first(where: { url.count >= $0.count && url.prefix($0.count).lowercased() == $0 }) else {
            return nil
        }
        let rest = String(url.dropFirst(prefix.count))
        guard !rest.contains("%"),
              let expression = try? NSRegularExpression(pattern: "^([A-Za-z0-9.\\-]+):([0-9]{1,5})(?:/([0-9]{24}))?$"),
              let match = expression.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
              let hostRange = Range(match.range(at: 1), in: rest), let portRange = Range(match.range(at: 2), in: rest),
              let port = Int32(rest[portRange]), port >= 1, port <= 65535 else {
            return .malformed
        }
        var code = ""
        if let codeRange = Range(match.range(at: 3), in: rest) {
            code = String(rest[codeRange])
        }
        return .link(host: String(rest[hostRange]), port: port, code: code)
    }
}
