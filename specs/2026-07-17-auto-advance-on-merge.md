---
id: auto-advance-on-merge
title: Auto-advance on PR merge (no manual close) + safe worktree teardown guard
status: implemented
created_at: '2026-07-17T10:05:59.647993Z'
updated_at: '2026-07-17T11:46:52.736929Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: When a task's PR(s) merge, the serve merge-watcher auto-advances the bound
    spec (dispatched -> implemented) and the WorkItem (-> done, or review-cleared)
    with no manual 'mship close' - verified by the WorkItem reaching 'done' and its
    needs_review attention clearing after a simulated merge.
  verdict: approved
  evidence:
  - kind: commit
    ref: e5b45a74cbe610d2f2238f8104bd2df746723854
    note: pr_watcher._auto_close_on_merge advances spec+WorkItem on merge
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac2
  text: 'The merge-driven auto-close runs non-interactively and fail-open: a failure
    (gh unavailable, PR-state error, etc.) is logged and never crashes the watcher
    or the serve process.'
  verdict: approved
  evidence:
  - kind: commit
    ref: 181c4607302ed14dfcaceb061dff7dfdfdd2eb76
    note: fail-open regression lock (event still posts)
  comment: null
- id: ac3
  text: 'The dirty/unpushed guard lives in the core teardown primitive (WorktreeManager.abort),
    so EVERY teardown path enforces it: the new merge auto-close, manual ''mship close'',
    and ''mship close --abandon''. Each affected repo''s worktree is checked for uncommitted
    changes AND unpushed commits; if any repo is dirty or unpushed, the teardown is
    refused/skipped for the whole task unless --force is passed.'
  verdict: approved
  evidence:
  - kind: commit
    ref: 9ef66275ae2f1c4633ba63011c311c2ccf193943
    note: guard in WorktreeManager.abort (universal, all teardown paths)
  - kind: commit
    ref: 8b608f2cd4a75fb36893d5687b4a7ecaacbc3d3f
    note: has_unpushed_commits detection
  comment: null
- id: ac4
  text: When teardown is skipped for dirty/unpushed work (no --force), the worktree
    is left intact (the silent force shutil.rmtree fallback is removed, so it can
    never be deleted without --force), and on the merge path the phase/spec still
    advances and a note is posted telling the operator to resolve then close (or --force).
  verdict: approved
  evidence:
  - kind: commit
    ref: c87b3676277eb16956715cd84036ec369e65eecf
    note: skip-note + rmtree fallback removed; worktree left intact
  comment: null
- id: ac5
  text: An explicit --force on a teardown command bypasses the dirty/unpushed guard
    and removes the worktree (the deliberate 'yes, discard it' path).
  verdict: approved
  evidence:
  - kind: commit
    ref: 1233a2afe206f5c36046e6764255dfa872271b42
    note: close threads --force to bypass the guard
  comment: null
- id: ac6
  text: A clean worktree (no uncommitted changes, no unpushed commits) is torn down
    on merge, so the common case reaches fully-done with zero manual steps.
  verdict: approved
  evidence:
  - kind: commit
    ref: e5b45a74cbe610d2f2238f8104bd2df746723854
    note: clean worktree torn down on merge
  comment: null
- id: ac7
  text: 'The auto-advance is idempotent: a repeated or duplicate merge signal does
    not double-advance the spec/WorkItem or raise an error.'
  verdict: approved
  evidence:
  - kind: commit
    ref: 181c4607302ed14dfcaceb061dff7dfdfdd2eb76
    note: idempotency-across-sweeps + partial-multipr locks
  comment: null
- id: ac8
  text: The skills finishing-a-development-branch and working-with-mothership are
    updated to reflect merge auto-advance and that 'mship close' is only needed to
    force teardown of a dirty/unpushed worktree.
  verdict: approved
  evidence:
  - kind: commit
    ref: bafd2f3a5d34e4a7604b21698eac61418337ed30
    note: skills updated (finishing-a-development-branch + working-with-mothership)
  comment: null
open_questions: []
non_goals:
- Clearing needs-you / needs_decision on merge - that's a separate axis that clears
  when the operator replies to the thread, by design.
- The Ground Control 'tapping a thread from Home doesn't mark it read' bug - that
  ships as its own small GC navigation fix.
- Changing the task-level phase machine (plan/dev/review/run) - this is about the
  WorkItem/spec projection and the close/teardown flow.
risks:
- The watcher runs inside the serve process; the auto-close must be non-interactive
  (no TTY confirm prompt), handle gh/PR-state checks gracefully, and fail-open (log,
  never crash the watcher or serve).
- 'Auto-teardown could delete a worktree the operator wanted to inspect - mitigated:
  only clean worktrees are torn down; dirty/unpushed ones are kept with a note.'
- Double-fire idempotency - advance is already idempotent; teardown must no-op if
  the worktrees are already gone.
task_slug: auto-advance-on-merge
work_item_id: wi-20260717101626-f9da5693
clarification_reason: null
prose_verdicts:
  problem:
    verdict: approved
    comment: null
  user_story:
    verdict: approved
    comment: null
  approach:
    verdict: approved
    comment: null
  non_goals:
    verdict: approved
    comment: null
  risks:
    verdict: approved
    comment: null
---
## Problem

Specs and WorkItems get stuck: a spec sits at 'dispatched' and its WorkItem at 'in_flight'/'review' with the needs-review attention flag lit long after the PR merged. Root cause: the WorkItem phase and attention flags are pure live projections of spec.status / task.pr_urls / finished_at, and the only thing that changes those inputs (advance_spec_on_close + advance_workitem_on_close, plus worktree teardown) runs only on a MANUAL 'mship close'. The PR-merge watcher today just posts a 'ready to close out' event; it advances nothing. So every merged item needs a manual close to reach 'done' and clear its attention. Separately, 'mship close' teardown can LOSE work: 'git worktree remove' refuses a dirty tree but the code falls back to a force rmtree that deletes uncommitted changes, and unpushed commits are never checked.

## User story

As the operator, when my PR merges I want the spec/WorkItem to auto-advance to done and its review attention to clear with zero manual steps, while never losing uncommitted or unpushed work in the worktree.

## Approach

Two coupled parts, mothership-only. (1) Auto-advance on merge: the serve PR-watcher already detects the merge and posts the event; extend it to auto-run the close flow for that task non-interactively and WITHOUT --abandon — advance_spec_on_close (spec dispatched -> implemented) + advance_workitem_on_close (WorkItem -> done / review-cleared), then the worktree teardown. Because compute_phase and compute_attention are pure projections of that state, this clears both the stuck phase and the lingering needs-review flag in one move. It must be fail-open (a gh/PR-state/error never crashes the watcher) and idempotent (advance_*_on_close already no-op on non-dispatched/terminal specs; a repeated merge signal must not double-advance). (2) Safe teardown guard baked into the CORE teardown primitive so EVERY teardown path respects it (not just the merge path): put the guard inside WorktreeManager.abort (the primitive that merge-auto-close, manual 'mship close', and 'mship close --abandon' all call). Before removing a task's worktrees, check every affected repo's worktree for uncommitted changes (git status --porcelain non-empty) AND unpushed commits (commits ahead of the tracked upstream). If ANY repo is dirty or unpushed, refuse/skip the teardown for the whole task unless an explicit --force is passed. On the merge-auto-close path a skipped teardown STILL advances the phase/spec (safe, reversible), leaves the worktree intact, and posts a note ('worktree has uncommitted/unpushed changes; resolve, then run mship close [--force]'). Remove the current silent force shutil.rmtree fallback entirely so a dirty worktree is never deleted without --force. Skills update: 'mship close' becomes optional (merge auto-advances); update finishing-a-development-branch and working-with-mothership to say merge auto-advances and close is only needed to force teardown of a dirty/unpushed worktree.

## Architecture

compute_phase (view/workitem_index.py) and compute_attention are LIVE read-time projections of spec.status / task.pr_urls / task.finished_at - nothing is stored, so nothing is truly 'stuck'; the projection just never reaches done/review-cleared because the inputs never change pre-close. The fix moves those inputs at the MERGE event via the existing advance_spec_on_close (core/spec_lifecycle.py) + advance_workitem_on_close (core/workitem_lifecycle.py), which are today only called from cli/worktree.py close. Wire them (and the guarded teardown) into the serve PR-watcher (core/relay/pr_watcher.py or wherever the merge is detected + the event posted). The dirty/unpushed guard lives INSIDE WorktreeManager.abort (core/worktree.py:726) - the single primitive every teardown path calls (merge auto-close, cli close, cli close --abandon) - so the safety is enforced once, universally, and takes a force flag to bypass. abort currently git-worktree-removes then force-rmtrees on failure, which is the exact data-loss gap; the fallback is removed and replaced by the guard (refuse unless force). The merge signal carries merged_count/closed_count (the offline Task has no merged flag), so reuse the watcher's PR-state result. Note the CLI --force/--abandon plumbing must thread force down to abort.

## Testing

Unit-test: a merged-PR signal advances the bound spec dispatched->implemented and the WorkItem to done, and the resulting compute_attention has needs_review cleared. The dirty guard: a worktree with uncommitted changes (or unpushed commits) is NOT torn down, the phase still advances, and a note is posted; a clean worktree IS torn down. Idempotency: firing the merge advance twice leaves a single implemented spec and no error. Fail-open: a raised error in the merge handler is logged and does not propagate. Manual 'mship close' on a dirty worktree now refuses/skips teardown instead of force-deleting.
