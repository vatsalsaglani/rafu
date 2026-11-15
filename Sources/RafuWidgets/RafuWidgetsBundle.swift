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
        UsageHundredWidget()
        UsageSevenWidget()
        UsageBoardWidget()
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

/// One hundred dots are one weekly limit: used, today, projected by the
/// reset, and spare. Same timeline as the Rings widget.
struct UsageHundredWidget: Widget {
    static let kind = "dev.vatsalsaglani.rafu.widgets.hundred"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: UsageTimelineProvider()) { entry in
            UsageHundredView(entry: entry)
                .widgetURL(WidgetHostApp.usageURL)
                .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        }
        .configurationDisplayName("Agent usage dots")
        .description(
            "Your weekly limit as 100 dots: what you used, what you used today, and what your pace adds by the reset."
        )
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// One column for each day of the weekly limit window, one dot for each 1%
/// of the limit, with a dashed line at an even daily pace. Same timeline as
/// the Rings widget; its day-boundary entries move "today".
struct UsageSevenWidget: Widget {
    static let kind = "dev.vatsalsaglani.rafu.widgets.seven"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: UsageTimelineProvider()) { entry in
            UsageSevenView(entry: entry)
                .widgetURL(WidgetHostApp.usageURL)
                .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        }
        .configurationDisplayName("Agent usage by day")
        .description(
            "Your weekly limit day by day: one dot for each 1% you used, against an even daily pace."
        )
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

/// Every connected agent on one board: each with its Hundred grid and its
/// Seven columns. Extra large on macOS 14 and later; extra large portrait
/// on macOS 27 only. Same timeline as the Rings widget.
struct UsageBoardWidget: Widget {
    static let kind = "dev.vatsalsaglani.rafu.widgets.board"

    static var families: [WidgetFamily] {
        // `systemExtraLargePortrait` exists for macOS only in the macOS 27
        // SDK (Swift 6.4 toolchains). The macOS 26 SDK marks it unavailable,
        // so a runtime check alone does not compile there (CI, release).
        #if compiler(>=6.4)
            if #available(macOS 27.0, *) {
                return [.systemExtraLarge, .systemExtraLargePortrait]
            }
        #endif
        return [.systemExtraLarge]
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: UsageTimelineProvider()) { entry in
            UsageBoardView(entry: entry)
                .widgetURL(WidgetHostApp.usageURL)
                .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        }
        .configurationDisplayName("Agent usage board")
        .description(
            "All your coding agents on one board: the weekly limit as 100 dots and day by day."
        )
        .supportedFamilies(Self.families)
    }
}
