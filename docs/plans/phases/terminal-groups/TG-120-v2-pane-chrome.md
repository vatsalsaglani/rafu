# TG-120 — Compact colored pane chrome

## Status

Integrated and verified on `main`.

The compact pane header, explicit naming route, color marker, accessible
controls, and close confirmation behavior are covered by the TG-190 audit.

## Branch and worker

- Worker: Luna Implementor
- Branch: `terminal-groups/tg-120-v2-pane-chrome`
- Required base: `<TG110_MERGED_SHA>`
- Execution environment: a coordinator-created Git worktree.

## Goal

Replace the tall Terminal Group pane title area with one compact row. Use the
pane's terminal color in the title chrome, support terminal naming, and replace
the text Close control with an icon-only control.

## Required reading

- `AGENTS.md`
- `docs/decisions/0024-terminal-group-v2-limits-and-pane-metadata.md`
- `docs/plans/phases/terminal-groups/TG-110-v2-runtime-capacity-metadata.md`
- `Sources/RafuApp/Terminal/TerminalGroupView.swift`
- `Sources/RafuApp/Support/RafuTheme.swift`
- `Tests/RafuAppTests/TerminalGroupViewPresentationTests.swift`
- `.agents/skills/swiftui-expert-skill/SKILL.md`
- `.agents/skills/swiftui-expert-skill/references/latest-apis.md`
- `.agents/skills/swiftui-expert-skill/references/accessibility-patterns.md`
- `.agents/skills/swiftui-expert-skill/references/focus-patterns.md`
- the Build macOS Apps `swiftui-patterns` skill and its commands/menus reference

## Exclusive ownership

- `Sources/RafuApp/Terminal/TerminalGroupView.swift`
- `Tests/RafuAppTests/TerminalGroupViewPresentationTests.swift`
- this plan file

## Behavior

1. Use one compact title row near the existing 28-point tab-bar tier. Remove
   the multi-line header expansion.
2. Show the explicit pane name, then the reported title, then `Terminal Pane`.
   Keep status, starting folder, and focus information available to VoiceOver
   and pointer help without making the row tall.
3. Provide an inline pane-name edit route that calls the pane-ID workspace API.
   Use private focus state, select/focus the field when editing starts, commit
   on Return, and cancel on Escape. Empty input clears the explicit name.
4. Render Close as `xmark` only. Use a real `Button`, at least a 22-by-22 hit
   target, help text, and `Close <pane name>` accessibility label. Preserve the
   existing typed close route and last-pane group confirmation.
5. Keep Start and Restart compact and accessible. Do not hide a core action.
6. Tint the title row from the live/snapshot pane color. Use a low-opacity fill
   plus a solid marker or border so normal text remains readable. Color is not
   the only identity or status signal. Work in Indigo, Khadi, Increase Contrast,
   and Reduce Transparency.
7. Keep process, controller, and persistence ownership outside the view.

Tests must pin the compact structure, icon-only controls, name fallback and
edit route, theme-color resolution, accessible labels/help, and textual
status/focus semantics.

## Gates and Goal Mode prompt

Run format fix, format lint, build, `./script/test.sh` in parallel mode, and
`git diff --check`, in that order. Do not edit tracked files after testing.

> Call `create_goal` first with objective "Complete TG-120 from
> `docs/plans/phases/terminal-groups/TG-120-v2-pane-chrome.md`". Confirm a clean
> worktree on `terminal-groups/tg-120-v2-pane-chrome` at exact commit
> `<TG110_MERGED_SHA>` and confirm it is not the primary checkout. Stop without
> edits if false. Read all required skills and files. Edit only owned paths.
> Run the ordered parallel gates, commit, and delete this worktree's `.build`
> last. Do not merge, rebase, or push. Report branch, commit SHA, files, tests,
> accessibility review, risks, and Deviations.
