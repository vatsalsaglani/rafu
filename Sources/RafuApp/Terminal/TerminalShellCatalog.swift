import Foundation

/// One shell binary discoverable on this machine, used to spawn a
/// `WorkspaceTerminalController`'s login shell (terminal-manager.md T-C).
/// Pure data — never spawns or probes by executing anything; only checks
/// existence/executability (AGENTS: no execution-based probing).
nonisolated struct TerminalShell: Equatable, Identifiable, Sendable {
    var id: String { path }
    let path: String
    /// "Default (\(basename))" for the `$SHELL` entry, bare basename for
    /// everything else discovered.
    let name: String
    let isDefault: Bool

    var basename: String { (path as NSString).lastPathComponent }

    /// Argv beyond the executable itself — `["-l"]` for known login-capable
    /// shells, `[]` otherwise. See `TerminalShellCatalog.loginArguments`.
    var loginArguments: [String] {
        TerminalShellCatalog.loginArguments(forBasename: basename)
    }
}

/// Discovers shell binaries available on this machine: the user's `$SHELL`
/// (always first, always kept even when it fails the executability check —
/// otherwise the catalog could be empty), everything listed in
/// `/etc/shells`, and a short list of well-known Homebrew install paths that
/// setups often never add to `/etc/shells`. Every dependency is injectable
/// so tests never touch the real filesystem or environment.
nonisolated struct TerminalShellCatalog: Sendable {
    /// Homebrew installs shells outside `/etc/shells` at these well-known
    /// paths on both Apple Silicon (`/opt/homebrew`) and Intel
    /// (`/usr/local`) prefixes.
    static let homebrewProbePaths: [String] = {
        let names = ["fish", "nu", "bash", "zsh", "elvish", "xonsh"]
        return names.map { "/opt/homebrew/bin/\($0)" } + names.map { "/usr/local/bin/\($0)" }
    }()

    private let etcShellsPath: String
    private let extraProbePaths: [String]
    private let defaultShellPath: String
    private let readFile: @Sendable (String) -> String?
    private let isExecutable: @Sendable (String) -> Bool

    init(
        etcShellsPath: String = "/etc/shells",
        extraProbePaths: [String] = TerminalShellCatalog.homebrewProbePaths,
        defaultShellPath: String = TerminalShellCatalog.environmentShellPath(),
        readFile: @escaping @Sendable (String) -> String? = {
            try? String(contentsOfFile: $0, encoding: .utf8)
        },
        isExecutable: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) {
        self.etcShellsPath = etcShellsPath
        self.extraProbePaths = extraProbePaths
        self.defaultShellPath = defaultShellPath
        self.readFile = readFile
        self.isExecutable = isExecutable
    }

    /// Never empty: `defaultShellPath` is always included, always first, and
    /// exempt from the executability filter. Candidate order is
    /// `[default] + /etc/shells entries + probe paths`; deduped first by
    /// exact path, then by basename (keeping whichever came first), so a
    /// probe path that only re-discovers an already-listed shell is dropped
    /// rather than shown twice under a different path.
    func shells() -> [TerminalShell] {
        let etcShells = readFile(etcShellsPath).map(Self.parseEtcShells) ?? []
        let candidates = [defaultShellPath] + etcShells + extraProbePaths

        var result: [TerminalShell] = []
        var seenPaths = Set<String>()
        var seenBasenames = Set<String>()

        for path in candidates {
            guard !seenPaths.contains(path) else { continue }
            let basename = (path as NSString).lastPathComponent
            guard !seenBasenames.contains(basename) else { continue }
            let isDefaultEntry = path == defaultShellPath
            guard isDefaultEntry || isExecutable(path) else { continue }

            seenPaths.insert(path)
            seenBasenames.insert(basename)
            let name = isDefaultEntry ? "Default (\(basename))" : basename
            result.append(TerminalShell(path: path, name: name, isDefault: isDefaultEntry))
        }
        return result
    }

    /// Parses `/etc/shells`: one path per line, `#` starts a comment
    /// (whole-line or trailing), blank lines and non-absolute paths are
    /// dropped. Deliberately naive — no quoting/word-splitting — so a
    /// malformed line (observed in the wild: curly smart quotes around a
    /// path) is dropped rather than misparsed, since it no longer starts
    /// with `/` once trimmed.
    static func parseEtcShells(_ contents: String) -> [String] {
        contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var trimmed = line.trimmingCharacters(in: .whitespaces)
                if let hashIndex = trimmed.firstIndex(of: "#") {
                    trimmed = String(trimmed[trimmed.startIndex..<hashIndex])
                }
                return trimmed.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty && $0.hasPrefix("/") }
    }

    /// Login-shell flag table by basename. Allowlist direction is
    /// deliberate: an unknown shell given an unsupported `-l` may abort
    /// outright, while omitting it only means "not started as a login
    /// shell" — argv[0] already carries the leading `-` that signals login
    /// mode to shells that recognize it that way.
    static func loginArguments(forBasename basename: String) -> [String] {
        let loginCapableShells: Set<String> = ["zsh", "bash", "sh", "ksh", "fish", "tcsh", "csh"]
        return loginCapableShells.contains(basename) ? ["-l"] : []
    }

    /// `$SHELL`, or `/bin/zsh` when it is unset/empty.
    static func environmentShellPath() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        return shell.isEmpty ? "/bin/zsh" : shell
    }
}
