# Fold the GitHub App token broker into mship serve — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `fold-the-github-app-token-broker-into` (approved) — `specs/2026-07-12-fold-the-github-app-token-broker-into.md`

**Goal:** Collapse the two GitHub-token brokers into one endpoint (`mship serve` `GET /gh-token`) that mints App installation tokens when App creds are configured — auto-resolving the installation per repo owner so one App spans every account/org it's installed on — and otherwise falls back to proxying `gh auth token`. Remove the standalone `mship relay gh-broker` process, its Caddy route, and the hardcoded installation id.

**Architecture:** A GitHub App JWT (signed from app_id + private key) can call `GET /repos/{owner}/{repo}/installation` to discover the installation id for any repo the App is installed on. So `mship serve` reads the App creds (env), resolves the installation per request from the repo owner, and mints a token scoped to the requested repos via the existing `mint_installation_token`. The client sends full `owner/repo` names so serve can resolve the owner. Backend selection is decided ONLY by whether App creds are configured; a configured-but-not-installed App is a hard error (never a silent fallback to a different identity).

**Tech Stack:** Python 3.14, FastAPI (serve), httpx, PyJWT, Typer (CLI), pytest (`httpx.MockTransport` + injected `client=`, `TestClient`, monkeypatch by module path).

**Repos:** mothership only.

**Execution note:** Build SERIALLY (one implementer subagent at a time; commit each task's work immediately). Parallel subagents writing mship state clobber `state.yaml` (MOS-233). Each dispatched subagent runs `mship test` for evidence.

---

<!-- mship:task id=1 -->
### Task 1: `resolve_installation` — discover the installation id for a repo from the App JWT

**Files:**
- Modify: `src/mship/core/gh_app.py` (add `resolve_installation`, reuse `_app_jwt`)
- Test: `tests/core/test_gh_app.py`

Add a function that signs an App JWT and calls `GET /repos/{owner}/{repo}/installation` to return the installation id for a repo the App is installed on. This is the piece that removes the hardcoded `installation_id` and enables multi-account.

- [ ] **Step 1: Write the failing test**

Add to `tests/core/test_gh_app.py` (mirror the existing `httpx.MockTransport(handler)` + injected `client=` + RSA-keypair-fixture style):

```python
def test_resolve_installation_returns_id_for_repo(rsa_private_key):
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/repos/acme/widgets/installation"
        assert request.headers["Authorization"].startswith("Bearer ")
        return httpx.Response(200, json={"id": 424242})
    client = httpx.Client(transport=httpx.MockTransport(handler))
    inst = resolve_installation(
        app_id="123", private_key=rsa_private_key,
        owner="acme", repo="widgets", client=client,
    )
    assert inst == "424242"


def test_resolve_installation_not_installed_raises_naming_repo(rsa_private_key):
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(404, json={"message": "Not Found"})
    client = httpx.Client(transport=httpx.MockTransport(handler))
    with pytest.raises(GhAppError) as ei:
        resolve_installation(app_id="123", private_key=rsa_private_key,
                             owner="acme", repo="widgets", client=client)
    assert "acme/widgets" in str(ei.value)
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/core/test_gh_app.py -k resolve_installation -v`
Expected: FAIL (`resolve_installation` not defined / not importable).

- [ ] **Step 3: Implement `resolve_installation`**

In `src/mship/core/gh_app.py`, add after `_app_jwt` (reusing it) and export alongside `mint_installation_token`:

```python
def resolve_installation(
    *,
    app_id: str,
    private_key: str,
    owner: str,
    repo: str,
    now: int | None = None,
    client: httpx.Client | None = None,
) -> str:
    """Return the App installation id that owns `owner/repo`, discovered from
    the App JWT via GET /repos/{owner}/{repo}/installation. Raises GhAppError
    naming owner/repo if the App is not installed there. Never logs the key.
    """
    token_jwt = _app_jwt(app_id, private_key, now)
    c, owns = (client, False) if client is not None else (httpx.Client(timeout=15), True)
    try:
        try:
            resp = c.get(
                f"{_API}/repos/{owner}/{repo}/installation",
                headers={
                    "Authorization": f"Bearer {token_jwt}",
                    "Accept": "application/vnd.github+json",
                },
            )
        except httpx.HTTPError as e:
            raise GhAppError(f"gh-app: installation lookup failed for {owner}/{repo}: {e}") from e
        if resp.status_code == 200:
            inst = resp.json().get("id")
            if inst is None:
                raise GhAppError(f"gh-app: installation lookup for {owner}/{repo} had no id")
            return str(inst)
        raise GhAppError(
            f"gh-app: App is not installed on {owner}/{repo} "
            f"(install the App on {owner}) — status {resp.status_code}"
        )
    finally:
        if owns:
            c.close()
```

- [ ] **Step 4: Run to verify it passes**

Run: `uv run pytest tests/core/test_gh_app.py -v`
Expected: PASS (new + existing).

- [ ] **Step 5: Commit + journal**

```bash
git add src/mship/core/gh_app.py tests/core/test_gh_app.py
mship journal "gh_app.resolve_installation: discover installation id per repo via App JWT" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=2 -->
### Task 2: Thread App creds into `mship serve`

**Files:**
- Modify: `src/mship/core/serve.py` (`create_app` signature — add `gh_app_id`, `gh_app_key`)
- Modify: `src/mship/cli/serve.py` (read env, pass to `create_app`, warn on ignored `MSHIP_GH_APP_INSTALLATION`)
- Test: `tests/core/test_serve_gh_token.py`, `tests/cli/test_serve*.py` (or a new small CLI test)

Serve currently has no App creds. Add them so the handler (Task 3) can mint. Selection is by presence of these creds.

- [ ] **Step 1: Write the failing test (create_app accepts App creds)**

In `tests/core/test_serve_gh_token.py`, add a test that `create_app` accepts and stores the creds (the mint behavior is Task 3 — here just assert the app builds with them):

```python
def test_create_app_accepts_gh_app_creds(tmp_path):
    app = create_app(
        specs_dir=tmp_path, state_manager=_stub_state(), log_manager=_stub_logs(),
        workspace_root=tmp_path, auth_token="t",
        gh_app_id="123", gh_app_key="-----BEGIN PRIVATE KEY-----\n...",
    )
    # app builds; the /gh-token App path is exercised in Task 3.
    assert app is not None
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/core/test_serve_gh_token.py -k create_app_accepts -v`
Expected: FAIL (`create_app` has no `gh_app_id`/`gh_app_key` kwargs).

- [ ] **Step 3: Add the params to `create_app`**

In `src/mship/core/serve.py`, extend `create_app(...)` with two keyword params (default None) alongside the existing ones:

```python
def create_app(
    specs_dir: Path,
    state_manager,
    log_manager,
    workspace_root: Path,
    workspace_name: str = "mothership",
    auth_token: str | None = None,
    worktree_manager=None,
    config=None,
    gh_app_id: str | None = None,
    gh_app_key: str | None = None,   # PRIVATE KEY TEXT (already read from the .pem)
):
```

Capture them in the closure scope used by `get_gh_token` (Task 3 reads them). No behavior change yet.

- [ ] **Step 4: Run to verify it passes**

Run: `uv run pytest tests/core/test_serve_gh_token.py -k create_app_accepts -v`
Expected: PASS.

- [ ] **Step 5: Read the App creds in the serve CLI + warn on the ignored installation var**

In `src/mship/cli/serve.py`, on BOTH the non-relay and relay paths, read the App creds from env and pass them to `create_app`. `MSHIP_GH_APP_KEY` is a FILE PATH (read its text). Warn (once) if `MSHIP_GH_APP_INSTALLATION` is set — it's now ignored (auto-resolved).

```python
# near where auth_token/config are resolved, before create_app(...):
import os
from pathlib import Path
gh_app_id = os.environ.get("MSHIP_GH_APP_ID") or None
gh_app_key = None
_key_path = os.environ.get("MSHIP_GH_APP_KEY")
if _key_path:
    p = Path(_key_path)
    if not p.is_file():
        Output().warning(f"MSHIP_GH_APP_KEY is set but not a readable file ({_key_path!r}); App minting disabled.")
    else:
        gh_app_key = p.read_text()
if os.environ.get("MSHIP_GH_APP_INSTALLATION"):
    Output().warning("MSHIP_GH_APP_INSTALLATION is ignored — the installation is now auto-resolved per repo.")
# then pass gh_app_id=gh_app_id, gh_app_key=gh_app_key into create_app(...) on both paths.
```

- [ ] **Step 6: Test the CLI wiring (env → create_app)**

Add a CLI-level test (in the existing serve CLI test module, matching its style) that sets `MSHIP_GH_APP_ID` + a temp `MSHIP_GH_APP_KEY` file and asserts `create_app` is called with the key text; and that setting `MSHIP_GH_APP_INSTALLATION` emits the "ignored" warning. Monkeypatch `mship.cli.serve.create_app` to capture kwargs.

Run: `uv run pytest tests/cli -k serve -v`
Expected: PASS.

- [ ] **Step 7: Commit + journal**

```bash
git add src/mship/core/serve.py src/mship/cli/serve.py tests/
mship journal "serve: thread MSHIP_GH_APP_ID/KEY into create_app; warn that MSHIP_GH_APP_INSTALLATION is ignored" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=3 -->
### Task 3: App-backed `/gh-token` handler (the if/elif ladder)

**Files:**
- Modify: `src/mship/core/serve.py` (`get_gh_token`)
- Test: `tests/core/test_serve_gh_token.py`

Replace the Broker-A-only handler with: if App creds configured → resolve installation from the repos' owner + mint scoped token (hard error if not installed or if repos span >1 owner); elif `gh auth token` succeeds → proxy it (unchanged); else → 503.

- [ ] **Step 1: Write the failing tests**

In `tests/core/test_serve_gh_token.py`. The App path calls `resolve_installation` + `mint_installation_token` in `mship.core.serve` — monkeypatch both by that module path (mirrors how Broker A tests monkeypatch `ShellRunner`). Repos are sent as `owner/repo`.

```python
def test_gh_token_app_path_mints_scoped_token(tmp_path, monkeypatch):
    calls = {}
    monkeypatch.setattr("mship.core.serve.resolve_installation",
        lambda **kw: (calls.update(resolve=kw) or "999"))
    monkeypatch.setattr("mship.core.serve.mint_installation_token",
        lambda **kw: (calls.update(mint=kw) or
                      {"token": "ghs_x", "expires_at": "2026-07-12T02:00:00Z",
                       "repositories": kw["repos"]}))
    app = create_app(specs_dir=tmp_path, state_manager=_stub_state(), log_manager=_stub_logs(),
                     workspace_root=tmp_path, auth_token="t",
                     gh_app_id="123", gh_app_key="KEY")
    r = TestClient(app).get("/gh-token?repos=acme/widgets,acme/gadgets",
                            headers={"Authorization": "Bearer t"})
    assert r.status_code == 200
    assert r.json()["token"] == "ghs_x"
    assert calls["resolve"]["owner"] == "acme"          # resolved from first repo
    assert calls["mint"]["installation_id"] == "999"
    assert calls["mint"]["repos"] == ["widgets", "gadgets"]  # SHORT names for the mint


def test_gh_token_app_not_installed_is_error_no_fallback(tmp_path, monkeypatch):
    from mship.core.gh_app import GhAppError
    def _boom(**kw): raise GhAppError("App is not installed on acme (install the App on acme)")
    monkeypatch.setattr("mship.core.serve.resolve_installation", _boom)
    # gh auth token would "work" — but must NOT be used:
    monkeypatch.setattr("mship.core.serve.ShellRunner", _FakeShellRunner(stdout="gho_fallback\n"))
    app = create_app(specs_dir=tmp_path, state_manager=_stub_state(), log_manager=_stub_logs(),
                     workspace_root=tmp_path, auth_token="t", gh_app_id="123", gh_app_key="KEY")
    r = TestClient(app).get("/gh-token?repos=acme/widgets", headers={"Authorization": "Bearer t"})
    assert r.status_code in (502, 500)
    assert "acme" in r.json()["detail"]
    assert "gho_fallback" not in r.text


def test_gh_token_repos_spanning_two_owners_is_400(tmp_path, monkeypatch):
    monkeypatch.setattr("mship.core.serve.resolve_installation", lambda **kw: "1")
    monkeypatch.setattr("mship.core.serve.mint_installation_token",
                        lambda **kw: {"token": "x", "expires_at": None, "repositories": kw["repos"]})
    app = create_app(specs_dir=tmp_path, state_manager=_stub_state(), log_manager=_stub_logs(),
                     workspace_root=tmp_path, auth_token="t", gh_app_id="123", gh_app_key="KEY")
    r = TestClient(app).get("/gh-token?repos=acme/a,other/b", headers={"Authorization": "Bearer t"})
    assert r.status_code == 400
    assert "single" in r.json()["detail"].lower() or "one account" in r.json()["detail"].lower()


def test_gh_token_no_app_creds_falls_back_to_gh_auth_token(tmp_path, monkeypatch):
    monkeypatch.setattr("mship.core.serve.ShellRunner", _FakeShellRunner(stdout="gho_daytime\n"))
    app = create_app(specs_dir=tmp_path, state_manager=_stub_state(), log_manager=_stub_logs(),
                     workspace_root=tmp_path, auth_token="t")  # NO app creds
    r = TestClient(app).get("/gh-token?repos=acme/widgets", headers={"Authorization": "Bearer t"})
    assert r.status_code == 200
    assert r.json()["token"] == "gho_daytime"
```

(Keep the existing Broker-A tests — they exercise the no-app-creds path with `repos` echoed. Adjust any that now send `owner/repo`.)

- [ ] **Step 2: Run to verify they fail**

Run: `uv run pytest tests/core/test_serve_gh_token.py -v`
Expected: new App-path tests FAIL.

- [ ] **Step 3: Implement the handler**

In `src/mship/core/serve.py`, import at top: `from mship.core.gh_app import resolve_installation, mint_installation_token, GhAppError`. Rewrite `get_gh_token`:

```python
@app.get("/gh-token")
def get_gh_token(repos: str | None = None):
    repos_list = [r.strip() for r in repos.split(",") if r.strip()] if repos else []

    # Path B — App-backed mint (selected ONLY by App creds being configured).
    if gh_app_id and gh_app_key:
        if not repos_list:
            raise HTTPException(400, "repos query param is required (owner/repo,...) for App minting")
        owners, short_names = set(), []
        for full in repos_list:
            if "/" not in full:
                raise HTTPException(400, f"repos must be owner/repo for App minting; got {full!r}")
            owner, name = full.split("/", 1)
            owners.add(owner)
            short_names.append(name)
        if len(owners) > 1:
            raise HTTPException(400,
                f"repos span multiple accounts {sorted(owners)}; a workspace must be single-account")
        owner = owners.pop()
        try:
            installation_id = resolve_installation(
                app_id=gh_app_id, private_key=gh_app_key, owner=owner, repo=short_names[0])
            result = mint_installation_token(
                app_id=gh_app_id, private_key=gh_app_key,
                installation_id=installation_id, repos=short_names)
        except GhAppError as e:
            raise HTTPException(502, detail=str(e)) from e
        logger.info("gh-token minted: broker=App owner=%s repos=%s at=%s",
                    owner, short_names, datetime.now(timezone.utc).isoformat())
        return result

    # Path A — proxy `gh auth token` (unchanged; single-identity daytime).
    result = gh_token_shell.run("gh auth token", cwd=workspace_root)
    token = (result.stdout or "").strip()
    if result.returncode != 0 or not token:
        raise HTTPException(503, detail=(
            "gh auth token unavailable on serve host — run `gh auth login`, "
            "set MSHIP_GH_APP_ID/MSHIP_GH_APP_KEY, or use a relay broker"))
    logger.info("gh-token minted: broker=A repos=%s at=%s",
                repos_list or None, datetime.now(timezone.utc).isoformat())
    return {"token": token, "expires_at": None, "repositories": repos_list or None}
```

- [ ] **Step 4: Run to verify they pass**

Run: `uv run pytest tests/core/test_serve_gh_token.py -v`
Expected: PASS (all).

- [ ] **Step 5: Commit + journal**

```bash
git add src/mship/core/serve.py tests/core/test_serve_gh_token.py
mship journal "serve /gh-token: App-backed mint with per-repo installation resolution + gh-auth-token fallback; no silent identity swap" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=4 -->
### Task 4: Client sends `owner/repo` on the broker pull

**Files:**
- Modify: `src/mship/core/bootstrap.py` (~line 110-114), `src/mship/cli/worktree.py` (finish, ~line 1171-1177)
- Reuse: `src/mship/core/gh_preflight.repo_owner_names_from_config` (already returns `{short: "owner/name"}`)
- Test: `tests/core/test_gh_auth.py` (broker query now carries owner/repo), plus bootstrap/finish tests if present

`resolve_token`'s `repos` is passed straight into the `?repos=` query. Change the two callers to pass `owner/repo` (so the new serve can resolve the installation). Broker A ignores repos, so this is backward-safe.

- [ ] **Step 1: Write/adjust the failing test**

In `tests/core/test_gh_auth.py`, the existing broker-pull test asserts the URL contains short names; add/adjust to assert it carries `owner/repo` when given such:

```python
def test_broker_pull_sends_owner_repo(monkeypatch):
    seen = {}
    def handler(request):
        seen["url"] = str(request.url)
        return httpx.Response(200, json={"token": "ghs_x"})
    client = httpx.Client(transport=httpx.MockTransport(handler))
    monkeypatch.delenv("GH_TOKEN", raising=False); monkeypatch.delenv("GITHUB_TOKEN", raising=False)
    tok = resolve_token(None, broker_url="https://serve", broker_bearer="b",
                        repos=["acme/widgets", "acme/gadgets"], client=client)
    assert tok == "ghs_x"
    assert "acme%2Fwidgets" in seen["url"] or "acme/widgets" in seen["url"]
```

(`resolve_token` itself needs NO change — it already joins whatever `repos` it's given. The change is in the CALLERS.)

- [ ] **Step 2: Run to verify current callers still pass short names**

Run: `uv run pytest tests/core/test_gh_auth.py -k broker -v` → the new test PASSES already (resolve_token is caller-agnostic). The real work is updating callers; verify via bootstrap/finish tests next.

- [ ] **Step 3: Update the callers to build owner/repo**

In `src/mship/core/bootstrap.py`, where it builds `all_repo_names` for `resolve_token`, map to owner/repo via the existing helper. Import `from mship.core.gh_preflight import repo_owner_names_from_config`:

```python
_owner_map = repo_owner_names_from_config(config_path, all_repo_names)  # {short: "owner/name"}
broker_repos = [_owner_map.get(n) for n in all_repo_names]
broker_repos = [r for r in broker_repos if r]  # drop non-github/unresolvable
resolve_token(token, ..., repos=broker_repos or all_repo_names)
```

Apply the same transform in `src/mship/cli/worktree.py` (finish) where `finish_repos` is passed to `resolve_token`. Fall back to short names if the owner map is empty (Broker A ignores repos, so nothing breaks).

- [ ] **Step 4: Run to verify it passes**

Run: `uv run pytest tests/core/test_gh_auth.py tests/core/test_bootstrap*.py tests/cli/test_worktree*.py -v`
Expected: PASS (adjust any caller test that asserted the exact `?repos=` short-name payload).

- [ ] **Step 5: Commit + journal**

```bash
git add src/mship/core/bootstrap.py src/mship/cli/worktree.py tests/
mship journal "client: bootstrap + finish send owner/repo to the broker so serve can resolve the installation" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=5 -->
### Task 5: Remove the standalone gh-broker (command, app, Caddy route, tls_ask)

**Files:**
- Modify: `src/mship/cli/relay.py` (delete `gh_broker` command + `_gh_broker_impl`)
- Delete: `src/mship/core/relay/gh_broker_app.py` and `tests/core/relay/test_gh_broker_app.py`
- Modify: `docker/relay/Caddyfile` (remove the `gh.{$RELAY_DOMAIN}` block, lines ~35-54)
- Modify: `src/mship/core/relay/tls_ask.py` (drop `"gh"` from the whitelist)
- Test: `tests/core/relay/test_tls_ask.py` (invert `test_allows_gh_broker_host`)

The folded serve endpoint replaces Broker B. Remove the now-dead standalone path.

- [ ] **Step 1: Write the failing test (tls_ask no longer allows `gh.`)**

In `tests/core/relay/test_tls_ask.py`, replace `test_allows_gh_broker_host` with:

```python
def test_rejects_gh_broker_host_after_fold():
    assert tls_ask_allowed(f"gh.{RELAY}", RELAY) is False  # folded into serve; no separate cert
```

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/core/relay/test_tls_ask.py -v`
Expected: FAIL (still allows `gh.`).

- [ ] **Step 3: Remove `gh` from the whitelist**

In `src/mship/core/relay/tls_ask.py`, change `if label in ("enroll", "gh"):` to `if label == "enroll":`.

- [ ] **Step 4: Delete the standalone broker**

- Remove the `gh_broker` typer command and `_gh_broker_impl` from `src/mship/cli/relay.py` (and any now-unused imports).
- `git rm src/mship/core/relay/gh_broker_app.py tests/core/relay/test_gh_broker_app.py`.
- Remove the `gh.{$RELAY_DOMAIN} { ... }` block from `docker/relay/Caddyfile`.

- [ ] **Step 5: Run the suite (catch dangling refs)**

Run: `uv run pytest -q`
Expected: PASS. Fix any import of the deleted module (e.g. re-exports).

- [ ] **Step 6: Commit + journal**

```bash
git add -A
mship journal "remove standalone gh-broker: cli command, gh_broker_app, Caddy gh. route, tls_ask gh whitelist — folded into serve" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=6 -->
### Task 6: `mship gh preflight` sends owner/repo to the folded endpoint

**Files:**
- Modify: `src/mship/core/gh_preflight.py` (`run_preflight` broker branch, ~line 237)
- Test: `tests/cli/test_gh_preflight.py`

Preflight's broker branch currently sends short names. It already computes `repo_owner_names` — send those `owner/repo` values so the folded App-backed serve can verify coverage.

- [ ] **Step 1: Write the failing test**

In `tests/cli/test_gh_preflight.py`, adjust the broker-covers-all test to assert the `?repos=` query carries `owner/repo` (e.g. `acme/widgets`) rather than the short name.

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/cli/test_gh_preflight.py -v`
Expected: FAIL on the query-shape assertion.

- [ ] **Step 3: Send owner/repo in the broker branch**

In `src/mship/core/gh_preflight.run_preflight`, the broker branch builds the CSV from `repos` (short names). Use `repo_owner_names` (the `{short: "owner/name"}` map already passed in) to send owner/repo:

```python
# broker branch:
owner_repos = [repo_owner_names.get(r, r) for r in repos] if repo_owner_names else repos
resp = client.get(f"{broker_url}/gh-token", params={"repos": ",".join(owner_repos)}, headers=...)
```

- [ ] **Step 4: Run to verify it passes**

Run: `uv run pytest tests/cli/test_gh_preflight.py -v`
Expected: PASS.

- [ ] **Step 5: Commit + journal**

```bash
git add src/mship/core/gh_preflight.py tests/cli/test_gh_preflight.py
mship journal "gh preflight: send owner/repo to the folded /gh-token broker branch" --action committed
```
<!-- /mship:task -->

---

<!-- mship:task id=7 -->
### Task 7: Rewrite `docs/cloud-agent-auth.md`

**Files:**
- Modify: `mothership/docs/cloud-agent-auth.md`

Collapse the doc to one broker (serve). Sections: (1) fresh cloud container recipe (MSHIP_GH_BROKER_URL + MSHIP_SERVE_TOKEN — unchanged); (2) GitHub App setup for unattended/multi-account — create App (installable on any account), install on each account/org, drop the .pem on the serve host, set MSHIP_GH_APP_ID + MSHIP_GH_APP_KEY, run `mship serve --relay`; NO installation id, NO separate process, NO separate Caddy route; (3) daytime zero-setup = same serve with no App creds (proxies `gh auth token`); (4) `mship gh preflight` verifies coverage. State that identity never silently falls back: App-configured-but-not-installed is a hard error. Note the removed `MSHIP_GH_APP_INSTALLATION` (auto-resolved) and the removed `mship relay gh-broker` / Caddy `gh.` route.

- [ ] **Step 1: Rewrite the doc** per the above. No code test; verify no stale references remain:

Run: `grep -n "gh-broker\|MSHIP_GH_APP_INSTALLATION\|installation id\|gh.{\|47181" mothership/docs/cloud-agent-auth.md`
Expected: no matches (except an explicit "removed/renamed" note if you keep one).

- [ ] **Step 2: Commit + journal**

```bash
git add mothership/docs/cloud-agent-auth.md
mship journal "docs: rewrite cloud-agent-auth for the single folded broker + multi-account App" --action committed
```
<!-- /mship:task -->

---

## Final review

After all tasks: run `uv run pytest -q` (full suite green), confirm `mship gh preflight` help still works, and dispatch a final code review over the whole diff before `mship finish`. Acceptance criteria ac1–ac8 in the spec map to Tasks 1/3 (ac1), 3 (ac3, ac5), 3 (ac4), 4 (ac2), 5 (ac6), 6 (ac7), 7 (ac8).

## Self-review (author)

- **Spec coverage:** ac1→T1+T3; ac2→T4 (multi-account owner/repo); ac3→T3 (no-fallback error); ac4→T3 (gh-auth fallback); ac5→T3 (multi-owner 400); ac6→T5 (removal + T2 warn); ac7→T6; ac8→T7. All covered.
- **Type consistency:** `resolve_installation` returns `str` (used as `installation_id: str` by `mint_installation_token`). Client sends `owner/repo`; serve splits to `owner` (resolve) + short `name` (mint) — matches `mint_installation_token(repos=[short names])`.
- **Ordering:** T1 (resolve) → T2 (creds into serve) → T3 (handler uses both) → T4 (client owner/repo) → T5 (remove dead broker) → T6 (preflight) → T7 (docs). T3 depends on T1+T2; T6 depends on T4's owner-map helper (already exists). Build serially in this order.
