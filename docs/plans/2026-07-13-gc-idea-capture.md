# Idea Capture → Agent-Led Brainstorm → Spec (MOS-156) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `gc-idea-capture-mos-156` (approved) — `specs/2026-07-13-gc-idea-capture-mos-156.md`

**Goal:** Let an operator capture an idea in Ground Control, have a host/cloud agent brainstorm it with them in a thread, and produce a spec draft in `needs_review` — with `mship serve` staying LLM-free and the pipeline driver-agnostic.

**Architecture:** A new serve `POST /capture` seeds a thread with the idea (`msgs.create_thread`, which appends the idea as the first human message) and posts an agent `event` handoff (`msgs.append(..., kind="event")`) — exactly the `_notify_dispatch` pattern — so `Thread.awaiting_agent_event` goes true and the shipped `mship _drain` / `inbox wait` surfaces it to a host/cloud agent. The agent brainstorms in the thread and finishes with `mship spec from-thread` → `apply` (→ `needs_review`). Serve does no drafting. Ground Control's Capture screen gains a kind picker ("Quick note" → today's `/threads`; "Brainstorm into a spec" → the new `/capture`).

**Tech Stack:** mothership serve — Python, FastAPI, Pydantic, pytest + `TestClient`. Ground Control — Kotlin, Compose/Material3, Ktor client, kotlinx.serialization; JUnit4 + Ktor `MockEngine` (JVM unit tests only, no emulator).

**Conventions (verified):**
- mothership root `/home/bailey/development/repos/mship-workspace/mothership`; source `src/mship/`, tests `tests/` (mirror `src`). Run: from `mothership/`, `task test` or `uv run pytest -q [path]`.
- ground-control root `…/ground-control/android`; pkg `com.atomikpanda.groundcontrol`; tests flat in `app/src/test/java/com/atomikpanda/groundcontrol/`. Run: from `ground-control/android`, `source ~/toolchains/android-env.sh` then `./gradlew testDebugUnitTest`.
- Commit + `mship journal` after each task. Reused serve symbols: `msgs` (a `MessageStore` built in `create_app`, serve.py:275), `_thread_payload` (serve.py:803), `MessageStore.create_thread`/`append` (`core/message_store.py:80,97`), `Thread.awaiting_agent_event` (`core/message.py:87`). Reused GC symbols: `SpecApi` (`data/MshipClient.kt`), `ThreadsRepository`, `NewThreadViewModel`/`NewThreadScreen` (`ui/messages/`), `NewThreadBody`/`NewMessageBody` DTOs (`data/dto/ThreadDtos.kt`).

---

## File Structure

**mothership:**
- Modify `src/mship/core/serve.py` — add `CaptureBody`, the `_capture_handoff(...)` helper, and the `POST /capture` route in the capture-write section.
- Create `tests/core/test_serve_capture.py` — endpoint tests + the LLM-free guard.
- Modify `src/mship/skills/working-with-mothership/SKILL.md` — a note on handling a capture-brainstorm handoff.

**ground-control:**
- Modify `data/dto/ThreadDtos.kt` — add `CaptureBody`.
- Modify `data/MshipClient.kt` — add `SpecApi.captureBrainstorm(...)`.
- Modify `data/ThreadsRepository.kt` — passthrough.
- Modify `ui/messages/NewThreadViewModel.kt` — add `CaptureKind`, kind state + setter, branch `create()`.
- Modify `ui/messages/NewThreadScreen.kt` — add `showKindPicker` + the dropdown.
- Modify `GroundControlApp.kt` — capture route passes `showKindPicker = true`.
- Tests (flat): `CaptureApiTest.kt`, add cases to `NewThreadViewModelTest.kt` (or create it).

---

<!-- mship:task id=1 -->
### Task 1: Serve — `POST /capture` seeds a thread with the idea

**Files:**
- Modify: `mothership/src/mship/core/serve.py` (capture-write section, ~line 574; `CaptureBody` near the other bodies ~line 90)
- Test: `mothership/tests/core/test_serve_capture.py`

- [ ] **Step 1: Write the failing test**

```python
# mothership/tests/core/test_serve_capture.py
from pathlib import Path

from fastapi.testclient import TestClient

from mship.core.serve import create_app
from mship.core.state import StateManager
from mship.core.message_store import MessageStore


def _app(tmp_path: Path):
    state = StateManager(tmp_path / ".mothership")
    return create_app(
        specs_dir=tmp_path / "specs",
        state_manager=state,
        log_manager=None,
        workspace_root=tmp_path,
        workspace_name="test-ws",
    )


def test_capture_seeds_thread_with_the_idea(tmp_path):
    client = TestClient(_app(tmp_path))
    r = client.post("/capture", json={"idea": "a queue tab for approvals"})
    assert r.status_code == 200, r.text
    thread = r.json()
    tid = thread["id"]
    assert thread["subject"].startswith("a queue tab")
    # first message is the human idea
    assert thread["messages"][0]["role"] == "human"
    assert thread["messages"][0]["text"] == "a queue tab for approvals"

    store = MessageStore(tmp_path / ".mothership" / "messages")
    assert store.get(tid) is not None


def test_capture_rejects_empty_idea(tmp_path):
    client = TestClient(_app(tmp_path))
    r = client.post("/capture", json={"idea": "   "})
    assert r.status_code == 400
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd mothership && uv run pytest -q tests/core/test_serve_capture.py`
Expected: FAIL — 404 (no `/capture` route) / route missing.

- [ ] **Step 3: Add `CaptureBody` and the route**

Near the other Pydantic bodies (after `NewMessageBody`, ~serve.py:97):

```python
class CaptureBody(BaseModel):
    idea: str
    title: str | None = None
```

In the capture-write section (after the `post_apply` handler, ~serve.py:614):

```python
    @app.post("/capture")
    def post_capture(body: CaptureBody):
        """Idea capture → agent-led brainstorm. Seeds a thread with the idea and
        posts an agent `event` handoff so a host/cloud agent drains it (mship
        _drain / inbox wait), brainstorms it in the thread, and produces a spec.
        Serve does NO drafting — it stays LLM-free."""
        idea = body.idea.strip()
        if not idea:
            raise HTTPException(status_code=400, detail="idea must not be empty")
        now = datetime.now(timezone.utc)
        subject = (body.title or idea.splitlines()[0])[:80]
        thread = msgs.create_thread(subject=subject, text=idea, now=now)
        return _thread_payload(msgs.get(thread.id))
```

(The agent-event handoff is added in Task 2.)

- [ ] **Step 4: Run to verify it passes**

Run: `uv run pytest -q tests/core/test_serve_capture.py`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/serve.py tests/core/test_serve_capture.py
git commit -m "feat(serve): POST /capture seeds a thread with the captured idea (MOS-156)"
mship journal "serve /capture creates a thread seeded with the idea; tests passing" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=2 -->
### Task 2: Serve — `/capture` posts the agent-event brainstorm handoff

**Files:**
- Modify: `mothership/src/mship/core/serve.py`
- Test: `mothership/tests/core/test_serve_capture.py` (add)

- [ ] **Step 1: Add the failing test**

```python
def test_capture_posts_one_agent_event_brainstorm_handoff(tmp_path):
    from mship.core.message_store import MessageStore
    client = TestClient(_app(tmp_path))
    tid = client.post("/capture", json={"idea": "a queue tab"}).json()["id"]

    store = MessageStore(tmp_path / ".mothership" / "messages")
    thread = store.get(tid)
    # seed human message + exactly one trailing agent event
    assert [m.role for m in thread.messages] == ["human", "agent"]
    event = thread.messages[-1]
    assert event.kind == "event"
    assert "capture-brainstorm" in event.text          # stable marker
    assert tid in event.text                            # names the thread to brainstorm
    assert "a queue tab" in event.text                  # carries the idea
    assert "mship spec from-thread" in event.text       # tells the driver how to finish
    # this is what makes _drain / inbox wait surface it to a host agent
    assert thread.awaiting_agent_event is True
    assert thread.needs_you is False                    # an event must NOT nag the phone
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest -q tests/core/test_serve_capture.py::test_capture_posts_one_agent_event_brainstorm_handoff`
Expected: FAIL — only the human message exists (`["human"] != ["human","agent"]`).

- [ ] **Step 3: Add the handoff helper + emit it in the route**

Add the helper near the other module-level serve helpers (e.g. after `_dispatch_marker`, ~serve.py:151):

```python
def _capture_handoff(thread_id: str, idea: str) -> str:
    """Agent `event` body for a phone idea capture. Instructs the draining agent
    to brainstorm the idea into a spec IN THIS THREAD and finish via from-thread.
    The leading marker line makes the handoff greppable/idempotent per thread."""
    return (
        f"capture-brainstorm {thread_id}\n\n"
        "An idea was captured from the phone to brainstorm into a spec. Run the "
        "brainstorming flow in THIS thread: ask the operator clarifying questions "
        f"one at a time with `mship reply {thread_id} \"...\"`, settle "
        "purpose/scope/approach, then produce the spec with "
        f"`mship spec from-thread {thread_id}` → fill the draft JSON → "
        "`mship spec apply <id> --from-json <file>`, and reply here when it's drafted.\n\n"
        f"Idea: {idea}"
    )
```

In `post_capture`, after `thread = msgs.create_thread(...)` and before the return, append the event:

```python
        msgs.append(thread.id, "agent", _capture_handoff(thread.id, idea), now, kind="event")
        return _thread_payload(msgs.get(thread.id))
```

(Replace the Task-1 `return _thread_payload(...)` line with these two lines.)

- [ ] **Step 4: Run to verify it passes**

Run: `uv run pytest -q tests/core/test_serve_capture.py`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/serve.py tests/core/test_serve_capture.py
git commit -m "feat(serve): /capture posts an agent-event brainstorm handoff (MOS-156)"
mship journal "serve /capture emits kind=event brainstorm handoff; awaiting_agent_event drains to host agent; tests passing" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=3 -->
### Task 3: Serve — guard that the capture/draft path stays LLM-free

**Files:**
- Test: `mothership/tests/core/test_serve_capture.py` (add)

- [ ] **Step 1: Add the failing/guard test**

```python
def test_capture_and_draft_path_import_no_llm_sdk():
    """AC5: serve stays LLM-free. The modules the capture→draft path touches must
    not import an LLM SDK — the drafting intelligence runs in the agent, not serve."""
    import inspect
    import mship.core.serve as serve_mod
    import mship.core.spec_draft as draft_mod

    banned = ("import anthropic", "from anthropic", "import openai", "from openai")
    for mod in (serve_mod, draft_mod):
        src = inspect.getsource(mod)
        for token in banned:
            assert token not in src, f"{mod.__name__} imports an LLM SDK ({token!r})"
```

- [ ] **Step 2: Run to verify it passes immediately (guard, not TDD-red)**

Run: `uv run pytest -q tests/core/test_serve_capture.py::test_capture_and_draft_path_import_no_llm_sdk`
Expected: PASS (the path is already LLM-free; this test *locks that in* so a future change that adds a serve-side LLM fails loudly).

- [ ] **Step 3: (no implementation — this is a regression guard)**

- [ ] **Step 4: Run the whole capture test file**

Run: `uv run pytest -q tests/core/test_serve_capture.py`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add tests/core/test_serve_capture.py
git commit -m "test(serve): guard that the capture/draft path stays LLM-free (MOS-156 AC5)"
mship journal "LLM-free guard test on serve capture/draft path; passing" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=4 -->
### Task 4: GC — `captureBrainstorm` client method + DTO + repo passthrough

**Files:**
- Modify: `ground-control/android/app/src/main/java/com/atomikpanda/groundcontrol/data/dto/ThreadDtos.kt`
- Modify: `…/data/MshipClient.kt`
- Modify: `…/data/ThreadsRepository.kt`
- Test: `app/src/test/java/com/atomikpanda/groundcontrol/CaptureApiTest.kt`

- [ ] **Step 1: Write the failing test**

```kotlin
// app/src/test/java/com/atomikpanda/groundcontrol/CaptureApiTest.kt
package com.atomikpanda.groundcontrol

import com.atomikpanda.groundcontrol.data.SpecApi
import com.atomikpanda.groundcontrol.data.WorkspaceConnection
import com.atomikpanda.groundcontrol.data.mshipDefaults
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CaptureApiTest {
    private val conn = WorkspaceConnection("1", "http://h:47100", "secret", "ws")
    private val jsonHdr = headersOf(HttpHeaders.ContentType, "application/json")

    @Test fun capture_brainstorm_posts_idea_to_capture_with_auth() = runTest {
        var url: String? = null
        var auth: String? = null
        var body: String? = null
        val api = SpecApi(HttpClient(MockEngine { req ->
            url = req.url.toString(); auth = req.headers[HttpHeaders.Authorization]
            body = (req.body as io.ktor.http.content.TextContent).text
            respond(
                """{"id":"t1","subject":"a queue tab","messages":[{"id":"m1","thread_id":"t1","role":"human","text":"a queue tab","kind":"note"}]}""",
                HttpStatusCode.OK, jsonHdr,
            )
        }) { mshipDefaults() })

        val thread = api.captureBrainstorm(conn, "a queue tab")
        assertEquals("t1", thread.id)
        assertTrue(url!!.endsWith("/capture"))
        assertEquals("Bearer secret", auth)
        assertTrue(body!!.contains("a queue tab"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ground-control/android && source ~/toolchains/android-env.sh && ./gradlew testDebugUnitTest --tests '*CaptureApiTest'`
Expected: FAIL — `captureBrainstorm` unresolved.

- [ ] **Step 3: Add the DTO, client method, and repo passthrough**

`data/dto/ThreadDtos.kt` (next to `NewThreadBody`):

```kotlin
@Serializable data class CaptureBody(val idea: String, val title: String? = null)
```

`data/MshipClient.kt` (next to `createThread`):

```kotlin
    suspend fun captureBrainstorm(conn: WorkspaceConnection, idea: String, title: String? = null): Thread =
        client.post("${conn.baseUrl}/capture") { auth(conn); jsonBody(CaptureBody(idea, title)) }.body()
```

Add the import if needed: `import com.atomikpanda.groundcontrol.data.dto.CaptureBody`.

`data/ThreadsRepository.kt` (next to `createThread`):

```kotlin
    suspend fun captureBrainstorm(conn: WorkspaceConnection, idea: String, title: String? = null) =
        api.captureBrainstorm(conn, idea, title)
```

- [ ] **Step 4: Run to verify it passes**

Run: `./gradlew testDebugUnitTest --tests '*CaptureApiTest'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/src/main/java/com/atomikpanda/groundcontrol/data/dto/ThreadDtos.kt \
        app/src/main/java/com/atomikpanda/groundcontrol/data/MshipClient.kt \
        app/src/main/java/com/atomikpanda/groundcontrol/data/ThreadsRepository.kt \
        app/src/test/java/com/atomikpanda/groundcontrol/CaptureApiTest.kt
git commit -m "feat(capture): GC captureBrainstorm client + CaptureBody DTO (MOS-156)"
mship journal "GC SpecApi.captureBrainstorm + CaptureBody + repo passthrough; test passing" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=5 -->
### Task 5: GC — capture kind + `create()` branches to captureBrainstorm

**Files:**
- Modify: `…/ui/messages/NewThreadViewModel.kt`
- Test: `app/src/test/java/com/atomikpanda/groundcontrol/NewThreadViewModelTest.kt`

- [ ] **Step 1: Write the failing test** (real repo over MockEngine; assert which endpoint is hit per kind)

```kotlin
// app/src/test/java/com/atomikpanda/groundcontrol/NewThreadViewModelTest.kt
package com.atomikpanda.groundcontrol

import com.atomikpanda.groundcontrol.data.SpecApi
import com.atomikpanda.groundcontrol.data.ThreadsRepository
import com.atomikpanda.groundcontrol.data.WorkspaceConnection
import com.atomikpanda.groundcontrol.data.mshipDefaults
import com.atomikpanda.groundcontrol.ui.messages.CaptureKind
import com.atomikpanda.groundcontrol.ui.messages.NewThreadViewModel
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertTrue
import org.junit.Test

class NewThreadViewModelTest {
    private val jsonHdr = headersOf(HttpHeaders.ContentType, "application/json")
    private val conns = listOf(WorkspaceConnection("a", "http://a:47100", null, "ws-a"))
    private val threadJson = """{"id":"t1","subject":"s","messages":[]}"""

    private fun vmHittingPath(record: (String) -> Unit): NewThreadViewModel {
        val api = SpecApi(HttpClient(MockEngine { req ->
            record(req.url.encodedPath)
            respond(threadJson, HttpStatusCode.OK, jsonHdr)
        }) { mshipDefaults() })
        return NewThreadViewModel(ThreadsRepository(api), { conns }, testScope = null)
    }

    @Test fun quick_note_posts_to_threads() = runTest {
        var path: String? = null
        val vm = vmHittingPath { path = it }
        vm.load(); vm.onSelectKind(CaptureKind.QUICK_NOTE); vm.onTextChange("hi")
        vm.create()?.join()
        assertTrue(path!!.endsWith("/threads"))
    }

    @Test fun brainstorm_spec_posts_to_capture() = runTest {
        var path: String? = null
        val vm = vmHittingPath { path = it }
        vm.load(); vm.onSelectKind(CaptureKind.BRAINSTORM_SPEC); vm.onTextChange("an idea")
        vm.create()?.join()
        assertTrue(path!!.endsWith("/capture"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./gradlew testDebugUnitTest --tests '*NewThreadViewModelTest'`
Expected: FAIL — `CaptureKind`, `onSelectKind` unresolved.

- [ ] **Step 3: Add the kind to the ViewModel**

In `ui/messages/NewThreadViewModel.kt`: add the enum (top of file), the state field, the setter, and branch `create()`:

```kotlin
enum class CaptureKind { QUICK_NOTE, BRAINSTORM_SPEC }
```

Add to `NewThreadUiState`:

```kotlin
    val kind: CaptureKind = CaptureKind.QUICK_NOTE,
```

Add the setter (next to `onSelectConnection`):

```kotlin
    fun onSelectKind(k: CaptureKind) { _state.value = _state.value.copy(kind = k) }
```

Replace the `runCatching { repo.createThread(conn, s.text.trim(), subject) }` line inside `create()` with a kind branch:

```kotlin
            runCatching {
                when (s.kind) {
                    CaptureKind.QUICK_NOTE -> repo.createThread(conn, s.text.trim(), subject)
                    CaptureKind.BRAINSTORM_SPEC -> repo.captureBrainstorm(conn, s.text.trim(), subject)
                }
            }
```

(Both return a `Thread`; the existing `.onSuccess { thread -> … Created(conn.id, thread.id) }` is unchanged, so the screen navigates to the thread either way.)

- [ ] **Step 4: Run to verify it passes**

Run: `./gradlew testDebugUnitTest --tests '*NewThreadViewModelTest'`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/NewThreadViewModel.kt \
        app/src/test/java/com/atomikpanda/groundcontrol/NewThreadViewModelTest.kt
git commit -m "feat(capture): kind picker state — brainstorm-into-spec routes to /capture (MOS-156)"
mship journal "NewThreadViewModel CaptureKind + create() branch to captureBrainstorm; tests passing" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=6 -->
### Task 6: GC — kind-picker UI + wire the Capture route

**Files:**
- Modify: `…/ui/messages/NewThreadScreen.kt`
- Modify: `…/GroundControlApp.kt`

Compose UI glue (no unit test — instrumentation isn't run; the branching logic is tested in Task 5). Verify via `./gradlew compileDebugKotlin` + `assembleDebug`.

- [ ] **Step 1: Add a `showKindPicker` param + the dropdown to `NewThreadScreen`**

Add the parameter to the signature (after `submitLabel`):

```kotlin
    showKindPicker: Boolean = false,
```

Inside the `Column` (before the `showSubject` block, ~line 108), render the picker when enabled, reusing the existing `WorkspacePickerDropdown` pattern in this file:

```kotlin
            if (showKindPicker) {
                WorkspacePickerDropdown(
                    label = when (state.kind) {
                        CaptureKind.QUICK_NOTE -> "Quick note"
                        CaptureKind.BRAINSTORM_SPEC -> "Brainstorm into a spec"
                    },
                    options = listOf(
                        CaptureKind.QUICK_NOTE.name to "Quick note",
                        CaptureKind.BRAINSTORM_SPEC.name to "Brainstorm into a spec",
                    ),
                    onPick = { vm.onSelectKind(CaptureKind.valueOf(it)) },
                )
            }
```

Add the import: `import com.atomikpanda.groundcontrol.ui.messages.CaptureKind` is same-package (no import needed); ensure `state.kind` resolves (it does, from Task 5).

- [ ] **Step 2: Pass `showKindPicker = true` from the Capture route**

In `GroundControlApp.kt` `composable("capture")` block (~line 373), add to the `NewThreadScreen(...)` call:

```kotlin
                    showKindPicker = true,
```

- [ ] **Step 3: Compile + build**

Run: `cd ground-control/android && source ~/toolchains/android-env.sh && ./gradlew compileDebugKotlin && ./gradlew assembleDebug`
Expected: BUILD SUCCESSFUL. Also `./gradlew testDebugUnitTest` — all green.

- [ ] **Step 4: Commit**

```bash
git add app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/NewThreadScreen.kt \
        app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApp.kt
git commit -m "feat(capture): kind-picker UI on the Capture screen (MOS-156)"
mship journal "NewThreadScreen kind picker + Capture route wired; assembleDebug green" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=7 -->
### Task 7: Docs — teach agents to handle a capture-brainstorm handoff

**Files:**
- Modify: `mothership/src/mship/skills/working-with-mothership/SKILL.md`

- [ ] **Step 1: Add a short section** (place it near the existing mailbox/`inbox wait` / agent-event guidance; keep the prose tight and matching the file's voice)

```markdown
### Capture-brainstorm handoffs

When you drain an agent-`event` thread whose body starts with `capture-brainstorm <thread-id>`,
an operator captured an idea from the phone for you to brainstorm into a spec. Run the
brainstorming flow **in that thread**: ask clarifying questions one at a time with
`mship reply <thread-id> "<question>"`, settle purpose/scope/approach, then produce the spec
with `mship spec from-thread <thread-id>` → fill the emitted draft JSON → `mship spec apply <id> --from-json <file>`,
and `mship reply <thread-id>` to note the spec is drafted. The event clears once you post any
non-event message on the thread; serve does no drafting itself.
```

- [ ] **Step 2: Verify the skill still renders/lints** (docs-only; confirm no broken markdown)

Run: `cd mothership && uv run pytest -q tests/ -k skill` (if a skill-validation test exists; otherwise `grep -n "Capture-brainstorm" src/mship/skills/working-with-mothership/SKILL.md` to confirm the edit landed)
Expected: PASS / the grep shows the new section.

- [ ] **Step 3: Commit**

```bash
git add src/mship/skills/working-with-mothership/SKILL.md
git commit -m "docs(skills): handle capture-brainstorm handoffs — brainstorm in-thread then from-thread (MOS-156)"
mship journal "working-with-mothership: capture-brainstorm handoff handling note" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=8 -->
### Task 8: Full verification (both repos) + AC cross-check

**Files:** none (verification only)

- [ ] **Step 1: mothership test suite**

Run: `cd mothership && task test` (or `uv run pytest -q`)
Expected: PASS — new `tests/core/test_serve_capture.py` (4 tests) green, no regressions.

- [ ] **Step 2: ground-control unit tests + build**

Run: `cd ground-control/android && source ~/toolchains/android-env.sh && ./gradlew testDebugUnitTest && ./gradlew assembleDebug`
Expected: BUILD SUCCESSFUL — `CaptureApiTest` + `NewThreadViewModelTest` green, APK builds.

- [ ] **Step 3: End-to-end sanity (manual, optional)**

With a serve running: `POST /capture {"idea":"..."}` → confirm a thread is created with the idea + one agent `event` whose text starts `capture-brainstorm`; confirm `mship inbox wait` / `_drain` surfaces it (a live agent would then brainstorm → `spec from-thread` → `apply` → `needs_review`).

- [ ] **Step 4: Cross-check the 7 acceptance criteria**

AC1 kind-picker choice (T5/T6); AC2 seed thread + agent-event naming thread+idea (T1/T2); AC3 agent drains → brainstorms → from-thread → needs_review (T2 handoff + T7 skill + the shipped from-thread/apply); AC4 active brainstorm visible as a thread, spec lands in needs_review (existing thread list + inbox grouping); AC5 serve LLM-free (T3 guard); AC6 one event per capture / drain doesn't duplicate (T2 — single append, awaiting_agent_event clears on agent action); AC7 no agent → visible thread remains (T1 — the thread persists regardless). Attach evidence with `mship spec evidence gc-idea-capture-mos-156 <acN> <ref>`.

- [ ] **Step 5: Journal**

```bash
mship journal "MOS-156 idea-capture: serve /capture + GC kind-picker + skill note; both suites green" --action verified
```
<!-- /mship:task -->

---

## Self-Review (author check)

**Spec coverage:** All 7 ACs map to tasks (Task 8 Step 4). The driver-agnostic requirement (AC5 second clause) is satisfied structurally — the `/capture` endpoint + thread + `from-thread`/`apply` carry no host-agent assumption, so a future GC-app or serve-side LLM driver can implement the same "seeded thread → needs_review spec" contract; the skill note documents only the *v1 agent* driver.

**Deliberate v1 choices:** The spec is created by the driver at the *end* of the brainstorm (via `from-thread`), so no empty spec stub floats mid-conversation — the in-progress signal is the live thread (matches the spec's Architecture). `from-thread` is CLI-only, so the driver finishes via the CLI; no new serve route for it (keeps the surface minimal). A literal same-text re-POST of `/capture` creates a new thread (a new capture the operator initiated) — the AC6 "no duplicate" property is about one `event` per capture and `_drain` not re-posting, both satisfied by the single `msgs.append`.

**Type consistency:** `CaptureBody{idea,title?}` matches between serve (Pydantic) and GC (`@Serializable`); `captureBrainstorm(conn, idea, title?) -> Thread` is identical across `SpecApi`/`ThreadsRepository`/ViewModel call sites; `CaptureKind{QUICK_NOTE,BRAINSTORM_SPEC}` is used identically in the ViewModel and the screen; the reused serve symbols (`msgs.create_thread`, `msgs.append(kind="event")`, `_thread_payload`, `Thread.awaiting_agent_event`) match the verified source.
