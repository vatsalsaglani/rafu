import CoreGraphics
import Foundation
import Testing

@testable import RafuApp

// MARK: - Sections and preferences

@Test("NotchSection.visible: all on by default; never empty")
func sectionVisibility() {
    #expect(NotchSection.visible(flags: [:]) == NotchSection.allCases)
    #expect(
        NotchSection.visible(flags: [.usage: false, .nowPlaying: false]) == [.ensembles, .upNext])
    let allOff = Dictionary(uniqueKeysWithValues: NotchSection.allCases.map { ($0, false) })
    #expect(NotchSection.visible(flags: allOff) == [.ensembles])
}

@Test("NotchSection.selection: keeps the remembered tab only while it is offered")
func sectionSelection() {
    #expect(NotchSection.selection(remembered: .usage, visible: [.ensembles, .usage]) == .usage)
    #expect(
        NotchSection.selection(remembered: .usage, visible: [.ensembles, .upNext]) == .ensembles)
    #expect(NotchSection.selection(remembered: nil, visible: [.upNext, .usage]) == .upNext)
}

@Test("NotchDisplayPreferenceStore: defaults, then round-trips, in an isolated suite")
func displayPreferencesRoundTrip() {
    let suite = TestDefaultsSuite.name("dev.rafu.tests.notch-display")
    defer { TestDefaultsSuite.remove(suite) }
    let store = NotchDisplayPreferenceStore(suiteName: suite)

    #expect(store.visibleSections() == NotchSection.allCases)
    #expect(store.isMascotEnabled())
    #expect(store.opensOnHover())
    #expect(!store.showsPillOnPlainDisplays())
    #expect(!store.isNowPlayingConnected())
    #expect(store.selectedSection() == nil)

    store.setSection(.nowPlaying, visible: false)
    store.setMascotEnabled(false)
    store.setOpensOnHover(false)
    store.setShowsPillOnPlainDisplays(true)
    store.setNowPlayingConnected(true)
    store.setSelectedSection(.usage)

    #expect(store.visibleSections() == [.ensembles, .upNext, .usage])
    #expect(!store.isMascotEnabled())
    #expect(!store.opensOnHover())
    #expect(store.showsPillOnPlainDisplays())
    #expect(store.isNowPlayingConnected())
    #expect(store.selectedSection() == .usage)
}

// MARK: - Now Playing

@Test("NowPlayingTrack.fromNotification: reads Name, Artist, and Player State; bounds the text")
func nowPlayingNotificationParsing() {
    let playing = NowPlayingTrack.fromNotification([
        "Name": "Song", "Artist": "Band", "Player State": "Playing",
    ])
    #expect(playing == NowPlayingTrack(title: "Song", artist: "Band", playing: true))
    let paused = NowPlayingTrack.fromNotification(["Name": "Song", "Player State": "Paused"])
    #expect(paused == NowPlayingTrack(title: "Song", artist: "", playing: false))
    #expect(
        NowPlayingTrack.fromNotification(nil)
            == NowPlayingTrack(title: "", artist: "", playing: false))
    let long = NowPlayingTrack.fromNotification([
        "Name": String(repeating: "x", count: 10_000)
    ])
    #expect(long.title.count == NowPlayingTrack.maximumTextLength)
}

@Test("NowPlayingTracker: a paused player never displaces one that is playing")
func trackerPausedDoesNotReplacePlaying() {
    var tracker = NowPlayingTracker()
    tracker.accept(NowPlayingTrack(title: "Active", artist: "", playing: true), from: .music)
    tracker.accept(NowPlayingTrack(title: "Paused", artist: "", playing: false), from: .spotify)
    #expect(tracker.current?.track.title == "Active")
    tracker.accept(NowPlayingTrack(title: "Active", artist: "", playing: false), from: .music)
    tracker.accept(NowPlayingTrack(title: "Other", artist: "", playing: true), from: .spotify)
    #expect(tracker.current?.track.title == "Other")
    #expect(tracker.current?.player == .spotify)
}

@Test("NowPlayingTracker: a closed player clears its stale track")
func trackerPrunesClosedPlayers() {
    var tracker = NowPlayingTracker()
    tracker.accept(NowPlayingTrack(title: "Old", artist: "", playing: true), from: .music)
    tracker.prune(running: [])
    #expect(tracker.current == nil)
}

@Test("NowPlayingTracker: each accept bumps the player's revision, so a slower read can be dropped")
func trackerRevisions() {
    var tracker = NowPlayingTracker()
    let before = tracker.revision(of: .music)
    tracker.accept(NowPlayingTrack(title: "New", artist: "", playing: true), from: .music)
    #expect(tracker.revision(of: .music) == before + 1)
    #expect(tracker.revision(of: .spotify) == 0)
}

@Test("NowPlayingScripts: only fixed bundle ids and verbs reach a script")
func nowPlayingScriptsAreFixed() {
    for player in NowPlayingPlayer.allCases {
        let read = NowPlayingScripts.read(player)
        #expect(read.contains("application id \"\(player.rawValue)\""))
        #expect(read.contains("with timeout of 3 seconds"))
        for command in [NowPlayingCommand.playPause, .next, .previous] {
            let script = NowPlayingScripts.command(command, for: player)
            #expect(script.contains(command.verb))
            #expect(script.contains(player.rawValue))
        }
    }
    #expect(NowPlayingCommand.playPause.verb == "playpause")
    #expect(NowPlayingPlayer.music.notificationNames.contains("com.apple.Music.playerInfo"))
    #expect(
        NowPlayingPlayer.spotify.notificationNames == ["com.spotify.client.PlaybackStateChanged"])
}

// MARK: - Usage meters

@Test("NotchUsageMeter: fraction clamps to 0...1; nil for token and cost windows")
func usageMeterFraction() {
    #expect(NotchUsageMeter.fraction(percent: 50) == 0.5)
    #expect(NotchUsageMeter.fraction(percent: -5) == 0)
    #expect(NotchUsageMeter.fraction(percent: 140) == 1)
    #expect(NotchUsageMeter.fraction(percent: nil) == nil)
    #expect(NotchUsageMeter.fraction(percent: .nan) == nil)
}

@Test("NotchUsageMeter: levels use UsageDisplayPolicy's thresholds; critical adds a glyph")
func usageMeterLevelsAndText() {
    #expect(NotchUsageMeter.level(percent: 79) == .normal)
    #expect(NotchUsageMeter.level(percent: 80) == .high)
    #expect(NotchUsageMeter.level(percent: 95) == .critical)
    #expect(NotchUsageMeter.level(percent: nil) == .normal)
    let normal = UsageWindow(label: "5h", percent: 41.4, tokens: nil, resetsAt: nil)
    let critical = UsageWindow(label: "7d", percent: 97, tokens: nil, resetsAt: nil)
    let tokens = UsageWindow(label: "5h", percent: nil, tokens: 12_300, resetsAt: nil)
    let bare = UsageWindow(label: "5h", percent: nil, tokens: nil, resetsAt: nil)
    #expect(NotchUsageMeter.valueText(for: normal) == "41%")
    #expect(NotchUsageMeter.valueText(for: critical) == "97% ⚠")
    #expect(NotchUsageMeter.valueText(for: tokens) == "12.3K tok")
    #expect(NotchUsageMeter.valueText(for: bare) == nil)
}

// MARK: - Panel geometry and the plain-display pill

private let notchScreen = NotchScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
    visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1074),
    safeAreaTopInset: 33,
    auxiliaryTopLeft: CGRect(x: 0, y: 1074, width: 763, height: 33),
    auxiliaryTopRight: CGRect(x: 948, y: 1074, width: 762, height: 33),
    isBuiltin: true)

private let plainScreen = NotchScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055),
    safeAreaTopInset: 0,
    auxiliaryTopLeft: nil,
    auxiliaryTopRight: nil)

private let plainBuiltinScreen = NotchScreenMetrics(
    frame: CGRect(x: 2000, y: 0, width: 1440, height: 900),
    visibleFrame: CGRect(x: 2000, y: 0, width: 1440, height: 875),
    safeAreaTopInset: 0,
    auxiliaryTopLeft: nil,
    auxiliaryTopRight: nil,
    isBuiltin: true)

@Test("pillFrame: nil on a notched screen; top-centre under the menu bar on a plain one")
func pillFrameGeometry() throws {
    #expect(NotchCompanionGeometry.pillFrame(for: notchScreen) == nil)
    let pill = try #require(NotchCompanionGeometry.pillFrame(for: plainScreen))
    #expect(pill.width == NotchCompanionGeometry.pillWidth)
    #expect(pill.midX == plainScreen.frame.midX)
    // Hangs from the menu bar's bottom edge (visibleFrame.maxY), never over it.
    #expect(pill.maxY == plainScreen.visibleFrame.maxY)
    #expect(pill.height >= NotchCompanionGeometry.pillMinimumHeight)
    let wide = try #require(NotchCompanionGeometry.pillFrame(for: plainScreen, expanded: true))
    #expect(wide.width == NotchCompanionGeometry.pillExpandedWidth)
    #expect(wide.midX == pill.midX)
}

@Test("restingFrame: the strip on a notch; the pill only when allowed; otherwise none")
func restingFramePolicy() {
    #expect(NotchCompanionGeometry.restingFrame(for: notchScreen, allowsPill: false) != nil)
    #expect(NotchCompanionGeometry.restingFrame(for: plainScreen, allowsPill: false) == nil)
    #expect(NotchCompanionGeometry.restingFrame(for: plainScreen, allowsPill: true) != nil)
    #expect(NotchCompanionGeometry.expandedFrame(for: plainScreen, allowsPill: false) == nil)
}

@Test("peekPanelFrame: the open panel is a fixed size and stays on screen on both layouts")
func openPanelFrameIsFixed() {
    let notchHeight = notchScreen.safeAreaTopInset + NotchCompanionGeometry.openPanelBodyHeight
    let onNotch = NotchCompanionGeometry.peekPanelFrame(
        for: notchScreen, contentHeight: notchHeight)
    #expect(onNotch.width == NotchCompanionGeometry.panelWidth)
    #expect(onNotch.height == notchHeight)
    #expect(onNotch.maxY == notchScreen.frame.maxY)
    #expect(notchScreen.frame.contains(onNotch))

    let pillHeight =
        NotchCompanionGeometry.pillMinimumHeight
        + NotchCompanionGeometry.openPanelBodyHeight
    let onPlain = NotchCompanionGeometry.peekPanelFrame(
        for: plainScreen, contentHeight: pillHeight)
    #expect(onPlain.maxY == plainScreen.visibleFrame.maxY)
    #expect(plainScreen.frame.contains(onPlain))
}

@Test("preferredForCompanion: notch first, then the built-in display, then the first candidate")
func companionScreenSelection() {
    #expect(
        NotchScreenSelection.preferredForCompanion(from: [
            plainScreen, notchScreen, plainBuiltinScreen,
        ])
            == notchScreen)
    #expect(
        NotchScreenSelection.preferredForCompanion(from: [plainScreen, plainBuiltinScreen])
            == plainBuiltinScreen)
    #expect(NotchScreenSelection.preferredForCompanion(from: [plainScreen]) == plainScreen)
    #expect(NotchScreenSelection.preferredForCompanion(from: []) == nil)
    // The attention drop-down keeps following the key window.
    #expect(
        NotchScreenSelection.preferred(from: [plainScreen, plainBuiltinScreen]) == plainScreen)
}

@Test("companionArbitration: a peek is the open panel only with hover-to-open")
func arbitrationWithHoverOpen() {
    let withHover = CompanionHoverPolicy.companionArbitration(
        hoverState: .peeking, peekShowsPanel: true)
    #expect(withHover.routeToFeed && !withHover.showDropDown)
    let without = CompanionHoverPolicy.companionArbitration(
        hoverState: .peeking, peekShowsPanel: false)
    #expect(!without.routeToFeed && without.showDropDown)
    let resting = CompanionHoverPolicy.companionArbitration(
        hoverState: .resting, peekShowsPanel: true)
    #expect(!resting.routeToFeed && resting.showDropDown)
}

// MARK: - Dynamic Island policy

@Test("NotchSection.offered: Usage only on an island; unchanged on a notch or pill")
func islandOfferedSections() {
    let all = NotchSection.allCases
    #expect(NotchSection.offered(all, on: .island) == [.usage])
    #expect(NotchSection.offered([.ensembles], on: .island) == [.usage])
    #expect(NotchSection.offered(all, on: .notch) == all)
    #expect(NotchSection.offered([.ensembles, .usage], on: .pill) == [.ensembles, .usage])
    #expect(NotchSection.offered([.upNext], on: nil) == [.upNext])
}

@Test("onIslandTap toggles open and closed; onClick keeps its notch table")
func islandTapTable() {
    #expect(CompanionHoverPolicy.onIslandTap(.resting) == .pinned)
    #expect(CompanionHoverPolicy.onIslandTap(.peeking) == .pinned)
    #expect(CompanionHoverPolicy.onIslandTap(.pinned) == .resting)
    #expect(CompanionHoverPolicy.onClick(.resting) == .pinned)
    #expect(CompanionHoverPolicy.onClick(.peeking) == .pinned)
    #expect(CompanionHoverPolicy.onClick(.pinned) == .peeking)
}

@Test("effectiveOpensOnHover: never on an island; the preference elsewhere")
func islandEffectiveOpensOnHover() {
    for preference in [true, false] {
        #expect(
            !CompanionHoverPolicy.effectiveOpensOnHover(preference: preference, surface: .island))
        #expect(
            CompanionHoverPolicy.effectiveOpensOnHover(preference: preference, surface: .notch)
                == preference)
        #expect(
            CompanionHoverPolicy.effectiveOpensOnHover(preference: preference, surface: .pill)
                == preference)
        #expect(
            CompanionHoverPolicy.effectiveOpensOnHover(preference: preference, surface: nil)
                == preference)
    }
}

@Test("companionArbitration: with no feed every bell takes the drop-down; default unchanged")
func islandArbitrationWithoutFeed() {
    for state in [CompanionHoverState.resting, .peeking, .pinned] {
        for peek in [true, false] {
            let noFeed = CompanionHoverPolicy.companionArbitration(
                hoverState: state, peekShowsPanel: peek, feedAvailable: false)
            #expect(!noFeed.routeToFeed && noFeed.showDropDown)
            let withFeed = CompanionHoverPolicy.companionArbitration(
                hoverState: state, peekShowsPanel: peek, feedAvailable: true)
            let original = CompanionHoverPolicy.companionArbitration(
                hoverState: state, peekShowsPanel: peek)
            #expect(withFeed == original)
        }
    }
}

// MARK: - Panel layering (menu-bar overflow on macOS 27)

@Test(
    "CompanionPanelLayering: lowered only when collapsed on a notch on macOS 27+; never on the island pill"
)
func panelLayeringTable() {
    let lowered = CompanionPanelLayering(level: .belowMenuBar, leadingWingStartsHover: false)
    for os in [25, 26, 27, 28] {
        for surface in [NotchCompanionSurface.notch, .island, .pill, nil] {
            for state in [CompanionHoverState.resting, .peeking, .pinned] {
                for open in [false, true] {
                    for pending in [false, true] {
                        let result = CompanionPanelLayering.resolve(
                            osMajorVersion: os, surface: surface, hoverState: state,
                            isPanelOpen: open, isHoverPending: pending)
                        let collapsed = state == .resting && !open && !pending
                        let lowers =
                            os >= 27 && surface == .notch && collapsed
                        #expect(result == (lowers ? lowered : .standard))
                    }
                }
            }
        }
    }
    #expect(CompanionPanelLayering.standard.level == .statusBar)
    #expect(CompanionPanelLayering.standard.leadingWingStartsHover)
}

@Test("leadingWingWidth: the wing left of the notch or island reserve; nil on a plain screen")
func panelLayeringLeadingWingWidth() throws {
    let resting = try #require(NotchCompanionGeometry.restingStripFrame(for: notchScreen))
    #expect(NotchCompanionGeometry.leadingWingWidth(for: notchScreen, stripFrame: resting) == 44)
    let expanded = try #require(NotchCompanionGeometry.expandedStripFrame(for: notchScreen))
    #expect(NotchCompanionGeometry.leadingWingWidth(for: notchScreen, stripFrame: expanded) == 90)
    let pill = try #require(NotchCompanionGeometry.pillFrame(for: plainScreen))
    #expect(NotchCompanionGeometry.leadingWingWidth(for: plainScreen, stripFrame: pill) == nil)

    let island = NotchScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 993),
        visibleFrame: CGRect(x: 0, y: 75, width: 1512, height: 873),
        safeAreaTopInset: 40,
        auxiliaryTopLeft: CGRect(x: 0, y: 953, width: 726.5, height: 40),
        auxiliaryTopRight: CGRect(x: 785.5, y: 953, width: 726.5, height: 40),
        isBuiltin: true)
    let capsule = try #require(NotchIslandGeometry.restingFrame(for: island))
    #expect(NotchCompanionGeometry.leadingWingWidth(for: island, stripFrame: capsule) == 25)
}

// MARK: - Usage glance position (Dynamic Island Macs)

@Test("UsageGlancePosition: below the island by default and for an unknown stored value")
func usageGlancePositionResolvesStoredValue() {
    #expect(UsageGlancePosition.resolve(stored: nil) == .belowIsland)
    #expect(UsageGlancePosition.resolve(stored: "somewhere") == .belowIsland)
    #expect(UsageGlancePosition.resolve(stored: "menuBar") == .menuBar)
    #expect(UsageGlancePosition.resolve(stored: "belowIsland") == .belowIsland)
}

@Test("NotchDisplayPreferenceStore: usage glance position defaults and round-trips")
func usageGlancePositionStoreRoundTrip() {
    let suite = TestDefaultsSuite.name("dev.rafu.tests.usage-glance-position")
    defer { TestDefaultsSuite.remove(suite) }
    let store = NotchDisplayPreferenceStore(suiteName: suite)
    #expect(store.usageGlancePosition() == .belowIsland)
    store.setUsageGlancePosition(.menuBar)
    #expect(store.usageGlancePosition() == .menuBar)
    #expect(NotchDisplayPreferenceStore(suiteName: suite).usageGlancePosition() == .menuBar)
    store.setUsageGlancePosition(.belowIsland)
    #expect(store.usageGlancePosition() == .belowIsland)
}

@Test("CompanionPresence: only an island Mac with the menu bar position gets a status item")
func companionPresenceTable() {
    let panelOnly = CompanionPresence(showsPanel: true, showsMenuBarItem: false)
    let itemOnly = CompanionPresence(showsPanel: false, showsMenuBarItem: true)
    let surfaces: [NotchCompanionSurface?] = [.notch, .island, .pill, nil]
    for surface in surfaces {
        for position in UsageGlancePosition.allCases {
            let disabled = CompanionPresence.resolve(
                surface: surface, position: position, isEnabled: false)
            #expect(disabled == .none)

            let enabled = CompanionPresence.resolve(
                surface: surface, position: position, isEnabled: true)
            switch (surface, position) {
            case (nil, _): #expect(enabled == .none)
            case (.island, .menuBar): #expect(enabled == itemOnly)
            default: #expect(enabled == panelOnly)
            }
        }
    }
}

@Test("UsageMenuBarItemText: percent, critical mark, and the no-data form")
func usageMenuBarItemTextFormats() {
    let normal = NotchIslandUsageGlance(
        fraction: 0.83, percentText: "83%", level: .normal, tone: .primary,
        spokenLabel: "Usage: Claude, 5-hour session 83%")
    let critical = NotchIslandUsageGlance(
        fraction: 0.97, percentText: "97%", level: .critical, tone: .secondary,
        spokenLabel: "Usage: Claude, Weekly 97%, critical")

    #expect(UsageMenuBarItemText.title(for: normal) == "83%")
    #expect(UsageMenuBarItemText.title(for: critical) == "97%!")
    #expect(UsageMenuBarItemText.title(for: nil) == "")

    #expect(
        UsageMenuBarItemText.accessibilityLabel(for: normal)
            == "Rafu usage. Usage: Claude, 5-hour session 83%")
    #expect(UsageMenuBarItemText.accessibilityLabel(for: nil) == "Rafu usage. No usage data")
}

@Test("UsageMenuBarItemText.ringSize: 16 pt on a 45 pt bar, never below 12 pt")
func usageMenuBarRingSize() {
    #expect(UsageMenuBarItemText.ringSize(forBarThickness: 45) == 16)
    #expect(UsageMenuBarItemText.ringSize(forBarThickness: 24) == 14)
    #expect(UsageMenuBarItemText.ringSize(forBarThickness: 10) == 12)
}
