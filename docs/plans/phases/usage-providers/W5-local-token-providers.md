# W5 — Local-token providers: Gemini CLI, GitHub Copilot, Kimi/Moonshot

Providers whose CLIs store a reusable local token/OAuth credential.
EXACT mechanisms must be read from CodexBar source first — the parent
plan deliberately does not guess them. If a provider proves cookie-ONLY
in current source, stub its strategies as unavailable, note it in the
handoff (it moves to Wave B), and do not implement cookies here.

**Contract rule:** `makeStrategies` must return the same strategy COUNT
regardless of `context` (Settings' visibility probe calls it with a
no-op/empty context) — all credential/availability gating belongs in
`isAvailable`, never in the strategy list's length.

## Owned paths

- `Sources/RafuApp/Usage/Providers/GeminiCLIProvider.swift`
- `Sources/RafuApp/Usage/Providers/CopilotProvider.swift`
- `Sources/RafuApp/Usage/Providers/KimiProvider.swift`
- `Tests/RafuAppTests/Usage/LocalTokenProvidersTests.swift`

## Scope

For each, from `Sources/CodexBarCore/Providers/{Gemini,Copilot,Kimi}`:

1. Identify the LOCAL credential source (e.g. Gemini CLI's oauth creds
   file under `~/.gemini/`, Copilot's token via `gh`/hosts.yml or its
   CLI config, Kimi's CLI config — WHATEVER the source actually shows;
   quote paths in code comments).
2. Identify the usage endpoint + response shape; implement the fetch
   strategy through the shim HTTP client with the standard rules
   (bounded, redacting, 429 gate, no token refresh flows).
3. Map to `UsageWindow`s honestly: percent when the API gives percent,
   token/request counts when it gives counts, costLine for credit
   balances. NEVER synthesize a percent from guessed limits.
4. `piggybackNetwork` pattern, default OFF, accurate disclosure strings
   naming the exact file read and endpoint called.

## Tests

Per provider: fixture response → snapshot; absent credential ⇒
unavailable ⇒ nil; malformed ⇒ nil not crash; redaction. Injected
transport and injected file-reader only.

## Definition of done

Gates green; owned paths only; each provider either fully working from
local credentials or explicitly stubbed-with-reason in the handoff;
observed paths/endpoints documented in the handoff for the coordinator's
reference note.
