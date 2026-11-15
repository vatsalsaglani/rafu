import Foundation
import RafuCore
import Testing

@testable import RafuApp

// Memory D1: the workspace symbol index is built only on the first demand
// (the palette's `#` mode or Go to Definition), then kept current by refreshes
// and watcher events. These drive `WorkspaceSession` directly on a temporary
// folder; no window, no LSP, no file watcher.

@MainActor
private func makeLazyIndexSession() throws -> (WorkspaceSession, URL) {
    let root = FileManager.default.temporaryDirectory
        .appending(
            path: "rafu-lazy-symbol-index-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("func alpha() {}\nfunc beta() {}\n".utf8).write(to: root.appending(path: "A.swift"))
    let session = WorkspaceSession()
    session.descriptor = WorkspaceDescriptor(
        displayName: "Lazy Symbol Index",
        location: .local(LocalWorkspaceReference(path: root.path)))
    return (session, root)
}

/// Awaits every in-flight build or patch, including a trailing rebuild.
@MainActor
private func settleSymbolIndex(_ session: WorkspaceSession) async {
    while let task = session.symbolIndexTaskForTesting { await task.value }
}

@MainActor
@Test("Opening and refreshing a workspace does not build the symbol index")
func lazySymbolIndexNotBuiltAtOpenOrRefresh() async throws {
    let (session, root) = try makeLazyIndexSession()
    defer { try? FileManager.default.removeItem(at: root) }

    await session.refreshWorkspace()
    session.requestSymbolIndexIncrementalUpdate(changedDirectoryRelativePaths: [""])

    #expect(session.symbolIndexState == .idle)
    #expect(session.symbolIndexTaskForTesting == nil)
    #expect(await session.symbolIndexForTesting.startedBuildCount == 0)
    #expect(await session.symbolIndexForTesting.currentState == .idle)
}

@MainActor
@Test("The first demand builds once; concurrent demands share that build")
func lazySymbolIndexFirstDemandBuildsOnce() async throws {
    let (session, root) = try makeLazyIndexSession()
    defer { try? FileManager.default.removeItem(at: root) }

    // Before the demand an open folder already reads "Indexing symbols…", so
    // the palette never flashes "Open a folder" for one.
    #expect(
        CommandPaletteView.workspaceSymbolEmptyMessage(
            state: session.symbolIndexState, hasWorkspace: true, hasMatches: false)
            == "Indexing symbols…")

    session.ensureSymbolIndexReady()
    session.ensureSymbolIndexReady()
    session.ensureSymbolIndexReady()
    #expect(session.symbolIndexState == .building)
    #expect(
        CommandPaletteView.workspaceSymbolEmptyMessage(
            state: session.symbolIndexState, hasWorkspace: true, hasMatches: false)
            == "Indexing symbols…")

    // Two Go to Definition style waiters share the one build.
    async let first: Void = session.waitForSymbolIndexBuild()
    async let second: Void = session.waitForSymbolIndexBuild()
    _ = await (first, second)

    #expect(session.symbolIndexState == .ready(count: 2, isTruncated: false))
    #expect(await session.symbolIndexForTesting.startedBuildCount == 1)
    let matches = try await session.queryWorkspaceSymbols(term: "alpha", limit: 10)
    #expect(matches.map(\.name) == ["alpha"])
    #expect(
        CommandPaletteView.workspaceSymbolEmptyMessage(
            state: session.symbolIndexState, hasWorkspace: true, hasMatches: false)
            == "No matching symbols")
}

@MainActor
@Test("A built index is patched incrementally and rebuilt by a refresh")
func lazySymbolIndexKeptCurrentOnceBuilt() async throws {
    let (session, root) = try makeLazyIndexSession()
    defer { try? FileManager.default.removeItem(at: root) }

    session.ensureSymbolIndexReady()
    await session.waitForSymbolIndexBuild()
    let index = session.symbolIndexForTesting
    #expect(await index.startedBuildCount == 1)

    try Data("func gamma() {}\n".utf8).write(to: root.appending(path: "B.swift"))
    session.requestSymbolIndexIncrementalUpdate(changedDirectoryRelativePaths: [""])
    await settleSymbolIndex(session)
    #expect(
        try await session.queryWorkspaceSymbols(term: "gamma", limit: 10).map(\.name) == ["gamma"])
    #expect(await index.startedBuildCount == 1)
    #expect(session.symbolIndexState == .ready(count: 3, isTruncated: false))

    await session.refreshWorkspace()
    #expect(session.symbolIndexState == .building)
    await settleSymbolIndex(session)
    #expect(await index.startedBuildCount == 2)
    #expect(session.symbolIndexState == .ready(count: 3, isTruncated: false))
    // The rebuild never retained the previous generation beside the new one.
    #expect(await index.peakRetainedSymbolCount == 3)
}

@MainActor
@Test("A memory-pressure shed cancels the build, wakes waiters, and stops lazy updates")
func lazySymbolIndexShedCancelsAndForgetsDemand() async throws {
    let (session, root) = try makeLazyIndexSession()
    defer { try? FileManager.default.removeItem(at: root) }

    session.ensureSymbolIndexReady()
    let waiter = Task { await session.waitForSymbolIndexBuild() }
    session.respondToMemoryPressure()
    await waiter.value

    #expect(session.symbolIndexState == .idle)
    #expect(session.symbolIndexTaskForTesting == nil)
    await session.refreshWorkspace()
    #expect(session.symbolIndexState == .idle)
    #expect(session.symbolIndexTaskForTesting == nil)
}

@MainActor
@Test("A cancelled waiter returns before the build ends")
func lazySymbolIndexWaiterIsCancellable() async throws {
    let (session, root) = try makeLazyIndexSession()
    defer { try? FileManager.default.removeItem(at: root) }

    session.ensureSymbolIndexReady()
    let waiter = Task { await session.waitForSymbolIndexBuild() }
    waiter.cancel()
    await waiter.value
    await settleSymbolIndex(session)
    #expect(session.symbolIndexState == .ready(count: 2, isTruncated: false))
}

@MainActor
@Test("Closing the workspace cancels the in-flight build")
func lazySymbolIndexCloseCancelsBuild() async throws {
    var (session, root): (WorkspaceSession?, URL) = try makeLazyIndexSession()
    defer { try? FileManager.default.removeItem(at: root) }

    session?.ensureSymbolIndexReady()
    let index = try #require(session?.symbolIndexForTesting)
    let task = try #require(session?.symbolIndexTaskForTesting)
    weak let closed = session
    session = nil
    #expect(closed == nil)

    // Without the cancellation the build would run and publish two symbols.
    await task.value
    #expect(await index.startedBuildCount == 0)
    #expect(await index.currentState == .idle)
}
