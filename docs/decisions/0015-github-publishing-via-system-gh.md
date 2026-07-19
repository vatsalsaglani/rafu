# ADR 0015: Publish to GitHub via the system `gh` CLI, never a bundled OAuth flow

- **Status:** Accepted
- **Date:** 2026-07-19

## Context

The user asked for a "publish this repository to GitHub" flow from the
Source Control surface: sign-in status, an account chip, and a "create
repository and push" action. Rafu has no existing GitHub integration and no
web-view/browser-redirect OAuth machinery, and AGENTS.md already commits
Rafu to using the system `/usr/bin/ssh` rather than building a second SSH
authentication authority. The same question applies to GitHub: build a
GitHub REST/OAuth client inside Rafu, or delegate to the user's own
GitHub CLI (`gh`) install.

## Decision

Rafu's GitHub integration shells out to the user's locally installed `gh`
CLI (`GitHubCLIService`/`GitHubCLILocator`) for exactly two operations:
resolving the authenticated account (`gh api user`) and publishing a
repository with no `origin` yet (`gh repo create … --push`), both from
explicit, user-confirmed UI (the status-bar account chip and
`GitHubPublishSheet`'s "Create & Push" action). Rafu never runs `gh auth
login` or any other interactive sign-in flow and never bundles a GitHub
OAuth client, browser-redirect flow, or personal-access-token field —
authentication is entirely `gh`'s responsibility, using whatever credential
storage `gh` already manages on the user's machine. See
[`github-cli-integration.md`](../references/github-cli-integration.md) for
the subprocess/locator/error-taxonomy implementation details.

## Alternatives considered

- **Bundle a GitHub OAuth device-code or browser-redirect flow.** Rejected:
  duplicates `gh`'s own credential storage and refresh logic inside Rafu,
  widens the attack surface (a second place a GitHub token could leak or be
  mis-stored), and requires either a `WKWebView` (a standing non-goal) or a
  local callback HTTP server for the redirect.
- **Build a GitHub REST client with a user-supplied personal access token
  field.** Rejected: puts token handling and scope selection on Rafu
  instead of `gh`, and a PAT field is easy to mis-store or over-scope
  compared to `gh`'s existing keychain-backed credential storage.
- **Require the user to run `gh repo create`/`git remote add` manually and
  only detect the result.** Rejected as the default: too much friction for
  a one-click "publish" action the user explicitly asked for; Rafu still
  falls back to the honest `.notInstalled`/`.notAuthenticated` errors that
  tell the user the exact terminal command when `gh` is missing or signed
  out.

## Consequences

- Rafu's GitHub feature surface stays small: two `gh` invocations, both
  argv-only and both behind explicit user confirmation. No new stored
  secret, no new Keychain item, no new network client.
- The feature is unavailable (with an honest error, not a silent failure)
  on any machine without `gh` installed and authenticated — this is an
  accepted tradeoff, parallel to how SSH workspace features assume the
  user's own OpenSSH configuration rather than Rafu shipping SSH key
  management.
- `GitHubCLIService` deliberately passes the **full** process environment to
  `gh` (unlike the hardened/overridden environment `GitCommandRunner` uses
  for `git`) because `gh` needs `HOME`/`GH_CONFIG_DIR`/`GH_TOKEN` to find
  its own auth state; this is documented as a one-off exception, not a
  general subprocess-environment policy change.
- `gh` stdout/stderr is never logged, mirroring the existing `git`
  no-diff/no-credential-logging discipline.

## Revisit trigger

Revisit if a future product goal needs GitHub access when `gh` is not
installed (e.g. a sandboxed/managed machine), or if GitHub deprecates a
`gh` subcommand Rafu depends on.

## Related plan, reference, and implementation paths

- Reference: [`github-cli-integration.md`](../references/github-cli-integration.md)
- `Sources/RafuApp/Services/GitHubCLIService.swift`
- `Sources/RafuApp/Models/GitHubAccountModel.swift`
- `Sources/RafuApp/Views/GitHubPublishSheet.swift`
- `Sources/RafuApp/Views/GitHubAccountStatusView.swift`
- `Tests/RafuAppTests/GitHubCLIParsingTests.swift`
