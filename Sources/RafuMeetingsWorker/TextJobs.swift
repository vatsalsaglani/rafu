// Nemotron English text (live and after Stop) and WhisperKit text (after
// Stop). Each job is one nonisolated async function: engine objects are
// made, used and dropped inside it.
import AVFoundation
import FluidAudio
import Foundation
import RafuCore
import Synchronization
import WhisperKit

private func nemotronChunkSize(_ milliseconds: Int) -> NemotronChunkSize {
    switch milliseconds {
    case 560: .ms560
    case 2_240: .ms2240
    default: .ms1120
    }
}

private func makeNemotronManager(_ request: MeetingWorkerRequest) async throws
    -> StreamingNemotronAsrManager
{
    let manager = StreamingNemotronAsrManager(
        requestedChunkSize: nemotronChunkSize(request.chunkMilliseconds))
    try await manager.loadModels(from: URL(fileURLWithPath: request.modelFolder, isDirectory: true))
    return manager
}

private func tokens(_ timings: [TokenTiming], offset: Double = 0) -> [MeetingWorkerToken] {
    timings.map { MeetingWorkerToken(piece: $0.token, time: $0.startTime + offset) }
}

private func readyEvent(since start: ContinuousClock.Instant) -> MeetingWorkerEvent {
    let loadMs = Int(milliseconds(ContinuousClock.now - start).rounded())
    return .ready(loadMilliseconds: loadMs, cold: loadMs >= MeetingWorkerEvent.coldLoadMilliseconds)
}

// MARK: - Live text

/// The state of one live track.
private struct LiveTrack {
    let manager: StreamingNemotronAsrManager
    var accumulator = MeetingLiveWordAccumulator()
    var clock = MeetingLiveClockMap()
    var pendingSamples = 0
    var lastVolatile: String?
}

/// Live text for both tracks with Nemotron: one streaming manager for each
/// track, audio frames on standard input, words on standard output.
nonisolated func runLiveText(
    _ request: MeetingWorkerRequest, leftover: Data, output: WorkerOutput
) async -> MeetingWorkerExitCode {
    let loadStart = ContinuousClock.now
    var tracks: [MeetingTrack: LiveTrack] = [:]
    do {
        for track in MeetingTrack.allCases {
            tracks[track] = LiveTrack(manager: try await makeNemotronManager(request))
        }
    } catch {
        output.fail(.model, code: 1, exit: .engineError)
    }
    output.send(readyEvent(since: loadStart))

    let chunkSamples = request.chunkMilliseconds * 16
    var parser = MeetingWorkerFrameParser()
    var chunkTimes: [Double] = []
    var lastStats = ContinuousClock.now
    let pump = WorkerInputPump()
    pump.start()

    func handle(_ data: Data) async throws {
        let frames: [MeetingWorkerFrame]
        do {
            frames = try parser.append(data)
        } catch {
            output.fail(.protocolError, code: 1, exit: .badRequest)
        }
        for frame in frames {
            guard var state = tracks[frame.track], frame.sampleCount > 0 else { continue }
            state.clock.record(startTime: frame.startTime, sampleCount: frame.sampleCount)
            guard let buffer = makePCMBuffer(floatSamples(fromInt16: frame.samples)) else {
                continue
            }
            let started = ContinuousClock.now
            _ = try await state.manager.process(audioBuffer: buffer)
            let elapsed = milliseconds(ContinuousClock.now - started)
            state.pendingSamples += frame.sampleCount
            let chunks = state.pendingSamples / chunkSamples
            state.pendingSamples %= chunkSamples
            if chunks > 0 {
                for _ in 0..<chunks { chunkTimes.append(elapsed / Double(chunks)) }
                let update = state.accumulator.update(
                    allTokens: tokens(await state.manager.getTokenTimings()))
                if !update.finalWords.isEmpty {
                    output.send(
                        .final(track: frame.track, words: state.clock.mapped(update.finalWords)))
                }
                if let text = update.volatileText, let start = update.volatileStart,
                    text != state.lastVolatile
                {
                    let fedEnd = Double(state.clock.fedSamples) / AudioBlockReader.sampleRate
                    output.send(
                        .volatile(
                            track: frame.track, text: text,
                            start: state.clock.meetingTime(forFedSeconds: start),
                            end: state.clock.meetingTime(forFedSeconds: fedEnd)))
                }
                state.lastVolatile = update.volatileText
            }
            tracks[frame.track] = state
        }
        if ContinuousClock.now - lastStats
            >= .seconds(MeetingWorkerProtocol.liveStatsIntervalSeconds)
        {
            sendStats()
        }
    }

    func sendStats() {
        let p50 = MeetingWorkerPercentile.value(chunkTimes, fraction: 0.5)
        let p95 = MeetingWorkerPercentile.value(chunkTimes, fraction: 0.95)
        output.send(
            .stats(
                peakFootprintBytes: memoryFootprint().peak,
                chunkP50Milliseconds: p50.map { Int($0.rounded()) },
                chunkP95Milliseconds: p95.map { Int($0.rounded()) }))
        chunkTimes.removeAll(keepingCapacity: true)
        lastStats = ContinuousClock.now
    }

    do {
        if !leftover.isEmpty { try await handle(leftover) }
        for await block in pump.blocks {
            try await handle(block)
            pump.blockUsed()
        }
        // End of input: finish both tracks.
        for track in MeetingTrack.allCases {
            guard var state = tracks[track], state.clock.fedSamples > 0 else { continue }
            let result = try await state.manager.finishWithTokenTimings()
            let fedEnd = Double(state.clock.fedSamples) / AudioBlockReader.sampleRate
            let words = state.accumulator.finish(
                allTokens: tokens(result.timings), fallbackEnd: fedEnd)
            if !words.isEmpty {
                output.send(.final(track: track, words: state.clock.mapped(words)))
            }
            tracks[track] = state
        }
    } catch {
        output.fail(.engine, code: 2, exit: .engineError)
    }
    sendStats()
    output.send(.done(audioSeconds: nil))
    return .done
}

// MARK: - Final text, Nemotron

/// The final text of one stored track with Nemotron, read in 10 s blocks.
nonisolated func runNemotronFinalText(
    _ request: MeetingWorkerRequest, audioFile: String, output: WorkerOutput
) async -> MeetingWorkerExitCode {
    output.send(.preparing)
    let loadStart = ContinuousClock.now
    let manager: StreamingNemotronAsrManager
    do {
        manager = try await makeNemotronManager(request)
    } catch {
        output.fail(.model, code: 1, exit: .engineError)
    }
    output.send(readyEvent(since: loadStart))

    let reader: AudioBlockReader
    do {
        reader = try AudioBlockReader(path: audioFile)
    } catch {
        output.fail(.audio, code: 1, exit: .badRequest)
    }
    var lastProgress = 0.0
    do {
        while let samples = try reader.next(maximumSamples: 160_000) {
            guard let buffer = makePCMBuffer(samples) else { continue }
            _ = try await manager.process(audioBuffer: buffer)
            let fraction = reader.fractionRead
            if fraction - lastProgress >= 0.01 {
                output.send(.progress(fraction: fraction))
                lastProgress = fraction
            }
        }
    } catch is AudioBlockReaderError {
        output.fail(.audio, code: 2, exit: .engineError)
    } catch {
        output.fail(.engine, code: 2, exit: .engineError)
    }
    let audioSeconds = Double(reader.samplesRead) / AudioBlockReader.sampleRate
    do {
        let result = try await manager.finishWithTokenTimings()
        let words = MeetingTokenWordGrouper.words(
            from: tokens(result.timings, offset: request.clockOffsetSeconds),
            fallbackEnd: audioSeconds + request.clockOffsetSeconds)
        output.send(.final(track: .them, words: words))
    } catch {
        output.fail(.engine, code: 3, exit: .engineError)
    }
    output.send(.progress(fraction: 1))
    output.send(
        .stats(
            peakFootprintBytes: memoryFootprint().peak, chunkP50Milliseconds: nil,
            chunkP95Milliseconds: nil))
    output.send(.done(audioSeconds: audioSeconds))
    return .done
}

// MARK: - Final text, WhisperKit

/// The final text of one stored track with WhisperKit large-v3: word times
/// on, the file read by the library in bounded chunks, windows as the
/// library gives them.
nonisolated func runWhisperKitFinalText(
    _ request: MeetingWorkerRequest, audioFile: String, output: WorkerOutput
) async -> MeetingWorkerExitCode {
    let duration: Double
    do {
        duration = try AudioBlockReader(path: audioFile).durationSeconds
    } catch {
        output.fail(.audio, code: 1, exit: .badRequest)
    }
    output.send(.preparing)
    let loadStart = ContinuousClock.now
    let whisperKit: WhisperKit
    do {
        // `download: false`: the model folder is the only source. The
        // tokenizer files sit in that folder (checked before the load).
        let config = WhisperKitConfig(
            modelFolder: request.modelFolder, verbose: false, logLevel: .none, load: true,
            download: false)
        whisperKit = try await WhisperKit(config)
    } catch {
        output.fail(.model, code: 1, exit: .engineError)
    }
    output.send(readyEvent(since: loadStart))

    // One progress step for each 30 s window the library reports.
    let windows = Mutex((last: -1, count: 0))
    let callback: TranscriptionCallback = { progress in
        let count = windows.withLock { state -> Int? in
            guard progress.windowId != state.last else { return nil }
            state.last = progress.windowId
            state.count += 1
            return state.count
        }
        if let count, duration > 0 {
            output.send(.progress(fraction: min(0.99, Double(count - 1) * 30 / duration)))
        }
        return nil
    }
    let results: [TranscriptionResult]
    do {
        results = try await whisperKit.transcribe(
            audioPath: audioFile,
            audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental),
            decodeOptions: DecodingOptions(language: "en", wordTimestamps: true),
            callback: callback)
    } catch {
        output.fail(.engine, code: 2, exit: .engineError)
    }
    var words: [MeetingWord] = []
    for result in results {
        for segment in result.segments {
            for word in segment.words ?? [] {
                let text = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = Double(word.start) + request.clockOffsetSeconds
                let end = max(start, Double(word.end) + request.clockOffsetSeconds)
                words.append(MeetingWord(text: text, start: start, end: end))
            }
        }
    }
    words.sort { $0.start < $1.start }
    output.send(.final(track: .them, words: words))
    output.send(.progress(fraction: 1))
    output.send(
        .stats(
            peakFootprintBytes: memoryFootprint().peak, chunkP50Milliseconds: nil,
            chunkP95Milliseconds: nil))
    output.send(.done(audioSeconds: duration))
    return .done
}
