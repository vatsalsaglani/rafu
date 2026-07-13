# Phase 2 — Editing completeness and performance

- **Status:** Planned
- **Depends on:** Combined Phase 1 public gate
- **Canonical scope:** v0.4 §§7.3–7.6 and §15 Phase 2

## Goal

Make normal source/config editing comfortable enough that another editor is rarely needed, without abandoning lazy loading or the small-runtime premise.

## Scoped deliverables

- Selection-set/edit-transaction engine; select-next occurrence, multiple selections/cursors, reverse-order edits in one undo group.
- Bracket matching, auto-closing pairs, complete move/duplicate/delete-line commands, and command routing.
- Quick Open; local and agent-backed remote project search; replace-in-files with preview and cancellation.
- Horizontal/vertical editor splits, stable pane/tab/selection/scroll restoration, configurable shortcuts, status details, drag files between folders.
- Large-file mode with visible-range highlighting/degraded tiers; optional Tree-sitter outline.
- Instruments and memory regression suite across local and high-latency remote workspaces.

## Explicit non-goals

- Git UI, AI, language-server ecosystem, debugger, terminal, formatter platform, extensions, or remote repository indexing/preload.
- Expanding the bundled language set without a product decision and measured grammar cost.

## Owned paths

- Editing owner: `Rafu/EditorCore`, editor command/selection tests.
- Search/Quick Open owner: search services/models and local/remote adapters under `Rafu/FileSystem` and `Rafu/Remote`, dedicated tests.
- Pane/restoration owner: `Rafu/Workspace` pane/tab/restoration models and views.
- Syntax/large-file owner: `Rafu/Syntax`, large-file fixtures, performance tests.
- Integration owner controls shared commands, workspace composition, and protocol capability changes.

## Locked decisions

- Search and syntax work is cancellable and never blocks typing.
- No entire repository index in memory; remote search executes through the agent.
- Multi-range edits apply in reverse order inside one undo group.
- Large-file behavior degrades predictably to plain/read-only tiers.
- Local and SSH editing expose the same commands and visual model.

## Open blockers to resolve

- Measured thresholds for normal, medium-large, very large, and extreme files.
- Search strategy and result limits that preserve lazy memory use.
- Shortcut conflict map, including the final Markdown preview shortcut.
- Whether the optional Tree-sitter outline meets cost and usefulness gates.

## Required project references

- [`../../references/build-and-run.md`](../../references/build-and-run.md)
- [`../../references/concurrency.md`](../../references/concurrency.md)
- [`../../references/swiftui-appkit-boundary.md`](../../references/swiftui-appkit-boundary.md)

## Required skills and capabilities

- `.agents/skills/swift-concurrency-pro` for cancellable search, task groups, streams, and stale-result rejection.
- `.agents/skills/swiftui-expert-skill` for stable pane/list identity, focus, invalidation, and trace analysis.
- `.agents/skills/apple-design` for immediate keyboard actions, direct manipulation, and restrained transitions.
- `build-macos-apps:appkit-interop` for multiple selection/TextKit command and responder work.
- `build-macos-apps:swiftui-patterns`, `build-macos-apps:view-refactor`, and `build-macos-apps:window-management` for split layouts and stable scene ownership.
- `build-macos-apps:build-run-debug` and `build-macos-apps:telemetry` for profiling/regression evidence; use `build-macos-apps:test-triage` only after a failure.

## Worktree decomposition and integration order

1. Editor owner freezes selection/edit transaction APIs and undo invariants.
2. Editing commands, search/Quick Open, pane/restoration, and syntax/large-file agents proceed in separate paths.
3. Integrate selection engine and commands before pane duplication.
4. Integrate search adapters before UI and replace preview.
5. Integrate pane/restoration, then large-file degradation.
6. Run full local/remote performance and memory suite; refactor only from measured evidence.

## Verification and measurements

- Multi-cursor Unicode/IME edits, overlapping selections, reverse edits, undo/redo grouping, auto-pairs, and bracket cases.
- Quick Open/search/replace cancellation and stale-result tests in 50,000+ files and high latency.
- 100 tabs, deep trees, large minified JSON, large Markdown, rapid pane/tab restore, and drag operations.
- Measure typing p95, Quick Open response, search memory, closed-buffer release, and SwiftUI invalidation with Release Instruments traces.
- Verify local and SSH command parity and no remote repository preload.
- Full keyboard, VoiceOver, Reduce Motion/Transparency, and focus traversal for pane/search surfaces.

## Exit criteria

- Ordinary source, Docker, Compose, environment, and manifest edits no longer require another editor.
- Multiple selections, Quick Open, search/replace, splits, restoration, and large-file tiers are correct locally and remotely.
- Command surfaces feel immediate and have measured latency evidence.
- Large repositories remain lazy and within recorded memory budgets.
- No regressions to Phase 1 disconnect, external-change, theme, or Markdown behavior.

## Documentation handoff

Record selection/undo invariants, search protocol and limits, shortcut map, pane restoration schema, large-file thresholds, trace artifacts, and measured regressions. Hand Phase 3 stable workspace paths, editor-open commands, and cancellation patterns.
