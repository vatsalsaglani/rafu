import SwiftUI

/// Colours for the thread sprite, resolved from the active theme. The body is
/// a gradient of the theme accent (the gold thread in Indigo and Khadi). The
/// notch is always black, and light themes use darker accents made for paper,
/// so a light theme's accent is lifted toward white first. Only the eyes and
/// the mouth use fixed colours: near-black ink with white catch-lights.
struct RafuMascotColors {
    let bodyLight: Color
    let body: Color
    let bodyShade: Color
    /// The thread rim and the stitched seam.
    let rim: Color
    /// The antenna, its loop, and the working trail.
    let thread: Color
    let blush: Color
    /// The Increase Contrast outline. It is the light end of the theme, so it
    /// reads on the black notch.
    let outline: Color

    static let eyeTop = Color(red: 0x3B / 255.0, green: 0x31 / 255.0, blue: 0x41 / 255.0)
    static let inkMid = Color(red: 0x1B / 255.0, green: 0x15 / 255.0, blue: 0x1F / 255.0)
    static let inkBottom = Color(red: 0x0C / 255.0, green: 0x09 / 255.0, blue: 0x0F / 255.0)

    init(theme: RafuTheme) {
        let palette = theme.palette
        let base = theme.isDark ? palette.accent : palette.accent.mix(with: .white, by: 0.18)
        bodyLight = base.mix(with: .white, by: 0.5)
        body = base
        bodyShade = base.mix(with: .black, by: 0.3)
        rim = base.mix(with: .white, by: 0.5)
        thread = base.mix(with: .white, by: 0.2)
        blush = base.mix(with: palette.error, by: 0.55)
        outline = theme.isDark ? palette.textPrimary : palette.editorBackground
    }
}

/// The Rafu mascot, a small thread sprite: a round, soft body whose outline
/// is one gold thread, a thin antenna that ends in a thread loop like the eye
/// of a needle, big dark glossy eyes, a small smile and two tiny feet. The
/// artwork is drawn in the 512-point coordinate space of the SVG design assets
/// in `Resources/Mascot/` (`rafu-*.svg`), so a change to one belongs in the
/// other.
///
/// Parts move independently so the animated view can blink, glance, sway the
/// antenna, spin the trail and pulse the loop without redrawing the body.
struct RafuMascotArtwork: View {
    let mood: RafuMascotMood
    let colors: RafuMascotColors
    var size: CGFloat = 22
    /// Increase Contrast: a solid outline replaces the soft thread rim.
    var outlined = false
    var blink: CGFloat = 1
    var gaze: CGSize = .zero
    /// Antenna rotation in degrees, added to the mood's pose.
    var sway: Double = 0
    /// Rotation of the working trail around the loop, in degrees.
    var spin: Double = 0
    /// Scale of the needs-you bead in the loop.
    var pulse: CGFloat = 1
    /// Scale of the reply-ready sparkles.
    var twinkle: CGFloat = 1

    private typealias Geometry = RafuMascotGeometry

    var body: some View {
        ZStack(alignment: .topLeading) {
            antenna
            feet
            softBody
            face
        }
        .frame(width: Geometry.designSize, height: Geometry.designSize)
        .scaleEffect(size / Geometry.designSize)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: Antenna

    private var antennaPose: Double { mood == .working ? Geometry.workingLean : 0 }

    private var antenna: some View {
        ZStack(alignment: .topLeading) {
            Geometry.antenna
                .stroke(
                    colors.thread,
                    style: StrokeStyle(
                        lineWidth: outlined ? 11 : Geometry.antennaLineWidth, lineCap: .round,
                        lineJoin: .round))
            if mood == .needsYou {
                Geometry.loopBead
                    .fill(colors.thread)
                    .scaleEffect(pulse, anchor: Geometry.loopAnchor)
            }
            if mood == .working {
                trail
                    .rotationEffect(.degrees(spin), anchor: Geometry.loopAnchor)
            }
            if mood == .replyReady {
                ForEach(Geometry.sparkles.indices, id: \.self) { index in
                    let sparkle = Geometry.sparkles[index]
                    let anchor = Geometry.unit(sparkle.center.x, sparkle.center.y)
                    sparkle.path
                        .fill(colors.rim)
                        .scaleEffect(twinkle, anchor: anchor)
                        .rotationEffect(.degrees(Double(twinkle - 1) * 57), anchor: anchor)
                }
            }
        }
        .frame(width: Geometry.designSize, height: Geometry.designSize)
        .rotationEffect(.degrees(antennaPose + sway), anchor: Geometry.antennaPivot)
    }

    /// A short thread trail with a fading tail and a bead at its leading end.
    private var trail: some View {
        ZStack(alignment: .topLeading) {
            Geometry.trail
                .stroke(
                    colors.thread.opacity(0.8), style: StrokeStyle(lineWidth: 7, lineCap: .round))
            Geometry.trailTail
                .stroke(
                    colors.thread.opacity(0.4), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            Geometry.trailBead.fill(colors.thread)
        }
        .frame(width: Geometry.designSize, height: Geometry.designSize)
    }

    // MARK: Body

    private var feet: some View {
        let gradient = LinearGradient(
            colors: [colors.body, colors.bodyShade], startPoint: Geometry.feetGradientStart,
            endPoint: Geometry.feetGradientEnd)
        return ZStack(alignment: .topLeading) {
            ForEach(Geometry.feet.indices, id: \.self) { index in
                Geometry.feet[index].fill(gradient)
            }
        }
        .frame(width: Geometry.designSize, height: Geometry.designSize)
    }

    private var softBody: some View {
        ZStack(alignment: .topLeading) {
            Geometry.silhouette
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: colors.bodyLight, location: 0),
                            .init(color: colors.body, location: 0.4),
                            .init(color: colors.body, location: 0.7),
                            .init(color: colors.bodyShade, location: 1),
                        ], startPoint: Geometry.bodyGradientStart,
                        endPoint: Geometry.bodyGradientEnd))
            Geometry.silhouette
                .fill(
                    RadialGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.42), location: 0),
                            .init(color: Color.white.opacity(0.06), location: 0.5),
                            .init(color: Color.white.opacity(0), location: 1),
                        ], center: Geometry.lightCenter, startRadius: 0,
                        endRadius: Geometry.lightRadius))
            Geometry.stitch
                .stroke(
                    colors.rim.opacity(0.3),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [12.6, 12.6])
                )
                .clipShape(Geometry.silhouette)
            Geometry.silhouette
                .stroke(
                    outlined ? colors.outline : colors.rim.opacity(0.9),
                    lineWidth: outlined ? 12 : 8)
            Geometry.specular.fill(Color.white.opacity(0.42))
            Geometry.specularDot.fill(Color.white.opacity(0.4))
            ForEach(Geometry.blush.indices, id: \.self) { index in
                Geometry.blush[index].fill(colors.blush.opacity(0.5))
            }
        }
        .frame(width: Geometry.designSize, height: Geometry.designSize)
    }

    // MARK: Face

    private var ink: LinearGradient {
        LinearGradient(
            colors: [RafuMascotColors.inkMid, RafuMascotColors.inkBottom],
            startPoint: Geometry.inkGradientStart, endPoint: Geometry.inkGradientEnd)
    }

    @ViewBuilder
    private var face: some View {
        if mood == .replyReady {
            ForEach([Geometry.leftEyeX, Geometry.rightEyeX], id: \.self) { x in
                Geometry.happyEye(centerX: x)
                    .stroke(ink, style: StrokeStyle(lineWidth: 14, lineCap: .round))
            }
        } else {
            let pose = Geometry.eyePose(for: mood)
            ForEach([Geometry.leftEyeX, Geometry.rightEyeX], id: \.self) { x in
                eye(pose)
                    .position(x: x + pose.shiftX + gaze.width, y: pose.centerY + gaze.height)
            }
        }
        mouth
    }

    /// A big, dark, glossy eye with a white catch-light and a softer second one.
    private func eye(_ pose: Geometry.EyePose) -> some View {
        let width = pose.width
        let height = pose.height
        return ZStack(alignment: .topLeading) {
            Ellipse()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: RafuMascotColors.eyeTop, location: 0),
                            .init(color: RafuMascotColors.inkMid, location: 0.6),
                            .init(color: RafuMascotColors.inkBottom, location: 1),
                        ], startPoint: .topLeading, endPoint: UnitPoint(x: 0.35, y: 1)))
            Circle()
                .fill(Color.white)
                .frame(width: width * 0.36, height: width * 0.36)
                .position(x: width * 0.67, y: height * 0.3)
            Circle()
                .fill(Color.white.opacity(0.6))
                .frame(width: width * 0.15, height: width * 0.15)
                .position(x: width * 0.32, y: height * 0.71)
        }
        .frame(width: width, height: height)
        // Wide needs-you eyes stay open; the other moods blink.
        .scaleEffect(x: 1, y: mood == .needsYou ? 1 : blink)
    }

    @ViewBuilder
    private var mouth: some View {
        switch mood {
        case .idle:
            Geometry.smile.stroke(ink, style: StrokeStyle(lineWidth: 9, lineCap: .round))
        case .working:
            Geometry.focusMouth.stroke(ink, style: StrokeStyle(lineWidth: 9, lineCap: .round))
        case .needsYou:
            Geometry.gaspMouth.fill(ink)
        case .replyReady:
            Geometry.openSmile.fill(ink)
            Geometry.openSmile.stroke(ink, style: StrokeStyle(lineWidth: 4, lineJoin: .round))
        }
    }
}

/// The animated mascot. Motion runs only while `visible` and never under
/// Reduce Motion; either way the still pose of the mood is shown, which
/// matches `rafu-*-still.svg`. Motion is a chain of explicit animations in one
/// task, so no timer runs and hiding the notch or changing mood cancels it.
struct RafuMascotView: View {
    let state: RafuMascotState
    let visible: Bool
    var size: CGFloat = 22
    let claimBounce: (UUID) -> Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.rafuTheme) private var theme
    @State private var motion = RafuMascotMotion()

    private var animates: Bool { visible && !reduceMotion }

    var body: some View {
        let breathing = animates && motion.breathing
        RafuMascotArtwork(
            mood: state.mood, colors: RafuMascotColors(theme: theme), size: size,
            outlined: contrast == .increased,
            blink: animates ? motion.blink : 1, gaze: animates ? motion.gaze : .zero,
            sway: animates ? motion.sway : 0, spin: animates ? motion.spin : 0,
            pulse: animates ? motion.pulse : 1, twinkle: animates ? motion.twinkle : 1
        )
        .scaleEffect(x: breathing ? 1.015 : 1, y: breathing ? 0.985 : 1, anchor: .bottom)
        .offset(y: animates ? motion.lift * size / RafuMascotGeometry.designSize : 0)
        .help("Rafu · " + state.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rafu")
        .accessibilityValue(state.label)
        .task(id: MascotMotionKey(mood: state.mood, reply: state.replyID, enabled: animates)) {
            await animate()
        }
    }

    private func reset() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { motion = RafuMascotMotion() }
    }

    private func animate() async {
        reset()
        guard animates else { return }
        do {
            switch state.mood {
            case .idle: try await rest()
            case .working: try await work()
            case .needsYou: try await callForAttention()
            case .replyReady: try await celebrate()
            }
        } catch {
            // Cancelled by a mood change, hiding, or Reduce Motion.
        }
    }

    /// Slow breathing and a gentle antenna sway, with a blink every other
    /// breath and a glance now and then.
    private func rest() async throws {
        var beat = 0
        while !Task.isCancelled {
            let inhale = beat.isMultiple(of: 2)
            withAnimation(.easeInOut(duration: 2.5)) {
                motion.breathing = inhale
                motion.sway = inhale ? 5 : -5
            }
            try await Task.sleep(for: .milliseconds(2500))
            beat += 1
            switch beat % 6 {
            case 2: glance(CGSize(width: 9, height: -2))
            case 5: glance(CGSize(width: -8, height: 1))
            case 0, 3: glance(.zero)
            default: break
            }
            if !beat.isMultiple(of: 2) { try await blinkOnce() }
        }
    }

    /// Focused eyes (the pose), an antenna that bobs, and a thread trail that
    /// circles the loop.
    private func work() async throws {
        var beat = 0
        while !Task.isCancelled {
            if motion.spin >= 3600 {
                // A whole number of turns looks the same; keep the value small.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { motion.spin = 0 }
            }
            withAnimation(.linear(duration: 1.4)) { motion.spin += 360 }
            withAnimation(.easeInOut(duration: 0.7)) { motion.sway = 12 }
            try await Task.sleep(for: .milliseconds(700))
            withAnimation(.easeInOut(duration: 0.7)) { motion.sway = 0 }
            beat += 1
            if beat.isMultiple(of: 3) {
                try await blinkOnce()
                try await Task.sleep(for: .milliseconds(600))
            } else {
                try await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    /// A small hop and a pulse of the loop bead, then stillness. Wide eyes
    /// and the filled loop carry the state between hops.
    private func callForAttention() async throws {
        while !Task.isCancelled {
            withAnimation(.easeOut(duration: 0.16)) {
                motion.lift = -16
                motion.pulse = 1.3
            }
            try await Task.sleep(for: .milliseconds(160))
            withAnimation(.spring(duration: 0.34, bounce: 0.3)) { motion.lift = 0 }
            withAnimation(.easeInOut(duration: 0.5)) { motion.pulse = 1 }
            try await Task.sleep(for: .milliseconds(2600))
        }
    }

    /// One bounce per reply, then the sparkle twinkles now and then while the
    /// happy face waits.
    private func celebrate() async throws {
        if let replyID = state.replyID, claimBounce(replyID) {
            withAnimation(.easeOut(duration: 0.16)) {
                motion.lift = -14
                motion.twinkle = 1.35
            }
            try await Task.sleep(for: .milliseconds(160))
            withAnimation(.spring(duration: 0.32, bounce: 0.25)) { motion.lift = 0 }
            withAnimation(.easeInOut(duration: 0.4)) { motion.twinkle = 1 }
        }
        while !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(3600))
            withAnimation(.easeInOut(duration: 0.3)) { motion.twinkle = 1.3 }
            try await Task.sleep(for: .milliseconds(300))
            withAnimation(.easeInOut(duration: 0.4)) { motion.twinkle = 1 }
        }
    }

    private func glance(_ offset: CGSize) {
        withAnimation(.easeInOut(duration: 0.4)) { motion.gaze = offset }
    }

    private func blinkOnce() async throws {
        withAnimation(.linear(duration: 0.08)) { motion.blink = 0.09 }
        try await Task.sleep(for: .milliseconds(100))
        withAnimation(.easeOut(duration: 0.14)) { motion.blink = 1 }
    }
}

/// The moving parts of the mascot. At rest every value is the still pose.
private struct RafuMascotMotion {
    var blink: CGFloat = 1
    var gaze: CGSize = .zero
    var lift: CGFloat = 0
    var sway: Double = 0
    var spin: Double = 0
    var pulse: CGFloat = 1
    var twinkle: CGFloat = 1
    var breathing = false
}

private struct MascotMotionKey: Equatable {
    let mood: RafuMascotMood
    let reply: UUID?
    let enabled: Bool
}

/// Three rising bars shown beside the mascot while music plays. Mounted only
/// during playback; its timeline stops under Reduce Motion or when hidden.
struct NotchPlaybackIndicator: View {
    let motionActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rafuTheme) private var theme

    private var animating: Bool { motionActive && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !animating)) { context in
            Canvas { drawing, size in
                let time = animating ? context.date.timeIntervalSinceReferenceDate : 0
                for bar in 0..<3 {
                    let phase = Double(bar) * 1.7
                    let height = 3.0 + (sin(time * 7 + phase) + 1) * 3.5
                    let rect = CGRect(
                        x: Double(bar) * 3.5, y: (size.height - height) / 2, width: 2,
                        height: height)
                    drawing.fill(
                        Path(roundedRect: rect, cornerRadius: 1), with: .color(theme.palette.accent)
                    )
                }
            }
        }
        .frame(width: 10, height: 12)
        .accessibilityLabel("Music playing")
    }
}
