# W1 — Browser-cookie infrastructure (no providers)

Builds the shared cookie-import module Wave B (W6–W8) providers consume.
No provider descriptors change in this phase.

## Owned paths

Created:
- `Sources/RafuApp/Usage/Cookies/BrowserCookieImporter.swift` — the API
- `Sources/RafuApp/Usage/Cookies/ChromiumCookieReader.swift`
- `Sources/RafuApp/Usage/Cookies/SafariCookieReader.swift`
- `Sources/RafuApp/Usage/Cookies/CookieAccessGate.swift`
- `Sources/RafuApp/Usage/Cookies/CookieHeaderCache.swift`
- `Tests/RafuAppTests/Usage/CookieInfrastructureTests.swift`

Modified: NOTHING else. The shim's `UsageFetchContext.cookieHeader`
closure is already in the contract; wiring the production closure to
this module is a ONE-LINE change the coordinator makes at merge if the
seam wasn't already left injectable — flag it in the handoff rather
than editing shim files.

## Scope

Study CodexBar's stack first (clone per README): its
`BrowserCookieImporter`/SweetCookieKit usage, the `cursor.com` importer,
and `BrowserCookieAccessGate`. Adapt (MIT, attribute), simplify:

1. **API**: `importCookieHeader(domains: [String], names: [String]?,
   browsers: [Browser]) async -> String?` returning a `Cookie:` header
   value. Browsers: `.chrome, .brave, .edge, .arc, .firefox, .safari`
   (implement Chromium family + Safari; Firefox only if CodexBar's
   reader adapts cleanly, else record as unsupported).
2. **Chromium**: read the profile's `Cookies` SQLite (via the shim's
   `UsageSQLite`), decrypt v10/v11 values with the browser's
   "Safe Storage" Keychain key (this triggers a macOS Keychain consent
   dialog — MUST only run from an explicit user action, mirroring the
   Claude Connect rule).
3. **Safari**: parse `~/Library/Cookies/Cookies.binarycookies`; if
   unreadable (no Full Disk Access), return a typed
   `.needsFullDiskAccess` outcome the Settings row renders as inline
   guidance — never a prompt loop.
4. **Access gate**: after N consecutive failures per browser, back off
   (in-memory) — never re-read cookies on a background cadence; imports
   happen only from Settings actions, refreshes reuse the CACHED header.
5. **Cache**: imported headers in memory + Rafu's own Keychain
   (`rafu.usage.cookie.<provider>`); never UserDefaults, never files,
   never logs (redaction tests).

## Privacy notes (enforced in code + tests)

Cookie values are credentials: same rules as tokens. The importer reads
ONLY the named domains' cookies; no full-jar enumeration APIs in the
public surface. All reads off-main. Nothing here transmits anything —
transmission stays inside provider strategies.

## Definition of done

- Module compiles standalone; unit tests cover: Chromium store parsing
  against a FIXTURE SQLite file (build one in tests, do not read a real
  browser in CI), v10 decryption round-trip with an injected key,
  binarycookies parsing against a fixture, gate backoff, cache
  round-trip, redaction.
- No real browser/Keychain access in tests (injected readers/keys).
- Gates green; owned paths only; handoff documents the exact public API
  for W6–W8 and the one-line context wiring for the coordinator.
