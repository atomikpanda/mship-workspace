---
id: mship-onboarding-fail-loud
title: 'mship onboarding fail-loud: init false-green + git_root main-checkout (issue
  366 findings 1-3)'
status: implemented
created_at: '2026-07-17T12:24:20.386447Z'
updated_at: '2026-07-18T20:04:58.480809Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: Given a repo directory containing only `Taskfile.yaml` (no `Taskfile.yml`),
    `mship init` / `write_taskfile` does NOT create a shadowing `Taskfile.yml` stub
    and reports that an existing go-task file was found, offering a rename to `.yml`.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: full mothership pytest suite green (2768 passed)
  - kind: commit
    ref: e9a14c1
    note: null
  comment: null
- id: ac2
  text: '`write_taskfile` suppresses the stub when ANY member of the full go-task
    resolution set exists: `Taskfile.yml`, `Taskfile.yaml`, `taskfile.yml`, `taskfile.yaml`,
    `Taskfile.dist.yml`, `Taskfile.dist.yaml`, `taskfile.dist.yml`, `taskfile.dist.yaml`.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: full mothership pytest suite green (2768 passed)
  - kind: commit
    ref: d33783c
    note: null
  comment: null
- id: ac3
  text: 'Every command in the generated `TASKFILE_TEMPLATE` (`test`, `run`, `lint`,
    `setup`) exits non-zero (e.g. `exit 1`), so running `mship test` against an unedited
    stub records `status: fail` (or errors) and NEVER a false `pass`.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: full mothership pytest suite green (2768 passed)
  - kind: commit
    ref: e9a14c1
    note: null
  comment: null
- id: ac4
  text: '`ConfigLoader.load` accepts a repo whose go-task file is spelled `Taskfile.yaml`
    (and the other resolution-set spellings): it no longer raises ''has no Taskfile.yml''
    (config.py:471,487) when a valid go-task file exists under an accepted name.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: full mothership pytest suite green (2768 passed)
  - kind: commit
    ref: d33783c
    note: null
  comment: null
- id: ac5
  text: '`mship doctor` emits a warning/error for any repo directory where more than
    one go-task file resolves (e.g. both `Taskfile.yml` and `Taskfile.yaml` present),
    naming both files.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: full mothership pytest suite green (2768 passed)
  - kind: commit
    ref: 3d525d1
    note: null
  comment: null
- id: ac6
  text: A directory whose only repo marker is a mship-generated stub Taskfile is NOT
    promoted to a repo by `detect_repos`, so re-running `init --detect` after a prior
    init does not treat mship's own stub dirs as repos.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: full mothership pytest suite green (2768 passed)
  - kind: commit
    ref: c7a2fd9
    note: null
  comment: null
- id: ac7
  text: "Constructing a `RepoConfig` with `git_root` set and an ABSOLUTE `path` raises\
    \ a clear ValueError naming the repo and stating git_root child paths must be\
    \ relative \u2014 mirroring `validate_bind_files` (config.py:206-218) \u2014 and\
    \ it fires at model construction, independent of `ConfigLoader.load`'s `require_paths`\
    \ flag."
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: full mothership pytest suite green (2768 passed)
  - kind: commit
    ref: 9c312b2
    note: null
  comment: null
- id: ac8
  text: Constructing a `RepoConfig` with `git_root` set and a `path` containing `..`
    raises a clear ValueError.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: full mothership pytest suite green (2768 passed)
  - kind: commit
    ref: 9c312b2
    note: null
  comment: null
- id: ac9
  text: "A git_root child with a RELATIVE `path` still resolves correctly nested under\
    \ its parent (`(parent.path / relative_child).resolve()` stays inside the parent\
    \ worktree/checkout) \u2014 no regression for valid configs."
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: full mothership pytest suite green (2768 passed)
  - kind: commit
    ref: 9c312b2
    note: null
  comment: null
- id: ac10
  text: 'In `DependencyGraph`, a repo with `git_root: parent` and NO explicit `depends_on`
    yields an implicit ordering edge: `topo_sort` emits `parent` before the child
    and `direct_deps(child)` includes `parent` (deduplicated when the parent is also
    an explicit depends_on target).'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: full mothership pytest suite green (2768 passed)
  - kind: commit
    ref: 5ab819c
    note: null
  comment: null
- id: ac11
  text: "`mship spawn` scoped to ONLY a git_root child materializes its git_root parent\
    \ (actively or passively) so the child's effective worktree nests under the task\
    \ worktree \u2014 the resolved child path is under `.worktrees/<slug>/<parent>/...`,\
    \ NEVER the source checkout."
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: full mothership pytest suite green (2768 passed)
  - kind: commit
    ref: 5ab819c
    note: null
  comment: null
- id: ac12
  text: If a git_root parent is still absent from the spawn's materialized `worktrees`
    map, `WorktreeManager` RAISES a clear error naming the child and parent instead
    of falling back to `self._config.repos[git_root].path` (the main checkout) at
    worktree.py:557-559.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: full mothership pytest suite green (2768 passed)
  - kind: commit
    ref: 6c40aeb
    note: null
  comment: null
- id: ac13
  text: A config that would require a git_root parent to `depends_on` its own child
    (opposite ordering) is rejected at load as an explicit cycle via `validate_no_cycles`,
    never resolved with a silent wrong-direction order.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: full mothership pytest suite green (2768 passed)
  - kind: commit
    ref: e85c196
    note: null
  comment: null
- id: ac14
  text: 'No worktree/config code path silently substitutes the main checkout for a
    task worktree: each git_root resolution either produces a path under `.worktrees/<slug>/`
    or raises.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: full mothership pytest suite green (2768 passed)
  - kind: commit
    ref: 6c40aeb
    note: null
  comment: null
- id: ac15
  text: Schema/docs state that git_root children require relative paths and that a
    git_root parent is auto-ordered before its children (no hand-added `depends_on`
    required).
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: full mothership pytest suite green (2768 passed)
  - kind: commit
    ref: 91001ff
    note: null
  comment: null
open_questions: []
non_goals:
- "Not redesigning `init --detect` repo detection or teaching it to emit `git_root:`\
  \ + relative paths for nested packages \u2014 that is issue #366 finding #4 (Medium-High),\
  \ a separate spec."
- "Not adding a supported workspace-config-change / bootstrap workflow or `doctor\
  \ --fix` \u2014 that is finding #5 (Medium), a separate spec."
- 'Not resolving config-discovery ambiguity for committed `mothership.yaml` / hub-worktree
  markers (finding #6) or build-context leakage of `.worktrees`/`.mothership` (finding
  #7).'
- "Not changing whether TOP-LEVEL (non-git_root) repos may use absolute paths \u2014\
  \ `init --detect` still emits those and that is finding #4's concern; this spec\
  \ only constrains git_root children."
- Not adding new go-task features or auto-migrating `Taskfile.yaml` files to `.yml`
  without operator action (we offer a rename, we don't perform it silently).
risks:
- "Turning the worktree.py:557-559 fallback into a `raise` will surface latent misconfigs\
  \ in EXISTING workspaces where a git_root child's parent was silently landing in\
  \ the main checkout \u2014 those spawns now hard-error until the scope/config is\
  \ corrected. That is the intended fail-loud behavior (it was silent branch corruption),\
  \ but it is a behavior change and must be called out in release notes."
- "The implicit git_root ordering edge changes topo order; a config that declared\
  \ a `depends_on` in the opposite direction (parent depends on child) will now form\
  \ a cycle and be rejected at load. This is the 'old direction becomes unrepresentable'\
  \ case the issue predicts \u2014 mitigated by surfacing it as an explicit `validate_no_cycles`\
  \ error rather than silently, but it can block a load that previously succeeded."
- "Rejecting absolute/`..` git_root child paths at model-validation time could break\
  \ hand-written configs that used an absolute child path and only 'worked' because\
  \ the child was never spawned in isolation \u2014 any such config was already one\
  \ spawn away from wrong-branch corruption, so failing loud is the point, but it\
  \ is a load-time break."
- Making the generated stub commands `exit 1` means a repo that was 'passing' purely
  via the untouched `echo` stub will now fail `mship test`. Correct (it was a false
  green), but adopters relying on the old no-op may be surprised; document it.
- "Changing REPO_MARKERS / detection so a lone stub Taskfile no longer counts risks\
  \ a legitimate repo whose ONLY marker is a hand-written Taskfile no longer being\
  \ detected \u2014 mitigate by matching against the generated-stub content (not just\
  \ filename) rather than dropping Taskfile detection wholesale."
task_slug: mship-onboarding-fail-loud
work_item_id: wi-20260718025602-be0796e3
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
---
## Problem

Three High-severity correctness bugs from issue #366 let mship silently degrade instead of erroring, violating the codebase's own stated principle. (1) `mship init` only ever looks for `Taskfile.yml` (init.py:12,148) and never the `.yaml` spelling that go-task also accepts (and lists first in its resolution order). For a repo that already uses `Taskfile.yaml`, `write_taskfile` (init.py:146-151) sees no `Taskfile.yml`, so it writes a *shadowing* stub whose `test:` target is `echo "TODO - add test command"` (init.py:78) which exits 0 — go-task then prefers the stub `.yml`, so `task test` runs nothing in ~0ms and `mship test` records a false `status: pass`. (2) The config loader deliberately skips path resolution for `git_root` children (config.py:463-465) and every consumer joins the child path onto the parent (config.py:481 `(parent.path / repo.path)`, worktree.py:560, doctor.py:135). Because `pathlib`'s `/` discards its left operand when the right side is absolute, a git_root child with an ABSOLUTE `path` resolves to the SOURCE checkout instead of `.worktrees/<slug>/<parent>/<child>` — commits land on the wrong branch with zero warning, and `init --detect` itself emits absolute paths. (3) Passive worktree expansion follows only `depends_on` edges (worktree.py:455-467 via graph.direct_deps) and never a `git_root` parent; if a git_root parent isn't ALSO a depends_on target it is never materialized, and worktree.py:557-559 then silently falls back to `self._config.repos[git_root].path` — again the main checkout. This is an undocumented requirement that `validate_git_root_refs` (config.py:403-420) never checks. Net effect: one false-green test hole and two wrong-branch (main-checkout) silent-corruption paths — the exact failure the pre-commit/edit-guard exists to prevent, reached via routes the hook can't see.

## User story

As a mship adopter onboarding a monorepo (single git root with per-subdir services, some using `Taskfile.yaml`), I want `mship init`, config load, and worktree materialization to fail loudly on the misconfigurations that would otherwise fabricate a passing test run or land my commits in the source checkout, so that I can trust `mship test` results and know my work always lands in the task worktree instead of silently corrupting the main branch.

## Approach

Enforce the codebase's already-declared 'fail loud instead of silently falling through' principle (stated verbatim at config.py:499-501 'raises so misconfiguration fails loud instead of silently falling through' and worktree.py:513-517 '...would silently cut from the checkout's current HEAD... Fail loudly instead.') in the three places issue #366 shows it is violated. Every line below was re-verified against the current tree.

Finding #1 (init.py): (a) Introduce a single canonical go-task resolution set and use it everywhere: `Taskfile.yml`, `Taskfile.yaml`, `taskfile.yml`, `taskfile.yaml`, plus the `.dist` variants (`Taskfile.dist.yml`/`.yaml`, `taskfile.dist.yml`/`.yaml`). `write_taskfile` (init.py:146-151, today `taskfile = repo_path / "Taskfile.yml"; if taskfile.exists(): return`) must return early if ANY member of that set exists, and when a non-`.yml` spelling exists, report it and offer a rename instead of writing a shadowing stub. (b) Change the four `TASKFILE_TEMPLATE` commands (init.py:75-93) from `echo "TODO..."` (exit 0) to `exit 1`, so a missed detection can never fabricate a pass — an unedited stub makes `mship test` fail, not falsely pass. (c) `ConfigLoader.load` currently hardcodes `Taskfile.yml` at config.py:471 and config.py:487; point both at the same resolution set so a `.yaml`-spelled repo loads instead of erroring 'has no Taskfile.yml'. (d) doctor.py gains a check that flags a repo dir where >1 go-task file resolves. (e) The `Taskfile.yml` entry in REPO_MARKERS (init.py:12) self-triggers on mship's own generated stubs during a later `--detect`; make detection ignore a Taskfile whose content matches the generated stub (or drop the marker), so a dir whose only marker is a mship stub is not promoted to a repo.

Finding #2 (config.py): Add a RepoConfig `@model_validator(mode="after")` that mirrors `validate_bind_files` (config.py:206-218): if `git_root is not None` and `Path(self.path).is_absolute()`, raise a clear ValueError naming the repo and stating git_root child paths must be relative; likewise reject `..` in the path parts. Scoping to git_root children only leaves top-level absolute paths (what `init --detect` emits, finding #4's domain) untouched. Because it lives on RepoConfig it fires at model construction, independent of `ConfigLoader.load`'s `require_paths` flag, so `load(require_paths=False)` callers are protected too.

Finding #3 (worktree.py + graph.py): Primary fix — treat `git_root` as an implicit ordering edge. In `DependencyGraph.__init__` (graph.py:12-16), for every repo with `git_root` set add a parent->child edge (dedup against an explicit `depends_on`), so `topo_sort` emits the parent before the child and `direct_deps(child)` includes the parent. This makes the passive-expansion loop (worktree.py:455-467) pull a git_root parent into the materialized set automatically, with no hand-added `depends_on`. Defense-in-depth — turn the silent fallback at worktree.py:557-559 (`parent_wt = worktrees.get(git_root); if parent_wt is None: parent_wt = self._config.repos[git_root].path`) into a `raise` naming child + parent, so if a parent is still unmaterialized we error instead of nesting into the source checkout. Together these close both #2's and #3's wrong-branch path. The opposite-direction case the issue flags (a real `parent depends_on child`) now becomes a genuine cycle, which is already caught loudly by `validate_no_cycles` (config.py:379). Document in the schema/docs that git_root children need relative paths and that git_root parents are auto-ordered.

## Testing

Unit tests (tests/core/): (1) init — a temp repo containing only `Taskfile.yaml` asserts `write_taskfile` writes no `Taskfile.yml` and returns the existing-file signal; a parametrized test over the full resolution set (`taskfile.yml`, `Taskfile.dist.yaml`, etc.) asserts each suppresses the stub; assert the `TASKFILE_TEMPLATE` string contains `exit 1` and no `echo`, and that a rendered stub run returns non-zero. (2) detect — a temp dir whose ONLY marker is a mship-generated stub Taskfile asserts `detect_repos` does not include it; a dir with a hand-written non-stub Taskfile still detects. (3) config (test_config.py) — construct `RepoConfig(git_root='api', path=Path('/abs/child'))` and assert ValueError (mirror the existing `validate_bind_files` absolute-path test); same for a `..`-containing path; assert a relative git_root child still loads and resolves nested; assert `ConfigLoader.load` accepts a repo whose file is `Taskfile.yaml`; assert an opposite-direction git_root/depends_on config raises the cycle error. (4) graph (test via topo_sort) — a config with `git_root` and no depends_on asserts parent precedes child in `topo_sort` and appears in `direct_deps(child)`, deduped when also declared. Integration tests (tests/): a temp monorepo fixture with a single git root, a git_root child that has NO depends_on edge to its parent, and an absolute-path variant — assert `mship spawn` scoped to just the child materializes the parent and the child's effective path is under `.worktrees/<slug>/<parent>/`, and that the absolute-path variant fails at load rather than resolving into the source checkout. Add a regression test that the pre-fix silent fallback (worktree.py:557-559) now raises. Reuse tests/conftest.py fixtures and the existing test_monorepo_integration.py / test_init_integration.py harnesses.

## Verification anchors (current tree, re-verified 2026-07)

Finding #1: init.py:10-19 REPO_MARKERS (incl. `Taskfile.yml` at :12); init.py:64-69 `_find_markers`; init.py:71-94 TASKFILE_TEMPLATE (`echo` cmds at :78/:83/:88/:93); init.py:146-151 `write_taskfile` (`.yml`-only at :148); config.py:471 & :487 hardcoded `Taskfile.yml`. Finding #2: config.py:463-465 git_root path-resolution skip; config.py:481 `(parent.path / repo.path).resolve()`; consumer joins at worktree.py:560 and doctor.py:135; pattern to mirror at config.py:206-218 (`validate_bind_files`). Finding #3: worktree.py:455-467 passive expansion via `direct_deps`; graph.py:12-16 edge construction + graph.py:18-41 `topo_sort` (depends_on only); worktree.py:557-559 silent main-checkout fallback; validators at config.py:403-420 (`validate_git_root_refs`, no depends_on check) and config.py:379 (`validate_no_cycles`). Fail-loud self-declarations quoted: config.py:499-501 and worktree.py:513-517.
