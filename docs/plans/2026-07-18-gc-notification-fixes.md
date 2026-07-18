# Ground Control notification fixes (#378 + #379) Implementation Plan

REQUIRED SUB-SKILL: test-driven-development

This single PR intentionally closes BOTH issue #378 (notifications pop for the open/foregrounded thread and aren't cleared once viewed) and issue #379 (decision-option buttons show the full option text and overflow). They are fixed together because both touch the SAME files — `AndroidNotifier.kt` (notifId derivation + option-action rendering) and `NeedsYouCore.kt` (the reconciler) — and share the same `connId|threadId` notification-id derivation. Splitting them into two PRs would guarantee a merge conflict in those files, so they are bundled here.

## Goal
- #379: Keep the POSTED decision choice (`EXTRA_OPTION_TEXT`) as the FULL option text (so an Android/Watch quick-reply still sends the correct full choice), but shorten only the VISIBLE button label to ~1-3 words with an ellipsis, and render the full option list into the notification's MessagingStyle body so the reader can still see the full choices.
- #378: Suppress `notifier.notify(...)` for the thread that is currently open in the foreground, and proactively cancel a thread's notification (by the same deterministic notifId it was posted under) when that thread is opened/viewed.
- All DECISION LOGIC (button short-label, options body, suppression predicate, notifId derivation) lives in pure, JVM-unit-tested functions. Android-framework surfaces that cannot be JVM-unit-tested (the `AndroidNotifier` render call, the `NotificationManagerCompat.cancel` call, the Service/Worker wiring, and the Compose lifecycle observer) are kept as THIN wrappers around those tested pure functions.

## Architecture
- **Pure helpers (tested)** in `notify/NotificationFormat.kt`: `threadKey`, `needsYouNotificationId`, `optionButtonLabel`, `decisionOptionsBody`, `shouldSuppressNotification`.
- **`OpenThreadRegistry` (tested)**: a process-wide singleton (pure kotlinx `MutableStateFlow<String?>`) holding the `threadKey` of the currently open+foregrounded thread. Written by the conversation screen's RESUME/PAUSE lifecycle; read by the reconciler (which runs in `WatchService`/`WatchBackstopWorker` in the same process).
- **`NeedsYouCanceller` (interface tested via a fake; Android impl is thin glue)**: `cancel(connId, threadId)` → `NotificationManagerCompat.cancel(needsYouNotificationId(...))`.
- **Reconciler (tested)**: gains an injected `foregroundThreadKey: () -> String?` (default `{ null }`) and calls `shouldSuppressNotification(...)` before notifying.
- **Thin untested glue**: `AndroidNotifier.render` wiring, `AndroidNeedsYouCanceller`, `WatchService`/`WatchBackstopWorker` construction, `ConversationScreen` `LifecycleResumeEffect`, `GroundControlApp` canceller injection.

## Tech Stack
Android / Kotlin / Jetpack Compose. Tests: JUnit4 + kotlinx-coroutines-test (`runTest`) + Ktor `MockEngine` (matching existing `NotificationFormatTest`, `NeedsYouReconcilerTest`, `ConversationViewModelTest`). Test runner: `source ~/toolchains/android-env.sh && ./gradlew --offline testDebugUnitTest` from `.worktrees/gc-notification-fixes/ground-control/android`. Pure Compose UI is not unit-tested; all testable logic stays in pure functions / the ViewModel.

## File Structure

| File | Change | What |
|------|--------|------|
| `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NotificationFormat.kt` | Modify | Add `threadKey`, `needsYouNotificationId`, `optionButtonLabel`, `decisionOptionsBody`, `shouldSuppressNotification` (pure) |
| `android/app/src/test/java/com/atomikpanda/groundcontrol/NotificationFormatTest.kt` | Modify | Tests for all five new pure helpers |
| `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/OpenThreadRegistry.kt` | Create | Process-wide open+foregrounded-thread signal |
| `android/app/src/test/java/com/atomikpanda/groundcontrol/OpenThreadRegistryTest.kt` | Create | Tests for open/close/compareAndSet/snapshot |
| `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NeedsYouCanceller.kt` | Create | `NeedsYouCanceller` interface + `NoopNeedsYouCanceller` + `AndroidNeedsYouCanceller` |
| `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/AndroidNotifier.kt` | Modify | Use `needsYouNotificationId`; short button label; options body in MessagingStyle |
| `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NeedsYouCore.kt` | Modify | Reconciler `foregroundThreadKey` param + suppression |
| `android/app/src/test/java/com/atomikpanda/groundcontrol/NeedsYouReconcilerTest.kt` | Modify | Suppression tests |
| `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/WatchService.kt` | Modify | Inject `foregroundThreadKey = { OpenThreadRegistry.snapshot() }` |
| `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/WatchBackstopWorker.kt` | Modify | Inject `foregroundThreadKey = { OpenThreadRegistry.snapshot() }` |
| `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/ConversationViewModel.kt` | Modify | `canceller` param, expose `connectionId`/`threadId`, cancel on view |
| `android/app/src/test/java/com/atomikpanda/groundcontrol/ConversationViewModelTest.kt` | Modify | Cancel-on-view tests |
| `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/ConversationScreen.kt` | Modify | `LifecycleResumeEffect` → `OpenThreadRegistry` |
| `android/app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApp.kt` | Modify | Construct `AndroidNeedsYouCanceller`, pass to `ConversationViewModel` |

Throughout, the worktree base is `/home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control`.

---

<!-- mship:task id=1 -->
## Task 1 — Pure: extract the shared notifId derivation (`threadKey` + `needsYouNotificationId`)

This is the single source of truth used by BOTH the notifier (post) and the canceller (cancel), so #378's cancel always targets the exact id #379's notifier posts under.

**Files**
- `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NotificationFormat.kt`
- `android/app/src/test/java/com/atomikpanda/groundcontrol/NotificationFormatTest.kt`

### Step 1 — Write the failing test
Add these imports to the top of `NotificationFormatTest.kt` (with the existing imports):
```kotlin
import com.atomikpanda.groundcontrol.notify.needsYouNotificationId
import com.atomikpanda.groundcontrol.notify.threadKey
import org.junit.Assert.assertNotEquals
```
Add these methods inside the `NotificationFormatTest` class:
```kotlin
    // --- notification id / thread key (shared by post + cancel, #378) ---------

    @Test fun thread_key_is_conn_pipe_thread() {
        assertEquals("c1|t1", threadKey("c1", "t1"))
    }

    @Test fun needs_you_notification_id_matches_the_legacy_derivation() {
        // Must equal the exact string hash AndroidNotifier posted under before extraction,
        // so a cancel keyed by the same id dismisses the same notification.
        assertEquals(("c1" + "|" + "t1").hashCode(), needsYouNotificationId("c1", "t1"))
        assertEquals("c1|t1".hashCode(), needsYouNotificationId("c1", "t1"))
    }

    @Test fun needs_you_notification_id_is_distinct_per_thread_and_connection() {
        assertNotEquals(needsYouNotificationId("c1", "t1"), needsYouNotificationId("c1", "t2"))
        assertNotEquals(needsYouNotificationId("c1", "t1"), needsYouNotificationId("c2", "t1"))
    }
```

### Step 2 — Run to fail
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control/android && source ~/toolchains/android-env.sh && ./gradlew --offline testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.NotificationFormatTest'
```
Expect a compile failure (unresolved `threadKey` / `needsYouNotificationId`) — this is the red state.

### Step 3 — Implement
Append to `NotificationFormat.kt` (after `stripMarkdownForNotification`):
```kotlin
/**
 * Deterministic key for a (connection, thread) pair — the single source of truth shared by the
 * notification-id derivation, the open-thread suppression signal, and the cancel-on-view path so
 * "post" and "cancel" always agree. Same `connId|threadId` string used since the first notifier.
 */
fun threadKey(connId: String, threadId: String): String = "$connId|$threadId"

/**
 * Stable notification id for a needs-you thread (#378). Both [com.atomikpanda.groundcontrol.notify
 * .AndroidNotifier] (post) and [com.atomikpanda.groundcontrol.notify.AndroidNeedsYouCanceller]
 * (cancel-on-view) derive the id through this one helper so a thread's notification can always be
 * cancelled by the same id it was posted under.
 */
fun needsYouNotificationId(connId: String, threadId: String): Int = threadKey(connId, threadId).hashCode()
```

### Step 4 — Run to pass
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control/android && source ~/toolchains/android-env.sh && ./gradlew --offline testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.NotificationFormatTest'
```

### Step 5 — Commit
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control add android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NotificationFormat.kt android/app/src/test/java/com/atomikpanda/groundcontrol/NotificationFormatTest.kt
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control commit -m "Extract shared needsYou notifId derivation (threadKey/needsYouNotificationId)" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "Pure threadKey + needsYouNotificationId shared by post/cancel" --task gc-notification-fixes --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
## Task 2 — Pure: `optionButtonLabel` short label for decision buttons (#379)

**Files**
- `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NotificationFormat.kt`
- `android/app/src/test/java/com/atomikpanda/groundcontrol/NotificationFormatTest.kt`

### Step 1 — Write the failing test
Add import:
```kotlin
import com.atomikpanda.groundcontrol.notify.optionButtonLabel
```
Add methods to `NotificationFormatTest`:
```kotlin
    // --- option button short label (#379) -----------------------------------

    @Test fun option_label_keeps_a_short_single_word() {
        assertEquals("Yes", optionButtonLabel("Yes"))
    }

    @Test fun option_label_keeps_a_short_multiword_phrase() {
        assertEquals("Ship it now", optionButtonLabel("Ship it now"))
    }

    @Test fun option_label_truncates_by_word_count_with_ellipsis() {
        assertEquals("Merge the pull…", optionButtonLabel("Merge the pull request into main"))
    }

    @Test fun option_label_hard_caps_a_long_single_word() {
        val out = optionButtonLabel("Supercalifragilisticexpialidocious")
        assertTrue(out.endsWith("…"))
        assertEquals(25, out.length)  // 24-char cap + the ellipsis
    }

    @Test fun option_label_blank_in_blank_out() {
        assertEquals("", optionButtonLabel(""))
        assertEquals("", optionButtonLabel("   "))
    }

    @Test fun option_label_trims_surrounding_whitespace() {
        assertEquals("Approve", optionButtonLabel("  Approve  "))
    }
```

### Step 2 — Run to fail
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control/android && source ~/toolchains/android-env.sh && ./gradlew --offline testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.NotificationFormatTest'
```
Expect unresolved `optionButtonLabel` (red).

### Step 3 — Implement
Append to `NotificationFormat.kt`:
```kotlin
/**
 * A short, glanceable button label for a decision option (#379). The notification Action title has
 * room for only ~1-3 words; the full option text overflows and is unusable. This shortens ONLY the
 * visible label — the POSTED choice (EXTRA_OPTION_TEXT) stays the full text so a phone/Watch tap
 * still sends the correct answer. Pure: first [maxWords] words, hard-capped at [maxChars], with an
 * ellipsis whenever anything was dropped. Blank in → blank out.
 */
fun optionButtonLabel(fullText: String, maxWords: Int = 3, maxChars: Int = 24): String {
    val trimmed = fullText.trim()
    if (trimmed.isEmpty()) return ""
    val words = trimmed.split(Regex("\\s+"))
    var label = words.take(maxWords).joinToString(" ")
    var truncated = words.size > maxWords
    if (label.length > maxChars) {
        label = label.take(maxChars).trimEnd()
        truncated = true
    }
    return if (truncated) "$label…" else label
}
```

### Step 4 — Run to pass
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control/android && source ~/toolchains/android-env.sh && ./gradlew --offline testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.NotificationFormatTest'
```

### Step 5 — Commit
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control add android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NotificationFormat.kt android/app/src/test/java/com/atomikpanda/groundcontrol/NotificationFormatTest.kt
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control commit -m "Add pure optionButtonLabel short-label helper for decision buttons (#379)" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "Pure optionButtonLabel: first-N-words + char cap + ellipsis" --task gc-notification-fixes --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
## Task 3 — Pure: `decisionOptionsBody` full-options block for the MessagingStyle body (#379)

**Files**
- `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NotificationFormat.kt`
- `android/app/src/test/java/com/atomikpanda/groundcontrol/NotificationFormatTest.kt`

### Step 1 — Write the failing test
Add import:
```kotlin
import com.atomikpanda.groundcontrol.notify.decisionOptionsBody
```
Add methods to `NotificationFormatTest`:
```kotlin
    // --- full decision options rendered into the chat body (#379) ------------

    @Test fun options_body_numbers_all_options_full_text() {
        val d = Decision(options = listOf("Ship it to production now", "Hold for review"))
        assertEquals("1. Ship it to production now\n2. Hold for review", decisionOptionsBody(d))
    }

    @Test fun options_body_flags_the_recommended_option() {
        val d = Decision(options = listOf("A", "B", "C"), recommended = 1)
        assertEquals("1. A\n2. B (recommended)\n3. C", decisionOptionsBody(d))
    }

    @Test fun options_body_lists_options_even_for_multi_select() {
        val d = Decision(options = listOf("A", "B"), multi = true)
        assertEquals("1. A\n2. B", decisionOptionsBody(d))
    }

    @Test fun options_body_is_null_when_no_options_or_no_decision() {
        assertNull(decisionOptionsBody(null))
        assertNull(decisionOptionsBody(Decision(options = emptyList())))
    }
```
(`Decision`, `assertNull`, `assertTrue` are already imported in this file.)

### Step 2 — Run to fail
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control/android && source ~/toolchains/android-env.sh && ./gradlew --offline testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.NotificationFormatTest'
```
Expect unresolved `decisionOptionsBody` (red).

### Step 3 — Implement
Append to `NotificationFormat.kt`:
```kotlin
/**
 * The full decision options as a plain-text block for the notification's MessagingStyle body
 * (#379). Now that the option BUTTONS show only a short label, the reader still needs the full
 * choices somewhere legible. Numbered 1-based, the recommended option flagged. Returns null when
 * there's no decision or no options (nothing to add). Independent of `multi` — a multi-select
 * decision renders no buttons, but its options are still worth reading.
 */
fun decisionOptionsBody(decision: Decision?): String? {
    if (decision == null) return null
    val options = decision.options
    if (options.isEmpty()) return null
    val rec = decision.recommended
    return options.mapIndexed { i, opt ->
        val flag = if (rec != null && i == rec) " (recommended)" else ""
        "${i + 1}. $opt$flag"
    }.joinToString("\n")
}
```

### Step 4 — Run to pass
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control/android && source ~/toolchains/android-env.sh && ./gradlew --offline testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.NotificationFormatTest'
```

### Step 5 — Commit
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control add android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NotificationFormat.kt android/app/src/test/java/com/atomikpanda/groundcontrol/NotificationFormatTest.kt
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control commit -m "Add pure decisionOptionsBody for the full option list in the notification body (#379)" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "Pure decisionOptionsBody: numbered full options + recommended flag" --task gc-notification-fixes --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
## Task 4 — Pure: `shouldSuppressNotification` predicate (#378)

**Files**
- `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NotificationFormat.kt`
- `android/app/src/test/java/com/atomikpanda/groundcontrol/NotificationFormatTest.kt`

### Step 1 — Write the failing test
Add import:
```kotlin
import com.atomikpanda.groundcontrol.notify.shouldSuppressNotification
```
Add methods to `NotificationFormatTest`:
```kotlin
    // --- foreground open-thread suppression predicate (#378) ------------------

    @Test fun suppress_when_the_open_thread_matches() {
        assertTrue(shouldSuppressNotification(threadKey("c1", "t1"), "c1", "t1"))
    }

    @Test fun do_not_suppress_a_different_open_thread() {
        assertFalse(shouldSuppressNotification(threadKey("c1", "other"), "c1", "t1"))
    }

    @Test fun do_not_suppress_when_nothing_is_open() {
        assertFalse(shouldSuppressNotification(null, "c1", "t1"))
    }
```
(`assertFalse` is already imported.)

### Step 2 — Run to fail
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control/android && source ~/toolchains/android-env.sh && ./gradlew --offline testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.NotificationFormatTest'
```
Expect unresolved `shouldSuppressNotification` (red).

### Step 3 — Implement
Append to `NotificationFormat.kt`:
```kotlin
/**
 * Whether a needs-you notification for (connId, threadId) should be SUPPRESSED because that exact
 * thread is currently open in the foreground (#378). [openThreadKey] is the process-wide
 * open+foregrounded thread signal (see [com.atomikpanda.groundcontrol.notify.OpenThreadRegistry]),
 * or null when nothing is on screen / the app is backgrounded. Pure predicate — the reconciler
 * stays a thin caller.
 */
fun shouldSuppressNotification(openThreadKey: String?, connId: String, threadId: String): Boolean =
    openThreadKey != null && openThreadKey == threadKey(connId, threadId)
```

### Step 4 — Run to pass
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control/android && source ~/toolchains/android-env.sh && ./gradlew --offline testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.NotificationFormatTest'
```

### Step 5 — Commit
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control add android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NotificationFormat.kt android/app/src/test/java/com/atomikpanda/groundcontrol/NotificationFormatTest.kt
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control commit -m "Add pure shouldSuppressNotification open-thread predicate (#378)" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "Pure shouldSuppressNotification predicate for foreground suppression" --task gc-notification-fixes --action committed
```
<!-- /mship:task -->

<!-- mship:task id=5 -->
## Task 5 — `OpenThreadRegistry` process-wide open+foregrounded-thread signal (#378)

Pure kotlinx `MutableStateFlow` holder — JVM-unit-testable. The only untested part (the lifecycle observer that drives it) is added in Task 10.

**Files**
- `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/OpenThreadRegistry.kt` (create)
- `android/app/src/test/java/com/atomikpanda/groundcontrol/OpenThreadRegistryTest.kt` (create)

### Step 1 — Write the failing test
Create `OpenThreadRegistryTest.kt`:
```kotlin
package com.atomikpanda.groundcontrol

import com.atomikpanda.groundcontrol.notify.OpenThreadRegistry
import com.atomikpanda.groundcontrol.notify.threadKey
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

class OpenThreadRegistryTest {

    // The registry is a process-wide singleton; force it clean around each test so ordering
    // between tests can't leak an "open" thread into the next.
    private fun forceClear() {
        OpenThreadRegistry.open("_reset_", "_reset_")
        OpenThreadRegistry.close("_reset_", "_reset_")
    }

    @Before fun setUp() = forceClear()
    @After fun tearDown() = forceClear()

    @Test fun open_records_the_thread_key() {
        OpenThreadRegistry.open("c1", "t1")
        assertEquals(threadKey("c1", "t1"), OpenThreadRegistry.snapshot())
    }

    @Test fun close_matching_thread_clears_the_signal() {
        OpenThreadRegistry.open("c1", "t1")
        OpenThreadRegistry.close("c1", "t1")
        assertNull(OpenThreadRegistry.snapshot())
    }

    @Test fun close_non_matching_thread_is_a_no_op() {
        OpenThreadRegistry.open("c1", "t1")
        OpenThreadRegistry.close("c1", "other")   // stale close of a thread that isn't open
        assertEquals(threadKey("c1", "t1"), OpenThreadRegistry.snapshot())
    }

    @Test fun opening_b_then_a_late_close_of_a_keeps_b() {
        // navigate A -> B race: B.open lands, then A's late close must not wipe B.
        OpenThreadRegistry.open("c1", "B")
        OpenThreadRegistry.close("c1", "A")
        assertEquals(threadKey("c1", "B"), OpenThreadRegistry.snapshot())
    }
}
```

### Step 2 — Run to fail
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control/android && source ~/toolchains/android-env.sh && ./gradlew --offline testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.OpenThreadRegistryTest'
```
Expect unresolved `OpenThreadRegistry` (red).

### Step 3 — Implement
Create `OpenThreadRegistry.kt`:
```kotlin
package com.atomikpanda.groundcontrol.notify

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Process-wide signal for "which thread (if any) is currently open AND foregrounded" (#378).
 *
 * Written by [com.atomikpanda.groundcontrol.ui.messages.ConversationScreen]'s RESUME/PAUSE
 * lifecycle (RESUMED ⇒ that thread is on screen and the app is foregrounded); read by
 * [NeedsYouReconciler] (running in WatchService / WatchBackstopWorker in the same process) to
 * suppress a notification for the thread the user is already looking at. Holds the [threadKey]
 * string so the reconciler compares against the same derivation the notifier posts under. Uses
 * ProcessLifecycleOwner-free foreground detection: the conversation screen's own RESUMED state is
 * exactly "open + foregrounded", so no extra dependency is needed.
 */
object OpenThreadRegistry {
    private val _current = MutableStateFlow<String?>(null)
    val current: StateFlow<String?> = _current.asStateFlow()

    /** Mark (connId, threadId) as the open+foregrounded thread. */
    fun open(connId: String, threadId: String) {
        _current.value = threadKey(connId, threadId)
    }

    /**
     * Clear the open thread — but only if (connId, threadId) is still the one on record. Guards the
     * navigate-A→B race where B's RESUME (open) can land before A's PAUSE (close): a late close of A
     * must not wipe B's open.
     */
    fun close(connId: String, threadId: String) {
        _current.compareAndSet(threadKey(connId, threadId), null)
    }

    /** Snapshot for the reconciler's suppression check. */
    fun snapshot(): String? = _current.value
}
```

### Step 4 — Run to pass
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control/android && source ~/toolchains/android-env.sh && ./gradlew --offline testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.OpenThreadRegistryTest'
```

### Step 5 — Commit
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control add android/app/src/main/java/com/atomikpanda/groundcontrol/notify/OpenThreadRegistry.kt android/app/src/test/java/com/atomikpanda/groundcontrol/OpenThreadRegistryTest.kt
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control commit -m "Add OpenThreadRegistry open+foregrounded-thread signal with race-safe close (#378)" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "OpenThreadRegistry singleton + compareAndSet close, unit-tested" --task gc-notification-fixes --action committed
```
<!-- /mship:task -->

<!-- mship:task id=6 -->
## Task 6 — Wire the notifier (short button label, full text still posted, options in body) (#379)

THIN UNTESTED GLUE: `AndroidNotifier` needs a `Context`/`NotificationManagerCompat` and has no existing JVM unit test. Its correctness rests entirely on the pure functions tested in Tasks 1-3 (`needsYouNotificationId`, `optionButtonLabel`, `decisionOptionsBody`). No new unit test is added here; instead we re-run the full suite to prove the pure helpers stay green and nothing regressed.

**Files**
- `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/AndroidNotifier.kt`

### Step 1 — Implement
In `AndroidNotifier.kt`:

(a) Replace the notifId derivation on line 33:
```kotlin
        val notifId = needsYouNotificationId(event.connectionId, event.threadId)
```
(byte-identical to the previous `(event.connectionId + "|" + event.threadId).hashCode()` — behavior-preserving, now shared with the canceller.)

(b) Add the full options block to the MessagingStyle body. Immediately AFTER the `if (recent.isEmpty()) { ... } else { ... }` block (currently ending at line 69) and BEFORE the `if (errorLine != null)` block, insert:
```kotlin
        // Full option list in the chat body so the reader can still see the full choices now that
        // the option BUTTONS below show only a short label (#379).
        decisionOptionsBody(event.decision)?.let { style.addMessage(it, now, agent) }
```

(c) Shorten only the visible button label in `optionAction` (lines 108-114). Replace the body with:
```kotlin
    private fun optionAction(event: NeedsYouEvent, optionText: String): NotificationCompat.Action {
        // POST the FULL option text (EXTRA_OPTION_TEXT, via replyPendingIntent) so a phone/Watch tap
        // sends the correct full choice; only the VISIBLE label is shortened (#379).
        val pi = replyPendingIntent(event, tag = "opt_" + optionText.hashCode(), optionText = optionText, mutable = false)
        return NotificationCompat.Action.Builder(0, optionButtonLabel(optionText), pi)
            .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_NONE)
            .setShowsUserInterface(false)
            .build()
    }
```
Note: the pending-intent `tag`/discriminator still uses the FULL `optionText.hashCode()`, so distinct options keep distinct PendingIntents, and `EXTRA_OPTION_TEXT` (set inside `replyPendingIntent` from the `optionText` param) remains the full text consumed by `ReplyReceiver` (`ReplyReceiver.kt:21`).

All new symbols are in the same `notify` package — no imports needed.

### Step 2 — Run to pass (full suite; no new test, prove no regression)
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control/android && source ~/toolchains/android-env.sh && ./gradlew --offline testDebugUnitTest
```

### Step 3 — Commit
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control add android/app/src/main/java/com/atomikpanda/groundcontrol/notify/AndroidNotifier.kt
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control commit -m "Notifier: short decision-button labels + full options in body, full text still posted (#379)" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "AndroidNotifier wired to optionButtonLabel/decisionOptionsBody/needsYouNotificationId (thin glue)" --task gc-notification-fixes --action committed
```
<!-- /mship:task -->

<!-- mship:task id=7 -->
## Task 7 — Reconciler foreground suppression (#378)

JVM-testable via `FakeStore`/`FakeNotifier` (already in `NeedsYouReconcilerTest`).

**Files**
- `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NeedsYouCore.kt`
- `android/app/src/test/java/com/atomikpanda/groundcontrol/NeedsYouReconcilerTest.kt`

### Step 1 — Write the failing test
Add this import to `NeedsYouReconcilerTest.kt`:
```kotlin
import com.atomikpanda.groundcontrol.notify.threadKey
```
Add these methods to `NeedsYouReconcilerTest`:
```kotlin
    @Test fun suppresses_notification_while_the_thread_is_open_in_foreground() = runTest {
        val store = FakeStore(); val notifier = FakeNotifier()
        var openKey: String? = threadKey(conn.id, "t1")
        val r = NeedsYouReconciler(store, notifier, routedRepo(), foregroundThreadKey = { openKey })
        r.reconcile(conn, listOf(decisionSummary("t1", true)))
        assertEquals(0, notifier.events.size)   // suppressed: user is viewing t1 in the foreground
        // Deliberately NOT marked notified: once the user leaves, the next reconcile surfaces it.
        openKey = null
        r.reconcile(conn, listOf(decisionSummary("t1", true)))
        assertEquals(1, notifier.events.size)
    }

    @Test fun does_not_suppress_when_a_different_thread_is_open() = runTest {
        val store = FakeStore(); val notifier = FakeNotifier()
        val r = NeedsYouReconciler(
            store, notifier, routedRepo(),
            foregroundThreadKey = { threadKey(conn.id, "someOtherThread") },
        )
        r.reconcile(conn, listOf(summary("t1", true)))
        assertEquals(1, notifier.events.size)
    }
```

### Step 2 — Run to fail
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control/android && source ~/toolchains/android-env.sh && ./gradlew --offline testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.NeedsYouReconcilerTest'
```
Expect unresolved `foregroundThreadKey` parameter (red).

### Step 3 — Implement
In `NeedsYouCore.kt`, change the `NeedsYouReconciler` constructor and `reconcile`:
```kotlin
class NeedsYouReconciler(
    private val store: NotifiedStore,
    private val notifier: Notifier,
    private val repo: ThreadsRepository,
    /** The thread currently open+foregrounded (see [OpenThreadRegistry]), or null. Suppresses a
     *  duplicate notification for the thread the user is already viewing (#378). Defaults to
     *  "nothing open" so non-UI callers/tests keep the original always-notify behavior. */
    private val foregroundThreadKey: () -> String? = { null },
) {
    suspend fun reconcile(conn: WorkspaceConnection, threads: List<ThreadSummary>) {
        for (t in threads) {
            val notified = store.isNotified(conn.id, t.id)
            val needsAttention = t.needsYou || t.needsDecision
            if (needsAttention && !notified) {
                if (shouldSuppressNotification(foregroundThreadKey(), conn.id, t.id)) {
                    // The user is looking at this exact thread right now. Skip the notification and
                    // deliberately do NOT markNotified: if they leave it still-unanswered, a later
                    // reconcile should surface it.
                    continue
                }
                // Fetch the full thread once (gated by the dedupe store, so one GET per new
                // notification) to build MessagingStyle context + resolve the active decision.
                // Degrades to the summary preview if the fetch fails — a notification always fires.
                val messages = runCatching { repo.getThread(conn, t.id).messages }.getOrDefault(emptyList())
                notifier.notify(
                    NeedsYouEvent(
                        connectionId = conn.id,
                        baseUrl = conn.baseUrl,
                        workspaceName = conn.workspaceName,
                        threadId = t.id,
                        subject = t.subject,
                        preview = t.lastMessage,
                        updatedAt = t.updatedAt ?: "",
                        messages = messages,
                        decision = activeDecision(messages),
                    )
                )
                store.markNotified(conn.id, t.id)
            } else if (!needsAttention && notified) {
                store.clear(conn.id, t.id)
            }
        }
    }

    suspend fun fetchAndReconcile(conn: WorkspaceConnection) =
        reconcile(conn, repo.listThreadsFor(conn))
}
```
`shouldSuppressNotification` is same-package — no import needed.

### Step 4 — Run to pass
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control/android && source ~/toolchains/android-env.sh && ./gradlew --offline testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.NeedsYouReconcilerTest'
```

### Step 5 — Commit
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control add android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NeedsYouCore.kt android/app/src/test/java/com/atomikpanda/groundcontrol/NeedsYouReconcilerTest.kt
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control commit -m "Reconciler suppresses notify() for the open+foregrounded thread (#378)" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "NeedsYouReconciler foregroundThreadKey injection + suppression, unit-tested" --task gc-notification-fixes --action committed
```
<!-- /mship:task -->

<!-- mship:task id=8 -->
## Task 8 — Feed the foreground signal into the reconciler at both call sites (#378)

THIN UNTESTED GLUE: `WatchService` (a `Service`) and `WatchBackstopWorker` (a `CoroutineWorker`) can't be JVM-unit-tested. They only pass the already-tested `OpenThreadRegistry.snapshot` into the already-tested reconciler.

**Files**
- `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/WatchService.kt`
- `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/WatchBackstopWorker.kt`

### Step 1 — Implement
In `WatchService.onCreate`, change the reconciler construction to:
```kotlin
        reconciler = NeedsYouReconciler(
            RoomNotifiedStore(NotifiedDatabase.get(applicationContext).notifiedDao()),
            AndroidNotifier(applicationContext),
            repo,
            foregroundThreadKey = { OpenThreadRegistry.snapshot() },
        )
```
In `WatchBackstopWorker.doWork`, change the reconciler construction to:
```kotlin
        val reconciler = NeedsYouReconciler(
            RoomNotifiedStore(NotifiedDatabase.get(applicationContext).notifiedDao()),
            AndroidNotifier(applicationContext),
            repo,
            foregroundThreadKey = { OpenThreadRegistry.snapshot() },
        )
```
`OpenThreadRegistry` is same-package (`notify`) — no import needed.

### Step 2 — Run to pass (full suite; prove no regression)
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control/android && source ~/toolchains/android-env.sh && ./gradlew --offline testDebugUnitTest
```

### Step 3 — Commit
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control add android/app/src/main/java/com/atomikpanda/groundcontrol/notify/WatchService.kt android/app/src/main/java/com/atomikpanda/groundcontrol/notify/WatchBackstopWorker.kt
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control commit -m "Wire OpenThreadRegistry snapshot into the reconciler in WatchService + WatchBackstopWorker (#378)" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "Both reconciler call sites now read the foreground open-thread signal (thin glue)" --task gc-notification-fixes --action committed
```
<!-- /mship:task -->

<!-- mship:task id=9 -->
## Task 9 — Cancel-on-view: `NeedsYouCanceller` + ViewModel cancels its notification when opened (#378)

The interface + `NoopNeedsYouCanceller` + the ViewModel's "cancel on open" decision are unit-tested via a fake. `AndroidNeedsYouCanceller` (the real `NotificationManagerCompat.cancel`) is thin untested glue, wired in Task 10.

**Files**
- `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NeedsYouCanceller.kt` (create)
- `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/ConversationViewModel.kt`
- `android/app/src/test/java/com/atomikpanda/groundcontrol/ConversationViewModelTest.kt`

### Step 1 — Write the failing test
Add these methods (and the fake) inside `ConversationViewModelTest`:
```kotlin
    private class FakeCanceller : com.atomikpanda.groundcontrol.notify.NeedsYouCanceller {
        val cancelled = mutableListOf<Pair<String, String>>()
        override fun cancel(connId: String, threadId: String) { cancelled += connId to threadId }
    }

    @Test fun opening_a_thread_cancels_its_pending_notification() = runTest {
        val canceller = FakeCanceller()
        val vm = ConversationViewModel(
            ThreadsRepository(SpecApi(HttpClient(MockEngine { req ->
                if (req.url.encodedPath.endsWith("/threads/t1") && req.method == HttpMethod.Get)
                    respond(threadJson, HttpStatusCode.OK, jsonHdr)
                else respondError(HttpStatusCode.NotFound)
            }) { mshipDefaults() })),
            conn, "t1", testScope = this, canceller = canceller,
        )
        vm.load()?.join()
        assertEquals(listOf("1" to "t1"), canceller.cancelled)   // conn.id == "1"
    }

    @Test fun a_failed_load_does_not_cancel() = runTest {
        val canceller = FakeCanceller()
        val vm = ConversationViewModel(
            ThreadsRepository(SpecApi(HttpClient(MockEngine { respondError(HttpStatusCode.InternalServerError) }) { mshipDefaults() })),
            conn, "t1", testScope = this, canceller = canceller,
        )
        vm.load()?.join()
        assertTrue(canceller.cancelled.isEmpty())
    }
```
(All referenced imports — `HttpClient`, `MockEngine`, `respond`, `respondError`, `HttpMethod`, `HttpStatusCode`, `mshipDefaults`, `assertTrue` — are already present in this test file.)

### Step 2 — Run to fail
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control/android && source ~/toolchains/android-env.sh && ./gradlew --offline testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.ConversationViewModelTest'
```
Expect unresolved `NeedsYouCanceller` / `canceller` param (red).

### Step 3 — Implement
Create `NeedsYouCanceller.kt`:
```kotlin
package com.atomikpanda.groundcontrol.notify

import android.content.Context
import androidx.core.app.NotificationManagerCompat

/**
 * Cancels the needs-you notification for a thread the user is now viewing (#378). Abstracted behind
 * an interface so the ViewModel's "cancel on open" decision is unit-testable with a fake, while the
 * real [NotificationManagerCompat] call stays thin, Android-only glue.
 */
interface NeedsYouCanceller {
    fun cancel(connId: String, threadId: String)
}

/** No-op default so tests / previews construct a ViewModel without an Android Context. */
object NoopNeedsYouCanceller : NeedsYouCanceller {
    override fun cancel(connId: String, threadId: String) {}
}

/**
 * Real canceller: dismisses the posted notification by the SAME [needsYouNotificationId] derivation
 * [AndroidNotifier] posted it under, so opening a thread proactively clears its shade entry even
 * when the user reached it in-app rather than by tapping the notification.
 */
class AndroidNeedsYouCanceller(private val context: Context) : NeedsYouCanceller {
    override fun cancel(connId: String, threadId: String) {
        runCatching {
            NotificationManagerCompat.from(context).cancel(needsYouNotificationId(connId, threadId))
        }
    }
}
```
In `ConversationViewModel.kt`, add imports:
```kotlin
import com.atomikpanda.groundcontrol.notify.NeedsYouCanceller
import com.atomikpanda.groundcontrol.notify.NoopNeedsYouCanceller
```
Change the class header to expose `threadId`/`connectionId` and accept the canceller:
```kotlin
class ConversationViewModel(
    private val repo: ThreadsRepository,
    private val conn: WorkspaceConnection,
    val threadId: String,
    private val testScope: CoroutineScope? = null,
    private val canceller: NeedsYouCanceller = NoopNeedsYouCanceller,
) : ViewModel() {

    /** This conversation's connection id — exposed for ConversationScreen's open-thread signal (#378). */
    val connectionId: String get() = conn.id
```
(Note: `threadId` changes from `private val` to `val`; no other change to the class body's use of `threadId`.)

In `load()`, add the cancel on the success path:
```kotlin
    fun load(): Job? {
        _state.value = ConversationUiState.Loading
        return scope().launch {
            runCatching { repo.getThread(conn, threadId) }
                .onSuccess { thread ->
                    val journal = fetchJournal(thread.taskSlug)
                    _state.value = ConversationUiState.Content(thread, journal = journal)
                    markSeen(thread)
                    // Opening the thread is "viewing" it: proactively clear any pending needs-you
                    // notification for it so a message you're already reading doesn't linger in the
                    // shade (#378). Idempotent — cancelling an absent notification is a no-op.
                    canceller.cancel(conn.id, threadId)
                }
                .onFailure { t -> _state.value = ConversationUiState.Error(t.toKind(), t.message ?: "error") }
        }
    }
```

### Step 4 — Run to pass
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control/android && source ~/toolchains/android-env.sh && ./gradlew --offline testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.ConversationViewModelTest'
```

### Step 5 — Commit
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control add android/app/src/main/java/com/atomikpanda/groundcontrol/notify/NeedsYouCanceller.kt android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/ConversationViewModel.kt android/app/src/test/java/com/atomikpanda/groundcontrol/ConversationViewModelTest.kt
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control commit -m "Cancel a thread's needs-you notification when the thread is opened/viewed (#378)" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "NeedsYouCanceller + ConversationViewModel cancel-on-view, unit-tested via fake" --task gc-notification-fixes --action committed
```
<!-- /mship:task -->

<!-- mship:task id=10 -->
## Task 10 — Screen + app wiring: drive `OpenThreadRegistry` from the conversation lifecycle and inject the real canceller (#378)

THIN UNTESTED GLUE: the `LifecycleResumeEffect` observer and the `AndroidNeedsYouCanceller` construction are Android/Compose surfaces (no JVM unit test). Their logic is the already-tested `OpenThreadRegistry` and `needsYouNotificationId`.

**Files**
- `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/ConversationScreen.kt`
- `android/app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApp.kt`

### Step 1 — Implement
In `ConversationScreen.kt`, add imports:
```kotlin
import androidx.lifecycle.compose.LifecycleResumeEffect
import com.atomikpanda.groundcontrol.notify.OpenThreadRegistry
```
In the `ConversationScreen` composable, immediately after the existing `LaunchedEffect(Unit) { vm.load()?.join(); vm.startPolling() }` (line 80), add:
```kotlin
    // Tell the watcher this thread is on screen + foregrounded so it suppresses a duplicate
    // notification for it, and clear that signal when we leave or the app backgrounds (#378).
    // RESUMED ⇒ open+foregrounded; PAUSE/dispose ⇒ closed. Thin lifecycle glue over the
    // OpenThreadRegistry singleton (no ProcessLifecycleOwner dependency required).
    LifecycleResumeEffect(vm.connectionId, vm.threadId) {
        OpenThreadRegistry.open(vm.connectionId, vm.threadId)
        onPauseOrDispose { OpenThreadRegistry.close(vm.connectionId, vm.threadId) }
    }
```
In `GroundControlApp.kt`, add import:
```kotlin
import com.atomikpanda.groundcontrol.notify.AndroidNeedsYouCanceller
```
In the `thread/{connectionId}/{threadId}` composable, change the `ConversationViewModel` construction (currently line 432-434) to pass the real canceller:
```kotlin
                    val vm = viewModel(key = "thread-$connectionId-$threadId") {
                        ConversationViewModel(
                            threadsRepo, conn, threadId,
                            canceller = AndroidNeedsYouCanceller(context.applicationContext),
                        )
                    }
```

### Step 2 — Run to pass (full suite; prove no regression)
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control/android && source ~/toolchains/android-env.sh && ./gradlew --offline testDebugUnitTest
```

### Step 3 — Commit
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/ConversationScreen.kt android/app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApp.kt
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control commit -m "Drive OpenThreadRegistry from conversation lifecycle + inject AndroidNeedsYouCanceller (#378)" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "ConversationScreen LifecycleResumeEffect + real canceller wired (thin glue)" --task gc-notification-fixes --action committed
```
<!-- /mship:task -->

<!-- mship:task id=11 -->
## Task 11 — Regression pass: full unit-test suite green

No code change — a whole-suite gate that both issues' pure logic is green together and nothing else regressed.

**Files**
- (none)

### Step 1 — Run the full suite
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/gc-notification-fixes/ground-control/android && source ~/toolchains/android-env.sh && ./gradlew --offline testDebugUnitTest
```
Confirm `NotificationFormatTest`, `OpenThreadRegistryTest`, `NeedsYouReconcilerTest`, `ConversationViewModelTest`, and all pre-existing tests pass.

### Step 2 — Manual verification checklist (record in the journal; no code)
- #379: option button shows ≤3 words + ellipsis; `EXTRA_OPTION_TEXT` (posted choice) is still the full option text; the full numbered options appear in the notification body.
- #378: a needs-you notification does NOT pop while its thread is open+foregrounded; it DOES pop for a different thread and after backgrounding; opening a thread clears its shade notification.

### Step 3 — Journal (no commit)
```
mship journal "Full testDebugUnitTest suite green for #378 + #379; manual checklist confirmed" --task gc-notification-fixes --action verified
```
<!-- /mship:task -->

---

## Self-Review

### Every fix requirement mapped to a task

**#379 — decision-option buttons overflow**
- Short visible button label (~1-3 words, ellipsis, bounded char/word count), pure + unit-tested (long/short/multiword/empty): `optionButtonLabel` — Task 2 (pure/tested), applied to `Action.Builder` in Task 6 (glue).
- POSTED payload (`EXTRA_OPTION_TEXT`) stays the FULL option text (Watch/phone quick-reply sends the correct full choice): Task 6 keeps `replyPendingIntent(optionText = optionText)` = full text; `ReplyReceiver.kt:21` consumes it unchanged.
- Full option list rendered into the MessagingStyle chat body: `decisionOptionsBody` — Task 3 (pure/tested), added to the style in Task 6 (glue).

**#378 — notifications pop for the open thread / aren't cleared once viewed**
- A lightweight observable "which thread is open + is the app foregrounded" signal: `OpenThreadRegistry` — Task 5 (tested holder), driven by the conversation screen's RESUME/PAUSE via `LifecycleResumeEffect` — Task 10 (thin glue).
- `reconcile` SUPPRESSES `notify()` for the open+foregrounded thread: `shouldSuppressNotification` — Task 4 (pure/tested); reconciler injection + suppression — Task 7 (tested); wired into both call sites (`WatchService`, `WatchBackstopWorker`) — Task 8 (thin glue).
- Proactive `NotificationManagerCompat.cancel(notifId)` when a thread is opened/marked-viewed, keyed by the SAME deterministic notifId derivation: `needsYouNotificationId` — Task 1 (pure/tested); `NeedsYouCanceller` + ViewModel cancel-on-view — Task 9 (tested via fake); real `AndroidNeedsYouCanceller` wired — Task 10 (thin glue).
- Shared, deterministic notifId used by BOTH notify and cancel: `needsYouNotificationId` (Task 1) is consumed by `AndroidNotifier` (Task 6) and `AndroidNeedsYouCanceller` (Task 9) — one derivation, byte-identical to the original `(connId + "|" + threadId).hashCode()`.

Single-PR justification (both issues): Tasks 6 (`AndroidNotifier.kt`) and 7 (`NeedsYouCore.kt`) each touch a file needed by the other issue, and Task 1's `needsYouNotificationId` is shared by #379's notifier and #378's canceller — so the two fixes cannot be cleanly separated into two PRs without conflict.

### Pure-tested vs thin-untested-glue
- Pure + unit-tested: `threadKey`, `needsYouNotificationId`, `optionButtonLabel`, `decisionOptionsBody`, `shouldSuppressNotification` (Tasks 1-4); `OpenThreadRegistry` open/close/compareAndSet/snapshot (Task 5); reconciler suppression via fakes (Task 7); `NeedsYouCanceller` decision + ViewModel cancel-on-view via a fake (Task 9).
- Thin untested glue (explicitly called out in each task; each wraps a tested pure function): `AndroidNotifier.render` (Task 6, needs `Context`/`NotificationManagerCompat`), `AndroidNeedsYouCanceller` (Task 9), `WatchService`/`WatchBackstopWorker` construction (Task 8), `ConversationScreen` `LifecycleResumeEffect` + `GroundControlApp` canceller injection (Task 10). Glue tasks add no unit test and instead re-run the full suite to prove no regression.

### Placeholder scan
No `TODO`, `FIXME`, `...`, or stub bodies. Every code block is complete Kotlin (imports, signatures, bodies). Glue tasks intentionally add no new test and say so, running the full suite instead.

### Type / name consistency
- `threadKey(connId, threadId) = "$connId|$threadId"` matches the original inline `connectionId + "|" + threadId` AND the existing `FakeStore` test key `"$c|$t"` in `NeedsYouReconcilerTest` — so hashes and dedupe keys stay identical.
- `needsYouNotificationId` is the ONE id derivation shared by `AndroidNotifier` (post) and `AndroidNeedsYouCanceller` (cancel) — cancel always targets the posted id.
- Reconciler `foregroundThreadKey: () -> String?` (default `{ null }`) preserves all existing 3-arg construction/tests; `OpenThreadRegistry.snapshot(): String?` matches that type exactly.
- `ConversationViewModel` new `canceller: NeedsYouCanceller = NoopNeedsYouCanceller` is the last param (after `testScope`), so existing call sites/tests compile unchanged; `threadId` widened `private val`→`val` and `connectionId` added for the screen's registry wiring.
- `Decision` fields used (`options: List<String>`, `recommended: Int?`, `multi: Boolean`) match `ThreadDtos.kt`; `decisionOptionsBody` guards null/empty and null `recommended`.
