# View tools, the 48 KiB rule and the generated vocabulary

- Applies to: `view_render` and `view_update` in
  `Sources/RafuCore/CanvasBridge/CanvasAgentTools.swift`,
  `CanvasAgentViewVocabulary.swift`, the `instructions` string of
  `CanvasBridgeMCPServer`, the bundled `rafu-view` skill, and its installer
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

### Two skills, one install

Settings ▸ Ensemble ▸ Agent Skill installs both bundled skills, `rafu-ensemble`
and `rafu-view`, to the same destinations (`~/.claude/skills/<id>`,
`~/.codex/skills/<id>`, or a custom folder). The installer runs a conflict pass
before it writes (the exact prompt text is covered by the manual check below).
`rafu-view` is thin: it
points at the package's `json-render-swift-use` skill for the spec language and
adds only what is Rafu-specific.

## Why it matters

A schema that is too strict makes the model send empty `elements`; a vocabulary
that drifts from the catalog makes agents call components that no longer exist; a
frame bound raised for one tool is raised for all.

## Reproduction or evidence

`Tests/RafuCoreTests/CanvasAgentViewVocabularyTests.swift`,
`Tests/RafuCoreTests/CanvasAgentToolsTests.swift`,
`Tests/RafuAppTests/GeneratedView/CanvasAgentViewVocabularyDriftTests.swift`,
`ViewToolsPolicyTests`. Test counts for wave 3 were not part of the handoff.

## Verification

- `swift test --filter CanvasAgentViewVocabulary`
- `./script/test.sh` and `./script/test.sh --no-parallel`
- Manual (Rafu Lightning only): MCP Ask from Claude Code (approval shows count
  and types, no text), MCP Allow from Codex with a `view_update` patch and a
  reset, Settings ▸ Ensemble install writes both skills and the conflict prompt
  appears when it should.

## Related code, ADRs, and phases

- `CanvasAgentTools.swift`, `CanvasAgentViewVocabulary.swift`,
  `Sources/RafuApp/Resources/AgentSkills/rafu-view/`,
  `Sources/RafuApp/Conductor/Ensemble/ConductorSkillInstaller.swift`
- [ADR 0036](../decisions/0036-generated-views-on-the-ensemble-board.md),
  [ADR 0026](../decisions/0026-canvas-live-session-links.md)
- [`ensemble-agent-terminal-tools.md`](ensemble-agent-terminal-tools.md)
- Phase: [`../plans/phases/ensemble-canvas.md`](../plans/phases/ensemble-canvas.md)
