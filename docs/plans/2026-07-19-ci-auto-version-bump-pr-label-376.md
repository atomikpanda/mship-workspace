# CI Auto Version-Bump on Merge via PR Label (issue 376) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `ci-auto-version-bump-on-merge-via-pr-issue-376` (approved) — WorkItem `wi-20260719204416-98810008`

**Goal:** When a PR is merged into `main`, a GitHub Action bumps the package version (level chosen by a `semver:*` PR label, default patch), commits it back with `[skip ci]`, and pushes a `v<version>` tag.

**Architecture:** All version logic lives in an importable, unit-tested module `src/mship/ci/version_bump.py` (pure functions + a thin `python -m` CLI). The workflow YAML is a thin wrapper that calls the module and does the git plumbing. The version string lives in **two** files that must stay in sync — `pyproject.toml` `[project].version` and `src/mship/__init__.py` `__version__` (guarded by the existing `tests/test_version.py`) — so the helper rewrites both.

**Tech Stack:** Python 3.14 (stdlib `argparse`, `re`, `tomllib`, `pathlib`), pytest, PyYAML 6 (already a dep, for the workflow-structure test), GitHub Actions.

---

## File Structure

- `src/mship/ci/__init__.py` — new package marker for the CI helpers.
- `src/mship/ci/version_bump.py` — the whole feature's logic: `bump_version`, `select_level`, `read_current_version`, `rewrite_version_files`, `VersionError`, and a `main()` CLI.
- `tests/ci/__init__.py` — package marker (siblings `tests/core`, `tests/cli`, `tests/util` are packages).
- `tests/ci/test_version_bump.py` — unit tests for the helper.
- `tests/ci/test_workflow.py` — parses the workflow YAML and asserts its structure.
- `.github/workflows/version-bump.yml` — the workflow (repo's first).

---

<!-- mship:task id=1 -->
### Task 1: Semver bump math (`bump_version`)

**Files:**
- Create: `src/mship/ci/__init__.py` (empty file)
- Create: `src/mship/ci/version_bump.py`
- Create: `tests/ci/__init__.py` (empty file)
- Test: `tests/ci/test_version_bump.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/ci/test_version_bump.py
import pytest

from mship.ci.version_bump import VersionError, bump_version


@pytest.mark.parametrize(
    "current,level,expected",
    [
        ("0.5.0", "patch", "0.5.1"),
        ("0.5.0", "minor", "0.6.0"),   # patch digit zeroed
        ("0.5.0", "major", "1.0.0"),   # minor and patch zeroed
        ("1.2.3", "patch", "1.2.4"),
        ("1.2.3", "minor", "1.3.0"),
        ("1.2.3", "major", "2.0.0"),
    ],
)
def test_bump_version(current, level, expected):
    assert bump_version(current, level) == expected


def test_bump_version_rejects_bad_version():
    with pytest.raises(VersionError):
        bump_version("1.2", "patch")


def test_bump_version_rejects_bad_level():
    with pytest.raises(VersionError):
        bump_version("1.2.3", "sideways")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/ci/test_version_bump.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'mship.ci'`

- [ ] **Step 3: Write minimal implementation**

```python
# src/mship/ci/version_bump.py
"""Compute and apply the next package version for the CI version-bump workflow (issue 376).

The version lives in two files that must stay in sync (guarded by tests/test_version.py):
pyproject.toml [project].version and src/mship/__init__.py __version__. This module reads the
current version from pyproject.toml, computes the next semver from a PR-label-derived bump
level, and rewrites both files in place.
"""
from __future__ import annotations

import re
from typing import Iterable

_LEVELS = ("major", "minor", "patch")  # highest-precedence first
_VERSION_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


class VersionError(ValueError):
    """Raised when a version can't be parsed or a level is unknown."""


def bump_version(current: str, level: str) -> str:
    m = _VERSION_RE.match(current.strip())
    if not m:
        raise VersionError(f"not a MAJOR.MINOR.PATCH version: {current!r}")
    if level not in _LEVELS:
        raise VersionError(f"unknown bump level: {level!r}")
    major, minor, patch = (int(g) for g in m.groups())
    if level == "major":
        return f"{major + 1}.0.0"
    if level == "minor":
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"
```

Also create empty `src/mship/ci/__init__.py` and `tests/ci/__init__.py`.

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/ci/test_version_bump.py -v`
Expected: PASS (9 cases)

- [ ] **Step 5: Commit + journal**

```bash
git add src/mship/ci/__init__.py src/mship/ci/version_bump.py tests/ci/__init__.py tests/ci/test_version_bump.py
git commit -m "feat(ci): semver bump_version helper (issue 376)"
mship journal "bump_version + VersionError; 9 cases passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: Label → bump level (`select_level`)

**Files:**
- Modify: `src/mship/ci/version_bump.py`
- Test: `tests/ci/test_version_bump.py`

- [ ] **Step 1: Write the failing test**

```python
# add to tests/ci/test_version_bump.py
from mship.ci.version_bump import select_level


@pytest.mark.parametrize(
    "labels,expected",
    [
        (["semver:minor"], "minor"),
        (["semver:patch", "semver:minor"], "minor"),          # highest precedence wins
        ([], "patch"),                                         # default
        (["bug", "needs-review"], "patch"),                   # no semver label -> default
        (["semver:major", "semver:patch"], "major"),
        (["SemVer:Major"], "major"),                          # case-insensitive
    ],
)
def test_select_level(labels, expected):
    assert select_level(labels) == expected
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/ci/test_version_bump.py -k select_level -v`
Expected: FAIL — `ImportError: cannot import name 'select_level'`

- [ ] **Step 3: Write minimal implementation**

```python
# add to src/mship/ci/version_bump.py
_LABEL_PREFIX = "semver:"


def select_level(labels: Iterable[str]) -> str:
    names = {label.strip().lower() for label in labels if label and label.strip()}
    for level in _LEVELS:  # major, minor, patch -> precedence major > minor > patch
        if f"{_LABEL_PREFIX}{level}" in names:
            return level
    return "patch"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/ci/test_version_bump.py -k select_level -v`
Expected: PASS (6 cases)

- [ ] **Step 5: Commit + journal**

```bash
git add src/mship/ci/version_bump.py tests/ci/test_version_bump.py
git commit -m "feat(ci): select_level maps PR labels to a bump level (issue 376)"
mship journal "select_level precedence + patch default; passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: Read current version + rewrite both files

**Files:**
- Modify: `src/mship/ci/version_bump.py`
- Test: `tests/ci/test_version_bump.py`

- [ ] **Step 1: Write the failing test**

```python
# add to tests/ci/test_version_bump.py
from pathlib import Path

from mship.ci.version_bump import read_current_version, rewrite_version_files


def _mini_repo(tmp_path: Path, version: str = "0.5.0") -> Path:
    (tmp_path / "pyproject.toml").write_text(
        f'[project]\nname = "mship"\nversion = "{version}"\ndescription = "x"\n',
        encoding="utf-8",
    )
    pkg = tmp_path / "src" / "mship"
    pkg.mkdir(parents=True)
    (pkg / "__init__.py").write_text(
        f'"""mship."""\n__version__ = "{version}"\n', encoding="utf-8"
    )
    return tmp_path


def test_read_current_version(tmp_path):
    repo = _mini_repo(tmp_path, "1.2.3")
    assert read_current_version(repo / "pyproject.toml") == "1.2.3"


def test_rewrite_updates_both_files_and_leaves_rest_intact(tmp_path):
    repo = _mini_repo(tmp_path, "0.5.0")
    rewrite_version_files(repo, "0.6.0")

    py = (repo / "pyproject.toml").read_text(encoding="utf-8")
    init = (repo / "src" / "mship" / "__init__.py").read_text(encoding="utf-8")

    assert 'version = "0.6.0"' in py
    assert '__version__ = "0.6.0"' in init
    # Surrounding lines untouched:
    assert 'name = "mship"' in py and 'description = "x"' in py
    assert py.startswith("[project]")
    assert init.startswith('"""mship."""')
    # The two declarations agree (mirrors the real tests/test_version.py guard):
    assert '0.6.0' in py and '0.6.0' in init


def test_rewrite_leaves_both_files_untouched_when_init_line_missing(tmp_path):
    repo = _mini_repo(tmp_path, "0.5.0")
    # Corrupt the __init__ so its version line can't be found.
    (repo / "src" / "mship" / "__init__.py").write_text('"""mship."""\n', encoding="utf-8")
    before_py = (repo / "pyproject.toml").read_text(encoding="utf-8")

    with pytest.raises(VersionError):
        rewrite_version_files(repo, "0.6.0")

    # pyproject must be untouched because we raise before writing anything.
    assert (repo / "pyproject.toml").read_text(encoding="utf-8") == before_py


def test_read_current_version_raises_when_absent(tmp_path):
    (tmp_path / "pyproject.toml").write_text('[project]\nname = "x"\n', encoding="utf-8")
    with pytest.raises(VersionError):
        read_current_version(tmp_path / "pyproject.toml")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/ci/test_version_bump.py -k "rewrite or read_current" -v`
Expected: FAIL — `ImportError: cannot import name 'read_current_version'`

- [ ] **Step 3: Write minimal implementation**

```python
# add to src/mship/ci/version_bump.py
import tomllib
from pathlib import Path

# In-place single-line substitutions that preserve all other formatting.
_PYPROJECT_VERSION_RE = re.compile(
    r'(?P<pre>^version\s*=\s*")(?P<ver>\d+\.\d+\.\d+)(?P<post>")', re.MULTILINE
)
_INIT_VERSION_RE = re.compile(
    r'(?P<pre>^__version__\s*=\s*")(?P<ver>\d+\.\d+\.\d+)(?P<post>")', re.MULTILINE
)


def read_current_version(pyproject_path: Path) -> str:
    data = tomllib.loads(Path(pyproject_path).read_text(encoding="utf-8"))
    try:
        return data["project"]["version"]
    except (KeyError, TypeError) as exc:
        raise VersionError(f"no [project].version in {pyproject_path}") from exc


def _sub_once(text: str, pattern: re.Pattern[str], new_version: str, where: Path) -> str:
    new_text, n = pattern.subn(
        lambda m: f"{m.group('pre')}{new_version}{m.group('post')}", text, count=1
    )
    if n != 1:
        raise VersionError(f"could not find a version line to update in {where}")
    return new_text


def rewrite_version_files(repo_root: Path, new_version: str) -> None:
    repo_root = Path(repo_root)
    pyproject = repo_root / "pyproject.toml"
    init = repo_root / "src" / "mship" / "__init__.py"
    # Compute BOTH substitutions before writing EITHER, so a failure leaves both files intact.
    new_py = _sub_once(pyproject.read_text(encoding="utf-8"), _PYPROJECT_VERSION_RE, new_version, pyproject)
    new_init = _sub_once(init.read_text(encoding="utf-8"), _INIT_VERSION_RE, new_version, init)
    pyproject.write_text(new_py, encoding="utf-8")
    init.write_text(new_init, encoding="utf-8")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/ci/test_version_bump.py -k "rewrite or read_current" -v`
Expected: PASS

- [ ] **Step 5: Commit + journal**

```bash
git add src/mship/ci/version_bump.py tests/ci/test_version_bump.py
git commit -m "feat(ci): read current version + atomic dual-file rewrite (issue 376)"
mship journal "read_current_version + rewrite_version_files (both files, fail-safe); passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: CLI entrypoint (`python -m mship.ci.version_bump`)

**Files:**
- Modify: `src/mship/ci/version_bump.py`
- Test: `tests/ci/test_version_bump.py`

- [ ] **Step 1: Write the failing test**

```python
# add to tests/ci/test_version_bump.py
from mship.ci.version_bump import main


def test_main_bumps_both_files_and_prints_new_version(tmp_path, capsys):
    repo = _mini_repo(tmp_path, "0.5.0")
    rc = main(["--labels", "bug,semver:minor", "--repo-root", str(repo)])
    assert rc == 0
    out = capsys.readouterr().out.strip()
    assert out == "0.6.0"
    assert 'version = "0.6.0"' in (repo / "pyproject.toml").read_text(encoding="utf-8")
    assert '__version__ = "0.6.0"' in (repo / "src" / "mship" / "__init__.py").read_text(encoding="utf-8")


def test_main_defaults_to_patch_when_no_semver_label(tmp_path, capsys):
    repo = _mini_repo(tmp_path, "0.5.0")
    main(["--labels", "", "--repo-root", str(repo)])
    assert capsys.readouterr().out.strip() == "0.5.1"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/ci/test_version_bump.py -k main -v`
Expected: FAIL — `ImportError: cannot import name 'main'`

- [ ] **Step 3: Write minimal implementation**

```python
# add to src/mship/ci/version_bump.py
import argparse
import sys


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m mship.ci.version_bump")
    parser.add_argument("--labels", default="", help="comma- or newline-separated PR label names")
    parser.add_argument("--repo-root", default=".", help="repo root containing pyproject.toml")
    args = parser.parse_args(argv)

    labels = re.split(r"[,\n]", args.labels)
    level = select_level(labels)
    repo_root = Path(args.repo_root).resolve()
    current = read_current_version(repo_root / "pyproject.toml")
    new_version = bump_version(current, level)
    rewrite_version_files(repo_root, new_version)
    print(new_version)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/ci/test_version_bump.py -v`
Expected: PASS (full file)

- [ ] **Step 5: Commit + journal**

```bash
git add src/mship/ci/version_bump.py tests/ci/test_version_bump.py
git commit -m "feat(ci): python -m mship.ci.version_bump CLI (issue 376)"
mship journal "CLI main: labels->level->bump->write both->print; passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: The workflow + a structure test

**Files:**
- Create: `.github/workflows/version-bump.yml`
- Test: `tests/ci/test_workflow.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/ci/test_workflow.py
from pathlib import Path

import yaml

WORKFLOW = Path(__file__).resolve().parents[2] / ".github" / "workflows" / "version-bump.yml"


def _load():
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))


def test_workflow_exists():
    assert WORKFLOW.is_file()


def test_triggers_on_pr_closed():
    wf = _load()
    # PyYAML parses the bare `on:` key as the boolean True.
    on = wf.get("on", wf.get(True))
    assert on["pull_request"]["types"] == ["closed"]


def test_job_guarded_to_merged_into_main():
    wf = _load()
    job = next(iter(wf["jobs"].values()))
    guard = job["if"]
    assert "merged == true" in guard
    assert "base.ref == 'main'" in guard


def test_has_write_permission_and_concurrency():
    wf = _load()
    assert wf["permissions"]["contents"] == "write"
    assert "concurrency" in wf


def test_bump_commit_uses_skip_ci_and_tags():
    raw = WORKFLOW.read_text(encoding="utf-8")
    assert "[skip ci]" in raw
    assert "python -m mship.ci.version_bump" in raw
    assert "git tag" in raw
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/ci/test_workflow.py -v`
Expected: FAIL — `test_workflow_exists` fails (file absent)

- [ ] **Step 3: Write the workflow**

```yaml
# .github/workflows/version-bump.yml
name: version-bump

on:
  pull_request:
    types: [closed]

permissions:
  contents: write

concurrency:
  group: version-bump-main
  cancel-in-progress: false

jobs:
  bump:
    if: >-
      github.event.pull_request.merged == true &&
      github.event.pull_request.base.ref == 'main'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: main
          fetch-depth: 0
          token: ${{ secrets.GITHUB_TOKEN }}

      - uses: actions/setup-python@v5
        with:
          python-version: "3.x"

      - name: Compute and apply version bump
        id: bump
        env:
          PYTHONPATH: src
        run: |
          NEW_VERSION="$(python -m mship.ci.version_bump \
            --labels "${{ join(github.event.pull_request.labels.*.name, ',') }}")"
          echo "new_version=${NEW_VERSION}" >> "$GITHUB_OUTPUT"

      - name: Commit, tag, and push
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add pyproject.toml src/mship/__init__.py
          git commit -m "[skip ci] chore: bump version to v${{ steps.bump.outputs.new_version }}"
          git tag -a "v${{ steps.bump.outputs.new_version }}" -m "v${{ steps.bump.outputs.new_version }}"
          git push origin main --follow-tags
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/ci/test_workflow.py -v`
Expected: PASS (5 cases)

- [ ] **Step 5: Full suite + commit + journal**

```bash
uv run pytest tests/ci/ -v
mship test            # records the passing-test evidence mship finish gates on
git add .github/workflows/version-bump.yml tests/ci/test_workflow.py
git commit -m "feat(ci): version-bump workflow on PR merge to main (issue 376)"
mship journal "workflow YAML + structure test; full tests/ci green" --action committed
```
<!-- /mship:task -->

---

## Self-Review

**Spec coverage:**
- AC1 (bump math incl. digit-zeroing) → Task 1.
- AC2 (label precedence + default) → Task 2.
- AC3 (rewrite both files, rest untouched, guard still passes) → Task 3.
- AC4 (malformed version → non-zero exit, files untouched) → Tasks 1 + 3 (`VersionError` propagates; CLI returns non-zero because the exception is uncaught → `sys.exit` non-zero).
- AC5 (workflow file: trigger, merged+base guard, contents:write, concurrency, `[skip ci]`) → Task 5.
- AC6 (writes version, commits, pushes `v<version>` tag) → Task 5 workflow steps; the tag/commit plumbing is asserted structurally (not executed) per the Testing section.

**Placeholder scan:** none — every step has concrete code/commands.

**Type consistency:** `bump_version(current, level)`, `select_level(labels)`, `read_current_version(pyproject_path)`, `rewrite_version_files(repo_root, new_version)`, `main(argv)`, `VersionError` — names identical across tasks and tests.

**Note on AC4 exit code:** `main()` deliberately does not catch `VersionError`; an uncaught exception makes `sys.exit(main())` never reach `0` and the process exits non-zero with a traceback, satisfying "fail loudly." No try/except needed.
