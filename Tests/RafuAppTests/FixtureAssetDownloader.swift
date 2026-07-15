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
