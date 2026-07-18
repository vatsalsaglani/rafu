import SwiftUI

/// The candidate-list sheet shown by `WorkspaceSession.navigate(kind:)` for
/// every outcome except a clean single-candidate jump: multiple candidates
/// to choose from, an in-progress index build, or nothing found. Presented
/// from `WorkspaceWindowView`; reads `session.navigationPeekContent`
/// directly rather than taking it as a constructor argument so it always
/// reflects the latest superseding navigation.
///
/// Renders `NavigationAnswer.tier.label` for provenance and NEVER branches
/// on the `NavigationTier` case itself — a lane-2 `.lsp(serverName:)` answer
/// renders through the exact same rows as `.syntactic`/`.text`, unchanged.
struct NavigationPeekView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.rafuTheme) private var theme
    @Bindable var session: WorkspaceSession
    @State private var selectedIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.palette.borderSubtle)
            content
        }
        .frame(width: 560, height: 360)
        .background(peekBackground)
        .clipShape(RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous)
                .strokeBorder(theme.palette.borderStrong.opacity(0.5))
        )
        .onKeyPress(.downArrow) {
            moveSelection(1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(-1)
            return .handled
        }
        .onKeyPress(.return) {
            jumpToSelection()
            return .handled
        }
        .onChange(of: session.navigationPeekContent) { _, _ in selectedIndex = 0 }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.turn.up.right.diamond")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.palette.accent)
                .frame(width: 24, height: 24)
                .background(Circle().fill(theme.palette.chipBackground))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
            Spacer()
            if let tierLabel {
                RafuChip(text: tierLabel)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tierLabel.map { "\(title), \($0)" } ?? title)
    }

    @ViewBuilder
    private var content: some View {
        switch session.navigationPeekContent {
        case .results(let answer):
            candidateList(answer)
        case .indexing:
            message("Indexing symbols…")
        case .empty(let kind):
            message(emptyMessage(for: kind))
        case nil:
            message("Nothing found")
        }
    }

    private var title: String {
        switch session.navigationPeekContent {
        case .results:
            "Navigation Results"
        case .indexing:
            "Navigation"
        case .empty(let kind):
            title(for: kind)
        case nil:
            "Navigation"
        }
    }

    private func title(for kind: NavigationTargetKind) -> String {
        switch kind {
        case .definition: "Go to Definition"
        case .declaration: "Go to Declaration"
        case .references: "Find References"
        case .hover: "Navigation"
        }
    }

    private var tierLabel: String? {
        guard case .results(let answer) = session.navigationPeekContent else { return nil }
        return answer.tier.label
    }

    private func candidateList(_ answer: NavigationAnswer) -> some View {
        let candidates = answer.candidates
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        candidateRow(candidate, isSelected: index == selectedIndex)
                            .id(index)
                            .onHover { hovering in
                                if hovering { selectedIndex = index }
                            }
                    }
                    if isTruncated(answer) {
                        truncationFooter
                    }
                }
                .padding(6)
            }
            .onChange(of: selectedIndex) { _, newValue in
                proxy.scrollTo(newValue, anchor: nil)
            }
        }
    }

    /// Whether `answer` may have more matches than were returned: a
    /// heuristic keyed on the text tier's candidate count exactly reaching
    /// its bounded search cap. `NavigationAnswer` carries no explicit
    /// truncation flag (see `TextSearchNavigationProvider.referencesResultCap`),
    /// so this under-discloses per-file truncation below the cap and can
    /// show the footer for a genuinely exact-cap match count.
    private func isTruncated(_ answer: NavigationAnswer) -> Bool {
        answer.tier == .text
            && answer.candidates.count == TextSearchNavigationProvider.referencesResultCap
    }

    private var truncationFooter: some View {
        Text("Showing first \(TextSearchNavigationProvider.referencesResultCap) matches")
            .font(.caption)
            .foregroundStyle(theme.palette.textMuted)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(
                "Showing only the first \(TextSearchNavigationProvider.referencesResultCap) "
                    + "matches; some results may not be shown."
            )
    }

    private func candidateRow(_ candidate: SymbolCandidate, isSelected: Bool) -> some View {
        Button {
            session.navigateToSymbolCandidate(candidate)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "curlybraces")
                    .frame(width: 20)
                    .foregroundStyle(
                        isSelected ? theme.palette.accent : theme.palette.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.name)
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                    Text("\(candidate.relativePath) · \(candidate.kindLabel)")
                        .font(.caption)
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !candidate.previewLine.isEmpty {
                        Text(candidate.previewLine)
                            .font(.caption.monospaced())
                            .foregroundStyle(theme.palette.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "return")
                        .font(.caption)
                        .foregroundStyle(theme.palette.textMuted)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
            )
            .background(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                    .fill(isSelected ? theme.palette.selection : .clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(candidate.name), \(candidate.kindLabel), \(candidate.relativePath)")
    }

    private func message(_ text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 22))
                .foregroundStyle(theme.palette.textMuted)
            Text(text)
                .foregroundStyle(theme.palette.textSecondary)
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyMessage(for kind: NavigationTargetKind) -> String {
        switch kind {
        case .definition: "No definition found"
        case .declaration: "No declaration found"
        case .references: "No references found"
        case .hover: "Nothing found"
        }
    }

    private var peekBackground: some View {
        theme.palette.cardBackground
    }

    private func moveSelection(_ delta: Int) {
        guard case .results(let answer) = session.navigationPeekContent,
            !answer.candidates.isEmpty
        else { return }
        let count = answer.candidates.count
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func jumpToSelection() {
        guard case .results(let answer) = session.navigationPeekContent,
            answer.candidates.indices.contains(selectedIndex)
        else { return }
        session.navigateToSymbolCandidate(answer.candidates[selectedIndex])
        dismiss()
    }
}
