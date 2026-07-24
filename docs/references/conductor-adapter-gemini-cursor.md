# Gemini CLI and Cursor CLI Ensemble adapters

- **Applies to:** C4 binary discovery, capability probes, delegated-auth
  classification, model choices, and invocation construction for Gemini CLI
  and Cursor Agent CLI
- **Last verified:** Apple Swift 6.2.4, Xcode 26.3 (17C529), macOS 26.5.2
  (25F84), Gemini CLI absent, and Cursor Agent CLI
  `2025.09.18-7ae6800` on 2026-07-24

## Rule or observed behavior

Both adapters discover an executable from the current process's `PATH` plus
`RafuConductorEnvironment.curatedPath`, retain its absolute URL, and prepend
the discovered executable's directory to the child `PATH` only when that
directory is not already curated. A run invocation stays disabled until a
bounded `--version` and `--help` probe succeeds and the help output contains
the required invocation surface.

Probes use a three-second deadline, a 32 KiB combined stdout/stderr cap,
`/dev/null` stdin, and `ProcessResourceRegistry` registration. Cancellation
and timeout send `SIGTERM`, then `SIGKILL` if the direct child does not exit.
The signal targets the direct PID, not a process group; a CLI that spawns a
grandchild during a probe could therefore leave that grandchild behind.

Do not call `Process.waitUntilExit()` after polling `Process.isRunning` to
`false` while pipe readability handlers are installed. The first serial C4
gate exposed a Foundation hang in that shape even though the direct child had
already exited. The bounded runners instead treat `isRunning == false` as the
completion condition, detach the handlers, drain the remaining bytes, and
then read `terminationStatus`. Both focused serial tests and the full serial
suite verify that completion path.

Neither adapter reads a credential file, credential value, or API-key
environment value. Probe subprocesses receive only `HOME` and the curated
`PATH`, allowing the vendor CLI itself to inspect its delegated OAuth state.
Run invocations add only `RAFU_RUN_DIR`, `RAFU_HANDOFF`, and the curated
`PATH`; `TerminalProcessSpec` later merges SwiftTerm's small base environment,
which includes `HOME` when available. OAuth remains owned by the installed
CLI. The C0 environment contract has no secure inherit-by-name mechanism, so
`GEMINI_API_KEY`, `GOOGLE_API_KEY`, `GOOGLE_APPLICATION_CREDENTIALS`, and
`CURSOR_API_KEY` are not forwarded. Supporting an API-key path later requires
a shared-contract change; C4 does not read a value and put it into an
`AdapterInvocation`.

### Gemini CLI: locally unverified

`gemini` was not installed anywhere visible to the process on the verification
host. All local Gemini behavior is therefore unverified, including version,
help spelling, authentication lookup, model availability, both autonomy
mappings, and an actual headless run.

Current official Gemini CLI documentation supports the general surface used by
the adapter:

- `-p`/`--prompt` for headless execution
- `-m`/`--model` for model selection
- `--output-format json`
- `--approval-mode`, including `default` and `auto_edit`

The same official documentation currently announces that Gemini CLI is being
replaced by Antigravity CLI for unpaid-tier and Google One users. That
provider-transition notice does not change C4's roster, but it makes
installation, account eligibility, and future flag stability explicit
re-verification risks for this best-effort adapter.

The adapter uses the phase-specified mappings:

| Rafu autonomy | Constructed Gemini arguments | Verification status |
|---|---|---|
| `readOnly` | `-p <prompt> -m <model> --output-format json --approval-mode default` | Document-derived; not locally verified. `default` is conservative but is not a strict read-only sandbox. |
| `worktreeWrite` | `-p <prompt> -m <model> --output-format json --approval-mode auto_edit` | Document-derived; not locally verified. It is less permissive than `yolo`. |

The current documentation also describes a `plan` approval mode as read-only,
but C4 did not claim it without an installed CLI probe. Re-evaluate
`readOnly` against `gemini --help` and a scratch-directory run when Gemini CLI
is installed. The curated `gemini-2.5-pro` and `gemini-2.5-flash` identifiers
are present in current official model-selection documentation, but their
availability to this user's account was not verified. Gemini exposes no
locally verified model-listing or non-interactive auth-status command, so
model discovery returns `nil` and auth status remains `unknown`.

The Gemini fixture is **synthetic and document-derived**. Its `0.20.0` version
line is test data, not a claim about an installed or current release.

### Cursor Agent CLI: help surface verified, account run unverified

The installed executable was
`/Users/vatsalsaglani/.local/bin/cursor-agent`, version
`2025.09.18-7ae6800`. Its local help exited zero and advertised:

```text
-p, --print                  Print responses to console (for scripts or
                             non-interactive use). Has access to all tools,
                             including write and bash.
--output-format <format>     ... text | json | stream-json
--model <model>              ... (e.g., gpt-5, sonnet-4,
                             sonnet-4-thinking)
-f, --force                  Force allow commands unless explicitly denied
status                       Check authentication status
```

This verifies the C4 `worktreeWrite` argv surface:

```text
-p --output-format json --force --model <model> <prompt>
```

It does not verify a completed agent run: `cursor-agent status` printed
`Not logged in` and exited `0`. The adapter must therefore classify the
negative text before treating exit zero as authentication. Login remains
delegated and the user-facing hint is
`` run `cursor-agent login` in a terminal ``.

No plan/read-only option appeared in the installed help, and Cursor's official
CLI documentation says print mode has full write access. Cursor `readOnly`
therefore fails closed through the placeholder invocation; only
`worktreeWrite` is supported. The C0 adapter protocol and Settings row have no
supported-autonomy or unsupported-reason field, so Settings cannot yet display
that limitation even though the adapter and tests state it.

No model-listing command appeared. The installed `ls` command lists resumable
chats, not models. Dynamic model discovery therefore returns `nil`. The
curated `gpt-5`, `sonnet-4`, and `sonnet-4-thinking` identifiers are examples
from installed help, but a logged-in account did not verify their
availability.

The Cursor version, relevant help excerpt, and logged-out status fixture are
**recorded local evidence**. The positive `Logged in` fixture is
**synthetic**, because this host was logged out.

## Why it matters

These are best-effort adapters. An installed binary is not enough evidence
that Rafu can safely run it: the expected headless flags must also be present,
unsupported autonomy must fail closed, and authentication must not be inferred
from a zero exit code alone. Keeping document-derived and account-verified
claims separate prevents the Settings surface and run engine from presenting
capabilities that were never exercised.

The explicit environment boundary also preserves ADR 0018's trust model.
Rafu delegates OAuth lookup to the vendor CLI through `HOME`; it does not turn
provider credentials into Rafu-owned configuration.

## Reproduction or evidence

The local discovery and Cursor probes were:

```console
$ command -v gemini
# no output; exit 1

$ command -v cursor-agent
/Users/vatsalsaglani/.local/bin/cursor-agent

$ /Users/vatsalsaglani/.local/bin/cursor-agent --version </dev/null
2025.09.18-7ae6800
# exit 0

$ /Users/vatsalsaglani/.local/bin/cursor-agent --help </dev/null
# included --print, --output-format, --model, --force, login, status, and ls
# exit 0

$ /Users/vatsalsaglani/.local/bin/cursor-agent status </dev/null
Starting login process...
Authenticating with Cursor...
Checking authentication status...
Not logged in
# exit 0
```

No credential file or environment value was opened or printed during these
probes.

### User-side Gemini verification commands

Run these after installing and authenticating Gemini CLI. They inspect only
CLI output and a new scratch directory:

```bash
command -v gemini
gemini --version </dev/null
gemini --help </dev/null
gemini -p "Return exactly RAFU_GEMINI_HEADLESS_OK." \
  -m gemini-2.5-flash \
  --output-format json \
  --approval-mode default </dev/null

gemini_probe_dir="$(mktemp -d /tmp/rafu-gemini-c4.XXXXXX)"
cd "$gemini_probe_dir"
/usr/bin/git init -q
gemini -p "Create rafu-auto-edit-probe.txt containing exactly OK." \
  -m gemini-2.5-flash \
  --output-format json \
  --approval-mode auto_edit </dev/null
/usr/bin/test -f "$gemini_probe_dir/rafu-auto-edit-probe.txt"
```

Also probe the documented stricter mode before changing the adapter's
`readOnly` mapping:

```bash
gemini --help </dev/null | /usr/bin/grep -E -- \
  '--approval-mode|default|auto_edit|plan|yolo'
gemini -p "Analyze this empty repository without modifying it." \
  -m gemini-2.5-flash \
  --output-format json \
  --approval-mode plan </dev/null
```

Retain the scratch directory until its Git status and output have been
reviewed; do not test autonomy inside a real repository.

### User-side Cursor account verification commands

The local help/status evidence can be reproduced without exposing a token:

```bash
/Users/vatsalsaglani/.local/bin/cursor-agent --version </dev/null
/Users/vatsalsaglani/.local/bin/cursor-agent --help </dev/null
/Users/vatsalsaglani/.local/bin/cursor-agent status </dev/null
printf 'status-exit=%s\n' "$?"
```

After signing in with `cursor-agent login`, verify the account-gated write
path only in a scratch repository:

```bash
cursor_probe_dir="$(mktemp -d /tmp/rafu-cursor-c4.XXXXXX)"
cd "$cursor_probe_dir"
/usr/bin/git init -q
/Users/vatsalsaglani/.local/bin/cursor-agent \
  -p \
  --output-format json \
  --force \
  --model gpt-5 \
  "Create rafu-cursor-probe.txt containing exactly OK." </dev/null
/usr/bin/test -f "$cursor_probe_dir/rafu-cursor-probe.txt"
```

This last command remains unverified on the 2026-07-24 host because the
installed CLI was logged out.

## Verification

The focused C4 command passed 14 tests across the two suites, up from the four
C0 stub tests:

```bash
swift test --filter 'GeminiCLIAdapter|CursorAdapter'
```

The tests cover exact argv arrays with shell metacharacters left inert,
minimal environments, credential-key exclusion, curated/non-curated `PATH`
behavior, locally recorded versus synthetic transcript classification,
logged-out exit-zero auth classification, unsupported Cursor `readOnly`,
probe caching, timeouts, cancellation, and serial process completion.

All required headless gates passed:

```bash
swift build
swift test
swift test --no-parallel
./script/format.sh --fix
./script/format.sh --lint
```

Both full test modes passed 1,372 tests in 62 suites. No GUI pass was run; the
C4 worktree contract permits headless gates only.

## Related code, ADRs, and phases

- [`GeminiCLIAdapter.swift`](../../Sources/RafuApp/Conductor/Adapters/GeminiCLIAdapter.swift)
- [`CursorAdapter.swift`](../../Sources/RafuApp/Conductor/Adapters/CursorAdapter.swift)
- [`GeminiCLIAdapterTests.swift`](../../Tests/RafuAppTests/Conductor/GeminiCLIAdapterTests.swift)
- [`CursorAdapterTests.swift`](../../Tests/RafuAppTests/Conductor/CursorAdapterTests.swift)
- [`C4-adapters-gemini-cursor.md`](../plans/phases/conductor/C4-adapters-gemini-cursor.md)
- [`Ensemble execution plan`](../plans/phases/conductor/README.md)
- [ADR 0018](../decisions/0018-conductor-external-agent-orchestration.md)
- [`conductor-pty-spawn-and-child-environment.md`](conductor-pty-spawn-and-child-environment.md)
- [Gemini CLI automation](https://geminicli.com/docs/cli/tutorials/automation/)
- [Gemini CLI transition notice](https://geminicli.com/docs/)
- [Gemini CLI configuration](https://geminicli.com/docs/reference/configuration/)
- [Gemini CLI model selection](https://geminicli.com/docs/cli/model/)
- [Cursor CLI parameters](https://docs.cursor.com/en/cli/reference/parameters)
- [Cursor CLI output formats](https://docs.cursor.com/en/cli/reference/output-format)
