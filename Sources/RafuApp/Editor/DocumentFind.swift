import AppKit
import Foundation
import Observation

nonisolated struct TextSearchOptions: OptionSet, Codable, Equatable, Sendable {
    let rawValue: Int

    static let regularExpression = Self(rawValue: 1 << 0)
    static let caseSensitive = Self(rawValue: 1 << 1)
    static let wholeWord = Self(rawValue: 1 << 2)
}

nonisolated struct TextSearchMatch: Codable, Equatable, Sendable {
    let range: NSRange
    let replacement: String
}

nonisolated struct TextSearchPattern: Equatable, Sendable {
    let query: String
    let replacementTemplate: String
    let options: TextSearchOptions

    init(query: String, replacementTemplate: String = "", options: TextSearchOptions = []) {
        self.query = query
        self.replacementTemplate = replacementTemplate
        self.options = options
    }

    func matches(
        in text: String,
        limit: Int? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> [TextSearchMatch] {
        if isCancelled() { throw CancellationError() }
        guard !query.isEmpty else { return [] }
        let expression = try regularExpression()
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var matches: [TextSearchMatch] = []
        expression.enumerateMatches(in: text, options: [.reportProgress], range: fullRange) {
            result, _, stop in
            guard !isCancelled() else {
                stop.pointee = true
                return
            }
            guard let result else { return }
            let replacement =
                replacementTemplate.isEmpty
                ? ""
                : expression.replacementString(
                    for: result,
                    in: text,
                    offset: 0,
                    template: replacementTemplate
                )
            matches.append(TextSearchMatch(range: result.range, replacement: replacement))
            if let limit, matches.count >= limit { stop.pointee = true }
        }
        if isCancelled() { throw CancellationError() }
        return matches
    }

    func replacingMatches(in text: String, limit: Int? = nil) throws -> String {
        let matches = try matches(in: text, limit: limit)
        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            mutable.replaceCharacters(in: match.range, with: match.replacement)
        }
        return mutable as String
    }

    private func regularExpression() throws -> NSRegularExpression {
        var pattern =
            options.contains(.regularExpression)
            ? query : NSRegularExpression.escapedPattern(for: query)
        if options.contains(.wholeWord) {
            pattern = #"(?<![\p{L}\p{N}_])(?:"# + pattern + #")(?![\p{L}\p{N}_])"#
        }
        let expressionOptions: NSRegularExpression.Options =
            options.contains(.caseSensitive)
            ? [] : [.caseInsensitive]
        do {
            return try NSRegularExpression(pattern: pattern, options: expressionOptions)
        } catch {
            throw TextSearchError.invalidRegularExpression(error.localizedDescription)
        }
    }
}

nonisolated enum TextSearchError: LocalizedError, Equatable {
    case invalidRegularExpression(String)

    var errorDescription: String? {
        switch self {
        case .invalidRegularExpression(let message): "Invalid regular expression: \(message)"
        }
    }
}

nonisolated enum FindDirection: Equatable, Sendable {
    case next
    case previous
}

@MainActor
protocol DocumentFindControlling: AnyObject {
    func refresh(using state: DocumentFindState)
    func find(_ direction: FindDirection, using state: DocumentFindState)
    func replaceCurrent(using state: DocumentFindState)
    func replaceAll(using state: DocumentFindState)
    func select(_ range: NSRange)
    func focusEditor()
    func detach()
}

extension DocumentFindControlling {
    func focusEditor() {}
    func detach() {}
}

@Observable
@MainActor
final class DocumentFindState {
    var query = "" {
        didSet {
            if query != oldValue { controller?.refresh(using: self) }
        }
    }
    var replacement = ""
    var options: TextSearchOptions = [] {
        didSet {
            if options != oldValue { controller?.refresh(using: self) }
        }
    }
    private(set) var matchCount = 0
    private(set) var currentMatchIndex: Int?
    private(set) var errorMessage: String?
    /// True while the find bar is presented for this document. In-buffer
    /// match work and highlighting are gated on this flag. Explicit commands
    /// can still request a search while the bar is closed.
    private(set) var isActive = false
    /// A presentation edge, not a Boolean state. Every Find command advances
    /// the value so a bar that is already visible can focus its query again.
    private(set) var queryFocusRequest = 0

    @ObservationIgnored
    private weak var controller: (any DocumentFindControlling)?

    @ObservationIgnored
    private var pendingSelection: NSRange?

    func findNext() {
        controller?.find(.next, using: self)
    }

    func findPrevious() {
        controller?.find(.previous, using: self)
    }

    func replaceCurrent() {
        controller?.replaceCurrent(using: self)
    }

    func replaceAll() {
        controller?.replaceAll(using: self)
    }

    func refresh() {
        controller?.refresh(using: self)
    }

    func requestQueryFocus() {
        queryFocusRequest += 1
    }

    func focusEditor() {
        controller?.focusEditor()
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        controller?.refresh(using: self)
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        controller?.refresh(using: self)
    }

    func select(_ range: NSRange) {
        pendingSelection = range
        if let controller {
            controller.select(range)
            pendingSelection = nil
        }
    }

    func attach(_ controller: any DocumentFindControlling) {
        if let previous = self.controller, previous !== controller { previous.detach() }
        self.controller = controller
        controller.refresh(using: self)
        if let pendingSelection {
            controller.select(pendingSelection)
            self.pendingSelection = nil
        }
    }

    func detach(_ controller: any DocumentFindControlling) {
        guard self.controller === controller else { return }
        controller.detach()
        self.controller = nil
        isActive = false
        update(matchCount: 0, currentMatchIndex: nil, errorMessage: nil)
    }

    fileprivate func update(
        matchCount: Int,
        currentMatchIndex: Int?,
        errorMessage: String?
    ) {
        if self.matchCount != matchCount { self.matchCount = matchCount }
        if self.currentMatchIndex != currentMatchIndex {
            self.currentMatchIndex = currentMatchIndex
        }
        if self.errorMessage != errorMessage { self.errorMessage = errorMessage }
    }
}

@MainActor
final class NSTextViewFindController: NSObject, DocumentFindControlling {
    private weak var textView: NSTextView?
    private weak var state: DocumentFindState?
    private let search: @Sendable (DocumentFindSearchRequest) async -> DocumentFindSearchResult
    private var revision = 0
    private var requestID = 0
    private var currentRequestID = 0
    private var running: Job?
    private var pending: Job?
    private var searchTask: Task<Void, Never>?
    private var cached: (key: DocumentFindSearchKey, result: DocumentFindSearchResult)?
    private var hasHighlights = false
    private var lastZeroLengthSelection: NSRange?
    private var navigationPattern: TextSearchPattern?
    private var editRefreshIsPending = false
    private var deferredIntent: DeferredIntent?
    private var editRefreshWaiters: [CheckedContinuation<Void, Never>] = []

    /// Temporary layout attributes do not change the live text or undo stack.
    var matchHighlightColor: NSColor?
    var activeMatchHighlightColor: NSColor?
    private static let highlightLimit = 2_000

    private enum Intent {
        case refresh
        case navigate(FindDirection, additionalSteps: Int, selection: NSRange)
        case replaceCurrent(selection: NSRange, count: Int, findNextFirst: Bool)
        case replaceAll

        var needsReplacement: Bool {
            switch self {
            case .replaceCurrent, .replaceAll: true
            case .refresh, .navigate: false
            }
        }

        func merging(_ newer: Intent) -> Intent {
            if case .refresh = newer { return self }
            if case .navigate(let direction, let steps, let selection) = self,
                case .navigate(let nextDirection, _, let nextSelection) = newer,
                selection == nextSelection
            {
                let delta = nextDirection == .next ? 1 : -1
                let (sum, overflow) = steps.addingReportingOverflow(delta)
                return .navigate(
                    direction, additionalSteps: overflow ? steps : sum, selection: selection)
            }
            if case .replaceCurrent(let selection, let count, let findNextFirst) = self,
                case .replaceCurrent(let nextSelection, let nextCount, _) = newer,
                selection == nextSelection
            {
                let (sum, overflow) = count.addingReportingOverflow(nextCount)
                return .replaceCurrent(
                    selection: selection, count: overflow ? count : sum,
                    findNextFirst: findNextFirst)
            }
            return newer
        }
    }

    private struct DeferredIntent {
        let key: DocumentFindSearchKey
        weak var state: DocumentFindState?
        var intent: Intent
    }

    private struct Job {
        let request: DocumentFindSearchRequest
        weak var state: DocumentFindState?
        var intent: Intent
    }

    init(
        textView: NSTextView,
        search: @escaping @Sendable (DocumentFindSearchRequest) async -> DocumentFindSearchResult =
            DocumentFindSearch.execute
    ) {
        self.textView = textView
        self.search = search
        super.init()
        // This storage belongs to the main-actor editor. Observe character
        // edits, including programmatic load and undo; ignore syntax attributes.
        NotificationCenter.default.addObserver(
            self, selector: #selector(textStorageDidEdit(_:)),
            name: NSTextStorage.didProcessEditingNotification, object: textView.textStorage)
    }

    isolated deinit {
        searchTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func refresh(using state: DocumentFindState) {
        synchronizeNavigationPattern(using: state)
        self.state = state
        guard state.isActive else {
            cancelRequests()
            clearHighlights()
            if cached?.key != key(for: state, intent: .refresh) {
                state.update(matchCount: 0, currentMatchIndex: nil, errorMessage: nil)
            }
            return
        }
        request(.refresh, using: state)
    }

    func find(_ direction: FindDirection, using state: DocumentFindState) {
        guard let textView else { return }
        request(
            .navigate(direction, additionalSteps: 0, selection: textView.selectedRange()),
            using: state)
    }

    func replaceCurrent(using state: DocumentFindState) {
        guard let textView, textView.isEditable else { return }
        request(
            .replaceCurrent(selection: textView.selectedRange(), count: 1, findNextFirst: false),
            using: state)
    }

    func replaceAll(using state: DocumentFindState) {
        guard textView?.isEditable == true else { return }
        request(.replaceAll, using: state)
    }

    func detach() {
        cancelRequests()
        state = nil
        cached = nil
        clearHighlights()
    }

    /// Await actual work, including the latest pending request. This is also
    /// useful to tests: no timer, run-loop pump, or fixed sleep is required.
    func waitForSearchCompletion() async {
        while true {
            if editRefreshIsPending {
                await withCheckedContinuation { editRefreshWaiters.append($0) }
                continue
            }
            guard let searchTask else { return }
            await searchTask.value
        }
    }

    @objc private func textStorageDidEdit(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
            storage.editedMask.contains(.editedCharacters)
        else { return }
        revision += 1
        cached = nil
        lastZeroLengthSelection = nil
        cancelRequests()
        // TextKit can still be updating its layout ranges here. Do not change
        // temporary attributes, capture text, or refresh until processing ends.
        guard !editRefreshIsPending else { return }
        editRefreshIsPending = true
        DispatchQueue.main.async { [weak self] in self?.finishTextEdits() }
    }

    private func finishTextEdits() {
        editRefreshIsPending = false
        let deferred = deferredIntent
        deferredIntent = nil
        defer {
            let waiters = editRefreshWaiters
            editRefreshWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        clearHighlights()
        guard let state else { return }
        state.update(matchCount: 0, currentMatchIndex: nil, errorMessage: nil)
        if let deferred, deferred.state === state,
            deferred.key == key(for: state, intent: deferred.intent)
        {
            request(deferred.intent, using: state)
        } else if state.isActive {
            request(.refresh, using: state)
        }
    }

    private func key(for state: DocumentFindState, intent: Intent) -> DocumentFindSearchKey {
        DocumentFindSearchKey(
            revision: revision,
            pattern: TextSearchPattern(
                query: state.query,
                replacementTemplate: intent.needsReplacement ? state.replacement : "",
                options: state.options))
    }

    private func synchronizeNavigationPattern(using state: DocumentFindState) {
        let pattern = TextSearchPattern(query: state.query, options: state.options)
        guard pattern != navigationPattern else { return }
        navigationPattern = pattern
        lastZeroLengthSelection = nil
    }

    private func request(_ intent: Intent, using state: DocumentFindState) {
        guard let textView else { return }
        synchronizeNavigationPattern(using: state)
        self.state = state
        let key = key(for: state, intent: intent)
        if editRefreshIsPending {
            if var deferred = deferredIntent, deferred.key == key, deferred.state === state {
                deferred.intent = deferred.intent.merging(intent)
                deferredIntent = deferred
            } else {
                deferredIntent = DeferredIntent(key: key, state: state, intent: intent)
            }
            return
        }
        guard !key.pattern.query.isEmpty else {
            cancelRequests()
            state.update(matchCount: 0, currentMatchIndex: nil, errorMessage: nil)
            clearHighlights()
            return
        }
        if let cached, cached.key == key {
            cancelRequests()
            apply(cached.result, intent: intent, using: state)
            return
        }
        if var job = running, job.request.key == key, searchTask?.isCancelled == false,
            job.state === state
        {
            job.intent = job.intent.merging(intent)
            running = job
            return
        }
        if var job = pending, job.request.key == key, job.state === state {
            job.intent = job.intent.merging(intent)
            pending = job
            return
        }
        requestID += 1
        currentRequestID = requestID
        // Replacing pending releases its snapshot immediately. Do not spawn
        // another worker until the current Foundation call actually returns.
        pending = Job(
            request: DocumentFindSearchRequest(id: requestID, key: key, text: textView.string),
            state: state, intent: intent)
        searchTask?.cancel()
        state.update(matchCount: 0, currentMatchIndex: nil, errorMessage: nil)
        clearHighlights()
        startPendingRequest()
    }

    private func startPendingRequest() {
        guard searchTask == nil, let job = pending else { return }
        pending = nil
        running = job
        let request = job.request
        let search = search
        searchTask = Task { [weak self] in
            let result = await search(request)
            self?.complete(request, result: result)
        }
    }

    private func complete(_ request: DocumentFindSearchRequest, result: DocumentFindSearchResult) {
        guard let job = running, job.request.id == request.id else { return }
        running = nil
        searchTask = nil
        if request.id == currentRequestID, let state = job.state, self.state === state,
            request.key == key(for: state, intent: job.intent)
        {
            if case .cancelled = result {
                // A cancelled search never becomes a valid empty result.
            } else {
                cached = (request.key, result)
                apply(result, intent: job.intent, using: state)
            }
        }
        startPendingRequest()
    }

    private func cancelRequests() {
        requestID += 1
        currentRequestID = requestID
        pending = nil
        deferredIntent = nil
        searchTask?.cancel()
    }

    private func apply(
        _ result: DocumentFindSearchResult, intent: Intent, using state: DocumentFindState
    ) {
        switch result {
        case .cancelled: return
        case .failure(let message):
            state.update(matchCount: 0, currentMatchIndex: nil, errorMessage: message)
            clearHighlights()
        case .matches(let matches):
            let currentIndex = selectedMatchIndex(in: matches)
            state.update(
                matchCount: matches.count, currentMatchIndex: currentIndex, errorMessage: nil)
            applyHighlights(matches, currentIndex: currentIndex, isActive: state.isActive)
            guard !matches.isEmpty, let textView else { return }
            switch intent {
            case .refresh: break
            case .navigate(let direction, let steps, let selection):
                guard textView.selectedRange() == selection else { return }
                navigate(
                    direction, additionalSteps: steps, selection: selection, matches: matches,
                    using: state)
            case .replaceCurrent(let selection, let count, let findNextFirst):
                guard textView.isEditable, textView.selectedRange() == selection else { return }
                if findNextFirst || currentIndex == nil {
                    navigate(
                        .next, additionalSteps: 0, selection: selection, matches: matches,
                        using: state)
                }
                // The first Replace only selects a match when none was selected.
                // Later queued commands must still run against that selection.
                let replacementsLeft = !findNextFirst && currentIndex == nil ? count - 1 : count
                guard replacementsLeft > 0, let index = selectedMatchIndex(in: matches) else {
                    return
                }
                replace(
                    matches: [matches[index]], all: false,
                    remainingReplacements: replacementsLeft - 1, using: state)
            case .replaceAll:
                guard textView.isEditable else { return }
                replace(matches: matches, all: true, using: state)
            }
        }
    }

    private func navigate(
        _ direction: FindDirection, additionalSteps: Int, selection: NSRange,
        matches: [TextSearchMatch], using state: DocumentFindState
    ) {
        guard let textView else { return }
        let skipZeroLength = selection.length == 0 && lastZeroLengthSelection == selection
        let firstIndex: Int
        switch direction {
        case .next:
            let candidate = matchBoundary(in: matches) {
                skipZeroLength
                    ? $0.range.location > selection.location
                    : $0.range.location >= NSMaxRange(selection)
            }
            firstIndex = candidate < matches.count ? candidate : 0
        case .previous:
            let candidate = matchBoundary(in: matches) {
                skipZeroLength
                    ? NSMaxRange($0.range) >= selection.location
                    : NSMaxRange($0.range) > selection.location
            }
            firstIndex = candidate > 0 ? candidate - 1 : matches.count - 1
        }
        let offset = additionalSteps % matches.count
        let index = (firstIndex + offset + matches.count) % matches.count
        select(matches[index].range, in: textView)
        lastZeroLengthSelection = matches[index].range.length == 0 ? matches[index].range : nil
        state.update(matchCount: matches.count, currentMatchIndex: index, errorMessage: nil)
        applyHighlights(matches, currentIndex: index, isActive: state.isActive)
    }

    private func replace(
        matches: [TextSearchMatch], all: Bool, remainingReplacements: Int = 0,
        using state: DocumentFindState
    ) {
        guard let textView, let storage = textView.textStorage else { return }
        let ranges = matches.map { NSValue(range: $0.range) }
        let replacements = matches.map(\.replacement)
        let undoManager = textView.undoManager
        let groupsByEvent = undoManager?.groupsByEvent
        undoManager?.groupsByEvent = false
        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.setActionName(all ? "Replace All" : "Replace")
            undoManager?.endUndoGrouping()
            if let groupsByEvent { undoManager?.groupsByEvent = groupsByEvent }
        }
        guard textView.shouldChangeText(inRanges: ranges, replacementStrings: replacements) else {
            return
        }
        storage.beginEditing()
        for match in matches.reversed() {
            storage.replaceCharacters(in: match.range, with: match.replacement)
        }
        storage.endEditing()
        if !all, let match = matches.first {
            textView.setSelectedRange(
                NSRange(location: match.range.location + match.replacement.utf16.count, length: 0))
        }
        textView.didChangeText()
        if all {
            refresh(using: state)
        } else if remainingReplacements > 0 {
            request(
                .replaceCurrent(
                    selection: textView.selectedRange(), count: remainingReplacements,
                    findNextFirst: true), using: state)
        } else {
            find(.next, using: state)
        }
    }

    func select(_ range: NSRange) {
        guard let textView, range.location >= 0, range.length >= 0,
            range.location <= (textView.textStorage?.length ?? 0),
            range.length <= (textView.textStorage?.length ?? 0) - range.location
        else { return }
        select(range, in: textView)
    }

    func focusEditor() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    func clearHighlights() {
        guard !editRefreshIsPending, hasHighlights else { return }
        hasHighlights = false
        guard let textView, let layoutManager = textView.layoutManager else { return }
        layoutManager.removeTemporaryAttribute(
            .backgroundColor,
            forCharacterRange: NSRange(location: 0, length: textView.textStorage?.length ?? 0))
    }

    private func applyHighlights(
        _ matches: [TextSearchMatch], currentIndex: Int?, isActive: Bool
    ) {
        clearHighlights()
        guard isActive, let textView, let layoutManager = textView.layoutManager,
            let matchHighlightColor, !matches.isEmpty
        else { return }
        let length = textView.textStorage?.length ?? 0
        for (index, match) in matches.prefix(Self.highlightLimit).enumerated() {
            guard match.range.length > 0, NSMaxRange(match.range) <= length else { continue }
            let color =
                index == currentIndex
                ? (activeMatchHighlightColor ?? matchHighlightColor) : matchHighlightColor
            layoutManager.addTemporaryAttribute(
                .backgroundColor, value: color, forCharacterRange: match.range)
            hasHighlights = true
        }
    }

    private func selectedMatchIndex(in matches: [TextSearchMatch]) -> Int? {
        guard let selection = textView?.selectedRange() else { return nil }
        let index = matchBoundary(in: matches) { $0.range.location >= selection.location }
        return index < matches.count && matches[index].range == selection ? index : nil
    }

    /// Match ranges are ordered and non-overlapping. Do not scan a large
    /// result array on the main actor for each navigation command.
    private func matchBoundary(
        in matches: [TextSearchMatch], where predicate: (TextSearchMatch) -> Bool
    ) -> Int {
        var lower = 0
        var upper = matches.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if predicate(matches[middle]) { upper = middle } else { lower = middle + 1 }
        }
        return lower
    }

    private func select(_ range: NSRange, in textView: NSTextView) {
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
    }
}
