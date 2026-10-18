import Foundation
import Synchronization

/// What the system-wide Now Playing source reports, from one line of the
/// MediaRemote adapter's `stream --no-diff` output:
/// `{"type":"data","diff":false,"payload":{"title":…,"artist":…,"playing":…}}`.
/// An empty payload means nothing is playing.
nonisolated struct NotchSystemMediaSnapshot: Equatable, Sendable {
    let title: String
    let artist: String
    let playing: Bool
    /// The app that plays (a browser's bundle id for a browser tab).
    let bundleIdentifier: String?

    static let empty = NotchSystemMediaSnapshot(
        title: "", artist: "", playing: false, bundleIdentifier: nil)

    /// `nil` for a line that is not a data envelope (ignored).
    static func parse(line: Data) -> NotchSystemMediaSnapshot? {
        guard let envelope = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            envelope["type"] as? String == "data"
        else { return nil }
        guard let payload = envelope["payload"] as? [String: Any], !payload.isEmpty else {
            return .empty
        }
        let bundle =
            payload["parentApplicationBundleIdentifier"] as? String
            ?? payload["bundleIdentifier"] as? String
        return NotchSystemMediaSnapshot(
            title: bounded(payload["title"] as? String),
            artist: bounded(payload["artist"] as? String),
            playing: payload["playing"] as? Bool ?? false,
            bundleIdentifier: bundle.map { String($0.prefix(255)) })
    }

    private static func bounded(_ text: String?) -> String {
        String((text ?? "").prefix(NowPlayingTrack.maximumTextLength))
    }
}

/// Splits a byte stream into newline-terminated lines with a hard bound. A
/// line longer than `maximumLineBytes` is dropped whole and the buffer
/// resynchronises at the next newline, so a hostile or broken stream can
/// never grow memory.
nonisolated struct NotchLineBuffer: Equatable, Sendable {
    static let maximumLineBytes = 256 * 1_024

    private var pending = Data()
    private var discarding = false

    init() {}

    mutating func append(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var rest = data[...]
        while let newline = rest.firstIndex(of: 0x0A) {
            let piece = rest[rest.startIndex..<newline]
            if discarding {
                discarding = false
            } else if pending.count + piece.count <= Self.maximumLineBytes {
                pending.append(contentsOf: piece)
                if !pending.isEmpty { lines.append(pending) }
            }
            pending = Data()
            rest = rest[rest.index(after: newline)...]
        }
        if !discarding {
            if pending.count + rest.count > Self.maximumLineBytes {
                pending = Data()
                discarding = true
            } else {
                pending.append(contentsOf: rest)
            }
        }
        return lines
    }
}

/// The line buffer shared with a pipe's readability handler, which
/// Foundation calls on a background queue.
nonisolated final class NotchLineAccumulator: Sendable {
    private let buffer = Mutex(NotchLineBuffer())

    func append(_ data: Data) -> [Data] {
        buffer.withLock { $0.append(data) }
    }
}

/// A source of system-wide Now Playing lines. The bridge is the production
/// source; tests inject a fake.
@MainActor
protocol NotchSystemMediaStreaming: AnyObject {
    /// The adapter files are in the app bundle.
    var isAvailable: Bool { get }
    func start(onLine: @escaping (Data) -> Void, onFailure: @escaping () -> Void)
    func send(_ command: NowPlayingCommand)
    func stop()
}

/// Runs the BSD-3 `mediaremote-adapter` (vendored in
/// `Vendor/MediaRemoteAdapter`, with code in `Contents/Helpers` and the
/// script in `Contents/Resources`) through
/// `/usr/bin/perl`, the way Cider does. Every process gets an argument
/// array, never a shell string. A generation token makes output and exits
/// from a stopped stream inert. stderr is discarded and nothing is logged.
final class NotchSystemMediaBridge: NotchSystemMediaStreaming {
    static let perl = URL(fileURLWithPath: "/usr/bin/perl")
    /// A transport command process is ended after this long.
    static let commandTimeout: Duration = .seconds(5)

    private let helpers: URL
    private let resources: URL
    private var process: Process?
    private var generation = 0
    private var onLine: ((Data) -> Void)?
    private var onFailure: (() -> Void)?
    private var commandProcesses: [Int: Process] = [:]
    private var commandCounter = 0
    private var availability: Bool?

    init(
        helpers: URL = Bundle.main.bundleURL.appending(path: "Contents/Helpers"),
        resources: URL = Bundle.main.bundleURL.appending(path: "Contents/Resources")
    ) {
        self.helpers = helpers
        self.resources = resources
    }

    /// Three `stat` calls, made once per bridge.
    var isAvailable: Bool {
        if let availability { return availability }
        let fileManager = FileManager.default
        let found =
            fileManager.isExecutableFile(atPath: Self.perl.path)
            && fileManager.fileExists(atPath: script.path)
            && fileManager.fileExists(
                atPath: framework.appending(path: "MediaRemoteAdapter").path)
        availability = found
        return found
    }

    private var script: URL { resources.appending(path: "mediaremote-adapter.pl") }
    private var framework: URL { helpers.appending(path: "MediaRemoteAdapter.framework") }

    func start(onLine: @escaping (Data) -> Void, onFailure: @escaping () -> Void) {
        stop()
        self.onLine = onLine
        self.onFailure = onFailure
        let token = generation
        let process = Process()
        process.executableURL = Self.perl
        process.arguments = [
            script.path, framework.path, "stream", "--no-diff", "--debounce=150", "--no-artwork",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        Self.install(on: process, pipe: pipe, bridge: self, token: token)
        do {
            try process.run()
            self.process = process
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            self.onFailure = nil
            onFailure()
        }
    }

    func send(_ command: NowPlayingCommand) {
        let process = Process()
        process.executableURL = Self.perl
        process.arguments = [script.path, framework.path, "send", String(Self.code(command))]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        commandCounter += 1
        let id = commandCounter
        Self.installCommandExit(on: process, bridge: self, id: id)
        guard (try? process.run()) != nil else { return }
        commandProcesses[id] = process
        Task { [weak self] in
            try? await Task.sleep(for: Self.commandTimeout)
            self?.endCommand(id, terminate: true)
        }
    }

    func stop() {
        generation += 1
        onLine = nil
        onFailure = nil
        if let pipe = process?.standardOutput as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        if process?.isRunning == true { process?.terminate() }
        process = nil
    }

    /// The MediaRemote command ids the adapter's `send` takes.
    nonisolated static func code(_ command: NowPlayingCommand) -> Int {
        switch command {
        case .playPause: 2
        case .next: 4
        case .previous: 5
        }
    }

    // MARK: - Callbacks

    fileprivate func deliver(_ lines: [Data], token: Int) {
        guard token == generation, let onLine else { return }
        for line in lines { onLine(line) }
    }

    fileprivate func streamDidEnd(token: Int) {
        guard token == generation else { return }
        let failure = onFailure
        process = nil
        onLine = nil
        onFailure = nil
        failure?()
    }

    fileprivate func endCommand(_ id: Int, terminate: Bool) {
        guard let process = commandProcesses.removeValue(forKey: id) else { return }
        if terminate, process.isRunning { process.terminate() }
    }

    /// Builds the pipe and exit handlers outside any actor, so the closures
    /// Foundation calls on its own queues are never main-actor-inferred.
    /// Each hops to the main queue in order and checks the generation.
    nonisolated private static func install(
        on process: Process, pipe: Pipe, bridge: NotchSystemMediaBridge, token: Int
    ) {
        let accumulator = NotchLineAccumulator()
        pipe.fileHandleForReading.readabilityHandler = { [weak bridge] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let lines = accumulator.append(data)
            guard !lines.isEmpty else { return }
            let target = bridge
            DispatchQueue.main.async {
                MainActor.assumeIsolated { target?.deliver(lines, token: token) }
            }
        }
        process.terminationHandler = { [weak bridge] _ in
            let target = bridge
            DispatchQueue.main.async {
                MainActor.assumeIsolated { target?.streamDidEnd(token: token) }
            }
        }
    }

    nonisolated private static func installCommandExit(
        on process: Process, bridge: NotchSystemMediaBridge, id: Int
    ) {
        process.terminationHandler = { [weak bridge] _ in
            let target = bridge
            DispatchQueue.main.async {
                MainActor.assumeIsolated { target?.endCommand(id, terminate: false) }
            }
        }
    }
}
