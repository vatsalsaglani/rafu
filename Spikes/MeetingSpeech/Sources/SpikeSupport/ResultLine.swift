// One JSON result line per run, per the plan's "Files to create" table.
// Throw-away spike code; see .rafu/plans/meeting-speech-spike.md.
import Foundation

public struct ChunkStats: Sendable, Codable {
    public var medianMs: Double
    public var p95Ms: Double
    public var maxMs: Double

    public init(medianMs: Double, p95Ms: Double, maxMs: Double) {
        self.medianMs = medianMs
        self.p95Ms = p95Ms
        self.maxMs = maxMs
    }
}

public struct ResultLine: Sendable, Codable {
    public var engine: String
    public var model: String
    public var file: String
    public var audioSeconds: Double
    public var loadMs: Double
    public var firstResultMs: Double
    public var processSeconds: Double
    public var footprintAfterLoadMB: Double
    public var footprintPeakMB: Double
    public var footprintEndMB: Double
    public var chunkStats: ChunkStats?
    public var note: String?

    public var rtfx: Double {
        guard processSeconds > 0 else { return 0 }
        return audioSeconds / processSeconds
    }

    public init(
        engine: String, model: String, file: String, audioSeconds: Double, loadMs: Double,
        firstResultMs: Double, processSeconds: Double, footprintAfterLoadMB: Double,
        footprintPeakMB: Double, footprintEndMB: Double, chunkStats: ChunkStats? = nil,
        note: String? = nil
    ) {
        self.engine = engine
        self.model = model
        self.file = file
        self.audioSeconds = audioSeconds
        self.loadMs = loadMs
        self.firstResultMs = firstResultMs
        self.processSeconds = processSeconds
        self.footprintAfterLoadMB = footprintAfterLoadMB
        self.footprintPeakMB = footprintPeakMB
        self.footprintEndMB = footprintEndMB
        self.chunkStats = chunkStats
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case engine, model, file
        case audioSeconds = "audio_seconds"
        case loadMs = "load_ms"
        case firstResultMs = "first_result_ms"
        case processSeconds = "process_seconds"
        case rtfx
        case footprintAfterLoadMB = "footprint_after_load_mb"
        case footprintPeakMB = "footprint_peak_mb"
        case footprintEndMB = "footprint_end_mb"
        case chunkStats = "chunk_stats"
        case note
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(engine, forKey: .engine)
        try container.encode(model, forKey: .model)
        try container.encode(file, forKey: .file)
        try container.encode(audioSeconds, forKey: .audioSeconds)
        try container.encode(loadMs, forKey: .loadMs)
        try container.encode(firstResultMs, forKey: .firstResultMs)
        try container.encode(processSeconds, forKey: .processSeconds)
        try container.encode(rtfx, forKey: .rtfx)
        try container.encode(footprintAfterLoadMB, forKey: .footprintAfterLoadMB)
        try container.encode(footprintPeakMB, forKey: .footprintPeakMB)
        try container.encode(footprintEndMB, forKey: .footprintEndMB)
        try container.encodeIfPresent(chunkStats, forKey: .chunkStats)
        try container.encodeIfPresent(note, forKey: .note)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        engine = try container.decode(String.self, forKey: .engine)
        model = try container.decode(String.self, forKey: .model)
        file = try container.decode(String.self, forKey: .file)
        audioSeconds = try container.decode(Double.self, forKey: .audioSeconds)
        loadMs = try container.decode(Double.self, forKey: .loadMs)
        firstResultMs = try container.decode(Double.self, forKey: .firstResultMs)
        processSeconds = try container.decode(Double.self, forKey: .processSeconds)
        footprintAfterLoadMB = try container.decode(Double.self, forKey: .footprintAfterLoadMB)
        footprintPeakMB = try container.decode(Double.self, forKey: .footprintPeakMB)
        footprintEndMB = try container.decode(Double.self, forKey: .footprintEndMB)
        chunkStats = try container.decodeIfPresent(ChunkStats.self, forKey: .chunkStats)
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    /// Prints the line to stdout as one line of compact JSON.
    public func printLine() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            print("{\"error\":\"failed to encode result line\"}")
            return
        }
        print(text)
    }
}
