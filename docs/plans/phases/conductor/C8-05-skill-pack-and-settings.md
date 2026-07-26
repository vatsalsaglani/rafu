# C8-05 — The `ensemble-with-rafu` skill pack, installer, Settings pane

- **Status:** Implemented; headless verification complete. Branch: `conductor/c8-05-skill-pack` (from `main`
  after **wave 1** merged — verify `Sources/RafuCore/Ensemble/` and
  `docs/references/ensemble-ipc-verbs.md` exist; missing ⇒ STOP and
  report). **Wave 2** — parallel with C8-03 and C8-06.
- **The one plan allowed to edit `Package.swift`** (one `.copy` line).
- **Moved up from wave 3 on 2026-07-26.** You do NOT wait for C8-03. The
  verb semantics this skill teaches are fixed by the merged ADR 0018
  amendment, not by C8-03's code, so they can be taught accurately now.
  Two things follow, and both are already reflected below: the grant
  **Defaults card is dropped** (it was the sole compile dependency on
  C8-03's `ConductorEnsembleGrant`, and was only ever a read-only
  display), and `troubleshooting.md` must state that a mutating verb
  exiting 64 means the installed Rafu predates them.

## Goal

Ship the coordinator skill pack bundled read-only in the app, an
on-demand installer (classify-before-write, confirmation on conflicts,
reports where it wrote), and a **Settings → Ensemble** pane hosting the
installer plus the verb-version line. The skill teaches a coordinator
CLI exactly the shipped verb surface — the hard rules, the loop, the
patterns — and declares the verb version it targets.

## Read first

`AGENTS.md`; conductor `README.md`; `C8-cli-and-skill-spec.md` Part 2
(contents, hard rules, patterns table, distribution) and Part 3 (the
three worked examples — they become skill material);
`docs/references/ensemble-ipc-verbs.md` (the authoritative verb
reference the skill MIRRORS — never contradict it);
`docs/references/ensemble-consent-and-token.md`;
`Sources/RafuApp/Conductor/Library/ConductorTemplateLibrary.swift` (the
instantiate-never-edit pattern you clone);
`Sources/RafuApp/Settings/ConductorSettingsTab.swift` +
`RafuSettingsView.swift` (the pane pattern); Build macOS Apps
`swiftui-patterns` for the Settings work.

## Owned paths

- NEW `Sources/RafuApp/Resources/EnsembleSkills/ensemble-with-rafu/`
  (`SKILL.md`, `references/{verbs.md,file-formats.md,patterns.md,troubleshooting.md}`)
- `Package.swift` — exactly one added line:
  `.copy("Resources/EnsembleSkills"),` beside the EnsembleTemplates entry
- NEW `Sources/RafuApp/Conductor/Ensemble/ConductorSkillInstaller.swift`
- NEW `Sources/RafuApp/Settings/EnsembleSettingsTab.swift`
- `Sources/RafuApp/Settings/RafuSettingsView.swift` — one added `Tab`
- NEW tests `Tests/RafuAppTests/Conductor/SkillPackTests.swift`,
  `Tests/RafuAppTests/EnsembleSettingsTests.swift`
- Docs: NEW `docs/references/ensemble-skill-pack.md`;
  `ensemble-manual-test-plan.md` — extend section A (A4/A5 rows for the
  Settings pane + install flow); this plan's status line.

**Forbidden:** everything C8-04 and C8-07 own this wave (engine, run
detail canvas, commands, palette, window presentations, runs panel);
`ConductorCore.swift`; `script/build_and_run.sh` (the SwiftPM bundle is
staged wholesale — verify the skill lands inside
`Rafu_RafuApp.bundle` via a test, not a script edit; if a staging assert
is genuinely needed, report it as a handoff).

## Design contract

### Skill content (author for a coordinator LLM, terse and rule-first)

`SKILL.md` frontmatter: `name: ensemble-with-rafu`, `description:` one
line ("Orchestrate parallel agent runs in Rafu via rafu ensemble —
worktrees, gates, budgets"), `targetsVerbVersion: 1` (matches
`LauncherIPCProtocol.ensembleVerbVersion`). Body sections:

1. **When to use** — you are a coordinator launched from Rafu's New
   Ensemble sheet; `RAFU_ENSEMBLE_TOKEN` is in your environment; the
   repo you sit in is the workspace.
2. **The hard rules** (verbatim-strength, from the spec §2.2):
   never merge — `propose-merge` then `await --state merged`; check
   `grant` before every fan-out and size to what is left; one artifact
   per step at the path Rafu gave the child; exit 77 = stop and report,
   never retry with different arguments; exit 75 = ask the user to
   extend, never loop; bind roles explicitly, never assume a CLI is
   installed or authorized; dedupe against everything SEEN, not against
   confirmed findings; write `.rafu/agents/*.md` + `.rafu/workflows/*.md`
   FIRST and open with `run --plan-gate` so the user approves the plan
   before anything spawns.
3. **The loop** — plan files → `run --plan-gate` → await approval →
   `grant` → fan out `run` (≤ concurrent limit) → `await --any` →
   read `artifact` → judge → repeat or `propose-merge` → `await
   --state merged` → summarize in your own terminal.
4. **Failure table** — exit codes 0/64/65/69/75/77 with the one action
   each demands (spec §1.3 table).

`references/verbs.md`: mirrored BY HAND. The **read-only** verbs
(`status`, `artifact`, `await`) come from
`docs/references/ensemble-ipc-verbs.md` — same grammar lines, same JSON
examples, same state enum. The **mutating** verbs (`run`, `abort`,
`note`, `grant`, `propose-merge`) are not implemented yet; take their
semantics from the **ADR 0018 amendment** (authoritative: trust classes,
token rule, exit codes) plus `C8-cli-and-skill-spec.md` §1.3 for the
grammar and JSON shapes. Never invent a flag neither source states.

Mark every mutating verb as requiring `RAFU_ENSEMBLE_TOKEN`, and add a
header: "Targets `rafu ensemble` verb version 1. If `rafu ensemble
status --json` reports a different `verbVersion`, trust the CLI and
re-read its `--help`."

Do **not** edit `docs/references/ensemble-ipc-verbs.md` — C8-03 owns it
this wave and appends the mutating verbs there. After C8-03 merges the
coordinator reconciles your `verbs.md` against the shipped parser.
`references/file-formats.md`: the agent/workflow grammar from
`conductor-file-contracts.md` (1-based numbering as corrected by C8-01)
with two worked files. `references/patterns.md`: the
primitive-equivalence table + the three worked examples from the spec
(fan-out+verify, the user's actual loop, loop-until-dry) rewritten as
imperative recipes. `references/troubleshooting.md`: per-exit-code
diagnosis + "app not running" (69) + "workspace not open in Rafu" + the
re-grant-after-relaunch rule (read-only verbs still work; ask the user
to re-grant from the New Ensemble sheet). **Plus, load-bearing while
wave 2 is in flight:** a *mutating* verb exiting **64** means the
installed Rafu predates the mutating verb surface — stop and tell the
user to update Rafu; do not retry with different arguments. Without
that line a coordinator meets an unimplemented verb and misreads it as
its own grammar mistake, which is exactly the loop the exit-code table
exists to prevent.

### Installer (`ConductorSkillInstaller.swift`)

Clone the `ConductorTemplateInstantiator` shape exactly: code-declared
manifest of the five files (never trust an on-disk listing), 1 MiB per
file cap, `isSafePathComponent` on every component, classify EVERY
destination before writing anything, atomic writes,
`ExistingFilePolicy.requireConfirmation` default with
`.replaceConfirmed`, result struct
`{created, replaced, unchanged, conflicts, destinationDescription}`.

Destinations (an enum, registry-style so more can be added):
- `.claudeCode` → `~/.claude/skills/ensemble-with-rafu/` — the verified
  first-class target.
- `.custom(URL)` → user-chosen folder (the Settings pane offers
  "Install to Folder…" via `fileImporter`); this is the honest path for
  Codex and the rest until their skill directories are verified —
  record that honesty in the reference note rather than guessing vendor
  paths.

Source root: `Bundle.module.url(forResource: "EnsembleSkills",
withExtension: nil)` (main-actor, same caveat as the template catalog).

### Settings → Ensemble pane

`RafuSettingsView.swift`: add
`Tab("Ensemble", systemImage: "circle.hexagongrid") {
EnsembleSettingsSection() }` after Agents. `EnsembleSettingsTab.swift`:
`struct EnsembleSettingsSection: View` + `@MainActor @Observable final
class EnsembleSettingsModel` (no I/O in construction; work in `.task`):

- **Coordinator skill card**: name, one-line description,
  `targetsVerbVersion` vs `LauncherIPCProtocol.ensembleVerbVersion`
  (mismatch shows a plain warning line — glyph + text, not color
  alone), buttons **Install for Claude Code** and **Install to
  Folder…**, result line reporting exactly where files were written /
  replaced / skipped, confirmation flow for conflicts (mirror the
  template-replacement `confirmationDialog` in the runs panel).
- ~~Defaults card~~ — **dropped** (2026-07-26). It read
  `ConductorEnsembleGrant`, which C8-03 creates, and was the only reason
  this plan waited on wave 2. It was read-only display of values the
  New Ensemble sheet already shows at launch, so deferring costs the
  user nothing. Recorded follow-up: surface (and later edit) grant
  defaults here once C8-03 and C8-07 have both landed.

Form style `.grouped`, `RafuSheetHeader`-free (Settings pane, not a
sheet), no credentials, no network.

## Tests

- `SkillPackTests`: all five files resolve from `Bundle.module` and are
  ≤ 1 MiB; `SKILL.md` frontmatter parses (reuse `ConductorFrontmatter`)
  and `targetsVerbVersion == LauncherIPCProtocol.ensembleVerbVersion`
  (the drift tripwire — THE load-bearing test of this plan);
  `verbs.md` mentions every verb the parser accepts (string-presence
  check against `EnsembleInvocation` cases — cheap honest drift guard).
  Assert **parser ⊆ doc**, deliberately not equality: during wave 2 the
  skill documents mutating verbs the parser does not yet have, and an
  equality test would fail on exactly the content we intend to ship. The
  reverse direction (doc ⊆ parser) becomes true after the coordinator's
  post-C8-03 reconciliation, and is not this plan's gate.
- Installer: fresh install creates 5 files; re-install is idempotent
  (`unchanged`); conflict requires confirmation and `.replaceConfirmed`
  replaces; unsafe path component refused; destination description
  accurate.
- Settings: model exposes install states without I/O at init; version
  match/mismatch logic.

## Gates

Standard four gates, HEADLESS ONLY. Additionally:
`swift test --filter SkillPack` green under both parallel modes, and
verify the resource ships: a test asserting
`Bundle.module.url(forResource: "EnsembleSkills", …) != nil` (this is
what makes a `build_and_run.sh` edit unnecessary).

## Documentation deliverables

NEW `docs/references/ensemble-skill-pack.md`: bundling mechanism, the
code-declared manifest rule, destinations + the vendor-path honesty
note, the version-drift tripwire, how to update the skill when verbs
change (edit `ensemble-ipc-verbs.md` FIRST, then mirror). Extend
`ensemble-manual-test-plan.md` §A with A4 (pane renders, versions
match) and A5 (install writes to `~/.claude/skills/`, re-install
idempotent, conflict asks). Intended index rows in the report.

## Handoff report

Delivered behavior; changed paths (call out the single Package.swift
line); test evidence; the skill's final SKILL.md hard-rules list
verbatim; remaining risks (vendor skill-directory verification);
branch; commit messages; `git rev-parse HEAD`.

---

## Goal-mode agent prompt (copy into the worktree agent)

```
You are a phase agent for the Rafu repository, working in a dedicated git
worktree. GOAL MODE: you own the outcome end to end; do not ask for
permission between steps; finish or report precisely why you cannot.

Branch: conductor/c8-05-skill-pack. Preflight: run `git status --short
--branch` ONCE. On this branch + clean tree → proceed. Detached HEAD or
wrong branch + clean tree → checkout the branch if it exists, else
`git checkout -b conductor/c8-05-skill-pack main`, then proceed and say
so. Dirty tree with edits you did not make → STOP. Then verify the
prerequisite: Sources/RafuCore/Ensemble/ and
docs/references/ensemble-ipc-verbs.md exist (wave 1 merged). Missing ⇒
STOP and report.

You run in WAVE 2, in parallel with C8-03 (mutating verbs) and C8-06
(graph canvas). Those branches do not exist in your tree and you do not
wait for them. Expect ensemble-ipc-verbs.md to document ONLY the
read-only verbs — that is correct, not a missing prerequisite.

GOAL: implement docs/plans/phases/conductor/C8-05-skill-pack-and-settings.md
— the bundled ensemble-with-rafu skill pack (SKILL.md + four reference
files authored for a coordinator LLM, mirroring ensemble-ipc-verbs.md
and declaring targetsVerbVersion), the ConductorSkillInstaller cloned
from the template-instantiator pattern (classify-before-write,
confirmation, honest destination reporting, ~/.claude/skills/ +
choose-a-folder), the Settings → Ensemble pane hosting the installer and
the version line, and the single Package.swift resource line. The plan
file is your authoritative design contract, edit list, and test list —
read it FIRST, then AGENTS.md, the conductor README ground rules,
C8-cli-and-skill-spec.md Parts 2–3, ensemble-ipc-verbs.md,
ensemble-consent-and-token.md, and ConductorTemplateLibrary.swift.

HARD CONSTRAINTS: mirror, never invent — read-only verbs come from
ensemble-ipc-verbs.md, mutating verbs from the ADR 0018 amendment plus
C8-cli-and-skill-spec.md §1.3, and no flag that neither states; do NOT
edit ensemble-ipc-verbs.md itself (C8-03 owns it this wave); the
version-drift tripwire test (targetsVerbVersion == ensembleVerbVersion)
is mandatory, and the verb-coverage test asserts parser ⊆ doc, NOT
equality, because you deliberately document verbs that do not exist
yet; troubleshooting.md must tell a coordinator that a mutating verb
exiting 64 means Rafu predates those verbs — stop, do not retry; the
grant Defaults card is DROPPED, so nothing you write may reference
ConductorEnsembleGrant or any other C8-03 type (if you find yourself
needing one, you have gone out of scope); the installer classifies every
destination before writing anything and never silently overwrites; never
guess vendor skill directories beyond ~/.claude/skills — the
folder-picker is the honest fallback and the reference note says so;
Package.swift gets exactly one .copy line and nothing else; user-visible
strings say Ensemble; no credentials, no network, no I/O in model
construction. DO NOT touch engine files, ConductorRunDetailCanvas,
RafuAppCommands, CommandPaletteView, WorkspaceWindowView,
ConductorRunsPanelView, ConductorCore.swift, script/, or anything under
Sources/RafuApp/Conductor/Ensemble/ and Sources/RafuApp/Views/ — C8-03
and C8-06 own those this wave. In ensemble-manual-test-plan.md extend
ONLY section A; C8-06/C8-04/C8-07 append sections K/L/M to the same
file. HEADLESS ONLY.

DEFINITION OF DONE:
1. Five skill files bundle and resolve via Bundle.module (test-proven);
   SKILL.md carries the hard rules, the loop, and the exit-code table;
   verbs.md names every verb the parser accepts (drift test).
2. Installer: fresh install / idempotent re-install / confirmed replace
   / refused unsafe paths, all tested; reports exactly where it wrote.
3. Settings → Ensemble pane renders the skill card + defaults card,
   version mismatch shows glyph+text warning; no I/O at init.
4. swift build 0 warnings; swift test AND swift test --no-parallel
   green; format --fix + --lint clean.
5. ensemble-skill-pack.md written; manual-test-plan §A extended with
   A4/A5; intended index rows in the report only.
6. Work committed locally in verified stages; never push/merge/rebase/
   checkout main. Shared-file needs are a HANDOFF with a proposed diff.

FINAL REPORT (mandatory): delivered behavior; changed paths (call out
the one Package.swift line); test evidence; the final hard-rules list
from SKILL.md verbatim; remaining risks; docs written; branch name;
every commit message; last commit id from `git rev-parse HEAD`.
```
