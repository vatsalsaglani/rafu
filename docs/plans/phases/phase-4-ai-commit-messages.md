# Phase 4 — AI-generated commit messages

- **Status:** Planned
- **Depends on:** Phase 3
- **Canonical scope:** v0.4 §12, §13 AI controls, and §15 Phase 4

## Goal

Add a narrow, safe accelerator that converts an explicitly previewed sanitized diff into editable commit subject/body text without staging, executing tools, or committing automatically.

## Scoped deliverables

- `CommitMessageProvider` abstraction and OpenAI-compatible implementation.
- Settings for provider name, base URL, Responses/Chat Completions compatibility mode, model, API key, timeout/payload limit, Plain/Conventional style, and custom instructions.
- Keychain-backed API key and nonsecret preferences.
- Staged-default, selected-files, and all-changes scopes with filenames/count/size, mismatch warning, exclusions/redactions, and exact payload preview.
- Responses API structured output when supported; Chat Completions and plain-JSON fallbacks; local schema validation, retry, cancellation, and editable result.
- Local sanitizer for sensitive filenames/likely assignments/authorization headers; binary and oversized-diff refusal.

## Explicit non-goals

- AI chat, inline generation, agents, tool calls, automatic staging, automatic commit, silent requests, arbitrary truncation, persisted payloads, remote API keys, or a bundled shared vendor key.
- A backend service or product-funded credentials.

## Owned paths

- Provider owner: `Rafu/CommitAI/OpenAICompatibleProvider.swift`, request/response models, network tests.
- Sanitization/scope owner: `Rafu/CommitAI/DiffSanitizer.swift`, prompt builder, fixtures/tests.
- Secrets/settings owner: `Rafu/Security/KeychainStore.swift`, AI settings surfaces and tests.
- UI owner: generation scope/payload preview and commit-form integration under `Rafu/CommitAI`/`Rafu/Git`.
- Integration owner controls shared commit/diff models and settings composition.

## Locked decisions

- API networking happens in the Mac app through `URLSession`; remote agent never receives the key.
- HTTPS is required except localhost.
- Staged changes are the default scope; every request is explicit and previewed.
- Sensitive files are excluded by default and likely values are locally redacted.
- Result is validated, editable, rejectable, and never auto-committed.

## Open blockers to resolve

- Default request timeout and payload limit from measured provider behavior.
- Exact structured-output capability detection and path joining for compatible base URLs.
- User override UX for excluded files without weakening explicit preview.
- Subject/body validation limits and Conventional Commit policy.

## Required project references

- [`../../references/build-and-run.md`](../../references/build-and-run.md)
- [`../../references/concurrency.md`](../../references/concurrency.md)

## Required skills and capabilities

- `.agents/skills/swift-concurrency-pro` for `URLSession`, cancellation, timeouts, and stale request handling.
- `.agents/skills/design-an-interface` before locking provider, scope, sanitized-payload, and suggestion contracts.
- `.agents/skills/swiftui-expert-skill` for settings, preview, focus, and commit-form data flow.
- `.agents/skills/apple-design` for agency, responsibility, warnings, and inline error feedback.
- `build-macos-apps:swiftui-patterns` for Settings and source-control integration.
- `build-macos-apps:build-run-debug` and `build-macos-apps:telemetry` for provider/error verification without payload logging; use `build-macos-apps:test-triage` only after a failure.
- `build-macos-apps:signing-entitlements` only when Keychain/signing behavior fails in an exported app.

## Worktree decomposition and integration order

1. Integration owner freezes provider, scope, suggestion, validation, and sanitized-payload models.
2. Provider, sanitizer/scope, and secrets/settings agents proceed in parallel with fake providers.
3. Integrate sanitizer and payload preview before enabling real network requests.
4. Integrate Keychain/settings and provider adapters.
5. Integrate editable commit-form UI last; then run privacy/error matrix.

## Verification and measurements

- Secret exclusion/redaction false-positive/negative fixtures, prompt-injection diff text, binary content, huge diff, scope mismatch, mixed staged/unstaged state, and remote diff flow.
- Provider timeout, cancellation, rate limit, TLS/HTTP rejection, schema error, malformed JSON, base URL path joining, Responses and compatibility modes.
- Inspect Keychain behavior and verify no key in defaults, logs, crash restoration, remote protocol, or test snapshots.
- Verify exact preview bytes correspond to the sent sanitized payload and requests occur only after confirmation.
- Measure payload construction and UI responsiveness on multi-megabyte diffs; require narrower scope instead of arbitrary truncation.
- Accessibility/keyboard review of scope selector, warning, preview, retry, and editable result.

## Exit criteria

- User can preview the exact sanitized local or remote diff payload.
- `.env` and likely-secret files are excluded by default and redactions are disclosed.
- Generated subject/body matches the displayed scope and validates locally.
- User can edit, reject, retry, or cancel before committing.
- No credential reaches the remote agent and no full diff/request body is logged or persisted.

## Documentation handoff

Record provider modes, URL/TLS rules, structured-output schema, prompt version, scope and redaction policy, Keychain identifiers, limits/timeouts, privacy verification, and compatibility fixtures. Hand Phase 5 a complete data-flow/threat-model update.
