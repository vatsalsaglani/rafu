import Foundation

/// The restart backoff schedule after consecutive, close-together crashes:
/// 1 s, 5 s, 30 s, then manual-restart-only. Index `n - 1` of `schedule`
/// answers "how long to wait before letting `LanguageServerManager`
/// lazily respawn after the `n`th consecutive crash"; once `n` exceeds
/// `schedule.count`, `delay(afterConsecutiveCrashes:)` returns `nil` —
/// meaning no further automatic restart is attempted, only
/// `LanguageServerManager.restart(languageID:)` (a user action, C4) can
/// bring the server back.
nonisolated struct RestartBackoffPolicy: Sendable {
    var schedule: [Duration] = [.seconds(1), .seconds(5), .seconds(30)]

    /// `nil` for `n <= 0` (nothing to back off from yet) and for `n` past
    /// the end of `schedule` (backoff exhausted — manual restart only).
    func delay(afterConsecutiveCrashes n: Int) -> Duration? {
        guard n >= 1, n <= schedule.count else { return nil }
        return schedule[n - 1]
    }
}

/// Configurable ceilings and timers governing one language server's
/// lifecycle, all independently overridable for tests.
nonisolated struct LanguageServerLifecycleBounds: Sendable {
    /// How long a server may sit with no open-document activity before
    /// `LanguageServerManager` shuts it down. Reset on every
    /// `documentOpened`/`documentChanged`/`ensureSession` call for its
    /// languageID — never a repeating timer.
    var idleTimeout: Duration = .seconds(300)

    /// How long a server must stay alive before an unexpected death is
    /// treated as a *fresh* crash (resetting `consecutiveCrashes` before
    /// counting this one) rather than an escalation of a prior crash loop.
    /// A server that crashes again immediately after this reset still
    /// starts its own new escalation from crash 1 — it does not average
    /// out with prior fast crashes.
    var stabilityThreshold: Duration = .seconds(30)

    var backoff = RestartBackoffPolicy()

    /// Default resident-memory ceiling in bytes when
    /// `ResolvedLanguageServer.rssCeilingBytes` is `nil`: 4 GB.
    var defaultRSSCeilingBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024

    /// How often the watchdog samples `ProcessResourceRegistry` for every
    /// live server's resident memory.
    var sampleInterval: Duration = .seconds(5)
}

/// Pure ceiling-breach arithmetic, kept free of any process/registry
/// dependency so it's trivially unit-testable. A `nil` reading (the pid
/// has already exited, or hasn't reported yet) is never a breach — death is
/// detected exclusively through `SpawnedLanguageServer.awaitTermination()`,
/// never inferred from a missing resident-memory sample. A `ceiling` of
/// `0` disables the ceiling entirely (also never a breach), matching
/// "no ceiling configured" rather than "always breach."
nonisolated enum RSSCeilingDecision {
    static func exceedsCeiling(residentBytes: UInt64?, ceiling: UInt64) -> Bool {
        guard let residentBytes, ceiling != 0 else { return false }
        return residentBytes > ceiling
    }
}

/// A snapshot of one language server's lifecycle state, safe to surface in
/// UI (a future C4 status row) or hand to a `@MainActor` observable store —
/// never document text or server request/response payloads.
nonisolated struct LanguageServerStatus: Sendable, Equatable {
    nonisolated enum Phase: Sendable, Equatable {
        case starting
        case ready
        case idle
        case warmingUp
        case backingOff
        case dead
        case ceilingKilled
    }

    let languageID: String
    let serverName: String
    let phase: Phase
    let residentBytes: UInt64?
    let consecutiveCrashes: Int

    /// Whether an edit-subscription loop should copy the document's full
    /// text and forward a change to `LanguageServerManager` for a
    /// languageID currently at `phase` (`nil` when no status has ever been
    /// published for it). Forwarding is worthwhile only while a server is
    /// live or on its way to being live — `.starting` is included
    /// deliberately: it is pushed at the very top of `ensureSession`,
    /// before the process spawns, so a store read that only recognized
    /// `.ready` would still copy-and-drop every keystroke during the
    /// startup window. `.idle`/`.backingOff`/`.dead`/`.ceilingKilled` (and
    /// no status at all) mean there is nowhere for the change to go right
    /// now; `LanguageServerManager` replays full `didOpen` snapshots for
    /// every open URI when a server later starts, so skipped deltas are
    /// never needed.
    nonisolated static func forwardsDocumentChanges(phase: Phase?) -> Bool {
        switch phase {
        case .starting, .ready, .warmingUp:
            return true
        case .idle, .backingOff, .dead, .ceilingKilled, nil:
            return false
        }
    }
}
