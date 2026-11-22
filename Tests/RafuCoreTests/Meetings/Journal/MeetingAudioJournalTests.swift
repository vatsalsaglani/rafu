import Foundation
import Testing

@testable import RafuCore

@Suite("Meeting audio journal and recovery")
struct MeetingAudioJournalTests {
    private static let rate = Int(MeetingAudioFormat.sampleRate)

    private static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "rafu-journal-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A ramp that never is zero, so silence fill is easy to tell apart.
    private static func samples(count: Int, offset: Int = 0) -> [Int16] {
        (0..<count).map { Int16(truncatingIfNeeded: ((offset + $0) % 30_000) + 1) }
    }

    /// Appends `seconds` of audio in 100 ms blocks from `start`.
    private static func append(
        _ writer: MeetingAudioJournalWriter, track: MeetingTrack, start: TimeInterval,
        seconds: Double
    ) throws {
        let block = rate / 10
        let blocks = Int(seconds * 10)
        for index in 0..<blocks {
            try writer.append(
                track: track, samples: samples(count: block, offset: index * block),
                startTime: start + Double(index) * 0.1)
        }
    }

    private static func pcm(_ url: URL) throws -> (header: Data, samples: [Int16]) {
        let data = try Data(contentsOf: url)
        let header = data.prefix(MeetingCAFFileWriter.headerSize)
        let body = data.dropFirst(MeetingCAFFileWriter.headerSize)
        let samples = body.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        return (Data(header), samples)
    }

    private final class Counter {
        var value = 0
    }

    /// Throws at `point` while the third "Me" segment closes.
    private static func failOnThirdSegment(at point: MeetingJournalSyncPoint)
        -> MeetingAudioJournalWriter.FaultInjector
    {
        let counter = Counter()
        return { reached, track in
            guard track == .me, reached == point else { return }
            counter.value += 1
            if counter.value == 3 { throw MeetingJournalError.injected(point) }
        }
    }

    @Test("Two tracks recover into CAF files on the meeting clock; Them starts 12.65 s late")
    func recoversBothTracks() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = MeetingAudioJournalWriter(audioFolder: folder, segmentSeconds: 1)
        try writer.prepare()
        try Self.append(writer, track: .me, start: 0, seconds: 2.5)
        try Self.append(writer, track: .them, start: 12.65, seconds: 1)
        try writer.flush()

        let diagnostics = CaptureTestDiagnostics()
        let report = try MeetingAudioJournalRecovery.recover(
            audioFolder: folder, diagnostics: diagnostics)
        #expect(report.result == .recovered)
        #expect(report.track(.me)?.frames == Int64(2.5 * Double(Self.rate)))
        #expect(report.track(.me)?.segmentsUsed == 3)
        let themStart = Int((12.65 * Double(Self.rate)).rounded())
        #expect(report.track(.them)?.frames == Int64(themStart + Self.rate))
        #expect(
            diagnostics.recorded.contains {
                if case .journalRecovery(.recovered, _) = $0 { true } else { false }
            })

        let me = try Self.pcm(MeetingJournalLayout.finalAudioFile(.me, in: folder))
        #expect(me.header == MeetingCAFFileWriter.header(frameCount: Int64(me.samples.count)))
        #expect(me.samples == Self.samples(count: 40_000))
        let them = try Self.pcm(MeetingJournalLayout.finalAudioFile(.them, in: folder))
        #expect(them.samples.prefix(themStart).allSatisfy { $0 == 0 })
        #expect(them.samples[themStart] != 0)
        #expect(them.samples.count == themStart + Self.rate)
    }

    @Test("A second recovery gives the same bytes")
    func recoveryIsRepeatable() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = MeetingAudioJournalWriter(audioFolder: folder, segmentSeconds: 1)
        try writer.prepare()
        try Self.append(writer, track: .me, start: 0.2, seconds: 3.3)
        try writer.flush()
        _ = try MeetingAudioJournalRecovery.recover(audioFolder: folder)
        let first = try Data(contentsOf: MeetingJournalLayout.finalAudioFile(.me, in: folder))
        _ = try MeetingAudioJournalRecovery.recover(audioFolder: folder)
        let second = try Data(contentsOf: MeetingJournalLayout.finalAudioFile(.me, in: folder))
        #expect(first == second)
        #expect(!first.isEmpty)
    }

    @Test(
        "A failure at each sync point keeps every written segment",
        arguments: MeetingJournalSyncPoint.allCases)
    func failureAtEachSyncPoint(point: MeetingJournalSyncPoint) throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = MeetingAudioJournalWriter(
            audioFolder: folder, segmentSeconds: 1,
            faultInjector: Self.failOnThirdSegment(at: point))
        try writer.prepare()
        #expect(throws: MeetingJournalError.injected(point)) {
            try Self.append(writer, track: .me, start: 0, seconds: 4)
        }
        // The process "crashed" here. The third segment was fully written
        // before each sync point, so its checksum passes.
        let report = try MeetingAudioJournalRecovery.recover(audioFolder: folder)
        #expect(report.track(.me)?.segmentsUsed == 3, "\(point)")
        #expect(report.track(.me)?.frames == Int64(3 * Self.rate), "\(point)")
        let first = try Data(contentsOf: MeetingJournalLayout.finalAudioFile(.me, in: folder))
        _ = try MeetingAudioJournalRecovery.recover(audioFolder: folder)
        let second = try Data(contentsOf: MeetingJournalLayout.finalAudioFile(.me, in: folder))
        #expect(first == second)
    }

    @Test("A torn write before the sync is dropped and counted")
    func tornPartialIsDropped() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = MeetingAudioJournalWriter(
            audioFolder: folder, segmentSeconds: 1,
            faultInjector: Self.failOnThirdSegment(at: .segmentWritten))
        try writer.prepare()
        #expect(throws: MeetingJournalError.self) {
            try Self.append(writer, track: .me, start: 0, seconds: 4)
        }
        let partial = MeetingJournalLayout.trackFolder(.me, in: folder)
            .appending(path: "000003.\(MeetingJournalLayout.partialExtension)")
        let data = try Data(contentsOf: partial)
        try data.prefix(data.count / 2).write(to: partial)

        let report = try MeetingAudioJournalRecovery.recover(audioFolder: folder)
        #expect(report.track(.me)?.segmentsUsed == 2)
        #expect(report.track(.me)?.segmentsDropped == 1)
        #expect(report.result == .partlyRecovered)
        #expect(report.track(.me)?.frames == Int64(2 * Self.rate))
    }

    @Test("A damaged segment is dropped and counted; its time stays silent")
    func damagedSegmentIsDropped() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = MeetingAudioJournalWriter(audioFolder: folder, segmentSeconds: 1)
        try writer.prepare()
        try Self.append(writer, track: .me, start: 0, seconds: 3)
        try writer.flush()
        let second = MeetingJournalLayout.trackFolder(.me, in: folder)
            .appending(path: MeetingJournalLayout.segmentName(2))
        var bytes = try Data(contentsOf: second)
        bytes[MeetingJournalSegmentHeader.size + 100] ^= 0xFF
        try bytes.write(to: second)

        let report = try MeetingAudioJournalRecovery.recover(audioFolder: folder)
        #expect(report.track(.me)?.segmentsDropped == 1)
        #expect(report.track(.me)?.segmentsUsed == 2)
        #expect(report.result == .partlyRecovered)
        let me = try Self.pcm(MeetingJournalLayout.finalAudioFile(.me, in: folder))
        #expect(me.samples.count == 3 * Self.rate)
        #expect(me.samples[Self.rate..<(2 * Self.rate)].allSatisfy { $0 == 0 })
        #expect(me.samples[2 * Self.rate] != 0)
    }

    @Test("A damaged header is dropped too")
    func damagedHeader() throws {
        let header = MeetingJournalSegmentHeader(
            track: .them, index: 7, startTime: 12.5, frameCount: 10, payloadChecksum: 99)
        let encoded = header.encoded()
        #expect(encoded.count == MeetingJournalSegmentHeader.size)
        #expect(MeetingJournalSegmentHeader.decode(encoded) == header)
        var broken = encoded
        broken[13] ^= 0x01
        #expect(MeetingJournalSegmentHeader.decode(broken) == nil)
    }

    @Test("A gap starts a new segment and recovery fills it with silence")
    func gapStartsNewSegment() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = MeetingAudioJournalWriter(audioFolder: folder, segmentSeconds: 10)
        try writer.prepare()
        try Self.append(writer, track: .me, start: 0, seconds: 0.5)
        try Self.append(writer, track: .me, start: 5, seconds: 0.5)
        try writer.flush()
        let report = try MeetingAudioJournalRecovery.recover(audioFolder: folder)
        #expect(report.track(.me)?.segmentsUsed == 2)
        let me = try Self.pcm(MeetingJournalLayout.finalAudioFile(.me, in: folder))
        #expect(me.samples.count == Int(5.5 * Double(Self.rate)))
        #expect(me.samples[Self.rate..<(5 * Self.rate)].allSatisfy { $0 == 0 })
    }

    @Test("A second writer continues the numbering; an empty journal has nothing to recover")
    func numberingContinues() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let empty = try MeetingAudioJournalRecovery.recover(audioFolder: folder)
        #expect(empty.result == .nothingToRecover)

        let first = MeetingAudioJournalWriter(audioFolder: folder, segmentSeconds: 1)
        try first.prepare()
        try Self.append(first, track: .me, start: 0, seconds: 1)
        try first.flush()
        let second = MeetingAudioJournalWriter(audioFolder: folder, segmentSeconds: 1)
        try second.prepare()
        try Self.append(second, track: .me, start: 1, seconds: 1)
        try second.flush()
        let report = try MeetingAudioJournalRecovery.recover(audioFolder: folder)
        #expect(report.track(.me)?.segmentsUsed == 2)
        #expect(report.track(.me)?.frames == Int64(2 * Self.rate))
        #expect(MeetingAudioJournalRecovery.hasJournal(in: folder))
        try MeetingAudioJournalRecovery.removeJournal(in: folder)
        #expect(!MeetingAudioJournalRecovery.hasJournal(in: folder))
    }
}
