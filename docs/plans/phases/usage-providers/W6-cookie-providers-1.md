# W6 — Cookie-first providers, group 1: Antigravity, Grok Build, Kilo Code

WAVE B: requires W0 AND W1 merged to main before this worktree is cut.
Verify `Sources/RafuApp/Usage/Cookies/BrowserCookieImporter.swift`
exists on your branch before starting; if absent, STOP and report.

## Owned paths

- `Sources/RafuApp/Usage/Providers/AntigravityProvider.swift`
- `Sources/RafuApp/Usage/Providers/GrokBuildProvider.swift`
- `Sources/RafuApp/Usage/Providers/KiloCodeProvider.swift`
- `Tests/RafuAppTests/Usage/CookieProviders1Tests.swift`

## Scope

For each, from `Sources/CodexBarCore/Providers/{Antigravity,Grok,Kilo}`
(clone per README; adapt with MIT attribution):

1. Determine the auth reality from source: which support a LOCAL
   token/key path (implement it FIRST in strategy order) and which are
   cookie-based (cookie domains, session cookie names, endpoints).
2. Cookie strategies consume `context.cookieHeader(providerID)` — the
   cached header imported via Settings. Strategies NEVER trigger a
   browser import themselves (imports are Settings-action-only, W1
   rule); absent header ⇒ unavailable.
3. Map usage responses to `UsageWindow`s honestly (real percents/counts
   only); identity to Settings-only `identity`.
4. All `cookieImport` (or mixed) pattern, default OFF, disclosure
   strings naming domains read and endpoint called.

## Tests

Fixture responses → snapshot mapping per provider; absent cookie header
⇒ nil; login-redirect/`looksSignedOut`-style response ⇒ typed
invalid-credentials (tile hidden, gate consulted, no import triggered);
redaction (cookie header never in errors). Injected transport; no real
browser access in tests.

## Definition of done

Gates green; owned paths only; strategy order local-first where a local
path exists; handoff documents each provider's observed
domains/endpoints/shapes.
