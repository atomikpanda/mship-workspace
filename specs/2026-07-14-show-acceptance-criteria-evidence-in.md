---
id: show-acceptance-criteria-evidence-in
title: Show acceptance-criteria evidence in Ground Control
status: approved
created_at: '2026-07-14T16:38:24.460158Z'
updated_at: '2026-07-14T17:20:10.315317Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: The GC ReviewCriterion DTO carries an evidence list of {kind, ref, note} and
    ReviewSummary carries the unverified count, both parsed from the review / spec-detail
    payload and defaulting to empty for specs that have none (existing specs still
    deserialize).
  verdict: approved
  evidence:
  - kind: test
    ref: SpecEvidenceDtoTest
    note: criterion evidence + summary unverified parse
  - kind: commit
    ref: 8589eb7
    note: Evidence DTO + fields
  comment: null
- id: ac2
  text: In the spec-detail criteria display, each acceptance criterion renders its
    evidence as a list of typed entries (kind label + ref + optional note); a criterion
    with empty evidence shows a muted 'unverified' indicator.
  verdict: approved
  evidence:
  - kind: test
    ref: EvidenceDisplayTest
    note: isUnverified + evidenceLabels
  - kind: commit
    ref: 8589eb7
    note: CriterionRow renders evidence / unverified
  comment: null
- id: ac3
  text: The Queue CriteriaCard shows, per criterion, whether it is verified (listing
    its evidence refs) or unverified, so the operator sees verification status while
    approving from the card stack.
  verdict: approved
  evidence:
  - kind: test
    ref: QueueCardTest.criteria_card_items_carry_each_criterions_evidence
    note: null
  - kind: commit
    ref: 8589eb7
    note: Queue CriteriaCard verified/unverified
  comment: null
- id: ac4
  text: "Long evidence refs and multi-entry criteria render without overflowing the\
    \ card or hiding its action controls \u2014 content stays inside the existing\
    \ vertical scroll."
  verdict: approved
  evidence:
  - kind: commit
    ref: 8589eb7
    note: evidence lines maxLines=2 + ellipsis, inside card scroll
  comment: null
- id: ac5
  text: "The Queue review-card metadata line (spec title, kind\xB7repos) is capped\
    \ with maxLines + TextOverflow.Ellipsis so a spec touching many repos can't wrap\
    \ into a wall of text (the nit deferred from PR #50)."
  verdict: approved
  evidence:
  - kind: commit
    ref: 8589eb7
    note: QueueCardMeta title + kind/repos capped
  comment: null
open_questions: []
non_goals:
- "Attaching or editing evidence from the phone \u2014 evidence is recorded by the\
  \ implementing agent via `mship spec evidence`; this slice is display-only."
- "Changing the approval gate \u2014 evidence is never required to approve (the parent\
  \ ac-evidence-loop spec keeps approval_blockers unchanged); this only shows what\
  \ exists."
- "Any serve or API change \u2014 build_review already exposes evidence + the unverified\
  \ count; this is purely the Android rendering the parent spec listed as a non-goal."
risks:
- "Evidence refs can be long (commit shas, artifact paths) \u2014 they must truncate\
  \ or wrap gracefully without overflowing the card or hiding its action controls."
- "A criterion can carry several evidence entries \u2014 the per-criterion list must\
  \ stay scannable within the existing scrollable card rather than dominating it."
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

When approving finished work from the Queue or the spec detail in Ground Control, the operator sees each acceptance criterion's verdict but not the concrete evidence behind it — the test run, commit, or artifact that satisfies it. serve already records that evidence per-criterion (kind/ref/note) and exposes it, plus an unverified count, in the build_review payload behind GET /specs/{id}/review and every review card. Ground Control drops it today, so 'approved' still rests on trusting the agent rather than seeing the proof.

## User story

As an operator reviewing finished work in Ground Control, I want each acceptance criterion to show the concrete evidence that satisfies it — and to see which criteria have none — so that approving means the work demonstrably met its criteria rather than an agent merely claiming it did.

## Approach

GC-only, read-only display consuming the already-deployed build_review payload (no serve/API change). (1) DTO: add evidence: List<Evidence>{kind,ref,note} to ReviewCriterion and an unverified count to ReviewSummary, both defaulting to empty so specs without evidence still parse. (2) Spec-detail criteria list: under each criterion, render its evidence as a compact list of typed entries — a kind label (test/commit/artifact) + the ref + an optional note; a criterion with no evidence shows a muted 'unverified' marker. (3) Queue CriteriaCard: per criterion, show verified (with its evidence refs) vs unverified so the operator sees verification status while approving in the card stack. (4) Fold in the small nit deferred from PR #50: cap the review-card metadata title + kind·repos lines with maxLines + TextOverflow.Ellipsis so a many-repo spec can't wrap into a wall of text.

## Testing

JVM unit tests only (no emulator). Cover: (a) the DTO parses a review/spec payload whose criteria carry evidence entries + a non-zero unverified count, and one with none (defaults to empty, unverified=0); (b) a criteria-card helper classifies each criterion as verified (has evidence) vs unverified and surfaces its refs. Follow the existing QueueCardTest / SpecDetail test patterns.
