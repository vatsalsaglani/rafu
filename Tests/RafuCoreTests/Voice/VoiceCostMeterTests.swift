import Foundation
import Testing

@testable import RafuCore

@Suite("Voice cost meter")
struct VoiceCostMeterTests {
    @Test("Keeps the largest reported seconds per session")
    func maximumPerSession() {
        var meter = VoiceCostMeter()
        meter.recordUsage(sessionID: "a", seconds: 15.5, month: "2026-11")
        meter.recordUsage(sessionID: "a", seconds: 30, month: "2026-11")
        meter.recordUsage(sessionID: "a", seconds: 12, month: "2026-11")
        meter.recordUsage(sessionID: "b", seconds: 60, month: "2026-11")
        #expect(meter.monthlySeconds(month: "2026-11") == 90)
        meter.finish(sessionID: "a")
        meter.finish(sessionID: "a")
        #expect(meter.monthlySeconds(month: "2026-11") == 90)
    }

    @Test("Cost is $0.05 a minute and months roll over")
    func costAndMonths() {
        var meter = VoiceCostMeter()
        meter.recordUsage(sessionID: "a", seconds: 600, month: "2026-11")
        meter.finish(sessionID: "a")
        #expect(abs(meter.monthlyCost(month: "2026-11") - 0.5) < 0.000_1)
        #expect(meter.monthlySeconds(month: "2026-12") == 0)
        meter.recordUsage(sessionID: "b", seconds: 60, month: "2026-12")
        #expect(meter.monthlySeconds(month: "2026-12") == 60)
        #expect(meter.monthlySeconds(month: "2026-11") == 600)
    }

    @Test("The cap blocks a new session once reached")
    func cap() {
        var meter = VoiceCostMeter()
        #expect(meter.allowsNewSession(cap: 5, month: "2026-11"))
        meter.recordUsage(sessionID: "a", seconds: 100 * 60, month: "2026-11")
        #expect(!meter.allowsNewSession(cap: 5, month: "2026-11"))
        #expect(meter.allowsNewSession(cap: 6, month: "2026-11"))
        #expect(meter.allowsNewSession(cap: 5, month: "2026-12"))
    }

    @Test("Bad values are ignored and the snapshot round-trips")
    func codable() throws {
        var meter = VoiceCostMeter()
        meter.recordUsage(sessionID: "a", seconds: .nan, month: "2026-11")
        meter.recordUsage(sessionID: "a", seconds: -4, month: "2026-11")
        meter.recordUsage(sessionID: "b", seconds: 30, month: "2026-11")
        let decoded = try JSONDecoder().decode(
            VoiceCostMeter.self, from: JSONEncoder().encode(meter))
        #expect(decoded == meter)
        #expect(decoded.monthlySeconds(month: "2026-11") == 30)
    }

    @Test("Many open sessions are folded, not lost")
    func folding() {
        var meter = VoiceCostMeter()
        for index in 0..<40 {
            meter.recordUsage(sessionID: "s\(index)", seconds: 10, month: "2026-11")
        }
        #expect(meter.monthlySeconds(month: "2026-11") == 400)
    }

    @Test("Month keys are year and month")
    func monthKey() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        #expect(VoiceCostMeter.monthKey(for: date, calendar: calendar) == "2026-10")
    }
}
