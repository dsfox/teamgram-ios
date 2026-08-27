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

    /// Which conversation a message was written in, read from the message.
    ///
    /// A device can hold two conversations with the same person - after one
    /// side is reinstalled each of them starts its own - so the group cannot be
    /// chosen by who sent the message. It has to be the one the message names,
    /// and it names it in the clear.
    public static func groupId(ofMessage ciphertext: Data) throws -> Data {
        let buffer = ciphertext.withUnsafeBytes { raw -> MlsBuffer in
            mls_message_group_id(
                raw.bindMemory(to: UInt8.self).baseAddress,
                UInt(ciphertext.count)
            )
        }
        return try take(buffer, "the message names no conversation")
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
    /// Adds every one of these devices in one go, and gives back the single
    /// welcome that lets all of them in.
    ///
    /// One per device is what a person with more than one phone - or one phone
    /// set up more than once - has published. Adding them one at a time makes a
    /// welcome each, and a caller with one welcome to send sends the last: every
    /// other device is then a member of a conversation nobody ever told it
    /// about, and the person reads nothing.
    public func addMembers(identity: MlsIdentity, keyPackages: [Data]) throws -> (commit: Data, welcome: Data) {
        // Length first, four bytes, most significant first - the shape the
        // other side of the boundary reads.
        var joined = Data()
        for package in keyPackages {
            var length = UInt32(package.count).bigEndian
            withUnsafeBytes(of: &length) { joined.append(contentsOf: $0) }
            joined.append(package)
        }

        var commitBuffer = MlsBuffer(ptr: nil, len: 0)
        let welcomeBuffer = joined.withUnsafeBytes { raw -> MlsBuffer in
            mls_group_add_members(
                self.handle,
                identity.handle,
                raw.bindMemory(to: UInt8.self).baseAddress,
                UInt(joined.count),
                &commitBuffer
            )
        }
        let welcome = try take(welcomeBuffer, "the members were not added")
        let commit = try take(commitBuffer, "no commit was produced")
        return (commit: commit, welcome: welcome)
    }

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

    /// Removes every device whose name begins with one of these prefixes, and
    /// gives back the commit the rest have to apply.
    ///
    /// By prefix because removal is asked about a *person* and answered about
    /// devices: a device is named `<user>/<device>`, so the prefix is the
    /// person. Taking one phone and leaving another is worse than not removing
    /// at all - they go on reading from the one that stayed while the interface
    /// says they are gone.
    ///
    /// Nil when nobody matched, which is not a failure: two people removing the
    /// same person at once is ordinary, and the second is looking at a group
    /// that already looks the way they wanted.
    public func removeMembers(identity: MlsIdentity, namePrefixes: [Data]) throws -> Data? {
        var joined = Data()
        for name in namePrefixes {
            var length = UInt32(name.count).bigEndian
            withUnsafeBytes(of: &length) { joined.append(contentsOf: $0) }
            joined.append(name)
        }

        let buffer = joined.withUnsafeBytes { raw -> MlsBuffer in
            mls_group_remove_members(
                self.handle,
                identity.handle,
                raw.bindMemory(to: UInt8.self).baseAddress,
                UInt(joined.count)
            )
        }
        // Nothing back means nothing to do, and the other client reads it the
        // same way. It could also mean the call failed, and the two are not
        // told apart here on purpose: the answer either way is that this device
        // has no commit to offer, and the comparison that asked will ask again.
        guard buffer.ptr != nil else {
            return nil
        }
        return try take(buffer, "the members were not removed")
    }

    /// Who is in the conversation, by the name each device goes under.
    ///
    /// The count cannot answer what this is asked for: two people leaving and
    /// two joining leaves the count exactly where it was.
    public func memberNames() -> [Data] {
        let buffer = mls_group_member_names(self.handle)
        guard let packed = try? take(buffer, "") else {
            return []
        }
        var names: [Data] = []
        var at = 0
        while at + 4 <= packed.count {
            let length = Int(
                UInt32(packed[at]) << 24 | UInt32(packed[at + 1]) << 16
                    | UInt32(packed[at + 2]) << 8 | UInt32(packed[at + 3])
            )
            at += 4
            if length < 0 || at + length > packed.count {
                break
            }
            names.append(packed.subdata(in: at ..< (at + length)))
            at += length
        }
        return names
    }

    /// Makes this device's own commit real, once the delivery service has said
    /// it is the one that took its epoch.
    ///
    /// Adding and removing leave the commit pending on purpose. Of two commits
    /// made from one epoch the protocol takes only one, and a device that moved
    /// on without being told it won ends up in a group of its own that nobody
    /// else can read - which shows up much later as a conversation that went
    /// quiet, for no visible reason.
    public func acceptCommit(identity: MlsIdentity) throws {
        if !mls_group_accept_commit(self.handle, identity.handle) {
            throw MlsError.last("the commit was not applied")
        }
    }

    /// Lets go of a commit the delivery service refused, so the winner can be
    /// applied and the change made again on top of it.
    public func abandonCommit(identity: MlsIdentity) throws {
        if !mls_group_abandon_commit(self.handle, identity.handle) {
            throw MlsError.last("the commit was not let go of")
        }
    }

    /// Applies a commit that arrived through the commit box.
    ///
    /// True when the group moved because somebody else changed it. False when
    /// the commit is one this device made and is being handed back - which is
    /// how the delivery service says it won, and the answer is to apply what is
    /// already staged here. That second half is what makes a lost answer
    /// survivable: a device that sent a commit and never heard back has no
    /// other way to find out, and would sit for ever at an epoch everybody else
    /// has left.
    public func applyCommit(identity: MlsIdentity, commit: Data) throws -> Bool {
        let applied = commit.withUnsafeBytes { raw -> Int32 in
            mls_group_apply_commit(
                self.handle,
                identity.handle,
                raw.bindMemory(to: UInt8.self).baseAddress,
                UInt(commit.count)
            )
        }
        if applied < 0 {
            throw MlsError.last("the commit was not applied")
        }
        return applied == 1
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

/// The words that get an account back, and what they stand for.
///
/// Made here, on the device. The server is told only `authSecret` - enough to
/// recognise somebody typing the words and nothing else - and never sees the
/// words or the backup key. It used to make the phrase itself and send it as a
/// message, which left every one of them in its message table in plain text.
public enum MlsRecovery {
    /// Six words, and the only copy of them is the one shown to the person.
    public static func phrase(words: Int = 6) throws -> String {
        let data = try take(mls_recovery_phrase(UInt(words)), "cannot make a recovery phrase")
        guard let text = String(data: data, encoding: .utf8) else {
            throw MlsError.failed("the recovery phrase is not readable text")
        }
        return text
    }

    /// What is sent in place of the words, and what a sign-in is checked
    /// against. Lower-case hex.
    public static func authSecret(phrase: String) throws -> String {
        let bytes = [UInt8](phrase.utf8)
        let data = try take(bytes.withUnsafeBufferPointer {
            mls_recovery_auth_secret($0.baseAddress, UInt($0.count))
        }, "cannot derive the recovery secret")
        guard let text = String(data: data, encoding: .utf8) else {
            throw MlsError.failed("the recovery secret is not readable text")
        }
        return text
    }

    /// The key the history backup is encrypted with. It never leaves here.
    public static func backupKey(phrase: String) throws -> Data {
        let bytes = [UInt8](phrase.utf8)
        return try take(bytes.withUnsafeBufferPointer {
            mls_recovery_backup_key($0.baseAddress, UInt($0.count))
        }, "cannot derive the backup key")
    }

    /// Whether what somebody typed into the code field is words rather than a
    /// code. Six digits is a code; anything with a letter in it is a phrase, and
    /// what gets sent for it is the derivation rather than the words.
    public static func looksLikeAPhrase(_ typed: String) -> Bool {
        return typed.contains(where: { $0.isLetter })
    }
}
