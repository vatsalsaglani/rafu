# C6 — Workflow library: multiple workflows, scopes, templates, concurrent runs

- **Branch:** `conductor/c6-workflow-library` (Wave C, branch after C5 merges)
- **Depends on:** C0 + C1 + C5 on `main` (verify in branch history)
- **Status:** Planned

## Mission

Make workflows plural and shareable: many workflow definitions per repo,
user-global definitions with repo override, bundled starter templates, a
picker at launch time, and more than one run in flight. Files stay the
source of truth throughout — the GUI edits `.rafu/` files, never a parallel
store.

## Scope

### Scoped definition resolution

- Repo scope: `.rafu/agents/`, `.rafu/workflows/` (exists since C0).
- User-global scope: `~/Library/Application Support/Rafu/conductor/agents/`
  and `.../workflows/` — same file formats, same parsers.
- Resolution: repo overrides global on name collision; the UI always labels
  which scope a definition came from. Runs snapshot the resolved definition
  into their manifest (already the C0 contract), so later edits never
  rewrite history.

### Bundled templates

Shipped read-only inside the app bundle, instantiated (copied) into a
chosen scope on demand — never edited in place:

- `advise-implement-document` — the flagship three-role pipeline (ports the
  repo's `.claude/agents` advisor/implementor/documentor pattern to
  Ensemble format; roles default to distinct providers as a demonstration
  of the multi-vendor point, with models left for the user to bind).
- `review-only` — one read-only reviewer role.
- `implement-review` — mutating implementor + read-only reviewer + merge
  gate.

### Library + launch UX

- A Workflows section in the Runs panel (or a segmented sub-view within
  it — implementor's choice, recorded): list of workflows across both
  scopes, with New from template, Duplicate, Reveal in Finder, Open (files
  open as ordinary editor tabs — editing IS text editing; validation
  surfaces parse errors inline in the list, never a modal).
- "New Run…" grows a workflow picker (default: last used per repo);
  per-run model override for any role at launch time (bind or override the
  agent file's `model:` without editing the file; the override lands in the
  manifest).
- Agent-definition validation errors (unknown provider, disabled adapter,
  unsupported autonomy) are shown at pick time, before anything spawns.

### Concurrent runs

- Multiple pipelines in flight across one or more workspace windows; each
  run already owns its isolated worktree + run dir (C1), so this is
  bookkeeping, not new isolation: per-run terminal tabs, panel grouping,
  and a guard that two mutating runs never share a worktree. A sane
  default cap (e.g. 3 active runs per window) with an explicit
  user-visible reason when hit — bounded by policy, not by accident.

## Owned paths

- `Sources/RafuApp/Conductor/Library/**` (new: scope resolution, templates,
  validation)
- `Views/ConductorRunsPanelView.swift` (extend — this phase owns it after
  C5; coordinate via wave ordering, not concurrent edits)
- Bundle resources for templates (+ `Package.swift` resource entry ONLY if
  unavoidable — flag it; prefer embedding via existing resource dirs)
- `Tests/RafuAppTests/Conductor/Library*` + fixtures
- This file's status line

Forbidden: adapters, `ConductorCore.swift` (scope resolution composes the
existing parsers; a needed core change is stop-and-report), registry, run
engine files beyond their public surface.

## Exit criteria

- Headless: scope resolution + override labeling tests; template
  instantiation is idempotent and never overwrites without confirmation;
  per-run model override lands in the manifest; concurrent-run guard tests.
- Deferred GUI pass listed: library list, picker flow, two concurrent runs
  in two windows.

## Goal-mode prompt

> /goal Implement phase C6 exactly as scoped in
> docs/plans/phases/conductor/C6-workflow-library.md. Read that file AND
> docs/plans/phases/conductor/README.md AND
> docs/decisions/0018-conductor-external-agent-orchestration.md first, in
> that order, then AGENTS.md. First run `git status --short --branch`; you
> must be on branch conductor/c6-workflow-library with a clean tree, and
> C0+C1+C5 must be present in this branch's history (the runs panel and
> workflow engine are implemented) — if not, STOP and report. Use the
> advisor→implementor→documentor workflow per increment. Files remain the
> source of truth: the GUI edits .rafu/ and Application Support files, and
> definitions open as ordinary editor tabs. All tests run against
> FakeConductorAdapter. Obey the README worktree ground rules (headless
> gates only, commit on this branch, never push/merge, touch ONLY your
> owned paths; flag any unavoidable Package.swift resource hunk as one
> isolated commit). Finish with one consolidated report: per increment —
> changes, files, test delta, deviations, evidence; then deferred GUI
> checks, intended doc-index rows, and remaining risks.
