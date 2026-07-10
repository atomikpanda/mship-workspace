---
id: idle-session-wake-serve-long-poll-for-mailbox-239-slice-2
title: Idle-session wake + serve long-poll for the message mailbox (#239 slice 2)
status: implemented
created_at: '2026-06-30T11:37:13.291551Z'
updated_at: '2026-06-30T13:48:27.678599Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: '`changed_since(threads, since)` returns exactly the threads whose `updated_at`
    is strictly after `since`, plus a `cursor` equal to the maximum `updated_at` across
    all threads (or `since` when none are newer); covered by unit tests including
    the empty and all-older cases.'
  verdict: approved
- id: ac2
  text: "`mship inbox wait [--since <iso>] [--timeout N]` blocks until a thread gains\
    \ a new human message after `since` (default `since` = now) or the timeout elapses,\
    \ then prints `{threads, cursor, timed_out}` JSON: on a hit, `threads` are the\
    \ awaiting threads (each with id, subject, pending text) and `timed_out` is false;\
    \ on timeout, `threads` is empty and `timed_out` is true; both carry the advanced\
    \ `cursor`. Tests use an injected clock/sleep \u2014 no multi-second real sleeps."
  verdict: approved
- id: ac3
  text: '`mship inbox wait` does NOT return for an agent-role message (the agent''s
    own reply): a thread whose latest message is from the agent is excluded from `threads`,
    so re-arming with the returned cursor blocks rather than busy-returning.'
  verdict: approved
- id: ac4
  text: "`mship inbox wait` reads only the cwd-resolved workspace's `MessageStore`\
    \ and reports a clear error (non-zero) when run outside a workspace \u2014 it\
    \ never falls back to another store."
  verdict: approved
- id: ac5
  text: '`GET /threads?wait=1&since=<iso>&timeout=N` (behind the existing bearer auth)
    blocks until some thread''s `updated_at` is after `since` or the (clamped, cap
    ~30s) timeout elapses, then returns the changed thread summaries + `cursor` (`timed_out`
    true with an empty list on timeout); it uses `asyncio.sleep` (does not block a
    worker thread); plain `GET /threads` without `wait=1` is unchanged.'
  verdict: approved
- id: ac6
  text: A bundled `receiving-messages` skill documents the arm/re-arm loop (background
    `mship inbox wait`, on wake answer + `mship reply` + re-arm with the new cursor),
    and the SessionStart notice nudges a fresh session to arm it.
  verdict: approved
- id: ac7
  text: "Tests (pytest) cover `changed_since` (pure), the CLI `inbox wait` (hit on\
    \ new human message, timeout, `--since` threading/idempotency, agent-reply ignored,\
    \ outside-workspace error), and the serve endpoint (returns-on-change, timeout,\
    \ `since` filter, bearer auth, non-`wait` unchanged) \u2014 all with injected/short\
    \ timing; the full mothership suite is green."
  verdict: approved
open_questions:
- id: q1
  text: What is the relay/Caddy/sish front's idle-read timeout for `mship serve --relay`?
    The serve long-poll cap (~30s) must stay safely under it; if it is shorter, lower
    the cap (or have the phone use a shorter `timeout` over the relay).
  answer: probably 30s but not sure
non_goals:
- "An inotify / filesystem-watch backend \u2014 a short-interval poll loop only; inotify\
  \ is a later optimization if poll latency/cost ever matters."
- "A persisted cursor file \u2014 the cursor is an ephemeral timestamp the caller\
  \ threads through."
- "Spawning agents / `claude -p` / waking a session that is NOT running \u2014 out\
  \ of #239; this requires a live (idle) session that can background the wait."
- "Real-time push (SSE / websockets) \u2014 long-poll only."
- "`task_slug` routing / steering a specific task's agent \u2014 a later layer."
- "Multi-workspace aggregation \u2014 one `mship serve` + one agent per workspace;\
  \ routing is structural."
risks:
- "The serve long-poll holds a connection open for up to ~30s and must survive the\
  \ relay/sish/Caddy front's idle-read timeout \u2014 keep the timeout conservative\
  \ (cap ~30s) and confirm the relay does not cut idle connections faster; the phone\
  \ must treat a `timed_out` empty response as 're-poll', not an error."
- "The ~1s poll interval adds up to ~1s wake latency and a steady light load while\
  \ a wait is open \u2014 acceptable for a single operator; revisit with inotify only\
  \ if it matters."
- "Idle-wake depends on the agent actually re-arming the background wait (protocol\
  \ compliance) \u2014 mitigated by the `receiving-messages` skill + the SessionStart\
  \ nudge, with slice 1's Stop hook as a turn-boundary safety net."
- "Mixing one new `async def` long-poll endpoint into the otherwise-sync FastAPI serve\
  \ \u2014 the async loop must use `asyncio.sleep` (never block the event loop) and\
  \ do only cheap `store.list()` reads per tick."
- "An ephemeral cursor lost on agent crash means a message could go unanswered until\
  \ the next human message or the next turn-boundary Stop-hook drain \u2014 accepted\
  \ (no durable cursor)."
task_slug: idle-session-wake-serve-long-poll-for-mailbox-239-slice-2
work_item_id: wi-20260702110439-b6d44017
---
## Problem

The message mailbox (`message-mailbox`, implemented) is poll-only, and slice 1 (`stop-hook-inbox-drain`, #239) made a live agent self-drain at turn boundaries. Two gaps remain: (1) a session that is open but IDLE (the agent finished its turn and is sitting at the prompt) does not notice a phone message that lands later — no hook fires on a file write; (2) the phone only learns of an agent's reply on its next manual poll, so reply latency is poor. Both are the same missing capability: block until a new message appears, instead of busy-polling. Agents are turn-based, so the idle agent backgrounds a long-poll (like backgrounding a test run) and the harness re-invokes the same session when it returns — no `claude -p`, no new sessions.

## User story

As a Mothership operator, I want an open-but-idle agent session to wake and answer a phone message shortly after I send it, and my phone to see the agent's reply promptly — without keeping a turn active or manually polling — so the conversation feels responsive even though it is store-and-forward underneath.

## Approach

One shared poll-until-change primitive with two consumers, mothership-only, no new dependency (mirrors mship's existing `time.sleep` poll loops; serve uses `asyncio.sleep` so it never stalls a uvicorn worker).

1. **Core predicate `changed_since`** (new, e.g. `src/mship/core/message_wait.py`): given the current threads and a `since` timestamp, return `(changed_threads, cursor)` where `changed_threads` are those with `updated_at > since` and `cursor` is the high-water mark `max(updated_at, since)`. Pure and exhaustively unit-tested. Each consumer wraps it in a thin loop that re-reads `store.list()` every ~1s until `changed_threads` is non-empty or a deadline passes; the loops take an injected clock + sleep so tests never sleep for real.

2. **Cursor = ephemeral timestamp, not a file.** Each caller passes `since=<last cursor>` and gets the new `cursor` back to thread into the next call; default `since` = now (only future messages). No persisted cursor file — a message missed during a crash window is caught by slice 1's Stop hook on the next turn anyway.

3. **Agent-side `mship inbox wait [--since <iso>] [--timeout N]`** (new CLI command alongside `inbox`/`reply`/`messages`): blocks on the core loop, then projects the changed threads to AWAITING ones (latest message role == human — new human messages to answer), and prints `{threads: [{id, subject, pending, updated_at}], cursor: <iso>, timed_out: bool}` JSON. Because it filters to awaiting, it never returns for the agent's OWN reply (an agent message). Reads only the cwd-resolved workspace's `MessageStore` (fails cleanly if not in a workspace). The idle agent backgrounds this; on return it answers each thread, `mship reply`s, and re-arms with the returned `cursor`.

4. **Serve-side `GET /threads?wait=1&since=<iso>&timeout=N`** (async handler added to `src/mship/core/serve.py`, behind the existing bearer auth): blocks on the same core (via `asyncio.sleep`), returns changed thread summaries + `cursor` so the phone sees an agent reply quickly. `timeout` is clamped (default ~25s, cap ~30s) to stay under the relay/Caddy idle-read timeout; returns promptly with `timed_out: true` + the cursor so the phone re-polls. Plain `GET /threads` (no `wait`) is unchanged.

5. **Arm/re-arm protocol** — a small bundled skill `receiving-messages` (in `src/mship/skills/`) documenting the loop (keep a background `mship inbox wait` armed; on wake answer each + `mship reply` + re-arm with the new cursor), plus a one-line nudge appended to the SessionStart notice (`no_task_notice` / `_session-context`) so a fresh session knows to arm it. Composes with slice 1's Stop hook, which catches messages that land mid-turn.

## Architecture

The tested logic is the pure `changed_since(threads, since) -> (changed, cursor)` in a new `core/message_wait.py`. Two thin wait loops wrap it: a synchronous one for the CLI (`time`-based, with injectable `now_fn`/`sleep_fn` for tests) and an `async` one for serve (`asyncio.sleep`). Both re-read `MessageStore.list()` each tick — the same store + `Thread.awaiting_reply` the rest of the mailbox uses, so wait, `inbox`, and `_drain` never disagree on what is awaiting. The CLI command joins `inbox`/`reply`/`messages` in `src/mship/cli/message.py`; the serve endpoint extends the `--- message mailbox ---` block in `src/mship/core/serve.py` (one `async def` among sync handlers — FastAPI supports the mix). The protocol skill lives in `src/mship/skills/receiving-messages/`, installed like other bundled skills; the SessionStart nudge extends `no_task_notice` (the `_session-context` source).

## Testing

Unit tests for `changed_since`: newer-than-since filtering, cursor = max(updated_at) / falls back to `since`, empty store, all-older. CLI `inbox wait` tests drive an injected `now_fn`/`sleep_fn` (or a load_fn returning successive thread lists) so a 'message arrives on the 3rd poll' scenario runs instantly: assert it returns the awaiting thread + advanced cursor; a no-message run returns `timed_out` true + empty; a thread whose latest message is the agent's reply is excluded; outside a workspace errors. Serve tests use FastAPI's async test client: `?wait=1` returns on a newly-appended message, times out with an empty list + cursor, filters by `since`, requires the bearer token, and the plain `GET /threads` path is unchanged. No test sleeps for real seconds — timing is injected or sub-100ms.
