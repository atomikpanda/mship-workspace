---
id: ground-control-conversation
title: 'Ground Control conversation: live reply + reply-box ergonomics (draft safety,
  keyboard scroll)'
status: implemented
created_at: '2026-06-30T14:20:09.325126Z'
updated_at: '2026-06-30T16:42:54.925121Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: "The compose draft survives a `state \u2192 Loading \u2192 Content` reload\
    \ and recomposition: with text typed, a reload (e.g. the poll refreshing the thread)\
    \ leaves the text intact in the box. Verified by a ConversationViewModel unit\
    \ test (draft persists across state changes) and ComposeBar reading the VM draft."
  verdict: approved
- id: ac2
  text: A successful send clears the draft; a failed send leaves the draft intact
    (no separate buffer); `inFlight`/`sendError` behavior is unchanged. Unit-tested.
  verdict: approved
- id: ac3
  text: "`MshipClient.listThreadsWait(conn, since, timeout)` issues `GET /threads?wait=1&since=\u2026\
    &timeout=\u2026` with a per-request timeout greater than the server timeout and\
    \ parses `{threads, cursor, timed_out}`. Unit-tested with a Ktor MockEngine (asserts\
    \ the query params + the raised timeout)."
  verdict: approved
- id: ac4
  text: While a thread is open, `ConversationViewModel` long-polls and refreshes the
    conversation when THAT thread changes (an agent reply appears with no manual refresh),
    advancing the cursor each round and re-looping on timeout; the loop is cancelled
    when the VM is cleared. Unit-tested with a fake repo and the injected test scope.
  verdict: approved
- id: ac5
  text: A network error during the poll neither crashes nor clears the open conversation;
    the loop retries. Unit-tested.
  verdict: approved
- id: ac6
  text: When the reply box gains focus and the keyboard opens, the message list scrolls
    to the latest message. Verified via `mship capture` of the running app (no emulator
    test in this repo).
  verdict: approved
- id: ac7
  text: The full ground-control JVM unit suite is green.
  verdict: approved
open_questions:
- id: q1
  text: 'Poll timeout values: the server caps the wait at 30s; the client should use
    ~25s server-wait with a Ktor request timeout of ~35s. Confirm these sit comfortably
    under the relay/Caddy idle-read timeout when GC connects over the relay (ties
    to mothership slice-2 q1).'
  answer: 'yes'
non_goals:
- "Voice dictation and quick-reply chips \u2014 separate follow-up specs (the higher-leverage\
  \ ergonomic wins, but out of this scope)."
- "Any server change \u2014 `GET /threads?wait=1` already merged (mothership #245);\
  \ this is client-side only."
- "Adding `?wait=1` to the single-thread `GET /threads/{id}` endpoint \u2014 the loop\
  \ long-polls the list endpoint, then re-fetches the open thread."
- "Lifecycle-aware poll throttling / pausing the poll when the app is backgrounded\
  \ \u2014 a later optimization; v1 polls while the conversation VM is alive."
- Read receipts, typing indicators, push notifications.
- "Instrumented / emulator UI tests \u2014 this repo runs JVM unit tests only; the\
  \ keyboard-scroll fix is verified via `mship capture`."
risks:
- "Ktor's default per-request timeout would abort the long-poll mid-wait \u2014 the\
  \ `listThreadsWait` call MUST set a request timeout greater than the server wait\
  \ (e.g. server 25s + ~10s headroom)."
- "Continuous polling while a conversation is open uses battery/network \u2014 acceptable\
  \ for v1 (only while viewing a thread); lifecycle pause is a follow-up."
- 'Cursor seeding: seed from the loaded thread''s `updatedAt`; a wrong seed could
  miss the first reply or busy-refetch. Server uses strict `>` on the high-water cursor,
  so seeding at the current latest is correct.'
- "The wait response is an OBJECT (`{threads, cursor, timed_out}`), unlike plain `GET\
  \ /threads` (a list) \u2014 use a separate DTO and do not change the existing `listThreads()`."
- "Moving the draft into the VM must not regress the existing send/inFlight/sendError\
  \ behavior (optimistic clear \u2192 restore-on-failure becomes keep-until-success)."
task_slug: ground-control-conversation
work_item_id: wi-20260702110439-666a1460
---
## Problem

The Ground Control Messages conversation screen has three issues that make replying to a host agent from the phone painful: (1) the agent's reply is not live — the conversation only fetches on open and pull-to-refresh, so a reply isn't seen until a manual refresh; (2) the compose draft lives in a Composable `remember { mutableStateOf("") }`, so it is lost when the screen recomposes or reloads (losing focus, or a refresh flipping state to Loading) — you lose the whole message; (3) when the reply box is focused the keyboard pushes the messages off-screen, because the auto-scroll only fires on a message-count change, not when the keyboard opens. The store-and-forward mailbox model itself is sound for mship's async/steering use (and the human side should stay short); these are conversation-screen ergonomics plus consuming the serve long-poll that just merged in mothership #245 (`GET /threads?wait=1`).

## User story

As a Mothership operator replying to a host agent from Ground Control, I want the conversation to show the agent's reply live, never lose my in-progress draft, and stay scrolled to the latest message when the keyboard is open, so steering from my phone is reliable and feels conversational.

## Approach

Client-side only (ground-control); the server `GET /threads?wait=1&since=&timeout=` already exists (mothership #245). Three components, all in the messages UI/VM/data layers:

1. **Draft → ViewModel (fix first; prerequisite for live-poll).** Move the compose text out of `ComposeBar`'s `remember { mutableStateOf("") }` into `ConversationViewModel` as a `draft: StateFlow<String>` with `onDraftChange(text)` / `clearDraft()`. The VM-owned draft subsumes the current restore-on-failure `pending` buffer: `send(text)` keeps the draft until it SUCCEEDS (then `clearDraft()`), and leaves it on failure — so a failed send never loses text and a poll/refresh state flip can't either. `ComposeBar` becomes stateless: it reads `vm.draft`, calls `vm.onDraftChange`, and sends via `vm.send(...)`. Survives recomposition, `state → Loading → Content` reloads, and rotation.

2. **Live reply (long-poll).** Add `MshipClient.listThreadsWait(conn, since, timeoutSeconds)` → `GET /threads?wait=1&since=…&timeout=…` with a PER-REQUEST timeout greater than the server wait (so Ktor doesn't abort mid-wait), plus a `ThreadsWaitResponse(threads, cursor, timedOut)` DTO; wrap it in `ThreadsRepository.waitForChange(conn, since, timeout)`. `ConversationViewModel` starts a poll loop in `scope()` after a successful load: seed the cursor from the loaded thread's `updatedAt`; loop { resp = repo.waitForChange(cursor, 25); if resp.threads contains this thread's id → `repo.getThread(...)` and emit updated Content (preserving inFlight/draft); cursor = resp.cursor }; a network error backs off briefly and retries (never crashes/clears the open conversation); the loop is bound to `scope()` so it cancels on `onCleared`. The injectable `testScope` already on the VM makes the loop unit-testable.

3. **Keyboard-aware scroll.** In `ConversationContentView`, add a `LaunchedEffect` keyed on IME visibility (derive from `WindowInsets.ime`) that `animateScrollToItem(last)` when the keyboard opens, complementing the existing message-count scroll; verify `imePadding`/Scaffold insets are applied exactly once.

## Architecture

Changes are confined to three ground-control layers: `ui/messages/ConversationViewModel.kt` (a `draft` StateFlow + `onDraftChange`/`clearDraft`; a `viewModelScope`/`testScope` poll loop; cursor state), `ui/messages/ConversationScreen.kt` (`ComposeBar` becomes stateless and reads `vm.draft`; an IME-visibility `LaunchedEffect` scroll), and the data layer (`data/MshipClient.kt` `listThreadsWait` + a `ThreadsWaitResponse` DTO; `data/ThreadsRepository.kt` `waitForChange`). The VM's existing `testScope` injection and the repo seam keep the poll loop and draft logic unit-testable without an emulator. The conversation re-fetches the full thread via the existing `getThread` once the long-poll signals a change, rather than diffing summaries — simplest and consistent with the current load path.

## Testing

JVM unit tests (this repo's only test tier): ConversationViewModel — draft persists across a load()/state transition; send clears on success, keeps on failure; the poll loop refreshes when the open thread is in the wait response's `threads`, advances the cursor, re-loops on timeout, and stops when the scope is cancelled; a thrown network error is swallowed and retried. MshipClient — a Ktor `MockEngine` asserts `listThreadsWait` hits `/threads?wait=1&since=…&timeout=…`, sends the raised request timeout, and parses the `{threads, cursor, timed_out}` body. The keyboard-aware scroll is UI behavior with no emulator test available, so it is verified by `mship capture --platform android` against the running app (screenshot with the reply box focused showing the latest message visible).
