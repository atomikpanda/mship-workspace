---
id: unattended-runner
title: 'Unattended runner: cloud-agent-agnostic autonomous WorkItem execution (v1:
  autonomous-to-PR-or-bail)'
status: implemented
created_at: '2026-07-08T10:51:50.541481Z'
updated_at: '2026-07-08T17:12:25.943929Z'
affected_repos:
- mothership
- ground-control
acceptance_criteria:
- id: ac1
  text: A WorkItem carries an opt-in `unattended` flag, settable from the CLI; only
    flagged items are eligible for unattended runs.
  verdict: approved
- id: ac2
  text: "`mship run-next` selects the next eligible item \u2014 spec approved AND\
    \ phase ready AND unattended=true AND not currently claimed \u2014 and emits its\
    \ dispatch prompt; exits cleanly (no-op) when nothing is eligible."
  verdict: approved
- id: ac3
  text: Selecting an item atomically claims it (git-backed run-claim, generalizing
    the inbox-listener lease) so two concurrent runs never pick the same item; a stale/dead
    claim is reclaimable.
  verdict: approved
- id: ac4
  text: "The dispatch prompt is resumable \u2014 for an item with prior work it folds\
    \ in the existing branch + journal so a fresh run continues rather than restarts."
  verdict: approved
- id: ac5
  text: "A run executes plan\u2192dev\u2192test\u2192finish via the host agent and\
    \ opens a PR; it never merges, and finish still enforces the existing gates (approved\
    \ spec, audit, passing tests)."
  verdict: approved
- id: ac6
  text: "On an unresolvable fork or unfixable test failure the run BAILS: marks the\
    \ item blocked with a recorded reason, pushes its branch, releases the claim,\
    \ and exits \u2014 leaving the item for attended pickup (no live phone escalation\
    \ in v1)."
  verdict: approved
- id: ac7
  text: Run-shared state (item status, claim, run-log) is persisted to a git-backed
    store (a dedicated ref) via commit+push checkpoints, so ephemeral cloud runs share
    it without an always-on server.
  verdict: approved
- id: ac8
  text: "A reference host adapter (a Claude routine on cron) drives one tick \u2014\
    \ mship bootstrap \u2192 mship run-next \u2192 exit \u2014 with no coupling between\
    \ mship and the agent runtime."
  verdict: approved
- id: ac9
  text: "The `unattended` flag is also toggleable from Ground Control \u2014 a checkbox\
    \ on the WorkItem (cockpit/detail) that flips the same flag the CLI sets, so the\
    \ operator can opt items into unattended runs from the phone."
  verdict: approved
open_questions:
- id: q1
  text: Exact layout of the git-backed run-state ref (dedicated repo vs orphan branch
    in the workspace repo) and the commit/rebase-retry protocol for concurrent writers.
  answer: orphan branch in workspace repo seems right
- id: q2
  text: Beyond v1 one-at-a-time, how many parallel runs to allow and whether the claim
    TTL needs tuning per expected run duration.
  answer: we can figure this out later
- id: q3
  text: How a cloud routine authenticates to git + the state ref (GH_TOKEN passthrough
    already exists for bootstrap/finish; confirm it covers the state ref push).
  answer: it covers it
non_goals:
- "Live phone escalation during a run (the shared-mailbox / \"git = truth, serve =\
  \ stateless view\" option-1 step) \u2014 deferred; v1 bails on forks instead."
- "Full migration of mship's local state layer (StateManager/WorkItemStore/MessageStore)\
  \ to git-backed storage \u2014 v1 only git-backs the narrow run-shared subset."
- "Auto-merge \u2014 a human always reviews/merges the PR."
- Parallel/concurrent runs beyond one-at-a-time.
risks:
- "Git-backed concurrent writes (run vs run) can conflict; per-item files + claim\
  \ + rebase-retry mitigate but need care \u2014 this is the fiddly part."
- 'Resumable-dispatch fidelity: if the prompt doesn''t faithfully fold in prior branch/journal,
  a resumed run could redo or diverge from earlier work.'
- 'Cold-start cost: bootstrap clones every tick; for a frequent farm cadence this
  may be slow/expensive and want a warm cache later.'
task_slug: unattended-runner
work_item_id: wi-20260708114908-ef81d025
---
## Problem

Approving a spec on the phone is the leverage point, but execution still needs a human to sit at a machine and drive an agent. We want approved work to execute **unattended** — overnight batch now, a continuous "farm" later — while keeping the human in the loop only where judgment matters (spec approval up front, PR review at the end). It must be **cloud-agent-agnostic**: runnable by a Claude routine or any scheduled/cloud agent, not tied to a local `claude -p` on a dev box that sleeps.

## User story

As an operator, I approve a spec and flag its WorkItem `unattended` (a checkbox in Ground Control, or the CLI), and overnight a cloud routine implements it and opens a PR I review in the morning — without me babysitting an agent. Items I want to keep for my own attended agent I simply don't flag.

## Approach

**Split control plane from execution plane.** mship is the host-agnostic control plane; the agent runtime (a Claude routine, cron+`claude -p`, cloud CI) is a swappable execution plane. The self-contained `mship dispatch` prompt is the agnostic hand-off seam — mship never spawns the agent.

**New in mship (v1):**
1. **`unattended` flag** on the WorkItem (opt-in) — the operator curates what may run unattended. Settable from the CLI **and** via a Ground Control checkbox on the WorkItem, both flipping the same flag.
2. **Ready-work selector** — `mship run-next`: next item where spec=approved ∧ phase=ready ∧ unattended ∧ unclaimed; emits its (resumable) dispatch prompt.
3. **Run-claim** — a git-backed claim generalizing the inbox-listener lease, so two runs never grab the same item; reclaimable when stale/dead.
4. **Git-backed run state** — item status + claim + run-log in a dedicated git ref (orphan branch in the workspace repo), committed/pushed as checkpoints. This is the serverless shared store; the phone/serve reconciliation ("git = truth, serve = stateless view") is deferred (see non-goals).

**The run (host-agnostic):** cold start `mship bootstrap` (fresh clone) → `mship run-next` claims an item + emits its dispatch prompt → the host agent runs plan→dev→test→finish, calling mship as it goes, and opens a PR (never merges) → on an unresolvable fork or unfixable test failure it **bails**: marks the item blocked with a reason, pushes its branch, releases the claim, exits. "Pause" is checkpoint-and-exit; a later tick resumes off the pushed branch. The human reviews/merges the PR, or picks up a bailed item attended.

**Reference adapter:** a Claude routine on cron — `mship bootstrap` → `mship run-next` → exit — one item per tick (v1 one-at-a-time).

**Guardrails:** approved-spec precondition, audit + passing tests enforced at finish, never merges, claim prevents double-run.

Implementable in slices: (a) `unattended` flag (CLI + GC checkbox) + selector + claim; (b) git-backed run-state + resumable dispatch; (c) the run loop wiring + bail; (d) the reference Claude-routine adapter.
