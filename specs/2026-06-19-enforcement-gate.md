---
id: enforcement-gate
title: 'Enforcement gate for untasked work: reliable hooks, pre-push, session-start
  injection'
status: dispatched
created_at: '2026-06-19T01:44:14.329764Z'
updated_at: '2026-06-19T01:47:32.269119Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: Git hook bodies resolve mship reliably (install-time absolute path + PATH
    fallback); enforcing hooks (pre-commit, pre-push) fail closed (exit 1, message
    names MSHIP_BYPASS_GATE) when mship is unresolvable, while advisory hooks (post-checkout,
    post-commit) keep their no-op `|| true`.
  verdict: approved
- id: ac2
  text: The existing `_check-commit` untasked src/tests rejection still holds (regression
    test) and now fires reliably because resolution no longer silently no-ops.
  verdict: approved
- id: ac3
  text: A `pre-push` hook is in the inventory; `mship _check-push` rejects a branch-pattern
    branch that is not a registered task branch, allows registered task branches and
    non-pattern branches (main), and ignores branch deletes (all-zero sha).
  verdict: approved
- id: ac4
  text: MSHIP_BYPASS_GATE (set to `1` or a reason string) makes `_check-commit` and
    `_check-push` allow the operation and append a record {ts, op, branch, reason,
    cwd} to <workspace>/.mothership/bypass-log.jsonl.
  verdict: approved
- id: ac5
  text: '`mship _session-context` prints the no-active-task notice when cwd is a workspace
    with no active task, and prints nothing when a task is active or cwd is not a
    workspace.'
  verdict: approved
- id: ac6
  text: '`mship init --install-hooks` installs a SessionStart hook into the workspace
    `.claude/settings.json` idempotently, preserving any pre-existing hooks.'
  verdict: approved
open_questions: []
non_goals:
- "codex/gemini session-start hooks \u2014 Claude-only in v1; their hook mechanisms\
  \ differ."
- "UserPromptSubmit per-turn injection \u2014 SessionStart only this round."
- Changing or removing git's native `--no-verify` (the unlogged escape stays).
- "A required-reason policy for bypass \u2014 the reason is optional; the bypass itself\
  \ is always logged."
- Gating non-pattern branches, or commits/pushes outside a mship workspace.
risks:
- Fail-closed on enforcing hooks blocks all commits/pushes in a managed repo if mship
  is genuinely uninstalled and off PATH; mitigated by the install-time baked path
  + PATH fallback (mship was present at install) and the named MSHIP_BYPASS_GATE escape.
- Editing the user's `.claude/settings.json` could clobber existing hooks; mitigated
  by an idempotent, marker-keyed merge that preserves other entries and no-ops on
  re-install.
- pre-push ref parsing from stdin must handle deletes (zero sha) and multiple refs;
  mitigated by explicit handling + tests.
- Claude Code may run the SessionStart hook with a PATH lacking ~/.local/bin; the
  notice is advisory (not fail-closed), so a miss degrades gracefully to today's behavior.
task_slug: enforcement-gate
work_item_id: wi-20260702110439-c0dc398e
---
## Problem

mship's pre-commit hook only enforces WHERE a commit lands once a task is already active; nothing forces a task to exist in the first place. Worse, every hook body guards with `command -v mship`, which returns not-found under a sanitized hook PATH, so the hook silently no-ops. Concrete evidence: an untasked commit landed 36 minutes before its task was created — the existing untasked-work commit gate did not fire because the PATH lookup failed. Soft signals (skills, CLAUDE.md prose) get rationalized past; the robust moves are to front-load context so the spawn decision is made correctly, and to put hard deterministic gates at unavoidable chokepoints with an explicit, logged escape hatch.

## User story

As an operator relying on mship's worktree discipline, I want deterministic gates that make untasked feature work hard to commit or push and that remind the agent to spawn a task at session start, so that work can't silently bypass the task workflow the way it does today when the hook no-ops.

## Approach

Key finding: the untasked-work commit gate ALREADY EXISTS (`_check-commit` refuses commits when no task is active and staged paths are under src/ or tests/); it is neutered by the PATH bug, so reliable mship resolution (#4) is the foundational unlock, not just a latent bug. v1 ships four pieces. (#4) Harden the git hook bodies: replace `command -v mship` with reliable resolution (an install-time absolute mship path baked at install, plus a PATH fallback); ENFORCING hooks (pre-commit, pre-push) fail closed (exit 1 with a message naming MSHIP_BYPASS_GATE) when mship can't be resolved, while advisory hooks (post-checkout, post-commit) keep their `|| true` no-op. (#2) Add a new pre-push hook to the inventory whose body pipes the pushed refs from stdin into a new hidden `mship _check-push`, which rejects any local branch matching the workspace branch_pattern (e.g. feat/*) that is not a registered task branch in state, while allowing registered task branches, non-pattern branches (main), and branch deletes (all-zero local sha). (#1) Session-start context injection: a new hidden `mship _session-context` prints a 'workspace, no active task — run mship spawn' notice to stdout when cwd resolves to a mship workspace with no active task (else nothing), and `mship init --install-hooks` idempotently installs a Claude Code SessionStart hook into the workspace `.claude/settings.json` that runs it (Claude-only for v1). (#3) Verify the existing commit gate and add bypass-awareness. Cross-cutting escape hatch: a new `core/gate.py` provides `resolve_bypass()` (reads MSHIP_BYPASS_GATE, optional reason), `record_bypass()` (appends {ts, op, branch, reason, cwd} to <workspace>/.mothership/bypass-log.jsonl), and `no_task_notice(cwd)`; `_check-commit` and `_check-push` consult resolve_bypass to allow + log instead of rejecting. git's native `--no-verify` remains the blunt, unlogged escape.

## Architecture

New `src/mship/core/gate.py` owns the cross-cutting bits as small testable units: resolve_bypass() (env read), record_bypass() (append JSONL to .mothership/bypass-log.jsonl), no_task_notice(cwd) (session message logic). `src/mship/core/hooks.py` gains the pre-push entry and hardened bodies (mship resolution + fail-closed for enforcing hooks). `src/mship/core/claude_settings.py` (new) does the idempotent SessionStart install into the workspace .claude/settings.json. `src/mship/cli/internal.py` adds the hidden `_check-push` and `_session-context` commands and threads bypass-awareness into `_check-commit`/`_check-push`. `src/mship/cli/init.py`'s install path calls the claude-settings installer alongside the git-hook installer. Each unit is independently testable; the hooks remain thin shells delegating to mship internals.

## Testing

gate.py: resolve_bypass across unset / '1' / reason; record_bypass appends a well-formed JSONL line (tmp_path); no_task_notice returns the notice for workspace+no-task and None for tasked or non-workspace. _check-push: pattern-branch-not-a-task rejects; registered task branch allows; main/non-pattern allows; delete (zero sha) allows; bypass allows + logs — driven via stdin with mocked state. hooks: assert pre-push is in the inventory and that the generated enforcing-hook block contains the mship-resolution + `exit 1` fail-closed path (no bare `command -v` no-op), while advisory hooks keep `|| true`. claude_settings: install into a missing/empty settings.json creates the SessionStart entry, re-install is idempotent, and pre-existing unrelated hooks survive. _session-context: workspace+no-task prints the notice, tasked prints empty, outside-workspace prints empty. All locally verifiable; no network.
