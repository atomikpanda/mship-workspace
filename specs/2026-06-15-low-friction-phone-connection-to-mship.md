---
id: low-friction-phone-connection-to-mship
title: Low-friction phone connection to mship serve via self-hosted sish relay
status: approved
created_at: '2026-06-15T23:45:46.606326Z'
updated_at: '2026-06-16T00:02:48.503172Z'
affected_repos:
- mothership
- ground-control
acceptance_criteria:
- id: ac1
  text: A self-hostable sish relay deployment (Docker Compose + scripts/relay-bootstrap.sh)
    brings up a relay with auto-TLS and an SSH-key allowlist; docs cover the single
    wildcard DNS record and adding a client key
  verdict: approved
- id: ac2
  text: '`mship serve --relay [<host>]` starts the local API and supervises an `ssh
    -R` reverse tunnel to the relay, reconnecting on drop and tearing down cleanly
    on exit'
  verdict: approved
- id: ac3
  text: Relay host is configurable via mothership.yaml (`relay.host`) and/or the --relay
    flag; the per-workspace subdomain is the slugified workspace name, yielding a
    stable https://<workspace>.<relay-domain> URL
  verdict: approved
- id: ac4
  text: mship uses a dedicated SSH key (auto-generated at ~/.mothership/relay_ed25519
    if absent) for the tunnel, and surfaces the public-key line to add to the relay
    allowlist (serve output or `mship relay setup`)
  verdict: approved
- id: ac5
  text: When --relay is used, an API bearer token is required; mship auto-generates
    and persists a per-workspace token if MSHIP_SERVE_TOKEN is unset
  verdict: approved
- id: ac6
  text: '`mship serve --relay` (and/or `mship pair`) prints a terminal QR code encoding
    {url, token, workspace} as a groundcontrol://add deep link'
  verdict: approved
- id: ac7
  text: "The Ground Control app adds Settings \u2192 Add \u2192 Scan QR (and accepts\
    \ the same deep link via paste/intent) that parses the payload and adds the connection\
    \ with no manual typing"
  verdict: approved
- id: ac8
  text: Tunnel supervision, token/key management, relay config, and pairing live in
    reusable core modules callable independently of the interactive `mship serve`
    command (so a future daemon can reuse them); a connection paired once stays valid
    regardless of which process maintains the tunnel
  verdict: approved
- id: ac9
  text: Unit tests cover QR/deep-link payload encode+decode (CLI and app), token generation/persistence,
    subdomain slugging, ssh tunnel argument construction, and relay config parsing
  verdict: approved
open_questions: []
non_goals:
- "Any mship-operated or mship-hosted relay \u2014 strictly bring-your-own; no dependency\
  \ on a vendor cloud"
- VPN / Tailscale as a required path (it remains a fine manual option, but the relay
  must work without it)
- "Other tunnel backends (frp, chisel, etc.) \u2014 sish is the standard for v1; a\
  \ pluggable backend abstraction is a possible future, not now"
- "A Terraform/IaC module \u2014 Docker Compose + bash bootstrap is the v1 packaging;\
  \ IaC is a later option"
- "iOS app QR scanning \u2014 Android-first (matches the C-series); iOS follows"
- "Token rotation/expiry, multi-tenant/multi-user relays, and audit logging \u2014\
  \ future hardening"
- "Automatic relay provisioning from mship \u2014 the user hosts the relay with the\
  \ kit; mship only configures the client + emits pairing"
- "A background serve daemon / auto-serve for mship sessions (auto-start tunnels for\
  \ active workspaces, systemd/launchd, reboot persistence) \u2014 out of scope for\
  \ THIS spec, but the design deliberately keeps tunnel supervision, token/key management,\
  \ and pairing as reusable core so a future daemon builds on it without re-pairing\
  \ or redesign"
risks:
- "SSH reverse-tunnel reliability \u2014 drops/reconnects must be handled (mitigate:\
  \ ServerAliveInterval + supervise/restart loop; reuse mship background-service supervision)"
- "Security: the relay exposes a public HTTPS surface \u2014 defense is the bearer\
  \ token (required when relaying) + SSH-key allowlist + auto-TLS; the QR encodes\
  \ a secret, so the terminal/screen is sensitive"
- "Operational burden of self-hosting sish (DNS wildcard + TLS + a VPS) \u2014 mitigate\
  \ with turnkey Docker Compose + bootstrap script + docs; the one-time DNS/TLS step\
  \ is the main user effort"
- ssh client version/behavior differences across dev machines (ubiquitous but edge
  cases exist; document minimums)
- Deep-link/QR handling on Android (intent filter + scanner permission) adds app surface
  and must be robust against malformed payloads
- "Factoring for a future daemon must not over-engineer v1 \u2014 keep the reusable\
  \ core minimal (a thin tunnel/token/pairing module) rather than building daemon\
  \ scaffolding now"
task_slug: null
work_item_id: wi-20260702110439-0702aa82
---
## Problem

Connecting the Ground Control phone app to an `mship serve` instance is a hassle today: `mship serve` binds to 127.0.0.1, so to reach it from a phone you must expose it on a routable host, invent and export `MSHIP_SERVE_TOKEN`, discover the machine's address, then hand-type the URL + paste the secret into the app — once per workspace/machine. There is no discovery or pairing. Requiring a VPN (e.g. Tailscale) is one fix but adds a dependency and isn't acceptable as the only path. The goal is reachable-from-anywhere connection with no VPN, no inbound firewall holes, no cloud lock-in, and near-zero typing on the phone.

## User story

As a Mothership operator, I want to stand up my own small relay once and then connect my phone to any of my `mship serve` workspaces by scanning a QR code, so that I can review and dispatch specs from anywhere without a VPN, port-forwarding, or copy-pasting URLs and tokens.

## Approach

Reverse-tunnel via a SELF-HOSTED relay (no VPN, BYO infra, no lock-in to mship-operated cloud). Standardize on **sish** (an SSH-based, self-hostable tunnel): `mship serve` keeps binding to loopback, and mship opens + supervises an `ssh -R <subdomain>:80:localhost:47100` reverse tunnel (outbound only) to the user's relay; sish maps it to a stable `https://<workspace>.<relay-domain>` with auto-TLS. The phone only ever speaks HTTPS to the relay. Client side needs no extra binary (ssh is ubiquitous).

The feature is three cohesive parts (one design, phased plan) spanning two repos:

**A. Relay hosting kit (mothership ops artifacts).** Turnkey self-host of sish: a Docker Compose file (sish + auto-TLS via Let's Encrypt) + a `scripts/relay-bootstrap.sh` that installs Docker and brings it up on a fresh VPS, plus docs (one wildcard `*.relay-domain` DNS A record; SSH-key allowlist). Everything BYO — nothing points at mship infra. A Terraform/IaC module is an explicit later option, not v1.

**B. mship client integration (mothership).** `mship serve --relay [<host>]` starts the local API and supervises the ssh reverse tunnel (reconnect on drop via ServerAliveInterval + a supervise loop, reusing mship's background-service supervision; clean teardown on Ctrl-C). Relay host comes from `mothership.yaml` (`relay.host`) or the flag. Subdomain = slugified workspace name. mship uses a dedicated SSH key (auto-generated at `~/.mothership/relay_ed25519` if absent); `mship relay setup` / serve output surfaces the public-key line to add to the relay allowlist once.

**Auth model — two independent layers:** (1) tunnel layer = SSH-key allowlist on the relay (who may expose a serve); (2) API layer = the existing `MSHIP_SERVE_TOKEN` bearer, end-to-end (who may call the API). Because relaying makes the URL public, a token is REQUIRED when `--relay` is used; mship auto-generates and persists a per-workspace token if none is set, so the user never invents/exports a secret.

**C. Pairing UX (mothership CLI + ground-control app).** `mship serve --relay` (and/or `mship pair`) prints a terminal QR code encoding `{url, token, workspace}` as a `groundcontrol://add?...` deep link. The Android app gains Settings → Add → Scan QR (and accepts the same deep link via paste/intent), which parses the payload and adds the multi-workspace connection with no typing. This builds directly on the existing C1/C2 multi-connection Settings + DataStore.

**Forward-compatibility (daemon).** Tunnel supervision, per-workspace token/key management, relay config, and pairing are factored as reusable core primitives — not locked inside the interactive `mship serve` foreground command — so a future background daemon that auto-serves active mship sessions/workspaces (systemd/launchd, auto-start tunnels) can drive the same plumbing without redesign. A paired connection is durable: a connection is keyed by its stable per-workspace URL + token, so whoever brings the tunnel up (interactive `mship serve` now, or a daemon later), the phone's saved connection is unchanged and requires NO re-pairing. The daemon itself is out of scope here; this spec only commits to the seam that keeps it cheap to add.
