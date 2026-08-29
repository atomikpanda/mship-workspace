---
id: remote-exact-copy
title: Exact-copy remote runs via a scratch ref
status: implemented
created_at: '2026-07-26T00:10:07.629460Z'
updated_at: '2026-07-28T11:45:52.237267Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: "With a dirty working tree, `mship run --remote` executes the operator's uncommitted\
    \ content: a test asserts the tree the run host is asked to materialize contains\
    \ the modified file exactly as it is on disk, and a second test asserts a file\
    \ that is BOTH tracked and gitignored survives \u2014 `git add -A` into an empty\
    \ index silently drops those, so the temporary index must be seeded from HEAD\
    \ first."
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac2
  text: "Synthesizing the commit leaves local state untouched \u2014 HEAD, the current\
    \ branch, the index, and `git status` output are identical before and after, and\
    \ no commit appears in the branch's history or in `git branch` \u2014 verified\
    \ against a real git repo rather than a mocked shell"
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac3
  text: 'On the dirty path nothing is pushed to origin: a test asserts the operator''s
    origin remote receives no push, and the synthesized objects exist only locally
    and on the run host'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac4
  text: "The client pushes the synthesized commit to the run host's git receive endpoint\
    \ with the run-host bearer supplied out of band \u2014 never in the remote URL,\
    \ never written to git config, and never on the command line, since process arguments\
    \ are world-readable via /proc. A test asserts the token appears in none of those\
    \ three places."
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac5
  text: The receive endpoint refuses a push onto any ref outside `refs/mship/run/*`,
    and refuses any repo not configured in the workspace, with both refusals covered
    by tests
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac6
  text: The receive endpoint requires the run-host bearer and rejects an unauthenticated
    push
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac7
  text: "The scratch ref is per task AND per GIT repository (`refs/mship/run/<task>/<repo>`),\
    \ keyed on the top-level repo when a monorepo child declares a `git_root` \u2014\
    \ such a child has no git directory of its own, so parent and child dedupe to\
    \ one push, and the receive endpoint refuses a child name and names the parent\
    \ instead."
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac8
  text: Each run force-updates its own scratch ref, and `mship close` deletes the
    task's scratch refs from the run host so they do not accumulate
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  - kind: commit
    ref: 00d418b6770469d943230d013665a38505b04739
    note: null
  comment: null
- id: ac9
  text: "A working tree with no `git status --porcelain` output takes the existing\
    \ path: the branch is pushed to origin and no scratch ref is created. Any porcelain\
    \ output at all counts as dirty, including untracked-only \u2014 otherwise untracked\
    \ files would never travel, contradicting the criterion that they do."
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac10
  text: The run host materializes the pushed ref by resetting to it without fetching
    from origin, with a test that a stale existing worktree ends up at the pushed
    ref's tree rather than the branch tip
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac11
  text: Untracked files are included (they are part of what the operator sees, and
    they travel only to the operator's own run host), while gitignored files are not,
    and a test pins both
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac12
  text: A repo in a conflicted or mid-rebase state is refused with an actionable message
    rather than shipping conflict markers to the run host
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac13
  text: The CLI names the synthesized revision as a throwaway run ref rather than
    as a commit the operator made, so nobody tries to build on it. The synthesis is
    client-side, so this is local output, not something the run host reports.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac14
  text: 'Nothing reaches a PR unreviewed: `finish` still requires real commits, the
    scratch namespace exists only on run hosts, and no code path merges or branches
    from `refs/mship/`'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  - kind: commit
    ref: 00d418b6770469d943230d013665a38505b04739
    note: null
  - kind: commit
    ref: 05cf141395f436cf0e257c0afb208fecee42abe6
    note: null
  comment: null
- id: ac15
  text: "`task setup` runs on the run host the first time a worktree is materialized\
    \ for a task, so a fresh host builds its dependencies from the delivered source\
    \ instead of failing on missing ones \u2014 and a repo that defines no setup target\
    \ is skipped rather than failed, since `task setup` exits non-zero when the target\
    \ is undefined."
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  - kind: commit
    ref: 00d418b6770469d943230d013665a38505b04739
    note: null
  comment: null
- id: ac16
  text: Setup re-runs when the repo's declared `setup_inputs` differ from what that
    run host last set up at, and is skipped when they are unchanged, so a source-only
    iteration pays no setup cost
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac17
  text: A repo that declares no `setup_inputs` runs setup on first materialization
    only, and the documentation states that declaring them is what enables re-run-on-change
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac18
  text: A failing `task setup` on the run host fails the run with setup's own output
    surfaced, rather than permitting a downstream error that does not name the real
    cause
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac19
  text: 'The docs state plainly what does and does not travel: the source is exact,
    uncommitted work goes only to the operator''s own run host and never to origin,
    dependencies are derived there by setup, and secrets, platform state, and `symlink_dirs`/`bind_files`
    still do not travel'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac20
  text: '`mship test --repos mothership` passes; the git plumbing is exercised against
    real temporary repositories, not a mocked shell, because the whole risk here is
    in git''s actual behaviour'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
open_questions: []
non_goals:
- Syncing gitignored files (.venv, node_modules, .env, build output) over the wire.
  Git cannot carry them; where they can be rebuilt from tracked manifests that is
  now setup's job, and where they cannot (secrets, platform state) it needs file-level
  sync (rsync/mutagen-shaped), which is a separate decision with its own security
  surface
- "Replicating `symlink_dirs` / `bind_files` on the run host \u2014 an existing documented\
  \ gap, unchanged here"
- Making the receive endpoint a general-purpose git host. It accepts pushes only for
  known workspace repos and only onto the `refs/mship/run/*` namespace; it is not
  a mirror, not a remote an operator adds by hand, and not a path for real history
- Changing what a normal (non-remote) run does, or what `mship commit` / `finish`
  push
- 'Making the scratch ref usable as real history: it is not a branch, is not PR-able,
  and is not intended to be merged from'
- 'Cloud workers or the relay egress path: this is the operator''s own trusted run
  host, reached over the tailnet or relay'
- "Two-way sync \u2014 output and artifacts already come back over the existing exec\
  \ stream; nothing writes back into the operator's tree"
- Inferring setup inputs automatically. The key is explicit per-repo config an operator
  can see and widen, not a heuristic that guesses which files matter
risks:
- 'The synthesis recipe is the highest-risk part and its failure is silent: an empty
  temporary index drops tracked-and-gitignored files without error, producing a run
  host executing code that differs from what the operator sees. It needs a test with
  exactly that file shape, not merely a dirty-tree test.'
- "Any mechanism that carries the bearer on a command line leaks it to every user\
  \ on the machine via /proc. The env-variable route avoids it, but so would several\
  \ plausible refactors that reintroduce `-c` for convenience \u2014 worth a test\
  \ asserting the token is absent from the invocation, not just that auth works."
- "A synthesized commit must never touch the operator's real state. `git add -A` against\
  \ the DEFAULT index would stage their work in progress \u2014 a destructive surprise\
  \ \u2014 so the temporary `GIT_INDEX_FILE` is load-bearing, not an implementation\
  \ detail, and deserves a test that asserts the index and HEAD are unchanged afterwards"
- A git receive endpoint is a write path into a repository. Unscoped it becomes an
  arbitrary-ref-write primitive against the run host, so the repo allowlist and the
  `refs/mship/run/*` ref-name constraint are security controls rather than tidiness,
  and both need tests that assert refusal
- "It widens the single-bearer surface tracked in #370: that token would now also\
  \ authorize git pushes. The practical increase is small \u2014 the same bearer already\
  \ authorizes `POST /exec`, which runs arbitrary task targets on that host, so a\
  \ holder can already do worse \u2014 but #370's scoping work should account for\
  \ this route rather than discover it"
- Scratch refs accumulate on the run host. Without cleanup they are a slow leak of
  objects nothing deletes; deletion on task close (and a force-push per run) is part
  of the feature rather than a follow-up. They are at least on the operator's own
  machine now, so a missed cleanup is disk, not disclosure
- "Force-pushing the scratch ref is required (each run replaces the last) and is safe\
  \ only because nothing else writes that namespace \u2014 which is exactly why it\
  \ must be `refs/mship/run/...` and never anything a human might branch from"
- An operator seeing a commit sha in remote output may reasonably try to `git show`
  it locally and find it detached from any branch; the output should name it as a
  throwaway run ref rather than presenting it as a commit they made
- "The tree comes from the working directory, so a repo mid-rebase or with conflict\
  \ markers will happily produce a commit containing them \u2014 worth detecting rather\
  \ than shipping a confusing remote failure"
- This weakens the incentive to commit before running, which is usually healthy; the
  mitigation is that it changes nothing about what `finish` requires, so nothing reaches
  a PR unreviewed
- Keying setup on declared inputs means a repo whose setup depends on something undeclared
  will silently skip a re-run it needed. That is the failure shape of every build
  cache; the mitigation is that the key is explicit config an operator can widen rather
  than an inferred heuristic they cannot inspect
- The first materialization on a fresh run host now pays full setup cost, making it
  the slowest a remote run will ever be. Worth stating in the docs so it reads as
  a one-time cost rather than a regression against today's behaviour
task_slug: null
work_item_id: null
clarification_reason: null
prose_verdicts: {}
---
## Problem

`--remote` runs whatever is on origin, because the run host materializes the task's branch by fetching it (`remote_exec.materialize_worktree`). The preflight added alongside this spec closes the silent-stale-code hole — a clean repo behind origin is pushed, a dirty one is refused — but refusing is still a dead end for the case that motivates remote runs in the first place: iterating on code locally and wanting to see it run on hardware only the other machine has (an iOS simulator, a GPU, a different OS). Today that means commit-and-push on every edit, which turns a build-run loop into a history of `wip` commits, or gives up and runs locally. Neither is what the operator asked for: they want the run host to execute the code that is in front of them.

There is a second problem hiding in the obvious fix. Routing uncommitted work through origin to reach the run host publishes it: `git add -A` sweeps in untracked files, and a scratch file — a debug dump, a data sample, a throwaway script with a token in it — would be pushed to GitHub. Refs under `refs/mship/` are outside the default fetch refspec, but `git ls-remote` enumerates them and anyone with read access can fetch them, which on a public repo means anyone. Deleting the ref afterwards does not retract it, because the objects remain reachable by sha. The operator's own machine is the destination; there is no reason for a third party to be in the path at all.

## User story

As an operator iterating on code with a simulator on another machine, I want `mship run --remote` to execute exactly what is in my working tree — including uncommitted edits — without polluting my branch with throwaway commits, without pushing on every iteration, and without my uncommitted work leaving the two machines involved.

## Approach

Synthesize a commit from the working tree, then push it **directly to the run host** over the authenticated channel that already reaches it. Origin is not in the path.

For each repo the task affects: build a tree from the current working state using a TEMPORARY index. Seed it from HEAD first (`GIT_INDEX_FILE` pointed at a scratch file, then `git read-tree HEAD`), and only then `git add -A` and `git write-tree`. The seeding is not a detail: against an EMPTY index `git add -A` silently skips any path that is both tracked and gitignored, because git will not add ignored paths that are not already in the index — verified against real git, where the tracked file simply vanished from the resulting tree. Without the seed the run host would execute a tree missing a file the operator can plainly see. Then `git commit-tree` that tree with HEAD as its parent: a real commit object whose content is byte-identical to the working tree, created without staging anything, without moving HEAD, and without appearing in any branch's history.

That commit is pushed straight to the run host. `mship serve` gains a git smart-HTTP receive endpoint, and the client pushes to it carrying the run-host bearer. The bearer is supplied through `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n` in the environment — **not** via `git -c http.extraHeader=...`, which would place the token in the process's command line and therefore in world-readable `/proc/<pid>/cmdline`, contradicting this spec's own requirement that the token never be exposed. The count must APPEND at the next free index rather than claiming 0: the test suite already sets `GIT_CONFIG_COUNT=2` to disable commit signing, and overwriting it would silently re-enable signing across every test. The run host already has the repo cloned, because it already materializes worktrees.

Using git's own transport rather than a hand-rolled one is the point. `git push` performs the have/want negotiation itself, so only the objects the run host is missing cross the wire, with no need to compute what it already has. Pushing to a ref under `refs/mship/` rather than a branch means `receive.denyCurrentBranch` never applies. And the failure diagnostics are git's own rather than something weaker invented on top.

The run-host side of `materialize_worktree` gets simpler, not more complex: after the push the ref is already present in the local repository, so materialization is a hard reset to a local ref with no fetch at all. What is new is being told which ref to land on.

When the working tree is clean there is nothing extra to send, so the existing path stands: the branch is pushed to origin exactly as the preflight already does, and no scratch ref is created. The rule that falls out is a good one — **real history goes to origin; throwaway state goes host to host and never touches origin.**

The endpoint must be narrow. It accepts pushes only for repos the workspace knows about, and only onto refs matching `refs/mship/run/*`; anything else is refused. It is a purpose-built receive path for this feature, not a general git host.

Exact source with stale dependencies is its own trap — change a manifest, run remotely, and the failure is a module-not-found with no visible relationship to the edit, which is the same confusing-staleness class the preflight was added to eliminate. So the run host also **derives** what git cannot carry: `task setup` runs there, rebuilding dependencies from the manifests the push just delivered rather than copying `node_modules` over the wire.

Running setup on every invocation would defeat the fast loop this spec exists to enable, so it is keyed. Setup runs when a worktree is first materialized on a host, and again whenever the repo's declared `setup_inputs` — its manifests and lockfiles, e.g. `package.json`, `uv.lock`, `build.gradle` — differ from what that host last set up at. A source-only edit, the common case, pays nothing. A dependency change pays once. It is a cache key of exactly the shape any build cache uses. A repo declaring no `setup_inputs` gets setup on first materialization only, because there is nothing to invalidate against, and the docs say that declaring them is what buys re-run-on-change.

What remains genuinely uncarried is what setup cannot derive: `.env` and other secrets, platform state, and `symlink_dirs`/`bind_files`, which are still not replicated. Untracked files **are** carried, because they are part of what the operator sees and they now travel only between the operator's own two machines. So the honest statement is that the source is exact, the dependency environment is derived from it, and the run host is still not a clone of the operator's machine — and the docs say so where an operator will read it.

## Why push to the run host rather than to origin

The obvious implementation pushes the synthesized commit to a scratch ref on **origin** and has the run host fetch it. It was the starting design here, and it is wrong for one reason that outweighs its convenience: it publishes uncommitted work, including untracked scratch files, to a third party. `refs/mship/` is outside the default fetch refspec but not private — `git ls-remote` enumerates it and anyone with read access can fetch it, which on a public repo is everyone — and deleting the ref does not retract the objects. The destination is the operator's own machine; origin has no reason to be in the path.

**A git bundle over the exec channel** removes origin too, and was the first alternative considered. It fails on negotiation: to keep a bundle small you must bundle only what the host lacks, which means knowing what it has — re-implementing, by hand and badly, the have/want exchange `git push` performs for free. It also turns `POST /exec` into a binary upload path, making its body-size and timeout limits into repo-size limits, and yields worse diagnostics than git's own.

**Encrypted scratch refs on origin** were considered and rejected as strictly more work for a weaker position. The run host cannot fetch and hard-reset to something git cannot read, so an encrypted payload must be fetched, decrypted, unpacked and only then reset — which is the bundle path plus key management, still routed through a third party, still leaking ref names and push timing as metadata, and still leaving ciphertext that outlives the work in an object store that retains it.

**Auto-committing to the branch** puts `wip` commits in history the operator must squash and mutates their branch to run a test. **A patch over the wire** still requires HEAD to exist remotely, so it still requires pushing the branch, and patch application is a second thing that can fail.

**rsync of the working tree** is the only option that carries gitignored material outright, and is the honest answer to 'an exact copy of my machine'. Running setup on the run host reaches most of that destination by deriving those files from tracked manifests instead of shipping them. rsync remains the answer only for what setup cannot derive — secrets and platform state — and stays deliberately out of scope, named in the docs so the boundary is visible.

## Sequencing

**Prerequisite: PR #419 must merge first.** `remote_preflight.py` exists only on that branch, not on main, so ac8's "the branch is pushed to origin exactly as the preflight already does" describes code that is not yet merged. More than a dependency: #419's documentation and four of its tests assert the OPPOSITE of this spec — that tracked changes are refused and that untracked files will not exist on the run host. Building this means rewriting that module, its tests, and its docs section, and the plan must say so rather than discovering it.

The preflight ships first as a bug fix, making today's behaviour honest. This spec then converts its refusal into a transfer: the dirty-tree refusal becomes scratch-ref synthesis, while its clean-tree push to origin remains the fast path.

Within this spec three pieces land in order: the scoped receive endpoint on `mship serve` first, since it is the new security surface and everything depends on it; then commit synthesis and push, the load-bearing behaviour change; then setup keying, which builds on the same `materialize_worktree` seam and is only meaningful once the run host receives exact source.

Out of scope but worth recording: `mship capture --remote` has its own inline remote path with no preflight. This spec addresses `mship run --remote` only.
