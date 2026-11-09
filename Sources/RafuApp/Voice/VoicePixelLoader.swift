import SwiftUI

/// The "Working" loader: a 3x3 grid of 2 pt squares. One cell lights per
/// step along a fixed path, at 8 Hz, with a dimmer trail behind it. Under
/// Reduce Motion, a hidden window or a locked screen it is a still grid at
/// 0.5. The step is written from one `Task.sleep` loop that exists only
/// while the loader is running and motion is allowed, so a hidden popover
/// (which removes the view) costs nothing. Decorative: always hidden from
/// VoiceOver, the row's own label says "working".
struct VoicePixelLoader: View {
    var isRunning = true
    @Environment(\.rafuTheme) private var theme
    @Environment(\.rafuMotionAllowed) private var motionAllowed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0

    static let frameInterval: Duration = .milliseconds(125)
    /// A snake through the grid, cell index = row * 3 + column.
    static let path = [0, 1, 2, 5, 4, 3, 6, 7, 8]
    static let cell: CGFloat = 2
    static let gap: CGFloat = 1

    static var side: CGFloat { cell * 3 + gap * 2 }

    private var animates: Bool { isRunning && motionAllowed && !reduceMotion }

    /// The brightness of a cell for a step: the head 1, the one behind it
    /// 0.55, the rest 0.18. Without motion every cell sits at 0.5.
    static func brightness(cell index: Int, step: Int, animates: Bool) -> Double {
        guard animates else { return 0.5 }
        let head = path[step % path.count]
        let trail = path[(step + path.count - 1) % path.count]
        if index == head { return 1 }
        if index == trail { return 0.55 }
        return 0.18
    }

    var body: some View {
        let ink = theme.palette.accent
        let step = step
        let animates = animates
        Canvas { context, _ in
            for index in 0..<9 {
                let column = CGFloat(index % 3)
                let row = CGFloat(index / 3)
                let rect = CGRect(
                    x: column * (Self.cell + Self.gap), y: row * (Self.cell + Self.gap),
                    width: Self.cell, height: Self.cell)
                let level = Self.brightness(cell: index, step: step, animates: animates)
                context.fill(Path(rect), with: .color(ink.opacity(level)))
            }
        }
        .frame(width: Self.side, height: Self.side)
        .accessibilityHidden(true)
        .task(id: animates) { await run() }
    }

    private func run() async {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { step = 0 }
        guard animates else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: Self.frameInterval, tolerance: .milliseconds(20))
            } catch {
                return
            }
            withTransaction(still) { step = (step + 1) % Self.path.count }
        }
    }
}

/// The 20 pt leading ring of a capsule. Running: a 270 degree arc that turns
/// (20 Hz state writes, only while running, visible and motion is allowed)
/// with the step count in the centre. Done: a check in a success circle.
/// Failed: an xmark in an error circle. Always hidden from VoiceOver; the
/// capsule's label carries the outcome in words.
struct VoiceRunningRing: View {
    enum Phase: Equatable {
        /// `steps` is the centre number; `nil` leaves the centre empty.
        case running(steps: Int?)
        case done
        case failed
    }

    let phase: Phase
    @Environment(\.rafuTheme) private var theme
    @Environment(\.rafuMotionAllowed) private var motionAllowed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle = 0.0

    static let size: CGFloat = 20
    static let frameInterval: Duration = .milliseconds(50)
    /// One turn takes 1.2 s: 24 writes of 15 degrees.
    static let degreesPerFrame = 15.0

    private var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    private var spins: Bool { isRunning && motionAllowed && !reduceMotion }

    var body: some View {
        Group {
            switch phase {
            case .running(let steps):
                ZStack {
                    Circle()
                        .stroke(theme.palette.accent.opacity(0.18), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: 0.75)
                        .stroke(
                            theme.palette.accent,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                        .rotationEffect(.degrees(angle))
                    if let steps {
                        Text("\(steps)")
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(theme.palette.textPrimary)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                    }
                }
            case .done:
                badge(symbol: "checkmark", color: theme.palette.success)
            case .failed:
                badge(symbol: "xmark", color: theme.palette.error)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
        .task(id: spins) { await spin() }
    }

    private func badge(symbol: String, color: Color) -> some View {
        ZStack {
            Circle().fill(color.opacity(0.18))
            Circle().strokeBorder(color, lineWidth: 1)
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
        }
    }

    private func spin() async {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { angle = 0 }
        guard spins else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: Self.frameInterval, tolerance: .milliseconds(10))
            } catch {
                return
            }
            withTransaction(still) {
                angle = (angle + Self.degreesPerFrame).truncatingRemainder(dividingBy: 360)
            }
        }
    }
}
