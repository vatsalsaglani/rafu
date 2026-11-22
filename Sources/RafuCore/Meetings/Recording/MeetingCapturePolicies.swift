import Foundation

/// Core Audio transport types (`kAudioDeviceTransportType…`), as the
/// four-character codes the device reports. Kept here so the pure policies
/// do not import Core Audio.
public enum MeetingTransportType {
    public static let builtIn: UInt32 = fourCharacterCode("bltn")
    public static let bluetooth: UInt32 = fourCharacterCode("blue")
    public static let bluetoothLE: UInt32 = fourCharacterCode("blea")
    public static let usb: UInt32 = fourCharacterCode("usb ")
    public static let aggregate: UInt32 = fourCharacterCode("grup")
    public static let virtual: UInt32 = fourCharacterCode("virt")

    public static func isBluetooth(_ transport: UInt32) -> Bool {
        transport == bluetooth || transport == bluetoothLE
    }

    public static func fourCharacterCode(_ text: StaticString) -> UInt32 {
        text.withUTF8Buffer { bytes in
            bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
    }
}

/// One audio input device, as the microphone policy sees it.
public struct MeetingInputDevice: Hashable, Sendable {
    /// The Core Audio object id (`AudioObjectID`).
    public var objectID: UInt32
    public var uid: String
    public var name: String
    public var transportType: UInt32

    public init(objectID: UInt32, uid: String, name: String, transportType: UInt32) {
        self.objectID = objectID
        self.uid = uid
        self.name = name
        self.transportType = transportType
    }

    public var isBuiltIn: Bool { transportType == MeetingTransportType.builtIn }
    public var isBluetooth: Bool { MeetingTransportType.isBluetooth(transportType) }
}

/// The microphone that a recording uses, and why.
public struct MeetingMicrophoneResolution: Hashable, Sendable {
    public var device: MeetingInputDevice?
    public var kind: MeetingMicrophoneChoiceKind
    public var reason: MeetingMicrophoneChoiceReason

    public init(
        device: MeetingInputDevice?, kind: MeetingMicrophoneChoiceKind,
        reason: MeetingMicrophoneChoiceReason
    ) {
        self.device = device
        self.kind = kind
        self.reason = reason
    }

    /// True when the start view should say "A headset microphone gives poor
    /// text. Use the Mac microphone."
    public var usesHeadsetMicrophone: Bool { device?.isBluetooth ?? false }
}

/// Which microphone a recording uses (the decision about Bluetooth headset
/// microphones in call mode). Automatic: the system default input, but the
/// built-in microphone when the default input is a Bluetooth device and a
/// built-in input exists. A call-mode headset microphone gave 71 to 92 %
/// wrong words in the engine bench; the Mac microphone gave 21 to 34 %.
public enum MeetingMicrophonePolicy {
    public static func resolve(
        choice: MeetingMicrophoneChoice, defaultInput: MeetingInputDevice?,
        inputs: [MeetingInputDevice]
    ) -> MeetingMicrophoneResolution {
        switch choice {
        case .systemDefault:
            return .init(device: defaultInput, kind: .systemDefault, reason: .systemDefault)
        case .device(let uid):
            if let named = inputs.first(where: { $0.uid == uid }) {
                return .init(device: named, kind: .named, reason: .userSelected)
            }
            // The named device is gone: fall back to the Automatic rule.
            let automatic = automaticDevice(defaultInput: defaultInput, inputs: inputs)
            return .init(device: automatic, kind: .named, reason: .namedDeviceMissing)
        case .automatic:
            let device = automaticDevice(defaultInput: defaultInput, inputs: inputs)
            let reason: MeetingMicrophoneChoiceReason =
                device != defaultInput ? .builtInOverCallHeadset : .systemDefault
            return .init(device: device, kind: .automatic, reason: reason)
        }
    }

    private static func automaticDevice(
        defaultInput: MeetingInputDevice?, inputs: [MeetingInputDevice]
    ) -> MeetingInputDevice? {
        guard let defaultInput else { return inputs.first(where: \.isBuiltIn) }
        if defaultInput.isBluetooth, let builtIn = inputs.first(where: \.isBuiltIn) {
            return builtIn
        }
        return defaultInput
    }
}

/// The sample rate rule for the call-audio tap: the tap format said 48 kHz
/// while AirPods in call mode ran the device at 24 kHz, and buffers labelled
/// 48 kHz were 2x speed audio. Use the aggregate device's nominal rate.
public enum MeetingSampleRatePolicy {
    public struct Resolution: Hashable, Sendable {
        public var rate: Double
        public var corrected: Bool
    }

    public static func effectiveRate(tapRate: Double, deviceRate: Double?) -> Resolution {
        guard let deviceRate, deviceRate > 0, deviceRate.isFinite else {
            return Resolution(rate: tapRate, corrected: false)
        }
        return Resolution(rate: deviceRate, corrected: deviceRate != tapRate)
    }

    /// Resolves the rate and records the tap format, the device rate and any
    /// correction.
    @discardableResult
    public static func resolve(
        tapFormat: MeetingTapFormat, deviceRate: Double?,
        diagnostics: any MeetingDiagnosticsRecording, meeting: MeetingID?
    ) -> Resolution {
        diagnostics.record(.tapFormat(tapFormat), meeting: meeting)
        if let deviceRate {
            diagnostics.record(
                .aggregateDeviceRate(nominalSampleRate: deviceRate), meeting: meeting)
        }
        let resolution = effectiveRate(tapRate: tapFormat.sampleRate, deviceRate: deviceRate)
        if resolution.corrected {
            diagnostics.record(
                .sampleRateCorrected(from: tapFormat.sampleRate, to: resolution.rate),
                meeting: meeting)
        }
        return resolution
    }
}

/// What the health check found on one track.
public enum MeetingTrackFinding: Hashable, Sendable {
    /// No buffer for the limit while one was expected.
    case noBuffers
    /// Only exact digital silence for the limit while sound played. A
    /// missing system-audio grant looks like this: every call returns 0 and
    /// each buffer is zeros (measured with no usage key).
    case silentWhilePlaying
}

/// The health check of one track, a pure value fed by the recorder. Times
/// are seconds of a monotonic clock. Each finding is reported once until
/// the track recovers.
///
/// - "Me": the microphone always gives buffers, even in a quiet room, so no
///   buffer for `limit` seconds is a finding. Exact silence for `limit`
///   seconds is `silentWhilePlaying` (a muted or denied microphone).
/// - "Them": the tap gives no buffer until sound plays (12.65 s and 15.0 s in
///   the capture check), so no buffer is a finding only after another app
///   has played sound for `limit` seconds.
public struct MeetingTrackHealthMonitor: Hashable, Sendable {
    public static let defaultLimit: TimeInterval = 5

    public let track: MeetingTrack
    public let limit: TimeInterval
    private var reference: TimeInterval
    private var lastBuffer: TimeInterval?
    private var silentSince: TimeInterval?
    private var playingSince: TimeInterval?
    private var heardSound = false
    private var reported: Set<MeetingTrackFinding> = []

    public init(track: MeetingTrack, startedAt: TimeInterval, limit: TimeInterval = defaultLimit) {
        self.track = track
        self.limit = limit
        self.reference = startedAt
    }

    /// A buffer arrived.
    public mutating func noteBuffer(at time: TimeInterval, silent: Bool) {
        lastBuffer = time
        reported.remove(.noBuffers)
        if silent {
            if silentSince == nil { silentSince = time }
        } else {
            silentSince = nil
            heardSound = true
            reported.remove(.silentWhilePlaying)
        }
    }

    /// The source started again (resume, or a rebuild after a device
    /// change): wait the full limit again.
    public mutating func noteRestart(at time: TimeInterval) {
        reference = time
        lastBuffer = nil
        silentSince = nil
        playingSince = nil
        reported = []
    }

    /// Checks the track. `othersPlaying`: another app plays sound now.
    public mutating func evaluate(at time: TimeInterval, othersPlaying: Bool)
        -> MeetingTrackFinding?
    {
        switch track {
        case .me:
            if time - (lastBuffer ?? reference) >= limit {
                return report(.noBuffers)
            }
            if let silentSince, time - silentSince >= limit {
                return report(.silentWhilePlaying)
            }
            return nil
        case .them:
            guard othersPlaying else {
                playingSince = nil
                return nil
            }
            let since = max(playingSince ?? time, reference)
            if playingSince == nil { playingSince = time }
            if time - max(lastBuffer ?? since, since) >= limit {
                return report(.noBuffers)
            }
            // A call app in a quiet moment plays exact silence too, so the
            // silence check runs only until the first real sound of the
            // recording proves the grant.
            if !heardSound, let silentSince, time - max(silentSince, since) >= limit {
                return report(.silentWhilePlaying)
            }
            return nil
        }
    }

    /// True after the first buffer that was not exact silence.
    public var hasHeardSound: Bool { heardSound }

    private mutating func report(_ finding: MeetingTrackFinding) -> MeetingTrackFinding? {
        guard !reported.contains(finding) else { return nil }
        reported.insert(finding)
        return finding
    }
}

/// Levels of one block of samples.
public struct MeetingBlockLevels: Hashable, Sendable {
    public var peakDBFS: Double
    public var meanDBFS: Double
    /// Every sample is exactly zero.
    public var isDigitalSilence: Bool

    public static let floorDBFS: Double = -160

    public init(peakDBFS: Double, meanDBFS: Double, isDigitalSilence: Bool) {
        self.peakDBFS = peakDBFS
        self.meanDBFS = meanDBFS
        self.isDigitalSilence = isDigitalSilence
    }

    /// Levels of 16-bit samples. The mean is the RMS level.
    public static func measure(_ samples: UnsafeBufferPointer<Int16>) -> MeetingBlockLevels {
        var peak: Int32 = 0
        var sumSquares = 0.0
        for sample in samples {
            let magnitude = abs(Int32(sample))
            if magnitude > peak { peak = magnitude }
            sumSquares += Double(sample) * Double(sample)
        }
        guard !samples.isEmpty, peak > 0 else {
            return .init(peakDBFS: floorDBFS, meanDBFS: floorDBFS, isDigitalSilence: true)
        }
        let rms = (sumSquares / Double(samples.count)).squareRoot() / 32_768
        return .init(
            peakDBFS: decibels(Double(peak) / 32_768), meanDBFS: decibels(rms),
            isDigitalSilence: false)
    }

    public static func decibels(_ amplitude: Double) -> Double {
        guard amplitude > 0 else { return floorDBFS }
        return max(floorDBFS, 20 * log10(amplitude))
    }
}

extension MeetingCaptureProblem {
    /// The System Settings pane that fixes a missing permission, or nil.
    /// The microphone anchor is the documented one; the audio-capture
    /// anchor (`Privacy_AudioCapture`) follows the TCC service name
    /// `kTCCServiceAudioCapture` and is not verified on a Mac yet.
    public var settingsPaneURL: URL? {
        switch self {
        case .missingMicrophonePermission:
            URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .missingSystemAudioPermission:
            URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
            )
        case .noBuffers, .deviceLost, .diskFull:
            nil
        }
    }

    /// A short message for the user.
    public var message: String {
        switch self {
        case .missingMicrophonePermission:
            "Rafu cannot use the microphone. Allow it in System Settings ▸ Privacy & Security ▸ Microphone."
        case .missingSystemAudioPermission:
            "Rafu cannot record the call sound. Allow it in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording."
        case .noBuffers:
            "No sound arrived from the microphone. The recording stopped and the audio so far is kept."
        case .deviceLost:
            "An audio device was lost and could not be opened again. The audio so far is kept."
        case .diskFull:
            "The disk is full. The recording stopped and the audio so far is kept."
        }
    }
}
