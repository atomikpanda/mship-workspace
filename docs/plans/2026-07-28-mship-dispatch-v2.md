# mship dispatch v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `mship dispatch` resolves the subagent model, persists metadata-only dispatch records under `.mothership/sdd/`, hands the controller a closed stub, and lets the subagent derive its own full prompt (plan slice + spec AC text) at emit time.

**Architecture:** Everything derives from two canonical stores at emit time — the plan file (prose, `mship:task` anchors) and the spec store (acceptance text). The dispatch record is a pointer + metadata JSON, never a copy. Controller stdout is a closed set of stub fields; the full prompt renders only when the subagent runs `--emit` from its worktree. Review packages are the one stored content: raw `git diff` files a reviewer reads directly.

**Tech Stack:** Python 3.12, typer CLI, pydantic models, pytest. All work in `mothership` repo. Spec: `mship-dispatch-v2`.

**Ordering:** Tasks 1→7 are sequential (each builds on the previous). Tasks 8–9 depend on 1–7 but not on each other.

---

<!-- mship:task id=1 -->
### Task 1: Anchor attributes — `acs=` on `mship:task` anchors

The current open-anchor regexes require `-->` immediately after the id, so an anchor carrying attributes (`mship:task id=3 acs=ac2,ac5` in comment brackets) doesn't parse anywhere today. Extend both parsers to accept optional attributes, and expose the parsed attrs.

> **Meta-note for the implementer:** this plan document is itself parsed by the anchor extractor, so every example anchor in the code blocks below is written as split Python string literals (`"<!-- mship:" "task ..."`) — they concatenate to real anchors at runtime but never appear contiguously in this file. Keep that property when editing tests.

**Files:**
- Modify: `src/mship/core/dispatch.py` (`_TASK_OPEN_RE` at line ~27, `extract_plan_task` at ~31)
- Modify: `src/mship/core/plan.py` (`_TASK_ANCHOR_RE` at line ~14)
- Test: `tests/core/test_dispatch.py`, `tests/core/test_plan.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/core/test_dispatch.py — add:
from mship.core.dispatch import extract_plan_task, extract_plan_task_meta

PLAN_WITH_ACS = (
    "<!-- mship:" "task id=3 acs=ac2,ac5 -->\n"
    "### Task 3: Thing\n"
    "body here\n"
    "<!-- /mship:" "task -->\n"
)

def test_extract_plan_task_ignores_attributes():
    assert "body here" in extract_plan_task(PLAN_WITH_ACS, "3")

def test_extract_plan_task_meta_returns_acs():
    text, meta = extract_plan_task_meta(PLAN_WITH_ACS, "3")
    assert "body here" in text
    assert meta == {"acs": ["ac2", "ac5"]}

def test_extract_plan_task_meta_no_attrs():
    plan = "<!-- mship:" "task id=1 -->\nx\n<!-- /mship:" "task -->"
    text, meta = extract_plan_task_meta(plan, "1")
    assert meta == {}
```

```python
# tests/core/test_plan.py — add:
from mship.core.plan import plan_has_tasks

def test_plan_has_tasks_with_attributes():
    assert plan_has_tasks("<!-- mship:" "task id=1 acs=ac1 -->\nx\n<!-- /mship:" "task -->")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/core/test_dispatch.py -k "meta or attributes" tests/core/test_plan.py -k attributes -v`
Expected: FAIL (`extract_plan_task_meta` not defined; attribute anchor not matched)

- [ ] **Step 3: Implement**

In `src/mship/core/dispatch.py`, replace the open regex and add the meta variant (keep `extract_plan_task` delegating so all 18 existing callers are untouched):

```python
_TASK_OPEN_RE = re.compile(r"<!--\s*mship:task\s+id=([^\s>]+)((?:\s+[a-z_]+=[^\s>]+)*)\s*-->")
_ATTR_RE = re.compile(r"([a-z_]+)=([^\s>]+)")


def extract_plan_task_meta(plan_text: str, task_id: str) -> tuple[str, dict]:
    """Like extract_plan_task, but also returns parsed anchor attributes.

    Attributes are optional `key=value` pairs after the id (e.g. an anchor
    of the form mship:task id=3 acs=ac2,ac5). `acs` is split on commas into
    a list. Unknown keys pass through as raw strings (forward-compatible).
    """
    opens = [m for m in _TASK_OPEN_RE.finditer(plan_text) if m.group(1) == task_id]
    if not opens:
        raise ValueError(
            f"no task with id {task_id!r} in plan "
            f"(expected an anchor mship:task id={task_id})"
        )
    if len(opens) > 1:
        raise ValueError(f"duplicate task id {task_id!r} in plan ({len(opens)} anchors)")
    open_m = opens[0]
    close_m = _TASK_CLOSE_RE.search(plan_text, open_m.end())
    next_open = _TASK_OPEN_RE.search(plan_text, open_m.end())
    if close_m is None or (next_open is not None and next_open.start() < close_m.start()):
        raise ValueError(
            f"unterminated task block for id {task_id!r} "
            f"(missing the closing /mship:task anchor)"
        )
    meta: dict = {}
    for k, v in _ATTR_RE.findall(open_m.group(2) or ""):
        meta[k] = v.split(",") if k == "acs" else v
    return plan_text[open_m.end():close_m.start()].strip(), meta


def extract_plan_task(plan_text: str, task_id: str) -> str:
    # (replace the existing body with:)
    text, _ = extract_plan_task_meta(plan_text, task_id)
    return text
```

Keep `extract_plan_task`'s existing docstring. In `src/mship/core/plan.py` line ~14, widen the anchor detector the same way:

```python
_TASK_ANCHOR_RE = re.compile(r"<!--\s*mship:task\s+id=([^\s>]+)(?:\s+[a-z_]+=[^\s>]+)*\s*-->")
```

- [ ] **Step 4: Run the full affected suites**

Run: `uv run pytest tests/core/test_dispatch.py tests/core/test_plan.py -v`
Expected: PASS, including all pre-existing anchor tests (no behavior change for attribute-less anchors)

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/dispatch.py src/mship/core/plan.py tests/core/test_dispatch.py tests/core/test_plan.py
git commit -m "feat(dispatch): parse optional attributes (acs=) on mship:task anchors"
mship journal "task 1: anchor attrs + extract_plan_task_meta; suites passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: Model resolution

**Files:**
- Create: `src/mship/core/dispatch_models.py`
- Modify: `src/mship/core/config.py` (add `dispatch_models` field to `WorkspaceConfig`, line ~337)
- Test: `tests/core/test_dispatch_models.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/core/test_dispatch_models.py
import pytest
from mship.core.dispatch_models import resolve_model, BUILTIN_MODEL_DEFAULTS

def test_flag_wins():
    assert resolve_model("implementer", flag="opus", configured={"implementer": "sonnet"}) == "opus"

def test_config_beats_builtin():
    assert resolve_model("reviewer", flag=None, configured={"reviewer": "haiku"}) == "haiku"

def test_builtin_default_per_mode():
    assert resolve_model("implementer", flag=None, configured=None) == BUILTIN_MODEL_DEFAULTS["implementer"]
    assert resolve_model("reviewer", flag=None, configured=None) == BUILTIN_MODEL_DEFAULTS["reviewer"]

def test_unknown_mode_raises():
    with pytest.raises(ValueError):
        resolve_model("juggler", flag=None, configured=None)

def test_config_field_roundtrip():
    from mship.core.config import WorkspaceConfig
    cfg = WorkspaceConfig(workspace="w", dispatch_models={"implementer": "sonnet"})
    assert cfg.dispatch_models == {"implementer": "sonnet"}
    assert WorkspaceConfig(workspace="w").dispatch_models is None
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/core/test_dispatch_models.py -v`
Expected: FAIL with "No module named 'mship.core.dispatch_models'"

- [ ] **Step 3: Implement**

```python
# src/mship/core/dispatch_models.py
"""Resolve the model a dispatched subagent runs on (spec mship-dispatch-v2).

The dispatcher — not the untrusted worker — owns the model choice. Precedence:
CLI flag > `dispatch_models:` per-mode map in mothership.yaml > built-in
per-mode default. Values are operator-chosen strings passed through verbatim
(harness-specific tier names are not validated here).

Upstream superpowers found that an unnamed model silently inherits the
session's most expensive tier; resolving here makes the choice explicit,
auditable, and configured in one place.
"""
from __future__ import annotations

# Reviewer work is judgment over prepared files — a cheaper tier by default.
# "inherit" means: no explicit model; the dispatching harness uses its session
# model. Implementers default to inherit so a capable session stays capable.
BUILTIN_MODEL_DEFAULTS: dict[str, str] = {
    "implementer": "inherit",
    "standalone": "inherit",
    "reviewer": "sonnet",
}


def resolve_model(mode: str, *, flag: str | None, configured: dict[str, str] | None) -> str:
    if mode not in BUILTIN_MODEL_DEFAULTS:
        raise ValueError(
            f"unknown dispatch mode {mode!r}; choose one of {', '.join(BUILTIN_MODEL_DEFAULTS)}"
        )
    if flag is not None:
        return flag
    if configured and mode in configured:
        return configured[mode]
    return BUILTIN_MODEL_DEFAULTS[mode]
```

In `src/mship/core/config.py`, add to `WorkspaceConfig` (beside `spec_paths`, line ~372):

```python
    # Per-dispatch-mode model map for `mship dispatch` (spec mship-dispatch-v2).
    # Keys: implementer | reviewer | standalone. Values are passed through
    # verbatim (harness-specific). None = built-in defaults
    # (core/dispatch_models.py). Precedence: --model flag > this map > builtin.
    dispatch_models: dict[str, str] | None = None
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/core/test_dispatch_models.py tests/core/test_config.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/dispatch_models.py src/mship/core/config.py tests/core/test_dispatch_models.py
git commit -m "feat(dispatch): model resolution — flag > dispatch_models config > builtin per-mode default"
mship journal "task 2: resolve_model + WorkspaceConfig.dispatch_models" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: Dispatch record store (metadata-only, pointer not copy)

**Files:**
- Create: `src/mship/core/sdd_store.py`
- Test: `tests/core/test_sdd_store.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/core/test_sdd_store.py
from datetime import datetime, timezone
from pathlib import Path
from mship.core.sdd_store import DispatchRecord, SddStore

NOW = datetime(2026, 7, 28, 12, 0, tzinfo=timezone.utc)

def _record(**over):
    base = dict(
        task_slug="my-task", work_item_id="wi-1", mode="implementer",
        model="sonnet", repo="api", worktree="/ws/.worktrees/my-task/api",
        base_branch="main", base_sha="a" * 7, head_sha="b" * 7,
        plan_path="docs/plans/2026-07-28-my-task.md", plan_task_id="3",
        acs=["ac2", "ac5"], instruction=None, created_at=NOW,
    )
    base.update(over)
    return DispatchRecord(**base)

def test_write_then_read_roundtrip(tmp_path):
    store = SddStore(tmp_path / ".mothership")
    store.write(_record())
    rec = store.read(work_item_id="wi-1", task_slug="my-task")
    assert rec.plan_task_id == "3" and rec.model == "sonnet" and rec.acs == ["ac2", "ac5"]

def test_record_dir_is_keyed_by_workitem_and_slug(tmp_path):
    store = SddStore(tmp_path / ".mothership")
    p = store.write(_record())
    assert p == tmp_path / ".mothership" / "sdd" / "wi-1" / "my-task" / "record.json"

def test_no_workitem_uses_no_item_key(tmp_path):
    store = SddStore(tmp_path / ".mothership")
    p = store.write(_record(work_item_id=None))
    assert p.parent.parent.name == "no-item"

def test_record_never_contains_plan_body(tmp_path):
    """The record is a pointer: plan prose must not be persisted (spec ac2)."""
    store = SddStore(tmp_path / ".mothership")
    p = store.write(_record())
    raw = p.read_text()
    assert "plan_path" in raw and "docs/plans" in raw
    for field in ("body", "task_text", "prompt", "template"):
        assert f'"{field}"' not in raw

def test_remove_task_removes_all_records_for_slug(tmp_path):
    store = SddStore(tmp_path / ".mothership")
    store.write(_record())
    store.write(_record(work_item_id=None))
    store.remove_task("my-task")
    assert not list((tmp_path / ".mothership" / "sdd").rglob("record.json"))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/core/test_sdd_store.py -v`
Expected: FAIL with "No module named 'mship.core.sdd_store'"

- [ ] **Step 3: Implement**

```python
# src/mship/core/sdd_store.py
"""Dispatch-record store under `<state_dir>/sdd/` (spec mship-dispatch-v2).

A record is metadata + a POINTER to canonical content — plan path + anchor id
(or an ad-hoc instruction for non-plan dispatches) — never a copy of plan
prose. Prompts are derived at emit time from the plan and spec stores, so an
edited plan is reflected on the next emit and no second copy can drift.
Layout: `<state_dir>/sdd/<work-item-id | no-item>/<task-slug>/record.json`,
with review-package artifacts (Task 6) beside it. Everything here is
git-ignored with the rest of `.mothership/` and removed by `mship close`.
"""
from __future__ import annotations

import json
import shutil
from datetime import datetime
from pathlib import Path

from pydantic import BaseModel

_NO_ITEM = "no-item"


class DispatchRecord(BaseModel):
    task_slug: str
    work_item_id: str | None
    mode: str
    model: str
    repo: str
    worktree: str
    base_branch: str
    base_sha: str | None
    head_sha: str | None
    # Exactly one content pointer: (plan_path + plan_task_id) or instruction.
    plan_path: str | None
    plan_task_id: str | None
    acs: list[str] = []
    instruction: str | None
    created_at: datetime


class SddStore:
    def __init__(self, state_dir: Path):
        self.root = state_dir / "sdd"

    def _dir(self, work_item_id: str | None, task_slug: str) -> Path:
        return self.root / (work_item_id or _NO_ITEM) / task_slug

    def write(self, rec: DispatchRecord) -> Path:
        d = self._dir(rec.work_item_id, rec.task_slug)
        d.mkdir(parents=True, exist_ok=True)
        path = d / "record.json"
        path.write_text(rec.model_dump_json(indent=2) + "\n")
        return path

    def read(self, *, work_item_id: str | None, task_slug: str) -> DispatchRecord:
        path = self._dir(work_item_id, task_slug) / "record.json"
        return DispatchRecord.model_validate(json.loads(path.read_text()))

    def find_for_slug(self, task_slug: str) -> DispatchRecord | None:
        """Locate a record by slug alone (the subagent's emit path — it knows
        its task from cwd, not its WorkItem)."""
        for p in sorted(self.root.glob(f"*/{task_slug}/record.json")):
            return DispatchRecord.model_validate(json.loads(p.read_text()))
        return None

    def remove_task(self, task_slug: str) -> None:
        """Remove every record dir for this slug (close-time teardown)."""
        if not self.root.is_dir():
            return
        for d in self.root.glob(f"*/{task_slug}"):
            shutil.rmtree(d, ignore_errors=True)
        for item_dir in self.root.iterdir():
            if item_dir.is_dir() and not any(item_dir.iterdir()):
                item_dir.rmdir()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/core/test_sdd_store.py -v`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/sdd_store.py tests/core/test_sdd_store.py
git commit -m "feat(dispatch): metadata-only dispatch-record store under .mothership/sdd/"
mship journal "task 3: SddStore — pointer records, keyed wi/slug, remove_task" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: Controller stub — closed-field stdout, record persisted

`mship dispatch --plan-task N` becomes: resolve model → persist record → print a **closed stub** (nothing else). `--full` keeps the old inline full-prompt output for manual/non-SDD use (still persists the record). Ad-hoc `--instruction` dispatches keep full output by default (no behavior break) but gain the same record + `--stub` opt-in.

**Files:**
- Create: `src/mship/core/dispatch_stub.py`
- Modify: `src/mship/cli/dispatch.py` (the `dispatch` command, flags at lines ~42-60, instruction resolution at ~82-126)
- Test: `tests/core/test_dispatch_stub.py`, `tests/cli/test_dispatch_cli.py` (extend the existing CLI test file for dispatch; if it lives under a different name, `grep -rl "plan-task" tests/cli` and extend that file)

- [ ] **Step 1: Write the failing tests**

```python
# tests/core/test_dispatch_stub.py
from mship.core.dispatch_stub import STUB_FIELDS, build_stub
from tests.core.test_sdd_store import _record  # reuse the fixture factory

def test_stub_contains_exactly_the_closed_fields():
    rec = _record()
    stub = build_stub(rec, record_path="/ws/.mothership/sdd/wi-1/my-task/record.json")
    for label in ("record:", "model:", "mode:", "emit:"):
        assert label in stub

def test_stub_carries_no_prompt_content():
    """Spec ac3: controller stdout is a closed set — no task body, no template
    boilerplate, no acceptance text, no subagent-only prompt content."""
    rec = _record()
    stub = build_stub(rec, record_path="/p/record.json")
    assert len(stub.splitlines()) <= 8
    for leaked in (
        "Work from (mandatory)",     # template section headings
        "Conventions (recap)",
        "Report back",
        "Your instruction",
    ):
        assert leaked not in stub

def test_stub_emit_line_is_runnable_from_worktree():
    rec = _record()
    stub = build_stub(rec, record_path="/p/record.json")
    assert "mship dispatch --emit" in stub
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/core/test_dispatch_stub.py -v`
Expected: FAIL with "No module named 'mship.core.dispatch_stub'"

- [ ] **Step 3: Implement the stub builder**

```python
# src/mship/core/dispatch_stub.py
"""Controller-facing dispatch stub (spec mship-dispatch-v2, ac3).

A CLOSED set of fields. The controller's context carries orchestration facts
only; every byte of prompt content (plan slice, template, acceptance text)
reaches the subagent alone via `mship dispatch --emit`. Adding a field here
means updating the closed-set test in tests/core/test_dispatch_stub.py — that
friction is the point.
"""
from __future__ import annotations

from mship.core.sdd_store import DispatchRecord

STUB_FIELDS = ("record", "model", "mode", "worktree", "emit")


def build_stub(rec: DispatchRecord, *, record_path: str) -> str:
    return (
        f"record: {record_path}\n"
        f"model: {rec.model}\n"
        f"mode: {rec.mode}\n"
        f"worktree: {rec.worktree}\n"
        f"emit: run subagent with cwd={rec.worktree}, model={rec.model}; "
        f"its first command: `mship dispatch --emit`\n"
    )
```

- [ ] **Step 4: Wire the CLI**

In `src/mship/cli/dispatch.py` add flags to the `dispatch` command:

```python
        model: Optional[str] = typer.Option(
            None, "--model",
            help="Model for the subagent. Default: dispatch_models map in "
                 "mothership.yaml, else built-in per-mode default.",
        ),
        full: bool = typer.Option(
            False, "--full",
            help="Print the full subagent prompt inline (legacy). Default for "
                 "--plan-task is a closed stub; the subagent emits its own "
                 "prompt via --emit.",
        ),
        stub: bool = typer.Option(
            False, "--stub",
            help="Print the closed stub even for --instruction dispatches.",
        ),
```

After the existing instruction resolution (line ~126), and before prompt assembly:

```python
        from mship.core.dispatch_models import resolve_model
        from mship.core.dispatch_stub import build_stub
        from mship.core.sdd_store import DispatchRecord, SddStore
        from datetime import datetime, timezone

        resolved_model = resolve_model(
            mode, flag=model, configured=container.config().dispatch_models
        )

        # Persist the record (pointer + metadata; never plan prose).
        acs = plan_meta.get("acs", []) if plan_task is not None else []
        rec = DispatchRecord(
            task_slug=t.slug, work_item_id=t.work_item_id, mode=mode,
            model=resolved_model, repo=resolved_repo, worktree=str(t.worktrees[resolved_repo]),
            base_branch=eff_base, base_sha=base_info.base_sha, head_sha=base_info.head_sha,
            plan_path=str(resolved_plan_path) if plan_task is not None else None,
            plan_task_id=plan_task, acs=acs,
            instruction=None if plan_task is not None else resolved_instruction,
            created_at=datetime.now(timezone.utc),
        )
        record_path = SddStore(container.state_dir()).write(rec)

        want_stub = (plan_task is not None and not full) or stub
        if want_stub:
            out.print(build_stub(rec, record_path=str(record_path)))
            return
```

(Use the variable names already in scope in that function — `t` for the resolved task, `resolved_repo`, `eff_base`, `base_info` per the existing prompt-assembly code; keep the existing full-prompt path below untouched, but pass `model=resolved_model` into `build_dispatch_prompt` — Task 5 adds that parameter. In Task 1's `extract_plan_task` call site, switch to `extract_plan_task_meta` and keep the returned meta as `plan_meta`; also keep `resolved_plan_path` from the existing plan-resolution branch.)

CLI test (extend the dispatch CLI test file found via `grep -rl "plan-task" tests/cli`):

```python
def test_plan_task_dispatch_prints_stub_not_prompt(...existing fixtures...):
    result = runner.invoke(app, ["dispatch", "--task", slug, "--plan-task", "1"])
    assert result.exit_code == 0
    assert "record:" in result.output and "model:" in result.output
    assert "Work from (mandatory)" not in result.output  # closed set — no template
    assert "Your instruction" not in result.output

def test_plan_task_dispatch_full_flag_prints_prompt(...):
    result = runner.invoke(app, ["dispatch", "--task", slug, "--plan-task", "1", "--full"])
    assert "Work from (mandatory)" in result.output
```

- [ ] **Step 5: Run the suites**

Run: `uv run pytest tests/core/test_dispatch_stub.py tests/cli -k dispatch -v`
Expected: PASS (new tests + all pre-existing dispatch CLI tests — `--instruction` default output unchanged)

- [ ] **Step 6: Commit**

```bash
git add src/mship/core/dispatch_stub.py src/mship/cli/dispatch.py tests/core/test_dispatch_stub.py tests/cli
git commit -m "feat(dispatch): closed controller stub + persisted record; --full/--stub escape hatches"
mship journal "task 4: stub default for --plan-task; record persisted; closed-set test" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: Subagent emit — derive prompt from plan slice + spec AC text

**Files:**
- Modify: `src/mship/core/dispatch.py` (`build_dispatch_prompt`, line ~293 — add `model` and `acceptance` params)
- Create: `src/mship/core/dispatch_emit.py`
- Modify: `src/mship/cli/dispatch.py` (add `--emit` flag)
- Test: `tests/core/test_dispatch_emit.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/core/test_dispatch_emit.py
"""Emit derives everything live: plan slice from the plan file, acceptance
text from the spec store. Editing either changes the next emit; the record
never contains them (spec ac2/ac3/ac8)."""
from mship.core.dispatch_emit import build_emitted_prompt, PlanDriftWarning
# Build fixtures with: a tmp workspace containing a plan file with an
# `acs=ac1` anchored task, a spec (SpecStore fixture from
# tests/core/test_spec_store.py patterns) whose ac1 text is known, and a
# DispatchRecord pointing at both (reuse tests/core/test_sdd_store.py::_record).

def test_emit_contains_plan_body_and_ac_text(ws):
    prompt, warnings = build_emitted_prompt(ws.record, workspace_root=ws.root, spec=ws.spec)
    assert "the anchored body" in prompt          # from the plan file
    assert "[ac1]" in prompt and ws.spec.acceptance_criteria[0].text in prompt
    assert f"Model: {ws.record.model}" in prompt

def test_emit_reflects_plan_edit_without_touching_store(ws):
    ws.plan_path.write_text(ws.plan_path.read_text().replace("the anchored body", "EDITED BODY"))
    prompt, _ = build_emitted_prompt(ws.record, workspace_root=ws.root, spec=ws.spec)
    assert "EDITED BODY" in prompt

def test_emit_warns_when_plan_newer_than_record(ws):
    ws.plan_path.touch()  # mtime > record.created_at
    _, warnings = build_emitted_prompt(ws.record, workspace_root=ws.root, spec=ws.spec)
    assert any(isinstance(w, PlanDriftWarning) for w in warnings)

def test_emit_ad_hoc_instruction_record(ws_adhoc):
    prompt, _ = build_emitted_prompt(ws_adhoc.record, workspace_root=ws_adhoc.root, spec=None)
    assert ws_adhoc.record.instruction in prompt
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/core/test_dispatch_emit.py -v`
Expected: FAIL with "No module named 'mship.core.dispatch_emit'"

- [ ] **Step 3: Implement**

First, `build_dispatch_prompt` grows two keyword-only params (default `None` — all 18 existing callers unaffected):

```python
# in build_dispatch_prompt signature (line ~293):
    model: str | None = None,
    acceptance: list | None = None,   # list of (ac_id, text) pairs
```

In the returned f-string, under `## Task facts` add (conditionally, following the pattern of `dependencies_block`):

```python
    model_line = f"- **Model:** {model}\n" if model else ""
    acceptance_block = ""
    if acceptance:
        joined = "\n".join(f"- [{ac_id}] {text}" for ac_id, text in acceptance)
        acceptance_block = (
            "## Acceptance criteria this task serves (from the spec store — live text)\n\n"
            f"{joined}\n\n"
        )
```

and interpolate `{model_line}` after the `- **active repo:**` line and `{acceptance_block}` before `## Where the branch stands`.

Then the emit assembler:

```python
# src/mship/core/dispatch_emit.py
"""Derive the full subagent prompt from a DispatchRecord (spec mship-dispatch-v2).

Run by the SUBAGENT (not the controller): the plan slice is re-parsed from the
canonical plan file and acceptance text is pulled live from the spec store, so
neither is ever copied into the record and both reflect edits at emit time.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from mship.core.dispatch import extract_plan_task_meta
from mship.core.sdd_store import DispatchRecord


@dataclass
class PlanDriftWarning:
    plan_path: str
    record_created_at: str
    plan_mtime: str

    def __str__(self) -> str:
        return (
            f"plan {self.plan_path} modified after this dispatch was recorded "
            f"({self.plan_mtime} > {self.record_created_at}); emitting the CURRENT "
            f"plan text — re-dispatch if the task was re-scoped"
        )


def resolve_instruction_and_acs(
    rec: DispatchRecord, workspace_root: Path
) -> tuple[str, list[str], list]:
    """Return (instruction_text, ac_ids, warnings) — plan-sliced or ad-hoc."""
    warnings: list = []
    if rec.plan_task_id is None:
        return rec.instruction or "", list(rec.acs), warnings
    plan_file = workspace_root / rec.plan_path
    text, meta = extract_plan_task_meta(plan_file.read_text(), rec.plan_task_id)
    from datetime import datetime, timezone
    mtime = datetime.fromtimestamp(plan_file.stat().st_mtime, tz=timezone.utc)
    if mtime > rec.created_at:
        warnings.append(PlanDriftWarning(
            plan_path=str(plan_file),
            record_created_at=rec.created_at.isoformat(),
            plan_mtime=mtime.isoformat(),
        ))
    return text, meta.get("acs", list(rec.acs)), warnings
```

`build_emitted_prompt(rec, *, workspace_root, spec, **prompt_deps)` then: calls `resolve_instruction_and_acs`, maps AC ids to `(id, text)` via `spec.acceptance_criteria` when a spec is given (unknown ids → warning, not error), and calls `build_dispatch_prompt(..., instruction=text, model=rec.model, acceptance=pairs, mode=rec.mode)` with the journal/base-sha dependencies gathered the same way the CLI's full-prompt path already gathers them (factor that gathering into a small helper in `src/mship/cli/dispatch.py` if it isn't importable — implementer's judgment, keep it DRY with the existing path).

CLI: add to the `dispatch` command:

```python
        emit: bool = typer.Option(
            False, "--emit",
            help="Subagent-side: derive and print MY full prompt from the "
                 "dispatch record (cwd-resolved task). Prints drift warnings "
                 "to stderr.",
        ),
```

`--emit` short-circuits before the instruction-source check (it needs no `--instruction`/`--plan-task`): resolve the task from cwd, `SddStore(container.state_dir()).find_for_slug(t.slug)` (error cleanly if no record: "no dispatch record for task <slug> — the controller runs `mship dispatch --plan-task N` first"), load the bound spec via `t.spec_id` and the container's spec store when `acs` is non-empty, print the prompt to stdout and each warning via `out.warning`.

- [ ] **Step 4: Run the suites**

Run: `uv run pytest tests/core/test_dispatch_emit.py tests/core/test_dispatch.py tests/cli -k dispatch -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/dispatch_emit.py src/mship/core/dispatch.py src/mship/cli/dispatch.py tests/core/test_dispatch_emit.py
git commit -m "feat(dispatch): --emit derives the subagent prompt live from plan slice + spec AC text"
mship journal "task 5: emit-in-subagent-context; Model line + acceptance block in prompt" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: Reviewer mode + review packages (diffs as files)

**Files:**
- Modify: `src/mship/core/dispatch.py` (`DISPATCH_MODES` line ~184, `_closing_section` ~234, `_conventions_recap` ~200)
- Create: `src/mship/core/review_package.py`
- Modify: `src/mship/cli/dispatch.py` (allow `--mode reviewer`)
- Test: `tests/core/test_review_package.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/core/test_review_package.py
"""Reviewer packages: manifest JSON + raw diff files. The reviewer READS the
diff from disk; the prompt references paths and never embeds diff content
(spec ac4). One reviewer returns both spec-compliance and quality verdicts
(upstream 6.2.0 task-reviewer contract)."""
from mship.core.review_package import build_review_package, build_reviewer_prompt

def test_package_writes_manifest_and_diff_files(ws):
    # ws: tmp workspace with a git repo worktree containing 2 commits past base
    pkg = build_review_package(ws.record, git_runner=ws.shell, state_dir=ws.state_dir)
    assert pkg.manifest_path.name == "manifest.json"
    assert pkg.diff_paths and all(p.exists() for p in pkg.diff_paths)
    raw = pkg.manifest_path.read_text()
    assert '"diff_files"' in raw and '"acs"' in raw
    assert "diff --git" not in raw               # manifest is metadata, not content

def test_reviewer_prompt_references_paths_not_content(ws):
    pkg = build_review_package(ws.record, git_runner=ws.shell, state_dir=ws.state_dir)
    prompt = build_reviewer_prompt(ws.record, pkg, acceptance=[("ac1", "does the thing")])
    assert str(pkg.diff_paths[0]) in prompt
    assert "diff --git" not in prompt             # never embedded
    assert "spec-compliance" in prompt.lower() and "quality" in prompt.lower()

def test_reviewer_mode_is_dispatchable():
    from mship.core.dispatch import DISPATCH_MODES
    assert "reviewer" in DISPATCH_MODES
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/core/test_review_package.py -v`
Expected: FAIL (module missing; "reviewer" not in DISPATCH_MODES)

- [ ] **Step 3: Implement**

In `src/mship/core/dispatch.py`:

```python
DISPATCH_MODES: tuple[str, ...] = ("implementer", "standalone", "reviewer")

_REVIEW_CONTRACT = """\
You are a READ-ONLY reviewer. Do not edit files, run git write commands, or
check out branches — a reviewer mutating the worktree orphans commits.

Read the diff files listed above (they are on disk — read them as files, do
not ask for them to be pasted). Then return BOTH verdicts in one report:

1. **Spec compliance** — does the change satisfy each listed acceptance
   criterion? Verdict per criterion: satisfied / not-satisfied / can't-tell,
   with the evidence line (file:line) that convinced you.
2. **Code quality** — correctness, tests, naming, duplication, style fit with
   the surrounding code. Findings ranked by severity; state what you verified,
   not just what you suspect.

Report back as text. Do NOT open a PR, do not run `mship finish`."""
```

In `_closing_section` (~line 234), route the new mode first:

```python
    if mode == "reviewer":
        return "Review contract (read-only; both verdicts)", _REVIEW_CONTRACT
```

and in `_conventions_recap`, reviewers get `_CONV_NO_PR` (same as implementer).

```python
# src/mship/core/review_package.py
"""Review-package builder (spec mship-dispatch-v2, ac4).

The ONE stored content in the sdd store: raw `git diff` output written as
files (generated artifacts, not duplicated prose) plus a metadata manifest.
Reading diffs from disk instead of pasting them is upstream superpowers'
measured token win (~2x faster, ~50% fewer review tokens in their evals).
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from mship.core.sdd_store import DispatchRecord, SddStore


@dataclass
class ReviewPackage:
    manifest_path: Path
    diff_paths: list[Path]


def build_review_package(rec: DispatchRecord, *, git_runner, state_dir: Path) -> ReviewPackage:
    """Write `<record-dir>/review/{manifest.json, <repo>.diff}`.

    Diff range: `<base_sha>..HEAD` of the worktree (the task's commits).
    `git_runner(cmd, cwd)` is the injected shell (same contract as
    container.shell().run) so tests use a fixture repo.
    """
    d = SddStore(state_dir)._dir(rec.work_item_id, rec.task_slug) / "review"
    d.mkdir(parents=True, exist_ok=True)
    diff_paths: list[Path] = []
    res = git_runner(f"git diff {rec.base_sha}..HEAD", cwd=Path(rec.worktree))
    diff_file = d / f"{rec.repo}.diff"
    diff_file.write_text(res.stdout)
    diff_paths.append(diff_file)
    manifest = {
        "task_slug": rec.task_slug, "work_item_id": rec.work_item_id,
        "plan_path": rec.plan_path, "plan_task_id": rec.plan_task_id,
        "acs": rec.acs, "base_sha": rec.base_sha, "head_sha": rec.head_sha,
        "diff_files": [str(p) for p in diff_paths],
    }
    manifest_path = d / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    return ReviewPackage(manifest_path=manifest_path, diff_paths=diff_paths)


def build_reviewer_prompt(rec: DispatchRecord, pkg: ReviewPackage, *, acceptance: list) -> str:
    ac_block = "\n".join(f"- [{ac_id}] {text}" for ac_id, text in acceptance) or "(none mapped)"
    files_block = "\n".join(f"- `{p}`" for p in pkg.diff_paths)
    return f"""\
# Review: task {rec.task_slug} (plan task {rec.plan_task_id or 'ad-hoc'})

**Model:** {rec.model}

## Diff files to read (on disk — read, don't paste)

{files_block}

Manifest: `{pkg.manifest_path}`

## Acceptance criteria to check (live from the spec store)

{ac_block}
"""
```

CLI wiring in `src/mship/cli/dispatch.py`: `--mode reviewer` requires an existing record (`find_for_slug`); the controller path builds the package and prints the stub (Task 4's `build_stub` — same closed fields); `--emit` with a reviewer-mode record prints `build_reviewer_prompt(...)` + `_REVIEW_CONTRACT` via the normal `_closing_section` flow, with acceptance pairs resolved exactly as in Task 5.

- [ ] **Step 4: Run the suites**

Run: `uv run pytest tests/core/test_review_package.py tests/core/test_dispatch.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/review_package.py src/mship/core/dispatch.py src/mship/cli/dispatch.py tests/core/test_review_package.py
git commit -m "feat(dispatch): reviewer mode — read-only dual-verdict contract, diffs as files"
mship journal "task 6: review packages + reviewer dispatch mode" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=7 -->
### Task 7: Close-time cleanup of the sdd store

**Files:**
- Modify: `src/mship/cli/worktree.py` (the `close` command, after worktree teardown succeeds)
- Test: `tests/cli/test_worktree.py` (extend — this file already covers close paths)

- [ ] **Step 1: Write the failing test**

```python
# tests/cli/test_worktree.py — add near the existing close tests, reusing
# their fixtures (grep "def test_close" for the established setup pattern):
def test_close_removes_sdd_records(...existing close fixtures...):
    # Arrange: write a record for the task being closed
    from mship.core.sdd_store import SddStore, DispatchRecord
    from datetime import datetime, timezone
    store = SddStore(state_dir)
    store.write(DispatchRecord(
        task_slug=slug, work_item_id="wi-x", mode="implementer", model="m",
        repo="api", worktree=str(wt_path), base_branch="main",
        base_sha=None, head_sha=None, plan_path=None, plan_task_id=None,
        instruction="x", created_at=datetime.now(timezone.utc),
    ))
    # Act: close the task (whichever invoke pattern the neighboring tests use)
    ...
    # Assert: no orphan store directory survives (spec ac6)
    assert not list((state_dir / "sdd").rglob(f"*/{slug}"))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/cli/test_worktree.py -k sdd -v`
Expected: FAIL (records survive close)

- [ ] **Step 3: Implement**

In the `close` command in `src/mship/cli/worktree.py`, at the point where worktrees have been removed and state is being cleared (beside the existing per-task teardown; best-effort like `_capture_dirty_main_post_op`):

```python
        # sdd dispatch records are per-task scratch — remove with the worktree
        # (spec mship-dispatch-v2 ac6). Best-effort: cleanup never blocks close.
        try:
            from mship.core.sdd_store import SddStore
            SddStore(container.state_dir()).remove_task(task_slug)
        except Exception:
            pass
```

Also add the same call in the PR-watcher's merge auto-close teardown path — find it with `grep -rn "auto-close\|teardown" src/mship/core/pr_watcher.py` and mirror the best-effort call there so serve-driven closes clean up too.

- [ ] **Step 4: Run the suite**

Run: `uv run pytest tests/cli/test_worktree.py tests/core/test_pr_watcher.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/mship/cli/worktree.py src/mship/core/pr_watcher.py tests/cli/test_worktree.py
git commit -m "feat(dispatch): close (manual and merge-auto) removes the task's sdd records"
mship journal "task 7: sdd cleanup on both close paths" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=8 -->
### Task 8: `mship context` exposes model resolution

**Files:**
- Modify: `src/mship/core/context.py` (the context payload builder)
- Test: `tests/core/test_context.py` (extend)

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_context.py — add, following the file's existing payload-assertion pattern:
def test_context_includes_dispatch_models(...existing context fixtures...):
    payload = ...  # build context the way neighboring tests do
    assert "dispatch_models" in payload
    assert payload["dispatch_models"]["implementer"]  # resolved, mode-keyed
    assert payload["dispatch_models"]["reviewer"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_context.py -k dispatch_models -v`
Expected: FAIL (key absent)

- [ ] **Step 3: Implement**

In the context payload builder in `src/mship/core/context.py`:

```python
    from mship.core.dispatch_models import BUILTIN_MODEL_DEFAULTS, resolve_model
    payload["dispatch_models"] = {
        m: resolve_model(m, flag=None, configured=config.dispatch_models)
        for m in BUILTIN_MODEL_DEFAULTS
    }
```

(`config` is whatever WorkspaceConfig object the builder already receives; thread it through if absent.)

- [ ] **Step 4: Run the suite**

Run: `uv run pytest tests/core/test_context.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/context.py tests/core/test_context.py
git commit -m "feat(context): expose per-mode resolved dispatch models"
mship journal "task 8: context carries resolved dispatch_models" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=9 -->
### Task 9: Ergonomics guard + docs

**Files:**
- Modify: `tests/skills/test_skill_dispatch_ergonomics.py`
- Modify: `docs/configuration.md` (config table, ~line 183)
- Modify: `src/mship/skills/working-with-mothership/SKILL.md` (the `mship dispatch` section — ours, not superpowers-vendored)

- [ ] **Step 1: Extend the guard (write first — it fails until docs/skill text exists)**

```python
# tests/skills/test_skill_dispatch_ergonomics.py — add:
from pathlib import Path

_WWM = Path("src/mship/skills/working-with-mothership/SKILL.md")

def test_working_with_mothership_documents_stub_and_emit():
    text = _WWM.read_text()
    assert "--emit" in text          # subagent derives its own prompt
    assert "stub" in text.lower()    # controller gets a pointer, not the prompt

def test_working_with_mothership_documents_model_resolution():
    text = _WWM.read_text()
    assert "dispatch_models" in text

def test_configuration_docs_cover_dispatch_models():
    assert "dispatch_models" in Path("docs/configuration.md").read_text()
```

- [ ] **Step 2: Run to verify they fail**

Run: `uv run pytest tests/skills/test_skill_dispatch_ergonomics.py -v`
Expected: the three new tests FAIL; existing ones still pass

- [ ] **Step 3: Write the docs**

`docs/configuration.md` — add a row to the config table (~line 183):

```markdown
| `dispatch_models` | Per-mode model map for `mship dispatch` (`implementer` / `reviewer` / `standalone`). Values pass through verbatim to the dispatching harness. Precedence: `--model` flag > this map > built-in defaults (reviewer defaults to a cheaper tier). |
```

`src/mship/skills/working-with-mothership/SKILL.md` — in the "Delegating to subagents" section, extend the `mship dispatch` bullet:

```markdown
  **Model resolution:** dispatch resolves the subagent's model (`--model` >
  `dispatch_models:` in mothership.yaml > built-in per-mode default) and stamps
  it in the output — the worker never chooses its own model.

  **Context isolation (SDD flow):** `mship dispatch --plan-task N` persists a
  metadata-only record under `.mothership/sdd/` and prints a **closed stub**
  (record path, model, mode, emit line). Do NOT expand it: launch the subagent
  with cwd set to the worktree and let its first command be
  `mship dispatch --emit`, which derives the full prompt (plan slice + live
  spec AC text) in the subagent's own context. Reviewer dispatches
  (`--mode reviewer`) build a review package (raw diff files + manifest) the
  reviewer reads from disk. `--full` prints the old inline prompt when you
  genuinely need it in-context.
```

- [ ] **Step 4: Run the whole guard + affected suites**

Run: `uv run pytest tests/skills/ -v`
Expected: PASS (all)

- [ ] **Step 5: Full suite + commit**

```bash
uv run mship test    # full evidence-recorded run — must be green
git add tests/skills/test_skill_dispatch_ergonomics.py docs/configuration.md src/mship/skills/working-with-mothership/SKILL.md
git commit -m "docs(dispatch): dispatch_models config + stub/emit contract; ergonomics guard extended"
mship journal "task 9: guard + docs; full suite green" --action committed --test-state pass
```
<!-- /mship:task -->

---

## Verification against the spec

| Spec AC | Covered by |
|---|---|
| ac1 model precedence + explicit in outputs | Tasks 2, 4, 5 |
| ac2 metadata-only record, pointer not copy | Task 3 (`test_record_never_contains_plan_body`), Task 4 |
| ac3 closed stub, emit-in-subagent-context, plan-edit reflected | Tasks 4, 5 |
| ac4 review package: manifest + diff files, paths not embedded | Task 6 |
| ac5 no rendered markdown persisted in the store | Tasks 3, 6 (stores are JSON + `.diff` only) |
| ac6 close removes records, no orphans | Task 7 |
| ac7 `acs=` anchor → live AC text in emits, in no stored artifact | Tasks 1, 5, 6 |
| ac8 ergonomics guard extended and green | Task 9 |
