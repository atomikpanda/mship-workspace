---
id: ground-control-chat-qol-polish-gc30-pr1
title: 'Ground Control chat QoL polish (GC#30 PR1): hold-to-copy, input padding, choice
  contrast, option numbers, jump-to-latest pill'
status: implemented
created_at: '2026-07-08T12:48:19.979914Z'
updated_at: '2026-07-08T13:42:36.655346Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: "Any message bubble's text is selectable/copyable via a long-press (native\
    \ text selection), with no dedicated copy button \u2014 implemented by wrapping\
    \ the message content in a SelectionContainer. Agent-bubble markdown links must\
    \ still open."
  verdict: approved
- id: ac2
  text: The chat compose bar has adequate padding below it so the input is not flush
    against the keyboard when the IME is open, and against the system nav bar when
    it is closed (imePadding + navigationBarsPadding + a small bottom gap).
  verdict: approved
- id: ac3
  text: "Choice/decision bubble contrast is raised \u2014 BOTH the decision question\
    \ text (full-contrast onSurface, matching agent prose) AND the non-recommended\
    \ option buttons (explicit themed container/content colors) are legible."
  verdict: approved
- id: ac4
  text: "Each choice option shows a leading number (1., 2., 3., \u2026) in its label;\
    \ the reply that is SENT remains the raw option text only (the number is display-only,\
    \ not sent)."
  verdict: approved
- id: ac7
  text: "When a new message arrives while the user is scrolled up in history, the\
    \ view does NOT auto-yank to the bottom (the existing deliberate near-bottom gate\
    \ is preserved); instead a \"jump to latest \u2193\" pill appears and taps to\
    \ the bottom. Auto-scroll still happens when the user is already near the bottom."
  verdict: approved
open_questions: []
non_goals:
- "Item 5 (comment/caveat appended to a choice) \u2014 deferred to a separate design/PR;\
  \ it touches reply semantics."
- "Item 6 (multiselect choice options) \u2014 deferred; needs a backend `multi` flag\
  \ on the decision payload + `mship ask --multi`, so it is its own design/PR."
- "Any change to the mothership decision/ask reply format \u2014 PR1 is Ground-Control-only."
risks:
- 'SelectionContainer vs tappable markdown links: wrapping agent bubbles may compete
  with the markdown library''s link tap/long-press; verify links still open, and fall
  back to selection-on-human-bubbles + a copy affordance on agent bubbles if they
  conflict.'
- The jump-to-latest effect must distinguish a genuinely new inbound message from
  an indicator/state toggle so the pill does not appear spuriously.
task_slug: ground-control-chat-qol-polish-gc30-pr1
work_item_id: null
---
## Problem

From GitHub GC#30 ("Quality of life improvements to ground control chat threads"). The chat threads have several small friction points: you can't copy message text, the input box sits flush against the keyboard, choice bubbles are low-contrast and unlabeled, and new messages don't bring you to the bottom. This is the low-risk, Ground-Control-only slice (items 1, 2, 3, 4, 7). Items 5 (comment-with-choice) and 6 (multiselect) are deferred because they touch reply semantics and need mothership-side support (see non-goals).

## User story

As the operator using Ground Control on my phone, I can long-press any message to copy it, type comfortably above the keyboard, read and pick clearly-numbered high-contrast choice options, and get pulled to the latest message (or tap a pill to jump there) — so the chat feels polished.

## Approach

All changes are in `ground-control/android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/`, informed by a code exploration of the current chat UI:

1. **Hold-to-copy** — wrap the message content of `MessageRow` (ConversationScreen.kt) in `androidx.compose.foundation.text.selection.SelectionContainer` so both plain human bubbles and the markdown agent bubbles get native long-press selection + copy. Verify markdown links still open (risk noted).
2. **Compose-bar padding** — add a bottom gap on the compose bar and combine `imePadding()` with `navigationBarsPadding()` so there's breathing room both when the keyboard is open and closed.
3. **Choice contrast (both elements)** — in `DecisionCard.kt`, paint the question text with `onSurface` (full-contrast, matching agent prose) and give the non-recommended option buttons explicit themed `filledTonalButtonColors` (or OutlinedButton with an `onSurface` label) so their labels are legible in the dark scheme.
4. **Option numbers** — in `DecisionCard.kt`, render each option label as `"${index + 1}. $option"`; keep the SENT reply as the raw `option` string (number is display-only). Operator decision: numbers (not letters), text-only send.
5. **Jump-to-latest pill (item 7)** — keep the existing deliberate "only auto-scroll if near the bottom" gate in ConversationScreen.kt's `LaunchedEffect(itemCount)` (added on purpose to avoid yanking the view during history reading). When a new inbound message arrives while scrolled up, show a small "jump to latest ↓" pill that scrolls to the bottom on tap. Operator decision: pill, not unconditional scroll.

Testing: JVM unit tests where logic is testable; `mship build --repos ground-control` (assembleDebug) for the Compose changes; manual scan of the 5 behaviors.

**Deferred (own design/PR):** Item 5 (append a comment to a choice — can ship UI-only by sending "option — comment", or add structured capture later) and Item 6 (multiselect — needs a `multi` flag on the mothership decision payload + `mship ask --multi`).
