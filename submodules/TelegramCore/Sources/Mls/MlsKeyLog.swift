import Foundation
import MtProtoKit
import SwiftSignalKit
import TelegramApi
import MlsCore

/// A claimed key package is added only when the key log holds its key (#44).
///
/// A key package is signed by its device's own key, but which key belongs to
/// which person a phone could only take on the server's word: a server could
/// hand out a package built on a key of its own under a real device's name and
/// join the conversation. The server writes every key it hands out into an
/// append-only log (RFC 9162's tree) and signs the log's head; this asks for the
/// person's entries before their packages are added, and adds only a package
/// whose (name, key) is an entry with a valid inclusion proof under a head
/// signed by the log key this phone pinned, and consistent with the newest head
/// it kept. A key the server logged to listen in stays in the log for good,
/// where the owner's own phones see it.
///
/// Required only from a server that has shown its log once: a server of one's
/// own on an older image, and ours before the log, answer as they always did.
/// The pin and the newest head are kept per server, in the container every
/// process of the app opens, beside the server's address.
///
/// The twin of MlsKeyLog.java.
public enum MlsKeyLog {
    private struct Kept: Codable {
        var key: Data
        var size: Int64
        var root: Data
    }

    private static let lock = NSLock()

    private static func file(network: Network) -> String {
        let rootPath = (network.basePath as NSString).deletingLastPathComponent
        return rootPath + "/mls-key-log"
    }

    private static func server(network: Network) -> String {
        return ServerAddressStore(rootPath: (network.basePath as NSString).deletingLastPathComponent).effective.described
    }

    private static func read(network: Network) -> [String: Kept] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file(network: network))),
              let all = try? JSONDecoder().decode([String: Kept].self, from: data) else {
            return [:]
        }
        return all
    }

    private static func write(network: Network, server: String, kept: Kept) {
        lock.lock()
        defer { lock.unlock() }
        var all = read(network: network)
        all[server] = kept
        if let data = try? JSONEncoder().encode(all) {
            try? data.write(to: URL(fileURLWithPath: file(network: network)), options: .atomic)
        }
    }

    /// mls.claimKeyPackages, with the answer cut down to the packages the key
    /// log vouches for. A failed claim fails as it did.
    static func claim(network: Network, userId: Int64) -> Signal<Api.mls.KeyPackages, MTRpcError> {
        return network.request(Api.functions.mls.claimKeyPackages(userId: userId))
        |> mapToSignal { (answer: Api.mls.KeyPackages) -> Signal<Api.mls.KeyPackages, MTRpcError> in
            if answer.packages.isEmpty {
                return .single(answer)
            }
            let vetted: Signal<[Data], NoError> = vet(network: network, userId: userId, packages: answer.packages.map { $0.makeData() })
            return vetted
            |> map { (kept: [Data]) -> Api.mls.KeyPackages in
                return Api.mls.KeyPackages(packages: kept.map { Buffer(data: $0) })
            }
            |> castError(MTRpcError.self)
        }
    }

    private static func vet(network: Network, userId: Int64, packages: [Data]) -> Signal<[Data], NoError> {
        let server = self.server(network: network)
        let pinned = read(network: network)[server]
        return network.request(Api.functions.mls.getKeyLog(userId: userId, knownSize: pinned?.size ?? 0))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.mls.KeyLog?, NoError> in .single(nil) }
        |> map { log -> [Data] in
            guard let log = log else {
                if pinned == nil {
                    // A server that has never shown a log: as before the log.
                    return packages
                }
                refuse(userId: userId, packages: packages, why: "the key log did not answer")
                return []
            }
            let head = log.head
            let root = head.root.makeData()
            let logKey = head.logKey.makeData()
            var wrong: String?
            if !MlsKeyLogCheck.headIsSigned(size: UInt64(max(head.size, 0)), root: root, date: head.date, logKey: logKey, signature: head.signature.makeData()) {
                wrong = "the key log's head is not signed by its own key"
            } else if let pinned = pinned {
                if pinned.key != logKey {
                    wrong = "the key log is signed by another key than the one this phone pinned"
                } else if head.size < pinned.size {
                    wrong = "the key log holds \(head.size) keys, and this phone saw \(pinned.size)"
                } else if head.size == pinned.size && root != pinned.root {
                    wrong = "the key log of \(head.size) keys is not the one this phone saw"
                } else if head.size > pinned.size && pinned.size > 0 && !MlsKeyLogCheck.provesConsistency(
                    first: UInt64(pinned.size), second: UInt64(head.size), firstRoot: pinned.root, secondRoot: root,
                    proof: joined(log.consistency)) {
                    wrong = "the key log of \(head.size) keys does not hold the one of \(pinned.size) this phone saw"
                }
            }
            if let wrong = wrong {
                refuse(userId: userId, packages: packages, why: wrong)
                return []
            }
            if pinned == nil {
                Logger.shared.log("Mls", "the key log of \(server) is pinned now, at \(head.size) keys")
            }
            if pinned == nil || head.size > pinned!.size {
                write(network: network, server: server, kept: Kept(key: logKey, size: head.size, root: root))
            }

            return packages.filter { keyPackage in
                guard let name = try? MlsGroup.name(ofKeyPackage: keyPackage),
                      let key = try? MlsKeyLogCheck.signatureKey(ofKeyPackage: keyPackage) else {
                    Logger.shared.log("Mls", "a package of \(userId) names no device, so it is not added")
                    return false
                }
                let proved = log.entries.contains { entry in
                    entry.name.makeData() == name && entry.signatureKey.makeData() == key
                        && MlsKeyLogCheck.provesInclusion(userId: userId, name: name, signatureKey: key,
                                                          index: UInt64(max(entry.index, 0)), size: UInt64(max(head.size, 0)),
                                                          proof: joined(entry.proof), root: root)
                }
                if !proved {
                    Logger.shared.log("Mls", "a package of \(userId) for \(String(decoding: name, as: UTF8.self)) is not in the key log, so it is not added")
                }
                return proved
            }
        }
    }

    private static func refuse(userId: Int64, packages: [Data], why: String) {
        Logger.shared.log("Mls", "\(why); none of the \(packages.count) package(s) of \(userId) is added")
    }

    private static func joined(_ hashes: [Buffer]) -> Data {
        var out = Data()
        for hash in hashes {
            out.append(hash.makeData())
        }
        return out
    }
}
