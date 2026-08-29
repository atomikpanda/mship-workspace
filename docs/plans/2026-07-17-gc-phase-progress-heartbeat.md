# GC Phase Progress + Activity Heartbeat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After an operator dispatches a spec, Ground Control shows the work moving through a shared phase stepper (Dispatched → Planning → Building → Review → Done) with a live "is the agent working right now" chip, driven by an agent-agnostic activity heartbeat stamped at the mship CLI boundary.

**Architecture:** mship stamps `last_activity_at` on the task inside the existing state-mutation lock whenever an agent runs a task-scoped command (journal, commit, test, phase, spec apply) plus a new no-side-effect `mship heartbeat` command. The serve layer already serializes the view dataclasses with `jsonable_encoder`, so exposing new fields on `TaskSummary` / `WorkItemSummary` is enough — no endpoint rewrites. Ground Control adds two shared, pure-logic-backed composables (`PhaseStepper`, `LiveChip`) wired into the Console cockpit (reusing its 4s poll) and the SpecDetail screen (new poll that runs only while the spec is in-flight).

**Tech Stack:** Python 3 / Pydantic / FastAPI / Typer / pytest (mothership); Kotlin / Jetpack Compose / Material3 / kotlinx.serialization / Ktor / JUnit4 + Ktor MockEngine (ground-control Android).

**Spec:** `gc-phase-progress-heartbeat` (approved).

**Acceptance criteria → task map** (full mapping in Self-Review): ac1 → T3, T4, T5, T6; ac2 → T7; ac3 → T8, T9; ac4 → T11; ac5 → T12; ac6 → T14; ac7 → T13; ac8 → T11, T12.

---

## File Structure

### mothership (Python serve/core) — worktree root `/home/bailey/development/repos/mship-workspace/.worktrees/gc-phase-progress-heartbeat/mothership`

| File | Change | Responsibility |
|---|---|---|
| `src/mship/core/state.py` | Modify | Add `Task.last_activity_at` field; add `StateManager.record_activity()` helper |
| `src/mship/cli/log.py` | Modify | `mship journal` write path stamps activity |
| `src/mship/cli/commit.py` | Modify | `mship commit` stamps activity on success |
| `src/mship/cli/exec.py` | Modify | `mship test` stamps activity in its existing mutate |
| `src/mship/core/phase.py` | Modify | Phase transition stamps activity in its existing mutate |
| `src/mship/cli/spec.py` | Modify | `mship spec apply` stamps the bound task's activity |
| `src/mship/cli/heartbeat.py` | Create | New `mship heartbeat --task <slug>` command (no other side effects) |
| `src/mship/cli/__init__.py` | Modify | Register the heartbeat command module |
| `src/mship/core/view/task_index.py` | Modify | Expose `last_activity_at` + `phase_entered_at` on `TaskSummary` |
| `src/mship/core/view/workitem_index.py` | Modify | Expose active task's `active_last_activity_at` + `active_phase` on `WorkItemSummary` |

Test files (mothership): `tests/core/test_state.py`, `tests/cli/test_log.py`, `tests/cli/test_commit.py`, `tests/cli/test_exec.py`, `tests/cli/test_phase.py`, `tests/cli/test_spec.py`, `tests/cli/test_heartbeat.py` (create), `tests/core/view/test_task_index.py`, `tests/core/test_serve.py`, `tests/core/view/test_workitem_index.py`, `tests/core/test_serve_items.py`.

### ground-control (Kotlin/Compose) — worktree root `/home/bailey/development/repos/mship-workspace/.worktrees/gc-phase-progress-heartbeat/ground-control`, Gradle module under `android/`

| File | Change | Responsibility |
|---|---|---|
| `app/src/main/java/com/atomikpanda/groundcontrol/data/dto/TaskDtos.kt` | Modify | Add `lastActivityAt` + `phaseEnteredAt` to `TaskSummary` DTO |
| `app/src/main/java/com/atomikpanda/groundcontrol/data/dto/WorkItemDtos.kt` | Modify | Add `activePhase` + `activeLastActivityAt` to `WorkItemSummary` DTO |
| `app/src/main/java/com/atomikpanda/groundcontrol/ui/activity/PhaseStepper.kt` | Create | `PhaseStep` enum, `phaseStepFor()` mapper, `PhaseStepper` composable |
| `app/src/main/java/com/atomikpanda/groundcontrol/ui/activity/LiveChip.kt` | Create | Threshold constants, `LiveStatus` + `liveStatus()`, `LiveChip` composable |
| `app/src/main/java/com/atomikpanda/groundcontrol/ui/console/ConsoleScreen.kt` | Modify | Render full stepper + chip from the focused task |
| `app/src/main/java/com/atomikpanda/groundcontrol/data/SpecDetailRepository.kt` | Modify | Add `loadTask()` seam |
| `app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/SpecDetailViewModel.kt` | Modify | Carry task phase/activity on `SpecDetail`; add in-flight-only activity poll |
| `app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/SpecDetailScreen.kt` | Modify | Compact stepper + chip; start/stop the poll by status |

Test files (ground-control, all under `android/app/src/test/java/com/atomikpanda/groundcontrol/`): `TaskDtosTest.kt`, `WorkItemDtosTest.kt`, `PhaseStepperTest.kt` (create), `LiveChipTest.kt` (create), `ConsoleViewModelTest.kt` (create), `SpecDetailViewModelTest.kt`.

**All mothership commands run from the mothership worktree root. All ground-control commands run from `ground-control/android` after `source ~/toolchains/android-env.sh`.** Journal every commit with `--task gc-phase-progress-heartbeat`.

---

<!-- mship:task id=1 -->
### Task 1: Add `last_activity_at` to the Task model

**Files:**
- Modify: `src/mship/core/state.py` (Task class ~line 37; datetime import line 2)
- Test: `tests/core/test_state.py`

- [ ] **Step 1: Write the failing tests**

Append to `tests/core/test_state.py`:

```python
def test_last_activity_at_defaults_none(state_dir: Path):
    mgr = StateManager(state_dir)
    task = Task(
        slug="a", description="d", phase="dev",
        created_at=datetime(2026, 4, 10, tzinfo=timezone.utc),
        affected_repos=["shared"], branch="feat/a",
    )
    mgr.save(WorkspaceState(tasks={"a": task}))
    assert mgr.load().tasks["a"].last_activity_at is None


def test_last_activity_at_roundtrips(state_dir: Path):
    mgr = StateManager(state_dir)
    stamp = datetime(2026, 7, 13, 9, 30, tzinfo=timezone.utc)
    task = Task(
        slug="a", description="d", phase="dev",
        created_at=datetime(2026, 4, 10, tzinfo=timezone.utc),
        affected_repos=["shared"], branch="feat/a",
        last_activity_at=stamp,
    )
    mgr.save(WorkspaceState(tasks={"a": task}))
    assert mgr.load().tasks["a"].last_activity_at == stamp
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/core/test_state.py::test_last_activity_at_roundtrips -v`
Expected: FAIL — `TypeError: ... unexpected keyword argument 'last_activity_at'` (or Pydantic ValidationError).

- [ ] **Step 3: Add the field**

In `src/mship/core/state.py`, in the `Task` class, add the field immediately after `phase_entered_at` (line 37) so it mirrors it:

```python
    phase_entered_at: datetime | None = None
    last_activity_at: datetime | None = None
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/core/test_state.py -v`
Expected: PASS (all state tests).

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/state.py tests/core/test_state.py
git commit -m "feat(state): add Task.last_activity_at heartbeat field"
mship journal "added Task.last_activity_at field mirroring phase_entered_at; roundtrip tests passing" --task gc-phase-progress-heartbeat --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: Add `StateManager.record_activity()` helper

**Files:**
- Modify: `src/mship/core/state.py` (import line 2; new method after `mutate` ~line 132)
- Test: `tests/core/test_state.py`

- [ ] **Step 1: Write the failing tests**

Append to `tests/core/test_state.py`:

```python
def test_record_activity_stamps_last_activity_at(state_dir: Path):
    mgr = StateManager(state_dir)
    task = Task(
        slug="a", description="d", phase="dev",
        created_at=datetime(2026, 4, 10, tzinfo=timezone.utc),
        affected_repos=["shared"], branch="feat/a",
    )
    mgr.save(WorkspaceState(tasks={"a": task}))
    fixed = datetime(2026, 7, 13, 12, 0, tzinfo=timezone.utc)
    mgr.record_activity("a", now=fixed)
    assert mgr.load().tasks["a"].last_activity_at == fixed


def test_record_activity_defaults_to_now(state_dir: Path):
    mgr = StateManager(state_dir)
    task = Task(
        slug="a", description="d", phase="dev",
        created_at=datetime(2026, 4, 10, tzinfo=timezone.utc),
        affected_repos=["shared"], branch="feat/a",
    )
    mgr.save(WorkspaceState(tasks={"a": task}))
    mgr.record_activity("a")
    assert mgr.load().tasks["a"].last_activity_at is not None


def test_record_activity_unknown_slug_is_noop(state_dir: Path):
    mgr = StateManager(state_dir)
    mgr.save(WorkspaceState(tasks={}))
    mgr.record_activity("ghost")  # must not raise
    assert mgr.load().tasks == {}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/core/test_state.py::test_record_activity_stamps_last_activity_at -v`
Expected: FAIL — `AttributeError: 'StateManager' object has no attribute 'record_activity'`.

- [ ] **Step 3: Implement the helper**

In `src/mship/core/state.py`, change the datetime import on line 2 from:

```python
from datetime import datetime
```
to:
```python
from datetime import datetime, timezone
```

Then add this method to `StateManager`, immediately after `mutate` (after line 132):

```python
    def record_activity(self, slug: str, now: "datetime | None" = None) -> None:
        """Stamp `last_activity_at` on a task — the agent-agnostic activity heartbeat.

        Cheap: one field write under the same exclusive lock as any other
        mutation. A no-op when `slug` is unknown, so callers that may pass a
        slug that isn't (yet) a task (e.g. `mship spec apply` before dispatch)
        stay safe.
        """
        stamp = now or datetime.now(timezone.utc)

        def _apply(state: WorkspaceState) -> None:
            task = state.tasks.get(slug)
            if task is not None:
                task.last_activity_at = stamp

        self.mutate(_apply)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/core/test_state.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/state.py tests/core/test_state.py
git commit -m "feat(state): add StateManager.record_activity heartbeat helper"
mship journal "added record_activity(slug, now) helper; no-ops on unknown slug; tests passing" --task gc-phase-progress-heartbeat --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: Stamp activity from `mship journal` (write path)

**Files:**
- Modify: `src/mship/cli/log.py` (write path, after `log_mgr.append(...)` ~line 168)
- Test: `tests/cli/test_log.py`

- [ ] **Step 1: Write the failing test**

Append to `tests/cli/test_log.py`:

```python
def test_journal_write_stamps_last_activity(configured_app_with_task: Path):
    result = runner.invoke(app, ["journal", "did a thing", "--task", "add-labels"])
    assert result.exit_code == 0, result.output
    state = StateManager(configured_app_with_task / ".mothership").load()
    assert state.tasks["add-labels"].last_activity_at is not None


def test_journal_read_does_not_stamp(configured_app_with_task: Path):
    runner.invoke(app, ["journal", "seed", "--task", "add-labels"])
    # reset the stamp, then do a read-only invocation
    mgr = StateManager(configured_app_with_task / ".mothership")
    st = mgr.load()
    st.tasks["add-labels"].last_activity_at = None
    mgr.save(st)
    result = runner.invoke(app, ["journal", "--task", "add-labels"])  # read path
    assert result.exit_code == 0, result.output
    assert mgr.load().tasks["add-labels"].last_activity_at is None
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/cli/test_log.py::test_journal_write_stamps_last_activity -v`
Expected: FAIL — `assert None is not None`.

- [ ] **Step 3: Stamp on the write path**

In `src/mship/cli/log.py`, inside the `if message is not None:` block, right after the `log_mgr.append(...)` call (which ends at line 168) and before the `if output.human_mode:` block, add:

```python
            # Agent-agnostic activity heartbeat: journaling is real task work.
            state_mgr.record_activity(t.slug)
```

(`state_mgr` is already bound at line 66.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/cli/test_log.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/mship/cli/log.py tests/cli/test_log.py
git commit -m "feat(journal): stamp last_activity_at on journal write"
mship journal "mship journal write path now stamps activity; read path unaffected; tests passing" --task gc-phase-progress-heartbeat --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: Stamp activity from `mship commit`

**Files:**
- Modify: `src/mship/cli/commit.py` (after the `if not results:` guard ~line 97, before output ~line 99)
- Test: `tests/cli/test_commit.py`

- [ ] **Step 1: Write the failing test**

Append to `tests/cli/test_commit.py` (mirror the shell-mock style already in this file):

```python
def test_commit_stamps_last_activity(configured_git_app: Path):
    runner.invoke(app, ["spawn", "--hotfix", "activity commit", "--repos", "shared"])
    slug = "activity-commit"

    def mock_run(cmd, cwd, env=None):
        if "git diff --cached --quiet" in cmd:
            return ShellResult(returncode=1, stdout="", stderr="")  # staged everywhere
        if "git rev-parse HEAD" in cmd:
            return ShellResult(returncode=0, stdout="abc1234\n", stderr="")
        return ShellResult(returncode=0, stdout="", stderr="")

    mock_shell = MagicMock(spec=ShellRunner)
    mock_shell.run.side_effect = mock_run
    container.shell.override(mock_shell)
    try:
        result = runner.invoke(app, ["commit", "fix: thing", "--task", slug])
        assert result.exit_code == 0, result.output
        state = StateManager(configured_git_app / ".mothership").load()
        assert state.tasks[slug].last_activity_at is not None
    finally:
        container.shell.reset_override()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/cli/test_commit.py::test_commit_stamps_last_activity -v`
Expected: FAIL — `assert None is not None`.

- [ ] **Step 3: Stamp on the commit success path**

In `src/mship/cli/commit.py`, after the `if not results:` error guard (ends line 97) and before `if output.human_mode:` (line 99), add:

```python
        # Agent-agnostic activity heartbeat: a successful commit is task work.
        state_mgr.record_activity(t.slug)

```

(`state_mgr` is bound at line 30.)

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/cli/test_commit.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/mship/cli/commit.py tests/cli/test_commit.py
git commit -m "feat(commit): stamp last_activity_at on successful commit"
mship journal "mship commit stamps activity after a successful commit; tests passing" --task gc-phase-progress-heartbeat --action committed
```
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: Stamp activity from `mship test` and phase transitions

**Files:**
- Modify: `src/mship/cli/exec.py` (the `_record` mutate ~line 278-280)
- Modify: `src/mship/core/phase.py` (the `_apply` mutate ~line 178-184)
- Test: `tests/cli/test_exec.py`, `tests/cli/test_phase.py`

Both of these paths already run a `state_manager.mutate(...)`. Fold the one-field stamp into the existing mutate (cheapest — no second lock), matching the `phase_entered_at` precedent.

- [ ] **Step 1: Write the failing tests**

Append to `tests/cli/test_exec.py`:

```python
def test_test_command_stamps_last_activity(configured_exec_app):
    workspace, mock_shell = configured_exec_app
    result = runner.invoke(app, ["test", "--task", "test-task"])
    assert result.exit_code == 0, result.output
    from mship.core.state import StateManager
    state = StateManager(workspace / ".mothership").load()
    assert state.tasks["test-task"].last_activity_at is not None
```

Append to `tests/cli/test_phase.py`:

```python
def test_phase_transition_stamps_last_activity(configured_app_with_task, workspace: Path):
    result = runner.invoke(app, ["phase", "dev", "--task", "add-labels"])
    assert result.exit_code == 0, result.output
    state = StateManager(workspace / ".mothership").load()
    assert state.tasks["add-labels"].last_activity_at is not None
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/cli/test_exec.py::test_test_command_stamps_last_activity tests/cli/test_phase.py::test_phase_transition_stamps_last_activity -v`
Expected: FAIL — `assert None is not None` for both.

- [ ] **Step 3: Add the stamps inline**

In `src/mship/cli/exec.py`, change the `_record` mutate (lines 278-280) from:

```python
        def _record(s):
            s.tasks[t.slug].test_iteration = new_iter
        state_mgr.mutate(_record)
```
to:
```python
        def _record(s):
            s.tasks[t.slug].test_iteration = new_iter
            # Agent-agnostic activity heartbeat: running tests is task work.
            s.tasks[t.slug].last_activity_at = datetime.now(timezone.utc)
        state_mgr.mutate(_record)
```

(`datetime, timezone` are already imported at line 173 inside `test_cmd`.)

In `src/mship/core/phase.py`, change the `_apply` mutate (lines 178-184) from:

```python
        def _apply(s):
            t = s.tasks[task_slug]
            if blocked_force_unblock:
                t.blocked_reason = None
                t.blocked_at = None
            t.phase = target
            t.phase_entered_at = datetime.now(timezone.utc)
```
to:
```python
        def _apply(s):
            t = s.tasks[task_slug]
            if blocked_force_unblock:
                t.blocked_reason = None
                t.blocked_at = None
            t.phase = target
            now = datetime.now(timezone.utc)
            t.phase_entered_at = now
            # Agent-agnostic activity heartbeat: a phase transition is task work.
            t.last_activity_at = now
```

(`datetime, timezone` are imported at `phase.py` line 2.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/cli/test_exec.py tests/cli/test_phase.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/mship/cli/exec.py src/mship/core/phase.py tests/cli/test_exec.py tests/cli/test_phase.py
git commit -m "feat(test,phase): stamp last_activity_at in existing state mutates"
mship journal "mship test + phase transition stamp activity inline in their existing mutates; tests passing" --task gc-phase-progress-heartbeat --action committed
```
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: Stamp activity from `mship spec apply`

**Files:**
- Modify: `src/mship/cli/spec.py` (the `apply` command, after `store.save(spec)` ~line 179)
- Test: `tests/cli/test_spec.py`

`spec apply` operates on a spec, not a task. It stamps the bound task (`spec.task_slug`) when that slug is a live task; `record_activity` no-ops otherwise.

- [ ] **Step 1: Write the failing test**

Append to `tests/cli/test_spec.py` (the `_draft_json` helper and `configured_app_with_task` fixture already exist in this file; that fixture seeds a task with slug `add-labels`):

```python
def test_spec_apply_stamps_bound_task_activity(configured_app_with_task: Path, tmp_path):
    # `spec new --task add-labels` binds spec.task_slug = "add-labels" (id "add-labels").
    runner.invoke(app, ["spec", "new", "--task", "add-labels"])
    jf = tmp_path / "draft.json"
    jf.write_text(_draft_json())
    result = runner.invoke(app, ["spec", "apply", "add-labels", "--from-json", str(jf)])
    assert result.exit_code == 0, result.output
    state = StateManager(configured_app_with_task / ".mothership").load()
    assert state.tasks["add-labels"].last_activity_at is not None
```

Confirm the file already imports `StateManager` (it does, via `from mship.core.state import StateManager, Task, WorkspaceState`); if not, add it.

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/cli/test_spec.py::test_spec_apply_stamps_bound_task_activity -v`
Expected: FAIL — `assert None is not None`.

- [ ] **Step 3: Stamp the bound task after save**

In `src/mship/cli/spec.py`, in the `apply` command, immediately after `path = store.save(spec)` (line 179) add:

```python
        # Agent-agnostic activity heartbeat: applying a drafted spec is task work.
        # No-ops when the spec's bound task_slug isn't (yet) a live task.
        if spec.task_slug:
            container.state_manager().record_activity(spec.task_slug)
```

(`container` is already bound at line 157 inside `apply`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/cli/test_spec.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/mship/cli/spec.py tests/cli/test_spec.py
git commit -m "feat(spec): stamp bound task activity on spec apply"
mship journal "mship spec apply stamps the bound task's last_activity_at; no-ops pre-dispatch; tests passing" --task gc-phase-progress-heartbeat --action committed
```
<!-- /mship:task -->

<!-- mship:task id=7 -->
### Task 7: New `mship heartbeat --task <slug>` command

**Files:**
- Create: `src/mship/cli/heartbeat.py`
- Modify: `src/mship/cli/__init__.py` (import block ~line 125; register block ~line 187)
- Test: `tests/cli/test_heartbeat.py` (create)

- [ ] **Step 1: Write the failing test**

Create `tests/cli/test_heartbeat.py`:

```python
from datetime import datetime, timezone
from pathlib import Path

import pytest
from typer.testing import CliRunner

from mship.cli import app, container
from mship.core.state import StateManager, Task, WorkspaceState

runner = CliRunner()


@pytest.fixture
def configured_app_with_task(workspace: Path):
    state_dir = workspace / ".mothership"
    state_dir.mkdir(exist_ok=True)
    container.config_path.override(workspace / "mothership.yaml")
    container.state_dir.override(state_dir)
    mgr = StateManager(state_dir)
    task = Task(
        slug="add-labels", description="Add labels", phase="dev",
        created_at=datetime(2026, 4, 10, tzinfo=timezone.utc),
        affected_repos=["shared"], branch="feat/add-labels",
    )
    mgr.save(WorkspaceState(tasks={"add-labels": task}))
    yield workspace
    container.config_path.reset_override()
    container.state_dir.reset_override()
    container.config.reset()
    container.state_manager.reset()


def test_heartbeat_stamps_last_activity(configured_app_with_task: Path):
    result = runner.invoke(app, ["heartbeat", "--task", "add-labels"])
    assert result.exit_code == 0, result.output
    state = StateManager(configured_app_with_task / ".mothership").load()
    assert state.tasks["add-labels"].last_activity_at is not None


def test_heartbeat_has_no_other_side_effects(configured_app_with_task: Path):
    before = StateManager(configured_app_with_task / ".mothership").load().tasks["add-labels"]
    runner.invoke(app, ["heartbeat", "--task", "add-labels"])
    after = StateManager(configured_app_with_task / ".mothership").load().tasks["add-labels"]
    # Only last_activity_at may differ.
    b = before.model_dump(exclude={"last_activity_at"})
    a = after.model_dump(exclude={"last_activity_at"})
    assert a == b


def test_heartbeat_json_output(configured_app_with_task: Path):
    result = runner.invoke(app, ["--json", "heartbeat", "--task", "add-labels"])
    assert result.exit_code == 0, result.output
    import json
    payload = json.loads(result.output)
    assert payload["task"] == "add-labels"
    assert payload["last_activity_at"] is not None


def test_heartbeat_unknown_task_errors(configured_app_with_task: Path):
    result = runner.invoke(app, ["heartbeat", "--task", "ghost"])
    assert result.exit_code != 0
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/cli/test_heartbeat.py -v`
Expected: FAIL — `No such command 'heartbeat'` (non-zero exit).

- [ ] **Step 3: Create the command and register it**

Create `src/mship/cli/heartbeat.py`:

```python
from typing import Optional

import typer

from mship.cli._resolve import resolve_for_command
from mship.cli.output import Output


def register(app: typer.Typer, get_container):
    @app.command(rich_help_panel="Workflow")
    def heartbeat(
        task: Optional[str] = typer.Option(
            None, "--task",
            help="Target task slug. Defaults to cwd (worktree) > MSHIP_TASK env var.",
        ),
    ):
        """Stamp a task's activity heartbeat (last_activity_at). No other side effects."""
        container = get_container()
        output = Output()
        state_mgr = container.state_manager()
        state = state_mgr.load()

        resolved = resolve_for_command("heartbeat", state, task, output)
        t = resolved.task

        state_mgr.record_activity(t.slug)
        stamped = state_mgr.load().tasks[t.slug].last_activity_at

        if output.human_mode:
            output.success(f"Heartbeat: {t.slug}")
        else:
            output.json({
                "task": t.slug,
                "last_activity_at": stamped.isoformat() if stamped else None,
                "resolved_task": resolved.task.slug,
                "resolution_source": resolved.source,
            })
```

In `src/mship/cli/__init__.py`, add the import alongside the other command imports (after the `gh` import at line 124):

```python
from mship.cli import heartbeat as _heartbeat_mod
```

And add the registration alongside the others (after `_gh_mod.register(app, get_container)` at line 186):

```python
_heartbeat_mod.register(app, get_container)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/cli/test_heartbeat.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/mship/cli/heartbeat.py src/mship/cli/__init__.py tests/cli/test_heartbeat.py
git commit -m "feat(cli): add mship heartbeat command (activity pulse, no side effects)"
mship journal "added mship heartbeat --task command that only stamps last_activity_at; tests passing" --task gc-phase-progress-heartbeat --action committed
```
<!-- /mship:task -->

<!-- mship:task id=8 -->
### Task 8: Expose `last_activity_at` + `phase_entered_at` on `TaskSummary` and the task endpoints

**Files:**
- Modify: `src/mship/core/view/task_index.py` (`TaskSummary` ~line 11-27; `_summarize` ~line 39-54)
- Test: `tests/core/view/test_task_index.py`, `tests/core/test_serve.py`

The serve endpoints (`GET /tasks`, `GET /tasks/{slug}`) already `jsonable_encoder(...)` the `TaskSummary` dataclass, so new fields serialize automatically — no serve.py change.

- [ ] **Step 1: Write the failing tests**

Append to `tests/core/view/test_task_index.py`:

```python
def test_summary_carries_activity_and_phase_entered(tmp_path: Path):
    now = datetime.now(timezone.utc)
    t = _task("a", last_activity_at=now, phase_entered_at=now)
    state = WorkspaceState(tasks={"a": t})
    [summary] = build_task_index(state, tmp_path)
    assert summary.last_activity_at == now
    assert summary.phase_entered_at == now


def test_summary_activity_defaults_none(tmp_path: Path):
    t = _task("a")
    [summary] = build_task_index(WorkspaceState(tasks={"a": t}), tmp_path)
    assert summary.last_activity_at is None
    assert summary.phase_entered_at is None
```

Append to `tests/core/test_serve.py` (the `_seed_task` / `_app_with` helpers already exist in this file):

```python
def test_get_task_serializes_activity_fields(tmp_path):
    state_dir = tmp_path / ".mothership"
    state_dir.mkdir(exist_ok=True)
    sm = StateManager(state_dir)
    now = datetime(2026, 7, 13, 12, 0, tzinfo=timezone.utc)
    sm.save(WorkspaceState(tasks={"dq": Task(
        slug="dq", description="d", phase="dev",
        created_at=datetime(2026, 6, 14, tzinfo=timezone.utc),
        affected_repos=["mothership"], branch="feat/dq",
        last_activity_at=now, phase_entered_at=now,
    )}))
    log = LogManager(state_dir / "logs")
    log.append("dq", "spawned")
    client = TestClient(_app_with(tmp_path, sm, log))
    body = client.get("/tasks/dq").json()
    assert body["last_activity_at"] == "2026-07-13T12:00:00Z"
    assert body["phase_entered_at"] == "2026-07-13T12:00:00Z"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/core/view/test_task_index.py::test_summary_carries_activity_and_phase_entered tests/core/test_serve.py::test_get_task_serializes_activity_fields -v`
Expected: FAIL — `AttributeError: 'TaskSummary' object has no attribute 'last_activity_at'`.

- [ ] **Step 3: Add fields to the dataclass + summarizer**

In `src/mship/core/view/task_index.py`, add two fields to `TaskSummary` after `depends_on` (line 27):

```python
    depends_on: list[str] = field(default_factory=list)
    last_activity_at: datetime | None = None
    phase_entered_at: datetime | None = None
```

In `_summarize`, add to the `TaskSummary(...)` construction (after the `depends_on=...` line at 54, keep the closing paren):

```python
        depends_on=[e.upstream_slug for e in task.depends_on],
        last_activity_at=task.last_activity_at,
        phase_entered_at=task.phase_entered_at,
    )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/core/view/test_task_index.py tests/core/test_serve.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/view/task_index.py tests/core/view/test_task_index.py tests/core/test_serve.py
git commit -m "feat(view): expose last_activity_at + phase_entered_at on TaskSummary"
mship journal "TaskSummary now carries last_activity_at + phase_entered_at; GET /tasks serializes them; tests passing" --task gc-phase-progress-heartbeat --action committed
```
<!-- /mship:task -->

<!-- mship:task id=9 -->
### Task 9: Expose the active task's `last_activity_at` + phase on `WorkItemSummary`

**Files:**
- Modify: `src/mship/core/view/workitem_index.py` (`WorkItemSummary` ~line 86-101; `_summarize` ~line 103-120)
- Test: `tests/core/view/test_workitem_index.py`, `tests/core/test_serve_items.py`

"Active task" = the first linked task with `finished_at is None`. `GET /items` / `GET /items/{id}` already `jsonable_encoder(...)` the `WorkItemSummary` dataclass, so new fields serialize automatically.

- [ ] **Step 1: Write the failing tests**

Append to `tests/core/view/test_workitem_index.py` (the `_wi`, `_task`, `_now` helpers already exist):

```python
def _task_active(last_activity):
    return Task(
        slug="s1", description="d", phase="review", created_at=_now(),
        affected_repos=["mothership"], branch="b",
        finished_at=None, last_activity_at=last_activity,
    )


def test_summary_surfaces_active_task_activity_and_phase():
    now = _now()
    item = _wi(task_slugs=["s1"])
    summaries = build_workitem_index(
        [item], {}, {"s1": _task_active(now)}, {},
    )
    assert summaries[0].active_phase == "review"
    assert summaries[0].active_last_activity_at == now


def test_summary_active_fields_none_without_active_task():
    item = _wi(task_slugs=["s1"])
    finished = _task(finished=True)  # finished_at set
    summaries = build_workitem_index([item], {}, {"s1": finished}, {})
    assert summaries[0].active_phase is None
    assert summaries[0].active_last_activity_at is None
```

Append to `tests/core/test_serve_items.py` (the `_now` / `_app` helpers already exist):

```python
from mship.core.state import Task, WorkspaceState  # add to imports if not present


def test_get_item_surfaces_active_task_activity(tmp_path):
    state_dir = tmp_path / ".mothership"
    state_dir.mkdir(parents=True, exist_ok=True)
    sm = StateManager(state_dir)
    now = datetime(2026, 7, 13, 12, 0, tzinfo=timezone.utc)
    sm.save(WorkspaceState(tasks={"s1": Task(
        slug="s1", description="d", phase="dev", created_at=_now(),
        affected_repos=["mothership"], branch="b", last_activity_at=now,
    )}))
    items = WorkItemStore(state_dir / "workitems")
    wi = items.create(title="Feat", kind="feature", workspace="testws", now=_now())
    items.add_task(wi.id, "s1", now=_now())

    client = _app(tmp_path)
    got = client.get(f"/items/{wi.id}").json()
    assert got["active_phase"] == "dev"
    assert got["active_last_activity_at"] == "2026-07-13T12:00:00Z"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/core/view/test_workitem_index.py::test_summary_surfaces_active_task_activity_and_phase tests/core/test_serve_items.py::test_get_item_surfaces_active_task_activity -v`
Expected: FAIL — `AttributeError: 'WorkItemSummary' object has no attribute 'active_phase'`.

- [ ] **Step 3: Add fields, a helper, and wire the summarizer**

In `src/mship/core/view/workitem_index.py`, add two fields to `WorkItemSummary` after `unattended` (line 100):

```python
    unattended: bool = False
    active_phase: str | None = None
    active_last_activity_at: datetime | None = None
```

Add this helper immediately above `_summarize` (before line 103):

```python
def _active_task(tasks: list[Task]) -> Task | None:
    """The task an operator is watching: the first still-running (unfinished) task,
    or None when every linked task is finished."""
    for t in tasks:
        if t.finished_at is None:
            return t
    return None
```

In `_summarize`, after `tasks = [...]` (line 110), compute the active task and pass the two fields into the `WorkItemSummary(...)` construction. Change the tail of the constructor (lines 116-120) from:

```python
        thread_ids=list(item.thread_ids), external_links=list(item.external_links),
        unattended=item.unattended,
    )
```
to:
```python
        thread_ids=list(item.thread_ids), external_links=list(item.external_links),
        unattended=item.unattended,
        active_phase=active.phase if active else None,
        active_last_activity_at=active.last_activity_at if active else None,
    )
```

And add the `active` binding right after the `tasks = [...]` line (line 110):

```python
    tasks = [tasks_by_slug[s] for s in item.task_slugs if s in tasks_by_slug]
    active = _active_task(tasks)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/core/view/test_workitem_index.py tests/core/test_serve_items.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/view/workitem_index.py tests/core/view/test_workitem_index.py tests/core/test_serve_items.py
git commit -m "feat(view): surface active task activity + phase on WorkItemSummary"
mship journal "WorkItemSummary now surfaces active_phase + active_last_activity_at; GET /items serializes them; tests passing" --task gc-phase-progress-heartbeat --action committed
```
<!-- /mship:task -->

<!-- mship:task id=10 -->
### Task 10: Add activity fields to the client DTOs

**Files:**
- Modify: `app/src/main/java/com/atomikpanda/groundcontrol/data/dto/TaskDtos.kt` (`TaskSummary` line 7-22)
- Modify: `app/src/main/java/com/atomikpanda/groundcontrol/data/dto/WorkItemDtos.kt` (`WorkItemSummary` line 6-20)
- Test: `app/src/test/java/com/atomikpanda/groundcontrol/TaskDtosTest.kt`, `app/src/test/java/com/atomikpanda/groundcontrol/WorkItemDtosTest.kt`

All ground-control commands run from `ground-control/android` after `source ~/toolchains/android-env.sh`.

- [ ] **Step 1: Write the failing tests**

Append to `TaskDtosTest.kt` (the class already has `private val json = buildJson()`):

```kotlin
    @Test fun parses_task_summary_activity_fields() {
        val raw = """
        {"slug":"t1","phase":"dev","branch":"feat/t1",
         "last_activity_at":"2026-07-13T12:00:00Z","phase_entered_at":"2026-07-13T11:00:00Z"}
        """.trimIndent()
        val t = json.decodeFromString(TaskSummary.serializer(), raw)
        assertEquals("2026-07-13T12:00:00Z", t.lastActivityAt)
        assertEquals("2026-07-13T11:00:00Z", t.phaseEnteredAt)
    }

    @Test fun task_summary_activity_fields_default_null() {
        val raw = """{"slug":"t1","phase":"dev","branch":"feat/t1"}"""
        val t = json.decodeFromString(TaskSummary.serializer(), raw)
        assertNull(t.lastActivityAt)
        assertNull(t.phaseEnteredAt)
    }
```

Append to `WorkItemDtosTest.kt` (add `import com.atomikpanda.groundcontrol.data.buildJson`, `import com.atomikpanda.groundcontrol.data.dto.WorkItemSummary`, `import org.junit.Assert.assertEquals`, `import org.junit.Assert.assertNull`, `import org.junit.Test` if not present, and a `private val json = buildJson()`):

```kotlin
    @Test fun parses_work_item_active_task_fields() {
        val raw = """
        {"id":"wi1","kind":"feature","title":"T","phase":"in_flight",
         "active_phase":"dev","active_last_activity_at":"2026-07-13T12:00:00Z"}
        """.trimIndent()
        val w = json.decodeFromString(WorkItemSummary.serializer(), raw)
        assertEquals("dev", w.activePhase)
        assertEquals("2026-07-13T12:00:00Z", w.activeLastActivityAt)
    }

    @Test fun work_item_active_fields_default_null() {
        val raw = """{"id":"wi1","kind":"feature","title":"T","phase":"inbox"}"""
        val w = json.decodeFromString(WorkItemSummary.serializer(), raw)
        assertNull(w.activePhase)
        assertNull(w.activeLastActivityAt)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.TaskDtosTest" --tests "com.atomikpanda.groundcontrol.WorkItemDtosTest"`
Expected: FAIL — compilation error / `Unresolved reference: lastActivityAt` (and `activePhase`).

- [ ] **Step 3: Add the DTO fields**

In `TaskDtos.kt`, add two fields to `TaskSummary` after `createdAt` (line 21):

```kotlin
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("last_activity_at") val lastActivityAt: String? = null,
    @SerialName("phase_entered_at") val phaseEnteredAt: String? = null,
)
```

In `WorkItemDtos.kt`, add two fields to `WorkItemSummary` after `phaseOverride` (line 19):

```kotlin
    @SerialName("phase_override") val phaseOverride: String? = null,
    @SerialName("active_phase") val activePhase: String? = null,
    @SerialName("active_last_activity_at") val activeLastActivityAt: String? = null,
)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.TaskDtosTest" --tests "com.atomikpanda.groundcontrol.WorkItemDtosTest"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/src/main/java/com/atomikpanda/groundcontrol/data/dto/TaskDtos.kt app/src/main/java/com/atomikpanda/groundcontrol/data/dto/WorkItemDtos.kt app/src/test/java/com/atomikpanda/groundcontrol/TaskDtosTest.kt app/src/test/java/com/atomikpanda/groundcontrol/WorkItemDtosTest.kt
git commit -m "feat(dto): add activity + phase fields to TaskSummary and WorkItemSummary DTOs"
mship journal "GC DTOs carry lastActivityAt/phaseEnteredAt + activePhase/activeLastActivityAt; decode tests passing" --task gc-phase-progress-heartbeat --action committed
```
<!-- /mship:task -->

<!-- mship:task id=11 -->
### Task 11: Shared `PhaseStepper` composable + `phaseStepFor` mapper

**Files:**
- Create: `app/src/main/java/com/atomikpanda/groundcontrol/ui/activity/PhaseStepper.kt`
- Test: `app/src/test/java/com/atomikpanda/groundcontrol/PhaseStepperTest.kt` (create)

- [ ] **Step 1: Write the failing test**

Create `PhaseStepperTest.kt`:

```kotlin
package com.atomikpanda.groundcontrol

import com.atomikpanda.groundcontrol.ui.activity.PhaseStep
import com.atomikpanda.groundcontrol.ui.activity.phaseStepFor
import org.junit.Assert.assertEquals
import org.junit.Test

class PhaseStepperTest {
    @Test fun maps_task_phases_to_steps() {
        assertEquals(PhaseStep.DISPATCHED, phaseStepFor(null, false))
        assertEquals(PhaseStep.PLANNING, phaseStepFor("plan", false))
        assertEquals(PhaseStep.BUILDING, phaseStepFor("dev", false))
        assertEquals(PhaseStep.REVIEW, phaseStepFor("review", false))
        assertEquals(PhaseStep.DONE, phaseStepFor("run", false))
    }

    @Test fun done_flag_wins_over_phase() {
        assertEquals(PhaseStep.DONE, phaseStepFor("dev", true))
    }

    @Test fun unknown_phase_degrades_to_dispatched() {
        assertEquals(PhaseStep.DISPATCHED, phaseStepFor("weird", false))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.PhaseStepperTest"`
Expected: FAIL — compilation error / `Unresolved reference: phaseStepFor`.

- [ ] **Step 3: Create the composable + mapper**

Create `app/src/main/java/com/atomikpanda/groundcontrol/ui/activity/PhaseStepper.kt`:

```kotlin
package com.atomikpanda.groundcontrol.ui.activity

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.atomikpanda.groundcontrol.ui.theme.LocalSemanticColors
import com.atomikpanda.groundcontrol.ui.theme.MonoStyle

/** The five shared progress stages an operator sees after dispatch. */
enum class PhaseStep(val label: String) {
    DISPATCHED("Dispatched"),
    PLANNING("Planning"),
    BUILDING("Building"),
    REVIEW("Review"),
    DONE("Done"),
}

/**
 * Map a mothership task phase (`plan`/`dev`/`review`/`run`) plus a `done` flag (task
 * finished/merged) onto the shared stepper. `done` wins. An unknown/absent phase degrades to
 * [PhaseStep.DISPATCHED] so a freshly dispatched task with no phase yet still renders sensibly.
 */
fun phaseStepFor(taskPhase: String?, done: Boolean): PhaseStep = when {
    done -> PhaseStep.DONE
    taskPhase == "plan" -> PhaseStep.PLANNING
    taskPhase == "dev" -> PhaseStep.BUILDING
    taskPhase == "review" -> PhaseStep.REVIEW
    taskPhase == "run" -> PhaseStep.DONE
    else -> PhaseStep.DISPATCHED
}

/**
 * Horizontal 5-dot stepper. Completed stages read in the approval hue, the current stage pulses in
 * the primary color, future stages are muted. `compact = true` drops the labels for tight rows
 * (e.g. the spec-detail header).
 */
@Composable
fun PhaseStepper(current: PhaseStep, modifier: Modifier = Modifier, compact: Boolean = false) {
    val colors = LocalSemanticColors.current
    val pulse by rememberInfiniteTransition(label = "phasePulse").animateFloat(
        initialValue = 0.35f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(700), RepeatMode.Reverse),
        label = "phaseAlpha",
    )
    val dot = if (compact) 8.dp else 12.dp
    Row(
        modifier.fillMaxWidth().padding(horizontal = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PhaseStep.values().forEachIndexed { i, step ->
            val isDone = i < current.ordinal
            val isCurrent = i == current.ordinal
            val tint = when {
                isDone -> colors.approval
                isCurrent -> MaterialTheme.colorScheme.primary
                else -> colors.muted
            }
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.weight(1f),
            ) {
                Box(
                    Modifier
                        .size(dot)
                        .clip(CircleShape)
                        .alpha(if (isCurrent) pulse else 1f)
                        .background(tint),
                )
                if (!compact) {
                    Text(step.label, style = MonoStyle, color = tint)
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.PhaseStepperTest"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/src/main/java/com/atomikpanda/groundcontrol/ui/activity/PhaseStepper.kt app/src/test/java/com/atomikpanda/groundcontrol/PhaseStepperTest.kt
git commit -m "feat(ui): add shared PhaseStepper composable + phaseStepFor mapper"
mship journal "added shared PhaseStepper composable + pure phaseStepFor mapper (plan/dev/review/run -> steps); tests passing" --task gc-phase-progress-heartbeat --action committed
```
<!-- /mship:task -->

<!-- mship:task id=12 -->
### Task 12: Shared `LiveChip` composable + `liveStatus` classifier

**Files:**
- Create: `app/src/main/java/com/atomikpanda/groundcontrol/ui/activity/LiveChip.kt`
- Test: `app/src/test/java/com/atomikpanda/groundcontrol/LiveChipTest.kt` (create)

Reuses `com.atomikpanda.groundcontrol.notify.parseTimestampMillis(iso: String?): Long?` for ISO parsing.

- [ ] **Step 1: Write the failing test**

Create `LiveChipTest.kt`:

```kotlin
package com.atomikpanda.groundcontrol

import com.atomikpanda.groundcontrol.ui.activity.LiveStatus
import com.atomikpanda.groundcontrol.ui.activity.LiveThresholds
import com.atomikpanda.groundcontrol.ui.activity.liveStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveChipTest {
    private val base = 1_000_000_000L

    @Test fun working_when_activity_is_recent() {
        assertEquals(LiveStatus.Working, liveStatus(base, base + 30_000L, merged = false))
    }

    @Test fun idle_between_working_and_quiet_windows() {
        // 2 minutes: past the 90s working window, before the 5min quiet threshold.
        assertEquals(LiveStatus.Idle, liveStatus(base, base + 120_000L, merged = false))
    }

    @Test fun quiet_after_five_minutes_reports_minutes() {
        val s = liveStatus(base, base + 480_000L, merged = false) // 8 minutes
        assertTrue(s is LiveStatus.Quiet)
        assertEquals(8L, (s as LiveStatus.Quiet).minutes)
    }

    @Test fun done_when_merged_regardless_of_activity() {
        assertEquals(LiveStatus.Done, liveStatus(base, base + 10_000_000L, merged = true))
    }

    @Test fun unknown_when_absent_not_false_working() {
        assertEquals(LiveStatus.Unknown, liveStatus(null, base, merged = false))
    }

    @Test fun thresholds_are_named_constants() {
        assertEquals(90_000L, LiveThresholds.WORKING_WINDOW_MS)
        assertEquals(300_000L, LiveThresholds.QUIET_AFTER_MS)
    }

    @Test fun iso_overload_parses_then_classifies() {
        // 2026-07-13T12:00:00Z == 1_784_030_400_000 ms; +30s still working.
        val nowMs = 1_784_030_430_000L
        assertEquals(
            LiveStatus.Working,
            liveStatus("2026-07-13T12:00:00Z", nowMs, merged = false),
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.LiveChipTest"`
Expected: FAIL — compilation error / `Unresolved reference: liveStatus`.

- [ ] **Step 3: Create the composable + classifier**

Create `app/src/main/java/com/atomikpanda/groundcontrol/ui/activity/LiveChip.kt`:

```kotlin
package com.atomikpanda.groundcontrol.ui.activity

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.atomikpanda.groundcontrol.notify.parseTimestampMillis
import com.atomikpanda.groundcontrol.ui.theme.LocalSemanticColors
import com.atomikpanda.groundcontrol.ui.theme.MonoStyle

/** Named activity-chip thresholds (ac5). */
object LiveThresholds {
    /** Last activity newer than this reads as actively "working". */
    const val WORKING_WINDOW_MS = 90_000L
    /** Last activity older than this reads as "quiet Nm". */
    const val QUIET_AFTER_MS = 300_000L
}

/** Classified live state for the activity chip. */
sealed interface LiveStatus {
    data object Working : LiveStatus
    /** Between the working window and the quiet threshold: recently active, neutral. */
    data object Idle : LiveStatus
    data class Quiet(val minutes: Long) : LiveStatus
    /** Task finished/merged. */
    data object Done : LiveStatus
    /** No activity timestamp yet — neutral, never a false "working" (ac8). */
    data object Unknown : LiveStatus
}

/**
 * Pure classifier. `merged` wins; a null timestamp is [LiveStatus.Unknown] (never "working").
 * Clock skew (negative age) is clamped to 0 so a slightly-future stamp still reads as working.
 */
fun liveStatus(lastActivityMillis: Long?, nowMillis: Long, merged: Boolean): LiveStatus = when {
    merged -> LiveStatus.Done
    lastActivityMillis == null -> LiveStatus.Unknown
    else -> {
        val age = (nowMillis - lastActivityMillis).coerceAtLeast(0)
        when {
            age < LiveThresholds.WORKING_WINDOW_MS -> LiveStatus.Working
            age >= LiveThresholds.QUIET_AFTER_MS -> LiveStatus.Quiet(age / 60_000L)
            else -> LiveStatus.Idle
        }
    }
}

/** ISO-string overload: parses via [parseTimestampMillis] then classifies. */
fun liveStatus(lastActivityIso: String?, nowMillis: Long, merged: Boolean): LiveStatus =
    liveStatus(parseTimestampMillis(lastActivityIso), nowMillis, merged)

/** Pill chip: a colored dot (pulsing while working) + a short label. */
@Composable
fun LiveChip(
    lastActivityIso: String?,
    merged: Boolean,
    nowMillis: Long,
    modifier: Modifier = Modifier,
) {
    val colors = LocalSemanticColors.current
    val status = liveStatus(lastActivityIso, nowMillis, merged)
    val (label, tint) = when (status) {
        is LiveStatus.Working -> "working" to colors.approval
        is LiveStatus.Idle -> "idle" to colors.muted
        is LiveStatus.Quiet -> "quiet ${status.minutes}m" to colors.muted
        is LiveStatus.Done -> "done" to MaterialTheme.colorScheme.primary
        is LiveStatus.Unknown -> "—" to colors.muted
    }
    val pulse by rememberInfiniteTransition(label = "chipPulse").animateFloat(
        initialValue = 0.3f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(700), RepeatMode.Reverse),
        label = "chipAlpha",
    )
    Row(
        modifier
            .clip(RoundedCornerShape(50))
            .background(tint.copy(alpha = 0.12f))
            .padding(horizontal = 8.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .size(8.dp)
                .clip(CircleShape)
                .alpha(if (status is LiveStatus.Working) pulse else 1f)
                .background(tint),
        )
        Spacer(Modifier.size(6.dp))
        Text(label, style = MonoStyle, color = tint)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.LiveChipTest"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/src/main/java/com/atomikpanda/groundcontrol/ui/activity/LiveChip.kt app/src/test/java/com/atomikpanda/groundcontrol/LiveChipTest.kt
git commit -m "feat(ui): add shared LiveChip composable + liveStatus classifier"
mship journal "added shared LiveChip + pure liveStatus classifier (working/idle/quiet/done/unknown) with named thresholds; tests passing" --task gc-phase-progress-heartbeat --action committed
```
<!-- /mship:task -->

<!-- mship:task id=13 -->
### Task 13: Wire the full stepper + chip into the Console cockpit

**Files:**
- Modify: `app/src/main/java/com/atomikpanda/groundcontrol/ui/console/ConsoleScreen.kt` (`ConsoleContentView` line 103-141; add an `ActivityStrip` composable)
- Test: `app/src/test/java/com/atomikpanda/groundcontrol/ConsoleViewModelTest.kt` (create)

The Console already fans `GET /items/{id}` out into per-task `GET /tasks/{slug}` (`ConsoleViewModel.fetch`) and reuses a 4s poll (`startPolling`, line 83) — no new loop. The stepper/chip read the focused task's new DTO fields. The test proves those fields flow through the fan-out (feeding the stepper); the composable wiring is a pure render of already-tested logic.

- [ ] **Step 1: Write the failing test**

Create `ConsoleViewModelTest.kt`:

```kotlin
package com.atomikpanda.groundcontrol

import com.atomikpanda.groundcontrol.data.SpecApi
import com.atomikpanda.groundcontrol.data.WorkspaceConnection
import com.atomikpanda.groundcontrol.data.mshipDefaults
import com.atomikpanda.groundcontrol.ui.console.ConsoleUiState
import com.atomikpanda.groundcontrol.ui.console.ConsoleViewModel
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.engine.mock.respondError
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ConsoleViewModelTest {
    @Before fun setUp() = Dispatchers.setMain(StandardTestDispatcher())
    @After fun tearDown() = Dispatchers.resetMain()

    private val conn = WorkspaceConnection("1", "http://h:47100", "secret", "ws")
    private val jsonHdr = headersOf(HttpHeaders.ContentType, "application/json")

    private fun vm(
        scope: CoroutineScope,
        handler: io.ktor.client.engine.mock.MockRequestHandler,
    ): ConsoleViewModel {
        val api = SpecApi(HttpClient(MockEngine(handler)) { mshipDefaults() })
        return ConsoleViewModel(api, conn, "wi1", testScope = scope)
    }

    @Test fun fetch_surfaces_focused_task_activity_for_the_stepper() = runTest {
        val vm = vm(this) { req ->
            when (req.url.encodedPath) {
                "/items/wi1" -> respond(
                    """{"id":"wi1","kind":"feature","title":"T","phase":"in_flight",
                        "task_slugs":["s1"],"thread_ids":[]}""",
                    HttpStatusCode.OK, jsonHdr,
                )
                "/tasks/s1" -> respond(
                    """{"slug":"s1","phase":"dev","branch":"b","finished_at":null,
                        "last_activity_at":"2026-07-13T12:00:00Z"}""",
                    HttpStatusCode.OK, jsonHdr,
                )
                "/journal/s1" -> respond("""[]""", HttpStatusCode.OK, jsonHdr)
                else -> respondError(HttpStatusCode.NotFound)
            }
        }
        vm.load().join()
        val c = (vm.state.value as ConsoleUiState.Content).c
        val focused = c.tasks.first()
        assertEquals("dev", focused.phase)
        assertEquals("2026-07-13T12:00:00Z", focused.lastActivityAt)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.ConsoleViewModelTest"`
Expected: FAIL — assertion or (before Task 10 merged) `Unresolved reference: lastActivityAt`. If Task 10 is already merged the test should compile and pass on the data path; still add the UI wiring in Step 3 so the cockpit renders it.

- [ ] **Step 3: Render the stepper + chip in the Console**

In `app/src/main/java/com/atomikpanda/groundcontrol/ui/console/ConsoleScreen.kt`, add imports near the other `ui` imports:

```kotlin
import com.atomikpanda.groundcontrol.ui.activity.LiveChip
import com.atomikpanda.groundcontrol.ui.activity.PhaseStepper
import com.atomikpanda.groundcontrol.ui.activity.phaseStepFor
```

In `ConsoleContentView`, add an activity-strip item right after the header item. Change (lines 114-116):

```kotlin
            item { HeaderSection(c.item) }

            item { SectionLabel("TASKS") }
```
to:
```kotlin
            item { HeaderSection(c.item) }

            item { ActivityStrip(focusedTask) }

            item { SectionLabel("TASKS") }
```

Then add this private composable (place it right after `ConsoleContentView`, before `HeaderSection` at line 143):

```kotlin
@Composable
private fun ActivityStrip(task: TaskSummary?) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        PhaseStepper(phaseStepFor(task?.phase, task?.finishedAt != null))
        LiveChip(
            lastActivityIso = task?.lastActivityAt,
            merged = task?.finishedAt != null,
            nowMillis = System.currentTimeMillis(),
            modifier = Modifier.padding(top = 8.dp),
        )
    }
}
```

(`Column`, `Modifier`, `fillMaxWidth`, `padding`, `dp`, `TaskSummary` are already imported in this file. `focusedTask` is the task the Console already focuses — confirm the exact local/derived name in `ConsoleContentView` and use it; if the screen focuses `c.tasks.firstOrNull()`, use that.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.ConsoleViewModelTest"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/src/main/java/com/atomikpanda/groundcontrol/ui/console/ConsoleScreen.kt app/src/test/java/com/atomikpanda/groundcontrol/ConsoleViewModelTest.kt
git commit -m "feat(console): show full phase stepper + live chip alongside journal feed"
mship journal "Console cockpit renders PhaseStepper + LiveChip from focused task, reusing the 4s poll; VM fan-out test passing" --task gc-phase-progress-heartbeat --action committed
```
<!-- /mship:task -->

<!-- mship:task id=14 -->
### Task 14: SpecDetail — compact stepper + chip with an in-flight-only poll

**Files:**
- Modify: `app/src/main/java/com/atomikpanda/groundcontrol/data/SpecDetailRepository.kt` (add `loadTask`)
- Modify: `app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/SpecDetailViewModel.kt` (`SpecDetail` fields; poll)
- Modify: `app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/SpecDetailScreen.kt` (compact stepper + start/stop poll)
- Test: `app/src/test/java/com/atomikpanda/groundcontrol/SpecDetailViewModelTest.kt`

The poll re-reads the spec (authoritative status → detects terminal) plus its task (phase + activity). It runs only while the spec status is `dispatched` and stops at terminal (`implemented`/`archived`), mirroring `ConsoleViewModel.startPolling`.

- [ ] **Step 1: Write the failing test**

Append to `SpecDetailViewModelTest.kt`. Add these imports at the top of the file:

```kotlin
import kotlinx.coroutines.test.advanceUntilIdle
import java.util.ArrayDeque
```

Add the test methods to the class:

```kotlin
    @Test fun activity_poll_advances_task_phase_then_stops_at_terminal() = runTest {
        // /specs/s1: dispatched (initial load), dispatched (tick 1), implemented (tick 2 -> stop).
        val specStatuses = ArrayDeque(listOf("dispatched", "dispatched", "implemented"))
        val vm = vm(this) { req ->
            when (req.url.encodedPath) {
                "/specs/s1" -> {
                    val status = if (specStatuses.size > 1) specStatuses.removeFirst() else specStatuses.first()
                    respond(
                        """{"id":"s1","title":"T","status":"$status","body":"b","task_slug":"s1"}""",
                        HttpStatusCode.OK, jsonHdr,
                    )
                }
                "/tasks/s1" -> respond(
                    """{"slug":"s1","phase":"dev","branch":"b","finished_at":null,
                        "last_activity_at":"2026-07-13T12:00:00Z"}""",
                    HttpStatusCode.OK, jsonHdr,
                )
                else -> respondError(HttpStatusCode.NotFound)
            }
        }
        vm.load()?.join()
        vm.startActivityPolling(intervalMs = 1000)
        advanceUntilIdle()
        val c = vm.state.value as SpecDetailUiState.Content
        assertEquals("dev", c.detail.taskPhase)
        assertEquals("2026-07-13T12:00:00Z", c.detail.taskLastActivityAt)
        assertEquals("implemented", c.detail.status) // terminal reached; poll stopped
    }

    @Test fun activity_poll_does_not_run_for_non_dispatched_spec() = runTest {
        var taskCalls = 0
        val vm = vm(this) { req ->
            when (req.url.encodedPath) {
                "/specs/s1" -> respond(
                    """{"id":"s1","title":"T","status":"approved","body":"b","task_slug":"s1"}""",
                    HttpStatusCode.OK, jsonHdr,
                )
                "/tasks/s1" -> { taskCalls++; respond("""{"slug":"s1","phase":"plan","branch":"b"}""", HttpStatusCode.OK, jsonHdr) }
                else -> respondError(HttpStatusCode.NotFound)
            }
        }
        vm.load()?.join()
        vm.startActivityPolling(intervalMs = 1000)
        advanceUntilIdle()
        assertEquals(0, taskCalls) // never polled a non-dispatched (approved) spec
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.SpecDetailViewModelTest"`
Expected: FAIL — `Unresolved reference: startActivityPolling` / `taskPhase`.

- [ ] **Step 3: Add the repository seam, the VM state + poll, and the screen wiring**

In `SpecDetailRepository.kt`, add the import and method:

```kotlin
import com.atomikpanda.groundcontrol.data.dto.TaskSummary
```
```kotlin
    suspend fun loadTask(conn: WorkspaceConnection, slug: String): TaskSummary = api.getTask(conn, slug)
```

In `SpecDetailViewModel.kt`, add three fields to the `SpecDetail` data class (after `questions` at line 47, before the closing paren):

```kotlin
    val criteria: List<ReviewCriterion>,
    val questions: List<ReviewQuestion>,
    val taskPhase: String? = null,
    val taskLastActivityAt: String? = null,
    val taskFinished: Boolean = false,
) {
```

Add these imports near the top:

```kotlin
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
```

Add the poll + one-tick refresh to `SpecDetailViewModel` (place after the `load()` method, ~line 92):

```kotlin
    private fun isSpecInFlight(status: String): Boolean = status == "dispatched"

    /**
     * Poll the task behind a dispatched spec so the compact stepper + chip advance live.
     * Runs only while the spec is in-flight (`dispatched`) and stops at terminal
     * (`implemented`/`archived`) or when the task can't be resolved. Mirrors
     * ConsoleViewModel.startPolling. Cancel via the returned Job (bound to the screen lifecycle).
     */
    fun startActivityPolling(intervalMs: Long = 4000): Job = scope().launch {
        while (isActive) {
            val c = content() ?: break
            if (!isSpecInFlight(c.detail.status)) break
            delay(intervalMs)
            if (!refreshActivityOnce()) break
        }
    }

    /** One activity tick: re-read spec (authoritative status) + its task (phase + activity).
     *  Returns true to keep polling. Transient fetch failures keep polling; a missing task slug
     *  or missing content stops it. */
    private suspend fun refreshActivityOnce(): Boolean {
        val slug = content()?.detail?.taskSlug ?: return false
        val spec = runCatching { repo.load(conn, specId) }.getOrNull() ?: return true
        val task = runCatching { repo.loadTask(conn, spec.taskSlug ?: slug) }.getOrNull()
        val c = content() ?: return false
        _state.value = c.copy(
            detail = c.detail.copy(
                status = spec.status,
                taskSlug = spec.taskSlug ?: c.detail.taskSlug,
                taskPhase = task?.phase ?: c.detail.taskPhase,
                taskLastActivityAt = task?.lastActivityAt ?: c.detail.taskLastActivityAt,
                taskFinished = task?.finishedAt != null,
            ),
        )
        return isSpecInFlight(spec.status)
    }
```

(Confirm the exact accessor names against the current `SpecDetailViewModel`: `scope()`, `content()`, `_state`, `repo`, `conn`, `specId`, and the `SpecDetail` field `taskSlug`. Adapt to the file's actual conventions — these mirror the Console VM's patterns.)

In `SpecDetailScreen.kt`, add imports:

```kotlin
import androidx.compose.runtime.DisposableEffect
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import com.atomikpanda.groundcontrol.ui.activity.LiveChip
import com.atomikpanda.groundcontrol.ui.activity.PhaseStepper
import com.atomikpanda.groundcontrol.ui.activity.phaseStepFor
```

In `SpecDetailScreen` (the top-level composable), after `LaunchedEffect(Unit) { vm.load() }` (line 63), add the poll lifecycle:

```kotlin
    // Poll the in-flight task only while the spec is dispatched; stop at terminal.
    val pollStatus = (state as? SpecDetailUiState.Content)?.detail?.status
    DisposableEffect(pollStatus) {
        val job = if (pollStatus == "dispatched") vm.startActivityPolling() else null
        onDispose { job?.cancel() }
    }
```

In `ContentView`, inside the first `item { Column(...) { ... } }` block, add the compact stepper + chip after `ReadinessChipsRow(sum, ...)` (line 127), still inside the `Column`:

```kotlin
                    ReadinessChipsRow(sum, Modifier.padding(top = 6.dp))
                    if (d.taskSlug != null) {
                        Spacer(Modifier.height(8.dp))
                        PhaseStepper(phaseStepFor(d.taskPhase, d.taskFinished), compact = true)
                        LiveChip(
                            lastActivityIso = d.taskLastActivityAt,
                            merged = d.taskFinished,
                            nowMillis = System.currentTimeMillis(),
                            modifier = Modifier.padding(top = 6.dp),
                        )
                    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.SpecDetailViewModelTest"`
Expected: PASS (all SpecDetail tests).

- [ ] **Step 5: Commit**

```bash
git add app/src/main/java/com/atomikpanda/groundcontrol/data/SpecDetailRepository.kt app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/SpecDetailViewModel.kt app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/SpecDetailScreen.kt app/src/test/java/com/atomikpanda/groundcontrol/SpecDetailViewModelTest.kt
git commit -m "feat(specdetail): compact stepper + live chip with in-flight-only activity poll"
mship journal "SpecDetail shows compact stepper+chip after dispatch; new poll runs only while dispatched, stops at terminal; VM poll tests passing" --task gc-phase-progress-heartbeat --action committed
```
<!-- /mship:task -->

---

## Final verification

After Task 14, run the full suites once from each worktree root:

- mothership: `uv run pytest tests/ -q`
- ground-control (`cd ground-control/android` after `source ~/toolchains/android-env.sh`): `./gradlew --offline testDebugUnitTest`

Both must be green before `mship finish`.

---

## Self-Review

**1. Spec coverage** — each acceptance criterion maps to at least one task:

| AC | Requirement | Task(s) |
|---|---|---|
| ac1 | mship stamps `last_activity_at` on journal, commit, test, phase, spec apply — agent-agnostic | T1 (field), T2 (helper), T3 (journal), T4 (commit), T5 (test + phase), T6 (spec apply) |
| ac2 | `mship heartbeat --task <slug>` updates `last_activity_at`, no other side effects | T7 (incl. `test_heartbeat_has_no_other_side_effects`) |
| ac3 | `GET /tasks{,/{slug}}` include `last_activity_at` + `phase_entered_at`; `GET /items/{id}` surfaces active task's `last_activity_at` + phase | T8 (tasks endpoints), T9 (items endpoint) |
| ac4 | Shared phase stepper (Dispatched→Planning→Building→Review→Done) driven by `task.phase`, current stage animated | T11 (`phaseStepFor` + animated `PhaseStepper`); wired in T13 (Console) and T14 (SpecDetail) |
| ac5 | Live chip from `last_activity_at`: working (<~90s), quiet <N>m (after ~5min), done on merge; named-constant thresholds | T12 (`LiveThresholds`, `liveStatus`, `LiveChip`) |
| ac6 | SpecDetail shows compact stepper+chip after Dispatch, polling only while dispatched/in-flight, stopping at terminal | T14 (compact stepper + `startActivityPolling` gated on `dispatched`, stops at `implemented`/`archived`) |
| ac7 | Console/WorkItem cockpit shows full stepper + chip alongside journal feed, reusing its 4s poll (no new loop) | T13 (renders from focused task; reuses `ConsoleViewModel.startPolling`) |
| ac8 | Absent `last_activity_at` degrades gracefully (stepper still shows phase; chip neutral/unknown, not false "working") | T11 (`phaseStepFor(null, …) → Dispatched`), T12 (`liveStatus(null, …) → Unknown`), verified by `unknown_when_absent_not_false_working` |

No gaps.

**2. Placeholder scan** — no `TBD`/`TODO`/"implement later" in any step. Every code step contains complete, compilable code and every test step contains complete test code. Exact run commands with expected outcomes are given. Two GC tasks (T13, T14) carry explicit "confirm the exact accessor name against the current file" notes because the Console/SpecDetail VM internals (focused-task local, `scope()`/`content()`/`_state`) must match the actual file — adapt names, keep the shape.

**3. Type / name consistency across tasks:**
- `StateManager.record_activity(slug, now=None)` — defined T2, called identically in T3, T4, T6, T7.
- `Task.last_activity_at` — defined T1; read by T8, T9; stamped inline in T5.
- `TaskSummary` gains `last_activity_at` + `phase_entered_at` (T8); DTO gains `lastActivityAt` + `phaseEnteredAt` (`@SerialName("last_activity_at")`/`("phase_entered_at")`) (T10) — server key ↔ DTO name match verified.
- `WorkItemSummary` gains `active_phase` + `active_last_activity_at` (T9); DTO `activePhase`/`activeLastActivityAt` with matching `@SerialName`s (T10).
- `PhaseStep` enum + `phaseStepFor(taskPhase: String?, done: Boolean)` — defined T11; consumed with the same signature in T13 (`phaseStepFor(task?.phase, task?.finishedAt != null)`) and T14 (`phaseStepFor(d.taskPhase, d.taskFinished)`).
- `LiveStatus`, `LiveThresholds.WORKING_WINDOW_MS`/`QUIET_AFTER_MS`, `liveStatus(...)` (both `Long?` and `String?` overloads), `LiveChip(lastActivityIso, merged, nowMillis, modifier)` — defined T12; `LiveChip` invoked with the same named params in T13 and T14.

One deliberate design note: locked decision lists `test` under "call `record_activity`", but `mship test` and the phase transition both already hold a `state_manager.mutate(...)`; folding the one-line stamp into those existing mutates (T5) is strictly cheaper (no second lock) and mirrors the `phase_entered_at` precedent — same field write, same observable result. journal, commit, spec apply, and heartbeat use `record_activity` directly.
