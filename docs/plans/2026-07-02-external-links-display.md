# External Links Display (v1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** Linear **MOS-201** (v1 scope: read-only link display; add/remove folded into MOS-210), the last core slice of the *Work Items — phase-aware cockpit* program.

**Goal:** Surface a WorkItem's `external_links` (github/linear/notion/jira/url upstream associations) as tap-through chips across its cockpits (Console / Review / Done).

**Architecture:** **ground-control only** — the server already emits `external_links` on `GET /items` / `GET /items/{id}`; GC drops them today via `ignoreUnknownKeys`. So it's two edits: widen the `WorkItemSummary` DTO to read them, and a shared `ExternalLinksRow` composable rendered in the three cockpit headers (each already takes `WorkItemSummary`, so one DTO change lights up all phases). No mship changes, no new endpoints.

**Tech Stack:** Kotlin, Compose (Material3), Ktor, kotlinx.serialization. JUnit4 + `MockEngine` (NOT `kotlin.test`). `source ~/toolchains/android-env.sh` before gradle. Focused: `./android/gradlew -p android :app:testDebugUnitTest --tests "com.atomikpanda.groundcontrol.<Class>"`; evidence: `mship test`. Package `com.atomikpanda.groundcontrol`.

---

## File Structure

- **Modify** `data/dto/WorkItemDtos.kt` — add an `ExternalLink` DTO + `externalLinks` field on `WorkItemSummary`.
- **Create** a shared `ExternalLinksRow` composable (a sensible shared UI location — reuse an existing shared package if one exists, else `ui/components/ExternalLinksRow.kt`).
- **Modify** `ui/console/ConsoleScreen.kt`, `ui/review/ReviewScreen.kt`, `ui/done/DoneScreen.kt` — render `ExternalLinksRow(item.externalLinks)` in each header.
- Test: extend/add a `WorkItem` DTO test asserting `external_links` deserializes.

---

<!-- mship:task id=1 -->
### Task 1: DTO — read external_links

**Files:** Modify `data/dto/WorkItemDtos.kt`; Test `WorkItemApiTest.kt` (extend) or `WorkItemDtoTest.kt` (new)

- [ ] **Step 1: Read** `data/dto/WorkItemDtos.kt` (current `WorkItemSummary`) and `WorkItemApiTest.kt` (the `getItem` MockEngine test) to mirror its harness.

- [ ] **Step 2: Failing test** — add a test that a `WorkItemSummary` payload carrying `external_links` deserializes. Mirror `WorkItemApiTest`'s `getItem` MockEngine setup but include links in the JSON:
```kotlin
@Test fun get_item_parses_external_links() = runTest {
    val api = SpecApi(HttpClient(MockEngine {
        respond(
            """{"id":"wi-1","kind":"feature","title":"T","phase":"done",
                "external_links":[{"provider":"github","url":"https://github.com/o/r/issues/1","title":"issue 1"},
                                  {"provider":"linear","url":"https://linear.app/x/MOS-1","title":""}]}""",
            HttpStatusCode.OK, jsonHdr,
        )
    }) { mshipDefaults() })
    val wi = api.getItem(conn, "wi-1")
    assertEquals(2, wi.externalLinks.size)
    assertEquals("github", wi.externalLinks[0].provider)
    assertEquals("https://github.com/o/r/issues/1", wi.externalLinks[0].url)
    assertEquals("issue 1", wi.externalLinks[0].title)
    assertEquals("", wi.externalLinks[1].title)
}
```
*(Match the exact `SpecApi`/`MockEngine`/`jsonHdr`/`mshipDefaults`/`conn` helpers already used in `WorkItemApiTest.kt`.)*

- [ ] **Step 3: Run — expect FAIL** — unresolved `externalLinks`.

- [ ] **Step 4: Implement** — in `data/dto/WorkItemDtos.kt`:
```kotlin
@Serializable
data class ExternalLink(
    val provider: String = "url",   // github | linear | notion | jira | url (server enum; kept as String)
    val url: String,
    val title: String = "",
)
```
and add to `WorkItemSummary` (after `updatedAt`):
```kotlin
@SerialName("external_links") val externalLinks: List<ExternalLink> = emptyList(),
```
The `emptyList()` default keeps it backward-compatible; `provider`/`title` defaults keep a partial entry from breaking the whole parse.

- [ ] **Step 5: Run — expect PASS**; **Step 6:** `mship test` green.

- [ ] **Step 7: Commit** — `feat(links): read external_links on WorkItemSummary` + `mship journal`.
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: ExternalLinksRow + render in the three cockpit headers

UI — build-verified. A shared tap-through chip row, shown in Console/Review/Done headers.

**Files:** Create the `ExternalLinksRow` composable; Modify `ui/console/ConsoleScreen.kt`, `ui/review/ReviewScreen.kt`, `ui/done/DoneScreen.kt`

- [ ] **Step 1: Create the shared composable.** Put it in a shared UI package (check for an existing shared/components location; else create `ui/components/ExternalLinksRow.kt`, package `com.atomikpanda.groundcontrol.ui.components`). It renders nothing when empty, else a wrapping chip row that taps through to each URL (mirror the existing `AssistChip` usage in `HomeScreen`/`WorkspaceScreen` and the `LocalUriHandler.openUri` tap-through in `TaskDetailScreen`/`ReviewScreen`):
```kotlin
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ExternalLinksRow(links: List<ExternalLink>, modifier: Modifier = Modifier) {
    if (links.isEmpty()) return
    val uriHandler = LocalUriHandler.current
    FlowRow(modifier, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        links.forEach { link ->
            AssistChip(
                onClick = { uriHandler.openUri(link.url) },
                label = { Text("${link.title.ifBlank { link.provider }} ↗") },
            )
        }
    }
}
```
(`FlowRow` is `androidx.compose.foundation.layout.FlowRow` under `@OptIn(ExperimentalLayoutApi::class)`; if the module lacks it, use a plain `Row` — the link count is small. Import `com.atomikpanda.groundcontrol.data.dto.ExternalLink`.)

- [ ] **Step 2: Render it in each header.** In each cockpit's `HeaderSection` (all three already have `item: WorkItemSummary` in scope — `ConsoleScreen.kt` ~line 142, `ReviewScreen.kt` ~line 120, `DoneScreen.kt` ~line 98), add `ExternalLinksRow(item.externalLinks, Modifier.padding(top = 4.dp))` after the existing title/kind lines. Add the import in each file. (Read each header first to place it inside the header `Column` and match padding.)

- [ ] **Step 3: Build** — `./android/gradlew -p android :app:assembleDebug` → BUILD SUCCESSFUL.

- [ ] **Step 4:** `mship test` green.

- [ ] **Step 5: Visual (deferred)** — `mship capture`: open an item that has external links → confirm the chips render + tap through. Deferred to operator (no emulator; needs an item with links, e.g. via `mship item link-url`).

- [ ] **Step 6: Commit** — `feat(links): shared ExternalLinksRow in console/review/done headers` + `mship journal`.
<!-- /mship:task -->

---

## Self-review checklist

- **Spec coverage (v1):** DTO reads `external_links` (T1), a shared chip row renders links across all three cockpits (T2). Add/remove correctly ABSENT (MOS-210).
- **No mship changes** — read-only; server already emits `external_links`.
- **Conventions** — JUnit4; `AssistChip` + `LocalUriHandler` mirror existing link patterns; one shared composable, not triplicated logic.

## Notes / risks

- **All phases at once** — Console/Review/Done headers all take `WorkItemSummary`, so the single DTO widening + one composable covers every phase an item can be in.
- **`provider` kept as String** — the server's closed enum (github/linear/notion/jira/url) is read as a plain String to avoid a brittle client enum; the chip label falls back to the provider when `title` is blank.
- **Add/remove is MOS-210** — display only here; managing links (and whether a follow-up is another `external_links` entry vs. a typed relation) is co-designed with MOS-210's spin-a-follow-up.
