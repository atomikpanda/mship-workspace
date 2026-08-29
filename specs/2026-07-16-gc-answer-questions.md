---
id: gc-answer-questions
title: 'GC review: answering open questions is the obvious path to approval'
status: implemented
created_at: '2026-07-16T21:32:05.103747Z'
updated_at: '2026-07-17T17:10:16.584128Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: When a review-phase spec has >=1 unanswered open question, the spec-detail
    screen shows a prominent lead naming the count and pointing to answering (e.g.
    'N unanswered question(s) - answer to approve').
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: ReadinessTest.lead_shows_only_in_review_with_unanswered_questions + SpecDetailViewModelTest.lead_and_guidance_surface_for_review_spec_with_sole_unanswered_blocker
  comment: null
- id: ac2
  text: When unanswered open questions are the only remaining approval blocker, the
    approve control communicates 'answer N question(s) to approve' rather than a generic
    disabled/blocked state.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: ReadinessTest.sole_blocker_label_only_when_questions_are_the_only_blocker;
      SpecDetailViewModelTest surfaces approveGuidance
  comment: null
- id: ac3
  text: The inline answer affordance (the QuestionRow answer field) remains and reads
    as the primary action; Request-changes is visually secondary on that screen.
  verdict: unreviewed
  evidence:
  - kind: commit
    ref: 898c5e245eb22d00f2828225dafab6a185990ffa
    note: QuestionRow uses MultilineComposeInput as the PRIMARY inline answer; Request-changes
      is a secondary OutlinedButton -> sheet
  comment: null
- id: ac4
  text: Answering the last unanswered question inline unblocks approval via the existing
    auto-approve, with no Request-changes needed - exercised in the ViewModel/UI test.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: SpecDetailViewModelTest.answering_last_question_auto_approves_and_clears_lead_and_guidance
  comment: null
- id: ac5
  text: A review-phase spec with no open questions renders unchanged (no new lead).
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: SpecDetailViewModelTest.no_lead_or_guidance_when_no_open_questions + ReadinessTest
      null-at-zero
  comment: null
- id: ac6
  text: The Request-changes action opens the app's standard bottom sheet (the same
    sheet component used elsewhere in GC), not a dialog.
  verdict: unreviewed
  evidence:
  - kind: commit
    ref: 898c5e245eb22d00f2828225dafab6a185990ffa
    note: RequestChangesSheet = the ModalBottomSheet idiom shared with QueueScreen.RejectSheet,
      not a dialog
  comment: null
- id: ac7
  text: The answer field (QuestionRow) and the ask-a-question field (AskQuestionRow)
    use the reusable auto-expanding multi-line compose box, so a multi-line question
    or answer wraps and grows instead of horizontally scrolling.
  verdict: unreviewed
  evidence:
  - kind: commit
    ref: 898c5e245eb22d00f2828225dafab6a185990ffa
    note: 'QuestionRow + AskQuestionRow render the #282 MultilineComposeInput (auto-expanding
      multi-line)'
  comment: null
- id: ac8
  text: The Ask/Send/Update submit control is disabled while its field is blank (no
    silent no-op tap), and reads as an unmissable primary submit.
  verdict: unreviewed
  evidence:
  - kind: commit
    ref: 898c5e245eb22d00f2828225dafab6a185990ffa
    note: MultilineComposeInput sendEnabled=value.isNotBlank() disables the FilledIconButton
      submit while blank
  comment: null
- id: ac9
  text: A non-empty unsent answer/question draft is preserved (not silently dropped)
    when the operator leaves and returns to the spec-detail screen - verified in a
    ViewModel test - so a stale/unsent question can't be lost.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: SpecDetailViewModelTest.unsent_answer_and_ask_drafts_survive_leave_and_return_keyed_per_question
      (+ clears-only-that-question / clears-ask)
  comment: null
open_questions: []
non_goals:
- Any mship serve change - inline answer + auto-approve already work.
- Removing or gating the Request-changes action (it stays, just visually secondary
  + moved to a sheet).
- A full spec-review redesign - this is a targeted prominence/guidance + ergonomics
  change.
- Auto-submitting a half-typed question/answer on blur - the unsent draft is preserved,
  not force-sent (the operator still explicitly submits).
risks:
- Don't over-clutter the spec-detail header - the lead should be a single concise
  banner, shown only when unanswered questions exist.
- The 'only blocker is unanswered questions' computation must be accurate - reuse
  the existing summary/blockers logic (approval_blockers / the Summary) rather than
  re-deriving it.
- The multi-line compose box (#282) and the bottom-sheet component are existing GC
  pieces - reuse them, don't fork new ones, so the UX matches the rest of the app.
- Preserving the unsent draft must be per-question (keyed by question id) so switching
  between questions doesn't cross-contaminate drafts.
task_slug: gc-answer-questions
work_item_id: wi-20260717114503-20b21b17
clarification_reason: null
prose_verdicts: {}
---
## Problem

A review-phase spec with an unanswered open question CAN already be answered inline (SpecDetailScreen's QuestionRow has an answer field + Send; the Queue has a QuestionsCard), and answering the last one auto-unblocks approval. But two things make it a dead-end. (1) It isn't OBVIOUS that answering is the path to approval, so the operator uses 'Request changes' (which sends the spec to draft) as the exit, dropping it out of the approval flow (this bit us on no-orphan-specs). (2) The question UI itself is awkward: the Request-changes action is a cramped dialog rather than the bottom-sheet pattern used elsewhere in the app; the answer and ask-a-question fields are single-line (bad for multi-line questions/answers on mobile); and the Ask/Send/Update button is easy to miss, so the operator can type a question or answer and navigate away with it unsent — leaving a stale, silently-lost draft.

## User story

As the operator, when I open a spec with open questions, I want the review UI to make clear that answering unblocks approval AND to make asking/answering ergonomic — a Request-changes flow that matches the app's sheet pattern, multi-line fields, and a submit control I can't accidentally skip — so a spec with a question is never a dead-end and I never lose a half-typed question.

## Approach

GC-only (no serve change; inline answer POST + auto-approve already work — this makes that flow discoverable and ergonomic). Five parts. (1) Lead the eye to answering: when a review-phase spec has >=1 unanswered open question, show a prominent single-banner lead at the top of the spec detail (and the Queue's spec review) — 'N unanswered question(s) - answer to approve' - pointing at the answer fields that already exist. (2) Guide the approve control: when unanswered questions are the ONLY approval blocker, the approve control communicates 'Answer N question(s) to approve' instead of a generic disabled/blocked state. (3) Primary vs secondary: keep the inline QuestionRow (answer + Send) as the visually PRIMARY action; keep Request-changes available but clearly secondary so it's not the accidental default. (4) Request-changes as a bottom sheet: replace the current Request-changes dialog with the app's standard bottom-sheet component (matching the sheets used elsewhere in GC) for a consistent, roomier UX. (5) Ergonomic ask/answer fields: swap the single-line OutlinedTextField in QuestionRow (answer) and AskQuestionRow (ask) for the app's reusable auto-expanding multi-line compose box (from #282) so multi-line text wraps and grows; disable the Ask/Send/Update submit control while its field is blank (no silent no-op tap); and preserve a non-empty unsent draft across navigation (kept in the ViewModel, not silently dropped) so a half-typed or unsent question/answer is never lost.

## Testing

ViewModel/UI: the lead banner appears iff a review-phase spec has >=1 unanswered question and disappears at zero; the approve control's guidance text switches when unanswered-questions is the sole blocker; answering the last question auto-approves without Request-changes. New for this revision: Request-changes opens the sheet composable (not the dialog); QuestionRow + AskQuestionRow render the multi-line compose box; the submit control is disabled for blank input; and a typed-but-unsent draft survives a navigate-away/return (ViewModel retains it, keyed per question id).
