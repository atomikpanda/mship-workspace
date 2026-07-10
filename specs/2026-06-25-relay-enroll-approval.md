---
id: relay-enroll-approval
title: 'Relay enrollment with owner approval (v1): pending requests + CLI approve/deny
  + 30min TTL'
status: approved
created_at: '2026-06-25T21:09:10.309038Z'
updated_at: '2026-07-09T10:21:29.978462Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: '`mship relay enroll-server` serves `POST /enroll`: given a valid ssh public
    key + hostname it creates a pending request and returns its id, and the key is
    NOT added to the pubkeys allowlist by the request alone.'
  verdict: approved
- id: ac2
  text: '`POST /enroll` rejects a malformed / non-ssh public key, and enforces a cap
    on the number of simultaneously-pending requests.'
  verdict: approved
- id: ac3
  text: 'A pending request expires after a configurable TTL (default 30 minutes):
    once expired it is not listed, cannot be approved, and `GET /status/{id}` reports
    it as expired.'
  verdict: approved
- id: ac4
  text: '`mship relay requests` (on the relay host) lists the non-expired pending
    requests with id, hostname, and key fingerprint.'
  verdict: approved
- id: ac5
  text: '`mship relay approve <id>` writes the request''s public key into the pubkeys
    allowlist directory as one sanitized, unique file and marks the request approved
    (so `GET /status/{id}` then reports approved); it refuses an expired or unknown
    id.'
  verdict: approved
- id: ac6
  text: '`mship relay deny <id>` resolves the request to denied without writing to
    the allowlist; `GET /status/{id}` reports denied.'
  verdict: approved
- id: ac7
  text: "`mship relay enroll` on a new device ensures its relay key, submits the request,\
    \ and reports the outcome (approved / denied / expired / timeout) by polling status\
    \ \u2014 with no filesystem or SSH access to the relay host."
  verdict: unreviewed
- id: ac8
  text: "The hostname\u2192filename mapping is sanitized so an enroll request cannot\
    \ write outside the pubkeys directory (no path traversal) and cannot clobber an\
    \ unrelated existing key."
  verdict: unreviewed
- id: ac9
  text: Unit tests cover the pure cores (public-key validation, fingerprinting, TTL/expiry
    with an injectable clock, filename sanitization, request-store transitions and
    the pending cap); the FastAPI endpoints are covered by TestClient app tests; the
    requester poll loop is tested with an injected HTTP client.
  verdict: unreviewed
open_questions:
- id: q1
  text: "Request-store layout: separate pending/ and resolved/ dirs, or a single dir\
    \ with a status field? (Leaning: move pending/<id>.json \u2192 resolved/<id>.json\
    \ on approve/deny/expire, so /status can report outcomes and approve is atomic.)"
  answer: "pending/<id>.json moved to resolved/<id>.json (with a status field) on\
    \ approve/deny/expire \u2014 atomic temp-file+rename; /status reads both dirs."
- id: q2
  text: "How the enroll-server takes its pending-dir / pubkeys-dir / port / TTL \u2014\
    \ flags, env, or a relay config block? (Leaning: CLI flags with defaults mirroring\
    \ the docker/relay/ layout.)"
  answer: CLI flags (--pending-dir/--pubkeys-dir/--port/--ttl) with defaults mirroring
    docker/relay/ (pubkeys=./pubkeys, pending=./pending, ttl=30m).
- id: q3
  text: 'Ship a docker-compose sidecar for the enroll-server in v1, or is a documented
    `mship relay enroll-server` host process enough? (Leaning: host process + docs
    for v1; compose sidecar optional follow-up.)'
  answer: v1 = a documented mship-relay-enroll-server host process; a docker-compose
    sidecar is an optional follow-up.
- id: q4
  text: Rate-limit specifics (per-IP vs a global pending cap of N; exact numbers).
  answer: global cap on simultaneously-pending requests + a light per-IP throttle;
    exact numbers as constants.
non_goals:
- Phone / Ground Control approval surface (v2; v1 is CLI approve/deny on the relay
  host)
- Changing sish's auth model (still the per-key pubkeys/ allowlist)
- Shared-password tunnel auth, or a shared enroll secret/code (open requests + rate-limit
  + TTL instead; approval is the gate)
- TLS/cert management for the enroll-server (plain HTTP in v1; it can sit behind the
  relay's HTTPS later)
- Auto-approval / trust-on-first-use
- 'A revocation UI (revoking a device stays: delete its file from pubkeys/)'
- iOS / any client beyond the mship CLI
risks:
- "A public POST endpoint is a spam/DoS surface \u2014 mitigated by rate-limiting,\
  \ a cap on simultaneously-pending requests, and the 30-minute TTL sweeping stale\
  \ entries."
- Plain HTTP means the public key + hostname transit in cleartext; acceptable (the
  key is not secret and approval is the gate) but noted.
- Hostname-derived filenames must be sanitized to prevent path traversal and avoid
  clobbering an unrelated key in pubkeys/.
- "The enroll-server and the approve/deny CLI share a filesystem request store \u2014\
  \ create/approve/deny must be atomic (temp-file + rename) to avoid races."
- If the owner isn't running the enroll-server on the relay host, requests can't be
  made; this is an explicit deployment step.
task_slug: null
work_item_id: wi-20260702110439-ead73097
---
## Problem

Per-key relay enrollment requires getting a device's public key into the relay host's pubkeys/ allowlist, but a device that needs enrolling often can't reach the relay host's filesystem or admin SSH at all (different machine, no access). A bare shared-secret enroll endpoint would let anyone holding the secret enroll themselves. There is no way today for a device to *request* access and for the owner to explicitly approve or deny it.

## User story

As someone running mship serve --relay across machines I can't always cross-access, I want a new device to request relay access and me to explicitly approve or deny it, so that I can enroll a device without giving it filesystem/SSH access to the relay box and without letting anyone on the internet add themselves to the allowlist.

## Approach

Three pieces in the `mship relay` surface, on top of the existing sish per-key allowlist (no sish change). (1) `mship relay enroll-server` — a small FastAPI service run on the relay host beside sish: `POST /enroll {pubkey, hostname}` validates the public key and creates a PENDING request (a JSON record under a pending store) with an id, key fingerprint, and created_at; it NEVER writes to pubkeys/. `GET /status/{id}` reports pending | approved | denied | expired | unknown so a requester can poll. Requests are open (no shared secret — the approval is the security gate) but rate-limited and capped, and each pending request EXPIRES after a configurable TTL (default 30 minutes). Plain HTTP is acceptable: the payload is a non-secret public key and the boundary is approval. (2) Owner CLI, run on the relay host where the owner has access: `mship relay requests` lists non-expired pending requests (id, hostname, fingerprint, age); `mship relay approve <id>` writes the request's public key into pubkeys/<sanitized-hostname>.pub (a unique file) and resolves the request to approved — sish picks it up with no restart; `mship relay deny <id>` resolves to denied without touching the allowlist. Approve refuses an expired or unknown id. (3) Requester CLI on the new device: `mship relay enroll [--enroll-url | --relay-host]` ensures the local relay key exists, POSTs its public key + hostname, prints the request id and 'ask the relay owner to approve', then polls /status until approved (prints a clear 'you can now mship serve --relay'), denied, expired, or a local timeout — needing no filesystem or SSH access to the relay box. Expiry is enforced lazily (on list/approve/status) plus a cleanup sweep. Security model: a stranger's POST can only ever create a pending entry the owner can deny or ignore; nothing enters the allowlist without an explicit approve. This is v1 (CLI approve/deny on the relay host); surfacing the approve/deny to the phone (Ground Control) is v2.

## Architecture

Keep the security-critical logic pure and heavily tested. `core/relay/enroll.py`: `validate_pubkey(s)`, `fingerprint(pubkey)`, `sanitize_label(hostname)` (→ a safe pubkeys filename, traversal-proof), and `RequestStore(dir, ttl, clock)` with `create(pubkey, hostname) -> id`, `list_pending()`, `get(id) -> status`, `approve(id, pubkeys_dir)`, `deny(id)`, and lazy expiry via the injected clock + a `sweep()`. The store uses atomic temp-file+rename writes and moves pending→resolved with a status. `core/relay/enroll_app.py`: `build_enroll_app(store)` returns a FastAPI app exposing `POST /enroll` and `GET /status/{id}` (with the rate-limit/cap). `cli/relay.py` adds: `enroll-server` (launch uvicorn over build_enroll_app), `requests`/`approve`/`deny` (operate a RequestStore + pubkeys dir on the host), and `enroll` (requester: ensure_relay_key + relay_public_key, httpx POST, poll GET /status). The RequestStore + helpers are the unit-tested core; the endpoints and CLI are thin wrappers.

## Testing

pytest, no network. Unit: valid/invalid pubkey; fingerprint determinism; sanitize_label against `../`, spaces, unicode, empty, and collision with an existing file; RequestStore lifecycle (create→list→approve writes the pubkeys file and resolves to approved; deny resolves to denied; expiry after TTL via an injected clock makes it unlistable/unapprovable/status=expired; the pending cap is enforced). App-level: FastAPI TestClient for `POST /enroll` (valid → id; invalid key → 4xx; over-cap → 4xx) and `GET /status/{id}` transitions (pending→approved/denied/expired/unknown). Requester: the `enroll` poll loop tested with an injected fake HTTP client returning a status sequence. Injectable clock everywhere TTL matters.
