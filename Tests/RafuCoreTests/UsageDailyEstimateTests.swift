import Foundation
import Testing

@testable import RafuCore

// Widget W3: when the day split is an estimate. Every test passes its own
// clock; nothing reads the real clock, `~`, or the network.

private let estimateStart = Date(timeIntervalSince1970: 1_784_800_800)
private let estimateReset = estimateStart.addingTimeInterval(7 * 86_400)

private func at(_ days: Double) -> Date { estimateStart.addingTimeInterval(days * 86_400) }

private func record(_ used: Double, _ time: Date) -> UsageSampleRecord {
    UsageSampleRecord(
        providerID: "claude", window: "7d", usedPercent: used, resetsAt: estimateReset,
        observedAt: time)
}

private func breakdown(_ records: [UsageSampleRecord], current: Double, at observed: Date)
    throws -> UsageDailyBreakdown
{
    try #require(
        UsageDailyBreakdown.make(
            records: records, providerID: "claude", window: "7d", currentPercent: current,
            observedAt: observed, resetsAt: estimateReset, windowMinutes: 10_080))
}

@Suite("Usage daily breakdown estimate")
struct UsageDailyEstimateTests {
    @Test("A log every 15 minutes from the window start is exact")
    func denseLog() throws {
        let records = (1..<240).map { index in
            record(Double(index) / 10, estimateStart.addingTimeInterval(Double(index) * 900))
        }
        let result = try breakdown(records, current: 24, at: at(2.5))
        #expect(!result.estimated)
    }

    @Test("A log that starts days after the window start is an estimate")
    func lateStart() throws {
        let records = [record(20, at(3)), record(21, at(3.01))]
        let result = try breakdown(records, current: 22, at: at(3.02))
        #expect(result.estimated)
    }

    @Test("A late first record inside day 1 is exact")
    func lateStartSameDay() throws {
        let records = [record(2, at(0.2)), record(3, at(0.21))]
        let result = try breakdown(records, current: 3, at: at(0.22))
        #expect(!result.estimated)
    }

    @Test("A gap across a day boundary with usage in it is an estimate")
    func gapWithUse() throws {
        let records = [record(5, at(0.9)), record(12, at(1.3))]
        let result = try breakdown(records, current: 12, at: at(1.31))
        #expect(result.estimated)
    }

    @Test("A gap across a day boundary with no usage is exact")
    func gapWithoutUse() throws {
        let records = [record(5, at(0.9)), record(5, at(1.3))]
        let result = try breakdown(records, current: 5, at: at(1.31))
        #expect(!result.estimated)
    }

    @Test("A gap of more than 2 hours inside one day is exact")
    func gapInsideDay() throws {
        // Idle until the end of day 1, then samples close together across
        // the boundary, then a 10-hour gap inside day 2.
        let records = [
            record(0, at(0.95)), record(1, at(1.01)), record(5, at(1.08)), record(9, at(1.5)),
        ]
        let result = try breakdown(records, current: 9, at: at(1.51))
        #expect(!result.estimated)
    }

    @Test("A short span across a day boundary is exact")
    func shortSpanAcrossBoundary() throws {
        let records = [
            record(5, at(1).addingTimeInterval(-1_800)), record(6, at(1).addingTimeInterval(1_800)),
        ]
        let result = try breakdown(records, current: 6, at: at(1).addingTimeInterval(2_700))
        // The span from the window start to the first record rises too,
        // but it ends inside day 1.
        #expect(!result.estimated)
    }
}
