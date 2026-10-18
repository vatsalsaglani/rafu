import Foundation

/// A player Rafu can read. Only these two fixed bundle ids are ever queried or
/// controlled, so no external text can become an Apple event target.
nonisolated enum NowPlayingPlayer: String, CaseIterable, Sendable {
    case music = "com.apple.Music"
    case spotify = "com.spotify.client"

    var displayName: String {
        switch self {
        case .music: "Music"
        case .spotify: "Spotify"
        }
    }

    /// The public notification each player posts on `DistributedNotificationCenter`
    /// when its track or state changes. Needs no permission.
    var notificationNames: [String] {
        switch self {
        case .music: ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo"]
        case .spotify: ["com.spotify.client.PlaybackStateChanged"]
        }
    }
}

nonisolated struct NowPlayingTrack: Equatable, Sendable {
    let title: String
    let artist: String
    let playing: Bool

    /// Reads a player notification's `userInfo` (`Name`, `Artist`,
    /// `Player State`). Missing keys give empty strings; a state other than
    /// "Playing" is not playing. Titles and artists are display text, bounded
    /// to keep a hostile notification from growing the model.
    static func fromNotification(_ userInfo: [AnyHashable: Any]?) -> NowPlayingTrack {
        NowPlayingTrack(
            title: bounded(userInfo?["Name"] as? String),
            artist: bounded(userInfo?["Artist"] as? String),
            playing: (userInfo?["Player State"] as? String) == "Playing")
    }

    static let maximumTextLength = 200

    private static func bounded(_ text: String?) -> String {
        String((text ?? "").prefix(maximumTextLength))
    }
}

nonisolated enum NowPlayingCommand: Sendable {
    case playPause
    case next
    case previous

    /// The AppleScript verb both players understand.
    var verb: String {
        switch self {
        case .playPause: "playpause"
        case .next: "next track"
        case .previous: "previous track"
        }
    }
}

/// The only AppleScript Rafu runs. Every variable part is a case of a fixed
/// enum, so no document, terminal, or network text can reach a script.
nonisolated enum NowPlayingScripts {
    /// Returns `{title, artist, state}`, or empty strings and "stopped" when
    /// the player is not running or has no current track. The timeout bounds
    /// the wait if the player is hung or the consent dialog is open.
    static func read(_ player: NowPlayingPlayer) -> String {
        """
        if application id "\(player.rawValue)" is not running then return {"", "", "stopped"}
        with timeout of 3 seconds
            tell application id "\(player.rawValue)"
                if player state is stopped then return {"", "", "stopped"}
                return {name of current track, artist of current track, player state as text}
            end tell
        end timeout
        """
    }

    static func command(_ command: NowPlayingCommand, for player: NowPlayingPlayer) -> String {
        """
        if application id "\(player.rawValue)" is running then
            with timeout of 3 seconds
                tell application id "\(player.rawValue)" to \(command.verb)
            end timeout
        end if
        """
    }

    /// AppleScript error number for "not authorised to send Apple events".
    static let notAuthorizedErrorNumber = -1743
}

/// The outcome of one explicit read of a player (an Apple event).
nonisolated enum NowPlayingReadResult: Equatable, Sendable {
    case track(NowPlayingTrack)
    case unavailable
    case permissionDenied
}

/// Which track the notch shows when Music and Spotify both know one. Pure, so
/// the choice is testable without either app: the most recently active player
/// wins while playing; otherwise any player with a title; a paused player
/// never displaces one that is playing.
nonisolated struct NowPlayingTracker: Equatable, Sendable {
    private var tracks: [NowPlayingPlayer: NowPlayingTrack] = [:]
    private var preferred: NowPlayingPlayer = .music
    private var revisions: [NowPlayingPlayer: Int] = [:]

    init() {}

    /// Records `track` from `player`. Bumps the player's revision so a slower
    /// explicit read that started earlier can be discarded.
    mutating func accept(_ track: NowPlayingTrack, from player: NowPlayingPlayer) {
        revisions[player, default: 0] += 1
        tracks[player] = track
        if track.playing { preferred = player }
    }

    func revision(of player: NowPlayingPlayer) -> Int { revisions[player, default: 0] }

    /// Forgets players that are no longer running.
    mutating func prune(running: Set<NowPlayingPlayer>) {
        tracks = tracks.filter { running.contains($0.key) }
    }

    mutating func removeAll() {
        tracks.removeAll()
    }

    /// The track and player to show, or `nil` when nothing has a title.
    var current: (player: NowPlayingPlayer, track: NowPlayingTrack)? {
        let order = [preferred] + NowPlayingPlayer.allCases.filter { $0 != preferred }
        let player =
            order.first { tracks[$0]?.playing == true }
            ?? order.first { !(tracks[$0]?.title.isEmpty ?? true) }
        guard let player, let track = tracks[player] else { return nil }
        return (player, track)
    }
}
