# Usage-provider contract nuances

- Applies to: `Sources/RafuApp/Usage/` (`UsageProviderCore.swift`,
  `UsageSupport.swift`, `UsageSQLite.swift`, `UsageStores.swift`,
  `UsageProviderRegistry.swift`, `UsageRegistryReader.swift`,
  `Sources/RafuApp/Usage/Providers/*Provider.swift`)
- Last verified: Swift 6.2, macOS 26, 2026-07-27 (connect-affordance split:
  `.localSessionPiggyback`/`.unavailable` + Cursor headless probe; supersedes
  the CodexBar de-brand + Antigravity `state.vscdb` + strip-order follow-up)

## Rule or observed behavior

1. **`UsageFetchStrategy` must be a `nonisolated protocol`.** The
   `RafuApp` target defaults to `.defaultIsolation(MainActor.self)`, so a
   plain `protocol UsageFetchStrategy` would implicitly require its
   conformers' `async` methods (`isAvailable`, `fetch`) to run on the
   main actor. Usage fetches are off-main network/file/SQLite work run
   from a background reader (`UsageRegistryReader`); declaring the
   protocol `nonisolated` keeps conforming strategy types free to run
   their bodies off-main without a hop, matching the AGENTS rule that
   AI/network/file work stay off the main actor.

2. **`UsageHTTPError` cannot carry secrets.** `UsageHTTPClient` is a
   bounded (15s timeout), 429-`Retry-After`-honoring, redacting HTTP
   client. Its thrown error type is constructed so that no header value,
   bearer token, or response body ever appears in the error's
   description or any log line — construct errors from status codes and
   fixed messages only, never by interpolating the request/response
   payload. Tests must assert on the error's `description`/localized
   text to catch an accidental token leak, not just on the error case.

3. **`UsageSQLite` is read-only with bound parameters only.** It opens
   databases with `SQLITE_OPEN_READONLY` (`import SQLite3`, a system
   module — no `Package.swift` change) and every query uses bound
   parameters, never interpolated SQL. This is a read-only reader over
   files owned by other tools (e.g. a CLI's local `.db`/`.vscdb`) —
   never open for write, and never build a query string by
   concatenating caller input.

4. **Sync-credential-closure-over-async-actor bridge.**
   `UsageFetchContext.credential` is a synchronous `@Sendable
   (UsageProviderID) -> String?` in the frozen contract type, but the
   credential store (`UsageCredentialStore`) is an `actor`. The bridge:
   the async caller (`UsageRegistryReader.snapshots(now:)`) awaits the
   actor to pre-resolve the specific credentials it needs into a
   `Sendable [UsageProviderID: String]` dictionary BEFORE constructing
   the context, then hands the context a sync closure that only reads
   from that already-resolved, captured dictionary. No actor hop happens
   inside the sync closure. `UsageFetchContext` itself never needs to
   change to add credentialed providers.

5. **`makeStrategies` must be context-independent in its element COUNT.**
   `UsageProviderDescriptor.makeStrategies` is `@Sendable
   (UsageFetchContext) -> [any UsageFetchStrategy]`. The Settings tab's
   visibility probe (`UsageSettingsModel`) calls it with a "probe"
   context (`http: .noop`, `credential`/`readFile`/`cookieHeader` all
   nil) and hides the provider's row whenever the result is empty. If a
   provider's `makeStrategies` conditionally omits a strategy based on
   whether a credential/cookie is already present, that provider becomes
   permanently invisible in Settings — the user has no way to enter the
   credential that would make it appear. All availability/credential/
   cookie gating must live inside each strategy's `isAvailable`, never in
   whether the strategy is included in the returned array.

6. **Settings keeps secret values out of observable state.** API-key text is
   owned only by the row's masked `SecureField`. `UsageSettingsModel` stores
   redacted presence/operation states, while an injected
   `UsageProviderInputClient` moves the value directly into
   `UsageCredentialStore` and the one-shot test fetch. Keys are trimmed,
   bounded to 16 KiB, and rejected if they contain control characters before
   either Keychain persistence or HTTP-header use.

7. **A browser importer is one-shot user intent.** Construct
   `BrowserCookieImporter.userInitiated()` inside each Import button action;
   never retain one importer for retries. Its authorization can be claimed
   once, and a fresh value ensures every retry comes from a fresh explicit
   click. Settings consumes `importCookieHeaderOutcome` so Safari's typed
   Full Disk Access failure stays actionable, then stores only a minimized
   provider-scoped header through `CookieHeaderCache`.

8. **Import and refresh are deliberately separate.** Settings is the only
   browser-read path. Periodic usage refreshes call only
   `CookieHeaderCache.shared.header(for:)` through the production
   `UsageFetchContext.cookieHeader` closure; they never touch browser stores,
   prompt for Chromium Safe Storage, or request Safari access.

9. **Antigravity's token lives in its own `state.vscdb`, not a JSON creds
   file.** Antigravity is a VS Code fork; its signed-in OAuth token is a
   single opaque string in `~/Library/Application Support/Antigravity/User/
   globalStorage/state.vscdb`, `ItemTable` key
   `antigravityUnifiedStateSync.oauthToken` — the same read-only-SQLite shape
   Rafu already uses for Cursor/Windsurf (rule 3). It carries no expiry,
   project id, or email, so `AntigravityLocalOAuthStrategy` uses it directly
   as the Cloud Code bearer, derives the project id from the `loadCodeAssist`
   response, and leaves identity unset. Antigravity does **not** persist a
   readable `oauth_creds.json`; a running Antigravity IDE mints the token into
   `state.vscdb`, and there is no in-app OAuth flow (kept out per the
   trust-transition ADR). `AntigravityLocalOAuthStrategy(databasePath:
   fileExists:)` is injectable exactly like `CursorVSCDBStrategy` so tests
   build a temp `state.vscdb` instead of stubbing a file read — and any test
   using the descriptor's default strategy must pin a nonexistent
   `databasePath`, because the default reads a real machine path that exists
   when Antigravity is installed on the test host.

10. **The user chooses the notch strip order in Settings, not the code.**
    `UsageSettingsModel` injects `UsageStripOrderStore` and exposes
    `stripOrderedEnabledRows()` / `moveStripProvider(_:up:)`; the "Notch strip
    order" Settings section reorders **enabled** providers with per-row
    up/down buttons (keyboard-reachable, no drag-only path). It persists the
    full effective order (enabled reordered, then disabled preserved at the
    tail) via `setOrder`; `UsageDisplayPolicy.frontLine` still takes the first
    `frontLineCap` (4) with data. Disabled providers are excluded from the
    arrangement because they never produce a snapshot.

11. **`UsageAuthPattern` describes where the credential LIVES, and that
    decides whether Connect can succeed at all.** The pattern is not
    cosmetic: `UsageSettingsTab` renders a Connect button for it, and
    `UsageOAuthConnector` decides what to do from
    `UsageAuthPattern.connectAffordance`. Three honest cases:

    - `.piggybackNetwork` → `.externalCredential`. Rafu loads the CLI's
      documented credential file (`~/.claude/.credentials.json`,
      `$CODEX_HOME/auth.json`), or, for Claude only, Claude Code's Keychain
      item. **Only Claude and Codex may use this pattern**, because
      `UsageOAuthConnector.credentialFileURL(for:environment:)` has an entry
      only for those two and correctly returns `nil` for everything else —
      inventing a plausible-looking path for another vendor is forbidden
      (ADR 0018: Rafu holds no inference credentials).
    - `.localSessionPiggyback` → `.localSession`. The credential never
      crosses into Rafu at all; the strategy reads the vendor app's own
      local session at fetch time (Cursor/Antigravity `state.vscdb`, Gemini
      CLI/Kimi JSON creds). There is nothing for Rafu to "load", so Connect
      instead runs the provider's OWN strategies' `isAvailable` against
      `UsageOAuthConnector.localSessionProbeContext(now:)` — bounded file
      reads, `UsageHTTPClient.noop`, no credential returned to the connector
      — and records network consent on success. Reusing the strategies means
      Connect and the refresh pipeline can never disagree about whether a
      session exists.
    - `.unavailable` → `.none`. A rostered provider with no obtainable
      signal (Copilot). Settings renders a stated reason next to a **disabled
      toggle** and no button at all. An error the user cannot act on is worse
      than a stated limitation.

    A `.piggybackNetwork` provider with no credential file is the exact
    defect this rule exists to prevent: Cursor shipped a Connect button that
    returned `.unsupportedProvider` on every press, because the pattern
    promised a credential source that only Claude and Codex have.
    `externalCredentialProvidersHaveACredentialSource` in `UsageStoreTests`
    fails the moment a provider claims that pattern without one.

12. **Consent granularity follows the pattern, not the provider.**
    `.piggybackNetwork` gates consent per **credential**, inside
    `UsageRegistryReader.productionCredentials`, so Claude's and Codex's
    LOCAL transcript/rollout fallback strategies keep producing a snapshot
    while disconnected. `.localSessionPiggyback` providers have only
    credential-bearing network strategies, so `snapshots(now:)` gates the
    whole **descriptor** on `hasNetworkConsent`. Gating a `.piggybackNetwork`
    descriptor wholesale would silently kill its local fallback; not gating a
    `.localSessionPiggyback` one lets Settings say "Not connected" while Rafu
    is already talking to the vendor.

13. **`cursor-agent` is not a usage source.** Probed at
    `2026.07.23-e383d2b`: `status`/`whoami` print only `✓ Logged in as
    <email>` (`--format json` available, still auth-only), `about` prints a
    subscription **tier** (`Free`) with no quota, percentage, or reset time,
    and `--help` lists no usage/quota/limit/credit/billing verb. Cursor's
    only obtainable usage signal remains Cursor.app's `state.vscdb`
    `cursorAuth/accessToken` (a ~400-byte JWT) converted to the
    `WorkosCursorSessionToken` cookie for `cursor.com/api/usage-summary` —
    which `CursorVSCDBStrategy` already implements. Do not add a
    `cursor-agent` probe to the usage path expecting numbers from it.

## Why it matters

These are the seams every downstream usage-provider phase (W1–W8) writes
against without being able to see W0's internals; getting any of them
wrong either traps at runtime (main-actor isolation), leaks a secret into
a log, corrupts/writes into a file that isn't Rafu's, or silently locks a
user out of enabling a provider in Settings. The input rules also prevent a
background refresh from becoming a surprise browser/Keychain consent action
and prevent secrets from lingering in model diagnostics.

## Reproduction or evidence

Rules 11–13 come from the 2026-07-27 Cursor Connect fix. The Cursor probe was
run against the installed, authenticated `~/.local/bin/cursor-agent`
(`cursor-agent status </dev/null`, `about`, `--help | grep -iE
"usage|quota|limit|credit|billing"`); the local session was confirmed by
listing `ItemTable` keys matching `cursorAuth/%` in a copy of Cursor.app's
`state.vscdb` and reading only their `length(value)`, never a value. Rules
11–12 are covered by `externalCredentialProvidersHaveACredentialSource`,
`rosterConnectAffordances`, `connectorLocalSessionOutcome`,
`localSessionProbeContextIsOffline`, and
`usageRegistryReaderGatesLocalSessionOnConsent`.

W0 established rules 1–5. The 2026-07-23 provider-input follow-up added
fixture-only Settings tests covering the exact six API-key rows, three
cookie-import rows, secret validation, save/test behavior, Safari Full Disk
Access state, cookie removal, bounded import catalogs, and production-context
cookie composition. No test touches a real browser, Keychain, or network.

## Verification

`swift test` (including `UsageProviderInputTests`, `UsageCoreTests`,
`UsageStoreTests`, and provider-specific redaction/availability tests) plus
`swift test --no-parallel`; `./script/format.sh --lint`; and the canonical
staged-app Settings launch pass for input-row layout and keyboard reachability.

## Related code, ADRs, and phases

- `Sources/RafuApp/Usage/UsageProviderCore.swift`,
  `UsageSupport.swift`, `UsageSQLite.swift`, `UsageStores.swift`,
  `UsageProviderRegistry.swift`, `UsageRegistryReader.swift`
- `Sources/RafuApp/Usage/UsageProviderInputs.swift`,
  `Sources/RafuApp/Usage/Cookies/BrowserCookieImporter.swift`,
  `Sources/RafuApp/Usage/Cookies/CookieHeaderCache.swift`,
  `Sources/RafuApp/Settings/UsageSettingsTab.swift`
- `docs/plans/phases/usage-providers/W0-shim.md` (contract + handoff),
  `W2-exact-percent-oauth.md` (first credentialed strategy, credential
  bridge landing point), `W3`–`W8` phase files (contract-rule callout)
- `docs/references/nonisolated-extension-isolation-trap.md` (related
  `nonisolated`-under-default-`MainActor` pitfall)
