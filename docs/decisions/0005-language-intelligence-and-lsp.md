# ADR 0005: Bounded language intelligence — Tree-sitter engine plus an opt-in LSP client

- **Status:** Accepted (narrows the "full LSP ecosystem" initial non-goal)
- **Date:** 2026-07-14

## Context

Rafu today highlights with a bounded regex window scanner
(`Sources/RafuApp/Editor/SyntaxHighlighter.swift` emits Neon token types;
SwiftTreeSitter 0.8.0 is pinned in `Package.swift` but unwired) and the
palette's `@` mode regex-scans only the active buffer
(`BufferSymbolScanner`). There is no go-to-definition, no find-references,
and no cross-file symbol navigation. Plan v0.4 already commits to Tree-sitter
(§7.4–7.5) and placed "a small number of optional built-in language servers,
disabled by default" in Phase 6 optional scope.

On 2026-07-14 the user gave explicit direction: navigation ("go to references
and find declarations") must work regardless of language, and language
servers must be transparent and customizable — Rafu discloses which server it
would download and from where, and the user can instead supply their own
server (a GitHub release path or local binary). That intentionally narrows
the "full LSP ecosystem" non-goal, recorded here rather than silently
contradicting AGENTS.md.

A decade of VS Code/Cursor memory pain shapes the bounds. Language servers
are the second-largest editor memory sink after the extension host: tsserver
growth earned a dedicated `typescript.tsserver.maxTsServerMemory` setting,
and un-attributed multi-GB processes are how an editor quietly loses the
"why is it using 4 GB" argument. Implicit always-on servers are the exact
failure mode Rafu exists to avoid.

Alternatives considered:

1. **Tree-sitter only, no LSP** — private and cheap, but syntactic: it
   matches names, not semantics, and cannot resolve imports, overloads, or
   project configuration. Kept as the always-available fallback tier;
   rejected as the whole answer.
2. **Bundled always-on servers (VS Code-style implicit)** — best out-of-box
   precision, but violates predictable memory and explicit user control.
3. **An extension host** — rejected outright; remains a non-goal.
4. **A thin native LSP client with a transparent, user-controlled server
   registry, layered over a Tree-sitter fallback tier** — chosen.

## Decision

- Navigation is a **three-tier ladder** that degrades gracefully and labels
  its tier so precision is never overstated:
  1. **LSP tier** — a configured, trusted, running server answers
     definition/declaration/references/hover/symbols ("via rust-analyzer").
  2. **Syntactic tier** — a bounded workspace symbol index built from
     Tree-sitter declaration captures answers with ranked candidates
     ("syntactic match"); works for every bundled grammar with zero
     configuration.
  3. **Text tier** — bounded workspace text search as the floor for
     languages with neither grammar nor server.
  The same commands (Go to Definition, Go to Declaration, Find References,
  ⌘-click) route down the ladder; features never disappear, they lose
  precision visibly.
- Tree-sitter becomes the real syntax engine per plan §7.5 (incremental
  per-buffer parsing, capture→theme-token mapping), replacing the regex
  window scanner. Grammars are bundled and curated; **no user-supplied
  grammar dylibs** — dynamic code loading needs its own decision.
- The LSP client is Rafu-native: JSON-RPC over stdio to child processes
  spawned with an executable plus argument array (standing invariant), one
  instance per language per workspace, **lazy start** on first request,
  **idle shutdown** by default, restart with backoff, and a **hard
  per-server RSS ceiling** that kills and notifies rather than letting the
  machine swap.
- The server registry is explicit and user-owned. Each entry names the
  binary, arguments, install source (URL or GitHub release), version,
  checksum when published upstream, license, and runtime prerequisites.
  Rafu never downloads or launches silently: installs require consent that
  shows exactly what comes from where; first launch per workspace requires a
  trust confirmation. Users can add their own entries pointing at a GitHub
  release asset or a local binary.
- LSP does **not** do highlighting (Tree-sitter owns color — one tokenizer,
  not two), does not run over SSH in this scope, and never becomes an
  extension host, marketplace, or auto-discovery system. "Full LSP
  ecosystem" stays excluded in that sense.

## Consequences

- AGENTS.md's non-goal sentence is narrowed the same way ADR 0004 narrowed
  the terminal non-goal; the extension-host exclusion stands unchanged.
- Phase 6's "a few opt-in bundled language servers" line and Phase 2's
  "optional Tree-sitter outline" item are superseded by the dedicated brief
  [`docs/plans/phases/language-intelligence.md`](../plans/phases/language-intelligence.md).
- Memory accounting changes shape: servers are attributed, user-visible
  child processes (the Resources surface in
  [`docs/plans/phases/memory-resilience.md`](../plans/phases/memory-resilience.md)),
  never hidden inside Rafu's own number. Rafu's idle budget (< 150 MB) is
  unaffected by servers the user has not started.
- New security-review surface: binary downloads (checksum, quarantine,
  Application Support install location), per-workspace trust prompts, and
  the rule that document text may flow to a local server process but never
  into Rafu logs.

**Revisit trigger:** per-server ceilings proving too blunt (legitimate
servers killed on large repos) revisits sizing, not the ceiling concept;
demand for LSP over SSH is a new ADR.

**Related:** plan v0.4 §3.3, §7.3–7.5, Phase 6;
[`language-intelligence.md`](../plans/phases/language-intelligence.md);
[`memory-resilience.md`](../plans/phases/memory-resilience.md);
`Sources/RafuApp/Editor/SyntaxHighlighter.swift`,
`Sources/RafuApp/Editor/BufferSymbols.swift`.
