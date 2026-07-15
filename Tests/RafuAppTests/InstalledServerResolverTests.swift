import Foundation
import Testing

@testable import RafuApp

@Suite("Installed server resolver")
struct InstalledServerResolverTests {
    @Test("An installed, trusted singleBinary descriptor resolves with the right launch spec")
    func resolvesInstalledTrustedSingleBinary() async throws {
        try await withTemporaryDirectory { installBase in
            let layout = InstallLayout(baseDirectory: installBase)
            let descriptor = makeSingleBinaryDescriptor(id: "rust-analyzer", languageID: "rust")
            try installExecutable(
                at: layout.serverDirectory(id: "rust-analyzer").appending(path: "rust-analyzer"))

            let resolver = InstalledServerResolver(
                catalog: [descriptor], layout: layout, isTrusted: { _ in true })

            let resolved = try #require(resolver.resolve(languageID: "rust"))
            #expect(resolved.serverName == "rust-analyzer")
            #expect(
                resolved.launch.executableURL.path
                    == layout.serverDirectory(id: "rust-analyzer").appending(
                        path: "rust-analyzer"
                    ).path)
            #expect(resolved.launch.arguments == [])
            #expect(resolved.launch.currentDirectoryURL == nil)
        }
    }

    @Test("An installed, trusted nodeHosted descriptor resolves with node + entry path + args")
    func resolvesInstalledTrustedNodeHosted() async throws {
        try await withTemporaryDirectory { installBase in
            let layout = InstallLayout(baseDirectory: installBase)
            let entryPath = "package/dist/pyright-langserver.js"
            let descriptor = ServerDescriptor(
                id: "pyright",
                languageIDs: ["python"],
                displayName: "Pyright",
                kind: .nodeHosted,
                source: ServerSource(
                    url: URL(string: "https://registry.npmjs.org/pyright/-/pyright-1.1.377.tgz")!,
                    version: "1.1.377", checksum: nil, license: "MIT", estimatedBytes: nil),
                launchArguments: ["--stdio"],
                archive: ArchiveLayout(format: .tarGzip, binaryRelativePath: entryPath),
                initializationOptions: nil,
                prerequisites: [.managedNodeRuntime]
            )
            let entryURL = layout.serverDirectory(id: "pyright").appending(path: entryPath)
            try FileManager.default.createDirectory(
                at: entryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("entry".utf8).write(to: entryURL)

            let nodeExecutableURL = installBase.appending(path: "Runtimes/node-22.11.0/bin/node")

            let resolver = InstalledServerResolver(
                catalog: [descriptor], layout: layout, nodeExecutableURL: nodeExecutableURL,
                isTrusted: { _ in true })

            let resolved = try #require(resolver.resolve(languageID: "python"))
            #expect(resolved.launch.executableURL == nodeExecutableURL)
            #expect(resolved.launch.arguments == [entryURL.path, "--stdio"])
        }
    }

    @Test("A descriptor whose binary is not yet installed on disk declines")
    func declinesWhenNotInstalled() async throws {
        try await withTemporaryDirectory { installBase in
            let layout = InstallLayout(baseDirectory: installBase)
            let descriptor = makeSingleBinaryDescriptor(id: "rust-analyzer", languageID: "rust")

            let resolver = InstalledServerResolver(
                catalog: [descriptor], layout: layout, isTrusted: { _ in true })

            #expect(resolver.resolve(languageID: "rust") == nil)
        }
    }

    @Test("An installed but untrusted descriptor declines")
    func declinesWhenNotTrusted() async throws {
        try await withTemporaryDirectory { installBase in
            let layout = InstallLayout(baseDirectory: installBase)
            let descriptor = makeSingleBinaryDescriptor(id: "rust-analyzer", languageID: "rust")
            try installExecutable(
                at: layout.serverDirectory(id: "rust-analyzer").appending(path: "rust-analyzer"))

            let resolver = InstalledServerResolver(
                catalog: [descriptor], layout: layout, isTrusted: { _ in false })

            #expect(resolver.resolve(languageID: "rust") == nil)
        }
    }

    @Test("A nodeHosted descriptor with no configured Node executable declines even when installed")
    func nodeHostedDeclinesWithoutNodeExecutable() async throws {
        try await withTemporaryDirectory { installBase in
            let layout = InstallLayout(baseDirectory: installBase)
            let entryPath = "package/lib/cli.mjs"
            let descriptor = ServerDescriptor(
                id: "typescript-language-server",
                languageIDs: ["typescript"],
                displayName: "typescript-language-server",
                kind: .nodeHosted,
                source: ServerSource(
                    url: URL(
                        string:
                            "https://registry.npmjs.org/typescript-language-server/-/typescript-language-server-4.3.3.tgz"
                    )!,
                    version: "4.3.3", checksum: nil, license: "Apache-2.0", estimatedBytes: nil),
                launchArguments: ["--stdio"],
                archive: ArchiveLayout(format: .tarGzip, binaryRelativePath: entryPath),
                initializationOptions: nil,
                prerequisites: [.managedNodeRuntime]
            )
            let entryURL = layout.serverDirectory(id: "typescript-language-server").appending(
                path: entryPath)
            try FileManager.default.createDirectory(
                at: entryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("entry".utf8).write(to: entryURL)

            let resolver = InstalledServerResolver(
                catalog: [descriptor], layout: layout, nodeExecutableURL: nil,
                isTrusted: { _ in true })

            #expect(resolver.resolve(languageID: "typescript") == nil)
        }
    }

    @Test("An unknown languageID declines")
    func unknownLanguageIDDeclines() async throws {
        try await withTemporaryDirectory { installBase in
            let resolver = InstalledServerResolver(
                catalog: [], layout: InstallLayout(baseDirectory: installBase),
                isTrusted: { _ in true })
            #expect(resolver.resolve(languageID: "cobol") == nil)
        }
    }

    @Test("A localDiscovery descriptor with no discovered executable declines")
    func localDiscoveryDeclinesWithoutDiscoveredExecutable() async throws {
        try await withTemporaryDirectory { installBase in
            let descriptor = ServerDescriptor(
                id: "gopls",
                languageIDs: ["go"],
                displayName: "gopls",
                kind: .localDiscovery,
                source: nil,
                launchArguments: [],
                archive: nil,
                initializationOptions: nil,
                prerequisites: [.note("Requires a Go toolchain")]
            )
            let resolver = InstalledServerResolver(
                catalog: [descriptor], layout: InstallLayout(baseDirectory: installBase),
                goplsExecutableURL: nil, isTrusted: { _ in true })
            #expect(resolver.resolve(languageID: "go") == nil)
        }
    }

    @Test("A localDiscovery descriptor with an injected discovered executable resolves")
    func localDiscoveryResolvesWithInjectedExecutable() async throws {
        try await withTemporaryDirectory { installBase in
            let fakeGoplsURL = installBase.appending(path: "fake-gopls")
            try installExecutable(at: fakeGoplsURL)

            let descriptor = ServerDescriptor(
                id: "gopls",
                languageIDs: ["go"],
                displayName: "gopls",
                kind: .localDiscovery,
                source: nil,
                launchArguments: [],
                archive: nil,
                initializationOptions: nil,
                prerequisites: [.note("Requires a Go toolchain")]
            )
            let resolver = InstalledServerResolver(
                catalog: [descriptor], layout: InstallLayout(baseDirectory: installBase),
                goplsExecutableURL: fakeGoplsURL, isTrusted: { _ in true })

            let resolved = try #require(resolver.resolve(languageID: "go"))
            #expect(resolved.launch.executableURL == fakeGoplsURL)
        }
    }

    @Test("A user entry takes precedence over a catalog entry for the same languageID")
    func userEntryTakesPrecedenceOverCatalog() async throws {
        try await withTemporaryDirectory { installBase in
            let layout = InstallLayout(baseDirectory: installBase)
            let catalogDescriptor = makeSingleBinaryDescriptor(
                id: "rust-analyzer", languageID: "rust")
            let userDescriptor = makeSingleBinaryDescriptor(
                id: "my-rust-tool", languageID: "rust")
            try installExecutable(
                at: layout.serverDirectory(id: "my-rust-tool").appending(path: "my-rust-tool"))

            let resolver = InstalledServerResolver(
                catalog: [catalogDescriptor], userEntries: [userDescriptor], layout: layout,
                isTrusted: { _ in true })

            let resolved = try #require(resolver.resolve(languageID: "rust"))
            #expect(resolved.serverName == "my-rust-tool")
        }
    }

    private func makeSingleBinaryDescriptor(id: String, languageID: String) -> ServerDescriptor {
        ServerDescriptor(
            id: id,
            languageIDs: [languageID],
            displayName: id,
            kind: .singleBinary,
            source: ServerSource(
                url: URL(string: "https://example.com/\(id).gz")!,
                version: "1.0.0", checksum: nil, license: "MIT", estimatedBytes: nil),
            launchArguments: [],
            archive: ArchiveLayout(format: .gzip, binaryRelativePath: id),
            initializationOptions: nil,
            prerequisites: []
        )
    }

    private func installExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
