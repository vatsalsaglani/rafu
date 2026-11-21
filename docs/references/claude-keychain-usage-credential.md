# Claude Code Keychain credential for exact usage

- **Applies to:** `UsageOAuthConnector.productionClaudeKeychainCredential()` and
  `UsageClaudeKeychainReadResult` (`Sources/RafuApp/Usage/UsageStores.swift`),
  the Settings texts in `UsageConnectionIssueText`
  (`Sources/RafuApp/Settings/UsageSettingsTab.swift`), and the signing step of
  `script/build_and_run.sh`.
- **Last verified:** Swift 6.4.2, macOS 27.2 (Darwin 27.2.0), 2026-11-21. The
  installed release app, v0.1.24-beta, was inspected with `codesign`. The CI
  build and a real Keychain prompt on a fixed release were NOT run; see
  "Owed checks".

## Observation

A user of the released app saw "Connection failed: credential access was
denied." under Settings, Usage, Claude. They chose "Always Allow" on the
Keychain prompt a second time and it still failed. Rafu Lightning worked.

## Where the credential is

- Keychain item: generic password, service `Claude Code-credentials`, in the
  login keychain. It is local (not synchronizable). Claude Code writes it with
  `security add-generic-password -U`.
- Content: JSON with the object `claudeAiOauth`. Rafu needs only
  `accessToken` and `expiresAt` from it (`UsageExternalCredentialParser.claude`).
  The item is about 4.8 KB; Rafu refuses more than 16 KiB.
- Never print the value. Check only that it exists and which keys it has:
  `security find-generic-password -s "Claude Code-credentials"` (attributes
  only, no `-w`).

## Status mapping (changed 2026-11-21)

Before, every `SecItemCopyMatching` status other than success and
`errSecItemNotFound` became "denied", so a signing problem looked like a
refusal by the user. Now `UsageClaudeKeychainReadResult.classify(status:)`
maps:

| Status | Result | Meaning |
|---|---|---|
| 0 | success | decode the data |
| -25300 | `.unavailable` | no item |
| -128 (`errSecUserCanceled`), -25293 (`errSecAuthFailed`) | `.denied` | the person denied or cancelled |
| anything else (for example -25308, -34018, -67xxx) | `.keychainError(status)` | not the person's choice; Settings shows the number |

Settings text for a denial: "you denied Keychain access. Connect again and
choose Allow." For any other status: "the Keychain returned error N. If you
installed a new Rafu version, quit and reopen it, then connect again." The
background refresh (`refreshClaudeKeychainCredential`) stops for good only on
`.denied`; a `.keychainError` retries after `keychainRefreshInterval` (15
minutes). The log line records the status number only (`Logger`, category
`usage`, level notice): never the item, the query, or the token.

The query no longer sets `kSecAttrSynchronizable = kSecAttrSynchronizableAny`.
That value also searches the data-protection keychain, which an app without
keychain entitlements may not be allowed to query (-34018). The item is a
local login-keychain item, so the default (non-synchronizable) search is
enough. This is a second suspect; it was not proven alone to be a cause.

## The invalid release signature

Most likely cause of the failure on the release app: its code signature was
invalid, so the Keychain could not bind an "Always Allow" grant to it.

```sh
codesign --verify --deep --strict --verbose=2 /Applications/Rafu.app
# code has no resources but signature indicates they must be present
codesign -dvvv /Applications/Rafu.app 2>&1 | grep -E 'Identifier|Info.plist|Sealed|CDHash'
# Identifier=RafuApp-<hash>   Info.plist=not bound   Sealed Resources=none
codesign -d -r- /Applications/Rafu.app
# designated => cdhash H"..."   (no bundle identifier)
```

Cause: the release workflow's toolchain emits flat SwiftPM resource bundles.
The script copied them to the `.app` root, where `codesign` cannot seal them
("unsealed contents present in the bundle root"), and the signing call ended in
`|| true`. Rafu Lightning, built on Swift 6.4, kept them in `Contents/Resources`
and had a valid sealed signature. A toy bundle shows the failure and that a
symlink at the root does not help (see
[`build-and-run.md`](build-and-run.md), "The release bundle must verify").

## Why each ad-hoc build asks again

An ad-hoc signature has no team or certificate. Its designated requirement is
the code directory hash (`cdhash`), which changes on every build. The Keychain
ties an "Always Allow" grant to the designated requirement, so a new release
is a new app to the Keychain and the prompt returns once. Only a stable signing
identity (a Developer ID certificate, in the distribution phase) removes this.
Quitting and reopening after an update is still the first thing to try.

## Not changed

- The trust model: Rafu reads the item itself through `SecItemCopyMatching`
  only after the person taps Connect (and for the later re-read). It does not
  run `/usr/bin/security`. That route would avoid the prompt but moves the
  grant to a system tool, which was rejected.
- The Codex credential path and Rafu's own Keychain items.

## Owed checks

1. CI: the Release workflow must pass the new `codesign --verify --deep
   --strict` step, and the unzipped `Rafu.app` must list only `Contents` at its
   root.
2. By hand, on the CI-built app: Settings, Usage, Claude, Connect, choose Allow
   (it should end at Connected). Choose Deny: the "you denied" text. Any other
   failure now shows a number; record it here if it appears.

## Verification commands

```sh
./script/test.sh --filter ClaudeOAuth
./script/test.sh --filter UsageSettingsMessage
RAFU_APP_NAME="Rafu Lightning" ./script/build_and_run.sh --stage   # non-launching
```

## Related

`Sources/RafuApp/Usage/UsageStores.swift`, `Sources/RafuApp/Support/RafuResourceBundle.swift`,
`script/build_and_run.sh`, [`usage-rings-and-pace.md`](usage-rings-and-pace.md),
[`test-keychain-isolation.md`](test-keychain-isolation.md).
