# A custom `DisclosureGroupStyle` in a `List` gives up the outline — and its keyboard

- **Applies to:** the Files sidebar tree (`RafuFileTreeDisclosureStyle`,
  `FileTreeMetrics`) and any future `List` that styles its own
  `DisclosureGroup`; also any `ScrollView` using `contentMargins` whose offset
  is read through `ScrollGeometry`.
- **Last verified:** Apple Swift 6.4 (swiftlang-6.4.0.34.1), macOS 27.0.1
  (26A434), on 2026-10-20, on `main` at 3fcc1aa.

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

### `ScrollGeometry.contentOffset` is `−inset` at rest with `contentMargins`

A `ScrollView` that uses `contentMargins` reports a resting
`contentOffset` of **negative the inset**, not `0`. Any "has the user scrolled?"
test — for example showing the tab shelf's leading fade — must compare against
`−inset`, or the affordance is visible before anyone scrolls.

## Why it matters

Both facts fail silently and in a way that reads as a different bug: the tree
looks right but is unreachable by keyboard and mute to VoiceOver, and a
scroll-dependent overlay appears permanently stuck on.

## Reproduction or evidence

- Expand a folder in the Files sidebar and drive it with the keyboard only.
- Turn VoiceOver on and confirm each folder row announces expanded/collapsed.
- Open a workspace with few enough tabs that the shelf does not scroll and
  confirm no leading fade is drawn.

## Verification

```bash
./script/build.sh
./script/test.sh
./script/build_and_run.sh --verify
```

## Related code, ADRs, and phases

- `RafuFileTreeDisclosureStyle`, `FileTreeMetrics`, the Files sidebar section.
- [ADR 0031](../decisions/0031-card-header-tabs-and-themed-chrome.md) §d
- [`scrollview-legacy-scroller-always-setting.md`](scrollview-legacy-scroller-always-setting.md),
  [`ui-design-language.md`](ui-design-language.md),
  [`sidebar-single-click-opening.md`](sidebar-single-click-opening.md)
- Commits on `main`: bfb1710, 349d66f, f094e46, 3fcc1aa.
