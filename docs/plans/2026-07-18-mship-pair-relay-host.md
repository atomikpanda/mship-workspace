# `mship pair`: `--relay-host` + auto-discover the running serve relay — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `mship-pair-relay-host` (approved + dispatched). mothership-only.

**Goal:** Make `mship pair` build the current pairing deep-link + QR when the relay was supplied by a `mship serve --relay-host <host>` flag (no `relay:` block in mothership.yaml) — via an explicit `--relay-host` option and auto-discovery of the running serve's persisted relay host — while preserving today's `relay:`-block behavior exactly.

**Architecture:** Introduce two small pure modules under `src/mship/core/relay/`: `runtime.py` (a per-workspace serve runtime record `write`/`read`/`clear`, a pid-liveness `live_runtime_record` staleness gate, and a pure `resolve_relay` precedence function **flag > config > live record**) and `link.py` (a single `build_relay_pair_link` that derives subdomain + token + URL + `groundcontrol://add?…` link). `pair` and `serve` both call `build_relay_pair_link`, which structurally guarantees the byte-for-byte link/token identity the spec requires (ac3/ac4) — today they duplicate that derivation (`pair.py:44-49` vs `serve.py:234-241`), so this plan **unifies** them. `serve` additionally persists a `relay-runtime.json` record (mode 0600, gitignored under `.mothership/`) while relaying and unlinks it on shutdown, which `pair` reads for auto-discovery.

**Tech Stack:** Python 3.14, Typer, pydantic, pytest (`uv run pytest`), segno (QR), dependency-injector container.

**Worktree (all commands run here):** `/home/bailey/development/repos/mship-workspace/.worktrees/mship-pair-relay-host/mothership`
- `uv run pytest …` runs from the worktree root (cwd = the worktree).
- Commits use `git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-pair-relay-host/mothership`.

**Key facts verified in the real code:**
- `pair.py:34-40` hard-exits "No relay configured" when `config.relay is None`; it has no CLI option. `pair.py:44-49` derives subdomain via `device_subdomain(workspace, device_id(relay_public_key(key_path)), secret)`, builds `url = f"https://{subdomain}.{rc.host}"`, token via `ensure_serve_token(workspace_root)`, link via `build_pair_link(...)`.
- `serve.py:_serve_with_relay` (`serve.py:197-201`) substitutes `RelayConfig(host=relay_host_override, …)` (works even when `config.relay is None`); `serve.py:234-241` duplicates the exact subdomain/url/link derivation; `serve.py:243-246` starts the tunnel; `serve.py:316-318` tears it down in `finally`. **serve persists the relay host nowhere today** — only `.mothership/relay-tunnel.log` + `.mothership/serve-token` are written; the `--relay-host` value lives only in the running process argv. The runtime-record read path does not exist yet — this plan introduces it.
- Token source is shared: both `pair.py:48` and `serve.py:212` call `ensure_serve_token(workspace_root)` → env `MSHIP_SERVE_TOKEN` > `.mothership/serve-token` > freshly generated+persisted (`token.py:5-19`). So ac4 already holds structurally; the missing input for pair is only the host.
- Subdomain secret + relay key are per-machine under `~/.mothership/` (`keys.py`), host-independent, so subdomain is deterministic given host+workspace.
- `_pid_alive` pattern already exists (`inbox_lease.py:37-45`, `os.kill(pid, 0)`); tests inject a fake `pid_alive` (`test_inbox_lease.py:12`). `.mothership/` is already gitignored (`.gitignore`), so the record needs no new ignore entry.
- Test conventions: `tests/cli/test_relay_cli.py` (fixtures `relay_configured_workspace` renaming workspace to "Mship Workspace" + host `relay.example.com` + seeding `.mothership/serve-token`; `workspace_no_relay`), `tests/cli/test_serve.py` (`_configured` + `_serve_with_relay` direct-drive with full stub set at source modules). `Output.error` writes to a stream captured by `CliRunner.output` (existing `test_pair_errors_without_relay` relies on this).

---

## File Structure

| File | Create/Modify | Responsibility |
|------|---------------|----------------|
| `src/mship/core/relay/runtime.py` | Create | `RelayRuntimeRecord` dataclass; `write_runtime_record`/`read_runtime_record`/`clear_runtime_record` (0600 JSON under `.mothership/relay-runtime.json`); `_pid_alive` + `live_runtime_record` staleness gate; `ResolvedRelay` + pure `resolve_relay` precedence (flag > config > record). |
| `src/mship/core/relay/link.py` | Create | `RelayPairLink` dataclass + `build_relay_pair_link(workspace, host, workspace_root, home)` — the ONE shared derivation of subdomain/url/token/link used by both `pair` and `serve`. Calls collaborators via module attributes (`keys.*`, `tunnel.*`, `token.*`, `pairing.*`) so existing serve tests' source-module monkeypatches still intercept. |
| `src/mship/cli/serve.py` | Modify (`_serve_with_relay`, ~176-246, ~312-318) | Replace the duplicated subdomain/url/link block with `build_relay_pair_link`; write the runtime record before `sup.start()` and `clear` it in `finally`. |
| `src/mship/cli/pair.py` | Modify (whole `pair` command) | Add `--relay-host` option; resolve via `live_runtime_record` + `resolve_relay`; build the link via `build_relay_pair_link`; actionable non-zero error naming `--relay-host` + serve when nothing resolves. Preserve today's output shape. |
| `tests/core/relay/test_runtime.py` | Create | Unit tests for record persistence, staleness, and precedence. |
| `tests/core/relay/test_link.py` | Create | Unit tests for `build_relay_pair_link` determinism + token identity. |
| `tests/cli/test_serve.py` | Append | Serve unification (link == shared builder) + record write/clear tests. |
| `tests/cli/test_relay_cli.py` | Append | `pair` CLI: `--relay-host`, precedence, error path, auto-discovery byte-for-byte, stale-ignore, ac8 regression. |

**Serve call-sites to keep green (regression guards — listed in the relevant task Files):**
- `tests/cli/test_relay_cli.py::test_serve_relay_wires_tunnel_and_loopback` (asserts argv + subdomain + public URL + `groundcontrol://add?`).
- `tests/cli/test_serve.py::test_relay_serve_app_serves_exec_with_config_not_503` (drives `_serve_with_relay`, monkeypatches `mship.core.relay.{token,keys,tunnel,pairing,health}` at their source modules).

---

<!-- mship:task id=1 -->
### Task 1: `runtime.py` — the serve runtime record (persist / read / clear)

**Files:**
- Create: `src/mship/core/relay/runtime.py`
- Test: `tests/core/relay/test_runtime.py`

- [ ] **Step 1: Write the failing tests** — create `tests/core/relay/test_runtime.py`:

```python
import json

from mship.core.relay.runtime import (
    RelayRuntimeRecord,
    clear_runtime_record,
    read_runtime_record,
    write_runtime_record,
)


def test_write_then_read_roundtrips(tmp_path):
    rec = RelayRuntimeRecord(
        host="relay.example.com",
        pid=4321,
        subdomain="abc-def",
        url="https://abc-def.relay.example.com",
        workspace="ws",
        ssh_port=2222,
        user="tunnel",
    )
    write_runtime_record(tmp_path, rec)
    assert read_runtime_record(tmp_path) == rec


def test_write_is_mode_0600(tmp_path):
    write_runtime_record(tmp_path, RelayRuntimeRecord(host="h", pid=1))
    path = tmp_path / ".mothership" / "relay-runtime.json"
    assert (path.stat().st_mode & 0o777) == 0o600


def test_written_file_is_json_with_host_and_pid(tmp_path):
    write_runtime_record(tmp_path, RelayRuntimeRecord(host="relay.h", pid=99))
    raw = json.loads((tmp_path / ".mothership" / "relay-runtime.json").read_text())
    assert raw["host"] == "relay.h"
    assert raw["pid"] == 99


def test_read_absent_returns_none(tmp_path):
    assert read_runtime_record(tmp_path) is None


def test_read_corrupt_json_returns_none(tmp_path):
    d = tmp_path / ".mothership"
    d.mkdir()
    (d / "relay-runtime.json").write_text("{not json")
    assert read_runtime_record(tmp_path) is None


def test_read_missing_required_keys_returns_none(tmp_path):
    d = tmp_path / ".mothership"
    d.mkdir()
    (d / "relay-runtime.json").write_text(json.dumps({"host": "h"}))  # no pid
    assert read_runtime_record(tmp_path) is None


def test_clear_removes_record_idempotently(tmp_path):
    write_runtime_record(tmp_path, RelayRuntimeRecord(host="h", pid=1))
    clear_runtime_record(tmp_path)
    assert read_runtime_record(tmp_path) is None
    clear_runtime_record(tmp_path)  # no error when already gone
```

- [ ] **Step 2: Run to verify they fail**

Run: `uv run pytest tests/core/relay/test_runtime.py -q`
Expected: FAIL — `mship.core.relay.runtime` does not exist (ModuleNotFoundError).

- [ ] **Step 3: Implement** — create `src/mship/core/relay/runtime.py`:

```python
"""Per-workspace serve runtime record — how `mship pair` auto-discovers the relay
host of a running `mship serve --relay-host <host>` (spec mship-pair-relay-host).

`mship serve --relay` writes `<workspace>/.mothership/relay-runtime.json` (mode
0600; `.mothership/` is already gitignored) while it is relaying and unlinks it on
shutdown. It carries only the relay host (no secret — the token stays in
`serve-token`) plus liveness/debug fields. `mship pair` reads it, ignores a record
whose pid is dead, and resolves the relay host with a fixed precedence.
"""
from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable

from mship.core.relay.config import RelayConfig

RECORD_NAME = "relay-runtime.json"


@dataclass(frozen=True)
class RelayRuntimeRecord:
    """What a running relay-serve persists so another process (pair) can discover it.

    Only `host` is strictly needed to rebuild the link (pair recomputes subdomain +
    token deterministically); `pid` gates staleness; the rest is for debugging /
    `mship relay whoami`.
    """
    host: str
    pid: int
    subdomain: str | None = None
    url: str | None = None
    workspace: str | None = None
    ssh_port: int = 2222
    user: str | None = None


def _record_path(workspace_root: Path) -> Path:
    return Path(workspace_root) / ".mothership" / RECORD_NAME


def write_runtime_record(workspace_root: Path, record: RelayRuntimeRecord) -> None:
    """Persist `record` as 0600 JSON at `<workspace_root>/.mothership/relay-runtime.json`."""
    path = _record_path(workspace_root)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(asdict(record)))
    path.chmod(0o600)


def read_runtime_record(workspace_root: Path) -> RelayRuntimeRecord | None:
    """Return the persisted record, or None if absent, unreadable, corrupt, or
    missing required keys (never raises — a bad record must never break pair)."""
    path = _record_path(workspace_root)
    try:
        data = json.loads(path.read_text())
    except (FileNotFoundError, ValueError):
        return None
    if not isinstance(data, dict) or "host" not in data or "pid" not in data:
        return None
    try:
        return RelayRuntimeRecord(
            host=data["host"],
            pid=int(data["pid"]),
            subdomain=data.get("subdomain"),
            url=data.get("url"),
            workspace=data.get("workspace"),
            ssh_port=int(data.get("ssh_port", 2222)),
            user=data.get("user"),
        )
    except (TypeError, ValueError):
        return None


def clear_runtime_record(workspace_root: Path) -> None:
    """Remove the record (idempotent — no error when already gone)."""
    _record_path(workspace_root).unlink(missing_ok=True)
```

- [ ] **Step 4: Run to verify they pass**

Run: `uv run pytest tests/core/relay/test_runtime.py -q`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-pair-relay-host/mothership add src/mship/core/relay/runtime.py tests/core/relay/test_runtime.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-pair-relay-host/mothership commit -m "feat(relay): relay-runtime.json record — write/read/clear (0600)" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "runtime.py: RelayRuntimeRecord + write/read/clear, 0600, corrupt-safe" --task mship-pair-relay-host --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: `runtime.py` — pid-liveness staleness gate (`live_runtime_record`)

**Files:**
- Modify: `src/mship/core/relay/runtime.py`
- Test: `tests/core/relay/test_runtime.py` (append)

- [ ] **Step 1: Write the failing tests** — append to `tests/core/relay/test_runtime.py`:

```python
def test_live_record_returned_when_pid_alive(tmp_path):
    write_runtime_record(tmp_path, RelayRuntimeRecord(host="h", pid=1234))
    got = live_runtime_record(tmp_path, pid_alive=lambda pid: True)
    assert got is not None and got.host == "h"


def test_stale_record_ignored_when_pid_dead(tmp_path):
    write_runtime_record(tmp_path, RelayRuntimeRecord(host="h", pid=1234))
    assert live_runtime_record(tmp_path, pid_alive=lambda pid: False) is None


def test_live_record_none_when_absent(tmp_path):
    assert live_runtime_record(tmp_path, pid_alive=lambda pid: True) is None


def test_live_record_checks_the_records_pid(tmp_path):
    write_runtime_record(tmp_path, RelayRuntimeRecord(host="h", pid=777))
    seen = {}

    def fake_alive(pid):
        seen["pid"] = pid
        return True

    live_runtime_record(tmp_path, pid_alive=fake_alive)
    assert seen["pid"] == 777


def test_default_pid_alive_true_for_current_process(tmp_path):
    import os

    write_runtime_record(tmp_path, RelayRuntimeRecord(host="h", pid=os.getpid()))
    assert live_runtime_record(tmp_path) is not None  # real _pid_alive on this pid
```

Also add the import to the top of the test file (extend the existing import line):

```python
from mship.core.relay.runtime import (
    RelayRuntimeRecord,
    clear_runtime_record,
    live_runtime_record,
    read_runtime_record,
    write_runtime_record,
)
```

- [ ] **Step 2: Run to verify they fail**

Run: `uv run pytest tests/core/relay/test_runtime.py -q`
Expected: FAIL — `cannot import name 'live_runtime_record'` (ImportError).

- [ ] **Step 3: Implement** — append to `src/mship/core/relay/runtime.py`:

```python
def _pid_alive(pid: int) -> bool:
    """True if a process with `pid` exists (signal 0 probes without killing)."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # exists but owned by another user
    except (OverflowError, ValueError):
        return False  # nonsense pid → treat as not alive
    return True


def live_runtime_record(
    workspace_root: Path,
    *,
    pid_alive: Callable[[int], bool] | None = None,
) -> RelayRuntimeRecord | None:
    """The runtime record ONLY when present AND its pid is alive; else None.

    A stale record (serve stopped / crashed / pid reused-away) is treated as absent
    so pair never derives a link from a dead serve. `pid_alive` is injectable for
    tests; the CLI leaves it None → module-level `_pid_alive` (so a test can also
    monkeypatch `mship.core.relay.runtime._pid_alive`).
    """
    record = read_runtime_record(workspace_root)
    if record is None:
        return None
    alive = (pid_alive or _pid_alive)(record.pid)
    return record if alive else None
```

- [ ] **Step 4: Run to verify they pass**

Run: `uv run pytest tests/core/relay/test_runtime.py -q`
Expected: PASS (12 tests total).

- [ ] **Step 5: Commit**

```bash
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-pair-relay-host/mothership add src/mship/core/relay/runtime.py tests/core/relay/test_runtime.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-pair-relay-host/mothership commit -m "feat(relay): live_runtime_record — ignore stale (dead-pid) records" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "runtime.py: live_runtime_record pid-liveness gate (ac7 staleness)" --task mship-pair-relay-host --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: `runtime.py` — pure precedence resolver (`resolve_relay`, flag > config > record)

**Files:**
- Modify: `src/mship/core/relay/runtime.py`
- Test: `tests/core/relay/test_runtime.py` (append)

- [ ] **Step 1: Write the failing tests** — append to `tests/core/relay/test_runtime.py`:

```python
def test_resolve_flag_only():
    from mship.core.relay.runtime import ResolvedRelay, resolve_relay

    r = resolve_relay(flag_host="flag.host", config_relay=None, record=None)
    assert r == ResolvedRelay(host="flag.host", ssh_port=2222, user=None, source="flag")


def test_resolve_config_only():
    from mship.core.relay.config import RelayConfig
    from mship.core.relay.runtime import ResolvedRelay, resolve_relay

    cfg = RelayConfig(host="cfg.host", ssh_port=2200, user="tunnel")
    r = resolve_relay(flag_host=None, config_relay=cfg, record=None)
    assert r == ResolvedRelay(host="cfg.host", ssh_port=2200, user="tunnel", source="config")


def test_resolve_record_only():
    from mship.core.relay.runtime import ResolvedRelay, resolve_relay

    rec = RelayRuntimeRecord(host="rec.host", pid=1, ssh_port=2019, user="u")
    r = resolve_relay(flag_host=None, config_relay=None, record=rec)
    assert r == ResolvedRelay(host="rec.host", ssh_port=2019, user="u", source="record")


def test_resolve_flag_beats_config_and_record():
    from mship.core.relay.config import RelayConfig
    from mship.core.relay.runtime import resolve_relay

    cfg = RelayConfig(host="cfg.host", ssh_port=2200, user="cu")
    rec = RelayRuntimeRecord(host="rec.host", pid=1)
    r = resolve_relay(flag_host="flag.host", config_relay=cfg, record=rec)
    assert r.host == "flag.host" and r.source == "flag"
    # Flag inherits ssh_port/user from config when present (mirrors _serve_with_relay
    # RelayConfig substitution at serve.py:197-201).
    assert r.ssh_port == 2200 and r.user == "cu"


def test_resolve_flag_without_config_uses_default_ssh_port():
    from mship.core.relay.runtime import ResolvedRelay, resolve_relay

    rec = RelayRuntimeRecord(host="rec.host", pid=1)
    r = resolve_relay(flag_host="flag.host", config_relay=None, record=rec)
    assert r == ResolvedRelay(host="flag.host", ssh_port=2222, user=None, source="flag")


def test_resolve_config_beats_record():
    from mship.core.relay.config import RelayConfig
    from mship.core.relay.runtime import resolve_relay

    cfg = RelayConfig(host="cfg.host")
    rec = RelayRuntimeRecord(host="rec.host", pid=1)
    r = resolve_relay(flag_host=None, config_relay=cfg, record=rec)
    assert r.host == "cfg.host" and r.source == "config"


def test_resolve_nothing_returns_none():
    from mship.core.relay.runtime import resolve_relay

    assert resolve_relay(flag_host=None, config_relay=None, record=None) is None
```

- [ ] **Step 2: Run to verify they fail**

Run: `uv run pytest tests/core/relay/test_runtime.py -q`
Expected: FAIL — `cannot import name 'ResolvedRelay'` / `'resolve_relay'` (ImportError).

- [ ] **Step 3: Implement** — append to `src/mship/core/relay/runtime.py`:

```python
@dataclass(frozen=True)
class ResolvedRelay:
    host: str
    ssh_port: int
    user: str | None
    source: str  # "flag" | "config" | "record"


def resolve_relay(
    *,
    flag_host: str | None,
    config_relay: RelayConfig | None,
    record: RelayRuntimeRecord | None,
) -> ResolvedRelay | None:
    """Resolve the relay host with fixed precedence: flag > config > live record.

    `record` should already be liveness-filtered (see `live_runtime_record`) — this
    function is pure precedence. Returns None when nothing resolves (caller emits an
    actionable error). An explicit `flag_host` overrides host but inherits
    ssh_port/user from `config_relay` when present, mirroring the RelayConfig
    substitution in `_serve_with_relay` (serve.py:197-201).
    """
    if flag_host:
        if config_relay is not None:
            return ResolvedRelay(
                host=flag_host,
                ssh_port=config_relay.ssh_port,
                user=config_relay.user,
                source="flag",
            )
        return ResolvedRelay(host=flag_host, ssh_port=2222, user=None, source="flag")
    if config_relay is not None:
        return ResolvedRelay(
            host=config_relay.host,
            ssh_port=config_relay.ssh_port,
            user=config_relay.user,
            source="config",
        )
    if record is not None:
        return ResolvedRelay(
            host=record.host, ssh_port=record.ssh_port, user=record.user, source="record"
        )
    return None
```

- [ ] **Step 4: Run to verify they pass**

Run: `uv run pytest tests/core/relay/test_runtime.py -q`
Expected: PASS (19 tests total).

- [ ] **Step 5: Commit**

```bash
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-pair-relay-host/mothership add src/mship/core/relay/runtime.py tests/core/relay/test_runtime.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-pair-relay-host/mothership commit -m "feat(relay): resolve_relay — flag > config > live-record precedence" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "runtime.py: resolve_relay precedence (ac6), pure + table-tested" --task mship-pair-relay-host --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: `link.py` — the single shared relay pair-link builder

Unifies the derivation duplicated at `pair.py:44-49` and `serve.py:234-241`. This is the structural guarantee behind ac3 (byte-for-byte link) and ac4 (token identity).

**Files:**
- Create: `src/mship/core/relay/link.py`
- Test: `tests/core/relay/test_link.py`

- [ ] **Step 1: Write the failing tests** — create `tests/core/relay/test_link.py`:

```python
from pathlib import Path

from mship.core.relay.keys import ensure_subdomain_secret, relay_public_key
from mship.core.relay.link import RelayPairLink, build_relay_pair_link
from mship.core.relay.pairing import build_pair_link, parse_pair_link
from mship.core.relay.token import ensure_serve_token
from mship.core.relay.tunnel import device_id, device_subdomain


def _fake_home_with_key(tmp_path):
    home = tmp_path / "home"
    (home / ".mothership").mkdir(parents=True)
    key = home / ".mothership" / "relay_ed25519"
    key.write_text("PRIV\n")
    (Path(str(key) + ".pub")).write_text("ssh-ed25519 AAAA mship-relay\n")
    return home


def _ws_root_with_token(tmp_path, token="tok-123"):
    ws_root = tmp_path / "ws"
    (ws_root / ".mothership").mkdir(parents=True)
    (ws_root / ".mothership" / "serve-token").write_text(token + "\n")
    return ws_root


def test_build_relay_pair_link_matches_manual_derivation(tmp_path):
    home = _fake_home_with_key(tmp_path)
    ws_root = _ws_root_with_token(tmp_path)

    result = build_relay_pair_link(
        workspace="My WS", host="relay.example.com", workspace_root=ws_root, home=home
    )

    key_path = home / ".mothership" / "relay_ed25519"
    secret = ensure_subdomain_secret(home=home)
    expected_sub = device_subdomain("My WS", device_id(relay_public_key(key_path)), secret)

    assert isinstance(result, RelayPairLink)
    assert result.host == "relay.example.com"
    assert result.subdomain == expected_sub
    assert result.url == f"https://{expected_sub}.relay.example.com"
    assert result.token == "tok-123"
    assert result.link == build_pair_link(url=result.url, token="tok-123", workspace="My WS")
    p = parse_pair_link(result.link)
    assert p == {"url": result.url, "token": "tok-123", "workspace": "My WS"}


def test_token_equals_ensure_serve_token(tmp_path):
    home = _fake_home_with_key(tmp_path)
    ws_root = tmp_path / "ws"
    (ws_root / ".mothership").mkdir(parents=True)  # no seeded token → generated + persisted
    result = build_relay_pair_link(workspace="w", host="h", workspace_root=ws_root, home=home)
    # ac4: same token source as serve, and it persists (re-derives identically).
    assert result.token == ensure_serve_token(ws_root)


def test_two_calls_produce_identical_link_and_token(tmp_path):
    # Simulates the serve path then the pair path with identical inputs (ac3/ac4).
    home = _fake_home_with_key(tmp_path)
    ws_root = _ws_root_with_token(tmp_path)
    serve_side = build_relay_pair_link(
        workspace="w", host="h.example", workspace_root=ws_root, home=home
    )
    pair_side = build_relay_pair_link(
        workspace="w", host="h.example", workspace_root=ws_root, home=home
    )
    assert serve_side.link == pair_side.link
    assert serve_side.token == pair_side.token
    assert serve_side.subdomain == pair_side.subdomain
```

- [ ] **Step 2: Run to verify they fail**

Run: `uv run pytest tests/core/relay/test_link.py -q`
Expected: FAIL — `mship.core.relay.link` does not exist (ModuleNotFoundError).

- [ ] **Step 3: Implement** — create `src/mship/core/relay/link.py`:

```python
"""The single derivation of a relay pairing deep-link, shared by `mship serve
--relay` and `mship pair` so their output is byte-for-byte identical for the same
workspace + relay host (spec mship-pair-relay-host, ac3/ac4).

Collaborators are called via their MODULES (keys.*, tunnel.*, token.*, pairing.*)
rather than `from x import name`, so tests that monkeypatch those functions at
their source modules (e.g. tests/cli/test_serve.py) still intercept them here.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from mship.core.relay import keys, pairing, token, tunnel


@dataclass(frozen=True)
class RelayPairLink:
    host: str
    subdomain: str
    url: str
    token: str
    link: str


def build_relay_pair_link(
    *, workspace: str, host: str, workspace_root: Path, home: Path
) -> RelayPairLink:
    """Derive the opaque per-device subdomain + serve token and build the
    `groundcontrol://add?…` deep-link for `workspace` on relay `host`.

    - subdomain: `device_subdomain(workspace, device_id(pubkey), secret)` from
      `~/.mothership/relay_ed25519(.pub)` + `~/.mothership/relay-subdomain-secret`.
    - token: `ensure_serve_token(workspace_root)` (env > `.mothership/serve-token` >
      generated) — the SAME source `mship serve` uses.
    """
    key_path = keys.ensure_relay_key(home=home)
    secret = keys.ensure_subdomain_secret(home=home)
    dev = tunnel.device_id(keys.relay_public_key(key_path))
    subdomain = tunnel.device_subdomain(workspace, dev, secret)
    url = f"https://{subdomain}.{host}"
    tok = token.ensure_serve_token(workspace_root)
    link = pairing.build_pair_link(url=url, token=tok, workspace=workspace)
    return RelayPairLink(host=host, subdomain=subdomain, url=url, token=tok, link=link)
```

- [ ] **Step 4: Run to verify they pass**

Run: `uv run pytest tests/core/relay/test_link.py -q`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-pair-relay-host/mothership add src/mship/core/relay/link.py tests/core/relay/test_link.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-pair-relay-host/mothership commit -m "feat(relay): build_relay_pair_link — one shared subdomain/token/link builder" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "link.py: build_relay_pair_link shared by serve+pair (ac3/ac4 identity)" --task mship-pair-relay-host --action committed
```
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: Unify serve on `build_relay_pair_link` (byte-for-byte via both paths)

Refactor `_serve_with_relay` so serve's printed link IS `build_relay_pair_link(...).link` — the same function pair will call. This is the "both paths" leg of ac3.

**Files:**
- Modify: `src/mship/cli/serve.py` (imports ~176-192; derivation ~234-241)
- Test: `tests/cli/test_relay_cli.py` (append)
- Regression guards (must stay green): `tests/cli/test_relay_cli.py::test_serve_relay_wires_tunnel_and_loopback`, `tests/cli/test_serve.py::test_relay_serve_app_serves_exec_with_config_not_503`

- [ ] **Step 1: Write the failing test** — append to `tests/cli/test_relay_cli.py`:

```python
def test_serve_relay_prints_shared_builder_link(relay_configured_workspace, tmp_path, monkeypatch):
    """ac3 (serve leg): `serve --relay` prints EXACTLY build_relay_pair_link(...).link,
    so the serve and pair paths are the same builder — byte-for-byte identical."""
    from mship.core.relay.link import build_relay_pair_link

    fake_home = tmp_path / "home"
    (fake_home / ".mothership").mkdir(parents=True)
    key = fake_home / ".mothership" / "relay_ed25519"
    key.write_text("PRIV\n")
    (Path(str(key) + ".pub")).write_text("ssh-ed25519 AAAA mship-relay\n")
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: fake_home))

    workspace_root = relay_configured_workspace  # config parent; seeds serve-token
    expected = build_relay_pair_link(
        workspace="Mship Workspace",
        host="relay.example.com",
        workspace_root=workspace_root,
        home=fake_home,
    )

    fake_sup = MagicMock()
    with patch("uvicorn.run", lambda *a, **k: None), \
         patch("mship.core.relay.tunnel.TunnelSupervisor", lambda *a, **k: fake_sup):
        r = runner.invoke(
            app,
            ["serve", "--relay", "--port", "47100", "--relay-tick", "0.01"],
            catch_exceptions=False,
        )

    assert r.exit_code == 0, r.output
    assert expected.link in r.output
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest "tests/cli/test_relay_cli.py::test_serve_relay_prints_shared_builder_link" -v`
Expected: FAIL — serve still builds the link inline; the assertion may pass by luck only if derivations match, so guard by first confirming the test is red before the refactor. If it already passes (identical derivation), still complete Step 3 to route serve through the shared builder (removes the duplication), then re-run.

- [ ] **Step 3: Refactor `src/mship/cli/serve.py`**

Replace the import block in `_serve_with_relay` (currently `serve.py:176-192`):

```python
    from mship.core.relay.config import RelayConfig
    from mship.core.relay.health import wait_until_reachable
    from mship.core.relay.keys import (
        ensure_relay_key,
        ensure_subdomain_secret,
        relay_public_key,
    )
    from mship.core.relay.pairing import build_pair_link
    from mship.core.relay.token import ensure_serve_token
    from mship.core.relay.tunnel import (
        TunnelSupervisor,
        build_tunnel_argv,
        device_id,
        device_subdomain,
    )
    from mship.core.serve import create_app
    from mship.core.spec_store import SPECS_DIRNAME
```

with:

```python
    from mship.core.relay.config import RelayConfig
    from mship.core.relay.health import wait_until_reachable
    from mship.core.relay.keys import ensure_relay_key
    from mship.core.relay.link import build_relay_pair_link
    from mship.core.relay.token import ensure_serve_token
    from mship.core.relay.tunnel import TunnelSupervisor, build_tunnel_argv
    from mship.core.serve import create_app
    from mship.core.spec_store import SPECS_DIRNAME
```

Then replace the derivation block (currently `serve.py:234-241`):

```python
    key_path = ensure_relay_key(home=Path.home())
    dev = device_id(relay_public_key(key_path))
    secret = ensure_subdomain_secret(home=Path.home())
    subdomain = device_subdomain(workspace, dev, secret)  # opaque; was: subdomain_for(workspace)
    argv = build_tunnel_argv(rc, subdomain=subdomain, local_port=port, key_path=key_path)

    public_url = f"https://{subdomain}.{rc.host}"
    link = build_pair_link(url=public_url, token=token, workspace=workspace)
```

with:

```python
    key_path = ensure_relay_key(home=Path.home())
    pair_link = build_relay_pair_link(
        workspace=workspace,
        host=rc.host,
        workspace_root=workspace_root,
        home=Path.home(),
    )
    subdomain = pair_link.subdomain
    argv = build_tunnel_argv(rc, subdomain=subdomain, local_port=port, key_path=key_path)

    public_url = pair_link.url
    link = pair_link.link
```

Note: `token = ensure_serve_token(workspace_root)` at `serve.py:212` is unchanged (still needed for `create_app` auth); `build_relay_pair_link` re-derives the identical token (idempotent), so `pair_link.token == token`.

- [ ] **Step 4: Run to verify the new test + both regression guards pass**

Run: `uv run pytest "tests/cli/test_relay_cli.py::test_serve_relay_prints_shared_builder_link" "tests/cli/test_relay_cli.py::test_serve_relay_wires_tunnel_and_loopback" "tests/cli/test_serve.py::test_relay_serve_app_serves_exec_with_config_not_503" -v`
Expected: PASS (3 tests). The source-module monkeypatches in the `_503` test still intercept because `build_relay_pair_link` calls `keys.*`/`tunnel.*`/`pairing.*`/`token.*` via module attributes.

- [ ] **Step 5: Commit**

```bash
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-pair-relay-host/mothership add src/mship/cli/serve.py tests/cli/test_relay_cli.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-pair-relay-host/mothership commit -m "refactor(serve): build the relay pair link via build_relay_pair_link" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "serve: route relay link through shared builder (ac3 serve leg)" --task mship-pair-relay-host --action committed
```
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: serve persists + clears the runtime record (the auto-discovery producer)

**Files:**
- Modify: `src/mship/cli/serve.py` (`_serve_with_relay`: function-top `import`; imports block; `~243-246`; `finally` at `~316-318`)
- Test: `tests/cli/test_serve.py` (append)
- Regression guard: `tests/cli/test_serve.py::test_relay_serve_app_serves_exec_with_config_not_503` (already creates `tmp_path/.mothership`, so the new write succeeds)

- [ ] **Step 1: Write the failing test** — append to `tests/cli/test_serve.py`:

```python
def test_serve_relay_writes_and_clears_runtime_record(tmp_path, monkeypatch):
    """ac2 producer / ac7 clean-shutdown: `_serve_with_relay` writes
    .mothership/relay-runtime.json (host + own pid) before serving and unlinks it
    in the finally teardown."""
    import os

    from mship.cli.output import Output
    from mship.cli.serve import _serve_with_relay
    from mship.core.config import RepoConfig, WorkspaceConfig
    from mship.core.relay.runtime import read_runtime_record
    from mship.core.state import StateManager

    monkeypatch.setenv("MSHIP_PR_WATCH_INTERVAL", "0")

    repo_dir = tmp_path / "api"
    repo_dir.mkdir()
    (tmp_path / ".mothership").mkdir()
    config = WorkspaceConfig(
        workspace="t",
        repos={"api": RepoConfig(path=repo_dir, type="service", tasks={"run": "start"})},
    )

    class _FakeContainer:
        def __init__(self, state_dir):
            self._sm = StateManager(state_dir)

        def state_manager(self):
            return self._sm

        def log_manager(self):
            return None

        def worktree_manager(self):
            return None

    class _FakeSup:
        restart_count = 0

        def __init__(self, *a, **k):
            pass

        def start(self):
            pass

        def stop(self):
            pass

        def tick(self):
            pass

        def recent_output(self):
            return ""

    monkeypatch.setattr("mship.core.relay.token.ensure_serve_token", lambda root: "tok")
    monkeypatch.setattr("mship.core.relay.keys.ensure_relay_key", lambda home=None: tmp_path / "key")
    monkeypatch.setattr("mship.core.relay.keys.ensure_subdomain_secret", lambda home=None: b"\x00" * 32)
    monkeypatch.setattr("mship.core.relay.keys.relay_public_key", lambda key_path: "ssh-ed25519 AAAAfake")
    monkeypatch.setattr("mship.core.relay.tunnel.device_id", lambda pub: "dev")
    monkeypatch.setattr("mship.core.relay.tunnel.device_subdomain", lambda ws, dev, secret: "sub")
    monkeypatch.setattr("mship.core.relay.tunnel.build_tunnel_argv", lambda *a, **k: ["true"])
    monkeypatch.setattr("mship.core.relay.tunnel.TunnelSupervisor", _FakeSup)
    monkeypatch.setattr("mship.core.relay.health.wait_until_reachable", lambda *a, **k: (True, ""))

    seen: dict = {}

    def _capture_run(api, **kw):
        seen["during"] = read_runtime_record(tmp_path)  # record must exist WHILE serving

    monkeypatch.setattr("uvicorn.run", _capture_run)

    _serve_with_relay(
        container=_FakeContainer(tmp_path / ".mothership"),
        config=config,
        workspace_root=tmp_path,
        output=Output(),
        relay_host_override="relay.example.test",
        port=47199,
        relay_tick=0.01,
    )

    during = seen["during"]
    assert during is not None
    assert during.host == "relay.example.test"
    assert during.pid == os.getpid()
    # ac7 clean-shutdown side: record unlinked in the finally teardown.
    assert read_runtime_record(tmp_path) is None
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest "tests/cli/test_serve.py::test_serve_relay_writes_and_clears_runtime_record" -v`
Expected: FAIL — `seen["during"]` is None (no record written yet).

- [ ] **Step 3: Implement in `src/mship/cli/serve.py`**

Add `import os` at the top of `_serve_with_relay` (it currently opens with `import threading`):

```python
    import os
    import threading
```

Extend the imports block edited in Task 5 to also pull in the runtime helpers:

```python
    from mship.core.relay.link import build_relay_pair_link
    from mship.core.relay.runtime import (
        RelayRuntimeRecord,
        clear_runtime_record,
        write_runtime_record,
    )
```

Write the record just before `sup.start()` (currently `serve.py:243-246`). Replace:

```python
    log_path = workspace_root / ".mothership" / "relay-tunnel.log"
    log_path.unlink(missing_ok=True)                      # fresh per run
    sup = TunnelSupervisor(argv=argv, log_path=log_path)
    sup.start()
```

with:

```python
    log_path = workspace_root / ".mothership" / "relay-tunnel.log"
    log_path.unlink(missing_ok=True)                      # fresh per run
    # Persist the effective relay host so `mship pair` in this workspace can
    # auto-discover it (spec mship-pair-relay-host). Gitignored, mode 0600, no
    # secret (the token stays in serve-token). Unlinked in the finally teardown.
    write_runtime_record(
        workspace_root,
        RelayRuntimeRecord(
            host=rc.host,
            pid=os.getpid(),
            subdomain=subdomain,
            url=public_url,
            workspace=workspace,
            ssh_port=rc.ssh_port,
            user=rc.user,
        ),
    )
    sup = TunnelSupervisor(argv=argv, log_path=log_path)
    sup.start()
```

Clear the record on shutdown. Replace the `finally` (currently `serve.py:316-318`):

```python
    finally:
        stop_event.set()
        sup.stop()
```

with:

```python
    finally:
        stop_event.set()
        sup.stop()
        clear_runtime_record(workspace_root)
```

- [ ] **Step 4: Run to verify it passes (and the exec-config guard still passes)**

Run: `uv run pytest "tests/cli/test_serve.py::test_serve_relay_writes_and_clears_runtime_record" "tests/cli/test_serve.py::test_relay_serve_app_serves_exec_with_config_not_503" -v`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-pair-relay-host/mothership add src/mship/cli/serve.py tests/cli/test_serve.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-pair-relay-host/mothership commit -m "feat(serve): persist relay-runtime.json while relaying; clear on shutdown" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "serve: write/clear relay-runtime.json (ac2 producer, ac7 clean shutdown)" --task mship-pair-relay-host --action committed
```
<!-- /mship:task -->

<!-- mship:task id=7 -->
### Task 7: `pair` CLI — `--relay-host` option, resolver wiring, actionable error

Rewrites the whole `pair` command. Covers ac1 (flag, no block), ac5 (error names `--relay-host` + serve), ac6 (flag precedence), and preserves ac8 output.

**Files:**
- Modify: `src/mship/cli/pair.py` (whole `pair` command, `pair.py:14-57`)
- Test: `tests/cli/test_relay_cli.py` (append)
- Regression guards (must stay green): `tests/cli/test_relay_cli.py::{test_pair_outputs_deeplink, test_pair_url_uses_subdomain_and_relay_host, test_pair_errors_without_relay}`

- [ ] **Step 1: Write the failing tests** — append to `tests/cli/test_relay_cli.py`:

```python
def test_pair_with_relay_host_flag_no_block(workspace_no_relay, tmp_path, monkeypatch):
    """ac1: --relay-host prints a valid link with NO relay: block (no 'No relay
    configured' exit)."""
    fake_home = tmp_path / "home"
    (fake_home / ".mothership").mkdir(parents=True)
    key = fake_home / ".mothership" / "relay_ed25519"
    key.write_text("PRIV\n")
    (Path(str(key) + ".pub")).write_text("ssh-ed25519 AAAA mship-relay\n")
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: fake_home))
    (workspace_no_relay / ".mothership" / "serve-token").write_text("flag-token\n")

    r = runner.invoke(app, ["pair", "--relay-host", "flag.relay.com"])
    assert r.exit_code == 0, r.output
    assert "groundcontrol://add?" in r.output
    assert "flag.relay.com" in r.output
    assert "flag-token" in r.output


def test_pair_flag_overrides_config_and_record(relay_configured_workspace, tmp_path, monkeypatch):
    """ac6: --relay-host wins over config.relay.host AND a live runtime record."""
    import os

    from mship.core.relay.runtime import RelayRuntimeRecord, write_runtime_record

    fake_home = tmp_path / "home"
    (fake_home / ".mothership").mkdir(parents=True)
    key = fake_home / ".mothership" / "relay_ed25519"
    key.write_text("PRIV\n")
    (Path(str(key) + ".pub")).write_text("ssh-ed25519 AAAA mship-relay\n")
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: fake_home))

    write_runtime_record(
        relay_configured_workspace,
        RelayRuntimeRecord(host="record.relay.com", pid=os.getpid()),
    )

    r = runner.invoke(app, ["pair", "--relay-host", "flag.relay.com"])
    assert r.exit_code == 0, r.output
    assert "flag.relay.com" in r.output
    assert "relay.example.com" not in r.output   # config host lost
    assert "record.relay.com" not in r.output    # record host lost


def test_pair_no_relay_error_names_flag_and_serve(workspace_no_relay):
    """ac5: nothing resolves → non-zero + actionable message naming --relay-host +
    serve; never a partial/empty link."""
    r = runner.invoke(app, ["pair"])
    assert r.exit_code != 0
    assert "--relay-host" in r.output
    assert "serve" in r.output.lower()
    assert "groundcontrol://add" not in r.output
```

- [ ] **Step 2: Run to verify they fail**

Run: `uv run pytest "tests/cli/test_relay_cli.py::test_pair_with_relay_host_flag_no_block" "tests/cli/test_relay_cli.py::test_pair_flag_overrides_config_and_record" "tests/cli/test_relay_cli.py::test_pair_no_relay_error_names_flag_and_serve" -v`
Expected: FAIL — `pair` has no `--relay-host` option (Typer usage error / exit 2) and the old error message names neither `--relay-host` nor serve.

- [ ] **Step 3: Rewrite `src/mship/cli/pair.py`**

Replace the entire file with:

```python
"""`mship pair` — print a scannable pairing deep-link + QR for the Ground Control app.

Resolves the workspace's relay host with a fixed precedence — an explicit
`--relay-host` flag > a `relay:` block in mothership.yaml > the runtime record of a
live `mship serve --relay-host <host>` in this workspace — then builds the SAME
`groundcontrol://add?…` deep-link the serve prints (via `build_relay_pair_link`) and
renders a terminal QR. Exits non-zero with an actionable message when nothing
resolves. See spec mship-pair-relay-host.
"""
from __future__ import annotations

from typing import Optional

import typer

from mship.cli.output import Output


def register(app: typer.Typer, get_container):
    @app.command(rich_help_panel="Messaging")
    def pair(
        relay_host: Optional[str] = typer.Option(
            None,
            "--relay-host",
            metavar="HOST",
            show_default=False,
            help="Relay host for the pairing link. Overrides config.relay.host and "
                 "any running-serve record (precedence: flag > config > live serve).",
        ),
    ):
        """Print a pairing deep-link + QR to connect the Ground Control app to this workspace."""
        from pathlib import Path

        import segno

        from mship.core.relay.link import build_relay_pair_link
        from mship.core.relay.runtime import live_runtime_record, resolve_relay

        output = Output()
        container = get_container()
        config = container.config()
        workspace = config.workspace
        workspace_root = Path(container.config_path()).parent

        record = live_runtime_record(workspace_root)  # None if absent or pid dead (stale)
        resolved = resolve_relay(
            flag_host=relay_host,
            config_relay=config.relay,
            record=record,
        )
        if resolved is None:
            output.error(
                "No relay to pair with. Pass `mship pair --relay-host <host>`, add a "
                "`relay:` block (host) to mothership.yaml, or start "
                "`mship serve --relay-host <host>` in this workspace first. "
                "See docs/relay-hosting.md."
            )
            raise typer.Exit(1)

        result = build_relay_pair_link(
            workspace=workspace,
            host=resolved.host,
            workspace_root=workspace_root,
            home=Path.home(),
        )

        output.print(result.link)
        output.print(
            "  (opaque subdomain — no workspace name leaked; if you upgraded mship, "
            "this changed, so re-scan to re-pair. Decode with `mship relay whoami <sub>`.)"
        )
        typer.echo(segno.make(result.link).terminal(compact=True))
```

- [ ] **Step 4: Run to verify the new + existing pair tests pass**

Run: `uv run pytest "tests/cli/test_relay_cli.py" -k pair -v`
Expected: PASS — the 3 new tests plus the existing `test_pair_outputs_deeplink`, `test_pair_url_uses_subdomain_and_relay_host`, `test_pair_errors_without_relay` (its `"relay" in output` assertion still holds — the new message contains "relay").

- [ ] **Step 5: Commit**

```bash
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-pair-relay-host/mothership add src/mship/cli/pair.py tests/cli/test_relay_cli.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-pair-relay-host/mothership commit -m "feat(pair): --relay-host + precedence resolver + actionable no-relay error" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "pair: --relay-host option, resolve_relay wiring, ac5 error (ac1/ac5/ac6)" --task mship-pair-relay-host --action committed
```
<!-- /mship:task -->

<!-- mship:task id=8 -->
### Task 8: `pair` auto-discovers the live serve record — byte-for-byte parity (ac2/ac3/ac4)

The headline identity test: builds the link via the serve path (`build_relay_pair_link`, which Task 5 proved is what serve prints) and the pair path (the CLI), and asserts equality + token identity.

**Files:**
- Test: `tests/cli/test_relay_cli.py` (append)
- (No source change — exercises Tasks 6 + 7 together.)

- [ ] **Step 1: Write the failing test** — append to `tests/cli/test_relay_cli.py`:

```python
def test_pair_autodiscovers_live_serve_record_byte_for_byte(workspace_no_relay, tmp_path, monkeypatch):
    """ac2/ac3/ac4: bare `mship pair` with NO relay: block discovers the live serve
    record's host and prints the SAME link the serve builder produces, same token."""
    import os

    from mship.core.relay.link import build_relay_pair_link
    from mship.core.relay.pairing import parse_pair_link
    from mship.core.relay.runtime import RelayRuntimeRecord, write_runtime_record
    from mship.core.relay.token import ensure_serve_token

    fake_home = tmp_path / "home"
    (fake_home / ".mothership").mkdir(parents=True)
    key = fake_home / ".mothership" / "relay_ed25519"
    key.write_text("PRIV\n")
    (Path(str(key) + ".pub")).write_text("ssh-ed25519 AAAA mship-relay\n")
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: fake_home))

    ws = workspace_no_relay
    (ws / ".mothership" / "serve-token").write_text("shared-serve-token\n")

    # The serve path: exactly what a running serve builds + prints (Task 5).
    serve_side = build_relay_pair_link(
        workspace="test-platform",
        host="mship-relay.atomikpanda.com",
        workspace_root=ws,
        home=fake_home,
    )

    # Simulate the running serve having persisted its runtime record (pid alive).
    write_runtime_record(
        ws, RelayRuntimeRecord(host="mship-relay.atomikpanda.com", pid=os.getpid())
    )

    # The pair path: no flag, no relay: block → auto-discovery.
    r = runner.invoke(app, ["pair"])
    assert r.exit_code == 0, r.output

    # ac3: byte-for-byte identical link.
    assert serve_side.link in r.output
    # ac4: token equals ensure_serve_token (the serve's token source).
    assert serve_side.token == ensure_serve_token(ws) == "shared-serve-token"

    p = parse_pair_link(serve_side.link)
    assert p["url"] == serve_side.url
    assert p["token"] == "shared-serve-token"
    assert p["workspace"] == "test-platform"
```

- [ ] **Step 2: Run to verify it fails, then passes**

Run: `uv run pytest "tests/cli/test_relay_cli.py::test_pair_autodiscovers_live_serve_record_byte_for_byte" -v`
Expected: PASS once Tasks 6 + 7 are in place (this task adds only the test). If it FAILS, the failure pinpoints the auto-discovery/identity gap — fix in `pair.py`/`runtime.py`, not the test.

- [ ] **Step 3: (No implementation — assert-only over Tasks 6+7.)**

- [ ] **Step 4: Re-run to confirm green**

Run: `uv run pytest "tests/cli/test_relay_cli.py::test_pair_autodiscovers_live_serve_record_byte_for_byte" -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-pair-relay-host/mothership add tests/cli/test_relay_cli.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-pair-relay-host/mothership commit -m "test(pair): auto-discover live serve record — byte-for-byte link + token parity" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "pair: byte-for-byte parity test vs serve builder (ac2/ac3/ac4)" --task mship-pair-relay-host --action committed
```
<!-- /mship:task -->

<!-- mship:task id=9 -->
### Task 9: `pair` ignores a stale (dead-pid) runtime record (ac7)

**Files:**
- Test: `tests/cli/test_relay_cli.py` (append)
- (No source change — exercises `live_runtime_record` staleness through the CLI.)

- [ ] **Step 1: Write the failing test** — append to `tests/cli/test_relay_cli.py`:

```python
def test_pair_ignores_stale_record(workspace_no_relay, monkeypatch):
    """ac7: a record whose pid is dead is ignored — pair does NOT print a link
    derived from it and falls through to the clear error (no relay: block, no flag)."""
    from mship.core.relay.runtime import RelayRuntimeRecord, write_runtime_record

    write_runtime_record(
        workspace_no_relay, RelayRuntimeRecord(host="dead.relay.com", pid=424242)
    )
    # Force the record's pid to read as dead, deterministically.
    monkeypatch.setattr("mship.core.relay.runtime._pid_alive", lambda pid: False)

    r = runner.invoke(app, ["pair"])
    assert r.exit_code != 0
    assert "dead.relay.com" not in r.output          # never a stale link
    assert "groundcontrol://add" not in r.output
    assert "--relay-host" in r.output                # actionable fallback message
```

- [ ] **Step 2: Run to verify it passes (assert-only over Tasks 2+7)**

Run: `uv run pytest "tests/cli/test_relay_cli.py::test_pair_ignores_stale_record" -v`
Expected: PASS — `live_runtime_record` filters the dead-pid record to None, so `resolve_relay` returns None and pair emits the ac5 error. If it FAILS, the gap is in `pair.py` calling `live_runtime_record` (not `read_runtime_record`) — fix there.

- [ ] **Step 3: (No implementation.)**

- [ ] **Step 4: Re-run to confirm green**

Run: `uv run pytest "tests/cli/test_relay_cli.py::test_pair_ignores_stale_record" -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-pair-relay-host/mothership add tests/cli/test_relay_cli.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-pair-relay-host/mothership commit -m "test(pair): stale dead-pid record is ignored, falls back to clear error" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "pair: stale-record CLI test (ac7)" --task mship-pair-relay-host --action committed
```
<!-- /mship:task -->

<!-- mship:task id=10 -->
### Task 10: ac8 regression — `relay:` block + no flag behaves exactly as today

**Files:**
- Test: `tests/cli/test_relay_cli.py` (append)
- (No source change — proves config precedence unchanged and the live record is ignored when a block is present.)

- [ ] **Step 1: Write the failing test** — append to `tests/cli/test_relay_cli.py`:

```python
def test_pair_relay_block_unchanged_ignores_record(relay_configured_workspace, tmp_path, monkeypatch):
    """ac8: with a relay: block and no flag, `mship pair` behaves exactly as today —
    it uses config.relay.host, prints the same explanatory note, and ignores any live
    serve record (config > record)."""
    import os

    from mship.core.relay.link import build_relay_pair_link
    from mship.core.relay.runtime import RelayRuntimeRecord, write_runtime_record

    fake_home = tmp_path / "home"
    (fake_home / ".mothership").mkdir(parents=True)
    key = fake_home / ".mothership" / "relay_ed25519"
    key.write_text("PRIV\n")
    (Path(str(key) + ".pub")).write_text("ssh-ed25519 AAAA mship-relay\n")
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: fake_home))

    # A live record with a DIFFERENT host must NOT override the relay: block.
    write_runtime_record(
        relay_configured_workspace,
        RelayRuntimeRecord(host="other.relay.com", pid=os.getpid()),
    )

    expected = build_relay_pair_link(
        workspace="Mship Workspace",
        host="relay.example.com",  # the configured block host
        workspace_root=relay_configured_workspace,
        home=fake_home,
    )

    r = runner.invoke(app, ["pair"])
    assert r.exit_code == 0, r.output
    assert expected.link in r.output            # exactly today's link
    assert "other.relay.com" not in r.output    # record ignored (config wins)
    assert "opaque subdomain" in r.output       # the same explanatory note as today
```

- [ ] **Step 2: Run to verify it passes (assert-only over Task 7)**

Run: `uv run pytest "tests/cli/test_relay_cli.py::test_pair_relay_block_unchanged_ignores_record" -v`
Expected: PASS. If it FAILS on `other.relay.com` appearing, the precedence in `resolve_relay`/`pair.py` is wrong (config must beat record).

- [ ] **Step 3: (No implementation.)**

- [ ] **Step 4: Full-suite regression pass**

Run: `uv run pytest tests/cli/test_relay_cli.py tests/cli/test_serve.py tests/core/relay -q`
Expected: PASS (all relay CLI, serve, and relay-core tests green — including the pre-existing pair/serve tests that guard ac8 and the serve tunnel wiring).

- [ ] **Step 5: Commit**

```bash
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-pair-relay-host/mothership add tests/cli/test_relay_cli.py
git -C /home/bailey/development/repos/mship-workspace/.worktrees/mship-pair-relay-host/mothership commit -m "test(pair): ac8 regression — relay: block unchanged, record ignored" -m "Claude-Session: https://claude.ai/code/session_015ZPGS2VyABiXaBDKz9ts8v"
mship journal "pair: ac8 regression test (relay block behaves as today)" --task mship-pair-relay-host --action committed
```
<!-- /mship:task -->

---

## Self-Review

**1. Spec coverage — AC → task map (all 8):**

| AC | Where implemented | Where proven | Assert-only or needs change |
|----|-------------------|--------------|------------------------------|
| **ac1** (`--relay-host`, no block, no "No relay configured" exit) | Task 7 (`pair.py` option + resolver + `build_relay_pair_link`) | Task 7 `test_pair_with_relay_host_flag_no_block` | **Needs change** (pair had no option; hard-exited at `pair.py:35-40`). |
| **ac2** (bare `pair` auto-discovers running serve's record) | Task 6 (serve writes record) + Task 7 (pair reads via `live_runtime_record`) | Task 8 `test_pair_autodiscovers_live_serve_record_byte_for_byte` | **Needs change** (record read/write path did not exist). |
| **ac3** (link byte-for-byte identical to serve) | Task 4 (`build_relay_pair_link`) + Task 5 (serve routes through it) + Task 7 (pair routes through it) | Task 5 (serve leg) + Task 8 (pair leg, equality) | **Needs change to structurally guarantee** (was duplicated logic that happened to match); derivation itself unchanged. |
| **ac4** (token == serve's `ensure_serve_token`; stable across restart) | Existing shared `ensure_serve_token`, now funneled through `build_relay_pair_link` (Task 4) | Task 4 `test_token_equals_ensure_serve_token` + Task 8 token equality | **Largely assert-only** — token identity already held (`pair.py:48`/`serve.py:212`); persistence (`token.py:5-19`) gives restart stability. Change only ensures pair can resolve the host to print it. |
| **ac5** (no relay → non-zero, names `--relay-host` + serve, never partial) | Task 7 (`output.error` + `Exit(1)` when `resolve_relay` is None) | Task 7 `test_pair_no_relay_error_names_flag_and_serve` | **Needs change** (old message named only `relay:` block). |
| **ac6** (flag > config > record) | Task 3 (`resolve_relay`) + Task 7 (wiring) | Task 3 table tests + Task 7 `test_pair_flag_overrides_config_and_record` | **Needs change.** |
| **ac7** (stale/dead-pid record ignored) | Task 2 (`live_runtime_record`) + Task 6 (`clear` on shutdown) + Task 7 (pair uses `live_runtime_record`) | Task 2 unit + Task 6 clear + Task 9 CLI `test_pair_ignores_stale_record` | **Needs change.** |
| **ac8** (relay: block + no flag unchanged) | Task 7 preserves exact output (link + note + QR); precedence config>record | Task 10 `test_pair_relay_block_unchanged_ignores_record` + pre-existing `test_pair_outputs_deeplink` / `test_pair_url_uses_subdomain_and_relay_host` | **Assert-only** (preserved by construction). |

No spec requirement is left without a task. Non-goals respected: no change to tunnel/enroll, opaque-subdomain scheme, `ensure_serve_token` semantics, the `groundcontrol://add?` shape, or any new serve endpoint (auto-discovery is via the persisted record, the spec's chosen approach).

**2. ac3/ac4 byte-for-byte identity — how it's tested (explicit):** The identity is proven by building the link via BOTH paths and asserting equality. The **serve path** is `build_relay_pair_link(...).link` — Task 5 proves serve's printed output IS that string (`test_serve_relay_prints_shared_builder_link`). The **pair path** is the `mship pair` CLI. Task 8 computes `serve_side = build_relay_pair_link(workspace, host, workspace_root, home)` (the serve path) and asserts `serve_side.link in <pair CLI output>` plus `serve_side.token == ensure_serve_token(ws)` — same URL host, subdomain, and token, byte-for-byte. Because both `serve` (Task 5) and `pair` (Task 7) call the one `build_relay_pair_link`, identity is structural, not coincidental. Task 4's `test_two_calls_produce_identical_link_and_token` additionally pins determinism at the unit level.

**3. Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to Task N". Every code step contains complete, runnable code; every test step contains full test bodies; every command has an expected result. Error handling is concrete (`read_runtime_record` catches `FileNotFoundError`/`ValueError` and validates keys; `_pid_alive` handles `ProcessLookupError`/`PermissionError`/`OverflowError`).

**4. Type/name consistency across tasks:**
- `RelayRuntimeRecord(host, pid, subdomain=None, url=None, workspace=None, ssh_port=2222, user=None)` — same fields used in Tasks 1, 2, 6, 7, 8, 9, 10.
- `ResolvedRelay(host, ssh_port, user, source)` — Tasks 3 and consumed in Task 7.
- `RelayPairLink(host, subdomain, url, token, link)` — created in Task 4; `.link`/`.subdomain`/`.url`/`.token` used in Tasks 5, 7, 8, 10.
- Functions: `write_runtime_record`/`read_runtime_record`/`clear_runtime_record`/`live_runtime_record`/`resolve_relay` (runtime.py); `build_relay_pair_link` (link.py) — names identical everywhere they appear.
- `resolve_relay` and `live_runtime_record` are keyword-only where the plan calls them keyword-style (`flag_host=`, `config_relay=`, `record=`, `pid_alive=`); `build_relay_pair_link` is keyword-only (`workspace=`, `host=`, `workspace_root=`, `home=`) and every call site matches.
- Monkeypatch target `mship.core.relay.runtime._pid_alive` (Task 9) matches the module-level `_pid_alive` defined in Task 2, and `live_runtime_record` looks it up via `(pid_alive or _pid_alive)` so the patch takes effect.

**5. Import-time monkeypatch safety (verified against existing serve tests):** `build_relay_pair_link` calls collaborators via module attributes (`keys.*`, `tunnel.*`, `token.*`, `pairing.*`), so `tests/cli/test_serve.py::test_relay_serve_app_serves_exec_with_config_not_503`, which patches those at their source modules, still intercepts them after the serve refactor. Confirmed `src/mship/core/relay/__init__.py` is empty (no import cycle from `from mship.core.relay import keys, pairing, token, tunnel`).
