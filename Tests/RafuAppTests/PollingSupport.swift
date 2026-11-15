import Foundation
import Testing

/// Shared bounded polling for tests that wait on a background task, an actor,
/// or a real OS notification.
///
/// Rules (see `docs/references/time-sensitive-tests.md`):
///
/// - The bound is a wall-clock deadline, never an iteration count. A
///   yield-count budget measures how fast a loaded machine spins, not how long
///   the work needs: under load it ends in seconds while the work is still
///   starved.
/// - The deadline is generous (120 s). It is a failure bound only; a passing
///   test returns as soon as the condition holds.
/// - After a short run of yields the loop sleeps a millisecond between checks,
///   so the work it waits for gets the CPU.
///
/// A negative assertion ("nothing happens") has nothing to poll for. Do not
/// use these helpers for it.
enum TestPolling {
    /// Failure deadline. Generous on purpose.
    static let deadline: Duration = .seconds(120)
    /// Cheap cooperative yields before the loop starts sleeping.
    static let yieldRun = 1_000
    /// Sleep between checks once the yield run is spent.
    static let pollSleep: Duration = .milliseconds(1)
}

/// Polls `predicate` until it is `true` or `timeout` of wall-clock time
/// passes. Returns the last result. The predicate runs on the caller's actor.
func waitUntil(
    timeout: Duration = TestPolling.deadline,
    isolation: isolated (any Actor)? = #isolation,
    _ predicate: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    var spins = 0
    while true {
        if await predicate() { return true }
        guard ContinuousClock.now < deadline, !Task.isCancelled else { return false }
        spins += 1
        if spins < TestPolling.yieldRun {
            await Task.yield()
        } else {
            try? await Task.sleep(for: TestPolling.pollSleep)
        }
    }
}

/// Waits until `condition` holds. Records an issue and throws
/// `CancellationError` when the deadline passes, so the test stops at the
/// real cause instead of failing later on a missing precondition.
func until(
    _ label: String = "condition",
    timeout: Duration = TestPolling.deadline,
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async throws {
    if await waitUntil(timeout: timeout, isolation: isolation, condition) { return }
    Issue.record("Timed out waiting for \(label)")
    throw CancellationError()
}

/// `waitUntil` for a predicate that reads `@MainActor` state synchronously,
/// called from a test that is not itself `@MainActor`. The predicate hops to
/// the main actor on each check.
func waitUntilOnMain(
    timeout: Duration = TestPolling.deadline,
    _ predicate: @MainActor () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    var spins = 0
    while true {
        if await predicate() { return true }
        guard ContinuousClock.now < deadline, !Task.isCancelled else { return false }
        spins += 1
        if spins < TestPolling.yieldRun {
            await Task.yield()
        } else {
            try? await Task.sleep(for: TestPolling.pollSleep)
        }
    }
}
