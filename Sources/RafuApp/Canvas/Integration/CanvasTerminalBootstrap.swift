import Foundation

/// One terminal owns this directory. Remove it after the terminal process has ended.
nonisolated struct CanvasTerminalBootstrap: Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String]
    let directory: URL
    /// `nil` keeps today's behavior (argv0 = `executable`, as zsh/bash/fish/
    /// POSIX/csh strategies need for their own login-shell detection).
    /// `"-\(basename)"` for strategies that still rely on the native
    /// leading-dash login convention because they have no private startup
    /// hook of their own (nushell, xonsh, environmentOnly).
    let execName: String?
    /// True only for `environmentOnly`: the wrapper directory is prepended
    /// to `PATH` in the environment alone, so a shell startup file that
    /// rewrites `PATH` afterward can still move the agent CLI wrappers
    /// behind the user's own `claude`/`codex`, if any.
    let pathMayBeReordered: Bool

    enum BootstrapError: Error, Equatable {
        case missingSocket
        case invalidCLI
    }

    /// One shell's bridge mechanism: a startup hook this type can use to
    /// install the wrapper directory ahead of the user's own `claude`/
    /// `codex`, if any, on `PATH`. `environmentOnly` is the catch-all for
    /// every other shell (elvish, an unknown basename): `PATH` is still
    /// prepended in the environment, but nothing guarantees it survives a
    /// startup file that rewrites `PATH` afterward.
    enum CanvasShellBridgeStrategy: Equatable, Sendable {
        /// Which file POSIX `sh`/`dash`/`ksh`/`mksh` read via `$ENV` when no
        /// `ENV` is already set, mirrored in the private `env.sh`'s default
        /// expression.
        enum PosixDefaultEnv: Equatable, Sendable {
            case none
            case kshrc
            case mkshrc
        }
        case zsh
        case bash
        case fish
        case posixEnv(PosixDefaultEnv)
        case cshHome
        case nushell
        case xonsh
        case environmentOnly
    }

    /// Single source of truth for which mechanism a shell basename uses.
    static func bridgeStrategy(shellBasename basename: String) -> CanvasShellBridgeStrategy {
        switch basename {
        case "zsh": return .zsh
        case "bash": return .bash
        case "fish": return .fish
        case "sh", "dash": return .posixEnv(.none)
        case "ksh": return .posixEnv(.kshrc)
        case "mksh": return .posixEnv(.mkshrc)
        case "tcsh", "csh": return .cshHome
        case "nu": return .nushell
        case "xonsh": return .xonsh
        default: return .environmentOnly
        }
    }

    /// True when `PATH` order is guaranteed after the user's own startup
    /// files finish running — every strategy except `environmentOnly`.
    /// Single source of truth for whether a shell's bridge is "fully"
    /// supported; a later Ensemble shell picker can reuse it to flag a
    /// weaker-guarantee shell before launch.
    static func supportsBridge(shellBasename basename: String) -> Bool {
        bridgeStrategy(shellBasename: basename) != .environmentOnly
    }

    @concurrent
    static func prepare(
        shellPath: String, loginArguments: [String], token: String, cliURL: URL,
        socketURL: URL? = nil,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> CanvasTerminalBootstrap {
        try Task.checkCancellation()
        let shell = URL(fileURLWithPath: shellPath).lastPathComponent
        let strategy = Self.bridgeStrategy(shellBasename: shell)
        guard cliURL.isFileURL, FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            throw BootstrapError.invalidCLI
        }
        let socket = socketURL?.path ?? baseEnvironment["RAFU_CANVAS_SOCKET"]
        guard let socket, socket.hasPrefix("/") else { throw BootstrapError.missingSocket }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rafu-canvas-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            for provider in ["claude", "codex"] {
                try write(
                    """
                    #!/bin/sh
                    exec "$RAFU_CANVAS_BRIDGE_CLI" _canvas-agent \(provider) "$@"
                    """, name: provider, directory: directory, permissions: 0o700)
            }
            // SwiftTerm replaces its default environment when a caller supplies one.
            // Preserve normal shell state and apply each bridge override exactly once.
            var environment = TerminalChildEnvironment.scrubbed(baseEnvironment)
            // A GUI launched by a command runner can inherit NO_COLOR or a forced
            // monochrome mode. These describe the host, not this interactive PTY.
            // Remove them before reading user startup files; those files can still
            // set the user's own color policy for the shell and its commands.
            for key in ["NO_COLOR", "FORCE_COLOR", "CLICOLOR", "CLICOLOR_FORCE"] {
                environment.removeValue(forKey: key)
            }
            environment["TERM"] = "xterm-256color"
            environment["COLORTERM"] = "truecolor"
            environment["RAFU_CANVAS_TOKEN"] = token
            environment["RAFU_CANVAS_SOCKET"] = socket
            environment["RAFU_CANVAS_BRIDGE_CLI"] = cliURL.path
            environment["RAFU_CANVAS_WRAPPER_DIR"] = directory.path
            let login = loginArguments.contains("-l") || loginArguments.contains("--login")
            let arguments: [String]
            switch strategy {
            case .zsh:
                environment["RAFU_CANVAS_USER_ZDOTDIR"] =
                    baseEnvironment["ZDOTDIR"] ?? baseEnvironment["HOME"] ?? NSHomeDirectory()
                environment["RAFU_CANVAS_USER_HAD_ZDOTDIR"] =
                    baseEnvironment["ZDOTDIR"] == nil ? "0" : "1"
                environment["ZDOTDIR"] = directory.path
                try prepareZsh(directory: directory)
                arguments = loginArguments + (loginArguments.contains("-i") ? [] : ["-i"])
            case .bash:
                try prepareBash(directory: directory, login: login)
                // Bash ignores --rcfile in login mode. The private rc file sources login files in order.
                arguments =
                    [
                        "--noprofile", "--rcfile", directory.appendingPathComponent("bashrc").path,
                        "-i",
                    ]
                    + loginArguments.filter { !["-l", "--login", "-i"].contains($0) }
            case .fish:
                // Fish has no ZDOTDIR/rcfile equivalent to redirect privately, but
                // `--init-command` runs after config.fish and conf.d (so it wins over
                // a user's `fish_add_path`) and before the first prompt. The command is
                // a static literal that only reads RAFU_CANVAS_WRAPPER_DIR from the
                // environment already set above; never interpolate a path or token into it.
                // A user command typed later (e.g. another `fish_add_path`) can still move
                // entries afterward — acceptable, same as zsh and bash.
                arguments =
                    loginArguments + (loginArguments.contains("-i") ? [] : ["-i"])
                    + ["--init-command", Self.installFish]
            case .posixEnv(let defaultEnv):
                environment["RAFU_CANVAS_USER_ENV"] = baseEnvironment["ENV"] ?? ""
                environment["RAFU_CANVAS_USER_HAD_ENV"] = baseEnvironment["ENV"] == nil ? "0" : "1"
                environment["ENV"] = directory.appendingPathComponent("env.sh").path
                try preparePosix(directory: directory, login: login, defaultEnv: defaultEnv)
                // sh/dash/ksh/mksh never see "-l": the private ENV file emulates the
                // login sequence itself, the same approach as bash's rcfile above.
                arguments = ["-i"]
            case .cshHome:
                environment["RAFU_CANVAS_USER_HOME"] =
                    baseEnvironment["HOME"] ?? NSHomeDirectory()
                environment["HOME"] = directory.path
                try prepareCsh(directory: directory, login: login)
                // tcsh/csh auto-source "$HOME/.tcshrc" for every interactive shell,
                // login or not; redirecting HOME is the csh equivalent of ZDOTDIR.
                // Never pass "-l": the private .tcshrc emulates the login-only files.
                arguments = ["-i"]
            case .nushell:
                // `-e` runs after env.nu/config.nu/login.nu and autoload, before the
                // REPL starts — the only hook nu offers after its own startup files.
                // The command is a static literal that only reads
                // RAFU_CANVAS_WRAPPER_DIR from the environment already set above.
                arguments = loginArguments + ["-e", Self.installNu]
            case .xonsh:
                let configHome =
                    baseEnvironment["XDG_CONFIG_HOME"]
                    ?? "\(baseEnvironment["HOME"] ?? NSHomeDirectory())/.config"
                let baseXonshrcDir =
                    baseEnvironment["XONSHRC_DIR"] ?? "/etc/xonsh/rc.d:\(configHome)/xonsh/rc.d"
                environment["XONSHRC_DIR"] =
                    "\(baseXonshrcDir):\(directory.appendingPathComponent("xonshrc.d").path)"
                try prepareXonsh(directory: directory)
                arguments = loginArguments + (loginArguments.contains("-i") ? [] : ["-i"])
            case .environmentOnly:
                // No private startup hook exists for this shell. Prepending PATH in
                // the environment alone is the only mechanism available — a startup
                // file that rewrites PATH afterward can still move the wrappers.
                environment["PATH"] = "\(directory.path):\(baseEnvironment["PATH"] ?? "")"
                arguments = loginArguments
            }
            let execName: String?
            switch strategy {
            case .nushell, .xonsh, .environmentOnly: execName = "-\(shell)"
            default: execName = nil
            }
            try Task.checkCancellation()
            return Self(
                executable: shellPath, arguments: arguments,
                environment: environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" },
                directory: directory, execName: execName,
                pathMayBeReordered: strategy == .environmentOnly)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static let install = """
        export PATH="$RAFU_CANVAS_WRAPPER_DIR:$PATH"
        """

    /// Fish's `PATH` is a list variable, not a colon-joined string; `$PATH`
    /// expands to its own elements, so prepending reads as a two-element
    /// insert rather than string concatenation. Passed verbatim to
    /// `--init-command`, never built from interpolated values.
    private static let installFish = """
        set -gx PATH $RAFU_CANVAS_WRAPPER_DIR $PATH
        """

    private static let restoreZdotdir = """
        if [[ "$RAFU_CANVAS_USER_HAD_ZDOTDIR" == 1 ]]; then
          export ZDOTDIR="$RAFU_CANVAS_USER_ZDOTDIR"
        else
          unset ZDOTDIR
        fi
        """

    private static func prepareZsh(directory: URL) throws {
        // zsh reads global files itself. Each private file reads the corresponding user file.
        // Restore the user's ZDOTDIR while their file runs, then retain any change it makes.
        for name in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
            var source = """
                \(restoreZdotdir)
                if [[ -r "${ZDOTDIR:-$HOME}/\(name)" ]]; then
                  source "${ZDOTDIR:-$HOME}/\(name)"
                fi
                if (( ${+ZDOTDIR} )); then
                  export RAFU_CANVAS_USER_HAD_ZDOTDIR=1
                  export RAFU_CANVAS_USER_ZDOTDIR="$ZDOTDIR"
                else
                  export RAFU_CANVAS_USER_HAD_ZDOTDIR=0
                  export RAFU_CANVAS_USER_ZDOTDIR="$HOME"
                fi
                export ZDOTDIR="$RAFU_CANVAS_WRAPPER_DIR"
                """
            if name == ".zshrc" {
                source += "\nif [[ ! -o login ]]; then\n\(restoreZdotdir)\n\(install)\nfi\n"
            } else if name == ".zlogin" {
                source += "\n\(restoreZdotdir)\n\(install)\n"
            }
            try write(source, name: name, directory: directory, permissions: 0o600)
        }
    }

    private static func prepareBash(directory: URL, login: Bool) throws {
        let source: String
        if login {
            source = """
                if [ -r /etc/profile ]; then . /etc/profile; fi
                if [ -r "$HOME/.bash_profile" ]; then
                  . "$HOME/.bash_profile"
                elif [ -r "$HOME/.bash_login" ]; then
                  . "$HOME/.bash_login"
                elif [ -r "$HOME/.profile" ]; then
                  . "$HOME/.profile"
                fi
                \(install)
                """
        } else {
            source = """
                if [ -r "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi
                \(install)
                """
        }
        try write(source, name: "bashrc", directory: directory, permissions: 0o600)
    }

    /// POSIX `sh`/`dash`/`ksh`/`mksh` source the file named by `$ENV` once
    /// they decide they are interactive — unlike a login shell's profile,
    /// that decision does not depend on argv0 or `-l`, so this file is the
    /// single hook needed for every one of them. A naive `ENV=<private>` +
    /// `-l` fails whenever the user's own `~/.profile` sets `ENV`, since the
    /// real profile runs before that `$ENV` is read and the private file
    /// never gets a turn; this file is read FIRST (via the overridden `ENV`)
    /// and manually emulates the login sequence before chaining to the
    /// user's own `ENV`, restored from `RAFU_CANVAS_USER_ENV` below. The
    /// `eval` only re-expands that one restored value — never a token,
    /// socket path, or anything else from this process's own environment —
    /// matching how POSIX itself expands a parameter-substituted `$ENV`.
    private static func preparePosix(
        directory: URL, login: Bool,
        defaultEnv: CanvasShellBridgeStrategy.PosixDefaultEnv
    ) throws {
        let defaultExpression: String
        switch defaultEnv {
        case .none: defaultExpression = "${ENV-}"
        case .kshrc: defaultExpression = "${ENV-$HOME/.kshrc}"
        case .mkshrc: defaultExpression = "${ENV-$HOME/.mkshrc}"
        }
        let loginLines =
            login
            ? "\nif [ -r /etc/profile ]; then . /etc/profile; fi"
                + "\nif [ -r \"$HOME/.profile\" ]; then . \"$HOME/.profile\"; fi"
            : ""
        let source = """
            if [ "${RAFU_CANVAS_USER_HAD_ENV-}" = 1 ]; then
              ENV=$RAFU_CANVAS_USER_ENV
              export ENV
            else
              unset ENV
            fi
            unset RAFU_CANVAS_USER_ENV RAFU_CANVAS_USER_HAD_ENV\(loginLines)
            rafu_canvas_env=\(defaultExpression)
            case $rafu_canvas_env in
              "~/"*) rafu_canvas_env=$HOME/${rafu_canvas_env#"~/"} ;;
              *'$'* | *'`'*) eval "rafu_canvas_env=\\"$rafu_canvas_env\\"" ;;
            esac
            if [ -n "$rafu_canvas_env" ] && [ -r "$rafu_canvas_env" ]; then . "$rafu_canvas_env"; fi
            unset rafu_canvas_env
            export PATH="$RAFU_CANVAS_WRAPPER_DIR:$PATH"
            """
        try write(source, name: "env.sh", directory: directory, permissions: 0o600)
    }

    /// tcsh/csh auto-source `$HOME/.tcshrc` (or `.cshrc`) for every
    /// interactive shell, login or not — HOME is the only lever to redirect
    /// that privately, the csh equivalent of zsh's ZDOTDIR. `/etc/csh.cshrc`
    /// still runs natively, unconditionally, before this file: it does not
    /// depend on `$HOME`, so it is never re-sourced here. The login-only
    /// files (`/etc/csh.login`, `~/.login`) are skipped by tcsh itself once
    /// `prepare` passes only `-i`, never `-l`, so this file re-creates them
    /// manually, in native order, exactly when `login` is true.
    private static func prepareCsh(directory: URL, login: Bool) throws {
        let loginOpen = login ? "\nif ( -r /etc/csh.login ) source /etc/csh.login" : ""
        let loginClose = login ? "\nif ( -r \"$HOME/.login\" ) source \"$HOME/.login\"" : ""
        let source = """
            setenv HOME "$RAFU_CANVAS_USER_HOME"
            unsetenv RAFU_CANVAS_USER_HOME\(loginOpen)
            if ( -r "$HOME/.tcshrc" ) then
              source "$HOME/.tcshrc"
            else if ( -r "$HOME/.cshrc" ) then
              source "$HOME/.cshrc"
            endif\(loginClose)
            setenv PATH "${RAFU_CANVAS_WRAPPER_DIR}:${PATH}"
            """
        try write(source, name: ".tcshrc", directory: directory, permissions: 0o600)
    }

    /// nushell's install hook: passed verbatim to `-e` (see `prepare`),
    /// never built from interpolated values.
    private static let installNu = """
        $env.PATH = ($env.PATH | prepend $env.RAFU_CANVAS_WRAPPER_DIR)
        """

    /// xonsh loads every file in each directory on `XONSHRC_DIR`, in
    /// alphabetical order, after all `XONSHRCRC`-style files — so a file that
    /// sorts last in a directory appended to the end of `XONSHRC_DIR` is the
    /// final word on `PATH`, after the user's own configuration.
    private static func prepareXonsh(directory: URL) throws {
        let rcDirectory = directory.appendingPathComponent("xonshrc.d", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rcDirectory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try write(
            "$PATH.insert(0, $RAFU_CANVAS_WRAPPER_DIR)",
            name: "zzzz-rafu-canvas.xsh", directory: rcDirectory, permissions: 0o600)
    }

    private static func write(_ source: String, name: String, directory: URL, permissions: Int)
        throws
    {
        let url = directory.appendingPathComponent(name)
        try Data((source + "\n").utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}
