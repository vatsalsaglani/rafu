# Ensemble — remediation plan from the 2026-07-29 manual test run

- **Status:** Planned (2026-07-29). Findings verified against on-disk evidence
  from the user's first real advisor run in `~/Desktop/njunk/personal/products/ensemble-test`.
- **Source:** [`ensemble-manual-test-plan.md`](ensemble-manual-test-plan.md),
  sections A–C. The run stopped at C1–C3; sections D onward are blocked on F1.
- **Scope:** six findings, ordered by severity. F1 is a structural blocker for
  every readOnly role on every adapter. Nothing here weakens ADR 0018.
- **Execution:** fanned out as the R-series worktree plans — see
  [`R-execution-plan.md`](R-execution-plan.md) (R1–R6, each with a goal-mode
  prompt). The "Order of work" section below is superseded by that plan's
  waves.

## What actually happened (verified, not inferred)

The user started a Single Role run of the `advisor` fixture (provider
`claudeCode`, `autonomy: readOnly`). The evidence chain:

1. Rafu created `.rafu/runs/e0e353ce…/` with `prompt.md`, `handoff/`,
   `logs/output.log`, and a manifest. `RAFU_HANDOFF` was injected correctly —
   the model echoed the resolved absolute handoff path in its output.
2. The adapter invoked
   `claude -p … --output-format stream-json --verbose --permission-mode plan`
   (`ClaudeCodeAdapter.swift:597-608`). The terminal tab therefore showed raw
   JSON events, not readable CLI output.
3. **Plan mode denied the one write the contract requires.** The model's final
   message (captured in `output.log`): *"The `ExitPlanMode` tool isn't enabled
   in this session … per plan-mode rules I have not written the artifact
   yet."* Headless `-p` has no approval dialog, so plan mode can never exit.
   Claude Code wrote its plan document to `~/.claude/plans/…` — that is the
   file the user found under `~/.claude` — and exited 0. Cost: $0.74 for a
   structurally impossible task.
4. Rafu's artifact contract then worked exactly as designed: the step was
   recorded **failed — "The agent exited successfully without creating its
   handoff artifact."** The run detail canvas shows this with a warning glyph.
5. `.rafu/runs/` exists on disk but never appeared in the app's file tree, so
   the user concluded no runs folder was created (manual plan check C6 is not
   performable in-app).
6. A second run directory (`4947e871…`) holds `prompt.md` + `handoff/` but
   **no manifest.json** — an orphan the Runs panel silently skips.
7. The Activity feed showed the run's three state transitions
   (Pending → Running → Interrupted) as three visually identical rows, which
   read as "the same run repeated 3 times."

**What this proves works:** run-directory creation, prompt persistence, the
curated environment (`RAFU_HANDOFF`), the PTY tee (`output.log` has the full
transcript — manual-plan check C6's biggest fear), honest artifact-based
completion, failure surfacing in run detail, and cost/usage capture. The
engine held. The breakage is concentrated in adapter flag choices and three
UI-visibility gaps.

---

## F1 — readOnly roles structurally cannot write their handoff artifact — BLOCKER

**Root cause.** `ConductorAutonomy.readOnly` maps to each vendor's
deny-all-writes mode. But every role — including read-only advisors — must
make exactly one write: the artifact in `RAFU_HANDOFF`. The two requirements
contradict, so every readOnly role on every adapter fails after doing the
work:

| Adapter | Current readOnly mapping | Verdict |
|---|---|---|
| Claude Code | `--permission-mode plan` | **Confirmed broken** (this run) |
| Codex | `--sandbox read-only` | Same class — denies all writes; must probe |
| OpenCode | `--agent plan` | Same class — must probe |
| Cline | `--plan` + `--auto-approve false` | Same class — must probe |
| Cursor | `--mode plan` | Already fails closed (known limitation) |

The capability-matrix probes verified these flags *exist and enforce
read-only*; no probe ever checked "read-only **and** can still write the
handoff file," which is the actual contract.

**Fix.** Redefine readOnly operationally: *no repository writes; writes inside
the run's handoff directory are allowed.* Then re-probe per adapter:

1. **Claude Code (first, unblocks the manual plan):** probe
   `--permission-mode default` with
   `--allowedTools "Write(<handoff-abs-path>/**)"` (and `Edit(…)`), relying on
   headless auto-deny for everything else. Verify: repo write → denied; handoff
   write → allowed; repo reads → allowed; artifact appears; exit 0.
2. **Codex:** probe whether a scoped writable root is expressible
   (`--sandbox workspace-write` with the handoff dir as the workspace, or a
   sandbox config override). Reads must still reach the repo.
3. **OpenCode / Cline:** equivalent probes.
4. **Any adapter that cannot express "read-only plus handoff"** must fail
   **before spawning** with a message naming the vendor limitation — today it
   fails after a paid, minutes-long run. Extend
   `ConductorCLIAdapter` so an adapter can declare readOnly unsupported, and
   surface that in the New Run canvas, not just at completion.
5. Record every probe result in
   [`conductor-cli-capability-matrix.md`](../../../references/conductor-cli-capability-matrix.md)
   as a new row: **"Read-only + handoff write."**
6. Tests: unit-assert the Claude invocation for readOnly no longer contains
   `plan`; add the probe procedure to the manual plan's known-limitations
   section for adapters that stay fail-closed.

**Owned paths:** `Sources/RafuApp/Conductor/Adapters/*.swift`,
`Sources/RafuApp/Conductor/ConductorCore.swift` (doc comment for
`ConductorAutonomy`), capability matrix reference note, adapter tests.

## F2 — terminal shows raw `stream-json` instead of the CLI working — HIGH

**Root cause.** `--output-format stream-json --verbose` (Claude, and the
unverified Kimi adapter). Nothing in Rafu consumes the JSON — ADR 0018 says
captured output is evidence, not protocol — so the flags buy nothing and cost
readability. Plain `-p` text output is the honest alternative but is silent
until completion, which reads as a hang on a multi-minute step.

**Fix.** Keep `stream-json` but add a **presentation-only** line renderer in
the run terminal path: each JSON event becomes one short human line
("initialized (model …)", "tool: Write brief.md", "thinking…", final text
verbatim), with an unparseable line passed through raw. Display-layer only —
completion detection stays artifact + exit; vendor schema churn degrades to
raw lines, never to misbehavior. `output.log` captures what the terminal
showed. Remove the meaningless "Restart Shell" overlay from completed
Ensemble step terminals (plain terminals keep it).

**Owned paths:** `Sources/RafuApp/Conductor/Run/ConductorRunOutputCapture.swift`
(or a new small formatter beside it), terminal hosting view for run steps,
`ClaudeCodeAdapter.swift` / `KimiAdapter.swift` doc comments.

## F3 — `.rafu/runs` never appears in the file tree — HIGH

**Symptom.** Runs existed on disk while the tree showed only
`.rafu/agents` and `.rafu/workflows`. Manual-plan check C6 cannot be performed
in-app; the user reasonably concluded no runs were recorded.

**Investigate then fix.** `.rafu` itself renders, so dotfiles are not hidden
wholesale. Two candidate causes, in order of likelihood: (a) the tree loads a
directory's children once on first expansion and the filesystem watcher does
not refresh nested directories created later (`runs/` was born after `.rafu`
was first expanded); (b) an ignore filter. Determine which via
`WorkspaceFileNode` loading and the `WorkspaceSession` filesystem monitor,
then make expanded directories reflect later-created children. Acceptance:
start a run; `.rafu/runs/<id>/` appears in the tree without collapsing or
reopening anything.

## F4 — Activity feed reads as one run repeated three times — MEDIUM

**Symptom.** Three rows ("advisor → Pending / Running / Interrupted"), each
with its own Open Run button, indistinguishable from three runs.

**Fix.** Keep the event-feed model (manual plan K5) but make run identity
visible: prefix rows with a short run id or group consecutive events of one
run under one header. Separately, **investigate the state history**: the
run's manifest ends `failed`, yet the newest event says `Interrupted` —
either the event belongs to the orphan run (F5) or a failed completion is
mislabelled. A failed run must emit "Failed," never "Interrupted."

**Owned paths:** the Activity feed model/view under
`Sources/RafuApp/Views/ConductorRunsPanelView.swift` and its event source.

## F5 — a run directory can exist without a manifest, and is then invisible — MEDIUM

**Symptom.** `.rafu/runs/4947e871…/` has `prompt.md` and `handoff/` but no
`manifest.json` and no logs. `listRunIDs()` + load silently skip it, so it is
orphan evidence no surface can show — contradicting the recovery contract
(manual plan G8: degraded runs surface with an explicit note, never vanish).

**Fix.** (a) Write the initial manifest atomically **at run creation, before
spawn** — the directory must never exist manifest-less; (b) in recovery,
surface a manifest-less run directory as degraded history ("evidence present,
manifest missing") instead of skipping it. Add a regression test for both.

**Owned paths:** `Sources/RafuApp/Conductor/Run/ConductorRunController.swift`,
`ConductorRunStore.swift`, `ConductorRunRecovery.swift`, tests.

## F6 — Single Role door has no provider/model override — MEDIUM (feature)

The Workflow door supports a model override (manual plan D2); the Single Role
door offers only the agent file, task prompt, and base ref — provider and
model come silently from frontmatter, and this run recorded `model: ""`
(rendered honestly as "CLI default", but unchosen). Add the same
provider + model override controls to Single Role: default from frontmatter,
override applies to this run only (never edits the file), recorded in the
manifest binding. Reuse the Workflow door's picker so the two doors cannot
drift.

**Owned paths:** `Sources/RafuApp/Conductor/Run/ConductorNewRunModel.swift`,
the New Ensemble Run canvas view, tests.

---

## Order of work and gates

1. **F1 Claude probe + adapter fix** — unblocks the manual plan. Gate:
   C1–C6 pass end to end with a real advisor run; `handoff/brief.md` exists;
   run completes (not fails).
2. **F2 renderer** — gate: C1's terminal shows readable lines; `output.log`
   captures them.
3. **F3 + F5** (small, parallel) — gates: runs directory visible live in the
   tree; orphan directory surfaces as degraded history.
4. **F4 + F6** — gates: Activity rows identify their run; Single Role door
   offers provider/model with frontmatter defaults.
5. **F1 remaining adapters** (Codex next — the D-section pipeline needs it,
   its readOnly probe can ride alongside step 1 if bandwidth allows).
6. Re-run manual plan sections C and D through D7 before touching E onward.

Every adapter flag change lands with its probe evidence in the capability
matrix (AGENTS.md standing learning rule). No fix here may add stream
parsing as *protocol* — completion stays artifact + clean exit.
