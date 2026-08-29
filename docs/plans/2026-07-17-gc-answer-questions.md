# gc-answer-questions — Implementation Plan

**Spec id:** `gc-answer-questions` (approved + dispatched)
**REQUIRED SUB-SKILL:** Use the `test-driven-development` skill for every task below (write the failing test first, watch it fail, implement the minimum, watch it pass, commit).

**Goal:** Make ANSWERING open questions the obvious path to approving a review-phase spec (so a spec with a question is never a dead-end that gets bounced to draft), and fix the flagged question-UX ergonomics: multi-line answer/ask fields, a disabled-when-blank primary submit, a Request-changes *bottom sheet* (not a dialog), and drafts that survive navigation.

**Architecture:** Ground Control only. No serve change — the inline answer POST + server-side auto-approve already work; this makes that flow discoverable + ergonomic. All new decision logic (lead condition, sole-blocker computation) lives in pure functions co-located with `Readiness.kt` and surfaced as computed vals on `SpecDetail`, so it is unit-testable without a render. Draft preservation lives in `SpecDetailViewModel` as flows independent of the load lifecycle, so it survives a leave+return. UI wiring reuses the two existing shared components — `MultilineComposeInput` (#282) and the `ModalBottomSheet` idiom — never forks new ones.

**Tech stack:** Kotlin / Jetpack Compose (Material3), JUnit4 + kotlinx-coroutines-test + Ktor `MockEngine` (the `vm(scope, handler)` harness). Module `:app` under `android/`.

**Conventions for every task below**
- All commands run from the module dir: `/home/bailey/development/repos/mship-workspace/.worktrees/gc-answer-questions/ground-control/android`
- Before any Gradle call: `source ~/toolchains/android-env.sh`
- Repo root for `git`: `/home/bailey/development/repos/mship-workspace/.worktrees/gc-answer-questions/ground-control` (already on branch `feat/gc-answer-questions`).
- Em dash `—` is used literally in the lead/guidance strings; tests and code must match byte-for-byte.

## File Structure

| File | Change |
|---|---|
| `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/Readiness.kt` | ADD pure fns `unansweredLeadText`, `unansweredQuestionsLead`, `soleBlockerApproveLabel` |
| `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/SpecDetailViewModel.kt` | ADD `SpecDetail.unansweredLead` / `.approveGuidance` computed vals; ADD draft-preservation flows + setters; clear-on-success in `answer`/`ask` via `write(onSuccess=…)` |
| `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/SpecDetailScreen.kt` | ADD lead banner; approve-control guidance line; `QuestionRow`/`AskQuestionRow` → `MultilineComposeInput` bound to VM drafts; Request-changes dialog → `RequestChangesSheet` (ModalBottomSheet) |
| `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/queue/QueueScreen.kt` | ADD `QuestionsCard` lead banner reusing `unansweredLeadText` |
| `android/app/src/test/java/com/atomikpanda/groundcontrol/ReadinessTest.kt` | ADD tests for the 3 pure fns (ac1/ac2/ac5 logic) |
| `android/app/src/test/java/com/atomikpanda/groundcontrol/SpecDetailViewModelTest.kt` | ADD tests: lead/guidance surface from loaded Content; auto-approve clears them (ac4); draft preservation keyed per question (ac9) |
| `…/ui/components/MultilineComposeInput.kt` | REUSE (no change) — #282 auto-expanding box, `sendEnabled = value.isNotBlank()` already disables blank submit |
| `…/data/SpecActions.kt` | REUSE (no change) — `Summary`, `isReviewInteractive` |

---

<!-- mship:task id=1 -->
## Task 1 — Lead + sole-blocker pure functions (ac1, ac2, ac5 logic)

**Files:**
- `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/Readiness.kt`
- `android/app/src/test/java/com/atomikpanda/groundcontrol/ReadinessTest.kt`

**Step 1 — Write the failing test.** Append these to `ReadinessTest.kt`, and add the imports `import org.junit.Assert.assertNull`, `import com.atomikpanda.groundcontrol.ui.specdetail.unansweredLeadText`, `import com.atomikpanda.groundcontrol.ui.specdetail.unansweredQuestionsLead`, `import com.atomikpanda.groundcontrol.ui.specdetail.soleBlockerApproveLabel` at the top (alongside the existing `readinessChips`/`ChipRole` imports):

```kotlin
    @Test fun unanswered_lead_text_formats_count() {
        assertEquals("2 unanswered question(s) — answer to approve", unansweredLeadText(2))
        assertEquals("1 unanswered question(s) — answer to approve", unansweredLeadText(1))
    }

    @Test fun lead_shows_only_in_review_with_unanswered_questions() {
        val sum = Summary(criteriaTotal = 3, approved = 3, flagged = 0, unreviewed = 0, unansweredQuestions = 2)
        assertEquals("2 unanswered question(s) — answer to approve", unansweredQuestionsLead("needs_review", sum))
        // ac5: no open questions → no lead
        assertNull(unansweredQuestionsLead("needs_review", sum.copy(unansweredQuestions = 0)))
        // not a review-phase spec → no lead
        assertNull(unansweredQuestionsLead("approved", sum))
    }

    @Test fun sole_blocker_label_only_when_questions_are_the_only_blocker() {
        // all criteria approved, 1 unanswered question → questions are the sole blocker
        assertEquals(
            "Answer 1 question(s) to approve",
            soleBlockerApproveLabel("needs_review", Summary(2, 2, 0, 0, 1)),
        )
        // a flagged criterion also blocks → not sole → null
        assertNull(soleBlockerApproveLabel("needs_review", Summary(2, 1, 1, 0, 1)))
        // an unreviewed criterion also blocks → not sole → null
        assertNull(soleBlockerApproveLabel("needs_review", Summary(2, 1, 0, 1, 1)))
        // no unanswered questions → nothing to guide toward → null
        assertNull(soleBlockerApproveLabel("needs_review", Summary(2, 2, 0, 0, 0)))
        // not review-phase → null
        assertNull(soleBlockerApproveLabel("approved", Summary(2, 2, 0, 0, 1)))
    }
```

**Step 2 — Run to fail:**
```
source ~/toolchains/android-env.sh
./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.ReadinessTest"
```
Expect: unresolved-reference compile failure (`unansweredLeadText` etc. don't exist).

**Step 3 — Implement.** Append to `Readiness.kt` (add `import com.atomikpanda.groundcontrol.data.isReviewInteractive` to the import block):

```kotlin
/** The single lead-banner copy pointing the operator at answering as the path to approval.
 *  Shared by spec-detail and the Queue's QuestionsCard so both surfaces speak the same words. */
fun unansweredLeadText(count: Int): String = "$count unanswered question(s) — answer to approve"

/** Lead shown atop a review-phase spec when >=1 open question is unanswered; null otherwise so a
 *  spec with no open questions renders unchanged (ac5). Reuses the [Summary], not a re-derivation. */
fun unansweredQuestionsLead(status: String, sum: Summary): String? =
    if (isReviewInteractive(status) && sum.unansweredQuestions > 0) unansweredLeadText(sum.unansweredQuestions)
    else null

/** Approve-control guidance when unanswered questions are the ONLY approval blocker — i.e. every
 *  criterion is already approved (none flagged or unreviewed) and >=1 question is unanswered:
 *  'Answer N question(s) to approve'. Null otherwise (generic Approve). Reuses the [Summary]'s
 *  counts rather than re-deriving the server approval gate. */
fun soleBlockerApproveLabel(status: String, sum: Summary): String? =
    if (isReviewInteractive(status) && sum.unansweredQuestions > 0 && sum.flagged == 0 && sum.unreviewed == 0)
        "Answer ${sum.unansweredQuestions} question(s) to approve"
    else null
```

**Step 4 — Run to pass:** rerun the Step-2 command. Expect green.

**Step 5 — Commit:**
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-answer-questions/ground-control add -A
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-answer-questions/ground-control commit -m "gc-answer-questions: lead + sole-blocker pure functions

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "lead/sole-blocker pure functions + ReadinessTest coverage" --task gc-answer-questions --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=2 -->
## Task 2 — Surface lead + guidance on SpecDetail; auto-approve clears them (ac1, ac2, ac4, ac5)

**Files:**
- `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/SpecDetailViewModel.kt`
- `android/app/src/test/java/com/atomikpanda/groundcontrol/SpecDetailViewModelTest.kt`

**Step 1 — Write the failing test.** Add `import org.junit.Assert.assertNull` to `SpecDetailViewModelTest.kt`, then append these test methods:

```kotlin
    @Test fun lead_and_guidance_surface_for_review_spec_with_sole_unanswered_blocker() = runTest {
        val vm = vm(this) {
            respond("""{"id":"s1","title":"T","status":"needs_review","body":"b",
                "acceptance_criteria":[{"id":"ac1","text":"a","verdict":"approved"}],
                "open_questions":[{"id":"q1","text":"q","answer":null}]}""", HttpStatusCode.OK, jsonHdr)
        }
        vm.load()?.join()
        val d = (vm.state.value as SpecDetailUiState.Content).detail
        assertEquals("1 unanswered question(s) — answer to approve", d.unansweredLead)   // ac1
        assertEquals("Answer 1 question(s) to approve", d.approveGuidance)               // ac2
    }

    @Test fun no_lead_or_guidance_when_no_open_questions() = runTest {                    // ac5
        val vm = vm(this) {
            respond("""{"id":"s1","title":"T","status":"needs_review","body":"b",
                "acceptance_criteria":[{"id":"ac1","text":"a","verdict":"approved"}],"open_questions":[]}""",
                HttpStatusCode.OK, jsonHdr)
        }
        vm.load()?.join()
        val d = (vm.state.value as SpecDetailUiState.Content).detail
        assertNull(d.unansweredLead)
        assertNull(d.approveGuidance)
    }

    @Test fun answering_last_question_auto_approves_and_clears_lead_and_guidance() = runTest {   // ac4
        var call = 0
        val vm = vm(this) {
            call++
            if (call == 1) respond("""{"id":"s1","title":"T","status":"needs_review","body":"b",
                "acceptance_criteria":[{"id":"ac1","text":"a","verdict":"approved"}],
                "open_questions":[{"id":"q1","text":"q","answer":null}]}""", HttpStatusCode.OK, jsonHdr)
            else respond("""{"id":"s1","status":"approved",
                "acceptance_criteria":[{"id":"ac1","text":"a","verdict":"approved"}],
                "open_questions":[{"id":"q1","text":"q","answer":"yes"}],
                "summary":{"criteria_total":1,"approved":1,"flagged":0,"unreviewed":0,"open_questions_unanswered":0}}""",
                HttpStatusCode.OK, jsonHdr)
        }
        vm.load()?.join()
        assertNotNull((vm.state.value as SpecDetailUiState.Content).detail.approveGuidance)  // blocked before
        vm.answer("q1", "yes")?.join()
        val d = (vm.state.value as SpecDetailUiState.Content).detail
        assertEquals("approved", d.status)   // server auto-approved on the answer POST; no Request-changes
        assertNull(d.unansweredLead)
        assertNull(d.approveGuidance)
    }
```

**Step 2 — Run to fail:**
```
source ~/toolchains/android-env.sh
./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.SpecDetailViewModelTest"
```
Expect: unresolved-reference (`d.unansweredLead` / `d.approveGuidance` don't exist).

**Step 3 — Implement.** In `SpecDetailViewModel.kt`, add two computed vals to the `SpecDetail` data class body, next to the existing `summary` val (same package as `Readiness.kt`, so no import needed):

```kotlin
    val summary: Summary get() = summaryOf(criteria, questions)

    /** Prominent lead atop the screen when this review-phase spec has unanswered questions (ac1);
     *  null when there are none (ac5). */
    val unansweredLead: String? get() = unansweredQuestionsLead(status, summary)

    /** Approve-control guidance when unanswered questions are the sole approval blocker (ac2);
     *  null otherwise. */
    val approveGuidance: String? get() = soleBlockerApproveLabel(status, summary)
```

No other change: `answer()` already routes through `applyReview`, which patches `status` from the returned review, so a server auto-approve flips `status` to `approved` and both computed vals recompute to null.

**Step 4 — Run to pass:** rerun Step-2 command. Expect green (all existing tests still pass).

**Step 5 — Commit:**
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-answer-questions/ground-control add -A
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-answer-questions/ground-control commit -m "gc-answer-questions: surface lead + approve guidance on SpecDetail

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "SpecDetail.unansweredLead/approveGuidance + auto-approve clears them (ac1/ac2/ac4/ac5)" --task gc-answer-questions --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=3 -->
## Task 3 — Draft preservation in the ViewModel, keyed per question (ac9)

**Files:**
- `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/SpecDetailViewModel.kt`
- `android/app/src/test/java/com/atomikpanda/groundcontrol/SpecDetailViewModelTest.kt`

**Step 1 — Write the failing test.** Append to `SpecDetailViewModelTest.kt`:

```kotlin
    @Test fun unsent_answer_and_ask_drafts_survive_leave_and_return_keyed_per_question() = runTest {  // ac9
        val vm = vm(this) {
            respond("""{"id":"s1","title":"T","status":"needs_review","body":"b","acceptance_criteria":[],
                "open_questions":[{"id":"q1","text":"q1","answer":null},{"id":"q2","text":"q2","answer":null}]}""",
                HttpStatusCode.OK, jsonHdr)
        }
        vm.load()?.join()
        vm.setAnswerDraft("q1", "half-typed one")
        vm.setAnswerDraft("q2", "half-typed two")
        vm.setAskDraft("a new question I'm still writing")
        // Leaving + returning re-runs load(); the unsent drafts must NOT be silently dropped.
        vm.load()?.join()
        assertEquals("half-typed one", vm.answerDrafts.value["q1"])
        assertEquals("half-typed two", vm.answerDrafts.value["q2"])   // per-question, no cross-contamination
        assertEquals("a new question I'm still writing", vm.askDraft.value)
    }

    @Test fun sending_an_answer_clears_only_that_questions_draft() = runTest {
        var call = 0
        val vm = vm(this) {
            call++
            if (call == 1) respond("""{"id":"s1","title":"T","status":"needs_review","body":"b","acceptance_criteria":[],
                "open_questions":[{"id":"q1","text":"q1","answer":null},{"id":"q2","text":"q2","answer":null}]}""",
                HttpStatusCode.OK, jsonHdr)
            else respond("""{"id":"s1","status":"needs_review","acceptance_criteria":[],
                "open_questions":[{"id":"q1","text":"q1","answer":"done"},{"id":"q2","text":"q2","answer":null}],
                "summary":{"criteria_total":0,"approved":0,"flagged":0,"unreviewed":0,"open_questions_unanswered":1}}""",
                HttpStatusCode.OK, jsonHdr)
        }
        vm.load()?.join()
        vm.setAnswerDraft("q1", "done")
        vm.setAnswerDraft("q2", "still typing")
        vm.answer("q1", "done")?.join()
        assertNull(vm.answerDrafts.value["q1"])                 // cleared on successful send
        assertEquals("still typing", vm.answerDrafts.value["q2"])  // sibling draft untouched
    }

    @Test fun sending_a_question_clears_the_ask_draft() = runTest {
        var call = 0
        val vm = vm(this) {
            call++
            if (call == 1) respond("""{"id":"s1","title":"T","status":"needs_review","body":"b",
                "acceptance_criteria":[],"open_questions":[]}""", HttpStatusCode.OK, jsonHdr)
            else respond("""{"id":"s1","status":"needs_review","acceptance_criteria":[],
                "open_questions":[{"id":"q9","text":"new q","answer":null}],
                "summary":{"criteria_total":0,"approved":0,"flagged":0,"unreviewed":0,"open_questions_unanswered":1}}""",
                HttpStatusCode.OK, jsonHdr)
        }
        vm.load()?.join()
        vm.setAskDraft("new q")
        vm.ask("new q")?.join()
        assertEquals("", vm.askDraft.value)
    }
```

**Step 2 — Run to fail:**
```
source ~/toolchains/android-env.sh
./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.SpecDetailViewModelTest"
```
Expect: unresolved-reference (`answerDrafts` / `askDraft` / `setAnswerDraft` / `setAskDraft` don't exist).

**Step 3 — Implement.** In `SpecDetailViewModel.kt`:

(a) Add draft flows + setters near `_state` (these are independent of the load lifecycle, so they survive a `load()`):

```kotlin
    // Unsent free-text drafts kept OUTSIDE the load lifecycle so they survive a leave+return (ac9).
    // Answer drafts are keyed by question id so switching questions never cross-contaminates.
    private val _answerDrafts = MutableStateFlow<Map<String, String>>(emptyMap())
    val answerDrafts: StateFlow<Map<String, String>> = _answerDrafts.asStateFlow()

    private val _askDraft = MutableStateFlow("")
    val askDraft: StateFlow<String> = _askDraft.asStateFlow()

    fun setAnswerDraft(questionId: String, text: String) {
        _answerDrafts.value = _answerDrafts.value + (questionId to text)
    }

    private fun clearAnswerDraft(questionId: String) {
        _answerDrafts.value = _answerDrafts.value - questionId
    }

    fun setAskDraft(text: String) { _askDraft.value = text }
```

(b) Give `write` an optional success hook (default no-op keeps existing callers unchanged) — change the signature and the `onSuccess` branch:

```kotlin
    private fun write(ref: ActionRef, onSuccess: () -> Unit = {}, block: suspend () -> SpecReview): Job? {
        val c = content() ?: return null
        _state.value = c.copy(inFlight = ref, banner = null, blockers = null)
        return scope().launch {
            runCatching { block() }
                .onSuccess { applyReview(it); onSuccess() }
                .onFailure { t ->
                    // ...unchanged...
                }
        }
    }
```

(c) Clear the relevant draft only on a successful send (a failed send keeps the typed text — never silently dropped):

```kotlin
    fun answer(questionId: String, answer: String): Job? =
        write(ActionRef.Answer(questionId), onSuccess = { clearAnswerDraft(questionId) }) {
            repo.answer(conn, specId, questionId, answer)
        }

    fun ask(text: String): Job? =
        write(ActionRef.Ask, onSuccess = { _askDraft.value = "" }) { repo.ask(conn, specId, text) }
```

**Step 4 — Run to pass:** rerun Step-2 command. Expect green.

**Step 5 — Commit:**
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-answer-questions/ground-control add -A
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-answer-questions/ground-control commit -m "gc-answer-questions: preserve unsent answer/ask drafts keyed per question

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "draft-preservation flows + clear-on-success (ac9)" --task gc-answer-questions --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=4 -->
## Task 4 — Spec-detail lead banner (ac1, UI)

**Files:** `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/SpecDetailScreen.kt`

UI-only render; the enabling condition is covered by Task 1 + Task 2 tests (`d.unansweredLead`). Verify with a compile + full-suite run.

**Step 1 — Implement.** In `ContentView`, add the lead as the very first `item` of the `LazyColumn` (before the existing status/summary `item`):

```kotlin
        LazyColumn(Modifier.fillMaxSize()) {
            d.unansweredLead?.let { lead ->
                item { LeadBanner(lead, Modifier.padding(16.dp, 8.dp)) }
            }
            item {
                Column(Modifier.padding(16.dp, 8.dp)) {
                    // ...existing status banner + repos + ReadinessChipsRow + stepper...
                }
            }
            // ...rest unchanged...
```

Add the composable (near `SectionLabel`):

```kotlin
/** ac1: a single, prominent lead atop a review-phase spec that has unanswered open questions,
 *  pointing the operator at the inline answer fields as the path to approval. Rendered only when
 *  [SpecDetail.unansweredLead] is non-null, so a spec with no open questions is unchanged (ac5). */
@Composable
private fun LeadBanner(text: String, modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        color = MaterialTheme.colorScheme.primaryContainer,
        contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
        shape = MaterialTheme.shapes.small,
    ) {
        Text(
            text,
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(12.dp),
        )
    }
}
```

(`Surface`, `Text`, `MaterialTheme`, `FontWeight`, `Modifier`, `fillMaxWidth`, `padding`, `dp` are already imported.)

**Step 2 — Verify (compile + no regression):**
```
source ~/toolchains/android-env.sh
./gradlew --offline testDebugUnitTest
```
Expect: compiles + full suite green.

**Step 3 — Commit:**
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-answer-questions/ground-control add -A
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-answer-questions/ground-control commit -m "gc-answer-questions: spec-detail unanswered-questions lead banner (ac1)

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "spec-detail lead banner (ac1)" --task gc-answer-questions --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=5 -->
## Task 5 — Approve-control guidance line (ac2, UI)

**Files:** `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/SpecDetailScreen.kt`

UI-only; the sole-blocker string is covered by Task 1 + Task 2 (`d.approveGuidance`). The Approve button stays enabled with its real gate (it is not a "generic disabled state") — we add a guidance caption directly at the control.

**Step 1 — Implement.** Replace the `Surface { Row { … } }` body of `ActionBar` with a `Column` that shows the guidance above the button row (the rest of `ActionBar` — the dialog wiring below the `Surface` — is unchanged in this task; the Request-changes swap happens in Task 8):

```kotlin
    Surface(tonalElevation = 3.dp) {
        Column(Modifier.fillMaxWidth().padding(12.dp)) {
            // ac2: unanswered questions are the ONLY blocker → guide toward answering rather than a
            // generic disabled/blocked Approve. Uses the tested SpecDetail.approveGuidance.
            s.detail.approveGuidance?.let { guidance ->
                Text(
                    guidance,
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(bottom = 8.dp),
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (SpecAction.REQUEST_CHANGES in actions)
                    OutlinedButton(enabled = !busy, onClick = { showReason = true }) { Text("Request changes") }
                if (SpecAction.APPROVE in actions) {
                    Button(enabled = !busy, onClick = { showApproveConfirm = true }) { Text("Approve") }
                    Box {
                        IconButton(enabled = !busy, onClick = { menu = true }) {
                            Icon(Icons.Filled.MoreVert, contentDescription = "More approve actions")
                        }
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            DropdownMenuItem(
                                text = { Text("Approve anyway") },
                                onClick = { menu = false; vm.approve(bypass = true) },
                            )
                        }
                    }
                }
                if (SpecAction.DISPATCH in actions)
                    FilledTonalButton(enabled = !busy, onClick = { showDispatch = true }) { Text("Plan implementation") }
            }
        }
    }
```

(`Column` is already imported.) Leave the `if (showReason) ReasonDialog(...)`, `if (showApproveConfirm) ConfirmDialog(...)`, `if (showDispatch) ConfirmDialog(...)` blocks that follow the `Surface` exactly as they are.

**Step 2 — Verify:**
```
source ~/toolchains/android-env.sh
./gradlew --offline testDebugUnitTest
```
Expect: compiles + green.

**Step 3 — Commit:**
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-answer-questions/ground-control add -A
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-answer-questions/ground-control commit -m "gc-answer-questions: approve control guides 'Answer N to approve' when questions are the sole blocker (ac2)

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "approve-control guidance line (ac2)" --task gc-answer-questions --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=6 -->
## Task 6 — QuestionRow: multi-line answer bound to the VM draft (ac3, ac7, ac8)

**Files:** `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/SpecDetailScreen.kt`

UI-only; the draft state + disable-on-blank behavior are covered by Task 3 (`answerDrafts`) and `MultilineComposeInput`'s own `sendEnabled = value.isNotBlank()`.

**Step 1 — Implement.**

(a) Add imports:
```kotlin
import androidx.compose.runtime.collectAsState
import com.atomikpanda.groundcontrol.ui.components.MultilineComposeInput
```
(`collectAsStateWithLifecycle` and `getValue` are already imported; use `collectAsStateWithLifecycle` for consistency with the screen.)

(b) In `ContentView`, collect the answer drafts once at the top of the function:
```kotlin
private fun ContentView(s: SpecDetailUiState.Content, vm: SpecDetailViewModel) {
    val d = s.detail
    val interactive = isReviewInteractive(d.status)
    val answerDrafts by vm.answerDrafts.collectAsStateWithLifecycle()
    // ...existing pull-to-refresh setup...
```

(c) Change the questions `items(...)` call to thread the per-question draft:
```kotlin
            items(d.questions, key = { it.id }) { question ->
                QuestionRow(
                    q = question,
                    interactive = interactive,
                    inFlight = s.inFlight,
                    draft = answerDrafts[question.id] ?: (question.answer ?: ""),
                    onDraftChange = { vm.setAnswerDraft(question.id, it) },
                    onSend = { vm.answer(question.id, it) },
                )
            }
```

(d) Replace the `QuestionRow` composable with the multi-line, draft-driven version (ac3 primary submit, ac7 auto-expanding, ac8 disabled-when-blank):
```kotlin
@Composable
private fun QuestionRow(
    q: ReviewQuestion,
    interactive: Boolean,
    inFlight: ActionRef?,
    draft: String,
    onDraftChange: (String) -> Unit,
    onSend: (String) -> Unit,
) {
    val busy = inFlight is ActionRef.Answer && inFlight.questionId == q.id
    Column(Modifier.fillMaxWidth().padding(16.dp, 4.dp)) {
        Text(q.text, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
        if (interactive) {
            // ac7: reusable auto-expanding multi-line compose box (#282) — a long answer wraps + grows.
            // ac8: its Send is a prominent FilledIconButton, disabled while blank (no silent no-op tap).
            // ac3: this inline answer is the PRIMARY action; Request-changes is a secondary sheet.
            // The VM owns the draft (ac9) and clears it on a successful send — we don't clear here, so a
            // failed send keeps the typed text.
            MultilineComposeInput(
                value = draft,
                onValueChange = onDraftChange,
                onSend = { if (draft.isNotBlank()) onSend(draft) },
                placeholder = if (q.answer == null) "answer" else "edit answer",
                enabled = !busy,
                inFlight = busy,
                sendDescription = "Send answer",
            )
        } else {
            Text("answer: ${q.answer ?: "—"}", style = MaterialTheme.typography.bodySmall)
        }
    }
}
```

**Step 2 — Verify:**
```
source ~/toolchains/android-env.sh
./gradlew --offline testDebugUnitTest
```
Expect: compiles + green.

**Step 3 — Commit:**
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-answer-questions/ground-control add -A
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-answer-questions/ground-control commit -m "gc-answer-questions: QuestionRow uses multi-line compose box bound to VM draft (ac3/ac7/ac8/ac9)

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "QuestionRow multi-line answer field + draft binding (ac3/ac7/ac8)" --task gc-answer-questions --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=7 -->
## Task 7 — AskQuestionRow: multi-line ask bound to the ask draft (ac7, ac8)

**Files:** `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/SpecDetailScreen.kt`

**Step 1 — Implement.**

(a) In `ContentView`, collect the ask draft (beside the `answerDrafts` line from Task 6) and thread it into the ask row:
```kotlin
    val askDraft by vm.askDraft.collectAsStateWithLifecycle()
```
```kotlin
            if (interactive) item {
                AskQuestionRow(
                    draft = askDraft,
                    onDraftChange = { vm.setAskDraft(it) },
                    onSend = { vm.ask(it) },
                )
            }
```

(b) Add import `import androidx.compose.material.icons.automirrored.filled.HelpOutline` and replace `AskQuestionRow`:
```kotlin
@Composable
private fun AskQuestionRow(
    draft: String,
    onDraftChange: (String) -> Unit,
    onSend: (String) -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(16.dp, 8.dp)) {
        Text("A new question blocks gated approve until answered.", style = MaterialTheme.typography.bodySmall)
        // ac7 multi-line + ac8 disabled-when-blank via the shared compose box. The VM owns the ask draft
        // (ac9) and clears it on a successful ask.
        MultilineComposeInput(
            value = draft,
            onValueChange = onDraftChange,
            onSend = { if (draft.isNotBlank()) onSend(draft) },
            placeholder = "Ask a question",
            sendIcon = Icons.AutoMirrored.Filled.HelpOutline,
            sendDescription = "Ask a question",
        )
    }
}
```

**Step 2 — Verify:**
```
source ~/toolchains/android-env.sh
./gradlew --offline testDebugUnitTest
```
Expect: compiles + green.

**Step 3 — Commit:**
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-answer-questions/ground-control add -A
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-answer-questions/ground-control commit -m "gc-answer-questions: AskQuestionRow uses multi-line compose box bound to ask draft (ac7/ac8/ac9)

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "AskQuestionRow multi-line + ask-draft binding (ac7/ac8)" --task gc-answer-questions --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=8 -->
## Task 8 — Request-changes as the standard bottom sheet (ac6)

**Files:** `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/SpecDetailScreen.kt`

Reuse the exact `ModalBottomSheet` idiom already used by `QueueScreen.RejectSheet` / `DecisionCard.CommentSheet` — do not fork a new component.

**Step 1 — Implement.**

(a) Add imports:
```kotlin
import androidx.compose.foundation.layout.imePadding
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.launch
```

(b) In `ActionBar`, swap the dialog trigger for the sheet — replace:
```kotlin
    if (showReason) ReasonDialog(onDismiss = { showReason = false }) { showReason = false; vm.requestChanges(it) }
```
with:
```kotlin
    if (showReason) RequestChangesSheet(
        onDismiss = { showReason = false },
        onSend = { vm.requestChanges(it) },
    )
```

(c) Delete the now-unused `ReasonDialog` composable, and add `RequestChangesSheet` (mirrors `RejectSheet`):
```kotlin
/** ac6: Request-changes opens the app's standard bottom sheet (the ModalBottomSheet idiom shared with
 *  QueueScreen.RejectSheet / DecisionCard.CommentSheet), reusing the #282 multi-line compose box —
 *  not a cramped AlertDialog. Clears the field before dispatch so the Send button disables (no
 *  double-submit), then hides + dismisses. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RequestChangesSheet(onDismiss: () -> Unit, onSend: (String) -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    var reason by remember { mutableStateOf("") }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 24.dp).imePadding(),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Request changes", style = MaterialTheme.typography.titleSmall)
            MultilineComposeInput(
                value = reason,
                onValueChange = { reason = it },
                onSend = {
                    val toSend = reason
                    reason = ""
                    onSend(toSend)
                    scope.launch { sheetState.hide() }.invokeOnCompletion {
                        if (!sheetState.isVisible) onDismiss()
                    }
                },
                placeholder = "Reason for changes…",
                sendDescription = "Send request-changes",
            )
        }
    }
}
```

(d) Cleanup: `OutlinedTextField` and `singleLine` are no longer referenced anywhere in this file (QuestionRow/AskQuestionRow moved to `MultilineComposeInput`; `ReasonDialog` deleted) — remove the now-unused `import androidx.compose.material3.OutlinedTextField` to keep the file warning-clean. (Kotlin treats a stray unused import as a warning, not an error, so this is cleanup, not a blocker.)

**Step 2 — Verify:**
```
source ~/toolchains/android-env.sh
./gradlew --offline testDebugUnitTest
```
Expect: compiles + green.

**Step 3 — Commit:**
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-answer-questions/ground-control add -A
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-answer-questions/ground-control commit -m "gc-answer-questions: Request-changes uses the standard bottom sheet, not a dialog (ac6)

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "Request-changes bottom sheet reusing MultilineComposeInput (ac6)" --task gc-answer-questions --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=9 -->
## Task 9 — Queue QuestionsCard lead banner (ac1, Queue surface)

**Files:** `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/queue/QueueScreen.kt`

The approach applies the same lead to the Queue's spec-review. `QuestionsCard.items` already contains only unanswered questions (`cardsFromSpec` filters), so the count is `card.items.size` and we reuse the shared `unansweredLeadText`.

**Step 1 — Implement.**

(a) Add import (QueueScreen already imports `evidenceLabels`/`isUnverified` from the same package, so this is consistent):
```kotlin
import com.atomikpanda.groundcontrol.ui.specdetail.unansweredLeadText
```

(b) In `CardFace`, prepend the lead to the `is QuestionsCard ->` branch:
```kotlin
                is QuestionsCard -> {
                    // ac1 (Queue): lead the operator toward answering as the path to approval.
                    Text(
                        unansweredLeadText(card.items.size),
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.primary,
                    )
                    Spacer(Modifier.height(4.dp))
                    card.items.forEach { item ->
                        QuestionAnswerRow(item, enabled) { answer -> vm.answerQuestion(card.connectionId, card.specId, item.id, answer) }
                    }
                }
```

(`Text`, `Spacer`, `height`, `FontWeight`, `MaterialTheme` are already imported.)

**Step 2 — Verify:**
```
source ~/toolchains/android-env.sh
./gradlew --offline testDebugUnitTest
```
Expect: compiles + green (existing `QueueCardTest`/`QueueViewModelTest` unaffected).

**Step 3 — Commit:**
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-answer-questions/ground-control add -A
git -C /home/bailey/development/repos/mship-workspace/.worktrees/gc-answer-questions/ground-control commit -m "gc-answer-questions: Queue QuestionsCard lead banner (ac1)

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "Queue QuestionsCard lead banner (ac1)" --task gc-answer-questions --action committed
```
<!-- /mship:task -->

---

## Self-Review

**AC → task map**

| AC | Covered by | Verification |
|---|---|---|
| ac1 (prominent lead naming count) | Task 1 (`unansweredQuestionsLead`/`unansweredLeadText`), Task 2 (`SpecDetail.unansweredLead`), Task 4 (spec-detail banner), Task 9 (Queue banner) | `ReadinessTest`, `SpecDetailViewModelTest.lead_and_guidance_surface_…`, compile |
| ac2 (approve control says "answer N to approve", not generic disabled) | Task 1 (`soleBlockerApproveLabel`), Task 2 (`SpecDetail.approveGuidance`), Task 5 (guidance line, Approve stays enabled with gate) | `ReadinessTest.sole_blocker_label_…`, `SpecDetailViewModelTest`, compile |
| ac3 (inline answer PRIMARY, Request-changes secondary) | Task 6 (`MultilineComposeInput` FilledIconButton primary submit), Task 8 (Request-changes is a secondary `OutlinedButton` → sheet) | compile |
| ac4 (answering last question auto-approves inline, no Request-changes) | Task 2 test `answering_last_question_auto_approves_and_clears_lead_and_guidance` (server auto-approve reflected via existing `applyReview`) | `SpecDetailViewModelTest` |
| ac5 (no open questions → unchanged, no lead) | Task 1 (`null` at zero), Task 2 test `no_lead_or_guidance_when_no_open_questions`, Task 4 (`?.let` guards the banner) | `ReadinessTest`, `SpecDetailViewModelTest` |
| ac6 (Request-changes = standard bottom sheet, same component) | Task 8 `RequestChangesSheet` = the `ModalBottomSheet` + `MultilineComposeInput` idiom shared with `QueueScreen.RejectSheet`/`DecisionCard.CommentSheet` | compile |
| ac7 (answer + ask fields use the #282 auto-expanding multi-line box) | Task 6 (QuestionRow), Task 7 (AskQuestionRow) → `MultilineComposeInput` | compile |
| ac8 (submit disabled while blank, unmissable primary submit) | Task 6 + Task 7 — `MultilineComposeInput` default `sendEnabled = value.isNotBlank()` disables the `FilledIconButton` | compile (+ behavior is a property of the already-shipped, tested `MultilineComposeInput`) |
| ac9 (unsent draft preserved across leave+return, keyed per question) | Task 3 (`answerDrafts` map + `askDraft` flows, independent of `load()`; clear-on-success) | `SpecDetailViewModelTest.unsent_answer_and_ask_drafts_survive_…`, `sending_an_answer_clears_only_that_questions_draft`, `sending_a_question_clears_the_ask_draft` |

**Placeholder scan:** No `TODO`, `...`, "left as an exercise", or stub bodies. Every test and every implementation block is complete Kotlin. Each UI-only task (4, 5, 6, 7, 8, 9) explicitly states its enabling logic is covered by a Task 1–3 unit test and is verified by a compile + full-suite `testDebugUnitTest` run, per the plan's UI-only allowance.

**Type consistency:**
- `Summary(criteriaTotal, approved, flagged, unreviewed, unansweredQuestions)` — all Ints; test literals match field order (verified against `data/SpecActions.kt`).
- New pure fns return `String` / `String?`; computed vals `SpecDetail.unansweredLead`/`.approveGuidance` are `String?` and null-guarded at every call site (`?.let`).
- `answerDrafts: StateFlow<Map<String, String>>`, `askDraft: StateFlow<String>` — collected in Compose via `collectAsStateWithLifecycle()`; test reads `.value["q1"]` / `.value`.
- `MultilineComposeInput` call sites use its real signature (`value`, `onValueChange`, `onSend: () -> Unit`, `placeholder`, `enabled`, `inFlight`, `sendIcon`, `sendDescription`; `sendEnabled` left to its `value.isNotBlank()` default) — verified against `ui/components/MultilineComposeInput.kt`.
- `write(ref, onSuccess = {}, block)` keeps the trailing-lambda `block` last, so existing `setVerdict`/`approve`/`requestChanges` callers compile unchanged.
- Sheet reuse matches the verified `RejectSheet` signature/behavior (`rememberModalBottomSheetState(skipPartiallyExpanded = true)`, `imePadding()`, hide-then-dismiss).
