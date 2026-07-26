---
name: advise-implement
description: >
  Analyze a non-trivial engineering task with the read-only advisor, implement
  it with the implementor, and perform a final review.
disable-model-invocation: true
argument-hint: "<engineering task>"
---

Execute this task using the Advisor–Implementor workflow:

$ARGUMENTS

Follow this exact sequence:

1. Send the complete task to the `advisor` agent.
2. Wait for a detailed implementation brief.
3. Check that the brief:
   - addresses the full request;
   - references actual repository files;
   - includes risks, tests, and definition of done.
4. Send the original task and full advisor brief to the `implementor` agent.
5. Ask the implementor to make the changes and run verification. The
   implementor runs the **parallel** suite only, and its final sequence must
   end with that run immediately before committing — format, lint, and build
   all come first, and nothing may touch a file afterwards.
6. Inspect the resulting git diff and test outcomes.
7. Send the completed diff and verification summary back to the `advisor` for
   a final read-only review. The advisor owns the **serial** suite — the mode
   CI runs — and adds a parallel run only when the change touched
   concurrency. It triages each failure by re-running that test alone before
   reporting it.
8. If the advisor identifies a concrete defect, send only those actionable
   findings back to the implementor. Do not forward failures the advisor
   classified as scheduler starvation, and route failures in
   integration-owned test files to yourself, not the implementor.
   Stop after two advisor↔implementor rounds; a third means escalating to
   the user rather than looping.
9. Send the implementor's report, your verification results, and any durable
   nuances or decisions to the `documentor` agent to update
   docs/references/, docs/decisions/, and the active phase document per the
   AGENTS.md standing learning rule. Review its diff.
10. Return the final implementation summary, verification results,
    deviations, documentation updates, and unresolved concerns.

Do not allow the advisor or documentor to edit implementation files.
Do not claim that tests passed unless their commands were actually run.
Do not commit or push unless the user explicitly requests it.