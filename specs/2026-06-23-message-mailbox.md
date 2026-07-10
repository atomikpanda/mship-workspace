---
id: message-mailbox
title: 'Message mailbox: agent-agnostic durable two-way messages (serve + CLI)'
status: implemented
created_at: '2026-06-23T00:04:46.713689Z'
updated_at: '2026-06-23T01:09:19.665829Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: "A `MessageStore` persists each thread as one JSON file under `.mothership/messages/<thread-id>.json`\
    \ containing the thread (`id`, `subject`, `created_at`, `updated_at`, optional\
    \ `task_slug`) and an ordered list of messages (`id`, `thread_id`, `role` in {human,\
    \ agent}, `text`, `created_at`); it supports create-thread, append-message (updates\
    \ `updated_at`), get-thread, list-threads, and an `awaiting_reply` derivation\
    \ (true iff the latest message role is `human`), with atomic writes \u2014 all\
    \ covered by unit tests."
  verdict: unreviewed
- id: ac2
  text: '`mship serve` exposes behind the existing bearer auth: `POST /threads {subject?,
    text}` (creates a thread with a first human message, returns the thread), `POST
    /threads/{id}/messages {text}` (appends a human message; 404 on unknown thread),
    `GET /threads` (summaries incl. id, subject, last-message preview, updated_at,
    awaiting_reply), and `GET /threads/{id}` (full thread + messages; 404 on unknown);
    covered by serve tests including auth and 404s.'
  verdict: unreviewed
- id: ac3
  text: '`mship inbox` lists only threads whose latest message role is `human` (awaiting
    an agent), each with its pending text; it emits JSON when stdout is not a TTY
    and an empty result when nothing awaits.'
  verdict: unreviewed
- id: ac4
  text: '`mship reply <thread-id> "<text>"` appends an `agent`-role message (errors/non-zero
    on unknown thread) and thereby removes that thread from `mship inbox`; `mship
    messages <thread-id>` prints the thread''s messages in chronological order (JSON
    when non-TTY).'
  verdict: unreviewed
- id: ac5
  text: 'Awaiting-reply is derived from the latest message only (no separate read/answered
    flag): after an agent reply a thread is not in the inbox, and a subsequent human
    message via the API re-raises it.'
  verdict: unreviewed
- id: ac6
  text: Tests (pytest) cover the MessageStore (create/append/get/list + awaiting derivation
    + atomic write), the four serve endpoints (create/append/list/get, auth required,
    404s), and the CLI (`inbox` filters to awaiting threads, `reply` appends + clears,
    `messages` renders); the full mothership suite is green.
  verdict: unreviewed
open_questions: []
non_goals:
- "The phone chat UI (a Messages tab in Ground Control) \u2014 its own next spec"
- "Capture-as-conversation: promoting a thread into a spec via mship spec draft/apply\
  \ \u2014 its own spec"
- "Task-steering wiring: surfacing a task agent's open_questions as messages and routing\
  \ answers back \u2014 its own spec"
- "Auto-dispatch: spawning/notifying an agent on a new message (delivery model #2)\
  \ \u2014 a later layer"
- "Notifications / push when a reply lands \u2014 a later slice"
- "Real-time delivery (SSE/websockets) \u2014 polling only"
- Message edit/delete, attachments/media, reactions
- "Multi-user identity / per-user threads \u2014 single operator; roles are just human|agent"
- Thread archival/retention/expiry policy
risks:
- Concurrent appends to the same thread file could race; mitigate by mirroring SpecStore's
  atomic write and load-append-save discipline (and a simple per-store lock if SpecStore
  uses one).
- "The agent-agnostic contract is convention, not enforcement \u2014 an agent only\
  \ answers if it (or the operator) runs `mship inbox`. That is the accepted store-and-forward\
  \ tradeoff; the later auto-dispatch layer removes the manual step."
- Thread/message id scheme must be collision-free and ordering deterministic (order
  messages by created_at / append order); pick a stable scheme (e.g. a sortable timestamp-prefixed
  id or uuid).
- "`awaiting_reply` derived purely from the latest message role assumes every thread\
  \ starts with a human message and alternation isn't required \u2014 confirm the\
  \ derivation holds for agent-initiated threads (out of scope now: threads are human-initiated\
  \ via POST /threads)."
task_slug: message-mailbox
work_item_id: wi-20260702110439-5db40a30
---
## Problem

Capture today means typing a precise title + repos into a form — the opposite of real capture, where you want to offload a half-formed thought and let something shape it. More broadly, Ground Control has no way to have a back-and-forth with the agents/LLMs doing the work: you can dispatch and watch, but not converse. The fix is a generic, agent-agnostic, durable two-way message channel between the phone and whatever agent runs on the host — capture (message an idea, an agent drafts a spec) and steering (answer a task agent's question) are uses on top. This spec is the FOUNDATION: the durable mailbox + serve endpoints (phone side) + CLI (agent side). It is deliberately store-and-forward (like email), not live chat: you send anytime, an agent answers whenever one next runs, you see the reply on your next poll. No always-on daemon; auto-dispatch and notifications are later layers on this base.

## User story

As a Mothership operator, I want to send and receive durable messages with the host-side agent from my phone, so that I can drop a thought and get a shaped reply (and later answer an agent's questions) without typing a precise form or keeping a session live.

## Approach

mothership-only. A MessageStore persists conversations durably as one JSON file per thread under `.mothership/messages/<thread-id>.json`, mirroring how SpecStore persists specs (atomic temp-file + rename writes; load-append-save for a new message). A thread is `{id, subject, created_at, updated_at, task_slug?}` plus an ordered list of messages `{id, thread_id, role: human|agent, text, created_at}`. `mship serve` gains four endpoints behind the existing bearer auth — POST /threads (create a thread + first human message), POST /threads/{id}/messages (append a human message), GET /threads (summaries), GET /threads/{id} (full thread) — the phone's side. The agent side is plain CLI requiring zero integration, which is what makes the channel agent-agnostic: `mship inbox` lists threads awaiting an agent (latest message role == human) with the pending text, `mship reply <thread-id> "<text>"` appends an agent message, `mship messages <thread-id>` prints a thread. Any agent (Claude Code, Codex, Gemini) participates by being told to check `mship inbox` and `mship reply`. 'Awaiting reply' is DERIVED from the latest message's role — no separate read/answered flag — so replying clears a thread from the inbox and a new human message re-raises it. Verification is pytest only (store + serve + CLI); no phone UI in this slice.

## Data model & storage

Two dataclasses/models (Pydantic, consistent with Spec): Thread { id: str, subject: str, created_at: datetime, updated_at: datetime, task_slug: str | None = None } and Message { id: str, thread_id: str, role: Literal['human','agent'], text: str, created_at: datetime }. Persisted as one JSON file per thread at `<workspace>/.mothership/messages/<thread-id>.json` holding the thread fields plus `messages: [Message...]`. MessageStore (new, in core/, mirroring core/spec_store.py SpecStore): `create_thread(subject, text, now, task_slug=None) -> Thread` (writes the file with a first human message), `append(thread_id, role, text, now) -> Message` (load-append-save, bumps updated_at), `get(thread_id) -> Thread|None`, `list() -> list[ThreadSummary]` (id, subject, last-message preview, updated_at, awaiting_reply), `awaiting(thread) -> bool` (latest message role == 'human'). Atomic writes via temp file + os.replace, exactly as SpecStore does. Ids: a sortable timestamp-prefixed slug or uuid4 — collision-free and chronologically orderable.

## Agent-agnostic contract

The channel is agent-agnostic because the agent side is plain mship CLI over durable data — no SDK, no per-agent integration. The documented contract: an agent (or the operator driving one) runs `mship inbox` to get the threads awaiting a reply (JSON: thread id, subject, pending human text), decides how to respond (free-text answer, or e.g. draft a spec via `mship spec draft/apply` and reply with a pointer — that wiring is a later spec), and posts `mship reply <thread-id> "<text>"`. Because 'awaiting' is derived from the latest message role, the inbox self-clears on reply and self-raises on the next human message — no state machine to maintain. This mirrors how agents already interact with specs and the journal (read/write durable mship state via CLI), so any agent that can run shell commands participates. The serve endpoints are the phone's mirror of the same store.
