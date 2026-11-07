import Foundation
import RafuCore

/// The personalization profile file:
/// `<Application Support>/Voice/style-profile.json`, written atomically with
/// mode 0600, at most 4 KiB. Never synced, never exported, never logged. Only
/// this store and the Settings View popup read it.
nonisolated struct VoiceStyleProfileStore: Sendable {
    let fileURL: URL

    init(root: URL = RafuAppIdentity.current.applicationSupportRoot()) {
        fileURL = root.appending(path: "Voice", directoryHint: .isDirectory)
            .appending(path: "style-profile.json")
    }

    /// `nil` when there is no profile yet. A file that fails validation is
    /// treated as absent.
    func load() -> VoiceStyleProfile? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? VoiceStyleProfile.decode(data)
    }

    func save(_ profile: VoiceStyleProfile) throws {
        try profile.validate()
        let data = try profile.encoded()
        let folder = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Deletes the profile. A missing file is not an error.
    func reset() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
