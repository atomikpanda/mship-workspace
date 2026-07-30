# product_assumptions Wave 5 — L0 (minimal) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Deliver the durable, non-speculative core of L0 — make the metarepo layout a first-class, shared fixture exercised in the dev-phase gate tests, and add a standing canary that fails if the checker ever stops catching the canonical metarepo divergence ("flag rate near zero is a defect").

**Architecture:** Two mothership test-side additions, no product-code change. (1) A shared `metarepo_workspace` fixture in `tests/conftest.py` (consolidating the one that lives locally in `test_scaling_integration.py`), used to add metarepo coverage to the plan→dev gate tests. (2) A canary test that runs the real deterministic checker (`core.plan_check.cross_check` / `flags_from_verdicts`) against a known-bad plan and asserts it flags the ignored assumption.

**Tech Stack:** Python, pytest.

**Spec:** `productassumptionsmd` (approved) — ac8 (metarepo as the default dev-phase test fixture; the import-linter / row-graduation half is DEFERRED, see Global Constraints) and ac9 (the canary; the metrics dashboard is DEFERRED).

## Global Constraints

- **Minimal L0 by explicit decision.** DEFERRED to a later increment (do NOT build here): import-linter + boundary contracts, the row-graduation mechanism, and the health-metrics dashboard (flag-rate/file-size/graduated-count reporting). Rationale: import-linter fits only import-shaped assumptions, several seed rows (e.g. the `undecided` "review surface") can't graduate by any mechanism, so building that machinery now would retire zero rows — the exact over-building this system exists to prevent. A follow-up issue tracks it.
- **No product-code change.** This wave is test-infrastructure only (`tests/`, `conftest.py`). If a test reveals a real product bug, STOP and report it rather than changing product code under this plan.
- **Reuse, don't reinvent.** The metarepo fixture already exists at `tests/test_scaling_integration.py::metarepo_workspace` (~lines 19-89) — promote/consolidate it, don't author a new layout. The checker primitives already exist in `src/mship/core/plan_check.py` (`cross_check`, `flags_from_verdicts`, `AxisVerdict`) and the seed rows in `src/mship/core/assumptions.py` (`SEED_ROWS`).
- **Canary asserts the DETERMINISTIC path** (`cross_check`), which is mship-owned and LLM-free — so the canary is a real regression guard runnable in CI, not dependent on a model.

---

<!-- mship:task id=1 acs=ac8 -->
### Task 1: Shared metarepo fixture + metarepo coverage in the dev-phase gate

**Files:**
- Modify: `tests/conftest.py` (add a shared `metarepo_workspace` fixture)
- Modify: `tests/test_scaling_integration.py` (use the shared fixture instead of its local copy, if it has one — otherwise leave its behavior identical)
- Modify: `tests/test_workitem_gate.py` (add metarepo-layout coverage for the plan→dev gate)

**Interfaces:**
- Produces: a `conftest.py` fixture `metarepo_workspace` (session/function scope matching the existing one) returning the same workspace-root/config shape the local `test_scaling_integration.py::metarepo_workspace` returns today — a genuine multi-repo metarepo layout (independent git roots, tags/dep-types). Read that fixture first and preserve its exact return contract so its own tests keep passing.
- Consumes: existing `WorkspaceConfig`/`RepoConfig`/git-root helpers already used by that fixture.

- [ ] **Step 1: Read the existing fixture and its consumers**

Read `tests/test_scaling_integration.py:19-89` (`metarepo_workspace`) and every test in that file that uses it. Note the exact object it yields (workspace root path, config, repo list) — the shared fixture must yield the same so those tests are unaffected.

- [ ] **Step 2: Write a failing test that consumes the not-yet-shared fixture**

Add to `tests/test_workitem_gate.py`:

```python
def test_feature_plan_gate_passes_with_metarepo_layout(tmp_path, metarepo_workspace):
    """The plan→dev gate must work against the product's core layout (metarepo),
    not only single/2-repo — L0 makes metarepo a first-class dev-phase fixture."""
    # Build an approved feature WorkItem + a valid plan in the metarepo workspace,
    # then assert check_task_gate(..., require_plan=True) is ok. (Mirror the existing
    # _approved_feature + convention-plan helpers, but rooted at the metarepo workspace.)
    ...
```

Run: `uv run pytest tests/test_workitem_gate.py::test_feature_plan_gate_passes_with_metarepo_layout -q`
Expected: FAIL — fixture `metarepo_workspace` not found (it's not in conftest yet).

- [ ] **Step 3: Promote the fixture into `tests/conftest.py`**

Move the `metarepo_workspace` fixture body into `tests/conftest.py` (so it's available to all test modules), and update `tests/test_scaling_integration.py` to consume the conftest fixture (delete its local copy). Keep the yielded contract identical.

- [ ] **Step 4: Flesh out and pass the gate test**

Implement the metarepo gate test from Step 2 using the real gate (`check_task_gate`) + the metarepo workspace root. Reuse the existing `_approved_feature`/plan helpers, rooting paths at the metarepo workspace.

Run: `uv run pytest tests/test_workitem_gate.py tests/test_scaling_integration.py -q`
Expected: PASS (new metarepo gate test + all scaling-integration tests still green on the shared fixture).

- [ ] **Step 5: Commit + journal**

```bash
git add tests/conftest.py tests/test_scaling_integration.py tests/test_workitem_gate.py
git commit -m "test(L0): promote shared metarepo_workspace fixture; exercise plan→dev gate on metarepo"
mship journal "L0: shared metarepo fixture in conftest; plan-dev gate covered on metarepo layout" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 acs=ac9 -->
### Task 2: The canary — checker must catch the metarepo divergence

**Files:**
- Create: `tests/core/test_assumptions_canary.py`

**Interfaces:**
- Consumes: `mship.core.plan_check.cross_check`, `mship.core.plan_check.flags_from_verdicts`, `mship.core.plan_check.AxisVerdict`, `mship.core.assumptions.SEED_ROWS`.

- [ ] **Step 1: Write the canary tests (they should pass immediately against the working checker — the canary FAILS only if the checker regresses)**

```python
# tests/core/test_assumptions_canary.py
"""L0 canary (ac9): 'a flag rate near zero is a defect'. A known-bad plan — the
canonical failure this whole system exists to catch: a git feature designed
considering only single-repo / monorepo, with metarepo (the product's core
divergence) ignored — MUST still be flagged. If the seed rows or the deterministic
cross-check ever regress so this passes silently, these tests fail loudly."""
from mship.core.assumptions import SEED_ROWS
from mship.core.plan_check import AxisVerdict, cross_check, flags_from_verdicts

# A plan whose text triggers the repo-topology axis (mentions git/clone) but whose
# disposition wrongly declares it n/a — the metarepo option was never considered.
_KNOWN_BAD_PLAN = (
    "# Plan\n\nAdd a git clone step and handle the single-repo and monorepo layouts.\n"
)


def test_canary_cross_check_flags_ignored_metarepo_divergence():
    rows = list(SEED_ROWS)
    verdicts = [AxisVerdict(axis="repo topology", verdict="n-a",
                            reason="only single/mono considered")]
    flags = cross_check(verdicts, rows, plan_text=_KNOWN_BAD_PLAN, task_text="", affected_repos=[])
    assert any(f.axis == "repo topology" for f in flags), (
        "CANARY TRIPPED: the deterministic cross-check no longer flags the metarepo "
        "divergence — the flag rate has gone to zero, which is a defect (#444 ac9)."
    )


def test_canary_completeness_flags_omitted_row():
    """A plan the checker returns NO verdict for a seed row on must still flag that
    row (completeness) — a silent omission cannot pass."""
    rows = list(SEED_ROWS)
    flags = flags_from_verdicts([], rows)  # checker returned nothing
    assert flags, "CANARY TRIPPED: an all-omitted verdict set produced zero flags."
    assert {f.axis for f in flags} >= {r.axis for r in SEED_ROWS}, (
        "CANARY TRIPPED: not every un-dispositioned seed row was flagged."
    )
```

- [ ] **Step 2: Run to verify they pass against the current (working) checker**

Run: `uv run pytest tests/core/test_assumptions_canary.py -q`
Expected: PASS (the checker currently catches the canary; these guard against future regression).

- [ ] **Step 3: Sanity-check the canary actually bites (manual, do not commit)**

Temporarily confirm the first canary FAILS if you neuter the trigger (e.g. locally blank the repo-topology row's triggers) — verifying it's a real guard, then revert. This is a one-off check, not a committed test.

- [ ] **Step 4: Commit + journal**

```bash
git add tests/core/test_assumptions_canary.py
git commit -m "test(L0): canary — checker must keep flagging the metarepo divergence (ac9)"
mship journal "L0: added assumptions canary (cross-check + completeness) guarding flag-rate-not-zero" --action committed
```
<!-- /mship:task -->

## Self-Review

- **Spec coverage:** ac8's *metarepo-as-fixture* half (Task 1) + ac9's *canary* (Task 2). The import-linter/graduation half of ac8 and the metrics-dashboard half of ac9 are DEFERRED by explicit decision (Global Constraints) — a follow-up issue will track them.
- **No product change:** both tasks are `tests/` only; the canary reuses real checker primitives so it genuinely guards the shipped behavior.
- **Type consistency:** `cross_check(verdicts, rows, *, plan_text, task_text, affected_repos)` and `flags_from_verdicts(verdicts, rows)` match their `core/plan_check.py` signatures; `AxisVerdict(axis, verdict, reason)` matches.
