---
id: ground-control-messages-tab
title: 'Ground Control Messages tab: two-way agent chat (thread list + conversation;
  repurposes Capture)'
status: implemented
created_at: '2026-06-23T01:11:06.710854Z'
updated_at: '2026-06-23T14:12:02.268358Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: The Capture bottom-nav tab is repurposed to 'Messages' (label + a chat/forum
    icon + route) and renders the thread-list screen; the old quick-capture CaptureScreen
    and CaptureViewModel (and CaptureViewModelTest) are removed, and the app still
    builds with the nav at 5 destinations.
  verdict: unreviewed
- id: ac2
  text: ThreadSummary, Thread, and Message DTOs deserialize the mailbox payloads (including
    awaiting_reply, the messages list, null/optional fields, ignoreUnknownKeys); the
    API gains listThreads (GET /threads), getThread (GET /threads/{id}), createThread
    (POST /threads {text, subject?}), and postMessage (POST /threads/{id}/messages
    {text}) with bearer auth and the existing 401/404/409 mapping, covered with Ktor
    MockEngine.
  verdict: unreviewed
- id: ac3
  text: A ThreadsRepository aggregates listThreads across all configured connections
    in parallel; the Messages list groups threads by workspace, each row showing subject
    (fallback when blank), a last-message preview, an awaiting-reply indicator, and
    the updated time; one unreachable workspace shows an error chip while others render;
    pull-to-refresh re-fetches.
  verdict: unreviewed
- id: ac4
  text: A 'new thread' action composes an optional subject plus a first message, calls
    createThread (POST /threads), and navigates to the resulting conversation.
  verdict: unreviewed
- id: ac5
  text: 'Tapping a thread opens the conversation (thread/{connectionId}/{threadId}):
    the message timeline distinguishes human vs agent, a compose box posts a human
    message and updates the view from the returned Thread, an awaiting indicator shows
    whether it is waiting on an agent, pull-to-refresh re-syncs, and back returns
    to the list.'
  verdict: unreviewed
- id: ac6
  text: 'Error handling matches the other screens: 401 -> auth error linking to Settings,
    404 -> ''thread no longer available'', network -> retry; covered by the ViewModel
    tests.'
  verdict: unreviewed
- id: ac7
  text: 'Tests (JVM unit / MockEngine): DTO deserialization; API method/path/auth/body
    + 401/404 mapping; ThreadsRepository parallel aggregation + partial failure; MessagesViewModel
    grouping (workspace -> threads); ConversationViewModel load + post-message + error
    states. ./gradlew assembleDebug and testDebugUnitTest are green.'
  verdict: unreviewed
open_questions: []
non_goals:
- "Promoting a thread into a spec via mship spec draft/apply (capture-as-conversation)\
  \ \u2014 slice 3"
- "Task-steering: tying threads to a task or surfacing a task agent's open_questions\
  \ as messages \u2014 slice 4"
- "Notifications / push when a reply lands \u2014 a later slice"
- "Real-time delivery (SSE/websockets) \u2014 polling / pull-to-refresh only"
- Editing or deleting messages; voice input
- Keeping the old form-based Quick Capture screen (it is retired by this slice)
- iOS; Compose UI / instrumentation / emulator tests
risks:
- Repurposing the Capture tab removes the just-shipped Quick Capture form. That is
  intentional (the chat is the better capture), but deleting CaptureScreen/CaptureViewModel
  + their tests must not break the build or other screens; SpecApi.createSpec/NewSpecBody
  are kept (used by the later capture-as-conversation slice).
- Threads belong to a specific workspace/connection; the list aggregates across connections
  and the conversation/compose must carry the connectionId so they hit the right workspace
  (same pattern as the spec inbox/detail and tasks).
- Store-and-forward means a thread can sit 'awaiting' indefinitely if no agent runs;
  the UI must make 'waiting for agent' vs 'replied' obvious (the awaiting_reply indicator)
  and not imply real-time.
- "Material3 bottom nav stays at 5 destinations (Specs, Messages, Decisions, Tasks,\
  \ Settings) after the repurpose \u2014 no 6th tab added."
task_slug: ground-control-messages-tab
work_item_id: wi-20260702110439-cb8f38ac
---
## Problem

The message-mailbox substrate (POST/GET /threads, /threads/{id}/messages, GET /threads/{id}) is merged, but the phone has no surface for it — you still can't message an agent from Ground Control. This is slice 2 of the agent-messaging direction: the phone chat UI. It also retires the stopgap form-based Quick Capture (typing a title + repos) — the chat is the richer capture: message a half-formed thought and let an agent shape it. The mailbox is store-and-forward, so the UI is poll-based (no real-time), consistent with the rest of the app.

## User story

As a Mothership operator, I want a Messages tab in Ground Control where I can start a thread with a half-formed idea, send and read messages, and see which threads are waiting on an agent — so that capture and agent conversation happen on my phone instead of a terminal.

## Approach

ground-control only, consuming the merged mailbox endpoints. New DTOs ThreadSummary, Thread, Message; extend the API (on SpecApi or a sibling ThreadsApi) with listThreads (GET /threads), getThread (GET /threads/{id}), createThread (POST /threads {text, subject?}), postMessage (POST /threads/{id}/messages {text}) — reusing the existing bearer auth + mshipDefaults 401/404/409 mapping. A ThreadsRepository fans out listThreads across all configured connections in parallel (like SpecRepository.listAllSpecs) for partial-failure resilience. The Capture bottom-nav tab is REPURPOSED to 'Messages' (label + chat icon + route): Section.CAPTURE becomes the Messages destination, the quick-capture CaptureScreen/CaptureViewModel (and their tests) are removed (the chat supersedes the form; SpecApi.createSpec / NewSpecBody stay as the server contract for the later capture-as-conversation slice). ui/messages/ holds: MessagesScreen + MessagesViewModel (thread list aggregated workspace -> threads, each row subject + last-message preview + an awaiting-reply indicator + updated time; a 'new thread' action; pull-to-refresh; error chip on a failed workspace — mirrors SpecInboxScreen), and ConversationScreen + ConversationViewModel (route thread/{connectionId}/{threadId}; loads getThread; human vs agent message rows; a compose box that POSTs a human message and updates state from the returned Thread; awaiting indicator; pull-to-refresh + back — mirrors SpecDetailScreen). New thread = compose an optional subject + first message -> createThread -> navigate to the new conversation; this is the new capture entry. Reuses the inbox's connectionId nav carry + runBlockingSnapshot connection-resolve. JVM unit tests only; screens build-verified.

## App data + screens

DTOs (data/dto/): ThreadSummary(id, subject, @SerialName updated_at updatedAt: String?, @SerialName awaiting_reply awaitingReply: Boolean = false, @SerialName last_message lastMessage: String = "", @SerialName message_count messageCount: Int = 0); Message(id, @SerialName thread_id threadId, role: String, text, @SerialName created_at createdAt: String?); Thread(id, subject, @SerialName created_at, @SerialName updated_at, @SerialName task_slug taskSlug: String? = null, messages: List<Message> = emptyList(), @SerialName awaiting_reply awaitingReply: Boolean = false); request bodies NewThreadBody(text, subject: String? = null), NewMessageBody(text). API: listThreads/getThread/createThread/postMessage on SpecApi (or a new ThreadsApi) over the same client + auth + mshipDefaults. ThreadsRepository.listAllThreads(connections) mirrors SpecRepository.listAllSpecs. ui/messages/: MessagesScreen + MessagesViewModel (mirror ui/specs SpecInboxScreen/ViewModel; group workspace -> threads; the section carries connectionId; a new-thread affordance), ConversationScreen + ConversationViewModel (mirror ui/specdetail; route thread/{connectionId}/{threadId}; load getThread + post via postMessage, updating from the returned Thread; ErrorKind AUTH/NOT_FOUND/NETWORK). Nav: in GroundControlApp, rename Section.CAPTURE -> MESSAGES (route 'messages', a chat icon), render MessagesScreen with an onThreadClick -> nav.navigate(thread/{conn}/{id}) and an onNewThread; add the thread/{connectionId}/{slug} route resolving the connection via runBlockingSnapshot (same as specDetail). Delete CaptureScreen.kt, CaptureViewModel.kt, CaptureViewModelTest.kt.
