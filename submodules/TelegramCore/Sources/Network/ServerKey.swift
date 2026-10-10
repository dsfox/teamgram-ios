import Foundation
import SwiftSignalKit

/// What a server said when asked for its own key (#244).
public enum ServerKeyAnswer: Equatable {
    /// A key the app may keep, as DER - whether it is the right one is the
    /// code's to say.
    case key(Data)
    /// Something answered, but gave no key the app takes: an image from before
    /// server codes, a server without a key of its own, or something else on
    /// the port.
    case noKey
    /// No connection, or nothing at all before the time was up.
    case unreachable
}

/// Fetches a server's own key the way check-mtproto.py --code does: a plain
/// TCP connection to the MTProto port, `GET /key`, and the RSA PUBLIC KEY block
/// in the answer, read strictly by ServerCode. Raw sockets rather than
/// URLSession: the request is plain HTTP to an address somebody typed, and the
/// only thing trusted about the answer is the code it is checked against.
///
/// The twin of ServerKey.java on the other client.
public enum ServerKey {
    public static func fetch(_ address: ServerAddress, timeout: Double = 10.0) -> Signal<ServerKeyAnswer, NoError> {
        return Signal { subscriber in
            Queue.concurrentDefaultQueue().async {
                let answer = fetchNow(host: address.host, port: address.port, timeout: timeout)
                Logger.shared.log("ServerKey", "GET /key at \(address.described): \(describe(answer))")
                subscriber.putNext(answer)
                subscriber.putCompletion()
            }
            return EmptyDisposable
        }
    }

    private static func describe(_ answer: ServerKeyAnswer) -> String {
        switch answer {
        case let .key(der):
            return "a key with the code \(ServerCode.code(der))"
        case .noKey:
            return "no key the app takes"
        case .unreachable:
            return "nothing answered"
        }
    }

    static func fetchNow(host: String, port: Int32, timeout: Double) -> ServerKeyAnswer {
        let deadline = Date().addingTimeInterval(timeout)
        guard let socket = connect(host: host, port: port, deadline: deadline) else {
            return .unreachable
        }
        defer {
            close(socket)
        }
        let request = Array("GET /key HTTP/1.0\r\nHost: \(host)\r\n\r\n".utf8)
        var sent = 0
        while sent < request.count {
            guard wait(socket, for: Int16(POLLOUT), until: deadline) else {
                return .unreachable
            }
            let written = request[sent...].withUnsafeBytes { send(socket, $0.baseAddress, $0.count, 0) }
            if written <= 0 {
                return .unreachable
            }
            sent += written
        }
        var answer = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while answer.count < 8192 {
            guard wait(socket, for: Int16(POLLIN), until: deadline) else {
                break
            }
            let read = buffer.withUnsafeMutableBytes { recv(socket, $0.baseAddress, min($0.count, 8192 - answer.count), 0) }
            if read <= 0 {
                break
            }
            answer.append(contentsOf: buffer[0 ..< read])
        }
        if answer.isEmpty {
            return .unreachable
        }
        guard let text = String(bytes: answer, encoding: .ascii), let der = ServerCode.derFromPem(text) else {
            return .noKey
        }
        return .key(der)
    }

    /// A connected, non-blocking socket to the first address that takes one in time.
    private static func connect(host: String, port: Int32, deadline: Date) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var found: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &found) == 0, let first = found else {
            return nil
        }
        defer {
            freeaddrinfo(first)
        }
        var next: UnsafeMutablePointer<addrinfo>? = first
        while let entry = next {
            next = entry.pointee.ai_next
            let socket = Darwin.socket(entry.pointee.ai_family, entry.pointee.ai_socktype, entry.pointee.ai_protocol)
            if socket < 0 {
                continue
            }
            var one: Int32 = 1
            _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL, 0) | O_NONBLOCK)
            if Darwin.connect(socket, entry.pointee.ai_addr, entry.pointee.ai_addrlen) == 0 {
                return socket
            }
            if errno == EINPROGRESS, wait(socket, for: Int16(POLLOUT), until: deadline) {
                var failure: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(socket, SOL_SOCKET, SO_ERROR, &failure, &size) == 0, failure == 0 {
                    return socket
                }
            }
            close(socket)
        }
        return nil
    }

    private static func wait(_ socket: Int32, for events: Int16, until deadline: Date) -> Bool {
        let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
        if remaining == 0 {
            return false
        }
        var entry = pollfd(fd: socket, events: events, revents: 0)
        return poll(&entry, 1, remaining) > 0 && entry.revents & (events | Int16(POLLHUP)) != 0
    }
}
