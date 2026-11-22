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
/// only whether the card is compact: the card never cuts the command or the
/// file change while Allow is active (`ApprovalPeekContent.answer`), and the
/// controller also checks the measured height
/// (`ApprovalPeekGeometry.maxCardHeight(visibleFrame:)`).
nonisolated enum ApprovalPeekFit {
    /// Columns in one line of the command box (11 pt monospaced, 360 pt card).
    static let lineColumns = 44
    /// The longest command, in wrapped lines, that Allow stays active for
    /// with no expand.
    static let maxCommandLines = 10
    /// The same bound for the text of a file change (its header line and its
    /// content or diff).
    static let maxBodyLines = 10
    static let maxFolderColumns = 88
    static let maxPermissionLines = 4
    /// The same bound for the two identity lines of a tool call (the friendly
    /// server and tool, then the raw name).
    static let maxToolIdentityLines = 6

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

    static func fileChangeFits(_ text: String) -> Bool {
        wrappedLines(text) <= maxBodyLines
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
        if let text = ApprovalPeekText.fileChangeText(request), !fileChangeFits(text) {
            return false
        }
        if request.kind == .toolCall, let reason = request.reason,
            wrappedLines(reason) > maxToolIdentityLines
        {
            return false
        }
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
    /// The request does not fit: its text is cut to 2 lines, "Show all"
    /// replaces Allow, and the actions have no accept option. Nothing can be
    /// allowed until the person expands the card.
    case needsExpand(CompanionRequestActions)
    /// The whole request in a scrollable, selectable box, with Allow active.
    /// Only a person's click on "Show all" gets here.
    case expanded(CompanionRequestActions)
    /// One short single-choice question: one button for each choice, and
    /// "Other…" (which expands the card) when the agent takes typed text.
    case choices(CanvasAgentRequest.Question)
    /// Any other question set, collapsed: the first question, and "Answer"
    /// expands the card. Nothing is chosen before the person expands it.
    case questionsCollapsed
    /// The question set whole (`CompanionQuestionSetView`). Only a person's
    /// click on "Answer" or "Other…" gets here.
    case questionSet
    /// An answer was chosen and waits for the agent.
    case sending

    /// The most choices the card shows as buttons.
    static let maxChoices = 4
    /// The most label columns all choice buttons share.
    static let maxChoiceColumns = 44
    /// The longest question text, in characters, that the card shows.
    static let maxQuestionCharacters = 120

    static func resolve(
        request: CanvasAgentRequest, decision: CanvasAgentRequestDecision?, oversize: Bool,
        isExpanded: Bool = false
    ) -> ApprovalPeekContent {
        if request.terminalOnly { return .terminalOnly }
        if decision != nil { return .sending }
        if request.kind == .userInput {
            if isExpanded { return .questionSet }
            guard request.questions.count == 1, let question = request.questions.first,
                !question.terminalOnly, !question.allowsMultiple, !question.choices.isEmpty,
                question.choices.count <= maxChoices,
                question.choices.reduce(0, { $0 + ApprovalPeekFit.columns($1.label) })
                    <= maxChoiceColumns,
                question.text.count <= maxQuestionCharacters
            else { return .questionsCollapsed }
            return .choices(question)
        }
        let actions = CompanionRequestActions(request: request)
        guard actions.primary != nil || actions.deny != nil else { return .terminalOnly }
        if oversize || !ApprovalPeekFit.fits(request) {
            return isExpanded ? .expanded(actions) : .needsExpand(actions.withoutAccept)
        }
        return .answer(actions)
    }

    /// A drag or two-finger swipe to the right sends the primary answer. Not
    /// before the card shows the whole request.
    var allowsSwipeRight: Bool {
        switch self {
        case .answer(let actions), .expanded(let actions): actions.primary != nil
        default: false
        }
    }

    /// A drag or two-finger swipe to the left denies.
    var allowsSwipeLeft: Bool {
        switch self {
        case .answer(let actions), .needsExpand(let actions), .expanded(let actions):
            actions.deny != nil
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
    /// The card height limit before the screen is known, and the least limit
    /// on any screen.
    static let defaultMaxCardHeight: CGFloat = 260
    /// The most height the card limit reaches on a tall screen.
    static let tallestMaxCardHeight: CGFloat = 420
    /// The height of the scrollable box that shows a whole request.
    static let expandedBodyHeight: CGFloat = 220
    /// The height of one line of the 11 pt monospaced request box.
    static let bodyLineHeight: CGFloat = 14

    /// A measured top card taller than this needs "Show all": 45% of the
    /// visible screen height, between 260 and 420 pt.
    static func maxCardHeight(visibleFrame: CGRect) -> CGFloat {
        max(defaultMaxCardHeight, min(tallestMaxCardHeight, visibleFrame.height * 0.45))
    }

    /// The height of the expanded request box: the text's own height, at
    /// most `expandedBodyHeight`, and never more than the screen leaves room
    /// for (`visibleFrame` less `reserved`, the rest of the card).
    static func expandedBoxHeight(
        lines: Int, visibleFrame: CGRect? = nil, reserved: CGFloat = 0
    ) -> CGFloat {
        let wanted = CGFloat(lines) * bodyLineHeight + 12
        var limit = expandedBodyHeight
        if let visibleFrame {
            limit = min(limit, visibleFrame.height - 2 * screenInset - reserved)
        }
        return max(60, min(wanted, limit))
    }

    /// The most height of a plan's box in the compact peek card. The plan
    /// scrolls in it; Up next shows a taller box.
    static let planBoxHeight: CGFloat = 120
    /// The rest of an expanded question card: header, title, question text,
    /// the page line and the buttons.
    static let questionCardReserved: CGFloat = 230
    /// The least height of the choice list of an expanded question card.
    static let minQuestionChoicesHeight: CGFloat = 80

    /// The most height of the choice list of an expanded question card: it
    /// scrolls above this, so Answer stays in view. At most
    /// `expandedBodyHeight`, and never more than the screen leaves room for.
    static func questionChoicesHeight(visibleFrame: CGRect?) -> CGFloat {
        var limit = expandedBodyHeight
        if let visibleFrame {
            limit = min(limit, visibleFrame.height - 2 * screenInset - questionCardReserved)
        }
        return max(minQuestionChoicesHeight, limit)
    }

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
            let count = request.questions.count
            let lead = count > 1 ? "\(agent) asks \(count) questions" : "\(agent) asks"
            return text.isEmpty ? "\(lead): Answer questions" : "\(lead): \(text)"
        case .fileChange:
            guard !request.terminalOnly, let first = request.fileChanges.first else {
                return "\(agent) needs approval: Apply file changes. Open the terminal to answer."
            }
            let more = request.fileChanges.count - 1
            let target = more > 0 ? "\(first.path) and \(more) more" : first.path
            return "\(agent) needs approval: Apply file changes to \(target)"
        case .permissions:
            return "\(agent) needs approval: Grant permissions"
        case .command:
            guard !request.terminalOnly, let command = request.command else {
                return "\(agent) needs approval: Run command. Open the terminal to answer."
            }
            return "\(agent) needs approval: \(command)"
        case .toolCall:
            guard !request.terminalOnly, let reason = request.reason,
                let identity = AgentPermissionRequestSummary.toolIdentity(fromReason: reason)
            else {
                return "\(agent) needs approval: Use MCP tool. Open the terminal to answer."
            }
            return "\(agent) needs approval: Use tool \(identity.tool) of \(identity.server)"
        case .plan:
            return "\(agent) has a plan ready. Open the terminal to answer."
        case .notice:
            guard let kind = CompanionRequestPresentation.noticeKind(request) else {
                return "\(agent) needs you. Open the terminal to answer."
            }
            return "\(agent) needs you: \(kind). Open the terminal to answer."
        }
    }

    // MARK: Request text

    /// The text of the box that shows a file change whole: for each file one
    /// line that names the action and the path, then its content or diff.
    /// Nil for a request with no file change.
    static func fileChangeText(_ request: CanvasAgentRequest) -> String? {
        guard request.kind == .fileChange, !request.fileChanges.isEmpty else { return nil }
        return request.fileChanges.map { change in
            let header: String
            switch change.kind {
            case .create: header = "Create \(change.path)"
            case .overwrite: header = "Write \(change.path)"
            case .edit: header = "Edit \(change.path)"
            case .delete: header = "Delete \(change.path)"
            case .move: header = "Move \(change.path) to \(change.movePath ?? "")"
            }
            return change.body.isEmpty ? header : header + "\n" + change.body
        }.joined(separator: "\n\n")
    }

    /// The command or the file change text: what the box shows whole.
    static func boxText(_ request: CanvasAgentRequest) -> String? {
        request.command ?? fileChangeText(request)
    }

    /// What VoiceOver reads for the box: all of it, with the path and the
    /// kind of body ("New content" or "Diff").
    static func spokenBox(agent: String, request: CanvasAgentRequest) -> String? {
        if request.kind == .toolCall, let arguments = request.command {
            // The raw name is part of what is read: it is the real target.
            guard let reason = request.reason,
                let identity = AgentPermissionRequestSummary.toolIdentity(fromReason: reason)
            else { return "\(agent) asks to use an MCP tool with arguments \(arguments)" }
            return
                "\(agent) asks to use tool \(identity.tool) of \(identity.server), "
                + "named \(identity.name), with arguments \(arguments)"
        }
        if let command = request.command { return "\(agent) asks to run \(command)" }
        guard request.kind == .fileChange, !request.fileChanges.isEmpty else { return nil }
        return request.fileChanges.map { change in
            let lead: String
            switch change.kind {
            case .create, .overwrite: lead = "\(agent) asks to write \(change.path)."
            case .edit: lead = "\(agent) asks to change \(change.path)."
            case .delete: lead = "\(agent) asks to delete \(change.path)."
            case .move:
                lead = "\(agent) asks to move \(change.path) to \(change.movePath ?? "")."
            }
            guard !change.body.isEmpty else { return lead }
            return lead + (change.isDiff ? " Diff: " : " New content: ") + change.body
        }.joined(separator: " ")
    }
}
