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

/// What is playing, for the notch's Now Playing section. Two sources:
///
/// 1. System media (default; Settings ▸ General ▸ Notch): the bundled BSD-3
///    MediaRemote adapter, run through `/usr/bin/perl` the way Cider does
///    (`NotchSystemMediaBridge`). It sees any app that reports Now Playing
///    (browsers, video, podcasts) and needs no Automation consent. The
///    framework it loads is private API; the user chose this in round 2.
/// 2. Music and Spotify through public API, the fallback when the adapter is
///    not bundled, the setting is off, or the adapter stops:
///    - Push, no permission: each player posts a
///      `DistributedNotificationCenter` notification when the track or state
///      changes. A track that already plays before Rafu launched appears at
///      the next change.
///    - Pull, with the person's consent: reading or controlling a player
///      sends an Apple event, which macOS gates behind Automation consent
///      (`NSAppleEventsUsageDescription`). Rafu sends none until the person
///      presses Connect, Refresh, or a transport button. After the first
///      explicit Connect, Rafu also refreshes once when the notch starts.
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
    /// The system media adapter is the active source.
    private(set) var isSystemMedia = false

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
    @ObservationIgnored private let systemMedia: (any NotchSystemMediaStreaming)?
    @ObservationIgnored private let appName: @MainActor (String) -> String
    /// The adapter stopped during this run; Music and Spotify take over
    /// until the next `stop()`.
    @ObservationIgnored private var systemMediaFailed = false
    @ObservationIgnored private var isStarted = false

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
        },
        systemMedia: (any NotchSystemMediaStreaming)? = NotchSystemMediaBridge(),
        appName: @escaping @MainActor (String) -> String = { NotchNowPlaying.applicationName($0) }
    ) {
        self.preferences = preferences
        self.readTrack = readTrack
        self.sendCommand = sendCommand
        self.runningPlayers = runningPlayers
        self.systemMedia = systemMedia
        self.appName = appName
        isConnected = preferences.isNowPlayingConnected()
    }

    /// Starts listening. Idempotent. Uses system media when it is on and
    /// bundled; otherwise registers the public observers only and sends no
    /// Apple event unless the person already connected.
    func start() {
        isStarted = true
        guard observers.isEmpty, !isSystemMedia else { return }
        if preferences.usesSystemNowPlaying(), !systemMediaFailed, let systemMedia,
            systemMedia.isAvailable
        {
            isSystemMedia = true
            unavailable = false
            needsPermission = false
            startSystemStream(systemMedia)
            return
        }
        startPublicObservers()
    }

    func stop() {
        isStarted = false
        if isSystemMedia { systemMedia?.stop() }
        isSystemMedia = false
        systemMediaFailed = false
        refreshTask?.cancel()
        refreshTask = nil
        refreshing = false
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        tracker.removeAll()
        isConnected = preferences.isNowPlayingConnected()
        clearTrack()
        project()
    }

    /// The Settings switch between system media and Music/Spotify changed.
    func sourcePreferenceDidChange() {
        guard isStarted else { return }
        stop()
        start()
    }

    /// The explicit pull. The first call is the person's consent to send
    /// Apple events to Music and Spotify.
    func connect() {
        isConnected = true
        preferences.setNowPlayingConnected(true)
        refresh()
    }

    func refresh() {
        if isSystemMedia, let systemMedia {
            // The stream pushes every change; a refresh restarts it.
            startSystemStream(systemMedia)
            return
        }
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
        if isSystemMedia {
            systemMedia?.send(command)
            return
        }
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

    /// One adapter line. Ignored unless system media is the active source.
    func acceptSystemLine(_ line: Data) {
        guard isSystemMedia, let snapshot = NotchSystemMediaSnapshot.parse(line: line) else {
            return
        }
        title = snapshot.title
        artist = snapshot.artist
        playing = snapshot.playing
        source = snapshot.bundleIdentifier.map(appName) ?? ""
        currentPlayer = nil
        unavailable = false
    }

    private func startSystemStream(_ systemMedia: any NotchSystemMediaStreaming) {
        systemMedia.start(
            onLine: { [weak self] line in self?.acceptSystemLine(line) },
            onFailure: { [weak self] in self?.systemMediaDidFail() })
    }

    /// The adapter stopped (no entitlement, crash, killed). Falls back to
    /// Music and Spotify for the rest of this run.
    private func systemMediaDidFail() {
        guard isSystemMedia else { return }
        isSystemMedia = false
        systemMediaFailed = true
        clearTrack()
        isConnected = preferences.isNowPlayingConnected()
        startPublicObservers()
    }

    private func startPublicObservers() {
        guard observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        for player in NowPlayingPlayer.allCases {
            for name in player.notificationNames {
                let token = distributed.addObserver(
                    forName: Notification.Name(name), object: nil, queue: .main
                ) { [weak self] notification in
                    // Read the Sendable track before the hop, so the
                    // Notification itself never crosses into the main actor.
                    let track = NowPlayingTrack.fromNotification(notification.userInfo)
                    MainActor.assumeIsolated { self?.accept(track, from: player) }
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

    private func runningPlayersChanged() {
        let running = runningPlayers()
        tracker.prune(running: running)
        project()
        if isConnected, !running.isEmpty { refresh() }
    }

    private func clearTrack() {
        title = ""
        artist = ""
        playing = false
        source = ""
        currentPlayer = nil
    }

    private func project() {
        guard !isSystemMedia else { return }
        guard let current = tracker.current else {
            clearTrack()
            return
        }
        title = current.track.title
        artist = current.track.artist
        playing = current.track.playing
        source = current.player.displayName
        currentPlayer = current.player
    }

    /// "Safari" for `com.apple.Safari`; the bundle id when the app is not
    /// installed. One Launch Services lookup per new id, then cached.
    static func applicationName(_ bundleIdentifier: String) -> String {
        if let cached = applicationNames[bundleIdentifier] { return cached }
        let name =
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)?
            .deletingPathExtension().lastPathComponent ?? bundleIdentifier
        if applicationNames.count >= 32 { applicationNames.removeAll() }
        applicationNames[bundleIdentifier] = name
        return name
    }

    private static var applicationNames: [String: String] = [:]
}
