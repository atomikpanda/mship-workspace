# product_assumptions Wave 3c — fleet-wide Queue surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Surface pending plan-assumptions **across all tasks** in Ground Control's Queue tab (fleet-wide "route to the human", not just per-task), sourced from a new serve list endpoint that avoids N+1.

**Architecture:** A new `GET /plan-assumptions` list endpoint iterates the stored plan-checks and returns `{task, fresh, pending}` per task, reusing Wave 3b's exact freshness/pending computation. Ground Control's `QueueRepository` gains a third card source that hits it and emits a `PlanAssumptionCard` (pending > 0), which **deep-links to the existing Wave 3b Task Detail** for view+approve (no inline-approve duplication).

**Tech Stack:** mothership (Python, FastAPI, pytest); ground-control (Kotlin, Ktor, Compose, MVVM, JVM unit tests).

**Spec:** `productassumptionsmd` (approved), ac6 (the Ground Control flag surface) — this is the fleet-wide increment of the surface 3b started at the Task-Detail level.

## Global Constraints

- **DEFERRED (do NOT build here):** push/notification (synthesizing a `needs_you` thread from the gate) — Ground Control has no FCM and there's no gate→message-store link today; that's a follow-on (tracked on #454). This wave is the Queue **pull** surface only.
- **Reuse Wave 3b freshness/pending logic verbatim** — the list endpoint must compute `fresh`/`pending` the same way `serve.py::_plan_assumptions_envelope` does (`is_fresh(stored, plan_text, rows)`, `pending = sum(1 for f in flags if not f.approved)`); load the workspace assumption `rows` ONCE for the whole list, not per task.
- **Only stored plan-checks are reported** — mirror the per-task endpoint's `stored is None` → skip. A task with no `PlanCheckResult` contributes nothing.
- **Deep-link, don't duplicate** — the Queue card navigates to the existing `TaskDetailScreen` (3b) for approving; do NOT build a second flag-approval UI in the Queue card.
- **Card contract** matches the existing `QueueV2Card` shape (connectionId, workspaceName, key, tier, waitingSince).

---

<!-- mship:task id=1 acs=ac6 -->
### Task 1: `GET /plan-assumptions` list endpoint (mothership)

**Files:**
- Modify: `src/mship/core/plan_check.py` (add `PlanCheckStore.list_slugs()`)
- Modify: `src/mship/core/serve.py` (add `GET /plan-assumptions`; factor the per-task envelope into a shared helper)
- Test: `tests/core/test_plan_check.py` (list_slugs), `tests/core/test_serve.py` (endpoint)

**Interfaces:**
- Produces: `PlanCheckStore.list_slugs() -> list[str]` (stems of `<state>/plan-checks/*.json`); `GET /plan-assumptions` → `[{"task": str, "fresh": bool, "pending": int}]` for every task that has a stored `PlanCheckResult` AND still exists in state, reusing the per-task freshness computation.
- Consumes: `is_fresh`, `PlanCheckStore`, `AssumptionStore`, `effective_plan_path` (all existing).

- [ ] **Step 1: Write the failing test for `list_slugs`**

```python
# tests/core/test_plan_check.py
def test_list_slugs_returns_stored_task_slugs(tmp_path):
    store = PlanCheckStore(tmp_path)
    store.save(PlanCheckResult(task_slug="a", plan_hash="h", assumptions_hash="x", verdicts=[], flags=[]))
    store.save(PlanCheckResult(task_slug="b", plan_hash="h", assumptions_hash="x", verdicts=[], flags=[]))
    assert sorted(store.list_slugs()) == ["a", "b"]

def test_list_slugs_empty_when_no_dir(tmp_path):
    assert PlanCheckStore(tmp_path / "nope").list_slugs() == []
```

- [ ] **Step 2: Run → FAIL** (`uv run pytest tests/core/test_plan_check.py -k list_slugs -q`).

- [ ] **Step 3: Implement `list_slugs`**

```python
# src/mship/core/plan_check.py — on PlanCheckStore
def list_slugs(self) -> list[str]:
    """Task slugs with a stored plan-check (`<dir>/*.json` stems). Empty when the
    dir doesn't exist. Lets the serve list endpoint enumerate without reaching
    into the private dir."""
    if not self._dir.is_dir():
        return []
    return sorted(p.stem for p in self._dir.glob("*.json"))
```

- [ ] **Step 4: Write the failing endpoint test**

```python
# tests/core/test_serve.py
def test_get_plan_assumptions_list_returns_pending_per_task(tmp_path):
    from mship.core.assumptions import AssumptionStore
    from mship.core.plan_check import Flag, PlanCheckResult, PlanCheckStore, assumptions_hash, plan_hash
    sm, log = _seed_task(tmp_path)          # task "dq"
    rows = AssumptionStore(tmp_path).seed()
    plan_path = _write_plan(tmp_path, "2026-07-30-dq.md", "# Plan\n\nBody.\n")
    PlanCheckStore(tmp_path / ".mothership").save(PlanCheckResult(
        task_slug="dq", plan_hash=plan_hash(plan_path.read_text()),
        assumptions_hash=assumptions_hash(rows), verdicts=[],
        flags=[Flag(axis="repo topology", source="checker", reason="gap")]))
    client = TestClient(_app_with(tmp_path, sm, log))
    body = client.get("/plan-assumptions").json()
    row = next(r for r in body if r["task"] == "dq")
    assert row["pending"] == 1 and row["fresh"] is True
```

- [ ] **Step 5: Run → FAIL** (route absent).

- [ ] **Step 6: Refactor the per-task freshness/pending into a shared helper + add the list endpoint**

Factor the fresh/pending computation out of `get_plan_assumptions` (serve.py ~675-712) into a local helper `_task_assumption_summary(slug, stored, rows, docs_dir, state)` returning `{"task", "fresh", "pending"}` (and the per-task GET keeps returning flags too). Then:

```python
@app.get("/plan-assumptions")
def list_plan_assumptions():
    from mship.core.assumptions import AssumptionStore, resolve_mode
    from mship.core.plan_check import PlanCheckStore
    state = state_manager.load()
    docs_dir = getattr(config, "docs_dir", "docs") if config is not None else "docs"
    rows = AssumptionStore(workspace_root, docs_dir=docs_dir, mode=resolve_mode(workspace_root)).load()
    pcstore = PlanCheckStore(workspace_root / ".mothership")
    out = []
    for slug in pcstore.list_slugs():
        if slug not in state.tasks:
            continue
        stored = pcstore.get(slug)
        if stored is None:
            continue
        out.append(_task_assumption_summary(slug, stored, rows, docs_dir, state))
    return out
```

- [ ] **Step 7: Run → PASS** (`uv run pytest tests/core/test_serve.py -k plan_assumptions tests/core/test_plan_check.py -k list_slugs -q`). Confirm the existing per-task GET/POST tests still pass (the refactor must not change their shape).

- [ ] **Step 8: Commit + journal**

```bash
git add src/mship/core/plan_check.py src/mship/core/serve.py tests/core/test_plan_check.py tests/core/test_serve.py
git commit -m "feat(serve): GET /plan-assumptions list endpoint (fleet-wide pending counts, reuses 3b freshness)"
mship journal "added plan-assumptions list endpoint + PlanCheckStore.list_slugs" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 acs=ac6 -->
### Task 2: Queue card for pending assumptions (ground-control)

**Files:**
- Modify: `android/.../data/dto/PlanAssumptionDtos.kt` (add the list-summary DTO)
- Modify: `android/.../data/MshipClient.kt` (add `listPlanAssumptions`)
- Modify: `android/.../data/QueueRepository.kt` (third card source)
- Modify: `android/.../ui/queue/QueueCard.kt` (add `PlanAssumptionCard` variant + its rendering)
- Modify: the Queue screen/nav wiring so tapping the card opens the existing Task Detail (Wave 3b)
- Test: `android/.../QueueRepositoryTest.kt` (or the existing queue test) — MockEngine

**Interfaces:**
- Consumes: `GET /plan-assumptions` (Task 1); the existing `QueueV2Card`/`QueueTier` model; the existing Task Detail route.
- Produces: `PlanAssumptionSummary(task, fresh, pending)` DTO; `SpecApi.listPlanAssumptions(conn): List<PlanAssumptionSummary>`; a `QueueV2Card.PlanAssumptionCard`; a Queue card that deep-links to Task Detail.

- [ ] **Step 1: Write the failing test (MockEngine)**

Mirror the existing QueueRepository test: a MockEngine returns `/plan-assumptions` = `[{"task":"dq","fresh":true,"pending":2},{"task":"ok","fresh":true,"pending":0}]`; assert `sourceCards()` includes exactly one `PlanAssumptionCard` for "dq" (pending>0) and none for "ok" (pending 0).

- [ ] **Step 2: Run → FAIL** (from `android/`, `source ~/toolchains/android-env.sh` first; `./gradlew testDebugUnitTest --tests "*Queue*"`).

- [ ] **Step 3: DTO + API**

```kotlin
@Serializable
data class PlanAssumptionSummary(val task: String, val fresh: Boolean = true, val pending: Int = 0)
// SpecApi:
suspend fun listPlanAssumptions(conn: WorkspaceConnection): List<PlanAssumptionSummary> =
    client.get("${conn.baseUrl}/plan-assumptions") { auth(conn) }.body()
```

- [ ] **Step 4: Card variant + source**

Add `data class PlanAssumptionCard(... , val task: String, val pending: Int) : QueueV2Card` (tier = APPROVAL). In `QueueRepository.sourceCards()` add a third `async { }`: `listPlanAssumptions(conn).filter { it.pending > 0 }.map { PlanAssumptionCard(...) }`, mirroring `decisionCards`.

- [ ] **Step 5: Render + deep-link**

In the Queue card composable, render the `PlanAssumptionCard` as e.g. "N assumptions need sign-off — <task>" (copy says "assumption", never "axis"/"flag"), and wire tap → navigate to the existing `TaskDetailScreen` for that task (reuse the 3b route). No inline approval.

- [ ] **Step 6: Run → PASS** (`./gradlew testDebugUnitTest --tests "*Queue*"`). Keep existing queue tests green.

- [ ] **Step 7: Commit + journal**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/data/dto/PlanAssumptionDtos.kt \
        android/app/src/main/java/com/atomikpanda/groundcontrol/data/MshipClient.kt \
        android/app/src/main/java/com/atomikpanda/groundcontrol/data/QueueRepository.kt \
        android/app/src/main/java/com/atomikpanda/groundcontrol/ui/queue/QueueCard.kt \
        android/app/src/test/java/com/atomikpanda/groundcontrol/QueueRepositoryTest.kt
git commit -m "feat(gc): Queue card for pending plan-assumptions, deep-links to Task Detail"
mship journal "GC: fleet-wide plan-assumption Queue card -> Task Detail" --action committed
```
<!-- /mship:task -->

## Self-Review

- **Spec coverage:** ac6's fleet-wide GC surface (Task 2) over the new list endpoint (Task 1). Push/notification explicitly DEFERRED (Global Constraints, tracked on #454).
- **Reuse:** list endpoint reuses 3b's `is_fresh`/pending; the card deep-links to 3b's Task Detail — no duplicated approval UI.
- **Type consistency:** `PlanAssumptionSummary(task, fresh, pending)` (Kotlin) matches the serve `{task, fresh, pending}`; `list_slugs()` returns `list[str]` consumed by the endpoint.
