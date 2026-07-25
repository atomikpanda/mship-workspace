# Cloud-Runner Docs Clarity Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `cloud-runner-docs-clarity-pass` (approved, dispatched)
**Work item:** `wi-20260725004405-f17b3e47`
**Worktree:** `/home/bailey/development/repos/mship-workspace/.worktrees/cloud-runner-docs-clarity-pass/mothership`
**Branch:** `feat/cloud-runner-docs-clarity-pass`

**Goal:** Make the four cloud-runner docs tell one consistent, navigable story: one canonical PR-open statement, current prerequisites, a decision guide, and consistent naming — no file renames, no code changes.

**Architecture:** Pure editorial pass. The runbook (`unattended-cloud-runner.md`) stays the entry point and gains a "Choosing your setup" decision table; the three deep-dives get role-stating H1s and "Where this fits" intros; the spine's stale PR-open claims are rewritten to defer to the runbook. `mkdocs.yml` nav labels track the new titles.

**Tech Stack:** Markdown only; `mkdocs build --strict` as the gate.

**Ground truth (verified against this branch's CLI on 2026-07-25 — do not re-litigate from the docs):**
- `mship finish --help` has `--push-only` ("Push branches only; skip gh pr create") and **NO** `--relay-url`/`--run-token` flags; no `relay_url` in finish code paths. → A run-token-only worker **cannot** open its own PR today. The runbook is correct; the spine's §6 callout and §8 intro are stale.
- `mship bootstrap --help` and `mship gh preflight --help` **do** both have `--relay-url` + `--run-token`. Runbook claims stand.

---

<!-- mship:task id=1 -->
### Task 1: `docs/cloud-worker-auth-spine.md` — fix the PR-open contradiction, retitle, de-jargon

**Files:**
- Modify: `docs/cloud-worker-auth-spine.md`

- [ ] **Step 1: Replace the H1 and add a "Where this fits" intro**

Replace line 1:
```markdown
# Cloud-worker auth spine — attach-at-relay credential egress proxy (Shape 2)
```
with:
```markdown
# Attach-at-relay: the credential egress proxy

> **Where this fits:** this is the deep-dive on the **credential plane** of the
> [unattended cloud runner](../unattended-cloud-runner.md) — start there for the
> workflow and setup. Siblings: [the `/gh-token` broker](cloud-agent-auth.md)
> (the simpler, trusted-worker alternative to this proxy) and the
> [pull-API runner](adapters/claude-routine-runner.md) (an alternative way to
> *select* work; independent of how auth is done).
```
(Link paths are same-dir: use `cloud-agent-auth.md` and `adapters/claude-routine-runner.md` — no `../`. Fix that in the block above when applying: the runbook link is `unattended-cloud-runner.md`.)

- [ ] **Step 2: De-jargon the section headings**

- `## 2. Attach-at-relay, Shape 2 (co-located)` → `## 2. The co-located deployment (v1)`
- `## 3. North star: the untrusted-relay 3-role split` → `## 3. Deployment trust: trusted relay today, untrusted relay later`
- Inside §3, keep the Shape-2/Shape-3 comparison but rename the terms in prose to "the co-located shape (this doc)" and "the untrusted-relay shape", keeping one parenthetical "(internally: Shape 2 / Shape 3)" on first mention so old spec/journal references still connect.

- [ ] **Step 3: Rewrite the §6 callout (the stale "worker OPENS its PR" claim)**

Replace the blockquote at the end of §6 (starts `> **The api.github.com leg is live + enforced.**`) with:
```markdown
> **The api.github.com leg is live + enforced — but `mship finish` does not
> route its PR-open through it yet.** The `/api/` route is deployed behind
> `GitHubApiEnforcer`, a DEFAULT-DENY REST enforcer (below) whose only permitted
> write is opening a PR. However `mship finish` has no `--relay-url`/`--run-token`
> path today, so a run-token-only worker pushes with `mship finish --push-only`
> and the PR is opened in an attended step. The canonical statement of what works
> today is the runbook's
> [Opening the PR](unattended-cloud-runner.md#opening-the-pr-why-it-is-a-separate-step-today)
> — this section documents the enforcer that makes the future relay-routed
> PR-open safe, so the API path can never sidestep the git push-to-run-branch
> enforcement.
```

- [ ] **Step 4: Rewrite the §8 intro sentence**

Replace the first paragraph of `## 8. The api.github.com leg — GitHubApiEnforcer (default-deny, PR-only)`:
```markdown
The worker opens its own PR, which is a REST call (`POST /repos/{o}/{r}/pulls`).
So the `api.github.com` route is routed on the **same** github-app provider as the
git leg, behind `GitHubApiEnforcer`.
```
with:
```markdown
Opening a PR is a REST call (`POST /repos/{o}/{r}/pulls`), and the plan of record
is for the worker to open its own PR through this leg once `mship finish` can
route its PR-open via the relay (today it cannot — see the runbook's
[Opening the PR](unattended-cloud-runner.md#opening-the-pr-why-it-is-a-separate-step-today)).
The `api.github.com` route is therefore already routed on the **same** github-app
provider as the git leg, behind `GitHubApiEnforcer`.
```
Keep the rest of §8 (containment layers, PERMIT/DENY lists) unchanged — it documents the deployed enforcer accurately.

- [ ] **Step 5: Verify no stale claim remains, commit + journal**

```bash
grep -n "worker OPENS\|worker opens its own PR" docs/cloud-worker-auth-spine.md
```
Expected: no output (the only remaining phrasings are the deferential ones above).
```bash
grep -n "Shape 2\|Shape 3" docs/cloud-worker-auth-spine.md
```
Expected: hits only in §3 prose parenthetical, none in headings.
```bash
git add docs/cloud-worker-auth-spine.md
git commit -m "docs: auth-spine defers PR-open truth to the runbook; de-jargon titles"
mship journal "spine: fixed stale worker-opens-PR claims (finish has no relay path - CLI-verified), retitled, Shape jargon out of headings" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: `docs/adapters/claude-routine-runner.md` — retitle + current auth prerequisites

**Files:**
- Modify: `docs/adapters/claude-routine-runner.md`

- [ ] **Step 1: Replace the H1 and add a "Where this fits" intro**

Replace line 1:
```markdown
# Reference Adapter: a Claude Routine as the Unattended-Run Host
```
with:
```markdown
# Pull-API runner: a Claude routine as the unattended-run host

> **Where this fits:** this is the **pull** variant of the
> [unattended cloud runner](../unattended-cloud-runner.md) — instead of
> scheduling one routine per named spec, `mship item run-next` selects and
> claims the next eligible item from a backlog. How the worker *authenticates*
> is an independent choice (see Prerequisites below): any of the three auth
> models works with this selection model.
```

- [ ] **Step 2: Rewrite the `GH_TOKEN` prerequisite bullet**

Replace the `**GH_TOKEN**` bullet under `## Prerequisites` (the one beginning `**GH_TOKEN** (or GITHUB_TOKEN, checked in that order) — a GitHub token with repo scope.`) with:
```markdown
  - **GitHub auth for `bootstrap`/`finish`** — pick ONE of the three auth
    models (full comparison: the runbook's
    [Choosing your setup](../unattended-cloud-runner.md#choosing-your-setup)):
    - **Raw env token** — set `GH_TOKEN` (or `GITHUB_TOKEN`; `--token` wins
      over both, `src/mship/core/gh_auth.py`). Simplest; only for a trusted
      execution environment, since the worker holds a real GitHub credential.
    - **The `/gh-token` broker** — set `MSHIP_GH_BROKER_URL` +
      `MSHIP_SERVE_TOKEN` and the worker pulls short-lived repo-scoped tokens
      from `mship serve` at the moment of use
      ([cloud-agent-auth.md](../cloud-agent-auth.md) §1).
    - **Attach-at-relay** — the worker holds no GitHub credential at all;
      `mship bootstrap --relay-url … --run-token …` routes git through the
      credential-attaching egress proxy
      ([cloud-worker-auth-spine.md](../cloud-worker-auth-spine.md)). Note the
      PR-open caveat: with only a run token, `finish` must run `--push-only`
      and the PR is opened in an attended step (runbook:
      [Opening the PR](../unattended-cloud-runner.md#opening-the-pr-why-it-is-a-separate-step-today)).
```

- [ ] **Step 3: Reconcile the tick-script comment block**

In `## The routine, one tick`, the env-comment block names only `GH_TOKEN`:
```bash
# --- environment the routine must provide ---
#   GH_TOKEN            GitHub token (repo scope); or GITHUB_TOKEN.
#   WORKSPACE_GIT_URL   git URL of the repo containing mothership.yaml.
```
Replace the `GH_TOKEN` comment line with:
```bash
#   <auth>              ONE of: GH_TOKEN / MSHIP_GH_BROKER_URL+MSHIP_SERVE_TOKEN
#                       / relay --relay-url+--run-token (see Prerequisites).
```

- [ ] **Step 4: Verify + commit + journal**

```bash
grep -n "MSHIP_GH_BROKER_URL\|relay-url" docs/adapters/claude-routine-runner.md | head -5
```
Expected: hits in Prerequisites and the tick comment.
```bash
git add docs/adapters/claude-routine-runner.md
git commit -m "docs: pull-API runner prerequisites offer all three auth models"
mship journal "adapter doc: retitled, prerequisites no longer demand raw GH_TOKEN; three auth options with links" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: `docs/unattended-cloud-runner.md` — "Choosing your setup" decision table + sibling naming

**Files:**
- Modify: `docs/unattended-cloud-runner.md`

- [ ] **Step 1: Insert the decision-guide section**

Insert a new section immediately after the "Mental model: three planes" section (before `## One-time setup`):
```markdown
---

## Choosing your setup

Two **independent** choices define a deployment. Pick one from each axis — any
combination works.

**Axis 1 — how the worker authenticates to GitHub:**

| Model | Worker holds | Use when | Doc |
|---|---|---|---|
| Raw env token (`GH_TOKEN`) | a real GitHub token | trusted CI/container you fully control | [pull-API runner prerequisites](adapters/claude-routine-runner.md) |
| The `/gh-token` broker | a serve bearer; pulls short-lived repo-scoped tokens on use | daytime/trusted runs; a machine with `mship serve` is awake | [cloud-agent-auth.md](cloud-agent-auth.md) |
| Attach-at-relay (this runbook's default) | **no GitHub credential** — only a per-run relay token | untrusted, prompt-injectable overnight workers | [cloud-worker-auth-spine.md](cloud-worker-auth-spine.md) |

**Axis 2 — how work is selected:**

| Model | You schedule | Use when | Doc |
|---|---|---|---|
| Per-spec push (this runbook's default) | one routine per named approved spec | you decide each night what runs | this doc, [Per-run lifecycle](#per-run-lifecycle-once-per-approved-spec) |
| Pull-API backlog | one recurring tick; `mship item run-next` picks + claims | you keep an `unattended`-flagged backlog and want it drained | [adapters/claude-routine-runner.md](adapters/claude-routine-runner.md) |

One caveat couples the axes: with attach-at-relay the worker cannot open its own
PR yet — `finish` runs `--push-only` and the PR is opened in an attended step
([Opening the PR](#opening-the-pr-why-it-is-a-separate-step-today)). The other
two auth models let `finish` open the PR directly.
```

- [ ] **Step 2: Align sibling references with the new titles**

In the intro bullet list (lines ~15–22) and `## See also`, update the descriptions to the new H1s (paths unchanged):
- `cloud-worker-auth-spine.md` — "Attach-at-relay: the credential egress proxy (trust model, enforcers, module boundary)."
- `cloud-agent-auth.md` — "The `/gh-token` broker — GitHub auth for trusted cloud sessions, and the GitHub App setup both models share."
- `adapters/claude-routine-runner.md` — "Pull-API runner — a Claude routine as the unattended-run host."
Also in `## Variants: when to use them`, retitle the two bullets' bold leads to
"**The `/gh-token` broker (daytime / trusted, zero App).**" and
"**Pull-API runner — `mship item run-next`.**" (keep existing body text).

- [ ] **Step 3: Verify + commit + journal**

```bash
grep -n "Choosing your setup" docs/unattended-cloud-runner.md
```
Expected: one heading hit (plus any same-doc links).
```bash
git add docs/unattended-cloud-runner.md
git commit -m "docs: runbook gains the two-axis Choosing-your-setup decision table"
mship journal "runbook: decision table (auth model x selection model), sibling titles aligned" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: `docs/cloud-agent-auth.md` — retitle as the `/gh-token` broker doc

**Files:**
- Modify: `docs/cloud-agent-auth.md`

- [ ] **Step 1: Replace the H1 and add a "Where this fits" intro**

Replace line 1:
```markdown
# GitHub Auth for Cloud Agent Sessions
```
with:
```markdown
# The /gh-token broker: GitHub auth for trusted cloud sessions

> **Where this fits:** this is the **simpler** of the two worker-auth models for
> the [unattended cloud runner](unattended-cloud-runner.md) — the worker pulls a
> short-lived GitHub token from `mship serve` at the moment of use, so it briefly
> holds a real credential. For untrusted overnight workers that must never hold
> one, use [attach-at-relay](cloud-worker-auth-spine.md) instead. §2 below (the
> GitHub App setup) is shared by **both** models.
```

- [ ] **Step 2: Disambiguate "broker" on first body use**

In the opening paragraph (`There is a single broker — mship serve's GET /gh-token — …`), change to:
```markdown
There is a single **token broker** — `mship serve`'s `GET /gh-token` (referred to
as "the `/gh-token` broker" across these docs; distinct from the attach-at-relay
egress proxy, which never hands the worker a token) — with two backends, chosen
automatically by whether a GitHub App is configured on the serve host:
```

- [ ] **Step 3: Commit + journal**

```bash
git add docs/cloud-agent-auth.md
git commit -m "docs: retitle cloud-agent-auth as the /gh-token broker doc"
mship journal "cloud-agent-auth: retitled + where-this-fits + broker disambiguation" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: `remote-run.md` stale mention + nav labels + index labels

**Files:**
- Modify: `docs/remote-run.md` (one phrase)
- Modify: `mkdocs.yml` (nav labels)
- Modify: `docs/index.md` (Cloud workers section labels)

- [ ] **Step 1: Fix the stale broker name in `remote-run.md`**

In `## The two-credential model`, replace:
```markdown
or the Phase-1 GitHub token broker for a credential-less/cloud remote
```
with:
```markdown
or the [`/gh-token` broker](cloud-agent-auth.md) for a credential-less/cloud remote
```

- [ ] **Step 2: Update `mkdocs.yml` nav labels (paths unchanged)**

```yaml
  - Cloud workers:
      - Unattended cloud runner: unattended-cloud-runner.md
      - Attach-at-relay egress proxy: cloud-worker-auth-spine.md
      - The /gh-token broker: cloud-agent-auth.md
      - Pull-API runner (Claude routine): adapters/claude-routine-runner.md
```

- [ ] **Step 3: Update `docs/index.md` Cloud workers bullets to match**

```markdown
## Cloud workers

- **[Unattended cloud runner](unattended-cloud-runner.md)** — the end-to-end runbook: setup, per-run lifecycle, security guarantees. Start here.
- **[Attach-at-relay egress proxy](cloud-worker-auth-spine.md)** — the no-credential-on-worker auth model.
- **[The /gh-token broker](cloud-agent-auth.md)** — the simpler trusted-session auth model + GitHub App setup.
- **[Pull-API runner](adapters/claude-routine-runner.md)** — backlog-draining via a scheduled Claude routine.
```

- [ ] **Step 4: Commit + journal**

```bash
git add docs/remote-run.md mkdocs.yml docs/index.md
git commit -m "docs: nav/index labels track retitled cloud-runner docs; fix stale broker name"
mship journal "nav + index labels aligned; remote-run stale Phase-1-broker mention fixed" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: Verification + finish

- [ ] **Step 1: Strict build**

```bash
rm -rf site && uv run --only-group docs mkdocs build --strict && echo BUILD-OK
```
Expected: `BUILD-OK`, zero warnings (all new cross-links + anchors resolve).

- [ ] **Step 2: AC greps**

```bash
# ac1: no doc claims the worker opens its own PR today
grep -rn "worker OPENS\|worker opens its own PR" docs/ --include="*.md" | grep -v plans/ | grep -v specs/
# expected: no output
# ac4: no Shape jargon in headings
grep -rn "^#.*Shape" docs/*.md docs/adapters/*.md
# expected: no output
# ac5: stale name gone
grep -rn "Phase-1 GitHub token broker" docs/
# expected: no output
```

- [ ] **Step 3: Test suite (finish evidence)**

```bash
mship test --repos mothership
```
Expected: pass, exit 0.

- [ ] **Step 4: Record AC evidence (ac1–ac6), then finish**

```bash
mship spec evidence cloud-runner-docs-clarity-pass ac1 <commit> --note "..."
# … one per AC, refs = the task commits …
mship finish
```
Then tidy the PR body with `gh pr edit` and reply on thread `20260725004407-7fec3c0e` with the PR link.
<!-- /mship:task -->

---

## Self-review notes

- **Spec coverage:** ac1 → Task 1 steps 3–5 (+ Task 6 grep); ac2 → Task 2 steps 2–3; ac3 → Task 3 step 1; ac4 → Task 1 steps 1–2, Task 2 step 1, Task 3 step 2, Task 4 step 1 (runbook already opens with its role statement — its intro bullets get title alignment in Task 3); ac5 → Task 4 step 2 + Task 5 step 1 + consistent naming applied across Tasks 1–4; ac6 → Task 5 steps 2–3 + Task 6 step 1.
- **Anchor check:** `#choosing-your-setup` (Task 2 links it) is created in Task 3 — both land before the strict build in Task 6; the existing `#opening-the-pr-why-it-is-a-separate-step-today` and `#per-run-lifecycle-once-per-approved-spec` anchors were verified against the current doc headings.
- **Placeholder scan:** every replacement shown verbatim; Task 6 evidence step intentionally references the commits produced by Tasks 1–5.
