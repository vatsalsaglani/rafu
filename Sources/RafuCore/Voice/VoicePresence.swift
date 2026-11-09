import CoreGraphics
import Foundation

// The voice companion's pure rules (voice-presence.md): the orb's pose per
// state, the level smoother, the caption window, what the speech card shows
// and when it hides, and where the companion sits. No view, no clock, no I/O.

// MARK: Orb pose

/// How the orb looks in one state. The view turns this into pixels; the look
/// itself may change later without touching these rules.
public nonisolated struct VoiceOrbPose: Equatable, Sendable {
    public enum Eyes: Equatable, Sendable {
        case closed, half, open
    }

    /// What moves the lobes.
    public enum Driver: Equatable, Sendable {
        /// Nothing: one static frame.
        case still
        /// The microphone level.
        case input
        /// Rafu's output level.
        case output
        /// Thinking: the lobes turn slowly with time.
        case turning
    }

    /// Size factor of the orb in its slot (1 = full).
    public var scale: Double = 1
    /// 0…1 multiplier for the lobes' light.
    public var brightness: Double = 1
    /// 0 = full colour, 1 = grey.
    public var desaturation: Double = 0
    public var eyes: Eyes = .closed
    public var eyesLookUp = false
    /// 0 hides the ring.
    public var ringOpacity: Double = 0
    public var ringWidth: Double = 1
    /// 0…0.15: how far the lobes shift toward the light tone (speaking).
    public var lightShift: Double = 0
    /// A ripple ring leaves the orb (connecting: repeating; check-in: once).
    public var ripple: Ripple = .none
    public var driver: Driver = .still

    public enum Ripple: Equatable, Sendable {
        case none, once, repeating
    }

    public init() {}

    /// The pose for `state`. `micOpen` and `latched` come from the session;
    /// Increase Contrast makes every shown ring at least 2 pt.
    public static func pose(
        for state: VoiceBlobState, micOpen: Bool, latched: Bool, increaseContrast: Bool = false
    ) -> VoiceOrbPose {
        var pose = VoiceOrbPose()
        switch state {
        case .idle:
            pose.brightness = 0.5
        case .connecting:
            pose.scale = 0.7
            pose.brightness = 0.5
            pose.ripple = .repeating
        case .listeningHeld:
            pose.eyes = .open
            pose.eyesLookUp = true
            pose.ringOpacity = 0.6
            pose.ringWidth = 1
            pose.driver = .input
        case .listeningLatched:
            pose.eyes = .open
            pose.ringOpacity = 0.6
            pose.ringWidth = 2
            pose.driver = .input
        case .thinking:
            pose.brightness = 0.8
            pose.eyes = .half
            pose.ringOpacity = 0.3
            pose.ringWidth = latched ? 2 : 1
            pose.driver = .turning
        case .speaking:
            pose.lightShift = 0.15
            pose.ringOpacity = micOpen ? 0.6 : 0
            pose.ringWidth = latched ? 2 : 1
            pose.driver = .output
        case .checkIn:
            pose.eyes = .open
            pose.eyesLookUp = true
            pose.ringOpacity = 0.6
            pose.ringWidth = 2
            pose.ripple = .once
        // The lobes stay still while Rafu waits for an answer.
        case .paused:
            pose.scale = 0.8
            pose.desaturation = 0.4
        case .needsConfirm:
            pose.eyes = .open
            pose.ringOpacity = 1
            pose.ringWidth = 2
        case .error:
            pose.brightness = 0.4
            pose.desaturation = 1
        }
        if increaseContrast, pose.ringOpacity > 0 {
            pose.ringWidth = max(2, pose.ringWidth)
            pose.ringOpacity = max(0.8, pose.ringOpacity)
        }
        return pose
    }
}

// MARK: Level smoothing

/// Turns raw audio levels into the orb's shown level and lobe phase. One
/// `step` per sampler tick (20 Hz). Silence never moves the lobes: the phase
/// advances only with level, except while turning (Thinking).
public nonisolated struct VoiceLevelSmoother: Equatable, Sendable {
    /// The fall rate per tick: `shown = max(raw, shown × decay)`.
    public static let decay = 0.72
    /// Smaller changes are not written, so the view does not redraw.
    public static let writeThreshold = 0.02
    /// Thinking: 0.1 turn per second at 20 Hz.
    public static let turnPerTick = 2 * Double.pi * 0.1 / 20
    /// Lobe travel per tick at full level.
    public static let phasePerLevel = 0.05
    /// Ticks of one connecting ripple (1.2 s at 20 Hz).
    public static let rippleTicks = 24

    public private(set) var shown = 0.0
    public private(set) var phase = 0.0
    /// 0…1 progress of the ripple ring; 0 when no ripple shows.
    public private(set) var ripple = 0.0
    private var rippleTick = 0
    private var rippleDone = false
    /// The values last handed to the view.
    public private(set) var written = Snapshot()

    public struct Snapshot: Equatable, Sendable {
        public var level = 0.0
        public var phase = 0.0
        public var ripple = 0.0
        public init(level: Double = 0, phase: Double = 0, ripple: Double = 0) {
            self.level = level
            self.phase = phase
            self.ripple = ripple
        }
    }

    public init() {}

    /// One tick. Returns the snapshot to write, or nil when the change is too
    /// small to draw.
    public mutating func step(raw: Double, pose: VoiceOrbPose) -> Snapshot? {
        let clamped = min(1, max(0, raw.isFinite ? raw : 0))
        switch pose.driver {
        case .input, .output:
            shown = max(clamped, shown * Self.decay)
            if shown < 0.005 { shown = 0 }
            phase += shown * Self.phasePerLevel
        case .turning:
            shown = max(0.25, shown * Self.decay)
            phase += Self.turnPerTick
        case .still:
            shown = 0
        }
        stepRipple(pose.ripple)
        let next = Snapshot(level: shown, phase: phase, ripple: ripple)
        let levelMoved = abs(next.level - written.level) > Self.writeThreshold
        let turning = pose.driver == .turning
        let rippleMoved = next.ripple != written.ripple
        guard levelMoved || turning || rippleMoved || (next.level == 0 && written.level != 0)
        else { return nil }
        written = next
        return next
    }

    /// Back to rest: level 0, no ripple. The phase is kept so the next
    /// motion continues from where the lobes stopped.
    public mutating func reset() {
        shown = 0
        ripple = 0
        rippleTick = 0
        rippleDone = false
        written = Snapshot(level: 0, phase: phase, ripple: 0)
    }

    private mutating func stepRipple(_ kind: VoiceOrbPose.Ripple) {
        switch kind {
        case .none:
            rippleTick = 0
            rippleDone = false
            ripple = 0
        case .repeating:
            rippleTick = (rippleTick + 1) % Self.rippleTicks
            ripple = Double(rippleTick) / Double(Self.rippleTicks)
        case .once:
            guard !rippleDone else {
                ripple = 0
                return
            }
            rippleTick += 1
            if rippleTick >= Self.rippleTicks {
                rippleDone = true
                ripple = 0
            } else {
                ripple = Double(rippleTick) / Double(Self.rippleTicks)
            }
        }
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
public nonisolated enum VoiceCompanionPlacement {
    /// The slot the orb lives in; the orb grows to it on hover.
    public static let slotSize = 96.0
    public static let orbSize = 72.0
    public static let hoverOrbSize = 96.0
    public static let idleOrbSize = 40.0
    public static let tuckedOrbSize = 20.0
    public static let padding = 18.0
    public static let cardMaxWidth = 260.0
    public static let cardGap = 6.0
    /// The tuck test grows the slot by this much, so a card edge near the
    /// orb counts.
    public static let tuckMargin = 8.0
    public static let untuckDelay: Duration = .milliseconds(400)
    public static let pillShowDelay: Duration = .milliseconds(150)

    /// The slot's top-left corner for `corner` in a container of `size`.
    public static func slotOrigin(for corner: VoiceCompanionCorner, in size: CGSize) -> CGPoint {
        let x = corner.isLeading ? padding : max(padding, Double(size.width) - slotSize - padding)
        let y = corner.isTop ? padding : max(padding, Double(size.height) - slotSize - padding)
        return CGPoint(x: x, y: y)
    }

    public static func slotRect(for corner: VoiceCompanionCorner, in size: CGSize) -> CGRect {
        CGRect(
            origin: slotOrigin(for: corner, in: size),
            size: CGSize(width: slotSize, height: slotSize))
    }

    /// The corner whose quadrant holds `point` (the slot centre where a
    /// fling would end).
    public static func nearestCorner(to point: CGPoint, in size: CGSize) -> VoiceCompanionCorner {
        VoiceCompanionCorner(
            top: Double(point.y) < Double(size.height) / 2,
            leading: Double(point.x) < Double(size.width) / 2)
    }

    /// The corner after a drag of the slot from `corner` by `predicted`
    /// (SwiftUI's `predictedEndTranslation`).
    public static func corner(
        afterDragFrom corner: VoiceCompanionCorner, predicted: CGSize, in size: CGSize
    ) -> VoiceCompanionCorner {
        let origin = slotOrigin(for: corner, in: size)
        let centre = CGPoint(
            x: Double(origin.x) + slotSize / 2 + Double(predicted.width),
            y: Double(origin.y) + slotSize / 2 + Double(predicted.height))
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

    /// The card: above the orb in a bottom corner; beside it, toward the
    /// window centre, in a top corner.
    public static func cardSide(for corner: VoiceCompanionCorner) -> Side {
        if !corner.isTop { return .above }
        return corner.isLeading ? .trailing : .leading
    }

    /// The pill: beside the orb toward the centre in a bottom corner; below
    /// it in a top corner (the card is beside it there).
    public static func pillSide(for corner: VoiceCompanionCorner) -> Side {
        if corner.isTop { return .below }
        return corner.isLeading ? .trailing : .leading
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
