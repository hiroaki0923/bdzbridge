import Foundation
import RecorderKit

// Where the television's registration and the helper's token are kept on Android: files in the app's own folder that
// Android leaves out of every backup and every move to another device, `Context.getNoBackupFilesDir()` -- its backup
// rules always leave that folder out, whatever an app asks. So they stay on this device, as the iOS app's Keychain items
// do: the client id lets anything on the LAN get a cookie from the television without a PIN, and the token lets it read
// the television's guide. The folder is the app's alone, opens once the device has been unlocked after a start, as the
// rest of an app's own storage does, and goes when the app is uninstalled; a device the app comes to some other way
// registers again, with the PIN once. The manifest's `allowBackup="false"` is not enough for that: for an app aimed at
// Android 12 or later, some makers' devices still move its data to another device with it off.

/// The television's registration, in `<kept>/television.json`. A file that cannot be read, or that does not read as a
/// registration, is no registration, and stays until a registration writes over it.
final class KeptTVCredentials: TVCredentialStore {
    let file: URL

    init(folder: URL) {
        file = folder.appendingPathComponent("television.json")
    }

    func load() -> TVCredentials? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(TVCredentials.self, from: data)
    }

    /// Whole or not at all: a write cut short leaves the last one.
    func save(_ credentials: TVCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        write(data, to: file)
    }

    func remove() {
        try? FileManager.default.removeItem(at: file)
    }
}

/// The helper's token, in `<kept>/helper-token`, apart from the television's own registration as on iOS.
final class KeptTVHelperToken: TVHelperTokenStore {
    let file: URL

    init(folder: URL) {
        file = folder.appendingPathComponent("helper-token")
    }

    func load() -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ token: String) {
        write(Data(token.utf8), to: file)
    }

    func remove() {
        try? FileManager.default.removeItem(at: file)
    }
}

private func write(_ data: Data, to file: URL) {
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: file, options: .atomic)
}
