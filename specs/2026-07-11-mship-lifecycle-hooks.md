---
id: mship-lifecycle-hooks
title: 'mship lifecycle hooks: run a task/command on state transitions (MOS-220)'
status: dispatched
created_at: '2026-07-11T18:09:01.831071Z'
updated_at: '2026-07-11T18:50:36.112252Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: 'A `hooks:` entry with `on: pr.merged` in mothership.yaml runs its configured
    `run` task/command when PrWatcher observes the tracked PR transition to merged,
    reusing pr_watcher.py''s existing terminal-state detection.'
  verdict: approved
- id: ac2
  text: "A hook's `run` executes via the resolved env_runner for its repo, through\
    \ the same wrapped-shell path executor.py uses for go-task targets \u2014 no new\
    \ sandbox surface is introduced."
  verdict: approved
- id: ac3
  text: A non-required hook that raises or exceeds its timeout is logged as a warning
    and does NOT block or roll back the underlying transition (task finish/close/phase
    change/PR-watcher sweep completes normally).
  verdict: approved
- id: ac4
  text: 'A hook with `required: true` that fails blocks the transition at points where
    blocking is meaningful (task.finished, phase.entered.*, workitem.phase.*, i.e.
    before the mutation commits).'
  verdict: approved
- id: ac5
  text: A `hooks:` entry naming an event outside the v1 enum is rejected as a config
    validation error at workspace-config load time, not deferred to first use.
  verdict: approved
- id: ac6
  text: Each hook enforces its configured (or workspace-default) timeout; a hook that
    runs past it is treated as a timeout failure, not left to hang.
  verdict: approved
- id: ac7
  text: 'Tests cover: each v1 event fires only its matching hook(s); fail-open default
    behavior for non-required hooks; required:true blocking behavior; timeout enforcement;
    unknown-event config rejection.'
  verdict: approved
open_questions:
- id: q1
  text: "Config shape for `run`: a single `run: <string>` disambiguated by convention\
    \ (resolves as a go-task name if found, else executed as shell), or explicit separate\
    \ `task:`/`shell:` keys? Proposed default: single `run:` with convention-based\
    \ resolution \u2014 confirm or prefer explicit keys."
  answer: explicit keys
- id: q2
  text: 'Event enum for v1: is `task.finished, task.closed, phase.entered.<phase>,
    workitem.phase.<phase>, pr.merged, pr.closed` the right starting set, given task
    phases (plan/dev/review/run) and WorkItem phases (inbox/shaping/ready/in_flight/review/done)
    are distinct enums kept as separate event families rather than one shared `phase.entered.*`?
    Confirm or adjust.'
  answer: it needs to be explicit maybe to distinguish between workitem and task events
- id: q3
  text: 'Sync-with-timeout vs async: proposed default is synchronous execution with
    a per-hook timeout, for deterministic agent/CI behavior, with async explicitly
    deferred to v2. Any objection given the latency risk noted above?'
  answer: fine just be sure to note it somewhere
- id: q4
  text: 'Sandbox model: proposed default is running hooks through the repo''s existing
    env_runner, identical trust boundary to `task` targets, no new privilege surface.
    Confirm, or should automatically-triggered hooks default to a more restrictive
    mode (e.g. read-only) than explicitly operator-invoked task runs?'
  answer: 'yes'
- id: q5
  text: 'Fail-open default: proposed default is fail-open with `required: true` as
    an explicit opt-in to blocking. For polling-derived events (pr.merged/pr.closed)
    where the transition is already historical by the time it''s detected, should
    `required: true` be rejected/ignored on those events specifically, since it can''t
    actually block anything?'
  answer: 'yes '
- id: q6
  text: 'Naming: src/mship/core/hooks.py is already the git-hooks (pre-commit/pre-push/etc.)
    module. Proposed new module name is `core/lifecycle_hooks.py` (or similar) to
    avoid collision. Confirm module name, and whether user-facing docs/CLI should
    call this feature something other than bare "hooks" to avoid conflating it with
    git hooks (even if the yaml config key itself stays `hooks:`).'
  answer: 'yes '
- id: q7
  text: "Scoping across repos: for a multi-repo workspace, is a single workspace-level\
    \ `hooks:` list (with each rule optionally naming its `repo:`) sufficient, or\
    \ should individual repos also be able to declare their own local hook rules \u2014\
    \ mirroring the env_runner workspace-then-repo override pattern already in config.py?"
  answer: hooks are defined at the workspace level of people really need a hook at
    the repo level they can make a shell script in that repo and have the hook call
    the script
non_goals:
- "Async / fire-and-forget hook execution mode \u2014 v1 is synchronous-with-timeout\
  \ only; async is a plausible v2 follow-up."
- "Migrating MOS-219 (PR-merge notification) or MOS-194 (dispatch notify) onto this\
  \ substrate \u2014 they remain on their current bespoke implementations for this\
  \ slice."
- A general plugin system (arbitrary discoverable Python plugins, third-party packages,
  dynamic loading).
- Remote or webhook-triggered hooks (inbound HTTP endpoints, external CI callbacks).
- Hook-specific sandboxing beyond the existing env_runner trust boundary (no new permission
  model).
- Automatic retries/backoff for failed hooks.
risks:
- "Naming collision: src/mship/core/hooks.py already exists for git pre-commit/pre-push/post-checkout/post-commit\
  \ install/uninstall \u2014 reusing that name or the bare word \"hooks\" without\
  \ qualification risks operator confusion between git hooks and lifecycle hooks."
- "Synchronous execution blocks the triggering call (finish/close/phase-transition/PR-watcher\
  \ sweep) \u2014 a slow or misconfigured hook adds latency to unrelated core operations;\
  \ per-hook timeout bounds this but several hooks on one transition can still stack\
  \ delay."
- "Fail-open by default can mask real failures if operators don't check logs/warnings\
  \ \u2014 automation that silently no-ops can look indistinguishable from automation\
  \ that's working."
- "pr.merged/pr.closed are polling-derived (PrWatcher's sweep cadence), not true real-time\
  \ events \u2014 describing their execution as \"synchronous at the transition point\"\
  \ is a bit of a fiction since the underlying transition already happened by the\
  \ time it's detected; required:true has limited meaning there."
- "Config validation gaps (unknown event name, unresolvable `run` target) need to\
  \ fail at config-load/doctor time \u2014 if deferred to first trigger, a bad hook\
  \ config silently no-ops (compounding the fail-open risk) until someone notices\
  \ it never ran."
task_slug: mship-lifecycle-hooks
work_item_id: wi-20260711185036-5abfe5b3
---
## Problem

Mothership has no general way to react to a WorkItem/task crossing a state boundary. Every existing "when X happens, do Y" is a bespoke, hand-wired module living inside core internals — e.g. PrWatcher (src/mship/core/pr_watcher.py) polls each task's pr_urls and posts a mailbox event on merge/close, purpose-built for one consumer. MOS-219 (PR-merge notification) needs exactly this kind of reaction, and more are coming (MOS-194 dispatch notify). Without a shared substrate, each new automation need means another one-off poller/callback wired directly into finish/close/phase-transition code, growing coupling and duplicting the same "detect transition, do side effect, don't wedge the workflow" logic every time.

## User story

As an mship operator (or an agent driving a WorkItem), I want to declare `on: <event> run: <task-or-command>` rules in my workspace config so that routine reactions to task/WorkItem state changes (notify, kick a follow-up task, sync an external status) happen automatically, without hand-coding a new watcher/callback in mothership core for each case.

## Approach

Config: a top-level `hooks:` list in `mothership.yaml`, parsed into a typed model on `WorkspaceConfig` (same pattern as the existing `RepoConfig.capture` -> `CaptureConfig`). Each entry: `on` (event name, required), `run` (a go-task target name or a literal shell command), optional `repo` (which repo's env_runner/worktree to run in; inferred from event context when omitted — e.g. the PR's own repo for `pr.*`), optional `name` (a label for logs), optional `timeout` (seconds; falls back to a workspace-level default), optional `required` (bool, default false). Declarative and secret-free, consistent with this being a public repo — a hook needing a secret reads it from the runner's ambient environment, not the yaml.

Event enum (v1, closed set, extensible later): `task.finished`, `task.closed`, `phase.entered.<phase>` for task phases (`plan`/`dev`/`review`/`run`, per the `Phase` Literal in core/phase.py), `workitem.phase.<phase>` for WorkItem phases (`inbox`/`shaping`/`ready`/`in_flight`/`review`/`done`, per core/workitem.py — a distinct enum from task phases, so the two event families stay separate rather than sharing one ambiguous `phase.entered.*`), `pr.merged`, `pr.closed`. An `on:` value outside this enum is a config validation error raised at workspace-config load time (e.g. surfaced by `mship doctor`), not deferred to first trigger.

Execution model: hooks run **synchronously** at the transition point, each bounded by its `timeout`. This keeps behavior deterministic for agents/CI (no race between "transition committed" and "hook effects visible"). A hook's `run` executes through the *existing* env_runner-wrapped path that go-task targets already use (executor.py's `resolve_env_runner(repo)` -> `shell.build_command(...)`) from the relevant repo/worktree — a shell `run` string executes literally in that same wrapped environment. This is intentionally not a new sandbox or privilege surface: it is the same trust boundary as any other `task` invocation already configured for the repo.

Failure handling: **fail-open by default** — a hook that raises or exceeds its timeout is caught, logged, and surfaced as a warning (mirroring `PhaseTransition.warnings` in core/phase.py, and PrWatcher's own never-abort-the-sweep-on-one-failure pattern), but the state transition itself is not blocked or rolled back; a bad hook must never wedge task/WorkItem progress. `required: true` opts a specific hook into blocking behavior — meaningful for events detected *before* the underlying mutation commits (`task.finished`, `phase.entered.*`, `workitem.phase.*`), where a hard failure can still prevent the transition. For `pr.merged`/`pr.closed` — detected after the fact by polling (the merge already happened) — `required: true` cannot un-merge a PR; it should only fail the *notification/hook step* loudly rather than claim to block a transition that's already historical. This distinction is called out per-event in the event catalog below and is one of the open questions.

Wiring points: PhaseManager.transition() in core/phase.py (for `phase.entered.*` and the analogous WorkItem phase-change call site), the task finish/close code paths (`task.finished`/`task.closed`), and PrWatcher's existing terminal-state detection in `_check_one`/`_resolve_and_post` (core/pr_watcher.py) for `pr.merged`/`pr.closed` — reusing its poll/idempotency machinery rather than standing up a second poller.

Module naming note: the issue's suggested new module `src/mship/core/hooks.py` is **already taken** — that file currently implements git pre-commit/pre-push/post-checkout/post-commit hook install/uninstall (see core/hooks.py). This new lifecycle-hooks registry+dispatcher needs a different module name (e.g. `core/lifecycle_hooks.py`) to avoid collision and, likely, different user-facing vocabulary to avoid confusing operators about which kind of "hook" is meant even though the config key itself can still be `hooks:`.

Consumers: MOS-219 (PR-merge notification) and MOS-194 (dispatch notify) are natural first consumers that could migrate onto this substrate once it exists, but that migration is explicitly deferred (see non-goals) to keep this slice reviewable on its own.

## Config schema (proposed)

```yaml
# mothership.yaml
hooks:
  # Fires when PrWatcher observes a tracked PR reach the merged state.
  - on: pr.merged
    run: notify-pr-merged      # go-task target name, resolved against the repo's Taskfile
    name: "Notify on PR merge"
    timeout: 30                 # seconds; falls back to a workspace default if omitted

  # Fires when a task's phase transitions to review (before the mutation commits).
  - on: phase.entered.review
    run: "task lint:full"       # or a literal shell command
    repo: mothership
    required: true               # a failure here blocks the phase transition
    timeout: 120

  # Fires when a WorkItem's phase reaches done.
  - on: workitem.phase.done
    run: archive-workitem-notes
```
Notes: no secrets in this file (it's a public repo, consistent with existing workspace rules) — hooks that need credentials read them from the runner's ambient environment. `repo` is optional and inferred from event context (e.g. the PR's own repo) when the event carries one.

## Event catalog (v1)

| Event | Fires when | Wired at | `required: true` meaningful? |
|---|---|---|---|
| `task.finished` | a task is marked finished (`mship finish`) | task finish code path | Yes — runs before the finish mutation commits |
| `task.closed` | a task is closed/abandoned | task close code path | Yes |
| `phase.entered.<phase>` (`plan`\|`dev`\|`review`\|`run`) | `PhaseManager.transition()` commits a new task phase | core/phase.py `PhaseManager.transition` | Yes |
| `workitem.phase.<phase>` (`inbox`\|`shaping`\|`ready`\|`in_flight`\|`review`\|`done`) | a WorkItem's phase field changes | WorkItem phase-change call site | Yes |
| `pr.merged` | PrWatcher's poll observes a tracked PR reach `merged` | core/pr_watcher.py `_check_one`/`_resolve_and_post` | Limited — the merge already happened; blocking only affects the hook/notify step, not the merge itself |
| `pr.closed` | PrWatcher's poll observes a tracked PR reach `closed` (not merged) | core/pr_watcher.py | Limited, same caveat as `pr.merged` |
