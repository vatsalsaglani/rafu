import SwiftUI

/// Colours for the mascot, resolved from the active theme. The notch is always
/// black, so the body must read as light on it in every theme: dark themes use
/// their primary text colour, light themes their paper colour. The thread is
/// the theme accent, the ink (eyes, mouth) is the opposite end of the theme.
struct RafuMascotColors {
    let body: Color
    let shade: Color
    let ink: Color
    let thread: Color
    let blush: Color

    init(theme: RafuTheme) {
        let palette = theme.palette
        let light = theme.isDark ? palette.textPrimary : palette.editorBackground
        let dark = theme.isDark ? palette.editorBackground : palette.textPrimary
        body = light
        shade = light.mix(with: .black, by: 0.28)
        ink = dark
        thread = palette.accent
        blush = palette.accent.opacity(0.4)
    }
}

/// The Rafu mascot: a round ball of mending yarn with a darning needle stuck
/// in its top. The thread through the needle's eye is the theme accent. The
/// artwork is drawn in the 512-point coordinate space of the SVG design
/// assets in `Resources/Mascot/` (`rafu-*.svg`), so a change to one belongs in
/// the other.
///
/// Parts move independently so the animated view can blink, glance, sway the
/// needle and breathe without redrawing the body.
struct RafuMascotArtwork: View {
    let mood: RafuMascotMood
    let colors: RafuMascotColors
    var size: CGFloat = 22
    var blink: CGFloat = 1
    var gaze: CGFloat = 0
    var sway: Double = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            needleAndThread
                .rotationEffect(.degrees(sway), anchor: RafuMascotGeometry.needleAnchor)
            ball
            strands
            face
            if mood == .needsYou {
                Circle()
                    .fill(colors.thread)
                    .frame(width: 76, height: 76)
                    .overlay(Circle().strokeBorder(Color.black, lineWidth: 10))
                    .position(x: 88, y: 118)
            }
        }
        .frame(width: 512, height: 512)
        .scaleEffect(size / 512)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var ball: some View {
        ZStack {
            Ellipse()
                .fill(
                    LinearGradient(
                        colors: [colors.body, colors.shade],
                        startPoint: UnitPoint(x: 0.2, y: 0.1),
                        endPoint: UnitPoint(x: 0.85, y: 1)))
            Ellipse()
                .fill(Color.white.opacity(0.28))
                .frame(width: 130, height: 76)
                .rotationEffect(.degrees(-24))
                .offset(x: -70, y: -92)
        }
        .frame(width: RafuMascotGeometry.ballWidth, height: RafuMascotGeometry.ballHeight)
        .position(x: RafuMascotGeometry.ballCenter.x, y: RafuMascotGeometry.ballCenter.y)
    }

    /// Yarn strands wrapped around the ball, clipped to its outline.
    private var strands: some View {
        ZStack {
            ForEach(Array(RafuMascotGeometry.strands.enumerated()), id: \.offset) { _, strand in
                strand.path
                    .stroke(
                        colors.thread.opacity(strand.opacity),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round))
            }
        }
        .frame(width: 512, height: 512)
        .mask {
            Ellipse()
                .frame(width: RafuMascotGeometry.ballWidth, height: RafuMascotGeometry.ballHeight)
                .position(
                    x: RafuMascotGeometry.ballCenter.x, y: RafuMascotGeometry.ballCenter.y)
        }
    }

    private var needleAndThread: some View {
        ZStack(alignment: .topLeading) {
            RafuMascotGeometry.needle
                .stroke(colors.body, style: StrokeStyle(lineWidth: 15, lineCap: .round))
            Circle()
                .fill(colors.ink)
                .frame(width: 11, height: 11)
                .position(RafuMascotGeometry.needleEye)
            RafuMascotGeometry.thread
                .stroke(colors.thread, style: StrokeStyle(lineWidth: 11, lineCap: .round))
        }
        .frame(width: 512, height: 512)
    }

    @ViewBuilder
    private var face: some View {
        ForEach([RafuMascotGeometry.leftEyeX, RafuMascotGeometry.rightEyeX], id: \.self) { x in
            eye(centerX: x)
        }
        Ellipse()
            .fill(colors.blush)
            .frame(width: 46, height: 28)
            .position(x: 142, y: 344)
        Ellipse()
            .fill(colors.blush)
            .frame(width: 46, height: 28)
            .position(x: 370, y: 344)
        mouth
    }

    @ViewBuilder
    private func eye(centerX: Double) -> some View {
        let centerY = mood == .needsYou ? 280.0 : 285.0
        if mood == .replyReady {
            RafuMascotGeometry.happyEye(centerX: centerX)
                .stroke(colors.ink, style: StrokeStyle(lineWidth: 13, lineCap: .round))
        } else {
            let tall = mood == .needsYou && centerX == RafuMascotGeometry.rightEyeX
            let lid = mood == .working ? 0.78 : 1.0
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(colors.ink)
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 13, height: 13)
                        .padding(.top, 10)
                        .padding(.trailing, 6)
                }
                .frame(width: 38, height: 66)
                .scaleEffect(x: 1, y: tall ? 1.15 : blink * lid)
                .position(x: centerX + gaze, y: centerY)
        }
    }

    @ViewBuilder
    private var mouth: some View {
        switch mood {
        case .idle:
            RafuMascotGeometry.smile
                .stroke(colors.ink, style: StrokeStyle(lineWidth: 9, lineCap: .round))
        case .working:
            RafuMascotGeometry.flatMouth
                .stroke(colors.ink, style: StrokeStyle(lineWidth: 9, lineCap: .round))
        case .needsYou:
            Ellipse()
                .fill(colors.ink)
                .frame(width: 26, height: 30)
                .position(x: 256, y: 362)
        case .replyReady:
            RafuMascotGeometry.openSmile.fill(colors.ink)
        }
    }
}

/// The animated mascot. Motion runs only while `visible` and never under
/// Reduce Motion; either way the still pose of the mood is shown. Blink and
/// breathing are sparse timer-free tasks, so a calm notch costs no frames.
struct RafuMascotView: View {
    let state: RafuMascotState
    let visible: Bool
    var size: CGFloat = 22
    let claimBounce: (UUID) -> Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rafuTheme) private var theme
    @State private var blink: CGFloat = 1
    @State private var gaze: CGFloat = 0
    @State private var lift: CGFloat = 0
    @State private var sway: Double = 0
    @State private var breathing = false

    private var animates: Bool { visible && !reduceMotion }

    var body: some View {
        RafuMascotArtwork(
            mood: state.mood, colors: RafuMascotColors(theme: theme), size: size,
            blink: animates ? blink : 1, gaze: animates ? gaze : 0,
            sway: animates ? sway : stillSway
        )
        .scaleEffect(
            x: breathing && animates ? 1.01 : 1, y: breathing && animates ? 0.99 : 1,
            anchor: .bottom
        )
        .offset(y: animates ? lift * size / 512 : 0)
        .help("Rafu · " + state.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rafu")
        .accessibilityValue(state.label)
        .task(id: MascotMotionKey(mood: state.mood, reply: state.replyID, enabled: animates)) {
            await animate()
        }
    }

    /// The pose when motion is off: a working mascot leans, others stand.
    private var stillSway: Double { state.mood == .working ? -7 : 0 }

    private func reset() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            blink = 1
            gaze = 0
            lift = 0
            sway = 0
            breathing = false
        }
    }

    private func animate() async {
        reset()
        guard animates else { return }
        do {
            if let replyID = state.replyID {
                // One bounce per reply; the happy face stays while it waits.
                if claimBounce(replyID) {
                    withAnimation(.easeOut(duration: 0.16)) { lift = -14 }
                    try await Task.sleep(for: .milliseconds(160))
                    withAnimation(.spring(duration: 0.32, bounce: 0.25)) { lift = 0 }
                }
                return
            }
            if state.mood == .needsYou {
                // Attention: a small repeated hop, then stillness. Sparse on
                // purpose; the dot and the wide eye carry the state.
                while !Task.isCancelled {
                    withAnimation(.easeOut(duration: 0.14)) { lift = -10 }
                    try await Task.sleep(for: .milliseconds(140))
                    withAnimation(.spring(duration: 0.3, bounce: 0.3)) { lift = 0 }
                    try await Task.sleep(for: .seconds(4))
                }
                return
            }
            if state.mood == .working {
                var right = true
                var beats = 0
                while !Task.isCancelled {
                    withAnimation(.easeInOut(duration: 0.85)) {
                        sway = right ? -9 : 9
                        gaze = right ? -14 : 14
                    }
                    try await Task.sleep(for: .milliseconds(850))
                    beats += 1
                    if beats.isMultiple(of: 4) { try await blinkOnce() }
                    right.toggle()
                }
                return
            }
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(6.7))
                withAnimation(.easeInOut(duration: 0.35)) { breathing = true }
                try await blinkOnce()
                try await Task.sleep(for: .milliseconds(400))
                withAnimation(.easeInOut(duration: 0.45)) { breathing = false }
            }
        } catch {
            // Cancelled by a mood change, hiding, or Reduce Motion.
        }
    }

    private func blinkOnce() async throws {
        withAnimation(.linear(duration: 0.08)) { blink = 0.09 }
        try await Task.sleep(for: .milliseconds(100))
        withAnimation(.easeOut(duration: 0.14)) { blink = 1 }
    }
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
                        x: Double(bar) * 3.5, y: (size.height - height) / 2, width: 2, height: height)
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
