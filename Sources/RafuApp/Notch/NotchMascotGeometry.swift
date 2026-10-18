import SwiftUI

/// The thread sprite's shapes in the 512-point design space shared with
/// `Resources/Mascot/rafu-*.svg`. Keep the numbers here and in the SVGs in
/// step: the SVGs are the design source, these are the native rendering.
///
/// `nonisolated` so the constants are plain `Sendable` values that any
/// shape or drawing code can read.
nonisolated enum RafuMascotGeometry {
    static let designSize: CGFloat = 512

    /// A point in the design space as a unit point of the 512-point frame.
    static func unit(_ x: CGFloat, _ y: CGFloat) -> UnitPoint {
        UnitPoint(x: x / designSize, y: y / designSize)
    }

    // MARK: Body

    /// The soft, round body. Its outline is stroked as one gold thread.
    static let silhouette: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 256, y: 150))
        path.addCurve(
            to: CGPoint(x: 430, y: 304), control1: CGPoint(x: 352, y: 150),
            control2: CGPoint(x: 426, y: 216))
        path.addCurve(
            to: CGPoint(x: 256, y: 440), control1: CGPoint(x: 434, y: 390),
            control2: CGPoint(x: 360, y: 440))
        path.addCurve(
            to: CGPoint(x: 82, y: 304), control1: CGPoint(x: 152, y: 440),
            control2: CGPoint(x: 78, y: 390))
        path.addCurve(
            to: CGPoint(x: 256, y: 150), control1: CGPoint(x: 86, y: 216),
            control2: CGPoint(x: 160, y: 150))
        path.closeSubpath()
        return path
    }()

    /// The body gradient runs from the lit top left to the shaded bottom right.
    static let bodyGradientStart = unit(150, 160)
    static let bodyGradientEnd = unit(360, 448)

    /// Soft light on the upper left of the body.
    static let lightCenter = unit(190, 214)
    static let lightRadius: CGFloat = 240

    /// The stitched seam just inside the rim: the outline scaled to 90 %.
    static let stitchScale: CGFloat = 0.9
    static let stitch: Path = silhouette.applying(
        CGAffineTransform(translationX: 256, y: 300)
            .scaledBy(x: stitchScale, y: stitchScale)
            .translatedBy(x: -256, y: -300))

    static let feet: [Path] = [
        Path(ellipseIn: CGRect(x: 180, y: 425, width: 56, height: 34)),
        Path(ellipseIn: CGRect(x: 276, y: 425, width: 56, height: 34)),
    ]
    static let feetGradientStart = unit(256, 420)
    static let feetGradientEnd = unit(256, 466)

    /// The glossy highlight and its small companion dot.
    static let specular: Path = Path(ellipseIn: CGRect(x: 136, y: 186, width: 92, height: 44))
        .applying(
            CGAffineTransform(translationX: 182, y: 208)
                .rotated(by: -30 * .pi / 180)
                .translatedBy(x: -182, y: -208))
    static let specularDot = Path(ellipseIn: CGRect(x: 224, y: 172, width: 16, height: 16))

    static let blush: [Path] = [
        Path(ellipseIn: CGRect(x: 118, y: 341, width: 52, height: 30)),
        Path(ellipseIn: CGRect(x: 342, y: 341, width: 52, height: 30)),
    ]

    // MARK: Antenna

    /// One thin thread from inside the body up to a small loop, like the eye
    /// of a needle, with a short loose end.
    static let antenna: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 262, y: 172))
        path.addCurve(
            to: CGPoint(x: 276, y: 96), control1: CGPoint(x: 258, y: 140),
            control2: CGPoint(x: 262, y: 112))
        path.addCurve(
            to: CGPoint(x: 312, y: 48), control1: CGPoint(x: 292, y: 78),
            control2: CGPoint(x: 314, y: 70))
        path.addCurve(
            to: CGPoint(x: 272, y: 36), control1: CGPoint(x: 310, y: 28),
            control2: CGPoint(x: 284, y: 22))
        path.addCurve(
            to: CGPoint(x: 284, y: 78), control1: CGPoint(x: 262, y: 48),
            control2: CGPoint(x: 268, y: 68))
        path.addCurve(
            to: CGPoint(x: 308, y: 86), control1: CGPoint(x: 292, y: 83),
            control2: CGPoint(x: 300, y: 86))
        return path
    }()
    static let antennaLineWidth: CGFloat = 9

    /// The antenna sways and bobs around where it leaves the body.
    static let antennaPivot = unit(262, 152)
    /// The working pose leans the antenna; the bob swings from here.
    static let workingLean: Double = -6

    static let loopCenter = CGPoint(x: 291, y: 52)
    static let loopAnchor = unit(291, 52)
    /// The bead that fills the loop when an agent needs you.
    static let loopBead = Path(ellipseIn: CGRect(x: 279, y: 40, width: 24, height: 24))

    /// The short thread trail that circles the loop while agents work.
    static let trailRadius: CGFloat = 46
    static let trail = arc(fromDegrees: -125, toDegrees: -35)
    static let trailTail = arc(fromDegrees: -162, toDegrees: -136)
    static let trailBead = Path(
        ellipseIn: CGRect(
            x: arcPoint(degrees: -35).x - 7, y: arcPoint(degrees: -35).y - 7, width: 14,
            height: 14))

    nonisolated struct Sparkle: Sendable {
        let center: CGPoint
        let path: Path
    }

    /// The reply-ready sparkles beside the loop.
    static let sparkles: [Sparkle] = [
        sparkle(centerX: 342, centerY: 44, radius: 24),
        sparkle(centerX: 232, centerY: 50, radius: 12),
    ]

    // MARK: Face

    static let leftEyeX: CGFloat = 194
    static let rightEyeX: CGFloat = 318

    /// The size and place of an open eye for a mood.
    nonisolated struct EyePose: Equatable, Sendable {
        let centerY: CGFloat
        let width: CGFloat
        let height: CGFloat
        /// Working eyes look down and a little to the right, at the work.
        let shiftX: CGFloat
    }

    static func eyePose(for mood: RafuMascotMood) -> EyePose {
        switch mood {
        case .working: EyePose(centerY: 310, width: 56, height: 62, shiftX: 6)
        case .needsYou: EyePose(centerY: 296, width: 64, height: 82, shiftX: 0)
        case .idle, .replyReady: EyePose(centerY: 302, width: 58, height: 74, shiftX: 0)
        }
    }

    /// A closed, smiling eye (the reply-ready face, `^ ^`).
    static func happyEye(centerX x: CGFloat) -> Path {
        curve(
            from: CGPoint(x: x - 25, y: 312), c1: CGPoint(x: x - 21, y: 280),
            c2: CGPoint(x: x + 21, y: 280), to: CGPoint(x: x + 25, y: 312))
    }

    /// The mouths stroke or fill with an ink gradient over this span.
    static let inkGradientStart = unit(256, 270)
    static let inkGradientEnd = unit(256, 390)

    static let smile = curve(
        from: CGPoint(x: 240, y: 356), c1: CGPoint(x: 248, y: 369), c2: CGPoint(x: 264, y: 369),
        to: CGPoint(x: 272, y: 356))

    static let focusMouth = curve(
        from: CGPoint(x: 247, y: 362), c1: CGPoint(x: 253, y: 366), c2: CGPoint(x: 261, y: 366),
        to: CGPoint(x: 267, y: 362))

    static let gaspMouth = Path(ellipseIn: CGRect(x: 245, y: 351, width: 22, height: 26))

    static let openSmile: Path = {
        var path = curve(
            from: CGPoint(x: 234, y: 350), c1: CGPoint(x: 238, y: 388),
            c2: CGPoint(x: 274, y: 388), to: CGPoint(x: 278, y: 350))
        path.closeSubpath()
        return path
    }()

    // MARK: Helpers

    private static func curve(from start: CGPoint, c1: CGPoint, c2: CGPoint, to end: CGPoint)
        -> Path
    {
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: c1, control2: c2)
        return path
    }

    /// A point on the trail circle. Angles grow clockwise on screen, as in
    /// the SVG (y points down).
    static func arcPoint(degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(
            x: loopCenter.x + trailRadius * CGFloat(cos(radians)),
            y: loopCenter.y + trailRadius * CGFloat(sin(radians)))
    }

    private static func arc(fromDegrees start: Double, toDegrees end: Double) -> Path {
        var path = Path()
        path.addRelativeArc(
            center: loopCenter, radius: trailRadius, startAngle: .degrees(start),
            delta: .degrees(end - start))
        return path
    }

    /// A four-point star with softly pinched sides.
    private static func sparkle(centerX x: CGFloat, centerY y: CGFloat, radius r: CGFloat)
        -> Sparkle
    {
        let w = r * 0.28
        let n = w * 0.4
        var path = Path()
        path.move(to: CGPoint(x: x, y: y - r))
        path.addCurve(
            to: CGPoint(x: x + r, y: y), control1: CGPoint(x: x + n, y: y - w),
            control2: CGPoint(x: x + w, y: y - n))
        path.addCurve(
            to: CGPoint(x: x, y: y + r), control1: CGPoint(x: x + w, y: y + n),
            control2: CGPoint(x: x + n, y: y + w))
        path.addCurve(
            to: CGPoint(x: x - r, y: y), control1: CGPoint(x: x - n, y: y + w),
            control2: CGPoint(x: x - w, y: y + n))
        path.addCurve(
            to: CGPoint(x: x, y: y - r), control1: CGPoint(x: x - w, y: y - n),
            control2: CGPoint(x: x - n, y: y - w))
        path.closeSubpath()
        return Sparkle(center: CGPoint(x: x, y: y), path: path)
    }
}
