import Foundation

/// A bounded, in-memory reading taken at one Ensemble step boundary.
///
/// This deliberately copies only provider identity plus usage-window
/// numbers. Account identity, credentials, and provider `costLine` strings
/// never enter run accounting: `costLine` is presentation text rather than a
/// structured counter, so subtracting it would require guessing.
nonisolated struct ConductorRunUsageSnapshot: Equatable, Sendable {
    let capturedAt: Date
    let providers: [ProviderReading]

    nonisolated struct ProviderReading: Equatable, Sendable {
        let providerID: UsageProviderID
        let windows: [WindowReading]
    }

    nonisolated struct WindowReading: Equatable, Sendable {
        let label: String
        let percent: Double?
        let tokens: Int?
        let resetsAt: Date?
    }

    init(capturedAt: Date, snapshots: [UsageSnapshot]) {
        self.capturedAt = capturedAt
        providers = snapshots.map { snapshot in
            ProviderReading(
                providerID: snapshot.providerID,
                windows: snapshot.windows.map { window in
                    WindowReading(
                        label: window.label,
                        percent: window.percent,
                        tokens: window.tokens,
                        resetsAt: window.resetsAt)
                })
        }
    }
}

/// Honest usage attributed to one attempt of one run step.
///
/// A missing record means the two readings had no resolvable positive
/// movement. It never means zero usage: providers can be unavailable, a
/// window can reset during the step, and short steps can finish below a
/// provider's measurement resolution.
nonisolated struct ConductorRunUsageRecord: Codable, Equatable, Sendable {
    let attempt: Int
    let providers: [ProviderDelta]

    nonisolated struct ProviderDelta: Codable, Equatable, Sendable {
        let providerID: UsageProviderID
        let windows: [WindowDelta]
    }

    nonisolated struct WindowDelta: Codable, Equatable, Sendable {
        let label: String
        /// Percentage-point movement in a provider's "used" window.
        let percentPoints: Double?
        let tokens: Int?
    }
}

/// Reads the existing usage registry at step boundaries and derives a
/// best-effort delta without crossing the metering trust boundary.
nonisolated struct ConductorRunUsageMeter: Sendable {
    typealias SnapshotReader = @Sendable (Date) async -> [UsageSnapshot]

    /// Smaller percentage movement cannot be rendered honestly at the
    /// detail surface's one-decimal precision, so it is treated as
    /// unresolved rather than displayed as a fake `0%`.
    static let minimumPercentResolution = 0.1

    private let readSnapshots: SnapshotReader

    init(reader: UsageRegistryReader = UsageRegistryReader()) {
        readSnapshots = { now in await reader.snapshots(now: now) }
    }

    init(readSnapshots: @escaping SnapshotReader) {
        self.readSnapshots = readSnapshots
    }

    func snapshot(at date: Date) async -> ConductorRunUsageSnapshot {
        let snapshots = await readSnapshots(date)
        return ConductorRunUsageSnapshot(capturedAt: date, snapshots: snapshots)
    }

    func finish(
        from start: ConductorRunUsageSnapshot,
        attempt: Int,
        at date: Date
    ) async -> ConductorRunUsageRecord? {
        let end = await snapshot(at: date)
        return Self.record(from: start, to: end, attempt: attempt)
    }

    static func record(
        from start: ConductorRunUsageSnapshot,
        to end: ConductorRunUsageSnapshot,
        attempt: Int
    ) -> ConductorRunUsageRecord? {
        guard attempt > 0, end.capturedAt >= start.capturedAt else { return nil }

        var providerDeltas: [ConductorRunUsageRecord.ProviderDelta] = []
        for startProvider in start.providers {
            guard
                start.providers.filter({ $0.providerID == startProvider.providerID }).count == 1,
                let endProvider = end.providers.first(where: {
                    $0.providerID == startProvider.providerID
                }),
                end.providers.filter({ $0.providerID == startProvider.providerID }).count == 1
            else { continue }

            var windowDeltas: [ConductorRunUsageRecord.WindowDelta] = []
            for startWindow in startProvider.windows {
                guard
                    startProvider.windows.filter({ $0.label == startWindow.label }).count == 1,
                    let endWindow = endProvider.windows.first(where: {
                        $0.label == startWindow.label
                    }),
                    endProvider.windows.filter({ $0.label == startWindow.label }).count == 1,
                    startWindow.resetsAt == endWindow.resetsAt,
                    let delta = windowDelta(from: startWindow, to: endWindow)
                else { continue }
                windowDeltas.append(delta)
            }

            if !windowDeltas.isEmpty {
                providerDeltas.append(
                    ConductorRunUsageRecord.ProviderDelta(
                        providerID: startProvider.providerID,
                        windows: windowDeltas))
            }
        }

        guard !providerDeltas.isEmpty else { return nil }
        return ConductorRunUsageRecord(attempt: attempt, providers: providerDeltas)
    }

    private static func windowDelta(
        from start: ConductorRunUsageSnapshot.WindowReading,
        to end: ConductorRunUsageSnapshot.WindowReading
    ) -> ConductorRunUsageRecord.WindowDelta? {
        if start.tokens == nil, end.tokens == nil,
            let startPercent = start.percent, let endPercent = end.percent,
            startPercent.isFinite, endPercent.isFinite,
            (0...100).contains(startPercent), (0...100).contains(endPercent)
        {
            let delta = endPercent - startPercent
            guard delta + Double.ulpOfOne >= minimumPercentResolution else { return nil }
            let resolvedDelta = (delta * 10).rounded() / 10
            return ConductorRunUsageRecord.WindowDelta(
                label: start.label, percentPoints: resolvedDelta, tokens: nil)
        }

        if start.percent == nil, end.percent == nil,
            let startTokens = start.tokens, let endTokens = end.tokens,
            startTokens >= 0, endTokens > startTokens
        {
            return ConductorRunUsageRecord.WindowDelta(
                label: start.label, percentPoints: nil, tokens: endTokens - startTokens)
        }

        return nil
    }
}

/// Presentation and per-run aggregation for persisted step records.
nonisolated enum ConductorRunUsagePresentation {
    static func runTotals(
        from records: [ConductorRunUsageRecord]
    ) -> [ConductorRunUsageRecord.ProviderDelta] {
        var totals: [ConductorRunUsageRecord.ProviderDelta] = []

        for record in records {
            for provider in record.providers {
                let providerIndex: Int
                if let existing = totals.firstIndex(where: {
                    $0.providerID == provider.providerID
                }) {
                    providerIndex = existing
                } else {
                    totals.append(
                        ConductorRunUsageRecord.ProviderDelta(
                            providerID: provider.providerID, windows: []))
                    providerIndex = totals.count - 1
                }

                var windows = totals[providerIndex].windows
                for delta in provider.windows {
                    if let windowIndex = windows.firstIndex(where: { $0.label == delta.label }) {
                        let existing = windows[windowIndex]
                        windows[windowIndex] = ConductorRunUsageRecord.WindowDelta(
                            label: delta.label,
                            percentPoints: sum(existing.percentPoints, delta.percentPoints),
                            tokens: sum(existing.tokens, delta.tokens))
                    } else {
                        windows.append(delta)
                    }
                }
                totals[providerIndex] = ConductorRunUsageRecord.ProviderDelta(
                    providerID: provider.providerID, windows: windows)
            }
        }

        return totals
    }

    static func line(for provider: ConductorRunUsageRecord.ProviderDelta) -> String? {
        let windows = provider.windows.compactMap(windowText)
        guard !windows.isEmpty else { return nil }
        return "\(providerName(provider.providerID)) • \(windows.joined(separator: " • "))"
    }

    private static func windowText(
        _ window: ConductorRunUsageRecord.WindowDelta
    ) -> String? {
        if let percent = window.percentPoints, percent.isFinite, percent > 0 {
            let formatted =
                percent >= 1
                ? String(
                    format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), percent)
                : String(
                    format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), percent)
            return "\(window.label) ~\(formatted)%"
        }
        if let tokens = window.tokens, tokens > 0 {
            return "\(window.label) \(tokens) tokens"
        }
        return nil
    }

    private static func providerName(_ id: UsageProviderID) -> String {
        UsageProviderRegistry.descriptor(for: id)?.displayName ?? id.rawValue
    }

    private static func sum(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard lhs != nil || rhs != nil else { return nil }
        return (lhs ?? 0) + (rhs ?? 0)
    }

    private static func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard lhs != nil || rhs != nil else { return nil }
        return (lhs ?? 0) + (rhs ?? 0)
    }
}
