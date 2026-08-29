---
id: ground-control-message-reconciler
title: Ground Control message reconciliation actor
status: implemented
created_at: '2026-08-21T10:25:20.028663Z'
updated_at: '2026-08-25T11:10:23.390106Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: Given a newly created message connection, exactly one per-connection serialization
    owner initiates a full initial load, and the UI receives the accepted loaded state
    before incremental live polling advances from that state.
  verdict: approved
  evidence: []
  comment: null
- id: ac2
  text: Given an initial full-load failure, the same connection schedules a cancellable
    retry of the full load; it does not treat the failed attempt as success, advance
    the live cursor, or begin incremental polling from an uninitialized cursor.
  verdict: approved
  evidence: []
  comment: null
- id: ac3
  text: Given connection A is waiting for an initial-load retry and connection B is
    ready to load or poll, B can complete and publish messages before A's retry fires,
    demonstrating that retry delay and failure handling do not block other connections.
  verdict: approved
  evidence: []
  comment: null
- id: ac4
  text: Given two manual refreshes whose network results complete in reverse order,
    the owner publishes results according to the defined revision ordering and the
    older completion cannot overwrite state produced by the newer refresh.
  verdict: approved
  evidence: []
  comment: null
- id: ac5
  text: Given an in-flight initial load, refresh, or poll from an older generation
    completes after replacement or cancellation, its result produces no message-state
    change, cursor change, retry, or restarted poll.
  verdict: approved
  evidence: []
  comment: null
- id: ac6
  text: Given a successful live-poll result for the current generation and eligible
    revision, its messages and cursor are committed together; given the same result
    is stale, failed, cancelled, or superseded, neither its messages nor its cursor
    are committed.
  verdict: approved
  evidence: []
  comment: null
- id: ac7
  text: Given a connection is adopted or replaced while live polling is active, the
    surviving owner retains the last accepted messages and cursor, cancels or invalidates
    obsolete work, and continues polling from that cursor without requiring a new
    user action.
  verdict: approved
  evidence: []
  comment: null
- id: ac8
  text: Given adoption occurs while an old owner's request is in flight, at most one
    owner can accept the completion, the obsolete owner cannot publish afterward,
    and subsequent live updates are published by the surviving owner.
  verdict: approved
  evidence: []
  comment: null
- id: ac9
  text: Given a connection is removed or its lifecycle is cancelled, all pending retry
    timers and owned asynchronous work are cancelled or invalidated, and later callbacks
    cannot update UI state, advance a cursor, or schedule more work.
  verdict: approved
  evidence: []
  comment: null
- id: ac10
  text: Given a transient poll or refresh failure after a successful load, the connection
    preserves its last accepted messages and cursor and follows the owner's retry
    policy without creating overlapping retry loops.
  verdict: approved
  evidence: []
  comment: null
- id: ac11
  text: Given repeated failures on one connection, another active connection continues
    to accept manual refreshes and live-poll results independently.
  verdict: approved
  evidence: []
  comment: null
- id: ac12
  text: Automated concurrency tests use controllable scheduling to cover reverse-order
    refresh completion, stale generation completion, cancellation during retry, cursor
    commit rejection, and adoption with in-flight work, and they deterministically
    assert the externally observable state and requests.
  verdict: approved
  evidence: []
  comment: null
- id: ac13
  text: Installing the redesigned Android build over a build based on frozen head
    dc913e08 requires no persisted-data migration, account reset, or server rollout;
    existing connections can load and poll using the unchanged API and stored state
    contracts.
  verdict: approved
  evidence: []
  comment: null
- id: ac14
  text: The change is confined to Ground Control Android and passes the existing message
    loading, refresh, polling, connection lifecycle, and adoption/replacement regression
    suites without changing user-visible message formatting or controls.
  verdict: approved
  evidence: []
  comment: null
open_questions: []
non_goals:
- Changing Ground Control server APIs, message payloads, cursor semantics, or wire
  protocols.
- Changing iOS, web, backend, or any client other than Ground Control Android.
- Adding new user-facing refresh controls, connection-management features, or message
  presentation behavior.
- Guaranteeing delivery beyond the guarantees of the existing polling API.
- 'Reworking unrelated connection lifecycle behavior outside the parent message-connection-lifecycle
  task and PR #75.'
- Migrating or rewriting persisted message data; the redesign must consume existing
  state without a user-visible migration.
risks:
- Incorrect generation or revision transitions could discard a valid result or allow
  a stale result to overwrite newer state.
- An incomplete adoption handoff could duplicate messages, skip live updates, regress
  the cursor, or leave both old and new owners polling.
- Cancellation races could allow obsolete callbacks to mutate state unless every completion
  is validated by the serialization owner.
- Unbounded or poorly delayed full-load retries could cause battery, network, or backend
  load even though retries are isolated by connection.
- Ordering all state transitions through one owner could expose deadlocks, queue growth,
  or responsiveness regressions if network waits or retry delays run inside the serialized
  execution path.
- 'The redesign may reveal assumptions in the frozen PR #75 implementation or tests
  that couple UI/model identity to the replaced connection instance.'
task_slug: ground-control-message-reconciler
work_item_id: wi-20260821115639-e33d47b2
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
  risks:
    verdict: approved
    comment: null
  scope_risk:
    verdict: approved
    comment: null
  non_goals:
    verdict: approved
    comment: null
---
## Problem

PR #75 at frozen head dc913e08 distributes message-loading and polling lifecycle decisions across competing asynchronous paths. Initial loads, manual refreshes, live polls, connection adoption/replacement, cancellation, cursor updates, and retries can therefore race, commit stale data, advance cursors incorrectly, stop live updates during adoption, or let one failing connection interfere with others. Ground Control Android needs a single, deterministic ownership model for each message connection so lifecycle behavior remains correct under concurrency and failure.

## User story

As a Ground Control Android user, I want each message connection to load, refresh, and receive live updates reliably through reconnects and connection replacement, so that I see current messages without stale results, gaps caused by lifecycle races, or one broken connection blocking the others.

## Approach

Redesign PR #75 from frozen head dc913e08 around one serialization owner per message connection. The owner is the sole authority for connection state transitions and coordinates initial full load, manual refresh, live polling, adoption/replacement, cancellation, cursor advancement, and retry scheduling. Asynchronous work may execute outside the owner, but every completion is returned to the owner and validated before it can mutate state. Assign a generation to each connection ownership lifecycle; replacement, adoption boundaries that invalidate prior work, and cancellation invalidate older generations so their completions are ignored. Assign monotonically increasing revisions to refresh and poll requests within a generation; the owner applies eligible completions in the defined request order and rejects results that have become stale, preventing an older request from overwriting newer state. Advance the live cursor only when the corresponding result is accepted and committed; failed, cancelled, superseded, or stale work cannot advance it. On initial-load failure, retain the connection and schedule another full-load attempt through a non-blocking, cancellable retry path rather than switching prematurely to an incremental poll. Retry state is isolated per connection so backoff or repeated failure on one connection does not block another connection owner. During adoption/replacement, transfer the accepted message state, live cursor, and polling intent to the surviving owner, invalidate and cancel obsolete work, and continue live polling from the transferred cursor. Preserve existing Ground Control Android user-facing behavior and data/protocol contracts; this is an internal lifecycle redesign of PR #75, not a server, wire-format, or persisted-data migration.

## Architecture

Model each message connection as an independently scheduled state machine with a single serialization owner. Network operations and delays must not block that owner's serialized state-processing loop. Work carries connection identity, generation, and revision metadata back to the owner. The owner alone decides whether to accept a completion, update message state, commit a cursor, schedule a retry, or launch follow-up polling. Adoption/replacement is an explicit handoff: capture accepted state and polling intent, invalidate the old generation, cancel obsolete work, initialize the surviving ownership state, and resume from the accepted cursor.

## Testing

Use deterministic fake loaders, pollers, clocks, and cancellation controls to force all relevant interleavings. Verify behavior through published message state, issued full-load and poll requests, committed cursors, retry scheduling, and absence of post-cancellation effects. Include multi-connection tests proving that delayed retries and failures are isolated, plus regression coverage for normal initial load, manual refresh, continuous polling, adoption, replacement, and teardown.

## Migration and Compatibility

Implement the redesign as a replacement of the internal lifecycle coordination introduced by PR #75 at frozen head dc913e08. Do not change server endpoints, request or response schemas, cursor meaning, persisted connection/message formats, or user-facing controls. Existing stored state must remain readable in place, and rollout must not depend on coordinated backend or non-Android client changes.
