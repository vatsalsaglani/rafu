import AppKit
import Observation

/// Runs the fixed Now Playing scripts. Apple events are confined to one serial
/// utility queue with a bounded reply timeout (the script's own
/// `with timeout`), so a hung player or an open consent dialog never blocks
/// the main actor. Nothing here is a private API: it is `NSAppleScript`
/// against the two public scripting dictionaries.
nonisolated enum NowPlayingScriptRunner {
    private static let queue = DispatchQueue(label: "dev.rafu.now-playing", qos: .utility)

    static func read(_ player: NowPlayingPlayer) async -> NowPlayingReadResult {
        await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: NowPlayingScripts.read(player))?
                    .executeAndReturnError(&error)
                guard error == nil, let result, result.numberOfItems == 3 else {
                    continuation.resume(returning: failure(error))
                    return
                }
                continuation.resume(
                    returning: .track(
                        NowPlayingTrack(
                            title: String(
                                (result.atIndex(1)?.stringValue ?? "").prefix(
                                    NowPlayingTrack.maximumTextLength)),
                            artist: String(
                                (result.atIndex(2)?.stringValue ?? "").prefix(
                                    NowPlayingTrack.maximumTextLength)),
                            playing: result.atIndex(3)?.stringValue == "playing")))
            }
        }
    }

    /// Sends a transport command. Returns `.permissionDenied` when macOS
    /// refused the Apple event, `.unavailable` for any other failure, and
    /// `nil` on success.
    static func send(_ command: NowPlayingCommand, to player: NowPlayingPlayer) async
        -> NowPlayingReadResult?
    {
        await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                _ = NSAppleScript(source: NowPlayingScripts.command(command, for: player))?
                    .executeAndReturnError(&error)
                continuation.resume(returning: error == nil ? nil : failure(error))
            }
        }
    }

    private static func failure(_ error: NSDictionary?) -> NowPlayingReadResult {
        let number = error?[NSAppleScript.errorNumber] as? Int
        return number == NowPlayingScripts.notAuthorizedErrorNumber
            ? .permissionDenied : .unavailable
    }
}

/// What Music or Spotify is playing, read through public API only.
///
/// Two paths, both public:
///
/// 1. Push, no permission: each player posts a `DistributedNotificationCenter`
///    notification when the track or state changes. Rafu observes those from
///    the moment the notch is shown. A track that is already playing before
///    Rafu launched is not announced, so it appears at the next change.
/// 2. Pull, with the person's consent: reading or controlling a player sends
///    an Apple event, which macOS gates behind Automation consent
///    (`NSAppleEventsUsageDescription`). Rafu sends none until the person
///    presses Connect, Refresh, or a transport button. After the first
///    explicit Connect, Rafu also refreshes once when the notch starts.
///
/// Cider reads system-wide media (browsers, video) through the private
/// MediaRemote framework. Rafu does not: no public API exposes other apps'
/// now-playing state, and private frameworks are not allowed here.
@MainActor
@Observable
final class NotchNowPlaying {
    private(set) var title = ""
    private(set) var artist = ""
    private(set) var playing = false
    private(set) var source = ""
    private(set) var needsPermission = false
    private(set) var unavailable = false
    private(set) var refreshing = false
    private(set) var isConnected: Bool

    var hasTrack: Bool { !title.isEmpty }

    @ObservationIgnored private var tracker = NowPlayingTracker()
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var currentPlayer: NowPlayingPlayer?
    @ObservationIgnored private let preferences: NotchDisplayPreferenceStore
    @ObservationIgnored private let readTrack:
        @Sendable (NowPlayingPlayer) async ->
            NowPlayingReadResult
    @ObservationIgnored private let sendCommand:
        @Sendable (NowPlayingCommand, NowPlayingPlayer) async -> NowPlayingReadResult?
    @ObservationIgnored private let runningPlayers: @MainActor () -> Set<NowPlayingPlayer>

    init(
        preferences: NotchDisplayPreferenceStore = NotchDisplayPreferenceStore(),
        readTrack: @escaping @Sendable (NowPlayingPlayer) async -> NowPlayingReadResult = {
            await NowPlayingScriptRunner.read($0)
        },
        sendCommand:
            @escaping @Sendable (NowPlayingCommand, NowPlayingPlayer) async ->
            NowPlayingReadResult? = { await NowPlayingScriptRunner.send($0, to: $1) },
        runningPlayers: @escaping @MainActor () -> Set<NowPlayingPlayer> = {
            let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            return Set(NowPlayingPlayer.allCases.filter { ids.contains($0.rawValue) })
        }
    ) {
        self.preferences = preferences
        self.readTrack = readTrack
        self.sendCommand = sendCommand
        self.runningPlayers = runningPlayers
        isConnected = preferences.isNowPlayingConnected()
    }

    /// Starts listening. Idempotent. Registers observers only; sends no Apple
    /// event unless the person already connected.
    func start() {
        guard observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        for player in NowPlayingPlayer.allCases {
            for name in player.notificationNames {
                let token = distributed.addObserver(
                    forName: Notification.Name(name), object: nil, queue: .main
                ) { [weak self] notification in
                    MainActor.assumeIsolated {
                        self?.accept(
                            NowPlayingTrack.fromNotification(notification.userInfo),
                            from: player)
                    }
                }
                observers.append((distributed, token))
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didWakeNotification,
        ] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.runningPlayersChanged() }
            }
            observers.append((workspace, token))
        }
        if isConnected { refresh() }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshing = false
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        tracker.removeAll()
        project()
    }

    /// The explicit pull. The first call is the person's consent to send
    /// Apple events to Music and Spotify.
    func connect() {
        isConnected = true
        preferences.setNowPlayingConnected(true)
        refresh()
    }

    func refresh() {
        guard !refreshing else { return }
        let running = runningPlayers()
        tracker.prune(running: running)
        project()
        guard !running.isEmpty else {
            unavailable = false
            needsPermission = false
            return
        }
        refreshing = true
        unavailable = false
        needsPermission = false
        let read = readTrack
        refreshTask = Task { [weak self] in
            for player in NowPlayingPlayer.allCases where running.contains(player) {
                guard let self else { return }
                let revision = tracker.revision(of: player)
                let result = await read(player)
                guard !Task.isCancelled else { return }
                // A notification that arrived during the read is newer.
                guard tracker.revision(of: player) == revision else { continue }
                switch result {
                case .track(let track): accept(track, from: player)
                case .unavailable: unavailable = true
                case .permissionDenied: needsPermission = true
                }
            }
            self?.refreshing = false
        }
    }

    func togglePlayback() { send(.playPause) }
    func next() { send(.next) }
    func previous() { send(.previous) }

    private func send(_ command: NowPlayingCommand) {
        guard let player = currentPlayer else { return }
        isConnected = true
        preferences.setNowPlayingConnected(true)
        let perform = sendCommand
        Task { [weak self] in
            let failure = await perform(command, player)
            guard let self else { return }
            if failure == .permissionDenied {
                needsPermission = true
            } else if failure == nil {
                // The player posts its own notification; this covers a player
                // that does not.
                try? await Task.sleep(for: .milliseconds(400))
                refresh()
            }
        }
    }

    func accept(_ track: NowPlayingTrack, from player: NowPlayingPlayer) {
        tracker.accept(track, from: player)
        project()
    }

    private func runningPlayersChanged() {
        let running = runningPlayers()
        tracker.prune(running: running)
        project()
        if isConnected, !running.isEmpty { refresh() }
    }

    private func project() {
        guard let current = tracker.current else {
            title = ""
            artist = ""
            playing = false
            source = ""
            currentPlayer = nil
            return
        }
        title = current.track.title
        artist = current.track.artist
        playing = current.track.playing
        source = current.player.displayName
        currentPlayer = current.player
    }
}
