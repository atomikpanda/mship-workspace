---
id: agentic-review-for-mothership
title: Agentic review for Mothership repositories
status: implemented
created_at: '2026-08-13T12:30:38.934497Z'
updated_at: '2026-08-13T19:03:55.647964Z'
affected_repos:
- atomikpanda/mothership
- atomikpanda/ground-control
acceptance_criteria:
- id: ac1
  text: One audited Mothership-managed cross-repository chore/task tracks the enrollment
    changes in both `atomikpanda/mothership` and `atomikpanda/ground-control`.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: null
  comment: null
- id: ac2
  text: Each repository contains a valid `.github/workflows/agentic-review.yml` triggered
    on `pull_request` types `opened`, `reopened`, `ready_for_review`, and `synchronize`.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: null
  comment: null
- id: ac3
  text: 'Each caller grants only `contents: read` and `pull-requests: write`, calls
    `atomikpanda/agentic-review/.github/workflows/agentic-review.yml@v1`, maps the
    repository `OPENROUTER_API_KEY` secret, and passes `central_ref: v1`.'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: null
  comment: null
- id: ac4
  text: 'Both callers retain the reusable workflow defaults for inline suggestions
    and comment-only enforcement; no custom model, prompt, skills, or `fail_on_findings:
    true` override is present.'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: null
  comment: null
- id: ac5
  text: One dedicated spend-limited OpenRouter key is stored independently as the
    `OPENROUTER_API_KEY` Actions secret in both repositories without the value appearing
    in repository files, task artifacts, command output, or Actions logs.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: null
  comment: null
- id: ac6
  text: The enrollment pull request in each repository triggers agentic-review and
    completes with a visible review result or comment before merge.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: null
  comment: null
- id: ac7
  text: Both caller configurations leave `fail_on_findings` false or omitted and make
    no branch-protection change, so agentic-review findings remain advisory rather
    than merge-blocking.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: null
  comment: null
- id: ac8
  text: Fork pull requests remain skipped by the reusable workflow and cannot use
    the repository OpenRouter secret.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: null
  comment: null
- id: ac9
  text: The enrollment changes modify only the two caller workflow files; no Mothership
    runtime hook, application code, workspace configuration, PR-Agent configuration,
    custom prompt, model override, or unrelated file is changed.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: null
  comment: null
- id: ac10
  text: 'The rollback procedure is defined in the implementation plan: remove both
    caller workflows, delete both repository secrets, confirm both callers are absent,
    then revoke the shared OpenRouter key; executing rollback is not part of enrollment.'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: null
  comment: null
open_questions: []
non_goals:
- Adding Mothership runtime hooks.
- Changing application code.
- Changing workspace configuration.
- Adding or configuring PR-Agent.
- Changing branch protection.
- Adding a custom prompt.
- Adding a model override.
- Making unrelated changes.
- Running reviews for fork pull requests; these remain skipped by the reusable workflow.
risks:
- A leaked shared OpenRouter key would expose both repositories' review budget; mitigate
  with repository secrets, no logging or persistence, and a provider-side spend limit.
- A moving or mismatched reusable-workflow ref could execute unreviewed central code;
  pin both `uses:` and `central_ref` to `v1`.
- 'Permissions that are too narrow prevent comments, while broader permissions increase
  impact; callers grant only `contents: read` and `pull-requests: write`.'
- Because comment-only mode is not a merge gate, maintainers can merge without addressing
  findings; this is intentional for the initial rollout.
task_slug: null
work_item_id: null
clarification_reason: null
prose_verdicts: {}
---
## Problem

Enroll atomikpanda/mothership and atomikpanda/ground-control in the centralized atomikpanda/agentic-review reusable workflow through one audited, Mothership-managed cross-repository chore/task, with identical pinned caller configuration, controlled credentials, comment-only review behavior, live verification, and a defined rollback.

## User story

As a maintainer of atomikpanda/mothership and atomikpanda/ground-control, I want every same-repository pull request—including Mothership-created and manually created pull requests—to invoke the pinned v1 agentic review workflow so that review findings are posted as non-blocking comments while fork pull requests remain skipped and credentials remain securely managed.

## Approach

Use one audited Mothership-managed cross-repository chore/task to create `.github/workflows/agentic-review.yml` in both `atomikpanda/mothership` and `atomikpanda/ground-control`. In each caller workflow, trigger on `pull_request` events of types `opened`, `reopened`, `ready_for_review`, and `synchronize`; grant only `contents: read` and `pull-requests: write`; call `atomikpanda/agentic-review/.github/workflows/agentic-review.yml@v1`; pass `central_ref: v1`; and provide `OPENROUTER_API_KEY` from the repository Actions secret of the same name. Retain the reusable workflow's default inline suggestion mode and comment-only enforcement by leaving `fail_on_findings` false or at its false default. Create one dedicated, spend-limited OpenRouter key and store the same value independently as the `OPENROUTER_API_KEY` Actions secret in each repository without persisting or logging it. Validate the YAML and verify successful live Actions runs and completed review comments/results on both enrollment pull requests before merging. Roll back by removing both caller workflows and both repository secrets, then revoke the shared OpenRouter key only after both callers have been removed.

## Workflow contract

Each repository's caller workflow must use the same approved contract: `pull_request` types `[opened, reopened, ready_for_review, synchronize]`; permissions `contents: read` and `pull-requests: write`; reusable workflow `atomikpanda/agentic-review/.github/workflows/agentic-review.yml@v1`; input `central_ref: v1`; and secret mapping from the local repository Actions secret `OPENROUTER_API_KEY`.

## Verification sequence

Validate both YAML files, configure the independently stored repository secrets from the single dedicated spend-limited key, run both enrollment pull requests live, confirm successful Actions completion and completed review comments/results, verify `@v1` and `central_ref: v1`, and confirm findings remain non-blocking before merge.

## Rollback sequence

Remove the caller workflow from both repositories, remove each repository's `OPENROUTER_API_KEY` Actions secret, verify that both callers are absent, and then revoke the shared OpenRouter key.
