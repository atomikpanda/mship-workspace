# product_assumptions.md — Implementation Plan (v1: Backtest gate + Wave 1 / L3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `productassumptionsmd` (approved) · **Issue:** atomikpanda/mothership#444 · **Task slug:** `productassumptionsmd`

**Goal:** Validate — before building product code — that a cold assumption-coverage checker actually catches the failure it claims to (backtest), then ship L3: the plan-template "Assumptions checked" disposition-all header plus a coverage validator that marks a plan omitting any current assumption as not well-formed.

**Architecture:** The system is six layers (L0–L5) gated on a retrospective backtest. This plan covers **only the backtest (AC-0, the gate) and Wave 1 / L3** in full; Waves 2–5 are skeletoned and expanded *after* the backtest's three numbers come back acceptable — the spec forbids building downstream until then. L3 reuses the existing plan-validity seam in `core/plan.py` (`plan_has_tasks`, consumed by `workitem_gate._feature_has_plan`): a new pure coverage validator sits beside it, checked against a hardcoded `SEED_AXES` constant that Wave 2's L1 store later supersedes. The same 7 seed axes drive both the backtest corpus and the Wave 1 validator — one source, two consumers.

**Tech Stack:** Python 3, mship CLI (Typer), pytest. Markdown-canonical plan/spec artifacts. No LLM in mship core — the backtest checker is run by an agent, not by mship.

## Global Constraints

- **The backtest (Task 1) gates everything.** No Wave 1+ product code is merged until Task 1's report shows acceptable numbers — **precision (low false-flag rate) prioritized over recall.** If the numbers are bad, stop and revise the approach, don't build L1–L5.
- **`SEED_AXES` is the single source of the 7 seed assumptions** (repo topology, credential locus, execution locus, state durability, review surface, agent stream, dispatched model). The backtest hand-writes them; Wave 1 imports them; Wave 2's L1 store replaces the constant. Never restate the list in a second place.
- **Human-facing word is `assumption`; schema field is `axis`.** `options` is the load-bearing column (contrastive enumeration), not `position`.
- **`triggers` is never an injection filter** — it exists only for L4's deterministic cross-check.
- **Divergences only** — the assumptions file/rows record only where mship contradicts a model's default; never restate what the repo already documents.
- **mship never calls an LLM itself.** The L4 checker (Wave 3) is agent-run; mship records + cross-checks + gates.
- **markdown, not JSON**, for the disposition header — enumeration is the goal; structured serialization collapses diversity.
- Work happens in the task worktree `.worktrees/productassumptionsmd/mothership/`; paths below are repo-relative. Ground Control is untouched until Wave 3.

## Assumptions checked
*(Dogfooding L3 — this plan dispositions every current seed assumption before naming its approach.)*
- repo topology — **metarepo**; this plan modifies `mothership` only in v1, but the assumptions store (Wave 2) is workspace-journal-scoped precisely because a metarepo has no canonical repo, and the enrollment-repo read-only projection is an explicit Wave 2 task.
- credential locus — **N/A**; no credential handling in the backtest or L3.
- execution locus — **both**; L3's validator and CLI run identically locally and on a disposable cloud worker (pure functions + a CLI over workspace files).
- state durability — **journal**; the assumptions store (Wave 2) lives in the durable workspace journal/state dir, not in-session. L3 itself is stateless.
- review surface — **undecided (flagged)**; L4's flag object (Wave 3) must surface on the async phone client, but the terminal-vs-phone product boundary (D1) stays an `undecided` row, not resolved here.
- agent stream — **journal-backed**; the backtest reads journaled/on-disk plans, not a live stream.
- dispatched model — **assume weaker**; L3's disposition-all header is a copy-and-disposition task chosen specifically because weaker dispatched models do it reliably.

---

<!-- mship:task id=1 acs=ac1 -->
### Task 1: Backtest — cold assumption-coverage checker vs. our own plan corpus (AC-0, THE GATE)

**Ships no product code.** Deliverable is a committed report; its numbers decide whether Waves 1–5 proceed.

**Files:**
- Create: `docs/plans/backtest/2026-07-29-assumption-checker-backtest.md` (the report)
- Create: `docs/plans/backtest/seed-axes.md` (the 7 hand-written rows used for the run — the human-authored source the later `SEED_AXES` constant mirrors)
- Read-only: `docs/plans/*.md` (accepted corpus), git history of `docs/plans/*.md` + `specs/*.md` (rejected/revised corpus), per-task journals under the workspace state dir (`mship journal` / `core/log.py` logs), `mship spec` review verdicts.

**Interfaces:**
- Produces: `SEED_ROWS` (7 rows, markdown table `axis | options | position | triggers`) reused verbatim by Task 2's `SEED_AXES`; and three headline numbers (recall, false-flag rate, header-vs-body consistency) that Global Constraints gate on.

- [ ] **Step 1: Assemble the corpus.** Enumerate the plan population and split it:
  - *Accepted plans*: the current `docs/plans/*.md` that shipped (merged PRs).
  - *Rejected plans*: plans/specs that were rejected or substantially rewritten at review. Source them, in priority order: (a) `mship spec` histories with a `request-changes` verdict; (b) git history of `docs/plans/*.md` where a plan was materially rewritten after first commit; (c) the known metarepo failure from #444 as a labeled canary.
  - Write the enumerated corpus (paths + accepted/rejected label + how the label was derived) into the report. **If the rejected corpus is thin, that is itself a finding** — record it; it may justify a small journaling change so rejections are first-class (candidate follow-up issue), but do not build that here.

- [ ] **Step 2: Hand-write the 7 seed rows** into `docs/plans/backtest/seed-axes.md` using the exact `axis | options | position | triggers` schema and the seven axes from Global Constraints. `options` must list the real alternatives (contrastive), not just the position.

- [ ] **Step 3: Define the cold-checker prompt.** Write, into the report, the exact prompt a fresh sub-agent will run per plan. Inputs it sees: **only** the original request/spec + the full 7-row set + the finished plan. It must NOT see the planner's reasoning, this backtest's labels, or codebase exploration. Output: per row, `covered / not-covered / N-A` + one line of reason. Closed-form recognition over the fixed list — not open critique.

- [ ] **Step 4: Run the checker cold over every corpus plan.** For each plan, dispatch a fresh sub-agent with the Step-3 prompt (blind to the accept/reject label). Record the per-row verdicts in a results table in the report.

- [ ] **Step 5: Compute the three numbers.**
  - **Recall** = of plans we rejected, the fraction the checker flags (any not-covered on a row that plausibly mattered).
  - **False-flag rate** = of plans we accepted, the fraction the checker wrongly flags. *This is the number that matters most.*
  - **Header-vs-body consistency** = for plans that already state a per-row position, does the plan body actually do that? (the F_ID/F_Strong analogue; measurable on existing plans). Report all three with the raw counts.

- [ ] **Step 6: Write the verdict + go/no-go.** State plainly whether the numbers clear (precision-first). Include: which rejected plans the checker missed (recall gaps) and which accepted plans it false-flagged (with why). If no-go, propose what to change before Wave 1. If go, note any seed-row edits the run surfaced.

- [ ] **Step 7: Commit + journal.**
```bash
git add docs/plans/backtest/
git commit -m "docs(backtest): assumption-checker retrospective — recall/false-flag/consistency"
mship journal "ran AC-0 assumption-checker backtest; 3 numbers recorded; go/no-go = <...>" --action committed
```

**GATE CHECK:** Do not start Task 2+ until Step 6's verdict is go. If no-go, return to the operator with the report.
<!-- /mship:task -->

<!-- mship:task id=2 acs=ac2 -->
### Task 2: Seed axes + "Assumptions checked" block parser

**Files:**
- Modify: `src/mship/core/plan.py` (add `SEED_AXES`, `dispositioned_axes`)
- Test: `tests/core/test_plan.py`

**Interfaces:**
- Produces:
  - `SEED_AXES: tuple[str, ...]` — the 7 seed axis names (canonical lowercase), single source of truth for Wave 1 (Wave 2's L1 store supersedes it).
  - `dispositioned_axes(plan_text: str) -> set[str]` — the set of axis names a plan's "Assumptions checked" block dispositions, normalized (lowercased, whitespace-collapsed). Empty set if there is no block.
- Consumes: nothing.

- [ ] **Step 1: Write the failing test.**
```python
# tests/core/test_plan.py
from mship.core.plan import dispositioned_axes, SEED_AXES

def test_dispositioned_axes_parses_block_with_em_dash_and_hyphen():
    plan = (
        "## Assumptions checked\n"
        "- repo topology — metarepo; covers clone across N repos\n"
        "- credential locus - N/A, no credential handling\n"
        "- execution locus -- cloud worker\n\n"
        "## Approach\nsomething\n"
    )
    assert dispositioned_axes(plan) == {"repo topology", "credential locus", "execution locus"}

def test_dispositioned_axes_no_block_returns_empty():
    assert dispositioned_axes("## Approach\nno assumptions block here\n") == set()

def test_dispositioned_axes_normalizes_case_and_whitespace():
    plan = "## Assumptions Checked\n- Repo   Topology — meta\n"
    assert dispositioned_axes(plan) == {"repo topology"}

def test_seed_axes_has_seven_including_repo_topology():
    assert len(SEED_AXES) == 7
    assert "repo topology" in SEED_AXES
```

- [ ] **Step 2: Run to verify it fails.**
Run: `mship test --repo mothership -- tests/core/test_plan.py -k dispositioned_axes -v` (or `pytest tests/core/test_plan.py -k dispositioned -v` inside the worktree)
Expected: FAIL — `ImportError: cannot import name 'dispositioned_axes'`.

- [ ] **Step 3: Implement.**
```python
# src/mship/core/plan.py  (add near the other module-level helpers)

# The 7 seed assumptions (issue #444). Canonical lowercase axis names.
# SINGLE SOURCE for Wave 1; Wave 2's L1 store supersedes this constant.
SEED_AXES: tuple[str, ...] = (
    "repo topology",
    "credential locus",
    "execution locus",
    "state durability",
    "review surface",
    "agent stream",
    "dispatched model",
)

# "## Assumptions checked" (any case), then consecutive "- <axis> <sep> <disposition>"
# bullet lines. Separator is an em-dash or one/two hyphens. Axis = text before the
# first separator, normalized (lowercased, internal whitespace collapsed).
_ASSUMPTIONS_HEADING_RE = re.compile(r"^#{1,6}\s+assumptions\s+checked\s*$", re.IGNORECASE | re.MULTILINE)
_ASSUMPTION_ROW_RE = re.compile(r"^\s*[-*]\s+(?P<axis>.+?)\s*(?:—|--|-)\s+\S", re.MULTILINE)


def _normalize_axis(raw: str) -> str:
    return " ".join(raw.strip().lower().split())


def dispositioned_axes(plan_text: str) -> set[str]:
    """Axis names dispositioned in the plan's 'Assumptions checked' block.

    Returns the normalized axis name of each bullet row under the first
    '## Assumptions checked' heading, up to the next heading. Empty set when
    there is no such block (an unchecked plan)."""
    m = _ASSUMPTIONS_HEADING_RE.search(plan_text)
    if m is None:
        return set()
    rest = plan_text[m.end():]
    next_heading = re.search(r"^#{1,6}\s+\S", rest, re.MULTILINE)
    block = rest[: next_heading.start()] if next_heading else rest
    return {_normalize_axis(row.group("axis")) for row in _ASSUMPTION_ROW_RE.finditer(block)}
```

- [ ] **Step 4: Run to verify it passes.**
Run: `pytest tests/core/test_plan.py -k "dispositioned or seed_axes" -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit + journal.**
```bash
git add src/mship/core/plan.py tests/core/test_plan.py
git commit -m "feat(plan): parse the Assumptions-checked block + seed axes"
mship journal "L3: assumptions-block parser + SEED_AXES" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 acs=ac2 -->
### Task 3: Coverage validator — which current assumptions a plan omits

**Files:**
- Modify: `src/mship/core/plan.py` (add `missing_assumption_axes`)
- Test: `tests/core/test_plan.py`

**Interfaces:**
- Consumes: `dispositioned_axes` (Task 2).
- Produces: `missing_assumption_axes(plan_text: str, expected_axes: Iterable[str]) -> list[str]` — expected axes (normalized) NOT dispositioned by the plan, in `expected_axes` order. Empty list ⇒ the plan is well-formed w.r.t. assumption coverage. `expected_axes` is a parameter (not hardcoded) so Wave 2's store can supply the live set; Wave 1 callers pass `SEED_AXES`.

- [ ] **Step 1: Write the failing test.**
```python
# tests/core/test_plan.py
from mship.core.plan import missing_assumption_axes, SEED_AXES

_FULL_BLOCK = "## Assumptions checked\n" + "".join(
    f"- {a} — disposition line\n" for a in SEED_AXES
)

def test_missing_none_when_all_dispositioned():
    assert missing_assumption_axes(_FULL_BLOCK, SEED_AXES) == []

def test_missing_lists_omitted_axis_in_expected_order():
    partial = "## Assumptions checked\n- repo topology — meta\n- execution locus — cloud\n"
    missing = missing_assumption_axes(partial, SEED_AXES)
    assert "credential locus" in missing
    assert missing == [a for a in SEED_AXES if a not in {"repo topology", "execution locus"}]

def test_na_disposition_counts_as_covered():
    block = "## Assumptions checked\n" + "".join(f"- {a} — N/A\n" for a in SEED_AXES)
    assert missing_assumption_axes(block, SEED_AXES) == []

def test_no_block_reports_all_expected_missing():
    assert missing_assumption_axes("## Approach\nx\n", SEED_AXES) == list(SEED_AXES)
```

- [ ] **Step 2: Run to verify it fails.**
Run: `pytest tests/core/test_plan.py -k missing_assumption -v`
Expected: FAIL — `ImportError: cannot import name 'missing_assumption_axes'`.

- [ ] **Step 3: Implement.**
```python
# src/mship/core/plan.py
from typing import Iterable

def missing_assumption_axes(plan_text: str, expected_axes: Iterable[str]) -> list[str]:
    """Expected assumption axes the plan does NOT disposition, in expected order.

    N/A counts as dispositioned (an explicit N/A IS a disposition — that is the
    HAZOP discipline). Empty list ⇒ well-formed. `expected_axes` is injected so
    the live source (Wave 1: SEED_AXES; Wave 2: the L1 store) is the caller's
    choice, not baked in here."""
    covered = dispositioned_axes(plan_text)
    return [a for a in (_normalize_axis(x) for x in expected_axes) if a not in covered]
```

- [ ] **Step 4: Run to verify it passes.**
Run: `pytest tests/core/test_plan.py -k missing_assumption -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit + journal.**
```bash
git add src/mship/core/plan.py tests/core/test_plan.py
git commit -m "feat(plan): coverage validator for the Assumptions-checked block"
mship journal "L3: missing_assumption_axes validator" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 acs=ac2 -->
### Task 4: `mship plan check-assumptions` CLI + plan-template convention (advisory in Wave 1)

Surfaces the validator so a planner (human or agent) sees uncovered assumptions. **Advisory only in Wave 1** — the hard plan→dev block is L4 (Wave 3), so this task must NOT wire a blocking gate into `phase.transition` (that would break every in-flight feature plan before the store/checker exist).

**Files:**
- Create: `src/mship/cli/plan.py` (a `plan` command group, mirroring `cli/spec.py`'s `register(app, container_factory)` pattern)
- Modify: the CLI app assembly that registers command groups (follow how `cli/spec.py` is registered — locate its `register(` call site and add `plan`'s alongside it)
- Test: `tests/cli/test_plan_check_assumptions.py`
- Doc: `src/mship/skills/writing-plans/SKILL.md` (add the "Assumptions checked" block to the plan header convention) and the plan Task template note.

**Interfaces:**
- Consumes: `resolve_plan_path`, `missing_assumption_axes`, `SEED_AXES` (`core/plan.py`).
- Produces: `mship plan check-assumptions [--task <slug>] [--plan <path>]` → JSON `{ "plan": <path>, "expected": [...], "missing": [...], "ok": bool }` on stdout (non-TTY), human summary on TTY. Exit 0 always in Wave 1 (advisory); Wave 3 flips missing→non-zero at the gate, not here.

- [ ] **Step 1: Write the failing test.**
```python
# tests/cli/test_plan_check_assumptions.py
import json
from pathlib import Path
import typer
from typer.testing import CliRunner

def _app(tmp_path):
    from mship.cli.plan import register
    class FakeContainer:
        def config_path(self): return str(tmp_path / "mothership.yaml")
    app = typer.Typer(); register(app, lambda: FakeContainer()); return app

def test_check_assumptions_reports_missing(tmp_path):
    plans = tmp_path / "docs" / "plans"; plans.mkdir(parents=True)
    (plans / "2026-07-29-x.md").write_text(
        "## Assumptions checked\n- repo topology — meta\n"
    )
    runner = CliRunner()
    res = runner.invoke(_app(tmp_path), ["plan", "check-assumptions", "--plan", str(plans / "2026-07-29-x.md")])
    assert res.exit_code == 0, res.output
    data = json.loads(res.output)
    assert data["ok"] is False
    assert "credential locus" in data["missing"]
    assert "repo topology" not in data["missing"]

def test_check_assumptions_ok_when_all_covered(tmp_path):
    from mship.core.plan import SEED_AXES
    plans = tmp_path / "docs" / "plans"; plans.mkdir(parents=True)
    body = "## Assumptions checked\n" + "".join(f"- {a} — ok\n" for a in SEED_AXES)
    (plans / "2026-07-29-y.md").write_text(body)
    runner = CliRunner()
    res = runner.invoke(_app(tmp_path), ["plan", "check-assumptions", "--plan", str(plans / "2026-07-29-y.md")])
    data = json.loads(res.output)
    assert data["ok"] is True and data["missing"] == []
```

- [ ] **Step 2: Run to verify it fails.**
Run: `pytest tests/cli/test_plan_check_assumptions.py -v`
Expected: FAIL — no `mship.cli.plan` module.

- [ ] **Step 3: Implement** the `plan` group + `check-assumptions` command. Resolve the plan via `--plan` (workspace-relative, through `resolve_plan_path`'s escape checks) or `--task` (via `resolve_plan_path(slug, None, workspace_root, docs_dir)`); compute `missing = missing_assumption_axes(text, SEED_AXES)`; emit the JSON envelope (non-TTY) / rich summary (TTY), always exit 0. Mirror `cli/spec.py` for container/config-path plumbing and the TTY-vs-JSON split.

- [ ] **Step 4: Run to verify it passes.**
Run: `pytest tests/cli/test_plan_check_assumptions.py -v`
Expected: PASS (2 tests).

- [ ] **Step 5: Document the convention.** In `writing-plans/SKILL.md`, add the `## Assumptions checked` block to the plan-header template (disposition every current assumption — `covered`/`N/A` + one line — before the approach), and note `mship plan check-assumptions` as the self-check. Keep it short; point at the store as the future source of the axis list.

- [ ] **Step 6: Full suite + commit + journal.**
```bash
mship test --repo mothership
git add src/mship/cli/plan.py tests/cli/test_plan_check_assumptions.py src/mship/skills/writing-plans/SKILL.md
git commit -m "feat(plan): mship plan check-assumptions (advisory) + writing-plans convention"
mship journal "L3: check-assumptions CLI + plan-template convention (advisory)" --action committed
```
<!-- /mship:task -->

---

## Waves 2–5 — skeleton (expand AFTER Task 1's gate clears)

These are intentionally NOT yet broken into TDD steps. The backtest may reshape L4/L5, and L1's storage detail depends on confirming the workspace journal/state-dir layout. Each becomes its own set of `mship:task` blocks in a plan revision once Task 1 is go.

<!-- mship:task id=5 acs=ac3,ac4 -->
### Task 5 (Wave 2 / L1+L2): assumptions store + late injection — SKELETON
- **L1 store:** a workspace-scoped, markdown-canonical assumptions store in the workspace journal/state dir (mirror `WorkItemStore`/`SpecStore`: one artifact, atomic write, flock). Schema per row: `axis`, `options`, `position`, `triggers`. Soft cap ~20. Seed it with the 7 rows. Read-only projection into enrollment repos.
- **CLI:** `mship assumptions list | add | edit` (human word: "assumption").
- **Swap the source of truth:** `SEED_AXES` (Task 2) → the store; Task 3/4 callers now pass the store's axes. Delete the constant's role as source (keep only if still the seed importer).
- **L2 injection:** render all rows, unfiltered, adjacent to plan generation (into the plan bundle / `mship export` for the plan phase, or the writing-plans context) — NOT at session start, NO trigger filter path.
- Expansion notes: confirm the exact state-dir path convention (see `core/log.py`, `core/reconcile/cache.py` `state_dir`); decide the enrollment-repo projection mechanism (generated read-only file vs. `mship` read command).
<!-- /mship:task -->

<!-- mship:task id=6 acs=ac5,ac6 -->
### Task 6 (Wave 3 / L4): agent-run checker record + deterministic cross-check + GC flag + gate — SKELETON
- **Record path:** `mship plan check-result --from-json` records the fresh sub-agent's per-row `covered/not-covered/N-A` + reason. mship stores it; never calls the model.
- **Deterministic trigger cross-check (in code, no model):** flag contradictions like *plan touches `git/*` but marked repo-topology N/A*, using the row `triggers` + the plan/task text + enrolled repos. Can only ADD flags.
- **Ground Control flag object** (ground-control repo): surface flags as a dispositionable object on the async client; "3 unchecked assumptions" phrasing.
- **Gate:** `phase.transition` (`core/phase.py`) blocks plan→dev until every flag is dispositioned — not-covered + explicit human approval passes; not-covered + silence blocks. Flip Task 4's advisory CLI to feed this gate. Flags route to the human, never back to the planner.
- Expansion notes: reuse the `_gate_*` pattern in `core/phase.py`; model the flag object on the spec question/verdict card if that fits; keep `--hotfix` bypass parity.
<!-- /mship:task -->

<!-- mship:task id=7 acs=ac7 -->
### Task 7 (Wave 4 / L5): rejection → row ratchet — SKELETON
- On plan/spec rejection at review (`mship spec request-changes` path), prompt for one line on *why* → append as a new assumption row via the L1 store. The only mechanism that finds blind-spot assumptions.
<!-- /mship:task -->

<!-- mship:task id=8 acs=ac8,ac9 -->
### Task 8 (Wave 5 / L0): metarepo fixtures + import-linter + health metrics — SKELETON
- Metarepo as the default workspace fixture in dev-phase test paths; `import-linter` boundary contracts; enable rows to graduate file→fixtures (file size trends down).
- Health metrics observable: flag rate (near-zero = defect, feed a known-bad canary), header-vs-body consistency (stays high), rows graduated (up), file size (down).
<!-- /mship:task -->

---

## Self-Review

- **Spec coverage:** ac1→Task 1 (full). ac2→Tasks 2–4 (full). ac3,ac4→Task 5 (skeleton). ac5,ac6→Task 6 (skeleton). ac7→Task 7 (skeleton). ac8,ac9→Task 8 (skeleton). Every AC maps to a task; downstream ACs are deliberately skeletoned per the approved "backtest + Wave 1" plan scope and the spec's own gate.
- **Placeholder scan:** Tasks 1–4 carry real code/tests/commands. "SKELETON" tasks are explicitly labeled as deferred expansions, not hidden TODOs — the gate makes premature detail wrong.
- **Type consistency:** `dispositioned_axes(str)->set[str]`, `missing_assumption_axes(str, Iterable[str])->list[str]`, `SEED_AXES: tuple[str,...]` used consistently across Tasks 2→3→4. `_normalize_axis` shared by both parser and validator. CLI consumes exactly those names.
