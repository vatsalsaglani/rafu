import Foundation
import Testing

@testable import RafuApp

@Suite("Agent activity summary")
struct AgentActivitySummaryTests {
    private func entry(
        _ provider: ConductorCLIID?, live: Bool = true, attention: Bool = false
    ) -> AgentActivitySummary.Entry {
        .init(provider: provider, isLive: live, needsAttention: attention)
    }

    @Test("No terminals means no activity")
    func empty() {
        let summary = AgentActivitySummary(entries: [])
        #expect(!summary.isActive)
        #expect(summary.runningCount == 0)
        #expect(summary.providers.isEmpty)
        #expect(summary.attentionLabel == nil)
    }

    @Test("Shells and exited agents are not counted")
    func ignoresShellsAndExited() {
        let summary = AgentActivitySummary(entries: [
            entry(nil), entry(.codex, live: false), entry(nil, attention: true),
        ])
        #expect(!summary.isActive)
    }

    @Test("One agent reads singular, several read plural")
    func labels() {
        #expect(AgentActivitySummary(entries: [entry(.claudeCode)]).label == "1 agent running")
        let two = AgentActivitySummary(entries: [entry(.claudeCode), entry(.codex)])
        #expect(two.label == "2 agents running")
        #expect(two.runningCount == 2)
    }

    @Test("Providers are distinct and keep first-seen order")
    func providersAreDistinct() {
        let summary = AgentActivitySummary(entries: [
            entry(.codex), entry(.claudeCode), entry(.codex), entry(.kimi, live: false),
        ])
        #expect(summary.providers == [.codex, .claudeCode])
        #expect(summary.runningCount == 3)
    }

    @Test("Attention is counted only for running agents and is worded")
    func attention() {
        let one = AgentActivitySummary(entries: [
            entry(.claudeCode, attention: true), entry(.codex), entry(nil, attention: true),
        ])
        #expect(one.attentionCount == 1)
        #expect(one.attentionLabel == "1 needs attention")
        #expect(one.accessibilityLabel == "2 agents running, 1 needs attention")
        let two = AgentActivitySummary(entries: [
            entry(.claudeCode, attention: true), entry(.codex, attention: true),
        ])
        #expect(two.attentionLabel == "2 need attention")
    }
}

@Suite("Titlebar double-click action")
struct TitlebarDoubleClickActionTests {
    @Test("An unset preference zooms, the system default")
    func defaultZooms() {
        #expect(
            TitlebarDoubleClickAction.resolve(actionPreference: nil, miniaturizePreference: nil)
                == .zoom)
    }

    @Test(
        "The action preference maps to zoom, minimise, or nothing",
        arguments: [
            ("Maximize", TitlebarDoubleClickAction.zoom),
            ("Zoom", TitlebarDoubleClickAction.zoom),
            ("Minimize", TitlebarDoubleClickAction.minimize),
            ("minimize", TitlebarDoubleClickAction.minimize),
            ("None", TitlebarDoubleClickAction.none),
            ("Something else", TitlebarDoubleClickAction.zoom),
        ])
    func actionPreference(value: String, expected: TitlebarDoubleClickAction) {
        #expect(
            TitlebarDoubleClickAction.resolve(actionPreference: value, miniaturizePreference: nil)
                == expected)
    }

    @Test("The legacy boolean applies only when the string is unset")
    func legacyBoolean() {
        #expect(
            TitlebarDoubleClickAction.resolve(actionPreference: nil, miniaturizePreference: true)
                == .minimize)
        #expect(
            TitlebarDoubleClickAction.resolve(actionPreference: nil, miniaturizePreference: false)
                == .zoom)
        #expect(
            TitlebarDoubleClickAction.resolve(
                actionPreference: "Maximize", miniaturizePreference: true) == .zoom)
    }

    @Test("Reading from a defaults suite follows the stored string")
    func readsDefaults() throws {
        let suiteName = TestDefaultsSuite.name("TitlebarDoubleClickActionTests")
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsSuite.remove(suiteName) }
        #expect(TitlebarDoubleClickAction.current(defaults: defaults) == .zoom)
        defaults.set("Minimize", forKey: "AppleActionOnDoubleClick")
        #expect(TitlebarDoubleClickAction.current(defaults: defaults) == .minimize)
        defaults.set("None", forKey: "AppleActionOnDoubleClick")
        #expect(TitlebarDoubleClickAction.current(defaults: defaults) == .none)
    }
}
