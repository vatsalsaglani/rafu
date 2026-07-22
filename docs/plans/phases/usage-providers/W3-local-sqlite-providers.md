# W3 — SQLite/local providers: Cursor, OpenCode, OpenCode Go/Zen

Zero-config providers whose primary data is local SQLite owned by the
user's own tools. Uses the shim's `UsageSQLite` only — no new SQLite
code.

**Contract rule:** `makeStrategies` must return the same strategy COUNT
regardless of `context` (Settings' visibility probe calls it with a
no-op/empty context) — all credential/availability gating belongs in
`isAvailable`, never in the strategy list's length.

## Owned paths

- `Sources/RafuApp/Usage/Providers/CursorProvider.swift`
- `Sources/RafuApp/Usage/Providers/OpenCodeProvider.swift`
- `Sources/RafuApp/Usage/Providers/OpenCodeGoProvider.swift`
- `Tests/RafuAppTests/Usage/CursorProviderTests.swift`,
  `OpenCodeProvidersTests.swift`

## Scope (from CodexBar source — verify, adapt with attribution)

**Cursor** (`piggybackNetwork`, opt-in):
- Token: SQLite `~/Library/Application Support/Cursor/User/globalStorage/
  state.vscdb`, `SELECT value FROM ItemTable WHERE
  key='cursorAuth/accessToken'`; decode JWT `sub` → synthesize
  `WorkosCursorSessionToken=<userID>::<accessToken>` cookie header.
- `GET https://cursor.com/api/usage-summary` (+ `/api/auth/me` for
  identity). Map plan %, on-demand $ used/limit, billing-cycle reset.
- Browser-cookie fallback is WAVE B territory — do NOT implement here;
  leave the strategy list ordered [vscdb-token] only.

**OpenCode** (`localZeroConfig`, default ON): sum `$.cost` from
`message`/`part` rows in `~/.local/share/opencode/opencode.db` per
CodexBar's queries; auth presence via `~/.local/share/opencode/auth.json`.
Windows: session/weekly/monthly $ against CodexBar's caps → percent +
costLine. Verify the caps/current schema from source, don't trust the
parent plan's numbers.

**OpenCode Go** (`localZeroConfig`, default ON): same DB filtered
`providerID='opencode-go'`; caps per CodexBar
(`session $12 / weekly $30 / monthly $60` — verify). Zen balance/web
enrichment is Wave B — skip.

## Tests

Fixture SQLite DBs built in-test (CREATE TABLE + INSERT through the
shim helper, then read back) — never a real `~/Library` or
`~/.local` read in tests; JWT decode against a synthetic token; Cursor
response fixtures → snapshot mapping; missing DB/absent auth ⇒ nil
snapshot; redaction (the synthesized cookie never appears in errors).

## Definition of done

Gates green; owned paths only; Cursor ships opt-in (defaultEnabled
false), OpenCode/Go default ON per the Settings pattern; handoff notes
schema/caps as actually observed in CodexBar's current source.
