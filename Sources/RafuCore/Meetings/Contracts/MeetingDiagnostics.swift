import Foundation

// The meeting diagnostics contract. An event has no free text field: its
// fields are numbers, enums, ids, OSStatus and error codes, and a few short
// facts through `MeetingDiagnosticString` (device name, device UID, bundle
// id, error domain, version strings). A source-scan test keeps this file
// free of any other string type.

/// A permission state at Start.
public enum MeetingPermissionState: Hashable, Codable, Sendable, CaseIterable {
    case notDetermined
    case denied
    case granted
    case unknown
}

/// The facts of one audio device.
public struct MeetingAudioDeviceFacts: Hashable, Codable, Sendable {
    public var name: MeetingDiagnosticString
    public var uid: MeetingDiagnosticString
    /// `kAudioDevicePropertyTransportType` (a four-character code).
    public var transportType: UInt32
    public var nominalSampleRate: Double
    public var channelCount: Int

    public init(
        name: MeetingDiagnosticString, uid: MeetingDiagnosticString, transportType: UInt32,
        nominalSampleRate: Double, channelCount: Int
    ) {
        self.name = name
        self.uid = uid
        self.transportType = transportType
        self.nominalSampleRate = nominalSampleRate
        self.channelCount = channelCount
    }
}

/// The kind of microphone choice, without the device itself.
public enum MeetingMicrophoneChoiceKind: Hashable, Codable, Sendable, CaseIterable {
    case automatic
    case systemDefault
    case named
}

/// Why the recorder used the microphone it used.
public enum MeetingMicrophoneChoiceReason: Hashable, Codable, Sendable, CaseIterable {
    case userSelected
    case systemDefault
    /// Automatic chose the built-in microphone over a call-mode headset.
    case builtInOverCallHeadset
    /// The named device was missing; the recorder fell back.
    case namedDeviceMissing
}

/// The Core Audio call that a diagnostic event reports.
public enum MeetingCoreAudioCall: Hashable, Codable, Sendable, CaseIterable {
    case createProcessTap
    case destroyProcessTap
    case readTapFormat
    case createAggregateDevice
    case destroyAggregateDevice
    case readNominalSampleRate
    case createIOProc
    case destroyIOProc
    case startDevice
    case stopDevice
    case addPropertyListener
    case removePropertyListener
    case readDefaultInputDevice
    case readDefaultOutputDevice
    case setInputDevice
    case other
}

/// The format of the system-audio tap.
public struct MeetingTapFormat: Hashable, Codable, Sendable {
    public var sampleRate: Double
    public var channelCount: Int
    public var bitsPerChannel: Int
    public var isInterleaved: Bool

    public init(sampleRate: Double, channelCount: Int, bitsPerChannel: Int, isInterleaved: Bool) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitsPerChannel = bitsPerChannel
        self.isInterleaved = isInterleaved
    }
}

/// The counters of one track for one 10 s window. Audio callbacks only add
/// to atomic counters; a timer off the audio thread reads them.
public struct MeetingTrackFlowCounters: Hashable, Codable, Sendable {
    public var buffers: Int
    public var frames: Int
    public var silentBuffers: Int
    public var droppedBuffers: Int
    public var lateBuffers: Int
    public var peakLevelDBFS: Double
    public var meanLevelDBFS: Double
    public var converterErrors: Int

    public init(
        buffers: Int = 0, frames: Int = 0, silentBuffers: Int = 0, droppedBuffers: Int = 0,
        lateBuffers: Int = 0, peakLevelDBFS: Double = -160, meanLevelDBFS: Double = -160,
        converterErrors: Int = 0
    ) {
        self.buffers = buffers
        self.frames = frames
        self.silentBuffers = silentBuffers
        self.droppedBuffers = droppedBuffers
        self.lateBuffers = lateBuffers
        self.peakLevelDBFS = peakLevelDBFS
        self.meanLevelDBFS = meanLevelDBFS
        self.converterErrors = converterErrors
    }
}

/// The result of an audio journal recovery.
public enum MeetingJournalRecoveryResult: Hashable, Codable, Sendable, CaseIterable {
    case nothingToRecover
    case recovered
    case partlyRecovered
    case failed
}

/// Why a live text session restarted.
public enum MeetingLiveSessionRestartReason: Hashable, Codable, Sendable, CaseIterable {
    case engineError
    case routeChange
    case helperExited
    case resumed
}

/// The work a helper process does (`--mode`).
public enum MeetingHelperMode: Hashable, Codable, Sendable, CaseIterable {
    case liveText
    case finalText
    case speakers
}

/// Why the app restarted a helper.
public enum MeetingHelperRestartReason: Hashable, Codable, Sendable, CaseIterable {
    case crashed
    case unresponsive
    case memoryPressure
    case protocolError
}

/// Either kind of engine, for events that both kinds emit.
public enum MeetingAnyEngineID: Hashable, Codable, Sendable {
    case text(MeetingTextEngineID)
    case speaker(MeetingSpeakerEngineID)
}

/// The result of a model file check.
public enum MeetingChecksumResult: Hashable, Codable, Sendable, CaseIterable {
    case matched
    case mismatched
    case wrongSize
    case missingFile
}

/// The result of a model install.
public enum MeetingInstallResult: Hashable, Codable, Sendable, CaseIterable {
    case installed
    case removedAfterBadFile
    case cancelled
    case failed
}

/// The result of a library write.
public enum MeetingLibraryWriteResult: Hashable, Codable, Sendable, CaseIterable {
    case written
    case conflict
    case failed
}

/// What an export wrote (never where).
public enum MeetingExportKind: Hashable, Codable, Sendable, CaseIterable {
    case markdown
    case diagnostics
}

/// How a hidden meeting agent run ended.
public enum MeetingAgentRunOutcome: Hashable, Codable, Sendable, CaseIterable {
    case answered
    case notSignedIn
    case timedOut
    case cancelled
    case failed
}

/// The place in Rafu where an error reached a user message.
public enum MeetingErrorPlace: Hashable, Codable, Sendable, CaseIterable {
    case capture
    case recorder
    case journal
    case appleSpeech
    case helper
    case speakers
    case modelDownload
    case library
    case export
    case agent
    case diagnostics
}

/// One meeting diagnostic event. A closed enum: each case is one event of
/// the meeting diagnostics design; the package that owns the code emits it.
public enum MeetingDiagnosticEvent: Hashable, Codable, Sendable {
    // Header (diagnostics package, at the start of each file).
    case header(
        macOSVersion: MeetingDiagnosticString, macOSBuild: MeetingDiagnosticString,
        macModel: MeetingDiagnosticString, rafuVersion: MeetingDiagnosticString,
        rafuBuild: MeetingDiagnosticString, rafuVariant: MeetingDiagnosticString,
        timeZoneOffsetSeconds: Int)

    // Start (capture).
    case permissions(microphone: MeetingPermissionState, systemAudio: MeetingPermissionState)
    case devices(input: MeetingAudioDeviceFacts?, output: MeetingAudioDeviceFacts?)
    case microphoneChoice(kind: MeetingMicrophoneChoiceKind, reason: MeetingMicrophoneChoiceReason)
    case playingProcesses(bundleIDs: [MeetingDiagnosticString])

    // Core Audio (capture).
    case coreAudioCall(MeetingCoreAudioCall, status: Int32)
    case tapFormat(MeetingTapFormat)
    case aggregateDeviceRate(nominalSampleRate: Double)
    case sampleRateCorrected(from: Double, to: Double)

    // Flow (capture).
    case firstBuffer(track: MeetingTrack, frames: Int)
    case trackFlow(track: MeetingTrack, counters: MeetingTrackFlowCounters)
    case deviceChanged(
        track: MeetingTrack, old: MeetingAudioDeviceFacts?, new: MeetingAudioDeviceFacts?)
    case recordingPaused
    case recordingResumed
    case recordingStopped(recordedSeconds: Double)
    case journalSync(bytes: Int64, ok: Bool)
    case journalRecovery(result: MeetingJournalRecoveryResult, recoveredSeconds: Double)

    // Text engine (Apple speech package; speech worker package).
    case textEngineLoaded(
        engine: MeetingTextEngineID, model: MeetingModelID?,
        modelRevision: MeetingDiagnosticString?, loadMilliseconds: Int, isCold: Bool)
    case firstLiveText(engine: MeetingTextEngineID, track: MeetingTrack, milliseconds: Int)
    case liveTextWindow(
        engine: MeetingTextEngineID, track: MeetingTrack, delayMedianMilliseconds: Int,
        delayP95Milliseconds: Int, words: Int)
    case liveSessionRestarted(
        engine: MeetingTextEngineID, track: MeetingTrack, reason: MeetingLiveSessionRestartReason)
    case finalTextDone(
        engine: MeetingTextEngineID, track: MeetingTrack, audioSeconds: Double,
        wallSeconds: Double)
    case engineError(engine: MeetingAnyEngineID, domain: MeetingDiagnosticString, code: Int)

    // Helper (speech worker package).
    case helperStarted(mode: MeetingHelperMode, engine: MeetingAnyEngineID)
    case helperExited(
        mode: MeetingHelperMode, exitCode: Int32?, signal: Int32?, wallSeconds: Double,
        peakFootprintBytes: Int64?)
    case helperRestarted(mode: MeetingHelperMode, reason: MeetingHelperRestartReason)

    // Speakers (speech worker package).
    case speakersDone(
        engine: MeetingSpeakerEngineID, modelRevision: MeetingDiagnosticString?,
        audioSeconds: Double, wallSeconds: Double, speakerCount: Int, segmentCount: Int)

    // Models (catalog package).
    case modelDownloadStarted(model: MeetingModelID, expectedBytes: Int64)
    case modelDownloadFinished(
        model: MeetingModelID, bytes: Int64, wallSeconds: Double,
        checksum: MeetingChecksumResult, install: MeetingInstallResult)

    // Library.
    case libraryWrite(result: MeetingLibraryWriteResult, code: Int?)
    case libraryIndexRebuilt(meetings: Int, wallMilliseconds: Int)
    case exportDone(kind: MeetingExportKind)

    // Hidden agent (never the prompt, the question or the reply).
    case agentRun(
        cli: MeetingAgentCLI, cliVersion: MeetingDiagnosticString?, exitCode: Int32?,
        wallSeconds: Double, replyBytes: Int, citations: Int, failedCitations: Int,
        outcome: MeetingAgentRunOutcome)

    // Errors that reach a user message.
    case userFacingError(place: MeetingErrorPlace, domain: MeetingDiagnosticString, code: Int)
}

/// Records meeting diagnostics. `record` is safe to call from each thread
/// except an audio callback and never blocks: an implementation puts the
/// event on a bounded queue (drop the oldest, count the drops).
public protocol MeetingDiagnosticsRecording: Sendable {
    func record(_ event: MeetingDiagnosticEvent, meeting: MeetingID?)
}

/// The default recorder: it drops each event. Each package can call
/// `record` from its first commit.
public struct NoopMeetingDiagnostics: MeetingDiagnosticsRecording {
    public init() {}
    public func record(_ event: MeetingDiagnosticEvent, meeting: MeetingID?) {}
}
