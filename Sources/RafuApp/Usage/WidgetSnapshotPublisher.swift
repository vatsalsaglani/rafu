import Foundation
import RafuWidgetShared
import WidgetKit

/// SPIKE (widget packaging): turns the companion's usage snapshots into the
/// credential-free `WidgetUsageSnapshot`, writes it off the main actor, and
/// asks WidgetKit to reload only when a shown value changed.
///
/// Writes only from a staged Rafu or Rafu Lightning bundle, so `swift test`
/// and raw `swift run` never touch the user's Application Support folder.
@MainActor
final class WidgetSnapshotPublisher {
    nonisolated static let ringsKind = "dev.vatsalsaglani.rafu.widgets.rings"
    /// `defaults write dev.vatsalsaglani.rafu.lightning RafuWidgetSampleSnapshot -bool YES`
    /// writes demo data when no provider has a percentage (spike evidence).
    static let sampleDefaultsKey = "RafuWidgetSampleSnapshot"

    private var lastFingerprint: String?
    private var writeTask: Task<Void, Never>?

    nonisolated static var hostAppName: String? {
        switch Bundle.main.bundleIdentifier {
        case "dev.vatsalsaglani.rafu.lightning": "Rafu Lightning"
        case "dev.vatsalsaglani.rafu": "Rafu"
        default: nil
        }
    }

    func publish(
        snapshots: [UsageSnapshot], observedAt: [UsageProviderID: Date],
        stale: Set<UsageProviderID>, mode: UsageDisplayMode, palette: UsageRingPalette, now: Date
    ) {
        guard let appName = Self.hostAppName else { return }
        var widget = Self.makeSnapshot(
            snapshots: snapshots, observedAt: observedAt, stale: stale, mode: mode,
            palette: palette, now: now)
        if widget.providers.isEmpty, UserDefaults.standard.bool(forKey: Self.sampleDefaultsKey) {
            widget = .sample(now: now)
        }
        let fingerprint = Self.fingerprint(widget)
        let changed = fingerprint != lastFingerprint
        lastFingerprint = fingerprint
        writeTask?.cancel()
        writeTask = Task.detached(priority: .utility) {
            // Always rewrite so `writtenAt` keeps the widget from going stale.
            try? WidgetSnapshotStore.write(widget, appName: appName)
            if changed {
                WidgetCenter.shared.reloadTimelines(ofKind: Self.ringsKind)
            }
        }
    }

    nonisolated static func makeSnapshot(
        snapshots: [UsageSnapshot], observedAt: [UsageProviderID: Date],
        stale: Set<UsageProviderID>, mode: UsageDisplayMode, palette: UsageRingPalette, now: Date
    ) -> WidgetUsageSnapshot {
        let providers: [WidgetUsageSnapshot.Provider] = snapshots.compactMap { snapshot in
            let windows = snapshot.windows.compactMap { window -> WidgetUsageSnapshot.Window? in
                guard let used = UsageWindowPresentation.usedPercent(window) else { return nil }
                return WidgetUsageSnapshot.Window(
                    label: window.label, usedPercent: used, resetsAt: window.resetsAt,
                    windowMinutes: window.windowMinutes)
            }
            guard !windows.isEmpty else { return nil }
            return WidgetUsageSnapshot.Provider(
                id: snapshot.providerID.rawValue,
                displayName: UsageProviderRegistry.descriptor(for: snapshot.providerID)?
                    .displayName ?? snapshot.providerID.rawValue,
                observedAt: observedAt[snapshot.providerID] ?? now,
                isStale: stale.contains(snapshot.providerID),
                windows: Array(windows.prefix(3)))
        }
        return WidgetUsageSnapshot(
            writtenAt: now, displayMode: mode.rawValue, palette: palette.rawValue,
            isSample: false, providers: providers)
    }

    /// What the widget shows: integer percents, labels, settings, staleness.
    nonisolated static func fingerprint(_ snapshot: WidgetUsageSnapshot) -> String {
        let providers = snapshot.providers.map { provider in
            let windows = provider.windows.map { "\($0.label)=\(Int($0.usedPercent.rounded()))" }
            return "\(provider.id):\(provider.isStale):\(windows.joined(separator: ","))"
        }
        return ([snapshot.displayMode, snapshot.palette, "\(snapshot.isSample)"] + providers)
            .joined(separator: "|")
    }
}
