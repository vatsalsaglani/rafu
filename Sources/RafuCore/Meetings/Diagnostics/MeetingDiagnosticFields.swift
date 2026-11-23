import Foundation

// Flattens a typed `MeetingDiagnosticEvent` into an event name and a flat
// list of fields. The JSON line encoder and the `Logger` mirror both read
// this one description, so the two outputs can never differ in what they
// hold. The switch below has no `default`: a new event case does not
// compile until it is described here.

/// One field value. `label` is a fixed word that the code chose (an enum
/// case name); `text` came from a `MeetingDiagnosticString` (a device name,
/// a bundle id) and is the only kind that the `Logger` mirror marks private.
public enum MeetingDiagnosticValue: Hashable, Sendable {
    case integer(Int64)
    case number(Double)
    case flag(Bool)
    case label(String)
    case text(String)
    case texts([String])
}

/// One `key = value` pair of an event.
public struct MeetingDiagnosticField: Hashable, Sendable {
    public var key: String
    public var value: MeetingDiagnosticValue

    public init(_ key: String, _ value: MeetingDiagnosticValue) {
        self.key = key
        self.value = value
    }
}

/// The name and fields of one event.
public struct MeetingDiagnosticDescription: Hashable, Sendable {
    public var name: String
    public var fields: [MeetingDiagnosticField]

    /// The keys that a line holds besides the event fields.
    public static let reservedKeys: Set<String> = ["t", "clock", "event", "dropped"]

    public init(name: String, fields: [MeetingDiagnosticField]) {
        self.name = name
        self.fields = fields
    }

    /// The text that replaces a text value that looks like a path or a URL.
    public static let removedPathText = "[path removed]"

    /// A text value with a path or a URL replaced, so that a careless caller
    /// cannot write a file location into the file or the log. Both outputs
    /// read the description, so this one place covers both.
    static func scrubbed(_ value: String) -> String {
        if value.hasPrefix("/") || value.hasPrefix("~") || value.lowercased().hasPrefix("file:") {
            return removedPathText
        }
        return value
    }
}

extension MeetingDiagnosticEvent {
    /// The event name (the case name) and its flat fields.
    public var diagnosticDescription: MeetingDiagnosticDescription {
        var fields: [MeetingDiagnosticField] = []
        let name: String
        switch self {
        case .header(
            let macOSVersion, let macOSBuild, let macModel, let rafuVersion, let rafuBuild,
            let rafuVariant, let timeZoneOffsetSeconds):
            name = "header"
            fields = [
                .text("macOSVersion", macOSVersion), .text("macOSBuild", macOSBuild),
                .text("macModel", macModel), .text("rafuVersion", rafuVersion),
                .text("rafuBuild", rafuBuild), .text("rafuVariant", rafuVariant),
                .int("timeZoneOffsetSeconds", timeZoneOffsetSeconds),
            ]
        case .permissions(let microphone, let systemAudio):
            name = "permissions"
            fields = [.word("microphone", microphone), .word("systemAudio", systemAudio)]
        case .devices(let input, let output):
            name = "devices"
            fields = Self.deviceFields("input", input) + Self.deviceFields("output", output)
        case .microphoneChoice(let kind, let reason):
            name = "microphoneChoice"
            fields = [.word("kind", kind), .word("reason", reason)]
        case .playingProcesses(let bundleIDs):
            name = "playingProcesses"
            fields = [
                .int("count", bundleIDs.count),
                MeetingDiagnosticField(
                    "bundleIDs",
                    .texts(bundleIDs.map { MeetingDiagnosticDescription.scrubbed($0.value) })),
            ]
        case .coreAudioCall(let call, let status):
            name = "coreAudioCall"
            fields = [.word("call", call), .int("status", Int(status))]
        case .tapFormat(let format):
            name = "tapFormat"
            fields = [
                .number("sampleRate", format.sampleRate), .int("channels", format.channelCount),
                .int("bits", format.bitsPerChannel), .flag("interleaved", format.isInterleaved),
            ]
        case .aggregateDeviceRate(let rate):
            name = "aggregateDeviceRate"
            fields = [.number("nominalSampleRate", rate)]
        case .sampleRateCorrected(let from, let to):
            name = "sampleRateCorrected"
            fields = [.number("from", from), .number("to", to)]
        case .microphoneFormat(let format, let isFloat32, let nominalSampleRate):
            name = "microphoneFormat"
            fields = [
                .number("sampleRate", format.sampleRate), .int("channels", format.channelCount),
                .int("bits", format.bitsPerChannel), .flag("interleaved", format.isInterleaved),
                .flag("float32", isFloat32), .number("nominalSampleRate", nominalSampleRate),
            ]
        case .firstBuffer(let track, let frames):
            name = "firstBuffer"
            fields = [.track(track), .int("frames", frames)]
        case .trackFlow(let track, let counters):
            name = "trackFlow"
            fields = [
                .track(track), .int("buffers", counters.buffers),
                .int("frames", counters.frames), .int("silentBuffers", counters.silentBuffers),
                .int("droppedBuffers", counters.droppedBuffers),
                .int("lateBuffers", counters.lateBuffers),
                .number("peakDBFS", counters.peakLevelDBFS),
                .number("meanDBFS", counters.meanLevelDBFS),
                .int("converterErrors", counters.converterErrors),
            ]
        case .deviceChanged(let track, let old, let new):
            name = "deviceChanged"
            fields =
                [.track(track)] + Self.deviceFields("old", old) + Self.deviceFields("new", new)
        case .recordingPaused:
            name = "recordingPaused"
        case .recordingResumed:
            name = "recordingResumed"
        case .recordingStopped(let recordedSeconds):
            name = "recordingStopped"
            fields = [.number("recordedSeconds", recordedSeconds)]
        case .journalSync(let bytes, let ok):
            name = "journalSync"
            fields = [MeetingDiagnosticField("bytes", .integer(bytes)), .flag("ok", ok)]
        case .journalRecovery(let result, let recoveredSeconds):
            name = "journalRecovery"
            fields = [.word("result", result), .number("recoveredSeconds", recoveredSeconds)]
        case .textEngineLoaded(
            let engine, let model, let modelRevision, let loadMilliseconds, let isCold):
            name = "textEngineLoaded"
            fields = [
                MeetingDiagnosticField("engine", .label(engine.rawValue)),
                .int("loadMilliseconds", loadMilliseconds), .flag("cold", isCold),
            ]
            if let model { fields.append(.label("model", model.rawValue)) }
            if let modelRevision { fields.append(.text("modelRevision", modelRevision)) }
        case .firstLiveText(let engine, let track, let milliseconds):
            name = "firstLiveText"
            fields = [.label("engine", engine.rawValue), .track(track), .int("ms", milliseconds)]
        case .liveTextWindow(
            let engine, let track, let delayMedianMilliseconds, let delayP95Milliseconds,
            let words):
            name = "liveTextWindow"
            fields = [
                .label("engine", engine.rawValue), .track(track),
                .int("delayMedianMs", delayMedianMilliseconds),
                .int("delayP95Ms", delayP95Milliseconds), .int("words", words),
            ]
        case .liveSessionRestarted(let engine, let track, let reason):
            name = "liveSessionRestarted"
            fields = [.label("engine", engine.rawValue), .track(track), .word("reason", reason)]
        case .finalTextDone(let engine, let track, let audioSeconds, let wallSeconds):
            name = "finalTextDone"
            fields = [
                .label("engine", engine.rawValue), .track(track),
                .number("audioSeconds", audioSeconds), .number("wallSeconds", wallSeconds),
            ]
        case .engineError(let engine, let domain, let code):
            name = "engineError"
            fields = [
                .label("engine", Self.engineLabel(engine)), .text("domain", domain),
                .int("code", code),
            ]
        case .helperStarted(let mode, let engine):
            name = "helperStarted"
            fields = [.word("mode", mode), .label("engine", Self.engineLabel(engine))]
        case .helperExited(
            let mode, let exitCode, let signal, let wallSeconds, let peakFootprintBytes):
            name = "helperExited"
            fields = [.word("mode", mode), .number("wallSeconds", wallSeconds)]
            if let exitCode { fields.append(.int("exitCode", Int(exitCode))) }
            if let signal { fields.append(.int("signal", Int(signal))) }
            if let peakFootprintBytes {
                fields.append(
                    MeetingDiagnosticField("peakFootprintBytes", .integer(peakFootprintBytes)))
            }
        case .helperRestarted(let mode, let reason):
            name = "helperRestarted"
            fields = [.word("mode", mode), .word("reason", reason)]
        case .speakersDone(
            let engine, let modelRevision, let audioSeconds, let wallSeconds,
            let speakerCount, let segmentCount):
            name = "speakersDone"
            fields = [
                .label("engine", engine.rawValue), .number("audioSeconds", audioSeconds),
                .number("wallSeconds", wallSeconds), .int("speakers", speakerCount),
                .int("segments", segmentCount),
            ]
            if let modelRevision { fields.append(.text("modelRevision", modelRevision)) }
        case .modelDownloadStarted(let model, let expectedBytes):
            name = "modelDownloadStarted"
            fields = [
                .label("model", model.rawValue),
                MeetingDiagnosticField("expectedBytes", .integer(expectedBytes)),
            ]
        case .modelDownloadFinished(
            let model, let bytes, let wallSeconds, let checksum, let install):
            name = "modelDownloadFinished"
            fields = [
                .label("model", model.rawValue),
                MeetingDiagnosticField("bytes", .integer(bytes)),
                .number("wallSeconds", wallSeconds), .word("checksum", checksum),
                .word("install", install),
            ]
        case .libraryWrite(let result, let code):
            name = "libraryWrite"
            fields = [.word("result", result)]
            if let code { fields.append(.int("code", code)) }
        case .libraryIndexRebuilt(let meetings, let wallMilliseconds):
            name = "libraryIndexRebuilt"
            fields = [.int("meetings", meetings), .int("wallMs", wallMilliseconds)]
        case .exportDone(let kind):
            name = "exportDone"
            fields = [.word("kind", kind)]
        case .agentRun(
            let cli, let cliVersion, let exitCode, let wallSeconds, let replyBytes,
            let citations, let failedCitations, let outcome):
            name = "agentRun"
            fields = [
                .label("cli", cli.rawValue), .number("wallSeconds", wallSeconds),
                .int("replyBytes", replyBytes), .int("citations", citations),
                .int("failedCitations", failedCitations), .word("outcome", outcome),
            ]
            if let cliVersion { fields.append(.text("cliVersion", cliVersion)) }
            if let exitCode { fields.append(.int("exitCode", Int(exitCode))) }
        case .userFacingError(let place, let domain, let code):
            name = "userFacingError"
            fields = [.word("place", place), .text("domain", domain), .int("code", code)]
        }
        return MeetingDiagnosticDescription(name: name, fields: fields)
    }

    private static func engineLabel(_ engine: MeetingAnyEngineID) -> String {
        switch engine {
        case .text(let id): "text:\(id.rawValue)"
        case .speaker(let id): "speaker:\(id.rawValue)"
        }
    }

    /// `prefix` alone is `none` when the device is missing; else the facts
    /// of the device as `prefix.name`, `prefix.uid`, and so on.
    private static func deviceFields(
        _ prefix: String, _ device: MeetingAudioDeviceFacts?
    ) -> [MeetingDiagnosticField] {
        guard let device else { return [.label(prefix, "none")] }
        return [
            .text("\(prefix).name", device.name), .text("\(prefix).uid", device.uid),
            MeetingDiagnosticField(
                "\(prefix).transport", .label(fourCharacterCode(device.transportType))),
            .number("\(prefix).rate", device.nominalSampleRate),
            .int("\(prefix).channels", device.channelCount),
        ]
    }

    /// A four-character code as text (`bltn`), or hex when it is not printable.
    static func fourCharacterCode(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return String(decoding: bytes, as: UTF8.self)
        }
        return "0x" + String(code, radix: 16, uppercase: true)
    }
}

extension MeetingDiagnosticField {
    fileprivate static func int(_ key: String, _ value: Int) -> MeetingDiagnosticField {
        MeetingDiagnosticField(key, .integer(Int64(value)))
    }

    fileprivate static func number(_ key: String, _ value: Double) -> MeetingDiagnosticField {
        MeetingDiagnosticField(key, .number(value))
    }

    fileprivate static func flag(_ key: String, _ value: Bool) -> MeetingDiagnosticField {
        MeetingDiagnosticField(key, .flag(value))
    }

    fileprivate static func label(_ key: String, _ value: String) -> MeetingDiagnosticField {
        MeetingDiagnosticField(key, .label(value))
    }

    fileprivate static func text(_ key: String, _ value: MeetingDiagnosticString)
        -> MeetingDiagnosticField
    {
        MeetingDiagnosticField(key, .text(MeetingDiagnosticDescription.scrubbed(value.value)))
    }

    /// An enum with no payload: its case name is the label.
    fileprivate static func word<Value>(_ key: String, _ value: Value) -> MeetingDiagnosticField {
        MeetingDiagnosticField(key, .label(String(describing: value)))
    }

    fileprivate static func track(_ track: MeetingTrack) -> MeetingDiagnosticField {
        MeetingDiagnosticField("track", .label(track.rawValue))
    }
}
