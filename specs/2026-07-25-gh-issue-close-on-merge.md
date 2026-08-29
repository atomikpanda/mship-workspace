---
id: gh-issue-close-on-merge
title: Close linked GitHub tracker issues on merge
status: implemented
created_at: '2026-07-25T02:34:32.808952Z'
updated_at: '2026-07-25T14:58:31.450439Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: '`mship item link-issue <id> <ref>` accepts #N, bare N, owner/repo#N, and
    a full GitHub issue URL, normalizes to owner/repo#N, stores it on the WorkItem''s
    external_links, and `mship item show` displays it; linking the same issue twice
    is a no-op'
  verdict: unreviewed
  evidence:
  - kind: commit
    ref: 62fd0ef
    note: 'link-issue: 4 ref forms normalized, deduped, shown in item show; 4 CLI
      tests'
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac2
  text: '`mship spawn --closes <ref>` (repeatable) and `mship spec dispatch --closes
    <ref>` link the issue(s) to the task''s WorkItem at creation time'
  verdict: unreviewed
  evidence:
  - kind: commit
    ref: 1f36c4c
    note: --closes on spawn+dispatch, validated before side effects; 4 CLI tests
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac3
  text: '`mship finish` appends a Closes trailer to each PR body for every linked
    issue (same-repo as #N, cross-repo as owner/repo#N), and does not alter bodies
    when no issues are linked'
  verdict: unreviewed
  evidence:
  - kind: commit
    ref: ea54709
    note: finish appends Closes trailers (short same-repo, full cross-repo); unchanged
      body when no links; 2 finish tests + 4 unit tests
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac4
  text: When all of a task's PRs are merged, both close-out triggers (mship close
    and the pr_watcher merge event) close every still-open linked issue via the GitHub
    API with a single 'Shipped in <repo>#<pr>' comment
  verdict: unreviewed
  evidence:
  - kind: commit
    ref: b4516ae
    note: close_linked_issues wired at both triggers (cli close + pr_watcher); Shipped-in
      comment from task.pr_urls
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac5
  text: 'Close-out is idempotent and fault-tolerant: an already-closed issue is skipped
    silently; an API failure (auth/permission/network) emits a warning naming the
    issue and never blocks the task close-out; running close-out twice produces no
    duplicate comments'
  verdict: unreviewed
  evidence:
  - kind: commit
    ref: 0ce109d
    note: idempotent (closed=skip, double-run no-op) + fault-tolerant (warn never
      raise; fail-open on corrupt store - test_finish_gate contract kept)
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac6
  text: Unit tests cover ref normalization (all four input forms + invalid refs rejected
    loudly), trailer injection, and the idempotent/fault-tolerant close paths (mocked
    API)
  verdict: unreviewed
  evidence:
  - kind: commit
    ref: b4516ae
    note: test_issue_refs (12 normalization/trailer tests) + test_issue_close (6 mocked-API
      tests) + CLI coverage
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
open_questions: []
non_goals:
- Auto-detecting issue references from prose in specs/PR bodies (explicit linking
  only in v1)
- Ground Control UI changes (linked issues already flow through the existing external_links
  API surface)
- Two-way sync (reopening the issue does not reopen the WorkItem; issue comments are
  not mirrored)
- Non-GitHub trackers (Linear etc. stay linkable via the generic link-url)
risks:
- Cross-repo close needs a credential with write access to the issue's repo - the
  gh CLI on the operator machine has it, but unattended/cloud close-out paths may
  not; failures must degrade to a loud warning + the issue staying open, never a blocked
  close
- Closing-keyword injection must not corrupt hand-authored --body-file bodies - append
  as a discrete trailer line, and only when issues are linked
- Idempotency across the two trigger points (pr_watcher event AND mship close may
  both fire for one task) - the already-closed check must make the second trigger
  a no-op
task_slug: gh-issue-close-on-merge
work_item_id: wi-20260725023900-7fbd98e6
clarification_reason: null
prose_verdicts: {}
---
## Problem

mship's merge close-out advances the spec (dispatched -> implemented) and the WorkItem, but never closes the originating GitHub tracker issue (mothership #386). Two gaps compound: spec-built PR bodies reference issues in prose, which GitHub does not treat as a closing keyword; and issues are often filed in one repo (mothership) while the fixing PR lands in another (ground-control), where a closing keyword cannot auto-close cross-repo without the owner/repo#N form. Result: shipped work lingers as open issues until someone closes them by hand - on 2026-07-19 this left three shipped issues open, and the operator's agent closed #366 and others manually this week.

## User story

As an operator, I want a task's linked GitHub tracker issues to close automatically when its PRs merge, so that the tracker reflects reality without manual close-out on every merge.

## Approach

Build on the existing WorkItem.external_links field rather than a new store. (1) Linking: add `mship item link-issue <work-item-id> <ref>` accepting `#N`, `N`, `owner/repo#N`, or a full GitHub issue URL; normalize to owner/repo#N (defaulting owner/repo from the affected repo's remote) and store as an ExternalLink with an issue kind. Also accept `--closes <ref>` (repeatable) on `mship spawn` and `mship spec dispatch` as sugar that links the issue to the task's WorkItem. Multiple issues per item; linking is optional. (2) Finish: for each PR body, `mship finish` injects a `Closes #N` / `Closes owner/repo#N` line for every linked issue, so GitHub auto-closes same-repo issues natively on merge. (3) Close-out: extend the existing merge close-out trigger points - the same places that call advance_spec_on_close / advance_workitem_on_close (mship close in cli/worktree.py and the pr_watcher merge event) - with a close_linked_issues step: for each linked issue still open, close it via the gh API with one comment 'Shipped in <repo>#<pr> (merged)'. Idempotent: already-closed issues are skipped without comment or error; a second run makes no changes. Failures to close (no auth, no permission) are surfaced as warnings, never block the close-out. (4) Visibility: linked issues render in `mship item show` and ride the existing external_links surface that serve already exposes to Ground Control - no GC changes required in this slice.
