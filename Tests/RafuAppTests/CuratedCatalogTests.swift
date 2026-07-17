import Foundation
import Testing

@testable import RafuApp

@Suite("Curated catalog")
struct CuratedCatalogTests {
    @Test("The real curated catalog validates cleanly")
    func realCatalogValidates() throws {
        try CuratedCatalog.validate()
    }

    @Test(
        "typescript-language-server's archive names npmPackageRoot \"package\"; Pyright's does not"
    )
    func typeScriptLanguageServerNamesNpmPackageRootButPyrightDoesNot() throws {
        let typeScriptLanguageServer = try #require(
            CuratedCatalog.servers.first { $0.id == "typescript-language-server" })
        #expect(typeScriptLanguageServer.archive?.npmPackageRoot == "package")

        let pyright = try #require(CuratedCatalog.servers.first { $0.id == "pyright" })
        #expect(pyright.archive?.npmPackageRoot == nil)
    }

    @Test("sourcekit-lsp requests background indexing via initializationOptions")
    func sourceKitLSPRequestsBackgroundIndexing() throws {
        let sourceKit = try #require(CuratedCatalog.servers.first { $0.id == "sourcekit-lsp" })
        #expect(sourceKit.initializationOptions == .object(["backgroundIndexing": .bool(true)]))
    }

    @Test("Every real catalog entry names a unique, non-empty id and languageIDs")
    func realCatalogEntriesAreWellFormed() {
        let ids = CuratedCatalog.servers.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(CuratedCatalog.servers.allSatisfy { !$0.languageIDs.isEmpty })
    }

    @Test("A non-https source URL is rejected")
    func rejectsNonHTTPSSource() {
        let descriptor = makeDescriptor(
            id: "insecure",
            kind: .singleBinary,
            source: ServerSource(
                url: URL(string: "http://example.com/tool.zip")!,
                version: "1.0.0", checksum: nil, license: "MIT", estimatedBytes: nil)
        )
        #expect(throws: CuratedCatalogError.nonHTTPSSource(id: "insecure")) {
            try CuratedCatalog.validate([descriptor])
        }
    }

    @Test("A missing pinned version is rejected")
    func rejectsMissingVersion() {
        let descriptor = makeDescriptor(
            id: "unversioned",
            kind: .singleBinary,
            source: ServerSource(
                url: URL(string: "https://example.com/tool.zip")!,
                version: "   ", checksum: nil, license: "MIT", estimatedBytes: nil)
        )
        #expect(throws: CuratedCatalogError.missingPinnedVersion(id: "unversioned")) {
            try CuratedCatalog.validate([descriptor])
        }
    }

    @Test("A duplicate id across two descriptors is rejected")
    func rejectsDuplicateID() {
        let first = makeDescriptor(id: "dup", kind: .localDiscovery, source: nil)
        let second = makeDescriptor(id: "dup", kind: .localDiscovery, source: nil)
        #expect(throws: CuratedCatalogError.duplicateID("dup")) {
            try CuratedCatalog.validate([first, second])
        }
    }

    @Test("An empty languageIDs list is rejected")
    func rejectsEmptyLanguageIDs() {
        let descriptor = ServerDescriptor(
            id: "no-languages",
            languageIDs: [],
            displayName: "No languages",
            kind: .localDiscovery,
            source: nil,
            launchArguments: [],
            archive: nil,
            initializationOptions: nil,
            prerequisites: []
        )
        #expect(throws: CuratedCatalogError.emptyLanguageIDs(id: "no-languages")) {
            try CuratedCatalog.validate([descriptor])
        }
    }

    @Test("A localDiscovery descriptor with a non-nil source is rejected")
    func rejectsLocalDiscoveryWithSource() {
        let descriptor = makeDescriptor(
            id: "bad-discovery",
            kind: .localDiscovery,
            source: ServerSource(
                url: URL(string: "https://example.com/tool")!,
                version: "1.0.0", checksum: nil, license: "MIT", estimatedBytes: nil)
        )
        #expect(throws: CuratedCatalogError.localDiscoveryMustHaveNoSource(id: "bad-discovery")) {
            try CuratedCatalog.validate([descriptor])
        }
    }

    @Test("A nodeHosted descriptor missing the managedNodeRuntime prerequisite is rejected")
    func rejectsNodeHostedMissingPrerequisite() {
        let descriptor = ServerDescriptor(
            id: "node-tool",
            languageIDs: ["javascript"],
            displayName: "Node tool",
            kind: .nodeHosted,
            source: ServerSource(
                url: URL(string: "https://registry.npmjs.org/tool/-/tool-1.0.0.tgz")!,
                version: "1.0.0", checksum: nil, license: "MIT", estimatedBytes: nil),
            launchArguments: [],
            archive: ArchiveLayout(format: .tarGzip, binaryRelativePath: "package/cli.js"),
            initializationOptions: nil,
            prerequisites: []
        )
        #expect(
            throws: CuratedCatalogError.nodeHostedMissingManagedRuntimePrerequisite(
                id: "node-tool")
        ) {
            try CuratedCatalog.validate([descriptor])
        }
    }

    @Test("sourcekit-lsp without the xcodeToolchain prerequisite is rejected")
    func rejectsSourceKitLSPMissingXcodeToolchainPrerequisite() {
        let descriptor = ServerDescriptor(
            id: "sourcekit-lsp",
            languageIDs: ["swift"],
            displayName: "SourceKit-LSP",
            kind: .localDiscovery,
            source: nil,
            launchArguments: [],
            archive: nil,
            initializationOptions: nil,
            prerequisites: []
        )
        #expect(throws: CuratedCatalogError.sourceKitLSPMissingXcodeToolchainPrerequisite) {
            try CuratedCatalog.validate([descriptor])
        }
    }

    private func makeDescriptor(
        id: String, kind: ServerKind, source: ServerSource?
    ) -> ServerDescriptor {
        ServerDescriptor(
            id: id,
            languageIDs: ["example"],
            displayName: id,
            kind: kind,
            source: source,
            launchArguments: [],
            archive: source == nil
                ? nil : ArchiveLayout(format: .zip, binaryRelativePath: "bin/tool"),
            initializationOptions: nil,
            prerequisites: []
        )
    }
}
