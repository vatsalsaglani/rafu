import AppKit
import Observation
import RafuCore
import SwiftUI

/// The result word and border tone shown for a short time after an answer.
nonisolated enum ApprovalPeekFlashResult: Equatable, Sendable {
    case allowed
    case denied

    var word: String {
        switch self {
        case .allowed: "Allowed"
        case .denied: "Denied"
        }
    }

    var tone: CompanionGlowTone {
        switch self {
        case .allowed: .allowed
        case .denied: .denied
        }
    }

    /// The direction the answered card leaves in: right for allow.
    var direction: CGFloat {
        self == .allowed ? 1 : -1
    }
}

/// An answered card while it leaves: what it showed, the result, and where
/// a swipe left it, so the fly-off starts there.
struct ApprovalPeekFlash: Equatable {
    let id = UUID()
    let entry: ApprovalPeekEntry
    let content: ApprovalPeekContent
    let result: ApprovalPeekFlashResult
    let startOffset: CGFloat
}

/// The approval peek (decision record about answering agent requests from
/// the Up next row, ADR 0042, peek amendment): a small card that shows below
/// the notch, Rafu's island pill or the menu bar item when an agent asks for
/// approval. The full companion panel does not open, Rafu does not become
/// active, and the card does not take key status when it appears.
///
/// One app-wide owner, like `NotchHUDController`. All state is in memory;
/// request text is never logged or saved. Every answer, from a button, a
/// choice or a swipe, goes through `answer(_:for:startOffset:)`, which calls
/// `AgentRequestStore.choose` behind the click guard.
@Observable
@MainActor
final class ApprovalPeekController: NSObject {
    static let shared = ApprovalPeekController()

    /// The flash of the result word and border tone lasts this long.
    static let flashDuration: Duration = .milliseconds(350)
    /// The card height used before the view reports its measured height.
    static let estimatedCardHeight: CGFloat = 170

    // MARK: - View-visible state

    private(set) var deck = ApprovalPeekDeck()
    private(set) var flash: ApprovalPeekFlash?
    /// The message of an answer that did not go through.
    private(set) var feedback: String?
    /// Requests whose measured card was taller than the limit: they show as
    /// "Show all" cards.
    private(set) var oversizeKeys: Set<UUID> = []
    /// Requests the person expanded with "Show all". Only a click adds a
    /// key, so a card always starts collapsed and Allow stays off until the
    /// person has asked to see the whole request.
    private(set) var expandedKeys: Set<UUID> = []
    private(set) var theme = RafuThemeCatalog.indigo
    /// The panel is on screen.
    private(set) var isShowing = false
    /// The horizontal offset a two-finger swipe gives the top card.
    private(set) var scrollOffset: CGFloat = 0

    // MARK: - Private state

    @ObservationIgnored private weak var model: NotchCompanionModel?
    @ObservationIgnored private var panel: NotchHUDPanel?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var clickGuard = ApprovalClickGuard()
    @ObservationIgnored private var engagement = ApprovalKeyEngagement()
    @ObservationIgnored private var rows: [UUID: NotchAgentRow] = [:]
    @ObservationIgnored private var wantsPeek = false
    @ObservationIgnored private var lastShownKey: UUID?
    /// The person moved to the shown card with previous or next: no
    /// announcement for it.
    @ObservationIgnored private var personSelected = false
    @ObservationIgnored private var measuredHeight = estimatedCardHeight
    @ObservationIgnored private var flashTask: Task<Void, Never>?
    @ObservationIgnored private var scrollRaw: CGFloat = 0
    @ObservationIgnored private var scrollTracking = false

    override init() {
        super.init()
    }

    // MARK: - Start and refresh

    /// Starts watching the requests. Idempotent; a later call (a screen or
    /// a setting change) only moves the panel to its new place.
    func start(model: NotchCompanionModel) {
        self.model = model
        if started {
            // Some inputs (the companion switch) live in defaults and are not
            // observed: read them again without a second tracking chain.
            apply(Self.readInputs(model: model))
            reposition()
            return
        }
        started = true
        observe()
    }

    /// Reads the inputs under observation tracking, then applies them. The
    /// tracked closure only reads, so applying cannot re-trigger itself.
    /// `onChange` fires once per registration, so it re-arms on the next
    /// main-actor turn (the `UsageMenuBarItem.observe()` pattern).
    private func observe() {
        guard started, let model else { return }
        let inputs = withObservationTracking {
            Self.readInputs(model: model)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        apply(inputs)
    }

    private struct Inputs {
        var entries: [ApprovalPeekEntry] = []
        var rows: [UUID: NotchAgentRow] = [:]
        var chosenKeys: Set<UUID> = []
        var allowed = false
    }

    private static func readInputs(model: NotchCompanionModel) -> Inputs {
        let store = AgentRequestStore.shared
        var inputs = Inputs()
        let presence = model.presence
        inputs.allowed =
            model.isApprovalPeekEnabled && presence != CompanionPresence.none
            && !model.isPanelOpen
            && !model.isMenuPopoverShown
        // The terminal list is read only while a request waits.
        guard !store.pending.isEmpty else { return inputs }
        for row in model.allAgentRows where row.windowID != nil {
            guard let request = store.current(for: row.id) else { continue }
            inputs.entries.append(
                ApprovalPeekEntry(
                    controllerID: row.id, title: row.title, cli: row.cli, request: request))
            inputs.rows[row.id] = row
            if store.decision(for: row.id, key: request.key) != nil {
                inputs.chosenKeys.insert(request.key)
            }
        }
        return inputs
    }

    private func apply(_ inputs: Inputs) {
        rows = inputs.rows
        wantsPeek = inputs.allowed
        deck.update(inputs.entries, chosenKeys: inputs.chosenKeys)
        let pending = Set(inputs.entries.map(\.key))
        if !oversizeKeys.isSubset(of: pending) { oversizeKeys.formIntersection(pending) }
        if !expandedKeys.isSubset(of: pending) { expandedKeys.formIntersection(pending) }
        sync()
    }

    /// Shows, moves or hides the panel for the current deck.
    private func sync() {
        let shownKey = deck.shown?.key
        if shownKey != lastShownKey {
            let announce = shownKey != nil && !personSelected
            lastShownKey = shownKey
            personSelected = false
            clickGuard.noteRows(shownKey.map { [$0] } ?? [])
            feedback = nil
            resetScroll(animated: false)
            if announce, wantsPeek, let shown = deck.shown { announceArrival(of: shown) }
        }
        if wantsPeek && (deck.shown != nil || flash != nil) {
            present()
        } else {
            hidePanel()
        }
    }

    // MARK: - Content

    /// What the card for `entry` shows now.
    func content(for entry: ApprovalPeekEntry) -> ApprovalPeekContent {
        ApprovalPeekContent.resolve(
            request: entry.request,
            decision: AgentRequestStore.shared.decision(
                for: entry.controllerID, key: entry.key),
            oversize: oversizeKeys.contains(entry.key),
            isExpanded: expandedKeys.contains(entry.key))
    }

    /// A surface can show Up next ("Show in Up next" and "Answer in Up next").
    var canRevealUpNext: Bool { model?.canRevealUpNext ?? false }

    /// The visible frame of the screen the card hangs on, for height limits.
    var visibleFrame: CGRect? { anchor()?.visibleFrame }

    /// "Show all": the card shows the whole request in a scrollable box, and
    /// Allow becomes active. Ignored during the click guard's quiet interval
    /// after the shown card changed, like every other click of the card.
    func expand(_ entry: ApprovalPeekEntry) {
        guard clickGuard.allowsClick, !expandedKeys.contains(entry.key) else { return }
        expandedKeys.insert(entry.key)
        sync()
    }

    // MARK: - Answers

    /// The one answer path of the peek. Ignored during the click guard's
    /// quiet interval after the shown card changed. Returns true when the
    /// answer was chosen.
    @discardableResult
    func answer(
        _ decision: CanvasAgentRequestDecision, for entry: ApprovalPeekEntry,
        startOffset: CGFloat = 0
    ) -> Bool {
        guard clickGuard.allowsClick else { return false }
        let content = content(for: entry)
        let result = AgentRequestStore.shared.choose(
            controllerID: entry.controllerID, key: entry.key, decision: decision)
        switch result {
        case .chosen:
            let word: ApprovalPeekFlashResult
            switch decision {
            case .decline, .cancel: word = .denied
            case .accept, .acceptForSession, .answers: word = .allowed
            }
            startFlash(
                ApprovalPeekFlash(
                    entry: entry, content: content, result: word, startOffset: startOffset))
            deck.markAnswered(entry.key)
            sync()
            return true
        case .alreadyChosen:
            deck.markAnswered(entry.key)
            sync()
            return false
        case .stale, .invalid:
            feedback = CompanionRequestPresentation.message(for: result)
            return false
        }
    }

    /// A drag or a two-finger swipe may start: not during the quiet interval
    /// after the shown card changed.
    var allowsGestureStart: Bool { clickGuard.allowsClick }

    private func startFlash(_ flash: ApprovalPeekFlash) {
        self.flash = flash
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flashDuration)
            guard !Task.isCancelled, let self, self.flash?.id == flash.id else { return }
            self.flash = nil
            self.sync()
        }
    }

    // MARK: - Other actions

    /// The close button and Escape: hides the stack. The requests stay in
    /// Up next and in the badge.
    func hide() {
        deck.hideAll()
        sync()
    }

    func showNext() {
        personSelected = true
        deck.next()
        sync()
    }

    func showPrevious() {
        personSelected = true
        deck.previous()
        sync()
    }

    func openTerminal(for entry: ApprovalPeekEntry) {
        guard let row = rows[entry.controllerID] else { return }
        model?.focusAgent(row)
    }

    func showInUpNext() {
        model?.revealUpNext()
    }

    /// "Answer in Up next": the full row, or the terminal when no surface
    /// shows Up next.
    func review(_ entry: ApprovalPeekEntry) {
        if canRevealUpNext {
            showInUpNext()
        } else {
            openTerminal(for: entry)
        }
    }

    /// The top card's measured height. A collapsed card taller than the
    /// limit needs "Show all", so the layout never has to cut a command while
    /// Allow is active. An expanded card is not marked: its box scrolls, and
    /// its own height is clamped to the screen.
    func cardHeightChanged(_ height: CGFloat, for key: UUID) {
        guard height > 0, key == deck.shown?.key else { return }
        let limit =
            visibleFrame.map { ApprovalPeekGeometry.maxCardHeight(visibleFrame: $0) }
            ?? ApprovalPeekGeometry.defaultMaxCardHeight
        if !expandedKeys.contains(key), !oversizeKeys.contains(key), height > limit {
            oversizeKeys.insert(key)
            return
        }
        guard abs(height - measuredHeight) > 0.5 else { return }
        measuredHeight = height
        if isShowing { reposition() }
    }

    // MARK: - Key status

    /// A click in the card: the panel may take key status, so the buttons
    /// take keyboard focus and Escape works.
    func noteClick() {
        engagement.noteInteraction()
        updateKeyStatus()
    }

    /// The pointer moves over the card. It counts only after the quiet
    /// interval, so a card that appears under a moving pointer does not
    /// take key status at once.
    func notePointerMoved() {
        guard clickGuard.allowsClick, !engagement.wantsKey else { return }
        engagement.noteInteraction()
        updateKeyStatus()
    }

    private func updateKeyStatus() {
        guard let panel, isShowing else { return }
        let wantsKey = engagement.wantsKey
        let wasKey = panel.allowsKeyStatus
        panel.allowsKeyStatus = wantsKey
        if wantsKey && !wasKey { panel.makeKey() }
    }

    @objc
    private func panelDidResignKey() {
        engagement.endInteraction()
        panel?.allowsKeyStatus = false
    }

    // MARK: - Two-finger swipe

    /// One scroll-wheel event over the card. Only trackpad events count
    /// (precise deltas, no momentum), and only a gesture that began after
    /// the quiet interval.
    func scrollWheel(_ event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty,
            let shown = deck.shown, flash == nil
        else { return }
        let content = content(for: shown)
        let allowsRight = content.allowsSwipeRight
        let allowsLeft = content.allowsSwipeLeft
        let phase = event.phase
        if phase.contains(.began) {
            scrollTracking = allowsGestureStart && (allowsRight || allowsLeft)
            scrollRaw = 0
            scrollOffset = 0
            return
        }
        guard scrollTracking else { return }
        if phase.contains(.changed) {
            // The finger's direction (to be checked on each device).
            let delta =
                event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            scrollRaw += delta
            scrollOffset = ApprovalSwipePolicy.offset(
                translation: scrollRaw, allowsRight: allowsRight, allowsLeft: allowsLeft)
        } else if phase.contains(.ended) {
            scrollTracking = false
            let outcome = ApprovalSwipePolicy.outcome(
                translation: scrollRaw, allowsRight: allowsRight, allowsLeft: allowsLeft)
            commitSwipe(outcome, for: shown, content: content, offset: scrollOffset)
        } else if phase.contains(.cancelled) {
            scrollTracking = false
            resetScroll(animated: true)
        }
    }

    /// Answers for a released swipe, or springs the card back.
    @discardableResult
    func commitSwipe(
        _ outcome: ApprovalSwipePolicy.Outcome, for entry: ApprovalPeekEntry,
        content: ApprovalPeekContent, offset: CGFloat
    ) -> Bool {
        var answered = false
        switch outcome {
        case .allow:
            // Only a card that shows the whole request can be allowed.
            switch content {
            case .answer(let actions), .expanded(let actions):
                if let primary = actions.primary {
                    answered = answer(primary.decision, for: entry, startOffset: offset)
                }
            default: break
            }
        case .deny:
            switch content {
            case .answer(let actions), .needsExpand(let actions), .expanded(let actions):
                if let deny = actions.deny {
                    answered = answer(deny.decision, for: entry, startOffset: offset)
                }
            default: break
            }
        case .cancel: break
        }
        resetScroll(animated: !answered)
        return answered
    }

    private func resetScroll(animated: Bool) {
        scrollRaw = 0
        guard scrollOffset != 0 else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animated && !reduceMotion {
            withAnimation(.spring(duration: 0.25)) { scrollOffset = 0 }
        } else {
            scrollOffset = 0
        }
    }

    // MARK: - Accessibility

    private func announceArrival(of entry: ApprovalPeekEntry) {
        guard let app = NSApp else { return }
        NSAccessibility.post(
            element: app, notification: .announcementRequested,
            userInfo: [
                .announcement: ApprovalPeekText.announcement(for: entry),
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    // MARK: - Panel

    /// The anchor rectangle and the visible frame of its screen, for the
    /// companion surface in use.
    private func anchor() -> (anchor: CGRect, visibleFrame: CGRect)? {
        guard let model else { return nil }
        let presence = model.presence
        if presence.showsMenuBarItem {
            let screens = NSScreen.screens.map {
                CompanionMenuPanelScreen(frame: $0.frame, visibleFrame: $0.visibleFrame)
            }
            if let frame = model.menuBarAnchorFrame,
                let screen = CompanionMenuPanelGeometry.screen(for: frame, among: screens)
            {
                return (frame, screen.visibleFrame)
            }
            guard let metrics = NotchScreenAdapter.companionMetrics() else { return nil }
            return (
                ApprovalPeekGeometry.fallbackAnchor(visibleFrame: metrics.visibleFrame),
                metrics.visibleFrame
            )
        }
        guard presence.showsPanel, let metrics = NotchScreenAdapter.companionMetrics() else {
            return nil
        }
        let rect: CGRect?
        switch NotchCompanionGeometry.surface(for: metrics, allowsPill: model.allowsPill) {
        case .notch: rect = NotchHUDGeometry.notchRect(for: metrics)
        case .island: rect = NotchIslandGeometry.restingFrame(for: metrics)
        case .pill: rect = NotchCompanionGeometry.restingFrame(for: metrics, allowsPill: true)
        case nil: rect = nil
        }
        return rect.map { ($0, metrics.visibleFrame) }
    }

    private func frames() -> (panel: CGRect, card: CGRect)? {
        guard let anchor = anchor() else { return nil }
        let height =
            measuredHeight + CGFloat(deck.stackDepth) * ApprovalPeekGeometry.stackStep
        let card = ApprovalPeekGeometry.cardFrame(
            anchor: anchor.anchor,
            cardSize: CGSize(width: ApprovalPeekGeometry.cardWidth, height: height),
            visibleFrame: anchor.visibleFrame)
        return (ApprovalPeekGeometry.panelFrame(card: card), card)
    }

    private func present() {
        guard let frames = frames() else {
            hidePanel()
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if isShowing, let panel {
            if panel.frame != frames.panel { panel.setFrame(frames.panel, display: true) }
            panel.clickThroughRegions = ApprovalPeekGeometry.clickThroughRegions(
                panel: frames.panel, card: frames.card)
            return
        }
        theme = RafuThemeCatalog.resolvedForCurrentAppearance()
        let panel = self.panel ?? makePanel(frame: frames.panel)
        isShowing = true
        engagement.setRowsVisible(true)
        panel.allowsKeyStatus = false
        panel.clickThroughRegions = ApprovalPeekGeometry.clickThroughRegions(
            panel: frames.panel, card: frames.card)
        // The peek and the attention drop-down use the same place.
        NotchHUDController.shared.dismiss(reason: .attentionCleared)
        // Appear without activating: slide down and fade in, or fade only
        // under Reduce Motion.
        panel.alphaValue = 0
        panel.setFrame(
            reduceMotion ? frames.panel : frames.panel.offsetBy(dx: 0, dy: 8), display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.15 : 0.22
            panel.animator().alphaValue = 1
            if !reduceMotion { panel.animator().setFrame(frames.panel, display: true) }
        }
    }

    private func reposition() {
        guard isShowing, let panel, let frames = frames() else { return }
        panel.setFrame(frames.panel, display: true)
        panel.clickThroughRegions = ApprovalPeekGeometry.clickThroughRegions(
            panel: frames.panel, card: frames.card)
    }

    private func makePanel(frame: CGRect) -> NotchHUDPanel {
        let panel = NotchHUDPanel(contentRect: frame)
        // The card draws its own shadow; the window is clear.
        panel.hasShadow = false
        panel.onCancel = { [weak self] in self?.hide() }
        panel.setAccessibilityLabel(ApprovalPeekText.panelLabel)
        NotificationCenter.default.addObserver(
            self, selector: #selector(self.panelDidResignKey),
            name: NSWindow.didResignKeyNotification, object: panel)
        let hostingView = ApprovalPeekHostingView(rootView: ApprovalPeekRootView(controller: self))
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.onScrollWheel = { [weak self] event in self?.scrollWheel(event) }
        panel.contentView = hostingView
        self.panel = panel
        return panel
    }

    private func hidePanel() {
        guard isShowing, let panel else { return }
        isShowing = false
        engagement.setRowsVisible(false)
        panel.allowsKeyStatus = false
        if panel.isKeyWindow { panel.resignKey() }
        scrollTracking = false
        scrollOffset = 0
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = reduceMotion ? 0.01 : 0.18
                panel.animator().alphaValue = 0
            },
            completionHandler: { [weak self, weak panel] in
                Task { @MainActor [weak self, weak panel] in
                    // A new request may have shown the panel again.
                    guard let self, !self.isShowing else { return }
                    panel?.orderOut(nil)
                }
            })
    }
}

/// The peek's content view. It passes clicks in the side gutters to the
/// windows behind (`NotchHUDPassthroughHosting`) and hands trackpad scroll
/// events to the controller for the two-finger swipe: SwiftUI has no
/// scroll-wheel gesture, and every scroll event over the card reaches this
/// root view through the responder chain.
final class ApprovalPeekHostingView: NSHostingView<ApprovalPeekRootView>,
    NotchHUDPassthroughHosting
{
    var clickThroughRegions: [CGRect] = []
    var hitOutline: CompanionOutlineLimits?
    var onScrollWheel: ((NSEvent) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window, !clickThroughRegions.isEmpty else { return super.hitTest(point) }
        let screenPoint = window.convertPoint(toScreen: point)
        if clickThroughRegions.contains(where: { $0.contains(screenPoint) }) { return nil }
        return super.hitTest(point)
    }

    override func scrollWheel(with event: NSEvent) {
        if let onScrollWheel {
            onScrollWheel(event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}
