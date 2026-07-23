import Foundation
import Testing

@testable import RafuApp

/// conductor/C0-shim.md increment 3: the `TerminalProcessSpec` seam.
///
/// `WorkspaceTerminalController.makeOrReuseView(theme:)` is unreachable
/// headlessly — it spawns inside a mounted AppKit view (ADR 0004's lazy
/// spawn; see `markRunningForTesting()`'s doc comment). So the seam is
/// verified in three parts: the PURE `resolvedLaunch()` mapping, the
/// login-shell path's untouched behavior, and a REAL child process spawned
/// from the resolved launch — see `runResolvedLaunch(_:)` for why that child
/// goes through `Foundation.Process` rather than `SwiftTerm.LocalProcess`.

// MARK: - Pure launch mapping

private func probeSpec(
    environment: [String: String] = [
        RafuConductorEnvironment.handoff: "/tmp/rafu-c0-run/step-1",
        RafuConductorEnvironment.runDirectory: "/tmp/rafu-c0-run",
    ]
) -> TerminalProcessSpec {
    TerminalProcessSpec(
        executableURL: URL(fileURLWithPath: "/bin/echo"),
        arguments: ["rafu-c0"],
        currentDirectoryPath: "/tmp",
        environment: environment,
        roleBadge: "advisor")
}

@Test("resolvedLaunch maps a spec onto SwiftTerm's exact startProcess tuple")
func resolvedLaunchProducesTheExactTuple() {
    let launch = probeSpec().resolvedLaunch()
    #expect(launch.executable == "/bin/echo")
    #expect(launch.arguments == ["rafu-c0"])
    #expect(launch.currentDirectory == "/tmp")
    // `execName` exists to fake a login shell (`-zsh`); an agent CLI must
    // never pretend to be one.
    #expect(launch.execName == nil)
}

@Test("resolvedLaunch emits sorted KEY=VALUE strings carrying both RAFU_ variables")
func resolvedLaunchEmitsSortedEnvironmentStrings() throws {
    let environment = try #require(probeSpec().resolvedLaunch().environment)
    #expect(environment == environment.sorted())
    #expect(environment.contains("RAFU_HANDOFF=/tmp/rafu-c0-run/step-1"))
    #expect(environment.contains("RAFU_RUN_DIR=/tmp/rafu-c0-run"))
    #expect(environment.contains("TERM=xterm-256color"))
    // SwiftTerm 1.14.0 deliberately omits PATH from its base variables, so a
    // PTY child inherits no search path — which is exactly why every
    // adapter must return an ABSOLUTE executable URL.
    #expect(!environment.contains { $0.hasPrefix("PATH=") })
    // One entry per key, and nothing without a value separator.
    let keys = environment.compactMap { $0.split(separator: "=", maxSplits: 1).first }
    #expect(Set(keys).count == keys.count)
    #expect(environment.allSatisfy { $0.contains("=") })
}

@Test("An explicit spec variable overrides the terminal base variable of the same name")
func specEnvironmentOverridesTheBaseVariables() throws {
    let spec = probeSpec(environment: ["TERM": "dumb", RafuConductorEnvironment.handoff: "/tmp/h"])
    let environment = try #require(spec.resolvedLaunch().environment)
    #expect(environment.contains("TERM=dumb"))
    #expect(!environment.contains("TERM=xterm-256color"))
    #expect(environment.filter { $0.hasPrefix("TERM=") }.count == 1)
}

// MARK: - Login-shell regression

@Test("The login-shell path is unchanged: no process spec, -l argv, and a -basename execName")
@MainActor
func loginShellPathIsUnchanged() {
    let shell = TerminalShell(path: "/bin/zsh", name: "zsh", isDefault: true)
    let session = WorkspaceTerminalController(
        index: 1, startingDirectory: "/tmp", shell: shell)
    // `nil` is what routes `makeOrReuseView` into the untouched login-shell
    // branch.
    #expect(session.processSpec == nil)
    #expect(shell.loginArguments == ["-l"])
    #expect("-\(shell.basename)" == "-zsh")
    #expect(session.displayName == "zsh 1")
}

@Test("A spec session carries its spec and shows the role badge as its name")
@MainActor
func specSessionUsesTheRoleBadge() {
    let manager = WorkspaceTerminalManager()
    let session = manager.newSession(spec: probeSpec())
    #expect(session.processSpec == probeSpec())
    #expect(session.displayName == "advisor")
    #expect(session.startingDirectory == "/tmp")
    #expect(manager.sessions.count == 1)
    #expect(manager.selectedID == session.id)
    // The login-shell entry point still works alongside it, untouched.
    let login = manager.newSession(
        startingDirectory: "/tmp",
        shell: TerminalShell(path: "/bin/zsh", name: "zsh", isDefault: true))
    #expect(login.processSpec == nil)
    #expect(manager.sessions.count == 2)
}

// MARK: - Real child execution

/// Runs the resolved launch through `Foundation.Process` (`posix_spawn`) and
/// returns what the child saw.
///
/// NOT `SwiftTerm.LocalProcess`: its spawn path is `forkpty`, and forking
/// this heavily threaded test process deterministically hangs the child
/// under a parallel `swift test` run (verified: passes with `--no-parallel`,
/// fails 3/3 in parallel with the child spawned but no output and no exit).
/// A PTY is a presentation detail of the terminal tab; what C0 actually has
/// to prove is that `resolvedLaunch()` yields a launch the OS executes with
/// the intended argv and the intended, minimal environment. True PTY
/// execution is exercised by C1 inside a mounted terminal view — the only
/// place `makeOrReuseView(theme:)` is reachable at all.
private func runResolvedLaunch(_ launch: TerminalLaunchArguments) throws -> (
    status: Int32, output: String
) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launch.executable)
    process.arguments = launch.arguments
    if let currentDirectory = launch.currentDirectory {
        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
    }
    process.environment = Dictionary(
        uniqueKeysWithValues: (launch.environment ?? []).compactMap { entry in
            guard let separator = entry.firstIndex(of: "=") else { return nil }
            return (
                String(entry[entry.startIndex..<separator]),
                String(entry[entry.index(after: separator)...])
            )
        })
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

@Test("A resolved launch really executes its absolute binary and exits cleanly")
func resolvedLaunchExecutes() throws {
    let result = try runResolvedLaunch(probeSpec().resolvedLaunch())
    #expect(result.status == 0)
    #expect(result.output == "rafu-c0\n")
}

@Test("A hostile prompt reaches the child as ONE unexpanded argv element")
func resolvedLaunchNeverExpandsArguments() throws {
    // The argv-only invariant (ADR 0018), proven against a real child: no
    // shell is involved, so `;`, `$( )`, and backticks are inert text.
    let hostile = "brief; rm -rf / and $(whoami) and `id`"
    let spec = TerminalProcessSpec(
        executableURL: URL(fileURLWithPath: "/bin/echo"),
        arguments: [hostile],
        currentDirectoryPath: NSTemporaryDirectory(),
        environment: [RafuConductorEnvironment.handoff: "/tmp/rafu-c0-run/step-1"],
        roleBadge: "advisor")
    let result = try runResolvedLaunch(spec.resolvedLaunch())
    #expect(result.status == 0)
    #expect(result.output == hostile + "\n")
    #expect(result.output.contains("$(whoami)"))
    #expect(!result.output.contains(NSUserName()))
}

@Test("The child receives exactly the resolved environment — the RAFU_ pair and no PATH")
func resolvedLaunchEnvironmentReachesTheChild() throws {
    let spec = TerminalProcessSpec(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: [],
        currentDirectoryPath: NSTemporaryDirectory(),
        environment: [
            RafuConductorEnvironment.handoff: "/tmp/rafu-c0-run/step-1",
            RafuConductorEnvironment.runDirectory: "/tmp/rafu-c0-run",
        ],
        roleBadge: "advisor")
    let launch = spec.resolvedLaunch()
    let result = try runResolvedLaunch(launch)
    #expect(result.status == 0)

    let seen = result.output.split(separator: "\n").map(String.init).sorted()
    #expect(seen == (launch.environment ?? []).sorted())
    #expect(seen.contains("RAFU_HANDOFF=/tmp/rafu-c0-run/step-1"))
    #expect(seen.contains("RAFU_RUN_DIR=/tmp/rafu-c0-run"))
    // The terminal's base environment contributes no PATH, which is why
    // adapters return absolute executable URLs; a Conductor child's PATH
    // comes from `RafuConductorEnvironment.curatedPath` through the
    // adapter's own invocation environment, which this hand-built spec does
    // not use.
    #expect(!seen.contains { $0.hasPrefix("PATH=") })
    // Nothing credential-shaped is ever forwarded (ADR 0018). Checked
    // against the KEYS only: the VALUES include USER/LOGNAME/HOME from the
    // real environment, so matching whole entries would fail this suite on
    // any machine whose login name happens to contain "key".
    let forbidden = ["TOKEN", "SECRET", "KEY", "PASSWORD", "COOKIE", "CREDENTIAL"]
    let seenKeys = seen.compactMap { $0.split(separator: "=", maxSplits: 1).first }
        .map { $0.uppercased() }
    #expect(!seenKeys.contains { key in forbidden.contains { key.contains($0) } })
}
