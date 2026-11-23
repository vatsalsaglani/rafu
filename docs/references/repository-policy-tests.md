# Repository policy tests and package merge traps

- Applies to: the source-scan tests that fail a build when new code uses a banned API or name, two Swift Testing
  compile traps, and the duplicate type name check after a merge of parallel packages. Found while building Meetings
  version 1 (the Meetings phase, [`meetings.md`](../plans/phases/meetings.md)).
- Last verified: 2026-11-23, during the Meetings build. The handoff does not state the Swift or Xcode version of
  the compile traps (see "Verification").

## Rule or observed behavior

### Source rules that a test enforces

A new file in `Sources/RafuApp` fails a test when it does one of these. Use the right column.

| Banned | Use | Test that enforces it |
|---|---|---|
| `.alert(` and `.confirmationDialog(` (also `NSAlert(` and `alert.runModal()`, allowed only in the no-window fallback of `RafuPopupPresenter.swift`) | `RafuConfirmPopup` inside `.sheet(item:)` | `RafuDialogPolicyTests` (the decision about the Rafu popup language, [ADR 0033](../decisions/0033-rafu-popup-language.md)) |
| `.pickerStyle(.segmented)` | `RafuSegmentedPicker` | `ThemedControlStyleScanTests` |
| `.environment(\.rafuTheme, …)` | `.rafuTheme(_:)` | `ThemedControlStyleScanTests` |
| A folder name built as `appending(path: "Rafu…`, `appendingPathComponent("Rafu…` or `Application Support/Rafu` | `RafuAppIdentity.applicationSupportRoot` (`Sources/RafuCore/RafuAppIdentity.swift`) | `AppSupportRootTests.sourceGuard` (it scans `Sources/` only, not `Tests/`) |
| In a test: a defaults suite name built from a `UUID` | `TestDefaultsSuite.name(_:)` | the scan test in [`test-defaults-suites.md`](test-defaults-suites.md) |

Facts about the popup components:

- `RafuConfirmPopup` does not close itself. The caller must dismiss the sheet.
- Its cancel button is always "Cancel". A caller cannot set another label for it.
- For one text field, use `RafuTextFieldPopup`.

### Swift Testing compile traps

- `@available(macOS 26, *)` is not accepted on a `@Suite` type. Put it on each `@Test` function.
- `#expect(x.allSatisfy(\.someKeyPath))` does not compile. Bind the result to a `let` first, then
  `#expect(result)`. A closure also works: `allSatisfy { $0.flag }` (the macro turns the key path into a call that can
  rethrow). Met again 2026-11-23 in the echo-flag tests.

### Duplicate type names after a merge

Two packages that ran in parallel each declared a top-level type `MeetingsListRow`. Each package built alone. The
merged tree did not build.

- Rule for a fan-out: prefix each new type name with the name of the package area (for example the Meetings library
  area, not a bare `ListRow`).
- The coordinator checks for duplicate top-level type names after each merge, before the first build of the merged
  tree.

## Why it matters

- A banned API in a new file shows as a test failure far from the cause. The right column gives the fix at once.
- The duplicate name error appears only after the merge. A worktree build cannot show it.

## Reproduction or evidence

- The rules were hit while the Meetings packages were built. The scan tests are in
  `Tests/RafuAppTests/RafuDialogPolicyTests.swift`, `Tests/RafuAppTests/AppSupportRootTests.swift` and
  `Tests/RafuAppTests/ThemedControlStyleScanTests.swift`.
- The duplicate `MeetingsListRow` was found when the Meetings integration merged the packages.

## Verification

```bash
swift test --filter "RafuDialogPolicyTests|AppSupportRootTests|ThemedControlStyleScanTests"
```

Open: the handoff did not give the compiler version or the test count for the compile traps.

## Related code, ADRs, and phases

- [`test-defaults-suites.md`](test-defaults-suites.md), [`test-source-policy-and-bookmark-isolation.md`](test-source-policy-and-bookmark-isolation.md),
  [`ui-design-language.md`](ui-design-language.md).
- [ADR 0033](../decisions/0033-rafu-popup-language.md).
- [`meetings.md`](../plans/phases/meetings.md).
