# Phase 1B — SSH workspace parity

- **Status:** Planned
- **Depends on:** Product Phase 0 SSH proof and Phase 1A internal v0.1
- **Canonical scope:** v0.4 §8, §13, §15 Phase 1B, and §16 SSH backlog

## Goal

Make an SSH folder feel like the same editor and file model as a local workspace while authentication, transport, watches, and saves remain secure and resilient.

## Scoped deliverables

- Open SSH Folder flow, concrete-alias catalog with nested `Include` support, manual alias/`user@host`, `ssh -G` diagnostics, remote folder picker, recents, and restoration.
- `/usr/bin/ssh` process runner with concurrent stdout/stderr draining, fixed argument arrays, no TTY, disabled unrelated forwarding/commands, app-owned control sockets, and bounded cancellation/timeouts.
- Signed askpass helper/broker, workspace-window prompts, unknown-host confirmation, changed-host blocking, and normal OpenSSH `known_hosts` updates.
- Versioned Rust agent install/update for Linux/macOS x86_64/arm64, handshake/capabilities, raw-byte paths, bounded frames, chunked reads, metadata/list/stat, atomic writes, create/move/delete, watch/cancel/ping.
- Remote `WorkspaceFileSystem`, lazy tree, expected-version conflict handling, bounded watches, reconnect state machine, and dirty-buffer restoration.

## Explicit non-goals

- Remote Windows, custom SSH library, listening remote socket, remote mirror, recursive whole-repository watches, remote project search, remote Git, terminal, port forwarding UI, or executable workspace tasks.
- Silent host-key acceptance, changed-key bypass, shell interpolation of selected paths, or API-key transfer to the remote agent.

## Owned paths

- SSH client owner: `Rafu/Remote/SSH*`, askpass helper target, SSH tests.
- Agent/protocol owner: `remote-agent`, `Rafu/Remote/RemoteProtocol.swift`, protocol tests and release-manifest fixtures.
- Remote file-system owner: `Rafu/Remote/RemoteWorkspaceFileSystem.swift`, remote tree/watch/reconnect models and tests.
- UI/restoration owner: SSH opening/settings/window-status surfaces under `Rafu/Workspace`, `Rafu/Settings`, and `Rafu/DesignSystem`.
- Integration owner controls shared `WorkspaceFileSystem`, `WorkspacePath`, and project/helper embedding changes.

## Locked decisions

- OpenSSH is configuration/authentication authority; connection uses the entered alias.
- Host catalog is discovery only; `ssh -G` is diagnostics only.
- Agent uses stdio, runs with user privileges, has no listening port, and receives workspace root through the protocol.
- Remote paths preserve raw bytes; atomic writes include expected-version checks.
- Dirty buffers remain local and survive disconnect; typing never waits on SSH.

## Open blockers to resolve

- Automatic agent install after host trust versus one-time explanatory confirmation.
- Control-master sharing per effective host versus isolation per workspace.
- Exact remote symlink containment policy.
- Maximum Phase 1 file size, chunk size, frame size, and bounded concurrency.
- Default crash-restoration storage/disclosure for dirty remote buffers.
- Per-host custom install behavior for `noexec` cache/home environments.

## Required project references

- [`../../references/project-structure.md`](../../references/project-structure.md)
- [`../../references/build-and-run.md`](../../references/build-and-run.md)
- [`../../references/concurrency.md`](../../references/concurrency.md)
- [`../../references/swiftui-appkit-boundary.md`](../../references/swiftui-appkit-boundary.md)

## Required skills and capabilities

- `.agents/skills/swift-concurrency-pro` for process lifetimes, actor reentrancy, cancellation, streams, backpressure, and reconnect state.
- `.agents/skills/design-an-interface` before locking remote paths, framing, capability, and reconnect contracts.
- `.agents/skills/swiftui-expert-skill` for window-scoped prompt/state composition.
- `.agents/skills/apple-design` for agency, spatially scoped errors, and nonblocking feedback.
- `build-macos-apps:appkit-interop` only where askpass panels or first-responder behavior exceed SwiftUI.
- `build-macos-apps:build-run-debug` and `build-macos-apps:telemetry` for real process/log verification; use `build-macos-apps:test-triage` only after a failure.
- `build-macos-apps:signing-entitlements` when embedding/signing the askpass helper or diagnosing launch trust.

## Worktree decomposition and integration order

1. Integration owner freezes remote path, frame, error, capability, and version contracts.
2. Agent/protocol and SSH process/askpass worktrees proceed in parallel with fixtures.
3. Integrate agent bootstrap and handshake before file-system operations.
4. Integrate remote file-system list/read/write, then watch events and conflict semantics.
5. Integrate opening UI, window status, recents/restoration, and reconnect behavior last.
6. Run the complete supported-host, security, latency, and resource matrix.

## Verification and measurements

- SSH config cases: includes/globs, wildcard/negation, Match, ProxyJump/ProxyCommand, identities, agent/security-key, custom known-hosts, syntax error, and missing config.
- Authentication: agent, passphrase, password, multi-step prompt, cancel, unknown/changed host key, window closed during prompt.
- Agent: four target triples, permission/noexec/disk-full/corrupt upload/protocol mismatch/crash, unusual shell startup, raw-byte/newline/Unicode paths, symlink boundary, watch overflow.
- Disconnect each operation: list/read/write/watch/bootstrap; test clean and dirty reconnect outcomes.
- High-latency typing proof: editor remains local and responsive.
- Measure additional idle remote client overhead against roughly 20–40 MB beyond buffers and agent idle memory against roughly 25 MB; prove no repository preload.
- Inspect logs for credential/path/content leakage and validate user-only socket/cache permissions.

## Exit criteria

- `Open SSH Folder` reaches a remote root through the user's real SSH configuration.
- Local and remote windows use the same file-tree/editor model.
- Remote files can be created, opened, edited, atomically saved, renamed, moved, and deleted.
- External remote changes and watch overflow recover correctly.
- Dirty edits survive disconnect and app relaunch; changed remote content produces an explicit conflict.
- Unknown hosts require confirmation; changed keys block.
- All four target triples and resource budgets have evidence.

## Documentation handoff

Record supported SSH options, askpass classification rules, install paths/permissions, protocol/version compatibility, symlink and chunk/frame decisions, reconnect transitions, host fixture setup, measured overhead, and recovery diagnostics. Hand Phase 1C stable local/SSH routing identifiers and error contracts.
