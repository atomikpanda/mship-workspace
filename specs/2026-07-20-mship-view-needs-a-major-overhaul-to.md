---
id: mship-view-needs-a-major-overhaul-to
title: mship view needs a major overhaul to bring it into parity with ground control.
  b
status: dispatched
created_at: '2026-07-20T21:05:56.570486Z'
updated_at: '2026-07-20T21:23:29.158509Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: '`mship view spec` resolves specs from the workspace-canonical store regardless
    of the current branch/worktree: a spec that exists only on main (not checked out
    in the current pane''s worktree) still renders.'
  verdict: approved
  evidence: []
  comment: null
- id: ac2
  text: '`mship view spec` can select a spec by WorkItem or by status (e.g. by workitem
    id, or status=needs_review) instead of newest-file mtime guessing; with no args
    it uses a deterministic, documented default.'
  verdict: approved
  evidence: []
  comment: null
- id: ac3
  text: '`mship view workitem <id>` renders a single-WorkItem cockpit: its spec (status
    + phase), acceptance criteria with their evidence, its tasks + worktrees, and
    its linked PRs + threads, all sourced from the canonical store.'
  verdict: approved
  evidence: []
  comment: null
- id: ac4
  text: '`mship view queue` lists cross-workspace attention items - specs in needs_review,
    blocked tasks, and PRs awaiting action - each selectable/navigable.'
  verdict: approved
  evidence: []
  comment: null
- id: ac5
  text: '`mship view status` groups tasks under their WorkItem and shows each task''s
    phase.'
  verdict: approved
  evidence: []
  comment: null
- id: ac6
  text: 'The list-style views (workitem, queue, spec picker) support master/detail
    keyboard navigation: j/k move the selection, enter drills into the selected entity,
    tab switches focus between list and detail, and / filters the list.'
  verdict: approved
  evidence: []
  comment: null
- id: ac7
  text: From queue/spec/workitem, the approve action moves the selected needs_review
    spec to approved and the view reflects the new status; the request-changes action
    prompts for a reason and moves the spec to draft - both routed through the same
    store path the serve uses.
  verdict: approved
  evidence: []
  comment: null
- id: ac8
  text: Navigation actions move between linked entities without leaving the view (WorkItem
    -> its spec -> its thread -> its PR), and open-in-browser / copy-ref actions operate
    on the selected entity.
  verdict: approved
  evidence: []
  comment: null
- id: ac9
  text: '`mship view journal` and `mship view diff` keep their current behavior but
    gain a WorkItem/phase-aware header.'
  verdict: approved
  evidence: []
  comment: null
open_questions: []
non_goals:
- Unifying the view commands into a single TUI app - they stay separate, one per zellij
  pane, on a shared foundation.
- Replicating the phone/mailbox chat or capture flow in the terminal - the operator
  talks to the agent in an adjacent pane.
- Write actions beyond the curated safe set - no building, dispatch, phase-advance,
  finish, or commit from the views.
- Expanding the experimental web view port (core/view/web_port) - out of scope for
  this overhaul.
- Multi-user / real-time collaboration features.
risks:
- Master/detail plus an action bar across six views is a meaningful Textual build;
  scope can creep. Mitigate by shipping the shared foundation + canonical data layer
  first and migrating views incrementally (each pane is independently shippable).
- Inline spec approve / request-changes writes mship state and could race the running
  agent or serve. Mitigate by routing through the same store path/locks the serve
  uses, keeping the action set tiny, and confirming the state-changing ones.
- Canonical spec resolution must handle the several legacy locations (docs/superpowers/specs,
  .mothership/tasks/<slug>/SPEC.md, workspace specs/) without regressing existing
  `mship view spec` usage.
- Terminal capability variance (color, key handling, resize) across tmux/zellij panes
  could affect the richer TUI; keep a graceful degrade path.
task_slug: mship-view-needs-a-major-overhaul-to
work_item_id: wi-20260720212329-1c123e55
clarification_reason: null
prose_verdicts: {}
---
## Problem

mship view's read-only terminal panes predate WorkItem and have fallen behind Ground Control. Three concrete gaps: (1) specs live in the workspace-canonical store, but the view commands resolve relative to the current branch/worktree and fall back to newest-file guessing, so a spec that landed on main or only in the workspace repo is hard or impossible to `mship view spec` from a task pane; (2) there is no WorkItem-centric view even though the WorkItem is now the center of gravity (its spec, phase, tasks, evidence, PRs and threads are scattered across separate commands); (3) there is no cross-workspace attention/triage view. On top of that the UI is single-scroll static text, far from the lazygit / Claude-Code usability the operator wants. Because operators run each view in its own zellij pane, the fix must keep the commands separate, not unify them.

## User story

As an operator running mship in zellij panes with agents in adjacent panes, I want WorkItem-aware, canonically-resolved view commands with a lazygit-style master/detail feel and a few safe inline actions, so that I can see and triage all my work (WorkItems, specs, the attention queue) from the terminal regardless of which branch a pane is on, and act (approve a spec, jump to its PR) only where doing it directly beats telling the agent.

## Approach

Keep the separate per-pane commands (no unified app). Build one shared Textual foundation by extending the existing ViewApp base with a master/detail container, a focus model, and a common footer action bar so every view looks and behaves consistently. Make ALL data resolve from the workspace-canonical store rather than branch/worktree-relative paths, so the current pane's branch never affects what is visible. Lineup becomes six views: (a) enhance the existing status / journal / diff / spec to be WorkItem-aware and, for spec, fix access so it selects by WorkItem or status and resolves canonically instead of newest-file guessing; (b) add two NEW views - `workitem` (a cockpit for one WorkItem: its spec status+phase, acceptance criteria with evidence, its tasks + worktrees, and linked PRs + threads) and `queue` (a cross-workspace attention list: specs in needs_review, blocked tasks, and PRs awaiting action). List-style views (workitem, queue, spec picker) get lazygit-style master/detail: a navigable list beside a detail pane, j/k to move, enter to drill, tab to switch focus, / to filter. Stream views (journal, diff, status) stay live-updating but gain richer WorkItem/phase-aware headers and grouping. The curated action set is deliberately tiny and included only where doing it directly via mship beats telling the agent in the next pane: approve (a) or request-changes (R, prompts a short reason) a spec from queue/spec/workitem; navigate/drill between linked entities (WorkItem -> spec -> thread -> PR); open in browser (o) and copy id/branch/PR-url (y). No building, dispatch, phase-advance, finish, or commit from the views - that stays with the agent. Inline writes (approve / request-changes) go through the same spec-store path the serve uses so they do not race the running agent/serve.

## Architecture

Three layers. (1) A shared TUI foundation: extend the existing src/mship/cli/view/_base.py ViewApp with a master/detail layout (list widget + detail pane), a focus model (tab between panes), a filter box (/), and a common footer action bar that renders the available keys per view. (2) A canonical data layer built from the existing core/view modules (workitem_index, spec_discovery, task_index, thread_links, entity_links), extended so every lookup reads the workspace-canonical store rather than a branch/worktree-relative path; spec_discovery gains WorkItem- and status-based selection and stops relying on newest-file mtime. (3) Per-view command modules under src/mship/cli/view/ (status, journal, diff, spec today; add workitem and queue), each a thin subclass wiring the data layer into the foundation. A small action layer performs the curated writes (approve / request-changes) by calling the same spec-store functions the serve endpoints call, so terminal and phone go through one code path and cannot diverge or race.

## Interaction Model

lazygit-inspired. List-style views show a selectable list on the left and a live detail pane on the right. Keys: j/k or arrows move selection, enter drills into the highlighted entity (e.g. from queue into that spec, or workitem into a task), tab cycles focus between list and detail (and between sections of the cockpit), / opens an incremental filter, q quits, r forces refresh. Curated action keys, shown in the footer bar and only where meaningful: a = approve the selected spec, R = request-changes (prompts a one-line reason), o = open the selected PR/thread in a browser, y = copy the selected entity's id / branch / PR url. Stream views (journal, diff, status) keep the current watch/auto-follow behavior and add the richer header; they expose no state-writing actions.

## Testing

Data-assembly logic is written as pure functions independent of the TUI and unit-tested: canonical spec resolution (a spec present only on main resolves; selection by workitem and by status returns the right file; the no-arg default is deterministic), the workitem cockpit assembly (spec+ACs+evidence+tasks+PRs+threads for a given WorkItem), and the queue aggregation (needs_review specs + blocked tasks + PRs-awaiting-action). The action layer is tested against the store: approve moves needs_review -> approved and request-changes -> draft with the reason recorded, using the same functions the serve calls. TUI navigation and action keybindings are exercised with Textual's pilot test harness where feasible (select-move-drill, and pressing the action keys triggers the store calls). No emulator or live serve is required.

## Rollout

Incremental, exploiting the per-pane separation: (1) shared foundation (master/detail base + action bar) and the canonical data layer; (2) migrate spec (canonical + WorkItem/status selection) and status (WorkItem grouping); (3) add the workitem cockpit; (4) add the queue view; (5) layer the curated actions (approve / request-changes / open / copy) onto queue, spec, and workitem. Each step leaves every command working, so it can ship as its own PR.
