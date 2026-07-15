# Cloud-agent GitHub auth — runtime token broker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Spec:** `cloud-agent-github-auth` (specs/2026-07-11-cloud-agent-github-auth.md) — approved. Closes MOS-226.

**Goal:** Cloud/unattended agents pull a fresh, multi-repo-scoped GitHub token at runtime from a broker (never carry a PAT). Two broker homes behind `resolve_token`: **A** (`mship serve` proxies the host `gh auth token`) and **B** (a relay service minting short-lived GitHub App installation tokens), with `--token`/`GH_TOKEN` as fallbacks.

**Architecture:** The merged cloud-auth work already funnels everything through `resolve_token` (`core/gh_auth.py`) and reuses `git_cred_args` (env-only credential helper) + `create_pr_via_httpx` (REST PR). The broker only has to *produce a token scoped to the right repos*; downstream is untouched.

**Tech Stack:** Python (FastAPI serve, httpx, PyJWT [new], pytest). Single repo: mothership. **Work from:** `.worktrees/cloud-agent-github-auth/mothership`.

**Operator-setup dependency (not code):** Broker B requires the operator to create a GitHub App, install it on all workspace repos, and place its id + private key on the relay. All code here is built with **mocked GitHub API** unit tests; the live App wiring is a one-time operator step (documented in Task 6).

**Operator requirement (from spec q1 answer) — FAIL FAST:** an overnight run must NOT do work then fail to push because the App isn't on a repo. So the token for the **full repo set** is requested **upfront** (bootstrap) and there is a **preflight** command (Task 5) that verifies mint-for-all-repos before any AI work — aborting with a clear error naming any uncovered repo.

**Key references (from the codebase map):**
- `core/gh_auth.py`: `resolve_token(explicit)` (:23-28, precedence `--token>GH_TOKEN>GITHUB_TOKEN`), `git_cred_args(token)` (:15-36, env-only helper), `create_pr_via_httpx` (:49-84). Call sites: `core/bootstrap.py:105`, `cli/worktree.py:1148`.
- `core/serve.py`: `create_app(...)` (:127-638), bearer dep `_make_auth_dependency` (:91-102) applied app-wide, endpoint closures `@app.get(...)`. `ShellRunner` at `util/shell.py:14-40`.
- Relay: `core/relay/enroll_app.py` (FastAPI pattern), `cli/relay.py` `enroll-server` command (uvicorn on loopback), `docker/relay/Caddyfile` (`enroll.{domain}` hardened route), `docker/relay/docker-compose.yml`.
- No existing GitHub App/JWT code (greenfield). `pyproject.toml:14-17` has fastapi/uvicorn/httpx; PyJWT must be added.

---

<!-- mship:task id=1 -->
### Task 1: GitHub App installation-token minting (core, pure + mocked)

**Files:** Create `src/mship/core/gh_app.py`; Test `tests/core/test_gh_app.py`; Modify `pyproject.toml` (add `pyjwt[crypto]`).

- [ ] **Step 1: Add the dep.** Add `"pyjwt[crypto]>=2.8"` to `pyproject.toml` dependencies; `uv sync`.

- [ ] **Step 2: Failing tests** (mock httpx so no network): a successful mint signs an App JWT (RS256, `iss`=app_id, `iat`/`exp` ~10min) and POSTs `/app/installations/{id}/access_tokens` with `{"repositories": [...]}`, returning `{token, expires_at}`; a GitHub 422/403 naming an uninstalled repo raises `GhAppError` whose message names the uncovered repo; the token value never appears in the error/log.

```python
# tests/core/test_gh_app.py (sketch — mock httpx.Client.post)
from mship.core.gh_app import mint_installation_token, GhAppError
```

- [ ] **Step 3: Implement `gh_app.py`.**

```python
"""Mint short-lived, repo-scoped GitHub App installation tokens (Broker B)."""
from __future__ import annotations
import time, httpx, jwt  # PyJWT

class GhAppError(Exception): ...

def _app_jwt(app_id: str, private_key: str, now: int | None = None) -> str:
    now = now or int(time.time())
    return jwt.encode({"iat": now - 60, "exp": now + 540, "iss": app_id}, private_key, algorithm="RS256")

def mint_installation_token(*, app_id, private_key, installation_id, repos, now=None, client=None):
    """Return {"token", "expires_at", "repositories"} scoped to `repos`
    (list of short repo names). Raises GhAppError with a repo-naming message
    if the App can't cover the request. Never logs/returns the private key."""
    token_jwt = _app_jwt(app_id, private_key, now)
    body = {"repositories": list(repos)} if repos else {}
    c = client or httpx.Client(timeout=15)
    try:
        r = c.post(
            f"https://api.github.com/app/installations/{installation_id}/access_tokens",
            headers={"Authorization": f"Bearer {token_jwt}", "Accept": "application/vnd.github+json"},
            json=body,
        )
    except httpx.HTTPError as e:
        raise GhAppError(f"gh-app: request failed: {e}") from e
    if r.status_code == 201:
        d = r.json()
        return {"token": d["token"], "expires_at": d.get("expires_at"), "repositories": repos}
    # 422 = a requested repo isn't in the installation; surface which repos were asked for.
    raise GhAppError(f"gh-app: mint failed ({r.status_code}) for repos {list(repos)}: {r.text[:300]}")
```

- [ ] **Step 4: Green** — `uv run pytest tests/core/test_gh_app.py -v`, then `mship test`.
- [ ] **Step 5: Commit + journal** (`mship journal "gh-app installation-token minting (JWT + repositories scope); tests passing" --action committed`).
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: `GET /gh-token` contract + Broker A (serve-host proxy)

**Files:** Modify `src/mship/core/serve.py`; Test `tests/core/test_serve.py` (or a new `test_serve_gh_token.py`).

- [ ] **Step 1: Failing serve tests** (TestClient): `GET /gh-token` requires the bearer (401 without); with a fake `ShellRunner` returning `"ghs_xxx"` for `gh auth token` → 200 `{"token":"ghs_xxx", ...}`; when the shell returns non-zero (gh absent/unauth) → 503 with a clear message, NOT a 200 empty token; the response never echoes the token into the server log.

- [ ] **Step 2: Implement** a `GET /gh-token` closure inside `create_app` (inherits the app-wide bearer dep automatically). Accept an optional `repos` query param (comma-separated) for parity + audit. Shell `gh auth token` via the `ShellRunner` already in scope (or construct one like `PRManager` does). Return `{"token": <out>, "expires_at": None, "repositories": repos_list}`. On non-zero/empty → `raise HTTPException(503, "gh auth token unavailable on serve host; run gh auth login or use a broker/relay")`. **Audit-log** the mint (timestamp, requester if available, repos) but NOT the token.

- [ ] **Step 3: Green** (`mship test`). **Step 4: Commit + journal.**
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: Broker B relay service + `mship relay gh-broker` command

**Files:** Create `src/mship/core/relay/gh_broker_app.py`; Modify `src/mship/cli/relay.py`; Test `tests/core/relay/test_gh_broker_app.py`.

- [ ] **Step 1: Failing tests** (TestClient over the broker app): `GET /gh-token?repos=r1,r2` with a valid bearer + mocked `mint_installation_token` → 200 `{token, expires_at}` scoped to `[r1,r2]`; missing/blank bearer → 401; App config absent (no app_id/key/installation) → 500/clear error; a `GhAppError` from the mint → surfaced as a clear error (naming the repo), not a 200.

- [ ] **Step 2: Implement `gh_broker_app.py`** — a FastAPI app mirroring `enroll_app.py`'s structure: a bearer dep (reuse the serve-token check pattern), a `GET /gh-token` route that reads App config (`app_id`, `private_key`, `installation_id`) from env (`MSHIP_GH_APP_ID`, `MSHIP_GH_APP_KEY`/key path, `MSHIP_GH_APP_INSTALLATION`), parses `repos`, calls `mint_installation_token(...)` (Task 1), returns `{token, expires_at, repositories}`, audit-logs the mint (no token). App key never logged/returned.

- [ ] **Step 3: Implement the CLI command** `mship relay gh-broker` in `cli/relay.py`, mirroring `enroll-server` (`_enroll_server_impl`): boot the broker app via uvicorn on a new loopback port (e.g. 47181), reading the bearer + App config from env. `--port` option.

- [ ] **Step 4: Green** (`mship test`). **Step 5: Commit + journal.**
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: `resolve_token` broker-pull + config + call-site wiring

**Files:** Modify `src/mship/core/gh_auth.py` (extend `resolve_token`), `src/mship/core/bootstrap.py`, `src/mship/cli/worktree.py`; config read (env / `mothership.yaml`); Test `tests/core/test_gh_auth.py`.

- [ ] **Step 1: Failing tests** for the extended resolver: with no `--token`/`GH_TOKEN`/`GITHUB_TOKEN` but a broker configured (URL + bearer + repos), it does `GET {url}/gh-token?repos=...` (mock httpx) and returns the token; a higher-precedence source still wins; broker down/timeout/HTTP-error → returns `None` (logged), never raises; the `repos` query is exactly the passed set.

- [ ] **Step 2: Implement.** Add a broker-pull as the lowest-precedence source. Keep `resolve_token(explicit)` backward-compatible; add an overload/param for broker config + repo set (e.g. `resolve_token(explicit, broker: BrokerConfig | None = None, repos: list[str] | None = None)`), or a new `resolve_token_with_broker(...)` that wraps it. The broker config (base URL + bearer credential) is read from env (`MSHIP_GH_BROKER_URL`, reuse `MSHIP_SERVE_TOKEN` as the bearer) and/or `mothership.yaml`. httpx GET with a short timeout; on any error log + return None (fall through to existing behavior).

- [ ] **Step 3: Wire the call sites.** `bootstrap.py:105` and `cli/worktree.py:1148` pass the broker config + the **repo set**: default to **all repos in the workspace `mothership.yaml`** (bootstrap knows these from the config it's materializing; finish from the task's affected repos). Confirm downstream `git_cred_args`/`create_pr_via_httpx` are untouched.

- [ ] **Step 4: Green** (`mship test`). **Step 5: Commit + journal.**
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: Preflight / fail-fast (operator q1 requirement)

**Files:** Create `src/mship/cli/` command (e.g. `mship gh preflight` or extend a `doctor`); Modify `core/bootstrap.py` (upfront full-repo-set token); Test `tests/cli/test_gh_preflight.py`.

- [ ] **Step 1: Failing tests.** `mship gh preflight` (a) with a broker that mints for all workspace repos → exit 0, prints "auth OK for repos: …"; (b) with a broker whose mint fails naming repo X → **non-zero exit** with a clear message naming X and how to fix (install the App on X); (c) no broker configured but `--token`/`GH_TOKEN` present → exit 0 (fallback path is fine). Bootstrap: requesting the full-repo-set token happens BEFORE cloning, so an uncoverable repo aborts bootstrap early with the same clear error.

- [ ] **Step 2: Implement** `mship gh preflight [--repos ...]`: resolve the broker + repo set (default all workspace repos), do a single broker-pull for the full set, and report OK / fail-fast naming the uncovered repo — WITHOUT doing any git/AI work. Make `bootstrap` request the full-repo-set token upfront (it needs it to clone anyway) so failure surfaces before work. The routine runs `mship gh preflight` as its first step.

- [ ] **Step 3: Green** (`mship test`). **Step 4: Commit + journal.**
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: Relay Caddy route + cloud/App setup docs

**Files:** Modify `docker/relay/Caddyfile`; Create `docs/` (cloud-agent auth setup); Modify `docs/` relay docs.

- [ ] **Step 1: Caddy route.** Add a hardened `gh.{domain}` route to `docker/relay/Caddyfile` mirroring the `enroll.{domain}` block: reverse-proxy to the broker's loopback port (47181), a method/path allowlist (only `GET /gh-token`), a small request-body cap, and the same on-demand-TLS `ask` gating. Do not touch the existing enroll/wildcard routes.

- [ ] **Step 2: Docs.** Write `docs/cloud-agent-auth.md`: (a) the fresh-cloud-container recipe — set `MSHIP_SERVE_TOKEN` + `MSHIP_GH_BROKER_URL` once-per-environment, no PAT; (b) **GitHub App setup** — create the App (repo contents:read+write, PRs:write), install it on all workspace repos, put `MSHIP_GH_APP_ID`/`MSHIP_GH_APP_KEY`/`MSHIP_GH_APP_INSTALLATION` on the relay (in the gitignored `docker/relay/.env`); (c) run `mship relay gh-broker`; (d) run `mship gh preflight` to verify coverage before scheduling an unattended run.

- [ ] **Step 3:** Verify Caddyfile parses if a `caddy` binary is available (`caddy validate`), else visual-review against the enroll block. **Step 4: Commit + journal.**
<!-- /mship:task -->

---

## Self-Review

- **Spec coverage:** ac1/ac6→T4; ac2→T2; ac3→T1+T3; ac4→T3+T6; ac5→T2+T3 (shared contract); ac7 (audit)→T2+T3; ac8 (config/docs)→T4+T6; ac9 (no argv/disk token, dep, tests)→T1+T4+every task's `mship test`; ac10 (multi-repo scope)→T1 (`repositories:[...]`)+T4 (passes the set)+T5 (preflight for all). Operator q1 fail-fast→T5. ✓
- **Type consistency:** the `{token, expires_at?, repositories}` response is identical across Broker A (T2) and Broker B (T3), consumed by `resolve_token`'s broker-pull (T4) and the preflight (T5). `mint_installation_token(app_id, private_key, installation_id, repos, ...)` signature is defined in T1 and called only in T3. ✓
- **Ordering:** T1 (mint) + T2 (contract/A) → T3 (B uses both) → T4 (resolver uses the contract) → T5 (preflight uses the resolver) → T6 (Caddy/docs). Single repo, sequential.
- **Out of scope (confirmed with operator):** OIDC/WIF request-auth (build the broker's auth pluggable so it slots in later; not v1), unattended-run state sync-back (its own issue). The live GitHub App creation/install is operator setup, not code.
