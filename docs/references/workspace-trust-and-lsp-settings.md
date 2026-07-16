# Workspace trust and language server settings

- **Applies to:** language server trust approval/decline, Settings UI for persisted trust, revocation workflow, server lifecycle
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-15

## Rule or observed behavior

### Trust persistence and revocation UI

`WorkspaceTrustStore` persists user trust approvals (workspace path → server ID mappings) via atomic file writes. The Language Servers pane in Settings now displays a "Workspace Trust" section listing current approvals from `WorkspaceTrustStore.load()`, with a Revoke button per row.

**Revoke semantics:** Clicking Revoke:
1. Calls `WorkspaceTrustStore.revoke(serverID:forWorkspaceKey:)` — an atomic write mirroring the `approve` path
2. Removes the row from the Settings UI immediately
3. Takes effect on the **next workspace reopen**; a running server remains running until it naturally idles or the workspace is closed and reopened

The "next reopen" deferral is a deliberate design choice: live teardown (killing a running server on revoke) would require real-time coordination between Settings and the LanguageIntelligenceCoordinator. The cost-benefit is poor (users rarely revoke mid-session), so teardown is deferred and documented in the UI footer ("Revocation takes effect on the next workspace reopen").

### Trust flow end-to-end

1. **Install trigger:** User installs a language server from the Language Servers catalog (Settings pane)
2. **Trust gate:** `InstalledServerResolver.resolve` gates server startup on `isTrusted` check against `WorkspaceTrustStore`
3. **Untrusted server:** If untrusted, `LanguageIntelligenceCoordinator` publishes `pendingTrustRequest` (a `TrustRequest` observable)
4. **Trust prompt:** `WorkspaceWindowView` presents `LanguageServerTrustPromptView` as a `.sheet(item:)` driven by this state
5. **User decision:** Sheet actions call `approveTrust(_:)` or `declineTrust(_:)`, updating the store or clearing the pending request
6. **Approval effect:** On next server session startup (user re-invokes Go to Definition after approval), the resolver sees `isTrusted=true` and permits the server to start
7. **Decline effect:** Decline clears the prompt; the user must explicitly approve in Settings to enable the server later

No automatic navigation retry after approval — the user re-invokes the action (Go to Definition, etc.) after trusting.

### VoiceOver accessibility

Trust prompt sheet has standard VoiceOver labels and keyboard paths (Escape dismisses as decline; standard default/cancel key equivalents). Settings table rows include per-server name, trust status, and Revoke button labels for screen-reader navigation.

## Why it matters

Workspace trust bridges the gap between "user explicitly chose to install this server" (catalog install) and "server is allowed to run" (resolver gate). Persistent storage allows trust decisions to survive app restarts. Revocation via Settings gives users control over their trust decisions without requiring code deletion or manual trust-store file editing.

The deferred-teardown design avoids complex live coordination (Settings ↔ LanguageIntelligenceCoordinator ↔ running server process) and acknowledges that mid-session revocation is rare in practice. The deferral is visible to the user (documented footer) rather than silent.

## Reproduction or evidence

**Trust flow (coordinator-tested):**
- Unit tests in lane-2 verify that `approveTrust` + resolver-snapshot rebuild makes `session(forLanguageID:)` succeed (existing trust-flow tests)
- UI test (manual): install a server → trust prompt appears → approve → Re-invoke navigation → server starts
- Revoke test (manual): Settings → Workspace Trust → Revoke → close/reopen workspace → server NOT auto-started (unless retrusted)

**Verification:**
```bash
swift build
swift test
./script/format.sh --fix && ./script/format.sh --lint
./script/build_and_run.sh --verify
```

All 485 tests passing. Manual verification owed: live GUI/VoiceOver pass for the trust prompt sheet and Settings revocation UI.

## Known design choices

1. **No live teardown on revoke:** Running servers are not killed when trust is revoked mid-session. Rationale: rare use case, high coordination cost, and no user-facing data loss (just continued server availability until natural idle/reopen). Documented in the UI ("takes effect on next workspace reopen").

2. **No automatic retry after approval:** After approving a server, the pending request is cleared but not automatically retried. Rationale: keeps the trust flow simple (one user action per decision), and re-invoking the navigation/definition action is a natural UX (user sees approval, then tries again). The denied path also follows this pattern (deny clears the prompt; Settings Approve is the explicit retry path).

## Related code, ADRs, and phases

- `Sources/RafuApp/Settings/LanguageServersSettingsSection.swift` → "Workspace Trust" section, revoke UI
- `Sources/RafuApp/LanguageIntelligence/Trust/LanguageServerTrustPromptView.swift` (mounted in WorkspaceWindowView)
- `Sources/RafuApp/LanguageIntelligence/Trust/WorkspaceTrustStore.swift` (persistence, approve/revoke/load)
- `Sources/RafuApp/LanguageIntelligence/LanguageIntelligenceCoordinator.swift` (pendingTrustRequest, approveTrust/declineTrust)
- `Sources/RafuApp/Views/WorkspaceWindowView.swift` (trust prompt sheet mounting)
- `docs/decisions/0005-language-intelligence-and-lsp.md` (ADR trust section)
- `docs/plans/phases/post-merge-validation-fixes.md` (Batch D, finding 7)
