# product_assumptions Wave 2 (L1 store + L2 injection) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `productassumptionsmd` (approved/implemented) — this plan implements **ac3 (L1 store)** and **ac4 (L2 injection)**. · **Issue:** atomikpanda/mothership#444 · **Task slug:** `productassumptions-wave-2` · **Builds on Wave 1 (PR #448, merged):** `core/plan.py` already has `SEED_AXES`, `dispositioned_axes`, `missing_assumption_axes`, `_normalize_axis`, `_is_real_disposition`; `cli/plan.py` has the advisory `check-assumptions`.

**Goal:** Give the 7 seed assumptions a real, editable, workspace-scoped home (a markdown doc under `docs/`, optionally encrypted), make it the runtime source of truth (demoting the `SEED_AXES` constant to seed data), and inject the rendered rows deterministically into the plan-phase context so a planning agent always sees them.

**Architecture:** L1 is a single markdown-canonical doc `docs/product_assumptions.md` in the **workspace repo** (its `docs/` dir is a real committed home — the "metarepo has no canonical repo" concern was about *member* repos, not the workspace). Optional at-rest encryption reuses the existing spec encryption core (`core/spec_key.py`, Fernet, `.md.enc`) behind a new `assumption_storage` config knob (committed/local/encrypted), mirroring `spec_storage`. L2 injection is **deterministic**: the plan-phase dispatch/emit assembly appends the rendered table to the planning agent's prompt — the agent can't skip it. No read-only member-repo projection (deterministic injection delivers the rows).

**Tech Stack:** Python 3, mship CLI (Typer), pytest, pydantic, `cryptography`/Fernet (already a dep via spec_key).

## Global Constraints
- **Single source of truth moves to the store.** After this wave, the runtime "which axes are expected" comes from `AssumptionStore`, with `SEED_AXES` used only to *seed* an absent store and as a fallback when no store exists (fresh workspace / unit tests). Do not add a second axis list.
- **Markdown-canonical**, one doc: `<workspace_root>/docs/product_assumptions.md` (or `.md.enc` when encrypted). Row schema columns: `axis | options | position | triggers`.
- **Optional encryption reuses `core/spec_key.py`** (`load_or_generate_key`, `encrypt`, `decrypt`) — do NOT reimplement crypto. New config field `assumption_storage: committed | local | encrypted`, default `committed`, resolved the same way `spec_storage` is.
- **Human word is `assumption`; schema field is `axis`.** `options` is the load-bearing contrastive column.
- **Injection is deterministic and late** — the plan-phase emit path, not session start; all rows, unfiltered (`triggers` is not an injection filter).
- **Soft cap ~20 rows** — warn, don't hard-fail, on save beyond the cap.
- Work happens in the `productassumptions-wave-2` mothership worktree; paths below are repo-relative to `mothership/`. The store *file* lives in the workspace root's `docs/`, addressed via `workspace_root`.
- **Run `mship test` in the FOREGROUND** (never backgrounded) before each commit.

## The 7 seed rows (with the backtest's 4 wording refinements folded in)
Used by `AssumptionStore.seed()`; keep as the single seed definition.
| axis | options | position | triggers |
| -- | -- | -- | -- |
| repo topology | single / mono / meta | **meta** — the *workspace-under-management* is N repos, independent histories, shipped together | git/*, workspace/*, clone, branch, push |
| credential locus | worker / relay / egress host | **attach-at-relay**; worker never holds the real credential | auth, token, push, credential |
| execution locus | local / disposable cloud worker | **both**; cloud is the priority path | run, dispatch, worker, remote |
| state durability | in-session / durable journal | **journal**; must survive process death | state, journal, persist, resume |
| review surface | terminal / async client | **undecided — flag it** (D1). Disposition rule: *covered* when a plan surfaces/respects the open choice; *not-covered* only when it silently declares one surface canonical | review, approve, verdict, UI |
| agent stream | live stream / journal-backed async | **journal-backed**. Scope: all run output (shell + agent), not agent-session output only | stream, output, follow, log |
| dispatched model | orchestrator-class / weaker | **assume weaker**. N/A unless the plan itself dispatches agent work | (applies whenever the plan dispatches agent work) |

## Assumptions checked
*(Dogfooding L3 against this plan.)*
- repo topology — covered; the store lives in the *workspace* repo precisely because a metarepo has no member canonical repo, and the store is workspace-root-scoped.
- credential locus — N/A; no credential handling (encryption key reuses existing spec_key locus).
- execution locus — both; store + CLI + injection run identically local and on a cloud worker (pure file + CLI over workspace files).
- state durability — journal; the store IS durable workspace state (committed doc), surviving process death by construction.
- review surface — undecided (flagged); Wave 2 adds no review surface — the L4 Ground Control flag is a later wave.
- agent stream — N/A; no streaming.
- dispatched model — assume weaker; the `mship assumptions` CLI + deterministic injection are copy/CRUD tasks a weaker model handles; injection removes reliance on the agent remembering to fetch rows.

---

<!-- mship:task id=1 acs=ac3 -->
### Task 1: `AssumptionRow` model + `AssumptionStore` (markdown-canonical, optional encryption)

**Files:**
- Create: `src/mship/core/assumptions.py`
- Test: `tests/core/test_assumptions.py`

**Interfaces:**
- Produces:
  - `AssumptionRow` — fields `axis: str`, `options: str`, `position: str`, `triggers: str` (all plain strings; the table cells).
  - `SEED_ROWS: tuple[AssumptionRow, ...]` — the 7 rows from the table above (single seed definition).
  - `AssumptionStore(workspace_root: Path, *, docs_dir: str = "docs", mode: str = "committed")` with:
    - `path -> Path` — `<workspace_root>/<docs_dir>/product_assumptions.md` (or `+ ".enc"` when `mode == "encrypted"`).
    - `load() -> list[AssumptionRow]` — parse the markdown table (decrypting via `spec_key` when the `.enc` file is present); return `[]` when no file exists.
    - `save(rows: list[AssumptionRow]) -> Path` — render the markdown table + atomic write (encrypt via `spec_key.encrypt` under `encrypted` mode; add `docs/product_assumptions.md` to gitignore under `local`, mirroring `SpecStorage.write`). Emit a warning (return it / log) when `len(rows) > 20`.
    - `seed() -> list[AssumptionRow]` — if no file exists, `save(list(SEED_ROWS))` and return them; else return `load()` (idempotent).
    - `axes() -> list[str]` — normalized axis names (reuse `core.plan._normalize_axis`) in file order.
    - `render() -> str` — the injection block: an `## Assumptions checked`-adjacent context section listing each row as `- <axis> — options: <options> · position: <position>` (human-facing word "assumption" in the header). This is what L2 injects and what a planner dispositions against.
- Consumes: `core.spec_key` (encrypt/decrypt/load_or_generate_key), `core.plan._normalize_axis`.

- [ ] **Step 1: Write the failing tests** (round-trip, encryption, seed idempotency, soft-cap warning, axes):
```python
# tests/core/test_assumptions.py
from pathlib import Path
from mship.core.assumptions import AssumptionRow, AssumptionStore, SEED_ROWS

def test_seed_writes_seven_rows_and_is_idempotent(tmp_path):
    store = AssumptionStore(tmp_path)
    rows = store.seed()
    assert len(rows) == 7
    assert store.path == tmp_path / "docs" / "product_assumptions.md"
    assert store.path.is_file()
    again = AssumptionStore(tmp_path).seed()   # second call: no overwrite, same rows
    assert [r.axis for r in again] == [r.axis for r in rows]

def test_round_trip_preserves_all_columns(tmp_path):
    store = AssumptionStore(tmp_path)
    store.save(list(SEED_ROWS))
    loaded = store.load()
    assert loaded == list(SEED_ROWS)

def test_axes_are_normalized_in_order(tmp_path):
    store = AssumptionStore(tmp_path); store.seed()
    assert store.axes()[0] == "repo topology"
    assert "dispatched model" in store.axes()

def test_encrypted_mode_writes_enc_and_round_trips(tmp_path):
    store = AssumptionStore(tmp_path, mode="encrypted")
    store.save(list(SEED_ROWS))
    assert store.path.name.endswith(".md.enc")
    assert (tmp_path / "docs" / "product_assumptions.md").exists() is False
    assert AssumptionStore(tmp_path, mode="encrypted").load() == list(SEED_ROWS)

def test_load_missing_returns_empty(tmp_path):
    assert AssumptionStore(tmp_path).load() == []

def test_soft_cap_warns_over_twenty(tmp_path):
    rows = [AssumptionRow(axis=f"a{i}", options="x/y", position="x", triggers="t") for i in range(21)]
    store = AssumptionStore(tmp_path)
    warn = store.save(rows)  # returns a warning string (or None under cap)
    assert warn and "20" in warn
```

- [ ] **Step 2: Run to verify they fail.** Run: `uv run pytest tests/core/test_assumptions.py -q` → FAIL (module missing).
- [ ] **Step 3: Implement `src/mship/core/assumptions.py`.** Markdown table parse/render (header row + `| -- |` separator + one row per assumption; escape/۰unescape pipes in cell text — cells here have none, but split on `|` and strip). Encryption: under `encrypted`, `spec_key.load_or_generate_key(workspace_root)` + `spec_key.encrypt/decrypt`, writing `path` with the `.enc` suffix (read decides by suffix like `SpecStorage.decode_file`). Atomic write via a tmp file + `replace` (mirror `SpecStorage._atomic_write_bytes`). `render()` returns the human-facing block.
- [ ] **Step 4: Run to verify pass.** Run: `uv run pytest tests/core/test_assumptions.py -q` → PASS.
- [ ] **Step 5: `mship test` (foreground), commit + journal.**
```bash
mship test
git add src/mship/core/assumptions.py tests/core/test_assumptions.py
git commit -m "feat(assumptions): AssumptionRow + AssumptionStore (markdown doc, optional encryption)"
mship journal "Wave2 L1: AssumptionStore + seed rows" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 acs=ac3 -->
### Task 2: `mship assumptions` CLI (list / add / edit / render) + `assumption_storage` config

**Files:**
- Create: `src/mship/cli/assumptions.py`
- Modify: the CLI app assembly (register `assumptions` alongside `plan`/`spec` — see `cli/__init__.py` where `_plan_mod.register` is called)
- Modify: `src/mship/core/config.py` — add `assumption_storage: Literal["committed","local","encrypted"] = "committed"` to the workspace config model (mirror `spec_storage`), and a resolver mirroring `spec_storage`'s.
- Test: `tests/cli/test_assumptions_cli.py`, and a config test for the new field.

**Interfaces:**
- Consumes: `AssumptionStore`, the resolved `assumption_storage` mode, `container.config_path()` (→ workspace_root + docs_dir), mirroring `cli/plan.py`'s container/Output plumbing.
- Produces: `mship assumptions list` (TTY table / non-TTY JSON `{rows:[{axis,options,position,triggers}], count, path}`), `add --axis --options --position --triggers`, `edit <axis> [--options --position --triggers]`, `render` (prints `AssumptionStore.render()` for L2/manual use). `list` auto-seeds an absent store so a fresh workspace shows the 7 rows.

- [ ] **Step 1: Failing tests** — assert `list` on a fresh workspace returns the 7 seeded rows (JSON), `add` appends a row (reloads and finds it), `edit` changes a position, `render` prints a block containing every axis, and the store honors `assumption_storage: encrypted` from config (writes `.enc`). Mirror `tests/cli/test_plan_check_assumptions.py`'s `_app`/`FakeContainer` harness.
- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement** the `assumptions` group (`register(parent, get_container)` like `cli/plan.py`), the config field + resolver, and wire registration. Resolve mode from config; build `AssumptionStore(workspace_root, docs_dir=..., mode=...)`.
- [ ] **Step 4: Run → pass.**
- [ ] **Step 5: `mship test` (foreground), commit + journal.**
<!-- /mship:task -->

<!-- mship:task id=3 acs=ac3 -->
### Task 3: Source swap — `check-assumptions` reads expected axes from the store

**Files:**
- Modify: `src/mship/cli/plan.py` (`check-assumptions`)
- Test: `tests/cli/test_plan_check_assumptions.py` (extend)

**Interfaces:**
- Consumes: `AssumptionStore.axes()`.
- Behavior: `check-assumptions` computes `expected = AssumptionStore(workspace_root, docs_dir=..., mode=...).axes()` when a store file exists; **falls back to `SEED_AXES`** when it does not (fresh workspace / no docs dir). `missing_assumption_axes(plan_text, expected)` is unchanged (still parameterized — that was Wave 1's whole point). The JSON envelope's `expected` now reflects the live store.

- [ ] **Step 1: Failing test** — with a store seeded then edited to ADD an 8th axis, `check-assumptions` reports that 8th axis as missing for a plan that doesn't disposition it (proving the source is the store, not the constant). With NO store, it still uses `SEED_AXES` (regression).
- [ ] **Step 2–4:** implement the store-or-fallback resolution in `check-assumptions`; run tests.
- [ ] **Step 5:** `mship test` (foreground), commit + journal.
<!-- /mship:task -->

<!-- mship:task id=4 acs=ac4 -->
### Task 4: L2 — deterministic injection of the rendered table into the plan-phase dispatch context

**Files:**
- Modify: the dispatch **emit** assembly that builds a subagent's prompt (locate in `src/mship/cli/dispatch.py` — the `mship dispatch --emit` path that assembles plan-task text + spec ACs + journal). Inject `AssumptionStore(...).render()` into the emitted prompt when the resolved task is in the **plan** phase.
- Test: `tests/cli/test_dispatch.py` (or the emit-specific test module) + a focused injection test.

**Interfaces:**
- Consumes: `AssumptionStore.render()`, the task's phase (`core/phase.py`), the resolved `assumption_storage` mode.
- Behavior: when emitting a prompt for a task whose phase is `plan`, append a clearly-delimited **"Assumptions to disposition"** section = `AssumptionStore.render()` (auto-seeded if absent, decrypted if encrypted). ALL rows, unfiltered. Non-plan phases are unaffected. This is the load-bearing delivery — the planner receives the rows without having to fetch them.

- [ ] **Step 1: Explore + confirm the exact emit function** (`mship dispatch --emit` in `cli/dispatch.py`); identify where the assembled prompt string is finalized and where task phase is available. Note the function name in the journal.
- [ ] **Step 2: Failing test** — emitting a prompt for a plan-phase task includes every seeded axis name in the output; emitting for a non-plan phase does not add the block.
- [ ] **Step 3: Implement** the conditional injection.
- [ ] **Step 4: Run → pass.**
- [ ] **Step 5: `mship test` (foreground), commit + journal.**
<!-- /mship:task -->

---

## Self-Review
- **Spec coverage:** ac3 (L1 store) → Tasks 1–3 (store + CLI + source swap). ac4 (L2 injection) → Task 4. Read-only projection deliberately dropped (deterministic injection supersedes it) — noted for the reviewer.
- **Placeholder scan:** Task 4's emit function is located at implementation time (Step 1) rather than guessed — flagged, not a hidden TODO.
- **Type consistency:** `AssumptionRow(axis,options,position,triggers)`, `AssumptionStore(workspace_root, *, docs_dir, mode)` with `.load/.save/.seed/.axes/.render`, `SEED_ROWS` used consistently across Tasks 1→2→3→4. `axes()` reuses `_normalize_axis`; `missing_assumption_axes` stays parameterized (Wave 1 contract unchanged).
