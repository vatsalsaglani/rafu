import AppKit
import SwiftUI

/// The one quiet selection style for sidebar lists: the Agent History look.
/// A selected row gets a rounded `selection` fill (a neutral tint in every
/// theme), a hovered row a `hover` fill, and under Increase Contrast the
/// selected row also gets a `borderStrong` hairline, so the selection never
/// rests on a low-contrast fill alone.
///
/// A `List(selection:)` must ALSO use `rafuQuietListSelection()`. Otherwise
/// AppKit draws its own highlight under this fill: the saturated system
/// accent while the list is first responder in the key window, whatever
/// `.tint` says. See `docs/references/sidebar-list-selection-style.md`.
struct RafuRowSelectionBackground: ViewModifier {
    let isSelected: Bool
    var isHovering = false
    var cornerRadius: CGFloat = RafuMetrics.radiusDenseSelection
    /// How far the fill reaches past the row's content on each side, for a
    /// row whose content sits flush with its leading control.
    var horizontalBleed: CGFloat = 0

    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        RafuRowSelectionPresentation.fill(
                            isSelected: isSelected, isHovering: isHovering, palette: theme.palette)
                    )
                    .padding(.horizontal, -horizontalBleed)
                    .allowsHitTesting(false)
            }
            .overlay {
                if RafuRowSelectionPresentation.showsHairline(
                    isSelected: isSelected, increasedContrast: contrast == .increased)
                {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(theme.palette.borderStrong, lineWidth: RafuMetrics.hairline)
                        .padding(.horizontal, -horizontalBleed)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// The pure rules behind `RafuRowSelectionBackground`.
nonisolated enum RafuRowSelectionPresentation {
    /// Selection wins over hover; nothing else fills.
    static func fill(isSelected: Bool, isHovering: Bool, palette: RafuThemePalette) -> Color {
        if isSelected { return palette.selection }
        return isHovering ? palette.hover : .clear
    }

    static func showsHairline(isSelected: Bool, increasedContrast: Bool) -> Bool {
        isSelected && increasedContrast
    }
}

extension View {
    /// The shared sidebar row fill. See `RafuRowSelectionBackground`.
    func rafuRowSelection(
        isSelected: Bool, isHovering: Bool = false,
        cornerRadius: CGFloat = RafuMetrics.radiusDenseSelection, horizontalBleed: CGFloat = 0
    ) -> some View {
        modifier(
            RafuRowSelectionBackground(
                isSelected: isSelected, isHovering: isHovering, cornerRadius: cornerRadius,
                horizontalBleed: horizontalBleed))
    }

    /// Turns off the native selection highlight of this `List(selection:)`,
    /// so its rows draw the shared quiet fill (`rafuRowSelection`) instead.
    /// Selection, arrow keys, multi-selection and the accessibility selected
    /// state are unchanged: only AppKit's drawing is off. Attach it on the
    /// `List` itself.
    func rafuQuietListSelection() -> some View {
        background(ListSelectionHighlightSuppressor())
    }
}

/// Sets the List's backing `NSTableView` (on macOS 15+ SDKs a SwiftUI
/// `NSOutlineView` subclass) to `selectionHighlightStyle = .none`. Its row
/// views use AppKit's selection drawing, which reads that style; SwiftUI
/// keeps the value across view updates. The probe re-applies on attach and
/// layout, and only writes when the value differs.
struct ListSelectionHighlightSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> ListSelectionHighlightProbeView {
        ListSelectionHighlightProbeView(frame: .zero)
    }

    func updateNSView(_ nsView: ListSelectionHighlightProbeView, context: Context) {
        nsView.apply()
        // The List's scroll view may not resolve on the update that first
        // attaches the probe; try once more on the next turn, no polling.
        DispatchQueue.main.async { [weak nsView] in nsView?.apply() }
    }
}

/// Zero-content probe beside a `List`; see `ListSelectionHighlightSuppressor`.
final class ListSelectionHighlightProbeView: NSView {
    private weak var tableView: NSTableView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tableView = nil
        apply()
    }

    override func layout() {
        super.layout()
        apply()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { false }

    func apply() {
        guard let tableView = resolveTableView() else { return }
        if tableView.selectionHighlightStyle != .none {
            tableView.selectionHighlightStyle = .none
        }
    }

    private func resolveTableView() -> NSTableView? {
        if let tableView, tableView.window != nil, tableView.window === window {
            return tableView
        }
        let found =
            OverlayScrollerProbeView.listScrollView(around: self)?.documentView as? NSTableView
        tableView = found
        return found
    }
}
