import Foundation

/// One terminal owns this directory. Remove it after the terminal process has ended.
nonisolated struct CanvasTerminalBootstrap: Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String]
    let directory: URL

    enum BootstrapError: Error {
        case unsupportedShell
        case missingSocket
        case invalidCLI
    }

    @concurrent
    static func prepare(
        shellPath: String, loginArguments: [String], token: String, cliURL: URL,
        socketURL: URL? = nil,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> CanvasTerminalBootstrap {
        try Task.checkCancellation()
        let shell = URL(fileURLWithPath: shellPath).lastPathComponent
        guard shell == "zsh" || shell == "bash" else { throw BootstrapError.unsupportedShell }
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
            var environment = baseEnvironment
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
            let arguments: [String]
            if shell == "zsh" {
                environment["RAFU_CANVAS_USER_ZDOTDIR"] =
                    baseEnvironment["ZDOTDIR"] ?? baseEnvironment["HOME"] ?? NSHomeDirectory()
                environment["RAFU_CANVAS_USER_HAD_ZDOTDIR"] =
                    baseEnvironment["ZDOTDIR"] == nil ? "0" : "1"
                environment["ZDOTDIR"] = directory.path
                try prepareZsh(directory: directory)
                arguments = loginArguments + (loginArguments.contains("-i") ? [] : ["-i"])
            } else {
                try prepareBash(
                    directory: directory,
                    login: loginArguments.contains("-l") || loginArguments.contains("--login"))
                // Bash ignores --rcfile in login mode. The private rc file sources login files in order.
                arguments =
                    [
                        "--noprofile", "--rcfile", directory.appendingPathComponent("bashrc").path,
                        "-i",
                    ]
                    + loginArguments.filter { !["-l", "--login", "-i"].contains($0) }
            }
            try Task.checkCancellation()
            return Self(
                executable: shellPath, arguments: arguments,
                environment: environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" },
                directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static let install = """
        export PATH="$RAFU_CANVAS_WRAPPER_DIR:$PATH"
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

    private static func write(_ source: String, name: String, directory: URL, permissions: Int)
        throws
    {
        let url = directory.appendingPathComponent(name)
        try Data((source + "\n").utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}
