# product_assumptions Wave 3a (L4: checker record + cross-check + gate + API) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Spec:** `productassumptionsmd` (approved/implemented) — implements **ac5** (agent-run checker record + deterministic cross-check) and **ac6** (Ground Control flag object + plan→dev gate; the *gate + serve API* half — the phone UI is Wave 3b). · **Issue:** #444 · **Task slug:** `productassumptions-wave-3a` · **Builds on** Wave 1 (`core/plan.py`: SEED_AXES/dispositioned_axes/missing_assumption_axes; `cli/plan.py`: advisory `check-assumptions`) and Wave 2 (`core/assumptions.py`: `AssumptionStore`/`AssumptionRow` with `axes()`/`render()`/`load()` and `triggers`).

**Goal:** Make the "Assumptions checked" header *causal*, not decoration: an external cold checker (run by the agent, recorded by mship) plus a deterministic in-code cross-check produce flags; a plan→dev gate blocks until every flag is signed off by a human. mship never calls an LLM — it emits the checker prompt, records the verdict, cross-checks, and gates.

**Architecture:** New `core/plan_check.py` holds the per-task check result (verdicts + flags), bound to a **plan-content hash** so a plan edit invalidates a stale check. `mship plan assumptions` is a new CLI group: `check --emit` (prints the cold-checker prompt), `result --from-json` (records + runs the deterministic cross-check), `status`, `approve <axis>`. The gate lives in the existing feature plan-gate path (`core/workitem_gate.py` / `core/phase.py::transition`). A serve endpoint exposes pending flags for Wave 3b (Ground Control).

**Tech Stack:** Python 3, Typer, pytest, pydantic, hashlib. No LLM in mship.

## Global Constraints
- **mship NEVER calls an LLM.** `check --emit` only *prints a prompt*; the agent runs it; `result --from-json` only *records*. The deterministic cross-check is pure code.
- **Flags route to the human, never back to the planner.** The gate surfaces flags; it never rewrites the plan or re-prompts the planner.
- **`covered` and `N/A` never flag.** Only `not-covered` verdicts and cross-check contradictions become flags. A flag clears ONLY by explicit human `approve` (silence never passes).
- **Fresh-context checker inputs:** the emitted prompt contains ONLY the original request/spec + the current assumption rows + the finished plan text. NEVER the planner's reasoning trace, journal, or codegraph.
- **Plan-hash staleness:** a check result is bound to `plan_hash(plan_text)`; the gate requires a result whose hash matches the CURRENT plan. Editing the plan ⇒ re-check required (mirrors the finish-evidence-stale gate).
- **Human word is `assumption`;** the CLI group is `plan assumptions`. `disposition` survives only as an internal field value (`covered`/`n-a`/`approved`), never in user-facing text — user-facing verb is **approve**, gate says "N assumptions need sign-off".
- Work in the `productassumptions-wave-3a` mothership worktree; **run only your focused test files, never `mship test`** — the controller runs the full suite.

---

<!-- mship:task id=1 acs=ac5 -->
### Task 1: `PlanCheckStore` + models + `plan_hash`

**Files:** Create `src/mship/core/plan_check.py`; Test `tests/core/test_plan_check.py`

**Interfaces / Produces:**
- `plan_hash(plan_text: str) -> str` — sha256 hex of the plan text with trailing whitespace per line stripped and a single trailing newline (so cosmetic whitespace edits don't churn the hash, but content changes do).
- `AxisVerdict(axis: str, verdict: Literal["covered","not-covered","n-a"], reason: str)` — one checker verdict (pydantic model or frozen dataclass).
- `Flag(axis: str, source: Literal["checker","cross-check"], reason: str, approved: bool = False, approved_by: str | None = None, approved_reason: str | None = None)`.
- `PlanCheckResult(task_slug: str, plan_hash: str, verdicts: list[AxisVerdict], flags: list[Flag])` — pydantic; JSON-serializable.
- `PlanCheckStore(state_dir: Path)` with `save(result) -> Path` (atomic write to `<state_dir>/plan-checks/<task_slug>.json`), `get(task_slug) -> PlanCheckResult | None`, `path(task_slug) -> Path`.
- `flags_from_verdicts(verdicts: list[AxisVerdict]) -> list[Flag]` — one `source="checker"` flag per `not-covered` verdict; `covered`/`n-a` produce none.

- [ ] **Step 1: Failing tests** — `plan_hash` stable across trailing-whitespace-only edits but changes on content edit; `flags_from_verdicts` flags only `not-covered`; `PlanCheckStore` round-trips a result (save→get equal) and `get` on absent → None. (Write the tests with concrete values.)
- [ ] **Step 2: Run → fail.** `uv run pytest tests/core/test_plan_check.py -q`
- [ ] **Step 3: Implement** `src/mship/core/plan_check.py` (atomic write mirrors `core/workitem_store.py`'s tmp+replace).
- [ ] **Step 4: Run → pass.**
- [ ] **Step 5: Commit + `mship journal`** (do NOT run the full suite).
<!-- /mship:task -->

<!-- mship:task id=2 acs=ac5 -->
### Task 2: Deterministic trigger cross-check

**Files:** Modify `src/mship/core/plan_check.py`; Test `tests/core/test_plan_check.py`

**Interfaces / Produces:**
- `cross_check(verdicts: list[AxisVerdict], rows: list[AssumptionRow], *, plan_text: str, task_text: str, affected_repos: list[str]) -> list[Flag]` — pure, no LLM. For each row: if the row's `triggers` MATCH the context (any trigger token found, case-insensitively, in `plan_text` or `task_text`, or matching an `affected_repos` entry) AND the checker's verdict for that axis is `n-a` (i.e. the plan declared it irrelevant while its triggers say it IS relevant), emit a `source="cross-check"` `Flag` explaining the contradiction. Can only ADD flags — never removes checker flags. A missing verdict for a triggered axis is also a contradiction (the plan didn't address a relevant axis).
- Trigger parsing: split a row's `triggers` cell on commas; each token trimmed; a `foo/*` token matches by prefix `foo/`; a plain token matches as a case-insensitive substring / repo-name equality.

- [ ] **Step 1: Failing tests** — a row whose trigger (`git/*`) appears in the plan text but is marked `n-a` → one cross-check flag; a row whose triggers don't match → no flag; a triggered axis with a `covered` verdict → no flag; a triggered axis with NO verdict → flag. Use `AssumptionStore.SEED_ROWS`-style rows.
- [ ] **Step 2–4:** implement + tests pass.
- [ ] **Step 5:** commit + journal.
<!-- /mship:task -->

<!-- mship:task id=3 acs=ac5 -->
### Task 3: `mship plan assumptions check --emit` + `result --from-json`

**Files:** Create `src/mship/cli/plan_assumptions.py` (a `plan assumptions` sub-group); Modify the CLI assembly to register it under `plan` (mirror how `cli/plan.py`'s `check-assumptions` is wired); Test `tests/cli/test_plan_assumptions.py`

**Interfaces:**
- `mship plan assumptions check --emit [--task <slug>] [--plan <path>]` — resolves the plan (via `resolve_plan_path`, Wave 1) and the spec/instruction, and prints the **cold-checker prompt**: a fixed template = the original request/spec text + the rendered current assumption rows (`AssumptionStore(...).render()`) + the finished plan text, plus a one-paragraph instruction to return per-row `{axis, verdict: covered|not-covered|n-a, reason}` JSON, seeing ONLY those inputs. No journal/trace/codegraph. Prints to stdout (pipeable).
- `mship plan assumptions result --from-json <file|-> [--task <slug>] [--plan <path>]` — parses `[{axis, verdict, reason}, …]`, builds `AxisVerdict`s, runs `cross_check(...)` against the store rows + the plan/task/affected-repos, computes `flags = flags_from_verdicts(verdicts) + cross_check(...)`, and saves a `PlanCheckResult` bound to `plan_hash(current plan text)`. Non-TTY JSON envelope `{task, plan_hash, verdicts, flags, pending: <count>}`.

- [ ] **Step 1: Failing tests** — `check --emit` output contains every current axis name AND the finished plan's text AND does NOT contain journal/trace markers; `result --from-json` with a not-covered verdict stores a pending checker flag, and a `n-a` verdict on a triggered axis stores a cross-check flag; the stored `plan_hash` matches the plan. Mirror `tests/cli/test_plan_check_assumptions.py`'s `_app`/`FakeContainer`.
- [ ] **Step 2–4:** implement + tests pass.
- [ ] **Step 5:** commit + journal.
<!-- /mship:task -->

<!-- mship:task id=4 acs=ac6 -->
### Task 4: `mship plan assumptions status` + `approve <axis>`

**Files:** Modify `src/mship/cli/plan_assumptions.py`; Test `tests/cli/test_plan_assumptions.py`

**Interfaces:**
- `mship plan assumptions status [--task] [--plan]` — prints the stored result's verdicts + flags for the task, and whether it is **stale** (stored `plan_hash` ≠ current plan hash) or **absent**. Non-TTY JSON `{task, fresh: bool, pending: <count>, flags:[…]}`.
- `mship plan assumptions approve <axis> [--reason "…"] [--task] [--plan]` — marks the matching pending flag `approved=True` (+ `approved_reason`, `approved_by` from `$USER`/config) and re-saves. Errors (exit 1) if there is no pending flag for that axis. Human sign-off is the ONLY way a flag clears.

- [ ] **Step 1: Failing tests** — `status` reports `fresh=False` when the plan changed after the check; `approve` clears exactly one flag and drops `pending` by one; `approve` on an unknown/covered axis → exit 1.
- [ ] **Step 2–4:** implement + tests pass.
- [ ] **Step 5:** commit + journal.
<!-- /mship:task -->

<!-- mship:task id=5 acs=ac6 -->
### Task 5: plan→dev gate in `phase.transition`

**Files:** Modify `src/mship/core/workitem_gate.py` (and/or `core/phase.py`); Test `tests/cli/test_phase.py` / `tests/core/test_workitem_gate.py`

**Interfaces / Behavior:**
- Extend the FEATURE plan gate that already blocks plan→dev without a plan (`workitem_gate._feature_has_plan` + its caller in `phase.transition`). Add: a feature entering **dev** must also have a `PlanCheckResult` whose `plan_hash` == the current plan's hash (**fresh**) AND **zero pending flags**. Otherwise block with an actionable message:
  - no/stale result → "run `mship plan assumptions check --emit` (agent runs it) then `result --from-json`".
  - pending flags → "N assumptions need sign-off: `mship plan assumptions approve <axis>`" (list the axes).
- Reuse the existing `--hotfix`/bypass parity (this gate must honor the same bypass the plan gate does, e.g. `MSHIP_BYPASS_GATE`/`--force`). Non-feature tasks and non-plan→dev transitions are unaffected.

- [ ] **Step 1: Failing tests** — plan→dev blocked when no check result; blocked when the result is stale; blocked when a flag is pending; PASSES when fresh + all approved; bug/chore tasks unaffected; bypass flag overrides.
- [ ] **Step 2–4:** implement + tests pass.
- [ ] **Step 5:** commit + journal.
<!-- /mship:task -->

<!-- mship:task id=6 acs=ac6 -->
### Task 6: serve API endpoint for pending flags (Ground Control-ready)

**Files:** Modify `src/mship/core/serve.py` (locate the route table / handler pattern — mirror an existing read endpoint); Test the serve test module

**Interfaces:**
- `GET /plan-assumptions/<task_slug>` (name to match serve's existing convention) → JSON `{task, fresh: bool, pending: <count>, flags:[{axis, source, reason, approved}]}` from `PlanCheckStore` + the current plan hash. Read-only; LLM-free; the same envelope `status` prints. This is the contract Wave 3b (Ground Control) consumes — no write/approve endpoint here yet unless the existing serve pattern makes it trivial (approve-over-serve can land with 3b).

- [ ] **Step 1: Failing test** — the endpoint returns the pending-flags envelope for a task with a stored result, and `pending:0`/absent shape when none.
- [ ] **Step 2–4:** implement (mirror an existing serve read route) + test passes.
- [ ] **Step 5:** commit + journal.
<!-- /mship:task -->

---

## Self-Review
- **Spec coverage:** ac5 (checker record + cross-check) → Tasks 1–3. ac6 (gate + GC-facing surface) → Tasks 4 (approve), 5 (gate), 6 (serve API). The Ground Control *phone UI* is Wave 3b (separate slice) — noted for the reviewer.
- **Placeholder scan:** Task 5's exact gate insertion point and Task 6's serve route pattern are located at implementation time (their Step 1 says "locate…/mirror existing"), flagged — not hidden TODOs.
- **Type consistency:** `AxisVerdict`/`Flag`/`PlanCheckResult`/`PlanCheckStore`/`plan_hash`/`flags_from_verdicts`/`cross_check` are defined in Task 1–2 and consumed with the same names/shapes in Tasks 3–6. `cross_check` and the CLI both read rows via Wave 2's `AssumptionStore`. The gate reuses Wave 1's `resolve_plan_path` for the current plan text/hash.
