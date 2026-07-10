---
id: mship-spawndispatch
title: 'mship spawn/dispatch: fetch + fast-forward the base branch before cutting
  a worktree'
status: implemented
created_at: '2026-06-22T20:45:37.210208Z'
updated_at: '2026-06-22T21:27:38.458904Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: WorktreeManager.spawn() fetches each affected repo's base branch (origin)
    and cuts the new feat/<slug> worktree from origin/<base> (the fetched tip) rather
    than the canonical checkout's current HEAD; util/git.py worktree_add accepts an
    optional start-point and defaults to current HEAD when none is given.
  verdict: unreviewed
- id: ac2
  text: 'Both `mship spawn` and `mship spec dispatch` auto-spawn go through this path,
    so a task dispatched/spawned immediately after a base-branch merge starts on the
    latest pushed base (verified: a deliberately-behind local base yields a worktree
    at origin''s tip).'
  verdict: unreviewed
- id: ac3
  text: When the canonical checkout's local base branch is clean and strictly behind
    origin, spawn fast-forwards it to origin/<base>; when it is dirty or diverged,
    spawn leaves it untouched and proceeds (the worktree is still cut from origin/<base>).
  verdict: unreviewed
- id: ac4
  text: "If the fetch fails (offline, no remote, auth/timeout) or there is no origin/<base>\
    \ ref, spawn logs a warning and falls back to cutting the worktree from the local\
    \ base \u2014 it never blocks or errors out on a fetch failure."
  verdict: unreviewed
- id: ac5
  text: An opt-out (`mship spawn --no-fetch-base`, plus an equivalent workspace-config
    toggle) skips the fetch/ff entirely and preserves the prior local-base behavior.
  verdict: unreviewed
- id: ac6
  text: 'Tests (real temp git repos, matching tests/core/test_worktree.py''s GitRunner
    + workspace_with_git style): (a) origin pushed ahead of a behind local base ->
    spawned worktree branch is at origin''s tip; (b) clean-behind local base is fast-forwarded;
    dirty/diverged local base is left untouched; (c) fetch failure / no remote still
    spawns from the local base with a warning and non-zero issues are not raised;
    (d) --no-fetch-base skips fetching. All green via `uv run mship` / the repo''s
    test target.'
  verdict: unreviewed
open_questions: []
non_goals:
- Changing how the base branch is RESOLVED (still RepoConfig.base_branch / workspace
  default / 'main')
- "Replacing or duplicating `mship sync`, `mship reconcile`, or the audit drift checks\
  \ \u2014 this is complementary, narrowly about the spawn-time base"
- Making `mship spec dispatch` run the full CLI audit gate (separate concern; the
  chokepoint fix removes the need to rely on that gate for base freshness)
- Rebasing or fast-forwarding EXISTING task branches (this only affects newly created
  worktrees)
- 'Any network requirement: offline / no-remote / local-only repos must still spawn'
risks:
- "Fetch can fail (offline, no remote configured, auth/timeout) \u2014 spawn MUST\
  \ degrade gracefully: warn and fall back to cutting from the local base (today's\
  \ behavior), never block spawn. This must be tested."
- A repo with no `origin/<base>` ref (brand-new/local-only) must fall back to the
  local base without error.
- "The opportunistic local-base fast-forward must be skipped when the canonical checkout\
  \ is dirty or diverged (not strictly behind) \u2014 never reset or force; just warn\
  \ and proceed (the worktree is still cut from origin/<base>, so correctness does\
  \ not depend on the local ff succeeding)."
- Fetching per repo at spawn adds latency; keep it a single fetch of the base ref
  per affected repo and allow opt-out (--no-fetch-base / config) for deterministic
  or offline-by-choice spawns.
- The installed `mship` binary can lag the dev source in this workspace (doctor 'dev_mode'
  warning); verify the change with `uv run mship` from the workspace root, not the
  stale installed binary.
task_slug: mship-spawndispatch
work_item_id: wi-20260702110439-6f4d74f9
---
## Problem

When mship creates a task worktree it runs `git worktree add <path> -b feat/<slug>` with no base ref (util/git.py worktree_add), so the new branch is cut from the canonical checkout's current HEAD — i.e. local `<base_branch>` at whatever staleness it happens to be. Right after a PR merges on GitHub, local `main` is typically behind `origin/main` (merges happen server-side; `mship close` cleans the worktree but does not pull the base). `mship spawn` runs an audit gate that fetches and would flag `behind_remote`, but `mship spec dispatch`'s auto-spawn calls `WorktreeManager.spawn()` directly and bypasses that CLI gate — so a task dispatched immediately after a merge is born on a stale base, missing just-merged work, with no warning. This actually happened: a task was spawned one commit behind origin and had to be manually rebased.

## User story

As an operator dispatching a task right after merging another PR, I want the new worktree to start from the latest pushed base branch automatically, so that I never silently build on a stale base or have to hand-rebase a freshly spawned task.

## Approach

Fix at the shared chokepoint `WorktreeManager.spawn()` so BOTH `mship spawn` (CLI) and `mship spec dispatch` auto-spawn (core/spec_dispatch -> serve _serve_spawn -> worktree_manager.spawn) are covered by one change. Before the worktree-creation loop, for each affected (non-passive) repo resolve its base branch (RepoConfig.base_branch or the workspace default, falling back to 'main') and: (1) best-effort `git fetch origin <base>` on the canonical checkout; (2) cut the worktree from the fetched remote tip by passing an explicit start point to worktree_add — `git worktree add <path> -b feat/<slug> origin/<base>` — so the task starts on the latest pushed base regardless of local main's state; (3) opportunistically fast-forward the canonical local `<base>` to `origin/<base>` when it is clean and strictly behind (reusing the ff-only semantics that `mship sync` already implements in core/repo_sync.py), keeping the local checkout current as a side benefit. The change threads an optional base start-point through `worktree_add` (defaulting to current HEAD when none is given, preserving existing behavior). Base-branch resolution and worktree paths are unchanged.

## Implementation notes

Chokepoint: `WorktreeManager.spawn()` in core/worktree.py — insert a 'freshen base' pass after repo-list/dependency resolution and before the per-repo worktree-creation loop (so all worktrees are cut from fresh bases). `util/git.py` `worktree_add(repo_path, worktree_path, branch, start_point: str | None = None)` — when start_point is given, append it to the `git worktree add ... -b <branch> <start_point>` invocation; when None, keep the current behavior. Reuse existing helpers/patterns rather than re-rolling git plumbing: core/pr.py `fetch_remote_branch(repo_path, base)` already does best-effort `git fetch origin <base>`; core/repo_sync.py implements ff-only semantics; core/repo_state.py shows the ahead/behind check (`git rev-list --count HEAD..@{u}`) and clean detection. Per-repo base resolution: `RepoConfig.base_branch or workspace_default_branch_from_config(config) or 'main'`. Both spawn and dispatch reach this method (serve.py _serve_spawn and spec_dispatch.dispatch_spec call worktree_manager.spawn()), so no change is needed in the dispatch path itself.
