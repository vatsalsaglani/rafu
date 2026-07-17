import Foundation

/// How a `ServerDescriptor` is obtained and run. `.localDiscovery` never
/// downloads anything — it only looks for an already-installed toolchain
/// binary (Xcode's `sourcekit-lsp`, a `gopls` on `PATH`) — so descriptors of
/// that kind carry `source == nil`.
nonisolated enum ServerKind: String, Codable, Sendable {
    case singleBinary
    case nodeHosted
    case localDiscovery
}

/// How a downloaded asset is packaged, and therefore how
/// `ServerInstaller` must unpack it.
nonisolated enum ArchiveFormat: String, Codable, Sendable {
    /// The download itself *is* the executable (no unpack step beyond a
    /// copy).
    case rawBinary
    /// A single gzip-compressed file (`gunzip`), not a tarball — e.g.
    /// rust-analyzer's release asset.
    case gzip
    /// A `.zip` archive (`ditto -x -k`).
    case zip
    /// A gzip-compressed tarball (`tar -xzf`) — npm release tarballs and
    /// the Node.js runtime distribution both use this shape.
    case tarGzip
}

/// Where the installed executable/entry point lives once `format` has been
/// unpacked into a server's install directory, relative to that directory's
/// root.
nonisolated struct ArchiveLayout: Codable, Hashable, Sendable {
    let format: ArchiveFormat
    let binaryRelativePath: String
    /// The directory, relative to the install root, that `npm install`
    /// should run in — an npm release tarball's real package root (e.g.
    /// `"package"`), or `nil` when the unpacked asset needs no npm
    /// dependency resolution (a self-contained bundle, or a non-npm
    /// archive). Optional so a legacy `ArchiveLayout` JSON payload that
    /// predates this property still decodes.
    var npmPackageRoot: String?
}

/// Where and how to fetch one server's asset, and what it costs to run
/// unverified: `checksum` is `nil` for a project that doesn't publish a
/// per-asset digest, in which case `ServerInstaller` still installs the
/// asset but reports that its checksum was never verified — it never
/// invents or skips the download to force a checksum into existence.
nonisolated struct ServerSource: Codable, Hashable, Sendable {
    let url: URL
    let version: String
    /// A lowercase hex-encoded SHA-256 digest, when the upstream project
    /// publishes one for this exact asset.
    let checksum: String?
    let license: String
    let estimatedBytes: UInt64?
}

/// A condition `InstalledServerResolver` (or a future settings UI) must
/// satisfy before a descriptor can run, beyond "the binary is on disk."
nonisolated enum ServerPrerequisite: Codable, Hashable, Sendable {
    /// Requires `NodeRuntimeManager.ensureInstalled()` to have completed.
    case managedNodeRuntime
    /// Requires a selected Xcode toolchain (`xcrun --find` resolves).
    case xcodeToolchain
    /// A free-form, user-facing note surfaced in a future catalog UI —
    /// never parsed, never used to gate anything programmatically.
    case note(String)
}

/// Everything needed to describe, install, and launch one language server,
/// whether it comes from the curated catalog or a user-added entry.
/// `source == nil` only for `.localDiscovery` — every other kind must name
/// exactly where its asset comes from.
nonisolated struct ServerDescriptor: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let languageIDs: [String]
    let displayName: String
    let kind: ServerKind
    let source: ServerSource?
    let launchArguments: [String]
    let archive: ArchiveLayout?
    let initializationOptions: JSONValue?
    let prerequisites: [ServerPrerequisite]
}

/// The on-disk shape of `<AppSupportBase>/Rafu/language-servers.json`: a
/// user's own added entries (GitHub-release single binaries, npm-hosted
/// servers, or a pre-installed local binary), independent of
/// `CuratedCatalog`.
nonisolated struct UserEntriesFile: Codable, Sendable {
    var schemaVersion: Int
    var servers: [ServerDescriptor]
}

nonisolated enum UserEntryStoreError: Error, Equatable {
    /// A user-supplied descriptor's `source.url` was neither `https` nor an
    /// explicit local `file://` reference. Rejected before it is ever
    /// persisted or handed to `ServerInstaller` — never shell-interpolated,
    /// never silently coerced.
    case insecureSourceURL(id: String)
}

/// Loads, saves, and edits a user's own server entries in
/// `<AppSupportBase>/Rafu/language-servers.json`. Never touches
/// `CuratedCatalog`'s entries. Settings, not secrets — plain JSON, never
/// Keychain.
nonisolated struct UserEntryStore: Sendable {
    static let currentSchemaVersion = 1

    /// Defaults to the real per-user Application Support directory; tests
    /// inject a temporary directory so this store never touches
    /// `~/Library/Application Support`.
    let baseDirectory: URL

    init(baseDirectory: URL = UserEntryStore.defaultBaseDirectory) {
        self.baseDirectory = baseDirectory
    }

    static var defaultBaseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Rafu", directoryHint: .isDirectory)
    }

    private var fileURL: URL {
        baseDirectory.appending(path: "language-servers.json")
    }

    /// Every user-added descriptor currently on disk, or `[]` if the file
    /// doesn't exist yet — a fresh install has no user entries, not an
    /// error.
    @concurrent
    func load() async throws -> [ServerDescriptor] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let file = try JSONDecoder().decode(UserEntriesFile.self, from: data)
        return file.servers
    }

    /// Overwrites the entire user-entries file atomically, after validating
    /// every descriptor's source URL. Creates `baseDirectory` first.
    @concurrent
    func save(_ servers: [ServerDescriptor]) async throws {
        for descriptor in servers {
            try Self.validateUserURL(descriptor)
        }
        try FileManager.default.createDirectory(
            at: baseDirectory, withIntermediateDirectories: true)
        let file = UserEntriesFile(schemaVersion: Self.currentSchemaVersion, servers: servers)
        let data = try JSONEncoder().encode(file)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Adds `descriptor`, replacing any existing entry with the same `id`.
    @concurrent
    func add(_ descriptor: ServerDescriptor) async throws {
        try Self.validateUserURL(descriptor)
        var servers = try await load()
        servers.removeAll { $0.id == descriptor.id }
        servers.append(descriptor)
        try await save(servers)
    }

    /// Removes the entry with the given `id`, if any. Unknown ids are a
    /// no-op.
    @concurrent
    func remove(id: String) async throws {
        var servers = try await load()
        servers.removeAll { $0.id == id }
        try await save(servers)
    }

    /// A user-supplied descriptor may only reference an `https` download
    /// asset or an explicit local `file://` binary the user already has —
    /// never any other scheme, and never a value later interpolated into a
    /// shell command (every downstream consumer spawns via argv arrays
    /// only). `.localDiscovery` descriptors have no source and are always
    /// valid here.
    static func validateUserURL(_ descriptor: ServerDescriptor) throws {
        guard let source = descriptor.source else { return }
        guard source.url.scheme == "https" || source.url.isFileURL else {
            throw UserEntryStoreError.insecureSourceURL(id: descriptor.id)
        }
    }
}
