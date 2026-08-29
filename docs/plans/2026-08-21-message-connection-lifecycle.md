# Message Connection Reconciler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serialize each message connection's initial load, refresh, poll, cursor, retry, adoption, replacement, and cancellation decisions under one deterministic owner.

## Assumptions checked

- repo topology — covered: only Ground Control Android changes on PR #75.
- credential locus — covered: request credentials remain on existing `WorkspaceConnection` objects and in DataStore.
- execution locus — covered: network calls run in child coroutines; all completion acceptance and state mutation returns through a per-connection owner.
- state durability — covered: message lists/cursors remain process memory as today; no new persisted message schema is introduced.
- review surface — covered: PR #75 and deterministic `MessagesViewModelTest` concurrency scenarios.
- agent stream — covered: one task worker executes owner, integration, and verification tasks in order.
- dispatched model — covered: use the task's configured Mothership implementation model.

**Architecture:** Add one `MessageConnectionOwner` per canonical connection ID. The owner issues generation/revision tokens, runs network work outside its mutex, and accepts a completion only when the owner, generation, revision, and connection snapshot still match; `MessagesViewModel` becomes the UI projection and filter layer over owner snapshots.

**Tech Stack:** Kotlin, ViewModel, coroutines, Mutex, StateFlow, Ktor MockEngine, kotlinx-coroutines-test, JUnit 4.

**Spec:** `ground-control-message-reconciler` — `specs/2026-08-21-ground-control-message-reconciler.md`

**Command root:** Run every command from the assigned `message-connection-lifecycle/ground-control` worktree root. Gradle commands use `(cd android && ./gradlew …)`.

## Global Constraints

- Ground Control Android only; no server API, message payload, cursor, wire protocol, or persistence migration.
- Network waits and retry delays never run while the owner's state mutex is held.
- Initial load or manual refresh accepts an authoritative full snapshot: it replaces that owner's complete threads/items and preserves only the already accepted live cursor. Poll deltas alone merge by thread ID.
- Messages and cursor commit atomically for one accepted poll completion.
- Stale, failed, cancelled, or superseded completions commit neither messages nor cursor and schedule no new work.
- Retry state is isolated and single-flight per connection; one failing connection cannot block another.
- User-visible message formatting, filters, controls, and grouping remain unchanged.

---

<!-- mship:task id=1 acs=ac1,ac2,ac3,ac4,ac5,ac6,ac9,ac10,ac11,ac12 -->
### Task 1: Build the per-connection serialization owner

**Files:**
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/MessageConnectionOwner.kt`
- Create: `android/app/src/test/java/com/atomikpanda/groundcontrol/MessageConnectionOwnerTest.kt`

**Interfaces:**
- Consumes: a `WorkspaceConnection`, `suspend (WorkspaceConnection) -> MessageFullLoad`, `suspend (WorkspaceConnection, String) -> MessagePollDelta`, a coroutine scope, an injectable cursor clock, and injectable `suspend () -> Unit` retry delay.
- Produces: `MessageConnectionSnapshot`, `MessageRequestToken`, internal `begin/complete` reducer methods, and public `initialLoad()`, `refresh()`, `startPolling()`, `handoffTo()`, and `cancel()`. Production construction binds retry delay to `delay(LIVE_POLL_RETRY_DELAY_MILLIS)` with the existing 2,000 ms constant; tests inject the controlled channel delay.

- [ ] **Step 1: Write deterministic token and completion tests**

Create a self-contained `ControllableMessageNetwork` in the test file. Each full-load or poll lambda sends a `PendingMessageRequest(id, connection, cursor, result: CompletableDeferred<Result<…>>)` to an unlimited `Channel`; `awaitRequest()` waits for a request to start; `succeed`/`fail` completes a named deferred; atomic counters record starts. Inject `backgroundScope` and a retry-delay lambda that waits on another test-controlled channel. Use the owner's internal token reducer for non-cooperative stale-completion interleavings:

```kotlin
@Test fun newer_refresh_wins_when_completions_reverse() = runTest {
    val owner = owner(ControllableMessageNetwork(), backgroundScope)
    val first = owner.beginForTest(MessageRequestToken.Kind.REFRESH)
    val second = owner.beginForTest(MessageRequestToken.Kind.REFRESH)
    owner.completeForTest(second, Result.success(MessageFullLoad(listOf(newer), emptyList())))
    owner.completeForTest(first, Result.success(MessageFullLoad(listOf(older), emptyList())))
    assertEquals(listOf(newer), owner.snapshot.value.threads.getOrThrow())
}

@Test fun newer_failure_still_fences_older_completion() = runTest {
    val first = owner.beginForTest(MessageRequestToken.Kind.REFRESH)
    val second = owner.beginForTest(MessageRequestToken.Kind.REFRESH)
    owner.completeForTest(second, Result.failure(IOException("offline")))
    owner.completeForTest(first, Result.success(MessageFullLoad(listOf(older), emptyList())))
    assertFalse(owner.snapshot.value.threads.getOrThrow().contains(older))
}

@Test fun stale_generation_commits_neither_threads_nor_cursor() = runTest {
    val token = owner.beginForTest(MessageRequestToken.Kind.POLL)
    owner.handoffTo(replacementConnection)
    owner.completeForTest(token, Result.success(MessagePollDelta(listOf(stale), "stale-cursor")))
    assertEquals(emptyList<ThreadSummary>(), owner.snapshot.value.threads.getOrThrow())
    assertEquals("", owner.snapshot.value.cursor)
}
```

Add tests for newer-request cancellation fencing an older completion, initial-load failure publishing Error and retrying the full load, cancellation during retry, another owner progressing during retry delay, initial success seeding the first poll cursor from maximum nonblank `updatedAt` (or the injected clock for an empty load), accepted poll delta merging and advancing its cursor atomically, a blank timeout/no-progress poll retaining the prior cursor while still accepting changed threads, stale poll rejecting both changed threads and cursor, failed poll/refresh preserving the last accepted snapshot, one retry loop per failure, successful retry resuming continuous polling, and handoff during INITIAL_LOADING/INITIAL_ERROR launching one fresh full load against the replacement connection.

- [ ] **Step 2: Run owner tests and verify RED**

```bash
(cd android && ./gradlew :app:testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.MessageConnectionOwnerTest')
```

Expected: FAIL because the owner types do not exist.

- [ ] **Step 3: Implement token-gated owner state**

```kotlin
internal data class MessageRequestToken(
    val generation: Long,
    val revision: Long,
    val kind: Kind,
) {
    enum class Kind { INITIAL, REFRESH, POLL }
}

internal data class MessageFullLoad(
    val threads: List<ThreadSummary>,
    val items: List<WorkItemSummary>,
)

internal data class MessagePollDelta(
    val changedThreads: List<ThreadSummary>,
    val cursor: String,
)

internal data class MessageConnectionSnapshot(
    val connection: WorkspaceConnection,
    val threads: Result<List<ThreadSummary>>,
    val items: List<WorkItemSummary>,
    val cursor: String,
    val phase: Phase,
    val lastError: Throwable?,
) {
    enum class Phase { INITIAL_LOADING, INITIAL_ERROR, READY }
}
```

Under the owner mutex keep `generation`, `latestIssuedRevision`, `acceptedRevision`, one `activeRequest`, one `retryJob`, `pollingEnabled`, and `cancelled`. `begin(kind)` first increments `latestIssuedRevision`, then cancels the prior request/retry and returns the new token; a later failure or cancellation never lowers that issuance fence. Every completion requires exact generation, exact connection identity, `token.revision == latestIssuedRevision`, and the token still owning `activeRequest`. Network work and joins run outside the mutex. An initial failure publishes `INITIAL_ERROR` plus the failure and schedules one delayed INITIAL retry; it never polls. After READY, refresh/poll failure preserves threads/items/cursor, records `lastError`, and schedules one same-kind retry. A current INITIAL completion replaces the complete threads/items, sets READY, clears `lastError`, and seeds the cursor from the maximum nonblank thread `updatedAt`, falling back to the injected clock; the first poll is launched only with that nonblank cursor. A current REFRESH completion replaces the complete threads/items, sets READY, clears `lastError`, and retains the accepted cursor. A current POLL completion applies `mergeThreadsById(snapshotThreads, delta.changedThreads)` and, only when `delta.cursor` is nonblank, advances the cursor in the same `_snapshot.value` assignment; blank cursors retain the prior accepted value. Manual refresh cancels/fences any in-flight poll; after the authoritative full result (or its retry) is accepted, polling resumes from the retained cursor. Poll success launches the next poll only after its snapshot is published. Cancellation and supersession schedule nothing.

- [ ] **Step 4: Run owner tests and verify GREEN**

Run the command from Step 2.

Expected: PASS for reverse completion, stale generation, cursor rejection, retry cancellation, and per-owner isolation.

- [ ] **Step 5: Commit the owner**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/MessageConnectionOwner.kt android/app/src/test/java/com/atomikpanda/groundcontrol/MessageConnectionOwnerTest.kt
git commit -m "feat: serialize each message connection lifecycle"
mship journal "added token-gated per-connection message owner; deterministic concurrency tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 acs=ac1,ac2,ac3,ac6,ac9,ac10,ac11,ac12,ac14 -->
### Task 2: Delegate initial load, refresh, polling, and cancellation

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/MessagesViewModel.kt:95-end`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/MessagesViewModelTest.kt`

**Interfaces:**
- Consumes: `MessageConnectionOwner` and `MessageConnectionSnapshot` from Task 1; `ThreadsRepository.listThreadsFor`, `listAllItems`, and `waitForChange`.
- Produces: unchanged `MessagesUiState` and public filter/selection functions.

- [ ] **Step 1: Write ViewModel lifecycle regressions**

`messagesViewModel` wires the same `ControllableMessageNetwork` lambdas into owners. Add test-only `MessagesUiState.Content.threadsFor(connectionId)` and `MessagesViewModel.content()` helpers that unwrap the public state; they contain no production behavior. Every test waits on named network/barrier events and uses `runCurrent()` only to drain already-unblocked work—never a wall-clock delay.

```kotlin

@Test fun failed_initial_load_retries_without_starting_poll_or_blocking_other_connection() = runTest {
    val connections = MutableStateFlow(listOf(connA, connB))
    val network = ControllableMessageNetwork()
    val vm = messagesViewModel(network, connections)
    vm.startLivePolling()
    val requestA = network.awaitFullRequest(connA.id)
    val requestB = network.awaitFullRequest(connB.id)
    requestA.fail(IOException("offline"))
    requestB.succeed(MessageFullLoad(listOf(bThread), emptyList()))
    runCurrent()
    assertEquals(listOf(bThread.id), vm.content().threadsFor(connB.id).map { it.id })
    assertEquals(0, network.pollCount(connA.id))
    network.releaseRetry(connA.id)
    network.awaitFullRequest(connA.id).succeed(MessageFullLoad(listOf(aThread), emptyList()))
    runCurrent()
    assertEquals(listOf(aThread.id), vm.content().threadsFor(connA.id).map { it.id })
}

@Test fun removing_connection_cancels_retry_and_late_completion() = runTest {
    val connections = MutableStateFlow(listOf(connA))
    val network = ControllableMessageNetwork()
    val vm = messagesViewModel(network, connections)
    val request = network.awaitFullRequest(connA.id)
    connections.value = emptyList()
    runCurrent()
    request.succeed(MessageFullLoad(listOf(staleThread), emptyList()))
    runCurrent()
    assertEquals(MessagesUiState.EmptyConfig, vm.state.value)
    assertEquals(0, network.retryCount(connA.id))
}

@Test fun refresh_without_intervening_poll_removes_server_deleted_thread() = runTest {
    val vm = loadedViewModel(threads = listOf(t1, t2, t3), cursor = "cursor-1")
    vm.refresh()
    network.awaitFullRequest(connA.id)
        .succeed(MessageFullLoad(listOf(t1, t3), emptyList()))
    runCurrent()
    assertEquals(listOf(t1.id, t3.id), vm.content().threadsFor(connA.id).map { it.id })
    assertEquals("cursor-1", vm.ownerSnapshot(connA.id).cursor)
}

@Test fun pre_refresh_poll_completion_cannot_restore_deleted_thread() = runTest {
    val vm = loadedAndPollingViewModel(listOf(t1, t2, t3), cursor = "cursor-1")
    val oldPoll = network.awaitPollRequest(connA.id)
    vm.refresh()
    network.awaitFullRequest(connA.id)
        .succeed(MessageFullLoad(listOf(t1, t3), emptyList()))
    oldPoll.succeed(MessagePollDelta(listOf(t2), "cursor-stale"))
    runCurrent()
    assertEquals(listOf(t1.id, t3.id), vm.content().threadsFor(connA.id).map { it.id })
    assertEquals("cursor-1", vm.ownerSnapshot(connA.id).cursor)
}
```

- [ ] **Step 2: Run `MessagesViewModelTest` and verify RED**

```bash
(cd android && ./gradlew :app:testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.MessagesViewModelTest')
```

Expected: new tests fail against `loadJobs`, `pollJobs`, and global initial-load flags.

- [ ] **Step 3: Replace competing maps and flags with owners**

```kotlin
private val owners = mutableMapOf<String, MessageConnectionOwner>()
private val ownerCollectors = mutableMapOf<MessageConnectionOwner, Job>()

private fun observe(owner: MessageConnectionOwner) {
    ownerCollectors.getOrPut(owner) {
        scope().launch { owner.snapshot.collect { renderOwners() } }
    }
}

private suspend fun reconcileConnections(current: List<WorkspaceConnection>) {
    // Task 3 adds alias-owner transfer; this task handles exact IDs and removals.
    owners.keys.filterNot(current.map { it.id }::contains).forEach(::removeAndCancelOwner)
    current.forEach { connection ->
        owners[connection.id]?.handoffTo(connection)
            ?: createOwner(connection).also { owner ->
                owners[connection.id] = owner
                observe(owner)
                owner.initialLoad()
            }
    }
    renderOwners()
}
```

Remove `loadJobs`, `pollJobs`, `livePollRevisions`, `hasCompletedInitialLoad`, and `livePollingStarted` decision logic. Keep UI filter/group derivation in `MessagesViewModel`; source each `ThreadsSection` from the latest owner snapshot. `observe(owner)` is the only collector installation path and `ownerCollectors.getOrPut(owner)` guarantees one active collector; the collector renders after every accepted owner snapshot. `removeAndCancelOwner` first removes all map keys for the owner and generation-invalidates/cancels the owner, so no later completion can schedule follow-up work; only then does it remove, cancel, and join the sole collector and join the already-invalidated owner jobs. Keep reconcile-revision and map-membership checks around every suspension. Add an integration assertion that initial success, each poll, refresh, retry success, and handoff each produce one new projection, while a stale completion produces none. `MessageConnectionOwner.refresh()` returns the exact full-request `Job`; `MessagesViewModel.refresh()` captures the current owners and returns one Job that `joinAll()`s those request jobs, preserving both existing `vm.refresh()?.join()` callsites before polling/refresh UI completes. `startLivePolling()` enables polling on every owner and on owners added later, but the owner starts polls only in READY. Build the full-load lambda as `coroutineScope { val threads = async { repo.listThreadsFor(conn) }; val items = async { repo.listAllItems(listOf(conn))[conn.id].orEmpty() }; MessageFullLoad(threads.await(), items.await()) }`. Bind the poll adapter as `repo.waitForChange(conn, cursor, LIVE_POLL_TIMEOUT_SECONDS).let { MessagePollDelta(it.threads, it.cursor) }`, where the existing timeout policy remains 25 seconds and the cursor is forwarded unchanged for owner-side blank preservation. Production `createOwner` passes `retryDelay = { delay(LIVE_POLL_RETRY_DELAY_MILLIS) }` and the UTC cursor clock.

- [ ] **Step 4: Run `MessagesViewModelTest` and verify GREEN**

Run the command from Step 2.

Expected: PASS for initial Loading/Error/Ready transitions, single-flight retry isolation, removal cancellation, authoritative refresh deletion, cursor atomicity, projection updates, filters, grouping, and continuous polling.

- [ ] **Step 5: Commit ViewModel delegation**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/MessagesViewModel.kt android/app/src/test/java/com/atomikpanda/groundcontrol/MessagesViewModelTest.kt
git commit -m "refactor: delegate message work to connection owners"
mship journal "delegated message load refresh poll retry and cancellation to per-connection owners; full ViewModel tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 acs=ac5,ac7,ac8,ac9,ac10,ac12,ac13,ac14 -->
### Task 3: Make adoption and replacement an atomic owner handoff

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/MessageConnectionOwner.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/MessagesViewModel.kt`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/MessageConnectionOwnerTest.kt`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/MessagesViewModelTest.kt`

**Interfaces:**
- Consumes: canonical ID/alias resolution through `findByConnectionId` and owner snapshots from Tasks 1-2.
- Produces: `handoffTo(connection)` that retains accepted messages/cursor while invalidating obsolete work.

- [ ] **Step 1: Write adoption and replacement race tests**

```kotlin
@Test fun adoption_keeps_accepted_cursor_and_only_survivor_polls() = runTest {
    owner.completeForTest(initialToken, Result.success(MessageFullLoad(listOf(existing), emptyList())))
    val cursorPoll = owner.beginForTest(MessageRequestToken.Kind.POLL)
    owner.completeForTest(cursorPoll, Result.success(MessagePollDelta(emptyList(), "cursor-7")))
    val stalePoll = owner.beginForTest(MessageRequestToken.Kind.POLL)
    val receipt = requireNotNull(owner.handoffTo(adoptedConnection))
    owner.resumeAfterHandoff(receipt)
    owner.completeForTest(stalePoll, Result.success(MessagePollDelta(listOf(stale), "cursor-8")))
    val snapshot = owner.snapshot.value
    assertEquals(listOf(existing), snapshot.threads.getOrThrow())
    assertEquals("cursor-7", snapshot.cursor)
    assertEquals(adoptedConnection, snapshot.connection)
    assertEquals(1, network.activePollers(adoptedConnection.id))
}
```

Add direct owner cases for INITIAL_LOADING and INITIAL_ERROR handoffs; each captures the non-null `HandoffReceipt`, calls `resumeAfterHandoff(receipt)`, and asserts exactly one replacement full load starts only after detached work joins. Add ViewModel cases where: (1) a sole legacy owner is rekeyed to the canonical ID while its old request is in flight; (2) canonical and legacy owners converge, only one canonical section remains, no cross-owner cursor/thread merge occurs, and one authoritative refresh repopulates it; (3) same-ID route/auth replacement occurs during a request; and (4) connection removal lands while `handoffTo` is waiting for a cancelled job to join. Assert exact section IDs, request connection snapshots, cursor, projection count, and active poller count after each named barrier.

- [ ] **Step 2: Run owner and ViewModel tests and verify RED**

```bash
(cd android && ./gradlew :app:testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.MessageConnectionOwnerTest' --tests 'com.atomikpanda.groundcontrol.MessagesViewModelTest')
```

Expected: stale work can still publish or handoff loses accepted cursor/messages.

- [ ] **Step 3: Implement generation-bumped handoff**

```kotlin
internal data class HandoffReceipt(val generation: Long)

private var pendingHandoffJobs = emptySet<Job>()

suspend fun handoffTo(replacement: WorkspaceConnection): HandoffReceipt? {
    val handoff = mutex.withLock {
        if (_snapshot.value.connection != replacement) {
            generation += 1
            pendingHandoffJobs = pendingHandoffJobs +
                listOfNotNull(activeRequest, retryJob)
            activeRequest = null
            retryJob = null
            _snapshot.value = _snapshot.value.copy(connection = replacement)
        }
        Handoff(generation, pendingHandoffJobs.toList())
    }
    // No suspension occurs between detaching the jobs and cancelling them.
    handoff.jobs.forEach(Job::cancel)
    handoff.jobs.joinAll() // cancellation leaves the jobs recorded for the next reconcile
    return mutex.withLock {
        if (generation != handoff.generation ||
            _snapshot.value.connection != replacement
        ) return@withLock null
        pendingHandoffJobs = pendingHandoffJobs - handoff.jobs.toSet()
        HandoffReceipt(handoff.generation)
    }
}

suspend fun resumeAfterHandoff(receipt: HandoffReceipt) {
    mutex.withLock {
        if (generation != receipt.generation || cancelled ||
            pendingHandoffJobs.isNotEmpty() ||
            activeRequest != null || retryJob != null
        ) return
        when (_snapshot.value.phase) {
            MessageConnectionSnapshot.Phase.READY ->
                if (pollingEnabled) launchPollLocked(_snapshot.value.cursor)
            MessageConnectionSnapshot.Phase.INITIAL_LOADING,
            MessageConnectionSnapshot.Phase.INITIAL_ERROR -> launchInitialLocked()
        }
    }
}

suspend fun cancel() {
    val jobs = mutex.withLock {
        if (!cancelled) {
            cancelled = true
            generation += 1
        }
        val detached = pendingHandoffJobs + listOfNotNull(activeRequest, retryJob)
        pendingHandoffJobs = emptySet()
        activeRequest = null
        retryJob = null
        detached
    }
    jobs.forEach(Job::cancel)
    jobs.joinAll()
}
```

Collect connection snapshots with `collectLatest`, incrementing `reconcileRevision` before each reconcile; a newer emission cancels a handoff blocked in `joinAll`, and the next reconcile removes/invalidates the owner before any resumption. Never merge thread lists or cursors from different owners. If no canonical owner exists, choose the first alias owner named by `connection.legacyConnectionIds` (stable persisted order), remove/cancel its snapshot collector before calling `handoffTo`, and do not expose it under the canonical key yet. The first handoff mutex returns the detached job set, and straight-line code cancels it before the next suspension. The owner also retains every detached request/retry in `pendingHandoffJobs` until a handoff successfully joins and clears it; `cancel()` captures, cancels, and joins active, retry, and pending-handoff jobs together. Thus cancellation during `joinAll` cannot lose the job handle, and removal cannot leave an old poll alive: a later matching snapshot joins retained jobs before receiving a resumable receipt. `handoffTo` returns the current receipt when its snapshot already equals the replacement and no jobs remain, so a later snapshot can finish an interrupted rekey instead of stranding an unobserved alias owner; a generation/replacement mismatch returns null and aborts that stale reconcile without creating another owner. After a non-null receipt, recheck the reconcile revision and canonical membership; only then remove every old key, install that same owner under the canonical key, reinstall its one collector, and call idempotent `resumeAfterHandoff(receipt)`, which starts nothing while any detached/request/retry job remains. Cancel all remaining aliases. If a canonical owner already exists, it survives unchanged and every alias owner is generation-invalidated/cancelled; no alias state is copied. Same-ID endpoint/auth replacement also calls `handoffTo`, then rechecks revision/current full identity before `resumeAfterHandoff`. Every suspension boundary rechecks revision and map membership. A convergence with more than one prior owner issues exactly one authoritative full refresh on the survivor; its full result replaces all old sections, then polling resumes from the survivor's retained cursor. Tests cancel just after detach and during blocked join: removal cancels/joins the pending old job with no publication, while a later Ready snapshot joins retained work before the same owner is rekeyed, observed once, and resumed once from its preserved snapshot.

- [ ] **Step 4: Run owner and ViewModel tests and verify GREEN**

Run the command from Step 2.

Expected: PASS for sole-owner adoption with in-flight work, canonical/alias convergence, same-ID replacement, retained eligible cursor/messages, one canonical section/collector/poller, removal-during-handoff, and stale completion rejection.

- [ ] **Step 5: Commit handoff semantics**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/MessageConnectionOwner.kt android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/MessagesViewModel.kt android/app/src/test/java/com/atomikpanda/groundcontrol/MessageConnectionOwnerTest.kt android/app/src/test/java/com/atomikpanda/groundcontrol/MessagesViewModelTest.kt
git commit -m "fix: hand off message owners atomically"
mship journal "added generation-bumped adoption and replacement handoff with retained cursor and one poller; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 acs=ac1,ac2,ac3,ac4,ac5,ac6,ac7,ac8,ac9,ac10,ac11,ac12,ac13,ac14 -->
### Task 4: Verify the complete reconciler contract

**Files:**
- Modify only if a failing observable contract requires it: files listed in Tasks 1-3.

**Interfaces:**
- Consumes: completed owner and ViewModel integration.
- Produces: PR #75 task-scoped evidence.

- [ ] **Step 1: Run deterministic message tests twice**

```bash
(cd android && ./gradlew :app:testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.MessageConnectionOwnerTest' --tests 'com.atomikpanda.groundcontrol.MessagesViewModelTest')
(cd android && ./gradlew :app:testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.MessageConnectionOwnerTest' --tests 'com.atomikpanda.groundcontrol.MessagesViewModelTest')
```

Expected: both runs BUILD SUCCESSFUL without timing-dependent retries.

- [ ] **Step 2: Run task-scoped Mothership verification**

```bash
mship test --task message-connection-lifecycle
```

Expected: pass with unchanged message formatting and controls.

- [ ] **Step 3: Record verification evidence**

```bash
mship journal "message reconciler complete: per-connection serialization, atomic cursor commits, isolated retries, and adoption handoff; task suite passing" --action verified
```
<!-- /mship:task -->
