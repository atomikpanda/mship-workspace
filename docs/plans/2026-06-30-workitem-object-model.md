# WorkItem Object Model + Phase State Machine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** Linear **MOS-196** — "Slice 1 — WorkItem object model + phase state machine (mship core)", foundation of the *Work Items — phase-aware cockpit* program. (Spec lives in Linear, not as an `mship spec`.)

**Goal:** Introduce a first-class `WorkItem` in mship core — a container that owns 0–1 spec, 0–N parallel tasks, and 0–N threads — with a kind-gated lifecycle phase and a derived two-axis attention overlay, exposed over CLI + serve, with a migration that wraps every existing spec/task.

**Architecture:** Mirror existing mship patterns. `WorkItem` is a Pydantic model persisted JSON-file-per-item under `.mothership/workitems/` via a `WorkItemStore` (copying `MessageStore`). **Lifecycle phase and the attention overlay are DERIVED in one shared projection** (`build_workitem_index`, copying `view/task_index.py`) consumed by both serve and CLI — phase is computed from child state with an optional stored `phase_override`; attention maps onto existing signals (`spec.status == needs_review`, `thread.needs_you`, `task.blocked_reason`, `task.pr_urls`). A back-pointer `work_item_id` is added to `Spec` and `Task`; a migration backfills both directions.

**Tech Stack:** Python 3.11+, Pydantic v2, Typer (CLI), FastAPI (serve), pytest (+ `tmp_path`). All commands run from the `mothership` repo root (inside the task worktree). `uv run pytest <nodeid> -v` for a single test; `mship test` at commit for the evidence trail.

---

## File Structure

- **Create** `src/mship/core/workitem.py` — `WorkItem` model, `Kind`/`Phase` literals, `ExternalLink`, `PHASE_ORDER`.
- **Create** `src/mship/core/workitem_store.py` — `WorkItemStore` (JSON file-per-item; create + link helpers).
- **Create** `src/mship/core/view/workitem_index.py` — `Attention`, `WorkItemSummary`, pure `compute_phase`/`compute_attention`, shared `build_workitem_index`.
- **Modify** `src/mship/core/spec.py` — add `work_item_id: str | None = None` to `Spec`.
- **Modify** `src/mship/core/state.py` — add `work_item_id: str | None = None` to `Task`.
- **Create** `src/mship/core/workitem_migrate.py` — `wrap_existing(...)` backfill.
- **Create** `src/mship/cli/workitem.py` — `mship item` command group (`register`).
- **Modify** `src/mship/cli/__init__.py` — import + register the module.
- **Modify** `src/mship/core/serve.py` — `GET /items`, `GET /items/{id}`.
- **Tests:** `tests/core/test_workitem.py`, `tests/core/test_workitem_store.py`, `tests/core/view/test_workitem_index.py`, `tests/core/test_workitem_migrate.py`, `tests/core/test_spec_workitem_field.py`, `tests/core/test_state_workitem_field.py`, `tests/cli/test_workitem.py`, `tests/core/test_serve_items.py`.

---

<!-- mship:task id=1 -->
### Task 1: WorkItem model

**Files:**
- Create: `src/mship/core/workitem.py`
- Test: `tests/core/test_workitem.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_workitem.py
from datetime import datetime, timezone

from mship.core.workitem import WorkItem, ExternalLink, PHASE_ORDER


def _now():
    return datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc)


def test_workitem_defaults_and_roundtrip():
    wi = WorkItem(id="wi-1", title="Make capture conversational", workspace="mothership",
                  kind="feature", created_at=_now(), updated_at=_now())
    assert wi.spec_id is None
    assert wi.task_slugs == [] and wi.thread_ids == [] and wi.external_links == []
    assert wi.phase_override is None
    restored = WorkItem.model_validate_json(wi.model_dump_json())
    assert restored == wi


def test_external_link_and_links_list():
    link = ExternalLink(provider="github", url="https://github.com/atomikpanda/mothership/issues/249",
                        title="MOS-196")
    wi = WorkItem(id="wi-2", title="t", workspace="ws", kind="bug",
                  created_at=_now(), updated_at=_now(), external_links=[link])
    assert wi.external_links[0].provider == "github"


def test_phase_order_is_the_pipeline():
    assert PHASE_ORDER == ("inbox", "shaping", "ready", "in_flight", "review", "done")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_workitem.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'mship.core.workitem'`

- [ ] **Step 3: Write minimal implementation**

```python
# src/mship/core/workitem.py
from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel

Kind = Literal["feature", "bug", "chore", "question"]
Phase = Literal["inbox", "shaping", "ready", "in_flight", "review", "done"]

PHASE_ORDER: tuple[Phase, ...] = ("inbox", "shaping", "ready", "in_flight", "review", "done")


class ExternalLink(BaseModel):
    provider: Literal["github", "linear", "notion", "jira", "url"]
    url: str
    title: str = ""


class WorkItem(BaseModel):
    id: str
    title: str
    workspace: str
    kind: Kind
    created_at: datetime
    updated_at: datetime
    spec_id: str | None = None
    task_slugs: list[str] = []
    thread_ids: list[str] = []
    external_links: list[ExternalLink] = []
    # Manual nudge: when set, overrides the phase derived from child state.
    phase_override: Phase | None = None
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_workitem.py -v`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/workitem.py tests/core/test_workitem.py
git commit -m "feat(workitem): add WorkItem model + Kind/Phase/ExternalLink"
mship journal "WorkItem model + literals; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: Pure phase derivation (`compute_phase`)

`compute_phase` derives the lifecycle phase from child state. `phase_override` wins. Tasks (if any) dominate: any running task → `in_flight`; all finished with a PR → `review`; all finished, no PR → `done`. With no tasks, the spec status maps onto the pipeline. With neither → `inbox`. (Precise `done`-on-merge is refined by the Review·Merge slice, MOS-199, which has PR-merge state; here a finished task with a PR reads as `review`.)

**Files:**
- Create: `src/mship/core/view/workitem_index.py`
- Test: `tests/core/view/test_workitem_index.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/core/view/test_workitem_index.py
from datetime import datetime, timezone

from mship.core.workitem import WorkItem
from mship.core.spec import Spec
from mship.core.state import Task
from mship.core.view.workitem_index import compute_phase


def _now():
    return datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc)


def _wi(**kw):
    base = dict(id="wi", title="t", workspace="ws", kind="feature",
                created_at=_now(), updated_at=_now())
    base.update(kw)
    return WorkItem(**base)


def _spec(status):
    return Spec(id="s", title="t", status=status, created_at=_now(), updated_at=_now())


def _task(*, finished=False, pr=False, blocked=False):
    return Task(
        slug="s1", description="d", phase="dev", created_at=_now(),
        affected_repos=["mothership"], branch="b",
        finished_at=_now() if finished else None,
        pr_urls={"mothership": "http://pr"} if pr else {},
        blocked_reason="waiting" if blocked else None,
    )


def test_phase_override_wins():
    assert compute_phase(_wi(phase_override="done"), _spec("drafting"), [_task()]) == "done"


def test_no_children_is_inbox():
    assert compute_phase(_wi(), None, []) == "inbox"


def test_spec_status_maps_to_phase():
    assert compute_phase(_wi(), _spec("captured"), []) == "inbox"
    assert compute_phase(_wi(), _spec("drafting"), []) == "shaping"
    assert compute_phase(_wi(), _spec("needs_review"), []) == "shaping"
    assert compute_phase(_wi(), _spec("approved"), []) == "ready"
    assert compute_phase(_wi(), _spec("implemented"), []) == "done"
    assert compute_phase(_wi(), _spec("archived"), []) == "done"


def test_tasks_dominate_spec():
    assert compute_phase(_wi(), _spec("approved"), [_task(finished=False)]) == "in_flight"
    assert compute_phase(_wi(), _spec("approved"),
                         [_task(finished=True, pr=True)]) == "review"
    assert compute_phase(_wi(), _spec("approved"),
                         [_task(finished=True, pr=False)]) == "done"


def test_mixed_tasks_one_running_is_in_flight():
    assert compute_phase(_wi(), None,
                         [_task(finished=True, pr=True), _task(finished=False)]) == "in_flight"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/view/test_workitem_index.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'mship.core.view.workitem_index'`

- [ ] **Step 3: Write minimal implementation**

```python
# src/mship/core/view/workitem_index.py
from __future__ import annotations

from mship.core.spec import Spec
from mship.core.state import Task
from mship.core.workitem import Phase, WorkItem

_SPEC_PHASE: dict[str, Phase] = {
    "captured": "inbox",
    "drafting": "shaping",
    "needs_review": "shaping",
    "needs_clarification": "shaping",
    "approved": "ready",
    "dispatched": "in_flight",
    "implemented": "done",
    "archived": "done",
}


def compute_phase(item: WorkItem, spec: Spec | None, tasks: list[Task]) -> Phase:
    if item.phase_override is not None:
        return item.phase_override
    if tasks:
        if any(t.finished_at is None for t in tasks):
            return "in_flight"
        if any(t.pr_urls for t in tasks):
            return "review"
        return "done"
    if spec is not None:
        return _SPEC_PHASE.get(spec.status, "shaping")
    return "inbox"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/view/test_workitem_index.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/view/workitem_index.py tests/core/view/test_workitem_index.py
git commit -m "feat(workitem): derive lifecycle phase from child state"
mship journal "compute_phase derivation + tests" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: Pure attention overlay (`compute_attention`)

The orthogonal "needs you" axis, derived from signals that already exist. Aggregates across parallel tasks (`blocked 1/3`).

**Files:**
- Modify: `src/mship/core/view/workitem_index.py`
- Test: `tests/core/view/test_workitem_index.py` (add to existing file)

- [ ] **Step 1: Write the failing test**

```python
# append to tests/core/view/test_workitem_index.py
from mship.core.message import Message, Thread
from mship.core.view.workitem_index import Attention, compute_attention


def _thread(*, needs_you=False):
    msgs = []
    if needs_you:
        msgs = [Message(id="m1", thread_id="t1", role="agent", text="?", created_at=_now(),
                        kind="needs_you")]
    return Thread(id="t1", subject="s", created_at=_now(), updated_at=_now(), messages=msgs)


def test_attention_clear_when_no_signals():
    att = compute_attention(_spec("approved"), [_task()], [])
    assert att == Attention(needs_approval=False, needs_decision=False, blocked=False,
                            needs_review=False, blocked_tasks=0, total_tasks=1)


def test_needs_approval_from_spec_needs_review():
    att = compute_attention(_spec("needs_review"), [], [])
    assert att.needs_approval is True


def test_blocked_counts_across_parallel_tasks():
    att = compute_attention(None, [_task(blocked=True), _task(), _task()], [])
    assert att.blocked is True
    assert att.blocked_tasks == 1 and att.total_tasks == 3


def test_needs_review_when_a_task_has_a_pr():
    assert compute_attention(None, [_task(pr=True)], []).needs_review is True


def test_needs_decision_from_thread_needs_you():
    assert compute_attention(None, [], [_thread(needs_you=True)]).needs_decision is True
    assert compute_attention(None, [], [_thread(needs_you=False)]).needs_decision is False
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/view/test_workitem_index.py -v`
Expected: FAIL — `ImportError: cannot import name 'Attention'`

- [ ] **Step 3: Write minimal implementation**

```python
# add to src/mship/core/view/workitem_index.py
from dataclasses import dataclass

from mship.core.message import Thread


@dataclass(frozen=True)
class Attention:
    needs_approval: bool
    needs_decision: bool
    blocked: bool
    needs_review: bool
    blocked_tasks: int
    total_tasks: int


def compute_attention(spec: Spec | None, tasks: list[Task], threads: list[Thread]) -> Attention:
    blocked_tasks = sum(1 for t in tasks if t.blocked_reason is not None)
    return Attention(
        needs_approval=spec is not None and spec.status == "needs_review",
        needs_decision=any(t.needs_you for t in threads),
        blocked=blocked_tasks > 0,
        needs_review=any(bool(t.pr_urls) for t in tasks),
        blocked_tasks=blocked_tasks,
        total_tasks=len(tasks),
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/view/test_workitem_index.py -v`
Expected: PASS (all phase + attention tests)

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/view/workitem_index.py tests/core/view/test_workitem_index.py
git commit -m "feat(workitem): derive attention overlay from child signals"
mship journal "compute_attention overlay + tests" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: WorkItemStore (JSON file-per-item)

Mirror `MessageStore`: atomic save, unsafe-id guard, `create`, and load-set-save link helpers.

**Files:**
- Create: `src/mship/core/workitem_store.py`
- Test: `tests/core/test_workitem_store.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_workitem_store.py
from datetime import datetime, timezone

import pytest

from mship.core.workitem_store import WorkItemStore


def _now():
    return datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc)


def test_create_get_roundtrip(tmp_path):
    store = WorkItemStore(tmp_path / "workitems")
    wi = store.create(title="Make capture conversational", kind="feature",
                      workspace="mothership", now=_now())
    assert wi.id
    assert store.get(wi.id) == wi


def test_list_sorted_by_updated_desc(tmp_path):
    store = WorkItemStore(tmp_path / "workitems")
    a = store.create(title="a", kind="bug", workspace="ws",
                     now=datetime(2026, 6, 30, 10, 0, tzinfo=timezone.utc))
    b = store.create(title="b", kind="bug", workspace="ws",
                     now=datetime(2026, 6, 30, 11, 0, tzinfo=timezone.utc))
    assert [w.id for w in store.list()] == [b.id, a.id]


def test_unsafe_id_rejected(tmp_path):
    store = WorkItemStore(tmp_path / "workitems")
    with pytest.raises(ValueError):
        store.get("../escape")


def test_link_helpers(tmp_path):
    store = WorkItemStore(tmp_path / "workitems")
    wi = store.create(title="t", kind="feature", workspace="ws", now=_now())
    store.link_spec(wi.id, "spec-1", now=_now())
    store.add_task(wi.id, "task-a", now=_now())
    store.add_task(wi.id, "task-a", now=_now())  # idempotent
    store.add_thread(wi.id, "thread-x", now=_now())
    store.set_phase_override(wi.id, "in_flight", now=_now())
    got = store.get(wi.id)
    assert got.spec_id == "spec-1"
    assert got.task_slugs == ["task-a"]
    assert got.thread_ids == ["thread-x"]
    assert got.phase_override == "in_flight"


def test_link_missing_item_raises(tmp_path):
    store = WorkItemStore(tmp_path / "workitems")
    with pytest.raises(KeyError):
        store.link_spec("nope", "spec-1")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_workitem_store.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'mship.core.workitem_store'`

- [ ] **Step 3: Write minimal implementation**

```python
# src/mship/core/workitem_store.py
from __future__ import annotations

import tempfile
import uuid
from datetime import datetime
from pathlib import Path

from mship.core.workitem import ExternalLink, Kind, Phase, WorkItem


def _new_id(now: datetime) -> str:
    return f"wi-{now:%Y%m%d%H%M%S}-{uuid.uuid4().hex[:8]}"


class WorkItemStore:
    """Filesystem registry for work items: one JSON file per item."""

    def __init__(self, workitems_dir: Path) -> None:
        self._dir = Path(workitems_dir)

    def _path(self, item_id: str) -> Path:
        if (not item_id or "/" in item_id or "\\" in item_id
                or item_id in (".", "..") or item_id.startswith(".")):
            raise ValueError(f"unsafe work item id: {item_id!r}")
        return self._dir / f"{item_id}.json"

    def save(self, item: WorkItem) -> Path:
        self._dir.mkdir(parents=True, exist_ok=True)
        path = self._path(item.id)
        fd, tmp = tempfile.mkstemp(dir=self._dir, suffix=".json.tmp")
        try:
            with open(fd, "w") as f:
                f.write(item.model_dump_json(indent=2))
            Path(tmp).replace(path)
        except Exception:
            Path(tmp).unlink(missing_ok=True)
            raise
        return path

    def get(self, item_id: str) -> WorkItem | None:
        path = self._path(item_id)
        if not path.is_file():
            return None
        return WorkItem.model_validate_json(path.read_text())

    def list(self) -> list[WorkItem]:
        if not self._dir.is_dir():
            return []
        items = [WorkItem.model_validate_json(p.read_text()) for p in self._dir.glob("*.json")]
        return sorted(items, key=lambda w: w.updated_at, reverse=True)

    def create(self, title: str, kind: Kind, workspace: str, now: datetime) -> WorkItem:
        item = WorkItem(id=_new_id(now), title=title, workspace=workspace, kind=kind,
                        created_at=now, updated_at=now)
        self.save(item)
        return item

    def _mutate(self, item_id: str, now: datetime | None) -> WorkItem:
        item = self.get(item_id)
        if item is None:
            raise KeyError(item_id)
        if now is not None:
            item.updated_at = now
        return item

    def link_spec(self, item_id: str, spec_id: str, now: datetime | None = None) -> None:
        item = self._mutate(item_id, now)
        item.spec_id = spec_id
        self.save(item)

    def add_task(self, item_id: str, task_slug: str, now: datetime | None = None) -> None:
        item = self._mutate(item_id, now)
        if task_slug not in item.task_slugs:
            item.task_slugs.append(task_slug)
        self.save(item)

    def add_thread(self, item_id: str, thread_id: str, now: datetime | None = None) -> None:
        item = self._mutate(item_id, now)
        if thread_id not in item.thread_ids:
            item.thread_ids.append(thread_id)
        self.save(item)

    def add_external_link(self, item_id: str, link: ExternalLink, now: datetime | None = None) -> None:
        item = self._mutate(item_id, now)
        item.external_links.append(link)
        self.save(item)

    def set_phase_override(self, item_id: str, phase: Phase, now: datetime | None = None) -> None:
        item = self._mutate(item_id, now)
        item.phase_override = phase
        self.save(item)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_workitem_store.py -v`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/workitem_store.py tests/core/test_workitem_store.py
git commit -m "feat(workitem): WorkItemStore (json file-per-item + link helpers)"
mship journal "WorkItemStore + tests" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: Shared projection — `WorkItemSummary` + `build_workitem_index`

The single projection serve and CLI both call (mirrors `build_task_index`). Looks each item's children up by id/slug, computes phase + attention, splits non-done first.

**Files:**
- Modify: `src/mship/core/view/workitem_index.py`
- Test: `tests/core/view/test_workitem_index.py` (add)

- [ ] **Step 1: Write the failing test**

```python
# append to tests/core/view/test_workitem_index.py
from mship.core.view.workitem_index import WorkItemSummary, build_workitem_index


def test_build_index_populates_phase_and_attention():
    item = _wi(id="wi-1", spec_id="s", task_slugs=["s1"], thread_ids=["t1"])
    summaries = build_workitem_index(
        workitems=[item],
        specs_by_id={"s": _spec("approved")},
        tasks_by_slug={"s1": _task(blocked=True)},
        threads_by_id={"t1": _thread(needs_you=True)},
    )
    assert len(summaries) == 1
    s = summaries[0]
    assert isinstance(s, WorkItemSummary)
    assert s.id == "wi-1" and s.kind == "feature"
    assert s.phase == "in_flight"
    assert s.attention.blocked is True and s.attention.blocked_tasks == 1
    assert s.attention.needs_decision is True


def test_build_index_orders_active_before_done():
    active = _wi(id="active", updated_at=datetime(2026, 6, 30, 9, 0, tzinfo=timezone.utc))
    done = _wi(id="done", phase_override="done",
               updated_at=datetime(2026, 6, 30, 13, 0, tzinfo=timezone.utc))
    summaries = build_workitem_index([done, active], {}, {}, {})
    assert [s.id for s in summaries] == ["active", "done"]


def test_build_index_tolerates_missing_children():
    item = _wi(id="wi-x", spec_id="ghost", task_slugs=["missing"], thread_ids=["gone"])
    s = build_workitem_index([item], {}, {}, {})[0]
    assert s.phase == "inbox"
    assert s.attention.total_tasks == 0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/view/test_workitem_index.py -v`
Expected: FAIL — `ImportError: cannot import name 'build_workitem_index'`

- [ ] **Step 3: Write minimal implementation**

```python
# add to src/mship/core/view/workitem_index.py
from dataclasses import dataclass, field
from datetime import datetime

from mship.core.workitem import ExternalLink, Kind


@dataclass(frozen=True)
class WorkItemSummary:
    id: str
    title: str
    kind: Kind
    workspace: str
    phase: str
    attention: Attention
    created_at: datetime
    updated_at: datetime
    spec_id: str | None
    task_slugs: list[str] = field(default_factory=list)
    thread_ids: list[str] = field(default_factory=list)
    external_links: list[ExternalLink] = field(default_factory=list)


def _summarize(item, specs_by_id, tasks_by_slug, threads_by_id) -> WorkItemSummary:
    spec = specs_by_id.get(item.spec_id) if item.spec_id else None
    tasks = [tasks_by_slug[s] for s in item.task_slugs if s in tasks_by_slug]
    threads = [threads_by_id[t] for t in item.thread_ids if t in threads_by_id]
    return WorkItemSummary(
        id=item.id, title=item.title, kind=item.kind, workspace=item.workspace,
        phase=compute_phase(item, spec, tasks),
        attention=compute_attention(spec, tasks, threads),
        created_at=item.created_at, updated_at=item.updated_at,
        spec_id=item.spec_id, task_slugs=list(item.task_slugs),
        thread_ids=list(item.thread_ids), external_links=list(item.external_links),
    )


def build_workitem_index(workitems, specs_by_id, tasks_by_slug, threads_by_id) -> list[WorkItemSummary]:
    """Non-done items first (updated_at desc), then done (also desc). Shared by serve + CLI."""
    summaries = [_summarize(w, specs_by_id, tasks_by_slug, threads_by_id) for w in workitems]
    active = sorted([s for s in summaries if s.phase != "done"],
                    key=lambda s: s.updated_at, reverse=True)
    done = sorted([s for s in summaries if s.phase == "done"],
                  key=lambda s: s.updated_at, reverse=True)
    return active + done
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/view/test_workitem_index.py -v`
Expected: PASS (all index tests)

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/view/workitem_index.py tests/core/view/test_workitem_index.py
git commit -m "feat(workitem): shared build_workitem_index projection"
mship journal "WorkItemSummary + build_workitem_index + tests" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: Back-pointer `work_item_id` on Spec and Task

Additive, default `None`, back-compatible with on-disk specs/tasks that predate it.

**Files:**
- Modify: `src/mship/core/spec.py:39` (after `body`)
- Modify: `src/mship/core/state.py:44` (after `depends_on`)
- Test: `tests/core/test_spec_workitem_field.py`, `tests/core/test_state_workitem_field.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/core/test_spec_workitem_field.py
from datetime import datetime, timezone

from mship.core.spec import Spec


def test_spec_work_item_id_defaults_none_and_legacy_loads():
    # legacy JSON without the field still validates (back-compat)
    legacy = ('{"id":"s","title":"t","status":"drafting",'
              '"created_at":"2026-06-30T12:00:00+00:00","updated_at":"2026-06-30T12:00:00+00:00"}')
    spec = Spec.model_validate_json(legacy)
    assert spec.work_item_id is None
    spec.work_item_id = "wi-1"
    assert Spec.model_validate_json(spec.model_dump_json()).work_item_id == "wi-1"
```

```python
# tests/core/test_state_workitem_field.py
from datetime import datetime, timezone

from mship.core.state import Task


def test_task_work_item_id_defaults_none_and_legacy_loads():
    legacy = ('{"slug":"s1","description":"d","phase":"dev",'
              '"created_at":"2026-06-30T12:00:00+00:00","affected_repos":["mothership"],'
              '"branch":"b"}')
    task = Task.model_validate_json(legacy)
    assert task.work_item_id is None
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/core/test_spec_workitem_field.py tests/core/test_state_workitem_field.py -v`
Expected: FAIL — `AttributeError: 'Spec' object has no attribute 'work_item_id'` (and the Task case)

- [ ] **Step 3: Write minimal implementation**

In `src/mship/core/spec.py`, add a field to `Spec` immediately after `body: str = ""` (line 39):

```python
    body: str = ""
    work_item_id: str | None = None
```

In `src/mship/core/state.py`, add a field to `Task` immediately after `depends_on: list[DependencyEdge] = []` (line 44):

```python
    depends_on: list[DependencyEdge] = []
    work_item_id: str | None = None
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/core/test_spec_workitem_field.py tests/core/test_state_workitem_field.py -v`
Expected: PASS

- [ ] **Step 5: Run the spec + state suites to confirm no regression**

Run: `uv run pytest tests/core/test_spec_store.py tests/core/ -k "state or spec" -v`
Expected: PASS (existing round-trip tests unaffected — the new field serializes as `null`)

- [ ] **Step 6: Commit**

```bash
git add src/mship/core/spec.py src/mship/core/state.py tests/core/test_spec_workitem_field.py tests/core/test_state_workitem_field.py
git commit -m "feat(workitem): add work_item_id back-pointer to Spec and Task"
mship journal "work_item_id on Spec+Task (back-compat) + tests" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=7 -->
### Task 7: Migration — wrap existing specs/tasks

`wrap_existing` is idempotent: for each spec with no `work_item_id`, create a `feature` WorkItem, link the spec + its `task_slug`, set back-pointers. For each task with no spec and no `work_item_id`, create a `chore` WorkItem and link it. Link threads by their `spec_id`/`task_slug`.

**Files:**
- Create: `src/mship/core/workitem_migrate.py`
- Test: `tests/core/test_workitem_migrate.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_workitem_migrate.py
from datetime import datetime, timezone

from mship.core.spec import Spec
from mship.core.spec_store import SpecStore
from mship.core.state import StateManager, Task, WorkspaceState
from mship.core.message_store import MessageStore
from mship.core.workitem_store import WorkItemStore
from mship.core.workitem_migrate import wrap_existing


def _now():
    return datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc)


def _setup(tmp_path):
    specs = SpecStore(tmp_path / "specs")
    state = StateManager(tmp_path / ".mothership")
    msgs = MessageStore(tmp_path / ".mothership" / "messages")
    items = WorkItemStore(tmp_path / ".mothership" / "workitems")
    return specs, state, msgs, items


def test_spec_with_task_becomes_one_feature_item(tmp_path):
    specs, state, msgs, items = _setup(tmp_path)
    specs.save(Spec(id="alpha", title="Alpha", status="approved",
                    created_at=_now(), updated_at=_now(), task_slug="alpha"))
    state.save(WorkspaceState(tasks={"alpha": Task(
        slug="alpha", description="d", phase="dev", created_at=_now(),
        affected_repos=["mothership"], branch="b", spec_id="alpha")}))

    wrap_existing(items, specs, state, msgs, now=_now())

    created = items.list()
    assert len(created) == 1
    wi = created[0]
    assert wi.kind == "feature" and wi.spec_id == "alpha" and wi.task_slugs == ["alpha"]
    assert specs.find_by_id("alpha").work_item_id == wi.id
    assert state.load().tasks["alpha"].work_item_id == wi.id


def test_orphan_task_becomes_chore_item(tmp_path):
    specs, state, msgs, items = _setup(tmp_path)
    state.save(WorkspaceState(tasks={"bugfix": Task(
        slug="bugfix", description="d", phase="dev", created_at=_now(),
        affected_repos=["mothership"], branch="b")}))

    wrap_existing(items, specs, state, msgs, now=_now())

    wi = items.list()[0]
    assert wi.kind == "chore" and wi.task_slugs == ["bugfix"] and wi.spec_id is None


def test_idempotent(tmp_path):
    specs, state, msgs, items = _setup(tmp_path)
    specs.save(Spec(id="alpha", title="Alpha", status="drafting",
                    created_at=_now(), updated_at=_now()))
    wrap_existing(items, specs, state, msgs, now=_now())
    wrap_existing(items, specs, state, msgs, now=_now())
    assert len(items.list()) == 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_workitem_migrate.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'mship.core.workitem_migrate'`

- [ ] **Step 3: Write minimal implementation**

```python
# src/mship/core/workitem_migrate.py
from __future__ import annotations

from datetime import datetime

from mship.core.message_store import MessageStore
from mship.core.spec_store import SpecStore
from mship.core.state import StateManager
from mship.core.workitem_store import WorkItemStore


def wrap_existing(items: WorkItemStore, specs: SpecStore, state: StateManager,
                  msgs: MessageStore, now: datetime) -> list[str]:
    """Idempotently wrap every spec/task lacking a work_item_id in a WorkItem.
    Returns the ids of newly created items."""
    created: list[str] = []
    workspace = "mothership"

    state_now = state.load()
    task_by_slug = dict(state_now.tasks)

    # 1) Specs -> feature items (carrying their linked task).
    for spec in specs.list():
        if spec.work_item_id:
            continue
        wi = items.create(title=spec.title, kind="feature", workspace=workspace, now=now)
        created.append(wi.id)
        items.link_spec(wi.id, spec.id, now=now)
        spec.work_item_id = wi.id
        specs.save(spec)
        if spec.task_slug and spec.task_slug in task_by_slug:
            items.add_task(wi.id, spec.task_slug, now=now)

            def _set(s, _slug=spec.task_slug, _wid=wi.id):
                if _slug in s.tasks:
                    s.tasks[_slug].work_item_id = _wid
            state.mutate(_set)

    # 2) Orphan tasks (no spec, no work_item_id) -> chore items.
    for slug, task in state.load().tasks.items():
        if task.work_item_id or task.spec_id:
            continue
        wi = items.create(title=task.description or slug, kind="chore",
                          workspace=workspace, now=now)
        created.append(wi.id)
        items.add_task(wi.id, slug, now=now)

        def _set(s, _slug=slug, _wid=wi.id):
            if _slug in s.tasks:
                s.tasks[_slug].work_item_id = _wid
        state.mutate(_set)

    # 3) Threads -> attach to the item their spec/task already belongs to.
    item_by_spec = {w.spec_id: w.id for w in items.list() if w.spec_id}
    item_by_task = {slug: w.id for w in items.list() for slug in w.task_slugs}
    for thread in msgs.list():
        target = (item_by_spec.get(thread.spec_id) if thread.spec_id else None) \
            or (item_by_task.get(thread.task_slug) if thread.task_slug else None)
        if target:
            items.add_thread(target, thread.id, now=now)

    return created
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_workitem_migrate.py -v`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/workitem_migrate.py tests/core/test_workitem_migrate.py
git commit -m "feat(workitem): migration wrapping existing specs/tasks"
mship journal "wrap_existing migration + tests" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=8 -->
### Task 8: CLI — `mship item` group

`new`, `list`, `show`, `link-spec`, `link-task`, `link-url`, `phase`, `migrate`. Resolves stores from `container.state_dir()` (workitems/messages/state) and `container.config_path()` parent (specs dir).

**Files:**
- Create: `src/mship/cli/workitem.py`
- Modify: `src/mship/cli/__init__.py` (import + register)
- Test: `tests/cli/test_workitem.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/cli/test_workitem.py
import json

from typer.testing import CliRunner

from mship.cli import app, container

runner = CliRunner()


def _isolate(tmp_path):
    """Point the global container at a throwaway workspace."""
    (tmp_path / "mothership.yaml").write_text("workspace: testws\n")
    container.config_path.override(tmp_path / "mothership.yaml")
    container.state_dir.override(tmp_path / ".mothership")
    container.config.reset()  # drop any singleton cached by another test


def test_new_then_list_roundtrip(tmp_path):
    _isolate(tmp_path)
    try:
        res = runner.invoke(app, ["item", "new", "Make capture conversational", "--kind", "feature"])
        assert res.exit_code == 0, res.output
        res = runner.invoke(app, ["--json", "item", "list"])
        assert res.exit_code == 0, res.output
        rows = json.loads(res.output)
        assert len(rows) == 1
        assert rows[0]["title"] == "Make capture conversational"
        assert rows[0]["phase"] == "inbox"
    finally:
        container.config_path.reset_override()
        container.state_dir.reset_override()
        container.config.reset()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/cli/test_workitem.py -v`
Expected: FAIL — no `item` command (`exit_code != 0`)

- [ ] **Step 3: Write minimal implementation**

```python
# src/mship/cli/workitem.py
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import typer

from mship.core.message_store import MessageStore
from mship.core.spec_store import SPECS_DIRNAME, SpecStore
from mship.core.workitem import ExternalLink
from mship.core.workitem_store import WorkItemStore
from mship.core.view.workitem_index import build_workitem_index


def register(parent: typer.Typer, get_container) -> None:
    item_app = typer.Typer(help="First-class work items (the phase-aware cockpit spine).")
    parent.add_typer(item_app, name="item")

    def _ctx():
        container = get_container()
        state_dir = Path(container.state_dir())
        workspace_root = Path(container.config_path()).parent
        return (
            WorkItemStore(state_dir / "workitems"),
            SpecStore(workspace_root / SPECS_DIRNAME),
            container.state_manager(),
            MessageStore(state_dir / "messages"),
            container.config().workspace,
        )

    @item_app.command("new")
    def new(title: str, kind: str = typer.Option("feature", "--kind",
            help="feature | bug | chore | question")):
        items, _, _, _, workspace = _ctx()
        wi = items.create(title=title, kind=kind, workspace=workspace,
                          now=datetime.now(timezone.utc))
        typer.echo(wi.id)

    @item_app.command("list")
    def list_items():
        items, specs, state_manager, msgs, _ = _ctx()
        summaries = build_workitem_index(
            items.list(),
            {s.id: s for s in specs.list()},
            dict(state_manager.load().tasks),
            {t.id: t for t in msgs.list()},
        )
        rows = [{"id": s.id, "title": s.title, "kind": s.kind, "phase": s.phase,
                 "needs_approval": s.attention.needs_approval,
                 "needs_decision": s.attention.needs_decision,
                 "blocked": s.attention.blocked, "needs_review": s.attention.needs_review}
                for s in summaries]
        if sys.stdout.isatty():
            for r in rows:
                flags = "".join(k[0].upper() for k in
                                ("needs_approval", "needs_decision", "blocked", "needs_review")
                                if r[k])
                typer.echo(f"{r['id']}  [{r['phase']}]  {r['title']}  {flags}")
            if not rows:
                typer.echo("(no work items)")
        else:
            typer.echo(json.dumps(rows))

    @item_app.command("show")
    def show(item_id: str):
        items, _, _, _, _ = _ctx()
        wi = items.get(item_id)
        if wi is None:
            typer.echo(f"no work item {item_id!r}", err=True)
            raise typer.Exit(1)
        typer.echo(wi.model_dump_json(indent=2))

    @item_app.command("link-spec")
    def link_spec(item_id: str, spec_id: str):
        items, _, _, _, _ = _ctx()
        _guard(items, item_id)
        items.link_spec(item_id, spec_id, now=datetime.now(timezone.utc))
        typer.echo(f"linked spec {spec_id} -> {item_id}")

    @item_app.command("link-task")
    def link_task(item_id: str, task_slug: str):
        items, _, _, _, _ = _ctx()
        _guard(items, item_id)
        items.add_task(item_id, task_slug, now=datetime.now(timezone.utc))
        typer.echo(f"linked task {task_slug} -> {item_id}")

    @item_app.command("link-url")
    def link_url(item_id: str, url: str,
                 provider: str = typer.Option("url", "--provider"),
                 title: str = typer.Option("", "--title")):
        items, _, _, _, _ = _ctx()
        _guard(items, item_id)
        items.add_external_link(item_id, ExternalLink(provider=provider, url=url, title=title),
                                now=datetime.now(timezone.utc))
        typer.echo(f"linked {provider} url -> {item_id}")

    @item_app.command("phase")
    def phase(item_id: str, phase: str):
        items, _, _, _, _ = _ctx()
        _guard(items, item_id)
        items.set_phase_override(item_id, phase, now=datetime.now(timezone.utc))
        typer.echo(f"set phase_override={phase} on {item_id}")

    @item_app.command("migrate")
    def migrate():
        from mship.core.workitem_migrate import wrap_existing
        items, specs, state_manager, msgs, _ = _ctx()
        created = wrap_existing(items, specs, state_manager, msgs, now=datetime.now(timezone.utc))
        typer.echo(f"created {len(created)} work item(s)")

    def _guard(items: WorkItemStore, item_id: str) -> None:
        if items.get(item_id) is None:
            typer.echo(f"no work item {item_id!r}", err=True)
            raise typer.Exit(1)
```

In `src/mship/cli/__init__.py`, add the import alongside the others (after line 141, `from mship.cli import worktree as _worktree_mod`):

```python
from mship.cli import workitem as _workitem_mod
```

and the registration alongside the others (after line 199, `_worktree_mod.register(app, get_container)`):

```python
_workitem_mod.register(app, get_container)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/cli/test_workitem.py -v`
Expected: PASS

- [ ] **Step 5: Smoke-test the help wiring**

Run: `uv run mship item --help`
Expected: lists `new`, `list`, `show`, `link-spec`, `link-task`, `link-url`, `phase`, `migrate`

- [ ] **Step 6: Commit**

```bash
git add src/mship/cli/workitem.py src/mship/cli/__init__.py tests/cli/test_workitem.py
git commit -m "feat(workitem): mship item CLI group"
mship journal "mship item CLI + register + tests" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=9 -->
### Task 9: serve — `GET /items` and `GET /items/{id}`

Add the two read endpoints just before `return app`, mirroring `/tasks` (shared projection via `jsonable_encoder(build_workitem_index(...))`) and the `MessageStore` construction already in serve.

**Files:**
- Modify: `src/mship/core/serve.py` (insert before `return app` at line ~387; the `msgs` `MessageStore` and `store` `SpecStore` are already in scope)
- Test: `tests/core/test_serve_items.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_serve_items.py
from datetime import datetime, timezone

from fastapi.testclient import TestClient

from mship.core.serve import create_app
from mship.core.spec_store import SpecStore
from mship.core.state import StateManager
from mship.core.workitem_store import WorkItemStore


def _now():
    return datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc)


def _app(tmp_path):
    specs_dir = tmp_path / "specs"
    SpecStore(specs_dir)  # ensure dir resolvable
    state_manager = StateManager(tmp_path / ".mothership")
    app = create_app(specs_dir=specs_dir, state_manager=state_manager, log_manager=None,
                     workspace_root=tmp_path, workspace_name="testws")
    return TestClient(app)


def test_list_items_empty(tmp_path):
    client = _app(tmp_path)
    assert client.get("/items").json() == []


def test_list_and_get_item_with_derived_phase(tmp_path):
    items = WorkItemStore(tmp_path / ".mothership" / "workitems")
    wi = items.create(title="Captured idea", kind="question", workspace="testws", now=_now())
    client = _app(tmp_path)

    listed = client.get("/items").json()
    assert len(listed) == 1
    assert listed[0]["id"] == wi.id
    assert listed[0]["phase"] == "inbox"
    assert listed[0]["attention"]["blocked"] is False

    got = client.get(f"/items/{wi.id}").json()
    assert got["id"] == wi.id and got["phase"] == "inbox"

    assert client.get("/items/nope").status_code == 404
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_serve_items.py -v`
Expected: FAIL — 404 on `/items` (route not defined → `test_list_items_empty` fails)

- [ ] **Step 3: Write minimal implementation**

In `src/mship/core/serve.py`, immediately before the final `return app` (line ~387), add:

```python
    # --- work items (phase-aware cockpit spine) ---
    from mship.core.workitem_store import WorkItemStore
    from mship.core.view.workitem_index import build_workitem_index

    workitems = WorkItemStore(workspace_root / ".mothership" / "workitems")

    def _workitem_index():
        return build_workitem_index(
            workitems.list(),
            {s.id: s for s in store.list()},
            dict(state_manager.load().tasks),
            {t.id: t for t in msgs.list()},
        )

    @app.get("/items")
    def list_items():
        return jsonable_encoder(_workitem_index())

    @app.get("/items/{item_id}")
    def get_item(item_id: str):
        for summary in _workitem_index():
            if summary.id == item_id:
                return jsonable_encoder(summary)
        raise HTTPException(status_code=404, detail=f"no work item {item_id!r}")
```

(`jsonable_encoder` is already imported at module scope near the `/tasks` endpoint; `store`, `state_manager`, `msgs`, and `workspace_root` are all in scope.)

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_serve_items.py -v`
Expected: PASS (2 tests)

- [ ] **Step 5: Run the full serve suite for regressions**

Run: `uv run pytest tests/core/test_serve.py -v`
Expected: PASS (existing endpoints unaffected)

- [ ] **Step 6: Commit**

```bash
git add src/mship/core/serve.py tests/core/test_serve_items.py
git commit -m "feat(workitem): serve GET /items and /items/{id}"
mship journal "serve /items endpoints + tests" --action committed
```
<!-- /mship:task -->

---

## Final verification

- [ ] **Run the whole suite**

Run: `mship test` (or `uv run pytest -q`)
Expected: all green, including the new `tests/core/test_workitem*.py`, `tests/core/view/test_workitem_index.py`, `tests/cli/test_workitem.py`, `tests/core/test_serve_items.py`.

- [ ] **Manual smoke** (optional)

```bash
uv run mship item migrate          # wraps existing specs/tasks
uv run mship item list             # see them binned (phase derived)
```

---

## Notes / deferred to later slices

- **Auto-inheritance of `work_item_id`** on `mship spec new` / `mship dispatch` (so new specs/tasks attach to a parent without `mship item link-*`) is a small fast-follow — out of scope here; the migration + explicit `link-*` cover the foundation. Flagged for MOS-196 follow-up.
- **Write endpoints** (`POST /items`, link, set-phase) land with the cockpit slices that need them (MOS-198/202/199); the foundation ships reads + CLI writes.
- **`done`-on-merge precision**: `compute_phase` treats a finished task *with a PR* as `review`; true `done`-after-all-PRs-merged needs PR-merge state, which arrives with the Review·Merge slice (MOS-199). Manual `mship item phase <id> done` covers closed items meanwhile.
- **Kind-gating is behavioral, not enforced**: `compute_phase` keys off child state, so a `feature` naturally walks the full pipeline while a `bug`/`chore` (dispatched straight to tasks) skips Shaping/Ready and a `question` (never spawns a task) sits in `inbox` until manually closed. The foundation does not *validate* kind→phase legality (e.g. it won't reject attaching a spec to a `question`); that guard, if wanted, is a cheap follow-up.
