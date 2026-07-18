import SwiftUI

/// Pure, UI-free filtering for `RafuSearchableDropdown`: a case-insensitive,
/// whitespace-tokenized AND match against a caller-supplied set of searchable
/// fields per item. Kept separate from the view so it is trivially unit
/// testable without instantiating SwiftUI.
nonisolated enum RafuDropdownFilter {
    /// Whether every whitespace-separated token in `query` (case-insensitive)
    /// appears as a substring somewhere across `fields`. An empty or
    /// all-whitespace query always matches.
    static func matches(query: String, fields: [String]) -> Bool {
        let tokens = query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard !tokens.isEmpty else { return true }
        let haystack = fields.joined(separator: " ").lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
    }

    /// Filters `items` by `query` against the fields `fields` extracts from
    /// each item, preserving the original order.
    static func filter<Item>(_ items: [Item], query: String, fields: (Item) -> [String]) -> [Item] {
        items.filter { matches(query: query, fields: fields($0)) }
    }
}

/// Reusable, keyboard-navigable searchable dropdown: a trigger button that
/// opens a popover with a filter field over a scrollable row list. Built for
/// the Source Control branch switcher (GitInspectorView.branchMenu), and
/// intentionally generic over `Item` so a future consumer (e.g. a status-bar
/// branch switcher) can reuse it with the same `GitBranch` items and a plain
/// trigger label, via the `Trailing == EmptyView` convenience initializer.
struct RafuSearchableDropdown<Item: Identifiable, Label: View, Trailing: View>: View {
    let items: [Item]
    let text: (Item) -> String
    let keywords: (Item) -> [String]
    let isCurrent: (Item) -> Bool
    let onSelect: (Item) -> Void
    @ViewBuilder let trailing: (Item) -> Trailing
    @ViewBuilder let label: () -> Label
    var searchPrompt: String = "Search"

    @Environment(\.rafuTheme) private var theme
    @State private var isPresented = false
    @State private var query = ""
    @State private var highlighted: Item.ID?
    @FocusState private var searchFocused: Bool

    init(
        items: [Item],
        text: @escaping (Item) -> String,
        keywords: @escaping (Item) -> [String],
        isCurrent: @escaping (Item) -> Bool,
        onSelect: @escaping (Item) -> Void,
        searchPrompt: String = "Search",
        @ViewBuilder trailing: @escaping (Item) -> Trailing,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.items = items
        self.text = text
        self.keywords = keywords
        self.isCurrent = isCurrent
        self.onSelect = onSelect
        self.searchPrompt = searchPrompt
        self.trailing = trailing
        self.label = label
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
        }
    }

    private var filtered: [Item] {
        RafuDropdownFilter.filter(items, query: query) { keywords($0) }
    }

    private var popoverContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: RafuMetrics.space2) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(theme.palette.textMuted)
                TextField(searchPrompt, text: $query)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .focused($searchFocused)
                    .onSubmit { chooseHighlightedOrFirst() }
            }
            .rafuField(isFocused: searchFocused)
            .padding(RafuMetrics.space2)
            Divider().overlay(theme.palette.borderSubtle)
            if filtered.isEmpty {
                Text("No matching branches")
                    .font(.caption)
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(RafuMetrics.space3)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(filtered) { item in
                                row(item).id(item.id)
                            }
                        }
                        .padding(RafuMetrics.space1)
                    }
                    .onChange(of: highlighted) { _, newValue in
                        guard let newValue else { return }
                        proxy.scrollTo(newValue, anchor: nil)
                    }
                }
            }
        }
        .frame(width: 260)
        .frame(minHeight: 160, maxHeight: 320)
        .background(theme.palette.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous))
        .onKeyPress(.downArrow) {
            moveHighlight(1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveHighlight(-1)
            return .handled
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
        .onChange(of: query) { _, _ in highlighted = filtered.first?.id }
        .onAppear {
            highlighted = filtered.first?.id
            searchFocused = true
        }
    }

    private func row(_ item: Item) -> some View {
        RafuHoverRow(isSelected: item.id == highlighted) {
            HStack(spacing: RafuMetrics.space2) {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.palette.accent)
                    .frame(width: 14)
                    .opacity(isCurrent(item) ? 1 : 0)
                Text(text(item))
                    .font(.callout)
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: RafuMetrics.space2)
                trailing(item)
            }
            .padding(.horizontal, RafuMetrics.space2)
            .padding(.vertical, RafuMetrics.space1)
            .contentShape(.rect)
        }
        .onTapGesture { choose(item) }
        .onHover { hovering in
            if hovering { highlighted = item.id }
        }
    }

    private func moveHighlight(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let currentIndex = highlighted.flatMap { id in filtered.firstIndex { $0.id == id } } ?? 0
        let count = filtered.count
        let newIndex = ((currentIndex + delta) % count + count) % count
        highlighted = filtered[newIndex].id
    }

    private func chooseHighlightedOrFirst() {
        if let highlighted, let item = filtered.first(where: { $0.id == highlighted }) {
            choose(item)
        } else if let first = filtered.first {
            choose(first)
        }
    }

    private func choose(_ item: Item) {
        onSelect(item)
        isPresented = false
        query = ""
    }
}

extension RafuSearchableDropdown where Trailing == EmptyView {
    /// Convenience initializer for callers with no per-row trailing content
    /// (e.g. a status-bar branch switcher trigger).
    init(
        items: [Item],
        text: @escaping (Item) -> String,
        keywords: @escaping (Item) -> [String],
        isCurrent: @escaping (Item) -> Bool,
        onSelect: @escaping (Item) -> Void,
        searchPrompt: String = "Search",
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.init(
            items: items,
            text: text,
            keywords: keywords,
            isCurrent: isCurrent,
            onSelect: onSelect,
            searchPrompt: searchPrompt,
            trailing: { _ in EmptyView() },
            label: label
        )
    }
}
