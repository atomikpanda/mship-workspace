---
id: fix-435-remote-exec-lock
title: Serialize remote execution per task
status: implemented
created_at: '2026-08-14T22:30:36.443018Z'
updated_at: '2026-08-15T21:48:52.715023Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: '`core/remote_exec.py` makes public `run_verb_stream` the sole per-task lock
    owner and holds the lock while iterating the complete existing execution generator.'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3:mothership
    note: Post-review recorded suite passed with no regressions
  - kind: test
    ref: test-runs/3.mothership
    note: null
  - kind: test
    ref: test-runs/4:mothership
    note: Final HEAD recorded suite passed after PR review compatibility fixes
  - kind: test
    ref: test-runs/8:mothership
    note: 'Final PR head fafa71f: full recorded suite passed after platform-boundary,
      optional-fcntl, ASGI, lifecycle, and security corrections; no regressions'
  - kind: test
    ref: test-runs/10:mothership
    note: 'Final PR head 9d98a2e: full recorded suite passed after idle-disconnect
      monitoring and all prior lifecycle, platform, compatibility, security, and locking
      corrections; no regressions'
  comment: null
- id: ac2
  text: The lock path is `<workspace_root>/.mothership/remote-exec-locks/<full lowercase
    SHA-256 of the raw task>.lock`, so even direct internal callers cannot turn a
    task value into path traversal.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3:mothership
    note: Post-review recorded suite passed with no regressions
  - kind: test
    ref: test-runs/3.mothership
    note: null
  - kind: test
    ref: test-runs/4:mothership
    note: Final HEAD recorded suite passed after PR review compatibility fixes
  - kind: test
    ref: test-runs/8:mothership
    note: 'Final PR head fafa71f: full recorded suite passed after platform-boundary,
      optional-fcntl, ASGI, lifecycle, and security corrections; no regressions'
  - kind: test
    ref: test-runs/10:mothership
    note: 'Final PR head 9d98a2e: full recorded suite passed after idle-disconnect
      monitoring and all prior lifecycle, platform, compatibility, security, and locking
      corrections; no regressions'
  comment: null
- id: ac3
  text: Lock acquisition uses exclusive nonblocking `fcntl.flock`; same-task contention
    is refused immediately without queueing or polling.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3:mothership
    note: Post-review recorded suite passed with no regressions
  - kind: test
    ref: test-runs/3.mothership
    note: null
  - kind: test
    ref: test-runs/4:mothership
    note: Final HEAD recorded suite passed after PR review compatibility fixes
  - kind: test
    ref: test-runs/8:mothership
    note: 'Final PR head fafa71f: full recorded suite passed after platform-boundary,
      optional-fcntl, ASGI, lifecycle, and security corrections; no regressions'
  - kind: test
    ref: test-runs/10:mothership
    note: 'Final PR head 9d98a2e: full recorded suite passed after idle-disconnect
      monitoring and all prior lifecycle, platform, compatibility, security, and locking
      corrections; no regressions'
  comment: null
- id: ac4
  text: While one same-task stream is active, a contender emits an actionable already-running
    error followed by the existing nonce-tagged exit sentinel with status 2 and makes
    zero repository, setup, verb, artifact, cleanup, shell-run, or shell-stream calls.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3:mothership
    note: Post-review recorded suite passed with no regressions
  - kind: test
    ref: test-runs/3.mothership
    note: null
  - kind: test
    ref: test-runs/4:mothership
    note: Final HEAD recorded suite passed after PR review compatibility fixes
  - kind: test
    ref: test-runs/8:mothership
    note: 'Final PR head fafa71f: full recorded suite passed after platform-boundary,
      optional-fcntl, ASGI, lifecycle, and security corrections; no regressions'
  - kind: test
    ref: test-runs/10:mothership
    note: 'Final PR head 9d98a2e: full recorded suite passed after idle-disconnect
      monitoring and all prior lifecycle, platform, compatibility, security, and locking
      corrections; no regressions'
  comment: null
- id: ac5
  text: Normal exhaustion, successful execution, task-reported failure, unexpected
    exception, explicit generator close, and `GeneratorExit`/client disconnect all
    release the lock; the same task can execute again afterward.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3:mothership
    note: Post-review recorded suite passed with no regressions
  - kind: test
    ref: test-runs/3.mothership
    note: null
  - kind: test
    ref: test-runs/4:mothership
    note: Final HEAD recorded suite passed after PR review compatibility fixes
  - kind: test
    ref: test-runs/8:mothership
    note: 'Final PR head fafa71f: full recorded suite passed after platform-boundary,
      optional-fcntl, ASGI, lifecycle, and security corrections; no regressions'
  - kind: test
    ref: test-runs/10:mothership
    note: 'Final PR head 9d98a2e: full recorded suite passed after idle-disconnect
      monitoring and all prior lifecycle, platform, compatibility, security, and locking
      corrections; no regressions'
  comment: null
- id: ac6
  text: Two streams for different task values use different locks and can execute
    concurrently.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3:mothership
    note: Post-review recorded suite passed with no regressions
  - kind: test
    ref: test-runs/3.mothership
    note: null
  - kind: test
    ref: test-runs/4:mothership
    note: Final HEAD recorded suite passed after PR review compatibility fixes
  - kind: test
    ref: test-runs/8:mothership
    note: 'Final PR head fafa71f: full recorded suite passed after platform-boundary,
      optional-fcntl, ASGI, lifecycle, and security corrections; no regressions'
  - kind: test
    ref: test-runs/10:mothership
    note: 'Final PR head 9d98a2e: full recorded suite passed after idle-disconnect
      monitoring and all prior lifecycle, platform, compatibility, security, and locking
      corrections; no regressions'
  comment: null
- id: ac7
  text: A multiprocessing test with explicit synchronization proves same-task exclusion
    across independent processes sharing one workspace.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3:mothership
    note: Post-review recorded suite passed with no regressions
  - kind: test
    ref: test-runs/3.mothership
    note: null
  - kind: test
    ref: test-runs/4:mothership
    note: Final HEAD recorded suite passed after PR review compatibility fixes
  - kind: test
    ref: test-runs/8:mothership
    note: 'Final PR head fafa71f: full recorded suite passed after platform-boundary,
      optional-fcntl, ASGI, lifecycle, and security corrections; no regressions'
  - kind: test
    ref: test-runs/10:mothership
    note: 'Final PR head 9d98a2e: full recorded suite passed after idle-disconnect
      monitoring and all prior lifecycle, platform, compatibility, security, and locking
      corrections; no regressions'
  comment: null
- id: ac8
  text: Failure to create the lock directory or open/acquire the lock file fails closed
    with an error and nonce-tagged nonzero exit sentinel before execution begins.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3:mothership
    note: Post-review recorded suite passed with no regressions
  - kind: test
    ref: test-runs/3.mothership
    note: null
  - kind: test
    ref: test-runs/4:mothership
    note: Final HEAD recorded suite passed after PR review compatibility fixes
  - kind: test
    ref: test-runs/8:mothership
    note: 'Final PR head fafa71f: full recorded suite passed after platform-boundary,
      optional-fcntl, ASGI, lifecycle, and security corrections; no regressions'
  - kind: test
    ref: test-runs/10:mothership
    note: 'Final PR head 9d98a2e: full recorded suite passed after idle-disconnect
      monitoring and all prior lifecycle, platform, compatibility, security, and locking
      corrections; no regressions'
  comment: null
- id: ac9
  text: Contention and lock-infrastructure errors preserve the existing HTTP 200 byte-stream
    framing and request nonce contract.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3:mothership
    note: Post-review recorded suite passed with no regressions
  - kind: test
    ref: test-runs/3.mothership
    note: null
  - kind: test
    ref: test-runs/4:mothership
    note: Final HEAD recorded suite passed after PR review compatibility fixes
  - kind: test
    ref: test-runs/8:mothership
    note: 'Final PR head fafa71f: full recorded suite passed after platform-boundary,
      optional-fcntl, ASGI, lifecycle, and security corrections; no regressions'
  - kind: test
    ref: test-runs/10:mothership
    note: 'Final PR head 9d98a2e: full recorded suite passed after idle-disconnect
      monitoring and all prior lifecycle, platform, compatibility, security, and locking
      corrections; no regressions'
  comment: null
- id: ac10
  text: Empty lock files may remain after release and do not prevent later acquisition;
    process termination relies on kernel descriptor cleanup rather than file deletion.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3:mothership
    note: Post-review recorded suite passed with no regressions
  - kind: test
    ref: test-runs/3.mothership
    note: null
  - kind: test
    ref: test-runs/4:mothership
    note: Final HEAD recorded suite passed after PR review compatibility fixes
  - kind: test
    ref: test-runs/8:mothership
    note: 'Final PR head fafa71f: full recorded suite passed after platform-boundary,
      optional-fcntl, ASGI, lifecycle, and security corrections; no regressions'
  - kind: test
    ref: test-runs/10:mothership
    note: 'Final PR head 9d98a2e: full recorded suite passed after idle-disconnect
      monitoring and all prior lifecycle, platform, compatibility, security, and locking
      corrections; no regressions'
  comment: null
- id: ac11
  text: All existing uncontended remote execution tests continue to pass, including
    materialization, setup, output, task-failure, nonce, artifact, cleanup, and disconnect
    behavior.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3:mothership
    note: Post-review recorded suite passed with no regressions
  - kind: test
    ref: test-runs/3.mothership
    note: null
  - kind: test
    ref: test-runs/4:mothership
    note: Final HEAD recorded suite passed after PR review compatibility fixes
  - kind: test
    ref: test-runs/8:mothership
    note: 'Final PR head fafa71f: full recorded suite passed after platform-boundary,
      optional-fcntl, ASGI, lifecycle, and security corrections; no regressions'
  - kind: test
    ref: test-runs/10:mothership
    note: 'Final PR head 9d98a2e: full recorded suite passed after idle-disconnect
      monitoring and all prior lifecycle, platform, compatibility, security, and locking
      corrections; no regressions'
  comment: null
open_questions: []
non_goals:
- Returning HTTP 409 or changing the existing HTTP 200 streaming contract
- Adding a blocking queue, wait mode, timeout, lock visibility endpoint, or execution-status
  UI
- Introducing per-repository or global execution locks
- Locking local task execution paths
- Changing persistent state or configuration schemas
- Deleting or garbage-collecting empty lock files
- Changing authentication or authorization
- Adding automatic retries for refused executions
- Refactoring unrelated remote execution code
risks:
- If `run_verb_stream` delegates to an inner generator without wrapping iteration
  in its own `try/finally`, the lock can be released before execution actually starts
  or remain held after a disconnect.
- If any repository mutation, shell helper, or stream helper runs before successful
  lock acquisition, a refused contender can still interfere with the active execution
  despite producing an already-running error.
- If the task identifier is normalized before hashing instead of hashing the exact
  raw task value, distinct raw task keys may collide semantically or the same intended
  lock may be derived inconsistently across call sites.
- If the lock descriptor is accidentally closed or garbage-collected while output
  is still being yielded, a second same-task execution can enter during setup, command
  execution, artifact handling, or cleanup.
- If generator-close and exception paths do not execute the release logic, a long-lived
  server process can retain the advisory lock and continue refusing valid executions.
- Workspace permission, read-only filesystem, descriptor exhaustion, or lock-directory
  path conflicts can prevent lock creation/opening; these conditions must refuse execution
  rather than silently running unlocked.
- '`fcntl.flock` is advisory and depends on filesystem support; a workspace hosted
  on a filesystem with broken or unsupported flock semantics may not provide reliable
  cross-process exclusion.'
- Changing early error framing can break clients that depend on the current nonce-tagged
  exit sentinel to detect completion and status even though the HTTP response remains
  200.
- Tests that only use threads or mocks can miss descriptor-inheritance and independent-process
  behavior; a real multiprocessing test is required to verify contention across `serve`
  processes.
- A multiprocessing test can become flaky if it relies on sleeps rather than explicit
  synchronization proving that the first process holds the lock before the contender
  starts.
task_slug: fix-435-remote-exec-lock
work_item_id: wi-20260814225644-4912544c
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

Mothership issue #435: two authenticated remote `/exec` streams for the same task can currently execute concurrently against the same task worktree. Their reset/clean, materialization, setup, verb execution, artifact handling, and cleanup phases can interleave, corrupt the worktree, remove or overwrite one another's files, and produce incorrect output or artifacts. In-memory coordination is insufficient because multiple `serve` processes may share the same host and workspace.

## User story

As an operator invoking remote task execution, I want Mothership to refuse a second concurrent `/exec` stream for the same task while allowing unrelated tasks to continue, so that each task worktree has at most one remote execution mutating it across all local server processes.

## Approach

In `core/remote_exec.py`, make the public `run_verb_stream` generator own a per-task advisory file lock for its complete lifetime. Derive the lock filename from the full lowercase SHA-256 digest of the raw task value and place it at `<workspace_root>/.mothership/remote-exec-locks/<full SHA-256 of raw task>.lock`. Create the lock directory and open the lock file, then attempt `fcntl.flock(..., LOCK_EX | LOCK_NB)` before invoking any existing execution path or causing any repository, setup, verb, artifact, or cleanup side effect. Keep the file descriptor open and the lock held across worktree materialization/reset/clean, setup, command streaming, artifact collection, cleanup, and all yielded output. On same-task contention, preserve HTTP 200 streaming semantics, emit an actionable already-running error, then emit the existing nonce-tagged exit sentinel with status 2; do not queue or invoke shell execution/streaming helpers. Treat lock-directory creation, lock-file opening, hashing/encoding, and lock acquisition errors other than ordinary contention as fail-closed stream errors followed by a nonzero nonce-tagged exit sentinel. Release and close the lock in `finally` on normal exhaustion, task failure, exceptions, explicit generator close, and `GeneratorExit`/client disconnect. Kernel process teardown provides release after process death; empty lock files may remain. Because the key is task-specific, different tasks retain existing concurrency.

## Implementation constraints

Keep the change in `core/remote_exec.py`. The outer public generator acquires the lock before entering the existing execution generator, iterates that generator while the descriptor remains open, and releases in `finally`. Distinguish ordinary `LOCK_NB` contention from filesystem or unsupported-lock failures so the former is actionable while every other failure remains fail-closed.

## Test strategy

Use deterministic synchronization rather than sleeps. Pause one stream after it has acquired the lock, attempt same-task and different-task contenders, close or release the first stream, and verify reacquisition. Use a shared temporary workspace plus separate processes for the cross-process proof. Reuse existing remote-exec fakes and framing assertions.
