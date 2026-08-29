# `mship-config-workflow-doctor` Implementation Plan

**Spec id:** `mship-config-workflow-doctor` (approved + dispatched, mothership-only)

**REQUIRED SUB-SKILL:** Every task below MUST be implemented with `test-driven-development` — write the failing pytest first, run it and watch it FAIL for the stated reason, implement the minimum code, run it and watch it PASS, then commit. Do not write implementation before its test. Use `subagent-driven-development` / `executing-plans` to drive the sequence.

## Goal

Close the three post-onboarding workspace-config ergonomics gaps from GitHub issue #366 findings #5/#6/#7, without breaking the "work happens in worktrees" invariant or deterministic JSON output:

- **#5 (ac1–ac3):** Let a config-only main-checkout edit (`mothership.yaml` and/or a Taskfile) pass the `mship finish` `dirty_worktree` audit gate without `--force-audit`, fail-closed; load config with `require_paths=False` on the doctor/config-change path; document the bootstrap workflow.
- **#6 (ac4–ac6):** Report the resolved `mothership.yaml` absolute path + resolution source (`env`/`marker`/`walk-up`) in `mship status` and `mship doctor`; assert the marker walk-up already resolves a hub-repo worktree to the workspace-root config.
- **#7 (ac7–ac9):** Write a `.mship-workspace` marker into every repo worktree (including the hub repo's own `path: .` worktree) with a `.gitignore` guard; add a best-effort `doctor` bundling-exclusion heuristic; document the `.worktrees`/`.mothership` bundler caveat.
- **ac10:** All new `status`/`doctor` JSON is additive.

## Architecture / approach

- **Discovery observability (ac4/5/6):** add `ConfigLoader.discover_with_source(start) -> ConfigResolution(path, source)` in `core/config.py`; keep the existing `discover(start) -> Path` as a thin delegate so the three current callers (`core/gate.py:53`, `core/gate.py:72`, `cli/__init__.py:95`) and all existing discover tests are UNCHANGED (additive, no return-type break). `status`/`doctor` compute the source via the new method and match it against `container.config_path()`.
- **Config-only gate exemption (ac1/2):** follow the established `without_no_upstream_on_task_branch` report-filter idiom. Record the modified tracked paths on the `dirty_worktree` `Issue` during `_probe_dirty`, add a fail-closed `is_config_only_paths` predicate + a `without_config_only_dirty(report)` filter in `core/repo_state.py`, and apply it in `finish` immediately after the existing no_upstream filter. `run_audit_gate` is untouched.
- **require_paths=False (ac3):** `cli/doctor.py` loads via `ConfigLoader.load(container.config_path(), require_paths=False)` instead of `container.config()`, so a missing/in-flux `Taskfile.yml` surfaces as a doctor `fail` check rather than crashing config load. The container singleton stays `require_paths=True`, so spawn/finish/exec are unaffected.
- **Per-worktree marker (ac7):** in `core/worktree.py` normal-repo branch (the single code path that also creates the hub `path: .` repo worktree), write the marker into each worktree and guard-add `.mship-workspace` to that worktree's `.gitignore`, mirroring the existing `.worktrees` gitignore handling.
- **Bundler heuristic (ac8):** add a shallow, `warn`-only `_check_bundler_exclusions` to `DoctorChecker` that inspects known bundler configs at the workspace root and flags missing `.worktrees`/`.mothership` exclusions, always labelling itself best-effort.
- **ac6 is largely pre-fixed:** the drafter flagged #6 as mostly already handled by the marker walk-up (`config.py:513-517` runs before the plain walk-up at `:519-530`). Task 8 ASSERTS this rather than re-implementing it.

## Tech Stack / conventions

- Python (Pydantic / Typer), `pytest` via **`uv run pytest`** run **FROM the worktree**: `/home/bailey/development/repos/mship-workspace/.worktrees/mship-config-workflow-doctor/mothership` (referred to below as `$WT`).
- Per-task test command form: `uv run pytest tests/<path>::<test> -v` (cwd = `$WT`).
- Commit per task: `git -C $WT add <files>` → `git -C $WT commit -m "<msg>"` → `mship journal "<msg>" --task mship-config-workflow-doctor --action committed`.
- Deterministic JSON is a hard constraint (ac10): additive fields only; never rename/remove an existing key.

## File Structure

| File (relative to `$WT`) | Role in this plan |
| --- | --- |
| `src/mship/core/config.py` | Add `ConfigResolution` + `discover_with_source`; make `discover` delegate (Task 1) |
| `src/mship/core/repo_state.py` | `Issue.paths` field; `_probe_dirty` path capture; `_enrich_active_task` path passthrough; `is_config_only_paths` + `without_config_only_dirty` (Tasks 2–3) |
| `src/mship/cli/worktree.py` | Apply `without_config_only_dirty` in `finish` (Task 4); no change to spawn |
| `src/mship/cli/doctor.py` | Load with `require_paths=False`; compute + emit config path/source JSON (Tasks 5, 7) |
| `src/mship/cli/status.py` | Emit `config_path` + `config_resolution_source` (Task 6) |
| `src/mship/core/doctor.py` | `DoctorChecker` config-resolution CheckResult; bundler-exclusion heuristic (Tasks 7, 10) |
| `src/mship/core/worktree.py` | Per-worktree `.mship-workspace` marker + `.gitignore` guard (Task 9) |
| `README.md` | Config-change workflow + bundler callout (Task 11) |
| `src/mship/skills/working-with-mothership/SKILL.md` | Same doc callouts (Task 11) |
| `tests/core/test_config.py` | discover_with_source + ac6 assertion (Tasks 1, 8) |
| `tests/core/test_repo_state.py` | paths capture, predicate, filter (Tasks 2, 3) |
| `tests/test_finish_config_only_gate.py` (new) | finish integration (Task 4) |
| `tests/cli/test_doctor.py`, `tests/cli/test_status.py` | require_paths, source fields, additive regression (Tasks 5, 6, 7, 12) |
| `tests/core/test_doctor.py` | config CheckResult + bundler heuristic (Tasks 7, 10) |
| `tests/core/test_worktree.py` | per-worktree marker (Task 9) |
| `tests/test_docs_config_workflow.py` (new) | docs callout presence (Task 11) |

---

<!-- mship:task id=1 -->
## Task 1 — `ConfigLoader.discover_with_source` returns (path, source); `discover` delegates

Enables ac4/ac5/ac6. Additive: `discover` keeps its `-> Path` contract; the three existing callers (`core/gate.py:53`, `core/gate.py:72`, `cli/__init__.py:95`) and all existing discover tests remain valid.

**Files:** `src/mship/core/config.py`, `tests/core/test_config.py`

### Step 1 — write the failing test

Append to `tests/core/test_config.py`:

```python
def test_discover_with_source_env(tmp_path, monkeypatch):
    from mship.core.config import ConfigLoader
    root = tmp_path / "ws"; root.mkdir()
    (root / "mothership.yaml").write_text("workspace: t\nrepos: {}\n")
    other = tmp_path / "other"; other.mkdir()
    monkeypatch.setenv("MSHIP_WORKSPACE", str(root))
    res = ConfigLoader.discover_with_source(other)
    assert res.path == root / "mothership.yaml"
    assert res.source == "env"


def test_discover_with_source_marker(tmp_path, monkeypatch):
    from mship.core.config import ConfigLoader
    from mship.core.workspace_marker import write_marker
    monkeypatch.delenv("MSHIP_WORKSPACE", raising=False)
    root = tmp_path / "ws"; root.mkdir()
    (root / "mothership.yaml").write_text("workspace: t\nrepos: {}\n")
    wt = tmp_path / "wt"; wt.mkdir()
    write_marker(wt, root)
    res = ConfigLoader.discover_with_source(wt)
    assert res.path == root / "mothership.yaml"
    assert res.source == "marker"


def test_discover_with_source_walk_up(tmp_path, monkeypatch):
    from mship.core.config import ConfigLoader
    monkeypatch.delenv("MSHIP_WORKSPACE", raising=False)
    root = tmp_path / "ws"; root.mkdir()
    (root / "mothership.yaml").write_text("workspace: t\nrepos: {}\n")
    nested = root / "a" / "b"; nested.mkdir(parents=True)
    res = ConfigLoader.discover_with_source(nested)
    assert res.path == root / "mothership.yaml"
    assert res.source == "walk-up"


def test_discover_delegates_to_discover_with_source(tmp_path, monkeypatch):
    from mship.core.config import ConfigLoader
    monkeypatch.delenv("MSHIP_WORKSPACE", raising=False)
    root = tmp_path / "ws"; root.mkdir()
    (root / "mothership.yaml").write_text("workspace: t\nrepos: {}\n")
    nested = root / "a"; nested.mkdir()
    assert ConfigLoader.discover(nested) == root / "mothership.yaml"
```

### Step 2 — run to fail

```
uv run pytest tests/core/test_config.py::test_discover_with_source_env tests/core/test_config.py::test_discover_with_source_marker tests/core/test_config.py::test_discover_with_source_walk_up -v
```
Expect: `AttributeError: type object 'ConfigLoader' has no attribute 'discover_with_source'`.

### Step 3 — implement

In `src/mship/core/config.py`, add a dataclass import at top (near `import yaml`): `from dataclasses import dataclass`. Add above `class ConfigLoader`:

```python
@dataclass(frozen=True)
class ConfigResolution:
    """Result of ConfigLoader.discover_with_source.

    `path` is the resolved mothership.yaml. `source` is which discovery branch
    produced it: "env" (MSHIP_WORKSPACE), "marker" (.mship-workspace walk-up),
    or "walk-up" (plain mothership.yaml walk-up).
    """
    path: Path
    source: str
```

Replace the existing `discover` staticmethod (`config.py:494-530`) with:

```python
    @staticmethod
    def discover_with_source(start: Path) -> "ConfigResolution":
        import os
        from mship.core.workspace_marker import read_marker_from_ancestor

        # 1. MSHIP_WORKSPACE env var — set-and-valid wins; set-but-invalid
        #    raises so misconfiguration fails loud instead of silently
        #    falling through to the walk-up.
        env = os.environ.get("MSHIP_WORKSPACE")
        if env:
            env_root = Path(env).resolve()
            env_yaml = env_root / "mothership.yaml"
            if env_yaml.is_file():
                return ConfigResolution(path=env_yaml, source="env")
            raise FileNotFoundError(
                f"MSHIP_WORKSPACE={env!r} does not contain a mothership.yaml "
                f"(expected {env_yaml})"
            )

        # 2. Marker walk-up — worktrees get a `.mship-workspace` pointer from
        #    spawn. Stale markers return None silently.
        marker_root = read_marker_from_ancestor(start)
        if marker_root is not None:
            return ConfigResolution(
                path=marker_root / "mothership.yaml", source="marker"
            )

        # 3. Existing walk-up for mothership.yaml.
        current = Path(start).resolve()
        while True:
            candidate = current / "mothership.yaml"
            if candidate.exists():
                return ConfigResolution(path=candidate, source="walk-up")
            parent = current.parent
            if parent == current:
                raise FileNotFoundError(
                    "No mothership.yaml found in any parent directory"
                )
            current = parent

    @staticmethod
    def discover(start: Path) -> Path:
        return ConfigLoader.discover_with_source(start).path
```

### Step 4 — run to pass

```
uv run pytest tests/core/test_config.py -v
```
All discover tests (existing + new) pass.

### Step 5 — commit

```
git -C $WT add src/mship/core/config.py tests/core/test_config.py
git -C $WT commit -m "config: add discover_with_source returning (path, source); discover delegates"
mship journal "config: discover_with_source (path, source); discover delegates" --task mship-config-workflow-doctor --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=2 -->
## Task 2 — Record modified tracked paths on the `dirty_worktree` Issue (fail-closed foundation for ac1/ac2)

`_probe_dirty` (`repo_state.py:241-278`) must record the modified paths so the config-only filter can consult them, and `_enrich_active_task` (`repo_state.py:285-310`) must PRESERVE them when it rebuilds the issue (it currently drops extra fields). The new field is `compare=False` so it does NOT change `Issue` equality/hash (existing tests unaffected) and is NOT serialized by `to_json` (ac10 additive-safe).

**Files:** `src/mship/core/repo_state.py`, `tests/core/test_repo_state.py`

### Step 1 — write the failing test

Append to `tests/core/test_repo_state.py`:

```python
def test_probe_dirty_records_modified_paths(audit_workspace):
    cfg, shell = _load(audit_workspace)
    (audit_workspace / "cli" / "Taskfile.yml").write_text(
        "version: '3'\ntasks:\n  x:\n    cmds:\n      - echo x\n"
    )
    rep = audit_repos(cfg, shell, names=["cli"])
    (repo,) = [r for r in rep.repos if r.name == "cli"]
    dirty = [i for i in repo.issues if i.code == "dirty_worktree"]
    assert dirty, [i.code for i in repo.issues]
    assert "Taskfile.yml" in dirty[0].paths


def test_probe_dirty_records_multiple_paths(audit_workspace):
    cfg, shell = _load(audit_workspace)
    (audit_workspace / "cli" / "README.md").write_text("changed\n")
    (audit_workspace / "cli" / "Taskfile.yml").write_text("version: '3'\ntasks: {x: {cmds: [echo]}}\n")
    rep = audit_repos(cfg, shell, names=["cli"])
    (repo,) = [r for r in rep.repos if r.name == "cli"]
    (dirty,) = [i for i in repo.issues if i.code == "dirty_worktree"]
    assert set(dirty.paths) == {"README.md", "Taskfile.yml"}


def test_enrich_active_task_preserves_paths():
    from mship.core.repo_state import Issue, _enrich_active_task
    issues = (Issue("dirty_worktree", "error", "1 modified tracked file",
                    paths=("mothership.yaml",)),)
    out = _enrich_active_task(issues, has_active_task=True)
    assert out[0].paths == ("mothership.yaml",)
    assert "worktree" in out[0].message  # hint still appended


def test_issue_equality_ignores_paths():
    from mship.core.repo_state import Issue
    a = Issue("dirty_worktree", "error", "x")
    b = Issue("dirty_worktree", "error", "x", paths=("a", "b"))
    assert a == b  # paths is compare=False → existing equality preserved
```

### Step 2 — run to fail

```
uv run pytest tests/core/test_repo_state.py::test_probe_dirty_records_modified_paths tests/core/test_repo_state.py::test_enrich_active_task_preserves_paths -v
```
Expect: `TypeError: Issue.__init__() got an unexpected keyword argument 'paths'`.

### Step 3 — implement

In `src/mship/core/repo_state.py`, change the dataclasses import (`repo_state.py:5`) to `from dataclasses import dataclass, field`. Add the field to `Issue` (`repo_state.py:12-16`):

```python
@dataclass(frozen=True)
class Issue:
    code: str
    severity: Severity
    message: str
    paths: tuple[str, ...] = field(default=(), compare=False)
```

In `_probe_dirty` (`repo_state.py:255-272`), capture the paths:

```python
    untracked = 0
    modified = 0
    modified_paths: list[str] = []
    for line in out.splitlines():
        if not line.strip():
            continue
        # Porcelain v1: first 2 chars are the status code. "??" is untracked;
        # anything else (M, A, D, R, C, U, plus staged/unstaged combos) is
        # tracked-modified content.
        if line.startswith("??"):
            untracked += 1
        else:
            modified += 1
            path_part = line[3:].strip()
            if " -> " in path_part:  # rename/copy: record the destination
                path_part = path_part.split(" -> ", 1)[1]
            path_part = path_part.strip().strip('"')
            if path_part:
                modified_paths.append(path_part)
    issues: list[Issue] = []
    if modified:
        issues.append(Issue(
            "dirty_worktree", "error",
            f"{modified} modified tracked file" + ("s" if modified != 1 else ""),
            paths=tuple(modified_paths),
        ))
```

In `_enrich_active_task` (`repo_state.py:300-307`), pass paths through when rebuilding the dirty issue:

```python
        if i.code == "dirty_worktree":
            out.append(Issue(
                i.code, i.severity,
                i.message + " — a task is active for this repo; "
                "edit in its worktree, not the main checkout "
                "(see `mship worktrees`)",
                paths=i.paths,
            ))
```

### Step 4 — run to pass

```
uv run pytest tests/core/test_repo_state.py -v
```
New tests pass; existing `Issue`/`to_json`/dirty tests still pass (paths excluded from equality + JSON).

### Step 5 — commit

```
git -C $WT add src/mship/core/repo_state.py tests/core/test_repo_state.py
git -C $WT commit -m "repo_state: record modified tracked paths on dirty_worktree Issue (compare=False)"
mship journal "repo_state: dirty_worktree Issue carries modified paths" --task mship-config-workflow-doctor --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=3 -->
## Task 3 — `is_config_only_paths` predicate + `without_config_only_dirty` filter (ac1/ac2 core logic)

Pure/loadable logic, fail-closed. The predicate uses exact BASENAME equality — this prevents substring escape (`my_Taskfile.yml`, `Taskfile.yml.bak` never match) while allowing a legitimately-named `Taskfile.yml` in a subdir (monorepo git_root child). Empty paths → False (can't confirm config-only). The filter mirrors `without_no_upstream_on_task_branch` and only strips `dirty_worktree`; every other issue code is retained.

**Files:** `src/mship/core/repo_state.py`, `tests/core/test_repo_state.py`

### Step 1 — write the failing test

Append to `tests/core/test_repo_state.py`:

```python
def test_is_config_only_paths_true_cases():
    from mship.core.repo_state import is_config_only_paths
    assert is_config_only_paths(["mothership.yaml"]) is True
    assert is_config_only_paths(["Taskfile.yaml"]) is True
    assert is_config_only_paths(["taskfile.yml", "mothership.yaml"]) is True
    assert is_config_only_paths(["services/api/Taskfile.yml"]) is True  # basename match


def test_is_config_only_paths_fail_closed_cases():
    from mship.core.repo_state import is_config_only_paths
    assert is_config_only_paths(["mothership.yaml", "src/app.py"]) is False  # mixed
    assert is_config_only_paths(["src/TaskfileHelper.py"]) is False          # substring look-alike
    assert is_config_only_paths(["Taskfile.yml.bak"]) is False               # look-alike suffix
    assert is_config_only_paths([]) is False                                  # empty → fail closed


def test_without_config_only_dirty_strips_config_only():
    from mship.core.repo_state import (
        AuditReport, Issue, RepoAudit, without_config_only_dirty,
    )
    r = RepoAudit(name="hub", path=Path("/w"), current_branch="main",
                  issues=(Issue("dirty_worktree", "error", "1 file",
                                paths=("mothership.yaml",)),))
    out = without_config_only_dirty(AuditReport(repos=(r,)))
    assert out.has_errors is False


def test_without_config_only_dirty_retains_mixed_drift():
    from mship.core.repo_state import (
        AuditReport, Issue, RepoAudit, without_config_only_dirty,
    )
    r = RepoAudit(name="hub", path=Path("/w"), current_branch="main",
                  issues=(Issue("dirty_worktree", "error", "2 files",
                                paths=("mothership.yaml", "src/app.py")),))
    out = without_config_only_dirty(AuditReport(repos=(r,)))
    assert out.has_errors is True  # fail closed


def test_without_config_only_dirty_retains_other_error_codes():
    from mship.core.repo_state import (
        AuditReport, Issue, RepoAudit, without_config_only_dirty,
    )
    r = RepoAudit(name="hub", path=Path("/w"), current_branch="main",
                  issues=(
                      Issue("dirty_worktree", "error", "1 file", paths=("mothership.yaml",)),
                      Issue("diverged", "error", "diverged"),
                  ))
    out = without_config_only_dirty(AuditReport(repos=(r,)))
    codes = {i.code for i in out.repos[0].issues}
    assert codes == {"diverged"}  # dirty stripped, diverged retained
```

### Step 2 — run to fail

```
uv run pytest tests/core/test_repo_state.py::test_is_config_only_paths_true_cases tests/core/test_repo_state.py::test_without_config_only_dirty_strips_config_only -v
```
Expect: `ImportError: cannot import name 'is_config_only_paths'`.

### Step 3 — implement

In `src/mship/core/repo_state.py`, add after the `without_no_upstream_on_task_branch` function (around `repo_state.py:90`):

```python
_CONFIG_ONLY_BASENAMES = frozenset({
    "mothership.yaml",
    "Taskfile.yml", "Taskfile.yaml",
    "taskfile.yml", "taskfile.yaml",
})


def is_config_only_paths(paths: Iterable[str]) -> bool:
    """True iff `paths` is non-empty and EVERY path's basename is a workspace
    config file (`mothership.yaml`) or a Taskfile.

    Fails closed: an empty input, or any path whose basename is outside the
    allowlist, returns False. Matching is exact basename equality (not
    substring), so look-alikes like `my_Taskfile.yml` or `Taskfile.yml.bak`
    never qualify, while a legitimately-named `Taskfile.yml` in a subdir
    (monorepo git_root child) does. See issue 366 #5.
    """
    names = [Path(p).name for p in paths]
    if not names:
        return False
    return all(n in _CONFIG_ONLY_BASENAMES for n in names)


def without_config_only_dirty(report: AuditReport) -> AuditReport:
    """Return a copy of `report` with `dirty_worktree` ERRORS stripped from
    repos whose modified-tracked drift is confined to workspace config /
    Taskfiles.

    Used by `mship finish` (issue 366 #5): editing `mothership.yaml` / a
    Taskfile in the main checkout is the supported config-change path and must
    not block finish on `dirty_worktree`. Fails closed via
    `is_config_only_paths` — the moment any non-config tracked file is
    modified, the issue is retained and the gate blocks again. Other issue
    codes are untouched; standalone `mship audit` still reports the drift.
    """
    new_repos: list[RepoAudit] = []
    for r in report.repos:
        kept = tuple(
            i for i in r.issues
            if not (i.code == "dirty_worktree" and is_config_only_paths(i.paths))
        )
        if len(kept) != len(r.issues):
            new_repos.append(RepoAudit(
                name=r.name, path=r.path,
                current_branch=r.current_branch, issues=kept,
            ))
        else:
            new_repos.append(r)
    return AuditReport(repos=tuple(new_repos))
```

(`Path` and `Iterable` are already imported at `repo_state.py:6-7`.)

### Step 4 — run to pass

```
uv run pytest tests/core/test_repo_state.py -v
```

### Step 5 — commit

```
git -C $WT add src/mship/core/repo_state.py tests/core/test_repo_state.py
git -C $WT commit -m "repo_state: is_config_only_paths predicate + without_config_only_dirty filter (fail-closed)"
mship journal "repo_state: config-only dirty predicate + filter" --task mship-config-workflow-doctor --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=4 -->
## Task 4 — Wire `without_config_only_dirty` into `mship finish` (ac1/ac2 end-to-end)

Apply the filter in `finish` immediately after the existing `without_no_upstream_on_task_branch` block (`cli/worktree.py:1148-1150`), BEFORE scope computation and the gate. Spawn is intentionally NOT changed — ac1/ac2 target `finish` only.

**Files:** `src/mship/cli/worktree.py`, `tests/test_finish_config_only_gate.py` (new)

### Step 1 — write the failing test

Create `tests/test_finish_config_only_gate.py`:

```python
"""issue 366 #5: a config-only main-checkout edit (mothership.yaml / Taskfile)
does not block `mship finish` on dirty_worktree; any non-config drift re-blocks."""
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import MagicMock

import pytest
from typer.testing import CliRunner

from mship.cli import app, container
from mship.core.state import StateManager
from mship.core.workitem_store import WorkItemStore
from mship.util.shell import ShellResult, ShellRunner

runner = CliRunner()


def _make_shell(porcelain: str) -> MagicMock:
    def _run(cmd, cwd, env=None):
        if "status --porcelain" in cmd:
            return ShellResult(returncode=0, stdout=porcelain, stderr="")
        if "gh auth status" in cmd:
            return ShellResult(returncode=0, stdout="Logged in", stderr="")
        if "ls-remote" in cmd:
            return ShellResult(returncode=0, stdout="abc\trefs/heads/main\n", stderr="")
        if "rev-list --count" in cmd and "origin/" in cmd:
            return ShellResult(returncode=0, stdout="1\n", stderr="")
        if "rev-list --count" in cmd:
            return ShellResult(returncode=0, stdout="0\n", stderr="")
        if "git push" in cmd:
            return ShellResult(returncode=0, stdout="", stderr="")
        if "gh pr create" in cmd:
            return ShellResult(returncode=0, stdout="https://github.com/org/shared/pull/1\n", stderr="")
        return ShellResult(returncode=0, stdout="", stderr="")

    shell = MagicMock(spec=ShellRunner)
    shell.run_task.return_value = ShellResult(returncode=0, stdout="ok\n", stderr="")
    shell.run.side_effect = _run
    return shell


@pytest.fixture
def cfg_only_workspace(workspace_with_git: Path):
    state_dir = workspace_with_git / ".mothership"
    state_dir.mkdir(exist_ok=True)
    container.config_path.override(workspace_with_git / "mothership.yaml")
    container.state_dir.override(state_dir)
    yield workspace_with_git
    container.config_path.reset_override()
    container.state_dir.reset_override()
    container.config.reset()
    container.state_manager.reset()
    container.shell.reset_override()


def _spawn_bug(workspace: Path, slug_desc: str) -> None:
    items = WorkItemStore(workspace / ".mothership" / "workitems")
    wi = items.create(title="cfg", kind="bug", workspace="ws", now=datetime.now(timezone.utc))
    result = runner.invoke(app, ["spawn", "--work-item", wi.id, slug_desc, "--repos", "shared"])
    assert result.exit_code == 0, result.output


def test_finish_not_blocked_by_config_only_dirty(cfg_only_workspace):
    workspace = cfg_only_workspace
    container.shell.override(_make_shell(" M mothership.yaml\n"))
    _spawn_bug(workspace, "cfg only edit")
    result = runner.invoke(app, ["finish", "--task", "cfg-only-edit"])
    assert result.exit_code == 0, result.output
    state = StateManager(workspace / ".mothership").load()
    assert state.tasks["cfg-only-edit"].pr_urls.get("shared") == "https://github.com/org/shared/pull/1"


def test_finish_reblocks_when_source_file_also_dirty(cfg_only_workspace):
    workspace = cfg_only_workspace
    container.shell.override(_make_shell(" M mothership.yaml\n M src/app.py\n"))
    _spawn_bug(workspace, "cfg plus source")
    result = runner.invoke(app, ["finish", "--task", "cfg-plus-source"])
    assert result.exit_code == 1, result.output
    assert "dirty_worktree" in result.output
    state = StateManager(workspace / ".mothership").load()
    assert state.tasks["cfg-plus-source"].pr_urls == {}
```

### Step 2 — run to fail

```
uv run pytest tests/test_finish_config_only_gate.py::test_finish_not_blocked_by_config_only_dirty -v
```
Expect: exit 1 (blocked by `dirty_worktree`) instead of 0 — the filter isn't wired in yet.

### Step 3 — implement

In `src/mship/cli/worktree.py`, inside `finish`, immediately after the no_upstream filter block (`cli/worktree.py:1148-1150`) add:

```python
        if task.finished_at is None:
            from mship.core.repo_state import without_no_upstream_on_task_branch
            report = without_no_upstream_on_task_branch(report, task.branch)

        # issue 366 #5: a config-only main-checkout edit (mothership.yaml /
        # Taskfile) is the supported config-change path — don't block finish's
        # dirty_worktree on it. Fails closed: any non-config tracked drift is
        # retained by the filter and re-blocks the gate. spawn/exec unchanged.
        from mship.core.repo_state import without_config_only_dirty
        report = without_config_only_dirty(report)
```

### Step 4 — run to pass

```
uv run pytest tests/test_finish_config_only_gate.py -v
uv run pytest tests/test_finish_gate.py -v
```
Both the new tests and the existing finish-gate suite pass.

### Step 5 — commit

```
git -C $WT add src/mship/cli/worktree.py tests/test_finish_config_only_gate.py
git -C $WT commit -m "finish: exempt config-only main-checkout drift from the dirty_worktree gate (fail-closed)"
mship journal "finish: config-only dirty exemption wired (ac1/ac2)" --task mship-config-workflow-doctor --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=5 -->
## Task 5 — `mship doctor` loads config with `require_paths=False` (ac3 code path)

So a not-yet-present / in-flux `Taskfile.yml` surfaces as a doctor `fail` check instead of crashing `ConfigLoader.load` before doctor even runs. The container singleton stays `require_paths=True`; only the doctor CLI path relaxes it.

**Files:** `src/mship/cli/doctor.py`, `tests/cli/test_doctor.py`

### Step 1 — write the failing test

Append to `tests/cli/test_doctor.py`:

```python
def test_doctor_loads_config_with_require_paths_false(workspace: Path):
    """A repo whose Taskfile.yml is missing must not crash doctor's config load;
    doctor should run and report a Taskfile fail check instead."""
    import json
    (workspace / "auth-service" / "Taskfile.yml").unlink()  # remove one Taskfile

    container.config.reset()
    container.state_manager.reset()
    container.config_path.override(workspace / "mothership.yaml")
    container.state_dir.override(workspace / ".mothership")
    (workspace / ".mothership").mkdir(exist_ok=True)

    mock_shell = MagicMock(spec=ShellRunner)
    mock_shell.run.side_effect = lambda cmd, cwd, env=None: (
        ShellResult(returncode=0, stdout="test\nrun\nlint\nsetup\n", stderr="") if "task --list" in cmd
        else ShellResult(returncode=0, stdout="Logged in", stderr="") if "gh auth" in cmd
        else ShellResult(returncode=0, stdout="", stderr="")
    )
    mock_shell.run_task.return_value = ShellResult(returncode=0, stdout="ok", stderr="")
    container.shell.override(mock_shell)
    try:
        result = runner.invoke(app, ["doctor"])
        assert result.exception is None, result.output  # NOT a ConfigLoader crash
        data = json.loads(result.output)                 # valid JSON, not a traceback
        assert any(
            c["status"] == "fail" and "Taskfile" in c["message"]
            for c in data["checks"]
        ), data["checks"]
    finally:
        container.config_path.reset_override()
        container.state_dir.reset_override()
        container.config.reset()
        container.state_manager.reset()
        container.shell.reset_override()
```

### Step 2 — run to fail

```
uv run pytest tests/cli/test_doctor.py::test_doctor_loads_config_with_require_paths_false -v
```
Expect: `result.exception` is a `ValueError("Repo 'auth-service' at ... has no Taskfile.yml")` from `container.config()` — assertion fails.

### Step 3 — implement

In `src/mship/cli/doctor.py`, inside `doctor()`, replace:

```python
        from mship.core.doctor import DoctorChecker

        config = container.config()
        shell = container.shell()
```

with:

```python
        from mship.core.doctor import DoctorChecker
        from mship.core.config import ConfigLoader

        # issue 366 #5/#3: load with require_paths=False so a not-yet-present or
        # being-changed Taskfile.yml surfaces as a doctor `fail` check rather
        # than hard-failing ConfigLoader.load before doctor can run. The
        # container singleton keeps require_paths=True for spawn/finish/exec.
        config = ConfigLoader.load(container.config_path(), require_paths=False)
        shell = container.shell()
```

### Step 4 — run to pass

```
uv run pytest tests/cli/test_doctor.py -v
```

### Step 5 — commit

```
git -C $WT add src/mship/cli/doctor.py tests/cli/test_doctor.py
git -C $WT commit -m "doctor: load config with require_paths=False so a missing Taskfile doesn't crash config load"
mship journal "doctor: require_paths=False config load (ac3)" --task mship-config-workflow-doctor --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=6 -->
## Task 6 — `mship status` reports resolved config path + resolution source (ac4)

Add two additive JSON keys to the status envelope (`cli/status.py:228-247`): `config_path` (absolute) and `config_resolution_source` (`env`/`marker`/`walk-up`, or `null` when the cwd-discovered path doesn't match the live config path). Reuses the `resolution_source` convention already used for tasks at `status.py:243` (that key is untouched; the new key is distinctly named).

**Files:** `src/mship/cli/status.py`, `tests/cli/test_status.py`

### Step 1 — write the failing test

Append to `tests/cli/test_status.py`:

```python
def test_status_reports_config_path_and_source(workspace, monkeypatch):
    monkeypatch.delenv("MSHIP_WORKSPACE", raising=False)
    container.config.reset()
    container.state_manager.reset()
    container.config_path.override(workspace / "mothership.yaml")
    container.state_dir.override(workspace / ".mothership")
    (workspace / ".mothership").mkdir(exist_ok=True)
    monkeypatch.chdir(workspace)
    try:
        result = runner.invoke(app, ["status"])
        assert result.exit_code == 0, result.output
        payload = json.loads(result.output)
        assert payload["config_path"] == str((workspace / "mothership.yaml").resolve())
        assert payload["config_resolution_source"] == "walk-up"
        # ac10: existing keys still present
        for k in ("workspace", "active_tasks", "resolved_task", "resolution_source"):
            assert k in payload
    finally:
        container.config_path.reset_override()
        container.state_dir.reset_override()
        container.config.reset()
        container.state_manager.reset()
```

### Step 2 — run to fail

```
uv run pytest tests/cli/test_status.py::test_status_reports_config_path_and_source -v
```
Expect: `KeyError: 'config_path'`.

### Step 3 — implement

In `src/mship/cli/status.py`, inside `status()`, just before building the `envelope` dict (`status.py:228`) add:

```python
        # --- Config resolution (issue 366 #6): absolute path + how it resolved.
        from mship.core.config import ConfigLoader
        config_path_abs = str(Path(container.config_path()).resolve())
        config_source: str | None = None
        try:
            res = ConfigLoader.discover_with_source(Path.cwd())
            if str(res.path.resolve()) == config_path_abs:
                config_source = res.source
        except Exception:
            config_source = None
```

Add the two keys to the `envelope` dict (after `"resolution_source": source,`):

```python
            "resolution_source": source,
            "config_path": config_path_abs,
            "config_resolution_source": config_source,
```

### Step 4 — run to pass

```
uv run pytest tests/cli/test_status.py -v
```

### Step 5 — commit

```
git -C $WT add src/mship/cli/status.py tests/cli/test_status.py
git -C $WT commit -m "status: report resolved config_path + config_resolution_source (additive JSON, ac4)"
mship journal "status: config_path + resolution source (ac4)" --task mship-config-workflow-doctor --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=7 -->
## Task 7 — `mship doctor` reports resolved config path + source (ac5)

Add a `config` CheckResult (visible in human `mship doctor`) and two additive top-level JSON keys (`config_path`, `config_resolution_source`). `DoctorChecker` gains two optional params (defaulting `None`), so the existing `bootstrap.py:188` caller and every `DoctorChecker(config, shell)` test are unaffected.

**Files:** `src/mship/core/doctor.py`, `src/mship/cli/doctor.py`, `tests/cli/test_doctor.py`, `tests/core/test_doctor.py`

### Step 1 — write the failing test

Append to `tests/core/test_doctor.py`:

```python
def test_doctor_appends_config_resolution_check(tmp_path):
    from mship.core.config import ConfigLoader
    from mship.core.doctor import DoctorChecker
    from unittest.mock import MagicMock
    from mship.util.shell import ShellRunner, ShellResult
    (tmp_path / "mothership.yaml").write_text(
        "workspace: t\nrepos:\n  a:\n    path: ./a\n    type: service\n"
    )
    (tmp_path / "a").mkdir()
    (tmp_path / "a" / "Taskfile.yml").write_text("version: '3'\ntasks: {}\n")
    config = ConfigLoader.load(tmp_path / "mothership.yaml")
    mock_shell = MagicMock(spec=ShellRunner)
    mock_shell.run.return_value = ShellResult(returncode=0, stdout="", stderr="")
    report = DoctorChecker(
        config, mock_shell,
        config_path=tmp_path / "mothership.yaml", config_source="walk-up",
    ).run()
    cfg_checks = [c for c in report.checks if c.name == "config"]
    assert cfg_checks and cfg_checks[0].status == "pass"
    assert "walk-up" in cfg_checks[0].message
    assert str((tmp_path / "mothership.yaml").resolve()) in cfg_checks[0].message
```

Append to `tests/cli/test_doctor.py`:

```python
def test_doctor_json_includes_config_path_and_source(workspace, monkeypatch):
    import json
    monkeypatch.delenv("MSHIP_WORKSPACE", raising=False)
    container.config.reset()
    container.state_manager.reset()
    container.config_path.override(workspace / "mothership.yaml")
    container.state_dir.override(workspace / ".mothership")
    (workspace / ".mothership").mkdir(exist_ok=True)
    mock_shell = MagicMock(spec=ShellRunner)
    mock_shell.run.side_effect = lambda cmd, cwd, env=None: (
        ShellResult(returncode=0, stdout="test\nrun\nlint\nsetup\n", stderr="") if "task --list" in cmd
        else ShellResult(returncode=0, stdout="Logged in", stderr="") if "gh auth" in cmd
        else ShellResult(returncode=0, stdout="", stderr="")
    )
    mock_shell.run_task.return_value = ShellResult(returncode=0, stdout="ok", stderr="")
    container.shell.override(mock_shell)
    monkeypatch.chdir(workspace)
    try:
        result = runner.invoke(app, ["doctor"])
        data = json.loads(result.output)
        assert data["config_path"] == str((workspace / "mothership.yaml").resolve())
        assert data["config_resolution_source"] == "walk-up"
        for k in ("checks", "warnings", "errors"):  # ac10: existing keys intact
            assert k in data
    finally:
        container.config_path.reset_override()
        container.state_dir.reset_override()
        container.config.reset()
        container.state_manager.reset()
        container.shell.reset_override()
```

### Step 2 — run to fail

```
uv run pytest tests/core/test_doctor.py::test_doctor_appends_config_resolution_check tests/cli/test_doctor.py::test_doctor_json_includes_config_path_and_source -v
```
Expect: `TypeError: __init__() got an unexpected keyword argument 'config_path'` / `KeyError: 'config_path'`.

### Step 3 — implement

In `src/mship/core/doctor.py`, extend `DoctorChecker.__init__` (`doctor.py:115-126`):

```python
    def __init__(
        self,
        config: WorkspaceConfig,
        shell: ShellRunner,
        *,
        state_dir: Path | None = None,
        workspace_root: Path | None = None,
        config_path: Path | None = None,
        config_source: str | None = None,
    ) -> None:
        self._config = config
        self._shell = shell
        self._state_dir = state_dir
        self._workspace_root = workspace_root
        self._config_path = config_path
        self._config_source = config_source
```

At the very start of `run()` (right after `report = DoctorReport()` at `doctor.py:129`):

```python
        report = DoctorReport()

        # issue 366 #6: report which config is live and how it resolved.
        if self._config_path is not None:
            report.checks.append(CheckResult(
                name="config",
                status="pass",
                message=(
                    f"config: {Path(self._config_path).resolve()} "
                    f"(resolved via {self._config_source or 'unknown'})"
                ),
            ))
```

In `src/mship/cli/doctor.py`, add `from pathlib import Path` at top. Inside `doctor()`, after the `config = ConfigLoader.load(...)` line from Task 5, compute the source and pass both into `DoctorChecker`, then add the JSON keys:

```python
        config_path = container.config_path()
        config_source = None
        try:
            res = ConfigLoader.discover_with_source(Path.cwd())
            if str(res.path.resolve()) == str(Path(config_path).resolve()):
                config_source = res.source
        except Exception:
            config_source = None

        checker = DoctorChecker(
            config,
            shell,
            state_dir=container.state_dir(),
            workspace_root=container.config_path().parent,
            config_path=config_path,
            config_source=config_source,
        )
        report = checker.run()
```

And in the `output.json({...})` block (`cli/doctor.py:55-59`) add the two keys:

```python
            output.json({
                "checks": [{"name": c.name, "status": c.status, "message": c.message} for c in report.checks],
                "warnings": report.warnings,
                "errors": report.errors,
                "config_path": str(Path(config_path).resolve()),
                "config_resolution_source": config_source,
            })
```

### Step 4 — run to pass

```
uv run pytest tests/core/test_doctor.py tests/cli/test_doctor.py -v
```

### Step 5 — commit

```
git -C $WT add src/mship/core/doctor.py src/mship/cli/doctor.py tests/core/test_doctor.py tests/cli/test_doctor.py
git -C $WT commit -m "doctor: report resolved config path + resolution source (check + additive JSON, ac5)"
mship journal "doctor: config path + resolution source (ac5)" --task mship-config-workflow-doctor --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=8 -->
## Task 8 — Assert ac6: hub-repo worktree resolves to WORKSPACE-root config via marker (largely pre-fixed)

The drafter flagged #6 as largely already satisfied: the marker walk-up (`config.py:513-517`) short-circuits before the plain `mothership.yaml` walk-up (`config.py:519-530`), so a hub-repo worktree that itself contains a tracked `mothership.yaml` still resolves to the workspace-root config with source `marker`. This is an ASSERT-only task (no production change) — it locks the behaviour in.

**Files:** `tests/core/test_config.py`

### Step 1 — write the test

Append to `tests/core/test_config.py`:

```python
def test_discover_with_source_hub_worktree_prefers_marker_over_own_yaml(tmp_path, monkeypatch):
    """ac6: from a hub-repo worktree that contains its OWN tracked mothership.yaml,
    discover must resolve to the WORKSPACE-root config via the marker, source=marker."""
    from mship.core.config import ConfigLoader
    from mship.core.workspace_marker import write_marker
    monkeypatch.delenv("MSHIP_WORKSPACE", raising=False)

    root = tmp_path / "ws"; root.mkdir()
    (root / "mothership.yaml").write_text("workspace: root\nrepos: {}\n")

    # Hub container gets a marker (write_marker at worktree.py:698); the hub-repo
    # worktree lands under it and carries its OWN tracked mothership.yaml copy.
    container_dir = root / ".worktrees" / "t"; container_dir.mkdir(parents=True)
    write_marker(container_dir, root)
    hub_wt = container_dir / "hub"; hub_wt.mkdir()
    (hub_wt / "mothership.yaml").write_text("workspace: SHADOW\nrepos: {}\n")

    res = ConfigLoader.discover_with_source(hub_wt)
    assert res.path == root / "mothership.yaml"     # NOT the worktree's own copy
    assert res.source == "marker"
```

### Step 2 — run (expected PASS immediately — assert-only)

```
uv run pytest tests/core/test_config.py::test_discover_with_source_hub_worktree_prefers_marker_over_own_yaml -v
```
This should PASS against the current marker walk-up. If it fails, STOP and treat #6 as not-pre-fixed (revisit discovery ordering) rather than editing the test to green.

### Step 3 — commit

```
git -C $WT add tests/core/test_config.py
git -C $WT commit -m "test: assert hub-worktree config resolves to workspace root via marker (ac6, pre-fixed)"
mship journal "test: ac6 marker precedence over worktree's own mothership.yaml" --task mship-config-workflow-doctor --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=9 -->
## Task 9 — Per-worktree `.mship-workspace` marker + `.gitignore` guard on every repo worktree (ac7)

Currently only the hub CONTAINER gets a marker (`worktree.py:698`). Write a marker into each repo worktree too — the normal-repo branch (`worktree.py:583-675`) is the SINGLE code path that also creates the hub repo's own `path: .` worktree, so this covers "including the hub repo's own worktree" by construction. Guard-add `.mship-workspace` to that worktree's `.gitignore` (mirrors the `.worktrees` handling at `worktree.py:546-549`) so the marker never pollutes `git status`.

**Files:** `src/mship/core/worktree.py`, `tests/core/test_worktree.py`

### Step 1 — write the failing test

Append to `tests/core/test_worktree.py`:

```python
def test_spawn_writes_marker_into_each_worktree(worktree_deps):
    from mship.core.workspace_marker import MARKER_NAME
    config, graph, state_mgr, git, shell, workspace, log = worktree_deps
    mgr = WorktreeManager(config, graph, state_mgr, git, shell, log)
    mgr.spawn("marker task", repos=["shared", "auth-service"], workspace_root=workspace)
    state = state_mgr.load()
    task = state.tasks["marker-task"]
    for repo_name in ["shared", "auth-service"]:
        wt = Path(task.worktrees[repo_name])
        marker = wt / MARKER_NAME
        assert marker.is_file(), f"missing marker in {wt}"
        assert marker.read_text().strip() == str(workspace.resolve())
        # Marker is ignored inside the worktree → no git status pollution.
        assert GitRunner().is_ignored(wt, MARKER_NAME) is True
```

### Step 2 — run to fail

```
uv run pytest tests/core/test_worktree.py::test_spawn_writes_marker_into_each_worktree -v
```
Expect: `AssertionError: missing marker in ...` (only the container currently gets a marker).

### Step 3 — implement

In `src/mship/core/worktree.py`, extend the marker import (`worktree.py:13`) to `from mship.core.workspace_marker import write_marker, MARKER_NAME`.

In the normal-repo branch, immediately after `worktrees[repo_name] = wt_path` (`worktree.py:675`) add:

```python
            worktrees[repo_name] = wt_path

            # issue 366 #7: every repo worktree — including the hub repo's own
            # `path: .` worktree, which flows through this same branch — carries
            # its own `.mship-workspace` marker pointing at the workspace root,
            # ignored in the worktree's .gitignore so it stays out of git status.
            # Belt-and-suspenders with the hub-container marker written below:
            # if the container marker is removed, this per-worktree marker still
            # resolves `discover` to the workspace root instead of falling
            # through to the worktree's own tracked mothership.yaml.
            write_marker(wt_path, workspace_root)
            if not self._git.is_ignored(wt_path, MARKER_NAME):
                self._git.add_to_gitignore(wt_path, MARKER_NAME)
```

(The container marker at `worktree.py:698` stays.)

### Step 4 — run to pass

```
uv run pytest tests/core/test_worktree.py -v
uv run pytest tests/core/test_workspace_marker.py -v
```
Existing spawn tests still pass (marker file + gitignore line are additive to each worktree).

### Step 5 — commit

```
git -C $WT add src/mship/core/worktree.py tests/core/test_worktree.py
git -C $WT commit -m "worktree: write .mship-workspace marker into every repo worktree + gitignore guard (ac7)"
mship journal "worktree: per-worktree marker incl hub repo's own worktree (ac7)" --task mship-config-workflow-doctor --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=10 -->
## Task 10 — `mship doctor` best-effort bundling-exclusion heuristic (ac8)

Add a `warn`-only `_check_bundler_exclusions` to `DoctorChecker` that inspects known bundler configs at the workspace root and flags a missing `.worktrees`/`.mothership` exclusion. Every message explicitly states it is a best-effort heuristic that cannot detect every bundler. Never raises severity above `warn`. Only runs when `workspace_root` is provided (so the many `DoctorChecker(config, shell)` unit tests are unaffected).

**Files:** `src/mship/core/doctor.py`, `tests/core/test_doctor.py`

### Step 1 — write the failing test

Append to `tests/core/test_doctor.py`:

```python
def _bundler_report(tmp_path):
    from mship.core.config import ConfigLoader
    from mship.core.doctor import DoctorChecker
    from unittest.mock import MagicMock
    from mship.util.shell import ShellRunner, ShellResult
    (tmp_path / "mothership.yaml").write_text(
        "workspace: t\nrepos:\n  a:\n    path: ./a\n    type: service\n"
    )
    (tmp_path / "a").mkdir()
    (tmp_path / "a" / "Taskfile.yml").write_text("version: '3'\ntasks: {}\n")
    config = ConfigLoader.load(tmp_path / "mothership.yaml")
    mock_shell = MagicMock(spec=ShellRunner)
    mock_shell.run.return_value = ShellResult(returncode=0, stdout="", stderr="")
    return DoctorChecker(config, mock_shell, workspace_root=tmp_path).run()


def test_doctor_bundler_warns_dockerignore_missing_worktrees(tmp_path):
    (tmp_path / ".dockerignore").write_text("node_modules\n")
    report = _bundler_report(tmp_path)
    warns = [c for c in report.checks if c.name == "bundler/docker"]
    assert warns and warns[0].status == "warn"
    assert "heuristic" in warns[0].message.lower()
    assert report.errors == 0  # never escalates to fail


def test_doctor_bundler_no_warn_when_dockerignore_excludes(tmp_path):
    (tmp_path / ".dockerignore").write_text("node_modules\n.worktrees\n.mothership\n")
    report = _bundler_report(tmp_path)
    assert not [c for c in report.checks if c.name == "bundler/docker"]


def test_doctor_bundler_warns_serverless(tmp_path):
    (tmp_path / "serverless.yml").write_text("service: x\nprovider: {name: aws}\n")
    report = _bundler_report(tmp_path)
    warns = [c for c in report.checks if c.name == "bundler/serverless"]
    assert warns and warns[0].status == "warn"
    assert "heuristic" in warns[0].message.lower()


def test_doctor_bundler_warns_cdk_from_asset(tmp_path):
    (tmp_path / "stack.ts").write_text("new lambda.Function(this,'f',{code: lambda.Code.fromAsset('.')});\n")
    report = _bundler_report(tmp_path)
    warns = [c for c in report.checks if c.name == "bundler/cdk"]
    assert warns and warns[0].status == "warn"
    assert report.errors == 0
```

### Step 2 — run to fail

```
uv run pytest tests/core/test_doctor.py::test_doctor_bundler_warns_dockerignore_missing_worktrees tests/core/test_doctor.py::test_doctor_bundler_warns_serverless tests/core/test_doctor.py::test_doctor_bundler_warns_cdk_from_asset -v
```
Expect: no `bundler/*` checks found.

### Step 3 — implement

In `src/mship/core/doctor.py`, in `run()`, right after the existing workspace `.gitignore` block (`doctor.py:328-341`) add:

```python
        # Bundler-exclusion heuristic (issue 366 #7) — best-effort, warn-only.
        if ws is not None and ws.is_dir():
            report.checks.extend(self._check_bundler_exclusions(ws))
```

Add this method to `DoctorChecker` (e.g. after `_detect_mship_dev_workspace`):

```python
    def _check_bundler_exclusions(self, ws: Path) -> list[CheckResult]:
        """WARN when a known asset-bundling config at the workspace root does not
        exclude `.worktrees`/`.mothership`. Best-effort heuristic (issue 366 #7):
        it inspects a curated set of bundler configs, cannot detect every tool,
        and never raises severity above `warn`.
        """
        results: list[CheckResult] = []
        heur = (
            " (best-effort heuristic — mship cannot detect every bundler; "
            "verify your build excludes `.worktrees`/`.mothership`)"
        )
        tokens = (".worktrees", ".mothership")

        def _excludes(text: str) -> bool:
            return any(tok in text for tok in tokens)

        # Docker
        dockerignore = ws / ".dockerignore"
        dockerfile = ws / "Dockerfile"
        if dockerignore.exists():
            try:
                if not _excludes(dockerignore.read_text()):
                    results.append(CheckResult(
                        name="bundler/docker", status="warn",
                        message=(".dockerignore does not exclude `.worktrees`/"
                                 "`.mothership` — the Docker build context will ship "
                                 "worktree checkouts" + heur),
                    ))
            except OSError:
                pass
        elif dockerfile.exists():
            results.append(CheckResult(
                name="bundler/docker", status="warn",
                message=("Dockerfile present but no .dockerignore excludes "
                         "`.worktrees`/`.mothership`" + heur),
            ))

        # serverless
        for fname in ("serverless.yml", "serverless.yaml"):
            f = ws / fname
            if f.exists():
                try:
                    if not _excludes(f.read_text()):
                        results.append(CheckResult(
                            name="bundler/serverless", status="warn",
                            message=(f"{fname} does not exclude `.worktrees`/"
                                     "`.mothership`" + heur),
                        ))
                except OSError:
                    pass

        # SAM
        for fname in ("template.yaml", "template.yml"):
            f = ws / fname
            if f.exists():
                try:
                    text = f.read_text()
                except OSError:
                    continue
                if "AWS::Serverless" in text and not _excludes(text):
                    results.append(CheckResult(
                        name="bundler/sam", status="warn",
                        message=(f"SAM template {fname} does not exclude "
                                 "`.worktrees`/`.mothership`" + heur),
                    ))

        # npm pack (`files` allowlist)
        pkg = ws / "package.json"
        if pkg.exists():
            try:
                import json as _json
                data = _json.loads(pkg.read_text())
            except Exception:
                data = {}
            if isinstance(data, dict) and "files" in data:
                results.append(CheckResult(
                    name="bundler/npm", status="warn",
                    message=("package.json declares `files` for `npm pack` — confirm "
                             "it does not bundle `.worktrees`/`.mothership`" + heur),
                ))

        # CDK Code.fromAsset — shallow scan of workspace-root files only
        for f in ws.iterdir():
            if not f.is_file() or f.suffix not in (".ts", ".js", ".py"):
                continue
            try:
                text = f.read_text()
            except OSError:
                continue
            if "Code.fromAsset" in text:
                results.append(CheckResult(
                    name="bundler/cdk", status="warn",
                    message=("CDK `Code.fromAsset` bundling detected at the workspace "
                             "root; ensure the asset root excludes `.worktrees`/"
                             "`.mothership`" + heur),
                ))
                break

        return results
```

### Step 4 — run to pass

```
uv run pytest tests/core/test_doctor.py -v
uv run pytest tests/cli/test_doctor.py -v
```
Existing doctor tests still pass (the plain `workspace` fixture has no bundler configs at root, so no new warns).

### Step 5 — commit

```
git -C $WT add src/mship/core/doctor.py tests/core/test_doctor.py
git -C $WT commit -m "doctor: best-effort bundler-exclusion heuristic for .worktrees/.mothership (warn-only, ac8)"
mship journal "doctor: bundler-exclusion heuristic (ac8)" --task mship-config-workflow-doctor --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=11 -->
## Task 11 — Docs: config-change/bootstrap workflow + bundler callout (ac3 docs, ac9)

Add both callouts to `README.md` (where the worktree layout / architecture is introduced) and to the working-with-mothership skill (`SKILL.md`, near the worktree-layout section). Guard them with a docs-content test.

**Files:** `README.md`, `src/mship/skills/working-with-mothership/SKILL.md`, `tests/test_docs_config_workflow.py` (new)

### Step 1 — write the failing test

Create `tests/test_docs_config_workflow.py`:

```python
"""issue 366 #5/#7: docs must cover the config-change workflow and the
`.worktrees`/`.mothership` bundler caveat, in both README and the skill."""
from pathlib import Path

from mship.core.skill_install import pkg_skills_source

README = Path(__file__).resolve().parent.parent / "README.md"
SKILL = pkg_skills_source() / "working-with-mothership" / "SKILL.md"


def _text(p: Path) -> str:
    return p.read_text().lower()


def test_readme_documents_config_change_workflow():
    t = _text(README)
    assert "mothership.yaml" in t and "mship doctor" in t
    assert "config-only" in t          # the dirty_worktree exemption is named
    assert "require_paths" in t or "not-yet-present" in t


def test_readme_documents_bundler_caveat():
    t = _text(README)
    assert ".worktrees" in t and ".mothership" in t
    assert "code.fromasset" in t and "bundl" in t
    assert "gitignore" in t


def test_skill_documents_config_change_workflow():
    t = _text(SKILL)
    assert "config-only" in t and "mship doctor" in t


def test_skill_documents_bundler_caveat():
    t = _text(SKILL)
    assert ".worktrees" in t and ".mothership" in t
    assert "bundl" in t and "gitignore" in t
```

### Step 2 — run to fail

```
uv run pytest tests/test_docs_config_workflow.py -v
```
Expect all four to fail (tokens absent).

### Step 3 — implement (docs only)

In `README.md`, in the worktree-layout / architecture section, add two short subsections. Suggested content:

> **Changing workspace config.** To edit `mothership.yaml` or a per-repo `Taskfile`, edit it directly in the main checkout, run `mship doctor`, then commit. mship exempts **config-only** edits (confined to `mothership.yaml` and/or a `Taskfile`) from the `dirty_worktree` gate, so `mship finish` is not blocked — the moment any non-config file is modified the gate re-applies (fail-closed). `mship doctor` loads config with path validation relaxed (`require_paths=False`) so a not-yet-present or in-flux `Taskfile.yml` does not hard-fail loading before your change lands.

> **Build/bundling caveat.** `.worktrees/` and `.mothership/` live at the **repo root**. Any bundler that does not honor `.gitignore` — AWS CDK `Code.fromAsset`, the Docker build context, `npm pack`, `sam build`, serverless — must exclude them explicitly. The `.gitignore` entry `mship spawn` adds protects git but **not** those bundlers; `mship doctor` emits a best-effort warning when it spots a bundling config that doesn't exclude them.

In `src/mship/skills/working-with-mothership/SKILL.md`, near the worktree-layout note, add equivalent copy including the tokens `config-only`, `mship doctor`, `.worktrees`, `.mothership`, `bundl`(er/ing), `Code.fromAsset`, and `gitignore`.

### Step 4 — run to pass

```
uv run pytest tests/test_docs_config_workflow.py -v
```

### Step 5 — commit

```
git -C $WT add README.md src/mship/skills/working-with-mothership/SKILL.md tests/test_docs_config_workflow.py
git -C $WT commit -m "docs: config-change workflow + .worktrees/.mothership bundler caveat (ac3 docs, ac9)"
mship journal "docs: config-change workflow + bundler caveat (ac3/ac9)" --task mship-config-workflow-doctor --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=12 -->
## Task 12 — Additive-JSON / determinism regression guard (ac10)

Lock in that the new `status`/`doctor` fields are additive: every pre-existing top-level key is still present, and only the two new keys were added.

**Files:** `tests/cli/test_status.py`, `tests/cli/test_doctor.py`

### Step 1 — write the test

Append to `tests/cli/test_status.py`:

```python
def test_status_json_keys_are_additive(configured_app, monkeypatch):
    monkeypatch.delenv("MSHIP_WORKSPACE", raising=False)
    result = runner.invoke(app, ["status"])
    assert result.exit_code == 0
    payload = json.loads(result.output)
    # Pre-existing keys preserved (no rename/removal):
    for k in ("workspace", "active_tasks", "resolved_task", "resolution_source"):
        assert k in payload, k
    # New additive keys present:
    assert "config_path" in payload
    assert "config_resolution_source" in payload
```

Append to `tests/cli/test_doctor.py`:

```python
def test_doctor_json_keys_are_additive(configured_doctor_app, monkeypatch):
    import json
    monkeypatch.delenv("MSHIP_WORKSPACE", raising=False)
    result = runner.invoke(app, ["doctor"])
    data = json.loads(result.output)
    for k in ("checks", "warnings", "errors"):      # pre-existing keys intact
        assert k in data, k
    assert "config_path" in data                     # new additive keys
    assert "config_resolution_source" in data
    # Each check object keeps its stable schema:
    for c in data["checks"]:
        assert set(c.keys()) == {"name", "status", "message"}
```

> NOTE: `configured_app` / `configured_doctor_app` are placeholders for whatever configured-CLI fixture each test module already uses — reuse the existing fixture pattern in that file rather than inventing a new one.

### Step 2 — run

```
uv run pytest tests/cli/test_status.py::test_status_json_keys_are_additive tests/cli/test_doctor.py::test_doctor_json_keys_are_additive -v
```
Both pass (fields delivered in Tasks 6/7). If either fails, a prior task renamed/removed a key — fix the task, not the test.

### Step 3 — full-suite verification

```
uv run pytest -q
```
Green. Then, per `verification-before-completion`, manually exercise real output from `$WT`:

```
uv run mship --json status | python -m json.tool
uv run mship --json doctor | python -m json.tool
```
Confirm `config_path` + `config_resolution_source` render.

### Step 4 — commit

```
git -C $WT add tests/cli/test_status.py tests/cli/test_doctor.py
git -C $WT commit -m "test: additive-JSON regression guard for status/doctor config fields (ac10)"
mship journal "test: additive-JSON regression guard (ac10)" --task mship-config-workflow-doctor --action committed
```
<!-- /mship:task -->

---

## Self-Review

### AC → Task map (all 10)

| AC | Covered by | Notes |
| --- | --- | --- |
| ac1 (config-only edit doesn't block finish) | Tasks 2, 3, 4 | paths recorded → predicate → filter → wired into finish |
| ac2 (any non-config file re-blocks; fail-closed) | Tasks 3, 4 | `is_config_only_paths` returns False on empty/mixed/look-alike |
| ac3 (documented workflow + doctor `require_paths=False`) | Tasks 5 (code), 11 (docs) | container singleton stays `require_paths=True` |
| ac4 (status: config path + source) | Task 6 | reuses `resolution_source` convention; distinct key `config_resolution_source` |
| ac5 (doctor: config path + source) | Task 7 | `config` CheckResult + top-level JSON keys |
| ac6 (hub worktree resolves to workspace root via marker) | Task 8 | assert-only; drafter flagged as pre-fixed; reinforced by Task 9 |
| ac7 (marker in every worktree incl. hub's own + gitignore) | Task 9 | normal-repo branch is the shared path that also creates the `path: .` hub worktree |
| ac8 (doctor bundling WARN, best-effort) | Task 10 | warn-only; message states "best-effort heuristic"; `report.errors == 0` asserted |
| ac9 (docs bundler caveat) | Task 11 | README + skill; test guards token presence |
| ac10 (additive JSON) | Tasks 6, 7, 12 | new keys only; `Issue.paths` is `compare=False` + not serialized |

### Placeholder scan

Complete Python/Markdown in every step. The only note-to-implementer is Task 12's `configured_app`/`configured_doctor_app` fixture names — reuse the file's existing configured-CLI fixture.

### Type consistency

`discover_with_source(start) -> ConfigResolution` NEW; `discover(start) -> Path` preserved as delegate. Existing `discover` callers (`gate.py:53`, `gate.py:72`, `cli/__init__.py:95`) still receive a `Path`. `Issue.paths: tuple[str, ...] = field(default=(), compare=False)` — equality/hash unchanged; `to_json` doesn't serialize it; `_enrich_active_task` reconstruction preserves it (critical, guarded). `DoctorChecker.__init__` gains two keyword-only params defaulting `None`.

### Additive-JSON guarantee (ac10)

status adds `config_path`/`config_resolution_source`; doctor adds the same + a `config` CheckResult + optional `bundler/*` warns (same `{name,status,message}` object schema). No key renamed/removed. `AuditReport.to_json` byte-stable.
