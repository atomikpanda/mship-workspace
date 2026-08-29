---
id: ground-control-active-and-archived
title: Ground Control active and archived inboxes
status: implemented
created_at: '2026-08-25T18:19:04.729599Z'
updated_at: '2026-08-27T01:50:04.946665Z'
affected_repos:
- mothership
- ground-control
acceptance_criteria:
- id: ac1
  text: Given any thread or spec with pin metadata set, when it is classified, then
    its inbox state is active regardless of manual archive metadata, restore age,
    linked terminal state, inactivity, implementation age, or lifecycle-archived state.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.mothership
    note: Mothership classifier/store/API full-suite evidence
  - kind: test
    ref: test-runs/6.ground-control
    note: null
  - kind: test
    ref: test-runs/6.mothership
    note: null
  comment: null
- id: ac2
  text: Given an unpinned thread marked needs-you or containing an unanswered decision,
    when it is classified, then its inbox state is active even if it otherwise qualifies
    for manual, linked-terminal, or inactivity archival.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.mothership
    note: Mothership classifier/store/API full-suite evidence
  - kind: test
    ref: test-runs/6.ground-control
    note: null
  - kind: test
    ref: test-runs/6.mothership
    note: null
  comment: null
- id: ac3
  text: Given an unpinned item without a higher-precedence thread attention condition,
    when its latest manual archive action is later than its latest restore action,
    then it is archived immediately with archive reason manual.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.mothership
    note: Mothership classifier/store/API full-suite evidence
  - kind: test
    ref: test-runs/6.ground-control
    note: null
  - kind: test
    ref: test-runs/6.mothership
    note: null
  comment: null
- id: ac4
  text: Given an item whose latest restore is later than its latest manual archive,
    when less than exactly seven days have elapsed since that restore, then it is
    active; when exactly seven days or more have elapsed, then restore no longer affects
    classification and the applicable lifecycle, linkage, or inactivity rule determines
    its state.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.mothership
    note: Mothership classifier/store/API full-suite evidence
  - kind: test
    ref: test-runs/6.ground-control
    note: null
  - kind: test
    ref: test-runs/6.mothership
    note: null
  comment: null
- id: ac5
  text: Given a restored linked thread whose WorkItem/task is terminal, when less
    than seven days have elapsed since restore, then it is active and the WorkItem/task
    remains terminal; at exactly seven days after restore, it is archived with reason
    linked_terminal unless pin or a thread attention condition applies.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.mothership
    note: Mothership classifier/store/API full-suite evidence
  - kind: test
    ref: test-runs/6.ground-control
    note: null
  - kind: test
    ref: test-runs/6.mothership
    note: null
  comment: null
- id: ac6
  text: Given an unpinned linked thread with no needs-you work, no unanswered decision,
    and no effective restore grace, when its linked WorkItem/task is terminal, then
    it is archived with reason linked_terminal; when the linked WorkItem/task is nonterminal,
    then terminal linkage does not archive it.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.mothership
    note: Mothership classifier/store/API full-suite evidence
  - kind: test
    ref: test-runs/6.ground-control
    note: null
  - kind: test
    ref: test-runs/6.mothership
    note: null
  comment: null
- id: ac7
  text: Given an unpinned unlinked thread with no needs-you work, no unanswered decision,
    no later manual archive, and no effective restore grace, when its latest activity
    is less than seven days old, then it is active; at exactly seven days after its
    latest activity and thereafter, it is archived with reason inactive_unlinked.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.mothership
    note: Mothership classifier/store/API full-suite evidence
  - kind: test
    ref: test-runs/6.ground-control
    note: null
  - kind: test
    ref: test-runs/6.mothership
    note: null
  comment: null
- id: ac8
  text: Given an unlinked thread receives new qualifying activity after having become
    archived for inactivity, when it is classified, then the seven-day inactivity
    period is measured from that new activity and the thread is active until the new
    exact boundary.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.mothership
    note: Mothership classifier/store/API full-suite evidence
  - kind: test
    ref: test-runs/6.ground-control
    note: null
  - kind: test
    ref: test-runs/6.mothership
    note: null
  comment: null
- id: ac9
  text: Given an unpinned spec with no effective later manual archive or restore grace,
    when its lifecycle state is draft, needs_review, approved, or dispatched, then
    it is active.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.mothership
    note: Mothership classifier/store/API full-suite evidence
  - kind: test
    ref: test-runs/6.ground-control
    note: null
  - kind: test
    ref: test-runs/6.mothership
    note: null
  comment: null
- id: ac10
  text: Given an unpinned implemented spec with no effective later manual archive
    or restore grace, when less than seven days have elapsed since its latest implementation
    or update timestamp, then it is active; at exactly seven days and thereafter,
    it is archived with reason implemented.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.mothership
    note: Mothership classifier/store/API full-suite evidence
  - kind: test
    ref: test-runs/6.ground-control
    note: null
  - kind: test
    ref: test-runs/6.mothership
    note: null
  comment: null
- id: ac11
  text: Given an implemented spec receives a qualifying update, when it is classified,
    then its seven-day active period is measured from that update rather than the
    earlier implementation timestamp.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.mothership
    note: Mothership classifier/store/API full-suite evidence
  - kind: test
    ref: test-runs/6.ground-control
    note: null
  - kind: test
    ref: test-runs/6.mothership
    note: null
  comment: null
- id: ac12
  text: Given an unpinned lifecycle-archived spec with no effective later restore
    grace, when it is classified, then it is archived immediately with reason lifecycle_archived.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.mothership
    note: Mothership classifier/store/API full-suite evidence
  - kind: test
    ref: test-runs/6.ground-control
    note: null
  - kind: test
    ref: test-runs/6.mothership
    note: null
  comment: null
- id: ac13
  text: Given a lifecycle-archived spec is restored, when less than seven days have
    elapsed since restore, then it is active while its lifecycle remains archived;
    at exactly seven days after restore, it is archived again with reason lifecycle_archived
    unless pinned.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.mothership
    note: Mothership classifier/store/API full-suite evidence
  - kind: test
    ref: test-runs/6.ground-control
    note: null
  - kind: test
    ref: test-runs/6.mothership
    note: null
  comment: null
- id: ac14
  text: Given an item is manually archived during an active restore grace period,
    when the archive action is committed after the restore, then it is archived immediately
    with reason manual unless pin or a thread attention condition has higher precedence,
    and its domain lifecycle is unchanged.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.mothership
    note: Mothership classifier/store/API full-suite evidence
  - kind: test
    ref: test-runs/6.ground-control
    note: null
  - kind: test
    ref: test-runs/6.mothership
    note: null
  comment: null
- id: ac15
  text: Given an archived item is pinned, when the pin action is committed, then it
    becomes active; given that same item is later unpinned, then classification immediately
    falls back to the applicable manual, restore, lifecycle, linkage, or inactivity
    rule without altering domain lifecycle.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.mothership
    note: Mothership classifier/store/API full-suite evidence
  - kind: test
    ref: test-runs/6.ground-control
    note: null
  - kind: test
    ref: test-runs/6.mothership
    note: null
  comment: null
- id: ac16
  text: Given archive, restore, pin, or unpin requests are retried with the same mutation
    identity, when Mothership processes the retries, then the durable inbox outcome
    is the same as processing the logical mutation once.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.mothership
    note: Mothership classifier/store/API full-suite evidence
  - kind: test
    ref: test-runs/6.ground-control
    note: null
  - kind: test
    ref: test-runs/6.mothership
    note: null
  comment: null
- id: ac17
  text: Given conflicting inbox mutations are submitted from two devices, when both
    are committed, then every subsequent read on both devices reflects the same result
    based on Mothership's authoritative mutation order; tests cover archive versus
    restore, pin versus unpin, and archive versus pin races.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.mothership
    note: Mothership classifier/store/API full-suite evidence
  - kind: test
    ref: test-runs/6.ground-control
    note: null
  - kind: test
    ref: test-runs/6.mothership
    note: null
  comment: null
- id: ac18
  text: Given a Mothership thread or spec list request explicitly uses active, archived,
    or all, when results are returned, then every result matches the requested classifier
    state, all includes both states, and each result exposes its computed inbox state
    and archive reason, with archive reason absent or null for active items.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.mothership
    note: Mothership classifier/store/API full-suite evidence
  - kind: test
    ref: test-runs/6.ground-control
    note: Ground Control data/UI full-suite evidence
  - kind: test
    ref: test-runs/6.mothership
    note: null
  comment: null
- id: ac19
  text: Given an existing Mothership API consumer omits the inbox filter, when it
    lists or searches threads or specs, then the effective filter is all and records
    are not excluded due to inbox classification.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.mothership
    note: Mothership classifier/store/API full-suite evidence
  - kind: test
    ref: test-runs/6.ground-control
    note: Ground Control data/UI full-suite evidence
  - kind: test
    ref: test-runs/6.mothership
    note: null
  comment: null
- id: ac20
  text: Given a search term and an active, archived, or all filter, when thread or
    spec search is executed, then matching is restricted to the selected filter and
    returns the same classification and archive reason as the corresponding list/read
    API.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.mothership
    note: Mothership classifier/store/API full-suite evidence
  - kind: test
    ref: test-runs/6.ground-control
    note: Ground Control data/UI full-suite evidence
  - kind: test
    ref: test-runs/6.mothership
    note: null
  comment: null
- id: ac21
  text: Given Ground Control opens the thread inbox or spec inbox on Android, then
    Active is the default selected tab, an Archived tab is available, and each tab
    displays only items classified for that tab by Mothership.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/6.ground-control
    note: Ground Control data/UI full-suite evidence
  - kind: test
    ref: test-runs/6.mothership
    note: null
  comment: null
- id: ac22
  text: Given a user searches from either the Active or Archived Ground Control tab
    for threads or specs, then results remain scoped to that tab and include matching
    items from the durable Mothership state.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/6.ground-control
    note: Ground Control data/UI full-suite evidence
  - kind: test
    ref: test-runs/6.mothership
    note: null
  comment: null
- id: ac23
  text: Given a Ground Control user views an item, then pin is available for an unpinned
    item, unpin is available for a pinned item, archive is available when a manual
    archive can change its inbox outcome, and restore is available for an archived
    item; after a successful action, another device displays the same durable state
    after refresh or synchronization.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/6.ground-control
    note: Ground Control data/UI full-suite evidence
  - kind: test
    ref: test-runs/6.mothership
    note: null
  comment: null
- id: ac24
  text: Given any archive, restore, pin, or unpin action, when storage and API records
    are inspected, then no thread, spec, message, WorkItem/task, lifecycle record,
    or associated content has been deleted, and the item remains retrievable through
    the all filter and applicable search.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.mothership
    note: Mothership classifier/store/API full-suite evidence
  - kind: test
    ref: test-runs/6.ground-control
    note: Ground Control data/UI full-suite evidence
  - kind: test
    ref: test-runs/6.mothership
    note: null
  comment: null
- id: ac25
  text: Automated tests in mothership cover classifier precedence, exact seven-day
    boundaries, linked and unlinked thread rules, all listed spec lifecycle states,
    archive reasons, mutation retries and races, search/filter behavior, compatibility
    defaults, and non-deletion; automated Android tests in ground-control cover default
    tabs, tab-scoped search, all four actions, and cross-device/server-backed state
    refresh.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.mothership
    note: Mothership classifier/store/API full-suite evidence
  - kind: test
    ref: test-runs/6.ground-control
    note: Ground Control data/UI full-suite evidence
  - kind: test
    ref: test-runs/6.mothership
    note: null
  comment: null
open_questions: []
non_goals:
- Changing thread, WorkItem/task, or spec lifecycle states as a side effect of inbox
  actions
- Deleting threads, specs, messages, lifecycle history, or inbox-action history
- Changing the compatibility default for existing Mothership API consumers from all
- Designing or modifying fleet behavior
- Designing or modifying relay behavior
- Introducing classification rules for item types other than threads and specs
risks:
- Ambiguous timestamp handling could produce inconsistent results at the exact seven-day
  boundary; classification must use a single authoritative time basis and define the
  window as elapsed time strictly less than seven days.
- Concurrent archive, restore, pin, and unpin requests from multiple devices could
  regress state unless mutations have deterministic server-authoritative ordering
  and idempotent retry behavior.
- Incorrect precedence could hide pinned items or threads requiring user attention,
  or could allow restore grace to override a later manual archive.
- Search and tab counts could disagree if filtering and classification are implemented
  by separate logic instead of the shared Mothership classifier.
- Legacy consumers could unexpectedly lose records if active is applied when the filter
  is omitted.
- Incomplete archive-reason propagation could make Ground Control state difficult
  to explain or test.
task_slug: ground-control-active-and-archived
work_item_id: wi-20260825182251-cf7afea3
clarification_reason: null
prose_verdicts: {}
---
## Problem

Mothership currently lacks a durable, cross-device distinction between inbox visibility and domain lifecycle for threads and specs. As a result, Ground Control cannot consistently present active versus archived inboxes, preserve user pin/archive/restore choices across devices, or explain why an item is archived without conflating inbox actions with lifecycle state.

## User story

As a Ground Control user, I want searchable Active and Archived views for threads and specs, with durable pin, unpin, archive, and restore actions, so that I can manage inbox visibility consistently across devices without deleting items or changing their underlying thread, WorkItem/task, or spec lifecycle state.

## Approach

Add optional durable inbox metadata to Mothership threads and specs for pin, manual archive, restore, and the timestamps/order needed to resolve those actions. Keep this metadata separate from domain lifecycle fields. Provide one shared Mothership classifier that returns an inbox state of active or archived plus an archive reason. Apply classification in this order: (1) a pinned item is active; (2) a thread with needs-you work or an unanswered decision is active; (3) when a manual archive is later than the latest restore, the item is archived immediately with reason manual; (4) otherwise, a restore grants active status for the half-open interval from the restore time through, but not including, seven days later; (5) remaining threads linked to a terminal WorkItem/task are archived with reason linked_terminal; (6) remaining unlinked threads are active until seven days after their latest activity and archived with reason inactive_unlinked at the exact seven-day boundary; (7) remaining specs in draft, needs_review, approved, or dispatched are active; (8) remaining implemented specs are active until seven days after their latest implementation or update timestamp and archived with reason implemented at the exact seven-day boundary; and (9) remaining lifecycle-archived specs are archived immediately with reason lifecycle_archived. A restored terminal linked thread, implemented spec beyond its normal window, or lifecycle-archived spec is therefore active for seven days without changing its lifecycle; a subsequent manual archive ends that grace immediately unless a higher-precedence pin or thread attention condition applies. Expose Mothership list/search filters for active, archived, and all, including inbox state and archive reason in results. Preserve all as the default when existing consumers omit the filter. Persist pin, unpin, archive, and restore mutations with deterministic authoritative ordering so concurrent or retried requests converge on the same classification across devices. Update Ground Control on Android to default to searchable Active and Archived tabs for both threads and specs and expose the four inbox actions appropriate to the current item state. All records remain queryable through all/search paths, and no inbox action deletes data.

## Archive reasons

The classifier exposes stable reasons for archived items: manual, linked_terminal, inactive_unlinked, implemented, and lifecycle_archived. Active items do not expose an archive reason.

## Durability and compatibility

Mothership is authoritative for inbox metadata and classification. Ground Control does not maintain an independent classification source of truth. Inbox metadata is optional so existing records remain valid, and omission of the API filter continues to mean all for compatibility.
