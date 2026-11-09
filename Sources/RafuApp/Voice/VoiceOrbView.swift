import Observation
import RafuCore
import SwiftUI

/// The orb's colours, built from the active theme: Indigo, Khadi, every
/// bundled theme and user themes, light and dark. Missing tokens in a user
/// theme already resolve to fallbacks in `RafuThemePalette`. The orb's look
/// lives only here and in `VoiceOrbView`, so it can change on its own.
struct VoiceOrbPalette {
    /// The dark disc under the light.
    let base: Color
    /// The base's lit centre.
    let baseGlow: Color
    /// Four lobe colours: cool, accent, light, warm.
    let lobes: [Color]
    /// The light tone the lobes shift toward while Rafu speaks.
    let light: Color
    let eye: Color
    /// The ring is the theme accent.
    let ring: Color
    /// The rim shade's strength; Increase Contrast makes the edge firmer.
    let rimShade: Double

    init(theme: RafuTheme, increaseContrast: Bool = false) {
        let palette = theme.palette
        // Light themes carry darker accents made for paper; the orb is a
        // dark sphere on any theme, so it lifts them first (as the mascot does).
        let accent = theme.isDark ? palette.accent : palette.accent.mix(with: .white, by: 0.18)
        base =
            theme.isDark
            ? palette.appBackground.mix(with: .black, by: 0.35)
            : palette.textPrimary.mix(with: palette.accent, by: 0.12).mix(with: .black, by: 0.2)
        baseGlow = base.mix(with: palette.info, by: 0.22)
        light = accent.mix(with: .white, by: 0.6)
        lobes = [
            palette.info.mix(with: base, by: 0.25),
            accent,
            light,
            palette.warning.mix(with: accent, by: 0.4),
        ]
        eye = accent.mix(with: .white, by: 0.88)
        ring = palette.accent
        rimShade = increaseContrast ? 0.55 : 0.35
    }
}

/// The voice orb: a dark disc, four lobes of light, a specular highlight, a
/// rim shade, and two eye-lights while Rafu listens. Pure inputs only; one
/// `Canvas`, no blur filter, no animation of its own. `level`, `phase` and
/// `ripple` come from `VoicePresenceSampler`; with the sampler stopped the
/// orb is one static frame.
struct VoiceOrbView: View {
    let pose: VoiceOrbPose
    let palette: VoiceOrbPalette
    var level = 0.0
    var phase = 0.0
    var ripple = 0.0
    var size: CGFloat = 72

    /// Lobe angle, distance and radius factors.
    private static let lobes: [(angle: Double, reach: Double, colour: Int)] = [
        (0, 0.42, 0), (2.1, 0.38, 1), (4.2, 0.34, 2), (1.1, 0.26, 1),
    ]

    var body: some View {
        Canvas { context, canvasSize in
            draw(in: &context, size: canvasSize)
        }
        .frame(width: size, height: size)
        .saturation(1 - pose.desaturation)
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size canvasSize: CGSize) {
        let side = min(canvasSize.width, canvasSize.height)
        // The ring and the ripple sit outside the disc.
        let radius = side / 2 * 0.86 * pose.scale
        let centre = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let disc = CGRect(
            x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
        let discPath = Path(ellipseIn: disc)

        context.fill(
            discPath,
            with: .radialGradient(
                Gradient(colors: [palette.baseGlow, palette.base]),
                center: CGPoint(x: centre.x - radius * 0.2, y: centre.y - radius * 0.2),
                startRadius: 0, endRadius: radius))

        var lobesLayer = context
        lobesLayer.clip(to: discPath)
        lobesLayer.blendMode = .plusLighter
        let dim = pose.brightness
        for (index, lobe) in Self.lobes.enumerated() {
            let direction: Double = index.isMultiple(of: 2) ? -1 : 1
            let angle =
                lobe.angle + phase * direction * 0.6 + sin(phase * 0.7 + Double(index)) * 0.3
            let reach =
                radius * (0.22 + lobe.reach * 0.9 * level + 0.08 * sin(phase + Double(index) * 2))
            let point = CGPoint(
                x: centre.x + cos(angle) * reach,
                y: centre.y + sin(angle) * reach * 0.85 + radius * 0.08)
            let lobeRadius = radius * (0.46 + 0.28 * level + (lobe.colour == 2 ? 0.1 : 0))
            var colour = palette.lobes[index]
            if pose.lightShift > 0 { colour = colour.mix(with: palette.light, by: pose.lightShift) }
            let alpha = (pose.lightShift > 0 && lobe.colour == 2 ? 0.9 : 0.75) * dim
            lobesLayer.fill(
                Path(
                    ellipseIn: CGRect(
                        x: point.x - lobeRadius, y: point.y - lobeRadius, width: lobeRadius * 2,
                        height: lobeRadius * 2)),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: colour.opacity(alpha), location: 0),
                        .init(color: colour.opacity(0.28 * dim), location: 0.55),
                        .init(color: colour.opacity(0), location: 1),
                    ]),
                    center: point, startRadius: 0, endRadius: lobeRadius))
        }

        // Specular light, top left.
        let specular = CGPoint(x: centre.x - radius * 0.38, y: centre.y - radius * 0.45)
        context.fill(
            discPath,
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: .white.opacity(0.32), location: 0),
                    .init(color: .white.opacity(0.06), location: 0.35),
                    .init(color: .white.opacity(0), location: 1),
                ]),
                center: specular, startRadius: 0, endRadius: radius * 0.9))

        drawEyes(in: &context, centre: centre, radius: radius)

        // Rim shade.
        context.fill(
            discPath,
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: .black.opacity(0), location: 0.86),
                    .init(color: .black.opacity(palette.rimShade), location: 1),
                ]),
                center: centre, startRadius: 0, endRadius: radius))

        if pose.ringOpacity > 0 {
            let inset = radius + 3 + pose.ringWidth / 2
            context.stroke(
                Path(
                    ellipseIn: CGRect(
                        x: centre.x - inset, y: centre.y - inset, width: inset * 2,
                        height: inset * 2)),
                with: .color(palette.ring.opacity(pose.ringOpacity)), lineWidth: pose.ringWidth)
        }
        if ripple > 0 {
            let spread = radius + 2 + (side / 2 - radius - 2) * ripple
            context.stroke(
                Path(
                    ellipseIn: CGRect(
                        x: centre.x - spread, y: centre.y - spread, width: spread * 2,
                        height: spread * 2)),
                with: .color(palette.ring.opacity(0.6 * (1 - ripple))), lineWidth: 1.5)
        }
    }

    private func drawEyes(in context: inout GraphicsContext, centre: CGPoint, radius: CGFloat) {
        guard pose.eyes != .closed else { return }
        let lift = pose.eyesLookUp ? radius * 0.1 : 0
        let height = radius * (pose.eyes == .half ? 0.12 : 0.28)
        let width = radius * 0.22
        for side in [-1.0, 1.0] {
            let eyeCentre = CGPoint(
                x: centre.x + side * radius * 0.27, y: centre.y - radius * 0.1 - lift)
            let rect = CGRect(
                x: eyeCentre.x - width / 2, y: eyeCentre.y - height / 2, width: width,
                height: height)
            context.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: palette.eye.opacity(0.95), location: 0),
                        .init(color: palette.eye.opacity(0.5), location: 0.5),
                        .init(color: palette.eye.opacity(0), location: 1),
                    ]),
                    center: eyeCentre, startRadius: 0, endRadius: max(width, height) * 0.6))
        }
    }
}

/// Drives one orb at 20 Hz while something moves it: the microphone is open,
/// Rafu speaks, or Rafu thinks. Otherwise no task runs and the orb is one
/// static frame. The hosting view owns it in `@State` and runs `run` from a
/// `.task(id:)` whose id includes `\.rafuMotionAllowed` and Reduce Motion, so
/// an occluded window, a locked screen or Reduce Motion cancels the loop.
@MainActor
@Observable
final class VoicePresenceSampler {
    static let interval: Duration = .milliseconds(50)
    static let tolerance: Duration = .milliseconds(10)

    private(set) var snapshot = VoiceLevelSmoother.Snapshot()
    @ObservationIgnored private var smoother = VoiceLevelSmoother()

    /// Whether `pose` needs the loop at all.
    static func isActive(pose: VoiceOrbPose, motionAllowed: Bool, reduceMotion: Bool) -> Bool {
        guard motionAllowed, !reduceMotion else { return false }
        return pose.driver != .still || pose.ripple != .none
    }

    /// The loop. Returns at once (after resetting to a still frame) when
    /// `active` is false; otherwise runs until cancelled.
    func run(active: Bool, session: VoiceSession, pose: @escaping () -> VoiceOrbPose) async {
        guard active else {
            settle()
            return
        }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: Self.interval, tolerance: Self.tolerance)
            } catch {
                break
            }
            let current = pose()
            let raw: Double =
                switch current.driver {
                case .input: session.inputLevel
                case .output: session.outputLevel
                case .turning, .still: 0
                }
            guard let next = smoother.step(raw: raw, pose: current) else { continue }
            write(next)
        }
        settle()
    }

    /// Back to one still frame.
    private func settle() {
        smoother.reset()
        let rest = smoother.written
        guard rest != snapshot else { return }
        write(rest)
    }

    private func write(_ next: VoiceLevelSmoother.Snapshot) {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { snapshot = next }
    }
}

/// An orb wired to the session: the pose from the session state, the palette
/// from the theme, and its own sampler. Used by the companion and the notch.
struct VoiceLiveOrb: View {
    let session: VoiceSession
    var size: CGFloat = 72
    /// The notch shows a smaller, plainer orb: no ring outside the disc.
    var showsRing = true
    @Environment(\.rafuTheme) private var theme
    @Environment(\.rafuMotionAllowed) private var motionAllowed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var sampler = VoicePresenceSampler()

    private var pose: VoiceOrbPose {
        var pose = VoiceOrbPose.pose(
            for: session.blobState, micOpen: session.isMicOpen,
            latched: session.machine.mic == .latched, increaseContrast: contrast == .increased)
        if !showsRing {
            pose.ringOpacity = 0
            pose.ripple = .none
        }
        return pose
    }

    private var active: Bool {
        VoicePresenceSampler.isActive(
            pose: pose, motionAllowed: motionAllowed, reduceMotion: reduceMotion)
    }

    var body: some View {
        let pose = pose
        let snapshot = sampler.snapshot
        VoiceOrbView(
            pose: pose,
            palette: VoiceOrbPalette(theme: theme, increaseContrast: contrast == .increased),
            level: snapshot.level, phase: snapshot.phase, ripple: snapshot.ripple, size: size
        )
        .task(id: SamplerKey(active: active, driver: pose.driver, ripple: pose.ripple)) {
            let session = session
            let showsRing = showsRing
            let contrast = contrast
            await sampler.run(active: active, session: session) {
                var current = VoiceOrbPose.pose(
                    for: session.blobState, micOpen: session.isMicOpen,
                    latched: session.machine.mic == .latched,
                    increaseContrast: contrast == .increased)
                if !showsRing { current.ripple = .none }
                return current
            }
        }
    }

    private struct SamplerKey: Equatable {
        let active: Bool
        let driver: VoiceOrbPose.Driver
        let ripple: VoiceOrbPose.Ripple
    }
}
