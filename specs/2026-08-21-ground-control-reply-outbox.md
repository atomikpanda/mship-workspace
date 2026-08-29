---
id: ground-control-reply-outbox
title: Ground Control durable reply outbox
status: implemented
created_at: '2026-08-21T10:25:20.866148Z'
updated_at: '2026-08-25T11:10:25.687538Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: When a user submits a valid notification reply, the exact accepted reply text,
    its decision free-text policy, and all context required for execution and rendering
    are committed to Room before any WorkManager enqueue request is made.
  verdict: approved
  evidence: []
  comment: null
- id: ac2
  text: Submitting a reply from a notification does not perform Room disk I/O or wait
    for WorkManager enqueue completion on the Android main thread, as verified by
    an instrumentation test with main-thread database access prohibited and a deliberately
    delayed persistence/enqueue path.
  verdict: approved
  evidence: []
  comment: null
- id: ac3
  text: If the app process terminates after the Room commit but before or during WorkManager
    enqueue, a subsequent app startup or scheduled reconciliation discovers the persisted
    eligible outbox item and requests execution without requiring the user to re-enter
    the reply.
  verdict: approved
  evidence: []
  comment: null
- id: ac4
  text: If WorkManager starts the same outbox item more than once or two workers race,
    exactly one worker obtains the transactional execution claim and at most one reply
    POST is attempted.
  verdict: approved
  evidence: []
  comment: null
- id: ac5
  text: An action from an older notification generation/version never produces a POST;
    the receiver records no new executable action for it and cancels the stale visible
    notification/action when present.
  verdict: approved
  evidence: []
  comment: null
- id: ac6
  text: For the current generation, version validation, action-state transition, execution
    claim, clearing/resolution, and publication eligibility are enforced by Room transactions
    such that no test interleaving can leave two claims or publish an actionable state
    from an obsolete generation.
  verdict: approved
  evidence: []
  comment: null
- id: ac7
  text: After a confirmed successful POST, the outbox action is terminal, the corresponding
    visible notification is canceled or rendered non-actionable, and delayed completion
    from an older worker or renderer cannot recreate an actionable notification.
  verdict: approved
  evidence: []
  comment: null
- id: ac8
  text: If a POST has an uncertain outcome, including a connection loss or timeout
    after transmission may have begun, the item moves to a distinct terminal uncertain
    state, WorkManager is instructed not to retry it automatically, and subsequent
    reconciliation does not issue another POST.
  verdict: approved
  evidence: []
  comment: null
- id: ac9
  text: If a POST fails in a way proven to occur before transmission, behavior follows
    the explicitly implemented non-ambiguous failure policy without ever converting
    an uncertain outcome into retryable work; tests distinguish pre-transmission failure
    from uncertain transmission.
  verdict: approved
  evidence: []
  comment: null
- id: ac10
  text: For replies that permit decision free text, text accepted within the existing
    bound is retrieved from Room byte-for-byte/code-point-for-code-point equivalent
    to the accepted input and is used unchanged in the POST; for decisions that forbid
    free text, submitted free text is rejected or omitted according to the existing
    policy.
  verdict: approved
  evidence: []
  comment: null
- id: ac11
  text: Payloads at the existing maximum accepted reply bound persist and execute
    successfully, while payloads beyond that bound are rejected before becoming executable;
    persistence never silently truncates or regenerates reply text.
  verdict: approved
  evidence: []
  comment: null
- id: ac12
  text: The persisted record retains all context needed to execute and render the
    reply after process death, and a worker can complete from Room state without depending
    on transient Intent extras, in-memory objects, or reconstructing context from
    the currently displayed notification.
  verdict: approved
  evidence: []
  comment: null
- id: ac13
  text: A render acknowledgement is accepted only for the matching current generation
    and published state; an acknowledgement from an older generation cannot clear,
    resolve, or republish the current action.
  verdict: approved
  evidence: []
  comment: null
- id: ac14
  text: Upgrading an existing installation from the legacy database schema to the
    new Room schema succeeds without destructive migration and preserves legacy pending
    actions only when their payload, context, and current generation can be represented
    and validated safely.
  verdict: approved
  evidence: []
  comment: null
- id: ac15
  text: During migration, legacy terminal or resolved actions remain terminal and
    cannot become claimable or cause a notification to be republished.
  verdict: approved
  evidence: []
  comment: null
- id: ac16
  text: During migration, a legacy action that lacks sufficient payload, context,
    or generation evidence to execute safely is marked non-executable/terminal and
    any corresponding visible action is canceled rather than guessed, posted, or silently
    promoted.
  verdict: approved
  evidence: []
  comment: null
- id: ac17
  text: A fresh installation and an upgraded installation produce the same new-schema
    behavior for newly created replies, while unsupported pre-migration schema versions
    fail according to the app's existing documented compatibility boundary rather
    than being silently destructively reset.
  verdict: approved
  evidence: []
  comment: null
- id: ac18
  text: Automated tests cover receiver-to-Room durability, enqueue recovery, duplicate
    delivery, concurrent claims, stale generation cancellation, success non-resurrection,
    uncertain POST terminal handling, exact/bounded text preservation, render acknowledgement,
    and every supported legacy migration path.
  verdict: approved
  evidence: []
  comment: null
- id: ac19
  text: No reply payload or full decision context is newly emitted to application
    logs, WorkManager diagnostic data, notification identifiers, or error messages
    as part of the outbox redesign.
  verdict: approved
  evidence: []
  comment: null
- id: ac20
  text: 'The implementation is confined to Ground Control Android and references parent
    task reply-notification-lifecycle and PR #76, with ba0b09d2 used as the frozen
    redesign baseline.'
  verdict: approved
  evidence: []
  comment: null
open_questions: []
non_goals:
- Adding server-side idempotency or changing the reply POST API.
- Automatically retrying a POST after an uncertain transport outcome.
- Changing the product policy for whether a decision may include free text or changing
  existing reply length bounds.
- Expanding the work beyond Ground Control Android.
- Redesigning unrelated notification types, app-wide WorkManager usage, or unrelated
  Room entities.
- Guaranteeing execution of legacy actions whose generation, payload, or required
  context cannot be migrated safely.
risks:
- A Room migration defect could lose valid pending replies, incorrectly revive terminal
  legacy actions, or make an existing installation unable to open its database.
- Android process death between durable persistence and WorkManager enqueue can delay
  execution unless persisted eligible work is reconciled and re-enqueued.
- PendingIntents from old notification generations may remain invokable; incorrect
  version checks could execute stale actions.
- Incorrect transaction boundaries could allow multiple workers to claim one reply
  or allow stale publication to resurrect a resolved notification.
- Treating an ambiguous POST as terminal prevents an automatic retry even when the
  server did not receive it, but retrying could create a duplicate because the server
  has no idempotency support.
- Persisting full reply context may increase local storage and expose sensitive notification
  content unless existing database and logging protections are maintained.
- WorkManager may redeliver work or run concurrently, so code that performs network
  I/O without a successful durable claim could duplicate delivery.
task_slug: ground-control-reply-outbox
work_item_id: wi-20260821115642-381872bb
clarification_reason: null
prose_verdicts:
  approach:
    verdict: approved
    comment: null
  user_story:
    verdict: approved
    comment: null
  non_goals:
    verdict: approved
    comment: null
  scope_risk:
    verdict: approved
    comment: null
  risks:
    verdict: approved
    comment: null
  problem:
    verdict: approved
    comment: null
---
## Problem

PR #76 at frozen head ba0b09d2 does not provide a single durable, transactional owner for the reply-notification lifecycle. A process death, duplicate/stale PendingIntent, concurrent worker, migration from legacy state, or ambiguous network result can otherwise lose a reply, execute it more than once, leave stale actions visible, or recreate a notification after it has been resolved. Ground Control Android needs a Room-backed outbox that preserves the exact bounded reply request and full decision context from user action through terminal delivery and render acknowledgement.

## User story

As a Ground Control Android user replying from a notification, I want my exact permitted reply to be durably captured and processed once with correct notification state, so that app restarts, concurrency, stale actions, and ambiguous network outcomes do not lose, duplicate, alter, or resurrect my reply.

## Approach

Redesign PR #76 from frozen head ba0b09d2 around a Room-owned reply outbox and notification lifecycle. Room is the source of truth for the bounded, exact reply payload; the policy governing decision free text; the full context required to execute and render the action; legacy migration state; notification generation/version; execution claim; action state; terminal outcome; and render acknowledgement. The notification receiver validates and durably commits the submitted action in Room before requesting WorkManager execution. That persistence and enqueue orchestration must not block the Android main thread; WorkManager is only a trigger and never the authoritative queue. Each notification action carries a generation/version. Room transactions serialize version validation, execution claim, state clearing, terminal resolution, and publication eligibility so only the current actionable generation can be claimed or rendered. Duplicate or stale intents are rejected from execution, and any still-visible stale notification actions are canceled. A worker atomically claims eligible work before issuing a POST and records the result transactionally. A confirmed success is terminal, clears actionability, cancels the applicable notification, and cannot later be overwritten or republished by an older worker or renderer. Because the server offers no idempotency key, any POST whose outcome is uncertain is also terminal and is not automatically retried; the UI/notification state communicates that no safe retry will be attempted. Decision free-text handling retains the existing product policy without normalizing, regenerating, or truncating accepted text beyond the established bound, and the exact accepted payload plus full execution/render context survive persistence. Add an explicit Room migration for installations using the legacy schema/state; preserve still-valid actionable data where it can be represented safely, map terminal legacy records to terminal records, and invalidate/cancel legacy actions that cannot be proven current or safely executable. Scope all implementation and tests to Ground Control Android and retain traceability to parent task reply-notification-lifecycle and PR #76.

## State and transaction model

Model the lifecycle with explicit persisted states rather than inferring it from WorkManager: actionable/pending, claimed/executing, succeeded, terminal-uncertain, and any required non-executable migration or acknowledged/render states. Persist a monotonically comparable notification generation/version and claim identity. All compare-and-set transitions must include the record identity, expected generation, and expected prior state. Network I/O occurs outside the Room transaction, but only after a successful claim; completion is committed only if the same claim and generation still own the transition. Publication reads a transactionally derived snapshot and must revalidate before rendering so stale snapshots cannot publish.

## Recovery and scheduling

Treat WorkManager as an at-least-once execution trigger. After every durable insertion, request unique work off the main thread. Also reconcile eligible unclaimed Room records on supported lifecycle entry points so a crash between commit and enqueue cannot strand work. Reconciliation must not reset claimed or terminal records blindly; lease/claim recovery, if needed, must use an explicit safe rule and must never retry a record whose POST outcome may be uncertain.

## Migration and backward compatibility

Provide versioned, non-destructive Room migrations for every database version supported by the current Ground Control Android upgrade policy. Migration must deterministically map legacy pending, executing, completed, and notification state into the new model. Preserve a legacy action only when its exact bounded payload, policy, full required context, and current generation are available. Otherwise mark it non-executable and arrange cancellation of its legacy notification. Never synthesize missing reply text or context, and never map a completed/ambiguous legacy action back to pending.

## Testing strategy

Use Room migration tests with production schema exports, receiver instrumentation tests, deterministic fake WorkManager scheduling, and concurrency tests with barriers around claims and completions. Use a controllable HTTP fake that can report confirmed success, proven pre-transmission failure, and disconnect/timeout after possible transmission. Include process-death simulations between commit and enqueue, enqueue and claim, claim and POST, POST and completion commit, publication and render acknowledgement, plus delayed stale callbacks for each generation.

## Security and privacy

Store only context required for reply execution, lifecycle correctness, and rendering, under the app's existing local data protections and retention policy. Treat reply text and decision context as sensitive. Avoid placing the payload in WorkManager input data, unique-work names, notification IDs, analytics, or logs; workers should receive only an opaque database identifier and load authoritative content from Room.
