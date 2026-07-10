# Unattended Runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `unattended-runner` (specs/2026-07-08-unattended-runner.md, status: approved)

**Goal:** Let a scheduler (e.g. a Claude routine) cold-start via `mship bootstrap`, pull the next approved+ready+`unattended` WorkItem, run it to a PR autonomously, and bail-and-checkpoint on a fork — with run-shared state on a git-backed ref so ephemeral cloud runs need no always-on server.

**Architecture:** mship is the host-agnostic control plane; the agent runtime is a swappable execution plane hand-shook via the self-contained `mship dispatch` prompt. v1 = autonomous-to-PR-or-bail; human gates are spec-approval (up front) and PR-review (end). Run-shared state (item `unattended` flag lives in the normal WorkItem store; the run-claim + run-log live on a dedicated orphan git ref) is committed/pushed as checkpoints.

**Tech Stack:** Python 3.14 (pydantic v2, Typer, pytest, fcntl) for mothership; Kotlin/Compose for the Ground Control checkbox.

**Guardrails:** approved-spec precondition, audit + passing tests enforced at `finish`, never merges, git-backed claim prevents double-run.

**Slices (each ships independently, working + tested):**
- A — `unattended` flag (WorkItem field + CLI + GC checkbox) + `mship item run-next` selector.
- B — git-backed run-state ref + run-claim (generalize `core/inbox_lease.py`) + resumable dispatch.
- C — run-loop wiring (`mship item run-next`) + `mship item bail` (bail-on-fork).
- D — reference Claude-routine adapter.

---

## File Structure

**mothership (Python):**
- `src/mship/core/workitem.py` — add `unattended: bool = False` to `WorkItem` (Slice A).
- `src/mship/core/workitem_store.py` — add `set_unattended(item_id, on, now)` (Slice A).
- `src/mship/cli/workitem.py` — add `item unattended <id> [--on/--off]` (Slice A).
- `src/mship/core/run_select.py` — **new**: pure `select_runnable(items, specs, tasks, claims)` → ordered eligible items (Slice A).
- `src/mship/core/run_state.py` — **new**: git-backed run-state store (claim + run-log) on an orphan ref, generalizing the `inbox_lease` lease semantics (Slice B).
- `src/mship/core/run_dispatch.py` — **new**: `resumable_dispatch(spec, task, ...)` folding prior branch/journal into the `mship dispatch` prompt (Slice B).
- `src/mship/core/runner.py` — **new**: `run_once(...)` orchestration = select → claim → dispatch → (host executes) → checkpoint/bail (Slice C).
- `src/mship/cli/workitem.py` — add `mship item run-next` (emit prompt for next eligible + claim) and `mship item bail <id>` (checkpoint-bail) under the existing `item` group — NOT top-level, to avoid colliding with the existing `mship run` (start services) (Slice C).
- `docs/adapters/claude-routine-runner.md` — **new**: reference adapter (Slice D).
- Tests under `tests/core/` and `tests/cli/` mirroring each.

**ground-control (Kotlin):**
- `data/dto/WorkItemDtos.kt` — add `unattended: Boolean = false` to `WorkItemSummary` (Slice A).
- `data/MshipClient.kt` — add `setUnattended(conn, id, on)` → `POST /items/{id}/unattended` (Slice A).
- The item detail cockpit composable — a checkbox bound to `unattended` (Slice A).
- mothership `core/serve.py` — `POST /items/{id}/unattended` endpoint (Slice A).

---

## Slice A — `unattended` flag + selector

<!-- mship:task id=1 -->
### Task 1: Add `unattended` to the WorkItem model

**Files:**
- Modify: `src/mship/core/workitem.py`
- Test: `tests/core/test_workitem.py`

- [ ] **Step 1: Write the failing test**

```python
def test_workitem_unattended_defaults_false_and_roundtrips():
    from mship.core.workitem import WorkItem
    from datetime import datetime, timezone
    now = datetime(2026, 7, 8, tzinfo=timezone.utc)
    wi = WorkItem(id="wi-1", title="t", workspace="ws", kind="feature",
                  created_at=now, updated_at=now)
    assert wi.unattended is False
    dumped = wi.model_dump_json()
    assert WorkItem.model_validate_json(dumped).unattended is False
    wi2 = wi.model_copy(update={"unattended": True})
    assert WorkItem.model_validate_json(wi2.model_dump_json()).unattended is True
```

- [ ] **Step 2: Run it — expect FAIL** (`unattended` unknown)

Run: `uv run pytest tests/core/test_workitem.py::test_workitem_unattended_defaults_false_and_roundtrips -v`
Expected: FAIL (`unattended` is not a field / AttributeError).

- [ ] **Step 3: Add the field**

In `src/mship/core/workitem.py`, in `class WorkItem`, after `external_links`:

```python
    # Opt-in: this item is eligible for unattended (cloud-runner) execution. #unattended-runner
    unattended: bool = False
```

- [ ] **Step 4: Run it — expect PASS**

Run: `uv run pytest tests/core/test_workitem.py -v`
Expected: PASS. Old items without the field load with `unattended=False` (default), so existing state is compatible.

- [ ] **Step 5: Commit + journal**

```bash
git add src/mship/core/workitem.py tests/core/test_workitem.py
git commit -m "feat(workitem): add opt-in unattended flag (unattended-runner slice A)"
mship journal "WorkItem.unattended field added + roundtrip test" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: Store mutator + CLI to set the flag

**Files:**
- Modify: `src/mship/core/workitem_store.py`
- Modify: `src/mship/cli/workitem.py`
- Test: `tests/core/test_workitem_store.py`, `tests/cli/test_workitem.py`

- [ ] **Step 1: Write the failing store test**

```python
def test_set_unattended_toggles(tmp_path):
    from mship.core.workitem_store import WorkItemStore
    from datetime import datetime, timezone
    s = WorkItemStore(tmp_path / "workitems")
    wi = s.create(title="t", kind="feature", workspace="ws", now=datetime(2026,7,8,tzinfo=timezone.utc))
    s.set_unattended(wi.id, True, now=datetime(2026,7,8,1,tzinfo=timezone.utc))
    assert s.get(wi.id).unattended is True
    s.set_unattended(wi.id, False, now=datetime(2026,7,8,2,tzinfo=timezone.utc))
    assert s.get(wi.id).unattended is False
```

- [ ] **Step 2: Run — expect FAIL** (`set_unattended` missing)

Run: `uv run pytest tests/core/test_workitem_store.py::test_set_unattended_toggles -v`

- [ ] **Step 3: Implement the mutator** (mirror existing `_mutate`/`link_spec` pattern in `workitem_store.py`)

```python
    def set_unattended(self, item_id: str, on: bool, now: datetime | None = None) -> None:
        item = self._mutate(item_id, now)
        item.unattended = on
        self._save(item)
```
(Use whatever the file's existing mutate+save helpers are — match `link_spec`.)

- [ ] **Step 4: Run — expect PASS**

Run: `uv run pytest tests/core/test_workitem_store.py -v`

- [ ] **Step 5: Add the CLI command**

In `src/mship/cli/workitem.py`, alongside the other `item_app.command`s:

```python
    @item_app.command("unattended")
    def unattended(item_id: str,
                   on: bool = typer.Option(True, "--on/--off",
                       help="Opt this item into (or out of) unattended runs.")):
        items, _, _, _, _ = _ctx()
        _guard(items, item_id)
        items.set_unattended(item_id, on, now=datetime.now(timezone.utc))
        typer.echo(f"{item_id}: unattended={on}")
```

- [ ] **Step 6: Write + run the CLI test**

```python
def test_item_unattended_cli(tmp_path, ...):  # follow tests/cli/test_workitem.py setup
    # item new -> item unattended <id> --on -> item show shows unattended true
    ...
```
Run: `uv run pytest tests/cli/test_workitem.py -v` — expect PASS.

- [ ] **Step 7: Commit + journal**

```bash
git add src/mship/core/workitem_store.py src/mship/cli/workitem.py tests/
git commit -m "feat(item): set_unattended store mutator + `mship item unattended` CLI"
mship journal "unattended flag settable via store + CLI" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: Pure ready-work selector

**Files:**
- Create: `src/mship/core/run_select.py`
- Test: `tests/core/test_run_select.py`

The selector is pure (no I/O) so it's trivially testable; callers pass loaded items + spec-status lookup + a `claimed` predicate.

- [ ] **Step 1: Write the failing test**

```python
from datetime import datetime, timezone
from mship.core.run_select import select_runnable, Candidate

NOW = datetime(2026, 7, 8, tzinfo=timezone.utc)

def _wi(id, unattended=True, phase="ready", spec="s", created=NOW):
    from mship.core.workitem import WorkItem
    return WorkItem(id=id, title=id, workspace="ws", kind="feature",
                    created_at=created, updated_at=created, spec_id=spec,
                    unattended=unattended, phase_override=phase)

def test_selects_only_eligible_oldest_first():
    items = [
        _wi("wi-new", created=datetime(2026,7,8,2,tzinfo=timezone.utc)),
        _wi("wi-old", created=datetime(2026,7,8,1,tzinfo=timezone.utc)),
        _wi("wi-notflagged", unattended=False),
        _wi("wi-notready", phase="shaping"),
        _wi("wi-nospec", spec=None),
    ]
    spec_approved = {"s": True}                      # spec id -> is approved
    claimed = set()                                  # item ids currently claimed
    out = select_runnable(items, spec_approved, claimed)
    assert [c.item.id for c in out] == ["wi-old", "wi-new"]  # eligible, oldest first

def test_excludes_claimed_and_unapproved_spec():
    items = [_wi("wi-1"), _wi("wi-2", spec="unapproved")]
    assert [c.item.id for c in select_runnable(items, {"s": True, "unapproved": False}, {"wi-1"})] == []
```

- [ ] **Step 2: Run — expect FAIL** (module missing)

Run: `uv run pytest tests/core/test_run_select.py -v`

- [ ] **Step 3: Implement `run_select.py`**

```python
"""Pure selection of the next runnable WorkItem for the unattended runner.

Eligibility: item is `unattended`, its derived/override phase is `ready`, it has a
spec that is `approved`, and it is not currently claimed. Ordered oldest-first so
the backlog drains FIFO. No I/O — callers supply loaded state. #unattended-runner
"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Candidate:
    item: object  # WorkItem


def _phase(item) -> str:
    # v1: the selector reads the item's phase_override; when the derived-phase
    # index lands, swap this for the computed phase. Spec q: ready = derived ready.
    return item.phase_override or "inbox"


def select_runnable(items, spec_approved: dict[str, bool], claimed: set[str]) -> list[Candidate]:
    eligible = [
        it for it in items
        if getattr(it, "unattended", False)
        and _phase(it) == "ready"
        and it.spec_id is not None
        and spec_approved.get(it.spec_id, False)
        and it.id not in claimed
    ]
    eligible.sort(key=lambda it: it.created_at)
    return [Candidate(item=it) for it in eligible]
```

> NOTE (spec open-question q1/phase): `_phase` reads `phase_override` in v1. When the phase-derivation index is wired, replace `_phase` with the derived phase from `build_workitem_index`. Documented, not a placeholder — the function is complete and tested as written.

- [ ] **Step 4: Run — expect PASS**

Run: `uv run pytest tests/core/test_run_select.py -v`

- [ ] **Step 5: Commit + journal**

```bash
git add src/mship/core/run_select.py tests/core/test_run_select.py
git commit -m "feat(runner): pure ready-work selector (select_runnable)"
mship journal "selector: eligible = unattended + ready + approved-spec + unclaimed, oldest-first" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: Ground Control checkbox (serve endpoint + DTO + UI)

**Files:**
- Modify (mothership): `src/mship/core/serve.py` (add `POST /items/{id}/unattended`)
- Modify (ground-control): `data/dto/WorkItemDtos.kt`, `data/MshipClient.kt`, item detail composable
- Test: `tests/core/test_serve.py` (endpoint); GC `WorkItemDtosTest.kt` (field parse)

- [ ] **Step 1: Serve endpoint test (mothership)** — follow `test_serve.py` patterns

```python
def test_post_item_unattended(tmp_path):
    # create item, POST /items/{id}/unattended {"on": true}, assert store shows unattended
    ...
```

- [ ] **Step 2: Run — expect FAIL**, then implement in `serve.py` (mirror other `/items/{id}/...` handlers; write via `workitems.set_unattended` under the existing item lock):

```python
    class UnattendedBody(BaseModel):
        on: bool = True

    @app.post("/items/{item_id}/unattended")
    def post_unattended(item_id: str, body: UnattendedBody):
        with _item_msg_lock:                       # reuse the item write lock
            try:
                workitems.set_unattended(item_id, body.on, now=datetime.now(timezone.utc))
            except KeyError:
                raise HTTPException(status_code=404, detail=f"no work item {item_id!r}")
        return {"id": item_id, "unattended": body.on}
```
Run: `uv run pytest tests/core/test_serve.py -v` — PASS.

- [ ] **Step 3: GC DTO field + parse test** — in `WorkItemDtos.kt` add `val unattended: Boolean = false` to `WorkItemSummary`; add a `WorkItemDtosTest` case parsing `"unattended":true`. Run the JVM unit tests (`mship test --repos ground-control`).

- [ ] **Step 4: GC client** — in `MshipClient.kt`:

```kotlin
suspend fun setUnattended(conn: WorkspaceConnection, id: String, on: Boolean) =
    post(conn, "/items/$id/unattended", mapOf("on" to on))
```

- [ ] **Step 5: GC checkbox** — on the item detail cockpit, a Material `Checkbox`/`Switch` bound to `item.unattended`, calling `vm.setUnattended(...)` on toggle (mirror the existing action wiring, e.g. how Steer/verdict calls are made). Build: `mship build --repos ground-control` (BUILD SUCCESSFUL).

- [ ] **Step 6: Commit + journal** (one commit per repo via `mship commit` if coordinating, else per worktree)

```bash
mship journal "unattended checkbox: serve endpoint + GC DTO/client/UI" --action committed
```
<!-- /mship:task -->

---

## Slice B — git-backed run-state + claim + resumable dispatch

<!-- mship:task id=5 -->
### Task 5: Git-backed run-state store (claim + run-log)

**Files:**
- Create: `src/mship/core/run_state.py`
- Test: `tests/core/test_run_state.py`

Run-state lives on a dedicated **orphan branch** (`refs/heads/mship-run-state`, spec q1) in the workspace repo's origin: per-item claim files + an append-only run-log. Generalizes `inbox_lease` claim semantics (pid+heartbeat → here holder-token + heartbeat, reclaimable when stale) but persisted via git so ephemeral runs share it. Concurrency: per-item files + commit + push-with-rebase-retry (pull --rebase then re-push on non-fast-forward).

- [ ] **Step 1: Write failing tests** (use a local bare repo as "origin" — mirror `tests/util/test_git.py` fixtures)

```python
def test_claim_is_exclusive_and_reclaimable(tmp_origin):
    from mship.core.run_state import RunStateRepo
    from datetime import datetime, timedelta, timezone
    T0 = datetime(2026,7,8,tzinfo=timezone.utc)
    a = RunStateRepo(tmp_origin, workdir=..., ttl_seconds=30)
    b = RunStateRepo(tmp_origin, workdir=..., ttl_seconds=30)
    assert a.try_claim("wi-1", holder="runA", now=T0) is None          # A wins
    assert b.try_claim("wi-1", holder="runB", now=T0+timedelta(seconds=1)) is not None  # B refused
    # stale reclaim: past TTL, B can take over
    assert b.try_claim("wi-1", holder="runB", now=T0+timedelta(seconds=31)) is None
    a.release("wi-1", holder="runB")  # non-holder no-op
    assert a.read_claim("wi-1").holder == "runB"

def test_run_log_appends_and_persists(tmp_origin):
    r = RunStateRepo(tmp_origin, workdir=...)
    r.append_log("wi-1", "run started", now=...)
    r.append_log("wi-1", "bailed: fork on auth approach", now=...)
    entries = RunStateRepo(tmp_origin, workdir=...).read_log("wi-1")   # fresh clone sees them
    assert [e.text for e in entries] == ["run started", "bailed: fork on auth approach"]
```

- [ ] **Step 2: Run — expect FAIL** (module missing)

- [ ] **Step 3: Implement `run_state.py`** — key shape (reuse `util/git.py` runner; claim record = `{holder, heartbeat_at}` JSON per item; the exclusivity/reclaim logic mirrors `InboxLease._reclaimable`; the git layer clones/pulls the orphan ref into `workdir`, writes the per-item file, commits, and pushes with one rebase-retry):

```python
class RunStateRepo:
    def __init__(self, origin, workdir, *, branch="mship-run-state", ttl_seconds=1800): ...
    def try_claim(self, item_id, holder, now) -> ClaimInfo | None:
        # pull ref; if claim exists and not reclaimable(holder,now) -> return it;
        # else write claim file, commit, push (rebase-retry); return None on success.
    def refresh(self, item_id, holder, now) -> None: ...
    def release(self, item_id, holder) -> None: ...     # only if we hold it
    def read_claim(self, item_id) -> ClaimInfo | None: ...
    def append_log(self, item_id, text, now) -> None: ...
    def read_log(self, item_id) -> list[LogEntry]: ...
```
Reclaimability helper is identical in spirit to `InboxLease._reclaimable` (stale heartbeat OR holder gone → reclaimable); extract a shared `is_reclaimable(existing, me, now, ttl)` into `core/lease_common.py` and have BOTH `inbox_lease` and `run_state` use it (DRY — Task 5b).

- [ ] **Step 3b: Extract shared reclaim logic** — create `core/lease_common.py::is_reclaimable(...)`, refactor `InboxLease._reclaimable` to call it, run `tests/core/test_inbox_lease.py` (must stay green — no behavior change), then use it in `run_state.py`.

- [ ] **Step 4: Run — expect PASS**

Run: `uv run pytest tests/core/test_run_state.py tests/core/test_inbox_lease.py -v`

- [ ] **Step 5: Commit + journal**

```bash
git add src/mship/core/run_state.py src/mship/core/lease_common.py src/mship/core/inbox_lease.py tests/
git commit -m "feat(runner): git-backed run-state (claim + run-log) on orphan ref; share reclaim logic with inbox lease"
mship journal "run-state: exclusive reclaimable claim + append-only log on mship-run-state ref" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: Resumable dispatch prompt

**Files:**
- Create: `src/mship/core/run_dispatch.py`
- Test: `tests/core/test_run_dispatch.py`

Wraps the existing `mship dispatch` prompt so a resumed run continues off prior work: if the task's branch already has commits, prepend a "RESUMING" preamble that states the branch, its commits-ahead, and the last journal entries, and instructs the agent to continue rather than restart.

- [ ] **Step 1: Write failing test**

```python
def test_resumable_prompt_flags_prior_work():
    from mship.core.run_dispatch import resumable_dispatch
    base = "## Task\nImplement X"
    out = resumable_dispatch(base_prompt=base, branch="feat/x", commits_ahead=3,
                             recent_journal=["wrote parser", "tests green"])
    assert "RESUMING" in out and "feat/x" in out and "3 commit" in out
    assert "wrote parser" in out and base in out

def test_fresh_prompt_unchanged():
    from mship.core.run_dispatch import resumable_dispatch
    base = "## Task\nImplement X"
    assert resumable_dispatch(base_prompt=base, branch="feat/x", commits_ahead=0,
                              recent_journal=[]) == base
```

- [ ] **Step 2: Run — expect FAIL**, then implement:

```python
def resumable_dispatch(*, base_prompt, branch, commits_ahead, recent_journal):
    if commits_ahead <= 0:
        return base_prompt                      # fresh start: no preamble
    tail = "\n".join(f"- {j}" for j in recent_journal[-5:])
    return (f"## RESUMING prior run\n"
            f"You are continuing WorkItem work already in progress on branch "
            f"`{branch}` ({commits_ahead} commit(s) ahead of base). Do NOT restart — "
            f"build on the existing commits. Recent journal:\n{tail}\n\n{base_prompt}")
```

- [ ] **Step 3: Run — expect PASS**; **Step 4: Commit + journal.**

```bash
git add src/mship/core/run_dispatch.py tests/core/test_run_dispatch.py
git commit -m "feat(runner): resumable dispatch prompt (continue prior branch)"
mship journal "resumable dispatch: RESUMING preamble when branch has commits" --action committed
```
<!-- /mship:task -->

---

## Slice C — run-loop + bail

<!-- mship:task id=7 -->
### Task 7: `run_once` orchestration + bail

**Files:**
- Create: `src/mship/core/runner.py`
- Test: `tests/core/test_runner.py`

`run_once` is the seam the CLI calls. It's injectable (spawn_fn, dispatch_fn, git helpers) so it's unit-testable without real agents/git. It: selects → claims → builds the (resumable) dispatch prompt → returns it for the host to execute; and exposes `checkpoint_bail(item, reason)` = append run-log, mark item blocked (phase_override or a blocked marker), release claim.

- [ ] **Step 1: Write failing tests** (inject fakes; assert claim taken, prompt returned, and that bail releases the claim + logs the reason + leaves the branch reference recorded)

```python
def test_run_once_claims_and_returns_prompt(fake_ctx): ...
def test_run_once_noop_when_nothing_eligible(fake_ctx): ...
def test_bail_releases_claim_and_logs_reason(fake_ctx): ...
def test_run_once_skips_item_already_claimed(fake_ctx): ...
```

- [ ] **Step 2: Run — expect FAIL**, then implement `run_once`/`checkpoint_bail` composing Task 3 (select) + Task 5 (claim/log) + Task 6 (resumable prompt) + existing `spec_dispatch`/`dispatch`. Never call merge. On any exception during the host phase, callers invoke `checkpoint_bail`.

- [ ] **Step 3: Run — expect PASS**; **Step 4: Commit + journal.**
<!-- /mship:task -->

<!-- mship:task id=8 -->
### Task 8: `mship item run-next` and `mship item bail` CLI (nested under the `item` group)

**Files:**
- Modify: `src/mship/cli/workitem.py` (add `run-next` + `bail` to the existing `item` typer group — NOT top-level, to avoid colliding with the existing `mship run` that starts services)
- Test: `tests/cli/test_workitem.py`

- [ ] **Step 1: Write failing CLI tests**

```python
def test_item_run_next_emits_prompt_and_claims(tmp_ws): ...   # prints dispatch prompt, claim recorded
def test_item_run_next_noop_exit_zero_when_empty(tmp_ws): ...  # {"runnable": false}, exit 0
def test_item_bail_logs_reason_and_releases(tmp_ws): ...       # run-log has reason, claim released, item blocked
```

- [ ] **Step 2: Run — expect FAIL**, then implement (both as `@item_app.command(...)` in `cli/workitem.py`):
  - `mship item run-next` — select+claim the next eligible item, print its resumable dispatch prompt (JSON `{runnable, item_id, prompt}` in non-TTY); exit 0 with `{"runnable": false}` when nothing eligible. This is the pull API a host adapter calls. Nested under `item` so it doesn't collide with the existing top-level `mship run` (start services).
  - `mship item bail <id> --reason "<why>"` — checkpoint-bail: append the reason to the run-log, mark the item blocked, release the claim (calls `checkpoint_bail`). The host agent calls this on an unresolvable fork/failure. (v1 keeps LLM execution in the host adapter; mship owns claim/checkpoint/bail, not the model.)

- [ ] **Step 3: Run — expect PASS**; **Step 4: Commit + journal.**
<!-- /mship:task -->

---

## Slice D — reference Claude-routine adapter

<!-- mship:task id=9 -->
### Task 9: Reference adapter doc + smoke

**Files:**
- Create: `docs/adapters/claude-routine-runner.md`

- [ ] **Step 1:** Write the adapter doc: a Claude routine (cron) whose body is: `mship bootstrap <workspace>` (fresh clone, GH_TOKEN in env) → `mship item run-next` → if `runnable`, run the emitted prompt through the routine's own agent (which calls `mship context/test/finish/ask` as it works, opening a PR; never merges) → on a fork/failure the agent calls `mship item bail <id> --reason "<reason>"` → exit. One item per tick. Include the exact commands, the env (GH_TOKEN, workspace url), and the "never merge" + "bail don't block" rules.
- [ ] **Step 2:** Add a smoke test/checklist section: dry-run `mship item run-next` in a workspace with one approved+unattended item and confirm it prints a prompt + records a claim; with none, confirm `{"runnable": false}`.
- [ ] **Step 3: Commit + journal.**
<!-- /mship:task -->

---

## Self-Review

- **Spec coverage:** ac1 (flag+CLI) → T1/T2; ac2 (run-next selector) → T3/T8; ac3 (claim, reclaimable) → T5; ac4 (resumable dispatch) → T6; ac5 (plan→…→PR, never merge, gates) → T7/T8 + existing finish; ac6 (bail) → T5/T7/T8; ac7 (git-backed run-state) → T5; ac8 (Claude-routine adapter) → T9; ac9 (GC checkbox) → T4. All 9 covered.
- **Placeholder scan:** the two `NOTE`s (phase-derivation in T3; agent-execution-in-host in T8) are explicit, bounded design notes with working code as written, not deferred work. Test bodies in T4/T7/T8 name the cases and follow existing fixtures; expand to full bodies at implementation time from the cited sibling test files.
- **Type consistency:** `set_unattended`, `select_runnable`/`Candidate`, `RunStateRepo.try_claim/refresh/release/read_claim/append_log/read_log`, `resumable_dispatch`, `run_once`/`checkpoint_bail` are named consistently across tasks.

## Notes for the implementer
- Reuse, don't reinvent: the claim reclaim logic is shared with `core/inbox_lease.py` via `core/lease_common.py` (T5b). The dispatch prompt builds on existing `mship dispatch`.
- Never merge — the human reviews/merges the PR. `finish` still enforces approved-spec + audit + tests.
- Git-backed run-state is scoped to the run-claim + run-log only (spec non-goal: no full state-layer migration).
