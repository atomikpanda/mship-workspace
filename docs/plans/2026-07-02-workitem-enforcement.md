# WorkItem-Mandatory + Kind-Gated Approval Enforcement — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Spec:** mship spec `workitem-mandatory-kind-gated-approval` (approved + dispatched). Principle: **no work without a WorkItem.** Enforce it as hard mship tooling gates.

**Operator decisions (from spec review):** (1) `mship spawn` **requires** an explicit WorkItem (via `mship item new` first) — no auto-create. (2) Only **kind=feature** requires an approved spec; bug/chore/question are WorkItem-only. (3) Gates **hard-block** with an explicit **`--hotfix`** override (logged). (4) **Migrate** existing `work_item_id=null` tasks (backfill). (5) The **PreToolUse** edit-guard is **default-on**.

**Architecture:** mothership only. A shared gate resolver (`core/workitem_gate.py`) is read by four enforcement points — `spawn`, `phase→dev`, `finish`, and the git/agent hooks — mirroring the existing untasked-work enforcement (`gate.py`/`hooks.py`/`internal.py`/`edit_guard.py`). The reverse link `task.work_item_id` (today set only by the migrator) is written at spawn and by `link-task`, so the gates have something to read.

**Tech Stack:** Python 3.11+, Pydantic v2, Typer, pytest, uv. Run tests: `uv run pytest`. Journal each step with `mship journal`.

---

## File Structure

- **Create** `src/mship/core/workitem_gate.py` — the shared resolver + `--hotfix` bypass logging.
- **Modify** `src/mship/core/workitem_store.py` — `add_task` also sets `task.work_item_id` (reverse link).
- **Modify** `src/mship/cli/workitem.py` — `link-task` sets the reverse link.
- **Modify** `src/mship/cli/worktree.py` (`spawn`, `finish`) + `src/mship/core/worktree.py` (`WorktreeManager.spawn`).
- **Modify** `src/mship/core/phase.py` (+ `src/mship/cli/phase.py`).
- **Modify** `src/mship/cli/internal.py` (`_check-commit`, `_check-push`, `_guard-edit`) + `src/mship/core/edit_guard.py`.
- **Modify** `src/mship/core/workitem_migrate.py` — backfill for pre-enforcement migration.
- Tests alongside each in `tests/`.

---

<!-- mship:task id=1 -->
### Task 1: Reverse-link foundation + shared gate resolver

**Files:** Create `core/workitem_gate.py`; Modify `core/workitem_store.py`, `cli/workitem.py`; Test `tests/test_workitem_gate.py`

- [ ] **Step 1: Reverse link.** In `core/workitem_store.py::add_task` (line ~71), after appending to `item.task_slugs`, also set the task's `work_item_id` via the state store (mirror how `workitem_migrate.wrap_existing` pass 2 mutates the task at `workitem_migrate.py:46-49`). `add_task` will need the `StateStore` (thread it in, matching the migrator's `state.mutate(_set)` pattern). Also update `cli/workitem.py::link-task` (line ~88) to pass the state store so the reverse link is written.

- [ ] **Step 2: Shared resolver** — `core/workitem_gate.py`:
```python
from pathlib import Path
from dataclasses import dataclass
from mship.core.workitem_store import WorkItemStore
from mship.core.spec_store import SpecStore

# "approved or beyond" — matches PhaseManager._has_approved_spec (phase.py:174-190)
_APPROVED = {"approved", "dispatched", "implemented"}

@dataclass(frozen=True)
class GateResult:
    ok: bool
    reason: str | None = None   # actionable message when not ok

def check_task_gate(task, workspace_root: Path) -> GateResult:
    """Universal: a task must have a WorkItem. Kind-gated: a feature WorkItem
    must have an approved spec. bug/chore/question need only the WorkItem."""
    if getattr(task, "work_item_id", None) is None:
        return GateResult(False, "no WorkItem — create one with `mship item new --kind <kind>` "
                                 "and spawn with `--work-item <id>` (or pass `--hotfix` to override)")
    items = WorkItemStore(workspace_root / ".mothership" / "workitems")
    wi = items.get(task.work_item_id)
    if wi is None:
        return GateResult(False, f"work_item_id {task.work_item_id!r} not found")
    if wi.kind == "feature" and not _feature_has_approved_spec(wi, task, workspace_root):
        return GateResult(False, "feature WorkItem requires an approved spec before dev/finish "
                                 "(approve it in Ground Control, or `--hotfix` to override)")
    return GateResult(True)

def _feature_has_approved_spec(wi, task, workspace_root: Path) -> bool:
    specs = SpecStore(workspace_root / "specs")
    if wi.spec_id:
        s = specs.find_by_id(wi.spec_id)
        if s is not None and s.status in _APPROVED:
            return True
    return any(s.task_slug == task.slug and s.status in _APPROVED for s in specs.list())
```

- [ ] **Step 3: `--hotfix` logging helper** in the same module — reuse `core/gate.py::record_bypass` (appends to `.mothership/bypass-log.jsonl`):
```python
from mship.core.gate import record_bypass
def log_hotfix(workspace_root: Path, where: str, task_slug: str) -> None:
    record_bypass(workspace_root, reason="hotfix", context={"gate": where, "task": task_slug})
```
*(Verify `record_bypass`'s actual signature at `core/gate.py:31` and adapt.)*

- [ ] **Step 4: Tests** (`tests/test_workitem_gate.py`, pytest): a task with `work_item_id=None` → `ok=False`; a task → bug WorkItem → `ok=True` (no spec needed); a task → feature WorkItem with no approved spec → `ok=False`; feature WorkItem whose `spec_id` resolves to an `approved` spec → `ok=True`; `add_task` sets `task.work_item_id` (reverse link). Use tmp-dir stores.

- [ ] **Step 5:** `uv run pytest tests/test_workitem_gate.py` green; commit + `mship journal`.
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: spawn gate — require a WorkItem

**Files:** Modify `cli/worktree.py` (`spawn`), `core/worktree.py` (`WorktreeManager.spawn`); Test `tests/test_spawn_gate.py`

- [ ] **Step 1:** Add `--work-item/--item <id>` and `--hotfix` options to `cli/worktree.py::spawn` (signature ~line 234).

- [ ] **Step 2:** Between the reconcile gate (~line 285) and the `wt_mgr.spawn(...)` call (~line 444): if `--work-item` is missing → if `--hotfix`, `workitem_gate.log_hotfix(ws, "spawn", slug)` and continue; else `output.error("mship spawn requires a WorkItem: create one with `mship item new` and pass --work-item <id> (or --hotfix)")` + `raise typer.Exit(1)`. If given, validate it exists (`WorkItemStore.get`) → 1 if not.

- [ ] **Step 3:** Thread `work_item_id` through `core/worktree.py::WorktreeManager.spawn` (~line 404) into the `Task(...)` constructor (~line 625) so `task.work_item_id` is set atomically; and call `WorkItemStore.add_task(work_item_id, slug, state=...)` (Task 1's reverse-link-aware version) for the forward link.

- [ ] **Step 4: Tests:** `spawn(..., work_item_id=None)` without hotfix → `SystemExit`/error, no task created; with a valid `--work-item` → task has `work_item_id` set AND the WorkItem lists the slug; `--hotfix` without a work-item → task created + a bypass-log entry. Mirror existing spawn tests' harness.

- [ ] **Step 5:** `uv run pytest tests/test_spawn_gate.py` green; commit + `mship journal`.
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: phase→dev gate — feature ⇒ approved spec

**Files:** Modify `core/phase.py`, `cli/phase.py`; Test `tests/test_phase.py` (extend)

- [ ] **Step 1:** Inject a `WorkItemStore` (or `workspace_root`, already present) into `PhaseManager` so it can resolve the task's WorkItem (constructor ~lines 33-43).

- [ ] **Step 2:** Extend the existing plan→dev gate (`core/phase.py::transition`, ~lines 69-82). BEFORE/around the current `require_approved_spec` block, call `workitem_gate.check_task_gate(task, workspace_root)`; on `not ok` and `not bypass_spec_gate` → raise `SpecGateError(result.reason)`. This makes the gate: (a) WorkItem required universally, (b) feature ⇒ approved spec (replacing/subsuming the old task-spec check, which was task-slug based and kind-agnostic — keep it as a fallback but the WorkItem-kind path is authoritative). Keep `--bypass-spec-gate` (cli/phase.py:16) as the `--hotfix` equivalent; log via `log_hotfix` when bypassed.

- [ ] **Step 3: Tests** (extend `tests/test_phase.py`): plan→dev with a task having no `work_item_id` → `SpecGateError`; with a bug WorkItem → allowed; with a feature WorkItem + no approved spec → blocked; feature + approved spec → allowed; `bypass_spec_gate=True` → allowed + logged.

- [ ] **Step 4:** `uv run pytest tests/test_phase.py` green; commit + `mship journal`.
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: finish gate — refuse PR without WorkItem / feature-without-spec

**Files:** Modify `cli/worktree.py` (`finish`); Test `tests/test_finish_gate.py`

- [ ] **Step 1:** In `cli/worktree.py::finish` (~line 830), add a `--hotfix` option. After `resolve_for_command(...)` (~line 955), call `workitem_gate.check_task_gate(task, ws)`; if `not ok`: if `--hotfix` → `output.warning("WorkItem gate bypassed (--hotfix): {reason}")` + `log_hotfix(ws,"finish",slug)`; else `output.error("Cannot finish: {reason}")` + `raise typer.Exit(1)`. Mirror the block/warn shape of the existing test-evidence gate (lines ~1197-1242) and the hard-block dependency gate (~973-988).

- [ ] **Step 2: Tests:** finish on a task with `work_item_id=None` → exit 1 (no PR); feature WorkItem w/o approved spec → exit 1; with approved spec (or bug WorkItem) → passes the gate; `--hotfix` → warns + proceeds + logs. Stub the PR-open path as existing finish tests do.

- [ ] **Step 3:** `uv run pytest tests/test_finish_gate.py` green; commit + `mship journal`.
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: hooks — commit/push + PreToolUse edit-guard

**Files:** Modify `cli/internal.py` (`_check-commit`, `_check-push`, `_guard-edit`), `core/edit_guard.py`; Test `tests/test_internal_gate.py`, `tests/test_edit_guard.py` (extend)

- [ ] **Step 1: commit/push.** In `cli/internal.py::_check-commit` (~line 55) and `_check-push` (~line 237), after the existing "active task registered" checks pass, also run `workitem_gate.check_task_gate(matched_task, ws)`; on `not ok` → refuse (same refusal shape as the existing "needs a task" path), honoring `resolve_bypass()`/`MSHIP_BYPASS_GATE` as the `--hotfix` escape. Fail OPEN on unexpected errors (match existing behavior).

- [ ] **Step 2: PreToolUse.** Extend `core/edit_guard.py::evaluate_edit` (~line 32): when the edit targets source under an active task's worktree, also block if `check_task_gate` fails (no WorkItem / feature-without-spec). Keep the existing main-checkout block and `MSHIP_ALLOW_MAIN_EDIT` escape; add a `MSHIP_BYPASS_GATE` (hotfix) escape. `_guard-edit` (~line 291) already wires stdin→evaluate_edit→exit 2; no install change needed (default-on via `claude_settings.install_pretooluse_guard_hook`).

- [ ] **Step 3: Tests:** `_check-commit` with a task lacking a WorkItem + staged source → refuses (exit non-zero); with `MSHIP_BYPASS_GATE` → allowed. `evaluate_edit` blocks a source edit when the task has no WorkItem; allows when the WorkItem gate passes; fails open on malformed input. Extend the existing edit-guard tests.

- [ ] **Step 4:** `uv run pytest tests/test_internal_gate.py tests/test_edit_guard.py` green; commit + `mship journal`.
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: backfill migration + full-suite verification

**Files:** Modify `core/workitem_migrate.py`; Test `tests/test_workitem_migrate.py` (extend)

- [ ] **Step 1:** Extend `core/workitem_migrate.py::wrap_existing` pass 2 (orphan tasks → WorkItems, ~lines 37-49): a task whose `task.spec_id` (or a `task_slug`-matched spec) resolves to an approved spec → create the WorkItem with `kind="feature"` (and `link_spec`); otherwise keep `kind="chore"`. Idempotent (skip tasks that already have `work_item_id`). This is the pre-enforcement backfill so no active task is left `work_item_id=None`. Runs via the existing `mship item migrate` (`cli/workitem.py:120`).

- [ ] **Step 2: Tests** (extend `tests/test_workitem_migrate.py`): an orphan task with no spec → gets a chore WorkItem + `work_item_id` set; an orphan task whose spec is approved → gets a feature WorkItem linked to the spec; re-running is idempotent (no duplicates).

- [ ] **Step 3: Full suite** — `uv run pytest` green (the new gates must not break existing spawn/phase/finish/hook tests; update any test that spawns without a WorkItem to pass one or `--hotfix`). Then run `mship test` at HEAD for finish evidence.

- [ ] **Step 4:** commit + `mship journal`.
<!-- /mship:task -->

---

## Self-review checklist

- **Spec coverage:** WorkItem required at spawn (T2) + commit/push/edit (T5); feature⇒approved-spec at phase-dev (T3) + finish (T4); bug/chore/question WorkItem-only (T1 resolver); `--hotfix` override logged everywhere (T1 helper, used T2-T5); migration backfills null work_item_ids (T6); PreToolUse default-on (T5, already wired). All 7 acceptance criteria mapped.
- **One resolver, many gates** — `check_task_gate` is the single source of truth; each gate is a thin call.
- **Reverse link is the linchpin** — set at spawn (T2) + by `link-task` (T1); backfilled (T6).

## Notes / risks

- **Ordering matters:** ship the backfill (T6) + reverse-link (T1) BEFORE the hard gates bite, or existing in-flight tasks (all `work_item_id=null`) get blocked. Run `mship item migrate` as part of rollout.
- **`--bypass-spec-gate` already exists** on `phase`; reuse it as the hotfix path there rather than adding a second flag.
- **Fail-open in hooks** (commit/push/edit) on unexpected errors — never brick the user's git over a gate bug (matches existing enforcement-gate behavior).
- **This session's own irony:** this very feature was specced + approved through GC (spec-first) — the process it enforces.
