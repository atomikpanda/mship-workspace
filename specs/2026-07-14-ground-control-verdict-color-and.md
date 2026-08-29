---
id: ground-control-verdict-color-and
title: Ground Control verdict color and accessibility pass
status: approved
created_at: '2026-07-14T22:43:55.191753Z'
updated_at: '2026-07-15T14:01:54.864898Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: Approve toggles render in the semantic approval green (not primary/cyan) in
    the Queue criteria and prose cards and in the Spec-detail criterion rows; the
    flag toggle stays error-red.
  verdict: approved
  evidence: []
  comment: null
- id: ac2
  text: "The muted secondary text color (onSurfaceVariant) meets WCAG AA contrast\
    \ (>=4.5:1) against the dark surface it renders on \u2014 demonstrated by the\
    \ computed contrast ratio."
  verdict: approved
  evidence: []
  comment: null
- id: ac3
  text: The thread list shows relative timestamps (e.g. '3m ago') via the existing
    relativeTimeAgo helper instead of raw ISO strings, with a safe fallback for missing/unparseable
    values.
  verdict: approved
  evidence: []
  comment: null
- id: ac4
  text: 'Home attention rows expose a non-color tier signal: a descriptive contentDescription
    on the tier icon AND a visible text tier label, so the tier is conveyed without
    relying on color.'
  verdict: approved
  evidence: []
  comment: null
- id: ac5
  text: The recommended decision option shows a visible 'Recommended' tag (text/icon),
    not color alone.
  verdict: approved
  evidence: []
  comment: null
open_questions: []
non_goals:
- "A theme redesign or removing the `primary`=question-cyan overloading app-wide (FAB,\
  \ human bubble, links) \u2014 that is a larger, separate effort; this only fixes\
  \ the approve affordances to green."
- "Dynamic-type / text-scaling truncation fixes (many maxLines=1) \u2014 separate\
  \ accessibility pass."
- "Any layout restructuring or new screens \u2014 this is color, text-format, and\
  \ content-description only."
- Any serve or API change.
risks:
- "Changing the muted color ripples across many surfaces (Home supporting lines, Queue\
  \ meta, Messages activity strip, read-state, timestamps) \u2014 verify it reads\
  \ well everywhere and isn't too bright/washed after the bump."
- The semantic approval green must have adequate contrast on the card container surfaces
  too, not just against the screen background.
- relativeTimeAgo must handle the thread-list's timestamp field + missing/blank values
  gracefully (fall back rather than crash).
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

A cluster of small but pervasive inconsistency + accessibility issues undercut Ground Control's core review idiom. 'Approve' is tinted the question-cyan (the app's `primary` is set to the question accent), so an approve/Check toggle glows CYAN in the Queue and the Spec detail — the same hue used for questions, links, and the recommended decision option — yet the SAME approve idiom is semantic GREEN on Home. Cyan doesn't read as 'go/approved', and the verdict idiom that is supposed to be identical across Home/Queue/Spec-detail visibly diverges. Separately: the muted secondary text color (onSurfaceVariant) computes to roughly 3.8:1 on the dark surface — below the WCAG AA 4.5:1 minimum — and it carries a lot of real content (card meta, supporting lines, read-state, activity strip, timestamps). Thread-list rows render a raw ISO timestamp string instead of a human relative time. And several state signals are conveyed by color alone (Home tier icons have null content descriptions; the recommended decision option is distinguished only by its cyan fill), which fails for color-blind and screen-reader users.

## User story

As an operator, I want 'approve' to read as green everywhere, muted text to be legible, timestamps to be human, and state to never be signaled by color alone — so the review idiom is consistent across surfaces and the app is readable and accessible at a glance.

## Approach

GC-only, low-risk polish batch. (1) Verdict color: tint approve affordances with the semantic approval green (LocalSemanticColors.current.approval) instead of colorScheme.primary in the Queue VerdictToggles and the Spec-detail CriterionRow; flag stays error-red (already correct). This makes the verdict idiom match Home. (2) Contrast: adjust the dark palette so onSurfaceVariant clears WCAG AA (>=4.5:1) against the dark surface — either lighten the muted tone or darken the surface — fixing legibility across every surface that uses muted text at once. (3) Timestamps: the thread list uses the existing relativeTimeAgo helper ('3m ago') instead of the raw updatedAt ISO string. (4) Non-color state signals: give the Home attention-row tier icons a descriptive contentDescription (Blocker/Question/Approval) AND a visible text tier label so the tier survives color-blindness + TalkBack; add a visible 'Recommended' tag to the recommended decision option so it isn't distinguished by color alone. Does not touch layouts or the broader primary=cyan overloading (a larger, separate change).

## Testing

JVM unit tests only. Cover the pure logic: relativeTimeAgo formats known deltas correctly and falls back safely on blank/unparseable input; the tier→(label, contentDescription) mapping returns the right non-color signal per tier. The color changes (approval green, muted-contrast bump) are verified by a contrast-ratio assertion where feasible (compute ratio of the two palette values against AA) plus compilation; the 'Recommended' tag by composition. Follow existing GC unit-test patterns.
