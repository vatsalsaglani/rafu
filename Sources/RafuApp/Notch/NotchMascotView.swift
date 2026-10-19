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

/// The animated mascot. Motion runs only while `\.rafuMotionAllowed` (the
/// window is visible, the screen is unlocked and awake) and never under
/// Reduce Motion; otherwise the still pose of the mood is shown, which
/// matches `rafu-*-still.svg`. Motion runs in one task, so no timer runs and
/// hiding the notch or changing mood cancels it.
///
/// The idle mood is the resting state of the strip, so it is cheap: the
/// still pose with a discrete blink or glance every few seconds. It breathes
/// only while the person engages with the strip (`engaged`), and the breath
/// is 15 plain state writes a second, not an animation: an animation in
/// flight re-renders the whole panel on every display frame (120 Hz on
/// ProMotion). The working mood's spin and antenna bob are plain writes at
/// 20 a second for the same reason. Only short blinks, glances and hops are
/// animations.
struct RafuMascotView: View {
    let state: RafuMascotState
    /// The strip is hovered, expanded or pinned, or the mascot is in an open
    /// panel. Changes only the idle mood.
    var engaged = false
    var size: CGFloat = 22
    let claimBounce: (UUID) -> Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rafuMotionAllowed) private var motionAllowed
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.rafuTheme) private var theme
    @State private var motion = RafuMascotMotion()

    private var animates: Bool { motionAllowed && !reduceMotion }

    private var idleMotion: RafuMascotIdleMotion? {
        state.mood == .idle ? RafuMascotIdleMotion.resolve(engaged: engaged) : nil
    }

    var body: some View {
        let breath = RafuMascotIdleMotion.breathPose(phase: animates ? motion.breathPhase : 0)
        RafuMascotArtwork(
            mood: state.mood, colors: RafuMascotColors(theme: theme), size: size,
            outlined: contrast == .increased,
            blink: animates ? motion.blink : 1, gaze: animates ? motion.gaze : .zero,
            sway: animates ? motion.sway + breath.sway : 0, spin: animates ? motion.spin : 0,
            pulse: animates ? motion.pulse : 1, twinkle: animates ? motion.twinkle : 1
        )
        .scaleEffect(
            x: 1 + 0.015 * breath.inhale, y: 1 - 0.015 * breath.inhale, anchor: .bottom
        )
        .offset(y: animates ? motion.lift * size / RafuMascotGeometry.designSize : 0)
        .help("Rafu · " + state.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rafu")
        .accessibilityValue(state.label)
        .task(
            id: MascotMotionKey(
                mood: state.mood, reply: state.replyID, idle: idleMotion, enabled: animates)
        ) {
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

    /// Engaged: slow breathing and a gentle antenna sway, with a blink every
    /// five seconds and a glance now and then. The breath is a plain state
    /// write every `breathFrameInterval`; blinks and glances are short
    /// animations. At rest: the still pose, with `stillCycle`'s beats.
    private func rest() async throws {
        guard idleMotion == .breathing else {
            try await restStill()
            return
        }
        let clock = ContinuousClock()
        let start = clock.now
        var beat = 0
        var reopenAt: ContinuousClock.Instant?
        var still = Transaction()
        still.disablesAnimations = true
        while !Task.isCancelled {
            try await Task.sleep(
                for: .seconds(RafuMascotIdleMotion.breathFrameInterval),
                tolerance: .milliseconds(10))
            let now = clock.now
            let elapsed = (now - start) / .seconds(1)
            withTransaction(still) {
                motion.breathPhase = RafuMascotIdleMotion.breathPhase(elapsed: elapsed)
            }
            if let reopen = reopenAt, now >= reopen {
                withAnimation(.easeOut(duration: 0.14)) { motion.blink = 1 }
                reopenAt = nil
            }
            let due = Int(elapsed / RafuMascotIdleMotion.engagedBeatSeconds)
            guard due > beat else { continue }
            beat = due
            switch beat % 6 {
            case 2: glance(CGSize(width: 9, height: -2))
            case 5: glance(CGSize(width: -8, height: 1))
            case 0, 3: glance(.zero)
            default: break
            }
            if !beat.isMultiple(of: 2) {
                withAnimation(.linear(duration: 0.08)) { motion.blink = 0.09 }
                reopenAt = now + .milliseconds(100)
            }
        }
    }

    /// Nothing animates between beats, so the panel renders only while a
    /// blink or glance runs.
    private func restStill() async throws {
        while !Task.isCancelled {
            for beat in RafuMascotIdleMotion.stillCycle {
                try await Task.sleep(for: beat.pause, tolerance: .milliseconds(250))
                switch beat.action {
                case .blink: try await blinkOnce()
                case .glance(let offset): glance(offset)
                }
            }
        }
    }

    /// Focused eyes (the pose), an antenna that bobs, and a thread trail that
    /// circles the loop. The spin and the bob are plain state writes every
    /// `RafuMascotWorkingMotion.frameInterval`; the blink every third bob is
    /// a short animation.
    private func work() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        var beat = 0
        var reopenAt: ContinuousClock.Instant?
        var still = Transaction()
        still.disablesAnimations = true
        while !Task.isCancelled {
            try await Task.sleep(
                for: .seconds(RafuMascotWorkingMotion.frameInterval),
                tolerance: .milliseconds(10))
            let now = clock.now
            let elapsed = (now - start) / .seconds(1)
            let pose = RafuMascotWorkingMotion.pose(elapsed: elapsed)
            withTransaction(still) {
                motion.spin = pose.spin
                motion.sway = pose.sway
            }
            if let reopen = reopenAt, now >= reopen {
                withAnimation(.easeOut(duration: 0.14)) { motion.blink = 1 }
                reopenAt = nil
            }
            let due = RafuMascotWorkingMotion.beat(elapsed: elapsed)
            guard due > beat else { continue }
            beat = due
            if RafuMascotWorkingMotion.blinks(onBeat: beat) {
                withAnimation(.linear(duration: 0.08)) { motion.blink = 0.09 }
                reopenAt = now + .milliseconds(100)
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
    /// Engaged idle breathing, in radians; 0 is the still pose.
    var breathPhase: Double = 0
}

private struct MascotMotionKey: Equatable {
    let mood: RafuMascotMood
    let reply: UUID?
    /// `nil` for every mood but idle, so engagement never restarts them.
    let idle: RafuMascotIdleMotion?
    let enabled: Bool
}

/// What the idle mood does. Pure, so the schedule is testable.
nonisolated enum RafuMascotIdleMotion: Equatable, Sendable {
    /// Slow breathing and antenna sway at 15 fps, only while the person
    /// engages with the strip.
    case breathing
    /// The still pose with a discrete blink or glance every few seconds.
    /// Nothing animates between beats.
    case still

    enum Action: Equatable, Sendable {
        case blink
        /// Eye offset in the 512-point design space; `.zero` looks back.
        case glance(CGSize)
    }

    struct Beat: Equatable, Sendable {
        /// The still time before the action.
        let pause: Duration
        let action: Action
    }

    /// The longest action in `stillCycle`, in seconds (a glance).
    static let longestActionSeconds = 0.4

    /// One cycle of the still schedule; it repeats. About 21 s with six
    /// short actions, so the mascot animates under a tenth of the time.
    static let stillCycle: [Beat] = [
        Beat(pause: .seconds(5), action: .blink),
        Beat(pause: .milliseconds(4500), action: .glance(CGSize(width: 9, height: -2))),
        Beat(pause: .milliseconds(1400), action: .glance(.zero)),
        Beat(pause: .milliseconds(5500), action: .blink),
        Beat(pause: .seconds(4), action: .glance(CGSize(width: -8, height: 1))),
        Beat(pause: .milliseconds(1400), action: .glance(.zero)),
    ]

    static func resolve(engaged: Bool) -> RafuMascotIdleMotion {
        engaged ? .breathing : .still
    }

    /// One full breath, in seconds: in for half, out for half.
    static let breathPeriod: TimeInterval = 5

    /// Time between engaged blinks and glances, in seconds.
    static let engagedBeatSeconds: Double = 2.5

    /// The breathing frame interval: 15 fps is smooth for a 1.5 % scale and
    /// a 5 degree sway, and an eighth of a 120 Hz display's frames.
    static let breathFrameInterval: TimeInterval = 1.0 / 15

    /// The breath phase, in radians, `elapsed` seconds after breathing began.
    static func breathPhase(elapsed: Double) -> Double {
        elapsed * 2 * .pi / breathPeriod
    }

    /// The pose for a breath phase: `inhale` from 0 (the still pose) to 1,
    /// and an antenna sway from -5 to 5 degrees. Phase 0 is the still pose,
    /// so breathing starts without a jump.
    static func breathPose(phase: Double) -> (inhale: CGFloat, sway: Double) {
        (CGFloat((1 - cos(phase)) / 2), 5 * sin(phase))
    }
}

/// The working mood's moving parts. Pure, so the schedule is testable.
nonisolated enum RafuMascotWorkingMotion {
    /// The frame interval: 20 writes a second turn the trail about 13
    /// degrees a step, and that is a sixth of a 120 Hz display's frames.
    static let frameInterval: TimeInterval = 1.0 / 20

    /// One turn of the thread trail, in seconds.
    static let spinPeriod: TimeInterval = 1.4

    /// One bob of the antenna (out and back), in seconds.
    static let bobPeriod: TimeInterval = 1.4

    /// The largest antenna sway, in degrees.
    static let swayAmplitude: Double = 12

    /// The pose `elapsed` seconds into the working mood: the spin in degrees
    /// (0 up to, not including, 360) and an eased sway from 0 to
    /// `swayAmplitude` and back. Time 0 is the still pose.
    static func pose(elapsed: Double) -> (spin: Double, sway: Double) {
        let turns = elapsed / spinPeriod
        let spin = (turns - turns.rounded(.down)) * 360
        let sway = swayAmplitude * (1 - cos(elapsed * 2 * .pi / bobPeriod)) / 2
        return (spin, sway)
    }

    /// The number of whole bobs `elapsed` seconds in.
    static func beat(elapsed: Double) -> Int { Int(elapsed / bobPeriod) }

    /// The mascot blinks after every third bob.
    static func blinks(onBeat beat: Int) -> Bool { beat > 0 && beat.isMultiple(of: 3) }
}

/// Three rising bars shown beside the mascot while music plays. Mounted only
/// during playback; the bars hold still under Reduce Motion, when the window
/// is hidden, or while the screen is locked or asleep.
///
/// The bars move by a plain state write every `frameInterval`, not a
/// `TimelineView`: in the notch panel's `NSHostingView` a `TimelineView`
/// re-rendered about 240 times a second with any schedule.
struct NotchPlaybackIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rafuMotionAllowed) private var motionAllowed
    @Environment(\.rafuTheme) private var theme
    @State private var time: TimeInterval = 0

    /// 8 writes a second.
    static let frameInterval: TimeInterval = 1.0 / 8

    private var animating: Bool { motionAllowed && !reduceMotion }

    var body: some View {
        let time = animating ? time : 0
        Canvas { drawing, size in
            for bar in 0..<3 {
                let height = Self.barHeight(bar: bar, time: time)
                let rect = CGRect(
                    x: Double(bar) * 3.5, y: (size.height - height) / 2, width: 2,
                    height: height)
                drawing.fill(
                    Path(roundedRect: rect, cornerRadius: 1), with: .color(theme.palette.accent)
                )
            }
        }
        .frame(width: 10, height: 12)
        .accessibilityLabel("Music playing")
        .task(id: animating) {
            await run()
        }
    }

    /// One bar's height in points, from 3 to 10, `time` seconds in.
    nonisolated static func barHeight(bar: Int, time: TimeInterval) -> Double {
        3.0 + (sin(time * 7 + Double(bar) * 1.7) + 1) * 3.5
    }

    private func run() async {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { time = 0 }
        guard animating else { return }
        let clock = ContinuousClock()
        let start = clock.now
        while !Task.isCancelled {
            do {
                try await Task.sleep(
                    for: .seconds(Self.frameInterval), tolerance: .milliseconds(20))
            } catch {
                return
            }
            let elapsed = (clock.now - start) / .seconds(1)
            withTransaction(still) { time = elapsed }
        }
    }
}
