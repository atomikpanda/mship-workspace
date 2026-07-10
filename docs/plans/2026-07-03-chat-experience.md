# Improve the Ground Control Chat Experience — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Spec:** mship spec `chat-experience` (approved + dispatched), Linear **MOS-212**. Task `chat-experience` (WorkItem `wi-20260703023637-92672bb8`, feature).

**Operator answers:** markdown = **agent-only** (don't markdown-render human messages); remove **only** the "Make this a spec" button (keep the separate "View spec →").

**Goal:** Make the GC chat readable + messaging-app-like: full-contrast markdown-rendered agent messages, scroll-while-typing, a modern rounded compose bar, minus the stale "Make this a spec" button.

**Architecture:** ground-control only, almost entirely `ui/messages/ConversationScreen.kt` (+ a small `ConversationViewModel` cleanup). Markdown reuses the already-present `com.mikepenz:multiplatform-markdown-renderer-m3` (see `ui/specdetail/SpecBodyMarkdown.kt`). No new deps, no API/model changes.

**Tech Stack:** Kotlin, Compose (Material3). JUnit4 (NOT kotlin.test). `source ~/toolchains/android-env.sh` before gradle. Build: `./android/gradlew -p android :app:assembleDebug`; evidence: `mship test`. All three tasks touch `ConversationScreen.kt`, so they are SEQUENTIAL (no parallel).

---

## File Structure

- **Modify** `ui/messages/ConversationScreen.kt` — `MessageRow` (render), `ConversationContentView` (scroll), `TopAppBar` (remove action), `ComposeBar` (restyle).
- **Modify** `ui/messages/ConversationViewModel.kt` — remove `requestSpec()`.
- **Modify** `src/test/.../ConversationViewModelTest.kt` — remove the `requestSpec` test.
- Possibly **create** a small `ui/messages/MessageMarkdown.kt` (bubble-tuned markdown wrapper).

---

<!-- mship:task id=1 -->
### Task 1: Agent-message contrast + markdown

**Files:** Modify `ui/messages/ConversationScreen.kt` (`MessageRow`, ~lines 203–238); optionally create `ui/messages/MessageMarkdown.kt`

- [ ] **Step 1: Read** `MessageRow` (ConversationScreen.kt ~203–238), `ui/specdetail/SpecBodyMarkdown.kt` (the `Markdown(content=…)` usage), and `ui/theme/Color.kt`/`Theme.kt` (the `onSurface`/`onSurfaceVariant` roles). Confirm the markdown dep in `android/app/build.gradle.kts`.

- [ ] **Step 2: Contrast.** In `MessageRow`, change the AGENT message text color from `MaterialTheme.colorScheme.onSurfaceVariant` (the muted role) to `MaterialTheme.colorScheme.onSurface` (full contrast). Leave the human branch (`onPrimary` on `primary`) unchanged. Keep the agent bubble background (`surfaceVariant`) — only the text foreground changes (adjust the bubble too only if still low-contrast).

- [ ] **Step 3: Markdown (agent-only).** For agent messages (`!isHuman`), render `message.text` as markdown instead of the plain `Text`. Reuse `com.mikepenz.markdown.m3.Markdown` via a small wrapper (either inline in `MessageRow` or a new `MessageMarkdown(text, color)` composable in `ui/messages/MessageMarkdown.kt`) tuned for a bubble: inherit the bubble text color, tighter spacing than the spec body, code spans in `JetBrainsMono`. **Human** messages keep the plain `Text` (operator answer). If `Markdown` needs a color/typography config, pass the bubble's `onSurface` color; verify the library's API against `SpecBodyMarkdown.kt`.

- [ ] **Step 4: Build** — `./android/gradlew -p android :app:assembleDebug` → BUILD SUCCESSFUL. Then **`mship test`** green (existing conversation tests unaffected; MessageRow is UI — build-verified).

- [ ] **Step 5: Commit** — `feat(chat): full-contrast + markdown-rendered agent messages` + `mship journal`.
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: Scroll-while-typing fix + remove "Make this a spec"

**Files:** Modify `ui/messages/ConversationScreen.kt` (`ConversationContentView` scroll effects ~119–158; `TopAppBar` actions ~69–73; import ~21), `ui/messages/ConversationViewModel.kt` (`requestSpec` ~107–108), `ConversationViewModelTest.kt`

- [ ] **Step 1: Scroll fix.** In `ConversationContentView`, the culprit is the IME-inset-keyed auto-scroll `LaunchedEffect` (~lines 144–147: `LaunchedEffect(imeBottom) { if (imeBottom>0 && itemCount>0) animateScrollToItem(...) }`) which force-pins to the bottom on every keyboard height change, blocking scroll-up while typing. **Remove that effect.** For the item-count effect (~125–128, scroll on new message), gate it so it only auto-scrolls when the user is already near the bottom before the new item (e.g. check `listState.layoutInfo` — last visible item index within ~2 of the old last index — before `animateScrollToItem`). Keep `imePadding()` (~160) and the decision-visibility effect (~154–158). Net: with the keyboard open you can scroll up and it stays; new messages still follow when you're at the bottom.

- [ ] **Step 2: Remove "Make this a spec".** Delete the `TopAppBar` `actions` block (~lines 69–73, the `IconButton { vm.requestSpec() }` with the `NoteAdd` icon) and the now-unused import (~line 21 `…automirrored.filled.NoteAdd`). In `ConversationViewModel.kt` delete `requestSpec()` (~107–108). In `ConversationViewModelTest.kt` delete the `request_spec_posts_canonical_message()` test (~208–242). **Leave** the "View spec →" `OutlinedButton` (~162–171) untouched (operator confirmed).

- [ ] **Step 3: Verify** — `./android/gradlew -p android :app:testDebugUnitTest --tests "com.atomikpanda.groundcontrol.ConversationViewModelTest"` green (requestSpec test gone, rest pass); `assembleDebug` BUILD SUCCESSFUL; **`mship test`** green.

- [ ] **Step 4: Commit** — `feat(chat): scroll-up while typing; remove 'Make this a spec' button` + `mship journal`.
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: Compose bar restyle

**Files:** Modify `ui/messages/ConversationScreen.kt` (`ComposeBar`, ~lines 240–290)

- [ ] **Step 1: Restyle the input row** (`ComposeBar`, the `Row` ~264–287) into a messaging-app bar: a **rounded** input container (an explicit `RoundedCornerShape(24.dp)` / pill — `AppShapes` caps at 8dp so use a local shape; a `TextField` with transparent indicator inside a rounded `Surface`, or `OutlinedTextField` with a large `shape`), and a **modern filled/tonal circular Send button** (`FilledIconButton`/`IconButton` with a filled container, `Icons.AutoMirrored.Filled.Send`) replacing the bare icon. Preserve: the `sendError` text (~245–252), the gated-decision "Choose an option above to continue." branch (~253–263), the in-flight `CircularProgressIndicator` state, `enabled = !state.inFlight`, and the draft/send wiring (`vm.draft`, `vm::onDraftChange`, `vm.send(draft)`).

- [ ] **Step 2: Reserve the attach slot.** Structure the `Row` so a **leading** `IconButton` (future file-attach) can be added as the first child without relayout — e.g. leave the horizontal arrangement + weights such that a leading icon + field + trailing send is the shape. Do NOT add a functional/dead attach button now (per the spec non-goal); a layout that accommodates one is enough (a brief comment marking where it goes is fine).

- [ ] **Step 3: Build** — `assembleDebug` BUILD SUCCESSFUL; **`mship test`** green.

- [ ] **Step 4: Visual (deferred)** — `mship capture`: open a thread → confirm readable markdown messages, scroll-up while typing, the rounded compose bar, no "Make this a spec". Deferred to operator (no emulator).

- [ ] **Step 5: Commit** — `feat(chat): rounded messaging-style compose bar (attach-ready)` + `mship journal`.
<!-- /mship:task -->

---

## Self-review checklist

- **Spec coverage:** contrast (T1) · agent-only markdown (T1) · scroll-while-typing (T2) · remove "Make this a spec" + requestSpec/test (T2) · rounded compose bar w/ attach slot (T3). Human messages stay plain (operator: agent-only). "View spec →" kept.
- **No new deps / API changes** — markdown reuses the existing renderer.
- **Conventions** — JUnit4; sequential (all touch ConversationScreen.kt).

## Notes / risks

- **Markdown in bubbles** needs spacing/typography tuning (bubble wrapper, not raw full-width `Markdown`).
- **Near-bottom gate** must still follow new messages when you're at the bottom — test both: scroll up + keyboard (stays), and at-bottom + new message (follows).
- **Pill compose bar** likely needs an explicit `RoundedCornerShape` (theme shapes cap at 8dp).
