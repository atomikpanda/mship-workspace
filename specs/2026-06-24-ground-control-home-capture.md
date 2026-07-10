---
id: ground-control-home-capture
title: 'Ground Control Home capture: FAB to thread, agent triages to spec'
status: implemented
created_at: '2026-06-24T19:10:02.459181Z'
updated_at: '2026-06-24T20:31:24.988909Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: The Home screen shows a Capture floating action button; the Tasks and Settings
    tabs do not gain one.
  verdict: unreviewed
- id: ac2
  text: Tapping the Capture FAB opens the capture flow with a workspace picker that
    auto-selects when there is exactly one connection, offers a dropdown when there
    are several, and shows an 'add a workspace in Settings' empty state when there
    are none.
  verdict: unreviewed
- id: ac3
  text: Entering a non-empty message and tapping Send creates a thread in the selected
    workspace and navigates the user into that thread's Conversation screen.
  verdict: unreviewed
- id: ac4
  text: "The capture flow reuses the existing new-thread creation logic \u2014 there\
    \ is no second, duplicate thread-creation code path."
  verdict: unreviewed
- id: ac5
  text: The Conversation screen reached from capture exposes the shipped 'Make this
    a spec' affordance, so a captured thread can be promoted to a spec.
  verdict: unreviewed
- id: ac6
  text: The capture entry reads as 'Capture' to the user (title/labels), not 'New
    thread'.
  verdict: unreviewed
- id: ac7
  text: JVM unit tests cover the capture entry's create-then-navigate behavior and
    the workspace-selection rules (reusing/extending NewThreadViewModel coverage);
    navigation wiring is verified by a successful debug compile (no emulator).
  verdict: unreviewed
open_questions:
- id: q1
  text: 'Implementation shape: relabel/parameterize the existing NewThreadScreen for
    capture, or add a thin dedicated CaptureScreen wrapper around the same ViewModel?
    (Lean: parameterize/relabel to avoid a near-duplicate screen.)'
  answer: 'no need to duplicate '
- id: q2
  text: Does the capture screen keep the existing optional 'subject' field, or collapse
    to body-only for minimum friction?
  answer: body only
- id: q3
  text: FAB icon/label on Home (e.g. Add vs Edit icon, 'Capture' label) and confirmation
    that slice 2 adds it to Home only.
  answer: compose new message icon
non_goals:
- Any jot-vs-brainstorm mode toggle or pre-classification UI (capture is one action;
  the agent triages)
- On-device or server-side LLM drafting (drafting stays agent-in-the-loop / store-and-forward)
- A dedicated personal 'Captures' staging area separate from threads
- '#156''s ''refine existing spec'' and ''create directive'' entry points (deferred)'
- Voice capture / transcription (D1, later slice)
- Auto-dispatch, push notifications, background polling
- iOS
- Any mothership API change
risks:
- 'Depends on slice 1 (ground-control-ia-overhaul, open PR #11) for the Home screen
  and the newThread route; must stack on that branch and not merge before slice 1.'
- "Reusing NewThreadScreen for 'capture' risks copy/affordance mismatch (it says 'New\
  \ thread', has an optional subject) \u2014 needs capture-oriented labeling without\
  \ forking a near-duplicate screen."
- The needs_review outcome is asynchronous (agent must run), so capture gives no instant
  spec; the UI must not imply a spec was created synchronously.
- "A Home FAB may later contend with a Tasks-tab FAB or other Home affordances \u2014\
  \ placement should not box that in."
task_slug: ground-control-home-capture
work_item_id: wi-20260702110439-3eb84b52
---
## Problem

Capturing intent from your phone is the most natural mobile moment, but after slice 1 there is no way to START anything from Home — you can only act on what's already in the 'Needs you' queue, or create a thread from inside a workspace's browse screen. A fleeting idea, a bug you just spotted, or a 'go do X' directive has nowhere to land. And the obvious design trap is forcing the user to pre-classify each capture (quick note vs feature brainstorm) at the exact moment they least want a decision; the host agent, in conversation, is far better placed to decide whether something is a one-off fix or worth shaping into a spec.

## User story

As someone running mship workspaces from my phone, I want one fast way to drop a thought, bug, or directive from the Home screen without choosing a mode, so that it reaches my agent immediately and the agent figures out — with me, in the thread — whether it's a quick fix or something to shape into a spec.

## Approach

Add a single '+' Capture FloatingActionButton to the Home screen. Tapping it opens the capture flow: a workspace target picker (auto-selected when there is one connection; a dropdown when several; an 'add a workspace in Settings' empty state when none) and a message field with a Send action. Send creates a thread in the chosen workspace (reusing the existing thread-creation path) and navigates the user INTO that thread's Conversation screen — exactly the shipped two-way chat. From there the host agent picks the thread up via `mship inbox` and triages it conversationally: it does the quick fix, or shapes the idea into a spec and promotes it via `mship spec from-thread`. The shipped 'Make this a spec' affordance on the Conversation screen lets either party pull the trigger explicitly. The resulting needs_review spec, and any agent reply/question, surface back in the slice-1 Home 'Needs you' queue. This is deliberately one action with no jot/brainstorm toggle. It is also mostly reuse: slice 1 already built the `newThread` route + NewThreadScreen (workspace picker + message -> create -> navigate into the conversation), and the Conversation screen + 'Make this a spec' shipped in PR #10. The genuinely new code is the Home Capture FAB, its wiring to the capture flow (unscoped so the workspace picker shows), and capture-oriented copy so the screen reads as 'Capture' rather than 'New thread'. No new storage and no separate 'captures' staging area — the agent's existing thread inbox IS the triage inbox. Client-side only; no mothership change.

## Architecture

Reuse map: HomeScreen gains a Scaffold floatingActionButton -> nav callback (e.g. onCapture) -> GroundControlApp navigates to the existing `newThread` route (unscoped, so the workspace picker shows) -> NewThreadScreen + NewThreadViewModel.create() (already exist) -> onCreated navigates to `thread/{conn}/{id}` -> ConversationScreen (with the shipped 'Make this a spec'). The only genuinely new production code is the Home FAB + its wiring and capture-oriented copy (a label/param on NewThreadScreen or a thin wrapper). Depends on slice 1's HomeScreen and `newThread` route. No mothership/API change. Branch stacks on `feat/ground-control-ia-overhaul`; task declares `depends_on: ground-control-ia-overhaul` so its finish gate holds until slice 1's PR merges.

## Testing

JVM unit tests only (no emulator), consistent with slice-1 patterns. The thread-creation + workspace-selection behavior is already covered by NewThreadViewModelTest; extend it if a capture parameter/flag is added. The Home FAB -> capture navigation and the create -> conversation navigation are verified by a successful `./gradlew compileDebugKotlin`/`assembleDebug` plus manual smoke against a running workspace (the asynchronous agent-promotes-to-spec outcome is server-state dependent and is checked by manual smoke, mirroring slice 1's approach to such criteria).
