---
id: mship-init-detect-monorepo
title: mship init --detect produces a working monorepo config (issue 366 finding 4)
status: implemented
created_at: '2026-07-17T12:24:23.183710Z'
updated_at: '2026-07-19T14:12:11.564571Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: 'Given a single-git monorepo where the workspace root has `.git` and subdirs
    `web/` and `infra/` contain only `package.json` (no nested `.git`), `mship init
    --detect` emits the root repo with `path: .` and no `git_root`, and emits `web`
    and `infra` as repos each with `git_root: <root-repo-name>` and a `path` relative
    to the root (`web`, `infra`) -- NOT as standalone top-level repos.'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green (2822 passed)
  - kind: commit
    ref: 074c830
    note: null
  comment: null
- id: ac2
  text: Every emitted repo `path` in the generated `mothership.yaml` is a relative
    path (`.`, `web`, `infra`); no emitted `path` is absolute (contains no leading
    `/` and no `/home/<user>/`), so the config is portable across machines and teammates.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green (2822 passed)
  - kind: commit
    ref: 074c830
    note: null
  comment: null
- id: ac3
  text: A detected subdirectory that has its OWN `.git` (an independent nested repo
    or a git submodule with a `.git` gitlink) is still emitted standalone with a relative
    `path` and NO `git_root`, preserving today's behavior for genuinely independent
    repos.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green (2822 passed)
  - kind: commit
    ref: d8badf7
    note: null
  comment: null
- id: ac4
  text: '`mship doctor` run against a freshly `init --detect`-ed single-git monorepo,
    with zero manual edits, reports NO `not a git repository` failure for the subdir
    repos (the git check resolves through `git_root` to the root per mothership/src/mship/core/doctor.py:152-157).'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green (2822 passed)
  - kind: commit
    ref: 77f6985
    note: null
  comment: null
- id: ac5
  text: '`mship audit` run against the same freshly detected workspace, with zero
    manual edits, reports NO `not_a_git_repo` error (subdir repos group under the
    root''s git via `_git_root_key`, mothership/src/mship/core/repo_state.py:330-347).'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green (2822 passed)
  - kind: commit
    ref: 9c7e21a
    note: null
  comment: null
- id: ac6
  text: '`mship spawn` against a repo in the freshly detected monorepo is NOT blocked
    by a `not_a_git_repo` audit error, with zero manual edits to `mothership.yaml`
    (the finding-#4 gate is removed).'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green (2822 passed)
  - kind: commit
    ref: 9c7e21a
    note: null
  comment: null
- id: ac7
  text: 'The `mothership.yaml` emitted by `init --detect` on the monorepo loads via
    `ConfigLoader.load(..., require_paths=True)` without raising: each `git_root`
    child resolves to `(parent.path / child.path)` and finds its scaffolded `Taskfile.yml`.'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green (2822 passed)
  - kind: commit
    ref: 863bb71
    note: null
  comment: null
- id: ac8
  text: When the workspace root itself is NOT a git repo (no `.git` at cwd) and a
    detected subdir also lacks `.git`, detection falls back to today's standalone
    emission and does not emit a `git_root` referencing the non-git root.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green (2822 passed)
  - kind: commit
    ref: dff4705
    note: null
  comment: null
open_questions: []
non_goals:
- 'Not the correctness/fail-loud validation fixes (findings #1-3: Taskfile.yaml shadowing/exit-1
  stubs, absolute-path git_root children resolving to the main checkout, and the undocumented
  git_root depends_on-edge requirement + silent fallback) -- those are a separate
  spec. This spec only changes what `init --detect` EMITS.'
- 'Not the config-change/bootstrap workflow (finding #5: there is no supported way
  to edit `mothership.yaml` itself once audit-gated) -- separate spec. This spec reduces
  how often that repair is needed but does not add a config-change path.'
risks:
- 'Git submodules and independent nested repos: the inference must NOT absorb them
  into the root''s git_root. Precise rule -- a detected subdir is emitted standalone
  (no git_root) whenever its markers include `.git`. `_find_markers` uses `(path/''.git'').exists()`,
  which is true for both a `.git` directory and a submodule''s `.git` gitlink FILE,
  so genuine submodules are classified as git owners and stay standalone; only a subdir
  with NO `.git` of its own is attached to an ancestor git owner. This means the change
  is behavior-preserving for every subdir that already has a `.git`.'
- 'Residual misclassification: because `.git` presence is the sole discriminator,
  a nested working tree that lacks a `.git` entry at its own root (e.g. an un-initialized/bare
  submodule, a `git worktree`-style linked checkout without a `.git` file, or a sparse/partial
  checkout) would be misclassified as a `git_root` child of the root. Document that
  `.git` presence is the signal and that a marker-bearing subdir without `.git` is
  assumed to belong to the nearest ancestor git owner; the operator can override in
  `mothership.yaml`.'
- 'Root-is-not-a-git-repo case: if cwd has no `.git`, there is no ancestor git owner
  to attach a non-git subdir to. The rule must fall back to today''s standalone emission
  rather than emit a `git_root` pointing at a non-git root (which would be a different,
  still-broken config).'
- 'Path relativization must be anchored correctly: a standalone repo''s `path` is
  relative to the workspace root, but a `git_root` child''s `path` is relative to
  its PARENT''s path (per the `(parent.path / repo.path)` resolution contract). Emitting
  a child path relative to the workspace root instead of the parent would resolve
  to the wrong directory. For single-level detection where the parent IS the workspace
  root these coincide, but the relativization logic must anchor on the parent for
  `git_root` children to stay correct if detection ever nests deeper.'
- 'The `.yaml`-vs-`.yml` Taskfile scaffolding footgun (finding #1) is untouched here;
  scaffolded `Taskfile.yml` files landing in each git_root child are what let `ConfigLoader.load(require_paths=True)`
  and `doctor` find a Taskfile per repo, so this spec depends on that scaffolding
  continuing to run for child repos (mothership/src/mship/cli/init.py:131-136).'
task_slug: mship-init-detect-monorepo
work_item_id: wi-20260718200636-57a381da
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

The advertised onboarding path (`mship init --detect` -> `mship doctor`) cannot produce a working config for the common single-git monorepo (one root `.git`, per-package `package.json`/`pyproject.toml` in subdirs, no nested `.git`). `detect_repos` (mothership/src/mship/core/init.py:42-62) promotes every immediate subdirectory that contains ANY marker in `REPO_MARKERS` (mothership/src/mship/core/init.py:10-19: `.git`, `Taskfile.yml`, `package.json`, `go.mod`, `pyproject.toml`, `Cargo.toml`, `build.gradle`, `pom.xml`) to a top-level repo, and `write_config` (mothership/src/mship/core/init.py:118-144, line 129 emits `str(repo.path)`) writes each with an ABSOLUTE `path`, no `git_root`, and no check for a nested `.git`. So subdirectories that are not independent git repos are declared as standalone repos. Immediately after a clean `init --detect`: `doctor` reports `not a git repository` per subdir (mothership/src/mship/core/doctor.py:152-157) and `audit` reports `not_a_git_repo` errors (mothership/src/mship/core/repo_state.py:330-347) that then BLOCK `spawn`/`finish`. The maddening part: mship ALREADY supports exactly this layout via `git_root` (RepoConfig.git_root at mothership/src/mship/core/config.py:150; child resolution at mothership/src/mship/core/config.py:477-490 and mothership/src/mship/core/repo_state.py:97-115) -- detection just never emits it, even though it already has the `.git`-presence signal (recorded in `DetectedRepo.markers`, init.py:33-36/64-69) needed to infer nesting. The fix already exists in the schema; detection simply doesn't use it.

## User story

As someone adopting mship into a single-git monorepo, I want `init --detect` to produce a working config so that onboarding doesn't require hand-editing before anything works.

## Approach

Make `init --detect` emit the `git_root` shape mship already understands, using the `.git`-presence signal detection already collects, and emit relative paths throughout for portability. Concretely: (1) Detection already scans exactly two levels -- the workspace root (cwd) and its immediate subdirectories (`detect_repos`, mothership/src/mship/core/init.py:42-62; no recursion) -- and `_find_markers` (mothership/src/mship/core/init.py:64-69) already records whether `.git` is present because `.git` is in `REPO_MARKERS`. Treat a detected directory as a 'git owner' iff its markers include `.git` (`(dir/.git).exists()`, which is true for both a real `.git` directory and a git submodule's gitlink file). (2) In the non-interactive detect wiring (mothership/src/mship/cli/init.py:107-119, which today unconditionally sets an absolute `path`, `type: service`, and no `git_root`) and the interactive path, apply this inference per detected entry: the workspace-root repo (cwd), if a git owner, is emitted standalone with `path: .`; a detected subdir that is itself a git owner (has its own `.git`) stays standalone with a path relative to the workspace root and NO `git_root` (preserving today's behavior for independent nested repos and git submodules); a detected subdir that is NOT a git owner while the workspace-root repo IS a git owner is emitted as a child with `git_root: <root-repo-name>` and a `path` that is the subdir name RELATIVE TO THE PARENT'S PATH (the child-resolution contract at mothership/src/mship/core/config.py:481 and mothership/src/mship/core/repo_state.py:97-102 is `(parent.path / repo.path)`); if neither the subdir nor the root is a git owner, fall back to today's standalone emission (nothing to attach to). Never point `git_root` at a repo that itself has `git_root` -- the no-chaining rule at mothership/src/mship/core/config.py:403-418 -- which single-level detection satisfies naturally since the only possible parent is the root. (3) Emit RELATIVE paths generally: `generate_config`/`write_config` (mothership/src/mship/core/init.py:96-144) must serialize `path` relative to the workspace root (or, for `git_root` children, relative to the parent), never the machine-specific absolute `/home/<user>/...`, mirroring the relative-path discipline already enforced for `bind_files` at mothership/src/mship/core/config.py:206-218. Net effect for a single-git monorepo: `write_config` emits `repos: { <root>: {path: ., type: service}, web: {path: web, type: service, git_root: <root>}, infra: {path: infra, type: service, git_root: <root>} }`, which `ConfigLoader.load(require_paths=True)` accepts, `doctor` (mothership/src/mship/core/doctor.py:152-157) and `audit` (mothership/src/mship/core/repo_state.py:330-347 grouping via `_git_root_key`) both pass because the git check now resolves to the root, and the `not_a_git_repo` audit error that gated `spawn`/`finish` is gone -- with zero manual editing. Documented default (resolving the depends_on ambiguity without an open question): detection does NOT synthesize `depends_on` edges, because it cannot infer real build ordering; the emitted config relies solely on `git_root`'s worktree-sharing semantics. Whether passive worktree materialization for a `git_root` child then follows its parent correctly is a distinct concern (finding #3) and is explicitly out of scope here -- this spec's job is to stop emitting the broken shape and start emitting the shape mship already supports.

## Testing

Unit/integration tests over a temporary monorepo fixture built in a tmpdir, no network and no real git worktree materialization required:

1. Single-git monorepo (primary): create a tmpdir, `git init` at the root, write a root marker (e.g. `pyproject.toml`) plus `web/package.json` and `infra/package.json` (each subdir gets ONLY `package.json`, no nested `.git`). Run `detect_repos` + the detect wiring + `write_config`, then load and assert the emitted YAML: root repo has `path: .` and no `git_root`; `web` and `infra` each have `git_root: <root-name>` and a relative `path` (`web`/`infra`); assert NO value under any repo's `path` is absolute (no leading `/`). Then `ConfigLoader.load(path, require_paths=True)` must not raise, run the doctor runner and `audit_repos` over the loaded config, and assert there is no `not a git repository` check failure and no `not_a_git_repo` error -- i.e. the exact symptoms in finding #4 are gone with zero manual edits.

2. Nested-.git / submodule case: same fixture but give `web/` its own `.git` (a directory is sufficient; also cover a `.git` FILE to model a submodule gitlink). Assert `web` is emitted standalone with NO `git_root` (behavior-preserving), while `infra` (no `.git`) still gets `git_root: <root>`.

3. Root-not-a-git-repo fallback: build the same subdir layout but do NOT `git init` the root. Assert detection falls back to today's standalone emission and does not attach a `git_root` pointing at the non-git root.

4. Portability assertion: re-load the emitted `mothership.yaml` from a DIFFERENT working directory / after moving the fixture, confirming the relative paths resolve against the workspace root rather than a baked-in absolute machine path.

5. Regression guard: a config emitted by the new detect path must satisfy `validate_git_root_refs` (no dangling and no chained `git_root`, mothership/src/mship/core/config.py:403-418).
