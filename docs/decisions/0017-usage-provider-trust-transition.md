# ADR 0017: Separate local usage enablement from explicit provider-network consent

- **Status:** Accepted
- **Date:** 2026-07-23

## Context

Rafu's first usage providers were local-only: Claude transcript totals and
Codex rollout percentages. W2 adds more accurate percentages by calling each
provider's first-party, read-only usage endpoint with credentials already
owned by that provider's CLI. This crosses a material trust boundary. Reading
local metric fields does not imply permission to transmit an access token, and
enabling a provider tile does not imply consent for credential-bearing network
traffic.

The CLIs also have different credential layouts. Both expose bounded local
files; Claude Code may additionally hold the same OAuth record in a Keychain
item whose service is `Claude Code-credentials`. Rafu must not become a second
OAuth authority, persist another application's token, or silently refresh it.

## Decision

### Enablement and network consent are independent

- `UsageEnableStore` continues to control whether a provider participates in
  the usage pipeline. Claude and Codex remain enabled by default because their
  local fallback strategies are zero-configuration and read-only.
- `UsageNetworkConsentStore` separately records whether the user has completed
  an explicit Connect action for a provider. It defaults to false.
- Disconnect revokes network consent and clears transient external credentials
  without disabling the provider's local fallback. Toggling provider
  enablement does not silently grant or revoke network consent.

### Connect is a credential-validation action, never a network action

- Connect validates the provider-owned credential file first:
  `~/.claude/.credentials.json` for Claude and `$CODEX_HOME/auth.json` or
  `~/.codex/auth.json` for Codex.
- Only Claude may fall back to another application's Keychain, and only from
  the explicit Connect path. The sole production service queried is
  `Claude Code-credentials`. Opening Settings, refreshing usage, and executing
  a strategy never query Claude Code's Keychain.
- Codex never queries Claude Code's Keychain. Neither Connect path performs a
  network request. Consent is written only after a valid, unexpired credential
  is found; a failed or cancelled Connect leaves no consent or transient token.
- Files are re-read after consent during refresh so a CLI's newer token wins.
  A Claude credential obtained from Claude Code's Keychain is only a
  process-memory fallback when no usable file credential exists.

### External credentials are minimized and ephemeral

- The only value crossing into `UsageFetchContext.credential` is a bounded,
  codable envelope containing `accessToken`, optional `accountID`, and optional
  `expiresAt`. Unknown fields are rejected. Refresh tokens, ID tokens, scopes,
  cookies, and provider metadata are never copied into the envelope.
- Claude/Codex tokens never pass through `UsageCredentialStore.setCredential`
  and are never written to Rafu's Keychain, `UserDefaults`, another file, or a
  log. A Claude Keychain fallback may live only in the actor's bounded
  process-memory cache and is removed on disconnect.
- Credential files, Keychain payloads, and envelopes are capped at 16 KiB.
  Resolution happens off the main actor before the synchronous fetch context
  is built. OAuth strategies consume only the immutable envelope and do not
  read files or Keychain themselves.

### Requests are narrow, bounded, and failure-safe

- Claude calls only `GET https://api.anthropic.com/api/oauth/usage` with the
  documented OAuth beta header. Codex calls only
  `GET https://chatgpt.com/backend-api/wham/usage`, including the account ID
  only when the credential provides one.
- Rafu sends an honest `Rafu/<version>` user agent, uses a 15-second timeout,
  disables request-cookie handling, honors the shared per-provider 429 gate,
  and never logs request headers, bodies, tokens, credential paths, or raw
  transport diagnostics.
- Rafu does not refresh external OAuth credentials. Claude requires a future
  expiry; Codex uses JWT `exp` when present and permits opaque tokens with no
  expiry claim. Codex `last_refresh` age is not an expiry signal.
- Missing or expired credentials make the OAuth strategy unavailable, so the
  existing local strategy remains usable. A 401/403 may fall back locally. A
  malformed response, transport failure, 429, or other server failure hides
  the tile for that refresh rather than inventing a number or blocking the UI.

### Cookie imports remain a separate, higher-trust transition

Future cookie-backed providers must use their own explicit import consent.
Browser cookies are never inferred from OAuth consent, never read silently,
and must be minimized, bounded, redacted, and sent solely to the disclosed
first-party endpoint. If an explicit browser-import flow persists the minimized
header, it may use only Rafu's own Keychain — never `UserDefaults`, files, or
logs. Disconnect/removal must delete that imported authority without changing
local provider enablement.

## Alternatives considered

- **Treat the provider enable toggle as network consent.** Rejected because a
  default-on local metric reader cannot honestly authorize token transmission.
- **Read files or Claude Code Keychain opportunistically during every strategy
  fetch.** Rejected because it makes Settings/refresh an implicit credential
  access path and prevents a testable, auditable consent boundary.
- **Copy external tokens into Rafu's Keychain for reliability.** Rejected
  because it creates a second persistent credential authority and stale-token
  lifecycle. The owning CLI's file remains authoritative; Claude's explicit
  Keychain fallback is process-memory only.
- **Refresh expired tokens with another application's OAuth client identity.**
  Rejected because Rafu does not own that client, its scopes, or its refresh
  lifecycle. Local fallback is the honest no-refresh behavior.
- **Show stale local data for every network error.** Rejected because a local
  estimate can look like a successful exact result. Only explicit
  authentication rejection permits fallback after an attempted exact fetch;
  other failures hide the tile.

## Consequences

- Users can keep local Claude/Codex usage visible while declining or revoking
  credential-bearing network access.
- A successful connection backed only by Claude Code's Keychain lasts for the
  current Rafu process; reconnecting after relaunch is an intentional explicit
  trust action unless a usable CLI credential file exists.
- Credential resolution adds bounded file I/O before context construction, but
  it runs off-main and only for enabled, consented external providers.
- Provider and Settings tests can inject readers, credential loaders, consent
  suites, stores, and transports. They require no real home directory,
  Keychain, network, fixed sleeps, or secret-bearing diagnostics.

## Revisit trigger

Revisit if a provider publishes an OAuth integration specifically for Rafu,
if a first-party endpoint changes its credential or response contract, or if a
future cookie-import phase needs stricter lifecycle rules than the boundary
above.

## Related plan and implementation paths

- Plan: [`../plans/phases/usage-providers/W2-exact-percent-oauth.md`](../plans/phases/usage-providers/W2-exact-percent-oauth.md)
- `Sources/RafuApp/Usage/UsageStores.swift`
- `Sources/RafuApp/Usage/UsageRegistryReader.swift`
- `Sources/RafuApp/Usage/Providers/ClaudeProvider.swift`
- `Sources/RafuApp/Usage/Providers/CodexProvider.swift`
- `Sources/RafuApp/Settings/UsageSettingsTab.swift`
- `Tests/RafuAppTests/Usage/`
