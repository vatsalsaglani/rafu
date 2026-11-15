import Foundation
import Testing

@testable import RafuApp

// The menu bar card (ADR 0037 amendment): which sections each host offers,
// the tab it opens on, where outside-agent notices go, the Up next and
// Agents content rules, the status item text, and the feed routing while
// the card is open. Pure functions, plus the model's popover lifecycle on
// its own `NotchCompanionModel()` (never `.shared`, never activated).

// MARK: - Sections per host

@Test("NotchSection.offered(host:): menu bar offers Agents, Up next, Usage; never Now Playing")
func menuBarOfferedSections() {
    let all = NotchSection.allCases
    #expect(NotchSection.offered(all, host: .menuBar) == [.ensembles, .upNext, .usage])
    #expect(NotchSection.offered([.upNext], host: .menuBar) == [.upNext, .usage])
    // Usage stays: the status item is the usage glance.
    #expect(
        NotchSection.offered([.ensembles, .nowPlaying], host: .menuBar) == [.ensembles, .usage])
    #expect(NotchSection.offered(all, host: .islandCard) == [.usage])
    #expect(NotchSection.offered(all, host: .notchPanel) == all)
}

@Test("CompanionHost.panel: the island card on an island, the notch panel elsewhere")
func panelHostPerSurface() {
    #expect(CompanionHost.panel(on: .island) == .islandCard)
    #expect(CompanionHost.panel(on: .notch) == .notchPanel)
    #expect(CompanionHost.panel(on: .pill) == .notchPanel)
    #expect(CompanionHost.panel(on: nil) == .notchPanel)
}

@Test("NotchSection: the ensembles tab reads Agents and keeps its stored key")
func agentsTabTitle() {
    #expect(NotchSection.ensembles.title == "Agents")
    #expect(NotchSection.ensembles.defaultsKey == "notchSection.ensembles")
    #expect(NotchSection.allCases.allSatisfy { !$0.title.contains("Canvas") })
}

// MARK: - Menu selection

@Test("CompanionMenuSelection.initial: Up next on attention, else remembered, else first")
func menuInitialSelection() {
    let offered: [NotchSection] = [.ensembles, .upNext, .usage]
    #expect(
        CompanionMenuSelection.initial(remembered: .usage, offered: offered, attention: 2)
            == .upNext)
    #expect(
        CompanionMenuSelection.initial(remembered: .usage, offered: offered, attention: 0)
            == .usage)
    #expect(
        CompanionMenuSelection.initial(remembered: .nowPlaying, offered: offered, attention: 0)
            == .ensembles)
    #expect(
        CompanionMenuSelection.initial(
            remembered: nil, offered: [.ensembles, .usage], attention: 3)
            == .ensembles)
}

@Test("CompanionMenuSelection.step: arrows move one tab and stop at the ends")
func menuStepClamps() {
    let offered: [NotchSection] = [.ensembles, .upNext, .usage]
    #expect(CompanionMenuSelection.step(from: .upNext, in: offered, by: 1) == .usage)
    #expect(CompanionMenuSelection.step(from: .usage, in: offered, by: 1) == .usage)
    #expect(CompanionMenuSelection.step(from: .ensembles, in: offered, by: -1) == .ensembles)
    #expect(CompanionMenuSelection.step(from: .nowPlaying, in: offered, by: 1) == .ensembles)
}

@Test("NotchDisplayPreferenceStore: the menu bar tab is remembered apart from the notch tab")
func menuBarSelectionRoundTrip() {
    let suite = TestDefaultsSuite.name("dev.rafu.tests.menu-selection")
    defer { TestDefaultsSuite.remove(suite) }
    let store = NotchDisplayPreferenceStore(suiteName: suite)
    #expect(store.menuBarSelectedSection() == nil)
    store.setSelectedSection(.nowPlaying)
    store.setMenuBarSelectedSection(.usage)
    #expect(store.menuBarSelectedSection() == .usage)
    #expect(store.selectedSection() == .nowPlaying)
}

// MARK: - Outside-agent notices go to the surface in use

@Test("CompanionHost.outsideNotices: menu bar card or notch panel, never both")
func outsideNoticesRouting() {
    #expect(CompanionHost.outsideNotices(surface: .island, position: .menuBar) == .menuBar)
    #expect(CompanionHost.outsideNotices(surface: .island, position: .belowIsland) == nil)
    for position in UsageGlancePosition.allCases {
        #expect(CompanionHost.outsideNotices(surface: .notch, position: position) == .notchPanel)
        #expect(CompanionHost.outsideNotices(surface: .pill, position: position) == .notchPanel)
        #expect(CompanionHost.outsideNotices(surface: nil, position: position) == nil)
    }
}

private func row(_ title: String, _ phase: NotchAgentPhase, window: UUID? = UUID())
    -> NotchAgentRow
{
    NotchAgentRow(id: UUID(), title: title, cli: .claudeCode, phase: phase, windowID: window)
}

@Test("upNextRows: needs-you first, then reply ready; outside rows only when given")
func upNextOrdering() {
    let rafuReply = row("rafu reply", .replyReady)
    let rafuWorking = row("rafu working", .working)
    let rafuNeeds = row("rafu needs", .needsYou)
    let outsideNeeds = row("outside needs", .needsYou, window: nil)
    let outsideIdle = row("outside idle", .idle, window: nil)

    let menu = NotchCompanionModel.upNextRows(
        rafu: [rafuReply, rafuWorking, rafuNeeds], outside: [outsideNeeds, outsideIdle])
    #expect(menu.map(\.title) == ["rafu needs", "outside needs", "rafu reply"])

    let elsewhere = NotchCompanionModel.upNextRows(
        rafu: [rafuReply, rafuWorking, rafuNeeds], outside: [])
    #expect(elsewhere.map(\.title) == ["rafu needs", "rafu reply"])
    #expect(NotchCompanionModel.upNextRows(rafu: [rafuWorking], outside: []).isEmpty)
}

@Test("CompanionUpNextContent.waitingRows: drops sessions that already show a feed card")
func waitingRowsSkipFeed() {
    let first = row("first", .needsYou)
    let second = row("second", .replyReady)
    #expect(
        CompanionUpNextContent.waitingRows([first, second], feedSessionIDs: [first.id])
            == [second])
    #expect(CompanionUpNextContent.waitingRows([first, second], feedSessionIDs: []).count == 2)
}

// MARK: - Agents empty states

@Test("CompanionAgentsContent: list, filter miss, and each host's empty line")
func agentsEmptyStates() {
    #expect(
        CompanionAgentsContent.resolve(editorCount: 1, outsideCount: 0, query: "", host: .menuBar)
            == .list)
    #expect(
        CompanionAgentsContent.resolve(editorCount: 0, outsideCount: 2, query: "", host: .menuBar)
            == .list)
    #expect(
        CompanionAgentsContent.resolve(
            editorCount: 0, outsideCount: 2, query: "api", host: .notchPanel)
            == .empty("No editors match “api”"))
    #expect(
        CompanionAgentsContent.resolve(editorCount: 0, outsideCount: 0, query: "", host: .menuBar)
            == .empty("No agents running. Start one in a terminal or an Ensemble."))
    #expect(
        CompanionAgentsContent.resolve(
            editorCount: 0, outsideCount: 0, query: " ", host: .notchPanel)
            == .empty("No open editors"))
}

// MARK: - Status item text

@Test("CompanionMenuBarItemText: the attention count joins the percent as text")
func statusItemText() {
    let glance = NotchIslandUsageGlance(
        fraction: 0.42, percentText: "42%", level: .normal, tone: .primary,
        spokenLabel: "Usage: Claude, 5-hour session 42%")
    let critical = NotchIslandUsageGlance(
        fraction: 0.97, percentText: "97%", level: .critical, tone: .secondary,
        spokenLabel: "Usage: Claude, Weekly 97%, critical")

    #expect(CompanionMenuBarItemText.title(glance: glance, attention: 0) == "42%")
    #expect(CompanionMenuBarItemText.title(glance: glance, attention: 2) == "42% · 2")
    #expect(CompanionMenuBarItemText.title(glance: critical, attention: 1) == "97%! · 1")
    #expect(CompanionMenuBarItemText.title(glance: nil, attention: 3) == "3")
    #expect(CompanionMenuBarItemText.title(glance: nil, attention: 0) == "")
    #expect(CompanionMenuBarItemText.title(glance: glance, attention: 120) == "42% · 99+")

    #expect(
        CompanionMenuBarItemText.accessibilityLabel(glance: glance, attention: 2)
            == "Rafu usage. Usage: Claude, 5-hour session 42%. 2 agents need you")
    #expect(
        CompanionMenuBarItemText.accessibilityLabel(glance: nil, attention: 1)
            == "Rafu usage. No usage data. 1 agent needs you")
    #expect(
        CompanionMenuBarItemText.accessibilityLabel(glance: glance, attention: 0)
            == "Rafu usage. Usage: Claude, 5-hour session 42%")
}

// MARK: - Feed routing while the card is open

@Test("companionArbitration: an open menu bar card takes the bell; closed keeps the drop-down")
func menuPopoverArbitration() {
    let open = CompanionHoverPolicy.companionArbitration(
        hoverState: .resting, feedAvailable: true, menuPopoverShown: true)
    #expect(open.routeToFeed && !open.showDropDown)
    let closed = CompanionHoverPolicy.companionArbitration(
        hoverState: .resting, feedAvailable: false, menuPopoverShown: false)
    #expect(!closed.routeToFeed && closed.showDropDown)
}

@MainActor
@Test("Menu popover lifecycle: feed opens on show, snippets drop on close")
func menuPopoverLifecycle() {
    let suite = TestDefaultsSuite.name("dev.rafu.tests.menu-popover")
    defer { TestDefaultsSuite.remove(suite) }
    let model = NotchCompanionModel()
    model.displayPreferences = NotchDisplayPreferenceStore(suiteName: suite)
    model.displayPreferences.setMenuBarSelectedSection(.usage)
    model.setSurfaceForTesting(.island)
    #expect(!model.isAttentionFeedAvailable)

    model.menuPopoverWillShow()
    #expect(model.isMenuPopoverShown)
    #expect(model.isAttentionFeedAvailable)
    #expect(model.sections(for: .menuBar) == [.ensembles, .upNext, .usage])
    #expect(model.selection(for: .menuBar) == .usage)
    // The island card keeps Usage only.
    #expect(model.sections(for: .islandCard) == [.usage])

    model.select(.ensembles, host: .menuBar)
    #expect(model.selection(for: .menuBar) == .ensembles)
    #expect(model.displayPreferences.menuBarSelectedSection() == .ensembles)

    model.pushFeedItem(
        CompanionFeedItem(
            id: UUID(), sessionID: UUID(), title: "zsh 1", editorName: "rafu", snippet: "s",
            timestamp: Date(), color: nil))
    #expect(model.feedItems.count == 1)

    model.menuPopoverDidClose()
    #expect(!model.isMenuPopoverShown)
    #expect(model.feedItems.isEmpty)
    #expect(!model.isAttentionFeedAvailable)
}
