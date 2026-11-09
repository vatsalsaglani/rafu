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
                #expect(palette.leaf.count == 3, Comment(rawValue: theme.name))
                // Translucent glass: thin in the middle, thicker at the rim.
                #expect(palette.centreAlpha < palette.rimAlpha)
                #expect(palette.rimAlpha < 1)
                #expect(palette.solidBase == nil)
                #expect(palette.outlineWidth == (contrast ? 2 : 1))
                // Light dots on a dark board, dark dots on a light board.
                if theme.isDark {
                    #expect(luminance(palette.ink) > 0.7, Comment(rawValue: theme.name))
                } else {
                    #expect(luminance(palette.ink) < 0.4, Comment(rawValue: theme.name))
                }
            }
        }
        let solid = VoiceOrbPalette(theme: RafuThemeCatalog.indigo, reduceTransparency: true)
        #expect(solid.solidBase != nil)
    }

    @Test("A custom accent reaches the cat's-eye; themes give different orbs")
    func customAccent() throws {
        let green = try customTheme(
            appearance: "dark", accent: "#33CC99", background: "#101418", ink: "#EEEEEE")
        let pink = try customTheme(
            appearance: "dark", accent: "#CC3366", background: "#101418", ink: "#EEEEEE")
        let greenPalette = VoiceOrbPalette(theme: green)
        let pinkPalette = VoiceOrbPalette(theme: pink)
        #expect(same(greenPalette.leaf[0], green.palette.accent.mix(with: .white, by: 0.1)))
        #expect(!same(greenPalette.leaf[0], pinkPalette.leaf[0]))
        #expect(
            !same(
                VoiceOrbPalette(theme: RafuThemeCatalog.indigo).ink,
                VoiceOrbPalette(theme: RafuThemeCatalog.khadi).ink))
    }

    @Test("Without motion the animator writes one still frame and returns")
    func animatorStill() async {
        let animator = VoiceOrbAnimator()
        await animator.run(face: .paused, animated: false) { (0, 0) }
        #expect(animator.frame.face == .paused)
        #expect(animator.frame.drawn.expression == .target(for: .paused))
        #expect(animator.frame.drawn.level == 0)
        await animator.runBlinks(enabled: false)
        #expect(animator.frame.blink == 0)
    }

    @Test("A face with no clock settles and the loop ends by itself")
    func animatorSettles() async {
        let animator = VoiceOrbAnimator()
        await animator.run(face: .needsConfirm, animated: true) { (0, 0) }
        #expect(animator.frame.face == .needsConfirm)
        #expect(animator.frame.drawn.expression == .target(for: .needsConfirm))
    }

    @Test("Chrome rects move into the host's space; the slot avoids them")
    func avoidRects() {
        let model = VoiceCompanionModel(defaults: .standard)
        model.containerSize = CGSize(width: 1_000, height: 700)
        model.hostOrigin = CGPoint(x: 200, y: 50)
        let natural = model.slotRect
        // Global rect of a zoom corner at the host's bottom-trailing corner.
        let chrome = CGRect(
            x: 200 + 1_000 - 12 - 170, y: 50 + 700 - 12 - 126, width: 170, height: 126)
        model.setAvoidRect(chrome, for: "board.a")
        #expect(model.localAvoidRects == [chrome.offsetBy(dx: -200, dy: -50)])
        #expect(model.slotRect.maxY < natural.maxY)
        #expect(!model.slotRect.intersects(model.localAvoidRects[0]))
        model.setAvoidRect(nil, for: "board.a")
        #expect(model.slotRect == natural)
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
