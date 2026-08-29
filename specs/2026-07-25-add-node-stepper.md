---
id: add-node-stepper
title: Guided add-a-node stepper
status: draft
created_at: '2026-07-25T22:55:06.188511Z'
updated_at: '2026-07-25T23:11:18.311404Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: '`mship relay enroll` records `{request id, enroll base url, hostname, requested_at}`
    in the gitignored state dir, and a test asserts no key material or token is written
    there'
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac2
  text: The console renders the add-a-node sequence with each step marked done / current
    / blocked / not-started, and only the current step shows a command
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac3
  text: "Step state is derived from the `GET /net/topology` payload for every step\
    \ it can cover (relay configured, serve running, role mapped, role reachable),\
    \ so the stepper and the edge list can never disagree \u2014 verified by a test\
    \ that flips an edge and asserts the step follows"
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac4
  text: 'The enrollment step reports the real answer from the relay: with a recorded
    request id the console polls the enroll-server''s public `GET /status/{rid}` and
    shows pending (with age) / approved / denied'
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac5
  text: 'Polling is timeout-bounded and never breaks the page: with the enroll host
    unreachable the step reports ''could not check'' and the rest of the console still
    renders, asserted by a test'
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac6
  text: An enrollment request older than a stated threshold is reported as likely
    lost, with the command to request again, rather than pending forever
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac7
  text: The pairing step renders a scannable QR for the pair link inline, generated
    locally with no external asset request
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac8
  text: "Edges are ordered by severity \u2014 fail, then warn, then absent, then ok\
    \ \u2014 with a test pinning the order for a mixed payload"
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac9
  text: The page auto-refreshes on a modest interval by full reload (not a JS fetch
    of the header-only topology endpoint), and shows how old the current view is so
    a stale tab is obvious
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac10
  text: The remaining `mship doctor` checks appear on the page behind a read-only
    endpoint that reuses `DoctorChecker`, with no duplicated check logic (grep-verifiable)
    and a test asserting no secret material in its payload
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac11
  text: "Every command the stepper renders survives `shlex` parsing with each substituted\
    \ value as one literal argument, and any placeholder the console cannot fill marks\
    \ the card as needing input \u2014 the guards the command cards already have"
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac12
  text: 'The frontend keeps the console''s isolation rules: everything in the one
    self-contained package, rendered only from endpoint payloads, no external CDN/font/script/stylesheet
    requests'
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac13
  text: '`mship test --repos mothership` passes; the stepper and the QR are unit-tested
    without a live relay or a real server'
  verdict: unreviewed
  evidence: []
  comment: null
open_questions: []
non_goals:
- 'Any relay-owner surface: approving an enrollment stays the relay owner''s job on
  the relay host. The stepper only reports whether YOUR request was approved, via
  the already-public status endpoint'
- "Executing steps from the UI \u2014 each step shows its command, consistent with\
  \ the console's existing read-plus-guide posture and the scoped-token question (#370)\
  \ still being open"
- 'Driving the sequence for a machine other than the one being set up: the stepper
  reports this machine''s position, not a fleet view'
- 'Persisting any secret for the sake of the stepper: the enroll record holds a request
  id and a URL, never a key or token'
- "Replacing docs/remote-run.md \u2014 the stepper is the interactive path; the prose\
  \ stays the reference"
- Editing mothership.yaml or any config from the page
risks:
- 'A wizard that misreads its own state is worse than no wizard: if it says ''approved,
  start serve'' when the tunnel will fail, the operator loses trust in the whole page.
  Hence step state is derived from the same topology payload the edges render from,
  rather than a second inference path that could disagree'
- "Polling a remote status endpoint on page render couples page load time to the relay\
  \ being up; it must be timeout-bounded and degrade to 'could not check' rather than\
  \ hanging or erroring the page \u2014 the same discipline the topology probes already\
  \ follow"
- A stale enroll record (request expired, or the relay's store rotated) will report
  'pending' forever. The record needs an age, and the step needs to say when a request
  is old enough to be presumed lost
- Auto-refresh on a page that performs network probes turns one page open in a background
  tab into steady probe traffic; the interval has to be modest and the refresh must
  be a plain reload rather than something that could stack
- Adding a `doctor` endpoint widens what the serve bearer exposes; doctor output is
  diagnostic and already assumed non-secret, but it needs the same redaction test
  the topology payload has
task_slug: null
work_item_id: null
clarification_reason: most people who are using open source aren't committing their
  relay host name in the yaml, I think a lot of people just use mship serve --relay-host
prose_verdicts: {}
---
## Problem

The original ask was Tailscale-style 'guided flows/instructions for adding a new node'. What shipped is a status page with one command per unhealthy edge — useful once you already know the sequence, useless if you do not. Adding a node actually spans four machines' worth of steps in a fixed order: configure a relay in mothership.yaml, request enrollment from the new machine, have the relay owner approve it, start `serve --relay`, pair the phone, then map the run-host role on the workspace. Get the order wrong and the errors are unhelpful — `serve --relay` before approval fails at the tunnel, `run-host add` before the remote serves produces 'unreachable'. Today that sequence exists only in docs/remote-run.md prose and in the operator's head, which is exactly the confusion that started this work. The console can close it: five of the six steps are already derivable from the `GET /net/topology` payload, and the sixth — 'has the relay owner approved my request yet?' — is answerable by polling the enroll-server's `GET /status/{rid}`, which is a PUBLIC unauthenticated endpoint by design. The one thing missing is that `mship relay enroll` prints its request id and polls it inline, then forgets it, so nothing later can ask 'where did my request get to?'.

## User story

As an operator adding a machine to my relay, I want the console to show me the whole sequence with my current position marked and exactly one next action, so that I do not have to reconstruct the order from docs or guess why a step failed.

## Approach

A stepper on the existing console page, driven by state the console can already see, plus one small piece of new local state.

Step state comes from the topology payload wherever possible, so the stepper cannot disagree with the edges rendered beside it: relay configured (relay edge is not `relay_not_configured`), relay serve running (serve edge `serve_relay_running`), run-host role mapped and reachable (per-role edges). Each step resolves to done / current / blocked / not-started, and only the CURRENT step shows a command — the failure mode of a wizard is a wall of commands for steps you are not on.

The cross-machine gap is closed by persisting what `mship relay enroll` already learns. It receives a request id, prints it, polls `/status/{rid}` inline, and discards it; it will instead record `{rid, enroll base url, hostname, requested_at}` in the gitignored state dir. The console then polls that public status endpoint — no relay-side console, no owner credential, nothing new exposed — and can finally say 'requested 14 minutes ago, still pending approval' or 'approved — start `mship serve --relay`'. That single record is the whole reason the sequence becomes trackable rather than guessable.

The pairing step gets the QR inline (segno and `serve_pair_link` already exist), because a QR in a browser is strictly better than a QR redrawn in a terminal for the one task that requires pointing a phone at it.

Shipped alongside are four small fixes to the same page that make it a dashboard rather than a snapshot: order edges by severity so failures are first, auto-refresh with a visibly-stale timestamp (a full page reload, because `GET /net/topology` is header-only and the console's cookie is scoped to `/ui`, so a JS fetch would 401), the pairing QR above, and the remaining `mship doctor` checks behind a small read-only endpoint so one page answers 'is this workspace healthy' instead of only 'is it connected'.

## The six steps, and where each one's truth comes from

1. **Relay configured** — `relay:` block in mothership.yaml. Truth: topology relay edge is not `relay_not_configured`.
2. **Enrollment requested** (from the new machine) — truth: the new local enroll record exists.
3. **Owner approved** (on the relay host) — truth: `GET /status/{rid}` on the enroll-server, public and unauthenticated by design, so no relay-side console or owner credential is needed.
4. **Relay serve running** — truth: topology serve edge is `serve_relay_running`.
5. **Phone paired** — truth: not locally observable (the phone holds the credential), so this step is advisory and renders the QR rather than claiming a state. Stated plainly rather than faked.
6. **Run-host role mapped** (on the workspace) — truth: topology per-role edges, which already distinguish declared / mapped / reachable.

Step 5 is the honest gap: nothing on this machine knows whether a phone completed pairing. Reporting it as 'unknown, here is the QR' is better than inventing a signal.

## Why the four small fixes ride along

They touch the same template and the same payload as the stepper, and two of them are prerequisites for it reading well: severity ordering means the failing edge is next to the step that mentions it, and the staleness timestamp matters more once a page carries a wizard someone might leave open. Shipping them separately would mean two passes over the same file for no benefit. Each remains independently testable.
