---
id: first-class-implementation-plans-plan-mos-235
title: First-class implementation plans + plan-gate for feature work items (MOS-235)
status: approved
created_at: '2026-07-12T02:52:27.147034Z'
updated_at: '2026-07-12T03:13:43.322873Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: "A `kind == feature` WorkItem's task cannot transition `phase plan \u2192\
    \ dev` unless a valid plan resolves for it (explicit `WorkItem.plan_path` OR `discover_plan_path`\
    \ convention); the error names the expected plan path and `mship item link-plan`."
  verdict: approved
- id: ac2
  text: The same plan requirement is enforced at `mship finish` for feature work items.
  verdict: unreviewed
- id: ac3
  text: '`spawn` does NOT require a plan (a feature can be spawned before its plan
    is written).'
  verdict: unreviewed
- id: ac4
  text: bug/chore/question work items are never plan-gated.
  verdict: unreviewed
- id: ac5
  text: "A plan file that exists but has no `<!-- mship:task -->` anchor is treated\
    \ as INVALID (gate fails) \u2014 an empty placeholder doesn't satisfy the gate."
  verdict: unreviewed
- id: ac6
  text: A plan written at the writing-plans convention path (`<docs_dir>/plans/<date>-<slug>.md`)
    satisfies the gate with no extra link step.
  verdict: unreviewed
- id: ac7
  text: '`mship item link-plan <item> <path>` links a plan doc to a WorkItem (persisted
    as `WorkItem.plan_path`); an explicitly linked plan satisfies the gate even off-convention.'
  verdict: unreviewed
- id: ac8
  text: '`mship phase dev --bypass-plan-gate` and `mship finish --hotfix` bypass the
    plan gate and record the bypass to `.mothership/bypass-log.jsonl`.'
  verdict: unreviewed
- id: ac9
  text: The `mship spec dispatch` handoff instructs the agent to write the implementation
    plan (writing-plans) during the plan phase before `phase dev`.
  verdict: unreviewed
- id: ac10
  text: When a task has a linked/discovered plan, `mship dispatch --task <slug>` with
    NO `--plan` flag resolves that plan automatically and emits the implementer prompt
    from it (per `--plan-task`, or a sensible default such as the first unbuilt task
    / a plan overview).
  verdict: unreviewed
- id: ac11
  text: Once a plan is linked, the `mship spec dispatch` handoff references the plan's
    `<!-- mship:task -->` blocks as the build instructions (execute in order) rather
    than the spec's acceptance criteria; with no plan yet it stays the spec-based
    kickoff (spawn + write-the-plan).
  verdict: unreviewed
open_questions: []
non_goals:
- A heavyweight first-class Plan object / PlanStore with its own status lifecycle
  (draft/approved/dispatched) like specs. The operator does not review plan contents,
  so an approval lifecycle is unnecessary; a linked/discovered plan DOC gated on existence+validity
  is enough.
- A pause-for-plan-approval checkpoint. The operator explicitly does not need to review
  the plan's contents; enforcing existence is the goal. (Could be a future opt-in
  flag/config, out of scope here.)
- "Gating bug/chore/question work items \u2014 only `kind == feature` is gated (mirrors\
  \ the spec gate)."
- Requiring a plan at `spawn` time (the plan is written during the plan phase, after
  spawn).
- Changing the spec gate, the writing-plans skill's output format, or the `<!-- mship:task
  -->` anchor syntax.
- "Auto-generating the plan content itself \u2014 mship enforces that a plan exists;\
  \ authoring stays with the agent/skill."
risks:
- "Chicken-and-egg if the gate fired at spawn \u2014 avoided by gating only phase-dev\
  \ + finish, never spawn."
- 'Convention drift: `discover_plan_path` matches `<slug>.md` or `<date>-<slug>.md`
  only; a plan at a non-matching path wouldn''t be found. Mitigated by the explicit
  `WorkItem.plan_path` link as an override, and by the gate error naming both the
  expected convention path and the link command.'
- "A trivially-empty plan file could satisfy a naive existence check \u2014 mitigated\
  \ by requiring at least one `<!-- mship:task -->` anchor for validity."
- "Existing in-flight feature tasks created before this lands would suddenly fail\
  \ `phase dev`/`finish` \u2014 mitigated by the `--bypass-plan-gate`/`--hotfix` escape\
  \ (same as spec-gate migrations) and by the gate being satisfied by the conventional\
  \ plan path many already have."
task_slug: null
work_item_id: null
---
## Problem

Specs are first-class in mship (`mship spec`, and `workitem_gate.check_task_gate` blocks a feature WorkItem from `phase dev`/`finish` without an approved linked spec). Implementation plans are NOT: the plan doc (`docs/plans/*.md`, the bite-sized-TDD breakdown from the writing-plans skill) is only consumed ad-hoc via `mship dispatch --plan <file> --plan-task N` — nothing links a plan to a task/WorkItem and nothing requires one to exist. So `mship spec dispatch` and the Ground Control / autonomous paths can take an approved spec straight to code with no implementation plan, skipping the plan step the operator wants enforced for features. The `plan` phase exists and `mship phase dev` only soft-warns; there is no hard requirement.

## User story

As an operator who wants every feature built from a written implementation plan, I want mship to treat a plan as a first-class, linked artifact and refuse to start development on a feature work item until a real plan exists, so that no feature — interactive, GC-dispatched, or autonomous — is coded without a plan driving it.

## Approach

Mirror the existing spec gate with a lightweight plan gate; do NOT add a heavyweight Plan object or approval lifecycle (the operator does not need to review plan CONTENTS — enforcement is that a real plan EXISTS and drives the build).

(1) PLAN RESOLUTION — a feature's plan is resolved for its task by either (a) an explicit `WorkItem.plan_path` (a workspace-relative path to the plan doc, mirroring `spec_id`), or (b) the existing `discover_plan_path(workspace_root, task_slug, docs_dir)` convention (`<docs_dir>/plans/<date>-<slug>.md` or `<slug>.md`). A plan is 'valid' if the resolved file exists and contains at least one `<!-- mship:task ... -->` anchor (proves it's a real plan, not an empty/placeholder file). This makes the plan writing-plans already produces at the conventional path clear the gate with zero extra steps.

(2) PLAN GATE — add a plan clause alongside the feature spec clause so a `kind == feature` WorkItem needs a valid plan. It fires at `phase plan→dev` (you can't start developing without a plan) and at `finish` (belt-and-suspenders), but NOT at spawn (the plan is written during the plan phase, after spawn). Bug/chore/question skip it entirely. Reuse the existing bypass plumbing: `--bypass-plan-gate` on `mship phase` and `--hotfix` on `mship finish`, logged to `.mothership/bypass-log.jsonl` via `log_hotfix`.

(3) LINK COMMAND — `mship item link-plan <item> <path>` mirroring `mship item link-spec`, plus `WorkItemStore.link_plan` mirroring `link_spec`, for the explicit-path case (and so the phone/GC can show a plan is attached).

(4) CLOSES THE AUTONOMOUS HOLE — because the gate is at `phase dev`, a GC-dispatched or autonomous agent literally cannot enter dev without a valid plan, so `spec dispatch` → build must produce one first (the dispatch handoff should remind the agent to run writing-plans in the plan phase before `phase dev`).

(5) PLAN-DRIVEN BUILD DISPATCH — the build handoff for a task should be minted from the PLAN, not re-derived from the spec. The spec is the what/why (kickoff); the plan is the how (the build's source of truth). So: (a) `mship dispatch --task <slug>` with NO `--plan` flag auto-resolves the task's linked/discovered plan and emits the per-task implementer prompt from it (the existing `--plan --plan-task` machinery, but the plan is found automatically); and (b) once a plan is linked, `mship spec dispatch`'s handoff points the build agent at the plan's `<!-- mship:task -->` blocks (execute them in order) rather than at the spec's acceptance criteria. `spec dispatch` stays spec-based only for the pre-plan kickoff (spawn + 'now write the plan'); the moment a plan exists, dispatch is plan-driven.

## Design decisions (all baked in — approve or tweak any)

D1 Plan representation: lightweight linked/discovered DOC, no approval lifecycle (not a full Plan object). D2 Gate fires at phase plan->dev + finish, NOT spawn. D3 feature work items only. D4 resolved via explicit WorkItem.plan_path OR the discover_plan_path convention; valid = exists + >=1 mship:task anchor. D5 optional pause-for-approval is out of scope (default: existence is enough).

## Architecture / seams

Mirror the spec gate throughout. `src/mship/core/workitem.py`: add `plan_path: str | None = None` to WorkItem (beside `spec_id`). `src/mship/core/workitem_store.py`: add `link_plan(item_id, plan_path, now)` mirroring `link_spec`. `src/mship/core/workitem_gate.py`: add `_feature_has_plan(wi, task, workspace_root, docs_dir)` and a clause in the feature branch of `check_task_gate` (or a sibling `check_plan_gate` called at the same feature sites); reuse `discover_plan_path` (move it from `export.py` to a shared location, e.g. `core/plan.py`, so both export and the gate use it) + an anchor-presence check (reuse the `_TASK_OPEN_RE` from `core/dispatch.py`). `src/mship/core/phase.py`: in the `plan→dev` block, run the plan gate beside the spec gate; add `--bypass-plan-gate` to `cli/phase.py` (or fold into the existing `--bypass-spec-gate`). `src/mship/cli/worktree.py` finish: the plan gate rides along with `check_task_gate` + `--hotfix`. `src/mship/cli/workitem.py`: add `mship item link-plan`. `src/mship/core/spec_dispatch.py`: `build_dispatch_handoff` instructs writing the plan in the plan phase when no plan is linked, and points at the linked plan's `mship:task` blocks once one exists. `src/mship/cli/dispatch.py` + `src/mship/core/dispatch.py`: when `--plan` is omitted but `--task` has a linked/discovered plan, resolve it automatically (via the shared plan resolver) and mint the implementer prompt from it — so `mship dispatch --task <slug>` is plan-driven by default; keep explicit `--plan` as an override.

## Testing

Unit (mirror tests/test_workitem_gate.py + tests/core/test_phase.py): feature task blocked at phase-dev with no plan; allowed with a convention-path plan; allowed with an explicit link-plan; invalid (no task anchor) blocked; bug/chore never gated; spawn never gated; --bypass-plan-gate + --hotfix log a bypass. Store: link_plan persists plan_path. Shared resolver: discover_plan_path + anchor check unit tests. CLI: `mship item link-plan` happy path + bad path. Regression: spec gate + existing phase transitions unchanged; export's use of discover_plan_path still works after the move.
