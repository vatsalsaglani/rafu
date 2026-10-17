# Edit-driven editor gutter index

- Applies to: `EditorGutterRulerView` and `EditorGutterLineIndex`.
- Integration environment: Swift 6.4 (`swiftlang-6.4.0.34.1`), macOS 27.0.1
  (26A434), 2026-10-17. The integrated build and focused regression checks pass.
  Final full-suite results and UI limits are recorded in the repair handoff.
  These checks do not establish a runtime speed gain or release memory budget.

## Rule

One index owns the UTF-16 line starts for one text storage. Line count,
line lookup, gutter drawing, and width use that index. It stores no text.
The ruler observes `NSTextStorage.didProcessEditingNotification` for its
client storage. Character edits update the index. Attribute edits do not.
The notification path reads the storage's `mutableString` proxy, so it does
not first make a full Swift `String` snapshot for a small edit.

The edit range is the **post-edit** range. Subtract `changeInLength` from
its length to get the old range length. Rescan the replacement and one
UTF-16 unit at each edge. Remove old line starts in that window and shift
the later offsets by the edit delta. The offset array still takes work
proportional to the number of later lines when those offsets move. This
change removes repeated document text scans; it does not make each edit
constant time. Combined storage edits can have a broad edited range and
can require a broad scan. Initial setup and an inconsistent edit delta
use a counted full rebuild.

The scanner tests the end of each separator. CR adds a line start only
when the next unit is not LF. LF always adds a line start. This permits
a local scan to start inside an existing CRLF pair. NEL, LINE SEPARATOR,
and PARAGRAPH SEPARATOR also start lines. Vertical tab and form feed do
not. These rules follow Apple's
[NSString line-boundary contract](https://developer.apple.com/documentation/foundation/nsstring/getlinestart(_:end:contentsend:for:)).
An empty buffer has one line. A final separator adds a final empty line.

Width work is combined in one main-queue dispatch. That dispatch must
occur after storage edit processing returns. Do not replace it with an
immediate MainActor call: scroll-view tiling can enter TextKit layout
inside a storage transaction. Only a changed measured width sets
`ruleThickness` and calls `tile()`. The existing classic ruler tiling
override remains in `EditorDropForwardingScrollView`.

`invalidateLineIndex()` and `markLineIndexStale()` remain compatibility
entry points. Normal storage notifications already update the index.
The first method handles explicit load refresh and a missed length
change. The second requests a deferred redraw and width update. Neither
invalidates a valid index. Repeated deferred `updateThickness()` calls
are no-ops after the pending width work is complete.

## Notification selector collision

Use a unique callback name such as `gutterStorageDidProcessEditing(_:)`.
Do not name a private observer callback `textStorageDidProcessEditing(_:)`.
AppKit declares `textStorageDidProcessEditing:` in the deprecated
`NSObject (NSDeprecatedTextStorageDelegateInterface)` category. On an
`NSRulerView` subclass, the latter name becomes an override. The compiler
rejects private access, the missing `override` keyword, and the main-actor
isolation difference from the nonisolated category method.

The coordinator verified this failure in
`/tmp/rafu-repair-20261017/repair-tests-1.log`. The diagnostic identifies
`MacOSX27.0.sdk/System/Library/Frameworks/AppKit.framework/Headers/NSTextStorage.h:201`.
Rename both the method and its `#selector`. Keep the notification handler
on the main actor: this ruler observes the UI-owned storage, whose edits
occur on the main actor. Do not make the callback nonisolated or change
it into a deprecated delegate override to remove the error. The integrated app
build and all nine focused gutter repair tests pass.

## Evidence and checks

The source review found a full width-count scan per edit and a separate
lazy offset rebuild in the next gutter draw. The repair adds independent
Foundation-oracle checks for all supported separators, every replacement
boundary in short CRLF fixtures, Unicode UTF-16 offsets, inverse edits,
combined storage transactions, same-length reloads, native undo and redo,
attribute-only edits, combined width updates, and ruler geometry.

Per-buffer `lineIndexOperations` counters expose full rebuilds,
incremental scans, scanned UTF-16 units in each path, and shifted offsets.
`thicknessUpdateCount` counts consumed width updates;
`thicknessRetileCount` counts explicit width changes that request tiling.
Lookup and draw must not increase scan counters. Inspect these properties
in tests or the debugger. They contain counts only. They are not timing,
memory, or release-performance evidence.

Run after the machine build slot is granted:

```bash
./script/test.sh --filter EditorGutterIncrementalIndexTests
./script/test.sh --filter EditorGutterTilingTests
./script/test.sh --filter gutterRulerLeavesGlyphsVisible
```

The coordinator must also run full parallel and serial tests and the
canonical Rafu Lightning launch. Check line numbers after typing,
paste, undo, and redo at CRLF boundaries; check scroll home and width
changes at 99/100 and 999/1000 lines. Use a second window to check that
one storage's notifications do not change another ruler's index.

## Related code and decisions

- `Sources/RafuApp/Editor/EditorGutterLineIndex.swift`
- `Sources/RafuApp/Editor/EditorGutterRulerView.swift`
- `Tests/RafuAppTests/EditorGutterIncrementalIndexTests.swift`
- [Ruler tiling contract](editor-gutter-ruler-tiling.md)
- [SwiftUI and AppKit boundary](swiftui-appkit-boundary.md)
- `docs/plans/phases/editor-performance-repair.md` (coordinator-owned plan)
- `docs/plans/phases/pre-initial-push-workbench.md`

No ADR changes are needed. This is an internal repair within the current
native editor boundary.
