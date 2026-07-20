# PR1 — mship view: canonical data + WorkItem/phase-aware rendering

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** mship-view-needs-a-major-overhaul-to

**Goal:** Fix the concrete data/rendering defects in `mship view` without any new TUI framework work. Make `mship view spec` resolve specs from the workspace-canonical `specs/` store (branch/worktree independent), let it select by WorkItem id or status (with a deterministic, documented no-arg default instead of newest-file mtime), group `mship view status` tasks under their WorkItem with each task's phase, and give `journal`/`diff`/`spec` a WorkItem/phase-aware header. All the resolution/selection/grouping/header logic lands as pure, unit-testable functions in `core/view/`, kept separate from the Textual rendering so every AC is testable without driving the TUI.

**Architecture:**
- **Pure data layer (`src/mship/core/view/`)** — new modules `spec_selection.py` (canonical spec read + selection), `status_grouping.py` (group task summaries under work items), `headers.py` (WorkItem/phase header strings). These take already-parsed `Spec`/`WorkItem`/`TaskSummary`/`WorkItemSummary` objects and return data or plain strings; no Textual, no container.
- **Thin CLI seam (`src/mship/cli/view/`)** — a shared `_workitems.py` helper builds the `WorkItemSummary` index from the container's canonical stores (reusing the existing `build_workitem_index`). The four view commands wire the pure functions into their existing `ViewApp` subclasses via small, optional constructor params (`workitem_loader` / `header_provider`), so existing tests that construct the views without those params keep their current behavior.
- **Canonical store is authoritative.** `SpecStore(workspace_root / "specs")` lives at the workspace root (the dir containing `mothership.yaml`), not in any per-pane git worktree, so reading it is inherently branch/worktree independent (AC1). The legacy `find_spec` worktree/mtime search stays as a fallback only for frontmatter-less/legacy `docs/superpowers/specs` layouts.

**Tech Stack:** Python 3.14, uv, pytest (`uv run pytest`, `pythonpath=["src"]`, `asyncio_mode=auto`), Textual (existing `ViewApp` base), Pydantic v2 models (`Spec`, `WorkItem`, `Task`), Typer CLI, `dependency_injector` container.

---

## File Structure

Create:
- `src/mship/core/view/spec_selection.py` — pure canonical spec reader + selection: `load_canonical_specs(specs_dir)`, `SpecSelector`, `select_default`, `select_by_status`, `select_by_workitem`, `select_spec`, `SpecSelectionError`. (AC1, AC2)
- `src/mship/core/view/status_grouping.py` — `WorkItemTaskGroup`, `group_tasks_by_workitem(tasks, workitems)`. (AC5)
- `src/mship/core/view/headers.py` — `header_for_task(...)`, `header_for_spec(...)`. (AC9)
- `src/mship/cli/view/_workitems.py` — `load_workitem_index(container)` shared helper building the `WorkItemSummary` index from the canonical stores.
- `tests/core/view/test_spec_selection.py`, `tests/core/view/test_status_grouping.py`, `tests/core/view/test_headers.py`, `tests/cli/view/test_workitems_helper.py` — new test modules.

Modify:
- `src/mship/cli/view/spec.py` — add `--workitem`/`--status` options + deterministic canonical default; render the canonical path through the existing web/non-TTY/TUI branches; add `header_provider` to `SpecView`. (AC1, AC2, AC9-spec)
- `src/mship/cli/view/status.py` — `StatusView` gains `workitem_loader`; `gather()` renders tasks grouped under their WorkItem with a group header. (AC5)
- `src/mship/cli/view/logs.py` — `LogsView` gains `workitem_loader`; `gather()` prepends the WorkItem/phase header. (AC9)
- `src/mship/cli/view/diff.py` — `DiffView` gains `header_provider` + a header `Static`; the diff command wires it. (AC9)
- `tests/cli/view/test_spec_view.py`, `tests/cli/view/test_status_view.py`, `tests/cli/view/test_logs_view.py`, `tests/cli/view/test_diff_view.py` — add PR1 tests.

---

<!-- mship:task id=1 -->
## Task 1 — Canonical spec selection: by WorkItem / status / deterministic default (AC2)

**Files:**
- `src/mship/core/view/spec_selection.py` (create)
- `tests/core/view/test_spec_selection.py` (create)

**Failing test** — `tests/core/view/test_spec_selection.py`:
```python
from datetime import datetime, timezone

import pytest

from mship.core.spec import Spec
from mship.core.workitem import WorkItem
from mship.core.view.spec_selection import (
    SpecSelectionError,
    SpecSelector,
    select_by_status,
    select_by_workitem,
    select_default,
    select_spec,
)


def _spec(spec_id, *, status="draft", created):
    return Spec(id=spec_id, title=spec_id, status=status,
                created_at=created, updated_at=created)


def _dt(day):
    return datetime(2026, 7, day, tzinfo=timezone.utc)


def _wi(item_id, *, spec_id=None):
    now = _dt(1)
    return WorkItem(id=item_id, title=item_id, workspace="ws", kind="feature",
                    created_at=now, updated_at=now, spec_id=spec_id)


def test_default_picks_newest_by_created_at_not_mtime():
    specs = [_spec("old", created=_dt(1)), _spec("new", created=_dt(9)),
             _spec("mid", created=_dt(5))]
    assert select_default(specs).id == "new"


def test_default_tie_breaks_on_id():
    specs = [_spec("aaa", created=_dt(3)), _spec("zzz", created=_dt(3))]
    assert select_default(specs).id == "zzz"


def test_default_excludes_archived_unless_all_archived():
    specs = [_spec("live", status="draft", created=_dt(1)),
             _spec("gone", status="archived", created=_dt(9))]
    assert select_default(specs).id == "live"
    only_archived = [_spec("gone", status="archived", created=_dt(9))]
    assert select_default(only_archived).id == "gone"


def test_default_empty_raises():
    with pytest.raises(SpecSelectionError):
        select_default([])


def test_select_by_status_returns_newest_match():
    specs = [_spec("r1", status="needs_review", created=_dt(1)),
             _spec("r2", status="needs_review", created=_dt(7)),
             _spec("a1", status="approved", created=_dt(9))]
    assert select_by_status(specs, "needs_review").id == "r2"


def test_select_by_status_no_match_raises():
    with pytest.raises(SpecSelectionError):
        select_by_status([_spec("a", status="approved", created=_dt(1))], "needs_review")


def test_select_by_workitem_follows_spec_id_link():
    specs = [_spec("s-linked", created=_dt(1)), _spec("s-other", created=_dt(2))]
    items = [_wi("wi-1", spec_id="s-linked")]
    assert select_by_workitem(specs, items, "wi-1").id == "s-linked"


def test_select_by_workitem_unknown_item_raises():
    with pytest.raises(SpecSelectionError):
        select_by_workitem([], [], "wi-missing")


def test_select_by_workitem_item_without_spec_raises():
    with pytest.raises(SpecSelectionError):
        select_by_workitem([], [_wi("wi-1", spec_id=None)], "wi-1")


def test_select_by_workitem_dangling_spec_raises():
    items = [_wi("wi-1", spec_id="ghost")]
    with pytest.raises(SpecSelectionError):
        select_by_workitem([_spec("real", created=_dt(1))], items, "wi-1")


def test_select_spec_precedence_workitem_over_status_over_default():
    specs = [_spec("s-wi", status="draft", created=_dt(1)),
             _spec("s-nr", status="needs_review", created=_dt(2)),
             _spec("s-new", status="approved", created=_dt(9))]
    items = [_wi("wi-1", spec_id="s-wi")]
    assert select_spec(specs, items, SpecSelector(work_item_id="wi-1")).id == "s-wi"
    assert select_spec(specs, items, SpecSelector(status="needs_review")).id == "s-nr"
    assert select_spec(specs, items, SpecSelector()).id == "s-new"
```

**Run (expect fail):** `uv run pytest tests/core/view/test_spec_selection.py -q`
Expected failure: `ModuleNotFoundError: No module named 'mship.core.view.spec_selection'`.

**Minimal implementation** — `src/mship/core/view/spec_selection.py`:
```python
"""Canonical spec resolution + selection for `mship view spec` (AC1, AC2).

Pure over already-parsed `Spec`/`WorkItem` objects, plus one resilient reader of
the workspace-canonical `<workspace_root>/specs` store. Deterministic: selection
is by created_at + id, never filesystem mtime.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from mship.core.spec import Spec
from mship.core.workitem import WorkItem


class SpecSelectionError(Exception):
    """No spec matched the requested selector (work item / status / default)."""


def _sort_key(spec: Spec) -> tuple:
    # Deterministic newest-first ordering: created_at, then id. NOT mtime.
    return (spec.created_at, spec.id)


def load_canonical_specs(specs_dir: Path) -> list[Spec]:
    """Parse every spec in the canonical `<workspace_root>/specs` store, skipping
    unparseable files. Reads ONLY the workspace-root store, never a per-task
    worktree, so the result is branch/worktree independent (AC1). Sorted by
    (created_at, id) ascending."""
    from mship.core.spec_store import SpecParseError, parse_spec
    if not specs_dir.is_dir():
        return []
    out: list[Spec] = []
    for p in sorted(specs_dir.glob("*.md")):
        try:
            out.append(parse_spec(p.read_text()))
        except SpecParseError:
            continue
    return sorted(out, key=_sort_key)


@dataclass(frozen=True)
class SpecSelector:
    work_item_id: str | None = None
    status: str | None = None


def select_default(specs: list[Spec]) -> Spec:
    """Documented default when `mship view spec` gets no selector: the most
    recently CREATED non-archived spec (created_at, then id), from the canonical
    store. Deterministic — never filesystem mtime (AC2)."""
    pool = [s for s in specs if s.status != "archived"] or list(specs)
    if not pool:
        raise SpecSelectionError("No specs in the canonical store.")
    return max(pool, key=_sort_key)


def select_by_status(specs: list[Spec], status: str) -> Spec:
    matches = [s for s in specs if s.status == status]
    if not matches:
        raise SpecSelectionError(f"No spec with status {status!r} in the canonical store.")
    return max(matches, key=_sort_key)


def select_by_workitem(specs: list[Spec], workitems: list[WorkItem], work_item_id: str) -> Spec:
    item = next((w for w in workitems if w.id == work_item_id), None)
    if item is None:
        raise SpecSelectionError(f"Unknown work item: {work_item_id!r}")
    if item.spec_id is None:
        raise SpecSelectionError(f"Work item {work_item_id!r} has no linked spec.")
    spec = next((s for s in specs if s.id == item.spec_id), None)
    if spec is None:
        raise SpecSelectionError(
            f"Work item {work_item_id!r} links spec {item.spec_id!r}, absent from the store."
        )
    return spec


def select_spec(specs: list[Spec], workitems: list[WorkItem], selector: SpecSelector) -> Spec:
    """Resolve one spec per `selector` (AC2). Precedence: work item > status >
    deterministic default. Raises SpecSelectionError on no match."""
    if selector.work_item_id is not None:
        return select_by_workitem(specs, workitems, selector.work_item_id)
    if selector.status is not None:
        return select_by_status(specs, selector.status)
    return select_default(specs)
```

**Run (expect pass):** `uv run pytest tests/core/view/test_spec_selection.py -q`

**Commit:**
```
git add -A && git commit -m "core/view: canonical spec selection layer (AC2)"
mship journal "Add spec_selection: select by workitem/status + deterministic default (AC2)" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=2 -->
## Task 2 — Canonical read is branch/worktree independent (AC1)

**Files:**
- `tests/core/view/test_spec_selection.py` (modify — append)

**Failing test** — append to `tests/core/view/test_spec_selection.py`:
```python
from mship.core.spec_store import SpecStore
from mship.core.view.spec_selection import load_canonical_specs


def _seed(store_dir, spec_id, *, created):
    store = SpecStore(store_dir)
    return store.save(Spec(id=spec_id, title=spec_id, status="draft",
                           created_at=created, updated_at=created,
                           body=f"Body of {spec_id}\n"))


def test_load_canonical_specs_reads_only_the_workspace_store(tmp_path):
    # Canonical store at <root>/specs.
    _seed(tmp_path / "specs", "canonical-one", created=_dt(3))
    # A task worktree with its OWN legacy specs dir that must be ignored (AC1).
    wt_specs = tmp_path / "wt-feature" / "docs" / "superpowers" / "specs"
    wt_specs.mkdir(parents=True)
    (wt_specs / "worktree-only.md").write_text("# worktree only\n")

    specs = load_canonical_specs(tmp_path / "specs")
    assert [s.id for s in specs] == ["canonical-one"]


def test_load_canonical_specs_skips_unparseable(tmp_path):
    _seed(tmp_path / "specs", "good", created=_dt(2))
    (tmp_path / "specs" / "raw-no-frontmatter.md").write_text("# no frontmatter\n")
    assert [s.id for s in load_canonical_specs(tmp_path / "specs")] == ["good"]


def test_load_canonical_specs_missing_dir_is_empty(tmp_path):
    assert load_canonical_specs(tmp_path / "specs") == []


def test_select_default_over_canonical_store_round_trip(tmp_path):
    _seed(tmp_path / "specs", "older", created=_dt(1))
    _seed(tmp_path / "specs", "newest", created=_dt(8))
    specs = load_canonical_specs(tmp_path / "specs")
    assert select_default(specs).id == "newest"
```

**Run (expect fail):** `uv run pytest tests/core/view/test_spec_selection.py -k canonical -q`
Expected failure: `ImportError: cannot import name 'load_canonical_specs'` (it does not yet exist in the module you import here) — or, if Task 1 already landed the symbol, the assertion `["canonical-one"]` proving the worktree dir is ignored is the load-bearing new coverage; run first to confirm red on the new file state.

> Note: `load_canonical_specs` is authored in Task 1's module body above; this task adds its AC1 test coverage. If executed strictly test-first, temporarily stub the function to `return []` to see red, then restore the Task 1 body to go green.

**Minimal implementation:** already provided by `load_canonical_specs` in `src/mship/core/view/spec_selection.py` (Task 1). No new production code; this task locks AC1's worktree-independence guarantee with tests.

**Run (expect pass):** `uv run pytest tests/core/view/test_spec_selection.py -q`

**Commit:**
```
git add -A && git commit -m "core/view: prove canonical spec read ignores worktrees (AC1)"
mship journal "Cover AC1: load_canonical_specs reads only <root>/specs, ignores worktree specs dirs" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=3 -->
## Task 3 — WorkItem/phase-aware header strings (AC9 pure)

**Files:**
- `src/mship/core/view/headers.py` (create)
- `tests/core/view/test_headers.py` (create)

**Failing test** — `tests/core/view/test_headers.py`:
```python
from datetime import datetime, timezone

from mship.core.workitem import WorkItem
from mship.core.view.workitem_index import build_workitem_index
from mship.core.view.headers import header_for_spec, header_for_task


def _now():
    return datetime(2026, 7, 1, tzinfo=timezone.utc)


def _index(**kw):
    base = dict(id="wi-1", title="View overhaul", workspace="ws", kind="feature",
                created_at=_now(), updated_at=_now())
    base.update(kw)
    return build_workitem_index([WorkItem(**base)], {}, {}, {})


def test_header_for_task_includes_workitem_and_phases():
    workitems = _index(task_slugs=["demo"])
    line = header_for_task("demo", "dev", workitems)
    assert "wi-1" in line
    assert "View overhaul" in line
    # WorkItem derived phase (no children -> inbox) and the task's own phase.
    assert "[inbox]" in line
    assert "demo" in line and "[dev]" in line


def test_header_for_task_none_when_task_unlinked():
    workitems = _index(task_slugs=["other"])
    assert header_for_task("demo", "dev", workitems) is None


def test_header_for_task_omits_task_phase_when_none():
    workitems = _index(task_slugs=["demo"])
    line = header_for_task("demo", None, workitems)
    assert "wi-1" in line
    assert "task demo" not in line


def test_header_for_spec_resolves_by_spec_id():
    workitems = _index(spec_id="spec-9")
    line = header_for_spec("spec-9", workitems)
    assert "wi-1" in line and "View overhaul" in line and "[inbox]" in line


def test_header_for_spec_none_when_unlinked():
    workitems = _index(spec_id="spec-9")
    assert header_for_spec("other-spec", workitems) is None
```

**Run (expect fail):** `uv run pytest tests/core/view/test_headers.py -q`
Expected failure: `ModuleNotFoundError: No module named 'mship.core.view.headers'`.

**Minimal implementation** — `src/mship/core/view/headers.py`:
```python
"""One-line WorkItem/phase-aware header strings for the view commands (AC9).

Pure: operate on the `WorkItemSummary` index (already carries derived `phase`,
`title`, `spec_id`, `task_slugs`). Return None when nothing links, so callers
simply omit the header and keep their current output.
"""
from __future__ import annotations

from mship.core.view.workitem_index import WorkItemSummary


def _base(wi: WorkItemSummary) -> str:
    parts = [f"◆ {wi.id}"]
    if wi.title:
        parts.append(wi.title)
    parts.append(f"[{wi.phase}]")
    return "  ·  ".join(parts)


def header_for_task(task_slug: str, task_phase: str | None,
                    workitems: list[WorkItemSummary]) -> str | None:
    """Header for a task-scoped view (journal, diff). None when the task belongs
    to no WorkItem. Appends the task's own phase when known."""
    wi = next((w for w in workitems if task_slug in w.task_slugs), None)
    if wi is None:
        return None
    line = _base(wi)
    if task_phase is not None:
        line += f"  —  task {task_slug} [{task_phase}]"
    return line


def header_for_spec(spec_id: str, workitems: list[WorkItemSummary]) -> str | None:
    """Header for the spec view: the WorkItem that links this spec. None when
    the spec is unlinked."""
    wi = next((w for w in workitems if w.spec_id == spec_id), None)
    return _base(wi) if wi is not None else None
```

**Run (expect pass):** `uv run pytest tests/core/view/test_headers.py -q`

**Commit:**
```
git add -A && git commit -m "core/view: WorkItem/phase header strings (AC9)"
mship journal "Add headers.py: header_for_task/header_for_spec pure builders (AC9)" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=4 -->
## Task 4 — Group task summaries under their WorkItem (AC5 pure)

**Files:**
- `src/mship/core/view/status_grouping.py` (create)
- `tests/core/view/test_status_grouping.py` (create)

**Failing test** — `tests/core/view/test_status_grouping.py`:
```python
from datetime import datetime, timezone

from mship.core.state import Task, WorkspaceState
from mship.core.workitem import WorkItem
from mship.core.view.task_index import build_task_index
from mship.core.view.workitem_index import build_workitem_index
from mship.core.view.status_grouping import WorkItemTaskGroup, group_tasks_by_workitem


def _now():
    return datetime(2026, 7, 1, tzinfo=timezone.utc)


def _task(slug, phase):
    return Task(slug=slug, description=slug, phase=phase, created_at=_now(),
                affected_repos=["r"], branch=f"feat/{slug}", worktrees={})


def _fixture(tmp_path):
    tasks = {"a": _task("a", "dev"), "b": _task("b", "review"), "c": _task("c", "plan")}
    state = WorkspaceState(tasks=tasks)
    index = build_task_index(state, tmp_path)
    wi = WorkItem(id="wi-1", title="Overhaul", workspace="ws", kind="feature",
                  created_at=_now(), updated_at=_now(), task_slugs=["a", "b"])
    workitems = build_workitem_index([wi], {}, tasks, {})
    return index, workitems


def test_groups_linked_tasks_under_workitem(tmp_path):
    index, workitems = _fixture(tmp_path)
    groups = group_tasks_by_workitem(index, workitems)
    assert isinstance(groups[0], WorkItemTaskGroup)
    assert groups[0].work_item_id == "wi-1"
    assert {t.slug for t in groups[0].tasks} == {"a", "b"}
    assert groups[0].title == "Overhaul"
    assert groups[0].phase == "in_flight"  # a running task -> in_flight


def test_unlinked_tasks_fall_into_trailing_none_group(tmp_path):
    index, workitems = _fixture(tmp_path)
    groups = group_tasks_by_workitem(index, workitems)
    tail = groups[-1]
    assert tail.work_item_id is None
    assert [t.slug for t in tail.tasks] == ["c"]


def test_each_task_retains_its_own_phase(tmp_path):
    index, workitems = _fixture(tmp_path)
    groups = group_tasks_by_workitem(index, workitems)
    phases = {t.slug: t.phase for g in groups for t in g.tasks}
    assert phases == {"a": "dev", "b": "review", "c": "plan"}


def test_no_workitems_yields_single_ungrouped_bucket(tmp_path):
    index, _ = _fixture(tmp_path)
    groups = group_tasks_by_workitem(index, [])
    assert len(groups) == 1
    assert groups[0].work_item_id is None
    assert {t.slug for t in groups[0].tasks} == {"a", "b", "c"}
```

**Run (expect fail):** `uv run pytest tests/core/view/test_status_grouping.py -q`
Expected failure: `ModuleNotFoundError: No module named 'mship.core.view.status_grouping'`.

**Minimal implementation** — `src/mship/core/view/status_grouping.py`:
```python
"""Group task summaries under their WorkItem for `mship view status` (AC5).

Pure: takes the task index (list[TaskSummary]) and the WorkItem index
(list[WorkItemSummary]) and returns ordered groups. Tasks keep their own phase;
the group header carries the WorkItem's derived phase.
"""
from __future__ import annotations

from dataclasses import dataclass

from mship.core.view.task_index import TaskSummary
from mship.core.view.workitem_index import WorkItemSummary


@dataclass(frozen=True)
class WorkItemTaskGroup:
    work_item_id: str | None
    title: str | None
    phase: str | None
    tasks: list[TaskSummary]


def group_tasks_by_workitem(
    tasks: list[TaskSummary],
    workitems: list[WorkItemSummary],
) -> list[WorkItemTaskGroup]:
    """Group tasks under their WorkItem. WorkItem order follows `workitems`
    (already active-before-done from build_workitem_index); tasks linked to no
    WorkItem fall into a single trailing group with work_item_id=None. Each task
    keeps its own `phase` (rendered by the caller)."""
    by_slug = {t.slug: t for t in tasks}
    groups: list[WorkItemTaskGroup] = []
    claimed: set[str] = set()
    for wi in workitems:
        members = [by_slug[s] for s in wi.task_slugs if s in by_slug]
        if not members:
            continue
        claimed.update(t.slug for t in members)
        groups.append(WorkItemTaskGroup(
            work_item_id=wi.id, title=wi.title, phase=wi.phase, tasks=members,
        ))
    ungrouped = [t for t in tasks if t.slug not in claimed]
    if ungrouped:
        groups.append(WorkItemTaskGroup(
            work_item_id=None, title=None, phase=None, tasks=ungrouped,
        ))
    return groups
```

**Run (expect pass):** `uv run pytest tests/core/view/test_status_grouping.py -q`

**Commit:**
```
git add -A && git commit -m "core/view: group tasks under their WorkItem (AC5)"
mship journal "Add status_grouping: group_tasks_by_workitem pure layer (AC5)" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=5 -->
## Task 5 — Shared CLI helper: build the WorkItem index from the canonical stores

**Files:**
- `src/mship/cli/view/_workitems.py` (create)
- `tests/cli/view/test_workitems_helper.py` (create)

**Failing test** — `tests/cli/view/test_workitems_helper.py`:
```python
from datetime import datetime, timezone

from mship.cli import container
from mship.core.spec import Spec
from mship.core.spec_store import SPECS_DIRNAME, SpecStore
from mship.core.state import StateManager, Task, WorkspaceState
from mship.core.workitem import WorkItem
from mship.core.workitem_store import WorkItemStore
from mship.cli.view._workitems import load_workitem_index


def _now():
    return datetime(2026, 7, 1, tzinfo=timezone.utc)


def _setup(tmp_path):
    state_dir = tmp_path / ".mothership"
    state_dir.mkdir()
    cfg = tmp_path / "mothership.yaml"
    cfg.write_text("workspace: t\nrepos: {}\n")

    SpecStore(tmp_path / SPECS_DIRNAME).save(Spec(
        id="spec-1", title="Overhaul", status="approved",
        created_at=_now(), updated_at=_now(), body="b\n"))
    WorkItemStore(state_dir / "workitems").save(WorkItem(
        id="wi-1", title="Overhaul", workspace="t", kind="feature",
        created_at=_now(), updated_at=_now(), spec_id="spec-1", task_slugs=["a"]))
    StateManager(state_dir).save(WorkspaceState(tasks={"a": Task(
        slug="a", description="d", phase="dev", created_at=_now(),
        affected_repos=["r"], branch="feat/a", worktrees={}, work_item_id="wi-1")}))

    container.config.reset()
    container.state_manager.reset()
    container.config_path.override(cfg)
    container.state_dir.override(state_dir)


def _teardown():
    container.config_path.reset_override()
    container.state_dir.reset_override()
    container.config.reset_override()
    container.config.reset()
    container.state_manager.reset_override()
    container.state_manager.reset()


def test_load_workitem_index_builds_from_canonical_stores(tmp_path):
    _setup(tmp_path)
    try:
        index = load_workitem_index(container)
        assert [s.id for s in index] == ["wi-1"]
        s = index[0]
        assert s.task_slugs == ["a"]
        assert s.spec_id == "spec-1"
        # approved spec + one unfinished task -> in_flight (build_workitem_index).
        assert s.phase == "in_flight"
    finally:
        _teardown()


def test_load_workitem_index_empty_workspace_is_empty(tmp_path):
    state_dir = tmp_path / ".mothership"
    state_dir.mkdir()
    cfg = tmp_path / "mothership.yaml"
    cfg.write_text("workspace: t\nrepos: {}\n")
    StateManager(state_dir).save(WorkspaceState(tasks={}))
    container.config.reset()
    container.state_manager.reset()
    container.config_path.override(cfg)
    container.state_dir.override(state_dir)
    try:
        assert load_workitem_index(container) == []
    finally:
        _teardown()
```

**Run (expect fail):** `uv run pytest tests/cli/view/test_workitems_helper.py -q`
Expected failure: `ModuleNotFoundError: No module named 'mship.cli.view._workitems'`.

**Minimal implementation** — `src/mship/cli/view/_workitems.py`:
```python
"""Shared view-CLI helper: build the WorkItem summary index from the workspace-
canonical stores. Reused by status/journal/diff/spec so each command wires the
same phase-aware index (headers, grouping) without duplicating store wiring."""
from __future__ import annotations

from pathlib import Path

from mship.core.message_store import MessageStore
from mship.core.spec_store import SPECS_DIRNAME, SpecStore
from mship.core.view.workitem_index import WorkItemSummary, build_workitem_index
from mship.core.workitem_store import WorkItemStore


def load_workitem_index(container) -> list[WorkItemSummary]:
    """Build the WorkItem index (derived phase + attention + task_slugs + spec_id)
    from the canonical stores under the workspace root and state dir. Best-effort:
    any store-scan failure degrades to an empty index so a view never crashes."""
    try:
        state_dir = Path(container.state_dir())
        workspace_root = Path(container.config_path()).parent
        items = WorkItemStore(state_dir / "workitems")
        specs = SpecStore(workspace_root / SPECS_DIRNAME)
        msgs = MessageStore(state_dir / "messages")
        return build_workitem_index(
            items.list(),
            {s.id: s for s in specs.list()},
            dict(container.state_manager().load().tasks),
            {t.id: t for t in msgs.list()},
        )
    except Exception:
        return []
```

**Run (expect pass):** `uv run pytest tests/cli/view/test_workitems_helper.py -q`

**Commit:**
```
git add -A && git commit -m "cli/view: shared load_workitem_index helper"
mship journal "Add cli/view/_workitems.load_workitem_index shared helper" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=6 -->
## Task 6 — `mship view spec`: canonical selection + WorkItem header (AC1, AC2, AC9-spec)

**Files:**
- `src/mship/cli/view/spec.py` (modify)
- `tests/cli/view/test_spec_view.py` (modify — append)

**Failing test** — append to `tests/cli/view/test_spec_view.py`:
```python
# --- PR1: canonical selection (AC1, AC2) + spec header (AC9) ---
from mship.core.spec import Spec as _Spec
from mship.core.spec_store import SPECS_DIRNAME as _SPECS_DIRNAME, SpecStore as _SpecStore
from mship.core.state import Task as _Task
from mship.core.workitem import WorkItem as _WorkItem
from mship.core.workitem_store import WorkItemStore as _WorkItemStore


def _seed_canonical(tmp_path, spec_id, *, status="draft", day=1, body="", wi_id=None):
    now = datetime(2026, 7, day, tzinfo=timezone.utc)
    _SpecStore(tmp_path / _SPECS_DIRNAME).save(_Spec(
        id=spec_id, title=spec_id, status=status,
        created_at=now, updated_at=now, body=body))
    if wi_id is not None:
        _WorkItemStore(tmp_path / ".mothership" / "workitems").save(_WorkItem(
            id=wi_id, title=spec_id, workspace="t", kind="feature",
            created_at=now, updated_at=now, spec_id=spec_id))


def test_spec_cli_selects_by_workitem(tmp_path):
    runner = CliRunner()
    _setup_workspace(tmp_path)
    _seed_canonical(tmp_path, "spec-wi", body="Canonical body for wi-7\n", wi_id="wi-7")
    _seed_canonical(tmp_path, "spec-other", day=9, body="Other body\n")
    try:
        result = runner.invoke(app, ["view", "spec", "--workitem", "wi-7"])
        assert result.exit_code == 0, result.output
        assert "Canonical body for wi-7" in result.output
        assert "Other body" not in result.output
    finally:
        _reset_overrides()


def test_spec_cli_selects_by_status(tmp_path):
    runner = CliRunner()
    _setup_workspace(tmp_path)
    _seed_canonical(tmp_path, "spec-review", status="needs_review", body="Review me\n")
    _seed_canonical(tmp_path, "spec-approved", status="approved", day=9, body="Approved\n")
    try:
        result = runner.invoke(app, ["view", "spec", "--status", "needs_review"])
        assert result.exit_code == 0, result.output
        assert "Review me" in result.output
        assert "Approved" not in result.output
    finally:
        _reset_overrides()


def test_spec_cli_default_is_newest_by_created_at(tmp_path):
    runner = CliRunner()
    _setup_workspace(tmp_path)
    _seed_canonical(tmp_path, "spec-old", day=1, body="Old body\n")
    _seed_canonical(tmp_path, "spec-new", day=9, body="Newest body\n")
    try:
        result = runner.invoke(app, ["view", "spec"])
        assert result.exit_code == 0, result.output
        assert "Newest body" in result.output
    finally:
        _reset_overrides()


def test_spec_cli_default_ignores_task_worktree(tmp_path):
    """AC1: a spec that lives only in the canonical <root>/specs store renders
    even though the (only) task's worktree has no specs dir."""
    runner = CliRunner()
    _setup_workspace(tmp_path)
    wt = tmp_path / "wt-feature"
    wt.mkdir()
    StateManager(tmp_path / ".mothership").save(WorkspaceState(tasks={"a": _Task(
        slug="a", description="d", phase="dev",
        created_at=datetime(2026, 7, 1, tzinfo=timezone.utc),
        affected_repos=["r"], branch="feat/a", worktrees={"r": wt})}))
    _seed_canonical(tmp_path, "spec-canonical", body="Only in canonical store\n")
    try:
        result = runner.invoke(app, ["view", "spec"])
        assert result.exit_code == 0, result.output
        assert "Only in canonical store" in result.output
    finally:
        _reset_overrides()


def test_spec_cli_workitem_status_mutually_exclusive(tmp_path):
    runner = CliRunner()
    _setup_workspace(tmp_path)
    try:
        result = runner.invoke(app, ["view", "spec", "--workitem", "x", "--status", "y"])
        assert result.exit_code != 0
        assert "mutually exclusive" in result.output.lower()
    finally:
        _reset_overrides()


def test_spec_cli_unknown_workitem_exits_1(tmp_path):
    runner = CliRunner()
    _setup_workspace(tmp_path)
    _seed_canonical(tmp_path, "spec-x", body="x\n")
    try:
        result = runner.invoke(app, ["view", "spec", "--workitem", "wi-missing"])
        assert result.exit_code == 1, result.output
        assert "wi-missing" in result.output
    finally:
        _reset_overrides()


@pytest.mark.asyncio
async def test_spec_view_renders_workitem_header(tmp_path):
    specs = tmp_path / "docs" / "superpowers" / "specs"
    specs.mkdir(parents=True)
    (specs / "s.md").write_text("# Hello\n\nBody text.\n")
    view = SpecView(
        workspace_root=tmp_path, name_or_path=None,
        header_provider=lambda: "◆ wi-1  ·  Overhaul  ·  [ready]",
        watch=False, interval=1.0,
    )
    async with view.run_test() as pilot:
        await pilot.pause()
        text = view.rendered_text()
        assert "wi-1" in text and "Overhaul" in text
        assert "Body text" in text
```

**Run (expect fail):** `uv run pytest tests/cli/view/test_spec_view.py -k "workitem or status or default_is_newest or ignores_task or header" -q`
Expected failure: `--workitem`/`--status` are unknown options (Typer usage error, non-zero) and `SpecView.__init__() got an unexpected keyword argument 'header_provider'`.

**Minimal implementation** — in `src/mship/cli/view/spec.py`:

1. Add `header_provider` to `SpecView.__init__` (new explicit param) and store it:
```python
    def __init__(
        self,
        workspace_root: Path,
        name_or_path: Optional[str],
        *,
        task: Optional[str] = None,
        state_manager=None,
        state=None,
        log_manager=None,
        cli_task: Optional[str] = None,
        cwd: Optional[Path] = None,
        header_provider=None,
        **kw,
    ):
        for k in ("workspace_root", "name_or_path", "task",
                  "state_manager", "state", "log_manager",
                  "cli_task", "cwd", "header_provider"):
            kw.pop(k, None)
        super().__init__(**kw)
        ...
        self._header_provider = header_provider
```

2. In `SpecView._refresh_content`, prepend the header in the success branch (replace the three lines that set `source`):
```python
            source = path.read_text()
            header = self._header_provider() if self._header_provider else None
            if header:
                source = f"**{header}**\n\n{source}"
            self._last_source = source
            self._last_error = ""
            self._markdown.update(source)
            self._error_static.update("")
```

3. In the `spec` command, add options and canonical resolution. Add to the signature:
```python
        workitem: Optional[str] = typer.Option(None, "--workitem", help="Select the spec linked to this WorkItem id"),
        status: Optional[str] = typer.Option(None, "--status", help="Select the newest spec with this status"),
```
Then, immediately after `state = container.state_manager().load()` (and before the existing task-resolution block), insert:
```python
        from mship.core.spec_store import SpecStore, SPECS_DIRNAME
        from mship.core.workitem_store import WorkItemStore
        from mship.core.view.spec_selection import (
            SpecSelectionError, SpecSelector, load_canonical_specs, select_spec,
        )
        from mship.core.view.headers import header_for_spec
        from mship.cli.view._workitems import load_workitem_index

        active_selectors = [n for n, v in (("--workitem", workitem), ("--status", status)) if v is not None]
        if len(active_selectors) > 1:
            typer.echo("Error: --workitem and --status are mutually exclusive.", err=True)
            raise typer.Exit(code=1)
        if active_selectors and name_or_path is not None:
            typer.echo(f"Error: {active_selectors[0]} and an explicit spec name are mutually exclusive.", err=True)
            raise typer.Exit(code=1)
        if active_selectors and task is not None:
            typer.echo(f"Error: {active_selectors[0]} and --task are mutually exclusive.", err=True)
            raise typer.Exit(code=1)

        specs_dir = workspace_root / SPECS_DIRNAME
        canonical_path: Optional[_P] = None
        canonical_spec_id: Optional[str] = None
        selector: Optional[SpecSelector] = None
        if active_selectors:
            selector = SpecSelector(work_item_id=workitem, status=status)
        elif name_or_path is None and task is None and load_canonical_specs(specs_dir):
            # AC1/AC2: deterministic canonical default (newest by created_at), not
            # worktree/mtime. Only engages when the canonical store has real specs;
            # otherwise fall through to the legacy task/worktree resolution below.
            selector = SpecSelector()
        if selector is not None:
            items = WorkItemStore(_P(container.state_dir()) / "workitems")
            try:
                spec = select_spec(load_canonical_specs(specs_dir), items.list(), selector)
            except SpecSelectionError as e:
                typer.echo(f"Error: {e}", err=True)
                raise typer.Exit(code=1)
            canonical_path = SpecStore(specs_dir).path_for(spec)
            canonical_spec_id = spec.id
```
Guard the existing task-resolution block with `if canonical_path is None:` (so `resolved_task_slug`/`cli_task_for_view` are computed only on the legacy path). Then thread `canonical_path` into the three existing render branches:
```python
        if web:
            try:
                path = canonical_path or find_spec(workspace_root, name_or_path, task=resolved_task_slug, state=state)
            except SpecNotFoundError as e:
                typer.echo(f"Error: {e}", err=True)
                raise typer.Exit(code=1)
            _serve_web(path, port)
            return

        from mship.cli.output import Output
        if not Output().is_tty:
            try:
                path = canonical_path or find_spec(workspace_root, name_or_path, task=resolved_task_slug, state=state)
            except SpecNotFoundError as e:
                typer.echo(f"Error: {e}", err=True)
                raise typer.Exit(code=1)
            typer.echo(path.read_text(), nl=False)
            return

        header_provider = None
        if canonical_spec_id is not None:
            header_provider = lambda: header_for_spec(canonical_spec_id, load_workitem_index(container))
        view = SpecView(
            workspace_root=workspace_root,
            name_or_path=str(canonical_path) if canonical_path is not None else name_or_path,
            task=resolved_task_slug,
            state_manager=container.state_manager(),
            log_manager=container.log_manager(),
            cli_task=cli_task_for_view,
            cwd=_P.cwd(),
            header_provider=header_provider,
            watch=watch,
            interval=interval,
        )
        view.run()
```
(When `canonical_path` is set, `resolved_task_slug`/`cli_task_for_view` remain their initialized `None`, so the TUI renders the absolute canonical path directly via `find_spec`'s absolute-path short-circuit.)

**Run (expect pass):** `uv run pytest tests/cli/view/test_spec_view.py -q`

**Commit:**
```
git add -A && git commit -m "cli/view spec: canonical selection by workitem/status/default + header (AC1, AC2, AC9)"
mship journal "view spec: --workitem/--status + deterministic canonical default + WorkItem header (AC1/AC2/AC9)" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=7 -->
## Task 7 — `mship view status`: group tasks under their WorkItem (AC5)

**Files:**
- `src/mship/cli/view/status.py` (modify)
- `tests/cli/view/test_status_view.py` (modify — append)

**Failing test** — append to `tests/cli/view/test_status_view.py`:
```python
# --- PR1: WorkItem grouping (AC5) ---
from mship.core.workitem import WorkItem as _WorkItem
from mship.core.view.workitem_index import build_workitem_index as _bwi


def test_status_view_groups_tasks_under_workitem(tmp_path):
    from mship.cli.view.status import StatusView
    now = datetime.now(timezone.utc)
    tasks = {"a": _task("a", phase="dev"), "b": _task("b", phase="review"),
             "c": _task("c", phase="plan")}

    class SM:
        def load(self):
            return WorkspaceState(tasks=tasks)

    wi = _WorkItem(id="wi-1", title="Overhaul", workspace="ws", kind="feature",
                   created_at=now, updated_at=now, task_slugs=["a", "b"])
    workitems = _bwi([wi], {}, tasks, {})

    view = StatusView(state_manager=SM(), workspace_root=tmp_path, task_filter=None,
                      workitem_loader=lambda: workitems)
    text = view.gather()
    assert "wi-1" in text and "Overhaul" in text
    # Grouped tasks appear with their own phase lines.
    assert "Task:   a" in text and "Task:   b" in text
    assert "Phase:  dev" in text and "Phase:  review" in text
    # Unlinked task 'c' still shown (trailing ungrouped block).
    assert "Task:   c" in text


def test_status_view_without_loader_is_flat(tmp_path):
    from mship.cli.view.status import StatusView

    class SM:
        def load(self):
            return WorkspaceState(tasks={"a": _task("a"), "b": _task("b")})

    view = StatusView(state_manager=SM(), workspace_root=tmp_path, task_filter=None)
    text = view.gather()
    assert "Task:   a" in text and "Task:   b" in text
    assert "◆" not in text  # no WorkItem header without a loader
```

**Run (expect fail):** `uv run pytest tests/cli/view/test_status_view.py -k "groups_tasks or without_loader" -q`
Expected failure: `StatusView.__init__() got an unexpected keyword argument 'workitem_loader'`.

**Minimal implementation** — in `src/mship/cli/view/status.py`:

1. Import and add a group-header renderer at module level:
```python
from mship.core.view.status_grouping import WorkItemTaskGroup, group_tasks_by_workitem


def _render_group_header(group: WorkItemTaskGroup) -> str:
    title = group.title or "(untitled)"
    return f"◆ {group.work_item_id}  ·  {title}  ·  [{group.phase}]"
```

2. Accept the loader in `StatusView.__init__`:
```python
    def __init__(self, state_manager, workspace_root: Path, task_filter: Optional[str],
                 log_manager=None, workitem_loader=None, **kw):
        super().__init__(**kw)
        self._state_manager = state_manager
        self._workspace_root = workspace_root
        self._task_filter = task_filter
        self._log_manager = log_manager
        self._workitem_loader = workitem_loader
```

3. Replace the all-tasks branch of `gather()` (the `index = build_task_index(...)` tail) with grouped rendering:
```python
        index = build_task_index(state, self._workspace_root)
        if not index:
            return "No tasks. Run `mship spawn \"…\"` to start one."
        workitems = self._workitem_loader() if self._workitem_loader is not None else []
        groups = group_tasks_by_workitem(index, workitems)
        blocks: list[str] = []
        for g in groups:
            body = "\n\n─────────────\n\n".join(
                _render_task(state.tasks[t.slug], self._open_questions(t.slug)) for t in g.tasks
            )
            blocks.append(f"{_render_group_header(g)}\n\n{body}" if g.work_item_id is not None else body)
        return "\n\n═════════════\n\n".join(blocks)
```

4. Wire the loader in `register`:
```python
        from mship.cli.view._workitems import load_workitem_index
        view = StatusView(
            state_manager=container.state_manager(),
            workspace_root=workspace_root,
            task_filter=task_slug,
            log_manager=container.log_manager(),
            workitem_loader=lambda: load_workitem_index(container),
            watch=watch,
            interval=interval,
        )
```

**Run (expect pass):** `uv run pytest tests/cli/view/test_status_view.py -q`

**Commit:**
```
git add -A && git commit -m "cli/view status: group tasks under their WorkItem (AC5)"
mship journal "view status: group tasks under WorkItem with per-task phase (AC5)" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=8 -->
## Task 8 — `mship view journal`: WorkItem/phase header (AC9)

**Files:**
- `src/mship/cli/view/logs.py` (modify)
- `tests/cli/view/test_logs_view.py` (modify — append)

**Failing test** — append to `tests/cli/view/test_logs_view.py`:
```python
# --- PR1: WorkItem/phase header (AC9) ---
from datetime import datetime as _dt, timezone as _tz

from mship.core.workitem import WorkItem as _WorkItem
from mship.core.view.workitem_index import build_workitem_index as _bwi


class _HeaderTask:
    def __init__(self, slug, phase):
        self.slug = slug
        self.phase = phase


class _HeaderState:
    def __init__(self, task):
        self.tasks = {task.slug: task}


class _HeaderStateMgr:
    def __init__(self, task):
        self._task = task

    def load(self):
        return _HeaderState(self._task)


def test_journal_prepends_workitem_header():
    now = _dt(2026, 7, 1, tzinfo=_tz.utc)
    entries = [_Entry(now, "did a thing")]
    wi = _WorkItem(id="wi-1", title="Overhaul", workspace="ws", kind="feature",
                   created_at=now, updated_at=now, task_slugs=["t1"])
    workitems = _bwi([wi], {}, {}, {})
    view = LogsView(
        state_manager=_HeaderStateMgr(_HeaderTask("t1", "dev")),
        log_manager=_FakeLogMgr(entries),
        task_slug="t1",
        workitem_loader=lambda: workitems,
        watch=False, interval=1.0,
    )
    text = view.gather()
    assert "wi-1" in text and "Overhaul" in text
    assert "task t1 [dev]" in text
    assert "did a thing" in text  # journal body preserved


def test_journal_no_header_without_loader():
    now = _dt(2026, 7, 1, tzinfo=_tz.utc)
    view = LogsView(
        state_manager=_FakeStateMgr(),
        log_manager=_FakeLogMgr([_Entry(now, "hello")]),
        task_slug="t1",
        watch=False, interval=1.0,
    )
    text = view.gather()
    assert "◆" not in text
    assert "hello" in text
```

**Run (expect fail):** `uv run pytest tests/cli/view/test_logs_view.py -k "workitem_header or no_header" -q`
Expected failure: `LogsView.__init__() got an unexpected keyword argument 'workitem_loader'`.

**Minimal implementation** — in `src/mship/cli/view/logs.py`:

1. Import the header builder:
```python
from mship.core.view.headers import header_for_task
```

2. Accept the loader in `LogsView.__init__` (add to the keyword-only section) and store it:
```python
        all_: bool = False,
        cli_task: Optional[str] = None,
        cwd: Optional[Path] = None,
        workitem_loader=None,
        **kw,
    ):
        super().__init__(**kw)
        ...
        self._cwd = cwd if cwd is not None else Path.cwd()
        self._workitem_loader = workitem_loader
```

3. Add a header helper and prepend it in `gather()`. Replace the two return sites (`f"Log for {slug} is empty"` and `"\n".join(lines)`) with a single `body`/header return:
```python
    def _header(self, slug: str) -> str | None:
        if self._workitem_loader is None:
            return None
        task = self._state_manager.load().tasks.get(slug)
        phase = getattr(task, "phase", None) if task is not None else None
        return header_for_task(slug, phase, self._workitem_loader())
```
and at the end of `gather()`:
```python
        if not entries:
            body = f"Log for {slug} is empty"
        else:
            lines = []
            for entry in entries:
                ...
            body = "\n".join(lines)
        header = self._header(slug)
        return f"{header}\n\n{body}" if header else body
```

4. Wire the loader in `register` (both the watch and non-watch construction go through one `LogsView(...)`):
```python
        from mship.cli.view._workitems import load_workitem_index
        view = LogsView(
            state_manager=container.state_manager(),
            log_manager=container.log_manager(),
            task_slug=task_slug,
            scope_to_repo=scope,
            all_=all_,
            cli_task=cli_task,
            cwd=Path.cwd(),
            workitem_loader=lambda: load_workitem_index(container),
            watch=watch,
            interval=interval,
        )
```

**Run (expect pass):** `uv run pytest tests/cli/view/test_logs_view.py -q`

**Commit:**
```
git add -A && git commit -m "cli/view journal: WorkItem/phase-aware header (AC9)"
mship journal "view journal: prepend WorkItem/phase header, body unchanged (AC9)" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=9 -->
## Task 9 — `mship view diff`: WorkItem/phase header (AC9)

**Files:**
- `src/mship/cli/view/diff.py` (modify)
- `tests/cli/view/test_diff_view.py` (modify — append)

**Failing test** — append to `tests/cli/view/test_diff_view.py`:
```python
# --- PR1: WorkItem/phase header (AC9) ---
@pytest.mark.asyncio
async def test_diff_view_renders_workitem_header(tmp_path):
    wa = tmp_path / "a"
    view = DiffView(
        worktree_paths=[wa], use_delta=False,
        header_provider=lambda: "◆ wi-1  ·  Overhaul  ·  [in_flight]  —  task a [dev]",
        watch=False, interval=1.0,
    )
    _seed(view, {wa: [_fd("f.py", "diff --git a/f.py b/f.py\n+++ b/f.py\n+x\n")]})
    async with view.run_test() as pilot:
        await pilot.pause()
        assert "wi-1" in view.header_text()
        assert "Overhaul" in view.header_text()
        # Tree/diff still populated as before.
        assert any("f.py" in l for l in view.tree_labels())


@pytest.mark.asyncio
async def test_diff_view_no_header_by_default(tmp_path):
    wa = tmp_path / "a"
    view = DiffView(worktree_paths=[wa], use_delta=False, watch=False, interval=1.0)
    _seed(view, {wa: [_fd("f.py", "diff --git a/f.py b/f.py\n+++ b/f.py\n+x\n")]})
    async with view.run_test() as pilot:
        await pilot.pause()
        assert view.header_text() == ""
```

**Run (expect fail):** `uv run pytest tests/cli/view/test_diff_view.py -k "workitem_header or no_header" -q`
Expected failure: `DiffView.__init__() got an unexpected keyword argument 'header_provider'`.

**Minimal implementation** — in `src/mship/cli/view/diff.py`:

1. Accept `header_provider` in `DiffView.__init__`; add a header widget ref:
```python
    def __init__(
        self,
        worktree_paths: Iterable[Path] = (),
        use_delta: bool | None = None,
        scope_to_active_path: Path | None = None,
        resolve_paths: Callable[[], tuple[list[Path], Path | None]] | None = None,
        base_branch_by_path: dict[Path, str | None] | None = None,
        header_provider: Callable[[], str | None] | None = None,
        **kw,
    ):
        super().__init__(**kw)
        self._header_provider = header_provider
        ...
        # Widget refs (populated in compose)
        self._header: Static | None = None
        self._tree: Tree | None = None
        self._diff_static: Static | None = None
        self._diff_scroll: VerticalScroll | None = None
```

2. Yield the header Static above the Horizontal in `compose`:
```python
    def compose(self) -> ComposeResult:
        self._header = Static("")
        self._tree = Tree("diff", id="diff-tree")
        self._tree.root.expand()
        self._tree.show_root = False
        self._diff_static = Static("", expand=True)
        self._diff_scroll = VerticalScroll(self._diff_static)
        yield self._header
        yield Horizontal(self._tree, self._diff_scroll)
```

3. Populate it in `_refresh_content` (first lines of the method):
```python
    def _refresh_content(self) -> None:
        if self._header is not None:
            text = self._header_provider() if self._header_provider else None
            self._header.update(text or "")
        if self._resolve_paths is not None:
            ...
```

4. Add a test helper near `diff_text`:
```python
    def header_text(self) -> str:
        assert self._header is not None
        return str(self._header.content)
```

5. Wire the provider in `register` after `target_task = t.slug`:
```python
        from mship.cli.view._workitems import load_workitem_index
        from mship.core.view.headers import header_for_task

        def _header() -> str | None:
            fresh = state_mgr.load()
            task_obj = fresh.tasks.get(target_task)
            if task_obj is None:
                return None
            return header_for_task(target_task, task_obj.phase, load_workitem_index(container))

        view = DiffView(
            resolve_paths=_resolver,
            base_branch_by_path=base_by_path,
            header_provider=_header,
            watch=watch,
            interval=interval,
        )
```

**Run (expect pass):** `uv run pytest tests/cli/view/test_diff_view.py -q`

**Commit:**
```
git add -A && git commit -m "cli/view diff: WorkItem/phase-aware header (AC9)"
mship journal "view diff: header Static with WorkItem/phase, panes unchanged (AC9)" --action committed
```
<!-- /mship:task -->

---

## Self-Review

Run the full view suite before finishing: `uv run pytest tests/core/view tests/cli/view -q`.

**AC coverage map (PR1 scope = AC1, AC2, AC5, AC9):**
- **AC1 — canonical spec resolution regardless of branch/worktree:** Task 1 (`load_canonical_specs` reads only `<workspace_root>/specs`), Task 2 (test proving a task worktree's own specs dir is ignored), Task 6 (`test_spec_cli_default_ignores_task_worktree` — canonical spec renders with an active task whose worktree has no specs). Wired in `cli/view/spec.py` via `SpecStore(workspace_root / SPECS_DIRNAME)`, never a worktree path.
- **AC2 — select by WorkItem or status, deterministic default (not mtime):** Task 1 (`select_by_workitem`, `select_by_status`, `select_default` ordered by `created_at`+`id`), Task 6 CLI (`--workitem`, `--status`, `test_spec_cli_default_is_newest_by_created_at`, mutual-exclusivity + unknown-item error).
- **AC5 — status WorkItem-grouping with per-task phase:** Task 4 (`group_tasks_by_workitem`, each task keeps its phase; unlinked tasks trail in a `None` group), Task 7 (`StatusView` renders group headers + preserves per-task `Phase:` lines; flat when no loader).
- **AC9 — WorkItem/phase headers for journal, diff, and spec:** Task 3 (`header_for_task`, `header_for_spec` pure), Task 8 (journal header prepended, body unchanged), Task 9 (diff header Static, tree/diff unchanged), Task 6 (spec header via `SpecView.header_provider`). Existing behavior preserved because all header/loader params default to off, so every pre-PR1 test that constructs these views unchanged still passes.

Every PR1 AC maps to at least one pure-layer task plus its wiring task; the pure functions (`spec_selection`, `status_grouping`, `headers`) are all tested without driving Textual.

## Deferred to later PRs

This PR delivers only the data + rendering fixes. Explicitly out of scope and deferred: the master/detail TUI foundation (the two-pane navigable shell that replaces today's independent single-view `ViewApp` panes), the WorkItem "cockpit" detail view (spec + tasks + threads + phase timeline in one drill-down surface), the queue/decision view (a prioritized cross-workspace attention list driven by `Attention`), and inline actions (approve/dispatch/phase-nudge/answer-decision keybindings that mutate state from within the view). Those build on the `WorkItemSummary` index and pure selection/grouping/header functions introduced here, so PR1 intentionally leaves the existing `ViewApp` subclasses and their navigation model untouched.
