# Rafu delivery phases

The active gate before the repository's first commit and initial push is
[`pre-initial-push-workbench.md`](pre-initial-push-workbench.md). It supersedes
the narrower vertical-slice brief after hands-on review expanded the acceptance
contract to a polished workbench.

This directory turns the canonical [Rafu v0.4 product and architecture plan](../rafu_product_architecture_plan.md) into worktree-ready Goal mode briefs. The canonical plan owns product intent and locked decisions; these files own execution order, path boundaries, verification, and handoff.

## Bootstrap checkpoint and active gate

The repository bootstrap was a prerequisite checkpoint, not evidence that Product Phase 0 started or passed. The active pre-first-commit brief now intentionally extends that scaffold with one local end-to-end slice.

Bootstrap is complete when:

- the native app and `rafu` CLI targets have a minimal buildable structure;
- the app can launch a placeholder workspace window and the CLI can print stable help/version output;
- one project-local build/test entrypoint and the Codex Run action are documented;
- `AGENTS.md`, decision/reference guidance, and these phase briefs exist;
- canonical Rafu names and resource locations are established; and
- a clean checkout can reproduce the bootstrap build.

Bootstrap itself did **not** claim TextKit editing, Tree-sitter, SSH, launcher IPC, Git, AI, or any Product Phase 0 exit criterion. The active gate claims only the behavior explicitly verified in its acceptance contract; Product Phase 0 still begins in a later goal/worktree after the first commit.

## Status and sequence

| Phase | Status | Depends on | Gate |
|---|---|---|---|
| [Phase 0](phase-0-feasibility.md) | Planned | Bootstrap checkpoint | Editor, SSH, and CLI feasibility proven |
| [Phase 1A](phase-1a-local-workspace.md) | Planned | Phase 0 | Shippable internal local v0.1 |
| [Phase 1B](phase-1b-ssh-workspace.md) | Planned | Phase 0 SSH proof and Phase 1A | SSH workspace parity |
| [Phase 1C](phase-1c-cli-integration.md) | Planned | Phase 0 CLI proof; stable 1A/1B routing contracts | Complete CLI and window routing |
| [Phase 2](phase-2-editor-completeness.md) | Planned | Phase 1 public gate | Comfortable daily editing and performance |
| [Phase 3](phase-3-git.md) | Planned | Phase 2 | Local/SSH edit-review-stage-commit loop |
| [Phase 4](phase-4-ai-commit-messages.md) | Planned | Phase 3 | Safe, editable AI commit suggestions |
| [Phase 5](phase-5-hardening-distribution.md) | Planned | Phase 4 feature set | Reliable notarized distribution |
| [Phase 6](phase-6-controlled-expansion.md) | Deferred | Phase 5 plus explicit approval | Only approved bounded additions |
| [UI refresh — flat, modern, layered](ui-flat-modern-refresh.md) | Implemented (2026-07-18); +15 issue-fix batch (2026-07-19); manual GUI verification + ADR 0012 acceptance owed | Pre-initial-push workbench baseline | RafuMetrics, palette tokens, flat layered chrome, design language established across all surfaces |
| [Git experience — blame, graph, worktrees, composer](git-experience-and-worktrees.md) | Implemented (2026-07-18); +15 issue-fix batch (2026-07-19); manual GUI verification + ADR 0013 acceptance owed | Pre-initial-push workbench baseline; ADR 0005 (LSP) for future intelligence seams | Inline blame (GX1, +full-file mode 2026-07-19), blame hover + hunk peek (GX2), commit graph (GX3), worktrees (GX4), AI composer visual (GX5) shipped; GX6 activity bubbles deferred |
| [Terminals as editor tabs](editor-terminal-tabs.md) | Planned (2026-07-18); T1 placement landed narrower (ephemeral, no restoration) via the issue-fix batch (2026-07-19, ADR 0014 Proposed) | Pre-initial-push workbench baseline; ADR 0004 | T1 (tab placement) done; T2 (lifecycle policy), T3 (agent-workflow polish), T4 (docs/measurement) still planned |
| [Terminal manager — sessions panel, hide/close, shells, attention](terminal-manager.md) | Implemented (2026-07-21); T-A through T-E all shipped; ADR 0004/0014 amended, ADR 0016 Proposed | ADR 0004/0014 terminal baseline; utility-rail pattern | ⌃` hides instead of killing; Terminals panel manages/reveals/names/colors sessions; shell choice with preferred default; bell → attention badge + on-by-default notification with bounded snippet and reply (ADR 0016) |
| [T-F — Notch Companion](terminal-notch-hud.md) | v1 attention HUD SHIPPED (2026-07-22: seamless housing merge, OSC 9/777 + quiescence detection, snippet + reply); v2 companion redesign Planned (NC-A…NC-E) | v1 HUD stack; ADR 0016; WorkspaceWindowRegistry | Always-on resting strip (editors count + attention dot), hover-peek panel (editors list w/ git one-liner, cross-window attention feed, reply), Codex %/Claude token usage tiles |
| [Diff syntax highlighting + new-side hover](diff-syntax-highlighting-and-hover.md) | Implemented (2026-07-20); interactive GUI checklist (hover card, scroll smoothness on a large diff) owed | Git experience baseline; ADR 0005 (opt-in LSP); tree-sitter grammar boundary | Diff canvas tokens colored both columns (shared `PlainTextSyntaxHighlighter` core, per-side parse, cached spans); hover (declarations/types) on the NEW side of working-tree diffs only — old-side and history-scoped hover remain an explicit non-goal |
| [Memory resilience](memory-resilience.md) | Lane 1 COMPLETE (2026-07-15); Stage C at lane-2 merge | Initial push; interleaves with feature phases | Budgets hold under abuse, with recorded Release evidence |
| [Language intelligence](language-intelligence.md) | Lane 1 COMPLETE (2026-07-15); Stage C at lane-2 merge | Initial push; ADR 0005; Resources surface for Stage C | Ladder navigation (Tree-sitter → symbols → opt-in LSP) shipped in bounded stages |
| [Post-audit fan-out](post-audit-worktree-fanout.md) | MERGED (2026-07-18): all six lanes on `main`, three integration rounds green | Clean working tree; contract commits G0 + I0 | Six lanes merged in three pairwise integration rounds |
| ├ [LSP production readiness](lsp-production-readiness.md) | Merged (2026-07-18); P5 live server round-trip still owed manually | Fan-out prerequisites | npm-resolved TS server, verified catalog, live gopls/rust-analyzer round-trip, sourcekit-lsp references |
| ├ [Symbol coverage + markdownInline](symbol-coverage-and-markdown-inline.md) | Merged (2026-07-18); on-screen render eyeball owed | Fan-out prerequisites | tags.scm × 5 new grammars; inline Markdown highlighting |
| ├ [Mermaid preview honesty](mermaid-preview-honesty.md) | Merged (2026-07-18); deep visual GUI pass owed; ADR 0008 Proposed | Fan-out prerequisites; ADR 0008 | Honest fallback + real flow/sequence native rendering |
| ├ [Multi-cursor editing](multi-cursor-editing.md) | Merged (2026-07-18); interactive gesture checklist owed | Fan-out prerequisites | Bounded multi-caret v1 (⌥-click, ⌘D, ⌘⇧L, carets above/below) |
| ├ [Git depth](git-depth-blame-stash-hunks.md) | Merged (2026-07-18); manual stage/stash/blame UI pass owed; ADR 0011 Proposed | G0 contract commit; stash approved by user; ADR 0011 | Hunk staging, stash, blame — explicit and bounded |
| └ [CLI ↔ app IPC v1](cli-app-ipc.md) | Merged (2026-07-18); nine-item manual checklist owed; ADR 0009 Proposed | I0 contract commit; ADR 0009 | Socket protocol, routing, `--goto`, `--new-window`; `--wait` deferred |

Memory resilience and language intelligence execute as the two-lane worktree
split defined in `language-intelligence.md`: lane 1
([`lane-1-memory-and-syntax-plan.md`](lane-1-memory-and-syntax-plan.md), main
checkout) and lane 2
([`lane-2-lsp-plan.md`](lane-2-lsp-plan.md), dedicated worktree created only
after lane 1's contract commit lands).

The post-audit work (2026-07-17) executes as a six-lane worktree split
coordinated by [`post-audit-worktree-fanout.md`](post-audit-worktree-fanout.md):
that file owns fan-out prerequisites, the two contract-first commits (G0
Git, I0 IPC), ADR number reservations 0008–0011, the shared-file
protocol, and the pairwise merge rounds; each lane's plan document owns
its scope and increments.

Phase 1C may develop late in parallel with Phase 1B after shared routing contracts stabilize, but the Phase 1 public gate requires 1A, 1B, and 1C together. Hardening and tests are continuous; Phase 5 is the dedicated release gate. The CLI ↔ app IPC lane above delivers Phase 0's CLI spike and the core of Phase 1C.

## Goal mode contract

For each phase:

1. Create one goal from that phase document; do not combine later-phase features.
2. Resolve listed blockers before work whose shape depends on them. Record the decision rather than silently choosing.
3. Give each worktree one owned path set. A worktree may consume shared protocols but must not casually edit another worktree's implementation paths.
4. The integration owner alone edits shared app entrypoints, project/workspace files, common resource manifests, and cross-feature composition unless ownership is explicitly handed off.
5. Build and test each worktree before integration. Integrate contracts first, implementations second, UI composition third, and measurements last.
6. Preserve user work and unrelated changes. Never use destructive Git cleanup to resolve worktree drift.
7. Finish the documentation handoff before marking the goal complete.

## Source-path mapping and ownership lock

The canonical plan uses conceptual `Rafu/<Domain>` paths. The bootstrap uses this concrete mapping:

| Plan ownership label | Current/default repository path |
|---|---|
| `Rafu/App` | `Sources/RafuApp/App` and cross-feature composition files explicitly named by the phase |
| `Rafu/Workspace`, `Settings`, `DesignSystem` | `Sources/RafuApp/Workspace`, `Sources/RafuApp/Settings`, `Sources/RafuApp/DesignSystem` |
| Pure domain/service code under any feature | `Sources/RafuCore/<Feature>` until an ADR approves an independent target |
| SwiftUI/AppKit feature presentation | `Sources/RafuApp/<Feature>` |
| `Rafu/Launcher` | `Sources/RafuCore/Launcher` and `Sources/RafuCLI` |
| `Rafu/Tests/<Feature>Tests` | `Tests/<Feature>Tests` |
| `remote-agent` | `remote-agent` |

Before spawning a phase's worktrees, the integration owner must replace any still-conceptual owned path with exact paths based on the then-current tree, and must prove the sets do not overlap. `Package.swift`, `AGENTS.md`, shared indexes, and app composition stay integration-owned unless explicitly handed off. No fan-out starts with ambiguous or overlapping ownership.

## Shared locked rules

- SwiftUI owns scenes and composition; AppKit/TextKit 2 owns the editor edge.
- One `WorkspaceSession` belongs to one window.
- Full document text never lives in SwiftUI observable state.
- Local and SSH workspaces share `WorkspaceFileSystem` and later `RepositoryClient` models.
- Typing, selection, undo, and open-buffer search never wait on SSH or AI.
- Use `/usr/bin/ssh`, the user's OpenSSH configuration, normal host-key verification, and a versioned Rust agent over stdio.
- CLI requests use versioned same-user Unix-domain socket IPC; do not use `open --args` as the protocol.
- Git and process invocations use executable argument arrays, never shell command strings.
- AI is explicit, sanitized, previewed, editable, and never commits automatically.
- No extension host, custom SSH stack, or per-document WebView. The embedded terminal (ADR 0004) and an opt-in, bounded LSP client (ADR 0005) are deliberate recorded reversals; a general LSP ecosystem and marketplace remain excluded.
- Standard macOS controls and behavior come before custom glass or decorative motion.
- Record Release-build memory and latency evidence; native implementation alone is not proof of efficiency.

## Skill and plugin routing

Use only the skills relevant to the owned work:

| Need | Required routing |
|---|---|
| SwiftUI scenes, state, lists, accessibility, or performance | `.agents/skills/swiftui-expert-skill`; optionally use `.agents/skills/swiftui-pro` for a deliberate broad second pass |
| Actors, `Sendable`, cancellation, streams, process/network concurrency | `.agents/skills/swift-concurrency-pro` |
| Native restraint, feedback, spatial consistency, typography, reduced motion | `.agents/skills/apple-design` |
| App scene/sidebar/settings/commands composition | `build-macos-apps:swiftui-patterns` |
| TextKit, responder chain, panels, or another narrow SwiftUI gap | `build-macos-apps:appkit-interop` |
| Build, launch, logs, and project-local Run action | `build-macos-apps:build-run-debug` |
| Window lifecycle, placement, restoration, and multi-window behavior | `build-macos-apps:window-management` |
| Structured `Logger` events and signposts | `build-macos-apps:telemetry` |
| Focused Xcode/SwiftPM failure classification | `build-macos-apps:test-triage`, only after a failure needs diagnosis |
| Splitting oversized scenes/views without widening AppKit | `build-macos-apps:view-refactor` |
| Signing, entitlements, Gatekeeper, nested helpers | `build-macos-apps:signing-entitlements` |
| Archive, exported bundle, notarization | `build-macos-apps:packaging-notarization` |
| Read-only late motion audit | `.agents/skills/improve-animations` |

Do not invoke every skill for every change. The phase briefs identify the required subset. When a selected skill points to a topic reference, load only the references needed for the concrete task.

## Documentation handoff rule

No phase is complete with discoveries trapped in a chat or PR description. The completing agent must:

- update this index and the phase status;
- record durable implementation nuances, diagnostics, and reproducible commands in the learning/reference location required by `AGENTS.md`;
- record architecture or product choices in the decision log, linking the relevant v0.4 section;
- state changed paths, verification commands, measured results, remaining risks, and the next phase's prerequisites; and
- update the phase brief if integration changed its decomposition or gate without changing canonical product scope.
