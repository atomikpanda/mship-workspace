---
id: durable-queryable-spec-rejections-for-444
title: 'Durable, queryable spec rejections (substrate for #444 L5 ratchet)'
status: implemented
created_at: '2026-07-31T02:13:20.081217Z'
updated_at: '2026-07-31T09:53:37.141908Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: A spec `request-changes` (via the CLI) writes a durable, enumerable rejection
    record capturing {spec_id, actor, reason, timestamp} that STILL EXISTS after the
    spec is later re-approved (i.e. it is not the clarification_reason field, which
    approval nulls).
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.mothership
    note: null
  comment: null
- id: ac2
  text: The serve HTTP request-changes path writes the same durable rejection record
    as the CLI path.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.mothership
    note: null
  comment: null
- id: ac3
  text: A rejection with no reason is refused/prompted (reason required at rejection
    time), so the record always carries reason text.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.mothership
    note: null
  comment: null
- id: ac4
  text: '`mship spec rejections <id>` lists that spec''s rejections as {actor, reason,
    timestamp}, in chronological order, reading only the durable records (not clarification_reason).'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.mothership
    note: null
  comment: null
- id: ac5
  text: '`mship spec rejections --all` enumerates rejections across all specs for
    the L5 ratchet and future backtests.'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.mothership
    note: null
  comment: null
- id: ac6
  text: A malformed or legacy journal entry does not crash the query (it is skipped).
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.mothership
    note: null
  comment: null
open_questions: []
non_goals:
- "Building the L5 rejection->row ratchet itself \u2014 that is #444 Wave 4; this\
  \ only lays its substrate."
- "Backfilling historical rejections \u2014 there are effectively none to backfill."
- "Plan rejection \u2014 there is no plan-review/reject lifecycle in the codebase\
  \ (cli/plan.py only does plan-assumptions gating), so this is spec-only."
risks:
- "Encoding {actor, reason} as JSON in the journal entry text is a lightweight convention,\
  \ not a schema \u2014 the query parser must tolerate malformed/legacy entries (skip,\
  \ don't crash)."
- '`--all` scans the logs dir rather than using an index; fine at current scale, may
  need an index if rejection volume grows.'
task_slug: null
work_item_id: null
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
  scope_risk:
    verdict: approved
    comment: null
---
## Problem

Plan/spec rejections are not first-class in mship. `mship spec request-changes` requires a reason but stores it only in `spec.clarification_reason`, which `approve_spec()` nulls on the next approval — so the rejection reason is erased and there is no queryable rejection history anywhere (across ~98 specs, zero durable request-changes records survive). This directly blocks #444 Wave 4 / L5, the rejection->row ratchet, which turns each rejection reason into a new assumption row and therefore needs a durable rejection event to hang off; it also starved the #444 backtest, which had no real rejected plans to measure recall against.

## User story

As an operator (and as the future L5 ratchet), I want every spec rejection recorded as a durable, reason-carrying event I can enumerate, so that rejection reasons survive re-approval and can be turned into assumption rows and backtest data.

## Approach

Reuse the append-only journal (LogManager), not a new store and not a new Spec field (a field would be overwritten exactly like clarification_reason). At `request-changes` — both the CLI path (cli/spec.py) and the serve HTTP path (core/serve.py) — write a journal entry keyed by the spec id with `action=rejected` whose text carries {actor, reason} as JSON (timestamp is the entry's, spec id is the log key). Because the journal is append-only, the record survives a later re-approval. The reason is already required at both paths. Add a thin query CLI `mship spec rejections <id>` (reads that spec's log filtered to action=rejected) and `mship spec rejections --all` (a cheap scan of the logs dir) that lists {actor, reason, timestamp}. Actor is the host USER on the CLI and "operator" on the serve path, mirroring the existing approve/verdict attribution.

## Testing

Unit tests: request-changes (CLI + serve) writes an action=rejected journal entry; the entry survives a subsequent approve (assert it's still enumerable after approval nulls clarification_reason); `spec rejections <id>` parses {actor,reason,timestamp} and orders chronologically; `--all` aggregates across specs; a malformed entry is skipped, not fatal.
