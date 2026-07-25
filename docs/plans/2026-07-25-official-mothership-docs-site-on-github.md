# Official Mothership Docs Site (GitHub Pages) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `official-mothership-docs-site-on-github` (approved, dispatched)
**Work item:** `wi-20260725001201-dd0e1633`
**Worktree:** `/home/bailey/development/repos/mship-workspace/.worktrees/official-mothership-docs-site-on-github/mothership`
**Branch:** `feat/official-mothership-docs-site-on-github`

**Goal:** Publish mothership's existing operator docs as a curated, searchable MkDocs Material site at https://atomikpanda.github.io/mothership/, deployed by GitHub Actions on merge to main.

**Architecture:** A `mkdocs.yml` at the repo root defines a curated nav over the existing `docs/*.md` files (no content rewrites) and excludes the internal working dirs (`docs/plans`, `docs/specs`, `docs/superpowers`) via `exclude_docs`. A new `docs/index.md` is the site landing page. A `docs.yml` GitHub Actions workflow builds with `mkdocs build --strict` on every docs PR (AC1) and deploys to Pages via the official artifact actions on push to main (AC2) — no `gh-pages` branch; `actions/configure-pages` with `enablement: true` turns Pages on automatically on first deploy.

**Tech Stack:** MkDocs + mkdocs-material (new `docs` dependency group, installed via uv), GitHub Actions (`actions/configure-pages@v5`, `actions/upload-pages-artifact@v3`, `actions/deploy-pages@v4`).

**Facts established up front (verified in the worktree):**
- Internal relative links between docs are exactly: `concepts.md → cli.md, configuration.md`; `cli.md → concepts.md, relay-hosting.md`; `configuration.md → relay-hosting.md`; `relay-hosting.md → cloud-agent-auth.md`. All are flat same-dir `.md` links — MkDocs resolves these natively, no fixes expected.
- `docs/` has no `index.md`; MkDocs requires one for the site home.
- `pyproject.toml` already has a `[dependency-groups]` table (a `dev` group exists) — add `docs` there, not `[project.optional-dependencies]`.
- Existing workflow style reference: `.github/workflows/version-bump.yml`.
- Repo is public; Pages is currently NOT enabled (`gh api repos/atomikpanda/mothership/pages` → 404).

---

<!-- mship:task id=1 -->
### Task 1: MkDocs tooling — dependency group, mkdocs.yml, landing page, gitignore

**Files:**
- Modify: `pyproject.toml` (add `docs` to the existing `[dependency-groups]` table)
- Create: `mkdocs.yml`
- Create: `docs/index.md`
- Modify: `.gitignore` (ignore `site/`, the mkdocs build output)

All work happens in the task worktree: `/home/bailey/development/repos/mship-workspace/.worktrees/official-mothership-docs-site-on-github/mothership`.

- [ ] **Step 1: Add the `docs` dependency group**

In `pyproject.toml`, inside the existing `[dependency-groups]` table (after the `dev` group's closing `]`), add:

```toml
docs = [
    "mkdocs-material>=9.5",
]
```

- [ ] **Step 2: Verify the failing state — strict build with no config**

Run (from the worktree root):
```bash
uv run --only-group docs mkdocs build --strict
```
Expected: FAIL — `Config file 'mkdocs.yml' does not exist.` (This proves the runner + group resolve before we add config.)

- [ ] **Step 3: Create `mkdocs.yml`**

```yaml
site_name: mship
site_description: Phase-based workflow engine for multi-repo AI development
site_url: https://atomikpanda.github.io/mothership/
repo_url: https://github.com/atomikpanda/mothership
repo_name: atomikpanda/mothership

theme:
  name: material
  palette:
    - media: "(prefers-color-scheme: light)"
      scheme: default
      toggle:
        icon: material/brightness-7
        name: Switch to dark mode
    - media: "(prefers-color-scheme: dark)"
      scheme: slate
      toggle:
        icon: material/brightness-4
        name: Switch to light mode
  features:
    - navigation.sections
    - navigation.top
    - content.code.copy

markdown_extensions:
  - admonition
  - toc:
      permalink: true
  - pymdownx.highlight
  - pymdownx.superfences

exclude_docs: |
  plans/
  specs/
  superpowers/

nav:
  - Getting started: index.md
  - Concepts: concepts.md
  - Configuration: configuration.md
  - CLI reference: cli.md
  - Remote access:
      - Serve over Tailscale: mship-serve-tailscale.md
      - Relay hosting: relay-hosting.md
      - Remote run: remote-run.md
  - Cloud workers:
      - Unattended cloud runner: unattended-cloud-runner.md
      - Cloud worker auth spine: cloud-worker-auth-spine.md
      - Cloud agent auth: cloud-agent-auth.md
      - Claude routine runner (adapter): adapters/claude-routine-runner.md
```

(`exclude_docs` is gitignore-syntax, supported since MkDocs 1.5 — it keeps the internal working dirs out of the build entirely, which is what satisfies AC3's exclusion clause. `pymdownx.*` ships with mkdocs-material, no extra dependency.)

- [ ] **Step 4: Create `docs/index.md`**

```markdown
# mship

A structured interface between AI coding agents and a running multi-repo system.

> Pre-1.0. API may change. Pin a commit if you need stability.

mship coordinates feature work that spans multiple repos: phase-based workflow,
per-task worktrees, dependency-ordered execution, healthchecks, and a phone
inbox for operator ↔ agent messaging.

## Where to start

- **[Concepts](concepts.md)** — the mental model: workspaces, work items, tasks, phases.
- **[Configuration](configuration.md)** — `mothership.yaml` reference.
- **[CLI reference](cli.md)** — every `mship` command.

## Remote access

- **[Serve over Tailscale](mship-serve-tailscale.md)** — expose `mship serve` on your tailnet.
- **[Relay hosting](relay-hosting.md)** — self-hosted sish relay with per-device subdomains.
- **[Remote run](remote-run.md)** — trigger runs from anywhere.

## Cloud workers

- **[Unattended cloud runner](unattended-cloud-runner.md)** — the end-to-end runbook: setup, per-run lifecycle, security guarantees.
- **[Cloud worker auth spine](cloud-worker-auth-spine.md)** — attach-at-relay credential model.
- **[Cloud agent auth](cloud-agent-auth.md)** — worker identity, enrollment, run tokens.
- **[Claude routine runner](adapters/claude-routine-runner.md)** — the scheduled-routine adapter.

## Install

```bash
uv tool install git+https://github.com/atomikpanda/mothership.git
```

See the [repository README](https://github.com/atomikpanda/mothership#readme) for the full quickstart.
```

- [ ] **Step 5: Ignore the build output**

Append to `.gitignore`:

```
site/
```

- [ ] **Step 6: Run the strict build — must pass**

```bash
uv run --only-group docs mkdocs build --strict
```
Expected: PASS — `INFO - Documentation built in X.XX seconds`, exit 0, zero WARNINGs. If strict fails on a broken link, fix the link in the offending doc (light fix only; the six known cross-links listed in the header are all valid).

- [ ] **Step 7: Verify the exclusion (AC3) and search index (AC4)**

```bash
test ! -d site/plans && test ! -d site/specs && test ! -d site/superpowers && echo EXCLUDED-OK
grep -c "unattended" site/search/search_index.json
```
Expected: `EXCLUDED-OK`, and a count ≥ 1 (search index contains doc content).

- [ ] **Step 8: Commit + journal**

```bash
git add pyproject.toml uv.lock mkdocs.yml docs/index.md .gitignore
git commit -m "feat(docs): mkdocs-material site config, landing page, docs dep group"
mship journal "mkdocs.yml + docs/index.md + docs dep group; strict build green, internals excluded, search index populated" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: GitHub Actions workflow — strict build on PRs, Pages deploy on main

**Files:**
- Create: `.github/workflows/docs.yml`

- [ ] **Step 1: Create `.github/workflows/docs.yml`**

```yaml
name: docs

on:
  push:
    branches: [main]
    paths:
      - "docs/**"
      - "mkdocs.yml"
      - ".github/workflows/docs.yml"
  pull_request:
    paths:
      - "docs/**"
      - "mkdocs.yml"
      - ".github/workflows/docs.yml"

permissions:
  contents: read

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: astral-sh/setup-uv@v5
      - name: Build docs (strict)
        run: uv run --only-group docs mkdocs build --strict
      - name: Upload Pages artifact
        if: github.event_name == 'push'
        uses: actions/upload-pages-artifact@v3
        with:
          path: site

  deploy:
    if: github.event_name == 'push'
    needs: build
    runs-on: ubuntu-latest
    permissions:
      pages: write
      id-token: write
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - name: Enable + configure Pages
        uses: actions/configure-pages@v5
        with:
          enablement: true
      - name: Deploy to GitHub Pages
        id: deployment
        uses: actions/deploy-pages@v4
```

Notes anchored to the ACs: the `pull_request` trigger is AC1's "CI runs it on docs changes"; the `push`-gated deploy job is AC2; `enablement: true` on `configure-pages` creates the Pages site on first run so no manual repo-settings step is needed (spec risk #2 resolved in-code).

- [ ] **Step 2: Validate the workflow YAML parses**

```bash
uv run python -c "import yaml,sys; yaml.safe_load(open('.github/workflows/docs.yml')); print('YAML-OK')"
```
Expected: `YAML-OK` (pyyaml is a project dependency, so plain `uv run` has it).

- [ ] **Step 3: Commit + journal**

```bash
git add .github/workflows/docs.yml
git commit -m "ci(docs): build docs strictly on PRs, deploy to GitHub Pages on main"
mship journal "docs.yml workflow: strict build on docs PRs, Pages artifact deploy on main push, auto-enables Pages" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: README link to the published site (AC5)

**Files:**
- Modify: `README.md` (after the `> Pre-1.0…` blockquote, before `## Problem`)

- [ ] **Step 1: Add the docs link**

Insert after the `> Pre-1.0. API may change. Pin a commit if you need stability.` line:

```markdown

📖 **Docs:** <https://atomikpanda.github.io/mothership/>
```

- [ ] **Step 2: Commit + journal**

```bash
git add README.md
git commit -m "docs: link the published docs site from the README"
mship journal "README links the Pages site" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: Full verification + finish

- [ ] **Step 1: Re-run the strict build clean**

```bash
rm -rf site && uv run --only-group docs mkdocs build --strict && echo BUILD-OK
```
Expected: `BUILD-OK`.

- [ ] **Step 2: Run the repo test suite (finish evidence trail)**

```bash
mship test --repos mothership
```
Expected: full suite green, exit 0 (change is docs/CI-only; nothing imports it).

- [ ] **Step 3: Record AC evidence**

```bash
mship spec evidence official-mothership-docs-site-on-github ac1 --note "mkdocs build --strict exit 0, zero warnings; docs.yml runs it on pull_request docs paths"
mship spec evidence official-mothership-docs-site-on-github ac3 --note "nav covers all 10 operator docs in 6 sections; site/plans|specs|superpowers absent from build output"
mship spec evidence official-mothership-docs-site-on-github ac4 --note "site/search/search_index.json contains doc content (grep hit count >= 1)"
mship spec evidence official-mothership-docs-site-on-github ac5 --note "README links https://atomikpanda.github.io/mothership/"
```
(AC2 — live site reachable — is only verifiable after merge; verify post-merge and note it on the PR/thread.)

- [ ] **Step 4: Finish (opens the PR; never merge)**

```bash
mship finish
```
Then tidy the auto-generated PR body with `gh pr edit` if it restates unscoped ACs (per workspace convention), and reply on thread `20260725001203-1a287a96` with the PR link.
<!-- /mship:task -->

---

## Self-review notes

- **Spec coverage:** AC1 → Task 1 step 6 + Task 2 (PR trigger); AC2 → Task 2 deploy job (live-URL check deferred to post-merge, stated in Task 4); AC3 → Task 1 steps 3/7 (nav + exclude_docs + build-output check); AC4 → Task 1 step 7; AC5 → Task 3. Non-goals respected: no content rewrites, no versioning, no custom domain.
- **Placeholder scan:** none — every file shown in full, every command exact with expected output.
- **Consistency:** the `docs` group name, `--only-group docs` invocations, nav paths, and workflow paths all match across tasks.
