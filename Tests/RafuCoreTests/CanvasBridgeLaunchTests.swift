import Foundation
import Testing

@testable import RafuCore

struct CanvasBridgeLaunchTests {
    @Test func noninteractiveCommandsKeepOriginalArguments() {
        #expect(
            !CanvasBridgeLaunch.shouldAttach(provider: "claude", arguments: ["--print", "hello"]))
        #expect(!CanvasBridgeLaunch.shouldAttach(provider: "claude", arguments: ["mcp", "list"]))
        #expect(!CanvasBridgeLaunch.shouldAttach(provider: "codex", arguments: ["exec", "hello"]))
        #expect(!CanvasBridgeLaunch.shouldAttach(provider: "codex", arguments: ["--version"]))
        #expect(CanvasBridgeLaunch.shouldAttach(provider: "claude", arguments: ["--resume"]))
        #expect(
            !CanvasBridgeLaunch.shouldAttach(provider: "codex", arguments: ["resume", "--last"]))
        #expect(
            CanvasBridgeLaunch.shouldAttach(provider: "codex", arguments: ["review this change"]))
        #expect(
            !CanvasBridgeLaunch.shouldAttach(
                provider: "codex", arguments: ["--model", "example", "exec", "hello"]))
    }

    @Test func explicitCodexNavigationKeepsOriginalLaunchWithoutBridgeConfiguration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for arguments in [
            ["resume", "--last"], ["fork", "session-id"], ["agents"],
            ["--sandbox", "workspace-write", "resume", "session-id"],
            ["-c", "model=\"example\"", "fork", "--last"],
        ] {
            let launch = try CanvasBridgeLaunch.plan(
                provider: "codex", arguments: arguments, environment: fixture.environment)
            #expect(!CanvasBridgeLaunch.shouldAttach(provider: "codex", arguments: arguments))
            #expect(launch.arguments == arguments)
            #expect(launch.environment == fixture.environment)
            #expect(
                launch.executable
                    == fixture.real.appendingPathComponent("codex").resolvingSymlinksInPath().path)
        }
    }

    @Test func launchSkipsWrapperAndPreservesArgumentBoundaries() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let arguments = ["--model", "model name", "a prompt; $(literal)"]
        let launch = try CanvasBridgeLaunch.plan(
            provider: "codex", arguments: arguments, environment: fixture.environment)
        #expect(
            launch.executable
                == fixture.real.appendingPathComponent("codex").resolvingSymlinksInPath().path)
        #expect(Array(launch.arguments.suffix(arguments.count)) == arguments)
        #expect(launch.arguments.contains("mcp_servers.rafu.args=[\"_canvas-mcp\",\"codex\"]"))
        #expect(launch.arguments.contains("mcp_servers.rafu.command=\"/private/rafu\""))
        #expect(!launch.arguments.contains(where: { $0.contains("\\/") }))
        #expect(
            launch.arguments.contains(
                "mcp_servers.rafu.env.RAFU_CANVAS_SOCKET=\"/private/test.sock\""))
    }

    @Test func claudeConfigIsPrivateAndContainsExplicitEnvironment() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let launch = try CanvasBridgeLaunch.plan(
            provider: "claude", arguments: [], environment: fixture.environment)
        let url = fixture.wrapper.appendingPathComponent("claude-mcp.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let servers = object?["mcpServers"] as? [String: Any]
        let server = servers?["rafu"] as? [String: Any]
        let environment = server?["env"] as? [String: String]
        #expect(
            environment == [
                "RAFU_CANVAS_TOKEN": "test-token", "RAFU_CANVAS_SOCKET": "/private/test.sock",
                "MCP_PROTOCOL_NEGOTIATION": "legacy",
            ])
        #expect(launch.environment["MCP_PROTOCOL_NEGOTIATION"] == "legacy")
        #expect(!launch.arguments.contains("test-token"))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    /// Claude Code 2.1.304 rejected `claude 'prompt'` because the prompt followed
    /// `--dangerously-load-development-channels server:rafu` and became a second entry.
    @Test func claudeBridgeFlagsNeverTakeAUserArgument() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let config = fixture.wrapper.appendingPathComponent("claude-mcp.json").path
        let prompt = "Read the note titled \"Local Keycloak – brief\"; run $(literal) 'as is'"
        let cases: [[String]] = [
            [prompt],
            ["--model", "sonnet", "--permission-mode", "plan", prompt],
            [prompt, "--add-dir", "/tmp/a", "/tmp/b"],
            ["--resume"],
            ["--resume", "session-id"],
            ["--", "-a prompt that starts with a dash"],
            ["--model", "sonnet", "--", prompt],
            [],
        ]
        for arguments in cases {
            #expect(CanvasBridgeLaunch.shouldAttach(provider: "claude", arguments: arguments))
            let launch = try CanvasBridgeLaunch.plan(
                provider: "claude", arguments: arguments, environment: fixture.environment)
            #expect(
                launch.arguments
                    == [
                        "--mcp-config=\(config)",
                        "--dangerously-load-development-channels=server:rafu",
                    ] + arguments)
            // The spaced variadic form must never appear: it would capture what follows.
            #expect(!launch.arguments.contains("--mcp-config"))
            #expect(!launch.arguments.contains("--dangerously-load-development-channels"))
            let parsed = VariadicCapture(launch.arguments)
            #expect(parsed.values["--mcp-config"] == [config])
            #expect(parsed.values["--dangerously-load-development-channels"] == ["server:rafu"])
            #expect(parsed.rest == arguments)
        }
        // The old spaced prefix: the parse model reproduces the reported failure.
        let old = VariadicCapture(
            ["--mcp-config", config, "--dangerously-load-development-channels", "server:rafu"]
                + [prompt])
        #expect(old.values["--dangerously-load-development-channels"] == ["server:rafu", prompt])
        #expect(old.rest.isEmpty)
    }

    /// Commander's rule for the two Rafu flags: `--flag value...` takes each later token
    /// up to the next one that starts with `-`; `--flag=value` takes only its own value.
    private struct VariadicCapture {
        var values: [String: [String]] = [:]
        var rest: [String] = []

        init(_ argv: [String]) {
            let flags = ["--mcp-config", "--dangerously-load-development-channels"]
            var active: String?
            for (index, token) in argv.enumerated() {
                if token == "--" {
                    rest += argv[index...]
                    return
                }
                if let flag = active, !token.hasPrefix("-") {
                    values[flag, default: []].append(token)
                    continue
                }
                active = nil
                if flags.contains(token) {
                    active = token
                } else if let flag = flags.first(where: { token.hasPrefix("\($0)=") }) {
                    values[flag, default: []].append(String(token.dropFirst(flag.count + 1)))
                } else {
                    rest.append(token)
                }
            }
        }
    }

    private struct Fixture {
        let root: URL
        let wrapper: URL
        let real: URL
        let environment: [String: String]

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            wrapper = root.appendingPathComponent("wrapper")
            real = root.appendingPathComponent("real")
            try FileManager.default.createDirectory(
                at: wrapper, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            for directory in [wrapper, real] {
                for provider in ["codex", "claude"] {
                    let file = directory.appendingPathComponent(provider)
                    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o700], ofItemAtPath: file.path)
                }
            }
            environment = [
                "PATH": "\(wrapper.path):\(real.path)",
                "RAFU_CANVAS_WRAPPER_DIR": wrapper.path, "RAFU_CANVAS_BRIDGE_CLI": "/private/rafu",
                "RAFU_CANVAS_TOKEN": "test-token", "RAFU_CANVAS_SOCKET": "/private/test.sock",
            ]
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
