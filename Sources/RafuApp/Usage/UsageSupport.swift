import Foundation

/// Shared, provider-agnostic support for the usage pipeline
/// (usage-providers/W0-shim.md): compact token-count formatting, a bounded
/// ISO-8601-fractional date parser, the bounded local-file readers the
/// shipped Claude/Codex strategies depend on, and a redacting, 429-aware
/// HTTP client every future network strategy shares. Every pure
/// static/member lives directly in its type's PRIMARY declaration (never a
/// bare `extension`) for the reason documented on `UsageProviderCore.swift`.

/// `999` → `"999"`, `1_234` → `"1.2K"`, `1_234_567` → `"1.2M"` — moved
/// unchanged from the shipped `AgentUsageFormat` (terminal-notch-hud.md
/// NC-D: "1_234_567 → \"1.2M\"").
nonisolated enum UsageFormat {
    /// Rounds to one decimal place and drops a trailing `.0` (`1_000` →
    /// `"1K"`, not `"1.0K"`). Identical output to the pre-W0
    /// `AgentUsageFormat.compactTokenCount`.
    static func compactTokenCount(_ value: Int) -> String {
        let magnitude = abs(value)
        switch magnitude {
        case ..<1_000:
            return "\(value)"
        case ..<1_000_000:
            return scaled(value, by: 1_000, suffix: "K")
        default:
            return scaled(value, by: 1_000_000, suffix: "M")
        }
    }

    private static func scaled(_ value: Int, by divisor: Double, suffix: String) -> String {
        let rounded = ((Double(value) / divisor) * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded))\(suffix)"
        }
        return String(format: "%.1f%@", rounded, suffix)
    }
}

/// The ISO-8601-with-fractional-seconds parser moved from the shipped
/// `ClaudeUsageParser` (verified shape 2026-07-22: Claude transcript
/// timestamps look like `"2026-07-13T04:57:21.205Z"`, which the default
/// `ISO8601DateFormatter` configuration rejects outright).
nonisolated enum UsageDateParsing {
    static func parseISO8601Fractional(_ string: String) -> Date? {
        Self.fractionalFormatter.date(from: string) ?? Self.formatter.date(from: string)
    }

    /// A fresh formatter per call — `ISO8601DateFormatter` is not
    /// `Sendable`, so a cached `static let` trips Swift 6 strict-concurrency
    /// global-state checking (matches `ISO8601DateFormatter.git`'s
    /// convention, `GitHistoryParser.swift`). Cheap to construct; every
    /// caller here already bounds how many timestamps it parses.
    private static var fractionalFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static var formatter: ISO8601DateFormatter {
        ISO8601DateFormatter()
    }
}

/// The ONLY file-touching type in the shared support layer — every parser
/// downstream (`ClaudeProvider`, `CodexProvider`) is pure over
/// already-read strings/lines. Moved unchanged (including every cap) from
/// the shipped `AgentUsageReader`'s "Production file access"/"Filesystem
/// helpers" sections. Kept OUTSIDE `UsageFetchContext.readFile` — see that
/// type's doc comment for why a single-file reader cannot express these
/// bounded multi-file directory scans.
///
/// Privacy (terminal-notch-hud.md, "Data sources"; agent-usage-providers.md
/// "The trust transition"): read-only, local-only, no logging. Only token
/// counts, percentages, `window_minutes`, and timestamps are ever parsed —
/// never prompt/response text.
nonisolated enum LocalUsageFiles {
    /// Newest-by-mtime Claude transcript files considered per scan.
    static let maxClaudeTranscriptFiles = 30
    /// Bytes read from the TAIL of each considered transcript.
    static let maxBytesPerClaudeFile = 256 * 1_024
    /// Bytes read from the TAIL of the newest Codex rollout file.
    static let maxBytesPerCodexFile = 256 * 1_024

    private static var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// The newest `rollout-*.jsonl` anywhere under `~/.codex/sessions`,
    /// tail-read (the newest `rate_limits` snapshot is at the end) and
    /// bounded to exactly one file.
    static func newestCodexRollout() -> String? {
        let sessionsDirectory = homeDirectory.appending(
            path: ".codex/sessions", directoryHint: .isDirectory)
        guard
            let newestURL = newestFile(
                under: sessionsDirectory,
                matching: { url in
                    url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl"
                })
        else { return nil }
        let tail = tailLines(of: newestURL, maxBytes: maxBytesPerCodexFile)
        return tail.isEmpty ? nil : tail.joined(separator: "\n")
    }

    /// The newest `maxClaudeTranscriptFiles` `*.jsonl` files anywhere under
    /// `~/.claude/projects` modified within the trailing 7-day window, each
    /// capped to its last `maxBytesPerClaudeFile` bytes.
    static func recentClaudeTranscriptLines(now: Date) -> [String] {
        let projectsDirectory = homeDirectory.appending(
            path: ".claude/projects", directoryHint: .isDirectory)
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let candidates = filesSortedByModificationDate(
            under: projectsDirectory, matching: { $0.pathExtension == "jsonl" },
            modifiedOnOrAfter: cutoff
        )
        var lines: [String] = []
        for url in candidates.prefix(maxClaudeTranscriptFiles) {
            lines.append(contentsOf: tailLines(of: url, maxBytes: maxBytesPerClaudeFile))
        }
        return lines
    }

    // MARK: - Filesystem helpers

    static func newestFile(
        under directory: URL, matching predicate: (URL) -> Bool
    ) -> URL? {
        var newestURL: URL?
        var newestDate = Date.distantPast
        enumerateFiles(under: directory) { url, modificationDate in
            guard predicate(url) else { return }
            if modificationDate > newestDate {
                newestDate = modificationDate
                newestURL = url
            }
        }
        return newestURL
    }

    static func filesSortedByModificationDate(
        under directory: URL, matching predicate: (URL) -> Bool, modifiedOnOrAfter cutoff: Date
    ) -> [URL] {
        var results: [(url: URL, date: Date)] = []
        enumerateFiles(under: directory) { url, modificationDate in
            guard predicate(url), modificationDate >= cutoff else { return }
            results.append((url, modificationDate))
        }
        return results.sorted { $0.date > $1.date }.map(\.url)
    }

    static func enumerateFiles(under directory: URL, _ body: (URL, Date) -> Void) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            )
        else { return }
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: keys),
                values.isRegularFile == true,
                let modificationDate = values.contentModificationDate
            else { continue }
            body(url, modificationDate)
        }
    }

    /// Reads at most `maxBytes` from the END of `url`. When the tail read
    /// did not start at the true beginning of the file, the first line is
    /// discarded as possibly truncated mid-object.
    static func tailLines(of url: URL, maxBytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else { return [] }
        let readSize = min(Int(fileSize), maxBytes)
        let offset = fileSize - UInt64(readSize)
        guard (try? handle.seek(toOffset: offset)) != nil,
            let data = try? handle.read(upToCount: readSize),
            let text = String(data: data, encoding: .utf8)
        else { return [] }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if offset > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        return lines
    }
}

/// A local strategy's "nothing to show this refresh" outcome — thrown
/// rather than returning an empty/absent snapshot so it flows through the
/// same `resolveUsageSnapshot` error path every network strategy uses.
/// Carries no diagnostic payload (nothing to redact).
nonisolated enum UsageLocalDataError: Error, Sendable, Equatable {
    case noData
}

/// Every network-facing failure a `UsageFetchStrategy` can throw from
/// `UsageHTTPClient.send`. STRUCTURALLY cannot carry a token, header, or
/// response body — there is no case with an associated string/data payload
/// wide enough to smuggle a credential, so `String(describing:)` on any
/// case is safe to put in a log or surfaced error message.
nonisolated enum UsageHTTPError: Error, Sendable, Equatable {
    case rateLimited(retryAfter: TimeInterval?)
    case httpStatus(Int)
    case timedOut
    case transportFailure
    case invalidResponse
}

/// A bounded, redacting HTTP client every network usage strategy shares
/// (usage-providers/W0-shim.md): injectable transport for tests, a 15s
/// default timeout, and a per-provider in-memory 429 `Retry-After` gate so
/// a rate-limited provider backs off instead of hammering the endpoint on
/// the next refresh tick.
nonisolated final class UsageHTTPClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// A transport that always fails — used where a real network call must
    /// never happen (Settings' provider-visibility probe context, and any
    /// test not exercising the HTTP path).
    static let noop = UsageHTTPClient(transport: { _ in throw UsageHTTPError.transportFailure })

    private let timeout: TimeInterval
    private let transport: Transport
    private let rateLimitGate = RateLimitGate()

    init(
        timeout: TimeInterval = 15,
        transport: @escaping Transport = UsageHTTPClient.urlSessionTransport
    ) {
        self.timeout = timeout
        self.transport = transport
    }

    /// Sends `request` on behalf of `provider`, honoring an active
    /// Retry-After gate for that provider and recording a fresh one on a
    /// 429 response. Only ever throws `UsageHTTPError` — the underlying
    /// transport's error (which could carry request/response detail) is
    /// deliberately discarded, never wrapped or logged, so no header,
    /// token, or body can leak through a thrown error.
    func send(_ request: URLRequest, provider: UsageProviderID) async throws -> (
        Data, HTTPURLResponse
    ) {
        if let retryAfter = await rateLimitGate.activeRetryAfter(for: provider) {
            throw UsageHTTPError.rateLimited(retryAfter: retryAfter)
        }
        var boundedRequest = request
        boundedRequest.timeoutInterval = timeout
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport(boundedRequest)
        } catch let httpError as UsageHTTPError {
            throw httpError
        } catch {
            if (error as NSError).code == NSURLErrorTimedOut {
                throw UsageHTTPError.timedOut
            }
            throw UsageHTTPError.transportFailure
        }
        if response.statusCode == 429 {
            let retryAfter = Self.parseRetryAfter(response)
            await rateLimitGate.setRetryAfter(retryAfter, for: provider)
            throw UsageHTTPError.rateLimited(retryAfter: retryAfter)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw UsageHTTPError.httpStatus(response.statusCode)
        }
        return (data, response)
    }

    static func urlSessionTransport(_ request: URLRequest) async throws -> (
        Data, HTTPURLResponse
    ) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageHTTPError.invalidResponse
        }
        return (data, httpResponse)
    }

    private static func parseRetryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        return TimeInterval(value)
    }
}

/// Per-provider in-memory 429 backoff state. An `actor` (never
/// `@unchecked Sendable`) so `UsageHTTPClient` stays a plain `Sendable`
/// class while still safely sharing this mutable gate across concurrent
/// refreshes.
private actor RateLimitGate {
    private var retryUntil: [UsageProviderID: Date] = [:]

    func activeRetryAfter(for provider: UsageProviderID) -> TimeInterval? {
        guard let until = retryUntil[provider] else { return nil }
        let remaining = until.timeIntervalSinceNow
        guard remaining > 0 else {
            retryUntil.removeValue(forKey: provider)
            return nil
        }
        return remaining
    }

    func setRetryAfter(_ interval: TimeInterval?, for provider: UsageProviderID) {
        guard let interval, interval > 0 else { return }
        retryUntil[provider] = Date().addingTimeInterval(interval)
    }
}
