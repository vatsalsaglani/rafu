---
title: AI in Rafu
description: Explicit, previewed, redacted — drafting tools, never an autopilot.
---

# AI in Rafu

Rafu uses AI providers in two places: drafting **commit messages** and suggesting
**ignore files** (`.gitignore` / `.dockerignore`). The boundary is absolute in both:
**AI generates editable text. It does not stage files, run commands, write files, or
commit.** You press the button; you see the payload; you edit the result; you decide.

## Choosing the scope

Drafting always starts from a scope you pick:

1. **Staged changes** — the default
2. **Selected files**
3. **All changes**

Before anything is sent, Rafu shows you the exact scope: file count and filenames, the
approximate payload size, and any sensitive-file exclusions and redactions. If the
draft scope differs from what's staged, a warning says so plainly.

## Secrets are excluded and redacted locally

Default exclusions never leave the machine inside a diff:

```text
.env  .env.*  *.pem  *.key  *.p12
id_rsa  credentials*  secrets*  *token*
```

A local redactor also replaces likely assignments — `API_KEY=`, `PASSWORD=`,
`SECRET=`, `TOKEN=`, `Authorization: Bearer …` — with `<redacted>`, keeping enough
context to describe the kind of change without leaking the value.

## Providers

Adapters ship for **OpenAI, Anthropic, Google, and any OpenAI-compatible endpoint** —
you supply the base URL, model, and API key. Drafts stream in token by token, with a
Stop button while generating and a *Rafu live!* connection test in Settings. Your key
lives in the macOS Keychain — never in `UserDefaults`, a file, or a log. Commit style
can be plain or Conventional Commits, with optional custom instructions.

## Ignore files, suggested

When a repository's `.gitignore` or `.dockerignore` is missing or stale, Rafu can
suggest one. The payload is deliberately narrow: a **bounded serialization of the
file tree's relative paths** (capped, oversized directories collapsed) plus the
existing ignore file's own text — **no other file's contents ever leave the machine**.
The proposed file arrives with a reason per pattern, fully editable in the sheet, and
is written only when you explicitly accept.

## Commit hygiene, advisory only

Before you commit, a local heuristic scan of the staged paths can warn about likely
secrets, dependency folders, build artifacts, and OS cruft. It is a warning in the
composer, never a block — and it runs entirely on your machine.

## The rules, verbatim

- No automatic request — network activity only on explicit action
- Request bodies and diffs are never logged or persisted
- Sensitive files excluded by default; binary content never sent
- HTTPS required for non-localhost endpoints
- Oversized diffs require a narrower selection — never silently truncated
- The remote agent never receives the API key; the AI provider never receives SSH credentials

## The flow

```text
You choose a diff scope
        ↓
Local redaction of secrets
        ↓
You preview the exact payload
        ↓
HTTPS to your configured provider
        ↓
Structured { subject, body } back
        ↓
Editable commit form
        ↓
You commit — or don't
```
