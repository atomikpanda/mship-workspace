# mship onboarding fail-loud (issue #366 findings #1-3) — Implementation Plan

**REQUIRED SUB-SKILL:** `test-driven-development` (write the failing pytest first, watch it fail, implement, watch it pass, commit — every task).

**Spec id:** `mship-onboarding-fail-loud` (approved + dispatched). Source of truth = the 15 acceptance criteria in `mship spec show mship-onboarding-fail-loud`.

**Goal:** Enforce mothership's own already-declared "fail loud instead of silently falling through" principle in the three onboarding places issue #366 proves it is violated: (#1) a false-green `Taskfile.yml` stub that shadows an existing `Taskfile.yaml` and whose `echo` commands exit 0; (#2) an absolute `git_root` child `path` that `pathlib`'s `/` resolves to the source checkout; (#3) a `git_root` parent that passive worktree expansion never materializes, silently falling back to the main checkout.

**Architecture:**
- **Finding #1 (init/config/doctor):** one canonical go-task resolution set + helper in `config.py`, reused by `write_taskfile` (suppress the stub for ANY spelling, return a result so the CLI can offer a rename), `ConfigLoader.load` (accept any spelling), `doctor` (warn when >1 resolves), and `detect_repos` (ignore a lone generated stub, matched by content). `TASKFILE_TEMPLATE` commands become `exit 1`.
- **Finding #2 (config):** a `RepoConfig` `@model_validator(mode="after")` mirroring `validate_bind_files` — rejects an absolute or `..`-bearing `path` when `git_root` is set, at model construction (independent of `require_paths`).
- **Finding #3 (graph/worktree/config):** `git_root` becomes an implicit parent→child ordering edge in `DependencyGraph` (so passive expansion materializes the parent) and in `validate_no_cycles` (so an opposite-direction `depends_on` is rejected as the cycle it is); the silent main-checkout fallback in `worktree.py` becomes a `raise`.

**Tech Stack:** Python 3, Pydantic v2 models, Typer CLI, pytest. Tests run with `uv run pytest tests/<path>::<test> -v` with **cwd = the worktree** `/home/bailey/development/repos/mship-workspace/.worktrees/mship-onboarding-fail-loud/mothership` (call it `$WT` below). RepoConfig has **no** `model_config` → `validate_assignment` is off, so `ConfigLoader.load`'s in-place `repo.path = resolved` on top-level repos does NOT re-trigger the new validator (and top-level repos have `git_root=None` anyway).

**Per-task commit (run after each task goes green):**
```
git -C $WT add <files>
git -C $WT commit -m "<msg>

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "<msg>" --task mship-onboarding-fail-loud --action committed
```

## File Structure

| File | Change |
| --- | --- |
| `src/mship/core/config.py` | Add `GO_TASK_FILENAMES` + `resolve_go_task_files`; add `RepoConfig.validate_git_root_child_path`; use resolution set in `ConfigLoader.load` (both passes); fold `git_root` edge into `validate_no_cycles`. |
| `src/mship/core/init.py` | Add `TaskfileWriteResult`; `TASKFILE_TEMPLATE` → `exit 1`; `write_taskfile` suppresses stub for full resolution set + returns result; `_find_markers` ignores generated-stub Taskfile. |
| `src/mship/core/graph.py` | Add implicit `git_root` parent→child edge in `DependencyGraph.__init__`. |
| `src/mship/core/worktree.py` | Turn the git_root silent fallback (`:557-559`) into a `raise`. |
| `src/mship/core/doctor.py` | Taskfile presence check uses resolution set; warn when >1 go-task file resolves. |
| `src/mship/cli/init.py` | Guard scaffold against full resolution set; surface rename offer from `write_taskfile` result (human + JSON). |
| `docs/configuration.md` | Document git_root children require relative paths + auto-ordering. |
| `tests/core/test_config.py` | New validator, resolution-set, cycle tests. |
| `tests/core/test_init.py` | New template/suppression/detect tests. |
| `tests/core/test_graph.py` | New implicit-edge tests. |
| `tests/core/test_worktree.py` | New raise + spawn-integration tests. |
| `tests/core/test_doctor.py` | New >1-file + `.yaml`-accept tests. |
| `tests/core/test_context.py` | **Fix** `:435` absolute git_root child → relative (breaks under new validator). |
| `tests/test_init_integration.py` | New CLI rename-offer test. |
| `tests/test_docs_config_workflow.py` | New configuration.md content test. |

---

<!-- mship:task id=1 -->
## Task 1 — RepoConfig git_root child-path validator (ac7, ac8, ac9)

**Files:**
- `src/mship/core/config.py` (add validator on `RepoConfig`, after `validate_bind_files` at ~:220-231)
- `tests/core/test_config.py` (new tests)
- `tests/core/test_context.py` (**fix** the one direct construction that will break: `:435`)
- Construction/caller audit (list, verify unaffected): `src/mship/core/init.py:105` `RepoConfig(...)` sets no `git_root` → unaffected; `tests/core/test_serve_exec.py:134` `path=Path("server")` relative → unaffected; `tests/cli/test_finish_groups.py` `path=Path(".")`/`Path("web")` relative → unaffected. Only `tests/core/test_context.py:435` uses an absolute path with `git_root` → must be fixed in this task.

**Step 1 — write failing tests** (append to `tests/core/test_config.py`):
```python
def test_git_root_child_absolute_path_rejected():
    """#366 #2: an absolute git_root child path silently resolves to the SOURCE
    checkout (pathlib drops the left operand on `/`); reject at construction."""
    from mship.core.config import RepoConfig
    with pytest.raises(ValueError) as exc:
        RepoConfig(path=Path("/abs/child"), type="library", git_root="mono")
    msg = str(exc.value)
    assert "/abs/child" in msg
    assert "absolute" in msg.lower()
    assert "git_root" in msg


def test_git_root_child_parent_escape_rejected():
    """ac8: a `..`-bearing git_root child path escapes the parent worktree."""
    from mship.core.config import RepoConfig
    with pytest.raises(ValueError) as exc:
        RepoConfig(path=Path("../sibling"), type="library", git_root="mono")
    assert ".." in str(exc.value)
    assert "git_root" in str(exc.value)


def test_git_root_child_relative_path_ok_and_nests(tmp_path: Path):
    """ac9: a relative git_root child still constructs and resolves nested under
    the parent worktree — no regression for valid monorepo configs."""
    from mship.core.config import RepoConfig
    child = RepoConfig(path=Path("web"), type="service", git_root="root")
    assert str(child.path) == "web"
    parent_path = tmp_path / "monorepo"
    effective = (parent_path / child.path).resolve()
    assert effective == (parent_path / "web").resolve()
    assert str(effective).startswith(str(parent_path.resolve()))


def test_top_level_absolute_path_still_allowed(tmp_path: Path):
    """Non-goal guard: TOP-LEVEL (no git_root) repos may still use absolute paths
    (what `init --detect` emits). The validator must only constrain git_root children."""
    from mship.core.config import RepoConfig
    r = RepoConfig(path=(tmp_path / "svc"), type="service")
    assert r.path.is_absolute()
```

**Step 2 — run to fail** (cwd `$WT`):
```
uv run pytest "tests/core/test_config.py::test_git_root_child_absolute_path_rejected" "tests/core/test_config.py::test_git_root_child_parent_escape_rejected" -v
```
Expected: both FAIL (`DID NOT RAISE ValueError`). The two "ok" tests already pass (no validator yet).

**Step 3 — implement.** In `src/mship/core/config.py`, add after `validate_bind_files` (ends ~:231):
```python
    @model_validator(mode="after")
    def validate_git_root_child_path(self) -> "RepoConfig":
        """A git_root child's `path` is joined onto its parent's worktree
        (`parent.path / child.path`, config.py + worktree.py + doctor.py).
        pathlib DISCARDS the left operand when the right side is absolute, so an
        ABSOLUTE child path silently resolves to the source checkout instead of
        the task worktree; a `..` escapes the parent. Reject both at model
        construction — mirroring validate_bind_files — so it fires independent of
        ConfigLoader.load's `require_paths` flag. See issue #366 finding #2."""
        if self.git_root is None:
            return self
        if self.path.is_absolute():
            raise ValueError(
                f"repo path {str(self.path)!r} is absolute but git_root="
                f"{self.git_root!r} is set; git_root child paths must be relative "
                f"to the parent worktree (an absolute path resolves to the source "
                f"checkout, not the task worktree)"
            )
        if ".." in self.path.parts:
            raise ValueError(
                f"repo path {str(self.path)!r} contains '..' but git_root="
                f"{self.git_root!r} is set; git_root child paths must stay inside "
                f"the parent worktree"
            )
        return self
```
Then **fix** `tests/core/test_context.py:435` (change the absolute child path to relative — the test only uses `git_root` children for the skip assertion, so a relative path is equivalent):
```python
            "pkg": RepoConfig(path=Path("pkg"), type="library", git_root="mono"),
```
(`context.py` computes `(parent.path / repo.path).resolve()` = `parent_dir / "pkg"` = the same `child_dir`, so `main_checkout_clean` behavior is unchanged.)

**Step 4 — run to pass:**
```
uv run pytest "tests/core/test_config.py::test_git_root_child_absolute_path_rejected" "tests/core/test_config.py::test_git_root_child_parent_escape_rejected" "tests/core/test_config.py::test_git_root_child_relative_path_ok_and_nests" "tests/core/test_config.py::test_top_level_absolute_path_still_allowed" "tests/core/test_context.py::test_main_checkout_clean_skips_git_root_children" -v
```

**Step 5 — commit** (`git -C $WT add src/mship/core/config.py tests/core/test_config.py tests/core/test_context.py` …) msg: `#366 #2: reject absolute/.. git_root child paths at RepoConfig construction`.
<!-- /mship:task -->

---

<!-- mship:task id=2 -->
## Task 2 — go-task resolution set + ConfigLoader accepts every spelling (ac4)

**Files:**
- `src/mship/core/config.py` (add `GO_TASK_FILENAMES` + `resolve_go_task_files`; both `ConfigLoader.load` passes at `:484` and `:500`)
- `tests/core/test_config.py` (new tests)
- Caller audit: hardcoded `"Taskfile.yml"` literals live at `config.py:484,500` (this task), `doctor.py:162` (Task 9), `init.py:12,148` (Tasks 3/4). `repo_state.py:94-98` has its OWN `_CONFIG_ONLY_BASENAMES` for a different purpose (config-only dirty detection incl. `mothership.yaml`, no `.dist` variants) — leave it untouched.

**Step 1 — write failing tests** (append to `tests/core/test_config.py`):
```python
import pytest as _pytest  # noqa: F401 (pytest already imported at top)


@_pytest.mark.parametrize("fname", [
    "Taskfile.yml", "Taskfile.yaml", "taskfile.yml", "taskfile.yaml",
    "Taskfile.dist.yml", "Taskfile.dist.yaml", "taskfile.dist.yml", "taskfile.dist.yaml",
])
def test_resolve_go_task_files_matches_full_set(tmp_path: Path, fname: str):
    from mship.core.config import resolve_go_task_files
    (tmp_path / fname).write_text("version: '3'\n")
    found = resolve_go_task_files(tmp_path)
    assert [p.name for p in found] == [fname]


def test_load_accepts_taskfile_yaml_spelling(tmp_path: Path):
    """ac4: a top-level repo whose go-task file is `Taskfile.yaml` (not `.yml`)
    loads instead of raising 'has no Taskfile.yml'."""
    repo = tmp_path / "svc"
    repo.mkdir()
    (repo / "Taskfile.yaml").write_text("version: '3'\ntasks: {}\n")
    cfg = tmp_path / "mothership.yaml"
    cfg.write_text("workspace: t\nrepos:\n  svc:\n    path: ./svc\n    type: service\n")
    config = ConfigLoader.load(cfg)
    assert "svc" in config.repos


def test_load_git_root_child_accepts_yaml_spelling(tmp_path: Path):
    """ac4 second pass: the git_root subdir check also accepts `.yaml`."""
    root = tmp_path / "mono"; root.mkdir()
    (root / "Taskfile.yml").write_text("version: '3'\n")
    web = root / "web"; web.mkdir()
    (web / "Taskfile.yaml").write_text("version: '3'\n")
    cfg = tmp_path / "mothership.yaml"
    cfg.write_text(
        "workspace: mono\nrepos:\n"
        "  mono:\n    path: ./mono\n    type: service\n"
        "  web:\n    path: web\n    type: service\n    git_root: mono\n"
    )
    config = ConfigLoader.load(cfg)
    assert config.repos["web"].git_root == "mono"
```

**Step 2 — run to fail:**
```
uv run pytest "tests/core/test_config.py::test_load_accepts_taskfile_yaml_spelling" "tests/core/test_config.py::test_resolve_go_task_files_matches_full_set" -v
```
Expected: `test_load_accepts...` FAILS (`has no Taskfile.yml`); parametrized test ERRORS (`ImportError: cannot import name 'resolve_go_task_files'`).

**Step 3 — implement.** In `config.py`, after the imports / `ConfigResolution` (before `class Dependency`):
```python
# go-task's Taskfile resolution set — the filenames `task` auto-discovers in a
# directory, in go-task's own precedence order (highest first). mship must treat
# ALL of these as "a go-task file exists here" so it never shadows an existing
# `Taskfile.yaml` (etc.) with a generated `Taskfile.yml` stub, and so config
# load / doctor accept any valid spelling. See issue #366 finding #1.
GO_TASK_FILENAMES: tuple[str, ...] = (
    "Taskfile.yml",
    "Taskfile.yaml",
    "taskfile.yml",
    "taskfile.yaml",
    "Taskfile.dist.yml",
    "Taskfile.dist.yaml",
    "taskfile.dist.yml",
    "taskfile.dist.yaml",
)


def resolve_go_task_files(directory: Path) -> list[Path]:
    """Existing go-task files in `directory`, in go-task resolution order.

    Empty list == no go-task file. More than one == an ambiguous directory where
    the file `task` actually runs depends on go-task's precedence (doctor warns)."""
    return [directory / name for name in GO_TASK_FILENAMES if (directory / name).is_file()]
```
In `ConfigLoader.load`, first pass — replace `:484-487`:
```python
                if not resolve_go_task_files(resolved):
                    raise ValueError(
                        f"Repo '{name}' at {resolved} has no go-task file "
                        f"(looked for one of: {', '.join(GO_TASK_FILENAMES)})"
                    )
```
Second pass — replace `:500-503`:
```python
                if not resolve_go_task_files(effective):
                    raise ValueError(
                        f"Repo '{name}' at {effective} has no go-task file "
                        f"(looked for one of: {', '.join(GO_TASK_FILENAMES)})"
                    )
```
(New message still contains "Taskfile.yml" via the joined set, so the existing `test_missing_taskfile_raises` `match="Taskfile"` still passes.)

**Step 4 — run to pass:**
```
uv run pytest "tests/core/test_config.py::test_resolve_go_task_files_matches_full_set" "tests/core/test_config.py::test_load_accepts_taskfile_yaml_spelling" "tests/core/test_config.py::test_load_git_root_child_accepts_yaml_spelling" "tests/core/test_config.py::test_missing_taskfile_raises" -v
```

**Step 5 — commit:** `git -C $WT add src/mship/core/config.py tests/core/test_config.py` — msg `#366 #1: ConfigLoader accepts full go-task resolution set`.
<!-- /mship:task -->

---

<!-- mship:task id=3 -->
## Task 3 — TASKFILE_TEMPLATE exits non-zero + write_taskfile suppresses stub (ac2, ac3; ac1 core)

**Files:**
- `src/mship/core/init.py` (`TASKFILE_TEMPLATE`, new `TaskfileWriteResult`, `write_taskfile`, import `resolve_go_task_files`)
- `tests/core/test_init.py` (new tests)
- Existing-test audit (must still pass): `test_write_taskfile` (:167), `test_taskfile_template_has_no_colon_in_echo_strings` (:181 — vacuous once no `echo` lines), `test_write_taskfile_does_not_overwrite` (:194 — non-stub existing content still suppresses).

**Step 1 — write failing tests** (append to `tests/core/test_init.py`):
```python
def test_taskfile_template_commands_all_exit_nonzero():
    """ac3: every generated task fails (exit 1) — an unedited stub can NEVER
    fabricate a passing `mship test`; no exit-0 `echo` no-ops remain."""
    tmpl = WorkspaceInitializer.TASKFILE_TEMPLATE
    assert "exit 1" in tmpl
    assert "echo" not in tmpl
    parsed = yaml.safe_load(tmpl)
    for task_name in ("test", "run", "lint", "setup"):
        assert parsed["tasks"][task_name]["cmds"] == ["exit 1"], task_name


@pytest.mark.parametrize("fname", [
    "Taskfile.yml", "Taskfile.yaml", "taskfile.yml", "taskfile.yaml",
    "Taskfile.dist.yml", "Taskfile.dist.yaml", "taskfile.dist.yml", "taskfile.dist.yaml",
])
def test_write_taskfile_suppressed_by_existing_go_task_file(tmp_path: Path, fname: str):
    """ac1/ac2: an existing go-task file (any resolution-set spelling) suppresses
    the stub; NO shadowing Taskfile.yml is written; result reports the existing file."""
    repo = tmp_path / "svc"; repo.mkdir()
    (repo / fname).write_text("version: '3'\ntasks: {}\n")
    result = WorkspaceInitializer().write_taskfile(repo)
    assert result.wrote is False
    assert result.existing is not None and result.existing.name == fname
    if fname != "Taskfile.yml":
        assert not (repo / "Taskfile.yml").exists()   # no shadow stub written
        assert result.needs_rename is True


def test_write_taskfile_writes_when_absent(tmp_path: Path):
    repo = tmp_path / "svc"; repo.mkdir()
    result = WorkspaceInitializer().write_taskfile(repo)
    assert result.wrote is True
    assert (repo / "Taskfile.yml").exists()
    assert result.needs_rename is False
```

**Step 2 — run to fail:**
```
uv run pytest "tests/core/test_init.py::test_taskfile_template_commands_all_exit_nonzero" "tests/core/test_init.py::test_write_taskfile_suppressed_by_existing_go_task_file" -v
```
Expected: template test FAILS (`echo` present / cmds != `["exit 1"]`); suppression test FAILS for `.yaml` spellings (shadow `Taskfile.yml` written) and `AttributeError` on `result.wrote` (returns `None`).

**Step 3 — implement.** In `src/mship/core/init.py`: extend the import — `from mship.core.config import RepoConfig, WorkspaceConfig, resolve_go_task_files`. Add near `DetectedRepo`:
```python
@dataclass(frozen=True)
class TaskfileWriteResult:
    """Outcome of WorkspaceInitializer.write_taskfile.

    - wrote:    a fresh Taskfile.yml stub was written (dir had no go-task file).
    - existing: the go-task file that suppressed the stub (None when wrote)."""
    wrote: bool
    existing: Path | None = None

    @property
    def needs_rename(self) -> bool:
        """True when the existing go-task file is a non-`Taskfile.yml` spelling
        that go-task resolves but mship's stub-based tooling keys off `.yml`."""
        return self.existing is not None and self.existing.name != "Taskfile.yml"
```
Replace `TASKFILE_TEMPLATE` (:71-94):
```python
    TASKFILE_TEMPLATE = """\
version: '3'

# Starter stub generated by `mship init`. Every task FAILS on purpose (exit 1)
# so an unedited stub can never fabricate a passing `mship test`. Replace each
# `exit 1` with the real command for this repo. See issue 366 finding 1.
tasks:
  test:
    desc: Run tests (stub - replace exit 1 with your test command)
    cmds:
      - exit 1

  run:
    desc: Start the service (stub - replace exit 1 with your run command)
    cmds:
      - exit 1

  lint:
    desc: Run linter (stub - replace exit 1 with your lint command)
    cmds:
      - exit 1

  setup:
    desc: Set up development environment (stub - replace exit 1 with your setup command)
    cmds:
      - exit 1
"""
```
Replace `write_taskfile` (:146-151):
```python
    def write_taskfile(self, repo_path: Path) -> TaskfileWriteResult:
        """Write a starter Taskfile.yml only when NO go-task file already resolves
        in `repo_path`. Returns a result describing what happened so callers can
        offer a rename for a non-`.yml` spelling instead of shadowing it with a
        generated `Taskfile.yml` stub. See issue #366 finding #1."""
        existing = resolve_go_task_files(repo_path)
        if existing:
            return TaskfileWriteResult(wrote=False, existing=existing[0])
        (repo_path / "Taskfile.yml").write_text(self.TASKFILE_TEMPLATE)
        return TaskfileWriteResult(wrote=True, existing=None)
```

**Step 4 — run to pass** (include the three existing tests to prove no regression):
```
uv run pytest tests/core/test_init.py -v
```

**Step 5 — commit:** `git -C $WT add src/mship/core/init.py tests/core/test_init.py` — msg `#366 #1: stub Taskfile exits non-zero; write_taskfile suppresses any existing go-task file`.
<!-- /mship:task -->

---

<!-- mship:task id=4 -->
## Task 4 — detect_repos ignores a lone generated-stub Taskfile (ac6)

**Files:**
- `src/mship/core/init.py` (`_find_markers`, add `_is_generated_stub`)
- `tests/core/test_init.py` (new tests)
- Existing-test audit: `test_detect_repos` (:40) uses a hand-written `Taskfile.yml` in `shared` (`"version: '3'"`, ≠ stub) → still detected; other markers unaffected.

**Step 1 — write failing tests** (append to `tests/core/test_init.py`):
```python
def test_detect_ignores_lone_generated_stub_taskfile(tmp_path: Path):
    """ac6: a dir whose ONLY marker is a mship-generated stub Taskfile is NOT
    promoted (so re-running `init --detect` ignores mship's own stubs)."""
    init = WorkspaceInitializer()
    stub_dir = tmp_path / "stubonly"; stub_dir.mkdir()
    (stub_dir / "Taskfile.yml").write_text(init.TASKFILE_TEMPLATE)
    assert "stubonly" not in [r.path.name for r in init.detect_repos(tmp_path)]


def test_detect_keeps_handwritten_taskfile(tmp_path: Path):
    init = WorkspaceInitializer()
    real = tmp_path / "realsvc"; real.mkdir()
    (real / "Taskfile.yml").write_text(
        "version: '3'\ntasks:\n  test:\n    cmds:\n      - pytest\n"
    )
    repos = init.detect_repos(tmp_path)
    svc = next(r for r in repos if r.path.name == "realsvc")
    assert "Taskfile.yml" in svc.markers


def test_detect_stub_dir_with_other_marker_still_promoted(tmp_path: Path):
    """A stub Taskfile PLUS a real marker (.git) is still a repo — only a LONE
    stub is ignored, and the stub itself is not counted among the markers."""
    init = WorkspaceInitializer()
    d = tmp_path / "svc"; d.mkdir()
    (d / ".git").mkdir()
    (d / "Taskfile.yml").write_text(init.TASKFILE_TEMPLATE)
    svc = next(r for r in init.detect_repos(tmp_path) if r.path.name == "svc")
    assert ".git" in svc.markers
    assert "Taskfile.yml" not in svc.markers
```

**Step 2 — run to fail:**
```
uv run pytest "tests/core/test_init.py::test_detect_ignores_lone_generated_stub_taskfile" "tests/core/test_init.py::test_detect_stub_dir_with_other_marker_still_promoted" -v
```
Expected: FAIL (stub Taskfile counts as a marker → `stubonly` promoted; stub listed in `svc.markers`).

**Step 3 — implement.** Replace `_find_markers` (:64-69) and add a helper:
```python
    def _find_markers(self, path: Path) -> list[str]:
        markers: list[str] = []
        for marker in REPO_MARKERS:
            target = path / marker
            if not target.exists():
                continue
            if marker == "Taskfile.yml" and self._is_generated_stub(target):
                # A dir whose only marker is mship's OWN generated stub Taskfile
                # must not be re-promoted to a repo on a later `init --detect`.
                # Match by content (not filename) so a hand-written Taskfile.yml
                # still counts. See issue #366 finding #1.
                continue
            markers.append(marker)
        return markers

    def _is_generated_stub(self, taskfile: Path) -> bool:
        try:
            return taskfile.read_text() == self.TASKFILE_TEMPLATE
        except OSError:
            return False
```

**Step 4 — run to pass:**
```
uv run pytest tests/core/test_init.py -v
```

**Step 5 — commit:** `git -C $WT add src/mship/core/init.py tests/core/test_init.py` — msg `#366 #1: detect_repos ignores lone mship-generated stub Taskfile`.
<!-- /mship:task -->

---

<!-- mship:task id=5 -->
## Task 5 — worktree silent main-checkout fallback becomes a raise (ac12)

**Files:**
- `src/mship/core/worktree.py` (`:555-561`, the git_root child branch)
- `tests/core/test_worktree.py` (new test; imports already present at top)

**Step 1 — write failing test** (append to `tests/core/test_worktree.py`):
```python
def test_spawn_git_root_parent_unmaterialized_raises(tmp_path: Path, monkeypatch):
    """ac12: if a git_root parent is absent from the materialized worktrees map,
    spawn RAISES naming child+parent instead of falling back to the source
    checkout (worktree.py:557-559)."""
    root = tmp_path / "monorepo"; root.mkdir()
    (root / "Taskfile.yml").write_text("version: '3'")
    web = root / "web"; web.mkdir()
    (web / "Taskfile.yml").write_text("version: '3'")
    git_env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t.com",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t.com"}
    subprocess.run(["git", "init", "-b", "main", str(root)], check=True, capture_output=True)
    subprocess.run(["git", "add", "."], cwd=root, check=True, capture_output=True, env=git_env)
    subprocess.run(["git", "commit", "-m", "init"], cwd=root, check=True, capture_output=True, env=git_env)

    cfg = tmp_path / "mothership.yaml"
    cfg.write_text(
        "workspace: mono\nrepos:\n"
        "  root:\n    path: ./monorepo\n    type: service\n    base_branch: main\n"
        "  web:\n    path: web\n    type: service\n    git_root: root\n    base_branch: main\n"
    )
    config = ConfigLoader.load(cfg)
    graph = DependencyGraph(config)
    # Simulate the pre-fix world where the parent is never pulled in: disable the
    # implicit git_root edge so passive expansion cannot materialize `root`.
    monkeypatch.setattr(graph, "direct_deps", lambda name: [])
    state_dir = tmp_path / ".mothership"; state_dir.mkdir()
    state_mgr = StateManager(state_dir)
    shell = MagicMock(spec=ShellRunner)
    shell.run_task.return_value = ShellResult(returncode=0, stdout="ok", stderr="")
    mgr = WorktreeManager(config, graph, state_mgr, GitRunner(), shell, MagicMock(spec=LogManager))

    with pytest.raises(ValueError) as exc:
        mgr.spawn("child only", repos=["web"], workspace_root=tmp_path, offline=True)
    msg = str(exc.value)
    assert "web" in msg and "root" in msg
    assert "checkout" in msg.lower()
```

**Step 2 — run to fail:**
```
uv run pytest "tests/core/test_worktree.py::test_spawn_git_root_parent_unmaterialized_raises" -v
```
Expected: FAIL — spawn currently falls back to the source checkout and does NOT raise (the test's `pytest.raises` is unmet; `web` lands under the source `monorepo/web`).

**Step 3 — implement.** In `worktree.py`, replace `:557-559`:
```python
                parent_wt = worktrees.get(repo_config.git_root)
                if parent_wt is None:
                    raise ValueError(
                        f"git_root parent '{repo_config.git_root}' of repo "
                        f"'{repo_name}' was not materialized in this spawn — "
                        f"refusing to nest the child under the source checkout "
                        f"({self._config.repos[repo_config.git_root].path}). "
                        f"Include '{repo_config.git_root}' in the spawn scope, or "
                        f"keep it reachable as a git_root/depends_on parent so it "
                        f"is created first."
                    )
```
(Leave the following `effective = parent_wt / repo_config.path` line intact.)

**Step 4 — run to pass:**
```
uv run pytest "tests/core/test_worktree.py::test_spawn_git_root_parent_unmaterialized_raises" -v
```

**Step 5 — commit:** `git -C $WT add src/mship/core/worktree.py tests/core/test_worktree.py` — msg `#366 #3: worktree git_root fallback raises instead of nesting into source checkout`.
<!-- /mship:task -->

---

<!-- mship:task id=6 -->
## Task 6 — implicit git_root ordering edge: graph + spawn (ac10, ac11, ac14)

**Files:**
- `src/mship/core/graph.py` (`DependencyGraph.__init__`)
- `tests/core/test_graph.py` (unit: ac10)
- `tests/core/test_worktree.py` (integration: ac11/ac14)

Sequenced after Task 5 so the pre-implementation integration failure is the clean `raise`, and the edge then materializes the parent properly. The edge is the single fix that satisfies ac10 (graph) and ac11/ac14 (spawn nests under `.worktrees/`, never the source checkout).

**Step 1 — write failing tests.** Append to `tests/core/test_graph.py`:
```python
def _write_monorepo_cfg(tmp_path: Path, child_extra: str = "") -> Path:
    root = tmp_path / "mono"; root.mkdir()
    (root / "Taskfile.yml").write_text("version: '3'")
    web = root / "web"; web.mkdir()
    (web / "Taskfile.yml").write_text("version: '3'")
    cfg = tmp_path / "mothership.yaml"
    cfg.write_text(
        "workspace: mono\nrepos:\n"
        "  mono:\n    path: ./mono\n    type: service\n"
        f"  web:\n    path: web\n    type: service\n    git_root: mono\n{child_extra}"
    )
    return cfg


def test_git_root_adds_implicit_ordering_edge(tmp_path: Path):
    """ac10: a git_root child with NO explicit depends_on still gets an implicit
    parent->child edge: topo_sort emits parent first; direct_deps includes it."""
    config = ConfigLoader.load(_write_monorepo_cfg(tmp_path))
    graph = DependencyGraph(config)
    order = graph.topo_sort()
    assert order.index("mono") < order.index("web")
    assert "mono" in graph.direct_deps("web")


def test_git_root_edge_deduped_when_also_depends_on(tmp_path: Path):
    """ac10: when the parent is ALSO an explicit depends_on target, the edge is
    not duplicated."""
    config = ConfigLoader.load(_write_monorepo_cfg(tmp_path, "    depends_on: [mono]\n"))
    graph = DependencyGraph(config)
    assert graph.direct_deps("web").count("mono") == 1
    assert graph.topo_sort().index("mono") < graph.topo_sort().index("web")
```
Append to `tests/core/test_worktree.py`:
```python
def test_spawn_only_git_root_child_materializes_parent(tmp_path: Path):
    """ac11/ac14: spawning ONLY a git_root child (no depends_on to its parent)
    materializes the parent so the child nests under .worktrees/<slug>/<parent>/,
    NEVER the source checkout."""
    root = tmp_path / "monorepo"; root.mkdir()
    (root / "Taskfile.yml").write_text("version: '3'")
    web = root / "web"; web.mkdir()
    (web / "Taskfile.yml").write_text("version: '3'")
    git_env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t.com",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t.com"}
    subprocess.run(["git", "init", "-b", "main", str(root)], check=True, capture_output=True)
    subprocess.run(["git", "add", "."], cwd=root, check=True, capture_output=True, env=git_env)
    subprocess.run(["git", "commit", "-m", "init"], cwd=root, check=True, capture_output=True, env=git_env)

    cfg = tmp_path / "mothership.yaml"
    cfg.write_text(
        "workspace: mono\nrepos:\n"
        "  root:\n    path: ./monorepo\n    type: service\n    base_branch: main\n"
        "  web:\n    path: web\n    type: service\n    git_root: root\n    base_branch: main\n"
    )
    config = ConfigLoader.load(cfg)
    graph = DependencyGraph(config)
    state_dir = tmp_path / ".mothership"; state_dir.mkdir()
    state_mgr = StateManager(state_dir)
    shell = MagicMock(spec=ShellRunner)
    shell.run_task.return_value = ShellResult(returncode=0, stdout="ok", stderr="")
    mgr = WorktreeManager(config, graph, state_mgr, GitRunner(), shell, MagicMock(spec=LogManager))

    mgr.spawn("child only", repos=["web"], workspace_root=tmp_path, offline=True)

    task = state_mgr.load().tasks["child-only"]
    assert "root" in task.worktrees            # parent pulled in via implicit edge
    root_wt = Path(task.worktrees["root"])
    assert root_wt == tmp_path / ".worktrees" / "child-only" / "root"
    web_wt = Path(task.worktrees["web"])
    assert web_wt == root_wt / "web"
    assert (tmp_path / ".worktrees" / "child-only") in web_wt.parents
    assert not str(web_wt).startswith(str(root.resolve()))   # NOT the source checkout
```

**Step 2 — run to fail:**
```
uv run pytest "tests/core/test_graph.py::test_git_root_adds_implicit_ordering_edge" "tests/core/test_worktree.py::test_spawn_only_git_root_child_materializes_parent" -v
```
Expected: graph test FAILS (`direct_deps("web") == []`); spawn test FAILS — `web`'s parent is never materialized, so spawn hits the Task-5 `raise` (`"root" ... was not materialized`).

**Step 3 — implement.** In `graph.py`, at the end of `DependencyGraph.__init__` (after the `depends_on` loop, :12-16):
```python
        # git_root implies an ordering edge: a subdirectory child nests inside its
        # parent's worktree, so the parent must be materialized first. Add a
        # parent->child edge (deduped against an explicit depends_on) so topo_sort
        # emits the parent first and direct_deps(child) includes it — this is what
        # pulls a git_root parent into passive worktree expansion even when the
        # child never declared depends_on. See issue #366 finding #3.
        for name, repo in config.repos.items():
            parent = repo.git_root
            if parent is None or parent not in self._forward:
                continue
            if name not in self._forward[parent]:
                self._forward[parent].append(name)
            if parent not in self._reverse[name]:
                self._reverse[name].append(parent)
```

**Step 4 — run to pass:**
```
uv run pytest "tests/core/test_graph.py::test_git_root_adds_implicit_ordering_edge" "tests/core/test_graph.py::test_git_root_edge_deduped_when_also_depends_on" "tests/core/test_worktree.py::test_spawn_only_git_root_child_materializes_parent" tests/core/test_graph.py -v
```
(Run the whole `test_graph.py` to confirm existing topo/tiers tests are unaffected — the fixture configs have no `git_root`, so the edge loop is a no-op there.)

**Step 5 — commit:** `git -C $WT add src/mship/core/graph.py tests/core/test_graph.py tests/core/test_worktree.py` — msg `#366 #3: git_root as implicit ordering edge; passive expansion materializes parent`.
<!-- /mship:task -->

---

<!-- mship:task id=7 -->
## Task 7 — validate_no_cycles folds in the git_root edge (ac13)

**Files:**
- `src/mship/core/config.py` (`validate_no_cycles`, :391-413)
- `tests/core/test_config.py` (new tests)

`DependencyGraph` (Task 6) is not consulted at load; `validate_no_cycles` must independently fold in the git_root edge so an opposite-direction `parent depends_on child` is rejected as a cycle rather than silently ordered wrong.

**Step 1 — write failing tests** (append to `tests/core/test_config.py`):
```python
def test_git_root_opposite_direction_depends_on_rejected_as_cycle(tmp_path: Path):
    """ac13: a parent that `depends_on` its own git_root child forms a cycle once
    the implicit git_root ordering edge is folded in — rejected at load."""
    root = tmp_path / "mono"; root.mkdir()
    (root / "Taskfile.yml").write_text("version: '3'")
    web = root / "web"; web.mkdir()
    (web / "Taskfile.yml").write_text("version: '3'")
    cfg = tmp_path / "mothership.yaml"
    cfg.write_text(
        "workspace: mono\nrepos:\n"
        "  mono:\n    path: ./mono\n    type: service\n    depends_on: [web]\n"
        "  web:\n    path: web\n    type: service\n    git_root: mono\n"
    )
    with pytest.raises(ValueError, match="[Cc]ircular"):
        ConfigLoader.load(cfg)


def test_git_root_child_depends_on_parent_still_loads(tmp_path: Path):
    """Same-direction (child depends_on parent) is NOT a cycle — no regression."""
    root = tmp_path / "mono"; root.mkdir()
    (root / "Taskfile.yml").write_text("version: '3'")
    web = root / "web"; web.mkdir()
    (web / "Taskfile.yml").write_text("version: '3'")
    cfg = tmp_path / "mothership.yaml"
    cfg.write_text(
        "workspace: mono\nrepos:\n"
        "  mono:\n    path: ./mono\n    type: service\n"
        "  web:\n    path: web\n    type: service\n    git_root: mono\n    depends_on: [mono]\n"
    )
    assert ConfigLoader.load(cfg).repos["web"].git_root == "mono"
```

**Step 2 — run to fail:**
```
uv run pytest "tests/core/test_config.py::test_git_root_opposite_direction_depends_on_rejected_as_cycle" -v
```
Expected: FAIL — the opposite-direction config currently loads (no cycle in `depends_on` alone).

**Step 3 — implement.** In `validate_no_cycles`, after the `depends_on` adjacency build (after :399, before the `queue = ...` at :401):
```python
        # git_root is an implicit parent->child ordering edge (mirrors
        # DependencyGraph + worktree passive expansion). Fold it into cycle
        # detection so an opposite-direction `parent depends_on child` is rejected
        # as the cycle it is, instead of being silently resolved wrong-way. See
        # issue #366 finding #3 / ac13. (git_root ref validity is checked later by
        # validate_git_root_refs; guard against unknown parents here.)
        for name, repo in self.repos.items():
            parent = repo.git_root
            if parent is None or parent not in in_degree:
                continue
            if any(dep.repo == parent for dep in repo.depends_on):
                continue  # already counted as an explicit depends_on edge
            adjacency[parent].append(name)
            in_degree[name] += 1
```

**Step 4 — run to pass:**
```
uv run pytest "tests/core/test_config.py::test_git_root_opposite_direction_depends_on_rejected_as_cycle" "tests/core/test_config.py::test_git_root_child_depends_on_parent_still_loads" tests/core/test_config.py -v
```
(Run the full `test_config.py` — existing `test_git_root_with_subdir` etc. use same-direction/no `depends_on` and must still load.)

**Step 5 — commit:** `git -C $WT add src/mship/core/config.py tests/core/test_config.py` — msg `#366 #3: fold git_root ordering edge into validate_no_cycles (ac13)`.
<!-- /mship:task -->

---

<!-- mship:task id=8 -->
## Task 8 — CLI init surfaces the rename offer + guards the full resolution set (ac1 complete)

**Files:**
- `src/mship/cli/init.py` (batch scaffold block :129-157; interactive block :268-280; import `resolve_go_task_files`)
- `tests/test_init_integration.py` (new CLI test)

Completes ac1's operator-facing half (Task 3 supplied the core `write_taskfile` result). Also fixes the batch path's `created_taskfiles` bookkeeping, which currently appends unconditionally even when the stub was suppressed.

**Step 1 — write failing test** (append to `tests/test_init_integration.py`):
```python
def test_init_scaffold_does_not_shadow_existing_taskfile_yaml(tmp_path: Path, monkeypatch):
    """ac1: `mship init --scaffold-taskfiles` against a repo that has only
    `Taskfile.yaml` writes NO shadowing `Taskfile.yml` and reports a rename offer."""
    svc = tmp_path / "svc"; svc.mkdir()
    (svc / ".git").mkdir()
    (svc / "Taskfile.yaml").write_text(
        "version: '3'\ntasks:\n  test:\n    cmds:\n      - echo ok\n"
    )
    monkeypatch.chdir(tmp_path)
    result = runner.invoke(app, [
        "init", "--name", "t", "--repo", "./svc:service", "--scaffold-taskfiles",
    ])
    assert result.exit_code == 0, result.output
    assert not (svc / "Taskfile.yml").exists()          # no shadow stub
    assert "Taskfile.yaml" in result.output             # the existing file is named
    assert "rename" in result.output.lower()            # rename is offered
```
(The JSON payload's `taskfile_rename_suggested` key carries both substrings on stdout, so the assertion holds under CliRunner's non-TTY/JSON mode.)

**Step 2 — run to fail:**
```
uv run pytest "tests/test_init_integration.py::test_init_scaffold_does_not_shadow_existing_taskfile_yaml" -v
```
Expected: FAIL — no "rename"/"Taskfile.yaml" text in output (CLI does not yet surface it).

**Step 3 — implement.** In `src/mship/cli/init.py` add to the import: `from mship.core.config import unique_git_roots, resolve_go_task_files`. Replace the batch scaffold block (:130-136):
```python
        created_taskfiles: list[str] = []
        rename_notes: list[tuple[str, Path]] = []
        if scaffold_taskfiles:
            for rd in repos_data:
                repo_path = Path(rd["path"])
                result = initializer.write_taskfile(repo_path)
                if result.wrote:
                    created_taskfiles.append(str(repo_path))
                elif result.needs_rename and result.existing is not None:
                    rename_notes.append((str(repo_path), result.existing))
```
Replace the reporting block (:148-157):
```python
        if output.human_mode:
            output.success(f"Created: {config_path}")
            for tf in created_taskfiles:
                output.success(f"Created: {tf}/Taskfile.yml")
            for repo_dir, existing in rename_notes:
                output.warning(
                    f"{repo_dir}: found existing go-task file {existing.name} — "
                    f"mship left it untouched (no shadowing Taskfile.yml written). "
                    f"Rename it to Taskfile.yml so go-task and mship resolve the "
                    f"same file."
                )
            output.print("\nRun `mship status` to verify your workspace.")
        else:
            output.json({
                "config": str(config_path),
                "taskfiles_created": created_taskfiles,
                "taskfile_rename_suggested": [
                    {"repo_dir": d, "existing": str(p)} for d, p in rename_notes
                ],
            })
```
Replace the interactive scaffold block (:269-279):
```python
    created_taskfiles: list[str] = []
    for rd in repos_data:
        repo_path = Path(rd["path"])
        existing = resolve_go_task_files(repo_path)
        if existing:
            note = f'"{rd["name"]}" already has {existing[0].name}'
            if existing[0].name != "Taskfile.yml":
                note += " — rename it to Taskfile.yml so go-task and mship resolve the same file"
            output.print(note)
            continue
        scaffold = inquirer.confirm(
            message=f'"{rd["name"]}" has no go-task file. Create a starter Taskfile.yml?',
            default=True,
        ).execute()
        if scaffold:
            result = initializer.write_taskfile(repo_path)
            if result.wrote:
                created_taskfiles.append(rd["name"])
```

**Step 4 — run to pass:**
```
uv run pytest "tests/test_init_integration.py::test_init_scaffold_does_not_shadow_existing_taskfile_yaml" tests/test_init_integration.py -v
```

**Step 5 — commit:** `git -C $WT add src/mship/cli/init.py tests/test_init_integration.py` — msg `#366 #1: init offers rename instead of shadowing an existing go-task file (ac1)`.
<!-- /mship:task -->

---

<!-- mship:task id=9 -->
## Task 9 — doctor warns on >1 go-task file; accepts any spelling (ac5)

**Files:**
- `src/mship/core/doctor.py` (Taskfile check :161-165; import `resolve_go_task_files`, `GO_TASK_FILENAMES`)
- `tests/core/test_doctor.py` (new tests)
- Existing-test audit: `test_doctor_resolves_git_root_subdir_paths` (:218-219) asserts only `web/taskfile` status `== "pass"` (message not asserted) → the single-file pass path keeps status `pass`.

**Step 1 — write failing tests** (append to `tests/core/test_doctor.py`):
```python
def _doctor_shell():
    s = MagicMock(spec=ShellRunner)
    s.run.side_effect = lambda cmd, cwd, env=None: (
        ShellResult(returncode=0, stdout="test\nrun\nlint\nsetup\n", stderr="")
        if "task --list" in cmd else ShellResult(returncode=0, stdout="", stderr="")
    )
    return s


def test_doctor_warns_on_multiple_go_task_files(tmp_path: Path):
    """ac5: >1 go-task file resolving in a repo dir → a warning naming them."""
    repo = tmp_path / "svc"; repo.mkdir()
    (repo / "Taskfile.yml").write_text("version: '3'\ntasks: {}\n")
    (repo / "Taskfile.yaml").write_text("version: '3'\ntasks: {}\n")
    cfg = tmp_path / "mothership.yaml"
    cfg.write_text("workspace: t\nrepos:\n  svc:\n    path: ./svc\n    type: service\n")
    report = DoctorChecker(ConfigLoader.load(cfg), _doctor_shell()).run()
    tf = next(c for c in report.checks if c.name == "svc/taskfile")
    assert tf.status == "warn"
    assert "Taskfile.yml" in tf.message and "Taskfile.yaml" in tf.message


def test_doctor_accepts_taskfile_yaml_only(tmp_path: Path):
    """A repo with only Taskfile.yaml passes the presence check (not fail)."""
    repo = tmp_path / "svc"; repo.mkdir()
    (repo / "Taskfile.yaml").write_text("version: '3'\ntasks: {}\n")
    cfg = tmp_path / "mothership.yaml"
    cfg.write_text("workspace: t\nrepos:\n  svc:\n    path: ./svc\n    type: service\n")
    report = DoctorChecker(ConfigLoader.load(cfg), _doctor_shell()).run()
    tf = next(c for c in report.checks if c.name == "svc/taskfile")
    assert tf.status == "pass"
    assert "Taskfile.yaml" in tf.message
```

**Step 2 — run to fail:**
```
uv run pytest "tests/core/test_doctor.py::test_doctor_warns_on_multiple_go_task_files" "tests/core/test_doctor.py::test_doctor_accepts_taskfile_yaml_only" -v
```
Expected: warn test FAILS (current check passes when `Taskfile.yml` present); yaml-only test FAILS (current check reports `fail`, "Taskfile.yml not found").

**Step 3 — implement.** In `doctor.py` extend the import: `from mship.core.config import WorkspaceConfig, resolve_go_task_files, GO_TASK_FILENAMES`. Replace the Taskfile block (:161-165):
```python
            # go-task file(s) — accept any resolution-set spelling; warn when more
            # than one resolves (go-task picks by precedence, so mship must not
            # silently key off a different file than the one `task` runs). #366 #1.
            go_task_files = resolve_go_task_files(effective_path)
            if not go_task_files:
                report.checks.append(CheckResult(
                    name=f"{name}/taskfile", status="fail",
                    message=f"no go-task file found (looked for one of: {', '.join(GO_TASK_FILENAMES)})",
                ))
            elif len(go_task_files) > 1:
                listed = ", ".join(f.name for f in go_task_files)
                report.checks.append(CheckResult(
                    name=f"{name}/taskfile", status="warn",
                    message=(
                        f"multiple go-task files resolve in {effective_path}: {listed} "
                        f"— go-task runs '{go_task_files[0].name}' by precedence; remove "
                        f"or rename the others so mship and go-task agree"
                    ),
                ))
            else:
                report.checks.append(CheckResult(
                    name=f"{name}/taskfile", status="pass",
                    message=f"{go_task_files[0].name} found",
                ))
```

**Step 4 — run to pass:**
```
uv run pytest "tests/core/test_doctor.py::test_doctor_warns_on_multiple_go_task_files" "tests/core/test_doctor.py::test_doctor_accepts_taskfile_yaml_only" tests/core/test_doctor.py -v
```

**Step 5 — commit:** `git -C $WT add src/mship/core/doctor.py tests/core/test_doctor.py` — msg `#366 #1: doctor warns on ambiguous go-task files; accepts any spelling (ac5)`.
<!-- /mship:task -->

---

<!-- mship:task id=10 -->
## Task 10 — Document git_root relative-path + auto-ordering rules (ac15)

**Files:**
- `docs/configuration.md` (Monorepo section :40-61)
- `tests/test_docs_config_workflow.py` (new content test)

**Step 1 — write failing test** (append to `tests/test_docs_config_workflow.py`):
```python
CONFIGURATION = Path(__file__).resolve().parent.parent / "docs" / "configuration.md"


def test_configuration_documents_git_root_relative_and_autoorder():
    """ac15: docs state git_root children need relative paths and that git_root
    parents are auto-ordered before their children (no hand-added depends_on)."""
    t = CONFIGURATION.read_text().lower()
    assert "relative" in t
    assert "absolute" in t          # the constraint (no absolute child paths) is stated
    assert "auto" in t and "order" in t   # auto-ordered before children
```

**Step 2 — run to fail:**
```
uv run pytest "tests/test_docs_config_workflow.py::test_configuration_documents_git_root_relative_and_autoorder" -v
```
Expected: FAIL (the current "Rules" list does not mention absolute-path rejection or auto-ordering).

**Step 3 — implement.** In `docs/configuration.md`, update the example (drop the now-unnecessary `depends_on`, keep the relative-path comment) and extend the Rules list (:56-60):
````markdown
```yaml
repos:
  backend:
    path: .
    type: service
  web:
    path: web              # relative — required; interpreted against backend's worktree
    type: service
    git_root: backend      # backend is auto-ordered before web (no depends_on needed)
```

Rules:
- `git_root` must reference another repo in the workspace.
- The referenced repo cannot itself have `git_root` set (no chaining).
- A `git_root` child's `path` **must be relative** and must not contain `..`; an
  absolute path would resolve to the source checkout instead of the task worktree
  and is rejected at config load.
- A `git_root` parent is **auto-ordered before its children** — it is materialized
  first automatically, so you do NOT need to hand-add `depends_on: [parent]`.
  (Declaring `parent depends_on child` is the opposite order and is rejected as a
  dependency cycle.)
- The subdirectory must exist and contain a go-task file (`Taskfile.yml`,
  `Taskfile.yaml`, or another resolution-set spelling).
- Subdirectory services still have their own `depends_on`, `tags`, `tasks`, and `start_mode`.
````

**Step 4 — run to pass:**
```
uv run pytest "tests/test_docs_config_workflow.py::test_configuration_documents_git_root_relative_and_autoorder" tests/test_docs_config_workflow.py -v
```

**Step 5 — commit:** `git -C $WT add docs/configuration.md tests/test_docs_config_workflow.py` — msg `#366: document git_root relative-path + auto-ordering rules (ac15)`.
<!-- /mship:task -->

---

<!-- mship:task id=11 -->
## Task 11 — Regression pass (whole suite)

**Files:** none (verification + any fallout fixes only). The `graph.py` implicit-edge and `config.py` cycle changes are global — verify every `DependencyGraph`/`validate_no_cycles` consumer (executor, serve/remote-exec, phase, finish, doctor). `tests/core/test_serve_exec.py:369-460` already has "git_root child materializes parent first" tests — confirm they still pass with the new edge.

**Step 1 — run the full suite** (cwd `$WT`):
```
uv run pytest -q
```

**Step 2 — triage.** For each failure: is it (a) an intended behavior change the spec's Risks call out (a config that relied on the silent fallback / absolute git_root child / opposite-direction `depends_on` / echo-stub false-green now fails loud) → update that test to assert the new fail-loud behavior; or (b) a genuine regression → fix the source. Do NOT weaken a fail-loud assertion to make a test pass. Re-run the affected node until green, then re-run `uv run pytest -q`.

**Step 3 — targeted confirm** of the cross-cutting suites:
```
uv run pytest tests/core/test_graph.py tests/core/test_config.py tests/core/test_worktree.py tests/core/test_serve_exec.py tests/core/test_doctor.py tests/core/test_context.py tests/core/test_init.py tests/test_monorepo_integration.py tests/test_init_integration.py -q
```

**Step 4 — commit** only if fallout fixes were made: `git -C $WT add <changed>` — msg `#366: regression pass — align tests with fail-loud behavior`. If the suite was already green, skip the commit and journal `regression pass green`.
<!-- /mship:task -->

---

## Self-Review

### AC → Task map (all 15)
| AC | Task(s) | Kind |
| --- | --- | --- |
| ac1 (no shadow stub; report + offer rename) | 3 (core: suppress + result) + 8 (CLI: offer) | change |
| ac2 (suppress for full resolution set) | 2 (helper) + 3 (write_taskfile) | change |
| ac3 (template commands exit non-zero) | 3 | change |
| ac4 (ConfigLoader accepts `.yaml` etc.) | 2 | change |
| ac5 (doctor warns on >1 go-task file) | 9 | change |
| ac6 (detect ignores lone generated stub) | 4 | change |
| ac7 (RepoConfig rejects absolute git_root child path) | 1 | change |
| ac8 (RepoConfig rejects `..` git_root child path) | 1 | change |
| ac9 (relative git_root child still nests) | 1 | assert-only (already-correct; regression guard) |
| ac10 (implicit git_root graph edge) | 6 | change |
| ac11 (spawn only child materializes parent under `.worktrees`) | 6 | change (satisfied by the edge; proven by spawn integration test) |
| ac12 (unmaterialized parent → raise) | 5 | change |
| ac13 (opposite-direction rejected as cycle) | 7 | change |
| ac14 (no silent main-checkout substitution) | 5 (raise) + 6 (nest) | change (asserted in the Task-6 spawn test + Task-5 raise test) |
| ac15 (schema/docs) | 10 | change (docs) |

Every AC maps to at least one task; ac9 is the only pure assert-only (the existing `(parent.path / child.path).resolve()` already keeps a relative child nested — we add a regression guard rather than new code).

### Placeholder / completeness scan
No `TODO`/`...`/`pass`-stub left in production code. The only literal `TODO` text is inside `TASKFILE_TEMPLATE`'s `desc:` strings (intentional, colon-free so it passes the existing `test_taskfile_template_has_no_colon_in_echo_strings`), and its `cmds` are `exit 1` (no `echo`). Every task ships complete failing-test code, complete implementation code, run-to-fail + run-to-pass commands, and a commit.

### Type consistency
- `resolve_go_task_files(directory: Path) -> list[Path]`; `GO_TASK_FILENAMES: tuple[str, ...]`. Defined once in `config.py`, imported by `init.py`, `doctor.py`, `cli/init.py` — no import cycle (all already depend on `config`).
- `write_taskfile` return type changes `None → TaskfileWriteResult`. Callers: `cli/init.py` (updated in Task 8 to consume `.wrote`/`.needs_rename`/`.existing`); the three existing `test_init.py` tests ignore the return (still valid). No other `write_taskfile` caller exists in `src/`.
- **RepoConfig validator fires at construction across ALL `RepoConfig(...)` sites** (audited via `grep -rEn "RepoConfig\((?:...)*git_root"`): `src/mship/core/init.py:105` (no `git_root`, unaffected); `tests/core/test_serve_exec.py:134` (`Path("server")`, relative); `tests/cli/test_finish_groups.py` (`Path(".")`/`Path("web")`, relative — `Path(".").parts == ()`, so no `..`, not absolute); **`tests/core/test_context.py:435` used an ABSOLUTE child path and is FIXED in Task 1**. YAML-loaded git_root children in fixtures/tests (`test_config.py`, `test_worktree.py`, `test_doctor.py`, `conftest.workspace_monorepo_app`, `test_monorepo_integration.py`) all use relative `path:` values — unaffected. The validator message names the `path` and `git_root` (the repo *key* is unavailable at `RepoConfig` construction — same limitation as the mirrored `validate_bind_files`, which names the entry, not the repo).
- **Back-compat for existing configs:** top-level (non-git_root) absolute paths remain allowed (explicit non-goal); `ConfigLoader.load`'s in-place `repo.path = resolved` does not re-trigger the validator (no `validate_assignment`); `validate_no_cycles` dedups the git_root edge against an explicit `depends_on`, so today's `git_root` + `depends_on:[parent]` fixtures still load. The behavior changes that can break a previously-loading config are exactly the four the spec's Risks enumerate (absolute/`..` git_root child; opposite-direction `depends_on`; echo-stub false-green; unmaterialized parent) — all intended fail-loud, handled in Task 11's triage rule (assert the new behavior, never weaken it).
