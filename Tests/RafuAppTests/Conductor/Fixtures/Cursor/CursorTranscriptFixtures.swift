enum CursorTranscriptFixtures {
    // Recorded locally from the installed Cursor Agent CLI.
    static let version = """
        2025.09.18-7ae6800
        """

    // Recorded locally from the installed Cursor Agent CLI.
    static let help = """
        Usage: cursor-agent [options] [command] [prompt...]
          -p, --print
          --output-format <format>
          --model <model>
          -f, --force
          status
        """

    // Recorded locally. The real status output contains cursor-control ANSI
    // sequences; retaining them exercises production sanitization.
    static let statusNotLoggedIn =
        "\u{001B}[2K\u{001B}[1A Starting login process...\n"
        + "\u{001B}[2K\u{001B}[G Checking authentication status...\n"
        + "\u{001B}[2K\u{001B}[1A\u{001B}[G Not logged in\n"

    // Synthetic positive case: the local account was not logged in.
    static let statusLoggedIn = """
        Logged in
        """
}
