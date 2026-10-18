import Foundation

/// The sections of the open notch panel, in tab order. The set mirrors
/// Cider's notch (agents, to-do, now playing, usage) with Rafu's own content:
/// Ensembles instead of agents, and an "Up next" attention queue instead of
/// to-dos.
nonisolated enum NotchSection: String, CaseIterable, Identifiable, Sendable {
    case ensembles
    case upNext
    case nowPlaying
    case usage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ensembles: "Ensembles"
        case .upNext: "Up next"
        case .nowPlaying: "Now Playing"
        case .usage: "Usage"
        }
    }

    var symbol: String {
        switch self {
        case .ensembles: "square.stack.3d.up"
        case .upNext: "tray.full"
        case .nowPlaying: "music.note"
        case .usage: "gauge.with.dots.needle.33percent"
        }
    }

    /// One-line explanation for Settings.
    var summary: String {
        switch self {
        case .ensembles: "Open Ensembles and the agents running in them."
        case .upNext: "Agents that need you or have a reply ready, with quick replies."
        case .nowPlaying: "What is playing on this Mac, with transport controls."
        case .usage: "Agent usage limits and token totals."
        }
    }

    /// `UserDefaults` key for this section's visibility flag.
    var defaultsKey: String { "notchSection.\(rawValue)" }

    /// The sections to offer given each section's flag. Never empty: with
    /// every flag off the panel would have no content, so Ensembles stays.
    static func visible(flags: [NotchSection: Bool]) -> [NotchSection] {
        let shown = allCases.filter { flags[$0] ?? true }
        return shown.isEmpty ? [.ensembles] : shown
    }

    /// The tab to show: the remembered one when it is still offered,
    /// otherwise the first offered section.
    static func selection(remembered: NotchSection?, visible: [NotchSection]) -> NotchSection {
        if let remembered, visible.contains(remembered) { return remembered }
        return visible.first ?? .ensembles
    }
}

/// Persists what the notch shows. Mirrors the other suite-injectable stores
/// (`NotchCompanionPreferenceStore`): the suite name is stored, not a
/// `UserDefaults`, so tests use an isolated suite.
nonisolated struct NotchDisplayPreferenceStore: Sendable {
    static let mascotKey = "notchMascotEnabled"
    static let openOnHoverKey = "notchOpenOnHover"
    static let plainDisplayPillKey = "notchPillOnPlainDisplays"
    static let selectedSectionKey = "notchSelectedSection"
    static let musicConnectedKey = "notchNowPlayingConnected"
    static let systemNowPlayingKey = "notchNowPlayingSystemMedia"

    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    private func flag(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }

    func isSectionVisible(_ section: NotchSection) -> Bool {
        flag(section.defaultsKey, default: true)
    }

    func setSection(_ section: NotchSection, visible: Bool) {
        defaults.set(visible, forKey: section.defaultsKey)
    }

    func visibleSections() -> [NotchSection] {
        NotchSection.visible(
            flags: Dictionary(
                uniqueKeysWithValues: NotchSection.allCases.map { ($0, isSectionVisible($0)) }))
    }

    /// The mascot replaces the plain Rafu mark in the collapsed notch.
    func isMascotEnabled() -> Bool { flag(Self.mascotKey, default: true) }
    func setMascotEnabled(_ value: Bool) { defaults.set(value, forKey: Self.mascotKey) }

    /// Hovering the notch opens the panel (Cider's behaviour). Off: hover
    /// only widens the strip and a click opens the panel.
    func opensOnHover() -> Bool { flag(Self.openOnHoverKey, default: true) }
    func setOpensOnHover(_ value: Bool) { defaults.set(value, forKey: Self.openOnHoverKey) }

    /// On a Mac with no notch, show a floating pill under the menu bar.
    /// Off by default: the companion is a notch companion first, and a
    /// permanent bar under a plain display is clutter unless asked for.
    func showsPillOnPlainDisplays() -> Bool { flag(Self.plainDisplayPillKey, default: false) }
    func setShowsPillOnPlainDisplays(_ value: Bool) {
        defaults.set(value, forKey: Self.plainDisplayPillKey)
    }

    func selectedSection() -> NotchSection? {
        defaults.string(forKey: Self.selectedSectionKey).flatMap(NotchSection.init(rawValue:))
    }

    func setSelectedSection(_ section: NotchSection) {
        defaults.set(section.rawValue, forKey: Self.selectedSectionKey)
    }

    /// The person asked Rafu to read Music and Spotify. Until then Rafu sends
    /// no Apple events, so macOS never shows an Automation prompt unasked.
    func isNowPlayingConnected() -> Bool { flag(Self.musicConnectedKey, default: false) }
    func setNowPlayingConnected(_ value: Bool) {
        defaults.set(value, forKey: Self.musicConnectedKey)
    }

    /// Read Now Playing from macOS (any app, through the bundled MediaRemote
    /// adapter) instead of asking Music and Spotify. On by default; the
    /// Music/Spotify path stays as the fallback when the adapter is missing
    /// or stops.
    func usesSystemNowPlaying() -> Bool { flag(Self.systemNowPlayingKey, default: true) }
    func setUsesSystemNowPlaying(_ value: Bool) {
        defaults.set(value, forKey: Self.systemNowPlayingKey)
    }
}
