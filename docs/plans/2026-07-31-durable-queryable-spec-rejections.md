# Durable, queryable spec rejections — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make a spec `request-changes` write a durable, append-only, reason-carrying rejection record that survives re-approval, and add a query CLI to enumerate rejections — the substrate for #444 Wave 4 / L5.

**Architecture:** Reuse `LogManager` (per-spec-id append-only journal). At `request-changes` (CLI `cli/spec.py` + serve `core/serve.py`) write a `action="rejected"` entry carrying `{actor, reason}` as JSON. Add `mship spec rejections <id> [--all]` that reads those entries. No new store, no new `Spec` field (a field is overwritten like `clarification_reason`).

**Tech Stack:** Python, typer, pytest.

**Spec:** `durable-queryable-spec-rejections-for-444` (approved).

## Global Constraints

- **Append-only journal, not a field.** The record must survive `approve_spec()` (which nulls `spec.clarification_reason`, `core/spec_transition.py:35`). Journal entries are append-only, so they survive — do NOT store the durable record on the Spec model.
- **Both paths.** CLI request-changes (`cli/spec.py` ~613-646, journals at ~640) and serve request-changes (`core/serve.py` ~984) must BOTH write the record.
- **Actor attribution mirrors approve/verdict:** CLI = `os.environ.get("USER") or "unknown"`; serve = `"operator"`.
- **Reason required** at rejection time — already enforced (CLI `--reason` required; serve `ReasonBody.reason`). Don't weaken it.
- **Query tolerates malformed/legacy entries** — skip, never crash.
- **Spec-only.** No plan-rejection (no plan-review lifecycle exists).

---

<!-- mship:task id=1 acs=ac1,ac2,ac3 -->
### Task 1: Record a durable `rejected` journal event at request-changes (CLI + serve)

**Files:**
- Modify: `src/mship/core/spec_transition.py` (add a small `record_rejection` helper) OR a suitable core module
- Modify: `src/mship/cli/spec.py` (request-changes → call the helper with host USER)
- Modify: `src/mship/core/serve.py` (request-changes handler → call the helper with `"operator"`)
- Test: `tests/core/test_spec_rejection_record.py`

**Interfaces:**
- Produces: `record_rejection(log_manager, spec_id: str, actor: str, reason: str, now: datetime) -> None` — appends one `LogManager` entry with `action="rejected"` and `text=json.dumps({"actor": actor, "reason": reason})` under key `spec_id`.
- Consumes: `LogManager.append(slug, text, action=...)` (`core/log.py`).

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_spec_rejection_record.py
import json
from datetime import datetime, timezone
from mship.core.log import LogManager
from mship.core.spec_transition import record_rejection


def test_record_rejection_writes_durable_rejected_entry(tmp_path):
    lm = LogManager(tmp_path / ".mothership" / "logs")
    record_rejection(lm, "spec-1", actor="alice", reason="metarepo not considered",
                     now=datetime(2026, 7, 31, tzinfo=timezone.utc))
    entries = [e for e in lm.read("spec-1") if e.action == "rejected"]
    assert len(entries) == 1
    payload = json.loads(entries[0].text)
    assert payload == {"actor": "alice", "reason": "metarepo not considered"}


def test_rejection_entry_survives_later_appends(tmp_path):
    """Append-only: a later entry (e.g. a re-approval note) does not erase it."""
    lm = LogManager(tmp_path / ".mothership" / "logs")
    record_rejection(lm, "spec-1", actor="alice", reason="r1",
                     now=datetime(2026, 7, 31, tzinfo=timezone.utc))
    lm.append("spec-1", "spec approved", action="approved")
    assert [e for e in lm.read("spec-1") if e.action == "rejected"]
```

- [ ] **Step 2: Run to verify it fails** — `uv run pytest tests/core/test_spec_rejection_record.py -q` → FAIL (`record_rejection` missing).

- [ ] **Step 3: Implement `record_rejection`**

```python
# src/mship/core/spec_transition.py
import json

def record_rejection(log_manager, spec_id: str, actor: str, reason: str, now) -> None:
    """Append a durable, append-only rejection event to the spec's journal.
    Survives a later approve_spec() (which nulls clarification_reason) because the
    journal is append-only. Keyed by spec_id; {actor, reason} as JSON so the query
    can parse it back; timestamp is the entry's own."""
    log_manager.append(spec_id, json.dumps({"actor": actor, "reason": reason}),
                       action="rejected", now=now)
```
(Match `LogManager.append`'s real signature — verify whether it takes `now=`; if not, drop it and let append stamp the time.)

- [ ] **Step 4: Wire both call sites**

In `cli/spec.py` request-changes (where it already journals at ~640): call `record_rejection(container.log_manager(), spec.id, os.environ.get("USER") or "unknown", reason, now)`. In `core/serve.py` request-changes handler (~984): call `record_rejection(log_manager, spec.id, "operator", body.reason, now)`. Keep the existing status flip to `draft` unchanged.

- [ ] **Step 5: Run tests** — `uv run pytest tests/core/test_spec_rejection_record.py tests/cli/test_spec*.py tests/core/test_serve.py -k "reject or request_changes or rejection" -q` → PASS.

- [ ] **Step 6: Commit + journal**

```bash
git add src/mship/core/spec_transition.py src/mship/cli/spec.py src/mship/core/serve.py tests/core/test_spec_rejection_record.py
git commit -m "feat(spec): durable append-only rejection record at request-changes (CLI + serve)"
mship journal "rejection recorded as durable action=rejected journal event on both paths" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 acs=ac4,ac5,ac6 -->
### Task 2: `mship spec rejections [<id>] [--all]` query

**Files:**
- Modify: `src/mship/cli/spec.py` (add the `rejections` subcommand — mirror the existing `list`/`show` commands)
- Test: `tests/cli/test_spec_rejections.py`

**Interfaces:**
- Consumes: `record_rejection` output (Task 1), `LogManager.read`, `SpecStore.list` (for `--all` spec enumeration).
- Produces: `mship spec rejections <id>` prints that spec's rejections `{actor, reason, timestamp}` chronologically; `--all` aggregates across specs; malformed entries skipped.

- [ ] **Step 1: Write the failing test**

```python
# tests/cli/test_spec_rejections.py — using the CLI runner pattern from tests/cli/test_spec*.py
def test_rejections_lists_records_for_a_spec(tmp_path, ...):
    # record two rejections for spec-1 via record_rejection, then invoke
    # `spec rejections spec-1` and assert both {actor, reason, timestamp} appear in order.
    ...

def test_rejections_all_aggregates_across_specs(tmp_path, ...):
    # rejections on spec-1 and spec-2 -> `spec rejections --all` shows both.
    ...

def test_rejections_skips_malformed_entry(tmp_path, ...):
    # a hand-written action=rejected entry with non-JSON text is skipped, not fatal.
    ...
```

- [ ] **Step 2: Run to verify it fails** — command doesn't exist yet.

- [ ] **Step 3: Implement the subcommand**

Add to `cli/spec.py` (mirror `list`/`show`): `rejections(spec_id: Optional[str], all: bool)`. For a single id: `log_manager.read(spec_id)` → keep `action == "rejected"` → `json.loads(text)` in a try (skip on failure) → print `{timestamp} {actor}: {reason}`, chronological. For `--all`: iterate `SpecStore.list()` ids (or glob the logs dir), do the same per spec, aggregate. JSON output mode returns a list of `{spec_id, actor, reason, timestamp}`.

- [ ] **Step 4: Run tests** — `uv run pytest tests/cli/test_spec_rejections.py -q` → PASS.

- [ ] **Step 5: Commit + journal**

```bash
git add src/mship/cli/spec.py tests/cli/test_spec_rejections.py
git commit -m "feat(spec): mship spec rejections [<id>] [--all] query"
mship journal "added spec rejections query (per-spec + --all), malformed-tolerant" --action committed
```
<!-- /mship:task -->

## Self-Review

- **Spec coverage:** ac1/ac2 (durable record both paths) + ac3 (reason required — already enforced, asserted) → Task 1; ac4/ac5 (query per-spec + --all) + ac6 (malformed skipped) → Task 2.
- **No new store / no Spec field:** reuses LogManager; survives re-approval by being append-only.
- **Signature check:** verify `LogManager.append`/`read` and `LogEntry` (`action`, `text`, `timestamp`) real signatures before finalizing; match them exactly.
