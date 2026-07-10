---
id: dispatch-ergonomics
title: 'Dispatch ergonomics: plan-anchored dispatch, spec-dispatch task adoption,
  mship-test evidence'
status: implemented
created_at: '2026-06-19T12:09:38.680344Z'
updated_at: '2026-06-19T15:15:31.869178Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: extract_plan_task(plan_text, id) returns the exact inner content of the matching
    anchored block and raises a clear error for a missing id, a duplicate id, and
    an unterminated block (unit-tested).
  verdict: approved
- id: ac2
  text: '`mship dispatch --task <slug> --plan <path> --plan-task <id>` emits the normal
    dispatch prompt whose instruction is the extracted task section.'
  verdict: approved
- id: ac3
  text: '`mship dispatch` enforces exactly one instruction source: zero sources errors;
    more than one of (inline / stdin `-` / `--plan-task`) errors; `--instruction -`
    reads stdin; inline `--instruction "<text>"` still works.'
  verdict: approved
- id: ac4
  text: '`mship spec dispatch <id> --task <slug>` binds the spec to that existing
    task without spawning a duplicate; re-dispatching a spec already bound to a task
    reuses it (idempotent); an unknown/ambiguous binding errors clearly naming `--task`;
    with no task and no --task, the slug==spec.id auto-spawn still works.'
  verdict: approved
- id: ac5
  text: "The bundled writing-plans skill text emits the `<!-- mship:task id=\u2026\
    \ -->` anchor format, and the subagent-driven-development skill text references\
    \ `mship dispatch \u2026 --plan-task` and `mship test` (guard test)."
  verdict: approved
open_questions: []
non_goals:
- "Auto-discovering the plan path when --plan is omitted \u2014 for v1, --plan is\
  \ required alongside --plan-task; discovery is a later nicety."
- "Parsing free-form `### Task N` headings \u2014 explicit anchors are used by design\
  \ to avoid markdown-format brittleness."
- "An mship driver that loops/dispatches every task in a plan \u2014 this spec only\
  \ makes single-task dispatch plan-aware; a 'dispatch all tasks' orchestrator is\
  \ a separate follow-up."
- "Changing `mship finish`'s evidence gate \u2014 it already warns and `--require-tests`\
  \ blocks; MOS-142 is satisfied by the skill invoking `mship test`."
risks:
- 'Anchor contract drift: writing-plans must emit anchors that `extract_plan_task`
  understands; a guard test on the bundled skill text mitigates regression.'
- Exactly-one-of instruction validation could break existing `mship dispatch -i "..."`
  callers if mis-implemented; keep inline the default and cover with tests.
- spec dispatch --task binding the wrong task; mitigated by requiring an explicit
  --task (no slug heuristics) and erroring on ambiguity.
- extract_plan_task on malformed/nested anchors; mitigated by explicit missing/duplicate/unterminated
  error paths + tests.
task_slug: dispatch-ergonomics
work_item_id: wi-20260702110439-1eae7cc8
---
## Problem

The subagent-driven-development workflow is meant to use mship's primitives but bypasses them in practice. Implementer prompts are hand-assembled in the controller instead of via `mship dispatch -i`, so the worktree/journal/base/skill scaffolding gets retyped and is error-prone (MOS-185; MOS-143 is the same issue). Dispatched subagents run bare `pytest` rather than `mship test`, so `mship finish` finds no test-evidence trail (MOS-142). And `mship spec dispatch` only adopts a task when `slug == spec.id` — if a task was pre-spawned under a different slug it creates a DUPLICATE task (MOS-181, hit during MOS-180). Net effect: plan execution isn't deterministic and can't be driven cleanly unattended, which is the opposite of what the dispatch primitives are for.

## User story

As a controller executing an implementation plan (interactively or unattended), I want each subagent's instruction to come straight from the plan via `mship dispatch`, and the dispatch/test primitives to be the path of least resistance, so that fan-out is deterministic, carries proper test evidence, and never spawns duplicate tasks.

## Approach

Make the implementation plan the single source of per-subagent instructions, using an anchored hybrid. (1) writing-plans wraps each task section in explicit anchors `<!-- mship:task id=N -->` … `<!-- /mship:task -->`. (2) `mship dispatch` gains `--plan <path> --plan-task <id>`: a new pure helper `extract_plan_task(plan_text, task_id)` (core/dispatch.py) returns the exact content between the matching anchors (clear errors on missing id / duplicate id / unterminated block), and the CLI uses that extracted section as the instruction, then builds the prompt with the existing worktree/journal/base/skill scaffolding unchanged. The instruction source becomes exactly-one-of: inline `--instruction "<text>"` | stdin `--instruction -` | `--plan-task <id>` (with required `--plan <path>`); `-i/--instruction` is no longer unconditionally required and the CLI errors on zero or multiple sources. (3) `mship spec dispatch` gains `--task <slug>` to bind an existing task plus idempotent reuse when a task is already bound (`task.spec_id == spec.id`), keeping the `slug == spec.id` auto-spawn and erroring clearly (naming `--task`) on ambiguity (MOS-181). (4) The bundled skills are updated: writing-plans emits the anchors and documents `mship dispatch --task <slug> --plan <plan> --plan-task <N>` plus a `mship test` step; subagent-driven-development (SKILL.md + implementer-prompt.md) has the controller build each implementer prompt via that dispatch command (stdout → subagent prompt) and has subagents run `mship test` (not bare pytest) so finish keeps the evidence trail.

## Architecture

core/dispatch.py gains the pure `extract_plan_task(plan_text, task_id) -> str` (anchor-delimited extraction, no I/O) alongside the existing prompt builder; cli/dispatch.py wires `--plan`/`--plan-task`, the stdin (`-`) path, and the exactly-one-of instruction-source validation, then feeds the resolved instruction into the unchanged `build_dispatch_prompt`. core/spec_dispatch.py's `dispatch_spec` gains explicit-task binding (`--task`) + idempotent reuse keyed on `task.spec_id`; cli/spec.py threads the `--task` option. The bundled skills (src/mship/skills/writing-plans, src/mship/skills/subagent-driven-development) are documentation changes that adopt the anchors + the dispatch/`mship test` commands. Each unit is independently testable; dispatch stays a thin CLI over pure helpers.

## Testing

core/dispatch: extract_plan_task table — found, missing id, duplicate id, unterminated block, and a multi-task plan (extracts the correct block). cli/dispatch: `--plan-task` reads the plan and the extracted section appears in the emitted prompt; exactly-one-of validation (zero → error, two → error); `--instruction -` reads stdin; inline `--instruction` still works. spec_dispatch: `--task` binds an existing differently-slugged task (no duplicate); idempotent reuse when already bound; error on unknown/ambiguous `--task`; auto-spawn when no task and no flag. Skills guard: assert the bundled writing-plans SKILL.md contains the anchor markers and subagent-driven-development references `--plan-task` + `mship test`. All locally verifiable; no network.
