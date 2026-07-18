# mship init --detect Monorepo Emission — Implementation Plan

**REQUIRED SUB-SKILL: test-driven-development** — every task writes a failing pytest first, runs it to confirm failure, implements the minimum to pass, reruns to green, then commits.

**Spec:** `mship-init-detect-monorepo` (approved + dispatched; mothership only)

## Goal
Make `mship init --detect` produce a *working* config for a single-git monorepo: emit the workspace root as `path: .` (no `git_root`), attach markerless subdirs to it via `git_root: <root-name>`, keep genuinely-independent nested repos/submodules standalone, and emit **relative** paths throughout so the config is portable and passes `ConfigLoader.load(require_paths=True)`, `doctor`, and `audit` with zero manual edits.

## Architecture
The schema already supports this shape (`RepoConfig.git_root`, the post-#380 `validate_git_root_child_path` validator, `ConfigLoader.load`'s two-pass `(parent.path / child.path)` resolution, `doctor`'s `git_root`-aware git check at `doctor.py:187-191`, and `audit_repos` grouping via `_git_root_key`/`_git_root_path` at `repo_state.py:157-167`/`396-410`). Detection simply never emits it. The change is:

1. A **pure classifier** `WorkspaceInitializer.plan_detected_repos(workspace_path, detected)` in `core/init.py` that turns `DetectedRepo`s into config-entry dicts with relative paths + `git_root` back-refs. The `.git`-presence signal is already recorded in `DetectedRepo.markers` (`.git` is in `REPO_MARKERS`, and `_find_markers` uses `(path/".git").exists()`, true for both a `.git` directory and a submodule gitlink **file**). **No `DetectedRepo` data-shape change is needed** — `markers` already carries the `.git` signal and `path` already carries enough to relativize against the scan root.
2. Plumb `git_root` through `generate_config` (currently drops it) and `write_config` (currently never serializes it, and always emits `str(repo.path)`).
3. Wire the non-interactive `--detect` branch of `cli/init.py` (lines 108-119, which today emits absolute `path`, `type: service`, no `git_root`) to the classifier, and anchor `--scaffold-taskfiles` writes to `cwd` (paths are now relative).

Scope boundary: the ACs target non-interactive `mship init --detect`. The interactive wizard (`_run_interactive`) is left unchanged (no AC exercises it); reusing `plan_detected_repos` there is a natural follow-up. Single-level detection means the only possible `git_root` parent is the workspace root, so relative-to-root equals relative-to-parent and the no-chaining rule (`config.py:492-498`) holds naturally.

## Tech Stack
Python 3, pydantic v2, PyYAML, typer + `typer.testing.CliRunner`, pytest, `uv run pytest`.

## File Structure

| File | Change |
| --- | --- |
| `src/mship/core/init.py` | `git_root` passthrough in `generate_config`; emit `git_root` in `write_config`; new `plan_detected_repos` classifier |
| `src/mship/cli/init.py` | Wire non-interactive `--detect` to `plan_detected_repos`; anchor scaffold paths to `cwd` |
| `tests/core/test_init.py` | Unit tests for git_root plumbing + `plan_detected_repos` (ac1/ac2/ac3/ac8 + guard) |
| `tests/cli/test_init.py` | CLI `--detect` monorepo emission test (ac1/ac2) |
| `tests/test_init_detect_monorepo.py` (new) | Integration: load / doctor / audit on a real monorepo (ac4/ac5/ac6/ac7) |

Worktree (all commands run from here): `/home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership`

---

<!-- mship:task id=1 -->
## Task 1 — `generate_config` carries `git_root` onto `RepoConfig`

**Files:** `src/mship/core/init.py`, `tests/core/test_init.py`

**Step 1 — failing test.** Append to `tests/core/test_init.py`:
```python
def test_generate_config_passes_git_root(tmp_path: Path):
    """git_root from the repo dict must land on the RepoConfig (init --detect
    monorepo emission). See spec mship-init-detect-monorepo ac1."""
    init = WorkspaceInitializer()
    config = init.generate_config(
        workspace_name="mono",
        repos=[
            {"name": "root", "path": ".", "type": "service", "depends_on": []},
            {"name": "web", "path": "web", "type": "service",
             "git_root": "root", "depends_on": []},
        ],
        env_runner=None,
    )
    assert config.repos["root"].git_root is None
    assert config.repos["web"].git_root == "root"
```

**Step 2 — run to fail:**
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership && uv run pytest tests/core/test_init.py::test_generate_config_passes_git_root -v
```
Expected: fail (`git_root` is `None` because `generate_config` drops it).

**Step 3 — implement.** In `core/init.py`, replace the `RepoConfig(...)` construction inside `generate_config` (currently lines 138-142) so it forwards `git_root`:
```python
        repo_configs: dict[str, RepoConfig] = {}
        for repo in repos:
            repo_configs[repo["name"]] = RepoConfig(
                path=Path(repo["path"]),
                type=repo["type"],
                depends_on=repo.get("depends_on", []),
                git_root=repo.get("git_root"),
            )
```
(`.get("git_root")` defaults to `None`, so existing callers — the interactive path and `_parse_repo_flag` — are unaffected.)

**Step 4 — run to pass:**
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership && uv run pytest tests/core/test_init.py -v
```

**Step 5 — commit:**
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership add -A
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership commit -m "generate_config: forward git_root onto RepoConfig

init --detect monorepo emission needs generate_config to carry the
git_root back-reference. See spec mship-init-detect-monorepo ac1.

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
cd /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership && mship journal "generate_config forwards git_root onto RepoConfig" --task mship-init-detect-monorepo --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=2 -->
## Task 2 — `write_config` serializes `git_root`

**Files:** `src/mship/core/init.py`, `tests/core/test_init.py`

**Step 1 — failing test.** Append to `tests/core/test_init.py`:
```python
def test_write_config_emits_git_root(tmp_path: Path):
    """write_config serializes git_root for subdir children and omits it for
    standalone repos. See spec mship-init-detect-monorepo ac1."""
    init = WorkspaceInitializer()
    config = init.generate_config(
        workspace_name="mono",
        repos=[
            {"name": "root", "path": ".", "type": "service", "depends_on": []},
            {"name": "web", "path": "web", "type": "service",
             "git_root": "root", "depends_on": []},
        ],
        env_runner=None,
    )
    out = tmp_path / "mothership.yaml"
    init.write_config(out, config)
    data = yaml.safe_load(out.read_text())
    assert data["repos"]["web"]["git_root"] == "root"
    assert data["repos"]["web"]["path"] == "web"
    assert data["repos"]["root"]["path"] == "."
    assert "git_root" not in data["repos"]["root"]
```

**Step 2 — run to fail:**
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership && uv run pytest tests/core/test_init.py::test_write_config_emits_git_root -v
```
Expected: fail (`KeyError: 'git_root'` — `write_config` never emits it).

**Step 3 — implement.** In `core/init.py` `write_config`, insert the `git_root` emission between the `type` line and the `depends_on` block (currently after line 164):
```python
            repo_data: dict = {
                "path": str(repo.path),
                "type": repo.type,
            }
            if repo.git_root is not None:
                repo_data["git_root"] = repo.git_root
            if repo.depends_on:
```

**Step 4 — run to pass:**
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership && uv run pytest tests/core/test_init.py -v
```

**Step 5 — commit:**
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership add -A
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership commit -m "write_config: serialize git_root for subdir children

Emit git_root only when set, so standalone repos are unchanged. Enables
the init --detect monorepo shape. See spec mship-init-detect-monorepo ac1.

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
cd /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership && mship journal "write_config serializes git_root" --task mship-init-detect-monorepo --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=3 -->
## Task 3 — `plan_detected_repos`: single-git monorepo emission (ac1/ac2)

**Files:** `src/mship/core/init.py`, `tests/core/test_init.py`

**Step 1 — failing test.** Append to `tests/core/test_init.py`:
```python
def test_plan_detected_repos_single_git_monorepo(tmp_path: Path):
    """ac1/ac2: a single-git monorepo emits the root as `path: .` (no git_root)
    and each markerless subdir as a git_root child with a RELATIVE path; the
    emitted plan builds a valid WorkspaceConfig (git_root refs, no chaining)."""
    (tmp_path / ".git").mkdir()
    (tmp_path / "pyproject.toml").write_text("[project]\nname='root'\n")
    for sub in ("web", "infra"):
        d = tmp_path / sub
        d.mkdir()
        (d / "package.json").write_text("{}")

    init = WorkspaceInitializer()
    detected = init.detect_repos(tmp_path)
    planned = init.plan_detected_repos(tmp_path, detected)
    by_name = {e["name"]: e for e in planned}

    root_name = tmp_path.name
    assert by_name[root_name]["path"] == "."
    assert by_name[root_name]["git_root"] is None
    for sub in ("web", "infra"):
        assert by_name[sub]["path"] == sub
        assert by_name[sub]["git_root"] == root_name

    # ac2: no emitted path is absolute
    for e in planned:
        assert not e["path"].startswith("/")
        assert str(tmp_path) not in e["path"]

    # Regression guard (spec testing #5): generate_config runs the
    # WorkspaceConfig validators (git_root refs, no chaining, cycles) at
    # construction — must not raise.
    config = init.generate_config("mono", planned, env_runner=None)
    assert config.repos[root_name].git_root is None
    for sub in ("web", "infra"):
        assert config.repos[sub].git_root == root_name
        assert config.repos[config.repos[sub].git_root].git_root is None
```

**Step 2 — run to fail:**
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership && uv run pytest tests/core/test_init.py::test_plan_detected_repos_single_git_monorepo -v
```
Expected: fail (`AttributeError: 'WorkspaceInitializer' object has no attribute 'plan_detected_repos'`).

**Step 3 — implement.** Add this method to `WorkspaceInitializer` in `core/init.py` (e.g. immediately after `detect_repos`):
```python
    def plan_detected_repos(
        self, workspace_path: Path, detected: list[DetectedRepo]
    ) -> list[dict]:
        """Turn detected repos into config-entry dicts with RELATIVE paths.

        The workspace root (path == workspace_path) is emitted standalone with
        `path: '.'`; every detected subdir becomes a git_root child of the root
        with a path relative to the root. (Refined for ac3/ac8 in later tasks.)
        """
        root_name = workspace_path.name
        entries: list[dict] = []
        for d in detected:
            if d.path == workspace_path:
                entries.append({
                    "name": root_name,
                    "path": ".",
                    "type": "service",
                    "git_root": None,
                    "depends_on": [],
                })
                continue
            rel = d.path.relative_to(workspace_path)
            entries.append({
                "name": d.path.name,
                "path": str(rel),
                "type": "service",
                "git_root": root_name,
                "depends_on": [],
            })
        return entries
```

**Step 4 — run to pass:**
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership && uv run pytest tests/core/test_init.py -v
```

**Step 5 — commit:**
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership add -A
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership commit -m "init: add plan_detected_repos classifier (root + git_root children)

Emits the workspace root as path '.' and each detected subdir as a
git_root child with a relative path. See spec mship-init-detect-monorepo
ac1/ac2.

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
cd /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership && mship journal "plan_detected_repos: root + git_root children" --task mship-init-detect-monorepo --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=4 -->
## Task 4 — `plan_detected_repos`: subdir with its own `.git` stays standalone (ac3)

**Files:** `src/mship/core/init.py`, `tests/core/test_init.py`

**Step 1 — failing test.** Append to `tests/core/test_init.py`:
```python
def test_plan_detected_repos_subdir_with_own_git_is_standalone(tmp_path: Path):
    """ac3: a subdir with its OWN .git (a directory OR a submodule gitlink FILE)
    stays standalone (no git_root); a sibling without .git still attaches."""
    (tmp_path / ".git").mkdir()
    (tmp_path / "pyproject.toml").write_text("[project]\nname='root'\n")

    nested = tmp_path / "nested"
    nested.mkdir()
    (nested / ".git").mkdir()                       # independent nested repo
    (nested / "package.json").write_text("{}")

    submodule = tmp_path / "submodule"
    submodule.mkdir()
    (submodule / ".git").write_text(                # submodule gitlink FILE
        "gitdir: ../.git/modules/submodule\n"
    )
    (submodule / "package.json").write_text("{}")

    infra = tmp_path / "infra"
    infra.mkdir()
    (infra / "package.json").write_text("{}")

    init = WorkspaceInitializer()
    detected = init.detect_repos(tmp_path)
    by_name = {e["name"]: e for e in init.plan_detected_repos(tmp_path, detected)}

    assert by_name["nested"]["git_root"] is None
    assert by_name["nested"]["path"] == "nested"
    assert by_name["submodule"]["git_root"] is None
    assert by_name["submodule"]["path"] == "submodule"
    assert by_name["infra"]["git_root"] == tmp_path.name
```

**Step 2 — run to fail:**
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership && uv run pytest tests/core/test_init.py::test_plan_detected_repos_subdir_with_own_git_is_standalone -v
```
Expected: fail (Task-3 impl attaches `git_root` to *every* subdir, so `nested`/`submodule` wrongly get `git_root`).

**Step 3 — implement.** In `plan_detected_repos`, replace the subdir branch so a subdir owning `.git` is left standalone:
```python
            rel = d.path.relative_to(workspace_path)
            git_root = None if ".git" in d.markers else root_name
            entries.append({
                "name": d.path.name,
                "path": str(rel),
                "type": "service",
                "git_root": git_root,
                "depends_on": [],
            })
```

**Step 4 — run to pass:**
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership && uv run pytest tests/core/test_init.py -v
```

**Step 5 — commit:**
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership add -A
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership commit -m "init: keep subdirs with their own .git standalone

A subdir whose markers include .git (dir or submodule gitlink file) is
emitted standalone with no git_root, preserving independent-repo behavior.
See spec mship-init-detect-monorepo ac3.

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
cd /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership && mship journal "plan_detected_repos: own-.git subdirs stay standalone (ac3)" --task mship-init-detect-monorepo --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=5 -->
## Task 5 — `plan_detected_repos`: root-not-a-git-repo fallback (ac8)

**Files:** `src/mship/core/init.py`, `tests/core/test_init.py`

**Step 1 — failing test.** Append to `tests/core/test_init.py`:
```python
def test_plan_detected_repos_root_not_git_falls_back_to_standalone(tmp_path: Path):
    """ac8: when the workspace root has no .git, a markerless subdir does NOT get
    a git_root pointing at the non-git root — it falls back to standalone."""
    # No .git at root; give it a non-git marker so it is still detected.
    (tmp_path / "pyproject.toml").write_text("[project]\nname='root'\n")
    for sub in ("web", "infra"):
        d = tmp_path / sub
        d.mkdir()
        (d / "package.json").write_text("{}")

    init = WorkspaceInitializer()
    detected = init.detect_repos(tmp_path)
    by_name = {e["name"]: e for e in init.plan_detected_repos(tmp_path, detected)}

    for sub in ("web", "infra"):
        assert by_name[sub]["git_root"] is None
        assert by_name[sub]["path"] == sub
    assert by_name[tmp_path.name]["path"] == "."
    assert by_name[tmp_path.name]["git_root"] is None
```

**Step 2 — run to fail:**
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership && uv run pytest tests/core/test_init.py::test_plan_detected_repos_root_not_git_falls_back_to_standalone -v
```
Expected: fail (Task-4 impl gives markerless `web`/`infra` `git_root=root_name` even though the root has no `.git`).

**Step 3 — implement.** Replace the full body of `plan_detected_repos` with the final version (adds `root_is_git_owner` guard and documents the rules):
```python
    def plan_detected_repos(
        self, workspace_path: Path, detected: list[DetectedRepo]
    ) -> list[dict]:
        """Classify detected repos into config-entry dicts with RELATIVE paths
        and, for non-git subdirs of a git-owning root, a `git_root` back-ref.

        Rules (spec mship-init-detect-monorepo / issue #366 finding #4):
        - The workspace root (path == workspace_path), if detected, is emitted
          standalone with `path: '.'` and no git_root.
        - A subdir owning its own `.git` (a `.git` dir OR a submodule gitlink
          `.git` file — both make `_find_markers` record ".git") stays standalone
          with a path relative to the root and no git_root (ac3).
        - A subdir with NO `.git`, when the root IS a git owner, becomes a
          `git_root: <root-name>` child with a path relative to the root (ac1).
          Single-level detection: the parent IS the root, so relative-to-root
          equals the `(parent.path / child.path)` resolution contract.
        - If the root is not a git owner, non-git subdirs fall back to standalone
          emission — never point git_root at a non-git root (ac8).
        All emitted paths are relative for portability (ac2).
        """
        root_repo = next(
            (d for d in detected if d.path == workspace_path), None
        )
        root_is_git_owner = root_repo is not None and ".git" in root_repo.markers
        root_name = workspace_path.name

        entries: list[dict] = []
        for d in detected:
            if d.path == workspace_path:
                entries.append({
                    "name": root_name,
                    "path": ".",
                    "type": "service",
                    "git_root": None,
                    "depends_on": [],
                })
                continue
            rel = d.path.relative_to(workspace_path)
            has_own_git = ".git" in d.markers
            git_root = None if (has_own_git or not root_is_git_owner) else root_name
            entries.append({
                "name": d.path.name,
                "path": str(rel),
                "type": "service",
                "git_root": git_root,
                "depends_on": [],
            })
        return entries
```

**Step 4 — run to pass:**
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership && uv run pytest tests/core/test_init.py -v
```

**Step 5 — commit:**
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership add -A
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership commit -m "init: fall back to standalone when the root is not a git repo

Never emit git_root pointing at a non-git root; markerless subdirs revert
to today's standalone emission. See spec mship-init-detect-monorepo ac8.

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
cd /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership && mship journal "plan_detected_repos: root-not-git fallback (ac8)" --task mship-init-detect-monorepo --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=6 -->
## Task 6 — Wire non-interactive `--detect` to the classifier + cwd-anchor scaffolding (ac1/ac2)

**Files:** `src/mship/cli/init.py`, `tests/cli/test_init.py`

**Step 1 — failing test.** Append to `tests/cli/test_init.py`:
```python
def test_init_detect_emits_git_root_for_single_git_monorepo(tmp_path: Path, monkeypatch):
    """ac1/ac2: `init --detect` on a single-git monorepo emits the root as
    `path: .` (no git_root) and each markerless subdir as a git_root child with
    a relative path."""
    import subprocess
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True, capture_output=True)
    (tmp_path / "pyproject.toml").write_text("[project]\nname='root'\n")
    for sub in ("web", "infra"):
        d = tmp_path / sub
        d.mkdir()
        (d / "package.json").write_text("{}")

    monkeypatch.chdir(tmp_path)
    result = runner.invoke(app, ["init", "--name", "mono", "--detect"])
    assert result.exit_code == 0, result.output

    data = yaml.safe_load((tmp_path / "mothership.yaml").read_text())
    root_name = tmp_path.name
    assert data["repos"][root_name]["path"] == "."
    assert "git_root" not in data["repos"][root_name]
    for sub in ("web", "infra"):
        assert data["repos"][sub]["path"] == sub
        assert data["repos"][sub]["git_root"] == root_name
    for repo in data["repos"].values():          # ac2
        assert not str(repo["path"]).startswith("/")
```

**Step 2 — run to fail:**
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership && uv run pytest tests/cli/test_init.py::test_init_detect_emits_git_root_for_single_git_monorepo -v
```
Expected: fail (current detect branch emits absolute paths, no `git_root`, and no `.`-rooted entry).

**Step 3 — implement.** In `cli/init.py`, replace the `if detect:` block (lines 108-119) with:
```python
        # Auto-detect
        if detect:
            detected = initializer.detect_repos(cwd)
            planned = initializer.plan_detected_repos(cwd, detected)
            existing_paths = {Path(rd["path"]).resolve() for rd in repos_data}
            for entry in planned:
                abspath = (cwd / entry["path"]).resolve()
                if abspath not in existing_paths:
                    repos_data.append(entry)
```
Then anchor the scaffold loop to `cwd` (paths are now relative). Replace the loop body at lines 132-135:
```python
        if scaffold_taskfiles:
            for rd in repos_data:
                repo_path = (cwd / rd["path"]).resolve()
                result = initializer.write_taskfile(repo_path)
```
(`(cwd / rd["path"]).resolve()` is correct for both relative detect entries and the absolute paths that `--repo` flags still produce, since `Path` discards the left operand when the right side is absolute. The `created_taskfiles` display strings become absolute, which the existing scaffold tests do not assert on.)

**Step 4 — run to pass (whole init suite, to catch regressions in `test_init_detect`, scaffold tests, etc.):**
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership && uv run pytest tests/cli/test_init.py tests/test_init_integration.py -v
```

**Step 5 — commit:**
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership add -A
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership commit -m "cli init: emit git_root + relative paths from --detect

Wire the non-interactive --detect flow through plan_detected_repos and
anchor --scaffold-taskfiles writes to cwd (paths are now relative). See
spec mship-init-detect-monorepo ac1/ac2.

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
cd /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership && mship journal "cli init --detect emits git_root + relative paths" --task mship-init-detect-monorepo --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=7 -->
## Task 7 — Integration: emitted config loads via `ConfigLoader.load(require_paths=True)` + portability (ac7/ac2)

**Files:** `tests/test_init_detect_monorepo.py` (new)

**Step 1 — failing test.** Create `tests/test_init_detect_monorepo.py`:
```python
"""Integration: `mship init --detect` produces a working single-git monorepo
config (issue #366 finding #4 / spec mship-init-detect-monorepo)."""
import os
import subprocess
from pathlib import Path
from unittest.mock import MagicMock

import pytest
import yaml
from typer.testing import CliRunner

from mship.cli import app
from mship.core.config import ConfigLoader

runner = CliRunner()


def _git(*args, cwd):
    env = {**os.environ,
           "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, env=env)


def _build_single_git_monorepo(tmp_path: Path) -> Path:
    """Real single-git monorepo: root .git; subdirs web/ and infra/ with only
    package.json (no nested .git)."""
    root = tmp_path / "mono"
    root.mkdir()
    (root / "pyproject.toml").write_text("[project]\nname='mono'\n")
    for sub in ("web", "infra"):
        d = root / sub
        d.mkdir()
        (d / "package.json").write_text("{}")
    _git("init", "-q", ".", cwd=root)
    _git("add", ".", cwd=root)
    _git("commit", "-qm", "init", cwd=root)
    return root


def _init_detect(root: Path, monkeypatch) -> Path:
    monkeypatch.chdir(root)
    result = runner.invoke(
        app, ["init", "--name", "mono", "--detect", "--scaffold-taskfiles"]
    )
    assert result.exit_code == 0, result.output
    return root / "mothership.yaml"


def test_detected_monorepo_config_loads_with_require_paths(tmp_path: Path, monkeypatch):
    """ac7 + ac2: the emitted config loads via ConfigLoader.load(require_paths=True)
    — each git_root child resolves to (parent.path / child.path) and finds its
    scaffolded Taskfile.yml — and every emitted path is relative/portable."""
    root = _build_single_git_monorepo(tmp_path)
    cfg_path = _init_detect(root, monkeypatch)

    data = yaml.safe_load(cfg_path.read_text())
    for repo in data["repos"].values():
        assert not str(repo["path"]).startswith("/")
        assert str(root) not in str(repo["path"])

    config = ConfigLoader.load(cfg_path, require_paths=True)   # must not raise
    assert config.repos[root.name].git_root is None
    for sub in ("web", "infra"):
        assert config.repos[sub].git_root == root.name

    # ac2 portability: resolution is anchored on the config's directory, not the
    # process CWD — loading still succeeds from an unrelated cwd.
    monkeypatch.chdir(tmp_path)
    reloaded = ConfigLoader.load(cfg_path, require_paths=True)
    assert set(reloaded.repos) == set(config.repos)
```

**Step 2 — run to fail (before this task the file does not exist; run it to confirm the assertion path once created — it must pass only because Tasks 1-6 landed):**
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership && uv run pytest tests/test_init_detect_monorepo.py::test_detected_monorepo_config_loads_with_require_paths -v
```
Note: this is an acceptance test that green-lights the Task 1-6 wiring; if any prior task regressed (e.g. a child path left absolute, so `validate_git_root_child_path` rejects it, or a missing scaffolded Taskfile), it fails here.

**Step 3 — implement.** No production code — Tasks 1-6 satisfy it. If red, debug the offending prior task.

**Step 4 — run to pass:** (same command as Step 2).

**Step 5 — commit:**
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership add -A
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership commit -m "test: detected monorepo config loads with require_paths (ac7/ac2)

Integration coverage that init --detect --scaffold-taskfiles emits a
config ConfigLoader.load(require_paths=True) accepts, with portable
relative paths. See spec mship-init-detect-monorepo ac7/ac2.

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
cd /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership && mship journal "integration: emitted monorepo config loads with require_paths (ac7)" --task mship-init-detect-monorepo --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=8 -->
## Task 8 — Integration: `doctor` reports no "not a git repository" for subdirs (ac4)

**Files:** `tests/test_init_detect_monorepo.py`

**Step 1 — failing test.** Append to `tests/test_init_detect_monorepo.py`:
```python
def test_detected_monorepo_doctor_no_not_a_git_repository(tmp_path: Path, monkeypatch):
    """ac4: doctor on a freshly detected single-git monorepo reports NO
    'not a git repository' for the subdir repos — the git check resolves through
    git_root to the root (doctor.py:186-191)."""
    from mship.core.doctor import DoctorChecker
    from mship.util.shell import ShellRunner, ShellResult

    root = _build_single_git_monorepo(tmp_path)
    cfg_path = _init_detect(root, monkeypatch)
    config = ConfigLoader.load(cfg_path, require_paths=True)

    shell = MagicMock(spec=ShellRunner)
    shell.run.return_value = ShellResult(
        returncode=0, stdout="test\nrun\nlint\nsetup\n", stderr=""
    )
    report = DoctorChecker(config, shell).run()

    for name in (root.name, "web", "infra"):
        git_check = next(c for c in report.checks if c.name == f"{name}/git")
        assert git_check.status == "pass", git_check.message
        assert "not a git repository" not in git_check.message
```

**Step 2 — run to fail:**
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership && uv run pytest tests/test_init_detect_monorepo.py::test_detected_monorepo_doctor_no_not_a_git_repository -v
```
Note: exercises the real `DoctorChecker` git check (`doctor.py:187` `git_check_path = self._config.repos[repo.git_root].path`) against the emitted+loaded config; a `MagicMock` shell is used because the git check is filesystem-based, not shell-based. It relies on Tasks 1-6.

**Step 3 — implement.** No production code — assertion over the real doctor checker.

**Step 4 — run to pass:** (same command).

**Step 5 — commit:**
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership add -A
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership commit -m "test: doctor finds no not-a-git-repo on detected monorepo (ac4)

Runs the real DoctorChecker against the emitted+loaded config; subdir git
checks pass via git_root resolution to the root. See spec
mship-init-detect-monorepo ac4.

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
cd /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership && mship journal "integration: doctor no not-a-git-repo on detected monorepo (ac4)" --task mship-init-detect-monorepo --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=9 -->
## Task 9 — Integration: `audit` reports no `not_a_git_repo`; spawn gate not blocked (ac5/ac6)

**Files:** `tests/test_init_detect_monorepo.py`

**Step 1 — failing test.** Append to `tests/test_init_detect_monorepo.py`:
```python
def test_detected_monorepo_audit_no_not_a_git_repo(tmp_path: Path, monkeypatch):
    """ac5/ac6: audit on the freshly detected monorepo reports NO not_a_git_repo
    error (subdirs group under the root's git via _git_root_key), so `mship
    spawn`'s audit gate (audit_gate.run_audit_gate) is not blocked by it."""
    from mship.core.repo_state import audit_repos
    from mship.util.shell import ShellRunner

    root = _build_single_git_monorepo(tmp_path)
    cfg_path = _init_detect(root, monkeypatch)
    config = ConfigLoader.load(cfg_path, require_paths=True)

    report = audit_repos(config, ShellRunner())

    # ac5: no repo carries a not_a_git_repo error.
    for repo in report.repos:
        assert "not_a_git_repo" not in {i.code for i in repo.issues}, (
            repo.name, [i.code for i in repo.issues]
        )

    # ac6: the exact error-code list the spawn audit gate keys off
    # (audit_gate.run_audit_gate builds `<name>:<code>` for severity == error)
    # contains no not_a_git_repo, so spawn is not blocked by it.
    error_codes = [
        f"{r.name}:{i.code}"
        for r in report.repos
        for i in r.issues
        if i.severity == "error"
    ]
    assert not any(c.endswith(":not_a_git_repo") for c in error_codes)
```

**Step 2 — run to fail:**
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership && uv run pytest tests/test_init_detect_monorepo.py::test_detected_monorepo_audit_no_not_a_git_repo -v
```
Note: uses a real `ShellRunner` + real git repo (matching the `audit_workspace`/`_load` convention). `web`/`infra` group under `mono` via `_git_root_key`, and `_git_root_path` resolves to the root, which has `.git`, so no `not_a_git_repo`. (A benign `no_upstream` error may exist — that is unrelated and not asserted; ac6 checks only the `not_a_git_repo` code, the finding-#4 gate.) Relies on Tasks 1-6.

**Step 3 — implement.** No production code — assertion over real `audit_repos` + the gate's error-code contract.

**Step 4 — run to pass:** (same command), then the full module:
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership && uv run pytest tests/test_init_detect_monorepo.py tests/core/test_init.py tests/cli/test_init.py -v
```

**Step 5 — commit:**
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership add -A
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership commit -m "test: audit finds no not_a_git_repo on detected monorepo (ac5/ac6)

Runs real audit_repos over the emitted+loaded config and asserts the
spawn audit gate's error-code list carries no not_a_git_repo. See spec
mship-init-detect-monorepo ac5/ac6.

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
cd /home/bailey/development/repos/mship-workspace/.worktrees/mship-init-detect-monorepo/mothership && mship journal "integration: audit + spawn gate clear of not_a_git_repo (ac5/ac6)" --task mship-init-detect-monorepo --action committed
```
<!-- /mship:task -->

---

## Self-Review

### AC → Task map (all 8)
- **ac1** (root `path: .`/no git_root; markerless subdirs get `git_root: <root>` + relative path): Task 3 (unit `plan_detected_repos`), Task 6 (CLI emission), Task 7 (loaded config asserts `git_root`).
- **ac2** (every emitted path relative, no absolute/`/home`): Task 3 (unit no-absolute assert), Task 6 (CLI no-absolute assert), Task 7 (yaml no-absolute + portability reload from a different cwd). Enforced structurally because `RepoConfig.validate_git_root_child_path` (config.py:258-282) *rejects* absolute git_root child paths, and the classifier only ever emits `.`/`str(rel)`.
- **ac3** (subdir with own `.git` — dir or submodule gitlink file — stays standalone, no git_root): Task 4 (covers both `.git` dir and gitlink `.git` file, matching `_find_markers`' `(path/".git").exists()`).
- **ac4** (doctor: no "not a git repository" for subdirs): Task 8 — runs the **real `DoctorChecker`** against the emitted+loaded config (not a re-implementation), asserting `web/git`/`infra/git` pass via the `git_root` resolution at `doctor.py:187-191`.
- **ac5** (audit: no `not_a_git_repo`): Task 9 — runs the **real `audit_repos`** with a real `ShellRunner`; subdirs group under the root via `_git_root_key`/`_git_root_path` (`repo_state.py:157-167`, `396-410`).
- **ac6** (spawn not blocked by `not_a_git_repo`): Task 9 — builds the exact `<name>:<code>` error list that `audit_gate.run_audit_gate` (audit_gate.py:35-41) keys off and asserts no `not_a_git_repo`, faithfully modeling the spawn gate without invoking the full spawn command.
- **ac7** (`ConfigLoader.load(require_paths=True)` succeeds; git_root child resolves to `parent.path / child.path` and finds its scaffolded `Taskfile.yml`): Task 7 — the loaded config exercises the two-pass resolver at `config.py:542-573`; `--scaffold-taskfiles` (cwd-anchored in Task 6) drops a `Taskfile.yml` in the root and each child.
- **ac8** (root not a git repo → fallback to standalone, no git_root at a non-git root): Task 5.

### Regression guard (spec testing #5 — `validate_git_root_refs`, no dangling/chaining)
Covered twice: Task 3's `generate_config(...)` assertion (constructs `WorkspaceConfig`, running `validate_git_root_refs`/`validate_no_cycles`/`validate_git_root_child_path` — no chaining because the only parent is the root, whose `git_root` is `None`), and Task 7's `ConfigLoader.load` (re-runs all `WorkspaceConfig` validators on the serialized yaml).

### Placeholder scan
No `TODO`/`FIXME`/`...`/`pass`-stub/`NotImplemented` in any snippet. Every code block is complete and paste-ready. The three "no production code" tasks (7-9) are acceptance tests over real checkers, with implementation code fully delivered in Tasks 1-6.

### Type consistency
- `plan_detected_repos(workspace_path: Path, detected: list[DetectedRepo]) -> list[dict]` — dict keys `name:str`, `path:str` (`"."` or `str(rel)`), `type:str`, `git_root:str|None`, `depends_on:list`. Consumed by `generate_config`, which reads exactly these keys (`repo["name"]`, `Path(repo["path"])`, `repo["type"]`, `repo.get("depends_on", [])`, `repo.get("git_root")`).
- `git_root` flows `str|None` end-to-end: dict → `RepoConfig.git_root: str | None` → `write_config` (`if repo.git_root is not None`) → yaml → `ConfigLoader` → `str`.
- CLI dedup/scaffold compute absolute filesystem paths via `(cwd / entry["path"]).resolve()`, which is correct for both relative detect entries and the absolute paths `--repo` flags still produce (pathlib discards the left side on an absolute right side).

### No-data-shape-change note
`DetectedRepo` is left unchanged: `markers` already records `.git` (it is in `REPO_MARKERS`) and `path` already lets the classifier relativize against the scan root and identify the root entry (`d.path == workspace_path`). No new field is required.

### Scope boundary
Only the non-interactive `--detect` path is wired (all 8 ACs are non-interactive). `_run_interactive` is unchanged; reusing `plan_detected_repos` there is a clean follow-up and is called out so it is not silently missed. The `.yaml`-vs-`.yml` scaffolding and worktree-materialization concerns (findings #1/#3) are explicit non-goals and untouched.
