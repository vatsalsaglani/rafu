import Foundation
import Testing

@testable import RafuApp

/// usage-providers/W0-shim.md: `resolveUsageSnapshot(strategies:context:)`'s
/// pipeline semantics (order, skip-unavailable, fallback-vs-stop, first
/// success wins, total failure ⇒ nil), plus a redaction audit for
/// `UsageHTTPError`. The migrated Claude/Codex local-provider tests
/// (formerly `Tests/RafuAppTests/AgentUsageTests.swift`) and the
/// front-line rendering parity assertion live in this same file — see the
/// "Claude/Codex provider parsing" and "Rendering parity" sections below.

private func fixtureContext(
    now: Date = Date(),
    readFile: @escaping @Sendable (String) -> String? = { _ in nil },
    http: UsageHTTPClient = .noop,
    credential: @escaping @Sendable (UsageProviderID) -> String? = { _ in nil },
    cookieHeader: @escaping @Sendable (UsageProviderID) -> String? = { _ in nil }
) -> UsageFetchContext {
    UsageFetchContext(
        now: now, readFile: readFile, http: http, credential: credential,
        cookieHeader: cookieHeader)
}

private struct StubStrategy: UsageFetchStrategy {
    let id: String
    var available = true
    var result: Result<UsageSnapshot, Error> = .failure(UsageLocalDataError.noData)
    var fallback = false

    func isAvailable(_ context: UsageFetchContext) async -> Bool { available }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        try result.get()
    }

    func shouldFallback(on error: Error) -> Bool { fallback }
}

private func snapshot(_ id: UsageProviderID = .claude, percent: Double = 10) -> UsageSnapshot {
    UsageSnapshot(
        providerID: id,
        windows: [UsageWindow(label: "5h", percent: percent, tokens: nil, resetsAt: nil)],
        costLine: nil, identity: nil)
}

// MARK: - resolveUsageSnapshot pipeline

@Test("resolveUsageSnapshot: the first available, succeeding strategy wins")
func pipelineFirstSuccessWins() async {
    let first = StubStrategy(id: "first", result: .success(snapshot(percent: 1)))
    let second = StubStrategy(id: "second", result: .success(snapshot(percent: 2)))
    let result = await resolveUsageSnapshot(
        strategies: [first, second], context: fixtureContext())
    #expect(result?.windows.first?.percent == 1)
}

@Test("resolveUsageSnapshot: an unavailable strategy is skipped, not tried")
func pipelineSkipsUnavailable() async {
    let unavailable = StubStrategy(
        id: "unavailable", available: false, result: .success(snapshot(percent: 1)))
    let available = StubStrategy(id: "available", result: .success(snapshot(percent: 2)))
    let result = await resolveUsageSnapshot(
        strategies: [unavailable, available], context: fixtureContext())
    #expect(result?.windows.first?.percent == 2)
}

@Test("resolveUsageSnapshot: a throw with shouldFallback(true) continues to the next strategy")
func pipelineContinuesOnFallbackTrue() async {
    let failing = StubStrategy(
        id: "failing", result: .failure(UsageLocalDataError.noData), fallback: true)
    let succeeding = StubStrategy(id: "succeeding", result: .success(snapshot(percent: 3)))
    let result = await resolveUsageSnapshot(
        strategies: [failing, succeeding], context: fixtureContext())
    #expect(result?.windows.first?.percent == 3)
}

@Test("resolveUsageSnapshot: a throw with shouldFallback(false) stops the pipeline immediately")
func pipelineStopsOnFallbackFalse() async {
    let failing = StubStrategy(
        id: "failing", result: .failure(UsageLocalDataError.noData), fallback: false)
    let neverTried = StubStrategy(id: "never-tried", result: .success(snapshot(percent: 4)))
    let result = await resolveUsageSnapshot(
        strategies: [failing, neverTried], context: fixtureContext())
    #expect(result == nil)
}

@Test("resolveUsageSnapshot: every strategy failing/unavailable yields nil, never a crash")
func pipelineTotalFailureYieldsNil() async {
    let unavailable = StubStrategy(id: "unavailable", available: false)
    let failing = StubStrategy(
        id: "failing", result: .failure(UsageLocalDataError.noData), fallback: true)
    let result = await resolveUsageSnapshot(
        strategies: [unavailable, failing], context: fixtureContext())
    #expect(result == nil)
}

@Test("resolveUsageSnapshot: an empty strategy list yields nil")
func pipelineEmptyStrategiesYieldsNil() async {
    let result = await resolveUsageSnapshot(strategies: [], context: fixtureContext())
    #expect(result == nil)
}

// MARK: - UsageSnapshot.renderable

@Test("UsageSnapshot.renderable: false only when both windows and costLine are empty/nil")
func snapshotRenderable() {
    #expect(
        UsageSnapshot(providerID: .claude, windows: [], costLine: nil, identity: nil).renderable
            == false)
    #expect(
        UsageSnapshot(
            providerID: .claude,
            windows: [UsageWindow(label: "5h", percent: 1, tokens: nil, resetsAt: nil)],
            costLine: nil, identity: nil
        ).renderable == true)
    #expect(
        UsageSnapshot(providerID: .claude, windows: [], costLine: "$1.00", identity: nil)
            .renderable == true)
}

// MARK: - UsageHTTPClient redaction

@Test("UsageHTTPError: no case can carry a token, header, or body — String(describing:) is safe")
func usageHTTPErrorRedaction() {
    let cases: [UsageHTTPError] = [
        .rateLimited(retryAfter: 30), .httpStatus(429), .timedOut, .transportFailure,
        .invalidResponse,
    ]
    let secret = "sk-super-secret-token-should-never-appear"
    for error in cases {
        let described = String(describing: error)
        #expect(!described.contains(secret))
        #expect(!described.lowercased().contains("bearer"))
        #expect(!described.lowercased().contains("cookie"))
    }
}

@Test("UsageHTTPClient: a 429 response is surfaced as .rateLimited with the Retry-After value")
func usageHTTPClientSurfacesRateLimit() async throws {
    let url = try #require(URL(string: "https://example.com/usage"))
    let client = UsageHTTPClient(transport: { request in
        let response = try #require(
            HTTPURLResponse(
                url: url, statusCode: 429, httpVersion: nil,
                headerFields: ["Retry-After": "5"]))
        return (Data(), response)
    })
    do {
        _ = try await client.send(URLRequest(url: url), provider: .claude)
        Issue.record("expected UsageHTTPError.rateLimited to be thrown")
    } catch UsageHTTPError.rateLimited(let retryAfter) {
        #expect(retryAfter == 5)
    }
}

private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@Test(
    "UsageHTTPClient: a subsequent request for the same provider is gated until Retry-After elapses"
)
func usageHTTPClientGatesSubsequentRequests() async throws {
    let url = try #require(URL(string: "https://example.com/usage"))
    let counter = CallCounter()
    let client = UsageHTTPClient(transport: { request in
        await counter.increment()
        let response = try #require(
            HTTPURLResponse(
                url: url, statusCode: 429, httpVersion: nil,
                headerFields: ["Retry-After": "300"]))
        return (Data(), response)
    })
    _ = try? await client.send(URLRequest(url: url), provider: .claude)
    #expect(await counter.count == 1)
    // Second attempt should be gated in-memory without invoking the
    // transport at all.
    _ = try? await client.send(URLRequest(url: url), provider: .claude)
    #expect(await counter.count == 1)
}

@Test("UsageHTTPClient: a non-2xx, non-429 status throws .httpStatus")
func usageHTTPClientSurfacesHTTPStatus() async throws {
    let url = try #require(URL(string: "https://example.com/usage"))
    let client = UsageHTTPClient(transport: { request in
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil))
        return (Data(), response)
    })
    do {
        _ = try await client.send(URLRequest(url: url), provider: .codex)
        Issue.record("expected UsageHTTPError.httpStatus to be thrown")
    } catch UsageHTTPError.httpStatus(let status) {
        #expect(status == 500)
    }
}

@Test("UsageHTTPClient: a 2xx response returns the transport's data unchanged")
func usageHTTPClientSurfacesSuccess() async throws {
    let url = try #require(URL(string: "https://example.com/usage"))
    let payload = Data("{\"ok\":true}".utf8)
    let client = UsageHTTPClient(transport: { request in
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (payload, response)
    })
    let (data, response) = try await client.send(URLRequest(url: url), provider: .codex)
    #expect(data == payload)
    #expect(response.statusCode == 200)
}
