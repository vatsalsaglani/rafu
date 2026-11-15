import Foundation
import RafuWidgetShared
import SwiftUI
import WidgetKit

/// Turns the companion's usage snapshots into the credential-free
/// `WidgetUsageSnapshot`, writes it off the main actor, and asks WidgetKit
/// to reload only when a shown value changed — or, with unchanged values,
/// once the widget's copy nears its 20-minute stale point
/// (`shouldReload`), so a running Rafu never shows as stale.
///
/// Writes only from a staged Rafu or Rafu Lightning bundle, so `swift test`
/// and raw `swift run` never touch the user's Application Support folder.
@MainActor
final class WidgetSnapshotPublisher {
    nonisolated static let ringsKind = "dev.vatsalsaglani.rafu.widgets.rings"
    /// `defaults write dev.vatsalsaglani.rafu.lightning RafuWidgetSampleSnapshot -bool YES`
    /// writes demo data when no provider has a percentage.
    static let sampleDefaultsKey = "RafuWidgetSampleSnapshot"
    /// With unchanged values, reload once the widget's copy is this old. The
    /// app refreshes at most every few minutes, so the reload lands before
    /// `WidgetRingsPresentation.staleAge` (20 minutes).
    nonisolated static let keepAliveInterval: TimeInterval = 15 * 60

    private var lastFingerprint: String?
    private var lastReloadAt: Date?
    private var writeTask: Task<Void, Never>?
    /// Theme inks by theme identifier, so a user theme file is read once.
    private var cachedInks: (identifier: String, inks: WidgetUsageSnapshot.ThemeInks)?

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
            palette: palette, now: now, inks: currentInks())
        if widget.providers.isEmpty, UserDefaults.standard.bool(forKey: Self.sampleDefaultsKey) {
            let inks = widget.inks
            widget = .sample(now: now)
            widget.inks = inks
        }
        let fingerprint = Self.fingerprint(widget)
        let reload = Self.shouldReload(
            fingerprint: fingerprint, lastFingerprint: lastFingerprint,
            lastReloadAt: lastReloadAt, now: now)
        lastFingerprint = fingerprint
        if reload { lastReloadAt = now }
        writeTask?.cancel()
        writeTask = Task.detached(priority: .utility) {
            // Always rewrite so the next timeline WidgetKit asks for reads
            // the newest `writtenAt`.
            try? WidgetSnapshotStore.write(widget, appName: appName)
            if reload {
                WidgetCenter.shared.reloadTimelines(ofKind: Self.ringsKind)
            }
        }
    }

    /// The light and dark ring inks of the current Rafu theme. A fixed
    /// theme gives the same set twice; System gives its pair.
    private func currentInks() -> WidgetUsageSnapshot.ThemeInks {
        let identifier =
            UserDefaults.standard.string(forKey: "themeChoice") ?? RafuThemeChoice.system.rawValue
        if let cachedInks, cachedInks.identifier == identifier { return cachedInks.inks }
        let inks = WidgetUsageSnapshot.ThemeInks(
            light: RafuThemeCatalog.resolved(identifier: identifier, systemScheme: .light)
                .widgetInkSet,
            dark: RafuThemeCatalog.resolved(identifier: identifier, systemScheme: .dark)
                .widgetInkSet)
        cachedInks = (identifier, inks)
        return inks
    }

    nonisolated static func makeSnapshot(
        snapshots: [UsageSnapshot], observedAt: [UsageProviderID: Date],
        stale: Set<UsageProviderID>, mode: UsageDisplayMode, palette: UsageRingPalette, now: Date,
        inks: WidgetUsageSnapshot.ThemeInks? = nil
    ) -> WidgetUsageSnapshot {
        let providers: [WidgetUsageSnapshot.Provider] = snapshots.compactMap { snapshot in
            let windows = snapshot.windows.compactMap { window -> WidgetUsageSnapshot.Window? in
                guard let used = UsageWindowPresentation.usedPercent(window) else { return nil }
                return WidgetUsageSnapshot.Window(
                    label: window.label, usedPercent: used, resetsAt: window.resetsAt,
                    windowMinutes: window.windowMinutes)
            }
            // A local estimate (token totals, no percent) shows its totals;
            // any other provider without a percent has nothing to draw.
            let tokenSummary =
                windows.isEmpty && snapshot.source == .localEstimate
                ? UsageCardPresentation.tokenLine(snapshot) : nil
            guard !windows.isEmpty || tokenSummary != nil else { return nil }
            return WidgetUsageSnapshot.Provider(
                id: snapshot.providerID.rawValue,
                displayName: UsageProviderRegistry.descriptor(for: snapshot.providerID)?
                    .displayName ?? snapshot.providerID.rawValue,
                observedAt: observedAt[snapshot.providerID] ?? now,
                isStale: stale.contains(snapshot.providerID),
                windows: Array(windows.prefix(UsageRingCluster.maxArcs)),
                source: sourceName(snapshot.source), tokenSummary: tokenSummary)
        }
        return WidgetUsageSnapshot(
            writtenAt: now, displayMode: mode.rawValue, palette: palette.rawValue,
            isSample: false, providers: providers, inks: inks)
    }

    nonisolated static func sourceName(_ source: UsageDataSource) -> String {
        switch source {
        case .unspecified: "unspecified"
        case .providerAPI: "providerAPI"
        case .localEstimate: "localEstimate"
        case .localReport: "localReport"
        }
    }

    /// What the widget shows: integer percents, labels, settings, staleness,
    /// sources, token summaries, and theme inks.
    nonisolated static func fingerprint(_ snapshot: WidgetUsageSnapshot) -> String {
        let providers = snapshot.providers.map { provider in
            let windows = provider.windows.map { "\($0.label)=\(Int($0.usedPercent.rounded()))" }
            return
                "\(provider.id):\(provider.isStale):\(provider.source ?? "-"):\(provider.tokenSummary ?? "-"):\(windows.joined(separator: ","))"
        }
        let inks = snapshot.inks.map { inks in
            [inks.light, inks.dark].map {
                [$0.accent, $0.info, $0.success, $0.warning, $0.critical].joined(separator: ",")
            }.joined(separator: "/")
        }
        return
            ([snapshot.displayMode, snapshot.palette, "\(snapshot.isSample)", inks ?? "-"]
            + providers)
            .joined(separator: "|")
    }

    /// Reload when a shown value changed, or when the widget's copy is
    /// `keepAliveInterval` old (it would otherwise turn stale at 20 minutes
    /// while Rafu still runs). Unchanged values within the interval never
    /// spend WidgetKit's reload budget.
    nonisolated static func shouldReload(
        fingerprint: String, lastFingerprint: String?, lastReloadAt: Date?, now: Date
    ) -> Bool {
        guard fingerprint == lastFingerprint, let lastReloadAt else { return true }
        return now.timeIntervalSince(lastReloadAt) >= keepAliveInterval
    }
}
