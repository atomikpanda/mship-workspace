# `mship spec apply --from-file <markdown>` — Implementation Plan

**REQUIRED SUB-SKILL: test-driven-development** — every task is red → green → commit. Write the failing pytest first, run it to confirm it fails for the right reason, implement the minimum to pass, run to green, then commit.

## Goal

Add `mship spec apply <id> --from-file <markdown>`: an inverse parser that reads a **rendered spec markdown document** (`## Problem` / `## User story` / `## Approach` / `## Acceptance criteria` / …) back into the exact same `SpecDraft` the existing `--from-json` path builds, then feeds it through the identical apply path (`apply_draft` → `needs_review`). This is **issue #298 item 1**. Items 2 (terser `AmbiguousTaskError`) and 3 (doc-ordering) already shipped in merged PR #358 and must **not** be touched — PR #358 only modified `src/mship/cli/_resolve.py`, `docs/cli.md`, `tests/cli/test_resolve_helper.py`; item 1 was explicitly deferred there.

## Architecture

The JSON path today (`src/mship/cli/spec.py:127-189`) does exactly three things: read raw text → deserialize to `SpecDraft` (`SpecDraft(**json.loads(raw))`) → `apply_draft(spec, draft)` + lifecycle transition + save. The **only** step that differs for markdown is deserialization. So the design is:

1. A pure function `parse_spec_markdown(text: str) -> SpecDraft` in `src/mship/core/spec_draft.py` (co-located with its sibling `apply_draft`/`build_draft_prompt`; already imports `SpecDraft` and `parse_body_sections`).
2. `spec apply` gains `--from-file`; `--from-json`/`--from-file` become **exactly-one-of**; the deserialized `SpecDraft` flows through the **unchanged** apply tail.

The parser **reuses the existing, tested `parse_body_sections`** (`src/mship/core/spec_body.py:24`) to split the document by `## ` headings, then maps known headings to `SpecDraft` fields and treats every other heading as an `additional_sections` entry (matching how `render_body` emits extras after Approach).

### Lossy-render limitation (must be stated to the operator)

There is **no single production renderer** that emits a complete spec-markdown document containing every `SpecDraft` field. Verified:

- `render_body` (`src/mship/core/spec_body.py:6`) — the only renderer of spec *content* — emits **only** `## Problem`, `## User story`, `## Approach` + additional `## <Heading>` sections. It does **not** render `acceptance_criteria`, `open_questions`, `non_goals`, `risks`, or `affected_repos`; those live in the spec's **YAML frontmatter** (`serialize_spec`, `src/mship/core/spec_store.py:43`).
- `mship view spec` (`src/mship/cli/view/spec.py:133`) renders the raw file (frontmatter + body) — criteria are YAML, not checkboxes.
- `mship spec show` (`src/mship/cli/spec.py:626`) prints only `spec.body` as rich Markdown in TTY mode and **pure JSON** in non-TTY mode — it never emits `## Acceptance criteria` checkboxes.
- The `- [ ] \`acN\` <text>` checkbox+backtick-id format the issue describes exists **only** in the PR-body renderer `build_acceptance_block` (`src/mship/core/pr.py:449`). Two other AC formats exist: `- [acN] <text>` (`src/mship/cli/workitem.py:68`) and indented `  - [acN] <text>` (`src/mship/core/spec_dispatch.py:54`).

**Consequence:** a true `render(draft) → parse → equal draft` round-trip against a *real* renderer is only possible for the **prose subset** (problem / user_story / approach / additional_sections) via `render_body` — that is the headline property test (Task 3). For the list fields there is no canonical renderer to invert, so the parser defines a **documented grammar** that is tolerant of the three in-repo AC conventions, and those sections are tested against hand-authored fixtures (Task 2). This limitation is surfaced to the operator via the `spec apply` docstring and error messages.

### Parser grammar (the contract)

`parse_spec_markdown` accepts a full spec markdown document and returns a `SpecDraft`:

- **Prose (required):** `## Problem`, `## User story`, `## Approach` → `problem`, `user_story`, `approach`. Missing any → `ValueError` naming it (fail loud, mship principle).
- **Lists (optional):** `## Acceptance criteria`, `## Open questions`, `## Non-goals` (or `Non goals`), `## Risks`, `## Affected repos` (or `Affected repositories`) → the matching `list[str]` field. Each item line: bullet marker (`-`, `*`, `+`, or `N.`), an optional `[ ]`/`[x]` checkbox, an optional id token (`` `acN` `` / `` `qN` `` backticked, or `[acN]`/`[qN]` bracketed) — all stripped; the remainder is the item **text**. Ids are re-derived positionally by `apply_draft` (matching the JSON path, whose lists are also text-only), so stripping them is correct.
- **Unknown `## <Heading>`** → `additional_sections` (`BodySection`), preserving document order (matching `render_body`).
- Heading matching is case-insensitive on `.strip().lower()`. Duplicate headings: last wins (inherited from `parse_body_sections`).
- **Malformed** (a known list section containing a non-blank, non-bullet line) → `ValueError` naming the section.

## Tech Stack

Python ≥ 3.14, Typer CLI, Pydantic v2 models (`SpecDraft`, `BodySection`), `uv run pytest` from the build worktree. No new dependencies (`re` is stdlib).

## File Structure

| File | Change |
| --- | --- |
| `src/mship/core/spec_draft.py` | **MODIFY** — add `parse_spec_markdown` + module-level regex/heading tables + `_parse_list_items` helper; add `import re`; add `BodySection` to the existing `from mship.core.spec import …`. |
| `src/mship/cli/spec.py` | **MODIFY** — `spec apply` gains `--from-file`; `--from-json`/`--from-file` become optional + exactly-one-of; markdown routes through `parse_spec_markdown`; unchanged apply tail. |
| `tests/core/test_spec_markdown_parse.py` | **NEW** — parser unit tests (happy-path, list sections, `render_body` round-trip, tolerance, malformed→`ValueError`). |
| `tests/cli/test_spec.py` | **MODIFY (append)** — `--from-file` CLI tests + `--from-json` regression guard. |

**Explicitly NOT touched:** `src/mship/core/spec.py` (`SpecDraft` already has every needed field — no model change), `src/mship/core/spec_body.py` (reused as-is), and all PR #358 files (`src/mship/cli/_resolve.py`, `docs/cli.md`, `tests/cli/test_resolve_helper.py`).

---

<!-- mship:task id=1 -->
## Task 1 — `parse_spec_markdown`: required prose happy-path

**Files:** `src/mship/core/spec_draft.py`, `tests/core/test_spec_markdown_parse.py`

**Step 1 — Write the failing test** (new file `tests/core/test_spec_markdown_parse.py`):

```python
from mship.core.spec import SpecDraft
from mship.core.spec_draft import parse_spec_markdown


def test_parses_required_prose_sections_into_empty_draft():
    text = (
        "## Problem\n\nP\n\n"
        "## User story\n\nU\n\n"
        "## Approach\n\nA\n"
    )
    draft = parse_spec_markdown(text)
    assert isinstance(draft, SpecDraft)
    assert draft.problem == "P"
    assert draft.user_story == "U"
    assert draft.approach == "A"
    # Optional fields default empty when their sections are absent.
    assert draft.acceptance_criteria == []
    assert draft.open_questions == []
    assert draft.non_goals == []
    assert draft.risks == []
    assert draft.affected_repos == []
    assert draft.additional_sections == []
```

**Step 2 — Run to fail** (cwd `/home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership`): `uv run pytest tests/core/test_spec_markdown_parse.py::test_parses_required_prose_sections_into_empty_draft -v` → fails: `ImportError` (`parse_spec_markdown` does not exist).

**Step 3 — Implement.** In `src/mship/core/spec_draft.py`, append this function (no other changes yet):

```python
def parse_spec_markdown(text: str) -> SpecDraft:
    """Parse a rendered spec markdown document back into a SpecDraft.

    Inverse of the `## Problem` / `## User story` / `## Approach` body rendering
    (see `render_body`). Reuses `parse_body_sections` to split by `## ` headings.
    """
    sections = parse_body_sections(text)
    by_key = {heading.strip().lower(): body.strip() for heading, body in sections.items()}
    return SpecDraft(
        problem=by_key.get("problem", ""),
        user_story=by_key.get("user story", ""),
        approach=by_key.get("approach", ""),
    )
```

**Step 4 — Run to pass** (cwd `/home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership`): `uv run pytest tests/core/test_spec_markdown_parse.py::test_parses_required_prose_sections_into_empty_draft -v` → green.

**Step 5 — Commit:**
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership add src/mship/core/spec_draft.py tests/core/test_spec_markdown_parse.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership commit -m "feat(spec): parse_spec_markdown reads required prose sections (#298 item 1)

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "spec markdown parser: prose happy-path" --task spec-apply-from-file --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
## Task 2 — List sections + id/checkbox stripping

**Files:** `src/mship/core/spec_draft.py`, `tests/core/test_spec_markdown_parse.py`

**Step 1 — Write the failing test** (append to `tests/core/test_spec_markdown_parse.py`):

```python
def test_parses_list_sections_stripping_checkboxes_and_ids():
    text = (
        "## Problem\n\nP\n\n"
        "## User story\n\nU\n\n"
        "## Approach\n\nA\n\n"
        "## Acceptance criteria\n\n"
        "- [ ] `ac1` view questions\n"
        "- [x] `ac2` record answer\n\n"
        "## Open questions\n\n"
        "- [q1] Android in v0?\n\n"
        "## Non-goals\n\n"
        "- chat\n\n"
        "## Risks\n\n"
        "- scope creep\n\n"
        "## Affected repos\n\n"
        "- mothership\n"
    )
    draft = parse_spec_markdown(text)
    # Text only — ids/checkboxes stripped, matching the JSON path's text-only lists.
    assert draft.acceptance_criteria == ["view questions", "record answer"]
    assert draft.open_questions == ["Android in v0?"]
    assert draft.non_goals == ["chat"]
    assert draft.risks == ["scope creep"]
    assert draft.affected_repos == ["mothership"]
```

**Step 2 — Run to fail** (cwd `/home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership`): `uv run pytest tests/core/test_spec_markdown_parse.py::test_parses_list_sections_stripping_checkboxes_and_ids -v` → fails: lists are empty (Task 1 impl ignores list sections).

**Step 3 — Implement.** In `src/mship/core/spec_draft.py`, add `import re` at the top of the file (below `from datetime import datetime`), then add these module-level tables + helper above `parse_spec_markdown`, and replace `parse_spec_markdown` with the version below:

```python
_PROSE_SECTIONS = {
    "problem": "problem",
    "user story": "user_story",
    "approach": "approach",
}
_LIST_SECTIONS = {
    "acceptance criteria": "acceptance_criteria",
    "open questions": "open_questions",
    "non-goals": "non_goals",
    "non goals": "non_goals",
    "risks": "risks",
    "affected repos": "affected_repos",
    "affected repositories": "affected_repos",
}
_BULLET_RE = re.compile(r"^\s*-\s+(.*)$")
_CHECKBOX_RE = re.compile(r"^\[[ xX]\]\s+(.*)$")
_ID_BACKTICK_RE = re.compile(r"^`[A-Za-z]+\d+`\s+(.*)$")
_ID_BRACKET_RE = re.compile(r"^\[[A-Za-z]+\d+\]\s+(.*)$")


def _parse_list_items(heading: str, raw: str) -> list[str]:
    """Extract bullet-item text from a list section, stripping an optional
    `[ ]`/`[x]` checkbox and an optional `` `acN` `` / `[acN]` id token. The
    `\\d+` requirement on ids means real prose like `` `code` does X `` is never
    mistaken for an id."""
    items: list[str] = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        m = _BULLET_RE.match(line)
        if m is None:
            continue  # tolerant here; Task 5 makes malformed lines loud
        text = m.group(1).strip()
        cb = _CHECKBOX_RE.match(text)
        if cb is not None:
            text = cb.group(1).strip()
        idm = _ID_BACKTICK_RE.match(text) or _ID_BRACKET_RE.match(text)
        if idm is not None:
            text = idm.group(1).strip()
        if text:
            items.append(text)
    return items


def parse_spec_markdown(text: str) -> SpecDraft:
    """Parse a rendered spec markdown document back into a SpecDraft.

    Inverse of the body/section rendering used across mship. Reuses
    `parse_body_sections` to split by `## ` headings, maps known headings to
    SpecDraft fields, and parses list sections into text-only items (ids are
    re-derived positionally by `apply_draft`, matching the JSON path).
    """
    sections = parse_body_sections(text)
    fields: dict[str, object] = {
        "problem": "", "user_story": "", "approach": "",
        "non_goals": [], "risks": [], "affected_repos": [],
        "acceptance_criteria": [], "open_questions": [],
    }
    for heading, body in sections.items():
        key = heading.strip().lower()
        if key in _PROSE_SECTIONS:
            fields[_PROSE_SECTIONS[key]] = body.strip()
        elif key in _LIST_SECTIONS:
            fields[_LIST_SECTIONS[key]] = _parse_list_items(heading.strip(), body)
        # else: unknown heading — additional_sections handled in Task 3
    return SpecDraft(**fields)
```

**Step 4 — Run to pass** (cwd `/home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership`): `uv run pytest tests/core/test_spec_markdown_parse.py -v` → both parser tests green.

**Step 5 — Commit:**
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership add src/mship/core/spec_draft.py tests/core/test_spec_markdown_parse.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership commit -m "feat(spec): parse_spec_markdown reads list sections, strips ids/checkboxes (#298 item 1)

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "spec markdown parser: list sections + id stripping" --task spec-apply-from-file --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
## Task 3 — `render_body` round-trip (headline) + additional_sections

**Files:** `src/mship/core/spec_draft.py`, `tests/core/test_spec_markdown_parse.py`

This is the headline correctness property: parse is the inverse of the **real** renderer (`render_body`) for the prose + additional-sections subset (the recoverable subset — see the lossy-render note in Architecture).

**Step 1 — Write the failing test** (append to `tests/core/test_spec_markdown_parse.py`):

```python
from mship.core.spec import BodySection
from mship.core.spec_body import render_body


def test_round_trips_render_body_prose_only():
    draft = SpecDraft(
        problem="the problem",
        user_story="as a user, I want X, so that Y",
        approach="the approach; key decisions",
    )
    body = render_body(draft.problem, draft.user_story, draft.approach)
    assert parse_spec_markdown(body) == draft


def test_round_trips_render_body_with_additional_sections():
    draft = SpecDraft(
        problem="the problem",
        user_story="as a user, I want X, so that Y",
        approach="the approach",
        additional_sections=[
            BodySection(heading="Architecture", body="the arch"),
            BodySection(heading="Testing", body="the tests"),
        ],
    )
    body = render_body(
        draft.problem, draft.user_story, draft.approach,
        additional_sections=[(s.heading, s.body) for s in draft.additional_sections],
    )
    parsed = parse_spec_markdown(body)
    assert parsed == draft  # full SpecDraft equality (empty lists on both sides)
```

**Step 2 — Run to fail** (cwd `/home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership`): `uv run pytest "tests/core/test_spec_markdown_parse.py::test_round_trips_render_body_with_additional_sections" -v` → fails: `parsed.additional_sections == []` but the draft has two entries (Task 2 impl drops unknown headings). (`test_round_trips_render_body_prose_only` already passes — that is expected; the additional-sections test is the red hook.)

**Step 3 — Implement.** In `src/mship/core/spec_draft.py`, add `BodySection` to the existing spec import so the line reads:

```python
from mship.core.spec import AcceptanceCriterion, BodySection, OpenQuestion, Spec, SpecDraft
```

Then replace `parse_spec_markdown` with the version that collects unknown headings into `additional_sections` (document order preserved by `parse_body_sections`):

```python
def parse_spec_markdown(text: str) -> SpecDraft:
    """Parse a rendered spec markdown document back into a SpecDraft.

    Inverse of the body/section rendering used across mship. Reuses
    `parse_body_sections` to split by `## ` headings, maps known headings to
    SpecDraft fields, parses list sections into text-only items, and preserves
    any other `## <Heading>` section as an additional_sections entry (matching
    how `render_body` appends extras after Approach).
    """
    sections = parse_body_sections(text)
    fields: dict[str, object] = {
        "problem": "", "user_story": "", "approach": "",
        "non_goals": [], "risks": [], "affected_repos": [],
        "acceptance_criteria": [], "open_questions": [],
    }
    additional: list[BodySection] = []
    for heading, body in sections.items():
        key = heading.strip().lower()
        if key in _PROSE_SECTIONS:
            fields[_PROSE_SECTIONS[key]] = body.strip()
        elif key in _LIST_SECTIONS:
            fields[_LIST_SECTIONS[key]] = _parse_list_items(heading.strip(), body)
        else:
            additional.append(BodySection(heading=heading.strip(), body=body.strip()))
    return SpecDraft(additional_sections=additional, **fields)
```

**Step 4 — Run to pass** (cwd `/home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership`): `uv run pytest tests/core/test_spec_markdown_parse.py -v` → all parser tests green.

**Step 5 — Commit:**
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership add src/mship/core/spec_draft.py tests/core/test_spec_markdown_parse.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership commit -m "feat(spec): parse_spec_markdown round-trips render_body + keeps additional sections (#298 item 1)

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "spec markdown parser: render_body round-trip + additional sections" --task spec-apply-from-file --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
## Task 4 — Tolerance: reordered sections, alt list markers, empty optional sections

**Files:** `src/mship/core/spec_draft.py`, `tests/core/test_spec_markdown_parse.py`

**Step 1 — Write the failing test** (append to `tests/core/test_spec_markdown_parse.py`):

```python
def test_tolerates_reorder_alt_markers_and_empty_optional_sections():
    # Sections out of canonical order; `*` and `1.`/`2.` bullet markers;
    # an empty optional section; a `- [ac1]` (bracket-id) AC form.
    text = (
        "## Approach\n\nA\n\n"
        "## Acceptance criteria\n\n"
        "* [ac1] first\n"
        "1. second\n"
        "2. third\n\n"
        "## Problem\n\nP\n\n"
        "## Risks\n\n\n"          # heading present, no items
        "## Non-goals\n\n"
        "+ out of scope\n\n"
        "## User story\n\nU\n"
    )
    draft = parse_spec_markdown(text)
    assert draft.problem == "P" and draft.user_story == "U" and draft.approach == "A"
    assert draft.acceptance_criteria == ["first", "second", "third"]
    assert draft.non_goals == ["out of scope"]
    assert draft.risks == []  # empty optional section → empty list, no error
```

**Step 2 — Run to fail** (cwd `/home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership`): `uv run pytest tests/core/test_spec_markdown_parse.py::test_tolerates_reorder_alt_markers_and_empty_optional_sections -v` → fails: `_BULLET_RE` is dash-only, so `* [ac1] first`, `1. second`, `2. third`, and `+ out of scope` are dropped.

**Step 3 — Implement.** In `src/mship/core/spec_draft.py`, broaden the bullet regex to accept `-`, `*`, `+`, and ordered `N.` markers:

```python
_BULLET_RE = re.compile(r"^\s*(?:[-*+]|\d+\.)\s+(.*)$")
```

(Reordering and empty-optional already work: `parse_body_sections` is order-agnostic, and an empty section yields `[]` from `_parse_list_items`.)

**Step 4 — Run to pass** (cwd `/home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership`): `uv run pytest tests/core/test_spec_markdown_parse.py -v` → all green.

**Step 5 — Commit:**
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership add src/mship/core/spec_draft.py tests/core/test_spec_markdown_parse.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership commit -m "feat(spec): parse_spec_markdown tolerant of reorder, alt bullet markers, empty sections (#298 item 1)

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "spec markdown parser: tolerance for order/markers/empty sections" --task spec-apply-from-file --action committed
```
<!-- /mship:task -->

<!-- mship:task id=5 -->
## Task 5 — Malformed input → `ValueError` (fail loud)

**Files:** `src/mship/core/spec_draft.py`, `tests/core/test_spec_markdown_parse.py`

**Step 1 — Write the failing test** (append to `tests/core/test_spec_markdown_parse.py`):

```python
import pytest


def test_missing_required_section_raises_naming_it():
    text = "## Problem\n\nP\n\n## User story\n\nU\n"  # no Approach
    with pytest.raises(ValueError) as exc:
        parse_spec_markdown(text)
    assert "Approach" in str(exc.value)


def test_non_markdown_junk_raises():
    with pytest.raises(ValueError):
        parse_spec_markdown("this is not a spec at all")


def test_malformed_list_section_raises_naming_section():
    text = (
        "## Problem\n\nP\n\n## User story\n\nU\n\n## Approach\n\nA\n\n"
        "## Acceptance criteria\n\nnot a bullet line\n"
    )
    with pytest.raises(ValueError) as exc:
        parse_spec_markdown(text)
    assert "Acceptance criteria" in str(exc.value)
```

**Step 2 — Run to fail** (cwd `/home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership`): `uv run pytest tests/core/test_spec_markdown_parse.py -k "raises" -v` → fails: Task 4 impl returns `approach=""` (no exception) and silently ignores non-bullet lines.

**Step 3 — Implement.** In `src/mship/core/spec_draft.py`: (a) change the non-bullet branch of `_parse_list_items` from `continue` to a loud raise, and (b) add a required-section presence check at the top of `parse_spec_markdown`.

In `_parse_list_items`, replace the `if m is None: continue` branch with:

```python
        m = _BULLET_RE.match(line)
        if m is None:
            raise ValueError(
                f"cannot parse spec markdown: '{heading}' section has a "
                f"non-list line: {line.strip()!r}"
            )
```

At the very top of `parse_spec_markdown` (immediately after `sections = parse_body_sections(text)`), add:

```python
    present = {heading.strip().lower() for heading in sections}
    missing = [name for name in ("Problem", "User story", "Approach") if name.lower() not in present]
    if missing:
        raise ValueError(
            "cannot parse spec markdown: missing required section(s): " + ", ".join(missing)
        )
```

(Junk input like `"this is not a spec at all"` yields no `## ` headings, so all three required sections are missing → `ValueError`.)

**Step 4 — Run to pass** (cwd `/home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership`): `uv run pytest tests/core/test_spec_markdown_parse.py -v` → all parser tests green (happy-path, lists, round-trip, tolerance, malformed).

**Step 5 — Commit:**
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership add src/mship/core/spec_draft.py tests/core/test_spec_markdown_parse.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership commit -m "feat(spec): parse_spec_markdown raises clear ValueError on missing/malformed sections (#298 item 1)

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "spec markdown parser: fail-loud on malformed input" --task spec-apply-from-file --action committed
```
<!-- /mship:task -->

<!-- mship:task id=6 -->
## Task 6 — Wire `spec apply --from-file` (exactly-one-of, reuse apply path)

**Files:** `src/mship/cli/spec.py`, `tests/cli/test_spec.py`

**Step 1 — Write the failing tests** (append to `tests/cli/test_spec.py`; reuses the file's existing `runner`, `app`, `_store`, `_json`, and `configured_app_with_task` fixture):

```python
# --- spec apply --from-file (#298 item 1) ---


def _draft_md() -> str:
    return (
        "## Problem\n\nP\n\n"
        "## User story\n\nU\n\n"
        "## Approach\n\nA\n\n"
        "## Acceptance criteria\n\n"
        "- [ ] `ac1` view questions\n\n"
        "## Open questions\n\n"
        "- Android?\n\n"
        "## Non-goals\n\n"
        "- chat\n\n"
        "## Affected repos\n\n"
        "- mothership\n"
    )


def test_spec_apply_from_file_merges_and_advances_status(configured_app_with_task: Path, tmp_path):
    runner.invoke(app, ["spec", "new", "--title", "Decision queue", "--id", "dq"])
    mf = tmp_path / "draft.md"
    mf.write_text(_draft_md())
    result = runner.invoke(app, ["spec", "apply", "dq", "--from-file", str(mf)])
    assert result.exit_code == 0, result.output
    spec = _store(configured_app_with_task).find_by_id("dq")
    assert spec.status == "needs_review"
    assert [c.id for c in spec.acceptance_criteria] == ["ac1"]
    assert spec.acceptance_criteria[0].text == "view questions"
    assert spec.non_goals == ["chat"]
    assert spec.affected_repos == ["mothership"]
    assert "## Problem" in spec.body


def test_spec_apply_requires_exactly_one_source(configured_app_with_task: Path, tmp_path):
    runner.invoke(app, ["spec", "new", "--title", "Decision queue", "--id", "dq"])
    # Neither source.
    neither = runner.invoke(app, ["spec", "apply", "dq"])
    assert neither.exit_code != 0
    assert "exactly one" in neither.output.lower()
    # Both sources.
    jf = tmp_path / "d.json"; jf.write_text(_draft_json())
    mf = tmp_path / "d.md"; mf.write_text(_draft_md())
    both = runner.invoke(app, ["spec", "apply", "dq", "--from-json", str(jf), "--from-file", str(mf)])
    assert both.exit_code != 0
    assert "exactly one" in both.output.lower()


def test_spec_apply_from_file_missing_file_errors(configured_app_with_task: Path):
    runner.invoke(app, ["spec", "new", "--title", "Decision queue", "--id", "dq"])
    result = runner.invoke(app, ["spec", "apply", "dq", "--from-file", "/no/such/file.md"])
    assert result.exit_code != 0
    assert "from-file" in result.output or "read" in result.output.lower()


def test_spec_apply_from_file_malformed_markdown_errors(configured_app_with_task: Path, tmp_path):
    runner.invoke(app, ["spec", "new", "--title", "Decision queue", "--id", "dq"])
    mf = tmp_path / "bad.md"
    mf.write_text("just some notes, no headings")  # missing required sections
    result = runner.invoke(app, ["spec", "apply", "dq", "--from-file", str(mf)])
    assert result.exit_code != 0
```

**Step 2 — Run to fail** (cwd `/home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership`): `uv run pytest tests/cli/test_spec.py -k "from_file or exactly_one" -v` → fails: `--from-file` is not a recognized option (Typer usage error, exit 2).

**Step 3 — Implement.** In `src/mship/cli/spec.py`, replace the `apply` command (currently lines ~126-189) with the version below. Changes: `from_json` becomes `Optional[str]` defaulting to `None`; new `from_file` option; exactly-one-of guard; source selection; markdown routes through `parse_spec_markdown`; **the entire apply tail (container/store/status-gate/save/journal/output) is unchanged.** `Optional` is already imported at the top of `spec.py`.

```python
    @spec_app.command("apply")
    def apply(
        spec_id: str = typer.Argument(..., help="Spec id to apply the draft to."),
        from_json: Optional[str] = typer.Option(None, "--from-json", help="Path to the draft JSON, or - for stdin."),
        from_file: Optional[str] = typer.Option(None, "--from-file", help="Path to a rendered spec markdown file, or - for stdin."),
        bypass_status_gate: bool = typer.Option(False, "--bypass-status-gate", help="Apply regardless of current status."),
    ):
        """Ingest a drafted spec, render the body, set fields, advance to needs_review.

        Provide exactly one source:
          --from-json <file|->   a structured SpecDraft JSON payload
          --from-file <file|->   a rendered spec markdown document (## Problem / ## Approach / …)
        Both feed the SAME apply path; only the deserialization differs. Note the
        markdown path recovers only the prose + list sections it renders — the
        JSON path remains authoritative for anything a rendered body omits.
        """
        import json
        import sys
        from datetime import datetime, timezone
        from pathlib import Path
        from pydantic import ValidationError
        from mship.core.spec import SpecDraft, InvalidTransition, validate_transition
        from mship.core.spec_draft import apply_draft, parse_spec_markdown
        from mship.core.spec_store import SpecStore, SPECS_DIRNAME

        output = Output()

        if (from_json is None) == (from_file is None):
            output.error("Provide exactly one of --from-json or --from-file.")
            raise typer.Exit(1)

        source_flag = "--from-json" if from_json is not None else "--from-file"
        source_val = from_json if from_json is not None else from_file
        if source_val == "-":
            raw = sys.stdin.read()
        else:
            try:
                raw = Path(source_val).read_text()
            except OSError as e:
                output.error(f"Cannot read {source_flag} {source_val!r}: {e}")
                raise typer.Exit(1)

        try:
            if from_json is not None:
                draft = SpecDraft(**json.loads(raw))
            else:
                draft = parse_spec_markdown(raw)
        except (json.JSONDecodeError, ValidationError) as e:
            output.error(f"Invalid draft JSON: {e}")
            raise typer.Exit(1)
        except ValueError as e:
            output.error(f"Invalid spec markdown: {e}")
            raise typer.Exit(1)

        container = get_container()
        workspace_root = Path(container.config_path()).parent
        store = SpecStore(workspace_root / SPECS_DIRNAME)
        spec = store.find_by_id(spec_id)
        if spec is None:
            output.error(f"No spec with id {spec_id!r}.")
            raise typer.Exit(1)

        if not bypass_status_gate:
            try:
                validate_transition(spec.status, "needs_review")
            except InvalidTransition as e:
                output.error(f"{e}. Use --bypass-status-gate to override.")
                raise typer.Exit(1)

        # MOS-215/MOS-240: applying a (re)drafted spec supersedes any pending
        # request-changes, so clear the reason — a freshly applied draft carries
        # no outstanding clarification ask. (A brand-new draft has none anyway.)
        apply_draft(spec, draft)
        spec.status = "needs_review"
        spec.clarification_reason = None
        spec.updated_at = datetime.now(timezone.utc)
        path = store.save(spec)

        # Agent-agnostic activity heartbeat: applying a drafted spec is task work.
        # No-ops when the spec's bound task_slug isn't (yet) a live task.
        if spec.task_slug:
            container.state_manager().record_activity(spec.task_slug)

        if output.human_mode:
            output.success(f"Applied draft → {spec.status}: {path}")
        else:
            output.json({"id": spec.id, "status": spec.status, "path": str(path)})
```

Note on the `except` ordering: `json.JSONDecodeError` is a subclass of `ValueError`, so it must be caught in the first clause (it is). `parse_spec_markdown` only raises plain `ValueError`, caught by the second clause. Both exit non-zero.

**Step 4 — Run to pass** (cwd `/home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership`): `uv run pytest tests/cli/test_spec.py -k "from_file or exactly_one" -v` → green.

**Step 5 — Commit:**
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership add src/mship/cli/spec.py tests/cli/test_spec.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership commit -m "feat(spec): spec apply --from-file <markdown> via parse_spec_markdown, exactly-one-of (#298 item 1)

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "spec apply --from-file wired, exactly-one-of with --from-json" --task spec-apply-from-file --action committed
```
<!-- /mship:task -->

<!-- mship:task id=7 -->
## Task 7 — Regression: `--from-json` unchanged

**Files:** `tests/cli/test_spec.py`

These are regression guards proving the JSON path is byte-for-byte behavior-preserved after Task 6 (making `--from-json` optional and adding the shared read/deserialize branch). Because they encode already-correct behavior they are expected to be **green on first run** — the "run" step confirms no regression rather than a red→green flip; this is the intentional regression-pass exception to strict red-green.

**Step 1 — Write the regression tests** (append to `tests/cli/test_spec.py`):

```python
# --- spec apply --from-json regression guard (#298 item 1) ---


def test_regression_from_json_file_still_applies(configured_app_with_task: Path, tmp_path):
    runner.invoke(app, ["spec", "new", "--title", "Decision queue", "--id", "dq"])
    jf = tmp_path / "draft.json"; jf.write_text(_draft_json())
    result = runner.invoke(app, ["spec", "apply", "dq", "--from-json", str(jf)])
    assert result.exit_code == 0, result.output
    spec = _store(configured_app_with_task).find_by_id("dq")
    assert spec.status == "needs_review"
    assert [c.id for c in spec.acceptance_criteria] == ["ac1"]
    assert "## Problem" in spec.body


def test_regression_from_json_stdin_still_applies(configured_app_with_task: Path):
    runner.invoke(app, ["spec", "new", "--title", "Decision queue", "--id", "dq"])
    result = runner.invoke(app, ["spec", "apply", "dq", "--from-json", "-"], input=_draft_json())
    assert result.exit_code == 0, result.output
    assert _store(configured_app_with_task).find_by_id("dq").status == "needs_review"


def test_regression_from_json_bad_payload_still_errors(configured_app_with_task: Path, tmp_path):
    runner.invoke(app, ["spec", "new", "--title", "Decision queue", "--id", "dq"])
    jf = tmp_path / "bad.json"; jf.write_text("this is not json at all")
    result = runner.invoke(app, ["spec", "apply", "dq", "--from-json", str(jf)])
    assert result.exit_code != 0
    # A valid-JSON but schema-invalid payload still errors via the JSON path
    # (never routed through the markdown parser).
    jf2 = tmp_path / "partial.json"; jf2.write_text('{"problem": "only problem"}')
    result2 = runner.invoke(app, ["spec", "apply", "dq", "--from-json", str(jf2)])
    assert result2.exit_code != 0
```

**Step 2 — Run to confirm green** (cwd `/home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership`, regression guard): `uv run pytest tests/cli/test_spec.py -k regression -v` → green.

**Step 3 — Full spec suite** (cwd `/home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership`): `uv run pytest tests/cli/test_spec.py tests/core/test_spec_markdown_parse.py tests/core/test_spec_draft.py tests/core/test_spec_body.py -v` → all green (proves the pre-existing `spec apply --from-json` and `apply_draft`/`render_body` tests still pass unchanged).

**Step 4 — Commit:**
```
git -C /home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership add tests/cli/test_spec.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership commit -m "test(spec): regression guard — spec apply --from-json unchanged after --from-file (#298 item 1)

Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "regression: --from-json path preserved" --task spec-apply-from-file --action committed
```
<!-- /mship:task -->

---

## Self-Review

**Issue #298 item 1 → task mapping.** Item 1 ("`spec apply --from-file <markdown>` shortcut — an inverse parser reading a rendered spec body back into `SpecDraft`") is delivered by Tasks 1-5 (the pure `parse_spec_markdown`) + Task 6 (CLI wiring reusing the apply path) + Task 7 (regression). Every clause of the request is covered: inverse parser (T1-5), reuse the same apply path as `--from-json` (T6, only deserialization differs), exactly-one-of semantics (T6), tolerance of missing/reordered/empty sections (T4), malformed→clear `ValueError` naming the failure (T5), and the render→parse round-trip against the real renderer (T3).

**Items 2 + 3 NOT touched.** PR #358 shipped item 2 (`_format_ambiguity` in `src/mship/cli/_resolve.py`) and item 3 (`docs/cli.md`), with `tests/cli/test_resolve_helper.py`. None of those files appear in this plan's File Structure — the only files touched are `src/mship/core/spec_draft.py`, `src/mship/cli/spec.py`, `tests/core/test_spec_markdown_parse.py`, `tests/cli/test_spec.py`. Confirmed no overlap.

**Placeholder scan.** No placeholders appear in any code block. The only placeholders are the sanctioned path/slug tokens `/home/bailey/development/repos/mship-workspace/.worktrees/spec-apply-from-file/mothership` (worktree path) and `spec-apply-from-file` (journal task slug), used exclusively in run/commit/journal shell lines — never in Python source or test code.

**Type consistency with the `SpecDraft` model.** `parse_spec_markdown` returns a `SpecDraft` built from exactly its fields: `problem`/`user_story`/`approach: str`, `non_goals`/`risks`/`affected_repos`/`acceptance_criteria`/`open_questions: list[str]`, `additional_sections: list[BodySection]` (verified against `src/mship/core/spec.py:156-169`). This is the identical type the JSON path constructs (`SpecDraft(**json.loads(raw))`), so both feed `apply_draft(spec, draft)` (`src/mship/core/spec_draft.py:93`) unchanged. AC/OQ items are text-only, matching `apply_draft`'s positional id re-derivation (`ac{i+1}`, `q{i+1}`) — the parser deliberately strips input ids so re-apply is stable.

**Round-trip property is tested against the real renderer.** Task 3 constructs a `SpecDraft`, calls the production `render_body` (`src/mship/core/spec_body.py:6`), parses the result, and asserts full `SpecDraft` equality — a genuine inverse test against real code, not a test-local re-implementation.

**Lossy-render limitation surfaced.** `render_body` is the only real spec-content renderer and it omits the list fields (they are YAML frontmatter, not body). This is documented in the Architecture section, the round-trip test scope (prose + additional_sections only), the `spec apply` docstring ("recovers only the prose + list sections it renders — the JSON path remains authoritative for anything a rendered body omits"), and the list-section grammar (which tolerates the three divergent in-repo AC conventions from `pr.py`, `workitem.py`, `spec_dispatch.py` since no single canonical one exists). The operator is told the JSON path stays authoritative for anything a rendered body cannot express.
