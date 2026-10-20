import AppKit
import SwiftUI
import Testing

@testable import RafuApp

@Suite("Commit graph lane palette")
struct CommitGraphPaletteTests {
    private func circularDistance(_ lhs: Double, _ rhs: Double) -> Double {
        let difference = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }

    @Test("Eight lanes get eight distinct hues, none near the accent")
    func eightDistinctHuesAwayFromAccent() {
        for accentHue in [0.0, 35, 120, 215, 359] {
            let hues = CommitGraphPalette.laneHues(accentHueDegrees: accentHue)
            #expect(hues.count == CommitGraphPalette.laneCount)
            for (index, hue) in hues.enumerated() {
                #expect(
                    circularDistance(hue, accentHue)
                        >= CommitGraphPalette.accentExclusionDegrees - 0.001)
                for other in hues[(index + 1)...] {
                    #expect(circularDistance(hue, other) > 30)
                }
            }
            // Neighbouring lanes are far apart on the hue circle.
            for (lane, next) in zip(hues, hues.dropFirst()) {
                #expect(circularDistance(lane, next) > 90)
            }
        }
    }

    @MainActor
    @Test("Every bundled theme derives lane colors that avoid its accent (Indigo gold)")
    func themeLaneColorsAvoidAccent() {
        for theme in [
            RafuThemeCatalog.indigo, RafuThemeCatalog.khadi, RafuThemeCatalog.dracula,
            RafuThemeCatalog.githubLight, RafuThemeCatalog.githubDark,
        ] {
            let lanes = CommitGraphPalette.lanes(
                accent: NSColor(theme.palette.accent), reference: NSColor(theme.palette.gitModified)
            )
            #expect(lanes.count == 8)
            let accentHue = CommitGraphPalette.hsb(of: NSColor(theme.palette.accent)).hue * 360
            let laneHues = lanes.map { CommitGraphPalette.hsb(of: $0).hue * 360 }
            #expect(Set(laneHues.map { Int($0.rounded()) }).count == 8, "\(theme.name)")
            #expect(laneHues.allSatisfy { circularDistance($0, accentHue) >= 29 }, "\(theme.name)")
            #expect(CommitGraphPalette.lanes(from: theme.palette).count == 8)
        }
    }
}
