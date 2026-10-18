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

    public static func plan(
        provider: String, arguments: [String], environment: [String: String]
    ) throws -> CanvasBridgeAgentLaunch {
        guard provider == "claude" || provider == "codex" else {
            throw LaunchError.unsupportedProvider
        }
        let executable = try resolve(provider: provider, environment: environment)
        var launch = CanvasBridgeAgentLaunch(
            executable: executable, arguments: arguments, environment: environment)
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
            launch.arguments =
                [
                    "--mcp-config", configURL.path,
                    "--dangerously-load-development-channels", "server:rafu",
                ] + arguments
            launch.environment["MCP_PROTOCOL_NEGOTIATION"] = "legacy"
        } else {
            launch.arguments =
                [
                    "-c", "mcp_servers.rafu.command=\(try quoted(cli))",
                    "-c", "mcp_servers.rafu.args=[\"_canvas-mcp\",\"codex\"]",
                    "-c", "mcp_servers.rafu.env.RAFU_CANVAS_TOKEN=\(try quoted(token))",
                    "-c", "mcp_servers.rafu.env.RAFU_CANVAS_SOCKET=\(try quoted(socket))",
                ] + arguments
        }
        return launch
    }

    /// Replaces only this CLI process. Failure returns a shell-compatible status without printing secrets.
    public static func run(
        provider: String, arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int32 {
        do {
            let launch = try plan(
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
            FileHandle.standardError.write(
                Data("Rafu: The agent executable could not start.\n".utf8))
            return 126
        } catch {
            FileHandle.standardError.write(
                Data("Rafu: The Ensemble agent launch could not be prepared.\n".utf8))
            return 127
        }
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
            guard directory != wrapper else { continue }
            let candidate = directory.appendingPathComponent(provider).resolvingSymlinksInPath()
            guard candidate.deletingLastPathComponent() != wrapper,
                FileManager.default.isExecutableFile(atPath: candidate.path)
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
