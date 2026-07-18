# Terminals as editor tabs — CLI agents (Claude Code, Codex) inside Rafu

## Status

Planned (2026-07-18). Direction brief only — no implementation started.

**2026-07-19 update:** increment T1's core placement change (terminal
sessions presented as first-class editor tabs) landed narrower than this
brief as part of the 15-item `docs/issues/issues_ui.md` fix batch (issue
#4; 789 tests, 0 warnings, lint clean) — see
[ADR 0014](../../decisions/0014-terminal-as-editor-tab.md). Terminal tabs
are ephemeral (not restored across relaunch), which is narrower than T2's
placeholder-restoration design below; T2 (full lifecycle policy), T3
(agent-workflow polish), and T4 (docs/measurement close-out) remain
planned. TD1–TD4 below are still open.
Sibling to [`ui-flat-modern-refresh.md`](ui-flat-modern-refresh.md) (adopts
its design language) and to
[`git-experience-and-worktrees.md`](git-experience-and-worktrees.md)
(worktree window + agent terminal is the combined workflow). File anchors
reflect the tree at `19cdfd7`; the repository wins when they disagree.

## Product intent

Today the terminal is one bottom panel per window (ADR 0004, with tabs
inside the panel). The user's real workflow is running CLI coding agents
(Claude Code, Codex) beside the editor. Making a terminal openable **as an
editor tab — a peer of files** turns Rafu into the complete loop: agent in
one tab/split, its diff and the files it touches in the next, Source
Control worktrees for its lane. Rafu's thesis is literally "focused edits
beside terminal coding agents" — this brings the agent inside.

Explicitly unchanged: Rafu never runs agent/task commands itself, no task
runners, no auto-execution, no PTY protocol parsing beyond what SwiftTerm
already does. The user types; Rafu hosts.

## Existing assets to build on (verified)

- `WorkspaceTerminalManager` / `WorkspaceTerminalController` already own N
  independent SwiftTerm sessions per window (login shell at workspace
  root, themed, bounded scrollback, Restart-on-exit, shutdown on
  workspace switch) — the engine is done; this phase changes *placement*.
- `EditorLayout` tabs already host non-file resources (Git diff/blame use
  editor-hosted presentations with identity strings); tab drag/split/drop
  machinery is resource-generic (`EditorDragPayload`).
- `ProcessResourceRegistry` + Resources popover — per-shell RSS rows.
- Document hibernation (ADR 0006) — terminals need an explicit exemption
  policy (below), decided here rather than discovered as a bug.

## Design (adopts the UI-refresh language)

- Tab: terminal glyph + title (OSC 0/2 window title when the program sets
  one — Claude Code does — else shell name), activity states: running
  foreground command = subtle pulse-free "busy" dot; **bell/output while
  unfocused = attention dot** (this is the "agent finished" signal —
  color + symbol, never color alone).
- Tab tooltip: cwd (OSC 7, already tracked for panel tabs) + shell + PID.
- In-tab chrome: none beyond the standard tab — the terminal fills the
  pane; the panel's header stays panel-only.

## Increments

### T1 — Tab resource + placement

`EditorLayout` gains a terminal resource (`.terminal(sessionID)`);
`WorkspaceTerminalManager` sessions become placement-agnostic (panel or
tab). "New Terminal Tab" via File menu, palette, and shortcut (decision
TD1); "Open Terminal Here" on sidebar folder context menu + active file's
directory variant. Terminal tabs participate in tab switching, splits,
and drag/drop like any file tab (one live view per session — a session
shown in a split is *moved*, not mirrored; AppKit view reparenting, the
same constraint the panel tabs already handle).

### T2 — Lifecycle policy (the correctness core)

- **Hibernation exemption:** a terminal tab is never hibernated (a PTY
  can't be snapshot/restored) — it stays mounted but its *view* may be
  detached from the hierarchy when not visible; the shell keeps running.
  Working-set accounting: terminals do not consume file-tab hibernation
  slots; instead a hard cap of **6 live terminal sessions per window**
  (panel + tabs combined; 7th request → alert naming the cap, per the
  bounded-resources rule).
- **Close semantics:** closing a terminal tab prompts when the shell has
  a foreground child process (detected via `tcgetpgrp` vs shell pgid —
  cheap, no polling; checked at close time only); an idle shell at the
  prompt closes silently. Close always terminates that session's shell
  (SIGHUP), mirroring panel-tab close.
- **Restoration:** shells are never auto-respawned. A restored window
  recreates terminal *tabs* as inert placeholders — cwd + title + a
  single "Start Shell" button — so layout survives but no process runs
  without an explicit user action (trust/safety invariant).
- **Window close/app quit:** existing panel semantics extend unchanged
  (shutdown on workspace switch; confirm-on-quit if any terminal has a
  foreground process — new, decision TD3).

### T3 — Agent-workflow polish

- Attention dot on unfocused terminal tabs on bell/output-after-quiet
  (SwiftTerm bell callback + a low-cost "output resumed after ≥5s idle"
  edge — no timers while quiet).
- cwd-aware spawn: "Open Terminal Here" starts in the folder; new
  worktree window + terminal tab is the two-step agent-lane setup.
- Resources popover lists each session (already registry-backed) with
  its tab/panel placement named.
- Session-move commands: "Move Terminal to Editor Area" / "Move to
  Panel" (menu + palette) — placement flexibility without duplicating
  sessions.

### T4 — Docs + measurement close-out

Release-build RSS with 3 live terminal tabs (one running Claude Code)
recorded against the ADR 0004 expectation (tens of MB after first open);
scrollback bound re-verified per session; reference note
(`docs/references/terminal-integration.md` update: placement model,
lifecycle table, cap rationale); ADR flip with the user.

## Durable decision

ADR **0014** (authored in-lane, Proposed): terminals as editor-tab peers —
supersedes ADR 0004's single-bottom-panel *placement* boundary while
keeping every other ADR 0004 bound (lazy spawn, bounded scrollback, no
task runners, no automatic command execution, per-window ownership).
Records the 6-session cap, hibernation exemption, close/restoration
semantics.

## Open decisions (user)

- **TD1** Shortcut for "New Terminal Tab": ⌃⇧T (recommended — sits beside
  the existing ⌃` panel toggle and ⌃⇧` new-panel-tab; ⌘T stays untouched
  for a future file-tab reopen) vs ⌘⇧T vs menu/palette-only.
- **TD2** Cap value: 6 sessions/window (recommended) vs 4 vs 8.
- **TD3** Quit confirmation when any terminal has a foreground process:
  yes (recommended — an agent mid-task is exactly the thing not to kill
  silently) vs rely on window-close confirmation only.
- **TD4** Placeholder restoration (recommended) vs not restoring terminal
  tabs at all.

## Verification contract

Per increment: build 0 warnings, full suite green, lint, `--verify`;
lifecycle unit tests (cap, close-prompt gating, placeholder restoration
state) plus a manual pass: run Claude Code in a terminal tab through a
real prompt cycle, switch tabs/splits/windows during output, confirm the
attention dot, hibernate-pressure test with 12 file tabs + 3 terminals,
second window, VoiceOver reachability of every new command; typing path
in *editor* tabs unaffected while a terminal streams output (measured
glance, no main-thread stalls).
