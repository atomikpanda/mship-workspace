---
id: ground-control-home-surfaces-agent
title: Ground Control Home surfaces agent messages that need operator action
status: implemented
created_at: '2026-06-30T17:09:26.002888Z'
updated_at: '2026-06-30T18:52:03.009337Z'
affected_repos:
- mothership
- ground-control
acceptance_criteria:
- id: ac1
  text: A needs_you agent message (`mship reply --needs-you` or POST /messages with
    kind=needs_you) surfaces on GC Home as an action card; a plain note does NOT become
    an action card.
  verdict: approved
- id: ac2
  text: The action card clears when the operator replies (latest message becomes human);
    it does NOT clear merely from opening the thread.
  verdict: approved
- id: ac3
  text: 'A plain unread agent note drives a "new" badge: a dot/count on the Messages
    nav tab and a quiet line on Home below the action cards.'
  verdict: approved
- id: ac4
  text: Opening the thread calls POST /threads/{id}/seen; afterward the note "new"
    badge clears and stays cleared (cursor is server-side + monotonic) -- including
    after the next Home refresh.
  verdict: approved
- id: ac5
  text: Message.kind round-trips through the MessageStore (note default; needs_you
    when set); legacy messages with no kind read back as note.
  verdict: approved
- id: ac6
  text: The seen cursor is monotonic (a stale/older POST /seen cursor never regresses
    it).
  verdict: approved
- id: ac7
  text: needs_you / unseen are computed by a single tested projection function shared
    by the CLI and serve; GET /threads summaries carry both, plus the unchanged awaiting_reply.
  verdict: approved
- id: ac8
  text: 'Ground Control parses needsYou/unseen (defaulting false when the server omits
    them) and tiers Home correctly: needs_you -> action card, unseen-and-not-needs_you
    -> quiet note line.'
  verdict: approved
- id: ac9
  text: mothership tests (the message/serve/CLI suite) and the ground-control JVM
    unit suite are green.
  verdict: approved
open_questions:
- id: q1
  text: 'Cursor type for seen_through / POST /seen body: message-id vs ISO timestamp.
    Timestamp is consistent with the existing high-water cursor used by `inbox wait`
    / `?wait=1`; message-id is unambiguous if two messages share a timestamp. Lean
    timestamp for consistency; confirm during planning.'
  answer: ISO timestamp (consistent with the existing inbox-wait / ?wait=1 high-water
    cursor).
- id: q2
  text: Whether the Messages-tab count should count threads or unread messages. Lean
    threads-with-unread (simpler, matches the Home tiering); confirm during planning.
  answer: Threads-with-unread (count of threads where unseen || needs_you), not total
    unread messages.
non_goals:
- 'Push notifications -- a separate layer (issue #239''s notification work / #246),
  not this spec.'
- Auto-dispatch (spawning an agent on a new message) -- explicitly a later layer.
- Multi-user / per-operator seen -- single-operator model; one seen cursor per thread.
- Changing awaiting_reply semantics -- it stays (agent-owes-reply); we ADD needs_you
  + unseen alongside it.
- Client-side question detection / "?" heuristics -- intent is agent-marked, not guessed.
- Instrumented/emulator UI tests in ground-control -- JVM unit tests only (this repo's
  tier); any pure-visual placement is operator-verified via `mship capture`.
risks:
- 'Two repos with an ordering dependency: ship/merge the mothership substrate (kind
  + seen + derived fields) before the ground-control client consumes it. The GC DTO
  defaults both flags to false so an un-upgraded server degrades gracefully (no cards/badges,
  no crash).'
- 'Operational: `mship serve` is long-running and must be RESTARTED to expose the
  new POST /seen endpoint and the new summary fields (same gotcha as #245''s ?wait=1).'
- needs_you definition must be "unanswered needs_you newer than the last human message,"
  not "latest message is needs_you," so a follow-up note doesn't drop the card.
- Keep the derived-fields projection in one place (shared by CLI + serve) to avoid
  drift.
task_slug: ground-control-home-surfaces-agent
work_item_id: wi-20260702110439-a1625ec1
---
## Problem

Ground Control's Home "Needs you" feed surfaces message threads via HomeFeedRepository -> questionsFrom(conn, threads) -> threads.filter { it.awaitingReply }. But ThreadSummary.awaitingReply is derived (in mothership) as latest message role == human -- i.e. the AGENT owes a reply. So Home surfaces threads where the OPERATOR already spoke, and the moment an agent replies, awaiting_reply flips to false and the thread DROPS OFF Home. The polarity is inverted: an agent message that actually needs the operator (a question, or even a notable status update) never surfaces on Home. The user's goal -- "stuff should surface on Ground Control Home when I need to take action" -- is unmet. Concretely observed while dogfooding: an agent posting `mship reply "hello world"` is invisible on Home.

## User story

As a Ground Control operator, I want agent messages that need my action to surface on Home as action cards (and plain agent notes to show a lighter 'new' badge), so that I see and can act on what needs me instead of having relevant agent messages stay invisible on Home.

## Approach

One cohesive feature spanning two repos, implemented mothership-first because the client can't consume the new fields until the substrate exists.

Two tiers of surfacing: an agent message that needs action (a question / "needs you") becomes a Home action card; a plain agent note becomes a lighter "new" badge (a dot/count on the Messages nav tab AND a quiet line on Home, below the action cards).

The agent marks intent (not a client-side heuristic). Messages carry a kind: note (default) or needs_you. Set agent-side via a CLI flag `mship reply --needs-you` -- an agent-agnostic convention mirroring the existing "Make this a spec" canonical-message pattern. Robust; touches both repos.

Server-side seen cursor. Opening a thread marks it seen in mothership (a per-thread read position). The plain-note "new" badge clears on seen, and the read-state survives reinstall and is consistent across devices.

Clearing semantics: the needs-you action card clears when the operator REPLIES (latest message becomes human -> needs_you false); merely opening/reading the thread does NOT clear it because reading is not acting. The plain-note "new" badge clears when the operator OPENS the thread (the seen cursor advances past the agent message -> unseen false), because the operator may never reply to a note, so it must clear on read, not on reply.

mothership substrate: Message gains a kind field (note | needs_you, default note), persisted in the file-per-thread MessageStore and back-compatible (legacy messages without kind deserialize as note); a per-thread monotonic operator read cursor (seen_through) exposed via POST /threads/{id}/seen; and derived thread-summary projection fields needs_you and unseen computed by a single shared, tested function used by both CLI and serve, exposed on GET /threads and GET /threads/{id} alongside the unchanged awaiting_reply.

ground-control surface: ThreadSummary DTO gains needsYou and unseen (default false when absent); questionsFrom filters threads.filter { it.needsYou } for the action cards; a quiet lower-tier Home line filters threads.filter { it.unseen && !it.needsYou } below the action cards; the Messages bottom-nav tab carries an unread badge; MshipClient/SpecApi gains markThreadSeen(conn, threadId, cursor) -> POST /threads/{id}/seen; and ConversationViewModel calls markThreadSeen on open so unseen flips false on the next Home refresh / via the existing long-poll.

## Architecture

This is one cohesive feature spanning two repos, implemented mothership-first (the client can't consume the new fields until the substrate exists).

mothership (the substrate)

1. Message kind field. Message gains kind: "note" | "needs_you", default note. Persisted in the file-per-thread MessageStore under .mothership/messages/. Back-compat: messages already on disk without a kind deserialize as note.
   - CLI: `mship reply <thread> "<text>" [--needs-you]` -- the flag sets kind="needs_you"; default is note. (The existing inbox/reply/messages behavior is otherwise unchanged.)
   - serve: POST /threads/{id}/messages accepts an optional kind (default note).

2. Per-thread operator read cursor ("seen"). Each thread gains a seen_through marker (the timestamp or message-id the operator has read up to). Single-operator model: one seen cursor per thread (no per-user fan-out).
   - serve: POST /threads/{id}/seen with a body carrying the cursor (latest message id or its timestamp). Idempotent and monotonic -- never moves the cursor backwards.

3. Derived thread-summary fields. So the client doesn't recompute message-walking logic, GET /threads (and GET /threads/{id}) expose, per thread summary, in addition to the existing awaiting_reply:
   - needs_you: bool -- there exists an agent message with kind=needs_you that is newer than the operator's last human message (i.e. an unanswered needs-you). Robust to an agent posting a needs_you followed by a plain note (the card persists until the operator replies).
   - unseen: bool -- the latest agent message is newer than seen_through (a plain unread agent message). Drives the "new" badge.
   These are pure projections over a thread's messages + seen cursor; implement as a single tested function so the CLI and serve agree. Note: the long-poll GET /threads?wait=1 (mothership #245) already returns changed thread summaries -- once these fields are on the summary, Ground Control's existing live-poll picks up needs_you/unseen transitions for free.

ground-control (the surface)

4. DTO. ThreadSummary (in ThreadDtos.kt) gains needsYou: Boolean and unseen: Boolean, parsed from GET /threads. Default false when absent (back-compat with an un-upgraded server).

5. Fix the Home action cards. In NeedsYouItem.kt, questionsFrom filters threads.filter { it.needsYou } (was it.awaitingReply). These are the Home action cards ("agent needs you"). Rename the item/label away from the misleading "Question/awaiting" framing if it reads cleanly.

6. Add the quiet note surface. A lower-tier Home entry for threads.filter { it.unseen && !it.needsYou } -- a soft "new message" line rendered BELOW the needs-you action cards (its own quiet section/variant), urgency-sorted under the cards.

7. Messages-tab unread badge. A dot/count on the Messages bottom-nav tab = count of threads with unseen || needsYou.

8. MshipClient/SpecApi: markThreadSeen(conn, threadId, cursor) -> POST /threads/{id}/seen.

9. Mark-seen on open. ConversationViewModel (or the conversation screen) calls markThreadSeen when the thread is opened/loaded; on success unseen flips false, so the Home "new" line and the Messages-tab dot clear on the next Home refresh / via the existing long-poll.

Clearing semantics (explicit): the needs-you action card clears when the operator replies (latest message becomes human -> needs_you false); merely opening/reading the thread does NOT clear it -- reading is not acting. The plain-note "new" badge clears when the operator opens the thread (the seen cursor advances past the agent message -> unseen false); the operator may never reply to a note, so it must clear on read, not on reply.

## Testing

mothership: exercise the existing message/serve/CLI test suite plus the new behavior. The needs_you / unseen derivation is a single shared projection function (used by both CLI and serve) and is tested directly -- covering: an unanswered needs_you newer than the last human message is needs_you=true; a needs_you followed by a plain note still keeps needs_you=true until a human reply; a human reply flips needs_you=false; unseen=true when the latest agent message is newer than seen_through and false once the cursor advances past it; the seen cursor is monotonic so a stale/older POST /seen never regresses it; Message.kind round-trips through the MessageStore (note default, needs_you when set) and legacy messages with no kind read back as note. GET /threads summaries carry needs_you, unseen, and the unchanged awaiting_reply.

ground-control: JVM unit tests only (this repo's tier). Drive MshipClient/SpecApi against a Ktor MockEngine and fakes -- verify ThreadSummary parses needsYou/unseen (defaulting false when the server omits them), that questionsFrom yields action cards for needsYou threads, that the quiet note surface selects unseen && !needsYou threads below the cards, that the Messages-tab badge counts unseen || needsYou threads, and that markThreadSeen issues POST /threads/{id}/seen and ConversationViewModel calls it on open. No emulator / instrumented UI tests; any pure-visual placement (action cards above the quiet note line, the tab dot/count) is operator-verified via `mship capture`.
