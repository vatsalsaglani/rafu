import Observation
import RafuCore
import SwiftUI

// The voice orb: a "kanche", a translucent tinted glass marble with a
// cat's-eye leaf of coloured glass inside, window reflections, a caustic,
// small bubbles, and a face of two dots (voice-presence.md). The look lives
// only in this file; the faces and the motion are pure rules in RafuCore
// (`VoiceOrbFace`, `VoiceOrbExpression`, `VoiceOrbMotion`).

/// The orb's colours, built from the active theme: Indigo, Khadi, every
/// bundled theme and user themes. The default marble is clear aqua glass
/// whose cat's-eye takes the theme's accent, warning or success, and info.
struct VoiceOrbPalette {
    /// The glass tint.
    let tint: Color
    /// Tint strength at the clear centre and at the rim: glass is thin in
    /// the middle and thick at the edge.
    let centreAlpha: Double
    let rimAlpha: Double
    /// Reduce Transparency: an opaque colour below the glass.
    let solidBase: Color?
    /// The cat's-eye's three bands.
    let leaf: [Color]
    /// The dot eyes, the brows and the lid lines.
    let ink: Color
    /// A soft spot behind each dot so it reads on the leaf.
    let halo: Color
    let outline: Color
    let outlineWidth: CGFloat
    let badgeFill: Color
    let badgeGlyph: Color
    let badgeBorder: Color
    let isDark: Bool

    /// Sea-glass aqua, the marble's own colour before the theme pulls it.
    static let seaGlass = Color(.sRGB, red: 0.498, green: 0.847, blue: 0.800)

    init(theme: RafuTheme, increaseContrast: Bool = false, reduceTransparency: Bool = false) {
        let palette = theme.palette
        let dark = theme.isDark
        isDark = dark
        let lift = dark ? 0.0 : 0.15
        tint = Self.seaGlass.mix(with: palette.info, by: 0.25)
        centreAlpha = dark ? 0.16 : 0.20
        rimAlpha = dark ? 0.50 : 0.55
        leaf = [
            palette.accent.mix(with: .white, by: lift + 0.1),
            (dark ? palette.warning : palette.success).mix(with: .white, by: lift),
            palette.info.mix(with: .white, by: lift),
        ]
        solidBase = reduceTransparency ? palette.cardBackground.mix(with: tint, by: 0.25) : nil
        ink = dark ? Color(.sRGB, red: 0.965, green: 0.973, blue: 0.988) : palette.textPrimary
        halo = dark ? palette.appBackground.mix(with: .black, by: 0.3) : .white
        outline =
            increaseContrast
            ? palette.borderStrong : tint.mix(with: palette.textPrimary, by: 0.35).opacity(0.55)
        outlineWidth = increaseContrast ? 2 : 1
        badgeFill = palette.cardBackground
        badgeGlyph = palette.textPrimary
        badgeBorder = increaseContrast ? palette.borderStrong : palette.borderStrong.opacity(0.45)
    }
}

/// What one frame draws: the motion's numbers, the blink, and the face.
struct VoiceOrbFrame: Equatable {
    var drawn = VoiceOrbMotion.Drawn()
    /// 0 open … 1 closed (the blink only).
    var blink = 0.0
    var face = VoiceOrbFace.off
}

/// Drives one orb. A 30 Hz sleeping loop runs only while the face uses the
/// clock (connecting, listening, thinking, speaking) or a pose change is
/// still easing; otherwise nothing runs and the orb is one still frame. No
/// always-on timeline view (motion-gate-and-idle-cpu.md). The host runs `run` from a
/// `.task(id:)` whose id holds the face and the motion gate, so an occluded
/// window, a locked screen or Reduce Motion cancels it.
@MainActor
@Observable
final class VoiceOrbAnimator {
    static let tick: Duration = .milliseconds(33)
    static let tolerance: Duration = .milliseconds(8)

    private(set) var frame = VoiceOrbFrame()
    @ObservationIgnored private var motion = VoiceOrbMotion()
    /// -1…1 from the orb's centre while the pointer is over it.
    @ObservationIgnored private var pointer: (x: Double, y: Double)?

    /// Runs while `face` is current. `levels` reads the session's mic and
    /// output levels on each tick, so the host view does not redraw for them.
    func run(face: VoiceOrbFace, animated: Bool, levels: @escaping () -> (Double, Double)) async {
        guard animated else {
            motion.rest(face: face)
            write(drawn: motion.drawn, face: face)
            return
        }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: Self.tick, tolerance: Self.tolerance)
            } catch {
                return
            }
            let (mic, output) = levels()
            if motion.step(face: face, mic: mic, output: output, pointer: pointer)
                || frame.face != motion.shown(face)
            {
                write(drawn: motion.drawn, face: motion.shown(face))
            }
            if motion.isSettled(face: face) { return }
        }
    }

    /// One blink each 3 to 6 s: one sleep, then five short frames.
    func runBlinks(enabled: Bool) async {
        guard enabled else {
            setBlink(0)
            return
        }
        while !Task.isCancelled {
            do {
                try await Task.sleep(
                    for: .seconds(Double.random(in: 3...6)), tolerance: .milliseconds(300))
            } catch {
                setBlink(0)
                return
            }
            for closed in [0.6, 1.0, 1.0, 0.5, 0.0] {
                setBlink(closed)
                do {
                    try await Task.sleep(for: Self.tick, tolerance: Self.tolerance)
                } catch {
                    setBlink(0)
                    return
                }
            }
        }
    }

    /// The pointer over the orb. The listening loop eases the dots to it.
    func look(at point: (x: Double, y: Double)?) {
        pointer = point
    }

    private func setBlink(_ value: Double) {
        guard frame.blink != value else { return }
        var next = frame
        next.blink = value
        commit(next)
    }

    private func write(drawn: VoiceOrbMotion.Drawn, face: VoiceOrbFace) {
        var next = frame
        next.drawn = drawn
        next.face = face
        commit(next)
    }

    private func commit(_ next: VoiceOrbFrame) {
        guard next != frame else { return }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { frame = next }
    }
}

/// The orb drawn from pure inputs. One `Canvas`, no blur filter, no
/// animation of its own.
struct VoiceOrbView: View {
    let frame: VoiceOrbFrame
    let palette: VoiceOrbPalette
    var size: CGFloat = 64
    /// The notch orb is too small for a face or a badge.
    var showsFace = true
    var showsBadge = true

    var body: some View {
        let frame = frame
        let palette = palette
        let showsFace = showsFace
        Canvas { context, canvasSize in
            VoiceOrbRenderer(frame: frame, palette: palette, showsFace: showsFace)
                .draw(in: &context, size: canvasSize)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            VoiceOrbBadge(
                symbol: showsBadge ? frame.face.badgeSymbol : nil, palette: palette, size: size)
        }
        .accessibilityHidden(true)
    }
}

/// The badge: a glyph on a solid chip. Only Paused, Needs confirmation and
/// Error have one; with the face it is the signal that does not use colour.
private struct VoiceOrbBadge: View {
    let symbol: String?
    let palette: VoiceOrbPalette
    let size: CGFloat

    var body: some View {
        let side = max(14, size * 0.34)
        ZStack {
            if let symbol {
                Circle().fill(palette.badgeFill)
                Circle().strokeBorder(palette.badgeBorder, lineWidth: 1)
                Image(systemName: symbol)
                    .font(.system(size: side * 0.5, weight: .bold))
                    .foregroundStyle(palette.badgeGlyph)
            }
        }
        .frame(width: side, height: side)
    }
}

/// Draws one frame. The light comes from the upper left and does not move;
/// the marble rocks a little under it, so the leaf drifts and turns its edge
/// while the reflections stay. That is what makes it read as glass.
struct VoiceOrbRenderer {
    let frame: VoiceOrbFrame
    let palette: VoiceOrbPalette
    var showsFace = true

    private var e: VoiceOrbExpression { frame.drawn.expression }
    private var level: Double { frame.drawn.level }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let side = min(size.width, size.height)
        let radius = side * 0.41 * e.scale
        let bounce = frame.face == .speaking ? -level * side * 0.02 : 0
        let centre = CGPoint(x: size.width / 2, y: size.height / 2 - side * 0.04 + bounce)
        let bodyRect = CGRect(
            x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
        let body = Path(ellipseIn: bodyRect)
        let tint = faded(palette.tint, e.grey)

        drawGround(in: &context, centre: centre, radius: radius, tint: tint)
        drawRipple(in: &context, centre: centre, radius: radius, side: side)
        if let solid = palette.solidBase { context.fill(body, with: .color(solid)) }
        context.fill(
            body,
            with: .radialGradient(
                Gradient(stops: [
                    .init(
                        color: tint.mix(with: .white, by: 0.55).opacity(palette.centreAlpha),
                        location: 0),
                    .init(
                        color: tint.opacity((palette.centreAlpha + palette.rimAlpha) / 2),
                        location: 0.72),
                    .init(
                        color: tint.mix(with: .black, by: palette.isDark ? 0.1 : 0.22)
                            .opacity(palette.rimAlpha), location: 1),
                ]),
                center: CGPoint(x: centre.x + radius * 0.18, y: centre.y + radius * 0.2),
                startRadius: 0, endRadius: radius * 1.18))

        var inside = context
        inside.clip(to: body)
        drawLeaves(in: &inside, centre: centre, radius: radius)
        drawCaustic(in: &inside, centre: centre, radius: radius, tint: tint)
        drawBubbles(in: &inside, centre: centre, radius: radius)
        if showsFace { drawEyes(in: &context, centre: centre, radius: radius) }
        drawReflections(in: &inside, centre: centre, radius: radius)

        let inset = palette.outlineWidth / 2
        context.stroke(
            Path(ellipseIn: bodyRect.insetBy(dx: inset, dy: inset)),
            with: .color(palette.outline), lineWidth: palette.outlineWidth)
    }

    // MARK: Ground

    /// A soft tinted shadow with the bright spot the marble focuses.
    private func drawGround(
        in context: inout GraphicsContext, centre: CGPoint, radius: CGFloat, tint: Color
    ) {
        var ground = context
        ground.translateBy(x: centre.x + radius * 0.06, y: centre.y + radius * 1.03)
        ground.scaleBy(x: 1, y: 0.2)
        let shadow = tint.mix(with: .black, by: 0.75)
        let reach = radius * 0.9
        ground.fill(
            Path(ellipseIn: CGRect(x: -reach, y: -reach, width: reach * 2, height: reach * 2)),
            with: .radialGradient(
                Gradient(colors: [shadow.opacity(palette.isDark ? 0.55 : 0.28), shadow.opacity(0)]),
                center: .zero, startRadius: 0, endRadius: reach))
        if palette.isDark { ground.blendMode = .plusLighter }
        let pool = tint.mix(with: .white, by: palette.isDark ? 0.35 : 0.75)
        let poolReach = radius * 0.5
        let at = CGPoint(x: radius * 0.22, y: 0)
        ground.fill(
            Path(
                ellipseIn: CGRect(
                    x: at.x - poolReach, y: at.y - poolReach, width: poolReach * 2,
                    height: poolReach * 2)),
            with: .radialGradient(
                Gradient(colors: [
                    pool.opacity((palette.isDark ? 0.5 : 0.9) * e.glow), pool.opacity(0),
                ]),
                center: at, startRadius: 0, endRadius: poolReach))
    }

    private func drawRipple(
        in context: inout GraphicsContext, centre: CGPoint, radius: CGFloat, side: CGFloat
    ) {
        let ripple = frame.drawn.ripple
        guard ripple > 0 else { return }
        let spread = radius + (side / 2 - radius) * ripple
        context.stroke(
            Path(
                ellipseIn: CGRect(
                    x: centre.x - spread, y: centre.y - spread, width: spread * 2,
                    height: spread * 2)),
            with: .color(palette.tint.opacity(0.8 * (1 - ripple))), lineWidth: 1.5)
    }

    // MARK: Cat's-eye

    /// One leaf: a thin sheet of coloured glass along an S-shaped spine,
    /// pointed at both ends, with a twist. Where the sheet turns its back it
    /// is narrower and paler.
    private struct Leaf {
        /// Spine control points in units of the radius, origin at the centre.
        var p0: CGPoint, c1: CGPoint, c2: CGPoint, p1: CGPoint
        var width: Double
        /// Band edges across the sheet, -1…1, uneven on purpose.
        var edges: [Double]
        var twist: Double
        var roll: Double
        var colours: [Int]
        var alpha: Double
    }

    private func drawLeaves(in context: inout GraphicsContext, centre: CGPoint, radius: CGFloat) {
        let phase = frame.drawn.phase
        let swell = 1 + level * e.levelSwell
        // A slow rock, never a full turn.
        let rock = 0.20 * sin(phase * 0.7)
        let back = Leaf(
            p0: CGPoint(x: -0.70, y: 0.16), c1: CGPoint(x: -0.34, y: 0.60),
            c2: CGPoint(x: -0.10, y: 0.24), p1: CGPoint(x: 0.22, y: 0.80),
            width: 0.13 * swell, edges: [-1, 0.1, 1], twist: 1.5,
            roll: 0.9 + 0.5 * cos(phase * 0.8), colours: [2, 1], alpha: 0.42)
        // It rises from the lower left to the right side, off-centre, so the
        // eyes sit on clear glass and the leaf does not read as a mouth.
        let front = Leaf(
            p0: CGPoint(x: -0.46, y: 0.70), c1: CGPoint(x: 0.42, y: 0.84),
            c2: CGPoint(x: -0.06, y: 0.12), p1: CGPoint(x: 0.78, y: -0.06),
            width: 0.22 * swell, edges: [-1, -0.30, 0.28, 1], twist: 2.3,
            roll: 0.35 + 0.55 * sin(phase), colours: [0, 1, 2], alpha: 0.92)
        draw(back, rock: -rock * 0.6, in: &context, centre: centre, radius: radius)
        draw(front, rock: rock, in: &context, centre: centre, radius: radius)
    }

    private func draw(
        _ leaf: Leaf, rock: Double, in context: inout GraphicsContext, centre: CGPoint,
        radius: CGFloat
    ) {
        let samples = 24
        let cosR = cos(rock)
        let sinR = sin(rock)
        func place(_ p: CGPoint) -> CGPoint {
            CGPoint(
                x: centre.x + (p.x * cosR - p.y * sinR) * radius,
                y: centre.y + (p.x * sinR + p.y * cosR) * radius)
        }
        let p0 = place(leaf.p0)
        let c1 = place(leaf.c1)
        let c2 = place(leaf.c2)
        let p1 = place(leaf.p1)
        var spine: [CGPoint] = []
        var normal: [CGVector] = []
        var half: [Double] = []
        var facing: [Double] = []
        spine.reserveCapacity(samples + 1)
        for index in 0...samples {
            let t = Double(index) / Double(samples)
            let u = 1 - t
            let a = u * u * u
            let b = 3 * u * u * t
            let c = 3 * u * t * t
            let d = t * t * t
            let x = a * p0.x + b * c1.x + c * c2.x + d * p1.x
            let y = a * p0.y + b * c1.y + c * c2.y + d * p1.y
            let dx =
                3 * u * u * (c1.x - p0.x) + 6 * u * t * (c2.x - c1.x) + 3 * t * t * (p1.x - c2.x)
            let dy =
                3 * u * u * (c1.y - p0.y) + 6 * u * t * (c2.y - c1.y) + 3 * t * t * (p1.y - c2.y)
            let length = max(0.0001, (dx * dx + dy * dy).squareRoot())
            spine.append(CGPoint(x: x, y: y))
            normal.append(CGVector(dx: -dy / length, dy: dx / length))
            // Pointed ends, widest a little past the middle.
            let profile = pow(sin(.pi * pow(t, 0.85)), 0.8)
            let turn = cos(leaf.roll + leaf.twist * (t - 0.5))
            facing.append(turn)
            // The sheet has some thickness, so it never vanishes mid-way.
            let seen = turn >= 0 ? max(turn, 0.16) : min(turn, -0.16)
            half.append(leaf.width * Double(radius) * profile * seen)
        }
        func edge(_ fraction: Double) -> [CGPoint] {
            (0...samples).map { index in
                CGPoint(
                    x: spine[index].x + normal[index].dx * half[index] * fraction,
                    y: spine[index].y + normal[index].dy * half[index] * fraction)
            }
        }
        for band in 0..<(leaf.edges.count - 1) {
            var path = Path()
            path.addLines(edge(leaf.edges[band]))
            path.addLines(edge(leaf.edges[band + 1]).reversed())
            path.closeSubpath()
            let colour = faded(palette.leaf[leaf.colours[band] % palette.leaf.count], e.grey)
            var stops: [Gradient.Stop] = []
            for step in 0...6 {
                let front = facing[step * samples / 6] >= 0
                let strength = leaf.alpha * (0.45 + 0.55 * e.glow) * (front ? 1 : 0.5)
                let shade = front ? colour : colour.mix(with: palette.tint, by: 0.35)
                stops.append(.init(color: shade.opacity(strength), location: Double(step) / 6))
            }
            context.fill(
                path, with: .linearGradient(Gradient(stops: stops), startPoint: p0, endPoint: p1))
        }
        var rim = Path()
        rim.addLines(edge(leaf.edges[0]))
        context.stroke(
            rim, with: .color(.white.opacity(0.28 * leaf.alpha)),
            style: StrokeStyle(
                lineWidth: max(0.6, radius * 0.018), lineCap: .round, lineJoin: .round))
    }

    // MARK: Light

    /// Light that went through the glass gathers at the lower right; the rim
    /// opposite the light is bright, and a thin line marks the lit rim.
    private func drawCaustic(
        in context: inout GraphicsContext, centre: CGPoint, radius: CGFloat, tint: Color
    ) {
        var layer = context
        if palette.isDark { layer.blendMode = .plusLighter }
        let light = tint.mix(with: .white, by: 0.7)
        let at = CGPoint(x: centre.x + radius * 0.40, y: centre.y + radius * 0.50)
        let reach = radius * (0.60 + 0.15 * level)
        layer.fill(
            Path(
                ellipseIn: CGRect(
                    x: at.x - reach, y: at.y - reach, width: reach * 2, height: reach * 2)
            ),
            with: .radialGradient(
                Gradient(stops: [
                    .init(
                        color: light.opacity((palette.isDark ? 0.42 : 0.75) * e.glow), location: 0),
                    .init(color: light.opacity(0.10 * e.glow), location: 0.6),
                    .init(color: light.opacity(0), location: 1),
                ]),
                center: at, startRadius: 0, endRadius: reach))
        var arc = Path()
        arc.addArc(
            center: centre, radius: radius * 0.88, startAngle: .degrees(12),
            endAngle: .degrees(84), clockwise: false)
        layer.stroke(
            arc, with: .color(.white.opacity((palette.isDark ? 0.5 : 0.85) * (0.5 + 0.5 * e.glow))),
            style: StrokeStyle(lineWidth: radius * 0.055, lineCap: .round))
        var top = Path()
        top.addArc(
            center: centre, radius: radius * 0.955, startAngle: .degrees(196),
            endAngle: .degrees(262), clockwise: false)
        context.stroke(
            top, with: .color(.white.opacity(palette.isDark ? 0.45 : 0.8)),
            style: StrokeStyle(lineWidth: max(0.8, radius * 0.025), lineCap: .round))
    }

    /// Small air bubbles: a ring and a light point. They do not move.
    private func drawBubbles(in context: inout GraphicsContext, centre: CGPoint, radius: CGFloat) {
        let bubbles: [(x: Double, y: Double, r: Double)] = [
            (0.50, -0.30, 0.040), (0.60, -0.06, 0.024), (-0.56, 0.42, 0.030),
        ]
        for bubble in bubbles {
            let r = max(0.8, radius * bubble.r)
            let at = CGPoint(x: centre.x + radius * bubble.x, y: centre.y + radius * bubble.y)
            let ring = Path(
                ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: r * 2, height: r * 2))
            context.fill(ring, with: .color(.white.opacity(0.14)))
            context.stroke(
                ring, with: .color(.white.opacity(0.55)), lineWidth: max(0.5, radius * 0.012))
            let dot = r * 0.35
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: at.x - r * 0.4 - dot, y: at.y - r * 0.4 - dot, width: dot * 2,
                        height: dot * 2)),
                with: .color(.white.opacity(0.9)))
        }
    }

    /// Two sharp window panes at the upper left and a faint one at the lower
    /// right (the same window, seen through the glass).
    private func drawReflections(
        in context: inout GraphicsContext, centre: CGPoint, radius: CGFloat
    ) {
        var panes = context
        panes.translateBy(x: centre.x - radius * 0.50, y: centre.y - radius * 0.52)
        panes.rotate(by: .degrees(-32))
        let width = radius * 0.15
        let height = radius * 0.21
        let gap = radius * 0.035
        for (index, x) in [-(width + gap / 2), gap / 2].enumerated() {
            let paneHeight = index == 0 ? height * 0.82 : height
            panes.fill(
                Path(
                    roundedRect: CGRect(x: x, y: -paneHeight / 2, width: width, height: paneHeight),
                    cornerRadius: width * 0.28, style: .continuous),
                with: .color(.white.opacity(index == 0 ? 0.78 : 0.95)))
        }
        var echo = context
        echo.translateBy(x: centre.x + radius * 0.50, y: centre.y + radius * 0.34)
        echo.rotate(by: .degrees(-32))
        echo.fill(
            Path(
                roundedRect: CGRect(
                    x: -radius * 0.05, y: -radius * 0.09, width: radius * 0.10,
                    height: radius * 0.18),
                cornerRadius: radius * 0.03, style: .continuous),
            with: .color(.white.opacity(0.28)))
    }

    // MARK: Face

    /// Two dots, no eye whites, no pupils. The dot's size, a flat lid that
    /// cuts its top, a squash for the blink, and where the pair sits carry
    /// the expression.
    private func drawEyes(in context: inout GraphicsContext, centre: CGPoint, radius: CGFloat) {
        var face = context
        face.translateBy(x: centre.x, y: centre.y)
        face.rotate(by: .radians(e.tilt))
        let confirm = frame.face == .needsConfirm
        // Needs confirmation glances up at the card.
        let glance =
            confirm
            ? CGVector(dx: -0.4, dy: -0.9) : CGVector(dx: frame.drawn.lookX, dy: frame.drawn.lookY)
        let gazeX = max(-1, min(1, e.gazeX + glance.dx * 0.8))
        let gazeY = max(-1, min(1, e.gazeY + glance.dy * (confirm ? 0.4 : 0.8)))
        let shift = CGVector(dx: gazeX * radius * 0.085, dy: gazeY * radius * 0.075)
        let dot = radius * 0.105 * e.dot * (1 + (frame.face == .hearing ? level * 0.18 : 0))
        let line = StrokeStyle(lineWidth: max(1.4, radius * 0.075), lineCap: .round)
        let browLine = StrokeStyle(lineWidth: max(1.2, radius * 0.06), lineCap: .round)
        let blink = frame.blink

        for sideSign in [-1.0, 1.0] {
            let eye = CGPoint(x: sideSign * radius * 0.27 + shift.dx, y: -radius * 0.20 + shift.dy)
            let haloReach = dot * 2.6
            face.fill(
                Path(
                    ellipseIn: CGRect(
                        x: eye.x - haloReach, y: eye.y - haloReach, width: haloReach * 2,
                        height: haloReach * 2)),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: palette.halo.opacity(0.42), location: 0),
                        .init(color: palette.halo.opacity(0.22), location: 0.5),
                        .init(color: palette.halo.opacity(0), location: 1),
                    ]),
                    center: eye, startRadius: 0, endRadius: haloReach))

            if e.happy > 0.5 {
                var arc = Path()
                arc.move(to: CGPoint(x: eye.x - dot * 1.25, y: eye.y + dot * 0.45))
                arc.addQuadCurve(
                    to: CGPoint(x: eye.x + dot * 1.25, y: eye.y + dot * 0.45),
                    control: CGPoint(x: eye.x, y: eye.y - dot * 1.5))
                face.stroke(arc, with: .color(palette.ink), style: line)
            } else if e.lids < 0.1 {
                var arc = Path()
                arc.move(to: CGPoint(x: eye.x - dot * 1.2, y: eye.y))
                arc.addQuadCurve(
                    to: CGPoint(x: eye.x + dot * 1.2, y: eye.y),
                    control: CGPoint(x: eye.x, y: eye.y + dot * 1.1))
                face.stroke(arc, with: .color(palette.ink), style: line)
            } else if blink > 0.85 {
                var flat = Path()
                flat.move(to: CGPoint(x: eye.x - dot * 1.05, y: eye.y))
                flat.addLine(to: CGPoint(x: eye.x + dot * 1.05, y: eye.y))
                face.stroke(flat, with: .color(palette.ink), style: line)
            } else {
                let rx = dot * (1 + blink * 0.12)
                let ry = dot * (confirm ? 1.12 : 1) * (1 - blink * 0.8)
                let shape = Path(
                    ellipseIn: CGRect(x: eye.x - rx, y: eye.y - ry, width: rx * 2, height: ry * 2))
                if e.lids < 0.95 {
                    let lidY = eye.y - ry + (1 - e.lids) * ry * 1.5
                    var below = face
                    below.clip(
                        to: Path(CGRect(x: eye.x - rx * 2, y: lidY, width: rx * 4, height: ry * 3)))
                    below.fill(shape, with: .color(palette.ink))
                    var lid = Path()
                    lid.move(to: CGPoint(x: eye.x - rx * 1.1, y: lidY))
                    lid.addLine(to: CGPoint(x: eye.x + rx * 1.1, y: lidY))
                    face.stroke(lid, with: .color(palette.ink), style: browLine)
                } else {
                    face.fill(shape, with: .color(palette.ink))
                }
            }

            guard e.brows > 0.05 else { continue }
            let skew = sideSign < 0 ? e.browSkew : 0
            let browY = eye.y - dot - radius * (0.11 + 0.08 * (e.browRaise + skew * 0.6))
            let halfLength = radius * 0.12
            let rise = radius * 0.075 * e.browTilt
            var brow = Path()
            brow.move(to: CGPoint(x: eye.x - sideSign * halfLength, y: browY - rise))
            brow.addQuadCurve(
                to: CGPoint(x: eye.x + sideSign * halfLength, y: browY + rise),
                control: CGPoint(x: eye.x, y: browY - radius * 0.03))
            face.stroke(brow, with: .color(palette.ink.opacity(0.92 * e.brows)), style: browLine)
        }
    }

    /// Off, Paused and Error take colour out of the glass and the leaf.
    private func faded(_ colour: Color, _ amount: Double) -> Color {
        amount <= 0
            ? colour : colour.mix(with: Color(white: palette.isDark ? 0.5 : 0.72), by: amount * 0.8)
    }
}

/// An orb wired to the session: the face from the session state, the
/// palette from the theme, its own animator, and the Done face for a moment
/// after each completed task. Used by the companion and the notch.
struct VoiceLiveOrb: View {
    let session: VoiceSession
    var size: CGFloat = 64
    /// The notch orb is too small for a face and a badge.
    var isCompact = false
    @Environment(\.rafuTheme) private var theme
    @Environment(\.rafuMotionAllowed) private var motionAllowed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var animator = VoiceOrbAnimator()
    @State private var doneSerial = 0
    @State private var showsDone = false

    private var face: VoiceOrbFace {
        VoiceOrbFace.face(for: session.blobState).withDone(showsDone)
    }

    private var animated: Bool { motionAllowed && !reduceMotion }

    var body: some View {
        let face = face
        let animated = animated
        VoiceOrbView(
            frame: animator.frame,
            palette: VoiceOrbPalette(
                theme: theme, increaseContrast: contrast == .increased,
                reduceTransparency: reduceTransparency),
            size: size, showsFace: !isCompact, showsBadge: !isCompact
        )
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard animated, !isCompact else { return }
            switch phase {
            case .active(let point):
                animator.look(at: Self.unit(point, size: size))
            case .ended:
                animator.look(at: nil)
            }
        }
        .onChange(of: session.completedTasks) { old, new in
            if new > old { doneSerial &+= 1 }
        }
        .task(id: doneSerial) {
            // One sleep for each completed task; nothing loops.
            guard doneSerial > 0 else { return }
            showsDone = true
            do {
                try await Task.sleep(for: VoiceOrbFace.doneHold)
            } catch {
                return
            }
            showsDone = false
        }
        .task(id: RunKey(face: face, animated: animated)) {
            let session = session
            await animator.run(face: face, animated: animated) { () -> (Double, Double) in
                (Double(session.inputLevel), Double(session.outputLevel))
            }
        }
        .task(id: RunKey(face: face.blinks ? .listening : .off, animated: animated)) {
            await animator.runBlinks(enabled: animated && face.blinks && !isCompact)
        }
    }

    private struct RunKey: Equatable {
        let face: VoiceOrbFace
        let animated: Bool
    }

    /// The pointer as -1…1 from the orb's centre.
    private static func unit(_ point: CGPoint, size: CGFloat) -> (x: Double, y: Double) {
        let half = Double(size) / 2
        let x: Double = (Double(point.x) - half) / half
        let y: Double = (Double(point.y) - half) / half
        return (x: max(-1, min(1, x)), y: max(-1, min(1, y)))
    }
}
