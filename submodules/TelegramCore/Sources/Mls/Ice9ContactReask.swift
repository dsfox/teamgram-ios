import Foundation

/// When a number of the address book that nobody in ice9 held is asked about
/// again (#297).
///
/// The phone sends each number to `contacts.importContacts` once, and the
/// server keeps only the numbers of people already here - that is the App
/// Store promise. So a person who signs up later stays nobody's contact: the
/// server cannot tell anybody, and the phone never asks again. Asking again
/// once a day is what makes them a contact, and what the Contacts tab's
/// search finds.
///
/// The time it last asked is a file of its own in the app's own container,
/// one per account, so a walk can make the next launch ask by removing it.
public enum Ice9ContactReask {
    static let interval: Double = 24.0 * 60.0 * 60.0

    static func file(accountPeerId: Int64) -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support.appendingPathComponent("ice9-contacts-asked-\(accountPeerId)")
    }

    /// Whether a day has passed since this account last asked; when it has,
    /// this round is the one that asks, and the time is written down now.
    /// Written whether or not anybody turns out to be new, so a phone whose
    /// address book holds nobody to ask about does not ask on every update.
    static func take(accountPeerId: Int64, now: Date = Date()) -> Bool {
        guard let file = file(accountPeerId: accountPeerId) else {
            return false
        }
        if let text = try? String(contentsOf: file, encoding: .utf8), let last = Double(text) {
            let since = now.timeIntervalSince1970 - last
            if since >= 0 && since < interval {
                return false
            }
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? String(now.timeIntervalSince1970).write(to: file, atomically: true, encoding: .utf8)
        Logger.shared.log("Contacts", "asking again about the numbers nobody held")
        return true
    }
}
