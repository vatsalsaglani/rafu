import SwiftUI

/// The floating preview `.onDrag(_:preview:)` lifts under the pointer: an
/// icon and a one-line title in a small pill. Every call site passes
/// ALREADY-computed values (an icon view, a plain string) — this view does
/// no path parsing, icon lookup, or observable-state reads of its own, so it
/// stays a cheap, static snapshot for the drag session's lifetime.
struct RafuDragPreviewLabel<Icon: View>: View {
    let icon: Icon
    let title: String
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(theme.palette.elevatedBackground))
        .overlay(Capsule().strokeBorder(theme.palette.borderSubtle))
        .fixedSize()
    }
}
