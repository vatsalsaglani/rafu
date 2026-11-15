import Foundation
import RafuCore
import RafuWidgetShared
import SwiftUI
import WidgetKit

/// Turns the companion's usage snapshots into the credential-free
/// `WidgetUsageSnapshot`, writes it off the main actor, and asks WidgetKit
/// to reload only when a shown value changed — or, with unchanged values,
/// once the widget's copy nears its 20-minute stale point
/// (`shouldReload`), so a running Rafu never shows as stale.
///
/// Each publish also appends the fresh windows to the daily usage log
/// (`UsageSampleLogStore`, in `Application Support/<App Name>/Usage/`) and
/// writes each provider's day split of its weekly window into the snapshot
/// (v3). The log is read and written only on its actor, never on the main
/// actor; the extension never reads it.
///
/// Writes only from a staged Rafu or Rafu Lightning bundle, so `swift test`
/// and raw `swift run` never touch the user's Application Support folder.
@MainActor
final class WidgetSnapshotPublisher {
    nonisolated static let ringsKind = "dev.vatsalsaglani.rafu.widgets.rings"
    nonisolated static let hundredKind = "dev.vatsalsaglani.rafu.widgets.hundred"
    nonisolated static let widgetKinds = [ringsKind, hundredKind]
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
    /// The daily usage log; `nil` outside a staged bundle.
    private let sampleLog: UsageSampleLogStore?
    /// Theme inks by theme identifier, so a user theme file is read once.
    private var cachedInks: (identifier: String, inks: WidgetUsageSnapshot.ThemeInks)?

    init() {
        if let appName = Self.hostAppName,
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        {
            sampleLog = UsageSampleLogStore(
                fileURL: UsageSampleLogStore.fileURL(applicationSupport: support, appName: appName))
        } else {
            sampleLog = nil
        }
    }

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
        let samples = Self.sampleRecords(
            snapshots: snapshots, observedAt: observedAt, stale: stale, now: now)
        let sampleLog = sampleLog
        let previous = writeTask
        // Chained, not cancelled: each publish appends to the log, and the
        // newest snapshot is always the last one written.
        writeTask = Task.detached(priority: .utility) {
            await previous?.value
            var widget = widget
            if let sampleLog {
                let log = await sampleLog.record(samples, now: now)
                if !widget.isSample { widget = Self.attachDaily(widget, log: log) }
            }
            // Always rewrite so the next timeline WidgetKit asks for reads
            // the newest `writtenAt`.
            try? WidgetSnapshotStore.write(widget, appName: appName)
            if reload {
                for kind in Self.widgetKinds {
                    WidgetCenter.shared.reloadTimelines(ofKind: kind)
                }
            }
        }
    }

    /// One log record for each window with a used percent of each fresh
    /// provider. A stale provider repeats an old read, so it adds nothing.
    nonisolated static func sampleRecords(
        snapshots: [UsageSnapshot], observedAt: [UsageProviderID: Date],
        stale: Set<UsageProviderID>, now: Date
    ) -> [UsageSampleRecord] {
        snapshots.filter { !stale.contains($0.providerID) }.flatMap { snapshot in
            snapshot.windows.compactMap { window -> UsageSampleRecord? in
                guard let used = UsageWindowPresentation.usedPercent(window) else { return nil }
                return UsageSampleRecord(
                    providerID: snapshot.providerID.rawValue, window: window.label,
                    usedPercent: used, resetsAt: window.resetsAt,
                    observedAt: observedAt[snapshot.providerID] ?? now)
            }
        }
    }

    /// Writes the day split into each provider's primary weekly window
    /// (the first window with a 7-day length). Other windows are unchanged.
    nonisolated static func attachDaily(_ snapshot: WidgetUsageSnapshot, log: UsageSampleLog)
        -> WidgetUsageSnapshot
    {
        var snapshot = snapshot
        for index in snapshot.providers.indices {
            let provider = snapshot.providers[index]
            guard
                let windowIndex = provider.windows.firstIndex(where: {
                    $0.windowMinutes == UsageDailyBreakdown.weeklyWindowMinutes
                })
            else { continue }
            let window = provider.windows[windowIndex]
            guard
                let breakdown = UsageDailyBreakdown.make(
                    records: log.records(providerID: provider.id, window: window.label),
                    providerID: provider.id, window: window.label,
                    currentPercent: window.usedPercent, observedAt: provider.observedAt,
                    resetsAt: window.resetsAt, windowMinutes: window.windowMinutes)
            else { continue }
            snapshot.providers[index].windows[windowIndex].windowStart = breakdown.windowStart
            snapshot.providers[index].windows[windowIndex].daily = breakdown.daily
        }
        return snapshot
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
