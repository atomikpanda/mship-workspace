# Queue Tab (MOS-225) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `gc-queue-tab-mos-225` (approved) — `specs/2026-07-13-gc-queue-tab-mos-225.md`

**Goal:** Add a one-card-at-a-time cross-workspace approval Queue tab to Ground Control Android that hands the operator the next pending action (approve / decide / blocked / needs-review), lets them act inline for the safe ones, and advances.

**Architecture:** A new `QueueRepository` fans out `GET /items` across every connected workspace (mirroring `HomeFeedRepository`), maps each `WorkItemSummary.attention` boolean into one `QueueCard` per pending action, merges, and urgency-sorts. A `QueueViewModel` drives a head-of-queue state machine (act / defer / undo / live-refresh-merge / focused-decision-load). A `QueueScreen` renders the current card by kind, reusing the existing `DecisionCard` and spec-`approve` paths; blocked/needs-review cards open detail via the existing `item/{connId}/{itemId}` redirect route or the PR URL. No `mship serve` change — the attention overlay and all actions already exist server-side.

**Tech Stack:** Kotlin, Jetpack Compose + Material3, Navigation-Compose, Ktor 2.3.12 client, kotlinx.serialization. Tests: JUnit4 + `kotlinx-coroutines-test` + Ktor `MockEngine` (JVM unit tests only — no emulator).

**Conventions (verified against the codebase):**
- Root package `com.atomikpanda.groundcontrol`; single Gradle module `:app`; main source `app/src/main/java/com/atomikpanda/groundcontrol/`.
- Test files are **flat** in `app/src/test/java/com/atomikpanda/groundcontrol/` (no `data/`/`ui/` subdirs), package `com.atomikpanda.groundcontrol`.
- The client class is `SpecApi` (in `data/MshipClient.kt`); base URL + bearer are per-call from `WorkspaceConnection`. `SpecApi.listItems`, `getItem`, `getThread`, `approve`, `postItemMessage` already exist — **no new client method is needed**.
- Run tests from `ground-control/android/`: `./gradlew testDebugUnitTest` (source `~/toolchains/android-env.sh` first for `ANDROID_HOME`/JDK17). Or `task test` from `ground-control/`.
- Commit + journal after each task (`mship journal "<what> ; tests passing" --action committed`).

**Reused types (do not redefine):** `WorkspaceConnection`, `WorkspaceError`, `WorkspaceConnection.displayName()` (all in `data/`); `WorkItemSummary`, `Attention`, `ExternalLink` (`data/dto/WorkItemDtos.kt`); `Thread`, `Message`, `Decision` (`data/dto/ThreadDtos.kt`); `DecisionCard` composable (`ui/messages/DecisionCard.kt`); `Section` (`ui/nav/Section.kt`).

---

## File Structure

- Create `data/QueueRepository.kt` — fan-out + action seams (`load`, `approve`, `answerDecision`, `loadDecision`). Returns `QueueFeed(cards, errors)`.
- Create `ui/queue/QueueCard.kt` — the card model (`QueueCard`, `QueueKind`, `QueueTier`), the `cardsFrom(conn, items)` mapper, `pendingDecision(thread)`, `DecisionPrompt`, and `sortQueue`. Pure, no I/O.
- Create `ui/queue/QueueViewModel.kt` — `QueueUiState` + the head-of-queue state machine.
- Create `ui/queue/QueueScreen.kt` — the one-card Compose UI.
- Modify `ui/nav/Section.kt` — add the `QUEUE` entry.
- Modify `GroundControlApp.kt` — construct `QueueRepository`, wire `composable(Section.QUEUE.route)`, deep-link nav + open-PR.
- Tests (flat): `QueueCardTest.kt`, `QueueRepositoryTest.kt`, `QueueViewModelTest.kt`, and update `SectionTest.kt`.

---

<!-- mship:task id=1 -->
### Task 1: QueueCard model, mappers, and urgency ordering (pure)

**Files:**
- Create: `app/src/main/java/com/atomikpanda/groundcontrol/ui/queue/QueueCard.kt`
- Test: `app/src/test/java/com/atomikpanda/groundcontrol/QueueCardTest.kt`

- [ ] **Step 1: Write the failing test**

```kotlin
// app/src/test/java/com/atomikpanda/groundcontrol/QueueCardTest.kt
package com.atomikpanda.groundcontrol

import com.atomikpanda.groundcontrol.data.WorkspaceConnection
import com.atomikpanda.groundcontrol.data.dto.Attention
import com.atomikpanda.groundcontrol.data.dto.ExternalLink
import com.atomikpanda.groundcontrol.data.dto.WorkItemSummary
import com.atomikpanda.groundcontrol.ui.queue.QueueKind
import com.atomikpanda.groundcontrol.ui.queue.QueueTier
import com.atomikpanda.groundcontrol.ui.queue.cardsFrom
import com.atomikpanda.groundcontrol.ui.queue.sortQueue
import org.junit.Assert.assertEquals
import org.junit.Test

class QueueCardTest {
    private val conn = WorkspaceConnection("c1", "http://h:47100", null, "ws-a")

    private fun item(id: String, att: Attention, updatedAt: String? = null) =
        WorkItemSummary(id = id, kind = "feature", title = "T-$id", phase = "ready", attention = att, updatedAt = updatedAt)

    @Test fun one_card_per_set_attention_flag() {
        val cards = cardsFrom(conn, listOf(item("wi1", Attention(needsApproval = true, blocked = true))))
        assertEquals(setOf(QueueKind.NEEDS_APPROVAL, QueueKind.BLOCKED), cards.map { it.kind }.toSet())
        assertEquals(2, cards.size)
    }

    @Test fun no_flags_yields_no_cards() {
        assertEquals(0, cardsFrom(conn, listOf(item("wi1", Attention()))).size)
    }

    @Test fun card_carries_workspace_specid_threadid_and_pr_url() {
        val it = item("wi1", Attention(needsApproval = true, needsReview = true))
            .copy(specId = "s1", threadIds = listOf("t1"),
                  externalLinks = listOf(ExternalLink(provider = "github", url = "https://gh/pr/1")))
        val cards = cardsFrom(conn, listOf(it))
        val approval = cards.first { it.kind == QueueKind.NEEDS_APPROVAL }
        val review = cards.first { it.kind == QueueKind.NEEDS_REVIEW }
        assertEquals("ws-a", approval.workspaceName)
        assertEquals("s1", approval.specId)
        assertEquals("https://gh/pr/1", review.prUrl)
    }

    @Test fun tiers_rank_blocked_and_decision_above_approval_above_review() {
        assertEquals(QueueTier.URGENT, QueueKind.BLOCKED.tier)
        assertEquals(QueueTier.URGENT, QueueKind.NEEDS_DECISION.tier)
        assertEquals(QueueTier.APPROVAL, QueueKind.NEEDS_APPROVAL.tier)
        assertEquals(QueueTier.REVIEW, QueueKind.NEEDS_REVIEW.tier)
    }

    @Test fun sort_is_tier_asc_then_oldest_first_blanks_last() {
        val a = cardsFrom(conn, listOf(item("old", Attention(needsApproval = true), updatedAt = "2026-01-01T00:00:00Z"))).first()
        val b = cardsFrom(conn, listOf(item("new", Attention(needsApproval = true), updatedAt = "2026-06-01T00:00:00Z"))).first()
        val blank = cardsFrom(conn, listOf(item("blank", Attention(needsApproval = true), updatedAt = null))).first()
        val blocked = cardsFrom(conn, listOf(item("blk", Attention(blocked = true), updatedAt = "2026-06-01T00:00:00Z"))).first()
        val sorted = sortQueue(listOf(b, blank, a, blocked))
        assertEquals(listOf("blk", "old", "new", "blank"), sorted.map { it.workItemId })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ground-control/android && ./gradlew testDebugUnitTest --tests '*QueueCardTest'`
Expected: FAIL — unresolved references (`QueueKind`, `cardsFrom`, `sortQueue`, …).

- [ ] **Step 3: Write minimal implementation**

```kotlin
// app/src/main/java/com/atomikpanda/groundcontrol/ui/queue/QueueCard.kt
package com.atomikpanda.groundcontrol.ui.queue

import com.atomikpanda.groundcontrol.data.WorkspaceConnection
import com.atomikpanda.groundcontrol.data.displayName
import com.atomikpanda.groundcontrol.data.dto.Decision
import com.atomikpanda.groundcontrol.data.dto.Thread
import com.atomikpanda.groundcontrol.data.dto.WorkItemSummary

/** Urgency tiers for the Queue. Lower ordinal = higher urgency. */
enum class QueueTier { URGENT, APPROVAL, REVIEW }

/** The four pending-action kinds a WorkItem's attention overlay can surface. */
enum class QueueKind(val tier: QueueTier) {
    BLOCKED(QueueTier.URGENT),
    NEEDS_DECISION(QueueTier.URGENT),
    NEEDS_APPROVAL(QueueTier.APPROVAL),
    NEEDS_REVIEW(QueueTier.REVIEW),
}

/** One pending action, one card. Identity = (connectionId, workItemId, kind). */
data class QueueCard(
    val connectionId: String,
    val workspaceName: String,
    val workItemId: String,
    val kind: QueueKind,
    val title: String,
    val specId: String? = null,     // NEEDS_APPROVAL: the spec to approve
    val threadId: String? = null,   // NEEDS_DECISION: the thread carrying the decision
    val prUrl: String? = null,      // NEEDS_REVIEW: the PR to open (github external link)
    val blockedTasks: Int = 0,      // BLOCKED: how many tasks are blocked
    val waitingSince: String = "",  // updatedAt proxy; ascending == oldest-waiting first
) {
    val tier: QueueTier get() = kind.tier
    /** Stable, unique key for dedupe + LazyColumn. */
    val key: String get() = "${kind.name}:$connectionId:$workItemId"
}

/** The pending decision extracted from a thread, for inline rendering. */
data class DecisionPrompt(val text: String, val decision: Decision)

/** Map every set attention flag on each item to one [QueueCard]. */
fun cardsFrom(conn: WorkspaceConnection, items: List<WorkItemSummary>): List<QueueCard> =
    items.flatMap { wi ->
        val ws = conn.displayName()
        val since = wi.updatedAt ?: ""
        buildList {
            if (wi.attention.blocked) add(
                QueueCard(conn.id, ws, wi.id, QueueKind.BLOCKED, wi.title,
                    blockedTasks = wi.attention.blockedTasks, waitingSince = since))
            if (wi.attention.needsDecision) add(
                QueueCard(conn.id, ws, wi.id, QueueKind.NEEDS_DECISION, wi.title,
                    threadId = wi.threadIds.firstOrNull(), waitingSince = since))
            if (wi.attention.needsApproval) add(
                QueueCard(conn.id, ws, wi.id, QueueKind.NEEDS_APPROVAL, wi.title,
                    specId = wi.specId, waitingSince = since))
            if (wi.attention.needsReview) add(
                QueueCard(conn.id, ws, wi.id, QueueKind.NEEDS_REVIEW, wi.title,
                    prUrl = wi.externalLinks.firstOrNull { it.provider == "github" }?.url,
                    waitingSince = since))
        }
    }

/** The latest message carrying a decision is the current prompt (attention gates existence). */
fun pendingDecision(thread: Thread): DecisionPrompt? =
    thread.messages.lastOrNull { it.decision != null }
        ?.let { DecisionPrompt(it.text, it.decision!!) }

/** Urgency order: tier asc (URGENT first), then oldest-waiting first; unknown timestamps last. */
internal val queueComparator: Comparator<QueueCard> =
    compareBy<QueueCard> { it.tier.ordinal }.thenBy { it.waitingSince.ifBlank { "￿" } }

fun sortQueue(cards: List<QueueCard>): List<QueueCard> = cards.sortedWith(queueComparator)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./gradlew testDebugUnitTest --tests '*QueueCardTest'`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add app/src/main/java/com/atomikpanda/groundcontrol/ui/queue/QueueCard.kt \
        app/src/test/java/com/atomikpanda/groundcontrol/QueueCardTest.kt
git commit -m "feat(queue): QueueCard model, attention->card mapping, urgency ordering"
mship journal "QueueCard model + cardsFrom + sortQueue; unit tests passing" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=2 -->
### Task 2: QueueRepository — cross-workspace /items fan-out

**Files:**
- Create: `app/src/main/java/com/atomikpanda/groundcontrol/data/QueueRepository.kt`
- Test: `app/src/test/java/com/atomikpanda/groundcontrol/QueueRepositoryTest.kt`

- [ ] **Step 1: Write the failing test** (mirrors `HomeFeedRepositoryTest`; routes `/items` per host)

```kotlin
// app/src/test/java/com/atomikpanda/groundcontrol/QueueRepositoryTest.kt
package com.atomikpanda.groundcontrol

import com.atomikpanda.groundcontrol.data.QueueRepository
import com.atomikpanda.groundcontrol.data.SpecApi
import com.atomikpanda.groundcontrol.data.WorkspaceConnection
import com.atomikpanda.groundcontrol.data.mshipDefaults
import com.atomikpanda.groundcontrol.ui.queue.QueueKind
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class QueueRepositoryTest {
    private val jsonHdr = headersOf(HttpHeaders.ContentType, "application/json")

    // wi-a: blocked + needs_review (2 cards); wi-b: needs_approval (1 card)
    private val itemsJson = """[
      {"id":"wi-a","kind":"feature","title":"A","phase":"review","updated_at":"2026-06-01T00:00:00Z",
       "attention":{"blocked":true,"needs_review":true,"blocked_tasks":1}},
      {"id":"wi-b","kind":"feature","title":"B","phase":"ready","spec_id":"s-b","updated_at":"2026-06-02T00:00:00Z",
       "attention":{"needs_approval":true}}
    ]"""

    private fun api() = SpecApi(HttpClient(MockEngine { req ->
        if (req.url.host == "bad") return@MockEngine respond("boom", HttpStatusCode.InternalServerError, jsonHdr)
        respond(itemsJson, HttpStatusCode.OK, jsonHdr)   // any /items call
    }) { mshipDefaults() })

    @Test fun maps_attention_to_cards_and_urgency_sorts() = runTest {
        val feed = QueueRepository(api()).load(listOf(WorkspaceConnection("c1", "http://good:47100", null, "ws-a")))
        assertEquals(3, feed.cards.size)
        // URGENT (blocked) first, then APPROVAL, then REVIEW
        assertEquals(QueueKind.BLOCKED, feed.cards[0].kind)
        assertEquals(QueueKind.NEEDS_APPROVAL, feed.cards[1].kind)
        assertEquals(QueueKind.NEEDS_REVIEW, feed.cards[2].kind)
        assertTrue(feed.errors.isEmpty())
    }

    @Test fun one_failing_workspace_isolates_to_error_others_still_load() = runTest {
        val feed = QueueRepository(api()).load(listOf(
            WorkspaceConnection("ok", "http://good:47100", null, "ws-a"),
            WorkspaceConnection("c2", "http://bad:47100", null, "ws-bad"),
        ))
        assertEquals(3, feed.cards.size)
        assertTrue(feed.cards.all { it.connectionId == "ok" })
        assertEquals(listOf("ws-bad"), feed.errors.map { it.workspaceName })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gradlew testDebugUnitTest --tests '*QueueRepositoryTest'`
Expected: FAIL — `QueueRepository` unresolved.

- [ ] **Step 3: Write minimal implementation**

```kotlin
// app/src/main/java/com/atomikpanda/groundcontrol/data/QueueRepository.kt
package com.atomikpanda.groundcontrol.data

import com.atomikpanda.groundcontrol.data.dto.Decision
import com.atomikpanda.groundcontrol.ui.queue.DecisionPrompt
import com.atomikpanda.groundcontrol.ui.queue.QueueCard
import com.atomikpanda.groundcontrol.ui.queue.cardsFrom
import com.atomikpanda.groundcontrol.ui.queue.pendingDecision
import com.atomikpanda.groundcontrol.ui.queue.sortQueue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope

/** The merged cross-workspace Queue: one card per pending action + per-workspace errors. */
data class QueueFeed(val cards: List<QueueCard>, val errors: List<WorkspaceError>)

/**
 * Fans out `GET /items` over every connected workspace, maps each WorkItem's
 * attention overlay to one card per pending action, and merges into one
 * urgency-sorted list. A workspace whose fetch fails contributes a
 * [WorkspaceError] instead of sinking the whole Queue. Also the action seam for
 * card faces (approve / answer-decision) and the lazy decision loader.
 */
class QueueRepository(private val api: SpecApi) {
    suspend fun load(connections: List<WorkspaceConnection>): QueueFeed = coroutineScope {
        val perConn = connections.map { conn -> async { loadOne(conn) } }.awaitAll()
        QueueFeed(
            cards = sortQueue(perConn.flatMap { it.cards }),
            errors = perConn.mapNotNull { it.error },
        )
    }

    private data class ConnResult(val cards: List<QueueCard>, val error: WorkspaceError?)

    private suspend fun loadOne(conn: WorkspaceConnection): ConnResult =
        runCatching { api.listItems(conn) }
            .onFailure { if (it is CancellationException) throw it }
            .fold(
                onSuccess = { ConnResult(cardsFrom(conn, it), null) },
                onFailure = { ConnResult(emptyList(), WorkspaceError(conn.id, conn.displayName())) },
            )

    /** Approve a spec from a needs_approval card (inline safe action). */
    suspend fun approve(conn: WorkspaceConnection, specId: String) =
        api.approve(conn, specId, bypassGate = false)

    /** Answer a decision: append the tapped option's text to the item's thread. */
    suspend fun answerDecision(conn: WorkspaceConnection, itemId: String, text: String) =
        api.postItemMessage(conn, itemId, text)

    /** Load the pending decision for a focused decision card. Null if none. */
    suspend fun loadDecision(conn: WorkspaceConnection, threadId: String): DecisionPrompt? =
        pendingDecision(api.getThread(conn, threadId))
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./gradlew testDebugUnitTest --tests '*QueueRepositoryTest'`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add app/src/main/java/com/atomikpanda/groundcontrol/data/QueueRepository.kt \
        app/src/test/java/com/atomikpanda/groundcontrol/QueueRepositoryTest.kt
git commit -m "feat(queue): QueueRepository cross-workspace /items fan-out + action seams"
mship journal "QueueRepository load fan-out + approve/answerDecision/loadDecision seams; tests passing" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=3 -->
### Task 3: QueueViewModel — load, empty-config, position indicator, caught-up

**Files:**
- Create: `app/src/main/java/com/atomikpanda/groundcontrol/ui/queue/QueueViewModel.kt`
- Test: `app/src/test/java/com/atomikpanda/groundcontrol/QueueViewModelTest.kt`

- [ ] **Step 1: Write the failing test** (VM test pattern: `Dispatchers.setMain(StandardTestDispatcher())`, pass `this` as `testScope`)

```kotlin
// app/src/test/java/com/atomikpanda/groundcontrol/QueueViewModelTest.kt
package com.atomikpanda.groundcontrol

import com.atomikpanda.groundcontrol.data.QueueRepository
import com.atomikpanda.groundcontrol.data.SpecApi
import com.atomikpanda.groundcontrol.data.WorkspaceConnection
import com.atomikpanda.groundcontrol.data.mshipDefaults
import com.atomikpanda.groundcontrol.ui.queue.QueueUiState
import com.atomikpanda.groundcontrol.ui.queue.QueueViewModel
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class QueueViewModelTest {
    @Before fun setUp() = Dispatchers.setMain(StandardTestDispatcher())
    @After fun tearDown() = Dispatchers.resetMain()

    private val jsonHdr = headersOf(HttpHeaders.ContentType, "application/json")

    // ws-a: one needs_approval item; ws-b: none
    private fun repo() = QueueRepository(SpecApi(HttpClient(MockEngine { req ->
        val body = if (req.url.host == "a")
            """[{"id":"wi1","kind":"feature","title":"A","phase":"ready","spec_id":"s1","attention":{"needs_approval":true}}]"""
        else "[]"
        respond(body, HttpStatusCode.OK, jsonHdr)
    }) { mshipDefaults() }))

    private val conns = listOf(
        WorkspaceConnection("a", "http://a:47100", null, "ws-a"),
        WorkspaceConnection("b", "http://b:47100", null, "ws-b"),
    )

    @Test fun no_connections_yields_empty_config() = runTest {
        val vm = QueueViewModel(repo(), { emptyList() }, this)
        vm.refresh(); kotlinx.coroutines.test.advanceUntilIdle()
        assertEquals(QueueUiState.EmptyConfig, vm.state.value)
    }

    @Test fun loads_one_card_with_position_1_of_1() = runTest {
        val vm = QueueViewModel(repo(), { conns }, this)
        vm.refresh()?.join()
        val c = vm.state.value as QueueUiState.Content
        assertEquals("wi1", c.current!!.workItemId)
        assertEquals(1, c.position)
        assertEquals(1, c.total)
        assertTrue(!c.caughtUp)
    }

    @Test fun empty_queue_is_caught_up() = runTest {
        val vm = QueueViewModel(repo(), { listOf(WorkspaceConnection("b", "http://b:47100", null, "ws-b")) }, this)
        vm.refresh()?.join()
        val c = vm.state.value as QueueUiState.Content
        assertTrue(c.caughtUp)
        assertNull(c.current)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gradlew testDebugUnitTest --tests '*QueueViewModelTest'`
Expected: FAIL — `QueueViewModel` / `QueueUiState` unresolved.

- [ ] **Step 3: Write minimal implementation** (this file grows across Tasks 3–5; write the full file now, later tasks add methods)

```kotlin
// app/src/main/java/com/atomikpanda/groundcontrol/ui/queue/QueueViewModel.kt
package com.atomikpanda.groundcontrol.ui.queue

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.atomikpanda.groundcontrol.data.QueueFeed
import com.atomikpanda.groundcontrol.data.QueueRepository
import com.atomikpanda.groundcontrol.data.WorkspaceConnection
import com.atomikpanda.groundcontrol.data.WorkspaceError
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

sealed interface QueueUiState {
    data object Loading : QueueUiState
    data object EmptyConfig : QueueUiState
    data class Content(
        val cards: List<QueueCard>,               // live queue; head = current card
        val resolved: Int,                        // acted-count, for the position indicator
        val focusedDecision: DecisionPrompt?,     // loaded lazily when the head is a decision
        val errors: List<WorkspaceError>,
        val undo: QueueCard?,                      // last acted card, re-insertable at head
        val inFlight: Boolean,
    ) : QueueUiState {
        val current: QueueCard? get() = cards.firstOrNull()
        val total: Int get() = resolved + cards.size
        val position: Int get() = if (cards.isEmpty()) total else resolved + 1
        val caughtUp: Boolean get() = cards.isEmpty()
    }
}

class QueueViewModel(
    private val repo: QueueRepository,
    private val connectionsProvider: () -> List<WorkspaceConnection>,
    private val testScope: CoroutineScope? = null,
) : ViewModel() {
    private val _state = MutableStateFlow<QueueUiState>(QueueUiState.Loading)
    val state: StateFlow<QueueUiState> = _state.asStateFlow()

    private val resolvedKeys = mutableSetOf<String>()
    private var connById: Map<String, WorkspaceConnection> = emptyMap()

    private fun scope(): CoroutineScope = testScope ?: viewModelScope
    private fun content(): QueueUiState.Content? = _state.value as? QueueUiState.Content
    private fun conn(card: QueueCard): WorkspaceConnection = connById.getValue(card.connectionId)

    fun refresh(): Job? {
        val connections = connectionsProvider()
        if (connections.isEmpty()) { _state.value = QueueUiState.EmptyConfig; return null }
        connById = connections.associateBy { it.id }
        val prev = content()
        if (prev == null) _state.value = QueueUiState.Loading
        return scope().launch {
            val feed = repo.load(connections)
            val fresh = feed.cards.filterNot { it.key in resolvedKeys }
            if (prev == null) {
                _state.value = QueueUiState.Content(
                    cards = fresh, resolved = 0, focusedDecision = null,
                    errors = feed.errors, undo = null, inFlight = false,
                )
                maybeLoadDecision(fresh.firstOrNull())
            } else {
                // live refresh: keep the current head stable, merge the rest by urgency
                val head = prev.current
                val merged = mergeKeepingHead(head, fresh)
                _state.value = prev.copy(cards = merged, errors = feed.errors)
            }
        }
    }

    /** Keep [head] at position 0 (don't yank focus); urgency-sort the rest of [fresh] behind it. */
    private fun mergeKeepingHead(head: QueueCard?, fresh: List<QueueCard>): List<QueueCard> =
        listOfNotNull(head) + sortQueue(fresh.filter { it.key != head?.key })

    // --- decision loading, act/defer/undo added in Tasks 4 & 5 ---
    private fun maybeLoadDecision(card: QueueCard?) { /* Task 5 */ }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./gradlew testDebugUnitTest --tests '*QueueViewModelTest'`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add app/src/main/java/com/atomikpanda/groundcontrol/ui/queue/QueueViewModel.kt \
        app/src/test/java/com/atomikpanda/groundcontrol/QueueViewModelTest.kt
git commit -m "feat(queue): QueueViewModel load + empty-config + position/caught-up state"
mship journal "QueueViewModel refresh/load, EmptyConfig, position indicator, caught-up; tests passing" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=4 -->
### Task 4: QueueViewModel — approve / defer / open / undo advance mechanics

**Files:**
- Modify: `app/src/main/java/com/atomikpanda/groundcontrol/ui/queue/QueueViewModel.kt`
- Test: `app/src/test/java/com/atomikpanda/groundcontrol/QueueViewModelTest.kt` (add tests)

- [ ] **Step 1: Add failing tests**

```kotlin
    // append inside QueueViewModelTest

    // ws-a: two needs_approval items -> two cards
    private fun repo2() = QueueRepository(SpecApi(HttpClient(MockEngine { _ ->
        respond("""[
          {"id":"wi1","kind":"feature","title":"A","phase":"ready","spec_id":"s1","updated_at":"2026-01-01T00:00:00Z","attention":{"needs_approval":true}},
          {"id":"wi2","kind":"feature","title":"B","phase":"ready","spec_id":"s2","updated_at":"2026-02-01T00:00:00Z","attention":{"needs_approval":true}}
        ]""", HttpStatusCode.OK, jsonHdr)
    }) { mshipDefaults() }))
    private val one = listOf(WorkspaceConnection("a", "http://a:47100", null, "ws-a"))

    @Test fun approve_removes_head_and_advances() = runTest {
        val vm = QueueViewModel(repo2(), { one }, this)
        vm.refresh()?.join()
        val firstKey = (vm.state.value as QueueUiState.Content).current!!.key
        vm.approveCurrent()?.join()
        val c = vm.state.value as QueueUiState.Content
        assertEquals("wi2", c.current!!.workItemId)   // advanced to the older-tier-equal next
        assertEquals(2, c.total)                       // resolved(1) + remaining(1)
        assertEquals(2, c.position)                    // now on 2 of 2
        assertEquals(firstKey, c.undo!!.key)           // undo armed with the acted card
    }

    @Test fun undo_restores_the_acted_card_at_head() = runTest {
        val vm = QueueViewModel(repo2(), { one }, this)
        vm.refresh()?.join()
        val firstKey = (vm.state.value as QueueUiState.Content).current!!.key
        vm.approveCurrent()?.join()
        vm.undo()
        val c = vm.state.value as QueueUiState.Content
        assertEquals(firstKey, c.current!!.key)
        assertEquals(1, c.position)
        assertNull(c.undo)
    }

    @Test fun defer_sends_head_to_back_without_resolving() = runTest {
        val vm = QueueViewModel(repo2(), { one }, this)
        vm.refresh()?.join()
        val firstKey = (vm.state.value as QueueUiState.Content).current!!.key
        vm.defer()
        val c = vm.state.value as QueueUiState.Content
        assertEquals("wi2", c.current!!.workItemId)          // next is now current
        assertEquals(firstKey, c.cards.last().key)            // deferred card moved to back
        assertEquals(2, c.total)                              // nothing resolved
    }

    @Test fun open_advances_without_arming_undo_or_resolving_key() = runTest {
        val vm = QueueViewModel(repo2(), { one }, this)
        vm.refresh()?.join()
        vm.openCurrent()
        val c = vm.state.value as QueueUiState.Content
        assertEquals("wi2", c.current!!.workItemId)
        assertNull(c.undo)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./gradlew testDebugUnitTest --tests '*QueueViewModelTest'`
Expected: FAIL — `approveCurrent`, `undo`, `defer`, `openCurrent` unresolved.

- [ ] **Step 3: Add the methods to QueueViewModel** (replace the `// --- ... ---` comment block)

```kotlin
    /** Approve the current spec card, then advance (optimistic). Arms undo. */
    fun approveCurrent(): Job? {
        val c = content() ?: return null
        val card = c.current ?: return null
        if (card.kind != QueueKind.NEEDS_APPROVAL || card.specId == null) return null
        resolvedKeys.add(card.key)
        _state.value = c.copy(inFlight = true)
        return scope().launch {
            runCatching { repo.approve(conn(card), card.specId) }
            advancePast(card, armUndo = true)
        }
    }

    /** Answer the current decision card with the tapped option text, then advance. Arms undo. */
    fun answerDecision(optionText: String): Job? {
        val c = content() ?: return null
        val card = c.current ?: return null
        if (card.kind != QueueKind.NEEDS_DECISION) return null
        resolvedKeys.add(card.key)
        _state.value = c.copy(inFlight = true)
        return scope().launch {
            runCatching { repo.answerDecision(conn(card), card.workItemId, optionText) }
            advancePast(card, armUndo = true)
        }
    }

    /** Risky cards (blocked / needs_review): screen navigates; we just advance past the head.
     *  Not added to resolvedKeys, so it returns on the next refresh if still pending. */
    fun openCurrent() {
        val c = content() ?: return
        val card = c.current ?: return
        _state.value = c.copy(cards = c.cards.drop(1), resolved = c.resolved + 1, undo = null, focusedDecision = null)
        maybeLoadDecision(content()?.current)
    }

    /** Send the current card to the back of the queue (reorder, never dismiss). */
    fun defer() {
        val c = content() ?: return
        val card = c.current ?: return
        _state.value = c.copy(cards = c.cards.drop(1) + card, undo = null, focusedDecision = null)
        maybeLoadDecision(content()?.current)
    }

    /** Undo the last inline approve/decision: re-insert the card at the head. */
    fun undo() {
        val c = content() ?: return
        val card = c.undo ?: return
        resolvedKeys.remove(card.key)
        _state.value = c.copy(cards = listOf(card) + c.cards, resolved = (c.resolved - 1).coerceAtLeast(0), undo = null, focusedDecision = null)
        maybeLoadDecision(card)
    }

    private fun advancePast(card: QueueCard, armUndo: Boolean) {
        val c = content() ?: return
        // guard: only advance if the head is still this card (no interleaving refresh moved it)
        if (c.current?.key != card.key) { _state.value = c.copy(inFlight = false); return }
        val remaining = c.cards.drop(1)
        _state.value = c.copy(
            cards = remaining, resolved = c.resolved + 1,
            undo = if (armUndo) card else null, inFlight = false, focusedDecision = null,
        )
        maybeLoadDecision(remaining.firstOrNull())
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./gradlew testDebugUnitTest --tests '*QueueViewModelTest'`
Expected: PASS (all QueueViewModelTest tests).

- [ ] **Step 5: Commit**

```bash
git add app/src/main/java/com/atomikpanda/groundcontrol/ui/queue/QueueViewModel.kt \
        app/src/test/java/com/atomikpanda/groundcontrol/QueueViewModelTest.kt
git commit -m "feat(queue): approve/answer/defer/open/undo advance mechanics"
mship journal "QueueViewModel act/defer/undo/open advance + resolvedKeys; tests passing" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=5 -->
### Task 5: QueueViewModel — live-refresh keeps focus + lazy decision load

**Files:**
- Modify: `app/src/main/java/com/atomikpanda/groundcontrol/ui/queue/QueueViewModel.kt`
- Test: `app/src/test/java/com/atomikpanda/groundcontrol/QueueViewModelTest.kt` (add tests)

- [ ] **Step 1: Add failing tests** (a mutable engine so a 2nd refresh returns a superset; and a decision item)

```kotlin
    // append inside QueueViewModelTest

    @Test fun live_refresh_keeps_current_head_and_inserts_new_behind() = runTest {
        var round = 0
        val engine = MockEngine { _ ->
            round++
            val body = if (round <= 2)  // round 1 = both workspaces' first load
                """[{"id":"wi1","kind":"feature","title":"A","phase":"ready","spec_id":"s1","updated_at":"2026-01-01T00:00:00Z","attention":{"needs_approval":true}}]"""
            else  // later: a new, more-urgent blocked item appears
                """[
                  {"id":"wi1","kind":"feature","title":"A","phase":"ready","spec_id":"s1","updated_at":"2026-01-01T00:00:00Z","attention":{"needs_approval":true}},
                  {"id":"wi9","kind":"feature","title":"Z","phase":"review","updated_at":"2026-03-01T00:00:00Z","attention":{"blocked":true}}
                ]"""
            respond(body, HttpStatusCode.OK, jsonHdr)
        }
        val vm = QueueViewModel(QueueRepository(SpecApi(HttpClient(engine) { mshipDefaults() })), { one }, this)
        vm.refresh()?.join()
        val headBefore = (vm.state.value as QueueUiState.Content).current!!.key
        vm.refresh()?.join()   // live refresh brings in the blocked card
        val c = vm.state.value as QueueUiState.Content
        assertEquals(headBefore, c.current!!.key)              // focus NOT yanked, even though blocked is more urgent
        assertEquals(2, c.cards.size)
        assertTrue(c.cards.any { it.workItemId == "wi9" })     // new card inserted behind
    }

    @Test fun focused_decision_is_loaded_for_a_decision_head() = runTest {
        val engine = MockEngine { req ->
            when {
                req.url.encodedPath.endsWith("/items") -> respond(
                    """[{"id":"wi1","kind":"feature","title":"Q","phase":"in_flight","thread_ids":["t1"],"attention":{"needs_decision":true}}]""",
                    HttpStatusCode.OK, jsonHdr)
                req.url.encodedPath.endsWith("/threads/t1") -> respond(
                    """{"id":"t1","subject":"Q","messages":[
                       {"id":"m1","role":"agent","text":"Pick one","kind":"decision","decision":{"options":["X","Y"],"recommended":0}}]}""",
                    HttpStatusCode.OK, jsonHdr)
                else -> respond("[]", HttpStatusCode.OK, jsonHdr)
            }
        }
        val vm = QueueViewModel(QueueRepository(SpecApi(HttpClient(engine) { mshipDefaults() })), { one }, this)
        vm.refresh()?.join(); kotlinx.coroutines.test.advanceUntilIdle()
        val c = vm.state.value as QueueUiState.Content
        assertEquals("Pick one", c.focusedDecision!!.text)
        assertEquals(listOf("X", "Y"), c.focusedDecision!!.decision.options)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./gradlew testDebugUnitTest --tests '*QueueViewModelTest'`
Expected: FAIL — `focusedDecision` stays null (`maybeLoadDecision` is a stub).

- [ ] **Step 3: Implement `maybeLoadDecision`** (replace the Task-3 stub)

```kotlin
    /** When the head is a decision card, fetch its thread's pending decision into state.
     *  Applies only if that card is still the head when the fetch returns (no stale overwrite). */
    private fun maybeLoadDecision(card: QueueCard?) {
        if (card?.kind != QueueKind.NEEDS_DECISION || card.threadId == null) {
            content()?.let { if (it.focusedDecision != null) _state.value = it.copy(focusedDecision = null) }
            return
        }
        scope().launch {
            val prompt = runCatching { repo.loadDecision(conn(card), card.threadId) }.getOrNull()
            val c = content() ?: return@launch
            if (c.current?.key == card.key) _state.value = c.copy(focusedDecision = prompt)
        }
    }
```

(The live-refresh test already passes given Task 3's `mergeKeepingHead`; this task's second test drives `maybeLoadDecision`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `./gradlew testDebugUnitTest --tests '*QueueViewModelTest'`
Expected: PASS (all).

- [ ] **Step 5: Commit**

```bash
git add app/src/main/java/com/atomikpanda/groundcontrol/ui/queue/QueueViewModel.kt \
        app/src/test/java/com/atomikpanda/groundcontrol/QueueViewModelTest.kt
git commit -m "feat(queue): live-refresh keeps focus + lazy decision load"
mship journal "QueueViewModel live-refresh merge + maybeLoadDecision; tests passing" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=6 -->
### Task 6: Add the QUEUE section to the bottom nav

**Files:**
- Modify: `app/src/main/java/com/atomikpanda/groundcontrol/ui/nav/Section.kt`
- Test: `app/src/test/java/com/atomikpanda/groundcontrol/SectionTest.kt`

- [ ] **Step 1: Read the existing SectionTest and add a failing assertion**

Run: `cat app/src/test/java/com/atomikpanda/groundcontrol/SectionTest.kt` to see its style. Add (adapting to that style) an assertion that `QUEUE` exists with route `"queue"` and sits between HOME and TASKS:

```kotlin
    @Test fun queue_tab_present_after_home() {
        val routes = Section.entries.map { it.route }
        assertTrue(routes.contains("queue"))
        assertEquals(0, routes.indexOf("home"))
        assertEquals(1, routes.indexOf("queue"))   // Queue is the 2nd tab, Home stays start destination
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `./gradlew testDebugUnitTest --tests '*SectionTest'`
Expected: FAIL — no `queue` route.

- [ ] **Step 3: Add the enum entry** (keep HOME first; insert QUEUE second)

```kotlin
package com.atomikpanda.groundcontrol.ui.nav

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Assignment
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material.icons.filled.Settings
import androidx.compose.ui.graphics.vector.ImageVector

enum class Section(val route: String, val label: String, val icon: ImageVector) {
    HOME("home", "Home", Icons.Filled.Home),
    QUEUE("queue", "Queue", Icons.Filled.Inbox),
    TASKS("tasks", "Tasks", Icons.AutoMirrored.Filled.Assignment),
    SETTINGS("settings", "Settings", Icons.Filled.Settings),
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./gradlew testDebugUnitTest --tests '*SectionTest'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/src/main/java/com/atomikpanda/groundcontrol/ui/nav/Section.kt \
        app/src/test/java/com/atomikpanda/groundcontrol/SectionTest.kt
git commit -m "feat(queue): add Queue section to bottom nav"
mship journal "Section.QUEUE added between Home and Tasks; SectionTest passing" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=7 -->
### Task 7: QueueScreen — the one-card UI

**Files:**
- Create: `app/src/main/java/com/atomikpanda/groundcontrol/ui/queue/QueueScreen.kt`

This is Compose UI glue (no unit test — instrumentation isn't run in this environment). All decision logic already lives in the tested `QueueViewModel`. Verify via `./gradlew testDebugUnitTest` (compiles) + `./gradlew assembleDebug` + a manual look at the app (see Task 9). Keep the screen a thin renderer over `QueueUiState`.

- [ ] **Step 1: Write the screen**

```kotlin
// app/src/main/java/com/atomikpanda/groundcontrol/ui/queue/QueueScreen.kt
package com.atomikpanda.groundcontrol.ui.queue

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.atomikpanda.groundcontrol.data.dto.Decision
import com.atomikpanda.groundcontrol.ui.messages.DecisionCard
import kotlinx.coroutines.launch

@Composable
fun QueueScreen(
    vm: QueueViewModel,
    onOpenItem: (connectionId: String, itemId: String) -> Unit,
    onOpenPr: (url: String) -> Unit,
) {
    val state by vm.state.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { vm.refresh() }

    val snackbar = remember { SnackbarHostState() }
    val cs = rememberCoroutineScope()

    Scaffold(snackbarHost = { SnackbarHost(snackbar) }) { padding ->
        Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
            when (val s = state) {
                QueueUiState.Loading -> CircularProgressIndicator()
                QueueUiState.EmptyConfig -> Text("No workspaces connected. Add one in Settings.")
                is QueueUiState.Content -> {
                    val card = s.current
                    if (card == null) {
                        Text("You're all caught up ✓", textAlign = TextAlign.Center)
                    } else {
                        Column(Modifier.fillMaxWidth().padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                            Text("${s.position} of ${s.total}")
                            Spacer(Modifier.height(12.dp))
                            CardFace(
                                card = card,
                                decision = s.focusedDecision,
                                enabled = !s.inFlight,
                                onApprove = { vm.approveCurrent() },
                                onOption = { text ->
                                    vm.answerDecision(text)
                                    cs.launch {
                                        val r = snackbar.showSnackbar("Sent", actionLabel = "Undo")
                                        if (r == SnackbarResult.ActionPerformed) vm.undo()
                                    }
                                },
                                onOpenItem = { vm.openCurrent(); onOpenItem(card.connectionId, card.workItemId) },
                                onOpenPr = { vm.openCurrent(); card.prUrl?.let(onOpenPr) ?: onOpenItem(card.connectionId, card.workItemId) },
                            )
                            Spacer(Modifier.height(8.dp))
                            OutlinedButton(onClick = { vm.defer() }, enabled = !s.inFlight) { Text("Defer") }
                        }
                    }
                }
            }
        }
    }

    // Undo affordance for an inline approve.
    LaunchedEffect(state) {
        val c = state as? QueueUiState.Content ?: return@LaunchedEffect
        if (c.undo != null && c.undo!!.kind == QueueKind.NEEDS_APPROVAL) {
            val r = snackbar.showSnackbar("Approved", actionLabel = "Undo")
            if (r == SnackbarResult.ActionPerformed) vm.undo()
        }
    }
}

@Composable
private fun CardFace(
    card: QueueCard,
    decision: com.atomikpanda.groundcontrol.ui.queue.DecisionPrompt?,
    enabled: Boolean,
    onApprove: () -> Unit,
    onOption: (String) -> Unit,
    onOpenItem: () -> Unit,
    onOpenPr: () -> Unit,
) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Text(card.workspaceName, textAlign = TextAlign.Start)
            Spacer(Modifier.height(4.dp))
            Text(card.title)
            Spacer(Modifier.height(12.dp))
            when (card.kind) {
                QueueKind.NEEDS_APPROVAL ->
                    Button(onClick = onApprove, enabled = enabled && card.specId != null) { Text("Approve") }
                QueueKind.NEEDS_DECISION ->
                    if (decision != null)
                        DecisionCard(text = decision.text, decision = decision.decision, enabled = enabled, onOption = onOption)
                    else CircularProgressIndicator()
                QueueKind.BLOCKED -> {
                    if (card.blockedTasks > 0) { Text("${card.blockedTasks} blocked task(s)"); Spacer(Modifier.height(8.dp)) }
                    Button(onClick = onOpenItem, enabled = enabled) { Text("Open") }
                }
                QueueKind.NEEDS_REVIEW ->
                    Button(onClick = onOpenPr, enabled = enabled) { Text("Open PR") }
            }
        }
    }
}
```

Note: `DecisionCard` is `internal` in `ui/messages/` — same module, so it's callable from `ui/queue/`. If Kotlin flags visibility, drop its `internal` modifier (it's within one module either way).

- [ ] **Step 2: Verify it compiles + unit tests still pass**

Run: `./gradlew testDebugUnitTest`
Expected: PASS (compiles; no new tests here).

- [ ] **Step 3: Commit**

```bash
git add app/src/main/java/com/atomikpanda/groundcontrol/ui/queue/QueueScreen.kt
git commit -m "feat(queue): one-card QueueScreen (approve/decision inline, blocked/review open, defer, undo)"
mship journal "QueueScreen one-card UI wired to QueueViewModel; compiles + unit tests green" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=8 -->
### Task 8: Wire the Queue tab into GroundControlApp

**Files:**
- Modify: `app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApp.kt`

The bottom bar already iterates `Section.entries`, so the tab appears automatically once `Section.QUEUE` exists (Task 6). This task adds the repo + the `composable(Section.QUEUE.route)` route. Reuse the existing `item/{connectionId}/{itemId}` redirect route for open-detail and `LocalUriHandler` for open-PR.

- [ ] **Step 1: Add the repository next to the others** (near `val homeRepo = remember { HomeFeedRepository(api) }`)

```kotlin
    val queueRepo = remember { QueueRepository(api) }
```

- [ ] **Step 2: Add the Queue route** (inside the `NavHost { ... }`, alongside the HOME/TASKS/SETTINGS `composable(...)` blocks). Grab a `uriHandler` from the composition:

```kotlin
            composable(Section.QUEUE.route) {
                val vm = viewModel {
                    QueueViewModel(queueRepo, connectionsProvider = { runBlockingSnapshot(connRepo) })
                }
                val uriHandler = LocalUriHandler.current
                QueueScreen(
                    vm,
                    onOpenItem = { connId, itemId -> nav.navigate("item/$connId/$itemId") },
                    onOpenPr = { url -> uriHandler.openUri(url) },
                )
            }
```

- [ ] **Step 3: Add imports** (at the top of `GroundControlApp.kt`, matching the existing import grouping)

```kotlin
import androidx.compose.ui.platform.LocalUriHandler
import com.atomikpanda.groundcontrol.data.QueueRepository
import com.atomikpanda.groundcontrol.ui.queue.QueueScreen
import com.atomikpanda.groundcontrol.ui.queue.QueueViewModel
```

- [ ] **Step 4: Build to verify wiring compiles**

Run: `cd ground-control/android && source ~/toolchains/android-env.sh && ./gradlew assembleDebug`
Expected: BUILD SUCCESSFUL. (Also re-run `./gradlew testDebugUnitTest` — all green.)

- [ ] **Step 5: Commit**

```bash
git add app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApp.kt
git commit -m "feat(queue): wire Queue tab route (deep-link open-detail + open-PR)"
mship journal "GroundControlApp wires QueueRepository + Queue route; assembleDebug green" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=9 -->
### Task 9: Full verification pass

**Files:** none (verification only)

- [ ] **Step 1: Full unit-test run**

Run: `cd ground-control/android && source ~/toolchains/android-env.sh && ./gradlew testDebugUnitTest`
Expected: BUILD SUCCESSFUL — QueueCardTest, QueueRepositoryTest, QueueViewModelTest, SectionTest all pass, no regressions.

- [ ] **Step 2: Debug build**

Run: `./gradlew assembleDebug`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 3: Lint (non-blocking, review warnings)**

Run: `./gradlew lintDebug`
Expected: no new errors.

- [ ] **Step 4: Cross-check every acceptance criterion against the spec**

Confirm each of the 11 `gc-queue-tab-mos-225` criteria is met by a task: tab (T6/T8), cross-workspace one-card-per-action (T1/T2), urgency+oldest-first (T1), workspace+type+action per card (T1/T7), inline approve+decision with undo (T4/T7), blocked/review open detail (T4/T7/T8), position + caught-up (T3/T7), defer-to-back (T4/T7), live-refresh keeps focus (T5), workspace-labeled + deep-link (T7/T8), partial-failure isolation (T2). Attach evidence with `mship spec evidence gc-queue-tab-mos-225 <acN> "<commit/test>"` if using the AC-evidence loop.

- [ ] **Step 5: Commit any lint fixups + journal**

```bash
mship journal "MOS-225 Queue tab: full test + assembleDebug + lint pass; all 11 ACs covered" --action verified
```
<!-- /mship:task -->

---

## Self-Review (author check)

**Spec coverage:** All 11 acceptance criteria map to tasks (see Task 9 Step 4). The "optional workspace filter" is intentionally omitted from v1 (spec marks it optional) — note as a follow-up, not a gap.

**Deliberate v1 simplifications (consistent with the spec's non-goals):** Card *bodies* show what `GET /items` already carries (title, workspace, blocked-task count) plus the primary action; the richer body sketches in the spec (spec criteria/risks, PR diff/CI/Greptile, blocked reason text) are **not** fetched in v1 — needs_approval/blocked/needs_review lean on "open detail" for depth, and the PR cockpit is MOS-208. Inline **decision** rendering *does* fetch the focused card's thread (one at a time) because AC5 requires picking an option inline.

**Type consistency:** `QueueCard`/`QueueKind`/`QueueTier`/`DecisionPrompt`/`QueueFeed`/`QueueUiState` names are used identically across tasks; `cardsFrom`/`sortQueue`/`pendingDecision`/`mergeKeepingHead`/`maybeLoadDecision`/`advancePast`/`approveCurrent`/`answerDecision`/`openCurrent`/`defer`/`undo` signatures match between definition and call sites. Reused APIs (`SpecApi.listItems/getThread/approve/postItemMessage`, `DecisionCard(text, decision, enabled, onOption)`, `WorkspaceError`, `displayName()`) match the verified source.

**Known edge cases (documented, acceptable for v1):** a head card kept stable across a live refresh may briefly outlive server-side resolution (AC9 "don't yank focus" wins); a multi-thread decision item uses `threadIds.first()`.
