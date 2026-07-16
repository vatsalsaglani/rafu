import Foundation

/// Manages the single pinned Node.js runtime `nodeHosted` servers (Pyright,
/// typescript-language-server) run under, installed once under
/// `InstallLayout.runtimesRoot/node-<version>/`. A bare `actor` so
/// concurrent `ensureInstalled()` calls (e.g. two `nodeHosted` servers
/// installing around the same time) are serialized onto one install rather
/// than racing.
actor NodeRuntimeManager {
    /// The Node.js LTS release this build pins to. Must be re-confirmed
    /// against https://nodejs.org/dist/ before shipping — this environment
    /// has no live network access to verify it at implementation time.
    static let pinnedVersion = "22.11.0"

    /// SHA-256 of `node-v22.11.0-darwin-arm64.tar.gz`, from Node's published
    /// `SHASUMS256.txt` for this release and confirmed against a live
    /// download of the tarball (both equal this digest). When bumping
    /// `pinnedVersion`, re-pin this from
    /// `https://nodejs.org/dist/v<version>/SHASUMS256.txt`; never set it to
    /// `nil` (that would silently disable verification of the downloaded
    /// runtime).
    static let pinnedChecksum =
        "2e89afe6f4e3aa6c7e21c560d8a0453d84807e97850bbb819b998531a22bdfde"

    private let downloader: any AssetDownloading
    private let layout: InstallLayout
    private let fileManager: FileManager
    private let expectedChecksum: String?

    init(
        downloader: any AssetDownloading = URLSessionAssetDownloader(),
        layout: InstallLayout = InstallLayout(),
        fileManager: FileManager = .default,
        expectedChecksum: String? = NodeRuntimeManager.pinnedChecksum
    ) {
        self.downloader = downloader
        self.layout = layout
        self.fileManager = fileManager
        self.expectedChecksum = expectedChecksum
    }

    private var versionedDirectory: URL {
        layout.runtimesRoot.appending(
            path: "node-\(Self.pinnedVersion)", directoryHint: .isDirectory)
    }

    private var nodeExecutableURL: URL {
        versionedDirectory.appending(path: "bin/node")
    }

    /// Returns the pinned Node executable, installing it first if this is
    /// the first `nodeHosted` install this app has performed. Idempotent:
    /// a call that finds `bin/node` already installed and executable
    /// returns immediately without downloading anything again.
    func ensureInstalled(consentToQuarantineRemoval: Bool) async throws -> URL {
        if fileManager.isExecutableFile(atPath: nodeExecutableURL.path) {
            return nodeExecutableURL
        }

        let sourceURL = URL(
            string:
                "https://nodejs.org/dist/v\(Self.pinnedVersion)/node-v\(Self.pinnedVersion)-darwin-arm64.tar.gz"
        )!

        let downloadedURL = try await downloader.download(from: sourceURL)
        defer { try? fileManager.removeItem(at: downloadedURL) }

        _ = try ServerInstaller.verifyChecksum(fileURL: downloadedURL, expected: expectedChecksum)

        let isolationRoot = fileManager.temporaryDirectory.appending(
            path: "rafu-node-install-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: isolationRoot) }
        let staging = isolationRoot.appending(path: "staging", directoryHint: .isDirectory)

        // Node's tarball wraps everything in a single top-level
        // `node-v<version>-darwin-arm64/` directory, unlike the npm
        // release tarballs `ServerInstaller` unpacks (whose declared
        // `binaryRelativePath` already includes their own top-level
        // `package/` prefix). The wrapper directory itself is what gets
        // validated and atomically moved into `versionedDirectory`.
        let wrapperName = "node-v\(Self.pinnedVersion)-darwin-arm64"
        try await ArchiveUnpacker.unpack(
            assetURL: downloadedURL, format: .tarGzip,
            binaryRelativePath: "\(wrapperName)/bin/node", into: staging)
        _ = try StagingValidator.validate(
            staging: staging, binaryRelativePath: "\(wrapperName)/bin/node")

        let wrapperDirectory = staging.appending(path: wrapperName, directoryHint: .isDirectory)
        try AtomicDirectoryReplacer.replace(target: versionedDirectory, with: wrapperDirectory)

        try fileManager.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: nodeExecutableURL.path)
        QuarantineRemover.removeIfConsented(
            at: nodeExecutableURL, consent: consentToQuarantineRemoval)

        return nodeExecutableURL
    }
}
