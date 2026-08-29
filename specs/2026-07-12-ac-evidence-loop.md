---
id: ac-evidence-loop
title: Close the AcceptanceCriterion evidence loop
status: approved
created_at: '2026-07-12T17:50:45.693069Z'
updated_at: '2026-07-12T19:36:45.394693Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: 'AcceptanceCriterion carries a persisted `evidence: list[AcceptanceEvidence]`
    where AcceptanceEvidence = {kind: test|commit|artifact, ref: str, note: str|None};
    an old spec file with no evidence field loads with evidence=[] and round-trips
    losslessly through serialize/parse.'
  verdict: approved
- id: ac2
  text: Re-applying a draft (apply_draft) preserves existing evidence AND verdicts
    for each AC whose id and text are unchanged; an AC whose text materially changed
    starts fresh with empty evidence and unreviewed verdict.
  verdict: approved
- id: ac3
  text: '`mship spec evidence <spec_id> <ac_id> <ref> [--kind test|commit|artifact]
    [--note TEXT]` attaches an evidence entry to the named AC and persists it; a `set_criterion_evidence(spec,
    ac_id, kind, ref, note)` service mirrors set_criterion_verdict and validates the
    ac_id and kind.'
  verdict: approved
- id: ac4
  text: '`POST /specs/{spec_id}/evidence` attaches evidence via the API and returns
    the updated review payload, mirroring POST /verdict.'
  verdict: approved
- id: ac5
  text: '`build_review` output (and therefore CLI `spec review`, `GET /specs/{id}/review`,
    and Ground Control cards) includes each AC''s evidence list and an `unverified`
    count in its summary (ACs with empty evidence).'
  verdict: approved
- id: ac6
  text: 'The spec-approval gate (approval_blockers) is unchanged: a spec with approved
    verdicts but no evidence is still approvable; evidence is never required to approve.'
  verdict: approved
- id: ac7
  text: '`mship commit` records the resulting commit sha in the journal entry''s evidence
    field so a `commit:<sha>` reference is resolvable from the journal.'
  verdict: approved
- id: ac8
  text: Entering `phase review` (dev->review) emits a WARNING listing any ACs on the
    bound spec that have no evidence, alongside the existing test-evidence warning,
    and never blocks the transition.
  verdict: approved
- id: ac9
  text: '`mship finish` WARNs by default when any AC on the bound spec lacks evidence
    and BLOCKs the finish only when `--require-evidence` is passed (mirroring `--require-tests`);
    with no bound spec the AC check is a no-op.'
  verdict: approved
- id: ac10
  text: The PR body produced by finish includes an 'Acceptance criteria' section that
    renders each AC as verified (listing its evidence refs) or unverified, produced
    by a `build_acceptance_block(spec)` helper mirroring build_coordination_block.
  verdict: approved
- id: ac11
  text: Slice A (model + set/surface + apply_draft preservation + commit-sha journaling)
    is delivered as PR-a and is mergeable on its own; Slice B (phase/finish/PR-body
    enforcement) is delivered as PR-b and can be reverted without touching the schema.
  verdict: approved
open_questions: []
non_goals:
- Per-test-case evidence granularity. Test runs are recorded per-repo only; there
  is no per-test id in the system, so an AC links to a test-run iteration/repo, not
  an individual test case. Adding per-test parsing is out of scope.
- Auto-populating evidence from test runs. There is no AC<->test mapping, so auto-attaching
  a passing run to criteria would produce false verification. Evidence is set explicitly
  by the operator or the reviewing agent.
- Resolving or validating evidence refs. Refs are advisory strings (test-runs/N, a
  sha, an artifact path/URL); v1 does not fetch, check, or dereference them.
- Ground Control UI for displaying/attaching evidence. The API (build_review / GET
  review / POST evidence) exposes evidence automatically, but the Android rendering
  + attach affordance is a fast-follow slice, not part of this spec.
- Blocking spec approval on evidence. By lifecycle design, evidence cannot exist at
  approval time; the approval gate stays verdict-only.
- Changing the meaning of `verdict` or the existing approval gate.
risks:
- 'Re-apply data loss: if `apply_draft` is not taught to preserve evidence/verdicts
  by AC id, re-drafting a spec silently wipes verification. Mitigation: preservation
  is an explicit acceptance criterion with a dedicated test; match on AC id AND text
  so a materially-changed criterion correctly starts fresh.'
- 'Gate creep / false friction: an over-eager finish block would punish bugs/chores
  that legitimately have thin ACs. Mitigation: WARN-by-default, opt-in `--require-evidence`
  only; the block never fires unless explicitly requested.'
- 'Spec-loading in finish/phase: `finish` and `_gate_review` do not load the spec
  today. They must resolve it via the task->WorkItem->spec link. Mitigation: reuse
  the same workspace_root + SpecStore pattern the WorkItem gate and `_has_approved_spec`
  already use; if no spec is bound, the AC gate is simply a no-op.'
- 'Evidence-shape lock-in: choosing a structured list vs a free-form string is hard
  to change after specs persist evidence. Mitigation: the structured list is a strict
  superset of a single string; a free-form ref still fits as {kind: artifact, ref:
  <string>}.'
task_slug: null
work_item_id: null
clarification_reason: null
---
## Problem

An `AcceptanceCriterion` carries only `id`, `text`, and a `verdict` (unreviewed/approved/flagged). Nothing links a criterion to the test, commit, or artifact that satisfies it, and neither `mship finish`, `core/pr.py`, nor the `phase dev->review` gate ever consult ACs. So a spec's acceptance criteria are a design-review artifact that evaporates the moment the build starts: the operator approves 'these are the right criteria', and then the implementation is verified with zero reference back to them. This is exactly the 'evidence over claims' gap the architecture review (MOS-236 / R1-G1) flagged as the single highest-value coherence investment. The criteria that define 'done' never get connected to the proof that they were met.

## User story

As an operator (on the phone or terminal) reviewing a piece of finished work, I want each acceptance criterion to show the concrete evidence that satisfies it (a test run, a commit, an artifact ref), and I want `review` and `finish` to warn me when criteria are unverified, so that 'done' means 'demonstrably met the criteria' instead of 'an agent claimed it was done'. As the implementing/reviewing agent, I want a command to attach that evidence as I verify each criterion, so the verification is captured at the moment it happens rather than reconstructed later.

## Approach

Add a first-class evidence link to each acceptance criterion and wire the existing review/finish/PR surfaces to consult it. The work splits cleanly along a schema/behavior seam, matching the two-PR split the issue mandates.

Central lifecycle insight that shapes everything: `verdict` and `evidence` are ORTHOGONAL and fire at different times. `verdict` (unreviewed/approved/flagged) is the DESIGN-review outcome -- 'is this the right criterion?' -- and it gates spec APPROVAL, which happens before any code exists. `evidence` is the IMPLEMENTATION-verification -- 'did the build actually satisfy this criterion?' -- and it can only exist AFTER the build, so it is surfaced at `review` and gated (softly) at `finish`. Therefore evidence is deliberately NOT added to the approval gate: requiring evidence to approve a spec would be a lifecycle error, because at approval time there is nothing to point at. This corrects the naive reading of the issue ('make finish consult ACs') by placing each gate at the lifecycle moment where its input can actually exist.

Slice A -- MODEL (ships as PR-a, safe + mergeable alone): a small `AcceptanceEvidence` value {kind: test|commit|artifact, ref: str, note: str|None} and `AcceptanceCriterion.evidence: list[AcceptanceEvidence] = []`. It round-trips automatically through the Pydantic-based spec_store (a default of [] keeps every existing spec file loadable), so persistence needs zero new code. A `set_criterion_evidence` service mirrors the existing `set_criterion_verdict`; a `mship spec evidence <spec> <ac> <ref>` CLI command mirrors `mship spec verdict`; a `POST /specs/{id}/evidence` endpoint mirrors `POST /verdict`. `build_review` (the shared payload behind CLI `spec review`, `GET /specs/{id}/review`, and every Ground Control review card) gains per-AC evidence and an `unverified` count (ACs with empty evidence). `apply_draft` is taught to PRESERVE existing evidence + verdicts by AC id when a draft is re-applied, so re-drafting a spec does not silently wipe verification of the criteria that did not change. Finally, `mship commit` journals the commit sha (LogEntry.evidence already exists as a free-form field) so that a `commit:<sha>` evidence ref is actually resolvable -- today the sha is printed but never durably recorded.

Slice B -- ENFORCEMENT (ships as PR-b, revertable without touching the schema): the `phase dev->review` gate (`_gate_review`) loads the task's bound spec and WARNs listing ACs with no evidence, right next to the existing test-evidence warning -- soft, never blocking. `mship finish` mirrors its existing test-evidence gate: WARN by default on evidence-less ACs, BLOCK only under a new `--require-evidence` flag (the exact shape of `--require-tests`). The PR body gains an 'Acceptance criteria' section rendering each AC as verified (with its evidence refs) or unverified, built by a `build_acceptance_block(spec)` helper that mirrors the existing `build_coordination_block` and is injected at the finish PR-body assembly site.

Evidence granularity is bounded by what exists: test runs are recorded PER-REPO only (`.mothership/test-runs/<task>/<iter>.<repo>`), with no per-test-case id anywhere in the system. So an evidence ref addresses a test-run iteration/repo (`test-runs/<iter>[.<repo>]`), a commit sha, or a free-form artifact path/URL -- reusing the ref convention already documented on `mship debug --evidence` (`test-runs/5`, `HEAD`, `path:12-18`). Refs are advisory strings; v1 does not attempt to resolve or validate them across repos.

Key decisions (pre-made, recommended -- request changes on the spec to override):
1. Evidence shape = a LIST of structured {kind, ref, note}, not a single free-form string. An AC is often satisfied by more than one thing (a test AND a commit), and an explicit `kind` lets the review card + PR body group/label refs and lets a future auto-linker populate them. Considered alternative: a single free-form `evidence: str` matching `LogEntry.evidence` -- simpler but loses the multi-ref + typed-render benefit.
2. Enforcement hardness = WARN-by-default everywhere, opt-in BLOCK at finish via `--require-evidence`; soft warn at review; NEVER gated at approval. This is the least-framing-dependent posture (aligns with both terminal-developer and phone-operator modes) and mirrors the established `--require-tests` precedent, so it needs no MOS-237 resolution.
3. Who attaches evidence = explicit, not auto. In the subagent-driven flow the spec-compliance reviewer (which already verifies each AC against the code) sets verdict + evidence together via `mship spec evidence`. There is deliberately NO auto-attach-to-all-ACs, because no AC<->test mapping exists to make it correct.
4. PR split = two sequential PRs per the issue (PR-a model merges first; PR-b enforcement branches off main after). Honors the 'gate is revertable without touching the schema' requirement.

## Insertion points (verified against main)

- Model: `src/mship/core/spec.py` AcceptanceCriterion (add `evidence`); new `AcceptanceEvidence` model.
- Construct/preserve: `src/mship/core/spec_draft.py::apply_draft` (rebuilds the AC list from strings today -- must merge prior evidence/verdicts by id+text).
- Persist: `src/mship/core/spec_store.py` -- no change (Pydantic model_dump round-trips nested models automatically).
- Set evidence: `src/mship/core/spec_review.py::set_criterion_verdict` (mirror as set_criterion_evidence); CLI `src/mship/cli/spec.py::verdict` (mirror as `evidence`); API `src/mship/core/serve.py::post_verdict` + VerdictBody (mirror as evidence endpoint).
- Surface: `src/mship/core/spec_review.py::build_review` (per-AC evidence + summary.unverified).
- Approval gate: `src/mship/core/spec_approve.py::approval_blockers` -- intentionally UNCHANGED.
- Commit-sha journaling: `src/mship/cli/commit.py` (append evidence=<sha> when journaling the committed action).
- Phase review gate: `src/mship/core/phase.py::_gate_review` (load spec via self._workspace_root + SpecStore, add unverified-AC warnings).
- Finish gate + PR body: `src/mship/cli/worktree.py` test-evidence gate (~1308-1353) is the template for the AC gate; PR-body assembly (~1493-1516) is where build_acceptance_block output is injected.
- PR helper: `src/mship/core/pr.py::build_coordination_block` is the template for build_acceptance_block.

## Evidence ref format

Reuse the convention already documented on `mship debug --evidence`:
- test-run: `test-runs/<iteration>` or `test-runs/<iteration>.<repo>` (per-repo is the finest granularity that exists).
- commit: a git sha (`HEAD` resolved, or a full/short sha).
- artifact: a workspace-relative path, `path:line-range`, or a URL.
The CLI infers `kind` from the ref shape (test-runs/... => test; hex sha => commit; else artifact) with a `--kind` override. Refs are advisory; not resolved or validated in v1.

## Testing strategy

- Model: evidence round-trips through serialize/parse; a legacy spec file (no evidence key) loads with evidence=[]; AcceptanceEvidence validates kind.
- apply_draft: re-apply preserves evidence+verdict for unchanged ACs; drops them for a materially-changed AC; assigns fresh ids consistently.
- Service/CLI/API: set_criterion_evidence appends + persists; unknown ac_id / bad kind error cleanly; POST /evidence returns the review payload.
- build_review: unverified count is exactly the number of ACs with empty evidence.
- Approval gate: unchanged -- approve succeeds with verdicts approved and zero evidence.
- commit: the journal entry for a commit carries evidence=<sha>.
- Enforcement: _gate_review warns (never blocks) on evidence-less ACs; finish warns by default and blocks under --require-evidence; no-bound-spec is a no-op; build_acceptance_block renders verified vs unverified correctly.
