# Architecture decisions

This directory records durable Rafu decisions that have meaningful alternatives or long-term consequences.

## Decision order

Accepted ADRs take precedence over older plan suggestions when they explicitly supersede them. The canonical product plan still controls product intent and scope. A phase plan may defer a decision, but it must not quietly contradict an accepted ADR.

## Index

| ADR | Status | Decision |
|---|---|---|
| [0001](0001-swiftpm-bootstrap.md) | Accepted for bootstrap | Use one dependency-free SwiftPM workspace for the initial GUI, CLI, shared core, and tests |
| [0002](0002-native-workbench-navigation.md) | Partially superseded by 0003 | Use one native workbench Navigator and editor-hosted details |
| [0003](0003-files-left-utility-right.md) | Accepted | Files-only left sidebar; Search and Source Control in a right utility panel |
| [0004](0004-embedded-terminal.md) | Accepted | Adopt a lazy, bounded embedded terminal panel built on SwiftTerm |
| [0005](0005-language-intelligence-and-lsp.md) | Accepted | Tree-sitter as the real syntax engine plus an opt-in, memory-bounded LSP client with a transparent, user-controlled server registry |
| [0006](0006-editor-working-set-hibernation.md) | Accepted | Bounded editor working set: keep visible/dirty/newest-8 tabs mounted, hibernate the rest, with a transient dirty-text snapshot for structural remounts |
| [0007](0007-cli-app-location-symlink.md) | Accepted | Install the `rafu` CLI as an in-bundle symlink and locate `Rafu.app` from the real executable path (`_NSGetExecutablePath`), not `argv[0]` |
| [0008](0008-mermaid-native-preview.md) | Superseded by [0020](0020-mermaid-rendering-via-beautiful-mermaid.md) | Bounded native Mermaid renderer with honest fallback: supported subset is flowchart + sequenceDiagram, everything else falls back to a labeled code block + notice; shared-WKWebView option deferred |
| [0009](0009-local-cli-app-ipc.md) | Proposed | Versioned same-user Unix-domain socket for local `rafu` CLI ↔ app IPC (bounded JSON framing, peer-UID auth, `open -a` as app starter only, `--wait` deferred to v2) |
| [0010](0010-npm-supply-chain-and-checksum-policy.md) | Proposed | Accept unpinned transitive npm fetch for nodeHosted servers with mandatory `--ignore-scripts`/`--omit=dev` and explicit consent disclosure; pin locally-verified SHA-256 (trust-on-first-download) per catalog entry |
| [0011](0011-advanced-git-hunks-stash-blame.md) | Proposed | Add explicit whole-hunk staging (verbatim rawPatch slicing via `git apply --cached`), explicit stash with drift guards, and read-only bounded blame |
| [0012](0012-flat-workbench-chrome.md) | Partially superseded by [0022](0022-recessed-workbench-deck.md) | Flat, layered workbench chrome retains theme authority, opaque tonal surfaces, native controls/accessibility, and no Liquid Glass; ADR 0022 supersedes only its flush-main-pane composition, universal-looking radius scale, and rejection of all main-pane gutters |
| [0013](0013-git-experience-scope.md) | Proposed | Scope inline editor blame annotations (off by default), blame-hover/hunk-peek cards, and a theme-colored bounded commit graph; excludes background fetch/poll, repo-wide search scans, avatars, and discard-from-peek |
| [0014](0014-terminal-as-editor-tab.md) | Proposed | Present terminal sessions as first-class, ephemeral (non-restored) editor tabs alongside file tabs, narrowing ADR 0004's bottom-panel-only placement; full lifecycle policy (restoration, cap, agent-workflow polish) remains future scope in `editor-terminal-tabs.md` |
| [0015](0015-github-publishing-via-system-gh.md) | Accepted | Publish to GitHub via the user's own `gh` CLI (account lookup + `repo create --push`), never a bundled OAuth flow or GitHub REST client |
| [0016](0016-terminal-attention-notifications.md) | Proposed; amended 2026-07-22 | Terminal bell attention notifications carry a bounded (6-line/512-byte, control-stripped, viewport-only) output snippet and accept a user-typed reply routed back into the session's pty by a minted UUID; on by default with authorization requested lazily on first actual notify, not at launch. Amendment: the notch companion's peek panel is a third, mutually-exclusive attention surface, and the companion may read other AI tools' local usage files read-only for counts/percentages/timestamps only, never content, never logged/cached/transmitted |
| [0017](0017-usage-provider-trust-transition.md) | Accepted | Keep local provider enablement separate from explicit credential-bearing network consent; external CLI tokens remain minimal, bounded, memory-only, file-first, no-refresh, and redacted |
| [0018](0018-conductor-external-agent-orchestration.md) | Accepted; amended 2026-07-26 | The Ensemble orchestrates external, user-installed agent CLIs (Claude Code, Codex, OpenCode, Cline, Kimi, Gemini, Cursor — with per-role model selection) as child processes with fully delegated auth, file-based handoffs, plain-file `.rafu/` configuration, Rafu-created worktrees, and an always-gated merge-back; Rafu embeds no agent and holds no inference credentials. Amendment: coordinator verbs, capability token, streaming |
| [0019](0019-external-file-opening-and-media-preview.md) | Proposed | Open arbitrary external files (outside workspace root) as first-class editor tabs with atomic writes to original paths; media preview boundary with bitmap/SVG/video inline rendering (via NSImage and AVKit) and UTF-8 text fallback; external files are ephemeral (not restored) and workspace-identity-separate |
| [0020](0020-mermaid-rendering-via-beautiful-mermaid.md) | Accepted | Adopt `beautiful-mermaid-swift` 1.0.4 + `elk-swift` 1.0.2 (MIT, pinned exact) for Mermaid parse/layout/raster, superseding ADR 0008's hand-written engine and reversing its no-new-dependency clause; supported types 2 → 6, still no JS engine and no WKWebView; ADR 0008's honest-fallback contract and Rafu-owned classification/strings survive; package state is actor-confined because `PreparedDiagram` is non-Sendable and `LabelRenderer` hijacks the ambient `NSGraphicsContext`, so only a `CGImage` crosses and rendering goes to an offscreen bitmap only |
| [0021](0021-agent-terminals.md) | Accepted | Launch tokenless interactive vendor CLIs as first-class, ephemeral Agent Terminal sessions: absolute executable + argv array, an environment of exactly a curated `PATH` (no `RAFU_*` keys, no capability token, no capture, no manifest), model flags only for probe-verified CLI shapes, delegated auth with visibly-disabled unavailable CLIs, `.agentTerminal` resource identity distinct from Ensemble's `.agent`, and pinned nominative-use vendor marks with a system-symbol fallback |
| [0022](0022-recessed-workbench-deck.md) | Accepted | Supersede ADR 0012's flush-main-pane composition with one 4 pt recessed workbench deck, compact semantic workbench radii, attached active tabs, measured 4 pt editor-group separation including native splitters, and collision-safe theme-resolved terminal perimeters while preserving opaque JSON-theme surfaces, accessibility, and no Liquid Glass |

Unresolved choices are tracked in [`open-decisions.md`](open-decisions.md).

## ADR template

Each ADR contains:

- Status and date
- Context
- Decision
- Alternatives considered
- Consequences
- Revisit trigger, if any
- Related plan, reference, and implementation paths

Do not rewrite the historical decision when circumstances change. Add a superseding ADR and update this index.
