# ADR 0024: Terminal Group v2 limits and pane metadata

- **Status:** Accepted
- **Date:** 2026-08-17

## Context

Terminal Groups v1 used one pane bound for several different resources. This
made a full group consume the window live-session capacity and block a new
group. Pane names and theme colors also need a typed runtime contract before
the editor and sidebar can update them by pane identity.

## Decision

Terminal Group limits are independent, bounded values:

- 20 open or parked groups per workspace window;
- 10 retained panes per group;
- 200 retained panes per workspace window;
- 200 live terminal sessions per workspace window; and
- 32 saved layouts per workspace.

The 200-live-session value is an explicit resource ceiling, not a promise that
Rafu can sustain 200 processes. Release-build memory and process measurements
must validate the practical limit before a distribution release. Capacity
failures are typed and non-mutating. Runtime and saved identities remain
separate.

Pane metadata is limited to an optional name of 80 Unicode scalars and an
optional theme-token color. Commands address a runtime pane by
`TerminalPaneID`. Saved layouts may persist only these explicit values. They
must not persist OSC titles, custom hex colors, output, commands, environment,
process details, provider/model values, tokens, or Agent/Ensemble capability
data.

This ADR supersedes only the numeric Terminal Group limits in ADR 0023 and the
shared six-live-session statement in ADR 0018. All process, authentication,
restoration, and user-start safety rules remain unchanged.

## Consequences

The capacity manager must use the correct independent limit for each resource.
Pane rename and theme-color operations can be validated without constructing a
process or reading a saved layout. Existing saved records remain compatible.

## Revisit trigger

Release measurement that cannot meet the resource budget, or a requirement for
unbounded groups, panes, or live processes, requires a new decision.

## Related

ADR 0018, ADR 0023, `TerminalGroupModel.swift`, and TG-100.

## Amendment 1 (2026-11-12): Ensemble terminals have no count limit

The user directed: "We shouldn't have any soft/hard limit on number of
terminal agents on the canvas."

- The 20-group, 200-retained-pane and 200-live-session bounds above apply to
  Terminal Group **editor tabs** only. A group that belongs to an Ensemble card
  is exempt from all three. `TerminalGroupRuntime.ensembleGroupIDs` records
  which groups are exempt; `windowGroupCount`, `retainedPaneCount` and
  `liveSessionCount` do not count them. Groups are marked when an Ensemble
  creates them (`insertStoppedSavedGroup(_:ensemble: true)`), when a saved
  board restores them, and when a tab moves onto an Ensemble.
- A group stays exempt for as long as it exists, also after its card is removed
  and the group is parked, or after it is shown as a tab again. This is a known
  loophole and it is bounded by the Ensemble card limit below.
- The 10-pane group bound, the 32 saved-layout bound and every per-message,
  queue and byte bound are unchanged.
- The ADR 0025 presentation-lease cap of four live Ensemble terminals is
  removed. The lease still says which board shows a terminal; it no longer
  counts.
- An Ensemble payload in a saved board holds one record per terminal card
  (`TerminalGroupWorkspaceRestoration.maximumEnsembleOpenGroups`, equal to
  `CanvasLimits.cards`); a window payload keeps 20.
- `CanvasLimits.cards` (100 nodes of all kinds per board) and
  `CanvasLimits.connections` (200) stay. They are document size bounds for every
  node kind, not terminal limits. Remove them only with a new decision.
- Rafu does not claim 200+ live shells are cheap. Each live Ensemble terminal
  mounts a native terminal view and a PTY. The user accepted this cost.

Supersedes the 200-live-session and 20-group statements for Ensemble terminals,
and the "four surfaces per window" sentence of ADR 0025. ADR 0023 stays
unchanged for Terminal Groups. See `docs/references/ensemble-agent-terminal-tools.md`
section 9 and section 11.
