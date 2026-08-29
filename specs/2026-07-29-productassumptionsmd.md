---
id: productassumptionsmd
title: "product_assumptions.md \u2014 assumption capture, injection & plan-phase coverage\
  \ gate"
status: implemented
created_at: '2026-07-29T10:46:12.947802Z'
updated_at: '2026-07-31T03:26:44.403892Z'
affected_repos:
- mothership
- ground-control
acceptance_criteria:
- id: ac1
  text: "AC-0 (Backtest \u2014 GATES ALL OTHER WORK, ships no product code): pull\
    \ rejected plans from the journal, hand-write the 7 seed rows, run the cold checker\
    \ against BOTH rejected and accepted plans, and report three numbers \u2014 recall\
    \ against our own rejections, false-flag rate on our acceptances, and header-vs-body\
    \ consistency (where a plan states a per-row position, does the plan body actually\
    \ do it). No downstream layer is built until these numbers are acceptable (precision\
    \ prioritized over recall)."
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/4.ground-control
    note: null
  - kind: test
    ref: test-runs/4.mothership
    note: null
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  - kind: test
    ref: test-runs/7.ground-control
    note: null
  - kind: test
    ref: test-runs/7.mothership
    note: null
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  - kind: test
    ref: test-runs/3.mothership
    note: null
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: test
    ref: test-runs/2.ground-control
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac2
  text: 'Wave 1 / L3: the plan template carries an `Assumptions checked:` block that
    dispositions every current assumption row (covered / N/A + one line) in markdown
    before an approach is named; plan structural validation treats a plan that omits
    any current row as not well-formed.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/4.ground-control
    note: null
  - kind: test
    ref: test-runs/4.mothership
    note: null
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  - kind: test
    ref: test-runs/7.ground-control
    note: null
  - kind: test
    ref: test-runs/7.mothership
    note: null
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  - kind: test
    ref: test-runs/3.mothership
    note: null
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: test
    ref: test-runs/2.ground-control
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac3
  text: 'Wave 2 / L1: a workspace-scoped, markdown-canonical assumptions store lives
    in the workspace journal/state dir with an `mship assumptions` CLI (list/add/edit),
    a soft cap of ~20 rows, and a read-only projection into enrollment repos; the
    7 seed rows are populated.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/4.ground-control
    note: null
  - kind: test
    ref: test-runs/4.mothership
    note: null
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  - kind: test
    ref: test-runs/7.ground-control
    note: null
  - kind: test
    ref: test-runs/7.mothership
    note: null
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  - kind: test
    ref: test-runs/3.mothership
    note: null
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: test
    ref: test-runs/2.ground-control
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac4
  text: 'Wave 2 / L2: all assumption rows are injected, unfiltered, adjacent to plan
    generation (not at session start); no trigger-based filtering path exists.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/4.ground-control
    note: null
  - kind: test
    ref: test-runs/4.mothership
    note: null
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  - kind: test
    ref: test-runs/7.ground-control
    note: null
  - kind: test
    ref: test-runs/7.mothership
    note: null
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  - kind: test
    ref: test-runs/3.mothership
    note: null
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: test
    ref: test-runs/2.ground-control
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac5
  text: 'Wave 3 / L4 (agent-run checker + mship record): a fresh-context checker sub-agent,
    given only request + full row set + finished plan, emits per-row covered/not-covered/N-A
    with one line of reason, and its result is recorded via a CLI command; mship performs
    a deterministic in-code trigger cross-check that can only add flags.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/4.ground-control
    note: null
  - kind: test
    ref: test-runs/4.mothership
    note: null
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  - kind: test
    ref: test-runs/7.ground-control
    note: null
  - kind: test
    ref: test-runs/7.mothership
    note: null
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  - kind: test
    ref: test-runs/3.mothership
    note: null
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: test
    ref: test-runs/2.ground-control
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac6
  text: "Wave 3 / L4 (surface + gate): checker output becomes a Ground Control flag\
    \ object, and phase.transition blocks plan\u2192dev until every flag is dispositioned\
    \ \u2014 not-covered + explicit human approval passes, not-covered + silence blocks;\
    \ flags never route back to the planner."
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/4.ground-control
    note: null
  - kind: test
    ref: test-runs/4.mothership
    note: null
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  - kind: test
    ref: test-runs/7.ground-control
    note: null
  - kind: test
    ref: test-runs/7.mothership
    note: null
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  - kind: test
    ref: test-runs/3.mothership
    note: null
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: test
    ref: test-runs/2.ground-control
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac7
  text: 'Wave 4 / L5: rejecting a plan/spec at review prompts for one line on why
    and appends it as a new assumption row.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/4.ground-control
    note: null
  - kind: test
    ref: test-runs/4.mothership
    note: null
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  - kind: test
    ref: test-runs/7.ground-control
    note: null
  - kind: test
    ref: test-runs/7.mothership
    note: null
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  - kind: test
    ref: test-runs/3.mothership
    note: null
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: test
    ref: test-runs/2.ground-control
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac8
  text: 'Wave 5 / L0: metarepo is the default workspace fixture in dev-phase test
    paths and import-linter boundary contracts are in place, enabling rows to graduate
    from the file into fixtures (file size trends down over time).'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/4.ground-control
    note: null
  - kind: test
    ref: test-runs/4.mothership
    note: null
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  - kind: test
    ref: test-runs/7.ground-control
    note: null
  - kind: test
    ref: test-runs/7.mothership
    note: null
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  - kind: test
    ref: test-runs/3.mothership
    note: null
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: test
    ref: test-runs/2.ground-control
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac9
  text: "Ongoing health metrics are observable once live: flag rate (a rate near zero\
    \ is a defect \u2014 periodically feed a known-bad canary plan), header-vs-body\
    \ consistency (stays high), rows graduated to fixtures (trends up), and file size\
    \ (trends down)."
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/4.ground-control
    note: null
  - kind: test
    ref: test-runs/4.mothership
    note: null
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  - kind: test
    ref: test-runs/7.ground-control
    note: null
  - kind: test
    ref: test-runs/7.mothership
    note: null
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  - kind: test
    ref: test-runs/3.mothership
    note: null
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: commit
    ref: 745f165027624710f2865f2a3813569bf041271d
    note: null
  - kind: test
    ref: test-runs/2.ground-control
    note: null
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
open_questions: []
non_goals:
- "mship core / serve calling an LLM itself \u2014 the checker is agent-run and mship\
  \ only records + cross-checks + gates (preserves the LLM-free, driver-agnostic serve\
  \ invariant)."
- "Trigger-scoped injection filtering \u2014 all rows are injected on every plan;\
  \ revisit only if the table exceeds ~25\u201330 rows."
- "Self-review by the planner \u2014 the checker is a separate call with different\
  \ inputs; models correct others but not themselves."
- "Routing checker flags back to the planner for auto-repair \u2014 flags go to a\
  \ human via Ground Control."
- "Restating what the repo already documents \u2014 divergences only; context files\
  \ that duplicate repo docs measurably hurt."
- "Fixing header-ignoring with more forceful prompt language \u2014 shown to give\
  \ inconsistent/negative gains."
- "Splitting this into wave-sequenced sub-issues now \u2014 that follows once the\
  \ backtest result is in."
risks:
- "Checker false-flags spend the scarce resource (operator attention) \u2014 precision\
  \ matters more than recall, so the backtest gates on false-flag rate, not just recall."
- "The L3 header decays into decoration that makes a wrong plan look checked (worse\
  \ than no header) \u2014 guarded by the header-vs-body-consistency metric plus the\
  \ external checker; a drop in that metric is the drift signal."
- "Table growth past ~25\u201330 rows makes injecting-everything stop being free and\
  \ reopens the filtering question (the weakest, fuzziest component)."
- "The checker needing a strong model to infer which rows apply would signal the rows\
  \ are too vague \u2014 a forcing function on file quality, but a real failure mode\
  \ if unmet."
- If D1 resolves toward terminal-developer and phone-operator being two products,
  the single-file-per-workspace assumption forks and needs a cross-repo conflict rule.
task_slug: productassumptionsmd
work_item_id: wi-20260729110356-af39cb2f
clarification_reason: null
prose_verdicts: {}
---
## Problem

Agents building features for mship default to whatever dominates their training distribution, not to what mship actually is. The concrete case: a git feature was planned considering only single-repo and monorepo layouts — metarepo, the product's core differentiator, was never raised. This is not misremembering: the option was never generated, so a bigger model, more thinking budget, or a better overview doc cannot unblock a search that never started. The general class is that the product's defining assumptions contradict the model's default assumptions, and the contradiction is invisible in the output — the resulting plan is internally consistent, passes review-by-reading, and solves the wrong problem correctly. This matters far more once ~10 approved specs fan out overnight onto disposable cloud workers with nobody watching in real time to push back; it is close to a prerequisite for comfortable fan-out, not a nice-to-have.

## User story

As an operator dispatching feature work to agents (increasingly unattended cloud workers), I want the places where mship diverges from a model's default assumptions to be enumerated, injected into every plan, dispositioned exhaustively, and checked by an independent evaluator before plan→dev, so that plans that silently resolve a product-defining assumption the wrong way are caught by a human before they become wrong PRs.

## Approach

A workspace-scoped product_assumptions.md holding DIVERGENCES ONLY — where mship differs from what a competent engineer/model would assume by default; everything the model already believes is omitted (including it is net negative). Each row is an `axis` with `options`, a chosen `position`, and `triggers`. `options` is load-bearing (contrastive enumeration), not `position`; `triggers` is NOT an injection filter — it exists only for L4's deterministic cross-check. Vocabulary split is deliberate: schema field is `axis`; the human-facing word everywhere in UI/plan/Ground Control is `assumption`.

The design is six layers, sequenced so the backtest gates everything and each layer is its own implementation wave.

L0 (endpoint, compile-out): metarepo as the default dev-phase test fixture; import-linter boundary contracts; rows graduate from the file into fixtures over time — the file shrinking is the success signal.

L1 (the file): workspace-scoped, markdown-canonical, stored in the workspace journal/state dir (a metarepo has no canonical repo to hold it), mirroring WorkItemStore/SpecStore; enrollment repos get a read-only projection. Soft cap ~20 rows. New `mship assumptions` CLI (list/add/edit).

L2 (inject all rows, late): every row injected on every plan, unfiltered, adjacent to plan generation (not session-start). Filtering rows by trigger IS pruning — the exact operation the original failure could not recover from — so it is refused until the table exceeds ~25–30 rows. Late (not scoped) injection is for cue proximity.

L3 (plan-template header, disposition-all): the plan artifact carries an `Assumptions checked:` block that dispositions EVERY row before naming an approach, including explicit `N/A`. Markdown, not JSON (enumeration is the goal; structured serialization collapses diversity). Plan structural validity (core/plan.py) is extended so a plan is well-formed only if it dispositions every current row; a wrong N/A is visible and checkable, a silent omission is not.

L4 (checker: externalization first, gate second): the header is not reliably causal on its own, so an external evaluator makes it so. The AGENT runs the checker (mship stays LLM-free / driver-agnostic): the driver spawns a FRESH sub-agent whose only inputs are the original request + the full row set + the finished plan — never the planner's reasoning trace or codebase exploration. It performs closed-form recognition over the fixed list (per row: covered / not-covered / N-A + one line of reason), then records the result back through a CLI command. mship owns, in code and never via a model call: (a) a DETERMINISTIC trigger cross-check that can only ADD flags (e.g. plan touches git/* but marked repo-topology N/A), degrading safely; (b) a small Ground Control flag object; (c) a plan→dev gate in phase.transition that blocks until flags are dispositioned. Not-covered + explicit human approval passes; not-covered + silence blocks. Flags route to the human, NEVER back to the planner (detection and uptake are separable; routing to a human sidesteps the neglect failure mode). No self-review. Header-ignoring is NOT to be fixed with stronger prompt language — externalization is the fix.

L5 (ratchet): on plan/spec rejection at review, prompt for one line on why → append as a row. This is the only mechanism that finds the assumptions we are blind to, because those are exactly the ones we cannot produce at interview time.

Seed rows (7): repo topology (single/mono/meta → meta); credential locus (worker/relay/egress → attach-at-relay); execution locus (local/cloud → both, cloud priority); state durability (in-session/journal → journal); review surface (terminal/async → UNDECIDED, flag it, per D1); agent stream (live/journal-backed → journal-backed); dispatched model (orchestrator-class/weaker → assume weaker). An `undecided` row is not a placeholder — it forces the plan to surface the open choice instead of silently resolving it.

## Row schema & vocabulary

Each row: `axis` (the dimension), `options` (the contrastive list — LOAD-BEARING; stating a position without listing alternatives is a pruned fault tree with one branch left), `position` (the chosen option, or `undecided`), `triggers` (deterministic patterns used ONLY by L4's cross-check, never to filter injection). Schema field names use `axis`; every human-facing surface (UI, plan template, Ground Control) says `assumption` — "3 unchecked assumptions" is legible on a phone with zero briefing; "3 axes not covered" is not. Contrastive not negative: list competing options and mark which holds; bare negation ("not a monorepo") is unreliable. An `undecided` row forces the plan to surface an open choice rather than let whichever agent touches it next resolve it silently.

## Sequencing & wave decomposition

1) Backtest (AC-0) — gate everything on the result. 2) L3 plan-template disposition-all header (markdown). 3) L1 file + L2 late injection of all rows. 4) L4 checker record + deterministic trigger cross-check + Ground Control surface + plan-phase gate. 5) L5 rejection→row ratchet. 6) L0 metarepo fixtures + import-linter contracts. Each numbered step is its own implementation wave/slice; the actual split into sub-issues is deferred until the backtest numbers are in.

## Design constraints (from evidence, not taste)

Flags route to the human, never back to the planner (detection ≠ uptake; neglect dominates auto-repair). No self-review. Divergences only — restating repo docs is worse than silence. Named nouns, not prose — "metarepo" is a retrieval hook, "we value multi-repo work" is not. Contrastive, not negative. Format is instruction — inject a 7-row markdown table, get 7 markdown dispositions; heavy serialization collapses diversity. Option count ≠ option spread — enumerating the DIMENSION breaks fixation, asking for "3 approaches" can return 3 fixated approaches. Externalization (a tool/artifact the actor must traverse), not stronger prompting, is what makes the intermediate structure causal. The same failure+fix recur across fault-tree pruning (Fischhoff 1978), design fixation (Jansson & Smith 1991), analogical transfer (Gick & Holyoak), HAZOP guide words, and Crew Resource Management — all documented in issue #444.

## Deferred decisions (captured, not blocking)

These stay open by design and do not block approval — most become `undecided` rows or plan-time calls: (a) Scope boundary — one file per workspace assumes one product; if D1 (review surface) resolves toward two products this forks and needs a cross-repo conflict rule. (b) Elicitation — the productive question is "where does this differ from what a competent engineer would assume by default?"; onboarding seeds, L5 grows. (c) Checker model size — should run on a cheap model; if it needs a strong model to infer which rows apply, the rows are too vague (a forcing function on file quality). (d) Table-growth threshold — revisit trigger-based filtering past ~25–30 rows; `triggers` is already in the schema for that.

## Prior art

Not novel; the combination is. GitHub Spec Kit constitution.md (governance mechanics aimed at engineering standards, not product divergences; name avoided). Kiro steering product.md (product content, but static, no drift detection). ADRs (architectural, time-triggered, the decided-against graveyard). The Spec Growth Engine (arXiv 2606.27045 — transversal ARCHITECTURE.md as a blocking drift gate; structurally identical motivating example, no evaluation). gstack /plan-ceo-review (right mechanism — forced premise challenge + N-option generation — but general startup judgment, empty of our product's divergences; this spec is the missing substrate). Full reference list (arXiv 2603.16475 driving the L4 reframe, 2607.18476 driving markdown-over-JSON, 2602.11988, 2605.29442, 2607.15388, and the cross-domain psychology literature) is in issue #444.
