# SwiftUI file importer single-owner rule

- Applies to: macOS windows with more than one file or directory picking intent
- Last verified: Apple Swift 6.3.3, macOS 26.5.2, 2026-08-17

## Rule or observed behavior

Mount only one SwiftUI `.fileImporter` presentation host in one window modifier
chain. On macOS 26, a later importer can shadow an earlier importer even while
the later importer's binding is false. Setting the earlier binding to true then
changes model state but presents no panel.

Use one importer that routes all intents, or keep a separate imperative action
behind a small `NSOpenPanel` helper. Rafu uses the second shape: workspace-open
actions use `WorkspaceFolderPicker`, while the one remaining `.fileImporter`
owns Terminal Pane starting-folder selection.

## Why it matters

The welcome button, File menu item, keyboard shortcut, and command-palette item
all call `WorkspaceSession.requestOpenFolder()`. The shared action was correct,
but its importer was shadowed by the later Terminal Group importer. Both the
button and menu therefore appeared enabled and did nothing visible.

## Reproduction or evidence

1. Mount two `.fileImporter` modifiers on `WorkspaceWindowPresentations`.
2. Bind the first to workspace-open state and the second to Terminal Pane state.
3. Start Rafu Lightning without a workspace.
4. Click **Open Folder…** or choose **File > Open Folder…**.
5. The workspace binding becomes true, but no picker appears.

The regression test pins one SwiftUI importer owner and checks the native
workspace panel's directory-only configuration.

## Verification

```sh
./script/test.sh --skip-update --filter WorkspaceFolderPickerTests
./script/format.sh --lint
./script/build.sh
./script/test.sh
./script/build_and_run.sh --verify
```

After launch, verify that the welcome button and `Command-O` each open the
directory picker. Cancel each panel before testing the next route.

## Related code, ADRs, and phases

- [`WorkspaceFolderPicker.swift`](../../Sources/RafuApp/Services/WorkspaceFolderPicker.swift)
- [`WorkspaceSession.swift`](../../Sources/RafuApp/Models/WorkspaceSession.swift)
- [`WorkspaceWindowView.swift`](../../Sources/RafuApp/Views/WorkspaceWindowView.swift)
- [`pre-initial-push-workbench.md`](../plans/phases/pre-initial-push-workbench.md)
- [ADR 0002](../decisions/0002-native-workbench-navigation.md)
