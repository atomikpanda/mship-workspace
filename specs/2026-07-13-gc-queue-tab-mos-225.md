---
id: gc-queue-tab-mos-225
title: 'Queue tab: one-card-at-a-time cross-workspace approval queue (Ground Control)'
status: implemented
created_at: '2026-07-13T11:10:58.610479Z'
updated_at: '2026-07-13T12:57:05.770649Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: A new Queue tab appears in the Ground Control bottom nav (a 4th Section alongside
    Home / Tasks / Settings).
  verdict: approved
  evidence:
  - kind: commit
    ref: 3786f17
    note: Section.QUEUE + route; SectionTest 4-tab nav
- id: ac2
  text: 'The Queue aggregates, across all connected workspaces, one card per pending
    action derived from GET /items attention, covering all four states: needs_approval,
    needs_decision, blocked, needs_review.'
  verdict: approved
  evidence:
  - kind: commit
    ref: daf0510
    note: QueueRepository /items fan-out + cardsFrom; QueueRepositoryTest
- id: ac3
  text: "Cards are urgency-tiered \u2014 (blocked + needs_decision) before needs_approval\
    \ before needs_review \u2014 and ordered oldest-waiting-first within each tier."
  verdict: approved
  evidence:
  - kind: commit
    ref: 05935b5
    note: sortQueue tier+oldest-first; QueueCardTest sort test
- id: ac4
  text: Each card shows its workspace, its type, and its primary action.
  verdict: approved
  evidence:
  - kind: commit
    ref: 75d1d7a
    note: 'QueueScreen: workspace + kind label + primary action'
- id: ac5
  text: 'Safe actions are inline: approving a spec and picking a decision option happen
    on the card face, remove the card, advance to the next, and offer a brief undo.'
  verdict: approved
  evidence:
  - kind: commit
    ref: 75d1d7a
    note: approve/answerDecision success-only advance + inline undo; VM tests
- id: ac6
  text: 'Risky actions open the detail: a blocked card opens its WorkItem; a needs_review
    card opens its PR (in the browser in v1).'
  verdict: approved
  evidence:
  - kind: commit
    ref: 75d1d7a
    note: blocked opens WorkItem, needs_review opens PR (browser)
- id: ac7
  text: "The Queue shows a position indicator (\"N of M\") and an 'all caught up \u2713\
    ' empty state when nothing is pending."
  verdict: approved
  evidence:
  - kind: commit
    ref: 3df6a37
    note: position/total + caught-up empty state; QueueViewModelTest
- id: ac8
  text: Deferring a card (swipe) sends it to the back of the queue without dismissing
    it.
  verdict: approved
  evidence:
  - kind: commit
    ref: 75d1d7a
    note: SwipeToDismissBox->defer + Defer button; defer_persists_across_refresh
- id: ac9
  text: Newly-arrived pending actions are inserted into the queue without disrupting
    or replacing the card currently in focus.
  verdict: approved
  evidence:
  - kind: commit
    ref: 75d1d7a
    note: 15s poll + mergeKeepingHead; live_refresh_keeps_current_head test
- id: ac10
  text: Each card is labeled with its workspace and deep-links to its underlying WorkItem
    / spec / PR.
  verdict: approved
  evidence:
  - kind: commit
    ref: 75d1d7a
    note: workspace label + Details/Open-thread/Open/Open-PR deep-links
- id: ac11
  text: A partially-unreachable fan-out still renders the reachable workspaces' cards,
    showing a per-workspace error indicator rather than failing the whole Queue.
  verdict: approved
  evidence:
  - kind: commit
    ref: 75d1d7a
    note: QueueRepository error isolation + WorkspaceErrorLine; partial-failure test
open_questions: []
non_goals:
- "In-app PR merge and the PR review/merge cockpit \u2014 delegated to MOS-208; needs_review\
  \ cards open the PR (browser in v1), never merge blind."
- "Inline resolution of blocked cards \u2014 blockers are heterogeneous; blocked cards\
  \ open the WorkItem detail in v1."
- "A snooze that is distinct from defer \u2014 v1 has defer-to-back only."
- "Migrating the Home 'Needs you' feed onto GET /items or adding needs_review to Home\
  \ \u2014 a follow-up (operator decision 2026-07-13: keep v1 tight)."
- "Any new mship serve work \u2014 the attention overlay and the approve / request-changes\
  \ / decision-send actions already exist; a structured decision-answer endpoint (vs\
  \ the current free-text thread send) is explicitly out of scope here."
- "iOS parity \u2014 Ground Control Android first; iOS is a later follow-up."
risks:
- 'Two cross-workspace attention derivations will coexist until Home converges: Home''s
  older 3-state client feed (no needs_review) and the Queue''s /items-based 4-state
  feed. They can disagree; accepted and tracked as a follow-up.'
- Client-side fan-out over N workspaces means Queue latency and error surface scale
  with workspace count; partial failures must degrade gracefully (per-workspace error
  indicator, never a blank/half Queue) rather than failing the whole tab.
- WorkItem Attention is boolean flags, not a list of discrete actions, so 'one card
  per pending action' needs a stable card identity (workspace + workitem + attention-kind)
  so a card doesn't reappear after it's acted on, and so refreshes don't duplicate
  cards.
- Live-refresh insertion without disrupting the focused card requires careful list
  diffing so indices don't jump and an action never lands on the wrong card.
- needs_review opening the browser (not in-app) is a stopgap until MOS-208 and may
  feel inconsistent with the inline-act promise; acceptable for v1.
task_slug: gc-queue-tab-mos-225
work_item_id: wi-20260713113650-48436cd9
clarification_reason: null
---
## Problem

A limited-time operator running mothership from their phone shouldn't have to scan a cross-workspace list and decide what to look at. Today Ground Control's Home surfaces an attention LIST, but acting on pending work means reading the list, choosing an item, navigating to detail, acting, and coming back — high friction for someone clearing work in short bursts. There is no surface that simply hands the operator the next thing that needs them, lets them act, and advances. As a result, approvals, decisions, and reviews pile up because triaging them is itself work.

## User story

As a limited-time operator running mothership from Ground Control, I want a Queue that hands me the next pending action across all my workspaces one card at a time, so that I can clear approvals, decisions, and reviews in short focused bursts without scanning a list.

## Approach

Add a new Queue bottom-nav tab (a 4th Section alongside HOME / TASKS / SETTINGS) that renders the cross-workspace attention overlay as a one-card-at-a-time stack — each card is one pending action; the operator acts and the next card surfaces. The data mostly already exists: mship serve derives the 4-state attention overlay per WorkItem via compute_attention and serves it at GET /items as WorkItemSummary.Attention {needs_approval, needs_decision, blocked, needs_review}, and GC already mirrors that DTO. v1 backs the Queue with a NEW cross-workspace client fan-out over GET /items (analogous to the existing HomeFeedRepository but 4-state) — a QueueRepository that merges across all connected workspaces into an urgency-tiered List<QueueCard>, one card per pending action. Card faces reuse existing GC pieces: DecisionCard for needs_decision (tap an option inline, + free-text Other), SpecActions/MshipClient.approve() for needs_approval (Approve inline; Request changes / full review open detail), open-WorkItem for blocked, and open-the-PR (browser in v1) for needs_review. Ordering is urgency-tiered — tier 1 blocked + needs_decision (an agent is stuck on you), tier 2 needs_approval, tier 3 needs_review — oldest-waiting first within a tier, with an optional workspace filter. Interaction: safe actions (approve-spec, pick-decision) happen inline, clear the card, and advance with a brief (~5s) undo; risky actions (blocked, needs_review) open the full screen; swipe defers a card to the back (reorder, not dismiss — you can't dismiss something that still needs you; no separate snooze in v1); a position indicator ("N of M") and an "all caught up ✓" empty state give closure; live refresh inserts newly-arrived cards without disrupting the card currently in focus. Home stays the at-a-glance attention list and is left AS-IS — converging it onto /items (so it also shows needs_review) is a tracked follow-up, not part of this issue. This is expected to be a Ground-Control-only change: the attention overlay and all reused actions already exist on serve, so no mship serve change is planned.

## Architecture

New client pieces in ground-control/android:

- QueueRepository (data/): fans out GET /items across all connected workspaces (reusing the same connection registry HomeFeedRepository uses), maps each WorkItemSummary.Attention into zero or more QueueCards (one per set attention flag), merges, and urgency-sorts. Partial failures surface per-workspace, not as a whole-Queue failure.
- QueueCard (model): a stable identity of (workspaceId, workItemId, kind ∈ {NEEDS_DECISION, NEEDS_APPROVAL, BLOCKED, NEEDS_REVIEW}) plus the render payload (title, one-line intent, workspace label, deep-link target, oldest-waiting timestamp for ordering) and an action descriptor (inline vs open-detail).
- QueueViewModel: holds the ordered card list + focus index; exposes act(card) (calls the reused MshipClient action, removes the card, advances, arms undo), defer(card) (moves to back), undo() (restores the last acted card), and refresh(newCards) (insert-behind-focus diff that keeps the focused card stable).
- UI: a new Section.QUEUE enum entry + a composable(...) route in GroundControlApp.kt; the card surface reuses DecisionCard for decisions and the existing SpecActions approve path for approvals.

Reuse map: GET /items + WorkItemSummary.Attention DTO (already mirrored in data/dto/WorkItemDtos.kt); MshipClient.approve() / requestChanges() / decision-option send; DecisionCard.kt; SpecActions.kt. No mship serve change planned.

## Testing

Android testing is JVM unit tests only (no emulator in this environment). Targets:

- QueueRepository: cross-workspace merge; Attention→QueueCard mapping (one card per set flag); urgency-tier ordering + oldest-first within a tier; partial fan-out failure yields reachable cards + a per-workspace error (never a blank Queue); stable card identity across refreshes.
- QueueViewModel: act removes-and-advances; defer sends to back; undo restores the acted card; live-insert keeps the focused card stable (no index jump).
- Card→action mapping: safe kinds (approval, decision) are inline; risky kinds (blocked, needs_review) are open-detail.

Use Ktor MockEngine for the /items fan-out and the approve / decision sends; assert any fire-and-forget side effects in real time, not on the virtual test clock (known MockEngine-under-runTest flake).
