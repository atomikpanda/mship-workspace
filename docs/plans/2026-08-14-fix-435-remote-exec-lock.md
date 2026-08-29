# Serialize Remote Execution Per Task Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refuse a second concurrent remote execution for one task before it can mutate the shared task worktree, while preserving concurrency between different tasks.

**Spec:** `fix-435-remote-exec-lock` (approved)

## Assumptions checked

- repo topology — covered: one affected repository, `mothership`; one task-level lock intentionally spans every repo named by a request and avoids per-repo lock ordering.
- credential locus — covered: `/exec` remains bearer-authenticated; this change coordinates already-authorized executions and does not alter token storage or verification.
- execution locus — covered: the lock is acquired on the remote serve host inside `run_verb_stream`, before base freshness, worktree materialization, setup, verb, artifact, or cleanup work.
- state durability — covered: advisory lock ownership is kernel/file-descriptor state; empty lock files persist under `.mothership/remote-exec-locks` but no workspace-state schema changes.
- review surface — covered: issue #435, approved spec `fix-435-remote-exec-lock`, deterministic lifecycle tests, a real multiprocessing test, the recorded suite, and pull-request review provide evidence.
- agent stream — covered: contention preserves the HTTP 200 byte stream and terminates it with the request nonce and exit status 2; infrastructure failures use the same framing with a nonzero status.
- dispatched model — N/A: model selection does not affect remote execution locking.

**Architecture:** Keep the current execution generator intact as a private unlocked implementation. The public `run_verb_stream()` acquires one nonblocking `fcntl.flock` keyed by the full SHA-256 digest of the raw task value, iterates the existing implementation while the descriptor remains open, and releases in `finally`. This single wrapper covers direct callers and FastAPI without moving lock lifetime into `StreamingResponse`.

**Tech Stack:** Python 3.14, `fcntl.flock`, SHA-256, FastAPI/Starlette streaming, pytest, `multiprocessing`, Mothership task/worktree lifecycle.

## Global Constraints

- Lock granularity is exactly one task across all repos in that request; different tasks must remain concurrent.
- Refuse immediately with `LOCK_EX | LOCK_NB`; do not queue, poll, retry, or introduce a timeout.
- Same-task contention emits `error: remote task '<task>' is already running; try again after it finishes\n`, then the existing nonce-tagged exit sentinel with status 2.
- Lock setup failures emit a named error plus a nonce-tagged nonzero sentinel and must fail closed before existing execution begins.
- Lock files live only at `<workspace_root>/.mothership/remote-exec-locks/<full lowercase SHA-256 of raw task>.lock`; do not use the task as a path segment.
- Do not change HTTP status, authentication, local task execution, state/config schemas, remote-client parsing, or lock-file cleanup.
- Preserve all existing materialization, setup, run-ref, output, artifact, process termination, capture-temp cleanup, and disconnect behavior.

---

<!-- mship:task id=1 acs=ac1,ac2,ac3,ac4,ac5,ac6,ac7,ac8,ac9,ac10,ac11 -->
### Task 1: Guard the Complete Remote Execution Stream

**Files:**
- Modify: `src/mship/core/remote_exec.py:53-70,357-639`
- Test: `tests/core/test_serve_exec.py:14-27,218-286`

**Interfaces:**
- Consumes: `RemoteExecDeps.workspace_root`, raw `task`, request `nonce`, the existing `run_verb_stream()` byte-stream contract, and the existing `_FakeShellRunner`/`_FakeProc` test seams.
- Produces: private `_acquire_task_execution_lock(workspace_root: Path, task: str)` and a public lock-owning `run_verb_stream()` wrapper; the existing implementation becomes `_run_verb_stream_unlocked()`.

- [ ] **Step 1: Add failing same-task lifecycle contracts**

In `tests/core/test_serve_exec.py`, add direct-stream tests beside the current incremental/disconnect tests. Keep one first stream suspended after its first yielded task line, then invoke a second stream with the same task and separate dependencies:

```python
first = remote_exec.run_verb_stream(
    "run", "t1", ["api"], None, deps=first_deps, nonce="firstnonce"
)
assert next(first) == b"first\n"

contender = list(remote_exec.run_verb_stream(
    "run", "t1", ["api"], None, deps=contender_deps, nonce="contendernonce"
))
assert contender == [
    b"error: remote task 't1' is already running; try again after it finishes\n",
    b"__MSHIP_EXIT__:contendernonce 2\n",
]
assert not contender_fake.run_calls
assert not contender_fake.streaming_calls
```

Close the first generator and prove a new same-task stream executes. Add a normal-exhaustion/task-nonzero variant proving both outcomes release the lock. Add an exception-path fake whose `run_streaming()` raises, assert the original exception propagates, then prove reacquisition. These are behavior tests: do not call unlock internals.

- [ ] **Step 2: Add failing task-granularity and lock-path contracts**

While the first `t1` stream remains suspended, fully execute a `t2` stream against the same workspace and assert its shell stream runs and returns its nonce-tagged success sentinel. After releasing `t1`, assert the expected persistent lock file exists:

```python
lock_name = hashlib.sha256("t1".encode("utf-8")).hexdigest() + ".lock"
assert (
    tmp_path / ".mothership" / "remote-exec-locks" / lock_name
).is_file()
```

Run another `t1` stream with that empty file present to prove file persistence does not imply ownership.

- [ ] **Step 3: Add a deterministic failing cross-process contract**

Add a module-level multiprocessing worker. It creates a `run_verb_stream()` for task `t1` with an unknown repo, calls `next()` once so the public generator owns the lock while suspended at the existing error yield, signals a `multiprocessing.Event`, waits on a release event with a bounded timeout, and closes the generator in `finally`.

The parent must use an explicit multiprocessing context and events—never sleeps:

```python
ctx = multiprocessing.get_context("spawn")
ready = ctx.Event()
release = ctx.Event()
proc = ctx.Process(
    target=_hold_remote_exec_stream,
    args=(str(tmp_path), ready, release),
)
proc.start()
try:
    assert ready.wait(timeout=10)
    contender = list(/* same task, shared tmp_path, distinct nonce */)
    assert contender[-1] == b"__MSHIP_EXIT__:processcontender 2\n"
finally:
    release.set()
    proc.join(timeout=10)
assert proc.exitcode == 0
```

Assert the contender reports `already running`, not the inner unknown-repo error. This proves independent processes contend on the same kernel lock.

- [ ] **Step 4: Add failing fail-closed infrastructure contracts**

Use real temporary filesystem states, not source inspection:

1. Make `<tmp_path>/.mothership` a regular file so lock-directory creation fails.
2. Make the computed `<digest>.lock` path a directory so opening it as a lock file fails.
3. Monkeypatch `remote_exec.fcntl.flock` to raise an `OSError` for acquisition.

For each case, consume `run_verb_stream()` and assert an error naming remote-task locking, a nonce-tagged nonzero exit sentinel, and zero fake shell run/stream calls. Do not assert platform-specific `OSError` wording.

- [ ] **Step 5: Run the new contracts RED**

Run:

```bash
uv run --frozen pytest -q tests/core/test_serve_exec.py -k "concurrent or task_lock or lock_failure"
```

Expected: FAIL because there is no per-task lock, same-task contenders execute or reach the inner error, and no lock file exists.

- [ ] **Step 6: Implement the nonblocking lock acquisition owner**

In `src/mship/core/remote_exec.py`, add `fcntl` and `hashlib` imports. Add one private acquisition helper near `_hub_dir`:

```python
def _acquire_task_execution_lock(workspace_root: Path, task: str):
    lock_dir = workspace_root / ".mothership" / "remote-exec-locks"
    lock_dir.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256(task.encode("utf-8")).hexdigest()
    lock_file = (lock_dir / f"{digest}.lock").open("a+")
    try:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BaseException:
        lock_file.close()
        raise
    return lock_file
```

Give the helper a concrete return annotation matching the repository's supported Python version. The cleanup-on-acquisition-error is mandatory; do not let a failed `flock` leak a descriptor. If direct non-ASCII/surrogate values require an encoding decision, preserve exact deterministic task identity and fail closed rather than normalizing names.

- [ ] **Step 7: Wrap the existing generator without reindenting its body**

Rename the current implementation to `_run_verb_stream_unlocked()` and leave its body and long wire-contract docstring otherwise unchanged. Add public `run_verb_stream()` with the same signature. It must:

1. Attempt `_acquire_task_execution_lock()` before delegating.
2. Catch ordinary `BlockingIOError` as contention and yield the exact actionable error plus exit 2.
3. Catch other acquisition `OSError`/encoding failures as lock-infrastructure errors and yield a named error plus exit 1.
4. `yield from _run_verb_stream_unlocked(...)` only after successful acquisition.
5. In `finally`, issue `LOCK_UN` and close the descriptor, with descriptor close guaranteed even if explicit unlock raises.

Do not catch `OSError` raised by the existing execution generator as a lock error. Keep acquisition exception handling lexically separate from `yield from`; otherwise unrelated worktree/artifact errors will be mislabeled.

- [ ] **Step 8: Run focused lock and remote execution tests GREEN**

Run:

```bash
uv run --frozen pytest -q tests/core/test_serve_exec.py
```

Expected: PASS. Same-task contenders have zero shell calls and exit 2; close, exhaustion, task failure, and exceptions release; different tasks run; infrastructure failures fail closed; the multiprocessing worker exits 0; all pre-existing streaming, setup, artifact, and disconnect contracts remain green.

- [ ] **Step 9: Run repository checks and recorded suite**

Run:

```bash
task lint
mship test --task fix-435-remote-exec-lock
mship plan check-assumptions --plan docs/plans/2026-08-14-fix-435-remote-exec-lock.md
```

Expected: static checks pass; Mothership records a passing suite with no regressions; every assumption axis is covered or explicitly N/A.

- [ ] **Step 10: Commit and journal the completed concurrency guard**

```bash
git add \
  src/mship/core/remote_exec.py \
  tests/core/test_serve_exec.py
git commit -m "fix(remote-exec): serialize runs per task"
mship journal --task fix-435-remote-exec-lock \
  "Added a cross-process per-task remote execution flock; same-task contenders fail closed through existing stream framing; lifecycle, infrastructure, multiprocessing, focused, and recorded suites pass" \
  --action committed
```

Do not stage generated `uv.lock` version drift or unrelated main-checkout hook files.
<!-- /mship:task -->
