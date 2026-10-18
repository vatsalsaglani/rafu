# ADR 0027: Refresh connected usage with bounded credential reads

- **Status:** Accepted
- **Date:** 2026-10-19
- **Supersedes:** ADR 0017 only for connected Claude Keychain reads and stale usage display.

## Context

PR #4 adds usage rings and pace estimates. A Claude connection backed by
Keychain loses its memory-only token after a restart or token expiry. The
old rule required Connect again even while Settings showed Connected.
The user requested review and integration of this change.

## Decision

After explicit Connect, usage refresh may read the `Claude Code-credentials`
Keychain item when neither the credential file nor the memory copy has a
usable token. The read runs off the main actor, at most once per 15 minutes
per process. Denial stops further attempts until Connect or Disconnect.
The Connect disclosure states that reads can recur while connected.
macOS still controls access to the item. No other Keychain item is queried.

This reads a token that Claude Code has renewed. Rafu does not use a refresh
token, renew OAuth credentials, or persist external credentials. The size,
expiry, endpoint, redaction, and network-consent rules in ADR 0017 remain.
Disconnect clears the memory copy and revokes network consent.

A failed refresh may keep the last successful snapshot for at most six
hours, with its original timestamp and a visible stale notice. It must not
replace an exact result with an unmarked estimate. Disabled providers are
removed; exact snapshots are removed after network consent is revoked.
These checks also apply to results from requests already in flight.
A quota whose reset has passed asks for a refresh, even if its old value
was 100 percent.

## Alternatives considered

- Require Connect after each restart or expiry: keeps the previous access
  rule but makes a connected provider appear broken.
- Persist another application's token: rejected; the owning CLI remains
  the credential authority.
- Read Keychain on every refresh: rejected; repeated prompts are disruptive.
- Hide all usage after a transient failure: rejected in favor of an explicit,
  bounded stale state.

## Consequences

A connected provider can prompt for Keychain access after restart or expiry.
A denied prompt does not repeat in that process. Tests use injected readers
and synthetic usage values, never real credentials. Stale data remains a
historical observation and cannot prove current capacity.

## Verification and related paths

- `Tests/RafuAppTests/Usage/UsagePaceTests.swift`
- `Sources/RafuApp/Usage/UsageStores.swift`
- `Sources/RafuApp/Usage/UsageRegistryReader.swift`
- [Usage rings and pace](../references/usage-rings-and-pace.md)
- [ADR 0017](0017-usage-provider-trust-transition.md)

Revisit if the provider offers a supported Rafu OAuth integration or changes
its credential contract.
