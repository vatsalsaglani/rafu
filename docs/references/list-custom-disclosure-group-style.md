# A custom `DisclosureGroupStyle` in a `List` gives up the outline — and its keyboard

- **Applies to:** the Files sidebar tree (`RafuFileTreeDisclosureStyle`,
  `FileTreeMetrics`, the multi-folder root sections in
  `WorkspaceRootSection`) and any future `List` that styles its own
  `DisclosureGroup`; also any `ScrollView` using `contentMargins` whose offset
  is read through `ScrollGeometry`.
- **Last verified:** Apple Swift 6.4 (swiftlang-6.4.0.34.1), macOS 27.0.1
  (26A434), on 2026-10-20, on `main` at 3fcc1aa; the outline-crash section on
  `main` at c62d60f.

## Rule or observed behaviour

### A custom style turns the group into ordinary rows

`List` recognises a `DisclosureGroup` only while it uses the system style. Apply
a custom `DisclosureGroupStyle` and the `List` stops treating it as an outline:
the rows become flat rows. That is exactly what the Files tree wants for
layout — fixed 26 pt rows, 14 pt indent, 6 pt selection radius, and indent
guides drawn with a strong segment beside the selected child — but two things
come with it and must be re-implemented by hand:

1. **Keyboard.** The style owns Return, Space, ← and →. Nothing is inherited.
2. **VoiceOver.** The style must publish its own expanded/collapsed state; the
   `List` no longer does it.

Related implementation notes for that tree:

- Depth is passed **through the recursion**, not inferred from the row, because
  the flat rows carry no outline level any more.
- The lazy child load is triggered from a placeholder row's `.onAppear`.

### A default-style group in the same List switches it to NSOutlineView and crashes on collapse

The flat rows hold only while **every** `DisclosureGroup` in the `List` uses
the custom style. One default-style group anywhere in the `List` — here the
multi-folder root sections (`WorkspaceRootSection`) — makes SwiftUI back the
whole `List` with an `NSOutlineView` (`OutlineListCoordinator`) with native
disclosure buttons, the custom-styled folder groups included.

Two symptoms:

1. **Indentation.** The native disclosure button put the root chevron at
   x≈48 and gave every child an extra outline indent (child chevrons at
   x≈90), on top of the indent the rows draw themselves.
2. **Crash (SIGABRT on the main thread).** Collapsing a root that removes
   many hosted rows, after a navigator switch rebuilt the `List`, re-enters a
   row's `NSHostingView.layout` during the outer graph update and fails the
   AttributeGraph precondition "setting value during update". Crash log:
   `RafuLightning-2026-10-20-190421.ips`. Key frames, innermost first:

   ```text
   AG::Graph::value_set            (precondition: setting value during update)
   NSHostingView.render / layout   (a row's hosting view)
   NSView layoutSubtreeIfNeeded
   NSOutlineView _updateDisclosureButtonForRowView
   NSOutlineView setFrameSize
   NSScrollView tile
   ScrollViewHelper.didChangeProperties
   OutlineListCoordinator.applyContext
   ```

**Rule:** a `List` that uses a custom `DisclosureGroupStyle` must style every
group in it, roots and sections included, so the `List` is never an outline.
Put row modifiers (`listRowInsets`, `listRowSeparator`, `listRowBackground`)
on the label, not on the group: the flat style makes the group several rows,
and a modifier on the group reaches every child row. Do not paper over the
crash by deferring the binding write with `Task { @MainActor in }`; remove the
outline instead.

Layout choice for the root sections: the header is a flat 26 pt row with the
tree rows' insets (leading 4, trailing 8; top 4 to separate sections). Its
14 pt chevron cell spans x 4–18 of the row, the column of a depth-0 row's
chevron; the folder icon slot spans 18–34 and the name starts at 38, as a
depth-0 row's name does. With more than one root, a root's direct children
are depth 1: their first indent guide is at x 11, straight down from the root
chevron's centre, and their chevrons span 18–32. A one-folder workspace has
no root header and keeps its rows at depth 0. The whole header row toggles,
so the chevron in it has no tap action of its own (one would toggle twice).

Repro (before the fix): open a workspace with two roots; collapse and expand
the primary root (no crash); open Source Control in the activity rail; return
to Files; collapse the primary root — the app aborts.

**Watch item, not changed:** `AgentHistoryPanelView.swift` (the "All
Projects" section, about line 216) has a default-style `DisclosureGroup` in a
sidebar `List`. That `List` has no custom-styled group, so it is a plain
outline, but it uses the same native outline path; if it ever crashes the same
way, apply the flat style there too.

### `ScrollGeometry.contentOffset` is `−inset` at rest with `contentMargins`

A `ScrollView` that uses `contentMargins` reports a resting
`contentOffset` of **negative the inset**, not `0`. Any "has the user scrolled?"
test — for example showing the tab shelf's leading fade — must compare against
`−inset`, or the affordance is visible before anyone scrolls.

## Why it matters

Both facts fail silently and in a way that reads as a different bug: the tree
looks right but is unreachable by keyboard and mute to VoiceOver, and a
scroll-dependent overlay appears permanently stuck on. A single unstyled
group is worse: it silently brings the outline back for the whole `List`,
which reads as an indentation bug until a collapse aborts the app.

## Reproduction or evidence

- Expand a folder in the Files sidebar and drive it with the keyboard only.
- Turn VoiceOver on and confirm each folder row announces expanded/collapsed.
- Open a workspace with few enough tabs that the shelf does not scroll and
  confirm no leading fade is drawn.
- Outline crash: the repro steps above; after the fix, collapse and expand
  each root many times, with navigator switches between, and confirm the
  root chevron and the children's first guide share a column.
- Source contract: `SidebarTreeAndRailPolishTests` ("Root sections use the
  flat disclosure style so the Files List is never an outline") checks that
  each `DisclosureGroup(` in the Files tree sources has a matching
  `.disclosureGroupStyle(RafuFileTreeDisclosureStyle())`.

## Verification

```bash
./script/build.sh
./script/test.sh
./script/build_and_run.sh --verify
```

## Related code, ADRs, and phases

- `RafuFileTreeDisclosureStyle`, `FileTreeMetrics`, the Files sidebar section
  (`Sources/RafuApp/Views/WorkspaceSidebarView.swift`), `WorkspaceRootSection`
  (`Sources/RafuApp/Views/WorkspacesRootSections.swift`).
- [`multi-folder-workspaces.md`](multi-folder-workspaces.md) (root sections).
- [ADR 0031](../decisions/0031-card-header-tabs-and-themed-chrome.md) §d
- [`scrollview-legacy-scroller-always-setting.md`](scrollview-legacy-scroller-always-setting.md),
  [`ui-design-language.md`](ui-design-language.md),
  [`sidebar-single-click-opening.md`](sidebar-single-click-opening.md)
- Commits on `main`: bfb1710, 349d66f, f094e46, 3fcc1aa.
