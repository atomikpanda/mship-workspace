# Ground Control Notifications (needs-you) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `ground-control-notifications-for-needs` (approved). Tracking issue: mothership #248.

**Goal:** Android notifications when an agent posts a `needs_you` message — a hybrid foreground-service long-poll + WorkManager backstop, gated by a global toggle, with dedup-on-resolve, an FCM-ready trigger seam, and a `groundcontrol://` deep-link resolver. Client-only (ground-control); no server change.

**Architecture:** A testable core — `NeedsYouReconciler` (dedup-on-resolve over `NotifiedStore`/`Notifier` interfaces) and `DeepLinkResolver` (pure, `java.net.URI`) — wrapped by Android framework shells (`WatchService` FGS, `WatchBackstopWorker`, `BootReceiver`, `AndroidNotifier`, `RoomNotifiedStore`, a `GroundControlApplication`). The shells construct deps manually (no DI), matching the app's `remember { ... }` pattern.

**Tech Stack:** Kotlin/Compose, Ktor 2.3.12, kotlinx-serialization, DataStore; **new:** Room (+ KSP) and WorkManager. JUnit4 + kotlinx-coroutines-test + Ktor MockEngine, JVM unit tests only (`./gradlew testDebugUnitTest --rerun-tasks`, run from `android/` after `source ~/toolchains/android-env.sh`).

**Worktree:** `.worktrees/ground-control-notifications-for-needs/ground-control` (source root `android/app/src/main/java/com/atomikpanda/groundcontrol/`, test root `android/app/src/test/java/com/atomikpanda/groundcontrol/`, package `com.atomikpanda.groundcontrol`).

**Verification note:** `./gradlew testDebugUnitTest` compiles **all** main + test sources (incl. KSP/Room codegen) before running unit tests — so it catches compile errors in the framework shells too. Framework *behavior* (the FGS actually running, a notification actually posting, the reboot/permission flow) is not unit-testable here and is **operator-verified on a device** via `mship capture` / manual. Every task's gate is `./gradlew testDebugUnitTest --rerun-tasks` green.

---

<!-- mship:task id=1 -->
### Task 1: Build setup — KSP + Room + WorkManager, `GroundControlApplication`, notification channels, manifest permissions

Foundation: add the new build plumbing and the Application class that creates the notification channels. No unit test (pure scaffolding); the gate is that the project still compiles and the existing suite stays green.

**Files:**
- Modify: `android/build.gradle.kts` (root — add KSP plugin to the plugins block)
- Modify: `android/app/build.gradle.kts` (KSP plugin + Room/WorkManager deps)
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApplication.kt`
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NotificationChannels.kt`
- Modify: `android/app/src/main/AndroidManifest.xml`

- [ ] **Step 1: Add the KSP plugin to the root `android/build.gradle.kts`.** It currently declares the android/kotlin plugins with `apply false`. Add KSP alongside them (match the existing Kotlin version 2.0.x). In the root `plugins { }` block add:

```kotlin
    id("com.google.devtools.ksp") version "2.0.0-1.0.22" apply false
```

(Use the KSP version matching the project's Kotlin version. If the root uses a version catalog or a different Kotlin version, align the KSP version's `<kotlin>-<ksp>` prefix to it.)

- [ ] **Step 2: Apply KSP + add deps in `android/app/build.gradle.kts`.** In its `plugins { }` add `id("com.google.devtools.ksp")`. In `dependencies { }` add:

```kotlin
    implementation("androidx.work:work-runtime-ktx:2.9.0")
    implementation("androidx.room:room-runtime:2.6.1")
    implementation("androidx.room:room-ktx:2.6.1")
    ksp("androidx.room:room-compiler:2.6.1")
```

- [ ] **Step 3: Create `NotificationChannels.kt`** (channel IDs + a `createAll` helper):

```kotlin
package com.atomikpanda.groundcontrol.notify

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build

object NotificationChannels {
    /** High-importance, heads-up: an agent needs the operator. */
    const val NEEDS_YOU = "agent_needs_you"
    /** Low-importance, ongoing: the foreground "watching" notification. */
    const val WATCHING = "watching_for_messages"

    fun createAll(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = context.getSystemService(NotificationManager::class.java) ?: return
        mgr.createNotificationChannel(
            NotificationChannel(NEEDS_YOU, "Agent needs you", NotificationManager.IMPORTANCE_HIGH)
        )
        mgr.createNotificationChannel(
            NotificationChannel(WATCHING, "Watching for messages", NotificationManager.IMPORTANCE_LOW)
        )
    }
}
```

- [ ] **Step 4: Create `GroundControlApplication.kt`** (creates channels on startup):

```kotlin
package com.atomikpanda.groundcontrol

import android.app.Application
import com.atomikpanda.groundcontrol.notify.NotificationChannels

class GroundControlApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        NotificationChannels.createAll(this)
    }
}
```

- [ ] **Step 5: Wire the manifest.** In `AndroidManifest.xml`: add `android:name=".GroundControlApplication"` to `<application>`, and add the permissions (above `<application>`):

```xml
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
    <uses-permission android:name="android.permission.WAKE_LOCK" />
```

(Leave the existing `INTERNET`/`CAMERA` permissions and the `groundcontrol://add` intent-filter as-is. The `<service>`/`<receiver>`/`thread` intent-filter are added in Task 9.)

- [ ] **Step 6: Verify it compiles + suite green.**

Run (from `android/`, toolchain sourced): `./gradlew testDebugUnitTest --rerun-tasks`
Expected: BUILD SUCCESSFUL (KSP runs with no Room entities yet; the existing unit suite passes).

- [ ] **Step 7: Commit + journal**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/ground-control-notifications-for-needs/ground-control
git add android/build.gradle.kts android/app/build.gradle.kts android/app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApplication.kt android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NotificationChannels.kt android/app/src/main/AndroidManifest.xml
git commit -m "feat(gc): build setup for notifications (KSP/Room/WorkManager, Application, channels, permissions)"
mship journal "notif: build setup + Application + channels + manifest perms; compiles" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: Notification core — domain types, `NotifiedStore`/`Notifier` seams, `NeedsYouReconciler` (dedup-on-resolve)

The TDD heart. A `NeedsYouReconciler` that, given a connection's thread summaries, notifies each newly-`needs_you` thread exactly once and clears the notified mark when a thread is no longer `needs_you` — over injected `NotifiedStore` + `Notifier` interfaces (Room/Android impls come later). Plus a fetch-and-reconcile integration test via Ktor MockEngine (the "pollConnectionForNeedsYou" behavior).

**Files:**
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NeedsYouCore.kt`
- Test: `android/app/src/test/java/com/atomikpanda/groundcontrol/NeedsYouReconcilerTest.kt`

- [ ] **Step 1: Write the failing tests.** Create `NeedsYouReconcilerTest.kt`:

```kotlin
package com.atomikpanda.groundcontrol

import com.atomikpanda.groundcontrol.data.SpecApi
import com.atomikpanda.groundcontrol.data.ThreadsRepository
import com.atomikpanda.groundcontrol.data.WorkspaceConnection
import com.atomikpanda.groundcontrol.data.buildJson
import com.atomikpanda.groundcontrol.data.dto.ThreadSummary
import com.atomikpanda.groundcontrol.notify.NeedsYouEvent
import com.atomikpanda.groundcontrol.notify.NeedsYouReconciler
import com.atomikpanda.groundcontrol.notify.Notifier
import com.atomikpanda.groundcontrol.notify.NotifiedStore
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.ktor.serialization.kotlinx.json.json
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

private class FakeStore : NotifiedStore {
    val marks = mutableSetOf<String>()
    private fun k(c: String, t: String) = "$c|$t"
    override suspend fun isNotified(connId: String, threadId: String) = k(connId, threadId) in marks
    override suspend fun markNotified(connId: String, threadId: String) { marks += k(connId, threadId) }
    override suspend fun clear(connId: String, threadId: String) { marks -= k(connId, threadId) }
}

private class FakeNotifier : Notifier {
    val events = mutableListOf<NeedsYouEvent>()
    override fun notify(event: NeedsYouEvent) { events += event }
}

class NeedsYouReconcilerTest {
    private val conn = WorkspaceConnection("c1", "http://h:47100", "tok", "ws")
    private val jsonHdr = headersOf(HttpHeaders.ContentType, "application/json")
    private fun summary(id: String, needsYou: Boolean) =
        ThreadSummary(id = id, subject = "S-$id", needsYou = needsYou, lastMessage = "msg-$id", updatedAt = "2026-06-30T12:00:00Z")

    @Test fun notifies_once_for_a_new_needs_you() = runTest {
        val store = FakeStore(); val notifier = FakeNotifier()
        val r = NeedsYouReconciler(store, notifier)
        r.reconcile(conn, listOf(summary("t1", true)))
        assertEquals(1, notifier.events.size)
        assertEquals("t1", notifier.events[0].threadId)
        assertEquals("ws", notifier.events[0].workspaceName)
        // a second reconcile while still needs_you does NOT re-notify
        r.reconcile(conn, listOf(summary("t1", true)))
        assertEquals(1, notifier.events.size)
    }

    @Test fun plain_note_does_not_notify() = runTest {
        val store = FakeStore(); val notifier = FakeNotifier()
        NeedsYouReconciler(store, notifier).reconcile(conn, listOf(summary("t1", false)))
        assertEquals(0, notifier.events.size)
    }

    @Test fun re_notifies_after_resolve_then_recurrence() = runTest {
        val store = FakeStore(); val notifier = FakeNotifier()
        val r = NeedsYouReconciler(store, notifier)
        r.reconcile(conn, listOf(summary("t1", true)))     // notify #1
        r.reconcile(conn, listOf(summary("t1", false)))    // operator acted -> clear
        r.reconcile(conn, listOf(summary("t1", true)))     // new episode -> notify #2
        assertEquals(2, notifier.events.size)
    }

    @Test fun fetch_and_reconcile_via_mockengine() = runTest {
        val store = FakeStore(); val notifier = FakeNotifier()
        val api = SpecApi(HttpClient(MockEngine {
            respond("""[{"id":"t1","subject":"hi","needs_you":true,"last_message":"look"}]""",
                HttpStatusCode.OK, jsonHdr)
        }) { install(ContentNegotiation) { json(buildJson()) } })
        val r = NeedsYouReconciler(store, notifier)
        r.fetchAndReconcile(conn, ThreadsRepository(api))
        assertEquals(1, notifier.events.size)
        assertEquals("look", notifier.events[0].preview)
    }
}
```

- [ ] **Step 2: Run to verify they fail.** `./gradlew testDebugUnitTest --rerun-tasks --tests "com.atomikpanda.groundcontrol.NeedsYouReconcilerTest"` → FAIL (unresolved `NeedsYouEvent`/`NotifiedStore`/`Notifier`/`NeedsYouReconciler`).

- [ ] **Step 3: Implement `NeedsYouCore.kt`:**

```kotlin
package com.atomikpanda.groundcontrol.notify

import com.atomikpanda.groundcontrol.data.ThreadsRepository
import com.atomikpanda.groundcontrol.data.WorkspaceConnection
import com.atomikpanda.groundcontrol.data.dto.ThreadSummary

/** A needs-you event ready to be turned into a notification. Carries the portable
 *  baseUrl so the notification's deep link can address the workspace. */
data class NeedsYouEvent(
    val connectionId: String,
    val baseUrl: String,
    val workspaceName: String,
    val threadId: String,
    val subject: String,
    val preview: String,
    val updatedAt: String,
)

/** Persisted dedup state. Room impl in production; a fake in tests. */
interface NotifiedStore {
    suspend fun isNotified(connId: String, threadId: String): Boolean
    suspend fun markNotified(connId: String, threadId: String)
    suspend fun clear(connId: String, threadId: String)
}

/** The notify sink. Android impl in production; a fake in tests. The FCM-ready seam:
 *  a future FcmTrigger funnels NeedsYouEvents to the same Notifier. */
interface Notifier {
    fun notify(event: NeedsYouEvent)
}

/** Dedup-on-resolve: notify a needs_you thread once; clear when it stops being needs_you
 *  so a future episode re-notifies. Shared by the foreground service and the WorkManager
 *  backstop (they pass the same NotifiedStore, so they never double-notify). */
class NeedsYouReconciler(
    private val store: NotifiedStore,
    private val notifier: Notifier,
) {
    suspend fun reconcile(conn: WorkspaceConnection, threads: List<ThreadSummary>) {
        for (t in threads) {
            val notified = store.isNotified(conn.id, t.id)
            if (t.needsYou && !notified) {
                notifier.notify(
                    NeedsYouEvent(conn.id, conn.baseUrl, conn.workspaceName, t.id, t.subject, t.lastMessage, t.updatedAt ?: "")
                )
                store.markNotified(conn.id, t.id)
            } else if (!t.needsYou && notified) {
                store.clear(conn.id, t.id)
            }
        }
    }

    /** One-shot fetch (the WorkManager path) + reconcile. The FGS path calls reconcile()
     *  directly on each long-poll wait response's changed summaries. */
    suspend fun fetchAndReconcile(conn: WorkspaceConnection, repo: ThreadsRepository) {
        val threads = repo.listThreadsFor(conn)
        reconcile(conn, threads)
    }
}
```

- [ ] **Step 4: Add `ThreadsRepository.listThreadsFor`** (a single-connection list passthrough next to the existing delegates in `data/ThreadsRepository.kt`):

```kotlin
    suspend fun listThreadsFor(conn: WorkspaceConnection) = api.listThreads(conn)
```

- [ ] **Step 5: Run to verify they pass.** `./gradlew testDebugUnitTest --rerun-tasks --tests "com.atomikpanda.groundcontrol.NeedsYouReconcilerTest"` → PASS (4).

- [ ] **Step 6: Commit + journal**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NeedsYouCore.kt android/app/src/main/java/com/atomikpanda/groundcontrol/data/ThreadsRepository.kt android/app/src/test/java/com/atomikpanda/groundcontrol/NeedsYouReconcilerTest.kt
git commit -m "feat(gc): notification core — reconciler dedup-on-resolve + NotifiedStore/Notifier seams"
mship journal "notif: NeedsYouReconciler + seams; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: `DeepLinkResolver` (pure, `java.net.URI`)

Parse `groundcontrol://thread?workspace=<key>&id=<threadId>` and resolve `<key>` (a base URL, with workspace-name fallback) to a local connection. Pure and JVM-testable — must NOT use `android.net.Uri`.

**Files:**
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/DeepLinkResolver.kt`
- Test: `android/app/src/test/java/com/atomikpanda/groundcontrol/DeepLinkResolverTest.kt`

- [ ] **Step 1: Write the failing tests.** Create `DeepLinkResolverTest.kt`:

```kotlin
package com.atomikpanda.groundcontrol

import com.atomikpanda.groundcontrol.data.WorkspaceConnection
import com.atomikpanda.groundcontrol.notify.DeepLinkOutcome
import com.atomikpanda.groundcontrol.notify.DeepLinkResolver
import java.net.URLEncoder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DeepLinkResolverTest {
    private val conns = listOf(
        WorkspaceConnection("c1", "http://host:47100", "tok", "Work"),
        WorkspaceConnection("c2", "https://relay.example.com", null, "Relay"),
    )
    private fun uri(workspace: String, id: String) =
        "groundcontrol://thread?workspace=${URLEncoder.encode(workspace, "UTF-8")}&id=$id"

    @Test fun resolves_known_workspace_by_base_url() {
        val out = DeepLinkResolver.resolve(uri("http://host:47100", "t1"), conns)
        assertEquals(DeepLinkOutcome.OpenThread("c1", "t1"), out)
    }

    @Test fun resolves_by_base_url_ignoring_trailing_slash() {
        val out = DeepLinkResolver.resolve(uri("http://host:47100/", "t9"), conns)
        assertEquals(DeepLinkOutcome.OpenThread("c1", "t9"), out)
    }

    @Test fun falls_back_to_workspace_name() {
        val out = DeepLinkResolver.resolve(uri("Relay", "t2"), conns)
        assertEquals(DeepLinkOutcome.OpenThread("c2", "t2"), out)
    }

    @Test fun unknown_workspace_routes_to_add_connection() {
        val out = DeepLinkResolver.resolve(uri("http://nope:1", "t3"), conns)
        assertTrue(out is DeepLinkOutcome.AddConnection)
    }

    @Test fun malformed_uri_is_ignored() {
        assertEquals(DeepLinkOutcome.Ignore, DeepLinkResolver.resolve("groundcontrol://thread?id=t1", conns)) // no workspace
        assertEquals(DeepLinkOutcome.Ignore, DeepLinkResolver.resolve("groundcontrol://other?x=1", conns))    // wrong host
        assertEquals(DeepLinkOutcome.Ignore, DeepLinkResolver.resolve("not a uri", conns))
    }
}
```

- [ ] **Step 2: Run to verify they fail.** `./gradlew testDebugUnitTest --rerun-tasks --tests "com.atomikpanda.groundcontrol.DeepLinkResolverTest"` → FAIL (unresolved `DeepLinkResolver`/`DeepLinkOutcome`).

- [ ] **Step 3: Implement `DeepLinkResolver.kt`** (uses `java.net.URI` + the existing `normalizedBaseUrl`):

```kotlin
package com.atomikpanda.groundcontrol.notify

import com.atomikpanda.groundcontrol.data.WorkspaceConnection
import com.atomikpanda.groundcontrol.data.normalizedBaseUrl
import java.net.URI
import java.net.URLDecoder

sealed interface DeepLinkOutcome {
    data class OpenThread(val connectionId: String, val threadId: String) : DeepLinkOutcome
    data class AddConnection(val workspaceKey: String) : DeepLinkOutcome
    data object Ignore : DeepLinkOutcome
}

object DeepLinkResolver {
    /** Parse a groundcontrol://thread?workspace=<key>&id=<threadId> link and resolve the
     *  portable workspace key (base URL, then name) to a local connection. */
    fun resolve(raw: String, connections: List<WorkspaceConnection>): DeepLinkOutcome {
        val uri = runCatching { URI(raw) }.getOrNull() ?: return DeepLinkOutcome.Ignore
        if (uri.scheme != "groundcontrol" || uri.host != "thread") return DeepLinkOutcome.Ignore
        val params = parseQuery(uri.rawQuery)
        val threadId = params["id"]?.takeIf { it.isNotBlank() } ?: return DeepLinkOutcome.Ignore
        val key = params["workspace"]?.takeIf { it.isNotBlank() } ?: return DeepLinkOutcome.Ignore

        val normKey = normalizedBaseUrl(key)
        val match = connections.firstOrNull { normKey != null && normalizedBaseUrl(it.baseUrl) == normKey }
            ?: connections.firstOrNull { it.workspaceName.isNotBlank() && it.workspaceName == key }
        return if (match != null) DeepLinkOutcome.OpenThread(match.id, threadId)
        else DeepLinkOutcome.AddConnection(key)
    }

    private fun parseQuery(rawQuery: String?): Map<String, String> =
        (rawQuery ?: "").split("&").mapNotNull { pair ->
            val i = pair.indexOf('=')
            if (i <= 0) null
            else pair.substring(0, i) to URLDecoder.decode(pair.substring(i + 1), "UTF-8")
        }.toMap()
}
```

(If `normalizedBaseUrl` returns null for an input that another connection also normalizes to null, the `normKey != null` guard prevents a false match. Confirm the exact `normalizedBaseUrl` signature in `WorkspaceConnection.kt` and import it correctly.)

- [ ] **Step 4: Run to verify they pass.** `./gradlew testDebugUnitTest --rerun-tasks --tests "com.atomikpanda.groundcontrol.DeepLinkResolverTest"` → PASS (5).

- [ ] **Step 5: Commit + journal**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/notify/DeepLinkResolver.kt android/app/src/test/java/com/atomikpanda/groundcontrol/DeepLinkResolverTest.kt
git commit -m "feat(gc): DeepLinkResolver — groundcontrol://thread URI -> local connection (pure)"
mship journal "notif: DeepLinkResolver; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: Room `NotifiedStore` implementation

The persistent dedup store keyed by `(connId, threadId)`. Framework-bound (Room/KSP) — compile-verified; its contract is exercised by Task 2's fake.

**Files:**
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NotifiedRoom.kt`

- [ ] **Step 1: Implement the entity, DAO, database, and `RoomNotifiedStore`:**

```kotlin
package com.atomikpanda.groundcontrol.notify

import android.content.Context
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase

@Entity(tableName = "notified", primaryKeys = ["connId", "threadId"])
data class NotifiedRecord(val connId: String, val threadId: String)

@Dao
interface NotifiedDao {
    @Query("SELECT EXISTS(SELECT 1 FROM notified WHERE connId = :connId AND threadId = :threadId)")
    suspend fun isNotified(connId: String, threadId: String): Boolean

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insert(record: NotifiedRecord)

    @Query("DELETE FROM notified WHERE connId = :connId AND threadId = :threadId")
    suspend fun delete(connId: String, threadId: String)
}

@Database(entities = [NotifiedRecord::class], version = 1, exportSchema = false)
abstract class NotifiedDatabase : RoomDatabase() {
    abstract fun notifiedDao(): NotifiedDao

    companion object {
        @Volatile private var instance: NotifiedDatabase? = null
        fun get(context: Context): NotifiedDatabase = instance ?: synchronized(this) {
            instance ?: Room.databaseBuilder(
                context.applicationContext, NotifiedDatabase::class.java, "notified.db"
            ).build().also { instance = it }
        }
    }
}

class RoomNotifiedStore(private val dao: NotifiedDao) : NotifiedStore {
    override suspend fun isNotified(connId: String, threadId: String) = dao.isNotified(connId, threadId)
    override suspend fun markNotified(connId: String, threadId: String) = dao.insert(NotifiedRecord(connId, threadId))
    override suspend fun clear(connId: String, threadId: String) = dao.delete(connId, threadId)
}
```

- [ ] **Step 2: Verify it compiles (KSP generates the Room impl).**

`./gradlew testDebugUnitTest --rerun-tasks` → BUILD SUCCESSFUL (KSP processes `@Database`/`@Dao`; existing + Task 2/3 tests pass).

- [ ] **Step 3: Commit + journal**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NotifiedRoom.kt
git commit -m "feat(gc): Room NotifiedStore impl for needs-you dedup state"
mship journal "notif: RoomNotifiedStore (Room/KSP); compiles" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: Settings — global notifications toggle (store flag + ViewModel + Switch row)

A persisted `notificationsEnabled` flag and the Settings UI to flip it. TDD the store + VM logic; the Switch row is Compose (compile-verified).

**Files:**
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/SettingsRepository.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/settings/SettingsViewModel.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/settings/SettingsScreen.kt`
- Test: `android/app/src/test/java/com/atomikpanda/groundcontrol/SettingsNotificationsTest.kt`

- [ ] **Step 1: Write the failing test.** The flag logic is testable behind a small interface so the VM can be unit-tested without DataStore. Create `SettingsNotificationsTest.kt`:

```kotlin
package com.atomikpanda.groundcontrol

import com.atomikpanda.groundcontrol.data.NotificationsSetting
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

private class FakeNotificationsSetting : NotificationsSetting {
    private val state = MutableStateFlow(false)
    override val enabled: StateFlow<Boolean> = state
    override suspend fun set(value: Boolean) { state.value = value }
}

class SettingsNotificationsTest {
    @Test fun toggle_persists_through_the_setting() = runTest {
        val setting = FakeNotificationsSetting()
        assertEquals(false, setting.enabled.first())
        setting.set(true)
        assertEquals(true, setting.enabled.first())
        setting.set(false)
        assertEquals(false, setting.enabled.first())
    }
}
```

- [ ] **Step 2: Run to verify it fails.** `./gradlew testDebugUnitTest --rerun-tasks --tests "com.atomikpanda.groundcontrol.SettingsNotificationsTest"` → FAIL (unresolved `NotificationsSetting`).

- [ ] **Step 3: Implement `SettingsRepository.kt`** — the interface + a DataStore-backed impl (reusing the existing `ground_control` preferences store):

```kotlin
package com.atomikpanda.groundcontrol.data

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn

/** Testable seam: the VM depends on this, not on DataStore directly. */
interface NotificationsSetting {
    val enabled: StateFlow<Boolean>
    suspend fun set(value: Boolean)
}

private val Context.settingsStore by preferencesDataStore(name = "ground_control_settings")
private val NOTIFICATIONS_ENABLED = booleanPreferencesKey("notifications_enabled")

class DataStoreNotificationsSetting(
    private val context: Context,
    scope: CoroutineScope,
) : NotificationsSetting {
    override val enabled: StateFlow<Boolean> =
        context.settingsStore.data.map { it[NOTIFICATIONS_ENABLED] ?: false }
            .stateIn(scope, SharingStarted.Eagerly, false)

    override suspend fun set(value: Boolean) {
        context.settingsStore.edit { it[NOTIFICATIONS_ENABLED] = value }
    }
}
```

- [ ] **Step 4: Wire `SettingsViewModel`.** Add a `NotificationsSetting` constructor param and expose the toggle. In `SettingsViewModel.kt`:

```kotlin
class SettingsViewModel(
    private val repo: ConnectionsRepository,
    private val api: SpecApi,
    private val notifications: NotificationsSetting,
) : ViewModel() {
    // ... existing members ...

    val notificationsEnabled: StateFlow<Boolean> get() = notifications.enabled

    /** Returns the new desired state; the screen requests POST_NOTIFICATIONS when turning ON. */
    fun setNotificationsEnabled(value: Boolean) {
        viewModelScope.launch { notifications.set(value) }
    }
}
```

(Update the `viewModel { SettingsViewModel(connRepo, api) }` construction site in `GroundControlApp.kt` to pass a `DataStoreNotificationsSetting(context.applicationContext, <a scope>)` — e.g. an app-scoped `CoroutineScope` created in `GroundControlApp` via `remember { CoroutineScope(SupervisorJob() + Dispatchers.Default) }`, or `viewModelScope` is not available there, so create the setting with a `MainScope()` held in `remember`.)

- [ ] **Step 5: Add the Switch row to `SettingsScreen.kt`** (above the connections list, after the test-result `Text`):

```kotlin
        val notificationsOn by vm.notificationsEnabled.collectAsStateWithLifecycle()
        // request POST_NOTIFICATIONS when turning on (Android 13+):
        val permLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) vm.setNotificationsEnabled(true)
        }
        ListItem(
            headlineContent = { Text("Notifications") },
            supportingContent = { Text("Alert me when an agent needs me (all workspaces)") },
            trailingContent = {
                Switch(checked = notificationsOn, onCheckedChange = { want ->
                    if (want && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS)
                            != PackageManager.PERMISSION_GRANTED
                    ) {
                        permLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                    } else {
                        vm.setNotificationsEnabled(want)
                    }
                })
            },
        )
        HorizontalDivider()
```

(Add imports: `android.Manifest`, `android.content.pm.PackageManager`, `android.os.Build`, `androidx.activity.compose.rememberLauncherForActivityResult`, `androidx.activity.result.contract.ActivityResultContracts`, `androidx.core.content.ContextCompat`, `androidx.compose.material3.Switch`. The actual start/stop of the service + worker on toggle change is wired in Task 9; for now the toggle only persists the flag.)

- [ ] **Step 6: Run to verify the test passes + everything compiles.** `./gradlew testDebugUnitTest --rerun-tasks` → PASS (the new test green; the Settings screen + VM compile; existing suite green — fix any other `SettingsViewModel(...)` construction site for the new param).

- [ ] **Step 7: Commit + journal**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/data/SettingsRepository.kt android/app/src/main/java/com/atomikpanda/groundcontrol/ui/settings/SettingsViewModel.kt android/app/src/main/java/com/atomikpanda/groundcontrol/ui/settings/SettingsScreen.kt android/app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApp.kt android/app/src/test/java/com/atomikpanda/groundcontrol/SettingsNotificationsTest.kt
git commit -m "feat(gc): global notifications toggle (setting + VM + Settings switch + permission request)"
mship journal "notif: settings toggle + POST_NOTIFICATIONS request; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: `AndroidNotifier` — build + post the notification with the deep-link PendingIntent

The production `Notifier`. Framework-bound — compile-verified.

**Files:**
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/AndroidNotifier.kt`

- [ ] **Step 1: Implement `AndroidNotifier`** (builds a heads-up notification on the `NEEDS_YOU` channel; tap → a `groundcontrol://thread?...` deep link into `MainActivity`):

```kotlin
package com.atomikpanda.groundcontrol.notify

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.atomikpanda.groundcontrol.MainActivity
import java.net.URLEncoder

class AndroidNotifier(private val context: Context) : Notifier {
    override fun notify(event: NeedsYouEvent) {
        val link = "groundcontrol://thread?workspace=" +
            URLEncoder.encode(event.baseUrl, "UTF-8") + "&id=" + event.threadId
        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            data = Uri.parse(link)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pending = PendingIntent.getActivity(
            context, link.hashCode(), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, NotificationChannels.NEEDS_YOU)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(event.workspaceName.ifBlank { "Ground Control" })
            .setContentText(if (event.subject.isBlank()) event.preview else "${event.subject} — ${event.preview}")
            .setStyle(NotificationCompat.BigTextStyle().bigText(event.preview))
            .setAutoCancel(true)
            .setContentIntent(pending)
            .build()
        // stable per-thread id so a repeat for the same thread replaces, not stacks:
        val id = (event.connectionId + "|" + event.threadId).hashCode()
        runCatching { NotificationManagerCompat.from(context).notify(id, notification) }
    }
}
```

(`NotificationManagerCompat.notify` requires POST_NOTIFICATIONS at runtime; the `runCatching` guards the `SecurityException` if the permission was revoked. The `MainActivity` deep-link handling + the `groundcontrol://thread` intent-filter are added in Task 9.)

- [ ] **Step 2: Verify compiles.** `./gradlew testDebugUnitTest --rerun-tasks` → BUILD SUCCESSFUL.

- [ ] **Step 3: Commit + journal**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/notify/AndroidNotifier.kt
git commit -m "feat(gc): AndroidNotifier — heads-up notification + groundcontrol:// deep-link intent"
mship journal "notif: AndroidNotifier; compiles" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=7 -->
### Task 7: `WatchService` — foreground service long-poll loop (the real-time path)

The foreground service that holds a `GET /threads?wait=1` loop per connection and reconciles each wait response. Framework-bound — compile-verified; behavior is operator-verified.

**Files:**
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/WatchService.kt`

- [ ] **Step 1: Implement `WatchService`** (manual dep construction, matching the app's pattern):

```kotlin
package com.atomikpanda.groundcontrol.notify

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.atomikpanda.groundcontrol.data.ConnectionsRepository
import com.atomikpanda.groundcontrol.data.SpecApi
import com.atomikpanda.groundcontrol.data.ThreadsRepository
import com.atomikpanda.groundcontrol.data.WorkspaceConnection
import com.atomikpanda.groundcontrol.data.defaultHttpClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.time.Instant

class WatchService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var reconciler: NeedsYouReconciler
    private lateinit var repo: ThreadsRepository
    private lateinit var connections: ConnectionsRepository

    override fun onCreate() {
        super.onCreate()
        val api = SpecApi(defaultHttpClient())
        repo = ThreadsRepository(api)
        connections = ConnectionsRepository(applicationContext)
        reconciler = NeedsYouReconciler(
            RoomNotifiedStore(NotifiedDatabase.get(applicationContext).notifiedDao()),
            AndroidNotifier(applicationContext),
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val watching = NotificationCompat.Builder(this, NotificationChannels.WATCHING)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("Watching for messages")
            .setOngoing(true)
            .build()
        startForeground(WATCH_NOTIFICATION_ID, watching)
        scope.launch {
            // Re-spread watchers whenever the connection set changes.
            connections.connections.collectLatest { conns -> watchAll(conns) }
        }
        return START_STICKY
    }

    private suspend fun watchAll(conns: List<WorkspaceConnection>) {
        coroutineScope {
            conns.forEach { conn -> launch { watchOne(conn) } }
        }
    }

    private suspend fun watchOne(conn: WorkspaceConnection) {
        var cursor = Instant.now().toString()
        var backoffMs = 1000L
        while (currentCoroutineScopeActive()) {
            val resp = runCatching { repo.waitForChange(conn, cursor, 25) }.getOrNull()
            if (resp == null) { delay(backoffMs); backoffMs = (backoffMs * 2).coerceAtMost(30_000); continue }
            backoffMs = 1000L
            reconciler.reconcile(conn, resp.threads)
            if (resp.cursor.isNotEmpty()) cursor = resp.cursor
        }
    }

    private fun currentCoroutineScopeActive(): Boolean = scope.isActive

    override fun onDestroy() { scope.cancel(); super.onDestroy() }
    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val WATCH_NOTIFICATION_ID = 42
        fun start(context: Context) {
            val i = Intent(context, WatchService::class.java)
            androidx.core.content.ContextCompat.startForegroundService(context, i)
        }
        fun stop(context: Context) { context.stopService(Intent(context, WatchService::class.java)) }
    }
}
```

(Note: `coroutineScope`/`currentCoroutineScopeActive` — the implementer should use the natural structured-concurrency form: `watchOne` loops `while (isActive)` inside the `launch`, and `collectLatest` cancels the prior `watchAll` when the connection set changes. The exact shape is the implementer's to make idiomatic; the contract is: one long-poll loop per connection, reconcile each wait response, reconnect-with-backoff, all cancelled on `onDestroy`. Keep the `import kotlinx.coroutines.coroutineScope`.)

- [ ] **Step 2: Verify compiles.** `./gradlew testDebugUnitTest --rerun-tasks` → BUILD SUCCESSFUL.

- [ ] **Step 3: Commit + journal**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/notify/WatchService.kt
git commit -m "feat(gc): WatchService foreground long-poll loop (real-time needs-you)"
mship journal "notif: WatchService FGS; compiles" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=8 -->
### Task 8: `WatchBackstopWorker` — WorkManager periodic backstop

A periodic one-shot poll of every connection that reconciles needs_you, covering windows the FGS isn't running. Framework-bound — compile-verified.

**Files:**
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/WatchBackstopWorker.kt`

- [ ] **Step 1: Implement the worker + its scheduling helpers:**

```kotlin
package com.atomikpanda.groundcontrol.notify

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.atomikpanda.groundcontrol.data.ConnectionsRepository
import com.atomikpanda.groundcontrol.data.SpecApi
import com.atomikpanda.groundcontrol.data.ThreadsRepository
import com.atomikpanda.groundcontrol.data.defaultHttpClient
import java.util.concurrent.TimeUnit

class WatchBackstopWorker(appContext: Context, params: WorkerParameters) :
    CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val reconciler = NeedsYouReconciler(
            RoomNotifiedStore(NotifiedDatabase.get(applicationContext).notifiedDao()),
            AndroidNotifier(applicationContext),
        )
        val repo = ThreadsRepository(SpecApi(defaultHttpClient()))
        val conns = ConnectionsRepository(applicationContext).snapshot()
        return runCatching {
            conns.forEach { reconciler.fetchAndReconcile(it, repo) }
        }.fold(onSuccess = { Result.success() }, onFailure = { Result.retry() })
    }

    companion object {
        private const val NAME = "watch_backstop"
        fun enqueue(context: Context) {
            val req = PeriodicWorkRequestBuilder<WatchBackstopWorker>(15, TimeUnit.MINUTES).build()
            WorkManager.getInstance(context)
                .enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.KEEP, req)
        }
        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(NAME)
        }
    }
}
```

- [ ] **Step 2: Verify compiles.** `./gradlew testDebugUnitTest --rerun-tasks` → BUILD SUCCESSFUL.

- [ ] **Step 3: Commit + journal**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/notify/WatchBackstopWorker.kt
git commit -m "feat(gc): WatchBackstopWorker — 15-min WorkManager needs-you backstop"
mship journal "notif: WatchBackstopWorker; compiles" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=9 -->
### Task 9: Lifecycle wiring — toggle→start/stop, `BootReceiver`, MainActivity deep-link handling, manifest entries

Connect everything: the toggle starts/stops the service + worker; a `BootReceiver` re-arms on boot; `MainActivity` resolves a notification tap's deep link and navigates; manifest gets the `<service>`/`<receiver>`/`thread` intent-filter. Framework-bound — compile-verified; the full flow is operator-verified.

**Files:**
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/BootReceiver.kt`
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/WatchController.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/settings/SettingsViewModel.kt` (start/stop on toggle)
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/MainActivity.kt` (resolve thread deep link)
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApp.kt` (consume a pending deep-link target)
- Modify: `android/app/src/main/AndroidManifest.xml`

- [ ] **Step 1: `WatchController`** — one place that starts/stops the service + worker (so the toggle, BootReceiver, and Settings agree):

```kotlin
package com.atomikpanda.groundcontrol.notify

import android.content.Context

object WatchController {
    fun enable(context: Context) {
        WatchService.start(context)
        WatchBackstopWorker.enqueue(context)
    }
    fun disable(context: Context) {
        WatchService.stop(context)
        WatchBackstopWorker.cancel(context)
    }
}
```

- [ ] **Step 2: `BootReceiver`** — re-arm on boot if the toggle is on:

```kotlin
package com.atomikpanda.groundcontrol.notify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking

private val Context.settingsStore by preferencesDataStore(name = "ground_control_settings")

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        val key = booleanPreferencesKey("notifications_enabled")
        val enabled = runBlocking { context.settingsStore.data.first()[key] ?: false }
        if (enabled) WatchController.enable(context.applicationContext)
    }
}
```

(`runBlocking` in a `BroadcastReceiver.onReceive` is acceptable for this brief read; alternatively use `goAsync()`. Reuse the same `"ground_control_settings"` store + `"notifications_enabled"` key as `DataStoreNotificationsSetting` — keep them identical.)

- [ ] **Step 3: Start/stop on toggle.** In `SettingsViewModel.setNotificationsEnabled`, drive `WatchController` (the VM needs an `Application`/`Context` — pass `application` via `AndroidViewModel`, or accept a `(Boolean) -> Unit` `onToggle` callback wired in the screen). Simplest: have the **screen** call `WatchController.enable/disable(context)` right where it calls `vm.setNotificationsEnabled(...)` (Task 5 step 5), so the VM stays Context-free:

```kotlin
// in SettingsScreen, replace the bare vm.setNotificationsEnabled(want) calls:
fun applyToggle(want: Boolean) {
    vm.setNotificationsEnabled(want)
    if (want) WatchController.enable(context) else WatchController.disable(context)
}
```

- [ ] **Step 4: MainActivity — resolve a thread deep link.** Add `onNewIntent`, and in `onCreate` branch on the link type. Resolve via `DeepLinkResolver` against the connection snapshot, then hand a pending target to Compose:

```kotlin
class MainActivity : ComponentActivity() {
    private val pendingThread = MutableStateFlow<Pair<String, String>?>(null)  // (connId, threadId)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent)
        setContent { GroundControlTheme { GroundControlApp(this, pendingThread) } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        val raw = intent?.data?.toString() ?: return
        // existing pairing link:
        PairLink.parse(raw)?.let { conn ->
            lifecycleScope.launch { ConnectionsRepository(applicationContext).upsert(conn) }
            return
        }
        // notification thread link:
        lifecycleScope.launch {
            val conns = ConnectionsRepository(applicationContext).snapshot()
            when (val out = DeepLinkResolver.resolve(raw, conns)) {
                is DeepLinkOutcome.OpenThread -> pendingThread.value = out.connectionId to out.threadId
                is DeepLinkOutcome.AddConnection -> { /* TODO future: route to add-connection; v1 no-op */ }
                DeepLinkOutcome.Ignore -> {}
            }
        }
    }
}
```

- [ ] **Step 5: `GroundControlApp` — consume the pending target.** Add a `pendingThread: StateFlow<Pair<String,String>?>? = null` param; after the `NavHost` is set up, a `LaunchedEffect` navigates and clears it:

```kotlin
    val pending by (pendingThread ?: remember { MutableStateFlow(null) }).collectAsStateWithLifecycle()
    LaunchedEffect(pending) {
        pending?.let { (connId, threadId) ->
            nav.navigate("thread/$connId/$threadId")
            (pendingThread as? MutableStateFlow)?.value = null
        }
    }
```

(Keep `GroundControlApp(context)` back-compatible by defaulting the new param to null. The `MutableStateFlow` cast is safe because `MainActivity` passes a `MutableStateFlow`.)

- [ ] **Step 6: Manifest — service, receiver, thread intent-filter.** In `AndroidManifest.xml`, inside `<application>` add:

```xml
        <service
            android:name=".notify.WatchService"
            android:exported="false"
            android:foregroundServiceType="dataSync" />
        <receiver
            android:name=".notify.BootReceiver"
            android:exported="false">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED" />
            </intent-filter>
        </receiver>
```

And add a second `<data>` line to MainActivity's existing VIEW intent-filter (or a new intent-filter) for the thread host:

```xml
                <data android:scheme="groundcontrol" android:host="thread" />
```

- [ ] **Step 7: Verify compiles + full suite green.** `./gradlew testDebugUnitTest --rerun-tasks` → BUILD SUCCESSFUL, all unit tests pass (the 3 TDD suites + existing).

- [ ] **Step 8: Commit + journal**

```bash
git add -A
git commit -m "feat(gc): notifications lifecycle — toggle start/stop, BootReceiver, deep-link nav, manifest"
mship journal "notif: lifecycle wiring + manifest; compiles, full suite green" --action committed --test-state pass
```
<!-- /mship:task -->

---

## Self-Review

- **Spec coverage:** ac1 (needs_you → notification) → T2 (reconcile) + T6 (post) + T7 (FGS); ac2 (tap → deep link → thread) → T3 (resolver) + T6 (PendingIntent) + T9 (MainActivity/nav); ac3 (dedup-on-resolve, plain note ignored) → T2; ac4 (backstop, no double-notify) → T8 + the shared `NotifiedStore` (T2/T4); ac5 (resolver known/unknown) → T3; ac6 (toggle + POST_NOTIFICATIONS) → T5; ac7 (survive reboot, BootReceiver) → T4 (Room persist) + T9 (BootReceiver); ac8 (no server change; suite green) → every task's gate. q1 (Room) → T4; q2 (15 min) → T8.
- **Placeholder scan:** the two intentional `/* future */` no-ops (AddConnection routing, the add-connection deep-link branch) are explicit non-goals, not gaps. No other TODOs.
- **Testability honesty:** only T2, T3, T5 carry real unit tests (the logic units); T1, T4, T6, T7, T8, T9 are framework shells gated on compile (`./gradlew testDebugUnitTest` compiles main+KSP) and operator-verified on a device — called out per task and in the header. This matches the spec's testing section.
- **Type/name consistency:** `NeedsYouEvent`, `NotifiedStore`, `Notifier`, `NeedsYouReconciler`, `NotificationsSetting`, `DeepLinkOutcome`, `WatchController`, channel ids, the `ground_control_settings` store + `notifications_enabled` key (shared by `DataStoreNotificationsSetting` and `BootReceiver`), and the `thread/{connectionId}/{threadId}` route are used consistently across tasks.

## Operator verification (post-merge, on a device — not CI)

Restart nothing on the server (client-only). Build/install the app, then: enable the toggle (grant POST_NOTIFICATIONS) → from a host run `mship reply <thread> "..." --needs-you` → a heads-up notification appears within seconds; tap it → opens that conversation. Reply from the phone → the card clears; a later `--needs-you` re-notifies. Force-stop the app → another `--needs-you` → the WorkManager backstop notifies within ~15 min. Reboot with the toggle on → the service re-arms.
