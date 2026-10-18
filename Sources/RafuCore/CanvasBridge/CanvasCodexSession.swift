import Darwin
import Foundation
import Synchronization

/// Owns the server used by one visible Codex terminal. It never starts a model turn.
public nonisolated enum CanvasCodexSession {
    public enum SessionError: Error, Equatable {
        case invalidEndpoint
        case invalidMessage
        case launchFailed
        case untrustedExecutable
        case deliveryFailed
        case deliveryTimedOut
    }

    public static func run(
        executable: String, arguments: [String], environment: [String: String],
        serverArguments: [String]
    ) -> Int32 {
        var phase = StartupPhase.directory
        let directory = "/tmp/rafu-cdx-\(UUID().uuidString)"
        let socket = directory + "/socket"
        let endpoint = "unix://" + socket
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            reportFailure(phase)
            return 126
        }
        defer { try? FileManager.default.removeItem(atPath: directory) }

        // Install the directory watcher before spawn, so bind cannot race its registration.
        phase = .watcher
        let descriptor = Darwin.open(directory, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            reportFailure(phase)
            return 126
        }
        let ready = DispatchSemaphore(value: 0)
        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write, queue: .global()
        )
        watcher.setEventHandler {
            if socketIsOwned(socket) { ready.signal() }
        }
        watcher.setCancelHandler { Darwin.close(descriptor) }
        watcher.resume()
        defer { watcher.cancel() }
        // The endpoint and executable are explicit MCP values. A shared daemon cannot
        // supply the terminal-specific environment of a later client.
        let additions = [
            "-c", "mcp_servers.rafu.env.RAFU_CANVAS_CODEX_ENDPOINT=\(quoted(endpoint))",
            "-c", "mcp_servers.rafu.env.RAFU_CANVAS_CODEX_EXECUTABLE=\(quoted(executable))",
        ]
        // The TUI shares the terminal foreground process group. Its SIGINT disposition
        // is reset at spawn. Only the supervisor ignores the terminal's Ctrl-C signal.
        let control = Mutex(RunControl())
        let oldInterrupt = Darwin.signal(SIGINT, SIG_IGN)
        let oldQuit = Darwin.signal(SIGQUIT, SIG_IGN)
        let oldTerminate = Darwin.signal(SIGTERM, SIG_IGN)
        let oldHangup = Darwin.signal(SIGHUP, SIG_IGN)
        let signalSources = [SIGINT, SIGQUIT, SIGTERM, SIGHUP].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                control.withLock { state in
                    // With a TUI, terminal-generated INT/QUIT already reaches it.
                    if number == SIGINT || number == SIGQUIT, state.terminal != nil { return }
                    state.stopSignal = number
                    if let terminal = state.terminal { Darwin.kill(terminal, number) }
                    if let server = state.server { Darwin.kill(-server, SIGTERM) }
                }
                ready.signal()
            }
            source.resume()
            return source
        }
        defer {
            for source in signalSources { source.cancel() }
            Darwin.signal(SIGINT, oldInterrupt)
            Darwin.signal(SIGQUIT, oldQuit)
            Darwin.signal(SIGTERM, oldTerminate)
            Darwin.signal(SIGHUP, oldHangup)
        }
        let server: pid_t
        phase = .server
        do {
            server = try spawn(
                executable: executable,
                arguments: ["app-server", "--listen", endpoint] + serverArguments + additions,
                environment: environment, isolatedGroup: true, discardIO: true
            )
        } catch {
            reportFailure(phase)
            return 126
        }
        control.withLock { state in
            state.server = server
            if state.stopSignal != nil { Darwin.kill(-server, SIGTERM) }
        }
        defer {
            control.withLock { $0.server = nil }
            stopServer(server)
        }
        phase = .socket
        if !socketIsOwned(socket), ready.wait(timeout: .now() + 15) == .timedOut,
            !socketIsOwned(socket)
        {
            reportFailure(phase)
            return 126
        }
        if let signal = control.withLock({ $0.stopSignal }) { return 128 + signal }
        guard socketIsOwned(socket) else {
            reportFailure(phase)
            return 126
        }

        do {
            var terminalArguments = arguments
            var preparedThread: String?
            if shouldPrepareThread(arguments) {
                phase = .control
                let rpc = try CanvasCodexRPC(endpoint: endpoint)
                phase = .thread
                let thread = try rpc.createThread(cwd: workingDirectory(arguments))
                guard let token = environment["RAFU_CANVAS_TOKEN"],
                    let bridgeSocket = environment["RAFU_CANVAS_SOCKET"]
                else { throw SessionError.launchFailed }
                phase = .binding
                let request = CanvasBridgeRequest(
                    token: token, operation: "bind", provider: "codex", threadID: thread,
                    endpoint: endpoint, executable: executable
                )
                let client = LauncherIPCClient(
                    socketURL: URL(fileURLWithPath: bridgeSocket), timeoutSeconds: 5)
                let response = try client.exchange(
                    LauncherIPCEnvelope(kind: .canvasBridge, canvasBridge: request))
                guard case .canvasBridge(let result) = response, result.error == nil else {
                    throw SessionError.launchFailed
                }
                terminalArguments = ["resume", thread] + arguments
                preparedThread = thread
            }
            guard let token = environment["RAFU_CANVAS_TOKEN"],
                let bridgeSocket = environment["RAFU_CANVAS_SOCKET"]
            else {
                throw SessionError.launchFailed
            }
            phase = .proxy
            let frontend = directory + "/terminal"
            let proxy = try CanvasCodexProxy(
                frontend: frontend, backend: endpoint, threadID: preparedThread ?? ""
            ) { reason in
                let client = LauncherIPCClient(
                    socketURL: URL(fileURLWithPath: bridgeSocket), timeoutSeconds: 5)
                let request = CanvasBridgeRequest(
                    token: token, operation: "suspend", provider: "codex", endpoint: endpoint,
                    reason: reason.rawValue)
                let response = try client.exchange(
                    LauncherIPCEnvelope(kind: .canvasBridge, canvasBridge: request))
                guard case .canvasBridge(let result) = response, result.error == nil else {
                    throw SessionError.deliveryFailed
                }
            }
            defer { proxy.stop() }
            phase = .terminal
            let terminal = try spawn(
                executable: executable,
                arguments: ["--remote", "unix://" + frontend] + terminalArguments,
                environment: environment, isolatedGroup: false, discardIO: false
            )
            control.withLock { state in
                state.terminal = terminal
                if let signal = state.stopSignal { Darwin.kill(terminal, signal) }
            }
            let exited = DispatchSemaphore(value: 0)
            let terminalExit = DispatchSource.makeProcessSource(
                identifier: terminal, eventMask: .exit, queue: .global())
            terminalExit.setEventHandler { exited.signal() }
            terminalExit.resume()
            defer { terminalExit.cancel() }
            let serverExit = DispatchSource.makeProcessSource(
                identifier: server, eventMask: .exit, queue: .global())
            serverExit.setEventHandler {
                control.withLock { state in
                    if let terminal = state.terminal { Darwin.kill(terminal, SIGTERM) }
                }
            }
            serverExit.resume()
            defer { serverExit.cancel() }
            exited.wait()
            control.withLock { $0.terminal = nil }
            return waitForExit(terminal)
        } catch {
            reportFailure(phase)
            return 126
        }
    }

    /// Enqueues into the exact server and thread used by the terminal. Output is
    /// discarded at the descriptor, so provider errors cannot retain message text.
    @concurrent
    public static func send(executable: String, endpoint: String, threadID: String, text: String)
        async throws
    {
        let approvedPaths = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                ".local/bin/codex"
            ).path,
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex",
        ]
        try await sendApproved(
            executable: executable, endpoint: endpoint, threadID: threadID, text: text,
            approvedPaths: approvedPaths
        )
    }

    @concurrent
    static func sendApproved(
        executable: String, endpoint: String, threadID: String, text: String,
        approvedPaths: [String]
    ) async throws {
        try validateExecutable(executable, approvedPaths: approvedPaths)
        try validateEndpoint(endpoint)
        guard UUID(uuidString: threadID) != nil, !text.isEmpty, text.utf8.count <= 32_768,
            !text.utf8.contains(0)
        else {
            throw SessionError.invalidMessage
        }
        let control = Mutex(DeliveryControl())
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let child = try spawn(
                executable: executable,
                arguments: [
                    "queue", "--remote", endpoint, "--thread", threadID, "--message", text,
                ],
                environment: ProcessInfo.processInfo.environment, isolatedGroup: true,
                discardIO: true
            )
            control.withLock { state in
                state.pid = child
                if state.cancelled { Darwin.kill(-child, SIGKILL) }
            }
            let deadline = DispatchSource.makeTimerSource(queue: .global())
            deadline.setEventHandler {
                control.withLock { state in
                    guard state.pid == child else { return }
                    state.timedOut = true
                    Darwin.kill(-child, SIGKILL)
                }
            }
            deadline.schedule(deadline: .now() + 15)
            deadline.resume()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let exitSource = DispatchSource.makeProcessSource(
                    identifier: child, eventMask: .exit, queue: .global())
                exitSource.setEventHandler {
                    exitSource.cancel()
                    continuation.resume()
                }
                exitSource.resume()
            }
            deadline.cancel()
            // Clear the PID before reaping. A timer/cancellation callback must never
            // signal a recycled PID after waitpid releases the child identifier.
            let timedOut = control.withLock { state in
                state.pid = nil
                return state.timedOut
            }
            let status = waitForExit(child)
            try Task.checkCancellation()
            if timedOut { throw SessionError.deliveryTimedOut }
            guard status == 0 else { throw SessionError.deliveryFailed }
        } onCancel: {
            control.withLock { state in
                state.cancelled = true
                if let pid = state.pid { Darwin.kill(-pid, SIGKILL) }
            }
        }
    }

    static func validateExecutable(_ executable: String, approvedPaths: [String]) throws {
        guard executable.hasPrefix("/"), !executable.utf8.contains(0) else {
            throw SessionError.untrustedExecutable
        }
        let candidate = URL(fileURLWithPath: executable).standardizedFileURL
            .resolvingSymlinksInPath().path
        guard
            approvedPaths.contains(where: {
                URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
                    == candidate
                    && FileManager.default.isExecutableFile(atPath: $0)
            })
        else { throw SessionError.untrustedExecutable }
    }

    /// Reject arbitrary provider endpoints and paths outside a private launch directory.
    public static func validateEndpoint(_ endpoint: String) throws {
        let prefix = "unix:///tmp/rafu-cdx-"
        guard endpoint.hasPrefix(prefix), endpoint.hasSuffix("/socket") else {
            throw SessionError.invalidEndpoint
        }
        let suffix = endpoint.dropFirst(prefix.count).dropLast("/socket".count)
        guard UUID(uuidString: String(suffix)) != nil else { throw SessionError.invalidEndpoint }
        let path = String(endpoint.dropFirst("unix://".count))
        let directory = String(path.dropLast("/socket".count))
        var metadata = stat()
        guard lstat(directory, &metadata) == 0,
            metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_mode & 0o777 == 0o700, socketIsOwned(path)
        else { throw SessionError.invalidEndpoint }
    }

    static func shouldPrepareThread(_ arguments: [String]) -> Bool {
        let valued: Set<String> = [
            "-c", "--config", "-C", "--cd", "-m", "--model", "-p", "--profile",
            "-a", "--ask-for-approval", "-s", "--sandbox", "--add-dir", "--enable", "--disable",
            "-i", "--image",
        ]
        var skip = false
        for argument in arguments {
            if skip {
                skip = false
                continue
            }
            if valued.contains(argument) {
                skip = true
                continue
            }
            if argument.hasPrefix("-") { continue }
            return argument != "resume" && argument != "fork" && argument != "agents"
        }
        return true
    }

    private static func workingDirectory(_ arguments: [String]) -> String {
        for (index, argument) in arguments.enumerated() {
            if argument == "-C" || argument == "--cd", index + 1 < arguments.count {
                return URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL.path
            }
            if argument.hasPrefix("--cd=") {
                return URL(fileURLWithPath: String(argument.dropFirst("--cd=".count)))
                    .standardizedFileURL.path
            }
        }
        return FileManager.default.currentDirectoryPath
    }

    private struct RunControl: Sendable {
        var server: pid_t?
        var terminal: pid_t?
        var stopSignal: Int32?
    }

    private struct DeliveryControl: Sendable {
        var pid: pid_t?
        var cancelled = false
        var timedOut = false
    }

    private static func socketIsOwned(_ path: String) -> Bool {
        var metadata = stat()
        guard lstat(path, &metadata) == 0, metadata.st_uid == getuid() else { return false }
        if metadata.st_mode & S_IFMT == S_IFSOCK { return true }
        // Codex 0.163 publishes a custom Unix listener as a same-user symlink
        // to its actual socket. Check both identities, while the enclosing
        // private directory protects the advertised endpoint from replacement.
        guard metadata.st_mode & S_IFMT == S_IFLNK else { return false }
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
            destination.hasPrefix("/")
        else { return false }
        guard
            destination.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
            let directParent = parentPath(destination),
            let parent = canonicalPath(directParent),
            let temporaryRootPath = canonicalPath("/tmp")
        else { return false }
        // Foundation file URLs can shorten /private/tmp back to /tmp even after
        // resolving symlinks. POSIX realpath supplies the actual filesystem path.
        let lexicalParent =
            directParent.hasPrefix("/tmp/")
            ? temporaryRootPath + directParent.dropFirst("/tmp".count) : directParent
        guard lexicalParent == parent else { return false }
        var target = stat()
        guard lstat(destination, &target) == 0, target.st_uid == getuid(),
            target.st_mode & S_IFMT == S_IFSOCK,
            let advertisedParent = parentPath(path),
            let advertisedDirectory = canonicalPath(advertisedParent)
        else { return false }
        var directory = stat()
        guard lstat(parent, &directory) == 0, directory.st_uid == getuid(),
            directory.st_mode & S_IFMT == S_IFDIR, directory.st_mode & 0o077 == 0
        else { return false }
        if parent == advertisedDirectory || parent.hasPrefix(advertisedDirectory + "/") {
            return true
        }
        // Codex places the actual socket's private directory directly below the
        // root-owned sticky temporary root. Reject arbitrary public ancestors.
        guard parentPath(parent) == temporaryRootPath else { return false }
        var temporaryRoot = stat()
        return lstat(temporaryRootPath, &temporaryRoot) == 0 && temporaryRoot.st_uid == 0
            && temporaryRoot.st_mode & S_IFMT == S_IFDIR && temporaryRoot.st_mode & 0o1000 != 0
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func parentPath(_ path: String) -> String? {
        guard let separator = path.lastIndex(of: "/"), separator != path.startIndex else {
            return nil
        }
        return String(path[..<separator])
    }

    private static func quoted(_ text: String) -> String {
        // JSON basic strings are also TOML basic strings for these generated paths.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(text), as: UTF8.self)
    }

    private static func spawn(
        executable: String, arguments: [String], environment: [String: String], isolatedGroup: Bool,
        discardIO: Bool
    ) throws -> pid_t {
        guard executable.hasPrefix("/"), !executable.utf8.contains(0),
            arguments.allSatisfy({ !$0.utf8.contains(0) }),
            environment.allSatisfy({ !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }),
            FileManager.default.isExecutableFile(atPath: executable)
        else {
            throw SessionError.launchFailed
        }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp =
            environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw SessionError.launchFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw SessionError.launchFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for number in [SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGPIPE] { sigaddset(&defaults, number) }
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)
        var flags = Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        if isolatedGroup {
            flags |= Int16(POSIX_SPAWN_SETPGROUP)
            posix_spawnattr_setpgroup(&attributes, 0)
        }
        posix_spawnattr_setflags(&attributes, flags)
        if discardIO {
            for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
                guard
                    posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", O_RDWR, 0)
                        == 0
                else {
                    throw SessionError.launchFailed
                }
            }
        }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { argumentsBuffer in
            envp.withUnsafeBufferPointer { environmentBuffer in
                posix_spawn(
                    &pid, executable, &actions, &attributes, argumentsBuffer.baseAddress!,
                    environmentBuffer.baseAddress!)
            }
        }
        guard result == 0 else { throw SessionError.launchFailed }
        return pid
    }

    private static func waitForExit(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
        guard result == pid else { return 126 }
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    private static func stopServer(_ pid: pid_t) {
        let stopped = DispatchSemaphore(value: 0)
        let source = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { stopped.signal() }
        source.resume()
        Darwin.kill(-pid, SIGTERM)
        if stopped.wait(timeout: .now() + 2) == .timedOut { Darwin.kill(-pid, SIGKILL) }
        source.cancel()
        _ = waitForExit(pid)
    }

    private enum StartupPhase {
        case directory, watcher, server, socket, control, thread, binding, proxy, terminal

        var message: String {
            switch self {
            case .directory: "The private Codex directory could not be created."
            case .watcher: "The private Codex socket could not be watched."
            case .server: "The private Codex server could not start."
            case .socket: "Codex did not open its private socket."
            case .control: "Codex did not complete the control connection."
            case .thread: "Codex did not prepare the terminal session."
            case .binding: "Ensemble could not bind the Codex session."
            case .proxy: "The Codex terminal transport could not start."
            case .terminal: "The Codex terminal interface could not start."
            }
        }
    }

    private static func reportFailure(_ phase: StartupPhase) {
        FileHandle.standardError.write(Data("Rafu: \(phase.message)\n".utf8))
    }
}
