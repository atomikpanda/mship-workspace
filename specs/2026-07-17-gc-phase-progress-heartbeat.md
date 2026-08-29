---
id: gc-phase-progress-heartbeat
title: 'GC: spec phase-progress + live agent heartbeat indicator'
status: implemented
created_at: '2026-07-17T01:12:34.949579Z'
updated_at: '2026-07-17T09:48:46.343875Z'
affected_repos:
- mothership
- ground-control
acceptance_criteria:
- id: ac1
  text: mship stamps last_activity_at on a task whenever the agent runs a task-scoped
    mship command (at minimum journal, commit, test, phase, spec apply), with no dependency
    on which agent or LLM is driving.
  verdict: approved
  evidence:
  - kind: commit
    ref: 4e6ea1e1b3a5bc82d9d6167abef601cb2496a08a
    note: record_activity stamped from journal/commit/test/phase/spec-apply
  - kind: test
    ref: test-runs/1.mothership
    note: null
  comment: null
- id: ac2
  text: mship heartbeat --task <slug> updates the task's last_activity_at and has
    no other side effects, so a cooperating agent can pulse it on a timer.
  verdict: approved
  evidence:
  - kind: commit
    ref: 5e898eb101341dfc4c158c5dacd97021f28f8dbe
    note: mship heartbeat command, no side effects
  comment: null
- id: ac3
  text: GET /tasks/{slug} and GET /tasks include last_activity_at and phase_entered_at;
    GET /items/{id} surfaces the active task's last_activity_at and phase so GC renders
    liveness without an extra round-trip.
  verdict: approved
  evidence:
  - kind: commit
    ref: cfc0911eb4a7d43edd3e2538ab1bd9d655fafc94
    note: TaskSummary exposes last_activity_at + phase_entered_at
  - kind: commit
    ref: 85849b93f086f0b6da1d35df73a381e3e272aa3e
    note: WorkItemSummary surfaces active_phase + active_last_activity_at
  comment: null
- id: ac4
  text: Ground Control renders a shared phase stepper (Dispatched -> Planning -> Building
    -> Review -> Done) driven by task.phase, with the current stage visually active/animated.
  verdict: approved
  evidence:
  - kind: commit
    ref: 4ae8cd8620c607019db69375e80aa6b07c1a3f18
    note: PhaseStepper Dispatched->Planning->Building->Review->Done
  comment: null
- id: ac5
  text: 'Ground Control shows a live chip derived from last_activity_at: ''working''
    when recent (~90s window), ''quiet <N>m'' after the stall threshold (~5 min),
    and ''done'' on merge; the thresholds are named constants.'
  verdict: approved
  evidence:
  - kind: commit
    ref: 4ae8cd8620c607019db69375e80aa6b07c1a3f18
    note: LiveChip working/idle/quiet/done, named thresholds
  - kind: test
    ref: test-runs/1.ground-control
    note: null
  comment: null
- id: ac6
  text: The spec-detail screen shows the compact stepper+chip after Dispatch, polling
    only while the spec is dispatched or in-flight and stopping at a terminal state.
  verdict: approved
  evidence:
  - kind: commit
    ref: 3331ca04de6bc89a67a91ccf09f1fe67ffe8969c
    note: spec-detail compact stepper + in-flight-only poll
  comment: null
- id: ac7
  text: The Console/WorkItem cockpit shows the full stepper + live chip alongside
    the existing journal feed, reusing its existing polling with no new poll loop.
  verdict: approved
  evidence:
  - kind: commit
    ref: 073558a05b13adc15d436683900e07facbf36f09
    note: Console cockpit stepper+chip reusing 4s poll
  comment: null
- id: ac8
  text: When last_activity_at is absent (older tasks or no activity yet), the UI degrades
    gracefully - the stepper still shows the phase and the chip shows a neutral/unknown
    state rather than a false 'working'.
  verdict: approved
  evidence:
  - kind: commit
    ref: 4ae8cd8620c607019db69375e80aa6b07c1a3f18
    note: phaseStepFor(null)->Dispatched, liveStatus(null)->Unknown
  comment: null
open_questions: []
non_goals:
- Per-keystroke or streamed output of the agent's work - the baseline liveness is
  an activity proxy, not literal typing.
- Changing the WorkItem phase projection's 6-value model - the stepper reads task.phase,
  not the collapsed WorkItem phase.
- A push/websocket transport - polling is sufficient and matches existing GC patterns.
risks:
- Activity-proxy liveness can read 'quiet' during a long heads-down file-writing stretch
  with no mship call; mitigated because the plan/dispatch flow journals at checkpoints,
  and the 'quiet Nm' wording is honest rather than claiming 'stalled' outright.
- Stamping on every task-scoped command must be cheap (a single field write) so it
  does not slow common commands.
- The optional continuous pulse must never be required for correctness - the baseline
  must fully work without it.
task_slug: gc-phase-progress-heartbeat
work_item_id: wi-20260717011740-20b91198
clarification_reason: null
prose_verdicts: {}
---
## Problem

After the operator taps Dispatch on a spec in Ground Control, there is no way to see what is happening or whether anything is actually in progress. The spec-detail screen goes cold immediately after Dispatch (it does no polling), and the WorkItem phase projection collapses planning/dev/review into a single 'in_flight' with no liveness signal. So the operator cannot distinguish an agent that is actively working from one that has stalled or crashed, and is left blind-waiting between dispatch and a PR appearing.

## User story

As the operator, after I dispatch a spec, I want to watch it move through its phases (Dispatched -> Planning -> Building -> Review -> Done) with a live indicator of whether the agent is actively working right now, so that I know something is happening and can spot a stall without leaving the screen.

## Approach

Two parts. (1) Serve, an agent-agnostic activity heartbeat: add `last_activity_at` to the Task model, stamped by mship whenever the agent runs a task-scoped command (e.g. journal, commit, test, phase, spec apply). This keys off the mship CLI boundary rather than any specific agent/LLM, so any driver pulses automatically with zero per-agent cooperation. Add an optional `mship heartbeat --task <slug>` command that cooperating agents/harnesses can call on a timer for finer, continuous liveness (progressive enhancement) - same field, no other side effects, never required for correctness. Expose `last_activity_at` and the already-stored-but-unexposed `phase_entered_at` on TaskSummary (GET /tasks, GET /tasks/{slug}) and surface the active task's liveness on WorkItemSummary (GET /items) so GC can render without extra round-trips. (2) Ground Control, a shared phase-progress component: a linear stepper 'Dispatched -> Planning -> Building -> Review -> Done' driven by task.phase (plan/dev/review, already exposed), with the current stage visually active/animated; and a live chip derived from `last_activity_at` - 'working' (green pulse) when recent, 'quiet <N>m' (amber) after the stall threshold, 'done' when merged, thresholds as named constants. The component renders in two places: a compact stepper+chip on the spec-detail screen backed by a new lightweight poll loop that runs only while the spec is dispatched/in-flight and stops at a terminal state (so the 'watch it start' moment works right where Dispatch was tapped); and the full stepper plus the existing journal feed in the Console/WorkItem cockpit, reusing that screen's existing 4s poll (no new loop).

## Architecture

Two phase models exist and the stepper deliberately reads the task-level one. Task phase (plan -> dev -> review -> run) is the only place a distinct 'plan/planning' state exists and is already exposed on GET /tasks/{slug}; the WorkItem phase projection (inbox/shaping/ready/in_flight/review/done) collapses plan+dev+review into in_flight and is NOT changed here. Stepper stage mapping: spec dispatched = Dispatched; task.phase plan = Planning; dev = Building; review = Review; task finished/merged = Done. last_activity_at is a new nullable timestamp on the Task, stamped at the mship command boundary (the agent-agnostic hook) and optionally by `mship heartbeat`; phase_entered_at already exists on the Task but is not currently exposed, so this also adds it to the task summary.

## Testing

Serve: unit-test that a representative task-scoped command stamps last_activity_at; that `mship heartbeat` updates it with no other state change; and that the task/workitem summaries include last_activity_at and phase_entered_at. Ground Control: test the stepper renders the correct active stage for each task.phase; the live chip resolves to working/quiet/done for recent/old/merged last_activity_at (inject fixed timestamps); the neutral state when last_activity_at is null; and that the spec-detail poll loop starts on dispatched/in-flight and stops at a terminal status.
