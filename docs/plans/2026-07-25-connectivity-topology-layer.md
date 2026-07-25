# Connectivity Topology + Diagnosis Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `connectivity-topology-layer` (approved 2026-07-25) — `mship spec show connectivity-topology-layer`

**Goal:** One read-only `probe_topology()` that reports this machine's connectivity graph with a machine-readable status code and an actionable fix hint per edge, surfaced by three thin callers: `mship net status`, a `mship doctor` connectivity group, and `GET /net/topology` on serve.

**Architecture:** A new `mship.core.topology` module owns the model (`Edge`, `Topology`), the status-code vocabulary, the JSON payload, and per-edge probing. It reuses existing owners rather than reimplementing them: `relay.health` for HTTP reachability, `relay.runtime` for the relay serve record, `run_host.store` for role→connection resolution, `gh_auth` for the GitHub auth-model precedence, and `relay.contract` for egress prefixes. Probing is read-only, timeout-bounded, and never raises — a broken environment is the expected input, so every failure becomes an edge status plus a fix hint. The `GET /net/topology` payload is the UI contract consumed by the serve-host console (spec `serve-host-management-ui`), so it carries a schema version and must be renderable on its own.

**Tech Stack:** Python 3.12, typer (CLI), FastAPI (serve), httpx (probes), pytest. Frozen dataclasses for the model; injected `probe`/`shell`/`now` callables so the suite needs no live network.

---

## Searches run before writing this plan

Stated per CLAUDE.md, so a reviewer can see why each piece of new code has no existing owner:

- `codegraph explore "doctor checks registry..."` → `core/doctor.py` owns `CheckResult(name, status, message)` and `DoctorChecker.run()`. **Reused**, not replaced: the connectivity group appends `CheckResult`s.
- `codegraph explore "run host role resolution..."` → `core/run_host/store.py` owns `RunHostStore` (incl. `MSHIP_RUN_HOST_<ROLE>_{URL,TOKEN}` env precedence and `redacted_list()`) and `resolve_run_host`, whose `RunHostError` messages already carry three of the spec's fix hints verbatim. **Reused as the source of those hints.**
- `codegraph explore "relay runtime state file..."` → `core/relay/runtime.py` owns `read_runtime_record` / `live_runtime_record`; `core/relay/tunnel.py` owns `device_subdomain`/`device_id`/`opaque_slug`. **Reused.**
- `codegraph explore "serve FastAPI app..."` → `core/serve.py` `create_app()` registers routes inline with an app-level bearer dependency (`_make_auth_dependency`), so a new endpoint is authenticated by construction.
- `codegraph explore "gh_preflight: detect which GitHub auth model is active..."` → `core/gh_preflight.run_preflight` encodes the auth precedence (relay-attach > explicit/GH_TOKEN/GITHUB_TOKEN > broker > none) but **strictly** (network verification, loud failure, no tests found covering it). Topology needs the *classification* only, and must never fail loudly. Decision: add a pure `classify_gh_auth()` to `core/gh_auth.py` — the module that already documents this precedence for `resolve_token` — and leave `run_preflight` untouched. Pre-existing duplication of the precedence between `gh_auth` and `gh_preflight` is **flagged, not refactored** (CLAUDE.md: don't refactor pre-existing duplication unless asked); refactoring an untested strict-auth path is not this change's job.
- `grep "unreachable via relay|not bootstrapped|rejected the bearer token"` → `core/remote_client.py:_http_status_message` owns the 503/401 prose. Topology maps status codes to its own per-edge hints (a run-host 401 fix is `mship run-host add <role>`, not the phone's "re-scan the QR"), so the codes are new but the wording follows the existing messages.
- **No `net` command group exists** (`grep "\"net\"" src/mship/cli/__init__.py` → no matches), so `mship net` is free.
- **No existing owner for reachability-with-status-code.** `relay/health.py:verify_relay_reachable` probes `/health` bounded and never raises, but returns only `(ok, prose)`. Task 3 extracts `probe_health()` from it (status code + error) and has `verify_relay_reachable` delegate, so there stays exactly ONE prober. Its 8 existing tests in `tests/core/relay/test_health.py` are the regression net.

## File structure

**Create:**
- `src/mship/core/topology.py` — status codes, `Edge`/`Topology`, `topology_payload()`, `probe_topology()` and the per-edge probes. One file: the edges share the vocabulary and are meaningless apart.
- `src/mship/cli/net.py` — the `mship net` group (`status`).
- `tests/core/test_topology_model.py` — model + payload + version.
- `tests/core/test_topology_probe.py` — per-edge status paths with injected probes.
- `tests/core/test_topology_redaction.py` — the secret-absence test (its own file: it is a security AC, and it must stay easy to find).
- `tests/cli/test_net_status.py` — CLI human/JSON rendering.
- `tests/core/test_serve_net_topology.py` — the endpoint.

**Modify:**
- `src/mship/core/relay/health.py` — extract `probe_health()`; `verify_relay_reachable` delegates.
- `src/mship/core/relay/keys.py` — add read-only `subdomain_secret_path()` / `relay_key_path()`; the `ensure_*` functions use them (topology must never generate a key).
- `src/mship/core/gh_auth.py` — add `classify_gh_auth()`.
- `src/mship/core/doctor.py` — `DoctorChecker` gains `probe_network`; `run()` appends the connectivity group.
- `src/mship/cli/doctor.py` — pass `probe_network` from a new `--no-network` flag.
- `src/mship/core/serve.py` — `GET /net/topology`.
- `src/mship/cli/__init__.py` — register the `net` group.
- `docs/remote-run.md` — point the troubleshooting table at `mship net status`.
- `mkdocs.yml` — nav entry for the new reference page (only if a new page is added; see Task 10).

---

<!-- mship:task id=1 -->
### Task 1: Topology model, status codes, and payload

**Files:**
- Create: `src/mship/core/topology.py`
- Test: `tests/core/test_topology_model.py`

Pure data. No I/O, no probing — those arrive in Tasks 3–5. The status-code constants are defined here in one place because both the payload consumers (console, doctor) and every probe branch below reference them.

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_topology_model.py
import json

from mship.core.topology import (
    SCHEMA_VERSION,
    Edge,
    Topology,
    topology_payload,
)


def _edge(**kw):
    base = dict(
        kind="relay", name="relay", status="fail",
        code="relay_unreachable", detail="could not reach https://x/health",
        fix="check the relay is up", facts={"host": "relay.example.com"},
    )
    base.update(kw)
    return Edge(**base)


def test_payload_carries_schema_version_and_edges():
    t = Topology(
        version=SCHEMA_VERSION,
        workspace="mship-workspace",
        probed_at="2026-07-25T16:00:00+00:00",
        edges=[_edge()],
    )
    payload = topology_payload(t)

    assert payload["version"] == SCHEMA_VERSION
    assert payload["workspace"] == "mship-workspace"
    assert payload["probed_at"] == "2026-07-25T16:00:00+00:00"
    assert payload["edges"][0] == {
        "kind": "relay",
        "name": "relay",
        "status": "fail",
        "code": "relay_unreachable",
        "detail": "could not reach https://x/health",
        "fix": "check the relay is up",
        "facts": {"host": "relay.example.com"},
    }


def test_payload_is_json_serializable():
    t = Topology(version=SCHEMA_VERSION, workspace="w", probed_at="t", edges=[_edge()])
    assert json.loads(json.dumps(topology_payload(t)))["version"] == SCHEMA_VERSION


def test_healthy_edge_has_no_fix():
    e = _edge(status="ok", code="relay_ok", fix=None)
    assert topology_payload(
        Topology(version=SCHEMA_VERSION, workspace="w", probed_at="t", edges=[e])
    )["edges"][0]["fix"] is None


def test_status_values_are_constrained():
    # The four statuses a caller may branch on; `absent` means "not configured
    # on this machine", which is not a problem to fix.
    from mship.core.topology import STATUSES
    assert STATUSES == ("ok", "warn", "fail", "absent")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/connectivity-topology-layer/mothership && uv run pytest tests/core/test_topology_model.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'mship.core.topology'`

- [ ] **Step 3: Write minimal implementation**

```python
# src/mship/core/topology.py
"""Read-only connectivity topology: what this machine is wired to, and whether
each edge is healthy.

ONE implementation, three thin callers — `mship net status`, `mship doctor`'s
connectivity group, and `GET /net/topology` on serve — so probe logic lives in
exactly one module.

Two invariants the callers depend on:

1. **Read-only.** Nothing here creates, writes, or rotates state. That rules out
   the `ensure_*` helpers in `relay.keys` (they generate on absence) — this
   module reads their paths instead.
2. **Never raises.** A broken environment is the EXPECTED input; this tool is
   most needed exactly when connectivity is broken. Every failure becomes an
   edge status plus a fix hint, and every network probe is timeout-bounded.

`GET /net/topology`'s payload is the UI contract for the serve-host console, so
it carries `version` (SCHEMA_VERSION) and must be renderable on its own — no
companion in-process data.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

SCHEMA_VERSION = 1

#: Bound on every network probe. Short on purpose: `doctor` was fast before
#: connectivity checks existed, and an unreachable edge must not stall it.
PROBE_TIMEOUT_SECONDS = 3.0

#: `absent` = not configured on this machine (nothing to fix), distinct from
#: `fail` = configured but broken.
STATUSES = ("ok", "warn", "fail", "absent")

# --- status codes ---------------------------------------------------------
# One code per distinguishable state so a UI can branch without parsing prose.
# The prose lives in `Edge.detail` / `Edge.fix`.

SERVE_RELAY_RUNNING = "serve_relay_running"
SERVE_RELAY_STALE = "serve_relay_stale"
SERVE_RELAY_ABSENT = "serve_relay_absent"

RELAY_OK = "relay_ok"
RELAY_UNREACHABLE = "relay_unreachable"
RELAY_AUTH_FAILED = "relay_auth_failed"
RELAY_SUBDOMAIN_DRIFT = "relay_subdomain_drift"
RELAY_NOT_CONFIGURED = "relay_not_configured"
RELAY_NOT_RUNNING = "relay_not_running"

RUN_HOSTS_NONE_DECLARED = "run_hosts_none_declared"
RUN_HOSTS_AMBIGUOUS_DEFAULT = "run_hosts_ambiguous_default"
RUN_HOSTS_OK = "run_hosts_ok"
RUN_HOST_OK = "run_host_ok"
RUN_HOST_UNKNOWN_ROLE = "run_host_unknown_role"
RUN_HOST_UNMAPPED = "run_host_unmapped"
RUN_HOST_UNREACHABLE = "run_host_unreachable"
RUN_HOST_NOT_BOOTSTRAPPED = "run_host_not_bootstrapped"
RUN_HOST_STALE_TOKEN = "run_host_stale_token"
RUN_HOST_ORPHAN_MAPPING = "run_host_orphan_mapping"

GH_AUTH_APP = "gh_auth_app"
GH_AUTH_BROKER = "gh_auth_broker"
GH_AUTH_ENV_TOKEN = "gh_auth_env_token"
GH_AUTH_RELAY_ATTACH = "gh_auth_relay_attach"
GH_AUTH_NONE = "gh_auth_none"

EGRESS_ROUTED = "egress_routed"
EGRESS_ABSENT = "egress_absent"
EGRESS_UNKNOWN = "egress_unknown"


@dataclass(frozen=True)
class Edge:
    """One connectivity edge (or node) and its health.

    `facts` holds REDACTED, source-annotated values only — urls, hostnames,
    booleans, and where an effective value came from. Never a token, key, or
    credential body (see `tests/core/test_topology_redaction.py`).
    """
    kind: str          # serve | relay | run_host | gh_auth | egress
    name: str          # "serve", "relay", "run_host:mac-studio", ...
    status: str        # one of STATUSES
    code: str          # one of the module's *_CODE constants
    detail: str        # human summary
    fix: str | None    # actionable next step; None when there is nothing to fix
    facts: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class Topology:
    version: int
    workspace: str
    probed_at: str     # ISO-8601, UTC
    edges: list[Edge]


def topology_payload(topology: Topology) -> dict[str, Any]:
    """The JSON body shared by `mship net status --json` and
    `GET /net/topology` — ONE serializer, so the CLI and the endpoint can never
    disagree about the contract."""
    return {
        "version": topology.version,
        "workspace": topology.workspace,
        "probed_at": topology.probed_at,
        "edges": [
            {
                "kind": e.kind,
                "name": e.name,
                "status": e.status,
                "code": e.code,
                "detail": e.detail,
                "fix": e.fix,
                "facts": dict(e.facts),
            }
            for e in topology.edges
        ],
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_topology_model.py -v > /tmp/t1.log 2>&1; echo "exit=$?"; tail -5 /tmp/t1.log`
Expected: `exit=0`, 4 passed.

> Always redirect pytest output to a file and echo `$?`. Piping pytest into `tail` returns *tail's* exit code and will hide a failing test.

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/topology.py tests/core/test_topology_model.py
git commit -m "feat(topology): status-code vocabulary, Edge/Topology model, payload serializer"
mship journal "topology model + payload landed; status codes defined in one place" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: `probe_health()` — one prober, now with a status code

**Files:**
- Modify: `src/mship/core/relay/health.py`
- Test: `tests/core/relay/test_health.py` (existing 8 tests are the regression net; add 3)

`verify_relay_reachable` already probes `/health` bounded and never raises, but returns `(ok, prose)`. Topology must distinguish 401 (stale token) from 503 (not bootstrapped) from a transport error, and parsing prose for that would be fragile. Extract the status code; keep exactly one prober.

**`verify_relay_reachable`'s signature and returned prose must not change** — `serve`, `pair`, and `wait_until_reachable` depend on them, including the `"auth failed"` marker that makes a 401 terminal.

- [ ] **Step 1: Write the failing test**

```python
# tests/core/relay/test_health.py  — append
from mship.core.relay.health import probe_health


class _Resp:
    def __init__(self, status_code):
        self.status_code = status_code


def test_probe_health_reports_status_code():
    p = probe_health("https://w-ab12.relay", "tok", get=lambda url, **kw: _Resp(503))
    assert p.ok is False
    assert p.status_code == 503
    assert p.error is None


def test_probe_health_ok_on_2xx():
    p = probe_health("https://w-ab12.relay", "tok", get=lambda url, **kw: _Resp(204))
    assert p.ok is True and p.status_code == 204


def test_probe_health_carries_transport_error_and_never_raises():
    def boom(url, **kw):
        raise RuntimeError("name resolution failed")

    p = probe_health("https://w-ab12.relay", "tok", get=boom)
    assert p.ok is False and p.status_code is None
    assert "name resolution failed" in p.error
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/relay/test_health.py -v > /tmp/t2.log 2>&1; echo "exit=$?"; tail -5 /tmp/t2.log`
Expected: non-zero — `ImportError: cannot import name 'probe_health'`

- [ ] **Step 3: Write minimal implementation**

Replace the top of `src/mship/core/relay/health.py` (keep everything from `_AUTH_FAILURE_MARKER` down unchanged):

```python
from __future__ import annotations

from dataclasses import dataclass
from typing import Callable


@dataclass(frozen=True)
class HealthProbe:
    """Outcome of one `/health` request. Exactly one of `status_code` (a
    response arrived) or `error` (transport/DNS/TLS failure) is set."""
    ok: bool
    status_code: int | None = None
    error: str | None = None


def probe_health(public_url: str, token: str, *, get: Callable | None = None,
                 timeout: float = 8.0) -> HealthProbe:
    """Probe `<public_url>/health` with the bearer token. Never raises.

    The single reachability prober for the codebase: `verify_relay_reachable`
    renders its prose from this, and `core.topology` maps the status code to a
    per-edge status + fix hint (a run-host 401 and a phone-pairing 401 need
    different advice, so the mapping belongs with the caller, not here).
    """
    if get is None:
        import httpx
        get = lambda url, **kw: httpx.get(url, **kw)
    url = public_url.rstrip("/") + "/health"
    try:
        r = get(url, headers={"Authorization": f"Bearer {token}"},
                timeout=timeout, follow_redirects=True)
    except Exception as e:  # transport/DNS/TLS error
        return HealthProbe(ok=False, error=str(e))
    code = r.status_code
    return HealthProbe(ok=200 <= code < 300, status_code=code)


def verify_relay_reachable(public_url: str, token: str, *, get: Callable | None = None,
                           timeout: float = 8.0) -> tuple[bool, str]:
    """Probe `<public_url>/health` with the bearer token through the relay.

    Returns (ok, detail). ok=True only on 2xx. 401/403 → a token-mismatch hint.
    Any transport error → ok=False with the exception text (the real reason).
    `get` is injectable (defaults to httpx.get) for testing.
    """
    p = probe_health(public_url, token, get=get, timeout=timeout)
    if p.error is not None:
        return False, f"could not reach relay URL: {p.error}"
    if p.ok:
        return True, "ok"
    if p.status_code in (401, 403):
        return False, (f"relay reachable but auth failed (HTTP {p.status_code}) — "
                       "the paired phone's token is stale; re-scan the QR")
    return False, f"relay returned HTTP {p.status_code}"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/relay/test_health.py -v > /tmp/t2.log 2>&1; echo "exit=$?"; tail -5 /tmp/t2.log`
Expected: `exit=0`, 11 passed (8 pre-existing + 3 new). The 8 pre-existing passing is the point: the delegation preserved the contract.

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/relay/health.py tests/core/relay/test_health.py
git commit -m "refactor(relay): extract probe_health so callers can branch on the status code"
mship journal "extracted probe_health from verify_relay_reachable; 8 existing tests still green" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: Read-only key paths + `classify_gh_auth()`

**Files:**
- Modify: `src/mship/core/relay/keys.py`
- Modify: `src/mship/core/gh_auth.py`
- Test: `tests/core/relay/test_keys.py` (append), `tests/core/test_gh_auth_classify.py` (create)

Two small prerequisites, both about not duplicating truth.

`ensure_subdomain_secret` and `ensure_relay_key` **generate on absence** — topology must never call them (read-only invariant), and must not hardcode their paths either. Extract the paths.

`classify_gh_auth` returns a bare model name (`"app" | "relay_attach" | "env_token" | "broker" | "none"`), not a topology code, so `gh_auth` never imports `topology` (no cycle). Topology maps name→code.

- [ ] **Step 1: Write the failing test**

```python
# tests/core/relay/test_keys.py  — append
from pathlib import Path

from mship.core.relay.keys import (
    ensure_subdomain_secret,
    relay_key_path,
    subdomain_secret_path,
)


def test_paths_are_readable_without_creating_anything(tmp_path: Path):
    assert subdomain_secret_path(tmp_path) == tmp_path / ".mothership" / "relay-subdomain-secret"
    assert relay_key_path(tmp_path) == tmp_path / ".mothership" / "relay_ed25519"
    # Read-only: asking for the paths must not create the dir or the files.
    assert not (tmp_path / ".mothership").exists()


def test_ensure_secret_writes_at_the_declared_path(tmp_path: Path):
    secret = ensure_subdomain_secret(home=tmp_path)
    assert subdomain_secret_path(tmp_path).read_bytes() == secret
```

```python
# tests/core/test_gh_auth_classify.py
from mship.core.gh_auth import classify_gh_auth


def test_relay_attach_wins():
    assert classify_gh_auth(
        app_configured=True, relay_url="https://r", run_token="rt",
        explicit_token="ghp_x", broker_url="https://b",
    ) == "relay_attach"


def test_app_beats_env_token_and_broker():
    assert classify_gh_auth(
        app_configured=True, relay_url=None, run_token=None,
        explicit_token="ghp_x", broker_url="https://b",
    ) == "app"


def test_env_token_beats_broker():
    assert classify_gh_auth(
        app_configured=False, relay_url=None, run_token=None,
        explicit_token="ghp_x", broker_url="https://b",
    ) == "env_token"


def test_broker_when_only_broker():
    assert classify_gh_auth(
        app_configured=False, relay_url=None, run_token=None,
        explicit_token=None, broker_url="https://b",
    ) == "broker"


def test_none_when_nothing_configured():
    assert classify_gh_auth(
        app_configured=False, relay_url=None, run_token=None,
        explicit_token=None, broker_url=None,
    ) == "none"


def test_half_configured_relay_is_not_relay_attach():
    # relay-attach needs BOTH url and run token (mirrors relay_flags_error).
    assert classify_gh_auth(
        app_configured=False, relay_url="https://r", run_token=None,
        explicit_token=None, broker_url=None,
    ) == "none"


def test_blank_strings_do_not_count_as_configured():
    assert classify_gh_auth(
        app_configured=False, relay_url=None, run_token=None,
        explicit_token="   ", broker_url="",
    ) == "none"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/relay/test_keys.py tests/core/test_gh_auth_classify.py -v > /tmp/t3.log 2>&1; echo "exit=$?"; tail -8 /tmp/t3.log`
Expected: non-zero — `ImportError: cannot import name 'relay_key_path'` / `'classify_gh_auth'`

- [ ] **Step 3: Write minimal implementation**

In `src/mship/core/relay/keys.py`, add the two path helpers and use them from the `ensure_*` functions (replace the two hardcoded `path = home / ".mothership" / ...` lines):

```python
def subdomain_secret_path(home: Path) -> Path:
    """Where the per-machine relay-subdomain HMAC secret lives. Read-only —
    creates nothing, so a reporter (see `mship.core.topology`) can check for it
    without generating one."""
    return home / ".mothership" / "relay-subdomain-secret"


def relay_key_path(home: Path) -> Path:
    """Where this machine's relay ssh key lives (public key at `<path>.pub`).
    Read-only — creates nothing."""
    return home / ".mothership" / "relay_ed25519"
```

Then in `ensure_subdomain_secret`: `path = subdomain_secret_path(home)`.
And in `ensure_relay_key`: `path = relay_key_path(home)`.

In `src/mship/core/gh_auth.py`, append:

```python
#: Auth models in precedence order, most specific first. Mirrors the token
#: precedence documented on `resolve_token` (explicit > GH_TOKEN > GITHUB_TOKEN
#: > broker), with relay-attach ahead of them all (a worker routed through the
#: relay egress never holds a token of its own) and an App-backed serve ahead of
#: the broker leg it implements.
#:
#: NOTE: `core.gh_preflight.run_preflight` branches on the same precedence for
#: its STRICT, network-verifying check. That duplication is pre-existing and
#: deliberately left alone here — this function is the *reporting* owner and must
#: never raise or touch the network.
GH_AUTH_MODELS = ("relay_attach", "app", "env_token", "broker", "none")


def classify_gh_auth(
    *,
    app_configured: bool,
    relay_url: str | None,
    run_token: str | None,
    explicit_token: str | None,
    broker_url: str | None,
) -> str:
    """Which GitHub auth model is in effect, by name (one of GH_AUTH_MODELS).

    Pure: no network, no environment reads (the caller supplies the values so
    the same function serves a report, a test, and a future dry-run). Blank
    strings count as absent.
    """
    def present(v: str | None) -> bool:
        return bool(v and v.strip())

    if present(relay_url) and present(run_token):
        return "relay_attach"
    if app_configured:
        return "app"
    if present(explicit_token):
        return "env_token"
    if present(broker_url):
        return "broker"
    return "none"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/relay/test_keys.py tests/core/test_gh_auth_classify.py -v > /tmp/t3.log 2>&1; echo "exit=$?"; tail -5 /tmp/t3.log`
Expected: `exit=0`, all passed (including the pre-existing `test_keys.py` tests).

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/relay/keys.py src/mship/core/gh_auth.py tests/core/relay/test_keys.py tests/core/test_gh_auth_classify.py
git commit -m "feat(auth): read-only relay key paths + pure classify_gh_auth precedence"
mship journal "added read-only key-path helpers and classify_gh_auth (reporting owner; preflight left untouched)" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: `probe_topology()` — serve + relay edges

**Files:**
- Modify: `src/mship/core/topology.py`
- Test: `tests/core/test_topology_probe.py`

The relay edge is where the useful local diagnosis lives: recomputing this machine's expected subdomain and comparing it against the running record distinguishes **a stale pairing** (the phone holds an old subdomain) from **a tunnel fault** (right subdomain, unreachable).

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_topology_probe.py
import json
from dataclasses import dataclass
from pathlib import Path

from mship.core.relay.health import HealthProbe
from mship.core.relay.runtime import RelayRuntimeRecord, write_runtime_record
from mship.core.topology import (
    RELAY_AUTH_FAILED,
    RELAY_NOT_CONFIGURED,
    RELAY_NOT_RUNNING,
    RELAY_OK,
    RELAY_UNREACHABLE,
    SERVE_RELAY_ABSENT,
    SERVE_RELAY_RUNNING,
    probe_topology,
)


@dataclass
class FakeConfig:
    workspace: str = "ws"
    run_hosts: tuple = ()
    repos: dict = None
    relay: object = None

    def __post_init__(self):
        if self.repos is None:
            self.repos = {}


def _probe(**by_url):
    """Return a probe fn serving canned HealthProbes keyed by url."""
    def fn(url, token, *, timeout=None):
        return by_url.get(url, HealthProbe(ok=False, error="no route"))
    return fn


def _edges(t, kind):
    return [e for e in t.edges if e.kind == kind]


def test_relay_absent_when_no_relay_configured(tmp_path: Path):
    t = probe_topology(
        config=FakeConfig(), state_dir=tmp_path / ".mothership",
        workspace_root=tmp_path, home=tmp_path, env={},
        probe=_probe(), now=lambda: "2026-07-25T16:00:00+00:00",
    )
    relay = _edges(t, "relay")[0]
    assert relay.status == "absent" and relay.code == RELAY_NOT_CONFIGURED
    assert relay.fix is not None          # tells you how to configure one
    serve = _edges(t, "serve")[0]
    assert serve.code == SERVE_RELAY_ABSENT


def test_relay_reachable_reports_ok_and_no_fix(tmp_path: Path):
    write_runtime_record(tmp_path, RelayRuntimeRecord(
        host="relay.example.com", pid=1, subdomain="abc-123456",
        url="https://abc-123456.relay.example.com", workspace="ws",
    ))
    t = probe_topology(
        config=FakeConfig(relay=object()), state_dir=tmp_path / ".mothership",
        workspace_root=tmp_path, home=tmp_path, env={},
        probe=_probe(**{"https://abc-123456.relay.example.com": HealthProbe(ok=True, status_code=200)}),
        now=lambda: "t", pid_alive=lambda pid: True,
    )
    relay = _edges(t, "relay")[0]
    assert relay.status == "ok" and relay.code == RELAY_OK and relay.fix is None
    assert _edges(t, "serve")[0].code == SERVE_RELAY_RUNNING


def test_relay_unreachable_carries_fix(tmp_path: Path):
    write_runtime_record(tmp_path, RelayRuntimeRecord(
        host="relay.example.com", pid=1, subdomain="abc-123456",
        url="https://abc-123456.relay.example.com",
    ))
    t = probe_topology(
        config=FakeConfig(relay=object()), state_dir=tmp_path / ".mothership",
        workspace_root=tmp_path, home=tmp_path, env={},
        probe=_probe(),  # nothing routes → transport error
        now=lambda: "t", pid_alive=lambda pid: True,
    )
    relay = _edges(t, "relay")[0]
    assert relay.status == "fail" and relay.code == RELAY_UNREACHABLE
    assert "serve --relay" in relay.fix


def test_relay_401_is_auth_failed_not_unreachable(tmp_path: Path):
    write_runtime_record(tmp_path, RelayRuntimeRecord(
        host="relay.example.com", pid=1, subdomain="s", url="https://s.relay",
    ))
    t = probe_topology(
        config=FakeConfig(relay=object()), state_dir=tmp_path / ".mothership",
        workspace_root=tmp_path, home=tmp_path, env={},
        probe=_probe(**{"https://s.relay": HealthProbe(ok=False, status_code=401)}),
        now=lambda: "t", pid_alive=lambda pid: True,
    )
    assert _edges(t, "relay")[0].code == RELAY_AUTH_FAILED


def test_dead_pid_reports_not_running_and_skips_the_probe(tmp_path: Path):
    write_runtime_record(tmp_path, RelayRuntimeRecord(
        host="relay.example.com", pid=999999, subdomain="s", url="https://s.relay",
    ))
    calls = []

    def counting_probe(url, token, *, timeout=None):
        calls.append(url)
        return HealthProbe(ok=True, status_code=200)

    t = probe_topology(
        config=FakeConfig(relay=object()), state_dir=tmp_path / ".mothership",
        workspace_root=tmp_path, home=tmp_path, env={},
        probe=counting_probe, now=lambda: "t", pid_alive=lambda pid: False,
    )
    assert _edges(t, "relay")[0].code == RELAY_NOT_RUNNING
    assert calls == []          # no point probing a tunnel whose serve is gone


def test_skip_network_never_probes(tmp_path: Path):
    write_runtime_record(tmp_path, RelayRuntimeRecord(
        host="relay.example.com", pid=1, subdomain="s", url="https://s.relay",
    ))
    calls = []

    def counting_probe(url, token, *, timeout=None):
        calls.append(url)
        return HealthProbe(ok=True, status_code=200)

    t = probe_topology(
        config=FakeConfig(relay=object()), state_dir=tmp_path / ".mothership",
        workspace_root=tmp_path, home=tmp_path, env={},
        probe=counting_probe, now=lambda: "t", pid_alive=lambda pid: True,
        skip_network=True,
    )
    assert calls == []
    assert _edges(t, "relay")[0].status in ("warn", "absent")


def test_probed_at_and_version_present(tmp_path: Path):
    t = probe_topology(
        config=FakeConfig(), state_dir=tmp_path / ".mothership",
        workspace_root=tmp_path, home=tmp_path, env={},
        probe=_probe(), now=lambda: "2026-07-25T16:00:00+00:00",
    )
    assert t.probed_at == "2026-07-25T16:00:00+00:00"
    assert t.version == 1 and t.workspace == "ws"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_topology_probe.py -v > /tmp/t4.log 2>&1; echo "exit=$?"; tail -8 /tmp/t4.log`
Expected: non-zero — `ImportError: cannot import name 'probe_topology'`

- [ ] **Step 3: Write minimal implementation**

Append to `src/mship/core/topology.py`:

```python
def _utc_now_iso() -> str:
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).isoformat()


def _default_probe(url: str, token: str, *, timeout: float = PROBE_TIMEOUT_SECONDS):
    from mship.core.relay.health import probe_health
    return probe_health(url, token, timeout=timeout)


def _serve_and_relay_edges(
    *, config, workspace_root, home, probe, pid_alive, skip_network, timeout,
) -> list[Edge]:
    """The `serve --relay` process on this machine and the relay edge it owns.

    Both come from the same runtime record, so they are built together: the
    relay edge is only meaningful when a live relay-serve wrote that record.
    """
    from mship.core.relay.runtime import read_runtime_record

    record = read_runtime_record(workspace_root)
    relay_configured = getattr(config, "relay", None) is not None

    if record is None:
        serve = Edge(
            kind="serve", name="serve", status="absent", code=SERVE_RELAY_ABSENT,
            detail="no relay-serve record on this machine",
            fix=("start one with `mship serve --relay` (a local-only "
                 "`mship serve` writes no record and needs no relay)"),
            facts={"relay_configured": relay_configured},
        )
        relay = Edge(
            kind="relay", name="relay", status="absent", code=RELAY_NOT_CONFIGURED,
            detail=("relay configured but not running" if relay_configured
                    else "no `relay:` block in mothership.yaml"),
            fix=("run `mship serve --relay`" if relay_configured else
                 "add a `relay:` block (host, ssh_port, user) to mothership.yaml, "
                 "then `mship relay enroll` and `mship serve --relay`"),
            facts={"relay_configured": relay_configured},
        )
        return [serve, relay]

    alive = pid_alive(record.pid)
    serve = Edge(
        kind="serve", name="serve",
        status="ok" if alive else "fail",
        code=SERVE_RELAY_RUNNING if alive else SERVE_RELAY_STALE,
        detail=(f"relay-serve pid {record.pid} running" if alive else
                f"stale record: pid {record.pid} is gone"),
        fix=None if alive else (
            "the recorded relay-serve died; restart `mship serve --relay` "
            "(the stale record is cleared on next start)"
        ),
        facts={
            "mode": "relay", "pid": record.pid, "host": record.host,
            "subdomain": record.subdomain, "url": record.url,
            "workspace": record.workspace, "ssh_port": record.ssh_port,
        },
    )

    facts = {"host": record.host, "subdomain": record.subdomain, "url": record.url}
    drift = _subdomain_drift(record, home=home)
    if drift is not None:
        facts["expected_subdomain"] = drift

    if not alive:
        relay = Edge(
            kind="relay", name="relay", status="fail", code=RELAY_NOT_RUNNING,
            detail="no live relay-serve owns this tunnel",
            fix="restart `mship serve --relay` on this machine",
            facts=facts,
        )
        return [serve, relay]

    if drift is not None:
        relay = Edge(
            kind="relay", name="relay", status="warn", code=RELAY_SUBDOMAIN_DRIFT,
            detail=(f"running subdomain {record.subdomain!r} is not the one this "
                    f"machine now derives ({drift!r})"),
            fix=("anything paired against the old subdomain is stale — re-pair "
                 "(`mship pair`, re-scan the QR) or restart `mship serve --relay` "
                 "to publish the derived subdomain"),
            facts=facts,
        )
        return [serve, relay]

    if skip_network or not record.url:
        relay = Edge(
            kind="relay", name="relay", status="warn", code=RELAY_UNREACHABLE,
            detail=("network probes skipped" if skip_network else
                    "record carries no public url"),
            fix="re-run without --no-network to probe the relay URL",
            facts=facts,
        )
        return [serve, relay]

    token = _serve_token(workspace_root)
    result = probe(record.url, token or "", timeout=timeout)
    if result.ok:
        relay = Edge(
            kind="relay", name="relay", status="ok", code=RELAY_OK,
            detail=f"{record.url} reachable", fix=None, facts=facts,
        )
    elif result.status_code in (401, 403):
        relay = Edge(
            kind="relay", name="relay", status="fail", code=RELAY_AUTH_FAILED,
            detail=f"{record.url} reachable but rejected this host's bearer "
                   f"(HTTP {result.status_code})",
            fix=("the tunnel is up but the token does not match — restart "
                 "`mship serve --relay` and re-pair the phone"),
            facts=facts,
        )
    else:
        why = result.error or f"HTTP {result.status_code}"
        relay = Edge(
            kind="relay", name="relay", status="fail", code=RELAY_UNREACHABLE,
            detail=f"{record.url} unreachable ({why})",
            fix=("check `mship serve --relay` is running here and the relay host "
                 "is up; an orphaned ssh tunnel duplicating this subdomain also "
                 "presents as unreachable — kill it and restart serve"),
            facts=facts,
        )
    return [serve, relay]


def _subdomain_drift(record, *, home) -> str | None:
    """The subdomain this machine derives NOW, when it differs from the running
    record's — i.e. anything paired against the record is stale. None when they
    agree, or when the inputs to derive it are missing/unreadable.

    Strictly read-only: uses the key/secret PATHS, never the `ensure_*`
    generators (which would create them as a side effect of reporting).
    """
    from mship.core.relay.keys import relay_key_path, subdomain_secret_path
    from mship.core.relay.tunnel import device_id, device_subdomain

    if not record.subdomain or not record.workspace:
        return None
    try:
        secret = subdomain_secret_path(home).read_bytes()
        pub = (relay_key_path(home).with_suffix(".pub")).read_text()
    except OSError:
        return None
    try:
        expected = device_subdomain(record.workspace, device_id(pub), secret)
    except Exception:
        return None
    return None if expected == record.subdomain else expected


def _serve_token(workspace_root) -> str | None:
    """This host's serve bearer, read WITHOUT creating one (`ensure_serve_token`
    would mint a token as a side effect of reporting)."""
    from pathlib import Path
    try:
        return Path(workspace_root).joinpath(".mothership", "serve-token").read_text().strip()
    except OSError:
        return None


def probe_topology(
    *,
    config,
    state_dir,
    workspace_root,
    home=None,
    env=None,
    probe=None,
    pid_alive=None,
    shell=None,
    now=None,
    skip_network: bool = False,
    timeout: float = PROBE_TIMEOUT_SECONDS,
) -> Topology:
    """This machine's connectivity topology. Read-only; never raises.

    Every collaborator is injectable so the suite needs no live network, no real
    home directory, and no running serve:
      `probe`     -> `relay.health.probe_health`
      `pid_alive` -> `relay.runtime._pid_alive`
      `shell`     -> `util.shell.ShellRunner`
      `now`       -> UTC ISO-8601 clock
      `env`       -> `os.environ`

    `skip_network=True` reports config-level state only (used by `mship doctor
    --no-network` so a previously-fast command stays fast).
    """
    import os
    from pathlib import Path

    from mship.core.relay.runtime import _pid_alive

    env = os.environ if env is None else env
    home = Path.home() if home is None else Path(home)
    probe = _default_probe if probe is None else probe
    pid_alive = _pid_alive if pid_alive is None else pid_alive
    now = _utc_now_iso if now is None else now

    edges: list[Edge] = []
    edges.extend(_serve_and_relay_edges(
        config=config, workspace_root=Path(workspace_root), home=home,
        probe=probe, pid_alive=pid_alive, skip_network=skip_network,
        timeout=timeout,
    ))
    return Topology(
        version=SCHEMA_VERSION,
        workspace=getattr(config, "workspace", "") or "",
        probed_at=now(),
        edges=edges,
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_topology_probe.py -v > /tmp/t4.log 2>&1; echo "exit=$?"; tail -8 /tmp/t4.log`
Expected: `exit=0`, 7 passed.

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/topology.py tests/core/test_topology_probe.py
git commit -m "feat(topology): serve + relay edges with subdomain-drift diagnosis"
mship journal "serve/relay edges probing; drift check distinguishes stale pairing from tunnel fault" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: Run-host edges

**Files:**
- Modify: `src/mship/core/topology.py`
- Test: `tests/core/test_topology_probe.py` (append)

Every declared role becomes an edge reporting declared → mapped → reachable, plus **the source of each effective value** (file vs `MSHIP_RUN_HOST_<ROLE>_*` env override), because on-disk config is not the whole truth. Two aggregate conditions get their own edge: nothing declared, and an ambiguous bare `--remote` (2+ roles, no repo default).

The fix hints here are the ones already written in `run_host.store.RunHostError` and `remote_client._http_status_message` — same wording, now attached to a code.

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_topology_probe.py  — append
from mship.core.topology import (
    RUN_HOSTS_AMBIGUOUS_DEFAULT,
    RUN_HOSTS_NONE_DECLARED,
    RUN_HOST_NOT_BOOTSTRAPPED,
    RUN_HOST_OK,
    RUN_HOST_ORPHAN_MAPPING,
    RUN_HOST_STALE_TOKEN,
    RUN_HOST_UNKNOWN_ROLE,
    RUN_HOST_UNMAPPED,
    RUN_HOST_UNREACHABLE,
)


@dataclass
class FakeRepo:
    run_host: str | None = None


def _map_role(tmp_path: Path, role: str, url: str, token: str = "tok"):
    from mship.core.run_host.config import RunHostConnection
    from mship.core.run_host.store import RunHostStore
    RunHostStore(tmp_path / ".mothership").set(role, RunHostConnection(url=url, token=token))


def _run(tmp_path, config, *, probe=None, env=None, **kw):
    return probe_topology(
        config=config, state_dir=tmp_path / ".mothership", workspace_root=tmp_path,
        home=tmp_path, env=env or {}, probe=probe or _probe(), now=lambda: "t",
        pid_alive=lambda pid: True, **kw,
    )


def test_no_roles_declared_is_an_absent_aggregate_edge(tmp_path: Path):
    t = _run(tmp_path, FakeConfig())
    agg = [e for e in t.edges if e.name == "run_hosts"][0]
    assert agg.status == "absent" and agg.code == RUN_HOSTS_NONE_DECLARED


def test_declared_but_unmapped_role_names_run_host_add(tmp_path: Path):
    t = _run(tmp_path, FakeConfig(run_hosts=("mac",)))
    edge = [e for e in t.edges if e.name == "run_host:mac"][0]
    assert edge.status == "fail" and edge.code == RUN_HOST_UNMAPPED
    assert "mship run-host add mac" in edge.fix


def test_mapped_and_reachable_role_is_ok_with_source(tmp_path: Path):
    _map_role(tmp_path, "mac", "https://mac.relay")
    t = _run(tmp_path, FakeConfig(run_hosts=("mac",)),
             probe=_probe(**{"https://mac.relay": HealthProbe(ok=True, status_code=200)}))
    edge = [e for e in t.edges if e.name == "run_host:mac"][0]
    assert edge.status == "ok" and edge.code == RUN_HOST_OK
    assert edge.facts["url"] == "https://mac.relay"
    assert edge.facts["url_source"] == "file"
    assert edge.facts["token_configured"] is True


def test_env_override_is_reported_as_the_effective_source(tmp_path: Path):
    _map_role(tmp_path, "mac", "https://from-file")
    t = _run(
        tmp_path, FakeConfig(run_hosts=("mac",)),
        env={"MSHIP_RUN_HOST_MAC_URL": "https://from-env"},
        probe=_probe(**{"https://from-env": HealthProbe(ok=True, status_code=200)}),
    )
    edge = [e for e in t.edges if e.name == "run_host:mac"][0]
    assert edge.facts["url"] == "https://from-env"
    assert edge.facts["url_source"] == "env:MSHIP_RUN_HOST_MAC_URL"


def test_503_is_not_bootstrapped(tmp_path: Path):
    _map_role(tmp_path, "mac", "https://mac.relay")
    t = _run(tmp_path, FakeConfig(run_hosts=("mac",)),
             probe=_probe(**{"https://mac.relay": HealthProbe(ok=False, status_code=503)}))
    edge = [e for e in t.edges if e.name == "run_host:mac"][0]
    assert edge.code == RUN_HOST_NOT_BOOTSTRAPPED
    assert "bootstrap" in edge.fix


def test_401_is_stale_token(tmp_path: Path):
    _map_role(tmp_path, "mac", "https://mac.relay")
    t = _run(tmp_path, FakeConfig(run_hosts=("mac",)),
             probe=_probe(**{"https://mac.relay": HealthProbe(ok=False, status_code=401)}))
    edge = [e for e in t.edges if e.name == "run_host:mac"][0]
    assert edge.code == RUN_HOST_STALE_TOKEN
    assert "mship run-host add mac" in edge.fix


def test_transport_error_is_unreachable(tmp_path: Path):
    _map_role(tmp_path, "mac", "https://mac.relay")
    t = _run(tmp_path, FakeConfig(run_hosts=("mac",)), probe=_probe())
    edge = [e for e in t.edges if e.name == "run_host:mac"][0]
    assert edge.code == RUN_HOST_UNREACHABLE


def test_repo_declaring_an_undeclared_role_is_unknown_role(tmp_path: Path):
    cfg = FakeConfig(run_hosts=("mac",), repos={"api": FakeRepo(run_host="typo")})
    t = _run(tmp_path, cfg)
    edge = [e for e in t.edges if e.name == "run_host:typo"][0]
    assert edge.status == "fail" and edge.code == RUN_HOST_UNKNOWN_ROLE
    assert "api" in edge.detail          # names the repo that points at it


def test_ambiguous_default_when_two_roles_and_no_repo_default(tmp_path: Path):
    _map_role(tmp_path, "mac", "https://mac")
    _map_role(tmp_path, "linux", "https://linux")
    t = _run(tmp_path, FakeConfig(run_hosts=("mac", "linux")))
    agg = [e for e in t.edges if e.name == "run_hosts"][0]
    assert agg.status == "warn" and agg.code == RUN_HOSTS_AMBIGUOUS_DEFAULT
    assert "--remote=<role>" in agg.fix


def test_mapping_for_an_undeclared_role_is_an_orphan_warning(tmp_path: Path):
    _map_role(tmp_path, "gone", "https://gone")
    t = _run(tmp_path, FakeConfig(run_hosts=("mac",)))
    edge = [e for e in t.edges if e.name == "run_host:gone"][0]
    assert edge.status == "warn" and edge.code == RUN_HOST_ORPHAN_MAPPING


def test_unmapped_role_is_never_probed(tmp_path: Path):
    calls = []

    def counting(url, token, *, timeout=None):
        calls.append(url)
        return HealthProbe(ok=True, status_code=200)

    _run(tmp_path, FakeConfig(run_hosts=("mac",)), probe=counting)
    assert calls == []
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_topology_probe.py -v > /tmp/t5.log 2>&1; echo "exit=$?"; tail -8 /tmp/t5.log`
Expected: non-zero — `ImportError: cannot import name 'RUN_HOST_OK'` (and the new run-host assertions fail).

- [ ] **Step 3: Write minimal implementation**

Add to `src/mship/core/topology.py`, and call it from `probe_topology` (see Step 3b):

```python
def _run_host_edges(
    *, config, state_dir, env, probe, skip_network, timeout,
) -> list[Edge]:
    """One edge per role — declared, mapped, reachable — plus aggregate edges
    for "nothing declared" and "a bare --remote would be ambiguous".

    Fix hints intentionally mirror `run_host.store.RunHostError` and
    `remote_client._http_status_message`, so the CLI error an operator hits and
    the topology hint they read say the same thing.
    """
    from mship.core.run_host.store import RunHostStore, _env_key

    declared = list(getattr(config, "run_hosts", ()) or ())
    repos = getattr(config, "repos", {}) or {}
    store = RunHostStore(state_dir)
    mapped = dict(store._read_all())          # role -> {url, token}
    edges: list[Edge] = []

    # --- aggregate: nothing declared / ambiguous bare --remote -------------
    repo_defaults = {
        name: getattr(r, "run_host", None)
        for name, r in repos.items() if getattr(r, "run_host", None)
    }
    if not declared:
        edges.append(Edge(
            kind="run_host", name="run_hosts", status="absent",
            code=RUN_HOSTS_NONE_DECLARED,
            detail="no run_hosts declared in mothership.yaml",
            fix=("add a `run_hosts:` list of role names to mothership.yaml "
                 "before using --remote"),
            facts={"declared": []},
        ))
    elif len(declared) > 1 and not repo_defaults:
        edges.append(Edge(
            kind="run_host", name="run_hosts", status="warn",
            code=RUN_HOSTS_AMBIGUOUS_DEFAULT,
            detail=(f"{len(declared)} roles declared ({', '.join(declared)}) and no "
                    f"repo declares a default, so a bare `--remote` is ambiguous"),
            fix=("pass --remote=<role> explicitly, or declare `run_host: <role>` "
                 "on the repo"),
            facts={"declared": declared},
        ))
    else:
        edges.append(Edge(
            kind="run_host", name="run_hosts", status="ok", code=RUN_HOSTS_OK,
            detail=f"{len(declared)} role(s) declared", fix=None,
            facts={"declared": declared, "repo_defaults": repo_defaults},
        ))

    # --- unknown roles: a repo points at a role that isn't declared --------
    for repo_name, role in sorted(repo_defaults.items()):
        if role in declared:
            continue
        edges.append(Edge(
            kind="run_host", name=f"run_host:{role}", status="fail",
            code=RUN_HOST_UNKNOWN_ROLE,
            detail=(f"repo {repo_name!r} declares run_host {role!r}, which is not "
                    f"in this workspace's run_hosts list"),
            fix=(f"add {role!r} to `run_hosts:` in mothership.yaml, or fix the "
                 f"typo on repo {repo_name!r}"),
            facts={"declared_by_repo": repo_name, "known_roles": declared},
        ))

    # --- per declared role -------------------------------------------------
    for role in declared:
        entry = mapped.get(role, {})
        url_env, token_env = _env_key(role, "URL"), _env_key(role, "TOKEN")
        url = env.get(url_env) or entry.get("url")
        token = env.get(token_env) or entry.get("token")
        facts = {
            "role": role,
            "url": url,
            "url_source": (f"env:{url_env}" if env.get(url_env)
                           else "file" if entry.get("url") else None),
            "token_configured": bool(token),
            "token_source": (f"env:{token_env}" if env.get(token_env)
                             else "file" if entry.get("token") else None),
        }

        if not url or not token:
            edges.append(Edge(
                kind="run_host", name=f"run_host:{role}", status="fail",
                code=RUN_HOST_UNMAPPED,
                detail=(f"role {role!r} is declared but has no connection mapped "
                        f"on this machine"),
                fix=(f"run `mship run-host add {role} --pair-link '...'` (get the "
                     f"link by running `mship pair` on that machine)"),
                facts=facts,
            ))
            continue

        if skip_network:
            edges.append(Edge(
                kind="run_host", name=f"run_host:{role}", status="warn",
                code=RUN_HOST_UNREACHABLE, detail="network probes skipped",
                fix="re-run without --no-network to probe this run host",
                facts=facts,
            ))
            continue

        result = probe(url, token, timeout=timeout)
        if result.ok:
            edges.append(Edge(
                kind="run_host", name=f"run_host:{role}", status="ok",
                code=RUN_HOST_OK, detail=f"{url} reachable", fix=None, facts=facts,
            ))
        elif result.status_code == 503:
            edges.append(Edge(
                kind="run_host", name=f"run_host:{role}", status="fail",
                code=RUN_HOST_NOT_BOOTSTRAPPED,
                detail=f"{url} is reachable but has no workspace wired in (503)",
                fix=("bootstrap that machine as an mship workspace and restart "
                     "`mship serve --relay` there"),
                facts=facts,
            ))
        elif result.status_code in (401, 403):
            edges.append(Edge(
                kind="run_host", name=f"run_host:{role}", status="fail",
                code=RUN_HOST_STALE_TOKEN,
                detail=f"{url} rejected the mapped bearer token "
                       f"(HTTP {result.status_code})",
                fix=(f"the mapping is stale — re-run `mship run-host add {role}` "
                     f"with a fresh pair link/token"),
                facts=facts,
            ))
        else:
            why = result.error or f"HTTP {result.status_code}"
            edges.append(Edge(
                kind="run_host", name=f"run_host:{role}", status="fail",
                code=RUN_HOST_UNREACHABLE,
                detail=f"{url} unreachable ({why})",
                fix=(f"confirm that machine is up with `mship serve --relay` "
                     f"running; re-pair if its relay subdomain changed"),
                facts=facts,
            ))

    # --- orphan mappings: mapped here, not declared anywhere ---------------
    for role in sorted(set(mapped) - set(declared)):
        edges.append(Edge(
            kind="run_host", name=f"run_host:{role}", status="warn",
            code=RUN_HOST_ORPHAN_MAPPING,
            detail=(f"role {role!r} is mapped on this machine but not declared in "
                    f"mothership.yaml, so nothing can select it"),
            fix=(f"add {role!r} to `run_hosts:` in mothership.yaml, or drop the "
                 f"mapping with `mship run-host remove {role}`"),
            facts={"role": role},
        ))

    return edges
```

**Step 3b:** in `probe_topology`, after the serve/relay edges:

```python
    edges.extend(_run_host_edges(
        config=config, state_dir=Path(state_dir), env=env, probe=probe,
        skip_network=skip_network, timeout=timeout,
    ))
```

> `store._read_all()` is a private read. Justified: `redacted_list()` drops the token entirely, and this edge must report `token_configured` (a boolean) plus the env-vs-file *source* — neither is derivable from the public method. If a reviewer prefers, promote it to a public `raw_entries()` on `RunHostStore` in a follow-up; it is not worth widening the store's surface for one caller here.

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_topology_probe.py -v > /tmp/t5.log 2>&1; echo "exit=$?"; tail -8 /tmp/t5.log`
Expected: `exit=0`, 18 passed.

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/topology.py tests/core/test_topology_probe.py
git commit -m "feat(topology): per-role run-host edges with effective-value sources and fix hints"
mship journal "run-host edges: declared/mapped/reachable + env-override source + unknown/ambiguous/orphan" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: GitHub auth + egress edges, and the never-raises guarantee

**Files:**
- Modify: `src/mship/core/topology.py`
- Test: `tests/core/test_topology_probe.py` (append)

The auth edge reports which model is in effect via `classify_gh_auth` (Task 3) — never the credential. The egress edge answers "is this machine's git routed through a relay egress?" by reading git's global config for the `insteadOf` rewrites `relay_git_config_commands` installs, recognizing them via `relay.contract.PREFIX_HOST` so the two can't drift.

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_topology_probe.py  — append
from mship.core.topology import (
    EGRESS_ABSENT,
    EGRESS_ROUTED,
    EGRESS_UNKNOWN,
    GH_AUTH_APP,
    GH_AUTH_BROKER,
    GH_AUTH_NONE,
    GH_AUTH_RELAY_ATTACH,
)


class FakeShell:
    def __init__(self, stdout="", returncode=0, raises=None):
        self._stdout, self._rc, self._raises = stdout, returncode, raises
        self.calls = []

    def run(self, cmd, cwd=None, **kw):
        self.calls.append(cmd)
        if self._raises:
            raise self._raises

        class R:
            stdout, stderr, returncode = self._stdout, "", self._rc
        return R()


def test_gh_auth_none_when_nothing_configured(tmp_path: Path):
    t = _run(tmp_path, FakeConfig(), shell=FakeShell())
    edge = [e for e in t.edges if e.kind == "gh_auth"][0]
    assert edge.code == GH_AUTH_NONE and edge.status == "warn"
    assert "MSHIP_GH_BROKER_URL" in edge.fix


def test_gh_auth_reports_app_without_leaking_the_key(tmp_path: Path):
    key = tmp_path / "app.pem"
    key.write_text("-----BEGIN PRIVATE KEY-----\nsupersecret\n")
    t = _run(
        tmp_path, FakeConfig(), shell=FakeShell(),
        env={"MSHIP_GH_APP_ID": "12345", "MSHIP_GH_APP_KEY": str(key)},
    )
    edge = [e for e in t.edges if e.kind == "gh_auth"][0]
    assert edge.code == GH_AUTH_APP and edge.status == "ok"
    assert edge.facts["app_key_readable"] is True
    assert "supersecret" not in json.dumps(edge.facts)
    assert "12345" not in json.dumps(edge.facts)   # app id is a credential-ish id


def test_gh_auth_broker_and_relay_attach(tmp_path: Path):
    t = _run(tmp_path, FakeConfig(), shell=FakeShell(),
             env={"MSHIP_GH_BROKER_URL": "https://b", "MSHIP_SERVE_TOKEN": "s"})
    assert [e for e in t.edges if e.kind == "gh_auth"][0].code == GH_AUTH_BROKER

    t2 = _run(tmp_path, FakeConfig(), shell=FakeShell(),
              env={"MSHIP_RELAY_URL": "https://r", "MSHIP_RUN_TOKEN": "rt"})
    assert [e for e in t2.edges if e.kind == "gh_auth"][0].code == GH_AUTH_RELAY_ATTACH


def test_egress_routed_when_git_config_has_the_rewrite(tmp_path: Path):
    shell = FakeShell(stdout=(
        "url.https://egress.example.com/gh/.insteadof https://github.com/\n"
        "url.https://egress.example.com/api/.insteadof https://api.github.com/\n"
    ))
    t = _run(tmp_path, FakeConfig(), shell=shell)
    edge = [e for e in t.edges if e.kind == "egress"][0]
    assert edge.code == EGRESS_ROUTED and edge.status == "ok"
    assert edge.facts["relay_base"] == "https://egress.example.com"


def test_egress_absent_when_git_config_is_clean(tmp_path: Path):
    t = _run(tmp_path, FakeConfig(), shell=FakeShell(stdout="", returncode=1))
    edge = [e for e in t.edges if e.kind == "egress"][0]
    assert edge.code == EGRESS_ABSENT and edge.status == "absent"


def test_egress_unknown_when_git_is_unavailable(tmp_path: Path):
    t = _run(tmp_path, FakeConfig(), shell=FakeShell(raises=OSError("no git")))
    edge = [e for e in t.edges if e.kind == "egress"][0]
    assert edge.code == EGRESS_UNKNOWN and edge.status == "warn"


def test_fully_broken_environment_still_returns_every_edge(tmp_path: Path):
    """AC4: serve down, relay unreachable, no run hosts mapped, no git,
    no auth — probe_topology must return a report, not raise."""
    cfg = FakeConfig(run_hosts=("mac", "linux"), relay=object())
    t = probe_topology(
        config=cfg, state_dir=tmp_path / "nope", workspace_root=tmp_path / "nope",
        home=tmp_path / "nope", env={}, probe=_probe(),
        shell=FakeShell(raises=OSError("boom")), now=lambda: "t",
        pid_alive=lambda pid: False,
    )
    kinds = {e.kind for e in t.edges}
    assert kinds == {"serve", "relay", "run_host", "gh_auth", "egress"}
    # every unhealthy edge offers a next step
    assert all(e.fix for e in t.edges if e.status in ("fail", "warn"))


def test_every_probe_call_is_timeout_bounded(tmp_path: Path):
    seen = []

    def recording(url, token, *, timeout=None):
        seen.append(timeout)
        return HealthProbe(ok=True, status_code=200)

    _map_role(tmp_path, "mac", "https://mac")
    write_runtime_record(tmp_path, RelayRuntimeRecord(
        host="h", pid=1, subdomain="s", url="https://s.relay", workspace="ws",
    ))
    _run(tmp_path, FakeConfig(run_hosts=("mac",), relay=object()),
         probe=recording, shell=FakeShell())
    assert seen and all(isinstance(t, float) and t > 0 for t in seen)
```

Update the shared `_run` helper (added in Task 5) to forward `shell`:

```python
def _run(tmp_path, config, *, probe=None, env=None, shell=None, **kw):
    return probe_topology(
        config=config, state_dir=tmp_path / ".mothership", workspace_root=tmp_path,
        home=tmp_path, env=env or {}, probe=probe or _probe(), now=lambda: "t",
        pid_alive=lambda pid: True, shell=shell or FakeShell(), **kw,
    )
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_topology_probe.py -v > /tmp/t6.log 2>&1; echo "exit=$?"; tail -8 /tmp/t6.log`
Expected: non-zero — `ImportError: cannot import name 'GH_AUTH_APP'`

- [ ] **Step 3: Write minimal implementation**

```python
_GH_AUTH_CODES = {
    "relay_attach": GH_AUTH_RELAY_ATTACH,
    "app": GH_AUTH_APP,
    "env_token": GH_AUTH_ENV_TOKEN,
    "broker": GH_AUTH_BROKER,
    "none": GH_AUTH_NONE,
}


def _gh_auth_edge(*, env) -> Edge:
    """Which GitHub auth model is in effect on this machine.

    Reports the MODEL and whether each credential is present/readable — never
    the credential, and never the App id (an identifier tied to a specific
    private key is not something a console needs to display).
    """
    from pathlib import Path

    from mship.core.gh_auth import classify_gh_auth

    app_id = env.get("MSHIP_GH_APP_ID") or None
    app_key_path = env.get("MSHIP_GH_APP_KEY") or None
    app_key_readable = bool(app_key_path) and Path(app_key_path).is_file()
    broker_url = env.get("MSHIP_GH_BROKER_URL") or None
    relay_url = env.get("MSHIP_RELAY_URL") or None
    run_token = env.get("MSHIP_RUN_TOKEN") or None
    explicit = env.get("GH_TOKEN") or env.get("GITHUB_TOKEN") or None

    model = classify_gh_auth(
        app_configured=bool(app_id and app_key_readable),
        relay_url=relay_url, run_token=run_token,
        explicit_token=explicit, broker_url=broker_url,
    )
    facts = {
        "model": model,
        "app_id_configured": bool(app_id),
        "app_key_readable": app_key_readable,
        "broker_url": broker_url,          # a URL, not a credential
        "relay_url": relay_url,
        "run_token_configured": bool(run_token),
        "env_token_configured": bool(explicit),
    }

    if model == "none":
        return Edge(
            kind="gh_auth", name="gh_auth", status="warn", code=GH_AUTH_NONE,
            detail="no GitHub auth configured on this machine",
            fix=("set MSHIP_GH_BROKER_URL + MSHIP_SERVE_TOKEN to use a broker, "
                 "or GH_TOKEN/GITHUB_TOKEN for a direct token"),
            facts=facts,
        )
    if app_id and not app_key_readable:
        return Edge(
            kind="gh_auth", name="gh_auth", status="fail", code=_GH_AUTH_CODES[model],
            detail="MSHIP_GH_APP_ID is set but MSHIP_GH_APP_KEY is not a readable file",
            fix=("fix the MSHIP_GH_APP_KEY path, or unset it to fall back to "
                 "`gh auth token` deliberately"),
            facts=facts,
        )
    return Edge(
        kind="gh_auth", name="gh_auth", status="ok", code=_GH_AUTH_CODES[model],
        detail=f"GitHub auth model in effect: {model}", fix=None, facts=facts,
    )


def _egress_edge(*, shell) -> Edge:
    """Is this machine's git routed through a relay egress proxy?

    Detected by reading git's global `insteadOf` rewrites — the ones
    `relay.worker_config.relay_git_config_commands` installs — and recognizing
    them via `relay.contract.PREFIX_HOST`, so detection cannot drift from
    installation. Read-only (`git config --get-regexp` writes nothing).
    """
    from mship.core.relay.contract import PREFIX_HOST

    cmd = 'git config --global --get-regexp "^url\\..*\\.insteadof$"'
    try:
        from pathlib import Path
        result = shell.run(cmd, cwd=Path("."))
    except Exception as exc:
        return Edge(
            kind="egress", name="egress", status="warn", code=EGRESS_UNKNOWN,
            detail=f"could not read git global config ({exc})",
            fix="ensure `git` is installed and on PATH to report egress routing",
            facts={},
        )

    bases: set[str] = set()
    for line in (result.stdout or "").splitlines():
        key, _, value = line.strip().partition(" ")
        if not key.startswith("url.") or not key.endswith(".insteadof"):
            continue
        rewritten = key[len("url."):-len(".insteadof")]
        for prefix in PREFIX_HOST:
            if rewritten.endswith(prefix):
                bases.add(rewritten[: -len(prefix)])

    if not bases:
        return Edge(
            kind="egress", name="egress", status="absent", code=EGRESS_ABSENT,
            detail="git is not routed through a relay egress on this machine",
            fix=None,
            facts={"prefixes": sorted(PREFIX_HOST)},
        )
    base = sorted(bases)[0]
    return Edge(
        kind="egress", name="egress", status="ok", code=EGRESS_ROUTED,
        detail=f"git is routed through {base}", fix=None,
        facts={"relay_base": base, "prefixes": sorted(PREFIX_HOST)},
    )
```

In `probe_topology`, default the shell and append both edges:

```python
    if shell is None:
        from mship.util.shell import ShellRunner
        shell = ShellRunner()
    ...
    edges.append(_gh_auth_edge(env=env))
    edges.append(_egress_edge(shell=shell))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_topology_probe.py -v > /tmp/t6.log 2>&1; echo "exit=$?"; tail -8 /tmp/t6.log`
Expected: `exit=0`, 26 passed.

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/topology.py tests/core/test_topology_probe.py
git commit -m "feat(topology): gh-auth model + egress routing edges; never-raises coverage"
mship journal "gh_auth + egress edges; broken-environment test proves probe_topology never raises" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=7 -->
### Task 7: Secret-absence test (AC7)

**Files:**
- Test: `tests/core/test_topology_redaction.py`

A structured dump of connectivity state is exactly where a token accidentally gets serialized. This is the test that makes redaction a property rather than an intention: plant distinctive secrets in *every* place topology reads, serialize the whole payload, and assert none of them appear.

No implementation is expected — if this fails, the leak is the bug.

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_topology_redaction.py
"""AC7: no secret material in any topology output.

Plant a unique sentinel in every secret-bearing input topology reads, then
assert none survive into the serialized payload. Serializing the WHOLE payload
(not per-field) is deliberate: a new edge that leaks a token fails this test
without anyone remembering to extend it.
"""
import json
from dataclasses import dataclass
from pathlib import Path

from mship.core.relay.health import HealthProbe
from mship.core.run_host.config import RunHostConnection
from mship.core.run_host.store import RunHostStore
from mship.core.topology import probe_topology, topology_payload

SECRETS = {
    "run_host_token": "SENTINEL-runhost-token",
    "serve_token": "SENTINEL-serve-token",
    "env_run_host_token": "SENTINEL-env-runhost-token",
    "gh_token": "SENTINEL-gh-token",
    "run_token": "SENTINEL-run-token",
    "serve_token_env": "SENTINEL-serve-token-env",
    "app_key_body": "SENTINEL-app-private-key-body",
    "subdomain_secret": "SENTINEL-subdomain-secret-bytes",
}


@dataclass
class Cfg:
    workspace: str = "ws"
    run_hosts: tuple = ("mac",)
    repos: dict = None
    relay: object = None

    def __post_init__(self):
        self.repos = self.repos or {}


class Shell:
    def run(self, cmd, cwd=None, **kw):
        class R:
            stdout, stderr, returncode = "", "", 1
        return R()


def test_no_secret_reaches_the_payload(tmp_path: Path):
    state = tmp_path / ".mothership"
    state.mkdir(parents=True)
    (state / "serve-token").write_text(SECRETS["serve_token"])
    (state / "relay-subdomain-secret").write_bytes(
        SECRETS["subdomain_secret"].encode() * 2
    )
    RunHostStore(state).set("mac", RunHostConnection(
        url="https://mac.relay", token=SECRETS["run_host_token"],
    ))
    key = tmp_path / "app.pem"
    key.write_text(f"-----BEGIN PRIVATE KEY-----\n{SECRETS['app_key_body']}\n")

    env = {
        "MSHIP_RUN_HOST_MAC_TOKEN": SECRETS["env_run_host_token"],
        "GH_TOKEN": SECRETS["gh_token"],
        "MSHIP_RUN_TOKEN": SECRETS["run_token"],
        "MSHIP_SERVE_TOKEN": SECRETS["serve_token_env"],
        "MSHIP_GH_APP_ID": "999",
        "MSHIP_GH_APP_KEY": str(key),
        "MSHIP_RELAY_URL": "https://relay.example.com",
    }

    topology = probe_topology(
        config=Cfg(relay=object()), state_dir=state, workspace_root=tmp_path,
        home=tmp_path, env=env, shell=Shell(), now=lambda: "t",
        pid_alive=lambda pid: True,
        probe=lambda url, token, *, timeout=None: HealthProbe(ok=True, status_code=200),
    )
    blob = json.dumps(topology_payload(topology))

    leaked = [name for name, value in SECRETS.items() if value in blob]
    assert leaked == [], f"topology payload leaked: {leaked}"


def test_token_presence_is_still_reported_as_a_boolean(tmp_path: Path):
    """Redaction must not cost the operator the information they need: the
    payload says a token IS configured, without saying what it is."""
    state = tmp_path / ".mothership"
    state.mkdir(parents=True)
    RunHostStore(state).set("mac", RunHostConnection(
        url="https://mac.relay", token=SECRETS["run_host_token"],
    ))
    topology = probe_topology(
        config=Cfg(), state_dir=state, workspace_root=tmp_path, home=tmp_path,
        env={}, shell=Shell(), now=lambda: "t", pid_alive=lambda pid: True,
        probe=lambda url, token, *, timeout=None: HealthProbe(ok=True, status_code=200),
    )
    edge = [e for e in topology.edges if e.name == "run_host:mac"][0]
    assert edge.facts["token_configured"] is True
```

- [ ] **Step 2: Run the test**

Run: `uv run pytest tests/core/test_topology_redaction.py -v > /tmp/t7.log 2>&1; echo "exit=$?"; tail -20 /tmp/t7.log`
Expected: `exit=0`, 2 passed. **If it fails, the named secret is genuinely leaking** — fix `topology.py` (drop the field or reduce it to a boolean), do not weaken the test.

- [ ] **Step 3: Commit**

```bash
git add tests/core/test_topology_redaction.py
git commit -m "test(topology): assert no planted secret survives into the payload"
mship journal "redaction test: 8 sentinel secrets, none reach the serialized payload" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=8 -->
### Task 8: `mship net status`

**Files:**
- Create: `src/mship/cli/net.py`
- Modify: `src/mship/cli/__init__.py`
- Test: `tests/cli/test_net_status.py`

Human table on a TTY, the payload verbatim when piped or `--json` — `Output` already decides which mode applies, so the command just asks it.

- [ ] **Step 1: Write the failing test**

```python
# tests/cli/test_net_status.py
import json

from typer.testing import CliRunner

from mship.cli import app

runner = CliRunner()


def _fake_topology():
    from mship.core.topology import Edge, Topology
    return Topology(
        version=1, workspace="ws", probed_at="2026-07-25T16:00:00+00:00",
        edges=[
            Edge(kind="serve", name="serve", status="ok", code="serve_relay_running",
                 detail="relay-serve pid 1 running", fix=None, facts={"mode": "relay"}),
            Edge(kind="run_host", name="run_host:mac", status="fail",
                 code="run_host_unmapped", detail="no connection mapped",
                 fix="run `mship run-host add mac`", facts={}),
        ],
    )


def test_json_mode_emits_the_payload(monkeypatch):
    monkeypatch.setattr("mship.core.topology.probe_topology", lambda **kw: _fake_topology())
    result = runner.invoke(app, ["net", "status", "--json"])
    assert result.exit_code == 0
    payload = json.loads(result.stdout)
    assert payload["version"] == 1
    assert payload["edges"][1]["code"] == "run_host_unmapped"


def test_human_mode_shows_status_and_fix(monkeypatch):
    monkeypatch.setattr("mship.core.topology.probe_topology", lambda **kw: _fake_topology())
    result = runner.invoke(app, ["net", "status"], env={"MSHIP_FORCE_TTY": "1"})
    assert result.exit_code == 0
    assert "run_host:mac" in result.stdout
    assert "run-host add mac" in result.stdout


def test_exits_zero_even_when_everything_is_broken(monkeypatch):
    """AC4: this command must work precisely when connectivity is broken."""
    from mship.core.topology import Edge, Topology
    broken = Topology(version=1, workspace="ws", probed_at="t", edges=[
        Edge(kind="relay", name="relay", status="fail", code="relay_unreachable",
             detail="down", fix="restart serve", facts={}),
    ])
    monkeypatch.setattr("mship.core.topology.probe_topology", lambda **kw: broken)
    assert runner.invoke(app, ["net", "status"]).exit_code == 0


def test_no_network_flag_is_passed_through(monkeypatch):
    seen = {}

    def spy(**kw):
        seen.update(kw)
        return _fake_topology()

    monkeypatch.setattr("mship.core.topology.probe_topology", spy)
    assert runner.invoke(app, ["net", "status", "--no-network"]).exit_code == 0
    assert seen["skip_network"] is True
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/cli/test_net_status.py -v > /tmp/t8.log 2>&1; echo "exit=$?"; tail -8 /tmp/t8.log`
Expected: non-zero — `No such command 'net'`

- [ ] **Step 3: Write minimal implementation**

```python
# src/mship/cli/net.py
"""`mship net` — report this machine's connectivity topology.

A thin caller over `mship.core.topology.probe_topology`: the same structure the
`doctor` connectivity group and `GET /net/topology` report, rendered for a
terminal. Exits 0 even when every edge is broken — this command has to work
precisely when connectivity does not.
"""
from __future__ import annotations

import typer

from mship.cli.output import Output

_ICON = {"ok": "[green]OK[/green]", "warn": "[yellow]WARN[/yellow]",
         "fail": "[red]FAIL[/red]", "absent": "[dim]--[/dim]"}


def register(parent: typer.Typer, get_container):
    net_app = typer.Typer(
        name="net",
        help="Inspect connectivity: serve, relay, run hosts, GitHub auth, egress.",
        no_args_is_help=True,
    )

    @net_app.command("status")
    def status(
        no_network: bool = typer.Option(
            False, "--no-network",
            help="Skip network probes; report configured state only.",
        ),
    ):
        """Show this machine's connectivity topology and per-edge health."""
        from mship.core import topology as topo
        from mship.core.config import ConfigLoader

        out = Output()
        container = get_container()
        # require_paths=False so a half-configured workspace still reports its
        # connectivity — the same reason `doctor` loads this way.
        config = ConfigLoader.load(container.config_path(), require_paths=False)

        result = topo.probe_topology(
            config=config,
            state_dir=container.state_dir(),
            workspace_root=container.config_path().parent,
            skip_network=no_network,
        )

        if out.json_mode:
            out.json(topo.topology_payload(result))
            return

        out.print(f"[bold]Workspace:[/bold] {result.workspace}   "
                  f"[dim]probed {result.probed_at}[/dim]\n")
        out.table(
            title="Connectivity",
            columns=["", "Edge", "State", "Detail"],
            rows=[
                [_ICON.get(e.status, e.status), e.name, e.code, e.detail]
                for e in result.edges
            ],
        )
        fixes = [e for e in result.edges if e.fix and e.status in ("warn", "fail")]
        if fixes:
            out.print("\n[bold]Next steps:[/bold]")
            for e in fixes:
                out.print(f"  [yellow]{e.name}[/yellow]: {e.fix}")

    parent.add_typer(net_app)
```

In `src/mship/cli/__init__.py`, add the import beside the others (alphabetical, after `_message_mod`):

```python
from mship.cli import net as _net_mod
```

and the registration beside the others:

```python
_net_mod.register(app, get_container)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/cli/test_net_status.py -v > /tmp/t8.log 2>&1; echo "exit=$?"; tail -8 /tmp/t8.log`
Expected: `exit=0`, 4 passed.

Then exercise it for real (this workspace has a live relay serve, so this is a genuine end-to-end check):

Run: `uv run mship net status` and `uv run mship net status --json | head -30`
Expected: a table naming serve/relay/run-host/gh_auth/egress edges; the JSON carries `"version": 1`.

- [ ] **Step 5: Commit**

```bash
git add src/mship/cli/net.py src/mship/cli/__init__.py tests/cli/test_net_status.py
git commit -m "feat(cli): mship net status — human topology view plus --json payload"
mship journal "mship net status landed; verified against this workspace's live relay serve" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=9 -->
### Task 9: `doctor` connectivity group

**Files:**
- Modify: `src/mship/core/doctor.py`
- Modify: `src/mship/cli/doctor.py`
- Test: `tests/core/test_doctor.py` (append)

`DoctorChecker` already receives `config`, `state_dir`, and `workspace_root` — everything `probe_topology` needs — so this is a call, not a new capability. The test asserts the checks come from that one function, which is the grep-verifiable "no duplicated probe logic" in AC3.

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_doctor.py  — append
def test_doctor_reports_connectivity_from_probe_topology(tmp_path, monkeypatch):
    """AC3: doctor's connectivity checks come from probe_topology, not from a
    second copy of the probe logic."""
    from mship.core import topology as topo
    from mship.core.doctor import DoctorChecker

    called = {}

    def fake_probe(**kw):
        called.update(kw)
        return topo.Topology(version=1, workspace="ws", probed_at="t", edges=[
            topo.Edge(kind="relay", name="relay", status="fail",
                      code="relay_unreachable", detail="down",
                      fix="restart `mship serve --relay`", facts={}),
            topo.Edge(kind="egress", name="egress", status="absent",
                      code="egress_absent", detail="not routed", fix=None, facts={}),
        ])

    monkeypatch.setattr(topo, "probe_topology", fake_probe)

    config = _minimal_config(tmp_path)          # existing helper in this file
    report = DoctorChecker(
        config, _FakeShell(), state_dir=tmp_path / ".mothership",
        workspace_root=tmp_path,
    ).run()

    conn = [c for c in report.checks if c.name.startswith("connectivity/")]
    assert [c.name for c in conn] == ["connectivity/relay", "connectivity/egress"]
    assert conn[0].status == "fail"
    assert "restart `mship serve --relay`" in conn[0].message
    # `absent` is not a problem to fix -> reported as a pass
    assert conn[1].status == "pass"
    assert called["skip_network"] is False


def test_doctor_can_skip_network_probes(tmp_path, monkeypatch):
    from mship.core import topology as topo
    from mship.core.doctor import DoctorChecker

    seen = {}
    monkeypatch.setattr(topo, "probe_topology", lambda **kw: (
        seen.update(kw),
        topo.Topology(version=1, workspace="ws", probed_at="t", edges=[]),
    )[1])

    DoctorChecker(
        _minimal_config(tmp_path), _FakeShell(), state_dir=tmp_path / ".mothership",
        workspace_root=tmp_path, probe_network=False,
    ).run()
    assert seen["skip_network"] is True


def test_doctor_survives_a_topology_failure(tmp_path, monkeypatch):
    """probe_topology promises never to raise; doctor must not depend on that
    promise being kept — a connectivity bug can't take down the other checks."""
    from mship.core import topology as topo
    from mship.core.doctor import DoctorChecker

    def boom(**kw):
        raise RuntimeError("probe exploded")

    monkeypatch.setattr(topo, "probe_topology", boom)
    report = DoctorChecker(
        _minimal_config(tmp_path), _FakeShell(), state_dir=tmp_path / ".mothership",
        workspace_root=tmp_path,
    ).run()
    conn = [c for c in report.checks if c.name == "connectivity"]
    assert conn and conn[0].status == "warn"
    assert "probe exploded" in conn[0].message
```

> If `_minimal_config` / `_FakeShell` are named differently in `tests/core/test_doctor.py`, reuse whatever that file already uses to build a `WorkspaceConfig` and a shell double — do not add a second fixture.

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_doctor.py -v > /tmp/t9.log 2>&1; echo "exit=$?"; tail -8 /tmp/t9.log`
Expected: non-zero — no `connectivity/*` checks exist; `probe_network` is an unexpected kwarg.

- [ ] **Step 3: Write minimal implementation**

In `src/mship/core/doctor.py`, add the constructor parameter:

```python
    def __init__(
        self,
        config: WorkspaceConfig,
        shell: ShellRunner,
        *,
        state_dir: Path | None = None,
        workspace_root: Path | None = None,
        config_path: Path | None = None,
        config_source: str | None = None,
        probe_network: bool = True,
    ) -> None:
        ...
        self._probe_network = probe_network
```

and, at the end of `run()` (just before `return report`):

```python
        # Connectivity group — sourced from the SINGLE topology implementation
        # (`mship.core.topology.probe_topology`), the same one `mship net status`
        # and `GET /net/topology` use. No probe logic lives here.
        report.checks.extend(self._connectivity_checks())

        return report

    #: topology edge status -> doctor check status. `absent` means "not
    #: configured on this machine", which is not a problem to report.
    _CONNECTIVITY_STATUS = {"ok": "pass", "warn": "warn", "fail": "fail", "absent": "pass"}

    def _connectivity_checks(self) -> list[CheckResult]:
        if self._state_dir is None or self._workspace_root is None:
            return []
        from mship.core import topology as topo

        try:
            result = topo.probe_topology(
                config=self._config,
                state_dir=self._state_dir,
                workspace_root=self._workspace_root,
                shell=self._shell,
                skip_network=not self._probe_network,
            )
        except Exception as exc:
            # probe_topology promises never to raise; don't let a bug there take
            # down the checks that ran before it.
            return [CheckResult(
                name="connectivity", status="warn",
                message=f"connectivity probe failed: {exc}",
            )]

        checks: list[CheckResult] = []
        for edge in result.edges:
            message = edge.detail if edge.fix is None else f"{edge.detail} — {edge.fix}"
            checks.append(CheckResult(
                name=f"connectivity/{edge.name}",
                status=self._CONNECTIVITY_STATUS.get(edge.status, "warn"),
                message=message,
            ))
        return checks
```

In `src/mship/cli/doctor.py`, add the flag and pass it:

```python
    def doctor(
        no_network: bool = typer.Option(
            False, "--no-network",
            help="Skip connectivity network probes (faster; config-level checks only).",
        ),
    ):
```

and in the `DoctorChecker(...)` construction: `probe_network=not no_network,`.

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_doctor.py -v > /tmp/t9.log 2>&1; echo "exit=$?"; tail -8 /tmp/t9.log`
Expected: `exit=0`, all passed (pre-existing doctor tests included).

Verify the no-duplicate-probe claim in AC3:

Run: `grep -rn "probe_health\|verify_relay_reachable" src/mship/core/topology.py src/mship/core/doctor.py src/mship/cli/net.py`
Expected: probe calls appear **only** in `src/mship/core/topology.py`.

Then run it for real: `uv run mship doctor | tail -20` and `uv run mship doctor --no-network | tail -20`
Expected: a connectivity group in both; the `--no-network` run returns noticeably faster.

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/doctor.py src/mship/cli/doctor.py tests/core/test_doctor.py
git commit -m "feat(doctor): connectivity check group sourced from probe_topology"
mship journal "doctor connectivity group + --no-network; grep confirms probes live only in core/topology.py" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=10 -->
### Task 10: `GET /net/topology` on serve

**Files:**
- Modify: `src/mship/core/serve.py`
- Test: `tests/core/test_serve_net_topology.py`

The app-level bearer dependency means this endpoint is authenticated by construction (AC5). Without a `config` the endpoint 503s with an actionable message rather than 404ing — the same choice `/exec/{verb}` already makes.

This payload is the console's contract, so the test pins the fields the console needs (AC6).

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_serve_net_topology.py
import pytest
from fastapi.testclient import TestClient

from mship.core.serve import create_app


@pytest.fixture
def app_factory(tmp_path):
    def build(*, config, token="tok"):
        specs = tmp_path / "specs"
        specs.mkdir(exist_ok=True)
        (tmp_path / ".mothership").mkdir(exist_ok=True)

        class _State:
            def load(self):
                class S:
                    tasks = {}
                return S()

        return create_app(
            specs_dir=specs, state_manager=_State(), log_manager=None,
            workspace_root=tmp_path, workspace_name="ws", auth_token=token,
            config=config,
        )
    return build


class Cfg:
    workspace = "ws"
    run_hosts = ()
    repos = {}
    relay = None
    spec_storage = "committed"


def test_requires_the_bearer(app_factory, monkeypatch):
    monkeypatch.setenv("MSHIP_PR_WATCH_INTERVAL", "0")
    client = TestClient(app_factory(config=Cfg()))
    assert client.get("/net/topology").status_code == 401


def test_returns_the_payload_with_a_version(app_factory, monkeypatch):
    monkeypatch.setenv("MSHIP_PR_WATCH_INTERVAL", "0")
    client = TestClient(app_factory(config=Cfg()))
    r = client.get("/net/topology", headers={"Authorization": "Bearer tok"})
    assert r.status_code == 200
    body = r.json()
    assert body["version"] == 1
    assert body["workspace"] == "ws"
    assert body["probed_at"]
    assert isinstance(body["edges"], list)


def test_payload_is_renderable_on_its_own(app_factory, monkeypatch):
    """AC6: every field the console renders comes from this response — no
    in-process-only data. If the console needs a field, it is asserted here."""
    monkeypatch.setenv("MSHIP_PR_WATCH_INTERVAL", "0")
    client = TestClient(app_factory(config=Cfg()))
    body = client.get("/net/topology", headers={"Authorization": "Bearer tok"}).json()

    assert set(body) >= {"version", "workspace", "probed_at", "edges"}
    for edge in body["edges"]:
        assert set(edge) == {"kind", "name", "status", "code", "detail", "fix", "facts"}
        assert edge["status"] in ("ok", "warn", "fail", "absent")


def test_503_when_serve_has_no_workspace_config(app_factory, monkeypatch):
    monkeypatch.setenv("MSHIP_PR_WATCH_INTERVAL", "0")
    client = TestClient(app_factory(config=None))
    r = client.get("/net/topology", headers={"Authorization": "Bearer tok"})
    assert r.status_code == 503
    assert "bootstrap" in r.json()["detail"].lower()


def test_never_500s_on_a_broken_environment(app_factory, monkeypatch):
    monkeypatch.setenv("MSHIP_PR_WATCH_INTERVAL", "0")

    class Broken(Cfg):
        run_hosts = ("mac", "linux")

    client = TestClient(app_factory(config=Broken()))
    r = client.get("/net/topology", headers={"Authorization": "Bearer tok"})
    assert r.status_code == 200
    codes = {e["code"] for e in r.json()["edges"]}
    assert "run_host_unmapped" in codes
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_serve_net_topology.py -v > /tmp/t10.log 2>&1; echo "exit=$?"; tail -8 /tmp/t10.log`
Expected: non-zero — 404 for `/net/topology`.

- [ ] **Step 3: Write minimal implementation**

In `src/mship/core/serve.py`, alongside the other read endpoints (after `/health` is a good home — it is the other infrastructure endpoint):

```python
    @app.get("/net/topology")
    def net_topology():
        """This host's connectivity topology — the SAME payload `mship net
        status --json` prints, from the same `probe_topology`.

        This is the UI contract for the serve-host console (spec
        `serve-host-management-ui`): it carries a schema `version` and must stay
        renderable on its own, so no view logic accumulates here.
        """
        from mship.core import topology as topo

        if config is None:
            raise HTTPException(
                status_code=503,
                detail=("this serve host has no workspace config wired in; "
                        "bootstrap it as an mship workspace and restart serve"),
            )
        result = topo.probe_topology(
            config=config,
            state_dir=workspace_root / ".mothership",
            workspace_root=workspace_root,
        )
        return topo.topology_payload(result)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_serve_net_topology.py -v > /tmp/t10.log 2>&1; echo "exit=$?"; tail -8 /tmp/t10.log`
Expected: `exit=0`, 5 passed.

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/serve.py tests/core/test_serve_net_topology.py
git commit -m "feat(serve): GET /net/topology — the versioned topology contract"
mship journal "GET /net/topology behind the existing bearer; payload pinned as the console contract" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=11 -->
### Task 11: Fix-hint coverage for every documented failure mode

**Files:**
- Test: `tests/core/test_topology_probe.py` (append)

AC8 names six failure modes from `docs/remote-run.md`'s troubleshooting table and requires each to have a **distinct** status code and a unit test. Tasks 4–6 wrote those tests; this task adds the guard that they stay distinct and stay hinted — the thing that actually breaks later, when someone adds a seventh mode and reuses a code.

- [ ] **Step 1: Write the failing test**

```python
# tests/core/test_topology_probe.py  — append
def test_documented_failure_modes_have_distinct_codes():
    """AC8: docs/remote-run.md's troubleshooting rows map 1:1 onto codes."""
    from mship.core import topology as topo

    documented = {
        "unknown role": topo.RUN_HOST_UNKNOWN_ROLE,
        "ambiguous run-host": topo.RUN_HOSTS_AMBIGUOUS_DEFAULT,
        "role unmapped on this machine": topo.RUN_HOST_UNMAPPED,
        "relay unreachable": topo.RUN_HOST_UNREACHABLE,
        "remote not bootstrapped (503)": topo.RUN_HOST_NOT_BOOTSTRAPPED,
        "stale token (401)": topo.RUN_HOST_STALE_TOKEN,
    }
    assert len(set(documented.values())) == len(documented)


def test_every_status_code_constant_is_unique():
    """A copy-pasted constant would silently merge two states in the UI."""
    from mship.core import topology as topo

    codes = [
        v for k, v in vars(topo).items()
        if k.isupper() and isinstance(v, str) and not k.startswith("_")
        and k not in ("SCHEMA_VERSION",)
    ]
    assert len(codes) == len(set(codes)), "duplicate status-code value"


def test_no_unhealthy_edge_is_ever_left_without_a_fix(tmp_path: Path):
    """Across every unhealthy shape this module can produce, `fix` is set —
    a status code with no next step is a dead end for the operator."""
    cfg = FakeConfig(run_hosts=("mac", "linux"), relay=object(),
                     repos={"api": FakeRepo(run_host="typo")})
    _map_role(tmp_path, "linux", "https://linux.relay")
    _map_role(tmp_path, "orphan", "https://orphan.relay")
    write_runtime_record(tmp_path, RelayRuntimeRecord(
        host="h", pid=1, subdomain="s", url="https://s.relay", workspace="ws",
    ))
    t = _run(
        tmp_path, cfg,
        probe=_probe(**{"https://linux.relay": HealthProbe(ok=False, status_code=503)}),
        shell=FakeShell(raises=OSError("no git")),
    )
    unhealthy = [e for e in t.edges if e.status in ("warn", "fail")]
    assert unhealthy, "expected this fixture to produce unhealthy edges"
    missing = [e.name for e in unhealthy if not e.fix]
    assert missing == [], f"edges with no fix hint: {missing}"
```

- [ ] **Step 2: Run test to verify it fails (or reveals a real gap)**

Run: `uv run pytest tests/core/test_topology_probe.py -k "documented or unique or without_a_fix" -v > /tmp/t11.log 2>&1; echo "exit=$?"; tail -12 /tmp/t11.log`
Expected: it may pass immediately (Tasks 4–6 already set every `fix`). If it fails, the named edge genuinely lacks a hint or reuses a code — fix `topology.py`.

- [ ] **Step 3: Commit**

```bash
git add tests/core/test_topology_probe.py
git commit -m "test(topology): pin distinct codes + a fix hint for every documented failure mode"
mship journal "AC8 guard: documented failure modes map 1:1 to codes, no unhealthy edge without a hint" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=12 -->
### Task 12: Docs — point the troubleshooting table at `mship net status`

**Files:**
- Modify: `docs/remote-run.md`
- Modify: `docs/index.md` (only the command list, if one is present)
- Modify: `mkdocs.yml` (nav — only if adding a new page)

The spec's premise is that diagnosis knowledge stopped living only in prose. The prose should now hand off to the command, and the table should say which code each row maps to — otherwise the next person still debugs by reading paragraphs.

- [ ] **Step 1: Add the handoff above the troubleshooting table**

In `docs/remote-run.md`, immediately above `## Troubleshooting`'s table (after the `## Troubleshooting` heading), insert:

```markdown
Start with `mship net status`. It reports every connectivity edge on this
machine — serve, relay, each run-host role, the GitHub auth model in effect, and
whether git is routed through a relay egress — with a status code and the fix for
each unhealthy one. `mship doctor` reports the same checks inline as a
`connectivity/*` group, and `GET /net/topology` returns the same JSON.

```bash
mship net status               # human topology view
mship net status --json        # the same structure, for scripts
mship net status --no-network  # configured state only, no probes
```

The table below is the reference for what each status code means.
```

- [ ] **Step 2: Add the status code to each existing row**

Add a `Code` column to the existing table, filling in the six mapped rows and leaving `—` for the four execution-time rows (they are task failures, not topology states):

| Symptom (existing text) | Code |
|---|---|
| `unknown run-host role ...` | `run_host_unknown_role` |
| `ambiguous run-host: ...` | `run_hosts_ambiguous_default` |
| `run-host role '<role>' is declared but has no connection mapped ...` | `run_host_unmapped` |
| `remote host at <url> is unreachable via relay ...` | `run_host_unreachable` |
| `remote workspace not bootstrapped at <url> (503)` | `run_host_not_bootstrapped` |
| `remote host at <url> rejected the bearer token (401)` | `run_host_stale_token` |
| the remaining four rows | `—` |

- [ ] **Step 3: Verify the docs build strictly**

Run: `uv run mkdocs build --strict > /tmp/t12.log 2>&1; echo "exit=$?"; tail -5 /tmp/t12.log`
Expected: `exit=0`. A broken link or a nav entry for a missing file fails here, which is what `--strict` is for.

- [ ] **Step 4: Commit**

```bash
git add docs/remote-run.md mkdocs.yml
git commit -m "docs(remote-run): lead with mship net status; map each symptom to its status code"
mship journal "docs: troubleshooting table now hands off to `mship net status` and names each code" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=13 -->
### Task 13: Full suite, then finish

**Files:** none (verification only)

- [ ] **Step 1: Run the full suite**

Run: `cd /home/bailey/development/repos/mship-workspace/.worktrees/connectivity-topology-layer/mothership && uv run pytest > /tmp/full.log 2>&1; echo "exit=$?"; tail -15 /tmp/full.log`
Expected: `exit=0`. Never trust a piped summary — check the echoed exit code.

- [ ] **Step 2: Record the evidence mship finish wants**

```bash
mship test --repos mothership
```

- [ ] **Step 3: Exercise the three callers against this live workspace**

```bash
uv run mship net status
uv run mship doctor | grep -A 12 connectivity
TOKEN=$(cat /home/bailey/development/repos/mship-workspace/.mothership/serve-token)
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:47100/net/topology | head -40
```

Expected: all three report the same edges. The `curl` runs against the *installed* serve, which will not have this endpoint until a redeploy — a 404 here is expected and is not a code failure. (Deploying serve is a separate step: `scripts/redeploy-serve.sh`, after merge.)

- [ ] **Step 4: Verify no secret leaked into the real output**

```bash
uv run mship net status --json > /tmp/topo.json
grep -c -f <(printf '%s\n' "$(cat /home/bailey/development/repos/mship-workspace/.mothership/serve-token)") /tmp/topo.json || echo "serve token absent (good)"
```

Expected: `serve token absent (good)`.

- [ ] **Step 5: Finish**

```bash
mship finish --task connectivity-topology-layer
```

Then clean up the PR body per the repo's convention (`mship finish` writes the raw spec title and all ACs; scope it to what this PR actually did), and note in the journal that the serve endpoint needs `scripts/redeploy-serve.sh` before Ground Control or the console can reach it.
<!-- /mship:task -->

---

## Self-review

**1. Spec coverage** — each AC maps to at least one task:

| AC | Where |
|---|---|
| ac1 `probe_topology()` inventory + code + hint per edge | Tasks 1, 4, 5, 6 |
| ac2 `mship net status` human + JSON | Task 8 |
| ac3 doctor from the same implementation, no duplicated probes | Task 9 (+ the `grep` verification in its Step 4) |
| ac4 never mutates, never raises, bounded timeouts | Task 6 (`test_fully_broken_environment...`, `test_every_probe_call_is_timeout_bounded`), Task 3 (read-only key paths), Task 4 (`_serve_token` reads without minting) |
| ac5 `GET /net/topology` behind the bearer | Task 10 |
| ac6 schema version + renderable alone | Task 1 (version), Task 10 (`test_payload_is_renderable_on_its_own`) |
| ac7 no secret material, with an absence test | Task 7 |
| ac8 fix hints for the documented modes, distinct codes, unit tests | Tasks 5, 11, 12 |
| ac9 every status path unit-tested with mocked probes | Tasks 4, 5, 6 (all probes injected; no test touches the network) |

**2. Placeholder scan** — no TBDs; every code step carries the actual code. Two places name a judgement the implementer must confirm against the repo rather than invent: the existing fixture names in `tests/core/test_doctor.py` (Task 9 says reuse, don't add a second fixture), and whether `docs/index.md` has a command list to extend (Task 12).

**3. Type consistency** — `Edge(kind, name, status, code, detail, fix, facts)` and `Topology(version, workspace, probed_at, edges)` are used identically in Tasks 1, 4, 5, 6, 9, 10. `probe_health` returns `HealthProbe(ok, status_code, error)` in Task 2 and is consumed with exactly those three attributes in Tasks 4–6. `classify_gh_auth` returns a model *name* in Task 3 and is mapped to a code via `_GH_AUTH_CODES` in Task 6 — deliberately not returning a topology code, so `gh_auth` never imports `topology`. `probe_topology`'s keyword set (`config, state_dir, workspace_root, home, env, probe, pid_alive, shell, now, skip_network, timeout`) is fixed in Task 4 and every later caller passes a subset of it.
