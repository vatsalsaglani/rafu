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
| [0008](0008-mermaid-native-preview.md) | Proposed | Bounded native Mermaid renderer with honest fallback: supported subset is flowchart + sequenceDiagram, everything else falls back to a labeled code block + notice; shared-WKWebView option deferred |
| [0009](0009-local-cli-app-ipc.md) | Proposed | Versioned same-user Unix-domain socket for local `rafu` CLI ↔ app IPC (bounded JSON framing, peer-UID auth, `open -a` as app starter only, `--wait` deferred to v2) |
| [0010](0010-npm-supply-chain-and-checksum-policy.md) | Proposed | Accept unpinned transitive npm fetch for nodeHosted servers with mandatory `--ignore-scripts`/`--omit=dev` and explicit consent disclosure; pin locally-verified SHA-256 (trust-on-first-download) per catalog entry |
| [0011](0011-advanced-git-hunks-stash-blame.md) | Proposed | Add explicit whole-hunk staging (verbatim rawPatch slicing via `git apply --cached`), explicit stash with drift guards, and read-only bounded blame |
| [0012](0012-flat-workbench-chrome.md) | Proposed | Flat, layered workbench chrome (tonal surfaces + hairlines, single continuous-corner scale, card language for overlays) supersedes system-material sidebars/toolbar band; native toolbar/controls/accessibility retained; no Liquid Glass |
| [0013](0013-git-experience-scope.md) | Proposed | Scope inline editor blame annotations (off by default), blame-hover/hunk-peek cards, and a theme-colored bounded commit graph; excludes background fetch/poll, repo-wide search scans, avatars, and discard-from-peek |
| [0014](0014-terminal-as-editor-tab.md) | Proposed | Present terminal sessions as first-class, ephemeral (non-restored) editor tabs alongside file tabs, narrowing ADR 0004's bottom-panel-only placement; full lifecycle policy (restoration, cap, agent-workflow polish) remains future scope in `editor-terminal-tabs.md` |
| [0015](0015-github-publishing-via-system-gh.md) | Accepted | Publish to GitHub via the user's own `gh` CLI (account lookup + `repo create --push`), never a bundled OAuth flow or GitHub REST client |

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
