# First-class implementation plans + plan-gate — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `first-class-implementation-plans-plan-mos-235` (approved) — `specs/2026-07-12-first-class-implementation-plans-plan-mos-235.md` (MOS-235)

**Goal:** Make an implementation plan a first-class, linked, gated artifact for feature work items — mirroring the spec gate — and make build dispatch plan-driven (minted from the plan, not the spec) once a plan exists.

**Architecture:** A feature's plan is resolved for its task via an explicit `WorkItem.plan_path` or the existing `discover_plan_path` convention; it's valid if the file exists and has ≥1 `<!-- mship:task -->` anchor. A plan clause in `workitem_gate.check_task_gate` (opt-in via a `require_plan` param, set True only at `phase plan→dev` and `finish`, never at spawn) blocks a feature from dev/finish without a valid plan. `mship item link-plan` links a plan; `mship dispatch --task` auto-resolves the linked plan and mints the implementer prompt from it. No heavyweight Plan object / approval lifecycle (enforce existence, not content).

**Tech Stack:** Python 3.14, Pydantic (models), Typer (CLI), pytest (`tmp_path`, stores on disk, `CliRunner`, `pytest.raises(match=...)`).

**Repos:** mothership only.

**Execution note:** Build SERIALLY (one implementer subagent at a time; the orchestrator commits each task's work immediately via `mship commit` — parallel state writes clobber `state.yaml`, MOS-233). Subagents leave changes STAGED and run only TARGETED tests; the orchestrator runs the full `mship test` once at the end. NOTE: the plan's per-task "commit" step is handled by the orchestrator, not the subagent.

---

<!-- mship:task id=1 -->
### Task 1: Shared plan resolver (`core/plan.py`)

**Files:**
- Create: `src/mship/core/plan.py`
- Modify: `src/mship/core/export.py` (import `discover_plan_path` from the new module instead of defining it)
- Test: `tests/core/test_plan.py` (new)

Centralize plan resolution so both export and the gate use it. Move `discover_plan_path` (currently `export.py:367-381` + `_plan_stem_matches_slug` `354-364`) into `core/plan.py`, add `plan_has_tasks(text)` (validity = ≥1 mship:task anchor, reuse the anchor regex), and `resolve_plan_path(task_slug, plan_path, workspace_root, docs_dir)` (explicit `plan_path` wins, else `discover_plan_path`).

- [ ] **Step 1: Write the failing tests**

Create `tests/core/test_plan.py`:

```python
from pathlib import Path
from mship.core.plan import discover_plan_path, plan_has_tasks, resolve_plan_path

_PLAN = "# Plan\n\n<!-- mship:task id=1 -->\n### Task 1\n<!-- /mship:task -->\n"

def test_plan_has_tasks_true_when_anchor_present():
    assert plan_has_tasks(_PLAN) is True

def test_plan_has_tasks_false_when_no_anchor():
    assert plan_has_tasks("# Just prose, no tasks") is False

def test_discover_plan_path_matches_dated_slug(tmp_path):
    d = tmp_path / "docs" / "plans"; d.mkdir(parents=True)
    p = d / "2026-07-12-add-labels.md"; p.write_text(_PLAN)
    assert discover_plan_path(tmp_path, "add-labels", docs_dir="docs") == p

def test_resolve_plan_path_prefers_explicit(tmp_path):
    explicit = tmp_path / "custom" / "myplan.md"; explicit.parent.mkdir(parents=True)
    explicit.write_text(_PLAN)
    got = resolve_plan_path("add-labels", str(explicit.relative_to(tmp_path)), tmp_path, "docs")
    assert got == explicit

def test_resolve_plan_path_falls_back_to_convention(tmp_path):
    d = tmp_path / "docs" / "plans"; d.mkdir(parents=True)
    p = d / "add-labels.md"; p.write_text(_PLAN)
    assert resolve_plan_path("add-labels", None, tmp_path, "docs") == p

def test_resolve_plan_path_none_when_missing(tmp_path):
    assert resolve_plan_path("add-labels", None, tmp_path, "docs") is None
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/core/test_plan.py -v`
Expected: FAIL (`mship.core.plan` doesn't exist).

- [ ] **Step 3: Implement `core/plan.py`**

Move the two functions from `export.py` verbatim, add the two new helpers:

```python
"""Resolve + validate a task's implementation plan doc (see MOS-235)."""
from __future__ import annotations
import re
from pathlib import Path

_TASK_ANCHOR_RE = re.compile(r"<!--\s*mship:task\s+id=([^\s>]+)\s*-->")
_DATED_STEM_RE = None  # keep whatever _plan_stem_matches_slug used


def _plan_stem_matches_slug(stem: str, task_slug: str) -> bool:
    # moved verbatim from export.py:354-364
    ...


def discover_plan_path(workspace_root: Path, task_slug: str, docs_dir: str = "docs") -> Path | None:
    # moved verbatim from export.py:367-381
    ...


def plan_has_tasks(text: str) -> bool:
    """A plan is 'real' if it has at least one <!-- mship:task ... --> anchor."""
    return _TASK_ANCHOR_RE.search(text) is not None


def resolve_plan_path(task_slug, plan_path, workspace_root, docs_dir="docs") -> Path | None:
    """Explicit `plan_path` (workspace-relative or absolute) wins; else the
    discover_plan_path convention. Returns the Path if the file exists, else None."""
    if plan_path:
        p = Path(plan_path)
        if not p.is_absolute():
            p = Path(workspace_root) / p
        return p if p.is_file() else None
    return discover_plan_path(Path(workspace_root), task_slug, docs_dir)
```

- [ ] **Step 4: Update `export.py` to import from the new module**

In `src/mship/core/export.py`, delete the moved `discover_plan_path` + `_plan_stem_matches_slug` and `from mship.core.plan import discover_plan_path`. Keep behavior identical.

- [ ] **Step 5: Run to verify it passes**

Run: `uv run pytest tests/core/test_plan.py tests/core/test_export.py -v`
Expected: PASS (new + export regression).

- [ ] **Step 6: Stage** (`git add`); orchestrator commits.
<!-- /mship:task -->

---

<!-- mship:task id=2 -->
### Task 2: `WorkItem.plan_path` + `WorkItemStore.link_plan`

**Files:**
- Modify: `src/mship/core/workitem.py` (add `plan_path` field beside `spec_id`)
- Modify: `src/mship/core/workitem_store.py` (add `link_plan`, mirroring `link_spec` at 69-72)
- Test: `tests/core/test_workitem_store.py`, `tests/core/test_workitem.py`

- [ ] **Step 1: Write the failing test**

In `tests/core/test_workitem_store.py` (mirror the `link_spec` test style):

```python
def test_link_plan_persists_plan_path(tmp_path):
    store = WorkItemStore(tmp_path)
    wi = store.create("t", "feature", "ws", _now())
    store.link_plan(wi.id, "docs/plans/2026-07-12-t.md", _now())
    assert store.get(wi.id).plan_path == "docs/plans/2026-07-12-t.md"
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/core/test_workitem_store.py -k link_plan -v`
Expected: FAIL (`plan_path`/`link_plan` missing).

- [ ] **Step 3: Add the field + method**

`src/mship/core/workitem.py`: add `plan_path: str | None = None` to `WorkItem` (beside `spec_id`).
`src/mship/core/workitem_store.py`, mirroring `link_spec`:

```python
def link_plan(self, item_id: str, plan_path: str, now: str) -> WorkItem:
    wi = self.get(item_id)
    if wi is None:
        raise KeyError(item_id)
    wi.plan_path = plan_path
    wi.updated_at = now
    self.save(wi)
    return wi
```

- [ ] **Step 4: Run to verify it passes**

Run: `uv run pytest tests/core/test_workitem_store.py tests/core/test_workitem.py -v`
Expected: PASS.

- [ ] **Step 5: Stage** (`git add`); orchestrator commits.
<!-- /mship:task -->

---

<!-- mship:task id=3 -->
### Task 3: Plan clause in `check_task_gate` (opt-in via `require_plan`)

**Files:**
- Modify: `src/mship/core/workitem_gate.py`
- Test: `tests/test_workitem_gate.py`

Add a plan requirement for feature work items, gated behind a `require_plan` param so it applies ONLY where the caller asks (phase-dev + finish), never at spawn.

- [ ] **Step 1: Write the failing tests**

In `tests/test_workitem_gate.py` (mirror the feature-spec tests; set up a feature WI with an approved spec so ONLY the plan is missing):

```python
def test_feature_without_plan_blocked_when_require_plan(tmp_path):
    # feature WI + approved spec + task, but NO plan doc
    ... (build env like the approved-spec tests)
    res = check_task_gate(task, tmp_path, require_plan=True)
    assert res.ok is False and "plan" in res.reason.lower()

def test_feature_with_convention_plan_passes(tmp_path):
    # write docs/plans/<slug>.md with a mship:task anchor
    res = check_task_gate(task, tmp_path, require_plan=True)
    assert res.ok is True

def test_plan_not_required_by_default(tmp_path):
    # same env, NO plan doc, default require_plan=False (spawn path)
    assert check_task_gate(task, tmp_path).ok is True

def test_empty_plan_file_is_invalid(tmp_path):
    # docs/plans/<slug>.md exists but has no mship:task anchor
    res = check_task_gate(task, tmp_path, require_plan=True)
    assert res.ok is False

def test_bug_never_plan_gated(tmp_path):
    # kind=bug, require_plan=True, no plan
    assert check_task_gate(bug_task, tmp_path, require_plan=True).ok is True
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/test_workitem_gate.py -k plan -v`
Expected: FAIL (`require_plan` param + plan clause missing).

- [ ] **Step 3: Implement the clause**

In `src/mship/core/workitem_gate.py`, add `require_plan: bool = False` to `check_task_gate`; after the feature-spec check, add:

```python
    if require_plan and wi.kind == "feature" and not _feature_has_plan(wi, task, workspace_root):
        return GateResult(False,
            "feature WorkItem requires an implementation plan before dev/finish — "
            "write one (writing-plans, at <docs_dir>/plans/<date>-<slug>.md) or link it "
            "with `mship item link-plan`. Use --bypass-plan-gate / --hotfix to skip.")
    return GateResult(True)
```

and the helper (reuse the shared resolver; needs `docs_dir` from config — load it):

```python
def _feature_has_plan(wi, task, workspace_root: Path) -> bool:
    from mship.core.plan import resolve_plan_path, plan_has_tasks
    from mship.core.config import ConfigLoader  # or the existing config access pattern
    docs_dir = "docs"
    try:
        docs_dir = ConfigLoader.load(Path(workspace_root) / "mothership.yaml", require_paths=False).docs_dir
    except Exception:
        pass
    p = resolve_plan_path(task.slug, getattr(wi, "plan_path", None), workspace_root, docs_dir)
    return p is not None and plan_has_tasks(p.read_text())
```

(Confirm the exact config-load idiom used elsewhere in the module; match it. Fall back to `docs_dir="docs"` on any load error.)

- [ ] **Step 4: Run to verify it passes**

Run: `uv run pytest tests/test_workitem_gate.py -v`
Expected: PASS.

- [ ] **Step 5: Stage** (`git add`); orchestrator commits.
<!-- /mship:task -->

---

<!-- mship:task id=4 -->
### Task 4: Wire the plan gate at phase-dev + finish (+ bypass)

**Files:**
- Modify: `src/mship/core/phase.py` (`plan→dev` block ~78-113)
- Modify: `src/mship/cli/phase.py` (add `--bypass-plan-gate`)
- Modify: `src/mship/cli/worktree.py` (finish gate call ~1020-1048)
- Test: `tests/core/test_phase.py`, `tests/test_finish_gate.py`

- [ ] **Step 1: Write the failing tests**

In `tests/core/test_phase.py` (mirror the feature-spec plan→dev tests; the env has an approved spec so only the plan is missing):

```python
def test_plan_to_dev_blocked_without_plan(tmp_path, ...):
    with pytest.raises(SpecGateError, match="plan"):
        pm.transition(slug, "dev")

def test_plan_to_dev_allowed_with_plan(tmp_path, ...):
    # write docs/plans/<slug>.md with an anchor
    pm.transition(slug, "dev")  # no raise
    assert state.tasks[slug].phase == "dev"

def test_bypass_plan_gate_logs_hotfix(tmp_path, ...):
    pm.transition(slug, "dev", bypass_plan_gate=True)  # no raise; bypass logged
```

Add a finish-gate test in `tests/test_finish_gate.py` mirroring the spec-gate finish test: feature with approved spec but no plan → finish blocked; with plan → allowed; `--hotfix` bypasses.

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/core/test_phase.py -k plan tests/test_finish_gate.py -v`
Expected: FAIL.

- [ ] **Step 3: Wire it**

- `src/mship/core/phase.py`: in the `plan→dev` gate block, call `check_task_gate(task, self._workspace_root, require_plan=True)` (so the existing spec check AND the new plan check both run). Add a `bypass_plan_gate: bool = False` param to `transition`; when set, skip the plan requirement (call with `require_plan=False`) and `log_hotfix(..., "phase-dev-plan", task_slug)`. Keep `bypass_spec_gate` behavior intact.
- `src/mship/cli/phase.py`: add `--bypass-plan-gate` option, thread to `transition(..., bypass_plan_gate=...)`.
- `src/mship/cli/worktree.py` finish: change the gate call to `check_task_gate(task, workspace_root, require_plan=True)`; the existing `--hotfix` path already downgrades gate failures to a warning + `log_hotfix` — confirm it covers the plan failure too.

- [ ] **Step 4: Run to verify it passes**

Run: `uv run pytest tests/core/test_phase.py tests/test_finish_gate.py tests/test_spawn_gate.py -v`
Expected: PASS (spawn tests confirm spawn is still NOT plan-gated).

- [ ] **Step 5: Stage** (`git add`); orchestrator commits.
<!-- /mship:task -->

---

<!-- mship:task id=5 -->
### Task 5: `mship item link-plan`

**Files:**
- Modify: `src/mship/cli/workitem.py` (add `link-plan`, mirroring `link-spec` at 233-238)
- Test: `tests/cli/test_workitem*.py`

- [ ] **Step 1: Write the failing test**

Mirror the `link-spec` CLI test: `mship item link-plan <id> docs/plans/x.md` sets `plan_path`; a missing item errors.

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/cli -k link_plan -v`
Expected: FAIL (no such command).

- [ ] **Step 3: Implement the command**

In `src/mship/cli/workitem.py`, mirror `link_spec` — a `link-plan` subcommand taking `item_id` + `plan_path`, calling `WorkItemStore(...).link_plan(item_id, plan_path, now)`, printing confirmation (human) / JSON.

- [ ] **Step 4: Run to verify it passes**

Run: `uv run pytest tests/cli -k "link_plan or workitem" -v`
Expected: PASS.

- [ ] **Step 5: Stage** (`git add`); orchestrator commits.
<!-- /mship:task -->

---

<!-- mship:task id=6 -->
### Task 6: Plan-driven dispatch

**Files:**
- Modify: `src/mship/cli/dispatch.py` (auto-resolve linked plan when `--plan` omitted + `--task` given)
- Modify: `src/mship/core/spec_dispatch.py` (`build_dispatch_handoff` points at the plan when linked)
- Test: `tests/cli/test_dispatch.py`, `tests/core/test_dispatch.py` (or test_spec_dispatch)

- [ ] **Step 1: Write the failing tests**

In `tests/cli/test_dispatch.py`:

```python
def test_dispatch_task_auto_resolves_linked_plan(tmp_path, ...):
    # task with a discoverable plan at docs/plans/<slug>.md (2 mship:task blocks)
    # mship dispatch --task <slug> --plan-task 2   (NO --plan)
    # -> emits the extracted Task 2 text from the auto-resolved plan
    assert "Task 2" in result.output

def test_dispatch_explicit_plan_still_overrides(...):
    # --plan <path> still wins over the linked plan
```

For `spec_dispatch`, a test that `build_dispatch_handoff` references the plan's tasks when the task/WI has a linked plan, and the spec-kickoff text when it doesn't.

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/cli/test_dispatch.py -k "auto_resolve or plan" -v`
Expected: FAIL (`--plan` currently required with `--plan-task`).

- [ ] **Step 3: Implement**

- `src/mship/cli/dispatch.py`: when `--plan` is omitted but `--task` is given and `--plan-task` (or a new default) is requested, resolve the task's plan via `resolve_plan_path` (using the task's `work_item_id` → `WorkItem.plan_path`, else the convention). If found, read it and feed `extract_plan_task` as today. Keep explicit `--plan` as an override and preserve the "exactly one instruction source" rule (a resolved plan counts as the plan source).
- `src/mship/core/spec_dispatch.py`: in `build_dispatch_handoff`, if a plan resolves for the task, add a section pointing the build at the plan (its path + "execute the mship:task blocks in order, e.g. `mship dispatch --task <slug> --plan-task N`"); otherwise keep the spec-based kickoff and instruct writing the plan first.

- [ ] **Step 4: Run to verify it passes**

Run: `uv run pytest tests/cli/test_dispatch.py tests/core/test_dispatch.py -v`
Expected: PASS.

- [ ] **Step 5: Stage** (`git add`); orchestrator commits.
<!-- /mship:task -->

---

<!-- mship:task id=7 -->
### Task 7: Docs

**Files:**
- Modify: `mothership/docs/cli.md` (document `mship item link-plan`; note the feature plan-gate + `--bypass-plan-gate`)
- Modify: the `working-with-mothership` skill doc if it describes the spec gate / phase flow (add the plan gate alongside)

- [ ] **Step 1: Update docs** — add `item link-plan` to the Work-items section, note that feature work items require a plan to enter dev/finish (auto-satisfied by writing-plans' conventional path), and that build dispatch is plan-driven. Verify no contradictions.
- [ ] **Step 2: Stage** (`git add`); orchestrator commits.
<!-- /mship:task -->

---

## Final review

After all tasks: full `mship test` green; dispatch a code reviewer over the whole diff vs the spec (ac1–ac11); confirm spawn is NOT plan-gated and bug/chore skip; then `mship finish`.

## Self-review (author)

- **Spec coverage:** ac1/ac2→T3+T4 (gate at dev+finish); ac3→T4 (spawn not gated); ac4→T3 (bug/chore skip); ac5→T1+T3 (anchor validity); ac6→T1+T3 (convention path); ac7→T2+T5 (link-plan); ac8→T4 (bypass); ac9→T6 (dispatch handoff writes-plan reminder — via spec_dispatch); ac10→T6 (dispatch --task auto-resolve); ac11→T6 (handoff points at plan). All covered.
- **Type consistency:** `resolve_plan_path(task_slug, plan_path, workspace_root, docs_dir) -> Path|None`; `plan_has_tasks(text)->bool`; `check_task_gate(task, workspace_root, require_plan=False)`; `transition(..., bypass_plan_gate=False)`; `WorkItem.plan_path: str|None`. Consistent across tasks.
- **Ordering:** T1 (resolver) → T2 (model/link) → T3 (gate uses resolver+model) → T4 (wire gate) → T5 (link CLI) → T6 (dispatch uses resolver+model) → T7 (docs). Build serially.
- **Gate-at-spawn guard:** `require_plan` defaults False; only phase-dev + finish pass True — spawn stays plan-free (verified by T4 keeping test_spawn_gate green).
