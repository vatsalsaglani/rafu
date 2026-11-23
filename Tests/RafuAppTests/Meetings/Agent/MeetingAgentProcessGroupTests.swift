import Darwin
import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Hidden meeting agent: process group")
struct MeetingAgentProcessGroupTests {
    /// A shell starts a child that holds the output pipe, then waits. Ending
    /// only the shell would leave the pipe open for 30 s; ending the group
    /// closes it at once.
    @Test("Terminate ends each process that the CLI started")
    func terminateEndsTheGroup() async throws {
        let registry = MeetingAgentProcessRegistry()
        let runner = MeetingAgentSystemProcessRunner(registry: registry)
        let handle = try runner.start(
            MeetingAgentProcessSpec(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 30 & echo started; wait"],
                environment: MeetingAgentEnvironment.make(),
                currentDirectoryURL: FileManager.default.temporaryDirectory, standardInput: nil))
        let system = try #require(handle as? MeetingAgentSystemProcess)
        #expect(system.ownsGroup)

        var received = Data()
        var iterator = handle.output.makeAsyncIterator()
        while !String(decoding: received, as: UTF8.self).contains("started"),
            let chunk = await iterator.next()
        {
            received.append(chunk)
        }
        #expect(String(decoding: received, as: UTF8.self).contains("started"))

        let start = ContinuousClock.now
        handle.terminate()
        while await iterator.next() != nil {}
        _ = await handle.termination()
        #expect(ContinuousClock.now - start < .seconds(10))
        #expect(registry.count == 0)
    }

    @Test("Rafu's own process group is never a target")
    func ownGroupIsNotATarget() {
        #expect(!MeetingAgentSystemProcess.leadsOwnGroup(getpid()))
        #expect(!MeetingAgentSystemProcess.leadsOwnGroup(getpgrp()))
        #expect(!MeetingAgentSystemProcess.leadsOwnGroup(0))
        #expect(!MeetingAgentSystemProcess.leadsOwnGroup(-1))
    }
}
