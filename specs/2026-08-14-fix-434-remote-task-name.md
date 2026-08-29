---
id: fix-434-remote-task-name
title: Harden remote exec task-name boundary
status: implemented
created_at: '2026-08-14T15:39:42.353301Z'
updated_at: '2026-08-14T18:19:45.387033Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: A public predicate in `core/run_ref.py` returns true for non-empty task-name
    segments containing only ASCII letters, digits, `.`, `_`, and `-`, except that
    bare `.` and bare `..` return false.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: Post-change recorded suite passed with no regressions
  comment: null
- id: ac2
  text: The predicate uses full-string matching, so inputs containing `/`, whitespace,
    shell metacharacters, or a trailing newline return false.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: Post-change recorded suite passed with no regressions
  comment: null
- id: ac3
  text: '`run_ref()`, `is_run_ref()`, and serve''s authenticated `POST /exec/{verb}`
    task-name validation use the same public predicate as their single validation-semantic
    owner.'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: Post-change recorded suite passed with no regressions
  comment: null
- id: ac4
  text: For each endpoint input `../escape`, `a/b`, `.`, `..`, the empty string, a
    value with a trailing newline, and a value containing shell metacharacters, the
    endpoint returns the existing HTTP 400 invalid-task-name response.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: Post-change recorded suite passed with no regressions
  comment: null
- id: ac5
  text: For every invalid endpoint case, tests prove zero fake shell run calls and
    zero fake shell stream calls; validation occurs before any `RemoteExecDeps` work
    or `StreamingResponse` creation and no filesystem or task work is performed.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: Post-change recorded suite passed with no regressions
  comment: null
- id: ac6
  text: The endpoint accepts a valid task name containing dots, underscores, and hyphens.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: Post-change recorded suite passed with no regressions
  comment: null
- id: ac7
  text: Direct `remote_exec` and `run_ref` validation remains in place as defense
    in depth.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: Post-change recorded suite passed with no regressions
  comment: null
- id: ac8
  text: All existing `run_ref` tests pass without behavioral changes.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: Post-change recorded suite passed with no regressions
  comment: null
- id: ac9
  text: Any stale test prose claiming that `/exec` accepts slash-containing task names
    is corrected.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: Post-change recorded suite passed with no regressions
  comment: null
- id: ac10
  text: The complete test suite relevant to serve, remote exec, and run refs passes.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: Post-change recorded suite passed with no regressions
  comment: null
open_questions: []
non_goals:
- Changing local task slug creation or introducing global slug validation
- Data migration
- Path normalization or a path-containment fallback
- Token or authentication redesign
- Configuration changes
- Unrelated refactors
risks:
- Accidental drift in existing run-ref validation behavior while extracting the public
  predicate; mitigate by preserving the exact semantics, routing all three consumers
  through the single predicate, and retaining the current run_ref test suite.
- Previously accepted slash-containing remote task names will be rejected; repository
  history indicates no task slugs with slashes in PR heads or branches.
task_slug: fix-434-remote-task-name
work_item_id: wi-20260814170742-4b66769a
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
  scope_risk:
    verdict: approved
    comment: null
---
## Problem

Issue #434: Authenticated POST /exec/{verb} accepts task names using serve.py regex `^[A-Za-z0-9._/-]+$`. Because `/` is allowed, inputs such as `../escape` can traverse outside `workspace_root/.worktrees` before remote filesystem writes and shell-backed git/task execution. The remote exec boundary must reject any task name that is not a safe run-ref segment.

## User story

As an operator of Mothership's authenticated remote exec endpoint, I want task names validated with the same exact safe-segment semantics as run refs so that crafted task names cannot escape the worktree namespace or reach filesystem, shell, or task execution.

## Approach

Promote the exact private safe-segment behavior in `core/run_ref.py` to a public predicate. The predicate accepts only non-empty full strings matching `[A-Za-z0-9._-]+`, except the bare values `.` and `..`; it rejects slash, whitespace, shell metacharacters, and trailing newlines. Make this predicate the single semantic owner used by `run_ref()`, `is_run_ref()`, and serve's `/exec/{verb}` task-name validation. In serve, validate the task name before constructing or invoking `RemoteExecDeps` and before creating a `StreamingResponse`. On failure, return the existing HTTP 400 invalid-task-name response and perform no filesystem, shell, stream, or task work. Retain direct validation in `remote_exec` and `run_ref` as defense in depth. Implement with strict TDD endpoint coverage and preserve all existing run-ref behavior.

## Issue

#434

## Security boundary

This change applies only to the authenticated remote exec boundary. Local task slug creation remains unchanged.

## Compatibility evidence

Historical PR heads and branches show no slash-containing task slugs.
