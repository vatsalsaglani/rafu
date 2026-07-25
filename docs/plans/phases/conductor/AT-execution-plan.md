# AT — Agent Terminals: execution plan (two worktree plans)

- **Status:** Approved for execution (2026-07-26). Follows the C8 waves in
  [`C8-execution-plan.md`](C8-execution-plan.md).
- **Inspiration:** muxy.app's "agent terminal" — the terminal itself is
  agent-aware: pick Claude Code / Codex / any installed CLI and it opens
  running that agent in the project directory, with agent identity in the
  chrome. Rafu builds the same thing natively on machinery it already has.

## What this is (and is not)

An **agent terminal** is an ordinary Rafu terminal session whose process
is a discovered, authed vendor CLI launched interactively in the
workspace — instead of a login shell where the user types `claude`
themselves. It is:

- **User-initiated and visible** — one explicit action per session
  (ADR 0018's "nothing executes without a visible, user-initiated run"
  is untouched; this is the user opening a terminal).
- **Tokenless by default** — no `RAFU_ENSEMBLE_TOKEN`, no grant, no
  manifests, no worktree, no output capture. It is NOT an Ensemble run
  and never appears on the graph canvas.
- **Registry-driven** — the launchable list is exactly the adapter
  registry's discovered + authed set; absent/unauthed CLIs show disabled
  with the stated reason (same honesty as everywhere else).
- **Identity-carrying** — the session shows the agent's icon and name in
  the editor tab, the terminals panel, the Control-Tab switcher, and the
  Resources surface ("Agent Terminal", never "Ensemble Agent").

**The Ensemble connection** is a single, honest seam: the same launch
sheet has a "Grant Ensemble coordination" toggle. On → the launch routes
through `ConductorCoordinatorLauncher` (token minted at spawn, grant
visible, lands on the graph). Off → plain agent terminal. A live
terminal can never be *promoted* — environment is fixed at spawn — so
the bridge offers "Relaunch as Ensemble Coordinator…" instead, and the
UI says so plainly.

## Decisions locked

1. New **ADR 0021** (part of AT-01) narrows ADR 0004: the embedded
   terminal may spawn a vendor agent CLI interactively at explicit user
   request; argv arrays only; environment is curated `PATH` (plus the
   adapter's probed directory prepended) and NOTHING else — no
   `RAFU_HANDOFF`, no `RAFU_RUN_DIR`, no token.
2. Internal symbols use the **`AgentTerminal*`** prefix (they live in the
   Terminal domain and consume the Conductor adapter registry
   read-only); user-visible strings say **"Agent Terminal"**. Recorded in
   ADR 0021's naming note, same pattern as the `Ensemble*` RafuCore
   exception in the ADR 0018 amendment.
3. Agent terminals are never restored across relaunch (ADR 0014 rule,
   unchanged) and register with `ProcessResourceRegistry` under a
   distinct kind rendering **"Agent Terminal"**.
4. Model selection: default from `ConductorDefaultModelStore`, curated
   list from the adapter where available, free-text override. Vendor
   flag shapes are HYPOTHESES until probed (adapter ground rule).
5. **Agent icons are the real vendor marks**, vendored from
   `@lobehub/icons-static-svg` (MIT, pinned `1.94.0`) under an `agent-`
   filename prefix, normalized to Rafu's template-icon contract. This
   reverses the earlier "hand-drawn letterform placeholders" draft: a
   product's own mark identifies it better than an initials box, the set
   is uniform (24×24, `fill="currentColor"`) where Rafu's three existing
   file-tree icons are not, and the prefix keeps the file tree
   untouched. Use is nominative — identify the product, never imply
   endorsement, never restyle a mark, never adopt one as Rafu branding;
   the catalog's symbol fallback is the degradation path. Provenance,
   per-file SHA-256, and the refresh procedure live in
   `docs/references/agent-icon-assets.md`; the clause is recorded in
   ADR 0021.

## The two plans

| # | Plan document | Branch | Earliest start |
|---|---|---|---|
| AT-01 | [`AT-01-agent-terminal-sessions.md`](AT-01-agent-terminal-sessions.md) | `conductor/at-01-agent-terminals` | **NOW — C8 wave 1**, parallel with C8-01 and C8-02 |
| AT-02 | [`AT-02-ensemble-bridge.md`](AT-02-ensemble-bridge.md) | `conductor/at-02-ensemble-bridge` | after C8 wave 3 AND AT-01 merge |

**Why AT-01 can join wave 1 — two ownership transfers (recorded here,
reflected in the C8 plan docs):**

1. **AT-01 owns the agent-icon catalog.** `ConductorCLIIcons.swift`, the
   seven vendored `agent-*.svg` marks, and the `build_and_run.sh`
   staging asserts move from C8-06 to AT-01.
   C8-06 (wave 2) consumes the catalog; its preflight verifies it
   exists. Missing SVG assets degrade to symbol fallbacks inside the
   catalog, so nothing else ever blocks on artwork.
2. **AT-01 owns the per-CLI interactive-launch probe table** (which CLIs
   accept a bare interactive launch, which take a model flag, verified
   vs. hypothesis), recorded in `docs/references/agent-terminals.md`.
   C8-03 (wave 2) reuses that table for the coordinator launcher instead
   of deriving its own, extending it only where the coordinator path
   exposes gaps.

Wave-1 conflict check: C8-01 is docs-only. C8-02 and AT-01 both touch
`ConductorCore.swift` and `WorkspaceSession.swift` but in disjoint
regions (manifest fields ~line 230 vs `TerminalProcessSpec` ~line 577;
gate-attention hook ~line 727 vs the terminal seam after
`hideTerminalSession` ~line 933) — the coordinator merges the two
branches serially and resolves at most trivial adjacency. AT-01's
command/palette/sheet edits touch files no wave-1 C8 plan touches;
C8-06/C8-07 branch later from a `main` that already contains them.

AT-02 stays late: it consumes `ConductorCoordinatorLauncher` (C8-03),
the skill-installed check (C8-05), and extracts the grant form from
`EnsembleStartSheet` (C8-07). The two AT plans are serial: AT-02 edits
the sheet AT-01 creates.

## Shared-file ownership

| Shared file | AT-01 | AT-02 |
|---|---|---|
| `Sources/RafuApp/Conductor/ConductorCore.swift` | one additive field on `TerminalProcessSpec` (~line 577 region; C8-02 edits the manifest region in parallel — serial merge, coordinator resolves) | no |
| `Sources/RafuApp/Models/WorkspaceSession.swift` | sheet flag + open seam anchored after `hideTerminalSession` (~933; C8-02's hook is at ~727) | no |
| `Sources/RafuApp/Views/WorkspaceWindowView.swift` | one `.sheet` line | no |
| `RafuAppCommands.swift` / `CommandPaletteView.swift` | agent-terminal entries (no C8 wave-1 plan touches these; C8-06/07 branch after AT-01 merges) | no |
| NEW `Sources/RafuApp/Conductor/ConductorCLIIcons.swift` + `Resources/FileIcons/agent-*.svg` (seven, vendored) | **creates (transferred from C8-06)** | no |
| `script/build_and_run.sh` | icon staging asserts (transferred from C8-06) | no |
| `Sources/RafuApp/Views/AgentTerminalSheet.swift` | creates | extends (toggle + grant form) |
| `Sources/RafuApp/Views/EnsembleStartSheet.swift` | no | grant-form extraction + cross-link |

## Worktree creation (coordinator, on `main`)

```bash
# NOW — with the C8 wave-1 worktrees
git worktree add ../rafu-at-terminals -b conductor/at-01-agent-terminals
# after C8 wave 3 AND AT-01 merge
git worktree add ../rafu-at-bridge    -b conductor/at-02-ensemble-bridge
```

## Definition of done for AT as a whole

1. Every discovered + authed CLI is one action away from an interactive
   session in the workspace (panel menu, ⌘⇧A sheet, palette, menu), with
   its icon and name in every terminal surface; absent/unauthed CLIs are
   visible-but-disabled with reasons.
2. A plain agent terminal provably carries no Ensemble capability (env =
   PATH only; a test asserts no `RAFU_*` keys, no token).
3. The same sheet launches a granted coordinator via the C8-03 path when
   the toggle is on, landing on the graph canvas; "relaunch as
   coordinator" exists in place of impossible promotion.
4. ADR 0021 records the decision; the manual test plan gains sections
   N and O.
