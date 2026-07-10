# Workspace Farm View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** Linear **MOS-197** — "Slice 2 — Workspace farm view (Ground Control)", part of the *Work Items — phase-aware cockpit* program. Depends on **MOS-196** (merged: `GET /items` + `GET /items/{id}` now serve `WorkItemSummary` with a derived `phase` and an `attention` object).

**Goal:** A per-workspace "farm view" in Ground Control: a vertical, phase-grouped list of WorkItems (sections Inbox → Shaping → Ready → In-flight → Review → Done, Done last), each item a tappable card showing a kind icon, title, a derived sub-line, and attention badges — reached by drilling into a workspace, consuming `GET /items`.

**Architecture:** Mirror ground-control's existing single-workspace pattern (`ui/workspace/WorkspaceViewModel` + `WorkspaceScreen`). Add a `WorkItemSummary`/`Attention` DTO, a `SpecApi.listItems` call, a pure phase-grouping helper (modeled on `UrgencyTier`/`sortNeedsYou`), a `FarmViewModel(api, conn, testScope?)`, a `FarmScreen`, and a `farm/{connectionId}` nav route that the Home "browse workspace" tap now targets. Home stays the cross-workspace "needs you" skim (unchanged). Tapping a farm card routes to the item's existing artifact screen (spec/task/thread) until the per-phase cockpits (later slices) exist.

**Tech Stack:** Kotlin, Jetpack Compose (Material3), Ktor client 2.3.12, kotlinx.serialization 1.6.3, MVVM. JVM unit tests only (no emulator) — `MockEngine` for API/VM tests. Package root `com.atomikpanda.groundcontrol`; source under `ground-control/android/app/src/main/java/...`, tests under `.../app/src/test/java/...`.

**Test commands (run inside the task worktree's `ground-control/`):**
- Preflight (once per shell): `source ~/toolchains/android-env.sh` (puts JDK17 + Android SDK on PATH; see the android-toolchain note).
- Focused: `./gradlew -p android :app:testDebugUnitTest --tests "com.atomikpanda.groundcontrol.<ClassName>"`
- Evidence gate (records `mship test` evidence): `mship test`

---

## File Structure

- **Create** `.../data/dto/WorkItemDtos.kt` — `WorkItemSummary` + nested `Attention` (@Serializable, snake_case, defaulted).
- **Modify** `.../data/MshipClient.kt` — add `SpecApi.listItems(conn)` → `GET /items`.
- **Create** `.../ui/farm/FarmPhase.kt` — `FarmPhase` enum (wire↔label, pipeline order) + `PhaseGroup` + pure `groupByPhase(...)`.
- **Create** `.../ui/farm/FarmViewModel.kt` — `FarmViewModel(api, conn, testScope?)` + `FarmUiState`.
- **Create** `.../ui/farm/FarmScreen.kt` — Compose list: phase sections, item cards, kind icons, attention badges, empty/error states.
- **Modify** `.../GroundControlApp.kt` — add `farm/{connectionId}` route; repoint Home's `onBrowseWorkspace` to it.
- **Tests:** `.../test/.../WorkItemDtosTest.kt`, `WorkItemsApiTest.kt`, `FarmPhaseTest.kt`, `FarmViewModelTest.kt`.

---

<!-- mship:task id=1 -->
### Task 1: WorkItemSummary + Attention DTOs

**Files:**
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/dto/WorkItemDtos.kt`
- Test: `android/app/src/test/java/com/atomikpanda/groundcontrol/WorkItemDtosTest.kt`

- [ ] **Step 1: Write the failing test**

```kotlin
// WorkItemDtosTest.kt
package com.atomikpanda.groundcontrol

import com.atomikpanda.groundcontrol.data.buildJson
import com.atomikpanda.groundcontrol.data.dto.WorkItemSummary
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class WorkItemDtosTest {
    private val json = buildJson()

    @Test
    fun parses_full_item_with_attention() {
        val w = json.decodeFromString(
            WorkItemSummary.serializer(),
            """{"id":"wi-1","kind":"feature","title":"Make capture conversational","phase":"in_flight",
                "spec_id":"s1","task_slugs":["a","b"],"thread_ids":["t1"],
                "attention":{"needs_approval":false,"blocked":true,"blocked_tasks":1,"total_tasks":3},
                "updated_at":"2026-07-01T00:00:00+00:00","extra_unknown":1}""",
        )
        assertEquals("wi-1", w.id)
        assertEquals("in_flight", w.phase)
        assertEquals("s1", w.specId)
        assertEquals(listOf("a", "b"), w.taskSlugs)
        assertTrue(w.attention.blocked)
        assertEquals(1, w.attention.blockedTasks)
        assertEquals(3, w.attention.totalTasks)
    }

    @Test
    fun defaults_when_fields_omitted() {
        val w = json.decodeFromString(
            WorkItemSummary.serializer(),
            """{"id":"wi-2","kind":"question","title":"?","phase":"inbox"}""",
        )
        assertEquals(null, w.specId)
        assertTrue(w.taskSlugs.isEmpty() && w.threadIds.isEmpty())
        assertEquals(false, w.attention.needsDecision)
        assertEquals(0, w.attention.totalTasks)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gradlew -p android :app:testDebugUnitTest --tests "com.atomikpanda.groundcontrol.WorkItemDtosTest"`
Expected: FAIL — unresolved reference `WorkItemSummary`.

- [ ] **Step 3: Write minimal implementation**

```kotlin
// WorkItemDtos.kt
package com.atomikpanda.groundcontrol.data.dto

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class WorkItemSummary(
    val id: String,
    val kind: String,
    val title: String,
    val phase: String,
    @SerialName("spec_id") val specId: String? = null,
    @SerialName("task_slugs") val taskSlugs: List<String> = emptyList(),
    @SerialName("thread_ids") val threadIds: List<String> = emptyList(),
    val attention: Attention = Attention(),
    @SerialName("updated_at") val updatedAt: String? = null,
)

@Serializable
data class Attention(
    @SerialName("needs_approval") val needsApproval: Boolean = false,
    @SerialName("needs_decision") val needsDecision: Boolean = false,
    val blocked: Boolean = false,
    @SerialName("needs_review") val needsReview: Boolean = false,
    @SerialName("blocked_tasks") val blockedTasks: Int = 0,
    @SerialName("total_tasks") val totalTasks: Int = 0,
)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./gradlew -p android :app:testDebugUnitTest --tests "com.atomikpanda.groundcontrol.WorkItemDtosTest"`
Expected: PASS (2 tests). (`buildJson()` in `MshipClient.kt` already sets `ignoreUnknownKeys = true`, so `extra_unknown` is dropped.)

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/data/dto/WorkItemDtos.kt android/app/src/test/java/com/atomikpanda/groundcontrol/WorkItemDtosTest.kt
git commit -m "feat(farm): WorkItemSummary + Attention DTOs"
mship journal "WorkItem DTOs + parse tests" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: SpecApi.listItems → GET /items

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/MshipClient.kt` (add a method right after `listTasks`)
- Test: `android/app/src/test/java/com/atomikpanda/groundcontrol/WorkItemsApiTest.kt`

- [ ] **Step 1: Write the failing test**

```kotlin
// WorkItemsApiTest.kt
package com.atomikpanda.groundcontrol

import com.atomikpanda.groundcontrol.data.SpecApi
import com.atomikpanda.groundcontrol.data.WorkspaceConnection
import com.atomikpanda.groundcontrol.data.mshipDefaults
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.ktor.http.HttpHeaders.ContentType
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class WorkItemsApiTest {
    private val conn = WorkspaceConnection("1", "http://h:47100", "secret", "ws")
    private val jsonHdr = headersOf(ContentType, "application/json")

    @Test
    fun list_items_path_auth_and_parse() = runTest {
        var url: String? = null
        var auth: String? = null
        val api = SpecApi(HttpClient(MockEngine { req ->
            url = req.url.toString(); auth = req.headers[HttpHeaders.Authorization]
            respond(
                """[{"id":"wi-1","kind":"feature","title":"T","phase":"ready","attention":{"needs_approval":true}}]""",
                HttpStatusCode.OK, jsonHdr,
            )
        }) { mshipDefaults() })

        val items = api.listItems(conn)
        assertEquals(1, items.size)
        assertEquals("ready", items[0].phase)
        assertTrue(items[0].attention.needsApproval)
        assertTrue(url!!.endsWith("/items"))
        assertEquals("Bearer secret", auth)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gradlew -p android :app:testDebugUnitTest --tests "com.atomikpanda.groundcontrol.WorkItemsApiTest"`
Expected: FAIL — unresolved reference `listItems`.

- [ ] **Step 3: Write minimal implementation**

In `MshipClient.kt`, import the DTO and add the method immediately after `listTasks` (mirroring its shape exactly):

```kotlin
import com.atomikpanda.groundcontrol.data.dto.WorkItemSummary
```

```kotlin
    suspend fun listItems(conn: WorkspaceConnection): List<WorkItemSummary> =
        client.get("${conn.baseUrl}/items") { auth(conn) }.body()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./gradlew -p android :app:testDebugUnitTest --tests "com.atomikpanda.groundcontrol.WorkItemsApiTest"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/data/MshipClient.kt android/app/src/test/java/com/atomikpanda/groundcontrol/WorkItemsApiTest.kt
git commit -m "feat(farm): SpecApi.listItems -> GET /items"
mship journal "listItems API + MockEngine test" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: Phase model + grouping (pure)

**Files:**
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/farm/FarmPhase.kt`
- Test: `android/app/src/test/java/com/atomikpanda/groundcontrol/FarmPhaseTest.kt`

- [ ] **Step 1: Write the failing test**

```kotlin
// FarmPhaseTest.kt
package com.atomikpanda.groundcontrol

import com.atomikpanda.groundcontrol.data.dto.WorkItemSummary
import com.atomikpanda.groundcontrol.ui.farm.FarmPhase
import com.atomikpanda.groundcontrol.ui.farm.groupByPhase
import kotlin.test.Test
import kotlin.test.assertEquals

class FarmPhaseTest {
    private fun item(id: String, phase: String, updated: String? = null) =
        WorkItemSummary(id = id, kind = "feature", title = id, phase = phase, updatedAt = updated)

    @Test
    fun groups_in_pipeline_order_done_last_empty_sections_dropped() {
        val groups = groupByPhase(
            listOf(item("a", "review"), item("b", "inbox"), item("c", "done"), item("d", "in_flight")),
        )
        // inbox, in_flight, review, done — shaping/ready dropped (empty)
        assertEquals(
            listOf(FarmPhase.INBOX, FarmPhase.IN_FLIGHT, FarmPhase.REVIEW, FarmPhase.DONE),
            groups.map { it.phase },
        )
    }

    @Test
    fun within_a_phase_newest_first() {
        val groups = groupByPhase(
            listOf(item("old", "inbox", "2026-07-01T00:00:00Z"), item("new", "inbox", "2026-07-02T00:00:00Z")),
        )
        assertEquals(listOf("new", "old"), groups.single().items.map { it.id })
    }

    @Test
    fun unknown_phase_is_dropped() {
        assertEquals(emptyList(), groupByPhase(listOf(item("x", "bogus"))))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gradlew -p android :app:testDebugUnitTest --tests "com.atomikpanda.groundcontrol.FarmPhaseTest"`
Expected: FAIL — unresolved reference `FarmPhase` / `groupByPhase`.

- [ ] **Step 3: Write minimal implementation**

```kotlin
// FarmPhase.kt
package com.atomikpanda.groundcontrol.ui.farm

import com.atomikpanda.groundcontrol.data.dto.WorkItemSummary

/** Lifecycle phases in pipeline order (Done last). `wire` matches the server's phase string. */
enum class FarmPhase(val wire: String, val label: String) {
    INBOX("inbox", "Inbox"),
    SHAPING("shaping", "Shaping"),
    READY("ready", "Ready"),
    IN_FLIGHT("in_flight", "In-flight"),
    REVIEW("review", "Review"),
    DONE("done", "Done");

    companion object {
        fun fromWire(s: String): FarmPhase? = entries.firstOrNull { it.wire == s }
    }
}

data class PhaseGroup(val phase: FarmPhase, val items: List<WorkItemSummary>)

/** Bin items by phase in pipeline order; drop empty sections; newest-first within a section.
 *  Items whose phase the client doesn't recognize are omitted (server is source of truth). */
fun groupByPhase(items: List<WorkItemSummary>): List<PhaseGroup> =
    FarmPhase.entries.mapNotNull { phase ->
        items.filter { FarmPhase.fromWire(it.phase) == phase }
            .sortedByDescending { it.updatedAt ?: "" }
            .takeIf { it.isNotEmpty() }
            ?.let { PhaseGroup(phase, it) }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./gradlew -p android :app:testDebugUnitTest --tests "com.atomikpanda.groundcontrol.FarmPhaseTest"`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/farm/FarmPhase.kt android/app/src/test/java/com/atomikpanda/groundcontrol/FarmPhaseTest.kt
git commit -m "feat(farm): phase-grouping model (pipeline order, newest-first)"
mship journal "FarmPhase + groupByPhase + tests" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: FarmViewModel

**Files:**
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/farm/FarmViewModel.kt`
- Test: `android/app/src/test/java/com/atomikpanda/groundcontrol/FarmViewModelTest.kt`

- [ ] **Step 1: Write the failing test**

```kotlin
// FarmViewModelTest.kt
package com.atomikpanda.groundcontrol

import com.atomikpanda.groundcontrol.data.SpecApi
import com.atomikpanda.groundcontrol.data.WorkspaceConnection
import com.atomikpanda.groundcontrol.data.mshipDefaults
import com.atomikpanda.groundcontrol.ui.farm.FarmUiState
import com.atomikpanda.groundcontrol.ui.farm.FarmPhase
import com.atomikpanda.groundcontrol.ui.farm.FarmViewModel
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.ktor.http.HttpHeaders.ContentType
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class FarmViewModelTest {
    private val conn = WorkspaceConnection("1", "http://h:47100", "secret", "ws")
    private val jsonHdr = headersOf(ContentType, "application/json")

    @BeforeTest fun setUp() { Dispatchers.setMain(StandardTestDispatcher()) }
    @AfterTest fun tearDown() { Dispatchers.resetMain() }

    private fun vm(scope: CoroutineScope, fail: Boolean = false) = FarmViewModel(
        SpecApi(HttpClient(MockEngine {
            if (fail) respond("boom", HttpStatusCode.InternalServerError)
            else respond(
                """[{"id":"a","kind":"feature","title":"A","phase":"inbox"},
                    {"id":"b","kind":"bug","title":"B","phase":"in_flight"}]""",
                HttpStatusCode.OK, jsonHdr,
            )
        }) { mshipDefaults() }),
        conn, testScope = scope,
    )

    @Test fun loads_and_groups_items() = runTest {
        val vm = vm(this); vm.refresh().join()
        val c = vm.state.value as FarmUiState.Content
        assertEquals(listOf(FarmPhase.INBOX, FarmPhase.IN_FLIGHT), c.groups.map { it.phase })
        assertTrue(!c.errored)
    }

    @Test fun error_is_isolated_not_crashing() = runTest {
        val vm = vm(this, fail = true); vm.refresh().join()
        val c = vm.state.value as FarmUiState.Content
        assertTrue(c.errored && c.groups.isEmpty())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gradlew -p android :app:testDebugUnitTest --tests "com.atomikpanda.groundcontrol.FarmViewModelTest"`
Expected: FAIL — unresolved reference `FarmViewModel` / `FarmUiState`.

- [ ] **Step 3: Write minimal implementation**

```kotlin
// FarmViewModel.kt
package com.atomikpanda.groundcontrol.ui.farm

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.atomikpanda.groundcontrol.data.SpecApi
import com.atomikpanda.groundcontrol.data.WorkspaceConnection
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlin.coroutines.cancellation.CancellationException

sealed interface FarmUiState {
    data object Loading : FarmUiState
    data class Content(val groups: List<PhaseGroup>, val errored: Boolean) : FarmUiState
}

/** Single-workspace farm: loads GET /items for one connection and bins by phase.
 *  Shape mirrors WorkspaceViewModel (concrete conn + optional testScope). */
class FarmViewModel(
    private val api: SpecApi,
    private val conn: WorkspaceConnection,
    private val testScope: CoroutineScope? = null,
) : ViewModel() {

    private val _state = MutableStateFlow<FarmUiState>(FarmUiState.Loading)
    val state: StateFlow<FarmUiState> = _state.asStateFlow()

    fun refresh(): Job = (testScope ?: viewModelScope).launch {
        _state.value = FarmUiState.Loading
        _state.value = runCatching { api.listItems(conn) }.fold(
            onSuccess = { FarmUiState.Content(groupByPhase(it), errored = false) },
            onFailure = {
                if (it is CancellationException) throw it
                FarmUiState.Content(emptyList(), errored = true)
            },
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./gradlew -p android :app:testDebugUnitTest --tests "com.atomikpanda.groundcontrol.FarmViewModelTest"`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/farm/FarmViewModel.kt android/app/src/test/java/com/atomikpanda/groundcontrol/FarmViewModelTest.kt
git commit -m "feat(farm): FarmViewModel (load /items, group by phase, error-isolated)"
mship journal "FarmViewModel + tests" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: FarmScreen (Compose UI)

UI has no emulator test in this repo — verified by build + `mship capture`. Mirror `HomeScreen.NeedsYouRow` (ListItem slots, `LocalSemanticColors`, `MonoStyle`, kind icons) and `WorkspaceScreen` section structure.

**Files:**
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/farm/FarmScreen.kt`

- [ ] **Step 1: Implement the screen**

```kotlin
// FarmScreen.kt
package com.atomikpanda.groundcontrol.ui.farm

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Description
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.atomikpanda.groundcontrol.data.dto.Attention
import com.atomikpanda.groundcontrol.data.dto.WorkItemSummary
import com.atomikpanda.groundcontrol.ui.theme.LocalSemanticColors
import com.atomikpanda.groundcontrol.ui.theme.MonoStyle

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FarmScreen(
    vm: FarmViewModel,
    workspaceName: String,
    onOpen: (WorkItemSummary) -> Unit,
    onBack: () -> Unit,
) {
    val state by vm.state.collectAsState()
    LaunchedEffect(Unit) { vm.refresh() }

    Scaffold(topBar = { TopAppBar(title = { Text(workspaceName) }) }) { pad ->
        when (val s = state) {
            is FarmUiState.Loading -> Box(Modifier.fillMaxSize().padding(pad)) {
                Text("Loading…", Modifier.padding(24.dp))
            }
            is FarmUiState.Content -> {
                if (s.errored && s.groups.isEmpty()) {
                    Box(Modifier.fillMaxSize().padding(pad)) {
                        Text("Couldn't reach this workspace.", Modifier.padding(24.dp),
                            color = LocalSemanticColors.current.error)
                    }
                } else if (s.groups.isEmpty()) {
                    Box(Modifier.fillMaxSize().padding(pad)) {
                        Text("Nothing here yet.", Modifier.padding(24.dp),
                            color = LocalSemanticColors.current.muted)
                    }
                } else {
                    LazyColumn(Modifier.fillMaxSize().padding(pad)) {
                        s.groups.forEach { group ->
                            item(key = "hdr-${group.phase.name}") {
                                Text(
                                    "${group.phase.label}   ${group.items.size}",
                                    style = MonoStyle,
                                    fontWeight = FontWeight.Bold,
                                    modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 4.dp),
                                )
                            }
                            items(group.items, key = { it.id }) { wi -> FarmCard(wi) { onOpen(wi) } }
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FarmCard(item: WorkItemSummary, onClick: () -> Unit) {
    ListItem(
        leadingContent = { Icon(kindIcon(item.kind), contentDescription = item.kind) },
        headlineContent = { Text(item.title) },
        supportingContent = { Text(subLine(item), style = MonoStyle) },
        trailingContent = { AttentionBadges(item.attention) },
        modifier = Modifier.clickable { onClick() },
    )
}

@Composable
private fun AttentionBadges(a: Attention) {
    val c = LocalSemanticColors.current
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        if (a.needsApproval) Badge("approve", c.approval)
        if (a.needsDecision) Badge("decide", c.question)
        if (a.blocked) Badge("blocked ${a.blockedTasks}/${a.totalTasks}", c.blocker)
        if (a.needsReview) Badge("review", c.question)
    }
}

@Composable
private fun Badge(text: String, color: Color) {
    Surface(color = color.copy(alpha = 0.15f), shape = RoundedCornerShape(6.dp)) {
        Text(text, style = MonoStyle, color = color,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp))
    }
}

private fun kindIcon(kind: String): ImageVector = when (kind) {
    "bug" -> Icons.Filled.BugReport
    "chore" -> Icons.Filled.Build
    "question" -> Icons.AutoMirrored.Filled.HelpOutline
    else -> Icons.Filled.Description // feature
}

private fun subLine(item: WorkItemSummary): String = when {
    item.attention.totalTasks > 0 ->
        "${item.attention.totalTasks} task(s)" +
            (if (item.attention.blockedTasks > 0) " · ${item.attention.blockedTasks} blocked" else "")
    item.specId != null -> "spec"
    item.threadIds.isNotEmpty() -> "conversation"
    else -> item.kind
}
```

- [ ] **Step 2: Verify it builds**

Run: `./gradlew -p android :app:assembleDebug`
Expected: BUILD SUCCESSFUL. (Confirm the `SemanticColors` fields used — `approval`, `question`, `blocker`, `error`, `muted` — match `ui/theme/Color.kt`; adjust names if the theme differs.)

- [ ] **Step 3: Commit**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/farm/FarmScreen.kt
git commit -m "feat(farm): FarmScreen — phase sections, kind icons, attention badges"
mship journal "FarmScreen compose UI (builds)" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: Wire the farm route + repoint the workspace drill-in

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApp.kt`

- [ ] **Step 1: Add the `farm/{connectionId}` destination**

In the `NavHost`, mirror the existing `workspace/{connectionId}` composable (it already imports `viewModel`, `navArgument`, `NavType`, `runBlockingSnapshot`, `connRepo`, `api`, `nav`). Add:

```kotlin
composable(
    route = "farm/{connectionId}",
    arguments = listOf(navArgument("connectionId") { type = NavType.StringType }),
) { entry ->
    val connectionId = entry.arguments?.getString("connectionId").orEmpty()
    val conn = remember(connectionId) {
        runBlockingSnapshot(connRepo).firstOrNull { it.id == connectionId }
    }
    if (conn == null) {
        Box(Modifier.fillMaxSize()) { Text("Connection removed.") }
    } else {
        val vm = viewModel(key = "farm-$connectionId") { FarmViewModel(api, conn) }
        FarmScreen(
            vm = vm,
            workspaceName = conn.workspaceName.ifBlank { conn.baseUrl },
            onOpen = { item ->
                when {
                    item.specId != null -> nav.navigate("specDetail/$connectionId/${item.specId}")
                    item.taskSlugs.isNotEmpty() -> nav.navigate("taskDetail/$connectionId/${item.taskSlugs.first()}")
                    item.threadIds.isNotEmpty() -> nav.navigate("thread/$connectionId/${item.threadIds.first()}")
                }
            },
            onBack = { nav.popBackStack() },
        )
    }
}
```

Add imports at the top of `GroundControlApp.kt`:
```kotlin
import com.atomikpanda.groundcontrol.ui.farm.FarmScreen
import com.atomikpanda.groundcontrol.ui.farm.FarmViewModel
```

- [ ] **Step 2: Repoint the Home drill-in to the farm**

Find the Home composable's `onBrowseWorkspace` wiring (currently `nav.navigate("workspace/$connId")`) and change the target to the farm route:

```kotlin
onBrowseWorkspace = { connId -> nav.navigate("farm/$connId") },
```

(Leave the `workspace/{connectionId}` route in place — it's now reachable only if something else links it; retiring it is a later cleanup, out of scope.)

- [ ] **Step 3: Verify it builds**

Run: `./gradlew -p android :app:assembleDebug`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: Full evidence run**

Run: `mship test`
Expected: green (all new JVM unit tests + the existing suite).

- [ ] **Step 5: Visual verification**

Run: `mship capture --platform android` against the running app; drill into a workspace from Home and confirm the farm renders items grouped by phase with attention badges. (Requires a workspace whose `mship serve` exposes `/items` — restart serve if it predates MOS-196; run `mship item migrate` there to populate items.)

- [ ] **Step 6: Commit**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApp.kt
git commit -m "feat(farm): wire farm/{connectionId} route; workspace drill-in opens the farm"
mship journal "farm route + drill-in repoint (builds, mship test green)" --action committed
```
<!-- /mship:task -->

---

## Self-review checklist (run before dispatch)

- **Spec coverage:** vertical phase-grouped list (Task 3+5), per-item cards with kind icon + sub-line + attention badge (Task 5), reached via workspace drill-in (Task 6), consumes `GET /items` (Task 2), Home stays the cross-workspace skim (unchanged — Task 6 only repoints the drill-in). Covered.
- **Non-goals honored:** no horizontal kanban; no cross-workspace aggregation (that's Home). The farm is single-connection.
- **Types consistent:** `WorkItemSummary`/`Attention` field names + `@SerialName`s match the server's `WorkItemSummary`/`Attention` from MOS-196 (`spec_id`, `task_slugs`, `thread_ids`, `attention.{needs_approval,needs_decision,blocked,needs_review,blocked_tasks,total_tasks}`, `updated_at`). `groupByPhase` → `List<PhaseGroup>` used by `FarmUiState.Content` and `FarmScreen`. `FarmViewModel(api, conn, testScope?)` matches `WorkspaceViewModel`.

## Notes / risks

- **Theme field names:** `FarmScreen`/badges assume `SemanticColors` exposes `approval`/`question`/`blocker`/`error`/`muted`. Confirm against `ui/theme/Color.kt` (the Explore map lists these) and adjust if a role name differs.
- **Tap target is interim:** cards route to the existing spec/task/thread detail screens; when the per-phase cockpits land (MOS-198/202/199/200), `onOpen` becomes "open the item's cockpit."
- **Serve must expose `/items`:** a workspace running an `mship serve` from before MOS-196 needs a restart (the serve-restart gotcha); `mship item migrate` populates items from existing specs/tasks.
