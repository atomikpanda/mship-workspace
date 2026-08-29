# Harden Remote Exec Task-Name Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reject traversal-capable task names at the authenticated remote `/exec` boundary before any filesystem, git, stream, or task work begins.

**Spec:** `fix-434-remote-task-name` (approved)

## Assumptions checked

- repo topology — covered: one affected repository, `mothership`; the workspace-level spec and plan dispatch one repository worktree.
- credential locus — covered: the vulnerable endpoint remains bearer-authenticated; this change narrows authenticated input and does not alter token storage or verification.
- execution locus — covered: validation runs on the remote serve host before `RemoteExecDeps`, `StreamingResponse`, shell-backed git, or task execution.
- state durability — N/A: no state schema, cache, journal, or persisted task format changes.
- review surface — covered: issue #434, approved spec `fix-434-remote-task-name`, focused security tests, full recorded suite, and pull-request review provide the evidence trail.
- agent stream — covered: invalid input returns the existing HTTP 400 response before a response stream exists; valid streaming behavior is unchanged.
- dispatched model — N/A: model selection does not affect the validation contract.

**Architecture:** `mship.core.run_ref` remains the single owner of safe run-ref segment semantics and exposes a public boolean predicate. `run_ref()`, `is_run_ref()`, and `create_app()`'s `/exec/{verb}` handler consume that predicate, while the direct remote-exec/run-ref rejection remains defense in depth.

**Tech Stack:** Python 3.14, FastAPI/Starlette `TestClient`, pytest, Mothership task/worktree lifecycle.

## Global Constraints

- Scope is the authenticated remote `/exec` task-name boundary only; do not change local task slug creation or state loading.
- Accepted segments are non-empty `[A-Za-z0-9._-]+`, excluding bare `.` and `..`; full-string matching must reject `/`, whitespace, shell metacharacters, and trailing newlines.
- Invalid task names retain HTTP 400 with detail `invalid task name`.
- Validation must happen before `RemoteExecDeps` work or `StreamingResponse` creation and must produce zero filesystem, shell, stream, or task side effects.
- Do not add migration code, path normalization, containment fallback, authentication changes, configuration, dependencies, compatibility aliases, or unrelated refactors.

---

<!-- mship:task id=1 acs=ac1,ac2,ac3,ac4,ac5,ac6,ac7,ac8,ac9,ac10 -->
### Task 1: Share Safe-Segment Validation at the Remote Boundary

**Files:**
- Modify: `src/mship/core/run_ref.py:30-56`
- Modify: `src/mship/core/serve.py:1544-1579`
- Modify: `src/mship/core/remote_setup.py:39-56`
- Test: `tests/core/test_run_ref.py:5-36`
- Test: `tests/core/test_serve_exec.py:498-545,1018-1040`

**Interfaces:**
- Consumes: existing `_SEGMENT_RE`, `run_ref(task: str, repo: str) -> str`, `is_run_ref(name: str) -> bool`, and FastAPI `ExecBody.task`.
- Produces: `is_run_ref_segment(value: str) -> bool`, the single safe-segment predicate used by both run-ref and remote endpoint validation.

- [ ] **Step 1: Add endpoint regressions for traversal and accepted safe characters**

Replace the one-case shell-metacharacter endpoint test with a boundary contract that includes the traversal forms from #434 and proves no command begins:

```python
def test_exec_rejects_unsafe_task_name_before_any_command(tmp_path, monkeypatch):
    fake = _FakeShellRunner(
        streaming_proc=_FakeProc(stdout_lines=["pwned\n"], returncode=0)
    )
    _patch_shell(monkeypatch, fake)
    client = TestClient(_app(tmp_path))

    for task in (
        "../escape",
        "a/b",
        ".",
        "..",
        "",
        "api\n",
        "x; touch /tmp/pwned; #",
    ):
        response = client.post(
            "/exec/run",
            json={"task": task, "repos": ["api"]},
        )
        assert response.status_code == 400, task
        assert response.json()["detail"] == "invalid task name"

    assert not fake.run_calls
    assert not fake.streaming_calls
```

Add a positive endpoint contract without changing the existing materialization test's narrower focus:

```python
def test_exec_accepts_safe_segment_task_name(tmp_path, monkeypatch):
    fake = _FakeShellRunner(
        streaming_proc=_FakeProc(stdout_lines=["ok\n"], returncode=0)
    )
    _patch_shell(monkeypatch, fake)

    response = TestClient(_app(tmp_path)).post(
        "/exec/run",
        json={"task": "release.v2_build-1", "repos": ["api"]},
    )

    assert response.status_code == 200
    assert fake.streaming_calls
```

- [ ] **Step 2: Run the endpoint regression to verify traversal is currently accepted**

Run:

```bash
uv run --frozen pytest -q tests/core/test_serve_exec.py::test_exec_rejects_unsafe_task_name_before_any_command
```

Expected: FAIL on `../escape` (or another traversal/segment case) because the current `/exec` regex accepts `/`, bare dot segments, or a trailing newline.

- [ ] **Step 3: Add the public predicate contract**

Extend the import and add focused accepted/rejected tests in `tests/core/test_run_ref.py`:

```python
from mship.core.run_ref import (
    RUN_REF_PREFIX,
    RunRefNameError,
    is_run_ref,
    is_run_ref_segment,
    run_ref,
)


@pytest.mark.parametrize("value", ["t1", "release.v2_build-1"])
def test_run_ref_segment_accepts_safe_values(value):
    assert is_run_ref_segment(value)


@pytest.mark.parametrize(
    "value",
    ["", ".", "..", "../escape", "a/b", "with space", "semi;colon", "api\n"],
)
def test_run_ref_segment_rejects_unsafe_values(value):
    assert not is_run_ref_segment(value)
```

- [ ] **Step 4: Run the predicate contract to verify the public owner is absent**

Run:

```bash
uv run --frozen pytest -q tests/core/test_run_ref.py
```

Expected: collection ERROR because `is_run_ref_segment` is not yet exported from `mship.core.run_ref`.

- [ ] **Step 5: Implement the shared predicate and use it at `/exec`**

In `src/mship/core/run_ref.py`, keep the existing anchored regex unchanged and add the public predicate:

```python
_SEGMENT_RE = re.compile(r"\A(?!\.{1,2}\Z)[A-Za-z0-9._-]+\Z")


def is_run_ref_segment(value: str) -> bool:
    """Whether `value` is one safe task/repository run-ref segment."""
    return bool(_SEGMENT_RE.match(value or ""))
```

Route both existing consumers through it:

```python
def run_ref(task: str, repo: str) -> str:
    for label, value in (("task", task), ("repo", repo)):
        if not is_run_ref_segment(value):
            raise RunRefNameError(
                f"{label} name {value!r} cannot be used in a run ref; it must "
                f"match [A-Za-z0-9._-]+ and not be '.' or '..'"
            )
    return f"{RUN_REF_PREFIX}{task}/{repo}"


def is_run_ref(name: str) -> bool:
    if not name.startswith(RUN_REF_PREFIX):
        return False
    segments = name[len(RUN_REF_PREFIX):].split("/")
    return len(segments) == 2 and all(is_run_ref_segment(s) for s in segments)
```

In `src/mship/core/serve.py`, remove the function-local `import re` and `_TASK_NAME_RE`. Import and use the shared owner before creating dependencies:

```python
from mship.core.run_ref import is_run_ref_segment

# ...

if not is_run_ref_segment(body.task):
    raise HTTPException(status_code=400, detail="invalid task name")
```

Keep the boundary comment concise and accurate: the task name becomes both a `.worktrees` path segment and shell-backed git/task input, so it must match the shared run-ref segment contract before any work begins.

Update stale comments only where this change makes them false:

- In `src/mship/core/run_ref.py`, replace the claim that serve accepts a looser task charset with a statement that the predicate is shared with serve.
- In `src/mship/core/remote_setup.py`, retain `_safe()` as defense for direct callers but remove the claim that serve permits `.` and `/`.
- In `tests/core/test_serve_exec.py::test_a_task_name_that_cannot_form_a_ref_fails_cleanly`, state that the direct `remote_exec` unit path deliberately bypasses `/exec` and still rejects an invalid ref before commands run.

- [ ] **Step 6: Run focused security tests**

Run:

```bash
uv run --frozen pytest -q tests/core/test_run_ref.py tests/core/test_remote_setup.py tests/core/test_serve_exec.py
```

Expected: PASS. The invalid endpoint table returns 400 with zero shell calls; the positive dotted/underscored/hyphenated task streams successfully; run-ref and setup behavior remain green.

- [ ] **Step 7: Run repository checks and recorded suite**

Run:

```bash
task lint
mship test --task fix-434-remote-task-name
mship plan check-assumptions --plan docs/plans/2026-08-14-fix-434-remote-task-name.md
```

Expected: all checks pass; Mothership records passing evidence for the task; every assumption axis is covered or explicitly N/A.

- [ ] **Step 8: Commit and journal the completed security boundary**

```bash
git add \
  src/mship/core/run_ref.py \
  src/mship/core/serve.py \
  src/mship/core/remote_setup.py \
  tests/core/test_run_ref.py \
  tests/core/test_serve_exec.py
git commit -m "fix(serve): reject traversing remote task names"
mship journal --task fix-434-remote-task-name \
  "Shared run-ref segment validation with the remote exec boundary; traversal and newline cases return 400 before commands; focused and recorded suites pass" \
  --action committed
```

Do not stage generated `uv.lock` version drift or unrelated main-checkout hook files.
<!-- /mship:task -->
