---
id: mship-config-workflow-doctor
title: mship config-change workflow plus discovery observability plus artifact-leak
  safeguards (issue 366 findings 5-7)
status: implemented
created_at: '2026-07-17T12:24:47.948806Z'
updated_at: '2026-07-17T17:10:17.953907Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: A change whose modified tracked files are confined to `mothership.yaml` and/or
    a Taskfile (`Taskfile.yml`/`.yaml`, `taskfile.yml`/`.yaml`) in an in-scope repo
    does NOT block `mship finish` on the `dirty_worktree` audit error, without `--force-audit`.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: test_finish_config_only_gate.test_finish_not_blocked_by_config_only_dirty
      + repo_state predicate/filter tests
  comment: null
- id: ac2
  text: The moment any modified tracked file falls outside that config/Taskfile allowlist,
    the `dirty_worktree` error blocks `mship finish` again (config-only exemption
    fails closed).
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: test_finish_reblocks_when_source_file_also_dirty + is_config_only_paths
      fail-closed cases
  comment: null
- id: ac3
  text: A documented bootstrap/config-change workflow exists (README + working-with-mothership
    skill) describing how to edit and land `mothership.yaml`/Taskfile changes from
    the main checkout, and the doctor/config-change path loads config with `require_paths=False`
    so a not-yet-present or being-changed `Taskfile.yml` does not hard-fail `ConfigLoader.load`.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: test_doctor_loads_config_with_require_paths_false + README/SKILL config-change
      docs
  comment: null
- id: ac4
  text: '`mship status` reports both the resolved `mothership.yaml` absolute path
    and the resolution source (env / marker / walk-up), reusing the existing `resolution_source`
    convention already used for tasks (status.py:243).'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: test_status_reports_config_path_and_source (config_path + config_resolution_source)
  comment: null
- id: ac5
  text: '`mship doctor` reports the resolved config path and its resolution source,
    so running inside a hub or subrepo worktree makes it unambiguous which config
    is live.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: test_doctor_appends_config_resolution_check + test_doctor_json_includes_config_path_and_source
  comment: null
- id: ac6
  text: "When run from inside a hub repo worktree (`path: .`) that contains a tracked\
    \ copy of `mothership.yaml`, `discover` resolves to the WORKSPACE-root config\
    \ (via the marker), and the reported resolution source is `marker` \u2014 not\
    \ the worktree's own copy."
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: test_discover_with_source_hub_worktree_prefers_marker_over_own_yaml (marker
      beats worktree's own mothership.yaml)
  comment: null
- id: ac7
  text: "Every worktree spawn creates \u2014 including the hub repo's own worktree,\
    \ not only subrepo worktrees and the hub container \u2014 is covered by a `.mship-workspace`\
    \ marker pointing at the workspace root, and that marker is added to the repo's\
    \ tracked `.gitignore` so it does not appear in `git status`."
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: "OPTION 0 (pending your decision card): resolution goal met by the single\
      \ hub marker \u2014 test_every_worktree_resolves_to_workspace_root_via_hub_marker;\
      \ per-worktree-marker letter deferred (reverses #84 + dirties worktrees)"
  comment: null
- id: ac8
  text: '`mship doctor` emits a WARN when it detects a common asset-bundling config
    (CDK `Code.fromAsset`, Dockerfile/`.dockerignore`, package.json `files` for `npm
    pack`, `sam build` template, serverless.yml) at/under the workspace root that
    does not exclude `.worktrees`/`.mothership`; the warning explicitly states it
    is a best-effort heuristic that cannot detect every bundler.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: test_doctor_bundler_warns_* (docker/serverless/cdk, warn-only, best-effort
      heuristic)
  comment: null
- id: ac9
  text: The docs where the worktree layout is introduced (README + working-with-mothership
    skill) call out that `.worktrees`/`.mothership` live at the repo root, must be
    excluded from any bundler that ignores `.gitignore`, and note that spawn's `.gitignore`
    entry protects git but not such bundlers.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: test_docs_config_workflow bundler-caveat tests (README + SKILL)
  comment: null
- id: ac10
  text: New JSON fields added to `status`/`doctor` output are additive (no existing
    key renamed or removed), preserving deterministic-output consumers.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: test_status_json_keys_are_additive + test_doctor_json_keys_are_additive
  comment: null
open_questions: []
non_goals:
- "Not the correctness fixes #1-#3 (Taskfile.yaml shadowing / false-green stubs; absolute-path\
  \ git_root child resolving to the main checkout; the undocumented git_root depends_on\
  \ edge and silent main-checkout fallback) \u2014 those are tracked separately."
- "Not the `init --detect` monorepo-emission fix #4 (emitting `git_root` + relative\
  \ paths for nested non-.git subdirs) \u2014 separate spec."
- 'Not a full config-editing UI or interactive config wizard; the #5 fix is a supported
  CLI/docs path, not a GUI.'
- 'Not relocating `.worktrees`/`.mothership` outside the repo root in this spec (kept
  as a documented future workspace option under #7).'
- Not a general `doctor --fix` auto-repair engine; any config-change ergonomics here
  are limited to unblocking edits, not mutating config on the user's behalf.
risks:
- "Narrowing the audit gate for config-only drift must not let REAL drift through:\
  \ the config-only predicate has to fail closed \u2014 if ANY modified tracked path\
  \ is outside the {mothership.yaml, Taskfile.yml/.yaml, taskfile.yml/.yaml} allowlist,\
  \ the `dirty_worktree` error must still block. Mis-scoping (e.g. matching a path\
  \ substring) could silently un-gate a real dirty worktree \u2014 the exact silent\
  \ main-checkout landing the pre-commit hook exists to stop."
- Loading config with `require_paths=False` skips the Taskfile/existence validation
  (config.py:468-489); it must be confined to the bootstrap/config-change and doctor
  paths and never leak into spawn/finish/exec, or a genuinely broken config could
  load and run tasks against a missing Taskfile.
- 'The doctor bundling-exclusion check is heuristic: it greps known tools (CDK/Docker/npm
  pack/sam/serverless) and will MISS custom or unrecognized bundlers, and may FALSE-POSITIVE
  on a bundling config that already excludes the dirs by another mechanism. It must
  be a WARN (never an error/block) and its message must say it is a best-effort heuristic
  that cannot see every tool.'
- Writing the marker into worktrees as well as the container adds a second write path;
  both must agree on the target (workspace root) and both must land in the repo's
  tracked `.gitignore` (as the container marker's docstring describes) so neither
  pollutes `git status`.
- Reporting the resolved config path/source in `status`/`doctor` adds fields to deterministic
  JSON output; downstream consumers (GC, scripts) key off stable schemas, so the additions
  must be additive and not rename or drop existing keys.
task_slug: mship-config-workflow-doctor
work_item_id: wi-20260717155220-ea8fdde3
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
---
## Problem

Post-onboarding (after `mship init`), 0.5.0 has three workspace-config ergonomics gaps, all traced to current code. (#5) There is no supported way to change the workspace config itself: `spawn`/`finish` are audit-gated by the very errors a config fix would resolve; `ConfigLoader.load` hard-requires a per-repo `Taskfile.yml` (config.py:471-473 for top-level repos, config.py:487-489 for git_root children), so a Taskfile-involving fix can't even load until merged; and `mothership.yaml` lives at the workspace root while mship insists work happen in worktrees that don't take effect until merge. The only path through is editing the main checkout directly (correctly flagged `dirty_worktree`, an error, at repo_state.py:268-272 and enriched with an 'edit in the worktree' hint at repo_state.py:301-307) and forcing past the gate with `--force-audit` (cli/worktree.py:238 spawn, :924 finish). (#6) Config discovery is ambiguous once `mothership.yaml` is committed: `ConfigLoader.discover` (config.py:495) resolves via MSHIP_WORKSPACE env (config.py:502-511) -> `.mship-workspace` marker walk-up (config.py:513-517) -> plain `mothership.yaml` walk-up (config.py:519-530); the marker walk-up short-circuits before the plain walk-up, but nothing reports which config is live or how it was resolved. `status` reports `resolution_source` for TASKS (status.py:243) but not for the CONFIG; `doctor` reports neither the resolved config path nor its source. (#7) Repo-root artifacts leak into build/bundling: spawn creates `.worktrees/<slug>` at the workspace root (worktree.py:543-544, full checkouts including node_modules) and `.mothership/` state (worktree.py:734), and adds `.worktrees` to the root `.gitignore` (worktree.py:546-549). Tooling that bundles the repo root without honoring `.gitignore` (AWS CDK `lambda.Code.fromAsset`, Docker build context, `npm pack`, `sam build`, serverless) ships worktree checkouts into build output; the `.gitignore` entry helps git but also hides the directory from `git status` while those tools still bundle it.

## User story

As a mship user past first-onboarding (config already generated, possibly committed and shared with a team), I want to safely change my workspace config through a supported path, always know which `mothership.yaml` is actually live and how it was resolved, and never leak `.worktrees`/`.mothership` checkouts into my build/bundling output — so that correcting or evolving my config isn't a chicken-and-egg fight with the audit gate, a committed config doesn't silently re-root onto a worktree copy, and a production bundle can't accidentally ship a full worktree tree.

## Approach

Three coordinated changes, each grounded in current code; primary approach chosen and justified for #5 and #7.

#5 (PRIMARY: narrow the audit gate for config-only drift + document the bootstrap path). Today the gate (audit_gate.py:run_audit_gate) blocks on any error-severity issue and already supports a per-repo `scope_repos` filter (audit_gate.py:37, computed by compute_finish_audit_scope at audit_gate.py:58, wired into finish at cli/worktree.py:1155-1172) — precedent (#112) for narrowing the gate by scope. Extend that precedent from 'which repos' to 'which files': when the ONLY tracked-file drift in an in-scope repo is confined to `mothership.yaml` and/or Taskfiles (`Taskfile.yml`/`.yaml`, `taskfile.yml`/`.yaml`), the resulting `dirty_worktree` error (repo_state.py:268-272) must NOT block `finish`. Implement by having the porcelain scan that produces `dirty_worktree` (repo_state.py:249-272) also record the set of modified paths, and add a config-only predicate the gate consults instead of blocking. Justification for this over the alternatives (worktree-rule exemption / `doctor --fix`): it reuses the existing gate-scoping mechanism rather than carving a hole in the core 'work happens in worktrees' invariant, and it is the narrowest change that unblocks the documented happy path's own most-likely first repair. Pair it with a documented bootstrap/config-change workflow (README/skill): edit `mothership.yaml`/Taskfiles in the main checkout, run `mship doctor`, commit. To break the Taskfile chicken-and-egg, `ConfigLoader.load` already exposes `require_paths: bool = True` (config.py:454, guarding the Taskfile checks at :468/:482) — the bootstrap/config-change and doctor paths should load with `require_paths=False` so a not-yet-present Taskfile doesn't hard-fail loading before the fix is merged.

#6 (report the resolved config path + resolution source, and harden the marker). The resolution half is already substantially mitigated: `write_marker(hub, workspace_root)` (worktree.py:698, added in the hub-layout change 2026-04-28) drops `.mship-workspace` at the hub container `.worktrees/<slug>/`, and every repo worktree — including the `path: .` hub repo — lands at `hub/<repo_name>/` (worktree.py:585), so `read_marker_from_ancestor` (workspace_marker.py:37) walks up and hits the container marker BEFORE the worktree's own tracked `mothership.yaml`, so `discover` returns the workspace config, not the worktree copy. Two residual gaps remain. (a) Observability: reuse the existing `resolution_source` pattern (status.py:243, cli/_resolve.py:104, threaded through ~12 CLI commands as `resolved.source`) for CONFIG resolution — have `discover` report which of its three branches resolved the config (env / marker / walk-up) and surface both the resolved `mothership.yaml` absolute path AND that source in `mship status` and `mship doctor`, so 'which config is live' is answerable. (b) Robustness: the marker is written only to the hub CONTAINER, not into each worktree, contradicting the module docstring's claim that 'every worktree it creates' gets one (workspace_marker.py:1-8); write the marker into the hub repo's own worktree too so removal of the container marker can't let the walk-up fall through to the worktree's tracked `mothership.yaml`.

#7 (PRIMARY: a doctor heuristic bundling-exclusion check + a docs callout). Add a `doctor` check that greps for common asset-bundling config at/under the workspace root (CDK `lambda.Code.fromAsset` / `Code.fromAsset`, `Dockerfile`/`.dockerignore`, `npm pack` via package.json `files`, `sam build` templates, serverless.yml) and WARNs when `.worktrees`/`.mothership` are not excluded from a detected bundling context (e.g. absent from `.dockerignore`, or inside an asset root). Add a docs callout where the worktree layout is introduced (README + working-with-mothership skill) noting that `.worktrees`/`.mothership` sit at the repo root and must be excluded from any bundler that does not honor `.gitignore`, and that spawn's `.gitignore` entry (worktree.py:546-549) protects git but not those bundlers. Justification for doctor+docs over relocating `.worktrees` outside the repo root: relocation is a larger layout change touching hub creation (worktree.py:543), teardown (worktree.py:810-836), and marker/discovery, with its own portability trade-offs; keep it as a documented future workspace option rather than the primary fix.

## Testing

#5: unit-test the config-only drift predicate against `git status --porcelain` fixtures — (a) only `mothership.yaml` modified -> not blocking; (b) only `Taskfile.yaml` modified -> not blocking; (c) `mothership.yaml` + one source file modified -> blocking; (d) a path whose name merely contains 'Taskfile' but sits elsewhere -> blocking (no substring escape). Integration-test `mship finish` on a task whose only main-checkout drift is `mothership.yaml`, asserting it proceeds without `--force-audit`, and that adding a source-file edit re-blocks it. Assert `ConfigLoader.load(path, require_paths=False)` succeeds when a repo's `Taskfile.yml` is absent, and that spawn/finish/exec still load with `require_paths=True`.
#6: unit-test `discover` returns the workspace-root `mothership.yaml` and source=`marker` when invoked from a hub-repo worktree that itself contains a tracked `mothership.yaml`; assert `status`/`doctor` JSON include the resolved config path + source. Regression-test that removing the hub-CONTAINER marker still resolves correctly because the hub-repo WORKTREE now also carries a marker. Verify the marker is present in the worktree's tracked `.gitignore` (no `git status` pollution).
#7: unit-test the doctor bundling-exclusion check against fixtures — a `.dockerignore` missing `.worktrees` -> WARN; a serverless.yml/SAM template/CDK `fromAsset` root not excluding the dirs -> WARN; the same configs WITH exclusions -> no warning; assert the check never raises severity to error/block and that its message flags itself as heuristic. Snapshot-test the docs callout presence. Manually exercise `mship doctor` in this workspace (which has real `.worktrees`/`.mothership` at root) to confirm the check runs and the new config-path/source fields render.

## Scope note

Findings #5, #6, and #7 are grouped here per the operator's decomposition of GitHub issue #366 (the 0.5.0 adoption feedback): they are the post-onboarding workspace-config/ergonomics cluster, distinct from the correctness cluster (#1-#3) and the `init --detect` cluster (#4), which are specced separately. The implementation plan may sub-sequence these three — a reasonable order is #6 observability (low risk, reuses `resolution_source`), then #7 doctor check + docs, then #5 gate-narrowing (highest care, must fail closed) — and may land them as separate PRs under one plan.
