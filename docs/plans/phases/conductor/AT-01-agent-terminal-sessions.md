# AT-01 — Agent terminal sessions: one action from discovery to a live agent

- **Status:** Complete (2026-07-26) on
  `conductor/at-01-agent-terminals`. Headless gates are green; coordinator
  GUI checks are recorded in manual-test section N. This plan owns the
  agent-icon catalog and per-CLI interactive-launch probe table; C8-06 and
  C8-03 consume them after merge (ownership transfer recorded in
  `AT-execution-plan.md`).
- Serial: AT-02 depends on this plan's sheet.
- Parallel-merge note: C8-02 also edits `ConductorCore.swift` (manifest
  region ~line 230) and `WorkspaceSession.swift` (~line 727) — your
  edits sit in different regions (`TerminalProcessSpec` ~577; terminal
  seam ~933). Keep them exactly there; the coordinator merges the two
  branches serially.

## Goal

Make every discovered, authed agent CLI launchable as a first-class
interactive terminal session in one action — the muxy.app move, done
natively. The session carries agent identity (icon + name) through the
editor tab, the terminals panel, the Control-Tab switcher, and the
Resources surface. Ship ADR 0021 in the same change. Tokenless by
design: this plan adds ZERO Ensemble capability (AT-02 adds the bridge).

## Read first

`AGENTS.md`; conductor `README.md` ground rules;
[`AT-execution-plan.md`](AT-execution-plan.md) (locked decisions,
ownership transfers); ADR 0004, ADR 0014, ADR 0018 (+ Amendment if
C8-01 has merged; if not, the amendment text in
`C8-01-consent-adr-and-doc-hygiene.md` is the same contract — what an
agent terminal must NOT be);
`docs/references/conductor-pty-spawn-and-child-environment.md` (curated
PATH, adapter-dir prepend rule);
`Sources/RafuApp/Terminal/WorkspaceTerminalController.swift`
(`WorkspaceTerminalManager.newSession(spec:)` ~line 95 — the spec-based
entry point you reuse; `processSpec` branch in `makeOrReuseView`);
`Sources/RafuApp/Conductor/ConductorCore.swift` (`TerminalProcessSpec`,
`RafuConductorEnvironment.curatedPath`);
`Sources/RafuApp/Views/GitHubPublishSheet.swift` (sheet structure);
`swiftui-expert-skill`; `swift-concurrency-pro` for the launch service.

## Owned paths

- NEW `docs/decisions/0021-agent-terminals.md`
- NEW `Sources/RafuApp/Terminal/AgentTerminalLaunchService.swift`
- NEW `Sources/RafuApp/Views/AgentTerminalSheet.swift`
- NEW `Sources/RafuApp/Conductor/ConductorCLIIcons.swift` — the
  seven-CLI icon catalog (transferred from C8-06; C8-06 consumes it)
- NEW `Resources/FileIcons/agent-{claude-code,codex,opencode,cline,kimi,gemini,cursor}.svg`
  — vendored from lobe-icons, pinned and normalized (see Design
  contract). The existing `claude.svg` / `codex.svg` / `gemini.svg` are
  **read-only to you**: they serve the file tree and must not change.
- `script/build_and_run.sh` — seven icon staging asserts ONLY (beside
  the existing `test -f` block, ~lines 184–186)
- `Sources/RafuApp/Conductor/ConductorCore.swift` — ONE additive field:
  `TerminalProcessSpec.agentProvider: ConductorCLIID? = nil`
  (the `TerminalProcessSpec` region ~line 577 ONLY — C8-02 edits the
  manifest region of this file in parallel; do not stray)
- `Sources/RafuApp/Models/WorkspaceSession.swift` — anchored seam only
- `Sources/RafuApp/Views/WorkspaceWindowView.swift` — one `.sheet` line
- `Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift` +
  `Sources/RafuApp/Terminal/TerminalsPanelModel.swift` — "+" menu with
  agent rows; agent identity on session rows
- `Sources/RafuApp/Views/EditorTabSwitcherView.swift` — provider icon +
  name for agent-terminal candidates
- `Sources/RafuApp/App/RafuAppCommands.swift` — "New Agent Terminal…"
  ⌘⇧A (terminal section)
- `Sources/RafuApp/Views/CommandPaletteView.swift` — static sheet command
  + per-agent quick commands
- `ProcessResourceRegistry` (locate via `rg -n "ProcessKind"
  Sources/RafuApp`) — additive kind `.agentTerminal` rendering
  **"Agent Terminal"** (the existing `.agent` kind renders "Ensemble
  Agent", which would be a lie here)
- NEW tests `Tests/RafuAppTests/AgentTerminalTests.swift`; extend
  `TerminalsPanelTests.swift`, `EditorTabSwitcherTests.swift`,
  `Tests/RafuAppTests/Conductor/ProcessAttributionTests.swift`,
  `Tests/RafuAppTests/FileIconAssetsTests.swift` (four new assets +
  exhaustive `ConductorCLIID` coverage)
- Docs: NEW `docs/references/agent-terminals.md`;
  `ensemble-manual-test-plan.md` NEW section **N**; this plan's status
  line. Intended `docs/decisions/README.md` and
  `docs/references/README.md` index rows go in your REPORT (never edit
  shared indexes).

**Forbidden:** everything under `Sources/RafuApp/Conductor/Ensemble/`
and `Sources/RafuCore/Ensemble/` (C8-02 creates those in parallel this
wave — never create or touch them), the Conductor run-engine files,
adapters (read-only consumption), `Package.swift`,
`EditorCanvasView.swift`, Settings, `script/` beyond the four assert
lines named above.

## Design contract

### ADR 0021 (write it first — it constrains the code)

Title: "ADR 0021: Agent terminals — interactive vendor CLIs as
first-class terminal sessions". Status Accepted; narrows ADR 0004's
login-shell default; explicitly NOT an Ensemble surface (relation to
ADR 0018: no token, no grant, no manifests, no capture, no graph
presence; auth fully delegated, unchanged). Rules: argv arrays only;
environment is exactly `PATH` (curated + the adapter's probed directory
prepended when discovery found the CLI off the curated path) — no
`RAFU_*` keys ever; sessions register as `.agentTerminal`; never
restored (ADR 0014); the launchable roster is the adapter registry's
probe result, degrading honestly. Naming note: `AgentTerminal*` internal
prefix, "Agent Terminal" user-visible.

### Launch service (`AgentTerminalLaunchService.swift`)

`@MainActor struct AgentTerminalLaunchService` (injectable adapters +
default-model store for tests):

- `func options() async -> [AgentTerminalOption]` — one row per
  `ConductorAdapterRegistry.all` entry:
  `AgentTerminalOption { id: ConductorCLIID, displayName, icon,
  availability: .ready(executableURL) | .notInstalled |
  .notAuthenticated(hint) , curatedModels: [String], defaultModel:
  String? }`. Probe via the existing resolve path
  (`ConductorRoleLaunchService.resolve`); auth hint text mirrors the
  Settings pane's ("not logged in — run `claude login` in a terminal").
- **You own the per-CLI interactive-launch table** (transferred from
  C8-03, which will reuse it for the coordinator launcher): for each of
  the seven CLIs, probe `<cli> --help` where installed and record (a)
  the bare interactive form, (b) the model flag shape if any. Treat
  undocumented shapes as HYPOTHESES (adapter ground rule): a CLI not
  installed in your environment is recorded `unverified` with the probe
  command the user must run. The table lives in
  `docs/references/agent-terminals.md`.
- `func specification(option:model:startingDirectory:) ->
  TerminalProcessSpec` — PURE. Executable from the probe; arguments =
  the CLI's bare interactive form, plus its model flag ONLY where your
  probe table records a verified shape (unverified ⇒ launch bare, model
  omitted, reason surfaced in the sheet as a caption — never guess
  flags). cwd = the chosen directory (default workspace
  root; must be inside the workspace). Environment: `["PATH":
  curatedPath]`, with the executable's own directory prepended when it
  lies outside the curated path (the adapter-prepend rule). `roleBadge`
  = the CLI display name; `agentProvider` set;
  `resourceAttribution: "<DisplayName> (agent terminal)"`;
  `outputLogURL: nil` (no capture — this is the user's own session, not
  run evidence).

### Icon catalog (`ConductorCLIIcons.swift` — transferred from C8-06)

**Vendor the real vendor marks from lobe-icons.** The earlier draft of
this plan called for hand-drawn letterform placeholders; that is
superseded. `lobehub/lobe-icons` publishes a uniform, MIT-licensed set
covering all seven of our CLIs, and using a product's own mark to label
that product is the honest, identifying choice — a "CL" box is a worse
answer for the user than Cline's actual logo.

**Source (verified 2026-07-26):** npm `@lobehub/icons-static-svg`,
**pin version `1.94.0`**, tarball integrity
`sha512-Inx1TYkjLH6YeHOIHeVW9+OM/xxRnk8TmcQVKquFUDBmE3X9sUuRGt7kALrrDBNNAbrWz7Qq6fAiFj9E9Mmw9Q==`.
Individual files are fetchable at
`https://unpkg.com/@lobehub/icons-static-svg@1.94.0/icons/<slug>.svg`.
All eleven candidate slugs were probed and return 200.

| `ConductorCLIID` | lobe slug | Vendored filename |
|---|---|---|
| `claudeCode` | `claude` | `agent-claude-code.svg` |
| `codex` | `codex` | `agent-codex.svg` |
| `openCode` | `opencode` | `agent-opencode.svg` |
| `cline` | `cline` | `agent-cline.svg` |
| `kimi` | `kimi` | `agent-kimi.svg` |
| `geminiCLI` | `gemini` | `agent-gemini.svg` |
| `cursor` | `cursor` | `agent-cursor.svg` |

**Vendor all seven under the `agent-` prefix — do NOT reuse or modify
the existing `claude.svg` / `codex.svg` / `gemini.svg`.** Those three
serve the *file tree* (`.claude/` directories, `claude.md`), come from a
different source, and are mutually inconsistent (`claude.svg` is
hardcoded `#ff7043`, `gemini.svg` carries a `radialGradient`,
`codex.svg` is stroke-based; viewBoxes 16 / 48 / 512). Touching them
would risk a file-tree regression for zero gain, and mixing sources
would make the graph canvas look assembled from spare parts. The
`agent-` prefix keeps both concerns separate in one flat directory, so
`FileIconAssets` needs no loader change. Unifying the file-tree icons
later is a recorded follow-up, explicitly out of scope here.

**Normalization (apply to each vendored file, then commit the result):**
lobe ships `fill="currentColor"`, `viewBox="0 0 24 24"`,
`width="1em" height="1em"`, plus a web-only
`style="flex:none;line-height:1"` and a `<title>`. Strip the `style`
attribute and the `<title>` (Rafu supplies its own accessibility
labels). **Keep `fill="currentColor"` and the `viewBox`** — that is
exactly what `assetIsTemplate: true` needs. `width/height="1em"` is
already proven to work in this app: all three existing shipped icons use
it. Record the byte-level SHA-256 of each committed file in the
reference note (Rafu's checksum-everything posture, ADR 0010 Part B) so
a future refresh is a diffable, verifiable act.

**API:** `ConductorCLIIcons.icon(for id: ConductorCLIID) ->
FileIconProvider.Icon` covering all seven cases in one exhaustive,
compiler-enforced switch, each `assetName:` the vendored file with
`assetIsTemplate: true`, tinted like a symbol via `FileIconView`.
Symbol fallback (`terminal`, `.secondary` tint) when an asset fails to
resolve, so a missing file degrades and never blocks a consumer. C8-06
renders this catalog on graph nodes later — keep the API exactly this
shape.

**Licensing posture, to be recorded in ADR 0021 and the reference note
(state it plainly; do not overstate it):** the package is MIT,
"Copyright (c) 2023 LobeHub", with no trademark clause — that covers
redistributing the files. Trademark is a separate regime from copyright
and those marks remain their owners'; our use is *nominative*, i.e.
showing a product's mark solely to identify that product, which is what
every editor does when it shows a tool's logo. Keep it that way: render
the marks unmodified apart from scaling and monochrome tinting, never
imply endorsement or partnership, and never use them as Rafu's own
branding. If a vendor ever objects, the symbol fallback already in the
catalog is the honest degradation path.

### Session identity

- `TerminalProcessSpec.agentProvider: ConductorCLIID? = nil` (additive,
  memberwise-init-safe: `var` + default).
- `WorkspaceTerminalController`: derive `displayName` for agent
  sessions as the CLI display name (e.g. "Claude Code") — follow
  whatever precedence the existing `displayName` uses for spec-based
  sessions; do not break Ensemble-run naming (`roleBadge` paths).
- Terminals panel rows + Control-Tab switcher candidates: when the
  controller's spec has `agentProvider`, render
  `ConductorCLIIcons.icon(for:)` (14 pt, template-tinted) beside the
  name instead of the generic terminal symbol; detail line keeps the
  existing status wording. Both surfaces keep text labels — the icon is
  additive identity, never the only signal.
- `ProcessResourceRegistry`: register agent terminals with kind
  `.agentTerminal` ("Agent Terminal", name = attribution string). The
  registration site is the existing `makeOrReuseView` PID-gated block —
  branch on `agentProvider != nil` before the `.agent` fallback.

### Entry points

- **Terminals panel "+"** becomes a `Menu`: first item "New Terminal"
  (existing behavior, unchanged default action on plain click if the
  control allows; otherwise first menu row), a divider, then one row per
  `options()` result — icon + name, disabled rows show the reason via
  `.help` AND a trailing caption (visible reason, not tooltip-only).
  Ready rows launch immediately with the default model in the workspace
  root (the one-click muxy move).
- **⌘⇧A → the sheet** (`AgentTerminalSheet.swift`, GitHubPublishSheet
  structure, width 440): agent picker (same rows/gating), model field
  (prefilled from `ConductorDefaultModelStore`, curated-list menu when
  the option carries one, free text allowed), starting directory
  (default workspace root; `fileImporter` restricted to inside the
  workspace), footer Cancel / **Launch** (prominent, `.defaultAction`).
  ⌘⇧A verified free (in-use ⌘⇧ after C8: n f g l k p e). Guarded on an
  open workspace.
- **Menu**: `RafuAppCommands.swift` terminal section —
  `Button("New Agent Terminal…")` + `.keyboardShortcut("a", modifiers:
  [.command, .shift])`.
- **Palette**: static `terminal.new-agent` ("New Agent Terminal…") plus
  dynamic per-agent commands `terminal.agent.<id>` ("Agent Terminal:
  Claude Code") for READY agents only — built in `makeCommands()` beside
  the existing conditional Ensemble block.

### WorkspaceSession seam (anchored)

Immediately after the terminal methods block (after
`hideTerminalSession(_:)`, ~line 933) add ONLY:

```swift
var agentTerminalSheetPresented: Bool = false
func presentAgentTerminalSheet()          // guards descriptor != nil
func openAgentTerminal(spec: TerminalProcessSpec)
// terminal.newSession(spec:) + revealTerminalSession(id) — the
// WorkspaceConductorRunLauncher pattern, minus run bookkeeping.
```

`WorkspaceWindowView.swift` `WorkspaceWindowPresentations`: one
`.sheet(isPresented: $session.agentTerminalSheetPresented)` line.

### Behavior details

- Exit: the vendor CLI exiting behaves exactly like a shell exiting
  (existing status/bell pipeline; no special-casing).
- No restoration (ADR 0014) — nothing to do, but a test proves the tab
  resource is non-restorable like other terminals.
- No decorative motion; sheet and menu obey Reduce Motion by default.
- A second agent terminal for the same CLI is fine (sessions are
  independent); no artificial cap beyond the existing terminal limits.

## Tests

- `AgentTerminalTests`:
  - **The no-capability proof (load-bearing):** built spec's environment
    keys == `["PATH"]` exactly — no `RAFU_HANDOFF`, no `RAFU_RUN_DIR`,
    no `RAFU_ENSEMBLE_TOKEN`; argv is executable + expected array;
    `outputLogURL == nil`.
  - Adapter-dir prepend when the executable is off the curated path.
  - Options gating matrix: absent / present-unauthed / ready, with
    reasons; model flag included only for verified CLIs (fixture-driven,
    mirroring the adapter-test fixture pattern).
  - Starting directory must be inside the workspace (reject escape).
  - `openAgentTerminal` creates + reveals a session whose controller
    carries `agentProvider` (FakeConductorAdapter-style fixture spec).
- `TerminalsPanelTests` + `EditorTabSwitcherTests`: agent identity
  (icon mapping + display name) on rows/candidates; plain shells
  unchanged.
- `FileIconAssetsTests`: all seven `agent-*.svg` assets resolve and load
  as `NSImage`; `ConductorCLIIcons` covers every `ConductorCLIID` case
  (`allCases` runtime test alongside the exhaustive switch); each
  vendored file still contains `fill="currentColor"` and carries no
  `<title>`/`style` residue (a normalization regression test — cheap,
  and it catches a careless re-vendor); **the three existing file-tree
  icons are byte-identical to their pre-change state** (the no-regression
  proof).
- `ProcessAttributionTests`: `.agentTerminal` renders "Agent Terminal";
  Ensemble `.agent` rendering unchanged; login shells unchanged.

## Gates

`swift build` 0 warnings; `swift test` AND `swift test --no-parallel`
green; `./script/format.sh --fix` then `--lint` clean; `xmllint
--noout` on all seven vendored SVGs; `./script/verify.sh` runs an SVG
lint step, so confirm the vendored files pass it. HEADLESS ONLY — list the GUI checks
(panel menu, sheet keyboard-only pass, switcher icons, second window)
for the coordinator. Remember the PTY rule: real spawn assertions only
via `Foundation.Process` substitutes or `--no-parallel` (see
`conductor-pty-spawn-and-child-environment.md`).

## Documentation deliverables

ADR 0021 (above; its decision list must include the icon-provenance and
nominative-use clause); NEW `docs/references/agent-terminals.md` (the
env/argv contract, identity surfaces, per-CLI interactive + model-flag
table with verified/hypothesis markers, why capture is off); NEW
`docs/references/agent-icon-assets.md` (provenance: package, pinned
version `1.94.0` + tarball integrity, slug→filename table, the
normalization steps, per-file committed SHA-256, the licensing posture,
the `agent-` prefix rationale and the file-tree-unification follow-up,
and the exact command sequence to refresh the set);
`ensemble-manual-test-plan.md` section **N — Agent terminals** (N1
one-click launch from panel, N2 ⌘⇧A sheet + model override, N3 unauthed
CLI disabled with visible reason, N4 icon + name in tab/panel/switcher,
N5 Resources shows "Agent Terminal", N6 exit behaves like a shell, N7
second window). Intended index rows in the report.

## Handoff report

Delivered behavior; changed paths; test evidence; per-CLI
interactive/model-flag table (verified vs hypothesis); the GUI checks
for the coordinator; remaining risks; branch; every commit message;
`git rev-parse HEAD`.

---

## Goal-mode agent prompt (copy into the worktree agent)

```
You are a phase agent for the Rafu repository, working in a dedicated git
worktree. GOAL MODE: you own the outcome end to end; do not ask for
permission between steps; finish or report precisely why you cannot.

Branch: conductor/at-01-agent-terminals. Preflight: run `git status
--short --branch` ONCE. On this branch + clean tree → proceed. Detached
HEAD or wrong branch + clean tree → checkout the branch if it exists,
else `git checkout -b conductor/at-01-agent-terminals main`, then
proceed and say so. Dirty tree with edits you did not make → STOP. This
plan has NO C8 prerequisites — it runs in wave 1, parallel with C8-02;
Sources/RafuApp/Conductor/Ensemble/ and Sources/RafuCore/Ensemble/ are
C8-02's territory and must not exist in your diff.

GOAL: implement docs/plans/phases/conductor/AT-01-agent-terminal-sessions.md
— agent terminals: every discovered + authed agent CLI launchable as an
interactive terminal session in one action (terminals-panel menu, ⌘⇧A
sheet with model + starting directory, palette, menu), with agent
identity in the editor tab, terminals panel, Control-Tab switcher, and
Resources ("Agent Terminal" kind). You also CREATE the seven-CLI icon
catalog (ConductorCLIIcons + seven real vendor marks vendored from
lobe-icons under the `agent-` prefix, pinned and normalized per the
plan + staging asserts) and the per-CLI interactive-launch probe table
— both transferred to this plan; later C8 phases consume them. Plus
ADR 0021 recording the decision. The plan file is your authoritative design
contract, edit list, and test list — read it FIRST, then AGENTS.md, the
conductor README ground rules, AT-execution-plan.md (the ownership
transfers), ADR 0004/0014/0018 (and C8-01's amendment text as contract
if it has not merged yet), and
conductor-pty-spawn-and-child-environment.md. Use swiftui-expert-skill
and swift-concurrency-pro.

HARD CONSTRAINTS: an agent terminal carries ZERO Ensemble capability —
environment is exactly ["PATH"] (curated, adapter-dir prepended when
needed), no RAFU_* keys, no token, no output capture, no manifest (a
test must prove the env contract); argv arrays only; vendor model flags
are used only where YOUR probe table records a verified shape —
unverified CLIs launch bare with the reason shown, never guessed flags;
disabled agents stay visible with stated reasons (text, not tooltip- or
color-only); sessions register as .agentTerminal rendering "Agent
Terminal" (never "Ensemble Agent"); terminals are never restored; icons
are the REAL vendor marks vendored from the pinned lobe-icons version in
the plan (never hand-drawn placeholders, never re-drawn or restyled
marks beyond scaling and monochrome tinting, never used as Rafu's own
branding), committed under the `agent-` prefix with per-file SHA-256
recorded, and the three existing file-tree SVGs must remain
byte-identical; user-visible strings say "Agent Terminal", internal
symbols use the AgentTerminal* prefix; your ConductorCore.swift edit
stays inside the TerminalProcessSpec region and your WorkspaceSession
edits stay at the anchored terminal seam (C8-02 edits other regions of
both files in parallel). DO NOT create or touch
Sources/RafuApp/Conductor/Ensemble/, Sources/RafuCore/Ensemble/, the
run-engine files, adapters, Package.swift, EditorCanvasView, Settings,
or script/ beyond the four assert lines. HEADLESS ONLY — never run
build_and_run.sh or launch Rafu.app; obey the PTY-spawn test rule (no
real PTY asserts under parallel swift test).

DEFINITION OF DONE:
1. One-click launch from the terminals-panel menu and full launch from
   the ⌘⇧A sheet both produce a revealed session whose spec passes the
   no-capability environment test; per-agent palette commands exist for
   ready agents.
2. The gating matrix (absent / unauthed / ready, with reasons) and the
   model-flag verified-only rule are test-covered.
3. Agent identity renders in panel rows, switcher candidates, and
   Resources, with plain shells and Ensemble runs unchanged
   (regression-tested).
4. ConductorCLIIcons resolves all seven ConductorCLIID cases
   (exhaustive switch + allCases test); all seven vendored agent-*.svg
   files pass xmllint, load as NSImage, keep fill="currentColor", carry
   no <title>/style residue, and are staged-asserted; the three existing
   file-tree icons are proven byte-identical; the per-CLI
   interactive/model-flag probe table is recorded in agent-terminals.md
   with verified/hypothesis markers.
5. ADR 0021 written (including the icon-provenance and nominative-use
   clause); agent-terminals.md and agent-icon-assets.md reference notes
   written, the latter carrying the pinned version, per-file SHA-256,
   and the refresh procedure; manual-test-plan section N added; intended
   index rows in the report only.
6. swift build 0 warnings; swift test AND swift test --no-parallel
   green; format --fix + --lint clean.
7. Work committed locally in verified stages; never push/merge/rebase/
   checkout main. Shared-file needs are a HANDOFF with a proposed diff.

FINAL REPORT (mandatory): delivered behavior; changed paths; test
evidence; the per-CLI interactive/model-flag table (verified vs
hypothesis); the GUI checks the coordinator must run on main; remaining
risks; branch name; every commit message; last commit id from
`git rev-parse HEAD`.
```
