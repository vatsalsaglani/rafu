// Adapted from CodexBar's BrowserCookieAccessGate, MIT License.
// Rafu intentionally keeps only an in-memory, per-browser circuit breaker:
// there is no UserDefaults persistence, timer, background retry, or
// Chromium-family-wide suppression.

import Foundation

nonisolated struct CookieAccessPolicy: Equatable, Sendable {
    static let standard = CookieAccessPolicy(
        failureThreshold: 3,
        cooldown: 15 * 60)

    let failureThreshold: Int
    let cooldown: TimeInterval

    init(failureThreshold: Int, cooldown: TimeInterval) {
        self.failureThreshold = max(1, failureThreshold)
        self.cooldown = max(0, cooldown)
    }
}

nonisolated enum CookieAccessDecision: Equatable, Sendable {
    case allowed
    case importAlreadyInProgress
    case backedOff(until: Date, lastFailure: BrowserCookieAccessFailure)
}

/// Consecutive read/access failures trip a bounded cooldown independently for
/// each browser. Missing stores and successful empty queries never count as
/// failures; callers record those as success/no-store without touching this
/// gate. State dies with the process by design.
actor CookieAccessGate {
    nonisolated static let shared = CookieAccessGate()

    private struct FailureState: Sendable {
        var consecutiveFailures: Int
        var blockedUntil: Date?
        var lastFailure: BrowserCookieAccessFailure
    }

    private let policy: CookieAccessPolicy
    private var failures: [Browser: FailureState] = [:]
    private var attemptsInProgress: Set<Browser> = []

    init(policy: CookieAccessPolicy = .standard) {
        self.policy = policy
    }

    /// Atomically reserves one browser import attempt. This prevents two
    /// Settings actions from racing into duplicate Keychain/TCC prompts.
    func beginAttempt(for browser: Browser, now: Date = Date()) -> CookieAccessDecision {
        guard !attemptsInProgress.contains(browser) else {
            return .importAlreadyInProgress
        }
        if var state = failures[browser], let blockedUntil = state.blockedUntil {
            if blockedUntil > now {
                return .backedOff(until: blockedUntil, lastFailure: state.lastFailure)
            }
            state.consecutiveFailures = 0
            state.blockedUntil = nil
            failures[browser] = state
        }
        attemptsInProgress.insert(browser)
        return .allowed
    }

    func recordFailure(
        _ failure: BrowserCookieAccessFailure,
        for browser: Browser,
        now: Date = Date()
    ) {
        attemptsInProgress.remove(browser)
        var state =
            failures[browser]
            ?? FailureState(
                consecutiveFailures: 0,
                blockedUntil: nil,
                lastFailure: failure)
        state.consecutiveFailures += 1
        state.lastFailure = failure
        if state.consecutiveFailures >= policy.failureThreshold {
            state.blockedUntil = now.addingTimeInterval(policy.cooldown)
        }
        failures[browser] = state
    }

    func recordSuccess(for browser: Browser) {
        attemptsInProgress.remove(browser)
        failures.removeValue(forKey: browser)
    }

    /// Releases a reservation without changing consecutive-failure state.
    /// Missing stores and cancellation are neither success nor access failure.
    func cancelAttempt(for browser: Browser) {
        attemptsInProgress.remove(browser)
    }

    func reset(for browser: Browser) {
        attemptsInProgress.remove(browser)
        failures.removeValue(forKey: browser)
    }
}
