# Source Control commit composer (Option B)

- Applies to: `Sources/RafuApp/Views/GitCommitComposerView.swift`,
  `Sources/RafuApp/Git/GitPanelPresentation.swift` (`GitCommitMessageParts`,
  `GitCommitComposerPresentation`, `GitCommitMenuAvailability`),
  `Sources/RafuApp/Git/WorkspaceSession+CommitComposer.swift`,
  `Sources/RafuApp/App/RafuAppCommands.swift` (Commit, Stage All, Draft Message
  with AI; `FocusedValues.commitComposerFocused`),
  `RafuProminentButtonStyle(quietWhenDisabled:)` in
  `Sources/RafuApp/Support/RafuControlStyles.swift`, and the Changes section
  header in `Sources/RafuApp/Views/GitInspectorView.swift`.
- Last verified: 2026-11-15. The toolchain and OS versions were not in the
  handoff. Merged as 9bca274 (composer) and 3a97c54 (⌘Return gating), merge
  0977337. No GUI check was done: the user asked for tests only and no app
  launch. Main gate on merge 0977337: 529 tests in 40 suites and 3927 tests in 319 suites passed in parallel and `--no-parallel` (Apple Swift 6.4.2, macOS 27.2).

## Rule or observed behavior

The user chose Option B from a three-option design proposal (A: flush field and
fixed controls; B: summary and description with one named button; C: compact
bar with a split button). The proposal had recommended A.

### Anatomy

- No card. The composer paints no surface. One top hairline separates it from
  the list (`borderSubtle`; `borderStrong` under Increase Contrast). In Solid the
  sidebar token shows through; in Frosted the window backdrop does.
- One opaque `fieldBackground` field through `rafuField`, the same chrome as the
  Search field. No new ADR 0038 rule: a translucent field fill was not chosen.
- Summary line: semibold, one line, the trimmed character count, and the AI
  button (sparkles; Stop with a mini spinner while drafting). The count turns to
  `warning` with a triangle glyph above 72 characters
  (`GitCommitComposerPresentation.summaryLengthLimit`). It never blocks Commit.
  The count is the Summary field's accessibility value, not a separate element.
  It is hidden while drafting.
- Description: a second `TextField` (2 to 6 lines) under a hairline inside the
  same field. It shows when the summary has text, the description has text or
  focus, or a draft runs.
- One full-width button names the next step. Its title is never truncated; the
  "to <branch>" suffix truncates in the middle first.

| State | Button | Style |
|---|---|---|
| Nothing staged, changes exist | Stage All N Files | secondary |
| Staged N, summary typed | Commit N Files to <branch> | prominent |
| Merge in progress | Commit Merge to <branch> (also with no file changes) | prominent |
| Nothing staged, no merge, no changes to stage | Nothing to Commit | prominent, quiet-disabled |
| Drafting | Drafting… | prominent, quiet-disabled |

A detached HEAD has no suffix. The disabled reason is the tooltip and the
accessibility hint: "Stage files to commit.", "Write a summary to commit.",
"Wait for the draft to finish, or stop it.", or "Wait for the current Git
operation to finish."

- Visibility: the composer is hidden on a clean tree unless a message is typed,
  a merge is in progress, or a draft runs. A typed message never disappears. The
  view keeps an empty stack on a clean tree so `onChange` of
  `isGeneratingAICommitMessage` still announces a draft started from the menu.
- Partly staged tree: the button names Commit, so a small "Stage All" appears in
  the Changes section header (`showsSectionStageAll`).
- AI error: the `error`-coloured label plus "Open AI Settings…" (routes through
  `SettingsPaneRouter.shared.request(.ai)` then `openSettings()`). The link shows
  for every AI error, because `aiCommitGenerationError` is a `String`, not a
  typed cause.
- VoiceOver announcements (`AccessibilityNotification.Announcement`): "Drafting
  commit message", "Commit message drafted", "Draft stopped" (Stop sets a local
  flag), "Draft failed: <error>".
- The drafting border is on the field with `RafuMetrics.radiusField` (it was the
  12 pt panel radius on a 6 pt card).
- The prominent button style has an opt-in `quietWhenDisabled` (default false,
  so sheets keep their look). A disabled button draws the neutral chip fill, a
  hairline and a `textMuted` label, not the accent at 40 %, so "disabled" does
  not read as "attention".

### One string, two fields

`WorkspaceSession.gitCommitMessage` stays one string. `GitCommitMessageParts`
splits and joins it:

- Summary is the first line. The description is the rest after one blank-line
  separator. A description with no blank line before it (an AI draft can stream
  that way) is still the rest.
- Only one blank line is the separator. More blank lines belong to the
  description, so `join(split(m))` keeps them.
- CRLF reads as LF. Trailing spaces are kept in both parts, so a word gap typed
  at the end of the summary is not lost.
- A pasted multi-line summary moves its extra lines into the description on the
  next split.
- While an AI draft streams, the draft owns the whole message: each delta
  replaces it. Stop keeps what arrived.

### Menu path and the ⌘Return rule

The three actions have menu items in the app-named command menu
(`CommandMenu(RafuApplication.displayName)`), after the Voice Companion items.
The composer's buttons carry no key equivalent, so each key is registered once.

- Commit: ⌘Return, but only while all three hold: a commit is possible
  (`GitCommitMenuAvailability.canCommit`), a commit message field has focus
  (`FocusedValues.commitComposerFocused`, set by the composer while either part
  is focused), and no Ensemble note is in Edit mode (`canvasNoteEditing`; the
  Format menu's Done Editing uses ⌘Return then). Otherwise the item has no key
  and stays in the menu, enabled when a commit is possible.
- Why: the first implementation (9bca274) put ⌘Return on the Commit item
  window-wide. A window-wide ⌘Return could commit from a terminal, so the
  coordinator added the focus gate in 3a97c54. A terminal, the editor or a note
  never commits on ⌘Return.
- Stage All: enabled only with something to stage and no Git or hunk operation in
  flight (`canStageAll`). It was enabled with nothing to stage before.
- Draft Message with AI: ⌥⌘G, window-wide, disabled while Git is busy or when
  generation is not available.
- The enabled Commit button tooltip reads "(⌘Return)", although the key is
  active only under the rule above (a field must have focus).

## Why it matters

- A menu item key is window-wide. A `.keyboardShortcut` on a menu item for an
  action that belongs to one panel needs a focus or state gate, or the key acts
  from other panels (a terminal, here).
- A single message string must stay the only model. Two stored strings would
  break AI streaming, the merge default message and the clear after commit.
- The hidden-on-clean-tree rule means the draft announcement works only while
  the Changes tab is in the view tree.

## Reproduction or evidence

- Tests: suite "Git commit composer presentation" (23 tests) in
  `Tests/RafuAppTests/GitPanelPresentationTests.swift`. It covers the split and
  join round trips, CRLF, trailing spaces, AI streaming into summary then
  description, the show rule, each button state and title, the counter, the
  section Stage All, and the menu availability, including "Command-Return stays
  with an Ensemble note in Edit mode".
- `UtilityPanelPresentationTests`: the source scan is inverted. It now forbids
  the old composer card.
- The 23 tests ran in both modes on `main` (merge 0977337): 529 tests in 40
  suites and 3927 tests in 319 suites passed, parallel and `--no-parallel`.
- Not done: any GUI check.

## Verification

```bash
swift test --filter "Git commit composer presentation"
swift test --filter UtilityPanelPresentationTests
./script/build_and_run.sh --verify
```

GUI checks owed (Rafu Lightning only): clean tree; changes with nothing staged;
staged with a message; ⌘Return from the field and from the menu, and ⌘Return in
a terminal does nothing; ⌥⌘G, Stop, and a draft with no provider ("Open AI
Settings…"); merge in progress; a hygiene finding; Indigo and Khadi; Solid and
Frosted; Reduce Transparency; Increase Contrast (hairline); Reduce Motion (static
drafting border); VoiceOver through the composer and the four announcements; Full
Keyboard Access Tab order; minimum sidebar width and a long branch name; a second
window with a different message.

## Open questions

- Return in an empty summary may not move focus to the description, because the
  description is not shown yet (`onSubmit` sets `focusedPart = .description`
  before the field exists). Not checked on screen.
- A draft started from the menu while the Changes tab is not shown is not
  announced, because the composer view is not in the tree.
- The view comment on the Draft button says "Source Control > Draft Message with
  AI". The items are in the app-named menu, not a Source Control menu.

## Related code, ADRs, and phases

- [`ui-design-language.md`](ui-design-language.md) (composer anatomy,
  `quietWhenDisabled`), [`sidebar-panel-anatomy-and-terminal-rows.md`](sidebar-panel-anatomy-and-terminal-rows.md)
  (sidebar rules the composer follows),
  [`command-palette-and-search-pitfalls.md`](command-palette-and-search-pitfalls.md)
  (other ⌘↩ owners), [`ai-provider-rest-contracts.md`](ai-provider-rest-contracts.md)
  (commit generation).
- [ADR 0002](../decisions/0002-native-workbench-navigation.md) (Source Control
  navigator; it does not fix the composer layout, so no amendment),
  [ADR 0038](../decisions/0038-optional-frosted-window-base.md) (opaque field, no
  new rule), [ADR 0013](../decisions/0013-git-experience-scope.md).
- Phase: [`git-experience-and-worktrees.md`](../plans/phases/git-experience-and-worktrees.md)
  (GX5 composer card, now superseded) and
  [`workbench-presentation-upgrade.md`](../plans/phases/workbench-presentation-upgrade.md)
  (work log 2026-11-15).
