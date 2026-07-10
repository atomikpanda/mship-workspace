# Re-home Phases + Done Summary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** Linear **MOS-200**, part of the *Work Items — phase-aware cockpit* program. The last core UI slice: give every WorkItem phase an intentional home in the cockpit frame.

**Goal:** Route the remaining phases (`inbox`/`shaping`/`ready` → the existing `SpecDetailScreen`; `done` → a new **Done summary**) from the farm drill-in, so the whole lifecycle reads consistently — Inbox/Shaping/Ready (spec) → In-flight (console, MOS-202) → Review (MOS-199) → Done (this).

**Architecture:** **ground-control only** — pure reuse; no mship changes, no new endpoints. `inbox`/`shaping`/`ready` already resolve to `specDetail` via fallthrough today; MOS-200 makes that explicit and adds the missing `done` home. The new `DoneViewModel` fans out `getItem` → per-task `getTask` (+ optional `getReview`) exactly like `ReviewViewModel`; `DoneScreen` renders an honest completion summary.

**Tech Stack:** Kotlin, Compose (Material3), Ktor, MVVM. JUnit4 + `MockEngine` (NOT `kotlin.test`). `source ~/toolchains/android-env.sh` before gradle. Focused: `./android/gradlew -p android :app:testDebugUnitTest --tests "com.atomikpanda.groundcontrol.<Class>"`; evidence: `mship test`. Package `com.atomikpanda.groundcontrol`.

---

## File Structure

- **Create** `ui/done/DoneViewModel.kt` + `ui/done/DoneScreen.kt` (model on `ui/review/*`).
- **Modify** `GroundControlApp.kt` — add the `done/{connectionId}/{itemId}` route; make the farm `onOpen` phase→screen mapping explicit.
- Test: `DoneViewModelTest.kt`.

No client/DTO/mship changes — `getItem`/`getTask`/`getReview` and `WorkItemSummary`/`TaskSummary`/`SpecReview` all already exist.

**Honesty constraint (from exploration):** an item reaches `done` *organically* only when its finished tasks have **no** `pr_urls` (items *with* PRs are the `review` phase); PRs appear on a `done` item only if it was `phase_override`'d or is a spec-only `implemented`/`archived`. So the summary says **"Completed"** and shows PR links **only when present** — never implies "shipped N PRs" by default. There is no `completed_at` field server-side; use `max(task.finishedAt)` (falling back to `item.updatedAt`) as the completion time.

---

<!-- mship:task id=1 -->
### Task 1: DoneViewModel

**Files:** Create `ui/done/DoneViewModel.kt`; Test `DoneViewModelTest.kt`

- [ ] **Step 1: Failing test** — `DoneViewModelTest.kt` (JUnit4, `MockEngine`, `Dispatchers.setMain(StandardTestDispatcher())`, injected `testScope`; mirror `ReviewViewModelTest`). Seed: `/items/wi-1` → `{task_slugs:["a"], spec_id:null, updated_at:"2026-07-02T00:00:00Z"}`; `/tasks/a` → `{slug:"a", branch:"feat/a", pr_urls:{}, test_results:{"mothership":"pass"}, affected_repos:["mothership"], finished_at:"2026-07-01T12:00:00Z"}`. Assert: after `load().join()`, state is `Content` with `tasks` size 1, `reposTouched == ["mothership"]`, `completedAt == "2026-07-01T12:00:00Z"` (max finishedAt), and `review == null` (no spec).

- [ ] **Step 2: Run — expect FAIL** — unresolved `DoneViewModel`.

- [ ] **Step 3: Implement**

```kotlin
package com.atomikpanda.groundcontrol.ui.done

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.atomikpanda.groundcontrol.data.SpecApi
import com.atomikpanda.groundcontrol.data.WorkspaceConnection
import com.atomikpanda.groundcontrol.data.dto.ReviewSummary
import com.atomikpanda.groundcontrol.data.dto.TaskSummary
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

data class DoneContent(
    val item: WorkItemSummary,
    val tasks: List<TaskSummary>,
    val reposTouched: List<String>,
    val completedAt: String?,      // max task.finishedAt, else item.updatedAt
    val review: ReviewSummary?,    // null when the item has no spec
)

sealed interface DoneUiState {
    data object Loading : DoneUiState
    data class Content(val c: DoneContent) : DoneUiState
    data class Failed(val reason: String) : DoneUiState
}

class DoneViewModel(
    private val api: SpecApi,
    private val conn: WorkspaceConnection,
    private val itemId: String,
    private val testScope: CoroutineScope? = null,
) : ViewModel() {

    private val _state = MutableStateFlow<DoneUiState>(DoneUiState.Loading)
    val state: StateFlow<DoneUiState> = _state.asStateFlow()
    private val scope get() = testScope ?: viewModelScope

    fun load(): Job = scope.launch { _state.value = fetch() }

    private suspend fun fetch(): DoneUiState = try {
        val item = api.getItem(conn, itemId)
        coroutineScope {
            val tasks = item.taskSlugs
                .map { async { runCatching { api.getTask(conn, it) }.getOrNull() } }
                .awaitAll().filterNotNull()
            val reposTouched = tasks.flatMap { it.affectedRepos }.distinct()
            val completedAt = tasks.mapNotNull { it.finishedAt }.maxOrNull() ?: item.updatedAt
            val review = item.specId?.let { runCatching { api.getReview(conn, it).summary }.getOrNull() }
            DoneUiState.Content(DoneContent(item, tasks, reposTouched, completedAt, review))
        }
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        DoneUiState.Failed(e.message ?: "failed to load")
    }
}
```

*(Verify `TaskSummary.affectedRepos`/`finishedAt`/`branch`/`prUrls`/`testResults`, `WorkItemSummary.updatedAt`/`specId`/`taskSlugs`, and `getReview(...).summary` against the real files — same fields the Review/Console VMs use. `finishedAt`/`updatedAt` are ISO-8601 strings, so lexical `maxOrNull()` is chronological.)*

- [ ] **Step 4: Run — expect PASS**; **Step 5:** `mship test` green.

- [ ] **Step 6: Commit** — `feat(done): DoneViewModel (completion summary fan-out)` + `mship journal`.
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: DoneScreen (Compose UI)

UI — build-verified. An honest completion summary. Model on `ui/review/ReviewScreen.kt`.

**Files:** Create `ui/done/DoneScreen.kt`

- [ ] **Step 1: Implement** — a `Scaffold` + back `TopAppBar` (mirror `ReviewScreen`), `LaunchedEffect(Unit) { vm.load() }`, `collectAsStateWithLifecycle`. On `Content`:
  - Header: item `title` (titleLarge) + `kind` in `MonoStyle` (`colorScheme.outline`); a **"Completed ${completedAt ?: "—"}"** line (mono).
  - "Repos touched" line: `reposTouched.joinToString(", ")` (or "—" if empty).
  - Per-task rows (`c.tasks`): `slug` (`MonoStyle`) + `branch` (mono, `colorScheme.outline`); per-repo test-status chips colored `when (status) { "pass" -> colors.approval; "skip" -> colors.muted; else -> colors.error }` (same rule as Console/Review); and — **only when `task.prUrls` is non-empty** — a `"${repo} PR ↗"` tap-through per entry (`LocalUriHandler.current.openUri(url)`, the `ReviewScreen`/`TaskDetailScreen` pattern). Do NOT render a PR section when there are no PRs.
  - When `c.review != null`: a spec line — `"Spec: ${approved}/${criteriaTotal} AC approved"` (from `ReviewSummary`).
  - `Loading` → spinner; `Failed` → `s.reason` in `LocalSemanticColors.current.error`.

- [ ] **Step 2: Build** — `./android/gradlew -p android :app:assembleDebug` → BUILD SUCCESSFUL. (Confirm `ReviewSummary` field names — `approved`/`criteriaTotal` — against `data/dto/SpecDetailDtos.kt`.)

- [ ] **Step 3:** `mship test` green.

- [ ] **Step 4: Commit** — `feat(done): DoneScreen — completion summary` + `mship journal`.
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: Nav wiring — done route + explicit phase homes

**Files:** Modify `GroundControlApp.kt`

- [ ] **Step 1: Add the done route** — mirror the `review/{connectionId}/{itemId}` composable exactly: a `done/{connectionId}/{itemId}` destination resolving `conn` via `runBlockingSnapshot(connRepo).firstOrNull{...}`, `viewModel(key = "done-$connectionId-$itemId") { DoneViewModel(api, conn, itemId) }`, rendering `DoneScreen(vm, title = conn.workspaceName.ifBlank { conn.baseUrl }, onBack = { nav.popBackStack() })`. Add the `DoneScreen`/`DoneViewModel` imports. (Confirm `DoneScreen`'s param names against Task 2.)

- [ ] **Step 2: Make the farm `onOpen` phase mapping explicit** — replace the farm `onOpen` `when` (currently `in_flight`→console, `review`→review, then `specId`/`taskSlugs`/`threadIds` fallbacks) with:

```kotlin
onOpen = { item ->
    when {
        item.phase == "in_flight" -> nav.navigate("console/$connectionId/${item.id}")
        item.phase == "review" -> nav.navigate("review/$connectionId/${item.id}")
        item.phase == "done" -> nav.navigate("done/$connectionId/${item.id}")
        item.phase in listOf("inbox", "shaping", "ready") && item.specId != null ->
            nav.navigate("specDetail/$connectionId/${item.specId}")
        // generic fallbacks: spec-less inbox captures, or any unmatched item
        item.specId != null -> nav.navigate("specDetail/$connectionId/${item.specId}")
        item.taskSlugs.isNotEmpty() -> nav.navigate("taskDetail/$connectionId/${item.taskSlugs.first()}")
        item.threadIds.isNotEmpty() -> nav.navigate("thread/$connectionId/${item.threadIds.first()}")
    }
}
```

This gives `done` its new home (before it would wrongly hit the `specDetail`/`taskDetail` fallback), makes `inbox`/`shaping`/`ready` intentional (the existing `SpecDetailScreen` — shape/review/approve/dispatch), and keeps the generic fallbacks for spec-less `inbox` captures (→ `thread`) and safety.

- [ ] **Step 3: Build + evidence** — `assembleDebug` BUILD SUCCESSFUL; then **`mship test`** green (full suite).

- [ ] **Step 4: Visual (deferred)** — `mship capture`: drill into a `done` item → confirm the completion summary; drill into a `shaping`/`ready` item → confirm it opens SpecDetail. Deferred to operator (no emulator; needs live items in those phases).

- [ ] **Step 5: Commit** — `feat(done): done route + explicit farm phase homes` + `mship journal`.
<!-- /mship:task -->

---

## Self-review checklist

- **Spec coverage:** every phase has an intentional farm home — `inbox`/`shaping`/`ready`→SpecDetail (T3), `in_flight`→console + `review`→review (already), `done`→new Done summary (T1/T2/T3). Done summary is honest re: PRs (T2).
- **No new endpoints / mship changes** — reuses `getItem`/`getTask`/`getReview`.
- **Conventions** — JUnit4; test-status color + fan-out mirror the console/review; `collectAsStateWithLifecycle`.

## Notes / risks

- **Done is honestly minimal** — organically-`done` items have no PRs, so the summary centers on completed-time + repos + tasks + tests + spec status; PR links show only when present. This is intentional (the "small Done summary" of the design), not a gap.
- **No `completed_at` field** — using `max(task.finishedAt)` (ISO strings, lexical max = chronological) with `item.updatedAt` fallback. A real completion timestamp would need a new mship model field (out of scope).
- **`external_links` / `created_at` deferred** — the server emits both but GC's DTO drops them; widening the DTO to enrich the Done summary (phase-independent PR/issue links, a start→finish span) is left to MOS-201 (external links).
- **Spec-less inbox** — a capture with no spec falls through to `thread` (unchanged); it has no dedicated capture-cockpit yet (existing behavior).
