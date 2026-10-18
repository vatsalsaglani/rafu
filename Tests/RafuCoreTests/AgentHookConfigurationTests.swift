import Foundation
import RafuCore
import Testing

private let paths = AgentTrackingPaths(
    root: URL(fileURLWithPath: "/Users/me/Library/Application Support/Rafu Lightning/AgentTracking")
)

private func json(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func plan(
    _ provider: AgentHookProvider, existing: Data?, removing: Bool = false
) throws -> AgentHookChange {
    try AgentHookConfiguration.plan(
        provider: provider,
        destination: URL(fileURLWithPath: "/Users/me/.claude/settings.json"),
        existing: existing,
        helper: paths.helper,
        spool: paths.spool,
        removing: removing)
}

@Suite("Agent hook configuration")
struct AgentHookConfigurationTests {
    @Test("Quoting keeps spaces and single quotes inside one argument")
    func quoting() {
        #expect(AgentHookConfiguration.shellQuoted("/a b/c") == "'/a b/c'")
        #expect(AgentHookConfiguration.shellQuoted("it's") == "'it'\\''s'")
        let command = AgentHookConfiguration.command(
            helper: paths.helper, provider: .claude, spool: paths.spool)
        #expect(
            command
                == "'/Users/me/Library/Application Support/Rafu Lightning/AgentTracking/bin/rafu-agent-events' claude '/Users/me/Library/Application Support/Rafu Lightning/AgentTracking/spool'"
        )
        #expect(AgentHookConfiguration.isRafuCommand(command, helper: paths.helper))
        #expect(!AgentHookConfiguration.isRafuCommand("/usr/bin/true", helper: paths.helper))
    }

    @Test("Claude Code: merge keeps other settings and hooks in order, then appends Rafu's")
    func claudeMerge() throws {
        let existing = Data(
            """
            {"model": "opus", "hooks": {"Stop": [
              {"hooks": [{"type": "command", "command": "afplay done.aiff"}]}
            ], "PreCompact": [{"hooks": [{"type": "command", "command": "keep-me"}]}]}}
            """.utf8)
        let change = try plan(.claude, existing: existing)
        #expect(!change.isNoOp)
        #expect(change.changedEvents == AgentHookProvider.claude.hookEventNames)
        let document = try json(change.after)
        #expect(document["model"] as? String == "opus")
        let hooks = try #require(document["hooks"] as? [String: Any])
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stop.count == 2)
        let firstCommand = (stop[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String
        #expect(firstCommand == "afplay done.aiff")
        let rafu = try #require((stop[1]["hooks"] as? [[String: Any]])?.first)
        #expect(rafu["command"] as? String == change.command)
        #expect(rafu["type"] as? String == "command")
        #expect(rafu["timeout"] as? Int == 1)
        #expect(hooks["PreCompact"] != nil)
        #expect(
            AgentHookConfiguration.isConnected(
                provider: .claude, existing: change.after, helper: paths.helper))
        #expect(change.preview.contains("SessionStart"))
        #expect(!change.preview.contains("afplay"))
    }

    @Test("Connect is idempotent")
    func idempotent() throws {
        let first = try plan(.claude, existing: nil)
        let second = try plan(.claude, existing: first.after)
        #expect(second.isNoOp)
        let stop = try #require(
            (try json(second.after)["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        #expect(stop.count == 1)
    }

    @Test("Disconnect removes only Rafu's entries and keeps a shared entry's other hooks")
    func claudeUnmerge() throws {
        let command = AgentHookConfiguration.command(
            helper: paths.helper, provider: .claude, spool: paths.spool)
        let existingObject: [String: Any] = [
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": "afplay done.aiff"]]],
                    [
                        "hooks": [
                            ["type": "command", "command": command],
                            ["type": "command", "command": "notify-send hi"],
                        ]
                    ],
                ],
                "SessionStart": [["hooks": [["type": "command", "command": command]]]],
            ],
            "theme": "dark",
        ]
        let existing = try JSONSerialization.data(withJSONObject: existingObject)
        let change = try plan(.claude, existing: existing, removing: true)
        #expect(Set(change.changedEvents) == ["Stop", "SessionStart"])
        let document = try json(change.after)
        #expect(document["theme"] as? String == "dark")
        let hooks = try #require(document["hooks"] as? [String: Any])
        #expect(hooks["SessionStart"] == nil)
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stop.count == 2)
        let shared = try #require(stop[1]["hooks"] as? [[String: Any]])
        #expect(shared.map { $0["command"] as? String } == ["notify-send hi"])
        #expect(
            !AgentHookConfiguration.isConnected(
                provider: .claude, existing: change.after, helper: paths.helper))
    }

    @Test("Disconnect with nothing installed is a no-op")
    func disconnectNothing() throws {
        let change = try plan(.codex, existing: Data("{\"hooks\": {}}".utf8), removing: true)
        #expect(change.isNoOp)
    }

    @Test("Connect replaces a stale Rafu entry with an older spool path")
    func replacesStale() throws {
        let stale =
            AgentHookConfiguration.shellQuoted(paths.helper.path)
            + " codex '/old/AgentTracking/spool'"
        let existing = try JSONSerialization.data(withJSONObject: [
            "hooks": ["Stop": [["hooks": [["type": "command", "command": stale]]]]]
        ])
        let change = try plan(.codex, existing: existing)
        let stop = try #require(
            (try json(change.after)["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        let commands = stop.compactMap {
            ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String
        }
        #expect(commands == [change.command])
    }

    @Test("Unparseable or oddly shaped files are refused")
    func refusals() {
        #expect(throws: AgentHookConfigurationError.unparseableConfiguration) {
            try plan(.claude, existing: Data("{ not json".utf8))
        }
        #expect(throws: AgentHookConfigurationError.unparseableConfiguration) {
            try plan(.claude, existing: Data("[]".utf8))
        }
        #expect(throws: AgentHookConfigurationError.unexpectedStructure) {
            try plan(.claude, existing: Data("{\"hooks\": []}".utf8))
        }
        #expect(throws: AgentHookConfigurationError.unexpectedStructure) {
            try plan(.claude, existing: Data("{\"hooks\": {\"Stop\": \"x\"}}".utf8))
        }
        #expect(throws: AgentHookConfigurationError.unexpectedStructure) {
            try plan(.cursor, existing: Data("{\"version\": 2}".utf8))
        }
    }

    @Test("Cursor uses flat entries and version 1")
    func cursor() throws {
        let change = try plan(.cursor, existing: nil)
        let document = try json(change.after)
        #expect(document["version"] as? Int == 1)
        let stop = try #require((document["hooks"] as? [String: Any])?["stop"] as? [[String: Any]])
        #expect(stop.first?["command"] as? String == change.command)
        let removed = try plan(.cursor, existing: change.after, removing: true)
        #expect((try json(removed.after)["hooks"]) == nil)
    }

    @Test("Destinations honor CLAUDE_CONFIG_DIR and CODEX_HOME")
    func destinations() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(
            AgentHookConfiguration.destination(provider: .claude, home: home, environment: [:])
                .path == "/Users/me/.claude/settings.json")
        #expect(
            AgentHookConfiguration.destination(
                provider: .codex, home: home, environment: ["CODEX_HOME": "/opt/codex"]
            ).path == "/opt/codex/hooks.json")
        #expect(
            AgentHookConfiguration.destination(
                provider: .claude, home: home, environment: ["CLAUDE_CONFIG_DIR": "relative"]
            ).path == "/Users/me/.claude/settings.json")
        #expect(
            AgentHookConfiguration.destination(provider: .cursor, home: home, environment: [:])
                .path == "/Users/me/.cursor/hooks.json")
    }
}

@Suite("Agent hook installer")
struct AgentHookInstallerTests {
    private struct Fixture {
        let root: URL
        let paths: AgentTrackingPaths
        let destination: URL
        let bundledHelper: URL
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "rafu-hooks \(UUID().uuidString)", directoryHint: .isDirectory)
        let support = root.appending(path: "Support/AgentTracking", directoryHint: .isDirectory)
        let bundled = root.appending(path: "Bundle/rafu-agent-events")
        try FileManager.default.createDirectory(
            at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bundled)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: bundled.path)
        return Fixture(
            root: root, paths: AgentTrackingPaths(root: support),
            destination: root.appending(path: "home/.claude/settings.json"),
            bundledHelper: bundled)
    }

    private func mode(_ url: URL) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
            as? NSNumber)?.intValue
    }

    @Test("Connect stages the helper, writes the file, and keeps a backup")
    func connectAndDisconnect() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            at: fixture.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{\"model\": \"opus\"}".utf8)
        try original.write(to: fixture.destination)
        let change = try AgentHookInstaller.prepare(
            provider: .claude, destination: fixture.destination, paths: fixture.paths,
            removing: false)
        let backup = try AgentHookInstaller.apply(
            change, paths: fixture.paths, bundledHelper: fixture.bundledHelper,
            now: Date(timeIntervalSince1970: 0))
        let backupURL = try #require(backup)
        #expect(try Data(contentsOf: backupURL) == original)
        #expect(backupURL.lastPathComponent.hasPrefix("settings.json.rafu-backup-"))
        #expect(try mode(backupURL) == 0o600)
        #expect(try mode(fixture.paths.helper) == 0o700)
        #expect(try mode(fixture.paths.spool) == 0o700)
        #expect(
            AgentHookInstaller.isConnected(
                provider: .claude, destination: fixture.destination, paths: fixture.paths))
        let undo = try AgentHookInstaller.prepare(
            provider: .claude, destination: fixture.destination, paths: fixture.paths,
            removing: true)
        try AgentHookInstaller.apply(undo, paths: fixture.paths, bundledHelper: nil)
        #expect(
            !AgentHookInstaller.isConnected(
                provider: .claude, destination: fixture.destination, paths: fixture.paths))
        let document = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.destination))
                as? [String: Any])
        #expect(document["model"] as? String == "opus")
        #expect(document["hooks"] == nil)
    }

    @Test("A file that changed after review is not written")
    func changedSinceReview() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let change = try AgentHookInstaller.prepare(
            provider: .claude, destination: fixture.destination, paths: fixture.paths,
            removing: false)
        try FileManager.default.createDirectory(
            at: fixture.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: fixture.destination)
        #expect(throws: AgentHookConfigurationError.changedSinceReview) {
            try AgentHookInstaller.apply(
                change, paths: fixture.paths, bundledHelper: fixture.bundledHelper)
        }
    }

    @Test("Connect without a bundled helper fails before writing")
    func helperMissing() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let change = try AgentHookInstaller.prepare(
            provider: .codex, destination: fixture.destination, paths: fixture.paths,
            removing: false)
        #expect(throws: AgentHookConfigurationError.helperMissing) {
            try AgentHookInstaller.apply(change, paths: fixture.paths, bundledHelper: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test("A symlinked configuration is refused")
    func symlink() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let folder = fixture.destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let real = fixture.root.appending(path: "real.json")
        try Data("{}".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(
            at: fixture.destination, withDestinationURL: real)
        #expect(throws: AgentHookConfigurationError.symlinkedConfiguration) {
            try AgentHookInstaller.prepare(
                provider: .claude, destination: fixture.destination, paths: fixture.paths,
                removing: false)
        }
    }
}
