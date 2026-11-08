# Remote image consent and the host trust list

- Applies to: `Sources/RafuApp/Canvas/RemoteImages/**`,
  `Sources/RafuApp/Settings/ImageTrustSettingsSection.swift`,
  `Sources/RafuApp/Resources/PublicSuffix/`, and the `Image` component of
  generated views ([ADR 0036](../decisions/0036-generated-views-on-the-ensemble-board.md)).
- Last verified: Swift 6.4.2, macOS 27, 2026-11-08. Foundation IDNA behaviour
  verified on macOS 27 (`bücher.example` becomes `xn--bcher-kva.example`).

## Rule or observed behavior

### Decision table

`RemoteImageDecision.evaluate(host, mode, patterns, ensemble, ensembleConsented)`:

| Global mode | Host on the trust list | Host not on the list |
|---|---|---|
| Off | deny ("Images from the web are off in Settings.") | deny |
| Ask (default) | allow, grant = the pattern | Ensemble consented: allow, grant = the Ensemble; else ask (the card offers "Allow…") |
| Always | allow, grant = the pattern | allow, grant = global |

Before the table, `RemoteImageFetchPolicy.classify` rejects the syntactic cases.
Nothing is fetched until a decision is allow, not even a HEAD request. A grant is
`pattern(text)`, `ensemble(id)` or `global`; every cached image carries it.

### HostPattern grammar

A trust-list entry is an exact host, or one leading `*.` wildcard on a parent
domain. Labels are lowercase letters, digits and hyphens, 1 to 63 bytes, no label
starts or ends with a hyphen, 253 bytes at most. No regex, path, port, scheme,
userinfo, IP address or `localhost`. A wildcard whose base is a public suffix
(`*.com`, `*.co.uk`, `*.github.io`) is refused with the reason shown under the
Add field. A wildcard covers any depth below its base and never the base itself.

`parentOffer(for:)` gives the wildcard the consent card offers: `*.` plus the
registrable domain, or nothing when the host is the registrable domain or a
public suffix. `githubusercontent.com` is a public suffix in the PSL private
section. So `raw.githubusercontent.com` is already registrable: the card offers
only that exact host, and `*.githubusercontent.com` is refused (test:
`HostPatternTests`). `example.com` offers nothing.

### IDNA and its traps

Foundation does the IDNA step; Rafu has no IDNA code. Traps the normaliser
rejects: percent-escapes (the URL is read with `host(percentEncoded: false)`, so
an escape is decoded before checking), `_` in a label, an empty label, spaces,
and numeric forms that a URL loader may read as an address: `127.1`, a bare
integer, and `0x7f.1`. A real top-level domain is never all digits and never
starts with `0x`.

### Public Suffix List

`Resources/PublicSuffix/public_suffix_list.dat`, downloaded 2026-11-08, version
`2026-11-06_09-01-47_UTC`, 338,546 bytes, MPL-2.0 (the header of the file keeps
the licence). It is read lazily, once, off the main actor. Parse time measured in
a Release build: 12 to 21 ms. Both the ICANN and the PRIVATE sections count.
`Bundle.module` is main-actor isolated under the app's default isolation, so read
the resource URL in a main-actor context, then parse off it.

### Trust file

`image-trust.json` in the app's Application Support folder (separate for Rafu
Lightning and the release app), written atomically with mode 0600. Format:
`{"version": 1, "entries": [{pattern, addedAt, source}]}`, `source` is `confirm`
or `settings`. At most 200 entries and 256 KiB. Invalid entries and duplicates are
skipped and counted for the Settings footer. A file that cannot be parsed is
renamed to `image-trust.invalid.json` (quarantine), never deleted or overwritten.
No agent tool reads or writes it. The Settings session keeps an undo stack of 20.

### Per-Ensemble consent

`CanvasDocument.permissions.remoteImages` (allowed, grantedAt, `grantedBy ==
"user"`). Written only from the consent card, as one undo step. It is not part of
a `.rafuensemble` file, so a received board starts without consent. Known limit:
Undo of a consent grant does not bump the provider's `revision`, so an image may
stay shown until the next redraw (cosmetic).

### Revocation

Removing a pattern, revoking an Ensemble's consent, or setting the global mode to
Off drops the cached images whose grant matches, across every open window, and
bumps the providers' `revision` so `Image` shows the placeholder again. Off drops
everything.

### Loader limits

Ephemeral `URLSession`; no cookies, credentials or cache; no `Referer`; fixed
User-Agent. Request timeout 8 s, whole transfer 15 s. `https`, port 443 only, no
userinfo. At most 2 redirects, each re-classified and re-authorised (an Ensemble
grant never covers a redirect to another host). The resolved addresses are
checked with `getaddrinfo`: loopback, RFC 1918, link-local, CGNAT 100.64/10,
multicast, documentation and reserved ranges, IPv6 unique-local and link-local,
and addresses embedded in NAT64, 6to4 and IPv4-mapped forms are refused; a host
with any non-public answer is refused. 2 MB encoded cap, 64 Mpx pixel check
before decode, thumbnail decode at the card's pixel size, first frame of a GIF,
type found by sniffing the first 12 bytes (PNG, JPEG, GIF, WebP; no SVG). 4
loads at once per Ensemble, 20 different images per card, 8 MB decoded cache
per Ensemble, 64 remembered failures.

Accepted risk: Rafu resolves the name to check it, then `URLSession` resolves
again to connect (a DNS time-of-check window). It is accepted and documented in
ADR 0036.

### Test technique

The loader tests route an in-process `URLProtocol` stub by host name, so no real
network or loopback server is needed, and a test can assert that no request is
made before consent.

## Why it matters

An image URL in a view written by an agent is a request from the user's Mac to a
host the agent chose. The three controls keep that explicit and revocable, and the
address checks keep it from reaching the local network.

## Reproduction or evidence

`Tests/RafuAppTests/RemoteImages/` (host pattern, PSL, trust store, decision,
fetch policy, loader, cache, revocation, Settings). Test counts for wave 3 were
not part of the handoff.

## Verification

- `swift test --filter RemoteImage`, `--filter HostPattern`, `--filter PublicSuffix`
- `./script/test.sh` and `./script/test.sh --no-parallel`
- Manual (Rafu Lightning only): placeholder, consent card, load, Settings list,
  revoke in two open Ensembles, `*.com` refused, Full Keyboard Access, VoiceOver.

## Related code, ADRs, and phases

- `HostPattern.swift`, `PublicSuffixList.swift`, `ImageTrustStore.swift`,
  `RemoteImageDecision.swift`, `RemoteImageFetchPolicy.swift`,
  `RemoteImageLoader.swift`, `RemoteImageCache.swift`,
  `RemoteImageRevocation.swift`, `RemoteImageConsentCard.swift`
- [ADR 0036](../decisions/0036-generated-views-on-the-ensemble-board.md)
- `Sources/RafuApp/Resources/PublicSuffix/README.md` (licence and refresh steps)
- Phase: [`../plans/phases/ensemble-canvas.md`](../plans/phases/ensemble-canvas.md)
