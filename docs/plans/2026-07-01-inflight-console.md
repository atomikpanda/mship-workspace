# In-flight Console (v1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** Linear **MOS-202** (v1 scope: read + Steer; mutating steering split to MOS-207), part of the *Work Items — phase-aware cockpit* program. Hosts the MOS-198 decision card; builds on MOS-197's farm.

**Goal:** A WorkItem **in-flight console** in Ground Control — a live cockpit for a running work item: parallel task rows + per-task live detail (AC progress, journal, tests), the hosted decision card, and a free-text **Steer** compose. Read + Steer only (reuses the MOS-198 mailbox); Pause/Narrow/Abort are deferred (MOS-207).

**Architecture:** **ground-control only** — every data source already exists server-side. A new `console/{connectionId}/{itemId}` route + `ConsoleViewModel` that loads `GET /items/{id}`, fans out `GET /tasks/{slug}` per child task + `GET /journal/{slug}` + `GET /specs/{spec_id}/review` (AC counts) + `GET /threads/{id}` (the work-item thread), and refreshes on a **client-side interval poll** (no `/tasks` long-poll exists; server `wait` is a later nicety). `ConsoleScreen` renders task rows + focused live detail + the reused `DecisionCard` + a Steer compose bar. `FarmScreen.onOpen` routes `in_flight` items here.

**Tech Stack:** Kotlin, Jetpack Compose (Material3), Ktor 2.3.12, kotlinx.serialization 1.6.3, MVVM. JVM unit tests only (JUnit4 + `MockEngine` — NOT `kotlin.test`). `source ~/toolchains/android-env.sh` before gradle. Focused: `./android/gradlew -p android :app:testDebugUnitTest --tests "com.atomikpanda.groundcontrol.<Class>"`; evidence: `mship test`. Package root `com.atomikpanda.groundcontrol`; source `android/app/src/main/java/...`, tests `.../src/test/java/...`.

---

## File Structure

- **Modify** `data/MshipClient.kt` — add `SpecApi.getItem(conn, id)` + `SpecApi.getSpecReview(conn, specId)` (reuse existing DTOs; `getTask`/`getJournal`/`getThread`/`postMessage` already exist).
- **Maybe modify** `data/dto/SpecDetailDtos.kt` — only if no DTO for `GET /specs/{id}/review` exists yet (the review summary carries the AC counts).
- **Create** `ui/messages/DecisionCard.kt` — extract the existing `DecisionCard` composable out of `ConversationScreen.kt` so the console can reuse it.
- **Create** `ui/console/ConsoleViewModel.kt` + `ui/console/ConsoleScreen.kt`.
- **Modify** `GroundControlApp.kt` — add the `console/{connectionId}/{itemId}` route; repoint `FarmScreen.onOpen` for `in_flight` items.
- **Modify** `ui/tasks/TaskDetailScreen.kt` — drive-by: fix the test-color bug (treat `pass` as green).
- Tests: `WorkItemApiTest.kt` (or extend an existing API test), `ConsoleViewModelTest.kt`.

---

<!-- mship:task id=1 -->
### Task 1: Client — getItem + getSpecReview

**Files:** Modify `data/MshipClient.kt`; maybe `data/dto/SpecDetailDtos.kt`; Test `WorkItemApiTest.kt`

- [ ] **Step 1: Read first** — open `data/MshipClient.kt` (the `SpecApi` methods `listItems`/`getTask`/`getJournal`/`getThread`/`postMessage` + the `auth(conn)` helper) and `data/dto/SpecDetailDtos.kt`. Determine whether a DTO already exists for `GET /specs/{id}/review` (it returns `build_review` = a summary with `criteria_total`/`approved`/`flagged`/`unreviewed`/`open_questions_unanswered`, plus criteria + context). If a suitable review DTO exists, reuse it; if not, add a minimal one (below).

- [ ] **Step 2: Failing test** — `WorkItemApiTest.kt` (JUnit4 + `MockEngine`, mirroring `WorkItemsApiTest`):

```kotlin
@Test fun get_item_path_auth_parse() = runTest {
    var url: String? = null
    val api = SpecApi(HttpClient(MockEngine { req ->
        url = req.url.toString()
        respond("""{"id":"wi-1","kind":"feature","title":"T","phase":"in_flight",
                    "task_slugs":["a"],"thread_ids":["t1"]}""", HttpStatusCode.OK, jsonHdr)
    }) { mshipDefaults() })
    val wi = api.getItem(conn, "wi-1")
    assertEquals("in_flight", wi.phase)
    assertTrue(url!!.endsWith("/items/wi-1"))
}

@Test fun get_spec_review_path_and_counts() = runTest {
    var url: String? = null
    val api = SpecApi(HttpClient(MockEngine { req ->
        url = req.url.toString()
        respond("""{"summary":{"criteria_total":3,"approved":2,"flagged":0,"unreviewed":1,
                    "open_questions_unanswered":0}}""", HttpStatusCode.OK, jsonHdr)
    }) { mshipDefaults() })
    val review = api.getSpecReview(conn, "spec-1")
    assertEquals(3, review.summary.criteriaTotal)
    assertEquals(2, review.summary.approved)
    assertTrue(url!!.endsWith("/specs/spec-1/review"))
}
```

- [ ] **Step 3: Run — expect FAIL** — unresolved `getItem`/`getSpecReview` (and the review DTO if absent).

- [ ] **Step 4: Implement** — in `SpecApi`, after `listItems`/`getTask`:

```kotlin
suspend fun getItem(conn: WorkspaceConnection, id: String): WorkItemSummary =
    client.get("${conn.baseUrl}/items/$id") { auth(conn) }.body()

suspend fun getSpecReview(conn: WorkspaceConnection, specId: String): SpecReview =
    client.get("${conn.baseUrl}/specs/$specId/review") { auth(conn) }.body()
```

If no review DTO exists, add to `data/dto/SpecDetailDtos.kt` (all defaulted; `ignoreUnknownKeys` drops `criteria`/`context` we don't need for the AC bar):

```kotlin
@Serializable
data class SpecReview(val summary: ReviewSummary = ReviewSummary())

@Serializable
data class ReviewSummary(
    @SerialName("criteria_total") val criteriaTotal: Int = 0,
    val approved: Int = 0,
    val flagged: Int = 0,
    val unreviewed: Int = 0,
    @SerialName("open_questions_unanswered") val openQuestionsUnanswered: Int = 0,
)
```

- [ ] **Step 5: Run — expect PASS**; **Step 6:** `mship test` green.

- [ ] **Step 7: Commit** — `feat(console): SpecApi.getItem + getSpecReview` + `mship journal`.
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: Extract DecisionCard into a reusable composable

The console needs to render the decision card outside the conversation. Move `DecisionCard` (and any private helpers it needs) out of `ui/messages/ConversationScreen.kt` into `ui/messages/DecisionCard.kt` as a **non-private** composable, leaving `ConversationScreen` calling it. Pure refactor — no behavior change.

**Files:** Create `ui/messages/DecisionCard.kt`; Modify `ui/messages/ConversationScreen.kt`

- [ ] **Step 1: Read** `ConversationScreen.kt` — find the `DecisionCard` composable + its exact parameter list (it takes the `Decision` payload / option list, a `recommended`, a `resolved`/`enabled` flag, and an `onOption: (String) -> Unit`). Note anything private it depends on.

- [ ] **Step 2: Move it** — cut `DecisionCard` (and any private helper only it uses) into a new `ui/messages/DecisionCard.kt`, same package `com.atomikpanda.groundcontrol.ui.messages`, change `private fun DecisionCard` → `internal fun DecisionCard` (or public). Keep its signature identical. Remove it from `ConversationScreen.kt` (which now just calls it — same package, so no import needed).

- [ ] **Step 3: Build** — `./android/gradlew -p android :app:assembleDebug` → BUILD SUCCESSFUL (ConversationScreen still compiles and renders decisions exactly as before). Then `mship test` green (existing conversation tests unaffected).

- [ ] **Step 4: Commit** — `refactor(console): extract reusable DecisionCard composable` + `mship journal`.
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: ConsoleViewModel

**Files:** Create `ui/console/ConsoleViewModel.kt`; Test `ConsoleViewModelTest.kt`

Loads the item + fans out its children, computes the console state, refreshes on an interval, and exposes `answerOption`/`steer` (both reuse `postMessage` to the work-item thread).

- [ ] **Step 1: Failing test** — `ConsoleViewModelTest.kt` (JUnit4, `MockEngine`, `Dispatchers.setMain(StandardTestDispatcher())`, injected `testScope`; mirror `FarmViewModelTest`). Seed `MockEngine` to answer `/items/{id}` (task_slugs=["a"], thread_ids=["t1"], spec_id=null), `/tasks/a`, `/journal/a`, `/threads/t1`. Assert: after `load().join()`, state is `Content` with one task row (slug "a") and no active decision; and that `steer("go")` issues a `POST /threads/t1/messages`.

- [ ] **Step 2: Run — expect FAIL** — unresolved `ConsoleViewModel`.

- [ ] **Step 3: Implement**

```kotlin
package com.atomikpanda.groundcontrol.ui.console

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.atomikpanda.groundcontrol.data.SpecApi
import com.atomikpanda.groundcontrol.data.WorkspaceConnection
import com.atomikpanda.groundcontrol.data.dto.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlin.coroutines.cancellation.CancellationException

data class ConsoleContent(
    val item: WorkItemSummary,
    val tasks: List<TaskSummary>,
    val journal: List<JournalEntry>,
    val review: ReviewSummary?,          // null when the item has no spec
    val activeDecision: Decision?,       // last unanswered decision on the work-item thread
    val threadId: String?,
)

sealed interface ConsoleUiState {
    data object Loading : ConsoleUiState
    data class Content(val c: ConsoleContent) : ConsoleUiState
    data class Failed(val reason: String) : ConsoleUiState
}

class ConsoleViewModel(
    private val api: SpecApi,
    private val conn: WorkspaceConnection,
    private val itemId: String,
    private val testScope: CoroutineScope? = null,
) : ViewModel() {

    private val _state = MutableStateFlow<ConsoleUiState>(ConsoleUiState.Loading)
    val state: StateFlow<ConsoleUiState> = _state.asStateFlow()
    private val scope get() = testScope ?: viewModelScope

    fun load(): Job = scope.launch { _state.value = fetch() }

    /** Periodic refresh; cancel by cancelling the returned Job (bind to the composable's lifecycle). */
    fun startPolling(intervalMs: Long = 4000): Job = scope.launch {
        while (isActive) {
            delay(intervalMs)
            val next = runCatching { fetch() }.getOrNull()
            if (next is ConsoleUiState.Content) _state.value = next
        }
    }

    private suspend fun fetch(): ConsoleUiState = try {
        val item = api.getItem(conn, itemId)
        coroutineScope {
            val tasks = item.taskSlugs.map { async { runCatching { api.getTask(conn, it) }.getOrNull() } }
            val threadId = item.threadIds.firstOrNull()
            val thread = threadId?.let { runCatching { api.getThread(conn, it) }.getOrNull() }
            val journal = item.taskSlugs.firstOrNull()
                ?.let { runCatching { api.getJournal(conn, it) }.getOrNull() } ?: emptyList()
            val review = item.specId?.let { runCatching { api.getSpecReview(conn, it).summary }.getOrNull() }
            ConsoleUiState.Content(ConsoleContent(
                item = item,
                tasks = tasks.awaitAll().filterNotNull(),
                journal = journal,
                review = review,
                activeDecision = thread?.let { activeDecision(it) },
                threadId = threadId,
            ))
        }
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        ConsoleUiState.Failed(e.message ?: "failed to load")
    }

    /** Last unanswered decision after the last human message (same rule as ConversationScreen). */
    private fun activeDecision(thread: Thread): Decision? {
        val lastHuman = thread.messages.indexOfLast { it.role == "human" }
        return thread.messages.drop(lastHuman + 1)
            .lastOrNull { it.kind == "decision" }?.decision
    }

    fun answerOption(text: String) = steer(text)   // an option tap is a plain human reply

    fun steer(text: String): Job = scope.launch {
        val tid = (state.value as? ConsoleUiState.Content)?.c?.threadId ?: return@launch
        runCatching { api.postMessage(conn, tid, text) }
        _state.value = fetch()
    }
}
```

*(Verify `api.getTask`/`getJournal`/`getThread`/`postMessage` signatures + the `JournalEntry`/`TaskSummary`/`Thread`/`Message`/`Decision` DTO field names against the real files; adjust as needed.)*

- [ ] **Step 4: Run — expect PASS**; **Step 5:** `mship test` green.

- [ ] **Step 6: Commit** — `feat(console): ConsoleViewModel (fan-out load, interval poll, steer)` + `mship journal`.
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: ConsoleScreen (Compose UI)

UI — build + `mship capture` verified (no emulator test). Header + parallel task rows + focused live detail (AC bar, journal tail, tests) + hosted `DecisionCard` (when `activeDecision != null`) + a Steer compose bar.

**Files:** Create `ui/console/ConsoleScreen.kt`

- [ ] **Step 1: Implement** — a `Scaffold` with a back `TopAppBar` (mirror `WorkspaceScreen`/`FarmScreen`), starting `vm.load()` + `vm.startPolling()` in a `LaunchedEffect(Unit)` and cancelling the poll `onDispose`. On `Content`:
  - **Task rows:** one row per `tasks` — kind-agnostic; show `slug`, `phase`, per-repo test status (reuse the Tasks styling; treat `pass`→green), a blocked marker (`blockedReason != null`), a PR marker (`prUrls` non-empty). Use `LocalSemanticColors`/`MonoStyle`.
  - **Live detail:** an AC progress line when `review != null` (`"${approved}/${criteriaTotal} AC approved"` + a small progress bar), the last few `journal` entries (timestamp + message, mono), and the per-repo test results.
  - **Decision card:** when `activeDecision != null`, render `DecisionCard(decision = it, resolved = false, enabled = true, onOption = { vm.answerOption(it) })` (match the extracted signature from Task 2).
  - **Steer:** a compose row (text field + Send) calling `vm.steer(text)` — the free-text escape hatch.
  - `Loading` → spinner/text; `Failed` → an error line (`LocalSemanticColors.current.error`).

- [ ] **Step 2: Build** — `./android/gradlew -p android :app:assembleDebug` → BUILD SUCCESSFUL. (Confirm the `DecisionCard` params + DTO field names against the real files.)

- [ ] **Step 3:** `mship test` green.

- [ ] **Step 4: Commit** — `feat(console): ConsoleScreen — task rows, live detail, decision card, steer` + `mship journal`.
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: Nav wiring + drive-by test-color fix

**Files:** Modify `GroundControlApp.kt`, `ui/tasks/TaskDetailScreen.kt`

- [ ] **Step 1: Add the console route** — mirror the `farm/{connectionId}` composable: a `console/{connectionId}/{itemId}` destination that resolves `conn` via `runBlockingSnapshot(connRepo).firstOrNull{...}`, builds `viewModel(key="console-$connectionId-$itemId"){ ConsoleViewModel(api, conn, itemId) }`, and renders `ConsoleScreen(vm, workspaceName=..., onBack={ nav.popBackStack() })`. Add the `ConsoleScreen`/`ConsoleViewModel` imports.

- [ ] **Step 2: Route in_flight items to the console** — in `FarmScreen.onOpen` wiring (`GroundControlApp.kt` farm composable), when the tapped item's `phase == "in_flight"`, `nav.navigate("console/$connectionId/${item.id}")`; otherwise keep the existing spec/task/thread routing. (The `WorkItemSummary` already carries `phase` + `id`.)

- [ ] **Step 3: Drive-by fix** — `ui/tasks/TaskDetailScreen.kt`: the test-result color currently keys off `status == "green"`, but the server sends `pass`/`fail`/`skip`. Change it to treat `"pass"` as green (and `"fail"` as error). (One-line correctness fix noticed during exploration.)

- [ ] **Step 4: Build** — `assembleDebug` BUILD SUCCESSFUL; then **`mship test`** green.

- [ ] **Step 5: Visual (deferred)** — `mship capture` against the running app: drill into an in-flight item → confirm the console renders task rows + (if present) a decision card. Deferred to operator (no emulator; needs a live in-flight item).

- [ ] **Step 6: Commit** — `feat(console): console route + in_flight drill-in; fix task test-result color` + `mship journal`.
<!-- /mship:task -->

---

## Self-review checklist

- **Spec coverage (v1):** parallel task rows (T3/T4), live detail incl. AC progress from spec-review (T1/T3/T4), journal + tests (T3/T4), hosted decision card (T2/T4), free-text Steer (T3/T4), console route + in_flight drill-in (T5). Mutating steering correctly ABSENT (MOS-207).
- **No new endpoints / mship changes** — reuses `/items/{id}`, `/tasks/{slug}`, `/journal/{slug}`, `/specs/{id}/review`, `/threads/{id}`, `POST /threads/{id}/messages`.
- **Answer reuses the mailbox** — `answerOption`/`steer` both `postMessage` to the work-item thread; agent-agnostic.
- **Conventions** — JUnit4 tests; interval poll cancels with the composable; DecisionCard reused, not duplicated.

## Notes / risks

- **Interval poll, not long-poll** — `/tasks`/`/items` have no `wait`; a 4s client poll is v1. A server long-poll is a later optimization (out of scope).
- **Steer is work-item-level** — `Thread.task_slug` is never populated server-side, so the console steers the work-item's thread (its `threadIds.first()`), not a task-specific one. Task-specific steering is part of MOS-207.
- **AC progress needs a spec** — `review` is null for bug/chore items with no spec; the AC line renders only when present.
- **Journal is first-task** — v1 shows the first task's journal; per-task journal switching can come later.
