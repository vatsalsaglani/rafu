import Foundation

/// The C3 `LanguageServerResolving` conformer: resolves a languageID to an
/// installed, on-disk, and workspace-trusted server descriptor. Built here
/// but **not** wired into `LanguageIntelligenceCoordinator`/
/// `LanguageServerManager` this increment — see the C4 wiring note on
/// `LanguageServerManager`'s doc comment location, or the phase brief.
/// `resolve(languageID:)` never throws: every failure mode (not installed,
/// not trusted, missing Node runtime, no discovered local toolchain) is a
/// silent decline, exactly like `NoLanguageServersResolver`.
nonisolated struct InstalledServerResolver: LanguageServerResolving {
    private let catalog: [ServerDescriptor]
    private let userEntries: [ServerDescriptor]
    private let layout: InstallLayout

    /// The pinned Node executable, when `NodeRuntimeManager.ensureInstalled()`
    /// has completed. `nil` declines every `.nodeHosted` descriptor.
    private let nodeExecutableURL: URL?

    /// A discovered `gopls` executable (see `discoverGopls()`), or `nil` to
    /// decline `gopls` resolution.
    private let goplsExecutableURL: URL?

    /// A discovered Xcode-toolchain `sourcekit-lsp` executable (see
    /// `discoverSourceKitLSP()`), or `nil` to decline `sourcekit-lsp`
    /// resolution.
    private let sourceKitLSPExecutableURL: URL?

    private let isTrusted: @Sendable (String) -> Bool

    /// - Parameters:
    ///   - catalog: Defaults to `CuratedCatalog.servers`.
    ///   - userEntries: A workspace's user-added descriptors (from
    ///     `UserEntryStore.load()`), searched before `catalog` so a user
    ///     entry can override a curated one with the same languageID.
    ///   - goplsExecutableURL/sourceKitLSPExecutableURL: Deliberately
    ///     default to `nil` rather than eagerly invoking
    ///     `discoverGopls()`/`discoverSourceKitLSP()` — local-toolchain
    ///     discovery spawns a real process and depends on the host
    ///     machine's installed tooling, so a caller (production C4 wiring)
    ///     must opt in explicitly rather than have every default-constructed
    ///     resolver (including in tests) trigger it implicitly.
    init(
        catalog: [ServerDescriptor] = CuratedCatalog.servers,
        userEntries: [ServerDescriptor] = [],
        layout: InstallLayout = InstallLayout(),
        nodeExecutableURL: URL? = nil,
        goplsExecutableURL: URL? = nil,
        sourceKitLSPExecutableURL: URL? = nil,
        isTrusted: @escaping @Sendable (String) -> Bool
    ) {
        self.catalog = catalog
        self.userEntries = userEntries
        self.layout = layout
        self.nodeExecutableURL = nodeExecutableURL
        self.goplsExecutableURL = goplsExecutableURL
        self.sourceKitLSPExecutableURL = sourceKitLSPExecutableURL
        self.isTrusted = isTrusted
    }

    func resolve(languageID: String) -> ResolvedLanguageServer? {
        let descriptors = userEntries + catalog
        guard let descriptor = descriptors.first(where: { $0.languageIDs.contains(languageID) })
        else {
            return nil
        }
        guard isTrusted(descriptor.id) else { return nil }
        guard let launch = launchSpecification(for: descriptor) else { return nil }

        return ResolvedLanguageServer(
            serverName: descriptor.displayName,
            launch: launch,
            initializationOptions: descriptor.initializationOptions,
            rssCeilingBytes: nil
        )
    }

    private func launchSpecification(
        for descriptor: ServerDescriptor
    ) -> LanguageServerLaunchSpecification? {
        switch descriptor.kind {
        case .localDiscovery:
            guard let executableURL = discoveredExecutable(forID: descriptor.id) else {
                return nil
            }
            return LanguageServerLaunchSpecification(
                executableURL: executableURL,
                arguments: descriptor.launchArguments,
                environment: nil,
                currentDirectoryURL: nil
            )

        case .singleBinary:
            guard let archive = descriptor.archive else { return nil }
            let binaryURL = layout.serverDirectory(id: descriptor.id).appending(
                path: archive.binaryRelativePath)
            guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else { return nil }
            return LanguageServerLaunchSpecification(
                executableURL: binaryURL,
                arguments: descriptor.launchArguments,
                environment: nil,
                currentDirectoryURL: nil
            )

        case .nodeHosted:
            guard let archive = descriptor.archive, let nodeExecutableURL else { return nil }
            let entryURL = layout.serverDirectory(id: descriptor.id).appending(
                path: archive.binaryRelativePath)
            guard FileManager.default.fileExists(atPath: entryURL.path) else { return nil }
            return LanguageServerLaunchSpecification(
                executableURL: nodeExecutableURL,
                arguments: [entryURL.path] + descriptor.launchArguments,
                environment: nil,
                currentDirectoryURL: nil
            )
        }
    }

    private func discoveredExecutable(forID id: String) -> URL? {
        switch id {
        case "gopls": return goplsExecutableURL
        case "sourcekit-lsp": return sourceKitLSPExecutableURL
        default: return nil
        }
    }
}

extension InstalledServerResolver {
    /// Searches `$PATH`, then `$GOPATH/bin` (falling back to `~/go/bin`
    /// when `$GOPATH` is unset, matching `go env GOPATH`'s own default),
    /// for an executable named `gopls`. Discovery only — this never runs
    /// `go install`. A future increment may offer
    /// `go install golang.org/x/tools/gopls@latest` as an explicit,
    /// user-initiated action from a settings row, but that is out of scope
    /// here.
    static func discoverGopls(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        let pathDirectories =
            (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)) }
        let goDirectory: URL =
            if let gopath = environment["GOPATH"], !gopath.isEmpty {
                URL(fileURLWithPath: gopath).appending(path: "bin")
            } else {
                fileManager.homeDirectoryForCurrentUser.appending(path: "go/bin")
            }

        for directory in pathDirectories + [goDirectory] {
            let candidate = directory.appending(path: "gopls")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Runs `/usr/bin/xcrun --find sourcekit-lsp` — a fixed executable and
    /// argument array, never a shell string — to locate the active Xcode
    /// toolchain's bundled `sourcekit-lsp`. `nil` when no Xcode toolchain
    /// is selected (only Command Line Tools installed, or `xcrun` can't
    /// find it) rather than throwing: a missing Xcode toolchain is a
    /// normal, expected decline.
    static func discoverSourceKitLSP(fileManager: FileManager = .default) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "sourcekit-lsp"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, fileManager.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
