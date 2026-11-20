import CoreGraphics
import Foundation
import RafuCore

// The pure parts of the approval peek: the small card that shows below the
// notch, Rafu's island pill or the menu bar item when an agent asks for
// approval (`ApprovalPeekController`). Everything here is a value with no
// window, no clock and no store, so the tests drive it directly. Request
// text stays in memory and is never logged.

/// One request the peek can show: the oldest request of one agent terminal.
nonisolated struct ApprovalPeekEntry: Equatable, Sendable {
    let controllerID: UUID
    let title: String
    let cli: ConductorCLIID
    let request: CanvasAgentRequest

    var key: UUID { request.key }
}

/// The peek's card stack. The controller gives it the current entries on
/// each refresh; it keeps which ones the person closed or answered, and
/// which one they selected with the previous and next buttons.
nonisolated struct ApprovalPeekDeck: Equatable, Sendable {
    /// At most this many blank cards show behind the top card.
    static let maxStackDepth = 2

    /// Every entry, oldest first.
    private(set) var entries: [ApprovalPeekEntry] = []
    /// Requests the person closed with the close button. They stay in Up
    /// next; only the peek does not show them again.
    private(set) var hiddenKeys: Set<UUID> = []
    /// Requests with a chosen answer that the supervisor did not close yet.
    private(set) var answeredKeys: Set<UUID> = []
    /// The request the person moved to with previous or next.
    private(set) var selectedKey: UUID?

    /// Replaces the entries (sorted by arrival time, then by key) and
    /// forgets hidden, answered and selected keys that are no longer
    /// pending. `chosenKeys` are requests answered on any surface.
    mutating func update(_ newEntries: [ApprovalPeekEntry], chosenKeys: Set<UUID> = []) {
        entries = newEntries.sorted { lhs, rhs in
            if lhs.request.receivedAt != rhs.request.receivedAt {
                return lhs.request.receivedAt < rhs.request.receivedAt
            }
            return lhs.key.uuidString < rhs.key.uuidString
        }
        let pending = Set(entries.map(\.key))
        hiddenKeys.formIntersection(pending)
        answeredKeys.formUnion(chosenKeys)
        answeredKeys.formIntersection(pending)
        if let selectedKey, !pending.contains(selectedKey) { self.selectedKey = nil }
    }

    /// The entries the peek can show: not hidden and not answered.
    var visible: [ApprovalPeekEntry] {
        entries.filter { !hiddenKeys.contains($0.key) && !answeredKeys.contains($0.key) }
    }

    /// The top card: the selected entry while it is visible, else the oldest.
    var shown: ApprovalPeekEntry? {
        let visible = self.visible
        if let selectedKey, let entry = visible.first(where: { $0.key == selectedKey }) {
            return entry
        }
        return visible.first
    }

    /// The shown card's place in the stack, 1-based.
    var position: (index: Int, count: Int)? {
        let visible = self.visible
        guard let shown, let index = visible.firstIndex(where: { $0.key == shown.key }) else {
            return nil
        }
        return (index + 1, visible.count)
    }

    /// "1 of 3", or `nil` when only one card shows.
    var positionText: String? {
        guard let position, position.count > 1 else { return nil }
        return "\(position.index) of \(position.count)"
    }

    var hasPrevious: Bool { (position?.index ?? 1) > 1 }
    var hasNext: Bool { position.map { $0.index < $0.count } ?? false }

    /// Shows the next card. Stays on the last card.
    mutating func next() { step(by: 1) }

    /// Shows the previous card. Stays on the first card.
    mutating func previous() { step(by: -1) }

    private mutating func step(by offset: Int) {
        let visible = self.visible
        guard let position else { return }
        let index = min(max(position.index - 1 + offset, 0), visible.count - 1)
        selectedKey = visible[index].key
    }

    /// The close button hides the full stack. A request that arrives later
    /// shows the peek again.
    mutating func hideAll() {
        hiddenKeys.formUnion(visible.map(\.key))
        selectedKey = nil
    }

    /// The person answered `key`: its card leaves the stack.
    mutating func markAnswered(_ key: UUID) {
        answeredKeys.insert(key)
        if selectedKey == key { selectedKey = nil }
    }

    /// The number of blank cards behind the top card.
    var stackDepth: Int {
        max(0, min(visible.count - 1, Self.maxStackDepth))
    }
}

/// Estimates whether a request fits the compact card. The estimate decides
/// only whether the card is compact: the card never cuts the command while
/// Allow is active (`ApprovalPeekContent.answer`), and the controller also
/// checks the measured height (`ApprovalPeekGeometry.maxCardHeight`).
nonisolated enum ApprovalPeekFit {
    /// Columns in one line of the command box (11 pt monospaced, 360 pt card).
    static let lineColumns = 44
    static let maxCommandLines = 4
    static let maxFolderColumns = 88
    static let maxPermissionLines = 4

    /// Display columns: an ASCII character counts 1, a tab counts 8, and any
    /// other scalar counts 2 (wide characters and marks are over-counted, on
    /// the safe side).
    static func columns(_ text: some StringProtocol) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            if scalar == "\t" { return total + 8 }
            return total + (scalar.isASCII ? 1 : 2)
        }
    }

    /// The lines `text` takes in the command box: each line between line
    /// breaks takes `ceil(columns / lineColumns)` lines, at least 1.
    static func wrappedLines(_ text: String) -> Int {
        var lines = 0
        var columns = 0
        func endLine() {
            lines += max(1, (columns + lineColumns - 1) / lineColumns)
            columns = 0
        }
        var afterReturn = false
        for scalar in text.unicodeScalars {
            defer { afterReturn = scalar == "\r" }
            if scalar == "\n" && afterReturn { continue }
            if scalar == "\n" || scalar == "\r" {
                endLine()
            } else if scalar == "\t" {
                columns += 8
            } else {
                columns += scalar.isASCII ? 1 : 2
            }
        }
        endLine()
        return lines
    }

    static func commandFits(_ command: String) -> Bool {
        wrappedLines(command) <= maxCommandLines
    }

    static func folderFits(_ folder: String) -> Bool {
        columns(folder) <= maxFolderColumns
    }

    static func permissionsFit(_ lines: [String]) -> Bool {
        lines.reduce(0) { $0 + wrappedLines($1) } <= maxPermissionLines
    }

    /// Every part the request has fits the compact card.
    static func fits(_ request: CanvasAgentRequest) -> Bool {
        if let command = request.command, !commandFits(command) { return false }
        if let cwd = request.cwd, !folderFits(cwd) { return false }
        if !request.permissions.isEmpty, !permissionsFit(request.permissions) { return false }
        return true
    }
}

/// What one peek card shows and which answers it offers.
nonisolated enum ApprovalPeekContent: Equatable, Sendable {
    /// Only the terminal can answer: the title and "Open terminal".
    case terminalOnly
    /// The full command, Allow, Deny, and the menu.
    case answer(CompanionRequestActions)
    /// The request does not fit: the command is cut to 2 lines, "Review"
    /// replaces Allow, and the actions have no accept option.
    case review(CompanionRequestActions)
    /// One short question: one button for each choice.
    case choices(CanvasAgentRequest.Question)
    /// Any other question: answered from the full Up next row.
    case answerInUpNext
    /// An answer was chosen and waits for the agent.
    case sending

    /// The most choices the card shows as buttons.
    static let maxChoices = 4
    /// The most label columns all choice buttons share.
    static let maxChoiceColumns = 44
    /// The longest question text, in characters, that the card shows.
    static let maxQuestionCharacters = 120

    static func resolve(
        request: CanvasAgentRequest, decision: CanvasAgentRequestDecision?, oversize: Bool
    ) -> ApprovalPeekContent {
        if request.terminalOnly { return .terminalOnly }
        if decision != nil { return .sending }
        if request.kind == .userInput {
            guard request.questions.count == 1, let question = request.questions.first,
                !question.terminalOnly, !question.choices.isEmpty,
                question.choices.count <= maxChoices,
                question.choices.reduce(0, { $0 + ApprovalPeekFit.columns($1.label) })
                    <= maxChoiceColumns,
                question.text.count <= maxQuestionCharacters
            else { return .answerInUpNext }
            return .choices(question)
        }
        let actions = CompanionRequestActions(request: request)
        guard actions.primary != nil || actions.deny != nil else { return .terminalOnly }
        if oversize || !ApprovalPeekFit.fits(request) {
            return .review(actions.withoutAccept)
        }
        return .answer(actions)
    }

    /// A drag or two-finger swipe to the right sends the primary answer.
    var allowsSwipeRight: Bool {
        if case .answer(let actions) = self { return actions.primary != nil }
        return false
    }

    /// A drag or two-finger swipe to the left denies.
    var allowsSwipeLeft: Bool {
        switch self {
        case .answer(let actions), .review(let actions): actions.deny != nil
        default: false
        }
    }
}

/// How a drag or a two-finger swipe on the top card answers. Only the
/// distance at release decides: velocity and the predicted end position are
/// not used, so a flick cannot approve a command (a safety choice).
nonisolated enum ApprovalSwipePolicy {
    enum Outcome: Equatable, Sendable {
        case allow
        case deny
        case cancel
    }

    /// Below this distance no label shows.
    static let deadZone: CGFloat = 24
    /// A release at or past this distance answers.
    static let commitDistance: CGFloat = 120
    /// The largest tilt, in degrees.
    static let maxTilt: Double = 8
    /// A blocked direction moves at most this far (a rubber band).
    static let blockedDirectionLimit: CGFloat = 24
    /// The strongest tint, at the commit distance.
    static let maxTintOpacity: Double = 0.35
    /// The distance a committed card flies to, past its own width.
    static let flyOffDistance: CGFloat = ApprovalPeekGeometry.cardWidth + 80

    /// The card's horizontal offset for a `translation`: it follows an
    /// allowed direction and rubber-bands in a blocked one.
    static func offset(translation: CGFloat, allowsRight: Bool, allowsLeft: Bool) -> CGFloat {
        let allowed = translation >= 0 ? allowsRight : allowsLeft
        guard !allowed else { return translation }
        let magnitude = abs(translation)
        let limit = blockedDirectionLimit
        let damped = limit * (1 - exp(-magnitude / (limit * 3)))
        return translation >= 0 ? damped : -damped
    }

    /// The tilt in degrees: `translation / 15`, clamped to `maxTilt`.
    static func tilt(_ translation: CGFloat) -> Double {
        min(max(Double(translation) / 15, -maxTilt), maxTilt)
    }

    /// The green or red tint's opacity: grows to `maxTintOpacity` at the
    /// commit distance.
    static func tintOpacity(_ translation: CGFloat) -> Double {
        min(Double(abs(translation)) / Double(commitDistance), 1) * maxTintOpacity
    }

    /// The label ("Allow" or "Deny") shows from the dead zone in an allowed
    /// direction.
    static func showsLabel(offset: CGFloat, allowsRight: Bool, allowsLeft: Bool) -> Bool {
        guard abs(offset) >= deadZone else { return false }
        return offset > 0 ? allowsRight : allowsLeft
    }

    /// What a release at `translation` does.
    static func outcome(translation: CGFloat, allowsRight: Bool, allowsLeft: Bool) -> Outcome {
        if translation >= commitDistance, allowsRight { return .allow }
        if translation <= -commitDistance, allowsLeft { return .deny }
        return .cancel
    }
}

/// Where the peek's card and window go. Pure: rectangles in, rectangles out,
/// in screen coordinates (bottom-left origin).
nonisolated enum ApprovalPeekGeometry {
    static let cardWidth: CGFloat = 360
    static let cornerRadius: CGFloat = 18
    /// The space between the anchor's bottom edge and the card's top.
    static let anchorGap: CGFloat = 6
    /// The least space between the card and a side of the visible frame.
    static let screenInset: CGFloat = 8
    /// Clear space at each side of the card, so a dragged card does not
    /// clip at the window edge.
    static let sideGutter: CGFloat = 140
    /// Clear space below the card for its shadow.
    static let bottomGutter: CGFloat = 16
    /// Each blank card behind the top card is this much lower.
    static let stackStep: CGFloat = 6
    /// A measured top card taller than this becomes a Review card.
    static let maxCardHeight: CGFloat = 260

    /// The card (with its stack) hangs `anchorGap` below `anchor`, centred
    /// on it, and stays `screenInset` inside `visibleFrame` at the sides.
    static func cardFrame(anchor: CGRect, cardSize: CGSize, visibleFrame: CGRect) -> CGRect {
        let top = anchor.minY - anchorGap
        var x = anchor.midX - cardSize.width / 2
        let minX = visibleFrame.minX + screenInset
        let maxX = visibleFrame.maxX - screenInset - cardSize.width
        x = maxX < minX ? minX : min(max(x, minX), maxX)
        return CGRect(
            x: x, y: top - cardSize.height, width: cardSize.width, height: cardSize.height)
    }

    /// The window: the card plus `sideGutter` at each side and
    /// `bottomGutter` below.
    static func panelFrame(card: CGRect) -> CGRect {
        CGRect(
            x: card.minX - sideGutter, y: card.minY - bottomGutter,
            width: card.width + 2 * sideGutter, height: card.height + bottomGutter)
    }

    /// The window areas that pass clicks to the windows behind: the two side
    /// gutters and the strip below the card.
    static func clickThroughRegions(panel: CGRect, card: CGRect) -> [CGRect] {
        [
            CGRect(
                x: panel.minX, y: panel.minY, width: card.minX - panel.minX, height: panel.height),
            CGRect(
                x: card.maxX, y: panel.minY, width: panel.maxX - card.maxX, height: panel.height),
            CGRect(x: card.minX, y: panel.minY, width: card.width, height: card.minY - panel.minY),
        ]
    }

    /// The anchor when the menu bar item has no window (macOS hid it): a
    /// zero-height rectangle at the top centre of the visible frame.
    static func fallbackAnchor(visibleFrame: CGRect) -> CGRect {
        CGRect(x: visibleFrame.midX, y: visibleFrame.maxY, width: 0, height: 0)
    }
}

/// The VoiceOver announcement for a new peek card.
nonisolated enum ApprovalPeekText {
    static let panelLabel = "Rafu approval request"

    static func announcement(for entry: ApprovalPeekEntry) -> String {
        let agent = entry.cli.displayName
        let request = entry.request
        switch request.kind {
        case .userInput:
            let text = request.questions.first?.text ?? ""
            return text.isEmpty ? "\(agent) asks: Answer questions" : "\(agent) asks: \(text)"
        case .fileChange:
            return "\(agent) needs approval: Apply file changes. Open the terminal to answer."
        case .permissions:
            return "\(agent) needs approval: Grant permissions"
        case .command:
            guard !request.terminalOnly, let command = request.command else {
                return "\(agent) needs approval: Run command. Open the terminal to answer."
            }
            return "\(agent) needs approval: \(command)"
        }
    }
}
