import AVFoundation
import Foundation
import RafuCore
import Synchronization

/// The microphone side, as `VoiceSession` sees it. Tests inject a fake.
protocol VoiceAudioCapturing: AnyObject {
    /// Starts the tap. Yields 20 ms frames of 24 kHz mono PCM16 (960 bytes).
    func startCapture() throws -> AsyncStream<Data>
    /// Removes the tap and finishes the stream.
    func stopCapture()
    /// True when echo cancellation is on, so local speech heard while Rafu
    /// speaks is the user and may cut the reply. Without it, Rafu's own
    /// voice from the speakers would cut itself.
    var supportsBargeIn: Bool { get }
    /// How the newest engine started. Numbers only, for the debug transcript.
    var lastEngineFacts: VoiceEngineFacts { get }
    /// Frames the current (or last) capture yielded and dropped since the
    /// previous call; the counts restart at zero.
    func takeCaptureStats() -> VoiceCaptureStats
}

/// How an engine started: for the opt-in debug transcript only.
nonisolated struct VoiceEngineFacts: Equatable, Sendable {
    var voiceProcessing = false
    /// The engine with voice processing did not start; this one runs without it.
    var fallbackUsed = false
    var startMS = 0
    var inputChannels = 0
    var sampleRate = 0
}

/// Capture frame counts: for the opt-in debug transcript only.
nonisolated struct VoiceCaptureStats: Equatable, Sendable {
    var yielded = 0
    /// Frames the stream buffer had no room for (the oldest went).
    var dropped = 0
}

/// The speaker side. The server streams 100 ms deltas continuously, silence
/// included (Phase 0), so the player is always fed while a session is open.
protocol VoiceAudioPlaying: AnyObject {
    func startPlayback() throws
    func enqueue(_ pcm: Data)
    /// Drops queued audio at once, for barge-in or Stop Speaking.
    func flush()
    /// Stops everything and releases the engine.
    func stopAll()
}

nonisolated enum VoiceAudioError: Error {
    case noInput
    case converter
}

/// One `AVAudioEngine` for both directions, so voice processing (echo
/// cancellation) can hear what Rafu plays. It exists only while a voice
/// session is open: idle Rafu holds no engine, no tap and no node.
///
/// Thread rules: the tap and render blocks run on audio threads. They are
/// built in `nonisolated` static functions, so they never inherit main-actor
/// isolation (a main-actor closure called on an audio thread traps), and
/// they touch only the stream continuation, buffers allocated before the
/// engine starts, and `Atomic` values. No lock, no `await`, no actor hop.
/// The engine itself is driven from the main actor.
final class VoiceAudioIO: VoiceAudioCapturing, VoiceAudioPlaying {
    private var engine: AVAudioEngine?
    private var source: AVAudioSourceNode?
    private var ring: VoicePlaybackRing?
    private var captureContinuation: AsyncStream<Data>.Continuation?
    private var tapInstalled = false
    /// The current or last capture's framer, kept after `stopCapture` so
    /// its counts can still be read.
    private var framer: VoiceCaptureFramer?
    /// Whether voice processing could be turned on. Read by Settings and
    /// recorded in the reference note after the manual check.
    private(set) var voiceProcessingEnabled = false

    var supportsBargeIn: Bool { voiceProcessingEnabled }

    private(set) var lastEngineFacts = VoiceEngineFacts()

    init() {}

    /// Builds and starts the engine with echo cancellation; when that engine
    /// does not start, builds a new one without it. Order matters: voice
    /// processing is turned on only after the source → main mixer → output
    /// graph exists. Turned on first (macOS 27, MacBook Air built-in mic and
    /// speakers), the output hardware format reads 0 ch / 0 Hz and `start()`
    /// fails with -10875 (`kAUInitialize` on the output node).
    func startPlayback() throws {
        guard engine == nil else { return }
        let started = ContinuousClock.now
        var fallbackUsed = false
        do {
            try startEngine(voiceProcessing: true)
        } catch {
            // Voice writes no logs (VoiceSourcePolicyTests). When this also
            // fails, the session's blob reason is the only report.
            fallbackUsed = true
            try startEngine(voiceProcessing: false)
        }
        let time = (ContinuousClock.now - started).components
        // `startCapture` reads the same input format a moment later.
        let input = engine?.inputNode.outputFormat(forBus: 0)
        lastEngineFacts = VoiceEngineFacts(
            voiceProcessing: voiceProcessingEnabled, fallbackUsed: fallbackUsed,
            startMS: Int(time.seconds * 1_000 + time.attoseconds / 1_000_000_000_000_000),
            inputChannels: Int(input?.channelCount ?? 0), sampleRate: Int(input?.sampleRate ?? 0))
    }

    private func startEngine(voiceProcessing: Bool) throws {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: VoiceAudioFormat.sampleRate,
                channels: 1, interleaved: false)
        else { throw VoiceAudioError.converter }
        let engine = AVAudioEngine()
        let ring = VoicePlaybackRing()
        let source = Self.makeSource(format: format, ring: ring)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        // Echo cancellation. Some devices refuse it; then the session runs
        // without it and local barge-in relies on the RMS threshold.
        var processing = false
        if voiceProcessing {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                processing = true
            } catch {
                processing = false
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.stop()
            engine.detach(source)
            throw error
        }
        voiceProcessingEnabled = processing
        self.engine = engine
        self.source = source
        self.ring = ring
    }

    func enqueue(_ pcm: Data) { ring?.write(pcm) }

    func flush() { ring?.requestFlush() }

    func startCapture() throws -> AsyncStream<Data> {
        guard let engine else { throw VoiceAudioError.noInput }
        stopCapture()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        // The converter reads a mono copy of channel 0, never the tap format:
        // with voice processing the input node has 9 channels (macOS 27), and
        // an `AVAudioConverter` from that format writes only zeros, with or
        // without `downmix`. Channel 0 is the processed voice.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate,
                channels: 1, interleaved: false),
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: VoiceAudioFormat.sampleRate,
                channels: 1, interleaved: true),
            let converter = AVAudioConverter(from: monoFormat, to: outputFormat)
        else { throw VoiceAudioError.converter }
        // 15 s of frames (at most about 720 KB, freed when the stream ends):
        // speech said while the session opens is sent after it starts. A cold
        // first open was measured at 3.1 s and 11.7 s, so 2 s lost the start.
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self, bufferingPolicy: .bufferingNewest(Self.bufferedFrames))
        let framer = VoiceCaptureFramer(
            converter: converter, monoFormat: monoFormat, outputFormat: outputFormat,
            continuation: continuation)
        self.framer = framer
        Self.installTap(on: input, format: inputFormat, framer: framer)
        tapInstalled = true
        captureContinuation = continuation
        return stream
    }

    func stopCapture() {
        if tapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        captureContinuation?.finish()
        captureContinuation = nil
    }

    func stopAll() { teardown() }

    /// 750 frames of 20 ms: 15 s.
    nonisolated static let bufferedFrames = 750

    func takeCaptureStats() -> VoiceCaptureStats {
        framer?.takeStats() ?? VoiceCaptureStats()
    }

    /// The render block, built outside the main actor.
    private nonisolated static func makeSource(format: AVAudioFormat, ring: VoicePlaybackRing)
        -> AVAudioSourceNode
    {
        AVAudioSourceNode(format: format) { isSilence, _, frameCount, buffers in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            guard let first = list.first, let data = first.mData else { return noErr }
            let output = data.assumingMemoryBound(to: Float.self)
            let produced = ring.read(into: output, count: Int(frameCount))
            if produced == 0 { isSilence.pointee = true }
            return noErr
        }
    }

    /// The tap block, built outside the main actor.
    private nonisolated static func installTap(
        on input: AVAudioInputNode, format: AVAudioFormat, framer: VoiceCaptureFramer
    ) {
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { buffer, _ in
            framer.consume(buffer)
        }
    }

    private func teardown() {
        stopCapture()
        engine?.stop()
        if let source { engine?.detach(source) }
        source = nil
        engine = nil
        ring = nil
        framer = nil
    }
}

/// Copies channel 0 of each tap buffer, converts it to 24 kHz mono PCM16 and
/// cuts it into 20 ms frames. Used only on the tap thread; its buffers are
/// allocated up front. The two counters are `Atomic`: the tap thread adds,
/// the main actor takes.
nonisolated final class VoiceCaptureFramer {
    private let converter: AVAudioConverter
    private let mono: AVAudioPCMBuffer?
    private let converted: AVAudioPCMBuffer?
    private let continuation: AsyncStream<Data>.Continuation
    private var pending: [Int16]
    private let yielded = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)

    init(
        converter: AVAudioConverter, monoFormat: AVAudioFormat, outputFormat: AVAudioFormat,
        continuation: AsyncStream<Data>.Continuation
    ) {
        self.converter = converter
        self.continuation = continuation
        // 500 ms of input: room for a large tap buffer at any device rate.
        mono = AVAudioPCMBuffer(
            pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(monoFormat.sampleRate * 0.5))
        // Room for a large tap buffer (100 ms at 192 kHz) after conversion.
        let capacity = AVAudioFrameCount(VoiceAudioFormat.sampleRate * 0.5)
        converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        pending = []
        pending.reserveCapacity(Int(capacity) + VoiceAudioFormat.inputFrameSamples)
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        guard let mono, let converted, let source = buffer.floatChannelData?[0],
            let target = mono.floatChannelData?[0]
        else { return }
        let length = min(buffer.frameLength, mono.frameCapacity)
        target.update(from: source, count: Int(length))
        mono.frameLength = length
        converted.frameLength = 0
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return mono
        }
        guard status != .error, let samples = converted.int16ChannelData?[0] else { return }
        let count = Int(converted.frameLength)
        pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        let frame = VoiceAudioFormat.inputFrameSamples
        var offset = 0
        while pending.count - offset >= frame {
            let data = pending[offset..<offset + frame].withUnsafeBytes { Data($0) }
            if case .dropped = continuation.yield(data) {
                dropped.add(1, ordering: .relaxed)
            }
            yielded.add(1, ordering: .relaxed)
            offset += frame
        }
        if offset > 0 { pending.removeFirst(offset) }
    }

    /// The counts since the last call; both restart at zero.
    func takeStats() -> VoiceCaptureStats {
        VoiceCaptureStats(
            yielded: yielded.exchange(0, ordering: .relaxed),
            dropped: dropped.exchange(0, ordering: .relaxed))
    }
}

/// A single-producer, single-consumer ring of PCM16 samples. The main actor
/// writes; the render thread reads. Each index has one writer; a flush is a
/// request the reader carries out, so the reader stays the only writer of
/// `readIndex`.
nonisolated final class VoicePlaybackRing {
    /// 2 s at 24 kHz.
    static let capacity = 48_000

    private let storage: UnsafeMutablePointer<Int16>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private let flushRequested = Atomic<Bool>(false)

    init() {
        storage = .allocate(capacity: Self.capacity)
        storage.initialize(repeating: 0, count: Self.capacity)
    }

    deinit { storage.deallocate() }

    /// Samples waiting to play.
    var queued: Int { writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .acquiring) }

    /// Appends little-endian PCM16. When the ring is full the rest is
    /// dropped: the stream is real-time paced, so this only happens after a
    /// long stall.
    func write(_ pcm: Data) {
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        let free = Self.capacity - (write - read)
        let count = min(pcm.count / 2, free)
        guard count > 0 else { return }
        pcm.withUnsafeBytes { raw in
            for index in 0..<count {
                let low = UInt16(raw[index * 2])
                let high = UInt16(raw[index * 2 + 1])
                storage[(write + index) % Self.capacity] = Int16(bitPattern: low | high << 8)
            }
        }
        writeIndex.store(write + count, ordering: .releasing)
    }

    func requestFlush() { flushRequested.store(true, ordering: .releasing) }

    /// Fills `count` floats; returns how many came from the ring. The rest
    /// is silence.
    func read(into output: UnsafeMutablePointer<Float>, count: Int) -> Int {
        if flushRequested.exchange(false, ordering: .acquiringAndReleasing) {
            readIndex.store(writeIndex.load(ordering: .acquiring), ordering: .releasing)
        }
        let read = readIndex.load(ordering: .relaxed)
        let available = writeIndex.load(ordering: .acquiring) - read
        let produced = min(count, max(0, available))
        for index in 0..<produced {
            output[index] = Float(storage[(read + index) % Self.capacity]) / 32_768
        }
        for index in produced..<count { output[index] = 0 }
        readIndex.store(read + produced, ordering: .releasing)
        return produced
    }
}

/// Microphone permission. Tests inject `requestMicrophone` instead.
enum VoiceMicrophonePermission {
    enum Access: Equatable {
        case allowed
        case notAsked
        case denied
    }

    static var access: Access {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    /// Asks once; later calls return the stored answer at once.
    static func request() async -> Bool {
        switch access {
        case .allowed: return true
        case .notAsked: return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied: return false
        }
    }
}
