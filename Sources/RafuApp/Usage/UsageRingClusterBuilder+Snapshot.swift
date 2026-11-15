import Foundation

extension UsageRingClusterBuilder {
    /// Builds a cluster from one provider snapshot. `nil` when the snapshot
    /// has no window with a usable percentage — the token-only and "No usage
    /// yet" card paths stay unchanged.
    ///
    /// The rules live in `RafuWidgetShared` (`make(windows:…)`) so the widget
    /// draws the same rings; this overload keeps the app's call sites and
    /// tests unchanged. `nonisolated` on the member itself: `RafuApp`'s
    /// default `MainActor` isolation would otherwise make it `@MainActor`
    /// (`docs/references/nonisolated-extension-isolation-trap.md`).
    nonisolated static func make(
        snapshot: UsageSnapshot, observedAt: Date?, mode: UsageDisplayMode, displayName: String,
        now: Date, maxArcs: Int = UsageRingCluster.maxArcs, calendar: Calendar = .current,
        locale: Locale = .current
    ) -> UsageRingCluster? {
        make(
            windows: UsageCardPresentation.ringWindows(snapshot), observedAt: observedAt,
            mode: mode, displayName: displayName, now: now, maxArcs: maxArcs,
            calendar: calendar, locale: locale)
    }
}
