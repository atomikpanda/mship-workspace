# mship layout: separate serve layout + serve params on launch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `mship-layout` (approved) — `specs/2026-07-16-mship-layout.md`. WorkItem `wi-20260716124900-187af322`.

**Goal:** Add a distinct **serve layout** to `mship layout` — the normal workspace tabs plus a Serve tab — selected on demand via `mship layout launch --serve` and configured with serve's own flags, leaving the normal layout untouched.

**Architecture:** All changes are in one CLI module, `mship/cli/layout.py`. Refactor the single `_TEMPLATE` string into composable parts (head / base tabs / tail), add two pure functions (`serve_cli_args`, `render_serve_layout`), have `init` write both layout files, and extend `launch` to select + render the serve layout when serve flags are passed. `launch` renders the effective serve layout (flags baked into the `mship serve` command) to a temp file and execs `zellij --layout <tempfile>`. The pure render functions are unit-tested without launching zellij.

**Tech Stack:** Python, Typer (CLI), zellij (KDL layout format), pytest + `typer.testing.CliRunner`.

---

## File Structure

- **Modify** `mothership/src/mship/cli/layout.py` — the whole feature:
  - Split `_TEMPLATE` into `_LAYOUT_HEAD` + `_BASE_TABS` + `_LAYOUT_TAIL` (reconstructs the identical string).
  - Add `serve_cli_args(host, port, relay, relay_host) -> list[str]` (pure flag→args mapping).
  - Add `_serve_tab(serve_args) -> str` and `render_serve_layout(serve_args) -> str` (pure KDL builders).
  - `init`: write both `mothership.kdl` (normal) and `mothership-serve.kdl` (serve).
  - `launch`: add `--serve/--host/--port/--relay/--relay-host`; select + render the serve layout when any is passed.
- **Modify** `mothership/tests/cli/test_layout.py` — extend with unit tests for the new functions + init/launch behavior.

Run all tests from the task worktree with: `mship test --repos mothership --task <slug>` (or `uv run pytest tests/cli/test_layout.py -v` while iterating).

---

<!-- mship:task id=1 -->
### Task 1: Refactor `_TEMPLATE` into composable parts (no behavior change)

**Files:**
- Modify: `mothership/src/mship/cli/layout.py`
- Test: `mothership/tests/cli/test_layout.py`

The existing `_TEMPLATE` is one string: `layout {` + a `default_tab_template { … }` block + four tabs (`Plan`, `Dev`, `Review`, `Run`) + the closing `}`. Split it so the serve layout can reuse the head + base tabs. The reconstruction MUST be byte-identical (existing `test_layout_init_writes_file` compares `init` output to `_TEMPLATE`).

- [ ] **Step 1: Write the failing test**

Add to `tests/cli/test_layout.py`:

```python
from mship.cli.layout import _LAYOUT_HEAD, _BASE_TABS, _LAYOUT_TAIL


def test_template_reconstructs_from_parts():
    assert _TEMPLATE == _LAYOUT_HEAD + _BASE_TABS + _LAYOUT_TAIL


def test_base_tabs_has_all_four_tabs():
    for name in ("Plan", "Dev", "Review", "Run"):
        assert f'tab name="{name}"' in _BASE_TABS
    # The Serve tab is NOT part of the base tabs.
    assert 'name="Serve"' not in _BASE_TABS
```

- [ ] **Step 2: Run it to verify it fails**

Run: `uv run pytest tests/cli/test_layout.py::test_template_reconstructs_from_parts -v`
Expected: FAIL with `ImportError` (`_LAYOUT_HEAD` not defined).

- [ ] **Step 3: Refactor `layout.py`**

Replace the single `_TEMPLATE = """…"""` with the three parts, then compose `_TEMPLATE`. `_LAYOUT_HEAD` is `layout {\n` + the `default_tab_template` block. `_BASE_TABS` is the four `tab …` blocks (Plan focus, Dev, Review, Run) exactly as they currently appear (same indentation, same trailing newline before the closing brace). `_LAYOUT_TAIL` is `}\n`.

```python
_LAYOUT_HEAD = """\
layout {
    default_tab_template {
        pane size=1 borderless=true {
            plugin location="zellij:tab-bar"
        }
        children
        pane size=2 borderless=true {
            plugin location="zellij:status-bar"
        }
    }

"""

_BASE_TABS = """\
    tab name="Plan" focus=true {
        pane split_direction="vertical" {
            pane size="50%" name="Agent"
            pane split_direction="horizontal" size="50%" {
                pane name="Specs" command="mship" close_on_exit=false { args "view" "spec" "--watch"; }
                pane name="Status" command="mship" close_on_exit=false { args "view" "status" "--watch"; }
            }
        }
    }

    tab name="Dev" {
        pane split_direction="vertical" {
            pane size="60%" name="Editor" command="sh" close_on_exit=false {
                args "-c" "${EDITOR:-$(command -v nvim || command -v vim || command -v vi)} ."
            }
            pane split_direction="horizontal" size="40%" {
                pane name="Journal" command="mship" close_on_exit=false { args "view" "journal" "--watch"; }
                pane name="Status" command="mship" close_on_exit=false { args "view" "status" "--watch"; }
            }
        }
    }

    tab name="Review" {
        pane split_direction="vertical" {
            pane size="70%" name="Diff" command="mship" close_on_exit=false { args "view" "diff" "--watch"; }
            pane size="30%" split_direction="horizontal" {
                pane name="Shell"
                pane name="Journal" command="mship" close_on_exit=false { args "view" "journal" "--watch"; }
            }
        }
    }

    tab name="Run" {
        pane split_direction="vertical" {
            pane size="60%" name="Shell"
            pane split_direction="horizontal" size="40%" {
                pane name="Journal" command="mship" close_on_exit=false { args "view" "journal" "--watch"; }
                pane name="Status" command="mship" close_on_exit=false { args "view" "status" "--watch"; }
            }
        }
    }
"""

_LAYOUT_TAIL = "}\n"

_TEMPLATE = _LAYOUT_HEAD + _BASE_TABS + _LAYOUT_TAIL
```

IMPORTANT: after editing, verify the reconstruction test passes AND the pre-existing `test_layout_init_writes_file` and `test_review_tab_has_journal_pane` still pass (they assert on `_TEMPLATE` content). If `test_template_reconstructs_from_parts` fails, the split boundaries (whitespace/newlines) are off — adjust `_LAYOUT_HEAD`/`_BASE_TABS`/`_LAYOUT_TAIL` until the concatenation is byte-identical to the original template.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `uv run pytest tests/cli/test_layout.py -v`
Expected: PASS (new reconstruction tests + all pre-existing layout tests).

- [ ] **Step 5: Commit (pair with `mship journal`)**

```bash
git add src/mship/cli/layout.py tests/cli/test_layout.py
git commit -m "refactor: split layout _TEMPLATE into head/base-tabs/tail"
mship journal "split layout template into composable parts; tests green" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: Pure builders — `serve_cli_args` + `render_serve_layout`

**Files:**
- Modify: `mothership/src/mship/cli/layout.py`
- Test: `mothership/tests/cli/test_layout.py`

- [ ] **Step 1: Write the failing tests**

```python
from mship.cli.layout import serve_cli_args, render_serve_layout


def test_serve_cli_args_mapping():
    assert serve_cli_args(host=None, port=None, relay=False, relay_host=None) == []
    assert serve_cli_args(host="0.0.0.0", port=8080, relay=False, relay_host=None) == ["--host", "0.0.0.0", "--port", "8080"]
    assert serve_cli_args(host=None, port=None, relay=True, relay_host=None) == ["--relay"]
    assert serve_cli_args(host=None, port=None, relay=False, relay_host="r.example.com") == ["--relay-host", "r.example.com"]
    # Combined
    assert serve_cli_args(host="1.2.3.4", port=47100, relay=True, relay_host=None) == ["--host", "1.2.3.4", "--port", "47100", "--relay"]


def test_render_serve_layout_no_args_has_base_tabs_plus_serve():
    kdl = render_serve_layout([])
    for name in ("Plan", "Dev", "Review", "Run", "Serve"):
        assert f'tab name="{name}"' in kdl
    # Serve pane runs `mship serve` with no extra flags.
    assert 'command="mship"' in kdl
    assert 'args "serve";' in kdl
    # Serve tab comes AFTER Run, and Plan keeps focus.
    assert kdl.index('tab name="Run"') < kdl.index('tab name="Serve"')
    assert 'tab name="Plan" focus=true' in kdl


def test_render_serve_layout_threads_flags():
    kdl = render_serve_layout(["--relay", "--port", "8080"])
    assert 'args "serve" "--relay" "--port" "8080";' in kdl
```

- [ ] **Step 2: Run to verify they fail**

Run: `uv run pytest tests/cli/test_layout.py -k "serve_cli_args or render_serve_layout" -v`
Expected: FAIL with `ImportError` (functions not defined).

- [ ] **Step 3: Implement the builders**

Add to `layout.py`:

```python
from typing import Optional


def serve_cli_args(
    *, host: Optional[str], port: Optional[int], relay: bool, relay_host: Optional[str]
) -> list[str]:
    """Map `mship layout launch` serve options to `mship serve` CLI args, in a stable order."""
    args: list[str] = []
    if host is not None:
        args += ["--host", host]
    if port is not None:
        args += ["--port", str(port)]
    if relay:
        args += ["--relay"]
    if relay_host is not None:
        args += ["--relay-host", relay_host]
    return args


def _serve_tab(serve_args: list[str]) -> str:
    """The Serve tab KDL block: a single pane running `mship serve <serve_args>`."""
    # KDL args list: "serve" followed by each flag token, each double-quoted.
    tokens = " ".join(f'"{a}"' for a in ["serve", *serve_args])
    return (
        '\n    tab name="Serve" {\n'
        '        pane name="Serve" command="mship" close_on_exit=false { args '
        + tokens
        + "; }\n"
        "    }\n"
    )


def render_serve_layout(serve_args: list[str]) -> str:
    """The serve layout: the normal base tabs plus a Serve tab, as a full KDL document."""
    return _LAYOUT_HEAD + _BASE_TABS + _serve_tab(serve_args) + _LAYOUT_TAIL
```

- [ ] **Step 4: Run to verify they pass**

Run: `uv run pytest tests/cli/test_layout.py -k "serve_cli_args or render_serve_layout" -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/mship/cli/layout.py tests/cli/test_layout.py
git commit -m "feat: serve_cli_args + render_serve_layout pure builders"
mship journal "added pure serve-layout builders; tests green" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: `init` writes both layout files

**Files:**
- Modify: `mothership/src/mship/cli/layout.py`
- Test: `mothership/tests/cli/test_layout.py`

`init` currently writes only `mothership.kdl`. It must now also write `mothership-serve.kdl` (= `render_serve_layout([])`), with the same `--force`/exists guard applied to each file.

- [ ] **Step 1: Write the failing tests**

```python
def _serve_path(tmp_path: Path) -> Path:
    return tmp_path / ".config" / "zellij" / "layouts" / "mothership-serve.kdl"


def test_init_writes_both_layouts(tmp_path: Path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    result = runner.invoke(app, ["layout", "init"])
    assert result.exit_code == 0, result.output
    assert _expected_path(tmp_path).read_text() == _TEMPLATE
    serve = _serve_path(tmp_path).read_text()
    assert 'tab name="Serve"' in serve
    assert 'args "serve";' in serve


def test_init_refuses_when_serve_exists_without_force(tmp_path: Path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    _serve_path(tmp_path).parent.mkdir(parents=True, exist_ok=True)
    _serve_path(tmp_path).write_text("keep me")
    result = runner.invoke(app, ["layout", "init"])
    assert result.exit_code == 1
    assert _serve_path(tmp_path).read_text() == "keep me"
```

- [ ] **Step 2: Run to verify they fail**

Run: `uv run pytest tests/cli/test_layout.py -k "both_layouts or serve_exists" -v`
Expected: FAIL (only mothership.kdl written; serve file missing / not guarded).

- [ ] **Step 3: Implement `init` writing both**

Add a serve target path helper and extend `init`. Refuse if EITHER target exists without `--force`; write both when clear.

```python
def _serve_target_path() -> Path:
    return Path.home() / ".config" / "zellij" / "layouts" / "mothership-serve.kdl"
```

In `init`, replace the single-target logic with:

```python
    normal = _target_path()
    serve = _serve_target_path()
    existing = [p for p in (normal, serve) if p.exists()]
    if existing and not force:
        typer.echo(
            "Error: layout file(s) already exist: "
            + ", ".join(str(p) for p in existing)
            + ". Use --force to overwrite.",
            err=True,
        )
        raise typer.Exit(code=1)
    normal.parent.mkdir(parents=True, exist_ok=True)
    normal.write_text(_TEMPLATE)
    serve.write_text(render_serve_layout([]))
    typer.echo(f"Written: {normal}")
    typer.echo(f"Written: {serve}")
```

- [ ] **Step 4: Run tests**

Run: `uv run pytest tests/cli/test_layout.py -v`
Expected: PASS (new init tests + the pre-existing init/force tests still pass — note the pre-existing `test_layout_init_refuses_when_exists_without_force` still holds because `mothership.kdl` exists → refuse).

- [ ] **Step 5: Commit**

```bash
git add src/mship/cli/layout.py tests/cli/test_layout.py
git commit -m "feat: layout init writes both normal + serve layouts"
mship journal "init writes mothership.kdl + mothership-serve.kdl; tests green" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: `launch` gains `--serve` + serve flags and selects/renders the serve layout

**Files:**
- Modify: `mothership/src/mship/cli/layout.py`
- Test: `mothership/tests/cli/test_layout.py`

`launch` gains `--serve` (bool) plus `--host`, `--port`, `--relay`, `--relay-host`. If any is passed, render the effective serve layout to a temp file and exec `zellij --layout <tempfile>`. Otherwise exec `zellij --layout mothership` (unchanged).

- [ ] **Step 1: Write the failing tests**

```python
import re


def _capture_launch(monkeypatch, argv):
    captured = {}
    def fake_execvp(file, args):
        captured["file"] = file
        captured["args"] = args
    monkeypatch.setattr("os.execvp", fake_execvp)
    result = runner.invoke(app, argv)
    assert result.exit_code == 0, result.output
    return captured


def test_launch_no_serve_execs_normal(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    cap = _capture_launch(monkeypatch, ["layout", "launch"])
    assert cap["args"] == ["zellij", "--layout", "mothership"]


def test_launch_serve_renders_temp_layout(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    cap = _capture_launch(monkeypatch, ["layout", "launch", "--serve"])
    assert cap["args"][0:2] == ["zellij", "--layout"]
    layout_path = Path(cap["args"][2])
    assert layout_path != Path("mothership")  # a rendered file path, not the named layout
    body = layout_path.read_text()
    assert 'tab name="Serve"' in body
    assert 'args "serve";' in body


def test_launch_serve_threads_flags(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    cap = _capture_launch(monkeypatch, ["layout", "launch", "--serve", "--relay", "--port", "8080"])
    body = Path(cap["args"][2]).read_text()
    assert 'args "serve" "--relay" "--port" "8080";' in body


def test_launch_serve_flag_implies_serve(tmp_path, monkeypatch):
    # --relay with no --serve still selects the serve layout.
    monkeypatch.setenv("HOME", str(tmp_path))
    cap = _capture_launch(monkeypatch, ["layout", "launch", "--relay"])
    body = Path(cap["args"][2]).read_text()
    assert 'args "serve" "--relay";' in body
```

- [ ] **Step 2: Run to verify they fail**

Run: `uv run pytest tests/cli/test_layout.py -k launch -v`
Expected: FAIL (launch has no `--serve`/serve flags yet; unknown-option errors).

- [ ] **Step 3: Implement `launch`**

```python
    @layout_app.command()
    def launch(
        serve: bool = typer.Option(False, "--serve", help="Open the serve layout (adds a Serve tab running `mship serve`)."),
        host: Optional[str] = typer.Option(None, "--host", help="serve --host (implies --serve)."),
        port: Optional[int] = typer.Option(None, "--port", help="serve --port (implies --serve)."),
        relay: bool = typer.Option(False, "--relay", help="serve --relay (implies --serve). NOTE: collides with a separately-running serve."),
        relay_host: Optional[str] = typer.Option(None, "--relay-host", help="serve --relay-host (implies --serve)."),
    ):
        """Launch zellij with the mothership layout (replaces current process).

        With --serve (or any serve flag) launches the serve layout — the normal
        tabs plus a Serve tab running `mship serve <flags>`. WARNING: starting a
        serve here will collide with a separately-running `mship serve` (same
        relay subdomain / bind), so use it only when no standalone serve is up.
        """
        serve_selected = serve or host is not None or port is not None or relay or relay_host is not None
        if not serve_selected:
            os.execvp("zellij", ["zellij", "--layout", "mothership"])
            return
        import tempfile
        args = serve_cli_args(host=host, port=port, relay=relay, relay_host=relay_host)
        kdl = render_serve_layout(args)
        fd, path = tempfile.mkstemp(prefix="mothership-serve-", suffix=".kdl")
        with os.fdopen(fd, "w") as f:
            f.write(kdl)
        os.execvp("zellij", ["zellij", "--layout", path])
```

Note: `os.execvp` replaces the process, so the temp file is intentionally not cleaned up here (there is no post-exec code); it is a small file in the system temp dir. This is acceptable and keeps the launch path simple.

- [ ] **Step 4: Run tests**

Run: `uv run pytest tests/cli/test_layout.py -v`
Expected: PASS (all launch tests + everything from Tasks 1–3).

- [ ] **Step 5: Commit**

```bash
git add src/mship/cli/layout.py tests/cli/test_layout.py
git commit -m "feat: layout launch --serve renders + opens the serve layout"
mship journal "launch --serve + serve flags render the serve layout; tests green" --action committed
```
<!-- /mship:task -->

---

## Self-Review

**Spec coverage** (spec `mship-layout` acceptance criteria):
- AC1 (init writes both layouts) → Task 3.
- AC2 (plain launch = normal, unchanged) → Task 4 `test_launch_no_serve_execs_normal` + pre-existing test.
- AC3 (`--serve` → Serve tab runs `mship serve` default) → Task 4 `test_launch_serve_renders_temp_layout`.
- AC4 (`--serve --relay --port 8080` → threaded) → Task 4 `test_launch_serve_threads_flags`.
- AC5 (serve flag implies `--serve`) → Task 4 `test_launch_serve_flag_implies_serve`.
- AC6 (Serve tab appended after normal tabs; Plan keeps focus) → Task 2 `test_render_serve_layout_no_args_has_base_tabs_plus_serve`.
- AC7 (`render_serve_layout` pure, unit-tested per flag/combos) → Task 2.

**Non-goals honored:** no changes to `mship serve`; no restyle of view panes; no serve lifecycle management. The normal layout output is byte-identical (Task 1 reconstruction test + pre-existing `_TEMPLATE` assertions).

**Type consistency:** `serve_cli_args(*, host, port, relay, relay_host) -> list[str]` and `render_serve_layout(serve_args: list[str]) -> str` are used consistently in Tasks 2 and 4. `_LAYOUT_HEAD`/`_BASE_TABS`/`_LAYOUT_TAIL`/`_serve_tab` names are stable across tasks.

**Risk note for the implementer:** the KDL whitespace in Task 1 must reconstruct `_TEMPLATE` exactly — if `test_template_reconstructs_from_parts` fails, adjust the split boundaries (a stray newline is the usual culprit) rather than changing the assertion.
