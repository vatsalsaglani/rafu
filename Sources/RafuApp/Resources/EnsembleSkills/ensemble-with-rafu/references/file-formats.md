# Ensemble plan files

Write plan files before the first `run --plan-gate`. Rafu reads ordinary
Markdown under the repository:

```text
.rafu/
  agents/
  workflows/
  runs/
```

Rafu does not create agent or workflow files merely because a workspace was
opened.

## Agent files

An agent file lives at `.rafu/agents/<name>.md` and has a small frontmatter
contract:

```text
---
name: <display name>
provider: <claudeCode|codex|openCode|cline|kimi|geminiCLI|cursor>
model: <optional model id>
autonomy: <readOnly|worktreeWrite>
handoffArtifact: <one file name>
---
<prompt body>
```

`provider` is required. Missing or unparseable `autonomy` becomes
`readOnly`, never broader access. Unknown scalar metadata and foreign list
metadata are ignored. The body is the role prompt.

Worked file — `.rafu/agents/auth-auditor.md`:

```markdown
---
name: Auth auditor
provider: codex
autonomy: readOnly
handoffArtifact: finding.md
---
Inspect the route named in the prompt. Write exactly one finding, including
evidence and a confidence judgment, to $RAFU_HANDOFF/finding.md.
```

## Workflow files

A workflow frontmatter `steps:` list uses:

```text
- <agentName> [<- artifact[, artifact…]] [[gate]]
```

`[gate]` is literal. Do not write `!gate`. Inputs after `<-` name artifacts
from earlier steps.

Worked file — `.rafu/workflows/audit-and-verify.md`:

```markdown
---
name: Audit and verify
steps:
  - auth-auditor
  - skeptic <- finding.md [gate]
---
Audit one route, then challenge the finding before the user decides whether
the workflow may continue.
```

Authored step numbers are 1-based: the first step is step 1 and its first
attempt lives under an evidence directory such as
`steps/01-auth-auditor-a1/`. Retry attempts use `-a2`, `-a3`, and so on;
earlier evidence is never mutated. The `artifact` CLI verb is the separate
wire boundary and takes a zero-based step index.

Each child receives:

- `RAFU_RUN_DIR`: that run's `.rafu/runs/<id>/` root.
- `RAFU_HANDOFF`: the current step's handoff directory.

Write exactly the one `handoffArtifact` promised by the agent file to
`RAFU_HANDOFF`. Never widen the write target or edit prior attempt evidence.
