import Foundation

/// Why a helper output line was refused. Each one ends the session.
public enum MeetingWorkerLineError: Error, Equatable, Sendable {
    case oversize
    case notJSON
    case unknownType
    case badFields
}

/// The error domains of an `error` line. A short, stable token; never
/// user text and never a library message.
public enum MeetingWorkerErrorDomain: String, Codable, Sendable, CaseIterable {
    case request
    case model
    case audio
    case engine
    case protocolError = "protocol"
}

/// One line on the helper's standard output.
public enum MeetingWorkerEvent: Equatable, Sendable {
    /// The model is loaded. `cold` is true when the load took 2 s or more
    /// (a warm Core ML load is 0.08 to 1.4 s; a cold one 7 to 80 s).
    case ready(loadMilliseconds: Int, cold: Bool)
    /// The model load starts (a cold WhisperKit load is about 58 s).
    case preparing
    /// Live text that can still change, on the meeting clock.
    case volatile(track: MeetingTrack, text: String, start: Double, end: Double)
    /// Words that will not change. A long result comes as several lines.
    case final(track: MeetingTrack, words: [MeetingWord])
    /// 0...1 of the stored audio.
    case progress(fraction: Double)
    /// Speaker segments of the "Them" track. Several lines can come.
    case segments([MeetingSpeakerSegment])
    /// The helper's peak memory footprint (`phys_footprint` peak) and, in
    /// live mode, the chunk processing time of the last window.
    case stats(peakFootprintBytes: Int64, chunkP50Milliseconds: Int?, chunkP95Milliseconds: Int?)
    /// The job ended well. `audioSeconds` is the length of the audio read.
    case done(audioSeconds: Double?)
    /// The job failed. The process exits after this line.
    case error(domain: MeetingWorkerErrorDomain, code: Int)

    /// The threshold for `cold` in `ready`.
    public static let coldLoadMilliseconds = 2_000
}

extension MeetingWorkerEvent {
    private enum Kind: String {
        case ready, preparing, volatile, final, progress, segments, stats, done, error
    }

    // The JSON shape of each line. `type` names the case; the other keys
    // are short. Encoded by hand so an unknown `type` is refused.
    private struct Line: Codable {
        var type: String
        var loadMs: Int?
        var cold: Bool?
        var track: MeetingTrack?
        var text: String?
        var start: Double?
        var end: Double?
        var words: [MeetingWord]?
        var fraction: Double?
        var segments: [MeetingSpeakerSegment]?
        var peakFootprintBytes: Int64?
        var chunkP50Ms: Int?
        var chunkP95Ms: Int?
        var audioSeconds: Double?
        var domain: MeetingWorkerErrorDomain?
        var code: Int?
    }

    /// The event as one JSON line with a final newline. Throws `oversize`
    /// when the line would pass the line limit; use `batched` first for
    /// long word and segment lists.
    public func encodedLine() throws -> Data {
        var line = Line(type: "")
        switch self {
        case .ready(let loadMilliseconds, let cold):
            line.type = Kind.ready.rawValue
            line.loadMs = loadMilliseconds
            line.cold = cold
        case .preparing:
            line.type = Kind.preparing.rawValue
        case .volatile(let track, let text, let start, let end):
            line.type = Kind.volatile.rawValue
            line.track = track
            line.text = text
            line.start = start
            line.end = end
        case .final(let track, let words):
            line.type = Kind.final.rawValue
            line.track = track
            line.words = words
        case .progress(let fraction):
            line.type = Kind.progress.rawValue
            line.fraction = fraction
        case .segments(let segments):
            line.type = Kind.segments.rawValue
            line.segments = segments
        case .stats(let peak, let p50, let p95):
            line.type = Kind.stats.rawValue
            line.peakFootprintBytes = peak
            line.chunkP50Ms = p50
            line.chunkP95Ms = p95
        case .done(let audioSeconds):
            line.type = Kind.done.rawValue
            line.audioSeconds = audioSeconds
        case .error(let domain, let code):
            line.type = Kind.error.rawValue
            line.domain = domain
            line.code = code
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .throw
        var data = try encoder.encode(line)
        guard data.count <= MeetingWorkerProtocol.maximumLineBytes else {
            throw MeetingWorkerLineError.oversize
        }
        data.append(0x0A)
        return data
    }

    /// Decodes one output line (without its newline).
    public static func decode(line: Data) throws(MeetingWorkerLineError) -> MeetingWorkerEvent {
        guard line.count <= MeetingWorkerProtocol.maximumLineBytes else { throw .oversize }
        let raw: Line
        do {
            raw = try JSONDecoder().decode(Line.self, from: line)
        } catch {
            throw .notJSON
        }
        guard let kind = Kind(rawValue: raw.type) else { throw .unknownType }
        switch kind {
        case .ready:
            guard let loadMs = raw.loadMs, let cold = raw.cold else { throw .badFields }
            return .ready(loadMilliseconds: loadMs, cold: cold)
        case .preparing:
            return .preparing
        case .volatile:
            guard let track = raw.track, let text = raw.text, let start = raw.start,
                let end = raw.end
            else { throw .badFields }
            return .volatile(track: track, text: text, start: start, end: end)
        case .final:
            guard let track = raw.track, let words = raw.words else { throw .badFields }
            return .final(track: track, words: words)
        case .progress:
            guard let fraction = raw.fraction, fraction.isFinite else { throw .badFields }
            return .progress(fraction: min(1, max(0, fraction)))
        case .segments:
            guard let segments = raw.segments else { throw .badFields }
            return .segments(segments)
        case .stats:
            guard let peak = raw.peakFootprintBytes else { throw .badFields }
            return .stats(
                peakFootprintBytes: peak, chunkP50Milliseconds: raw.chunkP50Ms,
                chunkP95Milliseconds: raw.chunkP95Ms)
        case .done:
            return .done(audioSeconds: raw.audioSeconds)
        case .error:
            guard let domain = raw.domain, let code = raw.code else { throw .badFields }
            return .error(domain: domain, code: code)
        }
    }

    /// Splits a long `final` or `segments` event into events that each
    /// stay below the line limit. Other events come back unchanged.
    public func batched() -> [MeetingWorkerEvent] {
        switch self {
        case .final(let track, let words) where words.count > MeetingWorkerProtocol.wordsPerLine:
            return stride(from: 0, to: words.count, by: MeetingWorkerProtocol.wordsPerLine).map {
                let end = min($0 + MeetingWorkerProtocol.wordsPerLine, words.count)
                return .final(track: track, words: Array(words[$0..<end]))
            }
        case .segments(let segments) where segments.count > MeetingWorkerProtocol.segmentsPerLine:
            return stride(from: 0, to: segments.count, by: MeetingWorkerProtocol.segmentsPerLine)
                .map {
                    let end = min($0 + MeetingWorkerProtocol.segmentsPerLine, segments.count)
                    return .segments(Array(segments[$0..<end]))
                }
        default:
            return [self]
        }
    }
}
