---
id: overnight-fan-out-orchestrator
title: 'Overnight fan-out orchestrator: run N approved specs as cloud-worker routines,
  collect coordinated PRs'
status: draft
created_at: '2026-07-22T13:18:22.830149Z'
updated_at: '2026-07-22T14:09:40.168836Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: '[ac1] `mship overnight <spec-id...>` (name TBD-in-review) takes one or more
    APPROVED spec ids and, for each, runs a per-run dispatch: it refuses a spec that
    is not approved, and a `--dry-run` prints what it WOULD fire (per run: repos,
    push_branch, payload size) without minting tokens or firing.'
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac2
  text: '[ac2] For each run it derives {repos = the spec''s affected_repos, push_branch
    = a deterministic run branch, handoff = the spec''s acceptance-criteria handoff}
    and mints a per-run relay token scoped to {repos, push_branch} via a `RunTokenMinter`
    seam (v1: shells `mship relay issue-run-token`); a repo outside the enrollment''s
    grant ceiling fails that run with a clear error (and does not fire it).'
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac3
  text: '[ac3] It assembles a single freeform /fire text payload (<= the ~64KB cap,
    asserted) carrying the handoff + per-run token + relay egress URL + repos + push_branch,
    and refuses to fire if the payload exceeds the cap.'
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac4
  text: '[ac4] The `WorkerBackend` seam is defined (`dispatch(run) -> handle`) with
    `ClaudeRoutineBackend` as v1''s only driver; the orchestrator core (derive ->
    mint -> assemble -> dispatch -> collect) does not depend on the driver, so another
    backend is a drop-in.'
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac5
  text: '[ac5] `ClaudeRoutineBackend.dispatch` POSTs to the routine /fire endpoint
    with the routine bearer token + `anthropic-beta: experimental-cc-routine-2026-04-01`
    + `anthropic-version` headers and `{"text": <payload>}`, returns the claude_code_session_id/url,
    and on HTTP 429 backs off honoring Retry-After and retries (bounded); all HTTP
    is behind an injectable client so tests use httpx.MockTransport (no live API).'
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac6
  text: "[ac6] After firing, the orchestrator collects PRs from GitHub (the source\
    \ of truth, since /fire is not pollable): it polls for the PR whose head branch\
    \ is the run's push_branch in each of the run's repos, with a bounded timeout,\
    \ and REPORTS per run the collected PR URL(s) plus which runs are still pending\
    \ / timed out \u2014 never claiming a success it cannot see."
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac7
  text: '[ac7] Fan-out is bounded + safe: parallelism is capped, each fire is logged,
    the command never fires from a blanket ''all'' (an explicit spec list is required),
    and 429s are backed off; the end-of-run report summarizes fired / collected /
    pending across all specs.'
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac8
  text: '[ac8] The whole flow is tested end-to-end with NO live services: a fake `RunTokenMinter`,
    a mock /fire endpoint + mock GitHub via httpx.MockTransport, asserting the derived
    run params, the payload contents + size guard, the fire request shape (URL/headers/body),
    the 429 backoff, and the PR-collection reporting (found + pending + timed-out).'
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac9
  text: '[ac9] Docs: the operator''s one-time routine setup (create the routine in
    the Claude Code UI: prompt to parse the routine-fire-payload, environment installs
    mship + bakes the git insteadOf + allows the relay host; then copy the trig_id
    + bearer token into mship config), the RunTokenMinter co-location assumption +
    the relay-mint-endpoint follow-up, and the fact that nothing auto-merges.'
  verdict: unreviewed
  evidence: []
  comment: null
open_questions: []
non_goals:
- "Creating/configuring the Claude Code Routine \u2014 routines have NO create API;\
  \ the operator pre-creates the one 'mship cloud worker' routine by hand (its prompt\
  \ to parse the routine-fire-payload, its environment to install mship + bake the\
  \ git insteadOf + allow the relay host) and hands the orchestrator the trig_id +\
  \ bearer token. Out of scope to automate."
- "Live polling of a routine's session status/output \u2014 the /fire API is fire-and-forget\
  \ with no poll endpoint; the orchestrator uses GitHub as the source of truth, not\
  \ the routine."
- "Auto-merging any PR \u2014 the flow is review-gated end to end; the orchestrator\
  \ only opens/collects, never merges."
- "A second worker backend (container/`claude -p`, or others) \u2014 the WorkerBackend\
  \ seam is built; only ClaudeRoutineBackend ships in v1."
- "A relay admin mint-endpoint \u2014 v1's RunTokenMinter shells the existing `mship\
  \ relay issue-run-token`; a network mint-endpoint is a later drop-in behind the\
  \ same seam."
- "Deploying the live relay (Caddy egress block + App creds on the relay host) \u2014\
  \ a separate operator ops step this slice depends on to RUN for real, but not to\
  \ build/merge/test."
risks:
- 'The orchestrator must mint a per-run token the RELAY will honor, and the relay''s
  run-token store lives on the relay host. v1 assumes the orchestrator can reach that
  store (co-located, or a filesystem/SSH path) via the RunTokenMinter seam. If the
  operator runs mship somewhere the relay store isn''t reachable, minting won''t work
  until a relay mint-endpoint is added. Mitigation: seam + flagged decision; the endpoint
  is a clean follow-up.'
- 'Routines are a research preview (experimental-cc-routine-2026-04-01) with breaking-change
  risk, and the fire concurrency/hourly cap is undocumented (only a daily cap is).
  Mitigation: isolate the API behind ClaudeRoutineBackend, honor 429 + Retry-After
  with backoff, and bound fan-out parallelism conservatively; a driver swap is a seam
  change, not a rewrite.'
- 'No routine poll means PR collection is a GitHub timing heuristic: a slow worker
  may not have opened its PR before the collection timeout. Mitigation: report pending/timed-out
  runs explicitly (never claim success it can''t see); the run is still discoverable
  later by its push_branch. No silent truncation.'
- 'The freeform text payload is the only per-fire channel and is capped (~64KB) +
  delivered to the worker as UNTRUSTED. A spec handoff that is too large won''t fit.
  Mitigation: send a compact handoff (ACs + problem + repos/branch/token), not the
  whole spec history; assert the payload size before firing.'
- 'Firing N workers spends real Anthropic usage against the operator''s account. Mitigation:
  the command takes an explicit spec list (never a blanket ''all''), logs each fire,
  and honors the routine''s daily cap via 429 handling; a dry-run mode shows what
  WOULD fire.'
task_slug: null
work_item_id: null
clarification_reason: we don't want to add any new subcommands to mship and we aren't
  using Claude API keys but rather want it to be scheduled using the existing agent
  doing the scheduling itself via the mailbox event or similar
prose_verdicts: {}
---
## Problem

The overnight cloud-worker arc has its two lower layers shipped: the attach-at-relay auth spine (a worker pushes its run branch through the relay, credential attached + enforced at egress) and the worker-PR egress leg (a worker opens its PR through the relay, default-deny enforced). What is still missing is the top layer — the thing that turns 'run these N approved specs overnight' into actual work: nothing today mints the per-run tokens, launches the N disposable workers, and gathers the resulting PRs. Without it, the operator would have to hand-mint a token and hand-fire a routine per spec. This slice adds the fan-out orchestrator that does it: given N approved specs, it dispatches one disposable cloud worker per spec (via the Claude Code Routines /fire driver) and reports back the coordinated PRs by morning.

## User story

As the operator, I want to point mship at N approved specs and have it fan them out to isolated cloud workers overnight — each worker implementing one spec, pushing its run branch, and opening its PR through the relay — and then see the resulting PRs collected in one place, so that I wake up to review-ready cross-repo PRs without having to launch or babysit anything.

## Approach

A new orchestrator command (`mship overnight <spec-id...>`, or from a saved set) that, for each approved spec, runs a per-run dispatch and then collects the PRs. The worker backend is a SEAM (a `WorkerBackend` interface: `dispatch(run) -> handle`) with v1's only driver being `ClaudeRoutineBackend` — so a container/`claude -p` driver or others slot in later with zero orchestrator change.

Per-spec dispatch (per run):
1. Derive the run: repos = the spec's affected_repos; push_branch = a deterministic run branch (e.g. feat/<spec-slug>); a spec handoff (the acceptance criteria + instructions, reusing the existing `mship spec dispatch` handoff text).
2. Mint a per-run relay token scoped to {repos, push_branch} within the enrollment's grant ceiling — behind a `RunTokenMinter` seam. v1's minter shells `mship relay issue-run-token` (Slice 1) writing to the relay's run-token store (co-located / filesystem-reachable relay host — see the flagged decision); a relay admin mint-endpoint is a documented drop-in later.
3. Assemble the /fire text payload: a single freeform string (<= ~64KB) carrying the spec handoff + the per-run token + the relay egress URL + repos + push_branch, in a structure the pre-created routine's prompt knows how to parse (it treats the routine-fire-payload as untrusted data and acts on it deliberately).
4. Fire the routine: `ClaudeRoutineBackend.dispatch` POSTs to https://api.anthropic.com/v1/claude_code/routines/{trig_id}/fire with the routine bearer token + the `anthropic-beta: experimental-cc-routine-2026-04-01` + `anthropic-version` headers and `{"text": <payload>}`; on 429 it backs off + retries (Retry-After). It returns the claude_code_session_id/url (fire is fire-and-forget; there is NO poll API).

PR collection (no routine polling exists, so GitHub is the source of truth): since the worker opens its own PR through the relay (Slice 2a), the orchestrator polls GitHub for the PR whose head is the run's push_branch across the run's repos, with a bounded timeout; it reports, per run, the collected PR URL(s) + which runs are still pending / timed out. Config it needs, all one-time: the routine trig_id + bearer token, the relay egress URL + enrollment id, and the GitHub read access it already has. The whole flow is testable end-to-end against a MOCK /fire endpoint + mock GitHub (httpx.MockTransport) and a fake minter — no live routine, relay, or GitHub in tests.

## Architecture

New (mothership): an orchestrator module (e.g. core/overnight/*) with pure pieces — `derive_run(spec) -> Run{repos, push_branch, handoff}`, `assemble_payload(run, token, relay_url) -> str` (+ size guard), a `RunTokenMinter` protocol (v1 `CliRunTokenMinter` shelling `mship relay issue-run-token`), a `WorkerBackend` protocol (`dispatch(run) -> Handle`) with `ClaudeRoutineBackend` (httpx POST to /fire, injectable client, 429 backoff), and a `collect_prs(runs, gh_client, timeout) -> Report` (poll GitHub by head=push_branch across repos). A thin `mship overnight` CLI wires config (routine trig_id + bearer token, relay egress URL + enrollment id) -> runs the pipeline -> prints the report. Reuses: `mship spec dispatch`'s handoff text for the payload; the spec store for approved-status + affected_repos; existing gh read helpers for collection. The pipeline is a per-item flow (derive -> mint -> assemble -> dispatch, then collect) so a failing run reports its own error without sinking the batch.

## Testing

Pure/unit: `derive_run` (repos from affected_repos, deterministic push_branch, handoff present); `assemble_payload` (contains handoff+token+relay+repos+branch; over-cap raises); `RunTokenMinter` fake (records the {repos, push_branch} it was asked for; a repo outside the ceiling raises). Backend: `ClaudeRoutineBackend.dispatch` against httpx.MockTransport — asserts POST URL /routines/{id}/fire, the bearer + beta + version headers, body {text}, returns the session id; a 429 then 200 exercises the Retry-After backoff. Collection: `collect_prs` against a mock GitHub returning a PR for one run's push_branch and nothing for another — the report shows one collected + one pending/timed-out. CLI: `mship overnight` refuses a non-approved spec; `--dry-run` fires nothing; the batch report summarizes fired/collected/pending. No live routine, relay, or GitHub — every boundary (minter, /fire, GitHub) is injected/mocked.
