/// Metadata-only transcripts recorded from the installed OpenCode 1.18.4
/// binary on 2026-07-24. No prompt, repository text, or credential value is
/// present.
nonisolated enum OpenCodeAdapterFixtures {
    static let version = "1.18.4\n"

    static let runHelp = """
        opencode run [message..]

        run opencode with a message

        Positionals:
          message  message to send

        Options:
          -h, --help         show help
          -v, --version      show version number
              --pure         run without external plugins
          -m, --model        model to use in the format of provider/model
              --agent        agent to use
              --format       format: default (formatted) or json (raw JSON events)
              --dir          directory to run in
              --auto         auto-approve permissions that are not explicitly denied (dangerous!)
          -i, --interactive  run in direct interactive split-footer mode
        """

    static let models = """
        opencode/big-pickle
        opencode/deepseek-v4-flash-free
        opencode/laguna-s-2.1-free
        opencode/mimo-v2.5-free
        opencode/nemotron-3-ultra-free
        opencode/north-mini-code-free
        opencode-go/deepseek-v4-flash
        opencode-go/deepseek-v4-pro
        opencode-go/glm-5.1
        opencode-go/glm-5.2
        opencode-go/grok-4.5
        opencode-go/hy3
        opencode-go/kimi-k2.6
        opencode-go/kimi-k2.7-code
        opencode-go/kimi-k3
        opencode-go/mimo-v2.5
        opencode-go/mimo-v2.5-pro
        opencode-go/minimax-m2.7
        opencode-go/minimax-m3
        opencode-go/qwen3.6-plus
        opencode-go/qwen3.7-max
        opencode-go/qwen3.7-plus
        google-vertex/claude-haiku-4-5@20251001
        google-vertex/claude-opus-4-5@20251101
        google-vertex/claude-opus-4-6@default
        google-vertex/claude-opus-4-7@default
        google-vertex/claude-opus-4-8@default
        google-vertex/claude-sonnet-4-5@20250929
        google-vertex/claude-sonnet-4-6@default
        google-vertex/claude-sonnet-5@default
        google-vertex/deepseek-ai/deepseek-v3.1-maas
        google-vertex/deepseek-ai/deepseek-v3.2-maas
        google-vertex/gemini-2.5-flash
        google-vertex/gemini-2.5-flash-image
        google-vertex/gemini-2.5-flash-lite
        google-vertex/gemini-2.5-flash-tts
        google-vertex/gemini-2.5-pro
        google-vertex/gemini-2.5-pro-tts
        google-vertex/gemini-3-flash-preview
        google-vertex/gemini-3-pro-image
        google-vertex/gemini-3.1-flash-image
        google-vertex/gemini-3.1-flash-lite
        google-vertex/gemini-3.1-pro-preview
        google-vertex/gemini-3.1-pro-preview-customtools
        google-vertex/gemini-3.5-flash
        google-vertex/gemini-3.5-flash-lite
        google-vertex/gemini-3.6-flash
        google-vertex/gemini-embedding-001
        google-vertex/gemini-flash-latest
        google-vertex/gemini-flash-lite-latest
        google-vertex/meta/llama-3.3-70b-instruct-maas
        google-vertex/meta/llama-4-maverick-17b-128e-instruct-maas
        google-vertex/moonshotai/kimi-k2-thinking-maas
        google-vertex/openai/gpt-oss-120b-maas
        google-vertex/openai/gpt-oss-20b-maas
        google-vertex/qwen/qwen3-235b-a22b-instruct-2507-maas
        google-vertex/zai-org/glm-4.7-maas
        google-vertex/zai-org/glm-5-maas
        google-vertex-anthropic/claude-haiku-4-5@20251001
        google-vertex-anthropic/claude-opus-4-5@20251101
        google-vertex-anthropic/claude-opus-4-6@default
        google-vertex-anthropic/claude-opus-4-7@default
        google-vertex-anthropic/claude-opus-4-8@default
        google-vertex-anthropic/claude-sonnet-4-5@20250929
        google-vertex-anthropic/claude-sonnet-4-6@default
        google-vertex-anthropic/claude-sonnet-5@default
        """

    static let malformedModels = """
        opencode/big-pickle
        this row contains spaces
        google-vertex/claude-sonnet-4-6@default
        """

    static let oneCredential = """
        ┌  Credentials ~/.local/share/opencode/auth.json
        │
        ●  OpenCode Go api
        │
        └  1 credentials
        """

    static let zeroCredentials = """
        ┌  Credentials ~/.local/share/opencode/auth.json
        │
        └  0 credentials
        """

    static func named(_ name: String) -> String? {
        switch name {
        case "version-1.18.4.txt": version
        case "run-help-1.18.4.txt": runHelp
        case "models-1.18.4.txt": models
        case "models-malformed.txt": malformedModels
        case "auth-one-credential-1.18.4.txt": oneCredential
        case "auth-zero-credentials-1.18.4.txt": zeroCredentials
        default: nil
        }
    }
}
