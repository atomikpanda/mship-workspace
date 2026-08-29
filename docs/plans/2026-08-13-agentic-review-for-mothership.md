# Agentic Review for Mothership Repositories Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enroll `atomikpanda/mothership` and `atomikpanda/ground-control` in the pinned `atomikpanda/agentic-review@v1` reusable workflow for advisory reviews on every same-repository pull request.

**Spec:** `agentic-review-for-mothership` (approved)

## Assumptions checked

- repo topology — covered: one Mothership task owns sibling worktrees for the independent `mothership` and `ground-control` repositories and commits the same caller contract in each.
- credential locus — covered: one dedicated, provider-spend-limited OpenRouter key is stored independently as the `OPENROUTER_API_KEY` GitHub Actions secret in both repositories.
- execution locus — covered: GitHub-hosted Actions invokes the central reusable workflow on `pull_request`; no Mothership service or local runner participates.
- state durability — covered: caller configuration is versioned in each repository; credential values live only in GitHub Actions secrets and OpenRouter.
- review surface — covered: agentic-review posts inline GitHub pull-request review results and uploads its `agentic-review` artifact.
- agent stream — N/A: this enrollment has no streaming agent session or Ground Control message surface.
- dispatched model — covered: callers deliberately inherit the model and reasoning defaults from pinned `v1`; no repository model override is added.

**Architecture:** A minimal caller workflow is committed to each repository and delegates all review logic to `atomikpanda/agentic-review/.github/workflows/agentic-review.yml@v1`. GitHub owns triggering, permissions, secret delivery, and PR output; Mothership only coordinates the two audited repository changes and opens their PRs.

**Tech Stack:** GitHub Actions reusable workflows, GitHub CLI, OpenRouter repository secrets, Python/PyYAML semantic configuration check.

## Global Constraints

- Trigger exactly `pull_request` activity types `opened`, `reopened`, `ready_for_review`, and `synchronize`.
- Grant only `contents: read` and `pull-requests: write` in each caller.
- Pin both `uses:` and `central_ref` to `v1`; never use `@main`.
- Keep central defaults for inline suggestions and advisory findings; omit `fail_on_findings` so its default remains `false`.
- Use one dedicated, spend-limited OpenRouter key, stored independently under the repository secret name `OPENROUTER_API_KEY` in both repositories.
- Never print, journal, persist, commit, or pass the OpenRouter key as a command-line argument.
- Do not change application code, Mothership runtime hooks, `mothership.yaml`, Taskfiles, PR-Agent, branch protection, prompts, skills, models, or unrelated files.
- Fork PRs remain subject to agentic-review's pinned `v1` skip behavior; never switch to `pull_request_target`.

---

<!-- mship:task id=1 acs=ac5 -->
### Task 1: Provision the shared review credential

**Files:**
- Create: none
- Modify: none
- External state: OpenRouter key; GitHub Actions secrets in `atomikpanda/mothership` and `atomikpanda/ground-control`

**Interfaces:**
- Consumes: an authenticated OpenRouter account and the existing `gh` login with `repo` scope.
- Produces: one dedicated, spend-limited key stored as `OPENROUTER_API_KEY` in both repository secret stores; no readable local copy.

- [ ] **Step 1: Create a dedicated key at OpenRouter**

Open `https://openrouter.ai/settings/keys`, create a key named `agentic-review-mothership`, and apply the smallest provider-side spend limit suitable for the initial rollout. Keep the value only in the password-manager/browser handoff used for the two hidden prompts below.

- [ ] **Step 2: Upload the key to `mothership` without exposing it**

Run interactively; paste the key only at the hidden prompt:

```bash
gh secret set OPENROUTER_API_KEY --repo atomikpanda/mothership
```

Expected: `gh` exits 0 and does not echo the value.

- [ ] **Step 3: Upload the same key to `ground-control`**

Run interactively; paste the same key only at the hidden prompt:

```bash
gh secret set OPENROUTER_API_KEY --repo atomikpanda/ground-control
```

Expected: `gh` exits 0 and does not echo the value.

- [ ] **Step 4: Verify secret metadata, never values**

```bash
gh secret list --repo atomikpanda/mothership --json name --jq 'map(.name) | index("OPENROUTER_API_KEY") != null'
gh secret list --repo atomikpanda/ground-control --json name --jq 'map(.name) | index("OPENROUTER_API_KEY") != null'
```

Expected: both commands print `true`.

- [ ] **Step 5: Journal the external prerequisite**

```bash
mship journal --task agentic-review-for-mothership "provisioned one spend-limited OpenRouter key as OPENROUTER_API_KEY in both repository secret stores; value was not persisted or logged" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 acs=ac1,ac2,ac3,ac4,ac7,ac8,ac9 -->
### Task 2: Add the pinned caller workflow to both repositories

**Files:**
- Create: `mothership/.github/workflows/agentic-review.yml`
- Create: `ground-control/.github/workflows/agentic-review.yml`
- Temporary test: `/tmp/validate-agentic-review.py` (do not commit)

**Interfaces:**
- Consumes: `OPENROUTER_API_KEY` from each repository's GitHub Actions secrets and the reusable workflow contract at `atomikpanda/agentic-review/.github/workflows/agentic-review.yml@v1`.
- Produces: identical repository-local caller workflows with the approved trigger, permission, pinning, secret, and advisory-mode contract.

Run these steps from the `mothership` worktree for task `agentic-review-for-mothership`; its sibling `ground-control` worktree is `../ground-control`.

- [ ] **Step 1: Write the semantic contract check**

Create `/tmp/validate-agentic-review.py` with this exact content:

```python
from pathlib import Path
import sys

import yaml

EXPECTED = {
    "name": "agentic-review",
    "on": {
        "pull_request": {
            "types": ["opened", "reopened", "ready_for_review", "synchronize"],
        },
    },
    "permissions": {
        "contents": "read",
        "pull-requests": "write",
    },
    "jobs": {
        "review": {
            "uses": "atomikpanda/agentic-review/.github/workflows/agentic-review.yml@v1",
            "secrets": {
                "OPENROUTER_API_KEY": "${{ secrets.OPENROUTER_API_KEY }}",
            },
            "with": {
                "central_ref": "v1",
            },
        },
    },
}

for filename in sys.argv[1:]:
    actual = yaml.load(Path(filename).read_text(), Loader=yaml.BaseLoader)
    assert actual == EXPECTED, f"{filename} does not match the approved caller contract"
```

`BaseLoader` is intentional: it parses GitHub's `on` key as a string instead of YAML 1.1 boolean `true`, while still validating syntax and the complete semantic shape.

- [ ] **Step 2: Run the contract check before implementation**

```bash
uv run python /tmp/validate-agentic-review.py \
  .github/workflows/agentic-review.yml \
  ../ground-control/.github/workflows/agentic-review.yml
```

Expected: FAIL with `FileNotFoundError` because neither caller exists yet.

- [ ] **Step 3: Create the caller in `mothership`**

Create `.github/workflows/agentic-review.yml` with exactly:

```yaml
name: agentic-review

on:
  pull_request:
    types: [opened, reopened, ready_for_review, synchronize]

permissions:
  contents: read
  pull-requests: write

jobs:
  review:
    uses: atomikpanda/agentic-review/.github/workflows/agentic-review.yml@v1
    secrets:
      OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}
    with:
      central_ref: v1
```

- [ ] **Step 4: Create the identical caller in `ground-control`**

Create `../ground-control/.github/workflows/agentic-review.yml` with the exact YAML from Step 3. Do not add repository-specific overrides.

- [ ] **Step 5: Run the semantic contract check**

```bash
uv run python /tmp/validate-agentic-review.py \
  .github/workflows/agentic-review.yml \
  ../ground-control/.github/workflows/agentic-review.yml
cmp .github/workflows/agentic-review.yml ../ground-control/.github/workflows/agentic-review.yml
```

Expected: both commands exit 0 with no output.

- [ ] **Step 6: Commit the `mothership` caller**

```bash
git add .github/workflows/agentic-review.yml
git commit -m "ci: add advisory agentic PR review"
```

- [ ] **Step 7: Commit the `ground-control` caller**

Run from `../ground-control`:

```bash
git add .github/workflows/agentic-review.yml
git commit -m "ci: add advisory agentic PR review"
```

- [ ] **Step 8: Journal the cross-repo change**

```bash
mship journal --task agentic-review-for-mothership "added identical v1-pinned advisory agentic-review callers to mothership and ground-control; semantic contract check passes" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 acs=ac6,ac10 -->
### Task 3: Open enrollment PRs and verify live review behavior

**Files:**
- Create: none in either repository
- Temporary PR body: `/tmp/agentic-review-pr-body.md` (do not commit)

**Interfaces:**
- Consumes: both committed caller workflows, both configured repository secrets, and clean task review results.
- Produces: one open enrollment PR per repository with a successful `agentic-review` run and a visible review result; a recorded rollback procedure.

- [ ] **Step 1: Prepare the exact shared PR body**

Create `/tmp/agentic-review-pr-body.md`:

```markdown
## Summary

- enroll this repository in `atomikpanda/agentic-review@v1`
- review every same-repository PR with inline, advisory findings
- grant only source-read and PR-comment permissions

## Verification

- semantic workflow contract check passes
- `uses:` and `central_ref` are both pinned to `v1`
- live agentic-review run and PR result will be verified before merge
```

- [ ] **Step 2: Transition to review and open both PRs**

After the implementation and code-quality reviews approve Task 2:

```bash
mship phase review --task agentic-review-for-mothership
mship finish --task agentic-review-for-mothership --no-require-tests --body-file /tmp/agentic-review-pr-body.md
```

`--no-require-tests` is deliberate: application suites do not exercise a new caller workflow. The semantic checker and live GitHub Actions runs are the relevant evidence.

Expected: `mship finish` pushes `feat/agentic-review-for-mothership` and prints one PR URL for each repository.

- [ ] **Step 3: Wait for the `mothership` agentic-review run**

```bash
gh run watch "$(gh run list --repo atomikpanda/mothership --workflow agentic-review.yml --branch feat/agentic-review-for-mothership --event pull_request --limit 1 --json databaseId --jq '.[0].databaseId')" --repo atomikpanda/mothership --exit-status
```

Expected: the `agentic-review` run exits successfully. Findings may be present, but advisory findings do not fail the run.

- [ ] **Step 4: Wait for the `ground-control` agentic-review run**

```bash
gh run watch "$(gh run list --repo atomikpanda/ground-control --workflow agentic-review.yml --branch feat/agentic-review-for-mothership --event pull_request --limit 1 --json databaseId --jq '.[0].databaseId')" --repo atomikpanda/ground-control --exit-status
```

Expected: the `agentic-review` run exits successfully.

- [ ] **Step 5: Verify visible PR review output in both repositories**

```bash
gh pr view "$(gh pr list --repo atomikpanda/mothership --head feat/agentic-review-for-mothership --state open --json number --jq '.[0].number')" --repo atomikpanda/mothership --json comments,reviews --jq '([.comments[].body, .reviews[].body] | map(select(contains("Agentic review"))) | length) > 0'
gh pr view "$(gh pr list --repo atomikpanda/ground-control --head feat/agentic-review-for-mothership --state open --json number --jq '.[0].number')" --repo atomikpanda/ground-control --json comments,reviews --jq '([.comments[].body, .reviews[].body] | map(select(contains("Agentic review"))) | length) > 0'
```

Expected: both commands print `true`.

If either workflow is missing or fails, do not merge. Inspect the failed run with `gh run view --log-failed`, correct the caller or repository secret, commit the correction, run `mship finish --task agentic-review-for-mothership --force --no-require-tests`, and repeat Steps 3–5.

- [ ] **Step 6: Record verification and rollback order**

```bash
mship journal --task agentic-review-for-mothership "verified successful agentic-review runs and visible advisory PR results in both repositories; rollback order is callers, repository secrets, then shared-key revocation" --action "ran tests"
```

Do not merge automatically. Hand both verified PRs to the maintainer. Rollback, if requested, is ordered: remove both caller workflows, delete `OPENROUTER_API_KEY` from both repository secret stores, confirm both callers are absent, then revoke the shared OpenRouter key.
<!-- /mship:task -->

## Self-Review

- **Spec coverage:** Task 1 covers credential creation and non-disclosure (ac5). Task 2 covers the two-repo task, exact workflow files, triggers, permissions, pinning, advisory defaults, fork-safe event, and strict file scope (ac1–ac4, ac7–ac9). Task 3 covers live PR execution/output and the non-destructive rollback procedure (ac6, ac10).
- **Placeholder scan:** Every file, workflow value, command, branch, repository, secret name, and expected result is concrete. The OpenRouter value is intentionally accepted only through hidden interactive prompts.
- **Type/config consistency:** The temporary semantic checker and both workflow bodies use the same complete mapping; `uses:` and `central_ref` are both `v1`; the secret name is `OPENROUTER_API_KEY` everywhere.
- **Rollback:** Enrollment does not execute rollback. The plan records an exact, safe order that avoids revoking the shared key while either caller remains active.
