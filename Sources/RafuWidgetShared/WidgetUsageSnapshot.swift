import Foundation

/// SPIKE (widget packaging): the small, credential-free usage snapshot the
/// app writes and the WidgetKit extension reads. No account identity, no
/// transcript text, no tokens of authentication: only percentages, reset
/// times, and presentation settings.
///
/// Kept in its own tiny target so the sandboxed `.appex` links neither the
/// GUI target nor `RafuCore`.
public struct WidgetUsageSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var writtenAt: Date
    /// `"used"` or `"remaining"` (mirrors `UsageDisplayMode.rawValue`).
    public var displayMode: String
    /// `"color"` or `"monochrome"` (mirrors `UsageRingPalette.rawValue`).
    public var palette: String
    /// `true` when the app wrote demo data because no provider had data.
    public var isSample: Bool
    public var providers: [Provider]

    public init(
        writtenAt: Date, displayMode: String, palette: String, isSample: Bool,
        providers: [Provider]
    ) {
        self.version = Self.currentVersion
        self.writtenAt = writtenAt
        self.displayMode = displayMode
        self.palette = palette
        self.isSample = isSample
        self.providers = providers
    }

    public struct Provider: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var displayName: String
        public var observedAt: Date
        public var isStale: Bool
        /// At most three windows, outermost ring first.
        public var windows: [Window]

        public init(
            id: String, displayName: String, observedAt: Date, isStale: Bool, windows: [Window]
        ) {
            self.id = id
            self.displayName = displayName
            self.observedAt = observedAt
            self.isStale = isStale
            self.windows = windows
        }
    }

    public struct Window: Codable, Equatable, Sendable {
        public var label: String
        /// Used percent, 0...100.
        public var usedPercent: Double
        public var resetsAt: Date?
        public var windowMinutes: Int?

        public init(label: String, usedPercent: Double, resetsAt: Date?, windowMinutes: Int?) {
            self.label = label
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
            self.windowMinutes = windowMinutes
        }
    }

    /// Demo data for the widget gallery placeholder and for a first run.
    public static func sample(now: Date) -> WidgetUsageSnapshot {
        WidgetUsageSnapshot(
            writtenAt: now, displayMode: "used", palette: "color", isSample: true,
            providers: [
                Provider(
                    id: "claude", displayName: "Claude", observedAt: now, isStale: false,
                    windows: [
                        Window(
                            label: "7d", usedPercent: 41,
                            resetsAt: now.addingTimeInterval(32 * 3600), windowMinutes: 10_080),
                        Window(
                            label: "Fable 7d", usedPercent: 24,
                            resetsAt: now.addingTimeInterval(32 * 3600), windowMinutes: 10_080),
                        Window(
                            label: "5h", usedPercent: 12,
                            resetsAt: now.addingTimeInterval(3 * 3600), windowMinutes: 300),
                    ]),
                Provider(
                    id: "codex", displayName: "Codex", observedAt: now, isStale: false,
                    windows: [
                        Window(
                            label: "7d", usedPercent: 34,
                            resetsAt: now.addingTimeInterval(82 * 3600), windowMinutes: 10_080),
                        Window(
                            label: "5h", usedPercent: 8,
                            resetsAt: now.addingTimeInterval(2 * 3600), windowMinutes: 300),
                    ]),
            ])
    }
}

/// SPIKE: where the snapshot lives and how it is read and written.
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

    /// Atomic write (temporary file, then rename). Call off the main actor.
    public static func write(_ snapshot: WidgetUsageSnapshot, appName: String) throws {
        let url = fileURL(appName: appName)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(snapshot).write(to: url, options: [.atomic])
    }

    /// `nil` when the file is missing, unreadable, or of an unknown version.
    public static func read(appName: String) -> WidgetUsageSnapshot? {
        guard let data = try? Data(contentsOf: fileURL(appName: appName)),
            let snapshot = try? decode(data),
            snapshot.version == WidgetUsageSnapshot.currentVersion
        else { return nil }
        return snapshot
    }
}
