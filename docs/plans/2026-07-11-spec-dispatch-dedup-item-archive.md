# spec dispatch dedup + mship item archive — Implementation Plan (MOS-228)

> **For agentic workers:** Use subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Spec:** `spec-dispatch-dedup-mship-item-archive-mos-228` (approved).

**Goal:** Stop `mship spec dispatch` from silently duplicating a task/WorkItem, and add a soft, reversible `mship item archive` so orphan WorkItems are removable.

**Architecture:** Two independent parts in `mothership`. Part 2 (archive) is data-model + CLI/serve/view plumbing (Tasks 1–3). Part 1 (dispatch dedup) is logic in the adopt ladder (Task 4). They don't depend on each other; ordered archive-first so the dispatch refuse-to-guess message can reference `item link-task` which already exists.

**Tech Stack:** Python, Typer CLI, dataclass/pydantic models, JSON-per-item store under `.mothership/workitems/`, FastAPI serve, pytest.

**Key code (from investigation):**
- WorkItem model: `src/mship/core/workitem.py:21-35` (fields; NO status field today).
- Store: `src/mship/core/workitem_store.py` (JSON per item; `create/get/list/save/link_spec/add_task/...`; no delete/archive).
- CLI: `src/mship/cli/workitem.py` (`new/list/show/link-spec/link-task/...`).
- Serve: `src/mship/core/serve.py:619-691` (`GET /items`, `GET /items/{id}`, `POST /items/{id}/...`).
- View: `src/mship/view/workitem_index.py` (joins items→spec/tasks/threads; filters by live tasks at ~:105-106; sinks phase `done` at ~:126-130).
- Gate: `src/mship/core/workitem_gate.py:26-39` (task blocked if `work_item_id` set but item missing — the reverse-link hazard).
- Dispatch ladder: `src/mship/core/spec_dispatch.py:72-166` (branches at :110/:123/:126/:129; WorkItem mint at :144-150); CLI spawn wiring `src/mship/cli/spec.py:457-463`.
- `Task.work_item_id`: `src/mship/core/state.py:53`. `Spec.work_item_id`: `src/mship/core/spec.py:40`.
- Precedent to mirror: `spec archive` (`SpecStatus` archived; `src/mship/cli/spec.py:647-649`; `POST /specs/{id}/archive` `serve.py:373-390`).

---

<!-- mship:task id=1 -->
### Task 1: WorkItem `archived` field + store archive/unarchive + list filter

**Files:** Modify `src/mship/core/workitem.py`, `src/mship/core/workitem_store.py`; Test `tests/core/test_workitem_store.py` (and/or the workitem model test).

- [ ] **Step 1: Failing tests.** In the store test: (a) `archive(id)` sets `archived=True` and persists; `unarchive(id)` clears it; (b) `list()` excludes archived items by default and `list(include_archived=True)` returns them; (c) an existing on-disk JSON with NO `archived` key loads with `archived=False` (backward compat) — write a JSON file without the key and `get()` it.
- [ ] **Step 2: Implement.** Add `archived: bool = False` to the `WorkItem` model (`core/workitem.py`) — ensure the deserializer defaults missing → `False` (mirror how other optional fields load). In `WorkItemStore` (`core/workitem_store.py`) add `archive(id)`/`unarchive(id)` (load, set flag, save — raise a clear error if id unknown), and add an `include_archived: bool = False` param to `list()` that filters out `archived` items unless set.
- [ ] **Step 3: Green + commit.** `mship test`; `mship journal "WorkItem.archived field + store archive/unarchive + list filter; backward-compatible load" --action committed`.
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: `mship item archive`/`unarchive` CLI + `item list --all` + live-task guard

**Files:** Modify `src/mship/cli/workitem.py`; Test `tests/cli/test_workitem.py`.

- [ ] **Step 1: Failing tests.** (a) `item archive <id>` archives an item with no live task referencing it; the item then disappears from `item list` and reappears under `item list --all`; (b) `item archive <id>` is REFUSED (non-zero exit, actionable message) when a non-closed task has `work_item_id == id`, and SUCCEEDS with `--force`; (c) `item unarchive <id>` restores it to the default list; (d) archiving an unknown id errors cleanly.
- [ ] **Step 2: Implement.** Add `archive`/`unarchive` subcommands to the `item` Typer group and an `--all` flag on `item list` (passes `include_archived=True` to the store). The archive guard: load state, find non-closed tasks with `work_item_id == id` (a task is live if it's in `state.tasks` and `finished_at is None` / not closed — match the existing "live task" notion used elsewhere); if any and not `--force`, `output.error(...)` naming the blocking task(s) + `--force`, and `raise typer.Exit(1)`. Mirror the phrasing/structure of existing `item` subcommands and `spec archive`.
- [ ] **Step 3: Green + commit.** `mship test`; journal.
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: serve `GET /items` archived filter + Ground Control view hides archived

**Files:** Modify `src/mship/core/serve.py` (~:619-691), `src/mship/view/workitem_index.py`; Test `tests/core/test_serve*.py` (items endpoint) + `tests/**/test_workitem_index*.py`.

- [ ] **Step 1: Failing tests.** (a) `GET /items` excludes archived items by default and includes them with a query flag (e.g. `?include_archived=true` / `?all=true`); `GET /items/{id}` still returns an archived item directly (direct fetch is not filtered); (b) the workitem index/view omits archived items from its default listing.
- [ ] **Step 2: Implement.** Thread the store's `include_archived` through `GET /items` (default excludes; query param includes). In `view/workitem_index.py`, filter archived items out of the default index (consistent with the CLI/serve default). Keep `GET /items/{id}` unfiltered.
- [ ] **Step 3: Green + commit.** `mship test`; journal.
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: spec dispatch — WorkItem-join adopt + refuse-to-guess

**Files:** Modify `src/mship/core/spec_dispatch.py` (the ladder ~:104-150), `src/mship/cli/spec.py` (messaging); Test `tests/core/test_spec_dispatch.py` (+ CLI test if present).

- [ ] **Step 1: Failing tests** (table-style over the ladder):
  - **WorkItem-join adopt:** spec has `work_item_id` set, and that WorkItem's `task_slugs` contains exactly ONE existing NON-closed task (slug ≠ spec.id, not otherwise bound) → dispatch ADOPTS that task (binds spec to it, no new task spawned, no new WorkItem minted).
  - **Refuse-to-guess:** spec is unbound (no `--task`, no `spec.task_slug`, `slug != spec.id`) and cannot uniquely resolve a task, but candidate non-closed task(s) plausibly belong (e.g. the spec's WorkItem lists ≥1 non-closed task but not exactly one uniquely-adoptable, or ≥2 candidates) → dispatch REFUSES: non-zero exit, actionable message naming `--task <slug>` (or `item link-task`), and spawns NO task + mints NO WorkItem. Assert state is unchanged.
  - **Closed-only doesn't block:** the spec's WorkItem `task_slugs` contains only CLOSED tasks → dispatch proceeds normally (auto-spawns), since adopt/ambiguity counts only non-closed tasks.
  - **Preserved paths unchanged:** explicit `--task <slug>`; already-bound `spec.task_slug`; `slug == spec.id` auto-adopt — all still behave as today.
- [ ] **Step 2: Implement.** In `dispatch_spec` (`core/spec_dispatch.py`), before the `else: auto-spawn` branch (~:129), insert a WorkItem-join step: if `spec.work_item_id`, look up its WorkItem's `task_slugs`, filter to tasks present in `state.tasks` and non-closed; if exactly one → adopt it (set as chosen task, `spawned=False`); if more than one, or if the join yields none but the resolution is otherwise ambiguous → raise/return a clear refuse-to-guess error (do NOT reach `spawn_fn` and do NOT mint a WorkItem). Only fall through to auto-spawn when there is genuinely nothing to adopt and no ambiguity. Reuse the existing WorkItem store passed into `dispatch_spec` (the `workitems` param added by MOS-213). Keep the existing branches (:110 `--task`, :123 bound, :126 slug==id) intact and ordered before the new join. Surface the refuse message through `cli/spec.py` as a clean CLI error (non-zero exit), not a traceback. `core/workitem_migrate.py:53-71` (`wrap_existing` pass 2) is a reference for the spec_id/task_slug join shape.
- [ ] **Step 3: Green + commit.** `mship test`; journal.
<!-- /mship:task -->

---

## Self-review
- Spec ACs → tasks: adopt-via-join (T4), refuse-to-guess (T4), closed-only-not-blocking (T4), preserved paths (T4), archive hides from list/GET (T1/T2/T3), archive live-task guard + --force (T2), unarchive (T1/T2), close leaves slug (no code change — verify existing behavior in T4's regression note / covered by "close unchanged"), backward-compat load (T1). All covered.
- `mship close` is intentionally NOT modified (operator decision: keep closed tasks as record). No task touches `cli/worktree.py` close.
- Non-goals respected: no hard delete; no fuzzy matching; no gate changes.
