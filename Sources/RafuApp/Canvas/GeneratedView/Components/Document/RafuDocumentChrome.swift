import JSONRenderCore
import JSONRenderSwiftUI
import SwiftUI

extension EnvironmentValues {
    /// The directory of the MDX document being drawn. The `Markdown` component
    /// resolves relative image and link references against it. Nil for a
    /// generated view, which has no document.
    @Entry var rafuDocumentBaseURL: URL?
}

/// The quiet bordered container every document block (except a callout)
/// shares. Moved from `MDXComponentView` so the document components and the
/// MDX fallback block draw one frame (ADR 0034 amendment).
struct RafuDocumentFrame<Header: View, Content: View>: View {
    var showsHeader = true
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                header
                    .padding(.horizontal, RafuMetrics.space3)
                    .padding(.vertical, RafuMetrics.space2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) {
                        Divider().overlay(theme.palette.borderSubtle)
                    }
            }
            content
                .padding(RafuMetrics.space3)
        }
        .background(theme.palette.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous)
                .strokeBorder(theme.palette.borderSubtle)
        )
        .clipShape(RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous))
    }
}

/// A frame header: symbol, title, and an optional status chip.
struct RafuDocumentHeader: View {
    let systemImage: String
    let title: Text
    let badge: Text?

    @Environment(\.rafuTheme) private var theme

    init(systemImage: String, title: String, badge: String?) {
        self.systemImage = systemImage
        self.title = Text(verbatim: title)
        self.badge = badge.map { Text(verbatim: $0) }
    }

    init(systemImage: String, title: Text, badge: Text?) {
        self.systemImage = systemImage
        self.title = title
        self.badge = badge
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: RafuMetrics.space2) {
            Image(systemName: systemImage)
                .foregroundStyle(theme.palette.textSecondary)
                .accessibilityHidden(true)
            title
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
            Spacer(minLength: RafuMetrics.space2)
            if let badge {
                badge
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.palette.textSecondary)
                    .padding(.horizontal, RafuMetrics.space2)
                    .padding(.vertical, 2)
                    .background(theme.palette.chipBackground, in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A component's children in source order, with the 12 pt gap the MDX
/// preview always used. Draws nothing when there are no children.
struct RafuDocumentChildren: View {
    let children: JRChildren

    var body: some View {
        if !children.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                children
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
