---
id: mship-layout
title: 'mship layout: opt-in serve tab + serve params on launch'
status: approved
created_at: '2026-07-16T11:36:13.003040Z'
updated_at: '2026-07-16T12:47:13.074273Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: '`mship layout init` writes two layout files: the normal mothership.kdl (tabs
    Plan/Dev/Review/Run, unchanged from the current default) and a serve layout (mothership-serve.kdl)
    containing those same tabs plus a Serve tab.'
  verdict: approved
  evidence: []
  comment: null
- id: ac2
  text: "`mship layout launch` with no serve args launches the normal layout (same\
    \ behavior as today \u2014 no Serve tab, no serve started)."
  verdict: approved
  evidence: []
  comment: null
- id: ac3
  text: '`mship layout launch --serve` launches the serve layout; its Serve tab runs
    `mship serve` with config/default params.'
  verdict: approved
  evidence: []
  comment: null
- id: ac4
  text: '`mship layout launch --serve --relay --port 8080` launches the serve layout
    whose Serve tab runs `mship serve --relay --port 8080` (flags threaded into the
    pane command).'
  verdict: approved
  evidence: []
  comment: null
- id: ac5
  text: Passing any serve flag (--host/--port/--relay/--relay-host) without --serve
    still selects the serve layout (serve flags imply --serve).
  verdict: approved
  evidence: []
  comment: null
- id: ac6
  text: In the serve layout the Serve tab is appended after the normal tabs and the
    Plan tab retains focus=true.
  verdict: approved
  evidence: []
  comment: null
- id: ac7
  text: render_serve_layout(serve_args) is a pure function unit-tested for each flag
    and combinations (and none), asserting the emitted `mship serve` command without
    launching zellij.
  verdict: approved
  evidence: []
  comment: null
open_questions: []
non_goals:
- "Restyling the mship view panes (spec/status/journal/diff) to match Ground Control\
  \ \u2014 deferred to a follow-up spec."
- Any change to `mship serve` itself.
- Serve lifecycle management beyond running it in the pane (no health monitoring,
  auto-restart, or shutdown handling).
risks:
- 'Double-serve collision: the serve layout starts a serve, so opening it while a
  standalone serve already runs will collide (the silent phone-drop). Explicit --serve
  opt-in keeps the operator in control; call out the collision in --help.'
- 'Flag drift: launch re-exposes serve''s flags, so a future serve flag needs a matching
  launch update. Keep the list small + documented and note the coupling in code.'
- "Two artifacts to keep in sync: init writes both layouts from one shared tab template\
  \ \u2014 the normal and serve layouts must not drift; render from a single source."
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

Issue #355. `mship layout` sets up a zellij workspace (tabs Plan/Dev/Review/Run, each pane running `mship view … --watch`), but there is no way to run `mship serve` inside the layout, and `mship layout launch` takes no serve parameters. An operator who wants serve running alongside their layout must start it separately. We want a distinct **serve layout** — the normal workspace plus a Serve tab — selected on demand and configured with serve's own flags, kept fully separate from the normal layout so plain launch never starts a serve (which would collide with a persistent relay serve and silently drop the phone).

## User story

As an operator, I want `mship layout launch --serve --relay --port 8080` to open a serve layout — my normal tabs (Plan/Dev/Review/Run) plus a Serve tab running `mship serve` with those params — so I can host serve inside my workspace on demand, while plain `mship layout launch` stays the normal layout untouched (no Serve tab, no collision with my standalone relay serve).

## Approach

- **Two separate layouts.** `mship layout init` writes both: the normal `mothership.kdl` (tabs Plan/Dev/Review/Run — unchanged from today) and a serve layout `mothership-serve.kdl` containing those same tabs plus a **Serve** tab (appended last; Plan keeps focus). The serve layout's Serve pane runs `mship serve` (config/default params) so `zellij --layout mothership-serve` works standalone.
- **Selecting the serve layout.** `mship layout launch` gains `--serve` plus serve's own flags (`--host`, `--port`, `--relay`, `--relay-host`). Passing `--serve` OR any serve flag selects the serve layout; passing none launches the normal layout exactly as today.
- **Threading params.** When serve flags are passed, `launch` renders the *effective* serve layout — the serve layout with those flags baked into the Serve pane's `mship serve <flags>` command — to a temp layout file and execs `zellij --layout <tempfile>`. Bare `--serve` (no flags) launches the static `mothership-serve.kdl`.
- **DRY + testability.** Factor the tab template into one shared source used by both layouts, and a pure `render_serve_layout(serve_args) -> str` (KDL) so tests assert the injected `mship serve` command without launching zellij; `launch` calls it then execs.
- **Normal layout untouched:** plain `launch` never renders or starts serve.
