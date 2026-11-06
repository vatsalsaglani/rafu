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
            RafuPopupHeader(
                symbol: "arrow.triangle.turn.up.right.diamond", title: title,
                showsEscapeHint: false
            ) {
                if let tierLabel {
                    RafuChip(text: tierLabel)
                }
            }
            content
            RafuPopupFooter(hints: [("↑↓", "Navigate"), ("↩", "Open"), ("esc", "Close")]) {
                Button("Close") { dismiss() }
                    .buttonStyle(RafuSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 560, height: 360, alignment: .top)
        .rafuPopupSurface(.sheet)
        .onExitCommand { dismiss() }
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

    @ViewBuilder
    private var content: some View {
        switch session.navigationPeekContent {
        case .results(let answer):
            candidateList(answer)
        case .indexing:
            RafuEmptyState(symbol: "clock", message: "Indexing symbols…")
        case .empty(let kind):
            RafuEmptyState(symbol: "questionmark.circle", message: emptyMessage(for: kind))
        case nil:
            RafuEmptyState(symbol: "questionmark.circle", message: "Nothing found")
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
            RafuPopupRow(
                symbol: "curlybraces", title: candidate.name,
                caption: "\(candidate.relativePath) · \(candidate.kindLabel)",
                keyHint: isSelected ? "↩" : nil, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(candidate.name), \(candidate.kindLabel), \(candidate.relativePath)")
    }

    private func emptyMessage(for kind: NavigationTargetKind) -> String {
        switch kind {
        case .definition: "No definition found"
        case .declaration: "No declaration found"
        case .references: "No references found"
        case .hover: "Nothing found"
        }
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
