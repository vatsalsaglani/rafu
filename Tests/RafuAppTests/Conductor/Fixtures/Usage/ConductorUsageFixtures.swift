import Foundation

@testable import RafuApp

enum ConductorUsageFixtures {
    static let startDate = Date(timeIntervalSince1970: 1_700_000_000)
    static let endDate = startDate.addingTimeInterval(90)
    static let resetDate = startDate.addingTimeInterval(3_600)

    static let start = [
        UsageSnapshot(
            providerID: .codex,
            windows: [
                UsageWindow(
                    label: "5h", percent: 12.4, tokens: nil, resetsAt: resetDate),
                UsageWindow(
                    label: "7d", percent: 30, tokens: nil, resetsAt: nil),
            ],
            costLine: nil,
            identity: "not copied into the run"),
        UsageSnapshot(
            providerID: .claude,
            windows: [
                UsageWindow(label: "5h", percent: nil, tokens: 10_000, resetsAt: nil)
            ],
            costLine: nil,
            identity: nil),
    ]

    static let end = [
        UsageSnapshot(
            providerID: .codex,
            windows: [
                UsageWindow(
                    label: "5h", percent: 13.6, tokens: nil, resetsAt: resetDate),
                UsageWindow(
                    label: "7d", percent: 30.04, tokens: nil, resetsAt: nil),
            ],
            costLine: nil,
            identity: nil),
        UsageSnapshot(
            providerID: .claude,
            windows: [
                UsageWindow(label: "5h", percent: nil, tokens: 11_250, resetsAt: nil)
            ],
            costLine: nil,
            identity: nil),
    ]

    static let noDataStart = [
        UsageSnapshot(
            providerID: .openRouter,
            windows: [],
            costLine: "$1.00 of $10",
            identity: nil)
    ]

    static let noDataEnd = [
        UsageSnapshot(
            providerID: .openRouter,
            windows: [],
            costLine: "$1.25 of $10",
            identity: nil)
    ]

    static func snapshot(
        date: Date,
        values: [UsageSnapshot]
    ) -> ConductorRunUsageSnapshot {
        ConductorRunUsageSnapshot(capturedAt: date, snapshots: values)
    }
}
