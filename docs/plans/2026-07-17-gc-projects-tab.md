# Ground Control — Projects Tab + Per-Workspace Color/Glyph Identity — Implementation Plan

**Spec:** `gc-projects-tab` (issue #375, status: dispatched)
**REQUIRED SUB-SKILL:** Execute this plan with the **test-driven-development** skill (red → green → commit) for every task, and **executing-plans** for checkpoint discipline. Each task is a self-contained red/green/commit unit; do not batch.

**Goal:** Add a 5th "Projects" bottom-nav destination that lists every connected workspace with a consistent color+glyph identity badge, reuse the existing `WorkspaceScreen` as the per-workspace detail, let the operator override color/glyph (persisted, survives re-pair), and render the same reusable badge everywhere a workspace is referenced — with no `mship serve` change and no app-scoping of Home/Queue.

**Architecture / reuse (do NOT fork new versions):**
- Bottom nav is data-driven by the `Section` enum in `ui/nav/Section.kt` and a single loop in `GroundControlApp.kt`. Adding `Section.PROJECTS` auto-adds the tab; only a new `composable(Section.PROJECTS.route)` route is needed.
- Row taps reuse the **existing** `workspace/{connectionId}` route → `WorkspaceScreen`. No new detail screen.
- Persistence reuses `ConnectionsCodec` + `upsertConnection` (`data/WorkspaceConnection.kt`) and `ConnectionsRepository` DataStore. kotlinx `Json { ignoreUnknownKeys = true }` + field defaults give old-JSON backward compat for free.
- Identity color lives alongside `ui/theme/Color.kt`; there is a per-workspace hue helper `chipHue(...)` and a WCAG contrast test pattern (`ThemeContrastTest.kt`) to mirror.
- One reusable `WorkspaceBadge` composable + a `LocalWorkspaceIdentityResolver` CompositionLocal replaces the ad-hoc colored-name chips at `HomeScreen.kt:325`, `QueueScreen.kt` CardFace, and the three detail-screen `TopAppBar` titles.

**Tech stack:** Kotlin / Jetpack Compose (Material3, `material-icons-extended` is a dependency), JUnit4 + kotlinx-coroutines-test + Ktor MockEngine. Module `:app` under `android/`. `androidx.compose.ui.graphics.Color` is a pure value class and works in plain JVM unit tests.

### Recon verified in the worktree
- `ui/nav/Section.kt` — `enum Section(route,label,icon)` = HOME, QUEUE, TASKS, SETTINGS. `SectionTest.kt` asserts **exactly four** routes and queue at index 1 — this test **must be updated** when PROJECTS is added.
- `GroundControlApp.kt` — the `NavigationBar { Section.entries.forEach { … } }` loop; `startDestination = Section.HOME.route`; existing `workspace/{connectionId}` route.
- `data/WorkspaceConnection.kt` — `@Serializable data class WorkspaceConnection(id, baseUrl, token?, workspaceName="")`; `ConnectionsCodec`; `upsertConnection` (filters by id/baseUrl, appends).
- `data/ConnectionsRepository.kt` — `connections: Flow`, `snapshot()`, `save()`, `upsert()`, `remove()`.
- `ui/theme/Color.kt` — `Palette`, `SemanticColors`, `chipHue`. `Palette.darkBackground`/`Palette.lightBackground`.
- Badge sites: `HomeScreen.kt:325` (`NeedsYouRow` overlineContent uses `chipHue(item.connectionId, colors)`), `QueueScreen.kt` CardFace, and `TopAppBar` titles in `ConversationScreen.kt`, `SpecDetailScreen.kt`, `ConsoleScreen.kt`.
- Construction sites: `SettingsViewModel.kt`, `PairLink.kt` — nullable+defaulted new fields keep them compiling.
- Test harness: `ConnectionsCodecTest.kt`, `SectionTest.kt`, `ThemeContrastTest.kt` (WCAG helper), `HomeViewModelTest.kt`.

## File Structure

| Path (under `android/app/src/`) | New/Edit | Purpose | AC |
|---|---|---|---|
| `main/.../ui/theme/WorkspaceIdentity.kt` | New | palette, autoColor/autoGlyph/autoIdentity, resolveIdentity, hex codec, resolver local | ac2, ac3, ac4 |
| `test/.../WorkspaceIdentityTest.kt` | New | determinism, palette-bounded, glyph, hex round-trip, override precedence, default resolver | ac2, ac4 |
| `test/.../WorkspaceIdentityContrastTest.kt` | New | WCAG contrast of glyph-on-swatch | ac3 |
| `main/.../data/WorkspaceConnection.kt` | Edit | add colorOverride/glyphOverride; preserve-on-upsert; applyIdentityOverride | ac4, ac5 |
| `test/.../ConnectionsCodecTest.kt` | Edit | override round-trip, old-JSON decode, upsert-preserve, applyIdentityOverride | ac4, ac5 |
| `main/.../data/ConnectionsRepository.kt` | Edit | setIdentity(...) | ac4 |
| `main/.../ui/components/WorkspaceBadge.kt` | New | reusable badge composable | ac7 |
| `main/.../ui/nav/Section.kt` | Edit | add PROJECTS | ac1 |
| `test/.../SectionTest.kt` | Edit | assert 5 entries incl. projects | ac1 |
| `main/.../ui/projects/ProjectsScreen.kt` | New | list + row→route + edit dialog | ac1, ac4, ac6 |
| `main/.../ui/projects/ProjectsViewModel.kt` | New | thin VM: collect connections, setOverride; pure projectRows/workspaceRoute | ac1, ac4 |
| `test/.../ProjectsViewModelTest.kt` | New | projectRows one-per-conn, route map, offline guard | ac1, ac6, ac8 |
| `main/.../GroundControlApp.kt` | Edit | composable(PROJECTS.route), provide resolver, pass identity to headers | ac1, ac6, ac7 |
| `main/.../ui/home/HomeScreen.kt`, `ui/queue/QueueScreen.kt` | Edit | badge in NeedsYouRow / CardFace | ac7 |
| `ui/messages/ConversationScreen.kt`, `ui/specdetail/SpecDetailScreen.kt`, `ui/console/ConsoleScreen.kt` | Edit | badge in TopAppBar title | ac7 |
| `test/.../ProjectsRegressionTest.kt` | New | no app-scoping, no serve dep | ac8 |

**Command prelude (from the module dir for every Gradle step):**
```
cd /home/bailey/development/repos/mship-workspace/.worktrees/gc-projects-tab/ground-control/android
source ~/toolchains/android-env.sh
```
**Commit prelude (worktree root):** `WT=/home/bailey/development/repos/mship-workspace/.worktrees/gc-projects-tab/ground-control`

---

<!-- mship:task id=1 -->
## Task 1 — Curated palette + deterministic auto-identity + hex codec (ac2, ac3-curated)

**Files:** `main/.../ui/theme/WorkspaceIdentity.kt` (new), `test/.../WorkspaceIdentityTest.kt` (new)

**Step 1 — write the failing test** `app/src/test/java/com/atomikpanda/groundcontrol/WorkspaceIdentityTest.kt`:
```kotlin
package com.atomikpanda.groundcontrol

import androidx.compose.ui.graphics.Color
import com.atomikpanda.groundcontrol.ui.theme.WorkspacePalette
import com.atomikpanda.groundcontrol.ui.theme.autoColor
import com.atomikpanda.groundcontrol.ui.theme.autoGlyph
import com.atomikpanda.groundcontrol.ui.theme.autoIdentity
import com.atomikpanda.groundcontrol.ui.theme.colorFromHex
import com.atomikpanda.groundcontrol.ui.theme.toHex
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkspaceIdentityTest {
    private val names = listOf("acme", "Beta Corp", "gamma", "delta-ops", "Épsilon", "zeta", "eta labs")

    @Test fun auto_color_is_deterministic_and_stable() {
        for (n in names) assertEquals(autoColor(n), autoColor(n))
    }

    @Test fun auto_color_is_always_within_the_curated_palette() {
        for (n in names) assertTrue(WorkspacePalette.swatches.contains(autoColor(n)))
    }

    @Test fun palette_is_a_reasonably_large_curated_fixed_set() {
        assertTrue("palette too small to disambiguate", WorkspacePalette.swatches.size >= 10)
        assertEquals("swatches must be unique", WorkspacePalette.swatches.toSet().size, WorkspacePalette.swatches.size)
    }

    @Test fun auto_color_distributes_across_the_palette() {
        val big = (0 until 200).map { "workspace-$it" }
        assertTrue("hash collapses to one hue", big.map { autoColor(it) }.toSet().size >= 5)
    }

    @Test fun default_glyph_is_uppercased_first_letter() {
        assertEquals("A", autoGlyph("acme"))
        assertEquals("B", autoGlyph("Beta Corp"))
    }

    @Test fun glyph_falls_back_for_blank_names() {
        assertEquals("?", autoGlyph(""))
        assertEquals("?", autoGlyph("   "))
    }

    @Test fun auto_identity_bundles_color_and_glyph() {
        val id = autoIdentity("acme")
        assertEquals(autoColor("acme"), id.color)
        assertEquals("A", id.glyph)
    }

    @Test fun hex_codec_round_trips() {
        val c = Color(0xFF1976D2)
        assertEquals(c, colorFromHex(c.toHex()))
        assertEquals(Color(0xFFD32F2F), colorFromHex("#D32F2F"))   // 6-digit → opaque
        assertNotNull(colorFromHex("#FF00796B"))
        assertNull(colorFromHex("nope"))
        assertNull(colorFromHex("#12"))
    }
}
```

**Step 2 — run to fail:**
```
./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.WorkspaceIdentityTest"
```
Expect compile failure (unresolved `WorkspacePalette`, `autoColor`, …).

**Step 3 — implement** `app/src/main/java/com/atomikpanda/groundcontrol/ui/theme/WorkspaceIdentity.kt`:
```kotlin
package com.atomikpanda.groundcontrol.ui.theme

import androidx.compose.ui.graphics.Color
import kotlin.math.roundToInt

/** A workspace's resolved visual identity: a solid badge [color] + a one-glyph [glyph] label. */
data class WorkspaceIdentity(val color: Color, val glyph: String)

/**
 * Curated, theme-independent badge palette. Every swatch is a mid-dark saturated tone whose
 * relative luminance is <= 0.30 so the white [onColor] glyph clears WCAG 3:1 (enforced by
 * WorkspaceIdentityContrastTest), and each reads as a colored chip on BOTH the near-white light
 * surface and the near-black dark surface. APPEND new colors at the END — never reorder — because
 * the persisted-free auto color is `hash(name) % size`, so reordering would remap every workspace.
 */
object WorkspacePalette {
    val swatches: List<Color> = listOf(
        Color(0xFFD32F2F), // red 700
        Color(0xFFC2185B), // pink 700
        Color(0xFF7B1FA2), // purple 700
        Color(0xFF512DA8), // deep purple 700
        Color(0xFF303F9F), // indigo 700
        Color(0xFF1976D2), // blue 700
        Color(0xFF00838F), // cyan 800
        Color(0xFF00796B), // teal 700
        Color(0xFF388E3C), // green 700
        Color(0xFF558B2F), // light green 800
        Color(0xFFE65100), // orange 900
        Color(0xFF455A64), // blue grey 700
    )
    val onColor: Color = Color.White
}

/** Stable hue: same name → same swatch across app restarts (JVM String.hashCode is spec-stable). */
fun autoColor(name: String): Color {
    val key = name.trim()
    if (key.isEmpty()) return WorkspacePalette.swatches.first()
    val idx = (key.hashCode() and Int.MAX_VALUE) % WorkspacePalette.swatches.size
    return WorkspacePalette.swatches[idx]
}

/** Default glyph = first non-blank char, uppercased; blank name → "?". */
fun autoGlyph(name: String): String =
    name.trim().firstOrNull()?.uppercaseChar()?.toString() ?: "?"

fun autoIdentity(name: String): WorkspaceIdentity = WorkspaceIdentity(autoColor(name), autoGlyph(name))

/** Parse "#RRGGBB" or "#AARRGGBB" (with or without '#'). Returns null on malformed input. */
fun colorFromHex(hex: String): Color? {
    val h = hex.trim().removePrefix("#")
    return when (h.length) {
        6 -> h.toLongOrNull(16)?.let { Color(0xFF000000L or it) }
        8 -> h.toLongOrNull(16)?.let { Color(it) }
        else -> null
    }
}

/** Encode as "#AARRGGBB" for DataStore persistence. */
fun Color.toHex(): String {
    fun c(v: Float) = (v * 255f).roundToInt().coerceIn(0, 255)
    return "#%02X%02X%02X%02X".format(c(alpha), c(red), c(green), c(blue))
}
```

**Step 4 — run to pass:** rerun the Step-2 command; expect all green.

**Step 5 — commit:**
```
git -C $WT add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/theme/WorkspaceIdentity.kt \
             android/app/src/test/java/com/atomikpanda/groundcontrol/WorkspaceIdentityTest.kt
git -C $WT commit -m "gc-projects-tab: curated palette + deterministic workspace auto-identity (ac2/ac3)

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "Palette + autoColor/autoGlyph/hex codec, deterministic + palette-bounded (ac2/ac3)" --task gc-projects-tab --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=2 -->
## Task 2 — Palette legibility contrast guard (ac3-legibility)

**Files:** `test/.../WorkspaceIdentityContrastTest.kt` (new). Mirrors the WCAG helper in `ThemeContrastTest.kt`.

**Step 1 — write the failing test** `app/src/test/java/com/atomikpanda/groundcontrol/WorkspaceIdentityContrastTest.kt`:
```kotlin
package com.atomikpanda.groundcontrol

import androidx.compose.ui.graphics.Color
import com.atomikpanda.groundcontrol.ui.theme.Palette
import com.atomikpanda.groundcontrol.ui.theme.WorkspacePalette
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/** The badge is a solid swatch with a white glyph; its legibility does NOT depend on the theme
 *  surface, so the guarantee is white-glyph-on-swatch contrast. 3:1 is the WCAG AA bar for large/
 *  graphical text. We also assert each swatch stands off both theme backgrounds. */
class WorkspaceIdentityContrastTest {
    private fun channel(v: Float): Double {
        val x = v.toDouble()
        return if (x <= 0.04045) x / 12.92 else ((x + 0.055) / 1.055).pow(2.4)
    }
    private fun luminance(c: Color) =
        0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
    private fun contrast(a: Color, b: Color): Double {
        val la = luminance(a); val lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @Test fun white_glyph_is_legible_on_every_swatch() {
        for (c in WorkspacePalette.swatches) {
            val r = contrast(WorkspacePalette.onColor, c)
            assertTrue("white glyph on $c is $r, below 3:1", r >= 3.0)
        }
    }

    @Test fun swatches_stand_off_both_theme_backgrounds() {
        for (c in WorkspacePalette.swatches) {
            assertTrue("swatch $c blends into dark bg", contrast(c, Palette.darkBackground) >= 1.5)
            assertTrue("swatch $c blends into light bg", contrast(c, Palette.lightBackground) >= 1.5)
        }
    }
}
```

**Step 2 — run to fail:**
```
./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.WorkspaceIdentityContrastTest"
```
Expect: compiles (Task 1 landed the palette); should PASS immediately since the palette was curated to satisfy this. If any swatch fails, that swatch must be darkened in `WorkspacePalette` until green (treat a red here as a palette bug, not a test bug).

**Step 3 — implement:** none expected; the palette from Task 1 satisfies the guard. (If red: darken the offending swatch in `WorkspaceIdentity.kt`.)

**Step 4 — run to pass:** rerun Step 2; green.

**Step 5 — commit:**
```
git -C $WT add android/app/src/test/java/com/atomikpanda/groundcontrol/WorkspaceIdentityContrastTest.kt \
             android/app/src/main/java/com/atomikpanda/groundcontrol/ui/theme/WorkspaceIdentity.kt
git -C $WT commit -m "gc-projects-tab: WCAG contrast guard for badge palette legibility (ac3)

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "Contrast guard: white glyph >=3:1 on every swatch, swatches stand off both bgs (ac3)" --task gc-projects-tab --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=3 -->
## Task 3 — Override fields on WorkspaceConnection + codec backward-compat (ac4-persist)

**Files:** `main/.../data/WorkspaceConnection.kt` (edit), `test/.../ConnectionsCodecTest.kt` (edit).

**Step 1 — add failing tests** to `ConnectionsCodecTest.kt` (append inside the class):
```kotlin
    @Test fun round_trips_color_and_glyph_overrides() {
        val list = listOf(
            WorkspaceConnection("1", "http://h:47100", "tok", "ws-a",
                colorOverride = "#FF1976D2", glyphOverride = "Z"),
        )
        val restored = ConnectionsCodec.decode(ConnectionsCodec.encode(list))
        assertEquals(list, restored)
        assertEquals("#FF1976D2", restored[0].colorOverride)
        assertEquals("Z", restored[0].glyphOverride)
    }

    @Test fun decodes_legacy_json_without_override_fields() {
        val legacy = """[{"id":"1","baseUrl":"http://h:47100","token":"tok","workspaceName":"ws-a"}]"""
        val restored = ConnectionsCodec.decode(legacy)
        assertEquals(1, restored.size)
        assertNull(restored[0].colorOverride)
        assertNull(restored[0].glyphOverride)
    }
```
(Add `import org.junit.Assert.assertNull` if not present.)

**Step 2 — run to fail:**
```
./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.ConnectionsCodecTest"
```
Expect compile failure (no `colorOverride`/`glyphOverride` params).

**Step 3 — implement** — edit `data/WorkspaceConnection.kt` data class:
```kotlin
@Serializable
data class WorkspaceConnection(
    val id: String,
    val baseUrl: String,
    val token: String? = null,
    val workspaceName: String = "",
    /** Operator override for the identity badge color, "#AARRGGBB"; null = auto-derived. */
    val colorOverride: String? = null,
    /** Operator override for the identity badge glyph; null = auto (name's first letter). */
    val glyphOverride: String? = null,
)
```
`ConnectionsCodec` is unchanged (`ignoreUnknownKeys = true` + the new defaults cover both directions).

**Step 4 — run to pass:** rerun Step 2; green.

**Step 5 — commit:**
```
git -C $WT add android/app/src/main/java/com/atomikpanda/groundcontrol/data/WorkspaceConnection.kt \
             android/app/src/test/java/com/atomikpanda/groundcontrol/ConnectionsCodecTest.kt
git -C $WT commit -m "gc-projects-tab: colorOverride/glyphOverride on WorkspaceConnection, legacy-safe decode (ac4)

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "Override fields + codec round-trip + legacy JSON decode (ac4)" --task gc-projects-tab --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=4 -->
## Task 4 — Preserve override across re-pair (upsert) + applyIdentityOverride (ac5, ac4-set)

**Files:** `main/.../data/WorkspaceConnection.kt` (edit `upsertConnection`, add `applyIdentityOverride`), `test/.../ConnectionsCodecTest.kt` (edit).

**Step 1 — add failing tests** to `ConnectionsCodecTest.kt`:
```kotlin
    @Test fun upsert_preserves_prior_override_when_incoming_omits_it() {
        val existing = listOf(
            WorkspaceConnection("id-1", "http://host:47100", "old", "ws",
                colorOverride = "#FF7B1FA2", glyphOverride = "Q"))
        val incoming = WorkspaceConnection("id-1", "http://host:47100", "new", "ws")
        val result = upsertConnection(existing, incoming)
        assertEquals(1, result.size)
        assertEquals("new", result[0].token)
        assertEquals("#FF7B1FA2", result[0].colorOverride)   // preserved
        assertEquals("Q", result[0].glyphOverride)           // preserved
    }

    @Test fun upsert_preserves_override_when_matched_by_baseUrl_after_id_change() {
        val existing = listOf(
            WorkspaceConnection("old-id", "http://host:47100", "old", "ws",
                colorOverride = "#FF00796B", glyphOverride = null))
        val incoming = WorkspaceConnection("new-id", "http://host:47100", "new", "ws")
        val result = upsertConnection(existing, incoming)
        assertEquals(1, result.size)
        assertEquals("new-id", result[0].id)
        assertEquals("#FF00796B", result[0].colorOverride)   // carried onto the replacement
    }

    @Test fun upsert_lets_an_explicit_incoming_override_win() {
        val existing = listOf(
            WorkspaceConnection("id-1", "http://host:47100", "t", "ws", colorOverride = "#FFAAAAAA"))
        val incoming = existing[0].copy(colorOverride = "#FF111111")
        assertEquals("#FF111111", upsertConnection(existing, incoming)[0].colorOverride)
    }

    @Test fun apply_identity_override_replaces_only_the_target_and_can_clear() {
        val list = listOf(
            WorkspaceConnection("a", "http://a", null, "ws-a", colorOverride = "#FF1976D2"),
            WorkspaceConnection("b", "http://b", null, "ws-b"))
        val set = applyIdentityOverride(list, "b", "#FFD32F2F", "B")
        assertEquals("#FFD32F2F", set.first { it.id == "b" }.colorOverride)
        assertEquals("#FF1976D2", set.first { it.id == "a" }.colorOverride)   // untouched
        val cleared = applyIdentityOverride(set, "a", null, null)             // reset to auto
        assertNull(cleared.first { it.id == "a" }.colorOverride)
    }
```
Add `import com.atomikpanda.groundcontrol.data.applyIdentityOverride` at the top.

**Step 2 — run to fail:**
```
./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.ConnectionsCodecTest"
```
Expect: `preserves_prior_override…` red and `applyIdentityOverride` unresolved.

**Step 3 — implement** — edit `data/WorkspaceConnection.kt`, replace `upsertConnection` and add `applyIdentityOverride`:
```kotlin
/**
 * Pure upsert: replace any existing entry matching [conn] by [id] or [baseUrl], else append.
 * Re-pairing carries forward a prior entry's colorOverride/glyphOverride when [conn] omits them,
 * so re-pairing a workspace never silently resets a customized identity (ac5). An explicit
 * override on [conn] still wins.
 */
fun upsertConnection(
    existing: List<WorkspaceConnection>,
    conn: WorkspaceConnection,
): List<WorkspaceConnection> {
    val prior = existing.firstOrNull { it.id == conn.id || it.baseUrl == conn.baseUrl }
    val merged = conn.copy(
        colorOverride = conn.colorOverride ?: prior?.colorOverride,
        glyphOverride = conn.glyphOverride ?: prior?.glyphOverride,
    )
    return existing.filterNot { it.id == conn.id || it.baseUrl == conn.baseUrl } + merged
}

/** Pure override editor: replace the identity override on the entry with [id] (null clears it,
 *  resetting that field to the auto-derived value). Used by the Projects tab edit affordance. */
fun applyIdentityOverride(
    list: List<WorkspaceConnection>,
    id: String,
    colorOverride: String?,
    glyphOverride: String?,
): List<WorkspaceConnection> =
    list.map { if (it.id == id) it.copy(colorOverride = colorOverride, glyphOverride = glyphOverride) else it }
```

**Step 4 — run to pass:** rerun Step 2; green (existing upsert tests still pass — same filter semantics).

**Step 5 — commit:**
```
git -C $WT add android/app/src/main/java/com/atomikpanda/groundcontrol/data/WorkspaceConnection.kt \
             android/app/src/test/java/com/atomikpanda/groundcontrol/ConnectionsCodecTest.kt
git -C $WT commit -m "gc-projects-tab: preserve override on re-pair + applyIdentityOverride editor (ac5/ac4)

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "upsert preserves override on re-pair; applyIdentityOverride set/clear (ac5/ac4)" --task gc-projects-tab --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=5 -->
## Task 5 — resolveIdentity(conn) override precedence + repo setIdentity (ac4-precedence)

**Files:** `main/.../ui/theme/WorkspaceIdentity.kt` (extend), `main/.../data/ConnectionsRepository.kt` (edit), `test/.../WorkspaceIdentityTest.kt` (extend).

**Step 1 — add failing tests** to `WorkspaceIdentityTest.kt`:
```kotlin
    @Test fun resolve_uses_overrides_when_present() {
        val conn = WorkspaceConnection("1", "http://h", null, "acme",
            colorOverride = "#FFD32F2F", glyphOverride = "★")
        val id = resolveIdentity(conn)
        assertEquals(Color(0xFFD32F2F), id.color)
        assertEquals("★", id.glyph)
    }

    @Test fun resolve_falls_back_to_auto_when_overrides_null() {
        val conn = WorkspaceConnection("1", "http://h", null, "acme")
        val id = resolveIdentity(conn)
        assertEquals(autoColor("acme"), id.color)
        assertEquals("A", id.glyph)
    }

    @Test fun resolve_uses_baseUrl_when_name_blank_and_ignores_unparseable_color() {
        val conn = WorkspaceConnection("1", "http://host:47100", null, "", colorOverride = "bad-hex")
        val id = resolveIdentity(conn)
        assertEquals(autoColor("http://host:47100"), id.color) // bad override → auto by displayName
    }
```
Add imports: `com.atomikpanda.groundcontrol.data.WorkspaceConnection`, `com.atomikpanda.groundcontrol.ui.theme.resolveIdentity`.

**Step 2 — run to fail:**
```
./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.WorkspaceIdentityTest"
```
Expect unresolved `resolveIdentity`.

**Step 3 — implement:**

(a) Append to `ui/theme/WorkspaceIdentity.kt`:
```kotlin
import com.atomikpanda.groundcontrol.data.WorkspaceConnection

/** Resolve a connection's identity: override-or-auto per field. A blank name falls back to the
 *  baseUrl (matching displayName conventions); an unparseable colorOverride falls back to auto. */
fun resolveIdentity(conn: WorkspaceConnection): WorkspaceIdentity {
    val name = conn.workspaceName.ifBlank { conn.baseUrl }
    val color = conn.colorOverride?.let(::colorFromHex) ?: autoColor(name)
    val glyph = conn.glyphOverride?.trim()?.takeIf { it.isNotEmpty() } ?: autoGlyph(name)
    return WorkspaceIdentity(color, glyph)
}
```

(b) Add to `data/ConnectionsRepository.kt` (after `remove`):
```kotlin
    suspend fun setIdentity(id: String, colorOverride: String?, glyphOverride: String?) =
        save(applyIdentityOverride(snapshot(), id, colorOverride, glyphOverride))
```

**Step 4 — run to pass:** rerun Step 2; green.

**Step 5 — commit:**
```
git -C $WT add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/theme/WorkspaceIdentity.kt \
             android/app/src/main/java/com/atomikpanda/groundcontrol/data/ConnectionsRepository.kt \
             android/app/src/test/java/com/atomikpanda/groundcontrol/WorkspaceIdentityTest.kt
git -C $WT commit -m "gc-projects-tab: resolveIdentity override precedence + repo.setIdentity (ac4)

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "resolveIdentity override-or-auto + ConnectionsRepository.setIdentity (ac4)" --task gc-projects-tab --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=6 -->
## Task 6 — Reusable WorkspaceBadge + LocalWorkspaceIdentityResolver (ac7-component)

**Files:** `main/.../ui/components/WorkspaceBadge.kt` (new), `main/.../ui/theme/WorkspaceIdentity.kt` (extend: resolver local + default), `test/.../WorkspaceIdentityTest.kt` (extend with the pure default-resolver test).

**Step 1 — add a failing test** to `WorkspaceIdentityTest.kt`:
```kotlin
    @Test fun default_identity_resolver_is_auto_by_name() {
        assertEquals(autoIdentity("acme"), defaultIdentityResolver("any-id", "acme"))
    }
```
Add import `com.atomikpanda.groundcontrol.ui.theme.defaultIdentityResolver`.

**Step 2 — run to fail:**
```
./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.WorkspaceIdentityTest"
```
Expect unresolved `defaultIdentityResolver`.

**Step 3 — implement:**

(a) Append to `ui/theme/WorkspaceIdentity.kt`:
```kotlin
import androidx.compose.runtime.staticCompositionLocalOf

/** Default (id, name) → identity resolver: auto-by-name. Overridden app-wide by a connections-aware
 *  resolver in GroundControlApp so overrides show at every badge site. */
fun defaultIdentityResolver(connectionId: String, name: String): WorkspaceIdentity = autoIdentity(name)

/** Read at any badge site: `LocalWorkspaceIdentityResolver.current(connectionId, fallbackName)`. */
val LocalWorkspaceIdentityResolver =
    staticCompositionLocalOf<(String, String) -> WorkspaceIdentity> { ::defaultIdentityResolver }
```

(b) New file `ui/components/WorkspaceBadge.kt`:
```kotlin
package com.atomikpanda.groundcontrol.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.atomikpanda.groundcontrol.ui.theme.WorkspaceIdentity
import com.atomikpanda.groundcontrol.ui.theme.WorkspacePalette

/** The one reusable per-workspace identity badge: a solid rounded-square swatch with a white glyph.
 *  Rendered everywhere a workspace is referenced so identity stays consistent across the app (ac7). */
@Composable
fun WorkspaceBadge(
    identity: WorkspaceIdentity,
    modifier: Modifier = Modifier,
    size: Dp = 24.dp,
) {
    Box(
        modifier.size(size).clip(RoundedCornerShape(percent = 28)).background(identity.color),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            identity.glyph,
            color = WorkspacePalette.onColor,
            fontWeight = FontWeight.Bold,
            fontSize = (size.value * 0.55f).sp,
            maxLines = 1,
            style = MaterialTheme.typography.labelMedium,
        )
    }
}
```

**Step 4 — run to pass:** rerun Step 2 (green), then a full-suite compile+run to prove the composable compiles:
```
./gradlew --offline testDebugUnitTest
```

**Step 5 — commit:**
```
git -C $WT add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/components/WorkspaceBadge.kt \
             android/app/src/main/java/com/atomikpanda/groundcontrol/ui/theme/WorkspaceIdentity.kt \
             android/app/src/test/java/com/atomikpanda/groundcontrol/WorkspaceIdentityTest.kt
git -C $WT commit -m "gc-projects-tab: reusable WorkspaceBadge + identity resolver CompositionLocal (ac7)

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "WorkspaceBadge composable + LocalWorkspaceIdentityResolver default (ac7)" --task gc-projects-tab --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=7 -->
## Task 7 — Projects tab: Section.PROJECTS, VM + pure projectRows, screen, nav wiring (ac1, ac6)

**Files:** `main/.../ui/nav/Section.kt` (edit), `test/.../SectionTest.kt` (edit), `main/.../ui/projects/ProjectsViewModel.kt` (new), `main/.../ui/projects/ProjectsScreen.kt` (new), `test/.../ProjectsViewModelTest.kt` (new), `main/.../GroundControlApp.kt` (edit).

**Step 1 — write failing tests.**

(a) Replace the assertions in `SectionTest.kt`:
```kotlin
    @Test fun five_destinations_home_queue_tasks_projects_settings() {
        assertEquals(
            listOf("home", "queue", "tasks", "projects", "settings"),
            Section.entries.map { it.route },
        )
    }

    @Test fun home_is_start_and_projects_precedes_settings() {
        val routes = Section.entries.map { it.route }
        assertEquals(0, routes.indexOf("home"))
        assertEquals(1, routes.indexOf("queue"))
        assertTrue(routes.indexOf("projects") < routes.indexOf("settings"))
    }
```

(b) New `test/.../ProjectsViewModelTest.kt`:
```kotlin
package com.atomikpanda.groundcontrol

import com.atomikpanda.groundcontrol.data.WorkspaceConnection
import com.atomikpanda.groundcontrol.ui.projects.projectRows
import com.atomikpanda.groundcontrol.ui.projects.workspaceRoute
import com.atomikpanda.groundcontrol.ui.theme.autoColor
import com.atomikpanda.groundcontrol.ui.theme.colorFromHex
import org.junit.Assert.assertEquals
import org.junit.Test

class ProjectsViewModelTest {
    private val conns = listOf(
        WorkspaceConnection("a", "http://a:47100", null, "acme"),
        WorkspaceConnection("b", "http://b:47100", null, "beta", colorOverride = "#FFD32F2F", glyphOverride = "B"),
        WorkspaceConnection("c", "http://c:47100", null, ""),   // blank name → baseUrl
    )

    @Test fun one_row_per_connection_in_order() {
        val rows = projectRows(conns)
        assertEquals(listOf("a", "b", "c"), rows.map { it.connectionId })
    }

    @Test fun row_route_targets_the_existing_workspace_detail() {
        assertEquals("workspace/a", projectRows(conns)[0].route)
        assertEquals("workspace/b", workspaceRoute("b"))
    }

    @Test fun row_identity_is_resolved_override_or_auto() {
        val rows = projectRows(conns)
        assertEquals(autoColor("acme"), rows[0].identity.color)   // auto
        assertEquals("A", rows[0].identity.glyph)
        assertEquals(colorFromHex("#FFD32F2F"), rows[1].identity.color) // override
        assertEquals("B", rows[1].identity.glyph)
        assertEquals("H", rows[2].identity.glyph)                 // "http://..." → H
    }

    @Test fun directory_builds_offline_from_connections_only() {
        assertEquals(3, projectRows(conns).size)
    }
}
```

**Step 2 — run to fail:**
```
./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.SectionTest" --tests "com.atomikpanda.groundcontrol.ProjectsViewModelTest"
```

**Step 3 — implement.**

(a) `ui/nav/Section.kt` — add the entry (before SETTINGS):
```kotlin
import androidx.compose.material.icons.filled.Dashboard
// ...
enum class Section(val route: String, val label: String, val icon: ImageVector) {
    HOME("home", "Home", Icons.Filled.Home),
    QUEUE("queue", "Queue", Icons.Filled.Inbox),
    TASKS("tasks", "Tasks", Icons.AutoMirrored.Filled.Assignment),
    PROJECTS("projects", "Projects", Icons.Filled.Dashboard),
    SETTINGS("settings", "Settings", Icons.Filled.Settings),
}
```

(b) New `ui/projects/ProjectsViewModel.kt`:
```kotlin
package com.atomikpanda.groundcontrol.ui.projects

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.atomikpanda.groundcontrol.data.ConnectionsRepository
import com.atomikpanda.groundcontrol.data.WorkspaceConnection
import com.atomikpanda.groundcontrol.ui.theme.WorkspaceIdentity
import com.atomikpanda.groundcontrol.ui.theme.resolveIdentity
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/** One Projects-tab row: name + resolved identity + the reused workspace detail route. */
data class ProjectRow(
    val connectionId: String,
    val name: String,
    val identity: WorkspaceIdentity,
    val route: String,
)

/** Reuse the existing per-workspace detail route (GroundControlApp `workspace/{connectionId}`). */
fun workspaceRoute(connectionId: String): String = "workspace/$connectionId"

/** Pure: one row per connection, identity resolved override-or-auto. No I/O (ac8: offline). */
fun projectRows(connections: List<WorkspaceConnection>): List<ProjectRow> =
    connections.map { c ->
        ProjectRow(
            connectionId = c.id,
            name = c.workspaceName.ifBlank { c.baseUrl },
            identity = resolveIdentity(c),
            route = workspaceRoute(c.id),
        )
    }

class ProjectsViewModel(private val repo: ConnectionsRepository) : ViewModel() {
    val rows: StateFlow<List<ProjectRow>> get() = _rows
    private val _rows = MutableStateFlow<List<ProjectRow>>(emptyList())

    init { viewModelScope.launch { repo.connections.collect { _rows.value = projectRows(it) } } }

    fun setOverride(connectionId: String, colorOverride: String?, glyphOverride: String?) {
        viewModelScope.launch { repo.setIdentity(connectionId, colorOverride, glyphOverride) }
    }
}
```

(c) New `ui/projects/ProjectsScreen.kt` (edit dialog added in Task 8):
```kotlin
package com.atomikpanda.groundcontrol.ui.projects

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.atomikpanda.groundcontrol.ui.components.WorkspaceBadge

@Composable
fun ProjectsScreen(
    vm: ProjectsViewModel,
    onOpenWorkspace: (connectionId: String) -> Unit,
) {
    val rows by vm.rows.collectAsStateWithLifecycle()
    LazyColumn(Modifier.fillMaxSize()) {
        items(rows, key = { it.connectionId }) { row ->
            ListItem(
                leadingContent = { WorkspaceBadge(row.identity, size = 32.dp) },
                headlineContent = { Text(row.name, style = MaterialTheme.typography.titleMedium) },
                modifier = Modifier.clickable { onOpenWorkspace(row.connectionId) },
            )
        }
    }
}
```

(d) `GroundControlApp.kt` — add the route inside the `NavHost` (after the `Section.TASKS` block):
```kotlin
            composable(Section.PROJECTS.route) {
                val vm = viewModel { ProjectsViewModel(connRepo) }
                ProjectsScreen(vm, onOpenWorkspace = { connId -> nav.navigate("workspace/$connId") })
            }
```
Add imports:
```kotlin
import com.atomikpanda.groundcontrol.ui.projects.ProjectsScreen
import com.atomikpanda.groundcontrol.ui.projects.ProjectsViewModel
```

**Step 4 — run to pass:** rerun Step 2, then a full-suite run:
```
./gradlew --offline testDebugUnitTest
```

**Step 5 — commit:**
```
git -C $WT add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/nav/Section.kt \
             android/app/src/main/java/com/atomikpanda/groundcontrol/ui/projects/ \
             android/app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApp.kt \
             android/app/src/test/java/com/atomikpanda/groundcontrol/SectionTest.kt \
             android/app/src/test/java/com/atomikpanda/groundcontrol/ProjectsViewModelTest.kt
git -C $WT commit -m "gc-projects-tab: Projects tab (5th nav) listing workspaces, rows reuse workspace detail (ac1/ac6)

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "Section.PROJECTS + ProjectsScreen/VM + projectRows one-per-conn → workspace route (ac1/ac6)" --task gc-projects-tab --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=8 -->
## Task 8 — Projects override-edit affordance (dialog) → setOverride (ac4-UI)

**Files:** `main/.../ui/projects/ProjectsScreen.kt` (edit). Logic (`applyIdentityOverride`/`setIdentity`/`colorFromHex`) already tested; this task is UI wiring verified by full-suite compile.

**Step 1 — regression anchor test** — add to `ProjectsViewModelTest.kt`:
```kotlin
    @Test fun palette_swatches_encode_to_parseable_hex() {
        for (c in com.atomikpanda.groundcontrol.ui.theme.WorkspacePalette.swatches) {
            assertEquals(c, colorFromHex(com.atomikpanda.groundcontrol.ui.theme.toHex(c)))
        }
    }
```

**Step 2 — run to fail:**
```
./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.ProjectsViewModelTest"
```
(Green if Task 1 codec is symmetric; if red, fix `toHex`/`colorFromHex` symmetry.)

**Step 3 — implement** — extend `ProjectsScreen.kt`: add a trailing "edit" IconButton per row that opens an `AlertDialog` letting the operator pick a palette swatch + type a 1-char glyph, plus a "Reset to auto" action. On confirm call `vm.setOverride(id, pickedHex, glyphOrNull)`; on reset call `vm.setOverride(id, null, null)`:
```kotlin
// add imports: remember, mutableStateOf, getValue, setValue, AlertDialog, IconButton, TextButton,
// OutlinedTextField, Icon, Icons.Filled.Edit, Row, Column, Spacer, height, width, Arrangement,
// Box, background, border, clip, size, RoundedCornerShape, clickable,
// com.atomikpanda.groundcontrol.ui.theme.WorkspacePalette, .toHex, FlowRow

@Composable
fun ProjectsScreen(vm: ProjectsViewModel, onOpenWorkspace: (String) -> Unit) {
    val rows by vm.rows.collectAsStateWithLifecycle()
    var editing by remember { mutableStateOf<ProjectRow?>(null) }
    LazyColumn(Modifier.fillMaxSize()) {
        items(rows, key = { it.connectionId }) { row ->
            ListItem(
                leadingContent = { WorkspaceBadge(row.identity, size = 32.dp) },
                headlineContent = { Text(row.name, style = MaterialTheme.typography.titleMedium) },
                trailingContent = {
                    IconButton(onClick = { editing = row }) {
                        Icon(Icons.Filled.Edit, contentDescription = "Edit ${row.name} identity")
                    }
                },
                modifier = Modifier.clickable { onOpenWorkspace(row.connectionId) },
            )
        }
    }
    editing?.let { row ->
        IdentityEditDialog(
            row = row,
            onDismiss = { editing = null },
            onSave = { hex, glyph -> vm.setOverride(row.connectionId, hex, glyph); editing = null },
            onReset = { vm.setOverride(row.connectionId, null, null); editing = null },
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun IdentityEditDialog(
    row: ProjectRow,
    onDismiss: () -> Unit,
    onSave: (hex: String?, glyph: String?) -> Unit,
    onReset: () -> Unit,
) {
    var picked by remember { mutableStateOf(row.identity.color) }
    var glyph by remember { mutableStateOf(row.identity.glyph) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Identity: ${row.name}") },
        text = {
            Column {
                OutlinedTextField(
                    value = glyph,
                    onValueChange = { glyph = it.take(1).uppercase() },
                    label = { Text("Glyph") },
                    singleLine = true,
                )
                Spacer(Modifier.height(12.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    WorkspacePalette.swatches.forEach { c ->
                        Box(
                            Modifier.size(32.dp).clip(RoundedCornerShape(percent = 28))
                                .background(c)
                                .border(
                                    width = if (c == picked) 3.dp else 0.dp,
                                    color = MaterialTheme.colorScheme.onSurface,
                                    shape = RoundedCornerShape(percent = 28),
                                )
                                .clickable { picked = c },
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                onSave(picked.toHex(), glyph.trim().takeIf { it.isNotEmpty() })
            }) { Text("Save") }
        },
        dismissButton = {
            Row {
                TextButton(onClick = onReset) { Text("Reset to auto") }
                TextButton(onClick = onDismiss) { Text("Cancel") }
            }
        },
    )
}
```
(`FlowRow` + `ExperimentalLayoutApi` from `androidx.compose.foundation.layout`; if unavailable, fall back to a `LazyRow`.)

**Step 4 — run to pass:** rerun Step 2 (green) then full-suite compile:
```
./gradlew --offline testDebugUnitTest
```

**Step 5 — commit:**
```
git -C $WT add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/projects/ProjectsScreen.kt \
             android/app/src/test/java/com/atomikpanda/groundcontrol/ProjectsViewModelTest.kt
git -C $WT commit -m "gc-projects-tab: per-workspace color/glyph override edit dialog, persisted via setIdentity (ac4)

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "Projects override edit dialog (swatch + glyph + reset) → repo.setIdentity (ac4)" --task gc-projects-tab --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=9 -->
## Task 9 — Render the badge on Home needs-you items + Queue cards (ac7)

**Files:** `main/.../ui/home/HomeScreen.kt` (edit `NeedsYouRow`), `main/.../ui/queue/QueueScreen.kt` (edit `CardFace`). Both read `LocalWorkspaceIdentityResolver`. UI-only; verified by full-suite compile.

**Step 1 — no new unit test** (identity resolve + badge already covered). Run-to-fail/pass = full suite.

**Step 2 — baseline run:**
```
./gradlew --offline testDebugUnitTest
```

**Step 3 — implement.**

(a) `HomeScreen.kt` `NeedsYouRow` — replace the colored-name `overlineContent` (currently `Text(item.workspaceName, style = MonoStyle, color = chipHue(item.connectionId, colors))`) with badge + name:
```kotlin
// imports: com.atomikpanda.groundcontrol.ui.components.WorkspaceBadge,
//          com.atomikpanda.groundcontrol.ui.theme.LocalWorkspaceIdentityResolver,
//          Row, Alignment, Spacer, width, dp
    val identity = LocalWorkspaceIdentityResolver.current(item.connectionId, item.workspaceName)
    // ...inside ListItem:
        overlineContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                WorkspaceBadge(identity, size = 16.dp)
                Spacer(Modifier.width(6.dp))
                Text(item.workspaceName, style = MonoStyle)
            }
        },
```
(`chipHue` import may now be unused — remove it if so to keep the build warning-clean.)

(b) `QueueScreen.kt` `CardFace` — replace the plain workspace-name `Text` with badge + name (the card carries `connectionId` + `workspaceName`):
```kotlin
// imports: WorkspaceBadge, LocalWorkspaceIdentityResolver, Row, Alignment, Spacer, width
            val wsIdentity = LocalWorkspaceIdentityResolver.current(card.connectionId, card.workspaceName)
            Row(verticalAlignment = Alignment.CenterVertically) {
                WorkspaceBadge(wsIdentity, size = 18.dp)
                Spacer(Modifier.width(6.dp))
                Text(card.workspaceName, style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
```

**Step 4 — run to pass:**
```
./gradlew --offline testDebugUnitTest
```
(Existing HomeViewModelTest/QueueViewModelTest/NeedsYouItemTest/QueueCardTest stay green — render-only change.)

**Step 5 — commit:**
```
git -C $WT add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/home/HomeScreen.kt \
             android/app/src/main/java/com/atomikpanda/groundcontrol/ui/queue/QueueScreen.kt
git -C $WT commit -m "gc-projects-tab: WorkspaceBadge on Home needs-you items + Queue cards (ac7)

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "Badge rendered on Home needs-you rows + Queue cards via resolver (ac7)" --task gc-projects-tab --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=10 -->
## Task 10 — Badge in thread/spec/console headers + provide the resolver app-wide (ac7)

**Files:** `main/.../GroundControlApp.kt` (provide `LocalWorkspaceIdentityResolver`, pass identity into the three header screens), `ui/messages/ConversationScreen.kt`, `ui/specdetail/SpecDetailScreen.kt`, `ui/console/ConsoleScreen.kt` (accept optional `identity`, render badge in `TopAppBar` title). UI-only; full-suite compile verifies.

**Step 1 — no new unit test.** Run-to-fail/pass = full suite.

**Step 2 — baseline run:** `./gradlew --offline testDebugUnitTest`

**Step 3 — implement.**

(a) `GroundControlApp.kt` — collect connections reactively and wrap the `NavHost` in the provider:
```kotlin
// imports: androidx.compose.runtime.CompositionLocalProvider,
//          com.atomikpanda.groundcontrol.ui.theme.LocalWorkspaceIdentityResolver,
//          com.atomikpanda.groundcontrol.ui.theme.resolveIdentity,
//          com.atomikpanda.groundcontrol.ui.theme.autoIdentity,
//          com.atomikpanda.groundcontrol.ui.theme.WorkspaceIdentity,
//          androidx.lifecycle.compose.collectAsStateWithLifecycle
```
Inside `Scaffold { padding -> … }`, before `NavHost`:
```kotlin
        val connsForBadges by connRepo.connections.collectAsStateWithLifecycle(initialValue = emptyList())
        val identityResolver: (String, String) -> WorkspaceIdentity =
            { id, name -> connsForBadges.firstOrNull { it.id == id }?.let(::resolveIdentity) ?: autoIdentity(name) }
        CompositionLocalProvider(LocalWorkspaceIdentityResolver provides identityResolver) {
            NavHost(nav, startDestination = Section.HOME.route, modifier = Modifier.padding(padding)) {
                // ... all existing composable(...) blocks unchanged, PLUS the PROJECTS block from Task 7 ...
            }
        }
```
Then in the `thread/{…}`, `specDetail/{…}` and `console/{…}` blocks, pass identity resolved via the local:
```kotlin
                    val badge = LocalWorkspaceIdentityResolver.current(connectionId, conn.workspaceName.ifBlank { conn.baseUrl })
                    ConversationScreen(vm, title = threadId, identity = badge, onBack = { nav.popBackStack() }, /* …existing callbacks… */)
```
Do the same for `SpecDetailScreen(vm, title = title, identity = badge, onBack = …)` and `ConsoleScreen(vm, title = conn.workspaceName.ifBlank { conn.baseUrl }, identity = badge, onBack = …)`.

(b) Each of the three screens — add `identity: WorkspaceIdentity? = null` param (default keeps other callers source-compatible) and render the badge in the `TopAppBar` title. Example `ConversationScreen.kt`:
```kotlin
// import WorkspaceBadge, WorkspaceIdentity, Row, Spacer, width, Alignment
fun ConversationScreen(
    vm: ConversationViewModel,
    title: String,
    identity: WorkspaceIdentity? = null,
    onBack: () -> Unit,
    /* … existing optional callbacks … */
) {
    // ...
            TopAppBar(
                title = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        identity?.let { WorkspaceBadge(it, size = 20.dp); Spacer(Modifier.width(8.dp)) }
                        Text(displayTitle, maxLines = 1)
                    }
                },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
            )
```
Apply the identical title-slot change to `SpecDetailScreen.kt` and `ConsoleScreen.kt`.

**Step 4 — run to pass:**
```
./gradlew --offline testDebugUnitTest
```

**Step 5 — commit:**
```
git -C $WT add android/app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApp.kt \
             android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/ConversationScreen.kt \
             android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specdetail/SpecDetailScreen.kt \
             android/app/src/main/java/com/atomikpanda/groundcontrol/ui/console/ConsoleScreen.kt
git -C $WT commit -m "gc-projects-tab: badge in thread/spec/console headers + app-wide override-aware resolver (ac7)

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "Header badges + LocalWorkspaceIdentityResolver provided from connections in GroundControlApp (ac7)" --task gc-projects-tab --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=11 -->
## Task 11 — Regression guard: cross-workspace aggregation intact, no serve change (ac8)

**Files:** `test/.../ProjectsRegressionTest.kt` (new). No production edits.

**Step 1 — write the guard test** `app/src/test/java/com/atomikpanda/groundcontrol/ProjectsRegressionTest.kt`:
```kotlin
package com.atomikpanda.groundcontrol

import com.atomikpanda.groundcontrol.data.WorkspaceConnection
import com.atomikpanda.groundcontrol.ui.projects.ProjectsViewModel
import com.atomikpanda.groundcontrol.ui.projects.projectRows
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Constructor

/** ac8: the Projects directory is orientation-only. It builds purely from the stored connection
 *  list with NO serve call, and must not introduce any app-scoping. */
class ProjectsRegressionTest {
    @Test fun projects_view_model_depends_only_on_connections_repository_no_specapi() {
        val ctors: Array<Constructor<*>> = ProjectsViewModel::class.java.declaredConstructors
        val paramTypes = ctors.flatMap { it.parameterTypes.map { p -> p.simpleName } }
        assertTrue("ProjectsViewModel must not take SpecApi", paramTypes.none { it == "SpecApi" })
        assertTrue("ProjectsViewModel must not take HttpClient", paramTypes.none { it == "HttpClient" })
    }

    @Test fun directory_lists_every_workspace_no_scoping_or_filtering() {
        val all = listOf(
            WorkspaceConnection("a", "http://a", null, "acme"),
            WorkspaceConnection("b", "http://b", null, "beta"),
            WorkspaceConnection("c", "http://c", null, "gamma"),
        )
        assertEquals(all.map { it.id }, projectRows(all).map { it.connectionId })
    }
}
```

**Step 2 — run:**
```
./gradlew --offline testDebugUnitTest --tests "com.atomikpanda.groundcontrol.ProjectsRegressionTest" \
  --tests "com.atomikpanda.groundcontrol.HomeViewModelTest" \
  --tests "com.atomikpanda.groundcontrol.QueueViewModelTest"
```

**Step 3 — implement:** none. If `projects_view_model_depends_only…` is red, remove any `SpecApi`/`HttpClient` dep the VM accidentally grew.

**Step 4 — run to pass (full suite as the final gate):**
```
./gradlew --offline testDebugUnitTest
```
Confirm HomeViewModelTest + QueueViewModelTest pass unchanged and the whole suite is green.

**Step 5 — commit:**
```
git -C $WT add android/app/src/test/java/com/atomikpanda/groundcontrol/ProjectsRegressionTest.kt
git -C $WT commit -m "gc-projects-tab: regression guard — no app-scoping, no new serve endpoint (ac8)

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "ac8 guard: Projects builds offline from connections, Home/Queue aggregation unchanged" --task gc-projects-tab --action committed
```
<!-- /mship:task -->

---

## Self-Review

**AC → Task coverage (all 8):**
| AC | Covered by |
|---|---|
| ac1 — 5th "Projects" nav item listing workspaces w/ name + colored glyph badge | Task 7 + badge from Task 6 |
| ac2 — deterministic/stable auto color + first-letter uppercased glyph | Task 1 |
| ac3 — curated fixed palette legible in light+dark | Task 1 + Task 2 (WCAG guard) |
| ac4 — set color/glyph override, persists, takes precedence | Task 3 + Task 5 + Task 8 |
| ac5 — re-pair preserves prior override | Task 4 |
| ac6 — row tap → existing workspace/{connectionId} / WorkspaceScreen | Task 7 |
| ac7 — one reusable WorkspaceBadge everywhere | Task 6 + Task 9 + Task 10 |
| ac8 — Home/Queue still aggregate all workspaces; no serve change | Task 11 |

**Placeholder scan:** No TODO/FIXME/stub bodies. Every new file + test is complete Kotlin. Edits show enough surrounding context to apply unambiguously.

**Type consistency — WorkspaceConnection's two new fields:** declared with defaults (Task 3) so all existing constructors (SettingsViewModel, PairLink, tests) keep compiling — nullable + defaulted, no positional break. Consumed in upsertConnection + applyIdentityOverride (Task 4), resolveIdentity (Task 5), ConnectionsRepository.setIdentity (Task 5), projectRows (Task 7). ConnectionsCodec needs no change (ignoreUnknownKeys + defaults, verified by legacy-decode test). Override stored/read as String? hex only in the data layer; Color conversion lives in ui/theme.

**Section enum consistency:** PROJECTS drives the NavigationBar loop automatically + requires the new composable(PROJECTS.route) (Task 7). SectionTest updated in the SAME task (currently asserts exactly four routes). startDestination = HOME unaffected. Order: HOME, QUEUE, TASKS, PROJECTS, SETTINGS.

**Resolver plumbing:** LocalWorkspaceIdentityResolver has a safe default (auto-by-name) so badges render before the provider is reached; GroundControlApp overrides with a connections-backed reactive resolver (Task 10). Badge sites need only (connectionId, fallbackName), which each already has.

**Reuse notes (no forking):** existing workspace/{connectionId} route + WorkspaceScreen (tap target), ConnectionsCodec + ConnectionsRepository (persistence), the Section.entries NavigationBar loop, the ThemeContrastTest WCAG helper (mirrored), SettingsViewModel's connections-collection pattern (mirrored). The chipHue colored-name chips are restyled onto the badge, not left parallel.
