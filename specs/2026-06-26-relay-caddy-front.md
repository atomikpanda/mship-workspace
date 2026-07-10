---
id: relay-caddy-front
title: 'Relay front: Caddy reverse proxy, on-demand TLS, enroll behind 443'
status: implemented
created_at: '2026-06-26T13:42:06.065707Z'
updated_at: '2026-06-29T22:17:42.166770Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: docker/relay/ gains a Caddy service that publishes 80/443 and is the only
    public web ingress; sish runs with --https=false on an internal HTTP port (:8080)
    and no longer publishes 80/443 (it still publishes 2222).
  verdict: unreviewed
- id: ac2
  text: Caddy host-routes enroll.<relay-domain> to the enroll-server on 127.0.0.1:47180
    and *.<relay-domain> to sish on :8080 with the original Host header preserved.
  verdict: unreviewed
- id: ac3
  text: TLS is Caddy on-demand gated by an ask endpoint backed by a pure predicate
    tls_ask_allowed(domain, relay_domain) that returns true only for enroll.<relay-domain>
    and <slug>-<6hex>.<relay-domain> serve subdomains and false for any other host
    (bare apex, foreign domains, lookalikes, traversal/whitespace); unit-tested as
    an allow/deny matrix.
  verdict: unreviewed
- id: ac4
  text: The enroll route is edge-hardened with a request-body size cap and a method/path
    allowlist (only POST /enroll and GET /status/*), so other methods or paths are
    rejected before reaching uvicorn.
  verdict: unreviewed
- id: ac5
  text: The enroll-server binds 127.0.0.1 only (no public port); a device reaches
    it solely via https://enroll.<relay-domain> through Caddy and port 47180 is not
    externally reachable.
  verdict: unreviewed
- id: ac6
  text: mship relay enroll accepts --relay-host (defaulting to the configured relay.host
    when present), derives the endpoint https://enroll.<relay-host>, and POSTs to
    /enroll over HTTPS; --enroll-url remains an optional explicit override; URL derivation
    and config defaulting are unit-tested.
  verdict: unreviewed
- id: ac7
  text: The full mothership suite is green; new unit tests cover the ask predicate
    and the enroll URL derivation, and the Caddyfile + compose changes plus the new
    device-facing https://enroll.<host> URL are documented in docs/relay-hosting.md.
  verdict: unreviewed
open_questions:
- id: q1
  text: 'Where the ask endpoint and predicate live: a new route on the enroll-server
    (simplest -- it is already the loopback FastAPI app behind Caddy) vs a tiny standalone
    service. Leaning: a route on the enroll app.'
  answer: 'yes'
- id: q2
  text: Whether to pre-warm the enroll.<relay> cert at deploy to avoid a first-hit
    502, or rely on the enroll CLI's clean error and the operator retrying.
  answer: 'yes'
- id: q3
  text: 'Stock caddy:latest for v1 (no rate-limit plugin) vs building a custom Caddy
    image now to include caddy-ratelimit. Leaning: stock for v1, rate-limit as a follow-up.'
  answer: 'yes'
non_goals:
- Changing the request->approve enrollment security model or RequestStore internals
  (unchanged).
- A custom Caddy image with the caddy-ratelimit plugin for true rate limiting (v1
  uses stock body-size cap + method allowlist; rate-limit is a follow-up).
- Wildcard TLS via DNS-01 (on-demand + ask was chosen; wildcard is documented as a
  drop-in alternative but not built).
- Moving sish off SSH 2222 or changing the reverse-tunnel mechanism that serve relies
  on.
- Any change to per-device subdomain hashing or serve tunnel behavior beyond routing
  it through Caddy.
- Adding authentication to the enroll endpoint (approval remains the gate; the endpoint
  stays open by design).
risks:
- 'Putting sish behind Caddy must preserve the Host header (sish muxes by Host); a
  misconfigured proxy would break every serve subdomain. Mitigate: explicit Host pass-through
  plus a smoke check that a known subdomain still routes to sish.'
- 'The on-demand ''ask'' endpoint is a hard dependency for cert issuance -- if it
  is down or wrong, no certs issue. Mitigate: serve it from an always-on loopback
  route and unit-test the allow/deny predicate exhaustively.'
- 'The ask predicate must not be exploitable to mint certs for arbitrary hosts (the
  very surface being closed); a too-loose regex reopens it. Mitigate: anchor the pattern
  to the exact relay domain and the serve subdomain shape, tested against lookalikes
  (enroll.<relay>.evil.com), the bare apex, and whitespace/traversal inputs.'
- Caddy on-demand ACME still has per-host latency on first hit, so enroll's first
  request may briefly 502 while the cert provisions. Acceptable (the enroll CLI surfaces
  connection errors cleanly and the operator retries), optionally pre-warm the enroll
  host at deploy.
- 'Loopback-only binding of the enroll-server must actually be 127.0.0.1 (not 0.0.0.0)
  or the firewall-hole closure is illusory. Mitigate: bind 127.0.0.1 explicitly.'
- 'The relay domain must agree between Caddy routing, the ask predicate, and what
  devices use; a mismatch silently denies certs/routes. Mitigate: a single source
  of the domain via the existing ${RELAY_DOMAIN}.'
task_slug: relay-caddy-front
work_item_id: wi-20260702110439-04deecd2
---
## Problem

The relay's device-enrollment endpoint (mship relay enroll-server) is exposed as a raw HTTP service on port 47180. That means a manual inbound firewall hole, plaintext transit, and a device-facing URL that includes the port. More broadly, sish terminates TLS itself with on-demand per-subdomain certs and will mint a cert for ANY requested hostname, and there is no edge layer in front of the public enroll POST surface to bound body size or methods. We want enrollment to live behind the relay's existing 443 over TLS, with no extra open port, edge hardening on the public surface, certs issued only for relay-owned hosts, and a device UX where the operator supplies only the relay host (no port, no full URL).

## User story

As someone enrolling a new device onto the relay, I want to run `mship relay enroll --relay-host <relay>` (no port, no full URL) and have the request travel over HTTPS through the relay's existing 443, so that I don't open a side port, the payload isn't sent in cleartext, and the public enroll endpoint is size- and method-guarded at the edge.

## Approach

Introduce a Caddy reverse proxy in docker/relay/ as the single public web ingress on 80/443. sish moves BEHIND Caddy: it stops terminating TLS (--https=false) and serves HTTP on an internal port (:8080), no longer publishing 80/443 to the host; it keeps publishing 2222 for incoming SSH reverse tunnels. Caddy host-routes: enroll.<relay-domain> -> the enroll-server (now bound to 127.0.0.1:47180, no public port), and *.<relay-domain> (every per-device serve subdomain) -> sish on :8080 with the original Host header preserved (sish muxes by Host). TLS is Caddy on-demand gated by an 'ask' endpoint: Caddy queries a small loopback HTTP endpoint with the requested domain and only provisions a cert when the host is relay-owned -- exactly enroll.<relay-domain> or the serve per-device pattern <slug>-<6hex>.<relay-domain> -- rejecting everything else, which closes sish's current mint-any-cert surface. The enroll route additionally gets stock-Caddy edge hardening: a request-body size cap and a method/path allowlist (only POST /enroll and GET /status/*). On the device side, mship relay enroll gains --relay-host (defaulting to the configured relay.host when present) and derives the endpoint https://enroll.<relay-host> itself; --enroll-url remains as an optional explicit override. The request->approve enrollment security model and the enroll-server / RequestStore internals are unchanged -- only the ingress and the device-facing UX change.

## Architecture

New files: docker/relay/Caddyfile (host routing, on-demand TLS + ask, enroll-route hardening) and a Caddy service in docker/relay/docker-compose.yml. Changed: the sish service in docker-compose.yml (--https=false, --http-address=:8080, stop publishing 80/443, keep 2222). New core: src/mship/core/relay/tls_ask.py exposing tls_ask_allowed(domain, relay_domain) -> bool -- the pure cert allowlist predicate -- reusing the serve subdomain shape established by device_subdomain in core/relay/tunnel.py. The enroll FastAPI app (core/relay/enroll_app.py) mounts a GET ask route (e.g. /tls-check?domain=) returning 200 when allowed and a forbidden status otherwise. Changed CLI: src/mship/cli/relay.py -- the enroll command (add --relay-host with derivation https://enroll.<host>, default from configured relay.host, keep --enroll-url as an optional override) and enroll-server (bind 127.0.0.1). Docs: docs/relay-hosting.md updated for the Caddy front and the new device-facing https://enroll.<host> URL.

## Testing

pytest, no network. Unit: tls_ask_allowed allow/deny matrix -- the enroll host, several valid serve subdomains (<slug>-<6hex>.<relay>), the bare apex, foreign domains, lookalikes (enroll.<relay>.evil.com), and whitespace/traversal inputs; enroll URL derivation from --relay-host and from a configured relay.host, plus --enroll-url override precedence. App-level: the ask route returns 200 for an allowed host and forbidden otherwise via FastAPI TestClient; the method/path allowlist behavior is asserted where enforced in-app. The Caddyfile and compose are configuration (not unit-tested) but documented and covered by a manual smoke step. The full mothership suite stays green.
