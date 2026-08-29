---
id: relay-aware-worker-boot
title: 'Relay-aware worker boot: bootstrap + gh preflight through the relay, and the
  cloud-worker-routine skill'
status: implemented
created_at: '2026-07-22T14:34:07.957315Z'
updated_at: '2026-07-22T20:40:46.830803Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: "[ac1] `mship bootstrap --relay-url <url> --run-token <token>` configures\
    \ git globally for the relay BEFORE cloning \u2014 the /gh/ + /api/ insteadOf\
    \ rewrites and the Mship-Run-Token extraHeader \u2014 and then clones through\
    \ the relay with NO GitHub token resolved/required on the worker; without the\
    \ flags, bootstrap behaves exactly as today."
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.ground-control
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac2
  text: '[ac2] The relay git config bootstrap writes (the /gh/ + /api/ path prefixes
    and the Mship-Run-Token header name) is emitted from a single shared source in
    mship (not a literal hardcoded in bootstrap), so it cannot drift from the relay
    egress-server; a test asserts the exact config produced.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.ground-control
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac3
  text: "[ac3] `mship gh preflight --relay-url <url> --run-token <token>` adds a relay-attach\
    \ mode: for each workspace repo it probes `GET <relay>/api/repos/{owner}/{repo}`\
    \ carrying the Mship-Run-Token header and STRICT-verifies a 200 with permissions.push\
    \ true; success prints an auth-OK message, any failure (401/403/404, no-push,\
    \ non-200, unreachable, timeout) exits non-zero with a clear message \u2014 the\
    \ same fail-fast contract as the existing modes."
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.ground-control
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac4
  text: "[ac4] The relay preflight reuses the existing permissions.push verification\
    \ path (verify_token_covers_repos), parameterized to the relay base URL + the\
    \ Mship-Run-Token header instead of api.github.com + a bearer \u2014 one verification,\
    \ two transports."
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.ground-control
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac5
  text: '[ac5] Relay mode is a distinct third auth mode: `--relay-url` and `--run-token`
    must be given together (one without the other errors clearly), relay mode does
    not fall through to the override-token/broker branches, and those existing branches
    are unchanged.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.ground-control
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac6
  text: '[ac6] A skill `src/mship/skills/overnight-cloud-worker-routines/SKILL.md`
    documents the end-to-end pattern: the agent mints a per-run token (mship relay
    issue-run-token scoped to the run''s repos + push_branch) and schedules a Claude
    Code routine whose flow is `bootstrap --relay` -> `gh preflight --relay` -> implement
    the assigned spec -> push + open the PR(s) through the relay; it states that the
    worker holds only the low-value run token and that nothing auto-merges (review-gated).'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.ground-control
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac7
  text: '[ac7] Tested with no live services: bootstrap --relay writes the exact expected
    git config and clones via ambient config without resolving a token (git invocation
    asserted through the shell seam); gh preflight --relay against a mock relay returns
    OK on 200+push and fails clearly on 401 / 403 / missing-push / unreachable; and
    the --relay-url/--run-token pairing validation.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.ground-control
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
open_questions: []
non_goals:
- "The agent's routine SCHEDULING itself \u2014 that is agent behaviour (the agent's\
  \ own Claude Code /schedule ability), not mship code. The skill documents it; mship\
  \ doesn't automate it."
- "Programmatically CREATING a Claude routine \u2014 routines have no create API;\
  \ the operator/agent sets it up. Out of scope."
- "A fan-out orchestrator subcommand (the earlier over-built idea) \u2014 explicitly\
  \ dropped; the existing agent schedules, existing mship commands do the work."
- "Deploying the live relay (Caddy egress + App creds on the relay host) \u2014 a\
  \ separate operator ops step this depends on to RUN, not to build/merge/test."
- "Auto-merging any PR \u2014 the flow is review-gated end to end."
- "Minting the run token inside the worker \u2014 the worker can't reach the relay's\
  \ token store; the agent that schedules the routine mints it (existing `mship relay\
  \ issue-run-token`) and injects it."
risks:
- 'The git config bootstrap writes MUST exactly match what the relay egress-server
  expects (path prefixes /gh/ + /api/, header name Mship-Run-Token) or the worker''s
  traffic won''t route/authenticate. Mitigation: emit the relay contract from one
  shared place in mship (not a hardcoded string in bootstrap), covered by a test that
  asserts the exact config.'
- '`mship bootstrap` today resolves a token (override/broker) and passes it to git;
  in relay mode it must NOT (the relay attaches at egress, and a stray token could
  shadow the relay path). Mitigation: when --relay-url is given, bootstrap skips token
  resolution and clones via the ambient relay git config only; tested.'
- "The preflight relay probe depends on the Slice-2a api leg permitting GET reads\
  \ on the run's repos \u2014 if that enforcer ever tightens GETs, the probe path\
  \ must move with it. Mitigation: the probe uses exactly the permitted GET /repos/{o}/{r}\
  \ shape; a test pins it."
- 'Global git config on a shared machine could clobber a developer''s real config.
  Mitigation: this is for a DISPOSABLE worker (fresh cloud env); the skill says so,
  and the flags are opt-in (never applied without --relay-url).'
task_slug: null
work_item_id: null
clarification_reason: null
prose_verdicts: {}
---
## Problem

The overnight cloud-worker vision is: the operator (or an agent) schedules a Claude Code cloud routine that, when it fires, becomes a disposable mship worker — it clones the workspace, implements one assigned spec, and opens the PR(s) — all routed through the relay (attach-at-relay: the worker holds only a low-value run token; its git goes through the relay, which attaches + enforces credentials at egress). The lower layers are shipped (the relay auth spine + the worker-PR egress leg). What is missing is the small worker-side glue so a fresh cloud routine can actually USE that path: (1) nothing configures the worker's git to route through the relay before it clones — `mship bootstrap` clones with a raw GH token, not the relay proxy; and (2) `mship gh preflight` — the fail-fast auth check meant to run FIRST on an unattended run so it aborts before spending AI tokens on code it can't push — only understands an override GH_TOKEN or a broker pull, NEITHER of which is the attach-at-relay model, so a relay-attach worker fails preflight ('no GitHub auth configured') even though its auth works. Plus there is no captured pattern for how the agent stands such a routine up.

## User story

As the agent standing up an overnight cloud-worker routine, I want the worker to configure its git for the relay and fail-fast-verify that relay-routed auth before it starts, so that a fired routine reliably becomes a working mship worker — cloning, building, and opening PRs through the relay — and aborts early with a clear message if its relay auth can't actually push, instead of burning AI tokens on code it then can't land.

## Approach

Three small, coherent worker-boot pieces plus a skill (no new subcommands — two existing commands gain a relay mode):

1. `mship bootstrap --relay-url <url> --run-token <token>`: when both are given, bootstrap first configures git GLOBALLY for the relay — the `url.<relay>/gh/.insteadOf https://github.com/` + `url.<relay>/api/.insteadOf https://api.github.com/` rewrites and the `http.<relay>/.extraHeader Mship-Run-Token: <token>` header — then clones. Because git rewrites the clone URLs to the relay and carries the run-token header, the clones (and every later push/PR) route through the relay with no GitHub credential on the worker. Without the flags, bootstrap is unchanged. The relay contract (the /gh/ + /api/ prefixes + the Mship-Run-Token header name) is emitted from ONE place in mship so it can't drift from the relay egress-server.

2. `mship gh preflight --relay-url <url> --run-token <token>`: a relay-attach MODE for the fail-fast check. For each workspace repo it probes `GET <relay>/api/repos/{owner}/{repo}` carrying the Mship-Run-Token header — the relay attaches the real App token at egress (the Slice-2a api leg permits GET reads on the run's repos) — and STRICT-verifies a 200 with `permissions.push` true. That single probe confirms the WHOLE relay-routed path: relay reachable + run token valid/unexpired + the enrollment grant covers the repo + the attached App token can push. Any failure exits non-zero with a clear, actionable message (same STRICT contract as the existing preflight). It reuses the existing `permissions.push` verification (`verify_token_covers_repos`), just routed through the relay base URL + run-token header instead of api.github.com + a bearer. Relay mode is a distinct third mode alongside override-token and broker; the existing modes are unchanged.

3. A SKILL (`src/mship/skills/overnight-cloud-worker-routines/SKILL.md`) capturing the end-to-end pattern the agent follows: mint a per-run token (`mship relay issue-run-token` scoped to the run's repos + branch), schedule a Claude Code routine (its environment installs mship; its prompt/task tells it what to build), where the routine's flow is `mship bootstrap --relay-url … --run-token …` -> `mship gh preflight --relay-url … --run-token …` -> implement the assigned spec -> push + open the PR through the relay. It states the guarantees (worker holds only the low-value run token; nothing auto-merges — review-gated).

## Architecture

Shared relay contract: a small helper (e.g. core/relay/worker_config.py, or reuse the egress request module's prefix map) exposes the /gh/ + /api/ insteadOf targets + the Mship-Run-Token header name, so both the relay egress-server and this worker-side config read the same source. bootstrap (cli + core/bootstrap.py): add --relay-url/--run-token; when set, run the git config via the existing ShellRunner seam (globally) before the clone loop, and take the no-token clone path (skip resolve_token). gh preflight (core/gh_preflight.py): add relay params to run_preflight; a new branch (or a generalized verify that takes base_url + auth-header) probes GET {relay}/api/repos/{owner}/{repo} with the Mship-Run-Token header and applies the same status/permissions.push checks as verify_token_covers_repos; cli/gh.py surfaces --relay-url/--run-token + the pairing validation. Skill: a new SKILL.md under src/mship/skills/. Reuses: resolve_clone_url + repo_owner_names_from_config (the same repo set/slug resolution bootstrap uses), verify_token_covers_repos' permission check, the ShellRunner seam for git config, and the Slice-2a api leg for the probe.

## Testing

bootstrap: with --relay-url/--run-token, assert the exact `git config` commands issued to the shell seam (the /gh/ + /api/ insteadOf + the Mship-Run-Token extraHeader) and that the clone path does NOT resolve/pass a token; without the flags, existing bootstrap tests unchanged. gh preflight relay mode (httpx.MockTransport): a repo returning 200 + permissions.push -> OK; 401 -> invalid/expired; 403/404 or 200-without-push -> cannot push; connection error/timeout -> clear failure; an out-of-scope/denied repo (relay 403) -> clear failure. Arg validation: --relay-url without --run-token (and vice versa) exits non-zero. The shared relay-contract helper: one test asserts the prefixes + header name so a drift from the egress-server breaks a test. No live relay, GitHub, or App key — the shell seam, the relay probe, and the config source are all injected/mocked.
