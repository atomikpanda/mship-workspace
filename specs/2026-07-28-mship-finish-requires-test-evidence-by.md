---
id: mship-finish-requires-test-evidence-by
title: mship finish requires test evidence by default
status: implemented
created_at: '2026-07-28T20:49:38.484328Z'
updated_at: '2026-07-29T10:33:03.190350Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: Bare `mship finish` on a task with a configured test target and no passing
    evidence refuses with an actionable message (run `mship test`, or pass --no-require-tests);
    with passing evidence it proceeds.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/8.mothership
    note: null
  - kind: commit
    ref: e6067774685d02b4c8083a8165e0d691d385eaab
    note: null
  - kind: commit
    ref: 7a305fb5d6cf2d27eb130408fe737a8cc33c43d0
    note: null
  comment: null
- id: ac2
  text: '`--no-require-tests` opts out with a plainly stated waiver line in the finish
    output; tasks whose affected repos have no `test` target configured downgrade
    to the current warning, naming the exempted repos.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/8.mothership
    note: null
  - kind: commit
    ref: e6067774685d02b4c8083a8165e0d691d385eaab
    note: null
  - kind: commit
    ref: 7a305fb5d6cf2d27eb130408fe737a8cc33c43d0
    note: null
  comment: null
- id: ac3
  text: '`--require-tests` is accepted as a hidden deprecated no-op with a stderr
    warning, mirroring the --stub precedent.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/8.mothership
    note: null
  - kind: commit
    ref: e6067774685d02b4c8083a8165e0d691d385eaab
    note: null
  comment: null
- id: ac4
  text: Skill canonical finish commands return to bare `mship finish` with prose stating
    the default; the ergonomics guard asserts no skill still passes --require-tests.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/8.mothership
    note: null
  - kind: commit
    ref: 0b63fa51782d7f99f6e49e9523849a917b974103
    note: null
  comment: null
- id: ac5
  text: The overnight cloud-worker routine's finish path is verified to produce evidence
    before finishing (updated if not).
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/8.mothership
    note: null
  - kind: commit
    ref: b7fb59c91bd77a3184b04cc92d76df31247e0f9f
    note: null
  comment: null
- id: ac6
  text: Unit tests cover all three paths (block, evidence-pass, no-target warn) and
    the deprecation no-op.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/8.mothership
    note: null
  - kind: commit
    ref: 7a305fb5d6cf2d27eb130408fe737a8cc33c43d0
    note: null
  comment: null
open_questions: []
non_goals:
- Changing what counts as evidence (a passing `mship test` iteration for the task,
  as today).
- Gating `mship commit` (post-finish iteration) or `mship close`.
- "Bypass-logging the opt-out \u2014 it is a legitimate flag, not a gate violation."
risks:
- "Existing scripts/routines calling bare `mship finish` on evidence-less tasks start\
  \ failing \u2014 deliberate, but the overnight cloud-worker routine must be checked\
  \ and updated to run `mship test` before finish (it should already)."
- The no-test-target exemption could mask a misconfigured repo (test task missing
  by accident); the warning text must name the repos it exempted so silence never
  reads as coverage.
task_slug: null
work_item_id: null
clarification_reason: null
prose_verdicts: {}
---
## Problem

Three skills tell implementer subagents that `mship finish` gates on recorded test evidence (the reason they must run `mship test`, never bare runners), but the gate is an opt-in flag: bare `mship finish` only warns when no passing evidence exists, and the canonical skill invocations historically omitted `--require-tests`. The intent-scan audit (2026-07-28) rated this 'erodes': the default routed flow opens PRs with no test-evidence enforcement while the documentation implies enforcement. The operator has decided to flip the default rather than only fixing the docs.

## User story

As the operator, I want `mship finish` to refuse to open a PR when no passing test evidence exists for the task, so that the evidence chain the skills teach is actually enforced by default and a green `mship test` run is a real precondition of shipping.

## Approach

Flip the default: `mship finish` blocks (current `--require-tests` behavior) when the task has no passing test evidence, unless `--no-require-tests` is passed. Scope the block to tasks where evidence is expectable: if NO affected repo has a `test` task target configured, downgrade to the current warning (a docs-only workspace cannot produce evidence and must not need a permanent opt-out). `--require-tests` remains accepted as a deprecated no-op (hidden, stderr deprecation warning) for one release, mirroring the `--stub` precedent. The `--no-require-tests` opt-out is a normal flag, not bypass-logged — legitimate for docs-only tasks in code workspaces — but the finish output states plainly when the gate was waived and why. Skills' canonical commands (updated to `--require-tests` in the intent-scan batch) get simplified back to bare `mship finish` in the same PR, with prose stating the default. Serve/API finish paths (if any expose finish) inherit the same default.
