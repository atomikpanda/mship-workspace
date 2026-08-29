# Reactive Navigation Connections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every connection-dependent Android surface one lifecycle-stable Loading/Ready/Error source that updates while the surface remains open.

## Assumptions checked

- repo topology — covered: only the `ground-control` Android member changes on PR #74.
- credential locus — covered: credentials remain in existing `WorkspaceConnection` DataStore records; the state store exposes records without copying secrets elsewhere.
- execution locus — covered: DataStore collection runs in an application-owned coroutine scope; Compose and ViewModels collect immutable state.
- state durability — covered: DataStore remains authoritative; Loading/Ready/Error are process-memory projections and require no persisted schema change.
- review surface — covered: PR #74 with state-store, ViewModel, navigation, and cold-start JVM tests.
- agent stream — covered: one worker executes the plan tasks in order and journals each independently reviewed commit.
- dispatched model — covered: use the task's configured Mothership implementation model.

**Architecture:** `GroundControlApplication` owns a `ConnectionStateStore` backed by `ConnectionsRepository.connections`. The store exposes `StateFlow<ConnectionState>` with explicit Loading, Ready (including empty), and Error states; Home, Queue, Tasks, and Capture/New Thread react to it directly rather than reading a captured provider or blocking DataStore.

**Tech Stack:** Kotlin, Android Application, DataStore, StateFlow, coroutines, Jetpack Compose lifecycle collection, Navigation Compose, JUnit 4, kotlinx-coroutines-test.

**Spec:** `ground-control-reactive-connections` — `specs/2026-08-21-ground-control-reactive-connections.md`

**Command root:** Run every command from the assigned `reactive-navigation-connections/ground-control` worktree root. Gradle commands use `(cd android && ./gradlew …)`.

## Global Constraints

- Ground Control Android only; no server, protocol, DataStore key, or connection-record schema changes.
- Loading is only the period before the first successful emission; `Ready(emptyList())` is not Loading.
- DataStore failures become visible Error state with an existing Settings navigation recovery path.
- Open surfaces must react to add, remove, and replace events without activity or process restart.
- No `runBlocking`, `Flow.first()`, or composition-captured connection provider on the named UI paths.

---

<!-- mship:task id=1 acs=ac1,ac2,ac3,ac8,ac10,ac11,ac12,ac14 -->
### Task 1: Application-owned connection state store

**Files:**
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/ConnectionStateStore.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApplication.kt:1-11`
- Create: `android/app/src/test/java/com/atomikpanda/groundcontrol/ConnectionStateStoreTest.kt`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/ConnectionsCodecTest.kt`

**Interfaces:**
- Consumes: `Flow<List<WorkspaceConnection>>` from `ConnectionsRepository.connections`.
- Produces: `ConnectionState.Loading`, `ConnectionState.Ready(connections)`, `ConnectionState.Error(cause)`, a small `ConnectionStateSource` interface exposing `state`/`retry()`, `ConnectionStateStore` implementing it, and an injectable application owner seam.

- [ ] **Step 1: Write state transition tests**

```kotlin
@Test fun empty_first_emission_is_ready_not_loading() = runTest {
    val source = MutableSharedFlow<List<WorkspaceConnection>>()
    val store = ConnectionStateStore(source, backgroundScope)
    runCurrent()
    assertEquals(ConnectionState.Loading, store.state.value)
    source.emit(emptyList())
    runCurrent()
    assertEquals(ConnectionState.Ready(emptyList()), store.state.value)
}

@Test fun ready_error_retry_ready_never_reenters_initial_loading() = runTest {
    val attempts = Channel<Flow<List<WorkspaceConnection>>>(Channel.UNLIMITED)
    val store = ConnectionStateStore(source = { attempts.receive() }, scope = backgroundScope)
    attempts.send(flow {
        emit(listOf(connectionA))
        throw IOException("disk")
    })
    runCurrent()
    assertTrue(store.state.value is ConnectionState.Error)
    store.retry()
    assertTrue(store.state.value is ConnectionState.Error)
    attempts.send(flowOf(listOf(connectionB)))
    runCurrent()
    assertEquals(ConnectionState.Ready(listOf(connectionB)), store.state.value)
}

@Test fun initial_error_retry_keeps_error_visible_until_ready() = runTest {
    val attempts = Channel<Flow<List<WorkspaceConnection>>>(Channel.UNLIMITED)
    val store = ConnectionStateStore(source = { attempts.receive() }, scope = backgroundScope)
    attempts.send(flow { throw IOException("disk") })
    runCurrent()
    val error = store.state.value
    assertTrue(error is ConnectionState.Error)
    store.retry()
    assertSame(error, store.state.value)
    attempts.send(flowOf(listOf(connectionA)))
    runCurrent()
    assertEquals(ConnectionState.Ready(listOf(connectionA)), store.state.value)
}

@Test fun frozen_encoded_connection_is_ready_without_rewrite() = runTest {
    val encoded = """[{"id":"legacy","baseUrl":"https://host/workspaces/ws","token":"tok"}]"""
    var persisted = encoded
    val decoded = ConnectionsCodec.decode(persisted)
    val store = ConnectionStateStore(flowOf(decoded), backgroundScope)
    runCurrent()
    assertEquals(ConnectionState.Ready(decoded), store.state.value)
    assertEquals("legacy", decoded.single().id)
    assertEquals(encoded, persisted)
}

@Test fun retry_is_single_flight_and_recovers_after_source_failure() = runTest {
    val attempts = Channel<Flow<List<WorkspaceConnection>>>(Channel.UNLIMITED)
    val store = ConnectionStateStore(source = { attempts.receive() }, scope = backgroundScope)
    attempts.send(flow { throw IOException("disk") })
    runCurrent()
    store.retry()
    store.retry()
    attempts.send(flowOf(listOf(connectionA)))
    runCurrent()
    assertEquals(ConnectionState.Ready(listOf(connectionA)), store.state.value)
    assertTrue(attempts.isEmpty)
}
```

- [ ] **Step 2: Run store tests and verify RED**

```bash
(cd android && ./gradlew :app:testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.ConnectionStateStoreTest' --tests 'com.atomikpanda.groundcontrol.ConnectionsCodecTest')
```

Expected: FAIL because the state model and store do not exist.

- [ ] **Step 3: Implement the application-owned store**

```kotlin
sealed interface ConnectionState {
    data object Loading : ConnectionState
    data class Ready(val connections: List<WorkspaceConnection>) : ConnectionState
    data class Error(val cause: Throwable) : ConnectionState
}

interface ConnectionStateSource {
    val state: StateFlow<ConnectionState>
    fun retry()
}

class ConnectionStateStore(
    private val source: () -> Flow<List<WorkspaceConnection>>,
    private val scope: CoroutineScope,
) : ConnectionStateSource {
    constructor(source: Flow<List<WorkspaceConnection>>, scope: CoroutineScope) : this({ source }, scope)

    private val _state = MutableStateFlow<ConnectionState>(ConnectionState.Loading)
    override val state: StateFlow<ConnectionState> = _state.asStateFlow()
    private var observation: Job? = null

    init { observe() }

    override fun retry() {
        if (observation?.isActive == true) return
        observe() // Preserve the current Error until a Ready emission replaces it.
    }

    private fun observe() {
        observation = scope.launch {
            try {
                source().collect {
                    _state.value = ConnectionState.Ready(it)
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                _state.value = ConnectionState.Error(error)
            }
        }
    }
}
```

Give `GroundControlApplication` a `SupervisorJob` application scope and a lazy store built from `ConnectionsRepository(this).connections`. Add an internal constructor/factory seam that accepts the source and scope for deterministic JVM ownership tests; production still constructs exactly one store. Cancel the scope only from that test seam; normal Android application lifetime owns it. `observe()` clears/replaces the completed observation job under a small lock, `retry()` starts at most one collector, and retry after an Error keeps Error visible until the next Ready value rather than flashing initial Loading.

- [ ] **Step 4: Run store tests and verify GREEN**

Run the command from Step 2.

Expected: PASS for Loading→Ready(non-empty), Loading→Ready(empty), Loading→Error, and Error→Ready recovery.

- [ ] **Step 5: Commit the state owner**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/data/ConnectionStateStore.kt android/app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApplication.kt android/app/src/test/java/com/atomikpanda/groundcontrol/ConnectionStateStoreTest.kt android/app/src/test/java/com/atomikpanda/groundcontrol/ConnectionsCodecTest.kt
git commit -m "feat: own connection state at application scope"
mship journal "added application-scoped Loading/Ready/Error connection state with retry; focused tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 acs=ac2,ac3,ac4,ac5,ac6,ac7,ac11,ac14 -->
### Task 2: Make Home, Queue, and Tasks reactive

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/home/HomeViewModel.kt:38-90`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/queue/QueueViewModel.kt:69-150,478-480`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/tasks/TasksViewModel.kt:34-70`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/home/HomeScreen.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/queue/QueueScreen.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/tasks/TasksScreen.kt`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/HomeViewModelTest.kt`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/QueueViewModelTest.kt`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/TasksViewModelTest.kt`
- Modify: route-scoped ViewModel construction in `android/app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApp.kt`

**Interfaces:**
- Consumes: `StateFlow<ConnectionState>` from Task 1.
- Produces: each ViewModel's existing public UI state, refreshed from every new `Ready` list and invalidated when its selected/active connection disappears.

- [ ] **Step 1: Write live add/remove/replace tests for each ViewModel**

```kotlin
@Test fun ready_replacement_reloads_open_tasks_surface() = runTest {
    val connections = MutableStateFlow<ConnectionState>(ConnectionState.Ready(listOf(connectionA)))
    val vm = TasksViewModel(repository, connections, backgroundScope)
    runCurrent()
    connections.value = ConnectionState.Ready(listOf(connectionB))
    runCurrent()
    assertEquals(listOf(connectionB.id), repository.requestedConnectionSets.last().map { it.id })
    assertFalse((vm.state.value as TasksUiState.Content).sections.any { it.connectionId == connectionA.id })
}
```

Repeat the same observable contract for Home and Queue. Cover Loading, source Error, `Ready(emptyList())`, removal of the active connection, and a replacement carrying changed routing/auth fields under the same ID. In Queue, add removal/replacement cancellation/revalidation barriers for every mutation entry that actually calls the repository: approve, reject, free-text answer, option answer, `setItemVerdict`, retry, and refresh; release each late completion and assert it neither restores/updates the retired card nor publishes success for the retired connection. Give `setItemVerdict` its own gated same-ID replacement and removal cases because it calls `QueueRepository.setCriterionVerdict` asynchronously. For synchronous `skip`/`defer`, emit removal/replacement immediately afterward and assert the retired card is pruned with no repository barrier or invented asynchronous work.

- [ ] **Step 2: Run the three ViewModel test classes and verify RED**

```bash
(cd android && ./gradlew :app:testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.HomeViewModelTest' --tests 'com.atomikpanda.groundcontrol.QueueViewModelTest' --tests 'com.atomikpanda.groundcontrol.TasksViewModelTest')
```

Expected: FAIL because each ViewModel only reads `connectionsProvider()` when manually refreshed.

- [ ] **Step 3: Replace provider constructors with StateFlow collection**

```kotlin
class TasksViewModel(
    private val repo: TasksRepository,
    private val connectionState: StateFlow<ConnectionState>,
    private val testScope: CoroutineScope? = null,
) : ViewModel() {
    private var refreshJob: Job? = null

    init {
        scope().launch {
            connectionState.collectLatest { state ->
                refreshJob?.cancelAndJoin()
                when (state) {
                    ConnectionState.Loading -> _state.value = TasksUiState.Loading
                    is ConnectionState.Error ->
                        _state.value = TasksUiState.ConnectionsUnavailable(state.cause)
                    is ConnectionState.Ready -> refreshJob = reload(state.connections)
                }
            }
        }
    }
}
```

Apply the same ownership pattern to Home and Queue. Preserve their existing repository requests, selection rules, and public UI-state types: add explicit `ConnectionsUnavailable(cause)` variants so source failure is never relabeled as Loading. Update `HomeScreen`, `QueueScreen`, and `TasksScreen` exhaustive `when` expressions to render a stable “Connections unavailable” error body for that variant; the enclosing navigation gate owns retry/Settings actions in production. Every action lookup consults the latest `Ready.connections`; remove the `connectionsProvider` field and captured lambdas. In Queue, track every connection-dependent mutation job by card key, cancel and `join` jobs for removed or replaced connection identities before pruning `connById` and visible cards, and capture a monotonically increasing connection snapshot revision. Immediately before each repository call and again before publishing completion, require the current revision and exact full `WorkspaceConnection`; retry callbacks perform the same lookup. Loading/Error cancels connection-dependent jobs before changing UI state.

- [ ] **Step 4: Run the three ViewModel test classes and verify GREEN**

Run the command from Step 2.

Expected: PASS for add/remove/replace, empty, source Error, active-selection removal, every mutation cancellation barrier, and unchanged existing refresh contracts.

- [ ] **Step 5: Commit reactive consumers**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApp.kt android/app/src/main/java/com/atomikpanda/groundcontrol/ui/home/HomeViewModel.kt android/app/src/main/java/com/atomikpanda/groundcontrol/ui/home/HomeScreen.kt android/app/src/main/java/com/atomikpanda/groundcontrol/ui/queue/QueueViewModel.kt android/app/src/main/java/com/atomikpanda/groundcontrol/ui/queue/QueueScreen.kt android/app/src/main/java/com/atomikpanda/groundcontrol/ui/tasks/TasksViewModel.kt android/app/src/main/java/com/atomikpanda/groundcontrol/ui/tasks/TasksScreen.kt android/app/src/test/java/com/atomikpanda/groundcontrol/HomeViewModelTest.kt android/app/src/test/java/com/atomikpanda/groundcontrol/QueueViewModelTest.kt android/app/src/test/java/com/atomikpanda/groundcontrol/TasksViewModelTest.kt
git commit -m "refactor: react to connection state in primary surfaces"
mship journal "migrated Home Queue Tasks from captured providers to live connection state; focused tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 acs=ac1,ac2,ac3,ac4,ac5,ac6,ac7,ac8,ac9,ac10,ac11,ac13,ac14 -->
### Task 3: Wire navigation and Capture/New Thread to shared state

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApp.kt:149-728` (all connection-bound route dispatches and route-scoped ViewModel construction)
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/NewThreadViewModel.kt:25-115`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/MessagesViewModel.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/projects/ProjectsViewModel.kt`
- Modify: `android/app/build.gradle.kts`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/CanonicalConnectionRoutesTest.kt`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/NewThreadViewModelTest.kt`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/MessagesViewModelTest.kt`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/ProjectsViewModelTest.kt`
- Create: `android/app/src/androidTest/java/com/atomikpanda/groundcontrol/GroundControlConnectionStateUiTest.kt`

**Interfaces:**
- Consumes: `ConnectionStateSource` from Task 1 and a `GroundControlDependencies` bundle whose production factory owns the existing repositories/API while tests provide a MockEngine-backed graph.
- Produces: lifecycle-aware UI collection, Settings recovery navigation, deterministic UI dependency injection, and current connection selection for Capture/New Thread.

- [ ] **Step 1: Write cold-start, recovery, and open-screen mutation tests**

```kotlin
@Test fun capture_waits_for_first_snapshot_then_tracks_replacement() = runTest {
    val state = MutableStateFlow<ConnectionState>(ConnectionState.Loading)
    val vm = NewThreadViewModel(repository, state, backgroundScope)
    assertTrue(vm.state.value.isLoading)
    state.value = ConnectionState.Ready(listOf(connectionA))
    runCurrent()
    assertEquals(connectionA.id, vm.state.value.selectedId)
    state.value = ConnectionState.Ready(listOf(connectionB))
    runCurrent()
    assertEquals(connectionB.id, vm.state.value.selectedId)
}

@Test fun error_to_ready_rebinds_open_destination_without_recreating_nav_graph() {
    val source = FakeConnectionStateSource(ConnectionState.Error(IOException("disk")))
    val dependencies = deterministicGroundControlDependencies()
    composeRule.setContent {
        GroundControlContent(connectionStateSource = source, dependencies = dependencies)
    }
    composeRule.onNodeWithText("Open Settings").performClick()
    composeRule.onNodeWithText("Relay account").assertIsDisplayed()
    composeRule.activityRule.scenario.onActivity {
        it.onBackPressedDispatcher.onBackPressed()
    }
    source.stateFlow.value = ConnectionState.Ready(listOf(connectionA))
    composeRule.waitUntil { composeRule.onAllNodesWithText(connectionA.workspaceName).fetchSemanticsNodes().isNotEmpty() }
}
```

Also test selected-connection removal and successful DataStore-empty state in `NewThreadViewModelTest`. Add a gated create test using `SpecApi(HttpClient(MockEngine))`: start `createThread` against A and suspend its response; replace A with the same ID but changed route/token (and separately remove A); emit the new Ready state, wait until cancellation/revalidation completes, then release the old response and assert it never publishes `Created`. The replacement case issues a later request whose captured URL/Authorization come only from the full new connection. Add `MessagesViewModelTest` and `ProjectsViewModelTest` cases that hold those destinations open across `Ready(A) → Error → Ready(B)`: Error is visible through the route gate, no A request/state can overwrite it, and recovery uses only B without recreating the NavHost. `GroundControlConnectionStateUiTest` uses a `FakeConnectionStateSource` implementing the production `ConnectionStateSource` interface and a `GroundControlDependencies` graph backed by deterministic `MockEngine`, temporary Preferences DataStore, and test coroutine scope. It launches Home, Queue, Tasks, Capture, New Thread, Threads/Messages, Projects, spec detail, task detail, and workspace detail in turn; while each is open, emit A→B and assert visible data/repository captures switch to B without route recreation. For every connection-dependent route, emit `ConnectionState.Error`, assert the shared error content and working Retry/Open Settings controls, then recover to Ready. Assert SETTINGS remains reachable during Error and no replacement `NavHost` is installed.

- [ ] **Step 2: Run navigation and New Thread tests and verify RED**

```bash
(cd android && ./gradlew :app:testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.CanonicalConnectionRoutesTest' --tests 'com.atomikpanda.groundcontrol.NewThreadViewModelTest' --tests 'com.atomikpanda.groundcontrol.MessagesViewModelTest' --tests 'com.atomikpanda.groundcontrol.ProjectsViewModelTest')
(cd android && ./gradlew :app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.atomikpanda.groundcontrol.GroundControlConnectionStateUiTest)
```

Expected: FAIL because `GroundControlApp` still owns an activity ViewModel snapshot and New Thread consumes only `StateFlow<List<WorkspaceConnection>>`.

- [ ] **Step 3: Remove the activity snapshot bridge**

Keep one `NavHost` installed for Loading, Error, and Ready so Settings is reachable when the first DataStore read fails and the same graph observes recovery. Split a production Activity wrapper from `GroundControlContent(connectionStateSource, dependencies)`. `GroundControlDependencies` is a boring bundle/factory for the existing `ConnectionsRepository`, `HostsRepository`, `SpecApi`, Home/Queue/detail/tasks/threads/projects repositories, notifications setting, and coach-mark store; production builds it exactly as today, while instrumentation supplies MockEngine/test-store instances. Collect `connectionStateSource.state` once beside the NavHost. Wrap every connection-dependent destination: Home, Queue, Tasks, Capture, New Thread, Threads/Messages, Projects, farm, console, review, done, item, thread detail, spec detail, task detail, and workspace detail. Each goes through the shared `ConnectionStateGate`; Settings is the sole ungated destination. Migrate both `MessagesViewModel` and `ProjectsViewModel` from raw/provider-backed connection lists to the same `StateFlow<ConnectionState>`; they stop work on Loading/Error, expose no stale A content through the route, and restart from the next Ready snapshot.

```kotlin
@Composable
internal fun ConnectionStateGate(
    state: ConnectionState,
    onRetry: () -> Unit,
    onOpenSettings: () -> Unit,
    ready: @Composable (List<WorkspaceConnection>) -> Unit,
) {
    when (state) {
        ConnectionState.Loading -> CircularProgressIndicator()
        is ConnectionState.Error -> ConnectionErrorContent(
            onRetry = onRetry,
            onOpenSettings = onOpenSettings,
        )
        is ConnectionState.Ready -> ready(state.connections)
    }
}

val connectionState by store.state.collectAsStateWithLifecycle()
NavHost(nav, startDestination = Section.HOME.route) {
    composable(Section.HOME.route) {
        ConnectionStateGate(connectionState, connectionStateSource::retry, openSettings) {
            HomeScreen(
                viewModel(factory = HomeViewModel.factory(dependencies.homeRepo, connectionStateSource.state)),
                nav,
            )
        }
    }
    composable(Section.SETTINGS.route) { SettingsScreen(/* existing arguments */) }
}
```

Add `androidTestImplementation("androidx.compose.ui:ui-test-junit4")`, `androidTestImplementation("androidx.test:core-ktx:1.6.1")`, `androidTestImplementation("androidx.test.ext:junit-ktx:1.2.1")`, `androidTestImplementation("io.ktor:ktor-client-mock:2.3.12")`, and `debugImplementation("androidx.compose.ui:ui-test-manifest")`. Keep the Ktor mock version identical to the existing `testImplementation`. Collect the application source with `collectAsStateWithLifecycle()` once beside the NavHost and pass the same state flow to all named ViewModels. Delete `ConnectionSnapshotViewModel`, `connectionSnapshotProvider`, every provider-based constructor callsite, and route keys whose only purpose was forcing a stale provider-backed ViewModel to restart. Reactive ViewModels remain route-scoped but own no captured credential snapshot; instrumentation asserts every already-open connection-bound destination—including Threads/Messages and Projects—renders shared Error recovery and updates A→B without route recreation. A separate `ActivityScenario.recreate()` case obtains the real `GroundControlApplication` before and after recreation, asserts `ConnectionStateStore` referential identity, writes a replacement through `ConnectionsRepository`, and asserts the recreated activity renders it while the same store survives.

Adapt `NewThreadViewModel` to `StateFlow<ConnectionState>` and preserve the current selection only while its complete connection identity exists in the latest Ready list; otherwise cancel and `join` any in-flight create request before choosing the first valid connection or showing empty configuration. Loading/Error expose distinct UI states and cannot be overwritten by late completion. Before POST and before publishing success, revalidate the selected connection against the latest Ready snapshot and revision.

- [ ] **Step 4: Run navigation and New Thread tests and verify GREEN**

Run the command from Step 2.

Expected: PASS for Loading, empty Ready, Error→Settings→Ready recovery, add/remove/same-ID replacement without route recreation, and selected-connection mutation cancellation.

- [ ] **Step 5: Commit navigation wiring**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApp.kt android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/NewThreadViewModel.kt android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/MessagesViewModel.kt android/app/src/main/java/com/atomikpanda/groundcontrol/ui/projects/ProjectsViewModel.kt android/app/build.gradle.kts android/app/src/test/java/com/atomikpanda/groundcontrol/CanonicalConnectionRoutesTest.kt android/app/src/test/java/com/atomikpanda/groundcontrol/NewThreadViewModelTest.kt android/app/src/test/java/com/atomikpanda/groundcontrol/MessagesViewModelTest.kt android/app/src/test/java/com/atomikpanda/groundcontrol/ProjectsViewModelTest.kt android/app/src/androidTest/java/com/atomikpanda/groundcontrol/GroundControlConnectionStateUiTest.kt
git commit -m "feat: drive navigation from shared connection state"
mship journal "wired navigation and Capture/New Thread to application connection state with Settings recovery; focused tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 acs=ac1,ac2,ac3,ac4,ac5,ac6,ac7,ac8,ac9,ac10,ac11,ac12,ac13,ac14 -->
### Task 4: Verify lifecycle and compatibility behavior

**Files:**
- Modify only if a failing observable contract requires it: files listed in Tasks 1-3.

**Interfaces:**
- Consumes: shared state owner and all named consumers.
- Produces: PR #74 task-scoped evidence.

- [ ] **Step 1: Run all affected JVM tests**

```bash
(cd android && ./gradlew :app:testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.ConnectionStateStoreTest' --tests 'com.atomikpanda.groundcontrol.ConnectionsCodecTest' --tests 'com.atomikpanda.groundcontrol.HomeViewModelTest' --tests 'com.atomikpanda.groundcontrol.QueueViewModelTest' --tests 'com.atomikpanda.groundcontrol.TasksViewModelTest' --tests 'com.atomikpanda.groundcontrol.CanonicalConnectionRoutesTest' --tests 'com.atomikpanda.groundcontrol.NewThreadViewModelTest' --tests 'com.atomikpanda.groundcontrol.MessagesViewModelTest' --tests 'com.atomikpanda.groundcontrol.ProjectsViewModelTest')
```

Expected: BUILD SUCCESSFUL.

- [ ] **Step 2: Compile the Android app**

```bash
(cd android && ./gradlew :app:compileDebugKotlin)
```

Expected: BUILD SUCCESSFUL with no provider-constructor callsites left.

- [ ] **Step 3: Run lifecycle/navigation instrumentation**

```bash
(cd android && ./gradlew :app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.atomikpanda.groundcontrol.GroundControlConnectionStateUiTest)
```

Expected: Settings is reachable from an initial Error and the same installed graph renders Ready after retry; open Home/Capture surfaces update A→B without route recreation; the application store survives activity recreation; and the recreated UI renders the latest persisted Ready snapshot. If no emulator/device is attached, build with `(cd android && ./gradlew :app:assembleDebugAndroidTest)` and record the runtime blocker without claiming execution.


- [ ] **Step 4: Run Mothership task verification**

```bash
mship test --task reactive-navigation-connections
mship journal "reactive connection redesign complete: application state owner, live consumers, and Settings recovery; task suite passing" --action verified
```

Expected: task test passes and records evidence.
<!-- /mship:task -->
