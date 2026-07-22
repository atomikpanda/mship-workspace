# Cloud-worker auth spine — attach-at-relay credential egress proxy (Shape 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `cloud-worker-auth-spine` (`specs/2026-07-22-cloud-worker-auth-spine.md`) — approved. Unblocks the overnight cloud-worker fan-out (#393).

**Goal:** Turn the relay into a scoped, credential-attaching egress proxy so a disposable, prompt-injectable worker can clone/fetch/push cross-repo carrying only a low-value placeholder, while the real GitHub App token is attached and enforced at the relay's egress (the credential never lands on the worker).

**Architecture:** A new **egress-proxy role** module on the relay terminates the worker's git smart-HTTP + GitHub-API traffic, then applies `route → provider → enforce → attach → forward`. Four seams go in from day one: `CredentialProvider` (v1 `GitHubAppProvider` wrapping `core/gh_app.py`), `Attachment` (host-locked `Authorization: token …`), a `RouteTable` (host → {provider, enforcer}), and typed enrollment **grants** (the repo ceiling). A **git-smart-HTTP enforcer** parses the receive-pack command list and permits a push only to the run's branch for a run-scoped repo; clone/fetch pass. Two authorization layers make cross-repo work: the enrollment grant is the repo **ceiling**; a **per-run token** narrows to `{repos ⊆ ceiling, push_branch}` and is the only thing the worker holds.

**Tech Stack:** Python 3, FastAPI + uvicorn (egress app, mirrors `enroll_app.py`), httpx (upstream forward + injectable `MockTransport` in tests, mirrors `core/gh_app.py`), `hmac`/`hashlib`/`secrets` (per-run token), Typer (`mship relay` sub-commands), pytest. Single repo: **mothership**. Caddy + docker-compose for deploy wiring.

**Work from:** `.worktrees/cloud-worker-auth-spine-attach-at-relay/mothership` (worktree already exists on branch off `main`). All paths below are relative to the **mothership repo root** (`src/mship/…`, `tests/…`, `docker/relay/…`, `docs/…`).

---

## The proxy mechanism (the crux — read before Task 10)

**Resolved: reverse-proxy via git URL-rewrite, not a forward proxy.** A forward proxy (`CONNECT`/`HTTPS_PROXY`) cannot attach a header — it blindly tunnels the worker's TLS to `github.com`, so the relay never sees plaintext to inject `Authorization`. Therefore the worker's git remote must point *at the relay*, which terminates TLS (Caddy already does on-demand TLS for `*.RELAY_DOMAIN`), attaches the token, and re-issues the request to `github.com`.

**Exactly what the worker configures (holds NO usable credential):**
```
# 1. URL rewrite (the "placeholder"/config — no secret). git resolves
#    https://github.com/<owner>/<repo>.git  ->  https://egress.<RELAY_DOMAIN>/gh/<owner>/<repo>.git
git config --global url."https://egress.<RELAY_DOMAIN>/gh/".insteadOf   "https://github.com/"
git config --global url."https://egress.<RELAY_DOMAIN>/api/".insteadOf "https://api.github.com/"

# 2. The per-run token on the worker->relay leg (LOW value: not a GitHub credential).
git config --global http."https://egress.<RELAY_DOMAIN>/".extraHeader "Mship-Run-Token: <token_id>.<secret>"
```
Verified locally: with that `insteadOf`, `git ls-remote --get-url` for `https://github.com/owner/repo.git` resolves to `https://egress.<host>/gh/owner/repo.git`. git then requests `…/gh/owner/repo.git/info/refs?service=git-receive-pack` and `POST …/gh/owner/repo.git/git-receive-pack`.

**How the relay attaches + forwards** (per request, in `build_egress_app`):
1. Read `Mship-Run-Token`; `verify_run_token` it (hmac over a persisted hash). Missing/invalid → 401. **This is the worker's end-to-end auth to the egress-proxy role** — verified by the module itself, not "the relay says so" (satisfies ac8; survives the future off-relay relocation unchanged).
2. Map path prefix → upstream host (`/gh/` → `github.com`, `/api/` → `api.github.com`) and strip it; extract `owner/repo` + the smart-HTTP service from the remaining path.
3. Look up the token's enrollment **ceiling** grants; require the per-run scope ⊆ ceiling.
4. `RouteTable.resolve(upstream_host)` → `{provider, enforcer}`.
5. `enforcer.check(...)`: on a receive-pack POST, parse the pkt-line command list and reject any ref-update whose ref ≠ `refs/heads/<push_branch>` or whose repo ∉ the run's repos; clone/fetch (upload-pack) pass.
6. `provider.resolve(...)`: mint an App installation token scoped to the run's repos.
7. `attachment.apply(headers, upstream_host, value)`: host-locked — refuses to set `Authorization` for any host outside `[github.com, api.github.com]`. **Strip `Mship-Run-Token` and the inbound `Host` from the upstream headers** so the placeholder never leaves the relay.
8. Forward to `https://<upstream_host><path>?<query>` via httpx; relay the response back.

**Why the worker holds nothing usable:** the per-run token is not a GitHub bearer — presented directly to `github.com` it is rejected; presented to the relay it only unlocks a push of the *run branch* to the *run's repos* (enforced) with a *repo-scoped, short-TTL* token the worker never sees. Exfiltrating it yields no GitHub access and no other-branch/other-repo write.

**Things to confirm with the operator before building (flagged in the report):**
- **Worker→egress auth = per-run token over outbound HTTPS, no SSH key on the worker.** The spec's Approach step (1) says "authenticate the tunnel against the SSH-pubkey enrollment." In v1 the *disposable* worker makes a plain outbound HTTPS request to `egress.<domain>` and authenticates with the per-run token; the SSH-pubkey enrollment is only where the grant **ceiling** is anchored (the per-run token references an approved enrollment id). No second SSH credential is placed on the worker. This is the simplest reading of "the per-run relay token is what a worker presents" — confirm it matches intent.
- **Host mapping = path-prefix (`/gh/`, `/api/`) on a single `egress.<domain>` host**, chosen over per-host subdomains (`github-com.egress.<domain>`) for one cert + one Caddy block. Alternative rejected; confirm no objection.
- **GitHub-API worker leg (api.github.com) is built + tested at the proxy boundary in v1, but wiring the worker's API client (mship/`gh`) to `…/api/` is the worker-image slice (Slice 2/3).** ac1's clone/fetch/push is fully exercised via the git leg. Confirm that api-route-now / api-worker-config-later split is acceptable.

---

## File Structure

**New — the egress-proxy role (a subpackage so it can relocate off the relay as a deployment change):**
- `src/mship/core/relay/egress/__init__.py` — package marker.
- `src/mship/core/relay/egress/pktline.py` — `RefUpdate`, `read_pkt_lines`, `parse_receive_pack_commands` (pure git-wire parsing).
- `src/mship/core/relay/egress/request.py` — `EgressRequest`, `parse_egress_request` (path-prefix host map + repo/service extraction).
- `src/mship/core/relay/egress/enforce.py` — `Enforcer` (Protocol), `GitSmartHttpEnforcer`, `HostLockedEnforcer`, `EnforcementError`.
- `src/mship/core/relay/egress/credential.py` — `Credential`, `Attachment`, `AttachmentHostError`, `github_token_attachment`.
- `src/mship/core/relay/egress/provider.py` — `CredentialProvider` (Protocol), `GitHubAppProvider`, `ProviderError`.
- `src/mship/core/relay/egress/routes.py` — `Route`, `RouteTable`, `UnknownHostError`, `build_default_routes`.
- `src/mship/core/relay/egress/proxy.py` — `build_egress_app` (the assembly: verify → route → enforce → provider → attach → forward; fail-closed).

**New — relay persistence (siblings of `enroll.py`, the ceiling + per-run scope):**
- `src/mship/core/relay/grants.py` — `Scope`, `Grant`, `GrantStore` (typed enrollment grants = repo ceiling).
- `src/mship/core/relay/run_token.py` — `RunToken`, `issue_run_token`, `verify_run_token` (plaintext once, hash persisted, hmac verify, expiry).

**Modified:**
- `src/mship/cli/relay.py` — add `grant`, `issue-run-token`, `egress-server` commands.
- `src/mship/core/relay/tls_ask.py` — allow the `egress` label (mirrors `enroll`).
- `docker/relay/Caddyfile` — `egress.{$RELAY_DOMAIN}` reverse-proxy block.
- `docker/relay/docker-compose.yml` — App-creds env + grant/token store note.
- `docs/cloud-worker-auth-spine.md` — trust model + four seams (new doc).

**Tests (one file per module):**
- `tests/core/relay/egress/test_pktline.py`, `test_request.py`, `test_enforce.py`, `test_credential.py`, `test_provider.py`, `test_routes.py`, `test_proxy.py`
- `tests/core/relay/test_grants.py`, `test_run_token.py`
- `tests/core/relay/test_tls_ask.py` (extend), `tests/cli/test_relay_grant.py`

Create `tests/core/relay/egress/__init__.py` (empty) alongside the first egress test.

---

<!-- mship:task id=1 -->
### Task 1: Grant + Scope model (the ceiling / per-run scope value objects)

**Files:**
- Create: `src/mship/core/relay/grants.py`
- Test: `tests/core/relay/test_grants.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/core/relay/test_grants.py
from mship.core.relay.grants import Scope, Grant


def test_scope_covers_is_repo_subset_ignoring_push_branch():
    ceiling = Scope(repos=("acme/api", "acme/web"))               # ceiling: push_branch None
    run = Scope(repos=("acme/api",), push_branch="feat/x")        # per-run subset
    assert ceiling.covers(run) is True


def test_scope_does_not_cover_repo_outside_ceiling():
    ceiling = Scope(repos=("acme/api",))
    run = Scope(repos=("acme/api", "acme/secret"), push_branch="feat/x")
    assert ceiling.covers(run) is False


def test_grant_carries_provider_and_scope():
    g = Grant(provider="github-app", scope=Scope(repos=("acme/api",)))
    assert g.provider == "github-app"
    assert g.scope.repos == ("acme/api",)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/relay/test_grants.py -v`
Expected: FAIL — `ModuleNotFoundError: mship.core.relay.grants`.

- [ ] **Step 3: Write minimal implementation**

```python
# src/mship/core/relay/grants.py
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class Scope:
    """A repo set, optionally narrowed to one push branch.

    Used twice: as an enrollment's CEILING (push_branch=None — which repos the
    enrollment may ever touch) and as a PER-RUN scope (repos ⊆ ceiling +
    push_branch = the run's branch). `repos` are full `owner/repo` names.
    """
    repos: tuple[str, ...] = field(default_factory=tuple)
    push_branch: str | None = None

    def covers(self, other: "Scope") -> bool:
        """True when `other`'s repos are a subset of this scope's repos.
        Branch is not part of the ceiling check (the ceiling has no branch)."""
        return set(other.repos) <= set(self.repos)


@dataclass(frozen=True)
class Grant:
    """A typed authorization: one provider + its scope. v1: provider='github-app'."""
    provider: str
    scope: Scope
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/relay/test_grants.py -v`
Expected: PASS (3 passed).

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/relay/grants.py tests/core/relay/test_grants.py
git commit -m "feat(relay): Scope + Grant model for enrollment ceiling / per-run scope"
mship journal "added Scope+Grant model (grants.py); covers() subset check; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: EgressRequest — path-prefix host map + repo/service extraction

**Files:**
- Create: `src/mship/core/relay/egress/__init__.py` (empty), `src/mship/core/relay/egress/request.py`
- Test: `tests/core/relay/egress/__init__.py` (empty), `tests/core/relay/egress/test_request.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/core/relay/egress/test_request.py
import pytest
from mship.core.relay.egress.request import parse_egress_request, UnmappablePathError


def test_gh_prefix_maps_to_github_and_extracts_repo_and_receive_service():
    req = parse_egress_request(
        method="POST",
        path="/gh/acme/api.git/git-receive-pack",
        query="",
        headers={},
        body=b"",
    )
    assert req.upstream_host == "github.com"
    assert req.upstream_path == "/acme/api.git/git-receive-pack"
    assert req.repo == "acme/api"
    assert req.service == "git-receive-pack"
    assert req.is_receive_pack_post is True


def test_info_refs_service_comes_from_query():
    req = parse_egress_request(
        method="GET",
        path="/gh/acme/api.git/info/refs",
        query="service=git-upload-pack",
        headers={},
        body=b"",
    )
    assert req.service == "git-upload-pack"
    assert req.is_receive_pack_post is False


def test_api_prefix_maps_to_api_host_with_no_repo():
    req = parse_egress_request(
        method="GET", path="/api/repos/acme/api/pulls", query="", headers={}, body=b"",
    )
    assert req.upstream_host == "api.github.com"
    assert req.upstream_path == "/repos/acme/api/pulls"
    assert req.repo is None


def test_unmapped_prefix_raises():
    with pytest.raises(UnmappablePathError):
        parse_egress_request(method="GET", path="/evil/x", query="", headers={}, body=b"")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/relay/egress/test_request.py -v`
Expected: FAIL — `ModuleNotFoundError: mship.core.relay.egress.request`.

- [ ] **Step 3: Write minimal implementation**

```python
# src/mship/core/relay/egress/request.py
from __future__ import annotations

from dataclasses import dataclass
from urllib.parse import parse_qs

# Path prefix -> upstream host. Adding a host = one entry here + one route
# (routes.py) + one tls_ask/Caddy allowance. No github.com special-case in code.
_PREFIX_HOST = {"/gh/": "github.com", "/api/": "api.github.com"}


class UnmappablePathError(Exception):
    """Incoming path did not start with a known egress prefix (/gh/, /api/)."""


@dataclass(frozen=True)
class EgressRequest:
    method: str
    upstream_host: str
    upstream_path: str
    query: str
    headers: dict
    body: bytes
    repo: str | None            # owner/repo for git hosts; None for the API host
    service: str | None         # git-upload-pack | git-receive-pack | None
    is_receive_pack_post: bool


def _extract_repo(upstream_path: str) -> str | None:
    # /acme/api.git/info/refs -> acme/api ; /acme/api.git/git-receive-pack -> acme/api
    parts = [p for p in upstream_path.split("/") if p]
    if len(parts) < 2:
        return None
    owner, name = parts[0], parts[1]
    if name.endswith(".git"):
        name = name[: -len(".git")]
    return f"{owner}/{name}"


def _service(method: str, upstream_path: str, query: str) -> tuple[str | None, bool]:
    if upstream_path.endswith("/info/refs"):
        svc = (parse_qs(query).get("service") or [None])[0]
        return svc, False
    if upstream_path.endswith("/git-receive-pack"):
        return "git-receive-pack", method.upper() == "POST"
    if upstream_path.endswith("/git-upload-pack"):
        return "git-upload-pack", False
    return None, False


def parse_egress_request(*, method, path, query, headers, body) -> EgressRequest:
    """Map a worker-facing path to its upstream host + repo + smart-HTTP service.

    Fails loud at the boundary: a path outside the known prefixes raises rather
    than defaulting to a host (a mis-forward could leak a credential)."""
    prefix = next((p for p in _PREFIX_HOST if path.startswith(p)), None)
    if prefix is None:
        raise UnmappablePathError(path)
    host = _PREFIX_HOST[prefix]
    upstream_path = path[len(prefix) - 1:]     # keep the leading slash
    repo = _extract_repo(upstream_path) if host == "github.com" else None
    service, is_rp_post = _service(method, upstream_path, query)
    return EgressRequest(
        method=method, upstream_host=host, upstream_path=upstream_path, query=query,
        headers=headers, body=body, repo=repo, service=service,
        is_receive_pack_post=is_rp_post,
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/relay/egress/test_request.py -v`
Expected: PASS (4 passed).

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/relay/egress/__init__.py src/mship/core/relay/egress/request.py \
        tests/core/relay/egress/__init__.py tests/core/relay/egress/test_request.py
git commit -m "feat(egress): EgressRequest path-prefix host map + repo/service extraction"
mship journal "added parse_egress_request (/gh//api/ host map, repo+service); tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: pkt-line reader + receive-pack command parser (pure git-wire)

Parse just enough of the smart-HTTP wire to read the receive-pack command list, which precedes the packfile. A pkt-line is a 4-hex length prefix (length *includes* the 4 bytes) framing a payload; `0000` is the flush-pkt that terminates the command list. Each command is `<old-oid> SP <new-oid> SP <ref>`; the FIRST command has a trailing `\0<capabilities>` (and every line a trailing `\n`).

**Files:**
- Create: `src/mship/core/relay/egress/pktline.py`
- Test: `tests/core/relay/egress/test_pktline.py`

- [ ] **Step 1: Write the failing test** (fixture is a REAL command line captured via `GIT_TRACE_PACKET` on `git push`)

```python
# tests/core/relay/egress/test_pktline.py
from mship.core.relay.egress.pktline import (
    read_pkt_lines, parse_receive_pack_commands, RefUpdate,
)

ZERO = "0" * 40


def pkt(payload: bytes) -> bytes:
    """Frame a payload as a pkt-line: 4-hex length (incl. the 4 prefix bytes)."""
    return b"%04x" % (len(payload) + 4) + payload


FLUSH = b"0000"

# Real client receive-pack command line (git 2.43): create feat/demo.
_CMD = (
    b"0000000000000000000000000000000000000000 "
    b"0cee56ac428e99ad3c1a55a8c6913250e9172578 "
    b"refs/heads/feat/demo\x00 report-status-v2 side-band-64k quiet "
    b"object-format=sha1 agent=git/2.43.0\n"
)


def test_read_pkt_lines_stops_at_flush_and_ignores_packfile_bytes():
    body = pkt(_CMD) + FLUSH + b"PACK\x00\x00garbage-packfile-bytes"
    lines = read_pkt_lines(body)
    assert lines == [_CMD]


def test_parse_receive_pack_commands_strips_caps_and_newline():
    body = pkt(_CMD) + FLUSH + b"PACKxxxx"
    cmds = parse_receive_pack_commands(body)
    assert cmds == [
        RefUpdate(
            old_oid=ZERO,
            new_oid="0cee56ac428e99ad3c1a55a8c6913250e9172578",
            ref="refs/heads/feat/demo",
        )
    ]


def test_parse_multiple_commands_atomic_push():
    line2 = (
        b"1111111111111111111111111111111111111111 "
        b"2222222222222222222222222222222222222222 "
        b"refs/heads/feat/demo\n"
    )
    body = pkt(_CMD) + pkt(line2) + FLUSH
    cmds = parse_receive_pack_commands(body)
    assert [c.ref for c in cmds] == ["refs/heads/feat/demo", "refs/heads/feat/demo"]
    assert cmds[1].old_oid == "1" * 40
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/relay/egress/test_pktline.py -v`
Expected: FAIL — `ModuleNotFoundError: mship.core.relay.egress.pktline`.

- [ ] **Step 3: Write minimal implementation**

```python
# src/mship/core/relay/egress/pktline.py
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class RefUpdate:
    old_oid: str
    new_oid: str
    ref: str


def read_pkt_lines(data: bytes) -> list[bytes]:
    """Return the pkt-line payloads up to (not including) the first flush-pkt.

    Reads the receive-pack command list without touching the packfile that
    follows the flush. 4-hex length frames the line and INCLUDES the 4 length
    bytes; `0000` is the flush-pkt. Malformed framing stops the scan (fail
    closed — the enforcer treats an empty/short command list as a rejectable
    push, never a pass)."""
    out: list[bytes] = []
    i, n = 0, len(data)
    while i + 4 <= n:
        try:
            length = int(data[i : i + 4], 16)
        except ValueError:
            break
        if length == 0:            # flush-pkt: command list ends, packfile follows
            break
        if length < 4 or i + length > n:
            break
        out.append(data[i + 4 : i + length])
        i += length
    return out


def parse_receive_pack_commands(body: bytes) -> list[RefUpdate]:
    """Parse the receive-pack POST body's command list into RefUpdates.

    Each command is `<old> <new> <ref>`; the first carries a trailing
    `\\0<caps>` and every line a trailing `\\n` — both stripped from the ref."""
    cmds: list[RefUpdate] = []
    for line in read_pkt_lines(body):
        text = line.rstrip(b"\n")
        text = text.split(b"\x00", 1)[0]      # drop capabilities on the first line
        parts = text.split(b" ")
        if len(parts) < 3:
            continue
        old, new, ref = parts[0], parts[1], b" ".join(parts[2:])
        cmds.append(
            RefUpdate(
                old_oid=old.decode("ascii", "replace"),
                new_oid=new.decode("ascii", "replace"),
                ref=ref.decode("utf-8", "replace"),
            )
        )
    return cmds
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/relay/egress/test_pktline.py -v`
Expected: PASS (3 passed).

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/relay/egress/pktline.py tests/core/relay/egress/test_pktline.py
git commit -m "feat(egress): pkt-line reader + receive-pack command parser (pure)"
mship journal "added pktline read + receive-pack command parse vs real wire sample; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: git-smart-HTTP enforcer (allow run branch, reject everything else; pass upload-pack)

The load-bearing security check. Provider-independent (the git wire is the same across GitHub/GitLab/Gitea), so branch-scoping is written once.

**Files:**
- Create: `src/mship/core/relay/egress/enforce.py`
- Test: `tests/core/relay/egress/test_enforce.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/core/relay/egress/test_enforce.py
import pytest
from mship.core.relay.grants import Grant, Scope
from mship.core.relay.egress.request import parse_egress_request
from mship.core.relay.egress.enforce import (
    GitSmartHttpEnforcer, HostLockedEnforcer, EnforcementError,
)


def pkt(payload: bytes) -> bytes:
    return b"%04x" % (len(payload) + 4) + payload


def _push_body(new_oid: str, ref: str) -> bytes:
    line = f"{'0'*40} {new_oid} {ref}\x00 report-status-v2\n".encode()
    return pkt(line) + b"0000" + b"PACKxxxx"


RUN_GRANT = Grant("github-app", Scope(repos=("acme/api", "acme/web"), push_branch="feat/x"))


def _req(path, method="POST", query="", body=b""):
    return parse_egress_request(method=method, path=path, query=query, headers={}, body=body)


def test_push_to_run_branch_is_allowed():
    body = _push_body("a" * 40, "refs/heads/feat/x")
    GitSmartHttpEnforcer().check(_req("/gh/acme/api.git/git-receive-pack", body=body), RUN_GRANT)


def test_push_to_other_branch_is_rejected():
    body = _push_body("a" * 40, "refs/heads/main")
    with pytest.raises(EnforcementError):
        GitSmartHttpEnforcer().check(_req("/gh/acme/api.git/git-receive-pack", body=body), RUN_GRANT)


def test_push_to_repo_outside_run_is_rejected():
    body = _push_body("a" * 40, "refs/heads/feat/x")
    with pytest.raises(EnforcementError):
        GitSmartHttpEnforcer().check(_req("/gh/acme/other.git/git-receive-pack", body=body), RUN_GRANT)


def test_delete_of_run_branch_is_rejected():
    body = _push_body("0" * 40, "refs/heads/feat/x")   # new-oid all-zero = delete
    with pytest.raises(EnforcementError):
        GitSmartHttpEnforcer().check(_req("/gh/acme/api.git/git-receive-pack", body=body), RUN_GRANT)


def test_clone_fetch_upload_pack_passes():
    e = GitSmartHttpEnforcer()
    e.check(_req("/gh/acme/api.git/info/refs", method="GET", query="service=git-upload-pack"), RUN_GRANT)
    e.check(_req("/gh/acme/api.git/git-upload-pack", method="POST", body=b"0011want.."), RUN_GRANT)


def test_receive_pack_advertisement_get_passes():
    e = GitSmartHttpEnforcer()
    e.check(_req("/gh/acme/api.git/info/refs", method="GET", query="service=git-receive-pack"), RUN_GRANT)


def test_host_locked_enforcer_passes_api_traffic():
    HostLockedEnforcer().check(_req("/api/repos/acme/api/pulls", method="GET"), RUN_GRANT)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/relay/egress/test_enforce.py -v`
Expected: FAIL — `ModuleNotFoundError: mship.core.relay.egress.enforce`.

- [ ] **Step 3: Write minimal implementation**

```python
# src/mship/core/relay/egress/enforce.py
from __future__ import annotations

from typing import Protocol, runtime_checkable

from mship.core.relay.grants import Grant
from mship.core.relay.egress.pktline import parse_receive_pack_commands
from mship.core.relay.egress.request import EgressRequest

_ZERO_OID = "0" * 40


class EnforcementError(Exception):
    """A request violated the route's policy and must not reach the provider."""


@runtime_checkable
class Enforcer(Protocol):
    def check(self, request: EgressRequest, grant: Grant) -> None: ...


class GitSmartHttpEnforcer:
    """Permit clone/fetch (upload-pack) and the receive-pack advertisement;
    permit a receive-pack POST only when every ref-update targets the run's
    branch for a repo inside the run's scope. Everything else is refused."""

    def check(self, request: EgressRequest, grant: Grant) -> None:
        if request.service == "git-upload-pack":
            return
        if request.service == "git-receive-pack" and not request.is_receive_pack_post:
            return                                   # ref advertisement (read-only)
        if not request.is_receive_pack_post:
            raise EnforcementError(f"unsupported git request: {request.upstream_path}")

        scope = grant.scope
        if request.repo not in scope.repos:
            raise EnforcementError(
                f"push to {request.repo!r} outside run repos {list(scope.repos)}"
            )
        if not scope.push_branch:
            raise EnforcementError("run scope carries no push_branch; refusing all pushes")
        want = scope.push_branch
        if not want.startswith("refs/"):
            want = f"refs/heads/{want}"

        commands = parse_receive_pack_commands(request.body)
        if not commands:
            raise EnforcementError("receive-pack POST had no parseable ref updates")
        for cmd in commands:
            if cmd.ref != want:
                raise EnforcementError(f"push to {cmd.ref!r}; only {want!r} is allowed")
            if cmd.new_oid == _ZERO_OID:
                raise EnforcementError(f"deletion of {cmd.ref!r} is not allowed")


class HostLockedEnforcer:
    """No ref-level policy: the API surface is bounded by the repo-scoped App
    token + the Attachment host-lock. Passes; documents the boundary."""

    def check(self, request: EgressRequest, grant: Grant) -> None:
        return
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/relay/egress/test_enforce.py -v`
Expected: PASS (7 passed).

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/relay/egress/enforce.py tests/core/relay/egress/test_enforce.py
git commit -m "feat(egress): git-smart-http enforcer — run-branch-only push, upload-pack passes"
mship journal "added GitSmartHttpEnforcer + HostLockedEnforcer (branch/repo allow-check); tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: Attachment seam — host-locked `Authorization: token <value>`

**Files:**
- Create: `src/mship/core/relay/egress/credential.py`
- Test: `tests/core/relay/egress/test_credential.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/core/relay/egress/test_credential.py
import pytest
from mship.core.relay.egress.credential import (
    Attachment, AttachmentHostError, github_token_attachment, Credential,
)


def test_apply_sets_authorization_header_for_allowed_host():
    headers: dict = {}
    github_token_attachment().apply(headers, host="github.com", value="ghs_secret")
    assert headers["Authorization"] == "token ghs_secret"


def test_apply_refuses_host_outside_lock():
    with pytest.raises(AttachmentHostError):
        github_token_attachment().apply({}, host="evil.example.com", value="ghs_secret")


def test_render_formats_value():
    att = Attachment(header="Authorization", template="token {value}",
                     hosts=("github.com",))
    assert att.render("abc") == "token abc"


def test_credential_carries_value_ttl_and_attachment():
    cred = Credential(value="ghs_x", expires_at="2026-07-22T02:00:00Z",
                      attach=github_token_attachment())
    assert cred.value == "ghs_x"
    assert cred.attach.header == "Authorization"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/relay/egress/test_credential.py -v`
Expected: FAIL — `ModuleNotFoundError: mship.core.relay.egress.credential`.

- [ ] **Step 3: Write minimal implementation**

```python
# src/mship/core/relay/egress/credential.py
from __future__ import annotations

from dataclasses import dataclass


class AttachmentHostError(Exception):
    """Refused to attach a credential to a host outside the Attachment's lock."""


@dataclass(frozen=True)
class Attachment:
    """HOW a credential rides on the wire, decoupled from WHAT it is, plus a
    host-lock so a route misconfig can never send a credential to the wrong
    host."""
    header: str
    template: str            # contains `{value}`
    hosts: tuple[str, ...]

    def render(self, value: str) -> str:
        return self.template.format(value=value)

    def apply(self, headers: dict, *, host: str, value: str) -> None:
        if host not in self.hosts:
            raise AttachmentHostError(
                f"refusing to attach {self.header} to {host!r}; "
                f"allowed hosts: {list(self.hosts)}"
            )
        headers[self.header] = self.render(value)


@dataclass(frozen=True)
class Credential:
    value: str
    expires_at: str | None
    attach: Attachment


def github_token_attachment() -> Attachment:
    """GitHub App token rides as `Authorization: token <value>`, locked to
    github.com + api.github.com."""
    return Attachment(
        header="Authorization",
        template="token {value}",
        hosts=("github.com", "api.github.com"),
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/relay/egress/test_credential.py -v`
Expected: PASS (4 passed).

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/relay/egress/credential.py tests/core/relay/egress/test_credential.py
git commit -m "feat(egress): Attachment seam with host-locked Authorization: token"
mship journal "added Credential + host-locked Attachment (github_token_attachment); tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: CredentialProvider seam + GitHubAppProvider (wraps core/gh_app.py, mocked)

**Files:**
- Create: `src/mship/core/relay/egress/provider.py`
- Test: `tests/core/relay/egress/test_provider.py`

- [ ] **Step 1: Write the failing test** (mock GitHub via `httpx.MockTransport`, mirroring `tests/core/test_gh_app.py`)

```python
# tests/core/relay/egress/test_provider.py
import httpx
import pytest
from mship.core.relay.grants import Grant, Scope
from mship.core.relay.egress.request import parse_egress_request
from mship.core.relay.egress.provider import GitHubAppProvider, ProviderError


def _req(repo_path="/gh/acme/api.git/git-receive-pack"):
    return parse_egress_request(method="POST", path=repo_path, query="", headers={}, body=b"")


def _mock_github(mint_capture: dict) -> httpx.Client:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/installation"):
            return httpx.Response(200, json={"id": 42})
        if request.url.path.endswith("/access_tokens"):
            import json
            mint_capture["repositories"] = json.loads(request.content)["repositories"]
            return httpx.Response(201, json={"token": "ghs_minted", "expires_at": "2026-07-22T02:00:00Z"})
        return httpx.Response(404)
    return httpx.Client(transport=httpx.MockTransport(handler))


# A throwaway RSA key so _app_jwt can sign; not a real GitHub App key.
@pytest.fixture(scope="module")
def rsa_pem():
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    return key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode()


def test_resolve_mints_token_scoped_to_run_repos(rsa_pem):
    captured: dict = {}
    grant = Grant("github-app", Scope(repos=("acme/api",), push_branch="feat/x"))
    provider = GitHubAppProvider(app_id="1", private_key=rsa_pem, client=_mock_github(captured))
    cred = provider.resolve(identity="enr1", grant=grant, request=_req())
    assert cred.value == "ghs_minted"
    assert cred.expires_at == "2026-07-22T02:00:00Z"
    assert captured["repositories"] == ["api"]          # short name, scoped to the grant
    assert cred.attach.header == "Authorization"


def test_resolve_refuses_repo_outside_grant(rsa_pem):
    grant = Grant("github-app", Scope(repos=("acme/web",), push_branch="feat/x"))
    provider = GitHubAppProvider(app_id="1", private_key=rsa_pem, client=_mock_github({}))
    with pytest.raises(ProviderError):
        provider.resolve(identity="enr1", grant=grant, request=_req("/gh/acme/api.git/git-receive-pack"))


def test_resolve_refuses_empty_repo_scope(rsa_pem):
    grant = Grant("github-app", Scope(repos=(), push_branch="feat/x"))
    provider = GitHubAppProvider(app_id="1", private_key=rsa_pem, client=_mock_github({}))
    with pytest.raises(ProviderError):
        provider.resolve(identity="enr1", grant=grant, request=_req())
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/relay/egress/test_provider.py -v`
Expected: FAIL — `ModuleNotFoundError: mship.core.relay.egress.provider`.

- [ ] **Step 3: Write minimal implementation**

```python
# src/mship/core/relay/egress/provider.py
from __future__ import annotations

from typing import Protocol, runtime_checkable

import httpx

from mship.core.gh_app import GhAppError, mint_installation_token, resolve_installation
from mship.core.relay.grants import Grant
from mship.core.relay.egress.credential import Credential, github_token_attachment
from mship.core.relay.egress.request import EgressRequest


class ProviderError(Exception):
    """The provider could not resolve a credential for this request."""


@runtime_checkable
class CredentialProvider(Protocol):
    def resolve(self, identity: str, grant: Grant, request: EgressRequest) -> Credential: ...


class GitHubAppProvider:
    """Resolve a GitHub App installation token scoped to the grant's repos.

    A future StaticSecretProvider / GitLabProvider implements the same
    `resolve(identity, grant, request)` and returns a Credential — the proxy
    core does not change."""

    def __init__(self, *, app_id: str, private_key: str, client: httpx.Client | None = None):
        self._app_id = app_id
        self._private_key = private_key
        self._client = client

    def resolve(self, identity: str, grant: Grant, request: EgressRequest) -> Credential:
        repos = list(grant.scope.repos)
        if not repos:
            raise ProviderError("refusing to mint an unscoped token — grant has no repos")
        if request.repo is not None and request.repo not in repos:
            raise ProviderError(f"repo {request.repo!r} is outside the grant {repos}")

        owners = {r.split("/", 1)[0] for r in repos}
        if len(owners) > 1:
            raise ProviderError(f"grant repos span multiple owners {sorted(owners)}")
        owner = owners.pop()
        short_names = [r.split("/", 1)[1] for r in repos]
        try:
            installation_id = resolve_installation(
                app_id=self._app_id, private_key=self._private_key,
                owner=owner, repo=short_names[0], client=self._client,
            )
            minted = mint_installation_token(
                app_id=self._app_id, private_key=self._private_key,
                installation_id=installation_id, repos=short_names, client=self._client,
            )
        except GhAppError as e:
            raise ProviderError(str(e)) from e
        return Credential(
            value=minted["token"],
            expires_at=minted.get("expires_at"),
            attach=github_token_attachment(),
        )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/relay/egress/test_provider.py -v`
Expected: PASS (3 passed).

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/relay/egress/provider.py tests/core/relay/egress/test_provider.py
git commit -m "feat(egress): CredentialProvider seam + GitHubAppProvider (mocked gh_app)"
mship journal "added GitHubAppProvider.resolve (scoped mint, refuses out-of-grant/empty); tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=7 -->
### Task 7: Route table — destination host → {provider, enforcer}

**Files:**
- Create: `src/mship/core/relay/egress/routes.py`
- Test: `tests/core/relay/egress/test_routes.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/core/relay/egress/test_routes.py
import pytest
from mship.core.relay.egress.routes import RouteTable, UnknownHostError, build_default_routes
from mship.core.relay.egress.enforce import GitSmartHttpEnforcer, HostLockedEnforcer


class _FakeProvider:
    def resolve(self, identity, grant, request):  # pragma: no cover - not called here
        raise NotImplementedError


def test_default_routes_map_github_and_api_hosts():
    table = build_default_routes(_FakeProvider())
    assert isinstance(table.resolve("github.com").enforcer, GitSmartHttpEnforcer)
    assert isinstance(table.resolve("api.github.com").enforcer, HostLockedEnforcer)
    assert table.resolve("github.com").provider is table.resolve("api.github.com").provider


def test_unknown_host_is_rejected_not_defaulted():
    table = build_default_routes(_FakeProvider())
    with pytest.raises(UnknownHostError):
        table.resolve("evil.example.com")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/relay/egress/test_routes.py -v`
Expected: FAIL — `ModuleNotFoundError: mship.core.relay.egress.routes`.

- [ ] **Step 3: Write minimal implementation**

```python
# src/mship/core/relay/egress/routes.py
from __future__ import annotations

from dataclasses import dataclass

from mship.core.relay.egress.enforce import Enforcer, GitSmartHttpEnforcer, HostLockedEnforcer
from mship.core.relay.egress.provider import CredentialProvider


class UnknownHostError(Exception):
    """No route for this destination host (fail closed, never default)."""


@dataclass(frozen=True)
class Route:
    provider: CredentialProvider
    enforcer: Enforcer


class RouteTable:
    """Destination host -> {provider, enforcer} as data. No github.com
    special-case in code — adding a host is a new entry."""

    def __init__(self, routes: dict[str, Route]):
        self._routes = dict(routes)

    def resolve(self, host: str) -> Route:
        try:
            return self._routes[host]
        except KeyError:
            raise UnknownHostError(host)


def build_default_routes(provider: CredentialProvider) -> RouteTable:
    return RouteTable(
        {
            "github.com": Route(provider=provider, enforcer=GitSmartHttpEnforcer()),
            "api.github.com": Route(provider=provider, enforcer=HostLockedEnforcer()),
        }
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/relay/egress/test_routes.py -v`
Expected: PASS (2 passed).

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/relay/egress/routes.py tests/core/relay/egress/test_routes.py
git commit -m "feat(egress): route table host -> {provider, enforcer}, unknown host rejected"
mship journal "added RouteTable + build_default_routes (github/api hosts); tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=8 -->
### Task 8: GrantStore — persist typed enrollment grants (the repo ceiling)

Extend `grants.py` with a queryable, atomic-write store keyed by enrollment id (the enroll request id — `resolved/<id>.json` already records approval). Mirrors `RequestStore`'s atomic-write discipline.

**Files:**
- Modify: `src/mship/core/relay/grants.py`
- Test: `tests/core/relay/test_grants.py` (extend)

- [ ] **Step 1: Write the failing test** (append to the Task 1 test file)

```python
# tests/core/relay/test_grants.py  (append)
from pathlib import Path
from mship.core.relay.grants import GrantStore


def test_set_and_get_grant_roundtrip(tmp_path: Path):
    store = GrantStore(tmp_path)
    store.set_grant("enr1", Grant("github-app", Scope(repos=("acme/api", "acme/web"))))
    grants = store.get_grants("enr1")
    assert len(grants) == 1
    assert grants[0].provider == "github-app"
    assert set(grants[0].scope.repos) == {"acme/api", "acme/web"}


def test_set_grant_replaces_same_provider(tmp_path: Path):
    store = GrantStore(tmp_path)
    store.set_grant("enr1", Grant("github-app", Scope(repos=("acme/api",))))
    store.set_grant("enr1", Grant("github-app", Scope(repos=("acme/api", "acme/web"))))
    grants = store.get_grants("enr1")
    assert len(grants) == 1
    assert set(grants[0].scope.repos) == {"acme/api", "acme/web"}


def test_get_grants_unknown_enrollment_is_empty(tmp_path: Path):
    assert GrantStore(tmp_path).get_grants("nope") == []
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/relay/test_grants.py -v`
Expected: FAIL — `ImportError: cannot import name 'GrantStore'`.

- [ ] **Step 3: Write minimal implementation** (append to `grants.py`)

```python
# src/mship/core/relay/grants.py  (append; add imports at top)
import json
import re
from pathlib import Path

_ID_RE = re.compile(r"\A[0-9a-f]{1,64}\Z")   # enroll ids are secrets.token_hex(16)


class GrantStore:
    """Filesystem-backed typed grants, one file per enrollment: grants/<id>.json.
    Atomic writes (tmp + replace), like RequestStore."""

    def __init__(self, base_dir):
        self._dir = Path(base_dir) / "grants"
        self._dir.mkdir(parents=True, exist_ok=True)

    def _path(self, enrollment_id: str) -> Path:
        if not _ID_RE.match(enrollment_id):
            raise ValueError(f"invalid enrollment id {enrollment_id!r}")
        return self._dir / f"{enrollment_id}.json"

    def _write_atomic(self, path: Path, rec: dict) -> None:
        tmp = path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(rec))
        tmp.replace(path)

    def set_grant(self, enrollment_id: str, grant: Grant) -> None:
        """Set/replace the grant for `grant.provider` on this enrollment."""
        path = self._path(enrollment_id)
        grants = {g.provider: g for g in self.get_grants(enrollment_id)}
        grants[grant.provider] = grant
        self._write_atomic(
            path,
            {
                "enrollment_id": enrollment_id,
                "grants": [
                    {
                        "provider": g.provider,
                        "scope": {"repos": list(g.scope.repos),
                                  "push_branch": g.scope.push_branch},
                    }
                    for g in grants.values()
                ],
            },
        )

    def get_grants(self, enrollment_id: str) -> list[Grant]:
        path = self._path(enrollment_id)
        if not path.exists():
            return []
        try:
            rec = json.loads(path.read_text())
        except (json.JSONDecodeError, OSError):
            return []
        out: list[Grant] = []
        for g in rec.get("grants", []):
            sc = g.get("scope", {})
            out.append(
                Grant(
                    provider=g["provider"],
                    scope=Scope(repos=tuple(sc.get("repos", [])),
                                push_branch=sc.get("push_branch")),
                )
            )
        return out
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/relay/test_grants.py -v`
Expected: PASS (6 passed — 3 from Task 1 + 3 new).

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/relay/grants.py tests/core/relay/test_grants.py
git commit -m "feat(relay): GrantStore — persist typed enrollment grants (repo ceiling)"
mship journal "added GrantStore (grants/<id>.json, atomic, per-provider replace); tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=9 -->
### Task 9: Per-run token — issue (plaintext once) + hmac verify + expiry

Token format `<token_id>.<secret>`: `token_id` names the record, `secret` is compared by hmac against a persisted SHA-256 hash. Only the hash is stored; re-issuing rotates (new `token_id`); records carry an expiry.

**Files:**
- Create: `src/mship/core/relay/run_token.py`
- Test: `tests/core/relay/test_run_token.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/core/relay/test_run_token.py
from pathlib import Path
from mship.core.relay.grants import Scope
from mship.core.relay.run_token import issue_run_token, verify_run_token


def test_issue_returns_plaintext_and_verify_accepts(tmp_path: Path):
    clock = lambda: 1000.0
    token = issue_run_token(
        tmp_path, enrollment_id="enr1",
        scope=Scope(repos=("acme/api", "acme/web"), push_branch="feat/x"),
        ttl_seconds=3600, clock=clock,
    )
    assert "." in token
    rt = verify_run_token(tmp_path, token, clock=clock)
    assert rt is not None
    assert rt.enrollment_id == "enr1"
    assert set(rt.scope.repos) == {"acme/api", "acme/web"}
    assert rt.scope.push_branch == "feat/x"


def test_only_hash_persisted_not_plaintext(tmp_path: Path):
    token = issue_run_token(tmp_path, enrollment_id="enr1",
                            scope=Scope(repos=("acme/api",), push_branch="feat/x"),
                            ttl_seconds=3600)
    _id, secret = token.split(".", 1)
    for f in (tmp_path / "run-tokens").glob("*.json"):
        assert secret not in f.read_text()


def test_verify_rejects_tampered_secret(tmp_path: Path):
    token = issue_run_token(tmp_path, enrollment_id="enr1",
                            scope=Scope(repos=("acme/api",), push_branch="feat/x"),
                            ttl_seconds=3600)
    token_id, _secret = token.split(".", 1)
    assert verify_run_token(tmp_path, f"{token_id}.wrong") is None


def test_verify_rejects_expired(tmp_path: Path):
    token = issue_run_token(tmp_path, enrollment_id="enr1",
                            scope=Scope(repos=("acme/api",), push_branch="feat/x"),
                            ttl_seconds=100, clock=lambda: 1000.0)
    assert verify_run_token(tmp_path, token, clock=lambda: 2000.0) is None


def test_verify_rejects_unknown_token(tmp_path: Path):
    (tmp_path / "run-tokens").mkdir(parents=True, exist_ok=True)
    assert verify_run_token(tmp_path, "deadbeef.secret") is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/relay/test_run_token.py -v`
Expected: FAIL — `ModuleNotFoundError: mship.core.relay.run_token`.

- [ ] **Step 3: Write minimal implementation**

```python
# src/mship/core/relay/run_token.py
from __future__ import annotations

import hashlib
import hmac
import json
import re
import secrets
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from mship.core.relay.grants import Scope

_ID_RE = re.compile(r"\A[0-9a-f]{1,32}\Z")


@dataclass(frozen=True)
class RunToken:
    token_id: str
    enrollment_id: str
    scope: Scope


def _dir(base_dir) -> Path:
    d = Path(base_dir) / "run-tokens"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _hash(secret: str) -> str:
    return hashlib.sha256(secret.encode("utf-8")).hexdigest()


def issue_run_token(
    base_dir, *, enrollment_id: str, scope: Scope, ttl_seconds: int,
    clock: Callable[[], float] = time.time,
) -> str:
    """Mint a per-run token, persist only its hash, return `<token_id>.<secret>`
    (the plaintext — printed once by the caller; never re-derivable)."""
    d = _dir(base_dir)
    token_id = secrets.token_hex(8)
    secret = secrets.token_urlsafe(32)
    rec = {
        "token_id": token_id,
        "enrollment_id": enrollment_id,
        "repos": list(scope.repos),
        "push_branch": scope.push_branch,
        "secret_hash": _hash(secret),
        "expires_at": clock() + ttl_seconds,
    }
    path = d / f"{token_id}.json"
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(rec))
    tmp.replace(path)
    return f"{token_id}.{secret}"


def verify_run_token(
    base_dir, presented: str, *, clock: Callable[[], float] = time.time,
) -> RunToken | None:
    """Return the RunToken for a valid, unexpired presented token, else None."""
    if "." not in presented:
        return None
    token_id, secret = presented.split(".", 1)
    if not _ID_RE.match(token_id):
        return None
    path = _dir(base_dir) / f"{token_id}.json"
    try:
        rec = json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return None
    if not hmac.compare_digest(_hash(secret), rec.get("secret_hash", "")):
        return None
    if clock() >= rec.get("expires_at", 0):
        return None
    return RunToken(
        token_id=token_id,
        enrollment_id=rec["enrollment_id"],
        scope=Scope(repos=tuple(rec.get("repos", [])), push_branch=rec.get("push_branch")),
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/relay/test_run_token.py -v`
Expected: PASS (5 passed).

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/relay/run_token.py tests/core/relay/test_run_token.py
git commit -m "feat(relay): per-run token — issue plaintext-once, hmac verify, expiry"
mship journal "added issue/verify_run_token (hash-only persist, hmac, expiry, rotation); tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=10 -->
### Task 10: Egress-proxy app — verify → route → enforce → provider → attach → forward (+ fail-closed)

The assembly and the distinct **egress-proxy role** module (ac8). Worker auth is verified here end-to-end (the run token, not "the relay says so"). Fail-closed when no provider is configured (App creds absent → 503, never forward).

**Files:**
- Create: `src/mship/core/relay/egress/proxy.py`
- Test: `tests/core/relay/egress/test_proxy.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/core/relay/egress/test_proxy.py
import httpx
from fastapi.testclient import TestClient
from mship.core.relay.grants import Grant, GrantStore, Scope
from mship.core.relay.run_token import issue_run_token
from mship.core.relay.egress.credential import Credential, github_token_attachment
from mship.core.relay.egress.routes import build_default_routes
from mship.core.relay.egress.proxy import build_egress_app


def pkt(payload: bytes) -> bytes:
    return b"%04x" % (len(payload) + 4) + payload


def _push_body(ref="refs/heads/feat/x") -> bytes:
    line = f"{'0'*40} {'a'*40} {ref}\x00 report-status-v2\n".encode()
    return pkt(line) + b"0000" + b"PACKxxxx"


class _StubProvider:
    """Returns a fixed credential without touching GitHub (gh_app is tested in
    Task 6). Records that resolve() was called with the run's repo."""
    def __init__(self):
        self.calls = []

    def resolve(self, identity, grant, request):
        self.calls.append((identity, tuple(grant.scope.repos), request.repo))
        return Credential(value="ghs_minted", expires_at=None, attach=github_token_attachment())


def _capture_upstream(seen: dict) -> httpx.Client:
    def handler(request: httpx.Request) -> httpx.Response:
        seen["host"] = request.url.host
        seen["authorization"] = request.headers.get("Authorization")
        seen["run_token"] = request.headers.get("Mship-Run-Token")
        return httpx.Response(200, content=b"ok-from-github")
    return httpx.Client(transport=httpx.MockTransport(handler))


def _app(tmp_path, provider, client):
    gs = GrantStore(tmp_path)
    gs.set_grant("enr1", Grant("github-app", Scope(repos=("acme/api", "acme/web"))))
    routes = build_default_routes(provider) if provider else None
    return build_egress_app(
        grant_store=gs, run_token_dir=tmp_path, routes=routes, client=client,
    ), tmp_path


def _token(tmp_path):
    return issue_run_token(tmp_path, enrollment_id="enr1",
                           scope=Scope(repos=("acme/api",), push_branch="feat/x"),
                           ttl_seconds=3600)


def test_push_to_run_branch_attaches_token_and_strips_placeholder(tmp_path):
    seen: dict = {}
    provider = _StubProvider()
    app, base = _app(tmp_path, provider, _capture_upstream(seen))
    token = _token(base)
    client = TestClient(app)
    resp = client.post(
        "/gh/acme/api.git/git-receive-pack",
        content=_push_body(),
        headers={"Mship-Run-Token": token, "Content-Type": "application/x-git-receive-pack-request"},
    )
    assert resp.status_code == 200
    assert resp.content == b"ok-from-github"
    assert seen["host"] == "github.com"
    assert seen["authorization"] == "token ghs_minted"     # real cred attached at egress
    assert seen["run_token"] is None                       # placeholder never leaves the relay
    assert provider.calls == [("enr1", ("acme/api",), "acme/api")]


def test_push_to_other_branch_is_rejected_before_egress(tmp_path):
    seen: dict = {}
    app, base = _app(tmp_path, _StubProvider(), _capture_upstream(seen))
    token = _token(base)
    resp = TestClient(app).post(
        "/gh/acme/api.git/git-receive-pack",
        content=_push_body(ref="refs/heads/main"),
        headers={"Mship-Run-Token": token},
    )
    assert resp.status_code == 403
    assert seen == {}                                       # never forwarded


def test_missing_or_invalid_run_token_is_401(tmp_path):
    app, base = _app(tmp_path, _StubProvider(), _capture_upstream({}))
    c = TestClient(app)
    assert c.post("/gh/acme/api.git/git-receive-pack", content=_push_body()).status_code == 401
    assert c.post("/gh/acme/api.git/git-receive-pack", content=_push_body(),
                  headers={"Mship-Run-Token": "bogus.secret"}).status_code == 401


def test_no_provider_fails_closed_503(tmp_path):
    app, base = _app(tmp_path, None, _capture_upstream({}))
    token = _token(base)
    resp = TestClient(app).post("/gh/acme/api.git/git-receive-pack",
                                content=_push_body(), headers={"Mship-Run-Token": token})
    assert resp.status_code == 503


def test_clone_upload_pack_passes_and_attaches(tmp_path):
    seen: dict = {}
    app, base = _app(tmp_path, _StubProvider(), _capture_upstream(seen))
    token = _token(base)
    resp = TestClient(app).get(
        "/gh/acme/api.git/info/refs?service=git-upload-pack",
        headers={"Mship-Run-Token": token},
    )
    assert resp.status_code == 200
    assert seen["authorization"] == "token ghs_minted"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/core/relay/egress/test_proxy.py -v`
Expected: FAIL — `ModuleNotFoundError: mship.core.relay.egress.proxy`.

- [ ] **Step 3: Write minimal implementation**

```python
# src/mship/core/relay/egress/proxy.py
from __future__ import annotations

import httpx
from fastapi import FastAPI, Request, Response

from mship.core.relay.grants import Grant, GrantStore, Scope
from mship.core.relay.run_token import verify_run_token
from mship.core.relay.egress.credential import AttachmentHostError
from mship.core.relay.egress.enforce import EnforcementError
from mship.core.relay.egress.provider import ProviderError
from mship.core.relay.egress.request import parse_egress_request, UnmappablePathError
from mship.core.relay.egress.routes import RouteTable, UnknownHostError

# Headers we must never pass upstream: the worker's placeholder token, the
# worker-facing Host, and length/encoding httpx recomputes for the new body.
_STRIP = {"mship-run-token", "host", "content-length", "authorization",
          "transfer-encoding", "connection"}


def build_egress_app(
    *, grant_store: GrantStore, run_token_dir, routes: RouteTable | None,
    client: httpx.Client | None = None, upstream_scheme: str = "https",
) -> FastAPI:
    """The egress-proxy role. `routes=None` (App creds absent) => fail closed:
    every request 503, never forward — mirrors serve's refuse-on-unreadable-key."""
    app = FastAPI(title="mship egress proxy")
    http = client or httpx.Client(timeout=60)

    @app.api_route("/{full_path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE"])
    async def egress(full_path: str, request: Request) -> Response:
        if routes is None:
            return Response("egress: no credential provider configured (App creds "
                            "absent) — refusing to forward", status_code=503)

        presented = request.headers.get("Mship-Run-Token")
        if not presented:
            return Response("missing run token", status_code=401)
        rt = verify_run_token(run_token_dir, presented)
        if rt is None:
            return Response("invalid or expired run token", status_code=401)

        body = await request.body()
        try:
            egress_req = parse_egress_request(
                method=request.method, path=request.url.path,
                query=request.url.query, headers=dict(request.headers), body=body,
            )
        except UnmappablePathError:
            return Response("unmapped path", status_code=404)

        # Ceiling: the enrollment's typed grant for this provider.
        ceiling = next((g for g in grant_store.get_grants(rt.enrollment_id)
                        if g.provider == "github-app"), None)
        if ceiling is None:
            return Response("no grant for enrollment", status_code=403)
        # Per-run scope must be within the ceiling.
        if not ceiling.scope.covers(rt.scope):
            return Response("run scope exceeds enrollment grant", status_code=403)
        effective = Grant("github-app", rt.scope)

        try:
            route = routes.resolve(egress_req.upstream_host)
            route.enforcer.check(egress_req, effective)
            cred = route.provider.resolve(
                identity=rt.enrollment_id, grant=effective, request=egress_req,
            )
        except UnknownHostError:
            return Response("no route for host", status_code=404)
        except EnforcementError as e:
            return Response(f"rejected: {e}", status_code=403)
        except ProviderError as e:
            return Response(f"provider error: {e}", status_code=502)

        upstream_headers = {k: v for k, v in egress_req.headers.items()
                            if k.lower() not in _STRIP}
        try:
            cred.attach.apply(upstream_headers, host=egress_req.upstream_host, value=cred.value)
        except AttachmentHostError as e:
            return Response(f"attach refused: {e}", status_code=500)

        url = f"{upstream_scheme}://{egress_req.upstream_host}{egress_req.upstream_path}"
        if egress_req.query:
            url = f"{url}?{egress_req.query}"
        upstream = http.request(request.method, url, headers=upstream_headers, content=body)
        # Pass the upstream response back verbatim (drop hop-by-hop headers).
        resp_headers = {k: v for k, v in upstream.headers.items()
                        if k.lower() not in ("content-length", "transfer-encoding", "connection")}
        return Response(content=upstream.content, status_code=upstream.status_code,
                        headers=resp_headers)

    return app
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/core/relay/egress/test_proxy.py -v`
Expected: PASS (5 passed).

> **Operational note (record in the journal, not a blocker):** the forward uses a sync `httpx.Client` inside an async route, so v1 serves one upstream request at a time per worker — fine for the fan-out's push cadence and matches `gh_app`'s injectable-client test pattern; a threadpool/async-client upgrade is a later perf change. Also v1 buffers the request body (needed to parse the receive-pack command list) and the response; a very large clone response is held in memory — note streaming (`http.stream`) as a follow-up if clones grow.

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/relay/egress/proxy.py tests/core/relay/egress/test_proxy.py
git commit -m "feat(egress): egress-proxy app — verify/route/enforce/provider/attach/forward, fail-closed"
mship journal "added build_egress_app (attach-at-egress, strips placeholder, 503 when no provider); tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=11 -->
### Task 11: `mship relay grant` + `mship relay issue-run-token` CLI

**Files:**
- Modify: `src/mship/cli/relay.py`
- Test: `tests/cli/test_relay_grant.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/cli/test_relay_grant.py
from pathlib import Path
from typer.testing import CliRunner
import typer

from mship.cli import relay as relay_cli
from mship.core.relay.enroll import RequestStore
from mship.core.relay.grants import GrantStore
from mship.core.relay.run_token import verify_run_token


def _app():
    app = typer.Typer()
    relay_cli.register(app, get_container=lambda: None)
    return app


def _approved_enrollment(tmp_path: Path) -> str:
    """Create + approve an enrollment so its id resolves as 'approved'."""
    store = RequestStore(tmp_path / "pending-store")
    rid = store.create(
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLE0", "worker",
    )
    store.approve(rid, tmp_path / "pubkeys")
    return rid


def test_grant_sets_typed_grant_for_approved_enrollment(tmp_path: Path):
    rid = _approved_enrollment(tmp_path)
    result = CliRunner().invoke(_app(), [
        "relay", "grant", rid,
        "--provider", "github-app", "--repos", "acme/api,acme/web",
        "--store-dir", str(tmp_path / "pending-store"),
        "--grant-store-dir", str(tmp_path / "grants-store"),
    ])
    assert result.exit_code == 0, result.output
    grants = GrantStore(tmp_path / "grants-store").get_grants(rid)
    assert set(grants[0].scope.repos) == {"acme/api", "acme/web"}


def test_grant_rejects_unknown_enrollment(tmp_path: Path):
    result = CliRunner().invoke(_app(), [
        "relay", "grant", "deadbeef",
        "--provider", "github-app", "--repos", "acme/api",
        "--store-dir", str(tmp_path / "pending-store"),
        "--grant-store-dir", str(tmp_path / "grants-store"),
    ])
    assert result.exit_code != 0


def test_issue_run_token_within_ceiling_prints_token(tmp_path: Path):
    rid = _approved_enrollment(tmp_path)
    GrantStore(tmp_path / "grants-store").set_grant(
        rid, __import__("mship.core.relay.grants", fromlist=["Grant", "Scope"]).Grant(
            "github-app",
            __import__("mship.core.relay.grants", fromlist=["Scope"]).Scope(repos=("acme/api", "acme/web")),
        ),
    )
    result = CliRunner().invoke(_app(), [
        "relay", "issue-run-token", rid,
        "--repos", "acme/api", "--push-branch", "feat/x",
        "--grant-store-dir", str(tmp_path / "grants-store"),
        "--run-token-dir", str(tmp_path / "run-tokens-store"),
    ])
    assert result.exit_code == 0, result.output
    token = result.output.strip().split()[-1]              # last token printed
    rt = verify_run_token(tmp_path / "run-tokens-store", token)
    assert rt is not None and rt.enrollment_id == rid


def test_issue_run_token_repo_outside_ceiling_fails(tmp_path: Path):
    rid = _approved_enrollment(tmp_path)
    GrantStore(tmp_path / "grants-store").set_grant(
        rid, __import__("mship.core.relay.grants", fromlist=["Grant", "Scope"]).Grant(
            "github-app",
            __import__("mship.core.relay.grants", fromlist=["Scope"]).Scope(repos=("acme/api",)),
        ),
    )
    result = CliRunner().invoke(_app(), [
        "relay", "issue-run-token", rid,
        "--repos", "acme/secret", "--push-branch", "feat/x",
        "--grant-store-dir", str(tmp_path / "grants-store"),
        "--run-token-dir", str(tmp_path / "run-tokens-store"),
    ])
    assert result.exit_code != 0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/cli/test_relay_grant.py -v`
Expected: FAIL — `No such command 'grant'` (exit code 2).

- [ ] **Step 3: Write minimal implementation** — add both commands inside `register(...)` in `src/mship/cli/relay.py`, next to `approve`/`deny`:

```python
    # ---- typed grants + per-run tokens (cloud-worker-auth-spine) ----

    @relay_app.command("grant")
    def grant_cmd(
        rid: str = typer.Argument(..., help="Approved enrollment id to grant repos to."),
        provider: str = typer.Option("github-app", "--provider", help="Credential provider."),
        repos: str = typer.Option(..., "--repos", help="Ceiling repos owner/a,owner/b."),
        store_dir: str = typer.Option("./pending-store", "--store-dir",
                                      help="Enroll request store (to confirm approval)."),
        grant_store_dir: str = typer.Option("./grants-store", "--grant-store-dir",
                                            help="Directory for the typed-grant store."),
    ):
        """Set/update an enrollment's typed grant (the repo CEILING it may ever touch)."""
        from pathlib import Path

        from mship.core.relay.enroll import RequestStore
        from mship.core.relay.grants import Grant, GrantStore, Scope

        out = Output()
        if RequestStore(Path(store_dir)).get(rid) != "approved":
            out.error(f"enrollment {rid!r} is not an approved enrollment")
            raise typer.Exit(1)
        repo_list = tuple(r.strip() for r in repos.split(",") if r.strip())
        if not repo_list:
            out.error("--repos must list at least one owner/repo")
            raise typer.Exit(1)
        GrantStore(Path(grant_store_dir)).set_grant(
            rid, Grant(provider=provider, scope=Scope(repos=repo_list))
        )
        out.success(f"granted {provider} {list(repo_list)} to enrollment {rid}")

    @relay_app.command("issue-run-token")
    def issue_run_token_cmd(
        rid: str = typer.Argument(..., help="Approved+granted enrollment id."),
        repos: str = typer.Option(..., "--repos", help="Run repos (⊆ the grant ceiling)."),
        push_branch: str = typer.Option(..., "--push-branch", help="The run's branch, e.g. feat/<slug>."),
        ttl: int = typer.Option(86400, "--ttl", help="Token TTL in seconds (default 24h)."),
        grant_store_dir: str = typer.Option("./grants-store", "--grant-store-dir",
                                            help="Directory for the typed-grant store."),
        run_token_dir: str = typer.Option("./run-tokens-store", "--run-token-dir",
                                           help="Directory for per-run token records."),
    ):
        """Issue a per-run token {repos ⊆ ceiling, push_branch}; prints plaintext ONCE."""
        from pathlib import Path

        from mship.core.relay.grants import GrantStore, Scope
        from mship.core.relay.run_token import issue_run_token

        out = Output()
        ceiling = next((g for g in GrantStore(Path(grant_store_dir)).get_grants(rid)
                        if g.provider == "github-app"), None)
        if ceiling is None:
            out.error(f"enrollment {rid!r} has no github-app grant; run `mship relay grant` first")
            raise typer.Exit(1)
        run_scope = Scope(repos=tuple(r.strip() for r in repos.split(",") if r.strip()),
                          push_branch=push_branch)
        if not ceiling.scope.covers(run_scope):
            out.error(f"requested repos exceed the grant ceiling {list(ceiling.scope.repos)}")
            raise typer.Exit(1)
        token = issue_run_token(Path(run_token_dir), enrollment_id=rid,
                                scope=run_scope, ttl_seconds=ttl)
        out.print(f"run token (store on the worker, shown once): {token}")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/cli/test_relay_grant.py -v`
Expected: PASS (4 passed).

- [ ] **Step 5: Commit**

```bash
git add src/mship/cli/relay.py tests/cli/test_relay_grant.py
git commit -m "feat(cli): mship relay grant + issue-run-token"
mship journal "added relay grant (ceiling) + issue-run-token (per-run, ⊆ ceiling, plaintext once); tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=12 -->
### Task 12: `mship relay egress-server` + deploy wiring (Caddy, tls_ask, docker env, fail-closed)

Stand the egress-proxy role up as a host process (like `enroll-server`), Caddy-front `egress.<domain>`, and read App creds with the same refuse-on-unreadable discipline as serve.

**Files:**
- Modify: `src/mship/core/relay/tls_ask.py`, `src/mship/cli/relay.py`, `docker/relay/Caddyfile`, `docker/relay/docker-compose.yml`
- Test: `tests/core/relay/test_tls_ask.py` (extend), `tests/cli/test_relay_egress_server.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/core/relay/test_tls_ask.py  (append)
from mship.core.relay.tls_ask import tls_ask_allowed

def test_egress_label_is_allowed():
    assert tls_ask_allowed("egress.relay.example.com", "relay.example.com") is True
```

```python
# tests/cli/test_relay_egress_server.py
from pathlib import Path
import typer
from typer.testing import CliRunner

from mship.cli import relay as relay_cli


def _app():
    app = typer.Typer()
    relay_cli.register(app, get_container=lambda: None)
    return app


def test_egress_server_builds_provider_and_hands_off_to_uvicorn(tmp_path, monkeypatch):
    captured = {}
    monkeypatch.setattr(relay_cli, "_run_uvicorn",
                        lambda app, host, port: captured.update(app=app, host=host, port=port))
    monkeypatch.setenv("MSHIP_GH_APP_ID", "123")
    key = tmp_path / "app.pem"
    key.write_text("-----BEGIN PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----\n")
    monkeypatch.setenv("MSHIP_GH_APP_KEY", str(key))
    result = CliRunner().invoke(_app(), [
        "relay", "egress-server",
        "--grant-store-dir", str(tmp_path / "grants-store"),
        "--run-token-dir", str(tmp_path / "run-tokens-store"),
        "--port", "47280",
    ])
    assert result.exit_code == 0, result.output
    assert captured["port"] == 47280 and captured["app"] is not None


def test_egress_server_refuses_unreadable_key(tmp_path, monkeypatch):
    monkeypatch.setattr(relay_cli, "_run_uvicorn", lambda *a, **k: None)
    monkeypatch.setenv("MSHIP_GH_APP_ID", "123")
    monkeypatch.setenv("MSHIP_GH_APP_KEY", str(tmp_path / "does-not-exist.pem"))
    result = CliRunner().invoke(_app(), [
        "relay", "egress-server",
        "--grant-store-dir", str(tmp_path / "grants-store"),
        "--run-token-dir", str(tmp_path / "run-tokens-store"),
    ])
    assert result.exit_code != 0
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `uv run pytest tests/core/relay/test_tls_ask.py::test_egress_label_is_allowed tests/cli/test_relay_egress_server.py -v`
Expected: FAIL — `test_egress_label_is_allowed` fails (returns False) and `No such command 'egress-server'`.

- [ ] **Step 3a: Allow the `egress` label** in `src/mship/core/relay/tls_ask.py` — extend the enroll check:

```python
    if label in ("enroll", "egress"):
        return True
```
(Replace the existing `if label == "enroll": return True` line.)

- [ ] **Step 3b: Add `egress-server`** inside `register(...)` in `src/mship/cli/relay.py` (reuses `_run_uvicorn`; mirrors `_read_gh_app_creds` refuse-on-unreadable):

```python
    @relay_app.command("egress-server")
    def egress_server(
        grant_store_dir: str = typer.Option("./grants-store", "--grant-store-dir",
                                             help="Directory for the typed-grant store."),
        run_token_dir: str = typer.Option("./run-tokens-store", "--run-token-dir",
                                           help="Directory for per-run token records."),
        port: int = typer.Option(47280, "--port", help="Port to listen on (Caddy fronts it)."),
        host: str = typer.Option("127.0.0.1", "--host", help="Interface to bind (loopback)."),
    ):
        """Run the credential-attaching egress proxy (worker git/API traffic terminates here)."""
        import os
        from pathlib import Path

        from mship.core.relay.grants import GrantStore
        from mship.core.relay.egress.provider import GitHubAppProvider
        from mship.core.relay.egress.routes import build_default_routes
        from mship.core.relay.egress.proxy import build_egress_app

        out = Output()
        app_id = os.environ.get("MSHIP_GH_APP_ID") or None
        app_key = None
        key_path = os.environ.get("MSHIP_GH_APP_KEY")
        if key_path:
            p = Path(key_path)
            if not p.is_file():
                out.error(
                    f"MSHIP_GH_APP_KEY is set but not a readable file ({key_path!r}). "
                    "Refusing to start: silently forwarding without a real credential "
                    "would defeat attach-at-relay."
                )
                raise typer.Exit(1)
            app_key = p.read_text()

        # Fail closed: no App creds => no provider => the app 503s every request.
        routes = None
        if app_id and app_key:
            provider = GitHubAppProvider(app_id=app_id, private_key=app_key)
            routes = build_default_routes(provider)
        else:
            out.warning("no App creds (MSHIP_GH_APP_ID/MSHIP_GH_APP_KEY) — egress will "
                        "refuse to forward (503) until configured.")

        app = build_egress_app(
            grant_store=GrantStore(Path(grant_store_dir)),
            run_token_dir=Path(run_token_dir), routes=routes,
        )
        out.print(f"egress-server → http://{host}:{port}")
        _run_uvicorn(app, host, port)
```

- [ ] **Step 3c: Caddy block** — add to `docker/relay/Caddyfile` (above the `*.{$RELAY_DOMAIN}` wildcard so it wins):

```caddyfile
# Egress proxy — worker git/API traffic, credential attached at egress.
egress.{$RELAY_DOMAIN} {
	tls {
		on_demand
	}
	reverse_proxy 127.0.0.1:47280 {
		header_up Host {host}
	}
}
```

- [ ] **Step 3d: docker-compose env note** — in `docker/relay/docker-compose.yml`, document the App-creds + store dirs the host `egress-server` needs (the egress-server, like `enroll-server`, runs as a host process, not a compose service):

```yaml
# Egress proxy (run on the host: `mship relay egress-server`) needs, in its env:
#   MSHIP_GH_APP_ID   — the GitHub App numeric id
#   MSHIP_GH_APP_KEY  — PATH to the App private-key .pem (refuse-on-unreadable)
# and persistent dirs for --grant-store-dir and --run-token-dir alongside pubkeys/.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `uv run pytest tests/core/relay/test_tls_ask.py tests/cli/test_relay_egress_server.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/mship/core/relay/tls_ask.py src/mship/cli/relay.py docker/relay/Caddyfile \
        docker/relay/docker-compose.yml tests/core/relay/test_tls_ask.py \
        tests/cli/test_relay_egress_server.py
git commit -m "feat(relay): egress-server CLI + Caddy/tls_ask deploy wiring, fail-closed on creds"
mship journal "added egress-server (fail-closed on absent/unreadable App creds) + Caddy egress route + tls_ask egress label; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=13 -->
### Task 13: Documentation — trust model + four seams + worker config

Pure docs (no test). Captures ac10 (trust model / north star / fork-not-ladder / seams admit GitLab+static) and the operator-facing worker + deploy setup, and makes the egress-proxy module boundary explicit (ac8).

**Files:**
- Create: `docs/cloud-worker-auth-spine.md`

- [ ] **Step 1: Write the doc** with these required sections:

1. **Trust model.** Worker = least trusted (disposable + prompt-injectable): holds only a placeholder + a low-value per-run token, never a GitHub credential. Relay/front door = trusted transport in v1 (Shape 2). Secrets-egress host = the small trusted core doing exchange + attach + enforce + provider egress. Containment rests on: credential never on the worker; receive-pack enforcer restricts pushes to the run branch; App token repo-scoped + short TTL; host-locked attachment.
2. **Attach-at-relay, Shape 2 (co-located).** All roles on the one relay the operator runs. State plainly that some host must see plaintext for a bearer credential (unavoidable) — the design minimizes and isolates it.
3. **North star: the untrusted-relay 3-role split** (worker / blind relay / separate secrets-egress host). Because the egress-proxy is a distinct module whose worker session terminates at it (verified by the per-run token end-to-end), relocating it to its own host behind a now-blind relay is a **deployment/wiring change, not a channel rewrite**. **Shape 2 vs Shape 3 is a FORK, not a ladder** — they defend different adversaries (worker-least-trusted vs relay-operator-least-trusted); **seal-to-worker / HPKE is retired** by attach-at-relay.
4. **The four seams and how they admit GitLab / static secrets with ZERO worker change:** `CredentialProvider` (add `GitLabProvider` / `StaticSecretProvider`), `Attachment` (different header/host-lock, e.g. `Authorization: Bearer` locked to `api.openai.com`), `RouteTable` (a new host entry), typed `Grant`s (a new provider scope). Note the security asymmetry: an App token has built-in TTL/scope; a static third-party key has none, so the off-box boundary is its ONLY backstop — the generalization strengthens attach-at-relay.
5. **Operator setup** (mirror the Task 11/12 commands): approve the enrollment → `mship relay grant <id> --provider github-app --repos owner/a,owner/b` (ceiling) → `mship relay issue-run-token <id> --repos owner/a --push-branch feat/<slug>` (per-run, printed once) → run `mship relay egress-server` with `MSHIP_GH_APP_ID`/`MSHIP_GH_APP_KEY` set → Caddy fronts `egress.<domain>`.
6. **Worker config (the placeholder)** — the exact git config from the "proxy mechanism" section of this plan (`url.…insteadOf` for `/gh/` + `/api/`, `http.…extraHeader` carrying `Mship-Run-Token`). State explicitly: the worker holds no usable GitHub credential; the per-run token presented directly to GitHub is rejected, and to the relay only unlocks a run-branch push to the run's repos.
7. **Egress-proxy module boundary** — name the modules (`core/relay/egress/*`) and that the worker's session logically terminates at `build_egress_app`, authenticated by the per-run token it verifies itself.

- [ ] **Step 2: Verify the doc renders and links resolve**

Run: `python -c "import pathlib,sys; t=pathlib.Path('docs/cloud-worker-auth-spine.md').read_text(); sys.exit(0 if all(s in t for s in ['Trust model','fork','seams','insteadOf','egress-server']) else 1)"`
Expected: exit 0 (the required section keywords are present).

- [ ] **Step 3: Commit**

```bash
git add docs/cloud-worker-auth-spine.md
git commit -m "docs: cloud-worker-auth-spine trust model + four seams + worker/deploy setup"
mship journal "wrote trust-model + four-seams + worker-config doc (ac8/ac10)" --action committed
```
<!-- /mship:task -->

---

## Full-suite gate (after Task 13)

Run the relay + egress + CLI suites together to confirm nothing regressed:

Run: `uv run pytest tests/core/relay tests/cli/test_relay_grant.py tests/cli/test_relay_egress_server.py -q`
Expected: all green. Then `mship test` for the mothership repo before `mship finish`.

---

## Self-Review

### AC → task coverage map

The spec's `acceptance_criteria` list ids are `ac1..ac10`; several carry a shuffled bracket label (shown in parentheses). Mapping by list id:

- **ac1** (placeholder worker clones/fetches/pushes through relay; real token attached at egress; direct placeholder fails) → **Task 10** (integration: attaches `token ghs_minted`, strips `Mship-Run-Token`, forwards; the run token is not a GitHub bearer) + worker config in **Task 13**.
- **ac2** (receive-pack enforcer: only run branch per run-repo; cross-repo same branch; upload-pack passes) → **Task 4** (built on the parser in **Task 3**).
- **ac3** (route table host → {provider, enforcer}, no hardcoded github.com; github.com + api.github.com; add-a-host = config) → **Task 7** (+ host map in **Task 2**).
- **ac4** (CredentialProvider seam; `GitHubAppProvider.resolve` scoped to grant repos; refuse out-of-grant/empty; admits future providers) → **Task 6**.
- **ac5** (Attachment: `Authorization: token`, host-locked to github.com/api.github.com; refuse other host) → **Task 5** (enforced at forward in **Task 10**).
- **ac6** (enrollment TYPED grants = ceiling; pubkey identity → persisted queryable {provider, scope}; `mship relay grant`; unknown/unapproved errors) → **Task 8** (store) + **Task 11** (CLI + approval check).
- **ac7** (label [ac10]: per-run token {repos ⊆ grant, push_branch}; plaintext once + hash persisted; rotate; expiry; enforcer reads {repos, push_branch}; issue path; out-of-ceiling / branch-mismatch refused) → **Task 9** (issue/verify) + **Task 11** (issue CLI, ⊆-ceiling check) + **Task 4** (enforcer reads scope).
- **ac8** (label [ac7]: egress-proxy distinct module; worker session terminates at it; end-to-end verifiable auth; relocatable = deploy change; documented) → **Task 10** (module + token-verified) + **Task 13** (boundary documented).
- **ac9** (label [ac8]: fail-closed on absent/unreadable App creds; deploy wiring — Caddy route, tls_ask entry, creds/store location) → **Task 12** (+ 503-on-no-provider in **Task 10**).
- **ac10** (label [ac9]: docs — trust model, north-star 3-role split, Shape 2 vs 3 fork, seal-to-worker retired, four seams admit GitLab/static later) → **Task 13**.

All ten covered. Spec Testing section (pure parser vs recorded wire samples, route resolution, provider mocked, attachment host-lock, grant store, per-run token, proxy integration with GitHub mocked, fail-closed) maps to Tasks 3/2, 7, 6, 5, 8, 9, 10 respectively — no live relay/GitHub/App key in any test.

### Placeholder scan

No `TBD`/`add error handling`/`similar to Task N` placeholders — every task ships real test code and real implementation code. Each git-wire test uses a real captured command line (`refs/heads/feat/demo`, oid `0cee56ac…`) framed by an in-test `pkt()` helper.

### Type-name consistency (locked across tasks)

- `Scope(repos: tuple[str,...], push_branch: str | None)`, `.covers(other)` — Tasks 1, 4, 6, 8, 9, 11.
- `Grant(provider, scope)` — Tasks 1, 4, 6, 7, 8, 10, 11.
- `GrantStore(base_dir)`: `set_grant(enrollment_id, grant)`, `get_grants(enrollment_id) -> list[Grant]` — Tasks 8, 10, 11, 12.
- `RunToken(token_id, enrollment_id, scope)`, `issue_run_token(base_dir, *, enrollment_id, scope, ttl_seconds, clock)`, `verify_run_token(base_dir, presented, *, clock)` — Tasks 9, 10, 11, 12.
- `RefUpdate(old_oid, new_oid, ref)`, `read_pkt_lines`, `parse_receive_pack_commands` — Tasks 3, 4.
- `EgressRequest`, `parse_egress_request(*, method, path, query, headers, body)` with `.upstream_host/.upstream_path/.repo/.service/.is_receive_pack_post`, `UnmappablePathError` — Tasks 2, 4, 6, 10.
- `Enforcer` (Protocol) `.check(request, grant)`, `GitSmartHttpEnforcer`, `HostLockedEnforcer`, `EnforcementError` — Tasks 4, 7, 10.
- `Credential(value, expires_at, attach)`, `Attachment(header, template, hosts)` `.render/.apply(headers,*,host,value)`, `AttachmentHostError`, `github_token_attachment()` — Tasks 5, 6, 10.
- `CredentialProvider` (Protocol) `.resolve(identity, grant, request)`, `GitHubAppProvider(*, app_id, private_key, client=None)`, `ProviderError` — Tasks 6, 7, 10, 12.
- `Route(provider, enforcer)`, `RouteTable(routes)` `.resolve(host)`, `UnknownHostError`, `build_default_routes(provider)` — Tasks 7, 10, 12.
- `build_egress_app(*, grant_store, run_token_dir, routes, client=None, upstream_scheme="https")` — Tasks 10, 12.

Signatures are consistent everywhere they recur.
</content>
</invoke>
