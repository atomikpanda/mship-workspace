# Review·Merge Cockpit (v1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** Linear **MOS-199** (v1 scope: PR list + request-changes + tap-through; in-app PR detail + Merge split to MOS-208), part of the *Work Items — phase-aware cockpit* program.

**Goal:** A **Review·Merge cockpit** for a WorkItem in the `review` phase — lists the item's PRs (aggregated across its child tasks/repos), taps through to GitHub for the diff/checks/merge, and offers **Request changes** (a structured comment). Read + comment + tap-through only; in-app checks/changed-files + a Merge button are deferred (MOS-208).

**Architecture:** **ground-control only** — reuses the MOS-202 console fan-out and existing client methods (`getItem`/`getTask`/`getThread`/`postMessage`); no mship changes. A new `review/{connectionId}/{itemId}` route + `ReviewViewModel` (loads the item, fans out `getTask` per child task, aggregates `pr_urls`→rows) + `ReviewScreen` (per-PR rows with GitHub tap-through + a Request-changes action via the mailbox). `FarmScreen.onOpen` routes `review`-phase items here.

**Tech Stack:** Kotlin, Compose (Material3), Ktor, MVVM. JUnit4 + `MockEngine` (NOT `kotlin.test`). `source ~/toolchains/android-env.sh` before gradle. Focused: `./android/gradlew -p android :app:testDebugUnitTest --tests "com.atomikpanda.groundcontrol.<Class>"`; evidence: `mship test`. Package `com.atomikpanda.groundcontrol`.

---

## File Structure

- **Create** `ui/review/ReviewViewModel.kt` + `ui/review/ReviewScreen.kt` (model on `ui/console/*`).
- **Modify** `GroundControlApp.kt` — add the `review/{connectionId}/{itemId}` route; route `review`-phase farm items to it.
- Test: `ReviewViewModelTest.kt`.

No client/DTO changes — `SpecApi.getItem`/`getTask`/`getThread`/`postMessage` and `WorkItemSummary`/`TaskSummary` all already exist (from MOS-197/202).

---

<!-- mship:task id=1 -->
### Task 1: ReviewViewModel

**Files:** Create `ui/review/ReviewViewModel.kt`; Test `ReviewViewModelTest.kt`

- [ ] **Step 1: Failing test** — `ReviewViewModelTest.kt` (JUnit4, `MockEngine`, `Dispatchers.setMain(StandardTestDispatcher())`, injected `testScope`; mirror `ConsoleViewModelTest`). Seed: `/items/wi-1` → `{task_slugs:["a"], thread_ids:["t1"]}`; `/tasks/a` → `{slug:"a", pr_urls:{"mothership":"http://pr/1"}, test_results:{"mothership":"pass"}, ...}`; `/threads/t1`. Assert: after `load().join()`, state is `Content` with one `PrRow(taskSlug="a", repo="mothership", url="http://pr/1", testStatus="pass")` and `threadId=="t1"`; and `requestChanges("please fix X")` issues a `POST /threads/t1/messages`.

- [ ] **Step 2: Run — expect FAIL** — unresolved `ReviewViewModel`.

- [ ] **Step 3: Implement**

```kotlin
package com.atomikpanda.groundcontrol.ui.review

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.atomikpanda.groundcontrol.data.SpecApi
import com.atomikpanda.groundcontrol.data.WorkspaceConnection
import com.atomikpanda.groundcontrol.data.dto.WorkItemSummary
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlin.coroutines.cancellation.CancellationException

data class PrRow(val taskSlug: String, val repo: String, val url: String, val testStatus: String?)
data class ReviewContent(val item: WorkItemSummary, val prs: List<PrRow>, val threadId: String?)

sealed interface ReviewUiState {
    data object Loading : ReviewUiState
    data class Content(val c: ReviewContent) : ReviewUiState
    data class Failed(val reason: String) : ReviewUiState
}

class ReviewViewModel(
    private val api: SpecApi,
    private val conn: WorkspaceConnection,
    private val itemId: String,
    private val testScope: CoroutineScope? = null,
) : ViewModel() {

    private val _state = MutableStateFlow<ReviewUiState>(ReviewUiState.Loading)
    val state: StateFlow<ReviewUiState> = _state.asStateFlow()
    private val scope get() = testScope ?: viewModelScope

    fun load(): Job = scope.launch { _state.value = fetch() }

    private suspend fun fetch(): ReviewUiState = try {
        val item = api.getItem(conn, itemId)
        coroutineScope {
            val tasks = item.taskSlugs
                .map { async { runCatching { api.getTask(conn, it) }.getOrNull() } }
                .awaitAll().filterNotNull()
            val prs = tasks.flatMap { t ->
                t.prUrls.entries.map { (repo, url) ->
                    PrRow(taskSlug = t.slug, repo = repo, url = url, testStatus = t.testResults[repo])
                }
            }
            ReviewUiState.Content(ReviewContent(item, prs, item.threadIds.firstOrNull()))
        }
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        ReviewUiState.Failed(e.message ?: "failed to load")
    }

    fun requestChanges(reason: String): Job = scope.launch {
        val tid = (state.value as? ReviewUiState.Content)?.c?.threadId ?: return@launch
        runCatching { api.postMessage(conn, tid, "**Requested changes:** $reason") }
        // defensive refetch (mirror ConsoleViewModel.steer): don't drop to Failed on a transient error
        val next = runCatching { fetch() }.getOrNull()
        if (next is ReviewUiState.Content) _state.value = next
    }
}
```

*(Verify `TaskSummary.prUrls`/`testResults`/`slug`, `WorkItemSummary.taskSlugs`/`threadIds`, and the `getItem`/`getTask`/`postMessage` signatures against the real files — they're the same ones `ConsoleViewModel` uses.)*

- [ ] **Step 4: Run — expect PASS**; **Step 5:** `mship test` green.

- [ ] **Step 6: Commit** — `feat(review): ReviewViewModel (aggregate PRs, request-changes)` + `mship journal`.
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: ReviewScreen (Compose UI)

UI — build + (deferred) `mship capture`. Header + per-PR rows (repo · task · GitHub tap-through · local test status) + a Request-changes action.

**Files:** Create `ui/review/ReviewScreen.kt`

- [ ] **Step 1: Implement** — a `Scaffold` + back `TopAppBar` (mirror `ConsoleScreen`/`WorkspaceScreen`), `LaunchedEffect(Unit) { vm.load() }`. On `Content`:
  - Header: the item title + a "Review" label (mono).
  - If `prs` is empty → "No PRs yet." (`LocalSemanticColors.current.muted`).
  - Else one row per `PrRow`: a tap-through affordance `"${repo} PR ↗"` via `LocalUriHandler.current.openUri(url)` (reuse the `TaskDetailScreen` pattern; an `AssistChip` or clickable `Text` in `colorScheme.primary`), the `taskSlug` in `MonoStyle`, and the test status colored `when (testStatus) { "pass" -> colors.approval; "skip" -> colors.muted; null -> colors.muted; else -> colors.error }` (same rule the console uses).
  - A **"Request changes"** button — enabled only when `c.threadId != null`; on tap open a reason dialog (reuse `ui/specdetail/`'s `ReasonDialog` if accessible, else a minimal `AlertDialog` with a text field) → `vm.requestChanges(reason)`. When `threadId == null`, show the button disabled with a hint ("no conversation on this item").
  - `Loading` → spinner; `Failed` → `s.reason` in `LocalSemanticColors.current.error`.

- [ ] **Step 2: Build** — `./android/gradlew -p android :app:assembleDebug` → BUILD SUCCESSFUL. (Confirm `ReasonDialog`'s signature/visibility if reused; if it's `private` to SpecDetail, just inline a small `AlertDialog` here.)

- [ ] **Step 3:** `mship test` green.

- [ ] **Step 4: Commit** — `feat(review): ReviewScreen — PR rows, tap-through, request-changes` + `mship journal`.
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: Nav wiring

**Files:** Modify `GroundControlApp.kt`

- [ ] **Step 1: Add the route** — mirror the `console/{connectionId}/{itemId}` composable exactly: a `review/{connectionId}/{itemId}` destination resolving `conn` via `runBlockingSnapshot(connRepo).firstOrNull{...}`, `viewModel(key = "review-$connectionId-$itemId") { ReviewViewModel(api, conn, itemId) }`, rendering `ReviewScreen(vm, title = conn.workspaceName.ifBlank { conn.baseUrl }, onBack = { nav.popBackStack() })`. Add the `ReviewScreen`/`ReviewViewModel` imports. (Confirm `ReviewScreen`'s actual param names against Task 2.)

- [ ] **Step 2: Route review-phase items** — in the farm `onOpen` `when` (`GroundControlApp.kt`), add `item.phase == "review" -> nav.navigate("review/$connectionId/${item.id}")` immediately AFTER the existing `item.phase == "in_flight"` branch and BEFORE the `specId`/`taskSlugs`/`threadIds` fallbacks (so a review-phase item opens the review cockpit, not spec/task detail).

- [ ] **Step 3: Build + evidence** — `assembleDebug` BUILD SUCCESSFUL; then **`mship test`** green (full suite).

- [ ] **Step 4: Visual (deferred)** — `mship capture`: drill into a review-phase item → confirm the PR rows + tap-through + request-changes. Deferred to operator (no emulator; needs a live review-phase item with PRs).

- [ ] **Step 5: Commit** — `feat(review): review route + review-phase drill-in` + `mship journal`.
<!-- /mship:task -->

---

## Self-review checklist

- **Spec coverage (v1):** PR list aggregated across tasks/repos (T1/T2), GitHub tap-through (T2), request-changes via mailbox (T1/T2), review route + drill-in (T3). In-app checks/changed-files + Merge correctly ABSENT (MOS-208).
- **No new endpoints / mship changes** — reuses `getItem`/`getTask`/`getThread`/`postMessage`.
- **Request-changes reuses the mailbox** — `postMessage` to the work-item thread; the defensive-refetch guard matches the console fix.
- **Conventions** — JUnit4; skip-status neutral color consistent with the console.

## Notes / risks

- **No thread ⇒ no request-changes** — a review-phase item with no thread (`threadIds` empty) disables the request-changes action (v1). Creating/linking a thread on demand is out of scope.
- **Local test status only** — the row shows the `test_results` (pass/fail/skip) recorded by `mship test`, NOT live CI checks; live checks are MOS-208. Label it as local test status, not CI.
- **Merge/diff via tap-through** — deliberately delegated to GitHub (the "review deep in another app" decision); the in-app Merge button is MOS-208.
