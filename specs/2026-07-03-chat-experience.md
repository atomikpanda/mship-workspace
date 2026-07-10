---
id: chat-experience
title: Improve the Ground Control chat experience
status: implemented
created_at: '2026-07-03T02:30:55.260155Z'
updated_at: '2026-07-07T16:43:07.355526Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: Agent messages render at full, readable contrast (a high-contrast foreground
    on the bubble), not the muted role.
  verdict: approved
- id: ac2
  text: "Message text renders markdown \u2014 bold/italic, lists, inline code + code\
    \ blocks, and links \u2014 instead of plain text."
  verdict: approved
- id: ac3
  text: With the keyboard open you can scroll up through history and it stays put
    (no force-scroll to the bottom); new incoming messages still auto-follow when
    you're already at the bottom.
  verdict: approved
- id: ac4
  text: "The 'Make this a spec' header button is gone (and `requestSpec()` + its unit\
    \ test are removed); the separate 'View spec \u2192' button still appears when\
    \ the thread has a spec."
  verdict: approved
- id: ac5
  text: The compose bar is a rounded, messaging-style input with a modern filled Send
    button, laid out so a leading attach button can be added later without relayout.
  verdict: approved
- id: ac6
  text: The app builds (assembleDebug) and the JUnit4 test suite is green (the requestSpec
    test removed; any new scroll/render behavior covered where unit-testable).
  verdict: approved
open_questions:
- id: q1
  text: 'Markdown scope: render markdown for BOTH agent and human messages, or agent-only?
    (human messages can contain markdown too, but are often short/plain)'
  answer: agent only
- id: q2
  text: "Confirm: remove ONLY the 'Make this a spec' button, keeping the separate\
    \ 'View spec \u2192' affordance that appears when a thread has a linked spec?"
  answer: correct
non_goals:
- "Building the file attach/send feature \u2014 only design the compose-bar layout\
  \ to accommodate a future leading attach button."
- Changing the message/thread data model or the API.
- Touching the decision-card flow (the typed-decision overlay stays as-is).
risks:
- "Markdown in tight chat bubbles needs spacing/typography tuning so it doesn't look\
  \ like a document \u2014 mitigated by a bubble-tuned wrapper, not the raw full-width\
  \ `Markdown` call."
- "Over-removing auto-scroll could stop the view following new messages when you ARE\
  \ at the bottom \u2014 mitigated by a 'near bottom' gate that still follows when\
  \ appropriate."
- A pill-shaped compose bar needs an explicit `RoundedCornerShape` (the theme `AppShapes`
  caps at 8dp).
task_slug: chat-experience
work_item_id: null
---
## Problem

The Ground Control chat is hard to use (Linear MOS-212). Agent messages are low-contrast — the agent bubble renders its text with the muted `onSurfaceVariant` role (dark: 0xFF6272A4 slate-blue on a 0xFF1A1F2B panel), which is hard to read. Messages render as plain text even though agents almost always write markdown (bold, lists, code, links) — so formatting is lost. You can't scroll up through history while the keyboard is open: an IME-inset-keyed LaunchedEffect force-scrolls to the bottom whenever the keyboard height changes, fighting any scroll-up. The compose bar is a boxy OutlinedTextField + a bare send icon that doesn't feel like a messaging app. And a 'Make this a spec' button in the thread header is now confusing given the WorkItem/spec flow (and it only posts a canned chat message).

## User story

As an operator chatting with an agent in Ground Control, I want readable, markdown-rendered messages, natural scroll-while-typing, and a modern messaging-style compose bar (without the stale 'Make this a spec' button), so the chat feels like a real messaging app and I can actually read what the agent says.

## Approach

Ground-control only, all in `ui/messages/ConversationScreen.kt` (+ small `ConversationViewModel` cleanup). (1) Contrast: move agent-message text from the muted `onSurfaceVariant` role to a full-contrast foreground (`onSurface`); keep the human bubble (already high-contrast). (2) Markdown: reuse the already-present `com.mikepenz:multiplatform-markdown-renderer-m3` (the dep used by `ui/specdetail/SpecBodyMarkdown.kt`) via a small bubble-tuned wrapper in `MessageRow`, so message text renders markdown with tighter spacing than the full-width spec body and code spans in JetBrainsMono. (3) Scroll: remove/gate the IME-inset-keyed auto-scroll `LaunchedEffect` (ConversationScreen ~144-147) that force-pins to the bottom on keyboard changes; auto-scroll to a new message only when the user is already near the bottom, so scroll-up while typing sticks. Keep `imePadding()`. (4) Compose bar: restyle `ComposeBar`'s input row into a rounded (pill) container with a modern filled/tonal circular Send button, and structure the Row so a leading file-attach button can slot in later without relayout (structure only — no non-functional button now). Draft/send wiring unchanged. (5) Remove the 'Make this a spec' header action (the `IconButton` + `NoteAdd` import + `ConversationViewModel.requestSpec()` + its test). Keep the separate 'View spec →' button.

## UI / Design notes

Bubble: agent text -> onSurface (full contrast); human bubble unchanged. Markdown: reuse com.mikepenz multiplatform-markdown-renderer-m3 (already a dependency; see SpecBodyMarkdown) through a bubble-tuned wrapper that inherits the bubble's color + typography, uses tighter vertical spacing than the spec body, and renders code in JetBrainsMono. Compose bar: a single rounded container (explicit RoundedCornerShape since AppShapes caps at 8dp) around the text field; a filled/tonal circular Send button replacing the bare icon; an in-flight spinner state preserved; the input Row structured so a leading attach IconButton drops in later. Keep the existing sendError surfacing + the gated-decision 'Choose an option above' branch.
