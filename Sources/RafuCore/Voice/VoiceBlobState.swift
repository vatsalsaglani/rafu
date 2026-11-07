import Foundation

/// What the voice blob shows. `paused` is an open session with the microphone
/// off: after a push-to-talk turn, or after the latched check-in went unanswered.
public nonisolated enum VoiceBlobState: Equatable, Sendable {
    case idle
    case connecting
    case listeningHeld
    case listeningLatched
    case thinking
    case speaking
    case checkIn
    case paused
    case needsConfirm
    case error(String)

    /// A short word for the status bar.
    public var word: String {
        switch self {
        case .idle: "Rafu"
        case .connecting: "Connecting"
        case .listeningHeld, .listeningLatched: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .checkIn: "Still there?"
        case .paused: "Paused"
        case .needsConfirm: "Confirm"
        case .error: "Voice off"
        }
    }

    public var symbol: String {
        switch self {
        case .idle: "waveform"
        case .connecting: "antenna.radiowaves.left.and.right"
        case .listeningHeld, .listeningLatched: "mic.fill"
        case .thinking: "ellipsis"
        case .speaking: "speaker.wave.2.fill"
        case .checkIn: "questionmark.bubble"
        case .paused: "pause.fill"
        case .needsConfirm: "hand.raised"
        case .error: "exclamationmark.triangle"
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .idle: "Rafu voice is off"
        case .connecting: "Rafu voice is connecting"
        case .listeningHeld: "Rafu is listening while you hold the key"
        case .listeningLatched: "Rafu is listening; the microphone stays open"
        case .thinking: "Rafu is working on your request"
        case .speaking: "Rafu is speaking"
        case .checkIn: "Rafu asks whether to keep listening"
        case .paused: "Rafu voice is paused; the microphone is off"
        case .needsConfirm: "Rafu needs your confirmation"
        case .error(let reason): "Rafu voice stopped: \(reason)"
        }
    }

    public var isOpen: Bool {
        switch self {
        case .idle, .error: false
        default: true
        }
    }
}

/// How the microphone is held. It is separate from the blob state because a
/// latched session stays latched while Rafu thinks or speaks.
public nonisolated enum VoiceMicMode: Equatable, Sendable {
    case off
    case held
    case latched
}

public nonisolated enum VoiceBlobEvent: Equatable, Sendable {
    case holdBegan
    case holdEnded
    case latchToggled
    case connected
    case delegationStarted
    case replyStarted
    case replyEnded
    case speechDetected
    case checkIn
    case pause
    case needsConfirm
    case confirmResolved
    case failed(String)
    case closed
    /// Clears an error; the blob returns to idle.
    case reset
}

/// The pure transition table. An event that does not apply is a no-op.
public nonisolated struct VoiceBlobMachine: Equatable, Sendable {
    public private(set) var state: VoiceBlobState = .idle
    public private(set) var mic: VoiceMicMode = .off

    public init() {}

    /// True while audio may be captured: the key is held or the session is
    /// latched, and the session is not failed. The blob shows it in every
    /// such state (a ring around the glyph).
    public var isMicOpen: Bool { mic != .off && state.isOpen }

    private var listening: VoiceBlobState {
        switch mic {
        case .held: .listeningHeld
        case .latched: .listeningLatched
        case .off: .paused
        }
    }

    public mutating func apply(_ event: VoiceBlobEvent) {
        switch event {
        case .holdBegan:
            guard mic != .latched else { return }
            mic = .held
            switch state {
            case .idle, .error: state = .connecting
            case .connecting, .needsConfirm: break
            default: state = .listeningHeld
            }
        case .holdEnded:
            guard mic == .held else { return }
            mic = .off
            if state == .listeningHeld { state = .thinking }
        case .latchToggled:
            if mic == .latched {
                mic = .off
                switch state {
                case .listeningLatched, .checkIn: state = .paused
                default: break
                }
            } else {
                mic = .latched
                switch state {
                case .idle, .error: state = .connecting
                case .connecting, .needsConfirm, .thinking, .speaking: break
                default: state = .listeningLatched
                }
            }
        case .connected:
            guard state == .connecting else { return }
            state = listening
        case .delegationStarted:
            switch state {
            case .listeningLatched, .paused, .speaking, .checkIn: state = .thinking
            default: break
            }
        case .replyStarted:
            // A check-in's own spoken prompt keeps the check-in glyph.
            switch state {
            case .thinking, .paused, .listeningLatched: state = .speaking
            default: break
            }
        case .replyEnded:
            guard state == .speaking || state == .thinking else { return }
            state = listening
        case .speechDetected:
            if state == .checkIn { state = .listeningLatched }
        case .checkIn:
            guard mic == .latched, state == .listeningLatched || state == .speaking else { return }
            state = .checkIn
        case .pause:
            guard mic == .latched else { return }
            mic = .off
            state = .paused
        case .needsConfirm:
            guard state.isOpen, state != .connecting else { return }
            state = .needsConfirm
        case .confirmResolved:
            guard state == .needsConfirm else { return }
            state = .thinking
        case .failed(let reason):
            mic = .off
            state = .error(reason)
        case .closed:
            mic = .off
            if state.isOpen { state = .idle }
        case .reset:
            mic = .off
            state = .idle
        }
    }
}
