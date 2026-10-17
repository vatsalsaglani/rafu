# Documentation hover timing and lifetime

- Applies to: native editor documentation hover and diff documentation hover.
- Last verified: Swift 6.4, macOS 27.0.1, 2026-10-17. Scheduler, hidden-editor,
  scroll-cancellation, and editor-lifetime tests passed. The canonical app
  launched. Live server latency was not measured.

## Rule and reason

Documentation hover waits 150 ms before asking the existing navigation provider.
The editor identifies a target by its UTF-16 identifier range. Pointer motion
inside that range must not restart the delay or send another request. The diff
surface uses the same delay. The blame card keeps its separate 450 ms delay.

`EditorHoverRequestScheduler` keeps one task and a generation number. It checks
cancellation and generation after the delay and after the server response. It
holds itself weakly across the response wait; presentation holds the text view
weakly. A declined response can retry on a later pointer event. No documentation
payload cache, language-server startup, or new network transmission is added.

Cancel on leaving the identifier, editor hiding, scrolling, editing, keystrokes,
clicks, and teardown. Bounds observation must start while the request is pending,
not only after a popover appears. A retained editor can be hidden without being
destroyed, so deinitialization alone is not a sufficient cancellation boundary.
A hidden host also releases its own first responder. It must not resign a field
in another pane or an auxiliary tab.

## Evidence and verification

The old editor delay was 450 ms and each mouse movement cancelled and restarted
it. The diff delay was 350 ms. Source review also found that scroll observation
started only after presentation and hidden hosts did not cancel pending hover.
The new tests control response completion explicitly; a late, non-cooperative
response must not present after a newer target, hiding, or scrolling.

```sh
./script/test.sh --filter 'EditorHoverRequestSchedulerTests|EditorHiddenInteractionTests'
./script/test.sh --filter 'Hover|IdentifierUnderCaret|EditorLifetimeRepairTests'
./script/build_and_run.sh --verify
```

A live language server can add latency after the 150 ms delay. Check a known
symbol in an already running, trusted server to assess that latency. Do not log
hover payloads or start a server without the user's explicit action.

## Related

- `Editor/EditorHoverRequestScheduler.swift`, `Editor/RafuTextView.swift`
- `Editor/CodeEditorView.swift`, `Views/EditorCanvasView.swift`
- `Tests/RafuAppTests/EditorHoverRequestSchedulerTests.swift`
- `Tests/RafuAppTests/EditorHiddenInteractionTests.swift`
- [ADR 0005](../decisions/0005-language-intelligence-and-lsp.md)
- [Language intelligence phase](../plans/phases/language-intelligence.md)
- [Editor repair phase](../plans/phases/editor-performance-repair.md)
