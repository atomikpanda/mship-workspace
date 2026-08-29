# Relay: opaque keyed-hash subdomains — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development or executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Spec:** `relay-opaque-subdomains` (approved, dispatched). WorkItem `wi-20260716230513-f9542a05`. Worktree: `.worktrees/relay-opaque-subdomains/mothership`.

**Goal:** Replace the workspace-name portion of the relay subdomain with an opaque keyed hash, so the subdomain no longer leaks the workspace name to the relay host / DNS / network — while the operator can still recover which workspace a subdomain is.

**Architecture:** mothership-only. Add a per-machine secret (co-located with the relay key at `~/.mothership/`) and an `opaque_slug(workspace, secret)` = truncated base32(HMAC-SHA256). `device_subdomain` uses it; its two callers (`serve --relay`, `pair`) load the secret and pass it — they stay in lockstep because the derivation is deterministic. A `mship relay whoami` decode helper recomputes over candidate workspace names. `tls_ask.py`'s cert-allowlist regex already accepts the new shape (base32 a-z2-7 ⊂ [a-z0-9]); only its comment changes.

**Tech Stack:** Python, `hmac`/`hashlib`/`base64`/`os.urandom`, Typer CLI, pytest. Test from the worktree: `mship test --repos mothership --task relay-opaque-subdomains` (or `uv run pytest tests/... -v`).

---

## File Structure

- **Modify** `mothership/src/mship/core/relay/tunnel.py` — add `opaque_slug`; `device_subdomain` gains a `secret` param and uses it.
- **Modify** `mothership/src/mship/core/relay/keys.py` — add `ensure_subdomain_secret(home) -> bytes`.
- **Modify** `mothership/src/mship/cli/serve.py` (~line 232) and `mothership/src/mship/cli/pair.py` (~line 41) — load the secret, pass to `device_subdomain`.
- **Modify** `mothership/src/mship/cli/relay.py` — add `mship relay whoami <subdomain>`.
- **Modify** `mothership/src/mship/core/relay/tls_ask.py` — update the comment (base is now opaque); no regex change needed.
- **Tests:** `tests/core/relay/test_tunnel.py`, `test_keys.py` (or existing), `tests/cli/test_relay.py`, `tests/core/relay/test_tls_ask.py` (extend existing where present).

---

<!-- mship:task id=1 -->
### Task 1: `opaque_slug` + `device_subdomain` (pure)

**Files:** Modify `core/relay/tunnel.py`; Test `tests/core/relay/test_tunnel.py`.

- [ ] **Step 1: Write failing tests**

```python
from mship.core.relay.tunnel import opaque_slug, device_subdomain

SECRET = b"\x00" * 32

def test_opaque_slug_is_deterministic_and_dns_safe():
    s = opaque_slug("My Workspace", SECRET)
    assert s == opaque_slug("My Workspace", SECRET)          # deterministic
    assert 0 < len(s) <= 12
    assert all(c in "abcdefghijklmnopqrstuvwxyz234567" for c in s)  # lowercase base32

def test_opaque_slug_hides_the_name():
    # Reveals nothing about the name; different names -> unrelated slugs.
    assert "workspace" not in opaque_slug("workspace", SECRET)
    assert opaque_slug("alpha", SECRET) != opaque_slug("alphb", SECRET)
    # secret matters: same name, different secret -> different slug
    assert opaque_slug("alpha", SECRET) != opaque_slug("alpha", b"\x01" * 32)

def test_device_subdomain_shape_and_length():
    d = device_subdomain("a-very-long-workspace-name-that-would-overflow", "abc123", SECRET)
    assert d.endswith("-abc123")
    assert len(d) <= 63
    # No trace of the name.
    assert "workspace" not in d
```

- [ ] **Step 2: Run — expect fail** (`uv run pytest tests/core/relay/test_tunnel.py -k "opaque or device_subdomain" -v`).

- [ ] **Step 3: Implement in `tunnel.py`**

```python
import base64
import hmac

def opaque_slug(workspace: str, secret: bytes) -> str:
    """Opaque, DNS-label-safe slug for a workspace: truncated lowercase base32 of
    HMAC-SHA256(secret, workspace). Deterministic (stable subdomain); reveals nothing
    about the name without `secret`."""
    digest = hmac.new(secret, workspace.encode("utf-8"), hashlib.sha256).digest()
    b32 = base64.b32encode(digest).decode("ascii").lower().rstrip("=")
    return b32[:12]

def device_subdomain(workspace: str, dev_id: str, secret: bytes) -> str:
    """Per-device relay subdomain: `<opaque-slug>-<dev_id>`, DNS-label-safe, <= 63 chars.
    The workspace name is no longer present (was `subdomain_for(workspace)`)."""
    suffix = f"-{dev_id}"
    base = opaque_slug(workspace, secret)[: 63 - len(suffix)]
    return f"{base}{suffix}"
```
Keep `subdomain_for` as-is (still a generic slug helper; no longer used by `device_subdomain`). `hashlib` is already imported.

- [ ] **Step 4: Run — expect pass.**

- [ ] **Step 5: Commit** (`git add ...; git commit -m "feat: opaque keyed-hash relay subdomain (opaque_slug)"; mship journal ...`).
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: Per-machine subdomain secret

**Files:** Modify `core/relay/keys.py`; Test `tests/core/relay/test_keys.py` (create if absent).

- [ ] **Step 1: Write failing test**

```python
from mship.core.relay.keys import ensure_subdomain_secret

def test_ensure_subdomain_secret_creates_stable_0600_secret(tmp_path):
    s1 = ensure_subdomain_secret(home=tmp_path)
    assert isinstance(s1, bytes) and len(s1) >= 32
    path = tmp_path / ".mothership" / "relay-subdomain-secret"
    assert oct(path.stat().st_mode & 0o777) == "0o600"
    assert ensure_subdomain_secret(home=tmp_path) == s1   # stable across calls
```

- [ ] **Step 2: Run — expect fail.**

- [ ] **Step 3: Implement in `keys.py`**

```python
import os

def ensure_subdomain_secret(home: Path) -> bytes:
    """Return the per-machine relay-subdomain HMAC secret (home/.mothership/relay-subdomain-secret),
    generating 32 random bytes with mode 0600 if absent. Losing it re-randomizes this machine's
    subdomains (a one-time re-pair), which is acceptable."""
    path = home / ".mothership" / "relay-subdomain-secret"
    if path.exists():
        return path.read_bytes()
    path.parent.mkdir(parents=True, exist_ok=True)
    secret = os.urandom(32)
    # Write with 0600 from creation (avoid a readable window).
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(fd, secret)
    finally:
        os.close(fd)
    return secret
```

- [ ] **Step 4: Run — expect pass.**

- [ ] **Step 5: Commit.**
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: Wire the secret into the two callers

**Files:** Modify `cli/serve.py` (~line 231-232) and `cli/pair.py` (~line 41).

Both call `device_subdomain(workspace, dev_id)`; both must now pass the same secret so the pairing URL and the tunnel bind the same subdomain.

- [ ] **Step 1: Update `serve.py`.** Near where `dev = device_id(...)` is computed, add `from mship.core.relay.keys import ensure_subdomain_secret` (with the other relay imports) and:

```python
    dev = device_id(relay_public_key(key_path))
    secret = ensure_subdomain_secret(home=Path.home())
    subdomain = device_subdomain(workspace, dev, secret)
```

- [ ] **Step 2: Update `pair.py`** (line ~41) identically:

```python
    from mship.core.relay.keys import relay_public_key, ensure_subdomain_secret
    secret = ensure_subdomain_secret(home=Path.home())
    subdomain = device_subdomain(workspace, device_id(relay_public_key(key_path)), secret)
```

- [ ] **Step 3: Compile/import check + run the serve/pair tests.** `uv run python -c "import mship.cli.serve, mship.cli.pair"` and `uv run pytest tests/cli/ -k "serve or pair" -q`. If a test constructs `device_subdomain(...)` with the old 2-arg signature, update it to pass a fixed `secret=b"\x00"*32`.

- [ ] **Step 4: Commit.**
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: `mship relay whoami <subdomain>`

**Files:** Modify `cli/relay.py`; Test `tests/cli/test_relay.py`.

Recover which workspace a subdomain belongs to by recomputing `opaque_slug` over candidate workspace names (the current workspace, plus any `--workspace` given) and matching the subdomain's slug part.

- [ ] **Step 1: Write failing test** (CliRunner; monkeypatch HOME so the secret is deterministic-per-tmp):

```python
def test_relay_whoami_matches_known_workspace(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    from mship.core.relay.keys import ensure_subdomain_secret
    from mship.core.relay.tunnel import device_subdomain, opaque_slug
    secret = ensure_subdomain_secret(home=tmp_path)
    sub = device_subdomain("ground-control", "abc123", secret)
    r = runner.invoke(app, ["relay", "whoami", sub, "--workspace", "ground-control", "--workspace", "other"])
    assert r.exit_code == 0
    assert "ground-control" in r.output
    r2 = runner.invoke(app, ["relay", "whoami", "zzzzzzzz-abc123", "--workspace", "ground-control"])
    assert "no match" in r2.output.lower()
```

- [ ] **Step 2: Run — expect fail.**

- [ ] **Step 3: Implement** — add a `whoami` command under the existing `relay_app` in `cli/relay.py`:

```python
    @relay_app.command()
    def whoami(
        subdomain: str = typer.Argument(..., help="A relay subdomain (or full label <slug>-<devid>)."),
        workspace: list[str] = typer.Option(None, "--workspace", "-w",
            help="Candidate workspace name(s) to test. Defaults to the current workspace."),
    ):
        """Recover which workspace a relay subdomain belongs to, by recomputing the opaque
        slug over candidate names on THIS machine (needs the machine's subdomain secret)."""
        from mship.core.relay.keys import ensure_subdomain_secret
        from mship.core.relay.tunnel import opaque_slug
        secret = ensure_subdomain_secret(home=Path.home())
        # Take the slug part (strip a trailing -<devid> and any host suffix).
        label = subdomain.strip().split(".", 1)[0]
        slug = label.rsplit("-", 1)[0] if "-" in label else label
        candidates = list(workspace) if workspace else []
        if not candidates:
            # current workspace name from the container/config, if resolvable
            try:
                candidates = [get_container().config().workspace_name]  # adjust to the real accessor
            except Exception:
                candidates = []
        match = next((w for w in candidates if opaque_slug(w, secret) == slug), None)
        if match:
            typer.echo(match)
        else:
            typer.echo(f"no match ({len(candidates)} candidate(s) checked)")
```
NOTE for the implementer: confirm how other `relay`/`serve` commands read the current workspace name (grep `workspace_name` / `config().` in `cli/serve.py` / `cli/relay.py`) and use that exact accessor for the default candidate; if none resolves cleanly, require `--workspace` and drop the auto-default.

- [ ] **Step 4: Run — expect pass.**

- [ ] **Step 5: Commit.**
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: tls_ask comment + opaque-subdomain acceptance test + migration note

**Files:** Modify `core/relay/tls_ask.py`; Test `tests/core/relay/test_tls_ask.py`.

The cert-allowlist regex `[a-z0-9][a-z0-9-]*-[0-9a-f]{6}` already accepts the opaque shape (base32 a-z2-7 ⊂ a-z0-9). Only the comment is now inaccurate.

- [ ] **Step 1: Add an acceptance test** — an opaque subdomain still passes `tls_ask_allowed`:

```python
def test_tls_ask_allows_opaque_subdomain():
    from mship.core.relay.keys import ensure_subdomain_secret  # or a fixed secret
    from mship.core.relay.tunnel import device_subdomain
    sub = device_subdomain("ground-control", "abc123", b"\x00" * 32)
    assert tls_ask_allowed(f"{sub}.relay.example.com", "relay.example.com") is True
```

- [ ] **Step 2: Run — expect pass already** (regex accepts it). If it fails, the base32 alphabet includes a char the regex rejects — widen the regex minimally; otherwise no code change.

- [ ] **Step 3: Update the `tls_ask.py` comment** — replace "the DNS-safe workspace slug ([a-z0-9-])" with "an opaque per-workspace slug (base32, [a-z2-7]); the workspace name is no longer present" so the intent is accurate.

- [ ] **Step 4: Migration note** — add a one-line note to `mship relay --help` / the serve-relay startup log (or the pair output) that upgrading changes the subdomain, so each device re-pairs once. Keep it a single clear line; nothing breaks silently.

- [ ] **Step 5: Commit.**
<!-- /mship:task -->

---

## Self-Review

**Spec coverage:** ac1 (opaque base32 HMAC slug, DNS-safe, <=63) → Task 1; ac2 (stable/deterministic) → Task 1 test; ac3 (secret generated once, 0600) → Task 2; ac4 (whoami recovers / no-match) → Task 4; ac5 (opacity, different names unrelated, unit-tested) → Task 1 `test_opaque_slug_hides_the_name`; ac6 (one-time re-pair documented) → Task 5 Step 4; ac7 (tls_ask in lockstep + pairing keeps the name for display) → Task 5 (regex already matches; comment fixed) + the pairing QR carrying the friendly name is unchanged (pair.py only changes the subdomain arg, not the workspace-name field).

**Consistency:** `opaque_slug(workspace, secret)` and `device_subdomain(workspace, dev_id, secret)` signatures are used identically across Tasks 1, 3, 4, 5. Both callers (serve, pair) load the secret via `ensure_subdomain_secret(home=Path.home())`.

**Risk notes:** the two callers MUST pass the same secret + same dev_id or the pairing URL and the tunnel diverge (verify both use `ensure_subdomain_secret(home=Path.home())`); confirm the current-workspace-name accessor for whoami before relying on the auto-default; keep the base32 lowercased + padding-stripped (DNS-safe).
