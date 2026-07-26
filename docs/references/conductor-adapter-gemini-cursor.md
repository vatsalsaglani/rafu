# Gemini CLI and Cursor CLI Ensemble adapters

- **Applies to:** C4 binary discovery, capability probes, delegated-auth
  classification, model choices, and invocation construction for Gemini CLI
  and Cursor Agent CLI
- **Last verified:** Gemini CLI was absent in the 2026-07-24 C4 pass; its
  newly discoverable `0.52.0` install was version-checked, but not runtime
  probed, on 2026-07-27. Cursor Agent CLI was re-probed locally as an
  authenticated `2026.07.23-e383d2b` install on 2026-07-27; its help, auth,
  model catalog, write, plan, resume, and continue surfaces were exercised in
  scratch repositories.

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

### Gemini CLI: adapter runtime locally unverified

`gemini` was not installed anywhere visible during C4 implementation. It is
now discoverable at
`/Users/vatsalsaglani/.nvm/versions/node/v22.0.0/bin/gemini`, and
`--version` reports `0.52.0`. This Cursor-focused re-verification did not probe
Gemini's help, authentication lookup, model availability, autonomy mappings,
or an actual headless run, so all adapter-runtime claims below retain their
document-derived status.

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

### Cursor Agent CLI: authenticated runtime verified; adapter has drifted

The current installed executable is
`/Users/vatsalsaglani/.local/bin/cursor-agent`, version
`2026.07.23-e383d2b`. `/Users/vatsalsaglani/.local/bin/agent` resolves to the
same versioned binary, but `cursor-agent` remains a backward-compatible alias
and is still the name Rafu discovers. Local help exits zero and now advertises:

```text
-p, --print                  ... non-interactive use ... access to all tools
--output-format <format>     text | json | stream-json
--mode <mode>                plan or ask (both read-only)
--plan                       shorthand for --mode=plan
--resume [chatId]
--continue
--model <model>              parameterized models accept bracket overrides
--list-models
-f, --force / --yolo
--trust
--workspace <path-or-name>
status|whoami
models
create-chat
ls
resume
```

The original C4 `worktreeWrite` argv shape remains valid:

```text
-p --output-format json --force --model <model> <prompt>
```

It completed in a new scratch Git repository with `--model auto`, produced a
single JSON result object, exited zero, and created exactly the requested
three-byte `OK\n` file. The same argv with Rafu's default `--model gpt-5`
failed before agent execution because that id is no longer present for the
local account.

The current CLI also has a strict plan surface. A fresh non-interactive
workspace first rejected the run with "Workspace Trust Required"; adding
`--trust` allowed this mapping to complete without changing the repository:

```text
-p --output-format json --trust --mode plan --model <model> <prompt>
```

`--trust` acknowledges the selected workspace; `--mode plan` supplies the
read-only enforcement. Do not substitute `--force` in this mapping.

Rafu's adapter predates both changes. It still:

- declares only `worktreeWrite` supported and sends `readOnly` to
  `/usr/bin/false`;
- reports `supportsModelDiscovery == false` even though `models` and
  `--list-models` now work headlessly; and
- curates `gpt-5`, `sonnet-4`, and `sonnet-4-thinking`, defaulting an empty
  model to `gpt-5`.

On 2026-07-27, `models` returned 190 catalog rows and included `auto`, but no
exact `gpt-5`. A listed named model was also rejected for this account's
entitlement while `auto` succeeded. Model-catalog visibility is therefore not
proof that the account can select a model. Dynamic discovery should improve
choices, but run-time entitlement errors still need to remain visible.

`cursor-agent status` now reports a logged-in account and exits zero, including
when launched with only `HOME` and Rafu's curated `PATH`. This verifies the
delegated-login boundary without forwarding `CURSOR_API_KEY`. The adapter's
negative-text-before-exit-zero classification remains necessary for signed-out
hosts.

The JSON success result contains `session_id`. An explicit
`--resume <chatId>` run and a subsequent `--continue` run both completed with
the same id. Rafu does not parse or persist that vendor session metadata, by
the file-handoff decision in ADR 0018.

The checked-in version/help/logged-out fixtures remain recorded evidence from
the older 2025.09.18 install. The positive `Logged in` fixture was synthetic
when written, although its classification is now corroborated by the current
local status output. Updating fixtures and adapter behavior is source work,
not part of this documentation-only re-verification.

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
/Users/vatsalsaglani/.nvm/versions/node/v22.0.0/bin/gemini

$ /Users/vatsalsaglani/.nvm/versions/node/v22.0.0/bin/gemini --version </dev/null
0.52.0
# exit 0

$ command -v cursor-agent
/Users/vatsalsaglani/.local/bin/cursor-agent

$ /Users/vatsalsaglani/.local/bin/cursor-agent --version </dev/null
2026.07.23-e383d2b
# exit 0

$ /Users/vatsalsaglani/.local/bin/cursor-agent --help </dev/null
# included --print, --output-format, plan/ask modes, resume/continue, model
# listing and parameters, force, trust, workspace, login/status, and sessions
# exit 0

$ /Users/vatsalsaglani/.local/bin/cursor-agent status </dev/null
# reported a logged-in account; account identifier omitted here
# exit 0

$ /Users/vatsalsaglani/.local/bin/cursor-agent models </dev/null
# 190 catalog rows; included auto, did not include exact gpt-5
# exit 0
```

No credential file or environment value was opened or printed during these
probes. The status command also succeeded under an `env -i` launch containing
only `HOME` and Rafu's curated `PATH`.

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
/bin/test -f "$gemini_probe_dir/rafu-auto-edit-probe.txt"
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

### Cursor account and runtime verification commands

The local help/status/model evidence can be reproduced without exposing a
token:

```bash
/Users/vatsalsaglani/.local/bin/cursor-agent --version </dev/null
/Users/vatsalsaglani/.local/bin/cursor-agent --help </dev/null
/Users/vatsalsaglani/.local/bin/cursor-agent status </dev/null
printf 'status-exit=%s\n' "$?"
/Users/vatsalsaglani/.local/bin/cursor-agent models </dev/null
```

Verify write and plan autonomy only in scratch repositories:

```bash
cursor_probe_dir="$(mktemp -d /tmp/rafu-cursor-c4.XXXXXX)"
cd "$cursor_probe_dir"
/usr/bin/git init -q
/Users/vatsalsaglani/.local/bin/cursor-agent \
  -p \
  --output-format json \
  --force \
  --model auto \
  "Create rafu-cursor-probe.txt containing exactly OK followed by one newline." \
  </dev/null
/bin/test -f "$cursor_probe_dir/rafu-cursor-probe.txt"

cursor_plan_dir="$(mktemp -d /tmp/rafu-cursor-plan.XXXXXX)"
cd "$cursor_plan_dir"
/usr/bin/git init -q
/Users/vatsalsaglani/.local/bin/cursor-agent \
  -p \
  --output-format json \
  --trust \
  --mode plan \
  --model auto \
  "Plan how to create should-not-exist.txt. Do not edit files." </dev/null
/bin/test ! -e "$cursor_plan_dir/should-not-exist.txt"
```

Both commands were verified on 2026-07-27. Retain the scratch directories
until their output, file contents, and Git status have been reviewed.

Session continuity was also verified using the `session_id` from the plan
result:

```bash
cursor-agent -p --output-format json --trust --mode ask --model auto \
  --resume '<session-id>' "Return exactly RESUME_OK and do not use tools." \
  </dev/null
cursor-agent -p --output-format json --trust --mode ask --model auto \
  --continue "Return exactly CONTINUE_OK and do not use tools." </dev/null
```

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
- [Cursor CLI model-listing release note](https://cursor.com/changelog/cli-jan-08-2026)
- [Cursor CLI plan/ask-mode release note](https://cursor.com/changelog/cli-jan-16-2026)
