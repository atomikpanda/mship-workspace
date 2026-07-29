# mship finish Requires Test Evidence by Default — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `mship-finish-requires-test-evidence-by` (approved 2026-07-29)

**Goal:** Flip `mship finish` so it *blocks* (not warns) when a task has no passing test evidence, with `--no-require-tests` as the explicit opt-out and a config-declared no-test-target exemption.

**Architecture:** Extract the current inline block/warn logic at `worktree.py:1446-1491` into a pure decision function in `core/test_evidence.py` (`decide_finish_gate`) so the three outcomes (block, waive, warn-no-target) plus pass are unit-testable in isolation. The CLI computes inputs (evidence map, config-exempt repos, opt-out flag), calls the function, and formats the messages. `--require-tests` becomes a hidden deprecated no-op mirroring `--stub`.

**Tech Stack:** Python 3.12, Typer CLI, pytest, Pydantic config models.

## Global Constraints

- **Affected repo:** `mothership` only.
- **Evidence definition is unchanged** — a passing `mship test` iteration for the task (`task.test_results` / journal `test_state=pass`), exactly as `read_evidence` computes today. Do not redefine what counts as evidence.
- **No-test-target exemption is config-declared only** — a repo is exempt iff `"test" in repo.not_applicable`. An accidentally-missing `test` target (no Taskfile entry, not declared `not_applicable`) is **not** exempt and still blocks — this deliberately surfaces the misconfig (spec risk note).
- **`--no-require-tests` is a legitimate flag, NOT bypass-logged** — do not write a `.mothership/bypass-log.jsonl` entry for it (spec non-goal). It only prints a plain waiver line.
- **Scope of the gate is unchanged** — only `mship finish`. Do not touch `mship commit` or `mship close` (spec non-goals).
- **Warning/waiver text must NAME repos** — exempted repos and evidence-missing repos are named explicitly so silence never reads as coverage (spec risk note).

---

<!-- mship:task id=1 acs=ac1,ac2,ac6 -->
### Task 1: Pure `decide_finish_gate` decision function

**Files:**
- Modify: `src/mship/core/test_evidence.py` (append the decision function + result dataclass)
- Test: `tests/core/test_test_evidence.py` (add a test class; create the file if it doesn't exist)

**Interfaces:**
- Consumes: `RepoEvidence` (already defined in `test_evidence.py`, `.status` in `{"passed","failed","stale","missing"}`); the per-repo evidence map returned by `read_evidence`.
- Produces:
  ```python
  @dataclass(frozen=True)
  class FinishGateDecision:
      action: Literal["pass", "block", "waive", "warn_no_target"]
      missing_repos: list[str]   # expectable repos lacking PASSING evidence (sorted)
      exempt_repos: list[str]    # repos with no configured test target (sorted)

  def decide_finish_gate(
      evidence: dict[str, RepoEvidence],
      exempt_repos: set[str],
      opt_out: bool,
  ) -> FinishGateDecision: ...
  ```
  Rules (evaluated in order):
  1. `expectable = evidence.keys() - exempt_repos`. If `expectable` is empty → `warn_no_target` (every touched repo is exempt; never block).
  2. `missing = {r in expectable : evidence[r].status != "passed"}`. If `missing` empty → `pass`.
  3. `missing` non-empty and `opt_out` → `waive`.
  4. `missing` non-empty and not `opt_out` → `block`.
  In every case `missing_repos` = sorted list of expectable repos not passing; `exempt_repos` = sorted `exempt_repos` argument.

- [ ] **Step 1: Write the failing tests**

```python
# tests/core/test_test_evidence.py
from mship.core.test_evidence import RepoEvidence, decide_finish_gate


def _ev(status):
    return RepoEvidence(status=status, source="test_results", at=None)


def test_blocks_when_expectable_repo_missing_and_not_opted_out():
    d = decide_finish_gate({"api": _ev("missing")}, exempt_repos=set(), opt_out=False)
    assert d.action == "block"
    assert d.missing_repos == ["api"]


def test_passes_when_all_expectable_repos_passing():
    d = decide_finish_gate({"api": _ev("passed")}, exempt_repos=set(), opt_out=False)
    assert d.action == "pass"
    assert d.missing_repos == []


def test_waives_when_opted_out_with_missing_evidence():
    d = decide_finish_gate({"api": _ev("missing")}, exempt_repos=set(), opt_out=True)
    assert d.action == "waive"
    assert d.missing_repos == ["api"]


def test_warns_when_every_touched_repo_is_exempt():
    d = decide_finish_gate({"docs": _ev("missing")}, exempt_repos={"docs"}, opt_out=False)
    assert d.action == "warn_no_target"
    assert d.exempt_repos == ["docs"]


def test_mixed_blocks_on_expectable_and_names_exempt():
    d = decide_finish_gate(
        {"api": _ev("missing"), "docs": _ev("missing")},
        exempt_repos={"docs"},
        opt_out=False,
    )
    assert d.action == "block"
    assert d.missing_repos == ["api"]
    assert d.exempt_repos == ["docs"]


def test_stale_counts_as_missing():
    d = decide_finish_gate({"api": _ev("stale")}, exempt_repos=set(), opt_out=False)
    assert d.action == "block"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mothership && uv run pytest tests/core/test_test_evidence.py -v`
Expected: FAIL with `ImportError: cannot import name 'decide_finish_gate'`

- [ ] **Step 3: Implement the decision function**

```python
# Append to src/mship/core/test_evidence.py

from dataclasses import dataclass  # add to existing imports if not present


@dataclass(frozen=True)
class FinishGateDecision:
    action: Literal["pass", "block", "waive", "warn_no_target"]
    missing_repos: list[str]
    exempt_repos: list[str]


def decide_finish_gate(
    evidence: dict[str, RepoEvidence],
    exempt_repos: set[str],
    opt_out: bool,
) -> FinishGateDecision:
    """Decide the finish test-evidence gate outcome (pure — no I/O).

    `evidence` maps each finish-touched repo to its RepoEvidence. `exempt_repos`
    are repos with no configured `test` target (`"test" in repo.not_applicable`),
    which cannot produce evidence and never block. `opt_out` is `--no-require-tests`.
    """
    exempt_sorted = sorted(exempt_repos)
    expectable = set(evidence) - exempt_repos
    missing = sorted(r for r in expectable if evidence[r].status != "passed")
    if not expectable:
        return FinishGateDecision("warn_no_target", missing, exempt_sorted)
    if not missing:
        return FinishGateDecision("pass", missing, exempt_sorted)
    action = "waive" if opt_out else "block"
    return FinishGateDecision(action, missing, exempt_sorted)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd mothership && uv run pytest tests/core/test_test_evidence.py -v`
Expected: PASS (all 6)

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/test_evidence.py tests/core/test_test_evidence.py
git commit -m "feat(finish): pure decide_finish_gate decision function (ac1,ac2,ac6)"
mship journal "added decide_finish_gate pure function; 6 unit tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 acs=ac1,ac2,ac3 -->
### Task 2: Wire the gate into `mship finish` + flag changes

**Files:**
- Modify: `src/mship/cli/worktree.py:1027-1032` (flag definitions), `:1446-1491` (gate call site)
- Test: `tests/test_finish_integration.py` (add block/waive/warn cases; follow existing finish-integration fixtures)

**Interfaces:**
- Consumes: `decide_finish_gate`, `FinishGateDecision` from Task 1; `read_evidence` (existing); `config.repos[name].not_applicable` (existing `RepoConfig` field).
- Produces: new `--no-require-tests` boolean option (default `False`); `--require-tests` becomes a hidden deprecated no-op.

- [ ] **Step 1: Write the failing integration tests**

Add to `tests/test_finish_integration.py`, mirroring the existing finish fixtures in that file (reuse whatever workspace/task builder the neighboring tests use — do not invent a new one):

```python
def test_finish_blocks_by_default_without_evidence(finish_workspace):
    # finish_workspace: a task with commits to push, a configured `test` target,
    # and NO recorded passing evidence.
    result = run_finish(finish_workspace, args=[])
    assert result.exit_code == 1
    assert "Test evidence missing" in result.stderr
    assert "--no-require-tests" in result.stderr  # opt-out is advertised


def test_finish_proceeds_with_no_require_tests_and_prints_waiver(finish_workspace):
    result = run_finish(finish_workspace, args=["--no-require-tests"])
    assert result.exit_code == 0
    assert "evidence gate waived" in result.stdout.lower()


def test_finish_warns_not_blocks_when_test_target_not_applicable(docs_only_workspace):
    # docs_only_workspace: touched repo declares `not_applicable: [test]`.
    result = run_finish(docs_only_workspace, args=[])
    assert result.exit_code == 0
    assert "no test target" in result.stdout.lower()  # names the exempt repo


def test_require_tests_flag_is_deprecated_noop(finish_workspace_with_evidence):
    result = run_finish(finish_workspace_with_evidence, args=["--require-tests"])
    assert result.exit_code == 0
    assert "--require-tests is deprecated" in result.stderr
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mothership && uv run pytest tests/test_finish_integration.py -k "block_by_default or no_require_tests or not_applicable or deprecated_noop" -v`
Expected: FAIL (default currently only warns; `--no-require-tests` flag doesn't exist)

- [ ] **Step 3: Replace the flag definitions**

At `src/mship/cli/worktree.py:1027-1032`, replace the `require_tests` option with:

```python
        no_require_tests: bool = typer.Option(
            False, "--no-require-tests",
            help="Opt out of the default test-evidence gate: open the PR even "
                 "when a repo with a configured test target lacks passing "
                 "evidence. Prints a waiver line. Legitimate for evidence-less "
                 "tasks; not bypass-logged.",
        ),
        require_tests: bool = typer.Option(
            False, "--require-tests", hidden=True,
            help="Deprecated no-op: test evidence is now required by default. "
                 "Use --no-require-tests to opt out.",
        ),
```

- [ ] **Step 4: Emit the deprecation warning**

Immediately after the option-conflict checks near `src/mship/cli/worktree.py:1084` (where other early flag validation lives), add:

```python
        if require_tests:
            output.warning(
                "--require-tests is deprecated and a no-op — test evidence is "
                "now required by default; use --no-require-tests to opt out."
            )
```

- [ ] **Step 5: Rewrite the gate call site**

Replace the body of the `# --- Test-evidence gate (#81) ---` block at `src/mship/cli/worktree.py:1473-1491` (the `if evidence_lines:` conditional) with a call to the pure decider:

```python
        from mship.core.test_evidence import decide_finish_gate

        exempt_repos = {
            r for r in evidence_repo_paths
            if "test" in config.repos[r].not_applicable
        }
        decision = decide_finish_gate(
            evidence, exempt_repos, opt_out=no_require_tests
        )
        if decision.action == "block":
            output.error("Test evidence missing — blocking finish:")
            for r in decision.missing_repos:
                output.error(f"  {r}: no passing test evidence")
            output.error(
                "Run `mship test`, record evidence via "
                "`mship journal \"tests verified externally\" --test-state pass`, "
                "or pass --no-require-tests to waive."
            )
            raise typer.Exit(code=1)
        if decision.action == "waive":
            output.warning(
                "Test-evidence gate waived (--no-require-tests); missing: "
                + ", ".join(decision.missing_repos)
            )
        elif decision.action == "warn_no_target":
            output.warning(
                "No test target configured for: "
                + ", ".join(decision.exempt_repos)
                + " — evidence gate downgraded to a warning."
            )
```

Note: `evidence` (the `read_evidence(...)` result) and `evidence_repo_paths` are already computed just above this block; keep those lines. Delete the now-unused `format_missing_summary` import/call **only** if no other code in the function uses it — otherwise leave it.

- [ ] **Step 6: Run the full finish suite**

Run: `cd mothership && uv run pytest tests/test_finish_integration.py -v`
Expected: PASS (new cases + no regressions). Fix any existing test that passed `require_tests=True` expecting a block — it now blocks by default; the assertion still holds but the flag is a no-op.

- [ ] **Step 7: Commit**

```bash
git add src/mship/cli/worktree.py tests/test_finish_integration.py
git commit -m "feat(finish): require test evidence by default; --no-require-tests opt-out; deprecate --require-tests (ac1,ac2,ac3)"
mship journal "finish gate inverted to block-by-default with --no-require-tests opt-out; integration tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 acs=ac4 -->
### Task 3: Skill prose + ergonomics guard

**Files:**
- Modify: `src/mship/skills/working-with-mothership/SKILL.md` (finish synopsis `:285` + `finish` description `:352`)
- Modify: `src/mship/skills/test-driven-development/SKILL.md:315`, `src/mship/skills/verification-before-completion/SKILL.md:125` (prose references)
- Modify: `src/mship/skills/VENDOR.md:75,90` (ledger entries mentioning the gate)
- Test: `tests/skills/test_skill_dispatch_ergonomics.py` (add a guard assertion)

**Interfaces:**
- Consumes: nothing new — pure documentation + a text-scan test.
- Produces: a `test_no_skill_passes_require_tests_flag` guard.

- [ ] **Step 1: Write the failing guard test**

Add to `tests/skills/test_skill_dispatch_ergonomics.py` (reuse the module's existing skill-file-reading helper — match how the neighboring tests load skill text):

```python
def test_no_skill_instructs_require_tests_flag():
    """Skills must describe the gate as the default, never instruct passing
    `mship finish --require-tests` (now a deprecated no-op)."""
    for path in _skill_markdown_files():  # existing helper in this module
        text = path.read_text()
        assert "finish --require-tests" not in text, (
            f"{path} still instructs the deprecated --require-tests flag"
        )
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd mothership && uv run pytest tests/skills/test_skill_dispatch_ergonomics.py::test_no_skill_instructs_require_tests_flag -v`
Expected: FAIL — VENDOR.md and two SKILL.md files contain `finish --require-tests`.

- [ ] **Step 3: Update the prose**

- `working-with-mothership/SKILL.md:285` — remove `[--require-tests]` from the finish synopsis (it's a hidden deprecated no-op now); add `[--no-require-tests]`.
- `working-with-mothership/SKILL.md:352` — change the `--require-tests blocks…` sentence to: *"By default `finish` blocks when a repo with a configured test target lacks passing test evidence; pass `--no-require-tests` to waive (repos with no test target downgrade to a warning naming them)."*
- `test-driven-development/SKILL.md:315` — change *"records the evidence that `mship finish --require-tests` checks"* to *"records the evidence that `mship finish` requires by default before opening a PR."*
- `verification-before-completion/SKILL.md:125` — change *"`mship finish --require-tests` enforces that gate"* to *"`mship finish` enforces that gate by default."*
- `VENDOR.md:75,90` — update the two ledger lines to drop `--require-tests` from the gate description (match the new prose); add a new ledger note that this task edited these vendored files.

- [ ] **Step 4: Run the guard + skill suite**

Run: `cd mothership && uv run pytest tests/skills/ -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/mship/skills/
git commit -m "docs(skills): finish gate is default; ergonomics guard bans --require-tests flag (ac4)"
mship journal "updated skill prose + added ergonomics guard for the default finish gate" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 acs=ac5 -->
### Task 4: Verify the overnight cloud-worker finish path produces evidence

**Files:**
- Read: `src/mship/skills/overnight-cloud-worker-routines/SKILL.md` (the finish path around `:75`)
- Modify: same file **only if** the routine finishes without first running `mship test`.

**Interfaces:**
- Consumes: nothing — verification task.
- Produces: either a confirmation note (no change needed) or an inserted `mship test` step before finish.

- [ ] **Step 1: Read the routine's finish path**

Read `overnight-cloud-worker-routines/SKILL.md` end-to-end for where the worker runs `mship finish` (bootstrap writes the finish call). Confirm whether a passing `mship test` (or recorded evidence) precedes it. Note: `mship serve` exposes **no** finish endpoint (verified — only the CLI finishes), so there is no serve/API path to update; the routine is the only automated finish caller.

- [ ] **Step 2: If evidence is NOT guaranteed before finish, insert a test step**

If the routine can reach `mship finish` without evidence, add an explicit step before it: run `mship test`; on failure, do not finish (report and stop). If the routine already runs `mship test` before finish, make no change — record the confirmation in the journal instead.

- [ ] **Step 3: Verify skill suite still passes (if edited)**

Run: `cd mothership && uv run pytest tests/skills/ -v`
Expected: PASS.

- [ ] **Step 4: Commit (or journal-only if no change)**

```bash
# If edited:
git add src/mship/skills/overnight-cloud-worker-routines/SKILL.md
git commit -m "docs(cloud-worker): ensure mship test precedes finish under the default gate (ac5)"
mship journal "verified/updated overnight cloud-worker finish path produces evidence before finishing" --action committed
# If no change was needed:
mship journal "verified overnight cloud-worker routine already runs mship test before finish; no change (ac5)" --action verified
```
<!-- /mship:task -->

---

## Self-Review

**Spec coverage:**
- ac1 (block by default, actionable message, proceed with evidence) → Task 1 (`block` action) + Task 2 (message + wiring). ✓
- ac2 (`--no-require-tests` waiver line; no-target downgrade names repos) → Task 1 (`waive`/`warn_no_target`) + Task 2 (flag + messages + `not_applicable` detection). ✓
- ac3 (`--require-tests` hidden deprecated no-op with stderr warning) → Task 2 Steps 3-4. ✓
- ac4 (skills back to bare finish + ergonomics guard) → Task 3. ✓
- ac5 (cloud-worker finish produces evidence) → Task 4. ✓
- ac6 (unit tests: block, evidence-pass, no-target warn, deprecation no-op) → Task 1 (block/pass/warn/waive units) + Task 2 (deprecation no-op integration test). ✓

**Placeholder scan:** No TBD/TODO; every code step has real code. Task 4 is inherently a verify-then-maybe-edit task — both branches (edit / journal-only) are spelled out. ✓

**Type consistency:** `decide_finish_gate(evidence, exempt_repos, opt_out)` and `FinishGateDecision(action, missing_repos, exempt_repos)` are used identically in Tasks 1 and 2. `RepoEvidence.status` values (`passed`/`failed`/`stale`/`missing`) match `test_evidence.py`. Flag names `--no-require-tests` / `--require-tests` consistent across Tasks 2 and 3. ✓
