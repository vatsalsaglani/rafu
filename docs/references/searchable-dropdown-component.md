# RafuSearchableDropdown reusable component

- Applies to: any trigger-button-plus-filterable-popover-list UI (branch
  switchers, and future similar pickers)
- Last verified: Swift 6.2.4, macOS SDK 26.x, 2026-07-19

## Rule or observed behavior

`Sources/RafuApp/Support/RafuSearchableDropdown.swift` provides a generic,
reusable searchable dropdown so future pickers do not reimplement
popover/filter/keyboard-navigation plumbing:

- `RafuSearchableDropdown<Item: Identifiable, Label: View, Trailing: View>`
  is a plain button (`label: () -> Label`) that opens a `.popover` containing
  a filter `TextField`, a scrollable `LazyVStack` of rows (checkmark for the
  current item, `text(item)` title, optional per-row `trailing(item)`
  content), keyboard navigation (`.onKeyPress(.downArrow/.upArrow/.escape)`),
  and a `ScrollViewReader` that scrolls to the highlighted row. `onSubmit` and
  `Return`/click both call `choose(item)`, which invokes `onSelect`, closes
  the popover, and clears the query.
- A `Trailing == EmptyView` convenience initializer exists for callers with
  no per-row trailing content — pass `items`, `text`, `keywords`, `isCurrent`,
  `onSelect`, and `label` only.
- Filtering logic lives in a separate, pure, `nonisolated enum
  RafuDropdownFilter` so it is unit-testable without instantiating SwiftUI:
  `RafuDropdownFilter.matches(query:fields:)` splits `query` on whitespace,
  lowercases every token, and requires **all** tokens to be a substring
  somewhere in `fields.joined(separator: " ").lowercased()` (AND-of-tokens,
  case-insensitive). An empty or all-whitespace query always matches every
  item. `RafuDropdownFilter.filter(_:query:fields:)` applies that predicate
  while preserving the input's original order (no re-sorting/ranking).
  `RafuDropdownFilter.sectioned(_:title:)` groups already-filtered items into
  ordered sections keyed by a title closure, preserving items' relative order
  and sections' first-appearance order — used by the branch dropdown and
  status-bar branch switcher to group Local/Remote branches.
- First shipped consumers: the Source Control branch switcher
  (`GitInspectorView.branchMenu`) and the status-bar branch switcher
  (`WorkspaceStatusBar`, issue #11), both passing `GitBranch` items — the
  component was written generic specifically so the second consumer needed
  no changes to the shared type.

## Why it matters

Before this component, branch-switcher-style pickers were bespoke per call
site. A shared, generic, tested component keeps future pickers (e.g. a
worktree switcher or a theme picker) from re-deriving the same popover
lifecycle, keyboard handling, and filter semantics — and keeps that filter
semantics centrally testable.

## Reproduction or evidence

`Tests/RafuAppTests/RafuSearchableDropdownTests.swift` exercises
`RafuDropdownFilter` directly (multi-token AND matching, case-insensitivity,
empty-query passthrough, order preservation) without touching SwiftUI.

## Verification

```bash
swift build
swift test   # RafuSearchableDropdownTests
./script/format.sh --lint
```

## Related code, ADRs, and phases

- `Sources/RafuApp/Support/RafuSearchableDropdown.swift`
- `Tests/RafuAppTests/RafuSearchableDropdownTests.swift`
- `Sources/RafuApp/Views/GitInspectorView.swift` (`branchMenu`)
- `Sources/RafuApp/Views/WorkspaceStatusBar.swift`
- `Tests/RafuAppTests/StatusBarBranchFormatterTests.swift`
- [`ui-design-language.md`](ui-design-language.md)
- `docs/decisions/0012-flat-workbench-chrome.md`
- `docs/plans/phases/git-experience-and-worktrees.md`
