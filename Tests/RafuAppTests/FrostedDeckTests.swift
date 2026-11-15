import AppKit
import Foundation
import SwiftUI
import Testing

@testable import RafuApp

/// The frosted deck (ADR 0038, steps 2 and 3): the resolver table for the
/// frame tint, deck, card and content opacities; the layer alphas that keep
/// two translucent fills from stacking; and the editor and terminal
/// background mappings.
@Suite("Frosted deck")
struct FrostedDeckTests {
    private typealias Preference = WindowSurfacePreference

    private static func resolve(
        _ style: String?, _ level: String?, isDark: Bool, frostsContent: Bool = true,
        reduceTransparency: Bool = false, increaseContrast: Bool = false
    ) -> Preference.Resolved {
        Preference.resolve(
            style: style, level: level, frostsContent: frostsContent, isDark: isDark,
            reduceTransparency: reduceTransparency, increaseContrast: increaseContrast)
    }

    private struct Row: Sendable {
        let level: String
        let isDark: Bool
        let tint: Double
        let deck: Double
        let card: Double
    }

    /// The whole table, one row per strength and appearance.
    private static let table: [Row] = [
        Row(level: "subtle", isDark: true, tint: 0.62, deck: 0.90, card: 0.96),
        Row(level: "balanced", isDark: true, tint: 0.50, deck: 0.82, card: 0.94),
        Row(level: "strong", isDark: true, tint: 0.38, deck: 0.72, card: 0.90),
        Row(level: "subtle", isDark: false, tint: 0.86, deck: 0.94, card: 0.98),
        Row(level: "balanced", isDark: false, tint: 0.74, deck: 0.88, card: 0.96),
        Row(level: "strong", isDark: false, tint: 0.60, deck: 0.80, card: 0.93),
    ]

    @Test(
        "Resolver table: strength x appearance x content switch",
        arguments: [true, false])
    func resolverTable(frostsContent: Bool) {
        for row in Self.table {
            let surface = Self.resolve(
                "frosted", row.level, isDark: row.isDark, frostsContent: frostsContent)
            let label = "\(row.level) \(row.isDark ? "dark" : "light") \(frostsContent)"
            #expect(surface.isFrosted, "\(label)")
            #expect(surface.tintOpacity == row.tint, "\(label)")
            #expect(surface.deckOpacity == row.deck, "\(label)")
            #expect(surface.cardOpacity == row.card, "\(label)")
            #expect(surface.frostsContent == frostsContent, "\(label)")
            #expect(surface.contentOpacity == (frostsContent ? row.deck : 1), "\(label)")
        }
    }

    @Test("Solid, and Solid forced by accessibility, paint every surface opaque")
    func solidIsOpaqueEverywhere() {
        let solids: [Preference.Resolved] = [
            Self.resolve(nil, nil, isDark: true),
            Self.resolve("solid", "strong", isDark: false),
            Self.resolve("frosted", "strong", isDark: true, reduceTransparency: true),
            Self.resolve("frosted", "strong", isDark: false, increaseContrast: true),
        ]
        for surface in solids {
            #expect(surface == .solid)
            #expect(surface.tintOpacity == 1)
            #expect(surface.deckOpacity == 1)
            #expect(surface.cardOpacity == 1)
            #expect(surface.contentOpacity == 1)
            #expect(!surface.frostsContent)
            for layer in Preference.DeckLayer.allCases {
                #expect(surface.paintOpacity(for: layer) == (layer == .frostedBase ? 0 : 1))
            }
            #expect(Preference.terminalBackgroundAlpha(surface) == 1)
        }
    }

    @Test("The middle stays calmer than the frame, and cards calmer than the board")
    func opacitiesAreOrdered() {
        for row in Self.table {
            #expect(row.tint < row.deck)
            #expect(row.deck < row.card)
            #expect(row.card < 1)
            // Readability floor for text drawn straight on the deck.
            #expect(row.deck >= 0.72)
        }
        for isDark in [true, false] {
            let decks = Preference.FrostLevel.allCases.map {
                Preference.deckOpacity(for: $0, isDark: isDark)
            }
            let cards = Preference.FrostLevel.allCases.map {
                Preference.cardOpacity(for: $0, isDark: isDark)
            }
            #expect(decks == decks.sorted(by: >))
            #expect(cards == cards.sorted(by: >))
        }
        for level in Preference.FrostLevel.allCases {
            #expect(
                Preference.deckOpacity(for: level, isDark: false)
                    > Preference.deckOpacity(for: level, isDark: true))
        }
    }

    @Test("A fill over a translucent base takes only the alpha it still needs")
    func layeredOpacity() {
        // Card 0.94 over a 0.82 board: (0.94 - 0.82) / (1 - 0.82).
        let alpha = Preference.layeredOpacity(target: 0.94, over: 0.82)
        #expect(abs(alpha - 0.12 / 0.18) < 1e-9)
        // Source-over check: the pair reaches the target.
        #expect(abs(alpha + 0.82 * (1 - alpha) - 0.94) < 1e-9)
        #expect(Preference.layeredOpacity(target: 0.82, over: 0.82) == 0)
        #expect(Preference.layeredOpacity(target: 0.5, over: 0.82) == 0)
        #expect(Preference.layeredOpacity(target: 0.9, over: 1) == 1)
        #expect(Preference.layeredOpacity(target: 1, over: 0) == 1)
    }

    @Test("Each deck layer paints the alpha that lands it on its target", arguments: [true, false])
    func layerPaintOpacities(frostsContent: Bool) {
        let surface = Self.resolve(
            "frosted", "balanced", isDark: true, frostsContent: frostsContent)
        #expect(surface.paintOpacity(for: .deck) == 0.82)
        #expect(surface.paintOpacity(for: .frostedBase) == 0.82)
        #expect(surface.paintOpacity(for: .underlay) == 0)
        #expect(surface.paintOpacity(for: .content) == (frostsContent ? 0.82 : 1))
        // A card over the board composites to the card opacity.
        let card = surface.paintOpacity(for: .card)
        #expect(abs(card + 0.82 * (1 - card) - 0.94) < 1e-9)
        // Editor-like content in a card shows the card when frosted.
        #expect(surface.paintOpacity(for: .cardContent) == (frostsContent ? 0 : 1))
        // A pinned header over content: at least the card opacity in total,
        // and opaque over opaque content.
        let pinned = surface.paintOpacity(for: .pinned)
        let content = surface.contentOpacity
        #expect(pinned + content * (1 - pinned) >= 0.94 - 1e-9)
        if !frostsContent { #expect(pinned == 1) }
    }

    @MainActor
    @Test("Fills change only in Frosted; Solid returns the colour itself")
    func fillHelper() {
        let color = Color.red
        #expect(WindowSurfacePreference.Resolved.solid.fill(color, .deck) == color)
        #expect(WindowSurfacePreference.Resolved.solid.fill(color, .card) == color)
        #expect(
            WindowSurfacePreference.Resolved.solid.fill(color, .frostedBase) == color.opacity(0))
        let frosted = Self.resolve("frosted", "balanced", isDark: true)
        #expect(frosted.fill(color, .deck) == color.opacity(0.82))
        #expect(frosted.fill(color, .underlay) == color.opacity(0))
    }

    // MARK: Terminal

    @Test("The terminal background alpha follows the content opacity, never 0")
    func terminalAlpha() {
        for row in Self.table {
            let on = Self.resolve("frosted", row.level, isDark: row.isDark)
            let off = Self.resolve(
                "frosted", row.level, isDark: row.isDark, frostsContent: false)
            #expect(Preference.terminalBackgroundAlpha(on) == row.deck)
            #expect(Preference.terminalBackgroundAlpha(off) == 1)
            // SwiftTerm draws inverse-video text in this colour.
            #expect(Preference.terminalBackgroundAlpha(on) >= 0.72)
        }
    }

    @MainActor
    @Test("The terminal background keeps the theme RGB and takes the alpha")
    func terminalBackgroundColor() throws {
        let base = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        #expect(WorkspaceTerminalController.terminalBackground(base, alpha: 1) === base)
        #expect(WorkspaceTerminalController.terminalBackground(base, alpha: 7) === base)
        let frosted = try #require(
            WorkspaceTerminalController.terminalBackground(base, alpha: 0.82)
                .usingColorSpace(.sRGB))
        #expect(abs(frosted.alphaComponent - 0.82) < 1e-6)
        #expect(abs(frosted.redComponent - 0.1) < 1e-6)
        #expect(abs(frosted.blueComponent - 0.3) < 1e-6)
        let clamped = WorkspaceTerminalController.terminalBackground(base, alpha: -1)
        #expect(clamped.alphaComponent == 0)
    }

    @MainActor
    @Test("The frosted margin strip covers the rows SwiftTerm leaves unpainted")
    func terminalMarginFrame() {
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 305)
        #expect(
            TerminalMarginFillView.frame(bounds: bounds, gridHeight: 300)
                == NSRect(x: 0, y: 0, width: 400, height: 5))
        #expect(TerminalMarginFillView.frame(bounds: bounds, gridHeight: 320).height == 0)
        let view = TerminalMarginFillView()
        #expect(view.hitTest(.zero) == nil)
        #expect(!view.isAccessibilityElement())
    }

    // MARK: Editor

    @MainActor
    @Test("The editor's translucent base lives on the scroll view only")
    func editorColorSet() throws {
        let theme = RafuThemeCatalog.indigo
        let opaque = EditorColorSet(theme: theme)
        #expect(!opaque.isTranslucent)
        #expect(opaque.backgroundAlpha == 1)
        #expect(opaque.textBackground.alphaComponent == 1)
        #expect(opaque.scrollBackground.alphaComponent == 1)

        let frosted = EditorColorSet(theme: theme, backgroundAlpha: 0.82)
        #expect(frosted.isTranslucent)
        #expect(frosted != opaque)
        #expect(frosted == EditorColorSet(theme: theme, backgroundAlpha: 0.82))
        // The text view stays clear so the two never stack.
        #expect(frosted.textBackground.alphaComponent == 0)
        #expect(abs(frosted.scrollBackground.alphaComponent - 0.82) < 1e-6)
        #expect(EditorColorSet(theme: theme, backgroundAlpha: 3).backgroundAlpha == 1)
    }

    @MainActor
    @Test("The gutter base follows the editor base; its strips keep their colour")
    func gutterStyle() {
        let theme = RafuThemeCatalog.indigo
        let opaque = EditorGutterStyle(theme: theme)
        let frosted = EditorGutterStyle(theme: theme, backgroundAlpha: 0.82)
        #expect(opaque.backgroundColor.alphaComponent == 1)
        #expect(abs(frosted.backgroundColor.alphaComponent - 0.82) < 1e-6)
        #expect(frosted.addedColor == opaque.addedColor)
        #expect(frosted.modifiedColor == opaque.modifiedColor)
        #expect(frosted.deletedColor == opaque.deletedColor)
        #expect(frosted.foregroundColor == opaque.foregroundColor)
    }
}
