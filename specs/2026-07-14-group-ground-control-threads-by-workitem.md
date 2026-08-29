---
id: group-ground-control-threads-by-workitem
title: Group Ground Control threads by WorkItem
status: approved
created_at: '2026-07-14T16:56:14.670868Z'
updated_at: '2026-07-14T17:15:37.876696Z'
affected_repos:
- mothership
- ground-control
acceptance_criteria:
- id: ac1
  text: 'Each thread summary in the payload GC consumes carries a resolved work_item_id:
    the id of the WorkItem that owns it (direct thread_ids membership, else indirect
    via task_slug/spec_id), or null when no item owns it.'
  verdict: approved
  evidence: []
  comment: null
- id: ac2
  text: "A thread belongs to at most one WorkItem: direct thread_ids membership is\
    \ exclusive (no thread is in two items' thread_ids \u2014 enforced at the link\
    \ site), and the indirect fallback resolves to exactly one item, so the stamped\
    \ work_item_id is never ambiguous; a thread the merge-watcher routed to an item\
    \ resolves to that same item."
  verdict: approved
  evidence: []
  comment: null
- id: ac3
  text: The Ground Control messages surface renders one group per WorkItem, labeled
    with the item's title + kind, its threads nested and ordered most-recent-first;
    threads with a null work_item_id render together in a single 'Other' group.
  verdict: approved
  evidence: []
  comment: null
- id: ac4
  text: A WorkItem group surfaces an attention indicator when any of its threads is
    awaiting the operator (awaiting_reply) or carries an unhandled agent event, so
    an item needing attention is visible without expanding it.
  verdict: approved
  evidence: []
  comment: null
- id: ac5
  text: Tapping a thread opens the existing conversation view unchanged; the read
    indicator, reply, and decision behaviors are unaffected.
  verdict: approved
  evidence: []
  comment: null
- id: ac6
  text: Groups order by their most-recently-updated thread so an item with fresh activity
    floats to the top; the 'Other' group sorts among the item groups by the same rule.
  verdict: approved
  evidence: []
  comment: null
open_questions: []
non_goals:
- "Changing how threads are created or linked to WorkItems \u2014 that linkage already\
  \ exists (WorkItem.thread_ids + the pr_watcher resolution); this only surfaces the\
  \ existing association."
- Merging threads or moving messages between threads.
- "Changing the conversation view itself \u2014 a tapped thread opens exactly as it\
  \ does today (read indicator, reply, decisions all unaffected)."
risks:
- "The exclusive-membership invariant has to be actually enforced at the link site,\
  \ not just assumed \u2014 if any code path could add a thread to a second item's\
  \ thread_ids, the guarantee breaks; a small audit + a guard on the linker keeps\
  \ it true."
- Threads linked only indirectly (task_slug/spec_id, no direct thread_ids membership)
  must resolve to their single owning item deterministically, matching how the pr_watcher
  already routes.
- Ungrouped (ad-hoc) threads must stay first-class and easy to find, not buried below
  every WorkItem group.
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
  non_goals:
    verdict: approved
    comment: null
  approach:
    verdict: approved
    comment: null
  risks:
    verdict: approved
    comment: null
---
## Problem

Ground Control's messages surface is a flat list of threads. The conversation for one piece of work is scattered across it — a WorkItem's dispatch thread, its PR-merge notifications, and its ad-hoc questions all sit as separate rows with nothing tying them together. As WorkItems accumulate threads, the operator can't tell which conversation belongs to which work, and the WorkItem — which is becoming the unit of work in the cockpit direction — isn't the unit of conversation.

## User story

As an operator, I want the Ground Control messages surface grouped by WorkItem — each item showing its threads together, with ad-hoc/unlinked chat in its own bucket — so I can see all the conversation for one piece of work in one place instead of hunting through a flat thread list.

## Approach

The thread-to-WorkItem association already exists but only server-side and one-directionally (WorkItem.thread_ids, plus indirect links via a thread's task_slug/spec_id matching the item's), so the mapping is resolved in serve and surfaced to a thin GC. INVARIANT: a thread belongs to at most one WorkItem. Direct membership is exclusive — a thread is never in two items' thread_ids (the linker, e.g. the pr_watcher, only ever links an unlinked thread, and reassigning moves it rather than duplicating), so work_item_id is unambiguous by construction rather than by tie-break. (1) serve stamps each thread SUMMARY (the inbox/thread-list payload GC consumes) with a single resolved work_item_id: direct thread_ids membership first; else the indirect fallback (thread.task_slug in item.task_slugs or thread.spec_id == item.spec_id), used ONLY for threads with no direct membership and resolved to exactly one item deterministically; null when no item owns the thread. serve builds a thread_id->work_item_id index once per list call. (2) GC groups the messages surface by work_item_id: one section per WorkItem (labeled with the item's title + kind), its threads nested and ordered most-recent-first, with an attention indicator at the item level; threads whose work_item_id is null fall into a single 'Other' group. Tapping a thread opens the existing ConversationScreen unchanged. Considered and rejected: deriving the grouping entirely in GC — rejected because GC would have to replicate serve's resolution (direct + indirect association) and drift from the server's source of truth; one server-stamped field is more robust and keeps GC thin, and the serve change deploys via the existing redeploy script.

## Testing

serve: a thread directly in an item's thread_ids resolves to that item; a thread linked only by task_slug/spec_id resolves to the right item; a thread with neither resolves to null; the linker keeps membership exclusive (linking an already-linked thread to a new item moves it rather than leaving it in both, so it never resolves to two); the stamped work_item_id appears on the thread-summary payload. GC (JVM unit tests, no emulator): a grouping helper buckets thread summaries by work_item_id including null->Other, orders groups by newest thread and threads within a group by recency, and rolls each group's attention up from its threads. Follow existing serve message/pr_watcher tests and the GC Queue/Conversation test patterns.
