public enum LauncherHelp {
    public static let text = """
        OVERVIEW: Open a local or SSH workspace in Rafu.

        The bootstrap CLI currently validates requests. App activation and IPC are
        delivered by product Phase 0 and Phase 1C.

        USAGE:
          rafu .
          rafu <path>
          rafu --goto <path:line[:column]>
          rafu --ssh <host-alias> <remote-path>
          rafu --ssh <host-alias> --goto <path:line[:column]>

        OPTIONS:
          --new-window       Always request a new workspace window.
          --reuse-window     Reuse the best exact workspace match.
          --wait             Wait for the requested tab or workspace to close.
          --list-ssh-hosts   List concrete OpenSSH aliases (planned Phase 1C).
          --status           Show launcher/app IPC status (planned Phase 0).
          -h, --help         Show help information.
          -V, --version      Show the Rafu version.
        """
}
