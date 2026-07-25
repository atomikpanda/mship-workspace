# Serve-Host Management Console Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `serve-host-management-ui` (approved + dispatched 2026-07-25) — `mship spec show serve-host-management-ui`

**Depends on:** `connectivity-topology-layer` (PR #411). **Do not start until #411 is merged** — this console renders nothing but that PR's `GET /net/topology` payload, and a worktree branched off a main without `mship.core.topology` cannot build.

**Goal:** A read-only web console on the serve host that renders the connectivity topology and, for every setup action, shows the exact command pre-filled with that node's real values — built so the frontend can later ship separately as a re-skin rather than a rewrite.

**Architecture:** Every frontend artifact lives in one self-contained package (`src/mship/webui/`) that attaches to serve through a single mount registration. Templates render **exclusively** from the `GET /net/topology` payload — the same bytes an external client would fetch — so the HTTP contract is the only coupling point and the Jinja templates are deliberately disposable. Styling is Tailwind compiled by the standalone CLI binary; the binary is fetched by a task target into a gitignored dir and never committed, while the generated stylesheet **is** committed so installing, running, and testing mship need no toolchain.

**Tech Stack:** Jinja2 (new runtime dependency), FastAPI (existing serve), Tailwind CSS v4 standalone CLI binary, go-task, pytest.

---

## Verified before writing this plan

- **Non-Python assets already ship in the wheel.** `[tool.hatch.build.targets.wheel] packages = ["src/mship"]`, and the *installed* tool contains `mship/skills/**/SKILL.md`. So templates and a generated `.css` under `src/mship/webui/` ship without any `include`/`artifacts` config. (Checked the real install at `~/.local/share/uv/tools/mothership/.../site-packages/mship/skills/`.)
- **`jinja2` is a DEV-ONLY dep today** — importable in the dev venv (3.1.6, pulled in by mkdocs-material) but **absent** from the installed tool's site-packages. This is exactly the MOS-190/MOS-187 trap the repo already documents in the `check-runtime-deps` task: a runtime module importing a dev-only dep crashes the installed CLI at startup, and **pytest cannot catch it** because pytest always runs in the dev env. Task 1 declares it and uses that task as the proof.
- **serve has no static-mount or template precedent.** `create_app()` registers routes inline as closures with an app-level bearer dependency (`_make_auth_dependency`), so a mounted sub-app is authenticated by construction and `docs_url`/`openapi_url` are already disabled behind auth.
- **Tailwind standalone binaries exist** for the platforms that matter — all four release URLs used by Task 5 return HTTP 200 for v4.3.3 (`tailwindcss-linux-x64`, `-linux-arm64`, `-linux-x64-musl`, `-macos-arm64`), checked directly, not just via the releases API. v4 is CSS-first, so no JS config file lands in the Python repo.
- **The installed FastAPI (0.137.0) uses the request-first template signature** — `TemplateResponse(request, name, context=None, ...)` — which is the form Task 2's `render_topology` and Task 3's spy both use. If a much older FastAPI is ever pinned, the argument order flips and both need updating.
- **`Jinja2Templates` autoescapes by default** (`select_autoescape`, verified by rendering `<script>x</script>` and getting `&lt;script&gt;x&lt;/script&gt;`), so ac13 is about *not breaking* an existing property — hence Task 6 asserts no `|safe` rather than switching anything on.
- **Taskfile targets today:** `setup`, `test`, `check-runtime-deps`, `lint`, `run`. The new `webui:*` targets follow `check-runtime-deps`' style (a `desc`, a comment explaining *why*, then `cmds`).

## Design decision this plan settles: the version field

Two acceptance criteria pull against each other. **ac3** requires the template context to hold *nothing* beyond the topology payload (that is what makes an external frontend possible). **ac14** requires each page to show the mship version that answered the request — which is not in the payload.

Resolution: **add `mship_version` to the topology payload** (Task 3). It is an additive field on an already-versioned contract, so no consumer breaks, and it keeps the payload genuinely sufficient — an external frontend can render the identical footer from the endpoint alone. The alternative (passing the version into the context beside the payload) would satisfy ac14 by breaking ac3's whole point.

## File structure

**Create (all frontend material in ONE package):**
- `src/mship/webui/__init__.py` — the mount seam: `mount_webui(app, *, probe)` and nothing else public.
- `src/mship/webui/views.py` — the one view: payload in, `TemplateResponse` out.
- `src/mship/webui/templates/base.html` — shell: `<head>`, stylesheet link, footer (version + probed-at).
- `src/mship/webui/templates/topology.html` — the page: edge cards + setup-command cards.
- `src/mship/webui/tailwind.css` — Tailwind input (the `@import`/`@source` directives).
- `src/mship/webui/static/app.css` — **generated, committed**.
- `src/mship/webui/static/copy.js` — tiny inline-able copy-to-clipboard helper (no framework).
- `tests/webui/test_mount.py`, `test_render_contract.py`, `test_topology_page.py`, `test_assets.py`, `test_escaping.py`.

**Modify:**
- `pyproject.toml` — add `jinja2` to `[project.dependencies]`.
- `src/mship/core/topology.py` — add `mship_version` to the payload.
- `src/mship/core/serve.py` — ONE mount line.
- `Taskfile.yml` — `webui:tailwind-binary`, `webui:css`, `webui:css-check`.
- `.gitignore` — the tools dir.

---

<!-- mship:task id=1 -->
### Task 1: Declare jinja2 as a runtime dependency, and prove it

**Files:**
- Modify: `pyproject.toml`

This goes first because it is the failure mode this repo has already been bitten by twice, and no pytest run can detect it.

- [ ] **Step 1: Prove the gap exists right now**

Run: `ls /home/bailey/.local/share/uv/tools/mothership/lib/python*/site-packages/ | grep -c jinja2 || echo "ABSENT (this is the bug we are preventing)"`
Expected: `ABSENT …` — jinja2 is not in the runtime environment.

- [ ] **Step 2: Declare it**

In `pyproject.toml`, add to `[project.dependencies]` (keep the existing order, append after `cryptography`):

```toml
    "jinja2>=3.1",
```

- [ ] **Step 3: Prove the guard catches an undeclared dep**

Run: `cd <worktree>/mothership && task check-runtime-deps`
Expected: exit 0. This builds a throwaway venv with **runtime deps only** and imports `mship.cli`.

Then verify the guard actually covers the new import path — temporarily comment out the `jinja2>=3.1` line, re-run `task check-runtime-deps`, and confirm it FAILS with `ModuleNotFoundError: No module named 'jinja2'` once Task 2's module is imported at CLI-import time. If it passes with the line removed, the import is lazy and the guard does not cover it — note that in the journal and rely on Task 2's mount test instead.

> This check only fires for imports reachable from `import mship.cli`. Task 2 imports the webui package lazily inside `create_app`, so expect the guard to pass either way; the point of running it is to know which of the two is true rather than to assume.

- [ ] **Step 4: Commit**

```bash
git add pyproject.toml uv.lock
git commit -m "build: declare jinja2 as a runtime dependency for the serve console"
mship journal "declared jinja2 runtime dep (was dev-only via mkdocs-material; MOS-190 trap)" --action committed
```

> If `uv.lock` shows an unrelated `version = "0.5.x"` bump, that is CI's post-merge artifact — `git restore uv.lock` and stage only the real dependency change.
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: The isolated package and its single mount seam

**Files:**
- Create: `src/mship/webui/__init__.py`, `src/mship/webui/views.py`, `src/mship/webui/templates/base.html`, `src/mship/webui/templates/topology.html`, `src/mship/webui/static/app.css` (placeholder for now)
- Modify: `src/mship/core/serve.py`
- Test: `tests/webui/test_mount.py`

The isolation ACs (ac1, ac2) are structural, so they are the first thing built and the first thing tested.

- [ ] **Step 1: Write the failing test**

```python
# tests/webui/test_mount.py
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from mship.webui import mount_webui


def _payload():
    return {
        "version": 1, "mship_version": "0.5.20", "workspace": "ws",
        "probed_at": "2026-07-25T16:00:00+00:00",
        "edges": [{
            "kind": "relay", "name": "relay", "status": "ok", "code": "relay_ok",
            "detail": "reachable", "fix": None, "facts": {},
        }],
    }


def test_mount_serves_the_console():
    app = FastAPI()
    mount_webui(app, payload_source=_payload)
    with TestClient(app) as client:
        r = client.get("/ui")
    assert r.status_code == 200
    assert "text/html" in r.headers["content-type"]
    assert "relay" in r.text


def test_mount_serves_the_stylesheet():
    app = FastAPI()
    mount_webui(app, payload_source=_payload)
    with TestClient(app) as client:
        r = client.get("/ui/static/app.css")
    assert r.status_code == 200
    assert "text/css" in r.headers["content-type"]


def test_serve_has_exactly_one_ui_coupling_point():
    """ac1: serve.py's only UI-specific code is the mount registration."""
    from pathlib import Path

    import mship.core.serve as serve_mod

    source = Path(serve_mod.__file__).read_text()
    # The import + the call. No template names, asset paths, or /ui routes.
    assert source.count("mount_webui") == 2, "expected exactly an import and one call"
    for leaked in (".html", "app.css", "templates", '"/ui'):
        assert leaked not in source, f"UI detail {leaked!r} leaked into serve.py"


def test_serve_still_works_with_the_frontend_absent(monkeypatch):
    """ac2: the frontend is detachable — serve degrades, it does not break."""
    import builtins

    real_import = builtins.__import__

    def no_webui(name, *args, **kw):
        if name.startswith("mship.webui"):
            raise ImportError("frontend package removed")
        return real_import(name, *args, **kw)

    monkeypatch.setattr(builtins, "__import__", no_webui)
    monkeypatch.setenv("MSHIP_PR_WATCH_INTERVAL", "0")

    from mship.core.serve import create_app

    class _State:
        def load(self):
            class S:
                tasks = {}
            return S()

    import tempfile
    from pathlib import Path

    with tempfile.TemporaryDirectory() as tmp:
        specs = Path(tmp) / "specs"
        specs.mkdir()
        (Path(tmp) / ".mothership").mkdir()
        app = create_app(
            specs_dir=specs, state_manager=_State(), log_manager=None,
            workspace_root=Path(tmp), workspace_name="ws", auth_token="tok",
        )
        with TestClient(app) as client:
            # every non-UI endpoint still serves
            assert client.get("/health", headers={"Authorization": "Bearer tok"}).status_code == 200
            # the console is simply absent
            assert client.get("/ui", headers={"Authorization": "Bearer tok"}).status_code == 404
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mkdir -p tests/webui && touch tests/webui/__init__.py && uv run pytest tests/webui/test_mount.py -q > /tmp/w2.log 2>&1; echo "exit=$?"; tail -5 /tmp/w2.log`
Expected: non-zero — `ModuleNotFoundError: No module named 'mship.webui'`

- [ ] **Step 3: Write minimal implementation**

```python
# src/mship/webui/__init__.py
"""The serve-host management console — a self-contained frontend package.

ISOLATION IS THE POINT. Everything the console needs (templates, stylesheet,
Tailwind input, static assets) lives in this directory, and the only thing that
crosses the boundary is the topology payload — the same JSON an external client
gets from `GET /net/topology`. Two rules keep it that way:

1. Nothing in here imports outward into mship internals (no config objects, no
   stores, no `mship.core.*` beyond what the payload already carries). The caller
   supplies `payload_source`; this package never learns where it came from.
2. `mship.core.serve` couples to this package through `mount_webui` and nothing
   else — no template names, no asset paths, no /ui routes over there.

Consequence: replacing this package with a separately-shipped frontend is a
re-skin, not a rewrite. Build the new client against the versioned payload,
enable CORS for its origin (auth is already a header-borne bearer, not a
same-origin cookie), and delete this directory plus its one mount line. The Jinja
templates are deliberately disposable — no effort is spent making them reusable.
"""
from __future__ import annotations

from pathlib import Path
from typing import Callable

_PACKAGE_DIR = Path(__file__).parent
TEMPLATES_DIR = _PACKAGE_DIR / "templates"
STATIC_DIR = _PACKAGE_DIR / "static"

MOUNT_PATH = "/ui"


def mount_webui(app, *, payload_source: Callable[[], dict]) -> None:
    """Attach the console to `app` at /ui.

    `payload_source` returns the `GET /net/topology` payload — a plain dict. It
    is the ONLY data this package receives, which is what makes the frontend
    separately shippable (see the module docstring).
    """
    from fastapi import APIRouter
    from fastapi.staticfiles import StaticFiles

    from mship.webui.views import render_topology

    router = APIRouter()

    @router.get(MOUNT_PATH, include_in_schema=False)
    def ui(request):  # noqa: ANN001 - FastAPI injects Request
        return render_topology(request, payload_source())

    app.include_router(router)
    app.mount(
        f"{MOUNT_PATH}/static",
        StaticFiles(directory=str(STATIC_DIR)),
        name="webui-static",
    )
```

```python
# src/mship/webui/views.py
"""The one view. Payload in, HTML out.

The render context is EXACTLY the topology payload — see
`tests/webui/test_render_contract.py`. No Python objects, config, or store
handles enter a template, so an external frontend could produce the same page
from the endpoint response alone.
"""
from __future__ import annotations

from fastapi import Request
from fastapi.templating import Jinja2Templates

from mship.webui import TEMPLATES_DIR

#: Autoescaping is on by default in Jinja2Templates and must stay on: this page
#: renders config-derived strings (hostnames, subdomains, role names).
_templates = Jinja2Templates(directory=str(TEMPLATES_DIR))


def render_topology(request: Request, payload: dict):
    """Render the topology page from `payload` and nothing else."""
    return _templates.TemplateResponse(request, "topology.html", dict(payload))
```

```html
<!-- src/mship/webui/templates/base.html -->
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{% block title %}mship{% endblock %}</title>
    <!-- Local stylesheet only: the console must work with no internet. -->
    <link rel="stylesheet" href="/ui/static/app.css">
  </head>
  <body class="bg-white text-slate-900 dark:bg-slate-950 dark:text-slate-100">
    <main class="mx-auto max-w-4xl p-6">
      {% block content %}{% endblock %}
    </main>
    <footer class="mx-auto max-w-4xl px-6 pb-10 text-xs text-slate-500">
      <!-- A server-rendered page is a snapshot; say when and by what. -->
      mship {{ mship_version }} · probed {{ probed_at }} ·
      <a class="underline" href="/ui">refresh</a>
    </footer>
  </body>
</html>
```

```html
<!-- src/mship/webui/templates/topology.html -->
{% extends "base.html" %}
{% block title %}{{ workspace }} — connectivity{% endblock %}
{% block content %}
  <h1 class="text-2xl font-semibold">{{ workspace }}</h1>
  <p class="mt-1 text-sm text-slate-500">Connectivity topology</p>

  <ul class="mt-6 space-y-3">
    {% for edge in edges %}
      <li class="rounded-lg border border-slate-200 p-4 dark:border-slate-800">
        <div class="flex items-baseline gap-3">
          <span class="rounded px-2 py-0.5 text-xs font-medium
            {% if edge.status == 'ok' %}bg-emerald-100 text-emerald-900 dark:bg-emerald-900/40 dark:text-emerald-200
            {% elif edge.status == 'warn' %}bg-amber-100 text-amber-900 dark:bg-amber-900/40 dark:text-amber-200
            {% elif edge.status == 'fail' %}bg-red-100 text-red-900 dark:bg-red-900/40 dark:text-red-200
            {% else %}bg-slate-100 text-slate-700 dark:bg-slate-800 dark:text-slate-300{% endif %}">
            {{ edge.status }}
          </span>
          <span class="font-medium">{{ edge.name }}</span>
          <code class="text-xs text-slate-500">{{ edge.code }}</code>
        </div>
        <p class="mt-2 text-sm">{{ edge.detail }}</p>
        {% if edge.fix %}
          <p class="mt-2 text-sm text-slate-600 dark:text-slate-400">
            <strong>Fix:</strong> {{ edge.fix }}
          </p>
        {% endif %}
      </li>
    {% endfor %}
  </ul>
{% endblock %}
```

Create a placeholder `src/mship/webui/static/app.css` (Task 6 generates the real one):

```css
/* Generated by `task webui:css` — do not edit. Placeholder until Task 6. */
```

In `src/mship/core/serve.py`, add the import at the top of `create_app`'s import block and ONE call after the app is constructed (keep it to exactly these two mentions — `test_serve_has_exactly_one_ui_coupling_point` asserts it):

```python
    # The management console is an optional, self-contained frontend package.
    # If it has been removed, serve runs without it rather than failing.
    try:
        from mship.webui import mount_webui
    except ImportError:
        mount_webui = None
    if mount_webui is not None:
        mount_webui(app, payload_source=_topology_payload)
```

where `_topology_payload` is a small closure defined next to the `/net/topology` route so BOTH surfaces read the same function (no second probe path):

```python
    def _topology_payload() -> dict:
        from mship.core import topology as topo

        if config is None:
            return {
                "version": topo.SCHEMA_VERSION, "mship_version": _mship_version(),
                "workspace": workspace_name, "probed_at": "", "edges": [],
            }
        return topo.topology_payload(topo.probe_topology(
            config=config,
            state_dir=workspace_root / ".mothership",
            workspace_root=workspace_root,
        ))
```

and rewrite the existing `/net/topology` handler to `return _topology_payload()` when `config` is not None (keeping its 503 for the config-less case), so there is exactly one payload builder.

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/webui/test_mount.py -q > /tmp/w2.log 2>&1; echo "exit=$?"; tail -5 /tmp/w2.log`
Expected: `exit=0`, 4 passed.

- [ ] **Step 5: Commit**

```bash
git add src/mship/webui src/mship/core/serve.py tests/webui
git commit -m "feat(webui): isolated console package behind a single mount seam"
mship journal "webui package mounted at /ui; serve's only coupling is mount_webui; detachability tested" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: The render contract — payload in, nothing else

**Files:**
- Modify: `src/mship/core/topology.py` (add `mship_version`)
- Test: `tests/webui/test_render_contract.py`, `tests/core/test_topology_model.py` (extend)

This is the test that keeps the frontend separable. Without it, someone passes one convenient config object into a template and separability quietly dies.

- [ ] **Step 1: Write the failing test**

```python
# tests/webui/test_render_contract.py
"""ac3: the template render context IS the topology payload.

If this test fails because a new key was added to the context, the fix is to add
it to the ENDPOINT payload instead — otherwise a separately-shipped frontend
cannot render the page from the endpoint alone, which is the whole point of the
isolation constraint.
"""
from fastapi import FastAPI
from fastapi.testclient import TestClient

from mship.webui import mount_webui

PAYLOAD = {
    "version": 1, "mship_version": "0.5.20", "workspace": "ws",
    "probed_at": "2026-07-25T16:00:00+00:00",
    "edges": [{
        "kind": "relay", "name": "relay", "status": "fail",
        "code": "relay_unreachable", "detail": "down",
        "fix": "restart serve", "facts": {"host": "h"},
    }],
}


def test_context_contains_nothing_beyond_the_payload(monkeypatch):
    seen = {}

    import mship.webui.views as views

    real = views._templates.TemplateResponse

    def spy(request, name, context, *a, **kw):
        seen["context"] = dict(context)
        return real(request, name, context, *a, **kw)

    monkeypatch.setattr(views._templates, "TemplateResponse", spy)

    app = FastAPI()
    mount_webui(app, payload_source=lambda: PAYLOAD)
    with TestClient(app) as client:
        assert client.get("/ui").status_code == 200

    # Jinja2Templates injects `request` itself; everything else must be payload.
    extra = set(seen["context"]) - set(PAYLOAD) - {"request"}
    assert extra == set(), f"context keys not in the payload: {extra}"


def test_the_endpoint_payload_carries_everything_the_page_shows():
    """Every value the templates interpolate exists in the payload contract."""
    from pathlib import Path

    from mship.webui import TEMPLATES_DIR

    rendered_vars = set()
    for tpl in Path(TEMPLATES_DIR).glob("*.html"):
        text = tpl.read_text()
        for token in ("workspace", "probed_at", "mship_version"):
            if "{{ " + token + " }}" in text:
                rendered_vars.add(token)
    assert rendered_vars <= set(PAYLOAD), (
        f"templates render values absent from the payload: "
        f"{rendered_vars - set(PAYLOAD)}"
    )
    assert "mship_version" in rendered_vars, "ac14: the version must be shown"
```

```python
# tests/core/test_topology_model.py  — append
def test_payload_carries_the_mship_version():
    """The console footer shows which mship answered the request, and an
    external frontend must be able to render it from the endpoint alone."""
    from mship.core.topology import Topology, topology_payload

    payload = topology_payload(
        Topology(version=1, workspace="w", probed_at="t", edges=[])
    )
    assert isinstance(payload["mship_version"], str) and payload["mship_version"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/webui/test_render_contract.py tests/core/test_topology_model.py -q > /tmp/w3.log 2>&1; echo "exit=$?"; tail -6 /tmp/w3.log`
Expected: non-zero — `KeyError: 'mship_version'`

- [ ] **Step 3: Write minimal implementation**

In `src/mship/core/topology.py`, add the version resolver and the payload field:

```python
def _mship_version() -> str:
    """The running mship version, for the console footer. An additive payload
    field (see topology_payload): a server-rendered page is a snapshot, so it has
    to say which build produced it — and an external frontend must be able to
    render the same footer from the endpoint alone."""
    try:
        from importlib.metadata import version
        return version("mothership")
    except Exception:
        return "unknown"
```

and in `topology_payload`, add after `"version"`:

```python
        "mship_version": _mship_version(),
```

> Additive, so `SCHEMA_VERSION` does not change — existing consumers keep working and new ones can rely on it being present.

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/webui tests/core/test_topology_model.py -q > /tmp/w3.log 2>&1; echo "exit=$?"; tail -5 /tmp/w3.log`
Expected: `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/topology.py tests/webui/test_render_contract.py tests/core/test_topology_model.py
git commit -m "feat(topology): add mship_version to the payload so the page renders from it alone"
mship journal "render contract locked: context == payload; mship_version added to the payload rather than the context" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: Setup-action command cards (read-plus-guide, never execute)

**Files:**
- Modify: `src/mship/webui/templates/topology.html`, `src/mship/webui/views.py`
- Create: `src/mship/webui/actions.py`, `src/mship/webui/static/copy.js`
- Test: `tests/webui/test_topology_page.py`

For each setup action the console shows the exact command **pre-filled with that node's real values** plus a copy button, and performs no privileged mutation (ac9). The command strings are derived from the payload's `facts`, so this stays inside the render contract.

- [ ] **Step 1: Write the failing test**

```python
# tests/webui/test_topology_page.py
from fastapi import FastAPI
from fastapi.testclient import TestClient

from mship.webui import mount_webui


def _payload(edges):
    return {
        "version": 1, "mship_version": "0.5.20", "workspace": "ws",
        "probed_at": "t", "edges": edges,
    }


def _html(edges):
    app = FastAPI()
    mount_webui(app, payload_source=lambda: _payload(edges))
    with TestClient(app) as client:
        return client.get("/ui").text


def test_unmapped_role_shows_the_prefilled_command():
    html = _html([{
        "kind": "run_host", "name": "run_host:mac-studio", "status": "fail",
        "code": "run_host_unmapped", "detail": "no connection mapped",
        "fix": "run `mship run-host add mac-studio`",
        "facts": {"role": "mac-studio"},
    }])
    # the ROLE is filled in, not a <role> placeholder
    assert "mship run-host add mac-studio" in html
    assert "&lt;role&gt;" not in html


def test_relay_setup_command_uses_the_real_host():
    html = _html([{
        "kind": "relay", "name": "relay", "status": "absent",
        "code": "relay_not_configured", "detail": "not running",
        "fix": "run `mship serve --relay`",
        "facts": {"host": "relay.example.com", "relay_configured": True},
    }])
    assert "mship serve --relay" in html


def test_every_command_card_has_a_copy_affordance():
    html = _html([{
        "kind": "run_host", "name": "run_host:mac", "status": "fail",
        "code": "run_host_unmapped", "detail": "x", "fix": "y",
        "facts": {"role": "mac"},
    }])
    assert 'data-copy' in html          # the hook the copy helper binds to


def test_healthy_topology_shows_no_commands():
    html = _html([{
        "kind": "relay", "name": "relay", "status": "ok", "code": "relay_ok",
        "detail": "reachable", "fix": None, "facts": {},
    }])
    assert "data-copy" not in html


def test_no_mutating_routes_exist():
    """ac9: the console performs no privileged mutation — it is GET-only."""
    app = FastAPI()
    mount_webui(app, payload_source=lambda: _payload([]))
    methods = {m for r in app.routes for m in getattr(r, "methods", set()) or set()}
    assert methods <= {"GET", "HEAD"}, f"console exposes {methods - {'GET', 'HEAD'}}"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/webui/test_topology_page.py -q > /tmp/w4.log 2>&1; echo "exit=$?"; tail -6 /tmp/w4.log`
Expected: non-zero — no command text in the page.

- [ ] **Step 3: Write minimal implementation**

```python
# src/mship/webui/actions.py
"""Status code -> the command that fixes it, pre-filled from the edge's facts.

Data, not logic: one entry per code, each a template over `facts`. Kept here
rather than in the template so the mapping is testable, and kept inside this
package so it leaves with the frontend if the frontend is ever replaced.

The console SHOWS these; it never runs them. One serve bearer currently grants
approve + exec + gh-token (issue #370), so executing privileged mutations behind
that bearer would turn it into a full admin credential reachable over the relay.
"""
from __future__ import annotations

#: code -> (label, command template). `{}` fields are filled from edge["facts"].
_COMMANDS: dict[str, tuple[str, str]] = {
    "run_host_unmapped": (
        "Map this role on this machine",
        "mship run-host add {role} --pair-link '<paste from `mship pair` on that machine>'",
    ),
    "run_host_stale_token": (
        "Re-map with a fresh token",
        "mship run-host add {role} --pair-link '<paste a fresh link>'",
    ),
    "run_host_orphan_mapping": (
        "Drop the unused mapping",
        "mship run-host remove {role}",
    ),
    "run_host_not_bootstrapped": (
        "Bootstrap that machine",
        "mship bootstrap   # run on the remote, then restart `mship serve --relay` there",
    ),
    "relay_not_configured": ("Start a relay serve", "mship serve --relay"),
    "relay_not_running": ("Restart the relay serve", "mship serve --relay"),
    "relay_unreachable": ("Restart the relay serve", "mship serve --relay"),
    "relay_auth_failed": ("Re-pair this device", "mship pair"),
    "relay_subdomain_drift": ("Re-pair against the current subdomain", "mship pair"),
    "serve_relay_stale": ("Restart the relay serve", "mship serve --relay"),
    "gh_auth_none": (
        "Point this machine at a token broker",
        "export MSHIP_GH_BROKER_URL=<serve url>  MSHIP_SERVE_TOKEN=<bearer>",
    ),
    "run_hosts_none_declared": (
        "Declare a role in mothership.yaml",
        "run_hosts: [<role-name>]   # add to mothership.yaml",
    ),
    "run_hosts_store_unreadable": (
        "Re-map roles after fixing the store",
        "mship run-host add <role>",
    ),
}


def command_for(edge: dict) -> dict | None:
    """`{label, command}` for an unhealthy edge, or None when there is nothing
    to do. Missing facts leave their placeholder visible rather than raising —
    a half-filled command is still better guidance than a blank card."""
    entry = _COMMANDS.get(edge.get("code", ""))
    if entry is None or edge.get("status") in ("ok", None):
        return None
    label, template = entry
    facts = edge.get("facts") or {}
    try:
        command = template.format(**facts)
    except (KeyError, IndexError):
        command = template
    return {"label": label, "command": command}
```

In `views.py`, attach the command to each edge — note this stays within the contract because it is derived **from the payload**, adding no new source of data:

```python
def render_topology(request: Request, payload: dict):
    """Render the topology page from `payload` and nothing else.

    The only transform is `command_for`, a pure function OF THE PAYLOAD — it
    introduces no new data source, so an external frontend can compute the same
    thing from the same response.
    """
    context = dict(payload)
    context["edges"] = [
        {**edge, "action": command_for(edge)} for edge in payload.get("edges", [])
    ]
    return _templates.TemplateResponse(request, "topology.html", context)
```

In `topology.html`, inside the edge `<li>` after the fix paragraph:

```html
        {% if edge.action %}
          <div class="mt-3 rounded-md bg-slate-50 p-3 dark:bg-slate-900">
            <div class="flex items-center justify-between gap-3">
              <span class="text-xs font-medium text-slate-600 dark:text-slate-400">
                {{ edge.action.label }}
              </span>
              <button type="button" data-copy="{{ edge.action.command }}"
                class="rounded border border-slate-300 px-2 py-1 text-xs
                       hover:bg-white dark:border-slate-700 dark:hover:bg-slate-800">
                Copy
              </button>
            </div>
            <pre class="mt-2 overflow-x-auto text-xs"><code>{{ edge.action.command }}</code></pre>
          </div>
        {% endif %}
```

and before `</body>` in `base.html`:

```html
    <script src="/ui/static/copy.js"></script>
```

```javascript
// src/mship/webui/static/copy.js
// Copy-to-clipboard for command cards. No framework, no network.
document.addEventListener('click', function (event) {
  var button = event.target.closest('[data-copy]');
  if (!button) return;
  navigator.clipboard.writeText(button.getAttribute('data-copy')).then(function () {
    var original = button.textContent;
    button.textContent = 'Copied';
    setTimeout(function () { button.textContent = original; }, 1200);
  });
});
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/webui -q > /tmp/w4.log 2>&1; echo "exit=$?"; tail -5 /tmp/w4.log`
Expected: `exit=0`.

Note the render-contract test from Task 3 must still pass — `action` is added to each edge dict, not as a new top-level context key. If it fails, that is the isolation guard doing its job: keep the derivation inside `edges`.

- [ ] **Step 5: Commit**

```bash
git add src/mship/webui tests/webui
git commit -m "feat(webui): pre-filled setup commands with copy affordance; GET-only console"
mship journal "command cards derived purely from payload facts; asserted the console exposes no non-GET routes" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: Tailwind via the standalone binary, with a drift check

**Files:**
- Create: `src/mship/webui/tailwind.css`
- Modify: `src/mship/webui/static/app.css` (generated), `Taskfile.yml`, `.gitignore`
- Test: `tests/webui/test_assets.py`

The binary is never committed (tens of megabytes); the **generated stylesheet is**, so installing/running/testing needs no toolchain. The cost of committing a build artifact is staleness, so a check regenerates and compares.

- [ ] **Step 1: Write the failing test**

```python
# tests/webui/test_assets.py
"""ac11/ac12: assets are self-contained and the page works in both schemes."""
from pathlib import Path

from fastapi import FastAPI
from fastapi.testclient import TestClient

from mship.webui import STATIC_DIR, TEMPLATES_DIR, mount_webui


def _html():
    app = FastAPI()
    mount_webui(app, payload_source=lambda: {
        "version": 1, "mship_version": "0.5.20", "workspace": "ws",
        "probed_at": "t", "edges": [],
    })
    with TestClient(app) as client:
        return client.get("/ui").text


def test_no_off_host_asset_references():
    """The console must work with no internet: no CDN, font, script, or
    stylesheet from another origin."""
    html = _html()
    for marker in ("http://", "https://", "//cdn", "fonts.googleapis", "unpkg", "jsdelivr"):
        assert marker not in html, f"off-host reference {marker!r} in the page"


def test_stylesheet_is_committed_and_non_trivial():
    css = (Path(STATIC_DIR) / "app.css").read_text()
    assert len(css) > 1000, "app.css looks like a placeholder — run `task webui:css`"
    assert "--tw" in css or "tailwind" in css.lower()


def test_dark_scheme_is_styled():
    css = (Path(STATIC_DIR) / "app.css").read_text()
    assert "prefers-color-scheme" in css, "no dark-scheme rules were generated"


def test_every_utility_class_used_by_a_template_is_in_the_stylesheet():
    """The drift hazard, as a test: a template class that was never compiled
    renders unstyled and nothing else complains."""
    import re

    css = (Path(STATIC_DIR) / "app.css").read_text()
    missing = []
    for tpl in Path(TEMPLATES_DIR).glob("*.html"):
        for match in re.finditer(r'class="([^"]+)"', tpl.read_text()):
            for cls in match.group(1).split():
                if "{" in cls or "}" in cls:      # skip Jinja-interpolated
                    continue
                # Tailwind escapes some characters in the emitted selector.
                needle = cls.replace(":", r"\:").replace("/", r"\/").replace(".", r"\.")
                if needle not in css:
                    missing.append(cls)
    assert not missing, f"classes used but not compiled: {sorted(set(missing))}"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/webui/test_assets.py -q > /tmp/w5.log 2>&1; echo "exit=$?"; tail -6 /tmp/w5.log`
Expected: non-zero — `app.css looks like a placeholder`.

- [ ] **Step 3: Write the input CSS and the task targets**

```css
/* src/mship/webui/tailwind.css — Tailwind INPUT. Compiled to static/app.css by
   `task webui:css`. v4 is CSS-first: no JS config file in a Python repo. */
@import "tailwindcss";

/* Scan the templates for utility classes. */
@source "./templates/*.html";
```

In `Taskfile.yml` (matching the existing style — `desc`, a *why* comment, then `cmds`):

```yaml
  webui:tailwind-binary:
    desc: Fetch the pinned standalone Tailwind CLI into .tools/ (gitignored, never committed)
    # The standalone binary removes any need for node/npm in this Python repo.
    # It is tens of megabytes, so it is fetched on demand into a gitignored dir
    # rather than committed — only contributors who edit templates need it. The
    # GENERATED stylesheet is what ships (see webui:css).
    vars:
      TAILWIND_VERSION: v4.3.3
    cmds:
      - |
        set -eu
        mkdir -p .tools
        if [ -x .tools/tailwindcss ]; then exit 0; fi
        os="$(uname -s)"; arch="$(uname -m)"
        case "$os/$arch" in
          Linux/x86_64)  asset=tailwindcss-linux-x64 ;;
          Linux/aarch64) asset=tailwindcss-linux-arm64 ;;
          Darwin/arm64)  asset=tailwindcss-macos-arm64 ;;
          Darwin/x86_64) asset=tailwindcss-macos-x64 ;;
          *) echo "no pinned Tailwind binary for $os/$arch — install tailwindcss manually onto PATH and re-run" >&2; exit 1 ;;
        esac
        # musl (Alpine): the glibc build will not run there.
        if [ "$os" = Linux ] && ! ldd /bin/sh 2>/dev/null | grep -q GNU; then
          case "$arch" in x86_64) asset=tailwindcss-linux-x64-musl ;; aarch64) asset=tailwindcss-linux-arm64-musl ;; esac
        fi
        url="https://github.com/tailwindlabs/tailwindcss/releases/download/{{.TAILWIND_VERSION}}/$asset"
        echo "fetching $asset ({{.TAILWIND_VERSION}})"
        curl -fsSL "$url" -o .tools/tailwindcss
        chmod +x .tools/tailwindcss

  webui:css:
    desc: Compile src/mship/webui/tailwind.css -> static/app.css (the committed stylesheet)
    deps: [webui:tailwind-binary]
    cmds:
      - .tools/tailwindcss -i src/mship/webui/tailwind.css -o src/mship/webui/static/app.css --minify

  webui:css-check:
    desc: Fail if the committed stylesheet is stale (a template class was added without recompiling)
    # Committing a build artifact is normally a smell; it is deliberate here so
    # users never need a Tailwind binary to install or test mship. This check
    # removes the usual downside — silent staleness — by making a mismatch loud.
    deps: [webui:tailwind-binary]
    cmds:
      - |
        set -eu
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        .tools/tailwindcss -i src/mship/webui/tailwind.css -o "$tmp/app.css" --minify
        if ! diff -q "$tmp/app.css" src/mship/webui/static/app.css >/dev/null; then
          echo "src/mship/webui/static/app.css is stale — run \`task webui:css\` and commit the result" >&2
          exit 1
        fi
```

In `.gitignore`, add:

```
.tools
```

> No trailing slash — the same footgun as the `.codegraph` symlink entry.

- [ ] **Step 4: Generate, then verify**

```bash
task webui:css
task webui:css-check          # must pass immediately after generating
uv run pytest tests/webui -q > /tmp/w5.log 2>&1; echo "exit=$?"; tail -5 /tmp/w5.log
git status --short .tools     # MUST be empty: the binary is never tracked
```

Expected: `webui:css-check` exits 0, tests pass, `.tools` untracked.

Then prove the drift check actually catches drift: add a class (e.g. `tracking-tight`) to a template, run `task webui:css-check`, and confirm it FAILS; regenerate with `task webui:css` and confirm it passes again.

- [ ] **Step 5: Wire it into CI**

Add `webui:css-check` to whatever the docs/build workflow runs on a pull request (see `.github/workflows/`), so a stale stylesheet fails a PR rather than shipping unstyled.

- [ ] **Step 6: Commit**

```bash
git add src/mship/webui/tailwind.css src/mship/webui/static/app.css Taskfile.yml .gitignore .github/workflows tests/webui/test_assets.py
git commit -m "build(webui): Tailwind via the standalone binary; commit the stylesheet, check for drift"
mship journal "tailwind standalone wired; binary gitignored, stylesheet committed, drift check proven to catch an uncompiled class" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: Escaping and secret-absence

**Files:**
- Test: `tests/webui/test_escaping.py`

Two safety properties, each as a test: config-derived strings are escaped (they reach the page from `mothership.yaml` and the relay record), and no secret is rendered.

- [ ] **Step 1: Write the test**

```python
# tests/webui/test_escaping.py
"""ac10/ac13: nothing is injectable, and nothing secret is rendered."""
from fastapi import FastAPI
from fastapi.testclient import TestClient

from mship.webui import mount_webui

SECRET = "SENTINEL-should-never-render"


def _html(payload):
    app = FastAPI()
    mount_webui(app, payload_source=lambda: payload)
    with TestClient(app) as client:
        return client.get("/ui").text


def test_config_derived_values_are_escaped():
    html = _html({
        "version": 1, "mship_version": "0.5.20",
        "workspace": '<script>alert("ws")</script>',
        "probed_at": "t",
        "edges": [{
            "kind": "run_host", "name": "run_host:<img src=x onerror=alert(1)>",
            "status": "fail", "code": "run_host_unmapped",
            "detail": '<script>alert("detail")</script>',
            "fix": "<b>not bold</b>",
            "facts": {"role": "<svg onload=alert(1)>"},
        }],
    })
    assert "<script>alert" not in html
    assert "onerror=alert" not in html
    assert "&lt;script&gt;" in html          # escaped, not dropped
    assert "<b>not bold</b>" not in html


def test_no_safe_filter_on_any_template_value():
    """A single `|safe` would silently undo the escaping above."""
    from pathlib import Path

    from mship.webui import TEMPLATES_DIR

    for tpl in Path(TEMPLATES_DIR).glob("*.html"):
        text = tpl.read_text()
        assert "|safe" not in text and "| safe" not in text, f"{tpl.name} uses |safe"
        assert "autoescape false" not in text


def test_a_secret_in_the_payload_would_still_not_be_rendered_blindly():
    """The topology layer already redacts, so this is belt-and-braces: the page
    renders only known fields, never a dump of `facts`."""
    html = _html({
        "version": 1, "mship_version": "0.5.20", "workspace": "ws",
        "probed_at": "t",
        "edges": [{
            "kind": "run_host", "name": "run_host:mac", "status": "ok",
            "code": "run_host_ok", "detail": "reachable", "fix": None,
            "facts": {"role": "mac", "token": SECRET},
        }],
    })
    assert SECRET not in html
```

- [ ] **Step 2: Run it**

Run: `uv run pytest tests/webui/test_escaping.py -q > /tmp/w6.log 2>&1; echo "exit=$?"; tail -8 /tmp/w6.log`
Expected: `exit=0`. If `test_a_secret...` fails, a template is iterating `facts` wholesale — render named fields only.

- [ ] **Step 3: Commit**

```bash
git add tests/webui/test_escaping.py
git commit -m "test(webui): escaping of config-derived values; no facts dump reaches the page"
mship journal "escaping + no-secret-render tests; asserted no |safe anywhere in the templates" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=7 -->
### Task 7: Full verification, then finish

**Files:** none (verification only)

- [ ] **Step 1: Full suite**

Run: `uv run pytest > /tmp/full.log 2>&1; echo "exit=$?"; tail -12 /tmp/full.log`
Expected: `exit=0`. Never trust a piped summary — check the echoed exit code.

- [ ] **Step 2: The runtime-dep guard (this is the one pytest cannot do)**

Run: `task check-runtime-deps`
Expected: exit 0 — the installed-shape environment can import the CLI with jinja2 declared.

- [ ] **Step 3: The detachability claim, for real**

```bash
mv src/mship/webui /tmp/webui-parked
uv run pytest -q > /tmp/detached.log 2>&1; echo "suite without the frontend: exit=$?"
mv /tmp/webui-parked src/mship/webui
```

Expected: the non-webui suite still passes (the `tests/webui/*` files will error on import — that is expected; confirm nothing *else* fails). This is the physical version of ac2.

- [ ] **Step 4: Look at it**

```bash
uv run mship serve --port 47199 &
sleep 2
curl -s -H "Authorization: Bearer $(cat .mothership/serve-token)" http://127.0.0.1:47199/ui | head -40
kill %1
```

Expected: HTML with the edge list. Also open it in a browser and check both light and dark schemes, and that the copy button works.

- [ ] **Step 5: Record evidence and finish**

```bash
mship test --repos mothership
mship finish --task serve-host-management-ui
```

Then scope the PR body per repo convention (`mship finish` writes the raw spec title and all 15 ACs) and note that the console needs `scripts/redeploy-serve.sh` before it is reachable on the live serve.
<!-- /mship:task -->

---

## Self-review

**1. Spec coverage** — all 15 ACs map to a task:

| AC | Where |
|---|---|
| ac1 one package, single mount seam | Task 2 (`test_serve_has_exactly_one_ui_coupling_point`) |
| ac2 detachable | Task 2 (import-blocked test) + Task 7 Step 3 (physically moved away) |
| ac3 context == payload | Task 3 |
| ac4 header bearer, not cookie | Inherited: serve's `_make_auth_dependency` reads `Authorization`; asserted implicitly by every test passing a bearer header. **No cookie/session code is introduced** — the plan adds none, which is the AC. |
| ac5 /ui from committed assets, no build step | Task 2 + Task 5 (`test_stylesheet_is_committed_and_non_trivial`) |
| ac6 task target fetches the pinned binary, OS/arch resolved or explicit failure | Task 5 |
| ac7 drift check, in CI | Task 5 (Steps 4–5) |
| ac8 full topology rendered with status + fix | Task 2 + Task 4 |
| ac9 pre-filled commands, no mutation | Task 4 (`test_no_mutating_routes_exist`) |
| ac10 no secret rendered | Task 6 |
| ac11 no off-host requests | Task 5 |
| ac12 light + dark | Task 5 (`test_dark_scheme_is_styled`) + Task 7 Step 4 (eyes on it) |
| ac13 autoescaped, no `\|safe` | Task 6 |
| ac14 version + probed-at shown | Task 3 (payload field) + Task 2 (footer) |
| ac15 suite passes, rendering unit-tested without a real server | Task 7 (all webui tests use `TestClient`, no live server) |

**2. Placeholder scan** — no TBDs. Two steps deliberately ask the implementer to *check* rather than assume: whether `check-runtime-deps` covers a lazy import (Task 1 Step 3), and which workflow file to add the drift check to (Task 5 Step 5).

**3. Type consistency** — `mount_webui(app, *, payload_source)` is defined in Task 2 and called identically in Tasks 3, 4, 5, 6. `render_topology(request, payload)` gains only the `action` derivation in Task 4. `command_for(edge) -> dict | None` returns `{label, command}`, matching `edge.action.label` / `edge.action.command` in the template. `TEMPLATES_DIR` / `STATIC_DIR` / `MOUNT_PATH` are defined once in `__init__.py` and imported from there everywhere.

**One risk this plan does not fully retire:** `test_every_utility_class_used_by_a_template_is_in_the_stylesheet` (Task 5) matches escaped class names against the minified CSS as a string. That is a heuristic — Tailwind may emit a selector shape the naive escaping misses, producing a false failure. If it proves flaky, delete it and rely on `webui:css-check`, which is the authoritative drift guard; do not weaken `css-check` to make the heuristic pass.
