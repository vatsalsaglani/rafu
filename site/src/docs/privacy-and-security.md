---
title: Privacy & security
description: What's at stake, where the trust boundaries are, and the controls on each.
---

# Privacy & security

Rafu handles the things a developer least wants leaked: source files, unsaved buffers,
SSH credentials, API keys, and the diffs that may contain secrets. The security model
is part of the product, not a preface to it.

## What Rafu never does

- **No silent network calls.** AI requests happen only on explicit action, after you
  preview the exact payload. Remote images in Markdown are blocked by default. There is
  no analytics or telemetry in the product plan.
- **No credential logging or persistence in plain text.** Secrets live in the macOS
  Keychain — never `UserDefaults`, files, fixtures, or logs. Document text, diffs, and
  askpass responses are never logged.
- **No silent overwrite.** External file changes never replace a dirty buffer; remote
  saves are atomic and version-checked.
- **No silent host-key acceptance.** OpenSSH's `known_hosts` stays authoritative; a
  changed host key is a blocking error.
- **No shell strings.** Processes spawn as an executable plus an argument array —
  workspace paths, Git arguments, and user input are never interpolated into a shell
  command.

## Trust boundaries

```text
CLI process → native app IPC        peer-validated, size-bounded, versioned
Native app → system SSH process     your config, your keys, your known_hosts
System SSH → remote host            OpenSSH is the security authority
Native app → AI provider            HTTPS, Keychain-stored key, previewed payloads
Workspace files → Git hooks         trust prompt before the first hook can run
```

## Per-subsystem controls

**SSH.** The system `/usr/bin/ssh` is the only SSH authority — `Include`, `ProxyJump`,
identity files, agents, security keys, and certificates behave as they already do.
Askpass prompts are window-scoped, never logged, never persisted.

**Remote agent.** No listening socket; runs as your remote user; versioned,
size-bounded protocol frames; atomic writes with expected-version conflict checks;
path-traversal protection.

**CLI IPC.** User-only socket directory, peer validation, versioned bounded messages,
canonicalized paths, and no remote command-execution surface.

**AI.** Local secret redaction, sensitive-file exclusions, explicit payload preview,
HTTPS required beyond localhost, no request logging, no persisted payloads. Ignore-file
suggestions send only bounded relative tree paths plus the existing ignore file's text —
never other file contents — and write nothing without an explicit accept.

**Git.** Argument arrays with `--` path separators, trust prompts before hook-capable
actions, hook output preserved and shown, no destructive reset/clean UI.

**Usage tracking.** Every provider beyond the fully-local ones (see
[Usage tracking](/docs/usage-tracking)) requires an explicit Connect, pasted key, or
one-time cookie import before it makes a single request. Only metric fields — percent
used, token totals, reset times — are ever read; message and prompt content are never
touched. Pasted keys live in the Keychain; nothing is logged, and a failing or
unauthenticated provider just doesn't show a tile.

## Local builds and Gatekeeper

Until signed distribution ships, locally built bundles may be quarantined. The
supported workaround is per-bundle, never system-wide:

```bash
xattr -dr com.apple.quarantine /path/to/Rafu.app
```

Published builds will use Developer ID signing and notarization.

## Reporting

If you believe you've found a security issue, report it privately rather than in a
public issue — see `SECURITY.md` in the repository for the current contact and scope.
