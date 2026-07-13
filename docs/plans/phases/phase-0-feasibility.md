# Phase 0 — Technical feasibility and architecture locks

- **Status:** Planned
- **Depends on:** Bootstrap checkpoint in [README](README.md)
- **Canonical scope:** v0.4 §15 Phase 0 and §21

## Goal

Prove the three highest-risk foundations—TextKit editing, SSH/remote-agent lifecycle, and CLI-to-app IPC—before product breadth. This is Product Phase 0, not the bootstrap scaffold.

## Scoped deliverables

- Editor spike: SwiftUI wrapper around a TextKit 2 editor; open/edit/save/undo/line numbers; one incremental Tree-sitter grammar; IME, Unicode, and large-file evidence.
- Buffer boundary: `NSTextStorage` owns live text; SwiftUI observes only buffer metadata and revision state.
- SSH spike: concrete alias discovery with `Include`, `ssh -G` diagnostics, `/usr/bin/ssh` connection, askpass and unknown-host-key flow, prototype versioned Rust helper, one remote atomic read/write, disconnect/reconnect with a dirty local buffer preserved.
- CLI spike: signed-target shape, Launch Services app start/focus, one `open local folder` request over versioned same-user Unix-socket IPC, stale-socket recovery.
- Release-build baseline traces for memory and typing latency.

## Explicit non-goals

- File tree, broad editor commands, themes/Markdown polish, Git, AI, full SSH browser, CLI installation UI, or release packaging.
- Locking in a third-party editor dependency without a replaceability and memory review.
- Treating a prototype remote command as a general shell-execution surface.

## Owned paths

- Integration/foundation owner: `Package.swift`, `Sources/RafuCore/Workspace`, `Sources/RafuCore/FileSystem`, `Sources/RafuApp/App/RafuApp.swift`, shared fixtures, and cross-feature composition only.
- Editor worktree: `Sources/RafuCore/Editor`, `Sources/RafuApp/Editor`, `Sources/RafuCore/Syntax`, and `Tests/EditorTests`.
- SSH worktree: `Sources/RafuCore/Remote`, `Sources/RafuApp/Remote`, `remote-agent`, `Tests/SSHConfigTests`, and `Tests/RemoteProtocolTests`.
- CLI worktree: `Sources/RafuCore/Launcher`, `Sources/RafuCLI`, `Sources/RafuApp/Launcher`, and `Tests/LauncherTests`.

Only the integration owner changes shared protocol signatures after parallel work starts.

## Locked decisions

- SwiftUI shell plus AppKit/TextKit 2 editor.
- System OpenSSH; normal `known_hosts`; no custom SSH implementation.
- Remote helper is Rust, versioned, stdio-only, and runs as the authenticated user.
- CLI uses Launch Services plus Unix-domain socket IPC.
- No full document in observable state; typing remains local.

## Open blockers to resolve

- Final bundle identifier and Phase 0 deployment target.
- Editor foundation: STTextView, CodeEditSourceEditor, or bespoke TextKit 2. Document the evaluation and escape hatch.
- Maintained Swift Tree-sitter wrapper and first grammar.
- Binary protocol encoding choice (CBOR or MessagePack), frame limit, and compatibility policy.
- Exact supported macOS OpenSSH options for the fixed agent command.

## Required project references

- [`../../references/project-structure.md`](../../references/project-structure.md)
- [`../../references/build-and-run.md`](../../references/build-and-run.md)
- [`../../references/concurrency.md`](../../references/concurrency.md)
- [`../../references/launcher-cli.md`](../../references/launcher-cli.md)
- [`../../references/swiftui-appkit-boundary.md`](../../references/swiftui-appkit-boundary.md)

## Required skills and capabilities

- `.agents/skills/swiftui-expert-skill` for state ownership and editor bridge review.
- `.agents/skills/swift-concurrency-pro` for actors, process draining, cancellation, and async streams.
- `.agents/skills/design-an-interface` before locking editor, remote-frame, and launcher IPC contracts.
- `build-macos-apps:appkit-interop` for the smallest TextKit representable/responder boundary.
- `build-macos-apps:build-run-debug` for the app/CLI build-launch loop.
- `build-macos-apps:telemetry` for privacy-safe logs and typing/memory signposts.
- `build-macos-apps:test-triage` only when a focused spike failure needs diagnosis.

## Worktree decomposition and integration order

1. Foundation owner locks workspace IDs, file snapshot/version types, buffer metadata, protocol versioning, fixture interfaces, and build commands.
2. Editor, SSH, and CLI agents implement independently against those contracts.
3. Integrate editor proof first and capture local baseline.
4. Integrate remote protocol/agent, then SSH process and askpass UI.
5. Integrate CLI server/client after the app lifecycle is stable.
6. Run the combined disconnect, stale-socket, and memory/latency gate.

## Verification and measurements

- Build and launch with the repository run script; build CLI separately in Debug and Release.
- Automated tests for buffer metadata, protocol framing/limits, SSH config includes, IPC version rejection, and stale socket cleanup.
- Manual proof: edit/save one local file; edit/save one remote file through an SSH alias; cut the connection with a dirty buffer; reconnect without loss; run `rafu .` with the app closed and running.
- Exercise emoji, combining marks, RTL sample, and CJK IME.
- Record Release resident memory and a typing trace; report p95 edit handling relative to one display frame rather than claiming success from feel alone.
- Confirm no credentials, file contents, or diffs appear in logs.

## Exit criteria

- One local and one remote file can be edited and saved.
- Unsaved remote edits survive connection loss.
- `rafu .` launches/focuses the app and opens a folder through IPC.
- One grammar highlights incrementally without full-string SwiftUI observation.
- Baseline memory and typing traces are stored and reproducible.
- No file-tree or polish work starts before this combined gate passes.

## Documentation handoff

Record the editor-dependency decision, protocol framing/version, SSH option verification, IPC contract, exact commands, baseline artifacts, failures found, and any changes needed to Phase 1 ownership. Update phase status only after every exit criterion has evidence.
