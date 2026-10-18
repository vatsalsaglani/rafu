import SwiftUI

/// The mascot's shapes in the 512-point design space shared with
/// `Resources/Mascot/rafu-*.svg`. Keep the numbers here and in the SVGs in
/// step: the SVGs are the design source, these are the native rendering.
enum RafuMascotGeometry {
    static let ballCenter = CGPoint(x: 256, y: 300)
    static let ballWidth: CGFloat = 352
    static let ballHeight: CGFloat = 320

    static let leftEyeX: Double = 187
    static let rightEyeX: Double = 325

    /// Where the needle enters the ball; the sway pivots here.
    static let needleAnchor = UnitPoint(x: 300.0 / 512.0, y: 150.0 / 512.0)
    static let needleEye = CGPoint(x: 349, y: 52)

    static let needle: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 300, y: 150))
        path.addLine(to: CGPoint(x: 352, y: 46))
        return path
    }()

    /// The thread through the needle's eye. It runs down the side of the ball
    /// and joins the first strand, so the strands read as the same thread
    /// wound around the ball. A short loose end hangs the other way.
    static let thread: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 349, y: 52))
        path.addCurve(
            to: CGPoint(x: 430, y: 256),
            control1: CGPoint(x: 438, y: 44),
            control2: CGPoint(x: 478, y: 168))
        path.move(to: CGPoint(x: 349, y: 52))
        path.addCurve(
            to: CGPoint(x: 312, y: 60),
            control1: CGPoint(x: 336, y: 40),
            control2: CGPoint(x: 318, y: 44))
        return path
    }()

    struct Strand {
        let path: Path
        let opacity: Double
    }

    /// Yarn wrapped around the ball. Clipped to the ball's outline when drawn.
    static let strands: [Strand] = [
        Strand(
            path: curve(from: (70, 270), c1: (150, 330), c2: (330, 330), to: (442, 262)),
            opacity: 0.55),
        Strand(
            path: curve(from: (70, 360), c1: (160, 410), c2: (340, 410), to: (442, 350)),
            opacity: 0.55),
        Strand(
            path: curve(from: (150, 150), c1: (215, 215), c2: (230, 330), to: (206, 470)),
            opacity: 0.35),
    ]

    /// A closed, smiling eye (the reply-ready face).
    static func happyEye(centerX: Double) -> Path {
        curve(
            from: (centerX - 21, 300), c1: (centerX - 18, 258), c2: (centerX + 18, 258),
            to: (centerX + 21, 300))
    }

    static let smile = curve(from: (232, 350), c1: (244, 368), c2: (268, 368), to: (280, 350))

    static let flatMouth: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 238, y: 356))
        path.addLine(to: CGPoint(x: 274, y: 356))
        return path
    }()

    static let openSmile: Path = {
        var path = curve(from: (226, 346), c1: (236, 388), c2: (276, 388), to: (286, 346))
        path.closeSubpath()
        return path
    }()

    private static func curve(
        from start: (Double, Double), c1: (Double, Double), c2: (Double, Double),
        to end: (Double, Double)
    ) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: start.0, y: start.1))
        path.addCurve(
            to: CGPoint(x: end.0, y: end.1),
            control1: CGPoint(x: c1.0, y: c1.1),
            control2: CGPoint(x: c2.0, y: c2.1))
        return path
    }
}
