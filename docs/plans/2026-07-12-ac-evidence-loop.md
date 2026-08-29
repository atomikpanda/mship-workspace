# Close the AcceptanceCriterion evidence loop — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `ac-evidence-loop` (approved) — `specs/2026-07-12-ac-evidence-loop.md` (MOS-239)

**Goal:** Give every acceptance criterion a first-class, persisted `evidence` link, and wire the existing review / finish / PR surfaces to consult it — so "done" means "demonstrably met the criteria" rather than "an agent claimed it."

**Architecture:** A small `AcceptanceEvidence` value object hangs off each `AcceptanceCriterion` as `evidence: list[AcceptanceEvidence] = []`; it round-trips for free through the Pydantic spec store (a default of `[]` keeps every legacy spec loadable). A `set_criterion_evidence` service mirrors `set_criterion_verdict`, exposed via a `mship spec evidence` CLI command and a `POST /specs/{id}/evidence` endpoint; `build_review` gains per-AC evidence + an `unverified` count. Enforcement is deliberately soft and lives at the post-build lifecycle moments: `phase dev→review` and `mship finish` WARN on evidence-less ACs (finish BLOCKs only under a new `--require-evidence` flag), and the PR body gains an `Acceptance criteria` section. **Lifecycle invariant (encode everywhere):** `verdict` (design-review outcome; gates spec approval PRE-build) and `evidence` (implementation-verification; surfaced at review, softly gated at finish POST-build) are ORTHOGONAL — evidence is NEVER added to `approval_blockers`, because at approval time no code exists to point at.

**Tech Stack:** Python 3.14, Pydantic (models), Typer (CLI), pytest (`tmp_path`, stores on disk, `CliRunner`, FastAPI `TestClient`, `pytest.raises(match=...)`).

**Repos:** mothership only.

**Execution note:** Build SERIALLY (one implementer subagent at a time; the orchestrator commits each task's work immediately via `mship commit` — parallel state writes clobber `state.yaml`, MOS-233). Subagents leave changes STAGED and run only TARGETED tests; the orchestrator runs the full `mship test` once at the end. NOTE: the plan's per-task "commit" step is handled by the orchestrator (`mship commit` + `mship journal`), not the subagent.

---

## PR mapping

This feature ships as **two sequential PRs**, matching the schema/behavior seam the spec mandates:

- **Slice A → PR-a (model + set/surface + preservation + commit-sha journaling):** Tasks 1–6. Purely additive (a new optional field + new commands/endpoint + a widened review payload + a journal field). Mergeable on its own — nothing consults evidence for enforcement yet, so it is safe to land first.
- **Slice B → PR-b (enforcement):** Tasks 7–9. Branches off `main` **after PR-a merges**. It only reads the evidence field PR-a introduced and adds soft gates + PR-body rendering; it touches no schema, so it is revertable without touching the model.

**ac11 (the two-PR split) is satisfied by this delivery structure, not by a code task.** Do not write a task for ac11 — PR-a is Tasks 1–6 and PR-b is Tasks 7–9; PR-b reverts cleanly because it changes only enforcement/rendering call sites, never `spec.py`.

---

# Slice A — PR-a (model + set/surface + preservation + commit-sha journaling)

<!-- mship:task id=1 -->
### Task 1: `AcceptanceEvidence` model + `AcceptanceCriterion.evidence` field

**Files:**
- Modify: `src/mship/core/spec.py`
- Test: `tests/core/test_spec_store.py` (round-trip + legacy load), `tests/core/test_spec.py` (new; kind validation)

Add a structured evidence value object and the list field on the criterion. Persistence needs NO change — `serialize_spec` uses `model_dump(mode="json", …)` and `parse_spec` does `Spec(**data)`, so nested Pydantic models round-trip automatically and a missing `evidence` key falls back to the default `[]`. (Confirm `src/mship/core/spec_store.py` is untouched.)

- [ ] **Step 1: Write the failing tests**

In `tests/core/test_spec_store.py` (the `AcceptanceCriterion` / `AcceptanceEvidence` import lives at the top; add `AcceptanceEvidence`):

```python
from mship.core.spec import AcceptanceCriterion, AcceptanceEvidence, OpenQuestion, Spec


def test_evidence_round_trips_through_serialize_parse():
    now = datetime(2026, 7, 12, 10, 0, 0, tzinfo=timezone.utc)
    s = Spec(
        id="ev", title="Evidence", status="needs_review",
        created_at=now, updated_at=now,
        acceptance_criteria=[AcceptanceCriterion(
            id="ac1", text="does the thing", verdict="approved",
            evidence=[
                AcceptanceEvidence(kind="test", ref="test-runs/5.mothership"),
                AcceptanceEvidence(kind="commit", ref="deadbeef", note="the fix"),
            ],
        )],
        body="## Problem\n\nx\n",
    )
    parsed = parse_spec(serialize_spec(s))
    assert parsed == s
    assert parsed.acceptance_criteria[0].evidence[1].note == "the fix"


def test_legacy_spec_without_evidence_key_loads_with_empty_list():
    # A frontmatter block whose acceptance_criteria have NO evidence key at all
    # (an older on-disk spec) must load with evidence == [].
    text = (
        "---\n"
        "id: legacy\n"
        "title: Legacy\n"
        "status: needs_review\n"
        "created_at: '2026-07-12T10:00:00Z'\n"
        "updated_at: '2026-07-12T10:00:00Z'\n"
        "acceptance_criteria:\n"
        "- id: ac1\n"
        "  text: old criterion\n"
        "  verdict: approved\n"
        "---\n"
        "## Problem\n\nlegacy body\n"
    )
    spec = parse_spec(text)
    assert spec.acceptance_criteria[0].evidence == []
```

In `tests/core/test_spec.py` (new file):

```python
import pytest
from pydantic import ValidationError

from mship.core.spec import AcceptanceEvidence


def test_acceptance_evidence_defaults_note_none():
    e = AcceptanceEvidence(kind="artifact", ref="docs/x.md:12-18")
    assert e.note is None


def test_acceptance_evidence_rejects_unknown_kind():
    with pytest.raises(ValidationError):
        AcceptanceEvidence(kind="screenshot", ref="x")
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/core/test_spec.py tests/core/test_spec_store.py -k "evidence or legacy" -v`
Expected: FAIL (`AcceptanceEvidence` doesn't exist; `AcceptanceCriterion` has no `evidence`).

- [ ] **Step 3: Implement the model**

In `src/mship/core/spec.py`, add `AcceptanceEvidence` directly above `AcceptanceCriterion` and add the field (`Literal` and `BaseModel` are already imported at the top of the file):

```python
class AcceptanceEvidence(BaseModel):
    kind: Literal["test", "commit", "artifact"]
    ref: str
    note: str | None = None


class AcceptanceCriterion(BaseModel):
    id: str
    text: str
    verdict: Literal["unreviewed", "approved", "flagged"] = "unreviewed"
    evidence: list[AcceptanceEvidence] = []
```

- [ ] **Step 4: Run to verify it passes**

Run: `uv run pytest tests/core/test_spec.py tests/core/test_spec_store.py -v`
Expected: PASS (new evidence tests + the existing round-trip/store regression all green).

- [ ] **Step 5: Stage** (`git add`); orchestrator commits.
<!-- /mship:task -->

---

<!-- mship:task id=2 -->
### Task 2: `apply_draft` preserves evidence + verdict for unchanged ACs

**Files:**
- Modify: `src/mship/core/spec_draft.py` (`apply_draft`)
- Test: `tests/core/test_spec_draft.py`

Today `apply_draft` rebuilds `acceptance_criteria` fresh from the draft's plain strings, silently wiping verdicts and (post-Task-1) evidence on every re-apply. Teach it to carry forward `verdict` AND `evidence` for each AC whose id AND text are unchanged; an AC whose text materially changed starts fresh (empty evidence, `unreviewed` verdict). Ids remain positional (`ac{i+1}`), so "same id" means "same position."

- [ ] **Step 1: Write the failing tests**

In `tests/core/test_spec_draft.py`:

```python
from mship.core.spec import AcceptanceCriterion, AcceptanceEvidence


def test_apply_draft_preserves_evidence_and_verdict_for_unchanged_ac():
    spec = _spec()
    spec.acceptance_criteria = [
        AcceptanceCriterion(
            id="ac1", text="view questions", verdict="approved",
            evidence=[AcceptanceEvidence(kind="test", ref="test-runs/5")],
        ),
    ]
    draft = SpecDraft(problem="P", user_story="U", approach="A",
                      acceptance_criteria=["view questions"])   # SAME text
    out = apply_draft(spec, draft)
    assert out.acceptance_criteria[0].verdict == "approved"     # preserved
    assert out.acceptance_criteria[0].evidence == [AcceptanceEvidence(kind="test", ref="test-runs/5")]


def test_apply_draft_resets_evidence_and_verdict_for_materially_changed_ac():
    spec = _spec()
    spec.acceptance_criteria = [
        AcceptanceCriterion(
            id="ac1", text="view questions", verdict="approved",
            evidence=[AcceptanceEvidence(kind="test", ref="test-runs/5")],
        ),
    ]
    draft = SpecDraft(problem="P", user_story="U", approach="A",
                      acceptance_criteria=["view questions AND record answers"])  # CHANGED
    out = apply_draft(spec, draft)
    assert out.acceptance_criteria[0].verdict == "unreviewed"   # fresh
    assert out.acceptance_criteria[0].evidence == []            # fresh
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/core/test_spec_draft.py -k "preserves_evidence or resets_evidence" -v`
Expected: FAIL (current `apply_draft` always builds fresh ACs → verdict `unreviewed`, evidence `[]`).

- [ ] **Step 3: Implement the merge**

In `src/mship/core/spec_draft.py`, replace the `spec.acceptance_criteria = [...]` list-comprehension inside `apply_draft` with a prior-preserving merge (the `open_questions` block below it is unchanged):

```python
    prior_acs = {c.id: c for c in spec.acceptance_criteria}
    new_acs: list[AcceptanceCriterion] = []
    for i, t in enumerate(draft.acceptance_criteria):
        ac_id = f"ac{i + 1}"
        prior = prior_acs.get(ac_id)
        if prior is not None and prior.text == t:
            # id AND text unchanged → carry forward verdict + evidence.
            new_acs.append(AcceptanceCriterion(
                id=ac_id, text=t, verdict=prior.verdict,
                evidence=list(prior.evidence),
            ))
        else:
            # new or materially-changed criterion → start fresh.
            new_acs.append(AcceptanceCriterion(id=ac_id, text=t))
    spec.acceptance_criteria = new_acs
```

- [ ] **Step 4: Run to verify it passes**

Run: `uv run pytest tests/core/test_spec_draft.py -v`
Expected: PASS (new preservation tests + the existing `test_apply_draft_merges_fields_and_assigns_ids` regression — a first-time apply on an empty spec still yields `unreviewed` / `[]`).

- [ ] **Step 5: Stage** (`git add`); orchestrator commits.
<!-- /mship:task -->

---

<!-- mship:task id=3 -->
### Task 3: `set_criterion_evidence` service + `mship spec evidence` CLI

**Files:**
- Modify: `src/mship/core/spec_review.py` (add `EVIDENCE_KINDS`, `infer_evidence_kind`, `set_criterion_evidence`)
- Modify: `src/mship/cli/spec.py` (add the `evidence` command, mirroring `verdict`)
- Test: `tests/core/test_spec_review.py` (service + inference), `tests/cli/test_spec.py` (CLI)

`set_criterion_evidence` mirrors `set_criterion_verdict`: validate the `kind` and the `criterion_id` (clean `ValueError` on either), then append an `AcceptanceEvidence` to the named AC. `infer_evidence_kind` implements the ref-shape convention (`test-runs/… → test`; a hex sha → `commit`; else `artifact`) so the CLI can omit `--kind`.

- [ ] **Step 1: Write the failing tests**

In `tests/core/test_spec_review.py` (extend the top imports to include `AcceptanceEvidence`, `set_criterion_evidence`, `infer_evidence_kind`):

```python
from mship.core.spec import AcceptanceCriterion, AcceptanceEvidence, OpenQuestion, Spec
from mship.core.spec_review import (
    build_review, infer_evidence_kind, set_criterion_evidence, set_criterion_verdict,
)


def test_set_criterion_evidence_appends_and_persists_in_object():
    spec = _spec()
    set_criterion_evidence(spec, "ac2", "test", "test-runs/5.mothership", note="ran it")
    ev = spec.acceptance_criteria[1].evidence
    assert ev == [AcceptanceEvidence(kind="test", ref="test-runs/5.mothership", note="ran it")]


def test_set_criterion_evidence_rejects_bad_kind():
    with pytest.raises(ValueError, match="kind"):
        set_criterion_evidence(_spec(), "ac1", "screenshot", "x")


def test_set_criterion_evidence_rejects_unknown_id():
    with pytest.raises(ValueError):
        set_criterion_evidence(_spec(), "ac99", "commit", "deadbeef")


@pytest.mark.parametrize("ref,expected", [
    ("test-runs/5", "test"),
    ("test-runs/5.mothership", "test"),
    ("deadbeefcafe", "commit"),
    ("a1b2c3d", "commit"),
    ("docs/design.md:12-18", "artifact"),
    ("https://example.com/run/9", "artifact"),
    ("HEAD", "artifact"),
])
def test_infer_evidence_kind(ref, expected):
    assert infer_evidence_kind(ref) == expected
```

In `tests/cli/test_spec.py` (the `_apply_dq` helper + `_store` fixture already exist; add near the verdict CLI tests):

```python
def test_spec_evidence_infers_kind_and_persists(configured_app_with_task: Path, tmp_path):
    _apply_dq(tmp_path)  # seeds ac1
    result = runner.invoke(app, ["spec", "evidence", "dq", "ac1", "test-runs/5"])
    assert result.exit_code == 0, result.output
    ac = _store(configured_app_with_task).find_by_id("dq").acceptance_criteria[0]
    assert [(e.kind, e.ref) for e in ac.evidence] == [("test", "test-runs/5")]


def test_spec_evidence_kind_override_and_note(configured_app_with_task: Path, tmp_path):
    _apply_dq(tmp_path)
    result = runner.invoke(
        app, ["spec", "evidence", "dq", "ac1", "HEAD", "--kind", "commit", "--note", "the fix"],
    )
    assert result.exit_code == 0, result.output
    ac = _store(configured_app_with_task).find_by_id("dq").acceptance_criteria[0]
    assert ac.evidence[0].kind == "commit" and ac.evidence[0].note == "the fix"


def test_spec_evidence_unknown_criterion_errors(configured_app_with_task: Path, tmp_path):
    _apply_dq(tmp_path)
    result = runner.invoke(app, ["spec", "evidence", "dq", "ac99", "test-runs/1"])
    assert result.exit_code != 0
    assert "ac99" in result.output
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/core/test_spec_review.py -k "evidence or infer" tests/cli/test_spec.py -k evidence -v`
Expected: FAIL (`set_criterion_evidence` / `infer_evidence_kind` / the `evidence` command don't exist).

- [ ] **Step 3: Implement the service + inference**

In `src/mship/core/spec_review.py`, add `import re` at the top, then (below `VERDICTS` / `PROSE_UNIT_IDS`) add the kind set + helpers, and append `set_criterion_evidence` mirroring `set_criterion_verdict`:

```python
import re

EVIDENCE_KINDS: tuple[str, ...] = ("test", "commit", "artifact")
_SHA_RE = re.compile(r"^[0-9a-f]{7,40}$", re.IGNORECASE)


def infer_evidence_kind(ref: str) -> str:
    """Infer an evidence kind from a ref's shape (the `mship debug --evidence`
    convention): `test-runs/…` → test; a 7–40 char hex sha → commit; else artifact.
    Refs are advisory — never resolved or validated. Callers pass an explicit
    kind to override (e.g. `HEAD`, which is not hex, defaults to artifact here)."""
    if ref.startswith("test-runs/"):
        return "test"
    if _SHA_RE.match(ref):
        return "commit"
    return "artifact"


def set_criterion_evidence(
    spec: Spec, criterion_id: str, kind: str, ref: str, note: str | None = None,
) -> Spec:
    """Append one evidence entry to an acceptance criterion in place. Raises
    ValueError on an invalid kind or unknown criterion id (mirrors
    set_criterion_verdict). Does not change status or persist."""
    if kind not in EVIDENCE_KINDS:
        raise ValueError(
            f"invalid evidence kind {kind!r}; expected one of {', '.join(EVIDENCE_KINDS)}"
        )
    if criterion_id in PROSE_UNIT_IDS:
        raise ValueError(
            f"{criterion_id!r} is not an acceptance criterion; only acceptance "
            f"criteria (ac1, ac2, …) carry evidence in this version."
        )
    for c in spec.acceptance_criteria:
        if c.id == criterion_id:
            c.evidence.append(AcceptanceEvidence(kind=kind, ref=ref, note=note))
            return spec
    valid = ", ".join(c.id for c in spec.acceptance_criteria) or "(none)"
    raise ValueError(f"no acceptance criterion {criterion_id!r}; valid ids: {valid}")
```

Add `AcceptanceEvidence` to the existing spec import at the top of `spec_review.py`:

```python
from mship.core.spec import AcceptanceEvidence, Spec
```

- [ ] **Step 4: Implement the CLI command**

In `src/mship/cli/spec.py`, add an `evidence` command directly after the `verdict` command (mirror its structure; `Optional` is already imported at the top of the module):

```python
    @spec_app.command("evidence")
    def evidence(
        spec_id: str = typer.Argument(..., help="Spec id."),
        criterion_id: str = typer.Argument(..., help="Acceptance criterion id (e.g. ac1)."),
        ref: str = typer.Argument(
            ..., help="Evidence ref: test-runs/<iter>[.<repo>], a commit sha, or an artifact path/URL.",
        ),
        kind: Optional[str] = typer.Option(
            None, "--kind", help="test | commit | artifact. Inferred from the ref shape when omitted.",
        ),
        note: Optional[str] = typer.Option(None, "--note", help="Optional human note."),
    ):
        """Attach an evidence entry to one acceptance criterion (no status change)."""
        from datetime import datetime, timezone
        from pathlib import Path
        from mship.core.spec_store import SpecStore, SPECS_DIRNAME
        from mship.core.spec_review import infer_evidence_kind, set_criterion_evidence

        output = Output()
        container = get_container()
        workspace_root = Path(container.config_path()).parent
        store = SpecStore(workspace_root / SPECS_DIRNAME)
        spec = store.find_by_id(spec_id)
        if spec is None:
            output.error(f"No spec with id {spec_id!r}.")
            raise typer.Exit(1)

        resolved_kind = kind or infer_evidence_kind(ref)
        try:
            set_criterion_evidence(spec, criterion_id, resolved_kind, ref, note)
        except ValueError as e:
            output.error(str(e))
            raise typer.Exit(1)

        spec.updated_at = datetime.now(timezone.utc)
        path = store.save(spec)
        if output.human_mode:
            output.success(f"{criterion_id} += {resolved_kind}:{ref}: {path}")
        else:
            output.json({"id": spec.id, "criterion": criterion_id, "kind": resolved_kind, "ref": ref})
```

- [ ] **Step 5: Run to verify it passes**

Run: `uv run pytest tests/core/test_spec_review.py tests/cli/test_spec.py -v`
Expected: PASS (service + inference + CLI + existing spec_review/CLI regressions).

- [ ] **Step 6: Stage** (`git add`); orchestrator commits.
<!-- /mship:task -->

---

<!-- mship:task id=4 -->
### Task 4: `POST /specs/{spec_id}/evidence` endpoint

**Files:**
- Modify: `src/mship/core/serve.py` (add `EvidenceBody` DTO + `post_evidence` handler)
- Test: `tests/core/test_serve.py`

Mirror `post_verdict` + `VerdictBody`: a new `EvidenceBody` carries `criterion_id`, `ref`, an optional `kind` (inferred when omitted, same convenience as the CLI), and an optional `note`; the handler returns the review payload via `_save_and_review`. (Note: `build_review` doesn't SURFACE evidence until Task 5, so this task verifies persistence via `GET /specs/{id}`, whose `model_dump` already includes the field from Task 1.)

- [ ] **Step 1: Write the failing test**

In `tests/core/test_serve.py` (add near `test_post_verdict`):

```python
def test_post_evidence_persists_and_validates(tmp_path):
    _seed_spec(tmp_path)   # spec "dq" with one AC "ac1"
    client = TestClient(_app(tmp_path))

    r = client.post("/specs/dq/evidence", json={"criterion_id": "ac1", "ref": "test-runs/5"})
    assert r.status_code == 200
    # build_review surfacing is Task 5; verify persistence via the full spec dump.
    ac = client.get("/specs/dq").json()["acceptance_criteria"][0]
    assert ac["evidence"] == [{"kind": "test", "ref": "test-runs/5", "note": None}]

    # explicit kind override + note round-trips
    r2 = client.post(
        "/specs/dq/evidence",
        json={"criterion_id": "ac1", "ref": "HEAD", "kind": "commit", "note": "fix"},
    )
    assert r2.status_code == 200
    ev = client.get("/specs/dq").json()["acceptance_criteria"][0]["evidence"]
    assert ev[1] == {"kind": "commit", "ref": "HEAD", "note": "fix"}

    # bad criterion → 400; unknown spec → 404
    assert client.post("/specs/dq/evidence", json={"criterion_id": "nope", "ref": "x"}).status_code == 400
    assert client.post("/specs/none/evidence", json={"criterion_id": "ac1", "ref": "x"}).status_code == 404
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/core/test_serve.py -k evidence -v`
Expected: FAIL (no `/specs/{id}/evidence` route → 405/404).

- [ ] **Step 3: Implement the DTO + handler**

In `src/mship/core/serve.py`, add `EvidenceBody` next to `VerdictBody` (near the top of the module):

```python
class EvidenceBody(BaseModel):
    criterion_id: str
    ref: str
    kind: str | None = None
    note: str | None = None
```

In the `--- write endpoints ---` section, extend the spec_review import and add the handler directly after `post_verdict`:

```python
    from mship.core.spec_review import (
        infer_evidence_kind, set_criterion_evidence, set_criterion_verdict,
    )
```

```python
    @app.post("/specs/{spec_id}/evidence")
    def post_evidence(spec_id: str, body: EvidenceBody):
        spec = _load_or_404(spec_id)
        kind = body.kind or infer_evidence_kind(body.ref)
        try:
            set_criterion_evidence(spec, body.criterion_id, kind, body.ref, body.note)
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e))
        return _save_and_review(spec)
```

(The existing `from mship.core.spec_review import set_criterion_verdict` line is replaced by the combined import above — keep `set_criterion_verdict` in it.)

- [ ] **Step 4: Run to verify it passes**

Run: `uv run pytest tests/core/test_serve.py -v`
Expected: PASS (new evidence endpoint + existing serve suite).

- [ ] **Step 5: Stage** (`git add`); orchestrator commits.
<!-- /mship:task -->

---

<!-- mship:task id=5 -->
### Task 5: `build_review` surfaces evidence + `unverified`; CLI printout; approval-gate regression

**Files:**
- Modify: `src/mship/core/spec_review.py` (`build_review`)
- Modify: `src/mship/cli/spec.py` (the `review` human printout)
- Test: `tests/core/test_spec_review.py` (surface + unverified; UPDATE two existing exact-equality tests), `tests/cli/test_spec.py` (printout), `tests/core/test_spec_approve.py` (ac6 regression)

`build_review` gains per-AC `evidence` and a `summary.unverified` count (= number of ACs with an EMPTY evidence list). The CLI `review` printout shows each AC's evidence refs and the `unverified` total. This task ALSO adds the ac6 regression proving the approval gate is unchanged (approve succeeds with approved verdicts + zero evidence).

- [ ] **Step 1: Write the failing tests (and update the two exact-match ones)**

In `tests/core/test_spec_review.py`, add:

```python
def test_build_review_surfaces_evidence_and_unverified_count():
    now = datetime(2026, 7, 12, tzinfo=timezone.utc)
    spec = Spec(
        id="dq", title="DQ", status="needs_review", created_at=now, updated_at=now,
        acceptance_criteria=[
            AcceptanceCriterion(id="ac1", text="a", verdict="approved",
                                evidence=[AcceptanceEvidence(kind="test", ref="test-runs/5")]),
            AcceptanceCriterion(id="ac2", text="b"),   # no evidence
            AcceptanceCriterion(id="ac3", text="c"),   # no evidence
        ],
    )
    r = build_review(spec)
    assert r["acceptance_criteria"][0]["evidence"] == [
        {"kind": "test", "ref": "test-runs/5", "note": None}
    ]
    assert r["acceptance_criteria"][1]["evidence"] == []
    # unverified is EXACTLY the number of ACs with an empty evidence list.
    assert r["summary"]["unverified"] == 2
```

UPDATE the two existing exact-equality assertions in the same file (they will otherwise break — the AC dicts now carry an `evidence` key and the summary a `unverified` key):

- In `test_build_review_shapes_units_and_context`, add `"evidence": []` to each AC dict:
  ```python
      assert r["acceptance_criteria"] == [
          {"id": "ac1", "text": "view questions", "verdict": "approved", "evidence": []},
          {"id": "ac2", "text": "record answer", "verdict": "unreviewed", "evidence": []},
      ]
  ```
- In `test_build_review_summary_counts`, add `"unverified": 2` (the `_spec()` helper's two ACs both have empty evidence):
  ```python
      assert s == {
          "criteria_total": 2, "approved": 1, "flagged": 0, "unreviewed": 1,
          "unverified": 2, "open_questions_unanswered": 1,
      }
  ```

In `tests/cli/test_spec.py`, add a human-mode printout test (force TTY so the review command takes the human branch):

```python
def test_spec_review_human_shows_evidence_and_unverified(configured_app_with_task: Path, tmp_path, monkeypatch):
    from mship.cli.output import Output
    monkeypatch.setattr(Output, "is_tty", property(lambda self: True))
    _apply_dq(tmp_path)   # ac1, no evidence yet
    runner.invoke(app, ["spec", "evidence", "dq", "ac1", "test-runs/7"])
    result = runner.invoke(app, ["spec", "review", "dq"])
    assert result.exit_code == 0, result.output
    assert "test-runs/7" in result.output          # the evidence ref is shown
    assert "unverified" in result.output.lower()    # summary carries the count
```

In `tests/core/test_spec_approve.py`, add the ac6 regression:

```python
from mship.core.spec import AcceptanceEvidence


def test_approval_gate_unchanged_approved_verdicts_zero_evidence():
    """ac6: evidence is NEVER required to approve. A spec with all verdicts
    approved and NO evidence has no approval blockers."""
    s = _spec(criteria=[AcceptanceCriterion(id="ac1", text="x", verdict="approved")])
    assert all(c.evidence == [] for c in s.acceptance_criteria)
    assert approval_blockers(s) == []
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/core/test_spec_review.py tests/cli/test_spec.py -k "review" tests/core/test_spec_approve.py -v`
Expected: FAIL (`evidence` / `unverified` not in payload; the printout lacks the ref/count). The ac6 regression should already PASS — that is intentional; it guards `approval_blockers` staying untouched.

- [ ] **Step 3: Implement `build_review`**

In `src/mship/core/spec_review.py`, extend the per-AC dict and the summary:

```python
        "acceptance_criteria": [
            {
                "id": c.id,
                "text": c.text,
                "verdict": c.verdict,
                "evidence": [
                    {"kind": e.kind, "ref": e.ref, "note": e.note} for e in c.evidence
                ],
            }
            for c in spec.acceptance_criteria
        ],
```

and in the `"summary"` dict add the `unverified` count:

```python
        "summary": {
            "criteria_total": len(spec.acceptance_criteria),
            "approved": counts["approved"],
            "flagged": counts["flagged"],
            "unreviewed": counts["unreviewed"],
            "unverified": sum(1 for c in spec.acceptance_criteria if not c.evidence),
            "open_questions_unanswered": sum(
                1 for q in spec.open_questions if q.answer is None
            ),
        },
```

**Do NOT touch `src/mship/core/spec_approve.py`.** Evidence stays out of the approval gate by lifecycle design (ac6).

- [ ] **Step 4: Implement the CLI printout**

In `src/mship/cli/spec.py`, in the `review` command's `human_mode` branch, print each AC's evidence and add `unverified` to the summary line:

```python
            for c in payload["acceptance_criteria"]:
                output.print(f"  [{c['verdict']}] {c['id']}: {c['text']}")
                for ev in c["evidence"]:
                    note = f" ({ev['note']})" if ev.get("note") else ""
                    output.print(f"      · {ev['kind']}: {ev['ref']}{note}")
            s = payload["summary"]
            output.print(
                f"  summary: {s['approved']} approved, {s['flagged']} flagged, "
                f"{s['unreviewed']} unreviewed, {s['unverified']} unverified; "
                f"{s['open_questions_unanswered']} open question(s)"
            )
```

- [ ] **Step 5: Run to verify it passes**

Run: `uv run pytest tests/core/test_spec_review.py tests/cli/test_spec.py tests/core/test_spec_approve.py tests/core/test_serve.py -v`
Expected: PASS (surface + printout + ac6 regression; serve's `test_get_review` still green with the widened payload).

- [ ] **Step 6: Stage** (`git add`); orchestrator commits.
<!-- /mship:task -->

---

<!-- mship:task id=6 -->
### Task 6: `mship commit` journals the commit sha into `LogEntry.evidence`

**Files:**
- Modify: `src/mship/cli/commit.py`
- Test: `tests/cli/test_commit.py`

`LogEntry.evidence` already exists (`core/log.py`) and `commit.py` already captures the sha via `git rev-parse HEAD` (into `sha`) BEFORE journaling — it just never records it. Pass `evidence=sha or None` on the `log_mgr.append` call so a `commit:<sha>` evidence ref is resolvable from the journal (ac7).

- [ ] **Step 1: Write the failing test**

In `tests/cli/test_commit.py` (mirror `test_commit_pre_finish_single_repo`; the mock returns `7f3a1b2abcdef` for `git rev-parse HEAD`):

```python
def test_commit_journals_commit_sha_as_evidence(configured_git_app: Path):
    runner.invoke(app, ["spawn", "--hotfix", "evidence commit", "--repos", "shared"])
    slug = "evidence-commit"

    def mock_run(cmd, cwd, env=None):
        if "git diff --cached --quiet" in cmd:
            return ShellResult(returncode=1, stdout="", stderr="")
        if "git commit -m" in cmd:
            return ShellResult(returncode=0, stdout="", stderr="")
        if "git rev-parse HEAD" in cmd:
            return ShellResult(returncode=0, stdout="7f3a1b2abcdef\n", stderr="")
        return ShellResult(returncode=0, stdout="", stderr="")

    mock_shell = MagicMock(spec=ShellRunner)
    mock_shell.run.side_effect = mock_run
    container.shell.override(mock_shell)
    try:
        result = runner.invoke(app, ["commit", "fix: typo", "--task", slug])
        assert result.exit_code == 0, result.output
        log = (configured_git_app / ".mothership" / "logs" / f"{slug}.md").read_text()
        assert 'evidence="7f3a1b2abcdef"' in log
        assert "action=committed" in log
    finally:
        container.shell.reset_override()
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/cli/test_commit.py -k evidence -v`
Expected: FAIL (no `evidence=` kv is written today).

- [ ] **Step 3: Implement**

In `src/mship/cli/commit.py`, change the `log_mgr.append` call inside the per-repo loop to carry the sha (the `sha` variable is already computed just above it):

```python
            log_mgr.append(
                t.slug, message, repo=repo_name, action="committed",
                evidence=sha or None,
            )
```

- [ ] **Step 4: Run to verify it passes**

Run: `uv run pytest tests/cli/test_commit.py -v`
Expected: PASS (new evidence-journaling test + the existing commit suite).

- [ ] **Step 5: Stage** (`git add`); orchestrator commits.
<!-- /mship:task -->

---

# Slice B — PR-b (enforcement) — branch off `main` AFTER PR-a merges

<!-- mship:task id=7 -->
### Task 7: shared `resolve_bound_spec` + `_gate_review` AC-evidence warnings

**Files:**
- Modify: `src/mship/core/workitem_gate.py` (add `resolve_bound_spec`)
- Modify: `src/mship/core/phase.py` (`_gate_review` appends unverified-AC warnings)
- Test: `tests/test_workitem_gate.py` (resolver), `tests/core/test_phase.py` (warn-not-block)

Both enforcement sites (this task's phase gate and Task 8's finish gate) need to resolve the spec bound to a task. Add ONE shared `resolve_bound_spec(task, workspace_root) -> Spec | None` in `workitem_gate.py`, reusing the exact `SpecStore` / `WorkItemStore` resolution the WorkItem gate + `PhaseManager._has_approved_spec` already use (WorkItem's `spec_id` first, then a `task_slug` match); it never raises (a missing/corrupt store yields `None`, so the AC gate becomes a no-op). Then `_gate_review` appends WARNING lines for bound-spec ACs with no evidence, next to the existing test-evidence warning — never blocking.

- [ ] **Step 1: Write the failing tests**

In `tests/test_workitem_gate.py` (imports at the top already pull `check_task_gate`, `GateResult`, `WorkItemStore`, `SpecStore`, `Spec`, `Task`; add `resolve_bound_spec`):

```python
from mship.core.workitem_gate import check_task_gate, resolve_bound_spec


def test_resolve_bound_spec_via_workitem_spec_id(tmp_path):
    from datetime import datetime, timezone
    now = datetime(2026, 7, 12, tzinfo=timezone.utc)
    items = WorkItemStore(tmp_path / ".mothership" / "workitems")
    wi = items.create(title="F", kind="feature", workspace="ws", now=now)
    SpecStore(tmp_path / "specs").save(Spec(id="s1", title="S", status="approved",
                                            created_at=now, updated_at=now))
    items.link_spec(wi.id, "s1", now=now)
    task = Task(slug="t", description="d", phase="dev", created_at=now,
                affected_repos=["shared"], branch="feat/t", work_item_id=wi.id)
    assert resolve_bound_spec(task, tmp_path).id == "s1"


def test_resolve_bound_spec_via_task_slug_fallback(tmp_path):
    from datetime import datetime, timezone
    now = datetime(2026, 7, 12, tzinfo=timezone.utc)
    SpecStore(tmp_path / "specs").save(Spec(id="s2", title="S", status="approved",
                                            created_at=now, updated_at=now, task_slug="t"))
    task = Task(slug="t", description="d", phase="dev", created_at=now,
                affected_repos=["shared"], branch="feat/t")
    assert resolve_bound_spec(task, tmp_path).id == "s2"


def test_resolve_bound_spec_none_when_unbound(tmp_path):
    from datetime import datetime, timezone
    now = datetime(2026, 7, 12, tzinfo=timezone.utc)
    task = Task(slug="t", description="d", phase="dev", created_at=now,
                affected_repos=["shared"], branch="feat/t")
    assert resolve_bound_spec(task, tmp_path) is None
```

(Confirm the exact top-of-file imports in `tests/test_workitem_gate.py` and match them — if `Task`/`Spec`/`SpecStore` aren't imported yet, add them.)

In `tests/core/test_phase.py` (uses the existing `state_with_task` fixture — a bug WI so plan→dev passes — and `_make_phase_manager`):

```python
def test_transition_to_review_warns_on_acs_without_evidence(state_with_task, tmp_path):
    """ac8: entering review WARNs listing bound-spec ACs with no evidence, and
    never blocks the transition."""
    from mship.core.spec import AcceptanceCriterion, Spec
    from mship.core.spec_store import SpecStore
    now = datetime(2026, 4, 10, tzinfo=timezone.utc)
    SpecStore(tmp_path / "specs").save(Spec(
        id="add-labels-spec", title="S", status="approved",
        created_at=now, updated_at=now, task_slug="add-labels",
        acceptance_criteria=[AcceptanceCriterion(id="ac1", text="x", verdict="approved")],
    ))
    pm = _make_phase_manager(state_with_task, tmp_path)
    pm.transition("add-labels", "dev")
    result = pm.transition("add-labels", "review")
    assert result.new_phase == "review"                                   # never blocks
    assert any("evidence" in w.lower() and "ac1" in w for w in result.warnings)


def test_transition_to_review_no_ac_warning_without_bound_spec(state_with_task, tmp_path):
    pm = _make_phase_manager(state_with_task, tmp_path)
    pm.transition("add-labels", "dev")
    result = pm.transition("add-labels", "review")
    assert not any("evidence" in w.lower() and "acceptance" in w.lower()
                   for w in result.warnings)
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/test_workitem_gate.py -k resolve_bound tests/core/test_phase.py -k "without_evidence or no_ac_warning" -v`
Expected: FAIL (`resolve_bound_spec` doesn't exist; `_gate_review` emits no AC warning).

- [ ] **Step 3: Implement `resolve_bound_spec`**

In `src/mship/core/workitem_gate.py`, add (module-level; the `SpecStore` / `WorkItemStore` imports already exist at the top of the file):

```python
def resolve_bound_spec(task, workspace_root: Path):
    """Return the Spec bound to `task` (its WorkItem's spec_id, else a spec whose
    task_slug matches), or None. Reuses the SpecStore/WorkItemStore resolution the
    WorkItem gate + PhaseManager._has_approved_spec already use. Never raises — a
    missing/corrupt store yields None, so the AC-evidence gate is simply a no-op."""
    try:
        specs = SpecStore(Path(workspace_root) / "specs")
        wi_id = getattr(task, "work_item_id", None)
        if wi_id is not None:
            wi = WorkItemStore(Path(workspace_root) / ".mothership" / "workitems").get(wi_id)
            if wi is not None and wi.spec_id:
                bound = specs.find_by_id(wi.spec_id)
                if bound is not None:
                    return bound
        for s in specs.list():
            if s.task_slug == task.slug:
                return s
    except Exception:
        return None
    return None
```

- [ ] **Step 4: Wire `_gate_review`**

In `src/mship/core/phase.py`, extend `_gate_review` to append AC-evidence warnings after the existing test-evidence lines, plus a small private helper:

```python
    def _gate_review(self, task) -> list[str]:
        # Unified reader honors both task.test_results and journal
        # `test_state=pass` entries so explicit evidence suppresses the
        # warning. See #81.
        from mship.core.test_evidence import format_missing_summary, read_evidence

        evidence = read_evidence(task, self._log)
        lines = format_missing_summary(evidence)
        if lines:
            hint = " — consider running tests before review"
            warnings = [lines[0] + hint] + lines[1:]
        else:
            warnings = []
        # AC-evidence warnings (ac8): soft, never blocks; no bound spec ⇒ no-op.
        warnings.extend(self._unverified_ac_warnings(task))
        return warnings

    def _unverified_ac_warnings(self, task) -> list[str]:
        """WARNING lines listing bound-spec acceptance criteria with no evidence.
        Loads the task's bound spec via the shared resolver (self._workspace_root
        + SpecStore, same pattern as _has_approved_spec). Never blocks."""
        if self._workspace_root is None:
            return []
        from mship.core.workitem_gate import resolve_bound_spec

        spec = resolve_bound_spec(task, self._workspace_root)
        if spec is None:
            return []
        missing = [c.id for c in spec.acceptance_criteria if not c.evidence]
        if not missing:
            return []
        return [
            f"Acceptance criteria without evidence: {', '.join(missing)} "
            f"— attach with `mship spec evidence {spec.id} <ac> <ref>`"
        ]
```

- [ ] **Step 5: Run to verify it passes**

Run: `uv run pytest tests/test_workitem_gate.py tests/core/test_phase.py -v`
Expected: PASS (resolver + warn-not-block; the existing phase/gate suites stay green).

- [ ] **Step 6: Stage** (`git add`); orchestrator commits.
<!-- /mship:task -->

---

<!-- mship:task id=8 -->
### Task 8: `mship finish` AC-evidence gate + `--require-evidence`

**Files:**
- Modify: `src/mship/cli/worktree.py` (`finish` signature + gate block after the test-evidence gate)
- Test: `tests/test_finish_gate.py`

Mirror the existing test-evidence gate (`worktree.py` ~1308–1353): resolve the bound spec via `resolve_bound_spec`; if any AC lacks evidence, WARN by default and BLOCK only under a new `--require-evidence` flag (shaped exactly like `--require-tests`). No bound spec ⇒ no-op. Introduce `bound_spec = resolve_bound_spec(task, workspace_root)` here — Task 9 reuses it for the PR body.

- [ ] **Step 1: Write the failing tests**

In `tests/test_finish_gate.py` (uses the `finish_gate_workspace` fixture + the `_write_plan` helper; add an approved-spec-with-AC seeder):

```python
def _seed_feature_with_ac(workspace: Path, *, ac_evidence=None):
    """Feature WI + approved spec whose ac1 has (or lacks) evidence, linked so
    resolve_bound_spec finds it via wi.spec_id."""
    from mship.core.spec import AcceptanceCriterion, Spec
    items = WorkItemStore(workspace / ".mothership" / "workitems")
    specs = SpecStore(workspace / "specs")
    now = datetime.now(timezone.utc)
    specs.save(Spec(id="ev-spec", title="S", status="approved", created_at=now, updated_at=now,
                    acceptance_criteria=[AcceptanceCriterion(
                        id="ac1", text="x", verdict="approved", evidence=ac_evidence or [])]))
    wi = items.create(title="add thing", kind="feature", workspace="ws", now=now)
    items.link_spec(wi.id, "ev-spec", now=now)
    return wi


def test_finish_warns_by_default_on_acs_without_evidence(finish_gate_workspace):
    workspace, _ = finish_gate_workspace
    wi = _seed_feature_with_ac(workspace)   # ac1 has NO evidence
    runner.invoke(app, ["spawn", "--work-item", wi.id, "ev warn", "--repos", "shared"])
    _write_plan(workspace, "ev-warn")       # plan-gate satisfied
    result = runner.invoke(app, ["finish", "--task", "ev-warn"])
    assert result.exit_code == 0, result.output          # WARN only → still finishes
    assert "evidence" in result.output.lower()
    state = StateManager(workspace / ".mothership").load()
    assert state.tasks["ev-warn"].pr_urls.get("shared") == "https://github.com/org/shared/pull/1"


def test_finish_blocks_under_require_evidence(finish_gate_workspace):
    workspace, _ = finish_gate_workspace
    wi = _seed_feature_with_ac(workspace)   # ac1 has NO evidence
    runner.invoke(app, ["spawn", "--work-item", wi.id, "ev block", "--repos", "shared"])
    _write_plan(workspace, "ev-block")
    result = runner.invoke(app, ["finish", "--task", "ev-block", "--require-evidence"])
    assert result.exit_code == 1, result.output
    assert "evidence" in result.output.lower()
    state = StateManager(workspace / ".mothership").load()
    assert state.tasks["ev-block"].pr_urls == {}          # blocked before any PR


def test_finish_require_evidence_noop_without_bound_spec(finish_gate_workspace):
    """No bound spec (a bug WI) ⇒ --require-evidence is a no-op, not a block."""
    workspace, _ = finish_gate_workspace
    items = WorkItemStore(workspace / ".mothership" / "workitems")
    wi = items.create(title="fix it", kind="bug", workspace="ws", now=datetime.now(timezone.utc))
    runner.invoke(app, ["spawn", "--work-item", wi.id, "ev noop", "--repos", "shared"])
    result = runner.invoke(app, ["finish", "--task", "ev-noop", "--require-evidence"])
    assert result.exit_code == 0, result.output
    state = StateManager(workspace / ".mothership").load()
    assert state.tasks["ev-noop"].pr_urls.get("shared") == "https://github.com/org/shared/pull/1"
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/test_finish_gate.py -k "evidence or require_evidence or noop" -v`
Expected: FAIL (no `--require-evidence` option; no AC gate).

- [ ] **Step 3: Add the `--require-evidence` option**

In `src/mship/cli/worktree.py`, in the `finish` signature, add directly after the `require_tests` option:

```python
        require_evidence: bool = typer.Option(
            False, "--require-evidence",
            help="Block finish when any acceptance criterion on the bound spec lacks "
                 "evidence. Default: WARN only. Mirrors --require-tests. "
                 "See ac-evidence-loop.",
        ),
```

- [ ] **Step 4: Add the gate block**

In `src/mship/cli/worktree.py`, immediately after the test-evidence gate block (after the `output.warning(...)` that ends at ~line 1353, before `pr_list: list[dict] = []`), add:

```python
        # --- Acceptance-criteria evidence gate (ac-evidence-loop) ---
        # Mirror the test-evidence gate: WARN by default when any AC on the bound
        # spec lacks evidence; BLOCK only with --require-evidence. Resolve the spec
        # via the task's WorkItem link; no bound spec ⇒ no-op. `bound_spec` is
        # reused by the PR-body assembly below (build_acceptance_block).
        from mship.core.workitem_gate import resolve_bound_spec
        bound_spec = resolve_bound_spec(task, workspace_root)
        if bound_spec is not None:
            unverified_acs = [c.id for c in bound_spec.acceptance_criteria if not c.evidence]
            if unverified_acs:
                if require_evidence:
                    output.error("Acceptance criteria without evidence — blocking finish (--require-evidence):")
                    output.error(f"  {bound_spec.id}: {', '.join(unverified_acs)}")
                    output.error(
                        "Attach evidence via `mship spec evidence <spec> <ac> <ref>`, then retry."
                    )
                    raise typer.Exit(code=1)
                output.warning("Acceptance-criteria evidence warnings:")
                output.warning(f"  {bound_spec.id}: {', '.join(unverified_acs)} lack evidence")
                output.warning(
                    "Pass `--require-evidence` to treat as blocking, or attach evidence via "
                    "`mship spec evidence <spec> <ac> <ref>`."
                )
```

- [ ] **Step 5: Run to verify it passes**

Run: `uv run pytest tests/test_finish_gate.py -v`
Expected: PASS (warn / block / no-op + the existing finish-gate suite).

- [ ] **Step 6: Stage** (`git add`); orchestrator commits.
<!-- /mship:task -->

---

<!-- mship:task id=9 -->
### Task 9: `build_acceptance_block` + inject into the finish PR body

**Files:**
- Modify: `src/mship/core/pr.py` (add `build_acceptance_block`)
- Modify: `src/mship/cli/worktree.py` (compute the block; append to `pr_body`)
- Test: `tests/core/test_pr.py` (rendering), `tests/test_finish_gate.py` (appended to body)

Add a module-level `build_acceptance_block(spec) -> str` in `pr.py` (the pure analogue of `PRManager.build_coordination_block`: a leading-separator markdown block, or `""` when there's nothing to render). Inject its output into the PR body at the finish body-assembly site, reusing the `bound_spec` variable Task 8 introduced.

- [ ] **Step 1: Write the failing tests**

In `tests/core/test_pr.py`:

```python
def _spec_with_acs(acs):
    from datetime import datetime, timezone
    from mship.core.spec import Spec
    now = datetime(2026, 7, 12, tzinfo=timezone.utc)
    return Spec(id="dq", title="DQ", status="approved", created_at=now, updated_at=now,
                acceptance_criteria=acs)


def test_build_acceptance_block_renders_verified_and_unverified():
    from mship.core.pr import build_acceptance_block
    from mship.core.spec import AcceptanceCriterion, AcceptanceEvidence
    spec = _spec_with_acs([
        AcceptanceCriterion(id="ac1", text="does X", verdict="approved",
                            evidence=[AcceptanceEvidence(kind="test", ref="test-runs/5")]),
        AcceptanceCriterion(id="ac2", text="does Y"),   # no evidence
    ])
    block = build_acceptance_block(spec)
    assert "## Acceptance criteria" in block
    assert "ac1" in block and "test:test-runs/5" in block   # verified with its ref
    assert "ac2" in block and "no evidence" in block.lower()  # unverified


def test_build_acceptance_block_empty_when_no_criteria():
    from mship.core.pr import build_acceptance_block
    assert build_acceptance_block(_spec_with_acs([])) == ""
```

In `tests/test_finish_gate.py` (reuse the `_seed_feature_with_ac` helper from Task 8; inspect the `gh pr create` command the mocked shell received):

```python
def test_finish_appends_acceptance_block_to_pr_body(finish_gate_workspace):
    from mship.core.spec import AcceptanceEvidence
    workspace, mock_shell = finish_gate_workspace
    wi = _seed_feature_with_ac(
        workspace, ac_evidence=[AcceptanceEvidence(kind="test", ref="test-runs/1")],
    )
    runner.invoke(app, ["spawn", "--work-item", wi.id, "ev body", "--repos", "shared"])
    _write_plan(workspace, "ev-body")
    result = runner.invoke(app, ["finish", "--task", "ev-body"])
    assert result.exit_code == 0, result.output
    create_cmds = [c.args[0] for c in mock_shell.run.call_args_list if "gh pr create" in c.args[0]]
    assert create_cmds, "expected a gh pr create call"
    assert "Acceptance criteria" in create_cmds[0]   # block injected into the PR body
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/core/test_pr.py -k acceptance_block tests/test_finish_gate.py -k appends -v`
Expected: FAIL (`build_acceptance_block` doesn't exist; body has no AC section).

- [ ] **Step 3: Implement `build_acceptance_block`**

In `src/mship/core/pr.py`, add a module-level function (mirroring the shape of `build_coordination_block`):

```python
def build_acceptance_block(spec) -> str:
    """Render an 'Acceptance criteria' PR-body section listing each AC as verified
    (with its evidence refs) or unverified. Pure analogue of
    PRManager.build_coordination_block: returns '' when there is nothing to render
    (no criteria), else a leading-separator markdown block ready to append to a
    PR body."""
    acs = getattr(spec, "acceptance_criteria", None) or []
    if not acs:
        return ""
    lines = [
        "",
        "---",
        "",
        "## Acceptance criteria",
        "",
    ]
    for c in acs:
        if c.evidence:
            refs = ", ".join(f"{e.kind}:{e.ref}" for e in c.evidence)
            lines.append(f"- [x] `{c.id}` {c.text} — {refs}")
        else:
            lines.append(f"- [ ] `{c.id}` {c.text} — _no evidence_")
    return "\n".join(lines)
```

- [ ] **Step 4: Inject into the finish PR body**

In `src/mship/cli/worktree.py`, right after Task 8's AC-evidence gate block (where `bound_spec` is in scope, before the `for i, group in enumerate(groups, 1):` loop), compute the block once:

```python
        from mship.core.pr import build_acceptance_block
        acceptance_block = build_acceptance_block(bound_spec) if bound_spec is not None else ""
```

Then in the body-assembly site (the fresh-PR branch, right after `pr_body = append_closes_footer(pr_body_base, extract_issue_refs(texts))`), append it:

```python
                pr_body = append_closes_footer(pr_body_base, extract_issue_refs(texts))
                if acceptance_block:
                    pr_body = pr_body + acceptance_block
```

- [ ] **Step 5: Run to verify it passes**

Run: `uv run pytest tests/core/test_pr.py tests/test_finish_gate.py -v`
Expected: PASS (rendering unit tests + the appended-to-body integration + the full finish-gate suite).

- [ ] **Step 6: Stage** (`git add`); orchestrator commits.
<!-- /mship:task -->

---

## Final review

After all Slice-B tasks: full `uv run mship test` green; dispatch a spec-compliance reviewer over the whole diff vs the spec (ac1–ac11) — checking especially that `approval_blockers` is byte-for-byte unchanged (ac6) and that both gates never fire at approval time. Confirm PR-a (Tasks 1–6) merged first and PR-b (Tasks 7–9) branched off `main` afterward and touches no schema (ac11). Then `mship finish` each slice.

## Self-review

Every one of the 11 spec acceptance criteria maps to a task (or, for ac11, to the delivery structure):

| Spec AC | Delivered by | What proves it |
|---------|--------------|----------------|
| ac1 (evidence field; legacy load; lossless round-trip) | **Task 1** | round-trip + legacy-no-key + kind-validation tests |
| ac2 (apply_draft preserves evidence+verdict for unchanged AC; fresh on material change) | **Task 2** | preserve + reset tests (both branches) |
| ac3 (`set_criterion_evidence` service + `mship spec evidence` CLI; validates ac_id + kind; infers kind) | **Task 3** | service, `infer_evidence_kind`, CLI (infer + `--kind` + `--note` + unknown-id) tests |
| ac4 (`POST /specs/{id}/evidence` returns the review payload, mirrors POST /verdict) | **Task 4** | `EvidenceBody` + `post_evidence`; TestClient persist/400/404 test |
| ac5 (`build_review` surfaces per-AC evidence + `unverified` count) | **Task 5** | surface test; `unverified` == #ACs with empty evidence; CLI printout test |
| ac6 (approval gate unchanged; approvable with verdicts approved + zero evidence) | **Task 5** | `spec_approve.py` untouched + explicit `approval_blockers` regression test |
| ac7 (`mship commit` records commit sha in `LogEntry.evidence`) | **Task 6** | journal carries `evidence="<sha>"` test |
| ac8 (`phase dev→review` WARNs on evidence-less ACs; never blocks) | **Task 7** | `resolve_bound_spec` + `_gate_review`; warn-but-`new_phase==review` test |
| ac9 (`finish` WARNs by default, BLOCKs under `--require-evidence`; no-bound-spec no-op) | **Task 8** | warn / block / no-op finish-gate tests |
| ac10 (PR body gains an 'Acceptance criteria' section via `build_acceptance_block`) | **Task 9** | rendering (verified vs unverified) + appended-to-PR-body tests |
| ac11 (Slice A = PR-a mergeable alone; Slice B = PR-b revertable without touching the schema) | **delivery structure** (see "## PR mapping") | Tasks 1–6 = PR-a; Tasks 7–9 = PR-b off `main`, no `spec.py` changes — no code task |

**Type consistency (spelled identically across all tasks):** `AcceptanceEvidence`, `AcceptanceCriterion.evidence`, `EVIDENCE_KINDS`, `infer_evidence_kind`, `set_criterion_evidence`, `EvidenceBody`, `resolve_bound_spec`, `build_acceptance_block`, `--require-evidence`, `summary.unverified`.

**Ordering / dependencies:** PR-a is self-contained and strictly additive (T1→T2→T3→T4→T5→T6). PR-b builds on PR-a's `evidence` field only: T7 introduces the shared `resolve_bound_spec` (used by T8 + T9) and the phase warning; T8 adds the finish gate and the `bound_spec` variable; T9 reuses `bound_spec` + adds `build_acceptance_block`. Build serially (MOS-233).
