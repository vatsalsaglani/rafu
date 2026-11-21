import Darwin
import Foundation

public nonisolated struct CanvasBridgeAgentLaunch: Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
}

/// Builds an explicit provider launch. This does not invoke a shell or change provider permissions.
public nonisolated enum CanvasBridgeLaunch {
    public enum LaunchError: Error {
        case unsupportedProvider
        case missingBridgeEnvironment
        case executableNotFound
    }

    /// Every Rafu terminal puts its private wrapper folder on `PATH`. The folder name starts
    /// with this prefix, so another terminal's folder can be recognized by name.
    public static let wrapperDirectoryPrefix = "rafu-canvas-shell-"

    /// Names the process that started this launcher. `execve` keeps the pid, so a second
    /// entry in the same pid is a loop through a wrapper, never a nested agent start.
    public static let launchPIDKey = "RAFU_CANVAS_LAUNCH_PID"

    /// The exact text of the `claude`/`codex` wrapper in a terminal's private folder.
    /// The terminal bootstrap writes it and `resolve` recognizes it: one source of truth.
    public static func wrapperScript(provider: String) -> String {
        "#!/bin/sh\nexec \"$RAFU_CANVAS_BRIDGE_CLI\" _canvas-agent \(provider) \"$@\""
    }

    /// True when `environment` shows that this very process already ran the launcher.
    static func isReentry(environment: [String: String], pid: Int32) -> Bool {
        environment[launchPIDKey] == String(pid)
    }

    /// True when the file is a Rafu wrapper, whatever folder or name holds it.
    /// Reads at most 256 bytes.
    static func isRafuWrapper(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256) else { return false }
        let text = String(decoding: data, as: UTF8.self)
        return ["claude", "codex"].contains { provider in
            let script = wrapperScript(provider: provider)
            return text == script || text == script + "\n"
        }
    }

    public static func plan(
        provider: String, arguments: [String], environment: [String: String]
    ) throws -> CanvasBridgeAgentLaunch {
        guard provider == "claude" || provider == "codex" else {
            throw LaunchError.unsupportedProvider
        }
        let executable = try resolve(provider: provider, environment: environment)
        var launch = CanvasBridgeAgentLaunch(
            executable: executable, arguments: arguments, environment: environment)
        launch.environment[launchPIDKey] = String(getpid())
        guard shouldAttach(provider: provider, arguments: arguments) else { return launch }
        guard let token = environment["RAFU_CANVAS_TOKEN"], !token.isEmpty,
            let cli = environment["RAFU_CANVAS_BRIDGE_CLI"], cli.hasPrefix("/"),
            let socket = environment["RAFU_CANVAS_SOCKET"], socket.hasPrefix("/"),
            let directory = environment["RAFU_CANVAS_WRAPPER_DIR"]
        else { throw LaunchError.missingBridgeEnvironment }
        let bridgeEnvironment = ["RAFU_CANVAS_TOKEN": token, "RAFU_CANVAS_SOCKET": socket]
        if provider == "claude" {
            let config: [String: Any] = [
                "mcpServers": [
                    "rafu": [
                        "type": "stdio", "command": cli, "args": ["_canvas-mcp", "claude"],
                        "env": bridgeEnvironment.merging(["MCP_PROTOCOL_NEGOTIATION": "legacy"]) {
                            _, value in value
                        },
                    ]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
            let configURL = URL(fileURLWithPath: directory).appendingPathComponent(
                "claude-mcp.json")
            // The parent owns this private directory and removes it when the terminal closes.
            try data.write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            launch.arguments = claudeBridgeArguments(configPath: configURL.path) + arguments
            launch.environment["MCP_PROTOCOL_NEGOTIATION"] = "legacy"
        } else {
            launch.arguments =
                [
                    "-c", "mcp_servers.rafu.command=\(try quoted(cli))",
                    "-c", "mcp_servers.rafu.args=[\"_canvas-mcp\",\"codex\"]",
                    "-c", "mcp_servers.rafu.env.RAFU_CANVAS_TOKEN=\(try quoted(token))",
                    "-c", "mcp_servers.rafu.env.RAFU_CANVAS_SOCKET=\(try quoted(socket))",
                    // Rafu's own tool server only. Ensemble Agent control already
                    // decides every call, so Codex must not ask a second time. The
                    // flags reach this terminal's private app-server, never
                    // ~/.codex/config.toml, and no other MCP server is affected.
                    "-c", "mcp_servers.rafu.default_tools_approval_mode=\(try quoted("approve"))",
                ] + arguments
        }
        return launch
    }

    /// Replaces only this CLI process. Failure returns a shell-compatible status without printing secrets.
    public static func run(
        provider: String, arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int32 {
        if isReentry(environment: environment, pid: getpid()) {
            try? FileHandle.standardError.write(
                contentsOf: Data(
                    ("Rafu: The \(provider) command leads back to Rafu's launcher. "
                        + "Open a new terminal; if this repeats, remove old "
                        + "rafu-canvas-shell folders from PATH.\n").utf8))
            return 127
        }
        do {
            let launch = try plan(
                provider: provider, arguments: arguments, environment: environment)
            announceClaudeLaunch(
                provider: provider, arguments: arguments, environment: environment)
            if provider == "codex", shouldAttach(provider: provider, arguments: arguments) {
                return CanvasCodexSession.run(
                    executable: launch.executable, arguments: arguments,
                    environment: launch.environment,
                    serverArguments: Array(launch.arguments.dropLast(arguments.count))
                )
            }
            let argv = ([launch.executable] + launch.arguments).map { strdup($0) } + [nil]
            let envp =
                launch.environment.sorted { $0.key < $1.key }.map {
                    strdup("\($0.key)=\($0.value)")
                } + [nil]
            defer {
                for pointer in argv { free(pointer) }
                for pointer in envp { free(pointer) }
            }
            argv.withUnsafeBufferPointer { argumentBuffer in
                envp.withUnsafeBufferPointer { environmentBuffer in
                    _ = execve(
                        launch.executable, argumentBuffer.baseAddress!,
                        environmentBuffer.baseAddress!)
                }
            }
            try? FileHandle.standardError.write(
                contentsOf:
                    Data("Rafu: The agent executable could not start.\n".utf8))
            return 126
        } catch {
            try? FileHandle.standardError.write(
                contentsOf:
                    Data("Rafu: The Ensemble agent launch could not be prepared.\n".utf8))
            return 127
        }
    }

    /// Tells the app that this terminal is about to run Claude with Rafu's channel
    /// flag, so the app can watch for Claude's channel dialog (`CanvasChannelPrompt`).
    /// Best effort: a closed app, a refusal, or a slow answer (one second at most)
    /// is ignored and never changes the launch. It sends no terminal content.
    private static func announceClaudeLaunch(
        provider: String, arguments: [String], environment: [String: String]
    ) {
        guard
            let request = CanvasChannelPrompt.launchRequest(
                provider: provider, arguments: arguments, environment: environment),
            let socket = environment["RAFU_CANVAS_SOCKET"], socket.hasPrefix("/")
        else { return }
        let client = LauncherIPCClient(socketURL: URL(fileURLWithPath: socket), timeoutSeconds: 1)
        _ = try? client.exchange(LauncherIPCEnvelope(kind: .canvasBridge, canvasBridge: request))
    }

    /// Claude's `--mcp-config` and `--dangerously-load-development-channels` are variadic.
    /// The spaced form takes every later non-option token, so a user prompt became a
    /// channel entry. The `--flag=value` form takes exactly one value and never reads
    /// the next argument, so the user's arguments keep their own meaning.
    static func claudeBridgeArguments(configPath: String) -> [String] {
        [
            "--mcp-config=\(configPath)",
            "--dangerously-load-development-channels=server:rafu",
        ]
    }

    public static func shouldAttach(provider: String, arguments: [String]) -> Bool {
        if arguments.contains("--help") || arguments.contains("-h")
            || arguments.contains("--version")
        {
            return false
        }
        if provider == "claude" {
            if arguments.contains(where: {
                $0 == "-p" || $0 == "--print" || $0.hasPrefix("--print=")
            }) {
                return false
            }
            let subcommands: Set<String> = [
                "auth", "mcp", "plugin", "plugins", "doctor", "install", "update", "upgrade",
                "setup-token", "help",
            ]
            return !subcommands.contains(firstPositionalArgument(arguments) ?? "")
        }
        let subcommands: Set<String> = [
            "exec", "e", "review", "login", "logout", "mcp", "mcp-server", "app-server",
            "completion", "sandbox", "debug", "apply", "a", "cloud", "features", "help", "app",
            "resume", "fork", "agents",
        ]
        return !subcommands.contains(firstPositionalArgument(arguments) ?? "")
    }

    private static func firstPositionalArgument(_ arguments: [String]) -> String? {
        let valuedOptions: Set<String> = [
            "--model", "-m", "--profile", "-p", "--config", "-c",
            "--cd", "-C", "--add-dir", "--permission-mode", "--mcp-config", "--system-prompt",
            "--append-system-prompt", "--allowedTools", "--disallowedTools",
            "-a", "--ask-for-approval", "-s", "--sandbox", "--enable", "--disable", "-i", "--image",
        ]
        var skipValue = false
        for argument in arguments {
            if skipValue {
                skipValue = false
                continue
            }
            if argument == "--" { return nil }
            if valuedOptions.contains(argument) {
                skipValue = true
                continue
            }
            if argument.hasPrefix("-") { continue }
            return argument
        }
        return nil
    }

    private static func resolve(provider: String, environment: [String: String]) throws -> String {
        let wrapper = environment["RAFU_CANVAS_WRAPPER_DIR"].map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL
        }
        for entry in (environment["PATH"] ?? "/usr/bin:/bin").split(
            separator: ":", omittingEmptySubsequences: false)
        {
            let directory = URL(fileURLWithPath: entry.isEmpty ? "." : String(entry))
                .resolvingSymlinksInPath().standardizedFileURL
            guard directory != wrapper,
                !directory.lastPathComponent.hasPrefix(wrapperDirectoryPrefix)
            else { continue }
            let candidate = directory.appendingPathComponent(provider).resolvingSymlinksInPath()
            guard candidate.deletingLastPathComponent() != wrapper,
                FileManager.default.isExecutableFile(atPath: candidate.path),
                !isRafuWrapper(candidate)
            else { continue }
            return candidate.path
        }
        throw LaunchError.executableNotFound
    }

    private static func quoted(_ value: String) throws -> String {
        // Codex parses these values as TOML. JSON's optional \/ escape is not valid TOML.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
