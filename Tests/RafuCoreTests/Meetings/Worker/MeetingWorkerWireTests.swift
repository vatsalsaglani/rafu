import Foundation
import RafuCore
import Testing

@Suite("Meetings speech worker wire")
struct MeetingWorkerWireTests {
    // MARK: Arguments

    @Test("The argument list is mode and protocol only, and parses back")
    func argumentsRoundTrip() throws {
        for mode in MeetingWorkerMode.allCases {
            let arguments = MeetingWorkerArguments.make(mode: mode)
            #expect(arguments == ["--mode", mode.rawValue, "--protocol", "1"])
            #expect(try MeetingWorkerArguments.parse(arguments) == mode)
        }
    }

    @Test("Each other argument shape is a usage error")
    func argumentsRefused() {
        let wrong: [[String]] = [
            [], ["--mode", "live-text"], ["--protocol", "1", "--mode", "live-text"],
            ["--mode", "dictate", "--protocol", "1"],
            ["--mode", "live-text", "--protocol", "1", "/Users/me/model"],
        ]
        for arguments in wrong {
            #expect(throws: MeetingWorkerUsageError.wrongArguments) {
                try MeetingWorkerArguments.parse(arguments)
            }
        }
        #expect(throws: MeetingWorkerUsageError.unsupportedProtocol) {
            try MeetingWorkerArguments.parse(["--mode", "speakers", "--protocol", "2"])
        }
    }

    @Test("Exit codes match the protocol")
    func exitCodes() {
        #expect(MeetingWorkerExitCode.done.rawValue == 0)
        #expect(MeetingWorkerExitCode.usage.rawValue == 64)
        #expect(MeetingWorkerExitCode.badRequest.rawValue == 65)
        #expect(MeetingWorkerExitCode.modelMissing.rawValue == 66)
        #expect(MeetingWorkerExitCode.engineError.rawValue == 70)
        #expect(MeetingWorkerExitCode.cancelled.rawValue == 75)
    }

    // MARK: Request

    @Test("A request round-trips as one line below 16 KB")
    func requestRoundTrip() throws {
        let request = MeetingWorkerRequest(
            engine: .whisperKit, modelFolder: "/Library/Models/whisper/rev",
            audioFile: "/Library/Meetings/a/them.caf", clockOffsetSeconds: 1.5)
        let line = try request.encodedLine()
        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
        let decoded = try MeetingWorkerRequest.decode(line: line.dropLast())
        #expect(decoded == request)
    }

    @Test("A request over 16 KB, not JSON, or of another protocol is refused")
    func requestRefused() {
        let big = Data(repeating: 0x20, count: MeetingWorkerProtocol.maximumRequestBytes + 1)
        #expect(throws: MeetingWorkerRequestError.tooLarge) {
            try MeetingWorkerRequest.decode(line: big)
        }
        #expect(throws: MeetingWorkerRequestError.notJSON) {
            try MeetingWorkerRequest.decode(line: Data("hello".utf8))
        }
        let other = Data(
            #"{"protocolVersion":2,"engine":"nemotron-en","modelFolder":"/m","clockOffsetSeconds":0,"chunkMilliseconds":1120}"#
                .utf8)
        #expect(throws: MeetingWorkerRequestError.wrongProtocol) {
            try MeetingWorkerRequest.decode(line: other)
        }
        let request = MeetingWorkerRequest(
            engine: .nemotronEnglish, modelFolder: "/" + String(repeating: "a", count: 17_000))
        #expect(throws: MeetingWorkerRequestError.tooLarge) { try request.encodedLine() }
    }

    @Test("Each engine runs only its modes")
    func engineModes() {
        #expect(MeetingWorkerEngineID.nemotronEnglish.supportedModes == [.liveText, .finalText])
        #expect(MeetingWorkerEngineID.whisperKit.supportedModes == [.finalText])
        #expect(MeetingWorkerEngineID.nemotron3.supportedModes == [.speakers])
        #expect(MeetingWorkerEngineID.speakerKit.supportedModes == [.speakers])
        #expect(throws: MeetingWorkerRequestError.engineNotInHelper) {
            try MeetingWorkerEngineID(MeetingTextEngineID.appleSpeech)
        }
    }

    // MARK: Output lines

    static let everyEvent: [MeetingWorkerEvent] = [
        .ready(loadMilliseconds: 120, cold: false),
        .preparing,
        .volatile(track: .me, text: "hello wor", start: 1.25, end: 2),
        .final(track: .them, words: [MeetingWord(text: "hello", start: 1, end: 1.4)]),
        .progress(fraction: 0.5),
        .segments([MeetingSpeakerSegment(speaker: 2, start: 3, end: 4.5)]),
        .stats(
            peakFootprintBytes: 268_026_984, chunkP50Milliseconds: 77, chunkP95Milliseconds: 106),
        .stats(peakFootprintBytes: 1, chunkP50Milliseconds: nil, chunkP95Milliseconds: nil),
        .done(audioSeconds: 1_530.5),
        .done(audioSeconds: nil),
        .error(domain: .model, code: 1),
    ]

    @Test("Each output line round-trips", arguments: everyEvent)
    func eventRoundTrip(_ event: MeetingWorkerEvent) throws {
        let line = try event.encodedLine()
        #expect(line.last == 0x0A)
        #expect(try MeetingWorkerEvent.decode(line: line.dropLast()) == event)
    }

    @Test("An unknown line type is refused")
    func unknownLineRefused() {
        #expect(throws: MeetingWorkerLineError.unknownType) {
            try MeetingWorkerEvent.decode(line: Data(#"{"type":"transcript","text":"x"}"#.utf8))
        }
        #expect(throws: MeetingWorkerLineError.notJSON) {
            try MeetingWorkerEvent.decode(line: Data("ready".utf8))
        }
        #expect(throws: MeetingWorkerLineError.badFields) {
            try MeetingWorkerEvent.decode(line: Data(#"{"type":"ready"}"#.utf8))
        }
    }

    @Test("An oversize line is refused on both sides")
    func oversizeRefused() {
        let words = (0..<5_000).map {
            MeetingWord(text: "word\($0)", start: Double($0), end: Double($0) + 0.5)
        }
        #expect(throws: MeetingWorkerLineError.oversize) {
            try MeetingWorkerEvent.final(track: .me, words: words).encodedLine()
        }
        let big = Data(repeating: 0x20, count: MeetingWorkerProtocol.maximumLineBytes + 1)
        #expect(throws: MeetingWorkerLineError.oversize) {
            try MeetingWorkerEvent.decode(line: big)
        }
    }

    @Test("A long word or segment list is batched into lines below the limit")
    func batching() throws {
        let words = (0..<5_000).map {
            MeetingWord(text: "word\($0)", start: Double($0), end: Double($0) + 0.5)
        }
        let parts = MeetingWorkerEvent.final(track: .them, words: words).batched()
        #expect(parts.count == 13)
        var joined: [MeetingWord] = []
        for part in parts {
            #expect(try part.encodedLine().count <= MeetingWorkerProtocol.maximumLineBytes + 1)
            if case .final(.them, let batch) = part { joined += batch }
        }
        #expect(joined == words)
        let segments = (0..<2_000).map {
            MeetingSpeakerSegment(speaker: $0 % 3 + 1, start: Double($0), end: Double($0) + 1)
        }
        let segmentParts = MeetingWorkerEvent.segments(segments).batched()
        #expect(segmentParts.count == 3)
        #expect(MeetingWorkerEvent.preparing.batched() == [.preparing])
    }

    @Test("The line splitter keeps a split line and refuses a line with no end")
    func lineSplitter() throws {
        var splitter = MeetingWorkerLineSplitter(maximumBytes: 16)
        #expect(try splitter.append(Data("abc".utf8)).isEmpty)
        #expect(
            try splitter.append(Data("d\nef\n\ng".utf8)) == [
                Data("abcd".utf8), Data("ef".utf8), Data(),
            ])
        #expect(splitter.pendingBytes == Data("g".utf8))
        #expect(throws: MeetingWorkerLineError.oversize) {
            try splitter.append(Data(repeating: 0x41, count: 16))
        }
        var second = MeetingWorkerLineSplitter(maximumBytes: 4)
        #expect(throws: MeetingWorkerLineError.oversize) {
            try second.append(Data("abcdef\n".utf8))
        }
    }

    // MARK: Frames

    private static func samples(_ count: Int, seed: Int16 = 3) -> Data {
        var data = Data()
        for index in 0..<count {
            let value = Int16(truncatingIfNeeded: index &* Int(seed)).littleEndian
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        return data
    }

    @Test("Frames parse back when the stream splits at each byte")
    func framesSplitAnywhere() throws {
        let frames = [
            MeetingWorkerFrame(track: .me, startTime: 0, samples: Self.samples(5)),
            MeetingWorkerFrame(track: .them, startTime: 12.65, samples: Self.samples(7, seed: 9)),
            MeetingWorkerFrame(track: .me, startTime: 13.5, samples: Data()),
        ]
        let stream = frames.reduce(into: Data()) { $0.append($1.encoded()) }
        #expect(stream.count == 3 * 13 + 24)
        for split in 0...stream.count {
            var parser = MeetingWorkerFrameParser()
            var parsed = try parser.append(stream.prefix(split))
            parsed += try parser.append(stream.dropFirst(split))
            #expect(parsed == frames)
            #expect(parser.pendingByteCount == 0)
        }
        var bytewise = MeetingWorkerFrameParser()
        var parsed: [MeetingWorkerFrame] = []
        for byte in stream { parsed += try bytewise.append(Data([byte])) }
        #expect(parsed == frames)
    }

    @Test("A frame with an unknown track, too many samples or a bad time is refused")
    func framesRefused() {
        var header = Data([2])
        withUnsafeBytes(of: Double(0).bitPattern.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(1).littleEndian) { header.append(contentsOf: $0) }
        var parser = MeetingWorkerFrameParser()
        #expect(throws: MeetingWorkerFrameError.unknownTrack) { try parser.append(header) }

        var big = Data([1])
        withUnsafeBytes(of: Double(0).bitPattern.littleEndian) { big.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(16_001).littleEndian) { big.append(contentsOf: $0) }
        var second = MeetingWorkerFrameParser()
        #expect(throws: MeetingWorkerFrameError.tooManySamples) { try second.append(big) }

        var nan = Data([0])
        withUnsafeBytes(of: Double.nan.bitPattern.littleEndian) { nan.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(0).littleEndian) { nan.append(contentsOf: $0) }
        var third = MeetingWorkerFrameParser()
        #expect(throws: MeetingWorkerFrameError.badTime) { try third.append(nan) }
    }

    @Test("A chunk splits into frames of at most 1 s with their own start times")
    func chunkSplit() throws {
        let data = Self.samples(40_000)
        let chunk = MeetingAudioChunk(
            track: .them, samples: data, startTime: 100, frameCount: 40_000)
        let frames = MeetingWorkerFrame.split(chunk)
        #expect(frames.map(\.sampleCount) == [16_000, 16_000, 8_000])
        #expect(frames.map(\.startTime) == [100, 101, 102])
        #expect(frames.allSatisfy { $0.track == .them })
        #expect(frames.reduce(into: Data()) { $0.append($1.samples) } == data)
        let slice = MeetingAudioChunk(
            track: .me, samples: data.dropFirst(2), startTime: 0, frameCount: 1)
        #expect(
            MeetingWorkerFrame.split(slice).first?.samples == Data(data.dropFirst(2).prefix(32_000))
        )
        let empty = MeetingAudioChunk(track: .me, samples: Data(), startTime: 0, frameCount: 0)
        #expect(MeetingWorkerFrame.split(empty).isEmpty)
    }
}
