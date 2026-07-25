import Foundation
import Testing

@testable import RafuApp

private actor FixtureUsageSnapshotReader {
    private var readings: [[UsageSnapshot]]

    init(_ readings: [[UsageSnapshot]]) {
        self.readings = readings
    }

    func next() -> [UsageSnapshot] {
        guard !readings.isEmpty else { return [] }
        return readings.removeFirst()
    }
}

@Test("Usage meter records only resolvable positive per-window movement")
func usageMeterRecordsPositiveMovement() async throws {
    let reader = FixtureUsageSnapshotReader([
        ConductorUsageFixtures.start,
        ConductorUsageFixtures.end,
    ])
    let meter = ConductorRunUsageMeter { _ in await reader.next() }

    let start = await meter.snapshot(at: ConductorUsageFixtures.startDate)
    let record = await meter.finish(
        from: start, attempt: 1, at: ConductorUsageFixtures.endDate)

    #expect(
        record
            == ConductorRunUsageRecord(
                attempt: 1,
                providers: [
                    .init(
                        providerID: .codex,
                        windows: [
                            .init(label: "5h", percentPoints: 1.2, tokens: nil)
                        ]),
                    .init(
                        providerID: .claude,
                        windows: [
                            .init(label: "5h", percentPoints: nil, tokens: 1_250)
                        ]),
                ]))
    #expect(
        start.providers.allSatisfy { provider in
            provider.windows.allSatisfy { !$0.label.contains("not copied") }
        })
}

@Test("Unstructured cost strings and no-data providers never fabricate a delta")
func usageMeterHidesUnstructuredCostMovement() {
    let record = ConductorRunUsageMeter.record(
        from: ConductorUsageFixtures.snapshot(
            date: ConductorUsageFixtures.startDate,
            values: ConductorUsageFixtures.noDataStart),
        to: ConductorUsageFixtures.snapshot(
            date: ConductorUsageFixtures.endDate,
            values: ConductorUsageFixtures.noDataEnd),
        attempt: 1)

    #expect(record == nil)
}

@Test("Sub-resolution movement, decreases, reset changes, and missing starts show nothing")
func usageMeterRejectsAmbiguousMovement() {
    let changedReset = ConductorUsageFixtures.resetDate.addingTimeInterval(60)
    let start = [
        UsageSnapshot(
            providerID: .codex,
            windows: [
                UsageWindow(label: "tiny", percent: 1, tokens: nil, resetsAt: nil),
                UsageWindow(label: "reset", percent: 60, tokens: nil, resetsAt: changedReset),
                UsageWindow(label: "decrease", percent: 80, tokens: nil, resetsAt: nil),
            ],
            costLine: nil,
            identity: nil)
    ]
    let end = [
        UsageSnapshot(
            providerID: .codex,
            windows: [
                UsageWindow(label: "tiny", percent: 1.04, tokens: nil, resetsAt: nil),
                UsageWindow(
                    label: "reset",
                    percent: 61,
                    tokens: nil,
                    resetsAt: ConductorUsageFixtures.resetDate),
                UsageWindow(label: "decrease", percent: 2, tokens: nil, resetsAt: nil),
                UsageWindow(label: "end only", percent: 4, tokens: nil, resetsAt: nil),
            ],
            costLine: nil,
            identity: nil)
    ]

    let record = ConductorRunUsageMeter.record(
        from: ConductorUsageFixtures.snapshot(
            date: ConductorUsageFixtures.startDate, values: start),
        to: ConductorUsageFixtures.snapshot(
            date: ConductorUsageFixtures.endDate, values: end),
        attempt: 1)

    #expect(record == nil)
}

@Test("Duplicate provider and window readings are rejected as ambiguous")
func usageMeterRejectsDuplicateReadings() {
    let duplicatedProviders = ConductorUsageFixtures.start + ConductorUsageFixtures.start
    let duplicatedWindow = UsageSnapshot(
        providerID: .codex,
        windows: [
            UsageWindow(label: "5h", percent: 1, tokens: nil, resetsAt: nil),
            UsageWindow(label: "5h", percent: 2, tokens: nil, resetsAt: nil),
        ],
        costLine: nil,
        identity: nil)

    #expect(
        ConductorRunUsageMeter.record(
            from: ConductorUsageFixtures.snapshot(
                date: ConductorUsageFixtures.startDate, values: duplicatedProviders),
            to: ConductorUsageFixtures.snapshot(
                date: ConductorUsageFixtures.endDate, values: ConductorUsageFixtures.end),
            attempt: 1) == nil)
    #expect(
        ConductorRunUsageMeter.record(
            from: ConductorUsageFixtures.snapshot(
                date: ConductorUsageFixtures.startDate, values: [duplicatedWindow]),
            to: ConductorUsageFixtures.snapshot(
                date: ConductorUsageFixtures.endDate, values: [duplicatedWindow]),
            attempt: 1) == nil)
}

@Test("Run totals preserve provider/window order and sum only like units")
func usageRunTotalsAndLines() {
    let records = [
        ConductorRunUsageRecord(
            attempt: 1,
            providers: [
                .init(
                    providerID: .codex,
                    windows: [.init(label: "5h", percentPoints: 1.2, tokens: nil)]),
                .init(
                    providerID: .claude,
                    windows: [.init(label: "5h", percentPoints: nil, tokens: 1_250)]),
            ]),
        ConductorRunUsageRecord(
            attempt: 1,
            providers: [
                .init(
                    providerID: .codex,
                    windows: [
                        .init(label: "5h", percentPoints: 0.8, tokens: nil),
                        .init(label: "7d", percentPoints: 0.4, tokens: nil),
                    ])
            ]),
    ]

    let totals = ConductorRunUsagePresentation.runTotals(from: records)

    #expect(
        totals
            == [
                .init(
                    providerID: .codex,
                    windows: [
                        .init(label: "5h", percentPoints: 2, tokens: nil),
                        .init(label: "7d", percentPoints: 0.4, tokens: nil),
                    ]),
                .init(
                    providerID: .claude,
                    windows: [.init(label: "5h", percentPoints: nil, tokens: 1_250)]),
            ])
    #expect(ConductorRunUsagePresentation.line(for: totals[0]) == "Codex • 5h ~2% • 7d ~0.4%")
    #expect(
        ConductorRunUsagePresentation.line(for: totals[1])
            == "Claude • 5h 1250 tokens")
}

@Test("Usage records round-trip through the manifest-compatible Codable shape")
func usageRecordCodableRoundTrip() throws {
    let record = ConductorRunUsageRecord(
        attempt: 2,
        providers: [
            .init(
                providerID: .codex,
                windows: [.init(label: "5h", percentPoints: 1.5, tokens: nil)])
        ])

    let data = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(ConductorRunUsageRecord.self, from: data)

    #expect(decoded == record)
}
