import Foundation
import RafuCore

/// Settings ▸ Ensemble: "Confirm Rafu's development-channel prompt automatically".
/// A plain preference; default on, effective only while the board's Agent
/// control is Allow.
nonisolated enum CanvasChannelPromptPreference {
    static let key = "ensemble.confirmChannelPrompt"

    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

/// Answers Claude Code's "Loading development channels" dialog for Rafu's own
/// channel, once per launch (ADR 0026).
///
/// The launch record is the trigger: `CanvasLiveBridge` calls `recordLaunch`
/// only when Rafu's own `claude` launcher announces a start with the Rafu
/// channel flag over the terminal's private token. Nothing here starts from
/// terminal output. From that moment one task samples the terminal's visible
/// rows at most four times a second for at most 30 s, sends one Return when
/// `CanvasChannelPrompt.matches` sees the exact dialog, and ends. No timer runs
/// outside that window. It never logs or keeps terminal content.
@MainActor
final class CanvasChannelPromptConfirmer {
    static let shared = CanvasChannelPromptConfirmer()

    /// Everything the watch needs from one terminal and its board.
    struct Hooks {
        var mode: @MainActor () -> CanvasAgentControlMode
        var settingOn: @MainActor () -> Bool
        /// The visible rows, or `nil` when the terminal has no view mounted.
        var read: @MainActor () -> [String]?
        var sendReturn: @MainActor () -> Bool
        var notice: @MainActor (_ message: String, _ tone: CanvasBoardNotice.Tone) -> Void
    }

    typealias Sleep = @MainActor (Duration) async -> Void

    private let now: @MainActor () -> TimeInterval
    private let sleep: Sleep
    /// Terminals whose current Claude Rafu launched with its channel flag and
    /// whose watch has not ended.
    private var launched: Set<UUID> = []
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(
        now: @escaping @MainActor () -> TimeInterval = { Date.timeIntervalSinceReferenceDate },
        sleep: @escaping Sleep = { try? await Task.sleep(for: $0) }
    ) {
        self.now = now
        self.sleep = sleep
    }

    func isWatching(_ controllerID: UUID) -> Bool { launched.contains(controllerID) }

    /// A new launch replaces the watch of an earlier launch in the same terminal.
    /// When the gates are not met the watch never starts, so Off and Ask boards
    /// and a switched-off setting read nothing from the terminal.
    func recordLaunch(controllerID: UUID, hooks: Hooks) {
        end(controllerID)
        launched.insert(controllerID)
        guard
            CanvasChannelPrompt.mayConfirm(
                mode: hooks.mode(), settingOn: hooks.settingOn(), launchedByRafu: true)
        else {
            launched.remove(controllerID)
            return
        }
        tasks[controllerID] = Task(name: "Watch for Claude's development-channel prompt") {
            [weak self] in
            await self?.watch(controllerID: controllerID, hooks: hooks)
        }
    }

    /// Test seam: returns when the terminal's watch has ended.
    func finishedWatching(_ controllerID: UUID) async {
        await tasks[controllerID]?.value
    }

    /// The terminal closed or ended its process.
    func cancel(controllerID: UUID) { end(controllerID) }

    private func end(_ controllerID: UUID) {
        tasks.removeValue(forKey: controllerID)?.cancel()
        launched.remove(controllerID)
    }

    /// The sampling loop. `internal` so a test drives it with a fake clock.
    func watch(controllerID: UUID, hooks: Hooks) async {
        defer {
            if !Task.isCancelled { end(controllerID) }
        }
        var watch = CanvasChannelPromptWatch(startedAt: now())
        while !Task.isCancelled {
            let eligible = CanvasChannelPrompt.mayConfirm(
                mode: hooks.mode(), settingOn: hooks.settingOn(),
                launchedByRafu: launched.contains(controllerID))
            // The rows are read only while the gates hold, or to see the result
            // of the one Return already sent.
            let lines = eligible || watch.hasSentReturn ? hooks.read() : nil
            var action = watch.advance(now: now(), lines: lines, eligible: eligible)
            if action == .sendReturn, !hooks.sendReturn() { action = watch.returnFailed() }
            switch action {
            case .wait, .sendReturn:
                break
            case .confirmed:
                hooks.notice(CanvasChannelPrompt.confirmedNotice, .info)
            case .couldNotConfirm:
                hooks.notice(CanvasChannelPrompt.unconfirmedNotice, .warn)
            case .stop:
                break
            }
            if watch.isFinished { return }
            await sleep(.milliseconds(Int(CanvasChannelPromptWatch.sampleInterval * 1000)))
        }
    }
}
