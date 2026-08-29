---
id: gc-pr-merge-cockpit-mos-208
title: 'Review-Merge cockpit: in-app PR detail + Merge (mship serve PR surface)'
status: approved
created_at: '2026-07-13T23:05:20.804903Z'
updated_at: '2026-07-14T11:47:48.576841Z'
affected_repos:
- mothership
- ground-control
acceptance_criteria:
- id: ac1
  text: "mship serve exposes a live PR-detail read endpoint (GET /items/{id}/prs)\
    \ returning, per the item's task PRs, the title, mergeable state, checks status,\
    \ review decision, and diff stats \u2014 fetched live via gh, not the persisted\
    \ snapshot."
  verdict: approved
  evidence: []
  comment: null
- id: ac2
  text: mship serve exposes a merge write endpoint that runs gh pr merge --squash
    --delete-branch, gated fail-closed (rejects with 409 unless the PR is mergeable
    with checks green); it is the first PR-mutating route and is protected by the
    existing bearer.
  verdict: approved
  evidence: []
  comment: null
- id: ac3
  text: On a successful merge, the item's needs_review attention clears (the PR is
    recorded merged; the derivation excludes merged PRs), so the Queue needs-review
    card and the review cockpit both reflect it.
  verdict: approved
  evidence: []
  comment: null
- id: ac4
  text: Ground Control's review cockpit shows each PR's checks / diff-stats / mergeable
    state and a Merge button enabled only when the fail-closed gate passes, with a
    confirm dialog before merging.
  verdict: approved
  evidence: []
  comment: null
- id: ac5
  text: "The Queue tab's needs-review card opens the in-app review cockpit (not the\
    \ browser), so review\u2192merge happens in-app."
  verdict: approved
  evidence: []
  comment: null
- id: ac6
  text: A coordinated multi-PR item shows its PRs' detail but the in-app Merge is
    not offered (deferred to browser/CLI).
  verdict: approved
  evidence: []
  comment: null
- id: ac7
  text: Merging does not tear down the worktree/branch locally (mship close stays
    separate); the worktree is left intact.
  verdict: approved
  evidence: []
  comment: null
open_questions: []
non_goals:
- "Coordinated multi-PR merge (out-of-order hazard) \u2014 a multi-PR item shows its\
  \ PRs read-only; the merge is deferred to browser/CLI in v1."
- "Admin/force override \u2014 never merge a not-mergeable PR or one past failing\
  \ checks from the phone."
- "A merge-strategy picker \u2014 squash + delete-branch is hard-coded."
- "Auto worktree teardown / mship close \u2014 stays a separate deliberate step; merge\
  \ leaves the worktree intact."
- Rebase / merge-commit strategies; a per-line diff view (diff STATS only, not the
  full diff).
risks:
- The live-gh read endpoint adds latency and depends on gh auth on the serve host
  (unlike today's offline snapshot); N PRs = N gh calls. A failed gh detail must degrade
  per-PR, not blank the cockpit.
- The merge is consequential and irreversible from the phone; the fail-closed gate
  + confirm mitigate, but the only auth is the single app-wide bearer (no step-up).
- "Post-gate race: checks/mergeable can change between the gate read and the gh pr\
  \ merge, so the merge can still fail \u2014 surface the error and record merged\
  \ ONLY if gh succeeded (no inconsistent state)."
- "The needs_review-on-merge change touches the attention derivation that feeds the\
  \ Queue (MOS-225) and Home \u2014 it must not regress needs_review for still-open\
  \ PRs."
- The in-app Merge must be reliably hidden for coordinated multi-PR items, or it could
  merge one PR of an ordered set out of order.
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

The Queue tab (MOS-225) surfaces a needs-review card when a task has an open PR, but its only action is 'Open PR' which kicks the operator out to the system browser — both to see the PR's real status and to merge. mship serve has no PR surface at all: PRManager only does read/create gh calls (no gh pr merge, no gh pr view --json checks/files/mergeable/reviewDecision) and is exposed by no route, so the client only ever sees an offline snapshot (PR URL + local test status from state.yaml at finish time), never live GitHub. So the review→merge step — the whole point of a phone control plane for reviews — can't happen in-app.

## User story

As an operator reviewing finished work from my phone, I want to see a PR's live checks, diff stats, and mergeable state and tap Merge right in Ground Control, so that I can land reviewed work without leaving the app for the browser.

## Approach

Add a mship serve PR surface and wire an in-app PR detail + Merge into Ground Control's review cockpit, per the operator's merge-from-phone contract (2026-07-13): squash + delete-branch (hard-coded); the Merge is enabled ONLY when GitHub reports the PR mergeable with checks green (fail-closed, 409 otherwise — no admin/force override from the phone); a confirm dialog before merging; single-PR items only in v1 (a coordinated multi-PR item shows its PRs but the in-app Merge is deferred to browser/CLI so nothing merges out of order); and merging CLEARS the item's needs-review so its Queue card leaves immediately, while worktree cleanup (mship close) stays a separate deliberate step (merge leaves the worktree intact). Serve: PRManager gains get_pr_detail(url) (gh pr view --json title,state,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup,files,additions,deletions) and merge_pr(url) (gh pr merge --squash --delete-branch, the first PR-mutating wrapper); a read endpoint GET /items/{id}/prs returns live PrDetail per task PR; a merge endpoint POST /items/{id}/prs/merge re-reads detail, gates fail-closed, merges, records the PR merged, and returns updated detail (mirrors the /exec + /items/{id}/phase write-route idioms; protected by the existing app-wide bearer). needs_review clears on merge by recording merged PRs on the task and changing compute_attention.needs_review (core/view/workitem_index.py) from 'any task has a PR' to 'any task has an UN-merged PR' — the exact merged-record field resolved in the plan, and it must not regress needs_review for still-open PRs. Ground Control: a PrDetail DTO + SpecApi.getPrDetail/mergePr; the review cockpit (ui/review) gains per-PR checks/diff/mergeable badges + a gated Merge button + a confirm dialog; and the Queue needs-review card is rewired to open the in-app review cockpit (review/{connId}/{itemId}) instead of the browser. Two repos.

## Architecture

Serve: PRManager.get_pr_detail / merge_pr are thin gh wrappers over the injected ShellRunner (unit-tested with MagicMock(spec=ShellRunner) per tests/core/test_pr.py). Routes go in the items section of core/serve.py; PRManager is exposed via app.state or a handler-local instance mirroring /exec's fresh-ShellRunner pattern; the merge route re-reads detail and gates before mutating (fail-closed). needs_review is updated in core/view/workitem_index.py to exclude merged PRs, with the merged record set by the merge endpoint (and/or the existing PrWatcher terminal-state detection). Endpoint tests use TestClient(create_app(...)) + a fake/monkeypatched ShellRunner (per tests/core/test_serve_gh_token.py).

Ground Control: a PrDetail DTO + SpecApi.getPrDetail/mergePr (the existing one-liner client pattern; 409 → ApiConflictException). ReviewViewModel fetches live detail and exposes a per-PR canMerge (from the gate) + a merge(url) action with in-flight + typed-error handling; ReviewScreen renders check/diff/mergeable badges + a gated Merge button + a confirm dialog; GroundControlApp routes the Queue needs-review card to review/{connId}/{itemId}.

## Testing

Serve unit: get_pr_detail composes the right gh ... --json ... and parses it; merge_pr composes gh pr merge --squash --delete-branch; both via MagicMock(spec=ShellRunner). Serve endpoint: GET /items/{id}/prs returns detail (fake ShellRunner); the merge endpoint rejects 409 when not mergeable/checks-failing, merges when green and records merged so needs_review flips false; bearer-401 on the merge route; a post-gate gh failure does NOT record merged. needs_review derivation: a task with only merged PRs is not needs_review; a task with an open PR still is.

Ground Control (JVM unit tests only): getPrDetail/mergePr hit the right paths + auth (Ktor MockEngine); ReviewViewModel computes canMerge from the gate, surfaces the 409 rejection, and refreshes on merge success; the Merge button is absent for a multi-PR coordinated item.
