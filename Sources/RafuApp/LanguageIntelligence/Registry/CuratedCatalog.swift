import Foundation

/// Why `CuratedCatalog.validate()` rejected the catalog it was given.
/// Never thrown for a healthy build — a hand-authored catalog failing its
/// own validation is a programmer error caught at test time, not a runtime
/// condition an end user can hit.
nonisolated enum CuratedCatalogError: Error, Equatable {
    case nonHTTPSSource(id: String)
    case missingPinnedVersion(id: String)
    case duplicateID(String)
    case emptyLanguageIDs(id: String)
    case localDiscoveryMustHaveNoSource(id: String)
    case nonLocalDiscoveryRequiresSource(id: String)
    case nodeHostedMissingManagedRuntimePrerequisite(id: String)
    case sourceKitLSPMissingXcodeToolchainPrerequisite
}

/// The built-in, hand-curated language server catalog. Every non-discovery
/// entry names an exact `https` source, a pinned version, and a license;
/// `ServerInstaller`/`NodeRuntimeManager` never fetch anything this catalog
/// doesn't name.
///
/// Versions and asset-name conventions below reflect each project's real
/// release layout at the time this catalog was written, but this
/// environment has no live network access to re-confirm them. Every
/// version, checksum, and asset URL here must be re-verified against the
/// upstream project's current release before this catalog ships.
nonisolated enum CuratedCatalog {
    static let servers: [ServerDescriptor] = [
        rustAnalyzer, clangd, marksman, gopls, sourceKitLSP, typeScriptLanguageServer, pyright,
    ]

    /// Validates `CuratedCatalog.servers`. Called from a test rather than
    /// at runtime — the production catalog is a static literal, so this
    /// only ever needs to run once per build.
    static func validate() throws {
        try validate(servers)
    }

    /// The reusable validator, exposed so tests can also drive it against
    /// deliberately broken fixture lists (non-`https` source, missing
    /// version, duplicate id) without touching the real catalog.
    static func validate(_ descriptors: [ServerDescriptor]) throws {
        var seenIDs = Set<String>()
        for descriptor in descriptors {
            guard seenIDs.insert(descriptor.id).inserted else {
                throw CuratedCatalogError.duplicateID(descriptor.id)
            }
            guard !descriptor.languageIDs.isEmpty else {
                throw CuratedCatalogError.emptyLanguageIDs(id: descriptor.id)
            }

            switch descriptor.kind {
            case .localDiscovery:
                guard descriptor.source == nil else {
                    throw CuratedCatalogError.localDiscoveryMustHaveNoSource(id: descriptor.id)
                }
            case .singleBinary, .nodeHosted:
                guard let source = descriptor.source else {
                    throw CuratedCatalogError.nonLocalDiscoveryRequiresSource(id: descriptor.id)
                }
                guard source.url.scheme == "https" else {
                    throw CuratedCatalogError.nonHTTPSSource(id: descriptor.id)
                }
                guard !source.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw CuratedCatalogError.missingPinnedVersion(id: descriptor.id)
                }
            }

            if descriptor.kind == .nodeHosted {
                guard descriptor.prerequisites.contains(.managedNodeRuntime) else {
                    throw CuratedCatalogError.nodeHostedMissingManagedRuntimePrerequisite(
                        id: descriptor.id)
                }
            }

            if descriptor.id == "sourcekit-lsp" {
                guard descriptor.prerequisites.contains(.xcodeToolchain) else {
                    throw CuratedCatalogError.sourceKitLSPMissingXcodeToolchainPrerequisite
                }
            }
        }
    }

    // MARK: - Entries

    private static let rustAnalyzer = ServerDescriptor(
        id: "rust-analyzer",
        languageIDs: ["rust"],
        displayName: "rust-analyzer",
        kind: .singleBinary,
        source: ServerSource(
            url: URL(
                string:
                    "https://github.com/rust-lang/rust-analyzer/releases/download/2024-01-01/rust-analyzer-aarch64-apple-darwin.gz"
            )!,
            version: "2024-01-01",
            checksum: nil,
            license: "MIT OR Apache-2.0",
            estimatedBytes: 50_000_000
        ),
        launchArguments: [],
        archive: ArchiveLayout(format: .gzip, binaryRelativePath: "rust-analyzer"),
        initializationOptions: nil,
        prerequisites: []
    )

    private static let clangd = ServerDescriptor(
        id: "clangd",
        languageIDs: ["c", "cpp"],
        displayName: "clangd",
        kind: .singleBinary,
        source: ServerSource(
            url: URL(
                string:
                    "https://github.com/clangd/clangd/releases/download/18.1.3/clangd-mac-18.1.3.zip"
            )!,
            version: "18.1.3",
            checksum: nil,
            license: "Apache-2.0 WITH LLVM-exception",
            estimatedBytes: 180_000_000
        ),
        launchArguments: [],
        archive: ArchiveLayout(format: .zip, binaryRelativePath: "clangd_18.1.3/bin/clangd"),
        initializationOptions: nil,
        prerequisites: []
    )

    // marksman's license must be re-confirmed against the project's current
    // `LICENSE` file before shipping (GPL-3.0-only at the time this catalog
    // was written).
    private static let marksman = ServerDescriptor(
        id: "marksman",
        languageIDs: ["markdown"],
        displayName: "Marksman",
        kind: .singleBinary,
        source: ServerSource(
            url: URL(
                string:
                    "https://github.com/artempyanykh/marksman/releases/download/2024-01-11/marksman-macos"
            )!,
            version: "2024-01-11",
            checksum: nil,
            license: "GPL-3.0-only",
            estimatedBytes: 60_000_000
        ),
        launchArguments: ["server"],
        archive: ArchiveLayout(format: .rawBinary, binaryRelativePath: "marksman"),
        initializationOptions: nil,
        prerequisites: []
    )

    // Coordinator decision: gopls is `.localDiscovery`, never a fabricated
    // download URL. `InstalledServerResolver.discoverGopls()` looks for an
    // existing `gopls` on `PATH` or under `$GOPATH/bin`
    // (`~/go/bin` when `$GOPATH` is unset). A future increment could offer
    // `go install golang.org/x/tools/gopls@latest` as an explicit,
    // user-initiated action, but C3 never invokes `go install` itself.
    private static let gopls = ServerDescriptor(
        id: "gopls",
        languageIDs: ["go"],
        displayName: "gopls",
        kind: .localDiscovery,
        source: nil,
        launchArguments: [],
        archive: nil,
        initializationOptions: nil,
        prerequisites: [
            .note("Requires a Go toolchain: gopls found on PATH or under $GOPATH/bin.")
        ]
    )

    private static let sourceKitLSP = ServerDescriptor(
        id: "sourcekit-lsp",
        languageIDs: ["swift"],
        displayName: "SourceKit-LSP",
        kind: .localDiscovery,
        source: nil,
        launchArguments: [],
        archive: nil,
        initializationOptions: nil,
        prerequisites: [.xcodeToolchain]
    )

    // Coordinator decision: this descriptor documents that a bare `.tgz`
    // unpack is NOT sufficient to run typescript-language-server — it also
    // needs `typescript` and its other npm dependencies resolved, which is
    // deferred. Do not treat a successful install as a runnable server.
    private static let typeScriptLanguageServer = ServerDescriptor(
        id: "typescript-language-server",
        languageIDs: ["typescript", "typescriptreact", "javascript", "javascriptreact"],
        displayName: "typescript-language-server",
        kind: .nodeHosted,
        source: ServerSource(
            url: URL(
                string:
                    "https://registry.npmjs.org/typescript-language-server/-/typescript-language-server-4.3.3.tgz"
            )!,
            version: "4.3.3",
            checksum: nil,
            license: "Apache-2.0",
            estimatedBytes: 2_000_000
        ),
        launchArguments: ["--stdio"],
        archive: ArchiveLayout(format: .tarGzip, binaryRelativePath: "package/lib/cli.mjs"),
        initializationOptions: nil,
        prerequisites: [
            .managedNodeRuntime,
            .note(
                "Unpacking this release tarball alone is not enough to run the server: it "
                    + "additionally depends on `typescript` and other npm packages that are not "
                    + "resolved by a bare `.tgz` extraction. Full npm dependency installation is "
                    + "deferred to a later increment."
            ),
        ]
    )

    // Pyright is the validated nodeHosted example: its published tarball is
    // a self-contained bundle and is fully runnable after unpack + the
    // managed Node runtime, unlike typescript-language-server above.
    private static let pyright = ServerDescriptor(
        id: "pyright",
        languageIDs: ["python"],
        displayName: "Pyright",
        kind: .nodeHosted,
        source: ServerSource(
            url: URL(string: "https://registry.npmjs.org/pyright/-/pyright-1.1.377.tgz")!,
            version: "1.1.377",
            checksum: nil,
            license: "MIT",
            estimatedBytes: 10_000_000
        ),
        launchArguments: ["--stdio"],
        archive: ArchiveLayout(
            format: .tarGzip, binaryRelativePath: "package/dist/pyright-langserver.js"),
        initializationOptions: nil,
        prerequisites: [.managedNodeRuntime]
    )
}
