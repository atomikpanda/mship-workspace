---
id: auto-link-acceptance-criterion-evidence-finish-377
title: Auto-link acceptance-criterion evidence at finish (#377)
status: implemented
created_at: '2026-07-18T19:45:05.249110Z'
updated_at: '2026-07-19T14:12:58.280146Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: Given a spec-bound task finished with a passing test-run, after `mship finish`
    every acceptance criterion of the bound spec has that test-run reference attached
    as `test` evidence.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green
  - kind: commit
    ref: e8c60c0
    note: null
  comment: null
- id: ac2
  text: A commit whose message contains an acceptance-criterion id token (e.g. `ac7`)
    has that commit sha attached as `commit` evidence to exactly the AC(s) it names.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green
  - kind: commit
    ref: e8c60c0
    note: null
  comment: null
- id: ac3
  text: A commit message naming multiple AC ids (e.g. `ac1` and `ac3`) attaches that
    commit to all of the named ACs.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green
  - kind: commit
    ref: fa4f052
    note: null
  comment: null
- id: ac4
  text: A commit message naming no AC id attaches that commit to no AC and does not
    error.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green
  - kind: commit
    ref: fa4f052
    note: null
  comment: null
- id: ac5
  text: 'AC id matching is word-boundary safe: a message naming `ac7` does not attach
    to AC `ac70`, and an `ac7` substring inside another word (e.g. `reactor`) is not
    treated as a reference.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green
  - kind: commit
    ref: 2e85c81
    note: null
  comment: null
- id: ac6
  text: 'Auto-population is idempotent: running `mship finish` twice does not create
    duplicate evidence entries for the same (ref, kind, criterion).'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green
  - kind: commit
    ref: 6f4e735
    note: null
  comment: null
- id: ac7
  text: "Manually attached evidence (via `mship spec evidence`) is preserved \u2014\
    \ auto-linking only adds, never removes or overwrites existing evidence."
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green
  - kind: commit
    ref: 6f4e735
    note: null
  comment: null
- id: ac8
  text: The bound spec is resolved via the same path `mship finish` already uses (WorkItem
    `spec_id`, else approved-slug fallback); when no spec is bound, `mship finish`
    attaches nothing and does not error.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green
  - kind: commit
    ref: c65eabe
    note: null
  comment: null
- id: ac9
  text: After `mship finish`, the generated PR body's acceptance block renders the
    auto-attached evidence (checked criteria show their `test:`/`commit:` refs) using
    the existing renderer unchanged.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green
  - kind: commit
    ref: c4fda6d
    note: null
  comment: null
- id: ac10
  text: The test-run reference(s) attached match the task's recorded passing test-run
    iteration(s) for each affected repo.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green
  - kind: commit
    ref: f2112d8
    note: null
  comment: null
open_questions: []
non_goals:
- "Per-criterion test mapping (attaching a specific test to a specific AC) \u2014\
  \ the passing test-run is attached to ALL criteria; there is no AC-to-test linkage."
- "Parsing an implementation plan's AC-to-task map \u2014 the commit-message id scan\
  \ is the sole commit-to-AC mapping mechanism."
- "Changing the PR-body acceptance-block renderer \u2014 it already works when evidence\
  \ is present."
- "Auto-linking at `mship test` or `mship commit` time \u2014 the single hook is `mship\
  \ finish`."
- Attaching any evidence for tasks that are not bound to a spec.
risks:
- A commit that coincidentally contains an `acN`-shaped token could over-attach; mitigated
  by word-boundary matching and the low likelihood of `acN` appearing outside a deliberate
  reference.
- If a spec's AC ids are non-standard (not `ac<number>`), the commit scan won't match
  them; the test-run-to-all step still populates every AC so the PR body is never
  left fully empty.
- "Idempotency depends on comparing existing evidence entries; a future change to\
  \ the evidence entry shape could reintroduce duplicates \u2014 covered by an idempotency\
  \ test."
task_slug: auto-link-acceptance-criterion-evidence-finish-377
work_item_id: wi-20260718201257-3fae8106
clarification_reason: null
prose_verdicts: {}
---
## Problem

In Ground Control / subagent build flows, acceptance-criterion evidence is never attached to a spec, so the generated PR body renders every acceptance criterion as "no evidence" even when a passing test-run and implementing commits exist. Tonight (PRs #380/#381/#382) that evidence had to be attached entirely by hand. Crucially, the evidence RENDERING already works when evidence is present (proven live on #380/#381 where every AC showed its test:/commit: refs) — the only gap is that nothing populates the evidence automatically. See issue #377.

## User story

As an mship user finishing a spec-bound task, I want the passing test-run and the implementing commits attached to my acceptance criteria automatically, so the PR body shows a real evidence trail without any manual `mship spec evidence` calls.

## Approach

At `mship finish`, for a task bound to a spec, auto-populate acceptance-criterion evidence before the PR acceptance block is built: (1) attach the task's passing test-run reference(s) (e.g. `test-runs/<iter>.<repo>`) to EVERY acceptance criterion of the bound spec; (2) scan each commit on the finished branch (since its base) and attach that commit to any AC whose id token (e.g. `ac7`) appears in the commit message, matched on a WORD BOUNDARY so `ac7` never matches inside `reactor` or the id `ac70`. The bound spec is resolved exactly as `mship finish` already resolves it (WorkItem `spec_id`, else approved-slug fallback). Auto-population is idempotent (never duplicates an existing evidence entry for the same ref+kind+criterion) and additive (manual `mship spec evidence` attachments are preserved). A commit naming no AC id is a no-op. Non-spec-bound tasks (bugs/chores) are unaffected. The evidence renderer (`build_acceptance_block`) is unchanged — it already renders whatever evidence is present.
