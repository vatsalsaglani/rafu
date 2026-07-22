---
title: Language intelligence
description: A three-tier navigation ladder — LSP when you opt in, syntactic always.
---

# Language intelligence

Navigation — go to definition, find references — should work regardless of language,
and language servers must never be the reason your editor balloons. Rafu's answer is
real Tree-sitter highlighting for everyone, plus a bounded navigation ladder that
degrades gracefully and **labels its tier**, so precision is never overstated.

## Highlighting, always local

Every open buffer is parsed incrementally by **Tree-sitter** — off the main thread,
re-parsing only what changed — and colored through the active theme's syntax tokens,
so Indigo and Khadi (and any theme you write) apply to code exactly as designed.
Bundled grammars: **Swift, Python, JavaScript, TypeScript, TSX, JSON, YAML, TOML,
Bash, Markdown, and Dockerfile**, with Markdown's inline grammar handling emphasis
and code spans. Very large files open in a plain-text guard mode rather than slowing
the editor down, and grammar-less files fall back to a bounded regex scanner.

LSP never colors your code — one tokenizer, not two.

## The three-tier ladder

1. **LSP tier** — a configured, trusted, running server answers definition,
   declaration, references, hover, and symbols (*"via rust-analyzer"*).
2. **Syntactic tier** — a bounded workspace symbol index built from Tree-sitter
   declaration captures answers with ranked candidates (*"syntactic match"*). It works
   for every bundled grammar with zero configuration — it matches names, not semantics,
   and says so.
3. **Text tier** — bounded workspace text search, the floor for languages with neither
   grammar nor server.

The same commands — Go to Definition (`⌃⌘J`), Go to Declaration, Find References
(`⌃⌘R`), and `⌘`-click — route down the ladder. Features never disappear; they lose
precision visibly.

## Opt-in servers, transparently

Language servers are **off by default**. When you enable one:

- A curated registry covers the usual suspects — rust-analyzer, clangd, marksman,
  gopls, sourcekit-lsp, typescript-language-server, Pyright — or you **supply your
  own**: a local binary, or a GitHub release asset with arguments
- Every install shows a consent sheet first: exact URL, version, size, license, and
  SHA-256 checksum, verified before first launch
- Each workspace approves a server before it runs — a trust prompt, persisted and
  revocable in Settings
- Servers start lazily on first request, shut down when idle, and restart with
  backoff; each has a **4 GB memory ceiling** that kills it and tells you, and the
  Resources view shows live per-server cost
- Today's capabilities: definition, declaration, references, hover, and document
  symbols. Diagnostics, rename, and code actions are a deliberately separate later
  slice — the editor never pretends a server feature exists when it doesn't

Workspace trust gates execution, exactly as it does for Git hooks: an untrusted
workspace edits and views fine, but nothing executes.

## What this is not

- **Not an extension host.** There is no plugin runtime, and there won't be.
- **Not the full LSP ecosystem.** A transparent registry of specific servers, not an
  open pipeline for arbitrary ones.
- **Not a requirement.** Tree-sitter highlighting and the syntactic navigation tier are
  always on, always local, and always free of configuration.
