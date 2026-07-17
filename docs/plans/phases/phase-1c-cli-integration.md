# Phase 1C — CLI and desktop integration

- **Status:** In progress — deterministic local IPC/goto/window routing complete (2026-07-18); SSH, wait v2, signing, and remaining desktop exits remain
- **Depends on:** Product Phase 0 CLI proof and stable Phase 1A/1B workspace routing contracts
- **Canonical scope:** v0.4 §9, §15 Phase 1C, and §16 CLI backlog

## Goal

Make `rafu` a reliable signed launcher for local and SSH workspaces, whether the app is closed or running, with deterministic multi-window routing and `--wait`.

## Scoped deliverables

- Argument and URI parsing for paths, `--goto`, `--new-window`, `--reuse-window`, `--wait`, `--ssh`, `--list-ssh-hosts`, `--status`, `--version`, and `--help`.
- Relative-path resolution in the caller, Launch Services app discovery/start by bundle identifier, versioned IPC handshake/acknowledgement, request size/path validation, same-user peer checks, stale-socket recovery, and concurrent requests.
- Exact window routing for matching local roots and SSH host/root pairs; file-tab and workspace wait tokens with clean signal handling.
- Settings UI to install a copy at `~/.local/bin/rafu`, explain PATH, optionally use another writable destination, verify, and uninstall without a privileged helper.
- Finder drag/drop and Open With integration where practical.

## Explicit non-goals

- Shell-command execution, arbitrary remote commands, privileged helper, absolute symlink into a movable app bundle, Git/AI commands, or an embedded terminal.
- Reworking SSH transport or editor behavior except through established routing contracts.

## Owned paths

- Launcher owner: `Rafu/Launcher` and launcher tests.
- IPC owner: `Rafu/App/LauncherIPCServer.swift`, IPC models/support, socket tests.
- Routing owner: `Rafu/App/WindowCoordinator.swift`, focused workspace routing adapters/tests.
- Installation owner: `Rafu/Settings/CommandLineToolSettingsView.swift` and installer support/tests.
- Integration owner controls shared app entrypoint, URL/document types, bundle metadata, and target embedding.

## Locked decisions

- Command name is `rafu`; launcher is a separate small signed target bundled under `Contents/SharedSupport/bin`.
- IPC socket lives in a user-only cache directory and every request is versioned/size-bounded.
- Default reuses an exact workspace; flags override routing.
- App acknowledges only after acceptance or a concrete error.
- `--wait` termination never closes the editor window.

## Open blockers to resolve

- Final bundle identifier.
- Whether a file outside every workspace opens a lightweight standalone window or its containing folder.
- Exact precedence/error behavior for incompatible flag combinations and ambiguous multiple installed app copies.
- Final user-directed install destinations beyond `~/.local/bin`.

## Required project references

- [`../../references/project-structure.md`](../../references/project-structure.md)
- [`../../references/build-and-run.md`](../../references/build-and-run.md)
- [`../../references/concurrency.md`](../../references/concurrency.md)
- [`../../references/launcher-cli.md`](../../references/launcher-cli.md)

## Required skills and capabilities

- `.agents/skills/swift-concurrency-pro` for socket lifetimes, cancellation, concurrent requests, and wait sessions.
- `.agents/skills/design-an-interface` before changing request, routing, acknowledgement, or wait-token contracts.
- `.agents/skills/swiftui-expert-skill` for Settings and routing-visible state.
- `build-macos-apps:swiftui-patterns` and `build-macos-apps:window-management` for settings, commands, activation, and multi-window focus.
- `build-macos-apps:build-run-debug` and `build-macos-apps:telemetry` for closed/running paths and event proof; use `build-macos-apps:test-triage` only after a failure.
- `build-macos-apps:signing-entitlements` for launcher embedding/signature and Gatekeeper diagnostics.

## Worktree decomposition and integration order

1. Integration owner freezes request/response schemas, routing identity, activation policy, and wait semantics.
2. Launcher parser/client and app IPC server worktrees proceed in parallel.
3. Integrate Launch Services start plus handshake before window routing.
4. Integrate local routing, then SSH routing, then `--wait`.
5. Integrate installer/Settings and desktop metadata last.
6. Run signed Release-path tests in addition to Debug tests.

## Verification and measurements

- App closed/running, stale socket, moved app, multiple app copies, relative/absolute/symlink paths, invalid `--goto`, local/SSH routes, concurrent requests, unsupported protocol, and signals during `--wait`.
- Verify every documented command surface and stable help text.
- Verify socket directory mode, peer validation, message limits, canonicalization, and no remote-command operation in the protocol.
- Verify install, PATH guidance, Launch Services discovery after app movement, uninstall, and launcher signature.
- Telemetry proves one accepted/rejected lifecycle per request without logging sensitive paths beyond approved public metadata.
- Measure cold app-start-to-ack and warm request-to-ack; retain baselines for regressions.

## Exit criteria

- `rafu .` opens/focuses a local repository correctly.
- `rafu --ssh prod /srv/app` opens/focuses the matching SSH workspace.
- File location, new/reuse window, URI, diagnostic, and wait flows work with the app closed and running.
- Multiple windows route deterministically and concurrent requests do not corrupt state.
- Install/verify/uninstall is reversible and survives normal app movement.
- The combined Phase 1 public exit criteria are satisfied with 1A and 1B.

## Documentation handoff

Record the CLI grammar, exit codes, IPC protocol/version, socket permissions, routing matrix, Launch Services edge cases, install locations, timing baselines, and signed-artifact verification commands. Update user-facing command documentation from generated/help-source truth.
