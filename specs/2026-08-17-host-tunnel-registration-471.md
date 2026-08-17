---
id: host-tunnel-registration-471
title: 'Tunnel registration: host reachable from the phone without an address (#471)'
status: needs_review
created_at: '2026-08-17T18:26:17.918415Z'
updated_at: '2026-08-17T18:26:54.547378Z'
affected_repos:
- mothership
- ground-control
acceptance_criteria:
- id: ac1
  text: "AC1 \u2014 A freshly provisioned VM appears in Ground Control with no address\
    \ on the phone. A daemon configured with relay: {host} and no prior enrollment\
    \ POSTs its key non-blockingly and re-posts on a bounded schedule shorter than\
    \ the enroll store's TTL (so an overnight provision is still approvable in the\
    \ morning), then registers as soon as it is approved; the host appears in GET\
    \ /hosts (first pending-approval, then online) and in GC's host list, with the\
    \ phone holding only the relay domain + fleet token. Repeat posts from one key\
    \ collapse to exactly one pending record. (Unit end-to-end minus rea"
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac2
  text: "AC2 \u2014 Killing the tunnel re-registers automatically. When the ssh -R\
    \ child exits, TunnelSupervisor respawns on capped-exponential backoff with no\
    \ retry ceiling and a clamped exponent (the shipped backoff_delay 2 restart_count\
    \ raises OverflowError at restart_count == 1024, ~17h at the 60s cap \u2014 reachable\
    \ only now that the owner is an immortal daemon), and a successful respawn triggers\
    \ exactly one additional registration (not one per tick). (Unit with FakeProc\
    \ + list clock, driven past 1024 restarts; real pkill = manual.)"
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac3
  text: "AC3 \u2014 Relay redeploy touches no host. docker compose up -d --force-recreate\
    \ sish drops every tunnel; each daemon respawns and re-registers unattended (with\
    \ jittered backoff, so a fleet does not retry in lockstep), and the host directory\
    \ survives an enroll-server restart (on-disk atomic store). The host subdomain\
    \ shape already satisfies tls_ask_allowed (core/relay/tls_ask.py:8 _SERVE_LABEL),\
    \ so no new port, container, DNS record, sish flag, compose change, or tls_ask\
    \ change is required \u2014 pinned by an assertion, not a comment. The one relay-config\
    \ delta is a single Caddy matcher on the existing "
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac4
  text: "AC4 \u2014 A cloned VM is detected and re-identified, never silently shadowing.\
    \ Three nets, ordered by the clone each actually catches: (a) host-local, before\
    \ the daemon ever dials \u2014 an identity record whose recorded machine fingerprint\
    \ differs from the running machine's re-mints host_id (recording cloned_from)\
    \ and rotates the relay keypair (old key moved aside, ensure_relay_key mints a\
    \ fresh one before the tunnel is built), so the clone lands on a different subdomain,\
    \ is not in pubkeys/, and enters awaiting-enrollment. This net only fires on a\
    \ re-imaged host. (b) on the wire, for the fingerprint-i"
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac5
  text: "AC5 \u2014 Multiple hosts are independently visible and addressable. Two\
    \ hosts (two home dirs) register independently, appear as two directory entries\
    \ with distinct subdomains and distinct credentials, and neither's staleness or\
    \ failure hides or degrades the other in GC. (Unit.)"
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac6
  text: "AC6 \u2014 #473 runner status rides this path, not a parallel one. The registration\
    \ payload, GET /hosts, GET /health and GET /workspaces all carry a runner block\
    \ assembled in exactly one function, sourced from the registry's already-existing\
    \ opaque WorkspaceEntry.runner passthrough (dropped today in host_app.py's /workspaces\
    \ projection). #471 always reports disabled/unknown; #473 fills idle|active|degraded\
    \ in the same field with no new transport. (Unit, contract/identity style.)"
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac7
  text: "AC7 \u2014 A tunnel outage does not terminate a healthy worker. The tunnel\
    \ loop shares no lifetime with the registry, control app, or host app: repeated\
    \ failing ticks and a sup.stop() leave them untouched, mshipd still exits 0 on\
    \ clean shutdown and the shutdown actually completes (a SIGTERM tears down the\
    \ tunnel loop, not just the uvicorn servers), tunnel failure never appears in\
    \ status.restart_blockers(), and current durable state is visible again after\
    \ reconnect (read on demand, never streamed). (Unit; \"a worker survives a 10-minute\
    \ real outage\" = manual.)"
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac8
  text: "AC8 \u2014 Auth requires no interactive entry at boot. Identity, secret,\
    \ relay key and tokens are all minted non-interactively (ssh-keygen -N \"\" precedent);\
    \ when the key is not yet approved the daemon reports awaiting-enrollment, keeps\
    \ its enroll request alive across the store TTL, and self-heals on approval. It\
    \ never prompts and never blocks on the 1800s polling loop. (Unit.)"
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac9
  text: "AC9 \u2014 The host's API bearer is short-lived and self-verified. No standing\
    \ credential authorizes traffic arriving over the relay. Relay-borne bearers carry\
    \ an expiry, are minted only through the refresh exchange at the host's own POST\
    \ /host/token (never proxied, never published live into the directory), and are\
    \ verified by the host that issued them; the phone persists the refresh credential\
    \ so a host reachable on LAN/tailnet stays usable while the relay is down. The\
    \ standing token survives as an internal sub-app credential and for direct non-relay\
    \ origins (loopback/LAN), so first-time LAN pairi"
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac10
  text: "AC10 \u2014 Clock skew on a long-lived VM does not break token validation.\
    \ The host is the only clock in the bearer loop, so phone\u2194host skew is irrelevant\
    \ by construction; the residual hazard \u2014 a wall-clock step on the VM \u2014\
    \ is absorbed by a monotonic anchor (epoch-tagged, so it survives a daemon restart)\
    \ plus a skew grace applied only when a discontinuity is actually detected. The\
    \ shipped verify_run_token's bare clock() >= expires_at has neither and is re-pointed\
    \ at the same helper. Cross-machine freshness decisions (last_seen, staleness,\
    \ challenge expiry) are stamped with the relay's clock, never "
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac11
  text: "AC11 \u2014 Network flap mid-run corrupts or duplicates nothing. Reconnect\
    \ performs no journal or registry writes and no replay: registration is idempotent\
    \ per host_id \u2014 it re-publishes the same refresh credential rather than minting\
    \ a new one \u2014 and carries only identity + capability metadata. N connect/disconnect\
    \ cycles leave ~/.mothership/daemon/ byte-identical (asserted over the directory\
    \ itself, not merely everything outside it) and produce exactly one directory\
    \ entry. (Unit.)"
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac12
  text: "AC12 \u2014 Tunnel state is first-class. mship daemon status reports state\
    \ / subdomain / public URL / restart count / last registration / last error as\
    \ structured JSON fields (via the global --json), not only inside lines; /health.capabilities.tunnel\
    \ is a real value; the literal \"tunnel: not configured (#471)\" assertion in\
    \ tests/core/daemon/test_status.py is replaced by per-state cases. GC distinguishes\
    \ the six ladder states plus directory-unreachable and stale. (Unit.)"
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac13
  text: "AC13 \u2014 Exactly one inbound path. No new port, container, DNS record,\
    \ relay service, or sish flag. Everything rides the existing ssh -R/sish transport\
    \ and the existing supervised enroll.<relay-domain> host process. The only edge\
    \ change is one additional matcher on that already-public site (@hosts { path\
    \ /hosts /hosts/ } with its own request-body cap), required because the site is\
    \ hardened to POST /enroll + GET /status/ with a respond \"not found\" 404 catch-all\
    \ \u2014 without it every new route 404s in production while every unit test passes\
    \ through TestClient. Pinned by a test asserting every route p"
  verdict: unreviewed
  evidence: []
  comment: null
open_questions: []
non_goals:
- '#473 runner scheduling and adapters: runner state rides this host identity/tunnel
  through a named passthrough seam, with zero runner code here'
- Closing sish's 'any enrolled key can claim any subdomain' hole - that is a sish
  redesign; what closes here is SILENT shadowing (contention is detected and surfaced,
  the loser is visible on the phone instead of vanishing)
- 'Replacing mship serve --relay: the per-workspace foreground relay path stays for
  desk/dev use and coexists with the host tunnel'
- New relay ports, containers, DNS records, sish flags, docker-compose or tls_ask
  changes (one Caddy matcher on the existing enroll site is the sole relay-config
  delta)
- Filesystem-watched host discovery, centralized fleet scheduling, and GC host-grouping
  UI beyond the state ladder
risks:
- 'Clone detection is defence-in-depth, not a guarantee: cp -a reproduces the machine
  fingerprint verbatim, so the host-local net misses it and the wire-side net must
  arbitrate by probing the incumbent (a fingerprint-keyed check would classify the
  clone as an idempotent re-registration and silently overwrite the incumbent)'
- TunnelSupervisor's shipped backoff (delay * 2 ** restart_count) raises OverflowError
  at restart_count 1024 (~17h at the 60s cap) - unreachable for a CLI process, reachable
  now that an immortal daemon owns it
- 'Signing/verification bytes must be byte-identical across ends: a golden-bytes test
  over a non-ASCII payload is required or the feature ships as ''every registration
  401s in production'' while unit tests pass in one interpreter'
- The Caddy enroll site's 404 catch-all would silently swallow every new /hosts route
  while all TestClient tests pass
- 'Clock skew on a long-lived VM must not render a host offline or hijackable: relay-side
  stamping plus an epoch-tagged monotonic anchor, with staleness derived from the
  register interval + max backoff so healthy hosts cannot flap'
- A fleet-wide relay redeploy can stampede reconnects without jitter
- Several ACs (real DNS/TLS, live force-recreate, real reboot/kill) are structurally
  uncloseable in CI on this box and are honest manual/VM checklist items
task_slug: null
work_item_id: null
clarification_reason: null
prose_verdicts: {}
---
## Problem

The phone cannot reach a dev VM's address and a dropped tunnel cannot be repaired from a phone. Today reachability is a per-WORKSPACE concern owned by a foreground process: mship serve --relay derives a per-workspace subdomain, holds a standing per-workspace bearer, and drives the tunnel from CLI threads that die with the process. The shipped daemon has no tunnel at all (control.py reports tunnel: False; status prints 'tunnel: not configured (#471)'). So N workspaces means N tunnels and N standing secrets, nothing maintains reachability when no mship serve runs (exactly the unattended-VM case), and the phone must be TOLD an address, leaving a freshly provisioned VM invisible. Underneath sits the harder identity problem: nothing identifies a host (device_id hashes a clonable key file), machine-id is copied verbatim by cp -a/snapshots, sish runs with bind-random-subdomains=false so any enrolled key may claim any subdomain, the only host credential is a standing plaintext bearer, and enrollment polls for a human for 1800s then expires the request.

## User story

As a phone-first operator, I want each provisioned host to dial out and register itself with my relay under a machine-bound identity it proves end-to-end, so that every VM appears in Ground Control with no address stored on the phone, survives tunnel drops and relay redeploys unattended, and a cloned VM can never silently shadow its source.

## Approach

The daemon owns ONE tunnel per host, maintained forever by its own supervised loop with capped, jittered, ceiling-free backoff. Identity: a minted host_id bound to a machine fingerprint plus a per-process instance_id; the daemon proves it end-to-end by signing a relay-issued nonce with the SAME ed25519 key that authenticates its ssh tunnel, verified against the same pubkeys/ allowlist sish authenticates against - so the relay never asserts identity on the daemon's behalf. The relay's enroll-server (already supervised, already owning an atomic on-disk store) gains a host directory binding host_id to (key fingerprint, machine fingerprint, instance_id, subdomain) and refuses a second LIVE claimant, arbitrating restart-vs-clone by probing the incumbent rather than trusting a fingerprint. Transport, trust root and service are all reused: no new port, container, DNS record, sish flag, or compose change - but exactly one Caddy matcher IS required, because the enroll site is hardened to POST /enroll + GET /status/* with a 404 catch-all that would swallow every new route. Ground Control stores a relay ACCOUNT, never a VM address: one deep link carries the relay domain plus a per-device fleet token; GET /hosts enumerates the fleet; each entry carries a refresh credential the phone exchanges at the host's own POST /host/token for a short-lived bearer, so no standing MSHIP_SERVE_TOKEN-shaped credential authorizes relay traffic and nothing is typed at boot. Tunnel state becomes structured data in daemon status and /health, and GC renders the full ladder plus two honest unknowns (directory-unreachable, stale) so a relay outage never mislabels a healthy host as offline.

## Implementation plan

Built via ultracode (6 readers, 2 opposed drafts, judge synthesis, 3 adversarial verifiers; 38 findings folded in incl. 6 blockers). Plan: docs/plans/2026-08-17-host-tunnel-registration-471.md - 11 TDD tasks. Every test uses injected proc_factory/clock/get/post/run_cmd seams: the repo has zero tests that bind a real port or sleep in real time, and #471 preserves that. Relay-box work is four one-time commands (tool reinstall + enroll-service restart, caddy force-recreate for the one new matcher, one fleet-token per phone, the existing approve per VM).
