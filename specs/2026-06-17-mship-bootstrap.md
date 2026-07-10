---
id: mship-bootstrap
title: 'mship bootstrap: materialize a workspace from a fresh clone'
status: dispatched
created_at: '2026-06-17T00:26:13.284193Z'
updated_at: '2026-06-17T00:33:59.411571Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: mothership.yaml accepts an optional `url` per member; a full URL, a git@/SSH
    URL, an `owner/repo` shorthand (-> https://github.com/owner/repo), a bare `repo`
    (-> default_remote/repo), and an omitted url (-> default_remote/member_name) all
    resolve correctly (unit-tested).
  verdict: approved
- id: ac2
  text: A bare or omitted url with no default_remote yields None and a clear per-member
    error, while the other members still proceed.
  verdict: approved
- id: ac3
  text: ConfigLoader.load(require_paths=False) does not raise on missing member paths
    but STILL raises on schema errors such as a dependency cycle or a malformed url.
  verdict: approved
- id: ac4
  text: mship bootstrap on a fresh workspace clone clones every member whose path
    is absent from its resolved url, runs task setup, installs git hooks, runs doctor,
    and afterward mship status works.
  verdict: approved
- id: ac5
  text: An existing member checkout or symlink is never clobbered (no-clobber via
    os.path.lexists), whether or not other members are being cloned.
  verdict: approved
- id: ac6
  text: Plain mship sync still never clones.
  verdict: approved
- id: ac7
  text: Non-TTY mship bootstrap stdout parses as JSON.
  verdict: approved
- id: ac8
  text: 'End-to-end against a LOCAL temporary bare repo as origin (no network): a
    missing member is materialized and the exit code is non-zero when a member errors.'
  verdict: approved
open_questions: []
non_goals:
- "`mship sync --clone-missing` \u2014 sync stays strictly fetch + ff-only and never\
  \ clones (its own follow-up issue)."
- "A dispatch self-bootstrap mode (Ground Control dispatch that auto-bootstraps before\
  \ working) \u2014 its own follow-up issue once bootstrap exists."
- "Adding hook installation to `mship sync` \u2014 doctor already detects missing\
  \ hooks and remediation belongs in init/bootstrap."
- Deriving the host for the owner/repo shorthand from default_remote (it stays github.com);
  a future enhancement only if a non-github member ever needs the slash-shorthand.
risks:
- 'Credentials: the cloud env must have git auth for every member it clones (CCR auths
  only the primary source). Mitigated by reporting clone failures clearly per-member
  without aborting the others.'
- Lenient loading could mask a genuinely broken config if applied too broadly; mitigated
  by keeping require_paths=True everywhere except bootstrap and still running all
  pure schema validators when False.
- No-clobber must never re-point the local `mothership` dogfooding symlink; mitigated
  by using os.path.lexists so any existing path or symlink is treated as present.
task_slug: mship-bootstrap
work_item_id: wi-20260702110439-314ae9ef
---
## Problem

A cloud/CI agent (a scheduled CCR routine, or an agent dispatched from Ground Control) only ever gets a fresh clone of ONE git repo, and neither shape can drive the mship workflow. A fresh clone of the workspace metarepo doesn't contain the members — they're gitignored subdirectories (the E1/MOS-165 layout) — so mship status/spawn/test/finish have nothing to operate on; a fresh clone of a single member isn't a workspace at all (no mothership.yaml). We hit this scheduling the overnight DX-fix routine: we had to point it at the mothership repo directly and fall back to raw git/gh/uv, losing worktrees, phases, journal, test-evidence gating, and multi-repo finish. Dispatching agents is a core goal — they should use mship natively.

## User story

As an operator dispatching a cloud/CI agent, I want `git clone <workspace> && mship bootstrap` to materialize a fully populated, doctor-clean workspace, so that the agent can drive the native mship workflow (spawn/test/finish) instead of falling back to raw git/gh.

## Approach

Make the workspace self-describing and add ONE command. Schema: add `RepoConfig.url` (optional per-member clone source) and `WorkspaceConfig.default_remote` (a host-agnostic base prefix such as https://github.com/atomikpanda — deliberately not named after github so non-github members work via a full URL). Add `require_paths: bool = True` to `ConfigLoader.load`; when False it skips only the path-exists / Taskfile.yml / git_root-subdir checks but still runs every pure schema validator (depends_on refs, cycles, url shape). All existing callers keep the strict default; bootstrap is the only caller passing require_paths=False (Approach A). A pure helper `resolve_clone_url(member_name, repo_cfg, default_remote)` resolves: a url with a scheme (://) or git@ prefix is used as-is; `owner/repo` (a slash, no scheme) -> https://github.com/owner/repo; a bare `repo` -> {default_remote}/repo; an omitted url -> {default_remote}/{member_name}; bare/omitted with no default_remote -> None (clear per-member error). `mship bootstrap` lenient-loads the config from container.config_path() (never the strict container.config(), which would fail on the missing members), then per member (or --repos subset): a no-clobber check treats a member as absent only when os.path.lexists(path) is False so an existing directory or symlink (even a broken one) is never touched; absent members are git-cloned from their resolved url (None -> per-member error, other members still proceed; clone failure -> per-member error with stderr tail, others proceed), then checked out to expected_branch||base_branch when it differs from the cloned default, then `task setup` is run per freshly-cloned repo (failure reported, not fatal), then `mship init --install-hooks` installs the worktree-isolation git hooks, then `mship doctor` runs and its result is surfaced. The command emits a structured per-member report and exits non-zero if any member errored; non-TTY stdout is a pure-JSON envelope with warnings routed to stderr (consistent with the MOS-177 fix) so `mship bootstrap | jq` works. `sync` is unchanged and stays strictly fetch + ff-only (never clones); doctor already detects missing hooks per git root and names `mship init --install-hooks`, so hook installation is intentionally NOT added to sync.

## Architecture

New units, each with one responsibility: (1) src/mship/core/clone_url.py — a pure `resolve_clone_url(member_name, repo_cfg, default_remote) -> str | None` with no I/O, exhaustively table-tested. (2) src/mship/core/config.py — the two new optional fields (RepoConfig.url, WorkspaceConfig.default_remote) plus the `require_paths` parameter on ConfigLoader.load (the only behavioral change to existing code; default True preserves every current caller). (3) src/mship/core/bootstrap.py — the orchestration: lenient load -> no-clobber scan -> clone absent members -> checkout branch -> task setup -> install hooks -> doctor, returning a structured per-member report object (status one of present/cloned/error with a message). (4) src/mship/cli/bootstrap.py — the Typer command (`--repos` subset; TTY table vs non-TTY pure-JSON envelope, warnings to stderr) registered in cli/__init__.py. bootstrap must obtain only config_path + state_dir from the container and never trigger the strict container.config(), since a fresh clone has no members yet.

## Testing

TDD red->green. Unit (resolve_clone_url): one assertion per resolution row — full https url as-is, git@ SSH url as-is, owner/repo -> github.com, bare repo + default_remote, omitted url + default_remote -> default_remote/member_name, omitted + no default_remote -> None, bare + no default_remote -> None, and trailing-slash normalization on default_remote. Unit (lenient load): ConfigLoader.load(require_paths=False) on a config whose member paths are absent does not raise; the same loader still raises on a dependency cycle and on a malformed url. Integration (bootstrap): build a LOCAL temporary bare git repo and point a member's url at it (no network); assert the absent member is cloned and materialized; an existing directory is skipped; a symlink is skipped (never re-pointed); a member with an unresolvable url produces a per-member error while the others still proceed; the process exit code is non-zero when any member errors; and non-TTY stdout parses as JSON.
