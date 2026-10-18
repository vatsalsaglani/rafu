public enum LauncherHelp {
    public static let text = """
        OVERVIEW: Open a local or SSH workspace in Rafu.

        `rafu <path>` opens or focuses a local workspace through Rafu's
        versioned same-user local IPC. The CLI starts its enclosing app bundle
        when needed. Status and SSH commands still validate only.

        USAGE:
          rafu .
          rafu <path>
          rafu --goto <path:line[:column]>
          rafu --ssh <host-alias> <remote-path>
          rafu --ssh <host-alias> --goto <path:line[:column]>

        OPTIONS:
          --new-window       Always request a new workspace window.
          --reuse-window     Reuse the best exact workspace match.
          --wait             Open now and report that waiting is deferred to v2.
          --list-ssh-hosts   List concrete OpenSSH aliases (planned Phase 1C).
          --status           Show launcher/app IPC status (planned Phase 0).
          -h, --help         Show help information.
          -V, --version      Show the Rafu version.
        """
}
