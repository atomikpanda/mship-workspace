# Auto-Advance-On-Merge — Implementation Plan

**Spec id:** `auto-advance-on-merge` (status: approved + dispatched)

**REQUIRED SUB-SKILL:** Execute this plan one task at a time with test-driven-development (write the failing test first, watch it fail, implement, watch it pass, commit). Do NOT batch tasks. Steps use checkbox tracking.

## Goal
When a PR merges, the `mship serve` PR-watcher auto-advances the bound spec (`dispatched -> implemented`) and its WorkItem (-> `done`, `needs_review` cleared) with zero manual `mship close`. Simultaneously make worktree teardown safe: never delete a worktree that has uncommitted OR unpushed changes unless `--force`, and remove the silent `shutil.rmtree` data-loss fallback.

## Architecture (build around these — verified by reading the worktree code)
- Projections are read-time and input-driven. `compute_phase` / `compute_attention` (`src/mship/core/view/workitem_index.py:31-83`) store nothing. A terminal spec status (`implemented`/`archived`) projects `done` before task-state checks (line 39-40); `needs_review` = `any(bool(t.pr_urls) for t in tasks)` (line 80). So advancing the spec to `implemented` and tearing the task down (removing its `pr_urls` from state) fixes phase AND attention together.
- Advance logic already exists and is idempotent. `advance_spec_on_close(*, task, specs_dir, merged_count, closed_count)` (`src/mship/core/spec_lifecycle.py:8`) no-ops unless `task.spec_id` set, all merged (`merged_count>0 and closed_count==0`), and spec status is exactly `dispatched`. `advance_workitem_on_close(*, task, workitems_dir, specs_dir, state, merged_count, closed_count)` (`src/mship/core/workitem_lifecycle.py:16`) no-ops unless it's the WorkItem's last live task after a clean full merge. Today both are called ONLY from `mship close` (`src/mship/cli/worktree.py:834, :853`).
- Merge detection lives in `PrWatcher` (`src/mship/core/pr_watcher.py`, NOT under `relay/`). `check_once()` -> per-PR `_check_one(slug, task, repo, url)` -> `check_state(url)` returns `"merged"|"closed"|"open"|"unknown"`; terminal states fire `_fire_lifecycle_hook(st, slug, repo)` (before the durable dedup marker is written) then `_post_event(...)`. Deps available: `msgs`, `workitems`, `state_manager`, `check_state`, `now_fn`, `lock`, `config`, `workspace_root`, `shell`. It is sync; `serve` runs it via `asyncio.to_thread`. The auto-close hooks in right after `_fire_lifecycle_hook`, gated on an injected `worktree_manager` (mirrors how `config` gates lifecycle hooks) so every existing test — none of which pass a `worktree_manager` — is unaffected.
- Teardown primitive: `WorktreeManager.abort` (`src/mship/core/worktree.py:726`) iterates `task.worktrees`, skips `git_root` repos, `git worktree remove` then `except: shutil.rmtree(ignore_errors=True)` (the data-loss fallback, line 744), `branch_delete`, then `shutil.rmtree` the hub, then pops state. The guard + `force` param + fallback removal all land HERE so it's universal.
- Reused git helpers (exact names): `GitRunner.has_uncommitted_changes(repo_path)` (`src/mship/util/git.py:127`, runs `git status --porcelain`) for uncommitted; `GitRunner.has_remote(repo_path, "origin")` (`:17`) to detect a remote. Unpushed needs a NEW `GitRunner.has_unpushed_commits`. Marker/gitignore writes go to the hub (`write_marker(hub, ...)`), NOT into each repo worktree, so a freshly-spawned worktree is clean per `git status --porcelain` — the guard does not falsely trip on spawn.
- `SPECS_DIRNAME = "specs"` (`src/mship/core/spec_store.py:10`): specs live at `<workspace_root>/specs`, workitems at `<workspace_root>/.mothership/workitems`.
- `mship close` already has `--force` (`src/mship/cli/worktree.py:561`) and `--abandon` (`:562`); its single `wt_mgr.abort(task_slug)` call is at `:884`. Thread `force` in there and catch the new dirty error.

### Dirtiness contract (locked — do NOT redesign)
- Uncommitted = `git status --porcelain` non-empty in the worktree (`has_uncommitted_changes`).
- Unpushed (`has_unpushed_commits(worktree_path)`):
  - No `origin` remote at all -> `False` (nothing to push to; every no-remote fixture must still tear down).
  - Upstream tracking ref set (post-`finish` this is `origin/<branch>`) -> `True` iff `git rev-list --count @{u}..HEAD > 0`.
  - `origin` exists but branch has NO upstream (never `push -u`'d) -> `True` (can't prove commits are on origin -> refuse). This is the "no upstream + has commits -> unpushed-safe -> refuse" decision.
- Guard runs as a pre-pass over all non-`git_root` worktrees before removing any; if ANY is dirty/unpushed and not `force`, the WHOLE task teardown raises `WorktreeDirtyError` (nothing removed, state untouched).

## Tech Stack
Python 3, pytest, `uv`. All commands run from the worktree root:
`/home/bailey/development/repos/mship-workspace/.worktrees/auto-advance-on-merge/mothership`

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `src/mship/util/git.py` | modify | Add `has_unpushed_commits(worktree_path)`. |
| `tests/util/test_git.py` | modify | Unit tests for `has_unpushed_commits`. |
| `src/mship/core/worktree.py` | modify | `WorktreeDirtyError`, module logger, `_dirty_worktrees`, `abort(force=False)` guard, remove rmtree fallback, guard hub rmtree, idempotent no-op. |
| `tests/core/test_worktree.py` | modify | Guard/force/clean/idempotent/no-rmtree abort tests. |
| `src/mship/cli/worktree.py` | modify | Thread `force` into `abort`; catch/surface `WorktreeDirtyError`. |
| `tests/cli/test_worktree.py` | modify | Close threads `--force`; surfaces dirty error. |
| `src/mship/core/pr_watcher.py` | modify | `worktree_manager` param; `_auto_close_on_merge`; skip-note; call from `_check_one`. |
| `src/mship/core/serve.py` | modify | Pass `worktree_manager` into `PrWatcher`. |
| `tests/core/test_pr_watcher.py` | modify | Auto-advance happy path, skip-note, idempotency, fail-open. |
| `tests/core/test_serve_pr_watch.py` | modify | `create_app` wires `worktree_manager` into the watcher. |
| `src/mship/skills/finishing-a-development-branch/SKILL.md` | modify | Merge auto-advances; close only to force-teardown a dirty worktree. |
| `src/mship/skills/working-with-mothership/SKILL.md` | modify | Same messaging in the close/lifecycle sections. |

> NOTE (controller): the plan's per-task commit step shows `mship journal --task auto-advance-on-merge` with no message — that's the READ path. When executing, journal WITH a message, e.g. `mship journal "task N: <what>" --task auto-advance-on-merge --action committed`.

---

<!-- mship:task id=1 -->
## Task 1 — `GitRunner.has_unpushed_commits`

**Files:** `src/mship/util/git.py`, `tests/util/test_git.py`

- [ ] **Step 1 — Write the failing test**
Append to `tests/util/test_git.py` (reuses the file's existing `ENV`, `_run`, `_rev`, `_repo_with_origin_ahead`, `git_repo`):

```python
# ---------------------------------------------------------------------------
# has_unpushed_commits — teardown guard (spec auto-advance-on-merge)
# ---------------------------------------------------------------------------

def test_has_unpushed_commits_false_when_no_remote(git_repo: Path):
    # A repo with no `origin` has nothing to push to; teardown must not be blocked.
    git = GitRunner()
    assert git.has_unpushed_commits(git_repo) is False


def test_has_unpushed_commits_false_when_fully_pushed(tmp_path: Path):
    # `_repo_with_origin_ahead` leaves `clone` at origin/main (nothing ahead).
    _repo, _tip = _repo_with_origin_ahead(tmp_path)
    clone = tmp_path / "svc-clone"
    git = GitRunner()
    assert git.has_unpushed_commits(clone) is False


def test_has_unpushed_commits_true_when_local_ahead_of_upstream(tmp_path: Path):
    _repo, _tip = _repo_with_origin_ahead(tmp_path)
    clone = tmp_path / "svc-clone"
    (clone / "c.txt").write_text("3")
    _run(["git", "add", "-A"], clone)
    _run(["git", "commit", "-m", "c3 (unpushed)"], clone)
    git = GitRunner()
    assert git.has_unpushed_commits(clone) is True


def test_has_unpushed_commits_true_when_origin_exists_but_no_upstream(tmp_path: Path):
    _repo, _tip = _repo_with_origin_ahead(tmp_path)
    clone = tmp_path / "svc-clone"
    _run(["git", "checkout", "-b", "feat/never-pushed"], clone)  # no upstream tracking
    git = GitRunner()
    assert git.has_unpushed_commits(clone) is True
```

- [ ] **Step 2 — Run to fail**
`uv run pytest tests/util/test_git.py -k has_unpushed_commits -v`
Expected: `AttributeError: 'GitRunner' object has no attribute 'has_unpushed_commits'`.

- [ ] **Step 3 — Implement**
Add to `GitRunner` in `src/mship/util/git.py` (e.g. after `has_uncommitted_changes`):

```python
    def has_unpushed_commits(self, worktree_path: Path) -> bool:
        """True if the worktree's current branch has commits not safely on origin.

        Semantics (teardown guard, spec auto-advance-on-merge):
        - No `origin` remote at all -> False (nothing to push to; a no-remote
          checkout can't have "unpushed" work in the sense this guard protects,
          and every no-remote fixture must still tear down).
        - Upstream tracking ref set (post-`finish`, this is origin/<branch>) ->
          True iff `git rev-list --count @{u}..HEAD` > 0.
        - `origin` exists but the branch has NO upstream tracking ref (it was
          never `push -u`'d) -> True: we can't prove its commits are on origin,
          so refuse (conservative).
        Any git error -> True (conservative: refuse rather than risk data loss).
        """
        if not self.has_remote(worktree_path, "origin"):
            return False
        upstream = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
            cwd=worktree_path, capture_output=True, text=True,
        )
        if upstream.returncode != 0:
            return True
        ahead = subprocess.run(
            ["git", "rev-list", "--count", "@{u}..HEAD"],
            cwd=worktree_path, capture_output=True, text=True,
        )
        if ahead.returncode != 0:
            return True
        try:
            return int(ahead.stdout.strip() or "0") > 0
        except ValueError:
            return True
```

- [ ] **Step 4 — Run to pass** `uv run pytest tests/util/test_git.py -v`
- [ ] **Step 5 — Commit** (`git add ...; git commit -m "Add GitRunner.has_unpushed_commits for teardown guard"; mship journal "task 1: has_unpushed_commits" --task auto-advance-on-merge --action committed`)
<!-- /mship:task -->

---

<!-- mship:task id=2 -->
## Task 2 — Dirty/unpushed guard + `force` in `WorktreeManager.abort`; remove rmtree fallback

**Files:** `src/mship/core/worktree.py`, `tests/core/test_worktree.py`

- [ ] **Step 1 — Write the failing tests**
Append to `tests/core/test_worktree.py` (module already imports `os`, `subprocess`, `pytest`, `Path`, `WorktreeManager`, and defines the `worktree_deps` fixture):

```python
# ---------------------------------------------------------------------------
# abort teardown guard (spec auto-advance-on-merge)
# ---------------------------------------------------------------------------

def test_abort_refuses_dirty_worktree_and_leaves_it_intact(worktree_deps):
    from mship.core.worktree import WorktreeDirtyError
    config, graph, state_mgr, git, shell, workspace, log = worktree_deps
    mgr = WorktreeManager(config, graph, state_mgr, git, shell, log)
    mgr.spawn("dirty task", repos=["shared"], workspace_root=workspace)
    wt = Path(state_mgr.load().tasks["dirty-task"].worktrees["shared"])
    (wt / "scratch.txt").write_text("uncommitted work")

    with pytest.raises(WorktreeDirtyError):
        mgr.abort("dirty-task")

    assert wt.exists()                                   # left intact (ac4)
    assert "dirty-task" in state_mgr.load().tasks        # state unchanged


def test_abort_force_removes_dirty_worktree(worktree_deps):
    config, graph, state_mgr, git, shell, workspace, log = worktree_deps
    mgr = WorktreeManager(config, graph, state_mgr, git, shell, log)
    mgr.spawn("dirty task", repos=["shared"], workspace_root=workspace)
    wt = Path(state_mgr.load().tasks["dirty-task"].worktrees["shared"])
    (wt / "scratch.txt").write_text("uncommitted work")

    mgr.abort("dirty-task", force=True)                  # ac5

    assert not wt.exists()
    assert "dirty-task" not in state_mgr.load().tasks


def test_abort_clean_worktree_still_torn_down_without_force(worktree_deps):
    config, graph, state_mgr, git, shell, workspace, log = worktree_deps
    mgr = WorktreeManager(config, graph, state_mgr, git, shell, log)
    mgr.spawn("clean task", repos=["shared"], workspace_root=workspace)
    wt = Path(state_mgr.load().tasks["clean-task"].worktrees["shared"])

    mgr.abort("clean-task")                              # ac6

    assert not wt.exists()
    assert "clean-task" not in state_mgr.load().tasks


def test_abort_idempotent_when_task_already_gone(worktree_deps):
    config, graph, state_mgr, git, shell, workspace, log = worktree_deps
    mgr = WorktreeManager(config, graph, state_mgr, git, shell, log)
    mgr.abort("never-existed")                           # ac7: no KeyError, no raise


def test_abort_does_not_rmtree_when_git_remove_fails(worktree_deps, monkeypatch):
    """The silent shutil.rmtree(ignore_errors=True) data-loss fallback is REMOVED:
    a worktree git refused to remove is LEFT on disk, not force-deleted, and the
    hub is not nuked either."""
    config, graph, state_mgr, git, shell, workspace, log = worktree_deps
    mgr = WorktreeManager(config, graph, state_mgr, git, shell, log)
    mgr.spawn("keep task", repos=["shared"], workspace_root=workspace)
    wt = Path(state_mgr.load().tasks["keep-task"].worktrees["shared"])

    def _boom(**kwargs):
        raise RuntimeError("git worktree remove refused")
    monkeypatch.setattr(git, "worktree_remove", _boom)

    mgr.abort("keep-task")                               # clean tree -> guard passes

    assert wt.exists()                                   # NOT rmtree'd (fallback gone)
    assert "keep-task" not in state_mgr.load().tasks     # state still cleared
```

- [ ] **Step 2 — Run to fail**
`uv run pytest tests/core/test_worktree.py -k "abort_refuses_dirty or abort_force_removes or abort_clean_worktree or abort_idempotent or does_not_rmtree" -v`
Expected: ImportError/TypeError (no `WorktreeDirtyError`, `abort()` has no `force` kwarg); the rmtree test fails (dir deleted by current fallback/hub rmtree).

- [ ] **Step 3 — Implement**
In `src/mship/core/worktree.py`:

1. Add near the top (after existing imports):
```python
import logging

logger = logging.getLogger(__name__)
```

2. Add the exception (next to `BaseBranchNotFoundError`):
```python
class WorktreeDirtyError(RuntimeError):
    """Raised by WorktreeManager.abort when a repo's worktree has uncommitted
    or unpushed changes and force was not requested. Carries the offending
    repos so callers can render an actionable message and never lose work."""

    def __init__(self, task_slug: str, dirty: dict[str, str]) -> None:
        self.task_slug = task_slug
        self.dirty = dirty  # repo_name -> reason ("uncommitted changes" | "unpushed commits")
        details = "; ".join(f"{repo}: {reason}" for repo, reason in dirty.items())
        super().__init__(
            f"Refusing to tear down '{task_slug}': {details}. "
            f"Resolve them, or pass --force to delete the worktree anyway."
        )
```

3. Add the pre-pass helper (method on `WorktreeManager`):
```python
    def _dirty_worktrees(self, task) -> dict[str, str]:
        """Return {repo_name: reason} for each affected repo's worktree with
        uncommitted changes OR unpushed commits. Empty dict = safe to tear down.
        Skips git_root repos (their worktree is a subdir of the parent's) and
        already-gone paths (nothing to lose)."""
        dirty: dict[str, str] = {}
        for repo_name, wt_path in task.worktrees.items():
            if self._config.repos[repo_name].git_root is not None:
                continue
            p = Path(wt_path)
            if not p.exists():
                continue
            if self._git.has_uncommitted_changes(p):
                dirty[repo_name] = "uncommitted changes"
            elif self._git.has_unpushed_commits(p):
                dirty[repo_name] = "unpushed commits"
        return dirty
```

4. Replace the whole `abort` method (lines ~726-775) with:
```python
    def abort(self, task_slug: str, force: bool = False) -> None:
        state = self._state_manager.load()
        task = state.tasks.get(task_slug)
        if task is None:
            return  # idempotent: already torn down (spec ac7)

        # Universal safety guard: never delete a worktree with uncommitted or
        # unpushed changes unless force. Pre-pass over ALL worktrees before
        # removing any, so a dirty repo refuses the whole task's teardown.
        if not force:
            dirty = self._dirty_worktrees(task)
            if dirty:
                raise WorktreeDirtyError(task_slug, dirty)

        removal_failed = False
        for repo_name, wt_path in task.worktrees.items():
            repo_config = self._config.repos[repo_name]

            # Skip git_root repos — their "worktree" is just a subdirectory
            # of the parent's worktree and will disappear with it
            if repo_config.git_root is not None:
                continue

            try:
                self._git.worktree_remove(
                    repo_path=repo_config.path,
                    worktree_path=Path(wt_path),
                )
            except Exception:
                # The silent shutil.rmtree(ignore_errors=True) data-loss fallback
                # was REMOVED (spec ac4): never blow away a directory git refused
                # to remove. Leave it for `mship prune` to reap.
                removal_failed = True
                logger.warning(
                    "worktree remove failed for %s (%s); left intact", repo_name, wt_path,
                )
            try:
                self._git.branch_delete(
                    repo_path=repo_config.path,
                    branch=task.branch,
                )
            except Exception:
                pass

        # Remove the hub directory for this task, but ONLY when every worktree
        # was cleanly removed — otherwise nuking the hub would delete a worktree
        # git just refused to remove (defeating the fallback removal above).
        if not removal_failed:
            try:
                sample_wt = None
                for name, wt in task.worktrees.items():
                    if self._config.repos[name].git_root is None:
                        sample_wt = wt
                        break
                if sample_wt is not None:
                    hub = Path(sample_wt).parent
                    if hub.name == task_slug and hub.parent.name == ".worktrees":
                        if hub.exists():
                            shutil.rmtree(hub, ignore_errors=True)
            except Exception:
                pass

        # Only update state after all cleanup attempts
        def _abort(s):
            s.tasks.pop(task_slug, None)
        self._state_manager.mutate(_abort)
```

- [ ] **Step 4 — Run to pass** `uv run pytest tests/core/test_worktree.py -v` (incl. pre-existing abort tests — their worktrees have no origin so the guard is a no-op).
- [ ] **Step 5 — Commit** (`... "Guard WorktreeManager.abort against dirty/unpushed teardown; remove rmtree fallback"`; journal with a message).
<!-- /mship:task -->

---

<!-- mship:task id=3 -->
## Task 3 — Thread `--force` through `mship close` and surface `WorktreeDirtyError`

**Files:** `src/mship/cli/worktree.py`, `tests/cli/test_worktree.py`

- [ ] **Step 1 — Write the failing tests**
Append to `tests/cli/test_worktree.py` (module already has `runner = CliRunner()` and the `configured_git_app` fixture; imports done locally per file style):

```python
def test_close_threads_force_true_to_abort(configured_git_app):
    from datetime import datetime, timezone
    from unittest.mock import MagicMock
    from mship.cli import container
    from mship.core.state import StateManager, Task, WorkspaceState
    from mship.util.shell import ShellRunner, ShellResult
    from typer.testing import CliRunner
    from mship.cli import app as _app

    sm = StateManager(configured_git_app / ".mothership")
    sm.save(WorkspaceState(tasks={"t": Task(
        slug="t", description="d", phase="review",
        created_at=datetime.now(timezone.utc),
        affected_repos=["shared"], branch="feat/t",
        pr_urls={"shared": "https://github.com/o/r/pull/1"},
        finished_at=datetime.now(timezone.utc),
    )}))

    mock_shell = MagicMock(spec=ShellRunner)
    mock_shell.run.return_value = ShellResult(returncode=0, stdout="MERGED\n", stderr="")
    mock_shell.run_task.return_value = ShellResult(returncode=0, stdout="", stderr="")

    class _Rec:
        def __init__(self): self.calls = []
        def abort(self, task_slug, force=False): self.calls.append((task_slug, force))

    rec = _Rec()
    container.shell.override(mock_shell)
    container.worktree_manager.override(rec)
    try:
        result = CliRunner().invoke(_app, ["close", "--yes", "--force", "--task", "t"])
        assert result.exit_code == 0, result.output
        assert rec.calls == [("t", True)]              # ac5: force reaches the primitive
    finally:
        container.shell.reset_override()
        container.worktree_manager.reset_override()


def test_close_surfaces_worktree_dirty_error_and_keeps_task(configured_git_app):
    from datetime import datetime, timezone
    from unittest.mock import MagicMock
    from mship.cli import container
    from mship.core.state import StateManager, Task, WorkspaceState
    from mship.util.shell import ShellRunner, ShellResult
    from typer.testing import CliRunner
    from mship.cli import app as _app

    sm = StateManager(configured_git_app / ".mothership")
    sm.save(WorkspaceState(tasks={"t": Task(
        slug="t", description="d", phase="review",
        created_at=datetime.now(timezone.utc),
        affected_repos=["shared"], branch="feat/t",
        pr_urls={"shared": "https://github.com/o/r/pull/1"},
        finished_at=datetime.now(timezone.utc),
    )}))

    mock_shell = MagicMock(spec=ShellRunner)
    mock_shell.run.return_value = ShellResult(returncode=0, stdout="MERGED\n", stderr="")
    mock_shell.run_task.return_value = ShellResult(returncode=0, stdout="", stderr="")

    class _Dirty:
        def abort(self, task_slug, force=False):
            from mship.core.worktree import WorktreeDirtyError
            if not force:
                raise WorktreeDirtyError(task_slug, {"shared": "uncommitted changes"})

    container.shell.override(mock_shell)
    container.worktree_manager.override(_Dirty())
    try:
        result = CliRunner().invoke(_app, ["close", "--yes", "--task", "t"])
        assert result.exit_code != 0
        assert "uncommitted changes" in result.output
        assert "--force" in result.output
        assert "t" in sm.load().tasks                   # ac3: task NOT removed
    finally:
        container.shell.reset_override()
        container.worktree_manager.reset_override()
```

- [ ] **Step 2 — Run to fail**
`uv run pytest tests/cli/test_worktree.py -k "threads_force_true or surfaces_worktree_dirty" -v`
Expected: force test records `("t", False)`; dirty test raises uncaught.

- [ ] **Step 3 — Implement**
In `src/mship/cli/worktree.py`, replace the abort call site (line ~883-884):
```python
        wt_mgr = container.worktree_manager()
        wt_mgr.abort(task_slug)  # core method retains the name; only CLI verb changed
```
with:
```python
        wt_mgr = container.worktree_manager()
        from mship.core.worktree import WorktreeDirtyError
        try:
            wt_mgr.abort(task_slug, force=force)  # core method retains the name; only CLI verb changed
        except WorktreeDirtyError as e:
            output.error(str(e))
            output.error("Resolve the changes (commit/push), or re-run `mship close --force` to discard them.")
            raise typer.Exit(code=1)
```

- [ ] **Step 4 — Run to pass** `uv run pytest tests/cli/test_worktree.py -v`
- [ ] **Step 5 — Commit** (`... "Thread --force through mship close; surface WorktreeDirtyError"`; journal with message).
<!-- /mship:task -->

---

<!-- mship:task id=4 -->
## Task 4 — Inject `worktree_manager` into `PrWatcher` and wire it in `serve.create_app`

**Files:** `src/mship/core/pr_watcher.py`, `src/mship/core/serve.py`, `tests/core/test_pr_watcher.py`, `tests/core/test_serve_pr_watch.py`

- [ ] **Step 1 — Write the failing tests**
Append to `tests/core/test_pr_watcher.py`:
```python
def test_pr_watcher_stores_worktree_manager():
    msgs = FakeMessageStore()
    workitems = FakeWorkItemStore()
    state = FakeStateManager({})
    sentinel = object()
    watcher = PrWatcher(
        msgs, workitems, state, lambda u: "open", now_fn,
        worktree_manager=sentinel,
    )
    assert watcher.worktree_manager is sentinel
```

Append to `tests/core/test_serve_pr_watch.py`:
```python
def test_create_app_wires_worktree_manager_into_watcher(tmp_path, monkeypatch):
    """serve.create_app must forward its worktree_manager into the PrWatcher it
    builds in the lifespan, so merge auto-close has a teardown primitive."""
    captured = {}

    class _StubWatcher:
        def __init__(self, *args, **kwargs):
            captured.update(kwargs)

        def check_once(self):
            pass

    monkeypatch.setattr("mship.core.serve.PrWatcher", _StubWatcher)
    monkeypatch.setenv("MSHIP_PR_WATCH_INTERVAL", "0.01")

    sentinel = object()
    app = create_app(
        specs_dir=tmp_path / "specs",
        state_manager=StateManager(tmp_path / ".mothership"),
        log_manager=None,
        workspace_root=tmp_path,
        worktree_manager=sentinel,
    )
    with TestClient(app):
        pass

    assert captured.get("worktree_manager") is sentinel
```

- [ ] **Step 2 — Run to fail**
`uv run pytest tests/core/test_pr_watcher.py -k stores_worktree_manager tests/core/test_serve_pr_watch.py -k wires_worktree_manager -v`
Expected: `TypeError: got an unexpected keyword argument 'worktree_manager'`; serve test key absent.

- [ ] **Step 3 — Implement**
In `src/mship/core/pr_watcher.py`, `PrWatcher.__init__`: add a parameter after `shell` and store it.
```python
        shell: Any | None = None,
        worktree_manager: Any | None = None,
    ) -> None:
```
```python
        self.shell = shell
        # When injected (in `serve`), a PR merge auto-advances the bound spec +
        # WorkItem and tears the worktree down. Gated on presence — like `config`
        # gates lifecycle hooks — so watchers built without it are unchanged.
        self.worktree_manager = worktree_manager
```

In `src/mship/core/serve.py`, the `PrWatcher(...)` call inside `_lifespan`: add one kwarg (the `worktree_manager` param is already in `create_app`'s scope):
```python
            config=config,
            workspace_root=workspace_root,
            shell=ShellRunner(),
            worktree_manager=worktree_manager,
        )
```

- [ ] **Step 4 — Run to pass** `uv run pytest tests/core/test_pr_watcher.py tests/core/test_serve_pr_watch.py -v`
- [ ] **Step 5 — Commit** (`... "Inject worktree_manager into PrWatcher and wire it in serve"`; journal with message).
<!-- /mship:task -->

---

<!-- mship:task id=5 -->
## Task 5 — Merge auto-close: advance spec + WorkItem, then guarded teardown

**Files:** `src/mship/core/pr_watcher.py`, `tests/core/test_pr_watcher.py`

- [ ] **Step 1 — Write the failing tests**
Append to `tests/core/test_pr_watcher.py` (module already imports `dataclass`, `field`, `datetime`, `Path`, `SimpleNamespace`, `pytest`, `NOW`, `now_fn`, `FakeMessageStore`, `FakeStateManager`, `PrWatcher`):

```python
# ---------------------------------------------------------------------------
# Merge auto-close (spec auto-advance-on-merge)
# ---------------------------------------------------------------------------

class FakeWorktreeManager:
    """Records abort() and mutates the shared task dict so re-sweeps see the
    teardown, mirroring the real WorktreeManager.abort contract."""

    def __init__(self, tasks: dict, *, dirty: dict | None = None, boom: bool = False) -> None:
        self._tasks = tasks
        self._dirty = dirty
        self._boom = boom
        self.abort_calls: list[tuple[str, bool]] = []

    def abort(self, task_slug: str, force: bool = False) -> None:
        self.abort_calls.append((task_slug, force))
        if task_slug not in self._tasks:
            return  # idempotent no-op (mirrors real abort)
        if not force and self._dirty is not None:
            from mship.core.worktree import WorktreeDirtyError
            raise WorktreeDirtyError(task_slug, self._dirty)
        if not force and self._boom:
            raise RuntimeError("teardown kaboom")
        self._tasks.pop(task_slug, None)


def _seed_dispatched_spec_and_workitem(tmp_path):
    """Real SpecStore + WorkItemStore on disk: a dispatched spec linked to a
    feature WorkItem that has one live task. Returns (spec, wi, wstore)."""
    from mship.core.spec_draft import new_spec
    from mship.core.spec_store import SpecStore
    from mship.core.workitem_store import WorkItemStore

    specs_dir = tmp_path / "specs"
    specs_dir.mkdir(parents=True, exist_ok=True)
    sstore = SpecStore(specs_dir)
    spec = new_spec("Auto advance feature", now=NOW, task_slug="task-m")
    spec.status = "dispatched"
    sstore.save(spec)

    wstore = WorkItemStore(tmp_path / ".mothership" / "workitems")
    wi = wstore.create(title="Auto advance feature", kind="feature", workspace="ws", now=NOW)
    wstore.link_spec(wi.id, spec.id, now=NOW)
    wstore.add_task(wi.id, "task-m", now=NOW)
    return spec, wi, wstore


def test_merge_auto_advances_spec_and_workitem_then_tears_down(tmp_path):
    from mship.core.spec_store import SpecStore
    from mship.core.workitem_store import WorkItemStore
    from mship.core.view.workitem_index import compute_phase, compute_attention

    spec, wi, wstore = _seed_dispatched_spec_and_workitem(tmp_path)

    msgs = FakeMessageStore()
    url = "https://github.com/org/repo1/pull/1"
    task = SimpleNamespace(
        slug="task-m", pr_urls={"repo1": url}, work_item_id=wi.id,
        spec_id=spec.id, worktrees={"repo1": str(tmp_path / "wt")},
    )
    tasks = {"task-m": task}
    state = FakeStateManager(tasks)
    fwm = FakeWorktreeManager(tasks)

    watcher = PrWatcher(
        msgs, wstore, state, lambda u: "merged", now_fn,
        worktree_manager=fwm, workspace_root=tmp_path,
    )
    watcher.check_once()

    # ac1: dispatched -> implemented
    assert SpecStore(tmp_path / "specs").find_by_id(spec.id).status == "implemented"
    reread_spec = SpecStore(tmp_path / "specs").find_by_id(spec.id)
    reread_item = WorkItemStore(tmp_path / ".mothership" / "workitems").get(wi.id)
    assert compute_phase(reread_item, reread_spec, []) == "done"
    assert compute_attention(reread_spec, [], []).needs_review is False
    # ac6: clean worktree torn down exactly once
    assert fwm.abort_calls == [("task-m", False)]
    assert "task-m" not in tasks
    assert any(c["kind"] == "event" and "merged" in c["text"] for c in msgs.append_calls)


def test_merge_auto_close_noop_without_worktree_manager(tmp_path):
    spec, wi, wstore = _seed_dispatched_spec_and_workitem(tmp_path)
    from mship.core.spec_store import SpecStore

    msgs = FakeMessageStore()
    url = "https://github.com/org/repo1/pull/1"
    task = SimpleNamespace(
        slug="task-m", pr_urls={"repo1": url}, work_item_id=wi.id,
        spec_id=spec.id, worktrees={"repo1": str(tmp_path / "wt")},
    )
    state = FakeStateManager({"task-m": task})

    PrWatcher(msgs, wstore, state, lambda u: "merged", now_fn,
              workspace_root=tmp_path).check_once()

    assert SpecStore(tmp_path / "specs").find_by_id(spec.id).status == "dispatched"
```

- [ ] **Step 2 — Run to fail**
`uv run pytest tests/core/test_pr_watcher.py -k "auto_advances_spec_and_workitem or auto_close_noop_without" -v`

- [ ] **Step 3 — Implement**
In `src/mship/core/pr_watcher.py`:

1. In `_check_one`, insert the auto-close call right after the hook fires (after `self._fire_lifecycle_hook(st, slug, repo)`):
```python
        self._fire_lifecycle_hook(st, slug, repo)
        self._auto_close_on_merge(slug, task, repo, url, st)
```

2. Add the method (fail-open throughout — never raises; spec ac2):
```python
    def _auto_close_on_merge(
        self, slug: str, task: Any, repo: str, url: str, st: str,
    ) -> None:
        """On a clean full merge, advance the bound spec (dispatched->implemented)
        and its WorkItem (->done / needs_review cleared), then tear the worktree
        down — the zero-manual-`mship close` path (spec ac1/ac6). Non-interactive
        and fail-open (ac2): every failure is logged and swallowed so the sweep
        never crashes. Only active when a worktree_manager is injected."""
        if st != "merged":
            return
        if self.worktree_manager is None or self.workspace_root is None:
            return

        # Advance phase/spec FIRST, so it stands even if teardown is later
        # skipped for a dirty worktree (ac4).
        try:
            from mship.core.spec_store import SPECS_DIRNAME
            from mship.core.spec_lifecycle import advance_spec_on_close
            from mship.core.workitem_lifecycle import advance_workitem_on_close

            states = [self.check_state(u) for u in task.pr_urls.values()]
            merged_count = sum(1 for s in states if s == "merged")
            closed_count = sum(1 for s in states if s == "closed")
            open_count = sum(1 for s in states if s == "open")
            # Only advance/tear down when the WHOLE task is cleanly merged
            # (mirrors `mship close`'s routing). A partially-merged multi-PR
            # task waits for its remaining PRs.
            if open_count or merged_count == 0 or closed_count > 0:
                return

            specs_dir = self.workspace_root / SPECS_DIRNAME
            workitems_dir = self.workspace_root / ".mothership" / "workitems"
            snapshot = self.state_manager.load()  # still contains the closing task
            advance_spec_on_close(
                task=task, specs_dir=specs_dir,
                merged_count=merged_count, closed_count=closed_count,
            )
            advance_workitem_on_close(
                task=task, workitems_dir=workitems_dir, specs_dir=specs_dir,
                state=snapshot, merged_count=merged_count, closed_count=closed_count,
            )
        except Exception:
            log.exception("pr_watcher: merge auto-advance failed (task=%s)", slug)
            return

        # Guarded teardown. A dirty/unpushed worktree raises WorktreeDirtyError
        # (handled in Task 6); any other failure just logs (fail-open, ac2).
        try:
            self.worktree_manager.abort(slug, force=False)
        except Exception:
            log.exception("pr_watcher: merge teardown failed (task=%s)", slug)
```

- [ ] **Step 4 — Run to pass** `uv run pytest tests/core/test_pr_watcher.py -v`
- [ ] **Step 5 — Commit** (`... "Auto-advance spec+WorkItem and tear down worktree on PR merge"`; journal with message).
<!-- /mship:task -->

---

<!-- mship:task id=6 -->
## Task 6 — Skip-note when teardown is refused for a dirty worktree

**Files:** `src/mship/core/pr_watcher.py`, `tests/core/test_pr_watcher.py`

- [ ] **Step 1 — Write the failing test**
Append to `tests/core/test_pr_watcher.py`:
```python
def test_merge_dirty_worktree_advances_then_posts_skip_note(tmp_path):
    """ac4: when teardown is refused (dirty), the worktree is left intact, the
    spec/phase still advances, and a note is posted telling the operator to
    resolve then `mship close` / --force."""
    from mship.core.spec_store import SpecStore

    spec, wi, wstore = _seed_dispatched_spec_and_workitem(tmp_path)

    msgs = FakeMessageStore()
    url = "https://github.com/org/repo1/pull/1"
    task = SimpleNamespace(
        slug="task-m", pr_urls={"repo1": url}, work_item_id=wi.id,
        spec_id=spec.id, worktrees={"repo1": str(tmp_path / "wt")},
    )
    tasks = {"task-m": task}
    state = FakeStateManager(tasks)
    fwm = FakeWorktreeManager(tasks, dirty={"repo1": "uncommitted changes"})

    watcher = PrWatcher(
        msgs, wstore, state, lambda u: "merged", now_fn,
        worktree_manager=fwm, workspace_root=tmp_path,
    )
    watcher.check_once()

    assert SpecStore(tmp_path / "specs").find_by_id(spec.id).status == "implemented"
    assert "task-m" in tasks
    notes = [c for c in msgs.append_calls if c["kind"] == "note"]
    assert len(notes) == 1
    assert "uncommitted changes" in notes[0]["text"]
    assert "mship close" in notes[0]["text"]

    watcher.check_once()  # idempotent: does not double-post
    notes = [c for c in msgs.append_calls if c["kind"] == "note"]
    assert len(notes) == 1
```

- [ ] **Step 2 — Run to fail** `uv run pytest tests/core/test_pr_watcher.py -k dirty_worktree_advances_then_posts -v` (current except swallows the error, no note).

- [ ] **Step 3 — Implement**
In `src/mship/core/pr_watcher.py`, replace the teardown `try/except` at the end of `_auto_close_on_merge`:
```python
        try:
            self.worktree_manager.abort(slug, force=False)
        except Exception:
            log.exception("pr_watcher: merge teardown failed (task=%s)", slug)
```
with:
```python
        try:
            self.worktree_manager.abort(slug, force=False)
        except Exception as exc:
            from mship.core.worktree import WorktreeDirtyError
            if isinstance(exc, WorktreeDirtyError):
                try:
                    self._post_teardown_skipped_note(slug, task, url, exc)
                except Exception:
                    log.exception("pr_watcher: teardown-skip note failed (task=%s)", slug)
            else:
                log.exception("pr_watcher: merge teardown failed (task=%s)", slug)
```
Add the helper method:
```python
    def _post_teardown_skipped_note(
        self, slug: str, task: Any, url: str, exc: Any,
    ) -> None:
        """Post a one-time NOTE (kind='note', not 'event' — informational, no
        nag) when a merged task's worktree was left intact because it had
        uncommitted/unpushed changes. Deduped across sweeps by a sentinel."""
        now = self.now_fn()
        tid, _wi = self._resolve_thread(slug, task, url, now)
        thread = self.msgs.get(tid)
        sentinel = f"Worktree for {slug} left intact"
        if thread is not None and any(sentinel in m.text for m in thread.messages):
            return
        details = "; ".join(f"{repo}: {reason}" for repo, reason in exc.dirty.items())
        text = (
            f"⚠️ {sentinel}: {details}. "
            f"Resolve (commit/push), then `mship close` "
            f"(or `mship close --force` to discard)."
        )
        self.msgs.append(tid, "agent", text, now, kind="note")
```
NOTE (controller): verify `_resolve_thread`'s real signature in pr_watcher (the event path already resolves a thread for `_post_event`); reuse that exact helper/args rather than assuming.

- [ ] **Step 4 — Run to pass** `uv run pytest tests/core/test_pr_watcher.py -v`
- [ ] **Step 5 — Commit** (`... "Post skip-note when merge teardown is refused for a dirty worktree"`; journal with message).
<!-- /mship:task -->

---

<!-- mship:task id=7 -->
## Task 7 — Idempotency + fail-open hardening (regression locks)

**Files:** `tests/core/test_pr_watcher.py`

- [ ] **Step 1 — Write the tests** (append):
```python
def test_merge_auto_close_is_idempotent_across_sweeps(tmp_path):
    from mship.core.spec_store import SpecStore
    spec, wi, wstore = _seed_dispatched_spec_and_workitem(tmp_path)
    msgs = FakeMessageStore()
    url = "https://github.com/org/repo1/pull/1"
    task = SimpleNamespace(
        slug="task-m", pr_urls={"repo1": url}, work_item_id=wi.id,
        spec_id=spec.id, worktrees={"repo1": str(tmp_path / "wt")},
    )
    tasks = {"task-m": task}
    state = FakeStateManager(tasks)
    fwm = FakeWorktreeManager(tasks)
    watcher = PrWatcher(msgs, wstore, state, lambda u: "merged", now_fn,
                        worktree_manager=fwm, workspace_root=tmp_path)
    watcher.check_once(); watcher.check_once(); watcher.check_once()
    assert fwm.abort_calls == [("task-m", False)]
    assert SpecStore(tmp_path / "specs").find_by_id(spec.id).status == "implemented"


def test_merge_partial_multipr_does_not_advance_or_tear_down(tmp_path):
    from mship.core.spec_store import SpecStore
    spec, wi, wstore = _seed_dispatched_spec_and_workitem(tmp_path)
    msgs = FakeMessageStore()
    url_a = "https://github.com/org/repoA/pull/1"
    url_b = "https://github.com/org/repoB/pull/2"
    task = SimpleNamespace(
        slug="task-m", pr_urls={"repoA": url_a, "repoB": url_b},
        work_item_id=wi.id, spec_id=spec.id,
        worktrees={"repoA": str(tmp_path / "wtA"), "repoB": str(tmp_path / "wtB")},
    )
    tasks = {"task-m": task}
    state = FakeStateManager(tasks)
    fwm = FakeWorktreeManager(tasks)

    def check_state(u):
        return "merged" if u == url_a else "open"

    PrWatcher(msgs, wstore, state, check_state, now_fn,
              worktree_manager=fwm, workspace_root=tmp_path).check_once()
    assert fwm.abort_calls == []
    assert SpecStore(tmp_path / "specs").find_by_id(spec.id).status == "dispatched"


def test_merge_teardown_failure_is_fail_open_event_still_posts(tmp_path):
    spec, wi, wstore = _seed_dispatched_spec_and_workitem(tmp_path)
    msgs = FakeMessageStore()
    url = "https://github.com/org/repo1/pull/1"
    task = SimpleNamespace(
        slug="task-m", pr_urls={"repo1": url}, work_item_id=wi.id,
        spec_id=spec.id, worktrees={"repo1": str(tmp_path / "wt")},
    )
    tasks = {"task-m": task}
    state = FakeStateManager(tasks)
    fwm = FakeWorktreeManager(tasks, boom=True)
    watcher = PrWatcher(msgs, wstore, state, lambda u: "merged", now_fn,
                        worktree_manager=fwm, workspace_root=tmp_path)
    watcher.check_once()  # must not raise
    assert any(c["kind"] == "event" and "merged" in c["text"] for c in msgs.append_calls)
```

- [ ] **Step 2 — Run** `uv run pytest tests/core/test_pr_watcher.py -k "idempotent_across_sweeps or partial_multipr or teardown_failure_is_fail_open" -v` — these are regression locks; should pass against Task 5/6. If red, fix the corresponding branch (open_count early-return / teardown try-except), not the tests.
- [ ] **Step 3 — no production change expected.**
- [ ] **Step 4 — Run to pass** `uv run pytest tests/core/test_pr_watcher.py -v`
- [ ] **Step 5 — Commit** (`... "Lock merge auto-close idempotency and fail-open invariants"`; journal with message).
<!-- /mship:task -->

---

<!-- mship:task id=8 -->
## Task 8 — Update skills: merge auto-advances; close only to force-teardown a dirty worktree

**Files:** `src/mship/skills/finishing-a-development-branch/SKILL.md`, `src/mship/skills/working-with-mothership/SKILL.md`

- [ ] **Step 1 — Establish the failing check** (expect no matches yet):
`grep -rn "auto-advance\|automatically advances\|left intact" src/mship/skills/finishing-a-development-branch/SKILL.md src/mship/skills/working-with-mothership/SKILL.md`

- [ ] **Step 2 — Edit `finishing-a-development-branch/SKILL.md`** — update the Step 5 close note to state: a merged PR in a serve workspace auto-advances the bound spec (dispatched -> implemented) + WorkItem (-> done) and tears the worktree down automatically; `mship close` is only needed when the worktree has uncommitted/unpushed changes (teardown refused to protect work, note posted) — resolve then close, or `mship close --force` to discard; `--force` is the only way to delete a dirty/unpushed worktree.

- [ ] **Step 3 — Edit `working-with-mothership/SKILL.md`** — update the `mship close` command reference to note `--force` is also required to tear down a dirty/unpushed worktree, and add a short "Merge auto-advance (mship serve)" note: with serve running, a merged PR advances spec dispatched->implemented + WorkItem->done (clearing needs_review), then tears the worktree down — no manual `mship close` in the common case; every teardown path (merge auto-close, `mship close`, `--abandon`) refuses to delete a dirty/unpushed worktree unless `--force`.

- [ ] **Step 4 — Verify green** `grep -rn "auto-advance\|auto-advances\|dirty/unpushed\|left intact\|--force" src/mship/skills/finishing-a-development-branch/SKILL.md src/mship/skills/working-with-mothership/SKILL.md`
- [ ] **Step 5 — Commit** (`... "Docs: merge auto-advances; close only to force-teardown a dirty worktree"`; journal with message).
<!-- /mship:task -->

---

## Final full-suite gate (after Task 8)
`uv run pytest tests/ -q` — Expected green. RISK to watch: integration/CLI close tests that drive a REAL `WorktreeManager.abort` on a worktree with an `origin` remote (e.g. `tests/test_integration.py`, `tests/test_finish_integration.py`, `tests/test_monorepo_integration.py`). After `mship finish` these branches are `push -u`'d (upstream set, 0 ahead) with clean trees, so the guard is a no-op — but if any leaves untracked non-ignored files or a committed-but-unpushed branch in the worktree at close time, the guard will (correctly) refuse. Fix by asserting `--force`/cleaning, not by weakening the guard.

## Self-Review

### AC -> Task map
- ac1 -> Task 5. ac2 -> Task 5 + Task 7. ac3 -> Task 2 + Task 1 + Task 3. ac4 -> Task 2 + Task 6. ac5 -> Task 2 + Task 3. ac6 -> Task 2 + Task 5. ac7 -> Task 2 + Task 7. ac8 -> Task 8. No gaps.

### Placeholder scan
No TODO/pseudocode. Every code block complete. Two controller NOTEs added (journal-with-message; verify `_resolve_thread` real signature).

### Type/signature consistency (verified against worktree source)
- `advance_spec_on_close(*, task, specs_dir, merged_count, closed_count)` + `advance_workitem_on_close(*, task, workitems_dir, specs_dir, state, merged_count, closed_count)` keyword-only, called as defined.
- `SPECS_DIRNAME == "specs"`; specs at `<root>/specs`, workitems at `<root>/.mothership/workitems`.
- `GitRunner.has_uncommitted_changes` + `has_remote` reused; `has_unpushed_commits` added.
- `WorktreeManager.abort` gains `force: bool = False` (default preserves existing caller + tests). `WorktreeDirtyError.dirty: dict[str,str]`.
- `PrWatcher.__init__` gains trailing `worktree_manager: Any | None = None`; auto-close gated on `worktree_manager is not None and workspace_root is not None`, so 30+ existing pr_watcher tests are behavior-preserving.
