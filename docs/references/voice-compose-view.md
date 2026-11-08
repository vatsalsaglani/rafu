# Voice `compose_view`

Applies to: `Sources/RafuApp/Voice/VoiceToolExecutor+Compose.swift`,
`Sources/RafuApp/Canvas/GeneratedView/Compose/`, `Sources/RafuCore/Voice/VoiceToolSchema.swift`, package
`swift-json-render` `JSONRenderCompose` (0.22.0-alpha.3).
Last verified: Swift 6.4.2 (local) and 6.3.3 (CI), macOS 27, 2026-11-08. Both test modes green on the jr-6r branch.

## Rule

- **When:** only when the GPT-Live backend calls `compose_view`. Never a fallback after `show_view` fails.
- **Policy:** Off refuses (`agent_control_off`); Ask runs at once with the Undo notice "Rafu (voice) composed
  <title>"; Allow runs. The voice rate limit applies (`rate_limited`). No key: `no_openai_key`, "Add an OpenAI key in
  Settings ▸ AI".
- **What Rafu sends to OpenAI:** the prompt, candidate ids and descriptions (counts, the Ensemble title up to 80
  characters, file node titles up to 60 characters), and the `context` after `VoiceOutputScrubber` (Ensemble title,
  counts, `terminal_output_shared`, the user's context).
- **What never leaves:** props, bindings, `state`, terminal text, file contents, the key. The `Table` and `BarChart`
  candidates exist only in Allow mode with "Share terminal output" on; their descriptions carry counts only.
- **Candidates:** `Card` or `Stack` root, `Heading`, three `Stat` counts, `KeyValue` (Ensemble facts, terminals),
  up to six `FileLink`s (one candidate each), and `Table` or `BarChart` sharing one `tests` resource.
- **Card flow and undo:** preview after round 1, final layout after round 2; one undo step when the board did not
  change between the rounds, otherwise two. Removing the preview between the rounds answers `removed`.
- **Stop reasons:** `finish` gives `ok`; `limit` gives `partial`; `unavailable` before the preview gives "Rafu could
  not compose a view for that…" (or the service sentence when a step failed with an evaluator code, never the HTTP
  status); `unavailable` after the preview keeps the preview and gives `partial`.
- **Timeline:** counts only, for example `N elements; rounds R; questions Q; tokens T`.

## Why it matters

The Decisions API is a second outbound call with the user's key. The candidate descriptions are the only text that
reaches the model, so they are the privacy boundary; a prompt-injected title can at most bias a choice among Rafu's
own candidates, because the model only answers choice, predicate and score questions and the package fails closed.

## Evidence

- `ComposePrivacyTests.keyOnlyInHeader`: the test key reaches only the `Authorization` header (not the body, output,
  summary, notice, `CanvasAgentCenter` log, board effects or encoded cards); a key placed in `context` is scrubbed.
- `ComposePrivacyTests.evaluatorInput`: no terminal text, `$state`, `$bindState` or `"props"` in the evaluator input.
- `ComposePrivacyTests.insecureBaseURL`: `http` refused before the key provider runs.
- `VoiceComposeViewTests`: Ask collapse to one step, edit between rounds gives two steps, Off, no key, unavailable.
- Fixtures are hand-written Decisions answers in code (`ComposeAnswers`); none is a real recording. A real recording
  must come from the user, never from an agent.

## Known gaps

- Latency: two rounds with a 10 s timeout each run inside the serial voice call chain. The backend's function-result
  window is not measured; the user's manual check records it from the timeline row.
- `VoiceSession` does not cancel the call chain on close, so a late final layout can land on the Ensemble captured at
  the start of the call (undoable, same as a late MCP approval).
- After a two-step update the journal keeps the round-1 counts; the prompt is not scrubbed (only `context` is);
  terminal test-line detection is word based ("fail", "error", "pass").

## Commands

```
swift test --filter "Compose|VoiceToolSchema"
```

## Related

ADR 0035 and ADR 0036 amendments (2026-11-08); [`voice-delta-streaming.md`](voice-delta-streaming.md);
[`generated-view-card-and-state.md`](generated-view-card-and-state.md); Rafu's own `JSONValue` clashes with the
package's, so RafuApp files write `JSONRenderCore.JSONValue`.
