import Darwin
import Foundation
import RafuCore

/// One located CLI executable.
nonisolated struct MeetingAgentExecutable: Sendable, Equatable {
    /// The path that Rafu starts (it can be a symbolic link).
    var url: URL
    /// The real file behind `url`, and its modification date: the key of
    /// the Codex version cache.
    var resolvedPath: String
    var modified: Date?
}

/// Finds a CLI for the hidden meeting agent. Tests inject a fake.
nonisolated protocol MeetingAgentLocating: Sendable {
    func locate(_ cli: MeetingAgentCLI) -> MeetingAgentExecutable?
}

/// Finds `claude` and `codex` as an absolute, executable, regular file in
/// the directories of `RafuConductorEnvironment.curatedPath`, in order. No
/// shell and no `which`; the user's shell `PATH` is never read. A CLI in
/// another directory is "not installed" for the hidden meeting agent.
nonisolated struct MeetingAgentExecutableLocator: MeetingAgentLocating {
    let directories: [String]

    init(directories: [String] = Self.curatedDirectories) {
        self.directories = directories
    }

    static var curatedDirectories: [String] {
        RafuConductorEnvironment.curatedPath.split(separator: ":").map(String.init)
    }

    static func executableName(for cli: MeetingAgentCLI) -> String {
        switch cli {
        case .claudeCode: "claude"
        case .codex: "codex"
        }
    }

    func locate(_ cli: MeetingAgentCLI) -> MeetingAgentExecutable? {
        let name = Self.executableName(for: cli)
        for directory in directories where directory.hasPrefix("/") {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
            let resolved = url.resolvingSymlinksInPath()
            var info = stat()
            guard lstat(resolved.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                FileManager.default.isExecutableFile(atPath: resolved.path)
            else { continue }
            let modified = Date(
                timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                    + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            return MeetingAgentExecutable(
                url: url, resolvedPath: resolved.path, modified: modified)
        }
        return nil
    }
}

/// The environment of each hidden agent run: exactly `PATH` (the curated
/// path), `HOME`, `USER` and `LOGNAME`. `Process.environment` replaces the
/// parent environment, so no Rafu-held key and no `RAFU_*` value reaches
/// the CLI.
nonisolated enum MeetingAgentEnvironment {
    static let keys: Set<String> = ["PATH", "HOME", "USER", "LOGNAME"]

    static func make(
        path: String = RafuConductorEnvironment.curatedPath,
        home: String = NSHomeDirectory(),
        user: String = NSUserName()
    ) -> [String: String] {
        ["PATH": path, "HOME": home, "USER": user, "LOGNAME": user]
    }
}

/// The private folders of Codex runs: `<runs>/<UUID>/e`, each 0700. `e` is
/// `<E>` of the limits note: new and empty, and Rafu never writes a file
/// into it (Codex applies an `AGENTS.md` that it finds there).
nonisolated enum MeetingAgentRunFolders {
    struct Run: Sendable, Equatable {
        var root: URL
        var emptyFolder: URL
    }

    enum Problem: Error {
        case notPrivate
    }

    /// `MeetingAgentRuns-<variant>` in the user's temporary folder. Rafu and
    /// Rafu Lightning share that folder, so each variant has its own root
    /// and removes only its own folders.
    static var defaultRunsRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                variantFolderName("MeetingAgentRuns", identity: .current), isDirectory: true)
    }

    /// `MeetingAgentSnapshots-<variant>`: the snapshot root of the app's store.
    static var defaultSnapshotRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                variantFolderName("MeetingAgentSnapshots", identity: .current), isDirectory: true)
    }

    /// For example `MeetingAgentRuns-RafuLightning`.
    nonisolated static func variantFolderName(_ stem: String, identity: RafuAppIdentity) -> String {
        "\(stem)-\(identity.executableName)"
    }

    /// Removes each folder inside `root` (one variant's runs or snapshots).
    /// Used at start and at quit: no run of this variant lives across a
    /// launch. `root` itself stays.
    static func removeAll(in root: URL) {
        removeStale(in: root, olderThan: -1)
    }

    static func make(in runsRoot: URL) throws -> Run {
        try makePrivateDirectory(runsRoot, mayExist: true)
        let root = runsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try makePrivateDirectory(root, mayExist: false)
        let emptyFolder = root.appendingPathComponent("e", isDirectory: true)
        do {
            try makePrivateDirectory(emptyFolder, mayExist: false)
            guard try FileManager.default.contentsOfDirectory(atPath: emptyFolder.path).isEmpty
            else { throw Problem.notPrivate }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        return Run(root: root, emptyFolder: emptyFolder)
    }

    /// Removes run roots older than `age` seconds, left by a crash.
    static func removeStale(in runsRoot: URL, olderThan age: TimeInterval, now: Date = Date()) {
        guard isRealDirectory(runsRoot),
            let names = try? FileManager.default.contentsOfDirectory(atPath: runsRoot.path)
        else { return }
        let cutoff = now.addingTimeInterval(-age)
        for name in names {
            let url = runsRoot.appendingPathComponent(name, isDirectory: true)
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
            if modified < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// A real directory (not a symbolic link) owned by this user, mode 0700.
    private static func makePrivateDirectory(_ url: URL, mayExist: Bool) throws {
        if mkdir(url.path, 0o700) != 0 {
            guard errno == EEXIST, mayExist else { throw Problem.notPrivate }
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
            info.st_uid == getuid()
        else { throw Problem.notPrivate }
        guard chmod(url.path, 0o700) == 0 else { throw Problem.notPrivate }
    }
}
