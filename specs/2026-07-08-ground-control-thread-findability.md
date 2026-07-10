---
id: ground-control-thread-findability
title: 'Ground Control thread findability: sticky Home threads card + live threads
  list with workspace + state chip filters'
status: implemented
created_at: '2026-07-08T21:21:12.093354Z'
updated_at: '2026-07-08T23:02:26.212751Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: A sticky, slim "threads" card is pinned at the top of Home (above the needs-you
    queue) showing a compact peek of recent conversations; tapping it (or a row) opens
    the full threads list. Home otherwise stays needs-you-only.
  verdict: approved
- id: ac2
  text: "The full threads list is LIVE \u2014 it updates as messages arrive (via the\
    \ existing GET /threads long-poll), merging changed threads into the list and\
    \ re-sorting so the most-recently-active thread is always at the top. It must\
    \ MERGE the changed-thread subset into the existing list, never replace the list\
    \ with only the changed threads."
  verdict: approved
- id: ac3
  text: "Every conversation is reachable \u2014 answered/older threads that have left\
    \ the needs-you queue are still accessible from the sticky card / threads list\
    \ (fixing the current dead-end where a thread off Home has no in-app access path)."
  verdict: approved
- id: ac4
  text: Threads with new activity since last seen show an unread badge/highlight in
    the list (using the existing `unseen` flag), in addition to bubbling to the top.
  verdict: approved
- id: ac5
  text: "The existing Home workspace-rail chips (All / per-workspace) scope the threads\
    \ card + list \u2014 \"All\" shows every workspace's threads, a workspace chip\
    \ narrows to that workspace's threads."
  verdict: approved
- id: ac6
  text: A SEPARATE second row of thread-STATE filter chips (All / Unread / Needs-you)
    filters the threads list by state, composing with the workspace chips (workspace
    AND state). It is its own row, not mixed into the workspace-rail chips.
  verdict: approved
- id: ac7
  text: Tapping a thread opens the existing conversation view unchanged. No new bottom-nav
    tab is added (tabs stay Home / Tasks / Settings), and no mothership/server change
    is required (the long-poll + unseen/needs_you/awaiting_reply fields already exist).
  verdict: approved
open_questions:
- id: q1
  text: "Sticky card content \u2014 a count + the single most-recent thread, or the\
    \ top 2-3 recent rows? (Impl detail; start compact.)"
  answer: well needs you ones surface always. but I think the card would show unread
    badge count maybe top 2-3
- id: q2
  text: Does the state-chip row live on Home under the sticky card, on the full threads
    list screen, or both? (Leaning the full list screen; the card stays minimal.)
  answer: both
non_goals:
- "Renameable or auto-summarized thread subjects \u2014 the operator's pain is placement/freshness,\
  \ not naming; deferred to a later pass."
- "A free-text search box over threads \u2014 deferred; the chips + recency cover\
  \ v1."
- Any change to the Home needs-you queue itself, or to the Tasks/Settings tabs.
- "Any mothership/server change \u2014 all required data (updated_at ordering, unseen,\
  \ needs_you, awaiting_reply) and the /threads long-poll already exist."
- "Reviving a dedicated Messages bottom-nav tab (explicitly out \u2014 access is the\
  \ sticky card + drill-in list)."
risks:
- 'Live-merge correctness: the GET /threads long-poll returns only CHANGED threads
  since the cursor. The list state must merge (upsert + re-sort) those into the full
  list; replacing the list with the changed subset would make older threads vanish
  (the very bug this fixes). Cover with a test.'
- "Sticky card must not crowd Home or push the needs-you queue below the fold \u2014\
  \ keep it slim (one compact row/peek)."
- The threads list screen (currently `ui/messages/MessagesScreen` + `MessagesViewModel`)
  is repurposed as a drill-in rather than a tab; ensure nav wiring + back behavior
  are clean.
task_slug: ground-control-thread-findability
work_item_id: wi-20260708212848-2f142156
---
## Problem

Ground Control's tabs are Home / Tasks / Settings — there is no Messages tab — and conversations are only reachable by tapping a needs-you item on Home. The moment a thread is answered it leaves the needs-you queue, and then there is **no in-app way back to it**. That is why threads "disappear" and the operator repeatedly can't find past conversations. (Server-side the mailbox is fine: `GET /threads` returns the full list sorted by `updated_at` desc; nothing is lost — it's purely an access + freshness gap in the app.)

## User story

As the operator, from Home I can see a slim sticky "threads" card, tap it to get a live, newest-first list of ALL my conversations (answered or not), filter it by workspace and by state (unread / needs-you), and tap into any one — so I never lose a thread again. Home stays a clean needs-you queue.

## Approach

All Ground-Control-only; no server change (the data + long-poll already exist).

1. **Sticky threads card on Home** — a slim card pinned above the needs-you queue: a compact peek (count + most-recent) that taps through to the full threads list. Home otherwise unchanged (still needs-you-only).
2. **Live threads list** — repurpose the existing `ui/messages/MessagesScreen` + `MessagesViewModel` as a drill-in screen (not a tab). Add a live-update loop using the existing `listThreadsWait(since, timeout)` long-poll: on each change, **merge** the returned changed threads into the in-memory list (upsert by id) and re-sort by `updated_at` desc so the active thread bubbles to the top. Critically, merge — do not replace the list with the changed subset.
3. **Unread treatment** — threads with `unseen == true` get a badge/highlight (operator's pick), on top of the recency sort.
4. **Two chip rows** — row 1 is the existing Home workspace rail (All / per-workspace), reused to scope threads by workspace (threads are already per-workspace). Row 2 is NEW: thread-state chips (All / Unread / Needs-you) driven by `ThreadSummary.unseen` / `needsYou`, on its own row, composing with row 1 (workspace AND state).
5. **Into the conversation** — tapping a thread opens the existing conversation view unchanged. No new bottom-nav tab.

Decisions captured from the brainstorm: pain is placement/freshness (not naming/search); Home stays needs-you-only; unread badges yes; no Messages tab; sticky slim card as the entry; reuse workspace chips + add a separate state-chip row.
