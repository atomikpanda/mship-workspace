---
id: workitem-focused-zellij-cockpit
title: 'WorkItem-focused zellij cockpit: mship focus + dynamic per-item tabs with
  phase sub-tabs'
status: needs_review
created_at: '2026-07-21T11:11:17.171167Z'
updated_at: '2026-07-21T11:12:19.604489Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: '`mship view item <id>` renders the single-WorkItem cockpit (renamed from
    `mship view workitem`); the old name is either aliased or cleanly removed with
    an error pointing to the new name. `mship view items` is registered and appears
    in `mship view --help`.'
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac2
  text: '`mship view items` lists the workspace''s WorkItems (id, title, derived phase,
    attention) as a navigable master/detail picker, reusing the shipped foundation.'
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac3
  text: '`mship focus <item-id>` switches to that item''s zellij tab when it already
    exists (go-to-tab-name), else creates it (new-tab with a per-WorkItem layout,
    named deterministically for the item, cwd = the item''s task worktree). Outside
    a zellij session it no-ops with a clear message instead of crashing.'
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac4
  text: "The per-WorkItem tab is chat-first: a primary agent/chat pane running a configurable\
    \ command (default: a shell in the worktree), plus explicit phase sub-tabs Plan/Dev/Review/Run,\
    \ plus an editor pane \u2014 all cd'd to the worktree."
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac5
  text: 'Each phase sub-tab shows the ambient views for that phase using the shipped
    view commands with the item baked in: Plan -> the item''s spec (+ open questions);
    Dev -> diff + journal (+ agent heartbeat); Review -> the PR/checks + diff; Run
    -> logs.'
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac6
  text: '`mship layout` gains the per-WorkItem tab template and wires an overview
    tab (`mship view queue` + `mship view items`) as the launchpad; picking an item
    in the overview focuses its tab (composes with `mship focus`).'
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac7
  text: A focused item's tab is closed when the item reaches `done` (or via an explicit
    close), so tabs do not accumulate across completed WorkItems.
  verdict: unreviewed
  evidence: []
  comment: null
open_questions: []
non_goals:
- "Auto-shaping the WorkItem tab to its current phase \u2014 explicit phase sub-tabs\
  \ for v1; auto is a documented later exploration."
- "A first-class live `mship view chat` / thread TUI \u2014 v1's chat pane is the\
  \ operator's own agent process in a shell on the worktree; a native terminal chat\
  \ view is future work."
- "Hardcoding a specific agent (claude etc.) \u2014 the chat/agent pane command is\
  \ configurable."
- "Replacing the developer's editor or tools \u2014 mship is the ambient awareness\
  \ + orchestration layer around them, not the primary editing surface."
- "Cross-workspace / multi-workspace tabs \u2014 this is per-workspace, like the rest\
  \ of mship."
risks:
- zellij runtime actions (new-tab --layout-string, go-to-tab-name, close-tab) may
  differ across zellij versions or be unavailable when not inside a session; the commands
  must degrade gracefully (clear message) rather than crash.
- "Rendering a correct per-WorkItem KDL (quoting, cwd, pane command tokens) \u2014\
  \ reuse mship layout's existing KDL rendering/quoting rather than hand-rolling."
- Tab-name collisions or stale tabs if an item is renamed/removed; derive the tab
  name deterministically from the item id and reconcile on focus.
- Renaming a shipped command (`mship view workitem`) is a CLI break; keep a deprecation
  alias or emit a clear error pointing to `mship view item`.
task_slug: null
work_item_id: null
clarification_reason: null
prose_verdicts: {}
---
## Problem

The mship view commands shipped in the view overhaul are each parameterized per-command (--item/--task/--workitem), and `mship layout` is a static phase-tab KDL (Plan/Dev/Review/Run) launched once. There is no shared way to switch which WorkItem the whole layout is focused on, so pivoting to another WorkItem means re-arging every pane — and MSHIP_TASK is per-shell, so it doesn't cross zellij panes. The current top-level phase-tab organization also doesn't match how people actually work: agentic engineering is WorkItem-centric and primarily driven by talking to the agent, with the editor as a secondary tool. Result: the views don't compose into a usable, switchable cockpit.

## User story

As an operator doing agentic engineering in zellij, I want to focus a WorkItem and get a dedicated tab that is chat-first (the agent conversation) with explicit phase sub-tabs of ambient mship views (spec / diff / journal / PR) and my editor, and to switch between WorkItems by switching tabs, so that I can direct agents across several WorkItems without re-arging panes or losing per-WorkItem context.

## Approach

Add `mship focus <item-id>`: if a zellij tab named for that item already exists, run `zellij action go-to-tab-name`; otherwise render a per-WorkItem KDL and run `zellij action new-tab --layout-string <kdl> --name <item>`, with the tab cd'd to the item's task worktree. The per-WorkItem tab is CHAT-FIRST: a primary agent/chat pane running a configurable command (default: a shell in the worktree where the operator runs their agent — mship does not hardcode a specific agent like claude), plus explicit phase sub-tabs Plan/Dev/Review/Run whose panes are the shipped view commands with the item baked in (Plan: the item's spec + open questions; Dev: diff + journal + agent heartbeat; Review: the PR/checks + diff; Run: logs), plus an editor pane for occasional one-off edits. Rename the shipped `mship view workitem <id>` to `mship view item <id>` and add `mship view items` (the WorkItems picker/list on the master/detail foundation) so the view commands match the existing `mship item` command group. The global orchestration layer stays as the already-shipped `mship view queue` + the new `mship view items` picker, used as the overview/launchpad tab: selecting an item there fires `mship focus <id>`. Tab lifecycle: a focused item's tab is opened on focus and closed when the item reaches `done` (or via an explicit close) so tabs don't pile up. `mship layout` gains the per-WorkItem tab template and wires the overview tab. Start with explicit phase sub-tabs; auto-shaping the tab to the current phase is a later exploration.

## Architecture

`mship focus` is a thin driver over zellij runtime actions: it resolves the item, derives a deterministic tab name, and chooses go-to-tab-name (exists) vs new-tab --layout-string (create), passing a per-WorkItem KDL and the worktree cwd. The KDL is produced by extending mship layout's existing renderer (cli/layout.py) with a per-item template; its panes are the shipped `mship view item/spec/diff/journal/queue` commands with `--item`/`--task` baked in, an editor pane, and the configurable chat/agent pane. Phase sub-tabs are static per-phase pane sets in the template. The overview tab is `mship view queue` + `mship view items`. Pure pieces (name derivation, KDL rendering, go-vs-create decision, cwd resolution) are separated from the actual zellij subprocess call so they are unit-testable without a live zellij.

## Interaction model

The overview tab (queue + items picker) is the launchpad and cross-WorkItem awareness. You pick an item there (or run `mship focus <id>`) -> its dedicated tab opens or you jump to it. Inside the tab, the agent conversation is the primary pane (you direct the agent), you flip the explicit phase sub-tabs (Plan/Dev/Review/Run) to change the ambient context, and the editor pane is there for one-off edits/config/review. Switching WorkItems is switching zellij tabs (native muscle-memory) or via `mship focus` / the overview. Phase still appears globally as the queue's triage buckets (needs-review = review, blocked = dev), and per-WorkItem as the sub-tab you are on.

## Testing

The `mship focus` driver is tested by mocking the zellij action invocation and asserting: the derived tab name, the go-to-vs-create decision (given a fake list of existing tab names), the resolved cwd (the item's task worktree), and the emitted per-WorkItem KDL (panes/commands/phase sub-tabs). The per-WorkItem KDL renderer is unit-tested like the existing layout renderer (quoting, pane commands). The `mship view workitem`->`mship view item` rename + `mship view items` picker are covered by the existing view test suites + the registration test (`queue`/`item`/`items` in `view --help`). Graceful-degrade-outside-zellij is asserted (no crash, clear message).

## Rollout

Independently shippable steps: (1) rename `mship view workitem` -> `mship view item` (+ deprecation alias) and add the `mship view items` picker; (2) the per-WorkItem KDL template + `mship focus` (go-to-or-create via zellij actions, worktree cwd, graceful degrade); (3) the chat-first + explicit phase sub-tabs wiring in the template; (4) the overview tab + tab lifecycle (close on done). Each leaves the CLI working.
