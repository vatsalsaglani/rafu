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
