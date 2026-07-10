# Ground Control Home Surfaces Agent Messages — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `ground-control-home-surfaces-agent` (`specs/2026-06-30-ground-control-home-surfaces-agent.md`, status `dispatched`)

**Goal:** Surface agent messages that need the operator on Ground Control's Home — a `needs_you` agent message becomes a Home action card, a plain unread agent note becomes a quiet "new" line — fixing the inverted `awaitingReply` polarity.

**Architecture:** Two repos, **mothership first** (the client can't consume new fields until the substrate exists). mothership: a `kind` field on messages (`note`|`needs_you`), a per-thread monotonic `seen_at` cursor with `POST /threads/{id}/seen`, and `needs_you`/`unseen` as `@computed_field`s on `Thread` (mirroring the existing `awaiting_reply`) exposed on the thread summaries. ground-control: parse the two new flags, flip the Home action-card filter to `needsYou`, add a quiet "new message" Home line for `unseen && !needsYou`, and mark a thread seen when its conversation opens.

**Tech Stack:** mothership — Python, Pydantic v2, FastAPI, Typer, pytest (`uv run pytest -q`). ground-control — Kotlin/Compose, Ktor 2.3.12, kotlinx-serialization, JUnit4 + kotlinx-coroutines-test + Ktor MockEngine, JVM unit tests only (`./gradlew testDebugUnitTest --rerun-tasks`).

**Worktrees:**
- mothership: `.worktrees/ground-control-home-surfaces-agent/mothership`
- ground-control: `.worktrees/ground-control-home-surfaces-agent/ground-control`

**Clearing semantics (the invariant the whole feature rests on):**
- A **needs-you action card** clears when the operator **replies** (latest message becomes human → `needs_you` false). Opening/reading does NOT clear it.
- A **plain-note "new" badge** clears when the operator **opens** the thread (the `seen_at` cursor advances past the agent message → `unseen` false).

**Tab note (Task 9):** Adding the Messages nav tab + its unread badge (the "dot on the Messages tab" half of the design) is gated on an operator decision (include now vs. fast-follow) and is documented as a deferred follow-up at the end. Tasks 1–8 deliver the Home action cards + quiet note line + seen-clearing, which is the core of the feature and ships independently.

---

<!-- mship:task id=1 -->
### Task 1: mothership — `Message.kind` + `Thread.seen_at` + derived `needs_you`/`unseen`

Add the data-model surface: a `kind` discriminator on `Message`, a `seen_at` operator-read cursor on `Thread`, and the two derived projection fields `needs_you`/`unseen` as `@computed_field`s (the same pattern the existing `awaiting_reply` uses, so they serialize into `model_dump()`/JSON and are computed in exactly one place — satisfying the spec's "single shared projection function").

**Work from:** `.worktrees/ground-control-home-surfaces-agent/mothership`

**Files:**
- Modify: `src/mship/core/message.py`
- Test: `tests/core/test_message_model.py` (create)

- [ ] **Step 1: Write the failing tests**

Create `tests/core/test_message_model.py`:

```python
from datetime import datetime, timedelta, timezone

from mship.core.message import Message, Thread

BASE = datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc)


def _thread(*msgs: Message, seen_at: datetime | None = None) -> Thread:
    return Thread(
        id="x", subject="s", created_at=BASE, updated_at=BASE,
        messages=list(msgs), seen_at=seen_at,
    )


def _m(role: str, minute: int, *, kind: str = "note") -> Message:
    return Message(
        id=f"m{minute}", thread_id="x", role=role, text=f"msg {minute}",
        created_at=BASE + timedelta(minutes=minute), kind=kind,
    )


def test_message_kind_defaults_to_note():
    assert _m("agent", 1).kind == "note"


def test_kind_round_trips_and_legacy_json_defaults_to_note():
    # explicit needs_you survives a JSON round-trip
    m = _m("agent", 1, kind="needs_you")
    assert Message.model_validate_json(m.model_dump_json()).kind == "needs_you"
    # legacy on-disk JSON with no `kind` deserializes as note
    legacy = '{"id":"m1","thread_id":"x","role":"agent","text":"hi","created_at":"2026-06-30T12:01:00+00:00"}'
    assert Message.model_validate_json(legacy).kind == "note"


def test_needs_you_true_for_unanswered_needs_you():
    t = _thread(_m("human", 0), _m("agent", 1, kind="needs_you"))
    assert t.needs_you is True


def test_needs_you_false_for_plain_note():
    t = _thread(_m("human", 0), _m("agent", 1))
    assert t.needs_you is False


def test_needs_you_persists_after_a_followup_note():
    # a needs_you followed by a plain note (no human reply) still needs you
    t = _thread(_m("human", 0), _m("agent", 1, kind="needs_you"), _m("agent", 2))
    assert t.needs_you is True


def test_needs_you_clears_after_human_reply():
    t = _thread(_m("human", 0), _m("agent", 1, kind="needs_you"), _m("human", 2))
    assert t.needs_you is False


def test_unseen_true_when_agent_newer_than_seen_cursor():
    t = _thread(_m("human", 0), _m("agent", 1), seen_at=None)
    assert t.unseen is True


def test_unseen_false_once_seen_cursor_advances_past_latest_agent():
    t = _thread(_m("human", 0), _m("agent", 1), seen_at=BASE + timedelta(minutes=2))
    assert t.unseen is False


def test_unseen_false_when_no_agent_messages():
    t = _thread(_m("human", 0))
    assert t.unseen is False


def test_needs_you_and_unseen_are_serialized():
    t = _thread(_m("human", 0), _m("agent", 1, kind="needs_you"))
    dumped = t.model_dump()
    assert dumped["needs_you"] is True
    assert dumped["unseen"] is True
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest -q tests/core/test_message_model.py`
Expected: FAIL — `Message` has no `kind`, `Thread` has no `seen_at`/`needs_you`/`unseen` (TypeError / AttributeError / KeyError).

- [ ] **Step 3: Implement the model changes**

In `src/mship/core/message.py`, add `kind` to `Message`, and `seen_at` + the two computed fields to `Thread`. Final state of the file:

```python
from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, computed_field


class Message(BaseModel):
    id: str
    thread_id: str
    role: Literal["human", "agent"]
    text: str
    created_at: datetime
    # "needs_you" marks an agent message that needs the operator to act
    # (surfaces as a Home action card in Ground Control). Default "note".
    kind: Literal["note", "needs_you"] = "note"


class Thread(BaseModel):
    id: str
    subject: str
    created_at: datetime
    updated_at: datetime
    task_slug: str | None = None
    spec_id: str | None = None
    # Operator read cursor: the operator has seen messages up to this time.
    seen_at: datetime | None = None
    messages: list[Message] = []

    @computed_field  # serialized into model_dump()/JSON (a plain @property is not)
    @property
    def awaiting_reply(self) -> bool:
        """A thread needs an agent iff its latest message is from a human."""
        return bool(self.messages) and self.messages[-1].role == "human"

    @computed_field
    @property
    def needs_you(self) -> bool:
        """True iff an agent message marked needs_you is unanswered — i.e. newer
        than the operator's last human message. Survives a follow-up plain note."""
        last_human = -1
        for i, m in enumerate(self.messages):
            if m.role == "human":
                last_human = i
        return any(
            m.role == "agent" and m.kind == "needs_you"
            for m in self.messages[last_human + 1:]
        )

    @computed_field
    @property
    def unseen(self) -> bool:
        """True iff the latest agent message is newer than the operator's seen cursor."""
        latest_agent = None
        for m in self.messages:
            if m.role == "agent":
                latest_agent = m
        if latest_agent is None:
            return False
        return self.seen_at is None or latest_agent.created_at > self.seen_at
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `uv run pytest -q tests/core/test_message_model.py`
Expected: PASS (10 passed).

- [ ] **Step 5: Commit + journal**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/ground-control-home-surfaces-agent/mothership
git add src/mship/core/message.py tests/core/test_message_model.py
git commit -m "feat(messages): add Message.kind + Thread.seen_at/needs_you/unseen"
mship journal "model: Message.kind, Thread.seen_at, computed needs_you/unseen; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: mothership — `MessageStore.append(kind=…)` + `mark_seen` (monotonic)

Thread the new `kind` through `append`, and add a `mark_seen` method that advances the per-thread cursor monotonically (mirrors the existing `link_spec` get→mutate→save pattern).

**Work from:** `.worktrees/ground-control-home-surfaces-agent/mothership`

**Files:**
- Modify: `src/mship/core/message_store.py`
- Test: `tests/core/test_message_store.py`

- [ ] **Step 1: Write the failing tests**

Append to `tests/core/test_message_store.py` (the file already imports `MessageStore`, `datetime`, `timezone` and has a `_store(tmp_path)` helper returning `MessageStore(tmp_path / ".mothership" / "messages")`; add `timedelta` to the datetime import if not present):

```python
def test_append_defaults_to_note_kind(tmp_path):
    now = datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc)
    s = _store(tmp_path)
    t = s.create_thread(subject="x", text="q", now=now)
    s.append(t.id, "agent", "fyi", now)
    got = s.get(t.id)
    assert got.messages[-1].kind == "note"
    assert got.needs_you is False


def test_append_needs_you_kind_flags_thread(tmp_path):
    now = datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc)
    s = _store(tmp_path)
    t = s.create_thread(subject="x", text="q", now=now)
    s.append(t.id, "agent", "look at this", now, kind="needs_you")
    got = s.get(t.id)
    assert got.messages[-1].kind == "needs_you"
    assert got.needs_you is True


def test_mark_seen_advances_cursor_and_clears_unseen(tmp_path):
    from datetime import timedelta
    base = datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc)
    s = _store(tmp_path)
    t = s.create_thread(subject="x", text="hi", now=base)
    s.append(t.id, "agent", "fyi", base + timedelta(minutes=1))
    assert s.get(t.id).unseen is True
    s.mark_seen(t.id, base + timedelta(minutes=2))
    assert s.get(t.id).unseen is False
    assert s.get(t.id).seen_at == base + timedelta(minutes=2)


def test_mark_seen_is_monotonic(tmp_path):
    from datetime import timedelta
    base = datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc)
    s = _store(tmp_path)
    t = s.create_thread(subject="x", text="hi", now=base)
    s.mark_seen(t.id, base + timedelta(minutes=5))
    s.mark_seen(t.id, base + timedelta(minutes=1))  # older — must not regress
    assert s.get(t.id).seen_at == base + timedelta(minutes=5)


def test_mark_seen_unknown_thread_raises(tmp_path):
    s = _store(tmp_path)
    with pytest.raises(KeyError):
        s.mark_seen("nope", datetime(2026, 6, 30, tzinfo=timezone.utc))
```

If `pytest` is not already imported at the top of the file, add `import pytest`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest -q tests/core/test_message_store.py -k "kind or mark_seen"`
Expected: FAIL — `append()` has no `kind` parameter; `mark_seen` does not exist.

- [ ] **Step 3: Implement**

In `src/mship/core/message_store.py`, change `append` to accept `kind` and add `mark_seen`:

```python
    def append(self, thread_id: str, role: Literal["human", "agent"], text: str,
               now: datetime, kind: Literal["note", "needs_you"] = "note") -> Message:
        thread = self.get(thread_id)
        if thread is None:
            raise KeyError(thread_id)
        msg = Message(id=_new_id(now), thread_id=thread_id, role=role, text=text,
                      created_at=now, kind=kind)
        thread.messages.append(msg)
        thread.updated_at = now
        self.save(thread)
        return msg

    def mark_seen(self, thread_id: str, seen_at: datetime) -> Thread:
        """Advance the operator's read cursor (monotonic — never regresses).
        Does not bump updated_at: reading is not a content change and must not
        reorder the thread list."""
        thread = self.get(thread_id)
        if thread is None:
            raise KeyError(thread_id)
        if thread.seen_at is None or seen_at > thread.seen_at:
            thread.seen_at = seen_at
            self.save(thread)
        return thread
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `uv run pytest -q tests/core/test_message_store.py`
Expected: PASS (existing tests + 5 new).

- [ ] **Step 5: Commit + journal**

```bash
git add src/mship/core/message_store.py tests/core/test_message_store.py
git commit -m "feat(messages): MessageStore.append kind + monotonic mark_seen"
mship journal "store: append(kind=), mark_seen monotonic; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: mothership — serve `POST /threads/{id}/seen` + `needs_you`/`unseen` on summaries

Add the seen endpoint and expose the two derived flags on every thread summary (the `_summaries` helper feeds both plain `GET /threads` and the `?wait=1` long-poll, so both get the fields). The `GET /threads/{id}` full-thread response already includes `needs_you`/`unseen` automatically via `model_dump` (Task 1's computed fields) — no change needed there.

**Work from:** `.worktrees/ground-control-home-surfaces-agent/mothership`

**Files:**
- Modify: `src/mship/core/serve.py`
- Test: `tests/core/test_serve.py`

- [ ] **Step 1: Write the failing tests**

Append to `tests/core/test_serve.py` (it has a `_app(tmp_path)` helper and uses `from fastapi.testclient import TestClient`):

```python
def test_thread_summaries_expose_needs_you_and_unseen(tmp_path):
    from mship.core.message_store import MessageStore
    from datetime import datetime, timezone, timedelta
    store = MessageStore(tmp_path / ".mothership" / "messages")
    base = datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc)
    t = store.create_thread("s", "hi", base)
    store.append(t.id, "agent", "need you", base + timedelta(minutes=1), kind="needs_you")

    client = TestClient(_app(tmp_path))
    summary = next(x for x in client.get("/threads").json() if x["id"] == t.id)
    assert summary["needs_you"] is True
    assert summary["unseen"] is True
    assert summary["awaiting_reply"] is False


def test_post_seen_marks_thread_and_clears_unseen(tmp_path):
    from mship.core.message_store import MessageStore
    from datetime import datetime, timezone, timedelta
    store = MessageStore(tmp_path / ".mothership" / "messages")
    base = datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc)
    t = store.create_thread("s", "hi", base)
    store.append(t.id, "agent", "fyi", base + timedelta(minutes=1))

    client = TestClient(_app(tmp_path))
    assert next(x for x in client.get("/threads").json() if x["id"] == t.id)["unseen"] is True
    r = client.post(f"/threads/{t.id}/seen", json={"seen_at": (base + timedelta(minutes=2)).isoformat()})
    assert r.status_code == 200
    assert next(x for x in client.get("/threads").json() if x["id"] == t.id)["unseen"] is False


def test_post_seen_unknown_thread_404(tmp_path):
    client = TestClient(_app(tmp_path))
    r = client.post("/threads/nope/seen", json={"seen_at": "2026-06-30T12:00:00+00:00"})
    assert r.status_code == 404


def test_post_seen_defaults_to_now_when_omitted(tmp_path):
    from mship.core.message_store import MessageStore
    from datetime import datetime, timezone, timedelta
    store = MessageStore(tmp_path / ".mothership" / "messages")
    base = datetime(2026, 6, 30, 12, 0, tzinfo=timezone.utc)
    t = store.create_thread("s", "hi", base)
    store.append(t.id, "agent", "fyi", base + timedelta(minutes=1))
    client = TestClient(_app(tmp_path))
    r = client.post(f"/threads/{t.id}/seen", json={})
    assert r.status_code == 200
    # default seen_at = server now() (well after the message) → unseen clears
    assert next(x for x in client.get("/threads").json() if x["id"] == t.id)["unseen"] is False
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest -q tests/core/test_serve.py -k "needs_you or seen"`
Expected: FAIL — summaries lack `needs_you`/`unseen`; `POST /threads/{id}/seen` returns 404/405 (route missing).

- [ ] **Step 3: Implement**

In `src/mship/core/serve.py`:

(a) Ensure `Literal` is importable for the body model — at the top of the file confirm `from typing import Literal` (add it if missing; `Optional` is already imported there).

(b) Add a `SeenBody` model next to `NewMessageBody`:

```python
class SeenBody(BaseModel):
    seen_at: str | None = None
```

(c) Add `needs_you`/`unseen` to the `_summaries` helper:

```python
    def _summaries(threads):
        return [
            {
                "id": t.id, "subject": t.subject,
                "updated_at": t.updated_at.isoformat(),
                "awaiting_reply": t.awaiting_reply,
                "needs_you": t.needs_you,
                "unseen": t.unseen,
                "last_message": (t.messages[-1].text[:120] if t.messages else ""),
                "message_count": len(t.messages),
            }
            for t in threads
        ]
```

(d) Add the seen endpoint (place it next to `post_message`, before `_summaries`):

```python
    @app.post("/threads/{thread_id}/seen")
    def post_seen(thread_id: str, body: SeenBody):
        if body.seen_at:
            try:
                seen_dt = datetime.fromisoformat(body.seen_at)
            except ValueError:
                raise HTTPException(status_code=422, detail=f"invalid seen_at: {body.seen_at!r}")
            if seen_dt.tzinfo is None:
                seen_dt = seen_dt.replace(tzinfo=timezone.utc)
        else:
            seen_dt = datetime.now(timezone.utc)
        try:
            t = msgs.mark_seen(thread_id, seen_dt)
        except KeyError:
            raise HTTPException(status_code=404, detail=f"no thread {thread_id!r}")
        return t.model_dump(mode="json")
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `uv run pytest -q tests/core/test_serve.py`
Expected: PASS (existing serve tests + 4 new).

- [ ] **Step 5: Commit + journal**

```bash
git add src/mship/core/serve.py tests/core/test_serve.py
git commit -m "feat(serve): POST /threads/{id}/seen + needs_you/unseen on summaries"
mship journal "serve: seen endpoint + summary fields; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: mothership — `mship reply --needs-you`

Add the agent-facing flag that marks a reply as needing the operator. This is the only way `needs_you` is set (the phone/serve side posts human notes, which are never `needs_you`).

**Work from:** `.worktrees/ground-control-home-surfaces-agent/mothership`

**Files:**
- Modify: `src/mship/cli/message.py`
- Test: `tests/cli/test_message.py`

- [ ] **Step 1: Write the failing tests**

Append to `tests/cli/test_message.py` (it has `runner = CliRunner()`, `from mship.cli import app`, the `_configured` fixture, and `_seed(workspace)` returning a `MessageStore`):

```python
def test_reply_needs_you_marks_kind(_configured):
    s = _seed(_configured)
    now = datetime(2026, 6, 23, tzinfo=timezone.utc)
    t = s.create_thread(subject="x", text="q", now=now)
    r = runner.invoke(app, ["reply", t.id, "look at this", "--needs-you"])
    assert r.exit_code == 0, r.output
    got = s.get(t.id)
    assert got.messages[-1].kind == "needs_you"
    assert got.needs_you is True


def test_reply_defaults_to_note(_configured):
    s = _seed(_configured)
    now = datetime(2026, 6, 23, tzinfo=timezone.utc)
    t = s.create_thread(subject="x", text="q", now=now)
    r = runner.invoke(app, ["reply", t.id, "just an fyi"])
    assert r.exit_code == 0, r.output
    got = s.get(t.id)
    assert got.messages[-1].kind == "note"
    assert got.needs_you is False
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest -q tests/cli/test_message.py -k needs_you`
Expected: FAIL — `--needs-you` is an unknown option (non-zero exit), so `kind` stays `note`.

- [ ] **Step 3: Implement**

In `src/mship/cli/message.py`, add the `--needs-you` option to `reply`:

```python
    @parent.command()
    def reply(
        thread_id: str,
        text: str,
        needs_you: bool = typer.Option(
            False, "--needs-you",
            help="Mark this reply as needing the operator's action "
                 "(surfaces as a Home action card in Ground Control).",
        ),
    ) -> None:
        """Post an agent reply to a thread."""
        store = _store()
        try:
            store.append(thread_id, "agent", text, datetime.now(timezone.utc),
                         kind="needs_you" if needs_you else "note")
        except KeyError:
            typer.echo(f"no thread {thread_id!r}", err=True)
            raise typer.Exit(1)
        typer.echo(f"replied to {thread_id}")
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `uv run pytest -q tests/cli/test_message.py`
Expected: PASS.

- [ ] **Step 5: Full mothership suite, then commit + journal**

```bash
uv run pytest -q       # whole suite green (no regressions in inbox/reply/messages/serve/wait)
git add src/mship/cli/message.py tests/cli/test_message.py
git commit -m "feat(cli): mship reply --needs-you marks an agent message needs_you"
mship journal "cli: reply --needs-you; full suite green" --action committed --test-state pass
```
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: ground-control — parse `needsYou`/`unseen` on `ThreadSummary`

**Work from:** `.worktrees/ground-control-home-surfaces-agent/ground-control` (source root `android/app/src/main/java/com/atomikpanda/groundcontrol/`, test root `android/app/src/test/java/com/atomikpanda/groundcontrol/`, package `com.atomikpanda.groundcontrol`).

> Source the Android toolchain first: `source ~/toolchains/android-env.sh`. Run tests from `android/`.

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/dto/ThreadDtos.kt`
- Test: `android/app/src/test/java/com/atomikpanda/groundcontrol/ThreadDtosTest.kt`

- [ ] **Step 1: Write the failing test**

Add to `ThreadDtosTest.kt` (it already constructs a `Json { ignoreUnknownKeys = true }` / `buildJson()` and decodes `ThreadSummary`; match the existing style):

```kotlin
@Test fun parses_needs_you_and_unseen() {
    val json = """{"id":"t1","subject":"s","needs_you":true,"unseen":true}"""
    val s = buildJson().decodeFromString<ThreadSummary>(json)
    assertTrue(s.needsYou)
    assertTrue(s.unseen)
}

@Test fun needs_you_and_unseen_default_false_when_omitted() {
    val s = buildJson().decodeFromString<ThreadSummary>("""{"id":"t1","subject":"s"}""")
    assertFalse(s.needsYou)
    assertFalse(s.unseen)
}
```

If `buildJson` / `assertTrue` / `assertFalse` aren't already imported in the file, add `import com.atomikpanda.groundcontrol.data.buildJson`, `import org.junit.Assert.assertTrue`, `import org.junit.Assert.assertFalse`.

- [ ] **Step 2: Run the test to verify it fails**

Run (from `android/`): `./gradlew testDebugUnitTest --rerun-tasks --tests "com.atomikpanda.groundcontrol.ThreadDtosTest"`
Expected: FAIL — `ThreadSummary` has no `needsYou`/`unseen` (compile error).

- [ ] **Step 3: Implement**

In `ThreadDtos.kt`, add the two fields to `ThreadSummary`:

```kotlin
@Serializable
data class ThreadSummary(
    val id: String,
    val subject: String = "",
    @SerialName("updated_at") val updatedAt: String? = null,
    @SerialName("awaiting_reply") val awaitingReply: Boolean = false,
    @SerialName("needs_you") val needsYou: Boolean = false,
    @SerialName("unseen") val unseen: Boolean = false,
    @SerialName("last_message") val lastMessage: String = "",
    @SerialName("message_count") val messageCount: Int = 0,
)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./gradlew testDebugUnitTest --rerun-tasks --tests "com.atomikpanda.groundcontrol.ThreadDtosTest"`
Expected: PASS.

- [ ] **Step 5: Commit + journal**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/ground-control-home-surfaces-agent/ground-control
git add android/app/src/main/java/com/atomikpanda/groundcontrol/data/dto/ThreadDtos.kt android/app/src/test/java/com/atomikpanda/groundcontrol/ThreadDtosTest.kt
git commit -m "feat(gc): parse needs_you/unseen on ThreadSummary"
mship journal "gc dto: needsYou/unseen parsing; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: ground-control — flip the Home action-card filter to `needsYou`

The single-line polarity fix: the Home "Needs you" queue must surface threads where the agent needs the operator (`needsYou`), not threads where the human spoke last (`awaitingReply`).

**Work from:** `.worktrees/ground-control-home-surfaces-agent/ground-control`

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/home/NeedsYouItem.kt`
- Test: `android/app/src/test/java/com/atomikpanda/groundcontrol/NeedsYouItemTest.kt`

- [ ] **Step 1: Update the failing test**

In `NeedsYouItemTest.kt`, replace the existing `questions_only_include_threads_awaiting_reply` test with one keyed on `needsYou`:

```kotlin
@Test fun questions_only_include_threads_that_need_you() {
    val conn = WorkspaceConnection("c1", "http://h", "tok", "ws")
    val threads = listOf(
        ThreadSummary(id = "t1", subject = "needs you", needsYou = true),
        ThreadSummary(id = "t2", subject = "awaiting agent", awaitingReply = true),  // not surfaced
        ThreadSummary(id = "t3", subject = "plain unread", unseen = true),            // not an action card
    )
    val items = questionsFrom(conn, threads)
    assertEquals(1, items.size)
    assertEquals("t1", (items[0] as NeedsYouItem.Question).threadId)
}
```

Ensure imports include `com.atomikpanda.groundcontrol.data.dto.ThreadSummary` and `com.atomikpanda.groundcontrol.data.WorkspaceConnection` (the file already tests `questionsFrom`, so these likely exist).

- [ ] **Step 2: Run the test to verify it fails**

Run: `./gradlew testDebugUnitTest --rerun-tasks --tests "com.atomikpanda.groundcontrol.NeedsYouItemTest"`
Expected: FAIL — `questionsFrom` still filters `awaitingReply`, so `t2` is surfaced and `t1` is not (assert mismatch).

- [ ] **Step 3: Implement**

In `NeedsYouItem.kt`, change the `questionsFrom` filter:

```kotlin
fun questionsFrom(conn: WorkspaceConnection, threads: List<ThreadSummary>): List<NeedsYouItem> =
    threads.filter { it.needsYou }
        .map { NeedsYouItem.Question(conn.id, conn.displayName(), it.id, it.subject, it.lastMessage, it.updatedAt ?: "") }
```

(The `NeedsYouItem.Question` type name is retained to avoid cascading renames across `HomeScreen`/tests; its meaning is now "agent needs you", which the row already renders as subject + last message.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `./gradlew testDebugUnitTest --rerun-tasks --tests "com.atomikpanda.groundcontrol.NeedsYouItemTest"`
Expected: PASS.

- [ ] **Step 5: Commit + journal**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/home/NeedsYouItem.kt android/app/src/test/java/com/atomikpanda/groundcontrol/NeedsYouItemTest.kt
git commit -m "fix(gc): Home action cards surface needsYou (was inverted awaitingReply)"
mship journal "gc: questionsFrom filters needsYou; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=7 -->
### Task 7: ground-control — `markThreadSeen` + mark-seen on conversation open

Add the client call to `POST /threads/{id}/seen`, a repo passthrough, and fire it best-effort when a conversation loads — so opening a thread clears its "new" state.

**Work from:** `.worktrees/ground-control-home-surfaces-agent/ground-control`

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/dto/ThreadDtos.kt` (add `SeenBody`)
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/MshipClient.kt` (`SpecApi.markThreadSeen`)
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/ThreadsRepository.kt` (`markSeen` passthrough)
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/ConversationViewModel.kt` (call on load)
- Test: `android/app/src/test/java/com/atomikpanda/groundcontrol/ThreadsApiTest.kt`, `android/app/src/test/java/com/atomikpanda/groundcontrol/ConversationViewModelTest.kt`

- [ ] **Step 1: Write the failing tests**

In `ThreadsApiTest.kt`:

```kotlin
@Test fun mark_thread_seen_posts_to_seen_path_with_auth() = runTest {
    var url: String? = null; var method: String? = null; var auth: String? = null
    val api = SpecApi(client { req ->
        url = req.url.toString(); method = req.method.value; auth = req.headers[HttpHeaders.Authorization]
        respond("""{"id":"t1","subject":"s","messages":[]}""", HttpStatusCode.OK, jsonHdr)
    })
    api.markThreadSeen(conn, "t1", "2026-06-30T12:00:00Z")
    assertTrue(url!!.endsWith("/threads/t1/seen"))
    assertEquals("POST", method)
    assertEquals("Bearer secret", auth)
}
```

In `ConversationViewModelTest.kt`, add a test that a successful load fires a `POST …/seen` (record requests via the handler):

```kotlin
@Test fun load_marks_thread_seen() = runTest {
    val seenPosts = mutableListOf<String>()
    val vm = vm(this) { req ->
        when {
            req.url.encodedPath.endsWith("/threads/t1/seen") && req.method == HttpMethod.Post -> {
                seenPosts += req.url.encodedPath
                respond("""{"id":"t1","subject":"s","messages":[]}""", HttpStatusCode.OK, jsonHdr)
            }
            req.url.encodedPath.endsWith("/threads/t1") && req.method == HttpMethod.Get ->
                respond(threadJson, HttpStatusCode.OK, jsonHdr)
            else -> respondError(HttpStatusCode.NotFound)
        }
    }
    vm.load()?.join()
    advanceUntilIdle()
    assertEquals(1, seenPosts.size)
}
```

Add `import kotlinx.coroutines.test.advanceUntilIdle` if absent.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./gradlew testDebugUnitTest --rerun-tasks --tests "com.atomikpanda.groundcontrol.ThreadsApiTest" --tests "com.atomikpanda.groundcontrol.ConversationViewModelTest"`
Expected: FAIL — `markThreadSeen`/`repo.markSeen` don't exist (compile error).

- [ ] **Step 3: Implement**

(a) In `ThreadDtos.kt`, add the body DTO:

```kotlin
@Serializable data class SeenBody(@SerialName("seen_at") val seenAt: String? = null)
```

(b) In `MshipClient.kt`, add to `SpecApi` (uses the existing private `auth` + `jsonBody` helpers):

```kotlin
    suspend fun markThreadSeen(conn: WorkspaceConnection, id: String, seenAt: String?) {
        client.post("${conn.baseUrl}/threads/$id/seen") { auth(conn); jsonBody(SeenBody(seenAt)) }
    }
```

Add `import com.atomikpanda.groundcontrol.data.dto.SeenBody` if the file imports DTOs individually.

(c) In `ThreadsRepository.kt`, add a passthrough next to the existing `getThread`/`postMessage` delegates:

```kotlin
    suspend fun markSeen(conn: WorkspaceConnection, id: String, seenAt: String?) =
        api.markThreadSeen(conn, id, seenAt)
```

(d) In `ConversationViewModel.kt`, fire mark-seen best-effort after a successful load. Change `load()` and add a helper:

```kotlin
    fun load(): Job? {
        _state.value = ConversationUiState.Loading
        return scope().launch {
            runCatching { repo.getThread(conn, threadId) }
                .onSuccess { thread ->
                    _state.value = ConversationUiState.Content(thread)
                    markSeen(thread)
                }
                .onFailure { t -> _state.value = ConversationUiState.Error(t.toKind(), t.message ?: "error") }
        }
    }

    /** Best-effort: mark this thread seen up to its loaded high-water timestamp.
     *  Never mutates UI state — a failed mark must not disturb the conversation. */
    private fun markSeen(thread: Thread) {
        scope().launch { runCatching { repo.markSeen(conn, threadId, thread.updatedAt) } }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./gradlew testDebugUnitTest --rerun-tasks --tests "com.atomikpanda.groundcontrol.ThreadsApiTest" --tests "com.atomikpanda.groundcontrol.ConversationViewModelTest"`
Expected: PASS.

- [ ] **Step 5: Commit + journal**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/data/dto/ThreadDtos.kt android/app/src/main/java/com/atomikpanda/groundcontrol/data/MshipClient.kt android/app/src/main/java/com/atomikpanda/groundcontrol/data/ThreadsRepository.kt android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/ConversationViewModel.kt android/app/src/test/java/com/atomikpanda/groundcontrol/ThreadsApiTest.kt android/app/src/test/java/com/atomikpanda/groundcontrol/ConversationViewModelTest.kt
git commit -m "feat(gc): markThreadSeen + mark-seen on conversation open"
mship journal "gc: markThreadSeen + open-marks-seen; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=8 -->
### Task 8: ground-control — quiet "new message" line on Home (`unseen && !needsYou`)

Surface unread plain notes as a soft section below the action cards. The thread list is already fetched in `HomeFeedRepository.loadOne`, so derive notes from the same data; thread them through `HomeFeed` → `HomeUiState.Content` with the same workspace-selection filter the action items use.

**Work from:** `.worktrees/ground-control-home-surfaces-agent/ground-control`

**Files:**
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/home/NewMessageNote.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/HomeFeedRepository.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/home/HomeViewModel.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/home/HomeScreen.kt`
- Test: `android/app/src/test/java/com/atomikpanda/groundcontrol/NewMessageNoteTest.kt` (create), `android/app/src/test/java/com/atomikpanda/groundcontrol/HomeFeedRepositoryTest.kt`

- [ ] **Step 1: Write the failing tests**

Create `NewMessageNoteTest.kt`:

```kotlin
package com.atomikpanda.groundcontrol

import com.atomikpanda.groundcontrol.data.WorkspaceConnection
import com.atomikpanda.groundcontrol.data.dto.ThreadSummary
import com.atomikpanda.groundcontrol.ui.home.notesFrom
import org.junit.Assert.assertEquals
import org.junit.Test

class NewMessageNoteTest {
    private val conn = WorkspaceConnection("c1", "http://h", "tok", "ws")

    @Test fun notes_are_unseen_and_not_needs_you() {
        val threads = listOf(
            ThreadSummary(id = "t1", subject = "plain unread", unseen = true),
            ThreadSummary(id = "t2", subject = "needs you", needsYou = true, unseen = true), // action card, not a note
            ThreadSummary(id = "t3", subject = "seen", unseen = false),
        )
        val notes = notesFrom(conn, threads)
        assertEquals(1, notes.size)
        assertEquals("t1", notes[0].threadId)
    }
}
```

In `HomeFeedRepositoryTest.kt`, add a test asserting the feed carries notes (extend the existing `threadsJson` fixture or add one with `"unseen":true`):

```kotlin
@Test fun feed_carries_unseen_notes() = runTest {
    val api = SpecApi(client { req ->
        when {
            req.url.encodedPath.endsWith("/threads") ->
                respond("""[{"id":"t1","subject":"hi","unseen":true}]""", HttpStatusCode.OK, jsonHdr)
            req.url.encodedPath.endsWith("/specs") -> respond("[]", HttpStatusCode.OK, jsonHdr)
            req.url.encodedPath.endsWith("/tasks") -> respond("[]", HttpStatusCode.OK, jsonHdr)
            else -> respondError(HttpStatusCode.NotFound)
        }
    })
    val feed = HomeFeedRepository(api).load(listOf(conn))
    assertEquals(1, feed.notes.size)
    assertEquals("t1", feed.notes[0].threadId)
}
```

(Match the file's existing MockEngine-by-path helper and `conn`/`jsonHdr` definitions.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./gradlew testDebugUnitTest --rerun-tasks --tests "com.atomikpanda.groundcontrol.NewMessageNoteTest" --tests "com.atomikpanda.groundcontrol.HomeFeedRepositoryTest"`
Expected: FAIL — `notesFrom`/`HomeFeed.notes` don't exist (compile error).

- [ ] **Step 3: Implement**

(a) Create `NewMessageNote.kt`:

```kotlin
package com.atomikpanda.groundcontrol.ui.home

import com.atomikpanda.groundcontrol.data.WorkspaceConnection
import com.atomikpanda.groundcontrol.data.dto.ThreadSummary

/** A quiet "new message" entry on Home: an unread plain agent note (not an action item). */
data class NewMessageNote(
    val connectionId: String,
    val workspaceName: String,
    val threadId: String,
    val subject: String,
    val lastMessage: String,
    val updatedAt: String,
)

fun notesFrom(conn: WorkspaceConnection, threads: List<ThreadSummary>): List<NewMessageNote> =
    threads.filter { it.unseen && !it.needsYou }
        .map { NewMessageNote(conn.id, conn.displayName(), it.id, it.subject, it.lastMessage, it.updatedAt ?: "") }
        .sortedByDescending { it.updatedAt }
```

(b) In `HomeFeedRepository.kt`: add `notes` to `HomeFeed` and `ConnResult`, populate in `loadOne`, merge in `load`. Add `import com.atomikpanda.groundcontrol.ui.home.notesFrom`. Changes:

```kotlin
data class HomeFeed(
    val items: List<NeedsYouItem>,
    val notes: List<NewMessageNote>,
    val errors: List<WorkspaceError>,
)
```
```kotlin
    suspend fun load(connections: List<WorkspaceConnection>): HomeFeed = coroutineScope {
        val perConn = connections.map { conn -> async { loadOne(conn) } }.awaitAll()
        HomeFeed(
            items = sortNeedsYou(perConn.flatMap { it.items }),
            notes = perConn.flatMap { it.notes }.sortedByDescending { it.updatedAt },
            errors = perConn.mapNotNull { it.error },
        )
    }

    private data class ConnResult(
        val items: List<NeedsYouItem>,
        val notes: List<NewMessageNote>,
        val error: WorkspaceError?,
    )
```
In `loadOne`, after building `items`, derive notes from the same thread result and return them:
```kotlin
        val notes = t.getOrNull()?.let { notesFrom(conn, it) } ?: emptyList()
        val failed = s.isFailure || t.isFailure || k.isFailure
        ConnResult(items, notes, if (failed) WorkspaceError(conn.id, conn.displayName()) else null)
```
Add `import com.atomikpanda.groundcontrol.ui.home.NewMessageNote`.

(c) In `HomeViewModel.kt`: add `notes` to `HomeUiState.Content`, and in `render` apply the same selection filter:

```kotlin
    data class Content(
        val rail: List<WorkspaceChip>,
        val selectedConnectionId: String?,
        val items: List<NeedsYouItem>,
        val notes: List<NewMessageNote>,
        val errors: List<WorkspaceError>,
    ) : HomeUiState
```
```kotlin
        val visible = if (selected == null) feed.items else feed.items.filter { it.connectionId == selected }
        val visibleNotes = if (selected == null) feed.notes else feed.notes.filter { it.connectionId == selected }
        _state.value = HomeUiState.Content(chips, selected, visible, visibleNotes, feed.errors)
```
Add `import com.atomikpanda.groundcontrol.ui.home.NewMessageNote` (same package — no import needed if `NewMessageNote` is in `ui.home`; HomeViewModel is in `ui.home`, so omit the import).

(d) In `HomeScreen.kt`: render a quiet section after the `items(s.items, …)` block. Update the empty-state guard to also consider notes (so "Nothing needs you right now." only shows when both are empty), then add the notes section:

```kotlin
                if (s.items.isEmpty() && s.notes.isEmpty() && s.errors.isEmpty()) {
                    item {
                        Box(Modifier.fillMaxSize().padding(32.dp), Alignment.Center) {
                            Text("Nothing needs you right now.", style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                }
                items(s.items, key = { it.key }) { item ->
                    NeedsYouRow(item, onApproval, onQuestion, onBlocker)
                }
                if (s.notes.isNotEmpty()) {
                    item {
                        Text(
                            "New messages",
                            style = MaterialTheme.typography.labelMedium,
                            modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 4.dp),
                        )
                    }
                    items(s.notes, key = { "note:${it.connectionId}:${it.threadId}" }) { note ->
                        NewMessageRow(note, onQuestion)
                    }
                }
```

Add the quiet row composable near `NeedsYouRow`:

```kotlin
@Composable
private fun NewMessageRow(note: com.atomikpanda.groundcontrol.ui.home.NewMessageNote, onQuestion: (String, String) -> Unit) {
    ListItem(
        leadingContent = { Icon(Icons.AutoMirrored.Filled.Chat, contentDescription = null) },
        overlineContent = { Text(note.workspaceName, style = MonoStyle) },
        headlineContent = { Text(note.subject) },
        supportingContent = { Text(note.lastMessage) },
        modifier = Modifier.clickable { onQuestion(note.connectionId, note.threadId) },
    )
}
```

(If `MonoStyle`/`Icons.AutoMirrored.Filled.Chat`/`ListItem`/`clickable` aren't already imported in `HomeScreen.kt`, they are — `NeedsYouRow` uses all of them.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./gradlew testDebugUnitTest --rerun-tasks --tests "com.atomikpanda.groundcontrol.NewMessageNoteTest" --tests "com.atomikpanda.groundcontrol.HomeFeedRepositoryTest" --tests "com.atomikpanda.groundcontrol.HomeViewModelTest"`
Expected: PASS (fix any `HomeUiState.Content(...)` construction sites the new `notes` param breaks — e.g. in `HomeViewModelTest` fixtures — by passing `notes = emptyList()`).

- [ ] **Step 5: Full GC suite, then commit + journal**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/ground-control-home-surfaces-agent/ground-control/android
./gradlew testDebugUnitTest --rerun-tasks      # whole module green
cd ..
git add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/home/NewMessageNote.kt android/app/src/main/java/com/atomikpanda/groundcontrol/data/HomeFeedRepository.kt android/app/src/main/java/com/atomikpanda/groundcontrol/ui/home/HomeViewModel.kt android/app/src/main/java/com/atomikpanda/groundcontrol/ui/home/HomeScreen.kt android/app/src/test/java/com/atomikpanda/groundcontrol/NewMessageNoteTest.kt android/app/src/test/java/com/atomikpanda/groundcontrol/HomeFeedRepositoryTest.kt
git commit -m "feat(gc): quiet 'new message' line on Home for unseen notes"
mship journal "gc: Home quiet-note section; full module green" --action committed --test-state pass
```
<!-- /mship:task -->

---

## Deferred follow-up — Task 9: Messages nav tab + unread badge (gated on operator decision)

The "dot on the Messages tab" half of the design requires **adding a Messages nav tab** (today `Section` is only HOME/TASKS/SETTINGS; `MessagesScreen` exists but isn't wired as a tab) plus an **app-level unread count** (`unseen || needsYou` across workspaces, surfaced as a Material3 `BadgedBox`/`Badge` on the tab). It also requires updating `SectionTest.kt` (which hard-asserts exactly `[home, tasks, settings]`).

This is a self-contained IA slice with its own plumbing (where the app-level count comes from — a shared flow / top-level VM polling `listThreads`). If the operator chose "include now," it is appended here as Task 9 after a quick scout of the app-level connection wiring (`GroundControlApp.kt` nav host + the connection store). Otherwise it ships as a fast-follow spec.

---

## Self-Review

- **Spec coverage:** ac1 (needs_you → action card) → T1/T4/T6; ac2 (card clears on reply, not open) → T1 `needs_you` definition (keyed on last human) + T6; ac3 (plain note → new badge: Home line now; Messages-tab dot in T9) → T8 (+ deferred T9); ac4 (open → POST seen, clears + monotonic) → T3/T7; ac5 (kind round-trips, legacy=note) → T1; ac6 (seen monotonic) → T2/T3; ac7 (single shared projection on summaries) → T1 computed fields + T3 `_summaries`; ac8 (GC parses + tiers) → T5/T6/T8; ac9 (suites green) → T4/T8 full-suite steps. The Messages-tab-dot portion of ac3 is explicitly deferred to T9.
- **Placeholder scan:** none — every step has concrete code/commands.
- **Type/name consistency:** `kind`/`seen_at`/`needs_you`/`unseen` (py) and `needsYou`/`unseen`/`markThreadSeen`/`markSeen`/`notesFrom`/`NewMessageNote` (kt) are used consistently across tasks; `HomeUiState.Content` gains `notes` in T8 with construction-site fixes called out.
- **Ordering:** mothership (T1–T4) before ground-control (T5–T8); within GC, DTO (T5) before consumers (T6–T8).
