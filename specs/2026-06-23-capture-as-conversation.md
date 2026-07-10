---
id: capture-as-conversation
title: 'Capture-as-conversation: promote a thread into a spec (mship spec from-thread
  + View spec link)'
status: implemented
created_at: '2026-06-23T16:52:05.578183Z'
updated_at: '2026-06-23T23:29:00.242862Z'
affected_repos:
- mothership
- ground-control
acceptance_criteria:
- id: ac1
  text: 'mothership: the Thread model gains `spec_id` (default None, serialized into
    model_dump/JSON and exposed on GET /threads/{id}); MessageStore.link_spec(thread_id,
    spec_id) sets it (load-set-save); unit tests cover both.'
  verdict: unreviewed
- id: ac2
  text: 'mothership: `mship spec from-thread <thread-id> [--title T]` creates a new
    spec (title from --title or the thread''s subject, with a safe fallback when blank),
    links thread.spec_id to the new spec, and prints a drafting prompt that includes
    the thread transcript (messages joined role: text); it 404s/errors on an unknown
    thread; covered by a CLI test.'
  verdict: unreviewed
- id: ac3
  text: 'ground-control: the Thread DTO deserializes `spec_id` (@SerialName) as `specId:
    String? = null`; existing thread parsing is unaffected.'
  verdict: unreviewed
- id: ac4
  text: 'ground-control: the ConversationScreen shows a ''Make this a spec'' action
    that posts a canonical request message (via ConversationViewModel.requestSpec,
    reusing the send path), and a ''View spec ->'' affordance shown only when `thread.specId
    != null` that invokes an onViewSpec(connectionId, specId) callback wired in GroundControlApp
    to navigate to specDetail/{connectionId}/{specId}.'
  verdict: unreviewed
- id: ac5
  text: ConversationViewModel.requestSpec() posts the canonical message and updates
    the thread from the returned Thread (same as send); a unit test verifies the message
    is posted.
  verdict: unreviewed
- id: ac6
  text: Error handling is unchanged; the 'View spec' affordance is absent when the
    thread has no spec_id and present once linked.
  verdict: unreviewed
- id: ac7
  text: 'Tests: mothership (link_spec; from-thread creates+links+prompt-includes-transcript;
    404; GET /threads/{id} exposes spec_id) and ground-control (Thread DTO spec_id;
    ConversationViewModel.requestSpec posts the message) pass; ./gradlew assembleDebug
    + testDebugUnitTest and the mothership pytest suite are green.'
  verdict: unreviewed
open_questions: []
non_goals:
- "Auto-dispatch: the agent still must run `mship inbox` and `mship spec from-thread`\
  \ (no daemon auto-drafting) \u2014 that's the later auto-dispatch layer"
- The agent automatically deciding to draft without the 'make this a spec' request
  message
- 'Task-steering (slice 4): tying threads to a task / surfacing open_questions as
  messages'
- Notifications when the spec is drafted
- Editing the drafted spec from the chat (review/act happens on the existing spec-detail
  screen)
- Any change to the spec draft/apply lifecycle itself (reused as-is)
risks:
- "from-thread links thread.spec_id at spec-creation time, so 'View spec' can open\
  \ a spec still in `drafting` (empty body) until the agent applies the draft. Acceptable\
  \ \u2014 the spec-detail screen already renders any status read-only when not needs_review;\
  \ the agent's reply tells the user when it's ready."
- "The transcript-seeded draft prompt can be large for long threads; build_draft_prompt\
  \ just embeds it as the intent \u2014 fine, but note long conversations produce\
  \ long prompts."
- spec id is slugified from the title/subject; a blank subject must yield a safe fallback
  title so new_spec doesn't fail (mirror POST /threads subject derivation).
- Message-convention promote relies on the agent recognizing the request; `mship spec
  from-thread` makes it a single obvious step, but a careless agent could ignore it
  (accepted tradeoff for agent-agnosticism; auto-dispatch later tightens it).
task_slug: capture-as-conversation
work_item_id: wi-20260702110439-b14a1da5
---
## Problem

The message mailbox (slice 1) and the phone chat UI (slice 2) are merged: you can converse with an agent from the phone. But a conversation can't yet become a structured spec — the payoff of 'easier capture'. This slice closes that loop: brain-dump in a thread, signal 'make this a spec', and the host agent drafts a real spec from the conversation (via the existing mship spec draft/apply), links it to the thread, and the phone offers a 'View spec' jump to the spec-detail screen. Agent-agnostic: the agent does the drafting; mship provides the link + a convenience, and the phone signals intent with a plain message (no new protocol).

## User story

As a Mothership operator, I want to turn a chat thread into a spec from my phone — message a half-formed idea, tap 'Make this a spec', and have an agent draft a structured spec I can then open and review — so capture goes from form-filling to conversation.

## Approach

Two repos. (1) mothership: add `spec_id: str | None = None` to the Thread model (serialized; exposed on GET /threads/{id}); MessageStore gains `link_spec(thread_id, spec_id)` (load-set-save). New CLI `mship spec from-thread <thread-id> [--title T]`: loads the thread (404 if missing), creates a new spec via the existing new_spec helper (title = --title or the thread subject), links thread.spec_id to it, and prints the drafting prompt (build_draft_prompt) seeded with the thread transcript (messages joined as 'role: text') — so the agent runs that prompt through an LLM -> SpecDraft JSON -> `mship spec apply <spec-id> --from-json`, then `mship reply`s the thread. The spec sits in `drafting` until applied; linking at creation means the phone's 'View spec' appears immediately and opens the (initially drafting, then populated) spec. (2) ground-control: the Thread DTO gains `specId` (@SerialName spec_id); ConversationViewModel gains `requestSpec()` that posts a canonical human message ('Please turn this thread into a spec.') via the existing send path; ConversationScreen shows a 'Make this a spec' action (calls requestSpec) and, when `thread.specId != null`, a 'View spec ->' affordance that navigates to specDetail/{connectionId}/{specId} (the spec-detail screen from the earlier slice). Wire onViewSpec in GroundControlApp's thread route. The promote signal is just the posted message — the agent reads it in `mship inbox` and runs `mship spec from-thread`. JVM/pytest unit tests; screens build-verified.

## mship spec from-thread (the convenience)

In src/mship/cli/spec.py add a `from-thread` subcommand: container -> MessageStore(state_dir/messages).get(thread_id) (404 via the CLI's error path if None); SpecStore(workspace_root/specs); from mship.core.spec_draft import new_spec, build_draft_prompt. title = --title or (thread.subject.strip() or 'captured note'); spec = new_spec(title, now=now); store.save(spec); messages.link_spec(thread_id, spec.id); transcript = '\n'.join(f'{m.role}: {m.text}' for m in thread.messages); print build_draft_prompt(spec.id, transcript) plus a one-line note ('created spec <id> linked to thread <tid>; run the prompt, then: mship spec apply <id> --from-json <file>, then mship reply <tid> ...'). The agent then runs the prompt -> SpecDraft JSON -> mship spec apply, and mship reply's the thread. No new draft/apply code — from-thread just seeds + links. MessageStore.link_spec(thread_id, spec_id): get thread (KeyError if missing), set thread.spec_id, save.
