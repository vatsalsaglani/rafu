import Foundation

@testable import RafuApp

/// A fixture `AssetDownloading` that copies a pre-built local file instead
/// of ever touching the network, so `ServerInstaller`/`NodeRuntimeManager`
/// tests are fully offline and deterministic. `downloadCount` lets
/// idempotency tests (e.g. `NodeRuntimeManager.ensureInstalled()` on an
/// already-installed runtime) assert that no re-download happened.
actor FixtureAssetDownloader: AssetDownloading {
    private let fixtureURL: URL
    private(set) var downloadCount = 0

    init(fixtureURL: URL) {
        self.fixtureURL = fixtureURL
    }

    func download(from url: URL) async throws -> URL {
        downloadCount += 1
        let destination = FileManager.default.temporaryDirectory.appending(
            path: "rafu-lsp-test-download-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixtureURL, to: destination)
        return destination
    }
}

/// A one-shot latch that lets a test hold an install mid-flight so a
/// transient in-progress state (`row.progressActive == true`) is
/// deterministically observable instead of racing a near-instant fixture
/// install. `wait()` suspends until `release()`; a `release()` that arrives
/// before any `wait()` is remembered, so a later `wait()` returns at once.
actor DownloadGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

/// A `FixtureAssetDownloader` variant whose `download(from:)` suspends on a
/// `DownloadGate` before copying, so a test can observe an install's
/// in-progress state before letting it complete. Removes the timing race in
/// which a fixture install finishes before the test reads `progressActive`.
actor GatedFixtureDownloader: AssetDownloading {
    private let fixtureURL: URL
    private let gate: DownloadGate

    init(fixtureURL: URL, gate: DownloadGate) {
        self.fixtureURL = fixtureURL
        self.gate = gate
    }

    func download(from url: URL) async throws -> URL {
        await gate.wait()
        let destination = FileManager.default.temporaryDirectory.appending(
            path: "rafu-lsp-test-download-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixtureURL, to: destination)
        return destination
    }
}

/// Builds small, real archive fixtures (`.gz`, `.zip`, `.tar.gz`) using the
/// same system tools (`/usr/bin/gzip`, `/usr/bin/ditto`, `/usr/bin/tar`)
/// `ServerInstaller` unpacks with, entirely inside a caller-supplied
/// temporary directory. Never touches the network.
enum ArchiveFixtureBuilder {
    /// Gzips `contents` under `binaryName`, returning the path to the
    /// resulting `<binaryName>.gz`.
    static func makeGzip(binaryName: String, contents: Data, in directory: URL) throws -> URL {
        let source = directory.appending(path: binaryName)
        try contents.write(to: source)
        try run("/usr/bin/gzip", ["-f", source.path])
        return directory.appending(path: "\(binaryName).gz")
    }

    /// Builds a zip archive at `<directory>/asset.zip` containing exactly
    /// `relativePath` with `contents`, nested under any declared
    /// subdirectories.
    static func makeZip(relativePath: String, contents: Data, in directory: URL) throws -> URL {
        let sourceRoot = directory.appending(path: "zip-source", directoryHint: .isDirectory)
        let entryURL = sourceRoot.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: entryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: entryURL)

        let zipURL = directory.appending(path: "asset.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", sourceRoot.path, zipURL.path])
        return zipURL
    }

    /// Builds a `.tar.gz` archive at `<directory>/asset.tar.gz` containing
    /// exactly `relativePath` with `contents`.
    static func makeTarGzip(relativePath: String, contents: Data, in directory: URL) throws -> URL {
        let sourceRoot = directory.appending(path: "tar-source", directoryHint: .isDirectory)
        let entryURL = sourceRoot.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: entryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: entryURL)

        let tarURL = directory.appending(path: "asset.tar.gz")
        try run("/usr/bin/tar", ["-czf", tarURL.path, "-C", sourceRoot.path, "."])
        return tarURL
    }

    /// Builds a `.tar.gz` fixture whose only entry is a symlink escaping
    /// the eventual staging directory — the fixture `ServerInstallerTests`
    /// uses to prove `StagingValidator` rejects a zip-slip attempt.
    static func makeZipSlipTarGzip(escapingLinkName: String, in directory: URL) throws -> URL {
        let sourceRoot = directory.appending(
            path: "zip-slip-source", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let linkURL = sourceRoot.appending(path: escapingLinkName)
        try FileManager.default.createSymbolicLink(
            at: linkURL, withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))

        let tarURL = directory.appending(path: "zip-slip.tar.gz")
        try run("/usr/bin/tar", ["-czf", tarURL.path, "-C", sourceRoot.path, "."])
        return tarURL
    }

    /// Builds a `.tar.gz` fixture that mirrors the managed Node runtime's
    /// shape — a real binary at `package/bin/tool` plus an internal,
    /// cross-directory relative symlink `package/bin/alias -> ../lib/impl.js`
    /// resolving back inside the archive (as Node's `bin/npm`,`bin/npx`,
    /// `bin/corepack` do). `StagingValidator` must accept this while still
    /// rejecting the escaping `makeZipSlipTarGzip` fixture.
    static func makeInternalSymlinkTarGzip(binaryContents: Data, in directory: URL) throws -> URL {
        let sourceRoot = directory.appending(
            path: "internal-symlink-source", directoryHint: .isDirectory)
        let binURL = sourceRoot.appending(path: "package/bin/tool")
        let implURL = sourceRoot.appending(path: "package/lib/impl.js")
        try FileManager.default.createDirectory(
            at: binURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: implURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try binaryContents.write(to: binURL)
        try Data("module.exports = {}\n".utf8).write(to: implURL)
        // Path-based API so the destination stays a literal *relative* link
        // (`URL(fileURLWithPath:)` would resolve it against the CWD into an
        // absolute, escaping target — defeating the point of the fixture).
        try FileManager.default.createSymbolicLink(
            atPath: sourceRoot.appending(path: "package/bin/alias").path,
            withDestinationPath: "../lib/impl.js")

        let tarURL = directory.appending(path: "internal-symlink.tar.gz")
        try run("/usr/bin/tar", ["-czf", tarURL.path, "-C", sourceRoot.path, "."])
        return tarURL
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ArchiveFixtureBuilderError.toolFailed(executable: executable)
        }
    }
}

enum ArchiveFixtureBuilderError: Error {
    case toolFailed(executable: String)
}

/// A fake `NodeDependencyResolving` that never spawns real `npm`/`node`
/// processes: it records exactly what it was asked to resolve and, on
/// success, fabricates a small `node_modules/typescript/package.json` fixture
/// inside `packageDirectory` — enough to prove a real npm install's output
/// would survive `ServerInstaller`'s later atomic move. `failureStatus`, when
/// set, makes every call throw `ServerInstallError.dependencyResolutionFailed`
/// instead, mirroring a real `npm install` exiting non-zero.
actor FakeNodeDependencyResolver: NodeDependencyResolving {
    private(set) var invocationCount = 0
    private(set) var recordedPackageDirectory: URL?
    private(set) var recordedNodeExecutableURL: URL?
    private let failureStatus: Int32?

    init(failureStatus: Int32? = nil) {
        self.failureStatus = failureStatus
    }

    func installDependencies(packageDirectory: URL, nodeExecutableURL: URL) async throws {
        invocationCount += 1
        recordedPackageDirectory = packageDirectory
        recordedNodeExecutableURL = nodeExecutableURL

        if let failureStatus {
            throw ServerInstallError.dependencyResolutionFailed(failureStatus)
        }

        let typescriptDirectory = packageDirectory.appending(
            path: "node_modules/typescript", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: typescriptDirectory, withIntermediateDirectories: true)
        try Data("{\"name\":\"typescript\"}".utf8).write(
            to: typescriptDirectory.appending(path: "package.json"))
    }
}
