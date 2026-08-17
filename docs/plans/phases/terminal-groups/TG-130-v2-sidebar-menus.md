# TG-130 — Terminal Manager three-dot menus

## Status

Integrated and verified on `main`.

The group and pane three-dot menus, pane-ID metadata routes, and legacy
standalone-terminal routes are covered by the TG-190 audit.

## Implementation record

- Commit: `b3bfe1c10e9476615cf026cd79d7c7d6cc9acfc8`
- Files: `Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift`,
  `Tests/RafuAppTests/TerminalManagerPresentationTests.swift`
- Validation: format fix, format lint, build, 2,145 parallel tests in 117
  suites, and `git diff --check` passed.
- Accessibility: group and pane menus use icon-only ellipsis controls with
  22-by-22 hit areas, hidden indicators, help text, and explicit labels.
- Security: pane actions use bounded `TerminalPaneID` metadata routes. No
  process, command, credential, or environment data is added.
- Deviations: none. Existing fixture and compiler warnings remain documented
  by the test and build output.

## Branch and worker

- Worker: Luna Implementor
- Branch: `terminal-groups/tg-130-v2-sidebar-menus`
- Required base: `<TG110_MERGED_SHA>`
- Execution environment: a coordinator-created Git worktree.

## Goal

Remove the visible `Terminal Group actions` and `Pane actions` labels from the
Terminal Manager sidebar. Keep one compact three-dot menu for each group and
each pane. Route pane Rename and Color through the pane-ID Terminal Group API.

## Required reading

- `AGENTS.md`
- `docs/plans/phases/terminal-groups/TG-110-v2-runtime-capacity-metadata.md`
- `Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift`
- `Tests/RafuAppTests/TerminalGroupManagerHierarchyTests.swift`
- `Tests/RafuAppTests/TerminalManagerPresentationTests.swift`
- `.agents/skills/swiftui-expert-skill/SKILL.md`
- `.agents/skills/swiftui-expert-skill/references/latest-apis.md`
- `.agents/skills/swiftui-expert-skill/references/accessibility-patterns.md`
- the Build macOS Apps `swiftui-patterns` skill and its commands/menus reference

## Exclusive ownership

- `Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift`
- `Tests/RafuAppTests/TerminalGroupManagerHierarchyTests.swift`
- `Tests/RafuAppTests/TerminalManagerPresentationTests.swift`
- this plan file

## Behavior

1. Reuse the legacy terminal row's icon-only ellipsis `Menu` pattern for group
   and pane rows: closure label, 22-by-22 hit frame, borderless menu style,
   hidden indicator, fixed size, help, and explicit accessibility label.
2. Remove only the visible `Terminal Group actions` and `Pane actions` text.
   Keep all existing menu item labels and typed action routes.
3. Use `Actions for <group>` and `Actions for <pane>` as accessibility labels.
4. Route pane Rename and theme Color by exact `TerminalPaneID`, not legacy
   session ID. This must work for live, stopped, and unavailable panes. Keep
   legacy standalone-terminal actions unchanged.
5. Preserve keyboard reachability, Full Keyboard Access, VoiceOver actions,
   reveal behavior, group rename focus, and narrow-sidebar layout.

Tests must assert icon-only source structure, hidden menu indicators, explicit
help/accessibility labels, exact pane-ID routing, and unchanged group/pane menu
actions.

## Gates and Goal Mode prompt

Run format fix, format lint, build, `./script/test.sh` in parallel mode, and
`git diff --check`, in that order. Do not edit tracked files after testing.

> Call `create_goal` first with objective "Complete TG-130 from
> `docs/plans/phases/terminal-groups/TG-130-v2-sidebar-menus.md`". Confirm a
> clean worktree on `terminal-groups/tg-130-v2-sidebar-menus` at exact commit
> `<TG110_MERGED_SHA>` and confirm it is not the primary checkout. Stop without
> edits if false. Read all required skills and files. Edit only owned paths.
> Run the ordered parallel gates, commit, and delete this worktree's `.build`
> last. Do not merge, rebase, or push. Report branch, commit SHA, files, tests,
> accessibility review, risks, and Deviations.
