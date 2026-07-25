import Foundation
import Testing

@testable import RafuApp

// MARK: - Pure timeline arithmetic

@Test("Delta is signed, and the first reading of a session has no delta")
func timelineDeltaSigning() {
    #expect(MemoryTimelinePolicy.delta(from: nil, to: 200_000_000) == 0)
    #expect(MemoryTimelinePolicy.delta(from: 100, to: 150) == 50)
    #expect(MemoryTimelinePolicy.delta(from: 150, to: 100) == -50)
    #expect(MemoryTimelinePolicy.delta(from: 100, to: 100) == 0)
}

/// Resident sizes are `UInt64` but a drop is a negative delta — the
/// conversion must not wrap around into a huge positive number.
@Test("A large drop in resident memory stays negative rather than wrapping")
func timelineDeltaDoesNotWrap() {
    let delta = MemoryTimelinePolicy.delta(from: 400_000_000, to: 150_000_000)
    #expect(delta == -250_000_000)
}

@Test("Ring buffer drops oldest-first at the cap and keeps nothing at cap 0")
func timelineRingBuffer() {
    var buffer: [Int] = []
    for value in 1...5 {
        buffer = MemoryTimelinePolicy.appending(value, to: buffer, cap: 3)
    }
    #expect(buffer == [3, 4, 5])
    #expect(MemoryTimelinePolicy.appending(1, to: [1, 2], cap: 0).isEmpty)
    #expect(MemoryTimelinePolicy.appending(9, to: [], cap: 3) == [9])
}

@Test("Delta labels carry an explicit sign and a direction symbol")
func timelineDeltaLabels() {
    #expect(MemoryTimelinePolicy.deltaLabel(0) == "0 MB")
    #expect(MemoryTimelinePolicy.deltaLabel(18 * 1024 * 1024) == "+18.0 MB")
    #expect(MemoryTimelinePolicy.deltaLabel(-4 * 1024 * 1024) == "-4.0 MB")
    #expect(MemoryTimelinePolicy.deltaSymbol(1) == "arrow.up")
    #expect(MemoryTimelinePolicy.deltaSymbol(-1) == "arrow.down")
    #expect(MemoryTimelinePolicy.deltaSymbol(0) == "equal")
}

@Test("Sparkline normalization maps low to 0 and high to 1")
func timelineNormalization() {
    #expect(MemoryTimelinePolicy.normalized([]) == [])
    #expect(MemoryTimelinePolicy.normalized([100, 200, 300]) == [0, 0.5, 1])
}

/// A flat series has a zero range; dividing by it would produce NaN and a
/// blank graph. Flat memory should draw a flat line instead.
@Test("Sparkline normalization renders a flat series as a mid-line")
func timelineNormalizationFlatSeries() {
    #expect(MemoryTimelinePolicy.normalized([500, 500, 500]) == [0.5, 0.5, 0.5])
    #expect(MemoryTimelinePolicy.normalized([42]) == [0.5])
}

// MARK: - Recording

@MainActor
private func makeTimeline(readings: [UInt64]) -> MemoryTimeline {
    let timeline = MemoryTimeline()
    var remaining = readings
    timeline.sampleResident = {
        guard !remaining.isEmpty else { return nil }
        return remaining.removeFirst()
    }
    return timeline
}

@Test("Recording an event files it against a reading with the interval delta")
@MainActor
func timelineRecordsEventsWithDeltas() {
    let timeline = makeTimeline(readings: [100_000_000, 118_000_000, 114_000_000])
    timeline.record(.documentOpened, detail: "Foo.swift")
    timeline.record(.diffOpened, detail: "Bar.swift")
    timeline.record(.documentClosed, detail: "Foo.swift")

    #expect(timeline.events.count == 3)
    #expect(timeline.events[0].deltaBytes == 0)
    #expect(timeline.events[1].deltaBytes == 18_000_000)
    #expect(timeline.events[2].deltaBytes == -4_000_000)
    #expect(timeline.events[1].detail == "Bar.swift")
    #expect(timeline.readings == [100_000_000, 118_000_000, 114_000_000])
}

/// Periodic readings exist to give the sparkline resolution; surfacing them
/// as rows would bury real activity under one row every two seconds.
@Test("A periodic reading advances the series without adding an event row")
func timelinePeriodicReadingIsNotAnEvent() async {
    await MainActor.run {
        let timeline = makeTimeline(readings: [100, 130, 150])
        timeline.record(.terminalOpened, detail: "zsh 1")
        timeline.recordPeriodicReading()
        timeline.record(.terminalClosed, detail: "zsh 1")

        #expect(timeline.events.count == 2)
        #expect(timeline.readings == [100, 130, 150])
        // The second event's delta spans from the periodic reading, not from
        // the previous EVENT — the interval is what was actually measured.
        #expect(timeline.events[1].deltaBytes == 20)
    }
}

@Test("A failed sample records nothing at all")
@MainActor
func timelineSkipsFailedSamples() {
    let timeline = MemoryTimeline()
    timeline.sampleResident = { nil }
    timeline.record(.gitRefreshed)

    #expect(timeline.events.isEmpty)
    #expect(timeline.readings.isEmpty)
}

@Test("Recent events are newest-first and the ring is bounded")
@MainActor
func timelineRecentEventsOrderAndBound() {
    let timeline = makeTimeline(
        readings: (0..<(MemoryTimeline.eventCap + 5)).map { UInt64(100 + $0) })
    for index in 0..<(MemoryTimeline.eventCap + 5) {
        timeline.record(.documentOpened, detail: "file\(index)")
    }

    #expect(timeline.events.count == MemoryTimeline.eventCap)
    #expect(timeline.recentEvents.first?.detail == "file\(MemoryTimeline.eventCap + 4)")
    #expect(timeline.recentEvents.last?.detail == "file5")
}

@Test("Clearing drops events, readings, and the delta baseline")
@MainActor
func timelineClear() {
    let timeline = makeTimeline(readings: [100, 500])
    timeline.record(.documentOpened)
    timeline.clear()
    timeline.record(.documentOpened)

    #expect(timeline.events.count == 1)
    // A cleared baseline means the next event is a first reading again, not
    // a fabricated +400 jump against a value the user can no longer see.
    #expect(timeline.events[0].deltaBytes == 0)
}

// MARK: - Cross-window attribution

private func entry(detail: String, source: String) -> MemoryTimelineEntry {
    MemoryTimelineEntry(
        id: UUID(),
        kind: .documentOpened,
        detail: detail,
        source: source,
        residentBytes: 100,
        deltaBytes: 0,
        at: Date(timeIntervalSince1970: 0)
    )
}

/// Every Rafu window shares one process and so one timeline. A row filed by
/// another window must say so, or it reads as something the user just did in
/// the window they are looking at.
@Test("An event from another window is labelled with its origin")
func timelineSubtitleMarksForeignWindows() {
    let foreign = entry(detail: "Foo.swift", source: "other-project")
    #expect(
        MemoryTimelinePolicy.subtitle(for: foreign, currentWindow: "rafu")
            == "Foo.swift · in other-project")
}

/// Annotating the current window's own rows would put "in <this workspace>"
/// on nearly every row and bury the few that came from elsewhere.
@Test("An event from this window carries no origin label")
func timelineSubtitleOmitsCurrentWindow() {
    let local = entry(detail: "Foo.swift", source: "rafu")
    #expect(MemoryTimelinePolicy.subtitle(for: local, currentWindow: "rafu") == "Foo.swift")
}

@Test("App-level and detail-less events degrade cleanly")
func timelineSubtitleEdgeCases() {
    // Memory pressure belongs to no window: no source, so no origin label.
    let appLevel = entry(detail: "critical", source: "")
    #expect(MemoryTimelinePolicy.subtitle(for: appLevel, currentWindow: "rafu") == "critical")

    let sourceOnly = entry(detail: "", source: "other-project")
    #expect(
        MemoryTimelinePolicy.subtitle(for: sourceOnly, currentWindow: "rafu")
            == "in other-project")

    let bare = entry(detail: "", source: "")
    #expect(MemoryTimelinePolicy.subtitle(for: bare, currentWindow: "rafu").isEmpty)
}

@Test("Recording carries the originating window onto the entry")
@MainActor
func timelineRecordsSource() {
    let timeline = makeTimeline(readings: [100, 200])
    timeline.record(.documentOpened, detail: "Foo.swift", source: "rafu")
    timeline.record(.terminalOpened, detail: "zsh 1", source: "other-project")

    #expect(timeline.events[0].source == "rafu")
    #expect(timeline.events[1].source == "other-project")
}

// MARK: - Composition grouping

private func sample(
    _ name: String,
    _ kind: ProcessResourceRegistry.ProcessKind,
    _ bytes: UInt64?
) -> ProcessResourceRegistry.ProcessResourceSample {
    ProcessResourceRegistry.ProcessResourceSample(
        id: UUID(), name: name, kind: kind, pid: 1, residentBytes: bytes)
}

/// `groups(from:)` iterates `kindOrder`, so a kind missing from that list is
/// dropped from the Resources view with no error — the failure mode is a
/// process that silently does not exist. Adding a `ProcessKind` case makes
/// the switches in `MemoryComposition` fail to compile, but nothing forces
/// the author to extend `kindOrder`; this test is that force.
@Test("Every process kind has a composition section so none silently vanishes")
func compositionKindOrderCoversEveryKind() {
    #expect(
        Set(MemoryComposition.kindOrder)
            == Set(ProcessResourceRegistry.ProcessKind.allCases))
    #expect(MemoryComposition.kindOrder.count == Set(MemoryComposition.kindOrder).count)
}

@Test("Composition groups by kind in a fixed order, omitting empty categories")
func compositionGroupsInFixedOrder() {
    let groups = MemoryComposition.groups(from: [
        sample("sourcekit-lsp", .languageServer, 300),
        sample("zsh 1", .terminalShell, 100),
        sample("zsh 2", .terminalShell, 200),
    ])

    #expect(groups.map(\.kind) == [.terminalShell, .languageServer])
    #expect(groups[0].count == 2)
    #expect(groups[0].totalBytes == 300)
    #expect(groups[1].totalBytes == 300)
}

@Test("Rows inside a group sort by descending size, then by name")
func compositionGroupRowOrder() {
    let groups = MemoryComposition.groups(from: [
        sample("zsh b", .terminalShell, 100),
        sample("zsh a", .terminalShell, 100),
        sample("zsh big", .terminalShell, 900),
    ])

    #expect(groups[0].rows.map(\.name) == ["zsh big", "zsh a", "zsh b"])
}

/// A pid that exited between registration and sampling reports `nil`. The
/// group must still total its surviving rows rather than collapsing to "—".
@Test("A group totals surviving rows and is nil only when every row exited")
func compositionGroupTotalsWithExitedProcesses() {
    let mixed = MemoryComposition.groups(from: [
        sample("zsh 1", .terminalShell, 100),
        sample("zsh 2", .terminalShell, nil),
    ])
    #expect(mixed[0].totalBytes == 100)

    let allGone = MemoryComposition.groups(from: [sample("zsh 1", .terminalShell, nil)])
    #expect(allGone[0].totalBytes == nil)
}

// MARK: - Content metrics

@Test("Content rows report tab, terminal, index, and diff counts")
func contentRowsReportCounts() {
    var metrics = WorkspaceContentMetrics()
    metrics.mountedDocuments = 3
    metrics.hibernatedDocuments = 5
    metrics.dirtyDocuments = 1
    metrics.terminalSessions = 2
    metrics.fileIndexEntries = 1204
    metrics.hasOpenDiff = true

    let rows = MemoryComposition.contentRows(for: metrics)
    #expect(rows.map(\.id) == ["documents", "dirty", "terminals", "fileIndex", "diff"])
    #expect(rows[0].value == "8")
    #expect(rows[0].note == "3 loaded, 5 hibernated")
    #expect(rows[3].value == "1204")
}

/// An empty category reads as "nothing here" only if it is absent; a row of
/// zeros is noise in a 340pt-wide popover.
@Test("Content rows omit zero-valued categories entirely")
func contentRowsOmitEmptyCategories() {
    #expect(MemoryComposition.contentRows(for: WorkspaceContentMetrics()).isEmpty)

    var indexOnly = WorkspaceContentMetrics()
    indexOnly.fileIndexEntries = 0
    let rows = MemoryComposition.contentRows(for: indexOnly)
    // A built-but-empty index is a real state (an empty repo), distinct from
    // "never built" — so it is reported where a zero tab count is not.
    #expect(rows.map(\.id) == ["fileIndex"])
    #expect(rows[0].value == "0")
}

@Test("A truncated file index says so")
func contentRowsDiscloseIndexTruncation() {
    var metrics = WorkspaceContentMetrics()
    metrics.fileIndexEntries = 200_000
    metrics.isFileIndexTruncated = true

    #expect(MemoryComposition.contentRows(for: metrics)[0].note == "truncated")
}
