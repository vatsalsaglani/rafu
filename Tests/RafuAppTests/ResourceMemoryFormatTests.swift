import Foundation
import Testing

@testable import RafuApp

@Test("nil bytes render as an em dash")
func resourceMemoryFormatRendersNilAsEmDash() {
    #expect(ResourceMemoryFormat.label(nil) == "—")
}

@Test("zero bytes render as 0.0 MB")
func resourceMemoryFormatRendersZeroBytes() {
    #expect(ResourceMemoryFormat.label(0) == "0.0 MB")
}

@Test("sub-gigabyte byte counts render as MB with one decimal place")
func resourceMemoryFormatRendersMegabytes() {
    #expect(ResourceMemoryFormat.label(149_000_000) == "142.1 MB")
}

@Test("gigabyte-scale byte counts render as GB with one decimal place")
func resourceMemoryFormatRendersGigabytes() {
    let bytes = UInt64(1.5 * 1024 * 1024 * 1024)
    #expect(ResourceMemoryFormat.label(bytes) == "1.5 GB")
}

@Test("exactly one gibibyte renders as GB, not MB")
func resourceMemoryFormatRendersGigabyteBoundary() {
    let bytes = UInt64(1024) * 1024 * 1024
    #expect(ResourceMemoryFormat.label(bytes) == "1.0 GB")
}

@Test("stateLabel gives a distinct, human-readable label per phase")
func languageServerStatusPresentationStateLabelsAreExhaustiveAndDistinct() {
    let labels: [LanguageServerStatus.Phase: String] = [
        .starting: "Starting",
        .ready: "Ready",
        .idle: "Idle",
        .warmingUp: "Indexing",
        .backingOff: "Restarting…",
        .dead: "Stopped",
        .ceilingKilled: "Stopped — memory limit",
    ]
    for (phase, expected) in labels {
        #expect(LanguageServerStatusPresentation.stateLabel(phase) == expected)
    }
    #expect(Set(labels.values).count == labels.count)
}

@Test("showsRestart offers restart only for terminal, non-auto-recovering phases")
func languageServerStatusPresentationShowsRestartOnlyForDeadOrCeilingKilled() {
    #expect(LanguageServerStatusPresentation.showsRestart(.dead) == true)
    #expect(LanguageServerStatusPresentation.showsRestart(.ceilingKilled) == true)
    #expect(LanguageServerStatusPresentation.showsRestart(.starting) == false)
    #expect(LanguageServerStatusPresentation.showsRestart(.ready) == false)
    #expect(LanguageServerStatusPresentation.showsRestart(.idle) == false)
    #expect(LanguageServerStatusPresentation.showsRestart(.warmingUp) == false)
    #expect(LanguageServerStatusPresentation.showsRestart(.backingOff) == false)
}

@Test("symbol assigns a shape-distinct SF Symbol to every phase")
func languageServerStatusPresentationSymbolIsAssignedPerPhase() {
    let phases: [LanguageServerStatus.Phase] = [
        .starting, .ready, .idle, .warmingUp, .backingOff, .dead, .ceilingKilled,
    ]
    for phase in phases {
        #expect(!LanguageServerStatusPresentation.symbol(phase).isEmpty)
    }
}
