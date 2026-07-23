/// Metadata-only transcripts recorded from the installed Cline 3.0.46
/// binary on 2026-07-24. `cline config` was deliberately not recorded
/// because it may contain provider configuration or credential material.
nonisolated enum ClineAdapterFixtures {
    static let version = "3.0.46\n"

    static let help = """
        Usage: cline [options] [command] [prompt]

        Cline CLI - AI coding assistant in your terminal

        Arguments:
          prompt                        Your prompt. Default to start in act mode with auto-approve enabled.

        Options:
          -V, --version                 Output the version number
          -p, --plan                    Run in plan mode
          --json                        Output messages as JSON instead of styled text
          --auto-approve <boolean>      Set tool auto-approval for all tools (default: true)
          -c, --cwd <path>              Working directory
          -i, --tui                     Open the terminal user interface (TUI) for interactive sessions
          -P, --provider <id>           Provider id (default: cline)
          -k, --key <api-key>           API key override for this run
          -m, --model <model-id>        Model to use for the session with the selected provider
          --worktree                    Auto-create a detached git worktree
          -h, --help                    display help for command

        Commands:
          auth [options] [provider]     Authenticate a provider and configure what model is used
          config [options]              Show current configuration
        """

    static func named(_ name: String) -> String? {
        switch name {
        case "version-3.0.46.txt": version
        case "help-3.0.46.txt": help
        default: nil
        }
    }
}
