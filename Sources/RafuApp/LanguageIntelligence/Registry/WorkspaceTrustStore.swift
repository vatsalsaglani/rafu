import Foundation

/// The on-disk shape of `<AppSupportBase>/Rafu/language-server-trust.json`:
/// which server ids a user has explicitly approved running, per workspace.
/// Settings, not secrets — plain JSON, never Keychain.
nonisolated struct TrustFile: Codable, Sendable {
    var schemaVersion: Int
    var approvals: [String: [String]]
}

/// Per-workspace, per-server trust approvals: a first-launch prompt (C4)
/// records a user's explicit "yes, run this server for this workspace"
/// decision here, and `InstalledServerResolver` consults it before ever
/// resolving a server — installed alone is never enough to run.
nonisolated struct WorkspaceTrustStore: Sendable {
    static let currentSchemaVersion = 1

    /// Defaults to the real per-user Application Support directory; tests
    /// inject a temporary directory so this store never touches
    /// `~/Library/Application Support`.
    let baseDirectory: URL

    init(baseDirectory: URL = WorkspaceTrustStore.defaultBaseDirectory) {
        self.baseDirectory = baseDirectory
    }

    static var defaultBaseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Rafu", directoryHint: .isDirectory)
    }

    private var fileURL: URL {
        baseDirectory.appending(path: "language-server-trust.json")
    }

    @concurrent
    func load() async throws -> TrustFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return TrustFile(schemaVersion: Self.currentSchemaVersion, approvals: [:])
        }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        return try JSONDecoder().decode(TrustFile.self, from: data)
    }

    @concurrent
    func save(_ file: TrustFile) async throws {
        try FileManager.default.createDirectory(
            at: baseDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(file)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Whether `serverID` has been explicitly approved for
    /// `workspaceKey` (a stable, opaque identifier for one workspace root —
    /// callers own how that key is derived).
    @concurrent
    func isTrusted(serverID: String, forWorkspaceKey workspaceKey: String) async throws -> Bool {
        let file = try await load()
        return file.approvals[workspaceKey]?.contains(serverID) ?? false
    }

    /// Records approval of `serverID` for `workspaceKey`. Idempotent —
    /// approving an already-approved server id is a no-op beyond a
    /// round-trip save.
    @concurrent
    func approve(serverID: String, forWorkspaceKey workspaceKey: String) async throws {
        var file = try await load()
        var approved = file.approvals[workspaceKey] ?? []
        if !approved.contains(serverID) {
            approved.append(serverID)
        }
        file.approvals[workspaceKey] = approved
        try await save(file)
    }

    /// Revokes approval of `serverID` for `workspaceKey`, if present.
    @concurrent
    func revoke(serverID: String, forWorkspaceKey workspaceKey: String) async throws {
        var file = try await load()
        guard var approved = file.approvals[workspaceKey] else { return }
        approved.removeAll { $0 == serverID }
        if approved.isEmpty {
            file.approvals.removeValue(forKey: workspaceKey)
        } else {
            file.approvals[workspaceKey] = approved
        }
        try await save(file)
    }
}
