# Line-manipulation shortcuts (move, duplicate, delete)

- **Applies to:** `RafuTextView.keyDown(with:)` dispatch, `EditorTextEditingSupport` line operations, `EditorDocument` undo integration
- **Last verified:** Swift 6.2, macOS 26, 2026-07-24

## Rule or observed behavior

Line-manipulation shortcuts are split into two registration paths based on whether they conflict with global text-navigation keys:

- **Option+↑ and Option+↓ (move line up/down) and Shift+Option+↑/↓ (duplicate line)** are dispatched EXCLUSIVELY from `RafuTextView.keyDown(with:)`, NEVER registered as SwiftUI `.keyboardShortcut` menu equivalents. **Why:** A global menu key-equivalent is matched by AppKit before the first responder (the text view) sees the key event; plain Option+arrow is standard paragraph-navigation in every `NSTextView`, `NSTextField`, and `UITextField` (including Rafu's embedded command palette, find bar, settings panels, and SwiftTerm terminal), so a global equivalent would hijack those keys app-wide and make paragraph navigation inaccessible in those contexts. Mirrors the precedent established at `RafuAppCommands.swift:232–236` (multi-caret commands routed through the text view's first-responder path).

- **⌘⇧K (delete line)** IS safe as a global menu equivalent and is registered normally, because ⌘⇧K is not a standard text-navigation sequence and does not conflict with existing AppKit text shortcuts.

**Discoverability tradeoff:** Move and Duplicate have menu items in the Edit menu but WITHOUT a displayed key-equivalent glyph (the `⌥↑` visual hint), because showing the glyph requires registering the interfering global equivalent. This tradeoff is accepted and intentional — the commands remain discoverable via the menu; keyboard-first users can find them via Command-Palette or by inspecting the menu.

## Line-edit batching and CRLF behavior

- A single `textStorage.replaceCharacters(in:with:)` followed by `didChangeText()` yields exactly ONE undo step and requires NO explicit `beginUndoGrouping()`/`endUndoGrouping()` — the text storage's implicit grouping is sufficient. (Contrast the multi-caret editing path, which does call `beginUndoGrouping()` explicitly before a batch of N-substitutions.)

- Line transforms (line start, line end, contents length) are computed from `NSString.getLineStart(_:end:contentsEnd:for:)`, which Foundation treats `\n`, `\r`, and `\r\n` as equivalent single-line terminators. Therefore CRLF line endings round-trip through move/duplicate/delete operations correctly with **no special-casing**. This improves on the pre-implementation anticipated limitation ("known bug: CRLF may not survive").

## Scope constraints and future work

- **Multi-caret line moves are an intentional non-goal this pass.** The implementation includes an `!hasMultipleCarets` guard that falls through to `super` (doing nothing) when more than one caret is active. This is a deliberate defer, noted for a future phase.

- **Future shortcuts identified during implementation:**
  - Cmd+Enter: insert new line (below current)
  - ⌘]: indent (increase indent)
  - ⌘[: outdent (decrease indent)
  These were prototyped but not landed to keep this pass scoped; they are captured as follow-up.

- **First-line edge case:** consuming Option+Up at the first line of the document suppresses the otherwise-standard paragraph-navigation behavior (AppKit would normally navigate out of the editor). This is intentional, matching VS Code behavior; it is recorded as a behavior change, not a bug.

## Why it matters

Line-editing is a foundational editor workflow; these shortcuts are present in every major text editor and agent interface (Claude Code, VS Code, etc.). Implementing them correctly requires understanding the tension between registration paths (first responder vs. global menu) and how global equivalents silently hijack other UI contexts. The CRLF correctness matters for cross-platform repositories where line endings may be mixed or preserve machine-native styles.

## Reproduction or evidence

- Unit tests for line move, duplicate, and delete across various edge cases: empty lines, line selections, caret at line start/middle/end, first/middle/last lines, CRLF line endings.
- Single-undo-step verification: an undo after a line move/duplicate/delete restores the original state in one step (not N steps).
- CRLF preservation test: a document with mixed CRLF/LF endings; move a CRLF line and verify no conversion occurs.

## Verification

```bash
swift build
swift test --filter LineEdit
swift test --filter LineManipulation
swift test
./script/format.sh --lint
./script/build_and_run.sh --verify
```

`swift test`: 1294 tests passing, 0 build warnings. `./script/format.sh --lint`: clean. `./script/build_and_run.sh --verify`: app launches successfully.

## Related code, ADRs, and phases

- `Sources/RafuApp/Editor/EditorTextEditingSupport.swift` — `LineEdit`, `LineManipulation` types and move/duplicate/delete logic
- `Sources/RafuApp/Editor/RafuTextView.swift` — `keyDown(with:)` dispatch for Option+arrow and Shift+Option+arrow
- `Sources/RafuApp/Editor/EditorDocument.swift` — action closures for line operations
- `Sources/RafuApp/Views/CodeEditorView.swift` — wiring
- `Sources/RafuApp/Models/WorkspaceSession.swift` — command forwarders
- `Sources/RafuApp/App/RafuAppCommands.swift` — menu items and keyboard-shortcut routing precedent (multi-caret commands)
- `Tests/RafuAppTests/*LineEdit*.swift` — 17 focused tests
- [`swiftui-appkit-boundary.md`](swiftui-appkit-boundary.md) — text-view keyboard routing patterns
- [`multi-caret-editing.md`](multi-caret-editing.md) — undo grouping patterns (contrast)
- `docs/plans/phases/pre-initial-push-workbench.md` — active phase
