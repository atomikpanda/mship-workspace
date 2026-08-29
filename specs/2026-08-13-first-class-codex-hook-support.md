---
id: first-class-codex-hook-support
title: first class codex hook support. if we are unsure we can consult official documen
status: implemented
created_at: '2026-08-13T02:10:28.021245Z'
updated_at: '2026-08-13T11:48:52.863862Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: A fresh Mothership initialization in a project installs the existing Claude
    hooks, a project-local `.codex/hooks.json` containing Mothership bindings for
    Codex SessionStart, PreToolUse, and Stop, and a project-local `.omp/extensions/mship.ts`
    handling OMP `session_start`, `tool_call`, and `session_stop`.
  verdict: unreviewed
  evidence:
  - kind: artifact
    ref: tests/cli/test_init.py
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: null
  comment: null
- id: ac2
  text: Running initialization repeatedly produces no duplicate Mothership hook registrations,
    no semantically unnecessary rewrites, and no duplicate OMP extension; the resulting
    integrations remain functional.
  verdict: unreviewed
  evidence:
  - kind: artifact
    ref: tests/core/test_codex_hooks.py
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: null
  comment: null
- id: ac3
  text: When `.codex/hooks.json` already contains valid user configuration, initialization
    preserves all unrelated user-owned keys and hook entries while adding or updating
    only Mothership-owned entries.
  verdict: unreviewed
  evidence:
  - kind: artifact
    ref: tests/core/test_codex_hooks.py
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: null
  comment: null
- id: ac4
  text: When `.codex/hooks.json` is malformed, initialization does not silently discard
    or overwrite it. It reports a clear best-effort warning/error state, preserves
    the malformed source for recovery, and avoids claiming successful Codex installation;
    behavior is covered by tests.
  verdict: unreviewed
  evidence:
  - kind: artifact
    ref: tests/core/test_codex_hooks.py
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: null
  comment: null
- id: ac5
  text: Unrelated files and extensions under `.omp/extensions` are preserved. Updating
    `mship.ts` changes only the Mothership-owned extension artifact.
  verdict: unreviewed
  evidence:
  - kind: artifact
    ref: tests/core/test_omp_extension.py
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: null
  comment: null
- id: ac6
  text: "Claude SessionStart, Codex SessionStart, and OMP `session_start` all normalize\
    \ into the same shared policy operation and inject equivalent Mothership session\
    \ context through each runtime\u2019s native output contract."
  verdict: unreviewed
  evidence:
  - kind: artifact
    ref: tests/core/test_agent_hooks.py
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: null
  comment: null
- id: ac7
  text: Claude PreToolUse, Codex PreToolUse, and OMP `tool_call` all normalize edit,
    worktree, and WorkItem-relevant operations into the shared guard policy and translate
    allow/deny results correctly.
  verdict: unreviewed
  evidence:
  - kind: artifact
    ref: tests/core/test_agent_hooks.py
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: null
  comment: null
- id: ac8
  text: Codex edit normalization recognizes `apply_patch` and documented aliases.
    For a patch that creates, updates, moves, deletes, or otherwise targets multiple
    files, every target path is extracted, normalized, and evaluated before the operation
    is allowed.
  verdict: unreviewed
  evidence:
  - kind: artifact
    ref: tests/core/test_codex_hooks.py
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: null
  comment: null
- id: ac9
  text: If any target in a multi-target edit is denied by policy, the entire tool
    invocation is denied through the runtime-native mechanism; no partial allow is
    returned.
  verdict: unreviewed
  evidence:
  - kind: artifact
    ref: tests/cli/test_guard_edit.py
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: null
  comment: null
- id: ac10
  text: Documented bypass cases for the existing guard remain bypasses in all three
    runtimes, while non-bypassed prohibited operations remain denied. Tests explicitly
    distinguish intentional bypasses from adapter errors.
  verdict: unreviewed
  evidence:
  - kind: artifact
    ref: tests/core/test_agent_hooks.py
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: null
  comment: null
- id: ac11
  text: "Adapter/runtime failures\u2014including malformed event payloads, unsupported\
    \ runtime output behavior, or internal translation exceptions\u2014allow the underlying\
    \ runtime action or stop to proceed and emit a best-effort warning. Tests verify\
    \ fail-open behavior."
  verdict: unreviewed
  evidence:
  - kind: artifact
    ref: tests/cli/test_omp_hook.py
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: null
  comment: null
- id: ac12
  text: A policy denial produced by a successful shared-core evaluation blocks the
    operation in Claude, Codex, and OMP. Tests verify that policy denial is fail closed
    and cannot be converted to allow by adapter fallback.
  verdict: unreviewed
  evidence:
  - kind: artifact
    ref: tests/cli/test_guard_edit.py
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: null
  comment: null
- id: ac13
  text: Codex Stop uses Codex-native continuation output to continue when actionable
    Mothership inbox work exists, and permits stop when the inbox is drained.
  verdict: unreviewed
  evidence:
  - kind: artifact
    ref: tests/cli/test_drain.py
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: null
  comment: null
- id: ac14
  text: OMP `session_stop` uses OMP-native continuation behavior to continue when
    actionable Mothership inbox work exists, and permits stop when the inbox is drained.
  verdict: unreviewed
  evidence:
  - kind: artifact
    ref: tests/cli/test_omp_hook.py
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: null
  comment: null
- id: ac15
  text: Continuation processing cannot enter an unbounded stop/continue cycle. Tests
    cover repeated Stop/session_stop events, unchanged or failing inbox drain state,
    re-entry, and the bounded safety fallback.
  verdict: unreviewed
  evidence:
  - kind: artifact
    ref: tests/core/test_agent_hooks.py
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: null
  comment: null
- id: ac16
  text: Doctor reports useful states for all three runtimes and integrations, including
    healthy/installed, missing integration, malformed Codex config, missing Mothership
    event registrations, stale Mothership-owned artifacts, unavailable runtime, detectably
    old/incompatible runtime, and Codex trust/review requirements.
  verdict: unreviewed
  evidence:
  - kind: artifact
    ref: tests/core/test_doctor.py
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: null
  comment: null
- id: ac17
  text: Missing or detectably old Codex/OMP runtimes produce warnings and do not prevent
    Claude installation, initialization completion where otherwise safe, or use of
    available runtimes.
  verdict: unreviewed
  evidence:
  - kind: artifact
    ref: tests/core/test_doctor.py
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: null
  comment: null
- id: ac18
  text: Codex and OMP event input/output translation tests use representative official
    contract fixtures and assert exact normalized policy requests and valid runtime-native
    responses.
  verdict: unreviewed
  evidence:
  - kind: artifact
    ref: tests/core/test_omp_extension.py
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: null
  comment: null
- id: ac19
  text: The shared policy core has runtime-independent tests for context injection,
    guard allow/deny/bypass behavior, inbox draining, and continuation decisions.
  verdict: unreviewed
  evidence:
  - kind: artifact
    ref: tests/core/test_agent_hooks.py
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: null
  comment: null
- id: ac20
  text: End-to-end or integration coverage exercises fresh installation and all three
    lifecycle behaviors for Claude, Codex, and OMP.
  verdict: unreviewed
  evidence:
  - kind: artifact
    ref: tests/cli/test_init.py
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: null
  comment: null
- id: ac21
  text: All existing Claude hook and initialization tests continue to pass, and new
    parity tests demonstrate no regression in Claude behavior.
  verdict: unreviewed
  evidence:
  - kind: artifact
    ref: tests/core/test_claude_settings_guard.py
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: null
  comment: null
- id: ac22
  text: No generic public hook API, plugin package, or new externally supported extension
    surface is added.
  verdict: unreviewed
  evidence:
  - kind: artifact
    ref: src/mship/core/agent_hooks.py
    note: null
  - kind: test
    ref: test-runs/8.mothership
    note: null
  comment: null
open_questions: []
non_goals:
- Creating a generic public lifecycle-hook API, adapter framework, or plugin SDK.
- Publishing Codex or OMP integrations as separate packages or externally consumable
  plugins.
- Changing or bypassing Codex project trust review.
- Replacing runtime-native events with polling or a custom daemon protocol.
- Broad redesign of Mothership policy unrelated to the three existing lifecycle behaviors.
- Changing existing Claude-visible behavior, installation semantics, policy outcomes,
  or failure handling except for internal refactoring required to share the policy
  core.
- Treating missing or unsupported Codex/OMP runtimes as fatal to initialization or
  to use of another supported runtime.
risks:
- Codex and OMP event payloads or output contracts may differ across runtime versions;
  adapters must validate defensively and fail open with warnings on unsupported shapes.
- Naive JSON rewriting could overwrite user-owned `.codex/hooks.json` configuration
  or duplicate Mothership entries; ownership markers and structural merge tests are
  required.
- Parsing `apply_patch` incompletely could omit secondary file targets and allow prohibited
  edits; extraction must cover all file-operation headers and supported aliases.
- Stop continuation can recurse indefinitely if continuation-generated stops are not
  tracked; the implementation needs explicit loop-safety state and a bounded fallback.
- Fail-open adapter errors can obscure broken enforcement if warnings are not visible
  and doctor does not detect the condition.
- Shared-core refactoring could alter Claude behavior; cross-runtime contract tests
  and existing Claude regression tests are required.
- Project-local executable TypeScript or hook configuration may be subject to runtime
  trust, permission, or version restrictions; installation should remain safe and
  doctor should explain inactive states.
- Concurrent or interrupted initialization could leave partially written configuration;
  writes should be atomic where supported and recover cleanly.
task_slug: first-class-codex-hook-support
work_item_id: wi-20260813021415-4e70076d
clarification_reason: null
prose_verdicts: {}
---
## Problem

Mothership currently provides lifecycle-hook behavior for Claude but lacks first-class equivalents for Codex and OMP. Add native adapters for both runtimes while preserving the existing three lifecycle behaviors and centralizing their decisions in a shared Mothership policy core. The implementation must use each runtime’s documented events, discovery/configuration model, data contracts, trust/runtime constraints, and continuation semantics without regressing Claude.

## User story

As a developer using Mothership with Claude, Codex, or OMP, I want initialization to install the correct project-local lifecycle integration automatically, so that session context is injected, unsafe edits/worktree or WorkItem operations are blocked, and pending inbox work is drained or continued consistently regardless of agent runtime, while my existing runtime configuration remains intact.

## Approach

1. Refactor or formalize the existing lifecycle decision logic as an internal shared Mothership policy core. The core owns runtime-independent policy evaluation and behavior for: SessionStart context injection; PreToolUse edit/worktree/WorkItem guarding; and Stop inbox drain/continuation. Existing Claude hooks must call or remain behaviorally aligned with this core.

2. Add an internal Codex adapter using Codex-native SessionStart, PreToolUse, and Stop events. Install its project-local configuration at `.codex/hooks.json`. The adapter must parse Codex JSON input, normalize it into the shared policy model, invoke the core, and translate the result to the documented Codex JSON output contract. For edit detection, recognize Codex `apply_patch` and documented aliases and extract every target path represented by the patch input before policy evaluation; do not evaluate only the first path.

3. Add an internal OMP TypeScript extension at `.omp/extensions/mship.ts`, discovered through OMP’s project extension mechanism. Subscribe to `session_start`, `tool_call`, and `session_stop`; normalize each event into the shared model; invoke the core; and translate the result using OMP-native response and continuation semantics.

4. Extend the same Mothership initialization flow that installs Claude hooks so it also installs or updates the Codex and OMP integrations automatically. Installation must be idempotent. For `.codex/hooks.json`, perform a structural merge that adds or updates only Mothership-owned hook entries while preserving unrelated user keys, hooks, ordering where practical, and valid configuration. For `.omp/extensions/mship.ts`, install/update the Mothership-owned extension deterministically without altering unrelated extensions.

5. Preserve failure semantics. Adapter parsing, translation, invocation, or runtime compatibility errors must fail open and emit a best-effort warning, matching existing hook behavior. A successful policy evaluation that denies an operation must remain fail closed and be translated into the runtime’s native denial mechanism. Adapter errors must never be mistaken for policy approval or policy denial.

6. Implement Stop behavior with runtime-native continuation: Codex Stop must use Codex continuation semantics; OMP `session_stop` must use OMP continuation semantics. Both must drain pending Mothership inbox work while preventing unbounded continuation loops through explicit per-session/re-entry state or an equivalent bounded guard. If no actionable inbox work remains, allow the session to stop normally.

7. Extend `doctor` to validate Claude, Codex, and OMP integration states. Report installed/valid, missing, malformed, stale or incompatible, and runtime unavailable/too old where detectable. Missing or old Codex/OMP runtimes must produce best-effort warnings rather than making initialization or unrelated Mothership operation fail. Codex project trust/review requirements must be surfaced diagnostically and must not be bypassed.

8. Keep all adapters and contracts internal to Mothership. Reuse internal utilities where useful, but do not introduce a generic public hook framework, plugin SDK, or separately packaged runtime plugins.

## Functional requirements

Session start: On Claude SessionStart, Codex SessionStart, or OMP `session_start`, obtain the current Mothership context from the shared policy core and inject it using the runtime-native response contract. Empty context should result in a valid no-op response rather than an adapter error.

Pre-tool guard: On Claude PreToolUse, Codex PreToolUse, or OMP `tool_call`, normalize runtime/tool name, arguments, working directory or project root, session identity where available, and all candidate target paths. Invoke the shared edit/worktree/WorkItem guard once with the complete normalized operation. Return the runtime-native allow or deny response, preserving an actionable policy denial reason where the runtime supports it.

Stop: On Claude Stop, Codex Stop, or OMP `session_stop`, ask the shared policy core whether actionable inbox work remains and obtain the continuation payload. Continue only when work is available and the loop-safety guard permits it. Otherwise allow normal termination.

## Internal normalized contract

Define an internal, non-public normalized request/decision model. At minimum, requests distinguish `session_start`, `pre_tool_use`, and `stop`; carry runtime identity (`claude`, `codex`, or `omp`); project/session context; normalized tool identity and raw arguments where relevant; and a complete deduplicated list of normalized target paths. Decisions distinguish successful allow, successful deny, context injection, continue, and stop. Adapter/internal failure must be represented separately from a successful policy decision so fail-open handling cannot override a real denial.

## Codex-specific requirements

Use project-local `.codex/hooks.json` and official native SessionStart, PreToolUse, and Stop events. The generated/merged configuration must reference Mothership-owned adapter commands or entry points deterministically. Respect Codex project trust review; do not auto-approve or modify trust state.

Parse JSON input defensively and emit only documented JSON output. For `apply_patch` and documented aliases, parse all patch file-operation headers and collect every old/new/created/deleted/moved target as applicable. Normalize paths relative to the project/worktree context without discarding paths that later prove invalid; let shared policy determine allow/deny. A malformed or ambiguous patch must not be treated as a successful no-target guarded edit; use the existing policy’s conservative decision path where parsing succeeded enough to identify an edit, while adapter-level parser failure follows the specified fail-open warning behavior.

## OMP-specific requirements

Install a project-local `.omp/extensions/mship.ts` that is discoverable by OMP without modifying unrelated project extensions. Register handlers for `session_start`, `tool_call`, and `session_stop`. Keep OMP API usage isolated in the adapter, normalize tool names/arguments and path candidates before invoking shared policy, and use OMP’s native mechanism to deny tool calls or continue a stopped session. Extension load or event-handler exceptions must be caught at the adapter boundary and handled fail open with best-effort diagnostics.

## Installation and ownership

The existing initialization command/flow is the sole automatic installation entry point for Claude, Codex, and OMP integrations. Mothership-owned Codex entries must be identifiable without claiming ownership of the whole file. Merge by parsing the existing document, reconciling owned entries, retaining unrelated data, and writing atomically only when content changes. Never replace malformed user JSON with a fresh file silently.

The OMP extension path is Mothership-owned, but the containing directory and all sibling files are user/project-owned. Installation may create missing directories. Updates should be deterministic and preferably include an internal version marker for doctor and upgrade reconciliation.

## Failure and security semantics

Policy result precedence is strict: a completed policy evaluation returning deny must always produce runtime denial. Fail open applies only when the adapter or runtime integration cannot obtain or translate a valid policy result. Warnings must avoid leaking sensitive tool arguments, patch contents, inbox contents, or injected context. Path normalization must account for relative paths, absolute paths, path separators, rename pairs, and repeated targets without weakening worktree boundaries. No adapter may execute an edit itself or bypass runtime trust controls.

## Test plan

Installation tests: fresh project; missing parent directories; repeated initialization; upgrade of owned entries/artifacts; preservation of unrelated Codex keys/hooks and OMP extensions; malformed, empty, and partially configured Codex JSON; interrupted/failed write behavior where testable.

Translation tests: fixtures for every event in every runtime; absent optional fields; malformed inputs; exact native outputs for context, allow, deny, continue, and stop; warning/fail-open paths.

Patch tests: single update; add/delete; rename/move; multiple files; duplicate targets; quoted/spaced paths; relative and absolute paths where supported; documented aliases; malformed patch; one denied target among multiple allowed targets.

Policy tests: edit/worktree/WorkItem allow, deny, and documented bypasses; adapter exception versus real denial; consistent outcomes across Claude, Codex, and OMP.

Continuation tests: empty inbox; one and multiple items; drain completion; drain error; repeated unchanged inbox; adapter re-entry; maximum continuation bound; native Codex and OMP continuation output.

Doctor tests: healthy, missing, malformed, stale, event missing, runtime absent, runtime too old, and Codex trust/review warning states.

Regression tests: run the existing Claude suite unchanged where possible and add parity/integration assertions across all three runtimes.

## Definition of done

Implementation, documentation, fixtures, and automated tests are merged in the Mothership repository; supported initialization installs all three integrations; doctor diagnoses them; all acceptance criteria pass in CI; existing Claude behavior is unchanged; and no public plugin or generic hook API is introduced.
