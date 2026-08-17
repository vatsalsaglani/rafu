# TG-190 — Terminal Groups v2 integration and release gate

## Status

Planned.

## Branch and worker

- Worker: Luna Implementor
- Branch: `terminal-groups/tg-190-v2-integration-release`
- Required base: `<TG120_TG130_MERGED_SHA>`
- Execution environment: a coordinator-created Git worktree.

## Goal

Audit the integrated Terminal Groups v2 behavior, add only missing regression
coverage, and close the v2 documentation. This lane does not push or create a
release branch. The coordinator owns those external actions.

## Required reading

- `AGENTS.md`
- ADRs 0018, 0023, and 0024
- `docs/plans/phases/terminal-groups.md`
- `docs/plans/phases/terminal-groups/README.md`
- `docs/plans/phases/terminal-groups/manifest.md`
- TG-100, TG-110, TG-120, and TG-130
- all production and test files owned by those four plans
- `.agents/skills/swift-concurrency-pro/SKILL.md`
- `.agents/skills/swiftui-expert-skill/SKILL.md`
- the Build macOS Apps `build-run-debug` skill

## Exclusive ownership

- `Tests/RafuAppTests/TerminalGroupsV2EndToEndTests.swift`
- `docs/plans/phases/terminal-groups/README.md`
- `docs/plans/phases/terminal-groups/manifest.md`
- `docs/plans/phases/terminal-groups/TG-100-v2-contracts.md`
- `docs/plans/phases/terminal-groups/TG-110-v2-runtime-capacity-metadata.md`
- `docs/plans/phases/terminal-groups/TG-120-v2-pane-chrome.md`
- `docs/plans/phases/terminal-groups/TG-130-v2-sidebar-menus.md`
- this plan file

Production corrections are not pre-authorized. If the audit finds one, stop
and report its exact file, cause, risk, and proposed owner to the coordinator.

## Integrated proof

1. Prove 20 groups, 10 panes per group, 200 retained panes, and 200 live slots
   use separate gates. Prove all 21st/11th/201st failures are typed and atomic.
2. Prove ordinary, saved, restored, Agent, and Ensemble paths use the same
   limits without automatic command execution or capability persistence.
3. Prove pane name and theme color survive save/open and inert workspace
   restoration, while runtime IDs re-key and OSC titles do not persist.
4. Prove live, stopped, and unavailable panes can receive safe explicit names
   and theme colors.
5. Prove the pane header is compact, uses color without color-only meaning,
   has icon-only accessible controls, and retains close confirmation behavior.
6. Prove group and pane sidebar rows each have one accessible three-dot menu
   with all old actions.
7. Review concurrency, failure atomicity, restoration bounds, security allow
   lists, backward compatibility, and unnecessary scope changes.
8. Set all v2 plan and manifest rows to `Integrated and verified` only after
   the gates pass. Do not mark the older blocked TG-90 plan complete.

## Gates and Goal Mode prompt

Run format fix, format lint, build, `./script/test.sh` in parallel mode, and
`git diff --check`, in that order. The coordinator will run the serial suite,
Rafu Lightning launch, GitHub CI, and release-branch work after merge.

> Call `create_goal` first with objective "Complete TG-190 from
> `docs/plans/phases/terminal-groups/TG-190-v2-integration-release.md`". Confirm
> a clean worktree on `terminal-groups/tg-190-v2-integration-release` at exact
> commit `<TG120_TG130_MERGED_SHA>` and confirm it is not the primary checkout.
> Stop without edits if false. Read all required skills and files. Edit only
> owned paths. Run the ordered parallel gates, commit, and delete this
> worktree's `.build` last. Do not merge, rebase, push, or create a release
> branch. Report branch, commit SHA, files, tests, security/concurrency and
> accessibility reviews, risks, and Deviations.

