---
id: agent-harness-parity
title: 'Agent harness parity: portable dispatch and complete Codex/OMP workflows'
status: implemented
created_at: '2026-08-13T19:25:02.380476Z'
updated_at: '2026-08-14T11:13:34.740786Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: With no `dispatch_models` override, implementer, standalone, and reviewer
    dispatch stubs contain only portable model behavior; no built-in default or generated
    instruction names Anthropic `sonnet`, `haiku`, or `opus`, and `inherit` is documented
    as using the harness default
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: full branch suite passed after live agentic-review remediation
  - kind: test
    ref: test-runs/5.mothership
    note: full branch suite passed after live agentic-review remediation
  - kind: test
    ref: test-runs/7.mothership
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: fresh full branch suite passed after final agentic-review cycle
  comment: null
- id: ac2
  text: An operator-supplied `dispatch_models` value is stored and emitted unchanged,
    while each supported harness adapter either applies it through a supported model
    selector or returns an actionable unsupported-selector error instead of silently
    substituting a model
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: full branch suite passed after live agentic-review remediation
  - kind: test
    ref: test-runs/7.mothership
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: fresh full branch suite passed after final agentic-review cycle
  comment: null
- id: ac3
  text: When Codex hook files are current but `codex_hooks` is unavailable or false,
    `mship init --install-hooks` and `mship doctor` report Codex as configured but
    inactive and print the exact feature-enable and `/hooks` review actions; neither
    command modifies user Codex configuration or trust
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  - kind: test
    ref: test-runs/4.mothership
    note: full branch suite passed after final review fix
  - kind: test
    ref: test-runs/5.mothership
    note: full branch suite passed after live agentic-review remediation
  - kind: test
    ref: test-runs/7.mothership
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: fresh full branch suite passed after final agentic-review cycle
  comment: null
- id: ac4
  text: When Codex hook capability is enabled and the project hook registration is
    current, health output distinguishes the remaining manual trust requirement from
    configuration errors without simultaneously presenting the lifecycle integration
    as fully active
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: full branch suite passed after live agentic-review remediation
  - kind: test
    ref: test-runs/7.mothership
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: fresh full branch suite passed after final agentic-review cycle
  comment: null
- id: ac5
  text: '`mship skill install --only omp` or the canonical Pi alias installs every
    bundled Mothership skill into the supported OMP/Pi discovery location without
    overwriting foreign content, and a repeated install is byte-idempotent'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  - kind: test
    ref: test-runs/4.mothership
    note: full branch suite passed after final review fix
  - kind: test
    ref: test-runs/5.mothership
    note: full branch suite passed after live agentic-review remediation
  - kind: test
    ref: test-runs/7.mothership
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: fresh full branch suite passed after final agentic-review cycle
  comment: null
- id: ac6
  text: '`mship doctor` reports OMP/Pi bundled-skill availability separately from
    the OMP lifecycle extension and gives an actionable repair command for missing,
    stale, dangling, or foreign installations'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  - kind: test
    ref: test-runs/4.mothership
    note: full branch suite passed after final review fix
  - kind: test
    ref: test-runs/5.mothership
    note: full branch suite passed after live agentic-review remediation
  - kind: test
    ref: test-runs/7.mothership
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: fresh full branch suite passed after final agentic-review cycle
  comment: null
- id: ac7
  text: '`mship context --for omp` succeeds and emits the same implementer invariants
    as `--for claude-code` and `--for codex`; existing audience validation remains
    strict for unknown values'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  - kind: test
    ref: test-runs/4.mothership
    note: full branch suite passed after final review fix
  - kind: test
    ref: test-runs/5.mothership
    note: full branch suite passed after live agentic-review remediation
  - kind: test
    ref: test-runs/7.mothership
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: fresh full branch suite passed after final agentic-review cycle
  comment: null
- id: ac8
  text: Equivalent Claude, Codex, and OMP session-start, guarded-edit, and stop fixtures
    produce equivalent shared policy decisions, including multi-target extraction,
    bypass behavior, actionable inbox continuation, bounded stop re-entry, and adapter
    failure reporting
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  - kind: test
    ref: test-runs/4.mothership
    note: full branch suite passed after final review fix
  - kind: test
    ref: test-runs/5.mothership
    note: full branch suite passed after live agentic-review remediation
  - kind: test
    ref: test-runs/7.mothership
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: fresh full branch suite passed after final agentic-review cycle
  comment: null
- id: ac9
  text: Focused runtime integration tests prove Codex capability diagnostics, OMP
    extension compatibility, skill discovery, and portable dispatch defaults; existing
    Claude, Codex, and OMP lifecycle contract tests remain green
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  - kind: test
    ref: test-runs/4.mothership
    note: full branch suite passed after final review fix
  - kind: test
    ref: test-runs/5.mothership
    note: full branch suite passed after live agentic-review remediation
  - kind: test
    ref: test-runs/7.mothership
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: fresh full branch suite passed after final agentic-review cycle
  comment: null
open_questions: []
non_goals:
- Changing the shared edit guard, WorkItem gate, inbox continuation, or fail-open
  policy
- Automatically enabling Codex experimental features or trusting project hooks
- Adding Ground Control application UI or API behavior
- Changing relay, GitHub, worktree, or PR lifecycle behavior
- Inventing a Gemini skill installer without a documented discovery directory
- Adding telemetry or provider-specific model selection logic to Mothership core
risks:
- Changing the reviewer default from `sonnet` to `inherit` may increase reviewer cost
  on sessions using expensive models; operator overrides remain the explicit cost-control
  mechanism
- Codex feature-list output and hook trust UX may change across Codex versions; capability
  parsing must fail clearly without treating configuration as active
- OMP/Pi skill discovery paths may vary by profile or release; installation must derive
  supported locations rather than hardcode one user's home layout
- Runtime adapters can drift even when the shared policy remains correct; conformance
  tests must cover adapter payload extraction as well as core decisions
task_slug: agent-harness-parity
work_item_id: wi-20260813193359-1ca256da
clarification_reason: null
prose_verdicts: {}
---
## Problem

Mothership's shared lifecycle policy is runtime-neutral, but its surrounding setup and dispatch contracts are not. Reviewer dispatch defaults to the Claude-specific model name `sonnet` and requires controllers to pass it verbatim; Codex hook files can be reported as installed while the runtime feature is disabled or the project remains untrusted; and OMP/Pi receives lifecycle hooks without supported skill installation, health checks, or tailored context. These gaps make the documented workflow reliable in Claude Code but require silent controller deviations or manual discovery in other harnesses.

## User story

As a maintainer using Claude Code, Codex, or OMP/Pi, I want Mothership setup, dispatch, and health reporting to use portable contracts, so that the same guarded workflow works without provider-specific assumptions or hidden activation steps.

## Approach

Keep `agent_hooks.py` as the single runtime-independent owner of session context, edit policy, and inbox continuation. Make the built-in dispatch model default portable: `inherit` means the harness uses its current/default model, while operator-configured model strings remain opaque overrides. Update skill adapters so a harness with no per-subagent model selector has an explicit platform-default path rather than being told to pass an impossible model field. After writing Codex hook configuration, reuse one capability probe to report active versus configured-but-inactive state and exact enable/trust actions; never mutate global Codex configuration or trust. Add first-class OMP/Pi skill installation and doctor coverage using the discovery location verified against the supported OMP release, plus an `omp` tailored-context audience. Keep Gemini's native-flow limitation explicit unless a supported discovery contract is verified. Add cross-adapter conformance tests around equivalent lifecycle decisions and runtime activation diagnostics.

## Architecture

Keep three boundaries explicit. Core policy owns decisions and remains unaware of harness APIs. Runtime adapters own event normalization, activation probes, model-selector capability, and native discovery paths. Skills own the human/agent instructions that map portable dispatch semantics to each harness. Setup and doctor must call the same probes so they cannot disagree about whether an installed artifact is usable.

## Delivery order

Implement as independent plan tasks in one Mothership repository change: first portable dispatch semantics and skill wording; second consolidated Codex activation diagnostics; third OMP/Pi skill installation, context audience, and health checks; fourth cross-runtime conformance and smoke coverage. Each task must preserve existing foreign-file and atomic-write protections.

## Verification

Run focused unit and CLI tests for dispatch, skill installation, context audiences, init, doctor, and all three adapters. Smoke-test setup in temporary homes. Where Codex and OMP binaries are available, run their capability/version probes and verify that health output matches the actual runtime state; do not auto-approve trust during tests.
