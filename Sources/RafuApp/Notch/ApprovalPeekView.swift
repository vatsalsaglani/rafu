import RafuCore
import SwiftUI

/// The approval peek's window content: the card stack at the top centre,
/// between the clear side gutters (`ApprovalPeekGeometry`), and the answered
/// card while it leaves. The window belongs to no scene, so the theme is set
/// here, as `NotchHUDView` does.
struct ApprovalPeekRootView: View {
    let controller: ApprovalPeekController

    var body: some View {
        ZStack(alignment: .top) {
            if let shown = controller.deck.shown {
                ApprovalPeekStackView(controller: controller, entry: shown)
                    .id(shown.key)
            }
            if let flash = controller.flash {
                ApprovalPeekDepartingCard(controller: controller, flash: flash)
                    .id(flash.id)
            }
        }
        .frame(width: ApprovalPeekGeometry.cardWidth)
        .padding(.horizontal, ApprovalPeekGeometry.sideGutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .rafuTheme(controller.theme)
        // The window belongs to no scene: this pauses the border's sweep
        // while the panel is hidden or the screen is locked.
        .rafuMotionScope()
    }
}

/// The top card with up to two blank cards behind it. Each back card is
/// 6 pt lower, smaller and fainter, and hidden from VoiceOver.
struct ApprovalPeekStackView: View {
    let controller: ApprovalPeekController
    let entry: ApprovalPeekEntry

    var body: some View {
        let depth = controller.deck.stackDepth
        // The back cards take the top card's size and stay still while the
        // top card moves (its offset does not change its layout frame).
        ApprovalPeekCardView(controller: controller, entry: entry)
            .background(alignment: .top) {
                ZStack {
                    ForEach(Array((0..<depth).reversed()), id: \.self) { index in
                        ApprovalPeekBackCard(level: index + 1)
                    }
                }
            }
    }
}

/// One blank card behind the top card.
private struct ApprovalPeekBackCard: View {
    let level: Int

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: ApprovalPeekGeometry.cornerRadius, style: .continuous)
        shape
            .fill(Color.black)
            .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .scaleEffect(level == 1 ? 0.96 : 0.92, anchor: .bottom)
            .offset(y: CGFloat(level) * ApprovalPeekGeometry.stackStep)
            .opacity(level == 1 ? 0.6 : 0.35)
            .accessibilityHidden(true)
    }
}

/// The top card: header, title, the request, and its answers. A drag to the
/// right allows and a drag to the left denies (`ApprovalSwipePolicy`); the
/// buttons give the same answers.
struct ApprovalPeekCardView: View {
    let controller: ApprovalPeekController
    let entry: ApprovalPeekEntry

    @State private var dragOffset: CGFloat = 0
    /// The drag started vertically, or during the quiet interval: ignored.
    @State private var dragRejected = false
    @State private var dragStarted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let content = controller.content(for: entry)
        let offset = dragStarted ? dragOffset : controller.scrollOffset
        ApprovalPeekCardBody(
            controller: controller, entry: entry, content: content, swipeOffset: offset,
            tone: .waiting, sweepKey: entry.key, interactive: true
        )
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: { height in
            controller.cardHeightChanged(height, for: entry.key)
        }
        .offset(x: offset)
        .rotationEffect(
            .degrees(reduceMotion ? 0 : ApprovalSwipePolicy.tilt(offset)), anchor: .bottom
        )
        .simultaneousGesture(drag(content))
        .onContinuousHover { phase in
            if case .active = phase { controller.notePointerMoved() }
        }
        .simultaneousGesture(TapGesture().onEnded { controller.noteClick() })
    }

    private func drag(_ content: ApprovalPeekContent) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                let allowsRight = content.allowsSwipeRight
                let allowsLeft = content.allowsSwipeLeft
                if !dragStarted && !dragRejected {
                    let horizontal = abs(value.translation.width) >= abs(value.translation.height)
                    if !horizontal || !controller.allowsGestureStart
                        || !(allowsRight || allowsLeft)
                    {
                        dragRejected = true
                        return
                    }
                    dragStarted = true
                    controller.noteClick()
                }
                guard dragStarted else { return }
                dragOffset = ApprovalSwipePolicy.offset(
                    translation: value.translation.width, allowsRight: allowsRight,
                    allowsLeft: allowsLeft)
            }
            .onEnded { value in
                defer { dragRejected = false }
                guard dragStarted else { return }
                // Only the distance at release decides; velocity is not used.
                let outcome = ApprovalSwipePolicy.outcome(
                    translation: value.translation.width,
                    allowsRight: content.allowsSwipeRight, allowsLeft: content.allowsSwipeLeft)
                let answered = controller.commitSwipe(
                    outcome, for: entry, content: content, offset: dragOffset)
                if answered {
                    dragOffset = 0
                    dragStarted = false
                } else if reduceMotion {
                    dragOffset = 0
                    dragStarted = false
                } else {
                    withAnimation(.spring(duration: 0.25)) {
                        dragOffset = 0
                    } completion: {
                        dragStarted = false
                    }
                }
            }
    }
}

/// The answered card while it leaves: the result word and tone, then it
/// flies off in its direction (or fades under Reduce Motion) and the next
/// card shows below it.
struct ApprovalPeekDepartingCard: View {
    let controller: ApprovalPeekController
    let flash: ApprovalPeekFlash

    @State private var offset: CGFloat
    @State private var opacity: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(controller: ApprovalPeekController, flash: ApprovalPeekFlash) {
        self.controller = controller
        self.flash = flash
        _offset = State(initialValue: flash.startOffset)
    }

    var body: some View {
        ApprovalPeekCardBody(
            controller: controller, entry: flash.entry, content: flash.content,
            swipeOffset: 0, tone: flash.result.tone, sweepKey: nil, interactive: false,
            result: flash.result
        )
        .offset(x: offset)
        .rotationEffect(
            .degrees(reduceMotion ? 0 : ApprovalSwipePolicy.tilt(offset)), anchor: .bottom
        )
        .opacity(opacity)
        .allowsHitTesting(false)
        .onAppear {
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.15)) { opacity = 0 }
            } else {
                withAnimation(.easeIn(duration: 0.22)) {
                    offset = flash.result.direction * ApprovalSwipePolicy.flyOffDistance
                    opacity = 0.4
                }
            }
        }
    }
}

/// The card itself, shared by the top card and the departing card.
private struct ApprovalPeekCardBody: View {
    let controller: ApprovalPeekController
    let entry: ApprovalPeekEntry
    let content: ApprovalPeekContent
    /// The swipe offset: drives the tint and the "Allow"/"Deny" label.
    let swipeOffset: CGFloat
    let tone: CompanionGlowTone
    let sweepKey: UUID?
    /// False on the departing card: no buttons respond.
    let interactive: Bool
    var result: ApprovalPeekFlashResult?

    @Environment(\.rafuTheme) private var theme

    private var ink: NotchInk { NotchInk(theme: theme) }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ApprovalPeekGeometry.cornerRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space2) {
            header
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.palette.warning)
            requestBody
            if let feedback = controller.feedback, interactive {
                Text(feedback)
                    .font(.system(size: 10))
                    .foregroundStyle(ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .controlSize(.small)
        .padding(14)
        .frame(width: ApprovalPeekGeometry.cardWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(shape.fill(Color.black))
        .overlay { swipeTint }
        .overlay(alignment: swipeOffset > 0 ? .topLeading : .topTrailing) { swipeLabel }
        .overlay { resultBadge }
        .companionGlowBorder(
            stroke: shape, clip: shape, visible: true, anyWorking: true, sweepKey: sweepKey,
            tone: tone
        )
        .clipShape(shape)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ApprovalPeekText.panelLabel)
    }

    private var title: String {
        switch entry.request.kind {
        case .command: "Run command"
        case .fileChange: "Apply file changes"
        case .permissions: "Grant permissions"
        case .userInput: "Answer questions"
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: RafuMetrics.space2) {
            AgentIconView(cli: entry.cli, size: 16)
                .accessibilityHidden(true)
            Button {
                controller.openTerminal(for: entry)
            } label: {
                Text(entry.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ink.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .buttonStyle(.plain)
            .help("Show this agent in its window")
            Spacer(minLength: 0)
            if interactive, let position = controller.deck.positionText {
                Button {
                    controller.showPrevious()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .disabled(!controller.deck.hasPrevious)
                .help("Previous request")
                .accessibilityLabel("Previous request")
                Text(position)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(ink.secondary)
                Button {
                    controller.showNext()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .disabled(!controller.deck.hasNext)
                .help("Next request")
                .accessibilityLabel("Next request")
            }
            Button {
                controller.hide()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Hide. The request stays in Up next.")
            .accessibilityLabel("Hide. The request stays in Up next.")
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(ink.secondary)
        .allowsHitTesting(interactive)
    }

    // MARK: Request

    @ViewBuilder
    private var requestBody: some View {
        let request = entry.request
        switch content {
        case .choices(let question):
            questionText(question)
        case .answerInUpNext:
            if let question = request.questions.first { questionText(question, limit: 3) }
        case .answer, .sending:
            if let text = ApprovalPeekText.boxText(request) {
                CompanionCommandBox(command: text)
                    .accessibilityLabel(spokenBox)
            }
            CompanionRequestDetails(request: request)
        case .needsExpand, .terminalOnly:
            if let text = ApprovalPeekText.boxText(request) {
                CompanionCommandBox(command: text, lineLimit: 2)
            }
            CompanionRequestDetails(request: request)
                .lineLimit(1)
                .truncationMode(.middle)
        case .expanded:
            if let text = ApprovalPeekText.boxText(request) {
                // The whole request, selectable, in a box that scrolls. One
                // VoiceOver element reads all of it.
                ScrollView {
                    CompanionCommandBox(command: text, selectable: true)
                }
                .frame(
                    height: ApprovalPeekGeometry.expandedBoxHeight(
                        lines: ApprovalPeekFit.wrappedLines(text),
                        visibleFrame: controller.visibleFrame, reserved: 150)
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenBox)
            }
            CompanionRequestDetails(request: request)
        }
    }

    /// What VoiceOver reads for the request box: all of it.
    private var spokenBox: String {
        ApprovalPeekText.spokenBox(agent: entry.cli.displayName, request: entry.request) ?? ""
    }

    private func questionText(_ question: CanvasAgentRequest.Question, limit: Int? = nil)
        -> some View
    {
        VStack(alignment: .leading, spacing: 2) {
            if !question.header.isEmpty {
                Text(verbatim: question.header)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ink.secondary)
            }
            Text(verbatim: question.text)
                .font(.system(size: 11))
                .foregroundStyle(ink.primary)
                .lineLimit(limit)
                .fixedSize(horizontal: false, vertical: limit == nil)
        }
    }

    // MARK: Buttons

    @ViewBuilder
    private var buttons: some View {
        Group {
            switch content {
            case .terminalOnly:
                Button("Open terminal") { controller.openTerminal(for: entry) }
            case .sending:
                Text("Sending answer…")
                    .font(.system(size: 11))
                    .foregroundStyle(ink.secondary)
            case .answer(let actions):
                CompanionRequestActionRow(
                    actions: actions, choose: choose, menuItems: menuItems)
            case .needsExpand(let actions):
                CompanionRequestActionRow(
                    actions: actions, showAll: { controller.expand(entry) }, choose: choose,
                    menuItems: menuItems)
            case .expanded(let actions):
                CompanionRequestActionRow(
                    actions: actions, choose: choose, menuItems: menuItems)
            case .choices(let question):
                HStack(spacing: RafuMetrics.space2) {
                    ForEach(question.choices.indices, id: \.self) { index in
                        let choice = question.choices[index]
                        Button {
                            choose(.answers([question.id: choice.label]))
                        } label: {
                            Text(choice.label).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .help(choice.detail.isEmpty ? choice.label : choice.detail)
                    }
                }
            case .answerInUpNext:
                if controller.canRevealUpNext {
                    Button("Answer in Up next") { controller.showInUpNext() }
                } else {
                    Button("Open terminal") { controller.openTerminal(for: entry) }
                }
            }
        }
        .allowsHitTesting(interactive)
    }

    private var menuItems: [CompanionRequestMenuItem] {
        var items = [
            CompanionRequestMenuItem(title: "Open terminal") { controller.openTerminal(for: entry) }
        ]
        if controller.canRevealUpNext {
            items.append(
                CompanionRequestMenuItem(title: "Show in Up next") { controller.showInUpNext() })
        }
        return items
    }

    private func choose(_ decision: CanvasAgentRequestDecision) {
        controller.noteClick()
        controller.answer(decision, for: entry)
    }

    // MARK: Swipe feedback

    private var allowsLabel: Bool {
        ApprovalSwipePolicy.showsLabel(
            offset: swipeOffset, allowsRight: content.allowsSwipeRight,
            allowsLeft: content.allowsSwipeLeft)
    }

    private var swipeColor: Color {
        swipeOffset > 0 ? theme.palette.success : theme.palette.error
    }

    @ViewBuilder
    private var swipeTint: some View {
        if allowsLabel {
            shape
                .fill(swipeColor.opacity(ApprovalSwipePolicy.tintOpacity(swipeOffset)))
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var swipeLabel: some View {
        if allowsLabel {
            let committed = abs(swipeOffset) >= ApprovalSwipePolicy.commitDistance
            Label(
                swipeOffset > 0 ? "Allow" : "Deny",
                systemImage: swipeOffset > 0 ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .font(.system(size: 13, weight: committed ? .bold : .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(swipeColor.opacity(committed ? 0.9 : 0.6)))
            .padding(10)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var resultBadge: some View {
        if let result {
            let color = result == .allowed ? theme.palette.success : theme.palette.error
            ZStack {
                shape.fill(color.opacity(0.3))
                Label(
                    result.word,
                    systemImage: result == .allowed ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
            }
            .allowsHitTesting(false)
        }
    }
}
