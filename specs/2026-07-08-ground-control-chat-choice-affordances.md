---
id: ground-control-chat-choice-affordances
title: 'Ground Control chat choice affordances (GC#30 PR2): comment-with-choice +
  multiselect'
status: implemented
created_at: '2026-07-08T12:58:49.396453Z'
updated_at: '2026-07-08T20:31:59.441078Z'
affected_repos:
- mothership
- ground-control
acceptance_criteria:
- id: ac1
  text: "Comment-with-choice: from a decision bubble the operator can pick an option\
    \ AND append a short comment/caveat before sending (e.g. \"add a share button\
    \ \u2014 make sure the word share is visible\"). This works even when the decision\
    \ is gated (allow_free_text=false), because the reply is anchored to a specific\
    \ option."
  verdict: approved
- id: ac2
  text: "Comment-with-choice reply format: the sent message combines the option and\
    \ the caveat in a single human message the agent can read (v1 free-text path \u2014\
    \ no wire-format change required); exact format is an open question below."
  verdict: approved
- id: ac3
  text: 'Multiselect: a decision can be marked as permitting multiple selections;
    in Ground Control such a decision renders its options as toggles with a single
    Send button, and sends the chosen options as one reply.'
  verdict: approved
- id: ac4
  text: 'Multiselect permission is signalled from the backend: the decision payload
    carries a `multi` flag (default false) set via `mship ask --multi`, so Ground
    Control only offers multiselect when the decision actually allows it (a single-choice
    decision cannot be answered with several options).'
  verdict: approved
- id: ac5
  text: Single-select decisions and the existing tap-to-send behavior are unchanged
    when neither comment nor multi is used (no regression to the current flow).
  verdict: approved
open_questions:
- id: q1
  text: 'Comment-with-choice affordance: long-press an option, a "+ comment" icon
    per option, or a single "customize / add note" action on the card? (brainstorm
    leaned: a per-option affordance opening an AlertDialog prefilled with the option
    text.)'
  answer: yes but I'd rather it be a compose style sheet instead of a dialog because
    sometimes text can get lengthy
- id: q2
  text: "Comment-with-choice reply format: \"1. <option> \u2014 <caveat>\" vs \"<option>:\
    \ <caveat>\" vs free prose? Keep the option text verbatim so the agent can still\
    \ map it to the offered option."
  answer: "I think 1. option text \u2014 caveat"
- id: q3
  text: 'Comment-with-choice capture: ship free-text-only first (send the combined
    string; agent interprets), or add STRUCTURED capture now (record chosen option/index
    + caveat separately on the wire for reliable parsing/analytics)? (brainstorm recommended
    free-text first.)'
  answer: use free text for now but we will eventually move to structured later date
    fyi
- id: q4
  text: 'Multiselect send semantics: one combined message (recommended) vs N separate
    messages, and the combined-text format (e.g. "Selected: 1. <a>; 3. <c>").'
  answer: one combined message
- id: q5
  text: 'Multiselect permission shape: a boolean `multi`, or `min_select`/`max_select`
    counts? (boolean is the simpler v1 unless min/max is genuinely needed.)'
  answer: boolean for now
non_goals:
- "The PR1 chat polish items (hold-to-copy, input padding, choice contrast, option\
  \ numbers, jump-to-latest pill) \u2014 shipped separately as ground-control-chat-qol-polish-gc30-pr1."
- Changing how single-select, non-commented decisions work today.
risks:
- If comment-with-choice bypasses the allow_free_text=false gate, make sure the reply
  is still clearly anchored to a specific offered option so the agent does not mistake
  a caveat for a free-form answer to a gated decision.
- 'A backend `multi` flag touches the decision/ask payload shared by CLI + serve +
  GC; version/compat: older GC clients must treat an unknown `multi` as false (default)
  and keep working.'
task_slug: ground-control-chat-choice-affordances
work_item_id: null
---
## Problem

From GitHub GC#30, the two chat-choice items that need real design (deferred out of PR1 because they touch reply semantics and the mothership side): (5) letting the operator append a comment/caveat to a chosen option, and (6) multiselect choices. Capturing now so the design isn't lost; several sub-decisions are recorded as open questions for review.

Key architectural fact (from the code exploration): a choice reply today is just a plain free-text human message — tapping an option posts the option's literal string; there is no structured "which option/index" on the wire, and the agent interprets `messages[-1].text`. That means comment-with-choice can ship UI-only (send a combined string), while multiselect needs a backend signal so GC knows a decision permits multiple answers.

## User story

As the operator answering a decision on my phone, I can (5) pick an option and add a short caveat before sending — even on a gated decision — and (6) when a decision allows it, select several options at once and send them together — so my replies carry the nuance the agent needs.

## Approach

**Item 5 — comment-with-choice (GC-first, backend optional):**
- In `DecisionCard.kt`, add a per-option affordance (see q1) that opens an `AlertDialog` (reuse the SpecDetail/Review dialog pattern) prefilled with the option text and a comment field. On confirm, send a single combined message via the existing `vm.send(...)` path. This must bypass the `allow_free_text=false` gate because it is anchored to a specific option.
- v1 uses the free-text channel (no wire change). Structured capture (chosen option/index + caveat as separate fields) is a possible later enhancement (q3).

**Item 6 — multiselect (needs backend flag):**
- mothership: add `multi: bool = False` (or min/max — q5) to the decision payload (`core/message.py` `DecisionPayload`) and a `mship ask --multi` option (`cli/message.py`), defaulting off; older clients treat absent/unknown as false.
- Ground Control: `Decision` DTO (`ThreadDtos.kt`) gains the flag; `DecisionCard.kt` renders multi-enabled decisions as toggle chips/checkboxes with a single Send button that concatenates the chosen options into one reply (q4). Single-select decisions are unchanged.

**Split guidance:** item 5 (GC-only, free-text path) is smaller and can land first; item 6 (backend flag + GC) is a second change. They are grouped here as "PR2 / choice affordances" but may become two PRs.

Resolve the open questions (q1–q5) on review; then this becomes an implementation plan (likely one plan with an item-5 slice and an item-6 slice).
