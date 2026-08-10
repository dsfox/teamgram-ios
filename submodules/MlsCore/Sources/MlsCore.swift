import Foundation
import mls

/// End-to-end encryption, as Swift sees it.
///
/// The cryptography itself is one piece of Rust shared with the Android client -
/// written once, tested once, and impossible to have in one client and not the
/// other. This file is only the manners: turning C's pointers and lengths into
/// values that cannot be leaked or freed twice.
///
/// The shape mirrors the core: an identity per device, a group per chat. A chat
/// between two people is a group of two, a group chat is a group of many, and a
/// person's second phone is another member of the same group.
public enum MlsError: Error, CustomStringConvertible {
    case failed(String)

    public var description: String {
        switch self {
        case let .failed(reason):
            return reason
        }
    }

    /// The reason the core recorded for the call that just failed.
    static func last(_ fallback: String) -> MlsError {
        guard let raw = mls_last_error() else {
            return .failed(fallback)
        }
        let reason = String(cString: raw)
        return .failed(reason.isEmpty ? fallback : reason)
    }
}

/// Takes ownership of a buffer the core returned and gives it back afterwards,
/// so a path that throws cannot leak it.
private func take(_ buffer: MlsBuffer, _ fallback: String) throws -> Data {
    guard let pointer = buffer.ptr else {
        throw MlsError.last(fallback)
    }
    defer { mls_buffer_free(buffer) }
    return Data(bytes: pointer, count: Int(buffer.len))
}

/// This device's identity: the key it signs with, and the name it goes by.
public final class MlsIdentity {
    fileprivate let handle: OpaquePointer

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    /// - Parameter name: what names this device - a user id and a device id,
    ///   joined. Per device rather than per person, because that is what makes
    ///   several devices possible at all.
    public init(name: Data) throws {
        guard let handle = name.withUnsafeBytes({ raw -> OpaquePointer? in
            mls_identity_new(raw.bindMemory(to: UInt8.self).baseAddress, UInt(name.count))
        }) else {
            throw MlsError.last("no identity was created")
        }
        self.handle = handle
    }

    deinit {
        mls_identity_free(self.handle)
    }

    /// What somebody else needs in order to add this device to a conversation.
    /// Published to the server, handed out on request, used once.
    public func keyPackage() throws -> Data {
        return try take(mls_identity_key_package(self.handle), "no key package was built")
    }

    /// Everything this device needs to carry on after the app is closed: its
    /// key, its conversations, and where each ratchet had got to. Without
    /// storing this, closing the app would leave every conversation unreadable
    /// - by design and for good.
    ///
    /// It holds the keys to everything this device can read, so it belongs
    /// wherever the client keeps its most guarded things.
    public func export() throws -> Data {
        return try take(mls_identity_export(self.handle), "nothing was saved")
    }

    /// Reads a device back from what `export` wrote.
    public static func open(state: Data) throws -> MlsIdentity {
        guard let handle = state.withUnsafeBytes({ raw -> OpaquePointer? in
            mls_identity_open(raw.bindMemory(to: UInt8.self).baseAddress, UInt(state.count))
        }) else {
            throw MlsError.last("the device did not come back")
        }
        return MlsIdentity(handle: handle)
    }
}

/// One conversation.
public final class MlsGroup {
    private let handle: OpaquePointer

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        mls_group_free(self.handle)
    }

    /// Starts a conversation holding only this device.
    public static func create(identity: MlsIdentity) throws -> MlsGroup {
        guard let handle = mls_group_create(identity.handle) else {
            throw MlsError.last("no group was created")
        }
        return MlsGroup(handle: handle)
    }

    /// Reopens a conversation this device was already in. Returns nil when this
    /// device does not know it - which is an answer, not a failure: a chat can
    /// exist on the server and not on this phone.
    public static func load(identity: MlsIdentity, id: Data) throws -> MlsGroup? {
        guard let handle = id.withUnsafeBytes({ raw -> OpaquePointer? in
            mls_group_load(
                identity.handle,
                raw.bindMemory(to: UInt8.self).baseAddress,
                UInt(id.count)
            )
        }) else {
            return nil
        }
        return MlsGroup(handle: handle)
    }

    /// Which conversation this is, to keep beside the chat so it can be
    /// reopened after a restart.
    public var id: Data {
        get throws {
            return try take(mls_group_id(self.handle), "the conversation has no id")
        }
    }

    /// Joins a conversation this device was invited into.
    public static func join(identity: MlsIdentity, welcome: Data) throws -> MlsGroup {
        guard let handle = welcome.withUnsafeBytes({ raw -> OpaquePointer? in
            mls_group_join(
                identity.handle,
                raw.bindMemory(to: UInt8.self).baseAddress,
                UInt(welcome.count)
            )
        }) else {
            throw MlsError.last("the invitation was refused")
        }
        return MlsGroup(handle: handle)
    }

    /// Adds a device. The commit goes to everybody already here; the welcome
    /// goes to the newcomer. Both have to be delivered, or the conversation
    /// splits in two.
    public func addMember(identity: MlsIdentity, keyPackage: Data) throws -> (commit: Data, welcome: Data) {
        var commitBuffer = MlsBuffer(ptr: nil, len: 0)
        let welcomeBuffer = keyPackage.withUnsafeBytes { raw -> MlsBuffer in
            mls_group_add_member(
                self.handle,
                identity.handle,
                raw.bindMemory(to: UInt8.self).baseAddress,
                UInt(keyPackage.count),
                &commitBuffer
            )
        }
        let welcome = try take(welcomeBuffer, "the member was not added")
        let commit = try take(commitBuffer, "no commit was produced")
        return (commit: commit, welcome: welcome)
    }

    public func encrypt(identity: MlsIdentity, plaintext: Data) throws -> Data {
        let buffer = plaintext.withUnsafeBytes { raw -> MlsBuffer in
            mls_group_encrypt(
                self.handle,
                identity.handle,
                raw.bindMemory(to: UInt8.self).baseAddress,
                UInt(plaintext.count)
            )
        }
        return try take(buffer, "nothing was encrypted")
    }

    /// Reads a message, or applies a commit that moved the conversation on.
    /// Returns nil for the second: the caller hands everything here and does not
    /// have to know which arrived.
    public func decrypt(identity: MlsIdentity, ciphertext: Data) throws -> Data? {
        var handshake: UInt8 = 0
        let buffer = ciphertext.withUnsafeBytes { raw -> MlsBuffer in
            mls_group_decrypt(
                self.handle,
                identity.handle,
                raw.bindMemory(to: UInt8.self).baseAddress,
                UInt(ciphertext.count),
                &handshake
            )
        }
        if handshake == 1 {
            mls_buffer_free(buffer)
            return nil
        }
        return try take(buffer, "nothing was decrypted")
    }

    /// How many devices are here. A person with two phones counts twice.
    public var memberCount: Int {
        return Int(mls_group_members(self.handle))
    }

    /// The conversation's version. It moves whenever the membership or the keys
    /// change, and a device left at an older one can read nothing new.
    public var epoch: UInt64 {
        return mls_group_epoch(self.handle)
    }
}

/// Proves on the device that the whole path works: two identities, a group, a
/// message that survives the trip, and a ciphertext that does not contain the
/// plaintext. Called from a smoke test rather than from the app.
public func mlsSelfCheck() -> String {
    do {
        let alice = try MlsIdentity(name: Data("alice/phone".utf8))
        let bob = try MlsIdentity(name: Data("bob/phone".utf8))

        let group = try MlsGroup.create(identity: alice)
        let invitation = try group.addMember(identity: alice, keyPackage: try bob.keyPackage())
        let bobGroup = try MlsGroup.join(identity: bob, welcome: invitation.welcome)

        let secret = Data("the server is not supposed to read this".utf8)
        let ciphertext = try group.encrypt(identity: alice, plaintext: secret)
        guard ciphertext.range(of: Data("server".utf8)) == nil else {
            return "FAIL: the plaintext is visible in the ciphertext"
        }

        guard let read = try bobGroup.decrypt(identity: bob, ciphertext: ciphertext) else {
            return "FAIL: that was read as a handshake, not a message"
        }
        guard read == secret else {
            return "FAIL: the message did not survive"
        }
        guard bobGroup.memberCount == 2 else {
            return "FAIL: the group holds \(bobGroup.memberCount) devices, expected 2"
        }

        return "ok: two devices, epoch \(group.epoch), \(ciphertext.count) bytes of ciphertext"
    } catch {
        return "FAIL: \(error)"
    }
}
