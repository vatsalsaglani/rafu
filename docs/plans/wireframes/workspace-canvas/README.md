# Canvas visual review

Planning artifacts for the [Workspace Canvas proposal](../../phases/workspace-canvas.md).
No Canvas product code is included. Existing app repairs remain separate.

The rendered `*.plan.html` files contain a generated third-party runtime and are
kept locally outside Git. Rebuild them from the tracked MDX sources with `vplan`.
The private planning site publishes separate copies.

## Open the design

- [Clickable wireframe](prototype.html): eight steps, with working card drag,
  resize, zoom, fit, list, focus, sample input, tab switching, and app-preview states.
- [Visual plan](canvas-plan.plan.html): self-contained output from `vplan`.
- [Execution and Worktree Plan](execution-plan.plan.html): baseline protection,
  nine staged worktrees, path ownership, fixed-SHA dependencies, and C0–C5 gates.
  Edit its [source](execution-plan.mdx) to revise the execution plan.
- [Plan source](canvas-plan.mdx): edit this file to revise the Visual Plan review.
- [Overview](overview.svg), [Focus](focus.svg), and [native app handoff](native-app.svg):
  annotated vector wireframes, also embedded in the visual plan.

Open the HTML files directly in a browser. For local review, serve only this directory:

```sh
python3 -m http.server 8756 --bind 127.0.0.1 --directory docs/plans/wireframes/workspace-canvas
```

Then open `http://127.0.0.1:8756/prototype.html`. The Visual Plan link to the
prototype uses this address. It requires the local server; the prototype itself
has no server dependency and works as a local HTML file.

## Review sequence

1. **Workbench:** New Canvas adds a tab beside the changed file and terminal.
2. **Open Canvas:** Add Card offers six types. Load sample board opens a complete example.
3. **Add cards:** Select and focus a terminal, file, note, web preview, or native app reference.
4. **Arrange:** Drag a header or lower-right corner. Scroll to pan; Control-scroll
   zooms. Connect then select two cards. Use List to reach cards without spatial aiming.
5. **Focus:** Enter content enables the sample input. Leave content returns to
   the frame; Back to Canvas returns to the same board position.
6. **Native app:** Choose Window shows a simulated system picker. Cancel keeps
   the reference; Preview shows sample frames. Open App shows a diagram of the
   separate native window. Paused and Unavailable demonstrate failure states.
7. **Return:** File and Settings tabs retain the Canvas tab. Select Checkout flow to return.
8. **Restore:** The sample board returns with its terminal stopped, web preview
   disconnected, and native app in Reference state.

The step buttons reset the sample data. This is an interaction model, not a
storage or native-hosting prototype. It does not run commands, connect to web
apps, capture screens, activate other apps, save notes, or make purchases.
Sample input is temporary. Reduced motion removes the small dialog fade.

## Proposed decisions shown

- Canvas is a normal workspace tab. Focus temporarily fills its editor area.
- Select a card before entering its content. Use a visible exit control outside
  the hosted terminal or web view.
- At overview scale, card contents are summaries. Use Focus for input at 1:1.
- Native app cards provide references and optional window previews. Input goes
  to the actual app after Open App. Return uses normal macOS app switching.
- Canvas List supplies a non-spatial route to cards and labeled relationships.
- Switching away from Canvas stops native preview. Resume needs a visible action.
- Restore and undo must never restart live work.

## Details to settle before implementation

The design review does not accept an ADR. These rules still need a final product
contract and native feasibility evidence:

- New Canvas name entry, menu placement, and conflict-free keyboard shortcut.
- Exact input-scale threshold, double-click behavior, and content exit shortcut.
- Terminal transfer when the same group is referenced by more than one board.
- Note save, close, crash recovery, and Save routing while content has focus.
- Offscreen versus hidden-tab web/capture policy, and capacity-limit actions.
- Whether two windows can edit one persisted board; if so, conflict handling.
- Removal/undo UI and paused resource ownership. Restore a reference without
  silently reconnecting, starting, or granting access.

## Tool provenance and reproduction

- Applies to these planning artifacts only.
- Verified on macOS 27.0.1, 2026-10-17, with Node 24.19.0 and `vplan` 0.24.0.
- Skill: `brandonburrus/visualplan`,
  `skills/visual-plan`, commit `be59b0c98ad85845ed8331b28eb9f578c54b9819`.
- The npm package repository points to the same source. The package and its
  manifest were inspected before use. Installation used `--ignore-scripts`.
- The installed skill is in `~/.codex/skills/visual-plan`; it is available on the
  next turn. No package was added to Rafu and no npm project files were created here.

The system Node 22.0.0 is too old for the current Vite/rolldown dependencies.
An install with that Node version omitted the native rolldown optional binding.
Reinstalling the same `vplan` version with the bundled Node 24.19.0 runtime and
`--include=optional` resolved it. Use a supported Node runtime for these commands:

```sh
vplan check docs/plans/wireframes/workspace-canvas/canvas-plan.mdx
vplan render docs/plans/wireframes/workspace-canvas/canvas-plan.mdx --static --no-share --no-diff
```

The interactive review command was tested, but its server was stopped. In
`vplan` 0.24.0, Commander exposes `--no-daemon` as `options.daemon === false`,
while `runRender` checks `options.noDaemon`. The flag therefore has no effect.
The shared review daemon was observed listening on `*:9151`; it was started by
this task and stopped after inspection. No installed package code was patched.
Use the checked static plan and clickable wireframe for this review. Do not
assume that the documented one-session flag works in this version.

Evidence: the packaged `dist/index.js` option declaration, `runRender` branch,
and `lsof -nP -iTCP -sTCP:LISTEN`. The static render needs no review daemon.
A design approval does not authorize implementation or repository actions.

## Verification

- `vplan check` passed; static HTML render passed.
- JavaScript syntax check passed.
- Browser pass checked card drag, list navigation, focus input with Shift-Enter,
  native window selection, app handoff, paused state, and stopped restore states.
- The native picker, terminal, and app behavior in these files is simulated.
  Native resource use, VoiceOver, process ownership, and performance still need C0 evidence.
- No Swift source changed for this visual review; the app build and test suite
  were not rerun for HTML/MDX/SVG artifacts.

Related decisions and native platform sources are listed in the
[phase plan](../../phases/workspace-canvas.md). This guide records the planning
tool behavior; it does not change Rafu's accepted architecture.
