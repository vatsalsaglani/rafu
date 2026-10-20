# Test UserDefaults suites

## Applies to

Every test in `Tests/RafuAppTests` that gives code under test its own
`UserDefaults` suite (`suiteName:`, `defaultsSuiteName:`), and the shared
helper `Tests/RafuAppTests/TestDefaultsSuite.swift`.

## Last verified

- Apple Swift 6.4 (swiftlang-6.4.0.34.1), macOS 27.0.1 (26A434), arm64.
- Verified with scratch programs and by counting plists in
  `~/Library/Preferences` before and after a run of the migrated suites.

## Rule

- Make a test suite name with `TestDefaultsSuite.name("<label>")` and clean
  it up with `defer { TestDefaultsSuite.remove(name) }`. Never build a suite
  name as `"dev.rafu.x.\(UUID().uuidString)"`.
- `name(_:)` returns an **absolute path** in a fresh temporary directory.
  CFPreferences stores a path-named suite as `<path>.plist` at that path, so
  the suite never reaches `~/Library/Preferences`.
- `remove(_:)` calls `removePersistentDomain(forName:)` and then deletes the
  suite's own temporary directory. It deletes nothing outside a directory that
  `name(_:)` made (`ownedDirectory(of:)`).
- `TestDefaultsSuiteTests.noBareUUIDSuiteNames` scans `Tests/` and fails on a
  new bare UUID suite name.
- Never clean up by deleting files in `~/Library/Preferences`. It does not
  work (see below), and it can delete a user's real preferences.

## Why it matters

The test runs had left more than 11,000 `<prefix>.<UUID>.plist` files in
`~/Library/Preferences` (for example `dev.rafu.agent-history.<UUID>` and
`dev.rafu.auxiliary-tabs.<UUID>`), and every run added about one per test.

## Observations

1. `removePersistentDomain(forName:)` empties the domain but leaves a 42-byte
   empty plist. Most of the leaked files were these.
2. Files of about 500 bytes held `dev.rafu.last-workspace.v1`: a debounced
   workspace save (`persistWorkspaceState`, 200 ms) landed **after** the
   test's `removePersistentDomain` and wrote the domain again.
3. Deleting the plist from the test process does not stick. cfprefsd wrote
   the empty plist back seconds later, after the process had exited, even
   when the delete ran in an `atexit` handler.
4. An absolute-path suite name works with `UserDefaults(suiteName:)`: values
   read back, `removePersistentDomain` empties it, and the plist is in the
   temporary directory.

## Evidence and verification

```bash
ls ~/Library/Preferences | grep -cE "auxiliary-tabs|agent-history|UsageStoreTests|navigation-repair"
swift test --filter "WorkspaceAuxiliaryTabTests|AgentHistoryTabTests|UsageStoreTests|WorkspaceNavigationRestorationRepairTests"
ls ~/Library/Preferences | grep -cE "auxiliary-tabs|agent-history|UsageStoreTests|navigation-repair"
swift test --filter TestDefaultsSuiteTests
```

The count was 3,934 before and after the migrated suites ran. The existing
leaked files were not deleted; removing them is the user's choice.

## Still open

Some tests write to the test runner's standard domain
(`~/Library/Preferences/swiftpm-testing-helper.plist`): keys
`dev.rafu.last-workspace.v1`, `dev.rafu.recent-workspaces.v1` and
`canvasEmptyBoardTipDismissed`. Code under test that falls back to
`UserDefaults.standard` needs an injected suite to stop this.

Tests that pass `TestDefaultsSuite.name(_:)` inline and never call
`remove(_:)` (several Canvas session helpers) leave one small
`rafu-test-defaults-<UUID>` directory in the temporary directory per test.
That is outside `~/Library/Preferences` and the system clears it, but a
`remove` in their teardown would be tidier.

## Related

- `Tests/RafuAppTests/TestDefaultsSuite.swift`
- `Tests/RafuAppTests/TestDefaultsSuiteTests.swift`
- [`test-keychain-isolation.md`](test-keychain-isolation.md) (the same
  isolation rule for the Keychain)
