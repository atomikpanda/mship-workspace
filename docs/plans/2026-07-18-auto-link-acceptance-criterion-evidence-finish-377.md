# Auto-link Acceptance-Criterion Evidence at `mship finish` (#377) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: **test-driven-development** (write the failing test first for every task). Use subagent-driven-development or executing-plans to run this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `auto-link-acceptance-criterion-evidence-finish-377` (status: dispatched). Mothership only. Affected repo: `mothership`.

**Goal:** At `mship finish`, for a task bound to a spec, auto-populate acceptance-criterion evidence before the PR acceptance block is built — attach the passing test-run reference(s) to every AC, and attach each implementing commit's sha to the AC(s) its message names on a word boundary — idempotently and additively.

**Architecture:** A new pure module `core/evidence_autolink.py` computes the evidence links to add (test-run refs → all criteria; commits → criteria whose id token appears in the message, intersected with the spec's real criterion ids), de-duplicated against existing evidence. A thin wiring block in the `finish` command (`cli/worktree.py`) resolves the bound spec (reusing `resolve_bound_spec`, already called there), gathers the task's passing test-run refs and the branch commits, calls the planner, applies each link via the existing `set_criterion_evidence` primitive, and persists with `SpecStore.save` — all placed after the existing AC-evidence gate and immediately before `build_acceptance_block`. The renderer is untouched.

**Tech Stack:** Python 3, Pydantic models (`Spec`/`AcceptanceCriterion`/`AcceptanceEvidence`), Typer CLI, pytest + `typer.testing.CliRunner`, `uv` for running tests.

---

## Key facts verified in the code (read before starting)

- **Wiring point** — `cli/worktree.py`: the `finish` command (def at line 920) already resolves the bound spec at line 1410 (`bound_spec = resolve_bound_spec(task, workspace_root)`), warns about un-evidenced ACs at lines 1424-1439, then renders the acceptance block at lines 1443-1444 (`build_acceptance_block(bound_spec)`). Insert the auto-link **between line 1439 and line 1441** — after the gate, before the renderer. `effective_bases` (dict `{repo: base}`, built at lines 1304-1314), `config`, `shell`, `task`, `workspace_root` (line 1078), and `Path` are all in scope there. `datetime` is NOT module-imported in that scope — import it locally (the file already does this at lines 459/1258/1699).
- **`resolve_bound_spec`** (`core/workitem_gate.py`) returns `Spec | None` (raises `BoundSpecUnresolved` on ambiguity). `finish` has already reduced it to `bound_spec` (a `Spec` or `None`). Guard the auto-link with `if bound_spec is not None:` → satisfies ac8 (no bound spec ⇒ skip, no error).
- **`set_criterion_evidence`** (`core/spec_review.py`) appends `AcceptanceEvidence(kind, ref, note)` **unconditionally — it is NOT idempotent**. Therefore de-duplication MUST live in the pure planner (`compute_evidence_links`), keyed on `(criterion_id, kind, ref)` vs. the criterion's existing `evidence`.
- **Renderer** (`core/pr.py::build_acceptance_block`, lines 428-450, UNCHANGED): for each criterion with `c.evidence`, emits `- [x] \`{c.id}\` {c.text} — {kind}:{ref}, …`; empty evidence → `- [ ] … — _no evidence_`. So attaching evidence makes it render checked with `test:`/`commit:` refs (ac9).
- **Models** (`core/spec.py`): `AcceptanceEvidence(kind: Literal["test","commit","artifact"], ref: str, note: str|None=None)`; `AcceptanceCriterion(id, text, verdict, evidence: list=[], comment)`. Serialization round-trips evidence (proven by `tests/core/test_spec_store.py`).
- **Test-run ref shape** (`core/spec_review.py::infer_evidence_kind` + `cli/spec.py` help + many tests): `test-runs/<iter>` or `test-runs/<iter>.<repo>`. Iteration is `task.test_iteration` (`core/state.py:41`); per-repo pass/fail is `task.test_results[<repo>]` = `TestResult(status: Literal["pass","fail","skip"], at)` (`core/state.py:14-16, 32`). `mship test` bumps `test_iteration` (`cli/exec.py:279`). For ac10 build `test-runs/{task.test_iteration}.{repo}` for each repo whose `test_results[repo].status == "pass"`.
- **Commit range** — `finish` already scans subjects with `git log --format=%s origin/{eff_base}..{task.branch}` (line 1575). Reuse the same `origin/<base>..<branch>` range but with `--format=%H…%B` to get sha + full message.
- **`SpecStore`** (`core/spec_store.py`): `SPECS_DIRNAME = "specs"` (line 10); `SpecStore(workspace_root / SPECS_DIRNAME).save(spec)` (line 65) is the persist path used by the manual `mship spec evidence` command (`cli/spec.py:324`).
- **Test conventions**: pure unit tests live under `tests/core/`; finish integration tests live in `tests/test_finish_gate.py`, which already provides the `finish_gate_workspace` fixture (mocks `gh`/git via `mock_shell.run.side_effect`), and helpers `_seed_feature_with_ac(workspace)` (creates approved spec id `ev-spec` with `ac1`, linked so `resolve_bound_spec` finds it) and `_write_plan(workspace, slug)`. `test_finish_appends_acceptance_block_to_pr_body` (line 376) is the pattern for asserting on the `gh pr create` body.

**Running commands:** the build target worktree is
`/home/bailey/development/repos/mship-workspace/.worktrees/auto-link-acceptance-criterion-evidence-finish-377/mothership`.
All `uv run pytest …` and `mship …` commands run with that directory as cwd. Commits use `git -C <that worktree>`.

## File Structure

| File | Create/Modify | Responsibility |
|------|---------------|----------------|
| `src/mship/core/evidence_autolink.py` | Create | Pure evidence-link planner: `extract_ac_ids`, `compute_evidence_links`, `test_run_refs_for_task`, `commits_since_base`, `EvidenceLink`. No mutation, no I/O except the git read in `commits_since_base`. |
| `tests/core/test_evidence_autolink.py` | Create | Unit tests for the planner (ac2/ac3/ac4/ac5/ac6/ac7/ac10 + parsing). |
| `src/mship/cli/worktree.py` | Modify (insert at line 1440, between the AC-evidence gate and `build_acceptance_block`) | Wire the auto-link into `finish`: gather test-run refs + branch commits, apply links, save the spec. |
| `tests/test_finish_gate.py` | Modify (append tests; reuse existing fixture/helpers) | Integration/acceptance tests for the finish flow (ac1/ac2/ac8/ac9/ac10 + ac6 end-to-end). |

---

<!-- mship:task id=1 -->
### Task 1: Module scaffold + `EvidenceLink` + `extract_ac_ids` (word-boundary AC id extraction)

**Files:**
- Create: `src/mship/core/evidence_autolink.py`
- Test: `tests/core/test_evidence_autolink.py`

- [ ] **Step 1: Write the failing test**

Create `tests/core/test_evidence_autolink.py`:

```python
from datetime import datetime, timezone

from mship.core.evidence_autolink import extract_ac_ids
from mship.core.spec import AcceptanceCriterion, AcceptanceEvidence, Spec


def _spec(criteria):
    now = datetime(2026, 7, 18, tzinfo=timezone.utc)
    return Spec(id="s1", title="S", status="approved", created_at=now,
                updated_at=now, acceptance_criteria=criteria)


def test_extract_ac_ids_standalone_tokens_lowercased():
    assert extract_ac_ids("fixes ac1 and AC3") == {"ac1", "ac3"}


def test_extract_ac_ids_word_boundary_excludes_longer_id_and_substrings():
    # `ac7` written alone must not surface `ac70` (\d+ is greedy to a boundary);
    # `ac7` buried in `mac7book` and the letters of `reactor` are not references.
    assert extract_ac_ids("done ac7") == {"ac7"}
    assert extract_ac_ids("done ac70") == {"ac70"}
    assert extract_ac_ids("patch mac7book near the reactor") == set()


def test_extract_ac_ids_empty_message():
    assert extract_ac_ids("") == set()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_evidence_autolink.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'mship.core.evidence_autolink'`.

- [ ] **Step 3: Write minimal implementation**

Create `src/mship/core/evidence_autolink.py`:

```python
"""Auto-link acceptance-criterion evidence at `mship finish` (spec 377).

For a spec-bound task, `mship finish` attaches:
  1. the task's passing test-run reference(s) (`test-runs/<iter>.<repo>`) to EVERY
     acceptance criterion, and
  2. each implementing commit's sha to the acceptance criterion/criteria whose id
     token (e.g. `ac7`) appears — on a word boundary — in the commit message.

`compute_evidence_links` is a pure planner: it never mutates the spec. It returns
the links to add, already de-duplicated against the spec's existing evidence, so
re-running finish is idempotent and manual `mship spec evidence` entries survive.
The finish command applies the links via `spec_review.set_criterion_evidence` and
persists with `SpecStore`.
"""
from __future__ import annotations

import re
from dataclasses import dataclass

# `\b` word boundaries make `ac7` match the standalone token `ac7` but never the
# longer id `ac70` (`\d+` is greedy up to a boundary) nor an `ac7` buried inside
# another word (e.g. `mac7book`). Case-insensitive so `AC7` in a subject matches.
_AC_TOKEN_RE = re.compile(r"\bac\d+\b", re.IGNORECASE)


@dataclass(frozen=True)
class EvidenceLink:
    """One evidence entry to append to an acceptance criterion."""

    criterion_id: str
    kind: str  # "test" | "commit"
    ref: str


def extract_ac_ids(message: str) -> set[str]:
    """Return the lowercased `ac<number>` tokens named on word boundaries in
    `message` (e.g. `"fixes ac1 and AC3"` -> `{"ac1", "ac3"}`). Substring hits
    inside a larger word (`mac7book`) and the longer id `ac70` when only `ac7`
    is written are excluded by the word-boundary anchors."""
    return {m.group(0).lower() for m in _AC_TOKEN_RE.finditer(message or "")}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_evidence_autolink.py -v`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git -C /home/bailey/development/repos/mship-workspace/.worktrees/auto-link-acceptance-criterion-evidence-finish-377/mothership add src/mship/core/evidence_autolink.py tests/core/test_evidence_autolink.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/auto-link-acceptance-criterion-evidence-finish-377/mothership commit -m "feat(377): add evidence_autolink module with word-boundary AC id extraction" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "evidence_autolink: EvidenceLink + extract_ac_ids (word-boundary ac id scan); tests passing" --task auto-link-acceptance-criterion-evidence-finish-377 --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: `compute_evidence_links` — test-run refs attach to every criterion

**Files:**
- Modify: `src/mship/core/evidence_autolink.py`
- Test: `tests/core/test_evidence_autolink.py`

- [ ] **Step 1: Write the failing test**

Append to `tests/core/test_evidence_autolink.py`:

```python
from mship.core.evidence_autolink import EvidenceLink, compute_evidence_links


def test_testrun_refs_attach_to_every_criterion():
    spec = _spec([AcceptanceCriterion(id="ac1", text="x"),
                  AcceptanceCriterion(id="ac2", text="y")])
    links = compute_evidence_links(spec, commits=[],
                                   test_run_refs=["test-runs/1.mothership"])
    assert set(links) == {
        EvidenceLink("ac1", "test", "test-runs/1.mothership"),
        EvidenceLink("ac2", "test", "test-runs/1.mothership"),
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_evidence_autolink.py::test_testrun_refs_attach_to_every_criterion -v`
Expected: FAIL — `ImportError: cannot import name 'compute_evidence_links'`.

- [ ] **Step 3: Write minimal implementation**

Append to `src/mship/core/evidence_autolink.py`:

```python
def compute_evidence_links(spec, commits, test_run_refs) -> list[EvidenceLink]:
    """Plan the evidence links to add for `spec` (pure -- no mutation).

    Every ref in `test_run_refs` becomes a `test` link on EVERY acceptance
    criterion. (Commit handling and de-duplication are added in later tasks.)"""
    links: list[EvidenceLink] = []
    for ref in test_run_refs:
        for c in spec.acceptance_criteria:
            links.append(EvidenceLink(criterion_id=c.id, kind="test", ref=ref))
    return links
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_evidence_autolink.py -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git -C /home/bailey/development/repos/mship-workspace/.worktrees/auto-link-acceptance-criterion-evidence-finish-377/mothership add src/mship/core/evidence_autolink.py tests/core/test_evidence_autolink.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/auto-link-acceptance-criterion-evidence-finish-377/mothership commit -m "feat(377): compute_evidence_links attaches test-run refs to every AC" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "compute_evidence_links v1: test-run refs -> all criteria; tests passing" --task auto-link-acceptance-criterion-evidence-finish-377 --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: `compute_evidence_links` — commits attach to named criteria (ac2/ac3/ac4/ac5)

**Files:**
- Modify: `src/mship/core/evidence_autolink.py`
- Test: `tests/core/test_evidence_autolink.py`

- [ ] **Step 1: Write the failing test**

Append to `tests/core/test_evidence_autolink.py`:

```python
def test_commit_attaches_to_named_criterion():  # ac2
    spec = _spec([AcceptanceCriterion(id="ac1", text="x"),
                  AcceptanceCriterion(id="ac2", text="y")])
    links = compute_evidence_links(spec, commits=[("sha1", "implement ac2 logic")],
                                   test_run_refs=[])
    assert links == [EvidenceLink("ac2", "commit", "sha1")]


def test_commit_naming_multiple_ids_attaches_to_all():  # ac3
    spec = _spec([AcceptanceCriterion(id="ac1", text="x"),
                  AcceptanceCriterion(id="ac3", text="z")])
    links = compute_evidence_links(spec, commits=[("sha1", "ac1 and ac3 together")],
                                   test_run_refs=[])
    assert set(links) == {EvidenceLink("ac1", "commit", "sha1"),
                          EvidenceLink("ac3", "commit", "sha1")}


def test_commit_naming_no_id_is_noop():  # ac4
    spec = _spec([AcceptanceCriterion(id="ac1", text="x")])
    links = compute_evidence_links(spec, commits=[("sha1", "refactor internals")],
                                   test_run_refs=[])
    assert links == []


def test_word_boundary_ac7_does_not_attach_to_ac70():  # ac5
    spec = _spec([AcceptanceCriterion(id="ac7", text="x"),
                  AcceptanceCriterion(id="ac70", text="y")])
    links = compute_evidence_links(spec, commits=[("sha1", "handles ac7")],
                                   test_run_refs=[])
    assert links == [EvidenceLink("ac7", "commit", "sha1")]


def test_word_boundary_substring_is_not_a_reference():  # ac5
    spec = _spec([AcceptanceCriterion(id="ac7", text="x")])
    links = compute_evidence_links(spec, commits=[("sha1", "patch mac7book in reactor")],
                                   test_run_refs=[])
    assert links == []


def test_unknown_ac_id_in_commit_is_ignored():  # ac5 (intersect with real ids)
    spec = _spec([AcceptanceCriterion(id="ac1", text="x")])
    links = compute_evidence_links(spec, commits=[("sha1", "touches ac9")],
                                   test_run_refs=[])
    assert links == []
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_evidence_autolink.py::test_commit_attaches_to_named_criterion -v`
Expected: FAIL — the current implementation ignores `commits`, so `links == []` (assert mismatch).

- [ ] **Step 3: Write minimal implementation**

Replace the whole `compute_evidence_links` in `src/mship/core/evidence_autolink.py` with:

```python
def compute_evidence_links(spec, commits, test_run_refs) -> list[EvidenceLink]:
    """Plan the evidence links to add for `spec` (pure -- no mutation).

    - every ref in `test_run_refs` -> a `test` link on EVERY acceptance criterion;
    - every `(sha, message)` in `commits` -> a `commit` link on each acceptance
      criterion whose id is named (word-boundary) in the message.

    (De-duplication is added in the next task.)"""
    id_by_lower = {c.id.lower(): c.id for c in spec.acceptance_criteria}
    links: list[EvidenceLink] = []
    for ref in test_run_refs:
        for c in spec.acceptance_criteria:
            links.append(EvidenceLink(criterion_id=c.id, kind="test", ref=ref))
    for sha, message in commits:
        for token in extract_ac_ids(message):
            criterion_id = id_by_lower.get(token)
            if criterion_id is not None:
                links.append(EvidenceLink(criterion_id=criterion_id, kind="commit", ref=sha))
    return links
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_evidence_autolink.py -v`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git -C /home/bailey/development/repos/mship-workspace/.worktrees/auto-link-acceptance-criterion-evidence-finish-377/mothership add src/mship/core/evidence_autolink.py tests/core/test_evidence_autolink.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/auto-link-acceptance-criterion-evidence-finish-377/mothership commit -m "feat(377): compute_evidence_links maps commits to named ACs (word-boundary, real-id intersect)" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "compute_evidence_links v2: commit->named AC (ac2/ac3/ac4/ac5); tests passing" --task auto-link-acceptance-criterion-evidence-finish-377 --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: `compute_evidence_links` — de-dup vs existing + additive + idempotent (ac6/ac7)

**Files:**
- Modify: `src/mship/core/evidence_autolink.py`
- Test: `tests/core/test_evidence_autolink.py`

- [ ] **Step 1: Write the failing test**

Append to `tests/core/test_evidence_autolink.py`:

```python
from mship.core.spec_review import set_criterion_evidence


def test_skips_evidence_that_already_exists():  # ac6 (dedup vs existing)
    spec = _spec([AcceptanceCriterion(
        id="ac1", text="x",
        evidence=[AcceptanceEvidence(kind="test", ref="test-runs/1.mothership")])])
    links = compute_evidence_links(spec, commits=[],
                                   test_run_refs=["test-runs/1.mothership"])
    assert links == []  # identical (criterion, kind, ref) already present


def test_preserves_manual_evidence_and_only_adds():  # ac7
    spec = _spec([AcceptanceCriterion(
        id="ac1", text="x",
        evidence=[AcceptanceEvidence(kind="artifact", ref="https://manual")])])
    links = compute_evidence_links(spec, commits=[],
                                   test_run_refs=["test-runs/1.mothership"])
    assert links == [EvidenceLink("ac1", "test", "test-runs/1.mothership")]
    # the planner never mutates: the manual entry is untouched
    assert spec.acceptance_criteria[0].evidence == [
        AcceptanceEvidence(kind="artifact", ref="https://manual")]


def test_idempotent_when_links_applied_then_recomputed():  # ac6
    spec = _spec([AcceptanceCriterion(id="ac1", text="x")])
    commits = [("sha1", "implement ac1")]
    refs = ["test-runs/1.mothership"]
    first = compute_evidence_links(spec, commits, refs)
    for link in first:
        set_criterion_evidence(spec, link.criterion_id, link.kind, link.ref)
    second = compute_evidence_links(spec, commits, refs)
    assert second == []  # nothing new on the second pass
    assert sorted(e.kind for e in spec.acceptance_criteria[0].evidence) == ["commit", "test"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_evidence_autolink.py::test_skips_evidence_that_already_exists tests/core/test_evidence_autolink.py::test_idempotent_when_links_applied_then_recomputed -v`
Expected: FAIL — the current planner appends duplicates (returns the already-present link / a non-empty second pass).

- [ ] **Step 3: Write minimal implementation**

Replace the whole `compute_evidence_links` in `src/mship/core/evidence_autolink.py` with the final version:

```python
def compute_evidence_links(spec, commits, test_run_refs) -> list[EvidenceLink]:
    """Plan the evidence links to add for `spec` (pure -- no mutation, no I/O).

    - every ref in `test_run_refs` -> a `test` link on EVERY acceptance criterion;
    - every `(sha, message)` in `commits` -> a `commit` link on each acceptance
      criterion whose id is named (word-boundary) in the message.

    De-duplicated against the spec's existing evidence and within the batch, so
    the result never repeats an existing `(criterion, kind, ref)`. This is what
    makes finish idempotent (ac6) and additive to manual evidence (ac7)."""
    id_by_lower = {c.id.lower(): c.id for c in spec.acceptance_criteria}
    existing: set[tuple[str, str, str]] = {
        (c.id, e.kind, e.ref)
        for c in spec.acceptance_criteria
        for e in c.evidence
    }
    seen: set[tuple[str, str, str]] = set()
    links: list[EvidenceLink] = []

    def _add(criterion_id: str, kind: str, ref: str) -> None:
        key = (criterion_id, kind, ref)
        if key in existing or key in seen:
            return
        seen.add(key)
        links.append(EvidenceLink(criterion_id=criterion_id, kind=kind, ref=ref))

    for ref in test_run_refs:
        for c in spec.acceptance_criteria:
            _add(c.id, "test", ref)
    for sha, message in commits:
        for token in extract_ac_ids(message):
            criterion_id = id_by_lower.get(token)
            if criterion_id is not None:
                _add(criterion_id, "commit", sha)
    return links
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_evidence_autolink.py -v`
Expected: PASS (13 tests).

- [ ] **Step 5: Commit**

```bash
git -C /home/bailey/development/repos/mship-workspace/.worktrees/auto-link-acceptance-criterion-evidence-finish-377/mothership add src/mship/core/evidence_autolink.py tests/core/test_evidence_autolink.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/auto-link-acceptance-criterion-evidence-finish-377/mothership commit -m "feat(377): dedup evidence links vs existing (idempotent + additive)" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "compute_evidence_links v3: dedup vs existing evidence (ac6/ac7 idempotent+additive); tests passing" --task auto-link-acceptance-criterion-evidence-finish-377 --action committed
```
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: `test_run_refs_for_task` — build passing test-run refs per repo (ac10)

**Files:**
- Modify: `src/mship/core/evidence_autolink.py`
- Test: `tests/core/test_evidence_autolink.py`

- [ ] **Step 1: Write the failing test**

Append to `tests/core/test_evidence_autolink.py`:

```python
from mship.core.evidence_autolink import test_run_refs_for_task
from mship.core.state import Task, TestResult


def _task(**kw):
    base = dict(slug="t", description="d", phase="dev",
                created_at=datetime(2026, 7, 18, tzinfo=timezone.utc),
                affected_repos=["mothership"], branch="feat")
    base.update(kw)
    return Task(**base)


def test_test_run_refs_only_for_passing_repos():  # ac10
    now = datetime(2026, 7, 18, tzinfo=timezone.utc)
    task = _task(test_iteration=3,
                 test_results={"mothership": TestResult(status="pass", at=now),
                               "web": TestResult(status="fail", at=now)})
    assert test_run_refs_for_task(task) == ["test-runs/3.mothership"]


def test_test_run_refs_empty_without_iteration():
    task = _task(test_iteration=0, test_results={})
    assert test_run_refs_for_task(task) == []
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_evidence_autolink.py::test_test_run_refs_only_for_passing_repos -v`
Expected: FAIL — `ImportError: cannot import name 'test_run_refs_for_task'`.

- [ ] **Step 3: Write minimal implementation**

Append to `src/mship/core/evidence_autolink.py`:

```python
def test_run_refs_for_task(task) -> list[str]:
    """Return `test-runs/<iteration>.<repo>` refs for every repo whose most recent
    recorded test result passed (spec 377 ac10). `task.test_iteration` is the run
    number; `task.test_results[repo].status == "pass"` selects the repos. Empty
    when the task has never recorded a test iteration."""
    iteration = getattr(task, "test_iteration", 0) or 0
    if iteration <= 0:
        return []
    refs: list[str] = []
    for repo in sorted(task.test_results):
        result = task.test_results[repo]
        if getattr(result, "status", None) == "pass":
            refs.append(f"test-runs/{iteration}.{repo}")
    return refs
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_evidence_autolink.py -v`
Expected: PASS (15 tests).

- [ ] **Step 5: Commit**

```bash
git -C /home/bailey/development/repos/mship-workspace/.worktrees/auto-link-acceptance-criterion-evidence-finish-377/mothership add src/mship/core/evidence_autolink.py tests/core/test_evidence_autolink.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/auto-link-acceptance-criterion-evidence-finish-377/mothership commit -m "feat(377): test_run_refs_for_task builds test-runs/<iter>.<repo> for passing repos" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "test_run_refs_for_task: passing test-run refs per repo (ac10); tests passing" --task auto-link-acceptance-criterion-evidence-finish-377 --action committed
```
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: `commits_since_base` — enumerate `(sha, message)` on the branch

**Files:**
- Modify: `src/mship/core/evidence_autolink.py`
- Test: `tests/core/test_evidence_autolink.py`

- [ ] **Step 1: Write the failing test**

Append to `tests/core/test_evidence_autolink.py`:

```python
from pathlib import Path

from mship.core.evidence_autolink import commits_since_base
from mship.util.shell import ShellResult


class _FakeShell:
    def __init__(self, result):
        self._result = result
        self.calls = []

    def run(self, cmd, cwd=None, env=None):
        self.calls.append((cmd, cwd))
        return self._result


def test_commits_since_base_parses_nul_separated_records():
    # git separates records with \x1e and the sha from the (possibly multi-line)
    # body with \x1f; a trailing newline per record is tolerated.
    stdout = "sha1\x1fimplement ac1\nmore body\x1e\nsha2\x1ffix ac2\x1e\n"
    shell = _FakeShell(ShellResult(returncode=0, stdout=stdout, stderr=""))
    commits = commits_since_base(shell, Path("/repo"), "main", "feat")
    assert commits == [("sha1", "implement ac1\nmore body"), ("sha2", "fix ac2")]
    assert "origin/main..feat" in shell.calls[0][0]


def test_commits_since_base_empty_on_git_failure():
    shell = _FakeShell(ShellResult(returncode=128, stdout="", stderr="fatal"))
    assert commits_since_base(shell, Path("/repo"), "main", "feat") == []
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_evidence_autolink.py::test_commits_since_base_parses_nul_separated_records -v`
Expected: FAIL — `ImportError: cannot import name 'commits_since_base'`.

- [ ] **Step 3: Write minimal implementation**

In `src/mship/core/evidence_autolink.py`, add `import shlex` to the top import block (below `import re`) and the two separator constants below `_AC_TOKEN_RE`, then append the function:

```python
# add to the imports at the top of the file:
import shlex
```

```python
# add below `_AC_TOKEN_RE`:
# Record/field separators for the `git log` format below. These control chars
# never appear in shas or human commit prose, so they delimit multi-line commit
# bodies unambiguously.
_FIELD_SEP = "\x1f"   # US -- between sha and message within one commit record
_COMMIT_SEP = "\x1e"  # RS -- between commit records
```

```python
# append at the end of the file:
def commits_since_base(shell, repo_path, base, branch) -> list[tuple[str, str]]:
    """Return `(sha, message)` for each commit on `branch` since `origin/<base>`
    (git log default order). Mirrors the `origin/<base>..<branch>` range that
    `mship finish` already uses for its subject scan. Returns `[]` on any git
    failure (fail-open: a missing branch simply yields no commit evidence)."""
    eff_base = base or "HEAD"
    rng = f"origin/{eff_base}..{branch}"
    result = shell.run(
        f"git log --format=%H{_FIELD_SEP}%B{_COMMIT_SEP} {shlex.quote(rng)}",
        cwd=repo_path,
    )
    if result.returncode != 0:
        return []
    commits: list[tuple[str, str]] = []
    for record in result.stdout.split(_COMMIT_SEP):
        record = record.strip()
        if not record:
            continue
        sha, _, message = record.partition(_FIELD_SEP)
        sha = sha.strip()
        if sha:
            commits.append((sha, message.strip()))
    return commits
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_evidence_autolink.py -v`
Expected: PASS (17 tests).

- [ ] **Step 5: Commit**

```bash
git -C /home/bailey/development/repos/mship-workspace/.worktrees/auto-link-acceptance-criterion-evidence-finish-377/mothership add src/mship/core/evidence_autolink.py tests/core/test_evidence_autolink.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/auto-link-acceptance-criterion-evidence-finish-377/mothership commit -m "feat(377): commits_since_base enumerates (sha, message) over origin/<base>..<branch>" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "commits_since_base: NUL-separated git log parse of branch commits; tests passing" --task auto-link-acceptance-criterion-evidence-finish-377 --action committed
```
<!-- /mship:task -->

<!-- mship:task id=7 -->
### Task 7: Wire auto-link into `mship finish` (ac1/ac2/ac10 end-to-end, on disk)

**Files:**
- Modify: `src/mship/cli/worktree.py` (insert a block at line 1440 — between the AC-evidence gate that ends at line 1439 and the `# Render the acceptance-criteria PR-body section once` comment at line 1441)
- Test: `tests/test_finish_gate.py` (append)

- [ ] **Step 1: Write the failing test**

Append to `tests/test_finish_gate.py`:

```python
def test_finish_autolinks_testrun_and_commit_evidence(finish_gate_workspace):
    """Spec 377 ac1/ac2/ac10: a spec-bound finish attaches the passing test-run to
    every AC and each implementing commit to the AC(s) it names -- persisted."""
    from mship.core.state import TestResult

    workspace, mock_shell = finish_gate_workspace
    wi = _seed_feature_with_ac(workspace)  # ev-spec, ac1, no evidence
    runner.invoke(app, ["spawn", "--work-item", wi.id, "auto link", "--repos", "shared"])
    _write_plan(workspace, "auto-link")

    now = datetime.now(timezone.utc)

    def _seed_tests(s):
        t = s.tasks["auto-link"]
        t.test_iteration = 1
        t.test_results = {"shared": TestResult(status="pass", at=now)}

    StateManager(workspace / ".mothership").mutate(_seed_tests)

    sha = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

    def _run(cmd, cwd, env=None):
        if "gh auth status" in cmd:
            return ShellResult(returncode=0, stdout="Logged in", stderr="")
        if "ls-remote" in cmd:
            return ShellResult(returncode=0, stdout="abc\trefs/heads/main\n", stderr="")
        if "git log --format=%H" in cmd:
            return ShellResult(returncode=0, stdout=f"{sha}\x1fimplement ac1 handling\x1e\n", stderr="")
        if "rev-list --count" in cmd and "origin/" in cmd:
            return ShellResult(returncode=0, stdout="1\n", stderr="")
        if "rev-list --count" in cmd:
            return ShellResult(returncode=0, stdout="0\n", stderr="")
        if "git push" in cmd:
            return ShellResult(returncode=0, stdout="", stderr="")
        if "gh pr create" in cmd:
            return ShellResult(returncode=0, stdout="https://github.com/org/shared/pull/1\n", stderr="")
        return ShellResult(returncode=0, stdout="", stderr="")

    mock_shell.run.side_effect = _run

    result = runner.invoke(app, ["finish", "--task", "auto-link"])
    assert result.exit_code == 0, result.output

    spec = SpecStore(workspace / "specs").find_by_id("ev-spec")
    refs = {(e.kind, e.ref) for e in spec.acceptance_criteria[0].evidence}
    assert ("test", "test-runs/1.shared") in refs  # ac1 + ac10
    assert ("commit", sha) in refs                  # ac2
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/test_finish_gate.py::test_finish_autolinks_testrun_and_commit_evidence -v`
Expected: FAIL — the spec's `ac1` still has empty evidence after finish (no wiring yet), so the `("test", …)` assertion fails.

- [ ] **Step 3: Write minimal implementation**

In `src/mship/cli/worktree.py`, insert this block immediately after the AC-evidence gate `if bound_spec is not None:` warning block (which ends at line 1439) and before the `# Render the acceptance-criteria PR-body section once` comment (line 1441):

```python
        # --- Auto-link acceptance-criterion evidence (spec 377) ---
        # For a spec-bound task, attach the passing test-run(s) to EVERY acceptance
        # criterion and each implementing commit to the AC(s) its message names --
        # BEFORE build_acceptance_block renders below. Placed AFTER the evidence
        # gate on purpose: it must not silently satisfy `--require-evidence` via an
        # auto-attached test-run (that gate is out of scope for 377). Idempotent +
        # additive; no bound spec => skipped entirely.
        if bound_spec is not None:
            from datetime import datetime as _dt_al, timezone as _tz_al

            from mship.core.evidence_autolink import (
                commits_since_base,
                compute_evidence_links,
                test_run_refs_for_task,
            )
            from mship.core.spec_review import set_criterion_evidence
            from mship.core.spec_store import SPECS_DIRNAME, SpecStore

            _al_commits: list[tuple[str, str]] = []
            for _al_repo, _al_base in effective_bases.items():
                _al_path = config.repos[_al_repo].path
                if _al_repo in task.worktrees:
                    _al_wt = Path(task.worktrees[_al_repo])
                    if _al_wt.exists():
                        _al_path = _al_wt
                _al_commits.extend(
                    commits_since_base(shell, _al_path, _al_base, task.branch)
                )
            _al_links = compute_evidence_links(
                bound_spec, _al_commits, test_run_refs_for_task(task),
            )
            if _al_links:
                for _al_link in _al_links:
                    set_criterion_evidence(
                        bound_spec, _al_link.criterion_id, _al_link.kind, _al_link.ref,
                    )
                bound_spec.updated_at = _dt_al.now(_tz_al.utc)
                SpecStore(workspace_root / SPECS_DIRNAME).save(bound_spec)
```

Note: this mutates the same `bound_spec` object that `build_acceptance_block(bound_spec)` renders two lines below, so the auto-attached evidence flows into the PR body without any renderer change.

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/test_finish_gate.py::test_finish_autolinks_testrun_and_commit_evidence -v`
Expected: PASS.

Then run the existing finish-gate suite to confirm no regression (existing tasks have `test_iteration == 0` and the default mock returns empty `git log`, so no links are added):

Run: `uv run pytest tests/test_finish_gate.py -v`
Expected: PASS (all, including `test_finish_appends_acceptance_block_to_pr_body`).

- [ ] **Step 5: Commit**

```bash
git -C /home/bailey/development/repos/mship-workspace/.worktrees/auto-link-acceptance-criterion-evidence-finish-377/mothership add src/mship/cli/worktree.py tests/test_finish_gate.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/auto-link-acceptance-criterion-evidence-finish-377/mothership commit -m "feat(377): auto-link AC evidence in mship finish before building the acceptance block" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "finish wiring: gather test-runs+commits, apply evidence links, save spec before build_acceptance_block (ac1/ac2/ac10); tests passing" --task auto-link-acceptance-criterion-evidence-finish-377 --action committed
```
<!-- /mship:task -->

<!-- mship:task id=8 -->
### Task 8: Non-spec-bound task is a clean skip (ac8)

**Files:**
- Test: `tests/test_finish_gate.py` (append)

- [ ] **Step 1: Write the failing/acceptance test**

Append to `tests/test_finish_gate.py`:

```python
def test_finish_autolink_noop_without_bound_spec(finish_gate_workspace):
    """Spec 377 ac8: a bug WI (no bound spec) finishes without any evidence work
    and without error -- the `if bound_spec is not None` guard skips auto-link."""
    from mship.core.state import TestResult

    workspace, _ = finish_gate_workspace
    items = WorkItemStore(workspace / ".mothership" / "workitems")
    wi = items.create(title="fix it", kind="bug", workspace="ws",
                      now=datetime.now(timezone.utc))
    runner.invoke(app, ["spawn", "--work-item", wi.id, "auto noop", "--repos", "shared"])

    now = datetime.now(timezone.utc)

    def _seed_tests(s):
        t = s.tasks["auto-noop"]
        t.test_iteration = 1
        t.test_results = {"shared": TestResult(status="pass", at=now)}

    StateManager(workspace / ".mothership").mutate(_seed_tests)

    result = runner.invoke(app, ["finish", "--task", "auto-noop"])
    assert result.exit_code == 0, result.output
    state = StateManager(workspace / ".mothership").load()
    assert state.tasks["auto-noop"].pr_urls.get("shared") == "https://github.com/org/shared/pull/1"
    assert SpecStore(workspace / "specs").list() == []  # no spec created or touched
```

- [ ] **Step 2: Run test**

Run: `uv run pytest tests/test_finish_gate.py::test_finish_autolink_noop_without_bound_spec -v`
Expected: PASS — the Task 7 guard (`if bound_spec is not None`) makes a no-spec task a clean skip; this test locks ac8.

- [ ] **Step 3: (no implementation needed — acceptance lock)**

This behavior is provided by the Task 7 guard. If the test fails, the guard is missing or `resolve_bound_spec` is being called incorrectly — fix the Task 7 block, do not weaken the test.

- [ ] **Step 4: Re-run to confirm**

Run: `uv run pytest tests/test_finish_gate.py::test_finish_autolink_noop_without_bound_spec -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C /home/bailey/development/repos/mship-workspace/.worktrees/auto-link-acceptance-criterion-evidence-finish-377/mothership add tests/test_finish_gate.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/auto-link-acceptance-criterion-evidence-finish-377/mothership commit -m "test(377): finish auto-link is a no-op without a bound spec (ac8)" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "acceptance lock ac8: no bound spec -> skip, no error; test passing" --task auto-link-acceptance-criterion-evidence-finish-377 --action committed
```
<!-- /mship:task -->

<!-- mship:task id=9 -->
### Task 9: PR body renders the auto-attached evidence via the unchanged renderer (ac9)

**Files:**
- Test: `tests/test_finish_gate.py` (append)

- [ ] **Step 1: Write the acceptance test**

Append to `tests/test_finish_gate.py`:

```python
def test_finish_pr_body_renders_autolinked_evidence(finish_gate_workspace):
    """Spec 377 ac9: the PR body's acceptance block (unchanged renderer) shows the
    auto-attached test:/commit: refs with a checked box."""
    from mship.core.state import TestResult

    workspace, mock_shell = finish_gate_workspace
    wi = _seed_feature_with_ac(workspace)
    runner.invoke(app, ["spawn", "--work-item", wi.id, "auto body", "--repos", "shared"])
    _write_plan(workspace, "auto-body")

    now = datetime.now(timezone.utc)

    def _seed_tests(s):
        t = s.tasks["auto-body"]
        t.test_iteration = 1
        t.test_results = {"shared": TestResult(status="pass", at=now)}

    StateManager(workspace / ".mothership").mutate(_seed_tests)

    sha = "0011223344556677889900112233445566778899"

    def _run(cmd, cwd, env=None):
        if "gh auth status" in cmd:
            return ShellResult(returncode=0, stdout="Logged in", stderr="")
        if "ls-remote" in cmd:
            return ShellResult(returncode=0, stdout="abc\trefs/heads/main\n", stderr="")
        if "git log --format=%H" in cmd:
            return ShellResult(returncode=0, stdout=f"{sha}\x1fimplement ac1\x1e\n", stderr="")
        if "rev-list --count" in cmd and "origin/" in cmd:
            return ShellResult(returncode=0, stdout="1\n", stderr="")
        if "rev-list --count" in cmd:
            return ShellResult(returncode=0, stdout="0\n", stderr="")
        if "git push" in cmd:
            return ShellResult(returncode=0, stdout="", stderr="")
        if "gh pr create" in cmd:
            return ShellResult(returncode=0, stdout="https://github.com/org/shared/pull/1\n", stderr="")
        return ShellResult(returncode=0, stdout="", stderr="")

    mock_shell.run.side_effect = _run

    result = runner.invoke(app, ["finish", "--task", "auto-body"])
    assert result.exit_code == 0, result.output
    create_cmds = [c.args[0] for c in mock_shell.run.call_args_list if "gh pr create" in c.args[0]]
    assert create_cmds, "expected a gh pr create call"
    body = create_cmds[0]
    assert "## Acceptance criteria" in body
    assert "test:test-runs/1.shared" in body   # test-run rendered
    assert f"commit:{sha}" in body              # commit rendered
    assert "[x]" in body and "ac1" in body      # criterion checked + listed
```

- [ ] **Step 2: Run test**

Run: `uv run pytest tests/test_finish_gate.py::test_finish_pr_body_renders_autolinked_evidence -v`
Expected: PASS — the Task 7 wiring mutates `bound_spec` before `build_acceptance_block`, so the existing renderer emits the refs. This test locks ac9 and proves the renderer stays unchanged.

- [ ] **Step 3: (no implementation needed — acceptance lock)**

- [ ] **Step 4: Commit**

```bash
git -C /home/bailey/development/repos/mship-workspace/.worktrees/auto-link-acceptance-criterion-evidence-finish-377/mothership add tests/test_finish_gate.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/auto-link-acceptance-criterion-evidence-finish-377/mothership commit -m "test(377): PR body renders auto-linked evidence via unchanged renderer (ac9)" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "acceptance lock ac9: PR body acceptance block renders auto-attached test:/commit: refs; test passing" --task auto-link-acceptance-criterion-evidence-finish-377 --action committed
```
<!-- /mship:task -->

<!-- mship:task id=10 -->
### Task 10: Idempotent across two finishes (ac6 end-to-end)

**Files:**
- Test: `tests/test_finish_gate.py` (append)

- [ ] **Step 1: Write the acceptance test**

Append to `tests/test_finish_gate.py`:

```python
def test_finish_autolink_idempotent_across_two_runs(finish_gate_workspace):
    """Spec 377 ac6: running finish twice does not duplicate evidence for the same
    (ref, kind, criterion)."""
    from mship.core.state import TestResult

    workspace, mock_shell = finish_gate_workspace
    wi = _seed_feature_with_ac(workspace)
    runner.invoke(app, ["spawn", "--work-item", wi.id, "auto idem", "--repos", "shared"])
    _write_plan(workspace, "auto-idem")

    now = datetime.now(timezone.utc)

    def _seed_tests(s):
        t = s.tasks["auto-idem"]
        t.test_iteration = 1
        t.test_results = {"shared": TestResult(status="pass", at=now)}

    StateManager(workspace / ".mothership").mutate(_seed_tests)

    sha = "ffeeddccbbaa99887766554433221100ffeeddcc"

    def _run(cmd, cwd, env=None):
        if "gh auth status" in cmd:
            return ShellResult(returncode=0, stdout="Logged in", stderr="")
        if "ls-remote" in cmd:
            return ShellResult(returncode=0, stdout="abc\trefs/heads/main\n", stderr="")
        if "git log --format=%H" in cmd:
            return ShellResult(returncode=0, stdout=f"{sha}\x1fimplement ac1\x1e\n", stderr="")
        if "rev-list --count" in cmd and "origin/" in cmd:
            return ShellResult(returncode=0, stdout="1\n", stderr="")
        if "rev-list --count" in cmd:
            return ShellResult(returncode=0, stdout="0\n", stderr="")
        if "git push" in cmd:
            return ShellResult(returncode=0, stdout="", stderr="")
        if "gh pr create" in cmd:
            return ShellResult(returncode=0, stdout="https://github.com/org/shared/pull/1\n", stderr="")
        return ShellResult(returncode=0, stdout="", stderr="")

    mock_shell.run.side_effect = _run

    assert runner.invoke(app, ["finish", "--task", "auto-idem"]).exit_code == 0
    assert runner.invoke(app, ["finish", "--task", "auto-idem"]).exit_code == 0

    spec = SpecStore(workspace / "specs").find_by_id("ev-spec")
    evidence = spec.acceptance_criteria[0].evidence
    assert sorted(e.kind for e in evidence) == ["commit", "test"]  # exactly one each
    assert [e.ref for e in evidence if e.kind == "test"] == ["test-runs/1.shared"]
    assert [e.ref for e in evidence if e.kind == "commit"] == [sha]
```

- [ ] **Step 2: Run test**

Run: `uv run pytest tests/test_finish_gate.py::test_finish_autolink_idempotent_across_two_runs -v`
Expected: PASS — the second finish re-runs the auto-link (it precedes the "already has PR" path), `resolve_bound_spec` re-loads the now-populated spec from disk, and `compute_evidence_links` de-dups to an empty plan, so no second `SpecStore.save` and no duplicate entries.

- [ ] **Step 3: (no implementation needed — acceptance lock)**

- [ ] **Step 4: Run the full suite for the touched areas**

Run: `uv run pytest tests/core/test_evidence_autolink.py tests/test_finish_gate.py tests/core/test_pr.py tests/core/test_spec_review.py -v`
Expected: PASS (all).

- [ ] **Step 5: Commit**

```bash
git -C /home/bailey/development/repos/mship-workspace/.worktrees/auto-link-acceptance-criterion-evidence-finish-377/mothership add tests/test_finish_gate.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/auto-link-acceptance-criterion-evidence-finish-377/mothership commit -m "test(377): finish auto-link is idempotent across two runs (ac6)" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "acceptance lock ac6: two finishes produce no duplicate evidence; full touched suite green" --task auto-link-acceptance-criterion-evidence-finish-377 --action committed
```
<!-- /mship:task -->

---

## Self-Review

**1. Spec coverage (ac → task map — all 10 covered):**

| AC | Requirement | Task(s) |
|----|-------------|---------|
| ac1 | Passing test-run attached as `test` evidence to every AC after finish | Task 2 (unit: refs→all criteria), **Task 7** (end-to-end on disk) |
| ac2 | Commit naming an AC id → `commit` evidence on exactly that AC | Task 3 (unit), **Task 7** (end-to-end) |
| ac3 | Commit naming multiple AC ids → attached to all named | Task 3 (unit) |
| ac4 | Commit naming no AC id → attached to none, no error | Task 3 (unit) |
| ac5 | Word-boundary safe (`ac7` ≠ `ac70`; `ac7` in `mac7book`/`reactor` not a ref) | Task 1 (`extract_ac_ids`), Task 3 (`ac7`-vs-`ac70`, substring, unknown-id) |
| ac6 | Idempotent — finish twice never duplicates `(ref, kind, criterion)` | Task 4 (unit apply-twice), **Task 10** (finish twice end-to-end) |
| ac7 | Manual `mship spec evidence` preserved — auto-link only adds | Task 4 (unit: existing + manual entries preserved, planner never mutates) |
| ac8 | Bound spec resolved via `resolve_bound_spec`; no spec → nothing, no error | Task 7 (reuses `resolve_bound_spec`/`bound_spec`), **Task 8** (bug WI no-op) |
| ac9 | PR body renders auto-attached evidence via unchanged renderer | **Task 9** (asserts `test:`/`commit:` + `[x]` in `gh pr create` body) |
| ac10 | Test-run ref(s) match recorded passing iteration(s) per affected repo | Task 5 (`test_run_refs_for_task` → `test-runs/<iter>.<repo>`), Task 7/9 (`test-runs/1.shared`) |

No spec requirement is left without a task. Non-goals respected: the renderer (`build_acceptance_block`) is untouched; the only hook is `mship finish`; no per-criterion test mapping and no plan AC-to-task parsing.

**2. Placeholder scan:** No `TBD`/`TODO`/"handle edge cases"/"similar to Task N". Every code step contains complete, runnable code and every command has an expected result. The evolving `compute_evidence_links` is shown in full at each task that changes it (Tasks 2, 3, 4), so out-of-order readers always see the current body.

**3. Type consistency:** `EvidenceLink(criterion_id, kind, ref)` (positional order used identically in tests and in the finish wiring). `compute_evidence_links(spec, commits, test_run_refs)` and `commits_since_base(shell, repo_path, base, branch)` signatures match every call site. `test_run_refs_for_task(task)` returns `list[str]`. The wiring feeds these into `set_criterion_evidence(spec, criterion_id, kind, ref)` — matching the verified signature in `core/spec_review.py`, whose kinds `"test"`/`"commit"` are members of `EVIDENCE_KINDS`. Evidence entries are appended as `AcceptanceEvidence(kind, ref, note=None)` per `core/spec.py`. `SpecStore(workspace_root / SPECS_DIRNAME).save(...)` and `find_by_id(...)` match `core/spec_store.py`. `resolve_bound_spec` returns `Spec | None` and the wiring hooks the already-resolved `bound_spec`, guarded by `if bound_spec is not None`.

**4. Explicit verification notes:**
- **`set_criterion_evidence` is NOT idempotent** (it appends unconditionally, confirmed in `core/spec_review.py`). All de-duplication therefore lives in `compute_evidence_links`, keyed on `(criterion_id, kind, ref)` against each criterion's existing `evidence` plus an intra-batch `seen` set. This is what delivers ac6 and ac7.
- **ac5 word-boundary** is tested with the exact `ac7`-vs-`ac70` case, the `ac7`-inside-`mac7book`/`reactor` substring case, and an unknown-id (`ac9` not in the spec) case — `extract_ac_ids` uses `r"\bac\d+\b"` and the planner intersects tokens with the spec's real criterion ids, so a message's `ac70` only matches when the spec actually defines `ac70`.
- **ac6 idempotency is tested by applying twice**: at the unit level (Task 4: compute → `set_criterion_evidence` → compute again returns `[]`) and end-to-end (Task 10: two `mship finish` invocations leave exactly one `test` and one `commit` entry).
- **Insertion point verified**: the wiring goes after the existing AC-evidence gate (ends `cli/worktree.py:1439`) and before `build_acceptance_block` (`cli/worktree.py:1443`), mutating the same `bound_spec` object the renderer reads. Placement is deliberately after the gate so the auto-attached test-run does not silently satisfy `--require-evidence` (that gate is out of scope for #377); the default finish path only warns, then auto-populates. A no-bound-spec finish is a clean skip via the `if bound_spec is not None` guard.

**Known simplification (documented, within ac10):** the per-repo test-run iteration is taken from `task.test_iteration` (the latest run number) combined with `task.test_results[repo].status == "pass"`. In the standard flow where `mship test` runs all affected repos together this is exact. A pathological interleaving (repo A last passed at iteration 5, repo B ran alone at iteration 6) would emit `test-runs/6.A`; this matches how the rest of mship (`test_evidence.read_evidence`, status views) already treats `test_results` + `test_iteration`, and the passing-test-run-to-all-ACs step still guarantees the PR body is never left empty.
