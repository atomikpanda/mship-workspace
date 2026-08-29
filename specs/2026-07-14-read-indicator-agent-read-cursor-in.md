---
id: read-indicator-agent-read-cursor-in
title: Read indicator (agent read cursor) in Ground Control
status: approved
created_at: '2026-07-14T13:22:57.865152Z'
updated_at: '2026-07-14T15:37:13.763514Z'
affected_repos: []
acceptance_criteria:
- id: ac1
  text: Thread gains an agent read cursor agent_seen_at (datetime | None), symmetric
    to the operator's seen_at; a helper advances it to the latest consumed human-message
    time and never moves it backward.
  verdict: approved
  evidence:
  - kind: commit
    ref: e221f3f
    note: Thread.agent_seen_at + MessageStore.mark_agent_seen (never-backward); test_mark_agent_seen_*
      (message.py, message_store.py)
  comment: null
- id: ac2
  text: mship _drain and mship inbox wait stamp agent_seen_at when they surface pending
    human messages to the agent, under the existing per-thread lock (idempotent; no
    double-write on overlapping waits).
  verdict: approved
  evidence:
  - kind: commit
    ref: e221f3f
    note: stamp_agent_seen wired into inbox_wait + _drain; test_stamp_agent_seen_*
      (message.py, internal.py, message_wait.py)
  comment: null
- id: ac3
  text: Serve exposes agent_seen_at on the thread in the endpoints Ground Control
    reads (thread list + thread detail).
  verdict: approved
  evidence:
  - kind: commit
    ref: e221f3f
    note: agent_seen_at on _summaries (list) + _thread_payload model_dump (detail);
      test_agent_seen_at_exposed_on_list_and_detail
  comment: null
- id: ac4
  text: The mship client / Ground Control deserializes agent_seen_at and shows a 'Read'
    indicator on a human message once agent_seen_at is at or past that message's created_at.
  verdict: approved
  evidence:
  - kind: commit
    ref: 27812dc
    note: agentSeenAt on Thread/ThreadSummary DTOs; Read indicator rendered in ConversationScreen
      MessageRow
  comment: null
- id: ac5
  text: "The indicator composes with the existing state so a human message reads Sent\
    \ \u2192 Read \u2192 Replied; it does not regress the operator-side seen_at /\
    \ unseen behavior."
  verdict: approved
  evidence:
  - kind: commit
    ref: 27812dc
    note: "messageReadState Sent\u2192Read\u2192Replied; MessageReadStateTest (incl\
      \ parsed-not-string-compared)"
  comment: null
- id: ac6
  text: 'Backward-compatible: a thread persisted without agent_seen_at deserializes
    with it null and shows no false ''Read''; a human message posted after the last
    consume reads un-Read until the next consume.'
  verdict: approved
  evidence:
  - kind: commit
    ref: 27812dc
    note: agent_seen_at defaults null (backward-compat) + never-backward (Task 1)
      + parsed >= comparison (Task 6)
  comment: null
open_questions: []
non_goals:
- Per-message read receipts beyond a single per-thread cursor (the cursor model matches
  the existing seen_at).
- "Read state for agent\u2192operator messages \u2014 that is the existing operator\
  \ seen_at / unseen."
- Typing indicators or presence.
- "A distinct 'read on mship reply' stamp \u2014 a reply already implies read and\
  \ lands later; the drain/wait consume is the earlier, more useful signal."
risks:
- "Stamp point: agent_seen_at must fire on CONSUME (drain / inbox wait), before the\
  \ reply, and be idempotent across both paths that surface messages \u2014 a wrong\
  \ point makes 'Read' fire too early, too late, or never."
- "Concurrency: only one agent/serve per workspace, but two overlapping inbox waits\
  \ must not race the cursor \u2014 reuse the existing per-thread locking and the\
  \ never-move-backward rule."
- 'Correctness of the > comparison (mirroring unseen): a human message posted after
  the agent last consumed must read un-Read until the next consume.'
task_slug: null
work_item_id: null
clarification_reason: null
prose_verdicts:
  problem:
    verdict: approved
    comment: null
  user_story:
    verdict: approved
    comment: null
  approach:
    verdict: approved
    comment: null
  non_goals:
    verdict: approved
    comment: null
  risks:
    verdict: approved
    comment: null
---
## Problem

The mship mailbox tracks only the OPERATOR's read cursor (Thread.seen_at → Thread.unseen = the operator hasn't seen the agent's latest reply). There is no agent-side equivalent, so when an operator messages an agent from Ground Control they can't tell whether the agent has actually seen the message — only whether the thread is still awaiting a reply. GitHub issue #345 asks for a 'Read' indicator that fires when the agent CONSUMES the message server-side, distinct from and complementary to awaiting-reply.

## User story

As an operator messaging an agent from Ground Control, I want a 'Read' indicator on my message once the agent has actually consumed it, so I know it was seen — a message should read Sent → Read → Replied, not just flip between awaiting-reply and replied.

## Approach

Add a symmetric AGENT read cursor to the mailbox: Thread.agent_seen_at, mirroring the existing operator-side Thread.seen_at (and its unseen computed property). Stamp agent_seen_at when the agent consumes a human message — i.e. when `mship _drain` (the turn-boundary Stop-hook drain) or `mship inbox wait` surfaces pending human messages to the agent (the 'seen it, not replied yet' moment). A helper on the MessageStore advances agent_seen_at to the latest surfaced human message's created_at, never moving it backward, under the existing per-thread lock. Serve exposes agent_seen_at on the thread payloads Ground Control reads (thread list + detail). Ground Control deserializes it and renders a 'Read' indicator on a human message once agent_seen_at covers it (>= its created_at), composing with the existing awaiting-reply / seen state. The operator-side seen_at/unseen semantics are unchanged.
