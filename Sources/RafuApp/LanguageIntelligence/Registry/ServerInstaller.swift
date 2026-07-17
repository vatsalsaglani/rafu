import CryptoKit
import Darwin
import Foundation

/// How `ServerInstaller`/`NodeRuntimeManager` fetch one asset. Injected so
/// tests never touch the network — production uses
/// `URLSessionAssetDownloader`; tests inject a fixture downloader that
/// returns a small local file already staged in the test's own temporary
/// directory.
nonisolated protocol AssetDownloading: Sendable {
    /// Downloads `url` and returns the location of a file Rafu now owns
    /// exclusively (safe to move/delete). Implementations must never log
    /// `url` — a user-added entry's URL could carry a token in its query
    /// string.
    func download(from url: URL) async throws -> URL
}

/// The production downloader: a plain `URLSession` download task, `https`
/// only in practice (every catalog/user-validated source is `https` or a
/// local `file://`, which this type is never invoked for — see
/// `ServerInstaller.install`). Cooperatively cancellable: cancelling the
/// calling `Task` cancels `URLSession`'s async download.
nonisolated struct URLSessionAssetDownloader: AssetDownloading {
    func download(from url: URL) async throws -> URL {
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw ServerInstallError.downloadFailed
        }
        // `URLSession` may delete its own temp file once this call returns,
        // so move it into a location Rafu controls before returning.
        let ownedURL = FileManager.default.temporaryDirectory.appending(
            path: "rafu-lsp-download-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: temporaryURL, to: ownedURL)
        return ownedURL
    }
}

/// Pure path math for where installed servers and runtimes live under one
/// base directory, independent of any I/O. Defaults to the real per-user
/// Application Support directory; tests inject a temporary directory.
nonisolated struct InstallLayout: Sendable {
    let baseDirectory: URL

    init(baseDirectory: URL = InstallLayout.defaultBaseDirectory) {
        self.baseDirectory = baseDirectory
    }

    static var defaultBaseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Rafu", directoryHint: .isDirectory)
    }

    var serversRoot: URL {
        baseDirectory.appending(path: "LanguageServers", directoryHint: .isDirectory)
    }

    var runtimesRoot: URL {
        baseDirectory.appending(path: "Runtimes", directoryHint: .isDirectory)
    }

    func serverDirectory(id: String) -> URL {
        serversRoot.appending(path: id, directoryHint: .isDirectory)
    }

    /// Where a descriptor's installed executable/entry point would live,
    /// once its archive has been unpacked — pure math, independent of
    /// whether anything is actually installed there yet.
    func installedBinaryURL(descriptor: ServerDescriptor) -> URL? {
        guard let archive = descriptor.archive else { return nil }
        return serverDirectory(id: descriptor.id).appending(path: archive.binaryRelativePath)
    }
}

/// Infers an `ArchiveFormat` from a URL's filename, and validates it
/// against a descriptor's declared format — pure, no I/O.
nonisolated enum ArchiveNameParser {
    static func inferFormat(from url: URL) -> ArchiveFormat {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
            return .tarGzip
        }
        if name.hasSuffix(".gz") {
            return .gzip
        }
        if name.hasSuffix(".zip") {
            return .zip
        }
        return .rawBinary
    }

    static func validate(url: URL, declared: ArchiveFormat) throws {
        guard inferFormat(from: url) == declared else {
            throw ServerInstallError.unsupportedArchive
        }
    }
}

/// Whether an installed asset's checksum was actually checked against a
/// published digest, surfaced honestly rather than silently assumed —
/// `ServerInstaller` never fabricates a checksum to force `.verified`.
nonisolated enum ChecksumVerificationStatus: Sendable, Equatable {
    case verified
    /// The catalog/user entry never published a checksum for this asset,
    /// so none could be checked.
    case notPublished
    /// No download occurred (a user-supplied local binary entry) — there
    /// is nothing to check a checksum of.
    case notApplicable
}

nonisolated struct ServerInstallResult: Sendable {
    let binaryURL: URL
    let checksumStatus: ChecksumVerificationStatus
}

nonisolated enum ServerInstallError: Error, Equatable {
    case checksumMismatch
    case unsupportedArchive
    case unpackFailed(Int32)
    case pathTraversal
    case binaryMissing
    case downloadFailed
    /// An `ArchiveLayout` named an `npmPackageRoot` (so `install` needs to
    /// run `npm install` in staging) but no `nodeExecutableURL` was
    /// supplied — the caller must resolve the managed Node runtime first.
    case nodeRuntimeUnavailable
    /// `npm install --ignore-scripts …` exited non-zero while resolving a
    /// node-hosted server's dependencies; the staged install is discarded.
    case dependencyResolutionFailed(Int32)
}

/// Unpacks a downloaded asset into an isolated staging directory, by
/// format, always via a fixed executable + argv array.
nonisolated enum ArchiveUnpacker {
    /// Runs one fixed executable with an argv array — never a shell
    /// string, never string-interpolated input — and reports its exit
    /// code. Cancellable: a cancelled calling `Task` terminates the child
    /// process rather than leaving it to finish unsupervised.
    @concurrent
    static func runArgv(
        executableURL: URL, arguments: [String], currentDirectoryURL: URL? = nil
    ) async throws -> Int32 {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            while process.isRunning {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch is CancellationError {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw CancellationError()
        }
        return process.terminationStatus
    }

    static func unpack(
        assetURL: URL, format: ArchiveFormat, binaryRelativePath: String, into staging: URL
    ) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        switch format {
        case .rawBinary:
            let destination = staging.appending(path: binaryRelativePath)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: assetURL, to: destination)

        case .gzip:
            let staged = staging.appending(path: binaryRelativePath + ".gz")
            try fileManager.createDirectory(
                at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: assetURL, to: staged)
            let status = try await runArgv(
                executableURL: URL(fileURLWithPath: "/usr/bin/gunzip"),
                arguments: ["-f", staged.path])
            guard status == 0 else { throw ServerInstallError.unpackFailed(status) }

        case .zip:
            let status = try await runArgv(
                executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", assetURL.path, staging.path])
            guard status == 0 else { throw ServerInstallError.unpackFailed(status) }

        case .tarGzip:
            let status = try await runArgv(
                executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-xzf", assetURL.path, "-C", staging.path])
            guard status == 0 else { throw ServerInstallError.unpackFailed(status) }
        }
    }
}

/// Validates an unpacked staging directory before any of its contents are
/// moved into the real install location: rejects the entire install the
/// moment it finds a path — or a symlink target — that escapes `staging`.
///
/// Both `/usr/bin/tar` (bsdtar) and `/usr/bin/ditto` already refuse
/// absolute paths and `..` path components in archive entries by default
/// on macOS — this validator does not re-parse the archive itself, it
/// defends the one path those tool-level protections don't fully close:
/// a symlink entry whose target resolves outside `staging`, which would
/// let a later entry in the same archive write through it. It does *not*
/// reject every symlink: the managed Node runtime tarball legitimately
/// ships internal `bin/npm`, `bin/npx`, and `bin/corepack` links that
/// point back inside its own directory, so a symlink is allowed exactly
/// when its declared target — resolved lexically against the link's real
/// parent, so the check does not depend on the target existing yet —
/// stays within `staging`.
nonisolated enum StagingValidator {
    static func validate(staging: URL, binaryRelativePath: String) throws -> URL {
        let fileManager = FileManager.default
        let stagingRealPath = staging.resolvingSymlinksInPath().standardizedFileURL.path

        guard
            let enumerator = fileManager.enumerator(
                at: staging,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        else {
            throw ServerInstallError.binaryMissing
        }

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                try requireSymlinkStaysInside(
                    link: url, stagingRealPath: stagingRealPath, fileManager: fileManager)
                continue
            }
            let realPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard realPath == url.standardizedFileURL.path || realPath.hasPrefix(stagingRealPath)
            else {
                throw ServerInstallError.pathTraversal
            }
        }

        let binaryURL = staging.appending(path: binaryRelativePath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: binaryURL.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            throw ServerInstallError.binaryMissing
        }
        let binaryValues = try binaryURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard binaryValues.isSymbolicLink != true else {
            throw ServerInstallError.pathTraversal
        }
        return binaryURL
    }

    /// Throws `.pathTraversal` unless `link`'s declared symlink target
    /// resolves to a path inside `stagingRealPath`. The target is resolved
    /// lexically (`standardizedFileURL` collapses `..` without touching the
    /// filesystem) against the link's *real* parent directory, so an escape
    /// is caught whether or not the target exists yet — the case
    /// `resolvingSymlinksInPath()` alone would miss for a link to a
    /// not-yet-extracted or absent path.
    private static func requireSymlinkStaysInside(
        link: URL, stagingRealPath: String, fileManager: FileManager
    ) throws {
        let destination = try fileManager.destinationOfSymbolicLink(atPath: link.path)
        let parentReal = link.deletingLastPathComponent().resolvingSymlinksInPath()
            .standardizedFileURL
        let targetPath =
            (destination as NSString).isAbsolutePath
            ? URL(fileURLWithPath: destination).standardizedFileURL.path
            : parentReal.appendingPathComponent(destination).standardizedFileURL.path
        guard targetPath == stagingRealPath || targetPath.hasPrefix(stagingRealPath + "/") else {
            throw ServerInstallError.pathTraversal
        }
    }
}

/// Atomically replaces `target` (a directory) with `newContent`: an
/// existing `target` is renamed aside first, `newContent` is renamed into
/// place, and only then is the old directory deleted — so a crash between
/// the two renames leaves either the old or the new install fully intact,
/// never a half-written directory at `target`. If the second rename fails,
/// the original is restored.
nonisolated enum AtomicDirectoryReplacer {
    static func replace(target: URL, with newContent: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

        let asideURL = target.deletingLastPathComponent().appending(
            path: ".\(target.lastPathComponent)-superseded-\(UUID().uuidString)")
        var hadPrevious = false
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.moveItem(at: target, to: asideURL)
            hadPrevious = true
        }

        do {
            try fileManager.moveItem(at: newContent, to: target)
        } catch {
            if hadPrevious {
                try? fileManager.moveItem(at: asideURL, to: target)
            }
            throw error
        }

        if hadPrevious {
            try? fileManager.removeItem(at: asideURL)
        }
    }
}

/// Consent-gated, per-file quarantine removal. Never blanket, never
/// recursive, never a spawned `xattr` process — a single native
/// `removexattr(2)` call on exactly the one binary a user has approved
/// running.
///
/// `ditto` is known to propagate a pre-existing `com.apple.quarantine`
/// attribute from a quarantined source archive onto every file it
/// extracts, which is why Finder-unzipped downloads prompt Gatekeeper for
/// each file inside. Whether a `URLSession`-downloaded asset itself
/// carries that attribute depends on how the download was initiated and
/// is not something this installer assumes either way — it unconditionally
/// checks (and only clears, when consented) the attribute on the single
/// final installed binary, regardless of which step might have added it.
nonisolated enum QuarantineRemover {
    private static let attributeName = "com.apple.quarantine"

    static func isQuarantined(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { representation in
            guard let representation else { return false }
            return getxattr(representation, attributeName, nil, 0, 0, XATTR_NOFOLLOW) >= 0
        }
    }

    /// Removes the quarantine attribute from exactly `url` when `consent`
    /// is `true` and the attribute is present. A missing attribute, or a
    /// failed removal, is silently tolerated — Gatekeeper simply re-prompts
    /// on first launch in that case, which is the safe fallback.
    static func removeIfConsented(at url: URL, consent: Bool) {
        guard consent, isQuarantined(url) else { return }
        _ = url.withUnsafeFileSystemRepresentation { representation -> Int32 in
            guard let representation else { return -1 }
            return removexattr(representation, attributeName, XATTR_NOFOLLOW)
        }
    }
}

/// Downloads, verifies, unpacks, and installs one `ServerDescriptor`'s
/// asset under `InstallLayout.serverDirectory(id:)`. A bare `actor` so
/// concurrent install requests for the same or different servers are
/// serialized rather than racing on the same staging/install directories.
actor ServerInstaller {
    private let downloader: any AssetDownloading
    private let layout: InstallLayout
    private let fileManager: FileManager
    private let resolver: any NodeDependencyResolving

    init(
        downloader: any AssetDownloading = URLSessionAssetDownloader(),
        layout: InstallLayout = InstallLayout(),
        fileManager: FileManager = .default,
        resolver: any NodeDependencyResolving = NpmDependencyResolver()
    ) {
        self.downloader = downloader
        self.layout = layout
        self.fileManager = fileManager
        self.resolver = resolver
    }

    /// Installs `descriptor`. `consentToQuarantineRemoval` must reflect an
    /// explicit user approval for running this specific server — this
    /// method never decides consent itself.
    ///
    /// A user-supplied local-binary entry (`source.url` is a `file://`
    /// pointing at a binary the user already has) never downloads anything:
    /// it only validates the binary exists and is executable, and returns
    /// its own URL unchanged.
    ///
    /// `nodeExecutableURL` is required whenever `descriptor.archive?
    /// .npmPackageRoot` is non-nil (a node-hosted server whose tarball
    /// needs `npm install` to resolve its own dependencies); it is unused
    /// otherwise. Callers pass the managed Node runtime's `bin/node` URL
    /// from `NodeRuntimeManager.ensureInstalled()`.
    func install(
        descriptor: ServerDescriptor, consentToQuarantineRemoval: Bool,
        nodeExecutableURL: URL? = nil
    ) async throws -> ServerInstallResult {
        guard let source = descriptor.source else {
            throw ServerInstallError.unsupportedArchive
        }

        if source.url.isFileURL {
            guard fileManager.isExecutableFile(atPath: source.url.path) else {
                throw ServerInstallError.binaryMissing
            }
            return ServerInstallResult(binaryURL: source.url, checksumStatus: .notApplicable)
        }

        guard let archive = descriptor.archive else {
            throw ServerInstallError.unsupportedArchive
        }
        try ArchiveNameParser.validate(url: source.url, declared: archive.format)

        let downloadedURL = try await downloader.download(from: source.url)
        defer { try? fileManager.removeItem(at: downloadedURL) }

        let checksumStatus = try Self.verifyChecksum(
            fileURL: downloadedURL, expected: source.checksum)

        let isolationRoot = fileManager.temporaryDirectory.appending(
            path: "rafu-lsp-install-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: isolationRoot) }
        let staging = isolationRoot.appending(path: "staging", directoryHint: .isDirectory)

        try await ArchiveUnpacker.unpack(
            assetURL: downloadedURL, format: archive.format,
            binaryRelativePath: archive.binaryRelativePath, into: staging)
        _ = try StagingValidator.validate(
            staging: staging, binaryRelativePath: archive.binaryRelativePath)

        if let npmPackageRoot = archive.npmPackageRoot {
            guard let nodeExecutableURL else { throw ServerInstallError.nodeRuntimeUnavailable }
            let packageDirectory = staging.appending(
                path: npmPackageRoot, directoryHint: .isDirectory)
            try await resolver.installDependencies(
                packageDirectory: packageDirectory, nodeExecutableURL: nodeExecutableURL)
        }

        let target = layout.serverDirectory(id: descriptor.id)
        try AtomicDirectoryReplacer.replace(target: target, with: staging)

        let binaryURL = target.appending(path: archive.binaryRelativePath)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)
        QuarantineRemover.removeIfConsented(at: binaryURL, consent: consentToQuarantineRemoval)

        return ServerInstallResult(binaryURL: binaryURL, checksumStatus: checksumStatus)
    }

    /// Compares a fixed executable/argument install, never a shell string
    /// — kept internal so `NodeRuntimeManager` can reuse the exact same
    /// checksum semantics for its own tarball.
    static func verifyChecksum(fileURL: URL, expected: String?) throws -> ChecksumVerificationStatus
    {
        guard let expected else { return .notPublished }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard hex == expected.lowercased() else {
            throw ServerInstallError.checksumMismatch
        }
        return .verified
    }
}
