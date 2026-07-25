# Close Linked GitHub Tracker Issues on Merge — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `gh-issue-close-on-merge` (approved, dispatched) — closes mothership #386
**Work item:** (dispatch-created; `mship item list` newest)
**Worktree:** `/home/bailey/development/repos/mship-workspace/.worktrees/gh-issue-close-on-merge/mothership`
**Branch:** `feat/gh-issue-close-on-merge`

**Goal:** A task's linked GitHub issues close automatically when its PRs merge: `item link-issue` / `--closes` record them, `finish` injects `Closes` trailers, and both merge close-out triggers close still-open issues via the API — idempotently, fault-tolerantly, cross-repo.

**Architecture (verified against current code):**
- Links ride `WorkItem.external_links` (`core/workitem.py:15`, `ExternalLink{provider,url,title}`) via `WorkItemStore.add_external_link` (`workitem_store.py:184`, append-only → dedupe in the new code). Issue link shape: `provider="github"`, `url="https://github.com/{owner}/{repo}/issues/{n}"`, `title="{owner}/{repo}#{n}"`.
- Ref parsing lives in a new `core/issue_ref.py`; gh calls extend `core/pr.py::PRManager` (already the gh-CLI seam, has `_parse_github_slug`).
- Trailer injection: `cli/worktree.py` finish, after per-repo body resolution (~line 1012).
- Close-out: new `core/issue_close.py::close_linked_issues(...)`, called from BOTH triggers that already call `advance_spec_on_close`/`advance_workitem_on_close`: `cli/worktree.py` close (~line 833) and `pr_watcher._auto_close_on_merge` (~line 248).
- `Task.work_item_id` and `Task.pr_urls: dict[repo→url]` exist on state (`core/state.py:35,54`).

**Tech Stack:** typer CLI, pydantic models, gh CLI via `ShellRunner`, pytest (mocked shell).

---

<!-- mship:task id=1 -->
### Task 1: `core/issue_ref.py` — ref normalization (TDD)

**Files:** Create `src/mship/core/issue_ref.py`, `tests/core/test_issue_ref.py`

- [ ] **Step 1: Write failing tests**

```python
# tests/core/test_issue_ref.py
import pytest
from mship.core.issue_ref import normalize_issue_ref, IssueRefError


def test_full_slug_form():
    assert normalize_issue_ref("acme/widgets#12", default_slug=None) == "acme/widgets#12"


def test_url_form():
    assert normalize_issue_ref(
        "https://github.com/acme/widgets/issues/12", default_slug=None
    ) == "acme/widgets#12"


def test_hash_and_bare_number_use_default_slug():
    assert normalize_issue_ref("#7", default_slug="acme/widgets") == "acme/widgets#7"
    assert normalize_issue_ref("7", default_slug="acme/widgets") == "acme/widgets#7"


def test_bare_number_without_default_slug_fails_loud():
    with pytest.raises(IssueRefError, match="owner/repo#N"):
        normalize_issue_ref("#7", default_slug=None)


@pytest.mark.parametrize("bad", ["", "abc", "acme/widgets", "acme#12", "https://github.com/acme/widgets/pull/12"])
def test_invalid_refs_rejected(bad):
    with pytest.raises(IssueRefError):
        normalize_issue_ref(bad, default_slug="acme/widgets")


def test_issue_url():
    from mship.core.issue_ref import issue_url
    assert issue_url("acme/widgets#12") == "https://github.com/acme/widgets/issues/12"
```

- [ ] **Step 2: Run** `uv run pytest tests/core/test_issue_ref.py -q` → FAIL (module missing).
- [ ] **Step 3: Implement**

```python
# src/mship/core/issue_ref.py
"""Normalize GitHub issue references to canonical 'owner/repo#N' form (#386)."""
from __future__ import annotations

import re


class IssueRefError(ValueError):
    pass


_SLUG_FORM = re.compile(r"^([\w.-]+)/([\w.-]+)#(\d+)$")
_URL_FORM = re.compile(r"^https?://github\.com/([\w.-]+)/([\w.-]+)/issues/(\d+)/?$")
_NUM_FORM = re.compile(r"^#?(\d+)$")


def normalize_issue_ref(ref: str, *, default_slug: str | None) -> str:
    """Return 'owner/repo#N' for any accepted form: owner/repo#N, a full GitHub
    issue URL, '#N', or a bare number (the latter two need `default_slug`)."""
    ref = ref.strip()
    if m := _SLUG_FORM.match(ref):
        return f"{m.group(1)}/{m.group(2)}#{int(m.group(3))}"
    if m := _URL_FORM.match(ref):
        return f"{m.group(1)}/{m.group(2)}#{int(m.group(3))}"
    if m := _NUM_FORM.match(ref):
        if not default_slug:
            raise IssueRefError(
                f"issue ref {ref!r} has no repo; use the owner/repo#N form "
                f"(no unambiguous default repo could be resolved)"
            )
        return f"{default_slug}#{int(m.group(1))}"
    raise IssueRefError(f"unrecognized issue ref {ref!r}; use #N, N, owner/repo#N, or an issue URL")


def issue_url(canonical: str) -> str:
    slug, num = canonical.rsplit("#", 1)
    return f"https://github.com/{slug}/issues/{num}"


def issue_slug_and_number(canonical: str) -> tuple[str, int]:
    slug, num = canonical.rsplit("#", 1)
    return slug, int(num)
```

- [ ] **Step 4: Run** the tests → PASS.
- [ ] **Step 5: Commit** `feat: canonical GitHub issue-ref parsing (#386)` + `mship journal`.
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: `mship item link-issue` (TDD)

**Files:** Modify `src/mship/cli/workitem.py`; Test `tests/cli/test_workitem.py` (append)

- [ ] **Step 1: Failing tests** (append to `tests/cli/test_workitem.py`, following its existing runner/fixture pattern — read the file's first test for the invoke idiom):
  - `link-issue <id> acme/widgets#12` → exit 0; item's `external_links` contains provider `github`, url `https://github.com/acme/widgets/issues/12`, title `acme/widgets#12`.
  - linking the same ref twice → second call exits 0, prints an "already linked" note, `external_links` still has exactly one entry.
  - `link-issue <id> 12` with no resolvable default slug → exit 1, stderr mentions `owner/repo#N`.
  - `item show <id>` output includes `acme/widgets#12`.
- [ ] **Step 2:** Run → FAIL (no such command).
- [ ] **Step 3: Implement** — in `cli/workitem.py`, next to `link-url` (line ~254):

```python
    @item_app.command("link-issue")
    def link_issue(item_id: str, ref: str):
        """Link a GitHub tracker issue (closed automatically when the task's PRs merge)."""
        from mship.core.issue_ref import IssueRefError, issue_url, normalize_issue_ref

        items, _, _, _, _ = _ctx()
        _guard(items, item_id)
        try:
            canonical = normalize_issue_ref(ref, default_slug=_default_issue_slug())
        except IssueRefError as e:
            typer.echo(str(e), err=True)
            raise typer.Exit(1)
        url = issue_url(canonical)
        item = items.get(item_id)
        if any(l.url == url for l in item.external_links):
            typer.echo(f"already linked: {canonical}")
            return
        items.add_external_link(item_id, ExternalLink(provider="github", url=url, title=canonical),
                                now=datetime.now(timezone.utc))
        typer.echo(f"linked issue {canonical} -> {item_id}")
```

  `_default_issue_slug()` (same file): resolve each configured repo's `origin` remote via `git -C <path> remote get-url origin` and `mship.core.pr._parse_github_slug`; if exactly one distinct slug across repos, return `"owner/repo"`, else `None`. (Check `items.get` exists on the store — if the accessor is named differently (e.g. `load`/`find`), use that; `_guard` already proves an accessor exists.)
- [ ] **Step 4:** Run → PASS. Verify `item show` renders external links (it should already — only add display code if the test proves otherwise).
- [ ] **Step 5: Commit** `feat: mship item link-issue (#386)` + journal.
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: `--closes` on spawn and spec dispatch (TDD)

**Files:** Modify `src/mship/cli/worktree.py` (spawn), `src/mship/cli/spec.py` (dispatch); tests in `tests/cli/test_spawn.py` / `tests/cli/test_spec.py` (append, following existing patterns)

- [ ] **Step 1: Failing tests:** spawn with `--closes acme/widgets#12` → the task's WorkItem has the link; `--closes` twice (repeatable) links both; invalid ref → exit 1 before any worktree is created. Same for `spec dispatch --closes`.
- [ ] **Step 2:** Implement: add `closes: list[str] = typer.Option(None, "--closes", help="GitHub issue ref(s) this task closes on merge (#N, owner/repo#N, or URL; repeatable)")` to both commands; after the WorkItem is known, normalize each ref (fail loud BEFORE side effects: validate refs first, then create) and add the deduped ExternalLinks. Factor the link-one-issue logic from Task 2 into a small helper (e.g. `core/issue_link.py::link_issue_to_item(items, item_id, ref, default_slug)`) so all three commands share it — rule of three.
- [ ] **Step 3:** Run → PASS. **Step 4: Commit** `feat: --closes on spawn/dispatch (#386)` + journal.
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: finish injects Closes trailers (TDD)

**Files:** Modify `src/mship/cli/worktree.py` (finish body resolution ~line 1012); Test `tests/cli/test_finish.py` (append; find the existing finish body test for the harness pattern)

- [ ] **Step 1: Failing tests:**
  - Task's WorkItem links `acme/widgets#12`; finishing repo whose PR targets `acme/widgets` → body ends with `\n\nCloses #12`.
  - Cross-repo: repo slug `acme/other` → body ends with `Closes acme/widgets#12`.
  - Two linked issues → two `Closes` lines. No linked issues → body byte-identical to before.
- [ ] **Step 2: Implement** — helper in `core/issue_close.py` (created here, extended in Task 5):

```python
def closes_trailer(linked: list[str], repo_slug: str | None) -> str:
    """'Closes #N' for same-repo refs, 'Closes owner/repo#N' otherwise; '' if none."""
    lines = []
    for canonical in linked:
        slug, num = canonical.rsplit("#", 1)
        lines.append(f"Closes #{num}" if slug == repo_slug else f"Closes {canonical}")
    return ("\n\n" + "\n".join(lines)) if lines else ""
```

  In finish: after each repo's body is resolved, look up the task's WorkItem, collect canonical refs from `external_links` with `provider == "github"` and an `/issues/` url (titles hold the canonical form), determine the repo's slug via its remote (`_parse_github_slug`), append the trailer.
- [ ] **Step 3:** Run → PASS. **Step 4: Commit** `feat: finish appends Closes trailers (#386)` + journal.
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: close-out closes still-open issues (both triggers, idempotent) (TDD)

**Files:** Extend `src/mship/core/issue_close.py`; extend `src/mship/core/pr.py`; wire `src/mship/cli/worktree.py` (close) + `src/mship/core/pr_watcher.py` (`_auto_close_on_merge`); Test `tests/core/test_issue_close.py`

- [ ] **Step 1: Failing tests** (fake gh runner — follow `tests/core/test_pr*.py` ShellRunner-stub pattern):
  - open linked issue + all PRs merged → `gh issue close` invoked once with `-R acme/widgets`, comment contains `Shipped in` and the PR reference; returns `closed=[...]`.
  - already-closed issue → no `close` call, no comment, `skipped=[...]`.
  - gh failure (nonzero rc) → warning collected naming the issue; function returns normally (`failed=[...]`), never raises.
  - called twice → second call all-skipped (state check makes it a no-op).
  - `merged_count == 0` or `closed_count > 0` → immediate no-op (mirrors `advance_spec_on_close` guards).
- [ ] **Step 2: Implement** `PRManager.issue_state(slug, num) -> str` (`gh issue view {num} -R {slug} --json state -q .state`) and `PRManager.close_issue(slug, num, comment) -> None` (`gh issue close {num} -R {slug} --comment <comment>`), then:

```python
def close_linked_issues(*, task, workitems, pr_manager, merged_count, closed_count, warn) -> dict:
    """Close still-open linked GitHub issues after a fully-merged close-out.
    Never raises: failures go through warn() and the close-out proceeds."""
```

  Guards: `task.work_item_id` set, `merged_count > 0`, `closed_count == 0`. Comment text: `Shipped in {owner/repo}#{pr} (merged)` using the first entry of `task.pr_urls` (parse slug+number from the URL). Wire it immediately after `advance_workitem_on_close` at BOTH call sites; in `pr_watcher` route `warn` to its existing logging, in `close` to `output.warn`.
- [ ] **Step 3:** Run → PASS. **Step 4: Commit** `feat: merge close-out closes linked issues (#386)` + journal.
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: full verification + finish

- [ ] **Step 1:** `mship test --repos mothership` → full suite pass (exit 0).
- [ ] **Step 2:** Record `mship spec evidence gh-issue-close-on-merge ac1..ac6 <commit> --note ...` (ac1→T2, ac2→T3, ac3→T4, ac4/ac5→T5, ac6→T1+T5 test commits).
- [ ] **Step 3:** `mship finish` — and since this PR itself should close #386, first run `mship item link-issue <this-wi> atomikpanda/mothership#386` (dogfood: the trailer + close-out machinery ships its own tracker issue). Tidy the PR body; reply on thread `20260725023902-f01dbccc`.
<!-- /mship:task -->

---

## Self-review notes

- **Spec coverage:** ac1→T1+T2; ac2→T3; ac3→T4; ac4→T5 (both call sites wired); ac5→T5 (state-check idempotency + warn-not-raise); ac6→T1/T4/T5 test steps.
- **Rule of three:** the link-one-issue helper is extracted in T3 when the third caller appears, not before.
- **Fail loud:** invalid refs raise `IssueRefError` at the boundary (CLI exits 1 before side effects); only the *network close* path is deliberately fault-tolerant, per spec risk #1.
- **Field names verified in code, not assumed:** `external_links`, `add_external_link`, `work_item_id`, `pr_urls`, `_parse_github_slug` all confirmed at the cited lines. Store accessor name in T2 flagged for verification at implementation time.
