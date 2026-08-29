# GC review page: acceptance-criteria evidence + commit deep-links — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `gc-review-page` (approved, dispatched). WorkItem `wi-20260716165337-cf7c646e`. Worktree: `.worktrees/gc-review-page/ground-control`.

**Goal:** On Ground Control's review page (a WorkItem/task in the review phase with an open PR), show the bound spec's acceptance criteria + their evidence, and make a commit-kind evidence item tap open that commit inside the PR on GitHub mobile.

**Architecture:** GC-only. Evidence (kind/ref/note) is already in `GET /specs/{id}` and modeled by existing DTOs (`SpecRecord.acceptanceCriteria` → `ReviewCriterion.evidence` → `Evidence`). The review ViewModel just doesn't fetch the spec yet. Add (1) a pure `evidenceOpenUrl(...)` link builder, (2) a spec fetch in `ReviewViewModel.fetch()` that adds `criteria` + `prUrls` to `ReviewContent`, (3) an "Acceptance criteria" section in `ReviewScreen` that renders criteria + evidence, with commit/URL evidence tappable via the existing `LocalUriHandler` pattern.

**Tech Stack:** Kotlin, Jetpack Compose (Material3), Ktor client, JUnit4 + Ktor MockEngine. Build/test from `ground-control/android`: `source ~/toolchains/android-env.sh` then `./gradlew --offline compileDebugKotlin testDebugUnitTest`.

---

## File Structure

- **Create** `ui/review/EvidenceLink.kt` — pure `evidenceOpenUrl(kind, ref, prUrls) : String?` (the deep-link/tappability logic).
- **Modify** `ui/review/ReviewViewModel.kt` — `ReviewContent` gains `criteria` + `prUrls`; `fetch()` fetches the bound spec.
- **Modify** `ui/review/ReviewScreen.kt` — render the "Acceptance criteria" section with tappable evidence.
- **Create** `test/.../ui/review/EvidenceLinkTest.kt` — unit tests for the link logic.
- **Modify/Create** `test/.../ui/review/ReviewViewModelTest.kt` — MockEngine test that the spec is fetched + criteria surfaced.

Reuse: `ui/specdetail/Evidence.kt` (`evidenceLabels`, `isUnverified`); the `LocalUriHandler.current` + `uriHandler.openUri(...)` pattern (wrap in `runCatching`, cf. `ui/components/ExternalLinksRow.kt`).

---

<!-- mship:task id=1 -->
### Task 1: Pure deep-link logic — `evidenceOpenUrl`

**Files:**
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/review/EvidenceLink.kt`
- Test: `android/app/src/test/java/com/atomikpanda/groundcontrol/ui/review/EvidenceLinkTest.kt`

Rules (from the spec): commit-kind → tappable ONLY when there is exactly one PR url → `<pr-url>/commits/<sha>`; multi-PR commit → not tappable (null). artifact-kind whose ref is http(s) → the ref; other artifact → null. test-kind → null.

- [ ] **Step 1: Write the failing tests**

```kotlin
package com.atomikpanda.groundcontrol.ui.review

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class EvidenceLinkTest {
    private val onePr = listOf("https://github.com/atomikpanda/mothership/pull/364")
    private val twoPrs = onePr + "https://github.com/atomikpanda/gc/pull/44"

    @Test fun commit_single_pr_builds_in_pr_commit_url() {
        assertEquals(
            "https://github.com/atomikpanda/mothership/pull/364/commits/abc123",
            evidenceOpenUrl("commit", "abc123", onePr),
        )
    }

    @Test fun commit_trailing_slash_pr_is_normalized() {
        assertEquals(
            "https://github.com/atomikpanda/mothership/pull/364/commits/abc123",
            evidenceOpenUrl("commit", "abc123", listOf("https://github.com/atomikpanda/mothership/pull/364/")),
        )
    }

    @Test fun commit_multi_pr_is_not_tappable() {
        assertNull(evidenceOpenUrl("commit", "abc123", twoPrs))
    }

    @Test fun commit_no_pr_is_not_tappable() {
        assertNull(evidenceOpenUrl("commit", "abc123", emptyList()))
    }

    @Test fun artifact_http_ref_opens_ref() {
        assertEquals("https://ci/run/9", evidenceOpenUrl("artifact", "https://ci/run/9", onePr))
    }

    @Test fun artifact_non_url_ref_is_not_tappable() {
        assertNull(evidenceOpenUrl("artifact", "/tmp/report.html", onePr))
    }

    @Test fun test_evidence_is_not_tappable() {
        assertNull(evidenceOpenUrl("test", "test-runs/3", onePr))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./gradlew --offline testDebugUnitTest --tests "*EvidenceLinkTest"`
Expected: FAIL (unresolved reference `evidenceOpenUrl`).

- [ ] **Step 3: Implement `EvidenceLink.kt`**

```kotlin
package com.atomikpanda.groundcontrol.ui.review

/**
 * The URL to open when a piece of acceptance-criterion evidence is tapped, or null when it
 * isn't tappable.
 *
 * - commit: opens the commit inside its PR — but only when the item has exactly one PR url
 *   (a bare commit SHA can't be attributed to a repo on multi-repo items), i.e. `<pr>/commits/<sha>`.
 * - artifact: opens the ref when it is an http(s) URL, else not tappable.
 * - test: never tappable (the ref is an internal test-run id).
 */
fun evidenceOpenUrl(kind: String, ref: String, prUrls: List<String>): String? = when (kind) {
    "commit" -> prUrls.singleOrNull()?.let { "${it.trimEnd('/')}/commits/$ref" }
    "artifact" -> ref.takeIf { it.startsWith("http://") || it.startsWith("https://") }
    else -> null
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `./gradlew --offline testDebugUnitTest --tests "*EvidenceLinkTest"`
Expected: PASS.

- [ ] **Step 5: Commit (pair with `mship journal`)**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/review/EvidenceLink.kt android/app/src/test/java/com/atomikpanda/groundcontrol/ui/review/EvidenceLinkTest.kt
git commit -m "feat: evidenceOpenUrl deep-link logic for review evidence"
mship journal "added evidenceOpenUrl pure link logic; tests green" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: ReviewViewModel fetches the bound spec

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/review/ReviewViewModel.kt`
- Test: `android/app/src/test/java/com/atomikpanda/groundcontrol/ui/review/ReviewViewModelTest.kt`

`ReviewContent` gains `criteria: List<ReviewCriterion>` and `prUrls: List<String>` (the flat list of PR urls, for the link logic). `fetch()`, after building `prs`, fetches the spec when `item.specId != null` and threads its `acceptanceCriteria` in. Confirm the field name on `WorkItemSummary` for the spec id (it is the serialized `spec_id`); use that. `SpecApi.getSpec(conn, id): SpecRecord` already exists.

- [ ] **Step 1: Write the failing test** (Ktor MockEngine; note: assert on the awaited `fetch()` result, do NOT rely on un-awaited side effects — cf. the MockEngine fire-and-forget flake).

```kotlin
// In ReviewViewModelTest.kt — a MockEngine that serves the item, its task, and the spec.
// Item has specId set + one task with a PR; spec has one criterion with a commit evidence.
// After load(), state is Content and c.criteria has the criterion with its evidence,
// and c.prUrls contains the task's PR url.
```

Model it on the existing ReviewViewModel/Console MockEngine tests in the repo (find them with `grep -rl MockEngine android/app/src/test`). The engine routes `GET /items/{id}` → item JSON (with `spec_id`), `GET /tasks/{slug}` → task JSON (with `pr_urls`), `GET /specs/{id}` → spec JSON (with `acceptance_criteria[].evidence`). Assert:
```kotlin
val c = (vm.state.value as ReviewUiState.Content).c
assertEquals(1, c.criteria.size)
assertEquals("commit", c.criteria[0].evidence[0].kind)
assertTrue(c.prUrls.isNotEmpty())
```

- [ ] **Step 2: Run to verify it fails**

Run: `./gradlew --offline testDebugUnitTest --tests "*ReviewViewModelTest"`
Expected: FAIL (`ReviewContent` has no `criteria`/`prUrls`).

- [ ] **Step 3: Implement the fetch**

Update the data class + `fetch()`:

```kotlin
data class ReviewContent(
    val item: WorkItemSummary,
    val prs: List<PrRow>,
    val threadId: String?,
    val criteria: List<ReviewCriterion> = emptyList(),
    val prUrls: List<String> = emptyList(),
)
```

In `fetch()`, after `val prs = ...`:

```kotlin
            val criteria = item.specId
                ?.let { runCatching { api.getSpec(conn, it) }.getOrNull() }
                ?.acceptanceCriteria
                ?: emptyList()
            ReviewUiState.Content(
                ReviewContent(item, prs, item.threadIds.firstOrNull(),
                              criteria = criteria, prUrls = prs.map { it.url }.distinct())
            )
```

Add the imports for `ReviewCriterion` (`com.atomikpanda.groundcontrol.data.dto.ReviewCriterion`). The spec fetch is best-effort (`runCatching`) so a spec-fetch failure never fails the whole review page. A no-spec item (`specId == null`) yields empty criteria → no AC section.

- [ ] **Step 4: Run to verify it passes**

Run: `./gradlew --offline testDebugUnitTest --tests "*ReviewViewModelTest"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/review/ReviewViewModel.kt android/app/src/test/java/com/atomikpanda/groundcontrol/ui/review/ReviewViewModelTest.kt
git commit -m "feat: review page fetches the bound spec's acceptance criteria"
mship journal "ReviewViewModel fetches spec criteria + prUrls; MockEngine test green" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: Render the acceptance-criteria section (tappable evidence)

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/review/ReviewScreen.kt`

Below the existing PR rows, add an "Acceptance criteria" section (only when `c.criteria` is non-empty). Each criterion renders its `text` + a verdict marker, then one line per evidence item (reuse `evidenceLabels(criterion.evidence)`). For each evidence item, compute `evidenceOpenUrl(e.kind, e.ref, c.prUrls)`; when non-null, render the line as clickable → `runCatching { uriHandler.openUri(url) }`; when null, render read-only. Unverified criteria (`isUnverified`) show a muted "unverified" marker (mirror `ui/specdetail/SpecDetailScreen.kt`'s `CriterionRow`).

- [ ] **Step 1: Implement the section** (Compose has no unit test here; the tested logic lives in Tasks 1–2. Keep this rendering thin.)

Add near the top of the composable: `val uriHandler = LocalUriHandler.current` (import `androidx.compose.ui.platform.LocalUriHandler`). After the PR-rows block, add:

```kotlin
if (c.criteria.isNotEmpty()) {
    Text(
        "Acceptance criteria",
        style = MaterialTheme.typography.titleSmall,
        modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 4.dp),
    )
    c.criteria.forEach { crit ->
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
            Text(crit.text, style = MaterialTheme.typography.bodyMedium)
            if (isUnverified(crit.evidence)) {
                Text("unverified", style = MonoStyle, color = MaterialTheme.colorScheme.outline)
            } else {
                crit.evidence.forEachIndexed { i, e ->
                    val label = evidenceLabels(crit.evidence)[i]
                    val url = evidenceOpenUrl(e.kind, e.ref, c.prUrls)
                    val base = Modifier.fillMaxWidth().padding(vertical = 2.dp)
                    if (url != null) {
                        Text(
                            label,
                            style = MonoStyle,
                            color = MaterialTheme.colorScheme.primary,
                            modifier = base.clickable { runCatching { uriHandler.openUri(url) } },
                        )
                    } else {
                        Text(label, style = MonoStyle, color = MaterialTheme.colorScheme.outline, modifier = base)
                    }
                }
            }
        }
    }
}
```

Add imports as needed: `androidx.compose.foundation.clickable`, `androidx.compose.foundation.layout.Column`, and reuse the screen's existing `MonoStyle` import (check the file — `com.atomikpanda.groundcontrol.ui.theme.MonoStyle`), `evidenceLabels`/`isUnverified` from `com.atomikpanda.groundcontrol.ui.specdetail`, and `evidenceOpenUrl` (same package). Match the surrounding column/scroll container the PR rows already sit in (verify whether ReviewContent is a `Column` or `LazyColumn` and place the section consistently).

- [ ] **Step 2: Compile + full test run**

Run: `./gradlew --offline compileDebugKotlin testDebugUnitTest`
Expected: compiles; all unit tests pass (Tasks 1–2 + existing).

- [ ] **Step 3: Commit**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/review/ReviewScreen.kt
git commit -m "feat: render acceptance-criteria evidence on the review page with tappable commit deep-links"
mship journal "review page renders AC evidence + tappable commit links; compiles + tests green" --action committed
```
<!-- /mship:task -->

---

## Self-Review

**Spec coverage:**
- ac1 (fetch spec + render AC section) → Tasks 2 + 3.
- ac2 (commit tappable, single-PR → `<pr>/commits/<sha>`) → Task 1 + 3.
- ac3 (multi-PR commit read-only) → Task 1 (`prUrls.singleOrNull()` → null) + 3.
- ac4 (artifact http ref tappable) → Task 1 + 3.
- ac5 (test read-only) → Task 1 (`else -> null`) + 3.
- ac6 (no-spec item unchanged) → Task 2 (`specId == null` → empty criteria) + 3 (`if (c.criteria.isNotEmpty())`).
- ac7 (reuse Evidence.kt helpers + uriHandler wrapped) → Task 3.

**Consistency:** `evidenceOpenUrl(kind, ref, prUrls)` signature is used identically in Tasks 1 and 3. `ReviewContent.criteria` / `.prUrls` added in Task 2 are consumed in Task 3.

**Risk notes for the implementer:**
- Confirm the `WorkItemSummary` spec-id field name (serialized `spec_id`) before Task 2 — grep `data/dto/*` for the `WorkItemSummary` definition.
- Verify whether `ReviewContent` renders inside a `Column` or `LazyColumn` in `ReviewScreen.kt` and place the AC section with the matching item/scroll idiom.
- MockEngine test (Task 2): assert on the awaited `fetch()`/`state.value`, not on un-awaited fire-and-forget effects (known flake).
