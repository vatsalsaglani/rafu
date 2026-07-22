# W7 — Cookie-first providers, group 2: Windsurf, Amp, Factory Droid, Warp

WAVE B: requires W0 AND W1 merged to main before this worktree is cut.
Verify `Sources/RafuApp/Usage/Cookies/BrowserCookieImporter.swift`
exists on your branch before starting; if absent, STOP and report.

**Contract rule:** `makeStrategies` must return the same strategy COUNT
regardless of `context` (Settings' visibility probe calls it with a
no-op/empty context) — all credential/availability gating belongs in
`isAvailable`, never in the strategy list's length.

## Owned paths

- `Sources/RafuApp/Usage/Providers/WindsurfProvider.swift`
- `Sources/RafuApp/Usage/Providers/AmpProvider.swift`
- `Sources/RafuApp/Usage/Providers/FactoryDroidProvider.swift`
- `Sources/RafuApp/Usage/Providers/WarpProvider.swift`
- `Tests/RafuAppTests/Usage/CookieProviders2Tests.swift`

## Scope

Identical contract to W6, over
`Sources/CodexBarCore/Providers/{Windsurf,Amp,Factory,Warp}`:

1. From source, determine each provider's real auth ladder — several of
   these have LOCAL app/CLI credential paths (e.g. app support files,
   CLI configs) that must rank ABOVE cookies in strategy order;
   cookies are the fallback, consumed from the cached header only.
2. Map usage (Cascade credits, Amp credits, Droid quotas, Warp AI
   request counts — whatever the source actually shows) to
   `UsageWindow`s/costLine honestly; never synthesize percents.
3. Default OFF, accurate disclosures, identity Settings-only.
4. Strategies never trigger imports; absent credentials/header ⇒
   unavailable ⇒ tile hidden.

## Tests

Per provider: fixture → snapshot; absent credential AND absent cookie ⇒
nil; invalid-credentials response ⇒ typed, gated, hidden; redaction.
Injected transport and readers only.

## Definition of done

Gates green; owned paths only; per-provider observed
paths/domains/endpoints in the handoff; any provider whose data proves
unreachable without scraping (rejected) is stubbed-with-reason rather
than faked.
