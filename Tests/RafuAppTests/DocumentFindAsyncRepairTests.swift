import AppKit
import Foundation
import Synchronization
import Testing

@testable import RafuApp

@MainActor
@Suite("Document Find bounded asynchronous search")
struct DocumentFindAsyncRepairTests {
    @Test("Closed Find skips edits and reopen searches the current revision")
    func closeEditReopen() async {
        let counter = FindRepairSearchCounter()
        let textView = makeTextView("cat cat")
        let state = DocumentFindState()
        let controller = NSTextViewFindController(textView: textView) {
            await counter.search($0)
        }
        controller.matchHighlightColor = .systemYellow
        state.attach(controller)
        state.query = "cat"
        state.refresh()
        textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 3), with: "dog")
        await controller.waitForSearchCompletion()
        #expect(await counter.count == 0)

        state.activate()
        await controller.waitForSearchCompletion()
        #expect(state.matchCount == 1)
        #expect(await counter.count == 1)
        #expect(highlight(in: textView, at: 4) == .systemYellow)

        // Cached refresh and attribute-only edits must not rescan the text.
        state.refresh()
        textView.textStorage?.addAttribute(
            .foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 1))
        await controller.waitForSearchCompletion()
        #expect(await counter.count == 1)
        state.deactivate()
        #expect(highlight(in: textView, at: 4) == nil)
        textView.textStorage?.replaceCharacters(in: NSRange(location: 4, length: 3), with: "dog")
        state.refresh()
        await controller.waitForSearchCompletion()
        #expect(await counter.count == 1)
        state.activate()
        await controller.waitForSearchCompletion()
        #expect(state.matchCount == 0)
        #expect(await counter.count == 2)
        state.detach(controller)
    }

    @Test("One running search retains only the newest pending request and rejects stale completion")
    func newestPendingRequestWins() async throws {
        let gate = FindRepairSearchGate()
        let textView = makeTextView("old")
        let state = DocumentFindState()
        let controller = NSTextViewFindController(textView: textView) { await gate.search($0) }
        controller.matchHighlightColor = .systemYellow
        state.attach(controller)
        state.query = "old"
        state.activate()
        let first = try #require(await gate.waitForRequests(1).first)

        for index in 0..<40 {
            textView.string = "new \(index)"
            state.refresh()
        }
        state.query = "new"
        #expect(await gate.requestCount == 1)
        await gate.finish(
            first.id,
            result: .matches([
                TextSearchMatch(range: NSRange(location: 0, length: 3), replacement: "")
            ]))
        let requests = await gate.waitForRequests(2)
        let latest = try #require(requests.last)
        #expect(latest.text == "new 39")
        #expect(latest.key.pattern.query == "new")
        #expect(state.matchCount == 0)
        #expect(highlight(in: textView, at: 0) == nil)

        await gate.finish(
            latest.id,
            result: .matches([
                TextSearchMatch(range: NSRange(location: 0, length: 3), replacement: "")
            ]))
        await controller.waitForSearchCompletion()
        #expect(state.matchCount == 1)
        #expect(await gate.requestCount == 2)
        #expect(highlight(in: textView, at: 0) == .systemYellow)
        state.detach(controller)
    }

    @Test("Closing and detaching Find reject results from a matcher that ignores cancellation")
    func closeAndDetachRejectStaleResults() async throws {
        let gate = FindRepairSearchGate()
        let textView = makeTextView("cat")
        let state = DocumentFindState()
        let controller = NSTextViewFindController(textView: textView) { await gate.search($0) }
        controller.matchHighlightColor = .systemYellow
        state.attach(controller)
        state.query = "cat"
        state.activate()
        let first = try #require(await gate.waitForRequests(1).first)
        state.deactivate()
        await gate.finish(
            first.id,
            result: .matches([
                TextSearchMatch(range: NSRange(location: 0, length: 3), replacement: "")
            ]))
        await controller.waitForSearchCompletion()
        #expect(state.matchCount == 0)
        #expect(highlight(in: textView, at: 0) == nil)

        state.activate()
        let second = try #require(await gate.waitForRequests(2).last)
        state.detach(controller)
        await gate.finish(second.id, result: .failure("stale error"))
        await controller.waitForSearchCompletion()
        #expect(state.errorMessage == nil)
        #expect(state.matchCount == 0)
        #expect(!state.isActive)
    }

    @Test("Query and option changes invalidate cache; invalid regex leaves text unchanged")
    func queryOptionsAndInvalidRegex() async {
        let counter = FindRepairSearchCounter()
        let textView = makeTextView("Cat cat cat_ scatter")
        let state = DocumentFindState()
        let controller = NSTextViewFindController(textView: textView) { await counter.search($0) }
        state.attach(controller)
        state.query = "cat"
        state.activate()
        await controller.waitForSearchCompletion()
        #expect(state.matchCount == 4)
        state.options = [.wholeWord]
        await controller.waitForSearchCompletion()
        #expect(state.matchCount == 2)
        state.options = [.wholeWord, .caseSensitive]
        await controller.waitForSearchCompletion()
        #expect(state.matchCount == 1)
        #expect(await counter.count == 3)

        state.options = [.regularExpression]
        state.query = "("
        await controller.waitForSearchCompletion()
        #expect(state.errorMessage != nil)
        state.replaceAll()
        await controller.waitForSearchCompletion()
        #expect(textView.string == "Cat cat cat_ scatter")
        state.query = "cat"
        await controller.waitForSearchCompletion()
        #expect(state.errorMessage == nil)
        #expect(state.matchCount == 4)
        let count = await counter.count
        state.query = ""
        await controller.waitForSearchCompletion()
        #expect(state.matchCount == 0)
        #expect(state.errorMessage == nil)
        #expect(await counter.count == count)
        state.detach(controller)
    }

    @Test("Replacing the attached controller rejects old results and stale detach")
    func replacedControllerRejectsOldResult() async throws {
        let gate = FindRepairSearchGate()
        let oldTextView = makeTextView("cat cat")
        let newTextView = makeTextView("cat")
        let state = DocumentFindState()
        let oldController = NSTextViewFindController(textView: oldTextView) {
            await gate.search($0)
        }
        state.attach(oldController)
        state.query = "cat"
        state.activate()
        let request = try #require(await gate.waitForRequests(1).first)
        let newController = NSTextViewFindController(textView: newTextView)
        state.attach(newController)
        await newController.waitForSearchCompletion()
        state.detach(oldController)
        #expect(state.isActive)
        #expect(state.matchCount == 1)
        await gate.finish(request.id, result: .failure("old controller"))
        await oldController.waitForSearchCompletion()
        #expect(state.errorMessage == nil)
        #expect(state.matchCount == 1)
        state.detach(newController)
    }

    @Test("Closed Find Next uses the current revision and reuses cached results")
    func explicitNavigationWhileClosed() async {
        let counter = FindRepairSearchCounter()
        let textView = makeTextView("🙂 cat cat")
        let state = DocumentFindState()
        let controller = NSTextViewFindController(textView: textView) { await counter.search($0) }
        state.attach(controller)
        state.query = "cat"
        state.findNext()
        await controller.waitForSearchCompletion()
        #expect(!state.isActive)
        #expect(state.matchCount == 2)
        #expect(textView.selectedRange() == NSRange(location: 3, length: 3))
        state.findNext()
        await controller.waitForSearchCompletion()
        #expect(textView.selectedRange() == NSRange(location: 7, length: 3))
        #expect(await counter.count == 1)
        state.findPrevious()
        #expect(textView.selectedRange() == NSRange(location: 3, length: 3))
        textView.string = "cat"
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        state.findNext()
        await controller.waitForSearchCompletion()
        #expect(state.matchCount == 1)
        #expect(textView.selectedRange() == NSRange(location: 0, length: 3))
        #expect(await counter.count == 2)
        state.detach(controller)
    }

    @Test("Repeated commands while search runs preserve navigation order")
    func pendingNavigationCommands() async throws {
        let gate = FindRepairSearchGate()
        let textView = makeTextView("cat cat cat")
        let state = DocumentFindState()
        let controller = NSTextViewFindController(textView: textView) { await gate.search($0) }
        state.attach(controller)
        state.query = "cat"
        state.findNext()
        let request = try #require(await gate.waitForRequests(1).first)
        state.findNext()
        state.findPrevious()
        state.findNext()
        await gate.finish(request.id, result: await DocumentFindSearch.execute(request))
        await controller.waitForSearchCompletion()
        #expect(textView.selectedRange() == NSRange(location: 4, length: 3))
        #expect(await gate.requestCount == 1)
        state.detach(controller)
    }

    @Test(
        "A new query or options clear the old zero-length navigation anchor",
        arguments: [false, true])
    func changedPatternResetsZeroLengthNavigation(changeOptions: Bool) async throws {
        let gate = FindRepairSearchGate()
        let textView = makeTextView(changeOptions ? "^^" : "aa")
        let state = DocumentFindState()
        let controller = NSTextViewFindController(textView: textView) { await gate.search($0) }
        state.attach(controller)
        state.options = [.regularExpression]
        state.query = changeOptions ? "^" : "(?=a)"
        state.findNext()
        let initial = try #require(await gate.waitForRequests(1).first)
        await gate.finish(initial.id, result: await DocumentFindSearch.execute(initial))
        await controller.waitForSearchCompletion()
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))

        if changeOptions { state.options = [] } else { state.query = "a" }
        state.findNext()
        let changed = try #require(await gate.waitForRequests(2).last)
        await gate.finish(changed.id, result: await DocumentFindSearch.execute(changed))
        await controller.waitForSearchCompletion()
        #expect(textView.selectedRange() == NSRange(location: 0, length: 1))
        state.detach(controller)
    }

    @Test("Two Replace commands during a gated search each replace one match and preserve undo")
    func repeatedPendingReplaceCommands() async throws {
        let gate = FindRepairSearchGate()
        let textView = makeTextView("cat cat")
        let undo = UndoManager()
        undo.groupsByEvent = false
        let host = FindRepairUndoHost(manager: undo)
        textView.delegate = host
        textView.allowsUndo = true
        defer { withExtendedLifetime(host) {} }
        textView.setSelectedRange(NSRange(location: 0, length: 3))
        let state = DocumentFindState()
        let controller = NSTextViewFindController(textView: textView) { await gate.search($0) }
        state.attach(controller)
        state.query = "cat"
        state.replacement = "dog"
        state.replaceCurrent()
        let first = try #require(await gate.waitForRequests(1).first)
        state.replaceCurrent()
        await gate.finish(first.id, result: await DocumentFindSearch.execute(first))
        let second = try #require(await gate.waitForRequests(2).last)
        #expect(textView.string == "dog cat")
        await gate.finish(second.id, result: await DocumentFindSearch.execute(second))
        let navigation = try #require(await gate.waitForRequests(3).last)
        await gate.finish(navigation.id, result: await DocumentFindSearch.execute(navigation))
        await controller.waitForSearchCompletion()
        #expect(textView.string == "dog dog")
        #expect(state.matchCount == 0)
        undo.undo()
        await controller.waitForSearchCompletion()
        #expect(textView.string == "dog cat")
        undo.undo()
        await controller.waitForSearchCompletion()
        #expect(textView.string == "cat cat")
        state.detach(controller)
    }

    @Test("Unicode current and all replacements each preserve native undo")
    func unicodeReplacementAndUndo() async throws {
        let textView = makeTextView("🙂 café and café")
        let undo = UndoManager()
        undo.groupsByEvent = false
        let host = FindRepairUndoHost(manager: undo)
        textView.delegate = host
        textView.allowsUndo = true
        defer { withExtendedLifetime(host) {} }
        let state = DocumentFindState()
        let controller = NSTextViewFindController(textView: textView)
        state.attach(controller)
        state.query = "(café)"
        state.options = [.regularExpression]
        state.replacement = "$1🙂"
        state.findNext()
        await controller.waitForSearchCompletion()
        #expect(textView.selectedRange() == NSRange(location: 3, length: 4))
        state.replaceCurrent()
        await controller.waitForSearchCompletion()
        #expect(textView.string == "🙂 café🙂 and café")
        #expect(
            textView.selectedRange()
                == (textView.string as NSString).range(of: "café", options: .backwards))
        #expect(undo.canUndo)
        undo.undo()
        await controller.waitForSearchCompletion()
        #expect(textView.string == "🙂 café and café")

        state.replacement = "રફૂ"
        state.replaceAll()
        await controller.waitForSearchCompletion()
        #expect(textView.string == "🙂 રફૂ and રફૂ")
        undo.undo()
        await controller.waitForSearchCompletion()
        #expect(textView.string == "🙂 café and café")
        state.detach(controller)
    }

    @Test("Zero-length regex navigation advances and replace-all preserves Unicode undo")
    func zeroLengthMatches() async {
        let textView = makeTextView("a")
        let undo = UndoManager()
        undo.groupsByEvent = false
        let host = FindRepairUndoHost(manager: undo)
        textView.delegate = host
        textView.allowsUndo = true
        defer { withExtendedLifetime(host) {} }
        let state = DocumentFindState()
        let controller = NSTextViewFindController(textView: textView)
        state.attach(controller)
        state.options = [.regularExpression]
        state.query = "(?=a)|$"
        // This pattern also matches EOF. Anchor the fixture explicitly so
        // initial AppKit selection does not shift every navigation assertion.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
        state.findNext()
        await controller.waitForSearchCompletion()
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
        state.findNext()
        #expect(textView.selectedRange() == NSRange(location: 1, length: 0))
        state.findNext()
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
        state.findPrevious()
        #expect(textView.selectedRange() == NSRange(location: 1, length: 0))
        state.replacement = "🙂"
        state.replaceAll()
        await controller.waitForSearchCompletion()
        #expect(textView.string == "🙂a🙂")
        undo.undo()
        await controller.waitForSearchCompletion()
        #expect(textView.string == "a")
        state.select(NSRange(location: 0, length: 0))
        state.replaceCurrent()
        await controller.waitForSearchCompletion()
        #expect(textView.string == "🙂a")
        undo.undo()
        await controller.waitForSearchCompletion()
        #expect(textView.string == "a")
        state.detach(controller)
    }

    @Test("Active highlights survive a large native paste, delete, and undo")
    func activeHighlightsLargePasteDeleteUndo() async throws {
        let original = String(repeating: "cat🙂\n", count: 2_300)
        let pasted = String(repeating: "cat café🙂\n", count: 4_100)
        let textView = makeTextView(original)
        let storage = try #require(textView.textStorage)
        let textContainer = try #require(textView.textContainer)
        let layoutManager = FindRepairRecordingLayoutManager()
        textContainer.replaceLayoutManager(layoutManager)
        layoutManager.observeEdits(in: storage)
        let undo = UndoManager()
        undo.groupsByEvent = false
        let host = FindRepairUndoHost(manager: undo)
        textView.delegate = host
        textView.allowsUndo = true
        defer { withExtendedLifetime(host) {} }
        let counter = FindRepairSearchCounter()
        let state = DocumentFindState()
        let controller = NSTextViewFindController(textView: textView) { await counter.search($0) }
        controller.matchHighlightColor = .systemYellow
        state.attach(controller)
        state.query = "cat"
        state.activate()
        await controller.waitForSearchCompletion()
        #expect(state.matchCount == 2_300)
        #expect(highlight(in: textView, at: 0) == .systemYellow)

        undo.beginUndoGrouping()
        textView.insertText(
            pasted, replacementRange: NSRange(location: original.utf16.count, length: 0))
        undo.endUndoGrouping()
        // The TextKit notification invalidates revision immediately. UI work
        // stays queued until its edit transaction has returned to the main queue.
        #expect(state.matchCount == 2_300)
        await controller.waitForSearchCompletion()
        #expect(textView.string == original + pasted)
        #expect(state.matchCount == 6_400)
        #expect(highlight(in: textView, at: 0) == .systemYellow)

        undo.beginUndoGrouping()
        textView.insertText(
            "", replacementRange: NSRange(location: 0, length: (original + pasted).utf16.count))
        undo.endUndoGrouping()
        #expect(state.matchCount == 6_400)
        await controller.waitForSearchCompletion()
        #expect(textView.string.isEmpty)
        #expect(state.matchCount == 0)
        #expect(undo.canUndo)
        undo.undo()
        await controller.waitForSearchCompletion()
        #expect(textView.string == original + pasted)
        #expect(state.matchCount == 6_400)
        #expect(highlight(in: textView, at: 0) == .systemYellow)
        undo.undo()
        await controller.waitForSearchCompletion()
        #expect(textView.string == original)
        #expect(state.matchCount == 2_300)
        #expect(highlight(in: textView, at: 0) == .systemYellow)
        #expect(await counter.count == 5)
        #expect(layoutManager.characterEditNotifications >= 4)
        #expect(layoutManager.processedCharacterEdits == layoutManager.characterEditNotifications)
        #expect(layoutManager.temporaryAttributeMutations > 0)
        #expect(layoutManager.temporaryMutationsBeforeLayoutProcessing == 0)
        state.detach(controller)
    }

    @Test("Several storage edits in one turn schedule one new active search")
    func editRefreshIsCoalescedAfterStorageTransaction() async {
        let textView = makeTextView("cat cat")
        let counter = FindRepairSearchCounter()
        let state = DocumentFindState()
        let controller = NSTextViewFindController(textView: textView) { await counter.search($0) }
        controller.matchHighlightColor = .systemYellow
        state.attach(controller)
        state.query = "cat"
        state.activate()
        await controller.waitForSearchCompletion()
        #expect(state.matchCount == 2)
        textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 3), with: "dog")
        textView.textStorage?.replaceCharacters(in: NSRange(location: 4, length: 3), with: "dog")
        state.refresh()
        #expect(state.matchCount == 2)
        await controller.waitForSearchCompletion()
        #expect(textView.string == "dog dog")
        #expect(state.matchCount == 0)
        #expect(highlight(in: textView, at: 0) == nil)
        #expect(await counter.count == 2)
        state.detach(controller)
    }

    @Test("A moved selection prevents a delayed current replacement")
    func movedSelectionRejectsReplacement() async throws {
        let gate = FindRepairSearchGate()
        let textView = makeTextView("cat cat")
        textView.setSelectedRange(NSRange(location: 0, length: 3))
        let state = DocumentFindState()
        let controller = NSTextViewFindController(textView: textView) { await gate.search($0) }
        state.attach(controller)
        state.query = "cat"
        state.replacement = "dog"
        state.replaceCurrent()
        let request = try #require(await gate.waitForRequests(1).first)
        textView.setSelectedRange(NSRange(location: 4, length: 3))
        await gate.finish(request.id, result: await DocumentFindSearch.execute(request))
        await controller.waitForSearchCompletion()
        #expect(textView.string == "cat cat")
        #expect(textView.selectedRange() == NSRange(location: 4, length: 3))
        state.detach(controller)
    }

    private func makeTextView(_ text: String) -> NSTextView {
        let textView = RafuTextView.makeTextKit1()
        textView.string = text
        return textView
    }

    private func highlight(in textView: NSTextView, at index: Int) -> NSColor? {
        textView.layoutManager?.temporaryAttribute(
            .backgroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
    }
}

private actor FindRepairSearchCounter {
    private(set) var count = 0

    func search(_ request: DocumentFindSearchRequest) async -> DocumentFindSearchResult {
        count += 1
        return await DocumentFindSearch.execute(request)
    }
}

private actor FindRepairSearchGate {
    private var requests: [DocumentFindSearchRequest] = []
    private var completions: [Int: CheckedContinuation<DocumentFindSearchResult, Never>] = [:]
    private var observers: [(Int, CheckedContinuation<[DocumentFindSearchRequest], Never>)] = []
    var requestCount: Int { requests.count }

    func search(_ request: DocumentFindSearchRequest) async -> DocumentFindSearchResult {
        requests.append(request)
        let ready = observers.filter { requests.count >= $0.0 }
        observers.removeAll { requests.count >= $0.0 }
        for (_, continuation) in ready { continuation.resume(returning: requests) }
        return await withCheckedContinuation { completions[request.id] = $0 }
    }

    func waitForRequests(_ count: Int) async -> [DocumentFindSearchRequest] {
        if requests.count >= count { return requests }
        return await withCheckedContinuation { observers.append((count, $0)) }
    }

    func finish(_ id: Int, result: DocumentFindSearchResult) {
        completions.removeValue(forKey: id)?.resume(returning: result)
    }
}

@MainActor
private final class FindRepairUndoHost: NSObject, NSTextViewDelegate {
    let manager: UndoManager
    init(manager: UndoManager) { self.manager = manager }

    nonisolated func undoManager(for view: NSTextView) -> UndoManager? {
        MainActor.assumeIsolated { manager }
    }
}

nonisolated private struct FindRepairLayoutRecording: Sendable {
    var characterEditNotifications = 0
    var processedCharacterEdits = 0
    var temporaryAttributeMutations = 0
    var temporaryMutationsBeforeLayoutProcessing = 0
    var processingLayoutEditDepth = 0
}

@MainActor
private final class FindRepairRecordingLayoutManager: NSLayoutManager {
    // NSLayoutManager overrides are nonisolated in this SDK. Keep the
    // recorder values under a lock; do not send its non-Sendable self to
    // MainActor.assumeIsolated from an override.
    nonisolated private let recording = Mutex(FindRepairLayoutRecording())

    var characterEditNotifications: Int { recording.withLock { $0.characterEditNotifications } }
    var processedCharacterEdits: Int { recording.withLock { $0.processedCharacterEdits } }
    var temporaryAttributeMutations: Int { recording.withLock { $0.temporaryAttributeMutations } }
    var temporaryMutationsBeforeLayoutProcessing: Int {
        recording.withLock { $0.temporaryMutationsBeforeLayoutProcessing }
    }

    func observeEdits(in storage: NSTextStorage) {
        NotificationCenter.default.addObserver(
            self, selector: #selector(findRepairStorageDidProcessEditing(_:)),
            name: NSTextStorage.didProcessEditingNotification, object: storage)
    }

    isolated deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func findRepairStorageDidProcessEditing(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
            storage.editedMask.contains(.editedCharacters)
        else { return }
        recording.withLock { $0.characterEditNotifications += 1 }
    }

    nonisolated override func processEditing(
        for textStorage: NSTextStorage, edited editMask: NSTextStorageEditActions,
        range newCharRange: NSRange, changeInLength delta: Int,
        invalidatedRange invalidatedCharRange: NSRange
    ) {
        recording.withLock { $0.processingLayoutEditDepth += 1 }
        super.processEditing(
            for: textStorage, edited: editMask, range: newCharRange,
            changeInLength: delta, invalidatedRange: invalidatedCharRange)
        recording.withLock {
            $0.processingLayoutEditDepth -= 1
            if editMask.contains(.editedCharacters) {
                $0.processedCharacterEdits = $0.characterEditNotifications
            }
        }
    }

    nonisolated override func addTemporaryAttribute(
        _ attrName: NSAttributedString.Key, value: Any, forCharacterRange charRange: NSRange
    ) {
        recordTemporaryMutation(attrName)
        super.addTemporaryAttribute(attrName, value: value, forCharacterRange: charRange)
    }

    nonisolated override func removeTemporaryAttribute(
        _ attrName: NSAttributedString.Key, forCharacterRange charRange: NSRange
    ) {
        recordTemporaryMutation(attrName)
        super.removeTemporaryAttribute(attrName, forCharacterRange: charRange)
    }

    nonisolated private func recordTemporaryMutation(_ attribute: NSAttributedString.Key) {
        // Ignore layout-manager internals while its superclass processes an
        // edit. Record client background-color calls between the notification
        // and completion of layout-manager processing. Release the lock before
        // calling AppKit, which can reenter these overrides.
        guard attribute == .backgroundColor else { return }
        recording.withLock {
            guard $0.processingLayoutEditDepth == 0 else { return }
            $0.temporaryAttributeMutations += 1
            if $0.processedCharacterEdits < $0.characterEditNotifications {
                $0.temporaryMutationsBeforeLayoutProcessing += 1
            }
        }
    }
}
