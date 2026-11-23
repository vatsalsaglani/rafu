import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Hidden meeting agent: registration and source policy")
struct MeetingAgentRegistrationAndPolicyTests {
    @MainActor
    @Test("Registration adds a runner that answers both protocols and starts nothing")
    func registration() throws {
        let runsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("rafu-agent-reg-\(UUID().uuidString)", isDirectory: true)
        // A temporary snapshot root too: registration removes each folder
        // in both roots, and the real roots belong to a running app.
        let snapshotRoot = runsRoot.appendingPathComponent("Snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: runsRoot) }
        let feature = MeetingsFeature(availability: .available)
        feature.registerAgentParts(runsRoot: runsRoot, snapshotRoot: snapshotRoot)
        #expect(feature.registeredKinds == [.agentRunner])
        let runner = try #require(feature.agentRunner)
        #expect(runner is MeetingAgentRunner)
        #expect(runner is any MeetingAgentAvailabilityChecking)
        #expect(MeetingAgentProcessRegistry.shared.count == 0)

        let unavailable = MeetingsFeature(availability: .needsMacOS26)
        unavailable.registerAgentParts(runsRoot: runsRoot, snapshotRoot: snapshotRoot)
        #expect(unavailable.agentRunner == nil)
    }

    @Test("Run folders are private and stale ones are removed")
    func runFolders() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("rafu-agent-runs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let run = try MeetingAgentRunFolders.make(in: base)
        for url in [base, run.root, run.emptyFolder] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o700)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: run.emptyFolder.path).isEmpty)
        MeetingAgentRunFolders.removeStale(in: base, olderThan: 3_600)
        #expect(FileManager.default.fileExists(atPath: run.root.path))
        MeetingAgentRunFolders.removeStale(
            in: base, olderThan: 3_600, now: Date().addingTimeInterval(7_200))
        #expect(!FileManager.default.fileExists(atPath: run.root.path))
    }

    /// The real process path with system tools (no agent CLI): the packet
    /// reaches standard input and comes back on standard output; terminate
    /// ends a process that waits; the registry forgets each ended process.
    @Test("The system process writes standard input, reads standard output and terminates")
    func systemProcess() async throws {
        let registry = MeetingAgentProcessRegistry()
        let runner = MeetingAgentSystemProcessRunner(registry: registry)
        let folder = FileManager.default.temporaryDirectory
        let packet = Data((String(repeating: "line of packet text\n", count: 20_000)).utf8)
        let cat = try runner.start(
            MeetingAgentProcessSpec(
                executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [],
                environment: MeetingAgentEnvironment.make(), currentDirectoryURL: folder,
                standardInput: packet))
        var received = Data()
        for await chunk in cat.output { received.append(chunk) }
        #expect(await cat.termination() == .exited(0))
        #expect(received == packet)

        let sleeper = try runner.start(
            MeetingAgentProcessSpec(
                executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                environment: MeetingAgentEnvironment.make(), currentDirectoryURL: folder,
                standardInput: nil))
        sleeper.terminate()
        #expect(await sleeper.termination() == .signalled(SIGTERM))
        sleeper.terminate()
        #expect(registry.count == 0)
    }

    @Test("The environment has exactly the four allowed keys")
    func environment() {
        let environment = MeetingAgentEnvironment.make()
        #expect(Set(environment.keys) == ["PATH", "HOME", "USER", "LOGNAME"])
        #expect(environment["PATH"] == RafuConductorEnvironment.curatedPath)
        #expect(environment["USER"] == environment["LOGNAME"])
    }

    @Test("The locator finds only an executable regular file in the given directories")
    func locator() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("rafu-agent-locator-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let first = base.appendingPathComponent("a", isDirectory: true)
        let second = base.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        // Not executable in the first directory; executable in the second.
        FileManager.default.createFile(
            atPath: first.appendingPathComponent("codex").path, contents: Data("x".utf8),
            attributes: [.posixPermissions: 0o644])
        FileManager.default.createFile(
            atPath: second.appendingPathComponent("codex").path, contents: Data("x".utf8),
            attributes: [.posixPermissions: 0o755])
        // A directory named claude is not an executable.
        try FileManager.default.createDirectory(
            at: first.appendingPathComponent("claude"), withIntermediateDirectories: true)

        let locator = MeetingAgentExecutableLocator(
            directories: ["relative/dir", first.path, second.path])
        let codex = try #require(locator.locate(.codex))
        #expect(codex.url.path == second.appendingPathComponent("codex").path)
        #expect(locator.locate(.claudeCode) == nil)
    }

    /// What this scan proves: no file in the two agent folders logs at all,
    /// and the one diagnostics call site with a string builds it only from
    /// a fixed code (`agent.<case>`) or a CLI version, never from the
    /// question, the reply text, a title or a name.
    @Test("No log call, and no diagnostics value from a question, a reply or a title")
    func sourcePolicy() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folders = ["Sources/RafuCore/Meetings/Agent", "Sources/RafuApp/Meetings/Agent"]
        var scanned = 0
        for folder in folders {
            let url = root.appendingPathComponent(folder, isDirectory: true)
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path)
            where name.hasSuffix(".swift") {
                let source = try String(
                    contentsOf: url.appendingPathComponent(name), encoding: .utf8)
                scanned += 1
                for call in ["Logger(", "print(", "NSLog(", "os_log("] {
                    #expect(!source.contains(call), "\(name) has \(call)")
                }
                for (index, line) in source.split(separator: "\n").enumerated() {
                    guard line.contains("MeetingDiagnosticString(") else { continue }
                    let allowed =
                        line.contains("MeetingDiagnosticString(\"agent.\\(Self.code(of: error))\")")
                        || line.contains("cliVersion.map { MeetingDiagnosticString($0) }")
                    #expect(allowed, "\(name):\(index + 1) builds a diagnostics string")
                }
                // A diagnostics event never takes the reply text or the question.
                for (index, line) in source.split(separator: "\n").enumerated()
                where line.contains("record(") || line.contains(".agentRun(") {
                    for word in ["question", "trimmed", "text:", "title", "packet"] {
                        #expect(!line.contains(word), "\(name):\(index + 1) has \(word)")
                    }
                }
            }
        }
        // Each file of both folders, with the probe, capture, drive and summary files.
        #expect(scanned >= 18)
    }
}
