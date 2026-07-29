# AC-0 Backtest — Cold assumption-coverage checker vs. our own plan corpus

**Feature:** `productassumptionsmd` · **Task 1 / AC-0 (THE GATE)** · **Date:** 2026-07-29
**Ships no product code.** This report's three numbers decide whether Waves 1–5 proceed.

## What this validates

Whether a *cold* assumption-coverage checker — a fresh evaluator that sees only (a) the plan's
own request/goal, (b) a fixed 7-row set of product assumptions, (c) the finished plan text —
actually catches the failure it claims to: a plan that silently resolves a product-defining
assumption the wrong way. The motivating case (atomikpanda/mothership#444) is a git feature
planned for single-repo and monorepo only, never raising **metarepo**, mship's core
differentiator. **Precision (low false-flag rate) matters more than recall**: a checker that
false-flags good plans spends the scarce resource — operator attention.

## Methodology and its central limitation

- **Single-agent, self-blinded run.** Each plan was evaluated by a fresh `general-purpose`
  sub-agent (model: `sonnet`, matching the "assume weaker dispatched model" seed row) that was
  told to read **only** its one plan file plus the 7 rows, with no codebase exploration and no
  knowledge of the accepted/rejected label. The verdicts were locked into the table below
  **before** being joined against the labels to score. This is *not* a truly independent panel
  of blind checkers — one orchestrator dispatched all of them and holds the labels. The operator
  should weight the numbers accordingly. Blindness was preserved structurally (per-plan fresh
  context, label withheld from the sub-agent, verdict-before-join), but the honest caveat stands.
- **The 7 rows are the current mship positions** (see `seed-axes.md`), not the positions that
  held when each historical plan was written. That is deliberate: the feature exists to catch
  divergence from *today's* product truth. It also means a plan can be legitimately ACCEPTED at
  its time and still carry a real divergence from a position that only crystallized later.

## Step 1 — Corpus

### Accepted plans (12, sampled for spread across date + subsystem)

All 12 correspond to specs with status `implemented` (or a spec that shipped) — they merged, so
they are labeled **ACCEPTED**. Spread: git/topology, relay, GC (Android), cloud-worker/credential,
docs, workitem/state, decision/review, execution-locus, cockpit/terminal.

| # | Plan (`docs/plans/…`) | Subsystem | Label basis |
|---|---|---|---|
| 1 | `2026-07-18-mship-init-detect-monorepo.md` | git / repo-topology | spec `implemented` |
| 2 | `2026-07-16-relay-opaque-subdomains.md` | relay | spec `implemented` |
| 3 | `2026-07-13-gc-queue-tab.md` | Ground Control | spec `gc-queue-tab-mos-225` `implemented` |
| 4 | `2026-07-22-cloud-worker-auth-spine.md` | cloud-worker / credential | spec `implemented` |
| 5 | `2026-07-25-user-journey-docs.md` | docs | spec `implemented` |
| 6 | `2026-06-30-workitem-object-model.md` | core / state | shipped (WorkItem model in code) |
| 7 | `2026-07-01-decision-protocol.md` | messaging / review | shipped (decision cards in code) |
| 8 | `2026-07-08-unattended-runner.md` | cloud execution | spec `implemented` |
| 9 | `2026-07-11-remote-run-machine.md` | remote execution | spec `implemented` |
| 10 | `2026-07-17-auto-advance-on-merge.md` | lifecycle | spec `implemented` |
| 11 | `2026-07-21-cockpit-v2.md` | terminal cockpit | spec `implemented` |
| 12 | `2026-07-22-worker-pr-egress.md` | cloud-worker / credential | spec `implemented` |

### Rejected plans — FINDING: the rejected corpus is essentially empty

Mining for genuine review-time rejections turned up almost nothing:

- **No `request-changes` verdicts exist.** Spec statuses across 98 specs: 70 `implemented`,
  17 `approved`, 7 `dispatched`, 2 `draft`, 2 `archived`. No `rejected` / `request-changes` state
  is recorded anywhere.
- **The 2 `draft` specs** (`overnight-fan-out-orchestrator`, `add-node-stepper`) never reached
  review — they are unfinished drafts, not rejections. Not usable as rejected ground truth.
- **The 2 `archived` specs** (`ground-control`, `gc`) are empty placeholder duplicates (no ACs,
  no body) — superseded id collisions, not content rejected at review.
- **Plan git history shows no material rewrites.** Only 2 of 67 plans have >1 commit, and both
  second commits are minor refinements ("de-anchor embedded examples", "record verified FastAPI
  facts"), not post-review rewrites.

**This is a first-class finding.** The workflow does not currently make rejections first-class:
plans are iterated in-session before the first commit, and specs are polished to `approved`
before a plan is written, so the "we rejected this and why" signal is never durably captured.
That is exactly the substrate Wave 4 / L5 (rejection→row ratchet) needs, and it is currently
absent. **Candidate follow-up issue:** make plan/spec rejection a durable, journaled event
(reason line captured) so future backtests have a real rejected corpus and L5 has an input.
No fabricated rejections were added.

### Canary (guaranteed-bad ground truth)

`docs/plans/backtest/canary-metarepo.md` — a synthesized short plan for a git feature
("`mship ship`: branch + commit + push") whose Approach considers only single-repo and monorepo
layouts and never mentions metarepo, and whose credentials come from "the ambient git config on
the machine running the command" (worker-held). Ground truth: **REJECTED / bad** — should be
flagged not-covered on repo topology (and, as it happens, credential locus).

## Step 2 — Seed rows

The 7 hand-authored rows live in `docs/plans/backtest/seed-axes.md` (schema
`axis | options | position | triggers`). They are the single human-authored source that Wave 1's
`SEED_AXES` constant will mirror.

## Step 3 — The exact cold-checker prompt

Each sub-agent received this prompt (only the plan path varied):

> You are an assumption-coverage checker doing closed-form recognition over a fixed list. Read
> ONLY this one file: `<PLAN_PATH>` — do NOT explore the codebase, do NOT read any other file,
> do NOT infer beyond the plan text.
>
> You are given 7 fixed product-assumption rows (axis — options — mship's position):
> 1. repo topology — single-repo / monorepo / metarepo — position: metarepo (N repos,
>    independent histories, shipped together)
> 2. credential locus — worker-held / relay-attached / egress-host — position: attach-at-relay
>    (worker never holds the real credential)
> 3. execution locus — local-only / disposable cloud worker — position: both, cloud is priority
> 4. state durability — in-session / durable journal — position: journal (must survive process death)
> 5. review surface — terminal / async client — position: UNDECIDED (open choice; must be
>    surfaced, not silently resolved)
> 6. agent stream — live stream / journal-backed async — position: journal-backed
> 7. dispatched model — orchestrator-class / weaker — position: assume weaker (all dispatched work)
>
> For EACH of the 7 rows output exactly one line:
> `<row name>: covered | not-covered | N-A — <one-line reason>`
>
> Definitions:
> - **N-A** = the plan's subject matter does not touch this dimension at all (irrelevant). NOT a flag.
> - **covered** = the dimension is relevant AND the plan handles it consistently with the mship
>   position (or, for the undecided row, explicitly surfaces the open choice).
> - **not-covered** = the dimension genuinely governs this plan's work BUT the plan never
>   addresses it, or silently resolves it the WRONG way (against the mship position). This IS a flag.
>
> Be strict about relevance: only mark not-covered when the dimension truly governs this plan's
> work; do not invent relevance (e.g. a docs plan does not govern credential locus merely because
> git exists). Output the 7 lines and nothing else — no preamble.

## Step 4 — Per-plan per-row results

Legend: **C** = covered · **NA** = N-A (not a flag) · **⚑** = not-covered (FLAG). Rows in seed
order: RepoTop · CredLoc · ExecLoc · StateDur · RevSurf · AgentStr · DispModel.

| # | Plan | Label | RepoTop | CredLoc | ExecLoc | StateDur | RevSurf | AgentStr | DispModel | Flags |
|---|---|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| 1 | init-detect-monorepo | ACC | NA | NA | NA | NA | NA | NA | NA | 0 |
| 2 | relay-opaque-subdomains | ACC | NA | NA | NA | C | NA | NA | NA | 0 |
| 3 | gc-queue-tab | ACC | NA | NA | NA | NA | C | C | NA | 0 |
| 4 | cloud-worker-auth-spine | ACC | NA | C | C | NA | NA | NA | C | 0 |
| 5 | user-journey-docs | ACC | C | NA | C | C | C | C | NA | 0 |
| 6 | workitem-object-model | ACC | NA | NA | NA | C | C | NA | NA | 0 |
| 7 | decision-protocol | ACC | C | NA | NA | C | C | C | C | 0 |
| 8 | unattended-runner | ACC | C | **⚑** | C | C | NA | C | C | **1** |
| 9 | remote-run-machine | ACC | C | NA | C | **⚑** | NA | NA | NA | **1** |
| 10 | auto-advance-on-merge | ACC | C | NA | NA | C | NA | C | NA | 0 |
| 11 | cockpit-v2 | ACC | NA | NA | NA | C | NA | C | NA | 0 |
| 12 | worker-pr-egress | ACC | NA | C | NA | NA | NA | NA | C | 0 |
| 13 | **canary-metarepo** | **REJ** | **⚑** | **⚑** | NA | NA | NA | NA | NA | **2** |

One-line reason for every flag (verbatim gist of the checker's own reason):

- **canary · repo topology ⚑** — "scopes to single-repo and monorepo only and never raises
  metarepo, silently resolving against mship's core differentiator." (the exact #444 failure)
- **canary · credential locus ⚑** — "push credentials come from the ambient git config on the
  machine running the command (worker-held), never attach-at-relay."
- **unattended-runner · credential locus ⚑** — "Task 9's adapter has the worker itself hold
  `GH_TOKEN` in env … worker-held, not attach-at-relay."
- **remote-run-machine · state durability ⚑** — "design is stream-only … 'state sync-back'
  explicitly out of scope; over relay this is exactly the disconnect-prone path the journal
  position exists for, ships without any durable record the run survives process/connection death."

## Step 5 — The three numbers

### Recall = 1 / 1 = **100 %** (on a corpus of one — see caveat)

The only ground-truth REJECTED item is the canary; the checker flagged it, on the exact
motivating row (repo topology) plus a second correct catch (credential locus). **Caveat:** the
real rejected corpus is empty (Step 1 finding), so recall is validated only against the synthetic
canary. Recall against genuine historical rejections is **not measurable** until rejections become
first-class. Supporting evidence that the checker's sensitivity is not confined to the canary: it
also raised 2 substantively real divergences on accepted plans (below).

### False-flag rate — the number that matters most

- **Raw flag rate on accepted plans = 2 / 12 = 16.7 %.** Two accepted plans drew a flag.
- **Hallucinated / factually-wrong flags = 0 / 12 = 0 %.** Neither flag misreads the plan. Both
  point at a divergence the plan *actually made* in its own text:
  - `unattended-runner` genuinely puts `GH_TOKEN` on the worker (worker-held credential). This is
    the very divergence that the later `cloud-worker-auth-spine` (attach-at-relay) was built to
    remove — a **high-value, correct catch**, not attention waste.
  - `remote-run-machine` genuinely ships a stream-only remote run with "state sync-back … out of
    scope" — a real divergence from the journal-durability position over a disconnect-prone relay.
- **Worst-case attention-wasting flags ≤ 1 / 12 = 8.3 %.** Only the `remote-run-machine` flag is
  arguably attention-spend, because that plan *consciously* scoped durable state out for v1 — a
  human might answer "yes, known, fine." But even that is the checker doing its job: surfacing a
  deliberate tradeoff to a human ("you're skipping durable state over a flaky link — intended?").
  It is a defensible flag, not a hallucination.

**Bottom line on precision: the checker never invented a divergence.** Every flag corresponds to
real plan text. That is the property a precision-first gate needs.

### Header-vs-body consistency — NOT MEASURABLE on the historical corpus

Zero of the 67 historical plans carry an "Assumptions checked" block (grep confirms only
`2026-07-29-productassumptionsmd.md` — this feature's own plan — has one). So there is no
historical plan that *states* a per-row position whose body we could check against. This metric
**becomes measurable only once L3 ships** and plans start carrying the block.

**Single available data point — this feature's own plan** (`2026-07-29-productassumptionsmd.md`,
which dogfoods a 7-row Assumptions-checked block): its body is consistent with its header on all
7 rows it states (e.g. header "execution locus — both" ↔ body "L3 runs identically locally and on
a disposable cloud worker"; header "review surface — undecided (flagged)" ↔ body keeps D1 open
rather than resolving it). **Consistency = 1 / 1** on the sole data point, flagged as
self-authored and not generalizable.

## Step 6 — Verdict: **GO** (precision-first bar cleared)

**Recommendation: GO — proceed to Wave 1 / L3.**

The two most important reasons:

1. **Precision holds — no hallucinated flags.** The gating number is false-flag rate, and every
   single flag the checker raised (2 on accepted plans, 2 on the canary) corresponds to a real,
   verifiable divergence in the plan text. Worst-case operator-attention waste is ≤ 1/12 (~8 %),
   and that one borderline flag is a legitimate "did you mean to skip durable state?" prompt, not
   noise. A cold sonnet-class checker reading only the plan + 7 rows did not false-alarm on any of
   the 10 clean accepted plans.
2. **It catches the motivating failure on the exact row.** The canary — the #444 metarepo case —
   was flagged not-covered on repo topology (and credential locus), confirming the mechanism
   catches the specific silent-resolution failure the whole feature is premised on.

### Recall caveat is real but does not block GO

Recall is only weakly evidenced (n=1 rejected item), because **the rejected corpus is empty** —
itself the report's headline finding. Precision-first means the gate is on false-flag rate, which
is strong; recall being under-evidenced argues for the L5 rejection-ratchet follow-up, not for a
no-go. The two correct catches on accepted plans are extra evidence the checker's sensitivity
generalizes beyond the canary.

### Seed-row edits the run surfaced (refinements, not blockers)

1. **`agent stream` is ambiguously scoped.** On `remote-run-machine` the checker read "agent
   stream" strictly as *a dispatched Claude agent's* output and marked N-A for the plan's
   shell/go-task `StreamingResponse` output — yet the row's triggers (`stream, output, follow,
   log`) would pull that plan in. Tighten the row to state whether it governs **all** streamed run
   output or **only** Claude-agent session output; the current ambiguity risks missed flags.
2. **`review surface` disposition semantics need spelling out.** Every checker correctly treated
   "builds one surface without claiming exclusivity" as **covered** for the undecided row, and
   would treat "silently declares one surface canonical" as not-covered. That is the right
   behavior, but it is inferred, not stated. Encode it: an `undecided` row is *covered* when the
   plan surfaces/respects the open choice and *not-covered* only when it silently resolves it.
3. **`dispatched model` (empty triggers, "applies to all dispatched work") was inconsistently
   handled** — covered on plans that dispatch subagents, N-A on plans that don't. That is actually
   sensible; make it explicit in guidance so the checker is deterministic: N-A unless the plan
   itself dispatches agent work.
4. **`repo topology` scope.** `init-detect-monorepo` — a plan literally about detecting repo
   topologies — was marked all-N-A because the checker distinguished "mship's own repo layout"
   from "the config shape mship emits for a user's workspace." Clarify the row means the
   **workspace-under-management's** topology; that would correctly flip such a plan to *covered*
   and sharpen the row for L4.

None of these change the GO. They are inputs to the Wave 1 `SEED_AXES` wording and the Wave 3
checker guidance.

---

*Appendix — reproducibility:* corpus enumeration from `ls docs/plans/*.md` (67 plans) and
`git log --oneline --all -- specs/`; labels from spec `status` fields; rejected-corpus dead-ends
verified (`grep` for `request-changes`, per-plan commit counts). Checker = 13 fresh `sonnet`
sub-agents, one per plan, prompt above, verdicts locked before label-join. Single-agent
self-blinded orchestration — see the methodology caveat.
