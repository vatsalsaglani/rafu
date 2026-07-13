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

    func matches(in text: String, limit: Int? = nil) throws -> [TextSearchMatch] {
        guard !query.isEmpty else { return [] }
        let expression = try regularExpression()
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var matches: [TextSearchMatch] = []
        expression.enumerateMatches(in: text, range: fullRange) { result, _, stop in
            guard let result else { return }
            let replacement = expression.replacementString(
                for: result,
                in: text,
                offset: 0,
                template: replacementTemplate
            )
            matches.append(TextSearchMatch(range: result.range, replacement: replacement))
            if let limit, matches.count >= limit { stop.pointee = true }
        }
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

nonisolated enum FindDirection: Sendable {
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
}

@Observable
@MainActor
final class DocumentFindState {
    var query = "" {
        didSet { controller?.refresh(using: self) }
    }
    var replacement = ""
    var options: TextSearchOptions = [] {
        didSet { controller?.refresh(using: self) }
    }
    private(set) var matchCount = 0
    private(set) var currentMatchIndex: Int?
    private(set) var errorMessage: String?
    /// True while the find bar is presented for this document. In-buffer
    /// match highlighting is strictly gated on this flag because `refresh()`
    /// also runs on every text change while the bar is closed.
    private(set) var isActive = false

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
        self.controller = controller
        controller.refresh(using: self)
        if let pendingSelection {
            controller.select(pendingSelection)
            self.pendingSelection = nil
        }
    }

    func detach(_ controller: any DocumentFindControlling) {
        guard self.controller === controller else { return }
        self.controller = nil
        isActive = false
        update(matchCount: 0, currentMatchIndex: nil, errorMessage: nil)
    }

    fileprivate func update(
        matchCount: Int,
        currentMatchIndex: Int?,
        errorMessage: String?
    ) {
        self.matchCount = matchCount
        self.currentMatchIndex = currentMatchIndex
        self.errorMessage = errorMessage
    }
}

@MainActor
final class NSTextViewFindController: DocumentFindControlling {
    private weak var textView: NSTextView?

    /// Match highlighting renders via `NSLayoutManager` temporary attributes
    /// so the Neon pipeline's storage-attribute passes never clobber it.
    var matchHighlightColor: NSColor?
    var activeMatchHighlightColor: NSColor?

    /// Upper bound on highlighted matches so a one-character query in a huge
    /// buffer cannot stall the main thread.
    private static let highlightLimit = 2_000

    init(textView: NSTextView) {
        self.textView = textView
    }

    func refresh(using state: DocumentFindState) {
        do {
            let matches = try pattern(for: state).matches(in: textView?.string ?? "")
            let currentIndex = selectedMatchIndex(in: matches)
            state.update(
                matchCount: matches.count,
                currentMatchIndex: currentIndex,
                errorMessage: nil
            )
            applyHighlights(matches, currentIndex: currentIndex, isActive: state.isActive)
        } catch {
            state.update(
                matchCount: 0, currentMatchIndex: nil, errorMessage: error.localizedDescription)
            clearHighlights()
        }
    }

    func find(_ direction: FindDirection, using state: DocumentFindState) {
        guard let textView else { return }
        do {
            let matches = try pattern(for: state).matches(in: textView.string)
            guard !matches.isEmpty else {
                state.update(matchCount: 0, currentMatchIndex: nil, errorMessage: nil)
                clearHighlights()
                return
            }

            let selection = textView.selectedRange()
            let index: Int
            switch direction {
            case .next:
                index = matches.firstIndex { $0.range.location >= NSMaxRange(selection) } ?? 0
            case .previous:
                index =
                    matches.lastIndex { NSMaxRange($0.range) <= selection.location }
                    ?? (matches.count - 1)
            }
            select(matches[index].range, in: textView)
            state.update(matchCount: matches.count, currentMatchIndex: index, errorMessage: nil)
            applyHighlights(matches, currentIndex: index, isActive: state.isActive)
        } catch {
            state.update(
                matchCount: 0, currentMatchIndex: nil, errorMessage: error.localizedDescription)
            clearHighlights()
        }
    }

    func replaceCurrent(using state: DocumentFindState) {
        guard let textView, textView.isEditable else { return }
        do {
            let matches = try pattern(for: state).matches(in: textView.string)
            guard !matches.isEmpty else {
                state.update(matchCount: 0, currentMatchIndex: nil, errorMessage: nil)
                return
            }
            guard let index = selectedMatchIndex(in: matches) else {
                find(.next, using: state)
                return
            }
            let match = matches[index]
            let undoManager = textView.undoManager
            let groupsByEvent = undoManager?.groupsByEvent
            undoManager?.groupsByEvent = false
            undoManager?.beginUndoGrouping()
            defer {
                undoManager?.setActionName("Replace")
                undoManager?.endUndoGrouping()
                if let groupsByEvent { undoManager?.groupsByEvent = groupsByEvent }
            }
            guard textView.shouldChangeText(in: match.range, replacementString: match.replacement)
            else { return }
            textView.textStorage?.replaceCharacters(in: match.range, with: match.replacement)
            textView.didChangeText()
            refresh(using: state)
            find(.next, using: state)
        } catch {
            state.update(
                matchCount: 0, currentMatchIndex: nil, errorMessage: error.localizedDescription)
        }
    }

    func replaceAll(using state: DocumentFindState) {
        guard let textView, textView.isEditable else { return }
        do {
            let matches = try pattern(for: state).matches(in: textView.string)
            guard !matches.isEmpty else {
                state.update(matchCount: 0, currentMatchIndex: nil, errorMessage: nil)
                return
            }

            let ranges = matches.map { NSValue(range: $0.range) }
            let replacements = matches.map(\.replacement)
            let undoManager = textView.undoManager
            let groupsByEvent = undoManager?.groupsByEvent
            undoManager?.groupsByEvent = false
            undoManager?.beginUndoGrouping()
            defer {
                undoManager?.setActionName("Replace All")
                undoManager?.endUndoGrouping()
                if let groupsByEvent { undoManager?.groupsByEvent = groupsByEvent }
            }
            guard textView.shouldChangeText(inRanges: ranges, replacementStrings: replacements)
            else { return }
            for match in matches.reversed() {
                textView.textStorage?.replaceCharacters(in: match.range, with: match.replacement)
            }
            textView.didChangeText()
            refresh(using: state)
        } catch {
            state.update(
                matchCount: 0, currentMatchIndex: nil, errorMessage: error.localizedDescription)
        }
    }

    func select(_ range: NSRange) {
        guard let textView, NSMaxRange(range) <= textView.string.utf16.count else { return }
        select(range, in: textView)
    }

    func clearHighlights() {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        layoutManager.removeTemporaryAttribute(
            .backgroundColor,
            forCharacterRange: NSRange(location: 0, length: (textView.string as NSString).length)
        )
    }

    private func applyHighlights(
        _ matches: [TextSearchMatch],
        currentIndex: Int?,
        isActive: Bool
    ) {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        layoutManager.removeTemporaryAttribute(
            .backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
        guard isActive, let matchHighlightColor, !matches.isEmpty else { return }
        for (index, match) in matches.prefix(Self.highlightLimit).enumerated() {
            guard match.range.length > 0, NSMaxRange(match.range) <= length else { continue }
            let color =
                index == currentIndex
                ? (activeMatchHighlightColor ?? matchHighlightColor) : matchHighlightColor
            layoutManager.addTemporaryAttribute(
                .backgroundColor, value: color, forCharacterRange: match.range)
        }
    }

    private func pattern(for state: DocumentFindState) -> TextSearchPattern {
        TextSearchPattern(
            query: state.query,
            replacementTemplate: state.replacement,
            options: state.options
        )
    }

    private func selectedMatchIndex(in matches: [TextSearchMatch]) -> Int? {
        guard let selection = textView?.selectedRange() else { return nil }
        return matches.firstIndex { $0.range == selection }
    }

    private func select(_ range: NSRange, in textView: NSTextView) {
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
    }
}
