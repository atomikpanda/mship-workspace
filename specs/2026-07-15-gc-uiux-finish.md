---
id: gc-uiux-finish
title: 'GC UI/UX finish: Home leads with needs-you queue + spec-detail readiness &
  action hierarchy'
status: approved
created_at: '2026-07-15T19:02:23.548765Z'
updated_at: '2026-07-15T19:13:27.698708Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: "Home renders the 'Needs you \xB7 N' section with a visible count as the first\
    \ content block, above the workspace rail and threads card."
  verdict: approved
  evidence: []
  comment: null
- id: ac2
  text: The 'Needs you' section exposes a control that navigates to the Queue tab
    when tapped, and its label reflects the count (e.g. 'Review 3 in Queue').
  verdict: approved
  evidence: []
  comment: null
- id: ac3
  text: When there are zero attention items, the 'Needs you' section shows a caught-up/empty
    state and offers no Queue-review action.
  verdict: approved
  evidence: []
  comment: null
- id: ac4
  text: The workspace rail and threads card still render, positioned below the 'Needs
    you' section.
  verdict: approved
  evidence: []
  comment: null
- id: ac5
  text: The spec-detail screen shows the acceptance-criteria readiness summary as
    colored counter chips (approved / flagged / unanswered) near the top, using the
    semantic colors.
  verdict: approved
  evidence: []
  comment: null
- id: ac6
  text: On spec-detail, Approve is a single filled primary action gated by a light
    confirmation step before it commits.
  verdict: approved
  evidence: []
  comment: null
- id: ac7
  text: On spec-detail, 'Plan implementation' renders as a secondary/tonal action,
    visually subordinate to Approve.
  verdict: approved
  evidence: []
  comment: null
- id: ac8
  text: On spec-detail, the bare caret is replaced by a labeled overflow affordance
    that exposes the secondary actions including 'Approve anyway'.
  verdict: approved
  evidence: []
  comment: null
open_questions: []
non_goals:
- "No mship serve or backend changes \u2014 Ground-Control-client-only."
- No changes to the Queue or the verdict-color/accessibility surfaces already shipped
  (Wins 1, 2, 4).
- "No new navigation graph beyond the Home\u2192Queue jump."
- No redesign of the Messages surface (its collapsible-context-chrome note from the
  review is out of scope here).
risks:
- File/line references from the UI/UX review are against the checkout at review time;
  the implementer must confirm current line numbers before editing.
- "Reordering Home content blocks could disturb existing scroll/state expectations\
  \ \u2014 verify the rail and threads card still render and behave, just repositioned."
- Adding a confirm gate to Approve must not regress the whole-spec confirmation behavior
  already shipped in the Queue spec; keep the confirm light so it does not become
  friction-heavy.
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
---
## Problem

Ground Control's Home and Spec-detail screens bury the two things that matter most to an operator triaging from a phone. On Home, the 'Needs you' attention items render at the very bottom, below the workspace rail, error banners, browse-all, and the threads card, with no header or count, so what is actually blocked on the operator is hidden under chrome they must scroll past. On Spec-detail, action friction is inverted (Approve is a one-tap with no confirm while the lower-stakes 'Plan implementation' has a confirm dialog), the acceptance-criteria readiness summary is tiny buried text, and 'Approve anyway' hides behind a bare caret. These are the last two surfaces of the Ground Control UI/UX review pass (Wins 1,2,4 already shipped).

## User story

As an operator triaging work from my phone, I want Home to lead with what needs me and the spec-detail screen to make a spec's readiness and its primary action obvious, so that I can see and act on blocked work without hunting through buried UI.

## Approach

Two Ground-Control-only (Kotlin/Compose) changes, no mship serve work. Home (HomeScreen.kt): pin a 'Needs you · N' section as the first content block with a visible count and a one-tap 'Review N in Queue →' control that navigates to the Queue tab; demote the workspace rail and threads card below it; when N is zero show a calm caught-up state offering no Queue action. Spec-detail (SpecDetailScreen.kt): promote the readiness summary to a row of colored counter chips (approved / flagged / unanswered) at the top using the existing SemanticColors (LocalSemanticColors.current.approval etc.); make Approve the single filled primary action gated by a light confirmation (a short confirm, not a full typed-reason dialog); demote 'Plan implementation' to a secondary/tonal button; replace the bare caret with a labeled overflow affordance that exposes secondary actions including 'Approve anyway'. Both features are independently testable and could split into two tasks, but are intended as one spec / likely one PR.

## Testing

JVM unit tests only (no emulator). Use JUnit4 with ViewModel/Compose-logic-level assertions where the logic lives: the count and label derivation for 'Needs you · N', the zero-items empty-state branch, the readiness-chip counts (approved/flagged/unanswered), and the confirm-gate state for Approve. Follow existing Ground Control test patterns (Ktor MockEngine for data-layer, ViewModel tests for state). Build and verify with 'source ~/toolchains/android-env.sh' then './gradlew --offline compileDebugKotlin testDebugUnitTest'.
