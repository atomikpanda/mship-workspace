# User-Journey Docs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `user-journey-docs` (approved, dispatched)
**Work item:** `wi-20260725014206-0af4fbc8`
**Worktree:** `/home/bailey/development/repos/mship-workspace/.worktrees/user-journey-docs/mothership`
**Branch:** `feat/user-journey-docs`

**Goal:** Add the user-journey layer to the docs site: a getting-started tutorial, six task-oriented guides under `docs/guides/`, a journey-first landing page, and a restructured nav — every command verified against the current CLI.

**Architecture:** New pages only; existing reference/internals pages untouched except nav position. Source material: README.md (quickstart, cheat sheet, capability tour), docs/concepts.md (object model, gates), docs/cli.md + `--help` output (commands), docs/configuration.md (healthchecks/services), the `working-with-mothership` + `subagent-driven-development` skills (agent guide), and Ground Control flow knowledge (phone guide, kept to stable flows).

**Tech Stack:** Markdown, mkdocs-material (existing), `mkdocs build --strict` gate.

**Command surface verified 2026-07-25 against `uv run mship --help` in the worktree** — groups: Inspection (audit, context, dispatch, doctor, export, pr, reconcile, status, graph, worktrees, debug), Workflow (block, unblock, commit, test, build, heartbeat, journal, phase, switch, spawn, close, finish, depends), Messaging (reply, ask, messages, pair, serve, inbox), Maintenance (prune, sync, bind), Work items & specs (spec, item), plus bootstrap, init, skill, gh, layout, relay. Any command a guide features MUST appear in this list (or its subcommand `--help`).

**Writing rules (apply to every page):**
- Open with one *when-you-need-this* line (guides) or *what-you'll-have-at-the-end* line (tutorial).
- Commands shown as the user would type them; expected output shown as a short representative excerpt, not full transcripts.
- Link to reference pages (cli.md, configuration.md, concepts.md) instead of restating them; link to internals docs only as "how it works" footnotes (ac6: no module paths / enforcer design / trust models in these pages).
- Verify each featured command's flags via `uv run mship <cmd> --help` before writing it down.

---

<!-- mship:task id=1 -->
### Task 1: `docs/getting-started.md` — install to first merged PR

**Files:** Create `docs/getting-started.md`

- [ ] **Step 1: Write the tutorial** with exactly these sections:
  1. **What you'll have at the end** — a workspace, one finished task, one merged PR.
  2. **Install** — `uv tool install git+https://github.com/atomikpanda/mothership.git`; prerequisites line (Python 3.14+, uv; optional go-task, gh) from README.
  3. **Create a workspace** — `cd my-project`, `mship init --name my-project --detect`; expected output excerpt; what `mothership.yaml` + `.mothership/` are (one sentence each, link configuration.md).
  4. **Create a work item** — `mship item new "hello world" --kind chore`; why every task needs one (one sentence, link concepts.md#the-three-gates).
  5. **Spawn the task** — `mship spawn "add hello world" --work-item <id>`; expected output; `cd $(mship status | jq -r '.resolved_task.worktrees | to_entries[0].value')`; what a worktree is (one sentence).
  6. **Do the work** — edit a file, `git add` + `git commit` (or `mship commit`); note the edit-guard protects main checkouts.
  7. **Test** — `mship test`; what dependency-ordered means (one sentence).
  8. **Finish** — `mship finish --body-file -` heredoc from README quickstart; what the gates check (link concepts).
  9. **Merge + close** — merge the PR (gh or web), `mship close`; expected output.
  10. **Where next** — bullets into the six guides.
- [ ] **Step 2: Verify every command** in the page against `uv run mship <cmd> --help` (init, item new, spawn, status, test, finish, close). Fix discrepancies in the page, never invent flags.
- [ ] **Step 3: Commit + journal**
```bash
git add docs/getting-started.md
git commit -m "docs: getting-started tutorial (install to first merged PR)"
mship journal "getting-started.md: install->init->item->spawn->test->finish->merge->close, commands CLI-verified" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: `docs/guides/ship-a-feature.md` + `docs/guides/fix-a-bug.md` — the two core loops

**Files:** Create `docs/guides/ship-a-feature.md`, `docs/guides/fix-a-bug.md`

- [ ] **Step 1: ship-a-feature.md** — *When you need this: building something new that deserves a design.* Sections:
  1. **The loop at a glance** — item (feature) → spec → approve → plan → dispatch/spawn → dev → finish. Reuse concepts.md's lifecycle framing, link it.
  2. **Create the work item** — `mship item new "<title>" --kind feature`.
  3. **Write the spec** — `mship spec new --title ... --id ...` → `mship spec draft <id>` (emits a drafting prompt for your agent) → `mship spec apply <id> --from-json -`; status lands `needs_review`.
  4. **Review + approve** — `mship spec review <id>`, `mship spec approve <id>` (or approve from the phone — link phone-control guide); `mship item link-spec` if the spec wasn't item-linked.
  5. **Plan** — the `writing-plans` skill; plan lives at `<docs_dir>/plans/<date>-<slug>.md` with `mship:task` anchors; `mship item link-plan <id> <path>`.
  6. **Build** — `mship spec dispatch <id>` (binds spec → task + emits handoff) or `mship spawn ... --work-item <id>`; `mship phase dev` and what the three gates check there (link concepts.md#the-three-gates).
  7. **Finish** — `mship finish`; the feature gates at finish; PR bodies carry the ACs.
- [ ] **Step 2: fix-a-bug.md** — *When you need this: something's broken and you want the shortest safe path to a merged fix.* Sections:
  1. **The fast path** — `mship item new "<bug>" --kind bug` → `mship spawn --work-item <id>` → fix → `mship test` → `mship finish`. Bugs/chores skip the spec + plan gates (link concepts).
  2. **Emergencies** — `mship spawn --hotfix` (skips the work-item gate); note bypasses are recorded to the bypass log; still no direct-to-main.
  3. **What stays enforced** — worktree isolation, edit guard, tests surfaced at finish.
- [ ] **Step 3: Verify commands** (`spec new/draft/apply/review/approve/dispatch`, `item new/link-spec/link-plan`, `spawn --hotfix`, `phase`) against their `--help`.
- [ ] **Step 4: Commit + journal**
```bash
git add docs/guides/ship-a-feature.md docs/guides/fix-a-bug.md
git commit -m "docs: ship-a-feature and fix-a-bug guides"
mship journal "guides: ship-a-feature (spec-first loop) + fix-a-bug (fast path, hotfix, what stays enforced)" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: `docs/guides/multi-repo-tasks.md` + `docs/guides/run-and-observe.md` — the coordination + runtime guides

**Files:** Create `docs/guides/multi-repo-tasks.md`, `docs/guides/run-and-observe.md`

- [ ] **Step 1: multi-repo-tasks.md** — *When you need this: one change spans several repos and the PRs have to land coherently.* Sections (source: README "What mship gives agents" + cli.md):
  1. **One task, many worktrees** — `mship spawn "<title>" --work-item <id> --repos a,b,c`; shared feature branch, one worktree per repo.
  2. **Moving between repos** — `mship switch <repo>` (orientation handoff).
  3. **Testing in dependency order** — `mship test` across affected repos; per-repo results.
  4. **Cross-task dependencies** — `mship depends add/list`, `mship spawn --depends-on`, `mship finish --bypass-deps`.
  5. **Finishing** — dependency-ordered PRs with coordination blocks; drift audits (`mship audit`).
- [ ] **Step 2: run-and-observe.md** — *When you need this: you (or your agent) need the system running to see a change work.* Sections (source: README + configuration.md):
  1. **Bring the stack up** — `mship run`; dependency-ordered start, per-service healthchecks (tcp/http/sleep/custom — link configuration.md), task-scoped ports.
  2. **Build artifacts** — `mship build` (dependency order).
  3. **See what's real** — `mship status`, `mship context` (JSON for agents), `mship journal`, `mship graph`, `mship worktrees`.
  4. **Remote execution** — one paragraph pointing at remote-run.md for `--remote` run hosts.
- [ ] **Step 3: Verify commands** (`spawn --repos/--depends-on`, `switch`, `depends`, `audit`, `run`, `build`, `graph`, `worktrees`) against `--help`. NOTE: `run`/`capture` were not in the top-level help groups captured in the header — check `uv run mship run --help` and `uv run mship capture --help` exist before featuring them; if `run` is exposed differently, write what the CLI actually has.
- [ ] **Step 4: Commit + journal**
```bash
git add docs/guides/multi-repo-tasks.md docs/guides/run-and-observe.md
git commit -m "docs: multi-repo-tasks and run-and-observe guides"
mship journal "guides: multi-repo coordination + run/observe (healthchecks, task-scoped state)" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: `docs/guides/phone-control.md` + `docs/guides/agent-driven-development.md`

**Files:** Create `docs/guides/phone-control.md`, `docs/guides/agent-driven-development.md`

- [ ] **Step 1: phone-control.md** — *When you need this: you want to steer work — approve specs, answer questions, merge PRs — away from your desk.* Kept to stable flows (the GC app lives in another repo). Sections:
  1. **Start serve** — `mship serve` (LAN/tailnet) or `mship serve --relay` (anywhere; link relay-hosting.md for self-hosting).
  2. **Pair the phone** — `mship pair` (deep-link + QR), Ground Control adds the workspace.
  3. **What you can do from the phone** — capture ideas (become specs via the brainstorm flow), review + approve specs in the Queue, answer agent questions (decision cards), chat with the agent (mailbox), watch phase progress, review + merge PRs.
  4. **How the agent hears you** — one paragraph: durable mailbox, `mship inbox wait` + turn-boundary drain; the agent replies with `mship reply`/`mship ask`. No internals.
- [ ] **Step 2: agent-driven-development.md** — *When you need this: an AI agent does the building and you want it operating safely inside the workspace.* Sections (source: concepts.md agents section + skills):
  1. **Install the skills** — `mship skill install`; `working-with-mothership` is the canonical agent operating guide.
  2. **What the guardrails give you** — worktree isolation + edit guard + gates, framed as "the agent can't rationalize past them" (link concepts.md; no enforcement internals).
  3. **Orchestrator + subagents** — `mship dispatch --task <slug> --plan-task N` mints self-contained implementer prompts from the plan; two-stage review pattern; keep mship-state writes serial.
  4. **The journal is the memory** — `mship journal` discipline; `mship export` to share a bundle.
- [ ] **Step 3: Verify commands** (`serve`, `pair`, `inbox wait`, `reply`, `ask`, `skill install`, `dispatch --plan-task`, `export`) against `--help`.
- [ ] **Step 4: Commit + journal**
```bash
git add docs/guides/phone-control.md docs/guides/agent-driven-development.md
git commit -m "docs: phone-control and agent-driven-development guides"
mship journal "guides: phone control (serve/pair/GC flows) + agent-driven development (skills, dispatch, journal)" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: Landing page + nav restructure

**Files:** Modify `docs/index.md`, `mkdocs.yml`

- [ ] **Step 1: Rewrite `docs/index.md`** as journey-first: (a) what mship is — three sentences from README's framing (structured interface between agents and a multi-repo system; coordination + isolation + observation); (b) **Start here** → getting-started.md; (c) **Guides by goal** — the six guides with one-line hooks; (d) **Understand it** → concepts.md; (e) **Reference** → cli.md, configuration.md; (f) **Advanced** → Remote access + Cloud workers (one line each). Keep the install one-liner.
- [ ] **Step 2: Restructure `mkdocs.yml` nav** to:
```yaml
nav:
  - Home: index.md
  - Getting started: getting-started.md
  - Guides:
      - Ship a feature: guides/ship-a-feature.md
      - Fix a bug: guides/fix-a-bug.md
      - Multi-repo tasks: guides/multi-repo-tasks.md
      - Run & observe: guides/run-and-observe.md
      - Phone control: guides/phone-control.md
      - Agent-driven development: guides/agent-driven-development.md
  - Concepts: concepts.md
  - Reference:
      - CLI reference: cli.md
      - Configuration: configuration.md
  - Remote access:
      - Serve over Tailscale: mship-serve-tailscale.md
      - Relay hosting: relay-hosting.md
      - Remote run: remote-run.md
  - Cloud workers:
      - Unattended cloud runner: unattended-cloud-runner.md
      - Attach-at-relay egress proxy: cloud-worker-auth-spine.md
      - The /gh-token broker: cloud-agent-auth.md
      - Pull-API runner (Claude routine): adapters/claude-routine-runner.md
```
- [ ] **Step 3: Commit + journal**
```bash
git add docs/index.md mkdocs.yml
git commit -m "docs: journey-first landing page + restructured nav"
mship journal "index.md journey-first; nav = Getting started / Guides / Concepts / Reference / Remote / Cloud" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: Verification + finish

- [ ] **Step 1:** `rm -rf site && uv run --only-group docs mkdocs build --strict && echo BUILD-OK` → expect `BUILD-OK`, zero warnings.
- [ ] **Step 2: AC checks**
```bash
ls docs/guides/           # six files
grep -l "When you need this" docs/guides/*.md | wc -l   # 6
grep -c "getting-started" site/search/search_index.json # >= 1
grep -rn "src/mship\|Enforcer\|trust model" docs/getting-started.md docs/guides/  # expect: no output (ac6)
```
- [ ] **Step 3:** `mship test --repos mothership` → pass.
- [ ] **Step 4:** Record evidence per AC (`mship spec evidence user-journey-docs ac1..ac6 <ref> --note ...`), `mship finish`, tidy PR body, reply on thread `20260725014208-85e6fa8e` with the PR link.
<!-- /mship:task -->

---

## Self-review notes

- **Spec coverage:** ac1 → Task 1; ac2 → Tasks 2–4 (six guides, when-you-need-this enforced by Task 6 grep); ac3 → Task 5 step 1; ac4 → Task 5 step 2 (every existing page present in the nav block above); ac5 → Task 6 steps 1–2; ac6 → writing rule + Task 6 grep.
- **Command verification is a per-task step**, not deferred to the end — a guide is not done until its commands were checked against `--help`.
- **Placeholder scan:** every page's full section structure is specified; prose is authored at build time from the named sources (README/concepts/cli/configuration/skills), which exist and were read.
