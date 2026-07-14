# Read indicator (agent read cursor) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When an agent consumes a human's inbox message, mark it "Read" and surface a Read indicator in Ground Control, so the operator knows the agent has seen their message (Sent → Read → Replied).

**Architecture:** Add a symmetric AGENT read cursor `Thread.agent_seen_at` (mirroring the operator-side `Thread.seen_at`). Stamp it — never moving backward — when the agent consumes human messages (`mship inbox wait` and `mship _drain` surface `awaiting_reply` threads). Serve auto-exposes it via the `Thread` model dump; Ground Control reads it and renders a Read indicator on human messages it covers.

**Tech Stack:** mothership (Python/Pydantic, pytest); ground-control (Kotlin/Compose, JUnit + Ktor MockEngine).

**Spec:** `read-indicator-agent-read-cursor-in` (approved). Issue #345.

---

<!-- mship:task id=1 -->
### Task 1: Model — `Thread.agent_seen_at` + never-backward stamp helper

**Files:**
- Modify: `mothership/src/mship/core/message.py` (Thread model)
- Modify: `mothership/src/mship/core/message_store.py` (a `mark_agent_seen` writer)
- Test: `mothership/tests/core/test_message.py` (or the message-store test)

- [ ] **Step 1: Failing test** — a `Thread` with `agent_seen_at=None` deserializes fine; `mark_agent_seen(thread, t)` sets it; a second call with an EARLIER time does NOT move it backward; a later time advances it. Also a `read_by_agent(msg)` / comparison helper: a human message is "read" iff `agent_seen_at is not None and agent_seen_at >= msg.created_at` (mirror `unseen`).
- [ ] **Step 2:** Add `agent_seen_at: datetime | None = None` to `Thread` (next to `seen_at`, with a comment: agent read cursor, symmetric to the operator's `seen_at`). Add a `MessageStore.mark_agent_seen(thread_id, up_to)` (under the existing per-thread lock) that loads, advances `agent_seen_at = max(existing, up_to)` (never backward), saves. Backward-compat: a persisted thread without the field loads with `None`.
- [ ] **Step 3:** Run the tests; commit + `mship journal`.
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: Stamp on consume — `mship inbox wait`

**Files:**
- Modify: `mothership/src/mship/cli/message.py` (`inbox_wait`, after `wait_for_change` returns)
- Test: `mothership/tests/cli/test_message*.py`

- [ ] **Step 1: Failing test** — after `inbox wait` returns a thread whose latest message is human (`awaiting_reply`), that thread's persisted `agent_seen_at` is at/after the latest human message's `created_at`. A non-awaiting changed thread (e.g. the agent's own reply) is NOT stamped.
- [ ] **Step 2:** In `inbox_wait`, for each returned thread that is `awaiting_reply`, call `store.mark_agent_seen(thread.id, now)` (now = the wait's resolution time) before emitting the JSON. Best-effort under the existing lock; a stamp failure must not fail the wait.
- [ ] **Step 3:** Run tests; commit + journal.
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: Stamp on consume — `mship _drain` (Stop hook)

**Files:**
- Modify: `mothership/src/mship/cli/internal.py` (`_drain` path, where `awaiting_reply` threads are surfaced — near `_format_drain_reason`'s `replies`)
- Test: `mothership/tests/cli/test_internal*.py` or the drain test

- [ ] **Step 1: Failing test** — when `_drain` surfaces an `awaiting_reply` thread, its persisted `agent_seen_at` is stamped (>= latest human message time). Threads that are only `awaiting_agent_event` (no human reply) are NOT stamped.
- [ ] **Step 2:** In the `_drain` flow, after computing the awaiting-reply threads, `store.mark_agent_seen(t.id, now)` for each (best-effort). Do this whether or not the hook blocks — the point is the agent has now SEEN them.
- [ ] **Step 3:** Run tests; commit + journal.
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: Serve exposes `agent_seen_at`

**Files:**
- Verify/Modify: `mothership/src/mship/core/serve.py` (thread list + detail endpoints)
- Test: `mothership/tests/core/test_serve*.py`

- [ ] **Step 1: Failing test** — `GET` the thread list + a thread detail; the JSON includes `agent_seen_at` (null when unset, the ISO timestamp when stamped).
- [ ] **Step 2:** The endpoints already dump the `Thread` model, so the field should serialize automatically once Task 1 adds it — confirm and, if a hand-built DTO is used instead, add the field there.
- [ ] **Step 3:** Run tests; commit + journal.
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: GC — `agent_seen_at` on the thread DTOs

**Files:**
- Modify: `ground-control/android/app/src/main/java/com/atomikpanda/groundcontrol/data/dto/ThreadDtos.kt` (`Thread`, `ThreadSummary`)
- Test: `ground-control/android/app/src/test/java/com/atomikpanda/groundcontrol/*ThreadDto*Test.kt`

- [ ] **Step 1: Failing test** — a thread JSON with `agent_seen_at` deserializes into the DTO's `agentSeenAt`; a JSON without it defaults to null (backward-compat).
- [ ] **Step 2:** Add `@SerialName("agent_seen_at") val agentSeenAt: String? = null` to `Thread` (and `ThreadSummary` if the chat surface uses it), next to `awaitingReply`/`seenAt`.
- [ ] **Step 3:** Run tests; commit + journal.
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: GC — Read indicator on human messages (Sent → Read → Replied)

**Files:**
- Modify: the messages/chat screen (`ui/messages/…`) that renders a `Message`
- Test: a small pure helper `messageReadState(message, thread)` in `ui/messages/…` + its unit test

- [ ] **Step 1: Failing test** — a pure helper `messageReadState(msg, thread)` returns: for a human message, `READ` iff `thread.agentSeenAt != null && agentSeenAt >= msg.createdAt` (ISO string compare is fine, all UTC); else `SENT`; and if a later agent message exists after it, `REPLIED`. Non-human messages → none.
- [ ] **Step 2:** Add the helper; render a small "Read" / "Sent" label (and keep the existing awaiting/replied affordance) under/next to the operator's own (human) messages. Reuse existing typography (labelSmall, onSurfaceVariant).
- [ ] **Step 3:** `compileDebugKotlin` + `testDebugUnitTest` + `assembleDebug`; commit + journal.
<!-- /mship:task -->

---

## Self-Review

- **Spec coverage:** ac1 (Task 1), ac2 (Tasks 2–3), ac3 (Task 4), ac4 (Tasks 5–6), ac5 (Task 6 Sent→Read→Replied), ac6 (Task 1 null default + never-backward + Task 6 `>=` comparison). Covered.
- **Types:** `agent_seen_at` (serve) ↔ `agentSeenAt` (GC), `mark_agent_seen(thread_id, up_to)` used identically in Tasks 2 + 3.
- **No placeholders.** Each task has concrete files + the exact field/helper.
