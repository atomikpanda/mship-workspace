---
id: pr-merge-notification
title: 'PR-merge notification: serve watcher posts a mailbox event that wakes inbox
  wait (MOS-219)'
status: implemented
created_at: '2026-07-09T13:43:24.075264Z'
updated_at: '2026-07-09T19:20:00.778040Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: A background watcher runs inside mship serve, launched via the app lifespan
    so it covers both the relay and non-relay serve paths, and it stops cleanly on
    shutdown. On an interval it checks the PR state of each active (not-yet-closed)
    task's recorded pr_urls via the existing PRManager.check_pr_state, run off the
    event loop (asyncio.to_thread) so gh subprocess calls never block serve.
  verdict: approved
- id: ac2
  text: "When a watched PR transitions from open to merged (or closed), the watcher\
    \ posts exactly one event message into that task's mailbox thread \u2014 located\
    \ via the task's WorkItem thread_ids, creating and linking a thread if none exists\
    \ \u2014 reusing the same append lock the other serve message writers use."
  verdict: approved
- id: ac3
  text: The event message is role=agent, kind=event. A new computed thread field surfaces
    a trailing unhandled agent event, and the mship inbox wait predicate is widened
    from awaiting_reply to (awaiting_reply OR trailing-agent-event), so an agent's
    existing inbox wait loop wakes on a PR-merge event with no new command.
  verdict: approved
- id: ac4
  text: "The event does NOT trigger the phone 'needs you' surface: needs_you and needs_decision\
    \ stay false (kind=event is neither needs_you nor decision), so the operator is\
    \ not nagged. (unseen may become true \u2014 an unread dot is acceptable; an action-card\
    \ nag is not.)"
  verdict: approved
- id: ac5
  text: 'Idempotency: the merge/close event is posted at most once per (task, repo,
    PR) across repeated poll iterations AND across serve restarts. Before posting,
    the watcher checks the target thread for an existing event for that PR+state and
    skips if present; it also tracks already-notified transitions in-process.'
  verdict: approved
- id: ac6
  text: 'kind=event is backward compatible: existing consumers tolerate it. Ground
    Control renders an event as an ordinary agent message with no GC change required;
    the mothership kind Literal and any exhaustive kind handling are updated.'
  verdict: approved
- id: ac7
  text: 'The watcher interval is configurable with a sane default (30-60s) and degrades
    safely: check_pr_state returning ''unknown'' (auth/network/rate-limit) is treated
    as no-transition and retried next tick; an exception in one iteration is logged
    and the loop continues.'
  verdict: approved
- id: ac8
  text: Tests cover the widened inbox-wait predicate / trailing-agent-event field,
    and the watcher's transition detection, once-only posting, and create-or-find-thread;
    everything passes via mship test with no new third-party dependencies.
  verdict: approved
open_questions: []
non_goals:
- 'Phone/GC push notification or special GC styling for PR-merge events: v1 is agent-facing
  and the event renders as a plain agent bubble; GC styling is a possible follow-up.'
- 'A blocking mship pr wait command: the operator chose mailbox reuse over adding
  a new command.'
- 'Refactoring onto the general lifecycle-hooks system (MOS-220): build this standalone
  now per the recorded decision; migrate later.'
- 'A GitHub webhook receiver: v1 is a polling watcher only.'
- Watching PRs for tasks that are already closed/abandoned.
risks:
- 'Concurrent append race: the watcher and a serve request could write the same thread.
  Mitigated by reusing serve''s existing message-append lock via shared store instances
  (watcher launched inside create_app''s lifespan).'
- Blocking gh subprocess in the event loop. Mitigated by running check_pr_state through
  asyncio.to_thread so the loop is never blocked.
- Duplicate events across serve restarts. Mitigated by a thread-scan idempotency guard
  (skip if an event for that PR+state already exists) plus in-process dedup.
- Widening the inbox-wait predicate touches a core, heavily-used path. Mitigated by
  targeted tests and keeping the trailing-agent-event condition cursor-gated so it
  fires once per event.
- "role=agent kind=event attribution: chosen deliberately over posting as a fake human\
  \ message \u2014 it is an honest system/agent event and renders as an agent bubble,\
  \ while still waking the agent and not nagging the phone."
task_slug: pr-merge-notification
work_item_id: wi-20260709161512-c1256f6c
---
## Problem

An agent that opens a PR has no way to learn it merged except **busy-polling** `gh pr view` — dogfooded hard this session (polling every ~90s for hours across multiple PRs). `mship serve` is already a persistent control plane that records each task's PR URLs (`Task.pr_urls`), so it should watch them and tell the agent the moment a PR merges or closes, letting close-out run without polling.

The operator's constraints (chosen during design): **reuse the mailbox** (no new command — the agent's existing `mship inbox wait` loop should catch it) and **don't nag the phone** (no "needs you" action card for a PR-merge event).

## User story

As an autonomous agent — and the operator supervising it — I want `mship serve` to notify the owning session the moment its PR merges/closes, through the mailbox my `mship inbox wait` loop already watches, so close-out runs promptly without wasting cycles polling, and without lighting up the phone.

## Approach

The decisive constraint (from mapping the internals): `mship inbox wait` returns only when a thread's `awaiting_reply` is true, i.e. its **last message is role=human**. An agent-role message does **not** wake it, and there is no system/event role or kind today. So a naive "serve posts a message" won't wake the agent unless we either post as a fake `human` (wrong attribution, and renders as the operator's own bubble on the phone) or make a small, honest model addition. This spec takes the honest path.

### Model additions (mothership `core/message.py`)

- Add `"event"` to the `Message.kind` Literal (`note | needs_you | decision | event`).
- Add a computed `Thread` field (e.g. `awaiting_agent_event`) = there exists an agent message with `kind=="event"` after the last human message.
- Widen the `mship inbox wait` predicate (`cli/message.py`) from `lambda t: t.awaiting_reply` to `lambda t: t.awaiting_reply or t.awaiting_agent_event`.

Why this shape: `needs_you`/`needs_decision` key on `kind in (needs_you, decision)`, so an `event` leaves them **false** → no phone nag (this is the exact surface MOS-219 must avoid). `unseen` may flip true (an unread dot), which is acceptable. The wait's `updated_at > since` cursor gate makes the event fire **once**: the agent handles it and re-arms with the returned cursor, so it won't re-fire until a new event posts. On the phone, GC's `MessageRow` specialcases only `kind=="decision"`; an `event` (agent role) falls through to the ordinary agent-markdown bubble — **no GC change required** for v1.

### The watcher (mothership `core/serve.py` + `cli/serve.py`)

Launch a background loop via a FastAPI **lifespan** on the app built in `create_app` (covers both the non-relay path and the relay path, which both call `create_app`). The loop has the collaborators it needs already in scope (`msgs`, `workitems`, `state_manager`, plus `container.pr_manager()`), and reuses the existing message-append lock so posts don't race with request handlers.

Each tick (interval configurable, default ~30-60s):
1. Load state; for each **active, not-yet-closed** task with `pr_urls`, check each URL via `PRManager.check_pr_state(url)` — run through `asyncio.to_thread` so the blocking `gh` call never stalls the event loop.
2. On an `open → merged` (or `open → closed`) transition, **create-or-find** the task's thread (task → `work_item_id` → WorkItem `thread_ids[0]`, else `create_thread` + `add_thread`, mirroring `POST /items/{id}/messages`) and `append(tid, role="agent", kind="event", text=...)` — e.g. `"🔀 PR merged: <repo> #<num> (task <slug>) — ready to close out."`.
3. `check_pr_state` returning `"unknown"` (auth/network/rate-limit) is treated as no transition and retried next tick; an exception in one iteration is logged and the loop continues.

### Idempotency

Post each transition at most once per (task, repo, PR): keep an in-process set of notified `(pr_url, state)` transitions, AND before appending, scan the target thread for an existing event referencing that PR+state — so a serve restart (which clears the in-process set) does not re-post. A merged PR also leaves the watch set once the agent runs `mship close` (the task is no longer active), bounding the window.

### Reuse (no new machinery)

- Merge/close detection: `PRManager.check_pr_state` (`core/pr.py`) → `{merged, closed, open, unknown}`.
- Thread create-or-find + append: the pattern already in `POST /items/{id}/messages` (`serve.py`), under the existing append lock.
- Background-loop lifecycle: the relay path's daemon-loop precedent (`_serve_with_relay`), here expressed as an app lifespan task.

No new third-party dependencies; gated on `mship test`.
