import RafuCore
import SwiftUI

// The question set of an agent request (Claude Code `AskUserQuestion`, Codex
// `item/tool/requestUserInput`): one page per question, radio rows for a
// single-choice question, checkbox rows for a multiple-choice question, and
// an "Other…" row with a text field when the agent takes typed text. Shared
// by the Up next row and the expanded approval peek. The page, the chosen
// labels and the typed text are view state; the request stays a value. The
// answer goes out only when `CanvasAgentRequest.permits` is true. Typed text
// stays in memory and is never logged.

/// The answers the person built so far for one question set. Pure, so the
/// tests drive it directly.
nonisolated struct CompanionQuestionSetState: Equatable, Sendable {
    /// The page shown, 0-based.
    private(set) var page = 0
    /// Question id to the chosen labels.
    private(set) var selections: [String: Set<String>] = [:]
    /// Question id to the text in its "Other…" field.
    private(set) var texts: [String: String] = [:]
    /// Question ids whose "Other…" row is chosen.
    private(set) var otherChosen: Set<String> = []

    /// "Question 1 of 3", or nil for a set of one question.
    func pageTitle(count: Int) -> String? {
        count > 1 ? "Question \(min(page, count - 1) + 1) of \(count)" : nil
    }

    func isLastPage(count: Int) -> Bool { page >= count - 1 }

    mutating func next(count: Int) { page = min(page + 1, max(count - 1, 0)) }

    mutating func back() { page = max(page - 1, 0) }

    func isChosen(_ label: String, in question: CanvasAgentRequest.Question) -> Bool {
        selections[question.id]?.contains(label) ?? false
    }

    func isOtherChosen(_ question: CanvasAgentRequest.Question) -> Bool {
        otherChosen.contains(question.id)
    }

    func text(for question: CanvasAgentRequest.Question) -> String {
        texts[question.id] ?? ""
    }

    /// A click (or Space) on a choice row. A single-choice question keeps
    /// one answer: the label, never the label and the "Other…" text too.
    mutating func toggle(_ label: String, in question: CanvasAgentRequest.Question) {
        guard question.choices.contains(where: { $0.label == label }) else { return }
        if question.allowsMultiple {
            var chosen = selections[question.id] ?? []
            if chosen.contains(label) { chosen.remove(label) } else { chosen.insert(label) }
            selections[question.id] = chosen
        } else {
            selections[question.id] = [label]
            otherChosen.remove(question.id)
        }
    }

    /// A click (or Space) on the "Other…" row.
    mutating func toggleOther(in question: CanvasAgentRequest.Question) {
        guard question.allowsFreeText else { return }
        if question.allowsMultiple {
            if otherChosen.contains(question.id) {
                otherChosen.remove(question.id)
            } else {
                otherChosen.insert(question.id)
            }
        } else {
            otherChosen.insert(question.id)
            selections[question.id] = []
        }
    }

    /// The person typed in the "Other…" field. The field keeps only what can
    /// be sent: no control or format characters, at most
    /// `CanvasAgentRequest.Limits.freeTextBytes`. So the text sent is the text
    /// shown. Typing chooses the "Other…" row.
    mutating func setText(_ text: String, for question: CanvasAgentRequest.Question) {
        guard question.allowsFreeText else { return }
        let kept = Self.sendableText(text)
        texts[question.id] = kept
        if !kept.trimmingCharacters(in: .whitespaces).isEmpty {
            if !question.allowsMultiple { selections[question.id] = [] }
            otherChosen.insert(question.id)
        }
    }

    /// The answer to one question as it stands: the chosen labels in choice
    /// order, then the typed text when the "Other…" row is chosen and the
    /// text is not blank. Nil when nothing is chosen.
    func answer(for question: CanvasAgentRequest.Question) -> QuestionAnswer? {
        let chosen = selections[question.id] ?? []
        let labels = question.choices.map(\.label).filter { chosen.contains($0) }
        var text: String?
        if question.allowsFreeText, otherChosen.contains(question.id) {
            let trimmed = (texts[question.id] ?? "").trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { text = trimmed }
        }
        guard !labels.isEmpty || text != nil else { return nil }
        return QuestionAnswer(labels: labels, text: text)
    }

    /// The answer of each question that has one.
    func decision(for request: CanvasAgentRequest) -> CanvasAgentRequestDecision {
        var answers: [String: QuestionAnswer] = [:]
        for question in request.questions {
            if let answer = answer(for: question) { answers[question.id] = answer }
        }
        return .answers(answers)
    }

    /// "Answer" is on only when the request permits the whole answer.
    func canAnswer(_ request: CanvasAgentRequest) -> Bool {
        request.permits(decision(for: request))
    }

    /// The question has a valid answer.
    func isAnswered(_ question: CanvasAgentRequest.Question) -> Bool {
        answer(for: question).map(question.accepts) ?? false
    }

    /// `text` with the characters the request sanitizer removes taken out
    /// (control, format, line and paragraph separators), cut to
    /// `Limits.freeTextBytes` at a character boundary.
    static func sendableText(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: continue
            default: scalars.append(scalar)
            }
        }
        let stripped = String(scalars)
        let limit = CanvasAgentRequest.Limits.freeTextBytes
        guard stripped.utf8.count > limit else { return stripped }
        var result = ""
        var used = 0
        for character in stripped {
            let size = character.utf8.count
            guard used + size <= limit else { break }
            result.append(character)
            used += size
        }
        return result
    }
}

/// The question set view. `readOnly` shows the questions of a request only
/// the terminal can answer: no row responds and no Answer button shows.
struct CompanionQuestionSetView: View {
    let request: CanvasAgentRequest
    var readOnly = false
    /// Set in the approval peek: the choice list scrolls above this height,
    /// so the buttons stay in view. Nil in Up next, which scrolls itself.
    var maxChoicesHeight: CGFloat?
    let choose: (CanvasAgentRequestDecision) -> Void
    let openTerminal: () -> Void

    @State private var state = CompanionQuestionSetState()
    @State private var choicesHeight: CGFloat = 0
    @FocusState private var focus: Field?
    @Environment(\.rafuTheme) private var theme

    private enum Field: Hashable {
        case choice(Int)
        case other
    }

    private var ink: NotchInk { NotchInk(theme: theme) }

    var body: some View {
        let questions = request.questions
        if let question = questions.indices.contains(state.page) ? questions[state.page] : nil {
            VStack(alignment: .leading, spacing: RafuMetrics.space2) {
                pageHeader(question, count: questions.count)
                Text(verbatim: question.text)
                    .font(.system(size: 11))
                    .foregroundStyle(ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                choiceList(question)
                if readOnly {
                    Text("Only the terminal can answer this question.")
                        .font(.system(size: 10))
                        .foregroundStyle(ink.muted)
                }
                navigation(count: questions.count)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .onKeyPress(.upArrow) { moveFocus(by: -1, in: question) }
            .onKeyPress(.downArrow) { moveFocus(by: 1, in: question) }
            .onKeyPress(.return) {
                // The text field goes on through `onSubmit`: never both.
                focus == .other ? .ignored : goOn(count: questions.count)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(state.pageTitle(count: questions.count) ?? "Question")
        }
    }

    // MARK: Page

    private func pageHeader(_ question: CanvasAgentRequest.Question, count: Int) -> some View {
        HStack(spacing: RafuMetrics.space2) {
            if let title = state.pageTitle(count: count) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ink.secondary)
                    .accessibilityAddTraits(.isHeader)
            }
            if !question.header.isEmpty {
                Text(verbatim: question.header)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ink.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if question.allowsMultiple {
                Text("Choose one or more")
                    .font(.system(size: 10))
                    .foregroundStyle(ink.muted)
            }
        }
    }

    @ViewBuilder
    private func choiceList(_ question: CanvasAgentRequest.Question) -> some View {
        let rows = VStack(alignment: .leading, spacing: RafuMetrics.space1) {
            ForEach(question.choices.indices, id: \.self) { index in
                choiceRow(question.choices[index], index: index, in: question)
            }
            if question.allowsFreeText && !readOnly { otherRow(question) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let maxChoicesHeight {
            ScrollView(.vertical) {
                rows.onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: { height in
                    choicesHeight = height
                }
            }
            .frame(height: max(1, min(choicesHeight, maxChoicesHeight)))
        } else {
            rows
        }
    }

    private func choiceRow(
        _ choice: CanvasAgentRequest.Choice, index: Int, in question: CanvasAgentRequest.Question
    ) -> some View {
        let chosen = state.isChosen(choice.label, in: question)
        return Button {
            state.toggle(choice.label, in: question)
        } label: {
            HStack(alignment: .top, spacing: RafuMetrics.space2) {
                Image(systemName: Self.symbol(chosen: chosen, multiple: question.allowsMultiple))
                    .foregroundStyle(chosen ? ink.accent : ink.secondary)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: choice.label)
                        .font(.system(size: 11, weight: chosen ? .semibold : .regular))
                        .foregroundStyle(ink.primary)
                    if !choice.detail.isEmpty {
                        Text(verbatim: choice.detail)
                            .font(.system(size: 10))
                            .foregroundStyle(ink.muted)
                    }
                    if let preview = choice.preview {
                        CompanionCommandBox(command: preview)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(readOnly)
        .focused($focus, equals: .choice(index))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            choice.detail.isEmpty ? choice.label : "\(choice.label), \(choice.detail)"
        )
        .accessibilityValue(question.allowsMultiple ? (chosen ? "Checked" : "Not checked") : "")
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .modifier(PreviewContent(preview: choice.preview))
    }

    private func otherRow(_ question: CanvasAgentRequest.Question) -> some View {
        let chosen = state.isOtherChosen(question)
        return HStack(alignment: .center, spacing: RafuMetrics.space2) {
            Button {
                state.toggleOther(in: question)
                focus = .other
            } label: {
                Image(systemName: Self.symbol(chosen: chosen, multiple: question.allowsMultiple))
                    .foregroundStyle(chosen ? ink.accent : ink.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Other")
            .accessibilityAddTraits(chosen ? .isSelected : [])
            TextField(
                "Other…",
                text: Binding(
                    get: { state.text(for: question) },
                    set: { state.setText($0, for: question) })
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
            .focused($focus, equals: .other)
            .onSubmit { _ = goOn(count: request.questions.count) }
            .onExitCommand { focus = nil }
            .accessibilityLabel("Other answer")
            .accessibilityHint("Type your own answer")
        }
    }

    // MARK: Navigation

    private func navigation(count: Int) -> some View {
        HStack(spacing: RafuMetrics.space2) {
            if count > 1 {
                Button("Back") {
                    state.back()
                    focus = nil
                }
                .disabled(state.page == 0)
            }
            if !state.isLastPage(count: count) {
                Button("Next") {
                    state.next(count: count)
                    focus = nil
                }
            } else if !readOnly {
                Button("Answer") { choose(state.decision(for: request)) }
                    .buttonStyle(CompanionAllowButtonStyle())
                    .disabled(!state.canAnswer(request))
                    .help("Send these answers to the agent")
            }
            Spacer(minLength: 0)
            Button("Open terminal", action: openTerminal)
        }
    }

    /// Return: the next page, or the answer on the last page when it is
    /// valid.
    private func goOn(count: Int) -> KeyPress.Result {
        guard !readOnly || !state.isLastPage(count: count) else { return .ignored }
        if !state.isLastPage(count: count) {
            state.next(count: count)
            focus = nil
            return .handled
        }
        guard state.canAnswer(request) else { return .ignored }
        choose(state.decision(for: request))
        return .handled
    }

    /// Up and Down move between the rows of the page.
    private func moveFocus(by offset: Int, in question: CanvasAgentRequest.Question)
        -> KeyPress.Result
    {
        guard !readOnly else { return .ignored }
        var fields = question.choices.indices.map { Field.choice($0) }
        if question.allowsFreeText { fields.append(.other) }
        guard !fields.isEmpty else { return .ignored }
        // Up and Down in the text field stay there.
        if focus == .other { return .ignored }
        let current = focus.flatMap { fields.firstIndex(of: $0) }
        let target = current.map { min(max($0 + offset, 0), fields.count - 1) } ?? 0
        focus = fields[target]
        return .handled
    }

    static func symbol(chosen: Bool, multiple: Bool) -> String {
        if multiple { return chosen ? "checkmark.square.fill" : "square" }
        return chosen ? "largecircle.fill.circle" : "circle"
    }
}

/// VoiceOver reads a choice's preview as more content, not in its label.
private struct PreviewContent: ViewModifier {
    let preview: String?

    func body(content: Content) -> some View {
        if let preview {
            content.accessibilityCustomContent(Text("Preview"), Text(verbatim: preview))
        } else {
            content
        }
    }
}

/// The read-only card of a plan the agent asks the person to approve: the
/// plan file, the plan in a box that scrolls, and a line when the plan was
/// cut. Only the terminal answers it.
struct CompanionPlanView: View {
    let request: CanvasAgentRequest
    /// The most box height; the box is shorter for a short plan.
    var maxBoxHeight: CGFloat = ApprovalPeekGeometry.expandedBodyHeight
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        let ink = NotchInk(theme: theme)
        VStack(alignment: .leading, spacing: RafuMetrics.space2) {
            if let path = request.reason, !path.isEmpty {
                Text(verbatim: path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(ink.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                    .accessibilityLabel("Plan file \(path)")
            }
            if let text = request.text, !text.isEmpty {
                let lines = ApprovalPeekFit.wrappedLines(text)
                ScrollView(.vertical) {
                    CompanionCommandBox(command: text, selectable: true)
                }
                .frame(
                    height: min(
                        ApprovalPeekGeometry.expandedBoxHeight(lines: lines), maxBoxHeight)
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Plan: \(text)")
            }
            if request.textIsCut {
                Text("The plan is cut here. Open the terminal to read all of it.")
                    .font(.system(size: 10))
                    .foregroundStyle(ink.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The read-only row of a prompt Rafu can only show: the agent's own text,
/// two lines with "Show all". The kind word is the row title. Only the
/// terminal answers it.
struct CompanionNoticeView: View {
    let request: CanvasAgentRequest
    @State private var showsAll = false
    @Environment(\.rafuTheme) private var theme

    /// Text longer than this many wrapped lines gets "Show all".
    static let collapsedLines = 2

    var body: some View {
        let ink = NotchInk(theme: theme)
        if let text = request.text, !text.isEmpty {
            let long = ApprovalPeekFit.wrappedLines(text) > Self.collapsedLines
            VStack(alignment: .leading, spacing: RafuMetrics.space1) {
                Text(verbatim: text)
                    .font(.system(size: 11))
                    .foregroundStyle(ink.primary)
                    .lineLimit(showsAll || !long ? nil : Self.collapsedLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if request.textIsCut && (showsAll || !long) {
                    Text("The text is cut here. Open the terminal to read all of it.")
                        .font(.system(size: 10))
                        .foregroundStyle(ink.muted)
                }
                if long {
                    Button(showsAll ? "Show less" : "Show all") { showsAll.toggle() }
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
