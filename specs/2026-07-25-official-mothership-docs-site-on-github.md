---
id: official-mothership-docs-site-on-github
title: Official mothership docs site on GitHub Pages
status: implemented
created_at: '2026-07-25T00:09:55.680777Z'
updated_at: '2026-07-25T00:34:40.734303Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: mkdocs build --strict succeeds (no broken internal links, every nav entry
    resolves), and CI runs it on docs changes
  verdict: approved
  evidence:
  - kind: commit
    ref: 6957bc2
    note: mkdocs build --strict exit 0, zero warnings; docs.yml runs it on pull_request
      docs paths
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac2
  text: Merging a docs change to main publishes the site via GitHub Actions Pages
    deployment, reachable at https://atomikpanda.github.io/mothership/
  verdict: approved
  evidence:
  - kind: commit
    ref: c5143b5
    note: deploy job on push-to-main via actions/deploy-pages, configure-pages enablement:true;
      live URL verifiable post-merge
  - kind: test
    ref: test-runs/2.mothership
    note: null
  - kind: artifact
    ref: https://atomikpanda.github.io/mothership/
    note: 'live site verified post-merge: home 200 (title mship), subpage 200, /plans/
      404; docs deploy run green after one-time Pages enable via gh api'
  comment: null
- id: ac3
  text: The site nav groups all current operator docs into sections (Getting started
    / Concepts / Configuration / CLI reference / Remote access / Cloud workers) and
    none of docs/plans, docs/specs, docs/superpowers is published
  verdict: approved
  evidence:
  - kind: commit
    ref: 6957bc2
    note: nav covers all 10 operator docs in 6 sections; site/plans|specs|superpowers
      absent from build output
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac4
  text: Site search returns results for doc content (Material built-in search)
  verdict: approved
  evidence:
  - kind: commit
    ref: 6957bc2
    note: site/search/search_index.json contains doc content (grep hit >= 1)
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac5
  text: The repo README links to the published docs site
  verdict: approved
  evidence:
  - kind: commit
    ref: d4831de
    note: README links https://atomikpanda.github.io/mothership/
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
open_questions: []
non_goals:
- Rewriting or restructuring the content of existing docs (light link/title fixes
  only)
- Publishing internal working dirs (docs/plans, docs/specs, docs/superpowers)
- Versioned docs (mike) or a custom domain
- "Auto-generated CLI/API reference \u2014 the hand-written cli.md remains the CLI\
  \ reference for now"
risks:
- mkdocs --strict may surface pre-existing broken cross-links that need fixing before
  the first green build
- "Enabling Pages requires a one-time repo-level action (gh api or Settings \u2192\
  \ Pages \u2192 Source: GitHub Actions); if token scopes block it, it becomes a small\
  \ operator hand-back"
- "Docs drift: the site publishes whatever merges to main \u2014 mitigated by the\
  \ strict build gate in CI"
task_slug: official-mothership-docs-site-on-github
work_item_id: wi-20260725001201-dd0e1633
clarification_reason: null
prose_verdicts: {}
---
## Problem

Mothership's operator documentation is 10 markdown files (~2k lines) living in docs/, discoverable only by browsing the repo, and mixed in with internal working directories (docs/plans, docs/specs, docs/superpowers). There is no published site, no navigation, and no search — a new or returning operator has no official entry point, and the docs' structure (e.g. the new unattended-cloud-runner runbook stitching three deep-dive docs together) is invisible from a flat file listing. The repo is public and GitHub Pages is not yet enabled, so the gap is purely tooling and curation.

## User story

As a mothership operator, I want the official docs published as a browsable GitHub Pages site with curated navigation and search, so that I can find setup, usage, and runbook information without spelunking the repository tree.

## Approach

Use MkDocs with the Material theme (Python-native, matching the project's uv toolchain; added as a docs dependency group). Publish via a GitHub Actions workflow using the official Pages actions (actions/upload-pages-artifact + actions/deploy-pages — no gh-pages branch), triggered on push to main when docs/**, mkdocs.yml, or the workflow change. 'Reconcile' means curating a nav over the existing docs rather than rewriting them: Getting started (new short index.md landing page), Concepts, Configuration, CLI reference, Remote access (mship-serve-tailscale, relay-hosting, remote-run), Cloud workers (cloud-worker-auth-spine, cloud-agent-auth, unattended-cloud-runner, adapters/claude-routine-runner). Internal working dirs (docs/plans, docs/specs, docs/superpowers) are excluded from the site. Build runs with --strict so broken internal links fail CI instead of publishing silently; existing cross-links get fixed as part of the change. Pages is enabled on the repo with build_type=workflow (one-time, via gh api or repo settings).
