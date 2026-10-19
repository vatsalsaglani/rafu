import Foundation
import Testing

@testable import RafuApp

struct CanvasTerminalBootstrapTests {
    @Test func preservesShellEnvironmentAndReplacesBridgeOverridesOnce() async throws {
        let launch = try await CanvasTerminalBootstrap.prepare(
            shellPath: "/bin/zsh", loginArguments: ["-l"], token: "fixture-token",
            cliURL: URL(fileURLWithPath: "/bin/sh"),
            socketURL: URL(fileURLWithPath: "/tmp/fixture.sock"),
            baseEnvironment: [
                "HOME": "/fixture/home", "PATH": "/fixture/bin:/usr/bin:/bin",
                "TERM": "old-term", "COLORTERM": "old-color", "ZDOTDIR": "/fixture/dot files",
                "RAFU_CANVAS_TOKEN": "old-token",
                "NO_COLOR": "1", "FORCE_COLOR": "0", "CLICOLOR": "0", "CLICOLOR_FORCE": "0",
            ])
        defer { try? FileManager.default.removeItem(at: launch.directory) }
        let environment = Self.dictionary(launch.environment)
        #expect(environment["HOME"] == "/fixture/home")
        #expect(environment["PATH"] == "/fixture/bin:/usr/bin:/bin")
        #expect(environment["TERM"] == "xterm-256color")
        #expect(environment["COLORTERM"] == "truecolor")
        for key in ["NO_COLOR", "FORCE_COLOR", "CLICOLOR", "CLICOLOR_FORCE"] {
            #expect(environment[key] == nil)
        }
        #expect(environment["RAFU_CANVAS_TOKEN"] == "fixture-token")
        #expect(environment["RAFU_CANVAS_USER_ZDOTDIR"] == "/fixture/dot files")
        #expect(environment["ZDOTDIR"] == launch.directory.path)
        #expect(environment.count == launch.environment.count)
    }

    @Test func zshSourcesUserStartupBeforeInstallingWrapperPath() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rafu-shell-test-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let dot = home.appendingPathComponent("dot files")
        try FileManager.default.createDirectory(at: dot, withIntermediateDirectories: false)
        for (file, marker) in [
            (".zshenv", "env"), (".zprofile", "profile"), (".zshrc", "rc"), (".zlogin", "login"),
        ] {
            var source =
                "export RAFU_TEST_ORDER=\"${RAFU_TEST_ORDER}\(marker) \"\nexport PATH=/fixture/\(marker):/usr/bin:/bin\n"
            if file == ".zlogin" {
                source +=
                    "export NO_COLOR=1\nexport FORCE_COLOR=0\nexport CLICOLOR=0\nexport CLICOLOR_FORCE=0\n"
            }
            try Data(source.utf8).write(to: dot.appendingPathComponent(file))
        }
        let launch = try await CanvasTerminalBootstrap.prepare(
            shellPath: "/bin/zsh", loginArguments: ["-l"], token: "fixture-token",
            cliURL: URL(fileURLWithPath: "/bin/sh"),
            socketURL: URL(fileURLWithPath: "/tmp/fixture.sock"),
            baseEnvironment: ["HOME": home.path, "PATH": "/usr/bin:/bin", "ZDOTDIR": dot.path])
        defer { try? FileManager.default.removeItem(at: launch.directory) }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments =
            launch.arguments + [
                "-c",
                "print -rl -- \"$HOME\" \"$PATH\" \"$ZDOTDIR\" \"$RAFU_TEST_ORDER\" \"$NO_COLOR/$FORCE_COLOR/$CLICOLOR/$CLICOLOR_FORCE\"",
            ]
        process.environment = Self.dictionary(launch.environment)
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let lines = String(decoding: data, as: UTF8.self).split(
            separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count >= 5)
        guard lines.count >= 5 else { return }
        #expect(lines[0] == Substring(home.path))
        #expect(lines[1] == Substring("\(launch.directory.path):/fixture/login:/usr/bin:/bin"))
        #expect(lines[2] == Substring(dot.path))
        #expect(lines[3] == "env profile rc login ")
        #expect(lines[4] == "1/0/0/0")
    }

    @Test func fishPreparesInitCommandAndWrapperDirWithoutZdotdir() async throws {
        let launch = try await CanvasTerminalBootstrap.prepare(
            shellPath: "/opt/homebrew/bin/fish", loginArguments: ["-l"],
            token: "fixture-token", cliURL: URL(fileURLWithPath: "/bin/sh"),
            socketURL: URL(fileURLWithPath: "/tmp/fixture.sock"),
            baseEnvironment: ["HOME": "/fixture/home", "PATH": "/usr/bin:/bin"])
        defer { try? FileManager.default.removeItem(at: launch.directory) }
        #expect(launch.executable == "/opt/homebrew/bin/fish")
        #expect(launch.arguments.first == "-l")
        #expect(launch.arguments.contains("-i"))
        guard let initIndex = launch.arguments.firstIndex(of: "--init-command"),
            initIndex + 1 < launch.arguments.count
        else {
            Issue.record("Missing --init-command")
            return
        }
        let constant = launch.arguments[initIndex + 1]
        #expect(constant == "set -gx PATH $RAFU_CANVAS_WRAPPER_DIR $PATH")
        #expect(!constant.contains("/"))
        #expect(!constant.contains("fixture-token"))
        let environment = Self.dictionary(launch.environment)
        #expect(environment["RAFU_CANVAS_WRAPPER_DIR"] == launch.directory.path)
        #expect(environment["ZDOTDIR"] == nil)
        #expect(environment["RAFU_CANVAS_USER_ZDOTDIR"] == nil)
        for provider in ["claude", "codex"] {
            let url = launch.directory.appendingPathComponent(provider)
            #expect(FileManager.default.isExecutableFile(atPath: url.path))
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? Int) == 0o700)
        }
    }

    @Test func zshAndBashPrepareAreUnaffectedByFishSupport() async throws {
        for (shellPath, login) in [("/bin/zsh", ["-l"]), ("/bin/bash", ["-l"])] {
            let launch = try await CanvasTerminalBootstrap.prepare(
                shellPath: shellPath, loginArguments: login, token: "fixture-token",
                cliURL: URL(fileURLWithPath: "/bin/sh"),
                socketURL: URL(fileURLWithPath: "/tmp/fixture.sock"),
                baseEnvironment: ["HOME": "/fixture/home", "PATH": "/usr/bin:/bin"])
            defer { try? FileManager.default.removeItem(at: launch.directory) }
            #expect(!launch.arguments.contains("--init-command"))
        }
    }

    @Test func supportsBridgeIsTrueOnlyForZshBashAndFish() {
        #expect(CanvasTerminalBootstrap.supportsBridge(shellBasename: "zsh"))
        #expect(CanvasTerminalBootstrap.supportsBridge(shellBasename: "bash"))
        #expect(CanvasTerminalBootstrap.supportsBridge(shellBasename: "fish"))
        #expect(!CanvasTerminalBootstrap.supportsBridge(shellBasename: "nu"))
        #expect(!CanvasTerminalBootstrap.supportsBridge(shellBasename: "tcsh"))
    }

    @Test func unsupportedShellStillRejectsNu() async {
        await #expect(throws: CanvasTerminalBootstrap.BootstrapError.unsupportedShell) {
            _ = try await CanvasTerminalBootstrap.prepare(
                shellPath: "/opt/homebrew/bin/nu", loginArguments: [], token: "fixture-token",
                cliURL: URL(fileURLWithPath: "/bin/sh"),
                socketURL: URL(fileURLWithPath: "/tmp/fixture.sock"), baseEnvironment: [:])
        }
    }

    @Test func cancelledBootstrapRejectsBeforeFilesystemSetup() async {
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                // Cancellation must win even over input validation. This proves the worker
                // exits before the private directory creation and startup-file writes.
                let launch = try await CanvasTerminalBootstrap.prepare(
                    shellPath: "/unsupported-shell", loginArguments: [], token: "fixture-token",
                    cliURL: URL(fileURLWithPath: "/missing-fixture-cli"), baseEnvironment: [:])
                try? FileManager.default.removeItem(at: launch.directory)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value
        #expect(cancelled)
    }

    @Test @MainActor func staleViewDoesNotInstallBridgeOrStartTerminal() async throws {
        let session = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: "dev.rafu.canvas-startup-tests.\(UUID())",
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker())
        let board = CanvasBoardState(document: CanvasDocument(title: "Startup lifecycle"))
        try board.add(title: "Terminal", content: .terminal(groupID: TerminalGroupID()))
        let card = try #require(board.cards.first)
        let controller = WorkspaceTerminalController(
            index: 1, startingDirectory: "/tmp",
            shell: TerminalShell(path: "/bin/zsh", name: "zsh", isDefault: true))
        let bridge = CanvasLiveBridge(location: { id in
            id == controller.id ? (session, board, card) : nil
        })
        let revision = bridge.revision
        let launch = await bridge.prepare(controller, isCurrent: { false })
        #expect(launch == nil)
        #expect(bridge.revision == revision)
        #expect(bridge.notice == nil)
        #expect(
            bridge.status(for: controller.id) == "Start a new terminal to enable the session bridge"
        )
        #expect(controller.status == .idle)
        #expect(!controller.hasLiveProcess)
    }

    private static func dictionary(_ environment: [String]) -> [String: String] {
        Dictionary(
            environment.compactMap { entry in
                guard let separator = entry.firstIndex(of: "=") else { return nil }
                return (
                    String(entry[..<separator]), String(entry[entry.index(after: separator)...])
                )
            }, uniquingKeysWith: { _, value in value })
    }
}
