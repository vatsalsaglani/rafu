import Foundation
import Testing

@testable import RafuApp

private actor CallRecorder {
    private(set) var calledTiers: [NavigationTier] = []

    func record(_ tier: NavigationTier) {
        calledTiers.append(tier)
    }
}

private struct MockNavigationProvider: NavigationTierProvider {
    let tier: NavigationTier
    let answerToReturn: NavigationAnswer?
    let recorder: CallRecorder

    func answer(_ request: NavigationRequest) async throws -> NavigationAnswer? {
        await recorder.record(tier)
        return answerToReturn
    }
}

/// Cancels the enclosing task the moment it is asked to answer, then
/// declines. Used to prove the ladder actually stops instead of merely
/// happening to run out of providers.
private struct CancellingProvider: NavigationTierProvider {
    let tier: NavigationTier
    let recorder: CallRecorder

    func answer(_ request: NavigationRequest) async throws -> NavigationAnswer? {
        await recorder.record(tier)
        withUnsafeCurrentTask { $0?.cancel() }
        return nil
    }
}

private func makeRequest(symbolName: String? = "foo") -> NavigationRequest {
    NavigationRequest(
        documentURL: URL(fileURLWithPath: "/tmp/File.swift"),
        position: 0,
        languageID: "swift",
        kind: .definition,
        symbolName: symbolName
    )
}

@Test("Ladder queries providers in order and returns the first non-nil answer")
func ladderRespectsOrderAndShortCircuits() async throws {
    let recorder = CallRecorder()
    let declining = MockNavigationProvider(
        tier: .lsp(serverName: "sourcekit-lsp"), answerToReturn: nil, recorder: recorder)
    let answering = MockNavigationProvider(
        tier: .syntactic,
        answerToReturn: NavigationAnswer(tier: .syntactic, candidates: [], state: .ready),
        recorder: recorder
    )
    let neverCalled = MockNavigationProvider(
        tier: .text,
        answerToReturn: NavigationAnswer(tier: .text, candidates: [], state: .ready),
        recorder: recorder
    )

    let ladder = NavigationLadder(providers: [declining, answering, neverCalled])
    let result = try await ladder.resolve(makeRequest())

    #expect(result?.tier == .syntactic)
    let called = await recorder.calledTiers
    #expect(called == [.lsp(serverName: "sourcekit-lsp"), .syntactic])
}

@Test("Ladder falls through to nil when every provider declines")
func ladderFallsThroughOnAllDeclines() async throws {
    let recorder = CallRecorder()
    let first = MockNavigationProvider(
        tier: .lsp(serverName: "sourcekit-lsp"), answerToReturn: nil, recorder: recorder)
    let second = MockNavigationProvider(tier: .syntactic, answerToReturn: nil, recorder: recorder)

    let ladder = NavigationLadder(providers: [first, second])
    let result = try await ladder.resolve(makeRequest())

    #expect(result == nil)
    let called = await recorder.calledTiers
    #expect(called == [.lsp(serverName: "sourcekit-lsp"), .syntactic])
}

@Test("Ladder stops before the next provider once its task is cancelled")
func ladderPropagatesCancellation() async throws {
    let recorder = CallRecorder()
    let cancelling = CancellingProvider(tier: .lsp(serverName: "cancelling"), recorder: recorder)
    let neverCalled = MockNavigationProvider(
        tier: .syntactic, answerToReturn: nil, recorder: recorder)

    let ladder = NavigationLadder(providers: [cancelling, neverCalled])

    await #expect(throws: CancellationError.self) {
        try await ladder.resolve(makeRequest())
    }
    let called = await recorder.calledTiers
    #expect(called == [.lsp(serverName: "cancelling")])
}
