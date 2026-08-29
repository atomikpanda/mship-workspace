---
id: queue-action-affordance-and-whole-spec
title: Queue action affordance and whole-spec approve confirmation
status: approved
created_at: '2026-07-14T22:43:54.469727Z'
updated_at: '2026-07-15T14:09:09.176019Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: "Dragging a card reveals a directional overlay whose intensity grows with\
    \ drag distance \u2014 a green 'Approve' cue toward the right, a red 'Request\
    \ changes' cue toward the left \u2014 and it clears on release or spring-back."
  verdict: approved
  evidence: []
  comment: null
- id: ac2
  text: "The resting Queue card shows a subtle, always-visible directional hint (e.g.\
    \ faint edge cues or a muted 'Request changes  \u2190   \u2192  Approve' label)\
    \ so a first-time user can tell what swiping left vs right does before attempting\
    \ it, without cluttering the card and without looking like a tappable button."
  verdict: approved
  evidence: []
  comment: null
- id: ac3
  text: A one-time onboarding coach mark on the first Queue open demonstrates swipe-right
    = approve and swipe-left = request changes, is dismissible, can be re-opened from
    a small info affordance, and does not reappear on later launches.
  verdict: approved
  evidence: []
  comment: null
- id: ac4
  text: 'Swiping to finalize the LAST remaining chunk of a spec surfaces an explicit
    confirmation naming the spec (e.g. ''Approved spec: <title>'') with a longer snackbar
    duration; a non-final chunk keeps the existing ''Approved / Undo'' snackbar.'
  verdict: approved
  evidence: []
  comment: null
- id: ac5
  text: Card types where swipe-right is not an approve action (QuestionsCard, DecisionCard)
    show a one-line hint of what the operator needs to do to proceed, rather than
    implying swipe-to-approve; no approve/request-changes BUTTON is added to any card.
  verdict: approved
  evidence: []
  comment: null
open_questions: []
non_goals:
- "Replacing or de-emphasizing the swipe gesture with a persistent button bar \u2014\
  \ swipe is the intended primary interaction model; this spec makes swipe discoverable,\
  \ it does NOT add a competing tap target for approve / request-changes."
- "Undo for whole-spec approval \u2014 the server can't reverse an approval, so we\
  \ confirm explicitly instead of pretending it's undoable."
- "Reworking the reject/flag comment sheet (RejectSheet) \u2014 it already forces\
  \ a considered reason and is fine as-is."
- Redesigning the card content, the fling physics, or the pinned-Skip footer beyond
  adding the hints + confirmation.
risks:
- The always-visible hint and the drag overlay must stay subtle and must compose with
  the card's existing graphicsLayer rotation/translation without fighting it or hurting
  fling performance.
- The onboarding coach mark must be genuinely one-time (persisted) and dismissible,
  and re-openable so a user who dismissed it can find the gesture help again.
- "Hints must not read as tappable buttons \u2014 they teach the swipe, they are not\
  \ an alternate tap path."
task_slug: null
work_item_id: null
clarification_reason: null
prose_verdicts:
  problem:
    verdict: approved
    comment: null
  user_story:
    verdict: approved
    comment: null
  approach:
    verdict: approved
    comment: null
  non_goals:
    verdict: approved
    comment: null
  risks:
    verdict: approved
    comment: null
---
## Problem

On the Queue — the operator's primary approval surface — the swipe gesture that drives everything is undiscoverable, and for the highest-stakes action there's no confirmation. Swipe-right approves and swipe-left requests changes, but the card gives ZERO on-screen indication that swiping does anything, which direction means what, or how far to swipe: FlingCard just translates + tilts with no stamp, edge color, or threshold cue, so a first-time operator has no way to learn the model except by accident. Separately, a swipe-right on the LAST chunk of a spec finalizes the ENTIRE spec via a path that deliberately does not arm undo, so the reactive snackbar shows nothing — the most consequential, effectively irreversible action produces no confirmation at all, while a low-stakes single-chunk advance shows 'Approved / Undo'.

## User story

As an operator, I want swiping the card to stay the way I approve (swipe right) or request changes (swipe left) — that gesture IS the interaction model I want — and I want the app to TEACH me that gesture with light onboarding and always-visible hints, so it's obvious what swiping does without replacing it with buttons; and when a swipe finalizes a whole spec, I want it to tell me what I just shipped.

## Approach

GC-only. Swipe stays THE interaction model on the Queue (right = approve, left = request changes); this spec makes that gesture DISCOVERABLE and adds a confirmation for the highest-stakes case, explicitly WITHOUT adding a competing button bar. (1) Drag affordance: while dragging, reveal a directional overlay under the card — a green '✓ Approve' cue toward the right, a red '⚑ Request changes' cue toward the left — whose opacity/scale grows with drag distance so the direction, the meaning, and the fling threshold are all FELT; it clears on release / spring-back. (2) Always-visible hint: a subtle, persistent cue on the resting card (e.g. faint edge chevrons or a muted 'Request changes  ←   →  Approve' line) so a first-time user can see what a swipe does before trying it — kept light enough not to clutter the card. (3) First-run onboarding: a one-time coach mark on the first Queue open that demonstrates swipe-right = approve and swipe-left = request changes; dismissible, re-openable from a small info affordance, and persisted so it never reappears. (4) Whole-spec confirmation: when a swipe finalizes an ENTIRE spec (its last remaining chunk), surface an explicit, longer-duration confirmation naming it ('Approved spec: <title>') even though server-side undo isn't possible; single-chunk advances keep the existing 'Approved / Undo'. (5) Card types where swipe-right isn't an 'approve' (a QuestionsCard needs answers, a DecisionCard needs an option) show a one-line hint of what's needed instead of implying swipe-to-approve. Reuses the existing approve/reject paths (approveAllCurrent, RejectSheet) and the semantic color set — no server change.

## Testing

JVM unit tests only (no emulator). Queue logic lives in the tested QueueViewModel — assert that: a swipe that finalizes the last chunk yields the whole-spec confirmation state while a non-final swipe yields the 'Approved/Undo' state (via approveAllCurrent), the coach-mark-seen flag persists and gates the onboarding, and each card type maps to the correct hint (approve-capable vs 'needs answers'/'needs a decision'). Compose-only pieces (drag overlay alpha, resting-hint rendering, coach-mark overlay) are verified by compilation + manual note; keep the pure logic (which directional cue, is-final-chunk, coach-mark-seen, card-type hint) in testable functions. Follow the existing QueueViewModelTest / QueueCardTest patterns.
