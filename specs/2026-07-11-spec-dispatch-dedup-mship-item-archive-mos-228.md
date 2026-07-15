---
id: spec-dispatch-dedup-mship-item-archive-mos-228
title: spec dispatch dedup + mship item archive (MOS-228)
status: implemented
created_at: '2026-07-11T12:26:47.478792Z'
updated_at: '2026-07-11T14:15:00.868922Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: '`spec dispatch` adopts a WorkItem-linked existing non-closed task (via spec.work_item_id
    -> task_slugs) instead of spawning a duplicate.'
  verdict: approved
- id: ac2
  text: '`spec dispatch`, when it cannot unambiguously resolve a task and unbound
    non-closed candidate(s) exist, refuses with an actionable message naming --task
    and spawns no task and mints no WorkItem.'
  verdict: approved
- id: ac3
  text: A WorkItem whose task_slugs contains only closed tasks does not block a fresh
    dispatch (closed tasks are ignored by the adopt/ambiguity logic).
  verdict: approved
- id: ac4
  text: 'Existing adopt paths are unchanged: explicit --task, already-bound spec.task_slug,
    and slug == spec.id all still work.'
  verdict: approved
- id: ac5
  text: '`mship item archive <id>` marks the item archived; archived items are hidden
    from `item list` and `GET /items` by default and shown with --all.'
  verdict: approved
- id: ac6
  text: '`mship item archive <id>` blocks when a non-closed task references the item
    (task.work_item_id == id); --force overrides.'
  verdict: approved
- id: ac7
  text: '`mship item unarchive <id>` restores an archived item to the default listing.'
  verdict: approved
- id: ac8
  text: '`mship close` leaves the closed task''s slug in its WorkItem''s task_slugs
    (history preserved); no delinking occurs.'
  verdict: approved
- id: ac9
  text: Existing WorkItem JSON files without an `archived` field still load (default
    false).
  verdict: approved
- id: ac10
  text: Unit tests cover each behavior above and the full suite stays green.
  verdict: approved
open_questions: []
non_goals:
- 'Hard delete of WorkItems (archive-only per decision: soft and reversible).'
- "Fuzzy title/intent matching for adopt \u2014 dedup uses the WorkItem-graph join\
  \ only, no heuristic guessing."
- "Delinking closed tasks from their WorkItem \u2014 closed tasks remain in task_slugs\
  \ as historical record (operator decision)."
- Changing spec lifecycle or the enforcement/spec gate itself.
risks:
- Refuse-to-guess could nag if its trigger is too broad; mitigate by triggering only
  when the spec's WorkItem graph yields ambiguous/multiple non-closed candidates rather
  than on any pre-existing task.
- '`archived` is a new field on the WorkItem model; must default to false and load
  cleanly for existing `.mothership/workitems/*.json` (backward-compatible deserialization).'
- Adopt/ambiguity logic must consistently exclude closed tasks when counting WorkItem.task_slugs
  candidates, so retained history never causes a false 'ambiguous' refusal or a wrong
  adoption.
task_slug: spec-dispatch-dedup-mship-item-archive-mos-228
work_item_id: wi-20260711125556-abb5f028
---
## Problem

`mship spec dispatch <id>` silently duplicates work. Its adopt logic only reuses an existing task when the task's slug == spec.id (or via explicit --task, or an already-bound spec.task_slug). A task pre-spawned with a custom slug — the documented `item new` -> `spawn --work-item` -> `spec dispatch` path — is never adopted, so dispatch auto-spawns a second task and (since MOS-213) mints a second WorkItem. The WorkItem, the natural join key between a spec and its task, is never consulted, so even a correctly-linked flow (`item link-spec` before spawn) still double-spawns. Separately, there is no command to remove an orphaned WorkItem (`item` has no delete/archive), so orphans created by this bug are permanent and clutter `item list`.

## User story

As a mship operator, I want `spec dispatch` to reuse the task I already spawned for a piece of work instead of duplicating it, and a safe way to remove a WorkItem created in error, so that one piece of work maps to exactly one task + WorkItem and mistakes are recoverable.

## Approach

Part 1 — spec dispatch dedup (core/spec_dispatch.py, cli/spec.py): extend the adopt ladder to consult the WorkItem join — when spec.work_item_id is set and that WorkItem's task_slugs contains exactly one existing NON-closed task, adopt it instead of auto-spawning. Before auto-spawning a brand-new task, if the spec is unbound, has no adoptable WorkItem-linked task, and resolution is ambiguous (the spec's WorkItem lists candidate non-closed task(s) that don't uniquely resolve), refuse to guess: emit an actionable error naming --task <slug> (or `item link-task`) and spawn/mint nothing. Preserve the existing explicit paths unchanged (--task, already-bound spec.task_slug, slug == spec.id). Note: closed tasks in a WorkItem's task_slugs are retained as historical record and are simply ignored by the adopt/ambiguity logic (which counts only non-closed tasks). Part 2 — item archive (core/workitem.py, core/workitem_store.py, cli/workitem.py, core/serve.py, view/workitem_index.py): add `mship item archive <id>` as a soft, reversible archive (mirrors `spec archive`), persisting an `archived` flag on the WorkItem; archived items are excluded from `item list` and `GET /items` by default and shown via --all; archive refuses when a non-closed task still references the item (task.work_item_id == id) unless --force is given (protects the enforcement gate from stranding a live task); add `mship item unarchive <id>` to reverse it. `mship close` is intentionally left unchanged: closing a task keeps its slug in the WorkItem's task_slugs as history (every reader already tolerates references to non-live tasks by filtering), and orphan removal is handled by archive, not by delinking.

## Root cause (corrected)

This is NOT a regression of MOS-213. The duplicate-task behavior has been latent since MOS-181 introduced the adopt ladder with match key slug == spec.id — a task pre-spawned with a custom slug was never adoptable. MOS-213 (WorkItem linking) only added the second-WorkItem mint on top of the pre-existing double-task; its diff to core/spec_dispatch.py did not touch the spawn-vs-adopt ladder. The deeper gap is that the WorkItem — the natural join key — is never consulted by the ladder, so even the correctly-linked `item link-spec` -> spawn -> dispatch flow double-spawns.

## Reference graph and archive guards

A WorkItem is referenced by: Task.work_item_id (reverse), WorkItem.task_slugs/thread_ids/spec_id (forward), Spec.work_item_id, threads, the enforcement gate (workitem_gate: a task whose work_item_id points at a missing item is blocked from dev/finish), pr_watcher, the unattended runner, and the Ground Control workitem view. Forward references to non-live tasks (e.g. closed tasks retained as history) are already tolerated by every reader (they filter by live tasks), which is exactly why `mship close` can safely leave the slug in place. The one hard hazard is the reverse link: archiving an item that a LIVE task still points at would strand that task behind the gate — hence the archive guard (refuse unless --force). Soft archive (a flag, list/GET filtering) avoids all dangling-reference breakage that a hard delete would cause and mirrors the existing `spec archive` terminal-status precedent.

## Testing

Part 1: table-style tests over the adopt ladder — WorkItem-join adopt (single linked non-closed task), refuse-to-guess (ambiguous/multiple non-closed candidates, unbound, no --task) asserting no task spawned and no WorkItem minted, closed-only task_slugs does not block a fresh dispatch, and the three preserved explicit paths. Part 2: item archive hides from list/GET, --all reveals; archive blocked by a live task and allowed with --force; unarchive restores; backward-compatible load of an archived-less JSON file. Regression: `mship close` still leaves the task slug in the WorkItem.
