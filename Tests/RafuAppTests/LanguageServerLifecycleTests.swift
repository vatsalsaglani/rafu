import Testing

@testable import RafuApp

@Test("Backoff escalates 1s, 5s, 30s then goes manual-only")
func backoffScheduleEscalatesThenGoesManual() {
    let policy = RestartBackoffPolicy()
    #expect(policy.delay(afterConsecutiveCrashes: 1) == .seconds(1))
    #expect(policy.delay(afterConsecutiveCrashes: 2) == .seconds(5))
    #expect(policy.delay(afterConsecutiveCrashes: 3) == .seconds(30))
    #expect(policy.delay(afterConsecutiveCrashes: 4) == nil)
}

@Test("Backoff declines for zero or negative crash counts")
func backoffDeclinesBelowOne() {
    let policy = RestartBackoffPolicy()
    #expect(policy.delay(afterConsecutiveCrashes: 0) == nil)
    #expect(policy.delay(afterConsecutiveCrashes: -1) == nil)
}

@Test("A custom schedule is honored verbatim")
func backoffHonorsCustomSchedule() {
    let policy = RestartBackoffPolicy(schedule: [.milliseconds(10)])
    #expect(policy.delay(afterConsecutiveCrashes: 1) == .milliseconds(10))
    #expect(policy.delay(afterConsecutiveCrashes: 2) == nil)
}

@Test("RSSCeilingDecision never breaches on a nil reading")
func rssCeilingDeclinesOnNilReading() {
    #expect(RSSCeilingDecision.exceedsCeiling(residentBytes: nil, ceiling: 100) == false)
}

@Test("RSSCeilingDecision never breaches when the ceiling is disabled (0)")
func rssCeilingDeclinesWhenDisabled() {
    #expect(RSSCeilingDecision.exceedsCeiling(residentBytes: .max, ceiling: 0) == false)
}

@Test("RSSCeilingDecision breaches only strictly above a positive ceiling")
func rssCeilingBreachesOnlyAboveCeiling() {
    #expect(RSSCeilingDecision.exceedsCeiling(residentBytes: 100, ceiling: 100) == false)
    #expect(RSSCeilingDecision.exceedsCeiling(residentBytes: 101, ceiling: 100) == true)
}
