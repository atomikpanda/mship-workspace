# product_assumptions Wave 3b — Ground Control view + approve Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the operator VIEW pending plan-assumption flags for a task and APPROVE them from the phone (Ground Control), consuming/extending the Wave 3a L4 serve surface.

**Architecture:** Ground Control's Task Detail screen adds a third parallel fetch of `GET /plan-assumptions/{slug}`, renders pending flags, and each Approve button POSTs to a new `POST /plan-assumptions/{slug}/approve` serve endpoint that returns the refreshed envelope (one round-trip). The approve mutation is factored out of the CLI into a shared core module so CLI and serve cannot drift (the divergence class that generated multiple Wave 3a review rounds). Mirrors the existing spec-approve flow end to end.

**Tech Stack:** mothership (Python, FastAPI serve, pydantic, pytest); ground-control (Kotlin, Ktor client, Compose, MVVM, kotlinx.serialization, JVM unit tests).

**Spec:** `productassumptionsmd` (approved), acceptance criterion **ac6** ("checker output becomes a Ground Control flag object … not-covered + explicit human approval passes"). This wave delivers ac6's Ground Control view+approve surface (the mothership L4 gate/record/read shipped in Wave 3a).

## Global Constraints

- **Human approval attribution:** a phone approval records `approved_by = "operator"` (the spec mandates *explicit human approval*; there is one shared workspace token, no per-user identity — `"operator"` is the honest human proxy, NOT the app name).
- **No CLI/serve drift:** the approve mutation lives in ONE core module (`core/plan_assumptions_transition.py`) called by both the CLI verb and the serve handler. Do not reimplement the transaction/normalization logic in the handler.
- **Lock discipline:** every approve read-modify-write runs inside `PlanCheckStore.transaction(slug)` (per-task `fcntl.flock`), reading the stored result AFTER acquiring the lock — never trust the client's last GET.
- **≤1 flag per axis:** the store rejects duplicate normalized axes and the checker returns one verdict per axis, so an axis has at most one flag; approve targets that single flag.
- **Idempotent approve:** approving an already-approved axis is a success no-op (returns the current envelope), not an error.
- **Response = full envelope:** the approve endpoint returns the same `{task, fresh, pending, flags}` shape as `GET /plan-assumptions/{slug}` so the client updates without a second round-trip.
- **Auth:** serve routes inherit the app-wide bearer dependency; no per-route auth code.
- **GC surface = Task Detail only.** Fleet-wide Queue surfacing and push notifications are OUT OF SCOPE (deferred: the Queue path is an N+1 over the per-task endpoint).
- **JSON tolerance (GC):** DTOs use `@Serializable` with `@SerialName("snake_case")`; the client Json is `ignoreUnknownKeys = true`.

---

<!-- mship:task id=1 acs=ac6 -->
### Task 1: Extract `approve_flag` into a shared core module (mothership)

**Files:**
- Create: `src/mship/core/plan_assumptions_transition.py`
- Modify: `src/mship/cli/plan_assumptions.py` (the `approve` verb → call the core helper)
- Test: `tests/core/test_plan_assumptions_transition.py`

**Interfaces:**
- Produces: `approve_flag(store: PlanCheckStore, slug: str, axis: str, reason: str | None, approved_by: str) -> PlanCheckResult`, and exceptions `NoStoredCheck(slug)`, `UnknownAxis(axis)`. Semantics: acquire `store.transaction(slug)`; `get` the stored result (None → raise `NoStoredCheck`); find the single flag whose normalized axis matches (none → raise `UnknownAxis`); if it is already approved, return the stored result unchanged (idempotent); else set `approved=True`, `approved_reason=reason`, `approved_by=approved_by`, save, and return the updated result.
- Consumes: `PlanCheckStore`, `_normalize_axis` (from `mship.core.plan`).

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_plan_assumptions_transition.py
import pytest
from mship.core.plan_check import Flag, PlanCheckResult, PlanCheckStore, plan_hash
from mship.core.plan_assumptions_transition import (
    approve_flag, NoStoredCheck, UnknownAxis,
)


def _seed(tmp_path, flags):
    store = PlanCheckStore(tmp_path / ".mothership")
    store.save(PlanCheckResult(
        task_slug="t", plan_hash=plan_hash("p\n"), assumptions_hash="h",
        verdicts=[], flags=flags,
    ))
    return store


def test_approve_flag_marks_the_axis_and_records_operator(tmp_path):
    store = _seed(tmp_path, [Flag(axis="repo topology", source="checker", reason="gap")])
    result = approve_flag(store, "t", "Repo  Topology", reason="ok", approved_by="operator")
    match = [f for f in result.flags if f.axis == "repo topology"]
    assert len(match) == 1
    assert match[0].approved is True
    assert match[0].approved_by == "operator"
    assert match[0].approved_reason == "ok"
    # persisted
    assert store.get("t").flags[0].approved is True


def test_approve_flag_is_idempotent_on_already_approved(tmp_path):
    store = _seed(tmp_path, [Flag(axis="repo topology", source="checker", reason="g", approved=True,
                                   approved_by="operator")])
    result = approve_flag(store, "t", "repo topology", reason="again", approved_by="operator")
    match = [f for f in result.flags if f.axis == "repo topology"]
    assert match[0].approved is True
    assert match[0].approved_reason is None  # unchanged; not overwritten by the no-op


def test_approve_flag_unknown_axis_raises(tmp_path):
    store = _seed(tmp_path, [Flag(axis="repo topology", source="checker", reason="g")])
    with pytest.raises(UnknownAxis):
        approve_flag(store, "t", "not a row", reason=None, approved_by="operator")


def test_approve_flag_no_stored_check_raises(tmp_path):
    store = PlanCheckStore(tmp_path / ".mothership")
    with pytest.raises(NoStoredCheck):
        approve_flag(store, "t", "repo topology", reason=None, approved_by="operator")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `uv run pytest tests/core/test_plan_assumptions_transition.py -q`
Expected: FAIL (module does not exist).

- [ ] **Step 3: Write the core module**

```python
# src/mship/core/plan_assumptions_transition.py
"""The single approve-a-plan-assumption-flag mutation, shared by the CLI verb
(`mship plan assumptions approve`) and the serve endpoint
(`POST /plan-assumptions/{slug}/approve`) so they cannot drift — mirrors how
spec approve/verdict live in core/spec_transition.py rather than inline in serve.
"""
from __future__ import annotations

from mship.core.plan import _normalize_axis
from mship.core.plan_check import PlanCheckResult, PlanCheckStore


class NoStoredCheck(Exception):
    """No plan-check result on record for the task — nothing to approve."""


class UnknownAxis(Exception):
    """No flag for the given axis (it is not a current row, or was dispositioned
    covered/N-A so it never produced a flag)."""


def approve_flag(
    store: PlanCheckStore, slug: str, axis: str, reason: str | None, approved_by: str,
) -> PlanCheckResult:
    """Approve the pending flag for `axis` on `slug`. Idempotent: an already-approved
    axis returns the stored result unchanged. Raises NoStoredCheck / UnknownAxis.
    The whole read-modify-write runs under the per-task exclusive lock so a
    concurrent checker refresh or double-approve cannot clobber it."""
    norm = _normalize_axis(axis)
    with store.transaction(slug):
        stored = store.get(slug)
        if stored is None:
            raise NoStoredCheck(slug)
        match = next((f for f in stored.flags if _normalize_axis(f.axis) == norm), None)
        if match is None:
            raise UnknownAxis(axis)
        if match.approved:
            return stored  # idempotent no-op
        match.approved = True
        match.approved_reason = reason
        match.approved_by = approved_by
        store.save(stored)
        return stored
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/core/test_plan_assumptions_transition.py -q`
Expected: PASS.

- [ ] **Step 5: Refactor the CLI `approve` verb to call the core helper**

In `src/mship/cli/plan_assumptions.py`, replace the inline transaction/find/mutate block in the `approve` command with a call to `approve_flag`, mapping exceptions to the existing CLI errors (exit 1) and preserving the JSON/human output. `approved_by` on the CLI stays the host user (`os.environ.get("USER") or "unknown"`) — the CLI is a human at a terminal; only serve uses `"operator"`.

```python
from mship.core.plan_assumptions_transition import (
    approve_flag, NoStoredCheck, UnknownAxis,
)

with store.transaction(...):  # REMOVE the inline block; replaced by:
    ...
# becomes:
approved_by = os.environ.get("USER") or "unknown"
try:
    stored = approve_flag(store, task_obj.slug, axis, reason, approved_by)
except NoStoredCheck:
    output.error(f"No stored plan-check for {task_obj.slug}.")
    raise typer.Exit(1)
except UnknownAxis:
    output.error(f"No pending flag for axis {axis!r} on {task_obj.slug}.")
    raise typer.Exit(1)
pending = sum(1 for f in stored.flags if not f.approved)
# ... existing success output unchanged, using `stored.flags` ...
```

- [ ] **Step 6: Run the CLI approve tests to verify no behavior change**

Run: `uv run pytest tests/cli/test_plan_assumptions.py -q`
Expected: PASS (the existing approve tests — clears-one, unknown-axis-exits-1 — still pass).

- [ ] **Step 7: Commit + journal**

```bash
git add src/mship/core/plan_assumptions_transition.py src/mship/cli/plan_assumptions.py tests/core/test_plan_assumptions_transition.py
git commit -m "feat(plan-assumptions): extract approve_flag core helper shared by CLI + serve"
mship journal "extracted approve_flag core helper; CLI approve now calls it; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 acs=ac6 -->
### Task 2: `POST /plan-assumptions/{slug}/approve` serve endpoint (mothership)

**Files:**
- Modify: `src/mship/core/serve.py` (add the write endpoint next to `GET /plan-assumptions/{slug}`, ~line 675; add a request-body model near the other body models ~line 44-93)
- Test: `tests/core/test_serve.py`

**Interfaces:**
- Consumes: `approve_flag`, `NoStoredCheck`, `UnknownAxis` (Task 1); the existing `GET /plan-assumptions/{slug}` envelope builder — REFACTOR the GET handler's envelope construction into a local helper so the POST returns the identical shape.
- Produces: `POST /plan-assumptions/{slug}/approve`, body `PlanFlagApproveBody{axis: str, reason: str | None = None}`, returns `{task, fresh, pending, flags}`. 404 when the task is unknown, no stored check, or the axis has no flag. Records `approved_by="operator"`.

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_serve.py — add
def test_post_plan_assumptions_approve_marks_flag_and_returns_envelope(tmp_path):
    from mship.core.assumptions import AssumptionStore
    from mship.core.plan_check import (
        Flag, PlanCheckResult, PlanCheckStore, assumptions_hash, plan_hash,
    )
    sm, log = _seed_task(tmp_path)
    rows = AssumptionStore(tmp_path).seed()
    plan_path = _write_plan(tmp_path, "2026-07-30-dq.md", "# Plan\n\nBody.\n")
    PlanCheckStore(tmp_path / ".mothership").save(PlanCheckResult(
        task_slug="dq", plan_hash=plan_hash(plan_path.read_text()),
        assumptions_hash=assumptions_hash(rows), verdicts=[],
        flags=[Flag(axis="repo topology", source="checker", reason="gap")],
    ))
    client = TestClient(_app_with(tmp_path, sm, log))
    body = client.post("/plan-assumptions/dq/approve",
                       json={"axis": "repo topology", "reason": "ok"}).json()
    assert body["pending"] == 0
    flag = body["flags"][0]
    assert flag["approved"] is True
    assert flag["approved_by"] == "operator"
    assert flag["approved_reason"] == "ok"


def test_post_plan_assumptions_approve_unknown_axis_404(tmp_path):
    from mship.core.assumptions import AssumptionStore
    from mship.core.plan_check import (
        Flag, PlanCheckResult, PlanCheckStore, assumptions_hash, plan_hash,
    )
    sm, log = _seed_task(tmp_path)
    rows = AssumptionStore(tmp_path).seed()
    _write_plan(tmp_path, "2026-07-30-dq.md", "# Plan\n\nBody.\n")
    PlanCheckStore(tmp_path / ".mothership").save(PlanCheckResult(
        task_slug="dq", plan_hash=plan_hash("# Plan\n\nBody.\n"),
        assumptions_hash=assumptions_hash(rows), verdicts=[],
        flags=[Flag(axis="repo topology", source="checker", reason="gap")],
    ))
    client = TestClient(_app_with(tmp_path, sm, log))
    r = client.post("/plan-assumptions/dq/approve", json={"axis": "no such axis"})
    assert r.status_code == 404


def test_post_plan_assumptions_approve_unknown_task_404(tmp_path):
    sm, log = _seed_task(tmp_path)
    client = TestClient(_app_with(tmp_path, sm, log))
    r = client.post("/plan-assumptions/nope/approve", json={"axis": "x"})
    assert r.status_code == 404
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/core/test_serve.py -k plan_assumptions_approve -q`
Expected: FAIL (405/404 — route absent).

- [ ] **Step 3: Refactor the GET envelope into a helper, add the POST handler**

Near `GET /plan-assumptions/{slug}` (serve.py ~675). Extract the envelope-building (load rows, resolve plan path, compute `fresh`, `pending`, dump flags) into a local function `_plan_assumptions_envelope(slug) -> dict` used by BOTH the GET handler and the new POST handler. Add the body model beside the others (~line 44-93):

```python
class PlanFlagApproveBody(BaseModel):
    axis: str
    reason: str | None = None
```

```python
@app.post("/plan-assumptions/{slug}/approve")
def approve_plan_assumption(slug: str, body: PlanFlagApproveBody):
    from mship.core.plan_assumptions_transition import (
        approve_flag, NoStoredCheck, UnknownAxis,
    )
    from mship.core.plan_check import PlanCheckStore

    state = state_manager.load()
    if slug not in state.tasks:
        raise HTTPException(status_code=404, detail=f"no task {slug!r}")
    store = PlanCheckStore(workspace_root / ".mothership")
    try:
        approve_flag(store, slug, body.axis, body.reason, approved_by="operator")
    except NoStoredCheck:
        raise HTTPException(status_code=404, detail=f"no plan-assumption check for {slug!r}")
    except UnknownAxis:
        raise HTTPException(status_code=404, detail=f"no pending flag for axis {body.axis!r}")
    return _plan_assumptions_envelope(slug)  # refreshed shape, same as GET
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/core/test_serve.py -k plan_assumptions -q`
Expected: PASS (approve + the existing GET test).

- [ ] **Step 5: Commit + journal**

```bash
git add src/mship/core/serve.py tests/core/test_serve.py
git commit -m "feat(serve): POST /plan-assumptions/{slug}/approve (operator sign-off, returns envelope)"
mship journal "added serve approve endpoint returning the GET envelope; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 acs=ac6 -->
### Task 3: Ground Control DTOs + API + repository seam (ground-control)

**Files:**
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/dto/PlanAssumptionDtos.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/MshipClient.kt` (add methods on `SpecApi` — or a new `PlanAssumptionsApi` — mirroring `approve()`/`jsonBody()`/`auth()`)
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/TasksRepository.kt` (add `getPlanAssumptions` / `approvePlanFlag` forwarders)
- Test: `android/app/src/test/java/com/atomikpanda/groundcontrol/data/PlanAssumptionsApiTest.kt` (Ktor `MockEngine`)

**Interfaces:**
- Produces: `PlanAssumptionFlag(axis, source, reason, axisFingerprint, approved, approvedBy, approvedReason)`, `PlanAssumptionsEnvelope(task, fresh, pending, flags)`; `SpecApi.getPlanAssumptions(conn, slug): PlanAssumptionsEnvelope`; `SpecApi.approvePlanFlag(conn, slug, axis, reason): PlanAssumptionsEnvelope`; repository forwarders.
- Consumes: existing `WorkspaceConnection`, `auth()`, `jsonBody()`, `buildJson()`.

- [ ] **Step 1: Write the failing test (MockEngine)**

```kotlin
// PlanAssumptionsApiTest.kt — assert the client GETs the envelope and POSTs axis/reason,
// deserializing the {task, fresh, pending, flags[...]} response. Mirror the existing
// SpecApi MockEngine test shape (respond with a JSON string, assert parsed fields +
// request method/path/body).
```

- [ ] **Step 2: Run to verify it fails**

Run (from `android/`): `./gradlew testDebugUnitTest --tests "*PlanAssumptionsApiTest*"`
Expected: FAIL (DTOs/methods absent).

- [ ] **Step 3: Add the DTOs**

```kotlin
// PlanAssumptionDtos.kt
@Serializable
data class PlanAssumptionFlag(
    val axis: String,
    val source: String,
    val reason: String,
    @SerialName("axis_fingerprint") val axisFingerprint: String? = null,
    val approved: Boolean = false,
    @SerialName("approved_by") val approvedBy: String? = null,
    @SerialName("approved_reason") val approvedReason: String? = null,
)

@Serializable
data class PlanAssumptionsEnvelope(
    val task: String,
    val fresh: Boolean,
    val pending: Int,
    val flags: List<PlanAssumptionFlag> = emptyList(),
)

@Serializable
data class PlanFlagApproveBody(val axis: String, val reason: String? = null)
```

- [ ] **Step 4: Add the API methods (mirror `SpecApi.approve`)**

```kotlin
suspend fun getPlanAssumptions(conn: WorkspaceConnection, slug: String): PlanAssumptionsEnvelope =
    client.get("${conn.baseUrl}/plan-assumptions/$slug") { auth(conn) }.body()

suspend fun approvePlanFlag(conn: WorkspaceConnection, slug: String, axis: String, reason: String?): PlanAssumptionsEnvelope =
    client.post("${conn.baseUrl}/plan-assumptions/$slug/approve") {
        auth(conn); jsonBody(PlanFlagApproveBody(axis, reason))
    }.body()
```

Add the matching forwarders on `TasksRepository`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `./gradlew testDebugUnitTest --tests "*PlanAssumptionsApiTest*"`
Expected: PASS.

- [ ] **Step 6: Commit + journal**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/data/dto/PlanAssumptionDtos.kt \
        android/app/src/main/java/com/atomikpanda/groundcontrol/data/MshipClient.kt \
        android/app/src/main/java/com/atomikpanda/groundcontrol/data/TasksRepository.kt \
        android/app/src/test/java/com/atomikpanda/groundcontrol/data/PlanAssumptionsApiTest.kt
git commit -m "feat(gc): plan-assumption DTOs, API get/approve, repository forwarders"
mship journal "GC: added plan-assumption DTOs + API + repo seam; unit tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 acs=ac6 -->
### Task 4: Task Detail — render pending flags + approve button (ground-control)

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/tasks/TaskDetailViewModel.kt` (third parallel fetch + `ActionRef.ApproveFlag(axis)` + approve action)
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/tasks/TaskDetailScreen.kt` (render the assumptions section + Approve buttons)
- Test: `android/app/src/test/java/com/atomikpanda/groundcontrol/ui/tasks/TaskDetailViewModelTest.kt`

**Interfaces:**
- Consumes: `TasksRepository.getPlanAssumptions/approvePlanFlag` (Task 3); the existing `TaskDetailUiState.Content` (extend with `assumptions: PlanAssumptionsEnvelope?`).
- Produces: user-visible pending-flag list with a per-flag Approve action that optimistically re-renders from the returned envelope.

- [ ] **Step 1: Write the failing test**

```kotlin
// TaskDetailViewModelTest.kt — with a fake repository returning an envelope with one
// pending flag, assert Content.assumptions.pending == 1; invoking approveFlag(axis)
// calls repo.approvePlanFlag and updates Content.assumptions from the returned envelope
// (pending -> 0). Mirror the existing SpecDetailViewModel test pattern; wait for the
// fire-and-forget effect in real time, NOT advanceUntilIdle (see the GC MockEngine
// flake note — the ktor engine runs off the virtual clock).
```

- [ ] **Step 2: Run to verify it fails**

Run: `./gradlew testDebugUnitTest --tests "*TaskDetailViewModelTest*"`
Expected: FAIL (no assumptions field / approveFlag).

- [ ] **Step 3: Add the third parallel fetch + approve action to the ViewModel**

Extend `Content` with `assumptions: PlanAssumptionsEnvelope?`; add `repo.getPlanAssumptions(conn, slug)` to the parallel `runCatching` load (alongside task + journal); add `ActionRef.ApproveFlag(axis: String)`; add `approveFlag(axis): Job? = write(ActionRef.ApproveFlag(axis)) { repo.approvePlanFlag(conn, slug, axis, null) }` and update `Content.assumptions` from the returned envelope. Reuse the existing `ApiConflictException`/`NotFoundException` handling for a per-flag error surface.

- [ ] **Step 4: Render in Compose**

In `TaskDetailScreen.kt`, when `assumptions?.flags` has pending entries, show an "Assumptions to approve" section: each pending flag shows `axis` + `reason`, an Approve button wired to `vm.approveFlag(flag.axis)` with a targeted spinner from `ActionRef.ApproveFlag`. Use the human word **"assumption"**, not "axis" or "flag", in visible copy (spec vocabulary rule). Approved flags render as resolved/hidden.

- [ ] **Step 5: Run tests to verify they pass**

Run: `./gradlew testDebugUnitTest --tests "*TaskDetailViewModelTest*"`
Expected: PASS.

- [ ] **Step 6: Commit + journal**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/tasks/TaskDetailViewModel.kt \
        android/app/src/main/java/com/atomikpanda/groundcontrol/ui/tasks/TaskDetailScreen.kt \
        android/app/src/test/java/com/atomikpanda/groundcontrol/ui/tasks/TaskDetailViewModelTest.kt
git commit -m "feat(gc): Task Detail surfaces pending plan-assumptions with per-assumption Approve"
mship journal "GC: Task Detail view+approve for plan-assumptions; VM tests passing" --action committed
```
<!-- /mship:task -->

## Self-Review

- **Spec coverage:** ac6's Ground Control surface (view) + human approve path is delivered by Tasks 2–4; Task 1 is the shared-core prerequisite that keeps CLI and serve consistent. The mothership record/gate/read for ac6 shipped in Wave 3a.
- **Type consistency:** `PlanAssumptionsEnvelope`/`PlanAssumptionFlag` (Kotlin) mirror the serve `{task, fresh, pending, flags}` + `Flag` (python) field-for-field including `axis_fingerprint`/`approved_by`/`approved_reason`. `approve_flag` signature is identical at both call sites.
- **Scope:** Task Detail only; Queue/fleet-wide and push notifications explicitly deferred (Global Constraints).
- **Human-approval fidelity:** serve records `approved_by="operator"` (spec: "explicit human approval"); CLI keeps the host user.
