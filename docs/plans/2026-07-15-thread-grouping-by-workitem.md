# Group Ground Control Threads by WorkItem — Implementation Plan

> **For agentic workers:** implement task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Spec:** `group-ground-control-threads-by-workitem` (approved)

**Goal:** serve stamps a single resolved `work_item_id` on each thread summary; Ground Control groups the messages surface by WorkItem, with an "Other" bucket for unowned threads.

**Architecture:** The thread↔WorkItem link only lives server-side today (`WorkItem.thread_ids`, plus indirect via a thread's `task_slug`/`spec_id`). Resolve it in serve — reusing the pr_watcher's existing routing — and expose one `work_item_id` field so GC stays thin and groups by it. Invariant: a thread belongs to AT MOST ONE WorkItem (direct membership is exclusive; the indirect fallback resolves to exactly one).

**Tech Stack:** serve = Python/Pydantic/FastAPI, pytest (`uv run pytest -q` via `mship test`). GC = Kotlin/Compose/Material3, JUnit4 (`source ~/toolchains/android-env.sh` then gradle; run via `mship test`).

---

<!-- mship:task id=1 -->
### Task 1: serve — resolve + stamp `work_item_id` on thread summaries

**Files:**
- Modify: `mothership/src/mship/core/serve.py` (the thread-list / inbox-summary endpoint that builds thread summaries — find where `_summaries` / thread-summary dicts are built, mirror the `work_item_kind` stamping added for specs in `get_spec`).
- Look at: `mothership/src/mship/core/pr_watcher.py` (`resolve_task_thread` / the WorkItem↔thread routing) and `mothership/src/mship/core/workitem_store.py` (WorkItem has `thread_ids`, `task_slugs`, `spec_id`).
- Test: `mothership/tests/core/` (add near the existing thread/summary or pr_watcher tests).

- [ ] **Step 1: Write a helper** `resolve_thread_work_item_id(thread, workitems)` that returns the id of the WorkItem owning `thread`, or None:
  - Direct: the WorkItem whose `thread_ids` contains `thread.id` (exclusive — pick deterministically if somehow more than one).
  - Else indirect: a WorkItem whose `task_slugs` contains `thread.task_slug`, or whose `spec_id == thread.spec_id`.
  - Else None. Build a `thread_id -> work_item_id` index once per list call for efficiency; guard the whole resolve in try/except so a corrupt WorkItem can't 500 the list (fall back to None), mirroring the best-effort pattern in `get_spec`.
- [ ] **Step 2: Failing test** — a thread in an item's `thread_ids` resolves to that item; a thread linked only by `task_slug`/`spec_id` resolves to the right item; a thread with neither → None; the linker never yields two items for one thread; and the thread-summary payload carries the stamped `work_item_id`.
- [ ] **Step 3: Stamp** `work_item_id` onto each thread summary dict returned by the thread-list endpoint.
- [ ] **Step 4: `mship test --task group-ground-control-threads-by-workitem`** → serve green.
- [ ] **Step 5: Commit + `mship journal`.**
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: GC DTO — `workItemId` on the thread summary

**Files:**
- Modify: `ground-control/android/app/src/main/java/com/atomikpanda/groundcontrol/data/dto/ThreadDtos.kt` (`ThreadSummary`).
- Test: `ground-control/android/app/src/test/java/com/atomikpanda/groundcontrol/` (DTO parse test).

- [ ] **Step 1: Failing test** — a thread-summary JSON with `"work_item_id":"wi-..."` parses into `workItemId`; one without defaults to null.
- [ ] **Step 2:** add `@SerialName("work_item_id") val workItemId: String? = null` to `ThreadSummary`.
- [ ] **Step 3: tests pass. Commit + journal.**
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: GC — group the messages surface by WorkItem

**Files:**
- Modify: `ground-control/android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/MessagesScreen.kt` (+ a small pure grouping helper file if cleaner).
- Look at: how `MessagesViewModel` exposes thread summaries + how items (`/items`, WorkItem title/kind) are available for labels.
- Test: `ground-control/android/app/src/test/java/com/atomikpanda/groundcontrol/` (grouping helper).

- [ ] **Step 1: Failing test** — a pure `groupThreadsByWorkItem(threads, items)` helper buckets summaries by `workItemId`: one group per WorkItem (carrying its title + kind for the header), threads ordered most-recent-first within a group; null `workItemId` → a single "Other" group; groups ordered by their newest thread; each group's attention rolls up (any thread awaiting the operator / unhandled agent event → the group shows attention).
- [ ] **Step 2: Implement the helper.**
- [ ] **Step 3: Render** the messages surface as grouped sections (WorkItem header = title + kind + attention indicator; "Other" for unowned). Tapping a thread still opens the existing conversation view unchanged.
- [ ] **Step 4: `mship test`** (both repos) green.
- [ ] **Step 5: Commit + journal.**
<!-- /mship:task -->

---

## Self-Review
- Spec AC1 (stamp work_item_id) → Task 1. AC2 (≤1 WorkItem, matches pr_watcher, single-valued) → Task 1 helper + tests. AC3 (group per WorkItem + Other) → Task 3. AC4 (group attention rollup) → Task 3. AC5 (tap opens existing conversation unchanged) → Task 3. AC6 (order by newest thread) → Task 3 helper.
- Types: serve `work_item_id` (Task 1) → GC `workItemId` (Task 2) → grouping helper key (Task 3).
