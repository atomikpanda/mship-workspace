---
id: cloud-runner-docs-clarity-pass
title: Cloud-runner docs clarity pass
status: implemented
created_at: '2026-07-25T00:41:31.543037Z'
updated_at: '2026-07-25T00:57:30.362314Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: Exactly one canonical PR-open statement exists (the runbook's 'Opening the
    PR' section, verified against the current mship finish CLI); cloud-worker-auth-spine.md
    no longer claims the worker opens its own PR and instead defers to the runbook
  verdict: unreviewed
  evidence:
  - kind: commit
    ref: aff3952
    note: 'spine defers to runbook Opening-the-PR; grep for worker-opens-PR claims
      clean; finish CLI verified: --push-only present, no relay flags'
  - kind: test
    ref: test-runs/1.mothership
    note: null
  comment: null
- id: ac2
  text: adapters/claude-routine-runner.md prerequisites present all three auth options
    (env token / gh-token broker / attach-at-relay run token) with links, and no longer
    require a raw GH_TOKEN as the only path
  verdict: unreviewed
  evidence:
  - kind: commit
    ref: 796f64e
    note: adapter prerequisites list env token / gh-token broker / attach-at-relay
      with links; tick-script env comment reconciled
  - kind: test
    ref: test-runs/1.mothership
    note: null
  comment: null
- id: ac3
  text: 'The runbook contains a ''Choosing your setup'' decision table covering both
    axes: auth model (env token / broker / attach-at-relay) and selection model (per-spec
    push / pull-API backlog), each with a when-to-use line'
  verdict: unreviewed
  evidence:
  - kind: commit
    ref: a5da833
    note: 'runbook Choosing-your-setup: two-axis tables (auth x selection) each with
      use-when + doc link'
  - kind: test
    ref: test-runs/1.mothership
    note: null
  comment: null
- id: ac4
  text: Each of the four cluster docs opens with a short 'where this fits' paragraph
    naming its siblings; no H1 or section heading contains Shape 2/Shape 3 jargon
  verdict: unreviewed
  evidence:
  - kind: commit
    ref: 3c28b0e
    note: all four docs open with where-this-fits; grep '^#.*Shape' clean (jargon
      only in one prose parenthetical)
  - kind: test
    ref: test-runs/1.mothership
    note: null
  comment: null
- id: ac5
  text: 'One name per concept across the four docs: worker, the /gh-token broker,
    the egress proxy (attach-at-relay), the unattended cloud runner; remote-run.md''s
    ''Phase-1 GitHub token broker'' mention is fixed'
  verdict: unreviewed
  evidence:
  - kind: commit
    ref: fecda6f
    note: one name per concept across cluster; remote-run Phase-1-broker mention fixed
      (grep clean)
  - kind: test
    ref: test-runs/1.mothership
    note: null
  comment: null
- id: ac6
  text: mkdocs build --strict passes; nav labels match the retitled pages
  verdict: unreviewed
  evidence:
  - kind: commit
    ref: fecda6f
    note: mkdocs build --strict exit 0; nav labels match retitled pages
  - kind: test
    ref: test-runs/1.mothership
    note: null
  comment: null
open_questions: []
non_goals:
- Renaming or moving doc files (all links, specs, and memories keep working)
- Any code or CLI change (if verification shows a docs claim needs code to become
  true, the docs state reality and the gap stays a tracked follow-up)
- Rewriting docs outside the cluster (concepts, configuration, cli, relay-hosting
  stay untouched; remote-run.md gets only the one stale-name fix)
- "Changing the security model or setup steps themselves \u2014 this is clarity, not\
  \ redesign"
risks:
- "The PR-open truth must be established from the current CLI, not from either doc\
  \ \u2014 if both docs are partially stale the pass must reflect verified behavior"
- Editorial rewrites can drift technical claims; every changed factual statement gets
  checked against --help output or code before landing
- "Retitled H1s change page titles (nav labels updated to match); external deep links\
  \ to heading anchors within these pages may break \u2014 acceptable for a young\
  \ site"
task_slug: cloud-runner-docs-clarity-pass
work_item_id: wi-20260725004405-f17b3e47
clarification_reason: null
prose_verdicts: {}
---
## Problem

The cloud-runner documentation cluster (unattended-cloud-runner.md, cloud-worker-auth-spine.md, cloud-agent-auth.md, adapters/claude-routine-runner.md) grew one spec at a time and now confuses readers, including on the new docs site. Concrete defects found in a full read: (1) a flat contradiction on PR-opening — the runbook says a run-token-only worker CANNOT open its own PR (finish --push-only, attended PR-open, relay-wired PR-open 'not yet shipped') while the auth spine says 'The worker OPENS its PR through the /api/ egress leg' (§6) and 'The worker opens its own PR' (§8); (2) the adapter doc's prerequisites require a raw GH_TOKEN on the worker, predating both the /gh-token broker env (MSHIP_GH_BROKER_URL) and the attach-at-relay run-token path — directly contradicting the headline 'the worker never holds a GitHub credential' with no reconciliation; (3) the two independent design axes — HOW the worker authenticates (env token vs /gh-token broker vs attach-at-relay) and HOW work is selected (push: schedule a named spec vs pull: item run-next backlog) — are never laid out anywhere, so 'variants' read as a pile of overlapping systems; (4) terminology sprawl: internal design jargon (Shape 2/Shape 3, 'auth spine') in reader-facing titles, and 'broker' used for two different things.

## User story

As an operator reading the docs site, I want the cloud-runner pages to tell one consistent story with a clear decision guide, so that I can pick the right setup and trust that what the docs claim matches what the CLI actually does.

## Approach

Editorial pass over the four docs plus small touches to mkdocs.yml nav labels and docs/index.md; no file renames (repo/spec/site links stay stable) and no code changes. (1) Resolve the PR-open contradiction to a single canonical statement: verify against the current CLI (mship finish --help) whether a relay-routed PR-open path exists, make the runbook's 'Opening the PR' section the one source of truth, and rewrite the spine's §6 callout and §8 intro to describe the /api/ leg as live-and-enforced infrastructure that finish does not yet route through, deferring to the runbook. (2) Rewrite the adapter doc's prerequisites to present the three auth options (raw env token for trusted CI; MSHIP_GH_BROKER_URL + serve token; relay-url + run-token) with links to the docs that own each, replacing the bare GH_TOKEN requirement. (3) Add a 'Choosing your setup' decision table to the runbook covering both axes (auth model x selection model) with when-to-use guidance, and give each deep-dive doc a short 'Where this fits' opening paragraph naming its siblings. (4) Normalize terminology: one name per concept (worker; the /gh-token broker; the egress proxy / attach-at-relay; the unattended cloud runner); retitle page H1s to state their role (e.g. 'Attach-at-relay: the credential egress proxy', 'The /gh-token broker: GitHub auth for trusted cloud sessions', 'Pull-API runner: a Claude routine host'); move Shape-2/Shape-3 language out of titles/headings into a renamed deployment-trust subsection. Also fix remote-run.md's stale 'Phase-1 GitHub token broker' mention to name/link the /gh-token broker. Update mkdocs.yml nav labels to match new titles; strict build stays green.
