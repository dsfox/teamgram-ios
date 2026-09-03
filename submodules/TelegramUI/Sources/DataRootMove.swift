import Foundation

/// Moves this app's data from its own sandbox into the app-group container,
/// once, the first time a build with the group runs over a build without it.
///
/// Every build we shipped before #42 had no app group - the group could not be
/// made through the App Store Connect API, so `Telegram/BUILD` did not ask for
/// it - and the app kept everything under its own `Documents/telegram-data`.
/// The notification extension is a second process and can only reach the
/// group container, so the data has to be there. A move within one volume is a
/// rename: atomic, instant, no copy, however big the database is.
///
/// Answers whether the data is now at `groupRoot`. When it cannot be moved -
/// something already at the destination, a failure in the rename - the app
/// stays where its data is, and the log says why; a phone that cannot be
/// moved is not a phone that cannot start.
///
/// A function of two directories rather than of the app, so that
/// `tests/ios/data_root_move/main.swift` can run it on the host over
/// temporary ones.
public func moveDataRootIfNeeded(from sandboxRoot: URL, to groupRoot: URL, fileManager: FileManager = .default, log: (String) -> Void = { _ in }) -> Bool {
    let name = "telegram-data"
    let old = sandboxRoot.appendingPathComponent(name, isDirectory: true)
    let new = groupRoot.appendingPathComponent(name, isDirectory: true)

    if fileManager.fileExists(atPath: new.path) {
        if fileManager.fileExists(atPath: old.path) {
            // Both. The group's copy is the one every process would open, and a
            // move would replace it; whatever the sandbox still holds is left
            // alone rather than decided about here.
            log("data root: both \(old.path) and \(new.path) exist; using the group's")
        }
        return true
    }
    guard fileManager.fileExists(atPath: old.path) else {
        // A fresh install: nothing to move, and the app makes its data where
        // it is told to, which is the group.
        return true
    }
    do {
        try fileManager.createDirectory(at: groupRoot, withIntermediateDirectories: true)
        try fileManager.moveItem(at: old, to: new)
        log("data root: moved \(old.path) into the group container")
        return true
    } catch {
        log("data root: could not move \(old.path) to \(new.path): \(error) - staying in the sandbox")
        return false
    }
}
