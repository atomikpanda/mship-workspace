---
id: user-journey-docs
title: 'User-journey docs: getting-started tutorial + guides section'
status: implemented
created_at: '2026-07-25T01:39:42.965555Z'
updated_at: '2026-07-25T01:56:03.159023Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: docs/getting-started.md walks install -> init -> first task -> finish -> merge
    -> close with expected output at each step, and every command in it exists in
    the current CLI (verified against --help during writing)
  verdict: approved
  evidence:
  - kind: commit
    ref: 751a3a4
    note: 'getting-started.md: install->init->item->spawn->test->finish->merge->close
      with output excerpts; every command verified against --help'
  - kind: test
    ref: test-runs/1.mothership
    note: null
  comment: null
- id: ac2
  text: docs/guides/ contains the six how-tos (ship-a-feature, fix-a-bug, multi-repo-tasks,
    run-and-observe, phone-control, agent-driven-development), each opening with a
    when-you-need-this line
  verdict: approved
  evidence:
  - kind: commit
    ref: 9bc0af1
    note: six guides in docs/guides/, all six open with a When-you-need-this line
      (grep-verified)
  - kind: test
    ref: test-runs/1.mothership
    note: null
  comment: null
- id: ac3
  text: 'docs/index.md is a journey-first landing page: what mship is, Start here
    -> tutorial, guides listed by goal, reference/advanced last'
  verdict: approved
  evidence:
  - kind: commit
    ref: '1799740'
    note: 'index.md journey-first: what mship is, Start here, guides by goal, reference/advanced
      last'
  - kind: test
    ref: test-runs/1.mothership
    note: null
  comment: null
- id: ac4
  text: mkdocs nav is restructured to Getting started / Guides / Concepts / Reference
    / Remote access / Cloud workers with every existing page still reachable
  verdict: approved
  evidence:
  - kind: commit
    ref: '1799740'
    note: nav = Home/Getting started/Guides/Concepts/Reference/Remote access/Cloud
      workers; all pre-existing pages present
  - kind: test
    ref: test-runs/1.mothership
    note: null
  comment: null
- id: ac5
  text: mkdocs build --strict passes and site search returns guide content
  verdict: approved
  evidence:
  - kind: commit
    ref: '1799740'
    note: mkdocs build --strict exit 0; search index contains guide content
  - kind: test
    ref: test-runs/1.mothership
    note: null
  comment: null
- id: ac6
  text: "No new page documents internals (module paths, enforcer design, trust models)\
    \ \u2014 internals remain in their existing pages, linked where relevant"
  verdict: approved
  evidence:
  - kind: commit
    ref: 9bc0af1
    note: 'grep for module paths/Enforcer/trust model across new pages: clean'
  - kind: test
    ref: test-runs/1.mothership
    note: null
  comment: null
open_questions: []
non_goals:
- Removing or rewriting the existing reference/internals pages (concepts, configuration,
  cli, relay, cloud workers stay as they are; only their nav position changes)
- "Documenting unshipped features \u2014 guides describe only what the current CLI\
  \ does, verified against --help"
- "Video/screenshot production \u2014 text + command transcripts only (GC flows described\
  \ textually)"
- Changing the README (it already serves the repo audience; the site gets its own
  pages rather than a copy)
risks:
- "Guide drift: guides embed command transcripts that can go stale as the CLI evolves\
  \ \u2014 mitigated by mkdocs strict CI on every docs PR and by keeping transcripts\
  \ minimal (representative, not exhaustive)"
- "Phone-control guide describes Ground Control UI flows that live in a different\
  \ repo and can drift \u2014 kept at the level of stable flows (pair, Queue approve,\
  \ chat, merge)"
- 'Scope creep: six guides is deliberate; more journeys (cloud runner already has
  its runbook) link out instead of duplicating'
task_slug: user-journey-docs
work_item_id: wi-20260725014206-0af4fbc8
clarification_reason: null
prose_verdicts: {}
---
## Problem

The docs site now exists and the cloud-runner cluster is coherent, but the site is reference- and internals-heavy: Concepts, Configuration, CLI reference, relay/cloud deep-dives. There is no tutorial that takes a new user from install to a first merged PR, and no task-oriented guides for the workflows people actually run (ship a feature spec-first, fix a bug fast, coordinate a multi-repo task, run and observe the stack, drive everything from the phone, work with an AI agent). The README has good user-facing material (quickstart, cheat sheet, capability tour) but none of it is on the site — the landing page is a thin link hub. A newcomer can learn what mship IS but not how to USE it.

## User story

As a new mship user, I want a getting-started tutorial and task-oriented guides on the docs site, so that I can go from install to my first merged PR and then find the workflow guide for whatever I am trying to do, without reading internals or design docs.

## Approach

Add a user-journey layer on top of the existing reference docs (which stay untouched apart from nav placement). New pages, every command verified against the current CLI before it is written down: (1) docs/getting-started.md — install (uv tool install), mship init --detect, then the full first-task loop: item new, spawn, edit in the worktree, test, finish, merge, close — with expected output shown at each step. (2) A docs/guides/ section with six task-oriented how-tos, each opening with a 'when you need this' line: ship-a-feature.md (the spec-first loop: item new --kind feature, spec new/draft/apply, review + approve, plan via the writing-plans skill, dispatch, phase gates, finish); fix-a-bug.md (bug/chore kinds skip the design gates; --hotfix for emergencies; what stays enforced); multi-repo-tasks.md (spawn --repos, switch, dependency-ordered test, cross-repo finish with coordinated PRs, drift audits); run-and-observe.md (mship run/build/capture, healthchecks, task-scoped ports, status/context/journal); phone-control.md (serve --relay, pairing Ground Control, capture -> spec -> approve from the Queue, chat/inbox, reviewing + merging PRs from the phone); agent-driven-development.md (mship skill install, the working-with-mothership skill, dispatch and subagent-driven development, journal discipline). (3) Rewrite docs/index.md as a journey-first landing page (what mship is in three sentences, then 'Start here' -> tutorial, then guides by goal). (4) Restructure the mkdocs nav: Getting started / Guides / Concepts / Reference (CLI, Configuration) / Remote access / Cloud workers — internals keep their pages but sit after the user-journey sections. Content is adapted from the README, concepts.md, the working-with-mothership skill, and CLI --help output — not invented.
