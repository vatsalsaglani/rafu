import AppKit
import Foundation
import RafuCore
import SwiftUI
import Testing

@testable import RafuApp

/// A user theme with only the required keys, so every optional token falls
/// back (as an older custom theme would).
private func customTheme(appearance: String, accent: String, background: String, ink: String)
    throws -> RafuTheme
{
    let json = """
        {
          "name": "Custom \(appearance)", "appearance": "\(appearance)",
          "ui": {
            "appBackground": "\(background)", "editorBackground": "\(background)",
            "elevatedBackground": "\(background)", "textPrimary": "\(ink)",
            "textSecondary": "\(ink)", "accent": "\(accent)",
            "borderSubtle": "#808080", "selection": "#808080"
          },
          "editor": {
            "background": "\(background)", "foreground": "\(ink)", "cursor": "\(ink)",
            "selectionBackground": "#808080", "lineHighlight": "#808080"
          },
          "syntax": { "keyword": { "color": "#CC88FF" } }
        }
        """
    return try JSONDecoder().decode(RafuTheme.self, from: Data(json.utf8))
}

private func rgb(_ color: Color) -> (red: Double, green: Double, blue: Double) {
    let srgb = NSColor(color).usingColorSpace(.sRGB) ?? .black
    return (Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent))
}

private func luminance(_ color: Color) -> Double {
    let value = rgb(color)
    return 0.2126 * value.red + 0.7152 * value.green + 0.0722 * value.blue
}

private func same(_ left: Color, _ right: Color) -> Bool {
    let a = rgb(left)
    let b = rgb(right)
    return abs(a.red - b.red) < 0.01 && abs(a.green - b.green) < 0.01
        && abs(a.blue - b.blue) < 0.01
}

@Suite("Voice presence (app)")
@MainActor
struct VoicePresenceAppTests {
    private static func themes() throws -> [RafuTheme] {
        [
            RafuThemeCatalog.indigo,
            RafuThemeCatalog.khadi,
            try customTheme(
                appearance: "dark", accent: "#33CC99", background: "#101418", ink: "#EEEEEE"),
            try customTheme(
                appearance: "light", accent: "#CC3366", background: "#FAFAF5", ink: "#202020"),
        ]
    }

    @Test("The orb palette builds from Indigo, Khadi and custom themes, light and dark")
    func paletteFollowsTheme() throws {
        for theme in try Self.themes() {
            for contrast in [false, true] {
                let palette = VoiceOrbPalette(theme: theme, increaseContrast: contrast)
                #expect(palette.lobes.count == 4, Comment(rawValue: theme.name))
                // The orb is a dark sphere on every theme.
                #expect(luminance(palette.base) < 0.3, Comment(rawValue: theme.name))
                // The ring is the theme accent, never a fixed brand colour.
                #expect(same(palette.ring, theme.palette.accent), Comment(rawValue: theme.name))
                // The light tone is lighter than the base.
                #expect(luminance(palette.light) > luminance(palette.base))
                #expect(palette.rimShade == (contrast ? 0.55 : 0.35))
            }
        }
    }

    @Test("A custom accent reaches the lobes; themes give different orbs")
    func customAccent() throws {
        let green = try customTheme(
            appearance: "dark", accent: "#33CC99", background: "#101418", ink: "#EEEEEE")
        let pink = try customTheme(
            appearance: "dark", accent: "#CC3366", background: "#101418", ink: "#EEEEEE")
        let greenPalette = VoiceOrbPalette(theme: green)
        let pinkPalette = VoiceOrbPalette(theme: pink)
        #expect(same(greenPalette.lobes[1], green.palette.accent))
        #expect(!same(greenPalette.lobes[1], pinkPalette.lobes[1]))
        #expect(
            !same(
                VoiceOrbPalette(theme: RafuThemeCatalog.indigo).ring,
                VoiceOrbPalette(theme: RafuThemeCatalog.khadi).ring)
                || !same(
                    VoiceOrbPalette(theme: RafuThemeCatalog.indigo).base,
                    VoiceOrbPalette(theme: RafuThemeCatalog.khadi).base)
        )
    }

    @Test("The sampler runs only while something moves the orb and motion is allowed")
    func samplerGate() {
        let listening = VoiceOrbPose.pose(for: .listeningLatched, micOpen: true, latched: true)
        let idle = VoiceOrbPose.pose(for: .idle, micOpen: false, latched: false)
        let paused = VoiceOrbPose.pose(for: .paused, micOpen: false, latched: false)
        let connecting = VoiceOrbPose.pose(for: .connecting, micOpen: true, latched: false)
        typealias Sampler = VoicePresenceSampler
        #expect(Sampler.isActive(pose: listening, motionAllowed: true, reduceMotion: false))
        #expect(Sampler.isActive(pose: connecting, motionAllowed: true, reduceMotion: false))
        #expect(!Sampler.isActive(pose: idle, motionAllowed: true, reduceMotion: false))
        #expect(!Sampler.isActive(pose: paused, motionAllowed: true, reduceMotion: false))
        #expect(!Sampler.isActive(pose: listening, motionAllowed: false, reduceMotion: false))
        #expect(!Sampler.isActive(pose: listening, motionAllowed: true, reduceMotion: true))
        #expect(Sampler.interval == .milliseconds(50))
    }

    @Test("An inactive sampler returns at once and leaves a still frame")
    func samplerInactive() async {
        let sampler = VoicePresenceSampler()
        let session = VoiceSession(dependencies: .live)
        await sampler.run(active: false, session: session) {
            VoiceOrbPose.pose(for: .idle, micOpen: false, latched: false)
        }
        #expect(sampler.snapshot.level == 0)
        #expect(sampler.snapshot.ripple == 0)
    }

    @Test("The corner is remembered per workspace and moves by keyboard")
    func companionCorner() throws {
        let suite = TestDefaultsSuite.name("dev.rafu.voice-companion")
        defer { TestDefaultsSuite.remove(suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let model = VoiceCompanionModel(defaults: defaults)
        model.load(workspacePath: "/tmp/api")
        #expect(model.corner == .bottomTrailing)
        model.move(.up)
        #expect(model.corner == .topTrailing)
        model.load(workspacePath: "/tmp/web")
        #expect(model.corner == .bottomTrailing)
        model.snap(to: .bottomLeading)

        let reopened = VoiceCompanionModel(defaults: defaults)
        reopened.load(workspacePath: "/tmp/api")
        #expect(reopened.corner == .topTrailing)
        reopened.load(workspacePath: "/tmp/web")
        #expect(reopened.corner == .bottomLeading)
        reopened.moveToNextCorner()
        #expect(reopened.corner == .topLeading)
    }

    @Test("A card dragged over the orb tucks it; it returns after the drag")
    func companionTuck() async throws {
        let model = VoiceCompanionModel(defaults: .standard, untuckDelay: .milliseconds(1))
        model.slotFrame = CGRect(x: 800, y: 500, width: 96, height: 96)
        model.noteBoardDrag(at: CGPoint(x: 100, y: 100))
        #expect(!model.isTucked)
        model.noteBoardDrag(at: CGPoint(x: 850, y: 540))
        #expect(model.isTucked)
        model.boardDragEnded()
        #expect(model.isTucked)
        let untuck = try #require(model.pendingUntuck)
        await untuck.value
        #expect(!model.isTucked)
        #expect(model.pendingUntuck == nil)
    }
}
