import Foundation

// The seams between the recorder and the audio hardware. The app implements
// them with Core Audio and AVFoundation; tests use fakes, so no test opens a
// real device or asks for a permission.

/// One block of captured audio, already converted to `MeetingAudioFormat`
/// (16 kHz mono Int16) off the audio thread.
public struct MeetingCapturedBlock: Hashable, Sendable {
    /// Host time (`mach_absolute_time` ticks) of the first sample.
    public var hostTime: UInt64
    /// Little-endian Int16 samples.
    public var samples: [Int16]
    /// The device rate the block came from, before conversion.
    public var sourceSampleRate: Double

    public init(hostTime: UInt64, samples: [Int16], sourceSampleRate: Double) {
        self.hostTime = hostTime
        self.samples = samples
        self.sourceSampleRate = sourceSampleRate
    }
}

/// What a running source reports beside its audio.
public enum MeetingAudioSourceEvent: Hashable, Sendable {
    /// The device changed or was lost; the source stopped itself. The
    /// recorder records a gap and calls `start` again.
    case interrupted(old: MeetingAudioDeviceFacts?)
}

/// The facts of a started source, for the start view and diagnostics.
public struct MeetingAudioSourceFacts: Hashable, Sendable {
    public var device: MeetingAudioDeviceFacts?
    /// The rate the source converts from (the corrected rate for the tap).
    public var captureSampleRate: Double
    /// Microphone only: the choice and its reason.
    public var microphone: MeetingMicrophoneResolution?
    /// Call audio only: the output is the built-in speakers.
    public var outputIsBuiltInSpeakers: Bool

    public init(
        device: MeetingAudioDeviceFacts?, captureSampleRate: Double,
        microphone: MeetingMicrophoneResolution? = nil, outputIsBuiltInSpeakers: Bool = false
    ) {
        self.device = device
        self.captureSampleRate = captureSampleRate
        self.microphone = microphone
        self.outputIsBuiltInSpeakers = outputIsBuiltInSpeakers
    }
}

/// One run of a source, from `start` to `stop` or an interruption. Both
/// streams finish when the run ends.
public struct MeetingAudioSourceRun: Sendable {
    public var facts: MeetingAudioSourceFacts
    public var blocks: AsyncStream<MeetingCapturedBlock>
    public var events: AsyncStream<MeetingAudioSourceEvent>

    public init(
        facts: MeetingAudioSourceFacts, blocks: AsyncStream<MeetingCapturedBlock>,
        events: AsyncStream<MeetingAudioSourceEvent>
    ) {
        self.facts = facts
        self.blocks = blocks
        self.events = events
    }
}

/// Counts that only the audio callback knows, since the last call.
public struct MeetingCallbackCounters: Hashable, Sendable {
    public var buffers: Int
    public var frames: Int
    public var droppedBuffers: Int
    public var converterErrors: Int

    public init(
        buffers: Int = 0, frames: Int = 0, droppedBuffers: Int = 0, converterErrors: Int = 0
    ) {
        self.buffers = buffers
        self.frames = frames
        self.droppedBuffers = droppedBuffers
        self.converterErrors = converterErrors
    }
}

/// Why a source could not start.
public enum MeetingAudioSourceError: Error, Hashable, Sendable {
    case permissionDenied
    case noDevice
    /// A Core Audio or AVFoundation call failed with this status.
    case failed(call: MeetingCoreAudioCall, status: Int32)
}

/// One track's audio: the microphone ("Me") or the call audio ("Them").
public protocol MeetingAudioSource: Sendable {
    var track: MeetingTrack { get }
    /// Opens the device and starts a run. Diagnostics of Core Audio calls go
    /// to `diagnostics` with `meeting`.
    func start(meeting: MeetingID?, diagnostics: any MeetingDiagnosticsRecording) async throws
        -> MeetingAudioSourceRun
    /// Ends the current run; its streams finish.
    func stop() async
    /// The callback counters since the last call; they start again at zero.
    func takeCallbackCounters() async -> MeetingCallbackCounters
}

/// The permission checks at each Start.
public protocol MeetingPermissionChecking: Sendable {
    func microphoneState() async -> MeetingPermissionState
    /// Shows the system prompt when the state is not determined. Returns
    /// true when the microphone is allowed.
    func requestMicrophone() async -> Bool
    /// The system-audio grant. macOS has no public status call for it, so
    /// the app returns `.unknown`; a denial shows as silent buffers.
    func systemAudioState() async -> MeetingPermissionState
}

/// The processes that play sound now (bundle ids), without Rafu itself.
public protocol MeetingPlayingProcessListing: Sendable {
    func playingBundleIDs() async -> [String]
}

/// The host clock, injected so tests control time.
public protocol MeetingHostClock: Sendable {
    var timebase: MeetingHostTimebase { get }
    /// The current host time (`mach_absolute_time`).
    func now() -> UInt64
}

/// The real host clock.
public struct MachMeetingHostClock: MeetingHostClock {
    public init() {}
    public var timebase: MeetingHostTimebase { .current }
    public func now() -> UInt64 { mach_absolute_time() }
}
