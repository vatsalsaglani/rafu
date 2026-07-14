import Darwin
import Foundation
import Testing

@testable import RafuApp

@Test("Registering the current process yields a sample with resident memory")
func registryReportsOwnProcessResidentMemory() async throws {
    let registry = ProcessResourceRegistry()
    let id = UUID()
    await registry.register(id: id, name: "self", kind: .other, pid: getpid())

    let samples = await registry.sample()
    #expect(samples.count == 1)
    let sample = try #require(samples.first)
    #expect(sample.id == id)
    #expect(sample.pid == getpid())
    let residentBytes = try #require(sample.residentBytes)
    #expect(residentBytes > 1_000_000)
}

@Test("Unregistering removes the process from future samples")
func registryUnregisterRemovesProcess() async throws {
    let registry = ProcessResourceRegistry()
    let id = UUID()
    await registry.register(id: id, name: "self", kind: .other, pid: getpid())

    await registry.unregister(id: id)

    let samples = await registry.sample()
    #expect(samples.isEmpty)
}

@Test("Registering the same id twice replaces the previous entry")
func registryLastWriteWins() async throws {
    let registry = ProcessResourceRegistry()
    let id = UUID()
    await registry.register(id: id, name: "first", kind: .terminalShell, pid: getpid())
    await registry.register(id: id, name: "second", kind: .git, pid: getpid())

    let samples = await registry.sample()
    #expect(samples.count == 1)
    #expect(samples.first?.name == "second")
}

@Test("Unregistering an unknown id is a no-op")
func registryUnregisterUnknownIDIsNoOp() async throws {
    let registry = ProcessResourceRegistry()
    await registry.unregister(id: UUID())

    let samples = await registry.sample()
    #expect(samples.isEmpty)
}
