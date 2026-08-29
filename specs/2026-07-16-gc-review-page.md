---
id: gc-review-page
title: 'GC review page: acceptance-criteria evidence + commit deep-links'
status: implemented
created_at: '2026-07-16T16:46:33.477720Z'
updated_at: '2026-07-16T17:31:44.947544Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: When a review-phase item has a bound spec (specId != null), the review page
    fetches it via getSpec(specId) and renders an 'Acceptance criteria' section below
    the PR rows; each criterion shows its text, verdict, and its evidence items.
  verdict: approved
  evidence: []
  comment: null
- id: ac2
  text: A commit-kind evidence item is rendered as a tappable control; when the item
    has exactly one PR url, tapping it opens `<pr-url>/commits/<sha>` (sha = evidence
    ref) via the system browser.
  verdict: approved
  evidence: []
  comment: null
- id: ac3
  text: When the item has more than one PR url (multi-repo), commit evidence is shown
    read-only (not tappable), because a bare commit SHA can't be reliably attributed
    to a repo/PR.
  verdict: approved
  evidence: []
  comment: null
- id: ac4
  text: Artifact-kind evidence whose ref is an http(s) URL is tappable and opens that
    URL; other artifact refs are shown read-only.
  verdict: approved
  evidence: []
  comment: null
- id: ac5
  text: Test-kind evidence is shown read-only.
  verdict: approved
  evidence: []
  comment: null
- id: ac6
  text: A review-phase item with no bound spec (bug/chore) renders the review page
    exactly as before, with no acceptance-criteria section.
  verdict: approved
  evidence: []
  comment: null
- id: ac7
  text: Evidence label formatting reuses the existing ui/specdetail/Evidence.kt helpers,
    and the commit/URL open uses the existing LocalUriHandler.openUri pattern wrapped
    to survive a missing browser.
  verdict: approved
  evidence: []
  comment: null
open_questions: []
non_goals:
- "Any mship serve change \u2014 evidence is already in GET /specs/{id}."
- Multi-repo commit->repo attribution (needs a repo hint on commit evidence); commit
  deep-linking is single-PR only in v1.
- "Adding/editing evidence from the review page \u2014 this is read-only display."
- Changing the spec-detail page (SpecDetailScreen); this is the review-phase page
  (ReviewScreen).
risks:
- "Multi-repo ambiguity: a commit SHA has no repo hint and pr_urls is per-repo \u2014\
  \ mitigated by gating tappability on single-PR items and deferring multi-repo attribution."
- "Extra network fetch (getSpec) per review-page load \u2014 minor; guarded on specId\
  \ != null and runs alongside the existing per-task fetches."
- 'The commit URL must resolve on GitHub: GitHub accepts short and full SHAs at /pull/<N>/commits/<sha>,
  so a bare ref works; if a ref is somehow not a commit in that PR the link 404s (acceptable,
  read-only fallback exists via the PR link).'
task_slug: gc-review-page
work_item_id: wi-20260716165337-cf7c646e
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

When a WorkItem/task is in the review phase (PR open), Ground Control's review detail page shows the PR link but not the acceptance-criteria evidence gathered during the build. To review the code, the operator has to leave the app and hunt through the PR. The evidence model already knows which commits satisfy which criteria — GC just doesn't surface it, and can't jump straight to a commit in the PR for a mobile code review.

## User story

As the operator, when I open a review-phase item with an open PR, I want to see each acceptance criterion with its evidence, and tap a commit-kind piece of evidence to open that exact commit inside the PR on GitHub mobile — so I can review the code behind each criterion without leaving to dig through the PR.

## Approach

GC-only — the evidence is already served. `GET /specs/{id}` (and `/specs/{id}/review`) already return `acceptance_criteria[].evidence` as {kind, ref, note}, and the DTOs already model it (SpecRecord.acceptanceCriteria -> ReviewCriterion.evidence -> Evidence). No serve change.

- **Fetch:** ReviewViewModel.fetch() (which today calls getItem + getTask per slug) also calls api.getSpec(item.specId) when specId != null, and threads the acceptance criteria into ReviewContent.
- **Render:** below the existing PR rows, an 'Acceptance criteria' section, grouped by criterion — each shows its text, verdict, and evidence items. Reuse the existing ui/specdetail/Evidence.kt helpers (evidenceLabels / isUnverified) for labels.
- **Commit deep-link:** a commit-kind evidence item is tappable; tapping opens `<pr-url>/commits/<sha>` (sha = evidence.ref) via the existing LocalUriHandler/openUri pattern (wrapped in runCatching like ExternalLinksRow, to survive no-browser). That opens the commit inside the PR on GitHub mobile.
- **Repo attribution:** commit evidence carries no repo hint, and pr_urls is a per-repo map. So enable commit deep-linking only when the item has exactly ONE PR url (single repo) — unambiguous. With multiple PRs (multi-repo), show commit evidence read-only. Per-repo attribution (a repo hint on commit evidence) is a documented follow-up needing a serve change.
- **Other evidence kinds:** artifact evidence whose ref is an http(s) URL is tappable -> opens the URL; otherwise read-only. Test evidence is read-only (internal ref).
- **No-spec items:** bug/chore items have no bound spec, so the review page renders unchanged.
