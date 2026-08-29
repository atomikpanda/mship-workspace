# Show AC Evidence in Ground Control — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `show-acceptance-criteria-evidence-in` (approved)

**Goal:** Render each acceptance criterion's evidence (kind/ref/note) and its verified-vs-unverified state in the Ground Control spec detail and the Queue criteria card, consuming the evidence the serve `build_review` payload already exposes.

**Architecture:** GC-only, read-only display. serve already emits per-criterion `evidence: [{kind, ref, note}]` and a summary `unverified` count (behind `GET /specs/{id}` and `GET /specs/{id}/review`). Add the fields to the DTOs, a small pure helper that classifies a criterion as verified (with its labeled refs) vs unverified, and render it in `CriterionRow` (spec detail) + the Queue `CriteriaCard`. Fold in the deferred PR #50 nit (cap the Queue metadata line with maxLines + ellipsis).

**Tech Stack:** Kotlin, Jetpack Compose, Material3, kotlinx.serialization; JUnit4 unit tests (JVM, no emulator).

---

<!-- mship:task id=1 -->
### Task 1: DTO — evidence on ReviewCriterion + unverified on ReviewSummary

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/dto/SpecDetailDtos.kt`
- Test: `android/app/src/test/java/com/atomikpanda/groundcontrol/SpecEvidenceDtoTest.kt` (create)

- [ ] **Step 1: Write the failing test** — parse a review payload whose criterion carries evidence + a summary `unverified`, and one with none (defaults empty / 0).

```kotlin
// SpecEvidenceDtoTest.kt
val json = Json { ignoreUnknownKeys = true }
@Test fun criterion_parses_evidence_entries() {
    val c = json.decodeFromString<ReviewCriterion>(
        """{"id":"ac1","text":"t","verdict":"approved",
            "evidence":[{"kind":"test","ref":"pytest -q","note":"18 passed"},
                        {"kind":"commit","ref":"abc123","note":null}]}"""
    )
    assertEquals(2, c.evidence.size)
    assertEquals("test", c.evidence[0].kind)
    assertEquals("pytest -q", c.evidence[0].ref)
    assertEquals("18 passed", c.evidence[0].note)
    assertNull(c.evidence[1].note)
}
@Test fun criterion_without_evidence_defaults_empty() {
    val c = json.decodeFromString<ReviewCriterion>("""{"id":"ac1","text":"t","verdict":"unreviewed"}""")
    assertTrue(c.evidence.isEmpty())
}
@Test fun summary_parses_unverified() {
    val s = json.decodeFromString<ReviewSummary>("""{"criteria_total":3,"unverified":2}""")
    assertEquals(2, s.unverified)
}
```

- [ ] **Step 2: Run it, verify it fails** (Evidence type / fields missing).

- [ ] **Step 3: Add the DTO fields.**

```kotlin
@Serializable
data class Evidence(
    val kind: String,               // "test" | "commit" | "artifact"
    val ref: String,
    val note: String? = null,
)
// in ReviewCriterion: add
    val evidence: List<Evidence> = emptyList(),
// in ReviewSummary: add
    val unverified: Int = 0,
```

- [ ] **Step 4: Run tests, verify pass.**
- [ ] **Step 5: Commit + `mship journal`.**
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: Pure classifier helper (shared by both surfaces)

**Files:**
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/Evidence.kt`
- Test: `android/app/src/test/java/com/atomikpanda/groundcontrol/EvidenceDisplayTest.kt` (create)

- [ ] **Step 1: Failing test** — a criterion with evidence classifies as verified with labeled refs; empty → unverified.

```kotlin
@Test fun verified_lists_labeled_refs() {
    val labels = evidenceLabels(listOf(Evidence("test","pytest","18 passed"), Evidence("commit","abc123")))
    assertEquals(listOf("test: pytest — 18 passed", "commit: abc123"), labels)
}
@Test fun empty_is_unverified() {
    assertTrue(isUnverified(emptyList()))
    assertFalse(isUnverified(listOf(Evidence("artifact","build.apk"))))
}
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement.**

```kotlin
fun isUnverified(evidence: List<Evidence>): Boolean = evidence.isEmpty()
/** "kind: ref" or "kind: ref — note" per entry, for compact display. */
fun evidenceLabels(evidence: List<Evidence>): List<String> =
    evidence.map { e -> buildString { append(e.kind); append(": "); append(e.ref); e.note?.takeIf { it.isNotBlank() }?.let { append(" — "); append(it) } } }
```

- [ ] **Step 4: Run tests, pass.**
- [ ] **Step 5: Commit + journal.**
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: Render evidence in SpecDetail CriterionRow

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/SpecDetailScreen.kt` (`CriterionRow`)

- [ ] **Step 1:** Wrap the criterion text + evidence in a Column (keep the verdict toggle/glyph to the left). Under the text, render `evidenceLabels(c.evidence)` as muted `labelSmall` lines; when `isUnverified(c.evidence)`, render a single muted "unverified" line instead. Long refs: `maxLines = 2, overflow = Ellipsis` per line.

```kotlin
// replace the trailing `Text(c.text, ...)` with:
Column(Modifier.padding(start = 4.dp)) {
    Text(c.text)
    if (isUnverified(c.evidence)) {
        Text("unverified", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    } else {
        c.evidence.let { evidenceLabels(it) }.forEach { line ->
            Text(line, style = MaterialTheme.typography.labelSmall,
                 color = MaterialTheme.colorScheme.onSurfaceVariant,
                 maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}
```

- [ ] **Step 2:** `compileDebugKotlin` clean (import `TextOverflow`, the helpers).
- [ ] **Step 3: Commit + journal.**
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: Queue CriteriaCard shows per-criterion verified/unverified + refs

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/queue/QueueCard.kt` (`CriterionItem`, `cardsFromSpec`)
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/queue/QueueScreen.kt` (`CriteriaCard` rendering)
- Test: `android/app/src/test/java/com/atomikpanda/groundcontrol/QueueCardTest.kt`

- [ ] **Step 1: Failing test** — `cardsFromSpec` carries each criterion's evidence into `CriterionItem`.

```kotlin
@Test fun criteria_card_items_carry_evidence() {
    val spec = spec(criteria = listOf(
        ReviewCriterion("ac1","t","approved", evidence = listOf(Evidence("test","pytest"))),
        ReviewCriterion("ac2","u","unreviewed"),
    ))
    val items = cardsFromSpec(conn, spec).filterIsInstance<CriteriaCard>().single().items
    assertEquals(1, items.first { it.id == "ac1" }.evidence.size)
    assertTrue(items.first { it.id == "ac2" }.evidence.isEmpty())
}
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3:** Add `val evidence: List<Evidence> = emptyList()` to `CriterionItem`; populate it in `cardsFromSpec` (`CriterionItem(it.id, it.text, it.verdict, it.comment, it.evidence)`). In `QueueScreen` `CriteriaCard` rendering, under each item's text render `evidenceLabels(item.evidence)` (muted, maxLines=2, ellipsis) or a muted "unverified" when empty — reusing the Task 2 helpers.
- [ ] **Step 4: Run tests + `testDebugUnitTest` pass.**
- [ ] **Step 5: Commit + journal.**
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: Fold in deferred PR #50 nit — cap Queue metadata line

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/queue/QueueScreen.kt` (`QueueCardMeta`)

- [ ] **Step 1:** Add `maxLines = 2, overflow = TextOverflow.Ellipsis` to both the title `Text` and the `kind · repos` `Text` in `QueueCardMeta`; add the `TextOverflow` import. (This is the guard Greptile flagged on #50; the diff is saved at `scratchpad/gc-queuecard-maxlines-p2.patch`.)
- [ ] **Step 2:** `compileDebugKotlin` clean.
- [ ] **Step 3: Commit + journal.**
<!-- /mship:task -->

---

## Self-Review

- **Spec coverage:** AC1 → Task 1 (DTO evidence + unverified). AC2 → Tasks 2+3 (spec-detail evidence + unverified marker). AC3 → Task 4 (Queue verified/unverified + refs). AC4 → maxLines/ellipsis in Tasks 3 & 4 (long refs stay inside scroll). AC5 → Task 5 (metadata line cap). All five covered.
- **Type consistency:** `Evidence` (Task 1) is reused by `evidenceLabels`/`isUnverified` (Task 2), `CriterionItem.evidence` (Task 4). `ReviewCriterion.evidence` feeds both `CriterionRow` (Task 3) and `cardsFromSpec` (Task 4).
- **No placeholders:** every code step shows the code.
