import AVFoundation
import CoreMedia
import Foundation
import RafuCore
import RafuObjCSupport
import Speech

// The thin adapter over Apple's `SpeechAnalyzer` and `SpeechTranscriber`
// (macOS 26). The call order is the one measured in the capture check (see
// `docs/references/meeting-audio-capture.md`, "APIs" and "Live speech").
// On-device `SpeechAnalyzer` needs no speech-recognition permission and no
// `NSSpeechRecognitionUsageDescription`.

@available(macOS 26, *)
nonisolated struct SystemAppleSpeechAnalyzer: AppleSpeechAnalyzing {
    static let localeIdentifier = "en-US"

    private func makeTranscriber(volatileResults: Bool) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw AppleSpeechError.transcriberUnavailable }
        guard
            let locale = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: Self.localeIdentifier))
        else { throw AppleSpeechError.unsupportedLocale }
        return SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: volatileResults ? [.volatileResults] : [],
            attributeOptions: [.audioTimeRange])
    }

    /// The asset status of the locale. Measured on macOS 27.2 (2026-11-23):
    /// `AssetInventory.status(forModules:)` gave `.supported` for a
    /// transcriber with no reporting options and `.installed` for one with
    /// `.volatileResults`, on the same Mac, while `installedLocales` listed
    /// en-US and `assetInstallationRequest` returned nil (nothing to install).
    /// So an installed locale counts as installed, whatever the options.
    private static func status(of transcriber: SpeechTranscriber) async -> AppleSpeechAssetStatus {
        let wanted = transcriber.selectedLocales.map { $0.identifier(.bcp47) }
        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        if !wanted.isEmpty, wanted.allSatisfy(installed.contains) { return .installed }
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return .installed
        case .supported: return .needsSystemDownload
        case .downloading: return .downloading
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// Throws unless the assets are installed. Live text and the final pass
    /// never start a system download.
    private static func requireInstalled(_ transcriber: SpeechTranscriber) async throws {
        guard await status(of: transcriber) == .installed else {
            throw AppleSpeechError.assetsNotInstalled
        }
    }

    func assetStatus() async -> AppleSpeechAssetStatus {
        guard let transcriber = try? await makeTranscriber(volatileResults: true) else {
            return .unsupported
        }
        return await Self.status(of: transcriber)
    }

    func installSystemAssets() async throws {
        let transcriber = try await makeTranscriber(volatileResults: false)
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber])
        {
            try await request.downloadAndInstall()
        }
    }

    func startLiveAnalysis() async throws -> any AppleSpeechLiveAnalysis {
        let transcriber = try await makeTranscriber(volatileResults: true)
        try await Self.requireInstalled(transcriber)
        return try await SystemAppleSpeechLiveAnalysis.start(transcriber: transcriber)
    }

    /// The system reads the file in its own blocks (`init(inputAudioFile:…)`
    /// with `finishAfterFile: true`, the call measured at 90 to 142 times real
    /// time), so the file is never in memory as a whole and its format is
    /// converted by the system.
    func analyzeFile(
        at url: URL, onProgress: @Sendable (Double) -> Void
    ) async throws -> AppleSpeechFileAnalysis {
        let started = ProcessInfo.processInfo.systemUptime
        let transcriber = try await makeTranscriber(volatileResults: false)
        try await Self.requireInstalled(transcriber)
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AppleSpeechError.unreadableAudio
        }
        let sampleRate = file.fileFormat.sampleRate
        let audioSeconds = sampleRate > 0 ? Double(file.length) / sampleRate : 0
        let analyzer = try await SpeechAnalyzer(
            inputAudioFile: file, modules: [transcriber], finishAfterFile: true)
        let loadMilliseconds = Int(
            ((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded())

        var results: [AppleSpeechResult] = []
        try await withTaskCancellationHandler {
            for try await result in transcriber.results {
                try Task.checkCancellation()
                let copied = AppleSpeechResultReader.read(result)
                guard copied.isFinal else { continue }
                results.append(copied)
                if audioSeconds > 0 { onProgress(copied.range.upperBound / audioSeconds) }
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
        return AppleSpeechFileAnalysis(
            audioSeconds: audioSeconds, loadMilliseconds: loadMilliseconds, results: results)
    }
}

/// One live analyzer, fed through a bounded `AsyncStream<AnalyzerInput>`.
@available(macOS 26, *)
nonisolated final class SystemAppleSpeechLiveAnalysis: AppleSpeechLiveAnalysis {
    /// 600 buffers of 100 ms: 60 s of backlog, as in the capture check.
    static let inputBufferLimit = 600

    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let analyzerFormat: AppleSpeechAudioFormat

    private init(
        analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        analyzerFormat: AppleSpeechAudioFormat
    ) {
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.continuation = continuation
        self.analyzerFormat = analyzerFormat
    }

    static func start(transcriber: SpeechTranscriber) async throws -> SystemAppleSpeechLiveAnalysis
    {
        let input = AppleSpeechAudioFormat.meetingInput
        let best = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber], considering: input.makeFormat())
        let analyzerFormat = best.map(AppleSpeechAudioFormat.init(_:)) ?? input
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: analyzerFormat.makeFormat())
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingOldest(inputBufferLimit))
        try await analyzer.start(inputSequence: stream)
        return SystemAppleSpeechLiveAnalysis(
            analyzer: analyzer, transcriber: transcriber, continuation: continuation,
            analyzerFormat: analyzerFormat)
    }

    func append(samples: Data, frameCount: Int) -> Bool {
        guard
            let buffer = AppleSpeechPCM.buffer(
                samples: samples, frameCount: frameCount, analyzerFormat: analyzerFormat)
        else { return false }
        if case .dropped = continuation.yield(AnalyzerInput(buffer: buffer)) { return false }
        return true
    }

    func consumeResults(_ handler: @Sendable (AppleSpeechResult) async -> Void) async throws {
        for try await result in transcriber.results {
            await handler(AppleSpeechResultReader.read(result))
        }
    }

    func finish() async throws {
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    }

    func cancel() async {
        continuation.finish()
        await analyzer.cancelAndFinishNow()
    }
}

/// Copies a `SpeechTranscriber.Result` into `AppleSpeechResult`.
@available(macOS 26, *)
nonisolated enum AppleSpeechResultReader {
    static func read(_ result: SpeechTranscriber.Result) -> AppleSpeechResult {
        let text = result.text
        var runs: [AppleSpeechRun] = []
        for run in text.runs {
            let piece = String(text[run.range].characters)
            let range = run.audioTimeRange.flatMap(seconds(of:))
            runs.append(AppleSpeechRun(text: piece, range: range))
        }
        return AppleSpeechResult(
            isFinal: result.isFinal, range: seconds(of: result.range) ?? 0...0, runs: runs)
    }

    static func seconds(of range: CMTimeRange) -> ClosedRange<TimeInterval>? {
        let start = range.start.seconds
        let end = CMTimeRangeGetEnd(range).seconds
        guard start.isFinite, end.isFinite else { return nil }
        return min(start, end)...max(start, end)
    }
}

/// A `Sendable` description of an audio format (`AVAudioFormat` is not
/// `Sendable`).
nonisolated struct AppleSpeechAudioFormat: Sendable, Equatable {
    var commonFormat: AVAudioCommonFormat
    var sampleRate: Double
    var channelCount: AVAudioChannelCount
    var isInterleaved: Bool

    /// The format of `MeetingAudioChunk`: 16 kHz, mono, Int16, interleaved.
    static let meetingInput = AppleSpeechAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: MeetingAudioFormat.sampleRate,
        channelCount: AVAudioChannelCount(MeetingAudioFormat.channelCount), isInterleaved: true)

    init(
        commonFormat: AVAudioCommonFormat, sampleRate: Double, channelCount: AVAudioChannelCount,
        isInterleaved: Bool
    ) {
        self.commonFormat = commonFormat
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.isInterleaved = isInterleaved
    }

    init(_ format: AVAudioFormat) {
        self.init(
            commonFormat: format.commonFormat, sampleRate: format.sampleRate,
            channelCount: format.channelCount, isInterleaved: format.isInterleaved)
    }

    func makeFormat() -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: commonFormat, sampleRate: sampleRate, channels: channelCount,
            interleaved: isInterleaved)
    }
}

/// Makes analyzer buffers from meeting chunks.
nonisolated enum AppleSpeechPCM {
    /// A buffer in `analyzerFormat` from 16 kHz mono Int16 samples. When the
    /// analyzer wants another format (it gave 16 kHz mono Int16 in every
    /// measured run), one `AVAudioConverter` for this buffer converts it.
    static func buffer(
        samples: Data, frameCount: Int, analyzerFormat: AppleSpeechAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard frameCount > 0, samples.count == frameCount * MeetingAudioFormat.bytesPerFrame,
            let inputFormat = AppleSpeechAudioFormat.meetingInput.makeFormat(),
            let input = AVAudioPCMBuffer(
                pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frameCount)),
            let channel = input.int16ChannelData?[0]
        else { return nil }
        input.frameLength = AVAudioFrameCount(frameCount)
        samples.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(channel, base, samples.count)
        }
        if analyzerFormat == .meetingInput { return input }
        guard let outputFormat = analyzerFormat.makeFormat(),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { return nil }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(frameCount) * ratio).rounded(.up) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        else { return nil }
        var supplied = false
        var error: NSError?
        var status = AVAudioConverterOutputStatus.error
        // An NSException from the converter gives no buffer, not an abort of
        // all of Rafu.
        do {
            try RafuObjCExceptionGuard.perform {
                status = converter.convert(to: output, error: &error) { _, inputStatus in
                    if supplied {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    supplied = true
                    inputStatus.pointee = .haveData
                    return input
                }
            }
        } catch {
            return nil
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
