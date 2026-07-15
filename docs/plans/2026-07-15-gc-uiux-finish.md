# GC UI/UX finish — Home needs-you lead + spec-detail readiness/action hierarchy — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `gc-uiux-finish` (approved 2026-07-15). Final bundle of the Ground Control UI/UX review pass (Wins 1,2,4 already shipped).

**Goal:** Make Ground Control's Home screen lead with what needs the operator (with a count and a one-tap funnel into the Queue tab), and make the spec-detail screen surface a spec's readiness at a glance while fixing its inverted action hierarchy.

**Architecture:** Two Ground-Control-client-only (Kotlin/Compose) feature areas, no `mship serve` changes. Feature 1 restructures `HomeScreen` to lead with a "Needs you · N" section + "Review N in Queue →" navigation to `Section.QUEUE`; string logic is extracted into pure, unit-tested helpers. Feature 2 replaces the buried readiness text line on `SpecDetailScreen` with colored counter chips (driven by a unit-tested chip-descriptor helper), gates Approve behind a light confirm, demotes "Plan implementation" to a tonal button, and replaces the bare "▾" caret with a labeled overflow.

**Tech Stack:** Kotlin, Jetpack Compose, Material3, JUnit4 (JVM unit tests only — no emulator), Ktor MockEngine for data-layer tests. Build/verify: `source ~/toolchains/android-env.sh` then `./gradlew --offline compileDebugKotlin testDebugUnitTest` (run from `ground-control/android`).

**Testing reality for Compose UI:** Pure composition and remembered UI state (e.g. a dialog's `mutableStateOf`) are not exercised by the JVM unit suite (no Robolectric/Compose-test here). So each task pushes the *testable logic* (label strings, chip descriptors, counts) into plain functions/ViewModel state and unit-tests those; the composable wiring that consumes them is verified by `compileDebugKotlin` + the existing suite staying green. Tasks note which parts are unit-tested vs compile-verified — do not fabricate UI-instrumentation tests.

**File map:**
- `ui/home/HomeStrings.kt` (Create) — pure label helpers for the Needs-you header + Queue CTA.
- `ui/home/HomeScreen.kt` (Modify) — lead with the Needs-you section; add `onReviewInQueue` param; caught-up empty state; reorder rail/threads below.
- `ui/specdetail/Readiness.kt` (Create) — pure chip-descriptor helper mapping a `Summary` to labeled/colored chips.
- `ui/specdetail/SpecDetailScreen.kt` (Modify) — readiness chips row; Approve light-confirm; tonal "Plan implementation"; labeled overflow.
- `GroundControlApp.kt` (Modify) — wire `onReviewInQueue` to navigate to `Section.QUEUE.route`.
- Tests: `HomeStringsTest.kt`, `ReadinessTest.kt` (Create).

---

<!-- mship:task id=1 -->
### Task 1: Home — pure label helpers for the Needs-you header + Queue CTA

**Files:**
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/home/HomeStrings.kt`
- Test: `android/app/src/test/java/com/atomikpanda/groundcontrol/HomeStringsTest.kt`

Rationale: The header ("Needs you · N") and funnel CTA ("Review N in Queue") strings and the count-zero branch are the unit-testable core of Feature 1. Extract them so the composable in Task 2 is a thin consumer.

- [ ] **Step 1: Write the failing test**

```kotlin
package com.atomikpanda.groundcontrol

import com.atomikpanda.groundcontrol.ui.home.needsYouHeader
import com.atomikpanda.groundcontrol.ui.home.reviewInQueueCta
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HomeStringsTest {
    @Test fun header_shows_count_when_positive() {
        assertEquals("Needs you · 3", needsYouHeader(3))
        assertEquals("Needs you · 1", needsYouHeader(1))
    }

    @Test fun header_is_caughtup_label_when_zero() {
        // Zero is a distinct caught-up state, never "Needs you · 0".
        assertEquals("You're all caught up", needsYouHeader(0))
    }

    @Test fun cta_reflects_count_and_is_null_when_zero() {
        assertEquals("Review 3 in Queue", reviewInQueueCta(3))
        assertEquals("Review 1 in Queue", reviewInQueueCta(1))
        assertNull(reviewInQueueCta(0))   // no funnel action in the caught-up state
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `ground-control/android`): `source ~/toolchains/android-env.sh && ./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.HomeStringsTest"`
Expected: FAIL — unresolved reference `needsYouHeader` / `reviewInQueueCta`.

- [ ] **Step 3: Write minimal implementation**

```kotlin
package com.atomikpanda.groundcontrol.ui.home

/**
 * Header label for Home's leading "Needs you" section. A positive count reads "Needs you · N";
 * zero is a distinct caught-up state (never "Needs you · 0", which would look like an action).
 */
fun needsYouHeader(count: Int): String =
    if (count > 0) "Needs you · $count" else "You're all caught up"

/**
 * CTA that funnels into the Queue tab. Null when there is nothing to review, so the caught-up
 * state shows no action. N is the needs-you count (matches the header).
 */
fun reviewInQueueCta(count: Int): String? =
    if (count > 0) "Review $count in Queue" else null
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.HomeStringsTest"`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit (pair with `mship journal`)**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/home/HomeStrings.kt \
        android/app/src/test/java/com/atomikpanda/groundcontrol/HomeStringsTest.kt
git commit -m "feat(home): pure label helpers for needs-you header + queue CTA"
mship journal "Home needs-you label helpers + tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: Home — lead with the Needs-you section + funnel into the Queue tab

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/home/HomeScreen.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApp.kt`
- Test: `android/app/src/test/java/com/atomikpanda/groundcontrol/HomeViewModelTest.kt` (existing — must stay green)

This is composition + navigation wiring, verified by `compileDebugKotlin` + the existing HomeViewModel suite (which already asserts `c.items.size`, the count the header consumes). **Operator-decided ordering (2026-07-15, refines AC1/AC4):** the workspace rail (scope control) stays on top; the Needs-you section moves above ONLY the threads sticky card — i.e. it sits below the rail / error chips / "Browse this workspace", and above the threads card. This preserves "needs-you leads the content" while keeping the workspace filter accessible and not reverting the thread-findability card placement further than necessary.

- [ ] **Step 1: Add the `onReviewInQueue` param and reposition the Needs-you section in `HomeScreen`**

Add the parameter to the `HomeScreen` signature (after `onOpenThreads`):

```kotlin
    onOpenThreads: () -> Unit,
    onReviewInQueue: () -> Unit,
) {
```

Add this import at the top of `HomeScreen.kt` (`LocalSemanticColors` is already imported — add only `ArrowForward`):

```kotlin
import androidx.compose.material.icons.automirrored.filled.ArrowForward
```

Inside the `is HomeUiState.Content -> LazyColumn(...)` block, insert the Needs-you section IMMEDIATELY BEFORE the threads sticky card block (the `if (messagesState is MessagesUiState.Content) { ... }`). Concretely, place it after the `// "Browse this workspace" when scoped to one` block and before the `// Sticky threads card` comment:

```kotlin
                // Needs-you leads the content (spec gc-uiux-finish; operator ordering: rail stays on
                // top, needs-you sits just above the threads card). Header + count + one-tap funnel
                // into the Queue tab; zero items shows a calm caught-up state with no funnel.
                item {
                    NeedsYouHeader(
                        count = s.items.size,
                        onReviewInQueue = onReviewInQueue,
                    )
                }
                items(s.items, key = { it.key }) { item ->
                    NeedsYouRow(item, onApproval, onQuestion, onBlocker)
                }
```

Then DELETE the old needs-you block lower down (the comment `// The "Needs you" queue` and its `items(s.items, key = { it.key }) { ... }`) so it is not rendered twice. Also DELETE the old catch-all empty-state block (the `if (s.items.isEmpty() && s.notes.isEmpty() && s.errors.isEmpty()) { item { Box ... "Nothing needs you right now." } }`) — the caught-up state now lives inside `NeedsYouHeader`.

Leave the workspace chip rail, error chips, and "Browse this workspace" ABOVE the inserted section (unchanged). The threads sticky card, the `ThreadStateChipRow`, and the "New messages" notes section stay where they are — now naturally BELOW the needs-you section.

- [ ] **Step 2: Add the `NeedsYouHeader` composable**

Add near the other private composables in `HomeScreen.kt`:

```kotlin
@Composable
private fun NeedsYouHeader(count: Int, onReviewInQueue: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(16.dp, 12.dp, 16.dp, 4.dp)) {
        Text(
            needsYouHeader(count),
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.Bold,
        )
        reviewInQueueCta(count)?.let { cta ->
            TextButton(
                onClick = onReviewInQueue,
                modifier = Modifier.padding(top = 4.dp),
            ) {
                Text(cta)
                Icon(
                    Icons.AutoMirrored.Filled.ArrowForward,
                    contentDescription = null,
                    modifier = Modifier.padding(start = 4.dp).size(18.dp),
                )
            }
        }
    }
}
```

Add these imports if not already present in the file: `androidx.compose.foundation.layout.size` (for `Modifier.size`). `Column`, `Modifier`, `padding`, `fillMaxWidth`, `Text`, `TextButton`, `Icon`, `MaterialTheme`, `FontWeight`, `dp` are already imported.

- [ ] **Step 3: Wire the navigation in `GroundControlApp.kt`**

In the `composable(Section.HOME.route)` block, add the `onReviewInQueue` argument to the `HomeScreen(...)` call:

```kotlin
                    onOpenThreads = { nav.navigate("threads") },
                    onReviewInQueue = { nav.navigate(Section.QUEUE.route) { launchSingleTop = true } },
                )
```
(`Section` is already imported in `GroundControlApp.kt`.)

- [ ] **Step 4: Compile + run the full unit suite**

Run (from `ground-control/android`): `source ~/toolchains/android-env.sh && ./gradlew --offline compileDebugKotlin testDebugUnitTest`
Expected: BUILD SUCCESSFUL; all tests pass (HomeViewModelTest still green — the count the header reads is `items.size`, unchanged).

- [ ] **Step 5: Commit (pair with `mship journal`)**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/home/HomeScreen.kt \
        android/app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApp.kt
git commit -m "feat(home): lead with needs-you section + one-tap Review-in-Queue funnel"
mship journal "Home leads with needs-you + queue funnel; compiles, suite green" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: Spec-detail — readiness counter chips

**Files:**
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/Readiness.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/SpecDetailScreen.kt`
- Test: `android/app/src/test/java/com/atomikpanda/groundcontrol/ReadinessTest.kt`

The chip *descriptors* (label text + which semantic role) are derived from the `Summary` and are unit-testable; the chip rendering is a thin composable. `Summary` has `approved`, `criteriaTotal`, `flagged`, `unansweredQuestions` (see `SpecDetailScreen.kt` line ~126 usage). The semantic role is expressed as an enum so the test never touches `Color`.

- [ ] **Step 1: Write the failing test**

```kotlin
package com.atomikpanda.groundcontrol

import com.atomikpanda.groundcontrol.data.Summary
import com.atomikpanda.groundcontrol.ui.specdetail.ChipRole
import com.atomikpanda.groundcontrol.ui.specdetail.readinessChips
import org.junit.Assert.assertEquals
import org.junit.Test

class ReadinessTest {
    @Test fun builds_three_chips_from_summary() {
        val chips = readinessChips(Summary(approved = 2, criteriaTotal = 5, flagged = 1, unansweredQuestions = 3))
        assertEquals(
            listOf(
                "2/5 approved" to ChipRole.APPROVED,
                "1 flagged" to ChipRole.FLAGGED,
                "3 unanswered" to ChipRole.UNANSWERED,
            ),
            chips.map { it.label to it.role },
        )
    }

    @Test fun zero_values_still_render_all_three_chips() {
        val chips = readinessChips(Summary(approved = 0, criteriaTotal = 0, flagged = 0, unansweredQuestions = 0))
        assertEquals(listOf("0/0 approved", "0 flagged", "0 unanswered"), chips.map { it.label })
        assertEquals(listOf(ChipRole.APPROVED, ChipRole.FLAGGED, ChipRole.UNANSWERED), chips.map { it.role })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.ReadinessTest"`
Expected: FAIL — unresolved reference `readinessChips` / `ChipRole`.

- [ ] **Step 3: Write minimal implementation**

```kotlin
package com.atomikpanda.groundcontrol.ui.specdetail

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.atomikpanda.groundcontrol.data.Summary
import com.atomikpanda.groundcontrol.ui.theme.LocalSemanticColors

/** Semantic role for a readiness chip; kept color-free so it is unit-testable. */
enum class ChipRole { APPROVED, FLAGGED, UNANSWERED }

data class ReadinessChip(val label: String, val role: ChipRole)

/** Derive the three readiness chips from a spec's [Summary]. Always three chips, even at zero. */
fun readinessChips(sum: Summary): List<ReadinessChip> = listOf(
    ReadinessChip("${sum.approved}/${sum.criteriaTotal} approved", ChipRole.APPROVED),
    ReadinessChip("${sum.flagged} flagged", ChipRole.FLAGGED),
    ReadinessChip("${sum.unansweredQuestions} unanswered", ChipRole.UNANSWERED),
)

@Composable
fun ReadinessChipsRow(sum: Summary, modifier: Modifier = Modifier) {
    val colors = LocalSemanticColors.current
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        readinessChips(sum).forEach { chip ->
            val tint = when (chip.role) {
                ChipRole.APPROVED -> colors.approval
                ChipRole.FLAGGED -> colors.error
                ChipRole.UNANSWERED -> colors.muted
            }
            AssistChip(
                onClick = {},
                enabled = false,
                label = { Text(chip.label) },
                colors = AssistChipDefaults.assistChipColors(
                    disabledLabelColor = tint,
                    disabledLeadingIconContentColor = tint,
                ),
            )
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.ReadinessTest"`
Expected: PASS (2 tests).

- [ ] **Step 5: Swap the buried readiness line for the chips row in `SpecDetailScreen.kt`**

In `ContentView`, inside the first `item { Column(...) { ... } }`, replace the readiness `Text(...)` (the `"${sum.approved}/${sum.criteriaTotal} approved · ${sum.flagged} flagged · ${sum.unansweredQuestions} unanswered Q"` bodySmall line) with:

```kotlin
                    ReadinessChipsRow(sum, Modifier.padding(top = 6.dp))
```

Keep the `val sum = d.summary` binding, the status banner line, and the `repos:` line as they are. Add no new import for `ReadinessChipsRow` — it is in the same package (`com.atomikpanda.groundcontrol.ui.specdetail`).

- [ ] **Step 6: Compile + run the full suite**

Run: `source ~/toolchains/android-env.sh && ./gradlew --offline compileDebugKotlin testDebugUnitTest`
Expected: BUILD SUCCESSFUL; all tests pass.

- [ ] **Step 7: Commit (pair with `mship journal`)**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/Readiness.kt \
        android/app/src/test/java/com/atomikpanda/groundcontrol/ReadinessTest.kt \
        android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/SpecDetailScreen.kt
git commit -m "feat(specdetail): promote readiness summary to colored counter chips"
mship journal "Spec-detail readiness chips + helper tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: Spec-detail — action hierarchy (Approve light-confirm, tonal Plan-implementation, labeled overflow)

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/SpecDetailScreen.kt`

All changes are in the `ActionBar` composable and are compile-verified UI (the confirm-gate is remembered Compose state — not exercised by the JVM suite). No ViewModel change: `vm.approve(bypass=false)` is unchanged; only a confirmation step is inserted before it. Reuse the existing `ConfirmDialog` composable already defined in this file (used today for "Plan implementation").

- [ ] **Step 1: Gate Approve behind a light confirm**

In `ActionBar`, add a confirm flag beside the existing ones:

```kotlin
    var showApproveConfirm by remember { mutableStateOf(false) }
```

Change the primary Approve button so it opens the confirm instead of approving immediately. Replace:

```kotlin
                    Button(enabled = !busy, onClick = { vm.approve(bypass = false) }) { Text("Approve") }
```
with:
```kotlin
                    Button(enabled = !busy, onClick = { showApproveConfirm = true }) { Text("Approve") }
```

At the bottom of `ActionBar`, next to the other dialog triggers (`if (showReason) ...`, `if (showDispatch) ...`), add:

```kotlin
    if (showApproveConfirm) ConfirmDialog(
        title = "Approve this spec?",
        body = "Marks the spec approved and unblocks implementation.",
        confirm = "Approve",
        onDismiss = { showApproveConfirm = false },
    ) { showApproveConfirm = false; vm.approve(bypass = false) }
```

- [ ] **Step 2: Replace the bare "▾" caret with a labeled overflow**

Replace the caret `TextButton` inside the Approve `Box`:

```kotlin
                    TextButton(enabled = !busy, onClick = { menu = true }) { Text("▾") }
```
with an icon button carrying a content description:
```kotlin
                    IconButton(enabled = !busy, onClick = { menu = true }) {
                        Icon(Icons.Filled.MoreVert, contentDescription = "More approve actions")
                    }
```

Add the import: `import androidx.compose.material.icons.filled.MoreVert`. (`IconButton` and `Icon` are already imported in this file.)

The `DropdownMenu` with the "Approve anyway" item stays exactly as-is.

- [ ] **Step 3: Demote "Plan implementation" to a tonal (secondary) button**

Make "Plan implementation" visually subordinate to the filled Approve. Replace:

```kotlin
            if (SpecAction.DISPATCH in actions)
                Button(enabled = !busy, onClick = { showDispatch = true }) { Text("Plan implementation") }
```
with:
```kotlin
            if (SpecAction.DISPATCH in actions)
                FilledTonalButton(enabled = !busy, onClick = { showDispatch = true }) { Text("Plan implementation") }
```

Add the import: `import androidx.compose.material3.FilledTonalButton`. The existing "Plan implementation" `ConfirmDialog` (`if (showDispatch) ...`) stays unchanged — it keeps its own confirm; Approve now has a comparable light confirm, so the friction is no longer inverted.

- [ ] **Step 4: Compile + run the full suite**

Run: `source ~/toolchains/android-env.sh && ./gradlew --offline compileDebugKotlin testDebugUnitTest`
Expected: BUILD SUCCESSFUL; all tests pass (no test changes — this task is compile-verified UI).

- [ ] **Step 5: Commit (pair with `mship journal`)**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/SpecDetailScreen.kt
git commit -m "feat(specdetail): fix action hierarchy — Approve light-confirm, tonal Plan-implementation, labeled overflow"
mship journal "Spec-detail action hierarchy fixed; compiles, suite green" --action committed
```
<!-- /mship:task -->

---

## Self-review

**Spec coverage:**
- AC1 (Needs-you · N first block, above rail + threads) → Task 2 (section inserted first; old block deleted).
- AC2 (control navigates to Queue, label reflects count) → Task 1 (`reviewInQueueCta`) + Task 2 (`onReviewInQueue` → `Section.QUEUE.route`).
- AC3 (zero items → caught-up, no Queue action) → Task 1 (`needsYouHeader(0)` / `reviewInQueueCta(0)==null`) + Task 2 (header renders no CTA).
- AC4 (rail + threads card still render, below) → Task 2 (blocks left in place, now below the inserted section).
- AC5 (readiness as colored counter chips) → Task 3.
- AC6 (Approve single filled primary + light confirm) → Task 4 Step 1.
- AC7 (Plan-implementation secondary/tonal) → Task 4 Step 3.
- AC8 (labeled overflow replaces caret) → Task 4 Step 2.

**Placeholder scan:** none — every step has concrete code/commands.

**Type consistency:** `needsYouHeader`/`reviewInQueueCta` (Task 1) consumed in Task 2; `readinessChips`/`ChipRole`/`ReadinessChip`/`ReadinessChipsRow` (Task 3) names match between impl, test, and the `SpecDetailScreen` call site; `Summary` fields (`approved`, `criteriaTotal`, `flagged`, `unansweredQuestions`) match existing usage in `SpecDetailScreen.kt`.

## Resolved ordering decision (2026-07-15)
Spec AC1/AC4 literally place the Needs-you section above the workspace rail AND the threads sticky card. That threads card was deliberately pinned above needs-you by the later `ground-control-thread-findability` spec, and the workspace rail is Home's scope control. **The operator chose:** keep the workspace rail on top, and move needs-you above the threads card only. Task 2 (above) is written to that resolution. For spec-compliance review: AC1 "above the workspace rail" is intentionally relaxed per this operator decision — needs-you leads the *content* (above the threads card) while the rail remains the top scope control; AC2/AC3 and everything else are unaffected.
