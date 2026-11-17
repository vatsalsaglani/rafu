import Foundation

/// The sections of the open notch panel, in tab order. The set mirrors
/// Cider's notch (agents, to-do, now playing, usage) with Rafu's own content:
/// an "Agents" tab with the open windows, their Ensembles, and agents outside
/// Rafu, and an "Up next" attention queue instead of to-dos. The `ensembles`
/// case keeps its raw value, so the stored flags and the remembered tab
/// survive the "Agents" title.
nonisolated enum NotchSection: String, CaseIterable, Identifiable, Sendable {
    case ensembles
    case upNext
    case nowPlaying
    case usage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ensembles: "Agents"
        case .upNext: "Up next"
        case .nowPlaying: "Now Playing"
        case .usage: "Usage"
        }
    }

    var symbol: String {
        switch self {
        case .ensembles: "point.3.connected.trianglepath.dotted"
        case .upNext: "tray.full"
        case .nowPlaying: "music.note"
        case .usage: "gauge.with.dots.needle.33percent"
        }
    }

    /// One-line explanation for Settings.
    var summary: String {
        switch self {
        case .ensembles:
            "Open windows, their Ensembles, and the agents running in them and outside Rafu."
        case .upNext: "Agents that need you or have a reply ready, with quick replies."
        case .nowPlaying: "What is playing on this Mac, with transport controls."
        case .usage: "Agent usage limits and token totals."
        }
    }

    /// `UserDefaults` key for this section's visibility flag.
    var defaultsKey: String { "notchSection.\(rawValue)" }

    /// The sections to offer given each section's flag. Never empty: with
    /// every flag off the panel would have no content, so Agents stays.
    static func visible(flags: [NotchSection: Bool]) -> [NotchSection] {
        let shown = allCases.filter { flags[$0] ?? true }
        return shown.isEmpty ? [.ensembles] : shown
    }

    /// The sections the open panel offers on `surface`: Usage only on a
    /// Dynamic Island screen, whatever the person turned on; `visible`
    /// unchanged everywhere else. Pure — the stored per-section flags are
    /// never rewritten, so the notch keeps its sections on another screen.
    static func offered(_ visible: [NotchSection], on surface: NotchCompanionSurface?)
        -> [NotchSection]
    {
        offered(visible, host: CompanionHost.panel(on: surface))
    }

    /// The sections that `host` offers:
    /// - the notch panel (or the plain-display pill): `visible` unchanged;
    /// - the island card: Usage only (ADR 0037, decision 4);
    /// - the menu bar card: Agents, Up next, and Usage from `visible`, never
    ///   Now Playing, and always Usage, because the status item is the usage
    ///   glance.
    static func offered(_ visible: [NotchSection], host: CompanionHost) -> [NotchSection] {
        switch host {
        case .notchPanel:
            return visible
        case .islandCard:
            return [.usage]
        case .menuBar:
            let menu: Set<NotchSection> = [.ensembles, .upNext, .usage]
            return allCases.filter { menu.contains($0) && ($0 == .usage || visible.contains($0)) }
        }
    }

    /// The tab to show: the remembered one when it is still offered,
    /// otherwise the first offered section.
    static func selection(remembered: NotchSection?, visible: [NotchSection]) -> NotchSection {
        if let remembered, visible.contains(remembered) { return remembered }
        return visible.first ?? .ensembles
    }
}

/// The surface that shows the companion's sections. One set of section views
/// serves every host (`CompanionSectionHost`); the host decides which
/// sections it offers and which control closes it.
nonisolated enum CompanionHost: Equatable, Sendable {
    /// The open notch panel, or the panel under the plain-display pill.
    case notchPanel
    /// The card that opens from the capsule below a system Dynamic Island.
    case islandCard
    /// The popover of the usage status item in the menu bar.
    case menuBar

    /// The host of the open companion panel on `surface`.
    static func panel(on surface: NotchCompanionSurface?) -> CompanionHost {
        surface == .island ? .islandCard : .notchPanel
    }

    /// The host that shows outside agents (seen only through hooks) that
    /// need the person, in its Up next section: the surface in use, never
    /// two at once. The menu bar card when the companion is in the menu bar
    /// (on any Mac); otherwise the notch panel on a notched Mac or the
    /// plain-display pill; nothing on an island Mac with the pill below the
    /// island, whose card shows Usage only, or on a plain screen with the
    /// pill off. `surface` is the screen's kind (`.pill` for a plain
    /// screen); `nil` means no screen.
    static func outsideNotices(
        surface: NotchCompanionSurface?, position: UsageGlancePosition, allowsPill: Bool = true
    ) -> CompanionHost? {
        guard let surface else { return nil }
        if position == .menuBar { return .menuBar }
        switch surface {
        case .island: return nil
        case .pill: return allowsPill ? .notchPanel : nil
        case .notch: return .notchPanel
        }
    }
}

/// The tab the menu bar card shows when it opens. Pure.
nonisolated enum CompanionMenuSelection {
    /// Up next when something waits for the person, so the card opens on
    /// what needs them; otherwise the remembered tab while it is offered;
    /// otherwise the first offered section.
    static func initial(
        remembered: NotchSection?, offered: [NotchSection], attention: Int
    ) -> NotchSection {
        if attention > 0, offered.contains(.upNext) { return .upNext }
        return NotchSection.selection(remembered: remembered, visible: offered)
    }

    /// The tab `offset` places from `current` in `offered`, kept at the
    /// ends (Left on the first tab stays there). An unknown `current`
    /// gives the first tab.
    static func step(from current: NotchSection, in offered: [NotchSection], by offset: Int)
        -> NotchSection
    {
        guard let index = offered.firstIndex(of: current) else {
            return offered.first ?? current
        }
        let next = min(max(index + offset, 0), offered.count - 1)
        return offered[next]
    }
}

/// Where the companion shows on this Mac (Settings ▸ General ▸ Notch,
/// "Companion position"). Every Mac reads it (`CompanionPresence`).
///
/// - `belowIsland`: the companion's own surface — the strip at the notch,
///   the pill below a system Dynamic Island, or the pill below the menu bar
///   on a plain display (the default). The raw value is historical: it
///   dates from when only Dynamic Island Macs had this setting, and stays
///   so the stored value survives.
/// - `menuBar`: one status item among the menu bar's right-side items,
///   which opens the menu bar card.
nonisolated enum UsageGlancePosition: String, CaseIterable, Identifiable, Sendable {
    case belowIsland
    case menuBar

    var id: String { rawValue }

    /// The Settings title on a screen of kind `surface` (`nil` means no
    /// screen).
    func title(on surface: NotchCompanionSurface?) -> String {
        switch (self, surface) {
        case (.belowIsland, .island): "Below the Dynamic Island"
        case (.belowIsland, .notch): "At the notch"
        case (.belowIsland, .pill), (.belowIsland, nil): "Below the menu bar"
        case (.menuBar, _): "In the menu bar"
        }
    }

    /// An unknown or missing stored value falls back to the default.
    static func resolve(stored: String?) -> UsageGlancePosition {
        stored.flatMap(UsageGlancePosition.init(rawValue:)) ?? .belowIsland
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
    static let usageGlancePositionKey = "notchUsageGlancePosition"
    static let menuBarSelectedSectionKey = "menuBarCompanionSection"

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

    /// Where a Dynamic Island Mac shows the usage glance.
    func usageGlancePosition() -> UsageGlancePosition {
        UsageGlancePosition.resolve(stored: defaults.string(forKey: Self.usageGlancePositionKey))
    }

    func setUsageGlancePosition(_ position: UsageGlancePosition) {
        defaults.set(position.rawValue, forKey: Self.usageGlancePositionKey)
    }

    func selectedSection() -> NotchSection? {
        defaults.string(forKey: Self.selectedSectionKey).flatMap(NotchSection.init(rawValue:))
    }

    func setSelectedSection(_ section: NotchSection) {
        defaults.set(section.rawValue, forKey: Self.selectedSectionKey)
    }

    /// The menu bar card's own remembered tab, apart from the notch's.
    func menuBarSelectedSection() -> NotchSection? {
        defaults.string(forKey: Self.menuBarSelectedSectionKey).flatMap(
            NotchSection.init(rawValue:))
    }

    func setMenuBarSelectedSection(_ section: NotchSection) {
        defaults.set(section.rawValue, forKey: Self.menuBarSelectedSectionKey)
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
