# 0036. Generated views on the Ensemble board

- Status: Accepted for wave 3 of the swift-json-render integration, 2026-11-08.
  The delta-streaming claim in decision 12 is unverified until the user reports
  the "deltas: N" measurement.
- Amends: [ADR 0034](0034-mdx-native-component-rendering.md) (renderer set),
  [ADR 0035](0035-voice-through-gpt-live.md) (`show_view`),
  [ADR 0026](0026-canvas-live-session-links.md) and
  [ADR 0028](0028-ensemble-bridge-shell-strategies.md) (one cross-reference).
- Phase: [`../plans/phases/ensemble-canvas.md`](../plans/phases/ensemble-canvas.md)
  ("Generated views (wave 3)") and
  [`../plans/phases/voice-control.md`](../plans/phases/voice-control.md).
- References:
  [`generated-view-card-and-state.md`](../references/generated-view-card-and-state.md),
  [`remote-image-consent-and-trust.md`](../references/remote-image-consent-and-trust.md),
  [`view-tools-and-vocabulary.md`](../references/view-tools-and-vocabulary.md),
  [`voice-delta-streaming.md`](../references/voice-delta-streaming.md).

## Context

Agents in Ensemble terminals, and the voice backend, can only add notes, files,
diagrams and other fixed card kinds. They cannot show a small table, a stat row
or a chart. The user chose the `swift-json-render` package (a declarative
JSON-to-native-UI renderer, Apache-2.0) to close that gap with a native
renderer: no web view, no JavaScript, no new runtime. Wave 3 adds four things:
a generated-view card with saved state, web images with consent, the MCP and
voice view tools, and MDX documents on the same catalog.

## Decision

### Card, state and limits

1. **One content case.** `CanvasCardContent.generatedView(CanvasGeneratedView)`
   stores the spec as canonical JSON text (sorted keys, no escaped slashes), the
   catalog version, provenance (names and counts, never spec text), and an
   optional saved state. The domain layer holds text, so the board file never
   depends on the package's types.
2. **Saved state rules.** The state is saved with `specVersion` (SHA-256 of the
   canonical spec without its `state` key) and `catalogVersion`. It is applied
   on load only when both match. A changed spec always resets the state to the
   spec's seed. Caps: 64 KiB for the state, 4 KiB for one value. Never saved:
   any key that starts with `_` at any depth; every path bound by a secret prop
   (`secretProps`, through both `$bindState` and `$bindItem` rows); any value
   over 4 KiB. Over the 64 KiB cap, the newest changes go back to their seed
   value first.
3. **Reset View** (header menu, context menu, ⌥⌘R, and `view_update` with
   `reset`) is one undo step. State writes are not undo steps. Creating and
   updating a view is one undo step each, with the agent notice.
4. **Card models** live per board window in `GeneratedViewModels`, because the
   board drops a card's view when it scrolls away and the user's input must
   survive that. The `RenderModel` is released while the card is off screen. The
   state save is debounced 500 ms and the snapshot is folded into the document
   at save time, with no undo step.
5. **Budgets.** All view specs and saved states on one board share 1 MiB,
   counted in the bytes they take in the saved file (a spec is stored as a JSON
   string, so quotes, slashes and backslashes count twice). One spec is at most
   256 KiB. A board holds at most 50 views. One MCP call carries at most 48 KiB
   of view JSON, because the bridge frame is 64 KiB and that bound protects every
   tool; larger views grow through `view_update` patches.
6. **Stream undo collapse.** When voice streams a view, the skeleton card is one
   undo step. At the end, the skeleton step and the final write collapse into one
   step only when four things hold: the board can undo, no card content is being
   edited, the board's `changeStamp` has not moved since the skeleton step, and
   `CanvasAgentUndoGate` still allows it. `changeStamp` is needed because the gate
   compares only cards and connections, while a rename or a consent change is also
   an undo step. If any check fails, the final spec is an ordinary update of the
   skeleton card (two honest undo steps). The same rule governs removing a
   skeleton on failure. Known weakness that predates wave 3: the gate looks only
   at cards and connections, so it cannot see a change that touches neither
   (for example a provenance notice).
7. **Two windows on one board** each have their own card model and store. The
   last debounced write wins the saved state. A toggled control in one window
   does not move in the other until reload. This is accepted for wave 3.
8. **File format.** `CanvasDocument.version` and
   `CanvasEnsembleFile.currentFormatVersion` stay 1, as for the whiteboard card
   kinds. An older Rafu cannot open a board that has a view card.

### Host actions and agent control

9. **Host actions** are `open_file`, `focus_node` and `open_url`. Every effect is
   a user press. `open_url` accepts `https` and `http` after a confirmation, and
   `mailto` after a confirmation. `javascript:`, `file:`, `data:` and custom
   schemes are refused. No action starts a process, types into a terminal,
   writes a file, or reaches the network by itself.
10. **Off / Ask / Allow** governs `view_render` and `view_update` (MCP) and
    `show_view` (voice). Off refuses. For MCP, Ask shows an approval with the
    element count and the component types, never the text. For voice, Ask runs at
    once with an Undo notice, as in ADR 0035. Allow runs.
11. **Tool schema is not strict.** The spec is a plain JSON object parameter. The
    vocabulary goes in the description text, which is generated from the catalog
    and checked by a drift test. The upstream strict schema cannot express a map
    of elements and free-form props. A JSON Lines text parameter is used only for
    `view_update.patches`, where it is the right shape for edits. The voice tool
    keeps the spec flat beside `title`, `node` and `reset` so the arguments text
    can stream into an object-mode decoder. `hiddenEnsembleTools` keeps
    `view_render` and `view_update` out of the voice tool list.
12. **Voice streaming** shows a skeleton card at the first useful argument delta
    and fills it while the model speaks. Whether GPT-Live sends argument deltas
    at all is unverified; without them the card appears on completion.

### Images from the web

13. **Three controls combine.** A global switch (Off / Ask / Always, default Ask),
    a per-Ensemble consent, and a host-pattern trust list. Nothing is fetched
    before a control allows it, not even a HEAD request.
14. **Per-Ensemble consent** is `CanvasDocument.permissions.remoteImages`. It is
    written only from the consent card, kept in the private store, and never in
    a `.rafuensemble` file, so a shared board starts without consent. No tool can
    read or write it.
15. **Trust list.** A pattern is an exact host or one leading wildcard on a
    registrable parent. The Public Suffix List decides what is registrable. There
    is no regex. The list lives in `image-trust.json` in the app's Application
    Support folder (separate for Rafu Lightning and the release app).
16. **Fetch policy.** `https` only, port 443 only, no user name, no IP literal,
    no `localhost` or local name. Resolved addresses are checked: private,
    loopback, link-local, carrier-grade NAT, NAT64, 6to4 and mapped addresses are
    refused, and a host with any private answer is refused. The session is
    ephemeral, with no cookies, no credentials, no cache and no `Referer`. At most
    2 redirects, each re-authorised; an Ensemble grant never covers a cross-host
    redirect. 2 MB encoded cap, 64 Mpx check before decode, thumbnail decode, and
    only sniffed PNG, JPEG, GIF and WebP (no SVG). The decoded cache is tagged by
    grant, so revoking a grant drops its images across open windows.
17. **Accepted risk.** Rafu checks the resolved addresses, then `URLSession`
    resolves again to connect. A DNS rebinding window remains. It is accepted and
    documented, not hidden.
18. **Known cosmetic limit.** Undo of a consent grant does not bump the image
    provider revision, so an already-shown image may stay visible until the next
    redraw.

### Other

19. **`RafuCore` stays dependency-free.** The MCP server process links it. The
    vocabulary constant is generated from the catalog in the app, and a drift test
    fails when it is stale.
20. **MDX** renders through the same catalog (ADR 0034 amendment).
21. **`Figure` roots.** In a document, `Figure` gets the local-root grant `/`,
    which equals today's preview behaviour. Cards get no local roots. Follow-up:
    narrow documents to the workspace roots plus the document folder.
22. **Dependency.** A git URL with an exact tag, on the `RafuApp` target only.
    Wave 3 started on `0.22.0-alpha.1`; the fix round moves the pin to
    `0.22.0-alpha.2`. Move to the `0.22.0` release tag when it exists.

## Alternatives considered

- The upstream strict tool schema: unusable for a map of elements and free-form
  props.
- A JSON Lines text parameter for the whole spec: double-encodes every quote,
  hides the shape from the schema, and streams as escaped fragments.
- A path dependency: builds a moving sibling tree, is not pinned, and fails in CI.
- Raising the 64 KiB bridge frame for one tool: raises it for every tool.
- Per-document web views or a JavaScript engine: break the memory budget and the
  "no extension host" rule.
- One global consent for images, or a regex trust list: too coarse, or too easy
  to get wrong.

## Consequences

- The board file can carry up to 1 MiB of views; the rest of the 2 MiB document
  limit stays for notes, layout and links.
- An older Rafu fails to open a board with a view card.
- Voice, MCP, documents and cards share one renderer and one catalog.
- Generated-view state survives quit and relaunch but never carries secrets or
  `_` keys.

## Revisit trigger

- The user's report shows that GPT-Live sends argument deltas, or never does.
- The package ships its `0.22.0` release tag.
- A second consumer of the catalog appears.
- A change to the stream undo gate so it sees more than cards and connections.

## Related

- Code: `Sources/RafuApp/Canvas/GeneratedView/`,
  `Sources/RafuApp/Canvas/RemoteImages/`, `Sources/RafuApp/Markdown/MDX*.swift`,
  `Sources/RafuApp/Voice/VoiceToolExecutor+Views.swift`,
  `Sources/RafuCore/CanvasBridge/CanvasAgentTools.swift`,
  `Sources/RafuCore/CanvasBridge/CanvasAgentViewVocabulary.swift`.
