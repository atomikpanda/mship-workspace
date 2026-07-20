# PR2 — mship view: master/detail foundation + WorkItem cockpit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** mship-view-needs-a-major-overhaul-to

**Goal:** Build a reusable, lazygit-style master/detail Textual foundation (a navigable list pane beside a detail pane, with a `tab` focus model, `j`/`k`/arrow/`enter` navigation, an incremental `/` filter, and a footer action bar) as a sibling to the existing single-body `ViewApp`, and on top of it ship a new `mship view workitem <id>` cockpit that renders one WorkItem's spec (status + phase), its acceptance criteria with evidence, its tasks + worktrees, and its linked PRs + threads — all sourced from the canonical stores via a pure, Textual-free assembly function.

**Architecture:** Three thin layers, mirroring PR1's split. (1) A **generic Textual base** `MasterDetailApp(App)` in a NEW module `src/mship/cli/view/_master_detail.py`, entirely independent of the data it shows: subclasses supply rows via a `list_rows() -> list[ListRow]` hook and an optional `header_line()`; the base owns compose, selection, the focus model, filtering, and the footer. It is a *sibling* of `ViewApp`, so the existing single-body views (status/journal/diff/spec from PR1) are not touched and cannot regress. (2) A **pure cockpit-model assembly** `assemble_cockpit(...)` plus small formatters + `render_text(...)` in a NEW `src/mship/core/view/workitem_cockpit.py`, folding already-resolved canonical objects (`WorkItemSummary` + `Spec` + `Task`s + `Thread`s) into a flat, render-ready `WorkItemCockpit` dataclass — no Textual, no container, unit-tested directly. (3) A **thin CLI seam** `src/mship/cli/view/workitem.py`: a `WorkItemCockpitView(MasterDetailApp)` that maps the cockpit to rows, a store resolver that feeds it, and the `mship view workitem` Typer command (with a non-TTY text short-circuit mirroring `spec.py`).

**Tech Stack:** Python 3.14, uv, pytest (`uv run pytest`, `pythonpath=["src"]`, `asyncio_mode=auto`), Textual 8.2.3 (`App`, `ListView`/`ListItem`, `VerticalScroll`, `Input`, `Footer`, `run_test()`/pilot), Pydantic v2 models (`Spec`, `WorkItem`, `Task`, `Thread`), Typer CLI, `dependency_injector` container. Reuses PR1's `load_workitem_index(container)`, `WorkItemSummary`, and the canonical stores (`SpecStore`, `WorkItemStore`, `MessageStore`, `StateManager`).

---

## File Structure

Create:
- `src/mship/cli/view/_master_detail.py` — generic `MasterDetailApp(App)` + `ListRow` dataclass: the reusable list-pane/detail-pane foundation (focus model, `j`/`k`/`enter` nav, `/` filter, footer action bar). Reusable by the future `queue` view. (AC6)
- `src/mship/core/view/workitem_cockpit.py` — pure assembly: `WorkItemCockpit`, `CriterionView`, `TaskView`, `PRView`, `ThreadView`, `assemble_cockpit(...)`, per-entity formatters, `render_text(...)`. (AC3)
- `src/mship/cli/view/workitem.py` — `WorkItemCockpitView(MasterDetailApp)`, `build_rows(...)`, store resolver, and the `mship view workitem <id>` command + `register(...)`. (AC3, AC6)
- `tests/cli/view/test_master_detail.py` — pilot tests for the generic foundation.
- `tests/core/view/test_workitem_cockpit.py` — pure assembly/formatter tests.
- `tests/cli/view/test_workitem_view.py` — widget pilot tests + CLI tests.

Modify:
- `src/mship/cli/view/__init__.py` — import and `register` the new `workitem` command (one added import + one added call).

Not touched (no regression surface): `_base.py` (`ViewApp`), `status.py`, `spec.py`, `diff.py`, `logs.py`, and all PR1 `core/view/` modules.

**Staging note:** each commit stages ONLY the files it names (there may be a stray `uv.lock` change in the tree — never `git add` it, never `git add -A`).

---

<!-- mship:task id=1 -->
## Task 1 — Generic master/detail base: list pane + detail pane (AC6)

**Files:**
- Create: `src/mship/cli/view/_master_detail.py`
- Create: `tests/cli/view/test_master_detail.py`

- [ ] **Step 1: Write the failing test** — `tests/cli/view/test_master_detail.py`:

```python
import pytest

from mship.cli.view._master_detail import ListRow, MasterDetailApp


class _DemoView(MasterDetailApp):
    """Tiny concrete subclass so the generic base can be exercised in isolation."""

    def __init__(self, rows, **kw):
        super().__init__(**kw)
        self._rows_src = list(rows)

    def list_rows(self):
        return self._rows_src

    def header_line(self):
        return "DEMO HEADER"


@pytest.mark.asyncio
async def test_list_populated_and_detail_follows_highlight():
    rows = [ListRow("a", "Alpha", "Detail A"), ListRow("b", "Bravo", "Detail B")]
    view = _DemoView(rows)
    async with view.run_test() as pilot:
        await pilot.pause()
        assert view.list_labels() == ["Alpha", "Bravo"]
        assert view.header_text() == "DEMO HEADER"
        # First row is highlighted on mount; the detail pane shows its detail.
        assert view.selected_key() == "a"
        assert view.detail_text() == "Detail A"


@pytest.mark.asyncio
async def test_empty_rows_render_without_error():
    view = _DemoView([])
    async with view.run_test() as pilot:
        await pilot.pause()
        assert view.list_labels() == []
        assert view.selected_key() is None
        assert view.detail_text() == ""
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/cli/view/test_master_detail.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'mship.cli.view._master_detail'`.

- [ ] **Step 3: Write minimal implementation** — `src/mship/cli/view/_master_detail.py`:

```python
"""Reusable lazygit-style master/detail Textual foundation for mship views.

A navigable list pane (left) beside a detail pane (right), a focus model (`tab`
toggles focus), list navigation (`j`/`k`/arrows move the highlight, `enter` drills
into the detail pane), an incremental filter (`/`), and a footer action bar that
renders the available keys.

Sibling to `ViewApp` (which stays the single-body `gather()` base for the stream
views status/journal/diff/spec, untouched here). This base is data-source
agnostic: subclasses implement `list_rows()` (and optionally `header_line()`); the
base owns compose, selection, focus, filtering, and the footer. Kept generic so
the future `queue` view reuses it unchanged.
"""
from __future__ import annotations

import re
from dataclasses import dataclass

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, VerticalScroll
from textual.widgets import Footer, Input, Label, ListItem, ListView, Static


@dataclass(frozen=True)
class ListRow:
    """One selectable row in the master list.

    `key` is a stable identifier (used by tests + future navigation), `label` is
    what shows in the list, `detail` is the pre-rendered text shown in the detail
    pane when the row is highlighted.
    """
    key: str
    label: str
    detail: str


class MasterDetailApp(App):
    CSS = """
    ListView#master {
        width: 40%;
        min-width: 24;
        border-right: tall $accent;
    }
    """

    # `tab` is priority so it beats Textual's built-in Screen `tab`->focus_next
    # binding; every other key stays non-priority so it can be typed into the
    # filter Input while that Input is focused.
    BINDINGS = [
        Binding("q", "quit", "Quit"),
        Binding("ctrl+c", "quit", "Quit", show=False),
        Binding("r", "reload", "Refresh"),
        Binding("tab", "toggle_focus", "Switch pane", priority=True),
        Binding("slash", "start_filter", "Filter"),
        Binding("enter", "drill", "Open"),
        Binding("j,down", "nav_down", "Down", show=False),
        Binding("k,up", "nav_up", "Up", show=False),
        Binding("escape", "close_filter", "Close filter", show=False),
    ]

    def __init__(self, **kw) -> None:
        super().__init__(**kw)
        self._header: Static | None = None
        self._master: ListView | None = None
        self._detail_static: Static | None = None
        self._detail: VerticalScroll | None = None
        self._filter_input: Input | None = None
        self._filter: str = ""
        self._rows: list[ListRow] = []       # all rows (unfiltered)
        self._visible: list[ListRow] = []    # rows after the active filter

    # --- subclass hooks ---
    def list_rows(self) -> list[ListRow]:
        raise NotImplementedError

    def header_line(self) -> str | None:
        return None

    async def reload_rows(self) -> None:
        """Re-fetch rows on `r`. Default: rebuild from `list_rows()` (static
        snapshot). Subclasses backed by a live store override to re-query."""
        await self._rebuild()

    # --- lifecycle ---
    def compose(self) -> ComposeResult:
        self._header = Static("")
        self._master = ListView(id="master")
        self._detail_static = Static("", expand=True)
        self._detail = VerticalScroll(self._detail_static, id="detail")
        self._filter_input = Input(placeholder="filter (/ to focus)…", id="filter")
        yield self._header
        yield Horizontal(self._master, self._detail)
        yield self._filter_input
        yield Footer()

    async def on_mount(self) -> None:
        await self._rebuild()

    # --- rendering ---
    async def _rebuild(self) -> None:
        assert self._header is not None
        self._rows = list(self.list_rows())
        self._header.update(self.header_line() or "")
        await self._apply_filter()

    async def _apply_filter(self) -> None:
        assert self._master is not None
        needle = self._filter.strip().lower()
        self._visible = (
            [r for r in self._rows if needle in r.label.lower()] if needle
            else list(self._rows)
        )
        await self._master.clear()
        await self._master.extend([ListItem(Label(r.label)) for r in self._visible])
        self.call_after_refresh(self._update_detail)

    def _current_index(self) -> int | None:
        assert self._master is not None
        if not self._visible:
            return None
        idx = self._master.index
        return idx if idx is not None and 0 <= idx < len(self._visible) else 0

    def _update_detail(self) -> None:
        assert self._detail_static is not None
        idx = self._current_index()
        self._detail_static.update("" if idx is None else self._visible[idx].detail)

    def on_list_view_highlighted(self, event) -> None:  # Textual: ListView.Highlighted
        self._update_detail()

    async def action_reload(self) -> None:
        await self.reload_rows()

    # --- test helpers ---
    _ANSI = re.compile(r"\x1b\[[0-9;]*[mKHFABCDJsu]")

    def list_labels(self) -> list[str]:
        return [r.label for r in self._visible]

    def detail_text(self) -> str:
        assert self._detail_static is not None
        return self._ANSI.sub("", str(self._detail_static.content))

    def header_text(self) -> str:
        assert self._header is not None
        return str(self._header.content)

    def selected_key(self) -> str | None:
        idx = self._current_index()
        return None if idx is None else self._visible[idx].key
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/cli/view/test_master_detail.py -q`
Expected: PASS (2 passed).

- [ ] **Step 5: Commit**

```bash
git add src/mship/cli/view/_master_detail.py tests/cli/view/test_master_detail.py
git commit -m "cli/view: reusable master/detail foundation — list+detail panes (AC6)"
mship journal "Add MasterDetailApp base: list_rows/header_line hooks, list+detail render (AC6)" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=2 -->
## Task 2 — Focus model: `tab` switches focus between list and detail (AC6)

**Files:**
- Modify: `src/mship/cli/view/_master_detail.py`
- Modify: `tests/cli/view/test_master_detail.py` (append)

- [ ] **Step 1: Write the failing test** — append to `tests/cli/view/test_master_detail.py`:

```python
@pytest.mark.asyncio
async def test_tab_toggles_focus_between_panes():
    view = _DemoView([ListRow("a", "Alpha", "Detail A")])
    async with view.run_test() as pilot:
        await pilot.pause()
        view._master.focus()
        await pilot.pause()
        assert view.focus_target() == "master"
        await pilot.press("tab")
        await pilot.pause()
        assert view.focus_target() == "detail"
        await pilot.press("tab")
        await pilot.pause()
        assert view.focus_target() == "master"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/cli/view/test_master_detail.py -k tab_toggles -q`
Expected: FAIL with `AttributeError: 'MasterDetailApp' object has no attribute 'focus_target'` (and no `action_toggle_focus`).

- [ ] **Step 3: Write minimal implementation** — add these methods to `MasterDetailApp` in `src/mship/cli/view/_master_detail.py` (place after `action_reload`):

```python
    # --- focus model ---
    def _detail_focused(self) -> bool:
        return self._detail is not None and self._detail.has_focus

    def action_toggle_focus(self) -> None:
        if self._master is None or self._detail is None:
            return
        if self._detail_focused():
            self._master.focus()
        else:
            self._detail.focus()
```

and add this test helper alongside the others (after `selected_key`):

```python
    def focus_target(self) -> str:
        if self._filter_input is not None and self._filter_input.has_focus:
            return "filter"
        if self._detail_focused():
            return "detail"
        return "master"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/cli/view/test_master_detail.py -q`
Expected: PASS (3 passed).

- [ ] **Step 5: Commit**

```bash
git add src/mship/cli/view/_master_detail.py tests/cli/view/test_master_detail.py
git commit -m "cli/view master/detail: tab focus model between list and detail (AC6)"
mship journal "MasterDetailApp: tab toggles focus master<->detail (priority binding beats Screen focus_next) (AC6)" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=3 -->
## Task 3 — Navigation: `j`/`k` move selection or scroll detail, `enter` drills (AC6)

**Files:**
- Modify: `src/mship/cli/view/_master_detail.py`
- Modify: `tests/cli/view/test_master_detail.py` (append)

- [ ] **Step 1: Write the failing test** — append to `tests/cli/view/test_master_detail.py`:

```python
@pytest.mark.asyncio
async def test_j_k_move_selection_when_master_focused():
    rows = [ListRow("a", "Alpha", "dA"), ListRow("b", "Bravo", "dB"),
            ListRow("c", "Cara", "dC")]
    view = _DemoView(rows)
    async with view.run_test() as pilot:
        await pilot.pause()
        view._master.focus()
        await pilot.pause()
        assert view.selected_key() == "a"
        await pilot.press("j")
        await pilot.pause()
        assert view.selected_key() == "b"
        assert view.detail_text() == "dB"
        await pilot.press("k")
        await pilot.pause()
        assert view.selected_key() == "a"
        assert view.detail_text() == "dA"


@pytest.mark.asyncio
async def test_enter_drills_into_detail():
    view = _DemoView([ListRow("a", "Alpha", "dA")])
    async with view.run_test() as pilot:
        await pilot.pause()
        view._master.focus()
        await pilot.pause()
        assert view.focus_target() == "master"
        await pilot.press("enter")
        await pilot.pause()
        assert view.focus_target() == "detail"


@pytest.mark.asyncio
async def test_j_scrolls_detail_when_detail_focused():
    long_detail = "\n".join(f"line {i}" for i in range(200))
    view = _DemoView([ListRow("a", "Alpha", long_detail)])
    async with view.run_test() as pilot:
        await pilot.pause()
        await pilot.press("tab")  # focus the detail pane
        await pilot.pause()
        assert view.focus_target() == "detail"
        assert view.detail_scroll_y() == 0
        for _ in range(5):
            await pilot.press("j")
        await pilot.pause()
        assert view.detail_scroll_y() > 0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/cli/view/test_master_detail.py -k "move_selection or drills or scrolls_detail" -q`
Expected: FAIL — pressing `j`/`k`/`enter` finds no `action_nav_down`/`action_nav_up`/`action_drill` (and no `detail_scroll_y` helper).

- [ ] **Step 3: Write minimal implementation** — add these to `MasterDetailApp` in `src/mship/cli/view/_master_detail.py` (after the focus-model block):

```python
    # --- navigation ---
    def action_nav_down(self) -> None:
        if self._detail_focused():
            assert self._detail is not None
            self._detail.scroll_relative(y=1, animate=False)
        elif self._master is not None:
            self._master.action_cursor_down()

    def action_nav_up(self) -> None:
        if self._detail_focused():
            assert self._detail is not None
            self._detail.scroll_relative(y=-1, animate=False)
        elif self._master is not None:
            self._master.action_cursor_up()

    def action_drill(self) -> None:
        # Enter drills into the highlighted entity: focus the detail pane so it
        # can be scrolled/read. (Cross-entity open/copy is a later PR.)
        if self._detail is not None:
            self._detail.focus()

    def on_list_view_selected(self, event) -> None:  # Textual: ListView.Selected (enter)
        self.action_drill()
```

and add this test helper alongside the others:

```python
    def detail_scroll_y(self) -> float:
        assert self._detail is not None
        return self._detail.scroll_y
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/cli/view/test_master_detail.py -q`
Expected: PASS (6 passed).

- [ ] **Step 5: Commit**

```bash
git add src/mship/cli/view/_master_detail.py tests/cli/view/test_master_detail.py
git commit -m "cli/view master/detail: j/k nav + enter drill into detail (AC6)"
mship journal "MasterDetailApp: j/k move selection (or scroll detail when focused), enter drills into detail (AC6)" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=4 -->
## Task 4 — Incremental filter: `/` filters the list (AC6)

**Files:**
- Modify: `src/mship/cli/view/_master_detail.py`
- Modify: `tests/cli/view/test_master_detail.py` (append)

- [ ] **Step 1: Write the failing test** — append to `tests/cli/view/test_master_detail.py`:

```python
@pytest.mark.asyncio
async def test_slash_filters_list_incrementally():
    rows = [ListRow("a", "Alpha", "dA"), ListRow("b", "Bravo", "dB"),
            ListRow("c", "Alpaca", "dC")]
    view = _DemoView(rows)
    async with view.run_test() as pilot:
        await pilot.pause()
        assert len(view.list_labels()) == 3
        await pilot.press("slash")
        await pilot.pause()
        assert view.focus_target() == "filter"
        for ch in "alp":
            await pilot.press(ch)
        await pilot.pause()
        # "alp" (case-insensitive) matches Alpha and Alpaca, not Bravo.
        assert set(view.list_labels()) == {"Alpha", "Alpaca"}
        await pilot.press("enter")  # submit closes the filter, refocuses the list
        await pilot.pause()
        assert view.focus_target() == "master"
        # Filter text persists; list stays filtered.
        assert set(view.list_labels()) == {"Alpha", "Alpaca"}


@pytest.mark.asyncio
async def test_escape_closes_filter_and_refocuses_master():
    view = _DemoView([ListRow("a", "Alpha", "dA")])
    async with view.run_test() as pilot:
        await pilot.pause()
        await pilot.press("slash")
        await pilot.pause()
        assert view.focus_target() == "filter"
        await pilot.press("escape")
        await pilot.pause()
        assert view.focus_target() == "master"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/cli/view/test_master_detail.py -k "filters_list or escape_closes" -q`
Expected: FAIL — `/` finds no `action_start_filter`, so focus never moves to the filter Input.

- [ ] **Step 3: Write minimal implementation** — add these to `MasterDetailApp` in `src/mship/cli/view/_master_detail.py` (after the navigation block):

```python
    # --- incremental filter ---
    def action_start_filter(self) -> None:
        if self._filter_input is not None:
            self._filter_input.focus()

    def action_close_filter(self) -> None:
        if self._master is not None:
            self._master.focus()

    async def on_input_changed(self, event) -> None:  # Textual: Input.Changed
        if event.input is self._filter_input:
            self._filter = event.value
            await self._apply_filter()

    def on_input_submitted(self, event) -> None:  # Textual: Input.Submitted (enter)
        if event.input is self._filter_input:
            self.action_close_filter()
```

(No new bindings needed — `slash` and `escape` are already in `BINDINGS` from Task 1; the filter `Input` is already composed. Typed characters reach the Input because it is the focused widget and the `j`/`k`/`slash` bindings are non-priority.)

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/cli/view/test_master_detail.py -q`
Expected: PASS (8 passed).

- [ ] **Step 5: Commit**

```bash
git add src/mship/cli/view/_master_detail.py tests/cli/view/test_master_detail.py
git commit -m "cli/view master/detail: incremental / filter over the list (AC6)"
mship journal "MasterDetailApp: / focuses filter Input, incremental Changed filters rows, enter/escape close (AC6)" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=5 -->
## Task 5 — Pure WorkItem cockpit assembly + text renderer (AC3)

**Files:**
- Create: `src/mship/core/view/workitem_cockpit.py`
- Create: `tests/core/view/test_workitem_cockpit.py`

- [ ] **Step 1: Write the failing test** — `tests/core/view/test_workitem_cockpit.py`:

```python
from datetime import datetime, timezone
from pathlib import Path

from mship.core.message import Thread
from mship.core.spec import AcceptanceCriterion, AcceptanceEvidence, Spec
from mship.core.state import Task
from mship.core.workitem import WorkItem
from mship.core.view.workitem_index import build_workitem_index
from mship.core.view.workitem_cockpit import assemble_cockpit, render_text


def _now():
    return datetime(2026, 7, 1, tzinfo=timezone.utc)


def _spec():
    return Spec(
        id="spec-1", title="Overhaul spec", status="needs_review",
        created_at=_now(), updated_at=_now(),
        acceptance_criteria=[
            AcceptanceCriterion(
                id="ac1", text="does X",
                evidence=[AcceptanceEvidence(kind="test", ref="test-runs/1", note="green")]),
            AcceptanceCriterion(id="ac2", text="does Y"),
        ],
        body="b\n")


def _task():
    return Task(
        slug="a", description="d", phase="dev", created_at=_now(),
        affected_repos=["r"], branch="feat/a",
        worktrees={"r": Path("/tmp/wt-a")}, pr_urls={"r": "https://gh/pr/1"})


def _thread():
    return Thread(id="th-1", subject="Question about X",
                  created_at=_now(), updated_at=_now())


def _cockpit():
    spec, task, thread = _spec(), _task(), _thread()
    wi = WorkItem(id="wi-1", title="Overhaul", workspace="ws", kind="feature",
                  created_at=_now(), updated_at=_now(), spec_id="spec-1",
                  task_slugs=["a"], thread_ids=["th-1"])
    summary = build_workitem_index([wi], {"spec-1": spec}, {"a": task}, {"th-1": thread})[0]
    return assemble_cockpit(summary, spec, [task], [thread])


def test_cockpit_carries_spec_status_title_and_derived_phase():
    c = _cockpit()
    assert c.id == "wi-1" and c.title == "Overhaul" and c.kind == "feature"
    assert c.spec_id == "spec-1"
    assert c.spec_status == "needs_review"
    assert c.spec_title == "Overhaul spec"
    # needs_review spec (non-terminal) + one unfinished task -> in_flight.
    assert c.phase == "in_flight"


def test_cockpit_criteria_with_evidence():
    c = _cockpit()
    assert [x.id for x in c.criteria] == ["ac1", "ac2"]
    assert c.criteria[0].verdict == "unreviewed"
    assert c.criteria[0].evidence[0].ref == "test-runs/1"
    assert c.criteria[0].evidence[0].note == "green"
    assert c.criteria[1].evidence == []


def test_cockpit_tasks_carry_worktrees_and_branch():
    c = _cockpit()
    assert c.tasks[0].slug == "a"
    assert c.tasks[0].phase == "dev"
    assert c.tasks[0].worktrees == {"r": "/tmp/wt-a"}


def test_cockpit_prs_aggregated_from_task_pr_urls():
    c = _cockpit()
    assert len(c.prs) == 1
    assert c.prs[0].repo == "r"
    assert c.prs[0].task_slug == "a"
    assert c.prs[0].url == "https://gh/pr/1"


def test_cockpit_threads_carry_subject_and_flags():
    c = _cockpit()
    assert c.threads[0].id == "th-1"
    assert c.threads[0].subject == "Question about X"
    assert c.threads[0].needs_you is False


def test_cockpit_without_spec_is_safe():
    wi = WorkItem(id="wi-2", title="No spec", workspace="ws", kind="chore",
                  created_at=_now(), updated_at=_now())
    summary = build_workitem_index([wi], {}, {}, {})[0]
    c = assemble_cockpit(summary, None, [], [])
    assert c.spec_id is None and c.spec_status is None
    assert c.criteria == [] and c.tasks == [] and c.prs == [] and c.threads == []


def test_render_text_includes_every_section():
    txt = render_text(_cockpit())
    assert "wi-1" in txt and "Overhaul" in txt and "[in_flight]" in txt
    assert "needs_review" in txt
    assert "ac1" in txt and "green" in txt      # criterion + its evidence note
    assert "worktrees" in txt and "/tmp/wt-a" in txt
    assert "https://gh/pr/1" in txt
    assert "Question about X" in txt
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/view/test_workitem_cockpit.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'mship.core.view.workitem_cockpit'`.

- [ ] **Step 3: Write minimal implementation** — `src/mship/core/view/workitem_cockpit.py`:

```python
"""Pure assembly of a single-WorkItem cockpit model for `mship view workitem` (AC3).

Sourced from already-resolved canonical objects: a `WorkItemSummary` (for the
derived phase + id/title/kind/links), the linked `Spec` (status + acceptance
criteria with evidence), the item's `Task`s (worktrees + recorded PR urls), and its
`Thread`s. No Textual, no container, no store I/O — the whole cockpit shape is
unit-testable directly. The Textual `WorkItemCockpitView` and the CLI command wire
thin on top; the per-entity formatters below are shared by both the flat text
renderer (non-TTY) and the TUI row builder.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime

from mship.core.message import Thread
from mship.core.spec import AcceptanceEvidence, Spec
from mship.core.state import Task
from mship.core.view.workitem_index import WorkItemSummary


@dataclass(frozen=True)
class CriterionView:
    id: str
    text: str
    verdict: str
    evidence: list[AcceptanceEvidence] = field(default_factory=list)


@dataclass(frozen=True)
class TaskView:
    slug: str
    phase: str
    branch: str
    worktrees: dict[str, str]
    pr_urls: dict[str, str]
    blocked_reason: str | None
    finished_at: datetime | None


@dataclass(frozen=True)
class PRView:
    task_slug: str
    repo: str
    url: str


@dataclass(frozen=True)
class ThreadView:
    id: str
    subject: str
    needs_you: bool
    needs_decision: bool
    unseen: bool


@dataclass(frozen=True)
class WorkItemCockpit:
    id: str
    title: str
    kind: str
    phase: str
    spec_id: str | None
    spec_title: str | None
    spec_status: str | None
    criteria: list[CriterionView] = field(default_factory=list)
    tasks: list[TaskView] = field(default_factory=list)
    prs: list[PRView] = field(default_factory=list)
    threads: list[ThreadView] = field(default_factory=list)


def assemble_cockpit(
    summary: WorkItemSummary,
    spec: Spec | None,
    tasks: list[Task],
    threads: list[Thread],
) -> WorkItemCockpit:
    """Fold a WorkItem's canonical parts into one flat, render-ready model (AC3).

    `summary` supplies the derived phase + id/title/kind; `spec` its acceptance
    criteria (with evidence) + status; `tasks` their worktrees + PR urls; `threads`
    the linked conversations. All inputs are already resolved by the caller from the
    canonical stores. PRs are aggregated from each task's recorded `pr_urls` (where
    `mship finish` records the opened PR), preserving task then repo order.
    """
    criteria = [
        CriterionView(id=c.id, text=c.text, verdict=c.verdict, evidence=list(c.evidence))
        for c in (spec.acceptance_criteria if spec is not None else [])
    ]
    task_views = [
        TaskView(
            slug=t.slug, phase=t.phase, branch=t.branch,
            worktrees={repo: str(p) for repo, p in t.worktrees.items()},
            pr_urls=dict(t.pr_urls),
            blocked_reason=t.blocked_reason, finished_at=t.finished_at,
        )
        for t in tasks
    ]
    prs = [
        PRView(task_slug=t.slug, repo=repo, url=url)
        for t in tasks
        for repo, url in t.pr_urls.items()
    ]
    thread_views = [
        ThreadView(id=th.id, subject=th.subject, needs_you=th.needs_you,
                   needs_decision=th.needs_decision, unseen=th.unseen)
        for th in threads
    ]
    return WorkItemCockpit(
        id=summary.id, title=summary.title, kind=summary.kind, phase=summary.phase,
        spec_id=summary.spec_id,
        spec_title=spec.title if spec is not None else None,
        spec_status=spec.status if spec is not None else None,
        criteria=criteria, tasks=task_views, prs=prs, threads=thread_views,
    )


# --- per-entity formatters (shared by render_text + the TUI row builder) ---

def _evidence_line(e: AcceptanceEvidence) -> str:
    note = f" — {e.note}" if e.note else ""
    return f"    [{e.kind}] {e.ref}{note}"


def spec_detail(cockpit: WorkItemCockpit) -> str:
    if cockpit.spec_id is None:
        return "No spec linked."
    return "\n".join([
        f"spec {cockpit.spec_id}  [{cockpit.spec_status}]",
        f"  {cockpit.spec_title or ''}",
        f"  WorkItem phase: {cockpit.phase}",
    ])


def criterion_detail(c: CriterionView) -> str:
    lines = [f"{c.id}  [{c.verdict}]", f"  {c.text}"]
    if c.evidence:
        lines.append("  evidence:")
        lines.extend(_evidence_line(e) for e in c.evidence)
    else:
        lines.append("  (no evidence)")
    return "\n".join(lines)


def task_detail(t: TaskView) -> str:
    lines = [f"task {t.slug}  [{t.phase}]", f"  branch: {t.branch}"]
    if t.blocked_reason:
        lines.append(f"  BLOCKED: {t.blocked_reason}")
    if t.finished_at is not None:
        lines.append(f"  finished: {t.finished_at:%Y-%m-%d %H:%M}")
    if t.worktrees:
        lines.append("  worktrees:")
        for repo, path in t.worktrees.items():
            lines.append(f"    {repo}: {path}")
    if t.pr_urls:
        lines.append("  PRs:")
        for repo, url in t.pr_urls.items():
            lines.append(f"    {repo}: {url}")
    return "\n".join(lines)


def pr_detail(p: PRView) -> str:
    return f"PR ({p.repo}, task {p.task_slug})\n  {p.url}"


def thread_detail(t: ThreadView) -> str:
    flags = [name for name, on in (("needs-you", t.needs_you),
             ("needs-decision", t.needs_decision), ("unseen", t.unseen)) if on]
    suffix = f"  [{', '.join(flags)}]" if flags else ""
    return f"thread {t.id}{suffix}\n  {t.subject}"


def render_text(cockpit: WorkItemCockpit) -> str:
    """Flat text dump of the whole cockpit — the non-TTY short-circuit output
    (agent pipes / CI), mirroring `mship view spec`'s non-TTY behavior."""
    parts: list[str] = [
        f"◆ {cockpit.id}  ·  {cockpit.title}  ·  [{cockpit.phase}]",
        "",
        "SPEC",
        spec_detail(cockpit),
        "",
        "ACCEPTANCE CRITERIA",
    ]
    parts.extend(criterion_detail(c) for c in cockpit.criteria)
    if not cockpit.criteria:
        parts.append("(none)")
    parts += ["", "TASKS"]
    parts.extend(task_detail(t) for t in cockpit.tasks)
    if not cockpit.tasks:
        parts.append("(none)")
    parts += ["", "PRS"]
    parts.extend(pr_detail(p) for p in cockpit.prs)
    if not cockpit.prs:
        parts.append("(none)")
    parts += ["", "THREADS"]
    parts.extend(thread_detail(t) for t in cockpit.threads)
    if not cockpit.threads:
        parts.append("(none)")
    return "\n".join(parts)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/view/test_workitem_cockpit.py -q`
Expected: PASS (7 passed).

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/view/workitem_cockpit.py tests/core/view/test_workitem_cockpit.py
git commit -m "core/view: pure WorkItem cockpit assembly + text renderer (AC3)"
mship journal "Add workitem_cockpit: assemble_cockpit folds spec/ACs+evidence/tasks+worktrees/PRs/threads; render_text non-TTY dump (AC3)" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=6 -->
## Task 6 — `WorkItemCockpitView` widget: cockpit rows on the master/detail base (AC3, AC6)

**Files:**
- Create: `src/mship/cli/view/workitem.py`
- Create: `tests/cli/view/test_workitem_view.py`

- [ ] **Step 1: Write the failing test** — `tests/cli/view/test_workitem_view.py`:

```python
import pytest

from mship.core.spec import AcceptanceEvidence
from mship.core.view.workitem_cockpit import (
    CriterionView, PRView, TaskView, ThreadView, WorkItemCockpit)
from mship.cli.view.workitem import WorkItemCockpitView


def _cockpit():
    return WorkItemCockpit(
        id="wi-1", title="Overhaul", kind="feature", phase="in_flight",
        spec_id="spec-1", spec_title="Overhaul spec", spec_status="needs_review",
        criteria=[CriterionView(
            id="ac1", text="does X", verdict="unreviewed",
            evidence=[AcceptanceEvidence(kind="test", ref="test-runs/1", note="green")])],
        tasks=[TaskView(slug="a", phase="dev", branch="feat/a",
                        worktrees={"r": "/tmp/wt-a"}, pr_urls={"r": "https://gh/pr/1"},
                        blocked_reason=None, finished_at=None)],
        prs=[PRView(task_slug="a", repo="r", url="https://gh/pr/1")],
        threads=[ThreadView(id="th-1", subject="Question about X",
                            needs_you=False, needs_decision=False, unseen=False)],
    )


@pytest.mark.asyncio
async def test_cockpit_view_lists_all_entities_with_header():
    view = WorkItemCockpitView(_cockpit())
    async with view.run_test() as pilot:
        await pilot.pause()
        labels = view.list_labels()
        assert any(l.startswith("spec") for l in labels)
        assert any("ac1" in l for l in labels)
        assert any(l.startswith("task") for l in labels)
        assert any(l.startswith("PR") for l in labels)
        assert any("thread" in l for l in labels)
        assert "wi-1" in view.header_text() and "Overhaul" in view.header_text()
        # First row (spec) detail shows status + WorkItem phase.
        assert "needs_review" in view.detail_text()
        assert "in_flight" in view.detail_text()


@pytest.mark.asyncio
async def test_cockpit_view_drills_show_criterion_evidence_and_worktrees():
    view = WorkItemCockpitView(_cockpit())
    async with view.run_test() as pilot:
        await pilot.pause()
        view._master.focus()
        await pilot.pause()
        # Row order: spec(0), ac1(1), task(2), PR(3), thread(4).
        await pilot.press("j")  # -> ac1
        await pilot.pause()
        assert "ac1" in view.detail_text()
        assert "green" in view.detail_text()      # evidence note surfaced
        await pilot.press("j")  # -> task
        await pilot.pause()
        assert "worktrees" in view.detail_text()
        assert "/tmp/wt-a" in view.detail_text()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/cli/view/test_workitem_view.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'mship.cli.view.workitem'` (or `ImportError: cannot import name 'WorkItemCockpitView'`).

- [ ] **Step 3: Write minimal implementation** — `src/mship/cli/view/workitem.py`:

```python
"""`mship view workitem <id>` — single-WorkItem cockpit on the master/detail base.

Thin wiring: `build_rows` maps a pure `WorkItemCockpit` (assembled in
core/view/workitem_cockpit) to `ListRow`s, and `WorkItemCockpitView` renders them
on the reusable `MasterDetailApp`. The store resolver + Typer command are added in
the next task.
"""
from __future__ import annotations

from mship.cli.view._master_detail import ListRow, MasterDetailApp
from mship.core.view.workitem_cockpit import (
    WorkItemCockpit, criterion_detail, pr_detail, spec_detail, task_detail,
    thread_detail,
)


def build_rows(cockpit: WorkItemCockpit) -> list[ListRow]:
    """One flat, sectioned list of the WorkItem's entities: the spec, each
    acceptance criterion, each task, each PR, each thread — each row carrying its
    own pre-rendered detail (reusing the shared cockpit formatters)."""
    rows: list[ListRow] = [
        ListRow(
            key="spec",
            label=f"spec  {cockpit.spec_id or '(none)'}  [{cockpit.spec_status or '—'}]",
            detail=spec_detail(cockpit),
        )
    ]
    for c in cockpit.criteria:
        rows.append(ListRow(
            key=f"ac:{c.id}",
            label=f"{c.id}  [{c.verdict}]  {c.text}",
            detail=criterion_detail(c),
        ))
    for t in cockpit.tasks:
        rows.append(ListRow(
            key=f"task:{t.slug}",
            label=f"task  {t.slug}  [{t.phase}]",
            detail=task_detail(t),
        ))
    for p in cockpit.prs:
        rows.append(ListRow(
            key=f"pr:{p.task_slug}:{p.repo}",
            label=f"PR  {p.repo}  ({p.task_slug})",
            detail=pr_detail(p),
        ))
    for th in cockpit.threads:
        rows.append(ListRow(
            key=f"thread:{th.id}",
            label=f"thread  {th.subject}",
            detail=thread_detail(th),
        ))
    return rows


class WorkItemCockpitView(MasterDetailApp):
    def __init__(self, cockpit: WorkItemCockpit, **kw) -> None:
        super().__init__(**kw)
        self._cockpit = cockpit

    def list_rows(self) -> list[ListRow]:
        return build_rows(self._cockpit)

    def header_line(self) -> str | None:
        return f"◆ {self._cockpit.id}  ·  {self._cockpit.title}  ·  [{self._cockpit.phase}]"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/cli/view/test_workitem_view.py -q`
Expected: PASS (2 passed).

- [ ] **Step 5: Commit**

```bash
git add src/mship/cli/view/workitem.py tests/cli/view/test_workitem_view.py
git commit -m "cli/view: WorkItemCockpitView renders cockpit rows on master/detail base (AC3, AC6)"
mship journal "Add WorkItemCockpitView + build_rows: spec/AC/task/PR/thread rows with per-entity detail on MasterDetailApp (AC3/AC6)" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=7 -->
## Task 7 — `mship view workitem <id>` command: resolve stores, register, non-TTY text (AC3)

**Files:**
- Modify: `src/mship/cli/view/workitem.py`
- Modify: `src/mship/cli/view/__init__.py`
- Modify: `tests/cli/view/test_workitem_view.py` (append)

- [ ] **Step 1: Write the failing test** — append to `tests/cli/view/test_workitem_view.py`:

```python
# --- CLI: mship view workitem <id> ---
from datetime import datetime, timezone

from typer.testing import CliRunner

from mship.cli import app, container
from mship.core.message import Thread
from mship.core.message_store import MessageStore
from mship.core.spec import AcceptanceCriterion, Spec
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

    SpecStore(tmp_path / SPECS_DIRNAME).save(Spec(
        id="spec-1", title="Overhaul spec", status="needs_review",
        created_at=_dt(), updated_at=_dt(),
        acceptance_criteria=[AcceptanceCriterion(id="ac1", text="does X")],
        body="b\n"))
    WorkItemStore(state_dir / "workitems").save(WorkItem(
        id="wi-1", title="Overhaul", workspace="t", kind="feature",
        created_at=_dt(), updated_at=_dt(), spec_id="spec-1",
        task_slugs=["a"], thread_ids=["th-1"]))
    MessageStore(state_dir / "messages").save(Thread(
        id="th-1", subject="Question about X", created_at=_dt(), updated_at=_dt()))
    StateManager(state_dir).save(WorkspaceState(tasks={"a": Task(
        slug="a", description="d", phase="dev", created_at=_dt(),
        affected_repos=["r"], branch="feat/a",
        worktrees={"r": tmp_path / "wt-a"}, pr_urls={"r": "https://gh/pr/1"},
        work_item_id="wi-1")}))

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


def test_workitem_registered_in_view_help():
    result = CliRunner().invoke(app, ["view", "--help"])
    assert result.exit_code == 0
    assert "workitem" in result.stdout


def test_workitem_cli_renders_cockpit_text(tmp_path):
    _seed_workspace(tmp_path)
    try:
        # CliRunner stdout is not a TTY -> non-TTY text short-circuit (no TUI hang).
        result = CliRunner().invoke(app, ["view", "workitem", "wi-1"])
        assert result.exit_code == 0, result.output
        assert "wi-1" in result.output and "Overhaul" in result.output
        assert "needs_review" in result.output
        assert "ac1" in result.output
        assert "worktrees" in result.output
        assert "https://gh/pr/1" in result.output
        assert "Question about X" in result.output
    finally:
        _reset()


def test_workitem_cli_unknown_id_exits_1(tmp_path):
    _seed_workspace(tmp_path)
    try:
        result = CliRunner().invoke(app, ["view", "workitem", "wi-missing"])
        assert result.exit_code == 1
        assert "wi-missing" in result.output
    finally:
        _reset()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/cli/view/test_workitem_view.py -k "registered or renders_cockpit_text or unknown_id" -q`
Expected: FAIL — `workitem` is not in `mship view --help` (not registered) and the command does not exist.

- [ ] **Step 3: Write minimal implementation**

3a. Append the resolver + command + `register` to `src/mship/cli/view/workitem.py` (add `from pathlib import Path`, `from typing import Optional`, and `import typer` to the imports at the top of the file):

```python
def _resolve_cockpit(container, item_id: str) -> WorkItemCockpit | None:
    """Resolve one WorkItem's cockpit from the canonical stores, or None if the id
    is unknown. Single entry point is the `WorkItemSummary` (from PR1's
    load_workitem_index): it carries the derived phase + spec_id/task_slugs/
    thread_ids used to fetch the linked spec, tasks, and threads."""
    from mship.cli.view._workitems import load_workitem_index
    from mship.core.message_store import MessageStore
    from mship.core.spec_store import SPECS_DIRNAME, SpecStore
    from mship.core.view.workitem_cockpit import assemble_cockpit

    summary = next((s for s in load_workitem_index(container) if s.id == item_id), None)
    if summary is None:
        return None

    workspace_root = Path(container.config_path()).parent
    state_dir = Path(container.state_dir())

    spec = None
    if summary.spec_id:
        spec = SpecStore(workspace_root / SPECS_DIRNAME).find_by_id(summary.spec_id)

    state = container.state_manager().load()
    tasks = [state.tasks[s] for s in summary.task_slugs if s in state.tasks]

    msgs = MessageStore(state_dir / "messages")
    threads = [th for th in (msgs.get(tid) for tid in summary.thread_ids) if th is not None]

    return assemble_cockpit(summary, spec, tasks, threads)


def register(app: "typer.Typer", get_container):
    @app.command()
    def workitem(
        item_id: str = typer.Argument(..., help="WorkItem id to open (e.g. wi-...)"),
    ):
        """Single-WorkItem cockpit: spec (status + phase), acceptance criteria with
        evidence, tasks + worktrees, and linked PRs + threads."""
        from mship.cli.output import Output
        from mship.core.view.workitem_cockpit import render_text

        container = get_container()
        cockpit = _resolve_cockpit(container, item_id)
        if cockpit is None:
            typer.echo(f"Error: unknown work item: {item_id}", err=True)
            raise typer.Exit(code=1)

        # Non-TTY short-circuit (mirrors `mship view spec` #124): the Textual TUI
        # hangs when stdout isn't a terminal (agent pipes, CI, CliRunner). Print
        # the flat cockpit text and exit instead.
        if not Output().is_tty:
            typer.echo(render_text(cockpit))
            return

        WorkItemCockpitView(cockpit).run()
```

3b. Register the command in `src/mship/cli/view/__init__.py` — add the import and the `register` call inside `register(...)` (alongside the existing four):

```python
    from mship.cli.view import status as _status
    from mship.cli.view import logs as _logs
    from mship.cli.view import diff as _diff
    from mship.cli.view import spec as _spec
    from mship.cli.view import workitem as _workitem

    _status.register(app, get_container)
    _logs.register(app, get_container)
    _diff.register(app, get_container)
    _spec.register(app, get_container)
    _workitem.register(app, get_container)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/cli/view/test_workitem_view.py -q`
Expected: PASS (5 passed).

- [ ] **Step 5: Commit**

```bash
git add src/mship/cli/view/workitem.py src/mship/cli/view/__init__.py tests/cli/view/test_workitem_view.py
git commit -m "cli/view: mship view workitem <id> — canonical resolve + non-TTY text + register (AC3)"
mship journal "Wire mship view workitem <id>: resolve summary/spec/tasks/threads from canonical stores, non-TTY render_text, register in view app (AC3)" --action committed
```
<!-- /mship:task -->

---

## Self-Review

Run the full view suite before finishing: `uv run pytest tests/core/view tests/cli/view -q`.

**AC coverage map (PR2 scope = AC3, AC6):**

- **AC3 — `mship view workitem <id>` renders a single-WorkItem cockpit (spec status + phase, acceptance criteria with evidence, tasks + worktrees, linked PRs + threads, from the canonical store):**
  - Task 5 — pure `assemble_cockpit(...)` folds the `WorkItemSummary` (derived phase), `Spec` (status + `acceptance_criteria` with `evidence`), `Task`s (`worktrees` + `pr_urls`), and `Thread`s into `WorkItemCockpit`; `render_text` proves every section is present. Tested without Textual.
  - Task 6 — `WorkItemCockpitView`/`build_rows` render the spec, each criterion (with evidence), each task (with worktrees), each PR, and each thread as navigable rows; pilot tests confirm evidence + worktrees surface on drill.
  - Task 7 — the `workitem` command resolves spec via `SpecStore(workspace_root / "specs").find_by_id`, tasks via `state.tasks`, and threads via `MessageStore.get`, all keyed off the canonical `WorkItemSummary` (branch/worktree-independent, reusing PR1's `load_workitem_index`); CLI test asserts the rendered cockpit and the unknown-id exit-1.
- **AC6 — list-style views support master/detail keyboard navigation (`j`/`k` move selection, `enter` drills, `tab` switches focus, `/` filters):**
  - Task 1 — list pane + detail pane with detail following the highlight.
  - Task 2 — `tab` toggles focus between list and detail (priority binding beats Textual's built-in Screen `tab`->focus_next).
  - Task 3 — `j`/`k` (and arrows) move the master selection or scroll the detail pane when it's focused; `enter` drills into the detail pane.
  - Task 4 — `/` focuses the filter Input and typing filters the list incrementally; `enter`/`escape` close it.
  - The footer action bar is a Textual `Footer` rendering the shown bindings (`Quit`, `Refresh`, `Switch pane`, `Filter`, `Open`). Task 6 applies the whole foundation to the workitem cockpit.

Every PR2 AC maps to at least one pure-layer task (`workitem_cockpit`) or generic-foundation task (`_master_detail`) plus its thin wiring. The foundation is a *sibling* of `ViewApp` and the workitem command/module are all new, so the PR1 stream views (status/journal/diff/spec) are untouched and cannot regress — `_base.py` and their tests are not in any task's file list.

**Type-consistency check:** `ListRow(key,label,detail)` and `MasterDetailApp.list_rows()/header_line()/reload_rows()` are defined in Task 1 and used unchanged in Task 6. `WorkItemCockpit` and its `CriterionView`/`TaskView`/`PRView`/`ThreadView` fields and the formatters `spec_detail`/`criterion_detail`/`task_detail`/`pr_detail`/`thread_detail`/`render_text` defined in Task 5 are imported by exactly those names in Tasks 6-7. `assemble_cockpit(summary, spec, tasks, threads)` signature matches its Task-5 definition and its Task-7 call site.

## Deferred to later PRs

Explicitly out of scope for PR2 and deferred, exactly as required:
- **`mship view queue` (AC4)** — the cross-workspace attention list (needs_review specs + blocked tasks + PRs awaiting action). It will reuse `MasterDetailApp` unchanged (the whole reason the foundation is kept generic and data-source-agnostic here).
- **Inline `approve` / `request-changes` actions (AC7)** — no state-writing keybindings; PR2's action bar exposes only read/navigation keys.
- **Cross-entity `open`-in-browser / `copy`-ref actions (AC8)** — `enter` in PR2 drills into the detail pane only; it does not jump between linked entities or open URLs. The cockpit already models the PR urls + thread ids these actions will target.
- **Migrating `spec`/`status` to master/detail** — the spec picker and status views stay on the PR1 single-body `ViewApp`; PR2 does not touch them.
