# Architecture decisions

This directory records durable Rafu decisions that have meaningful alternatives or long-term consequences.

## Decision order

Accepted ADRs take precedence over older plan suggestions when they explicitly supersede them. The canonical product plan still controls product intent and scope. A phase plan may defer a decision, but it must not quietly contradict an accepted ADR.

## Index

| ADR | Status | Decision |
|---|---|---|
| [0001](0001-swiftpm-bootstrap.md) | Accepted for bootstrap | Use one dependency-free SwiftPM workspace for the initial GUI, CLI, shared core, and tests |
| [0002](0002-native-workbench-navigation.md) | Partially superseded by 0003 | Use one native workbench Navigator and editor-hosted details |
| [0003](0003-files-left-utility-right.md) | Superseded by [0030](0030-framed-workbench-left-rail-and-detached-tabs.md) (mode placement and right panel) | Files-only left sidebar; Search and Source Control in a right utility panel |
| [0004](0004-embedded-terminal.md) | Accepted; terminal presentation details superseded by 0023 | Adopt the lazy, bounded SwiftTerm terminal boundary |
| [0005](0005-language-intelligence-and-lsp.md) | Accepted | Tree-sitter as the real syntax engine plus an opt-in, memory-bounded LSP client with a transparent, user-controlled server registry |
| [0006](0006-editor-working-set-hibernation.md) | Accepted | Bounded editor working set: keep visible/dirty/newest-8 tabs mounted, hibernate the rest, with a transient dirty-text snapshot for structural remounts |
| [0007](0007-cli-app-location-symlink.md) | Accepted | Install the `rafu` CLI as an in-bundle symlink and locate `Rafu.app` from the real executable path (`_NSGetExecutablePath`), not `argv[0]` |
| [0008](0008-mermaid-native-preview.md) | Superseded by [0020](0020-mermaid-rendering-via-beautiful-mermaid.md) | Bounded native Mermaid renderer with honest fallback: supported subset is flowchart + sequenceDiagram, everything else falls back to a labeled code block + notice; shared-WKWebView option deferred |
| [0009](0009-local-cli-app-ipc.md) | Proposed | Versioned same-user Unix-domain socket for local `rafu` CLI ↔ app IPC (bounded JSON framing, peer-UID auth, `open -a` as app starter only, `--wait` deferred to v2) |
| [0010](0010-npm-supply-chain-and-checksum-policy.md) | Proposed | Accept unpinned transitive npm fetch for nodeHosted servers with mandatory `--ignore-scripts`/`--omit=dev` and explicit consent disclosure; pin locally-verified SHA-256 (trust-on-first-download) per catalog entry |
| [0011](0011-advanced-git-hunks-stash-blame.md) | Proposed | Add explicit whole-hunk staging (verbatim rawPatch slicing via `git apply --cached`), explicit stash with drift guards, and read-only bounded blame |
| [0012](0012-flat-workbench-chrome.md) | Partially superseded by [0022](0022-recessed-workbench-deck.md) and [0030](0030-framed-workbench-left-rail-and-detached-tabs.md) (no-shadow rule and the 2026-10-19 left-rail amendment) | Flat, layered workbench chrome retains theme authority, opaque tonal surfaces, native controls/accessibility, and no Liquid Glass; ADR 0022 supersedes only its flush-main-pane composition, universal-looking radius scale, and rejection of all main-pane gutters |
| [0013](0013-git-experience-scope.md) | Proposed | Scope inline editor blame annotations (off by default), blame-hover/hunk-peek cards, and a theme-colored bounded commit graph; excludes background fetch/poll, repo-wide search scans, avatars, and discard-from-peek |
| [0014](0014-terminal-as-editor-tab.md) | Proposed; terminal-layout details superseded by 0023 | Historical editor-tab placement decision; legacy terminal-resource decoding remains compatible during Terminal Group migration |
| [0015](0015-github-publishing-via-system-gh.md) | Accepted | Publish to GitHub via the user's own `gh` CLI (account lookup + `repo create --push`), never a bundled OAuth flow or GitHub REST client |
| [0016](0016-terminal-attention-notifications.md) | Proposed; amended 2026-07-22 | Terminal bell attention notifications carry a bounded (6-line/512-byte, control-stripped, viewport-only) output snippet and accept a user-typed reply routed back into the session's pty by a minted UUID; on by default with authorization requested lazily on first actual notify, not at launch. Amendment: the notch companion's peek panel is a third, mutually-exclusive attention surface, and the companion may read other AI tools' local usage files read-only for counts/percentages/timestamps only, never content, never logged/cached/transmitted |
| [0017](0017-usage-provider-trust-transition.md) | Partially superseded by 0027 | Keep local provider enablement separate from explicit credential-bearing network consent; external CLI tokens remain minimal, bounded, memory-only, file-first, no-refresh, and redacted |
| [0018](0018-conductor-external-agent-orchestration.md) | Accepted; amended 2026-07-26 | The Ensemble orchestrates external, user-installed agent CLIs (Claude Code, Codex, OpenCode, Cline, Kimi, Gemini, Cursor — with per-role model selection) as child processes with fully delegated auth, file-based handoffs, plain-file `.rafu/` configuration, Rafu-created worktrees, and an always-gated merge-back; Rafu embeds no agent and holds no inference credentials. Amendment: coordinator verbs, capability token, streaming |
| [0019](0019-external-file-opening-and-media-preview.md) | Proposed | Open arbitrary external files (outside workspace root) as first-class editor tabs with atomic writes to original paths; media preview boundary with bitmap/SVG/video inline rendering (via NSImage and AVKit) and UTF-8 text fallback; external files are ephemeral (not restored) and workspace-identity-separate |
| [0020](0020-mermaid-rendering-via-beautiful-mermaid.md) | Accepted | Adopt `beautiful-mermaid-swift` 1.0.4 + `elk-swift` 1.0.2 (MIT, pinned exact) for Mermaid parse/layout/raster, superseding ADR 0008's hand-written engine and reversing its no-new-dependency clause; supported types 2 → 6, still no JS engine and no WKWebView; ADR 0008's honest-fallback contract and Rafu-owned classification/strings survive; package state is actor-confined because `PreparedDiagram` is non-Sendable and `LabelRenderer` hijacks the ambient `NSGraphicsContext`, so only a `CGImage` crosses and rendering goes to an offscreen bitmap only |
| [0021](0021-agent-terminals.md) | Accepted | Launch tokenless interactive vendor CLIs as first-class, ephemeral Agent Terminal sessions: absolute executable + argv array, an environment of exactly a curated `PATH` (no `RAFU_*` keys, no capability token, no capture, no manifest), model flags only for probe-verified CLI shapes, delegated auth with visibly-disabled unavailable CLIs, `.agentTerminal` resource identity distinct from Ensemble's `.agent`, and pinned nominative-use vendor marks with a system-symbol fallback |
| [0022](0022-recessed-workbench-deck.md) | Partially superseded by [0030](0030-framed-workbench-left-rail-and-detached-tabs.md) (4 pt inset, 6 pt radius, attached-cap tabs, no-shadow consequence) | Supersede ADR 0012's flush-main-pane composition with one 4 pt recessed workbench deck, compact semantic workbench radii, attached active tabs, measured 4 pt editor-group separation including native splitters, and collision-safe theme-resolved terminal perimeters while preserving opaque JSON-theme surfaces, accessibility, and no Liquid Glass |
| [0023](0023-terminal-groups-and-saved-layouts.md) | Accepted; amended 2026-10-19 | Define one Terminal Group editor tab with bounded recursive panes, explicit user-start only, and inert workspace-local saved layouts; Agent Terminal and Ensemble panes restore only as unavailable placeholders without launch descriptors or capability data. Amendment: an Ensemble terminal card may carry a chosen shell persisted in the inert layout with no process restoration, and every Ensemble key equivalent exists only while a board is the selected tab |
| [0024](0024-terminal-group-v2-limits-and-pane-metadata.md) | Accepted | Separate Terminal Group resource limits and add bounded runtime pane-name and theme-token metadata commands |
| [0025](0025-workspace-canvas-and-app-previews.md) | Accepted; amended 2026-10-19 | Optional Workspace Canvas with native notes, one-owner terminal presentation, bounded local web and selected-window app previews, and inert restoration. Amendment: a one-pane live Terminal Group can move onto a board by drag or menu without restarting. Amendment 2: undo of that move restores the tab in its source editor group (process keeps running), superseding "undo removes only the card" |

| [0026](0026-canvas-live-session-links.md) | Accepted | Any two Canvas nodes can be linked; a link between terminal nodes permits bounded messages between their live Claude Code or Codex sessions; other links stay labelled relationships, and no file text or app capture is sent |
| [0027](0027-connected-usage-refresh.md) | Accepted | Allow bounded Claude Keychain re-reads after Connect and visibly stale usage retention; preserve external token and network consent boundaries |
| [0028](0028-ensemble-bridge-shell-strategies.md) | Accepted | Agent links on non-native shells use per-basename strategies — login emulation with a private `ENV` file for sh/dash/ksh/mksh, `HOME` forwarding for tcsh/csh, documented post-config hooks for fish/nu/xonsh, and environment-only PATH with an honest notice for elvish and unknown shells; no user rc file is edited, and host Claude Code session variables are scrubbed from the bridge environment by an exact list |
| [0029](0029-agent-status-vocabulary.md) | Accepted | Seven agent-card states (working, needsYou(approval/input), failed, doneUnread, done, inactive, stopped) with a fixed precedence; Failed only from a reported hook/CLI failure and never from an exit code (so Codex can never show Failed); inactive at 30 min; no cost, no sub-agent count, no tab badge, and session-scoped read/unread |
| [0030](0030-framed-workbench-left-rail-and-detached-tabs.md) | Partially superseded by [0031](0031-card-header-tabs-and-themed-chrome.md) (deck geometry/shadow, minimum width, tab fill/outline/font/shelf, the `+` presentation) | Framed workbench: quiet `appBackground` window frame with one raised rounded editor deck (8 pt inset, 10 pt radius, bounded theme-aware shadow), one always-visible left Activity Rail carrying all five navigator modes (right rail and right utility panel removed), a custom drag-to-resize/collapse sidebar handle with persisted width, and detached rounded tab cards with activity dots and a focus-safe text-only hover preview |
| [0031](0031-card-header-tabs-and-themed-chrome.md) | Accepted | Card-header tabs (selected = `tabActiveBackground` + `borderSubtle` hairline + semibold 12.5 pt, inactive unfilled, no accent edge), a fixed 38 pt `tabBarBackground` shelf with one header hairline and grey overflow fades, deck radius 12 / inset 10 with stronger theme-aware shadows, a darker Indigo frame `#0C0F15` with `borderStrong` `#6A748D`, a 774 pt minimum window, a hover-only sidebar seam, a native rail app tile, flat Files-tree rows behind a custom `DisclosureGroupStyle`, and a themed `NSScroller` that never forces `scrollerStyle`

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
