---
id: mship-dispatch-v2
title: 'mship dispatch v2: model resolution, structured briefs, and context-isolated
  handoff'
status: implemented
created_at: '2026-07-28T12:41:27.387986Z'
updated_at: '2026-07-28T16:40:50.507649Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: '`mship dispatch` resolves the subagent model with precedence flag > `dispatch_models:`
    per-mode map in `mothership.yaml` > built-in per-mode default, and the resolved
    model appears explicitly in the emitted stub and prompt; unit tests cover all
    three precedence levels.'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac2
  text: "A dispatch persists a metadata-only JSON record under `.mothership/sdd/<work-item-id>/<task-slug>/`\
    \ containing a pointer to the canonical content (plan path + anchor id, or the\
    \ ad-hoc instruction) and never a copy of plan task text \u2014 verified by a\
    \ test asserting the record lacks the plan body while the emitted prompt contains\
    \ it."
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac3
  text: "The full prompt is derived at emit time from the canonical plan slice wrapped\
    \ in the shared template, by a command the downstream agent runs itself; the controller-facing\
    \ stub is a closed set of fields (storage key, resolved model, mode, and the one-line\
    \ emit instruction for the subagent) and a test fails if controller-facing stdout\
    \ contains anything beyond them \u2014 no task body, no template boilerplate,\
    \ no acceptance text, no subagent-only prompt content of any kind. Editing the\
    \ plan changes the next emit without touching the store."
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac4
  text: Review-package generation stores a JSON manifest plus raw `git diff` files
    for the task's commit range in the same keyed directory, and the emitted reviewer
    prompt references those file paths instead of embedding the diff.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac5
  text: "No rendered markdown is persisted anywhere under `.mothership/sdd/` \u2014\
    \ the store is metadata JSON plus diff blobs, with markdown emitted to stdout\
    \ on demand."
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac6
  text: '`mship close` removes the task''s `.mothership/sdd/` records as part of worktree
    teardown, and a test proves a closed task leaves no orphan store directory.'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac7
  text: A plan task anchor may declare `acs=<id,...>`; implementer and reviewer emits
    derive the referenced criteria's current text from the spec store (a spec-AC edit
    changes the next emit), and a test asserts the acceptance text appears in emitted
    prompts but in neither the plan body, the dispatch record, nor the review-package
    manifest.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac8
  text: '`tests/skills/test_skill_dispatch_ergonomics.py` is extended to assert the
    new capabilities and passes alongside the existing suite.'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
open_questions: []
non_goals:
- Vendoring or porting upstream's `sdd-workspace` / `task-brief` / `review-package`
  shell scripts, or supporting a `.superpowers/` scratch directory.
- Changing the plan format or storage (plans stay markdown-canonical with `<!-- mship:task
  -->` anchors, human-readable on github.com; no parallel JSON plan store).
- "Snapshotting or versioning plan text in the dispatch store \u2014 the plan file\
  \ is the only copy of plan prose, by design."
- Model enforcement inside the worker (the worker receives a resolved model; policing
  what a harness does with it is out of scope).
- "Re-vendoring the skills themselves \u2014 that is the companion spec, which depends\
  \ on this one."
risks:
- 'CLI surface creep: dispatch grows modes and a store. Mitigated by keeping the record
  schema minimal (pointers + metadata) and flag naming an implementation-plan decision
  reviewed against real skill text in the companion spec.'
- "Derive-at-emit means a plan edited after dispatch changes what the subagent receives\
  \ on its next emit. This is deliberate (the canonical doc wins; base/head SHAs pin\
  \ the code range independently), but a task whose plan is edited mid-flight should\
  \ be re-dispatched \u2014 the emit command surfaces the record's creation time vs\
  \ the plan file's mtime so drift is visible."
- Large diffs make large review packages; the package stores raw diff files so this
  is disk, not context, but a pathological range could still be slow. Acceptable for
  v1.
- Model tier names are harness-specific (e.g. Claude tier aliases vs Codex model ids).
  The config stores operator-chosen strings and passes them through verbatim; mship
  does not validate them against any provider list.
task_slug: null
work_item_id: null
clarification_reason: null
prose_verdicts: {}
---
## Problem

Upstream superpowers 6.2.0 (issue #437) lands two subagent-orchestration mechanisms mship needs but should own at the CLI layer, not in vendored skill prose. First, every dispatch must name a model: upstream found that controllers left to choose stopped naming one, and an unnamed model silently inherits the session's most expensive tier (one of their runs put all 26 reviewers on the top tier). Their fix is a template-level requirement — the controller picks from prose guidance — which is unenforced and re-decided per dispatch. In mship's trust model the model choice belongs to the dispatcher, not the untrusted worker. Second, upstream's rewritten subagent-driven-development passes task text and diffs to subagents as files (their `task-brief` / `review-package` shell scripts writing to `.superpowers/sdd/`), which their evals credit with ~2x faster reviews and ~50% fewer tokens. We are not vendoring those scripts (operator decision): mship reimplements the flow, with one deliberate divergence from upstream — **no duplication of plan content**. Plans stay markdown-canonical with `<!-- mship:task -->` anchors: human-readable, reviewable on github.com, the single source of truth. Upstream's `task-brief` copies task text into a scratch file; ours must not — `mship dispatch --plan-task` already parses the anchored slice and wraps it in the common template, so subagent-facing content is *derived at emit time*, never persisted as a second copy that can drift. Today `mship dispatch` also prints the full subagent prompt to the controller's stdout, so the controller's context pays for every prompt it relays; the benefit we want is that only the downstream agent materializes the prompt in its context.

## User story

As an orchestrating agent in a mothership workspace, I want `mship dispatch` to resolve the subagent's model and hand me only a compact pointer to a dispatch record derived from the canonical plan, so that model choice is enforced in one place, plan content is never duplicated, and neither my context nor the untrusted worker carries what it shouldn't.

## Approach

Three capabilities on the existing `mship dispatch` surface, plus a metadata-only store.

**Model resolution.** `mship dispatch` gains `--model <tier>`. When omitted, the model resolves from a `dispatch_models:` map in `mothership.yaml` keyed by dispatch mode (`implementer`, `reviewer`, `standalone`), falling back to built-in per-mode defaults. Precedence: flag > workspace config > built-in default. The resolved model appears as an explicit `Model:` line in the emitted stub and prompt, and `mship context` exposes the same resolution for programmatic consumers. The untrusted worker never chooses.

**Metadata-only dispatch store — derive, don't duplicate.** A dispatch persists a small JSON record under `.mothership/sdd/<work-item-id>/<task-slug>/`: a *pointer* to the canonical content (plan path + `mship:task` anchor id, or the ad-hoc instruction for non-plan dispatches), plus resolved model, mode, worktree path, base/head SHAs, and timestamps. **No plan text is copied into the store.** The full prompt is derived at emit time: the CLI re-parses the plan's anchored slice (the existing `--plan-task` path) and wraps it in the shared prefix/suffix template that lives in mship — agents never regurgitate boilerplate, and an edited plan is reflected on the next emit because the plan is the only copy. Review packages are the one thing stored as content: a JSON manifest plus raw `git diff` output for the task's commit range, written as files beside the record — diffs are generated artifacts, not duplicated prose, and reading them as files is upstream's measured token-saving mechanism. No rendered markdown is ever persisted; markdown views are emitted on demand, exactly like `spec show` / `item show`. The store lives under `.mothership/` (already gitignored); `mship close` removes a task's records with the worktree.

**Pointer-stub dispatch.** The controller-facing output becomes a compact stub (a few lines: the storage key, the resolved model, and the instruction that the subagent emit its own brief). The full prompt materializes only in the downstream agent's context, via an emit command the subagent runs from inside its worktree (cwd-based task resolution already works there). Reviewer prompts reference the stored diff file paths for the subagent to read directly.

**Reviewer consolidation support.** The review-package flow is shaped for upstream 6.2.0's single task-reviewer contract (one reviewer returning both spec-compliance and quality verdicts, plus one whole-branch review at the end) so the re-vendored SDD skill (companion spec) can reference real commands.

**Task-to-AC mapping via anchor metadata.** A plan task anchor may optionally declare which spec acceptance criteria it serves: `<!-- mship:task id=3 acs=ac2,ac5 -->`. Anchors are HTML comments — invisible in GitHub's render — so the plan stays fully human-readable while carrying the mapping. Emit paths use it for derivation: the implementer prompt includes the referenced criteria's *current* text pulled from the spec store, and the review-package manifest records the AC refs so the reviewer prompt derives the same. Acceptance language is never copied into the plan, the dispatch record, or the package — the spec store remains its only home, the plan the only home of implementation prose, and the spec-compliance half of the task-reviewer's job stops being blind.

Exact flag/subcommand names are an implementation-plan decision; the spec fixes the capabilities, the no-duplication rule, the store layout and keying, the precedence order, and the context-isolation contract.

## Context isolation contract

The design invariant, stated once so every flag decision downstream honors it: **each context pays only for what it owns, and each fact lives in one place.** The plan file owns prose — human-readable markdown with `mship:task` anchors, viewable on github.com; briefs point at it, never copy it. The template (prefix/suffix boilerplate) lives in mship, emitted by the CLI so no agent regurgitates it. The controller owns orchestration — it carries the storage key, the resolved model, and verdicts. The implementer owns the task — it materializes the prompt in its own context by running the emit command from its worktree, which derives the plan slice fresh. The reviewer owns judgment — it reads task text and diffs from files. Nothing is pasted through the controller, and the worker never resolves its own model. This combines upstream 6.2.0's measured file-passing win (~2x faster, ~50% fewer review tokens in their evals) with mship's cloud trust model and single-source-of-truth discipline.
