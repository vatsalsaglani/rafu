Project instructions live in AGENTS.md — read it first.

@AGENTS.md

Agent instruction live here - 

## Advisor–Implementor–Documentor workflow

For non-trivial code changes, use the following sequence:

1. Delegate repository analysis and planning to the `advisor` subagent.
2. Wait for its implementation brief.
3. Critically review the brief against the user's request.
4. Delegate implementation to the `implementor` subagent, including:
   - the original user request;
   - the advisor's complete implementation brief;
   - any corrections or constraints identified by the coordinator.
5. After implementation, review the resulting diff and verification results.
6. For high-risk changes, ask the advisor to perform a final read-only review
   of the implementation.
7. Delegate documentation to the documentor subagent, providing the implementor's report, the coordinator's verification results, and any durable decisions or nuances; it updates docs/references/, docs/decisions/, and the active phase document per the AGENTS.md standing learning rule.

A change is non-trivial when it affects multiple files, public behaviour,
architecture, persistence, authentication, concurrency, infrastructure,
security, migrations, or requires new tests.

For tiny and unambiguous changes, direct implementation is allowed.

The advisor must never edit implementation files.
The implementor must not begin until it has received the advisor brief.
The documentor must never edit implementation files and must not begin until implementation has been verified.

## Model routing for subagents

The coordinator chooses the model and effort by the size of the work:

| Work | Who does it |
|---|---|
| Guidance, planning, design ideas, final read-only review | `advisor` subagent on **Fable**. Always. It never writes code. |
| Work that touches multiple parts of the app (several subsystems, shared models, cross-cutting UI) | `implementor` on **Opus, medium effort** |
| Smaller tasks, docs, and test updates that change **more than 4** things (files, tests to run, or distinct edits) | `implementor` or `documentor` on **Sonnet, high effort** |
| Smaller tasks with **4 or fewer** things | The coordinator does it directly, quickly. No subagent. |

For a worktree fan-out, group the issues that share files or a subsystem into
one agent, and run independent groups in parallel worktrees. The coordinator
merges, runs both test modes on `main`, and owns shared indexes.


