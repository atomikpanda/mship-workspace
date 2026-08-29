# Reply Notification Outbox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist every accepted notification reply as a versioned Room outbox item, claim it once, and reconcile delivery/render state safely across process death.

## Assumptions checked

- repo topology — covered: only Ground Control Android changes on PR #76.
- credential locus — covered: workspace credentials stay in DataStore; Room stores reply payload/context but no new credential copy.
- execution locus — covered: the receiver uses `goAsync` plus an IO coroutine for Room, WorkManager triggers execution, and Room transactions own claims/transitions.
- state durability — covered: Room becomes authoritative for accepted payload, notification generation, execution claim, delivery outcome, and render acknowledgement.
- review surface — covered: PR #76 with JVM lifecycle tests and Android Room migration/instrumentation tests.
- agent stream — covered: one task worker executes schema, enqueue, worker, rendering, and verification tasks in order.
- dispatched model — covered: use the task's configured Mothership implementation model.

**Architecture:** Replace WorkManager input-data authority with a Room outbox row containing exact bounded payload and complete execution/render context. Receiver persistence precedes enqueue; workers transactionally claim only current-generation work; success, safe pre-transmission failure, uncertain delivery, and render acknowledgement are durable states, and a reconciler re-enqueues eligible rows after restart.

**Tech Stack:** Kotlin, Room, WorkManager, BroadcastReceiver `goAsync`, Ktor, Android notifications, coroutines, JUnit 4, AndroidX test, Room migration testing.

**Spec:** `ground-control-reply-outbox` — `specs/2026-08-21-ground-control-reply-outbox.md`

**Command root:** Run every command from the assigned `reply-notification-lifecycle/ground-control` worktree root. Gradle commands use `(cd android && ./gradlew …)`.

## Global Constraints

- Ground Control Android only; no server-side idempotency or reply API change.
- Exact accepted text and decision context persist within existing bounds; no truncation or regeneration.
- Receiver main thread performs no Room I/O and does not wait for persistence or WorkManager.
- WorkManager is a trigger, never the authoritative queue.
- Any outcome that may have transmitted is terminal uncertain and never automatically retries.
- Stale notification generations never create executable work or POST.
- Existing supported Room versions migrate without destructive reset; unsafe legacy rows become terminal, never guessed executable.
- Reply payload and full decision context are not added to logs, work names, WorkManager data, notification IDs, or error strings.

---

<!-- mship:task id=1 acs=ac6,ac12,ac14,ac15,ac16,ac17,ac18,ac19,ac20 -->
### Task 1: Define the durable outbox schema and migrations

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/ReplyLifecycle.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NotifiedRoom.kt:19-246`
- Modify: `android/app/build.gradle.kts`
- Create: `android/app/src/androidTest/java/com/atomikpanda/groundcontrol/notify/NotifiedDatabaseMigrationTest.kt`
- Create: `android/app/schemas/com.atomikpanda.groundcontrol.notify.NotifiedDatabase/5.json`

**Interfaces:**
- Consumes: explicit legacy database fixtures for versions 1-4 and current notification version records.
- Produces: database version 5, complete `ReplyOutboxRecord`, migration-safe `ReplyActionTombstone`, a durable legacy-notification-reset marker, nullable opaque `capabilityKey` on notification versions, DAOs, and an internal `ALL_MIGRATIONS` list used by production and tests.

- [ ] **Step 1: Write migration and schema tests**

`NotifiedDatabaseMigrationTest` creates each historical database with `FrameworkSQLiteOpenHelperFactory` and explicit frozen DDL, sets its `user_version`, closes it, then opens the same file through `Room.databaseBuilder(..., NotifiedDatabase::class.java).addMigrations(*ALL_MIGRATIONS)` so Room performs and validates the complete path. The fixture creates `notified` in v1; adds `reply_actions(actionKey,state)` in v2; adds `reply_notification_versions(connId,threadId,sourceVersion,generation,active)` in v3; and adds `reply_actions.executionId` in v4.

```kotlin
@Test fun migration_4_5_tombstones_every_legacy_action_without_inventing_payload() {
    createLegacyDatabase(version = 4) { db ->
        db.execSQL("INSERT INTO reply_actions(actionKey,state,executionId) VALUES('done','DELIVERED','')")
        db.execSQL("INSERT INTO reply_actions(actionKey,state,executionId) VALUES('pending','READY','')")
        db.execSQL(
            "INSERT INTO reply_notification_versions(connId,threadId,sourceVersion,generation,active) " +
                "VALUES('c','t','source',7,1)",
        )
    }
    val room = openVersionFive()
    assertEquals("DELIVERED", room.replyActionTombstoneDao().get("done")!!.terminalReason)
    assertEquals("LEGACY_UNEXECUTABLE", room.replyActionTombstoneDao().get("pending")!!.terminalReason)
    assertNull(room.replyOutboxDao().get("done"))
    assertNull(room.replyOutboxDao().get("pending"))
    assertFalse(room.replyNotificationVersionDao().get("c", "t")!!.active)
    assertNull(room.replyNotificationVersionDao().get("c", "t")!!.capabilityKey)
    assertTrue(room.replyMigrationStateDao().get()!!.legacyNotificationResetRequired)
}
```

Add fresh-v5 creation and migration tests from versions 1, 2, 3, and 4. Seed every v4 `ReplyActionState`; assert all become tombstones, no incomplete outbox row exists, all legacy notification versions are inactive with no capability, and an upgrade—not a fresh v5 database—sets the durable global notification-reset marker. Map `DELIVERED`/`DELIVERED_PENDING_RENDER` to delivered tombstones, `UNCERTAIN`/`UNCERTAIN_PENDING_RENDER`/`IN_FLIGHT` to uncertain tombstones, and `READY`/`SAFE_FAILURE_PENDING_RENDER` to legacy-unexecutable tombstones. An old PendingIntent lacking a capability key and an old WorkRequest lacking the new opaque input key must both terminate without POST. Verify an unsupported nonempty database version outside 1-4 fails Room open rather than destructively resetting.

- [ ] **Step 2: Run migration tests and verify RED**

```bash
(cd android && ./gradlew :app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.atomikpanda.groundcontrol.notify.NotifiedDatabaseMigrationTest)
```

Expected: FAIL because database version 5 and `MIGRATION_4_5` do not exist.

- [ ] **Step 3: Replace claim-only rows with complete outbox records**

```kotlin
@Entity(tableName = "reply_outbox")
data class ReplyOutboxRecord(
    @PrimaryKey val actionKey: String,
    val connectionId: String,
    val threadId: String,
    val notificationVersion: String,
    val state: ReplyOutboxState,
    val executionId: String?,
    val claimedAtMillis: Long?,
    val renderVersion: String?,
    val renderCapabilityKey: String?,
    val replyText: String,
    val inputKind: ReplyInputKind,
    val subject: String,
    val workspace: String,
    val baseUrl: String,
    val decisionJson: String?,
    val retryAttempt: Int,
    val createdAtMillis: Long,
)

enum class ReplyInputKind { FREE_TEXT, OPTION }

@Entity(tableName = "reply_action_tombstones")
data class ReplyActionTombstone(
    @PrimaryKey val actionKey: String,
    val terminalReason: String,
)

@Entity(tableName = "reply_migration_state")
data class ReplyMigrationState(
    @PrimaryKey val singletonId: Int = 0,
    val legacyNotificationResetRequired: Boolean,
)

enum class ReplyOutboxState {
    READY, WAITING_FOR_CONNECTION, IN_FLIGHT,
    SAFE_FAILURE_PENDING_RENDER, SAFE_FAILURE,
    DELIVERED_PENDING_RENDER, DELIVERED,
    UNCERTAIN_PENDING_RENDER, UNCERTAIN, STALE,
}
```

Create DAO compare-and-set updates with `WHERE actionKey = :key AND notificationVersion = :version AND state = :expected`, plus execution-owner checks for claim completions. Extend `ReplyNotificationVersionRecord` with nullable `capabilityKey`. Every fresh activation stores `UUID.randomUUID().toString()`; all actions rendered for that generation carry it and no action identity is recomputed from connection/thread aliases. `MIGRATION_4_5` creates the outbox, tombstone, and singleton migration-state tables; adds `capabilityKey TEXT` to `reply_notification_versions`; copies every legacy `actionKey` into `reply_action_tombstones` with the explicit terminal mapping above; sets every existing version inactive with null capability; sets `legacyNotificationResetRequired = true`; then drops `reply_actions`. It never invents payload or render context. Receiver submission requires exact version plus capability agreement and checks tombstones/outbox before insert. Expose all migrations through `internal val ALL_MIGRATIONS` and use that list in `NotifiedDatabase.get`. Enable Room schema export, configure `ksp { arg("room.schemaLocation", "$projectDir/schemas") }`, and check in generated v5 JSON. Add `androidTestImplementation("androidx.test:runner:1.6.2")`, `androidTestImplementation("androidx.test.ext:junit:1.2.1")`, `androidTestImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.1")`, and `androidTestImplementation("androidx.room:room-testing:2.6.1")`; historical validation uses explicit DDL fixtures because frozen heads did not export schemas.
- [ ] **Step 4: Run migration tests and verify GREEN**

Run the command from Step 2.

Expected: PASS for fresh schema and all supported migration paths.

- [ ] **Step 5: Commit schema and migrations**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/notify/ReplyLifecycle.kt android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NotifiedRoom.kt android/app/build.gradle.kts android/app/src/androidTest/java/com/atomikpanda/groundcontrol/notify/NotifiedDatabaseMigrationTest.kt android/app/schemas/com.atomikpanda.groundcontrol.notify.NotifiedDatabase/5.json
git commit -m "feat: persist notification replies in Room outbox"
mship journal "added reply outbox schema and non-destructive migrations with unsafe legacy terminalization; migration tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 acs=ac1,ac2,ac3,ac5,ac10,ac11,ac12,ac18,ac19 -->
### Task 2: Persist receiver actions before enqueue

**Files:**
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/ReplyOutbox.kt`
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NotificationRenderCoordinator.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/ReplyReceiver.kt:19-80`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/ReplyWorker.kt:83-end`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/AndroidNotifier.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApplication.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/WatchBackstopWorker.kt`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/ReplyWorkerIdentityTest.kt`
- Create: `android/app/src/androidTest/java/com/atomikpanda/groundcontrol/notify/ReplyReceiverOutboxTest.kt`

**Interfaces:**
- Consumes: receiver extras, `RemoteInput`, current notification version, and `ReplyOutboxDao` from Task 1.
- Produces: `ReplySubmission`, `ReplyOutbox.submit()`, opaque `ReplyWorker.enqueue(actionKey)`, and restart `reconcileEligible()`.

- [ ] **Step 1: Write receiver durability and main-thread tests**

Construct `ReplyReceiver` with a default `ReplyIntakeFactory` parameter so Android retains a no-argument constructor while the instrumentation test can inject a gated fake. The fake exposes `commitReached` and `enqueueReached` deferred signals; assertions await them rather than racing the `goAsync` coroutine.

```kotlin
@Test fun receiver_commits_exact_accepted_payload_before_requesting_work() = runTest {
    val events = Channel<String>(Channel.UNLIMITED)
    val intake = gatedIntake(events)
    ReplyReceiver { intake }.onReceive(context, validReplyIntent("  exact Δ reply  "))
    assertEquals("commit", events.receive())
    assertEquals("enqueue", events.receive())
    assertEquals("exact Δ reply", intake.persisted.single().replyText)
    assertEquals(ReplyInputKind.FREE_TEXT, intake.persisted.single().inputKind)
}

@Test fun gated_persistence_does_not_block_receiver_main_thread() {
    val intake = gatedBeforeCommit()
    InstrumentationRegistry.getInstrumentation().runOnMainSync {
        ReplyReceiver { intake }.onReceive(context, validReplyIntent("reply"))
    }
    assertFalse(intake.commitReached.isCompleted)
    intake.releaseCommit()
}
```

Add maximum-bound acceptance and one-byte-over-bound rejection using the frozen legacy WorkManager `Data` serialization policy, free-text-forbidden versus option-tap behavior, exact decision JSON/options/recommended/multi policy, missing/wrong capability rejection, duplicate/tombstoned key rejection, stale-version handling, and commit-before-enqueue process-death reconciliation. Add an upgraded-database test that renders no new notification, runs reconciliation, observes cancellation of every active notification on `NotificationChannels.NEEDS_YOU` before the reset marker clears, and proves a crash between those operations safely repeats cancellation; notifications on other channels and a fresh-v5 database remain untouched. For a stale/missing-capability action, assert a generation-aware cancellation callback runs; if a newer generation is current, its visible actionable notification remains unchanged.
- [ ] **Step 2: Run receiver/outbox tests and verify RED**

```bash
(cd android && ./gradlew :app:testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.ReplyWorkerIdentityTest')
(cd android && ./gradlew :app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.atomikpanda.groundcontrol.notify.ReplyReceiverOutboxTest)
```

Expected: receiver still passes full payload through WorkManager before a Room source exists.

- [ ] **Step 3: Implement exact submission persistence**

```kotlin
internal data class ReplySubmission(
    val actionKey: String, // opaque capability from the PendingIntent
    val connectionId: String,
    val threadId: String,
    val notificationVersion: String,
    val replyText: String,
    val inputKind: ReplyInputKind,
    val subject: String,
    val workspace: String,
    val baseUrl: String,
    val decision: Decision?,
    val retryAttempt: Int,
)

internal class ReplyOutbox(
    private val database: NotifiedDatabase,
    private val scheduler: ReplyWorkScheduler,
    private val currentConnections: suspend () -> List<WorkspaceConnection>,
    private val notificationActionHandler: suspend (ReplySubmission) -> Unit,
) {
    suspend fun submit(submission: ReplySubmission): Boolean {
        val canonical = currentConnections().findByConnectionId(submission.connectionId)
        if (canonical == null) {
            notificationActionHandler(submission) // cancel the stale visible action
            return false
        }
        val persisted = submission.copy(connectionId = canonical.id)
        val accepted = database.withTransaction {
            if (database.replyActionTombstoneDao().get(persisted.actionKey) != null) return@withTransaction false
            if (database.replyOutboxDao().get(persisted.actionKey) != null) return@withTransaction false
            val current = database.replyNotificationVersionDao()
                .get(persisted.connectionId, persisted.threadId)
            if (current == null || !current.active ||
                current.version != persisted.notificationVersion ||
                current.capabilityKey != persisted.actionKey
            ) return@withTransaction false
            database.replyOutboxDao().insert(persisted.toReadyRecord()) != -1L
        }
        notificationActionHandler(persisted)
        if (accepted) scheduler.enqueue(persisted.actionKey)
        return accepted
    }
}
```

Use `goAsync()` and an injected IO scope in `ReplyReceiver`; call `PendingResult.finish()` in `finally`. Add `EXTRA_REPLY_CAPABILITY`; AndroidNotifier obtains the current `ReplyCapability(version, opaqueKey)` from Room activation and places the same opaque key in every action for that notification. The PendingIntent may retain the event's alias connection ID for compatibility, so `ReplyOutbox.submit` resolves that ID through the latest full connection snapshot before the Room transaction, validates the version/capability under the canonical ID, and persists the canonical ID used for all later execution. Add a test with an action rendered for alias A whose version row is stored under canonical C: intake accepts exactly once, stores C, and later execution resolves C. An unknown/removed alias inserts and schedules nothing but still invokes `notificationActionHandler(submission)` once so its visible stale notification is canceled. Determine `ReplyInputKind` before choosing accepted text. Apply existing `replyText` trimming once, reject FREE_TEXT when the persisted decision forbids it, and never alter OPTION text. Extract the frozen WorkData construction into `ReplyPayloadPolicy`: it builds the old full input `Data` only to preserve its exact `Data.MAX_DATA_BYTES` acceptance boundary, then discards it; accepted content is persisted unchanged and new WorkData contains only `actionKey`. After the insert/rejection transaction, the receiver invokes `NotificationRenderCoordinator` with connection/thread/version and nullable capability; the coordinator takes the per-thread lock and cancels the visible notification only if no newer version now owns its shared ID. This handles accepted taps, duplicates, missing capability, and inactive legacy actions without deactivating a valid in-flight version. Before any normal render/cancel, the coordinator also takes a process-global render lock, checks the migration marker, enumerates `NotificationManager.activeNotifications`, cancels only entries whose channel is `NotificationChannels.NEEDS_YOU`, and only then clears the marker in Room; a crash repeats the safe targeted reset, while no new needs-you notification can race between reset and clear and foreground/other-channel notifications remain intact. `reconcileEligible(connections)` queries READY/render-pending rows plus inactive legacy version rows; it enqueues opaque outbox keys, performs generation-checked legacy cancellation, and moves WAITING_FOR_CONNECTION rows to READY only when `connections.findByConnectionId` resolves them. It also inspects WorkManager state for IN_FLIGHT rows: an active ENQUEUED/RUNNING request is left alone; a row whose unique work is absent or terminal is CASed to `UNCERTAIN_PENDING_RENDER`, never re-executed. Call reconciliation from `GroundControlApplication.onCreate` on an application scope that collects `ConnectionsRepository.connections`, and from one snapshot in `WatchBackstopWorker.doWork`; distinct connection snapshots trigger reconciliation, not a retry loop.
- [ ] **Step 4: Run receiver/outbox tests and verify GREEN**

Run both commands from Step 2.

Expected: exact payload survives Room round-trip, commit precedes enqueue, the receiver returns immediately, stale/oversized inputs create no executable row, and reconciliation recovers commit-before-enqueue death.
- [ ] **Step 5: Commit durable intake**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/notify/ReplyOutbox.kt android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NotificationRenderCoordinator.kt android/app/src/main/java/com/atomikpanda/groundcontrol/notify/ReplyReceiver.kt android/app/src/main/java/com/atomikpanda/groundcontrol/notify/ReplyWorker.kt android/app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApplication.kt android/app/src/main/java/com/atomikpanda/groundcontrol/notify/WatchBackstopWorker.kt android/app/src/test/java/com/atomikpanda/groundcontrol/ReplyWorkerIdentityTest.kt android/app/src/androidTest/java/com/atomikpanda/groundcontrol/notify/ReplyReceiverOutboxTest.kt
git commit -m "fix: persist notification reply before scheduling"
mship journal "receiver now persists exact bounded reply/context before opaque WorkManager enqueue without main-thread I/O; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 acs=ac4,ac6,ac8,ac9,ac10,ac11,ac12,ac18,ac19 -->
### Task 3: Claim once and classify delivery outcomes

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/MshipClient.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/ReplyLifecycle.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/ReplyOutbox.kt`
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/ReplyExecutor.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NotificationRenderCoordinator.kt`

**Interfaces:**
- Consumes: opaque action key, persisted outbox row, current notification version/capability, latest `ConnectionsRepository` snapshot resolved with `findByConnectionId`, existing `SpecApi.postMessage` behavior, and `NotificationRenderCoordinator.renderPending(actionKey)`.
- Produces: one execution-owner claim, explicit `WAITING_FOR_CONNECTION`, transactional completion, terminal `ReplyDeliveryOutcome` classification without automatic uncertain retry, and an immediate durable render attempt after every successful completion CAS.

- [ ] **Step 1: Write concurrent-claim and outcome tests**

Define `ReplyExecutor` as the testable state machine and leave `ReplyWorker` as an adapter that reads `actionKey`/`id`, constructs production dependencies, and returns `executor.execute(actionKey, id)`. `ReplyExecutor` receives `ReplyOutboxStore`, `ReplyVersionReader`, `suspend (ReplyOutboxRecord) -> Unit` post function, and `suspend (String) -> Unit` pending-render function; production binds the last function to `NotificationRenderCoordinator::renderPending`. The test fake uses a mutex-protected map, a claim barrier, an atomic POST counter, and recorded render keys.

```kotlin
@Test fun two_executors_racing_post_at_most_once() = runTest {
    store.insertReady(submission)
    awaitAll(async { executor("one").execute(key) }, async { executor("two").execute(key) })
    assertEquals(1, postCount.get())
    assertEquals(ReplyOutboxState.DELIVERED_PENDING_RENDER, store.get(key)!!.state)
}

@Test fun timeout_after_request_start_is_terminal_uncertain() = runTest {
    postFailure = SocketTimeoutException("after write")
    assertEquals(Result.success(), executor("one").execute(key))
    assertEquals(ReplyOutboxState.UNCERTAIN_PENDING_RENDER, store.get(key)!!.state)
    executor("two").execute(key)
    assertEquals(1, postCount.get())
}
```

Add safe pre-transmission unresolved-address/connect-timeout and HTTP 4xx rejection tests through a real `HttpClient` configured with `mshipDefaults`, same-execution restart from IN_FLIGHT becoming terminal uncertain, different-execution contention performing no transition/POST, startup/backstop detection of abandoned IN_FLIGHT work becoming uncertain without POST, live RUNNING work remaining untouched, unresolved connection moving to WAITING without retry, connection-resolution reconciliation returning it to READY exactly once, alias-to-canonical resolution, exact trimmed free text, exact option value/decision policy POST, and stale-version/capability no-POST tests. For DELIVERED, SAFE_FAILURE, and UNCERTAIN, assert a successful completion CAS immediately invokes `renderPending(actionKey)` once. If the renderer throws, assert the executor never retries the POST and leaves the row in its durable `*_PENDING_RENDER` state for startup/backstop reconciliation.

- [ ] **Step 2: Run worker tests and verify RED**

```bash
(cd android && ./gradlew :app:testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.ReplyWorkerIdentityTest')
```

Expected: WorkManager input data still owns payload or a race/restart can POST twice.

- [ ] **Step 3: Implement conservative delivery classification and CAS transitions**

```kotlin
internal sealed interface ReplyDeliveryOutcome {
    data object Delivered : ReplyDeliveryOutcome
    data object SafePreTransmissionFailure : ReplyDeliveryOutcome
    data object Uncertain : ReplyDeliveryOutcome
}

internal fun classifyReplyFailure(error: Throwable): ReplyDeliveryOutcome = when {
    error is java.nio.channels.UnresolvedAddressException ||
        error is io.ktor.client.network.sockets.ConnectTimeoutException ->
        ReplyDeliveryOutcome.SafePreTransmissionFailure
    error is com.atomikpanda.groundcontrol.data.ApiResponseException &&
        error.status.value in 400..499 ->
        ReplyDeliveryOutcome.SafePreTransmissionFailure
    else -> ReplyDeliveryOutcome.Uncertain
}
```

`ReplyExecutor` loads by opaque action key and resolves its persisted canonical connection ID through the latest DataStore snapshot using `findByConnectionId`. If unresolved, one Room transaction revalidates version/capability and CASes READY→WAITING_FOR_CONNECTION; it returns success and does not ask WorkManager to retry. Connection-flow reconciliation alone CASes a still-current waiting row back to READY and enqueues it once after commit. If resolved, the claim transaction checks tombstones, exact current notification version/capability, and `READY → IN_FLIGHT(executionId, claimedAtMillis)`; it proceeds only after one successful claim. Re-read and require the same full `WorkspaceConnection` immediately before invoking the POST lambda so removal/replacement cannot knowingly use a retired credential. A different execution encountering IN_FLIGHT never POSTs or steals the claim. The same WorkRequest execution ID encountering its prior IN_FLIGHT row after restart transitions it to `UNCERTAIN_PENDING_RENDER` without POST. Startup/backstop handles work that will never re-enter: after checking that its unique WorkManager request is absent or terminal, it CASes the abandoned IN_FLIGHT row to `UNCERTAIN_PENDING_RENDER`; it never touches ENQUEUED/RUNNING work. Every completion CAS includes action key, notification version, expected state, and execution ID. Transition success to `DELIVERED_PENDING_RENDER`, proven pre-transmission failure or production `ApiResponseException` HTTP 4xx rejection to `SAFE_FAILURE_PENDING_RENDER`, and every other failure—including cancellation after claim—to `UNCERTAIN_PENDING_RENDER`. After any successful completion CAS, immediately invoke `NotificationRenderCoordinator.renderPending(actionKey)` outside the transaction; a render exception is recorded but cannot retry the POST, and the unchanged pending row remains discoverable by startup/backstop. Return `Result.success()` for uncertain and render failure; never use WorkManager automatic retry after a POST starts.

- [ ] **Step 4: Run worker tests and verify GREEN**

Run the command from Step 2.

Expected: one POST maximum, exact payload, no stale POST, conservative uncertainty, and no automatic uncertain retry.

- [ ] **Step 5: Commit transactional execution**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/data/MshipClient.kt android/app/src/main/java/com/atomikpanda/groundcontrol/notify/ReplyLifecycle.kt android/app/src/main/java/com/atomikpanda/groundcontrol/notify/ReplyOutbox.kt android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NotificationRenderCoordinator.kt android/app/src/main/java/com/atomikpanda/groundcontrol/notify/ReplyExecutor.kt android/app/src/main/java/com/atomikpanda/groundcontrol/notify/ReplyWorker.kt android/app/src/test/java/com/atomikpanda/groundcontrol/ReplyWorkerIdentityTest.kt
git commit -m "fix: claim reply outbox work exactly once"
mship journal "worker now claims current-generation outbox rows once and terminalizes uncertain delivery; focused tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 acs=ac5,ac6,ac7,ac8,ac9,ac13,ac18,ac19 -->
### Task 4: Reconcile notification rendering transactionally

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/AndroidNotifier.kt:27-end`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NeedsYouCore.kt:28-109`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NotificationFormat.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/ReplyOutbox.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NotificationRenderCoordinator.kt`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/NeedsYouReconcilerTest.kt`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/ReplyWorkerIdentityTest.kt`

**Interfaces:**
- Consumes: persisted `*_PENDING_RENDER` states and notification generation.
- Produces: generation-checked render acknowledgement and terminal `DELIVERED`, `SAFE_FAILURE`, or `UNCERTAIN` state.

- [ ] **Step 1: Write stale-render and non-resurrection tests**

```kotlin
@Test fun generation_advance_before_render_lock_suppresses_stale_render() = runTest {
    outbox.seed(deliveredPending(version = "old#1"))
    renderer.pauseAfterCandidateLoadBeforeThreadLock()
    val render = async { renderer.renderPending(key) }
    renderer.awaitCandidateLoad()
    coordinator.activateAndPublish(connId, threadId, sourceVersion = "new") {
        notifier.publishCurrentActionable()
    }
    renderer.resume()
    render.await()
    assertEquals(ReplyOutboxState.STALE, outbox.get(key)!!.state)
    assertTrue(notifier.currentNotificationIsActionable(connId, threadId))
    assertEquals(0, notifier.oldGenerationPublishCount)
}
```

Add successful delivery non-resurrection after restart, safe-failure fresh capability, safe-failure notifier throw followed by restart publishing the same fresh capability exactly once, uncertain informational/no-actions rendering, delayed old cancellation completion, and delivered/uncertain notifier-throw-before-ack tests.

- [ ] **Step 2: Run notifier/reconciler tests and verify RED**

```bash
(cd android && ./gradlew :app:testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.NeedsYouReconcilerTest' --tests 'com.atomikpanda.groundcontrol.ReplyWorkerIdentityTest')
```

Expected: notifier and version state can advance independently of outbox render acknowledgement.

- [ ] **Step 3: Add transaction-bound render eligibility and acknowledgement**

```kotlin
@Query(
    "UPDATE reply_outbox SET state = :next " +
        "WHERE actionKey = :actionKey AND notificationVersion = :version " +
        "AND state = :expected AND renderVersion IS :renderVersion"
)
suspend fun transitionForRender(
    actionKey: String,
    version: String,
    expected: ReplyOutboxState,
    renderVersion: String?,
    next: ReplyOutboxState,
): Int
```

`NotificationRenderCoordinator` owns one `Mutex` per `(connectionId, threadId)`. Route both normal notification activation/publication and pending-outbox rendering through `withThreadLock`; no generation can activate between the final eligibility transaction and notifier side effect. `renderPending` may load a candidate before the lock, but under the lock it runs the authoritative Room transaction and reloads the row by action key. DELIVERED/UNCERTAIN requires the row's original version/capability to be the exact current generation, then clears that exact active version while leaving the row pending. SAFE_FAILURE with no render target first requires the original generation, activates one fresh generation/capability, and atomically stores them in `renderVersion`/`renderCapabilityKey` while leaving `SAFE_FAILURE_PENDING_RENDER`; a retry with an existing render target requires that exact fresh generation and never activates another. Any original/render target mismatch CASes pending→STALE. Publish/cancel outside the database transaction but still under the thread lock. On successful side effect, a second transaction rechecks action key, original notification version, pending state, and nullable render target before `transitionForRender` to DELIVERED/UNCERTAIN/SAFE_FAILURE. If notifier throws, the pending row retains its exact target: startup retries a matching inactive original terminal generation or matching active safe-failure render generation, but can never act on a newer generation.

- [ ] **Step 4: Run notifier/reconciler tests and verify GREEN**

Run the command from Step 2.

Expected: terminal delivery does not resurrect, uncertain remains non-retryable, safe failure gets a new manual capability, and stale acknowledgement cannot affect current state.

- [ ] **Step 5: Commit render reconciliation**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/notify/AndroidNotifier.kt android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NeedsYouCore.kt android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NotificationFormat.kt android/app/src/main/java/com/atomikpanda/groundcontrol/notify/ReplyOutbox.kt android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NotificationRenderCoordinator.kt android/app/src/test/java/com/atomikpanda/groundcontrol/NeedsYouReconcilerTest.kt android/app/src/test/java/com/atomikpanda/groundcontrol/ReplyWorkerIdentityTest.kt
git commit -m "fix: acknowledge reply rendering by generation"
mship journal "notification rendering now consumes durable pending states and acknowledges only matching generations; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=5 acs=ac1,ac2,ac3,ac4,ac5,ac6,ac7,ac8,ac9,ac10,ac11,ac12,ac13,ac14,ac15,ac16,ac17,ac18,ac19,ac20 -->
### Task 5: Verify restart, migration, and privacy contracts

**Files:**
- Modify only if a failing observable contract requires it: files listed in Tasks 1-4.

**Interfaces:**
- Consumes: complete Room outbox and notification reconciler.
- Produces: PR #76 task-scoped evidence.

- [ ] **Step 1: Run reply lifecycle JVM tests**

```bash
(cd android && ./gradlew :app:testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.ReplyWorkerIdentityTest' --tests 'com.atomikpanda.groundcontrol.NeedsYouReconcilerTest')
```

Expected: BUILD SUCCESSFUL.

- [ ] **Step 2: Run receiver and migration instrumentation tests**

```bash
(cd android && ./gradlew :app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.atomikpanda.groundcontrol.notify.ReplyReceiverOutboxTest,com.atomikpanda.groundcontrol.notify.NotifiedDatabaseMigrationTest)
```

Expected: BUILD SUCCESSFUL on the configured emulator/device. If no Android runtime is attached, build both test APKs with `:app:assembleDebugAndroidTest` and record the runtime blocker without claiming instrumentation execution.

- [ ] **Step 3: Inspect work names and logs for payload leakage**

```bash
(cd android && ./gradlew :app:testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.ReplyWorkerIdentityTest.work_request_contains_only_opaque_action_key' --tests 'com.atomikpanda.groundcontrol.ReplyWorkerIdentityTest.errors_do_not_include_reply_or_decision_payload')
```

Expected: PASS; only opaque action keys enter WorkManager metadata and errors contain no payload/context.

- [ ] **Step 4: Run task-scoped Mothership verification**

```bash
mship test --task reply-notification-lifecycle
mship journal "reply outbox redesign complete: durable intake, exact-once claims, terminal uncertainty, generation-safe rendering, migrations, and privacy checks verified" --action verified
```

Expected: task test passes and records evidence.
<!-- /mship:task -->
