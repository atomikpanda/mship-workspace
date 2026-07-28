---
id: re-vendor-superpowers-620-with-mship
title: Re-vendor superpowers 6.2.0 with mship deltas re-woven and a durable VENDOR.md
  ledger
status: needs_review
created_at: '2026-07-28T12:41:28.140845Z'
updated_at: '2026-07-28T12:41:35.822385Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: 'All fourteen vendored skill directories match 6.2.0 content plus ledgered
    deltas: renames and deletions applied (`task-reviewer-prompt.md` and `re-review-prompt.md`
    present; `spec-reviewer-prompt.md`, `code-quality-reviewer-prompt.md`, `testing-anti-patterns.md`
    absent; `writing-good-tests.md` present), and upstream''s three SDD shell scripts
    are absent with no `.superpowers/` path referenced anywhere in the tree.'
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac2
  text: 'Every ledgered mship delta is re-woven and covered: worktree routing through
    `mship spawn`/WorkItem, finishing mapped to `mship finish`/`mship close` (discard
    via `close --abandon`, merge auto-advance noted), brainstorming''s dual-path spec
    capture, executing-plans'' anchored-task check, subagent-driven-development rebuilt
    on the new structure referencing `mship dispatch` briefs/review-packages/model
    resolution, and `mship debug` integration in systematic-debugging and test-driven-development
    with the anti-patterns pointer updated to `writing-good-tests.md`.'
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac3
  text: '`VENDOR.md` exists at `src/mship/skills/` declaring base 6.2.0 and per-skill
    deltas with rationale, and a guard test fails if a vendored file differs from
    upstream 6.2.0 without a VENDOR.md entry naming it.'
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac4
  text: '`THIRD_PARTY_LICENSES.md` declares superpowers 6.2.0 in the same PR.'
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac5
  text: The four original skills are byte-identical to before the re-vendor, except
    `using-mothership`'s platform-adaptation references point at files that exist
    in the new tree (upstream deleted `copilot-tools.md`).
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac6
  text: The full `tests/skills/` suite passes, extended with guards asserting no `superpowers:`
    namespace prefix, no un-hyphenated `Ultrathink` keyword, and no `.superpowers/`
    path survives in the vendored tree; `mship skill list` and `mship skill install`
    smoke-tested against the new tree.
  verdict: unreviewed
  evidence: []
  comment: null
- id: ac7
  text: 'GitHub issue #437 is closed manually after the PR merges (auto-close never
    touches source issues), with a comment linking both specs'' PRs.'
  verdict: unreviewed
  evidence: []
  comment: null
open_questions: []
non_goals:
- Any change to our four original skills' content beyond `using-mothership`'s platform-adaptation
  pointers (`using-mothership`, `working-with-mothership`, `overnight-cloud-worker-routines`,
  `receiving-messages` are not superpowers-derived).
- "Re-litigating upstream's methodology decisions (reviewer consolidation, no-discard\
  \ finishing menu, compression) \u2014 we take them as shipped; evidence shows naive\
  \ re-trimming hurts weaker models, so no mship-side compression pass on top."
- Vendoring `using-superpowers` or its per-harness bootstrap.
- Building the `mship dispatch` capabilities themselves (companion spec).
risks:
- The subagent-driven-development re-weave is a hand rewrite into a heavily restructured
  upstream file; the consistency guard catches dropped mship invariants mechanically,
  but semantic drift needs the spec-compliance review to read the re-woven skill against
  the ledger.
- Upstream's rewritten finishing-a-development-branch dropped 'discard work' from
  the default menu; our mapping (discard = `mship close --abandon`) must be re-woven
  without reintroducing the removed default.
- 'Skill-consumer breakage on renamed files: anything referencing `testing-anti-patterns.md`
  or the deleted reviewer prompts (docs, tests, other skills) must be swept, not just
  the skills tree.'
- 'Delta ledger rot: VENDOR.md is only useful if the next modification updates it;
  a guard test asserting VENDOR.md mentions every locally-modified file keeps it honest.'
task_slug: null
work_item_id: null
clarification_reason: null
prose_verdicts: {}
---
## Problem

`src/mship/skills/` vendors obra/superpowers 5.0.7 (2026-03-31); upstream is at 6.2.0 (2026-07-23) — one major version and ~4 months of changes that land directly on problems we are hitting (issue #437): a compression campaign trimming exactly the prose Opus 5 over-verifies on, a rewritten subagent-driven-development flow their evals rate ~2x faster at ~50% fewer review tokens, per-dispatch model requirements, controller-coaching bans, read-only reviewers, and a vendor-neutral rewrite that removes Claude-Code-only dialect. A three-way comparison (5.0.7 base vs our tree vs 6.2.0, ledger in the spec's companion delta report) shows our local modifications cluster into four kinds: namespace stripping (dissolves — upstream went harness-neutral itself), mship routing (worktrees/finishing/brainstorming/executing-plans — upstream rewrote these files, toward us), mship subagent anchoring (subagent-driven-development is the one hard conflict: upstream deleted both reviewer prompts we modified and restructured the skill around file-passing scripts), and mship debug integration (clean re-apply). The last re-vendor left no record of what we changed, so #437 had to reverse-engineer our deltas from git archaeology — this one must leave a durable ledger. `THIRD_PARTY_LICENSES.md` still declares 5.0.7. Our `using-mothership` references `references/copilot-tools.md`, which 6.2.0 deleted.

## User story

As the operator running agents across Claude Code, Codex, and other harnesses, I want the bundled skills current with superpowers 6.2.0 while keeping every mship-aware behavior, so that agents get upstream's better-tested, cheaper, harness-neutral methodology without losing workspace discipline.

## Approach

Approach A from the brainstorm: fresh-take plus curated delta ledger. Copy 6.2.0's fourteen skills over the vendored tree wholesale — including deletions and renames (`spec-reviewer-prompt.md` and `code-quality-reviewer-prompt.md` are gone, replaced by `task-reviewer-prompt.md` plus `re-review-prompt.md`; `testing-anti-patterns.md` becomes `writing-good-tests.md`) — then re-apply our deltas from the catalogued ledger, re-weaving rather than patching where upstream rewrote the file. Two deliberate exclusions: upstream's three SDD shell scripts (`sdd-workspace`, `task-brief`, `review-package`) and the `.superpowers/sdd/` scratch convention are NOT vendored — the re-woven subagent-driven-development text references the `mship dispatch` capabilities from the companion dispatch-v2 spec instead (structured store under `.mothership/sdd/`, pointer-stub dispatch, emit-in-subagent-context); and `using-superpowers` stays un-vendored because `using-mothership` is its role-equivalent. Upstream's harness-neutral prose is preserved throughout — re-woven mship sections speak the `mship` CLI, which is harness-agnostic by construction. Model-selection guidance in the re-vendored templates defers to `mship dispatch` resolution instead of asking the controller to choose from prose. A new `VENDOR.md` at `src/mship/skills/` records the base version and every per-skill delta with rationale, so the next re-vendor starts from a ledger instead of archaeology. This work depends on the dispatch-v2 spec landing first so skill text references real commands.

## Delta ledger (input inventory)

The three-way comparison this spec executes against, summarized. Kind 1 — namespace stripping (`superpowers:` prefix removal, path de-branding) across all thirteen modified skills: dropped, upstream 6.0.0's vendor-neutral rewrite makes them moot. Kind 2 — mship routing: using-git-worktrees (spawn + WorkItem-first), finishing-a-development-branch (menu options 1/2/4 mapped to mship, post-finish `mship commit` guidance, merge auto-advance), brainstorming (dual-path capture, spec lifecycle, review-gate messages), executing-plans (anchored-task precondition). Kind 3 — subagent anchoring: subagent-driven-development SKILL.md + implementer-prompt.md (the `mship status` envelope checks, worktree-only work contract, `mship dispatch --plan-task`, `mship test` for evidence), writing-plans (`<!-- mship:task -->` anchors, journal pairing), test-driven-development and verification-before-completion (`mship test` evidence trail), dispatching-parallel-agents (anchored-task + worktree cwd). Kind 4 — mship debug: systematic-debugging's REQUIRED integration section (hypothesis/rule-out/resolved, auto-attach on `mship test`) and TDD's cross-reference. The full file-level diff lives in the #437 working notes and becomes VENDOR.md's first version.
