# Public Suffix List

`public_suffix_list.dat` is the Public Suffix List from
<https://publicsuffix.org/list/public_suffix_list.dat>, copied unchanged.

- Downloaded: 2026-11-08
- List version: `2026-11-06_09-01-47_UTC`, commit `94ec5df7273926560d91e77c002000ba1a53fec4`
- License: Mozilla Public License 2.0 (the header of the file says so; keep it)
- Size: 338,546 bytes (the full list, ICANN and PRIVATE sections)

Rafu reads it lazily for the image host trust list (Settings ▸ Ensemble ▸
Images from the web). To refresh it, download the file again from the URL
above, replace it unchanged, and update the date, version, commit, and size
here.

## Third-party notice

The Public Suffix List is a third-party data file, licensed under the Mozilla
Public License, version 2.0
(<https://mozilla.org/MPL/2.0/>). Rafu ships the file unmodified, so the MPL
licence header inside `public_suffix_list.dat` stays with it. The source is
<https://publicsuffix.org/list/public_suffix_list.dat>. Rafu's own code is not
covered by the MPL. The MediaRemote adapter's notice is the BSD-3
`Vendor/MediaRemoteAdapter/LICENSE`, which the app script stages as
`MediaRemoteAdapter-LICENSE`; this README is the matching notice for the list
(the directory is bundled whole by `Package.swift`).

## How Rafu reads it

`PublicSuffixList` (`Sources/RafuApp/Canvas/RemoteImages/PublicSuffixList.swift`)
parses the file once, off the main actor, when the image trust model loads.
Both the ICANN and the PRIVATE section count, so `github.io` is a public
suffix. Rules with Unicode labels are matched in punycode. The list decides
two things: a wildcard such as `*.com`, `*.co.uk` or `*.github.io` is never a
valid trust-list entry, and the consent card offers `*.` plus the registrable
domain of a host (`cdn.example.co.uk` offers `*.example.co.uk`).
`githubusercontent.com` is itself a public suffix in the PRIVATE section, so
`raw.githubusercontent.com` can only be trusted as that exact host.
Tests inject a tiny list through `PublicSuffixProviding`; one test reads this
file and checks it is a plausible size (100 KB to 400 KB).
