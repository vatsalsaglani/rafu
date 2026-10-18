import Foundation
import Testing

@testable import RafuApp

/// `NotchNowPlaying` with injected readers: no Apple event is ever sent and no
/// observer is registered (`start()` is never called).

@MainActor
private func makePlayer(
    suite: String,
    running: Set<NowPlayingPlayer> = [.music],
    read: @escaping @Sendable (NowPlayingPlayer) async -> NowPlayingReadResult = { _ in .unavailable
    }
) -> NotchNowPlaying {
    NotchNowPlaying(
        preferences: NotchDisplayPreferenceStore(suiteName: suite),
        readTrack: read,
        sendCommand: { _, _ in nil },
        runningPlayers: { running })
}

@MainActor
@Test("accept: a notification track becomes the shown track, with its player's name")
func nowPlayingAcceptsNotification() {
    let suite = "dev.rafu.tests.now-playing.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let player = makePlayer(suite: suite)
    #expect(!player.hasTrack)
    player.accept(NowPlayingTrack(title: "Song", artist: "Band", playing: true), from: .spotify)
    #expect(player.title == "Song")
    #expect(player.artist == "Band")
    #expect(player.playing)
    #expect(player.source == "Spotify")
}

@MainActor
@Test("connect: records consent, then reads the running player once")
func nowPlayingConnectReads() async {
    let suite = "dev.rafu.tests.now-playing.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let player = makePlayer(suite: suite) { _ in
        .track(NowPlayingTrack(title: "Already playing", artist: "Artist", playing: true))
    }
    #expect(!player.isConnected)
    player.connect()
    #expect(player.isConnected)
    #expect(NotchDisplayPreferenceStore(suiteName: suite).isNowPlayingConnected())
    while player.refreshing { await Task.yield() }
    #expect(player.title == "Already playing")
    #expect(player.source == "Music")
}

@MainActor
@Test("refresh: a refused Apple event is reported as needing permission, not as an error")
func nowPlayingPermissionDenied() async {
    let suite = "dev.rafu.tests.now-playing.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let player = makePlayer(suite: suite) { _ in .permissionDenied }
    player.refresh()
    while player.refreshing { await Task.yield() }
    #expect(player.needsPermission)
    #expect(!player.unavailable)
    #expect(!player.hasTrack)
}

@MainActor
@Test("refresh: with no player running nothing is read and no state is faked")
func nowPlayingNothingRunning() async {
    let suite = "dev.rafu.tests.now-playing.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let player = makePlayer(suite: suite, running: []) { _ in
        Issue.record("a player that is not running must not be read")
        return .unavailable
    }
    player.accept(NowPlayingTrack(title: "Old", artist: "", playing: true), from: .music)
    player.refresh()
    #expect(!player.refreshing)
    #expect(!player.hasTrack)
}
