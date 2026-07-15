---
id: mship-context-for-kind-audience-shaped-mos-100
title: mship context --for/--kind audience-shaped output (MOS-100)
status: dispatched
created_at: '2026-07-11T18:09:00.427890Z'
updated_at: '2026-07-11T18:50:31.026686Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: '`mship context` with no `--for` flag produces output identical to today''s
    schema (no `audience` key present).'
  verdict: approved
- id: ac2
  text: '`mship context --for claude-code` and `mship context --for codex` each emit
    the full existing factual base payload plus an `audience` block whose `instructions`
    contain the implementer framing (work from the resolved worktree, never commit
    to main, commit via `mship commit`, journal via `mship debug hypothesis` when
    investigating).'
  verdict: approved
- id: ac3
  text: '`mship context --for human` emits the base payload plus an `audience` block
    with a prose-style human summary instruction.'
  verdict: approved
- id: ac4
  text: '`mship context --for reviewer --kind spec` emits the base payload plus an
    `audience` block instructing the reviewer to verify the implementation matches
    the task description/plan and flag over- or under-building.'
  verdict: approved
- id: ac5
  text: '`mship context --for reviewer --kind code-quality` emits the base payload
    plus an `audience` block instructing the reviewer to inspect the diff for maintainability,
    naming, test quality, and regressions.'
  verdict: approved
- id: ac6
  text: Passing `--kind` without `--for reviewer` (or with `--for` set to a non-reviewer
    audience) is rejected with a clear CLI error.
  verdict: approved
- id: ac7
  text: Passing `--for reviewer` without `--kind` is rejected with a clear CLI error
    (kind is required for the reviewer audience).
  verdict: approved
- id: ac8
  text: 'The JSON payload''s `audience` block always has exactly the shape `{"for":
    ..., "kind": ..., "instructions": ...}` when `--for` is supplied, and is absent
    entirely otherwise.'
  verdict: approved
- id: ac9
  text: TTY output additionally renders the `instructions` text as a readable markdown-ish
    block appended after the existing breadcrumb output, without altering any existing
    TTY lines.
  verdict: approved
- id: ac10
  text: All base factual fields already present in `build_context()` today (branch,
    worktrees, drift, phase, test results, etc.) are unchanged and quoted verbatim
    regardless of `--for`/`--kind`.
  verdict: approved
- id: ac11
  text: "No field in the output is inferred or synthesized (e.g. no `current_hypothesis`,\
    \ no `next_recommended_action`) \u2014 every value is either pre-existing factual\
    \ state or the fixed per-audience instruction string."
  verdict: approved
- id: ac12
  text: 'Unit tests cover: default (no `--for`) output is unchanged; each of `claude-code`,
    `codex`, `human`, `reviewer --kind spec`, `reviewer --kind code-quality` produces
    the expected `audience` block; the two invalid `--kind`/`--for` combinations are
    rejected.'
  verdict: approved
open_questions:
- id: q1
  text: Confirm the exact closed set of `--for` values (`claude-code`, `codex`, `human`,
    `reviewer`) is complete for now, or whether other agent runtimes (e.g. `gemini`)
    should be added in this same pass.
  answer: fine for now
- id: q2
  text: Confirm `claude-code` and `codex` should share one identical implementer instruction
    string (as designed) rather than each having runtime-specific wording (e.g. tool-name
    differences).
  answer: fine for now I think
non_goals:
- "No new `mship handoff` command or subcommand \u2014 this rides entirely on `mship\
  \ context`."
- "No inference, summarization, or LLM calls of any kind \u2014 `instructions` text\
  \ is static, hand-written, and identical on every invocation for a given `--for`/--kind\
  \ pair."
- "No change to the existing factual fields already emitted by `build_context()` (branch,\
  \ worktrees, drift, test results, phase, etc.) \u2014 this is purely additive."
- "No migration of `subagent-driven-development`'s prompt templates in this spec \u2014\
  \ that's a follow-up once `--for`/`--kind` ships; this spec only adds the capability."
risks:
- Adding `--kind` validation (only valid with `--for reviewer`) could be enforced
  inconsistently between CLI-level typer validation and core-level assembly; needs
  a single, clearly tested source of truth for the error path.
- If audience instruction strings drift from the actual prompt templates they're meant
  to replace, the two sources of truth (skill templates vs. mship-emitted instructions)
  could disagree during the transition period before the skill is migrated to consume
  them.
- "Static instruction text still has to be kept in sync by hand as workflow conventions\
  \ change (e.g. if `mship commit`/`mship debug hypothesis` semantics change) \u2014\
  \ mitigated by being colocated in the mship source rather than scattered across\
  \ skill files, but not eliminated."
task_slug: mship-context-for-kind-audience-shaped-mos-100
work_item_id: wi-20260711185031-6004053e
---
## Problem

`mship context` emits one factual JSON snapshot of task state (branch, worktrees, drift, test results, phase, etc.) for a single implicit audience. The subagent-driven-development flow now dispatches several downstream readers of that same state — implementer subagents (claude-code, codex), a spec-compliance reviewer, a code-quality reviewer, and humans reading a terminal — and each wants the same facts framed differently. Today that framing is hand-rolled inside prompt templates in the `subagent-driven-development` skill (`implementer-prompt.md`, `spec-reviewer-prompt.md`, `code-quality-reviewer-prompt.md`), which duplicates knowledge mship already has and drifts out of sync as `mship context`'s schema evolves.

## User story

As a controller dispatching subagents (or a human reading the terminal), I want `mship context --for <audience> [--kind <kind>]` to return the same factual base payload plus an audience-specific instruction block, so that I stop hand-maintaining audience framing in skill prompt templates and instead get it straight from the source of truth.

## Approach

Extend the existing `mship context` command with two new options — `--for` (`claude-code` | `codex` | `human` | `reviewer`) and `--kind` (`spec` | `code-quality`; only meaningful when `--for reviewer`) — no new command is introduced. `src/mship/cli/context.py` gains the two typer.Option flags, validates `--kind` is only supplied with `--for reviewer`, and passes both through to `build_context()`/a new helper in `src/mship/core/context.py`. That core module assembles the existing factual payload exactly as today, then appends an `audience` block: `{"for": <value>, "kind": <value-or-null>, "instructions": <static text>}`. The `instructions` text is STATIC per audience/kind pair — a fixed string constant, not generated or inferred — so output stays deterministic and reviewable, and the reviewer/tester can literally diff it. Audience framings: `claude-code`/`codex` get the implementer framing (work from the resolved task's worktree, never commit to main, commit via `mship commit`, journal investigation via `mship debug hypothesis`); `human` gets a short prose-style instruction to read the payload as a status summary; `reviewer --kind spec` gets the spec-compliance framing (verify the implementation matches the task description/plan, flag over- or under-building, don't trust the implementer's report); `reviewer --kind code-quality` gets the code-quality framing (inspect the diff for maintainability, naming, test quality, and regressions). When `--for` is omitted, behavior is byte-for-byte unchanged from today (no `audience` key at all) — this preserves the existing schema for any current caller. When `--for` is given, JSON output (the default, non-TTY path) gains the `audience` key nested in the same payload; the TTY/human-readable render path (`Output`) additionally prints a markdown-ish rendition of the `instructions` block after the existing breadcrumb/summary lines. No LLM calls, no synthesized fields (e.g. no invented "current hypothesis" or "next recommended action") are added anywhere in the payload — every value already existed in `build_context()`'s factual output or is one of the fixed instruction strings.

## Existing duplication this replaces

`src/mship/skills/subagent-driven-development/implementer-prompt.md`, `spec-reviewer-prompt.md`, and `code-quality-reviewer-prompt.md` currently hand-roll the exact framings this spec formalizes: worktree-not-main-checkout instructions for implementers, "verify against requirements, don't trust the report" instructions for spec reviewers, and "inspect the diff for maintainability/naming/tests" instructions for code-quality reviewers. This spec doesn't rewrite those templates (out of scope), but the `instructions` text for each `--for`/`--kind` pair should be drawn from the language already proven out in those templates so a later migration is a drop-in swap rather than a rewrite.

## Payload shape example

`mship context --for reviewer --kind spec` (JSON, abbreviated): `{"schema_version": "1", "active_tasks": [...], ..., "audience": {"for": "reviewer", "kind": "spec", "instructions": "Verify the implementation matches the task description and plan. Flag anything under-built (missing requirements) or over-built (unrequested scope). Do not trust the implementer's self-report — verify by reading the actual diff."}}`. All keys preceding `audience` are exactly what `build_context()` emits today; only the trailing `audience` key is new, and it is only present when `--for` was supplied.
