# Typed Decision Protocol Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** Linear **MOS-198** — "Slice 3a — Typed decision protocol (mothership + Ground Control)", part of the *Work Items — phase-aware cockpit* program. The paired in-flight console is MOS-202 (follow-up). Builds on MOS-196 (WorkItem/attention) + MOS-197 (farm).

**Goal:** Let an agent emit a *typed decision* (a question + tappable options) that the operator answers with one tap — replacing chat-at-a-fork. The agent emits via `mship ask`; Ground Control renders a decision card in the conversation; tapping an option posts a normal human reply carrying that option's text (reusing the existing mailbox — **no new write endpoint**); an unanswered decision drives a `needs_decision` attention signal on Home + the farm.

**Architecture:** Additive + reuse. mship: `Message.kind` gains `"decision"` + an optional `DecisionPayload` (options / recommended / allow_free_text); a `Thread.needs_decision` computed field mirrors `needs_you`; `mship ask` emits it; `serve`'s thread summaries expose `needs_decision`; the WorkItem `Attention.needs_decision` rollup is repointed to `any(t.needs_you or t.needs_decision)` (resolving the collision — was a `needs_you`-only proxy). ground-control: the `Message` DTO gains `kind` + payload; the conversation `MessageRow` renders a decision message as a card whose option chips call the existing `vm.send(optionText)`; `ThreadSummary` gains `needsDecision`, wired into the Home queue + notifications. The *answer* is a plain human reply — agent-agnostic, `mship inbox` still just reads text.

**Tech Stack:** mothership (Python/Pydantic/FastAPI/Typer, `uv run pytest` + `mship test`); ground-control (Kotlin/Compose/Ktor, JUnit4 tests via `./android/gradlew -p android :app:testDebugUnitTest`, `source ~/toolchains/android-env.sh` first). Two-repo task (`--repos mothership,ground-control`); `mship test` runs both repos' suites.

---

## File Structure

**mothership:**
- Modify `src/mship/core/message.py` — `Message.kind` += `"decision"`; add `DecisionPayload` + `Message.decision`; add `Thread.needs_decision` computed field.
- Modify `src/mship/core/message_store.py` — widen `append` `kind` + accept `decision` payload.
- Modify `src/mship/cli/message.py` — add `mship ask` command.
- Modify `src/mship/core/serve.py` — `_summaries` += `needs_decision`.
- Modify `src/mship/core/view/workitem_index.py` — repoint `Attention.needs_decision`.

**ground-control** (under `android/app/src/main/java/com/atomikpanda/groundcontrol/`):
- Modify `data/dto/ThreadDtos.kt` — `Message` += `kind`/`options`/`recommended`/`allowFreeText`; `ThreadSummary` += `needsDecision`.
- Modify `ui/messages/ConversationScreen.kt` — decision-card rendering in `MessageRow`.
- Modify `ui/home/NeedsYouItem.kt` + `data/HomeFeedRepository.kt` — surface decisions on Home.
- Modify `notify/NeedsYouCore.kt` — notify on `needsDecision`.

Tests updated alongside each (see per-task).

---

<!-- mship:task id=1 -->
### Task 1: Message.kind += "decision" + DecisionPayload + Thread.needs_decision  [mothership]

**Files:** Modify `src/mship/core/message.py`; Test `tests/core/test_message_model.py`

- [ ] **Step 1: Write the failing test** (append to `tests/core/test_message_model.py`)

```python
from datetime import datetime, timezone
from mship.core.message import Message, Thread, DecisionPayload

def _m(role, kind="note", text="x", decision=None, t="2026-07-01T00:00:00+00:00"):
    return Message(id=text, thread_id="th", role=role, text=text,
                   created_at=datetime.fromisoformat(t), kind=kind, decision=decision)

def test_decision_payload_roundtrips():
    d = DecisionPayload(options=["File-per-thread", "SQLite"], recommended=0)
    m = _m("agent", "decision", "How to store?", decision=d)
    back = Message.model_validate_json(m.model_dump_json())
    assert back.kind == "decision"
    assert back.decision.options == ["File-per-thread", "SQLite"]
    assert back.decision.recommended == 0 and back.decision.allow_free_text is True

def test_needs_decision_true_when_unanswered():
    th = Thread(id="t", subject="s", created_at=datetime.now(timezone.utc),
                updated_at=datetime.now(timezone.utc),
                messages=[_m("agent", "decision", "pick", DecisionPayload(options=["a", "b"]))])
    assert th.needs_decision is True

def test_needs_decision_false_after_human_reply():
    th = Thread(id="t", subject="s", created_at=datetime.now(timezone.utc),
                updated_at=datetime.now(timezone.utc),
                messages=[_m("agent", "decision", "pick", DecisionPayload(options=["a", "b"])),
                          _m("human", "note", "a")])
    assert th.needs_decision is False
```

- [ ] **Step 2: Run — expect FAIL** — `uv run pytest tests/core/test_message_model.py -k decision -v` → ImportError `DecisionPayload`.

- [ ] **Step 3: Implement** — in `src/mship/core/message.py`:

```python
class DecisionPayload(BaseModel):
    options: list[str]
    recommended: int | None = None
    allow_free_text: bool = True
```

Change `Message.kind` and add the payload field:

```python
    kind: Literal["note", "needs_you", "decision"] = "note"
    decision: DecisionPayload | None = None
```

Add a `Thread.needs_decision` computed field mirroring `needs_you` (below `needs_you`):

```python
    @computed_field
    @property
    def needs_decision(self) -> bool:
        """True iff an unanswered agent message with kind=decision exists after the
        operator's last human message (mirrors needs_you)."""
        last_human = -1
        for i, m in enumerate(self.messages):
            if m.role == "human":
                last_human = i
        return any(
            m.role == "agent" and m.kind == "decision"
            for m in self.messages[last_human + 1:]
        )
```

- [ ] **Step 4: Run — expect PASS** — `uv run pytest tests/core/test_message_model.py -v`.

- [ ] **Step 5: Commit** — `git add ...; git commit -m "feat(decision): Message kind=decision + DecisionPayload + Thread.needs_decision"; mship journal "decision message model + needs_decision" --action committed`
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: MessageStore.append carries kind=decision + payload  [mothership]

**Files:** Modify `src/mship/core/message_store.py`; Test `tests/core/test_message_store.py`

- [ ] **Step 1: Failing test** (append)

```python
def test_append_decision_roundtrips(tmp_path):
    from datetime import datetime, timezone
    from mship.core.message_store import MessageStore
    from mship.core.message import DecisionPayload
    store = MessageStore(tmp_path / "messages")
    now = datetime(2026, 7, 1, tzinfo=timezone.utc)
    th = store.create_thread("s", "hi", now)
    store.append(th.id, "agent", "How to store?", now, kind="decision",
                 decision=DecisionPayload(options=["a", "b"], recommended=1))
    got = store.get(th.id)
    assert got.messages[-1].kind == "decision"
    assert got.messages[-1].decision.options == ["a", "b"]
    assert got.needs_decision is True
```

- [ ] **Step 2: Run — expect FAIL** — `uv run pytest tests/core/test_message_store.py -k decision -v` (append() has no `decision` kwarg; kind Literal excludes "decision").

- [ ] **Step 3: Implement** — widen `append` in `src/mship/core/message_store.py`:

```python
    def append(self, thread_id: str, role: Literal["human", "agent"], text: str,
               now: datetime, kind: Literal["note", "needs_you", "decision"] = "note",
               decision: "DecisionPayload | None" = None) -> Message:
        thread = self.get(thread_id)
        if thread is None:
            raise KeyError(thread_id)
        msg = Message(id=_new_id(now), thread_id=thread_id, role=role, text=text,
                      created_at=now, kind=kind, decision=decision)
        thread.messages.append(msg)
        thread.updated_at = now
        self.save(thread)
        return msg
```

Add the import at the top: `from mship.core.message import DecisionPayload, Message, Thread`.

- [ ] **Step 4: Run — expect PASS** — `uv run pytest tests/core/test_message_store.py -v`.

- [ ] **Step 5: Commit** — `git commit -m "feat(decision): MessageStore.append carries decision payload"; mship journal "append decision payload" --action committed`
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: `mship ask` CLI (agent emits a decision)  [mothership]

**Files:** Modify `src/mship/cli/message.py`; Test `tests/cli/test_message.py`

- [ ] **Step 1: Failing test** (append; mirror the existing `reply` test style)

```python
def test_ask_emits_decision(tmp_path, monkeypatch):
    # follow the existing test's container/store setup in this file for _store();
    # then invoke `ask` and assert the appended agent message.
    from typer.testing import CliRunner
    from mship.cli import app
    # ... isolate container to tmp workspace (copy the pattern used by other tests here) ...
    r = CliRunner().invoke(app, ["ask", "<thread-id>", "How to store?",
                                 "--option", "File-per-thread", "--option", "SQLite", "--recommend", "0"])
    assert r.exit_code == 0
    # load the thread via MessageStore and assert last message kind=="decision",
    # decision.options == ["File-per-thread","SQLite"], recommended==0, role=="agent".
```

*(Match `tests/cli/test_message.py`'s existing container-isolation + thread-seed helpers verbatim — reuse them rather than inventing a new harness.)*

- [ ] **Step 2: Run — expect FAIL** — no `ask` command.

- [ ] **Step 3: Implement** — in `src/mship/cli/message.py`, add alongside `reply` (mirror its `_store()` + append pattern):

```python
    @parent.command()
    def ask(
        thread_id: str,
        question: str,
        option: list[str] = typer.Option(..., "--option", help="A choice (repeat for each; ≥2)."),
        recommend: int = typer.Option(None, "--recommend", help="0-based index of the recommended option."),
        no_free_text: bool = typer.Option(False, "--no-free-text", help="Disallow a free-text reply."),
    ) -> None:
        """Post an agent DECISION: a question + tappable options (surfaces as a decision card)."""
        from mship.core.message import DecisionPayload
        if len(option) < 2:
            typer.echo("a decision needs at least two --option values", err=True)
            raise typer.Exit(2)
        if recommend is not None and not (0 <= recommend < len(option)):
            typer.echo(f"--recommend {recommend} out of range for {len(option)} options", err=True)
            raise typer.Exit(2)
        store = _store()
        try:
            store.append(thread_id, "agent", question, datetime.now(timezone.utc),
                         kind="decision",
                         decision=DecisionPayload(options=option, recommended=recommend,
                                                  allow_free_text=not no_free_text))
        except KeyError:
            typer.echo(f"no thread {thread_id!r}", err=True)
            raise typer.Exit(1)
        typer.echo(f"asked {thread_id}: {len(option)} options")
```

- [ ] **Step 4: Run — expect PASS**; also `uv run mship ask --help` lists it.

- [ ] **Step 5: Commit** — `git commit -m "feat(decision): mship ask emits a typed decision"; mship journal "mship ask command" --action committed`
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: serve exposes needs_decision on thread summaries  [mothership]

**Files:** Modify `src/mship/core/serve.py`; Test `tests/core/test_serve.py`

- [ ] **Step 1: Failing test** — assert a thread with an unanswered decision shows `needs_decision: true` on `GET /threads` (mirror the existing needs_you serve test; seed via `MessageStore.append(..., kind="decision", decision=...)`).

- [ ] **Step 2: Run — expect FAIL** — `_summaries` doesn't emit `needs_decision`.

- [ ] **Step 3: Implement** — in `serve.py` `_summaries`, add one line:

```python
                "needs_you": t.needs_you,
                "needs_decision": t.needs_decision,
                "unseen": t.unseen,
```

(`GET /threads/{id}` already returns `t.model_dump(mode="json")`, so per-message `kind`+`decision` flow to the client automatically — no other serve change.)

- [ ] **Step 4: Run — expect PASS** — `uv run pytest tests/core/test_serve.py -v`.

- [ ] **Step 5: Commit** — `git commit -m "feat(decision): serve thread summaries expose needs_decision"; mship journal "serve needs_decision" --action committed`
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: repoint WorkItem Attention.needs_decision (collision fix)  [mothership]

The existing `Attention.needs_decision` was `any(t.needs_you for t in threads)` — a proxy. Repoint it to include real decisions so the farm "decide" badge (MOS-197) reflects both.

**Files:** Modify `src/mship/core/view/workitem_index.py`; Test `tests/core/view/test_workitem_index.py`

- [ ] **Step 1: Failing test** (append) — a work item whose thread has an unanswered `kind=decision` message yields `attention.needs_decision == True`:

```python
def test_attention_needs_decision_from_a_real_decision():
    from mship.core.message import DecisionPayload, Message, Thread
    from datetime import datetime, timezone
    now = datetime(2026, 7, 1, tzinfo=timezone.utc)
    th = Thread(id="t1", subject="s", created_at=now, updated_at=now,
                messages=[Message(id="m", thread_id="t1", role="agent", text="?", created_at=now,
                                  kind="decision", decision=DecisionPayload(options=["a", "b"]))])
    att = compute_attention(None, [], [th])
    assert att.needs_decision is True
```

(The existing `test_needs_decision_from_thread_needs_you` must still pass — `needs_you` still counts.)

- [ ] **Step 2: Run — expect FAIL** (the new test; a decision-only thread has `needs_you == False`).

- [ ] **Step 3: Implement** — in `compute_attention`, change the one line:

```python
        needs_decision=any(t.needs_you or t.needs_decision for t in threads),
```

- [ ] **Step 4: Run — expect PASS** — `uv run pytest tests/core/view/test_workitem_index.py -v`.

- [ ] **Step 5: Commit** — `git commit -m "feat(decision): workitem needs_decision reflects real decisions (not just needs_you)"; mship journal "attention needs_decision repoint" --action committed`
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: Ground-control DTOs — Message payload + ThreadSummary.needsDecision  [ground-control]

**Files:** Modify `data/dto/ThreadDtos.kt`; Test `ThreadDtosTest.kt` (JUnit4)

- [ ] **Step 1: Failing test** — parse a `Message` with `kind:"decision"` + `options`/`recommended`/`allow_free_text`; and a `ThreadSummary` with `needs_decision:true`. Use `org.junit.Test`/`Assert.*` + `buildJson()`.

- [ ] **Step 2: Run — expect FAIL** (`kind`/`options`/`needsDecision` not on the DTOs).

- [ ] **Step 3: Implement** — extend the `Message` data class:

```kotlin
    val kind: String = "note",
    val options: List<String> = emptyList(),
    val recommended: Int? = null,
    @SerialName("allow_free_text") val allowFreeText: Boolean = true,
```

Wait — the server nests these under `decision`, not flat. Match the server shape: add a nested DTO and reference it:

```kotlin
@Serializable
data class Decision(
    val options: List<String> = emptyList(),
    val recommended: Int? = null,
    @SerialName("allow_free_text") val allowFreeText: Boolean = true,
)
```
and on `Message`: `val kind: String = "note",` + `val decision: Decision? = null,`.

Extend `ThreadSummary`: `@SerialName("needs_decision") val needsDecision: Boolean = false,`.

- [ ] **Step 4: Run — expect PASS** — `./android/gradlew -p android :app:testDebugUnitTest --tests "com.atomikpanda.groundcontrol.ThreadDtosTest"`.

- [ ] **Step 5: Commit** — `git commit -m "feat(decision): GC Message.decision payload + ThreadSummary.needsDecision"; mship journal "GC decision DTOs" --action committed`
<!-- /mship:task -->

<!-- mship:task id=7 -->
### Task 7: Decision card in the conversation  [ground-control]

Render an agent `Message` with `kind=="decision"` as a card: the question text + one chip/button per option (highlight `recommended`); tapping an option calls the existing `vm.send(option)`; the `ComposeBar` free-text stays as the escape hatch (hide/disable only if `decision.allowFreeText == false`). UI — build + `mship capture` verified.

**Files:** Modify `ui/messages/ConversationScreen.kt` (branch inside `MessageRow` on `message.kind == "decision"`; pass an `onOption: (String) -> Unit` from the screen that calls `vm.send(it)`).

- [ ] **Step 1: Implement** — in `MessageRow`, when `message.kind == "decision" && message.decision != null`, render the question + a column of option buttons (Material3 `FilledTonalButton`/`AssistChip`), the recommended one visually accented (reuse `LocalSemanticColors.current.question`); each button `onClick = { onOption(option) }`. Thread `onOption` up to where `vm.send(...)` is called (mirror the Send button at ConversationScreen ~line 225 / `requestSpec` pattern). Respect `allowFreeText` for the ComposeBar.

- [ ] **Step 2: Build** — `./android/gradlew -p android :app:assembleDebug` → BUILD SUCCESSFUL. (Confirm the `Message.decision`/`options` field names + `LocalSemanticColors`/`MonoStyle` against the actual files.)

- [ ] **Step 3 (optional unit):** if `ConversationViewModel` exposes `send`, add a `ConversationViewModelTest` asserting an option tap posts a human message with the option text (reuses the existing send-path test harness).

- [ ] **Step 4:** `mship test` green.

- [ ] **Step 5: Commit** — `git commit -m "feat(decision): render decision card with tappable options in conversation"; mship journal "GC decision card" --action committed`
<!-- /mship:task -->

<!-- mship:task id=8 -->
### Task 8: Surface decisions on Home  [ground-control]

**Files:** Modify `ui/home/NeedsYouItem.kt` + `data/HomeFeedRepository.kt`; Test `NeedsYouItemTest.kt`

- [ ] **Step 1: Failing test** — a thread with `needsDecision == true` produces a Home item (extend the existing `questionsFrom` test, or a new `decisionsFrom`).

- [ ] **Step 2: Implement** — mirror `questionsFrom` (which filters `it.needsYou`): add `decisionsFrom(conn, threads)` filtering `it.needsDecision` → a `NeedsYouItem.Question` (reuse the Question variant — a decision opens the thread to tap an option, same route) OR a new `Decision` variant if you want a distinct label/tier. Merge it in `HomeFeedRepository.loadOne` next to `questionsFrom`. Keep the tap routing to the conversation (`onQuestion(connectionId, threadId)`).

- [ ] **Step 3: Run — expect PASS**; **Step 4:** `mship test` green.

- [ ] **Step 5: Commit** — `git commit -m "feat(decision): surface unanswered decisions on Home"; mship journal "GC Home decisions" --action committed`
<!-- /mship:task -->

<!-- mship:task id=9 -->
### Task 9: Notify on unanswered decisions  [ground-control]

**Files:** Modify `notify/NeedsYouCore.kt`; Test `NeedsYouReconcilerTest.kt`

- [ ] **Step 1: Failing test** — the reconciler fires a notification for a thread with `needsDecision == true` (mirror the existing `needsYou` reconciler test).

- [ ] **Step 2: Implement** — in `NeedsYouReconciler.reconcile`, include decisions: change the fire condition from `t.needsYou` to `t.needsYou || t.needsDecision` (same `NotificationChannels.NEEDS_YOU` channel).

- [ ] **Step 3: Run — expect PASS**; **Step 4:** `mship test` green (full two-repo suite).

- [ ] **Step 5: Commit** — `git commit -m "feat(decision): notify on unanswered decisions"; mship journal "GC decision notifications" --action committed`
<!-- /mship:task -->

---

## Self-review checklist (before dispatch)

- **Spec coverage:** typed emit (`mship ask`, Task 3) with `Message.kind=decision`+payload (1-2); operator answer reuses the existing human-reply path (no new endpoint — Task 7 option tap → `vm.send`); `needs_decision` on threads (1), serve (4), work-item attention/farm (5), Home (8), notifications (9); decision card rendering (7). Covered.
- **Agent-agnostic:** the answer is a plain human reply carrying the option text; `mship inbox` reads it as-is. No agent SDK.
- **Collision resolved:** `Attention.needs_decision` repointed to `needs_you or needs_decision` (Task 5) — no regression to the MOS-197 farm badge, now also reflects real decisions.
- **Type consistency:** server nests the payload under `decision` (`DecisionPayload`), so the GC DTO uses a nested `Decision` object (Task 6) — NOT flat fields. `needs_decision` snake_case ↔ `needsDecision`.
- **Conventions:** GC tests use JUnit4 (`org.junit`), not `kotlin.test`.

## Notes / risks

- **`--recommend` default:** Typer treats `None` default as optional; ensure the range check only runs when provided.
- **Decision card row count:** if the decision card adds non-message rows, the conversation auto-scroll (`itemCount`/`animateScrollToItem`) may need the count adjusted — verify in Task 7.
- **allow_free_text:** when `false`, hide/disable the ComposeBar for that thread; the plan keeps it simple (the escape hatch normally stays).
- **In-flight console (MOS-202)** hosts this decision card inside the running-task cockpit — separate slice; this slice makes the card work in the conversation + on Home/farm.
