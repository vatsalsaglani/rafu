# View tools, the 48 KiB rule and the generated vocabulary

- Applies to: `view_render` and `view_update` in
  `Sources/RafuCore/CanvasBridge/CanvasAgentTools.swift`,
  `CanvasAgentViewVocabulary.swift`, the `instructions` string of
  `CanvasBridgeMCPServer`, the bundled `rafu-view` and `json-render-swift-use` skills, and their installer
  ([ADR 0036](../decisions/0036-generated-views-on-the-ensemble-board.md)).
- Last verified: Swift 6.4.2, macOS 27, 2026-11-08.

## Rule or observed behavior

### MCP shapes

- `view_render { title?, spec, near? | x?, y? }`: `spec` is a JSON object with
  `root` (string) and `elements` (object). The server re-serialises it with sorted
  keys and no escaped slashes, so the card stores canonical text.
- `view_update { node_id, spec | patches | reset }`: give exactly one of the three;
  two together are refused ("give spec, patches or reset, not two"). `patches` is
  JSON Lines, one `{op, path, value}` per line, applied to the current spec. A
  changed spec resets the view's saved state. `reset: true` restores the initial
  state only.
- Risk class is `edit` for both, so they follow Off / Ask / Allow like
  `note_create`. The Ask approval line is "View: N elements; Type, Type…": the
  element count and up to 8 distinct component types, never a prop value. Patches
  show "Patches: N lines".
- Parse limits: 2,000 elements, 2,000 patch lines, no `__proto__` key anywhere
  in the spec, each non-blank patch line starts with `{`. A spec that fails
  validation returns the validator's text (codes, element keys and types, never
  prop values; bounded to 1,000 characters) as the tool error so the agent can
  fix it.

### The 48 KiB rule

One MCP frame is 64 KiB (`CanvasBridgeMCPServer.maximumFrameBytes`), and that
bound protects every tool. So one call carries at most 48 KiB of view JSON
(`CanvasAgentToolCall.maximumViewBytes`). The card itself holds up to 256 KiB, and
a view grows past 48 KiB through `view_update` patches. Voice is in-process, not a
frame, so voice uses the card's 256 KiB bound.

### The tool schema is not strict

`CanvasAgentViewVocabulary.specSchema` is a hand-written JSON Schema for a plain
object. `elements` is a map and `props` is free-form, which strict mode cannot
express. The component vocabulary sits in the tool description text
(`CanvasAgentViewVocabulary.text`), not in the schema.

### Regenerating the vocabulary constant

`RafuCore` has no package dependency, so the vocabulary text is a checked-in
constant generated from `RafuCatalog.rafu.prompt(...)` in the app. When a catalog
component changes, the drift test fails.

1. Run `swift test --filter CanvasAgentViewVocabularyDriftTests`.
2. The test writes the new text to `$TMPDIR/rafu-view-vocabulary.txt`.
3. Paste it into `CanvasAgentViewVocabulary.text`, indented 8 spaces.
4. Bump `RafuCatalog.version`'s suffix when a Rafu component definition changed,
   so saved states for the old definition do not apply.
5. Run the test again, then `swift test --filter CanvasAgentViewVocabularyTests`
   (RafuCore).

A second test checks that every component name mentioned in the `rafu-view`
SKILL.md exists in the catalog.

### Three skills, one install

Settings ▸ Ensemble ▸ Agent Skill installs all three bundled skills,
`rafu-ensemble`, `rafu-view` and `json-render-swift-use`
(`ConductorBundledSkillCatalog.skills`), to the same destinations
(`~/.claude/skills/<id>`, `~/.codex/skills/<id>`, or a custom folder). The
installer runs a conflict pass before it writes (the exact prompt text is covered
by the manual check below). `rafu-view` is thin: it points at
`json-render-swift-use` for the spec language and adds only what is
Rafu-specific. Both names appear in the `rafu-view` SKILL.md and in the
`view_render` tool description (2026-11-15; before that, the description named a
skill that an agent could not find, so it read Rafu's Swift sources).

- **`json-render-swift-use` is vendored.** Copied from `swift-json-render`
  0.22.0-alpha.3, commit `a319217c950cc55de0b31f884e8c32877e2b09ee`, with the
  upstream `LICENSE` (Apache-2.0) and `NOTICE` unchanged. `install.md`,
  `upgrade.md`, `customising.md` and `examples/` are left out because the
  installer writes only the skill root and `references/`. The host, validate and
  action text is rewritten for Rafu. The "Source" section at the end of the
  vendored `SKILL.md` is the Apache-2.0 §4(b) change notice; the install writes
  `LICENSE` and `NOTICE` beside it (they are in the manifest). A package bump does
  not update the copy: re-copy and re-run `AgentSkillBundleTests`.
- **Item shapes.** `rafu-view/references/components.md` gives exact props and item
  shapes, plus one validated example, for each of the 17 Rafu components. The
  vocabulary text points to it ("ITEM SHAPES (Array<unknown> props): rafu-view
  skill, references/components.md"). The agent rule is: do not read Rafu's source;
  render a small spec and read the validator error.
- **The vocabulary text has a 6 KiB limit.** After this change it is 6134 of 6144
  bytes (10 bytes free), checked by "The vocabulary text fits 6 KiB…" in
  `CanvasAgentViewVocabularyTests`. A new component or a longer line needs a
  cut elsewhere in the text, or the limit moves for every client.
- **Install is explicit, never automatic.** Skills reach `~/.claude` and
  `~/.codex` only when the user presses Install. There is no refresh on launch,
  on purpose (no unasked writes). A user who installed earlier must press Install
  again. For this user the coordinator copied the new files by hand on 2026-11-15.
- **`Figure` loads no local image in a generated view.** `components.md` tells
  agents to use `Image`.
- **Catalog drift in the skill text.** `examples.md` used Stat intent `success`;
  the valid value is `good`. `AgentSkillBundleTests` now runs every JSON block in
  the bundled skills through `GeneratedViewActions.validate(specJSON:)`, so a stale
  example fails a test.

## Why it matters

A schema that is too strict makes the model send empty `elements`; a vocabulary
that drifts from the catalog makes agents call components that no longer exist; a
frame bound raised for one tool is raised for all.

## Reproduction or evidence

`Tests/RafuCoreTests/CanvasAgentViewVocabularyTests.swift`,
`Tests/RafuCoreTests/CanvasAgentToolsTests.swift`,
`Tests/RafuAppTests/GeneratedView/CanvasAgentViewVocabularyDriftTests.swift`,
`ViewToolsPolicyTests`. Test counts for wave 3 were not part of the handoff.

2026-11-15 skill bundle (commit f31d079):
`Tests/RafuAppTests/Conductor/AgentSkillBundleTests.swift` (8 tests, including
validation of every JSON block). Parallel mode only: 523 tests in 40 suites and
3901 tests in 318 suites passed. No `--no-parallel` result was in the handoff.

## Verification

- `swift test --filter CanvasAgentViewVocabulary`
- `./script/test.sh` and `./script/test.sh --no-parallel`
- `swift test --filter AgentSkillBundleTests`
- Manual (Rafu Lightning only): MCP Ask from Claude Code (approval shows count
  and types, no text), MCP Allow from Codex with a `view_update` patch and a
  reset, Settings ▸ Ensemble install writes all three skills and the conflict
  prompt appears when it should.

## Related code, ADRs, and phases

- `CanvasAgentTools.swift`, `CanvasAgentViewVocabulary.swift`,
  `Sources/RafuApp/Resources/AgentSkills/rafu-view/`,
  `Sources/RafuApp/Resources/AgentSkills/json-render-swift-use/`,
  `Sources/RafuApp/Conductor/Ensemble/ConductorSkillInstaller.swift`
- [ADR 0036](../decisions/0036-generated-views-on-the-ensemble-board.md),
  [ADR 0026](../decisions/0026-canvas-live-session-links.md)
- [`ensemble-agent-terminal-tools.md`](ensemble-agent-terminal-tools.md)
- Phase: [`../plans/phases/ensemble-canvas.md`](../plans/phases/ensemble-canvas.md)
