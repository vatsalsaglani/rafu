# UX-03 — Agent identity everywhere, and an inline agent launcher

- **Status:** Ready. Branch: `ux/03-agent-identity` (from `main`).
  Wave 1 — parallel with UX-00. Fully disjoint from it: UX-00 owns canvas
  routing and control styles, this plan owns the terminals panel and the
  icon catalog.

## Goal

Make every agent-bearing surface show the right vendor mark, and replace the
terminal `+` **menu** with an inline agent launcher in the panel — icons, an
honest loading state, and keyboard shortcuts.

## The finding that drives this plan

Agent icons render as **tiny dots** in the terminal `+` menu but correctly at
size 18 in the New Ensemble sheet. Same `FileIconView`, same assets, same
catalog — the difference is the container.

**SwiftUI `Menu` on macOS renders items through AppKit's `NSMenu`, which does
not draw arbitrary SwiftUI image views.** `Label(_:systemImage:)` survives
because AppKit can resolve an SF Symbol; an `Image(nsImage:)` backed by a
vendored SVG does not.

So this is not a bug in the catalog and must not be "fixed" there. The fix is
to stop rendering agent identity inside a menu — which is also what the user
asked for, and which fits the standing no-popups preference. Verify the
mechanism yourself before building on it (put a plain `Label` beside a
`FileIconView` in one menu row and observe), and record what you find.

## Read first

`AGENTS.md` (interface rules: glyph + text, never icon-only for meaning;
Reduce Motion; keyboard reachability);
`docs/references/agent-terminals.md` (AT-01: the launch service, availability
gating, per-CLI verified argv);
`docs/references/agent-icon-assets.md` (the pinned lobe catalog and its
normalization);
`Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift` (the `+` Menu at
~line 108-125, session rows at ~245-275);
`Sources/RafuApp/Terminal/TerminalsPanelModel.swift`;
`Sources/RafuApp/Terminal/AgentTerminalLaunchService.swift` (`options()` is
async — it probes real CLIs, which is why a loading state is required);
`Sources/RafuApp/Support/FileIconProvider.swift`;
`swiftui-expert-skill`.

## Owned paths

- `Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift`
- `Sources/RafuApp/Terminal/TerminalsPanelModel.swift`
- `Sources/RafuApp/Conductor/ConductorCLIIcons.swift`
- `Sources/RafuApp/Support/FileIconProvider.swift` (icon resolution only)
- `Resources/FileIcons/` (only if an asset must be corrected — say why)
- `Tests/RafuAppTests/TerminalsPanelTests.swift`, `FileIconAssetsTests.swift`
- `docs/references/agent-terminals.md` (append the NSMenu finding);
  this plan's status line.

**Forbidden:** `EditorCanvasView.swift`, `WorkspaceSession.swift`,
`RafuControlStyles.swift` (UX-00 owns it — consume the styles),
`ConductorRunsPanelView.swift` (UX-01), `Settings/**` (UX-02),
`AgentTerminalLaunchService.swift`'s env/argv contract (consume it; AT-01's
tokenless-environment guarantee is not yours to change).

## Design contract

### 1. The inline agent launcher

Replace the `+` **Menu**'s agent section with an inline section in the
terminals panel, below the existing New Terminal affordance. The `+` control
may keep a small menu for shell choice (plain `Label`s render fine there);
agents move out of it entirely.

Section anatomy, top-pinned like every other panel section:

- Header "Agents" with a count once resolved.
- **Loading state while `options()` probes** — it spawns real CLIs, so this is
  visibly slow on a cold run. Show a determinate-looking row per known
  provider in a pending style, or one honest "Checking installed agents…"
  row. Never render an empty list that later fills in silently; that reads as
  "no agents installed", which is a lie during probing.
- One row per provider: **vendor mark** (`ConductorCLIIcons`, ~16 pt) +
  display name + availability.
- Ready rows launch on click, and expose a keyboard shortcut hint.
- Unavailable rows stay **visible and disabled with the reason in text**
  ("not installed", "not logged in — run `claude login` in a terminal") —
  AT-01's honesty rule, unchanged. Never colour alone.
- Every row reachable by keyboard; VoiceOver label carries name + state +
  reason.

Reuse `AgentTerminalLaunchService` exactly as AT-01 built it — this plan
changes presentation, not launching. Do not re-probe on every render:
resolve once in a `.task`, refresh on an explicit user action.

### 2. Shortcuts

The user asked for "shortcuts to open those agents". ⌘⇧A already opens the
Agent Terminal sheet (AT-01). Add **per-agent** activation that does not
collide: prefer showing the existing shortcut on the row rather than minting
seven new global chords, and if you do add any, verify against the in-use set
(⌘⇧: n f g l k p e a) and say what you checked. Seven new global shortcuts is
almost certainly the wrong answer; a focused list with Return-to-launch is
almost certainly the right one.

### 3. Icon fidelity and the file-tree divergence

The user observed the Codex icon differs between the file tree and agent
surfaces. That is real: the file tree uses the pre-existing `codex.svg`
(a different source), agent surfaces use AT-01's pinned `agent-codex.svg`.

Decide and record, do not silently unify: the file-tree assets serve
`.codex`/`.claude` **directories**, the agent assets serve **providers**.
If a mark is genuinely wrong or unrecognisable at 16 pt, correct the agent
asset from the pinned lobe source (`agent-icon-assets.md` has the exact
procedure and checksums) rather than pointing agent surfaces at the file-tree
asset. Whatever you choose, state it in the reference note so the divergence
is a decision rather than an accident.

Sweep every agent-bearing surface for correct rendering: the terminals panel
rows, the session rows, the Control-Tab switcher, Resources. Anywhere a mark
fails to appear, determine whether the container is a menu before touching
the catalog.

## Tests

- `TerminalsPanelTests`: loading state precedes resolution and is not an
  empty list; ready/unavailable rows carry name, state, and reason;
  launching a ready row calls the launch service once with that provider;
  a disabled row cannot launch.
- `FileIconAssetsTests`: every `ConductorCLIID` resolves an asset (already
  present — extend if you change the catalog).
- A test pinning that agent identity does not regress in the session rows
  and switcher.

## Gates

Standard build/parallel-per-stage/serial-once/format. Delete `.build` last.

**Run `./script/build_and_run.sh --verify`** — this plan is almost entirely
visual, so a Lightning GUI pass is required, not optional: the agent section
renders with real marks, the loading state is visible on a cold start,
disabled reasons are readable, and keyboard-only operation works. Never
`pkill`/`pgrep` a bare `Rafu`.

## Documentation deliverables

Append to `docs/references/agent-terminals.md`: **the NSMenu rendering
limitation** (with the evidence you gathered), the inline-launcher contract,
the loading-state rule, and the file-tree-vs-agent asset divergence decision.
That first item is the reusable platform nuance — it will catch the next
person who tries to put a vendor mark in a menu.

## Handoff report

Delivered; changed paths; your evidence for the NSMenu limitation; the
asset-divergence decision and why; shortcut collisions you checked; test
evidence; the Lightning GUI checks you ran (describe what the loading state
looks like); branch; commit messages; `git rev-parse HEAD`.

---

## Goal-mode agent prompt

```
You are a phase agent for the Rafu repository, working in a dedicated git
worktree. GOAL MODE: you own the outcome end to end; do not ask for
permission between steps; finish or report precisely why you cannot.

Branch: ux/03-agent-identity. Preflight: run `git status --short --branch`
ONCE. On this branch + clean tree → proceed. Detached HEAD or wrong branch
+ clean tree → checkout it if it exists, else `git checkout -b
ux/03-agent-identity main`, then proceed and say so. Dirty tree with edits
you did not make → STOP.

GOAL: implement docs/plans/phases/ux/UX-03-agent-identity-and-terminals.md
— replace the terminal + menu's agent section with an inline agent
launcher in the terminals panel (vendor marks, honest loading state,
keyboard reachable, disabled rows stating why), and make every
agent-bearing surface show the right mark. Read that plan FIRST, then
AGENTS.md, docs/references/agent-terminals.md, and
docs/references/agent-icon-assets.md. Use swiftui-expert-skill.

THE KEY FINDING, which you must verify before building on it: agent icons
render as tiny dots inside the SwiftUI Menu but correctly at size 18 in a
sheet, because macOS renders Menu items through AppKit's NSMenu, which
does not draw arbitrary SwiftUI image views. This is NOT a catalog bug —
do not "fix" ConductorCLIIcons or the assets to chase it. Confirm the
mechanism yourself, record the evidence, and solve it by moving agent
identity out of the menu.

HARD CONSTRAINTS: consume AgentTerminalLaunchService unchanged — its
tokenless PATH-only environment is AT-01's guarantee and not yours to
alter; unavailable agents stay visible and disabled WITH the reason in
text, never colour alone; probe once in a .task, never per render; do not
mint seven new global keyboard shortcuts without checking the in-use set
(⌘⇧: n f g l k p e a) and saying what you checked — a focused list with
Return-to-launch is very likely the right answer instead; the file-tree
and agent icon divergence is a DECISION to record, not something to
silently unify. DO NOT touch EditorCanvasView, WorkspaceSession,
RafuControlStyles (UX-00 owns it), ConductorRunsPanelView (UX-01), or
Settings (UX-02).

Local builds are Rafu Lightning. You MUST run ./script/build_and_run.sh
--verify — this work is visual and a headless pass proves almost nothing.
Never pkill or pgrep a bare "Rafu": that is the user's editor.

DEFINITION OF DONE:
1. Agents launch from an inline panel section with real vendor marks; the
   + menu no longer carries agent identity.
2. A loading state is visible while probing and is never an empty list.
3. Disabled rows state their reason in text; everything is keyboard
   reachable with VoiceOver labels carrying name + state + reason.
4. Marks verified correct in panel rows, session rows, Control-Tab, and
   Resources.
5. build 0 warnings; parallel per stage; serial once at the end; format
   --fix + --lint clean.
6. agent-terminals.md carries the NSMenu finding with your evidence and
   the asset-divergence decision; intended index row in the report only.
7. Committed in verified stages; `rm -rf .build` last. Never
   push/merge/rebase/checkout main.

FINAL REPORT: delivered; changed paths; your NSMenu evidence; the
divergence decision; shortcut collisions checked; test evidence; the
Lightning GUI checks with a description of the loading state; branch;
every commit message; last commit id.
```
