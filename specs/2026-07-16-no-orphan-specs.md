---
id: no-orphan-specs
title: 'No orphan specs: tie every spec to a WorkItem + surface any needs_review spec
  in the Queue'
status: dispatched
created_at: '2026-07-16T19:17:58.882273Z'
updated_at: '2026-07-16T20:53:31.091969Z'
affected_repos:
- mothership
- ground-control
acceptance_criteria:
- id: ac1
  text: '`mship spec new` with no WorkItem provided auto-creates a feature WorkItem
    and links the new spec to it, so the spec is never orphaned.'
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac2
  text: '`mship spec from-thread` ties the resulting spec to a WorkItem (creating
    one if none exists).'
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac3
  text: "Moving a spec to needs_review (`mship spec apply`) when it has no WorkItem\
    \ auto-links one (or is refused) \u2014 there is no path to an orphaned needs_review\
    \ spec."
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac4
  text: The serve Queue/attention feed includes any needs_review spec that has no
    WorkItem, and GC renders it as an approvable Queue card.
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac5
  text: A spec that already has a WorkItem is unaffected (no duplicate WorkItem created);
    the WorkItem-first flow is unchanged.
  verdict: unreviewed
  evidence: []
  comment: null
open_questions: []
non_goals:
- Changing the WorkItem-first flow (mship item new + link-spec / spawn --work-item).
- "A one-time backfill retro-linking every historical standalone spec \u2014 the Queue\
  \ safety net surfaces them; a migration is optional and out of scope."
- Any change to how approved/dispatched specs flow.
risks:
- "Auto-creating a WorkItem on `spec new` could surprise flows that intentionally\
  \ create a throwaway/draft spec \u2014 mitigate by only auto-creating for specs\
  \ that reach needs_review, or make the WorkItem cheap + archivable."
- "The Queue feed change must not double-count a spec that has BOTH a WorkItem and\
  \ is surfaced as an orphan \u2014 dedupe by spec id."
- 'Idempotency: re-running spec new / link must not create duplicate WorkItems for
  the same spec.'
task_slug: no-orphan-specs
work_item_id: wi-20260716205331-8472d3de
clarification_reason: null
prose_verdicts: {}
---
## Problem

A spec can exist with no WorkItem: `mship spec new` creates a standalone spec, and `mship spec from-thread` links to a thread but not necessarily a WorkItem. GC's Queue is WorkItem-attention-based (needs_approval = a WorkItem's spec is needs_review), so an ORPHAN needs_review spec (no WorkItem) never appears in the approval funnel — the operator can't review it and it silently hides. This just happened with gc-done-evidence.

## User story

As the operator, every spec awaiting my review must appear in the Queue — and structurally, no spec should ever be orphaned from a WorkItem in the first place.

## Approach

Two layers — prevention (offense) + a safety net (defense):
- **Prevent orphans (mothership CLI):** the spec-creation paths tie the spec to a WorkItem. When no WorkItem is provided, `mship spec new` and `mship spec from-thread` auto-create a feature WorkItem and link the spec (and `mship spec apply`'s draft→needs_review transition ensures a WorkItem exists — auto-linking one if somehow absent). So a spec is never orphaned, at creation or at review.
- **Safety net (mothership serve + GC):** the Queue's attention feed also surfaces any needs_review spec that has NO WorkItem (legacy/edge), rendered as an approvable Queue card, so an orphan can never silently hide even if prevention is bypassed.
- **Enforcement point:** creation-time — every new spec gets a WorkItem the moment it's created, for the strongest 'never orphaned' invariant (the needs_review check is a backstop).
- The existing WorkItem-first flow (`mship item new` → `link-spec` / `spawn --work-item`) is unchanged; this only closes the standalone-spec gap.
