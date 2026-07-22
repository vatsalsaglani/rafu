# Usage-provider contract nuances

- Applies to: `Sources/RafuApp/Usage/` (`UsageProviderCore.swift`,
  `UsageSupport.swift`, `UsageSQLite.swift`, `UsageStores.swift`,
  `UsageProviderRegistry.swift`, `UsageRegistryReader.swift`,
  `Sources/RafuApp/Usage/Providers/*Provider.swift`)
- Last verified: Swift 6.2, macOS 26, 2026-07-22 (W0 shim,
  branch `usage/w0`, 1096 tests)

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

## Why it matters

These are the seams every downstream usage-provider phase (W1–W8) writes
against without being able to see W0's internals; getting any of them
wrong either traps at runtime (main-actor isolation), leaks a secret into
a log, corrupts/writes into a file that isn't Rafu's, or silently locks a
user out of enabling a provider in Settings.

## Reproduction or evidence

W0 implementation (`usage/w0` branch, 4 commits): `swift test` and
`swift test --no-parallel` both green (1096 tests), 0 warnings, lint
clean, advisor read-only review: SAFE TO MERGE, no P0 findings. See
`docs/plans/phases/usage-providers/W0-shim.md` "Handoff to W1–W8" for
the full symbol inventory these rules attach to.

## Verification

`swift test` (targets `UsageCoreTests`, `UsageStoreTests`, and any
provider-specific redaction/availability tests added by W1–W8) plus
`swift test --no-parallel`; `./script/format.sh --lint`.

## Related code, ADRs, and phases

- `Sources/RafuApp/Usage/UsageProviderCore.swift`,
  `UsageSupport.swift`, `UsageSQLite.swift`, `UsageStores.swift`,
  `UsageProviderRegistry.swift`, `UsageRegistryReader.swift`
- `docs/plans/phases/usage-providers/W0-shim.md` (contract + handoff),
  `W2-exact-percent-oauth.md` (first credentialed strategy, credential
  bridge landing point), `W3`–`W8` phase files (contract-rule callout)
- `docs/references/nonisolated-extension-isolation-trap.md` (related
  `nonisolated`-under-default-`MainActor` pitfall)
