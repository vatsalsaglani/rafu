# Ensemble graph canvas

- Applies to: the editor-hosted Ensemble graph, its Runs-panel Activity feed,
  and coordinator attribution introduced by C8-06
- Last verified: Swift 6.3.3, Xcode 26.6, macOS 26.5.2, 2026-07-26

## Projection contract

The graph is a read-only projection. It may operate a run through existing
controller verbs, but it never edits workflow topology, creates steps, or
persists layout. Workflow and agent Markdown files remain the authoring
surface.

`ConductorGraphModel.build` consumes three bounded value snapshots:

| Input | What it contributes |
|---|---|
| `[ConductorRunManifest]` | Durable run identity, `startedBy`, steps, artifact dependencies, status, and gates |
| `[String: ConductorWorkflowState]` | Ephemeral refinement for controllers still owned by this window |
| `[CoordinatorNodeInput]` | Live or recently ended coordinator identity, provider, terminal, and timestamps |

The pure model deduplicates and sorts inputs before assigning a simple
column-major layout. Coordinator roots occupy column zero. A manifest with no
`startedBy` is an orphan root; an unknown `startedBy` synthesizes an ended
coordinator root so durable runs never silently lose attribution. Steps chain
left to right, artifact inputs add producer-to-consumer edges, and an open
step or merge gate appends a gate node. An unresolved artifact input degrades
to a textual waiting state without inventing an edge.

`ConductorGraphRefreshInput` snapshots observation-driven values before
SwiftUI's structured `.task(id:)` calls an off-main `@concurrent` projection.
The caller checks cancellation before publishing the result.
`ConductorGraphLayout` precomputes node centers and canvas size outside
`View.body`; the edge `Canvas` only reads those points. This keeps a live state
update from moving layout math into SwiftUI's render path.

## State precedence and node verbs

Run nodes reuse `ConductorRunPresentation.overallStatus(for:)` and
`graphNode(for:live:)`. Views switch on `EnsembleGraphState`, never on a
symbol string. Every state has both a shape-distinct glyph and a text label;
color is supplementary.

| Semantic state | Visible primary path |
|---|---|
| Pending | Show Run Detail |
| Running step | Reveal Terminal |
| Blocked/waiting | Show Run Detail; dependency remains in the detail line |
| Awaiting step gate | Approve, Revise, Abort |
| Completed step | Open Artifact |
| Interrupted step | Retry, Abort, Keep Worktree when present |
| Failed step | Open Evidence, Retry |
| Merge gate | Open Diff, Apply, Discard with dirty-worktree confirmation |

Run, step, and gate cards also expose **Show Run Detail**. Context menus
repeat each applicable verb. Coordinator cards reveal their recorded
terminal while live and remain selectable, plainly marked ended, after the
session disappears.

## Why node cards use Buttons

The edge layer is decorative and accessibility-hidden. Each node's primary
surface and every verb is a real SwiftUI `Button`, not a canvas hit region or
tap gesture. This supplies macOS keyboard activation, Full Keyboard Access,
semantic accessibility actions, and a visible theme `focusRing`. Model output
is column-major, and `ForEach` preserves that order for VoiceOver traversal.
There is no decorative animation on state changes.

## Provider icon and Activity policy

Every graph node renders `ConductorCLIIcons.icon(for:)` at badge scale with
the CLI display name in `.help` and its accessibility label. A synthesized
node whose provider is unavailable still renders the generic terminal
fallback and says "Unknown provider." C8-06 consumes the shared catalog; it
does not own vendor assets or icon coverage tests.

The Runs panel Activity segment subscribes to
`ConductorEnsembleEventCenter.shared`, filters heartbeat and foreign-workspace
events, and keeps at most 200 newest-first rows. Its subscription identity
includes the current root and run IDs so a post-attach manifest reload
replays the relevant in-memory ring rather than missing initial events. Rows
show a provider mark when resolvable, relative time, one bounded summary, and
only an **Open Run** verb. Run rows render `via <coordinator label or
id-prefix>` whenever `startedBy` exists.

## Reproduction or evidence

Pure tests cover deterministic placement, coordinator grouping and ended-root
synthesis, artifact edges, gate nodes, unresolved inputs, semantic glyphs,
and per-window route ownership. The route tests also prove graph/run-detail/
terminal peer exclusivity and last-document fallback.

The graph intentionally compiles against the documented C8-03
`ConductorCoordinatorSession` shape on this parallel branch. At integration,
remove C8-06's compatibility declaration and placeholder
`WorkspaceSession.conductorCoordinatorSessions` property in favor of C8-03's
identical session storage; retain the graph projection and mapping.

## Verification

```bash
./script/format.sh --fix
./script/format.sh --lint
./script/await_build_lock.sh && swift build
./script/await_build_lock.sh && swift test
./script/await_build_lock.sh && swift test --no-parallel
```

The phase branch is headless-only. Run section K of the Ensemble manual test
plan from the integrated `main` app bundle to verify visual routing, focus,
VoiceOver, gate controls, and second-window ownership.

## Related code, ADRs, and phases

- `Sources/RafuApp/Conductor/Run/ConductorGraphModel.swift`
- `Sources/RafuApp/Conductor/Run/ConductorRunPresentation.swift`
- `Sources/RafuApp/Views/ConductorGraphCanvas.swift`
- `Sources/RafuApp/Views/ConductorRunsPanelView.swift`
- `docs/decisions/0018-conductor-external-agent-orchestration.md`
- `docs/plans/phases/conductor/C8-06-graph-canvas.md`
- `docs/plans/phases/conductor/C8-coordinator-ux.md`
- `docs/plans/phases/conductor/ensemble-manual-test-plan.md`
