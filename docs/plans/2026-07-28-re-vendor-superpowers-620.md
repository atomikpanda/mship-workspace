# Re-vendor superpowers 6.2.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the vendored superpowers 5.0.7 skill tree with 6.2.0, re-weave every mship delta from the catalogued ledger, and leave a durable `VENDOR.md` + guard so the next re-vendor starts from a ledger instead of archaeology.

**Architecture:** Approach A (fresh-take + curated delta ledger). Task 1 imports 6.2.0 wholesale — the existing `tests/skills/` guard suite goes red, and that red set *is* the work-list for the re-weave tasks (2–5), which restore each mship behavior into upstream's new structure. Tasks 6–7 handle pointers, licenses, the ledger, and new guards; task 8 verifies end-to-end. Spec: `re-vendor-superpowers-620-with-mship` (7 ACs). Depends on the merged `mship-dispatch-v2` (#439) — the re-woven SDD text references `mship dispatch --emit`, review packages, and `dispatch_models`, all live in mship ≥ 0.5.34.

**Tech Stack:** Markdown skill files, Python guard tests (pytest), bash for the vendor import. All work in the `mothership` repo.

**Sources of truth during the work:**
- Upstream: `git clone https://github.com/obra/superpowers.git /tmp/sp && git -C /tmp/sp worktree add /tmp/sp-620 v6.2.0 && git -C /tmp/sp worktree add /tmp/sp-507 v5.0.7`
- Our per-skill deltas (what to re-weave): `diff -ru /tmp/sp-507/skills/<skill> $(git rev-parse --show-toplevel)/src/mship/skills/<skill>` **run BEFORE task 1's copy** — task 1 saves these diffs to `.mothership/revendor-deltas/` so later tasks read them after the tree changes.
- Upstream's changes (context): `git -C /tmp/sp diff v5.0.7 v6.2.0 -- skills/<skill>`

---

<!-- mship:task id=1 -->
### Task 1: Import vendor 6.2.0 wholesale (deltas snapshotted first)

**Files:**
- Modify: all 13 vendored dirs under `src/mship/skills/` (every dir except `using-mothership`, `working-with-mothership`, `overnight-cloud-worker-routines`, `receiving-messages`)
- Create: `.mothership/revendor-deltas/<skill>.diff` (working artifacts, gitignored — NOT committed)

- [ ] **Step 1: Snapshot our deltas before touching anything**

```bash
cd "$(git rev-parse --show-toplevel)"
git clone --quiet https://github.com/obra/superpowers.git /tmp/sp
git -C /tmp/sp worktree add -q /tmp/sp-507 v5.0.7
git -C /tmp/sp worktree add -q /tmp/sp-620 v6.2.0
mkdir -p .mothership/revendor-deltas
for s in $(ls /tmp/sp-507/skills); do
  [ -d "src/mship/skills/$s" ] && \
    diff -ru "/tmp/sp-507/skills/$s" "src/mship/skills/$s" \
      > ".mothership/revendor-deltas/$s.diff" || true
done
wc -l .mothership/revendor-deltas/*.diff   # expect 13 non-empty (receiving-code-review may be empty)
```

- [ ] **Step 2: Wholesale copy, with the two exclusions**

```bash
for s in $(ls /tmp/sp-620/skills); do
  [ "$s" = "using-superpowers" ] && continue          # ours is using-mothership
  rm -rf "src/mship/skills/$s"
  cp -R "/tmp/sp-620/skills/$s" "src/mship/skills/$s"
done
# Excluded: upstream's SDD shell scripts — mship dispatch replaces them (spec non-goal)
rm -f src/mship/skills/subagent-driven-development/scripts/sdd-workspace \
      src/mship/skills/subagent-driven-development/scripts/task-brief \
      src/mship/skills/subagent-driven-development/scripts/review-package
rmdir src/mship/skills/subagent-driven-development/scripts 2>/dev/null || true
```

- [ ] **Step 3: Verify the file-shape expectations**

```bash
# Renames/deletions landed:
test -f src/mship/skills/test-driven-development/writing-good-tests.md
test ! -f src/mship/skills/test-driven-development/testing-anti-patterns.md
test -f src/mship/skills/subagent-driven-development/task-reviewer-prompt.md
test -f src/mship/skills/subagent-driven-development/re-review-prompt.md
test ! -f src/mship/skills/subagent-driven-development/spec-reviewer-prompt.md
test ! -f src/mship/skills/subagent-driven-development/code-quality-reviewer-prompt.md
test ! -d src/mship/skills/using-superpowers
# Four originals untouched:
git status --porcelain src/mship/skills/using-mothership src/mship/skills/working-with-mothership \
  src/mship/skills/overnight-cloud-worker-routines src/mship/skills/receiving-messages   # expect empty
# Upstream's Ultra-think fix carried over:
! grep -rn "Ultrathink" src/mship/skills/
```

- [ ] **Step 4: Run the guard suite and RECORD the red set**

Run: `uv run pytest tests/skills/ -v`
Expected: **failures are correct here** — the mship-delta guards (`test_skill_dispatch_ergonomics.py` assertions on SDD/writing-plans/implementer-prompt text) go red because the vendor drop wiped our deltas. Record the exact failing test list in the commit message; tasks 2–5 turn them green. Any failure NOT attributable to a wiped mship delta (e.g. an import error) must be fixed now.

- [ ] **Step 5: Commit the pure vendor drop**

```bash
git add -A src/mship/skills/
git commit -m "chore(skills): import superpowers 6.2.0 wholesale (pure vendor drop)

Deltas re-woven in follow-up commits; tests/skills red set at this commit
is the re-weave work-list: <paste failing test names>"
mship journal "task 1: 6.2.0 vendor drop; guard red-set recorded" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: Re-weave — using-git-worktrees + finishing-a-development-branch

**Files:**
- Modify: `src/mship/skills/using-git-worktrees/SKILL.md`, `src/mship/skills/finishing-a-development-branch/SKILL.md`

Read first: `.mothership/revendor-deltas/using-git-worktrees.diff` and `finishing-a-development-branch.diff` (our 5.0.7-era deltas), then the new upstream files in full. Re-weave the *behavior*, not the literal patch — upstream rewrote both files.

- [ ] **Step 1: using-git-worktrees** — restore the mship routing section near the top (after the announce line), adapted to the new structure:
  - "In a mothership workspace" section: `mship spawn` replaces manual worktree creation; every task needs a WorkItem first (`mship item new` → `mship spawn --work-item <id>`; `--hotfix` override is logged); spawn creates the worktree, registers state, runs `task setup`, symlinks `symlink_dirs`. Manual sections apply only outside mship workspaces.
  - Upstream 6.2.0 already prefers in-project `.worktrees/` — do NOT re-add any global-location prose.
  - Pairing note: cleanup routes through `mship close` in mship workspaces.

- [ ] **Step 2: finishing-a-development-branch** — upstream's rewrite dropped "discard work" from the default menu and made PR creation forge-agnostic. Re-weave:
  - Option "push and create PR" → in a mothership workspace run `mship finish --body-file <path>` (writes real Summary/Test-plan body; pushes; opens the PR; stamps state).
  - Post-finish iteration paragraph: `mship commit "<msg>"` for reviewer-feedback fixes (commits + pushes to the existing PR).
  - Merge-locally option: note `mship close` records the merge + cleans the worktree.
  - Discard path: do NOT reintroduce a discard menu item (upstream removed it deliberately); where the skill discusses abandoning work, map it to `mship close --abandon`.
  - Worktree-cleanup section: merge auto-advance note (serve's watcher auto-closes on merge; `mship close` needed only for dirty/unpushed worktrees; `--force` is the only way to delete unpushed work).

- [ ] **Step 3: Verify** — `grep -n "mship spawn" src/mship/skills/using-git-worktrees/SKILL.md`, `grep -n "mship finish\|mship commit\|mship close" src/mship/skills/finishing-a-development-branch/SKILL.md` (all non-empty); re-read both files top-to-bottom for coherence (no orphaned references to removed upstream sections, no contradiction between upstream prose and the mship inserts).

- [ ] **Step 4: Commit**

```bash
git add src/mship/skills/using-git-worktrees src/mship/skills/finishing-a-development-branch
git commit -m "feat(skills): re-weave mship worktree + finishing routing into 6.2.0"
mship journal "task 2: worktrees+finishing re-woven" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: Re-weave — brainstorming + executing-plans + writing-plans

**Files:**
- Modify: `src/mship/skills/brainstorming/SKILL.md`, `spec-document-reviewer-prompt.md`; `src/mship/skills/executing-plans/SKILL.md`; `src/mship/skills/writing-plans/SKILL.md`

Read the three delta files in `.mothership/revendor-deltas/` first, then the new upstream files.

- [ ] **Step 1: brainstorming** — restore the dual-path capture (the biggest 5.0.7 delta, largely structure-independent):
  - Checklist step 6 + Documentation section: in a mothership workspace the design becomes an `mship spec` (`spec new` → `spec draft` → `spec apply` → `needs_review`), else a design doc at `docs/specs/`; the process-flow graph node renamed accordingly.
  - "Where specs live" paragraph (workspace-level, branch-stable, never hand-edit in a worktree).
  - Path-aware User Review Gate messages (spec review via `mship spec review <id>` / the phone).
  - `spec-document-reviewer-prompt.md`: "Dispatch after" line covers both paths.

- [ ] **Step 2: executing-plans** — restore: the mothership pre-flight in Step 1 (verify `mship status` resolves a task; no task → stop, WorkItem + spawn first; cd into the worktree; `require_approved_spec` note) and the finishing note (routes through `mship finish`).

- [ ] **Step 3: writing-plans** — restore: mothership header note (plan input = approved `mship spec`, reference its id); save-location line (`docs_dir` from `mship context`); the anchored-task convention — task blocks wrapped in mship:task comment anchors with id, **plus the 6.2.0-era addition:** anchors may carry `acs=<ac-ids>` mapping a task to the spec criteria it serves; controller pulls a single task with `mship dispatch --task <slug> --plan-task <N>` (stub + `--emit` contract, not inline prompt); the journal-pairing commit-step note; execution-handoff mship notes (implementer prompts built by `mship dispatch`, subagents run `mship test`).
  - CAUTION: when writing example anchors into this skill, keep upstream's formatting; the skill file itself is not parsed as a plan, but plans written FROM it are — preserve upstream's example-fencing style.

- [ ] **Step 4: Verify** — `uv run pytest tests/skills/test_skill_dispatch_ergonomics.py -v`: the writing-plans assertions (`test_writing_plans_documents_task_anchors`, `test_writing_plans_documents_plan_task_dispatch`) now pass; brainstorming/executing-plans have no dedicated guards, so re-read both full files for coherence.

- [ ] **Step 5: Commit**

```bash
git add src/mship/skills/brainstorming src/mship/skills/executing-plans src/mship/skills/writing-plans
git commit -m "feat(skills): re-weave spec-capture + plan-anchor conventions into 6.2.0"
mship journal "task 3: brainstorming+executing-plans+writing-plans re-woven" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: Re-weave — subagent-driven-development + dispatching-parallel-agents (the hard one)

**Files:**
- Modify: `src/mship/skills/subagent-driven-development/SKILL.md`, `implementer-prompt.md`, `task-reviewer-prompt.md`, `re-review-prompt.md`; `src/mship/skills/dispatching-parallel-agents/SKILL.md`

Upstream restructured SDD around its (now-excluded) shell scripts and a single task-reviewer. Re-weave means: keep upstream's *methodology* (one dual-verdict reviewer per task, whole-branch final review, file-passing, per-dispatch model requirement) and replace every mechanism reference with the mship dispatch v2 equivalents that shipped in #439.

- [ ] **Step 1: Read** `.mothership/revendor-deltas/subagent-driven-development.diff` + the new upstream SKILL.md in full + the four prompt files. Also read the shipped CLI contract: `mship dispatch --help` and the "Context isolation (SDD flow)" section of `src/mship/skills/working-with-mothership/SKILL.md` (written in #439 — the SDD skill must AGREE with it, not restate it differently).

- [ ] **Step 2: SKILL.md re-weave**
  - Mothership preamble (from our delta): before dispatching, verify `mship status` resolves an anchored task; the `.active_tasks`/`.resolved_task` envelope walk; subagents work/commit only in the task worktree.
  - Every reference to `scripts/sdd-workspace`, `scripts/task-brief`, `scripts/review-package`, or `.superpowers/sdd/` paths → the mship equivalents: controller runs `mship dispatch --task <slug> --plan-task <N>` (persists the record under `.mothership/sdd/`, prints the closed stub); the subagent's first command is `mship dispatch --emit`; reviewer dispatch is `mship dispatch --mode reviewer` (builds the diff-file package) and the reviewer emits its own prompt the same way. The progress-ledger concept: upstream's ledger lived in sdd scratch — mship's equivalent is the task journal (`mship journal`) + TodoWrite; say so rather than inventing a ledger file.
  - Upstream's per-dispatch model requirement → "the model is resolved by `mship dispatch` (`--model` > `dispatch_models` config > per-mode default) and printed in the stub — pass it to your platform's dispatch mechanism; never let the worker choose."
  - Keep upstream's controller-coaching ban and read-only-reviewer rules verbatim (they match our review contract).
  - Subagents run `mship test` (not bare runners) for the finish evidence gate.
  - `implementer-prompt.md`: restore our pre-dispatch checklist (anchored task, worktree-only work, never commit to main, BLOCKED-if-on-main) adapted to upstream's new template shape; the template's model line defers to the stub's resolved model.
  - `task-reviewer-prompt.md` / `re-review-prompt.md`: adapt file-reference placeholders to review-package paths (manifest + diff files from `mship dispatch --mode reviewer`'s package; skipped-repo disclosure section is produced by the CLI — the template should tell the reviewer to honor it).

- [ ] **Step 3: dispatching-parallel-agents** — restore the short "Mothership Workspace" section (anchored task via `mship status`, per-agent cwd = `.resolved_task.worktrees.<repo>`, agents on main are blocked by the pre-commit hook), placed per the new file structure.

- [ ] **Step 4: Verify** — `uv run pytest tests/skills/test_skill_dispatch_ergonomics.py -v` fully green (SDD guards: `test_sdd_references_plan_task_dispatch`, `test_sdd_uses_mship_test_for_evidence`, `test_implementer_prompt_uses_mship_test`); `grep -rn "sdd-workspace\|task-brief\|review-package\b" src/mship/skills/subagent-driven-development/` → only prose references to mship's review packages, no script invocations; `grep -rn "\.superpowers" src/mship/skills/` → empty.

- [ ] **Step 5: Commit**

```bash
git add src/mship/skills/subagent-driven-development src/mship/skills/dispatching-parallel-agents
git commit -m "feat(skills): rebuild SDD on mship dispatch v2 (stub/emit, review packages, dispatch_models)"
mship journal "task 4: SDD re-woven onto dispatch v2; ergonomics guards green" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: Re-weave — systematic-debugging + TDD + verification + requesting-code-review + writing-skills

**Files:**
- Modify: `src/mship/skills/systematic-debugging/SKILL.md`, `test-driven-development/SKILL.md`, `verification-before-completion/SKILL.md`, `writing-skills/SKILL.md`, `writing-skills/testing-skills-with-subagents.md`; check `requesting-code-review/SKILL.md`

Read the five delta files first. These are clean re-applies — upstream barely touched the sections our deltas live in.

- [ ] **Step 1: systematic-debugging** — restore the "mship integration (REQUIRED when mship is present)" section verbatim from the delta (`mship debug hypothesis`/`rule-out`/`resolved`, auto-attach on `mship test`, the not-available fallback, the why-tight-coupling rationale). Confirm the file still says "Ultra-think" (upstream's fix), not "Ultrathink".

- [ ] **Step 2: test-driven-development** — restore the two mship paragraphs (debug-thread auto-attach; run tests via `mship test` for the finish evidence gate). **Update the anti-patterns pointer:** our delta referenced `testing-anti-patterns.md`; the file is now `writing-good-tests.md` — point the restored text (and verify upstream's own references) there.

- [ ] **Step 3: verification-before-completion** — restore the "Mothership Workspace" section (`mship test` records evidence; `mship finish --require-tests`).

- [ ] **Step 4: writing-skills** — restore: bundled-skills location line (`src/mship/skills/<name>/SKILL.md`, distributed via `mship skill install`) and the deployment-checklist line (run `mship skill install` after committing). Upstream went vendor-neutral, so drop any remaining namespace-stripping parts of our old delta that no longer apply (compare against the delta file hunk-by-hunk).

- [ ] **Step 5: requesting-code-review** — our 5.0.7 delta was pure namespace-stripping + a path fix; upstream's rewrite makes it moot. Verify by reading the delta vs the new file; expected outcome: NO changes needed. If any hunk still applies (the `docs/plans/` path example), apply just that.

- [ ] **Step 6: Verify + commit**

```bash
uv run pytest tests/skills/ -v          # entire suite green from here on
grep -rn "testing-anti-patterns" src/ docs/ tests/ || echo "no stale refs"
git add src/mship/skills
git commit -m "feat(skills): re-apply mship debug/test-evidence integrations into 6.2.0"
mship journal "task 5: debugging/TDD/verification/writing-skills re-woven; guard suite green" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: using-mothership references + THIRD_PARTY_LICENSES

**Files:**
- Modify: `src/mship/skills/using-mothership/SKILL.md`
- Create: `src/mship/skills/using-mothership/references/` (vendored from upstream)
- Modify: `THIRD_PARTY_LICENSES.md` (repo root — verify location with `ls THIRD_PARTY_LICENSES.md`)

- [ ] **Step 1: Establish current state** — `grep -n "references/" src/mship/skills/using-mothership/SKILL.md` and `find src/mship/skills -name "*-tools.md"`. Our Platform Adaptation line names `references/copilot-tools.md` + `references/codex-tools.md`; 6.2.0 deleted copilot-tools.md and reworked the set (codex, gemini, antigravity, pi). Determine whether ANY references/ dir currently exists in our tree (it may have been dangling since 5.0.7).

- [ ] **Step 2: Vendor the 6.2.0 reference files** into `src/mship/skills/using-mothership/references/`:

```bash
mkdir -p src/mship/skills/using-mothership/references
cp /tmp/sp-620/skills/using-superpowers/references/*.md src/mship/skills/using-mothership/references/
```

Update the Platform Adaptation paragraph in using-mothership's SKILL.md to name the actual shipped set (Codex, Gemini, Antigravity, Pi — drop Copilot; keep the Gemini-via-GEMINI.md note only if still accurate per the new gemini-tools.md content, which you must read).

- [ ] **Step 3: THIRD_PARTY_LICENSES.md** — update the superpowers entry to 6.2.0 (version + date + upstream commit `git -C /tmp/sp rev-parse v6.2.0`). Diff `src/mship/skills/SUPERPOWERS_LICENSE` (or wherever the license copy lives — find it) against `/tmp/sp-620/LICENSE`; refresh if upstream's changed.

- [ ] **Step 4: Commit**

```bash
git add src/mship/skills/using-mothership THIRD_PARTY_LICENSES.md
git commit -m "chore(skills): 6.2.0 per-harness references under using-mothership; license bump"
mship journal "task 6: references vendored, licenses bumped" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=7 -->
### Task 7: VENDOR.md ledger + drift guard

**Files:**
- Create: `src/mship/skills/VENDOR.md`
- Create: `src/mship/skills/.upstream-manifest.json`
- Create: `tests/skills/test_vendor_ledger.py`

- [ ] **Step 1: Write the failing guard tests**

```python
# tests/skills/test_vendor_ledger.py
"""The vendor ledger keeps re-vendors honest: every vendored file that differs
from upstream 6.2.0 must be named in VENDOR.md, and banned patterns must never
reappear (spec re-vendor-superpowers-620-with-mship ac3/ac6)."""
import hashlib
import json
from pathlib import Path

SKILLS = Path("src/mship/skills")
MANIFEST = SKILLS / ".upstream-manifest.json"
VENDOR_MD = SKILLS / "VENDOR.md"
ORIGINALS = {"using-mothership", "working-with-mothership",
             "overnight-cloud-worker-routines", "receiving-messages"}

def _sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()

def test_vendor_ledger_names_every_modified_file():
    manifest = json.loads(MANIFEST.read_text())          # {rel_path: upstream_sha}
    ledger = VENDOR_MD.read_text()
    unledgered = []
    for rel, upstream_sha in manifest.items():
        local = SKILLS / rel
        if not local.exists():
            # deliberately-dropped upstream file: must still be ledgered
            if rel not in ledger:
                unledgered.append(f"{rel} (deleted locally, not in VENDOR.md)")
            continue
        if _sha(local) != upstream_sha and rel not in ledger:
            unledgered.append(rel)
    assert not unledgered, f"files diverge from upstream 6.2.0 without a VENDOR.md entry: {unledgered}"

def test_local_files_not_in_manifest_are_ledgered_or_original():
    manifest = json.loads(MANIFEST.read_text())
    ledger = VENDOR_MD.read_text()
    strays = []
    for p in SKILLS.rglob("*"):
        if not p.is_file() or p.name in ("VENDOR.md", ".upstream-manifest.json"):
            continue
        rel = str(p.relative_to(SKILLS))
        if rel.split("/")[0] in ORIGINALS:
            continue
        if rel not in manifest and rel not in ledger:
            strays.append(rel)
    assert not strays, f"local-only vendored files missing from VENDOR.md: {strays}"

def test_banned_patterns_never_reappear():
    banned = ("superpowers:", ".superpowers/", "Ultrathink")
    hits = []
    for p in SKILLS.rglob("*.md"):
        text = p.read_text()
        for b in banned:
            if b in text:
                hits.append(f"{p}: {b}")
    assert not hits, f"banned patterns in vendored tree: {hits}"

def test_no_references_to_deleted_upstream_files():
    gone = ("testing-anti-patterns.md", "spec-reviewer-prompt.md", "code-quality-reviewer-prompt.md")
    hits = []
    for base in (Path("src/mship/skills"), Path("docs")):
        for p in base.rglob("*.md"):
            if p.name == "VENDOR.md":
                continue                                  # the ledger may name them
            text = p.read_text()
            for g in gone:
                if g in text:
                    hits.append(f"{p}: {g}")
    assert not hits, f"stale references to files deleted in 6.2.0: {hits}"
```

Run: `uv run pytest tests/skills/test_vendor_ledger.py -v` — expect FAIL (manifest/ledger missing).

- [ ] **Step 2: Generate the upstream manifest**

```bash
cd "$(git rev-parse --show-toplevel)"
python3 - <<'EOF'
import hashlib, json
from pathlib import Path
up = Path("/tmp/sp-620/skills")
out = {}
for p in sorted(up.rglob("*")):
    if not p.is_file():
        continue
    rel = str(p.relative_to(up))
    if rel.startswith("using-superpowers/") and not rel.startswith("using-superpowers/references/"):
        continue  # not vendored (using-mothership is its role-equivalent)
    # references/ ARE vendored, but under using-mothership/ — record them there:
    rel = rel.replace("using-superpowers/references/", "using-mothership/references/")
    out[rel] = hashlib.sha256(p.read_bytes()).hexdigest()
json.dump(out, open("src/mship/skills/.upstream-manifest.json", "w"), indent=1, sort_keys=True)
print(len(out), "entries")
EOF
```

- [ ] **Step 3: Write VENDOR.md** — header: base `obra/superpowers v6.2.0 (<commit sha>)`, vendored date, the two structural exclusions (SDD scripts — replaced by `mship dispatch` (#439); `using-superpowers` — role filled by `using-mothership`). Then one section per modified skill listing each changed/deleted file and a one-to-three-line rationale per delta (use tasks 2–5's commit messages and the `.mothership/revendor-deltas/` files as the source; the four delta *kinds* from the spec's "Delta ledger" section are the vocabulary). Every file the guard finds divergent must appear by relative path.

- [ ] **Step 4: Iterate until green**

Run: `uv run pytest tests/skills/test_vendor_ledger.py -v` — all 4 pass. The first run's failure list IS the checklist of files VENDOR.md must name; do not silence the test, complete the ledger.

- [ ] **Step 5: Commit**

```bash
git add src/mship/skills/VENDOR.md src/mship/skills/.upstream-manifest.json tests/skills/test_vendor_ledger.py
git commit -m "feat(skills): VENDOR.md delta ledger + upstream-manifest drift guard"
mship journal "task 7: vendor ledger + guards green" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=8 -->
### Task 8: End-to-end verification

**Files:**
- None new (fixes only if verification finds breakage)

- [ ] **Step 1: Full test suite via mship (evidence-recorded)**

Run: `uv run mship test`
Expected: pass. Any failure in `tests/skills/` means a re-weave gap — fix in the responsible skill file, don't weaken the guard.

- [ ] **Step 2: Skill install smoke test**

```bash
uv run mship skill list                      # all skills listed, no parse errors
uv run mship skill install --only claude --yes --force
grep -c "mship dispatch --emit" ~/.claude/skills/subagent-driven-development/SKILL.md   # >= 1
grep -rn "Ultrathink" ~/.claude/skills/ || echo clean
```

- [ ] **Step 3: Dispatch-prompt sanity** — from a workspace with an active task (or a scratch fixture), run `mship dispatch --plan-task <n>` + `--emit` once to confirm the canonical-skills list the prompt embeds still resolves (Task 1 renamed files; `canonical_skills` in `src/mship/core/dispatch.py` names skill DIRS, which didn't change — verify, and check nothing in `src/mship/` references the deleted prompt files: `grep -rn "spec-reviewer-prompt\|code-quality-reviewer-prompt\|testing-anti-patterns" src/`).

- [ ] **Step 4: Commit any fixes + final journal**

```bash
git add -A && git commit -m "fix(skills): post-re-vendor verification fixes" || echo "nothing to fix"
mship journal "task 8: full suite + install smoke green; re-vendor verified" --action "ran tests" --test-state pass
```
<!-- /mship:task -->

---

## Verification against the spec

| Spec AC | Covered by |
|---|---|
| ac1 fourteen dirs match 6.2.0 + deletions/renames, no SDD scripts, no `.superpowers` refs | Tasks 1, 4 (grep gates), 7 (banned-pattern guard) |
| ac2 every ledgered delta re-woven | Tasks 2–5 (per-cluster), guard suite green from task 5 |
| ac3 VENDOR.md + drift guard | Task 7 |
| ac4 THIRD_PARTY_LICENSES 6.2.0 | Task 6 |
| ac5 four originals byte-identical except using-mothership pointers | Task 1 step 3 (git status check), Task 6 |
| ac6 guards: namespace/Ultrathink/.superpowers + skill list/install smoke | Tasks 7, 8 |
| ac7 issue #437 closed after merge with links | Orchestrator, post-merge (manual — auto-close never touches source issues) |
