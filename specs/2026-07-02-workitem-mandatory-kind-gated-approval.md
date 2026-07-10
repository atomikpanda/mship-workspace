---
id: workitem-mandatory-kind-gated-approval
title: WorkItem-mandatory + kind-gated approval enforcement
status: implemented
created_at: '2026-07-02T19:59:58.829976Z'
updated_at: '2026-07-02T23:50:28.175910Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: "`mship spawn` cannot leave work_item_id null \u2014 a task is always attached\
    \ to a WorkItem (attached or auto-created), for every kind."
  verdict: approved
- id: ac2
  text: A feature-kind WorkItem cannot enter the dev phase (`mship phase dev`) or
    be dispatched unless its linked spec is in the approved state.
  verdict: approved
- id: ac3
  text: A bug/chore/question-kind WorkItem can be dispatched with only a WorkItem
    (no spec required).
  verdict: approved
- id: ac4
  text: "`mship finish` refuses to open a PR when the gate is unsatisfied (no WorkItem,\
    \ or a feature without an approved spec) and reports the reason \u2014 mirroring\
    \ the existing test-evidence gate."
  verdict: approved
- id: ac5
  text: Hooks enforce the gate at the agent boundary (SessionStart injection + a PreToolUse
    block on source edits) so an agent cannot sidestep it via prose.
  verdict: approved
- id: ac6
  text: Existing tasks with work_item_id=null are migrated/backfilled so no active
    work is left untracked.
  verdict: approved
- id: ac7
  text: Every gate reports a clear, actionable message and, where allowed, an explicit
    + logged override path.
  verdict: approved
open_questions:
- id: q1
  text: Should `mship spawn` AUTO-CREATE a WorkItem when none is given, or REQUIRE
    an explicit --work-item / prior `mship item new`?
  answer: prior mship item new
- id: q2
  text: 'Exact kind->gate mapping: is ''question'' spec-gated like feature, or WorkItem-only
    like chore? Are chores ever spec-required?'
  answer: 'no'
- id: q3
  text: "Per gate \u2014 hard block, or warn-with-explicit-override? Which gates get\
    \ an escape hatch (e.g. hotfix)?"
  answer: hotfix
- id: q4
  text: 'Migration of existing work_item_id=null tasks: backfill one WorkItem per
    task, group by spec, or grandfather legacy tasks?'
  answer: 'yes '
- id: q5
  text: Should the PreToolUse source-edit hook be default-on or opt-in per workspace?
  answer: default on
non_goals:
- "Changing what a spec or WorkItem IS (both exist from MOS-196) \u2014 this is enforcement\
  \ + gating only."
- "Building the GC-side capture kind-picker / dispatch-now UI (that is MOS-210) \u2014\
  \ this is the mship-side gate that flow relies on."
- "Removing every escape hatch \u2014 an override path may exist for emergencies,\
  \ but it must be explicit and logged, not silent."
risks:
- "Too-strict gates could block legitimate quick work (tiny chores, hotfixes) \u2014\
  \ mitigated by the kind dial and a possible explicit override."
- "Auto-creating WorkItems could spam low-value items \u2014 needs a sensible default\
  \ (one WorkItem per task, or reuse an existing one)."
- Migrating existing work_item_id=null tasks must not orphan in-flight work.
- "PreToolUse hooks add friction and can misfire; they must be reliable \u2014 the\
  \ existing enforcement-gate work learned this the hard way."
task_slug: workitem-mandatory-kind-gated-approval
work_item_id: wi-20260702235053-cef857ee
---
## Problem

Nothing in mship tooling enforces the intended workflow. `mship spawn` creates tasks with work_item_id=null, and the spec-first + plan/approval gates live only in skill prose — so an agent on momentum can build, commit, and open a PR for feature work with NO WorkItem and NO approved spec. That work is then invisible in Ground Control's farm/cockpit (which lists WorkItems by phase), and the operator never got to review or approve it. This happened across the whole phase-cockpit program (MOS-196..201): every slice was tracked as Linear + docs/plans + bare spawned tasks, with work_item_id null throughout — the operator literally couldn't see it in GC.

## User story

As the operator, I want mship to refuse to let an agent build or ship work that isn't attached to a WorkItem (and, for feature-kind work, an approved spec), so that every piece of work is tracked, visible in Ground Control, and approved by me where its kind demands it — enforcement in the tooling, not agent goodwill.

## Approach

Move the gates from skill prose into hard mship tooling gates, kind-aware. (1) WorkItem is mandatory and universal: `mship spawn` and the first source edit require a WorkItem — work_item_id may never be null (attach an existing one or auto-create). (2) The item's `kind` is the dial on approval strictness: kind=feature requires an APPROVED linked spec before entering the dev phase / dispatch; kind=bug/chore/question needs only the WorkItem and may dispatch directly (skip Shaping). (3) Gate points mirror the existing untasked-work enforcement: `mship phase dev` blocks a feature without an approved spec; `mship finish` refuses to open a PR when the gate isn't satisfied (no WorkItem, or feature without approved spec) — the same shape as its existing test-evidence gate. (4) Hooks make it un-sidesteppable at the agent boundary: extend the SessionStart injection (from 'spawn before editing' to 'edits to feature code need a WorkItem + kind-appropriate approval') and add a PreToolUse block on source Edits/Writes when the active task lacks a WorkItem (or a feature lacks an approved spec). (5) Ground Control is the approval control plane — the operator approves feature specs in GC; the tooling blocks the agent until then.

## Relationship to existing enforcement

This extends the existing 'enforcement gate for untasked work' (reliable hooks, pre-push, session-start injection) from 'work needs a TASK' to 'work needs a WORKITEM, and feature-kind work needs an approved SPEC.' Reuse the same hook / pre-push machinery and message style. Pairs with MOS-210's capture kind-picker + dispatch-now (the GC-side flow that produces the kind-tagged WorkItems this gate checks).
