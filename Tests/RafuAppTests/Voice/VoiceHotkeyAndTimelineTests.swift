import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Voice hot key and timeline")
@MainActor
struct VoiceHotkeyAndTimelineTests {
    private static func entry(enabled: Bool, key: Int, modifiers: Int) -> [String: Any] {
        [
            "enabled": enabled,
            "value": ["parameters": [32, key, modifiers], "type": "standard"] as [String: Any],
        ]
    }

    @Test("⌃⌥Space collides with the input-source shortcut only when it is on")
    func conflict() {
        let controlOption = 0x40000 | 0x80000
        #expect(VoiceHotkeyConflict.chordIsTaken(symbolicHotKeys: nil))
        #expect(
            VoiceHotkeyConflict.chordIsTaken(symbolicHotKeys: [
                "61": Self.entry(enabled: true, key: 49, modifiers: controlOption)
            ]))
        #expect(
            !VoiceHotkeyConflict.chordIsTaken(symbolicHotKeys: [
                "61": Self.entry(enabled: false, key: 49, modifiers: controlOption)
            ]))
        #expect(
            !VoiceHotkeyConflict.chordIsTaken(symbolicHotKeys: [
                "61": Self.entry(enabled: true, key: 49, modifiers: controlOption | 0x20000)
            ]))
        // "Previous source" moved onto ⌃⌥Space also counts.
        #expect(
            VoiceHotkeyConflict.chordIsTaken(symbolicHotKeys: [
                "60": Self.entry(enabled: true, key: 49, modifiers: controlOption),
                "61": Self.entry(enabled: false, key: 49, modifiers: controlOption),
            ]))
    }

    @Test("The hot key installs and uninstalls cleanly, and can install again")
    func installUninstall() {
        let hotkey = VoiceHotkey()
        hotkey.install()
        #expect(hotkey.isInstalled)
        hotkey.uninstall()
        #expect(!hotkey.isInstalled)
        #expect(!hotkey.isGlobal)
        hotkey.install()
        #expect(hotkey.isInstalled)
        hotkey.uninstall()
        #expect(!hotkey.isInstalled)
    }

    @Test("Timeline rows read as text: id, title, start and duration")
    func timelineFormat() {
        let done = VoiceTimelineEvent(
            id: "#4", lane: .tool, startMS: 12_400, endMS: 13_200, persona: "Rafu",
            title: "note_create", detail: "ok")
        #expect(VoiceTimelineFormat.timing(done) == "+12.4 s · 0.8 s")
        #expect(VoiceTimelineFormat.spoken(done) == "#4, note_create, ok, at 12.4 s, took 0.8 s")
        let running = VoiceTimelineEvent(
            id: "#5", lane: .delegation, startMS: 500, persona: "Rafu", title: "Delegation")
        #expect(VoiceTimelineFormat.timing(running) == "+0.5 s · running")
        #expect(VoiceTimelinePopover.title(.board) == "Board effects")
        #expect(
            VoiceTimelineEvent.Lane.allCases.map(VoiceTimelinePopover.title) == [
                "You", "Rafu", "Delegations", "Tools", "Board effects",
            ])
    }
}
