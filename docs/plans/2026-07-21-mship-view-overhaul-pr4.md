# PR4 — Curated inline actions (approve / request-changes + cross-entity open/copy)

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Feature:** The final PR of the `mship view` overhaul: the only state-writing surface. Adds curated, safe inline actions to the read-only views — approve / request-changes a `needs_review` spec (`a` / `R`), cross-entity open (`enter`), open-in-browser (`o`), and copy id/branch/PR-url (`y`) — while read-only stays the default everywhere else.

**Spec:** `mship-view-needs-a-major-overhaul-to`

**Goal:** Let the terminal reviewer approve or bounce a spec, and jump between/open/copy linked entities, without ever leaving a view — and without the terminal and the phone (`mship serve`) being able to race or diverge, by routing every write through the exact same spec-transition + atomic-store path serve uses.

**Architecture (grounded in the actual code):**

The crux is that there is **no single shared "approve" function today**. The approve/request-changes transition is *inlined and duplicated* in two places around three shared primitives:

- `src/mship/core/serve.py` — the FastAPI endpoints `mship serve` mounts: `post_approve` (line 596) and `post_request_changes` (line 616). They do: `approval_blockers(spec)` → `validate_transition(spec.status, "approved")` → `spec.status = "approved"; spec.clarification_reason = None` → `store.save(spec)` (via `_save_and_review`, which stamps `updated_at`). request-changes: `validate_transition(spec.status, "draft")` → `spec.status="draft"; spec.clarification_reason=reason` → `store.save`.
- `src/mship/cli/spec.py` — `approve` (line 428) and `request_changes` (line 573) inline the identical logic.

The shared primitives are `mship.core.spec.validate_transition` / `InvalidTransition`, `mship.core.spec_approve.approval_blockers` (the open-questions + unapproved-criteria + prose guard, `core/spec_approve.py`), and the atomic write `mship.core.spec_store.SpecStore.save` (tempfile + `Path.replace` — there is no advisory lock in either path; "same locking" means using this identical atomic-replace store method, reading a fresh spec via `store.find_by_id` immediately before save exactly as serve does).

So to guarantee "cannot diverge," PR4 **extracts that transition into one function** (`core/spec_transition.py`) and refactors `serve.py` *and* `cli/spec.py` to delegate to it (behavior-preserving; the existing serve/CLI suites are the parity safety net). A thin **view-facing seam** (`core/view/actions.py`) wraps it into user-facing `ActionOutcome` messages (verify `needs_review`, no-op otherwise, catch the gate). The Textual layer is thin: a generic action-hook extension on `MasterDetailApp` (`_master_detail.py`) with `a`/`R`/`o`/`y` bindings defaulting to no-op-with-message, overridden per view (`queue.py`, `workitem.py`, and the `ViewApp`-based `spec.py`), plus a `RequestChangesModal` and an in-process `EntityScreen` (`push_screen`, never a second `mship` process).

**Tech Stack:** Python 3.14, `uv run pytest` (`pythonpath=["src"]`, `asyncio_mode=auto`), Textual 8.2.3 (confirmed: `App.notify`, `App.copy_to_clipboard`, `App.push_screen` / `push_screen_wait`, `textual.screen.ModalScreen`, `textual.work` all present), `webbrowser` (stdlib), Pydantic specs.

---

<!-- mship:task id=1 -->
## Task 1 — Shared spec-transition seam (the single source of truth)

Extract serve's inlined approve/request-changes transition into one core function that serve, the CLI, and the views will all call.

**Files**
- `src/mship/core/spec_transition.py` (new)
- `tests/core/test_spec_transition.py` (new)

**Failing test** (`tests/core/test_spec_transition.py`) — mirrors `tests/core/test_serve.py` seeding style, uses the *real* store and the *real* open-questions guard:

```python
from __future__ import annotations
from datetime import datetime, timezone

import pytest

from mship.core.spec import AcceptanceCriterion, InvalidTransition, OpenQuestion, Spec
from mship.core.spec_store import SpecStore
from mship.core.spec_transition import ApprovalBlocked, approve_spec, request_changes_spec


def _dt():
    return datetime(2026, 7, 1, tzinfo=timezone.utc)


def _reviewable(**over) -> Spec:
    base = dict(
        id="s1", title="t", status="needs_review", created_at=_dt(), updated_at=_dt(),
        body="b\n", acceptance_criteria=[AcceptanceCriterion(id="ac1", text="x", verdict="approved")],
        open_questions=[],
    )
    base.update(over)
    return Spec(**base)


def test_approve_transitions_and_persists_via_store(tmp_path):
    store = SpecStore(tmp_path / "specs")
    spec = _reviewable()
    store.save(spec)
    approve_spec(spec, store)
    reloaded = store.find_by_id("s1")
    assert reloaded.status == "approved"
    assert reloaded.clarification_reason is None


def test_approve_blocked_by_open_questions_does_not_write(tmp_path):
    store = SpecStore(tmp_path / "specs")
    spec = _reviewable(open_questions=[OpenQuestion(id="q1", text="?", answer=None)])
    store.save(spec)
    with pytest.raises(ApprovalBlocked) as e:
        approve_spec(spec, store)
    assert "q1" in "; ".join(e.value.blockers)
    assert store.find_by_id("s1").status == "needs_review"


def test_request_changes_sends_to_draft_with_reason(tmp_path):
    store = SpecStore(tmp_path / "specs")
    spec = _reviewable()
    store.save(spec)
    request_changes_spec(spec, store, "tighten AC2")
    reloaded = store.find_by_id("s1")
    assert reloaded.status == "draft"
    assert reloaded.clarification_reason == "tighten AC2"


def test_approve_illegal_status_raises_invalid_transition(tmp_path):
    store = SpecStore(tmp_path / "specs")
    spec = _reviewable(status="draft")
    store.save(spec)
    with pytest.raises(InvalidTransition):
        approve_spec(spec, store)
```

Confirm the exact `OpenQuestion` field names by reading `src/mship/core/spec.py` before writing (adjust the fixture if the answer field differs).

**Run (expect fail):** `uv run pytest tests/core/test_spec_transition.py` → `ModuleNotFoundError: mship.core.spec_transition`.

**Minimal implementation** (`src/mship/core/spec_transition.py`) — the exact serve/CLI logic, once:

```python
"""The single approve / request-changes transition, shared by `mship serve`
(core/serve.py), the CLI (cli/spec.py), and the views (core/view/actions.py).

Extracted so the terminal and the phone cannot diverge: every writer performs the
identical guard (approval_blockers + validate_transition) and the identical atomic
store write (SpecStore.save = tempfile + os.replace). Callers own only their own
concerns (HTTP status mapping, CLI output, journal appends, view messaging)."""
from __future__ import annotations

from datetime import datetime, timezone

from mship.core.spec import InvalidTransition, Spec, validate_transition
from mship.core.spec_approve import approval_blockers
from mship.core.spec_store import SpecStore

__all__ = ["ApprovalBlocked", "InvalidTransition", "approve_spec", "request_changes_spec"]


class ApprovalBlocked(Exception):
    """Approval gate not met (unapproved criteria / unanswered questions / prose)."""

    def __init__(self, blockers: list[str]) -> None:
        super().__init__("; ".join(blockers))
        self.blockers = list(blockers)


def approve_spec(spec: Spec, store: SpecStore, *, bypass_gate: bool = False) -> None:
    """needs_review -> approved. Raises ApprovalBlocked (gate) or InvalidTransition."""
    if not bypass_gate:
        blockers = approval_blockers(spec)
        if blockers:
            raise ApprovalBlocked(blockers)
    validate_transition(spec.status, "approved")
    spec.status = "approved"
    spec.clarification_reason = None
    spec.updated_at = datetime.now(timezone.utc)
    store.save(spec)


def request_changes_spec(spec: Spec, store: SpecStore, reason: str) -> None:
    """needs_review/approved -> draft carrying `reason`. Raises InvalidTransition."""
    validate_transition(spec.status, "draft")
    spec.status = "draft"
    spec.clarification_reason = reason
    spec.updated_at = datetime.now(timezone.utc)
    store.save(spec)
```

**Run (expect pass):** `uv run pytest tests/core/test_spec_transition.py`.

**Commit:**
```
git add src/mship/core/spec_transition.py tests/core/test_spec_transition.py
git commit -m "PR4: extract shared approve/request-changes transition seam"
mship journal "PR4 t1: shared spec_transition seam (approve/request_changes)" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
## Task 2 — Route `mship serve` through the shared seam (parity, non-breaking)

Behavior-preserving refactor so the phone's Queue write path *is* the shared function — the existing serve suite is the divergence guard.

**Files**
- `src/mship/core/serve.py`
- `tests/core/test_serve.py`

**Failing test** — add a regression that pins the shared path is used (append to `tests/core/test_serve.py`, reusing its `_app`/`_seed_spec` helpers):

```python
def test_approve_endpoint_uses_shared_transition(tmp_path, monkeypatch):
    called = {}
    import mship.core.serve as serve_mod

    def spy(spec, store, *, bypass_gate=False):
        called["hit"] = (spec.id, bypass_gate)
        spec.status = "approved"
        spec.clarification_reason = None
        store.save(spec)
    monkeypatch.setattr(serve_mod, "approve_spec", spy, raising=False)

    now = datetime(2026, 6, 14, tzinfo=timezone.utc)
    SpecStore(tmp_path / "specs").save(Spec(
        id="ready", title="ready", status="needs_review", created_at=now, updated_at=now,
        body=render_body("p", "u", "a"),
        acceptance_criteria=[AcceptanceCriterion(id="ac1", text="x", verdict="approved")],
        open_questions=[]))
    r = TestClient(_app(tmp_path)).post("/specs/ready/approve", json={})
    assert r.status_code == 200 and r.json()["status"] == "approved"
    assert called["hit"] == ("ready", False)
```

**Run (expect fail):** `uv run pytest tests/core/test_serve.py -k approve_endpoint_uses_shared` → `AttributeError`/no `approve_spec` symbol in `serve` (spy target missing).

**Minimal implementation** — import at module top of `serve.py`:
```python
from mship.core.spec_transition import ApprovalBlocked, approve_spec, request_changes_spec
```
Replace the body of `post_approve` (keep the 404 + idempotent-already-approved short-circuit + exact HTTP strings):
```python
@app.post("/specs/{spec_id}/approve")
def post_approve(spec_id: str, body: ApproveBody):
    spec = _load_or_404(spec_id)
    if spec.status == "approved":
        return build_review(spec)          # idempotent (auto-approve may have fired)
    try:
        approve_spec(spec, store, bypass_gate=body.bypass_gate)
    except ApprovalBlocked as e:
        raise HTTPException(status_code=409, detail="cannot approve: " + "; ".join(e.blockers))
    except InvalidTransition as e:
        raise HTTPException(status_code=409, detail=str(e))
    return build_review(spec)
```
Replace the body of `post_request_changes` (keep the log_manager append):
```python
@app.post("/specs/{spec_id}/request-changes")
def post_request_changes(spec_id: str, body: ReasonBody):
    spec = _load_or_404(spec_id)
    try:
        request_changes_spec(spec, store, body.reason)
    except InvalidTransition as e:
        raise HTTPException(status_code=409, detail=str(e))
    review = build_review(spec)
    if log_manager is not None:
        try:
            log_manager.append(spec.id, f"spec request-changes (api): {body.reason}")
        except Exception:
            pass
    return review
```
`_auto_approve_if_ready` stays as-is (it is not the explicit-approve path). Note `updated_at` is now stamped inside `approve_spec`/`request_changes_spec`, so `_save_and_review` is no longer called on these two paths.

**Run (expect pass):** `uv run pytest tests/core/test_serve.py` (the full serve suite — `test_post_approve_gate_and_success`, `_bypass`, `_succeeds_when_approvable`, request-changes tests — must stay green: this is the parity proof).

**Commit:**
```
git add src/mship/core/serve.py tests/core/test_serve.py
git commit -m "PR4: serve approve/request-changes delegate to shared seam"
mship journal "PR4 t2: serve endpoints route through spec_transition" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
## Task 3 — Route the `mship spec` CLI through the shared seam

Same extraction for the CLI writers, so all three writers share one implementation.

**Files**
- `src/mship/cli/spec.py`
- `tests/cli/test_spec.py`

**Failing test** — add a spy regression to `tests/cli/test_spec.py` (reuse its existing workspace-seeding + `CliRunner` helpers; confirm their names first):

```python
def test_cli_approve_uses_shared_transition(tmp_path, monkeypatch):
    called = {}
    import mship.core.spec_transition as st
    orig = st.approve_spec
    def spy(spec, store, *, bypass_gate=False):
        called["hit"] = spec.id
        return orig(spec, store, bypass_gate=bypass_gate)
    monkeypatch.setattr(st, "approve_spec", spy)
    # ... seed a reviewable needs_review spec in a workspace (mirror existing tests) ...
    # ... invoke `mship spec approve <id>` via CliRunner, assert exit 0 ...
    assert called["hit"] == "<id>"
```
Import the symbol into `cli/spec.py`'s module namespace so the patch on `spec_transition` is seen (patch the source module, not a local alias).

**Run (expect fail):** the spy is never hit (CLI still inlines the transition).

**Minimal implementation** — in `cli/spec.py` `approve`, replace the `validate_transition`/`spec.status = "approved"`/`store.save` block (lines ~446-459) with:
```python
from mship.core.spec_transition import ApprovalBlocked, approve_spec
try:
    approve_spec(spec, store, bypass_gate=bypass_gate)
except ApprovalBlocked as e:
    output.error("Cannot approve — " + "; ".join(e.blockers) + ". Use --bypass-gate to override.")
    raise typer.Exit(1)
except InvalidTransition as e:
    output.error(str(e)); raise typer.Exit(1)
path = store.path_for(spec)
```
And in `request_changes` (lines ~594-602) replace with:
```python
from mship.core.spec_transition import request_changes_spec
try:
    request_changes_spec(spec, store, reason)
except InvalidTransition as e:
    output.error(str(e)); raise typer.Exit(1)
```
(keep the existing `log_manager().append` and output blocks). Preserve the exact error strings the CLI tests assert.

**Run (expect pass):** `uv run pytest tests/cli/test_spec.py tests/cli/test_spec_lifecycle_close.py`.

**Commit:**
```
git add src/mship/cli/spec.py tests/cli/test_spec.py
git commit -m "PR4: mship spec CLI delegates to shared transition seam"
mship journal "PR4 t3: CLI approve/request-changes route through seam" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
## Task 4 — View-facing action seam (`ActionOutcome`, Textual-free)

The safety wrapper the views call: verify `needs_review`, no-op-with-message otherwise, catch the gate, return a render-ready outcome. Fully unit-testable without Textual.

**Files**
- `src/mship/core/view/actions.py` (new)
- `tests/core/view/test_actions.py` (new)

**Failing test** (`tests/core/view/test_actions.py`):

```python
from __future__ import annotations
from datetime import datetime, timezone

from mship.core.spec import AcceptanceCriterion, OpenQuestion, Spec
from mship.core.spec_store import SpecStore
from mship.core.view.actions import approve_spec_by_id, request_changes_by_id


def _dt(): return datetime(2026, 7, 1, tzinfo=timezone.utc)

def _store(tmp_path, **over):
    store = SpecStore(tmp_path / "specs")
    base = dict(id="s1", title="t", status="needs_review", created_at=_dt(), updated_at=_dt(),
                body="b\n", acceptance_criteria=[AcceptanceCriterion(id="ac1", text="x", verdict="approved")],
                open_questions=[])
    base.update(over)
    store.save(Spec(**base))
    return store


def test_approve_ok_reflects_new_status(tmp_path):
    store = _store(tmp_path)
    out = approve_spec_by_id(store, "s1")
    assert out.ok and out.new_status == "approved"
    assert store.find_by_id("s1").status == "approved"


def test_approve_noop_when_not_needs_review(tmp_path):
    store = _store(tmp_path, status="approved")
    out = approve_spec_by_id(store, "s1")
    assert not out.ok and "not awaiting review" in out.message
    assert store.find_by_id("s1").status == "approved"


def test_approve_reports_open_questions_gate(tmp_path):
    store = _store(tmp_path, open_questions=[OpenQuestion(id="q1", text="?", answer=None)])
    out = approve_spec_by_id(store, "s1")
    assert not out.ok and "q1" in out.message
    assert store.find_by_id("s1").status == "needs_review"


def test_request_changes_needs_reason_and_writes_draft(tmp_path):
    store = _store(tmp_path)
    assert not request_changes_by_id(store, "s1", "   ").ok         # empty reason rejected
    out = request_changes_by_id(store, "s1", "tighten AC2")
    assert out.ok and out.new_status == "draft"
    assert store.find_by_id("s1").clarification_reason == "tighten AC2"


def test_missing_spec_is_safe(tmp_path):
    store = SpecStore(tmp_path / "specs")
    assert not approve_spec_by_id(store, "nope").ok
    assert not approve_spec_by_id(store, None).ok
```

**Run (expect fail):** `ModuleNotFoundError: mship.core.view.actions`.

**Minimal implementation** (`src/mship/core/view/actions.py`):

```python
"""Thin view-facing wrapper over core.spec_transition. Translates the shared
approve/request-changes transition into a render-ready ActionOutcome: verifies the
target is needs_review, no-ops (ok=False) with a visible message otherwise, and
surfaces the approval gate. No Textual — unit-testable directly."""
from __future__ import annotations

from dataclasses import dataclass

from mship.core.spec import InvalidTransition
from mship.core.spec_store import SpecStore
from mship.core.spec_transition import ApprovalBlocked, approve_spec, request_changes_spec


@dataclass(frozen=True)
class ActionOutcome:
    ok: bool
    message: str
    new_status: str | None = None


def _load_reviewable(store: SpecStore, spec_id: str | None):
    if not spec_id:
        return None, ActionOutcome(False, "No spec on this row.")
    spec = store.find_by_id(spec_id)
    if spec is None:
        return None, ActionOutcome(False, f"Spec {spec_id} not found.")
    if spec.status != "needs_review":
        return None, ActionOutcome(False, f"{spec_id} is {spec.status}, not awaiting review.")
    return spec, None


def approve_spec_by_id(store: SpecStore, spec_id: str | None) -> ActionOutcome:
    spec, bail = _load_reviewable(store, spec_id)
    if bail is not None:
        return bail
    try:
        approve_spec(spec, store)
    except ApprovalBlocked as e:
        return ActionOutcome(False, f"Cannot approve {spec_id}: {'; '.join(e.blockers)}")
    except InvalidTransition as e:
        return ActionOutcome(False, str(e))
    return ActionOutcome(True, f"Approved {spec_id}.", new_status="approved")


def request_changes_by_id(store: SpecStore, spec_id: str | None, reason: str) -> ActionOutcome:
    spec, bail = _load_reviewable(store, spec_id)
    if bail is not None:
        return bail
    reason = (reason or "").strip()
    if not reason:
        return ActionOutcome(False, "Request-changes needs a reason.")
    try:
        request_changes_spec(spec, store, reason)
    except InvalidTransition as e:
        return ActionOutcome(False, str(e))
    return ActionOutcome(True, f"Requested changes on {spec_id}.", new_status="draft")
```

**Run (expect pass):** `uv run pytest tests/core/view/test_actions.py`.

**Commit:**
```
git add src/mship/core/view/actions.py tests/core/view/test_actions.py
git commit -m "PR4: view-facing action seam (ActionOutcome)"
mship journal "PR4 t4: core/view/actions ActionOutcome wrapper" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=5 -->
## Task 5 — Generic action hooks + `a`/`R`/`o`/`y` on `MasterDetailApp`

Extend the reusable base with overridable hooks defaulting to a visible no-op, so every master/detail view inherits the keys but does nothing unsafe unless it opts in. Non-breaking (existing base + queue + cockpit tests unaffected — default hooks only announce).

**Files**
- `src/mship/cli/view/_master_detail.py`
- `tests/cli/view/test_master_detail.py`

**Failing test** — append to `tests/cli/view/test_master_detail.py`:

```python
@pytest.mark.asyncio
async def test_action_keys_default_to_visible_noop():
    view = _DemoView([ListRow("a", "Alpha", "dA")])
    async with view.run_test() as pilot:
        await pilot.pause()
        view._master.focus()
        await pilot.pause()
        await pilot.press("a")
        await pilot.pause()
        assert "not available" in view.last_action().lower()
        await pilot.press("o")
        await pilot.pause()
        assert "nothing to open" in view.last_action().lower()
        await pilot.press("y")
        await pilot.pause()
        assert "nothing to copy" in view.last_action().lower()


@pytest.mark.asyncio
async def test_enter_still_drills_when_no_open_target():
    view = _DemoView([ListRow("a", "Alpha", "dA")])
    async with view.run_test() as pilot:
        await pilot.pause()
        view._master.focus()
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        assert view.focus_target() == "detail"   # unchanged base behavior
```

**Run (expect fail):** `AttributeError: 'MasterDetailApp' object has no attribute 'last_action'` / no `a` binding.

**Minimal implementation** — in `_master_detail.py`:
- `__init__`: add `self._last_action_message: str = ""`.
- Extend `BINDINGS` (non-priority, so they type into the filter Input when it is focused — consistent with existing `q`/`r`):
```python
        Binding("a", "approve", "Approve", show=False),
        Binding("R", "request_changes", "Req-changes", show=False),
        Binding("o", "open_external", "Open↗", show=False),
        Binding("y", "copy_id", "Copy", show=False),
```
- Add the hook layer:
```python
    def last_action(self) -> str:
        return self._last_action_message

    def _announce(self, msg: str) -> None:
        self._last_action_message = msg
        self.notify(msg)

    # overridable hooks — subclasses opt in; defaults are safe no-ops
    def _do_approve(self) -> None:
        self._announce("Approve is not available here.")

    def _do_request_changes(self) -> None:
        self._announce("Request-changes is not available here.")

    def _do_open_external(self) -> None:
        self._announce("Nothing to open here.")

    def _do_copy(self) -> None:
        self._announce("Nothing to copy here.")

    def _do_open_entity(self) -> bool:
        return False   # no cross-entity target; action_drill falls back to detail focus

    def action_approve(self) -> None:
        self._do_approve()

    def action_request_changes(self) -> None:
        self._do_request_changes()

    def action_open_external(self) -> None:
        self._do_open_external()

    def action_copy_id(self) -> None:
        self._do_copy()
```
- Change `action_drill` to try cross-entity open first (fallback preserves existing behavior):
```python
    def action_drill(self) -> None:
        if self._do_open_entity():
            return
        if self._detail is not None:
            self._detail.focus()
```

**Run (expect pass):** `uv run pytest tests/cli/view/test_master_detail.py`.

**Commit:**
```
git add src/mship/cli/view/_master_detail.py tests/cli/view/test_master_detail.py
git commit -m "PR4: generic action hooks (a/R/o/y) + last_action on MasterDetailApp"
mship journal "PR4 t5: MasterDetailApp action-hook layer" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=6 -->
## Task 6 — Request-changes reason modal + in-process entity screen

Two small Textual screens used by the write and open actions. `push_screen_wait` must run inside a worker (`textual.work`) — confirm `from textual import work` in 8.2.3.

**Files**
- `src/mship/cli/view/_modals.py` (new)
- `tests/cli/view/test_modals.py` (new)

**Failing test** (`tests/cli/view/test_modals.py`) — drive the modal from a tiny host app:

```python
import pytest
from textual import work
from textual.app import App

from mship.cli.view._modals import EntityScreen, RequestChangesModal


class _Host(App):
    def __init__(self):
        super().__init__(); self.result = "unset"

    @work
    async def ask(self):
        self.result = await self.push_screen_wait(RequestChangesModal("spec-1"))


@pytest.mark.asyncio
async def test_reason_modal_returns_typed_reason():
    app = _Host()
    async with app.run_test() as pilot:
        app.ask()
        await pilot.pause()
        for ch in "fix ac2":
            await pilot.press(ch)
        await pilot.press("enter")
        await pilot.pause()
        assert app.result == "fix ac2"


@pytest.mark.asyncio
async def test_reason_modal_escape_cancels():
    app = _Host()
    async with app.run_test() as pilot:
        app.ask()
        await pilot.pause()
        await pilot.press("escape")
        await pilot.pause()
        assert app.result is None


@pytest.mark.asyncio
async def test_entity_screen_shows_text_and_dismisses():
    class H(App):
        def on_mount(self): self.push_screen(EntityScreen("spec-1", "SPEC BODY HERE"))
    app = H()
    async with app.run_test() as pilot:
        await pilot.pause()
        assert isinstance(app.screen, EntityScreen)
        await pilot.press("escape")
        await pilot.pause()
        assert not isinstance(app.screen, EntityScreen)
```

**Run (expect fail):** `ModuleNotFoundError: mship.cli.view._modals`.

**Minimal implementation** (`src/mship/cli/view/_modals.py`):

```python
"""Small in-process screens for PR4 actions: a request-changes reason prompt and a
read-only cross-entity detail overlay (opened via push_screen — never a second
mship process)."""
from __future__ import annotations

from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import Input, Label, Static


class RequestChangesModal(ModalScreen[str | None]):
    """Prompt a short reason; dismisses with the reason, or None if cancelled/empty."""
    BINDINGS = [Binding("escape", "cancel", "Cancel")]

    def __init__(self, spec_id: str) -> None:
        super().__init__()
        self._spec_id = spec_id

    def compose(self) -> ComposeResult:
        yield Vertical(
            Label(f"Request changes on {self._spec_id} — reason:", markup=False),
            Input(placeholder="what needs to change…", id="reason"),
        )

    def on_mount(self) -> None:
        self.query_one("#reason", Input).focus()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        self.dismiss(event.value.strip() or None)

    def action_cancel(self) -> None:
        self.dismiss(None)


class EntityScreen(ModalScreen[None]):
    """Read-only, scrollable overlay rendering a linked entity in-process."""
    BINDINGS = [Binding("escape,q", "close", "Close")]

    def __init__(self, title: str, text: str) -> None:
        super().__init__()
        self._title = title
        self._text = text

    def compose(self) -> ComposeResult:
        yield VerticalScroll(
            Static(f"◆ {self._title}", markup=False),
            Static(self._text, expand=True, markup=False),
        )

    def action_close(self) -> None:
        self.dismiss(None)
```

**Run (expect pass):** `uv run pytest tests/cli/view/test_modals.py`.

**Commit:**
```
git add src/mship/cli/view/_modals.py tests/cli/view/test_modals.py
git commit -m "PR4: RequestChangesModal + EntityScreen in-process screens"
mship journal "PR4 t6: reason modal + entity overlay screens" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=7 -->
## Task 7 — Wire the queue view (AC7 approve/request-changes + AC8 open/copy)

Inject a `SpecStore`, override the hooks. Approve/request-changes only on `spec-needs-review` rows; `o` opens `pr_url`; `y` copies the row's identity; `enter` opens the linked spec in-process. Keep `spec_store=None` default so existing `QueueView(items)` tests are untouched.

**Files**
- `src/mship/cli/view/queue.py`
- `tests/cli/view/test_queue_view.py`

**Failing test** — append pilot tests that seed a real store (reuse `_dt`, `SpecStore`, `SPECS_DIRNAME` already imported in the file):

```python
@pytest.mark.asyncio
async def test_queue_approve_writes_and_drops_row(tmp_path):
    from mship.core.spec import AcceptanceCriterion, Spec
    from mship.core.spec_store import SPECS_DIRNAME, SpecStore
    store = SpecStore(tmp_path / SPECS_DIRNAME)
    store.save(Spec(id="spec-1", title="t", status="needs_review", created_at=_dt(),
                    updated_at=_dt(), body="b\n",
                    acceptance_criteria=[AcceptanceCriterion(id="ac1", text="x", verdict="approved")],
                    open_questions=[]))
    view = QueueView(_items(), spec_store=store)
    async with view.run_test() as pilot:
        await pilot.pause()
        view._master.focus()
        await pilot.pause()
        await pilot.press("a")                       # spec row is first
        await pilot.pause()
        assert store.find_by_id("spec-1").status == "approved"
        assert "approved" in view.last_action().lower()
        assert not any("spec-1" in l for l in view.list_labels())   # left the queue


@pytest.mark.asyncio
async def test_queue_approve_noop_on_pr_row(tmp_path):
    view = QueueView(_items())
    async with view.run_test() as pilot:
        await pilot.pause()
        view._master.focus()
        await pilot.press("j"); await pilot.press("j")   # -> PR row
        await pilot.pause()
        await pilot.press("a")
        await pilot.pause()
        assert "spec awaiting review" in view.last_action().lower()


@pytest.mark.asyncio
async def test_queue_open_and_copy_pr(tmp_path, monkeypatch):
    import mship.cli.view.queue as qv
    opened = {}
    monkeypatch.setattr(qv.webbrowser, "open", lambda u: opened.setdefault("u", u))
    view = QueueView(_items())
    async with view.run_test() as pilot:
        await pilot.pause()
        view._master.focus()
        await pilot.press("j"); await pilot.press("j")   # -> PR row
        await pilot.pause()
        await pilot.press("o")
        await pilot.pause()
        assert opened["u"] == "https://gh/pr/9"
        await pilot.press("y")
        await pilot.pause()
        assert "https://gh/pr/9" in view.last_action()
```

**Run (expect fail):** `TypeError: __init__() got an unexpected keyword argument 'spec_store'` (and no `webbrowser`/`work` in the module).

**Minimal implementation** — in `queue.py` add imports (`import webbrowser`, `from textual import work`, the seam + modal + screen) and:

```python
class QueueView(MasterDetailApp):
    def __init__(self, items: list[QueueItem], spec_store=None, **kw) -> None:
        super().__init__(**kw)
        self._items = list(items)
        self._spec_store = spec_store

    def list_rows(self) -> list[ListRow]:
        return build_rows(self._items)

    def header_line(self) -> str | None:
        return queue_header(self._items)

    def _selected(self) -> QueueItem | None:
        key = self.selected_key()
        return next((i for i in self._items if i.key == key), None)

    # AC7 --------------------------------------------------------------
    def _do_approve(self) -> None:
        item = self._selected()
        if item is None or item.kind != "spec-needs-review" or self._spec_store is None:
            self._announce("Approve applies to a spec awaiting review.")
            return
        out = approve_spec_by_id(self._spec_store, item.spec_id)
        self._announce(out.message)
        if out.ok:
            self._items = [i for i in self._items if i.key != item.key]
            self.call_later(self.reload_rows)

    @work
    async def _do_request_changes(self) -> None:
        item = self._selected()
        if item is None or item.kind != "spec-needs-review" or self._spec_store is None:
            self._announce("Request-changes applies to a spec awaiting review.")
            return
        reason = await self.push_screen_wait(RequestChangesModal(item.spec_id))
        if reason is None:
            self._announce("Request-changes cancelled.")
            return
        out = request_changes_by_id(self._spec_store, item.spec_id, reason)
        self._announce(out.message)
        if out.ok:
            self._items = [i for i in self._items if i.key != item.key]
            await self.reload_rows()

    # AC8 --------------------------------------------------------------
    def _do_open_external(self) -> None:
        item = self._selected()
        if item is not None and item.pr_url:
            webbrowser.open(item.pr_url)
            self._announce(f"Opened {item.pr_url}")
        else:
            self._announce("No PR/thread to open on this row.")

    def _do_copy(self) -> None:
        item = self._selected()
        text = None if item is None else (item.pr_url or item.spec_id or item.task_slug)
        if text:
            self.copy_to_clipboard(text)
            self._announce(f"Copied {text}")
        else:
            self._announce("Nothing to copy here.")

    def _do_open_entity(self) -> bool:
        item = self._selected()
        if item is None or item.kind != "spec-needs-review" or self._spec_store is None:
            return False
        spec = self._spec_store.find_by_id(item.spec_id)
        if spec is None:
            return False
        self.push_screen(EntityScreen(item.spec_id, spec.body))
        return True
```
`action_request_changes` in the base calls `self._do_request_changes()`; because the override is `@work`, it is scheduled as a worker (required for `push_screen_wait`). Then wire the CLI `register()` to pass the store:
```python
    from mship.core.spec_store import SPECS_DIRNAME, SpecStore
    store = SpecStore(Path(container.config_path()).parent / SPECS_DIRNAME)
    QueueView(items, spec_store=store).run()
```
(add `from pathlib import Path` if not present).

**Run (expect pass):** `uv run pytest tests/cli/view/test_queue_view.py`.

**Commit:**
```
git add src/mship/cli/view/queue.py tests/cli/view/test_queue_view.py
git commit -m "PR4: queue view inline approve/request-changes/open/copy"
mship journal "PR4 t7: queue view actions wired (AC7+AC8)" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=8 -->
## Task 8 — Wire the workitem cockpit view (spec-row approve + row open/copy)

Same hooks on the cockpit: `a`/`R` on the spec row (when `needs_review`), `y` copies the selected entity's id/branch/PR-url, `o` opens a PR row's url, `enter` opens the linked spec. Reflect the new status on the spec row after a write.

**Files**
- `src/mship/cli/view/workitem.py`
- `tests/cli/view/test_workitem_view.py`

**Failing test** — append (reuse the file's cockpit fixtures; construct a `WorkItemCockpit` whose `spec_status="needs_review"` + a real store):

```python
@pytest.mark.asyncio
async def test_cockpit_approve_updates_spec_row(tmp_path):
    from mship.core.spec import AcceptanceCriterion, Spec
    from mship.core.spec_store import SPECS_DIRNAME, SpecStore
    store = SpecStore(tmp_path / SPECS_DIRNAME)
    store.save(Spec(id="spec-1", title="t", status="needs_review", created_at=_dt(),
                    updated_at=_dt(), body="b\n",
                    acceptance_criteria=[AcceptanceCriterion(id="ac1", text="x", verdict="approved")],
                    open_questions=[]))
    cockpit = _cockpit(spec_id="spec-1", spec_status="needs_review")   # helper in this test file
    view = WorkItemCockpitView(cockpit, spec_store=store)
    async with view.run_test() as pilot:
        await pilot.pause()
        view._master.focus()
        await pilot.pause()
        assert view.selected_key() == "spec"
        await pilot.press("a")
        await pilot.pause()
        assert store.find_by_id("spec-1").status == "approved"
        assert any("[approved]" in l for l in view.list_labels())


@pytest.mark.asyncio
async def test_cockpit_copy_pr_url(tmp_path, monkeypatch):
    # navigate to a PR row, press y, assert last_action contains its url
    ...
```

**Run (expect fail):** `TypeError` (no `spec_store` kwarg / no action hooks).

**Minimal implementation** — in `workitem.py`:
- `__init__(self, cockpit, spec_store=None, **kw)`; store both; add `self._spec_status = cockpit.spec_status`.
- Make the spec row label read the live status: in `build_rows`, use the view's status. Simplest: override `list_rows` to patch the spec row label using `self._spec_status`:
```python
    def list_rows(self) -> list[ListRow]:
        rows = build_rows(self._cockpit)
        if rows and self._spec_status is not None:
            rows[0] = ListRow(key="spec",
                              label=f"spec  {self._cockpit.spec_id or '(none)'}  [{self._spec_status}]",
                              detail=rows[0].detail)
        return rows
```
- `_do_approve`: only when `self.selected_key() == "spec"` and `self._spec_status == "needs_review"` and store present → `approve_spec_by_id`; on ok set `self._spec_status = "approved"` and `self.call_later(self.reload_rows)`; else announce.
- `_do_request_changes` (`@work`): same guard → modal → `request_changes_by_id`; on ok set `self._spec_status = "draft"` + reload.
- `_do_copy`: map selected key prefix → text (`spec:` → spec_id; `task:<slug>` → that task's `branch`; `pr:<slug>:<repo>` → that PR's `url`; `ac:<id>` → the criterion id). Use `self._cockpit`.
- `_do_open_external`: for a `pr:` row → `webbrowser.open(url)`.
- `_do_open_entity`: for the `spec` row with a store → `push_screen(EntityScreen(spec_id, spec.body))` and return True.
- CLI `register()`: pass `spec_store=SpecStore(workspace_root / SPECS_DIRNAME)` into `WorkItemCockpitView(...)`.

**Run (expect pass):** `uv run pytest tests/cli/view/test_workitem_view.py`.

**Commit:**
```
git add src/mship/cli/view/workitem.py tests/cli/view/test_workitem_view.py
git commit -m "PR4: cockpit view inline approve/request-changes/open/copy"
mship journal "PR4 t8: workitem cockpit actions wired (AC7+AC8)" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=9 -->
## Task 9 — Wire the spec stream view (`mship view spec`) approve/request-changes

`mship view spec` uses the `ViewApp` stream base (`cli/view/spec.py::SpecView`), not `MasterDetailApp`. Add `a`/`R` directly to `SpecView` for the currently-rendered `needs_review` spec, reusing the same seam + modal. Only active when the resolved canonical spec id + store are known.

**Files**
- `src/mship/cli/view/spec.py`
- `tests/cli/view/test_spec_view.py`

**Failing test** — append (mirror the existing `SpecView(...)` construction in this test file; add the two new kwargs):

```python
@pytest.mark.asyncio
async def test_spec_view_approve_writes_via_store(tmp_path):
    from mship.core.spec import AcceptanceCriterion, Spec
    from mship.core.spec_store import SPECS_DIRNAME, SpecStore
    store = SpecStore(tmp_path / SPECS_DIRNAME)
    p = store.save(Spec(id="spec-1", title="t", status="needs_review", created_at=_dt(),
                        updated_at=_dt(), body="# body\n",
                        acceptance_criteria=[AcceptanceCriterion(id="ac1", text="x", verdict="approved")],
                        open_questions=[]))
    view = SpecView(workspace_root=tmp_path, name_or_path=str(p),
                    spec_store=store, spec_id="spec-1")
    async with view.run_test() as pilot:
        await pilot.pause()
        await pilot.press("a")
        await pilot.pause()
        assert store.find_by_id("spec-1").status == "approved"
        assert "approved" in view.last_action().lower()
```

**Run (expect fail):** `TypeError` (no `spec_store`/`spec_id` kwargs; no `a` binding on `ViewApp`).

**Minimal implementation** — in `spec.py`:
- Accept and stash `spec_store=None`, `spec_id=None` in `SpecView.__init__` (and strip them in the kwargs-pop list already present). Add `self._last_action_message = ""` + `last_action()` + `_announce()` (same shape as base) + `from textual import work` / seam / modal imports.
- Add to `SpecView.BINDINGS` (it does not inherit `MasterDetailApp`): copy `ViewApp.BINDINGS` and append `Binding("a", "approve", "Approve", show=False)` and `Binding("R", "request_changes", "Req-changes", show=False)`.
- `action_approve`: if `self._spec_store` and `self._spec_id` → `out = approve_spec_by_id(...)`; `self._announce(out.message)`; if ok `self._refresh_content()`. Else announce not-available.
- `action_request_changes` (`@work`): modal → `request_changes_by_id` → announce + refresh.
- CLI `register()` `spec()` command: when a canonical spec was selected, pass `spec_store=SpecStore(specs_dir)` and `spec_id=canonical_spec_id` into the `SpecView(...)` construction (only the canonical path carries a spec id; name/task paths pass `None`, leaving the view read-only there).

**Run (expect pass):** `uv run pytest tests/cli/view/test_spec_view.py`.

**Commit:**
```
git add src/mship/cli/view/spec.py tests/cli/view/test_spec_view.py
git commit -m "PR4: mship view spec inline approve/request-changes"
mship journal "PR4 t9: spec stream view actions wired (AC7)" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=10 -->
## Task 10 — Full-suite guard + deferred-note cleanup

Confirm no regression across the whole view/serve/CLI surface, and retire the now-satisfied "deferred — read-only" note that PR3 left in the queue detail (`core/view/queue.py`, `_ACTION_HINT`/`_ACTION_DEFERRED`), replacing it with the live action hint.

**Files**
- `src/mship/core/view/queue.py`
- `tests/core/view/test_queue.py`

**Failing test** — the existing PR3 test asserts the deferred/read-only string; update it to the new hint and add the assertion first:

```python
def test_queue_detail_shows_live_action_hint():
    from mship.core.view.queue import QueueItem, queue_detail
    item = QueueItem(kind="spec-needs-review", key="k", workspace="w",
                     work_item_id="wi-1", work_item_title="T", phase="shaping", spec_id="spec-1")
    d = queue_detail(item)
    assert "a: approve" in d and "R: request-changes" in d
    assert "deferred" not in d
```

**Run (expect fail):** old deferred/read-only text still present.

**Minimal implementation** — in `core/view/queue.py` replace the deferred-action constant with:
```python
_ACTION_HINT = "  actions: a: approve · R: request-changes · enter: open · y: copy"
```
and update the detail sites to use `_ACTION_HINT` (PR rows may use a `o: open · y: copy` variant). Grep for any test still referencing the old string and update it in the same commit.

**Run (expect pass):**
```
uv run pytest tests/core/view/test_queue.py
uv run pytest tests/core tests/cli   # full guard: serve, spec CLI, all view suites green
```

**Commit:**
```
git add src/mship/core/view/queue.py tests/core/view/test_queue.py
git commit -m "PR4: replace deferred-action note with live action hints"
mship journal "PR4 t10: retire deferred note; full-suite green" --action committed
```
<!-- /mship:task -->

---

## Self-Review — AC coverage and completion

**AC7 (approve / request-changes a `needs_review` spec, same write path as serve):**
- Single shared transition extracted to `core/spec_transition.py` (Task 1); `mship serve` (Task 2) and the `mship spec` CLI (Task 3) refactored to *delegate* to it — so the terminal and the phone execute literally one implementation and cannot diverge; both go through `SpecStore.save` (tempfile + atomic `os.replace`), reading a fresh spec immediately before write exactly as serve does.
- View-facing wrapper `core/view/actions.py` (Task 4) enforces the safety rules: (a) verifies `needs_review`, (b) no-ops with a visible `ActionOutcome.message` otherwise, (c) routes through the shared locked store path, (e) surfaces the open-questions/criteria/prose gate (`approval_blockers`) — all unit-tested without Textual.
- Keybindings are thin: `a` = one-keypress approve, `R` = reason prompt (`RequestChangesModal`, Task 6) then request-changes, wired into the queue (Task 7), the cockpit spec row (Task 8), and the `mship view spec` stream view (Task 9). (d) After each successful write the view reflects the new status — the approved item leaves the attention queue and the cockpit spec row relabels to `[approved]`/`[draft]`.

**AC8 (cross-entity navigation + open/copy):**
- `enter` opens the linked entity in-process via `App.push_screen(EntityScreen)` (Task 6) — queue spec-row → the spec body, cockpit spec-row → the spec (Tasks 7, 8) — never spawning a second `mship` process; falls back to the original detail-focus drill when a row has no linked entity (base unchanged, Task 5).
- `o` opens a PR url in the browser via `webbrowser.open` (Tasks 7, 8).
- `y` copies the selected entity's id / branch / PR-url via `App.copy_to_clipboard` (Tasks 7, 8).

**Read-only stays the default:** the base hooks (Task 5) no-op with a visible message; only the queue, cockpit, and spec views opt in, and only for the curated safe writes. No building / dispatch / phase-advance / finish is reachable from any view.

**This COMPLETES the overhaul.** PR1 (data layer), PR2 (`MasterDetailApp` + workitem cockpit), PR3 (queue) are consumed here; PR4 adds the sole state-writing surface. The only "deferred" marker in the codebase (the PR3 read-only note) is retired in Task 10. No deferrals remain.
