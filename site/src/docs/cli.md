---
title: The rafu command
description: A deliberately small launcher — rafu ., --goto, --new-window.
---

# The `rafu` command

Rafu ships a small command-line launcher bundled inside the app. It is a launcher,
not a second product: it locates the app by bundle identifier through Launch Services
and talks to it over a private, peer-validated Unix socket.

> IPC v1 ships today: opening folders and files, `--goto`, and window routing.
> `--wait` (editor `$EDITOR` flows) is honestly deferred to v2; `--ssh` arrives with
> SSH workspaces.

## Command surface

```bash
# Open the current directory
rafu .

# Open a file
rafu README.md

# Always open in a new workspace window
rafu --new-window .

# Reuse the best matching existing window
rafu --reuse-window .

# Open a file at a line and column
rafu --goto Sources/App.swift:42:8

# Block until the file or workspace closes (editor $EDITOR flows)
rafu --wait README.md

# Open a remote folder through an SSH config alias
rafu --ssh prod-api /srv/api

# URI form, for scripts and links
rafu 'ssh://prod-api/srv/api'

# Diagnostics
rafu --list-ssh-hosts
rafu --status
rafu --version
```

## Installation

**Settings → General → Command Line Tool → Install…**

1. Copies the signed launcher to `~/.local/bin/rafu`
2. If that directory isn't on your `PATH`, shows the exact one-line shell configuration
   for your detected shell
3. Offers `/usr/local/bin` when it already exists and is writable
4. No privileged helper, and Uninstall / Verify beside Install

The installed command is a real copied binary, not a fragile absolute symlink into an
app bundle that may move.

## How `--wait` will work (v2)

The app returns a wait token; the launcher subscribes until the specific file tab
closes (file request) or the workspace window closes (folder request). Signals
terminate the wait cleanly without closing the editor window — which is what makes
`rafu --wait` viable as a Git editor.

## Security posture

- Socket directory is user-only (`0700`); peer credentials validated
- Versioned, size-bounded messages; local paths canonicalized before routing
- All CLI arguments treated as untrusted input
- No remote command-execution surface in the launcher protocol — opening an SSH
  workspace sends a host alias and path, never a shell command
