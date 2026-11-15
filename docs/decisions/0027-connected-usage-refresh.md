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

## Amendment 2026-11-15: hook-triggered reads

Usage reads may also start after an agent turn ends. The trigger is a fresh
(at most 60 s old) `Stop`, `SubagentStop`, `StopFailure`, or `SessionEnd` event
from the opt-in Activity tracking hooks (Settings ▸ Agents). The rules:

- Turn-end events are coalesced over 15 s. Automatic reads start at least 60 s
  apart. One read runs at a time, with at most one follow-up.
- A failed read backs off 300 s × the failure count (count capped at 3), and
  this also delays turn-end reads. The fallback read is 300 s while a status
  item or panel exists (180 s for a pinned panel with no status item).
- No read runs while the screen is locked or asleep.
- No new credential read is added. The 15-minute Keychain gate, the denial stop,
  and the 429 handling stay as they are; the schedule only decides when to ask.
- No new hook entries are written. Hooks exist only through the existing opt-in
  Activity tracking; Codex hooks need the user's trust through `/hooks`.

Reason: in menu-bar mode the usage percent refreshed only at install, on
popover open, and on manual refresh. See
[Usage rings and pace](../references/usage-rings-and-pace.md) (Refresh
schedule).

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
- `Sources/RafuApp/Usage/UsageRefreshSchedule.swift` (amendment)
- [Usage rings and pace](../references/usage-rings-and-pace.md)
- [ADR 0017](0017-usage-provider-trust-transition.md)

Revisit if the provider offers a supported Rafu OAuth integration or changes
its credential contract.
