import Foundation
import Testing

@testable import RafuApp

@Suite("Installer path math")
struct InstallerPathMathTests {
    @Test("InstallLayout derives servers/runtimes roots and per-id server directories")
    func installLayoutDerivesPaths() {
        let base = URL(fileURLWithPath: "/tmp/rafu-test-base")
        let layout = InstallLayout(baseDirectory: base)

        // Compared via `.path` (not URL `==`) because `InstallLayout` builds
        // its URLs with `directoryHint: .isDirectory` (a trailing slash),
        // while a plain `appending(path:)` here would not — `.path` strips
        // that trailing slash on both sides either way.
        #expect(layout.serversRoot.path == base.appending(path: "LanguageServers").path)
        #expect(layout.runtimesRoot.path == base.appending(path: "Runtimes").path)
        #expect(
            layout.serverDirectory(id: "rust-analyzer").path
                == base.appending(path: "LanguageServers/rust-analyzer").path)
    }

    @Test("InstallLayout.installedBinaryURL combines the server directory with the archive path")
    func installedBinaryURLCombinesPaths() {
        let base = URL(fileURLWithPath: "/tmp/rafu-test-base")
        let layout = InstallLayout(baseDirectory: base)
        let descriptor = ServerDescriptor(
            id: "clangd",
            languageIDs: ["cpp"],
            displayName: "clangd",
            kind: .singleBinary,
            source: ServerSource(
                url: URL(string: "https://example.com/clangd.zip")!,
                version: "18.1.3", checksum: nil, license: "Apache-2.0", estimatedBytes: nil),
            launchArguments: [],
            archive: ArchiveLayout(format: .zip, binaryRelativePath: "clangd_18.1.3/bin/clangd"),
            initializationOptions: nil,
            prerequisites: []
        )

        #expect(
            layout.installedBinaryURL(descriptor: descriptor)?.path
                == base.appending(path: "LanguageServers/clangd/clangd_18.1.3/bin/clangd").path
        )
    }

    @Test("InstallLayout.installedBinaryURL is nil for a descriptor without an archive")
    func installedBinaryURLIsNilWithoutArchive() {
        let layout = InstallLayout(baseDirectory: URL(fileURLWithPath: "/tmp/rafu-test-base"))
        let descriptor = ServerDescriptor(
            id: "gopls",
            languageIDs: ["go"],
            displayName: "gopls",
            kind: .localDiscovery,
            source: nil,
            launchArguments: [],
            archive: nil,
            initializationOptions: nil,
            prerequisites: []
        )
        #expect(layout.installedBinaryURL(descriptor: descriptor) == nil)
    }

    @Test("ArchiveNameParser infers format from filename suffix")
    func inferFormatFromFilename() {
        #expect(
            ArchiveNameParser.inferFormat(
                from: URL(string: "https://example.com/tool-aarch64-apple-darwin.gz")!) == .gzip)
        #expect(
            ArchiveNameParser.inferFormat(from: URL(string: "https://example.com/tool.zip")!)
                == .zip)
        #expect(
            ArchiveNameParser.inferFormat(from: URL(string: "https://example.com/tool.tar.gz")!)
                == .tarGzip)
        #expect(
            ArchiveNameParser.inferFormat(from: URL(string: "https://example.com/tool.tgz")!)
                == .tarGzip)
        #expect(
            ArchiveNameParser.inferFormat(from: URL(string: "https://example.com/tool-macos")!)
                == .rawBinary)
    }

    @Test("ArchiveNameParser.validate throws unsupportedArchive on a mismatch")
    func validateThrowsOnMismatch() {
        #expect(throws: ServerInstallError.unsupportedArchive) {
            try ArchiveNameParser.validate(
                url: URL(string: "https://example.com/tool.zip")!, declared: .tarGzip)
        }
    }

    @Test("ArchiveNameParser.validate succeeds on a matching declared format")
    func validateSucceedsOnMatch() throws {
        try ArchiveNameParser.validate(
            url: URL(string: "https://example.com/tool.zip")!, declared: .zip)
    }
}
