# Security policy

## Current support status

Rafu is pre-release and does not yet have a supported public version. Security work is still important because the design will handle source files, SSH authentication flows, Git hooks, local IPC, remote helpers, API credentials, and sensitive diffs.

## Reporting a vulnerability

Do not disclose a suspected vulnerability in a public issue. Use a private GitHub Security Advisory for the repository when available.

There is not yet a published backup security contact. A public release is blocked until the maintainer adds a concrete monitored private email or form here. Until then, do not publish vulnerability details when a private advisory is unavailable.

Never submit real SSH keys, passwords, API keys, `.env` contents, proprietary source, or unsanitized diffs. Replace them with purpose-built fixtures.

## Expected report content

- Affected commit or version
- The relevant trust boundary
- Reproduction steps using synthetic data
- Observed and expected behavior
- Likely impact
- Any known workaround

The project will acknowledge a private report, validate the issue, agree on disclosure timing, and add a regression test and durable security reference with the fix.
