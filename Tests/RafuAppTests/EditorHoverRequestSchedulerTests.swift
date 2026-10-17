import Foundation
import Testing

@testable import RafuApp

@Suite("Editor hover request scheduling")
@MainActor
struct EditorHoverRequestSchedulerTests {
    @Test("Movement inside one identifier does not restart or repeat hover")
    func stableIdentifierKeepsRequest() async throws {
        let scheduler = EditorHoverRequestScheduler(wait: { delay in
            #expect(delay == .milliseconds(150))
        })
        let range = NSRange(location: 10, length: 6)
        var resolves = 0
        var shown: [String] = []
        let resolve: @MainActor () async -> EditorHoverInfo? = {
            resolves += 1
            return Self.info("current") as EditorHoverInfo?
        }
        let present: @MainActor (EditorHoverInfo) -> Void = { shown.append($0.text) }
        let task = try #require(
            scheduler.schedule(target: range, resolve: resolve, present: present))
        scheduler.schedule(target: range, resolve: resolve, present: present)
        scheduler.schedule(target: range, resolve: resolve, present: present)
        await task.value
        scheduler.schedule(target: range, resolve: resolve, present: present)
        #expect(resolves == 1)
        #expect(shown == ["current"])
    }

    @Test("A stale response cannot replace a newer identifier's documentation")
    func staleResponseIsRejected() async throws {
        let scheduler = EditorHoverRequestScheduler(wait: { _ in })
        let started = AsyncStream<Void>.makeStream()
        var complete: CheckedContinuation<EditorHoverInfo?, Never>?
        var shown: [String] = []
        let oldTask = try #require(
            scheduler.schedule(target: NSRange(location: 0, length: 3)) {
                await withCheckedContinuation { continuation in
                    complete = continuation
                    started.continuation.yield(())
                }
            } present: {
                shown.append($0.text)
            })
        var starts = started.stream.makeAsyncIterator()
        _ = await starts.next()
        let newTask = try #require(
            scheduler.schedule(target: NSRange(location: 5, length: 3)) {
                Self.info("new")
            } present: {
                shown.append($0.text)
            })
        await newTask.value
        try #require(complete).resume(returning: Self.info("old"))
        await oldTask.value
        #expect(shown == ["new"])
    }

    @Test("Dismissal during the delay prevents the language-server request")
    func cancelBeforeResolve() async throws {
        let started = AsyncStream<Void>.makeStream()
        let released = AsyncStream<Void>.makeStream()
        let scheduler = EditorHoverRequestScheduler(wait: { _ in
            started.continuation.yield(())
            var events = released.stream.makeAsyncIterator()
            _ = await events.next()
        })
        var resolves = 0
        let task = try #require(
            scheduler.schedule(target: NSRange(location: 0, length: 3)) {
                resolves += 1
                return Self.info("unused")
            } present: { _ in
                Issue.record("Dismissed hover must not present")
            })
        var starts = started.stream.makeAsyncIterator()
        _ = await starts.next()
        scheduler.cancel()
        released.continuation.yield(())
        released.continuation.finish()
        await task.value
        #expect(resolves == 0)
    }

    @Test("A declined request can retry and leaving an identifier permits a new hover")
    func declineAndReentryCanRetry() async throws {
        let scheduler = EditorHoverRequestScheduler(wait: { _ in })
        let range = NSRange(location: 2, length: 4)
        var resolves = 0
        let decline = try #require(
            scheduler.schedule(target: range) {
                resolves += 1
                return nil
            } present: { _ in
                Issue.record("Declined hover must not present")
            })
        await decline.value
        var shown = 0
        let resolve: @MainActor () async -> EditorHoverInfo? = {
            resolves += 1
            return Self.info("result") as EditorHoverInfo?
        }
        let present: @MainActor (EditorHoverInfo) -> Void = { _ in shown += 1 }
        let retry = try #require(
            scheduler.schedule(target: range, resolve: resolve, present: present))
        await retry.value
        scheduler.cancel()
        let reentry = try #require(
            scheduler.schedule(target: range, resolve: resolve, present: present))
        await reentry.value
        #expect(resolves == 3)
        #expect(shown == 2)
    }

    private static func info(_ text: String) -> EditorHoverInfo {
        EditorHoverInfo(
            text: text, symbolName: text, signature: nil, documentation: text, isMarkdown: false)
    }
}
