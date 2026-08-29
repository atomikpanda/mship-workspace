# Queue v2 (review + decision queue) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `gc-review-decision-queue-v2` (approved + dispatched) — `specs/2026-07-13-gc-review-decision-queue-v2.md`

**Goal:** Reframe Ground Control's Queue to source `needs_review` spec **chunks** (prose sections + acceptance criteria + open questions) and open **decisions** as one-card-at-a-time review, with per-prose-section verdicts (MOS-172) and flag-with-comment (MOS-217) on the serve Spec model.

**Architecture:** Serve foundations first (a `prose_verdicts` map + `ProseVerdict` on `Spec`, a `set_prose_verdict` core fn that flips the existing `PROSE_UNIT_IDS` rejection into acceptance, a `POST /specs/{id}/prose-verdict` endpoint, an `AcceptanceCriterion.comment` for flag-with-comment, apply_draft preservation, and a **backward-compatible** approve gate), then the GC rework (source specs→chunk-cards + threads→decision-cards; card-stack UI with directional swipe / comment sheet / per-item verdicts / Skip). Reworks the four MOS-225 Queue files in place.

**Tech Stack:** mothership serve — Python, Pydantic, FastAPI, pytest + TestClient. Ground Control — Kotlin, Compose/Material3, Ktor + kotlinx.serialization; JUnit4 + Ktor MockEngine (JVM unit tests only).

**Sequencing (three PRs, check in at each boundary):**
- **PR1 — serve foundations** (Tasks 1–7): `mothership`. Prose verdicts + flag-comment + gate. Independently shippable + fully backward-compatible.
- **PR2 — GC sourcing** (Tasks 8–10): `ground-control`. Card model + source specs/threads → cards.
- **PR3 — GC card-stack UI** (Tasks 11–14): `ground-control`. Rework ViewModel + Screen for approve-all/reject/per-item/skip.

**Conventions (verified):** mothership `src/mship/`, tests `tests/` (`uv run pytest -q` from `mothership/`). Prose section ids = `{problem, user_story, approach, non_goals, risks, scope_risk}` (`core/spec_review.py:9-11`). GC pkg `com.atomikpanda.groundcontrol`, tests flat, `./gradlew testDebugUnitTest` (source `~/toolchains/android-env.sh`). Commit + `mship journal` per task.

---

## File Structure

**PR1 (mothership):**
- Modify `src/mship/core/spec.py` — add `ProseVerdict` model + `Spec.prose_verdicts` + `AcceptanceCriterion.comment`.
- Modify `src/mship/core/spec_review.py` — `set_prose_verdict`, `set_criterion_verdict` gains `comment`, `build_review` emits `prose_verdicts` + criterion comment.
- Modify `src/mship/core/spec_approve.py` — backward-compat prose blockers.
- Modify `src/mship/core/spec_draft.py` — apply_draft preserves prose verdicts.
- Modify `src/mship/core/serve.py` — `ProseVerdictBody` + `POST /specs/{id}/prose-verdict` + `VerdictBody.comment`.
- Tests: `tests/core/test_spec_review.py` (invert the prose-reject test + add prose-verdict), `test_spec_approve.py`, `test_spec_draft.py`, `test_serve.py`.

**PR2/PR3 (ground-control):** rework `data/QueueRepository.kt`, `ui/queue/QueueCard.kt`, `ui/queue/QueueViewModel.kt`, `ui/queue/QueueScreen.kt`; add prose-verdict/flag-comment to `data/MshipClient.kt` + `data/dto/SpecDetailDtos.kt`; source via `data/SpecRepository.kt`. Reuse `ui/messages/DecisionCard.kt` + its `CommentSheet`, and `ui/specdetail`'s `CriterionRow` Check/Flag toggles + `write()` 409-gate handling.

---

<!-- mship:task id=1 -->
### Task 1: PR1 — `ProseVerdict` model + `Spec.prose_verdicts` + `AcceptanceCriterion.comment`

**Files:**
- Modify: `mothership/src/mship/core/spec.py`
- Test: `mothership/tests/core/test_spec_model.py` (create if absent)

- [ ] **Step 1: Write the failing test**

```python
# mothership/tests/core/test_spec_model.py
from datetime import datetime, timezone
from mship.core.spec import AcceptanceCriterion, ProseVerdict, Spec


def _now():
    return datetime(2026, 7, 13, tzinfo=timezone.utc)


def test_spec_carries_prose_verdicts_and_criterion_comment():
    s = Spec(
        id="s1", title="T", status="needs_review", created_at=_now(), updated_at=_now(),
        acceptance_criteria=[AcceptanceCriterion(id="ac1", text="x", verdict="flagged", comment="fix this")],
        prose_verdicts={"problem": ProseVerdict(verdict="approved"),
                        "approach": ProseVerdict(verdict="flagged", comment="unclear")},
    )
    assert s.prose_verdicts["approach"].comment == "unclear"
    assert s.acceptance_criteria[0].comment == "fix this"
    # round-trips through model_dump (what GET /specs/{id} + frontmatter use)
    dumped = s.model_dump(mode="json")
    assert dumped["prose_verdicts"]["problem"]["verdict"] == "approved"
    assert dumped["acceptance_criteria"][0]["comment"] == "fix this"


def test_prose_verdicts_defaults_empty():
    s = Spec(id="s1", title="T", status="draft", created_at=_now(), updated_at=_now())
    assert s.prose_verdicts == {}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd mothership && uv run pytest -q tests/core/test_spec_model.py`
Expected: FAIL — `ProseVerdict` unresolved / `comment`/`prose_verdicts` unknown fields.

- [ ] **Step 3: Add the model**

In `src/mship/core/spec.py`, add a `comment` to `AcceptanceCriterion` and a `ProseVerdict` model + `prose_verdicts` on `Spec`:

```python
class AcceptanceCriterion(BaseModel):
    id: str
    text: str
    verdict: Literal["unreviewed", "approved", "flagged"] = "unreviewed"
    evidence: list[AcceptanceEvidence] = []
    comment: str | None = None
```

```python
class ProseVerdict(BaseModel):
    verdict: Literal["unreviewed", "approved", "flagged"] = "unreviewed"
    comment: str | None = None
```

On `Spec` (after `clarification_reason`):

```python
    prose_verdicts: dict[str, ProseVerdict] = {}
```

- [ ] **Step 4: Run to verify it passes**

Run: `uv run pytest -q tests/core/test_spec_model.py`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/spec.py tests/core/test_spec_model.py
git commit -m "feat(spec): ProseVerdict model + Spec.prose_verdicts + AcceptanceCriterion.comment (MOS-172/217)"
mship journal "Spec model gains prose_verdicts + criterion comment; tests passing" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=2 -->
### Task 2: PR1 — `set_prose_verdict` (flip the PROSE_UNIT_IDS rejection) + criterion comment

**Files:**
- Modify: `mothership/src/mship/core/spec_review.py`
- Test: `mothership/tests/core/test_spec_review.py`

- [ ] **Step 1: Update the tests** — invert the existing "rejects prose unit" test and add prose-verdict + comment tests

Replace `test_set_criterion_verdict_rejects_prose_unit` (currently at `test_spec_review.py:94-96`) and add:

```python
def test_set_prose_verdict_accepts_a_prose_section():
    from mship.core.spec_review import set_prose_verdict
    s = _spec()
    set_prose_verdict(s, "approach", "flagged", comment="unclear")
    assert s.prose_verdicts["approach"].verdict == "flagged"
    assert s.prose_verdicts["approach"].comment == "unclear"


def test_set_prose_verdict_rejects_unknown_section():
    from mship.core.spec_review import set_prose_verdict
    import pytest
    with pytest.raises(ValueError, match="not a prose section"):
        set_prose_verdict(_spec(), "bogus", "approved")


def test_set_prose_verdict_rejects_bad_verdict():
    from mship.core.spec_review import set_prose_verdict
    import pytest
    with pytest.raises(ValueError, match="invalid verdict"):
        set_prose_verdict(_spec(), "problem", "bogus")


def test_set_criterion_verdict_stores_comment():
    s = _spec()  # _spec() should include an ac1
    set_criterion_verdict(s, "ac1", "flagged", comment="needs work")
    assert s.acceptance_criteria[0].comment == "needs work"
```

(Ensure `_spec()` in this test file seeds an `ac1`; the existing helper does.)

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest -q tests/core/test_spec_review.py`
Expected: FAIL — `set_prose_verdict` unresolved; `set_criterion_verdict` has no `comment` kwarg.

- [ ] **Step 3: Implement**

In `src/mship/core/spec_review.py`, add `set_prose_verdict` and give `set_criterion_verdict` a `comment`:

```python
def set_criterion_verdict(spec: Spec, criterion_id: str, verdict: str, comment: str | None = None) -> Spec:
    if verdict not in VERDICTS:
        raise ValueError(f"invalid verdict {verdict!r}; expected one of {', '.join(VERDICTS)}")
    if criterion_id in PROSE_UNIT_IDS:
        raise ValueError(f"{criterion_id!r} is a prose section — use set_prose_verdict")
    for c in spec.acceptance_criteria:
        if c.id == criterion_id:
            c.verdict = verdict
            if comment is not None:
                c.comment = comment or None
            return spec
    valid = ", ".join(c.id for c in spec.acceptance_criteria) or "(none)"
    raise ValueError(f"no acceptance criterion {criterion_id!r}; valid ids: {valid}")


def set_prose_verdict(spec: Spec, section_id: str, verdict: str, comment: str | None = None) -> Spec:
    """Set one prose section's verdict (MOS-172). section_id must be one of PROSE_UNIT_IDS."""
    if verdict not in VERDICTS:
        raise ValueError(f"invalid verdict {verdict!r}; expected one of {', '.join(VERDICTS)}")
    if section_id not in PROSE_UNIT_IDS:
        raise ValueError(f"{section_id!r} is not a prose section; valid: {', '.join(sorted(PROSE_UNIT_IDS))}")
    from mship.core.spec import ProseVerdict
    spec.prose_verdicts[section_id] = ProseVerdict(verdict=verdict, comment=(comment or None))
    return spec
```

- [ ] **Step 4: Run to verify it passes**

Run: `uv run pytest -q tests/core/test_spec_review.py`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/spec_review.py tests/core/test_spec_review.py
git commit -m "feat(spec): set_prose_verdict + criterion flag-comment (MOS-172/217)"
mship journal "set_prose_verdict accepts PROSE_UNIT_IDS; criterion verdict takes a comment; tests passing" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=3 -->
### Task 3: PR1 — `POST /specs/{id}/prose-verdict` endpoint + `VerdictBody.comment`

**Files:**
- Modify: `mothership/src/mship/core/serve.py`
- Test: `mothership/tests/core/test_serve.py`

- [ ] **Step 1: Write the failing test** (mirror `test_post_verdict`, `test_serve.py:153-160`)

```python
def test_post_prose_verdict(tmp_path):
    _seed_spec(tmp_path)
    client = TestClient(_app(tmp_path))
    r = client.post("/specs/dq/prose-verdict", json={"section_id": "approach", "verdict": "flagged", "comment": "unclear"})
    assert r.status_code == 200
    # verdict endpoint returns the review; the spec itself now carries the prose verdict
    from mship.core.spec_store import SpecStore
    s = SpecStore(tmp_path / "specs").find_by_id("dq")
    assert s.prose_verdicts["approach"].verdict == "flagged"
    assert s.prose_verdicts["approach"].comment == "unclear"
    assert client.post("/specs/dq/prose-verdict", json={"section_id": "nope", "verdict": "approved"}).status_code == 400
    assert client.post("/specs/dq/prose-verdict", json={"section_id": "approach", "verdict": "bogus"}).status_code == 400


def test_post_verdict_with_comment(tmp_path):
    _seed_spec(tmp_path)
    client = TestClient(_app(tmp_path))
    r = client.post("/specs/dq/verdict", json={"criterion_id": "ac1", "verdict": "flagged", "comment": "fix"})
    assert r.status_code == 200
    from mship.core.spec_store import SpecStore
    assert SpecStore(tmp_path / "specs").find_by_id("dq").acceptance_criteria[0].comment == "fix"
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest -q tests/core/test_serve.py::test_post_prose_verdict tests/core/test_serve.py::test_post_verdict_with_comment`
Expected: FAIL — 404 (no prose-verdict route) / `comment` ignored.

- [ ] **Step 3: Implement**

In `src/mship/core/serve.py`: add `comment` to `VerdictBody`, add `ProseVerdictBody`, and a route:

```python
class VerdictBody(BaseModel):
    criterion_id: str
    verdict: str
    comment: str | None = None


class ProseVerdictBody(BaseModel):
    section_id: str
    verdict: str
    comment: str | None = None
```

Update `post_verdict` to pass the comment, and add the prose route next to it:

```python
    @app.post("/specs/{spec_id}/verdict")
    def post_verdict(spec_id: str, body: VerdictBody):
        spec = _load_or_404(spec_id)
        try:
            set_criterion_verdict(spec, body.criterion_id, body.verdict, body.comment)
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e))
        return _save_and_review(spec)

    @app.post("/specs/{spec_id}/prose-verdict")
    def post_prose_verdict(spec_id: str, body: ProseVerdictBody):
        spec = _load_or_404(spec_id)
        try:
            set_prose_verdict(spec, body.section_id, body.verdict, body.comment)
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e))
        return _save_and_review(spec)
```

Add `set_prose_verdict` to the `from mship.core.spec_review import ...` line.

- [ ] **Step 4: Run to verify it passes**

Run: `uv run pytest -q tests/core/test_serve.py -k "prose_verdict or verdict_with_comment"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/serve.py tests/core/test_serve.py
git commit -m "feat(serve): POST /specs/{id}/prose-verdict + verdict comment (MOS-172/217)"
mship journal "serve prose-verdict endpoint + criterion comment; tests passing" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=4 -->
### Task 4: PR1 — apply_draft preserves prose verdicts across a re-draft

**Files:**
- Modify: `mothership/src/mship/core/spec_draft.py`
- Test: `mothership/tests/core/test_spec_draft.py`

- [ ] **Step 1: Write the failing test** (mirror the AC-preservation test at `test_spec_draft.py:51-63`)

```python
def test_apply_draft_preserves_prose_verdicts():
    from mship.core.spec import ProseVerdict
    spec = _spec()
    spec.prose_verdicts = {"approach": ProseVerdict(verdict="approved"),
                           "problem": ProseVerdict(verdict="flagged", comment="c")}
    draft = SpecDraft(problem="P2", user_story="U", approach="A", acceptance_criteria=["x"])
    out = apply_draft(spec, draft)
    # prose verdicts carry over by stable section id (re-review the whole spec is the reviewer's call,
    # but a re-draft alone must not silently reset prior verdicts)
    assert out.prose_verdicts["approach"].verdict == "approved"
    assert out.prose_verdicts["problem"].comment == "c"
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest -q tests/core/test_spec_draft.py::test_apply_draft_preserves_prose_verdicts`
Expected: FAIL — `apply_draft` currently doesn't touch `prose_verdicts` (they'd survive only by accident; if the test fails, it's because a fresh Spec path resets them — implement to be explicit and safe).

- [ ] **Step 3: Implement** — in `apply_draft` (`core/spec_draft.py`), right after `spec.risks = list(draft.risks)`, carry prose verdicts for the canonical sections that still exist:

```python
    # Preserve prose-section verdicts across a re-draft (MOS-172). Section ids are
    # stable (problem/user_story/approach/non_goals/risks), so this is a straight
    # carry-over — unlike the positional AC matcher below. (The prose text may have
    # changed; re-reviewing is the reviewer's call, but a re-draft must not silently
    # drop prior verdicts.)
    spec.prose_verdicts = dict(spec.prose_verdicts)
```

(`apply_draft` mutates `spec` in place and never reassigns `prose_verdicts`, so they already survive; the explicit `dict(...)` copy documents the intent and guards against a future in-place clear. Keep the test as the guard.)

- [ ] **Step 4: Run to verify it passes**

Run: `uv run pytest -q tests/core/test_spec_draft.py`
Expected: PASS (existing + new).

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/spec_draft.py tests/core/test_spec_draft.py
git commit -m "feat(spec): apply_draft preserves prose verdicts across re-draft (MOS-172)"
mship journal "apply_draft preserves prose_verdicts; tests passing" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=5 -->
### Task 5: PR1 — backward-compatible approve gate (prose blockers only for explicit non-approved)

**Files:**
- Modify: `mothership/src/mship/core/spec_approve.py`
- Test: `mothership/tests/core/test_spec_approve.py`

- [ ] **Step 1: Write the failing test**

```python
def test_prose_flagged_blocks_but_missing_prose_does_not():
    from mship.core.spec import ProseVerdict
    # legacy spec: no prose_verdicts at all → still approvable (back-compat)
    s = _spec(criteria=[AcceptanceCriterion(id="ac1", text="x", verdict="approved")],
              questions=[OpenQuestion(id="q1", text="?", answer="y")])
    assert approval_blockers(s) == []
    # a flagged prose section blocks
    s.prose_verdicts = {"approach": ProseVerdict(verdict="flagged")}
    assert any("approach" in b for b in approval_blockers(s))
    # an approved prose section does not block
    s.prose_verdicts = {"approach": ProseVerdict(verdict="approved")}
    assert approval_blockers(s) == []
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest -q tests/core/test_spec_approve.py::test_prose_flagged_blocks_but_missing_prose_does_not`
Expected: FAIL — the flagged prose section isn't checked yet.

- [ ] **Step 3: Implement** — append to `approval_blockers` in `core/spec_approve.py`:

```python
    bad_prose = [sid for sid, pv in spec.prose_verdicts.items() if pv.verdict != "approved"]
    if bad_prose:
        blockers.append(f"prose sections not approved: {', '.join(sorted(bad_prose))}")
```

(A section with an explicit non-approved verdict blocks; a section absent from `prose_verdicts` contributes nothing — legacy specs and specs the reviewer hasn't touched still approve. This is the spec's stated back-compat rule.)

- [ ] **Step 4: Run to verify it passes**

Run: `uv run pytest -q tests/core/test_spec_approve.py`
Expected: PASS (existing legacy tests still green + the new one).

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/spec_approve.py tests/core/test_spec_approve.py
git commit -m "feat(spec): approve gate considers prose verdicts, backward-compatibly (MOS-172)"
mship journal "approve gate: explicit non-approved prose blocks; missing prose never blocks; tests passing" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=6 -->
### Task 6: PR1 — `build_review` emits prose verdicts + criterion comment

**Files:**
- Modify: `mothership/src/mship/core/spec_review.py`
- Test: `mothership/tests/core/test_spec_review.py`

- [ ] **Step 1: Write the failing test**

```python
def test_build_review_emits_prose_verdicts_and_comments():
    from mship.core.spec import ProseVerdict
    s = _spec()
    set_criterion_verdict(s, "ac1", "flagged", comment="fix")
    s.prose_verdicts = {"approach": ProseVerdict(verdict="approved")}
    review = build_review(s)
    assert review["prose_verdicts"]["approach"]["verdict"] == "approved"
    # the criterion's comment is exposed in the review's criteria list
    crit = next(c for c in review["acceptance_criteria"] if c["id"] == "ac1")
    assert crit["comment"] == "fix"
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest -q tests/core/test_spec_review.py::test_build_review_emits_prose_verdicts_and_comments`
Expected: FAIL — `build_review` doesn't emit `prose_verdicts` / criterion `comment`.

- [ ] **Step 3: Implement** — in `build_review` (`spec_review.py:16-62`): add `comment` to each criterion dict it builds, and add a top-level `prose_verdicts` key: `"prose_verdicts": {sid: pv.model_dump(mode="json") for sid, pv in spec.prose_verdicts.items()}`. (Read the current `build_review` body and add these two fields to its returned dict; keep the existing `context` block that already exposes the prose text.)

- [ ] **Step 4: Run to verify it passes**

Run: `uv run pytest -q tests/core/test_spec_review.py`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/spec_review.py tests/core/test_spec_review.py
git commit -m "feat(spec): build_review emits prose_verdicts + criterion comment (MOS-172/217)"
mship journal "build_review surfaces prose_verdicts + criterion comments; tests passing" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=7 -->
### Task 7: PR1 — full serve suite + finish PR1

**Files:** none (verification)

- [ ] **Step 1:** `cd mothership && uv run pytest -q` — the whole suite green (new tests + no regressions; the old prose-reject behavior test is replaced by Task 2).
- [ ] **Step 2:** Confirm back-compat: an existing spec with no `prose_verdicts` still approves via `mship spec approve` (exercise `test_spec_approve.py` legacy cases).
- [ ] **Step 3:** `mship journal "Queue v2 PR1 serve foundations: prose verdicts + flag-comment + gate; suite green" --action verified`
- [ ] **Step 4 (orchestrator):** this is the PR1 boundary — `mship finish` for the **mothership** PR, run Greptile close-out, and check in with the operator before starting PR2.
<!-- /mship:task -->

---

<!-- mship:task id=8 -->
### Task 8: PR2 — Queue v2 card model (chunk cards + decision cards)

**Files:**
- Rework: `ground-control/android/app/src/main/java/com/atomikpanda/groundcontrol/ui/queue/QueueCard.kt`
- Test: `app/src/test/java/com/atomikpanda/groundcontrol/QueueCardTest.kt`

**Goal:** replace the WorkItem-attention `QueueCard` (verbatim recon: single data class, `cardsFrom(items)`) with a card model that represents (a) a spec **prose-section** card, (b) a spec **acceptance-criteria** card (multi-item), (c) a spec **open-questions** card (multi-item), and (d) a **decision** card. Keep the `key`/`tier`/`sortQueue` machinery (reused by the ViewModel's `mergeKeepingHead`).

- [ ] Define a `sealed interface QueueV2Card` with `connectionId`, `workspaceName`, `key`, `tier`, `waitingSince`:
  - `ProseCard(specId, sectionId, sectionLabel, text, verdict)` — one prose section.
  - `CriteriaCard(specId, items: List<CriterionItem>)` where `CriterionItem(id, text, verdict, comment?)` — multi-item.
  - `QuestionsCard(specId, items: List<QuestionItem>)` where `QuestionItem(id, text, answer?)` — multi-item.
  - `DecisionCard(threadId, text, decision)` — reuse the `DecisionPrompt`/`Decision` shape.
  - `key` includes specId + sectionId/criterion-set/threadId for uniqueness; tier: decisions = URGENT, spec-review = APPROVAL.
- [ ] `cardsFromSpec(conn, spec: SpecRecord)` → the prose/criteria/questions cards for one `needs_review` spec (skip empty sections; the questions card only when unanswered questions exist).
- [ ] `decisionCardFrom(conn, thread)` → a decision card when the thread has a pending decision (reuse `pendingDecision`).
- [ ] Keep `sortQueue` (tier asc, oldest-first) from the MOS-225 file.
- [ ] **Tests:** a `needs_review` spec explodes into the expected prose + criteria + questions cards; an approved-criteria card marks each item's verdict; a thread with a decision yields a decision card; ordering (decisions before spec-review).

Commit: `feat(queue): Queue v2 card model — spec chunk cards + decision cards` + journal.
<!-- /mship:task -->

---

<!-- mship:task id=9 -->
### Task 9: PR2 — DTOs + SpecApi prose-verdict / flag-comment / spec-detail source

**Files:**
- Modify: `data/dto/SpecDetailDtos.kt`, `data/MshipClient.kt`, `data/SpecRepository.kt`
- Test: `app/src/test/java/com/atomikpanda/groundcontrol/QueueV2ApiTest.kt`

- [ ] `SpecDetailDtos.kt`: `VerdictBody` gains `comment: String? = null`; add `@Serializable data class ProseVerdictBody(@SerialName("section_id") val sectionId: String, val verdict: String, val comment: String? = null)`. Add `comment` to `ReviewCriterion`; add `proseVerdicts: Map<String, ProseVerdictDto>` (`@SerialName("prose_verdicts")`) to `SpecReview` + `SpecRecord`, with `ProseVerdictDto(verdict, comment?)`. (All additive; `ignoreUnknownKeys` makes them safe even before PR1 deploys.)
- [ ] `MshipClient.kt` (`SpecApi`): `setProseVerdict(conn, id, sectionId, verdict, comment?) → POST /specs/$id/prose-verdict`; `setVerdict` gains a `comment` param passed into `VerdictBody`. Reuse `approve`/`requestChanges`/`answerQuestion` verbatim.
- [ ] `SpecRepository.kt` already fans out `listAllSpecs`; add a `specDetail(conn, id)` passthrough to `api.getSpec`/`getReview` for chunk sourcing (filter callers to `status == "needs_review"`).
- [ ] **Tests:** `setProseVerdict` POSTs the right path + body + auth (MockEngine); `setVerdict` sends the comment.

Commit: `feat(queue): GC prose-verdict + flag-comment client + spec-detail sourcing` + journal.
<!-- /mship:task -->

---

<!-- mship:task id=10 -->
### Task 10: PR2 — rework `QueueRepository` to source specs+threads → cards

**Files:**
- Rework: `data/QueueRepository.kt`
- Test: `app/src/test/java/com/atomikpanda/groundcontrol/QueueRepositoryTest.kt`

- [ ] Keep the `load(connections)` fan-out + `loadOne` per-workspace-error `fold` shape verbatim (recon B1). Swap the source: per workspace, `listSpecs` filtered to `needs_review` → for each, `specDetail` → `cardsFromSpec`; **plus** `listThreads` → `decisionCardFrom` for threads needing a decision. Merge → `sortQueue`.
- [ ] Action seams: `setProseVerdict`, `setCriterionVerdict(+comment)`, `answerQuestion`, `approve`, `requestChanges`, `answerDecision` (all thin `api.*` passthroughs).
- [ ] Per-workspace failure still contributes a `WorkspaceError`, not a blank queue.
- [ ] **Tests (MockEngine, per-host):** two workspaces' `needs_review` specs + a decision thread merge into the expected cards; a failing workspace isolates to an error.

Commit: `feat(queue): source needs_review specs + decisions cross-workspace (Queue v2)` + journal. **PR2 boundary:** finish the GC PR OR continue to PR3 in the same branch (orchestrator's call — likely one GC PR covering PR2+PR3). Check in with the operator.
<!-- /mship:task -->

---

<!-- mship:task id=11 -->
### Task 11: PR3 — rework `QueueViewModel`: approve-all / reject / per-item / skip / auto-approve

**Files:**
- Rework: `ui/queue/QueueViewModel.kt`
- Test: `app/src/test/java/com/atomikpanda/groundcontrol/QueueViewModelTest.kt`

**Goal:** keep the head-stable `refresh`/`mergeKeepingHead`/`resolvedKeys`/`deferredKeys`/`advancePast`/undo/snackbar machinery (recon B1, verbatim), generalize `Content.cards` to `QueueV2Card`, and add the v2 transitions:
- [ ] `approveAllCurrent()` — for a CriteriaCard: `setVerdict(approved)` for each item; for a ProseCard: `setProseVerdict(approved)`; then, if that makes the whole spec approvable, call `approve(bypass=false)` (auto-approve). Handle the `ApiConflictException`/`cannot approve` 409 (a still-un-approved chunk) via the existing blockers path — advance and let the spec's remaining chunks stay in queue.
- [ ] `rejectCurrent(comment)` — flag the card's item(s) (`setVerdict(flagged, comment)` / `setProseVerdict(flagged, comment)`) AND `requestChanges(spec, comment)`; on success the spec's cards leave (add all its `key`s to `resolvedKeys`).
- [ ] `setItemVerdict(itemId, verdict, comment?)` — per-item approve/flag inside a multi-item card (no advance; updates the card in place).
- [ ] `answerQuestion(qid, answer)` — per-item answer inside a QuestionsCard.
- [ ] `answerDecision(text)` — unchanged from MOS-225 (post to thread).
- [ ] `skip()` = the MOS-225 `defer()` (to back).
- [ ] **Tests:** approve-all marks all items + auto-approves when the spec is fully approved (MockEngine `approve` returns approved); a 409 on approve keeps remaining chunks; reject flags + request-changes + clears the spec's cards; per-item verdict updates in place; skip → back.

Commit: `feat(queue): Queue v2 ViewModel — approve-all/reject/per-item/skip/auto-approve` + journal.
<!-- /mship:task -->

---

<!-- mship:task id=12 -->
### Task 12: PR3 — rework `QueueScreen`: directional swipe + comment sheet + per-item rows

**Files:**
- Rework: `ui/queue/QueueScreen.kt`

Compose UI (verify via compile + build; logic is in the tested ViewModel).
- [ ] Make the `SwipeToDismissBox` **directional**: `confirmValueChange` branches on `dismissDirection` — `StartToEnd` (right) → `vm.approveAllCurrent()` (+ undo snackbar), return `true`/animate-out; `EndToStart` (left) → open the reject `CommentSheet`, return `false` (don't dismiss until the sheet resolves). Keep the Skip button (= `vm.skip()`) as the guaranteed path.
- [ ] Reject `CommentSheet`: reuse the `ModalBottomSheet` pattern from `ui/messages/DecisionCard.kt`'s `CommentSheet` (verbatim recon B5) → `onSend { vm.rejectCurrent(it) }`.
- [ ] `CardFace` `when` over `QueueV2Card`: ProseCard → the section text + Check/Flag toggles (reuse `CriterionRow`'s two `IconToggleButton`s, recon B4); CriteriaCard/QuestionsCard → a per-item list with those toggles / an answer field; DecisionCard → reuse `DecisionCard` composable.
- [ ] Keep the 15s poll `LaunchedEffect`, snackbar-undo, position indicator, `WorkspaceErrorLine`, "all caught up ✓".
- [ ] Verify: `./gradlew compileDebugKotlin && ./gradlew assembleDebug && ./gradlew testDebugUnitTest`.

Commit: `feat(queue): Queue v2 card-stack UI — directional swipe, comment sheet, per-item rows` + journal.
<!-- /mship:task -->

---

<!-- mship:task id=13 -->
### Task 13: PR3 — wire the Queue tab (screen already wired via Section.QUEUE)

**Files:** `GroundControlApp.kt` (the `composable(Section.QUEUE.route)` block from MOS-225) — update the VM/repo construction + nav callbacks (open-item deep-link stays; the browser-open PR path is gone since v2 doesn't source PR cards). Verify `assembleDebug`. Commit + journal.
<!-- /mship:task -->

---

<!-- mship:task id=14 -->
### Task 14: Full verification + finish GC PR

- [ ] `cd ground-control/android && source ~/toolchains/android-env.sh && ./gradlew testDebugUnitTest && ./gradlew assembleDebug` — green.
- [ ] Cross-check the 10 spec ACs (Task-by-task mapping): AC1 (T8/T10), AC2 (T1-3), AC3 (T1-3), AC4 (T11/T12), AC5 (T11/T12), AC6 (T11), AC7 (T8/T12), AC8 (T11/T12), AC9 (T5), AC10 (T10).
- [ ] Attach `mship spec evidence` per AC.
- [ ] `mship finish` the GC PR; Greptile close-out; report to operator.
<!-- /mship:task -->

---

## Self-Review

**Spec coverage:** AC2/AC3 → T1-3,6 (prose verdicts + flag-comment on serve, surfaced in review); AC9 → T5 (back-compat gate); AC1/AC10 → T8-10 (sourcing + per-workspace error); AC4/AC5/AC7/AC8 → T11-12 (approve-all/reject/per-item/decision/skip UI); AC6 → T11 (auto-approve / request-changes lifecycle). All covered.

**Sequencing note:** PR1 (Tasks 1-7) is fully detailed TDD and independently shippable + backward-compatible — build it first, ship, check in. PR2/PR3 (Tasks 8-14) are specified against the verbatim recon of the four MOS-225 Queue files + the reused serve endpoints + `DecisionCard`/`CommentSheet`/`CriterionRow`/`write()` patterns; their per-step TDD code will be filled in against the actual PR1-updated DTOs when PR1 lands (the exact `SpecReview`/`SpecRecord` shape depends on Task 6's serializer). This is deliberate for a dependent epic — don't hand-write PR3's Kotlin against DTOs PR1 hasn't finalized.

**Type consistency:** `ProseVerdict{verdict,comment}` / `prose_verdicts: dict[str,ProseVerdict]` / `set_prose_verdict(spec, section_id, verdict, comment)` / `POST /specs/{id}/prose-verdict` `ProseVerdictBody{section_id,verdict,comment}` are consistent across serve tasks; `AcceptanceCriterion.comment` + `VerdictBody.comment` + `ReviewCriterion.comment` align serve↔GC. `PROSE_UNIT_IDS` is the single source of valid section ids.
