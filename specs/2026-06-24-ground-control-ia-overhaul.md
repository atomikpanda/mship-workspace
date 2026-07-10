---
id: ground-control-ia-overhaul
title: 'Ground Control IA overhaul: 3-tab nav + cross-workspace Home attention queue'
status: implemented
created_at: '2026-06-24T16:46:40.582406Z'
updated_at: '2026-06-24T19:17:17.928610Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: The bottom nav shows exactly three destinations -- Home, Tasks, Settings --
    and the Specs, Messages, and Decisions tabs are gone.
  verdict: approved
- id: ac2
  text: Home shows one 'Needs you' list that aggregates items from all connected workspaces,
    each item labeled with a workspace chip.
  verdict: approved
- id: ac3
  text: 'The list includes all three kinds: approval-ready specs (needs_review), agent
    questions (threads awaiting reply), and blocked tasks.'
  verdict: approved
- id: ac4
  text: Items are ordered by a defined, documented urgency rule that is independent
    of which workspace they came from.
  verdict: approved
- id: ac5
  text: Tapping an approval opens the existing spec-detail screen; tapping a question
    opens the conversation thread; tapping a blocker opens task detail.
  verdict: approved
- id: ac6
  text: After approving a spec or replying to a question, that item no longer appears
    in the queue on refresh.
  verdict: approved
- id: ac7
  text: A one-tap workspace switcher opens a scoped view of a single workspace listing
    its conversations/specs/tasks, and new conversations created there are scoped
    to that workspace.
  verdict: approved
- id: ac8
  text: If one workspace connection fails to load, the queue still renders items from
    the remaining workspaces and surfaces a non-fatal indicator for the failed one.
  verdict: approved
- id: ac9
  text: Home shows an explicit empty state when nothing is blocked on the user.
  verdict: approved
- id: ac10
  text: JVM unit tests cover the merge/sort aggregation and per-connection failure
    isolation at the repository/ViewModel level (no emulator).
  verdict: approved
open_questions:
- id: q1
  text: What is the exact urgency ranking across item kinds and age (e.g. blocked
    task > agent question > needs_review spec, then newest-first)?
  answer: 'Proposed default (confirm/override): blocked task > agent question > needs_review
    spec; within a tier, newest-first. Rationale: a blocker has work fully stalled,
    a question blocks an agent, a needs_review spec awaits you but nothing is actively
    waiting on it.'
- id: q2
  text: Do existing endpoints expose enough to cleanly detect 'awaiting human reply'
    on a thread and 'blocked' on a task, or is a thin mothership serialization addition
    needed (which would push this out of client-only scope)?
  answer: 'Verified against mothership serve API: no server change needed for slice
    1. Approvals = GET /specs where status==needs_review; agent questions = threads
    with awaiting_reply==true (Thread.awaiting_reply, serve.py:323); blocked tasks
    = TaskSummary.blocked_reason!=null (task_index.py:19, /tasks). Slice 1 is client-only.'
- id: q3
  text: In slice 1, do ambient non-blocking conversations live only under the scoped
    workspace view, or does Home also get an 'All activity' entry now?
  answer: only under scoped workspace view for now
- id: q4
  text: Workspace switcher affordance and placement -- Home header dropdown vs a dedicated
    control?
  answer: 'B: persistent chip rail (not a dropdown). Auto-ordered, no manual curation:
    ''All'' pinned first (global queue), then workspaces with items-needing-you-now
    (count badge, most-urgent first), then the rest by recent activity; horizontally
    scrollable with a trailing overflow that opens the full paired list. All paired
    workspaces always present (source of truth = Settings); what changes daily is
    only the order. Capture reuses the same recency order, defaulting to front-most/last-used.
    Manual pinning deferred (YAGNI, easy later add).'
- id: q5
  text: Does removing the Messages tab require migrating any existing deep links or
    future notification targets?
  answer: 'no'
- id: q6
  text: sounds right
  answer: ok
non_goals:
- 'Capture & brainstorm composer on Home (slice 2 -- builds C3 / closes mothership
  issue #156)'
- 'Visual design-system pass: type scale, color, spacing, card/chip styling, empty-state
  art (slice 3 -- needs its own brainstorm to pick a direction)'
- Any mothership API / serialization changes (slice 1 is client-side only)
- Auto-dispatch, push notifications, or background polling
- iOS (Android-first; iOS tracked separately)
- Changing spec lifecycle states or review/approve semantics
risks:
- Client-side fan-out over N workspaces can be slow or partially fail; one unreachable
  workspace must not break the whole queue (needs per-connection error isolation +
  loading/partial states).
- Urgency ranking across heterogeneous item kinds (blocker vs needs_review spec vs
  agent question vs age) is fuzzy and needs an explicit, testable order.
- '''Agent question / awaiting human reply'' detection depends on existing thread
  awaiting-reply semantics being accurate; task ''blocked'' state must be derivable
  from the current API.'
- Removing the Messages tab risks hiding ambient (non-blocking) threads until the
  scoped workspace view / all-activity affordance covers them.
- Navigation refactor (removing routes, re-homing SpecInbox) touches existing screens
  and deep links.
task_slug: ground-control-ia-overhaul
work_item_id: wi-20260702110439-3a1db265
---
## Problem

Ground Control's 5-tab bottom nav (Specs, Messages, Decisions, Tasks, Settings) has three doors into the same spec lifecycle, an empty Decisions placeholder, and no home for idea capture. Worse, the inbox groups workspace -> status, so a blocker or a question in one workspace is invisible while you're looking at another. The primary job is 'review & decide' across a handful of workspaces, but the structure scatters that job and buries cross-workspace urgency.

## User story

As someone running a handful of mship workspaces from my phone, I want one home that pools everything currently blocked on me across all of those workspaces and lets me act in a tap, so that I can review and decide without hunting through tabs or missing a blocker buried in a workspace I wasn't looking at.

## Approach

Collapse the bottom nav to three destinations: Home, Tasks, Settings. Home presents a single 'Needs you' queue that fans out across every connected workspace (WorkspaceConnection) and merges three item kinds into one urgency-sorted list, each tagged with a workspace chip: (1) approval-ready specs (needs_review), (2) agent questions (threads awaiting a human reply), (3) blocked tasks. The unifying idea is that an approval and a question are the same kind of item -- the agent is blocked on you. Tapping routes to the right existing surface: approval -> SpecDetail (review cards: approve/flag/dispatch), question -> Conversation thread (answer inline; replying unblocks the agent and drops the item), blocker -> task detail. The Decisions tab (C7) becomes this queue; the Messages tab dissolves -- conversations are reached through Home items and a scoped single-workspace view. Attention is global; creation and browsing stay workspace-scoped: a one-tap workspace switcher opens a scoped view of that workspace's conversations/specs/tasks, which is where new conversations are born. Aggregation is client-side: a new HomeFeed repository fans out over ConnectionsRepository snapshots, queries each connection's existing SpecApi (GET /specs, /threads, /tasks), maps results into a unified item type, and merges+sorts with per-connection error isolation. Reuses shipped screens (SpecInbox content moves into Home; SpecDetail, Conversation, Tasks, Settings unchanged) and the existing MVVM + repository pattern.

## Architecture

Add a HomeFeedRepository that takes a ConnectionsRepository snapshot and, per connection, calls the existing SpecApi for specs/threads/tasks. Each source maps into a unified sealed NeedsYouItem (ApprovalItem(specId), QuestionItem(threadId), BlockerItem(taskSlug)) carrying the source WorkspaceConnection for chip rendering. Results are flattened, filtered to 'blocked on you' states, and sorted by the urgency rule; each connection's fetch is isolated so a failure yields a per-connection error rather than aborting the merge. HomeViewModel exposes UI state {items, perConnectionStatus, isRefreshing, isEmpty}. Navigation: NavHost drops the specs/messages/decisions tab routes; retains specDetail/{conn}/{spec}, thread/{conn}/{id}, taskDetail/{conn}/{slug} as detail destinations reachable from Home items and the scoped workspace view. The scoped workspace view reuses existing thread/spec/task lists filtered to one connection.

## Testing

JVM unit tests only, per the project toolchain (no emulator). Cover: merge of multiple workspaces into one list; urgency sort determinism; per-connection failure isolation (one failing connection still yields others' items + an error marker); item-kind filtering (only blocked-on-you states surface); empty state. ViewModel tests use fake repositories returning canned per-connection results.
