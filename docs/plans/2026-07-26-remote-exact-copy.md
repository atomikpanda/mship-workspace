# Exact-Copy Remote Runs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `remote-exact-copy` (status `approved`, 20 acceptance criteria) — run `mship spec show remote-exact-copy` for the text this plan is measured against.

**Goal:** Make `mship run/build --remote` execute the operator's *uncommitted working tree* on the run host, by synthesizing a commit from the working state and pushing it host-to-host onto a scratch ref — never through origin.

**Architecture:** Three pieces, landed in order. (1) `mship serve` gains a deliberately narrow git smart-HTTP **receive** endpoint — the new security surface — scoped to workspace repos and to the `refs/mship/run/*` namespace. (2) The client synthesizes a commit from the working tree through a **temporary index** (`GIT_INDEX_FILE` + `git read-tree <base>` + `git add -A` + `git write-tree` + `git commit-tree`), pushes it to that endpoint with the run-host bearer carried in the *environment*, and tells the run host which repos to materialize from a scratch ref instead of from origin. (3) The run host runs `task setup` after materializing, keyed on the repo's declared `setup_inputs`, so a source-only iteration pays nothing.

**Tech Stack:** Python 3.12+, FastAPI/Starlette (serve), Typer (CLI), httpx (client), pydantic (config), pytest. Git plumbing is exercised against **real temporary repositories over a real socket** — never a mocked shell — because the whole risk here is in git's actual behaviour.

**Work in the task worktree:** `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership`. Every path below is absolute and points there. Do **not** edit through `/home/bailey/development/repos/mothership` — that is the main checkout.

---

## What is already on `main` — and why this plan is surgical, not a rewrite

PR **#419 (remote-run preflight)** is **merged** (commit `29732b8`, on the base of this worktree). It went through six review rounds and absorbed **ten fixes**. `src/mship/core/remote_preflight.py` and the preflight block in `src/mship/cli/exec.py` are substantially richer than any earlier description of them.

**Rule for this whole plan: TRANSFORM those two files. Never replace them, and never replace `tests/core/test_remote_preflight.py`.** Every change to them below is given as an exact anchor + replacement. If a step tempts you to paste a whole file, stop — you are about to delete fixes and the tests that prove them.

The ten fixes, all of which must still hold when this plan is done:

| # | Fix | Where it lives now | Status after this plan |
|---|-----|--------------------|------------------------|
| 1 | `git status --porcelain` return code checked — a failure is `UNREADABLE`, not "clean" | `_inspect_repo`, the `status.returncode != 0` guard | **unchanged** |
| 2 | Origin queried directly with `git ls-remote`, not the local `@{u}` cache | `_origin_tip` | **unchanged**, but now only reached for CLEAN repos (see below) |
| 3 | Origin ahead of HEAD refused (`BEHIND_ORIGIN`) — no push can fix it | `_inspect_repo`, the `merge-base --is-ancestor` branch | **unchanged**, clean path only (see below) |
| 4 | A missing worktree refuses (`MISSING_WORKTREE`) rather than being skipped | `_inspect_repo`'s `path.exists()` guard | **unchanged** |
| 5 | Preflight scoped to the `--repos`/`--tag` set actually dispatched | `inspect(..., repos=...)` + `cli/exec.py` passing `repos=target_repos` | **unchanged** — Task 12 keeps `repos=target_repos` |
| 6 | A selected repo with no `task.worktrees` entry refuses | `inspect`'s `selected - worktrees.keys()` block | **unchanged** |
| 7 | `push` uses an explicit refspec naming the inspected commit | `push`, `f"{s.head_sha}:refs/heads/{s.branch}"` | **unchanged — `push()` is not edited at all** |
| 8 | Worktree not on the task branch refuses (`WRONG_BRANCH`) | `_inspect_repo`'s pair-read comparison | **unchanged** (one new refusal is ordered ahead of it — see below) |
| 9 | The inspected sha pinned on `RepoState.head_sha` and pushed, not re-resolved | `_inspect_repo` → `RepoState.head_sha` → `push` | **unchanged, and extended**: dirty states now also carry `head_sha`, and `synthesize_commit` uses it as the explicit base rather than re-resolving `HEAD` |
| 10 | Branch identity and sha capture collapsed into one self-verifying `git rev-parse HEAD refs/heads/<branch>` | `_inspect_repo`'s `pair` read | **unchanged** |

Also intact and not to be lost: `ORIGIN_UNREACHABLE`, the non-interactive origin query env (`GIT_TERMINAL_PROMPT=0`, `REMOTE_QUERY_TIMEOUT_SECONDS`) in `_origin_tip`, and the documented post-push mutable-branch limitation in `docs/remote-run.md`.

---

## The semantic inversion, worked out

The merged preflight **refuses** a dirty worktree. This spec makes a dirty worktree **the case that works**. Here is exactly what happens to each verdict, and why.

### Refusals that survive unchanged

- **`UNREADABLE`** — if `git status` will not answer, nothing can be decided: not whether to transfer, not whether to push. Refuse.
- **`MISSING_WORKTREE`** — there is no tree to synthesize from, and the run host would materialize that repo from origin regardless. Refuse.
- **`WRONG_BRANCH`** — survives on **both** paths. On the clean path it is exactly as load-bearing as before (fixes 7/8: pushing `<sha>:refs/heads/<branch>` from a detached or foreign-branch worktree would move the task's branch on origin to a commit the operator never named). On the dirty path it stays because the synthesized commit's **parent is HEAD**: a worktree on some other branch would produce a snapshot rooted in history that is not the task's, and the task model (worktree ⇄ branch ⇄ `mship close`) assumes the pairing holds. Nothing in this spec asks to relax it, so it is not relaxed.
- **`ORIGIN_UNREACHABLE`** — survives, but is now only *reachable* on the clean path, because a dirty repo never asks origin anything (below).

### `BEHIND_ORIGIN` — the one that needed a decision

`BEHIND_ORIGIN` exists because the run host materializes a **branch** from origin, so origin's newer commit is what would actually execute. That reasoning is entirely about the origin path.

On the dirty path the run host materializes a **scratch ref** that this machine pushed, and `materialize_worktree(run_ref=...)` issues **no fetch at all** (Task 10). Origin is provably not in the execution path. So `BEHIND_ORIGIN` cannot describe a real hazard there — and neither can `ORIGIN_UNREACHABLE`.

**Decision: the origin comparison runs only for repos that are clean.** A dirty repo short-circuits to the `dirty` list *before* `_origin_tip` is called. This is not a weakening: it preserves both refusals in full on the path where they are load-bearing, and removes a network round trip per dirty repo on the path where origin's answer could not change anything. It is stated in the module docstring so the next reader does not have to re-derive it.

### The refusal that changes meaning

- **`DIRTY`** stops being a refusal. The constant, its `_WHY` entry and its `_FIX` entry are removed; dirty repos become `Preflight.dirty`, which the CLI **transfers**.

### The signal that disappears

- **`Preflight.untracked` / `RepoState.untracked_only`** are removed outright. ac9 makes *any* porcelain output dirty, including untracked-only, and ac11 makes untracked files travel — so the warning they fed ("untracked files will not exist on the run host") becomes a false statement. Deleting a warning that would now be a lie is not a lost guarantee.

### The refusal that is added

- **`IN_PROGRESS`** (ac12) — a repo mid-merge / mid-rebase / mid-cherry-pick / mid-revert, or with unmerged paths. Its files hold conflict markers, so shipping them produces a remote failure with no visible relationship to the edit.

  **It is ordered BEFORE `WRONG_BRANCH`, deliberately.** `git rebase` detaches HEAD, so a mid-rebase repo would otherwise be refused as `WRONG_BRANCH` with the remedy `git -C <path> checkout <branch>` — a command that abandons the rebase. Reordering two refusals costs no guarantee (both stop the run); it only makes the message the correct one. `UNREADABLE` still comes first, so a path that is not a git worktree is still "fix the repo", never "finish your rebase".

### Test disposition — what inverts, what is added, what is deleted

In `tests/core/test_remote_preflight.py` (33 tests today):

| Test | Disposition |
|------|-------------|
| `test_tracked_changes_block_the_run` | **inverts** — same repo shape, now asserts transfer + `pre.ok` + nothing pushed to origin |
| `test_staged_but_uncommitted_also_blocks` | **inverts** — staged-but-uncommitted is dirty, therefore transferred |
| `test_every_dirty_repo_is_named_not_just_the_first` | **inverts** — every dirty repo appears in `pre.dirty`, not just the first |
| `test_untracked_alongside_tracked_still_blocks` | **inverts** — the mixed case is transferred |
| `test_untracked_files_warn_rather_than_block` | **inverts** — ac9: untracked-only is dirty and travels |
| `test_each_blocked_reason_gets_its_own_section` | **edited** — uses `IN_PROGRESS` + `BEHIND_ORIGIN` instead of `DIRTY` + `BEHIND_ORIGIN`; the guarantee (one section per reason) is untouched |
| `test_repos_scoping_ignores_a_dirty_repo_the_run_never_touches` | **edited** — asserts `pre.dirty == []` as well as `pre.ok` |
| `test_the_branch_is_checked_before_the_tree_is_judged_dirty` | **edited** — wrong-branch still beats dirty; the assertion also pins `pre.dirty == []` |
| everything else (25 tests, incl. all 8 real-git tests and all 5 torn-read/race tests) | **untouched** |

**Nothing is deleted.** Every inversion keeps the repo shape and the guarantee, and flips only the verdict — which is the point of the spec. If while implementing you find yourself deleting a test in this file, stop: you are discarding a guarantee rather than converting one.

---

## Verified facts this plan is built on

Every one of these was re-checked against real git **2.43.0** and the real merged codebase while writing this plan. Do not "simplify" them away.

1. **`git add -A` against an EMPTY temporary index silently drops a file that is both tracked and gitignored.** Verified: with `secret.txt` tracked and later listed in `.gitignore`, the empty-index tree was `{.gitignore, a.txt, u.txt}`; the `read-tree`-seeded tree was `{.gitignore, a.txt, secret.txt, u.txt}`. Seeding is required (spec ac1, and the spec now says so).
2. **A tracked-and-gitignored file that is MODIFIED gets its working-tree content into the seeded tree**, not HEAD's. Verified: the tree blob read back as `MODIFIED-SECRET`.
3. **A gitignored file that was never tracked stays out of both trees.** Verified — ac11's second half.
4. **`git commit-tree` does not honour `commit.gpgsign`.** Verified with `-c commit.gpgsign=true -c gpg.program=/bin/false`: `commit-tree` returned a sha and exit 0. No signing prompt can block synthesis.
5. **Synthesis leaves local state byte-identical.** After the full recipe, `git rev-parse HEAD`, `git rev-parse --abbrev-ref HEAD`, `git status --porcelain`, `git diff --cached --name-only` and `git branch --list` were unchanged, and `git branch --contains <sha>` was empty.
6. **Synthesis run from a SUBDIRECTORY still produces the full repo tree.** Verified in a monorepo: from `mono/pkg`, the resulting tree was `{pkg/c.txt, pkg/new.txt, root.txt}` with `root.txt` holding the working-tree edit. (`git ls-tree` run from a subdirectory filters its own output by cwd prefix — a display artefact, not a tree artefact; check with `git cat-file -p <tree>` from the repo root.) This is why a `git_root` child can be synthesized from its own path.
7. **`git commit-tree <tree> -p <sha>` accepts an explicit base sha**, and `git read-tree <sha>` accepts one too — so the synthesized commit's parent can be the sha `inspect` certified rather than a re-resolved `HEAD` (fix 9, carried onto the new path).
8. **The git smart-HTTP receive wire works with exactly two endpoints.** `GET <base>/info/refs?service=git-receive-pack` → `pkt_line(b"# service=git-receive-pack\n") + b"0000" + <git receive-pack --http-backend-info-refs REPO stdout>`; `POST <base>/git-receive-pack` → raw body into `git receive-pack --stateless-rpc REPO`, stdout returned verbatim. Verified end to end with a real `git push` over a real socket.
9. **The bearer reaches BOTH legs** when passed via `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n` (`http.extraHeader`). Verified: the push succeeded, which requires the GET to have been authorized too. The token never enters argv (`/proc/<pid>/cmdline` is world-readable; `/proc/<pid>/environ` is not).
10. **`tests/conftest.py` sets `GIT_CONFIG_COUNT=2` suite-wide** (session-scoped autouse `_disable_git_signing_for_tests`, lines 41–45). The push env must **append** at `n = int(os.environ.get("GIT_CONFIG_COUNT", "0"))`, never claim index 0.
11. **An unauthenticated push fails with a credential error, NOT the string "401".** Verified stderr with `GIT_TERMINAL_PROMPT=0`: `fatal: could not read Username for 'http://127.0.0.1:47999': terminal prompts disabled`. Any test asserting `"401" in stderr` is wrong. Assert non-zero exit and that no ref was created.
12. **A push onto `refs/heads/*` that the endpoint 403s produces `error: RPC failed; HTTP 403` and creates no ref.** Verified against the live prototype.
13. **Deleting an absent scratch ref exits 0** (`remote: warning: deleting a non-existent ref`), locally and over HTTP. The `:<ref>` refspec form is required; `--delete <ref>` errors when the ref is absent.
14. **Pushing onto `refs/mship/run/*` in a NON-BARE repo leaves the checkout untouched** — `receive.denyCurrentBranch` never applies. Verified: `git status --porcelain` empty and `HEAD` still `main` afterwards.
15. **`git rev-parse --git-dir` returns the per-worktree dir in a linked worktree** (verified: `/home/bailey/development/repos/mothership/.git/worktrees/mothership`, containing `HEAD`, `index`, `commondir`) and may return a bare relative `.git` at a repo root — resolve it against the cwd. `MERGE_HEAD` / `rebase-merge` live there.
16. **`git status --porcelain` reports unmerged paths as `UU`** (also `DD`, `AU`, `UD`, `UA`, `DU`, `AA`), and reports a modified tracked-and-gitignored file as ` M` — so it is visible as dirty.
17. **`Output.breadcrumb` prints NOTHING under `CliRunner`.** `json_mode` defaults to `not is_tty` (`src/mship/cli/output.py:126`) and `breadcrumb` is gated on `human_mode` (line 226). Any CLI test asserting on breadcrumb text must `monkeypatch.setenv("MSHIP_JSON", "0")` first. (The already-merged `pushed {repo} so the run host sees your commits` breadcrumb is invisible in tests for exactly this reason — no existing test asserts on it.)
18. **`ConfigLoader.load` resolves top-level `RepoConfig.path` to an absolute path** (`config.py:577`); `git_root` children keep a relative `path` joined onto the parent. So `receive_repo_path` can use `repo_config.path` directly, and tests constructing `WorkspaceConfig` by hand must pass absolute paths for top-level repos.
19. **zsh eats `$SHA:refs/…`** (the `:r`/`:a` history modifiers) — it bit twice while verifying this plan. Every refspec here is built in Python or inside `/bin/sh` via `subprocess(shell=True)`, never typed into an interactive zsh.

---

## File structure

**New source files**

| File | Responsibility |
|------|----------------|
| `src/mship/core/run_ref.py` | The one owner of the `refs/mship/run/<task>/<repo>` namespace: build it, validate it. Imported by the pusher, the endpoint, the run host and cleanup. |
| `src/mship/core/git_receive.py` | The scoped receive path: pkt-line parsing, the ref-namespace + repo allowlist controls, and the two `git receive-pack` invocations. No HTTP here. |
| `src/mship/core/run_transfer.py` | Client side: synthesize a commit through a temporary index, push it to a run host's scratch ref, delete scratch refs on close. |
| `src/mship/core/remote_setup.py` | The `task setup` cache key on the run host (declared `setup_inputs` → digest → per-host state file). |
| `src/mship/util/taskfile.py` | `taskfile_has_target` — moved out of `cli/exec.py` so `core/` can use it too (core must not import from cli). |

**Modified source files**

| File | Change |
|------|--------|
| `src/mship/core/remote_preflight.py` | **Surgical.** `DIRTY` refusal → `dirty` transfer; new `IN_PROGRESS` refusal; origin query scoped to clean repos; `git_repo` on `RepoState`; `untracked_only`/`Preflight.untracked` removed. `push()` untouched. |
| `src/mship/core/serve.py` | `ExecBody.run_ref_repos`; `GET /git/{repo}/info/refs` + `POST /git/{repo}/git-receive-pack`; pass `run_ref_repos` through. |
| `src/mship/core/remote_client.py` | `exec_remote(..., run_ref_repos=...)`. |
| `src/mship/core/remote_exec.py` | `materialize_worktree(..., run_ref=...)` (no fetch); `run_verb_stream(..., run_ref_repos=...)`; keyed `task setup`. |
| `src/mship/core/config.py` | `RepoConfig.setup_inputs`. |
| `src/mship/cli/exec.py` | **Surgical.** Two edits inside `_run_remote`, plus the moved taskfile import. |
| `src/mship/cli/worktree.py` | `close` deletes the task's scratch refs from its run hosts. |
| `docs/remote-run.md`, `docs/configuration.md` | What travels and what does not; `setup_inputs`. |

**New test files:** `tests/core/test_run_ref.py`, `tests/core/test_git_receive.py`, `tests/core/test_run_transfer.py`, `tests/core/test_remote_setup.py`, `tests/core/test_remote_exact_copy_invariants.py`, `tests/util/test_taskfile.py`.

**Modified test files:** `tests/core/test_remote_preflight.py` (8 edited, ~10 added, 0 deleted), `tests/cli/test_remote_dispatch.py`, `tests/core/test_serve_exec.py`, `tests/cli/test_worktree.py`, `tests/core/test_config.py`.

---

## Spec coverage

| AC | What it demands | Task(s) |
|----|-----------------|---------|
| ac1 | Dirty tree → the run host materializes the operator's uncommitted content; a tracked-AND-gitignored file survives | 7, 12, 13 |
| ac2 | Synthesis leaves HEAD/branch/index/`git status` unchanged, no commit in history — real repo | 7 |
| ac3 | Nothing pushed to origin on the dirty path | 6, 12 |
| ac4 | Bearer out of band; never in the remote URL, git config, or argv | 8, 12 |
| ac5 | Refuse refs outside `refs/mship/run/*`; refuse unknown repos | 2, 3, 4, 5 |
| ac6 | Receive endpoint requires the bearer; unauthenticated push rejected | 4, 5 |
| ac7 | Scratch ref per task AND per **git** repo; `git_root` child dedupes to the parent; endpoint refuses a child name | 1, 3, 6, 8 |
| ac8 | Force-update per run; `mship close` deletes the task's scratch refs | 5, 8, 14 |
| ac9 | Clean tree keeps today's path; any porcelain output at all counts as dirty | 6, 12 |
| ac10 | Run host resets to the pushed ref without fetching; stale worktree lands on the pushed tree | 10, 11 |
| ac11 | Untracked files travel, gitignored ones do not | 7, 13 |
| ac12 | Conflicted / mid-rebase repo refused with an actionable message | 6, 12 |
| ac13 | Local output names the revision as a throwaway run ref | 12 |
| ac14 | `finish` still requires real commits; nothing branches/merges from `refs/mship/` | 15 |
| ac15 | `task setup` runs on first materialization; a repo with no setup target is skipped, not failed | 16, 19 |
| ac16 | Setup re-runs when declared `setup_inputs` change, skipped otherwise | 17, 18, 19 |
| ac17 | No declared inputs → setup on first materialization only; docs say declaring buys re-run | 17, 18, 19, 20 |
| ac18 | Failing setup fails the run with setup's own output surfaced | 19 |
| ac19 | Docs state plainly what does and does not travel | 20 |
| ac20 | `mship test --repos mothership` passes; git plumbing exercised against real repos | 21 (+ 3, 5, 6, 7, 10, 13) |

**Out of scope (deliberate):** `mship capture --remote` keeps its own inline remote path in `src/mship/cli/capture.py` — no preflight, no transfer, exactly as #419 left it. `exec_remote`'s new argument defaults to empty so capture is byte-identical on the wire.

---

# Piece 1 — the scoped receive endpoint

Landed first because it is the new security surface and everything else depends on it. Tasks 1–5 touch nothing #419 shipped.

<!-- mship:task id=1 -->
### Task 1: The scratch-ref namespace, one owner

**Files:**
- Create: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/src/mship/core/run_ref.py`
- Test: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/tests/core/test_run_ref.py`

- [ ] **Step 1: Write the failing test**

Create `tests/core/test_run_ref.py`:

```python
"""`refs/mship/run/<task>/<repo>` — the throwaway namespace, and the only place
its shape is decided."""
import pytest

from mship.core.run_ref import RUN_REF_PREFIX, RunRefNameError, is_run_ref, run_ref


def test_ref_is_per_task_and_per_repo():
    """ac7: two tasks, or two repos, must never collide on one ref."""
    assert run_ref("t1", "api") == "refs/mship/run/t1/api"
    assert run_ref("t1", "api") != run_ref("t2", "api")
    assert run_ref("t1", "api") != run_ref("t1", "web")


def test_ref_is_outside_refs_heads():
    """Not a branch: `receive.denyCurrentBranch` never applies (verified against
    a real non-bare repo), and it is nothing a human would branch from (ac14)."""
    assert RUN_REF_PREFIX.startswith("refs/mship/")
    assert not run_ref("t1", "api").startswith("refs/heads/")


@pytest.mark.parametrize("bad", ["..", ".", "a/b", "", "with space", "semi;colon", "dollar$"])
def test_traversal_and_shell_metachars_are_refused(bad):
    """The ref reaches `git push` / `git reset --hard` through a shell and names
    a file on disk, so anything outside the segment charset is refused up front."""
    with pytest.raises(RunRefNameError):
        run_ref(bad, "api")
    with pytest.raises(RunRefNameError):
        run_ref("t1", bad)


def test_is_run_ref_accepts_exactly_two_segments():
    assert is_run_ref("refs/mship/run/t1/api")
    assert not is_run_ref("refs/mship/run/t1")
    assert not is_run_ref("refs/mship/run/t1/api/extra")


@pytest.mark.parametrize("bad", [
    "refs/heads/main",
    "refs/heads/../mship/run/t1/api",
    "refs/mship/runaway/t1/api",
    "refs/mship/run/../../heads/main",
    "HEAD",
    "",
])
def test_is_run_ref_refuses_everything_else(bad):
    assert not is_run_ref(bad)
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_run_ref.py -q`
Expected: collection error — `ModuleNotFoundError: No module named 'mship.core.run_ref'`

- [ ] **Step 3: Write the implementation**

Create `src/mship/core/run_ref.py`:

```python
"""The scratch-ref namespace used to hand a working tree to a run host.

ONE owner for the ref name, imported by every side that touches it: the client
that pushes (`core/run_transfer.py`), the endpoint that decides which pushes to
accept (`core/git_receive.py`), the run host that materializes from it
(`core/remote_exec.py`), and `mship close`, which deletes it. If the shape ever
changes, it changes here.

`refs/mship/run/<task>/<repo>` is deliberately NOT under `refs/heads/`:

  - `receive.denyCurrentBranch` never applies, so a push lands cleanly in a
    non-bare repo whose branch is checked out (verified against real git);
  - nothing else writes this namespace, which is what makes the force-push per
    run safe;
  - it is not real history and must never become any — no code path branches
    from it, merges it, or opens a PR from it (spec ac14, guarded by
    `tests/core/test_remote_exact_copy_invariants.py`).

The `<repo>` segment is the TOP-LEVEL git repo's name. A `git_root` child has no
git directory of its own — its tree IS its parent's — so parent and child dedupe
to one ref (spec ac7). That collapsing happens in `core/remote_preflight.py`;
this module only refuses to build a name it cannot make safe.
"""
from __future__ import annotations

import re

RUN_REF_PREFIX = "refs/mship/run/"

# One path segment of the ref. Deliberately NARROWER than the task-name charset
# `core/serve.py` accepts for `/exec` (`^[A-Za-z0-9._/-]+$`, which allows `/` and
# a bare `.`): this string is interpolated into `git push` / `git reset --hard`
# run through a shell, and `core/remote_setup.py` derives a filename from the
# same values. `.` and `..` are excluded outright so no traversal segment can
# exist.
_SEGMENT_RE = re.compile(r"^(?!\.{1,2}$)[A-Za-z0-9._-]+$")


class RunRefNameError(ValueError):
    """A task or repo name that cannot appear in a run ref."""


def run_ref(task: str, repo: str) -> str:
    """`refs/mship/run/<task>/<repo>` — per task AND per git repo, so two tasks
    or two repos running remotely at once cannot overwrite each other's refs."""
    for label, value in (("task", task), ("repo", repo)):
        if not _SEGMENT_RE.match(value or ""):
            raise RunRefNameError(
                f"{label} name {value!r} cannot be used in a run ref; it must "
                f"match [A-Za-z0-9._-]+ and not be '.' or '..'"
            )
    return f"{RUN_REF_PREFIX}{task}/{repo}"


def is_run_ref(name: str) -> bool:
    """True iff `name` is a ref this feature is allowed to write.

    The receive endpoint's ref-scope control (spec ac5). Strict on purpose:
    exactly the prefix, then exactly two well-formed segments.
    """
    if not name.startswith(RUN_REF_PREFIX):
        return False
    segments = name[len(RUN_REF_PREFIX):].split("/")
    return len(segments) == 2 and all(_SEGMENT_RE.match(s) for s in segments)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_run_ref.py -q`
Expected: `16 passed`

- [ ] **Step 5: Commit (pair with `mship journal`)**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
git add src/mship/core/run_ref.py tests/core/test_run_ref.py
git commit -m "feat(remote): one owner for the refs/mship/run scratch namespace"
mship journal "run_ref: per-task/per-git-repo scratch ref, traversal-safe; 16 tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: pkt-line parsing and the ref-scope control

**Files:**
- Create: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/src/mship/core/git_receive.py`
- Test: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/tests/core/test_git_receive.py`

The push body is parsed for the refs it asks to write **before any git process sees it**. An unscoped receive-pack pass-through really is an arbitrary-ref-write primitive: a live prototype accepted `<sha>:refs/heads/attacker` and created that branch on the host.

- [ ] **Step 1: Write the failing test**

Create `tests/core/test_git_receive.py`:

```python
"""The scoped git receive path.

Layered on purpose: pure pkt-line framing first (no git, no HTTP), then the
allowlist and receive-pack against REAL repositories, then the FastAPI routes,
then a real `git push` over a real socket. The framing is the security boundary,
so it is tested where nothing can hide behind a mock.
"""
import pytest

from mship.core.git_receive import (
    PktLineError,
    RefScopeError,
    check_ref_scope,
    pkt_line,
    ref_commands,
    service_advertisement,
)

ZERO = "0" * 40
SHA = "9647986511a9eb8e9260ca70fc90406674ece7a9"


def _body(*commands: bytes, pack: bytes = b"") -> bytes:
    return b"".join(pkt_line(c) for c in commands) + b"0000" + pack


def test_pkt_line_prefixes_a_four_hex_length_including_itself():
    assert pkt_line(b"abc") == b"0007abc"


def test_service_advertisement_matches_the_wire_prefix_git_expects():
    """Verified against a real `git push`: this exact prefix, then the
    `git receive-pack --http-backend-info-refs` output verbatim."""
    assert service_advertisement(b"REFS").startswith(b"001f# service=git-receive-pack\n0000")
    assert service_advertisement(b"REFS").endswith(b"REFS")


def test_first_command_capabilities_are_stripped():
    body = _body(f"{ZERO} {SHA} refs/mship/run/t1/api\x00report-status side-band-64k".encode())
    assert ref_commands(body) == ["refs/mship/run/t1/api"]


def test_every_command_is_reported_not_just_the_first():
    body = _body(
        f"{ZERO} {SHA} refs/mship/run/t1/api\x00report-status".encode(),
        f"{ZERO} {SHA} refs/heads/sneaky".encode(),
    )
    assert ref_commands(body) == ["refs/mship/run/t1/api", "refs/heads/sneaky"]


def test_a_delete_command_is_parsed():
    """Deleting a scratch ref is old=<sha>, new=<zeros> — the same ref-name
    control governs it."""
    body = _body(f"{SHA} {ZERO} refs/mship/run/t1/api".encode())
    assert ref_commands(body) == ["refs/mship/run/t1/api"]


def test_trailing_pack_data_is_ignored():
    body = _body(f"{ZERO} {SHA} refs/mship/run/t1/api".encode(), pack=b"PACK\x00\x01binary")
    assert ref_commands(body) == ["refs/mship/run/t1/api"]


@pytest.mark.parametrize("body", [
    b"zzzz0000",                    # length is not hex
    b"0003ab",                      # length below the 4-byte header
    b"00ff" + b"short",             # length runs past the body
    b"0010" + b"only two fields",   # not a ref command
])
def test_unparseable_bodies_raise_rather_than_being_guessed_at(body):
    """A body whose refs cannot be read is a body whose refs cannot be checked."""
    with pytest.raises(PktLineError):
        ref_commands(body)


def test_check_ref_scope_accepts_the_run_namespace():
    check_ref_scope(_body(f"{ZERO} {SHA} refs/mship/run/t1/api".encode()))


def test_check_ref_scope_refuses_a_branch_write():
    """ac5. An unscoped receive path really does create refs/heads/<anything> —
    verified against a live prototype. This is the control that stops it."""
    with pytest.raises(RefScopeError) as exc:
        check_ref_scope(_body(f"{ZERO} {SHA} refs/heads/attacker".encode()))
    assert "refs/heads/attacker" in str(exc.value)


def test_one_out_of_scope_ref_refuses_the_whole_push():
    with pytest.raises(RefScopeError):
        check_ref_scope(_body(
            f"{ZERO} {SHA} refs/mship/run/t1/api".encode(),
            f"{ZERO} {SHA} refs/tags/v1".encode(),
        ))


def test_a_body_with_no_commands_is_refused():
    with pytest.raises(PktLineError):
        check_ref_scope(b"0000")
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_git_receive.py -q`
Expected: collection error — `ModuleNotFoundError: No module named 'mship.core.git_receive'`

- [ ] **Step 3: Write the implementation**

Create `src/mship/core/git_receive.py`:

```python
"""A deliberately narrow git smart-HTTP RECEIVE path for `mship serve`.

`mship run --remote` hands the operator's working tree to the run host by
pushing a synthesized commit straight to it (see `core/run_transfer.py`), so
serve needs somewhere for that push to land. This module is that somewhere, and
nothing more: it is not a mirror, not a remote an operator adds by hand, and not
a path for real history.

Two controls, both security controls rather than tidiness:

  - the REPO ALLOWLIST (`receive_repo_path`) — only repos this workspace's
    config declares, and only top-level ones;
  - the REF-NAME constraint (`check_ref_scope`) — only the run scratch
    namespace owned by `core/run_ref.py`.

Without the second this is an arbitrary-ref-write primitive against the run
host: a plain receive-pack pass-through was verified to accept
`<sha>:refs/heads/attacker` and create that branch. The body is therefore parsed
for its ref commands BEFORE any git process sees it.

Wire shape (verified end to end against real `git push`, git 2.43):

    GET  <base>/info/refs?service=git-receive-pack
      -> pkt_line(b"# service=git-receive-pack\\n") + b"0000"
         + `git receive-pack --http-backend-info-refs <repo>` stdout
    POST <base>/git-receive-pack
      -> raw body piped to `git receive-pack --stateless-rpc <repo>` stdin,
         its stdout returned verbatim

The HTTP layer (auth, status codes, threadpool) lives in `core/serve.py`; this
module is pure logic plus two subprocess calls so it can be tested without a
server.
"""
from __future__ import annotations

import subprocess
from pathlib import Path

from mship.core.run_ref import RUN_REF_PREFIX, is_run_ref

RECEIVE_SERVICE = "git-receive-pack"
ADVERTISEMENT_CONTENT_TYPE = "application/x-git-receive-pack-advertisement"
RESULT_CONTENT_TYPE = "application/x-git-receive-pack-result"


class PktLineError(ValueError):
    """The request body is not parseable pkt-line framing. Refused rather than
    guessed at: a body we cannot read is a body whose refs we cannot check."""


class RefScopeError(ValueError):
    """The push asks to write a ref outside the run scratch namespace."""


class UnknownReceiveRepoError(ValueError):
    """No git repository this endpoint will accept a push for."""


class ReceivePackError(RuntimeError):
    """`git receive-pack` itself failed on this host."""


def pkt_line(payload: bytes) -> bytes:
    """`<4-hex-length><payload>`, where the length counts its own 4 bytes."""
    return f"{len(payload) + 4:04x}".encode("ascii") + payload


def service_advertisement(refs_output: bytes) -> bytes:
    """The `info/refs` body: the service pkt-line, a flush, then receive-pack's
    own advertisement."""
    return pkt_line(f"# service={RECEIVE_SERVICE}\n".encode("utf-8")) + b"0000" + refs_output


def ref_commands(body: bytes) -> list[str]:
    """The ref names a receive-pack request asks to update, in order.

    The request is `pkt_line("<old-oid> <new-oid> <ref>[\\0<capabilities>]")`
    repeated, then a `0000` flush, then (for anything but a delete) the
    packfile. Parsing stops at the flush, so the pack is never touched.
    """
    names: list[str] = []
    i = 0
    while i + 4 <= len(body):
        header = body[i:i + 4]
        try:
            length = int(header, 16)
        except ValueError:
            raise PktLineError(f"not a pkt-line length: {header!r}")
        if length == 0:
            break
        if length < 4 or i + length > len(body):
            raise PktLineError(
                f"pkt-line length {length} runs past the end of the request body"
            )
        payload = body[i + 4:i + length]
        i += length
        fields = payload.split(b"\x00", 1)[0].rstrip(b"\n").split(b" ")
        if len(fields) < 3:
            raise PktLineError(f"malformed ref command: {payload!r}")
        names.append(fields[2].decode("utf-8", errors="replace"))
    return names


def check_ref_scope(body: bytes) -> None:
    """Raise unless every ref the push writes is in the run scratch namespace."""
    names = ref_commands(body)
    if not names:
        raise PktLineError("push request contains no ref command")
    outside = [n for n in names if not is_run_ref(n)]
    if outside:
        raise RefScopeError(
            f"refusing to write {', '.join(outside)}: this endpoint accepts "
            f"pushes only onto {RUN_REF_PREFIX}<task>/<repo>"
        )


def receive_repo_path(config, repo: str) -> Path:
    """The git directory a push for `repo` may land in — the ALLOWLIST.

    Only repos declared in this workspace's config are accepted (spec ac5). A
    `git_root` child has no git directory of its own (its tree IS its parent's),
    so a push named for a child is refused and names the parent instead (ac7).

    `ConfigLoader.load` resolves top-level repo paths to absolute, so the value
    returned here is directly usable as a git argument.
    """
    repo_config = getattr(config, "repos", {}).get(repo)
    if repo_config is None:
        known = ", ".join(sorted(getattr(config, "repos", {}))) or "(none)"
        raise UnknownReceiveRepoError(
            f"unknown repo {repo!r}; this workspace knows: {known}"
        )
    if repo_config.git_root is not None:
        raise UnknownReceiveRepoError(
            f"{repo!r} is a git_root child of {repo_config.git_root!r} and has "
            f"no git directory of its own; push to {repo_config.git_root!r}"
        )
    return Path(repo_config.path)


def advertise_refs(repo_path: Path) -> bytes:
    """The `info/refs?service=git-receive-pack` body for `repo_path`."""
    result = subprocess.run(
        ["git", "receive-pack", "--http-backend-info-refs", str(repo_path)],
        capture_output=True,
    )
    if result.returncode != 0:
        raise ReceivePackError(
            f"git receive-pack advertisement failed for {repo_path}: "
            f"{result.stderr.decode('utf-8', errors='replace').strip()}"
        )
    return service_advertisement(result.stdout)


def receive_pack(repo_path: Path, body: bytes) -> bytes:
    """Run the push. Ref scope is checked BEFORE git is invoked, so an
    out-of-scope push never reaches the repository at all."""
    check_ref_scope(body)
    result = subprocess.run(
        ["git", "receive-pack", "--stateless-rpc", str(repo_path)],
        input=body, capture_output=True,
    )
    if result.returncode != 0:
        raise ReceivePackError(
            f"git receive-pack failed for {repo_path}: "
            f"{result.stderr.decode('utf-8', errors='replace').strip()}"
        )
    return result.stdout
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_git_receive.py -q`
Expected: `14 passed`

- [ ] **Step 5: Commit**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
git add src/mship/core/git_receive.py tests/core/test_git_receive.py
git commit -m "feat(serve): pkt-line parsing and the run-namespace scope control"
mship journal "git_receive: ref commands parsed before git sees the body; out-of-scope refs refused" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: The repo allowlist and receive-pack, against a real repository

**Files:**
- Test: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/tests/core/test_git_receive.py` (append)

The implementation already exists from Task 2; this task proves it against real git. The helpers defined here (`_git`, `_repo`, `_config`) are reused by Tasks 4, 5 and 13 — keep them in this file.

- [ ] **Step 1: Write the failing tests**

First, extend the import block at the top of `tests/core/test_git_receive.py` to:

```python
import subprocess
from pathlib import Path

import pytest

from mship.core.config import RepoConfig, WorkspaceConfig
from mship.core.git_receive import (
    PktLineError,
    RefScopeError,
    UnknownReceiveRepoError,
    advertise_refs,
    check_ref_scope,
    pkt_line,
    receive_pack,
    receive_repo_path,
    ref_commands,
    service_advertisement,
)
```

Then append to the same file:

```python
# --- real repositories -------------------------------------------------------

# The operator's own git config must not reach these repos: a global
# `commit.gpgsign`, `insteadOf`, or `hooksPath` would make the outcome depend on
# whose machine the suite runs on. Same reasoning (and same shape) as
# `_GIT_ENV` in tests/core/test_remote_preflight.py:581.
import os

_GIT_ENV = {
    **os.environ,
    "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull,
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
}


def _git(*args: str, cwd: Path) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, capture_output=True, text=True, check=True,
        env=_GIT_ENV,
    ).stdout.strip()


def _repo(path: Path) -> Path:
    """A real, NON-BARE git repository with one commit — the shape a run host's
    checkout actually has."""
    path.mkdir(parents=True, exist_ok=True)
    _git("init", "-q", "-b", "main", ".", cwd=path)
    (path / "a.txt").write_text("one\n")
    _git("add", "-A", cwd=path)
    _git("commit", "-qm", "init", cwd=path)
    return path


def _config(tmp_path: Path) -> WorkspaceConfig:
    """One top-level repo plus a `git_root` child of it. Top-level paths are
    absolute because `ConfigLoader.load` resolves them that way in production
    (config.py:577) and `receive_repo_path` hands the value straight to git."""
    return WorkspaceConfig(
        workspace="t",
        repos={
            "api": RepoConfig(path=tmp_path / "api", type="service"),
            "server": RepoConfig(path=Path("server"), type="service", git_root="api"),
        },
    )


def test_allowlist_resolves_a_declared_repo(tmp_path):
    assert receive_repo_path(_config(tmp_path), "api") == tmp_path / "api"


def test_allowlist_refuses_a_repo_this_workspace_does_not_declare(tmp_path):
    """ac5: not a general-purpose git host — an undeclared repo is refused."""
    with pytest.raises(UnknownReceiveRepoError) as exc:
        receive_repo_path(_config(tmp_path), "somebody-elses-repo")
    assert "api" in str(exc.value)          # names what IS known


def test_allowlist_refuses_a_git_root_child_and_names_its_parent(tmp_path):
    """ac7: a child has no git directory of its own, so the push belongs to the
    parent — and the refusal has to say which parent."""
    with pytest.raises(UnknownReceiveRepoError) as exc:
        receive_repo_path(_config(tmp_path), "server")
    assert "api" in str(exc.value)


def test_advertisement_is_the_prefix_plus_real_receive_pack_output(tmp_path):
    repo = _repo(tmp_path / "api")
    head = _git("rev-parse", "HEAD", cwd=repo)
    body = advertise_refs(repo)
    assert body.startswith(b"001f# service=git-receive-pack\n0000")
    assert head.encode() in body


def test_receive_pack_refuses_an_out_of_scope_push_without_touching_the_repo(tmp_path):
    """The decisive assertion: no ref is created, because git was never run."""
    repo = _repo(tmp_path / "api")
    zero, sha = "0" * 40, _git("rev-parse", "HEAD", cwd=repo)
    body = pkt_line(f"{zero} {sha} refs/heads/attacker".encode()) + b"0000"

    with pytest.raises(RefScopeError):
        receive_pack(repo, body)

    refs = _git("for-each-ref", "--format=%(refname)", cwd=repo)
    assert "refs/heads/attacker" not in refs
```

- [ ] **Step 2: Run them to verify they behave**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_git_receive.py -q -k "allowlist or advertisement_is_the_prefix or out_of_scope_push" -v`
Expected: `5 passed`. They exercise Task 2's code, so they should go green immediately — confirm with `-v` that all five actually **ran** rather than being skipped or not collected. If `test_receive_pack_refuses_an_out_of_scope_push_without_touching_the_repo` fails by creating the ref, `check_ref_scope` is being called after the subprocess in `receive_pack` — fix `git_receive.py`, never the test.

- [ ] **Step 3: No implementation needed**

`git_receive.py` from Task 2 already implements every symbol under test.

- [ ] **Step 4: Run the whole file**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_git_receive.py -q`
Expected: `19 passed`

- [ ] **Step 5: Commit**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
git add tests/core/test_git_receive.py
git commit -m "test(serve): allowlist and receive-pack proven against a real repository"
mship journal "receive path on real git: out-of-scope push creates no ref; git_root child refused, parent named" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: The two serve routes

**Files:**
- Modify: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/src/mship/core/serve.py` (the `from fastapi import ...` line inside `create_app`, line 292; and a new block immediately before the final `return app`, line 1448)
- Test: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/tests/core/test_git_receive.py` (append)

- [ ] **Step 1: Write the failing tests**

Append to `tests/core/test_git_receive.py`:

```python
# --- the HTTP routes ---------------------------------------------------------

from fastapi.testclient import TestClient

from mship.core.serve import create_app
from mship.core.state import StateManager


def _app(tmp_path: Path, *, auth_token: str | None = None, with_config: bool = True):
    """Mirrors `tests/core/test_serve_exec.py::_app` (line 141) so the receive
    routes are exercised through exactly the app the exec routes are."""
    return create_app(
        specs_dir=tmp_path / "specs",
        state_manager=StateManager(tmp_path / ".mothership"),
        log_manager=None,
        workspace_root=tmp_path,
        workspace_name="test-ws",
        auth_token=auth_token,
        config=_config(tmp_path) if with_config else None,
    )


def test_receive_endpoints_require_the_bearer(tmp_path):
    """ac6: the run-host bearer gates the push, on both legs of it."""
    client = TestClient(_app(tmp_path, auth_token="secret"))
    assert client.get(
        "/git/api/info/refs", params={"service": "git-receive-pack"}
    ).status_code == 401
    assert client.post("/git/api/git-receive-pack", content=b"0000").status_code == 401


def test_advertisement_is_served_with_the_bearer(tmp_path):
    _repo(tmp_path / "api")
    client = TestClient(_app(tmp_path, auth_token="secret"))
    r = client.get(
        "/git/api/info/refs",
        params={"service": "git-receive-pack"},
        headers={"Authorization": "Bearer secret"},
    )
    assert r.status_code == 200
    assert r.headers["content-type"] == "application/x-git-receive-pack-advertisement"
    assert r.content.startswith(b"001f# service=git-receive-pack\n0000")


def test_upload_pack_service_is_not_served_here(tmp_path):
    """Narrow on purpose: this is a receive path, not a git host."""
    _repo(tmp_path / "api")
    client = TestClient(_app(tmp_path))
    r = client.get("/git/api/info/refs", params={"service": "git-upload-pack"})
    assert r.status_code == 403


def test_a_repo_the_workspace_does_not_declare_is_404(tmp_path):
    client = TestClient(_app(tmp_path))
    assert client.get(
        "/git/nope/info/refs", params={"service": "git-receive-pack"}
    ).status_code == 404
    assert client.post("/git/nope/git-receive-pack", content=b"0000").status_code == 404


def test_a_git_root_child_is_404_and_names_its_parent(tmp_path):
    """ac7 at the HTTP boundary."""
    r = TestClient(_app(tmp_path)).post("/git/server/git-receive-pack", content=b"0000")
    assert r.status_code == 404
    assert "api" in r.json()["detail"]


def test_a_push_outside_the_run_namespace_is_403_and_creates_nothing(tmp_path):
    """ac5 at the HTTP boundary."""
    repo = _repo(tmp_path / "api")
    sha = _git("rev-parse", "HEAD", cwd=repo)
    body = pkt_line(f"{'0' * 40} {sha} refs/heads/attacker".encode()) + b"0000"
    r = TestClient(_app(tmp_path)).post("/git/api/git-receive-pack", content=body)
    assert r.status_code == 403
    assert "refs/mship/run" in r.json()["detail"]
    assert "attacker" not in _git("for-each-ref", "--format=%(refname)", cwd=repo)


def test_an_unparseable_body_is_400(tmp_path):
    _repo(tmp_path / "api")
    r = TestClient(_app(tmp_path)).post("/git/api/git-receive-pack", content=b"zzzz0000")
    assert r.status_code == 400


def test_a_compressed_body_is_refused_rather_than_mis_parsed(tmp_path):
    """git does not compress a receive-pack request body (verified against a
    real push), so a non-identity encoding means bytes whose refs cannot be
    checked. Refuse rather than hand them to receive-pack unexamined."""
    _repo(tmp_path / "api")
    r = TestClient(_app(tmp_path)).post(
        "/git/api/git-receive-pack", content=b"0000",
        headers={"Content-Encoding": "gzip"},
    )
    assert r.status_code == 400


def test_receive_is_unavailable_without_a_workspace_config(tmp_path):
    """Mirrors `POST /exec/{verb}` (serve.py:1411): 503 with an actionable
    message, never a bare 404."""
    client = TestClient(_app(tmp_path, with_config=False))
    assert client.post(
        "/git/api/git-receive-pack", content=b"0000"
    ).status_code == 503
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_git_receive.py -q -k "receive_endpoints or advertisement_is_served or upload_pack or does_not_declare or git_root_child_is_404 or outside_the_run_namespace or unparseable or compressed or unavailable_without"`
Expected: FAIL — the routes do not exist, so every assertion sees `404` (including the two 401 cases, because FastAPI 404s on an unknown path before the auth dependency runs).

- [ ] **Step 3: Write the implementation**

In `src/mship/core/serve.py`, change the import line at the top of `create_app` (line 292) from:

```python
    from fastapi import Depends, FastAPI, HTTPException
```

to:

```python
    from fastapi import Depends, FastAPI, HTTPException, Request, Response
```

Then insert this block immediately **before** the final `return app` of `create_app` (currently line 1448, right after the `post_exec` handler):

```python
    # --- scoped git receive (spec remote-exact-copy) -------------------------
    # Where `mship run --remote` lands the operator's working tree: a commit
    # synthesized from it and pushed straight here, so uncommitted work never
    # travels through origin. Narrow by construction — `core/git_receive.py`
    # owns both controls (the repo allowlist and the run-scratch ref-name
    # constraint) and explains why an unscoped version would be an
    # arbitrary-ref-write primitive against this host. Auth is the app-wide
    # bearer dependency every other route already inherits.
    from starlette.concurrency import run_in_threadpool

    from mship.core import git_receive

    def _receive_repo(repo: str) -> Path:
        if config is None:
            raise HTTPException(
                status_code=503,
                detail=(
                    "remote workspace not bootstrapped: this serve host has no "
                    "workspace config wired in, so there is no repo to receive "
                    "a push for — bootstrap this machine as an mship workspace "
                    "(mothership.yaml present) and restart `mship serve`"
                ),
            )
        try:
            return git_receive.receive_repo_path(config, repo)
        except git_receive.UnknownReceiveRepoError as exc:
            raise HTTPException(status_code=404, detail=str(exc))

    @app.get("/git/{repo}/info/refs")
    async def get_git_info_refs(repo: str, service: str = ""):
        if service != git_receive.RECEIVE_SERVICE:
            raise HTTPException(
                status_code=403,
                detail=(
                    f"only service={git_receive.RECEIVE_SERVICE} is served here; "
                    f"this is a receive path for `mship run --remote`, not a git host"
                ),
            )
        repo_path = _receive_repo(repo)
        try:
            body = await run_in_threadpool(git_receive.advertise_refs, repo_path)
        except git_receive.ReceivePackError as exc:
            raise HTTPException(status_code=500, detail=str(exc))
        return Response(
            content=body,
            media_type=git_receive.ADVERTISEMENT_CONTENT_TYPE,
            headers={"Cache-Control": "no-cache"},
        )

    @app.post("/git/{repo}/git-receive-pack")
    async def post_git_receive_pack(repo: str, request: Request):
        encoding = (request.headers.get("content-encoding") or "").strip().lower()
        if encoding not in ("", "identity"):
            # git does not compress a receive-pack request (verified). A body we
            # cannot read is a body whose refs we cannot check, so refuse it
            # rather than hand it to receive-pack unexamined.
            raise HTTPException(
                status_code=400,
                detail=(
                    f"unsupported Content-Encoding {encoding!r}; send the body "
                    f"uncompressed"
                ),
            )
        repo_path = _receive_repo(repo)
        body = await request.body()
        try:
            result = await run_in_threadpool(git_receive.receive_pack, repo_path, body)
        except git_receive.RefScopeError as exc:
            raise HTTPException(status_code=403, detail=str(exc))
        except git_receive.PktLineError as exc:
            raise HTTPException(status_code=400, detail=str(exc))
        except git_receive.ReceivePackError as exc:
            raise HTTPException(status_code=500, detail=str(exc))
        return Response(content=result, media_type=git_receive.RESULT_CONTENT_TYPE)
```

Note the comment deliberately does **not** spell the literal ref prefix — Task 15's invariant test allowlists only the five modules that genuinely own it, and `serve.py` is not one of them.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_git_receive.py tests/core/test_serve.py tests/core/test_serve_exec.py -q`
Expected: `test_git_receive.py` reports `28 passed`, and the two existing serve suites stay green (no route regressions).

- [ ] **Step 5: Commit**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
git add src/mship/core/serve.py tests/core/test_git_receive.py
git commit -m "feat(serve): scoped git receive endpoint for run-host pushes"
mship journal "serve: GET/POST /git/{repo} receive routes — bearer-gated, ref-scoped, 503 without config" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: A real `git push` against a live server

**Files:**
- Test: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/tests/core/test_git_receive.py` (append)

`TestClient` never speaks real HTTP, so it cannot prove the wire framing works with real git. This task runs the app under uvicorn on a loopback port and pushes to it with `git push`. The `live_serve` and `_push_env` helpers defined here are reused by Task 13 — keep them in this file.

- [ ] **Step 1: Write the failing tests**

Append to `tests/core/test_git_receive.py`:

```python
# --- real git over a real socket ---------------------------------------------

import contextlib
import socket
import threading
import time

import uvicorn


def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


@contextlib.contextmanager
def live_serve(app):
    """Run `app` under uvicorn on a loopback port for the duration of the block.

    Real git speaks real HTTP; TestClient does not. Anything asserting the smart-
    HTTP framing, the auth header git actually sends, or a push's effect on refs
    has to go through a socket.
    """
    port = _free_port()
    server = uvicorn.Server(
        uvicorn.Config(app, host="127.0.0.1", port=port, log_level="error")
    )
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    deadline = time.time() + 10
    while not server.started and time.time() < deadline:
        time.sleep(0.02)
    if not server.started:
        server.should_exit = True
        raise RuntimeError("uvicorn did not start within 10s")
    try:
        yield f"http://127.0.0.1:{port}"
    finally:
        server.should_exit = True
        thread.join(timeout=10)


def _push_env(token: str | None) -> dict[str, str]:
    """The env `core/run_transfer.extra_header_env` will build in Task 8: the
    bearer as an HTTP header through git's ENV config, and no interactive
    credential prompt (a rejected push must fail the command, not hang).

    APPENDS at the next free index — tests/conftest.py:41 already sets
    GIT_CONFIG_COUNT=2 suite-wide to disable commit signing, and claiming index
    0 would silently re-enable it.
    """
    env = {**_GIT_ENV, "GIT_TERMINAL_PROMPT": "0"}
    if token is not None:
        n = int(os.environ.get("GIT_CONFIG_COUNT", "0"))
        env["GIT_CONFIG_COUNT"] = str(n + 1)
        env[f"GIT_CONFIG_KEY_{n}"] = "http.extraHeader"
        env[f"GIT_CONFIG_VALUE_{n}"] = f"Authorization: Bearer {token}"
    return env


def _push(cwd: Path, url: str, refspec: str, token: str | None):
    return subprocess.run(
        ["git", "push", "--force", url, refspec],
        cwd=cwd, capture_output=True, text=True, env=_push_env(token),
    )


def _clone(host_repo: Path, dest: Path) -> Path:
    subprocess.run(
        ["git", "clone", "-q", str(host_repo), str(dest)],
        check=True, capture_output=True, env=_GIT_ENV,
    )
    return dest


def test_a_real_git_push_lands_on_the_scratch_ref(tmp_path):
    """ac5/ac6/ac8/ac20 end to end: real git, real socket, real refs."""
    host_repo = _repo(tmp_path / "api")
    operator = _clone(host_repo, tmp_path / "operator")
    (operator / "b.txt").write_text("two\n")
    _git("add", "-A", cwd=operator)
    _git("commit", "-qm", "second", cwd=operator)
    sha = _git("rev-parse", "HEAD", cwd=operator)

    with live_serve(_app(tmp_path, auth_token="tok-abc")) as base:
        result = _push(
            operator, f"{base}/git/api", f"{sha}:refs/mship/run/t1/api", "tok-abc"
        )
        assert result.returncode == 0, result.stderr

        # ac8: the same ref force-updates on the next run.
        (operator / "b.txt").write_text("three\n")
        _git("commit", "-qam", "third", cwd=operator)
        sha2 = _git("rev-parse", "HEAD", cwd=operator)
        assert _push(
            operator, f"{base}/git/api", f"{sha2}:refs/mship/run/t1/api", "tok-abc"
        ).returncode == 0

        # Deleting an absent ref is a no-op success (verified against real git),
        # so `mship close` needs no "does it exist" probe.
        delete_absent = _push(
            operator, f"{base}/git/api", ":refs/mship/run/never/api", "tok-abc"
        )
        assert delete_absent.returncode == 0, delete_absent.stderr

    assert _git("rev-parse", "refs/mship/run/t1/api", cwd=host_repo) == sha2
    # The push never touched the host's checkout: `receive.denyCurrentBranch`
    # cannot apply outside refs/heads/.
    assert _git("rev-parse", "--abbrev-ref", "HEAD", cwd=host_repo) == "main"
    assert _git("status", "--porcelain", cwd=host_repo) == ""


def test_a_real_push_without_the_bearer_is_rejected(tmp_path):
    """ac6: an unauthenticated push fails — and fails rather than prompting.

    git turns the 401 into a credential request, which `GIT_TERMINAL_PROMPT=0`
    then refuses; the observed stderr is `fatal: could not read Username for
    '<url>': terminal prompts disabled`, NOT the string "401". Assert the
    outcome (non-zero exit, no ref created), not git's wording.
    """
    host_repo = _repo(tmp_path / "api")
    operator = _clone(host_repo, tmp_path / "operator")
    sha = _git("rev-parse", "HEAD", cwd=operator)

    with live_serve(_app(tmp_path, auth_token="tok-abc")) as base:
        result = _push(operator, f"{base}/git/api", f"{sha}:refs/mship/run/t1/api", None)

    assert result.returncode != 0
    assert "refs/mship/run/t1/api" not in _git(
        "for-each-ref", "--format=%(refname)", cwd=host_repo
    )


def test_a_real_push_onto_a_branch_is_rejected(tmp_path):
    """ac5, with real git driving: the endpoint is not an arbitrary-ref writer."""
    host_repo = _repo(tmp_path / "api")
    operator = _clone(host_repo, tmp_path / "operator")
    sha = _git("rev-parse", "HEAD", cwd=operator)

    with live_serve(_app(tmp_path, auth_token="tok-abc")) as base:
        result = _push(operator, f"{base}/git/api", f"{sha}:refs/heads/attacker", "tok-abc")

    assert result.returncode != 0
    assert "403" in result.stderr        # the endpoint's refusal, not a git error
    assert "refs/heads/attacker" not in _git(
        "for-each-ref", "--format=%(refname)", cwd=host_repo
    )
```

- [ ] **Step 2: Run them to verify they behave**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_git_receive.py -q -k "real_git_push or without_the_bearer or onto_a_branch" -v`
Expected: `3 passed` (the routes landed in Task 4). If `test_a_real_git_push_lands_on_the_scratch_ref` fails while fetching the advertisement, the framing in `service_advertisement` is wrong — fix it there, not in the test.

- [ ] **Step 3: No implementation needed**

These tests exercise Task 2 and Task 4 code only.

- [ ] **Step 4: Run the whole file plus the serve suites**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_git_receive.py tests/core/test_serve.py tests/core/test_serve_exec.py -q`
Expected: all pass; `test_git_receive.py` reports `31 passed`.

- [ ] **Step 5: Commit**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
git add tests/core/test_git_receive.py
git commit -m "test(serve): real git push against a live receive endpoint"
mship journal "receive endpoint proven with real git over a real socket: scoped, bearer-gated, force-updates, delete-absent is a no-op" --action committed
```
<!-- /mship:task -->

---

# Piece 2 — commit synthesis and the push

<!-- mship:task id=6 -->
### Task 6: The preflight stops refusing dirt and starts routing it

**Files:**
- Modify (**surgical — thirteen anchored edits, never a rewrite**): `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/src/mship/core/remote_preflight.py`
- Modify (**surgical — one helper edit, eight test edits, ten additions, zero deletions**): `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/tests/core/test_remote_preflight.py`

Read "The semantic inversion, worked out" at the top of this plan before starting. In one sentence: `DIRTY` becomes a transfer, `IN_PROGRESS` becomes a refusal ordered ahead of `WRONG_BRANCH`, the origin query is scoped to clean repos, and `untracked_only` disappears. **`push()` is not touched at all** — fixes 7 and 9 live there.

- [ ] **Step 1: Edit the tests first — the helper, then the eight that change meaning**

**1a. Teach `FakeShell` about `git rev-parse --git-dir`, and have it record commands.** In `tests/core/test_remote_preflight.py`, inside `FakeShell.run`, insert this branch immediately before the `elif "rev-parse HEAD" in cmd and "refs/heads/" in cmd:` branch:

```python
        elif "rev-parse --git-dir" in cmd:
            # `_inspect_repo` asks for the per-worktree git dir to look for an
            # interrupted merge/rebase (MERGE_HEAD, rebase-merge/, ...). Real
            # git returns an absolute path in a linked worktree and may return a
            # bare `.git` at a repo root; either is fine here because the
            # production code resolves a relative answer against `cwd`.
            out, rc = spec.get("git_dir", str(Path(cwd) / ".git")), 0
```

In the same class, add a command log. In `__init__`, after `self.pair_calls: dict[str, int] = {}`:

```python
        # Every command issued, in order — the only way to assert that a query
        # was NOT made (e.g. that a dirty repo never asks origin).
        self.commands: list[str] = []
```

and as the first line of `run`, immediately after `key = Path(cwd).name`:

```python
        self.commands.append(cmd)
```

**1b. Update the import block** at the top of the file from `DIRTY` to `IN_PROGRESS`:

```python
from mship.core.remote_preflight import (
    BEHIND_ORIGIN,
    IN_PROGRESS,
    MISSING_WORKTREE,
    ORIGIN_UNREACHABLE,
    UNREADABLE,
    WRONG_BRANCH,
    blocked_message,
    inspect,
    push,
)
```

**1c. Invert the five dirty-refusal tests.** Delete `test_tracked_changes_block_the_run`, `test_staged_but_uncommitted_also_blocks` and `test_every_dirty_repo_is_named_not_just_the_first` from under `# --- what must be refused ---`, and delete `test_untracked_files_warn_rather_than_block` and `test_untracked_alongside_tracked_still_blocks` together with their now-empty `# --- what must only warn ---` heading. Add these five in their place, as one block immediately after the `_clean` helper and before `# --- what must be refused ---`:

```python
# --- what must be TRANSFERRED, not refused ----------------------------------
#
# These five were refusals under PR #419, for a reason that no longer holds:
# inventing a commit out of someone's work in progress was not a decision the
# tool could make, because that commit would have gone to ORIGIN. It now goes
# only to the operator's own run host, on a ref nothing else writes, leaving
# their repository untouched — so the same repo shapes route instead of stopping.

def test_tracked_changes_are_transferred_not_refused(tmp_path):
    """The whole point of the spec: run what the operator is editing."""
    api = _repo(tmp_path, "api")
    shell = FakeShell({"api": _clean(status=" M src/app.py\n")})

    pre = inspect(FakeTask({"api": api}), shell)

    assert pre.ok
    assert [s.repo for s in pre.dirty] == ["api"]
    assert pre.to_push == []            # ac3: origin is not in this path
    assert shell.pushes == []


def test_staged_but_uncommitted_is_also_transferred(tmp_path):
    api = _repo(tmp_path, "api")
    shell = FakeShell({"api": _clean(status="M  src/app.py\n")})
    pre = inspect(FakeTask({"api": api}), shell)
    assert pre.ok and [s.repo for s in pre.dirty] == ["api"]


def test_every_dirty_repo_is_transferred_not_just_the_first(tmp_path):
    """A multi-repo task must send every repo's tree; sending one and leaving
    the others on origin's revision is the stale-code failure again."""
    api, web = _repo(tmp_path, "api"), _repo(tmp_path, "web")
    shell = FakeShell({
        "api": _clean(status=" M a.py\n"),
        "web": _clean(status=" M b.ts\n"),
    })
    pre = inspect(FakeTask({"api": api, "web": web}), shell)
    assert sorted(s.repo for s in pre.dirty) == ["api", "web"]
    assert pre.ok and shell.pushes == []


def test_untracked_only_counts_as_dirty_and_travels(tmp_path):
    """ac9/ac11. Under #419 this only warned, because untracked files could not
    change what a push to origin carried. They are part of what the operator
    sees, and they now travel only between the operator's own two machines — so
    ANY porcelain output at all is dirty, or untracked files would never travel
    and ac11 would be unsatisfiable."""
    api = _repo(tmp_path, "api")
    shell = FakeShell({"api": _clean(status="?? scratch.txt\n")})
    pre = inspect(FakeTask({"api": api}), shell)
    assert pre.ok
    assert [s.repo for s in pre.dirty] == ["api"]
    assert pre.to_push == []


def test_untracked_alongside_tracked_is_transferred_once(tmp_path):
    api = _repo(tmp_path, "api")
    shell = FakeShell({"api": _clean(status="?? new.py\n M old.py\n")})
    pre = inspect(FakeTask({"api": api}), shell)
    assert pre.ok and [s.repo for s in pre.dirty] == ["api"]
```

**1d. Edit `test_each_blocked_reason_gets_its_own_section`** — the guarantee (one section per reason, because the fix for one is wrong for the other) is unchanged; only the pair of reasons changes, since dirty is no longer a reason:

```python
def test_each_blocked_reason_gets_its_own_section(tmp_path):
    """A conflicted repo and a stale one need BOTH remedies, not whichever was
    found first — the fix for one is actively wrong for the other."""
    api, web = _repo(tmp_path, "api"), _repo(tmp_path, "web")
    (api / ".git").mkdir(parents=True, exist_ok=True)
    (api / ".git" / "MERGE_HEAD").write_text("abc\n")
    shell = FakeShell({
        "api": _clean(status="UU a.py\n"),
        "web": _clean(origin="beefbeefbeef", head="oldsha", contains=[]),
    })
    msg = blocked_message(inspect(FakeTask({"api": api, "web": web}), shell))
    assert "merge or rebase in progress in api" in msg
    assert "unpulled commits on origin in web" in msg
    assert "--abort" in msg and "pull --ff-only" in msg
```

**1e. Edit `test_the_branch_is_checked_before_the_tree_is_judged_dirty`** — same guarantee, one extra assertion:

```python
def test_the_branch_is_checked_before_the_tree_is_judged_dirty(tmp_path):
    """A wrong-branch worktree that is also dirty must report the branch. Under
    #419 the alternative was telling the operator to `mship commit` onto the
    wrong branch; now it is silently SENDING that branch's tree as if it were
    the task's, which is worse still. So WRONG_BRANCH keeps winning."""
    api = _repo(tmp_path, "api")
    shell = FakeShell({"api": _clean(status=" M a.py\n", head_ref="refs/heads/main")})
    pre = inspect(FakeTask({"api": api}), shell)
    assert [s.blocked_reason for s in pre.blocked] == [WRONG_BRANCH]
    assert pre.dirty == []
```

**1f. Edit `test_repos_scoping_ignores_a_dirty_repo_the_run_never_touches`** — add the transfer assertion:

```python
def test_repos_scoping_ignores_a_dirty_repo_the_run_never_touches(tmp_path):
    """`--repos api` dispatches only api; work in progress in web is neither a
    reason to stop nor a tree to ship."""
    api, web = _repo(tmp_path, "api"), _repo(tmp_path, "web")
    shell = FakeShell({
        "api": _clean(),
        "web": _clean(status=" M b.ts\n"),
    })
    pre = inspect(FakeTask({"api": api, "web": web}), shell, repos=["api"])
    assert pre.ok
    assert [s.repo for s in pre.states] == ["api"]
    assert pre.dirty == []
```

**1g. Add the new cases.** Append to the `# --- what must be refused ---` section:

```python
def test_a_conflicted_repo_is_refused(tmp_path):
    """ac12: the working tree IS what gets sent, and mid-conflict it holds
    conflict markers rather than code anyone meant to run."""
    api = _repo(tmp_path, "api")
    shell = FakeShell({"api": _clean(status="UU src/app.py\n")})

    pre = inspect(FakeTask({"api": api}), shell)

    assert not pre.ok
    assert [s.blocked_reason for s in pre.blocked] == [IN_PROGRESS]
    assert pre.dirty == [] and shell.pushes == []

    msg = blocked_message(pre)
    assert "merge or rebase in progress in api" in msg
    assert "src/app.py" in msg          # which file, exactly
    assert "--abort" in msg             # the way out


def test_a_mid_rebase_repo_is_refused_ahead_of_the_branch_check(tmp_path):
    """Ordering matters, and it is not cosmetic: `git rebase` DETACHES HEAD, so
    checking the branch first would refuse this as WRONG_BRANCH and print
    `git checkout <branch>` — a command that abandons the rebase. The
    in-progress check is deliberately ordered ahead of it."""
    api = _repo(tmp_path, "api")
    (api / ".git" / "rebase-merge").mkdir(parents=True)
    shell = FakeShell({"api": _clean(status="", head_ref="")})   # detached

    pre = inspect(FakeTask({"api": api}), shell)

    assert [s.blocked_reason for s in pre.blocked] == [IN_PROGRESS]
    msg = blocked_message(pre)
    assert "rebase" in msg
    assert "checkout" not in msg        # NOT the wrong-branch remedy


def test_a_mid_merge_repo_is_refused_even_with_a_clean_tree(tmp_path):
    """`git merge --no-commit` leaves MERGE_HEAD with nothing unmerged: the
    porcelain alone cannot see it, which is why the git dir is consulted."""
    api = _repo(tmp_path, "api")
    (api / ".git").mkdir(parents=True, exist_ok=True)
    (api / ".git" / "MERGE_HEAD").write_text("abc\n")
    shell = FakeShell({"api": _clean(status="")})
    assert [s.blocked_reason for s in inspect(FakeTask({"api": api}), shell).blocked] \
        == [IN_PROGRESS]


def test_a_cherry_pick_in_progress_is_refused(tmp_path):
    api = _repo(tmp_path, "api")
    (api / ".git").mkdir(parents=True, exist_ok=True)
    (api / ".git" / "CHERRY_PICK_HEAD").write_text("abc\n")
    shell = FakeShell({"api": _clean(status="")})
    assert [s.blocked_reason for s in inspect(FakeTask({"api": api}), shell).blocked] \
        == [IN_PROGRESS]


def test_an_unanswerable_git_dir_is_unreadable_not_transferred(tmp_path):
    """Same rule as fix 1's `git status` guard: a repo whose state could not be
    established is refused, never assumed clean — and never shipped."""
    api = _repo(tmp_path, "api")
    shell = FakeShell({"api": _clean(status=" M a.py\n", git_dir="")})
    pre = inspect(FakeTask({"api": api}), shell)
    assert [s.blocked_reason for s in pre.blocked] == [UNREADABLE]
    assert pre.dirty == []
```

And append a new section at the end of the scripted-shell tests, before `# --- against real git ---`:

```python
# --- how a dirty repo is routed ---------------------------------------------

def test_a_dirty_repo_never_asks_origin(tmp_path):
    """BEHIND_ORIGIN and ORIGIN_UNREACHABLE exist because the run host
    materializes a BRANCH from origin. On this path it materializes a scratch
    ref this machine pushes, with no fetch at all, so origin's answer cannot
    change what executes — and a round trip that cannot change the outcome is a
    round trip not worth taking. Both refusals keep their full force on the
    clean path (see the tests above)."""
    api = _repo(tmp_path, "api")
    shell = FakeShell({"api": _clean(
        status=" M a.py\n",
        origin="0123456789abcdef", head="oldsha", contains=[],   # would be BEHIND_ORIGIN
    )})

    pre = inspect(FakeTask({"api": api}), shell)

    assert pre.ok
    assert [s.repo for s in pre.dirty] == ["api"]
    assert pre.blocked == []                                # not BEHIND_ORIGIN
    assert not any("ls-remote" in c for c in shell.commands)
    assert not any("merge-base" in c for c in shell.commands)


def test_a_dirty_repo_carries_the_sha_inspect_certified(tmp_path):
    """Fix 9, carried onto the new path: `synthesize_commit` parents the
    snapshot on THIS sha rather than re-resolving HEAD moments later."""
    api = _repo(tmp_path, "api")
    shell = FakeShell({"api": _clean(status=" M a.py\n", head="certified")})
    pre = inspect(FakeTask({"api": api}), shell)
    assert [s.head_sha for s in pre.dirty] == ["certified"]


def test_a_git_root_child_and_its_parent_dedupe_to_one_transfer(tmp_path):
    """ac7: one git repository, one scratch ref. The child's tree IS the
    parent's, so pushing both would send the same objects twice under two names
    — and the run host resolves the child under the materialized parent anyway.
    The parent is the survivor because that is the name the host materializes."""
    mono = _repo(tmp_path, "mono")
    child = _repo(tmp_path / "mono", "pkg")
    shell = FakeShell({
        "mono": _clean(status=" M a.py\n"),
        "pkg": _clean(status=" M a.py\n"),
    })
    config = WorkspaceConfig(workspace="t", repos={
        "mono": RepoConfig(path=mono, type="service"),
        "pkg": RepoConfig(path=Path("pkg"), type="service", git_root="mono"),
    })

    pre = inspect(FakeTask({"mono": mono, "pkg": child}), shell, config=config)

    assert [s.git_repo for s in pre.dirty] == ["mono"]
    assert [s.repo for s in pre.dirty] == ["mono"]
    assert [s.repo for s in pre.states] == ["mono", "pkg"]   # both still inspected


def test_without_a_config_every_repo_is_its_own_git_repo(tmp_path):
    """`config` is optional so the 25 untouched tests in this file keep calling
    `inspect(task, shell)`. Absent it there is nothing to collapse against."""
    api = _repo(tmp_path, "api")
    shell = FakeShell({"api": _clean(status=" M a.py\n")})
    pre = inspect(FakeTask({"api": api}), shell)
    assert [s.git_repo for s in pre.dirty] == ["api"]
```

Add the config import at the top of the file (next to the existing `from mship.core.remote_preflight import ...`):

```python
from mship.core.config import RepoConfig, WorkspaceConfig
```

**1h. Add two real-git cases** at the end of the file, alongside the existing real-git suite (which is where staleness and detached-HEAD are proven, because a mock has no notion of them):

```python
def test_a_real_dirty_repo_is_transferred_and_origin_is_untouched(tmp_path):
    """ac3 against real git: the whole point is that origin sees nothing."""
    origin, work = _real_repo(tmp_path)
    before = _git(origin, "rev-parse", "refs/heads/feat/x")
    (work / "f.txt").write_text("uncommitted\n")
    (work / "scratch.txt").write_text("untracked\n")

    shell = RealShell()
    pre = inspect(FakeTask({"api": work}), shell)

    assert pre.ok
    assert [s.repo for s in pre.dirty] == ["api"]
    assert pre.to_push == []
    assert push(pre, shell) == ([], None)
    assert _git(origin, "rev-parse", "refs/heads/feat/x") == before


def test_a_real_conflicted_repo_is_refused(tmp_path):
    """ac12 against real git: a real merge conflict, real MERGE_HEAD, real
    `UU` porcelain — the exact state a mock can only assert about."""
    _, work = _real_repo(tmp_path)
    _git(work, "checkout", "-b", "side")
    (work / "f.txt").write_text("side\n")
    _git(work, "commit", "-am", "side")
    _git(work, "checkout", "feat/x")
    (work / "f.txt").write_text("mine\n")
    _git(work, "commit", "-am", "mine")
    subprocess.run(["git", "merge", "side"], cwd=work, capture_output=True, env=_GIT_ENV)

    pre = inspect(FakeTask({"api": work}), RealShell())

    assert [s.blocked_reason for s in pre.blocked] == [IN_PROGRESS]
    assert pre.dirty == []
    assert "--abort" in blocked_message(pre)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_remote_preflight.py -q`
Expected: collection error — `ImportError: cannot import name 'IN_PROGRESS' from 'mship.core.remote_preflight'`.

- [ ] **Step 3: Make the thirteen anchored edits to `remote_preflight.py`**

Every edit below is `old` → `new` on exact existing text. Apply them in order. Do **not** rewrite the file, and do **not** touch `_tail`, `_origin_tip`, the pair-read comment block, or `push()`.

**Edit 1 — the docstring's verdict half** (the module's first 34 lines). Replace from `"""Make sure a remote run executes` down to and including the `* untracked files only → **warn**...` bullet, with:

```python
"""Make sure a remote run executes the code you are actually looking at.

`--remote` used to run whatever was on origin, because the run host materialized
the task's branch by fetching it. Nothing on the caller side checked that origin
matched the local worktree, and nothing pushes during development — `git push -u`
happens at `mship finish`. So two things could happen silently:

  * the branch was never pushed at all, and the remote failed with a materialize
    error that pointed at the remote rather than at the real cause; or
  * the branch was pushed at some earlier point, and the remote ran THAT revision.
    The output looked like a real result for code the operator was not editing.

The second is the dangerous one, and it is what this module exists to prevent. It
sorts the task's repos into three outcomes:

  * **REFUSE** — the repo cannot be sent, or sending it would be a lie about what
    the operator meant. See the reason constants below.
  * **TRANSFER** (`Preflight.dirty`) — the working tree differs from HEAD, in any
    way at all. `cli/exec.py` synthesizes a commit from that tree
    (`core/run_transfer.py`) and pushes it STRAIGHT TO THE RUN HOST, onto a ref
    under the throwaway namespace `core/run_ref.py` owns. Origin is never in this
    path: routing uncommitted work through it would publish untracked scratch
    files to a third party, and deleting the ref afterwards would not retract the
    objects. Nothing local is mutated — see `synthesize_commit`.
  * **PUSH** (`Preflight.to_push`) — the tree is clean but origin is missing the
    branch or is behind it. Push the branch to origin exactly as before. There is
    nothing extra to send, so nothing extra happens.

Real history goes to origin; throwaway state goes host to host.

ANY `git status --porcelain` output makes a repo dirty, untracked entries
included. That is not laxity: untracked files are part of what the operator sees,
they now travel only between the operator's own two machines, and a rule that
excluded them would mean they never travel at all.

For a CLEAN repo, and only for a clean repo, the verdict is reached by ASKING
ORIGIN rather than by reading a local remote-tracking ref: `@{u}` is a cached copy
that another machine's push makes stale, and it goes stale in the unsafe direction
— it reports "up to date" for a branch origin has since moved ahead on. One
`git ls-remote origin refs/heads/<branch>` settles it (the same pattern, for the
same reason, as `evidence_url._remote_tip`). Against origin's real tip:

  * the branch is **missing from origin, or origin's tip is an ancestor of HEAD** →
    **push**. That is unambiguously what the operator meant, and nothing is lost.
  * origin's tip is **not in HEAD's history** → **refuse**. The run host would
    execute a commit the operator does not have, and no push can fix it: a
    fast-forward from behind is impossible, so attempting one would only produce a
    confusing git error in place of the real remedy (sync, or reset deliberately).

A DIRTY repo never asks origin at all. The run host materializes the scratch ref
this machine pushed, with no fetch (`remote_exec.materialize_worktree(run_ref=…)`),
so origin's tip cannot change what executes — and a network round trip that cannot
change the outcome is one not worth taking. BEHIND_ORIGIN and ORIGIN_UNREACHABLE
therefore keep their full force on the path where they describe a real hazard, and
are simply unreachable on the path where they would not.

A repo mid-merge, mid-rebase, mid-cherry-pick or with unmerged paths is refused
outright (IN_PROGRESS). The working tree is what gets sent, and in that state it
holds conflict markers and half-applied changes; shipping them produces a remote
failure with no visible relationship to the edit the operator was making. That
check runs BEFORE the branch check on purpose: `git rebase` detaches HEAD, so
checking the branch first would refuse a rebase as WRONG_BRANCH and print a
`git checkout` that abandons it.
```

**Edit 2 — the reason constants.** Replace:

```python
DIRTY = "uncommitted changes"
UNREADABLE = "unreadable git state"
```

with:

```python
IN_PROGRESS = "merge or rebase in progress"
UNREADABLE = "unreadable git state"
```

**Edit 3 — `_WHY`'s first entry.** Replace:

```python
    DIRTY:
        "the run host materializes the task's branch from origin, so it would "
        "run the last PUSHED revision, not what you are editing.",
```

with:

```python
    IN_PROGRESS:
        "the working tree is what gets sent, and mid-operation it holds conflict "
        "markers and half-applied changes rather than code you meant to run.",
```

**Edit 4 — `_FIX`'s first entry.** Replace:

```python
    DIRTY: [
        "Commit and push first:",
        '  mship commit "<what changed>"        # commits across every task repo',
        '  git -C "{path}" push -u origin HEAD',
    ],
```

with:

```python
    IN_PROGRESS: [
        "Finish it or abandon it, then re-run:",
        '  git -C "{path}" status                 # what git is in the middle of',
        '  git -C "{path}" rebase --abort         # ...or merge/cherry-pick/revert --abort',
    ],
```

**Edit 5 — `RepoState` fields.** Replace:

```python
    untracked_only: bool
    needs_push: bool
    push_reason: str | None      # "not on origin" | "ahead of origin" | None
    head_sha: str | None = None  # HEAD as resolved during inspect; see `push`
```

with:

```python
    dirty: bool                  # working tree differs from HEAD -> TRANSFER
    needs_push: bool
    push_reason: str | None      # "not on origin" | "ahead of origin" | None
    head_sha: str | None = None  # HEAD as resolved during inspect; see `push`
    # The TOP-LEVEL git repo this worktree belongs to. Equal to `repo` except
    # for a `git_root` child, whose tree IS its parent's — so both name the
    # parent and dedupe to one transfer (spec ac7). Resolved in `inspect` from
    # the workspace config; `repo` itself when no config was supplied.
    git_repo: str | None = None
```

**Edit 6 — `Preflight` fields.** Replace:

```python
    states: list[RepoState]
    blocked: list[RepoState]
    to_push: list[RepoState]
    untracked: list[RepoState]
```

with:

```python
    states: list[RepoState]
    blocked: list[RepoState]
    to_push: list[RepoState]
    dirty: list[RepoState]       # one entry per GIT repo, not per repo name
```

**Edit 7 — add the in-progress helpers** immediately after `_tail` and before `_origin_tip`:

```python
# `git status --porcelain` spells an unmerged path with these two-letter codes
# (verified: a real conflict reports `UU`). They are the only porcelain codes
# that mean "git has not finished", which is why they are singled out rather
# than lumped in with the dirty check below.
_UNMERGED_CODES = ("DD", "AU", "UD", "UA", "DU", "AA", "UU")

# Marker files git leaves in the per-worktree git dir while an operation is
# suspended. A `--no-commit` merge leaves MERGE_HEAD with NOTHING unmerged, so
# the porcelain alone cannot see it — hence the extra look.
_OPERATIONS = (
    ("rebase-merge", "a rebase is in progress"),
    ("rebase-apply", "a rebase or `git am` is in progress"),
    ("MERGE_HEAD", "a merge is in progress"),
    ("CHERRY_PICK_HEAD", "a cherry-pick is in progress"),
    ("REVERT_HEAD", "a revert is in progress"),
)


def _operation_in_progress(git_dir: Path) -> str | None:
    """Which suspended git operation this worktree is in, if any."""
    for marker, description in _OPERATIONS:
        if (git_dir / marker).exists():
            return description
    return None
```

**Edit 8 — `_inspect_repo`'s signature and `state()` helper.** Replace:

```python
def _inspect_repo(shell, repo: str, path: Path, branch: str) -> RepoState:
    """One repo's verdict. Every path out of here is either a decision or a
    refusal — there is no "could not tell, carry on"."""
    def state(*, blocked=None, detail=None, untracked_only=False,
              needs_push=False, push_reason=None, head_sha=None) -> RepoState:
        return RepoState(
            repo=repo, path=path, branch=branch, blocked_reason=blocked,
            detail=detail, untracked_only=untracked_only,
            needs_push=needs_push, push_reason=push_reason, head_sha=head_sha,
        )
```

with:

```python
def _inspect_repo(
    shell, repo: str, path: Path, branch: str, *, git_repo: str | None = None,
) -> RepoState:
    """One repo's verdict. Every path out of here is either a decision or a
    refusal — there is no "could not tell, carry on"."""
    def state(*, blocked=None, detail=None, dirty=False,
              needs_push=False, push_reason=None, head_sha=None) -> RepoState:
        return RepoState(
            repo=repo, path=path, branch=branch, blocked_reason=blocked,
            detail=detail, dirty=dirty,
            needs_push=needs_push, push_reason=push_reason, head_sha=head_sha,
            git_repo=git_repo or repo,
        )
```

**Edit 9 — the status comment, and the in-progress check right after it.** Replace:

```python
    # `git status --porcelain` lists untracked entries as `??` and never lists
    # gitignored files, so an ignored `.venv` does not make a repo look dirty.
    # Untracked files are reported separately because they cannot alter what a
    # push carries — refusing on them would block a run over a stray scratch file.
    status = shell.run("git status --porcelain", cwd=path)
    if status.returncode != 0:
        # Empty stdout from a FAILED status is indistinguishable from a clean
        # tree, so the return code is the only thing separating "nothing to
        # report" from "could not look".
        return state(blocked=UNREADABLE, detail=_tail(status))
```

with:

```python
    # `git status --porcelain` lists untracked entries as `??` and never lists
    # gitignored files, so an ignored `.venv` does not make a repo look dirty.
    # (It DOES list a tracked-and-gitignored file that changed, as ` M` —
    # verified — which is right: that file is part of what gets sent.)
    status = shell.run("git status --porcelain", cwd=path)
    if status.returncode != 0:
        # Empty stdout from a FAILED status is indistinguishable from a clean
        # tree, so the return code is the only thing separating "nothing to
        # report" from "could not look".
        return state(blocked=UNREADABLE, detail=_tail(status))

    lines = [ln for ln in (status.stdout or "").splitlines() if ln.strip()]

    # An interrupted operation is refused BEFORE the branch is checked, because
    # `git rebase` detaches HEAD: checking the branch first would refuse a
    # rebase as WRONG_BRANCH and hand the operator a `git checkout` that
    # abandons it. Still AFTER `git status`, so a path that is not a git
    # worktree at all stays UNREADABLE rather than becoming "finish your merge".
    unmerged = [ln[3:].strip() for ln in lines if ln[:2] in _UNMERGED_CODES]
    git_dir_result = shell.run("git rev-parse --git-dir", cwd=path)
    git_dir_raw = (git_dir_result.stdout or "").strip()
    if git_dir_result.returncode != 0 or not git_dir_raw:
        # Same rule as the status guard above: a repo whose state could not be
        # established is refused, never assumed clean — and never shipped.
        return state(blocked=UNREADABLE, detail=_tail(git_dir_result))
    git_dir = Path(git_dir_raw)
    if not git_dir.is_absolute():
        # `git rev-parse --git-dir` answers a bare `.git` at a repo root and an
        # absolute path in a linked worktree (verified) — resolve either.
        git_dir = path / git_dir
    operation = _operation_in_progress(git_dir)
    if operation is not None or unmerged:
        detail = operation or "unmerged paths"
        if unmerged:
            detail = f"{detail}; unresolved: {', '.join(sorted(unmerged)[:5])}"
        return state(blocked=IN_PROGRESS, detail=detail)
```

**Edit 10 — the dirty judgement.** Replace:

```python
    lines = [ln for ln in (status.stdout or "").splitlines() if ln.strip()]
    if any(not ln.startswith("??") for ln in lines):
        return state(blocked=DIRTY)
    untracked_only = bool(lines)
```

with:

```python
    # ANY porcelain output at all — tracked edits, untracked files, or both —
    # means the working tree is not HEAD, and the working tree is what gets
    # sent. Returning HERE is also what keeps origin out of the dirty path: the
    # `ls-remote` below is never reached, because origin's tip cannot change
    # what the run host executes once it is materializing a scratch ref.
    if lines:
        return state(dirty=True, head_sha=head_sha)
```

**Edit 11 — drop `untracked_only` from the origin verdicts.** Replace:

```python
    tip, error = _origin_tip(shell, path, branch)
    if error is not None:
        return state(blocked=ORIGIN_UNREACHABLE, detail=error,
                     untracked_only=untracked_only, head_sha=head_sha)
    if tip is None:
        return state(untracked_only=untracked_only, head_sha=head_sha,
                     needs_push=True, push_reason="not on origin")
    if head_sha == tip:
        return state(untracked_only=untracked_only, head_sha=head_sha)
```

with:

```python
    tip, error = _origin_tip(shell, path, branch)
    if error is not None:
        return state(blocked=ORIGIN_UNREACHABLE, detail=error, head_sha=head_sha)
    if tip is None:
        return state(head_sha=head_sha, needs_push=True,
                     push_reason="not on origin")
    if head_sha == tip:
        return state(head_sha=head_sha)
```

and replace:

```python
    if ancestor.returncode == 0:
        return state(untracked_only=untracked_only, head_sha=head_sha,
                     needs_push=True, push_reason="ahead of origin")
    return state(
        blocked=BEHIND_ORIGIN, untracked_only=untracked_only, head_sha=head_sha,
        detail=f"origin/{branch} is at {tip[:12]}, which is not in your history",
    )
```

with:

```python
    if ancestor.returncode == 0:
        return state(head_sha=head_sha, needs_push=True,
                     push_reason="ahead of origin")
    return state(
        blocked=BEHIND_ORIGIN, head_sha=head_sha,
        detail=f"origin/{branch} is at {tip[:12]}, which is not in your history",
    )
```

**Edit 12 — `inspect`.** Replace the signature line:

```python
def inspect(task, shell, *, repos: list[str] | None = None) -> Preflight:
```

with:

```python
def inspect(task, shell, *, repos: list[str] | None = None, config=None) -> Preflight:
```

Append this paragraph to its docstring, immediately before the closing `"""`:

```
    `config` (the workspace's `WorkspaceConfig`, optional) is used for one thing:
    resolving each repo to its TOP-LEVEL git repo, so a `git_root` child and its
    parent — one git repository, one tree — dedupe to a single entry in `dirty`
    (spec ac7). Without it every repo is its own git repo, which is correct for
    every workspace that has no `git_root` children.
```

Replace the states comprehension:

```python
    states = [
        _inspect_repo(shell, repo, Path(raw_path), task.branch)
        for repo, raw_path in sorted(worktrees.items())
        if selected is None or repo in selected
    ]
```

with:

```python
    repo_configs = getattr(config, "repos", {}) if config is not None else {}

    def _git_repo_of(repo: str) -> str:
        rc = repo_configs.get(repo)
        return rc.git_root if rc is not None and rc.git_root else repo

    states = [
        _inspect_repo(shell, repo, Path(raw_path), task.branch,
                      git_repo=_git_repo_of(repo))
        for repo, raw_path in sorted(worktrees.items())
        if selected is None or repo in selected
    ]
```

Replace the synthetic missing-worktree state's field line:

```python
                untracked_only=False, needs_push=False, push_reason=None,
```

with:

```python
                dirty=False, needs_push=False, push_reason=None,
                git_repo=_git_repo_of(repo),
```

Replace the `return Preflight(...)` block:

```python
    return Preflight(
        states=states,
        blocked=[s for s in states if s.blocked_reason is not None],
        to_push=[s for s in states if s.needs_push],
        untracked=[s for s in states if s.untracked_only],
    )
```

with:

```python
    # One transfer per GIT repository: a `git_root` child and its parent share
    # one tree, so pushing both would send the same objects twice under two
    # names, and the run host materializes the parent either way (spec ac7).
    # The parent's own state is preferred as the survivor when it is in scope,
    # because the parent is the name the run host resolves the child under.
    dirty_states = [s for s in states if s.dirty]
    dirty: list[RepoState] = []
    seen_git_repos: set[str] = set()
    for s in [d for d in dirty_states if d.repo == d.git_repo] + dirty_states:
        if s.git_repo in seen_git_repos:
            continue
        seen_git_repos.add(s.git_repo)
        dirty.append(s)

    return Preflight(
        states=states,
        blocked=[s for s in states if s.blocked_reason is not None],
        to_push=[s for s in states if s.needs_push],
        dirty=dirty,
    )
```

**Edit 13 — `blocked_message`'s reason order.** Replace:

```python
    for reason in (DIRTY, WRONG_BRANCH, BEHIND_ORIGIN, MISSING_WORKTREE,
                   UNREADABLE, ORIGIN_UNREACHABLE):
```

with:

```python
    for reason in (IN_PROGRESS, WRONG_BRANCH, BEHIND_ORIGIN, MISSING_WORKTREE,
                   UNREADABLE, ORIGIN_UNREACHABLE):
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_remote_preflight.py -q`
Expected: all pass. Then confirm the ten fixes survived, by name:

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
uv run pytest tests/core/test_remote_preflight.py -q -v -k "\
failed_git_status or stale_remote_tracking or origin_ahead or missing_worktree or \
outside_the_tasks_worktrees or another_branch or detached or torn_pair or \
landing_between or one_ref_failing or diverged"
```
Expected: every one of those `PASSED`. They are fixes 1, 2, 3, 4, 6, 8, 9 and 10. If any is now failing or missing, an edit above went too wide — revert and re-apply that edit only.

Also confirm `push()` was not touched:

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
git diff -U0 src/mship/core/remote_preflight.py | grep -c '^[-+].*head_sha}:refs/heads/'
```
Expected: `0` — the push refspec line (fix 7) appears in neither side of the diff.

- [ ] **Step 5: Commit**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
git add src/mship/core/remote_preflight.py tests/core/test_remote_preflight.py
git commit -m "feat(remote): preflight routes a dirty tree to transfer, refuses mid-operation"
mship journal "preflight: DIRTY->dirty transfer, IN_PROGRESS refusal ahead of WRONG_BRANCH, origin query clean-path only; push() untouched, 0 tests deleted" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=7 -->
### Task 7: Synthesize a commit without touching anything local

**Files:**
- Create: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/src/mship/core/run_transfer.py`
- Test: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/tests/core/test_run_transfer.py`

This is the load-bearing task. Every test here runs against a **real temporary git repository** with a **real `ShellRunner`** — a mocked shell would prove nothing about git's actual behaviour, which is the entire risk (spec ac20).

- [ ] **Step 1: Write the failing test**

Create `tests/core/test_run_transfer.py`:

```python
"""Commit synthesis: a real commit object whose tree is the working tree, built
without touching the operator's repository.

Real git, real repositories, real ShellRunner throughout. The spec's own risk
list says the failure here is SILENT — an empty temporary index drops
tracked-and-gitignored files with no error — so nothing in this file is allowed
to be asserted against a mock.
"""
import os
import subprocess
from pathlib import Path

import pytest

from mship.core.run_transfer import RunTransferError, synthesize_commit
from mship.util.shell import ShellRunner

# Keep the operator's global git config out of these repos, exactly as
# tests/core/test_remote_preflight.py:581 does and for the same reason.
_GIT_ENV = {
    **os.environ,
    "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull,
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
}


def _git(*args: str, cwd: Path) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, capture_output=True, text=True, check=True,
        env=_GIT_ENV,
    ).stdout.strip()


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    """A repo on a feature branch with one commit, a .gitignore, and a
    deliberately ignored file."""
    path = tmp_path / "api"
    path.mkdir()
    _git("init", "-q", "-b", "main", ".", cwd=path)
    (path / "a.txt").write_text("one\n")
    (path / ".gitignore").write_text("ignored.txt\n")
    _git("add", "-A", cwd=path)
    _git("commit", "-qm", "init", cwd=path)
    _git("checkout", "-q", "-b", "feat/x", cwd=path)
    return path


def _head(repo: Path) -> str:
    return _git("rev-parse", "HEAD", cwd=repo)


def _dirty(repo: Path) -> None:
    (repo / "a.txt").write_text("one\nedited\n")
    (repo / "untracked.txt").write_text("scratch\n")
    (repo / "ignored.txt").write_text("secret\n")


def _tree_files(repo: Path, sha: str) -> list[str]:
    return _git("ls-tree", "-r", "--name-only", sha, cwd=repo).splitlines()


def test_the_synthesized_tree_is_the_working_tree(repo):
    """ac1: what the run host is asked to materialize contains the modified file
    exactly as it is on disk."""
    _dirty(repo)
    sha = synthesize_commit(ShellRunner(), repo, base_sha=_head(repo))

    blob = _git("show", f"{sha}:a.txt", cwd=repo)
    assert blob == "one\nedited"
    assert (repo / "a.txt").read_text() == blob + "\n"


def test_untracked_files_travel_and_gitignored_ones_do_not(repo):
    """ac11, pinned in both directions."""
    _dirty(repo)
    files = _tree_files(repo, synthesize_commit(ShellRunner(), repo, base_sha=_head(repo)))
    assert "untracked.txt" in files
    assert "ignored.txt" not in files


def test_a_tracked_file_that_is_also_gitignored_survives(repo):
    """ac1's second half, and the spec's top risk. Verified failure mode: with
    an EMPTY temporary index `git add -A` silently skips this file, because git
    will not add an ignored path that is not already in the index — the run host
    would then execute a tree missing a file the operator can plainly see.
    Seeding the scratch index from the base commit is what keeps it."""
    (repo / ".gitignore").write_text("ignored.txt\na.txt\n")
    files = _tree_files(repo, synthesize_commit(ShellRunner(), repo, base_sha=_head(repo)))
    assert "a.txt" in files


def test_a_modified_tracked_and_gitignored_file_carries_its_WORKING_content(repo):
    """Seeding from the base commit must not mean shipping the base commit's
    version: it seeds, then `git add -A` overwrites from the working tree."""
    (repo / ".gitignore").write_text("a.txt\n")
    (repo / "a.txt").write_text("edited while ignored\n")
    sha = synthesize_commit(ShellRunner(), repo, base_sha=_head(repo))
    assert _git("show", f"{sha}:a.txt", cwd=repo) == "edited while ignored"


def test_a_deleted_tracked_file_is_absent_from_the_tree(repo):
    (repo / "a.txt").unlink()
    sha = synthesize_commit(ShellRunner(), repo, base_sha=_head(repo))
    assert "a.txt" not in _tree_files(repo, sha)


def test_local_state_is_identical_before_and_after(repo):
    """ac2, the destructive-surprise guard: `git add -A` against the DEFAULT
    index would stage the operator's work in progress."""
    _dirty(repo)
    def snapshot():
        return {
            "head": _git("rev-parse", "HEAD", cwd=repo),
            "branch": _git("rev-parse", "--abbrev-ref", "HEAD", cwd=repo),
            "status": _git("status", "--porcelain", cwd=repo),
            "index": _git("diff", "--cached", "--name-only", cwd=repo),
            "branches": _git("branch", "--list", cwd=repo),
        }

    before = snapshot()
    sha = synthesize_commit(ShellRunner(), repo, base_sha=before["head"])
    after = snapshot()

    assert after == before
    assert before["index"] == ""                     # nothing was staged
    assert sha != before["head"]


def test_the_commit_is_on_no_branch(repo):
    """ac2/ac14: it is not history anyone can build on."""
    _dirty(repo)
    base = _head(repo)
    sha = synthesize_commit(ShellRunner(), repo, base_sha=base)
    assert _git("branch", "--contains", sha, "--all", cwd=repo) == ""
    assert _git("rev-parse", f"{sha}^", cwd=repo) == base


def test_the_parent_is_the_sha_it_was_given_not_a_re_resolved_head(repo):
    """Fix 9 carried onto this path. `inspect` certifies a sha; something else
    committing in this worktree in the meantime (a subagent, a background job —
    this workspace's normal pattern) must not silently re-root the snapshot."""
    _dirty(repo)
    certified = _head(repo)

    (repo / "raced.txt").write_text("raced\n")
    _git("add", "raced.txt", cwd=repo)
    _git("commit", "-qm", "raced after inspection", cwd=repo)
    assert _head(repo) != certified

    sha = synthesize_commit(ShellRunner(), repo, base_sha=certified)
    assert _git("rev-parse", f"{sha}^", cwd=repo) == certified


def test_it_works_in_a_repo_with_no_configured_identity(tmp_path, monkeypatch):
    """`git commit-tree` needs an author; taking it from git config would make
    synthesis fail on a machine that has none. It is pinned to mship instead."""
    for var in ("GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL",
                "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL"):
        monkeypatch.delenv(var, raising=False)
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_SYSTEM", os.devnull)

    path = tmp_path / "no-identity"
    path.mkdir()
    _git("init", "-q", "-b", "main", ".", cwd=path)
    (path / "a.txt").write_text("one\n")
    _git("add", "-A", cwd=path)
    _git("commit", "-qm", "init", cwd=path)
    (path / "a.txt").write_text("edited\n")

    sha = synthesize_commit(ShellRunner(), path, base_sha=_head(path))
    assert "mship" in _git("show", "-s", "--format=%an <%ae>", sha, cwd=path)


def test_commit_signing_cannot_block_synthesis(repo):
    """`git commit-tree` does not honour `commit.gpgsign` (verified with
    `-c commit.gpgsign=true -c gpg.program=/bin/false`), so an operator with
    signing configured cannot be left waiting on a passphrase prompt that a
    captured-output subprocess never shows anyone."""
    _git("config", "commit.gpgsign", "true", cwd=repo)
    _git("config", "gpg.program", "/bin/false", cwd=repo)
    _dirty(repo)
    assert synthesize_commit(ShellRunner(), repo, base_sha=_head(repo))


def test_synthesis_from_a_subdirectory_still_captures_the_whole_repo(tmp_path):
    """A `git_root` child's path is a subdirectory of its parent's worktree, so
    synthesis may be invoked there. Verified: `git add -A` with no pathspec is
    whole-tree since git 2.0, and `git write-tree` writes the full index."""
    mono = tmp_path / "mono"
    (mono / "pkg").mkdir(parents=True)
    _git("init", "-q", "-b", "main", ".", cwd=mono)
    (mono / "root.txt").write_text("root\n")
    (mono / "pkg" / "c.txt").write_text("child\n")
    _git("add", "-A", cwd=mono)
    _git("commit", "-qm", "init", cwd=mono)
    (mono / "root.txt").write_text("ROOT-EDIT\n")
    (mono / "pkg" / "c.txt").write_text("CHILD-EDIT\n")

    sha = synthesize_commit(ShellRunner(), mono / "pkg", base_sha=_head(mono))

    assert sorted(_tree_files(mono, sha)) == ["pkg/c.txt", "root.txt"]
    assert _git("show", f"{sha}:root.txt", cwd=mono) == "ROOT-EDIT"


def test_a_clean_tree_still_synthesizes_the_same_content(repo):
    """Not a path the CLI takes (clean repos go to origin), but the function
    must not depend on there being changes."""
    base = _head(repo)
    sha = synthesize_commit(ShellRunner(), repo, base_sha=base)
    assert _git("rev-parse", f"{sha}^{{tree}}", cwd=repo) == _git(
        "rev-parse", f"{base}^{{tree}}", cwd=repo
    )


def test_a_git_failure_raises_a_named_error(tmp_path):
    not_a_repo = tmp_path / "plain"
    not_a_repo.mkdir()
    with pytest.raises(RunTransferError) as exc:
        synthesize_commit(ShellRunner(), not_a_repo, base_sha="HEAD")
    assert "read-tree" in str(exc.value)
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_run_transfer.py -q`
Expected: collection error — `ModuleNotFoundError: No module named 'mship.core.run_transfer'`

- [ ] **Step 3: Write the implementation**

Create `src/mship/core/run_transfer.py`:

```python
"""Client side of an exact-copy remote run: turn a working tree into a commit,
and hand that commit to the run host.

Real history goes to origin; throwaway state goes host to host and never touches
origin. This module owns the second half of that rule. `core/remote_preflight.py`
decides which repos take which path; this one carries them.
"""
from __future__ import annotations

import os
import shlex
import tempfile
from pathlib import Path

from mship.core.run_ref import run_ref

# Pinned identity for synthesized commits. Deliberately NOT the operator's: this
# is machinery, not a commit they made (spec ac13), and pinning it also means
# synthesis works in a repo with no `user.email` configured.
_IDENTITY_NAME = "mship run"
_IDENTITY_EMAIL = "mship-run@localhost"

_MESSAGE = "mship --remote: working-tree snapshot (throwaway, not real history)"


class RunTransferError(Exception):
    """A git command needed to synthesize or deliver the working tree failed.

    Always names the command and git's own stderr: using git's transport rather
    than a hand-rolled one is partly FOR those diagnostics, so they are passed
    through rather than replaced.
    """


def _checked(shell, command: str, cwd: Path, env: dict[str, str]) -> str:
    result = shell.run(command, cwd=cwd, env=env)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        raise RunTransferError(
            f"`{command}` failed in {cwd}: {detail or f'exit {result.returncode}'}"
        )
    return result.stdout or ""


def synthesize_commit(shell, repo_root: Path, *, base_sha: str) -> str:
    """A real commit object whose tree is byte-identical to the working tree at
    `repo_root`, created without touching the repository's own state.

    The TEMPORARY INDEX is load-bearing, not an implementation detail. `git add
    -A` against the DEFAULT index would stage the operator's work in progress —
    a destructive surprise on their real repository — so every command here runs
    with `GIT_INDEX_FILE` pointed at a scratch file that is deleted afterwards.
    HEAD, the current branch, the real index and `git status` output are all
    unchanged when this returns (verified against real git), and the commit
    belongs to no branch.

    `git read-tree <base_sha>` seeds the scratch index BEFORE `git add -A`.
    Without that seed a file that is both tracked and gitignored is silently
    dropped from the tree — git will not add an ignored path that is not already
    in the index — which is exactly the "the remote ran something subtly
    different" failure this feature exists to remove. Verified against real git.

    `base_sha` is the sha `remote_preflight.inspect` certified HEAD to be at, not
    the string `HEAD`. Re-resolving HEAD here would let anything that commits in
    this worktree between inspection and synthesis (a subagent, a background job)
    re-root the snapshot on a commit nothing verified — the same bypass
    `remote_preflight.push` closes for the origin path.

    `git commit-tree` rather than `git commit`: it writes an object and moves no
    ref, and (verified) it does not honour `commit.gpgsign`, so an operator with
    commit signing configured cannot be blocked on a passphrase prompt a
    captured-output subprocess would never show them.

    Untracked files are included — they are part of what the operator sees, and
    they now travel only between the operator's own two machines. Gitignored
    files are not; `git add -A` never picks them up.

    Safe to call from a SUBDIRECTORY of the repository (a `git_root` child):
    `git add -A` with no pathspec is whole-tree since git 2.0 and `git
    write-tree` writes the full index, so the result is the same tree either
    way. Verified.
    """
    with tempfile.TemporaryDirectory(prefix="mship-run-index-") as tmp:
        env = {
            "GIT_INDEX_FILE": str(Path(tmp) / "index"),
            "GIT_AUTHOR_NAME": _IDENTITY_NAME,
            "GIT_AUTHOR_EMAIL": _IDENTITY_EMAIL,
            "GIT_COMMITTER_NAME": _IDENTITY_NAME,
            "GIT_COMMITTER_EMAIL": _IDENTITY_EMAIL,
        }
        base = shlex.quote(base_sha)
        _checked(shell, f"git read-tree {base}", repo_root, env)
        _checked(shell, "git add -A", repo_root, env)
        tree = _checked(shell, "git write-tree", repo_root, env).strip()
        sha = _checked(
            shell,
            f"git commit-tree {shlex.quote(tree)} -p {base} "
            f"-m {shlex.quote(_MESSAGE)}",
            repo_root, env,
        ).strip()
    return sha
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_run_transfer.py -q`
Expected: `14 passed`

- [ ] **Step 5: Commit**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
git add src/mship/core/run_transfer.py tests/core/test_run_transfer.py
git commit -m "feat(remote): synthesize a working-tree commit through a temporary index"
mship journal "synthesize_commit: temp index + read-tree seed + pinned base sha; HEAD/branch/index/status proven unchanged on real repos" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=8 -->
### Task 8: Push the synthesized commit to the run host

**Files:**
- Modify: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/src/mship/core/run_transfer.py` (append)
- Test: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/tests/core/test_run_transfer.py` (append)

- [ ] **Step 1: Write the failing tests**

Append to `tests/core/test_run_transfer.py`:

```python
# --- delivery: where the commit goes, and where the token does NOT -----------

from mship.core.run_host import RunHostConnection
from mship.core.run_transfer import delete_run_ref, extra_header_env, push_run_ref
from mship.util.shell import ShellResult


class RecordingShell:
    """Records every command with the env it was given — the only way to assert
    where the bearer did and did not go. `ShellRunner.run` takes a command
    STRING (shell=True), so `calls[i][0]` is the whole command line."""

    def __init__(self, returncode: int = 0, stderr: str = ""):
        self.calls: list[tuple[str, Path, dict]] = []
        self._returncode = returncode
        self._stderr = stderr

    def run(self, command, cwd=None, env=None, **kw):
        self.calls.append((command, Path(cwd), dict(env or {})))
        return ShellResult(returncode=self._returncode, stdout="", stderr=self._stderr)


CONN = RunHostConnection(url="https://mac-abc.relay.example", token="tok-secret")


def test_the_push_targets_the_per_task_per_repo_scratch_ref(repo):
    """ac7: two tasks or two repos cannot overwrite each other."""
    shell = RecordingShell()
    ref = push_run_ref(shell, repo, conn=CONN, repo="api", task="t1", sha="abc123")

    assert ref == "refs/mship/run/t1/api"
    command, cwd, _env = shell.calls[0]
    assert "abc123:refs/mship/run/t1/api" in command
    assert cwd == repo


def test_each_run_force_updates_its_own_ref(repo):
    """ac8: the ref is replaced per run — safe only because nothing else writes
    this namespace, which is why it must never be a branch."""
    shell = RecordingShell()
    push_run_ref(shell, repo, conn=CONN, repo="api", task="t1", sha="abc123")
    assert shell.calls[0][0].startswith("git push --force ")


def test_the_push_goes_to_the_run_host_not_origin(repo):
    """ac3: origin is not in this path at all."""
    shell = RecordingShell()
    push_run_ref(shell, repo, conn=CONN, repo="api", task="t1", sha="abc123")
    command = shell.calls[0][0]
    assert "https://mac-abc.relay.example/git/api" in command
    assert "origin" not in command


def test_the_bearer_is_supplied_out_of_band_only(repo):
    """ac4, all three prohibitions at once: not in the remote URL, not written
    to any git config file, and above all not in argv — `/proc/<pid>/cmdline` is
    world-readable, `/proc/<pid>/environ` is not."""
    shell = RecordingShell()
    push_run_ref(shell, repo, conn=CONN, repo="api", task="t1", sha="abc123")
    command, _cwd, env = shell.calls[0]

    assert "tok-secret" not in command
    assert "-c" not in command.split()                    # no `git -c http.extraHeader=`
    assert not any(c[0].startswith("git config") for c in shell.calls)
    assert "Authorization: Bearer tok-secret" in env.values()
    assert "http.extraHeader" in env.values()


def test_the_push_never_prompts_for_credentials(repo):
    """A stale token must fail the command, not hang the CLI on a prompt that a
    captured-output subprocess never shows anyone."""
    shell = RecordingShell()
    push_run_ref(shell, repo, conn=CONN, repo="api", task="t1", sha="abc123")
    assert shell.calls[0][2]["GIT_TERMINAL_PROMPT"] == "0"


def test_the_header_config_appends_to_inherited_git_config_entries(monkeypatch):
    """tests/conftest.py:41 sets GIT_CONFIG_COUNT=2 suite-wide to disable commit
    signing. Claiming index 0 would silently re-enable signing everywhere."""
    monkeypatch.setenv("GIT_CONFIG_COUNT", "2")
    env = extra_header_env("tok")
    assert env["GIT_CONFIG_COUNT"] == "3"
    assert env["GIT_CONFIG_KEY_2"] == "http.extraHeader"
    assert "GIT_CONFIG_KEY_0" not in env          # the inherited pair is untouched


def test_a_missing_count_starts_at_zero(monkeypatch):
    monkeypatch.delenv("GIT_CONFIG_COUNT", raising=False)
    env = extra_header_env("tok")
    assert env["GIT_CONFIG_COUNT"] == "1"
    assert env["GIT_CONFIG_KEY_0"] == "http.extraHeader"


def test_a_nonsense_count_does_not_crash_the_push(monkeypatch):
    monkeypatch.setenv("GIT_CONFIG_COUNT", "not-a-number")
    assert extra_header_env("tok")["GIT_CONFIG_COUNT"] == "1"


def test_a_failed_push_raises_with_gits_own_message(repo):
    shell = RecordingShell(returncode=1, stderr="fatal: unable to access\n")
    with pytest.raises(RunTransferError) as exc:
        push_run_ref(shell, repo, conn=CONN, repo="api", task="t1", sha="abc123")
    assert "unable to access" in str(exc.value)
    assert "api" in str(exc.value)


def test_delete_uses_the_colon_refspec_form(repo):
    """ac8. `--delete <ref>` resolves against the advertisement and errors when
    the ref is absent; the `:<ref>` form is a no-op success (verified against
    real git, locally and over HTTP), so cleanup needs no existence probe."""
    shell = RecordingShell()
    delete_run_ref(shell, repo, conn=CONN, repo="api", task="t1")
    command = shell.calls[0][0]
    assert ":refs/mship/run/t1/api" in command
    assert "--delete" not in command
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_run_transfer.py -q`
Expected: collection error — `ImportError: cannot import name 'push_run_ref' from 'mship.core.run_transfer'`

- [ ] **Step 3: Write the implementation**

Append to `src/mship/core/run_transfer.py`:

```python
def extra_header_env(token: str) -> dict[str, str]:
    """Env that makes git send `Authorization: Bearer <token>` on BOTH legs of
    the push (the `info/refs` GET and the `git-receive-pack` POST — verified).

    Carried as git's ENV-based config (`GIT_CONFIG_COUNT` / `_KEY_n` /
    `_VALUE_n`, git >= 2.31) rather than `git -c http.extraHeader=…`: argv is
    world-readable through `/proc/<pid>/cmdline`, a process's environment is
    not. Nothing is written to any git config file, and the token never appears
    in the remote URL (spec ac4).

    APPENDS at the next free index instead of claiming index 0 — the test suite
    sets its own `GIT_CONFIG_COUNT` entries (tests/conftest.py disables commit
    signing that way), and overwriting them would silently drop them.

    `GIT_TERMINAL_PROMPT=0` makes a rejected push FAIL rather than block on an
    interactive credential prompt.
    """
    try:
        index = int(os.environ.get("GIT_CONFIG_COUNT", "0"))
    except ValueError:
        index = 0
    return {
        "GIT_CONFIG_COUNT": str(index + 1),
        f"GIT_CONFIG_KEY_{index}": "http.extraHeader",
        f"GIT_CONFIG_VALUE_{index}": f"Authorization: Bearer {token}",
        "GIT_TERMINAL_PROMPT": "0",
    }


def _receive_url(conn, repo: str) -> str:
    """The run host's scoped receive endpoint for `repo`. git appends
    `/info/refs?service=git-receive-pack` and `/git-receive-pack` itself."""
    return f"{conn.url}/git/{repo}"


def push_run_ref(shell, repo_root: Path, *, conn, repo: str, task: str, sha: str) -> str:
    """Push `sha` straight to the run host's scratch ref, and return that ref.

    Origin is not in this path: uncommitted work — including untracked scratch
    files — goes only between the operator's own two machines.

    `git push` performs the have/want negotiation itself, so only objects the
    run host is missing cross the wire, with no need to compute what it already
    has. `--force` is required because each run replaces the last, and is safe
    precisely because nothing else writes this namespace.

    `repo` is the TOP-LEVEL git repo's name — the receive endpoint refuses a
    `git_root` child, which has no git directory of its own.
    """
    ref = run_ref(task, repo)
    url = _receive_url(conn, repo)
    result = shell.run(
        f"git push --force {shlex.quote(url)} {shlex.quote(sha)}:{ref}",
        cwd=repo_root, env=extra_header_env(conn.token),
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        raise RunTransferError(
            f"could not send {repo}'s working tree to the run host at {url}: "
            f"{detail or f'exit {result.returncode}'}"
        )
    return ref


def delete_run_ref(shell, repo_root: Path, *, conn, repo: str, task: str) -> None:
    """Delete this task's scratch ref from the run host.

    Deleting a ref that is not there exits 0 with a warning (verified against
    real git, locally and over HTTP), so there is nothing to ask first — and the
    `:<ref>` refspec form is required, because `--delete <ref>` resolves against
    the advertisement and errors when the ref is absent.
    """
    ref = run_ref(task, repo)
    url = _receive_url(conn, repo)
    result = shell.run(
        f"git push --force {shlex.quote(url)} :{ref}",
        cwd=repo_root, env=extra_header_env(conn.token),
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        raise RunTransferError(
            f"could not delete {ref} from the run host at {url}: "
            f"{detail or f'exit {result.returncode}'}"
        )
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_run_transfer.py -q`
Expected: `24 passed`

- [ ] **Step 5: Commit**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
git add src/mship/core/run_transfer.py tests/core/test_run_transfer.py
git commit -m "feat(remote): push the synthesized commit host-to-host, bearer out of band"
mship journal "push_run_ref/delete_run_ref: force refspec on the run ref; token via appended GIT_CONFIG env, never URL/argv/config" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=9 -->
### Task 9: Tell the run host which repos to take from a scratch ref

**Files:**
- Modify: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/src/mship/core/remote_client.py` (`exec_remote`, line 230)
- Modify: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/src/mship/core/serve.py` (`ExecBody`, line 114)
- Test: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/tests/cli/test_remote_dispatch.py` (append)
- Test: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/tests/core/test_serve_exec.py` (append)

The client sends **repo names**, never ref strings: the run host derives the ref itself from the task and repo names it has already validated, so no client-controlled ref ever reaches a shell there.

- [ ] **Step 1: Write the failing tests**

Append to `tests/cli/test_remote_dispatch.py`:

```python
# --- exact copy: which repos come from a scratch ref -------------------------

def test_exec_remote_sends_run_ref_repos_when_there_are_any():
    recorder: dict = {}
    conn = RunHostConnection(url="http://remote.example", token="tok")

    remote_client.exec_remote(
        verb="run", conn=conn, task="t1", repos=["api", "web"],
        run_ref_repos=["api"], print_fn=lambda _l: None,
        transport=_mock_transport(_recording_handler(recorder, _frame(["ok\n"], exit_code=0))),
    )

    assert recorder["json"] == {
        "task": "t1", "repos": ["api", "web"], "kind": "all", "run_ref_repos": ["api"],
    }


def test_exec_remote_omits_the_key_entirely_when_nothing_was_transferred():
    """ac9: a clean run must be byte-identical on the wire to today's, so a run
    host on an older mship keeps working."""
    recorder: dict = {}
    conn = RunHostConnection(url="http://remote.example", token="tok")

    remote_client.exec_remote(
        verb="run", conn=conn, task="t1", repos=["api"], print_fn=lambda _l: None,
        transport=_mock_transport(_recording_handler(recorder, _frame(["ok\n"], exit_code=0))),
    )

    assert recorder["json"] == {"task": "t1", "repos": ["api"], "kind": "all"}
```

Append to `tests/core/test_serve_exec.py`:

```python
def test_exec_body_accepts_run_ref_repos(tmp_path, monkeypatch):
    fake = _FakeShellRunner(streaming_proc=_FakeProc(stdout_lines=["ok\n"]))
    _patch_shell(monkeypatch, fake)
    client = TestClient(_app(tmp_path))
    r = client.post(
        "/exec/run", json={"task": "t1", "repos": ["api"], "run_ref_repos": ["api"]},
    )
    assert r.status_code == 200


def test_exec_body_defaults_run_ref_repos_to_empty(tmp_path, monkeypatch):
    """An older client omits the key; the host must behave exactly as before."""
    fake = _FakeShellRunner(streaming_proc=_FakeProc(stdout_lines=["ok\n"]))
    _patch_shell(monkeypatch, fake)
    r = TestClient(_app(tmp_path)).post("/exec/run", json={"task": "t1", "repos": ["api"]})
    assert r.status_code == 200
    assert any("fetch origin feat/t1" in cmd for cmd, _cwd in fake.run_calls)
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/cli/test_remote_dispatch.py tests/core/test_serve_exec.py -q -k run_ref_repos`
Expected: FAIL — `TypeError: exec_remote() got an unexpected keyword argument 'run_ref_repos'`, and the serve test 422s because `ExecBody` forbids nothing but does not carry the field through.

- [ ] **Step 3: Write the implementation**

In `src/mship/core/remote_client.py`, add the parameter to `exec_remote`'s signature, immediately after `captures_dir_for`:

```python
    captures_dir_for: Path | None = None,
    run_ref_repos: list[str] | None = None,
```

Add this paragraph to `exec_remote`'s docstring, immediately after the paragraph beginning "Prints each stdout/stderr line as it arrives":

```
    `run_ref_repos` (optional) names the repos this host should materialize from
    its own local scratch ref for this task rather than from origin — the
    operator's working tree was pushed straight to it (see
    `mship.core.run_transfer`). Repo NAMES, not refs: the host builds the ref
    itself from values it has already validated. Omitted from the request body
    entirely when empty, so a clean run's wire format is unchanged.
```

And immediately after the existing body construction:

```python
    body: dict = {"task": task, "repos": repos, "kind": kind}
    if platform is not None:
        body["platform"] = platform
```

add:

```python
    if run_ref_repos:
        body["run_ref_repos"] = list(run_ref_repos)
```

In `src/mship/core/serve.py`, replace `ExecBody` (line 114) with:

```python
class ExecBody(BaseModel):
    """POST /exec/{verb} request body — see `mship.core.remote_exec` for the
    full wire contract (how the response streams task output + exit code)."""
    task: str
    repos: list[str]
    platform: str | None = None
    # Only meaningful for verb == "capture"; mirrors `cli/capture.py`'s
    # `--kind` default. Optional so run/build callers can omit it.
    kind: str = "all"
    # Repos whose working tree the caller pushed to this host's own scratch ref
    # for this task (spec remote-exact-copy). Materialized from that LOCAL ref
    # instead of from origin — no fetch. Absent or empty means today's behaviour
    # for every repo in the request, so an older client is unaffected.
    run_ref_repos: list[str] = []
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/cli/test_remote_dispatch.py tests/core/test_serve_exec.py -q -k run_ref_repos`
Expected: `4 passed`.

Then run both suites in full:

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/cli/test_remote_dispatch.py tests/core/test_serve_exec.py -q`
Expected: `tests/core/test_serve_exec.py` fully green. `tests/cli/test_remote_dispatch.py` still has the pre-#419-semantics preflight tests Task 12 owns — expect exactly two failures, `test_remote_run_is_refused_when_the_worktree_is_dirty` and `test_a_task_missing_from_a_later_state_read_does_not_skip_the_preflight`, both because a dirty repo no longer refuses. Any OTHER failure means Task 6 went too wide; investigate before continuing.

- [ ] **Step 5: Commit**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
git add src/mship/core/remote_client.py src/mship/core/serve.py tests/cli/test_remote_dispatch.py tests/core/test_serve_exec.py
git commit -m "feat(remote): carry run_ref_repos on the exec request"
mship journal "exec wire: run_ref_repos (names, not refs); omitted when empty so clean runs are byte-identical" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=10 -->
### Task 10: Materialize from a local ref, with no fetch

**Files:**
- Modify: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/src/mship/core/remote_exec.py` (`materialize_worktree`, line 182)
- Test: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/tests/core/test_serve_exec.py` (append)

- [ ] **Step 1: Write the failing tests**

Append to `tests/core/test_serve_exec.py`:

```python
# --- exact copy: materializing from a pushed scratch ref ---------------------

import os
import subprocess

from mship.util.shell import ShellRunner

_REAL_GIT_ENV = {
    **os.environ,
    "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull,
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
}


def _real_git(*args: str, cwd: Path) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, capture_output=True, text=True, check=True,
        env=_REAL_GIT_ENV,
    ).stdout.strip()


def _host_repo_with_run_ref(tmp_path: Path) -> tuple[Path, str, str]:
    """A run-host-shaped repo: a branch tip, plus a scratch ref holding
    DIFFERENT content, as a push from the operator would have left it."""
    repo = tmp_path / "hostrepo"
    repo.mkdir()
    _real_git("init", "-q", "-b", "main", ".", cwd=repo)
    (repo / "a.txt").write_text("branch tip\n")
    _real_git("add", "-A", cwd=repo)
    _real_git("commit", "-qm", "tip", cwd=repo)
    _real_git("branch", "-f", "feat/t1", "HEAD", cwd=repo)
    tip = _real_git("rev-parse", "HEAD", cwd=repo)

    (repo / "a.txt").write_text("what the operator is editing\n")
    (repo / "untracked.txt").write_text("scratch\n")
    _real_git("add", "-A", cwd=repo)
    _real_git("commit", "-qm", "synthesized", cwd=repo)
    scratch = _real_git("rev-parse", "HEAD", cwd=repo)
    _real_git("update-ref", "refs/mship/run/t1/api", scratch, cwd=repo)

    _real_git("reset", "-q", "--hard", tip, cwd=repo)
    return repo, tip, scratch


def test_materialize_from_a_run_ref_creates_a_detached_worktree(tmp_path):
    """ac10, first materialization: no fetch at all, and HEAD is left detached
    because the scratch commit is throwaway state, not a branch."""
    repo, _tip, scratch = _host_repo_with_run_ref(tmp_path)
    worktree = tmp_path / "wt" / "api"

    remote_exec.materialize_worktree(
        ShellRunner(), repo, worktree, "feat/t1",
        repo_name="api", run_ref="refs/mship/run/t1/api",
    )

    assert _real_git("rev-parse", "HEAD", cwd=worktree) == scratch
    assert (worktree / "a.txt").read_text() == "what the operator is editing\n"
    assert (worktree / "untracked.txt").exists()


def test_the_run_ref_worktree_is_detached_not_a_branch(tmp_path):
    """ac14 on the run host: a branch pointing at a synthesized commit would
    dress throwaway state up as history."""
    repo, _tip, _scratch = _host_repo_with_run_ref(tmp_path)
    worktree = tmp_path / "wt" / "api"
    remote_exec.materialize_worktree(
        ShellRunner(), repo, worktree, "feat/t1",
        repo_name="api", run_ref="refs/mship/run/t1/api",
    )
    head_ref = subprocess.run(
        ["git", "symbolic-ref", "--quiet", "HEAD"], cwd=worktree,
        capture_output=True, text=True, env=_REAL_GIT_ENV,
    )
    assert head_ref.returncode != 0          # detached: no symbolic HEAD


def test_a_stale_worktree_lands_on_the_pushed_tree_not_the_branch_tip(tmp_path):
    """ac10, the decisive case: an existing worktree sitting on the branch, with
    leftovers from a previous run, ends up at the pushed ref's tree."""
    repo, tip, scratch = _host_repo_with_run_ref(tmp_path)
    worktree = tmp_path / "wt" / "api"
    worktree.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["git", "worktree", "add", "-q", str(worktree), "feat/t1"],
        cwd=repo, capture_output=True, check=True, env=_REAL_GIT_ENV,
    )
    (worktree / "a.txt").write_text("stale local edit\n")
    (worktree / "leftover.txt").write_text("from the last run\n")

    remote_exec.materialize_worktree(
        ShellRunner(), repo, worktree, "feat/t1",
        repo_name="api", run_ref="refs/mship/run/t1/api",
    )

    assert _real_git("rev-parse", "HEAD", cwd=worktree) == scratch != tip
    assert (worktree / "a.txt").read_text() == "what the operator is editing\n"
    assert not (worktree / "leftover.txt").exists()   # cleaned, so the copy is exact
    assert _real_git("status", "--porcelain", cwd=worktree) == ""


def test_materializing_from_a_run_ref_issues_no_fetch(tmp_path):
    """ac10 as a command-level invariant: origin is not consulted, at all."""
    fake = _FakeShellRunner()
    remote_exec.materialize_worktree(
        fake, tmp_path / "api", tmp_path / "wt" / "api", "feat/t1",
        repo_name="api", run_ref="refs/mship/run/t1/api",
    )
    assert not any("fetch" in cmd for cmd, _cwd in fake.run_calls)
    assert not any("origin" in cmd for cmd, _cwd in fake.run_calls)


def test_without_a_run_ref_the_branch_path_is_unchanged(tmp_path):
    """ac9: nothing about today's behaviour moves."""
    fake = _FakeShellRunner()
    worktree = tmp_path / "wt" / "api"
    remote_exec.materialize_worktree(
        fake, tmp_path / "api", worktree, "feat/t1", repo_name="api",
    )
    assert [cmd for cmd, _cwd in fake.run_calls] == [
        "git fetch origin feat/t1",
        f"git worktree add -B feat/t1 {worktree} origin/feat/t1",
    ]
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_serve_exec.py -q -k "run_ref or stale_worktree or no_fetch or branch_path_is_unchanged or detached_not_a_branch"`
Expected: FAIL — `materialize_worktree() got an unexpected keyword argument 'run_ref'`

- [ ] **Step 3: Write the implementation**

In `src/mship/core/remote_exec.py`, replace `materialize_worktree` (the whole function, signature through its last `)` — it is self-contained and every branch of it changes shape) with:

```python
def materialize_worktree(
    shell: ShellLike,
    repo_path: Path,
    worktree_path: Path,
    branch: str,
    *,
    repo_name: str,
    run_ref: str | None = None,
) -> None:
    """Ensure `worktree_path` is a git worktree of `repo_path` holding the
    revision this run is supposed to execute.

    Two modes.

    `run_ref` GIVEN (spec remote-exact-copy): the operator pushed a commit
    synthesized from their working tree straight to this host, so the revision is
    ALREADY in this repository. Materialization is a reset to a LOCAL ref with NO
    FETCH — origin is not consulted at all, which is also why the caller skips
    the base-freshness probe for these repos. HEAD is left DETACHED on purpose:
    the scratch commit is throwaway state, and pointing a branch at it would
    dress it up as history. `git clean -fd` removes leftovers from a previous
    run so the result is an exact copy; it does not remove gitignored files, so
    dependencies derived by `task setup` survive between runs.

    `run_ref` NONE (unchanged from before): `branch` already exists on origin
    (created by `mship spawn`/dispatch on the operator's machine and pushed
    there) — this NEVER creates a new branch here, it only fetches + tracks the
    existing one. Idempotent: an existing worktree is fetched + hard-reset to the
    new tip; a first-time run creates it with `git worktree add -B`, which is
    safe to re-run even if a stale local branch ref of the same name exists.

    Every git command runs through `_run_checked` (`repo_name` is only used for
    that error message): a failure here raises `MaterializeError` instead of
    silently letting execution continue against a missing/stale checkout.
    """
    if run_ref is not None:
        if (worktree_path / ".git").exists():
            # `checkout --detach` with NO ref keeps the current commit, so it
            # succeeds even when the worktree is dirty from the last run
            # (verified); the reset then moves detached HEAD without ever moving
            # a branch.
            _run_checked(shell, "git checkout --detach", worktree_path, repo_name=repo_name)
            _run_checked(shell, f"git reset --hard {run_ref}", worktree_path, repo_name=repo_name)
            _run_checked(shell, "git clean -fd", worktree_path, repo_name=repo_name)
        else:
            worktree_path.parent.mkdir(parents=True, exist_ok=True)
            _run_checked(
                shell,
                f"git worktree add --detach {worktree_path} {run_ref}",
                repo_path,
                repo_name=repo_name,
            )
        return

    _run_checked(shell, f"git fetch origin {branch}", repo_path, repo_name=repo_name)
    if (worktree_path / ".git").exists():
        _run_checked(shell, f"git fetch origin {branch}", worktree_path, repo_name=repo_name)
        _run_checked(shell, f"git checkout {branch}", worktree_path, repo_name=repo_name)
        _run_checked(shell, f"git reset --hard origin/{branch}", worktree_path, repo_name=repo_name)
    else:
        worktree_path.parent.mkdir(parents=True, exist_ok=True)
        _run_checked(
            shell,
            f"git worktree add -B {branch} {worktree_path} origin/{branch}",
            repo_path,
            repo_name=repo_name,
        )
```

The `run_ref is None` half is byte-identical to what is on `main` — diff it and confirm only the new block and the docstring changed.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_serve_exec.py -q`
Expected: all pass. The existing materialize tests (`test_exec_run_materializes_new_worktree_and_streams_output`, `test_exec_run_resets_existing_worktree_to_latest_branch`) are unaffected because `run_ref` defaults to `None`.

- [ ] **Step 5: Commit**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
git add src/mship/core/remote_exec.py tests/core/test_serve_exec.py
git commit -m "feat(remote): materialize from a local scratch ref with no fetch"
mship journal "materialize_worktree(run_ref=...): detached reset + clean, proven on real repos incl. the stale-worktree case" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=11 -->
### Task 11: Route `run_ref_repos` through the streaming run

**Files:**
- Modify: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/src/mship/core/remote_exec.py` (`run_verb_stream`, line 319, and `_ensure_materialized` inside it)
- Modify: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/src/mship/core/serve.py` (`post_exec`'s `run_verb_stream(...)` call, line 1438)
- Test: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/tests/core/test_serve_exec.py` (append)

- [ ] **Step 1: Write the failing tests**

Append to `tests/core/test_serve_exec.py`:

```python
def test_run_verb_stream_uses_the_scratch_ref_for_named_repos(tmp_path):
    fake = _FakeShellRunner(streaming_proc=_FakeProc(stdout_lines=["ok\n"]))
    deps = remote_exec.RemoteExecDeps(
        config=_config(tmp_path), shell=fake, workspace_root=tmp_path,
    )

    list(remote_exec.run_verb_stream(
        "run", "t1", ["api"], None, deps=deps, nonce=_TEST_NONCE, run_ref_repos=["api"],
    ))

    commands = [cmd for cmd, _cwd in fake.run_calls]
    assert any("refs/mship/run/t1/api" in c for c in commands)
    # ac10: no fetch, not even the MOS-203 base-freshness probe, which exists
    # only to keep this host's view of ORIGIN current.
    assert not any("fetch" in c for c in commands)


def test_a_repo_not_named_still_comes_from_origin(tmp_path):
    """The mixed case: one repo transferred, another clean."""
    fake = _FakeShellRunner(streaming_proc=_FakeProc(stdout_lines=["ok\n"]))
    deps = remote_exec.RemoteExecDeps(
        config=_config_with_child(tmp_path), shell=fake, workspace_root=tmp_path,
    )

    list(remote_exec.run_verb_stream(
        "run", "t1", ["app"], None, deps=deps, nonce=_TEST_NONCE, run_ref_repos=[],
    ))

    commands = [cmd for cmd, _cwd in fake.run_calls]
    assert any("fetch origin feat/t1" in c for c in commands)
    assert not any("refs/mship/run" in c for c in commands)


def test_a_git_root_child_is_materialized_from_its_parents_scratch_ref(tmp_path):
    """ac7 on the run host: one git repository, one ref. The client sends the
    PARENT's name even when only the child was requested."""
    fake = _FakeShellRunner(streaming_proc=_FakeProc(stdout_lines=["ok\n"]))
    deps = remote_exec.RemoteExecDeps(
        config=_config_with_child(tmp_path), shell=fake, workspace_root=tmp_path,
    )

    list(remote_exec.run_verb_stream(
        "run", "t1", ["server"], None, deps=deps, nonce=_TEST_NONCE, run_ref_repos=["app"],
    ))

    commands = [cmd for cmd, _cwd in fake.run_calls]
    assert any("refs/mship/run/t1/app" in c for c in commands)


def test_a_task_name_that_cannot_form_a_ref_fails_cleanly(tmp_path):
    """The ref reaches a shell here, so a name that cannot form one is refused
    BEFORE anything runs — as stream DATA (an error line + a non-zero exit
    sentinel), never a raised exception mid-generator, matching how the
    unknown-repo guard already behaves. `/exec` accepts `/` in a task name;
    `run_ref` does not."""
    fake = _FakeShellRunner(streaming_proc=_FakeProc(stdout_lines=["ok\n"]))
    deps = remote_exec.RemoteExecDeps(
        config=_config(tmp_path), shell=fake, workspace_root=tmp_path,
    )

    lines = [
        l.decode() for l in remote_exec.run_verb_stream(
            "run", "a/b", ["api"], None, deps=deps, nonce=_TEST_NONCE,
            run_ref_repos=["api"],
        )
    ]

    assert lines[-1].startswith(f"{remote_exec.EXIT_MARKER}:{_TEST_NONCE} ")
    assert int(lines[-1].split(" ", 1)[1].strip()) != 0
    assert any("run ref" in l for l in lines[:-1])
    assert fake.streaming_calls == []       # the task never started
    assert fake.run_calls == []             # nor did any git command
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_serve_exec.py -q -k "scratch_ref or comes_from_origin or git_root_child_is_materialized or cannot_form_a_ref"`
Expected: FAIL — `run_verb_stream() got an unexpected keyword argument 'run_ref_repos'`

- [ ] **Step 3: Write the implementation**

In `src/mship/core/remote_exec.py`:

**(a)** Add the import next to the existing `from mship.core.config import WorkspaceConfig`:

```python
from mship.core.run_ref import RunRefNameError
from mship.core.run_ref import run_ref as build_run_ref
```

**(b)** Add the parameter to `run_verb_stream`'s signature, immediately after `nonce: str,`:

```python
    run_ref_repos: list[str] | None = None,
```

**(c)** Add this to `run_verb_stream`'s docstring, immediately after the numbered step 2 paragraph:

```
      2b. A repo named in `run_ref_repos` is materialized from THIS host's own
          scratch ref for the task instead — the operator pushed a commit
          synthesized from their working tree straight here, so the revision is
          already local and NO fetch (not even the base-freshness probe, which
          exists only to refresh this host's view of origin) is issued for it.
          Names are TOP-LEVEL git repo names, so a `git_root` child is covered
          by its parent's entry.
```

**(d)** Immediately after the `unknown_repos` guard block (the one ending `return`), insert:

```python
    scratch_repos = sorted(set(run_ref_repos or []))
    run_refs: dict[str, str] = {}
    for scratch_repo in scratch_repos:
        try:
            run_refs[scratch_repo] = build_run_ref(task, scratch_repo)
        except RunRefNameError as exc:
            # The ref is interpolated into git commands run with shell=True, so
            # a name that cannot form one is refused before anything runs — as
            # stream DATA, never a raised exception mid-generator, matching the
            # unknown-repo guard above.
            yield f"error: cannot build a run ref for this request: {exc}\n".encode("utf-8")
            yield f"{EXIT_MARKER}:{nonce} 2\n".encode("utf-8")
            return
```

**(e)** In `_ensure_materialized`, replace this block:

```python
        if top_repo in materialized:
            return True
        rc = config.repos[top_repo]
        repo_path = rc.path
        worktree_path = hub / top_repo

        warning = check_base_freshness(shell, repo_path, rc.base_branch)
        if warning is not None:
            yield f"{warning}\n".encode("utf-8")

        try:
            materialize_worktree(shell, repo_path, worktree_path, branch, repo_name=top_repo)
```

with:

```python
        if top_repo in materialized:
            return True
        rc = config.repos[top_repo]
        repo_path = rc.path
        worktree_path = hub / top_repo
        ref = run_refs.get(top_repo)

        if ref is None:
            # Origin is the source of truth for this repo, so make sure this
            # host's view of its base is current first (MOS-203). Skipped
            # entirely on the scratch-ref path: nothing there comes from origin,
            # and a fetch would be pure latency.
            warning = check_base_freshness(shell, repo_path, rc.base_branch)
            if warning is not None:
                yield f"{warning}\n".encode("utf-8")

        try:
            materialize_worktree(
                shell, repo_path, worktree_path, branch,
                repo_name=top_repo, run_ref=ref,
            )
```

Leave the `except MaterializeError` handler and everything after it untouched.

In `src/mship/core/serve.py`, replace the `run_verb_stream(...)` call inside `post_exec`:

```python
        gen = remote_exec.run_verb_stream(
            verb, body.task, body.repos, body.platform,
            kind=body.kind, deps=deps, nonce=nonce,
        )
```

with:

```python
        gen = remote_exec.run_verb_stream(
            verb, body.task, body.repos, body.platform,
            kind=body.kind, deps=deps, nonce=nonce,
            run_ref_repos=body.run_ref_repos,
        )
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_serve_exec.py tests/core/test_git_receive.py -q`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
git add src/mship/core/remote_exec.py src/mship/core/serve.py tests/core/test_serve_exec.py
git commit -m "feat(remote): run host materializes named repos from their scratch ref"
mship journal "run_verb_stream(run_ref_repos=...): derives the ref itself, skips base-freshness on that path, refuses an unusable task name as stream data" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=12 -->
### Task 12: The CLI decides per repo — transfer or origin

**Files:**
- Modify (**surgical — three anchored edits**): `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/src/mship/cli/exec.py` (`_run_remote`, lines 172–204)
- Modify: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/tests/cli/test_remote_dispatch.py`

The merged `_run_remote` already resolves the run host, then preflights, then pushes, then dispatches. Only two things change: the untracked *warning* becomes a *transfer*, and `exec_remote` learns which repos were transferred. **Do not** re-resolve `task_obj` from state — the merged docstring (lines 119–124) explains at length why the caller's already-resolved `Task` object is passed in, and `test_a_task_missing_from_a_later_state_read_does_not_skip_the_preflight` guards it.

- [ ] **Step 1: Edit the tests**

**1a. Extend `_git_shell`** in `tests/cli/test_remote_dispatch.py` (line 1017) so it answers the new git commands and records each push's env. Replace its inner `_run` and the trailing assignments with:

```python
    def _run(cmd, cwd=None, env=None, **kw):
        touched.add(Path(cwd).name)
        s = spec[Path(cwd).name]
        if "status --porcelain" in cmd:
            return ShellResult(
                returncode=s["status_rc"], stdout=s["status"], stderr=s["status_err"],
            )
        if "rev-parse --git-dir" in cmd:
            # `_inspect_repo` looks here for MERGE_HEAD / rebase-merge — a test
            # that wants the in-progress refusal creates the marker itself.
            return ShellResult(returncode=0, stdout=str(Path(cwd) / ".git"), stderr="")
        if "symbolic-ref" in cmd:
            return ShellResult(
                returncode=0 if s["head_ref"] else 1, stdout=s["head_ref"], stderr="",
            )
        if "ls-remote" in cmd:
            out = "" if s["origin"] is None else f"{s['origin']}\trefs/heads/feat/t1\n"
            return ShellResult(returncode=0, stdout=out, stderr="")
        if "rev-parse HEAD" in cmd and "refs/heads/" in cmd:
            # The atomic branch-identity + sha read `_inspect_repo` makes: one
            # call answering both "which branch is HEAD on" and "what sha is
            # it at" from the same process. `head_ref` decides whether the
            # branch-ref half of the pair agrees with `head` (HEAD really is
            # on the named branch) or reports a distinct sha (it is not).
            target_ref = cmd.rsplit("refs/heads/", 1)[-1].strip("'\"")
            branch_sha = (
                s["head"] if s["head_ref"] == f"refs/heads/{target_ref}"
                else "otherbranchsha"
            )
            return ShellResult(returncode=0, stdout=f"{s['head']}\n{branch_sha}",
                               stderr="")
        if "merge-base --is-ancestor" in cmd:
            tip = cmd.split()[-2].strip("'")
            return ShellResult(returncode=0 if tip in s["contains"] else 1,
                               stdout="", stderr="")
        # --- commit synthesis (core/run_transfer.py) -------------------------
        if "write-tree" in cmd:
            return ShellResult(returncode=0, stdout="tree1111\n", stderr="")
        if "commit-tree" in cmd:
            return ShellResult(returncode=0, stdout="synth2222\n", stderr="")
        if cmd.startswith("git push"):
            pushes.append(cmd)
            push_envs.append(dict(env or {}))
            return ShellResult(returncode=push_rc, stdout="", stderr="denied\n")
        return ShellResult(returncode=0, stdout="", stderr="")

    shell.run.side_effect = _run
    shell.run_task.return_value = ShellResult(returncode=0, stdout="ok\n", stderr="")
    shell.pushes = pushes
    shell.push_envs = push_envs
    shell.touched = touched
    return shell
```

and add `push_envs: list[dict] = []` next to the existing `pushes: list[str] = []` declaration at the top of `_git_shell`.

**1b. Invert `test_remote_run_is_refused_when_the_worktree_is_dirty`.** Replace the whole test with:

```python
def test_a_dirty_worktree_is_sent_to_the_run_host_not_to_origin(tmp_path, monkeypatch):
    """ac1 + ac3 + ac7 through the CLI: the operator's uncommitted content is
    synthesized into a commit and pushed straight to the run host, and origin
    sees nothing at all. Under PR #419 this exact repo shape was a refusal."""
    _write_run_workspace(tmp_path, run_hosts=["role-x"])
    _seed_task_with_worktree(tmp_path, "t1", "api")
    _configure(tmp_path)
    shell = _git_shell(_repo_git(" M src/app.py\n?? scratch.txt\n"))
    container.shell.override(shell)
    RunHostStore(tmp_path / ".mothership").set(
        "role-x", RunHostConnection(url="http://remote.example", token="tok-abc"),
    )
    recorder: dict = {}
    try:
        with _ClientPatch(monkeypatch, _recording_handler(recorder, _frame(["ok\n"], exit_code=0))):
            result = runner.invoke(app, ["run", "--task", "t1", "--remote=role-x"])
        assert result.exit_code == 0, result.output

        assert len(shell.pushes) == 1
        assert "synth2222:refs/mship/run/t1/api" in shell.pushes[0]
        assert "http://remote.example/git/api" in shell.pushes[0]
        assert "origin" not in shell.pushes[0]              # ac3
        assert recorder["json"]["run_ref_repos"] == ["api"]
    finally:
        container.shell.reset_override()
        _reset()


def test_the_bearer_never_reaches_the_push_command_line(tmp_path, monkeypatch):
    """ac4, end to end through the CLI: argv is world-readable via /proc."""
    _write_run_workspace(tmp_path, run_hosts=["role-x"])
    _seed_task_with_worktree(tmp_path, "t1", "api")
    _configure(tmp_path)
    shell = _git_shell(_repo_git(" M src/app.py\n"))
    container.shell.override(shell)
    RunHostStore(tmp_path / ".mothership").set(
        "role-x", RunHostConnection(url="http://remote.example", token="tok-abc"),
    )
    try:
        with _ClientPatch(monkeypatch, _recording_handler({}, _frame(["ok\n"], exit_code=0))):
            runner.invoke(app, ["run", "--task", "t1", "--remote=role-x"])
        assert "tok-abc" not in shell.pushes[0]
        assert "Authorization: Bearer tok-abc" in shell.push_envs[0].values()
    finally:
        container.shell.reset_override()
        _reset()


def test_the_output_names_the_revision_as_a_throwaway_run_ref(tmp_path, monkeypatch):
    """ac13: nobody should `git show` it and try to build on it.

    `MSHIP_JSON=0` is required, not decorative: `Output.breadcrumb` is gated on
    `human_mode`, and `json_mode` defaults to `not is_tty` — so under CliRunner
    breadcrumbs are suppressed and `result.output` would never contain the line.
    """
    monkeypatch.setenv("MSHIP_JSON", "0")
    _write_run_workspace(tmp_path, run_hosts=["role-x"])
    _seed_task_with_worktree(tmp_path, "t1", "api")
    _configure(tmp_path)
    container.shell.override(_git_shell(_repo_git(" M src/app.py\n")))
    RunHostStore(tmp_path / ".mothership").set(
        "role-x", RunHostConnection(url="http://remote.example", token="tok-abc"),
    )
    try:
        with _ClientPatch(monkeypatch, _recording_handler({}, _frame(["ok\n"], exit_code=0))):
            result = runner.invoke(app, ["run", "--task", "t1", "--remote=role-x"])
        assert "throwaway" in result.output
        assert "refs/mship/run/t1/api" in result.output
        assert "synth2222"[:12] in result.output
    finally:
        container.shell.reset_override()
        _reset()


def test_a_failed_transfer_aborts_before_dispatch(tmp_path, monkeypatch):
    """Dispatching after a failed transfer would run the previous ref's tree —
    the same silent-stale-code failure, one layer along."""
    _write_run_workspace(tmp_path, run_hosts=["role-x"])
    _seed_task_with_worktree(tmp_path, "t1", "api")
    _configure(tmp_path)
    container.shell.override(_git_shell(_repo_git(" M src/app.py\n"), push_rc=1))
    RunHostStore(tmp_path / ".mothership").set(
        "role-x", RunHostConnection(url="http://remote.example", token="tok-abc"),
    )
    recorder: dict = {}
    try:
        with _ClientPatch(monkeypatch, _recording_handler(recorder, _frame([], exit_code=0))):
            result = runner.invoke(app, ["run", "--task", "t1", "--remote=role-x"])
        assert result.exit_code == 1, result.output
        assert "run host" in result.output and "denied" in result.output
        assert recorder == {}                       # never contacted
    finally:
        container.shell.reset_override()
        _reset()


def test_a_mid_rebase_repo_is_refused_before_anything_is_sent(tmp_path, monkeypatch):
    """ac12 through the CLI."""
    _write_run_workspace(tmp_path, run_hosts=["role-x"])
    wts = _seed_task_with_worktree(tmp_path, "t1", "api")
    (wts["api"] / ".git" / "rebase-merge").mkdir(parents=True)
    _configure(tmp_path)
    shell = _git_shell(_repo_git("UU src/app.py\n"))
    container.shell.override(shell)
    RunHostStore(tmp_path / ".mothership").set(
        "role-x", RunHostConnection(url="http://remote.example", token="tok-abc"),
    )
    recorder: dict = {}
    try:
        with _ClientPatch(monkeypatch, _recording_handler(recorder, _frame([], exit_code=0))):
            result = runner.invoke(app, ["run", "--task", "t1", "--remote=role-x"])
        assert result.exit_code == 1, result.output
        assert "merge or rebase in progress in api" in result.output
        assert "--abort" in result.output
        assert shell.pushes == []
        assert recorder == {}
    finally:
        container.shell.reset_override()
        _reset()
```

**1c. Re-point `test_a_task_missing_from_a_later_state_read_does_not_skip_the_preflight`** at a repo shape that is still a refusal. Its guarantee — the preflight is mandatory and is not conditional on a second state read — is unchanged; only the scripted repo changes, because a dirty repo now dispatches. Replace its `container.shell.override(...)` line and its two output assertions with:

```python
    container.shell.override(_git_shell(_repo_git(
        "", status_rc=128, status_err="fatal: not a git repository\n",
    )))
```

```python
        assert result.exit_code == 1, result.output
        assert "unreadable git state in api" in result.output
        assert recorder == {}                    # the remote was never contacted
```

and update its docstring's last sentence to read: `... over a repo (here, one whose git state cannot be read at all) that the first read had every fact needed to refuse.`

**1d. Add one assertion** to `test_repos_scope_keeps_an_unrelated_dirty_repo_from_blocking`, after the existing `assert recorder["json"]["repos"] == ["api"]`:

```python
        assert "run_ref_repos" not in recorder["json"]   # web was never transferred
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/cli/test_remote_dispatch.py -q`
Expected: the five new/inverted tests FAIL — `_run_remote` still warns about untracked files instead of transferring, and `exec_remote` is called without `run_ref_repos`, so `recorder["json"]` has no such key and `shell.pushes` is empty.

- [ ] **Step 3: Make the three anchored edits to `cli/exec.py`**

**Edit 1 — pass `config` to the preflight, and reuse one shell.** Replace:

```python
    from mship.core import remote_preflight

    pre = remote_preflight.inspect(task_obj, container.shell(), repos=target_repos)
    if not pre.ok:
        output.error(remote_preflight.blocked_message(pre))
        raise typer.Exit(code=1)
```

with:

```python
    from mship.core import remote_preflight, run_transfer
    from mship.core.run_ref import RunRefNameError

    shell = container.shell()
    # `repos=target_repos` is load-bearing and stays: preflighting the task's
    # other repos would both refuse a run over work in progress it never touches
    # and transfer repos the operator never named. `config` is what lets a
    # `git_root` child and its parent collapse to one transfer.
    pre = remote_preflight.inspect(
        task_obj, shell, repos=target_repos, config=config,
    )
    if not pre.ok:
        output.error(remote_preflight.blocked_message(pre))
        raise typer.Exit(code=1)
```

**Edit 2 — the warning becomes the transfer.** Replace:

```python
    for state in pre.untracked:
        output.warning(
            f"{state.repo}: untracked files will not exist on the run host "
            f"(they are not part of the push)"
        )
    pushed, push_error = remote_preflight.push(pre, container.shell())
```

with:

```python
    # A working tree that differs from HEAD is no longer a refusal, it is a
    # TRANSFER: synthesize a commit from that tree and push it STRAIGHT to the
    # run host, onto the throwaway namespace `core/run_ref.py` owns. Origin is
    # never in this path — routing uncommitted work through it would publish
    # untracked scratch files to a third party, and deleting the ref afterwards
    # would not retract the objects.
    #
    # `state.head_sha` is the sha the preflight certified HEAD to be at, not a
    # re-read of HEAD: it is the same guarantee `remote_preflight.push` makes
    # for the origin path, applied to the snapshot's parent.
    run_ref_repos: list[str] = []
    for state in pre.dirty:
        try:
            sha = run_transfer.synthesize_commit(
                shell, state.path, base_sha=state.head_sha,
            )
            ref = run_transfer.push_run_ref(
                shell, state.path, conn=conn, repo=state.git_repo,
                task=task_obj.slug, sha=sha,
            )
        except (run_transfer.RunTransferError, RunRefNameError) as e:
            output.error(str(e))
            raise typer.Exit(code=1)
        run_ref_repos.append(state.git_repo)
        # Name it as throwaway (spec ac13): an operator who sees a bare sha will
        # reasonably try to `git show` it and find it attached to nothing.
        output.breadcrumb(
            f"{state.git_repo}: sent your working tree to the run host as "
            f"{ref} ({sha[:12]}) — a throwaway run ref, not a commit on "
            f"{state.branch}"
        )

    pushed, push_error = remote_preflight.push(pre, shell)
```

**Edit 3 — tell the run host.** Replace:

```python
        return exec_remote(
            verb=verb, conn=conn, task=task_obj.slug, repos=target_repos,
        )
```

with:

```python
        return exec_remote(
            verb=verb, conn=conn, task=task_obj.slug, repos=target_repos,
            run_ref_repos=run_ref_repos,
        )
```

Finally, update `_run_remote`'s docstring: replace the paragraph beginning `Remote execution always operates on a task's branch` with:

```
    Remote execution always operates on a task's branch — the remote
    materializes `.worktrees/<task>/<repo>`, either from origin or from a
    scratch ref this command pushes it — so there's no "ad-hoc" remote run.
    Local `run`/`build` gracefully fall back to "the whole workspace" when no
    task is active, but that fallback has no branch for the remote to check out,
    so `--remote` without a resolvable task is a clean, actionable CLI error
    rather than a confusing remote-side failure.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/cli/test_remote_dispatch.py tests/core/test_remote_preflight.py -q`
Expected: all pass.

Then confirm fix 5 (scoping) is still wired, by name:

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
uv run pytest tests/cli/test_remote_dispatch.py -q -v -k "repos_scope or selection_outside or missing_from_a_later_state"
```
Expected: all `PASSED`.

- [ ] **Step 5: Commit**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
git add src/mship/cli/exec.py tests/cli/test_remote_dispatch.py
git commit -m "feat(remote): --remote sends your working tree; refusal becomes transfer"
mship journal "cli: dirty -> synthesize+push to run host (never origin); clean -> origin; mid-rebase refused; repos scoping and the resolved-Task guarantee both kept" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=13 -->
### Task 13: End to end — the run host really runs the uncommitted bytes

**Files:**
- Test: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/tests/core/test_git_receive.py` (append)

Everything so far is proven one layer at a time. This walks the whole path with real git on both sides and a real socket in the middle: synthesize → push over HTTP → materialize → read the file. It is the direct evidence for ac1.

- [ ] **Step 1: Write the test**

Append to `tests/core/test_git_receive.py`:

```python
# --- the whole path ----------------------------------------------------------

from mship.core import remote_exec
from mship.core.run_host import RunHostConnection
from mship.core.run_transfer import push_run_ref, synthesize_commit
from mship.util.shell import ShellRunner


def test_the_run_host_materializes_the_operators_uncommitted_bytes(tmp_path):
    """ac1 end to end. The operator edits a file and never commits it; the run
    host's worktree ends up holding exactly those bytes."""
    host_repo = _repo(tmp_path / "api")
    operator = _clone(host_repo, tmp_path / "operator")
    _git("checkout", "-q", "-b", "feat/t1", cwd=operator)

    # Uncommitted work of every shape that matters.
    (operator / "a.txt").write_text("what I am editing right now\n")
    (operator / "scratch.py").write_text("print('debug')\n")
    (operator / ".gitignore").write_text("secret.env\nbuilt.log\n")
    (operator / "secret.env").write_text("TOKEN=hunter2\n")
    (operator / "built.log").write_text("derived\n")

    shell = ShellRunner()
    base = _git("rev-parse", "HEAD", cwd=operator)
    sha = synthesize_commit(shell, operator, base_sha=base)

    with live_serve(_app(tmp_path, auth_token="tok-abc")) as base_url:
        push_run_ref(
            shell, operator,
            conn=RunHostConnection(url=base_url, token="tok-abc"),
            repo="api", task="t1", sha=sha,
        )

    worktree = tmp_path / "host-wt" / "api"
    remote_exec.materialize_worktree(
        shell, host_repo, worktree, "feat/t1",
        repo_name="api", run_ref="refs/mship/run/t1/api",
    )

    # ac1: the tracked edit arrived, uncommitted.
    assert (worktree / "a.txt").read_text() == "what I am editing right now\n"
    # ac11: untracked travels, gitignored does not.
    assert (worktree / "scratch.py").read_text() == "print('debug')\n"
    assert not (worktree / "secret.env").exists()
    assert not (worktree / "built.log").exists()

    # ac2: the operator's own repo is untouched — still dirty, still on the
    # branch, HEAD unmoved, nothing staged, no new branch.
    assert _git("status", "--porcelain", cwd=operator) != ""
    assert _git("rev-parse", "--abbrev-ref", "HEAD", cwd=operator) == "feat/t1"
    assert _git("rev-parse", "HEAD", cwd=operator) == base
    assert _git("diff", "--cached", "--name-only", cwd=operator) == ""

    # ac3: the branch never reached the host as a branch — only the scratch ref
    # did. (`host_repo` is the operator's origin here, which makes this the
    # strongest available form of "origin saw nothing but the scratch ref".)
    refs = _git("for-each-ref", "--format=%(refname)", cwd=host_repo)
    assert "refs/heads/feat/t1" not in refs
    assert "refs/mship/run/t1/api" in refs
```

- [ ] **Step 2: Run it to verify it passes**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_git_receive.py -q -k uncommitted_bytes -v`
Expected: PASS. A failure here means one of Tasks 5, 7, 8 or 10 is subtly wrong — debug there, and add the missing case to *that* task's tests rather than only fixing it here.

- [ ] **Step 3: No implementation needed**

- [ ] **Step 4: Run the file**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_git_receive.py -q`
Expected: `32 passed`

- [ ] **Step 5: Commit**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
git add tests/core/test_git_receive.py
git commit -m "test(remote): end-to-end proof the run host executes uncommitted bytes"
mship journal "e2e: synthesize -> HTTP push -> materialize; tracked edit + untracked file arrive, gitignored does not, operator repo untouched" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=14 -->
### Task 14: `mship close` deletes the task's scratch refs

**Files:**
- Modify: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/src/mship/core/run_transfer.py` (append)
- Modify: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/src/mship/cli/worktree.py` (`close`, immediately before `wt_mgr = container.worktree_manager()`)
- Test: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/tests/core/test_run_transfer.py` (append)
- Test: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/tests/cli/test_worktree.py` (append)

Without this, scratch refs are a slow leak of objects nothing deletes. They are on the operator's own machine, so a missed cleanup costs disk rather than disclosure — which is exactly why this fails **open** rather than blocking a close.

- [ ] **Step 1: Write the failing tests**

Append to `tests/core/test_run_transfer.py`:

```python
# --- cleanup on close --------------------------------------------------------

from mship.core.config import RepoConfig, WorkspaceConfig
from mship.core.run_host import RunHostStore
from mship.core.run_transfer import cleanup_run_refs


class FakeTask:
    def __init__(self, slug, affected_repos):
        self.slug = slug
        self.affected_repos = affected_repos


def _run_host_config(tmp_path, **extra_repos) -> WorkspaceConfig:
    repos = {"api": RepoConfig(path=tmp_path / "api", type="service", run_host="role-x")}
    repos.update(extra_repos)
    return WorkspaceConfig(workspace="t", run_hosts=["role-x"], repos=repos)


def _store(tmp_path) -> RunHostStore:
    store = RunHostStore(tmp_path / ".mothership")
    store.set("role-x", RunHostConnection(url="http://remote.example", token="tok-abc"))
    return store


def test_close_deletes_the_tasks_scratch_ref(tmp_path):
    """ac8: they do not accumulate."""
    shell = RecordingShell()
    warnings: list[str] = []

    deleted = cleanup_run_refs(
        FakeTask("t1", ["api"]),
        config=_run_host_config(tmp_path), store=_store(tmp_path),
        shell=shell, warn=warnings.append,
    )

    assert deleted == ["api"]
    assert ":refs/mship/run/t1/api" in shell.calls[0][0]
    assert warnings == []


def test_a_git_root_child_is_cleaned_once_via_its_parent(tmp_path):
    """ac7 again: one git repository, one ref, one delete."""
    shell = RecordingShell()
    config = _run_host_config(
        tmp_path,
        server=RepoConfig(path=Path("server"), type="service", git_root="api"),
    )

    deleted = cleanup_run_refs(
        FakeTask("t1", ["api", "server"]), config=config, store=_store(tmp_path),
        shell=shell, warn=lambda _m: None,
    )

    assert deleted == ["api"]
    assert len(shell.calls) == 1


def test_no_mapped_run_host_means_nothing_to_clean(tmp_path):
    """A task that never ran remotely must not warn on every close."""
    shell = RecordingShell()
    warnings: list[str] = []

    deleted = cleanup_run_refs(
        FakeTask("t1", ["api"]),
        config=WorkspaceConfig(
            workspace="t",
            repos={"api": RepoConfig(path=tmp_path / "api", type="service")},
        ),
        store=RunHostStore(tmp_path / ".mothership"),
        shell=shell, warn=warnings.append,
    )

    assert deleted == [] and shell.calls == [] and warnings == []


def test_a_failed_delete_warns_and_keeps_going(tmp_path):
    """Cleanup must never block a close: a missed ref is disk, not disclosure."""
    shell = RecordingShell(returncode=1, stderr="host unreachable\n")
    warnings: list[str] = []

    deleted = cleanup_run_refs(
        FakeTask("t1", ["api"]), config=_run_host_config(tmp_path),
        store=_store(tmp_path), shell=shell, warn=warnings.append,
    )

    assert deleted == []
    assert warnings and "api" in warnings[0]


def test_a_task_slug_that_cannot_form_a_ref_warns_rather_than_raising(tmp_path):
    """`run_ref` refuses `/` in a slug; a close must not die on it."""
    shell = RecordingShell()
    warnings: list[str] = []

    deleted = cleanup_run_refs(
        FakeTask("a/b", ["api"]), config=_run_host_config(tmp_path),
        store=_store(tmp_path), shell=shell, warn=warnings.append,
    )

    assert deleted == [] and shell.calls == []
    assert warnings
```

Append to `tests/cli/test_worktree.py`:

```python
def test_close_deletes_scratch_refs_from_the_run_host(configured_git_app):
    """ac8, wired: closing a task removes what `--remote` left on the host."""
    from datetime import datetime, timezone

    from mship.core.run_host import RunHostConnection, RunHostStore

    config_path = configured_git_app / "mothership.yaml"
    config_path.write_text(
        config_path.read_text().replace(
            "workspace: test-platform",
            "workspace: test-platform\nrun_hosts: [role-x]",
        ).replace(
            "  shared:\n    path: ./shared\n    type: library\n",
            "  shared:\n    path: ./shared\n    type: library\n    run_host: role-x\n",
        )
    )
    container.config.reset()
    RunHostStore(configured_git_app / ".mothership").set(
        "role-x", RunHostConnection(url="http://remote.example", token="tok-abc"),
    )

    sm = StateManager(configured_git_app / ".mothership")
    sm.save(WorkspaceState(tasks={"t": Task(
        slug="t", description="d", phase="dev",
        created_at=datetime.now(timezone.utc),
        affected_repos=["shared"], branch="feat/t",
    )}))

    result = runner.invoke(app, ["close", "--yes", "--abandon", "--task", "t"])

    assert result.exit_code == 0, result.output
    shell = container.shell()
    assert any(
        ":refs/mship/run/t/shared" in call.args[0]
        for call in shell.run.call_args_list
    )


def test_close_still_succeeds_when_the_run_host_is_unreachable(configured_git_app):
    """Fail-open: a run host that is off must never stop a close."""
    from datetime import datetime, timezone

    from mship.core.run_host import RunHostConnection, RunHostStore

    config_path = configured_git_app / "mothership.yaml"
    config_path.write_text(
        config_path.read_text().replace(
            "workspace: test-platform",
            "workspace: test-platform\nrun_hosts: [role-x]",
        ).replace(
            "  shared:\n    path: ./shared\n    type: library\n",
            "  shared:\n    path: ./shared\n    type: library\n    run_host: role-x\n",
        )
    )
    container.config.reset()
    RunHostStore(configured_git_app / ".mothership").set(
        "role-x", RunHostConnection(url="http://remote.example", token="tok-abc"),
    )

    shell = container.shell()
    original = shell.run.side_effect

    def _fail_pushes(cmd, cwd=None, env=None, **kw):
        if cmd.startswith("git push"):
            return ShellResult(returncode=1, stdout="", stderr="host unreachable\n")
        return original(cmd, cwd, env)

    shell.run.side_effect = _fail_pushes

    sm = StateManager(configured_git_app / ".mothership")
    sm.save(WorkspaceState(tasks={"t": Task(
        slug="t", description="d", phase="dev",
        created_at=datetime.now(timezone.utc),
        affected_repos=["shared"], branch="feat/t",
    )}))

    result = runner.invoke(app, ["close", "--yes", "--abandon", "--task", "t"])

    assert result.exit_code == 0, result.output
    assert "t" not in sm.load().tasks
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_run_transfer.py tests/cli/test_worktree.py -q -k "cleanup or scratch_ref or run_host"`
Expected: FAIL — `ImportError: cannot import name 'cleanup_run_refs' from 'mship.core.run_transfer'`

- [ ] **Step 3: Write the implementation**

Change the top-of-file import in `src/mship/core/run_transfer.py` from:

```python
from mship.core.run_ref import run_ref
```

to:

```python
from mship.core.run_ref import RunRefNameError, run_ref
```

and append:

```python
def cleanup_run_refs(task, *, config, store, shell, warn) -> list[str]:
    """Delete this task's scratch refs from the run hosts that hold them.

    Called by `mship close`. Without it the refs are a slow leak of objects
    nothing deletes — on the operator's own machine, so a missed one costs disk
    rather than disclosure, which is exactly why every failure here WARNS and
    the close continues.

    One delete per GIT repository: a `git_root` child shares its parent's ref
    (spec ac7). Issued from the repo's MAIN CHECKOUT rather than a task worktree,
    which is about to be torn down. A repo with no mapped run host is silently
    skipped — a task that never ran remotely must not warn on every close.
    """
    from mship.core.run_host import RunHostError, resolve_run_host

    deleted: list[str] = []
    seen: set[str] = set()
    repos = getattr(config, "repos", {})
    for repo in sorted(getattr(task, "affected_repos", None) or []):
        repo_config = repos.get(repo)
        if repo_config is None:
            continue
        git_repo = repo_config.git_root or repo
        if git_repo in seen:
            continue
        seen.add(git_repo)
        root_config = repos.get(git_repo)
        if root_config is None:
            continue
        try:
            conn = resolve_run_host(None, repo=root_config, config=config, store=store)
        except RunHostError:
            continue
        try:
            delete_run_ref(
                shell, Path(root_config.path), conn=conn,
                repo=git_repo, task=task.slug,
            )
        except (RunTransferError, RunRefNameError) as exc:
            warn(f"could not delete {git_repo}'s run ref from the run host: {exc}")
            continue
        deleted.append(git_repo)
    return deleted
```

In `src/mship/cli/worktree.py`, insert this immediately **before** `wt_mgr = container.worktree_manager()` inside `close`:

```python
        # Scratch refs left on run hosts by `--remote` (spec remote-exact-copy).
        # Fail-open like the spec/WorkItem advances above: a run host that is
        # off, unreachable, or was never mapped must not stop a close. The refs
        # are on the operator's own machine, so a missed one is disk, not
        # disclosure.
        try:
            from mship.core.run_host import RunHostStore
            from mship.core.run_transfer import cleanup_run_refs
            cleanup_run_refs(
                task, config=config, store=RunHostStore(container.state_dir()),
                shell=container.shell(), warn=output.warning,
            )
        except Exception:
            pass
```

Note this call site never spells a ref itself — `cleanup_run_refs` builds it through `run_ref()`. Task 15's invariant test depends on that.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_run_transfer.py tests/cli/test_worktree.py -q`
Expected: all pass (`test_run_transfer.py` reports `29 passed`).

- [ ] **Step 5: Commit**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
git add src/mship/core/run_transfer.py src/mship/cli/worktree.py tests/core/test_run_transfer.py tests/cli/test_worktree.py
git commit -m "feat(remote): mship close deletes the task's scratch refs"
mship journal "close: cleanup_run_refs per git repo, fail-open; no mapped run host = silent skip" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=15 -->
### Task 15: Pin the invariant that scratch refs never become history

**Files:**
- Create: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/tests/core/test_remote_exact_copy_invariants.py`

ac14 is an **absence**, and absences rot silently. This makes the absence enforceable: the `refs/mship/` namespace may only be named by the modules that own it, push to it, scope it, or materialize from it — never by anything that branches, merges, or opens a PR.

- [ ] **Step 1: Write the test**

Create `tests/core/test_remote_exact_copy_invariants.py`:

```python
"""ac14: nothing reaches a PR unreviewed.

The scratch namespace exists to be executed once and thrown away. No code path
branches from it, merges it, or pushes it anywhere but a run host — and `finish`
still requires real commits, exactly as before.

An absence needs a guard or it rots. This is that guard: if a new module starts
naming `refs/mship/`, this test fails until someone decides it belongs there.
"""
from pathlib import Path

SRC = Path(__file__).resolve().parents[2] / "src" / "mship"

# The only modules allowed to name the namespace, and why.
ALLOWED = {
    "core/run_ref.py",           # owns the name
    "core/git_receive.py",       # refuses everything outside it
    "core/run_transfer.py",      # pushes to it, deletes it
    "core/remote_exec.py",       # materializes from it (detached, never a branch)
    "core/remote_preflight.py",  # explains the routing in prose
}

# Modules that create real history. None of them may know this namespace exists.
HISTORY_MODULES = (
    "core/pr.py",
    "cli/worktree.py",
    "core/worktree.py",
    "cli/exec.py",
    "core/serve.py",
)


def _files_naming_the_namespace() -> set[str]:
    found = set()
    for path in SRC.rglob("*.py"):
        if "refs/mship/" in path.read_text(encoding="utf-8", errors="replace"):
            found.add(path.relative_to(SRC).as_posix())
    return found


def test_only_the_declared_modules_name_the_scratch_namespace():
    unexpected = _files_naming_the_namespace() - ALLOWED
    assert not unexpected, (
        f"{sorted(unexpected)} now name refs/mship/. That namespace is throwaway "
        f"state, not history: it must never be branched from, merged, or pushed "
        f"anywhere but a run host (spec remote-exact-copy ac14). If the module "
        f"genuinely belongs, add it to ALLOWED with a one-line reason."
    )


def test_the_pr_and_finish_paths_do_not_know_the_namespace_exists():
    """The call sites build the ref through `run_ref()`; inlining the string
    there is how it would leak into a path that pushes real history."""
    for module in HISTORY_MODULES:
        path = SRC / module
        assert path.exists(), f"{module} moved; update HISTORY_MODULES"
        assert "refs/mship/" not in path.read_text(), (
            f"{module} names refs/mship/; `finish` must keep requiring real commits"
        )


def test_the_run_host_checks_out_the_scratch_ref_detached():
    """A branch pointing at a synthesized commit would dress throwaway state up
    as history on the run host."""
    source = (SRC / "core" / "remote_exec.py").read_text()
    assert "git worktree add --detach {worktree_path} {run_ref}" in source
    assert "git checkout --detach" in source
    assert "git worktree add -B {branch} {worktree_path} {run_ref}" not in source


def test_nothing_pushes_a_synthesized_commit_to_origin():
    """ac3 as a source-level invariant: `core/run_transfer.py` is the only
    module that sends a synthesized commit anywhere, and origin is not a
    destination it knows."""
    source = (SRC / "core" / "run_transfer.py").read_text()
    assert "origin" not in source


def test_synthesis_is_the_only_git_add_and_it_carries_a_scratch_index():
    """The one thing no runtime test can catch: a future edit adding a git
    command to `synthesize_commit` WITHOUT the scratch-index env would stage the
    operator's work in progress against their real index."""
    source = (SRC / "core" / "run_transfer.py").read_text()
    assert source.count("git add -A") == 1
    assert source.count("GIT_INDEX_FILE") == 1
    body = source.split("def synthesize_commit", 1)[1].split("\ndef ", 1)[0]
    assert "GIT_INDEX_FILE" in body
    assert "git add -A" in body
    # Every git call in the function goes through `_checked(shell, …, env)`,
    # which is the single place the scratch-index env is applied.
    assert body.count("shell.run(") == 0
```

- [ ] **Step 2: Run it**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_remote_exact_copy_invariants.py -q`
Expected: `5 passed`.

If `test_only_the_declared_modules_name_the_scratch_namespace` fails, read the offending module: either it genuinely belongs in `ALLOWED` (add it, with the one-line reason), or the namespace has escaped and the code is wrong. If `test_the_pr_and_finish_paths_do_not_know_the_namespace_exists` fails on `cli/exec.py` or `cli/worktree.py`, a Task 12 or Task 14 call site is inlining the ref string — move it back behind `run_ref()`.

- [ ] **Step 3: No implementation needed**

- [ ] **Step 4: Run the whole core suite**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core -q`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
git add tests/core/test_remote_exact_copy_invariants.py
git commit -m "test(remote): guard that the scratch namespace never becomes history"
mship journal "ac14 guard: only 5 modules may name refs/mship/; pr/finish/cli paths must not; single git add -A under a scratch index" --action committed
```
<!-- /mship:task -->

---

# Piece 3 — setup on the run host, keyed

Exact source with stale dependencies is its own trap: change a manifest, run remotely, and the failure is a module-not-found with no visible relationship to the edit — the same confusing-staleness class the preflight was added to eliminate. So the run host **derives** what git cannot carry.

<!-- mship:task id=16 -->
### Task 16: Move the Taskfile-target check where core can reach it

**Files:**
- Create: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/src/mship/util/taskfile.py`
- Modify: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/src/mship/cli/exec.py` (delete `_taskfile_has_target`, lines 38–62; update its one caller at line 757)
- Test: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/tests/util/test_taskfile.py`

Task 19 needs "does this repo actually define a `setup` target?" on the run host, and `core/` must not import from `cli/`. `cli/exec.py` already owns that check with exactly one caller, so the existing owner **moves** rather than being copied — no new function, no second implementation.

Confirm the single caller before moving:

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
grep -rn "_taskfile_has_target" src/ tests/
```
Expected: exactly two hits, both in `src/mship/cli/exec.py` (the definition at line 38 and the call at line 757).

- [ ] **Step 1: Write the failing test**

Create `tests/util/test_taskfile.py`:

```python
"""`taskfile_has_target` — moved out of cli/exec.py so core can use it too."""
from mship.util.taskfile import taskfile_has_target

_WITH_SETUP = "version: '3'\ntasks:\n  setup:\n    cmds: [echo hi]\n"


def _taskfile(tmp_path, name="Taskfile.yml", body=_WITH_SETUP):
    (tmp_path / name).write_text(body)
    return tmp_path


def test_finds_a_declared_target(tmp_path):
    assert taskfile_has_target(_taskfile(tmp_path), "setup")


def test_missing_target_is_false(tmp_path):
    assert not taskfile_has_target(_taskfile(tmp_path), "lint")


def test_the_yaml_spelling_is_honoured(tmp_path):
    assert taskfile_has_target(_taskfile(tmp_path, name="Taskfile.yaml"), "setup")


def test_no_taskfile_is_false(tmp_path):
    assert not taskfile_has_target(tmp_path, "setup")


def test_an_unparseable_taskfile_is_false(tmp_path):
    assert not taskfile_has_target(_taskfile(tmp_path, body="{{{not yaml"), "setup")


def test_a_taskfile_without_a_tasks_map_is_false(tmp_path):
    assert not taskfile_has_target(_taskfile(tmp_path, body="version: '3'\n"), "setup")


def test_a_taskfile_whose_tasks_key_is_not_a_map_is_false(tmp_path):
    assert not taskfile_has_target(
        _taskfile(tmp_path, body="version: '3'\ntasks: [setup]\n"), "setup"
    )
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/util/test_taskfile.py -q`
Expected: collection error — `ModuleNotFoundError: No module named 'mship.util.taskfile'`

- [ ] **Step 3: Move the implementation**

Create `src/mship/util/taskfile.py`:

```python
"""Read a repo's go-task file without running go-task.

Moved verbatim out of `cli/exec.py` (where `mship logs` used it to turn a
missing target into an actionable error instead of go-task's general help text,
issue #125) so `core/remote_exec.py` can ask the same question on a run host —
`core` must not import from `cli`.
"""
from pathlib import Path

import yaml


def taskfile_has_target(repo_path, target: str) -> bool:
    """True if `<repo_path>/Taskfile.yml` (or .yaml) defines `target`.

    Reads the local Taskfile only; `includes:` are not recursed into. That
    covers the common case. False on a missing file or a parse error, which is
    the correct, fail-loud signal for the caller.
    """
    p = Path(repo_path)
    candidates = [p / "Taskfile.yml", p / "Taskfile.yaml"]
    taskfile = next((c for c in candidates if c.exists()), None)
    if taskfile is None:
        return False
    try:
        data = yaml.safe_load(taskfile.read_text())
    except Exception:
        return False
    if not isinstance(data, dict):
        return False
    tasks = data.get("tasks", {})
    if not isinstance(tasks, dict):
        return False
    return target in tasks
```

In `src/mship/cli/exec.py`, delete the whole `_taskfile_has_target` function (from `def _taskfile_has_target(repo_path, target: str) -> bool:` through its closing `return target in tasks`), and change its one call site inside `logs` from:

```python
            if not _taskfile_has_target(cwd, actual_task):
```

to:

```python
            from mship.util.taskfile import taskfile_has_target
            if not taskfile_has_target(cwd, actual_task):
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/util/test_taskfile.py tests/cli -q`
Expected: all pass — the `mship logs` tests still cover the moved behaviour through the CLI. Then confirm nothing still references the old name:

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
grep -rn "_taskfile_has_target" src/ tests/
```
Expected: no output.

- [ ] **Step 5: Commit**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
git add src/mship/util/taskfile.py src/mship/cli/exec.py tests/util/test_taskfile.py
git commit -m "refactor: move taskfile_has_target to util so core can use it"
mship journal "moved taskfile_has_target cli->util (single caller confirmed by grep); no copy, one owner" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=17 -->
### Task 17: `setup_inputs` per repo

**Files:**
- Modify: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/src/mship/core/config.py` (`RepoConfig`, immediately after the `run_host` field at line 205)
- Test: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/tests/core/test_config.py` (append)

- [ ] **Step 1: Write the failing tests**

Append to `tests/core/test_config.py`:

```python
def test_setup_inputs_defaults_to_nothing_declared():
    """ac17: no declaration is the honest default — there is nothing to
    invalidate against, so setup runs on first materialization only."""
    repo = RepoConfig(path=Path("./api"), type="service")
    assert repo.setup_inputs == []


def test_setup_inputs_accepts_manifests_and_globs():
    repo = RepoConfig(
        path=Path("./api"), type="service",
        setup_inputs=["package.json", "uv.lock", "**/build.gradle"],
    )
    assert repo.setup_inputs == ["package.json", "uv.lock", "**/build.gradle"]


def test_setup_inputs_parses_from_yaml(tmp_path):
    config_path = tmp_path / "mothership.yaml"
    (tmp_path / "api").mkdir()
    (tmp_path / "api" / "Taskfile.yml").write_text("version: '3'\ntasks:\n  run:\n    cmds: [echo]\n")
    config_path.write_text(
        "workspace: t\n"
        "repos:\n"
        "  api:\n"
        "    path: ./api\n"
        "    type: service\n"
        "    setup_inputs: [pyproject.toml, uv.lock]\n"
    )
    config = ConfigLoader.load(config_path)
    assert config.repos["api"].setup_inputs == ["pyproject.toml", "uv.lock"]
```

Before running, confirm `RepoConfig`, `ConfigLoader` and `Path` are already imported at the top of `tests/core/test_config.py`; add whichever is missing.

- [ ] **Step 2: Run them to verify they fail**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_config.py -q -k setup_inputs`
Expected: FAIL — `AttributeError: 'RepoConfig' object has no attribute 'setup_inputs'` (pydantic ignores the unknown kwarg, then the attribute lookup fails).

- [ ] **Step 3: Write the implementation**

In `src/mship/core/config.py`, add to `RepoConfig` immediately after the `run_host` field:

```python
    # Files whose CONTENT decides whether a remote run re-runs `task setup` on
    # the run host — this repo's manifests and lockfiles (e.g. package.json,
    # uv.lock, build.gradle). Glob patterns, matched inside the materialized
    # worktree. See mship.core.remote_setup.
    #
    # Empty (the default) is NOT "never run setup": it means there is nothing to
    # invalidate against, so setup runs the first time a worktree is
    # materialized on a host and not again. DECLARING inputs is what buys
    # re-run-on-change. Deliberately explicit rather than inferred — an operator
    # can see and widen a declared key; they cannot inspect a heuristic.
    setup_inputs: list[str] = []
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_config.py tests/core/test_example_config.py -q`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
git add src/mship/core/config.py tests/core/test_config.py
git commit -m "feat(config): setup_inputs per repo"
mship journal "RepoConfig.setup_inputs: explicit cache key for remote setup; empty = first materialization only" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=18 -->
### Task 18: The setup cache key

**Files:**
- Create: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/src/mship/core/remote_setup.py`
- Test: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/tests/core/test_remote_setup.py`

- [ ] **Step 1: Write the failing test**

Create `tests/core/test_remote_setup.py`:

```python
"""The `task setup` cache key on a run host.

A cache key of exactly the shape any build cache uses — and with the same
failure mode, which is precisely why the inputs are DECLARED rather than
guessed: an operator can see and widen a declared key, and cannot inspect a
heuristic.
"""
from pathlib import Path

from mship.core.remote_setup import (
    FIRST_MATERIALIZATION_KEY,
    key_file,
    needs_setup,
    record_setup,
    setup_key,
)


def _worktree(tmp_path: Path) -> Path:
    wt = tmp_path / "wt"
    (wt / "src").mkdir(parents=True)
    (wt / "package.json").write_text('{"deps": 1}\n')
    (wt / "src" / "app.js").write_text("console.log(1)\n")
    return wt


def test_no_declared_inputs_gives_the_first_materialization_key(tmp_path):
    """ac17: nothing to invalidate against, so the key never changes."""
    assert setup_key(_worktree(tmp_path), []) == FIRST_MATERIALIZATION_KEY


def test_the_key_changes_when_a_declared_input_changes(tmp_path):
    """ac16: a dependency change pays once."""
    wt = _worktree(tmp_path)
    before = setup_key(wt, ["package.json"])
    (wt / "package.json").write_text('{"deps": 2}\n')
    assert setup_key(wt, ["package.json"]) != before


def test_the_key_is_unchanged_by_a_source_only_edit(tmp_path):
    """ac16, the case the whole feature exists for: the common iteration pays
    nothing."""
    wt = _worktree(tmp_path)
    before = setup_key(wt, ["package.json"])
    (wt / "src" / "app.js").write_text("console.log(2)\n")
    assert setup_key(wt, ["package.json"]) == before


def test_globs_are_matched_inside_the_worktree(tmp_path):
    wt = _worktree(tmp_path)
    (wt / "src" / "package.json").write_text('{"nested": 1}\n')
    before = setup_key(wt, ["**/package.json"])
    (wt / "src" / "package.json").write_text('{"nested": 2}\n')
    assert setup_key(wt, ["**/package.json"]) != before


def test_a_declared_input_that_does_not_exist_is_not_an_error(tmp_path):
    """A repo that declares `uv.lock` before it has one must still run."""
    assert setup_key(_worktree(tmp_path), ["uv.lock"])


def test_adding_a_file_a_pattern_matches_moves_the_key(tmp_path):
    wt = _worktree(tmp_path)
    before = setup_key(wt, ["*.lock"])
    (wt / "uv.lock").write_text("locked\n")
    assert setup_key(wt, ["*.lock"]) != before


def test_widening_the_declaration_moves_the_key_by_itself(tmp_path):
    """The declaration is part of the key, so an operator who widens
    `setup_inputs` gets a re-run rather than a stale skip."""
    wt = _worktree(tmp_path)
    assert setup_key(wt, ["package.json"]) != setup_key(wt, ["package.json", "*.lock"])


def test_needs_setup_is_true_when_nothing_was_recorded(tmp_path):
    assert needs_setup(tmp_path / "absent.key", "abc")


def test_recording_then_asking_again_says_no(tmp_path):
    path = key_file(tmp_path, "t1", "api")
    record_setup(path, "abc")
    assert not needs_setup(path, "abc")
    assert needs_setup(path, "different")


def test_the_key_file_path_is_per_task_and_per_repo(tmp_path):
    assert key_file(tmp_path, "t1", "api") != key_file(tmp_path, "t2", "api")
    assert key_file(tmp_path, "t1", "api") != key_file(tmp_path, "t1", "web")


def test_a_task_name_cannot_escape_the_state_directory(tmp_path):
    """The task name arrives over the wire, where `core/serve.py` permits `/`
    and `.`, so `../..` would otherwise be a legal path component here."""
    path = key_file(tmp_path, "../../etc", "api")
    root = (tmp_path / ".mothership").resolve()
    assert root in path.resolve().parents
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_remote_setup.py -q`
Expected: collection error — `ModuleNotFoundError: No module named 'mship.core.remote_setup'`

- [ ] **Step 3: Write the implementation**

Create `src/mship/core/remote_setup.py`:

```python
"""When a run host needs to re-run `task setup`.

Exact source with stale dependencies is its own trap: change a manifest, run
remotely, and the failure is a module-not-found with no visible relationship to
the edit. So the run host DERIVES what git cannot carry — it runs `task setup`
against the source the push just delivered, rather than copying `node_modules`
over the wire.

Running setup on every invocation would defeat the fast loop this exists to
enable, so it is keyed:

  - setup runs the first time a worktree is materialized for a task on a host;
  - and again whenever the repo's declared `setup_inputs` differ from what that
    host last set up at.

A source-only edit — the common case — pays nothing. A dependency change pays
once. A repo declaring no `setup_inputs` gets setup on first materialization
only, because there is nothing to invalidate against.

This is a cache key of exactly the shape any build cache uses, and it has the
same failure mode: a repo whose setup depends on something undeclared will skip
a re-run it needed. The mitigation is that the key is explicit config an
operator can see and widen, not an inferred heuristic they cannot inspect.
"""
from __future__ import annotations

import hashlib
import re
from pathlib import Path

SETUP_STATE_DIRNAME = "remote-setup"

# The key recorded for a repo that declares no inputs: constant, so it matches
# on every run after the first and setup never repeats.
FIRST_MATERIALIZATION_KEY = "first-materialization"

_UNSAFE = re.compile(r"[^A-Za-z0-9_-]")


def _safe(name: str) -> str:
    """A filename component that cannot escape its directory.

    The task name arrives over the wire, where `core/serve.py`'s `_TASK_NAME_RE`
    permits `.` and `/` — so `../..` would otherwise be a legal path component
    here.
    """
    return _UNSAFE.sub("-", name) or "unnamed"


def key_file(workspace_root: Path, task: str, repo: str) -> Path:
    """Where this host records the key it last set `task`/`repo` up at."""
    return (
        Path(workspace_root) / ".mothership" / SETUP_STATE_DIRNAME
        / f"{_safe(task)}__{_safe(repo)}.key"
    )


def setup_key(worktree_path: Path, patterns: list[str]) -> str:
    """A digest of the declared setup inputs as they exist in this worktree.

    Every match of every pattern contributes its worktree-relative path AND its
    bytes, so a rename, an edit, an addition or a deletion all move the key. A
    pattern that matches nothing contributes nothing but is still folded in as a
    declaration, so WIDENING `setup_inputs` moves the key by itself rather than
    silently reusing a narrower run's result.
    """
    if not patterns:
        return FIRST_MATERIALIZATION_KEY

    digest = hashlib.sha256()
    root = Path(worktree_path)
    for pattern in patterns:
        digest.update(f"\0pattern:{pattern}\0".encode("utf-8"))
        for match in sorted(root.glob(pattern)):
            if not match.is_file():
                continue
            digest.update(str(match.relative_to(root)).encode("utf-8"))
            digest.update(b"\0")
            digest.update(match.read_bytes())
            digest.update(b"\0")
    return digest.hexdigest()


def needs_setup(path: Path, key: str) -> bool:
    """True when this host has not recorded a successful setup at `key`."""
    try:
        return path.read_text().strip() != key
    except OSError:
        return True


def record_setup(path: Path, key: str) -> None:
    """Record `key` as set up. Called ONLY after setup exits zero — recording a
    failed setup would cache the failure and skip the retry."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"{key}\n")
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_remote_setup.py -q`
Expected: `11 passed`

- [ ] **Step 5: Commit**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
git add src/mship/core/remote_setup.py tests/core/test_remote_setup.py
git commit -m "feat(remote): key task setup on the repo's declared setup_inputs"
mship journal "remote_setup: digest of declared inputs; empty = first-materialization sentinel; key path traversal-safe" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=19 -->
### Task 19: Run `task setup` on the run host

**Files:**
- Modify: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/src/mship/core/remote_exec.py` (`run_verb_stream`: two imports, one new inner generator, one call in the per-repo loop)
- Test: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/tests/core/test_serve_exec.py` (append)

- [ ] **Step 1: Write the failing tests**

Append to `tests/core/test_serve_exec.py`:

```python
# --- setup on the run host, keyed --------------------------------------------

def _config_with_setup(tmp_path: Path, *, setup_inputs=None) -> WorkspaceConfig:
    """A repo whose MATERIALIZED WORKTREE really has a Taskfile declaring
    `setup`. The Taskfile has to exist on disk because `taskfile_has_target`
    reads it — the fake shell cannot answer for it."""
    repo_dir = tmp_path / "api"
    repo_dir.mkdir(exist_ok=True)
    worktree = tmp_path / ".worktrees" / "t1" / "api"
    worktree.mkdir(parents=True, exist_ok=True)
    (worktree / "Taskfile.yml").write_text(
        "version: '3'\ntasks:\n  setup:\n    cmds: [echo setup]\n"
        "  start:\n    cmds: [echo run]\n"
    )
    (worktree / "package.json").write_text('{"deps": 1}\n')
    return WorkspaceConfig(
        workspace="t",
        repos={
            "api": RepoConfig(
                path=repo_dir, type="service",
                tasks={"run": "start"},
                setup_inputs=setup_inputs or [],
            ),
        },
    )


def _stream_run(deps, **kw) -> list[str]:
    return [
        l.decode() for l in remote_exec.run_verb_stream(
            "run", "t1", ["api"], None, deps=deps, nonce=_TEST_NONCE, **kw
        )
    ]


def test_setup_runs_the_first_time_a_worktree_is_materialized(tmp_path):
    """ac15: a fresh host builds its dependencies from the delivered source
    instead of failing on missing ones."""
    fake = _FakeShellRunner(streaming_proc=_FakeProc(stdout_lines=["ok\n"]))
    deps = remote_exec.RemoteExecDeps(
        config=_config_with_setup(tmp_path), shell=fake, workspace_root=tmp_path,
    )

    _stream_run(deps)

    assert [c["command"] for c in fake.streaming_calls] == ["task setup", "task start"]


def test_setup_is_skipped_on_the_next_run(tmp_path):
    """ac16: a source-only iteration pays no setup cost."""
    config = _config_with_setup(tmp_path)
    first = _FakeShellRunner(streaming_proc=_FakeProc(stdout_lines=["ok\n"]))
    _stream_run(remote_exec.RemoteExecDeps(
        config=config, shell=first, workspace_root=tmp_path))

    second = _FakeShellRunner(streaming_proc=_FakeProc(stdout_lines=["ok\n"]))
    _stream_run(remote_exec.RemoteExecDeps(
        config=config, shell=second, workspace_root=tmp_path))

    assert [c["command"] for c in second.streaming_calls] == ["task start"]


def test_setup_re_runs_when_a_declared_input_changes(tmp_path):
    """ac16: a dependency change pays once."""
    config = _config_with_setup(tmp_path, setup_inputs=["package.json"])
    first = _FakeShellRunner(streaming_proc=_FakeProc(stdout_lines=["ok\n"]))
    _stream_run(remote_exec.RemoteExecDeps(
        config=config, shell=first, workspace_root=tmp_path))

    (tmp_path / ".worktrees" / "t1" / "api" / "package.json").write_text('{"deps": 2}\n')
    second = _FakeShellRunner(streaming_proc=_FakeProc(stdout_lines=["ok\n"]))
    _stream_run(remote_exec.RemoteExecDeps(
        config=config, shell=second, workspace_root=tmp_path))

    assert [c["command"] for c in second.streaming_calls] == ["task setup", "task start"]


def test_declaring_no_inputs_means_setup_runs_once_only(tmp_path):
    """ac17: nothing to invalidate against, even when a manifest changes."""
    config = _config_with_setup(tmp_path)
    first = _FakeShellRunner(streaming_proc=_FakeProc(stdout_lines=["ok\n"]))
    _stream_run(remote_exec.RemoteExecDeps(
        config=config, shell=first, workspace_root=tmp_path))

    (tmp_path / ".worktrees" / "t1" / "api" / "package.json").write_text('{"deps": 9}\n')
    second = _FakeShellRunner(streaming_proc=_FakeProc(stdout_lines=["ok\n"]))
    _stream_run(remote_exec.RemoteExecDeps(
        config=config, shell=second, workspace_root=tmp_path))

    assert [c["command"] for c in second.streaming_calls] == ["task start"]


def test_a_failing_setup_fails_the_run_with_its_own_output(tmp_path):
    """ac18: not a downstream error that does not name the real cause."""
    fake = _FakeShellRunner(
        streaming_proc=_FakeProc(stdout_lines=["npm ERR! ENOENT\n"], returncode=3),
    )
    deps = remote_exec.RemoteExecDeps(
        config=_config_with_setup(tmp_path), shell=fake, workspace_root=tmp_path,
    )

    lines = _stream_run(deps)

    assert "npm ERR! ENOENT\n" in lines                       # setup's own output
    assert any(l.startswith("error:") and "setup" in l and "api" in l for l in lines)
    assert lines[-1] == f"{remote_exec.EXIT_MARKER}:{_TEST_NONCE} 3\n"
    assert [c["command"] for c in fake.streaming_calls] == ["task setup"]  # run never started


def test_a_failed_setup_is_not_recorded_as_done(tmp_path):
    """Caching a failure would skip the retry."""
    config = _config_with_setup(tmp_path)
    failing = _FakeShellRunner(streaming_proc=_FakeProc(returncode=1))
    _stream_run(remote_exec.RemoteExecDeps(
        config=config, shell=failing, workspace_root=tmp_path))

    second = _FakeShellRunner(streaming_proc=_FakeProc(stdout_lines=["ok\n"]))
    _stream_run(remote_exec.RemoteExecDeps(
        config=config, shell=second, workspace_root=tmp_path))

    assert [c["command"] for c in second.streaming_calls][0] == "task setup"


def test_a_repo_with_no_setup_target_is_not_failed_over_it(tmp_path):
    """ac15's second half: `task setup` in a repo that never declared one exits
    non-zero, and that must not turn every remote run into a failure."""
    config = _config_with_setup(tmp_path)
    (tmp_path / ".worktrees" / "t1" / "api" / "Taskfile.yml").write_text(
        "version: '3'\ntasks:\n  start:\n    cmds: [echo run]\n"
    )
    fake = _FakeShellRunner(streaming_proc=_FakeProc(stdout_lines=["ok\n"]))

    _stream_run(remote_exec.RemoteExecDeps(
        config=config, shell=fake, workspace_root=tmp_path))

    assert [c["command"] for c in fake.streaming_calls] == ["task start"]


def test_a_repo_declaring_setup_not_applicable_skips_it(tmp_path):
    config = _config_with_setup(tmp_path)
    config.repos["api"].not_applicable = ["setup"]
    fake = _FakeShellRunner(streaming_proc=_FakeProc(stdout_lines=["ok\n"]))

    _stream_run(remote_exec.RemoteExecDeps(
        config=config, shell=fake, workspace_root=tmp_path))

    assert [c["command"] for c in fake.streaming_calls] == ["task start"]


def test_setup_honours_an_aliased_target_name(tmp_path):
    """A repo may spell its setup target something else via `tasks:`."""
    config = _config_with_setup(tmp_path)
    config.repos["api"].tasks = {"run": "start", "setup": "bootstrap"}
    (tmp_path / ".worktrees" / "t1" / "api" / "Taskfile.yml").write_text(
        "version: '3'\ntasks:\n  bootstrap:\n    cmds: [echo boot]\n"
        "  start:\n    cmds: [echo run]\n"
    )
    fake = _FakeShellRunner(streaming_proc=_FakeProc(stdout_lines=["ok\n"]))

    _stream_run(remote_exec.RemoteExecDeps(
        config=config, shell=fake, workspace_root=tmp_path))

    assert [c["command"] for c in fake.streaming_calls] == ["task bootstrap", "task start"]
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_serve_exec.py -q -k setup`
Expected: FAIL — `assert [...] == ["task setup", "task start"]` sees only `["task start"]`; setup is never run.

- [ ] **Step 3: Write the implementation**

In `src/mship/core/remote_exec.py`, add the imports next to the others at the top:

```python
from mship.core import remote_setup
from mship.util.taskfile import taskfile_has_target
```

Add this generator inside `run_verb_stream`, immediately **after** the `_ensure_materialized` definition:

```python
    def _ensure_setup(repo_name: str, repo_config, worktree_path: Path) -> Iterator[bytes]:
        """Run `task setup` in a freshly-materialized worktree when it is
        needed, streaming its output live exactly like the verb itself.

        Git carries source, not dependencies. Without this, an exact-source run
        against stale dependencies fails with a module-not-found that has no
        visible relationship to the edit — the same confusing-staleness class
        the rest of this feature exists to eliminate. So the host DERIVES them.

        Keyed (see `core/remote_setup.py`): the first materialization on this
        host, then only when the repo's declared `setup_inputs` change. Skipped
        entirely for a repo that declares `setup` not applicable or whose
        Taskfile has no such target — `task setup` in a repo that never defined
        one exits non-zero, and that must not fail every remote run.

        PEP 380 value: True to continue, False when setup FAILED — in which case
        the error line and the exit sentinel have ALREADY been emitted and the
        caller MUST return, exactly like `_ensure_materialized`.
        """
        if "setup" in repo_config.not_applicable:
            return True
        actual_setup = repo_config.tasks.get("setup", "setup")
        if not taskfile_has_target(worktree_path, actual_setup):
            return True

        key = remote_setup.setup_key(worktree_path, repo_config.setup_inputs)
        key_path = remote_setup.key_file(deps.workspace_root, task, repo_name)
        if not remote_setup.needs_setup(key_path, key):
            return True

        yield f"setup: {repo_name} (task {actual_setup})\n".encode("utf-8")
        env_runner = repo_config.env_runner or config.env_runner
        command = shell.build_command(f"task {actual_setup}", env_runner)
        proc = None
        try:
            proc = shell.run_streaming(command, cwd=worktree_path, env=None)
            yield from _stream_proc_lines(proc)
            setup_code = proc.wait()
        finally:
            _terminate_proc(proc)

        if setup_code != 0:
            # Surface setup's OWN failure rather than letting the verb run
            # against half-built dependencies and report something that does not
            # name the real cause (spec ac18).
            yield (
                f"error: `task {actual_setup}` failed on the run host for repo "
                f"{repo_name!r} (exit {setup_code}); the output above is setup's "
                f"own. The {verb} was not started.\n"
            ).encode("utf-8")
            yield f"{EXIT_MARKER}:{nonce} {setup_code}\n".encode("utf-8")
            return False

        # Recorded only after a SUCCESSFUL setup: caching a failure would skip
        # the retry that fixes it.
        remote_setup.record_setup(key_path, key)
        return True
```

Then in the per-repo loop, immediately after `worktree_path` is resolved (i.e. after the whole `if repo_config.git_root is not None: … else: …` block) and **before** `actual_task_name = repo_config.tasks.get(verb, verb)`, add:

```python
        if not (yield from _ensure_setup(repo_name, repo_config, worktree_path)):
            return
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_serve_exec.py -q`
Expected: all pass. The pre-existing tests use `_config`/`_config_with_child`, whose worktree directories have no Taskfile at all, so `taskfile_has_target` returns False and setup never fires for them — if any of them now shows an extra `task setup` streaming call, a fixture has gained a Taskfile it did not have.

- [ ] **Step 5: Commit**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
git add src/mship/core/remote_exec.py tests/core/test_serve_exec.py
git commit -m "feat(remote): run task setup on the run host, keyed on setup_inputs"
mship journal "remote setup: first materialization + declared-input changes only; failure fails the run with setup's own output; missing target skipped" --action committed
```
<!-- /mship:task -->

---

# Close-out

<!-- mship:task id=20 -->
### Task 20: Say plainly what travels and what does not

**Files:**
- Modify: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/docs/remote-run.md` (replace the `## Before it dispatches` section added by #419, lines 99–150; and the first bullet of `## Known limitations (v1)`, line 92)
- Modify: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/docs/configuration.md` (per-repo field table after the `run_host` row at line 237; and the example block at line 257)
- Test: `/home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership/tests/core/test_remote_exact_copy_invariants.py` (append)

#419's docs section says tracked changes are refused and that untracked files will not exist on the run host. Both statements become false with this change; leaving them is worse than having written nothing.

- [ ] **Step 1: Write the failing tests**

Append to `tests/core/test_remote_exact_copy_invariants.py`:

```python
# --- ac19: the docs say what travels ----------------------------------------

DOCS = Path(__file__).resolve().parents[2] / "docs"


def _remote_run_doc() -> str:
    return (DOCS / "remote-run.md").read_text().lower()


def test_docs_state_that_uncommitted_work_travels_and_never_reaches_origin():
    t = _remote_run_doc()
    assert "uncommitted" in t
    assert "untracked" in t
    assert "never" in t and "origin" in t


def test_docs_state_what_does_not_travel():
    """ac19: secrets, platform state, symlink_dirs/bind_files."""
    t = _remote_run_doc()
    assert ".env" in t or "secret" in t
    assert "symlink_dirs" in t and "bind_files" in t
    assert "gitignore" in t


def test_docs_state_that_dependencies_are_derived_by_setup():
    """ac19 + ac17, including that the first run on a fresh host is a one-time
    cost rather than a regression."""
    t = _remote_run_doc()
    assert "task setup" in t
    assert "setup_inputs" in t
    assert "first" in t


def test_docs_name_the_scratch_ref_as_throwaway():
    """ac13: an operator reading the output must not think it is their commit."""
    t = _remote_run_doc()
    assert "refs/mship/run" in t
    assert "throwaway" in t


def test_docs_no_longer_claim_a_dirty_tree_is_refused():
    """The #419 wording is now false; leaving it would be worse than silence."""
    t = _remote_run_doc()
    assert "tracked changes present" not in t


def test_configuration_documents_setup_inputs():
    """ac17: declaring them is what enables re-run-on-change."""
    t = (DOCS / "configuration.md").read_text().lower()
    assert "setup_inputs" in t
    assert "re-run" in t or "rerun" in t
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_remote_exact_copy_invariants.py -q -k "docs or configuration"`
Expected: FAIL on the six docs tests (`assert "uncommitted" in t`, etc.).

- [ ] **Step 3: Write the docs**

In `docs/remote-run.md`, replace the whole `## Before it dispatches` section (everything from that heading down to, but not including, `## Troubleshooting`) with:

```markdown
## What travels to the run host

`--remote` runs the code you are looking at, **including work you have not
committed**. Before dispatching, mship reads every repo the task touches and
takes one of three paths per repo:

- **Working tree differs from HEAD** — tracked edits, untracked files, or both →
  mship builds a commit from your working tree and pushes it **straight to the
  run host**, onto a throwaway ref (`refs/mship/run/<task>/<repo>`). The host
  resets a worktree to that ref and runs it. **Nothing is pushed to origin on
  this path**, and nothing on your machine changes: your HEAD, your branch, your
  index and `git status` are exactly as you left them, and the synthesized commit
  belongs to no branch. mship names it as a throwaway run ref in the output for
  that reason — do not build on it.
- **Clean, but origin is missing the branch or is behind it** → mship pushes the
  branch to origin for you, then dispatches. There is nothing extra to send, so
  this is the old, fast path. If origin has a commit you do not, mship **refuses**
  — a push cannot fast-forward from behind, and the run would execute a commit
  you have never seen. It prints the `git pull --ff-only` that fixes it.
- **Mid-merge, mid-rebase, or with unmerged paths** → mship **refuses**, and
  names the command that unblocks you. Files in that state hold conflict markers,
  and a remote failure over a conflict marker tells you nothing about the edit
  you were making.

It also still refuses a worktree that is not on the task's branch, a repo whose
git state it cannot read, and a worktree that is missing — in each case naming
which, because the remedies differ.

Every repo **the run will actually touch** is checked, not just the one you are
standing in: a task has a branch per repo and the run host materializes each
separately. `--repos` / `--tag` narrow the check as well as the run, so work in
progress in a repo you excluded neither blocks the run nor gets sent.

### Why the run host and not origin

Routing uncommitted work through origin would publish it. `git add -A` sweeps in
untracked files, so a debug dump, a data sample or a throwaway script with a
token in it would land on GitHub. Refs under `refs/mship/` are outside the
default fetch refspec but they are not private — `git ls-remote` enumerates them
and anyone with read access can fetch them, which on a public repo means anyone —
and deleting the ref afterwards does not retract the objects, because they stay
reachable by sha. The destination is your own machine, so there is no reason for
a third party to be in the path. **Real history goes to origin; throwaway state
goes host to host.**

The run host accepts these pushes on a purpose-built endpoint (`/git/<repo>`)
that is bearer-authenticated with the same run-host token, accepts only repos
that workspace declares, and accepts writes only onto the `refs/mship/run/*`
namespace. It is not a mirror, not a remote you add by hand, and not a path for
real history. Each run force-updates its own ref, and `mship close` deletes the
task's scratch refs from the host.

Nothing here changes what `mship finish` requires. The scratch namespace is not
a branch, is not PR-able, and no code path merges or branches from it — so
nothing reaches a PR unreviewed.

### The guarantee, and where it stops

On the clean path mship pushes the **exact sha it resolved HEAD to** during
inspection — `<sha>:refs/heads/<branch>` — rather than letting git resolve `HEAD`
(or the branch) a second time when the push runs moments later. On the dirty path
the same sha becomes the synthesized snapshot's parent. Either way, if something
else commits in the worktree in between — a subagent, a background job — the run
still carries the commit every check actually cleared.

That guarantee ends at origin, and this is a real limit, not a hypothetical one:
**the commit *pushed* is the commit *inspected*; that is not the same claim as
"the commit *executed* is the commit inspected."** Once a push to origin lands,
the branch there is a mutable ref, and anyone with push access can advance it
before the run host fetches it — after mship has finished checking, on a
different machine's clock, outside this process entirely. Closing that gap would
need the run host to materialize an immutable revision instead of resolving a
branch at fetch time. The **dirty path already does exactly that**: it
materializes a specific commit from a ref nothing else writes, with no fetch at
all. The clean path does not.

### Dependencies are derived there, not copied

Git carries source, not `node_modules`. So after materializing, the run host runs
**`task setup`** in that worktree, rebuilding dependencies from the manifests the
push just delivered.

That is keyed, or it would defeat the fast loop this exists to enable:

- setup runs the **first time** a worktree is materialized for a task on that
  host — so the first remote run on a fresh host is the slowest it will ever be,
  a one-time cost rather than a regression;
- and again whenever the repo's declared **`setup_inputs`** (its manifests and
  lockfiles — `package.json`, `uv.lock`, `build.gradle`) differ from what that
  host last set up at.

A source-only edit, the common case, pays nothing. A dependency change pays once.
**A repo that declares no `setup_inputs` gets setup on first materialization
only**, because there is nothing to invalidate against — declaring them is what
buys re-run-on-change. A repo that defines no `setup` target at all is skipped
rather than failed. If setup fails, the run stops and you see setup's own output.

### What does not travel

- **Gitignored files.** `.env` and other secrets, build output, virtualenvs,
  `node_modules`. Where they can be rebuilt from tracked manifests that is now
  setup's job; where they cannot — secrets, platform state — they simply are not
  there, and you put them on the run host yourself.
- **`symlink_dirs` / `bind_files`.** Still not replicated on the run host.
- **Your machine.** The source is exact and the dependency environment is derived
  from it, but the run host is not a clone of your box.
```

In the same file, replace the first bullet of `## Known limitations (v1)` (the one beginning `- **The remote worktree is a bare \`git fetch\` + \`git worktree add\`.**`) with:

```markdown
- **`symlink_dirs` / `bind_files` are not replicated on the remote worktree.** `task setup` now runs there (see "Dependencies are derived there, not copied"), so a repo whose deps come from tracked manifests works. A repo that depends on symlinked gitignored material from your source checkout still does not.
```

In `docs/configuration.md`, add a row to the per-repo field table immediately after the `run_host` row:

```markdown
| `setup_inputs` | Manifests/lockfiles whose content decides whether a **remote** run re-runs `task setup` on the run host (glob patterns, matched inside the materialized worktree). Undeclared means setup runs on first materialization only — declaring them is what enables re-run-on-change. See [`remote-run.md`](remote-run.md). |
```

and add this line to the example block's `ground-control` entry (the one that already carries `run_host: android-emu-host`), immediately after its `run_host:` line:

```yaml
    setup_inputs: [build.gradle, gradle/libs.versions.toml]   # remote runs re-run `task setup` when these change
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && uv run pytest tests/core/test_remote_exact_copy_invariants.py -q`
Expected: `11 passed`

- [ ] **Step 5: Commit**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
git add docs/remote-run.md docs/configuration.md tests/core/test_remote_exact_copy_invariants.py
git commit -m "docs(remote): what travels to the run host, and what does not"
mship journal "docs: exact source / derived deps / nothing to origin / setup_inputs; the mutable-ref limit restated per path; pinned by tests" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=21 -->
### Task 21: Full suite, and a read of the whole diff

**Files:** none (verification only)

- [ ] **Step 1: Run the full suite the way CI does**

Run: `mship test --repos mothership`
Expected: `mothership` reports `pass`. This is ac20 — do not claim completion on a partial run.

- [ ] **Step 2: Confirm the git plumbing was exercised against real repositories**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
uv run pytest tests/core/test_run_transfer.py tests/core/test_git_receive.py -q --collect-only | tail -3
```
Expected: a non-zero collected count. Those files use a real `ShellRunner`, real `git`, real temporary repositories and (in `test_git_receive.py`) a real socket — ac20's "not a mocked shell, because the whole risk here is in git's actual behaviour".

- [ ] **Step 3: Confirm none of #419's ten fixes was lost**

```bash
cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership
uv run pytest tests/core/test_remote_preflight.py -q -v | grep -c PASSED
git diff main...HEAD --stat -- tests/core/test_remote_preflight.py
git diff main...HEAD -- tests/core/test_remote_preflight.py | grep '^-def test_' | sort
git diff main...HEAD -- tests/core/test_remote_preflight.py | grep '^+def test_' | sort
```
Expected: the first command reports **at least 35** passing tests (33 on `main`, minus none, plus the ten added in Task 6 — several inverted tests were renamed, so the count rises). The last two commands must show every removed `def test_` name reappearing as an added name, possibly renamed per the disposition table at the top of this plan. **A removed name with no corresponding addition is a deleted guarantee — stop and restore it.**

- [ ] **Step 4: Read the diff for the three things no test catches**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/remote-exact-copy/mothership && git diff main...HEAD --stat`

Then check by eye:

1. **`push()` in `remote_preflight.py` is byte-identical to `main`.**
   `git diff main...HEAD -- src/mship/core/remote_preflight.py | grep -A5 'def push'` — expected: no output (the function does not appear in the diff at all).
2. **Every `git add -A` this change introduces is inside a block that also sets `GIT_INDEX_FILE`.**
   `grep -rn "git add -A" src/mship/` — expected: the only hit in code added by this branch is the one in `synthesize_commit`. (Task 15 pins this, but read it once with your own eyes: this is the one mistake that would silently stage an operator's work in progress.)
3. **No new code path sends a synthesized sha to origin.**
   `grep -rn "origin" src/mship/core/run_transfer.py` — expected: no output.

- [ ] **Step 5: Sanity-check the CLI against the real thing, then finish**

With a run host mapped (`mship run-host list` shows one), from a task worktree with an uncommitted edit:

```bash
mship run --remote
```

Expected: a line of the shape `api: sent your working tree to the run host as refs/mship/run/<task>/api (abc123def456) — a throwaway run ref, not a commit on feat/<task>`, then the remote task's output. Afterwards, on this machine, `git status --porcelain` is unchanged and `git log --oneline -1` is the same commit as before.

If no run host is mapped, skip this step and say so in the PR body rather than claiming it passed.

```bash
cd /home/bailey/development/repos/mship-workspace
mship journal "full suite green; git plumbing covered by real-repo tests; #419's ten fixes verified intact; diff read for GIT_INDEX_FILE and origin leaks" --action verified
mship finish
```
<!-- /mship:task -->

---

## Self-review

Run after Task 21, before `mship finish`.

**1. Spec coverage.** Walk the coverage table near the top of this plan against `mship spec show remote-exact-copy` and confirm each criterion's task actually landed the assertion named there. The four easiest to fake and hardest to notice:

- **ac1's second half** — the test must use a file that is BOTH tracked and gitignored, not merely a dirty tree (Task 7 `test_a_tracked_file_that_is_also_gitignored_survives`).
- **ac2** — the test must compare HEAD, branch, `git status` AND the staged file list, on a **real** repo (Task 7 `test_local_state_is_identical_before_and_after`).
- **ac3** — a positive assertion that no origin push happened, not the absence of a test (Task 12 `test_a_dirty_worktree_is_sent_to_the_run_host_not_to_origin`, Task 6's `test_a_real_dirty_repo_is_transferred_and_origin_is_untouched`, and Task 15's source-level guard).
- **ac5/ac6** — refusals asserted with **real git driving the push** over a socket (Task 5), not only through TestClient.

**2. Placeholder scan.** `grep -nE "TODO|TBD|implement later|appropriate error handling|similar to Task" docs/plans/2026-07-26-remote-exact-copy.md` must be empty.

**3. Type consistency.** These names cross task boundaries and must match exactly:

- `run_ref(task, repo)` / `is_run_ref(name)` / `RUN_REF_PREFIX` / `RunRefNameError` (Task 1) — used in Tasks 2, 8, 11, 12, 14, 15.
- `RepoState.dirty` / `RepoState.git_repo` / `RepoState.head_sha` / `RepoState.path` / `RepoState.branch`, and `Preflight.dirty` / `.to_push` / `.blocked` / `.ok` (Task 6) — read in Task 12.
- `inspect(task, shell, *, repos=..., config=...)` — the keyword names in Task 6 and Task 12 must agree, and `repos=target_repos` must still be passed.
- `synthesize_commit(shell, repo_root, *, base_sha)`, `push_run_ref(shell, repo_root, *, conn, repo, task, sha)`, `delete_run_ref(shell, repo_root, *, conn, repo, task)`, `extra_header_env(token)`, `cleanup_run_refs(task, *, config, store, shell, warn)` (Tasks 7, 8, 14) — called in Tasks 12, 13, 14.
- `run_ref_repos` — the same spelling in `exec_remote`, `ExecBody`, `run_verb_stream` and the CLI (Tasks 9, 11, 12).
- `materialize_worktree(..., repo_name=..., run_ref=...)` (Task 10) — called in Tasks 11 and 13.
- `setup_key`, `key_file`, `needs_setup`, `record_setup`, `FIRST_MATERIALIZATION_KEY` (Task 18) — called in Task 19.
- `taskfile_has_target` (Task 16) — called in Task 19 and by `cli/exec.py`'s `logs`.

**4. The two things to re-read before merging.**

- `synthesize_commit` is the only function in this change that runs `git add -A`. Confirm once more that the env dict is built **once** and passed to all four git calls, and that every call goes through `_checked`. A future edit adding a fifth git command without that env would stage the operator's work in progress, and only Task 15's source-level guard would notice.
- `remote_preflight.push()` still names `s.head_sha` in its refspec, and `cli/exec.py` still calls `inspect(..., repos=target_repos)`. Those are #419's fixes 7 and 5, and they are the two this change came closest to disturbing.
