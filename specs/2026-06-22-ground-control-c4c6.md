---
id: ground-control-c4c6
title: "Ground Control C4\u2013C6: Spec detail screen + review/act loop (verdicts,\
  \ Q&A, approve, request-changes, dispatch)"
status: implemented
created_at: '2026-06-22T16:56:53.723393Z'
updated_at: '2026-06-22T19:06:58.851446Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: Tapping a spec row in the inbox opens the detail screen for that workspace
    + spec (connectionId + specId); the system back returns to the inbox.
  verdict: unreviewed
- id: ac2
  text: "The detail screen loads via a single GET /specs/{id} and renders the COMPLETE\
    \ body markdown \u2014 all sections including custom ones beyond Problem/User\
    \ story/Approach \u2014 plus non-goals, risks, affected repos, status, and task\
    \ binding."
  verdict: unreviewed
- id: ac3
  text: Acceptance criteria render with their verdicts; the per-row toggle sets approved
    (check) or flagged (flag) via POST /specs/{id}/verdict, and tapping the active
    verdict clears it to unreviewed; the row and the client-side summary chip reflect
    the returned review payload.
  verdict: unreviewed
- id: ac4
  text: Open questions render with their answers; an unanswered question can be answered
    via POST /specs/{id}/questions/{qid}/answer and a new question asked via POST
    /specs/{id}/questions; the summary updates from the returned review.
  verdict: unreviewed
- id: ac5
  text: 'The bottom action bar is status-aware: needs_review shows Request changes
    + Approve (with an Approve-anyway overflow); approved shows Request changes +
    Dispatch; dispatched / needs_clarification / drafting / captured / implemented
    / archived show a read-only banner and no actions.'
  verdict: unreviewed
- id: ac6
  text: Gated Approve (POST approve, bypass_gate=false) succeeds and transitions the
    spec to approved when all criteria are approved and all questions answered; when
    blocked it returns 409 whose detail is parsed into a blocker sheet listing the
    blocking criteria/questions and offering Approve anyway (bypass_gate=true), which
    succeeds.
  verdict: unreviewed
- id: ac7
  text: Request changes requires a reason and transitions the spec to needs_clarification
    via POST request-changes; Dispatch shows a confirmation, calls POST dispatch,
    and on success shows the result (task slug, whether it spawned, a peek at the
    handoff) with status now dispatched; a 409 auto-spawn-unavailable is surfaced
    as a clear actionable message.
  verdict: unreviewed
- id: ac8
  text: 'Error handling: 401 shows an auth error linking to Settings; 404 shows ''spec
    no longer available'' and returns to the inbox; a network failure shows a retry;
    a stale 409 invalid-transition shows a ''spec changed'' message and auto-refetches
    so the action bar re-derives; pull-to-refresh re-runs the load to resync.'
  verdict: unreviewed
- id: ac9
  text: availableActions(status) is a pure function with an exhaustive unit test over
    all 8 statuses; SpecApi calls (method/path/auth header/request body) and error
    mapping (401 to AuthException, 404 to NotFoundException, 409 to ApiConflictException
    with detail preserved) are covered with Ktor MockEngine; SpecDetailViewModel transitions
    for load / verdict / answer / ask / approve (gated + bypass) / request-changes
    / dispatch are covered.
  verdict: unreviewed
- id: ac10
  text: ./gradlew assembleDebug and ./gradlew testDebugUnitTest (run via mship test)
    are green.
  verdict: unreviewed
open_questions: []
non_goals:
- "Editing or drafting the spec body from the phone \u2014 that is the separate Capture\
  \ slice"
- "Notifications / push \u2014 its own later slice; this slice is pull / pull-to-refresh\
  \ only"
- "The needs_clarification -> needs_review reopen transition \u2014 no HTTP endpoint\
  \ exists for it (re-draft path), so such specs are read-only on the phone"
- "Capture / Decisions / Tasks screens \u2014 remain placeholders"
- iOS app
- Offline cache / sync queue
- "Compose UI / instrumentation / emulator-based tests \u2014 no emulator in the environment"
- "Marking a spec implemented \u2014 CLI-only, no HTTP endpoint"
- "Any mothership / mship serve changes \u2014 every endpoint already exists"
risks:
- "Adding a Compose-native markdown rendering library is the one new dependency; it\
  \ must render arbitrary author markdown (headings, lists, code, bold, links) resiliently\
  \ \u2014 a malformed or exotic body must not crash the screen"
- Dispatch from the phone triggers real work on the host (spawns task / worktrees
  and starts an agent), so it is gated behind an explicit confirmation dialog
- Concurrent terminal + phone edits can make the phone's view stale; mitigated by
  writes returning the authoritative review payload and by 409 invalid-transition
  triggering an automatic refetch
- Dispatch can fail with 409 'auto-spawn unavailable' when the server has no worktree
  manager; this must be surfaced as a clear, actionable message rather than a generic
  error
task_slug: ground-control-c4c6
work_item_id: wi-20260702110439-1c14a4e5
---
## Problem

The C1/C2 inbox lists and groups specs across workspaces, but tapping a row is a no-op — the Ground Control app is read-only and shallow. You cannot open a spec, read it, or act on it (approve / request clarification / dispatch). A cockpit you cannot steer from is not a daily tool. The mship serve HTTP API already exposes the entire review/act surface (GET /specs/{id}, GET /specs/{id}/review, POST verdict / questions / answer / approve / request-changes / dispatch), all tested on main, so this is pure Ground Control app work with zero mothership changes.

## User story

As a Mothership operator away from my desk, I want to tap a spec in Ground Control, read the entire spec, and approve / request changes / dispatch it from my phone, so that I can keep work moving without opening a terminal.

## Approach

Add a Spec Detail screen (ui/specdetail/SpecDetailScreen.kt + SpecDetailViewModel.kt, MVVM with StateFlow) reached by navigating specDetail/{connectionId}/{specId} from the inbox row tap (today a no-op). connectionId resolves the WorkspaceConnection (baseUrl + bearer token) via the existing ConnectionsRepository, since each spec belongs to one specific workspace. Layout is a single LazyColumn with a sticky top bar (back + title) and a status-aware sticky bottom action bar. The display source is the FULL record: a single GET /specs/{id} returns everything, and the complete body markdown is rendered verbatim (all sections, including custom ones beyond Problem/User story/Approach) exactly like `mship view spec` — deliberately NOT using the /review endpoint's context, which only extracts three prose sections and silently drops the rest. Acceptance criteria render with an interactive per-row verdict toggle and open questions with inline answer/ask affordances. Every write endpoint returns a fresh review payload that is treated as the source of truth (patch status + criteria + questions, recompute summary), making the flow non-optimistic and converging phone and terminal automatically. Approve is gated by default with a quick-approve (bypass_gate) escape hatch surfaced from the 409 blocker sheet. Dispatch is confirmed before firing because it spawns/binds a task on the host. The action bar and interactivity are driven by a pure availableActions(status) function. Verification is JVM unit tests only (Ktor MockEngine), matching the C1/C2 discipline; no emulator.

## Data layer & API contract

Following the existing data/MshipClient + SpecApi patterns. New DTOs: SpecRecord (id, title, status, created_at, updated_at, affected_repos[], acceptance_criteria[{id,text,verdict}], open_questions[{id,text,answer}], non_goals[], risks[], task_slug?, body), SpecReview (id, status, acceptance_criteria, open_questions, context{problem,user_story,approach,non_goals,risks,affected_repos}, summary{criteria_total,approved,flagged,unreviewed,open_questions_unanswered}), DispatchResult (spec, task_slug, spawned, handoff), and request bodies (VerdictBody{criterion_id,verdict}, AnswerBody{answer}, QuestionBody{text}, ApproveBody{bypass_gate}, ReasonBody{reason}). SpecApi gains the 8 calls: getSpec, getReview (consumed only as the write return shape), postVerdict, postAnswer, postQuestion, postApprove, postRequestChanges, postDispatch. A SpecDetailRepository takes a WorkspaceConnection + spec id and wraps these. Typed errors: keep AuthException (401); add ApiConflictException(detail) for 409 carrying the verbatim server detail (blockers / transition message) and NotFoundException for 404. DTOs decode with ignoreUnknownKeys so server additions never break the app.

## Screen layout & interactions

Single LazyColumn (Approach A): header (status badge, affected repos, task binding) + a client-side summary chip (e.g. '3/5 approved · 1 flagged · 1 unanswered Q'); the full rendered body markdown; non-goals and risks as bullet lists; acceptance criteria each with a two-button verdict toggle (check = approved, flag = flagged, tap-active = clears to unreviewed) with a per-row spinner while that one call is in flight; open questions where an unanswered question shows an inline text field + Send, an answered question shows the answer with an edit affordance, and an 'Ask a question' control appends a new open question (with a hint that a new unanswered question re-blocks gated approve). The sticky bottom action bar is status-aware per the matrix. Approve blocked -> a sheet lists the parsed blockers and offers Approve anyway. Request changes opens a required reason field. Dispatch opens a confirmation dialog, then a result sheet (task slug, spawned, handoff peek).

## State, data flow & concurrency

SpecDetailViewModel exposes StateFlow<SpecDetailUiState> = Loading | Error(kind: NETWORK|AUTH|NOT_FOUND, message, retry) | Content(detail, inFlight: ActionRef?, banner). Load is a single GET /specs/{id} -> SpecDetail; the summary chip is computed client-side from criteria/questions. Writes (verdict/answer/ask/approve/request-changes) return a review payload -> patch status + criteria + questions in place and recompute the summary; the body persists from the initial load because these writes never change it. Dispatch returns DispatchResult -> update status from its spec and surface the result sheet. The flow is non-optimistic: the returned payload is the source of truth, so phone and terminal converge. inFlight marks which action is running (e.g. Verdict("ac2")) so only that row spins and the action bar disables — no full-screen block. Pull-to-refresh re-runs the load. A stale 409 invalid-transition auto-refetches so the action bar re-derives from the true current status.
