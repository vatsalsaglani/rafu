import AppKit
import SwiftUI

/// Lane colors for the commit graph (ADR 0013 GD3 amendment). The eight
/// lanes are derived from the theme accent by hue rotation, so they change
/// with every theme and adjacent lanes stay distinguishable. Saturation and
/// brightness follow the theme's `gitModified` token, clamped, so the lanes
/// sit at the same visual weight as the other Git colors on light and dark
/// themes. Hues within `accentExclusionDegrees` of the accent are never
/// used: the accent (gold in Indigo and Khadi) is reserved for focus,
/// selection, and the HEAD marker.
nonisolated enum CommitGraphPalette {
    static let laneCount = 8
    /// Half-width of the hue arc around the accent that no lane uses.
    static let accentExclusionDegrees: Double = 30

    /// Order in which lanes take the eight evenly spaced hue slots. Each
    /// step jumps about 130 degrees, so two neighbouring lanes never get
    /// neighbouring hues. Lane 0 (usually the main line) takes the slot
    /// opposite the accent.
    private static let slotOrder = [4, 1, 6, 3, 0, 5, 2, 7]

    static func lanes(from palette: RafuThemePalette) -> [Color] {
        lanes(accent: NSColor(palette.accent), reference: NSColor(palette.gitModified))
            .map { Color(nsColor: $0) }
    }

    /// The hues, in degrees, that `lanes(accent:reference:)` assigns, in
    /// lane order. Exposed for tests.
    static func laneHues(accentHueDegrees: Double) -> [Double] {
        let arc = 360 - 2 * accentExclusionDegrees
        let step = arc / Double(laneCount - 1)
        return slotOrder.map { slot in
            let offset = accentExclusionDegrees + Double(slot) * step
            return (accentHueDegrees + offset).truncatingRemainder(dividingBy: 360)
        }
    }

    static func lanes(accent: NSColor, reference: NSColor) -> [NSColor] {
        let accentHSB = hsb(of: accent)
        let referenceHSB = hsb(of: reference)
        let saturation = min(max(referenceHSB.saturation, 0.45), 0.80)
        let brightness = min(max(referenceHSB.brightness, 0.55), 0.92)
        return laneHues(accentHueDegrees: accentHSB.hue * 360).map { hue in
            NSColor(
                colorSpace: .sRGB,
                hue: hue / 360,
                saturation: saturation,
                brightness: brightness,
                alpha: 1
            )
        }
    }

    static func hsb(of color: NSColor) -> (hue: Double, saturation: Double, brightness: Double) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return (0, 0.6, 0.8) }
        return (
            Double(srgb.hueComponent), Double(srgb.saturationComponent),
            Double(srgb.brightnessComponent)
        )
    }
}
