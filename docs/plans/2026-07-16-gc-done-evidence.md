# AC evidence on the done/completion view (shared with review) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development or executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Spec:** `gc-done-evidence` (approved, dispatched). WorkItem `wi-20260716193424-918f51b6`. Worktree: `.worktrees/gc-done-evidence/ground-control`.

**Goal:** Show the same acceptance-criteria evidence (with commit deep-links) on the done/completion view (DoneScreen) that the review page already shows, from a single shared component.

**Architecture:** GC-only. Extract the review page's evidence rendering (`evidenceOpenUrl` + the criterion/evidence row) into one shared composable used by BOTH ReviewScreen and DoneScreen. DoneViewModel gains `criteria` + `prUrls` on DoneContent (fetched like ReviewViewModel does). Commit deep-links (`<pr>/commits/<sha>`) stay valid on a merged PR.

**Tech Stack:** Kotlin, Compose (Material3), Ktor client, JUnit4 + Ktor MockEngine. Build/test from `ground-control/android`: `source ~/toolchains/android-env.sh` then `./gradlew --offline compileDebugKotlin testDebugUnitTest`.

---

## File Structure

- **Create** `ui/review/AcceptanceEvidence.kt` — the shared public API: `evidenceOpenUrl(...)` (moved from `EvidenceLink.kt`) + a public `AcceptanceCriteriaSection(criteria, prUrls)` composable (extracted from ReviewScreen's private `CriterionEvidenceRow`).
- **Delete/fold** `ui/review/EvidenceLink.kt` — its `evidenceOpenUrl` moves into `AcceptanceEvidence.kt` (keep the same package so `EvidenceLinkTest` still resolves it).
- **Modify** `ui/review/ReviewScreen.kt` — replace the inline criteria rendering with `AcceptanceCriteriaSection`.
- **Modify** `ui/done/DoneViewModel.kt` — `DoneContent` gains `criteria` + `prUrls`; `fetch()` populates them.
- **Modify** `ui/done/DoneScreen.kt` — render `AcceptanceCriteriaSection` in the completion list.
- **Modify** `test/.../DoneViewModelTest.kt` (or create) — MockEngine test that criteria + prUrls are surfaced.
- `EvidenceLinkTest.kt` stays (same package, same `evidenceOpenUrl`).

---

<!-- mship:task id=1 -->
### Task 1: Extract the shared evidence component (no behavior change)

**Files:**
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/review/AcceptanceEvidence.kt`
- Modify: `ui/review/ReviewScreen.kt`; remove `ui/review/EvidenceLink.kt`
- Test: existing `EvidenceLinkTest.kt` (unchanged) + existing `ReviewViewModelTest.kt` (unchanged) are the regression guard.

- [ ] **Step 1: Create `AcceptanceEvidence.kt`** — move `evidenceOpenUrl` verbatim from `EvidenceLink.kt`, and add a public `AcceptanceCriteriaSection` extracted from ReviewScreen's private `CriterionEvidenceRow`:

```kotlin
package com.atomikpanda.groundcontrol.ui.review

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.dp
import com.atomikpanda.groundcontrol.data.dto.ReviewCriterion
import com.atomikpanda.groundcontrol.ui.specdetail.evidenceLabels
import com.atomikpanda.groundcontrol.ui.specdetail.isUnverified
import com.atomikpanda.groundcontrol.ui.theme.LocalSemanticColors
import com.atomikpanda.groundcontrol.ui.theme.MonoStyle

fun evidenceOpenUrl(kind: String, ref: String, prUrls: List<String>): String? = when (kind) {
    "commit" -> prUrls.singleOrNull()?.let { "${it.trimEnd('/')}/commits/$ref" }
    "artifact" -> ref.takeIf { it.startsWith("http://") || it.startsWith("https://") }
    else -> null
}

/** Adds the "Acceptance criteria" header + one row per criterion (verdict + tappable evidence)
 *  to a LazyColumn. Shared by the review page and the done view. No-op when [criteria] is empty. */
fun LazyListScope.acceptanceCriteriaSection(criteria: List<ReviewCriterion>, prUrls: List<String>) {
    if (criteria.isEmpty()) return
    item {
        Text(
            "Acceptance criteria",
            style = MaterialTheme.typography.titleSmall,
            modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 4.dp),
        )
    }
    items(criteria, key = { it.id }) { crit -> CriterionEvidenceRow(crit, prUrls) }
}

@Composable
private fun CriterionEvidenceRow(crit: ReviewCriterion, prUrls: List<String>) {
    val colors = LocalSemanticColors.current
    val uriHandler = LocalUriHandler.current
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
        Text(crit.text, style = MaterialTheme.typography.bodyMedium)
        Text(
            crit.verdict,
            style = MonoStyle,
            color = when (crit.verdict) {
                "approved" -> colors.approval
                "flagged" -> colors.error
                else -> colors.muted
            },
        )
        if (isUnverified(crit.evidence)) {
            Text("unverified", style = MonoStyle, color = colors.muted)
        } else {
            val labels = evidenceLabels(crit.evidence)
            crit.evidence.forEachIndexed { i, e ->
                val url = evidenceOpenUrl(e.kind, e.ref, prUrls)
                val base = Modifier.fillMaxWidth().padding(top = 2.dp)
                if (url != null) {
                    Text(labels[i], style = MonoStyle, color = MaterialTheme.colorScheme.primary,
                        modifier = base.clickable { runCatching { uriHandler.openUri(url) } })
                } else {
                    Text(labels[i], style = MonoStyle, color = colors.muted, modifier = base)
                }
            }
        }
    }
}
```

Note: add `import androidx.compose.foundation.lazy.items` for the `items` extension. This uses a `LazyListScope` extension so both screens (which use LazyColumn) drop it in as `acceptanceCriteriaSection(c.criteria, c.prUrls)`.

- [ ] **Step 2: Delete `EvidenceLink.kt`** (its `evidenceOpenUrl` now lives in `AcceptanceEvidence.kt`, same package). `EvidenceLinkTest` still resolves `evidenceOpenUrl`.

- [ ] **Step 3: Update `ReviewScreen.kt`** — remove the private `CriterionEvidenceRow` and the inline `if (c.criteria.isNotEmpty()) { item {...}; items(...) }` block; replace with `acceptanceCriteriaSection(c.criteria, c.prUrls)` inside the LazyColumn. Remove now-unused imports (`evidenceLabels`, `isUnverified`, `clickable` if unused elsewhere — verify).

- [ ] **Step 4: Compile + run existing tests (regression guard)**

Run: `./gradlew --offline compileDebugKotlin testDebugUnitTest --tests "*EvidenceLinkTest" --tests "*ReviewViewModelTest"`
Expected: compiles; existing review tests still pass (behavior unchanged).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: extract shared acceptanceCriteriaSection + evidenceOpenUrl"
mship journal "extracted shared AC-evidence section; review page unchanged, tests green" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: DoneViewModel surfaces criteria + prUrls

**Files:**
- Modify: `ui/done/DoneViewModel.kt`
- Test: `test/.../DoneViewModelTest.kt` (create if absent; model on `ReviewViewModelTest`)

`DoneContent` gains `criteria: List<ReviewCriterion>` + `prUrls: List<String>`. `fetch()` (which already calls `getItem`, `getTask` per slug, and `getReview` for the summary) additionally surfaces the acceptance criteria — take them from a `getSpec(item.specId)` fetch (or the review record if it already carries criteria) and `prUrls` from the tasks' `pr_urls`.

- [ ] **Step 1: Write the failing test** (MockEngine; assert on awaited `load()`): item with `spec_id`, a task with a PR, and a spec with one commit-evidence criterion → `c.criteria` has it and `c.prUrls` is non-empty. Route `GET /specs/{id}` (or `/specs/{id}/review`) in the handler.

- [ ] **Step 2: Run to verify it fails.** `./gradlew --offline testDebugUnitTest --tests "*DoneViewModelTest"`

- [ ] **Step 3: Implement** — mirror `ReviewViewModel.fetch()`:

```kotlin
// in DoneContent:
val criteria: List<ReviewCriterion> = emptyList(),
val prUrls: List<String> = emptyList(),
// in fetch(), alongside the existing review fetch:
val criteria = item.specId?.let { runCatching { api.getSpec(conn, it) }.getOrNull() }?.acceptanceCriteria ?: emptyList()
val prUrls = tasks.flatMap { it.prUrls.values }.distinct()
DoneUiState.Content(DoneContent(item, tasks, reposTouched, completedAt, review, criteria = criteria, prUrls = prUrls))
```
Import `com.atomikpanda.groundcontrol.data.dto.ReviewCriterion`. Best-effort (`runCatching`) so a spec-fetch failure doesn't fail the done view.

- [ ] **Step 4: Run to verify it passes.**

- [ ] **Step 5: Commit** (`git add -A && git commit -m "feat: done view surfaces acceptance criteria + prUrls"`; `mship journal ...`).
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: Render the shared section on DoneScreen

**Files:**
- Modify: `ui/done/DoneScreen.kt`

- [ ] **Step 1: Add the section.** In `DoneContentView`'s `LazyColumn` (which has `item { HeaderSection }`, `item { ReposTouchedRow }`, `items(c.tasks) {...}`, and `c.review?.let { item { SpecLine } }`), add `acceptanceCriteriaSection(c.criteria, c.prUrls)` (import from `com.atomikpanda.groundcontrol.ui.review`). Place it after the task rows / spec line.

- [ ] **Step 2: Compile + full test run.** `./gradlew --offline compileDebugKotlin testDebugUnitTest` → compiles; all unit tests pass.

- [ ] **Step 3: Commit** (`git add -A && git commit -m "feat: render acceptance-criteria evidence on the done view"`; `mship journal ...`).
<!-- /mship:task -->

---

## Self-Review

**Spec coverage:** ac1 (done view renders section) → Tasks 2+3; ac2 (commit tappable, single-PR, valid on merged PR) → Task 1 `evidenceOpenUrl` + 3; ac3 (single shared component both screens use) → Task 1; ac4 (no-spec item unchanged) → Task 2 (`specId==null` → empty) + `acceptanceCriteriaSection` no-op on empty; ac5 (review page behavior unchanged) → Task 1 Step 4 regression run.

**Risk notes:** verify `DoneScreen`'s LazyColumn structure before inserting the section; confirm `getSpec` vs `getReview` for criteria in DoneViewModel (reuse an existing fetch where possible); ensure removing `EvidenceLink.kt` doesn't orphan imports (`EvidenceLinkTest` imports `evidenceOpenUrl` from the same package, so it still resolves).
