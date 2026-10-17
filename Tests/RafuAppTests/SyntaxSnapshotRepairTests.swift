import AppKit
import Foundation
import SwiftTreeSitter
import Testing

@testable import RafuApp

/// Suspends the actual worker operation at its first request. No sleep, polling,
/// or parser-duration assumption is needed to hold a parse behind burst edits.
private actor SyntaxRepairGate {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var started = false
    private(set) var versions: [Int] = []
    private(set) var edits: [Bool] = []
    private(set) var observedCancellation = false

    func enter(_ request: SyntaxSnapshotRequest) async {
        versions.append(request.version)
        edits.append(request.edit != nil)
        guard versions.count == 1 else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            started = true
            startContinuation?.resume()
            startContinuation = nil
        }
        observedCancellation = Task.isCancelled
    }

    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { startContinuation = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private func syntaxRepairSorted(_ spans: [SyntaxSpan]) -> [SyntaxSpan] {
    spans.sorted {
        if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
        if $0.range.length != $1.range.length { return $0.range.length < $1.range.length }
        return $0.themeKey < $1.themeKey
    }
}

@MainActor
@Test("Slow syntax parsing retains one pending snapshot and resets after burst edits")
func syntaxRepairBoundsBurstAndPreservesMultilineUndo() async throws {
    let registry = GrammarRegistry()
    let configuration = try await registry.configuration(for: .swift)
    let parser = try #require(SyntaxParsingActor(configuration: configuration))
    let reference = try #require(SyntaxParsingActor(configuration: configuration))
    let gate = SyntaxRepairGate()
    var appliedVersions: [Int] = []
    let worker = SyntaxSnapshotWorker(
        operation: { request in
            await gate.enter(request)
            await parser.process(request)
        },
        didFinish: { appliedVersions.append($0) })
    let original = "let face = \"😀\"\r\nlet value = 1\n"
    worker.submit(SyntaxSnapshotRequest(text: original, version: 1, edit: nil))
    await gate.waitForStart()

    var previous = original
    for version in 2...100 {
        // A whole-document replacement is a valid contiguous InputEdit. Each
        // snapshot differs, including a final comment that changes every line.
        let next = version == 100 ? "/*\n\(previous)*/\n" : previous + "let v\(version) = 1\n"
        worker.submit(
            SyntaxSnapshotRequest(
                text: next, version: version,
                edit: .init(
                    startUTF16: 0, oldEndUTF16: previous.utf16.count,
                    newEndUTF16: next.utf16.count)))
        #expect(worker.metrics.pendingCount == 1)
        previous = next
    }
    #expect(worker.metrics.peakPendingCount == 1)
    #expect(worker.metrics.peakRetainedSnapshotCount == 2)
    #expect(worker.metrics.coalescedSnapshotCount == 98)
    await gate.release()
    await worker.waitUntilIdle()
    #expect(await gate.versions == [1, 100])
    #expect(await gate.edits == [false, false])
    #expect(worker.metrics.fullResetCount == 2)
    #expect(worker.metrics.pendingCount == 0)
    #expect(worker.metrics.activeCount == 0)
    #expect(appliedVersions == [100])

    await reference.updateSnapshot(previous, version: 1)
    let finalRange = NSRange(location: 0, length: previous.utf16.count)
    let actual = try #require(await parser.tokens(inUTF16: finalRange, version: 100))
    let expected = await reference.tokens(inUTF16: finalRange)
    #expect(syntaxRepairSorted(actual) == syntaxRepairSorted(expected))
    #expect(actual.contains { $0.themeKey == "comment" })
    #expect(await parser.tokens(inUTF16: finalRange, version: 99) == nil)

    // Undo the coalesced change through the same worker. Reusing the reset
    // baseline must produce exactly the original document's highlight spans.
    worker.submit(
        SyntaxSnapshotRequest(
            text: original, version: 101,
            edit: .init(
                startUTF16: 0, oldEndUTF16: previous.utf16.count,
                newEndUTF16: original.utf16.count)))
    await worker.waitUntilIdle()
    #expect(appliedVersions == [100, 101])
    #expect(await parser.lastReparseMetric?.wasIncremental == true)
    await reference.updateSnapshot(original, version: 2)
    let originalRange = NSRange(location: 0, length: original.utf16.count)
    let undone = try #require(await parser.tokens(inUTF16: originalRange, version: 101))
    let originalSpans = await reference.tokens(inUTF16: originalRange)
    #expect(syntaxRepairSorted(undone) == syntaxRepairSorted(originalSpans))
    worker.stop()
}

@MainActor
@Test("Stopping syntax work drops pending text and cancels the active operation")
func syntaxRepairStopCancelsWork() async throws {
    let registry = GrammarRegistry()
    let configuration = try await registry.configuration(for: .swift)
    let parser = try #require(SyntaxParsingActor(configuration: configuration))
    let gate = SyntaxRepairGate()
    var finished: [Int] = []
    let worker = SyntaxSnapshotWorker(
        operation: { request in
            await gate.enter(request)
            await parser.process(request)
        },
        didFinish: { finished.append($0) })
    worker.submit(SyntaxSnapshotRequest(text: "let a = 1", version: 1, edit: nil))
    await gate.waitForStart()
    worker.submit(SyntaxSnapshotRequest(text: "let b = 2", version: 2, edit: nil))
    worker.stop()
    #expect(worker.metrics.pendingCount == 0)
    worker.submit(SyntaxSnapshotRequest(text: "let c = 3", version: 3, edit: nil))
    await gate.release()
    await worker.waitUntilIdle()
    #expect(await gate.versions == [1])
    #expect(await gate.observedCancellation)
    #expect(finished.isEmpty)
    #expect(await parser.lastReparseMetric == nil)
    #expect(await parser.tokens(inUTF16: NSRange(location: 0, length: 9)).isEmpty)
}

@MainActor
@Test("A suspended syntax operation does not retain its worker")
func syntaxRepairWorkerReleasesDuringParse() async {
    let gate = SyntaxRepairGate()
    var worker: SyntaxSnapshotWorker? = SyntaxSnapshotWorker(
        operation: { request in await gate.enter(request) }, didFinish: { _ in })
    weak var releasedWorker: SyntaxSnapshotWorker?
    releasedWorker = worker
    worker?.submit(SyntaxSnapshotRequest(text: "text", version: 1, edit: nil))
    await gate.waitForStart()
    worker = nil
    #expect(releasedWorker == nil)
    await gate.release()
}

@Test("A missing syntax edit resets the tree and older edits cannot replace it")
func syntaxRepairVersionGapAndStaleQueries() async throws {
    let registry = GrammarRegistry()
    let configuration = try await registry.configuration(for: .swift)
    let parser = try #require(SyntaxParsingActor(configuration: configuration))
    let reference = try #require(SyntaxParsingActor(configuration: configuration))
    await parser.updateSnapshot("let a = 1", version: 1)
    let newest = "/* 😀\r\ncomment */\nlet fresh = 3"
    // This delta is relative to an omitted version 2. It must not edit v1's tree.
    await parser.applyEdit(
        startUTF16: 20, oldEndUTF16: 20, newEndUTF16: 21, newText: newest, version: 3)
    #expect(await parser.lastReparseMetric?.wasIncremental == false)
    await parser.applyEdit(
        startUTF16: 0, oldEndUTF16: 0, newEndUTF16: 1, newText: "stale", version: 2)
    await reference.updateSnapshot(newest, version: 1)
    let range = NSRange(location: 0, length: newest.utf16.count)
    let actual = try #require(await parser.tokens(inUTF16: range, version: 3))
    let expected = await reference.tokens(inUTF16: range)
    #expect(syntaxRepairSorted(actual) == syntaxRepairSorted(expected))
    #expect(await parser.tokens(inUTF16: range, version: 2) == nil)
    #expect(await parser.tokens(inUTF16: range, version: 4) == nil)
}

private func syntaxRepairReferencePoint(_ offset: Int, _ text: String) -> Point {
    let units = Array(text.utf16)
    let limit = min(max(offset, 0), units.count)
    var row = 0
    var lineStart = 0
    for index in 0..<limit where units[index] == 10 {
        row += 1
        lineStart = index + 1
    }
    return Point(row: row, column: (limit - lineStart) * 2)
}

@Test("Indexed syntax points preserve UTF-16, LF, CRLF, and replacement boundaries")
func syntaxRepairIndexedPointsAcrossEdits() {
    let original = "a\r\n😀\nb\r"
    let boundaries = [0, 1, 2, 3, 5, 6, 7, 8]
    for start in boundaries {
        for end in boundaries where end >= start {
            for replacement in ["", "X", "\n", "😀\r\n", "\r", "\u{2028}"] {
                let updated = (original as NSString).replacingCharacters(
                    in: NSRange(location: start, length: end - start), with: replacement)
                var index = SyntaxByteOffset.LineIndex(original)
                index.applyEdit(
                    startUTF16: start, oldEndUTF16: end,
                    newEndUTF16: start + replacement.utf16.count, newText: updated)
                #expect(index.length == updated.utf16.count)
                for offset in -1...(updated.utf16.count + 1) {
                    #expect(
                        index.point(forUTF16Offset: offset)
                            == syntaxRepairReferencePoint(offset, updated))
                }
            }
        }
    }
}

@Test("Syntax point lookup scans no prefix and edits scan only replacement text")
func syntaxRepairIndexedPointScanBound() {
    let original = String(repeating: "let x = 1\r\n", count: 20_000)
    var index = SyntaxByteOffset.LineIndex(original)
    let baselineScans = index.scannedUTF16Count
    for offset in [0, 10, original.utf16.count - 1, original.utf16.count] {
        #expect(index.point(forUTF16Offset: offset) == syntaxRepairReferencePoint(offset, original))
    }
    #expect(index.scannedUTF16Count == baselineScans)
    let insertion = "😀\n"
    let offset = original.utf16.count - 3
    let updated = (original as NSString).replacingCharacters(
        in: NSRange(location: offset, length: 0), with: insertion)
    index.applyEdit(
        startUTF16: offset, oldEndUTF16: offset,
        newEndUTF16: offset + insertion.utf16.count, newText: updated)
    #expect(index.scannedUTF16Count == baselineScans + insertion.utf16.count)
    #expect(
        index.point(forUTF16Offset: updated.utf16.count)
            == syntaxRepairReferencePoint(updated.utf16.count, updated))
}

@MainActor
@Test("Syntax teardown is final and suppression still tracks text edits")
func syntaxRepairPipelineTracksSuppressedEditsAndStops() async throws {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
    let textView = RafuTextView.makeTextKit1()
    textView.frame = scrollView.bounds
    scrollView.documentView = textView
    textView.string = "let face = \"😀\"\n"
    let pipeline = NeonSyntaxHighlightingPipeline(
        textView: textView, theme: RafuThemeCatalog.indigo, fileExtension: "swift")
    await pipeline.waitForSyntaxWorkForTesting()
    #expect(pipeline.hasLiveGrammarActorForTesting)
    pipeline.isSuppressed = true
    pipeline.applyBaseStyleAndInvalidate()
    let oldLength = textView.string.utf16.count
    let current = "let n = 42\n"
    textView.string = current
    pipeline.didProcessEditing(
        editedMask: .editedCharacters,
        editedRange: NSRange(location: 0, length: current.utf16.count),
        changeInLength: current.utf16.count - oldLength)
    pipeline.isSuppressed = false
    pipeline.applyBaseStyleAndInvalidate()
    await pipeline.waitForSyntaxWorkForTesting()
    #expect(pipeline.hasLiveGrammarActorForTesting)
    // Check applied tokens for the current nonempty text, not just actor
    // creation. Offset 8 was not a number in the old emoji-string fixture.
    let layoutManager = try #require(textView.layoutManager)
    let numberHex = try #require(RafuThemeCatalog.indigo.syntax["number"]?.color)
    let actualNumberColor =
        layoutManager.temporaryAttribute(
            .foregroundColor, atCharacterIndex: 8, effectiveRange: nil) as? NSColor
    #expect(actualNumberColor == NSColor(rafuHex: numberHex))
    #expect(textView.string == current)
    pipeline.tearDown()
    pipeline.update(theme: RafuThemeCatalog.khadi, fileExtension: "json")
    await pipeline.waitForSyntaxWorkForTesting()
    #expect(!pipeline.hasLiveGrammarActorForTesting)
    #expect(pipeline.syntaxQueueMetricsForTesting == nil)
}

@MainActor
private final class SyntaxRepairTextDelegate: NSObject, NSTextStorageDelegate, NSTextViewDelegate {
    let manager = UndoManager()
    weak var pipeline: NeonSyntaxHighlightingPipeline?

    nonisolated func undoManager(for view: NSTextView) -> UndoManager? {
        MainActor.assumeIsolated { manager }
    }

    nonisolated func textStorage(
        _ storage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange, changeInLength delta: Int
    ) {
        MainActor.assumeIsolated {
            pipeline?.didProcessEditing(
                editedMask: editedMask, editedRange: editedRange, changeInLength: delta)
        }
    }
}

@MainActor
@Test("Multi-caret undo keeps Neon ranges valid through coalesced syntax work")
func syntaxRepairPipelineBurstUndo() async throws {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
    let textView = RafuTextView.makeTextKit1()
    textView.frame = scrollView.bounds
    scrollView.documentView = textView
    textView.allowsUndo = true
    let delegate = SyntaxRepairTextDelegate()
    delegate.manager.groupsByEvent = false
    textView.delegate = delegate
    let original = "let shared = \"😀\"\r\nlet shared = 2\r\n"
    textView.string = original
    let pipeline = NeonSyntaxHighlightingPipeline(
        textView: textView, theme: RafuThemeCatalog.indigo, fileExtension: "swift")
    defer { pipeline.tearDown() }
    delegate.pipeline = pipeline
    textView.textStorage?.delegate = delegate
    await pipeline.waitForSyntaxWorkForTesting()
    #expect(pipeline.hasLiveGrammarActorForTesting)

    // The token task captures the original version synchronously. The two
    // shrinking edits below happen before it can query or apply that version.
    pipeline.applyBaseStyleAndInvalidate()
    textView.setSelectedRange(NSRange(location: 4, length: 6))
    textView.selectNextOccurrence()
    textView.deleteBackward(nil)
    #expect(textView.string == "let  = \"😀\"\r\nlet  = 2\r\n")
    await pipeline.waitForSyntaxWorkForTesting()
    delegate.manager.undo()
    #expect(textView.string == original)
    await pipeline.waitForSyntaxWorkForTesting()
    let metrics = try #require(pipeline.syntaxQueueMetricsForTesting)
    #expect(metrics.peakPendingCount == 1)
    #expect(metrics.pendingCount == 0)
}

@MainActor
@Test("Cached fallback rules retain token order and style changes replace cached values")
func syntaxRepairFallbackCachePreservesStyles() {
    let source = "func sample() { let count = 42 /* 😀 */ }"
    let highlighter = SyntaxHighlighter(theme: RafuThemeCatalog.indigo, fileExtension: "swift")
    let range = NSRange(location: 0, length: source.utf16.count)
    let first = highlighter.tokenApplication(in: source, targetRange: range)
    let second = highlighter.tokenApplication(in: source, targetRange: range)
    #expect(first.tokens.map(\.name) == second.tokens.map(\.name))
    #expect(first.tokens.map(\.range) == second.tokens.map(\.range))
    #expect(
        highlighter.matches(theme: RafuThemeCatalog.indigo, fileExtension: "SWIFT", fileName: ""))
    #expect(
        !highlighter.matches(theme: RafuThemeCatalog.khadi, fileExtension: "swift", fileName: ""))
    let keyword = first.tokens.first { $0.name == "keyword" }
    if let keyword {
        let firstColor = highlighter.attributes(for: keyword)[.foregroundColor] as? NSColor
        let cachedColor = highlighter.attributes(for: keyword)[.foregroundColor] as? NSColor
        #expect(firstColor == cachedColor)
        #expect(firstColor != nil)
    } else {
        Issue.record("fallback did not emit a keyword")
    }
}

@Test("Indexed incremental parses match full parses after Unicode and multiline edits")
func syntaxRepairIndexedIncrementalEquivalence() async throws {
    let registry = GrammarRegistry()
    let configuration = try await registry.configuration(for: .swift)
    let parser = try #require(SyntaxParsingActor(configuration: configuration))
    let reference = try #require(SyntaxParsingActor(configuration: configuration))
    var text = "let face = \"😀\"\r\nfunc f() {\r\n    let v = 1\r\n    return v\r\n}\r\n"
    await parser.updateSnapshot(text, version: 1)
    let replacements = [
        ("\"😀\"", "\"😀!\""),
        ("\r\n    let v = 1\r\n", "\n    let v = \"é\"\n"),
        ("func f() {", "/*\nfunc f() {"),
        ("}\r\n", "}\r\n*/\nlet done = true\n"),
        ("/*\n", ""),
    ]
    for (index, replacement) in replacements.enumerated() {
        let oldRange = (text as NSString).range(of: replacement.0)
        #expect(oldRange.location != NSNotFound)
        let next = (text as NSString).replacingCharacters(in: oldRange, with: replacement.1)
        let version = index + 2
        await parser.applyEdit(
            startUTF16: oldRange.location, oldEndUTF16: NSMaxRange(oldRange),
            newEndUTF16: oldRange.location + replacement.1.utf16.count,
            newText: next, version: version)
        #expect(await parser.lastReparseMetric?.wasIncremental == true)
        await reference.updateSnapshot(next, version: version)
        let queryRange = NSRange(location: 0, length: next.utf16.count)
        let actual = try #require(await parser.tokens(inUTF16: queryRange, version: version))
        let expected = await reference.tokens(inUTF16: queryRange)
        #expect(syntaxRepairSorted(actual) == syntaxRepairSorted(expected))
        text = next
    }
}

@MainActor
@Test("Guard override repaints regex tokens through the editor coordinator")
func syntaxRepairFallbackRepaintsThroughGuardCaller() throws {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
    let textView = RafuTextView.makeTextKit1()
    textView.frame = scrollView.bounds
    scrollView.documentView = textView
    let document = EditorDocument(
        url: URL(fileURLWithPath: "/tmp/rafu-syntax-repair.rafusyntaxfallback"))
    let grammarID = GrammarLanguageID.languageID(
        forExtension: document.url.pathExtension, fileName: document.url.lastPathComponent)
    #expect(grammarID == nil)
    document.applyGuardDecision(.guarded(reason: .longLine(length: 10_001)))
    let coordinator = CodeEditorView.Coordinator(
        document: document, theme: RafuThemeCatalog.indigo, findState: nil)
    coordinator.textView = textView
    coordinator.installSyntaxPipeline(for: textView)
    defer { coordinator.tearDownSyntaxPipeline() }
    textView.textStorage?.delegate = coordinator
    coordinator.syncGuardSuppression(forceRepaint: true)

    // Load text while suppressed, as the editor load path does. The unknown
    // extension must use the fallback when the banner override repaints it.
    textView.textStorage?.replaceCharacters(
        in: NSRange(location: 0, length: 0), with: "let n = 42\n")
    coordinator.syncGuardSuppression(forceRepaint: true)
    let layoutManager = try #require(textView.layoutManager)
    let beforeOverride =
        layoutManager.temporaryAttribute(
            .foregroundColor, atCharacterIndex: 8, effectiveRange: nil) as? NSColor
    #expect(beforeOverride == nil)
    document.overrideGuard()
    coordinator.syncGuardSuppression()
    let numberHex = try #require(RafuThemeCatalog.indigo.syntax["number"]?.color)
    let afterOverride =
        layoutManager.temporaryAttribute(
            .foregroundColor, atCharacterIndex: 8, effectiveRange: nil) as? NSColor
    #expect(afterOverride == NSColor(rafuHex: numberHex))
    #expect(!document.suppressesSyntax)
}
