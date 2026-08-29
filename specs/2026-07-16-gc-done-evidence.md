---
id: gc-done-evidence
title: AC evidence on the done/completion view (shared with the review page)
status: implemented
created_at: '2026-07-16T18:56:00.887454Z'
updated_at: '2026-07-17T00:54:22.208372Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: "The done view (DoneScreen) renders an 'Acceptance criteria' section \u2014\
    \ each criterion with its verdict + evidence \u2014 for a done item with a bound\
    \ spec, matching the review page."
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac2
  text: Commit-kind evidence on the done view is tappable when the item has a single
    PR and opens `<pr-url>/commits/<sha>` (valid on the merged PR); multi-repo commits
    and test evidence are read-only; artifact URLs open.
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac3
  text: "The evidence rendering and the evidenceOpenUrl link logic are a SINGLE shared\
    \ component used by BOTH ReviewScreen and DoneScreen \u2014 no duplicated implementation."
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac4
  text: A done item with no bound spec renders the done view unchanged (no acceptance-criteria
    section).
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac5
  text: "Extracting the shared component does not change the review page's existing\
    \ behavior \u2014 the existing review tests still pass."
  verdict: unreviewed
  evidence: []
  comment: null
open_questions: []
non_goals:
- "Any mship serve change \u2014 evidence is already served."
- "A dedicated archived-items detail view \u2014 archived items inherit the done view\
  \ if they route to it."
- "Adding/editing evidence from the done view \u2014 read-only display."
- Multi-repo commit->repo attribution (still single-PR only, inherited from gc-review-page).
risks:
- "The shared-component extraction must preserve ReviewScreen's behavior \u2014 the\
  \ existing review-page tests are the guard."
- 'Merged-PR commit URLs must resolve: GitHub keeps a merged PR''s commits at /pull/<N>/commits/<sha>,
  so the deep link still works post-merge.'
- "DoneViewModel already calls getReview for the summary \u2014 prefer taking criteria\
  \ from that existing fetch (or getSpec) rather than adding a redundant round-trip."
task_slug: gc-done-evidence
work_item_id: wi-20260716193424-918f51b6
clarification_reason: null
prose_verdicts: {}
---
## Problem

The review page now shows each acceptance criterion + its evidence with commit deep-links (gc-review-page). But once an item is done/closed/archived it renders via the completion view (DoneScreen), which only shows a spec-summary line — you lose the per-criterion evidence and the jump-to-commit. You should still be able to review what satisfied each criterion after it shipped.

## User story

As the operator, when I open a done/closed/archived item, I want the same acceptance criteria + evidence (with commit deep-links into the merged PR) the review page shows, so I can review what shipped after the fact.

## Approach

- **Share, don't duplicate.** Extract the review page's evidence rendering into a shared component: the pure `evidenceOpenUrl` and a shared composable (the criterion + evidence rows / an 'Acceptance criteria' section), so ReviewScreen and DoneScreen render identically from one source.
- **DoneViewModel:** surface `criteria` + `prUrls` on DoneContent. It already fetches the item's review (for the summary counts) and the tasks (for pr_urls); take the acceptance criteria from that same review/spec fetch (no extra round-trip where avoidable) and the PR urls from the tasks.
- **DoneScreen:** render the shared Acceptance-criteria section below the existing summary. Commit evidence deep-links to `<pr-url>/commits/<sha>` — still valid on a merged PR (GitHub keeps a merged PR's commits).
- **Scope:** the done/completion view (DoneScreen), where done + closed items land; archived items that route to the done view inherit it. There is no separate archived-item detail view to change.
