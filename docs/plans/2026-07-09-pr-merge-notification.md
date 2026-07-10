# PR-merge notification (serve watcher → mailbox event) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `pr-merge-notification` (specs/2026-07-09-pr-merge-notification.md) — approved. Closes MOS-219.

**Goal:** `mship serve` watches each task's open PR and, on merge/close, posts an event into the task's mailbox thread that wakes the owning agent's `mship inbox wait` — so agents stop busy-polling for PR close — without nagging the phone.

**Architecture:** A new message `kind="event"` + a `Thread.awaiting_agent_event` computed field let the existing `inbox wait` predicate wake on a trailing agent event. A `PrWatcher` (pure, testable) detects open→merged/closed transitions via the existing `PRManager.check_pr_state` and posts a once-only event into the task's thread. A FastAPI lifespan runs the watcher on an interval inside `create_app`, off the event loop via `asyncio.to_thread`.

**Tech Stack:** Python (pydantic models, FastAPI/Starlette `serve.py`, pytest). Single repo: mothership.

**Worktree (Work from):** `.worktrees/pr-merge-notification/mothership`

**Key references (verified):**
- `core/message.py`: `Message.kind` Literal (`note|needs_you|decision`); `Thread` computed fields `awaiting_reply` (last msg role==human), `needs_you`/`needs_decision` (agent msg of that kind after last human), `unseen`.
- `cli/message.py`: `inbox wait` calls `wait_for_change(..., predicate=lambda t: t.awaiting_reply)`.
- `core/message_store.py`: `append(thread_id, role, text, now, kind="note", decision=None)`, `create_thread(subject, text, now, task_slug=None)`.
- `core/workitem_store.py`: `get(id)`, `add_thread(item_id, thread_id, now)`.
- `core/state.py`: `Task.pr_urls: dict[repo,url]`, `Task.work_item_id`, `Task.finished_at`; `StateManager.load().tasks`.
- `core/pr.py`: `PRManager.check_pr_state(url) -> PrStateResult(state, reason)`, `state ∈ {merged,closed,open,unknown}`; `container.pr_manager()`.
- `core/serve.py`: `create_app(...)` builds `msgs`, `workitems`, `store`, `state_manager`; the two `FastAPI(...)` constructors; `_item_msg_lock`; the create-or-find-thread pattern in `POST /items/{id}/messages`.
- `cli/serve.py`: both call `create_app`; non-relay `uvicorn.run`; relay path's daemon-thread precedent (`_serve_with_relay`).

---

<!-- mship:task id=1 -->
### Task 1: `event` message kind + `awaiting_agent_event` + widened inbox-wait predicate

**Files:**
- Modify: `src/mship/core/message.py` (kind Literal + new computed field)
- Modify: `src/mship/cli/message.py` (inbox wait predicate)
- Test: `tests/core/test_message.py` (or the existing message-model test module)

- [ ] **Step 1: Write failing tests**

```python
# tests/core/test_message.py  (add)
from datetime import datetime, timezone
from mship.core.message import Thread, Message

def _msg(role, kind="note", t="2026-01-01T00:00:00Z"):
    return Message(id=t, thread_id="x", role=role, text="hi", created_at=datetime.fromisoformat(t.replace("Z","+00:00")), kind=kind)

def _thread(msgs):
    return Thread(id="x", subject="s", created_at=datetime.now(timezone.utc), updated_at=datetime.now(timezone.utc), messages=msgs)

def test_awaiting_agent_event_true_for_trailing_event():
    t = _thread([_msg("human"), _msg("agent", "event")])
    assert t.awaiting_agent_event is True
    assert t.needs_you is False and t.needs_decision is False  # event does NOT nag the phone

def test_awaiting_agent_event_reset_by_later_human():
    t = _thread([_msg("agent", "event"), _msg("human")])
    assert t.awaiting_agent_event is False
    assert t.awaiting_reply is True

def test_event_kind_accepted():
    m = _msg("agent", "event")
    assert m.kind == "event"
```

- [ ] **Step 2: Run — confirm failure** — `uv run pytest tests/core/test_message.py -k "event" -v` (kind="event" rejected by the Literal / field missing).

- [ ] **Step 3: Implement.** In `message.py`: add `"event"` to the `Message.kind` Literal. Add a computed field on `Thread` mirroring the `needs_you` pattern (find the index of the last human message, then look for a trailing agent event):

```python
    @computed_field
    @property
    def awaiting_agent_event(self) -> bool:
        """True iff there's an agent message with kind=='event' after the last human
        message — a PR-merge/close signal the owning agent hasn't handled yet."""
        last_human = -1
        for i, m in enumerate(self.messages):
            if m.role == "human":
                last_human = i
        return any(
            m.role == "agent" and m.kind == "event"
            for m in self.messages[last_human + 1:]
        )
```

- [ ] **Step 4: Widen the inbox-wait predicate** in `cli/message.py`:

```python
    predicate=lambda t: t.awaiting_reply or t.awaiting_agent_event,
```

- [ ] **Step 5: Run tests → green** — `uv run pytest tests/core/test_message.py -v`, then `mship test`.

- [ ] **Step 6: Commit + journal**

```bash
git add -A && git commit -m "message: add event kind + awaiting_agent_event; inbox wait wakes on it"
mship journal "event message kind + awaiting_agent_event computed field + widened inbox wait predicate; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: `PrWatcher.check_once` — transition detection, once-only event post, create-or-find thread

**Files:**
- Create: `src/mship/core/pr_watcher.py`
- Test: `tests/core/test_pr_watcher.py`

Pure, dependency-injected so it's unit-testable without a server. Takes the stores + a `check_state(url)->str` callable + a mutable `notified` set.

- [ ] **Step 1: Write failing tests** (open→merged posts once; second call no-op via in-process set; a fresh set but an existing event in the thread → skip via thread-scan; unknown → no post; creates+links a thread when the WorkItem has none)

```python
# tests/core/test_pr_watcher.py
from mship.core.pr_watcher import PrWatcher

# Use lightweight fakes matching the real stores' surface. See the real
# MessageStore/WorkItemStore/StateManager for method names:
#   state.tasks: {slug: Task(pr_urls={repo:url}, work_item_id=..., ...)}
#   workitems.get(id).thread_ids ; workitems.add_thread(id, tid, now)
#   msgs.create_thread(subject, text, now, task_slug) -> Thread(id=...)
#   msgs.get(tid).messages ; msgs.append(tid, role, text, now, kind=...)
# The test builds fakes with exactly these; assert:
#   - one open->merged transition => exactly one msgs.append(kind="event")
#   - calling check_once again (same notified set) => no second append
#   - new PrWatcher (empty set) but the thread already has that event => no append
#   - state=="unknown" or "open" => no append
#   - WorkItem with empty thread_ids => create_thread + add_thread called, event appended there
```
(Write these concretely against small in-memory fakes; assert append call counts / recorded messages.)

- [ ] **Step 2: Run — confirm failure** — module missing.

- [ ] **Step 3: Implement** `PrWatcher`. Constructor takes `msgs`, `workitems`, `state_manager`, `check_state` (callable `url->state`), `now_fn` (for testability), and an append lock (optional). `check_once()`:
  1. `state = state_manager.load()`; for each `task` in `state.tasks.values()` with non-empty `task.pr_urls`:
  2. for each `repo, url` in `task.pr_urls.items()`: `st = check_state(url)`; if `st not in ("merged","closed")`: continue.
  3. key = `(task.slug or repo, repo, url, st)`; if key in `self.notified`: continue.
  4. resolve/create thread (see below); if the thread already has an event referencing this `url`+`st` (`any(m.kind=="event" and url in m.text and st in m.text for m in thread.messages)`): mark notified + continue (restart idempotency).
  5. append the event: `msgs.append(tid, "agent", f"🔀 PR {st}: {url} (task {task.slug}) — ready to close out.", now, kind="event")`; add key to `self.notified`.
  - **Thread resolution:** `wi = workitems.get(task.work_item_id) if task.work_item_id else None`; if `wi and wi.thread_ids`: use `wi.thread_ids[0]`; elif a thread exists with `t.task_slug == task.slug` (scan `msgs.list()`): use it; else `thread = msgs.create_thread(subject=f"{task.slug}", text=..., now=now, task_slug=task.slug)` and if `wi`: `workitems.add_thread(wi.id, thread.id, now)`.
  - Wrap the resolve+append in the injected lock if provided.
  Keep it defensive: a per-task/per-url exception is caught and logged (return/continue), never aborting the whole sweep.

- [ ] **Step 4: Run tests → green** — `uv run pytest tests/core/test_pr_watcher.py -v`, then `mship test`.

- [ ] **Step 5: Commit + journal**

```bash
git add -A && git commit -m "pr_watcher: detect PR merge/close transitions and post once-only mailbox events"
mship journal "PrWatcher.check_once: transition detection + create-or-find-thread + idempotent event post; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: Wire the watcher into `serve` via a lifespan + interval loop + config

**Files:**
- Modify: `src/mship/core/serve.py` (lifespan on both `FastAPI(...)` constructors; construct `PrWatcher`; interval)
- Test: `tests/core/test_serve_pr_watch.py` (the loop wrapper start/stop + a check_once integration through TestClient lifespan)

- [ ] **Step 1: Write failing tests**
  - A `run_watch_loop(check_once, interval, stop_event)` wrapper: calling it in a thread with a fake `check_once` invokes it ≥1 time and exits promptly when `stop_event` is set (assert call count > 0 and clean exit).
  - Lifespan integration: `with TestClient(app):` (which runs startup+shutdown) does not error and the watcher task is created+cancelled cleanly. (Use a very small/ः disabled interval or inject a fake watcher so the test is fast and deterministic — e.g. an env/param to set interval and to inject `check_state` that returns "open" so nothing posts.)

- [ ] **Step 2: Run — confirm failure.**

- [ ] **Step 3: Implement.**
  - Add `run_watch_loop(check_once, interval, stop_event)` (a thin, testable loop: `while not stop_event.is_set(): check_once(); stop_event.wait(interval)`), OR the async equivalent scheduled on the loop. Prefer the async lifespan form:
  ```python
  from contextlib import asynccontextmanager
  @asynccontextmanager
  async def _lifespan(app):
      watcher = PrWatcher(msgs, workitems, state_manager,
                          check_state=lambda u: pr_manager.check_pr_state(u).state,
                          now_fn=lambda: datetime.now(timezone.utc), lock=_item_msg_lock)
      stop = asyncio.Event()
      async def loop():
          while not stop.is_set():
              try:
                  await asyncio.to_thread(watcher.check_once)   # gh calls off the event loop
              except Exception:
                  logger.exception("pr-watch tick failed")
              try:
                  await asyncio.wait_for(stop.wait(), timeout=interval)
              except asyncio.TimeoutError:
                  pass
      task = asyncio.create_task(loop())
      try:
          yield
      finally:
          stop.set(); task.cancel()
          with contextlib.suppress(asyncio.CancelledError, Exception):
              await task
  ```
  - Pass `lifespan=_lifespan` to BOTH `FastAPI(...)` constructors in `create_app` (the relay and non-relay apps both come from here).
  - `pr_manager` from `container.pr_manager()` (see `container.py`). Interval: a module default constant (e.g. `PR_WATCH_INTERVAL_SECONDS = 45`), overridable via an env var (e.g. `MSHIP_PR_WATCH_INTERVAL`) so tests can shrink it; `0`/negative disables the loop (guard at startup) for tests that don't want it.
  - Reuse `_item_msg_lock` as the watcher's lock so appends don't race request handlers.

- [ ] **Step 4: Run tests → green** — `uv run pytest tests/core/test_serve_pr_watch.py -v`, then the full `mship test`.

- [ ] **Step 5: Commit + journal**

```bash
git add -A && git commit -m "serve: run PrWatcher on an interval via app lifespan (off-loop gh checks, graceful shutdown)"
mship journal "serve lifespan runs PrWatcher on an interval (asyncio.to_thread, graceful cancel); config + tests passing" --action committed
```
<!-- /mship:task -->

---

## Self-Review

- **Spec coverage:** ac3 (event kind + awaiting_agent_event + widened predicate) → T1; ac4 (needs_you/decision stay false) → T1 test; ac2/ac5 (post once, create-or-find, idempotency) → T2; ac1/ac7 (lifespan, interval, off-loop, degrade safely) → T3; ac6 (kind=event backward compatible; no GC change) → T1 (Literal add; GC untouched); ac8 (tests, no new deps) → every task runs `mship test`. ✓
- **Type consistency:** `check_state(url)->str` in {merged,closed,open,unknown} matches `PRManager.check_pr_state(url).state`. `PrWatcher` constructor args (msgs, workitems, state_manager, check_state, now_fn, lock) are identical in T2 (definition) and T3 (construction). Event text format (`🔀 PR {st}: {url} ...`) is the same string T2 writes and T2's thread-scan checks (`url in m.text and st in m.text`). ✓
- **Merge note:** this branch is off current `main`; threadentity PR #293 also edits `serve.py` (different regions: thread handlers vs. the `FastAPI()`/lifespan). If #293 merges first, rebase this branch and re-resolve `serve.py` at finish.
