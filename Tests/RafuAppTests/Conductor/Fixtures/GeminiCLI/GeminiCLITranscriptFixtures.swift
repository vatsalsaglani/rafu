enum GeminiCLITranscriptFixtures {
    // Synthetic, document-derived transcript. Gemini CLI was not installed
    // locally, so neither this version nor this help surface is local evidence.
    static let version = """
        0.20.0
        """

    // Synthetic, document-derived, and locally unverified.
    static let help = """
        Usage: gemini [options]
          -p, --prompt <prompt>
          -m, --model <model>
          --output-format <format>
          --approval-mode <mode>
        """
}
