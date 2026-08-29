# Queue Swipe Hints + Onboarding + Whole-Spec Confirmation — Implementation Plan

> **For agentic workers:** implement task-by-task. Steps use checkbox (`- [ ]`).

**Spec:** `queue-action-affordance-and-whole-spec` (approved)

**Goal:** keep swipe as THE Queue interaction and make it discoverable — a drag directional stamp, an always-visible resting hint, and a one-time onboarding coach mark — plus an explicit confirmation when a swipe finalizes a whole spec. No button bar.

**Architecture:** all in `ui/queue/QueueScreen.kt` (FlingCard drag rendering, CardFace resting hint, a first-run coach-mark overlay) + `ui/queue/QueueViewModel.kt` (last-chunk-finalize detection for the whole-spec confirmation) + a tiny persisted "coach-mark seen" flag. Keep the pure logic (which cue, is-final-chunk, coach-mark-seen, card-type hint) in testable functions.

**Tech Stack:** Kotlin/Compose/Material3, JUnit4 (`source ~/toolchains/android-env.sh` then gradle; run via `mship test`).

---

<!-- mship:task id=1 -->
### Task 1: whole-spec approve confirmation (ViewModel)

**Files:** Modify `ui/queue/QueueViewModel.kt`; Test `QueueViewModelTest.kt`.

- [ ] **Step 1: Failing test** — approving the LAST remaining chunk of a spec yields a "spec finalized" confirmation state carrying the spec title (distinct from the single-chunk 'Approved / Undo' state).
- [ ] **Step 2:** In the approve-all path (`approveAllCurrent` / `removeSpecCardsAdvancing`), when the action finalizes the whole spec (last chunk → the auto-approve fires), expose a confirmation signal (e.g. a `SpecApprovedNotice(title)` on the Content state) instead of nothing; non-final chunk keeps the existing undo snackbar. Surface it in `QueueScreen` as a longer-duration snackbar "Approved spec: <title>".
- [ ] **Step 3: tests pass. Commit + journal.**
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: coach-mark-seen flag + card-type hint (pure logic)

**Files:** Create/modify a small helper in `ui/queue/`; Test alongside QueueCardTest.

- [ ] **Step 1: Failing test** — a `queueCardHint(card)` maps each card type to its swipe/what's-needed hint text (Prose/Criteria → swipe right approve / left request changes; Questions → "Answer to continue"; Decision → "Choose an option"); and a coach-mark-seen flag round-trips through the persistence shim.
- [ ] **Step 2:** implement `queueCardHint`; persist the coach-mark-seen flag (SharedPreferences or the app's existing settings store — check how other one-time flags are stored; if none, a simple SharedPreferences-backed holder).
- [ ] **Step 3: tests pass. Commit + journal.**
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: drag directional stamp (Compose, FlingCard)

**Files:** Modify `ui/queue/QueueScreen.kt` (`FlingCard`).

- [ ] **Step 1:** During drag, overlay a directional cue under/over the card whose alpha (and optionally scale) grows with |offsetX| toward the fling threshold — green "✓ Approve" as it moves right, red "⚑ Request changes" as it moves left (use `LocalSemanticColors.current.approval` / `colorScheme.error`); clears on release / spring-back. Only for card types where the direction is a valid action.
- [ ] **Step 2:** `compileDebugKotlin` clean. Commit + journal.
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: always-visible resting hint + per-card hint (Compose, CardFace)

**Files:** Modify `ui/queue/QueueScreen.kt` (`CardFace`).

- [ ] **Step 1:** On the resting card, render a subtle, non-tappable directional hint — for approve-capable cards a muted "Request changes  ←   →  Approve" line (or faint edge chevrons); for Questions/Decision cards show `queueCardHint(card)` ("Answer to continue" / "Choose an option"). Keep it muted (onSurfaceVariant) and clearly not a button.
- [ ] **Step 2:** `compileDebugKotlin` clean. Commit + journal.
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: first-run onboarding coach mark (Compose)

**Files:** Modify `ui/queue/QueueScreen.kt`.

- [ ] **Step 1:** On first Queue open (coach-mark-seen == false), show a one-time overlay/dialog demonstrating "swipe right = approve, swipe left = request changes"; a "Got it" dismiss sets the seen flag; a small info affordance (e.g. an icon in the header) re-opens it on demand. Persisted so it doesn't reappear.
- [ ] **Step 2:** `compileDebugKotlin` + `testDebugUnitTest` green; then `mship test --task queue-swipe-hints-onboarding-whole-spec`. Commit + journal.
<!-- /mship:task -->

---

## Self-Review
- Spec AC1 (drag stamp) → Task 3. AC2 (resting hint, not a button) → Task 4. AC3 (one-time re-openable coach mark) → Tasks 2+5. AC4 (whole-spec confirmation vs undo) → Task 1. AC5 (non-approve cards show what's needed, no button) → Tasks 2+4.
- Non-goal honored: no persistent approve/request-changes button bar anywhere.
