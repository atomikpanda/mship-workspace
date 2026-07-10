---
id: non-relay-qr-pairing
title: 'Non-relay QR pairing: mship serve prints a scannable pairing QR for tailnet/LAN'
status: implemented
created_at: '2026-06-22T22:03:36.530481Z'
updated_at: '2026-06-22T22:52:14.883146Z'
affected_repos:
- mothership
- ground-control
acceptance_criteria:
- id: ac1
  text: "When `mship serve` runs non-relay with a bearer token set and a reachable\
    \ (non-loopback) advertised host, it prints both a `groundcontrol://add?url=http://<host>:<port>&token=<token>&workspace=<workspace>`\
    \ pair link and a scannable segno terminal QR, reusing build_pair_link \u2014\
    \ the same format the relay emits and the app already scans."
  verdict: unreviewed
- id: ac2
  text: 'Advertised-host resolution is a pure, unit-tested function: a concrete non-loopback
    --host is used as-is; 0.0.0.0/:: yields a best-effort detected primary LAN/tailnet
    IPv4 (used in the QR with a note to pin via --host); a loopback host yields none;
    when no reachable IP can be determined the QR is skipped with a hint to pass --host.'
  verdict: unreviewed
- id: ac3
  text: "No pair link or QR is printed when there is no token (loopback-only serve)\
    \ \u2014 existing non-relay output is otherwise unchanged, and the `--relay` path\
    \ (its https QR) is unchanged."
  verdict: unreviewed
- id: ac4
  text: When the http QR is printed, the serve output includes a one-line advisory
    clarifying the trust model (plain HTTP is fine on a trusted LAN or tailnet; use
    --relay for untrusted networks).
  verdict: unreviewed
- id: ac5
  text: "ground-control: a PairLinkTest case asserts that an `http://<ip>:<port>`\
    \ pair link parses to a WorkspaceConnection whose baseUrl is exactly that http\
    \ URL, with the token and workspace preserved \u2014 proving the existing scanner\
    \ pairs non-relay links with no functional app change."
  verdict: unreviewed
- id: ac6
  text: 'Tests: mothership pytest covers the host-resolution helper (concrete passthrough;
    loopback -> none; 0.0.0.0 -> detected-or-none) and the emit-or-not decision (token
    + reachable -> link; no token -> none) without running uvicorn; the ground-control
    http PairLink test passes; both suites are green.'
  verdict: unreviewed
open_questions: []
non_goals:
- "TLS / SSL / self-signed certs / certificate pinning \u2014 deferred to a separate\
  \ future spec. The secure-network story for now is: tailnet (WireGuard already encrypts\
  \ the http link) for secure-anywhere, and --relay (https) for public/untrusted;\
  \ self-signed + trust-on-first-use pinning (server cert gen/rotation + Android per-connection\
  \ pinning + reworking the shared HTTP client) is its own slice if untrusted-LAN-without-tailnet\
  \ becomes a real need."
- A CLI flag to toggle the QR (it is automatic, like the relay; no --qr/--no-qr in
  this slice)
- Multi-interface IP enumeration or choosing among several local IPs (one best-effort
  primary IP; the user pins with --host to be explicit)
- "Any FUNCTIONAL ground-control change \u2014 the existing scanner/PairLink.parse/Settings\
  \ already pair from this link; only a guard test is added"
- Changing the relay (`--relay`) path or its https pairing
risks:
- 0.0.0.0 primary-IP detection is best-effort and may pick the wrong interface on
  a multi-homed host; mitigated by the printed note and letting the user pin the address
  with --host.
- Plain HTTP means the bearer token and spec/task data travel in cleartext on the
  link; acceptable on a trusted LAN and confidential on a tailnet (WireGuard), but
  the advisory line must make the trust boundary explicit, and untrusted networks
  should use --relay.
- "The QR encodes a specific host:port; if the host's IP later changes, the printed\
  \ QR is stale \u2014 re-running `mship serve` prints a fresh one (no persistence\
  \ needed)."
task_slug: non-relay-qr-pairing
work_item_id: wi-20260702110439-983207c4
---
## Problem

Pairing a non-relay workspace to Ground Control is high-friction. `mship serve --relay` builds a `groundcontrol://add?url=&token=&workspace=` pair link via build_pair_link and prints it as a scannable terminal QR (segno), so relay users just point their phone at it. But plain `mship serve` on a tailnet IP or LAN — even with a token — only prints the bare URL, so non-relay users have to hand-type the URL and bearer token into Settings. The app already scans the relay's QR format; the gap is entirely that the non-relay serve path doesn't emit one.

## User story

As an operator running `mship serve` on my tailnet/LAN without the relay, I want it to print a scannable pairing QR like the relay does, so that I can pair Ground Control by scanning instead of typing a URL and token by hand.

## Approach

Mothership-only functional change (plus one ground-control guard test). In the non-relay serve path (src/mship/cli/serve.py, the branch after the loopback/auth gate, before uvicorn.run), when a bearer token is set AND the advertised host is reachable, build the same pair link the relay uses — build_pair_link(url=f"http://{adv}:{port}", token=token, workspace=config.workspace) — and print it plus a segno terminal QR, mirroring the relay path. Automatic (no new flag), matching the relay. Advertised-host resolution is the one nuance: a concrete --host (ip/hostname, non-loopback) is used as-is; 0.0.0.0/:: (bind-all) triggers a best-effort primary LAN/tailnet IPv4 detection (the standard UDP-socket getsockname trick — opens a UDP socket toward a public address and reads the local sockname; sends no packets) used in the QR with a printed note to pin it via --host; if no reachable IP can be determined, the QR is skipped with a hint to pass --host. No token (loopback-only serve) prints no QR (unchanged). The relay path is untouched. A one-line advisory accompanies the http QR clarifying the trust model (plain HTTP is fine on a trusted LAN or a tailnet, which is WireGuard-encrypted; use --relay for untrusted networks). On the app side NO functional change is needed: the Settings QR scanner (ZXing ScanContract/ScanOptions) and MainActivity deep-link both route the scanned string through PairLink.parse, which stores the url param verbatim as baseUrl (no https requirement) and normalizedBaseUrl accepts http://; we only add a PairLinkTest case locking in that an http link parses. Verification is unit tests only (no running uvicorn): the host-resolution and pair-link-emission logic live in pure helpers.

## Implementation notes

Mothership: the non-relay branch lives in src/mship/cli/serve.py (after the `token = os.environ.get("MSHIP_SERVE_TOKEN")` + loopback/auth gate, before `uvicorn.run`). build_pair_link is in mship.core.relay.pairing and segno is already a dependency (used by the relay path: `typer.echo(segno.make(link).terminal(compact=True))`). Add a pure helper (e.g. resolve_advertised_host(host) -> str | None) in a testable module — concrete non-loopback host -> itself; loopback -> None; unspecified-bind (0.0.0.0/::) -> primary IPv4 via the UDP-socket getsockname trick or None. The CLI glue stays thin: if token: adv = resolve_advertised_host(host); if adv: link = build_pair_link(f"http://{adv}:{port}", token, config.workspace); print link + QR + advisory; else print the --host hint. Tests assert resolve_advertised_host and the emission decision directly (uvicorn.run is never invoked in tests). Ground-control: append one case to tests PairLinkTest asserting an http://<ip>:<port> link round-trips (baseUrl verbatim http, token + workspace preserved); no functional source change — SettingsViewModel.addFromLink -> PairLink.parse and MainActivity.handleDeepLink already handle it, and PairLink.parse stores url verbatim with no https requirement.
