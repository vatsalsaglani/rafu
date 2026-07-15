import Foundation
import Testing

@testable import RafuApp

/// Not `@MainActor`-annotated — every call into `LanguageServersCatalogModel`
/// (a `@MainActor` type) below crosses the actor boundary via an explicit
/// `await`, which keeps these tests free of a `@MainActor` test function
/// nesting the shared (non-`@Sendable`-closure) `withTemporaryDirectory`
/// helper, something Swift 6's cross-isolation "sending value risks
/// causing data races" check rejects.
private func waitUntil(
    timeout: Duration = .seconds(2), pollInterval: Duration = .milliseconds(5),
    _ predicate: @MainActor () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: pollInterval)
    }
    return await predicate()
}

@Suite("Language servers catalog model")
struct LanguageServersCatalogModelTests {
    @Test("Loading populates rows from the curated catalog and packs from ServerPack.all")
    func loadPopulatesRowsAndPacks() async throws {
        try await withTemporaryDirectory { directory in
            let model = await LanguageServersCatalogModel(
                userEntryStore: UserEntryStore(baseDirectory: directory),
                layout: InstallLayout(baseDirectory: directory),
                downloader: FixtureAssetDownloader(fixtureURL: directory.appending(path: "unused"))
            )
            await model.load()

            let rows = await model.rows
            let packs = await model.packs
            let userRows = await model.userRows
            #expect(rows.map(\.id).sorted() == CuratedCatalog.servers.map(\.id).sorted())
            #expect(packs.map(\.id) == ServerPack.all.map(\.id))
            #expect(userRows.isEmpty)
        }
    }

    @Test("A fresh install layout reports marksman as not installed")
    func freshLayoutReportsNotInstalled() async throws {
        try await withTemporaryDirectory { directory in
            let model = await LanguageServersCatalogModel(
                userEntryStore: UserEntryStore(baseDirectory: directory),
                layout: InstallLayout(baseDirectory: directory),
                downloader: FixtureAssetDownloader(fixtureURL: directory.appending(path: "unused"))
            )
            await model.load()

            let marksman = await model.rows.first { $0.id == "marksman" }
            #expect(marksman?.installState == .notInstalled)
        }
    }

    @Test("Confirming a single-server install transitions its row to installed")
    func confirmInstallTransitionsToInstalled() async throws {
        try await withTemporaryDirectory { fixtures in
            try await withTemporaryDirectory { directory in
                let fixtureBinary = fixtures.appending(path: "marksman-macos")
                try Data("#!/bin/sh\necho marksman\n".utf8).write(to: fixtureBinary)

                let model = await LanguageServersCatalogModel(
                    userEntryStore: UserEntryStore(baseDirectory: directory),
                    layout: InstallLayout(baseDirectory: directory),
                    downloader: FixtureAssetDownloader(fixtureURL: fixtureBinary)
                )
                await model.load()

                await model.beginInstall(id: "marksman")
                let consentID = await model.presentedConsent?.id
                #expect(consentID == "marksman")

                await model.confirmInstall()
                let consentAfterConfirm = await model.presentedConsent
                #expect(consentAfterConfirm == nil)
                let progressWhileInstalling = await model.rows.first { $0.id == "marksman" }?
                    .progressActive
                #expect(progressWhileInstalling == true)

                let installed = await waitUntil {
                    if case .installed = model.rows.first(where: { $0.id == "marksman" })?
                        .installState
                    {
                        return true
                    }
                    return false
                }
                #expect(installed)
                let progressAfterInstall = await model.rows.first { $0.id == "marksman" }?
                    .progressActive
                #expect(progressAfterInstall == false)
            }
        }
    }

    @Test("Cancelling an install immediately resets the row's progress")
    func cancelResetsProgress() async throws {
        try await withTemporaryDirectory { directory in
            let model = await LanguageServersCatalogModel(
                userEntryStore: UserEntryStore(baseDirectory: directory),
                layout: InstallLayout(baseDirectory: directory),
                downloader: FixtureAssetDownloader(fixtureURL: directory.appending(path: "unused"))
            )
            await model.load()

            await model.beginInstall(id: "marksman")
            await model.confirmInstall()
            let progressWhileInstalling = await model.rows.first { $0.id == "marksman" }?
                .progressActive
            #expect(progressWhileInstalling == true)

            await model.cancelInstall(id: "marksman")
            let progressAfterCancel = await model.rows.first { $0.id == "marksman" }?
                .progressActive
            #expect(progressAfterCancel == false)
        }
    }

    @Test("beginInstallPack composes a consent request naming every pack member's descriptor")
    func packComposition() async throws {
        try await withTemporaryDirectory { directory in
            let model = await LanguageServersCatalogModel(
                userEntryStore: UserEntryStore(baseDirectory: directory),
                layout: InstallLayout(baseDirectory: directory),
                downloader: FixtureAssetDownloader(fixtureURL: directory.appending(path: "unused"))
            )
            await model.load()

            await model.beginInstallPack(id: "node-web-tools")
            guard case .pack(_, let descriptors) = await model.presentedConsent?.subject else {
                Issue.record("Expected a pack consent request")
                return
            }
            #expect(Set(descriptors.map(\.id)) == Set(["pyright", "typescript-language-server"]))
        }
    }

    @Test("A custom https entry is accepted and appears in userRows")
    func acceptsHTTPSUserEntry() async throws {
        try await withTemporaryDirectory { directory in
            let model = await LanguageServersCatalogModel(
                userEntryStore: UserEntryStore(baseDirectory: directory),
                layout: InstallLayout(baseDirectory: directory),
                downloader: FixtureAssetDownloader(fixtureURL: directory.appending(path: "unused"))
            )
            await model.load()

            var draft = LanguageServersCatalogModel.UserEntryDraft()
            draft.id = "my-tool"
            draft.displayName = "My Tool"
            draft.languageIDsText = "toml"
            draft.sourceKind = .httpsReleaseAsset
            draft.assetURLText = "https://example.com/my-tool.tar.gz"
            draft.version = "1.0.0"
            draft.license = "MIT"
            draft.archiveFormat = .tarGzip
            draft.binaryRelativePath = "package/bin/my-tool"

            try await model.addUserEntry(draft)

            let userRows = await model.userRows
            #expect(userRows.map(\.id) == ["my-tool"])
            let isPresentingEntryForm = await model.isPresentingEntryForm
            #expect(isPresentingEntryForm == false)
        }
    }

    @Test("A non-https, non-file asset URL is rejected before being persisted")
    func rejectsNonHTTPSUserEntry() async throws {
        try await withTemporaryDirectory { directory in
            let model = await LanguageServersCatalogModel(
                userEntryStore: UserEntryStore(baseDirectory: directory),
                layout: InstallLayout(baseDirectory: directory),
                downloader: FixtureAssetDownloader(fixtureURL: directory.appending(path: "unused"))
            )
            await model.load()

            var draft = LanguageServersCatalogModel.UserEntryDraft()
            draft.id = "insecure-tool"
            draft.languageIDsText = "toml"
            draft.sourceKind = .httpsReleaseAsset
            draft.assetURLText = "ftp://example.com/tool"
            draft.binaryRelativePath = "tool"

            await #expect(throws: LanguageServersCatalogModel.CatalogModelError.invalidHTTPSURL) {
                try await model.addUserEntry(draft)
            }
            let userRows = await model.userRows
            #expect(userRows.isEmpty)
        }
    }

    @Test("A local-binary entry is accepted without an https URL")
    func acceptsLocalBinaryUserEntry() async throws {
        try await withTemporaryDirectory { directory in
            let model = await LanguageServersCatalogModel(
                userEntryStore: UserEntryStore(baseDirectory: directory),
                layout: InstallLayout(baseDirectory: directory),
                downloader: FixtureAssetDownloader(fixtureURL: directory.appending(path: "unused"))
            )
            await model.load()

            var draft = LanguageServersCatalogModel.UserEntryDraft()
            draft.id = "local-tool"
            draft.languageIDsText = "toml"
            draft.sourceKind = .localBinary
            draft.localBinaryPathText = "/usr/local/bin/local-tool"

            try await model.addUserEntry(draft)
            let userRows = await model.userRows
            #expect(userRows.map(\.id) == ["local-tool"])
        }
    }
}
