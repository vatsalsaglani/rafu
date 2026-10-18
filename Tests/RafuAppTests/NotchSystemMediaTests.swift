import Foundation
import Testing

@testable import RafuApp

/// A stand-in for the MediaRemote adapter: records calls, and lets a test
/// push lines or fail the stream. No process is ever started.
@MainActor
private final class FakeSystemMedia: NotchSystemMediaStreaming {
    var isAvailable = true
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var commands: [NowPlayingCommand] = []
    private var onLine: ((Data) -> Void)?
    private var onFailure: (() -> Void)?

    func start(onLine: @escaping (Data) -> Void, onFailure: @escaping () -> Void) {
        starts += 1
        self.onLine = onLine
        self.onFailure = onFailure
    }

    func send(_ command: NowPlayingCommand) { commands.append(command) }

    func stop() {
        stops += 1
        onLine = nil
        onFailure = nil
    }

    func push(_ json: String) { onLine?(Data(json.utf8)) }

    func fail() {
        let failure = onFailure
        onLine = nil
        onFailure = nil
        failure?()
    }
}

@MainActor
private func makePlayer(suite: String, media: FakeSystemMedia) -> NotchNowPlaying {
    NotchNowPlaying(
        preferences: NotchDisplayPreferenceStore(suiteName: suite),
        readTrack: { _ in .unavailable },
        sendCommand: { _, _ in nil },
        runningPlayers: { [] },
        systemMedia: media,
        appName: { $0 == "com.apple.Safari" ? "Safari" : $0 })
}

@MainActor
@Suite("Notch system media")
struct NotchSystemMediaTests {
    @Test("Start uses the adapter by default and shows what it streams")
    func streamsSystemMedia() {
        let suite = "dev.rafu.tests.system-media.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let media = FakeSystemMedia()
        let player = makePlayer(suite: suite, media: media)
        player.start()
        #expect(player.isSystemMedia)
        #expect(media.starts == 1)
        media.push(
            #"{"type":"data","diff":false,"payload":{"title":"Talk","artist":"Host","playing":true,"bundleIdentifier":"com.apple.Safari"}}"#
        )
        #expect(player.title == "Talk")
        #expect(player.artist == "Host")
        #expect(player.playing)
        #expect(player.source == "Safari")
        media.push(#"{"type":"data","diff":false,"payload":{}}"#)
        #expect(!player.hasTrack)
        player.stop()
        #expect(media.stops == 1)
        #expect(!player.isSystemMedia)
    }

    @Test("Transport commands go to the adapter")
    func commands() {
        let suite = "dev.rafu.tests.system-media.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let media = FakeSystemMedia()
        let player = makePlayer(suite: suite, media: media)
        player.start()
        player.togglePlayback()
        player.next()
        player.previous()
        #expect(media.commands == [.playPause, .next, .previous])
        player.stop()
    }

    @Test("A failed adapter falls back to Music and Spotify for the run")
    func fallbackOnFailure() {
        let suite = "dev.rafu.tests.system-media.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let media = FakeSystemMedia()
        let player = makePlayer(suite: suite, media: media)
        player.start()
        media.push(#"{"type":"data","payload":{"title":"Song","playing":true}}"#)
        media.fail()
        #expect(!player.isSystemMedia)
        #expect(!player.hasTrack)
        player.accept(NowPlayingTrack(title: "Public", artist: "A", playing: true), from: .music)
        #expect(player.title == "Public")
        #expect(player.source == "Music")
        player.stop()
    }

    @Test("Turning the setting off, or a missing adapter, uses the public path")
    func preferenceAndAvailability() {
        let suite = "dev.rafu.tests.system-media.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        NotchDisplayPreferenceStore(suiteName: suite).setUsesSystemNowPlaying(false)
        let media = FakeSystemMedia()
        let player = makePlayer(suite: suite, media: media)
        player.start()
        #expect(!player.isSystemMedia)
        #expect(media.starts == 0)
        player.stop()

        let otherSuite = "dev.rafu.tests.system-media.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: otherSuite)?.removePersistentDomain(forName: otherSuite) }
        let missing = FakeSystemMedia()
        missing.isAvailable = false
        let fallback = makePlayer(suite: otherSuite, media: missing)
        fallback.start()
        #expect(!fallback.isSystemMedia)
        fallback.stop()
    }

    @Test("The setting defaults to on")
    func defaultOn() {
        let suite = "dev.rafu.tests.system-media.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        #expect(NotchDisplayPreferenceStore(suiteName: suite).usesSystemNowPlaying())
    }
}

@Suite("Notch system media parsing")
struct NotchSystemMediaParsingTests {
    @Test("Envelopes parse; other lines are ignored; text is bounded")
    func parse() throws {
        let long = String(repeating: "x", count: 500)
        let line = Data(
            #"{"type":"data","payload":{"title":"\#(long)","artist":"B","playing":false,"parentApplicationBundleIdentifier":"com.google.Chrome","bundleIdentifier":"com.google.Chrome.helper"}}"#
                .utf8)
        let snapshot = try #require(NotchSystemMediaSnapshot.parse(line: line))
        #expect(snapshot.title.count == NowPlayingTrack.maximumTextLength)
        #expect(snapshot.bundleIdentifier == "com.google.Chrome")
        #expect(!snapshot.playing)
        #expect(NotchSystemMediaSnapshot.parse(line: Data("garbage".utf8)) == nil)
        #expect(NotchSystemMediaSnapshot.parse(line: Data(#"{"type":"error"}"#.utf8)) == nil)
        #expect(
            NotchSystemMediaSnapshot.parse(line: Data(#"{"type":"data","payload":{}}"#.utf8))
                == .empty)
    }

    @Test("The line buffer splits lines across chunks and drops oversized lines")
    func lineBuffer() {
        var buffer = NotchLineBuffer()
        #expect(buffer.append(Data("ab".utf8)).isEmpty)
        #expect(buffer.append(Data("c\nde\n\nf".utf8)) == [Data("abc".utf8), Data("de".utf8)])
        let huge = Data(repeating: 0x41, count: NotchLineBuffer.maximumLineBytes + 1)
        #expect(buffer.append(huge).isEmpty)
        #expect(buffer.append(Data("tail\nnext\n".utf8)) == [Data("next".utf8)])
    }

    @Test("Command ids match the adapter's MediaRemote numbers")
    func commandCodes() {
        #expect(NotchSystemMediaBridge.code(.playPause) == 2)
        #expect(NotchSystemMediaBridge.code(.next) == 4)
        #expect(NotchSystemMediaBridge.code(.previous) == 5)
    }
}
