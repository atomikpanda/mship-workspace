# Implementation Plan: WorkItem-focused zellij cockpit

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Feature:** A WorkItem-centric zellij cockpit — rename `mship view workitem` → `mship view item` (with a deprecation alias), add a `mship view items` picker, and add `mship layout focus <item-id>` that opens/switches a per-WorkItem zellij tab (chat-first, with Plan/Dev/Review/Run phase sub-tabs baked to the item), an Overview launchpad tab, and close-on-done tab lifecycle.

**Spec:** workitem-focused-zellij-cockpit

**Goal:** Let an operator focus a WorkItem and get a dedicated, switchable zellij tab (agent conversation primary, ambient mship views per phase, editor secondary), driven entirely off the already-shipped `mship view` commands and the existing `mship layout` KDL renderer — with all pure pieces (tab-name derivation, KDL rendering, go-vs-create-vs-close decision, cwd/task resolution, chat-command resolution) unit-testable without a live zellij, and the actual `zellij action` subprocess behind a thin mockable seam.

**Architecture:**
- `mship layout focus` is a thin driver over zellij runtime actions. It resolves the item, derives a deterministic tab name, queries existing tab names, and chooses go-to-tab-name (exists) vs new-tab --layout-string (create) vs close-tab (item done). It no-ops with a clear message when `$ZELLIJ` is unset.
- The per-WorkItem KDL is produced by extending the existing `cli/layout.py` renderer (reusing `_kdl_quote`, matching the `_TEMPLATE` pane/quoting structure). It is chat-first: an `Agent` pane running a configurable command (default: a bare pane = the operator's shell in the worktree cwd), an `Editor` pane, and four `swap_tiled_layout` phase sub-tabs (Plan/Dev/Review/Run) whose panes are the shipped `mship view` commands with `--workitem`/`--task`/`item-id` baked in. All panes inherit the worktree cwd via a layout-root `cwd` node plus `--cwd` on new-tab.
- The pure functions (`tab_name_for`, `decide_focus_action`, `render_workitem_layout`, `resolve_chat_command`, `default_phase_tab`, `resolve_focus_target`) are separated from three subprocess seams (`_in_zellij`, `_query_tab_names`, `_run_zellij_action`) that tests monkeypatch.
- The `items` picker reuses the shipped master/detail foundation (`MasterDetailApp`, `load_workitem_index`) with pure row formatters in a new `core/view/items.py` (mirroring `core/view/queue.py`). Its `enter` action composes with `mship layout focus` via a mockable seam.
- The Overview launchpad tab (`mship view queue` + `mship view items`) is added to the static `_TEMPLATE` with `focus=true` moved from Plan to Overview.

**Tech Stack:** Python 3.14, uv (`uv run pytest`, `pythonpath=["src"]`), Typer CLI (`CliRunner`), Textual (pilot for the new view widget), zellij runtime actions via `subprocess`. Repo root: `/home/bailey/development/repos/mship-workspace/.worktrees/workitem-focused-zellij-cockpit/mothership` (paths below are relative to it).

**Conventions grounded in the actual code:**
- View command flags are used verbatim as they ship: `mship view spec --workitem <id> --watch`, `mship view diff --task <slug> --watch`, `mship view journal --task <slug> --watch`, `mship view logs --task <slug> --watch`, `mship view item <id>`. (`mship view spec` takes `--workitem`, not `--item`; the rename in AC1 is only the `view workitem` *command* → `view item`.)
- Primary worktree/repo is resolved by reusing `mship.core.dispatch.resolve_repo` (priority: active_repo > sole worktree).
- WorkItem derived `phase` values are `inbox|shaping|ready|in_flight|review|done` (from `core/view/workitem_index.compute_phase`); the master/detail base uses `markup=False` throughout.
- Each commit stages only the files it names; never stage a stray `uv.lock`.

---

<!-- mship:task id=1 -->
## Task 1 — Rename `view workitem` → `view item` (+ deprecation alias) (AC1)

**Files:**
- `src/mship/cli/view/workitem.py` (modify: `register`)
- `tests/cli/view/test_workitem_view.py` (modify: update CLI invocations, add alias test)

**Failing test** — update the two existing CLI invocations to the new name, retarget the help test, and add an alias test. In `tests/cli/view/test_workitem_view.py`:

Change `test_workitem_registered_in_view_help` to:

```python
def test_item_and_items_registered_in_view_help():
    result = CliRunner().invoke(app, ["view", "--help"])
    assert result.exit_code == 0
    assert "item" in result.stdout
```

Change the two invocations `["view", "workitem", "wi-1"]` → `["view", "item", "wi-1"]` and `["view", "workitem", "wi-missing"]` → `["view", "item", "wi-missing"]`, then add:

```python
def test_workitem_alias_still_renders_cockpit(tmp_path):
    _seed_workspace(tmp_path)
    try:
        result = CliRunner().invoke(app, ["view", "workitem", "wi-1"])
        assert result.exit_code == 0, result.output
        assert "wi-1" in result.output and "Overhaul" in result.output
        assert "deprecated" in result.output.lower()
        assert "mship view item" in result.output
    finally:
        _reset()
```

**Run (expect fail):** `uv run pytest tests/cli/view/test_workitem_view.py -q` → fails: `view item` is not a registered command (`item`/`items` not in help), and the alias emits no deprecation text.

**Minimal implementation** — in `src/mship/cli/view/workitem.py`, replace the `register` function body's command with a shared runner plus two commands:

```python
def register(app: "typer.Typer", get_container):
    def _run_item_cockpit(item_id: str) -> None:
        from mship.cli.output import Output
        from mship.core.view.workitem_cockpit import render_text

        container = get_container()
        cockpit = _resolve_cockpit(container, item_id)
        if cockpit is None:
            typer.echo(f"Error: unknown work item: {item_id}", err=True)
            raise typer.Exit(code=1)
        if not Output().is_tty:
            typer.echo(render_text(cockpit))
            return
        from mship.core.spec_store import SPECS_DIRNAME, SpecStore
        workspace_root = Path(container.config_path()).parent
        store = SpecStore(workspace_root / SPECS_DIRNAME)
        WorkItemCockpitView(cockpit, spec_store=store).run()

    @app.command(name="item")
    def item(item_id: str = typer.Argument(..., help="WorkItem id to open (e.g. wi-...)")):
        """Single-WorkItem cockpit: spec (status + phase), acceptance criteria with
        evidence, tasks + worktrees, and linked PRs + threads."""
        _run_item_cockpit(item_id)

    @app.command(name="workitem", hidden=True)
    def workitem(item_id: str = typer.Argument(..., help="Deprecated alias for `view item`.")):
        """Deprecated: use `mship view item <id>`."""
        typer.echo("Note: `mship view workitem` is deprecated; use `mship view item`.", err=True)
        _run_item_cockpit(item_id)
```

(The `WorkItemCockpitView` class and its pilot tests are unchanged — only the CLI command name moves.)

**Run (expect pass):** `uv run pytest tests/cli/view/test_workitem_view.py -q` → passes.

**Commit:**
```
git add src/mship/cli/view/workitem.py tests/cli/view/test_workitem_view.py
git commit -m "Rename view workitem -> view item with deprecation alias (AC1)"
mship journal "Renamed mship view workitem to view item, kept deprecated workitem alias" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=2 -->
## Task 2 — `mship view items` WorkItems picker (AC2, AC6 compose)

**Files:**
- `src/mship/core/view/items.py` (new: pure formatters)
- `tests/core/view/test_items.py` (new)
- `src/mship/cli/view/items.py` (new: `ItemsView` + `register` + non-TTY short-circuit + enter→focus seam)
- `tests/cli/view/test_items_view.py` (new)
- `src/mship/cli/view/__init__.py` (modify: register the new module)

**Failing test (pure formatters)** — `tests/core/view/test_items.py`:

```python
from datetime import datetime, timezone

from mship.core.view.items import items_detail, items_label, items_render_text
from mship.core.view.workitem_index import Attention, WorkItemSummary


def _summary(**over):
    base = dict(
        id="wi-1", title="Overhaul", kind="feature", workspace="t",
        phase="in_flight",
        attention=Attention(needs_approval=True, needs_decision=False, blocked=False,
                            needs_review=False, blocked_tasks=0, total_tasks=1),
        created_at=datetime(2026, 7, 1, tzinfo=timezone.utc),
        updated_at=datetime(2026, 7, 1, tzinfo=timezone.utc),
        spec_id="spec-1", task_slugs=["a"], thread_ids=[],
    )
    base.update(over)
    return WorkItemSummary(**base)


def test_items_label_has_id_title_phase_and_attention_marker():
    label = items_label(_summary())
    assert "wi-1" in label and "Overhaul" in label and "[in_flight]" in label
    assert "!" in label  # needs_approval surfaces an attention marker


def test_items_label_no_attention_has_no_marker():
    label = items_label(_summary(attention=Attention(
        needs_approval=False, needs_decision=False, blocked=False,
        needs_review=False, blocked_tasks=0, total_tasks=1)))
    assert "!" not in label


def test_items_detail_lists_links():
    detail = items_detail(_summary())
    assert "spec-1" in detail and "a" in detail


def test_items_render_text_lists_all():
    text = items_render_text([_summary(id="wi-1"), _summary(id="wi-2", title="Second")])
    assert "wi-1" in text and "wi-2" in text and "Second" in text
```

**Run (expect fail):** `uv run pytest tests/core/view/test_items.py -q` → fails: module `mship.core.view.items` does not exist.

**Minimal implementation** — `src/mship/core/view/items.py`:

```python
"""Pure row formatters for `mship view items` — the WorkItems picker. Mirrors
core/view/queue.py: label/detail/render_text over the shared WorkItemSummary
index (id/title/derived-phase/attention), no store wiring here."""
from __future__ import annotations

from mship.core.view.workitem_index import WorkItemSummary


def _attention_marker(s: WorkItemSummary) -> str:
    a = s.attention
    if a.needs_approval or a.needs_decision or a.blocked or a.needs_review:
        return "!"
    return " "


def items_label(s: WorkItemSummary) -> str:
    return f"{_attention_marker(s)} {s.id}  {s.title or '(untitled)'}  [{s.phase}]"


def items_detail(s: WorkItemSummary) -> str:
    a = s.attention
    lines = [
        f"{s.id}  {s.title}",
        f"phase: {s.phase}",
        f"spec: {s.spec_id or '(none)'}",
        f"tasks: {', '.join(s.task_slugs) or '(none)'}",
        f"attention: approval={a.needs_approval} decision={a.needs_decision} "
        f"blocked={a.blocked} review={a.needs_review}",
    ]
    return "\n".join(lines)


def items_render_text(summaries: list[WorkItemSummary]) -> str:
    if not summaries:
        return "No work items."
    return "\n".join(items_label(s) for s in summaries)
```

**Run (expect pass):** `uv run pytest tests/core/view/test_items.py -q` → passes.

**Failing test (CLI + view)** — `tests/cli/view/test_items_view.py` (reuse the seeding pattern from `tests/cli/view/test_workitems_helper.py`):

```python
from datetime import datetime, timezone

import pytest
from typer.testing import CliRunner

from mship.cli import app, container
from mship.core.spec import Spec
from mship.core.spec_store import SPECS_DIRNAME, SpecStore
from mship.core.state import StateManager, Task, WorkspaceState
from mship.core.workitem import WorkItem
from mship.core.workitem_store import WorkItemStore


def _now():
    return datetime(2026, 7, 1, tzinfo=timezone.utc)


def _seed(tmp_path):
    state_dir = tmp_path / ".mothership"
    state_dir.mkdir()
    (tmp_path / "mothership.yaml").write_text("workspace: t\nrepos: {}\n")
    SpecStore(tmp_path / SPECS_DIRNAME).save(Spec(
        id="spec-1", title="Overhaul", status="approved",
        created_at=_now(), updated_at=_now(), body="b\n"))
    WorkItemStore(state_dir / "workitems").save(WorkItem(
        id="wi-1", title="Overhaul", workspace="t", kind="feature",
        created_at=_now(), updated_at=_now(), spec_id="spec-1", task_slugs=["a"]))
    StateManager(state_dir).save(WorkspaceState(tasks={"a": Task(
        slug="a", description="d", phase="dev", created_at=_now(),
        affected_repos=["r"], branch="feat/a", worktrees={}, work_item_id="wi-1")}))
    container.config.reset(); container.state_manager.reset()
    container.config_path.override(tmp_path / "mothership.yaml")
    container.state_dir.override(state_dir)


def _reset():
    container.config_path.reset_override(); container.state_dir.reset_override()
    container.config.reset_override(); container.config.reset()
    container.state_manager.reset_override(); container.state_manager.reset()


def test_items_registered_in_view_help():
    result = CliRunner().invoke(app, ["view", "--help"])
    assert result.exit_code == 0
    assert "items" in result.stdout


def test_items_cli_renders_text(tmp_path):
    _seed(tmp_path)
    try:
        result = CliRunner().invoke(app, ["view", "items"])
        assert result.exit_code == 0, result.output
        assert "wi-1" in result.output and "Overhaul" in result.output
    finally:
        _reset()


@pytest.mark.asyncio
async def test_items_view_lists_and_enter_focuses(tmp_path, monkeypatch):
    from mship.core.view.workitem_index import Attention, WorkItemSummary
    import mship.cli.view.items as iv

    fired = {}
    monkeypatch.setattr(iv, "_focus_workitem", lambda item_id: fired.setdefault("id", item_id))
    s = WorkItemSummary(
        id="wi-1", title="Overhaul", kind="feature", workspace="t", phase="in_flight",
        attention=Attention(False, False, False, False, 0, 1),
        created_at=_now(), updated_at=_now(), spec_id="spec-1", task_slugs=["a"], thread_ids=[])
    view = iv.ItemsView([s])
    async with view.run_test() as pilot:
        await pilot.pause()
        assert any("wi-1" in l for l in view.list_labels())
        view._master.focus()
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        assert fired.get("id") == "wi-1"
```

**Run (expect fail):** `uv run pytest tests/cli/view/test_items_view.py -q` → fails: `mship.cli.view.items` does not exist and `items` is not registered.

**Minimal implementation** — `src/mship/cli/view/items.py`:

```python
"""`mship view items` — the workspace's WorkItems picker on the master/detail base
(AC2). Reuses load_workitem_index + the pure items formatters. `enter` on a row
composes with `mship layout focus <id>` (AC6)."""
from __future__ import annotations

import subprocess

import typer

from mship.cli.view._master_detail import ListRow, MasterDetailApp
from mship.core.view.items import items_detail, items_label, items_render_text


def _focus_workitem(item_id: str) -> None:
    """Seam: fire `mship layout focus <id>` for the selected item. Best-effort;
    a missing zellij / non-session degrades inside the focus command itself."""
    subprocess.run(["mship", "layout", "focus", item_id], check=False)


class ItemsView(MasterDetailApp):
    def __init__(self, summaries, **kw) -> None:
        super().__init__(**kw)
        self._summaries = list(summaries)

    def list_rows(self) -> list[ListRow]:
        return [ListRow(key=s.id, label=items_label(s), detail=items_detail(s))
                for s in self._summaries]

    def header_line(self) -> str | None:
        return f"WorkItems ({len(self._summaries)})"

    def _do_open_entity(self) -> bool:
        key = self.selected_key()
        if key is None:
            return False
        _focus_workitem(key)
        self._announce(f"Focusing {key}")
        return True

    def _do_copy(self) -> None:
        key = self.selected_key()
        if key:
            self.copy_to_clipboard(key)
            self._announce(f"Copied {key}")
        else:
            self._announce("Nothing to copy here.")


def register(app: "typer.Typer", get_container):
    @app.command()
    def items():
        """This workspace's WorkItems as a navigable picker: id, title, derived
        phase, and attention. enter focuses the item's zellij tab · y copies id."""
        from mship.cli.view._workitems import load_workitem_index
        from mship.cli.output import Output

        container = get_container()
        summaries = load_workitem_index(container)
        if not Output().is_tty:
            typer.echo(items_render_text(summaries))
            return
        ItemsView(summaries).run()
```

Then register it in `src/mship/cli/view/__init__.py` — add the import and call:

```python
    from mship.cli.view import items as _items
    ...
    _items.register(app, get_container)
```

**Run (expect pass):** `uv run pytest tests/cli/view/test_items_view.py tests/core/view/test_items.py -q` → passes.

**Commit:**
```
git add src/mship/core/view/items.py tests/core/view/test_items.py src/mship/cli/view/items.py tests/cli/view/test_items_view.py src/mship/cli/view/__init__.py
git commit -m "Add mship view items WorkItems picker (AC2, AC6 compose)"
mship journal "Added mship view items picker on master/detail; enter composes with layout focus" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=3 -->
## Task 3 — Pure tab-name derivation + go/create/close decision (AC3, AC7)

**Files:**
- `src/mship/cli/layout.py` (add `tab_name_for`, `decide_focus_action`)
- `tests/cli/test_layout_focus.py` (new)

**Failing test** — `tests/cli/test_layout_focus.py`:

```python
from mship.cli.layout import decide_focus_action, tab_name_for


def test_tab_name_is_deterministic_and_id_based():
    assert tab_name_for("wi-20260721-abc") == tab_name_for("wi-20260721-abc")
    assert "wi-20260721-abc" in tab_name_for("wi-20260721-abc")


def test_decision_create_when_absent():
    assert decide_focus_action("wi-1", [], is_done=False) == "create"


def test_decision_go_to_when_present():
    assert decide_focus_action("wi-1", ["other", "wi-1"], is_done=False) == "go-to"


def test_decision_close_when_done_and_present():
    assert decide_focus_action("wi-1", ["wi-1"], is_done=True) == "close"


def test_decision_noop_when_done_and_absent():
    assert decide_focus_action("wi-1", ["other"], is_done=True) == "noop"
```

**Run (expect fail):** `uv run pytest tests/cli/test_layout_focus.py -q` → fails: `tab_name_for`/`decide_focus_action` do not exist.

**Minimal implementation** — add to `src/mship/cli/layout.py` (near the other pure helpers):

```python
def tab_name_for(item_id: str) -> str:
    """Deterministic zellij tab name for a WorkItem. The id verbatim: the same
    item always maps to the same tab, so focus reconciles rather than duplicates."""
    return item_id


def decide_focus_action(tab_name: str, existing_tab_names: list[str], *, is_done: bool) -> str:
    """Pure go-vs-create-vs-close decision for `mship layout focus`.
    Returns "close" | "noop" | "go-to" | "create"."""
    exists = tab_name in existing_tab_names
    if is_done:
        return "close" if exists else "noop"
    return "go-to" if exists else "create"
```

**Run (expect pass):** `uv run pytest tests/cli/test_layout_focus.py -q` → passes.

**Commit:**
```
git add src/mship/cli/layout.py tests/cli/test_layout_focus.py
git commit -m "Add pure tab-name derivation + focus go/create/close decision (AC3, AC7)"
mship journal "Added tab_name_for and decide_focus_action pure helpers for layout focus" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=4 -->
## Task 4 — Pure per-WorkItem KDL renderer (chat-first + phase sub-tabs) (AC4, AC5)

**Files:**
- `src/mship/cli/layout.py` (add `resolve_chat_command`, `default_phase_tab`, `render_workitem_layout` + private pane helpers)
- `tests/cli/test_layout_focus.py` (extend)

**Failing test** — append to `tests/cli/test_layout_focus.py`:

```python
from mship.cli.layout import (
    default_phase_tab, render_workitem_layout, resolve_chat_command,
)


def test_resolve_chat_command_precedence():
    assert resolve_chat_command("claude", {}) == "claude"
    assert resolve_chat_command(None, {"MSHIP_CHAT_COMMAND": "my-agent"}) == "my-agent"
    assert resolve_chat_command(None, {}) is None  # default: bare shell pane


def test_default_phase_tab_mapping():
    assert default_phase_tab("shaping") == "Plan"
    assert default_phase_tab("ready") == "Plan"
    assert default_phase_tab("in_flight") == "Dev"
    assert default_phase_tab("review") == "Review"
    assert default_phase_tab("done") == "Run"
    assert default_phase_tab("something-else") == "Plan"


def _kdl(**over):
    base = dict(name="wi-1", worktree="/wt/a", item_id="wi-1", task_slug="a",
                chat_command=None, default_phase="Dev")
    base.update(over)
    return render_workitem_layout(**base)


def test_kdl_is_chat_first_with_editor_and_cwd():
    kdl = _kdl()
    assert 'tab name="wi-1" focus=true' in kdl
    assert 'cwd "/wt/a"' in kdl
    assert 'name="Agent"' in kdl
    assert 'name="Editor"' in kdl
    # Default chat command == bare shell pane (no command= on Agent).
    assert 'name="Agent" focus=true {' not in kdl  # bare pane has no child block


def test_kdl_configurable_chat_command():
    kdl = _kdl(chat_command="claude")
    assert 'name="Agent"' in kdl and 'command="sh"' in kdl
    assert '"-c" "claude"' in kdl


def test_kdl_has_all_four_phase_subtabs():
    kdl = _kdl()
    for phase in ("Plan", "Dev", "Review", "Run"):
        assert f'swap_tiled_layout name="{phase}"' in kdl


def test_kdl_bakes_shipped_view_commands_with_item_and_task():
    kdl = _kdl()
    assert '"view" "spec" "--workitem" "wi-1" "--watch"' in kdl   # Plan
    assert '"view" "diff" "--task" "a" "--watch"' in kdl           # Dev/Review
    assert '"view" "journal" "--task" "a" "--watch"' in kdl        # Dev
    assert '"view" "item" "wi-1"' in kdl                            # Review (PR/checks)
    assert '"view" "logs" "--task" "a" "--watch"' in kdl           # Run


def test_kdl_escapes_worktree_path():
    kdl = _kdl(worktree='/wt/ba"d')
    assert 'cwd "/wt/ba\\"d"' in kdl


def test_kdl_without_task_degrades_task_scoped_panes():
    kdl = _kdl(task_slug=None)
    assert "--task" not in kdl
    assert 'name="Shell"' in kdl   # task-scoped panes fall back to a shell
```

**Run (expect fail):** `uv run pytest tests/cli/test_layout_focus.py -q` → fails: renderer + helpers do not exist.

**Minimal implementation** — add to `src/mship/cli/layout.py` (reusing the existing `_kdl_quote`):

```python
from typing import Mapping

_PHASES = ("Plan", "Dev", "Review", "Run")

_PHASE_FROM_WORKITEM = {
    "inbox": "Plan", "shaping": "Plan", "ready": "Plan",
    "in_flight": "Dev", "review": "Review", "done": "Run",
}


def default_phase_tab(workitem_phase: str) -> str:
    """Map a WorkItem's derived phase to the sub-tab that opens focused."""
    return _PHASE_FROM_WORKITEM.get(workitem_phase, "Plan")


def resolve_chat_command(explicit: str | None, env: Mapping[str, str]) -> str | None:
    """Configurable agent/chat command. None -> a bare pane = the operator's shell
    in the tab cwd (mship does NOT hardcode a specific agent)."""
    if explicit:
        return explicit
    return env.get("MSHIP_CHAT_COMMAND") or None


def _mship_pane(name: str, tokens: list[str]) -> str:
    args = " ".join(_kdl_quote(t) for t in tokens)
    return (f'                pane name="{name}" command="mship" close_on_exit=false '
            f'{{ args {args}; }}\n')


def _phase_panes(phase: str, item_id: str, task_slug: str | None) -> str:
    """The ambient view panes for one phase sub-tab, baking the item/task in. Panes
    that need a task fall back to a Shell pane when the item has no task yet."""
    shell = '                pane name="Shell"\n'
    if phase == "Plan":
        return (_mship_pane("Spec", ["view", "spec", "--workitem", item_id, "--watch"])
                + _mship_pane("Item", ["view", "item", item_id]))
    if phase == "Dev":
        if task_slug is None:
            return shell
        return (_mship_pane("Diff", ["view", "diff", "--task", task_slug, "--watch"])
                + _mship_pane("Journal", ["view", "journal", "--task", task_slug, "--watch"]))
    if phase == "Review":
        item = _mship_pane("Item", ["view", "item", item_id])
        if task_slug is None:
            return item
        return _mship_pane("Diff", ["view", "diff", "--task", task_slug, "--watch"]) + item
    if phase == "Run":
        if task_slug is None:
            return shell
        return _mship_pane("Logs", ["view", "logs", "--task", task_slug, "--watch"]) + shell
    return shell


def _agent_pane(chat_command: str | None) -> str:
    if chat_command is None:
        return '            pane name="Agent" focus=true\n'
    cmd = _kdl_quote(chat_command)
    return ('            pane name="Agent" focus=true command="sh" close_on_exit=false '
            f'{{ args "-c" {cmd}; }}\n')


def _editor_pane() -> str:
    return ('            pane name="Editor" command="sh" close_on_exit=false {\n'
            '                args "-c" "${EDITOR:-$(command -v nvim || command -v vim || command -v vi)} ."\n'
            '            }\n')


def _phase_swap(phase: str, item_id: str, task_slug: str | None,
                chat_command: str | None) -> str:
    return (f'    swap_tiled_layout name="{phase}" {{\n'
            '        tab {\n'
            '            pane split_direction="vertical" {\n'
            + _agent_pane(chat_command)
            + '                pane split_direction="horizontal" size="50%" {\n'
            + _phase_panes(phase, item_id, task_slug)
            + '                }\n'
            + '            }\n'
            + _editor_pane()
            + '        }\n'
            '    }\n')


def render_workitem_layout(
    *, name: str, worktree: str, item_id: str, task_slug: str | None,
    chat_command: str | None, default_phase: str,
) -> str:
    """A per-WorkItem tab KDL: chat-first Agent pane + Editor pane, all cd'd to the
    worktree, with Plan/Dev/Review/Run phase sub-tabs (zellij swap layouts) whose
    panes are the shipped `mship view` commands baked to this item/task. Reuses
    _kdl_quote so paths/commands can't break out of the KDL string."""
    base_phase = default_phase if default_phase in _PHASES else "Plan"
    parts = [f'layout {{\n    cwd {_kdl_quote(worktree)}\n\n',
             f'    tab name="{name}" focus=true {{\n',
             '        pane split_direction="vertical" {\n',
             _agent_pane(chat_command),
             '            pane split_direction="horizontal" size="50%" {\n',
             _phase_panes(base_phase, item_id, task_slug),
             '            }\n',
             '        }\n',
             _editor_pane(),
             '    }\n\n']
    for phase in _PHASES:
        parts.append(_phase_swap(phase, item_id, task_slug, chat_command))
    parts.append('}\n')
    return "".join(parts)
```

**Run (expect pass):** `uv run pytest tests/cli/test_layout_focus.py -q` → passes.

**Commit:**
```
git add src/mship/cli/layout.py tests/cli/test_layout_focus.py
git commit -m "Add per-WorkItem KDL renderer: chat-first + phase sub-tabs (AC4, AC5)"
mship journal "Added render_workitem_layout with configurable chat pane, editor, and phase swap layouts" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=5 -->
## Task 5 — Resolve an item's worktree cwd + task slug (AC3)

**Files:**
- `src/mship/cli/layout.py` (add `resolve_focus_target`)
- `tests/cli/test_layout_focus.py` (extend)

**Failing test** — append to `tests/cli/test_layout_focus.py` (reuse the seeding style; a task with a worktree so `resolve_repo` picks it):

```python
from datetime import datetime, timezone
from pathlib import Path

from mship.cli import container
from mship.cli.layout import resolve_focus_target
from mship.core.spec import Spec
from mship.core.spec_store import SPECS_DIRNAME, SpecStore
from mship.core.state import StateManager, Task, WorkspaceState
from mship.core.workitem import WorkItem
from mship.core.workitem_store import WorkItemStore


def _dt():
    return datetime(2026, 7, 1, tzinfo=timezone.utc)


def _seed_focus(tmp_path, worktrees):
    state_dir = tmp_path / ".mothership"
    state_dir.mkdir()
    (tmp_path / "mothership.yaml").write_text("workspace: t\nrepos: {}\n")
    SpecStore(tmp_path / SPECS_DIRNAME).save(Spec(
        id="spec-1", title="Overhaul", status="approved",
        created_at=_dt(), updated_at=_dt(), body="b\n"))
    WorkItemStore(state_dir / "workitems").save(WorkItem(
        id="wi-1", title="Overhaul", workspace="t", kind="feature",
        created_at=_dt(), updated_at=_dt(), spec_id="spec-1", task_slugs=["a"]))
    StateManager(state_dir).save(WorkspaceState(tasks={"a": Task(
        slug="a", description="d", phase="dev", created_at=_dt(),
        affected_repos=["r"], branch="feat/a", worktrees=worktrees, work_item_id="wi-1")}))
    container.config.reset(); container.state_manager.reset()
    container.config_path.override(tmp_path / "mothership.yaml")
    container.state_dir.override(state_dir)


def _reset_focus():
    container.config_path.reset_override(); container.state_dir.reset_override()
    container.config.reset_override(); container.config.reset()
    container.state_manager.reset_override(); container.state_manager.reset()


def test_resolve_focus_target_returns_worktree_and_task(tmp_path):
    wt = tmp_path / "wt-a"
    _seed_focus(tmp_path, {"r": wt})
    try:
        summary, task_slug, worktree = resolve_focus_target(container, "wi-1")
        assert summary.id == "wi-1"
        assert task_slug == "a"
        assert worktree == wt
    finally:
        _reset_focus()


def test_resolve_focus_target_unknown_id_is_none(tmp_path):
    _seed_focus(tmp_path, {"r": tmp_path / "wt-a"})
    try:
        assert resolve_focus_target(container, "wi-missing") is None
    finally:
        _reset_focus()


def test_resolve_focus_target_no_worktree_falls_back_to_workspace_root(tmp_path):
    _seed_focus(tmp_path, {})
    try:
        summary, task_slug, worktree = resolve_focus_target(container, "wi-1")
        assert worktree == tmp_path   # workspace root (config_path parent)
    finally:
        _reset_focus()
```

**Run (expect fail):** `uv run pytest tests/cli/test_layout_focus.py -q` → fails: `resolve_focus_target` does not exist.

**Minimal implementation** — add to `src/mship/cli/layout.py`:

```python
def resolve_focus_target(container, item_id: str):
    """Resolve (WorkItemSummary, primary task_slug|None, worktree cwd) for an item,
    or None if the id is unknown. Reuses load_workitem_index + dispatch.resolve_repo
    (active_repo > sole worktree). Falls back to the workspace root when the item has
    no usable worktree yet."""
    from mship.cli.view._workitems import load_workitem_index
    from mship.core.dispatch import resolve_repo

    summary = next((s for s in load_workitem_index(container) if s.id == item_id), None)
    if summary is None:
        return None

    state = container.state_manager().load()
    task_slug: str | None = None
    worktree: Path | None = None
    for slug in summary.task_slugs:
        task = state.tasks.get(slug)
        if task is None:
            continue
        task_slug = task_slug or slug
        try:
            repo = resolve_repo(task, None)
        except ValueError:
            continue
        worktree = Path(task.worktrees[repo])
        task_slug = slug
        break

    if worktree is None:
        worktree = Path(container.config_path()).parent
    return summary, task_slug, worktree
```

**Run (expect pass):** `uv run pytest tests/cli/test_layout_focus.py -q` → passes.

**Commit:**
```
git add src/mship/cli/layout.py tests/cli/test_layout_focus.py
git commit -m "Resolve WorkItem worktree cwd + primary task slug for layout focus (AC3)"
mship journal "Added resolve_focus_target reusing load_workitem_index + dispatch.resolve_repo" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=6 -->
## Task 6 — `mship layout focus <item-id>` driver + zellij seams + graceful degrade (AC3, AC4, AC5, AC7)

**Files:**
- `src/mship/cli/layout.py` (add `import subprocess`; seams `_in_zellij`/`_query_tab_names`/`_run_zellij_action`; `focus` subcommand)
- `tests/cli/test_layout_focus.py` (extend)

**Failing test** — append to `tests/cli/test_layout_focus.py`:

```python
import mship.cli.layout as layout_mod
from mship.cli import app
from typer.testing import CliRunner

runner = CliRunner()


def _patch_zellij(monkeypatch, *, in_session, existing):
    calls = []
    monkeypatch.setattr(layout_mod, "_in_zellij", lambda: in_session)
    monkeypatch.setattr(layout_mod, "_query_tab_names", lambda: list(existing))
    monkeypatch.setattr(layout_mod, "_run_zellij_action", lambda args: calls.append(args))
    return calls


def test_focus_outside_zellij_noops_with_message(tmp_path, monkeypatch):
    _seed_focus(tmp_path, {"r": tmp_path / "wt-a"})
    calls = _patch_zellij(monkeypatch, in_session=False, existing=[])
    try:
        result = runner.invoke(app, ["layout", "focus", "wi-1"])
        assert result.exit_code == 0, result.output
        assert "zellij" in result.output.lower()
        assert calls == []   # no zellij action attempted
    finally:
        _reset_focus()


def test_focus_creates_tab_when_absent(tmp_path, monkeypatch):
    wt = tmp_path / "wt-a"
    _seed_focus(tmp_path, {"r": wt})
    calls = _patch_zellij(monkeypatch, in_session=True, existing=["Overview"])
    try:
        result = runner.invoke(app, ["layout", "focus", "wi-1"])
        assert result.exit_code == 0, result.output
        assert len(calls) == 1
        args = calls[0]
        assert args[0] == "new-tab"
        assert "--name" in args and "wi-1" in args
        assert "--cwd" in args and str(wt) in args
        kdl = args[args.index("--layout-string") + 1]
        assert 'tab name="wi-1"' in kdl and 'name="Agent"' in kdl
    finally:
        _reset_focus()


def test_focus_switches_to_existing_tab(tmp_path, monkeypatch):
    _seed_focus(tmp_path, {"r": tmp_path / "wt-a"})
    calls = _patch_zellij(monkeypatch, in_session=True, existing=["wi-1"])
    try:
        result = runner.invoke(app, ["layout", "focus", "wi-1"])
        assert result.exit_code == 0, result.output
        assert calls == [["go-to-tab-name", "wi-1"]]
    finally:
        _reset_focus()


def test_focus_unknown_id_exits_1(tmp_path, monkeypatch):
    _seed_focus(tmp_path, {"r": tmp_path / "wt-a"})
    _patch_zellij(monkeypatch, in_session=True, existing=[])
    try:
        result = runner.invoke(app, ["layout", "focus", "wi-missing"])
        assert result.exit_code == 1
        assert "wi-missing" in result.output
    finally:
        _reset_focus()
```

**Run (expect fail):** `uv run pytest tests/cli/test_layout_focus.py -q` → fails: no `focus` command / seams.

**Minimal implementation** — in `src/mship/cli/layout.py` add `import subprocess` at the top, the seams (module level), and the `focus` command inside `register` (after `launch`):

```python
def _in_zellij() -> bool:
    return bool(os.environ.get("ZELLIJ"))


def _query_tab_names() -> list[str]:
    out = subprocess.run(["zellij", "action", "query-tab-names"],
                         capture_output=True, text=True, check=False)
    return [line for line in out.stdout.splitlines() if line.strip()]


def _run_zellij_action(args: list[str]) -> None:
    subprocess.run(["zellij", "action", *args], check=False)
```

Inside `register`, add:

```python
    @layout_app.command()
    def focus(
        item_id: str = typer.Argument(..., help="WorkItem id to focus (e.g. wi-...)."),
        chat_command: Optional[str] = typer.Option(
            None, "--chat-command",
            help="Command for the Agent pane. Default: your shell in the worktree."),
    ):
        """Open or switch to a WorkItem's zellij tab (chat-first, phase sub-tabs).

        No-ops with a message when not inside a zellij session. Closes the tab
        instead of opening it when the item has reached `done` (AC7)."""
        if not _in_zellij():
            typer.echo("Not inside a zellij session ($ZELLIJ unset); "
                       "run `mship layout launch` first. (no-op)")
            return
        target = resolve_focus_target(get_container(), item_id)
        if target is None:
            typer.echo(f"Error: unknown work item: {item_id}", err=True)
            raise typer.Exit(code=1)
        summary, task_slug, worktree = target
        name = tab_name_for(item_id)
        action = decide_focus_action(name, _query_tab_names(), is_done=summary.phase == "done")
        if action == "noop":
            typer.echo(f"{item_id} is done; no tab to focus.")
            return
        if action == "close":
            _run_zellij_action(["go-to-tab-name", name])
            _run_zellij_action(["close-tab"])
            typer.echo(f"Closed tab for done item {item_id}.")
            return
        if action == "go-to":
            _run_zellij_action(["go-to-tab-name", name])
            typer.echo(f"Switched to {item_id}.")
            return
        kdl = render_workitem_layout(
            name=name, worktree=str(worktree), item_id=item_id, task_slug=task_slug,
            chat_command=resolve_chat_command(chat_command, os.environ),
            default_phase=default_phase_tab(summary.phase),
        )
        _run_zellij_action(["new-tab", "--layout-string", kdl, "--name", name,
                            "--cwd", str(worktree)])
        typer.echo(f"Opened {item_id}.")
```

**Run (expect pass):** `uv run pytest tests/cli/test_layout_focus.py -q` → passes.

**Commit:**
```
git add src/mship/cli/layout.py tests/cli/test_layout_focus.py
git commit -m "Add mship layout focus driver over zellij actions with graceful degrade (AC3-AC5, AC7)"
mship journal "Added mship layout focus: go-to/create/close via mocked zellij action seams; no-op outside zellij" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=7 -->
## Task 7 — Overview launchpad tab (queue + items) in the base layout (AC6)

**Files:**
- `src/mship/cli/layout.py` (add an `Overview` tab to `_TEMPLATE`, move `focus=true` from Plan to Overview)
- `tests/cli/test_layout.py` (update the one focus assertion; add Overview assertions)

**Failing test** — in `tests/cli/test_layout.py`, update `test_render_serve_layout_no_args_has_base_tabs_plus_serve` so the focused tab is Overview:

```python
    # Overview is the launchpad and keeps focus.
    assert 'tab name="Overview" focus=true' in kdl
    assert kdl.index('tab name="Run"') < kdl.index('tab name="Serve"')
```

(remove the old `assert 'tab name="Plan" focus=true' in kdl`.) Then add:

```python
def test_template_has_overview_launchpad_tab():
    assert 'tab name="Overview" focus=true' in _TEMPLATE
    start = _TEMPLATE.index('tab name="Overview"')
    end = _TEMPLATE.index('tab name="Plan"', start)
    overview = _TEMPLATE[start:end]
    assert '"view" "queue"' in overview
    assert '"view" "items"' in overview


def test_overview_precedes_plan():
    assert _TEMPLATE.index('tab name="Overview"') < _TEMPLATE.index('tab name="Plan"')
```

**Run (expect fail):** `uv run pytest tests/cli/test_layout.py -q` → fails: no Overview tab; Plan still carries focus.

**Minimal implementation** — in `src/mship/cli/layout.py`, edit `_TEMPLATE`: remove `focus=true` from the `Plan` tab line (`tab name="Plan" {`) and insert an Overview tab immediately before Plan:

```
    tab name="Overview" focus=true {
        pane split_direction="vertical" {
            pane size="50%" name="Queue" command="mship" close_on_exit=false { args "view" "queue"; }
            pane size="50%" name="Items" command="mship" close_on_exit=false { args "view" "items"; }
        }
    }

    tab name="Plan" {
```

The slicing markers still hold: `_plan_idx = _TEMPLATE.index('    tab name="Plan"')` places the new Overview tab inside `_LAYOUT_HEAD`, so `_BASE_TABS` stays Plan..Run and `_TEMPLATE == _LAYOUT_HEAD + _BASE_TABS + _LAYOUT_TAIL` is preserved. `render_serve_layout` now also carries the Overview tab (launchpad in the serve layout too). `queue`/`items` are interactive master/detail TUIs, so their panes run without `--watch` (matching that these are not stream views).

**Run (expect pass):** `uv run pytest tests/cli/test_layout.py -q` → passes (including `test_template_reconstructs_from_parts` and `test_base_tabs_has_all_four_tabs`).

**Commit:**
```
git add src/mship/cli/layout.py tests/cli/test_layout.py
git commit -m "Wire Overview launchpad tab (view queue + view items) into base layout (AC6)"
mship journal "Added Overview launchpad tab with queue + items panes; moved focus from Plan to Overview" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=8 -->
## Task 8 — Explicit `mship layout close <item-id>` + close-on-done lifecycle (AC7)

**Files:**
- `src/mship/cli/layout.py` (add `close` subcommand)
- `tests/cli/test_layout_focus.py` (extend)

**Failing test** — append to `tests/cli/test_layout_focus.py`:

```python
def test_close_closes_existing_tab(tmp_path, monkeypatch):
    _seed_focus(tmp_path, {"r": tmp_path / "wt-a"})
    calls = _patch_zellij(monkeypatch, in_session=True, existing=["wi-1"])
    try:
        result = runner.invoke(app, ["layout", "close", "wi-1"])
        assert result.exit_code == 0, result.output
        assert calls == [["go-to-tab-name", "wi-1"], ["close-tab"]]
    finally:
        _reset_focus()


def test_close_no_tab_is_noop(tmp_path, monkeypatch):
    _seed_focus(tmp_path, {"r": tmp_path / "wt-a"})
    calls = _patch_zellij(monkeypatch, in_session=True, existing=["Overview"])
    try:
        result = runner.invoke(app, ["layout", "close", "wi-1"])
        assert result.exit_code == 0, result.output
        assert calls == []
    finally:
        _reset_focus()


def test_close_outside_zellij_noops(tmp_path, monkeypatch):
    _seed_focus(tmp_path, {"r": tmp_path / "wt-a"})
    calls = _patch_zellij(monkeypatch, in_session=False, existing=["wi-1"])
    try:
        result = runner.invoke(app, ["layout", "close", "wi-1"])
        assert result.exit_code == 0
        assert "zellij" in result.output.lower()
        assert calls == []
    finally:
        _reset_focus()


def test_focus_done_item_closes_its_tab(tmp_path, monkeypatch):
    # A done item (terminal spec status) whose tab exists is closed, not re-opened.
    from mship.core.spec_store import SPECS_DIRNAME, SpecStore
    _seed_focus(tmp_path, {"r": tmp_path / "wt-a"})
    spec = SpecStore(tmp_path / SPECS_DIRNAME).find_by_id("spec-1")
    SpecStore(tmp_path / SPECS_DIRNAME).save(spec.model_copy(update={"status": "archived"}))
    calls = _patch_zellij(monkeypatch, in_session=True, existing=["wi-1"])
    try:
        result = runner.invoke(app, ["layout", "focus", "wi-1"])
        assert result.exit_code == 0, result.output
        assert calls == [["go-to-tab-name", "wi-1"], ["close-tab"]]
        assert "done" in result.output.lower() or "closed" in result.output.lower()
    finally:
        _reset_focus()
```

(If `Spec` is not a pydantic `BaseModel` with `model_copy`, re-save a `Spec(...)` with `status="archived"` mirroring the seed — verified against the actual `Spec` constructor during implementation.)

**Run (expect fail):** `uv run pytest tests/cli/test_layout_focus.py -q` → fails: no `close` command (the done-focus test already passes via Task 6's close branch, confirming AC7's focus path).

**Minimal implementation** — inside `register` in `src/mship/cli/layout.py`, add:

```python
    @layout_app.command()
    def close(
        item_id: str = typer.Argument(..., help="WorkItem id whose tab to close."),
    ):
        """Explicitly close a WorkItem's zellij tab so tabs don't accumulate (AC7)."""
        if not _in_zellij():
            typer.echo("Not inside a zellij session ($ZELLIJ unset). (no-op)")
            return
        name = tab_name_for(item_id)
        if name not in _query_tab_names():
            typer.echo(f"No open tab for {item_id}.")
            return
        _run_zellij_action(["go-to-tab-name", name])
        _run_zellij_action(["close-tab"])
        typer.echo(f"Closed tab for {item_id}.")
```

**Run (expect pass):** `uv run pytest tests/cli/test_layout_focus.py tests/cli/test_layout.py -q` → passes.

**Full-suite gate:** `uv run pytest tests/cli/view/ tests/core/view/ tests/cli/test_layout.py tests/cli/test_layout_focus.py -q` → all pass.

**Commit:**
```
git add src/mship/cli/layout.py tests/cli/test_layout_focus.py
git commit -m "Add explicit mship layout close + close-on-done tab lifecycle (AC7)"
mship journal "Added mship layout close command; confirmed focus closes a done item's tab" --action committed
```
<!-- /mship:task -->

---

## Self-Review — Acceptance Criteria → Tasks

- **AC1** (`mship view item <id>` renames `view workitem`; old name aliased; `items` in `view --help`): Task 1 (rename `item`, hidden deprecated `workitem` alias, alias-still-renders test, help asserts `item`) + Task 2 (`items` in `view --help`).
- **AC2** (`mship view items` lists id/title/derived-phase/attention as master/detail, reusing the foundation): Task 2 — `core/view/items.py` pure formatters (plain-assert tested), `ItemsView(MasterDetailApp)` + non-TTY `items_render_text` short-circuit, reuses `load_workitem_index`; pilot test lists rows.
- **AC3** (`focus` switches vs creates; deterministic id-based name; cwd = task worktree; graceful no-op outside zellij): Task 3 (`tab_name_for`, `decide_focus_action`), Task 5 (`resolve_focus_target` cwd/task via `resolve_repo`), Task 6 (`focus` driver: go-to vs new-tab, `--cwd`, `--name`, no-op when `$ZELLIJ` unset — all via mocked seams).
- **AC4** (chat-first: configurable Agent pane default shell, Plan/Dev/Review/Run sub-tabs, Editor pane, all cd'd to worktree): Task 4 (`render_workitem_layout`: bare Agent pane by default / configurable via `resolve_chat_command`, `_editor_pane`, four `swap_tiled_layout` phases, layout-root `cwd`) + Task 6 wiring.
- **AC5** (each phase sub-tab = shipped view commands baked to the item): Task 4 — Plan `view spec --workitem <id> --watch` + `view item <id>`; Dev `view diff --task <slug> --watch` + `view journal --task <slug> --watch`; Review `view diff --task <slug>` + `view item <id>` (PR/checks); Run `view logs --task <slug> --watch`; asserted by `test_kdl_bakes_shipped_view_commands_with_item_and_task`.
- **AC6** (`mship layout` gains the per-WorkItem template + Overview launchpad tab; picking an item focuses it): Task 4/6 (template + focus command live in `layout.py`), Task 7 (Overview tab = `view queue` + `view items`, focused), Task 2 (`ItemsView` `enter` → `_focus_workitem` seam composes with `mship layout focus`).
- **AC7** (tab closed on done or explicit close; tabs don't accumulate): Task 3 (`decide_focus_action` returns `close`/`noop` when done), Task 6 (focus close branch), Task 8 (explicit `mship layout close` + `test_focus_done_item_closes_its_tab`).
