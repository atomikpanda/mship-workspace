# PR3 — `mship view queue` (attention/triage list)

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Feature:** `mship view queue` — a cross-workspace attention/triage list (specs needing review, blocked tasks, PRs awaiting action) built on the reusable `MasterDetailApp` foundation, with a pure assembly layer and a non-TTY text dump.

**Spec:** mship-view-needs-a-major-overhaul-to

**Goal:** Give the operator one navigable list of everything in the workspace that needs a human decision — each attention item a row with its own detail pane — sourced entirely from the canonical stores, with zero live `gh` calls. PR3 is READ-ONLY (navigate + view); inline actions come later.

**Architecture:**
- **Reuse, don't reinvent, the "attention" logic.** The canonical attention rollup already lives in `src/mship/core/view/workitem_index.py`: `compute_attention(spec, tasks, threads) -> Attention` (`needs_approval` = spec status `needs_review`; `blocked`/`blocked_tasks` = tasks with `blocked_reason`; `needs_review` = any task with `pr_urls`), carried on every `WorkItemSummary.attention`. This is exactly what the phone's Queue is assembled from (`serve.py` serves `/items` from `build_workitem_index`). The queue folds the same `WorkItemSummary` index (via PR1's `load_workitem_index`) — so the CLI queue and the phone Queue agree by construction.
- **Pure assembly layer + thin widget/CLI on top** — mirrors PR2's `workitem_cockpit.py` (pure `assemble_cockpit` + formatters + `render_text`) / `workitem.py` (thin `MasterDetailApp` subclass + Typer command) split. New `core/view/queue.py` folds `(summaries, tasks_by_slug)` into a flat `list[QueueItem]` (each tagged `spec-needs-review` / `blocked-task` / `pr-awaiting`), unit-tested with no Textual. New `cli/view/queue.py` maps those to `ListRow`s on `MasterDetailApp` and wires the Typer command with the non-TTY `Output().is_tty` short-circuit.
- **No live `gh` in a view.** Live PR state (open/merged/closed) is only ever resolved by `PrWatcher.check_once` (shells out to `gh` via `pr_manager.check_pr_state`) inside `mship serve`'s background loop — never in a read-only view. `Task.pr_urls` is recorded by `mship finish` at PR-open time. So the queue sources "has an open PR awaiting action" from **recorded state** (`Task.pr_urls`), not a live call. Once the PR merges and `mship close` drives the spec terminal, the work item's derived `phase` becomes `done`; the queue **gates on `summary.phase != "done"`**, so merged/closed PRs (and completed items generally) drop off automatically. This gate is also correct for the other kinds: a needs_review spec is non-done (`shaping`), a blocked task keeps its item `in_flight`.
- **Reuse `MasterDetailApp` unchanged.** No edits to `_master_detail.py`; `QueueView` only implements the `list_rows()` / `header_line()` hooks.

**Tech Stack:** Python 3.14, uv (`uv run pytest`), Typer, Textual (`MasterDetailApp` base), pytest (`pythonpath=["src"]`, `asyncio_mode=auto`), `typer.testing.CliRunner`, dependency-injector `container` (test overrides).

## File Structure (exact paths)

New files:
- `src/mship/core/view/queue.py` — pure assembly: `QueueItem`, `assemble_queue`, `queue_label` / `queue_detail` / `queue_header`, `render_text`.
- `src/mship/cli/view/queue.py` — thin: `build_rows`, `QueueView(MasterDetailApp)`, `_resolve_queue`, `register` (`mship view queue`).
- `tests/core/view/test_queue.py` — pure-model unit tests.
- `tests/cli/view/test_queue_view.py` — pilot widget tests + `CliRunner` command tests.

Modified files:
- `src/mship/cli/view/__init__.py` — import + `register` the queue command.
- `tests/cli/view/test_view_registration.py` — assert `queue` appears in `view --help`.

---

<!-- mship:task id=1 -->
## Task 1 — Pure `QueueItem` model + `assemble_queue` folds specs-needs-review

**Files:**
- `src/mship/core/view/queue.py` (new)
- `tests/core/view/test_queue.py` (new)

**Failing test** — `tests/core/view/test_queue.py`:
```python
from datetime import datetime, timezone

from mship.core.spec import Spec
from mship.core.state import Task
from mship.core.workitem import WorkItem
from mship.core.view.workitem_index import build_workitem_index
from mship.core.view.queue import assemble_queue


def _now():
    return datetime(2026, 7, 1, tzinfo=timezone.utc)


def _summary(spec=None, tasks=()):
    wi = WorkItem(
        id="wi-1", title="Overhaul", workspace="ws", kind="feature",
        created_at=_now(), updated_at=_now(),
        spec_id=(spec.id if spec else None),
        task_slugs=[t.slug for t in tasks],
    )
    return build_workitem_index(
        [wi],
        {spec.id: spec} if spec else {},
        {t.slug: t for t in tasks},
        {},
    )[0]


def _tasks_by_slug(*tasks):
    return {t.slug: t for t in tasks}


def test_needs_review_spec_becomes_a_spec_queue_item():
    spec = Spec(id="spec-1", title="Overhaul spec", status="needs_review",
                created_at=_now(), updated_at=_now(), body="b\n")
    summary = _summary(spec=spec)
    items = assemble_queue([summary], {})
    assert [i.kind for i in items] == ["spec-needs-review"]
    it = items[0]
    assert it.key == "spec:wi-1"
    assert it.spec_id == "spec-1"
    assert it.work_item_id == "wi-1"
    assert it.work_item_title == "Overhaul"
    assert it.workspace == "ws"


def test_approved_spec_is_not_in_queue():
    spec = Spec(id="spec-1", title="Overhaul spec", status="approved",
                created_at=_now(), updated_at=_now(), body="b\n")
    items = assemble_queue([_summary(spec=spec)], {})
    assert items == []
```

**Run (expect fail):** `uv run pytest tests/core/view/test_queue.py -q`
Expected: `ModuleNotFoundError: No module named 'mship.core.view.queue'` (module/symbol absent).

**Minimal implementation** — `src/mship/core/view/queue.py`:
```python
"""Pure assembly of the `mship view queue` attention/triage list (AC4).

Folds the WorkItem summary index (which already carries the canonical `Attention`
rollup from `compute_attention`) plus the workspace's `Task`s into a flat,
render-ready list of attention items: specs awaiting review, blocked tasks, and
PRs awaiting action. No Textual, no container, no store I/O — unit-testable
directly. The Textual `QueueView` and the CLI command wire thin on top; the
formatters below are shared by both the flat text renderer (non-TTY) and the TUI
row builder (mirrors workitem_cockpit's split).

READ-ONLY: PR-awaiting rows come from each task's RECORDED `pr_urls` (stamped by
`mship finish` at PR-open time), never a live `gh` call — live PR state is only
ever resolved by `mship serve`'s PrWatcher, never in a view. Completed work
(merged/closed PRs, implemented specs) drops off via the `phase != "done"` gate.
"""
from __future__ import annotations

from dataclasses import dataclass

from mship.core.state import Task
from mship.core.view.workitem_index import WorkItemSummary


@dataclass(frozen=True)
class QueueItem:
    """One attention item. `kind` is one of "spec-needs-review", "blocked-task",
    "pr-awaiting". `key` is stable + unique across the queue (ListRow.key). Every
    item carries its owning WorkItem context (id/title/phase/workspace); the
    kind-specific fields below are populated per kind."""
    kind: str
    key: str
    workspace: str
    work_item_id: str
    work_item_title: str
    phase: str
    spec_id: str | None = None
    task_slug: str | None = None
    blocked_reason: str | None = None
    repo: str | None = None
    pr_url: str | None = None


def assemble_queue(
    summaries: list[WorkItemSummary],
    tasks_by_slug: dict[str, Task],
) -> list[QueueItem]:
    """Fold the WorkItem index + tasks into the flat attention list (AC4).

    Grouped by kind (specs → blocked tasks → PRs); within a kind, WorkItem order
    is preserved (the index is already updated_at-desc). Done work items are
    skipped: a merged+closed PR / implemented spec derives `phase == "done"` and
    is no longer awaiting a human.
    """
    specs: list[QueueItem] = []
    for s in summaries:
        if s.phase == "done":
            continue
        if s.attention.needs_approval and s.spec_id is not None:
            specs.append(QueueItem(
                kind="spec-needs-review", key=f"spec:{s.id}",
                workspace=s.workspace, work_item_id=s.id,
                work_item_title=s.title, phase=s.phase, spec_id=s.spec_id,
            ))
    return specs
```

**Run (expect pass):** `uv run pytest tests/core/view/test_queue.py -q` → 2 passed.

**Commit:**
```
git add src/mship/core/view/queue.py tests/core/view/test_queue.py
git commit -m "queue: pure QueueItem model + assemble_queue folds needs_review specs (AC4)"
mship journal "PR3 T1: QueueItem + assemble_queue spec-needs-review folding, unit-tested off WorkItemSummary.attention" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=2 -->
## Task 2 — `assemble_queue` folds blocked tasks

**Files:**
- `src/mship/core/view/queue.py`
- `tests/core/view/test_queue.py`

**Failing test** — append to `tests/core/view/test_queue.py`:
```python
def test_blocked_task_becomes_a_blocked_queue_item():
    task = Task(slug="a", description="d", phase="dev", created_at=_now(),
                affected_repos=["r"], branch="feat/a",
                blocked_reason="waiting on API key")
    summary = _summary(tasks=[task])
    items = assemble_queue([summary], _tasks_by_slug(task))
    assert [i.kind for i in items] == ["blocked-task"]
    it = items[0]
    assert it.key == "block:a"
    assert it.task_slug == "a"
    assert it.blocked_reason == "waiting on API key"
    assert it.work_item_id == "wi-1"


def test_unblocked_task_is_not_in_queue():
    task = Task(slug="a", description="d", phase="dev", created_at=_now(),
                affected_repos=["r"], branch="feat/a")
    summary = _summary(tasks=[task])
    assert assemble_queue([summary], _tasks_by_slug(task)) == []
```

**Run (expect fail):** `uv run pytest tests/core/view/test_queue.py -q`
Expected: `test_blocked_task_becomes_a_blocked_queue_item` fails (`assert [] == ["blocked-task"]`) — blocked branch not yet implemented.

**Minimal implementation** — extend `assemble_queue` in `src/mship/core/view/queue.py` (add a `blocked` accumulator + the per-task loop; return `specs + blocked`):
```python
def assemble_queue(
    summaries: list[WorkItemSummary],
    tasks_by_slug: dict[str, Task],
) -> list[QueueItem]:
    specs: list[QueueItem] = []
    blocked: list[QueueItem] = []
    for s in summaries:
        if s.phase == "done":
            continue
        if s.attention.needs_approval and s.spec_id is not None:
            specs.append(QueueItem(
                kind="spec-needs-review", key=f"spec:{s.id}",
                workspace=s.workspace, work_item_id=s.id,
                work_item_title=s.title, phase=s.phase, spec_id=s.spec_id,
            ))
        for slug in s.task_slugs:
            task = tasks_by_slug.get(slug)
            if task is None:
                continue
            if task.blocked_reason is not None:
                blocked.append(QueueItem(
                    kind="blocked-task", key=f"block:{slug}",
                    workspace=s.workspace, work_item_id=s.id,
                    work_item_title=s.title, phase=s.phase,
                    task_slug=slug, blocked_reason=task.blocked_reason,
                ))
    return specs + blocked
```

**Run (expect pass):** `uv run pytest tests/core/view/test_queue.py -q` → 4 passed.

**Commit:**
```
git add src/mship/core/view/queue.py tests/core/view/test_queue.py
git commit -m "queue: fold blocked tasks (Task.blocked_reason) into the attention list (AC4)"
mship journal "PR3 T2: assemble_queue folds blocked tasks from Task.blocked_reason via summary.task_slugs" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=3 -->
## Task 3 — `assemble_queue` folds PRs awaiting action + `phase != "done"` exclusion + ordering

**Files:**
- `src/mship/core/view/queue.py`
- `tests/core/view/test_queue.py`

**Failing test** — append to `tests/core/view/test_queue.py`:
```python
def test_recorded_pr_urls_become_pr_queue_items():
    task = Task(slug="a", description="d", phase="review", created_at=_now(),
                affected_repos=["r"], branch="feat/a",
                pr_urls={"r": "https://gh/pr/1"}, finished_at=_now())
    summary = _summary(tasks=[task])
    items = assemble_queue([summary], _tasks_by_slug(task))
    assert [i.kind for i in items] == ["pr-awaiting"]
    it = items[0]
    assert it.key == "pr:a:r"
    assert it.repo == "r"
    assert it.pr_url == "https://gh/pr/1"
    assert it.task_slug == "a"


def test_done_workitem_prs_are_excluded():
    # A closed/merged item derives phase "done" (terminal spec status). Its
    # recorded pr_urls must NOT show as awaiting action — no live gh call needed.
    task = Task(slug="a", description="d", phase="review", created_at=_now(),
                affected_repos=["r"], branch="feat/a",
                pr_urls={"r": "https://gh/pr/1"}, finished_at=_now())
    spec = Spec(id="spec-1", title="done spec", status="implemented",
                created_at=_now(), updated_at=_now(), body="b\n")
    wi = WorkItem(id="wi-1", title="Overhaul", workspace="ws", kind="feature",
                  created_at=_now(), updated_at=_now(), spec_id="spec-1",
                  task_slugs=["a"])
    summary = build_workitem_index([wi], {"spec-1": spec}, {"a": task}, {})[0]
    assert summary.phase == "done"
    assert assemble_queue([summary], _tasks_by_slug(task)) == []


def test_queue_order_is_specs_then_blocked_then_prs():
    spec = Spec(id="spec-1", title="Overhaul spec", status="needs_review",
                created_at=_now(), updated_at=_now(), body="b\n")
    blocked = Task(slug="a", description="d", phase="dev", created_at=_now(),
                   affected_repos=["r"], branch="feat/a", blocked_reason="x")
    pr = Task(slug="b", description="d", phase="review", created_at=_now(),
              affected_repos=["r"], branch="feat/b",
              pr_urls={"r": "https://gh/pr/9"}, finished_at=_now())
    wi = WorkItem(id="wi-1", title="Overhaul", workspace="ws", kind="feature",
                  created_at=_now(), updated_at=_now(), spec_id="spec-1",
                  task_slugs=["a", "b"])
    summary = build_workitem_index(
        [wi], {"spec-1": spec}, {"a": blocked, "b": pr}, {})[0]
    items = assemble_queue([summary], _tasks_by_slug(blocked, pr))
    assert [i.kind for i in items] == [
        "spec-needs-review", "blocked-task", "pr-awaiting"]
```

**Run (expect fail):** `uv run pytest tests/core/view/test_queue.py -q`
Expected: `test_recorded_pr_urls_become_pr_queue_items` and `test_queue_order_is_specs_then_blocked_then_prs` fail (PR branch missing; ordering list lacks `"pr-awaiting"`). (`test_done_workitem_prs_are_excluded` already passes via the existing `phase == "done"` gate.)

**Minimal implementation** — extend `assemble_queue` in `src/mship/core/view/queue.py` (add a `prs` accumulator + the `pr_urls` loop inside the per-task block; return `specs + blocked + prs`):
```python
    specs: list[QueueItem] = []
    blocked: list[QueueItem] = []
    prs: list[QueueItem] = []
    for s in summaries:
        if s.phase == "done":
            continue
        if s.attention.needs_approval and s.spec_id is not None:
            specs.append(QueueItem(
                kind="spec-needs-review", key=f"spec:{s.id}",
                workspace=s.workspace, work_item_id=s.id,
                work_item_title=s.title, phase=s.phase, spec_id=s.spec_id,
            ))
        for slug in s.task_slugs:
            task = tasks_by_slug.get(slug)
            if task is None:
                continue
            if task.blocked_reason is not None:
                blocked.append(QueueItem(
                    kind="blocked-task", key=f"block:{slug}",
                    workspace=s.workspace, work_item_id=s.id,
                    work_item_title=s.title, phase=s.phase,
                    task_slug=slug, blocked_reason=task.blocked_reason,
                ))
            for repo, url in task.pr_urls.items():
                prs.append(QueueItem(
                    kind="pr-awaiting", key=f"pr:{slug}:{repo}",
                    workspace=s.workspace, work_item_id=s.id,
                    work_item_title=s.title, phase=s.phase,
                    task_slug=slug, repo=repo, pr_url=url,
                ))
    return specs + blocked + prs
```

**Run (expect pass):** `uv run pytest tests/core/view/test_queue.py -q` → 7 passed.

**Commit:**
```
git add src/mship/core/view/queue.py tests/core/view/test_queue.py
git commit -m "queue: fold PRs from recorded pr_urls, gate done items, group specs/blocked/PRs (AC4)"
mship journal "PR3 T3: assemble_queue folds PRs from recorded Task.pr_urls (no live gh), phase!=done gate, kind ordering" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=4 -->
## Task 4 — Formatters (`queue_label`, `queue_detail`, `queue_header`) + `render_text`

**Files:**
- `src/mship/core/view/queue.py`
- `tests/core/view/test_queue.py`

**Failing test** — append to `tests/core/view/test_queue.py`:
```python
from mship.core.view.queue import (
    QueueItem, queue_detail, queue_header, queue_label, render_text)


def _spec_item():
    return QueueItem(kind="spec-needs-review", key="spec:wi-1", workspace="ws",
                     work_item_id="wi-1", work_item_title="Overhaul",
                     phase="shaping", spec_id="spec-1")


def _blocked_item():
    return QueueItem(kind="blocked-task", key="block:a", workspace="ws",
                     work_item_id="wi-1", work_item_title="Overhaul",
                     phase="in_flight", task_slug="a",
                     blocked_reason="waiting on API key")


def _pr_item():
    return QueueItem(kind="pr-awaiting", key="pr:b:r", workspace="ws",
                     work_item_id="wi-1", work_item_title="Overhaul",
                     phase="review", task_slug="b", repo="r",
                     pr_url="https://gh/pr/9")


def test_queue_labels_communicate_kind():
    assert "needs-review" in queue_label(_spec_item())
    assert "spec-1" in queue_label(_spec_item())
    assert "blocked" in queue_label(_blocked_item())
    assert "a" in queue_label(_blocked_item())
    assert "PR" in queue_label(_pr_item())
    assert "r" in queue_label(_pr_item())


def test_queue_detail_carries_specifics_and_workitem_context():
    assert "waiting on API key" in queue_detail(_blocked_item())
    assert "wi-1" in queue_detail(_blocked_item())
    assert "https://gh/pr/9" in queue_detail(_pr_item())
    assert "spec-1" in queue_detail(_spec_item())


def test_queue_header_counts_by_kind():
    header = queue_header([_spec_item(), _blocked_item(), _pr_item()])
    assert "3" in header
    assert "queue" in header.lower()


def test_render_text_has_all_sections():
    txt = render_text([_spec_item(), _blocked_item(), _pr_item()])
    assert "SPECS" in txt and "BLOCKED" in txt and "PRS" in txt
    assert "spec-1" in txt and "waiting on API key" in txt and "https://gh/pr/9" in txt


def test_render_text_empty_queue_shows_none():
    txt = render_text([])
    assert "(none)" in txt
```

**Run (expect fail):** `uv run pytest tests/core/view/test_queue.py -q`
Expected: `ImportError: cannot import name 'queue_label'` (formatters absent).

**Minimal implementation** — append to `src/mship/core/view/queue.py`:
```python
# --- formatters (shared by render_text + the TUI row builder) ---

# The read-only note surfaced in detail panes for items that will grow inline
# actions in a later PR (approve / request-changes — AC7).
_ACTION_DEFERRED = "  action: approve / request-changes (deferred — read-only in this view)"


def _context_lines(item: QueueItem) -> list[str]:
    return [
        f"  work item: {item.work_item_id}  ·  {item.work_item_title}  [{item.phase}]",
        f"  workspace: {item.workspace}",
    ]


def queue_label(item: QueueItem) -> str:
    if item.kind == "spec-needs-review":
        return f"[needs-review]  {item.spec_id}  ·  {item.work_item_title}"
    if item.kind == "blocked-task":
        return f"[blocked]  {item.task_slug}  —  {item.blocked_reason}"
    return f"[PR]  {item.repo}  ({item.task_slug})"


def queue_detail(item: QueueItem) -> str:
    if item.kind == "spec-needs-review":
        lines = [f"spec {item.spec_id}  [needs_review]", f"  {item.work_item_title}"]
        lines += _context_lines(item)
        lines.append(_ACTION_DEFERRED)
        return "\n".join(lines)
    if item.kind == "blocked-task":
        lines = [f"task {item.task_slug}  [BLOCKED]", f"  reason: {item.blocked_reason}"]
        lines += _context_lines(item)
        return "\n".join(lines)
    lines = [f"PR ({item.repo}, task {item.task_slug})", f"  {item.pr_url}"]
    lines += _context_lines(item)
    lines.append(_ACTION_DEFERRED)
    return "\n".join(lines)


def queue_header(items: list[QueueItem]) -> str:
    n_spec = sum(1 for i in items if i.kind == "spec-needs-review")
    n_block = sum(1 for i in items if i.kind == "blocked-task")
    n_pr = sum(1 for i in items if i.kind == "pr-awaiting")
    return (
        f"◆ queue  ·  {len(items)} needing attention  ·  "
        f"{n_spec} specs · {n_block} blocked · {n_pr} PRs"
    )


def render_text(items: list[QueueItem]) -> str:
    """Flat text dump of the whole queue — the non-TTY short-circuit output
    (agent pipes / CI), mirroring workitem_cockpit.render_text."""
    parts: list[str] = [queue_header(items), ""]
    for title, kind in (
        ("SPECS NEEDS REVIEW", "spec-needs-review"),
        ("BLOCKED TASKS", "blocked-task"),
        ("PRS AWAITING ACTION", "pr-awaiting"),
    ):
        parts.append(title)
        section = [i for i in items if i.kind == kind]
        parts.extend(queue_detail(i) for i in section)
        if not section:
            parts.append("(none)")
        parts.append("")
    return "\n".join(parts).rstrip("\n")
```

**Run (expect pass):** `uv run pytest tests/core/view/test_queue.py -q` → 12 passed.

**Commit:**
```
git add src/mship/core/view/queue.py tests/core/view/test_queue.py
git commit -m "queue: label/detail/header formatters + render_text non-TTY dump (AC4)"
mship journal "PR3 T4: queue_label/queue_detail/queue_header + render_text, shared by TUI rows and non-TTY output" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=5 -->
## Task 5 — `QueueView(MasterDetailApp)` + `build_rows` (thin widget layer)

**Files:**
- `src/mship/cli/view/queue.py` (new)
- `tests/cli/view/test_queue_view.py` (new)

**Failing test** — `tests/cli/view/test_queue_view.py`:
```python
import pytest

from mship.core.view.queue import QueueItem
from mship.cli.view.queue import QueueView


def _items():
    return [
        QueueItem(kind="spec-needs-review", key="spec:wi-1", workspace="ws",
                  work_item_id="wi-1", work_item_title="Overhaul",
                  phase="shaping", spec_id="spec-1"),
        QueueItem(kind="blocked-task", key="block:a", workspace="ws",
                  work_item_id="wi-1", work_item_title="Overhaul",
                  phase="in_flight", task_slug="a",
                  blocked_reason="waiting on API key"),
        QueueItem(kind="pr-awaiting", key="pr:b:r", workspace="ws",
                  work_item_id="wi-1", work_item_title="Overhaul",
                  phase="review", task_slug="b", repo="r",
                  pr_url="https://gh/pr/9"),
    ]


@pytest.mark.asyncio
async def test_queue_view_lists_every_attention_item_with_header():
    view = QueueView(_items())
    async with view.run_test() as pilot:
        await pilot.pause()
        labels = view.list_labels()
        assert any("needs-review" in l for l in labels)
        assert any("blocked" in l for l in labels)
        assert any(l.startswith("[PR]") for l in labels)
        assert "queue" in view.header_text().lower()
        assert "3" in view.header_text()
        # First row (spec) detail shows the deferred-action note + spec id.
        assert "spec-1" in view.detail_text()


@pytest.mark.asyncio
async def test_queue_view_detail_follows_highlight():
    view = QueueView(_items())
    async with view.run_test() as pilot:
        await pilot.pause()
        view._master.focus()
        await pilot.pause()
        await pilot.press("j")  # -> blocked task
        await pilot.pause()
        assert "waiting on API key" in view.detail_text()
        await pilot.press("j")  # -> PR
        await pilot.pause()
        assert "https://gh/pr/9" in view.detail_text()


@pytest.mark.asyncio
async def test_queue_view_empty_is_safe():
    view = QueueView([])
    async with view.run_test() as pilot:
        await pilot.pause()
        assert view.list_labels() == []
        assert view.detail_text() == ""
        assert "0 needing attention" in view.header_text()
```

**Run (expect fail):** `uv run pytest tests/cli/view/test_queue_view.py -q`
Expected: `ModuleNotFoundError: No module named 'mship.cli.view.queue'`.

**Minimal implementation** — `src/mship/cli/view/queue.py`:
```python
"""`mship view queue` — cross-workspace attention/triage list on the master/detail
base (AC4). Thin wiring: `build_rows` maps pure `QueueItem`s (assembled in
core/view/queue) to `ListRow`s, and `QueueView` renders them on the reusable
`MasterDetailApp`. READ-ONLY in this PR — navigate + view only.
"""
from __future__ import annotations

import typer

from mship.cli.view._master_detail import ListRow, MasterDetailApp
from mship.core.view.queue import (
    QueueItem, assemble_queue, queue_detail, queue_header, queue_label,
)


def build_rows(items: list[QueueItem]) -> list[ListRow]:
    """One flat list of attention items — each row carrying its own pre-rendered
    detail (reusing the shared queue formatters)."""
    return [
        ListRow(key=i.key, label=queue_label(i), detail=queue_detail(i))
        for i in items
    ]


class QueueView(MasterDetailApp):
    def __init__(self, items: list[QueueItem], **kw) -> None:
        super().__init__(**kw)
        self._items = items

    def list_rows(self) -> list[ListRow]:
        return build_rows(self._items)

    def header_line(self) -> str | None:
        return queue_header(self._items)


def _resolve_queue(container) -> list[QueueItem]:
    """Assemble the queue from the canonical stores: the WorkItem summary index
    (PR1's load_workitem_index — carries the Attention rollup) + the workspace's
    tasks (blocked_reason + recorded pr_urls). No live gh call."""
    from mship.cli.view._workitems import load_workitem_index

    summaries = load_workitem_index(container)
    tasks = container.state_manager().load().tasks
    return assemble_queue(summaries, tasks)
```

**Run (expect pass):** `uv run pytest tests/cli/view/test_queue_view.py -q` → 3 passed.

**Commit:**
```
git add src/mship/cli/view/queue.py tests/cli/view/test_queue_view.py
git commit -m "queue: QueueView(MasterDetailApp) + build_rows thin widget layer (AC4)"
mship journal "PR3 T5: QueueView on MasterDetailApp (unchanged base) + build_rows + _resolve_queue; pilot tests green" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=6 -->
## Task 6 — `mship view queue` Typer command + registration + non-TTY text output

**Files:**
- `src/mship/cli/view/queue.py`
- `src/mship/cli/view/__init__.py`
- `tests/cli/view/test_queue_view.py`
- `tests/cli/view/test_view_registration.py`

**Failing test** — append to `tests/cli/view/test_queue_view.py`:
```python
# --- CLI: mship view queue ---
from datetime import datetime, timezone

from typer.testing import CliRunner

from mship.cli import app, container
from mship.core.spec import Spec
from mship.core.spec_store import SPECS_DIRNAME, SpecStore
from mship.core.state import StateManager, Task, WorkspaceState
from mship.core.workitem import WorkItem
from mship.core.workitem_store import WorkItemStore


def _dt():
    return datetime(2026, 7, 1, tzinfo=timezone.utc)


def _seed_workspace(tmp_path):
    state_dir = tmp_path / ".mothership"
    state_dir.mkdir()
    cfg = tmp_path / "mothership.yaml"
    cfg.write_text("workspace: t\nrepos: {}\n")

    # A needs_review spec (spec-1 / wi-1) + a blocked task and a PR task (wi-2).
    SpecStore(tmp_path / SPECS_DIRNAME).save(Spec(
        id="spec-1", title="Overhaul spec", status="needs_review",
        created_at=_dt(), updated_at=_dt(), body="b\n"))
    WorkItemStore(state_dir / "workitems").save(WorkItem(
        id="wi-1", title="Overhaul", workspace="t", kind="feature",
        created_at=_dt(), updated_at=_dt(), spec_id="spec-1"))
    WorkItemStore(state_dir / "workitems").save(WorkItem(
        id="wi-2", title="Wiring", workspace="t", kind="feature",
        created_at=_dt(), updated_at=_dt(), task_slugs=["a", "b"]))
    StateManager(state_dir).save(WorkspaceState(tasks={
        "a": Task(slug="a", description="d", phase="dev", created_at=_dt(),
                  affected_repos=["r"], branch="feat/a",
                  blocked_reason="waiting on API key", work_item_id="wi-2"),
        "b": Task(slug="b", description="d", phase="review", created_at=_dt(),
                  affected_repos=["r"], branch="feat/b",
                  pr_urls={"r": "https://gh/pr/9"}, finished_at=_dt(),
                  work_item_id="wi-2"),
    }))

    container.config.reset()
    container.state_manager.reset()
    container.config_path.override(cfg)
    container.state_dir.override(state_dir)


def _reset():
    container.config_path.reset_override()
    container.state_dir.reset_override()
    container.config.reset_override()
    container.config.reset()
    container.state_manager.reset_override()
    container.state_manager.reset()


def test_queue_registered_in_view_help():
    result = CliRunner().invoke(app, ["view", "--help"])
    assert result.exit_code == 0
    assert "queue" in result.stdout


def test_queue_cli_renders_text_dump(tmp_path):
    _seed_workspace(tmp_path)
    try:
        # CliRunner stdout is not a TTY -> non-TTY text short-circuit (no TUI hang).
        result = CliRunner().invoke(app, ["view", "queue"])
        assert result.exit_code == 0, result.output
        assert "spec-1" in result.output           # spec needs review
        assert "waiting on API key" in result.output  # blocked task
        assert "https://gh/pr/9" in result.output     # PR awaiting
    finally:
        _reset()


def test_queue_cli_empty_workspace_is_ok(tmp_path):
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
        result = CliRunner().invoke(app, ["view", "queue"])
        assert result.exit_code == 0, result.output
        assert "0 needing attention" in result.output
        assert "(none)" in result.output
    finally:
        _reset()
```

Also add to `tests/cli/view/test_view_registration.py` (inside `test_view_command_exists`):
```python
    assert "queue" in result.stdout
```

**Run (expect fail):** `uv run pytest tests/cli/view/test_queue_view.py tests/cli/view/test_view_registration.py -q`
Expected: registration/CLI tests fail — no `queue` command wired (`view --help` lacks `queue`; `invoke(app, ["view", "queue"])` exits non-zero "No such command").

**Minimal implementation:**

Append the Typer command to `src/mship/cli/view/queue.py`:
```python
def register(app: "typer.Typer", get_container):
    @app.command()
    def queue():
        """Cross-workspace attention/triage queue: specs awaiting review, blocked
        tasks, and PRs awaiting action — each a navigable row with a detail pane.
        Read-only (navigate + view)."""
        from mship.cli.output import Output
        from mship.core.view.queue import render_text

        container = get_container()
        items = _resolve_queue(container)

        # Non-TTY short-circuit (mirrors `mship view workitem`): the Textual TUI
        # hangs when stdout isn't a terminal (agent pipes, CI, CliRunner). Print
        # the flat queue text and exit instead.
        if not Output().is_tty:
            typer.echo(render_text(items))
            return

        QueueView(items).run()
```

Wire it in `src/mship/cli/view/__init__.py` — add the import + `register` call alongside the existing five (match the file's actual `register(...)` structure; do not blindly replace it):
```python
    from mship.cli.view import queue as _queue
    ...
    _queue.register(app, get_container)
```

**Run (expect pass):**
```
uv run pytest tests/cli/view/test_queue_view.py tests/cli/view/test_view_registration.py -q
```
→ all passed. Then the full view suite as a regression guard: `uv run pytest tests/cli/view tests/core/view -q`.

**Commit:**
```
git add src/mship/cli/view/queue.py src/mship/cli/view/__init__.py tests/cli/view/test_queue_view.py tests/cli/view/test_view_registration.py
git commit -m "queue: wire mship view queue command + non-TTY render_text short-circuit (AC4)"
mship journal "PR3 T6: mship view queue registered; non-TTY text dump via CliRunner; empty workspace safe" --action committed
```
<!-- /mship:task -->

---

## Self-Review

**AC4 — `mship view queue`, a cross-workspace attention/triage list (specs in needs_review, blocked tasks, PRs awaiting action), navigable on `MasterDetailApp` with a detail pane per item, sourced from the canonical stores, non-TTY text dump:**

| AC4 sub-requirement | Task(s) |
| --- | --- |
| Specs in `needs_review` as rows (reusing `WorkItemSummary.attention.needs_approval` / `compute_attention`) | 1 |
| Blocked tasks as rows (`Task.blocked_reason`, from canonical `state.tasks`) | 2 |
| PRs awaiting action as rows from **recorded** `Task.pr_urls` (no live `gh` call); merged/closed drop via `phase != "done"` gate | 3 |
| Deterministic grouping/order (specs → blocked → PRs) | 3 |
| Per-item detail pane + list labels + header (pure formatters shared by TUI and text) | 4 |
| Navigable on the reusable `MasterDetailApp` (base unchanged; only `list_rows`/`header_line` hooks) — j/k/enter/tab/`/`/footer inherited | 5 |
| Sourced from canonical stores via PR1's `load_workitem_index` + `state_manager().load().tasks` | 5, 6 |
| `mship view queue` command registered; non-TTY flat text dump (mirrors `workitem.py`'s `render_text` + `Output().is_tty`) | 6 |
| Empty-workspace safety | 5 (widget), 6 (CLI) |

The pure/thin split mirrors PR2 exactly (`core/view/queue.py` unit-tested with no Textual; `cli/view/queue.py` thin on top), and `MasterDetailApp` / `ListRow` / `load_workitem_index` / `compute_attention` are all reused unchanged.

## Deferred to later PRs

- **AC7 — inline approve / request-changes** on spec-needs-review and PR-awaiting rows. This PR is read-only (navigate + view); the detail panes already surface a `"action: approve / request-changes (deferred — read-only in this view)"` note as the anchor point. Wiring the write path (reusing `serve.py`'s verdict/approve/request-changes logic against the canonical `SpecStore`) is a later PR.
- **AC8 — cross-entity open/copy** (e.g. `enter` on a queue row jumping into `mship view workitem <id>` / `mship view spec`, or yanking an id/PR-url). PR2 already notes cross-entity open/copy as deferred in `MasterDetailApp.action_drill`; the queue inherits that. A later PR can key off `QueueItem.work_item_id` / `spec_id` / `pr_url` to launch the corresponding cockpit or copy the ref.
- **Live PR state** (open vs merged vs closed beyond the recorded-`pr_urls` + `phase` proxy) stays out of the view — it belongs to `mship serve`'s `PrWatcher`, never a read-only view.
