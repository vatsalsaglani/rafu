---
title: Usage tracking
description: Real 5-hour and 7-day budgets for the coding agents you run, read-only and opt-in.
---

# Usage tracking

Coding agents ration you — a 5-hour window here, a weekly cap there — and finding out
you're close usually means the agent tells you mid-task. Rafu can show real usage
numbers for the agents and tools you actually run, right in the
[notch companion](/docs/notch-companion), read before you hit the wall instead of
after.

Every provider is configured in **Settings → Usage**, one row each: what Rafu reads,
where it's sent (if anywhere), a Connect action or a place to paste a key, and an
enable toggle. Nothing here is a dashboard *about* your agents' behavior — it's the
same percentage or token count the provider's own tool would show you, read locally.

## How a provider connects

Rafu never guesses; it reads exactly what the underlying tool already stores, and each
network-reaching provider requires your explicit action before it makes a request:

**On by default, fully local — no network at all**
: OpenCode, OpenCode Go read the local database those tools already keep. Nothing
  leaves your machine.

**On by default, local with an optional exact read**
: Claude and Codex show a token-based estimate from local session files immediately.
  Click Connect to additionally get the exact percentage from the provider's own API,
  using the login your CLI already has — Rafu never asks you to sign in again.

**Off by default — Connect to read the CLI's existing login**
: Cursor, Antigravity, Gemini CLI, GitHub Copilot, Kimi. Connect reads the token that
  tool's own CLI already stored and calls that provider's usage endpoint once.

**Off by default — paste an API key**
: Cline / ClinePass, Kilo Code, Amp, OpenRouter, Warp, Qwen.

**Off by default — one-time browser cookie import**
: Grok Build, Factory Droid, Qoder. Used only when a provider has no local token or
  key to read; the import happens once, from a button you click, never silently.

## What every strategy is bound to

- **Read-only.** Nothing in this system stages, commits, writes, or executes anything.
- **Metric fields only.** Percent used, token totals, and reset times — never message
  or prompt content, from any provider.
- **Nothing logged.** Tokens, cookies, and keys are never written to a log; keys you
  paste are stored in the macOS Keychain, never `UserDefaults` or a plain file.
- **Fails quiet.** A provider that's unreachable, unauthenticated, or rate-limited
  simply doesn't show a tile — never a fake number, never a blocked panel.

## Choosing what shows

The notch panel's usage line holds four tiles — Claude and Codex lead by default —
before it collapses everything else behind a `▸ N more providers` disclosure that
expands into a small grid. Nothing is hidden permanently: it's one click away, every
time you peek the panel.
