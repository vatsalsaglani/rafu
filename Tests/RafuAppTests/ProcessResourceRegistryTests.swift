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

/// `.shared` is the canonical cross-lane instance terminal controllers (and
/// later lane-2 language servers) register into. This exercises the
/// terminal-shell shape end to end against `.shared` itself, complementing
/// the isolated-instance tests above.
@Test("Shared registry tracks a terminal-shell registration end to end")
func sharedRegistryTracksTerminalShellRegistration() async throws {
    let id = UUID()
    await ProcessResourceRegistry.shared.register(
        id: id, name: "Terminal 1", kind: .terminalShell, pid: getpid())

    let samples = await ProcessResourceRegistry.shared.sample()
    let sample = try #require(samples.first { $0.id == id })
    #expect(sample.name == "Terminal 1")
    #expect(sample.pid == getpid())
    if case .terminalShell = sample.kind {
        // expected
    } else {
        Issue.record("Expected .terminalShell, got \(sample.kind)")
    }

    await ProcessResourceRegistry.shared.unregister(id: id)
    let after = await ProcessResourceRegistry.shared.sample()
    #expect(after.first { $0.id == id } == nil)
}
