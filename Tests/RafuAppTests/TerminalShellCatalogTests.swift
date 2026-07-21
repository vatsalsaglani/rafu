import Foundation
import Testing

@testable import RafuApp

/// Terminal-manager.md T-C: `TerminalShellCatalog` discovers shell binaries
/// without ever executing anything (AGENTS: no execution-based probing),
/// and `PreferredShellStore` remembers the last-chosen one. All isolation
/// is `nonisolated`/pure — no `@MainActor` needed here.
@Suite("TerminalShellCatalog")
struct TerminalShellCatalogTests {

    // MARK: - C1: /etc/shells parsing

    @Test("parseEtcShells drops comments, blanks, relative paths, and malformed lines")
    func parseEtcShellsDropsNoise() {
        let contents = """
            # /etc/shells: valid login shells
            /bin/bash
            /bin/zsh   # the default on macOS
            relative/path/not/absolute
            \u{201C}/usr/local/bin/fish\u{201D}

            /bin/sh
            """
        let parsed = TerminalShellCatalog.parseEtcShells(contents)
        #expect(parsed == ["/bin/bash", "/bin/zsh", "/bin/sh"])
    }

    // MARK: - C2: unreadable file

    @Test("An unreadable /etc/shells yields exactly the default entry")
    func unreadableEtcShellsYieldsOnlyDefault() {
        let catalog = TerminalShellCatalog(
            etcShellsPath: "/nonexistent/etc/shells",
            extraProbePaths: [],
            defaultShellPath: "/bin/zsh",
            readFile: { _ in nil },
            isExecutable: { _ in false }
        )

        let shells = catalog.shells()

        #expect(shells.count == 1)
        #expect(shells.first?.path == "/bin/zsh")
        #expect(shells.first?.isDefault == true)
        #expect(shells.first?.name == "Default (zsh)")
    }

    // MARK: - C3: executability filter

    @Test("A non-default candidate that fails the executability check is dropped")
    func nonDefaultCandidateFailingExecutabilityCheckIsDropped() {
        let catalog = TerminalShellCatalog(
            etcShellsPath: "/etc/shells",
            extraProbePaths: [],
            defaultShellPath: "/bin/zsh",
            readFile: { _ in "/bin/zsh\n/bin/bash\n" },
            isExecutable: { $0 == "/bin/zsh" }
        )

        let shells = catalog.shells()

        #expect(shells.map(\.path) == ["/bin/zsh"])
    }

    @Test("The real FileManager.isExecutableFile seam is honest against a temp directory")
    func realExecutabilitySeamIsHonest() async throws {
        try await withTemporaryDirectory { directory in
            let executablePath = directory.appending(path: "my-shell").path
            let nonExecutablePath = directory.appending(path: "not-a-shell").path
            FileManager.default.createFile(atPath: executablePath, contents: Data())
            FileManager.default.createFile(atPath: nonExecutablePath, contents: Data())
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executablePath)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: nonExecutablePath)

            let catalog = TerminalShellCatalog(
                etcShellsPath: "/nonexistent/etc/shells",
                extraProbePaths: [executablePath, nonExecutablePath],
                defaultShellPath: "/bin/zsh",
                readFile: { _ in nil }
            )

            let shells = catalog.shells()

            #expect(shells.map(\.path) == ["/bin/zsh", executablePath])
        }
    }

    // MARK: - C4: dedupe/order

    @Test("Order is default, then /etc/shells, then probes; dupes and repeated basenames drop")
    func dedupeAndOrderMatchesCandidateSequence() {
        let catalog = TerminalShellCatalog(
            etcShellsPath: "/etc/shells",
            extraProbePaths: ["/opt/homebrew/bin/fish", "/usr/bin/zsh"],
            defaultShellPath: "/bin/zsh",
            readFile: { _ in "/bin/zsh\n/bin/bash\n/bin/zsh\n" },
            isExecutable: { _ in true }
        )

        let shells = catalog.shells()

        // /bin/zsh (default) first; /bin/bash from /etc/shells; the
        // duplicate /bin/zsh line dropped; the homebrew fish probe kept;
        // /usr/bin/zsh dropped — same basename ("zsh") already seen.
        #expect(shells.map(\.path) == ["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/fish"])
        #expect(shells.first?.isDefault == true)
        #expect(shells.dropFirst().allSatisfy { !$0.isDefault })
    }

    // MARK: - C5: Homebrew probes

    @Test("A Homebrew-only fish is discovered when /etc/shells has nothing")
    func homebrewOnlyShellIsDiscoveredViaProbe() {
        let catalog = TerminalShellCatalog(
            etcShellsPath: "/etc/shells",
            extraProbePaths: TerminalShellCatalog.homebrewProbePaths,
            defaultShellPath: "/bin/zsh",
            readFile: { _ in "" },
            isExecutable: { $0 == "/opt/homebrew/bin/fish" }
        )

        let shells = catalog.shells()

        #expect(shells.map(\.path) == ["/bin/zsh", "/opt/homebrew/bin/fish"])
    }

    @Test("homebrewProbePaths covers both the Apple Silicon and Intel prefixes")
    func homebrewProbePathsCoversBothPrefixes() {
        let paths = TerminalShellCatalog.homebrewProbePaths
        #expect(paths.contains { $0.hasPrefix("/opt/homebrew/bin/") })
        #expect(paths.contains { $0.hasPrefix("/usr/local/bin/") })
    }

    // MARK: - C6: login-argument table

    @Test("Login-shell argv table: known login shells get -l, others get none")
    func loginArgumentsTable() {
        for basename in ["zsh", "bash", "sh", "ksh", "fish", "tcsh", "csh"] {
            #expect(TerminalShellCatalog.loginArguments(forBasename: basename) == ["-l"])
        }
        for basename in ["nu", "xonsh", "elvish", "dash", "some-unknown-shell"] {
            #expect(TerminalShellCatalog.loginArguments(forBasename: basename) == [])
        }
    }

    @Test("TerminalShell.loginArguments/basename derive from the path, not a real spawn")
    func terminalShellDerivesLoginArgumentsAndBasenameFromPath() {
        // nu has no login-shell flag (per the login-argument table).
        let nu = TerminalShell(path: "/opt/homebrew/bin/nu", name: "nu", isDefault: false)
        #expect(nu.basename == "nu")
        #expect(nu.loginArguments == [])

        let zsh = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
        #expect(zsh.basename == "zsh")
        #expect(zsh.loginArguments == ["-l"])
    }

    // MARK: - C9: environmentShellPath

    @Test("A custom defaultShellPath is honored without touching the real environment")
    func customDefaultShellPathIsHonored() {
        let catalog = TerminalShellCatalog(
            etcShellsPath: "/nonexistent/etc/shells",
            extraProbePaths: [],
            defaultShellPath: "/opt/homebrew/bin/fish",
            readFile: { _ in nil },
            isExecutable: { _ in false }
        )

        let shells = catalog.shells()

        #expect(shells.map(\.path) == ["/opt/homebrew/bin/fish"])
        #expect(shells.first?.name == "Default (fish)")
    }

    // MARK: - C7/C8: PreferredShellStore

    /// Every test below uses a unique suite name, never `UserDefaults.standard`
    /// — required for parallel/serial parity and to keep the suite from
    /// polluting real prefs (see `WorkspaceSearchHistoryStore`'s tests for
    /// the same pattern).
    @Test("PreferredShellStore round-trips a recorded shell against an injected suite")
    func preferredShellStoreRoundTrips() {
        let suiteName = "TerminalShellCatalogTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let store = PreferredShellStore(suiteName: suiteName)
        let fish = TerminalShell(path: "/opt/homebrew/bin/fish", name: "fish", isDefault: false)
        let zsh = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)

        store.record(fish)

        #expect(store.resolved(in: [zsh, fish])?.path == fish.path)
    }

    @Test("A stale preferred shell resolves to nil and clears the stored value")
    func stalePreferredShellResolvesToNilAndClears() throws {
        let suiteName = "TerminalShellCatalogTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferredShellStore(suiteName: suiteName)
        let uninstalled = TerminalShell(path: "/opt/homebrew/bin/nu", name: "nu", isDefault: false)
        let zsh = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
        store.record(uninstalled)

        let resolved = store.resolved(in: [zsh])

        #expect(resolved == nil)
        #expect(defaults.string(forKey: PreferredShellStore.defaultsKey) == nil)
    }

    @Test("No stored preference resolves to nil without touching the store")
    func noStoredPreferenceResolvesToNil() {
        let suiteName = "TerminalShellCatalogTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let store = PreferredShellStore(suiteName: suiteName)
        let zsh = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)

        #expect(store.resolved(in: [zsh]) == nil)
    }
}
