# Sidebar file opening

- Applies to: the Files Navigator in `WorkspaceSidebarView.swift`.
- Last source check: 2026-10-17, Swift 6.4, macOS 27.0.1 (26A434).
- Runtime verification: canonical Rafu Lightning launch and single-click file
  opening passed on 2026-10-17. Reopening an existing file, file-tab switching,
  second-window state, folder disclosure, nested file opening, and the file
  context menu were checked. Folder drag and keyboard-only sidebar activation
  remain manual checks.

## Rule

A file row is a plain native SwiftUI `Button`. One click, keyboard button
activation, or an accessibility activation calls the existing `session.open`.
An open file uses the same document, including its dirty text. A folder row
keeps its `DisclosureGroup`, selection gesture, lazy child loading, and drop
handling. File and folder context menus and drag providers stay on the row.

Keep opening attached to an explicit row action. Do not open a file from an
`onChange` observer of `selectedTreePath`. Editor selection and
`revealInSidebar` also set this path. An observer would turn a programmatic
reveal into another editor action. This can change the selected editor or its
focus without a file-row action.

Selection remains drawn per row. The existing list has no native selection
binding because a selected file below a collapsed folder previously caused a
phantom selection highlight. This change does not replace that policy.

## Evidence and checks

`WorkspaceSidebarSingleClickTests` checks one-action opening, repeated opening
with dirty text, folder selection with an open editor, and separate window
state. These tests exercise the row action. They do not prove pointer handling,
keyboard reachability, accessibility behavior, or drag handling.

The coordinator runs:

```sh
./script/test.sh --filter WorkspaceSidebarSingleClickTests
./script/build_and_run.sh --verify
```

In Rafu Lightning, click a file once. Select another tab and click the open
file again. Check folder disclosure, a file context menu, file dragging, and
keyboard activation. Reveal a folder from a breadcrumb and select a file tab;
check that this does not cause another file to open. Check a second window.

Related: [ADR 0002](../decisions/0002-native-workbench-navigation.md),
[editor repair phase](../plans/phases/editor-performance-repair.md), and
[pre-initial-push workbench](../plans/phases/pre-initial-push-workbench.md).
