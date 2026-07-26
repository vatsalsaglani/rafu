import Foundation

/// The one-time, cinematic first-launch overlay ("The Unfolding," pass 1):
/// presentation state, the step cursor, and the single auto-advance timer
/// that drives it. `@Observable` state only — no view-body logic lives here,
/// mirroring `NotchCompanionModel`'s split from `NotchCompanionView`.
///
/// `.shared` is genuinely app-global (same justification as
/// `NotchCompanionModel.shared`/`MemoryPressureMonitor.shared`): it must be
/// reachable from Help ▸ Play the Intro Again in ANY window, and it pins
/// itself to at most one hosting `WorkspaceSession` at a time so exactly one
/// window ever shows the overlay.
@MainActor
@Observable
final class FirstLaunchExperienceModel {
    static let shared = FirstLaunchExperienceModel()

    private(set) var isPresented = false
    private(set) var stepIndex = 0
    private(set) var hostSessionID: ObjectIdentifier?

    private let store: OnboardingCompletionStore
    private var advanceTask: Task<Void, Never>?

    /// Injectable for tests; production call sites use the default
    /// `standard`-defaults-backed store.
    init(store: OnboardingCompletionStore = .init()) {
        self.store = store
    }

    /// Called once per window from its own launch `.task` (mirrors
    /// `WorkspaceRestorationGate`'s one-per-launch shape). The real guard is
    /// `store.hasCompleted` plus `isPresented` rather than a second static
    /// gate: a completed intro must never re-offer itself later in the same
    /// launch, and an already-presented one must not also present in a
    /// second window opened at the same moment.
    func offerOnFirstLaunch(hostedBy session: WorkspaceSession) {
        guard !isPresented, !store.hasCompleted else { return }
        present(hostedBy: session)
    }

    /// Help ▸ Play the Intro Again — ignores completion state entirely.
    func replay(hostedBy session: WorkspaceSession) {
        guard !isPresented else { return }
        present(hostedBy: session)
    }

    /// A window closing mid-intro is not consent to skip: it must not mark
    /// completion, unlike `skip()`/`finish()`. The intro may be offered again
    /// to a later window in the same launch.
    func relinquishHost(_ session: WorkspaceSession) {
        guard hostSessionID == ObjectIdentifier(session) else { return }
        cancelAdvanceTask()
        hideNotchDemo()
        hostSessionID = nil
        isPresented = false
    }

    func hosts(_ session: WorkspaceSession) -> Bool {
        hostSessionID == ObjectIdentifier(session)
    }

    /// →/⏎/click. Advancing past the last step is `finish()`, not a no-op —
    /// the finale step itself never auto-advances (its `dwell` is `nil`), so
    /// this only fires from an explicit user action there.
    func advance() {
        cancelAdvanceTask()
        hideNotchDemo()
        guard stepIndex + 1 < OnboardingScript.passOne.count else {
            finish()
            return
        }
        stepIndex += 1
        scheduleAdvance()
    }

    /// ←. Clamps at the first step rather than going negative.
    func back() {
        cancelAdvanceTask()
        hideNotchDemo()
        stepIndex = max(0, stepIndex - 1)
        scheduleAdvance()
    }

    /// Skip is sacred: available from step 1 onward, jumps straight to
    /// completion.
    func skip() {
        complete()
    }

    /// The finale's explicit dismissal path (either button).
    func finish() {
        complete()
    }

    private func present(hostedBy session: WorkspaceSession) {
        hostSessionID = ObjectIdentifier(session)
        stepIndex = 0
        isPresented = true
        scheduleAdvance()
    }

    private func complete() {
        cancelAdvanceTask()
        hideNotchDemo()
        store.markCompleted()
        isPresented = false
        hostSessionID = nil
        stepIndex = 0
    }

    // MARK: - Notch demo

    /// The notch movement's live demo: while that scene is up, the real
    /// notch companion waves with a one-off attention card, pushed through
    /// the same `pushFeedItem` seam terminal bells use. Respects the
    /// companion's own enable preference, degrades to nothing on screens
    /// where the companion has no home, and is cleared on every path out of
    /// the scene (advance/back/skip/finish/host-window-close).
    private static let notchDemoSessionID = UUID()

    func showNotchDemo() {
        guard NotchCompanionPreferenceStore().isEnabled() else { return }
        let companion = NotchCompanionModel.shared
        companion.activateIfEnabled()
        companion.pushFeedItem(
            CompanionFeedItem(
                id: UUID(),
                sessionID: Self.notchDemoSessionID,
                title: "Rafu",
                editorName: "The Unfolding",
                snippet: "Like this — I'll wave up here when something needs you.",
                timestamp: Date(),
                color: nil
            ))
    }

    func hideNotchDemo() {
        NotchCompanionModel.shared.clearFeedItem(sessionID: Self.notchDemoSessionID)
    }

    private func scheduleAdvance() {
        cancelAdvanceTask()
        guard let dwell = OnboardingScript.passOne[stepIndex].dwell else { return }
        advanceTask = Task { [weak self] in
            try? await Task.sleep(for: dwell)
            guard !Task.isCancelled else { return }
            self?.advance()
        }
    }

    private func cancelAdvanceTask() {
        advanceTask?.cancel()
        advanceTask = nil
    }
}
