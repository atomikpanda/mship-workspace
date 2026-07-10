---
id: guard-against-editing-a-repos-main
title: Guard against editing a repo's main checkout while a task is active
status: implemented
created_at: '2026-06-30T00:54:28.892307Z'
updated_at: '2026-06-30T02:19:09.843105Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: An Edit/Write/MultiEdit/NotebookEdit whose resolved path is inside a repo's
    main checkout while that repo has an active task is blocked, and the deny reason
    names the correct worktree path to use instead.
  verdict: unreviewed
- id: ac2
  text: The same edit issued via the `mothership/` symlink AND via the main checkout's
    direct absolute path are both blocked (realpath canonicalization).
  verdict: unreviewed
- id: ac3
  text: Edits inside the task's worktree, edits to a repo with no active task, and
    edits to non-repo workspace files (e.g. specs/, .claude/) are allowed.
  verdict: unreviewed
- id: ac4
  text: The guard fails open (allows) when run outside a workspace, when state is
    unreadable, on malformed/missing event input, and when MSHIP_ALLOW_MAIN_EDIT=1
    is set.
  verdict: unreviewed
- id: ac5
  text: '`mship init --install-hooks` installs the PreToolUse guard into .claude/settings.json
    idempotently, preserving any existing hooks and tolerating a malformed/empty settings
    file.'
  verdict: unreviewed
- id: ac6
  text: A repo with an active task that has tracked changes in its MAIN checkout produces
    a blocking audit error (surfaced by `mship audit` and the spawn/finish gate);
    an untracked-only main checkout stays a warning.
  verdict: unreviewed
open_questions:
- id: q1
  text: Does the `mship finish` audit gate inspect each repo's main checkout, or only
    the task worktrees? If only worktrees, the new backstop check must be routed so
    that both `spawn` and a pre-finish check catch a main-checkout edit made AFTER
    spawn.
  answer: each
non_goals:
- "Codex/Gemini PreToolUse hook installation \u2014 their hook mechanisms differ;\
  \ the audit backstop covers those harnesses generically."
- Spawn-banner / `mship cd <task>` ergonomics for steering the user to the worktree
  (separate, lower-value polish).
- "Blocking read-only tools or non-edit operations \u2014 only the four edit tools\
  \ are guarded."
- A faster per-edit entrypoint that avoids full mship startup (revisit only if the
  ~150ms cost proves noticeable).
risks:
- Per-edit mship startup (~150ms) is paid on every edit while a task is active; acceptable
  for now but worth measuring.
- False positives would be very disruptive (blocking legitimate edits), so the guard
  MUST fail open on any uncertainty and only block on a confident main-checkout-with-active-task
  positive.
- 'Symlink vs realpath mismatch: the configured repo path and the edit path must both
  be realpath-canonicalized or the symlinked main checkout would slip through.'
- git_root subdir repos (a repo whose path is a subdirectory of another repo's git
  root) must resolve their main-checkout boundary correctly so edits aren't mis-attributed.
task_slug: guard-against-editing-a-repos-main
work_item_id: wi-20260702110439-3fc1b26e
---
## Problem

In a mothership workspace a member repo's main checkout is reachable both by its configured path and, in this workspace, through the `mothership/` symlink. After `mship spawn`, an agent that derives file paths from the main checkout (via the symlink or its absolute path) edits the MAIN checkout — which sits on `main` — instead of the task's worktree on the feature branch. mship's only guard is the git pre-commit hook, which fires at `git commit` time; but Read/Edit/Write tools bypass git entirely, so the misdirected edit lands silently, the feature branch stays empty, and tests can even go falsely green because the test runner reads the unmodified worktree. The failure is invisible until much later.

## User story

As an agent (or human) working a mship task, I want my edit tool to refuse edits that would land in a repo's main checkout while that repo has an active task, so that work always lands on the task's feature branch instead of silently polluting `main`.

## Approach

Intercept at the layer where the failure happens (the agent's edit tool) and add a harness-agnostic backstop in audit.

1. New pure module `src/mship/core/edit_guard.py`: `evaluate_edit(target_path, state, config) -> GuardDecision`. realpath the target; for each repo R, BLOCK iff the target is inside R's main checkout AND some active task has R in `affected_repos` AND the target is NOT inside that task's `worktrees[R]`; otherwise ALLOW. Pure and trivially unit-testable (mirrors the pure-builder style of `dispatch.py`).

2. Hidden CLI command `mship _guard-edit` in `src/mship/cli/internal.py` (mirrors `_check-push`, which already reads stdin): read the Claude Code PreToolUse event JSON from stdin, extract `tool_input.file_path` (and `notebook_path` for NotebookEdit), `get_container(required=False)`, call `evaluate_edit`, and either emit Claude's deny-decision JSON or exit 0. Honor `MSHIP_ALLOW_MAIN_EDIT=1` as a bypass. Fail open on ANY exception (malformed JSON, missing fields, unreadable state, no workspace, no active task).

3. `install_pretooluse_guard_hook(workspace_root)` in `src/mship/core/claude_settings.py`, mirroring `install_session_hook`: idempotent deep-merge into `.claude/settings.json` under `hooks.PreToolUse` with matcher `"Edit|Write|MultiEdit|NotebookEdit"` and command `mship _guard-edit`, deduped by command string. Wire it into the existing `mship init --install-hooks` path (and the normal init flow) alongside the SessionStart installer.

4. Audit backstop in `src/mship/core/repo_state.py`: when a repo with an active task has TRACKED changes in its MAIN checkout, emit a blocking (`error`) `Issue` with an active-task-aware message (e.g. "uncommitted tracked changes in main checkout while task <slug> is active — did you mean the worktree?"). `error` severity auto-wires into the spawn/finish gate via `run_audit_gate`. Untracked-only changes stay a `warn`.

Deny message example: "Editing the MAIN checkout of 'mothership' while task 'dispatch-implementer-mode' is active. Edit here instead: .worktrees/dispatch-implementer-mode/mothership/<relpath>. (MSHIP_ALLOW_MAIN_EDIT=1 to override.)"

## Architecture

Decision lives in a pure core module (`edit_guard.py`); the CLI command (`internal.py`) is a thin stdin/JSON adapter; the installer (`claude_settings.py`) and the audit probe (`repo_state.py`) are independent edges. Reused machinery: hidden-command + stdin pattern (`_check-push`, internal.py:218-270); `install_session_hook` deep-merge (claude_settings.py:11-48); state via `container.state_manager().load()` (`Task.worktrees`, `Task.affected_repos`); repo main paths via `container.config().repos[R].path`; `collect_known_worktree_paths` (audit_gate.py:91-98); tracked-vs-untracked split in `_probe_dirty` (repo_state.py:241-278) and the `run_audit_gate` bridge (audit_gate.py:14-55).

## Testing

Pure `evaluate_edit` unit tests: main-checkout edit with active task -> block; worktree edit -> allow; main-checkout edit with NO active task -> allow; symlinked main path -> block (realpath); workspace non-repo file (specs/, .claude/) -> allow; git_root subdir repo resolves correctly. `_guard-edit` CLI tests: stdin JSON parse, deny-decision JSON shape, fail-open on malformed JSON / no workspace / no task, MSHIP_ALLOW_MAIN_EDIT override. Installer tests: fresh settings.json, idempotent re-install, preserves existing hooks, tolerates malformed settings (mirror existing claude_settings tests). Audit tests: active-task repo with tracked-dirty main -> blocking error; clean main -> none; untracked-only -> still warn; no active task -> no new issue.
