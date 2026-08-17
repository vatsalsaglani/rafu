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
