import OSLog
import RafuWidgetShared
import SwiftUI
import WidgetKit

/// SPIKE (widget packaging): the WidgetKit extension entry point. Built as a
/// SwiftPM executable and assembled into `Contents/PlugIns/*.appex` by
/// `script/build_and_run.sh`.
@main
struct RafuWidgetsBundle: WidgetBundle {
    var body: some Widget {
        UsageRingsWidget()
    }
}

let widgetLog = Logger(subsystem: "dev.vatsalsaglani.rafu.widgets", category: "timeline")

/// The app variant this extension belongs to, from its own bundle id, so
/// Rafu Lightning's widget never reads the release app's snapshot.
enum WidgetHostApp {
    static var name: String {
        let id = Bundle.main.bundleIdentifier ?? ""
        return id.hasPrefix("dev.vatsalsaglani.rafu.lightning") ? "Rafu Lightning" : "Rafu"
    }
}

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetUsageSnapshot?
    let isPlaceholder: Bool
}

struct UsageTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, snapshot: .sample(now: .now), isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        completion(UsageEntry(date: .now, snapshot: loadSnapshot(), isPlaceholder: false))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let now = Date.now
        let snapshot = loadSnapshot()
        // One entry now plus hourly entries so the countdown and staleness
        // age without a reload. The app reloads on real changes.
        let entries = (0..<6).map { hour in
            UsageEntry(
                date: now.addingTimeInterval(Double(hour) * 3600), snapshot: snapshot,
                isPlaceholder: false)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func loadSnapshot() -> WidgetUsageSnapshot? {
        let app = WidgetHostApp.name
        let url = WidgetSnapshotStore.fileURL(appName: app)
        let snapshot = WidgetSnapshotStore.read(appName: app)
        widgetLog.notice(
            "snapshot read app=\(app, privacy: .public) path=\(url.path, privacy: .public) ok=\(snapshot != nil, privacy: .public) home=\(NSHomeDirectory(), privacy: .public)"
        )
        return snapshot
    }
}

struct UsageRingsWidget: Widget {
    static let kind = "dev.vatsalsaglani.rafu.widgets.rings"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: UsageTimelineProvider()) { entry in
            UsageRingsView(entry: entry)
                .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        }
        .configurationDisplayName("Agent usage rings")
        .description("Weekly and session limits for your coding agents.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
