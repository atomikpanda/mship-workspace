---
id: gc-review-decision-queue-v2
title: 'Queue v2: spec-chunk + decision review queue (swipe approve/reject, per-item
  verdicts)'
status: implemented
created_at: '2026-07-13T23:38:20.511593Z'
updated_at: '2026-07-14T02:04:20.228904Z'
affected_repos:
- mothership
- ground-control
acceptance_criteria:
- id: ac1
  text: 'The Queue sources, across all connected workspaces, spec-review chunk cards
    (per needs_review spec: one card per prose section, one acceptance-criteria card,
    and an open-questions card when questions are unanswered) and decision cards (per
    thread needing the operator).'
  verdict: approved
  evidence:
  - kind: commit
    ref: 58a5acf
    note: QueueV2Card model + cardsFromSpec/decisionCardFrom + QueueRepository sourcing
      needs_review specs + decision threads; QueueCardTest/QueueRepositoryTest
- id: ac2
  text: "mship serve supports per-prose-section verdicts (problem/user_story/approach/non_goals/risks\
    \ \u2192 unreviewed/approved/flagged + optional comment), surfaced in spec detail\
    \ and settable via an endpoint (subsumes MOS-172)."
  verdict: approved
  evidence:
  - kind: commit
    ref: 33714ef
    note: prose-verdict endpoint + ProseVerdict model + set_prose_verdict; test_serve
      prose-verdict
- id: ac3
  text: A flagged acceptance criterion or prose section can carry a comment (subsumes
    MOS-217).
  verdict: approved
  evidence:
  - kind: commit
    ref: 7e9e789
    note: AcceptanceCriterion.comment + criterion/prose flag-comment; test_spec_review
- id: ac4
  text: Swipe right approves all items on a card; swipe left rejects via a comment
    sheet that flags the item(s) and request-changes the spec with that comment.
  verdict: approved
  evidence:
  - kind: commit
    ref: ccce16b
    note: swipe-right approve-all + swipe-left reject->comment->request-changes; QueueViewModelTest
- id: ac5
  text: Multi-item cards (acceptance-criteria, open-questions) allow per-item approve/flag
    (and answer, for questions).
  verdict: approved
  evidence:
  - kind: commit
    ref: ccce16b
    note: per-item Check/Flag in multi-item cards (in-place); QueueViewModelTest
- id: ac6
  text: When all of a spec's chunk-cards are approved (prose + criteria + questions),
    the spec auto-approves and leaves the queue; when any chunk is rejected, the spec
    is request-changed and leaves the queue until re-drafted.
  verdict: approved
  evidence:
  - kind: commit
    ref: 02de7fa
    note: auto-approve on last chunk; reject request-changes clears spec cards; QueueViewModelTest
- id: ac7
  text: Decision cards render the question + options and are answered by tapping an
    option (+ free-text Other); answering clears the card.
  verdict: approved
  evidence:
  - kind: commit
    ref: 58a5acf
    note: decision cards render + answered via option tap (reuse DecisionCard)
- id: ac8
  text: A Skip button sends the current card to the back; a position indicator and
    an 'all caught up' empty state are shown.
  verdict: approved
  evidence:
  - kind: commit
    ref: ccce16b
    note: Skip->back (defer) + position indicator + all-caught-up
- id: ac9
  text: 'The approve-gate change is backward-compatible: specs without prose verdicts
    can still be approved (un-reviewed prose does not hard-block legacy approvals)
    or are migrated, and existing CLI/GC spec approval is not broken.'
  verdict: approved
  evidence:
  - kind: commit
    ref: f153644
    note: 'approve gate: explicit non-approved prose blocks, missing prose never blocks
      (legacy specs still approve); test_spec_approve'
- id: ac10
  text: Cross-workspace fan-out degrades per-workspace on partial failure (a down
    workspace shows an error, not a blank queue).
  verdict: approved
  evidence:
  - kind: commit
    ref: 02de7fa
    note: cross-workspace fan-out per-workspace error isolation + (conn,spec) scoping;
      QueueRepositoryTest
open_questions: []
non_goals:
- "WorkItem-attention cards (blocked-task, needs-review PR) from MOS-225 \u2014 v2\
  \ reframes around spec-review + decisions; PR review\u2192merge is MOS-208 (deferred);\
  \ a pure blocked-task card without a thread is a follow-on (agent-blocked-asking-you\
  \ is still covered when it posts a needs_you/decision thread)."
- Runtime agent blockers as decision cards (D2 / MOS-162, deferred).
- In-app PR merge / coalescing (MOS-208).
- "Preserving MOS-225's swipe=defer semantics \u2014 v2 redefines swipes (left=reject,\
  \ right=approve-all) and moves defer to a Skip button."
- "A merge-strategy picker or any PR surface \u2014 this feature is spec-review +\
  \ decisions only."
risks:
- 'Big, multi-layer, dependent build: the GC card UI depends on the serve prose-verdict
  model, so it must sequence (foundations first) and spans multiple PRs; keep each
  PR shippable and guard scope creep.'
- "The approve-gate change (requiring prose verdicts) touches the existing spec-approval\
  \ flow everywhere (CLI + the shipped GC spec-detail approve) \u2014 it must be backward-compatible\
  \ so specs predating prose verdicts can still be approved (un-reviewed prose must\
  \ not hard-block legacy approvals), or they're migrated."
- "Reframing the shipped Queue deliberately drops MOS-225's blocked/PR-review cards\
  \ \u2014 a visible reduction until MOS-208 lands; the operator confirmed the reframe."
- Swipe gestures aren't unit-testable (no instrumentation); the approve-all/reject/skip/per-item
  logic must live in the tested ViewModel with the gesture as a thin trigger and a
  reliable Skip-button fallback.
- Cross-workspace fan-out cost scales with workspace count; partial failures must
  degrade per-workspace (carried from MOS-225).
task_slug: gc-review-decision-queue-v2
work_item_id: wi-20260713234839-39409ec8
clarification_reason: null
---
## Problem

The shipped Queue (MOS-225) sources WorkItem-level attention (needs-approval/decision/blocked/needs-review on WorkItems), which in practice leaves it empty even when there's plenty to do: on 2026-07-13 the workspace had 77 items and ZERO with pending attention, while a needs_review spec sat unlinked and mship-ask decisions sat in chat — none of which the WorkItem-attention model surfaces. The operator's mental model is better: the Queue should present the things that actually need their judgment — chunks of a spec to review, and open decisions — one card at a time. Queue v2 reframes the Queue around review + decisions, largely decoupled from WorkItem attention.

## User story

As an operator clearing work from my phone, I want the Queue to hand me the spec chunks that need review and the open decisions that need answering, one card at a time — swipe to approve or reject, tap to decide — so that reviewing and deciding actually happens on my phone instead of the Queue sitting empty.

## Approach

Reframe the Queue's sources (operator decision 2026-07-13) and subsume MOS-172 (per-prose-section verdicts) + MOS-217 (flag-with-comment). SOURCES (cross-workspace fan-out): (1) every needs_review spec explodes into chunk-cards — one card per prose section present (Problem/User story/Approach/Non-goals/Risks, each approve/flag via new per-prose-section verdicts), one acceptance-criteria card (multi-item, per-criterion approve/flag), and an open-questions card when questions are unanswered; (2) every thread needing the operator (an unanswered mship-ask decision or needs_you) → a decision card. INTERACTIONS: swipe-right = approve-all (mark every item on the card approved); swipe-left = reject → a comment sheet that flags the card's item(s) with the comment AND request-changes the whole spec (comment = the reason, via MOS-215 which exists); per-item approve/flag inside multi-item cards (flag opens the comment sheet — MOS-217); a Skip button sends the card to the back; decision cards are answered by tapping an option (+ free-text Other). LIFECYCLE: approving all of a spec's chunk-cards (prose + criteria + questions) satisfies the existing approve gate → the spec auto-approves and leaves the queue; rejecting any chunk request-changes the spec (leaves the queue until re-drafted). SERVE (mothership): add per-prose-section verdicts to the Spec model + a set-verdict endpoint, extend the approve gate to require them (backward-compatible for legacy specs), add flag-with-comment on criteria/sections; review sourcing reuses GET /specs (needs_review) + spec detail + GET /threads. GROUND CONTROL: a QueueV2 sourcing layer + a reworked card-stack screen (reworking the MOS-225 QueueRepository/QueueViewModel/QueueScreen), reusing DecisionCard for decision cards, plus prose-verdict/flag-comment client methods + DTOs. Build is sequenced — serve foundations first, then the GC UI — landing as a few PRs, not one.

## Architecture

Serve: extend Spec with prose_verdicts (a verdict + optional comment per canonical section) and criterion/section flag comments; core/spec_draft.apply_draft preserves them across re-drafts (mirroring the existing AC-evidence preservation); add POST /specs/{id}/prose-verdict and extend the criterion-verdict path with a comment; update the approve gate in core/spec.py to consider prose verdicts with a backward-compat rule (legacy specs with no prose verdicts are not hard-blocked). Review sourcing reuses GET /specs + spec detail + GET /threads. Tests: tests/core/test_spec*.py (model + gate) + tests/core/test_serve*.py (endpoints, FastAPI TestClient).

Ground Control: a QueueV2Repository (fan-out → ordered card list) + a reworked QueueViewModel (card stack; approve-all/reject/skip/per-item state machine; auto-approve + request-changes calls; live-refresh keeping the focused card stable — carried from MOS-225) + a reworked QueueScreen (swipe gestures, a comment bottom-sheet, per-item rows, Skip, reuse DecisionCard). Client: prose-verdict + flag-comment methods + DTOs. This reworks the MOS-225 QueueRepository/QueueViewModel/QueueScreen (retiring the WorkItem-attention sourcing).

## Testing

Serve: prose-verdict set/get + comment; approve gate requires prose verdicts AND a backward-compat path lets a legacy (no-prose-verdict) spec approve; flag-comment persists + surfaces; request-changes carries the reject comment. Ground Control (JVM unit tests only — no emulator): card sourcing (specs → prose + AC + questions cards; threads → decision cards; ordering); ViewModel approve-all marks all items and auto-approves when the spec is fully approved; reject flags + request-changes; per-item approve/flag; Skip → back; partial fan-out failure shows a per-workspace error. Swipe gestures verified by compile/build + manual (all logic in the tested ViewModel). Ktor MockEngine, real-time side-effect assertions (known fire-and-forget flake).

## Build sequencing

This is an epic that subsumes MOS-172 + MOS-217 and reframes MOS-225's Queue. The implementation plan sequences it: (1) serve foundations — per-prose-section verdicts (MOS-172) + flag-with-comment (MOS-217) + the backward-compatible approve-gate change; (2) GC QueueV2 sourcing (fan-out → cards); (3) GC card-stack UI (swipe/skip/per-item/comment-sheet, reuse DecisionCard) + the spec-approve/request-changes wiring. Each stage is independently shippable; the build lands as a few PRs, not one. A new Linear issue should track it (it reframes the shipped MOS-225 and closes MOS-172 + MOS-217).
