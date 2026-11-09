import CoreGraphics
import Foundation

// The voice companion's pure rules (voice-presence.md): the orb's pose per
// state, the level smoother, the caption window, what the speech card shows
// and when it hides, and where the companion sits. No view, no clock, no I/O.

// MARK: Orb face

/// What the voice orb (the "kanche", a glass marble with a face of two dots)
/// shows. The session state maps to one face; `hearing` and `success` are
/// shown by the orb itself (speech arrives while listening; a task ended).
public nonisolated enum VoiceOrbFace: String, CaseIterable, Sendable {
    case off, connecting, listening, hearing, thinking, speaking, checkIn, paused, needsConfirm,
        error, success

    public static func face(for state: VoiceBlobState) -> VoiceOrbFace {
        switch state {
        case .idle: .off
        case .connecting: .connecting
        case .listeningHeld, .listeningLatched: .listening
        case .thinking: .thinking
        case .speaking: .speaking
        case .checkIn: .checkIn
        case .paused: .paused
        case .needsConfirm: .needsConfirm
        case .error: .error
        }
    }

    /// The faces that need the motion clock: they move with time or with an
    /// audio level. Listening needs it to notice speech. Every other face is
    /// one still frame once its pose is reached.
    public var usesClock: Bool {
        switch self {
        case .connecting, .listening, .hearing, .thinking, .speaking: true
        default: false
        }
    }

    /// Open eyes blink now and then.
    public var blinks: Bool {
        switch self {
        case .off, .success: false
        default: true
        }
    }

    /// Only the faces where the user must know or act carry a badge (user
    /// decision, 2026-11-10). So a badge always means: Rafu does not hear
    /// you, or Rafu needs you.
    public var badgeSymbol: String? {
        switch self {
        case .paused: "pause.fill"
        case .needsConfirm: "hand.raised.fill"
        case .error: "exclamationmark"
        default: nil
        }
    }

    /// The Done face shows for this long after each completed task.
    public static let doneHold: Duration = .milliseconds(1200)

    /// Done never replaces a face that needs the user, or Off.
    public func withDone(_ showsDone: Bool) -> VoiceOrbFace {
        guard showsDone else { return self }
        switch self {
        case .needsConfirm, .error, .off: return self
        default: return .success
        }
    }
}

/// One pose of the face and the marble. Every field is a number, so two poses
/// can mix and the motion can ease from one to the next.
public nonisolated struct VoiceOrbExpression: Equatable, Sendable {
    /// 0 closed … 1 open.
    public var lids = 1.0
    /// 1: the eyes are happy arcs.
    public var happy = 0.0
    /// -1…1 each; +y is down.
    public var gazeX = 0.0
    public var gazeY = 0.0
    /// The dot size factor.
    public var dot = 1.0
    /// 0 hides the brows.
    public var brows = 0.0
    public var browRaise = 0.0
    /// + : inner ends up (worried).
    public var browTilt = 0.0
    /// Extra lift of the left brow only (thinking).
    public var browSkew = 0.0
    /// Head tilt in radians.
    public var tilt = 0.0
    /// Wobble speed of the marble (phase per second). It rocks; it never spins.
    public var spin = 0.0
    /// Extra wobble speed per unit of level.
    public var levelSpin = 0.0
    /// How much the cat's-eye swells per unit of level.
    public var levelSwell = 0.0
    /// 0 full colour … 1 grey.
    public var grey = 0.0
    /// 0…1 brightness of the cat's-eye and the caustic.
    public var glow = 1.0
    /// The marble's size in its slot.
    public var scale = 1.0

    public init() {}

    public static func target(for face: VoiceOrbFace) -> VoiceOrbExpression {
        var e = VoiceOrbExpression()
        switch face {
        case .off:
            e.lids = 0
            e.grey = 0.55
            e.glow = 0.45
            e.scale = 0.92
        case .connecting:
            e.lids = 0.6
            e.spin = 0.9
            e.glow = 0.7
            e.scale = 0.96
        case .listening:
            e.gazeY = 0.1
        case .hearing:
            e.dot = 1.15
            e.gazeY = 0.05
            e.brows = 1
            e.browRaise = 0.6
            e.levelSpin = 1.6
            e.levelSwell = 0.28
        case .thinking:
            e.gazeX = -0.8
            e.gazeY = -0.9
            e.dot = 0.88
            e.brows = 1
            e.browSkew = 0.9
            e.spin = 1.1
            e.glow = 0.9
        case .speaking:
            e.dot = 0.95
            e.gazeY = 0.15
            e.spin = 0.45
            e.levelSpin = 1
            e.levelSwell = 0.35
        case .checkIn:
            e.dot = 1.1
            e.brows = 1
            e.browRaise = 0.8
            e.browSkew = 0.5
            e.gazeY = -0.2
            e.tilt = 0.14
        case .paused:
            e.lids = 0.45
            e.gazeY = 0.8
            e.grey = 0.5
            e.glow = 0.6
            e.scale = 0.95
        case .needsConfirm:
            e.dot = 1.3
            e.brows = 1
            e.browRaise = 1
            e.gazeY = -0.4
        case .error:
            e.gazeY = 0.7
            e.dot = 0.85
            e.brows = 1
            e.browTilt = 1
            e.grey = 0.7
            e.glow = 0.5
        case .success:
            e.happy = 1
            e.spin = 2.4
        }
        return e
    }

    private static var fields: [WritableKeyPath<VoiceOrbExpression, Double>] {
        [
            \.lids, \.happy, \.gazeX, \.gazeY, \.dot, \.brows, \.browRaise, \.browTilt, \.browSkew,
            \.tilt, \.spin, \.levelSpin, \.levelSwell, \.grey, \.glow, \.scale,
        ]
    }

    /// `fraction` of the way to `target`; snaps to it when it is close, so a
    /// finished change is exactly equal and stops the clock.
    public func approaching(_ target: VoiceOrbExpression, by fraction: Double)
        -> VoiceOrbExpression
    {
        var next = self
        var far = 0.0
        for field in Self.fields {
            let delta = target[keyPath: field] - self[keyPath: field]
            next[keyPath: field] = self[keyPath: field] + delta * fraction
            far = max(far, abs(delta))
        }
        return far * (1 - fraction) < 0.01 ? target : next
    }
}

// MARK: Orb motion

/// The orb's motion, one tick at a time (30 Hz). Pure: the app's animator
/// calls `step` from a sleeping loop and writes the result only when
/// `step` reports a change. Silence never moves anything.
public nonisolated struct VoiceOrbMotion: Equatable, Sendable {
    public static let ticksPerSecond = 30.0
    /// Listening shows the hearing face above this mic level …
    public static let hearOn = 0.08
    /// … and returns below this one.
    public static let hearOff = 0.02
    /// Easing per tick: a change of face takes about 8 ticks.
    public static let ease = 0.28
    /// The shown level falls by this factor per tick.
    public static let decay = 0.8
    /// One connecting ripple takes this long, in seconds.
    public static let rippleSeconds = 1.2

    /// What one frame draws.
    public struct Drawn: Equatable, Sendable {
        public var expression = VoiceOrbExpression.target(for: .off)
        /// The marble's wobble phase.
        public var phase = 0.6
        public var level = 0.0
        /// 0…1 progress of the connecting ripple; 0 hides it.
        public var ripple = 0.0
        /// Pointer or wander gaze, added to the expression's gaze.
        public var lookX = 0.0
        public var lookY = 0.0
        public init() {}
    }

    public private(set) var drawn = Drawn()
    public private(set) var hearing = false
    private var time = 0.0

    public init(face: VoiceOrbFace = .off) {
        drawn.expression = .target(for: face)
    }

    /// Listening becomes Hearing while speech arrives.
    public func shown(_ face: VoiceOrbFace) -> VoiceOrbFace {
        face == .listening && hearing ? .hearing : face
    }

    /// The still frame for `face` (Reduce Motion, or a window that cannot
    /// show motion): the pose at once, no level, no ripple, eyes ahead.
    public mutating func rest(face: VoiceOrbFace) {
        hearing = false
        let phase = drawn.phase
        drawn = Drawn()
        drawn.phase = phase
        drawn.expression = .target(for: face)
    }

    /// One tick. `pointer` is -1…1 from the orb's centre while the pointer
    /// is over the orb. Returns true when the drawn frame changed.
    @discardableResult
    public mutating func step(
        face: VoiceOrbFace, mic: Double, output: Double, pointer: (x: Double, y: Double)? = nil
    ) -> Bool {
        let before = drawn
        let dt = 1 / Self.ticksPerSecond
        time += dt
        let micLevel = Self.clamped(mic)
        if face == .listening {
            if micLevel > Self.hearOn {
                hearing = true
            } else if micLevel < Self.hearOff {
                hearing = false
            }
        } else {
            hearing = false
        }
        let shown = shown(face)
        let target = VoiceOrbExpression.target(for: shown)
        drawn.expression = drawn.expression.approaching(target, by: Self.ease)

        let raw: Double =
            switch shown {
            case .hearing: micLevel
            case .speaking: Self.clamped(output)
            default: 0
            }
        drawn.level = max(raw, drawn.level * Self.decay)
        if drawn.level < 0.005 { drawn.level = 0 }
        let settling = drawn.expression != target
        // Success wobbles only while its face arrives; then it rests.
        let spin = shown == .success && !settling ? 0 : drawn.expression.spin
        drawn.phase += dt * (spin + drawn.level * target.levelSpin)
        drawn.ripple =
            shown == .connecting
            ? (drawn.ripple + dt / Self.rippleSeconds).truncatingRemainder(dividingBy: 1) : 0

        switch shown {
        case .connecting:
            drawn.lookX = sin(time * 1.6) * 0.6
            drawn.lookY = 0
        case .thinking:
            drawn.lookX = sin(time * 0.9) * 0.12
            drawn.lookY = 0
        default:
            // The dots follow the pointer only while listening.
            let wanted = (shown == .listening || shown == .hearing) ? pointer : nil
            drawn.lookX = Self.approach(drawn.lookX, wanted?.x ?? 0)
            drawn.lookY = Self.approach(drawn.lookY, wanted?.y ?? 0)
        }
        return drawn != before
    }

    /// True when ticks would change nothing more for `face`: a face with no
    /// clock whose pose, level, ripple and gaze have arrived.
    public func isSettled(face: VoiceOrbFace) -> Bool {
        let shown = shown(face)
        guard !shown.usesClock else { return false }
        return drawn.expression == .target(for: shown) && drawn.level == 0 && drawn.ripple == 0
            && drawn.lookX == 0 && drawn.lookY == 0
    }

    private static func approach(_ value: Double, _ target: Double) -> Double {
        let next = value + (target - value) * 0.3
        return abs(target - next) < 0.01 ? target : next
    }

    private static func clamped(_ value: Double) -> Double {
        min(1, max(0, value.isFinite ? value : 0))
    }

    public static func == (lhs: VoiceOrbMotion, rhs: VoiceOrbMotion) -> Bool {
        lhs.drawn == rhs.drawn && lhs.hearing == rhs.hearing
    }
}

// MARK: Captions

/// Who said the live words on the speech card.
public nonisolated enum VoiceSpeaker: Equatable, Sendable {
    case you, rafu
}

/// The live words of the current turn, bounded. Never written to disk.
public nonisolated struct VoiceCaption: Equatable, Sendable {
    public static let maximumScalars = 160
    /// Rafu's words show at most this many at a time.
    public static let windowWords = 12

    public let speaker: VoiceSpeaker
    public private(set) var text: String
    /// Moves with every change, so the card can restart its hide timer.
    public private(set) var revision: Int

    public init(speaker: VoiceSpeaker, text: String = "", revision: Int = 0) {
        self.speaker = speaker
        self.text = Self.bounded(text)
        self.revision = revision
    }

    /// Adds a transcript delta. The text keeps its newest
    /// `maximumScalars` scalars.
    public mutating func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        text = Self.bounded(text + delta)
        revision &+= 1
    }

    /// True when the words end a sentence (the card announces it then).
    public var endsSentence: Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".!?".contains(last)
    }

    /// The text without line breaks, cut to the newest scalars at a word.
    public static func bounded(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let scalars = flat.unicodeScalars
        guard scalars.count > maximumScalars else { return flat }
        let tail = String(String.UnicodeScalarView(scalars.suffix(maximumScalars)))
        guard let space = tail.firstIndex(of: " ") else { return tail }
        return String(tail[tail.index(after: space)...])
    }

    /// What the card shows: the newest `words` words, so a long reply reads
    /// as a moving window instead of a wall of text.
    public static func window(_ text: String, words: Int = windowWords) -> String {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard parts.count > words else {
            return parts.joined(separator: " ")
        }
        return "…" + parts.suffix(words).joined(separator: " ")
    }
}

// MARK: Agent line

/// The speech card's line for a spoken agent update.
public nonisolated struct VoiceAgentLine: Equatable, Sendable {
    public let cardID: String
    public let agent: String
    public let kind: VoiceAgentUpdate.Kind
    public let title: String
    /// Moves with every new update, so the card cross-fades.
    public let sequence: Int

    public init(update: VoiceAgentUpdate, sequence: Int) {
        cardID = update.cardID
        agent = update.agent
        kind = update.kind
        title = VoiceAgentUpdatePolicy.cleanTitle(update.title)
        self.sequence = sequence
    }

    /// "Codex in Tests is done", "Claude Code in API needs you".
    public var text: String {
        switch kind {
        case .done: "\(agent) in \(title) is done"
        case .needsApproval: "\(agent) in \(title) needs your approval"
        case .waiting: "\(agent) in \(title) needs you"
        }
    }

    /// One letter for the CLI glyph.
    public var monogram: String { agent.first.map { String($0).uppercased() } ?? "A" }
}

// MARK: Speech card

/// What the speech card shows, and when it hides. At most one card.
public nonisolated enum VoiceCardPolicy {
    public static let hideAfter: Duration = .seconds(4)

    public enum Content: Equatable, Sendable {
        case none
        case status(String)
        case caption(VoiceSpeaker, String)
        case agent(VoiceAgentLine)
        case confirm
        case error(String)
    }

    public struct Inputs: Equatable, Sendable {
        public var state: VoiceBlobState
        public var caption: VoiceCaption?
        public var agentLine: VoiceAgentLine?
        public var hint: String?
        public var hasPendingConfirm: Bool

        public init(
            state: VoiceBlobState, caption: VoiceCaption? = nil,
            agentLine: VoiceAgentLine? = nil, hint: String? = nil, hasPendingConfirm: Bool = false
        ) {
            self.state = state
            self.caption = caption
            self.agentLine = agentLine
            self.hint = hint
            self.hasPendingConfirm = hasPendingConfirm
        }
    }

    /// Order: Confirm, error, the state's own words, a hint, the live
    /// caption, then an agent line. A voice caption always wins over an
    /// agent line.
    public static func content(_ inputs: Inputs) -> Content {
        if inputs.state == .needsConfirm, inputs.hasPendingConfirm { return .confirm }
        switch inputs.state {
        case .idle:
            return .none
        case .error(let reason):
            return .error(reason)
        case .connecting:
            return .status("Connecting…")
        case .thinking:
            return .status("Working…")
        case .checkIn:
            return .status("Still there?")
        default:
            break
        }
        if let hint = inputs.hint, !hint.isEmpty { return .status(hint) }
        if let caption = inputs.caption, !caption.text.isEmpty {
            // Your words while you talk; Rafu's while Rafu speaks.
            let current =
                (caption.speaker == .rafu && inputs.state == .speaking)
                || (caption.speaker == .you && inputs.state != .speaking)
            if current {
                let text =
                    caption.speaker == .rafu ? VoiceCaption.window(caption.text) : caption.text
                return .caption(caption.speaker, text)
            }
        }
        if let line = inputs.agentLine { return .agent(line) }
        return .none
    }

    /// The card never hides while Rafu speaks, a Confirm waits, an error
    /// shows, or the pointer is over it.
    public static func staysVisible(_ content: Content, state: VoiceBlobState, hovering: Bool)
        -> Bool
    {
        if hovering || state == .speaking { return true }
        switch content {
        case .confirm, .error: return true
        case .status: return state == .thinking || state == .connecting
        default: return false
        }
    }
}

// MARK: Placement

/// A corner of the window the companion snaps to.
public nonisolated enum VoiceCompanionCorner: String, CaseIterable, Sendable {
    case topLeading = "tl"
    case topTrailing = "tr"
    case bottomLeading = "bl"
    case bottomTrailing = "br"

    public static let defaultCorner = VoiceCompanionCorner.bottomTrailing

    public var isTop: Bool { self == .topLeading || self == .topTrailing }
    public var isLeading: Bool { self == .topLeading || self == .bottomLeading }

    public init(top: Bool, leading: Bool) {
        switch (top, leading) {
        case (true, true): self = .topLeading
        case (true, false): self = .topTrailing
        case (false, true): self = .bottomLeading
        case (false, false): self = .bottomTrailing
        }
    }

    public enum Move: Sendable {
        case left, right, up, down
    }

    /// ⌥ + an arrow key: the adjacent corner in that direction (or this one).
    public func moved(_ move: Move) -> VoiceCompanionCorner {
        switch move {
        case .left: VoiceCompanionCorner(top: isTop, leading: true)
        case .right: VoiceCompanionCorner(top: isTop, leading: false)
        case .up: VoiceCompanionCorner(top: true, leading: isLeading)
        case .down: VoiceCompanionCorner(top: false, leading: isLeading)
        }
    }

    /// Clockwise: top-leading, top-trailing, bottom-trailing, bottom-leading.
    public var next: VoiceCompanionCorner {
        switch self {
        case .topLeading: .topTrailing
        case .topTrailing: .bottomTrailing
        case .bottomTrailing: .bottomLeading
        case .bottomLeading: .topLeading
        }
    }

    public var spokenName: String {
        switch self {
        case .topLeading: "top left"
        case .topTrailing: "top right"
        case .bottomLeading: "bottom left"
        case .bottomTrailing: "bottom right"
        }
    }
}

/// Where the companion, its card and its pill sit. Pure geometry in the
/// host's coordinate space (origin top-left).
///
/// Board chrome (the zoom capsule and the overview above it) reports a
/// reserved rect; the orb never covers it. In a bottom corner the orb sits
/// above that rect, on the same vertical line (user decision, 2026-11-10).
/// The card and the pill are placed by explicit rects, never by alignment
/// guides: a guide set inside an `if` does not reach `.overlay(alignment:)`,
/// which is how the pill once covered the orb and left the window.
public nonisolated enum VoiceCompanionPlacement {
    /// The slot the orb lives in. The orb does not grow on hover.
    public static let slotSize = 64.0
    public static let orbSize = 64.0
    public static let idleOrbSize = 40.0
    public static let tuckedOrbSize = 20.0
    public static let padding = 18.0
    /// Clear space between the orb and a reserved chrome rect.
    public static let chromeGap = 8.0
    /// Space between the orb and its card or pill.
    public static let partGap = 8.0
    /// The card and the pill keep this far inside the host.
    public static let partMargin = 8.0
    public static let cardMaxWidth = 260.0
    /// The tuck test grows the slot by this much, so a card edge near the
    /// orb counts.
    public static let tuckMargin = 8.0
    public static let untuckDelay: Duration = .milliseconds(400)
    public static let pillShowDelay: Duration = .milliseconds(150)

    /// The slot for `corner` in a container of `size` that touches no rect
    /// in `avoiding`. First the corner itself; then away from the horizontal
    /// edge (above the chrome in a bottom corner, below it in a top one), on
    /// the same vertical line; then, in a short host, beside the chrome. If
    /// nothing fits, the corner (the tuck rule still applies).
    public static func slotRect(
        for corner: VoiceCompanionCorner, in size: CGSize, avoiding: [CGRect] = []
    ) -> CGRect {
        let width = Double(size.width)
        let height = Double(size.height)
        let natural = CGRect(
            x: corner.isLeading ? padding : max(padding, width - slotSize - padding),
            y: corner.isTop ? padding : max(padding, height - slotSize - padding),
            width: slotSize, height: slotSize)
        let blocks = avoiding.filter { !$0.isEmpty && !$0.isNull }
            .map { $0.insetBy(dx: -chromeGap, dy: -chromeGap) }
        func isFree(_ rect: CGRect) -> Bool {
            Double(rect.minX) >= padding - 0.5 && Double(rect.maxX) <= width - padding + 0.5
                && Double(rect.minY) >= padding - 0.5 && Double(rect.maxY) <= height - padding + 0.5
                && !blocks.contains { $0.intersects(rect) }
        }
        if isFree(natural) { return natural }

        var stacked = natural
        for _ in 0..<blocks.count {
            guard let hit = blocks.first(where: { $0.intersects(stacked) }) else { break }
            stacked.origin.y = corner.isTop ? hit.maxY : hit.minY - slotSize
        }
        if isFree(stacked) { return stacked }

        var beside = natural
        for _ in 0..<blocks.count {
            guard let hit = blocks.first(where: { $0.intersects(beside) }) else { break }
            beside.origin.x = corner.isLeading ? hit.maxX : hit.minX - slotSize
        }
        if isFree(beside) { return beside }
        return natural
    }

    /// The corner whose quadrant holds `point` (the slot centre where a
    /// fling would end).
    public static func nearestCorner(to point: CGPoint, in size: CGSize) -> VoiceCompanionCorner {
        VoiceCompanionCorner(
            top: Double(point.y) < Double(size.height) / 2,
            leading: Double(point.x) < Double(size.width) / 2)
    }

    /// The corner after a drag of `slot` by `predicted` (SwiftUI's
    /// `predictedEndTranslation`).
    public static func corner(afterDragFrom slot: CGRect, predicted: CGSize, in size: CGSize)
        -> VoiceCompanionCorner
    {
        let centre = CGPoint(
            x: slot.midX + predicted.width, y: slot.midY + predicted.height)
        return nearestCorner(to: centre, in: size)
    }

    /// True while a board card drag is live and its pointer is over the orb.
    public static func shouldTuck(dragLive: Bool, pointer: CGPoint?, orbRect: CGRect) -> Bool {
        guard dragLive, let pointer, !orbRect.isEmpty else { return false }
        return orbRect.insetBy(dx: -tuckMargin, dy: -tuckMargin).contains(pointer)
    }

    public enum Side: Equatable, Sendable {
        case above, below, leading, trailing
    }

    /// The speech card: above the orb in a bottom corner (below it in a top
    /// one), its outer edge in line with the orb's; beside the orb, toward
    /// the centre, when the host is too short.
    public static func cardRect(
        orb: CGRect, card: CGSize, corner: VoiceCompanionCorner, in size: CGSize,
        avoiding: [CGRect] = []
    ) -> (rect: CGRect, side: Side) {
        let towardCentre: Side = corner.isLeading ? .trailing : .leading
        let order: [Side] =
            corner.isTop ? [.below, towardCentre, .above] : [.above, towardCentre, .below]
        return place(
            card, around: orb, order: order, in: size, avoiding: avoiding, edgeAligned: corner)
    }

    /// The control pill: toward the window centre on the orb's centre line,
    /// then above or below, then away. Never on the orb, never outside the
    /// host, and off the chrome and the card when it can be.
    public static func pillRect(
        orb: CGRect, pill: CGSize, corner: VoiceCompanionCorner, in size: CGSize,
        avoiding: [CGRect] = [], card: CGRect? = nil
    ) -> (rect: CGRect, side: Side) {
        let towardCentre: Side = corner.isLeading ? .trailing : .leading
        let away: Side = corner.isLeading ? .leading : .trailing
        let vertical: [Side] = corner.isTop ? [.below, .above] : [.above, .below]
        let card = card.flatMap { $0.isEmpty ? nil : $0 }
        return place(
            pill, around: orb, order: [towardCentre] + vertical + [away], in: size,
            avoiding: avoiding + (card.map { [$0] } ?? []), edgeAligned: nil)
    }

    /// The first side where `part` fits in the host, off the orb and off
    /// every rect in `avoiding`; else the first side in the host and off the
    /// orb; else kept inside the host on both axes.
    static func place(
        _ part: CGSize, around orb: CGRect, order: [Side], in size: CGSize,
        avoiding: [CGRect], edgeAligned: VoiceCompanionCorner?
    ) -> (rect: CGRect, side: Side) {
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: partMargin, dy: partMargin)
        let blocks = avoiding.filter { !$0.isEmpty && !$0.isNull }
        func stackedX() -> CGFloat {
            guard let corner = edgeAligned else { return orb.midX - part.width / 2 }
            return corner.isLeading ? orb.minX : orb.maxX - part.width
        }
        func candidate(_ side: Side) -> CGRect {
            let gap = partGap
            return switch side {
            case .leading:
                CGRect(
                    x: orb.minX - gap - part.width, y: orb.midY - part.height / 2,
                    width: part.width, height: part.height)
            case .trailing:
                CGRect(
                    x: orb.maxX + gap, y: orb.midY - part.height / 2, width: part.width,
                    height: part.height)
            case .above:
                CGRect(
                    x: stackedX(), y: orb.minY - gap - part.height, width: part.width,
                    height: part.height)
            case .below:
                CGRect(
                    x: stackedX(), y: orb.maxY + gap, width: part.width, height: part.height)
            }
        }
        // Slides only along the axis that cannot push the part onto the orb.
        func clamped(_ side: Side) -> CGRect {
            var rect = candidate(side)
            if side == .above || side == .below {
                rect.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
            } else {
                rect.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
            }
            return rect
        }
        func inside(_ rect: CGRect) -> Bool {
            rect.minX >= bounds.minX - 0.5 && rect.maxX <= bounds.maxX + 0.5
                && rect.minY >= bounds.minY - 0.5 && rect.maxY <= bounds.maxY + 0.5
        }
        for side in order {
            let rect = clamped(side)
            if inside(rect), !rect.intersects(orb), !blocks.contains(where: { $0.intersects(rect) })
            {
                return (rect, side)
            }
        }
        for side in order {
            let rect = clamped(side)
            if inside(rect), !rect.intersects(orb) { return (rect, side) }
        }
        let side = order.first ?? .above
        var last = candidate(side)
        last.origin.x = min(max(last.minX, bounds.minX), max(bounds.minX, bounds.maxX - last.width))
        last.origin.y = min(
            max(last.minY, bounds.minY), max(bounds.minY, bounds.maxY - last.height))
        return (last, side)
    }

    public static let cornerKeyPrefix = "voice.companion.corner."

    /// The `UserDefaults` key for one workspace's corner. The path is hashed
    /// (FNV-1a, stable across launches), so no path is stored in a key.
    public static func cornerKey(workspacePath: String?) -> String {
        guard let workspacePath, !workspacePath.isEmpty else { return cornerKeyPrefix + "none" }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in workspacePath.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return cornerKeyPrefix + String(hash, radix: 16)
    }
}

// MARK: Turn progress

/// Tool calls in the current delegation: done of total.
public nonisolated struct VoiceTurnProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int

    public init(done: Int = 0, total: Int = 0) {
        self.done = done
        self.total = total
    }

    /// "2/3"; nil before the first call.
    public var chip: String? { total > 0 ? "\(min(done, total))/\(total)" : nil }
}
