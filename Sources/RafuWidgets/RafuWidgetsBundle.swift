import RafuWidgetShared
import SwiftUI
import WidgetKit

/// The WidgetKit extension entry point. Built as a SwiftPM executable and
/// assembled into `Contents/PlugIns/RafuWidgets.appex` by
/// `script/build_and_run.sh`.
@main
struct RafuWidgetsBundle: WidgetBundle {
    var body: some Widget {
        UsageRingsWidget()
    }
}

/// The app variant this extension belongs to, from its own bundle id, so
/// Rafu Lightning's widget never reads the release app's snapshot or opens
/// the release app.
enum WidgetHostApp {
    static var bundleIdentifier: String? { Bundle.main.bundleIdentifier }

    static var name: String {
        RafuDeepLink.scheme(forBundleIdentifier: bundleIdentifier) == RafuDeepLink.lightningScheme
            ? "Rafu Lightning" : "Rafu"
    }

    /// `rafu://usage` or `rafu-lightning://usage`.
    static var usageURL: URL {
        RafuDeepLink.usageURL(scheme: RafuDeepLink.scheme(forBundleIdentifier: bundleIdentifier))
    }
}

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetUsageSnapshot?
}

struct UsageTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, snapshot: .sample(now: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        completion(UsageEntry(date: .now, snapshot: loadSnapshot()))
    }

    /// Entries at each moment the rings change without new data
    /// (`WidgetTimelinePlan`). The app reloads the timeline when a shown
    /// value changes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let snapshot = loadSnapshot()
        let entries = WidgetTimelinePlan.entryDates(snapshot: snapshot, now: .now).map {
            UsageEntry(date: $0, snapshot: snapshot)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func loadSnapshot() -> WidgetUsageSnapshot? {
        WidgetSnapshotStore.read(appName: WidgetHostApp.name)
    }
}

struct UsageRingsWidget: Widget {
    static let kind = "dev.vatsalsaglani.rafu.widgets.rings"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: UsageTimelineProvider()) { entry in
            UsageRingsView(entry: entry)
                .widgetURL(WidgetHostApp.usageURL)
                .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        }
        .configurationDisplayName("Agent usage rings")
        .description("Weekly and session limits for your coding agents.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
