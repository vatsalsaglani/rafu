import AppKit
import SwiftUI

/// Pure rules shared by the narrow AppKit bridge and its headless tests.
nonisolated enum TerminalGroupSplitPresentation {
    static let minimumPaneLength: CGFloat = 120

    static func normalizedFraction(_ value: Double) -> Double {
        TerminalGroupSnapshot.normalizedFraction(value)
    }

    /// A minimum-size clamp affects only the temporary AppKit layout. It does
    /// not change the saved snapshot fraction.
    static func effectiveFraction(
        savedFraction: Double,
        availableLength: CGFloat,
        minimumPaneLength: CGFloat = minimumPaneLength
    ) -> Double {
        let saved = normalizedFraction(savedFraction)
        guard availableLength > 0, minimumPaneLength > 0 else { return saved }
        let minimum = min(0.5, Double(minimumPaneLength / availableLength))
        return min(max(saved, minimum), 1 - minimum)
    }
}

/// An AppKit split bridge is required because SwiftUI's split views do not
/// report divider drags. SwiftUI keeps the snapshot; this bridge holds only
/// two hosted children and applies a temporary effective fraction.
struct TerminalGroupSplitView<First: View, Second: View>: NSViewRepresentable {
    let id: TerminalGroupSplitID
    let axis: TerminalGroupSplitAxis
    let fraction: Double
    let onUserDividerChange: (TerminalGroupSplitID, Double) -> Void
    @ViewBuilder let first: () -> First
    @ViewBuilder let second: () -> Second

    init(
        id: TerminalGroupSplitID,
        axis: TerminalGroupSplitAxis,
        fraction: Double,
        onUserDividerChange: @escaping (TerminalGroupSplitID, Double) -> Void,
        @ViewBuilder first: @escaping () -> First,
        @ViewBuilder second: @escaping () -> Second
    ) {
        self.id = id
        self.axis = axis
        self.fraction = fraction
        self.onUserDividerChange = onUserDividerChange
        self.first = first
        self.second = second
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TerminalGroupNSSplitView {
        let splitView = TerminalGroupNSSplitView()
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.delegate = splitView
        splitView.addArrangedSubview(context.coordinator.firstHost)
        splitView.addArrangedSubview(context.coordinator.secondHost)
        configure(splitView, coordinator: context.coordinator)
        context.coordinator.firstHost.rootView = AnyView(first())
        context.coordinator.secondHost.rootView = AnyView(second())
        return splitView
    }

    func updateNSView(_ nsView: TerminalGroupNSSplitView, context: Context) {
        configure(nsView, coordinator: context.coordinator)
        context.coordinator.firstHost.rootView = AnyView(first())
        context.coordinator.secondHost.rootView = AnyView(second())
        nsView.applySavedFraction(TerminalGroupSplitPresentation.normalizedFraction(fraction))
    }

    static func dismantleNSView(_ nsView: TerminalGroupNSSplitView, coordinator: Coordinator) {
        nsView.onUserDividerChange = nil
        coordinator.releaseHostedViews()
    }

    private func configure(_ splitView: TerminalGroupNSSplitView, coordinator: Coordinator) {
        splitView.isVertical = axis == .columns
        splitView.dividerStyle = .thin
        splitView.onUserDividerChange = { [weak coordinator] fraction in
            guard let coordinator else { return }
            coordinator.onUserDividerChange?(fraction)
        }
        coordinator.onUserDividerChange = { [id, onUserDividerChange] fraction in
            onUserDividerChange(id, fraction)
        }
        splitView.minimumPaneLength = TerminalGroupSplitPresentation.minimumPaneLength
    }

    final class Coordinator {
        let firstHost = NSHostingView(rootView: AnyView(EmptyView()))
        let secondHost = NSHostingView(rootView: AnyView(EmptyView()))
        var onUserDividerChange: ((Double) -> Void)?

        func releaseHostedViews() {
            onUserDividerChange = nil
            firstHost.rootView = AnyView(EmptyView())
            secondHost.rootView = AnyView(EmptyView())
        }
    }
}

final class TerminalGroupNSSplitView: NSSplitView, NSSplitViewDelegate {
    var minimumPaneLength: CGFloat = TerminalGroupSplitPresentation.minimumPaneLength
    var onUserDividerChange: ((Double) -> Void)?

    private var isDraggingDivider = false
    private var dragStartFraction: Double?
    private var savedFraction = TerminalGroupSnapshot.defaultSplitFraction
    private var isApplyingSavedFraction = false

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        max(proposedMinimumPosition, minimumDividerCoordinate)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        min(proposedMaximumPosition, maximumDividerCoordinate)
    }

    var minimumDividerCoordinate: CGFloat {
        effectiveMinimumPaneLength
    }

    var maximumDividerCoordinate: CGFloat {
        max(minimumDividerCoordinate, usableContentLength - effectiveMinimumPaneLength)
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        isDraggingDivider = isDividerHit(at: location)
        if isDraggingDivider {
            beginUserDividerDrag()
        }
        super.mouseDown(with: event)
        completeUserDividerDrag()
    }

    func applySavedFraction(_ savedFraction: Double) {
        self.savedFraction = TerminalGroupSplitPresentation.normalizedFraction(savedFraction)
        // The snapshot remains authoritative, but applying an unrelated
        // update while AppKit tracks a divider would snap the active drag.
        // Retain it now; the next post-drag update or resize applies it.
        guard !isDraggingDivider else { return }
        applySavedFractionForCurrentBounds()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        guard !isApplyingSavedFraction, !isDraggingDivider else { return }
        applySavedFractionForCurrentBounds()
    }

    /// Exposed to the focused AppKit test as the deterministic equivalent of
    /// NSSplitView's divider tracking. Production tracking enters and leaves
    /// through `mouseDown(with:)` above.
    func beginUserDividerDrag() {
        isDraggingDivider = true
        dragStartFraction = currentFraction()
    }

    func completeUserDividerDrag() {
        guard isDraggingDivider else { return }
        isDraggingDivider = false
        defer { dragStartFraction = nil }
        guard let dragStartFraction, let finalFraction = currentFraction(),
            abs(finalFraction - dragStartFraction) > 0.000_1
        else { return }
        // Keep the live display stable until the snapshot owner returns the
        // same user fraction through `updateNSView`.
        savedFraction = finalFraction
        onUserDividerChange?(finalFraction)
    }

    private func applySavedFractionForCurrentBounds() {
        guard subviews.count == 2 else { return }
        let contentLength = usableContentLength
        let effective = TerminalGroupSplitPresentation.effectiveFraction(
            savedFraction: savedFraction,
            availableLength: contentLength,
            minimumPaneLength: minimumPaneLength
        )
        let position = CGFloat(effective) * contentLength
        isApplyingSavedFraction = true
        setPosition(position, ofDividerAt: 0)
        isApplyingSavedFraction = false
    }

    private func currentFraction() -> Double? {
        guard subviews.count == 2 else { return nil }
        let contentLength = usableContentLength
        guard contentLength > 0 else { return nil }
        let firstLength = isVertical ? subviews[0].frame.width : subviews[0].frame.height
        return TerminalGroupSplitPresentation.normalizedFraction(
            Double(firstLength / contentLength)
        )
    }

    private var usableContentLength: CGFloat {
        max(0, (isVertical ? bounds.width : bounds.height) - dividerThickness)
    }

    private var effectiveMinimumPaneLength: CGFloat {
        min(minimumPaneLength, usableContentLength / 2)
    }

    private func isDividerHit(at location: NSPoint) -> Bool {
        guard subviews.count == 2 else { return false }
        let dividerCoordinate = isVertical ? subviews[0].frame.maxX : subviews[0].frame.maxY
        let pointerCoordinate = isVertical ? location.x : location.y
        return abs(pointerCoordinate - dividerCoordinate) <= (dividerThickness / 2) + 2
    }
}
