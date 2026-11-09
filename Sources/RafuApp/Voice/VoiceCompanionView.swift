import AppKit
import Observation
import RafuCore
import SwiftUI

/// One workspace window's voice companion state: its corner, the tuck under
/// a dragged board card, and the pill and timeline toggles. The window root
/// owns it in `@State`, puts it in the environment (board cards report their
/// drags to it) and publishes it as a focused scene value (the Rafu menu).
@MainActor
@Observable
final class VoiceCompanionModel {
    private(set) var corner = VoiceCompanionCorner.defaultCorner
    /// The orb shrinks to a dot while a board card is dragged over it.
    private(set) var isTucked = false
    var showsPill = false
    var showsTimeline = false
    /// The host's size; the corner positions follow it.
    var containerSize: CGSize = .zero
    /// The host's origin in global coordinates, to bring chrome rects into
    /// the host's space.
    var hostOrigin: CGPoint = .zero
    /// Chrome the orb must not cover (a board's zoom capsule and overview),
    /// in global coordinates, by a stable key. Chrome writes it on layout
    /// changes only, through `setAvoidRect`. A model, not a preference, so
    /// it also crosses an `NSHostingView` boundary.
    private(set) var avoidRects: [String: CGRect] = [:]

    /// The orb's slot in global coordinates, for the tuck test. Written by
    /// the view on layout changes only; never observed.
    @ObservationIgnored var slotFrame: CGRect = .zero
    @ObservationIgnored private var cornerKey: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var untuckTask: Task<Void, Never>?
    @ObservationIgnored private var dragLive = false

    @ObservationIgnored private let untuckDelay: Duration

    init(
        defaults: UserDefaults = .standard,
        untuckDelay: Duration = VoiceCompanionPlacement.untuckDelay
    ) {
        self.defaults = defaults
        self.untuckDelay = untuckDelay
    }

    /// The pending return after a drag. Tests await it instead of sleeping.
    var pendingUntuck: Task<Void, Never>? { untuckTask }

    /// Reads the workspace's remembered corner. Called when the window's
    /// folder is known or changes.
    func load(workspacePath: String?) {
        let key = VoiceCompanionPlacement.cornerKey(workspacePath: workspacePath)
        guard key != cornerKey else { return }
        cornerKey = key
        let stored = defaults.string(forKey: key).flatMap(VoiceCompanionCorner.init(rawValue:))
        let next = stored ?? .defaultCorner
        if next != corner { corner = next }
    }

    func snap(to next: VoiceCompanionCorner) {
        if next != corner { corner = next }
        if let cornerKey { defaults.set(next.rawValue, forKey: cornerKey) }
    }

    func move(_ direction: VoiceCompanionCorner.Move) { snap(to: corner.moved(direction)) }

    /// The host's global frame; writes only what changed.
    func noteHostFrame(_ frame: CGRect) {
        let size: CGSize = frame.size
        let origin: CGPoint = frame.origin
        if containerSize != size { containerSize = size }
        if hostOrigin != origin { hostOrigin = origin }
    }

    /// Chrome reports its rect (global), or nil when it leaves.
    func setAvoidRect(_ rect: CGRect?, for key: String) {
        guard avoidRects[key] != rect else { return }
        avoidRects[key] = rect
    }

    /// The chrome rects in the host's space.
    var localAvoidRects: [CGRect] {
        avoidRects.keys.sorted().compactMap { key in
            avoidRects[key]?.offsetBy(dx: -hostOrigin.x, dy: -hostOrigin.y)
        }
    }

    /// The orb's slot in the host's space.
    var slotRect: CGRect {
        VoiceCompanionPlacement.slotRect(
            for: corner, in: containerSize, avoiding: localAvoidRects)
    }

    func moveToNextCorner() { snap(to: corner.next) }

    // MARK: Tuck

    /// A board card drag moved; `location` is in global coordinates.
    func noteBoardDrag(at location: CGPoint) {
        dragLive = true
        let tuck = VoiceCompanionPlacement.shouldTuck(
            dragLive: true, pointer: location, orbRect: slotFrame)
        guard tuck else { return }
        untuckTask?.cancel()
        untuckTask = nil
        if !isTucked { isTucked = true }
    }

    /// The drag ended: the orb returns `untuckDelay` later.
    func boardDragEnded() {
        dragLive = false
        guard isTucked, untuckTask == nil else { return }
        untuckTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.untuckDelay ?? .zero)
            } catch {
                return
            }
            guard let self else { return }
            self.untuckTask = nil
            // A new drag started meanwhile: its end schedules the return.
            guard !self.dragLive else { return }
            self.isTucked = false
        }
    }
}

extension FocusedValues {
    /// The key window's voice companion, for the Rafu menu.
    @Entry var voiceCompanion: VoiceCompanionModel?
}

/// The window's voice surface: the orb, its speech card and its control
/// pill, fixed in one corner of the workbench above the editor and below
/// sheets. Shown while a voice session is open (or failed); when idle only
/// if "Keep Rafu on the canvas when voice is off" is on, or while the
/// timeline is open.
struct VoiceCompanionHost: View {
    let model: VoiceCompanionModel
    let session: VoiceSession
    let workspace: WorkspaceSession
    @AppStorage(VoicePreferences.keepsCompanionKey) private var keepsCompanion = false

    private var isVisible: Bool {
        session.blobState != .idle || keepsCompanion || model.showsTimeline
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isVisible {
                VoiceCompanionView(model: model, session: session, reveal: reveal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: { frame in
            model.noteHostFrame(frame)
        }
        .onChange(of: workspace.rootURL?.path, initial: true) { _, path in
            model.load(workspacePath: path)
        }
    }

    /// The agent line's chevron: the board in front, that card focused.
    private func reveal(_ line: VoiceAgentLine) {
        guard let boardID = session.activeBoardID, let board = workspace.canvas.boards[boardID],
            let uuid = UUID(uuidString: line.cardID)
        else { return }
        let id = CanvasCardID(rawValue: uuid)
        guard board.cards.contains(where: { $0.id == id }) else { return }
        workspace.presentCanvasBoard(board)
        board.focus(id)
        board.zoomToCard(id)
    }
}

/// The positioned companion. The orb sits in a 64 pt slot that avoids board
/// chrome; the card and the pill take explicit rects from
/// `VoiceCompanionPlacement`, so they stay inside the host and off the orb.
private struct VoiceCompanionView: View {
    let model: VoiceCompanionModel
    let session: VoiceSession
    let reveal: (VoiceAgentLine) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
    @FocusState private var orbFocused: Bool
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var hoverIntent = false
    @State private var isHovering = false
    @State private var cardHeight: CGFloat = 0
    @State private var pillSize: CGSize = .zero

    private typealias Placement = VoiceCompanionPlacement

    private var corner: VoiceCompanionCorner { model.corner }

    private var cornerAlignment: Alignment {
        switch corner {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }

    private var orbSize: CGFloat {
        if model.isTucked { return Placement.tuckedOrbSize }
        if session.blobState == .idle { return Placement.idleOrbSize }
        return Placement.orbSize
    }

    private var partsHidden: Bool { model.isTucked || isDragging }

    var body: some View {
        let size = model.containerSize
        let avoid = model.localAvoidRects
        let slot = Placement.slotRect(for: corner, in: size, avoiding: avoid)
        let card = Placement.cardRect(
            orb: slot, card: CGSize(width: Placement.cardMaxWidth, height: cardHeight),
            corner: corner, in: size, avoiding: avoid)
        let pill = Placement.pillRect(
            orb: slot, pill: pillSize, corner: corner, in: size, avoiding: avoid,
            card: cardHeight > 0 && !partsHidden ? card.rect : nil)
        ZStack(alignment: .topLeading) {
            cardView
                .offset(x: card.rect.minX, y: card.rect.minY)
            orbSlot
                .offset(x: slot.minX + dragOffset.width, y: slot.minY + dragOffset.height)
            pillView
                .offset(x: pill.rect.minX, y: pill.rect.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: hoverIntent) { await settleHover() }
        .animation(
            RafuMotion.resolve(RafuMotion.companionSnap, reduceMotion: reduceMotion),
            value: corner
        )
        .animation(
            RafuMotion.resolve(RafuMotion.companionTuck, reduceMotion: reduceMotion),
            value: model.isTucked)
    }

    // MARK: Orb

    // Three parts, not one chain: Swift 6.3 (CI) cannot type-check the
    // whole modifier chain in reasonable time.
    private var orbSlot: some View {
        orbAccessible
            .popover(
                isPresented: Binding(
                    get: { model.showsTimeline }, set: { model.showsTimeline = $0 }),
                arrowEdge: corner.isTop ? .bottom : .top
            ) {
                VoiceTimelinePopover(session: session)
            }
            .contextMenu { VoiceCompanionMenuItems(model: model, session: session) }
            .frame(
                width: Placement.slotSize, height: Placement.slotSize, alignment: cornerAlignment
            )
            .animation(
                RafuMotion.resolve(RafuMotion.hoverIn, reduceMotion: reduceMotion),
                value: orbSize
            )
            // Inside the offset, so the global frame is where the slot is drawn.
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: { frame in
                model.slotFrame = frame
            }
    }

    /// The orb with its pointer and keyboard input.
    private var orbControl: some View {
        VoiceLiveOrb(session: session, size: orbSize)
            .contentShape(Circle())
            .gesture(dragGesture.exclusively(before: TapGesture().onEnded { activate() }))
            .focusable(interactions: .activate)
            .focused($orbFocused)
            .onChange(of: orbFocused) { _, focused in
                withAnimation(RafuMotion.resolve(RafuMotion.pillShow, reduceMotion: reduceMotion)) {
                    model.showsPill = focused || isHovering
                }
            }
            .onKeyPress(phases: .down) { press in handleKey(press) }
            .onHover { hovering in hoverIntent = hovering }
            .help(orbHelp)
    }

    /// The orb as one VoiceOver button with named actions.
    private var orbAccessible: some View {
        orbControl
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rafu voice")
            .accessibilityValue(session.blobState.accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { activate() }
            .accessibilityAction(named: "Start or stop listening") { session.toggleLatched() }
            .accessibilityAction(named: "Stop speaking") { session.stopSpeaking() }
            .accessibilityAction(named: "End session") { endSession() }
            .accessibilityAction(named: "Show timeline") { model.showsTimeline = true }
            .accessibilityAction(named: "Move to the next corner") { model.moveToNextCorner() }
    }

    private var dragGesture: some Gesture {
        // Global: the orb moves under the pointer, so a local translation
        // would feed back into itself.
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                isDragging = true
                // 1:1 with the pointer; no animation while it moves.
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { dragOffset = value.translation }
            }
            .onEnded { value in
                let next = Placement.corner(
                    afterDragFrom: model.slotRect, predicted: value.predictedEndTranslation,
                    in: model.containerSize)
                isDragging = false
                let animation = RafuMotion.resolve(
                    RafuMotion.companionSnap, reduceMotion: reduceMotion)
                withAnimation(animation) {
                    dragOffset = .zero
                    model.snap(to: next)
                }
            }
    }

    private var orbHelp: String {
        if let hint = session.hint { return "Rafu voice: \(hint)" }
        return "Rafu voice: \(session.blobState.word). Drag to move; Space shows the controls."
    }

    private func activate() {
        switch session.blobState {
        case .speaking: session.stopSpeaking()
        case .error: session.dismissError()
        default: session.toggleLatched()
        }
    }

    private func endSession() {
        Task { await session.close(reason: .user) }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .space, press.modifiers.isEmpty {
            withAnimation(RafuMotion.resolve(RafuMotion.pillShow, reduceMotion: reduceMotion)) {
                model.showsPill.toggle()
            }
            return .handled
        }
        guard press.modifiers.contains(.option) else { return .ignored }
        let move: VoiceCompanionCorner.Move? =
            switch press.key {
            case .leftArrow: .left
            case .rightArrow: .right
            case .upArrow: .up
            case .downArrow: .down
            default: nil
            }
        guard let move else { return .ignored }
        model.move(move)
        return .handled
    }

    /// The pill shows 150 ms after the pointer arrives and hides 300 ms
    /// after it leaves the orb and the pill. One short sleep per hover
    /// change; nothing loops.
    private func settleHover() async {
        let delay: Duration =
            hoverIntent
            ? Placement.pillShowDelay
            : .milliseconds(Int(RafuMotion.contextualHideDelay * 1_000))
        do {
            try await Task.sleep(for: delay)
        } catch {
            return
        }
        guard hoverIntent != isHovering || model.showsPill != hoverIntent else { return }
        // Keyboard focus keeps the pill after the pointer leaves.
        let showsPill = hoverIntent || orbFocused
        withAnimation(RafuMotion.resolve(RafuMotion.pillShow, reduceMotion: reduceMotion)) {
            isHovering = hoverIntent
            model.showsPill = showsPill
        }
    }

    // MARK: Card and pill

    /// Always in the tree, so its height is known before it shows; hidden
    /// while the orb is tucked or dragged.
    private var cardView: some View {
        VoiceSpeechCard(session: session, reveal: reveal)
            .frame(
                width: Placement.cardMaxWidth,
                alignment: corner.isLeading ? .leading : .trailing
            )
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: { height in
                cardHeight = height
            }
            .opacity(partsHidden ? 0 : 1)
            .allowsHitTesting(!partsHidden)
            .accessibilityHidden(partsHidden)
    }

    @ViewBuilder
    private var pillView: some View {
        if model.showsPill, !partsHidden {
            VoiceControlPill(
                session: session,
                showTimeline: { model.showsTimeline = true },
                openSettings: {
                    SettingsPaneRouter.shared.request(.voice)
                    openSettings()
                }
            )
            .fixedSize()
            .onGeometryChange(for: CGSize.self) {
                $0.size
            } action: { size in
                pillSize = size
            }
            // Until its size is known the rect is a guess: do not show it.
            .opacity(pillSize == .zero ? 0 : 1)
            .transition(.opacity)
            .onHover { hovering in hoverIntent = hovering }
        }
    }
}

/// The orb's context menu and the Rafu menu share these words.
struct VoiceCompanionMenuItems: View {
    let model: VoiceCompanionModel
    let session: VoiceSession

    var body: some View {
        Button(session.machine.mic == .latched ? "Stop Listening" : "Start Listening") {
            session.toggleLatched()
        }
        Button("Stop Speaking") { session.stopSpeaking() }
            .disabled(session.blobState != .speaking)
        if session.blobState.isOpen {
            Button("End Voice Session") { Task { await session.close(reason: .user) } }
        }
        if case .error = session.blobState {
            Button("Dismiss") { session.dismissError() }
        }
        Button("Show Voice Timeline") { model.showsTimeline = true }
        Button("Move to Next Corner") { model.moveToNextCorner() }
    }
}
