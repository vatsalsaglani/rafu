import Foundation

/// The small, credential-free usage snapshot the app writes and the
/// WidgetKit extension reads. No account identity, no transcript text, no
/// tokens of authentication: only percentages, reset times, token totals as
/// display text, and presentation settings.
///
/// Kept in its own tiny target so the sandboxed `.appex` links neither the
/// GUI target nor `RafuCore`.
///
/// Version 2 adds the ring palette's theme inks, each provider's data
/// source, and a token summary for local estimates. Every v2 field is
/// optional, so a v1 file still decodes (and renders with system inks).
///
/// Version 3 adds, on each provider's primary weekly window, the day split
/// of the current limit window (`Window.daily`, `Window.windowStart`). The
/// app derives it from its own sample log; the extension never reads that
/// log. Both fields are optional, so v1 and v2 files still decode.
/// `Window.dailyEstimated` (added with the Seven widget, still version 3)
/// is optional too: a v3 file without it decodes as not estimated.
public struct WidgetUsageSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 3
    /// Versions `WidgetSnapshotStore.read` accepts.
    public static let supportedVersions: ClosedRange<Int> = 1...currentVersion

    public var version: Int
    public var writtenAt: Date
    /// `"used"` or `"remaining"` (mirrors `UsageDisplayMode.rawValue`).
    public var displayMode: String
    /// `"color"` or `"monochrome"` (mirrors `UsageRingPalette.rawValue`).
    public var palette: String
    /// `true` when the app wrote demo data because no provider had data.
    public var isSample: Bool
    public var providers: [Provider]
    /// v2: the ring colours of the user's Rafu theme, as hex. `nil` in a v1
    /// file; the widget then uses system colours.
    public var inks: ThemeInks?

    public init(
        writtenAt: Date, displayMode: String, palette: String, isSample: Bool,
        providers: [Provider], inks: ThemeInks? = nil
    ) {
        self.version = Self.currentVersion
        self.writtenAt = writtenAt
        self.displayMode = displayMode
        self.palette = palette
        self.isSample = isSample
        self.providers = providers
        self.inks = inks
    }

    /// The display mode, `.used` for an unknown value.
    public var resolvedDisplayMode: UsageDisplayMode {
        UsageDisplayMode(rawValue: displayMode) ?? .used
    }

    /// The ring palette, `.color` for an unknown value.
    public var resolvedPalette: UsageRingPalette {
        UsageRingPalette(rawValue: palette) ?? .color
    }

    public struct Provider: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var displayName: String
        public var observedAt: Date
        public var isStale: Bool
        /// At most three windows, outermost ring first. Only windows with a
        /// valid used percent.
        public var windows: [Window]
        /// v2: `"providerAPI"`, `"localEstimate"`, `"localReport"`, or
        /// `"unspecified"` (mirrors `UsageDataSource`). `nil` in a v1 file.
        public var source: String?
        /// v2: `"5h 120K tok · 7d 1.4M tok"` for windows that report tokens
        /// and no percent (`UsageCardPresentation.tokenLine`), else `nil`.
        public var tokenSummary: String?

        public init(
            id: String, displayName: String, observedAt: Date, isStale: Bool, windows: [Window],
            source: String? = nil, tokenSummary: String? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.observedAt = observedAt
            self.isStale = isStale
            self.windows = windows
            self.source = source
            self.tokenSummary = tokenSummary
        }

        /// The windows as the shared `UsageWindow`, so the widget runs the
        /// app's `UsageRingClusterBuilder` and `UsagePace` on them.
        public var usageWindows: [UsageWindow] {
            windows.map {
                UsageWindow(
                    label: $0.label, percent: $0.usedPercent, tokens: nil, resetsAt: $0.resetsAt,
                    windowMinutes: $0.windowMinutes)
            }
        }
    }

    public struct Window: Codable, Equatable, Sendable {
        public var label: String
        /// Used percent, 0...100.
        public var usedPercent: Double
        public var resetsAt: Date?
        public var windowMinutes: Int?
        /// v3: the start of the current limit window (`resetsAt` minus the
        /// window length). Only on a provider's primary weekly window.
        public var windowStart: Date?
        /// v3: seven values, one for each 24-hour slice from `windowStart`:
        /// the used percent of each past day, today's so far, and `nil` for
        /// each day after the app's last observation. Only on a provider's
        /// primary weekly window, and only when the app has a sample log.
        public var daily: [Double?]?
        /// v3: `true` when the app spread a gap in its sample log over more
        /// than one day (the log started after the window start, or Rafu
        /// was closed), so `daily` is an estimate. `nil` (an older v3 file)
        /// reads as `false`; see `isDailyEstimated`.
        public var dailyEstimated: Bool?

        public init(
            label: String, usedPercent: Double, resetsAt: Date?, windowMinutes: Int?,
            windowStart: Date? = nil, daily: [Double?]? = nil, dailyEstimated: Bool? = nil
        ) {
            self.label = label
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
            self.windowMinutes = windowMinutes
            self.windowStart = windowStart
            self.daily = daily
            self.dailyEstimated = dailyEstimated
        }

        /// `dailyEstimated`, `false` when absent.
        public var isDailyEstimated: Bool { dailyEstimated ?? false }
    }

    /// The theme colours the rings use, for a light and a dark desktop. A
    /// fixed theme writes the same set twice; the System theme writes its
    /// light and dark pair. The extension never parses theme JSON.
    public struct ThemeInks: Codable, Equatable, Sendable {
        public var light: InkSet
        public var dark: InkSet

        public init(light: InkSet, dark: InkSet) {
            self.light = light
            self.dark = dark
        }
    }

    /// `#RRGGBB` or `#RRGGBBAA` hex strings, as in a Rafu theme file.
    public struct InkSet: Codable, Equatable, Sendable {
        /// Ring 1 (outermost) in Color mode: the theme accent.
        public var accent: String
        /// Ring 2 in Color mode.
        public var info: String
        /// Ring 3 in Color mode.
        public var success: String
        /// The warning glyph and text.
        public var warning: String
        /// The critical (at limit) glyph and text.
        public var critical: String

        public init(
            accent: String, info: String, success: String, warning: String, critical: String
        ) {
            self.accent = accent
            self.info = info
            self.success = success
            self.warning = warning
            self.critical = critical
        }
    }

    /// Demo data for the widget gallery placeholder and for a first run.
    /// Claude is on day 6 of 7 and Codex on day 4 of 7, each with a day
    /// split that adds up to its weekly percent.
    public static func sample(now: Date) -> WidgetUsageSnapshot {
        let claudeReset = now.addingTimeInterval(32 * 3600)
        let codexReset = now.addingTimeInterval(82 * 3600)
        let week: TimeInterval = 7 * 86_400
        return WidgetUsageSnapshot(
            writtenAt: now, displayMode: "used", palette: "color", isSample: true,
            providers: [
                Provider(
                    id: "claude", displayName: "Claude", observedAt: now, isStale: false,
                    windows: [
                        Window(
                            label: "7d", usedPercent: 41, resetsAt: claudeReset,
                            windowMinutes: 10_080,
                            windowStart: claudeReset.addingTimeInterval(-week),
                            daily: [7, 9, 5, 8, 6, 6, nil]),
                        Window(
                            label: "Fable 7d", usedPercent: 24,
                            resetsAt: now.addingTimeInterval(32 * 3600), windowMinutes: 10_080),
                        Window(
                            label: "5h", usedPercent: 12,
                            resetsAt: now.addingTimeInterval(3 * 3600), windowMinutes: 300),
                    ], source: "providerAPI"),
                Provider(
                    id: "codex", displayName: "Codex", observedAt: now, isStale: false,
                    windows: [
                        Window(
                            label: "7d", usedPercent: 34, resetsAt: codexReset,
                            windowMinutes: 10_080,
                            windowStart: codexReset.addingTimeInterval(-week),
                            daily: [10, 9, 8, 7, nil, nil, nil]),
                        Window(
                            label: "5h", usedPercent: 8,
                            resetsAt: now.addingTimeInterval(2 * 3600), windowMinutes: 300),
                    ], source: "providerAPI"),
            ])
    }
}

/// Where the snapshot lives and how it is read and written.
///
/// The location is `~/Library/Application Support/<App Name>/Widgets/` in
/// the user's real home. The app is not sandboxed and writes there; the
/// sandboxed extension reads it through a read-only
/// `com.apple.security.temporary-exception.files.home-relative-path.read-only`
/// entitlement. An App Group container was evaluated and is not used: see
/// the spike report (ad-hoc signing has no team identifier to validate a
/// group, so macOS 15+ treats access as cross-app data access).
public enum WidgetSnapshotStore {
    public static let fileName = "usage-snapshot.json"

    /// `appName` is `"Rafu Lightning"` or `"Rafu"`. The extension derives it
    /// from its own bundle identifier so the two variants never share data.
    public static func directory(appName: String, home: URL = realHomeDirectory()) -> URL {
        home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .appending(path: appName, directoryHint: .isDirectory)
            .appending(path: "Widgets", directoryHint: .isDirectory)
    }

    public static func fileURL(appName: String, home: URL = realHomeDirectory()) -> URL {
        directory(appName: appName, home: home).appending(
            path: fileName, directoryHint: .notDirectory)
    }

    /// The user's real home, also inside a sandbox, where `NSHomeDirectory()`
    /// is the container. `getpwuid` reads the account record.
    public static func realHomeDirectory() -> URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(filePath: String(cString: dir), directoryHint: .isDirectory)
        }
        return URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
    }

    public static func encode(_ snapshot: WidgetUsageSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    public static func decode(_ data: Data) throws -> WidgetUsageSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WidgetUsageSnapshot.self, from: data)
    }

    /// `nil` for undecodable data or a version outside
    /// `WidgetUsageSnapshot.supportedVersions`.
    public static func decodeSupported(_ data: Data) -> WidgetUsageSnapshot? {
        guard let snapshot = try? decode(data),
            WidgetUsageSnapshot.supportedVersions.contains(snapshot.version)
        else { return nil }
        return snapshot
    }

    /// Atomic write (temporary file, then rename). Call off the main actor.
    public static func write(_ snapshot: WidgetUsageSnapshot, appName: String) throws {
        let url = fileURL(appName: appName)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(snapshot).write(to: url, options: [.atomic])
    }

    /// `nil` when the file is missing, unreadable, or of an unknown version.
    public static func read(appName: String) -> WidgetUsageSnapshot? {
        guard let data = try? Data(contentsOf: fileURL(appName: appName)) else { return nil }
        return decodeSupported(data)
    }
}
