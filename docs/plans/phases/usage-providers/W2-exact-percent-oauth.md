# W2 — Exact percentages via the agents' own tokens (Claude + Codex)

The headline upgrade: real rate-limit percentages using tokens the
user's CLIs already store. Also owns the trust-transition ADR.

**Contract rule:** `makeStrategies` must return the same strategy COUNT
regardless of `context` (Settings' visibility probe calls it with a
no-op/empty context) — all credential/availability gating belongs in
`isAvailable`, never in the strategy list's length.

**Credential bridge:** `UsageFetchContext.credential` is a sync
`@Sendable (UsageProviderID) -> String?`, but `UsageCredentialStore` is
an `actor`. Pre-resolve the credentials you need into a `Sendable
[UsageProviderID: String]` inside the async `UsageRegistryReader.
snapshots(now:)` before building the context, and have the sync
`credential` closure close over that dict. `UsageFetchContext` itself
does not change. Turning `UsageRegistryReader.makeContext` from
`@Sendable (Date) -> UsageFetchContext` into `async` is source-compatible
with existing sync call sites (function subtyping), so it lands here at
near-zero rebase cost even if W3/W4/W5 already merged.

## Owned paths

- `Sources/RafuApp/Usage/Providers/ClaudeProvider.swift` (extend — keep
  the migrated transcript strategy as fallback)
- `Sources/RafuApp/Usage/Providers/CodexProvider.swift` (extend — keep
  the migrated rollout strategy as fallback)
- `Tests/RafuAppTests/Usage/ClaudeOAuthTests.swift`,
  `CodexOAuthTests.swift`
- `docs/decisions/00XX-usage-provider-trust-transition.md` (NEW ADR —
  next free number; also add its row to `docs/decisions/README.md`)

## Scope (verified endpoints — confirm against CodexBar source)

**Claude** (`piggybackNetwork`): strategy order = oauth → transcript
fallback.
- Token: read `~/.claude/.credentials.json` FIRST (silent file read).
  The Keychain item `"Claude Code-credentials"` may ONLY be read from
  the Settings Connect action (consent dialog) — the strategy consumes
  a token the store already holds; it never triggers Keychain itself.
- `GET https://api.anthropic.com/api/oauth/usage`, headers
  `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`,
  honest `User-Agent: Rafu/<version>` first; if the endpoint rejects it,
  document and only then mimic `claude-code/<version>`.
- Parse windows: `five_hour`, `seven_day` (+ per-model 7d if present in
  the `limits[]` array) → `UsageWindow(percent:resetsAt:)`. Expired
  token ⇒ fall back to transcripts (NO refresh flow — refreshing with
  Claude's client id is deferred per the parent plan).

**Codex** (`piggybackNetwork`): strategy order = oauth → rollout
fallback.
- Token: `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`).
- `GET https://chatgpt.com/backend-api/wham/usage` with
  `Authorization: Bearer`, `ChatGPT-Account-Id`, per CodexBar's fetcher.
  Same no-refresh rule; expired ⇒ rollout fallback.

**ADR**: codify the parent plan's "trust transition" section — network
calls carrying user credentials, per-provider opt-in defaults, in-memory
token handling, no-refresh rule, cookie-import consent rules (W1),
redaction requirements. This phase owns writing it because it ships the
first credential-bearing network call.

## Tests

Fixture-driven: real-shaped `oauth/usage` and `wham/usage` JSON →
windows/percent/resets mapping; expired/absent token ⇒ fallback strategy
produces the local estimate; malformed response ⇒ snapshot nil (tile
hidden), never a crash; REDACTION: a thrown transport error containing
headers never surfaces the token (assert on error description).
Injected transport only — no live network in tests.

## Definition of done

Gates green; owned paths only; both providers keep working with NO
credentials present (identical to pre-W2 behavior); ADR added and
indexed; handoff notes the real response shapes observed (for the
reference note the coordinator's documentor writes post-merge).
