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

    @Test func scrubsInheritedClaudeCodeHostSessionKeysButKeepsUserConfiguration() async throws {
        let launch = try await CanvasTerminalBootstrap.prepare(
            shellPath: "/bin/zsh", loginArguments: ["-l"], token: "fixture-token",
            cliURL: URL(fileURLWithPath: "/bin/sh"),
            socketURL: URL(fileURLWithPath: "/tmp/fixture.sock"),
            baseEnvironment: [
                "HOME": "/fixture/home", "PATH": "/usr/bin:/bin",
                "CLAUDECODE": "1", "CLAUDE_PID": "4242", "CLAUDE_EFFORT": "40",
                "CLAUDE_CODE_SESSION_ID": "fixture-session",
                "CLAUDE_CODE_MESSAGING_TOKEN": "fixture-messaging-token",
                "ANTHROPIC_API_KEY": "fixture-anthropic-key",
                "CLAUDE_CONFIG_DIR": "/fixture/claude-config",
            ])
        defer { try? FileManager.default.removeItem(at: launch.directory) }
        let environment = Self.dictionary(launch.environment)
        for key in [
            "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_CODE_SESSION_ID",
            "CLAUDE_CODE_MESSAGING_TOKEN",
        ] {
            #expect(environment[key] == nil)
        }
        #expect(environment["ANTHROPIC_API_KEY"] == "fixture-anthropic-key")
        #expect(environment["CLAUDE_CONFIG_DIR"] == "/fixture/claude-config")
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

    @Test(
        "Every basename maps to a strategy, and supportsBridge tracks environmentOnly exactly",
        arguments: [
            ("zsh", CanvasTerminalBootstrap.CanvasShellBridgeStrategy.zsh, true),
            ("bash", .bash, true),
            ("fish", .fish, true),
            ("sh", .posixEnv(.none), true),
            ("dash", .posixEnv(.none), true),
            ("ksh", .posixEnv(.kshrc), true),
            ("mksh", .posixEnv(.mkshrc), true),
            ("tcsh", .cshHome, true),
            ("csh", .cshHome, true),
            ("nu", .nushell, true),
            ("xonsh", .xonsh, true),
            ("elvish", .environmentOnly, false),
            ("foo", .environmentOnly, false),
        ] as [(String, CanvasTerminalBootstrap.CanvasShellBridgeStrategy, Bool)]
    )
    func strategyTableAndSupportsBridgeAgree(
        basename: String, strategy: CanvasTerminalBootstrap.CanvasShellBridgeStrategy,
        supported: Bool
    ) {
        #expect(CanvasTerminalBootstrap.bridgeStrategy(shellBasename: basename) == strategy)
        #expect(CanvasTerminalBootstrap.supportsBridge(shellBasename: basename) == supported)
    }

    @Test func unknownShellStillPreparesWithEnvironmentOnlyPath() async throws {
        let launch = try await CanvasTerminalBootstrap.prepare(
            shellPath: "/opt/homebrew/bin/elvish", loginArguments: ["-l"],
            token: "fixture-token", cliURL: URL(fileURLWithPath: "/bin/sh"),
            socketURL: URL(fileURLWithPath: "/tmp/fixture.sock"),
            baseEnvironment: ["HOME": "/fixture/home", "PATH": "/usr/bin:/bin"])
        defer { try? FileManager.default.removeItem(at: launch.directory) }
        #expect(launch.arguments == ["-l"])
        #expect(launch.execName == "-elvish")
        #expect(launch.pathMayBeReordered)
        let environment = Self.dictionary(launch.environment)
        #expect(environment["PATH"] == "\(launch.directory.path):/usr/bin:/bin")
        let entries = try FileManager.default.contentsOfDirectory(atPath: launch.directory.path)
        #expect(Set(entries) == ["claude", "codex"])
    }

    @Test(
        "POSIX shells never see -l: the private ENV file emulates the login sequence",
        arguments: [
            ("/bin/sh", "env.sh"), ("/bin/dash", "env.sh"), ("/bin/ksh", "env.sh"),
            ("/bin/mksh", "env.sh"),
        ]
    )
    func posixPrepareUsesPrivateEnvFileNotLoginFlag(shellPath: String, fileName: String)
        async throws
    {
        let launch = try await CanvasTerminalBootstrap.prepare(
            shellPath: shellPath, loginArguments: ["-l"], token: "fixture-token",
            cliURL: URL(fileURLWithPath: "/bin/sh"),
            socketURL: URL(fileURLWithPath: "/tmp/fixture.sock"),
            baseEnvironment: ["HOME": "/fixture/home", "PATH": "/usr/bin:/bin"])
        defer { try? FileManager.default.removeItem(at: launch.directory) }
        #expect(launch.arguments == ["-i"])
        #expect(launch.execName == nil)
        #expect(!launch.pathMayBeReordered)
        let environment = Self.dictionary(launch.environment)
        #expect(environment["ENV"] == launch.directory.appendingPathComponent(fileName).path)
        #expect(environment["RAFU_CANVAS_USER_HAD_ENV"] == "0")
        #expect(environment["RAFU_CANVAS_USER_ENV"] == "")
    }

    @Test func posixPrepareCarriesTheUsersOwnEnvWhenPresent() async throws {
        let launch = try await CanvasTerminalBootstrap.prepare(
            shellPath: "/bin/ksh", loginArguments: [], token: "fixture-token",
            cliURL: URL(fileURLWithPath: "/bin/sh"),
            socketURL: URL(fileURLWithPath: "/tmp/fixture.sock"),
            baseEnvironment: [
                "HOME": "/fixture/home", "PATH": "/usr/bin:/bin", "ENV": "/fixture/my-kshrc",
            ])
        defer { try? FileManager.default.removeItem(at: launch.directory) }
        let environment = Self.dictionary(launch.environment)
        #expect(environment["RAFU_CANVAS_USER_HAD_ENV"] == "1")
        #expect(environment["RAFU_CANVAS_USER_ENV"] == "/fixture/my-kshrc")
    }

    @Test(
        "tcsh and csh redirect HOME, like ZDOTDIR, and never pass -l",
        arguments: ["/bin/tcsh", "/bin/csh"]
    )
    func cshPrepareRedirectsHomeAndNeverPassesLoginFlag(shellPath: String) async throws {
        let launch = try await CanvasTerminalBootstrap.prepare(
            shellPath: shellPath, loginArguments: ["-l"], token: "fixture-token",
            cliURL: URL(fileURLWithPath: "/bin/sh"),
            socketURL: URL(fileURLWithPath: "/tmp/fixture.sock"),
            baseEnvironment: ["HOME": "/fixture/home", "PATH": "/usr/bin:/bin"])
        defer { try? FileManager.default.removeItem(at: launch.directory) }
        #expect(launch.arguments == ["-i"])
        #expect(launch.execName == nil)
        #expect(!launch.pathMayBeReordered)
        let environment = Self.dictionary(launch.environment)
        #expect(environment["HOME"] == launch.directory.path)
        #expect(environment["RAFU_CANVAS_USER_HOME"] == "/fixture/home")
        let attributes = try FileManager.default.attributesOfItem(
            atPath: launch.directory.appendingPathComponent(".tcshrc").path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func nuPrepareAppendsInstallCommandAfterStartupFiles() async throws {
        let launch = try await CanvasTerminalBootstrap.prepare(
            shellPath: "/opt/homebrew/bin/nu", loginArguments: ["-l"], token: "fixture-token",
            cliURL: URL(fileURLWithPath: "/bin/sh"),
            socketURL: URL(fileURLWithPath: "/tmp/fixture.sock"),
            baseEnvironment: ["HOME": "/fixture/home", "PATH": "/usr/bin:/bin"])
        defer { try? FileManager.default.removeItem(at: launch.directory) }
        #expect(launch.execName == "-nu")
        #expect(!launch.pathMayBeReordered)
        #expect(
            launch.arguments.suffix(3)
                == ["-l", "-e", "$env.PATH = ($env.PATH | prepend $env.RAFU_CANVAS_WRAPPER_DIR)"])
        #expect(!launch.arguments[launch.arguments.count - 1].contains("/"))
        #expect(!launch.arguments[launch.arguments.count - 1].contains("fixture-token"))
    }

    @Test func xonshPrepareAppendsWrapperRcDirectoryAfterTheUsersOwn() async throws {
        let launch = try await CanvasTerminalBootstrap.prepare(
            shellPath: "/opt/homebrew/bin/xonsh", loginArguments: [], token: "fixture-token",
            cliURL: URL(fileURLWithPath: "/bin/sh"),
            socketURL: URL(fileURLWithPath: "/tmp/fixture.sock"),
            baseEnvironment: [
                "HOME": "/fixture/home", "PATH": "/usr/bin:/bin",
                "XONSHRC_DIR": "/fixture/xonshrc.d",
            ])
        defer { try? FileManager.default.removeItem(at: launch.directory) }
        #expect(launch.execName == "-xonsh")
        #expect(!launch.pathMayBeReordered)
        let environment = Self.dictionary(launch.environment)
        #expect(
            environment["XONSHRC_DIR"]
                == "/fixture/xonshrc.d:\(launch.directory.appendingPathComponent("xonshrc.d").path)"
        )
        let rcFile = launch.directory.appendingPathComponent("xonshrc.d/zzzz-rafu-canvas.xsh")
        #expect(
            (try String(contentsOf: rcFile, encoding: .utf8)).trimmingCharacters(
                in: .whitespacesAndNewlines)
                == "$PATH.insert(0, $RAFU_CANVAS_WRAPPER_DIR)")
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: rcFile.path)
        #expect((fileAttributes[.posixPermissions] as? Int) == 0o600)
        let dirAttributes = try FileManager.default.attributesOfItem(
            atPath: launch.directory.appendingPathComponent("xonshrc.d").path)
        #expect((dirAttributes[.posixPermissions] as? Int) == 0o700)
    }

    @Test func xonshPrepareComputesDefaultRcDirWhenBaseIsAbsent() async throws {
        let launch = try await CanvasTerminalBootstrap.prepare(
            shellPath: "/opt/homebrew/bin/xonsh", loginArguments: [], token: "fixture-token",
            cliURL: URL(fileURLWithPath: "/bin/sh"),
            socketURL: URL(fileURLWithPath: "/tmp/fixture.sock"),
            baseEnvironment: [
                "HOME": "/fixture/home", "PATH": "/usr/bin:/bin",
                "XDG_CONFIG_HOME": "/fixture/.config",
            ])
        defer { try? FileManager.default.removeItem(at: launch.directory) }
        let environment = Self.dictionary(launch.environment)
        #expect(
            environment["XONSHRC_DIR"]
                == "/etc/xonsh/rc.d:/fixture/.config/xonsh/rc.d:\(launch.directory.appendingPathComponent("xonshrc.d").path)"
        )
    }

    @Test(
        "The private env.sh/env.ksh/.tcshrc files never contain the token, socket, or any base-environment value",
        arguments: ["/bin/sh", "/bin/ksh", "/bin/mksh", "/bin/tcsh", "/opt/homebrew/bin/xonsh"]
    )
    func privateStartupFilesNeverEmbedASecret(shellPath: String) async throws {
        let marker = "/fixture/$(evil)"
        let launch = try await CanvasTerminalBootstrap.prepare(
            shellPath: shellPath, loginArguments: ["-l"], token: "fixture-secret-token",
            cliURL: URL(fileURLWithPath: "/bin/sh"),
            socketURL: URL(fileURLWithPath: "/tmp/fixture-secret.sock"),
            baseEnvironment: ["HOME": marker, "PATH": "/usr/bin:/bin", "ENV": marker])
        defer { try? FileManager.default.removeItem(at: launch.directory) }
        let entries =
            try FileManager.default.subpathsOfDirectory(atPath: launch.directory.path)
        for entry in entries {
            let url = launch.directory.appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            guard !isDirectory.boolValue else { continue }
            let contents = try String(contentsOf: url, encoding: .utf8)
            #expect(!contents.contains(marker), "\(entry) embedded a base-environment value")
            #expect(!contents.contains("fixture-secret-token"), "\(entry) embedded the token")
            #expect(!contents.contains("fixture-secret.sock"), "\(entry) embedded the socket path")
        }
    }

    // MARK: Opt-in integration tests — real shells, hermetic fixture HOME, bounded by stdin + exit

    @Test(
        "sh sources the user's own startup files, through the private ENV redirect, before installing the wrapper PATH",
        .enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/sh"))
    )
    func shSourcesUserStartupBeforeInstallingWrapperPath() async throws {
        try await Self.assertPosixLoginSourcesFixtureProfile(shellPath: "/bin/sh")
    }

    @Test(
        "dash sources the user's own startup files, through the private ENV redirect, before installing the wrapper PATH",
        .enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/dash"))
    )
    func dashSourcesUserStartupBeforeInstallingWrapperPath() async throws {
        try await Self.assertPosixLoginSourcesFixtureProfile(shellPath: "/bin/dash")
    }

    @Test(
        "ksh sources the user's own startup files, through the private ENV redirect, before installing the wrapper PATH",
        .enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/ksh"))
    )
    func kshSourcesUserStartupBeforeInstallingWrapperPath() async throws {
        try await Self.assertPosixLoginSourcesFixtureProfile(shellPath: "/bin/ksh")
    }

    @Test(
        "tcsh sources the user's own .tcshrc, through the private HOME redirect, before installing the wrapper PATH",
        .enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/tcsh"))
    )
    func tcshSourcesUserStartupBeforeInstallingWrapperPath() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rafu-shell-test-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("setenv PATH \"/fixture/tcshrc:$PATH\"\n".utf8).write(
            to: home.appendingPathComponent(".tcshrc"))
        let launch = try await CanvasTerminalBootstrap.prepare(
            shellPath: "/bin/tcsh", loginArguments: ["-l"], token: "fixture-token",
            cliURL: URL(fileURLWithPath: "/bin/sh"),
            socketURL: URL(fileURLWithPath: "/tmp/fixture.sock"),
            baseEnvironment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        defer { try? FileManager.default.removeItem(at: launch.directory) }
        let path = try Self.pathFromInteractiveShell(
            launch: launch, echo: "echo \"RAFU_TEST_PATH:$PATH\"\nexit\n")
        #expect(path.hasPrefix("\(launch.directory.path):"))
        #expect(path.contains("/fixture/tcshrc"))
    }

    /// Runs the already-prepared launch non-interactively over a stdin pipe
    /// and returns the one line it prints after the `RAFU_TEST_PATH:`
    /// marker: `-i` alone has no `-c` to carry a script, so the fixture's
    /// commands are fed as input and the shell exits on its own `exit`
    /// command — bounded, no sleeps, no tty. A tcsh/csh warning about having
    /// no real tty, plus its prompt, can land on the SAME stdout stream, so
    /// the marker — not line position — picks the one line that matters.
    private static func pathFromInteractiveShell(
        launch: CanvasTerminalBootstrap, echo: String
    ) throws -> String {
        let process = Process()
        let output = Pipe()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.environment = Self.dictionary(launch.environment)
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin
        try process.run()
        stdin.fileHandleForWriting.write(Data(echo.utf8))
        try stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let text = String(decoding: data, as: UTF8.self)
        guard
            let line = text.split(separator: "\n").first(where: {
                $0.contains("RAFU_TEST_PATH:")
            }), let marker = line.range(of: "RAFU_TEST_PATH:")
        else {
            Issue.record("No RAFU_TEST_PATH line in output: \(text)")
            return ""
        }
        return String(line[marker.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    private static func assertPosixLoginSourcesFixtureProfile(shellPath: String) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rafu-shell-test-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("export PATH=/fixture/profile-marker:$PATH\n".utf8).write(
            to: home.appendingPathComponent(".profile"))
        let launch = try await CanvasTerminalBootstrap.prepare(
            shellPath: shellPath, loginArguments: ["-l"], token: "fixture-token",
            cliURL: URL(fileURLWithPath: "/bin/sh"),
            socketURL: URL(fileURLWithPath: "/tmp/fixture.sock"),
            baseEnvironment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        defer { try? FileManager.default.removeItem(at: launch.directory) }
        let path = try Self.pathFromInteractiveShell(
            launch: launch, echo: "echo \"RAFU_TEST_PATH:$PATH\"\nexit\n")
        #expect(path.hasPrefix("\(launch.directory.path):"))
        #expect(path.contains("/fixture/profile-marker"))
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
                defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.canvas-startup-tests"),
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
