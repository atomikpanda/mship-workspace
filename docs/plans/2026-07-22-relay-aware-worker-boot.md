# Relay-Aware Worker Boot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `relay-aware-worker-boot` (approved). Read `specs/2026-07-22-relay-aware-worker-boot.md` first — this plan implements its 7 ACs.

**Goal:** Give a fresh Claude-routine cloud worker the small glue to use the shipped attach-at-relay path: `mship bootstrap` and `mship gh preflight` each gain a relay mode, driven by a single shared relay-contract source, plus a skill documenting the end-to-end routine pattern.

**Architecture:** Extract the relay egress contract (the `/gh/` + `/api/` path prefixes, their upstream hosts, and the `Mship-Run-Token` header name) into one module, `core/relay/contract.py`, and make the existing egress-proxy consume it — so the worker-side git config and preflight probe read the *same* constants the server parses and can never drift. `mship bootstrap --relay-url/--run-token` writes those constants as `git config --global` `insteadOf` rewrites + an `extraHeader` *before* cloning, then clones with **no** GitHub token resolved. `mship gh preflight --relay-url/--run-token` reuses the existing `permissions.push` verification, routed through the relay `/api` leg + the run-token header instead of `api.github.com` + a bearer — one verification, two transports. A new SKILL.md captures the routine pattern.

**Tech Stack:** Python 3, Typer (CLI), httpx (+ `httpx.MockTransport` for tests), pytest, `mship.util.shell.ShellRunner` (subprocess seam), dependency-injector container.

---

## Single-source decision (state it once, referenced by every task)

The relay contract lives in a NEW module **`src/mship/core/relay/contract.py`**, exposing:

```python
GH_PREFIX = "/gh/"
API_PREFIX = "/api/"
GH_HOST = "github.com"
API_HOST = "api.github.com"
PREFIX_HOST: dict[str, str] = {GH_PREFIX: GH_HOST, API_PREFIX: API_HOST}
RUN_TOKEN_HEADER = "Mship-Run-Token"
```

- `core/relay/egress/request.py` currently owns the private `_PREFIX_HOST = {"/gh/": "github.com", "/api/": "api.github.com"}`. It is **moved** to `contract.py`; `request.py` imports `PREFIX_HOST` from there.
- `core/relay/egress/proxy.py` currently has the literal `"Mship-Run-Token"` (in `request.headers.get(...)`) and `"mship-run-token"` (in `_STRIP`). Both are **replaced** with `RUN_TOKEN_HEADER` / `RUN_TOKEN_HEADER.lower()`.
- The new worker-side code (`worker_config.py`, `gh_preflight.py` relay branch) imports the same constants.

Result: the egress-proxy parses by these constants AND the worker emits git config / probes from these constants. A drift on either side changes the shared source and breaks a pinned test (Tasks 1 & 2).

## Preflight factoring (one verification, two transports)

`verify_token_covers_repos` currently hardcodes `_API` + `Authorization: Bearer {token}`. Task 5 extracts the status/`permissions.push` loop into a transport-agnostic `verify_repos_pushable(*, base_url, auth_headers, repo_owner_names, timeout, client)`. `verify_token_covers_repos(*, token, ...)` stays as a thin wrapper (GitHub base + bearer) so the override-token branch and its existing tests are untouched. The relay branch of `run_preflight` calls `verify_repos_pushable` with `base_url=<relay>/api` and `auth_headers={Mship-Run-Token: <run_token>}`.

## Where the real code differed from the spec's Architecture

- **Contract source did not exist yet.** The spec's Architecture floats "e.g. core/relay/worker_config.py, or reuse the egress request module's prefix map". Concrete decision: a dedicated `contract.py` (prefixes+hosts+header), because the header name is *not* currently single-sourced — it is a literal in `proxy.py` — so "reuse `_PREFIX_HOST`" alone would leave the header name to drift. `contract.py` captures both.
- **ShellRunner runs shell strings, not argv.** `ShellRunner.run(command: str, cwd, env=None)` executes with `shell=True`. So `worker_config` emits ready-to-run `git config --global ...` command **strings** (shlex-quoted), matching how `_clone_one` already builds its `git clone` string — not argv lists.
- **Pairing validation lives at the CLI edge.** Per "validate at edges; core assumes clean state", `relay_flags_error()` is called by both CLIs; `core.bootstrap` / `run_preflight` treat relay mode as active only when *both* are set.
- **`repo_set_from_config` is the helper name** in `gh_preflight.py` (the task brief referenced it loosely); it is unchanged and still used by the CLI.

---

## File Structure

**New files:**
- `src/mship/core/relay/contract.py` — single source of truth for the egress path prefixes, their upstream hosts, and the run-token header name.
- `src/mship/core/relay/worker_config.py` — emits the relay `git config --global` command strings from the contract; validates the `--relay-url`/`--run-token` flag pair.
- `src/mship/skills/overnight-cloud-worker-routines/SKILL.md` — the end-to-end cloud-worker-routine pattern.
- `tests/core/relay/test_contract.py` — asserts the contract constants and that the egress-proxy consumes the same source.
- `tests/core/relay/test_worker_config.py` — asserts the exact git config emitted + the pairing validator.
- `tests/core/test_gh_preflight_relay.py` — unit tests for the relay branch of `run_preflight` / `verify_repos_pushable` (httpx.MockTransport).
- `tests/skills/test_overnight_cloud_worker_routines.py` — doc-lint that the skill documents the real command flow + guarantees.

**Modified files:**
- `src/mship/core/relay/egress/request.py` — consume `contract.PREFIX_HOST` (drop the private `_PREFIX_HOST`).
- `src/mship/core/relay/egress/proxy.py` — consume `contract.RUN_TOKEN_HEADER`.
- `src/mship/core/bootstrap.py` — add relay mode: configure git before cloning, no-token clone path.
- `src/mship/cli/bootstrap.py` — add `--relay-url`/`--run-token` + pairing validation.
- `src/mship/core/gh_preflight.py` — add `verify_repos_pushable`; add the relay branch to `run_preflight`.
- `src/mship/cli/gh.py` — add `--relay-url`/`--run-token` + pairing validation, wire the relay branch.
- `tests/core/test_bootstrap.py` — add the relay-mode core test.
- `tests/cli/test_bootstrap.py` — add the relay pairing + flag-forwarding CLI tests.
- `tests/cli/test_gh_preflight.py` — add the relay CLI tests.

All paths below are relative to the task worktree `mothership/` repo root:
`/home/bailey/development/repos/mship-workspace/.worktrees/relay-aware-worker-boot/mothership`.
Run commands from that directory.

---

<!-- mship:task id=1 -->
### Task 1: Shared relay-contract module + egress consumes it

**Files:**
- Create: `src/mship/core/relay/contract.py`
- Modify: `src/mship/core/relay/egress/request.py` (drop private `_PREFIX_HOST`, import `PREFIX_HOST`)
- Modify: `src/mship/core/relay/egress/proxy.py` (replace `"Mship-Run-Token"` literals with `RUN_TOKEN_HEADER`)
- Test: `tests/core/relay/test_contract.py`

- [ ] **Step 1: Write the failing test**

Create `tests/core/relay/test_contract.py`:

```python
"""The relay contract is a single source: the egress-proxy parses by the same
prefixes/header the worker-side config emits, so they can't drift."""
from __future__ import annotations

from mship.core.relay import contract
from mship.core.relay.egress import proxy, request


def test_contract_constants_are_the_relay_shape():
    assert contract.PREFIX_HOST == {"/gh/": "github.com", "/api/": "api.github.com"}
    assert contract.RUN_TOKEN_HEADER == "Mship-Run-Token"
    assert contract.API_PREFIX == "/api/"
    assert contract.GH_PREFIX == "/gh/"


def test_egress_request_parser_uses_the_shared_prefix_map():
    # Same object, not a copy — a change to contract.PREFIX_HOST changes the
    # egress parser too (drift-proof).
    assert request.PREFIX_HOST is contract.PREFIX_HOST


def test_egress_proxy_uses_the_shared_run_token_header():
    assert proxy.RUN_TOKEN_HEADER is contract.RUN_TOKEN_HEADER
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/relay/test_contract.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'mship.core.relay.contract'`.

- [ ] **Step 3: Write the contract module**

Create `src/mship/core/relay/contract.py`:

```python
"""Single source of truth for the relay egress contract (spec relay-aware-worker-boot).

Both ends of the relay must agree on:
  - the worker-facing path prefixes and the upstream host each maps to
    (/gh/ -> github.com git, /api/ -> api.github.com REST), and
  - the header name the worker carries its low-value per-run token in.

The egress-proxy PARSES incoming requests by these prefixes (egress/request.py)
and reads the run token from this header (egress/proxy.py); the worker-side git
config (worker_config.py) and the relay preflight probe (gh_preflight.py) EMIT
exactly the same prefixes + header. Sourcing both ends here means they can
never drift.
"""
from __future__ import annotations

GH_PREFIX = "/gh/"
API_PREFIX = "/api/"
GH_HOST = "github.com"
API_HOST = "api.github.com"

# Worker-facing path prefix -> upstream host. Adding a host = one entry here
# + one route (egress/routes.py) + one tls_ask/Caddy allowance.
PREFIX_HOST: dict[str, str] = {GH_PREFIX: GH_HOST, API_PREFIX: API_HOST}

# Header the worker carries its per-run token in (relay attaches real creds at egress).
RUN_TOKEN_HEADER = "Mship-Run-Token"
```

- [ ] **Step 4: Point the egress request parser at the shared map**

In `src/mship/core/relay/egress/request.py`, replace the private map (lines 6-8):

```python
# Path prefix -> upstream host. Adding a host = one entry here + one route
# (routes.py) + one tls_ask/Caddy allowance. No github.com special-case in code.
_PREFIX_HOST = {"/gh/": "github.com", "/api/": "api.github.com"}
```

with an import from the contract (place near the top imports):

```python
from mship.core.relay.contract import PREFIX_HOST
```

Then update the two use sites inside `parse_egress_request` (was `_PREFIX_HOST`):

```python
    prefix = next((p for p in PREFIX_HOST if path.startswith(p)), None)
    if prefix is None:
        raise UnmappablePathError(path)
    host = PREFIX_HOST[prefix]
```

Leave the rest of `request.py` unchanged (the `host == "github.com"` branch at the repo-extract step is pre-existing and out of scope).

- [ ] **Step 5: Point the egress proxy at the shared header name**

In `src/mship/core/relay/egress/proxy.py`, add the import near the top:

```python
from mship.core.relay.contract import RUN_TOKEN_HEADER
```

Replace the `_STRIP` literal (line 16) `"mship-run-token"` with `RUN_TOKEN_HEADER.lower()`:

```python
_STRIP = {RUN_TOKEN_HEADER.lower(), "host", "content-length", "authorization",
          "transfer-encoding", "connection"}
```

Replace the header read (line 35):

```python
        presented = request.headers.get(RUN_TOKEN_HEADER)
```

- [ ] **Step 6: Run the new test + the existing egress tests**

Run: `uv run pytest tests/core/relay/test_contract.py tests/core/relay/egress -v`
Expected: PASS — the contract tests pass and the existing egress-proxy/request tests are unaffected (they parse and strip via the same constants).

- [ ] **Step 7: Commit**

```bash
git add src/mship/core/relay/contract.py \
        src/mship/core/relay/egress/request.py \
        src/mship/core/relay/egress/proxy.py \
        tests/core/relay/test_contract.py
git commit -m "feat(relay): single-source the egress contract (prefixes + run-token header)"
mship journal "added core/relay/contract.py; egress request/proxy now read the shared prefixes + Mship-Run-Token header (relay-aware-worker-boot ac2)" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: Worker git-config emitter + flag-pair validator

**Files:**
- Create: `src/mship/core/relay/worker_config.py`
- Test: `tests/core/relay/test_worker_config.py`

- [ ] **Step 1: Write the failing test**

Create `tests/core/relay/test_worker_config.py`:

```python
"""The worker-side git config emitted for a relay boot, pinned to the exact
contract shape (so any drift from the egress-server breaks this test)."""
from __future__ import annotations

from mship.core.relay.worker_config import (
    relay_flags_error,
    relay_git_config_commands,
)


def test_emits_exactly_three_global_config_commands():
    cmds = relay_git_config_commands("https://relay.example", "rt-123")
    assert len(cmds) == 3
    assert all(c.startswith("git config --global ") for c in cmds)


def test_insteadof_rewrites_gh_and_api_prefixes_to_relay():
    cmds = relay_git_config_commands("https://relay.example", "rt-123")
    assert any(
        "url.https://relay.example/gh/.insteadOf" in c and "https://github.com/" in c
        for c in cmds
    )
    assert any(
        "url.https://relay.example/api/.insteadOf" in c and "https://api.github.com/" in c
        for c in cmds
    )


def test_extraheader_carries_the_run_token_under_the_contract_header():
    cmds = relay_git_config_commands("https://relay.example", "rt-123")
    assert any(
        "http.https://relay.example/.extraHeader" in c and "Mship-Run-Token: rt-123" in c
        for c in cmds
    )


def test_trailing_slash_on_relay_url_is_normalized():
    cmds = relay_git_config_commands("https://relay.example/", "rt-1")
    # No doubled slash before the /gh/ prefix.
    assert any("url.https://relay.example/gh/.insteadOf" in c for c in cmds)


def test_relay_flags_error_requires_both_or_neither():
    assert relay_flags_error(None, None) is None
    assert relay_flags_error("https://relay.example", "rt-1") is None
    assert "run-token" in relay_flags_error("https://relay.example", None).lower()
    assert "relay-url" in relay_flags_error(None, "rt-1").lower()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/relay/test_worker_config.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'mship.core.relay.worker_config'`.

- [ ] **Step 3: Write the emitter + validator**

Create `src/mship/core/relay/worker_config.py`:

```python
"""Worker-side glue for attach-at-relay boots (spec relay-aware-worker-boot).

Emits the `git config --global` commands that route a DISPOSABLE cloud
worker's git + GitHub-API traffic through the relay egress-proxy, and
validates the --relay-url/--run-token flag pair. The path prefixes and the
run-token header name come from core/relay/contract.py — the SAME constants the
egress-proxy parses — so this config can never drift from the server.
"""
from __future__ import annotations

import shlex

from mship.core.relay.contract import PREFIX_HOST, RUN_TOKEN_HEADER


def relay_git_config_commands(relay_url: str, run_token: str) -> list[str]:
    """The `git config --global` shell commands that point a worker's git at
    the relay:

      - one `url.<relay><prefix>.insteadOf https://<host>/` rewrite per egress
        prefix (so `git clone https://github.com/o/r` -> `<relay>/gh/o/r`, and
        every REST call to api.github.com -> `<relay>/api/...`), and
      - `http.<relay>/.extraHeader <RUN_TOKEN_HEADER>: <run_token>` so every
        relay-bound request carries the low-value per-run token.

    Ready to hand to ShellRunner.run() (shell=True); values are shlex-quoted.
    """
    base = relay_url.rstrip("/")
    cmds: list[str] = []
    for prefix, host in PREFIX_HOST.items():
        key = f"url.{base}{prefix}.insteadOf"
        val = f"https://{host}/"
        cmds.append(f"git config --global {shlex.quote(key)} {shlex.quote(val)}")
    header_key = f"http.{base}/.extraHeader"
    header_val = f"{RUN_TOKEN_HEADER}: {run_token}"
    cmds.append(
        f"git config --global {shlex.quote(header_key)} {shlex.quote(header_val)}"
    )
    return cmds


def relay_flags_error(relay_url: str | None, run_token: str | None) -> str | None:
    """Validate the --relay-url/--run-token pair. They are a unit — relay-attach
    mode needs both. Returns a clear error string when exactly one is given,
    else None (both => relay mode; neither => the command's non-relay behavior)."""
    if bool(relay_url) == bool(run_token):
        return None
    missing = "--run-token" if relay_url else "--relay-url"
    return f"relay mode requires both --relay-url and --run-token; {missing} is missing"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/relay/test_worker_config.py -v`
Expected: PASS (all 5 tests).

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/relay/worker_config.py tests/core/relay/test_worker_config.py
git commit -m "feat(relay): worker git-config emitter + --relay-url/--run-token pair validator"
mship journal "added worker_config.relay_git_config_commands (insteadOf + extraHeader from the contract) and relay_flags_error (relay-aware-worker-boot ac2/ac5)" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: `bootstrap()` relay mode — configure git first, clone with no token

**Files:**
- Modify: `src/mship/core/bootstrap.py:95-145` (`bootstrap` signature + the token-resolution block)
- Test: `tests/core/test_bootstrap.py` (append)

- [ ] **Step 1: Write the failing test**

Append to `tests/core/test_bootstrap.py`:

```python
def test_bootstrap_relay_configures_git_then_clones_without_token(tmp_path, monkeypatch):
    """Relay mode: git config runs (globally) BEFORE the clone, resolve_token is
    never called, and the clone carries no credential args and no token env."""
    from mship.core import bootstrap as bmod
    from mship.util.shell import ShellResult

    def boom_resolve_token(*a, **k):
        raise AssertionError("resolve_token must not run in relay mode")

    monkeypatch.setattr(bmod, "resolve_token", boom_resolve_token)

    calls = []

    class FakeShell:
        def run(self, command, cwd, env=None):
            calls.append((command, env))
            return ShellResult(returncode=0, stdout="", stderr="")
        def run_task(self, *a, **k):
            return ShellResult(returncode=0, stdout="", stderr="")

    ws = tmp_path / "ws"; ws.mkdir(); (ws / ".mothership").mkdir()
    (ws / "mothership.yaml").write_text(
        "workspace: w\nrepos:\n  lib:\n    path: lib\n    type: library\n"
        "    url: https://github.com/o/lib\n"
    )
    bmod.bootstrap(ws / "mothership.yaml", FakeShell(),
                   state_dir=ws / ".mothership",
                   relay_url="https://relay.example", run_token="rt-123")

    commands = [c for c, _ in calls]
    cfg_idxs = [i for i, c in enumerate(commands) if "git config --global" in c]
    clone_idx = next(i for i, c in enumerate(commands) if "clone" in c)
    # All three config commands ran before the clone.
    assert len(cfg_idxs) == 3
    assert max(cfg_idxs) < clone_idx
    cfg = [commands[i] for i in cfg_idxs]
    assert any("url.https://relay.example/gh/.insteadOf" in c and "https://github.com/" in c for c in cfg)
    assert any("url.https://relay.example/api/.insteadOf" in c and "https://api.github.com/" in c for c in cfg)
    assert any("http.https://relay.example/.extraHeader" in c and "Mship-Run-Token: rt-123" in c for c in cfg)
    # Clone took the NO-token path.
    clone_cmd, clone_env = calls[clone_idx]
    assert "credential.https://github.com.helper" not in clone_cmd
    assert clone_env is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/test_bootstrap.py::test_bootstrap_relay_configures_git_then_clones_without_token -v`
Expected: FAIL — `TypeError: bootstrap() got an unexpected keyword argument 'relay_url'`.

- [ ] **Step 3: Add relay mode to `bootstrap()`**

In `src/mship/core/bootstrap.py`, extend the signature (lines 95-102) to add the two keyword-only params:

```python
def bootstrap(
    config_path: Path,
    shell: ShellRunner,
    *,
    state_dir: Path,
    repos: list[str] | None = None,
    token: str | None = None,
    relay_url: str | None = None,
    run_token: str | None = None,
) -> BootstrapReport:
```

Then replace the token-resolution block (currently lines 106-122, the comment block through `resolved_token = resolve_token(...)`) with a relay branch that guards it:

```python
    config_path = Path(config_path)
    workspace_root = config_path.parent
    config = ConfigLoader.load(config_path, require_paths=False)

    if relay_url and run_token:
        # Relay-attach mode: route git through the relay BEFORE cloning, then
        # clone with NO GitHub token on the worker (the relay attaches real
        # creds at egress). Skip token/broker resolution entirely — a stray
        # token could shadow the relay path.
        from mship.core.relay.worker_config import relay_git_config_commands
        for cmd in relay_git_config_commands(relay_url, run_token):
            res = shell.run(cmd, cwd=workspace_root)
            if res.returncode != 0:
                raise ValueError(
                    f"failed to configure git for the relay ({cmd}): "
                    f"{res.stderr.strip()[:200] or 'unknown error'}"
                )
        resolved_token = None
    else:
        # Repo set for the broker-pull fallback: every repo in the workspace
        # config that is its own GitHub repo (git_root repos are subdirectories
        # of their parent's checkout, excluded so a broker mint request never
        # names a repo the App can't see).
        all_repo_names = [n for n, r in config.repos.items() if r.git_root is None]
        # Send the broker `owner/repo` slugs (not short config names) so the
        # folded serve can resolve the GitHub App installation per repo.
        _owner_map = repo_owner_names_from_config(config_path, all_repo_names)
        broker_repos = [_owner_map[n] for n in all_repo_names if n in _owner_map]
        broker_url, broker_bearer = broker_config_from_env()
        resolved_token = resolve_token(
            token, broker_url=broker_url, broker_bearer=broker_bearer,
            repos=broker_repos or all_repo_names,
        )
```

Note: `config_path`/`workspace_root`/`config` are already assigned once at the top of `bootstrap` (lines 103-105) — do not duplicate them; the snippet above shows them only for placement context. The rest of the function (from `names = repos or ...` onward, lines 124+) is unchanged; it already passes `resolved_token` into `_clone_one`, which takes the no-token path when it is `None`.

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/test_bootstrap.py::test_bootstrap_relay_configures_git_then_clones_without_token -v`
Expected: PASS.

- [ ] **Step 5: Run the whole bootstrap suite (no regression on the non-relay path)**

Run: `uv run pytest tests/core/test_bootstrap.py -v`
Expected: PASS — all pre-existing tests (broker-pull, cred-args, no-cred-args, filters) still pass unchanged.

- [ ] **Step 6: Commit**

```bash
git add src/mship/core/bootstrap.py tests/core/test_bootstrap.py
git commit -m "feat(bootstrap): relay mode — configure git for the relay, clone with no GH token"
mship journal "bootstrap() relay mode: emits relay git config before cloning + skips resolve_token (relay-aware-worker-boot ac1)" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: `mship bootstrap` CLI — `--relay-url`/`--run-token` + pairing

**Files:**
- Modify: `src/mship/cli/bootstrap.py`
- Test: `tests/cli/test_bootstrap.py` (append)

- [ ] **Step 1: Write the failing tests**

Append to `tests/cli/test_bootstrap.py`:

```python
def test_bootstrap_relay_pairing_error_exit_nonzero(tmp_path):
    ws = _ws(tmp_path,
             "workspace: w\nrepos:\n  lib:\n    path: lib\n    type: library\n")
    _configure(ws)
    try:
        result = runner.invoke(app, ["bootstrap", "--run-token", "rt-1"])
        assert result.exit_code == 1
        assert "relay-url" in result.output.lower()
    finally:
        _reset()


def test_bootstrap_relay_forwards_both_flags_to_core(tmp_path, monkeypatch):
    import mship.core.bootstrap as bmod
    from mship.core.bootstrap import BootstrapReport

    captured = {}

    def fake_bootstrap(config_path, shell, *, state_dir, repos=None, token=None,
                       relay_url=None, run_token=None):
        captured.update(relay_url=relay_url, run_token=run_token)
        return BootstrapReport(members=(), doctor_ok=None)

    monkeypatch.setattr(bmod, "bootstrap", fake_bootstrap)

    ws = _ws(tmp_path,
             "workspace: w\nrepos:\n  lib:\n    path: lib\n    type: library\n")
    _configure(ws)
    try:
        result = runner.invoke(
            app,
            ["bootstrap", "--relay-url", "https://relay.example", "--run-token", "rt-1"],
        )
        assert result.exit_code == 0, result.output
        assert captured == {"relay_url": "https://relay.example", "run_token": "rt-1"}
    finally:
        _reset()
```

(The CLI imports `bootstrap` locally as `run_bootstrap` inside the command, so patching `mship.core.bootstrap.bootstrap` before `invoke` takes effect at call time — no real `git config --global` runs.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/cli/test_bootstrap.py::test_bootstrap_relay_pairing_error_exit_nonzero tests/cli/test_bootstrap.py::test_bootstrap_relay_forwards_both_flags_to_core -v`
Expected: FAIL — `--relay-url`/`--run-token` are unknown options (the pairing test) / `relay_url` not forwarded (the forwarding test).

- [ ] **Step 3: Add the options + pairing to the CLI**

In `src/mship/cli/bootstrap.py`, add the two options after `token` (in the `bootstrap` command signature):

```python
        relay_url: Optional[str] = typer.Option(
            None, "--relay-url",
            help="Relay egress base URL. With --run-token, route git through the "
                 "relay and clone with no GitHub token on the worker.",
        ),
        run_token: Optional[str] = typer.Option(
            None, "--run-token",
            help="Per-run relay token (paired with --relay-url).",
        ),
```

After `output = Output()` and before building `names`, validate the pair and fail loud at the edge:

```python
        from mship.core.relay.worker_config import relay_flags_error
        pair_error = relay_flags_error(relay_url, run_token)
        if pair_error:
            output.error(pair_error)
            raise typer.Exit(code=1)
```

Then forward the flags in the `run_bootstrap(...)` call:

```python
        try:
            report = run_bootstrap(config_path, shell, state_dir=state_dir,
                                   repos=names, token=token,
                                   relay_url=relay_url, run_token=run_token)
        except ValueError as e:
            output.error(str(e))
            raise typer.Exit(code=1)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/cli/test_bootstrap.py -v`
Expected: PASS — the two new tests pass and the pre-existing bootstrap CLI tests are unchanged.

- [ ] **Step 5: Commit**

```bash
git add src/mship/cli/bootstrap.py tests/cli/test_bootstrap.py
git commit -m "feat(bootstrap): --relay-url/--run-token CLI flags + pairing validation"
mship journal "mship bootstrap gains --relay-url/--run-token with both-or-neither validation (relay-aware-worker-boot ac1/ac5)" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: Preflight relay verification — `verify_repos_pushable` + `run_preflight` relay branch

**Files:**
- Modify: `src/mship/core/gh_preflight.py` (extract `verify_repos_pushable`; add relay branch to `run_preflight`)
- Test: `tests/core/test_gh_preflight_relay.py`

- [ ] **Step 1: Write the failing tests**

Create `tests/core/test_gh_preflight_relay.py`:

```python
"""Relay-attach mode of run_preflight: one verification (permissions.push),
routed through <relay>/api + the Mship-Run-Token header. No live services."""
from __future__ import annotations

import httpx

from mship.core.gh_preflight import run_preflight


def _run(handler, **overrides):
    client = httpx.Client(transport=httpx.MockTransport(handler))
    kwargs = dict(
        explicit_token=None, broker_url=None, broker_bearer=None,
        repos=["lib"], repo_owner_names={"lib": "acme/lib"},
        relay_url="https://relay.example", run_token="rt-1", client=client,
    )
    kwargs.update(overrides)
    return run_preflight(**kwargs)


def test_relay_probes_api_leg_with_run_token_header_and_oks_on_200_push():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = str(request.url)
        seen["path"] = request.url.path
        seen["run_token"] = request.headers.get("Mship-Run-Token")
        seen["has_auth"] = "authorization" in {k.lower() for k in request.headers}
        return httpx.Response(200, json={"permissions": {"push": True}})

    result = _run(handler)
    assert result.ok, result.message
    assert "acme/lib" in result.message
    assert seen["path"] == "/api/repos/acme/lib"
    assert seen["url"] == "https://relay.example/api/repos/acme/lib"
    assert seen["run_token"] == "rt-1"
    assert seen["has_auth"] is False        # relay attaches creds; no bearer from the worker


def test_relay_401_is_invalid_or_expired():
    result = _run(lambda r: httpx.Response(401, json={"message": "bad"}))
    assert not result.ok
    assert "invalid or expired" in result.message.lower()


def test_relay_403_cannot_push():
    result = _run(lambda r: httpx.Response(403, json={"message": "denied"}))
    assert not result.ok
    assert "cannot push" in result.message.lower()
    assert "acme/lib" in result.message


def test_relay_200_without_push_cannot_push():
    result = _run(lambda r: httpx.Response(200, json={"permissions": {"push": False}}))
    assert not result.ok
    assert "cannot push" in result.message.lower()


def test_relay_unreachable_is_a_clear_failure():
    def handler(request):
        raise httpx.ConnectError("connection refused")

    result = _run(handler)
    assert not result.ok
    assert "relay.example" in result.message


def test_relay_mode_does_not_fall_through_to_override_token():
    # A stray GH token/env must be ignored when relay flags are present.
    result = _run(
        lambda r: httpx.Response(200, json={"permissions": {"push": True}}),
        explicit_token="should-not-be-used",
    )
    assert result.ok
    assert "relay covers" in result.message.lower()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/core/test_gh_preflight_relay.py -v`
Expected: FAIL — `run_preflight()` has no `relay_url`/`run_token` params (`TypeError: unexpected keyword argument`).

- [ ] **Step 3: Extract the transport-agnostic verification**

In `src/mship/core/gh_preflight.py`, add `verify_repos_pushable` (place it directly above the existing `verify_token_covers_repos`), moving the status/`permissions.push` loop into it verbatim:

```python
def verify_repos_pushable(
    *,
    base_url: str,
    auth_headers: dict[str, str],
    repo_owner_names: list[str],
    timeout: float = 8.0,
    client: httpx.Client | None = None,
) -> str | None:
    """STRICT check that the caller's auth can push to every `owner/name`, via
    `GET {base_url}/repos/{owner}/{name}` carrying `auth_headers`. ONE
    verification, two transports:
      - override-token: base_url=api.github.com, {Authorization: Bearer <tok>}
      - relay-attach:   base_url=<relay>/api,    {Mship-Run-Token: <run tok>}

    Returns None when every repo responds 200 with `permissions.push` true.
    Returns a clear, non-None error string on the first problem:
      401 -> "token is invalid or expired"; 403/404 or 200-without-push ->
      "token cannot push to {owner/name}"; any other non-200, a non-JSON body,
      a connection error, or a timeout -> a clear error naming the repo (never
      silently passes on ambiguity)."""
    c, owns = (client, False) if client is not None else (httpx.Client(timeout=timeout), True)
    try:
        for owner_name in repo_owner_names:
            try:
                resp = c.get(f"{base_url}/repos/{owner_name}", headers=auth_headers)
            except httpx.HTTPError as e:
                return f"token check request failed for {owner_name}: {e}"

            if resp.status_code == 401:
                return "token is invalid or expired"
            if resp.status_code in (403, 404):
                return f"token cannot push to {owner_name}"
            if resp.status_code != 200:
                return (
                    f"token check for {owner_name} failed "
                    f"({resp.status_code}): {resp.text[:200]}"
                )

            try:
                body = resp.json()
            except ValueError:
                return f"token check for {owner_name} returned a non-JSON response"

            permissions = body.get("permissions") if isinstance(body, dict) else None
            can_push = isinstance(permissions, dict) and bool(permissions.get("push"))
            if not can_push:
                return f"token cannot push to {owner_name}"
        return None
    finally:
        if owns:
            c.close()
```

Then replace the body of the existing `verify_token_covers_repos` with a thin wrapper (keep its signature + docstring intact; delete only the moved loop):

```python
def verify_token_covers_repos(
    *,
    token: str,
    repo_owner_names: list[str],
    timeout: float = 8.0,
    client: httpx.Client | None = None,
) -> str | None:
    """STRICT check that `token` can push to every `owner/name`, via
    `GET /repos/{owner}/{name}`. The override-token transport of
    `verify_repos_pushable` (GitHub REST + a bearer); the verification lives
    once in that helper.
    """
    return verify_repos_pushable(
        base_url=_API,
        auth_headers={"Authorization": f"Bearer {token}"},
        repo_owner_names=repo_owner_names,
        timeout=timeout,
        client=client,
    )
```

- [ ] **Step 4: Add the relay branch to `run_preflight`**

In `run_preflight`, add the two params to the signature (keyword-only, alongside the others):

```python
def run_preflight(
    *,
    explicit_token: str | None,
    broker_url: str | None,
    broker_bearer: str | None,
    repos: list[str],
    repo_owner_names: dict[str, str] | None = None,
    relay_url: str | None = None,
    run_token: str | None = None,
    timeout: float = 8.0,
    client: httpx.Client | None = None,
) -> PreflightResult:
```

Then insert the relay branch as the FIRST thing in the body (before `token = _resolve_override_token(...)`), so relay mode never falls through to the override/broker branches:

```python
    # Relay-attach mode (distinct third mode): probe each repo through the
    # relay's /api leg carrying the run-token header. Returns within this
    # branch — never falls through to the override-token / broker branches.
    if relay_url and run_token:
        from mship.core.relay.contract import API_PREFIX, RUN_TOKEN_HEADER
        owner_names = repo_owner_names or {}
        missing = [n for n in repos if n not in owner_names]
        if missing:
            return PreflightResult(
                False,
                f"cannot verify the relay covers {', '.join(missing)}: no "
                "resolvable GitHub owner (set `url` on the repo or "
                "`default_remote` on the workspace)",
            )
        slugs = [owner_names[n] for n in repos]
        base_url = f"{relay_url.rstrip('/')}{API_PREFIX}".rstrip("/")
        error = verify_repos_pushable(
            base_url=base_url,
            auth_headers={RUN_TOKEN_HEADER: run_token},
            repo_owner_names=slugs, timeout=timeout, client=client,
        )
        if error:
            return PreflightResult(
                False, f"{error} — relay auth can't push through {relay_url}"
            )
        return PreflightResult(True, f"auth OK — relay covers: {', '.join(slugs)}")
```

- [ ] **Step 5: Run the relay tests + the existing preflight tests**

Run: `uv run pytest tests/core/test_gh_preflight_relay.py tests/cli/test_gh_preflight.py -v`
Expected: PASS — the relay unit tests pass and the existing override-token/broker CLI tests are unchanged (they still hit `api.github.com` via the wrapper).

- [ ] **Step 6: Commit**

```bash
git add src/mship/core/gh_preflight.py tests/core/test_gh_preflight_relay.py
git commit -m "feat(preflight): relay-attach verification via verify_repos_pushable (one check, two transports)"
mship journal "gh_preflight: extracted verify_repos_pushable; run_preflight relay branch probes <relay>/api with Mship-Run-Token (relay-aware-worker-boot ac3/ac4)" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: `mship gh preflight` CLI — `--relay-url`/`--run-token` + pairing

**Files:**
- Modify: `src/mship/cli/gh.py`
- Test: `tests/cli/test_gh_preflight.py` (append)

- [ ] **Step 1: Write the failing tests**

Append to `tests/cli/test_gh_preflight.py` (reuses the file's `_ws`, `_configure`, `_reset`, `_patch_httpx_client`, and the `_clean_gh_env` autouse fixture):

```python
def test_preflight_relay_ok_on_200_push_exit_zero(tmp_path, monkeypatch):
    ws = _ws(tmp_path)
    _configure(ws)

    def handler(request: httpx.Request) -> httpx.Response:
        assert "/api/repos/acme/" in request.url.path
        assert request.headers.get("mship-run-token") == "rt-9"
        assert "authorization" not in {k.lower() for k in request.headers}
        return httpx.Response(200, json={"permissions": {"push": True}})

    _patch_httpx_client(monkeypatch, handler)
    try:
        result = runner.invoke(
            app,
            ["gh", "preflight", "--relay-url", "https://relay.example", "--run-token", "rt-9"],
        )
        assert result.exit_code == 0, result.output
        assert "auth ok" in result.output.lower()
        assert "acme/mothership" in result.output
    finally:
        _reset()


def test_preflight_relay_401_exit_nonzero(tmp_path, monkeypatch):
    ws = _ws(tmp_path)
    _configure(ws)

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(401, json={"message": "bad run token"})

    _patch_httpx_client(monkeypatch, handler)
    try:
        result = runner.invoke(
            app,
            ["gh", "preflight", "--relay-url", "https://relay.example", "--run-token", "rt-9"],
        )
        assert result.exit_code != 0
        assert "invalid or expired" in result.output.lower()
    finally:
        _reset()


def test_preflight_relay_pairing_error_exit_nonzero(tmp_path):
    ws = _ws(tmp_path)
    _configure(ws)
    try:
        result = runner.invoke(app, ["gh", "preflight", "--relay-url", "https://relay.example"])
        assert result.exit_code != 0
        assert "run-token" in result.output.lower()
    finally:
        _reset()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/cli/test_gh_preflight.py::test_preflight_relay_ok_on_200_push_exit_zero tests/cli/test_gh_preflight.py::test_preflight_relay_pairing_error_exit_nonzero -v`
Expected: FAIL — `--relay-url`/`--run-token` are unknown options.

- [ ] **Step 3: Add the options + pairing + wiring to the CLI**

In `src/mship/cli/gh.py`, add the two options to the `preflight` command signature (after `token`):

```python
        relay_url: Optional[str] = typer.Option(
            None, "--relay-url",
            help="Relay egress base URL. With --run-token, verify auth through "
                 "the relay (attach-at-relay) instead of a GH token / broker.",
        ),
        run_token: Optional[str] = typer.Option(
            None, "--run-token",
            help="Per-run relay token (paired with --relay-url).",
        ),
```

After `output = Output()` and `container = get_container()`, validate the pair:

```python
        from mship.core.relay.worker_config import relay_flags_error
        pair_error = relay_flags_error(relay_url, run_token)
        if pair_error:
            output.error(pair_error)
            raise typer.Exit(code=1)
```

Then forward the flags to `run_preflight(...)`:

```python
        result = run_preflight(
            explicit_token=token,
            broker_url=broker_url,
            broker_bearer=broker_bearer,
            repos=resolved_repos,
            repo_owner_names=repo_owner_names,
            relay_url=relay_url,
            run_token=run_token,
        )
```

(`repo_owner_names` is already computed unconditionally above — the relay branch reuses it to build the `owner/repo` slugs for the probe URL.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/cli/test_gh_preflight.py -v`
Expected: PASS — the three new relay tests pass and every pre-existing preflight CLI test still passes.

- [ ] **Step 5: Commit**

```bash
git add src/mship/cli/gh.py tests/cli/test_gh_preflight.py
git commit -m "feat(preflight): --relay-url/--run-token CLI mode + pairing validation"
mship journal "mship gh preflight gains relay-attach mode (--relay-url/--run-token) with pairing validation (relay-aware-worker-boot ac3/ac5)" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=7 -->
### Task 7: The `overnight-cloud-worker-routines` skill

**Files:**
- Create: `src/mship/skills/overnight-cloud-worker-routines/SKILL.md`
- Test: `tests/skills/test_overnight_cloud_worker_routines.py`

- [ ] **Step 1: Write the failing doc-lint test**

Create `tests/skills/test_overnight_cloud_worker_routines.py` (mirrors `tests/skills/test_capture_skill.py`):

```python
"""Guard: the overnight-cloud-worker-routines skill documents the real command
flow (the actual flag names) and the guarantees, so it can't drift from the CLI."""
from __future__ import annotations

from mship.core.skill_install import pkg_skills_source


def _skill_text() -> str:
    return (
        pkg_skills_source() / "overnight-cloud-worker-routines" / "SKILL.md"
    ).read_text()


def test_skill_has_frontmatter():
    text = _skill_text()
    assert text.startswith("---")
    assert "name: overnight-cloud-worker-routines" in text
    assert "description:" in text


def test_skill_documents_the_command_flow():
    text = _skill_text()
    assert "mship relay issue-run-token" in text
    assert "mship bootstrap --relay-url" in text
    assert "mship gh preflight --relay-url" in text


def test_skill_states_the_guarantees():
    low = _skill_text().lower()
    assert "run token" in low
    # nothing auto-merges / review-gated
    assert "auto-merge" in low or "review-gated" in low
    # the run token grant must cover the workspace repo + the member repos
    assert "workspace" in low
    assert "--push-branch" in _skill_text()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/skills/test_overnight_cloud_worker_routines.py -v`
Expected: FAIL — `FileNotFoundError` (the SKILL.md does not exist yet).

- [ ] **Step 3: Write the skill**

Create `src/mship/skills/overnight-cloud-worker-routines/SKILL.md`:

```markdown
---
name: overnight-cloud-worker-routines
description: Use when standing up an overnight/unattended Claude Code cloud routine that becomes a disposable mship worker — clones the workspace, implements one approved spec, and opens the PR(s) through the relay, holding only a low-value per-run token.
---

# Overnight Cloud-Worker Routines

## Overview

A cloud-worker routine is a scheduled Claude Code run that, when it fires,
becomes a **disposable mship worker**: it clones the workspace, implements one
assigned spec, and opens the PR(s) — all routed through the **relay**. The
worker never holds a GitHub token. It carries only a low-value, short-lived
**per-run token**; its git and GitHub-API traffic go through the relay, which
attaches and enforces real credentials at egress (attach-at-relay).

**You** (the agent standing the routine up) do two things the worker cannot:
mint the run token and schedule the routine. The worker does the rest.

> Scheduling a routine and creating it are **agent behaviour** (your own Claude
> Code `/schedule` ability), not mship code. This skill documents the pattern;
> mship does not automate it.

## Prerequisites

- An **approved enrollment** with a **github-app grant** whose ceiling covers
  every repo the run touches (see `mship relay enroll` / `mship relay grant`).
- A live relay egress-server reachable at a base URL (the `<relay-url>` below).
- The approved **spec** the worker will implement.

## The flow

### 1. You: mint a per-run token (scoped to the run)

```bash
mship relay issue-run-token <enrollment-id> \
  --repos "acme/mothership,acme/ground-control" \
  --push-branch "feat/<slug>" \
  --ttl 86400
```

- `--repos` must be within the enrollment's grant ceiling. **It must include
  the workspace repo** (so the worker can clone the workspace to read the
  spec/plan) **and every affected member repo** (so it can clone them, push,
  and open PRs).
- `--push-branch` is the run's branch; the relay only lets the attached
  credential push that branch.
- The token prints **once** — inject it into the routine's environment as the
  `--run-token` value. It is low-value: scoped, short-lived, and useless
  without the relay.

### 2. You: schedule a Claude Code routine

Give the routine an environment that installs mship and the relay URL + the
run token, and a prompt/task naming the spec to implement. Its flow is:

### 3. The worker (inside the fired routine)

```bash
# a. Clone the workspace repo through the relay (git already routes there once
#    bootstrap configures it; the very first workspace clone uses the same relay
#    URL + run token). Then, from the workspace root:

# b. Configure git for the relay and clone the members with NO GitHub token:
mship bootstrap --relay-url "<relay-url>" --run-token "<run-token>"

# c. Fail-fast: verify relay-routed auth can actually push, BEFORE spending AI
#    tokens on code it then can't land. Exits non-zero with a clear message on
#    any failure (invalid/expired token, missing push, unreachable relay):
mship gh preflight --relay-url "<relay-url>" --run-token "<run-token>"

# d. Implement the assigned spec (normal mship phase workflow).

# e. Push + open the PR(s) — routed through the relay by the git config
#    bootstrap wrote (e.g. mship finish).
```

## Guarantees

- **The worker holds only the low-value run token.** No GitHub token, no App
  key, no broker bearer ever lands on the worker. The relay attaches real
  credentials at egress and enforces the run's scope (repos + push branch).
- **Nothing auto-merges — the flow is review-gated end to end.** The worker
  opens PRs; a human reviews and merges. There is no auto-merge step.
- **Fail-fast before spend.** `gh preflight` aborts the run early if relay auth
  can't push, instead of burning AI tokens on code that can't be landed.

## Notes

- The relay flags are opt-in: without `--relay-url`/`--run-token`, `bootstrap`
  and `gh preflight` behave exactly as they do for a local/broker run. Passing
  one without the other is a clear error.
- `git config --global` on the worker is safe **because the worker is
  disposable** (a fresh cloud env). Do not run these flags on a machine whose
  real git config you care about.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/skills/test_overnight_cloud_worker_routines.py -v`
Expected: PASS (all three tests).

- [ ] **Step 5: Verify the skill is discoverable**

Run: `uv run mship skill list`
Expected: the output includes `overnight-cloud-worker-routines` (skills auto-list from `src/mship/skills/`).

- [ ] **Step 6: Commit**

```bash
git add src/mship/skills/overnight-cloud-worker-routines/SKILL.md \
        tests/skills/test_overnight_cloud_worker_routines.py
git commit -m "docs(skill): overnight-cloud-worker-routines — the relay-attach worker pattern"
mship journal "added overnight-cloud-worker-routines SKILL.md documenting mint token -> bootstrap --relay -> preflight --relay -> implement -> PR (relay-aware-worker-boot ac6)" --action committed
```
<!-- /mship:task -->

---

## Final verification

- [ ] Run the full suite: `mship test` (or `uv run pytest -q`). Expected: green, including the new relay tests and all pre-existing bootstrap / preflight / egress tests.

---

## Self-Review

### 1. Spec coverage — every AC maps to a task

- **ac1** (`bootstrap --relay-url/--run-token` configures git globally BEFORE cloning — `/gh/`+`/api/` insteadOf + `Mship-Run-Token` extraHeader — then clones with NO token; without flags, unchanged): **Task 3** (core: config-before-clone + no-token path; the "before clone" ordering + no-cred-args are asserted) + **Task 4** (CLI flags). Non-relay unchanged is pinned by re-running the existing bootstrap suite (Task 3 Step 5).
- **ac2** (relay git config emitted from a single shared source, not a hardcoded literal; a test asserts the exact config): **Task 1** (`contract.py` is the single source; egress consumes it — `request.PREFIX_HOST is contract.PREFIX_HOST`, `proxy.RUN_TOKEN_HEADER is contract.RUN_TOKEN_HEADER`) + **Task 2** (exact config strings pinned: the two insteadOf lines + the extraHeader line).
- **ac3** (`gh preflight --relay-url/--run-token` probes `GET <relay>/api/repos/{owner}/{repo}` with the run-token header, STRICT-verifies 200 + `permissions.push`; any failure exits non-zero with a clear message): **Task 5** (core relay branch + unit tests for 200-push/401/403/200-no-push/unreachable) + **Task 6** (CLI, exit codes).
- **ac4** (relay preflight reuses the existing `permissions.push` verification, parameterized to relay base URL + `Mship-Run-Token` — one verification, two transports): **Task 5** (`verify_repos_pushable(base_url, auth_headers, ...)`; `verify_token_covers_repos` becomes its GitHub+bearer wrapper).
- **ac5** (relay is a distinct third mode: `--relay-url`/`--run-token` required together, no fall-through, existing branches unchanged): **Task 2** (`relay_flags_error`) + **Task 5** (relay branch returns first, never falls through — pinned by `test_relay_mode_does_not_fall_through_to_override_token`) + **Task 4/6** (pairing at both CLIs; existing preflight tests re-run unchanged).
- **ac6** (SKILL.md documents mint run-token -> `bootstrap --relay` -> `gh preflight --relay` -> implement -> push+PR; states worker holds only the low-value run token, nothing auto-merges): **Task 7** (skill + doc-lint test asserting the command flow and guarantees).
- **ac7** (tested with no live services — bootstrap asserts exact git config + no token via the shell seam; preflight against a mock relay OK on 200+push and fails on 401/403/missing-push/unreachable; pairing validation): **Task 2** (config strings), **Task 3** (FakeShell seam: config-before-clone, no token env, `resolve_token` never called), **Task 5** (httpx.MockTransport: all failure modes), **Task 4/6** (pairing). No live relay/GitHub/App key anywhere — shell seam, relay probe, and contract source are all injected/mocked.

### 2. Placeholder scan

No `TBD`/`TODO`/"handle edge cases"/"similar to Task N"/"add validation" placeholders. Every code step shows complete, runnable code; every test step shows the full test; every command step gives the exact command + expected result.

### 3. Type / name consistency

- `contract.py` exports used everywhere they appear: `PREFIX_HOST`, `RUN_TOKEN_HEADER`, `API_PREFIX`, `GH_PREFIX` (Tasks 1, 2, 5).
- `worker_config.relay_git_config_commands(relay_url, run_token) -> list[str]` (Task 2) is called in Task 3; `worker_config.relay_flags_error(relay_url, run_token) -> str | None` (Task 2) is called in Tasks 4 and 6 — same names, same signatures.
- `bootstrap(..., relay_url=None, run_token=None)` (Task 3) matches the forwarding call in Task 4 and the fake in Task 4's forwarding test.
- `verify_repos_pushable(*, base_url, auth_headers, repo_owner_names, timeout, client)` (Task 5) is the single verification; `verify_token_covers_repos(*, token, ...)` keeps its existing signature (wrapper) so its existing callers/tests are unchanged.
- `run_preflight(..., relay_url=None, run_token=None, ...)` (Task 5) matches the CLI forwarding in Task 6 and the test kwargs in Task 5.
- Skill dir name `overnight-cloud-worker-routines` matches the SKILL.md `name:` and the test's `pkg_skills_source() / "overnight-cloud-worker-routines"` (Task 7) and the spec's `src/mship/skills/overnight-cloud-worker-routines/SKILL.md`.

---

## Execution Handoff

Plan complete. Two execution options:

1. **Subagent-Driven (recommended)** — a fresh subagent per task via `mship dispatch --task <slug> --plan docs/plans/2026-07-22-relay-aware-worker-boot.md --plan-task <N>`, two-stage review between tasks. Tasks are linear (Task N depends on N-1's symbols), so run them in order.
2. **Inline Execution** — execute in this session with checkpoints (executing-plans).
