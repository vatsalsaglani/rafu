# AI provider REST contracts

- Applies to: commit-message provider configuration, request construction, streaming, tests, and secrets
- Last verified: Swift 6.2, macOS 15 deployment target, 2026-07-13 (commit-message
  size budgeting revised 2026-07-13)

## Rule or observed behavior

Rafu has separate REST adapters for OpenAI, Anthropic, Google Gemini, and custom
OpenAI-compatible endpoints. Do not infer one provider's wire format from another.

- OpenAI supports the Responses API and Chat Completions. New OpenAI
  configurations default to Responses; custom endpoints expose either transport.
- Anthropic Messages uses `POST /v1/messages`, `x-api-key`, and an explicit
  `anthropic-version` header. Streaming is server-sent events with typed events.
- Gemini native generation uses `generateContent`; streaming uses
  `streamGenerateContent?alt=sse` and authenticates with `x-goog-api-key`.
- A connection test asks for the exact short reply `Rafu live!`. Treat a valid
  provider response as transport evidence, while showing the returned text so a
  user can spot model/prompt incompatibility.
- API keys are stored in Keychain. Provider metadata may be stored in
  `UserDefaults`. Never log keys, prompts, diffs, request bodies, or generated text.
- Default model strings must come from a currently published provider page, never
  a guessed future name. They are conveniences rather than locks; model fields
  remain editable because availability varies by account and changes over time.
- Source Control sends checked diffs; when none are checked it may send all changed
  files only after labeling that scope beside the explicit Generate action.
  Generation fills an editable draft and never commits automatically.
- Keep the verified bounds unless a measured requirement supersedes them: 512 KiB
  encoded request, 2 MiB streamed wire response, and 64 KiB generated output.
  Exceeding one of those is still a visible error.
- Commit-message diff selection never hard-fails on size. `WorkspaceSession`
  orders in-scope files smallest-estimated-first (`AICommitDiffOrdering`, using
  `GitService.changeLineStats`), fetches full patches up to 64 files and a
  combined 256 KiB budget (`AICommitPromptBuilder.maximumFullDiffCount` /
  `.maximumDiffBytes`), truncates any single patch over 48 KiB with a literal
  marker, and turns every remaining in-scope file into a one-line stat summary
  (path, status, `+added/-deleted` when known). `AIProviderError
  .selectedDiffsTooLarge` was removed; only an empty selection
  (`.selectedDiffsRequired`) and the request/response wire bounds above still
  throw. The prompt's own instruction discloses summarization/truncation to the
  model; the Source Control caption discloses it to the user only past the
  64-file full-patch cap (a count-based heuristic — byte-driven summarization
  under that count is disclosed in the prompt only, not recomputed per keystroke).
- **AI tab-completion feature flag (off by default).** A separate AI completion
  mode (ghost-text suggestions as-you-type) exists but is not ready to ship yet.
  `WorkspaceSession.isAICompletionFeatureAvailable` is a build-level static flag
  (default `false`). While false, the Edit menu item and command-palette entry
  are hidden and `toggleAICompletion()` is a no-op, preventing the feature from
  being enabled. Set the flag to `true` when the feature is finished and
  verified.

## Why it matters

Endpoints that appear similar differ in authentication, request JSON, response
content, and stream event shapes. A generic unchecked dictionary-based request
silently breaks or risks sending content to an unintended path.

## Reproduction or evidence

Primary documentation:

- OpenAI Responses: <https://platform.openai.com/docs/api-reference/responses>
- OpenAI Chat Completions: <https://platform.openai.com/docs/api-reference/chat>
- OpenAI models: <https://platform.openai.com/docs/models>
- Anthropic Messages: <https://docs.anthropic.com/en/api/messages>
- Anthropic streaming: <https://docs.anthropic.com/en/api/messages-streaming>
- Anthropic models: <https://docs.anthropic.com/en/docs/about-claude/models/overview>
- Gemini text generation: <https://ai.google.dev/gemini-api/docs/text-generation>
- Gemini API reference: <https://ai.google.dev/api/generate-content>

## Verification

Run `swift test --filter AI` with mocked URL loading and stream fixtures. Live
provider testing is user-initiated from Settings because CI must not receive keys.

## Related code, ADRs, and phases

- `Sources/RafuApp/AI/`
- `Sources/RafuApp/Models/WorkspaceSession.swift` (`budgetedCommitPromptInput`)
- `Sources/RafuApp/Services/GitService.swift` (`changeLineStats`)
- `Sources/RafuApp/Views/GitInspectorView.swift`
- `Tests/RafuAppTests/AIProviderConfigurationTests.swift`
- `docs/plans/phases/pre-initial-push-workbench.md`
