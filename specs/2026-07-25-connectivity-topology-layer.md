---
id: connectivity-topology-layer
title: Connectivity topology + diagnosis layer
status: implemented
created_at: '2026-07-25T15:31:21.587033Z'
updated_at: '2026-07-25T17:07:13.229290Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: "`probe_topology()` returns a structured inventory covering serve (running/bind/mode),\
    \ relay (subdomain, reachability, pairing freshness), run-host roles (declared\
    \ vs mapped vs reachable, with the source of each effective value including env\
    \ overrides), GitHub auth model in effect, and egress proxy state \u2014 each\
    \ edge carrying a machine-readable status code and a human fix hint"
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac2
  text: '`mship net status` renders a human topology view on a TTY and emits the same
    structure as JSON when piped or given --json'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac3
  text: '`mship doctor` reports connectivity checks sourced from the same `probe_topology()`
    implementation, with no duplicated probe logic (grep-verifiable: probe calls exist
    in one module)'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac4
  text: 'Probing never mutates state and never raises: with serve down, the relay
    unreachable, and no run hosts mapped, `mship net status` still exits 0 and reports
    each edge''s status plus fix hint; every network probe is bounded by an explicit
    timeout'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac5
  text: '`GET /net/topology` on serve returns the same JSON behind the existing bearer
    and is rejected without it'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac6
  text: "The payload includes a schema version field, and is complete enough to render\
    \ a topology view from alone \u2014 a test asserts every field the console needs\
    \ is present in the endpoint response (no in-process-only data)"
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac7
  text: 'No secret material appears in any output: tokens, SSH keys, and GitHub App
    credentials are redacted or reduced to a boolean, verified by a test that asserts
    known secret values are absent from the serialized topology'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac8
  text: Fix hints exist for the documented failure modes currently in docs/remote-run.md's
    troubleshooting table (unknown role, ambiguous role, role unmapped on this machine,
    relay unreachable, remote not bootstrapped/503, stale token/401), each with a
    distinct status code and unit test
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac9
  text: Unit tests cover each status path with mocked probes (healthy, misconfigured,
    probe-failed) so the suite needs no live network
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
open_questions: []
non_goals:
- The serve-host console itself (separate spec, consumes GET /net/topology)
- "A relay-host admin surface \u2014 relay-owner operations (requests/approve/deny,\
  \ grant, issue-run-token) run on a different machine and are a later slice"
- 'Mutating any connectivity state: this layer only reports (no enrolling, approving,
  pairing, or token minting)'
- "Scoped serve tokens (#370) \u2014 tracked separately; this spec only avoids making\
  \ it worse by staying read-only"
- "A formally versioned/published public API with compatibility guarantees \u2014\
  \ the payload carries a version field so consumers can detect mismatch, but stability\
  \ commitments are out of scope here"
- 'Discovering other machines'' topology: there is no coordination server, so this
  reports THIS machine''s view plus its probed edges'
risks:
- "Probe latency: adding network probes to `doctor` could slow a previously-fast command\
  \ \u2014 mitigate with short per-probe timeouts and a way to skip network probes"
- "False negatives from local network conditions (NAT, captive DNS) could report a\
  \ healthy relay as unreachable \u2014 statuses must distinguish 'probe failed' from\
  \ 'definitely misconfigured'"
- "Secret leakage: a structured dump of connectivity state is exactly where a token\
  \ could accidentally be serialized \u2014 redaction needs an explicit test, not\
  \ just care"
- The env-var override paths (MSHIP_RUN_HOST_<ROLE>_URL/TOKEN) mean on-disk config
  is not the whole truth; the inventory must report effective values and their source
- "If the payload is not sufficient to render from alone, a future detached frontend\
  \ silently becomes impossible \u2014 the render-completeness requirement needs a\
  \ test, since the coupling would otherwise only surface much later"
task_slug: connectivity-topology-layer
work_item_id: wi-20260725155310-90560a37
clarification_reason: null
prose_verdicts: {}
---
## Problem

mship's connectivity layer has outgrown shell + config files. There are 11 `mship relay` subcommands (setup, enroll-server, requests, approve, deny, grant, issue-run-token, egress-server, enroll, whoami) plus `run-host add/list/remove`, `pair`, and two `serve` modes; their state is spread across at least eight locations on up to three machines: mothership.yaml (role names only), .mothership/run-hosts.yaml (role -> url+token), .mothership/serve-token, .mothership/relay-runtime.json, the relay host's pubkey allowlist and enroll-request store, the egress host's grants-store and run-tokens-store, and env overrides (MSHIP_RUN_HOST_<ROLE>_*, MSHIP_GH_BROKER_URL). `mship doctor` has 12 checks and none of them touch connectivity. The result: no command answers 'what is my topology and is it healthy?' — the operator has to hold the graph in their head and probe each edge by hand. Diagnosis knowledge that does exist lives in prose: docs/remote-run.md carries a nine-row symptom->fix troubleshooting table that no code consumes. This is the prerequisite for any management UI (serve-host console, later relay admin surface, possibly a separately-shipped frontend): without a queryable topology model each UI would reimplement probing, and without a stable payload a detached frontend cannot be built against it at all.

## User story

As an operator running serves, relays, run hosts, and cloud-worker egress, I want one command (and one endpoint) that reports my live connectivity topology with per-edge health and an actionable fix for each failure, so that I can see and debug the whole graph without reconstructing it from config files.

## Approach

One implementation, three thin callers. A new core module (e.g. core/topology.py) exposes `probe_topology()` returning a structured inventory + per-edge status: serve (running, bind address, mode local/relay), relay (subdomain, DNS/HTTP reachability, pairing freshness), run hosts (declared roles in mothership.yaml vs mapped in .mothership/run-hosts.yaml vs actually reachable, including env-var overrides), GitHub auth model in effect (App-backed / gh-token broker / raw env token / none), and egress proxy (configured, reachable). Every edge carries a machine-readable status code plus a human fix hint; the fix hints port docs/remote-run.md's troubleshooting table into code so diagnosis stops living only in prose. Callers: (1) `mship net status` — human topology view on a TTY, same structure as JSON when piped or with --json; (2) `mship doctor` gains a connectivity check group that calls the SAME function (no duplicated probe logic); (3) `GET /net/topology` on serve returns the same JSON behind the existing bearer. That endpoint is explicitly treated as the UI contract — it is what the serve-host console consumes today and what any separately-shipped frontend would consume later — so the payload carries a schema version field and is self-describing enough to render from alone, with no companion in-process data required. Probing is strictly read-only and bounded: every network probe has a timeout, and a broken environment is the expected input — failures become statuses with fix hints, never exceptions or non-zero exits, because the tool must work precisely when connectivity is broken. Secrets are never emitted: tokens, keys, and App credentials are redacted or reduced to a boolean 'configured', following the existing `run-host list` precedent.
