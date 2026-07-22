# Worker PR egress: api.github.com relay route with a PR-creation-only enforcer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `worker-pr-egress` (approved) — `specs/2026-07-22-worker-pr-egress.md`. WorkItem `wi-20260722104802-8e8ec5bc`. Affected repo: `mothership`.

**Goal:** Re-add the `api.github.com` egress route dropped by Slice 1, this time behind a real default-deny `GitHubApiEnforcer` that lets a worker open/manage only the run's PR (plus comments/reviews and repo-scoped reads) and refuses every other REST call — so the API leg cannot sidestep the git push-to-run-branch enforcement.

**Architecture:** Three net-new pieces in the existing egress subpackage, all riding the Slice-1 seams verbatim: (1) an api-path repo extractor in `request.py` that pulls `owner/repo` from `/repos/{o}/{r}/...` (and returns `None` for repo-less globals like `/user`); (2) a pure `classify_api_request(method, path, in_scope) -> bool` default-deny classifier plus a `GitHubApiEnforcer` that does the scope lookup and raises on deny; (3) the `api.github.com` route added back to `build_default_routes`. No Caddy/`tls_ask`/worker-config change — the `/api/` prefix already exists and rides the same egress subdomain as `/gh/`.

**Tech Stack:** Python 3, dataclasses, FastAPI + `fastapi.testclient.TestClient`, `httpx` (`httpx.MockTransport` for the upstream), pytest. Package manager: `uv` (run tests with `uv run pytest`). Work from the task worktree: `/home/bailey/development/repos/mship-workspace/.worktrees/worker-pr-egress/mothership`.

---

## File Structure

All paths are relative to the mothership repo root inside the worktree: `.worktrees/worker-pr-egress/mothership/`.

**Modify (source):**
- `src/mship/core/relay/egress/request.py` — add `_extract_api_repo()`; set `EgressRequest.repo` for the api host in `parse_egress_request()`. (Currently `repo` is `None` for the api host.)
- `src/mship/core/relay/egress/enforce.py` — add pure `classify_api_request()` + `GitHubApiEnforcer`; **remove** the now-dead `HostLockedEnforcer` (its role — a pass-through with no ref policy — is exactly the placeholder this slice replaces; leaving a no-policy enforcer in the tree is a loaded gun that would re-open the bypass if ever wired to the api route).
- `src/mship/core/relay/egress/routes.py` — re-add `"api.github.com": Route(provider, GitHubApiEnforcer())` to `build_default_routes()`; rewrite the "api is dropped" docstring.

**Modify (tests):**
- `tests/core/relay/egress/test_request.py` — update the api-prefix test (repo is now extracted, not `None`); add a repo-less-global case + a query-tolerated case.
- `tests/core/relay/egress/test_enforce.py` — drop the `HostLockedEnforcer` import + its test; add the full `classify_api_request` permit/deny matrix + `GitHubApiEnforcer` scope tests.
- `tests/core/relay/egress/test_routes.py` — rewrite the "git-only" route test to assert `api.github.com` now resolves to `GitHubApiEnforcer`.
- `tests/core/relay/egress/test_proxy.py` — add the api-leg integration tests (permit forwards+attaches, merge 403 pre-egress, out-of-scope 403 pre-egress, fail-closed 503).

**Modify (docs):**
- `docs/cloud-worker-auth-spine.md` — the api leg is back + enforced; document exactly what `GitHubApiEnforcer` permits vs denies, that merge is explicitly forbidden (review-gated), that no new deploy surface is needed, and that this is the deferred worker-API leg from the auth-spine slice.

**Reused verbatim (do NOT change):** `credential.py` (`github_token_attachment()` already host-locks `[github.com, api.github.com]`), `provider.py` (`GitHubAppProvider`), `proxy.py` (`build_egress_app` pipeline + fail-closed), `grants.py` (`Grant`/`Scope`/`covers`), `run_token.py`.

**Consistent names used across every task (verbatim):** `_extract_api_repo`, `classify_api_request`, `GitHubApiEnforcer`.

---

<!-- mship:task id=1 -->
### Task 1: api-path repo extraction in `request.py`

Extract `owner/repo` from `/repos/{owner}/{repo}/...` for the `api.github.com` host so the enforcer can scope-check; repo-less API paths (`/user`, `/rate_limit`, `/graphql`, `/orgs/...`) resolve to `None` (recognized, not mis-parsed). Query strings never reach the path (they arrive in the separate `query` field), so extraction is on the path segments only.

**Files:**
- Modify: `src/mship/core/relay/egress/request.py`
- Test: `tests/core/relay/egress/test_request.py`

- [ ] **Step 1: Update/add the failing tests**

In `tests/core/relay/egress/test_request.py`, REPLACE the existing `test_api_prefix_maps_to_api_host_with_no_repo` (it asserts `req.repo is None`, which this task changes) with the three tests below:

```python
def test_api_prefix_extracts_repo_from_repos_path():
    req = parse_egress_request(
        method="POST", path="/api/repos/acme/api/pulls", query="", headers={}, body=b"",
    )
    assert req.upstream_host == "api.github.com"
    assert req.upstream_path == "/repos/acme/api/pulls"
    assert req.repo == "acme/api"


def test_api_repo_less_global_paths_yield_none():
    for p in ("/api/user", "/api/rate_limit", "/api/graphql", "/api/orgs/acme"):
        req = parse_egress_request(method="GET", path=p, query="", headers={}, body=b"")
        assert req.upstream_host == "api.github.com"
        assert req.repo is None


def test_api_repo_extraction_tolerates_query_string():
    req = parse_egress_request(
        method="GET", path="/api/repos/acme/api/pulls", query="state=open&per_page=100",
        headers={}, body=b"",
    )
    assert req.repo == "acme/api"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/core/relay/egress/test_request.py -v`
Expected: `test_api_prefix_extracts_repo_from_repos_path` and `test_api_repo_extraction_tolerates_query_string` FAIL with `assert None == 'acme/api'` (repo is still `None` for the api host).

- [ ] **Step 3: Write the implementation**

In `src/mship/core/relay/egress/request.py`, add the extractor next to `_extract_repo` (below it):

```python
def _extract_api_repo(upstream_path: str) -> str | None:
    # /repos/{owner}/{repo}/... -> owner/repo. Repo-less API paths
    # (/user, /rate_limit, /graphql, /orgs/...) -> None: recognized as repo-less,
    # not mis-parsed. Query strings never appear here (they ride the `query` field).
    parts = [p for p in upstream_path.split("/") if p]
    if len(parts) >= 3 and parts[0] == "repos":
        return f"{parts[1]}/{parts[2]}"
    return None
```

Then in `parse_egress_request`, change the `repo` assignment (currently `repo = _extract_repo(upstream_path) if host == "github.com" else None`) to:

```python
    repo = (
        _extract_repo(upstream_path) if host == "github.com"
        else _extract_api_repo(upstream_path)
    )
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `uv run pytest tests/core/relay/egress/test_request.py -v`
Expected: PASS (all request tests, including the two git-leg tests, green).

- [ ] **Step 5: Commit + journal**

```bash
git add src/mship/core/relay/egress/request.py tests/core/relay/egress/test_request.py
git commit -m "feat(relay): extract owner/repo from api.github.com /repos/ paths"
mship journal "api-path repo extractor for the api.github.com egress host; repo-less globals -> None; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: the pure `classify_api_request` default-deny classifier

Add a pure function `classify_api_request(method, path, in_scope) -> bool` in `enforce.py`. It is the security core: DEFAULT-DENY over the GitHub REST surface, returning `True` only for the enumerated allowlist. It takes `in_scope` (whether the path's `owner/repo` is within the run's `scope.repos`) as a parameter so it stays pure and exhaustively unit-testable; the scope lookup itself lives in the enforcer (Task 3).

**Files:**
- Modify: `src/mship/core/relay/egress/enforce.py`
- Test: `tests/core/relay/egress/test_enforce.py`

- [ ] **Step 1: Write the failing tests (full permit/deny matrix)**

In `tests/core/relay/egress/test_enforce.py`, add this import to the existing `enforce` import line so it reads:

```python
from mship.core.relay.egress.enforce import (
    GitSmartHttpEnforcer, GitHubApiEnforcer, classify_api_request, EnforcementError,
)
```

(Note: `HostLockedEnforcer` is intentionally NOT imported — Task 3 removes it. `GitHubApiEnforcer` is imported now but not exercised until Task 3; that is fine, this step only calls `classify_api_request`.)

Then add the full matrix at the end of the file:

```python
# --- GitHubApiEnforcer classifier: default-deny permit/deny matrix ----------
# `in_scope` = the path's owner/repo is within the run's scope.repos. For the
# repo-less safe globals it is irrelevant (they are allowed regardless).
_API_PERMIT = [
    ("POST", "/repos/o/r/pulls", True),                       # open a PR
    ("PATCH", "/repos/o/r/pulls/1", True),                    # update the run's PR (NOT merge)
    ("POST", "/repos/o/r/issues/1/comments", True),           # comment
    ("POST", "/repos/o/r/pulls/1/reviews", True),             # review
    ("POST", "/repos/o/r/pulls/1/requested_reviewers", True), # request review
    ("GET", "/repos/o/r", True),                              # repo read (root)
    ("GET", "/repos/o/r/pulls", True),                        # repo read
    ("GET", "/repos/o/r/pulls/1", True),                      # repo read
    ("GET", "/rate_limit", False),                            # safe global (scope irrelevant)
    ("GET", "/user", False),                                  # safe global (scope irrelevant)
]

_API_DENY = [
    ("PUT", "/repos/o/r/pulls/1/merge", True),        # merge a PR — DIFFERENT path from PATCH /pulls/{n}
    ("PATCH", "/repos/o/r/pulls/1/merge", True),      # merge via another method is still merge
    ("POST", "/repos/o/r/merges", True),              # merges
    ("POST", "/repos/o/r/git/refs", True),            # ref create
    ("PATCH", "/repos/o/r/git/refs/heads/x", True),   # ref update
    ("DELETE", "/repos/o/r/git/refs/heads/x", True),  # ref delete
    ("PUT", "/repos/o/r/contents/f", True),           # content write
    ("DELETE", "/repos/o/r/contents/f", True),        # content delete
    ("DELETE", "/repos/o/r", True),                   # delete repo
    ("POST", "/repos/o/r/deployments", True),         # unknown write endpoint
    ("PUT", "/repos/o/r/pulls/1", True),              # method-specific: only PATCH updates a PR
    ("POST", "/repos/o/r/pulls", False),              # permitted shape but OUT OF SCOPE
    ("GET", "/repos/o/r", False),                     # read but OUT OF SCOPE
    ("GET", "/orgs/o", True),                         # repo-less non-global read
    ("POST", "/rate_limit", False),                   # non-GET on a safe global
]


@pytest.mark.parametrize("method, path, in_scope", _API_PERMIT)
def test_classify_api_request_permits_allowlist(method, path, in_scope):
    assert classify_api_request(method, path, in_scope) is True


@pytest.mark.parametrize("method, path, in_scope", _API_DENY)
def test_classify_api_request_denies_everything_else(method, path, in_scope):
    assert classify_api_request(method, path, in_scope) is False
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/core/relay/egress/test_enforce.py -v`
Expected: FAIL at import — `ImportError: cannot import name 'GitHubApiEnforcer'` (and `classify_api_request`) — the whole file errors on collection. That is the expected red for Steps 2–3 of both this task and Task 3.

- [ ] **Step 3: Write the implementation**

In `src/mship/core/relay/egress/enforce.py`, add `classify_api_request` (place it above the `HostLockedEnforcer` class, which Task 3 removes):

```python
def classify_api_request(method: str, path: str, in_scope: bool) -> bool:
    """Pure DEFAULT-DENY classifier for the GitHub REST surface.

    Returns True to PERMIT, False to DENY. `in_scope` says whether the path's
    owner/repo is within the run's scope.repos (only meaningful for repo-scoped
    paths; the safe globals are allowed regardless). Permits ONLY:
      - GET /rate_limit, GET /user                      (safe global reads)
      - GET  /repos/{o}/{r}/...                          (reads on the run's repos)
      - POST  /repos/{o}/{r}/pulls                       (open a PR)
      - PATCH /repos/{o}/{r}/pulls/{n}                   (update the PR; NOT merge)
      - POST  /repos/{o}/{r}/issues/{n}/comments         (comment)
      - POST  /repos/{o}/{r}/pulls/{n}/reviews           (review)
      - POST  /repos/{o}/{r}/pulls/{n}/requested_reviewers (request review)
    Everything else -> deny. Merge (PUT /pulls/{n}/merge) is a DIFFERENT path
    from the permitted PATCH /pulls/{n} and is denied by construction."""
    method = method.upper()
    segs = [s for s in path.split("/") if s]

    # Safe global reads (repo-less), permitted regardless of scope.
    if method == "GET" and segs in (["rate_limit"], ["user"]):
        return True

    # Every other permit is repo-scoped: /repos/{owner}/{repo}/...
    if len(segs) < 3 or segs[0] != "repos":
        return False
    if not in_scope:
        return False
    rest = segs[3:]  # path tail after /repos/{owner}/{repo}

    # Reads on the run's repos (bounded by the repo-scoped token).
    if method == "GET":
        return True

    # Writes: a tiny explicit allowlist (open/manage the run's PR + comment/review).
    if method == "POST" and rest == ["pulls"]:
        return True
    if method == "PATCH" and len(rest) == 2 and rest[0] == "pulls":
        return True  # PATCH /pulls/{n} — NOT /pulls/{n}/merge (len 3)
    if method == "POST" and len(rest) == 3 and rest[0] == "issues" and rest[2] == "comments":
        return True  # POST /issues/{n}/comments
    if (method == "POST" and len(rest) == 3 and rest[0] == "pulls"
            and rest[2] in ("reviews", "requested_reviewers")):
        return True  # POST /pulls/{n}/reviews | /pulls/{n}/requested_reviewers
    return False
```

- [ ] **Step 4: Run the classifier tests to verify they pass**

Run: `uv run pytest tests/core/relay/egress/test_enforce.py -k classify_api_request -v`
Expected: PASS — 25 parametrized cases green (10 permit + 15 deny). (The rest of `test_enforce.py` still fails to import `GitHubApiEnforcer` until Task 3; run with `-k classify_api_request` to isolate this task's evidence.)

- [ ] **Step 5: Commit + journal**

```bash
git add src/mship/core/relay/egress/enforce.py tests/core/relay/egress/test_enforce.py
git commit -m "feat(relay): pure default-deny classify_api_request for the GitHub REST leg"
mship journal "classify_api_request default-deny classifier + full 25-case permit/deny matrix; classifier tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: `GitHubApiEnforcer.check` (scope lookup + classifier + raise); remove `HostLockedEnforcer`

Add the enforcer that plugs into the `Enforcer` protocol: it computes `in_scope` (the path's `owner/repo` ∈ `grant.scope.repos`), calls `classify_api_request`, and raises `EnforcementError` on deny (the proxy maps that to 403). Then remove the dead `HostLockedEnforcer` (pass-through, no ref policy) and its test — this slice replaces that placeholder with a real enforcer, so the no-policy class must not linger where a route could pick it up.

**Files:**
- Modify: `src/mship/core/relay/egress/enforce.py`
- Test: `tests/core/relay/egress/test_enforce.py`

- [ ] **Step 1: Write the failing tests**

In `tests/core/relay/egress/test_enforce.py`, first REMOVE the now-obsolete `HostLockedEnforcer` test (it tests a class this task deletes):

```python
def test_host_locked_enforcer_passes_api_traffic():
    HostLockedEnforcer().check(_req("/api/repos/acme/api/pulls", method="GET"), RUN_GRANT)
```

(The import was already switched to `GitHubApiEnforcer` in Task 2, so no import edit is needed here.)

Then add the enforcer tests. `RUN_GRANT` (already defined at the top of the file) is scoped to `("acme/api", "acme/web")`, and `_req(path, method=...)` builds an `EgressRequest` via `parse_egress_request`:

```python
def test_api_enforcer_permits_in_scope_pr_create():
    GitHubApiEnforcer().check(_req("/api/repos/acme/api/pulls", method="POST"), RUN_GRANT)


def test_api_enforcer_permits_safe_global_read():
    GitHubApiEnforcer().check(_req("/api/rate_limit", method="GET"), RUN_GRANT)


def test_api_enforcer_denies_merge():
    with pytest.raises(EnforcementError):
        GitHubApiEnforcer().check(_req("/api/repos/acme/api/pulls/1/merge", method="PUT"), RUN_GRANT)


def test_api_enforcer_denies_ref_mutation():
    with pytest.raises(EnforcementError):
        GitHubApiEnforcer().check(
            _req("/api/repos/acme/api/git/refs/heads/main", method="PATCH"), RUN_GRANT
        )


def test_api_enforcer_denies_out_of_scope_repo():
    # acme/other is NOT in RUN_GRANT.repos -> even a permitted shape is refused.
    with pytest.raises(EnforcementError):
        GitHubApiEnforcer().check(_req("/api/repos/acme/other/pulls", method="POST"), RUN_GRANT)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `uv run pytest tests/core/relay/egress/test_enforce.py -v`
Expected: FAIL — `AttributeError`/`ImportError` for `GitHubApiEnforcer` (not yet defined), and a `NameError: HostLockedEnforcer` collection error would arise only if the old test were kept — confirm you removed it.

- [ ] **Step 3: Write the implementation**

In `src/mship/core/relay/egress/enforce.py`, add the enforcer (place it where `HostLockedEnforcer` was), and DELETE the entire `HostLockedEnforcer` class:

```python
class GitHubApiEnforcer:
    """DEFAULT-DENY enforcer for the worker's api.github.com PR-egress leg.

    Permits only opening/managing the run's PR + comments/reviews + reads scoped
    to the run's repos (plus the safe globals /rate_limit, /user). Every
    repo-scoped permit additionally requires the path's owner/repo to be within
    grant.scope.repos (same containment as the git leg). Everything else raises
    EnforcementError, which the proxy maps to 403. Merge, POST /merges,
    git/refs mutation, and contents mutation are all denied — the API leg cannot
    sidestep the git push-to-run-branch enforcement."""

    def check(self, request: EgressRequest, grant: Grant) -> None:
        in_scope = request.repo is not None and request.repo in grant.scope.repos
        if not classify_api_request(request.method, request.upstream_path, in_scope):
            raise EnforcementError(
                f"github api request refused: {request.method} {request.upstream_path} "
                f"(repo={request.repo!r}, in_scope={in_scope})"
            )
```

DELETE this class entirely (lines 66-71 in the current file):

```python
class HostLockedEnforcer:
    """No ref-level policy: the API surface is bounded by the repo-scoped App
    token + the Attachment host-lock. Passes; documents the boundary."""

    def check(self, request: EgressRequest, grant: Grant) -> None:
        return
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `uv run pytest tests/core/relay/egress/test_enforce.py -v`
Expected: PASS — the git-leg tests, the 25 classifier cases, and the 5 new `GitHubApiEnforcer` tests all green; no reference to `HostLockedEnforcer` remains.

- [ ] **Step 5: Commit + journal**

```bash
git add src/mship/core/relay/egress/enforce.py tests/core/relay/egress/test_enforce.py
git commit -m "feat(relay): GitHubApiEnforcer (scope lookup + default-deny); drop dead HostLockedEnforcer"
mship journal "GitHubApiEnforcer.check does scope lookup + classifier + raise; removed the dead HostLockedEnforcer placeholder; enforce tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: re-add the `api.github.com` route

Add `api.github.com` back to `build_default_routes` with the same github-app provider as the git leg + the new `GitHubApiEnforcer`. With the route present, an `/api/` request no longer 404s as an unknown host. Rewrite the docstring (it currently explains why the route was dropped).

**Files:**
- Modify: `src/mship/core/relay/egress/routes.py`
- Test: `tests/core/relay/egress/test_routes.py`

- [ ] **Step 1: Rewrite the failing test**

In `tests/core/relay/egress/test_routes.py`, REPLACE `test_default_routes_ship_git_only_with_branch_enforcer` (it asserts `api.github.com` raises `UnknownHostError`, which this task reverses). Add the `GitHubApiEnforcer` import to the existing enforce import line:

```python
from mship.core.relay.egress.enforce import GitSmartHttpEnforcer, GitHubApiEnforcer
```

Replace the test with:

```python
def test_default_routes_include_git_and_api_enforcers():
    # The git leg is fully branch-enforced; the api leg is default-deny (PR-only)
    # via GitHubApiEnforcer. Both share the github-app provider.
    table = build_default_routes(_FakeProvider())
    assert isinstance(table.resolve("github.com").enforcer, GitSmartHttpEnforcer)
    api_route = table.resolve("api.github.com")
    assert isinstance(api_route.enforcer, GitHubApiEnforcer)
    assert api_route.provider is table.resolve("github.com").provider
```

(Keep `test_unknown_host_is_rejected_not_defaulted` unchanged — `evil.example.com` still raises.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `uv run pytest tests/core/relay/egress/test_routes.py -v`
Expected: FAIL — `test_default_routes_include_git_and_api_enforcers` raises `UnknownHostError` on `table.resolve("api.github.com")` (route not present yet).

- [ ] **Step 3: Write the implementation**

In `src/mship/core/relay/egress/routes.py`, update the enforce import (line 5) to pull in the new enforcer:

```python
from mship.core.relay.egress.enforce import Enforcer, GitSmartHttpEnforcer, GitHubApiEnforcer
```

Then replace `build_default_routes` (docstring + return) with:

```python
def build_default_routes(provider: CredentialProvider) -> RouteTable:
    """v1 ships two GitHub legs, both on the github-app provider:

    - github.com    -> GitSmartHttpEnforcer: clone/fetch + push only the run
      branch to a run-scoped repo (fully branch-enforced).
    - api.github.com -> GitHubApiEnforcer: DEFAULT-DENY REST leg permitting only
      opening/managing the run's PR + comments/reviews + repo-scoped reads. It
      refuses merge, POST /merges, git/refs mutation, and contents mutation, so
      the API leg cannot sidestep the git push-to-run-branch enforcement.

    Both hosts already ride the same egress subdomain (path-prefix /gh/ vs /api/,
    one Caddy block, one tls_ask entry) and the Attachment host-locks the token to
    [github.com, api.github.com] — adding the api leg needs no new deploy surface.
    Adding a host stays a data entry (+ one /prefix/ in request.py)."""
    return RouteTable(
        {
            "github.com": Route(provider=provider, enforcer=GitSmartHttpEnforcer()),
            "api.github.com": Route(provider=provider, enforcer=GitHubApiEnforcer()),
        }
    )
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `uv run pytest tests/core/relay/egress/test_routes.py -v`
Expected: PASS — both route tests green.

- [ ] **Step 5: Commit + journal**

```bash
git add src/mship/core/relay/egress/routes.py tests/core/relay/egress/test_routes.py
git commit -m "feat(relay): re-add api.github.com route with GitHubApiEnforcer"
mship journal "api.github.com re-added to build_default_routes (github-app provider + GitHubApiEnforcer); /api/ no longer 404s; route tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: proxy integration tests for the api leg (FastAPI TestClient)

End-to-end through `build_egress_app`: a permitted PR-create for an in-scope repo attaches the minted token + forwards to `api.github.com`; a merge attempt and an out-of-scope repo are both 403 *before* egress (never forwarded); and the api leg still fails CLOSED (503) when App creds are absent (`routes=None`). This mirrors the existing git-leg proxy tests; reuse the `_StubProvider`, `_capture_upstream`, `_app`, and `_token` fixtures already in the file.

**Files:**
- Test: `tests/core/relay/egress/test_proxy.py`

- [ ] **Step 1: Write the failing tests**

Append to `tests/core/relay/egress/test_proxy.py` (the imports it needs — `httpx`, `TestClient`, the `_StubProvider`/`_capture_upstream`/`_app`/`_token` helpers — are already at the top of the file). The run token issued by `_token` is scoped to `("acme/api",)`, so `acme/web` is out of the run scope even though it is in the enrollment ceiling `("acme/api", "acme/web")`:

```python
_PR_BODY = b'{"title":"x","head":"feat/x","base":"main"}'


def test_api_pr_create_for_in_scope_repo_attaches_token_and_forwards(tmp_path):
    seen: dict = {}
    provider = _StubProvider()
    app, base = _app(tmp_path, provider, _capture_upstream(seen))
    token = _token(base)
    resp = TestClient(app).post(
        "/api/repos/acme/api/pulls",
        content=_PR_BODY,
        headers={"Mship-Run-Token": token, "Content-Type": "application/json"},
    )
    assert resp.status_code == 200
    assert resp.content == b"ok-from-github"
    assert seen["host"] == "api.github.com"
    assert seen["authorization"] == "token ghs_minted"   # real cred attached at egress
    assert seen["run_token"] is None                     # placeholder never leaves the relay
    assert provider.calls == [("enr1", ("acme/api",), "acme/api")]


def test_api_merge_attempt_is_rejected_before_egress(tmp_path):
    seen: dict = {}
    app, base = _app(tmp_path, _StubProvider(), _capture_upstream(seen))
    token = _token(base)
    resp = TestClient(app).put(
        "/api/repos/acme/api/pulls/1/merge",
        content=b"{}",
        headers={"Mship-Run-Token": token, "Content-Type": "application/json"},
    )
    assert resp.status_code == 403
    assert seen == {}                                    # never forwarded


def test_api_out_of_scope_repo_is_rejected_before_egress(tmp_path):
    seen: dict = {}
    app, base = _app(tmp_path, _StubProvider(), _capture_upstream(seen))
    token = _token(base)  # run scope is ("acme/api",); acme/web is out of the run scope
    resp = TestClient(app).post(
        "/api/repos/acme/web/pulls",
        content=_PR_BODY,
        headers={"Mship-Run-Token": token, "Content-Type": "application/json"},
    )
    assert resp.status_code == 403
    assert seen == {}                                    # never forwarded


def test_api_leg_fails_closed_503_without_provider(tmp_path):
    app, base = _app(tmp_path, None, _capture_upstream({}))
    token = _token(base)
    resp = TestClient(app).post(
        "/api/repos/acme/api/pulls", content=_PR_BODY,
        headers={"Mship-Run-Token": token, "Content-Type": "application/json"},
    )
    assert resp.status_code == 503
```

- [ ] **Step 2: Run the tests to verify they pass**

Run: `uv run pytest tests/core/relay/egress/test_proxy.py -v`
Expected: PASS. (These pass immediately because Tasks 1–4 already wired the api leg end-to-end. If any FAIL, the failure localizes the integration gap: a 404 means the route is missing (Task 4); a 200 on the merge/out-of-scope tests means the enforcer let it through (Tasks 2–3); a wrong `provider.calls` repo means the api-path extractor is off (Task 1).)

If you want a genuine red-first for this task, run it after Task 1 only — the merge/out-of-scope tests will 200-and-forward — then confirm green after Task 4.

- [ ] **Step 3: Run the full egress suite**

Run: `uv run pytest tests/core/relay/egress/ -v`
Expected: PASS — every egress test (request, enforce, routes, proxy, credential, provider, pktline) green.

- [ ] **Step 4: Commit + journal**

```bash
git add tests/core/relay/egress/test_proxy.py
git commit -m "test(relay): proxy integration coverage for the api.github.com PR-egress leg"
mship journal "proxy integration tests for the api leg: permit forwards+attaches, merge 403 pre-egress, out-of-scope 403, fail-closed 503; full egress suite passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: docs — the api leg is back + enforced

Update `docs/cloud-worker-auth-spine.md`: the `api.github.com` leg is live behind a real enforcer, exactly what it permits vs denies, that merge is explicitly forbidden (review-gated — nothing auto-merges), that no new deploy surface is needed (path-prefix on the existing egress host + the Attachment host-lock), and that this is the deferred worker-API leg from the auth-spine slice, now done. This is a docs-only task — no code changes.

**Files:**
- Modify: `docs/cloud-worker-auth-spine.md`

- [ ] **Step 1: Update the module inventory (Section 7)**

Replace the `enforce.py` bullet in Section 7 (currently: `` - `enforce.py` — `GitSmartHttpEnforcer` (run-branch-only push), `HostLockedEnforcer`. ``) with:

```markdown
- `enforce.py` — `GitSmartHttpEnforcer` (run-branch-only push), `GitHubApiEnforcer`
  (default-deny PR-only REST leg) + `classify_api_request` (its pure classifier).
```

- [ ] **Step 2: Replace the "API route deferred" callout**

Replace the blockquote near the end of Section 6 (currently the `> **API route deferred on the worker.** …` note) with:

```markdown
> **The api.github.com leg is live + enforced.** The worker opens (and lightly
> manages) its own PR through the `/api/` egress leg (operator decision B). The
> route is back on the github-app provider behind `GitHubApiEnforcer`, a
> DEFAULT-DENY REST enforcer (below). This is the API leg the auth-spine slice
> deferred, now done with a real enforcer instead of a pass-through — so the API
> path cannot sidestep the git push-to-run-branch enforcement.
```

- [ ] **Step 3: Add the enforcer allowlist subsection**

Insert a new section after Section 7 (append to the end of the file):

```markdown
## 8. The api.github.com leg — `GitHubApiEnforcer` (default-deny, PR-only)

The worker opens its own PR, which is a REST call (`POST /repos/{o}/{r}/pulls`).
So the `api.github.com` route is routed on the **same** github-app provider as the
git leg, behind `GitHubApiEnforcer`. Containment is two independent layers: (a) the
repo-scoped App installation token already bounds every call to the run's repos;
(b) the enforcer is DEFAULT-DENY over the REST surface — it permits an enumerated
allowlist and refuses everything else (403). New/unknown GitHub endpoints are denied
by construction: the safe failure mode is a blocked worker call, never an unexpected
mutation.

**PERMIT (and nothing else):**
- `POST  /repos/{o}/{r}/pulls` — open a PR
- `PATCH /repos/{o}/{r}/pulls/{n}` — update the run's PR (title/body/state); **not** merge
- `POST  /repos/{o}/{r}/issues/{n}/comments` — comment
- `POST  /repos/{o}/{r}/pulls/{n}/reviews`, `POST /repos/{o}/{r}/pulls/{n}/requested_reviewers` — review / request review
- `GET   /repos/{o}/{r}/...` — reads scoped to the run's repos
- `GET   /rate_limit`, `GET /user` — safe global reads

Every repo-scoped permit ALSO requires the path's `owner/repo` to be within the
run's `scope.repos` (an out-of-scope repo is refused — same containment as the git
leg).

**Explicitly DENIED (named + tested, though default-deny already covers them):**
- `PUT /repos/{o}/{r}/pulls/{n}/merge` — merging a PR. **Nothing auto-merges**; the
  fan-out is review-gated end to end (#393), so merge is denied even though the
  token technically could. Note this is a DIFFERENT path from the permitted
  `PATCH /pulls/{n}`.
- `POST /repos/{o}/{r}/merges`
- `POST|PATCH|DELETE /repos/{o}/{r}/git/refs/*` — ref mutation
- `PUT|DELETE /repos/{o}/{r}/contents/*` — content mutation

These are exactly the REST paths that could sidestep the git push-to-run-branch
enforcement, so they are called out even though default-deny refuses them anyway.
GraphQL (`/graphql`) is not routed (REST-only in v1; it would need its own enforcer).

**No new deploy surface.** The api leg rides the existing egress subdomain: the
`/api/` path prefix is already mapped in `request.py`, the worker config already sets
`url."…/api/".insteadOf "https://api.github.com/"` (Section 6), the Attachment already
host-locks the token to `[github.com, api.github.com]`, and one Caddy block + one
`tls_ask` entry already front the whole `egress.<RELAY_DOMAIN>` host. Adding the leg
was a route-table entry + enforcer, not a new route/TLS allowance. The proxy still
fails CLOSED on the api leg (App creds absent -> 503, never forward).
```

- [ ] **Step 4: Verify the doc has no stale references**

Run: `grep -n "HostLockedEnforcer\|API route deferred\|api.github.com.*NOT routed\|intentionally not routed" docs/cloud-worker-auth-spine.md`
Expected: no matches (every stale "api is dropped/deferred" statement is gone).

- [ ] **Step 5: Commit + journal**

```bash
git add docs/cloud-worker-auth-spine.md
git commit -m "docs: api.github.com PR-egress leg is live + enforced (GitHubApiEnforcer allowlist)"
mship journal "documented the api leg return: GitHubApiEnforcer permit/deny allowlist, merge explicitly denied (review-gated), no new deploy surface; removed stale 'deferred' notes" --action committed
```
<!-- /mship:task -->

---

## Self-Review

### 1. Spec coverage — every AC maps to a task

| AC | Requirement (abbrev.) | Task(s) |
|----|-----------------------|---------|
| ac1 | api.github.com re-added to `build_default_routes` + `GitHubApiEnforcer`; App token attached host-locked; no more 404 | Task 4 (route) + Task 5 (proxy: attaches + forwards, `seen["host"]=="api.github.com"`) |
| ac2 | api-path repo extractor; non-repo paths recognized as repo-less | Task 1 |
| ac3 | `GitHubApiEnforcer` DEFAULT-DENY; permits only the allowlist, refuses everything else (403) | Task 2 (classifier + full matrix) + Task 3 (enforcer + raise) |
| ac4 | explicitly refuses merge, `merges`, `git/refs/*`, `contents/*` (named + tested) | Task 2 (`_API_DENY` matrix) + Task 3 (`test_api_enforcer_denies_merge`, `..._denies_ref_mutation`) |
| ac5 | every repo-scoped permit requires owner/repo ∈ `scope.repos`; out-of-scope 403 | Task 3 (`in_scope` lookup + `test_api_enforcer_denies_out_of_scope_repo`) + Task 5 (proxy out-of-scope 403) |
| ac6 | unit-tested hard: permit each call; deny merge/merges/refs/contents/out-of-scope/unknown; proxy fails CLOSED (503) | Task 2 + Task 3 + Task 5 (`test_api_leg_fails_closed_503_without_provider`) |
| ac7 | no new deploy surface — path-prefix routing on the existing egress host; worker reaches it with the same config | Task 4 (route present so `/api/` resolves) + Task 6 (documented: prefix/Caddy/tls_ask/host-lock unchanged) |
| ac8 | docs updated: leg back, permit vs deny, merge forbidden (review-gated), deferred-slice-now-done | Task 6 |

No AC is left without a task.

### 2. Placeholder scan

Searched the plan for the "No Placeholders" red flags (TBD/TODO/"handle edge cases"/"add more cases"/"similar to Task N"/"write tests for the above"). None present: the full 25-case classifier matrix is enumerated (`_API_PERMIT` 10 rows + `_API_DENY` 15 rows), every enforcer/route/proxy test is written out in full, and every implementation step shows the real code (extractor, classifier, enforcer, route table, doc prose). Every referenced symbol is defined in a task.

### 3. Type/name consistency

- `_extract_api_repo` — defined Task 1, used only in Task 1 (`parse_egress_request`). ✔
- `classify_api_request(method, path, in_scope) -> bool` — defined Task 2, imported/used in Task 2 tests and Task 3 enforcer (same signature, `in_scope` bool). ✔
- `GitHubApiEnforcer` — defined Task 3; imported in Task 2 (import line), Task 3 (tests), Task 4 (routes + test); `.check(request, grant)` matches the `Enforcer` protocol in `enforce.py`. ✔
- `EgressRequest.repo` set for the api host in Task 1; consumed by `GitHubApiEnforcer.check` (`request.repo`) in Task 3 and asserted in `provider.calls` in Task 5. ✔
- `HostLockedEnforcer` removed in Task 3; its import is dropped in Task 2's rewritten import line and its Section-7 mention is removed in Task 6. No dangling reference. ✔
- Test-run command is `uv run pytest …` in every task. ✔

### 4. Notes / decisions flagged for the operator

- **`EgressRequest.repo` for the api host:** set via a new `_extract_api_repo` (branch on host in `parse_egress_request`), NOT by extending `_extract_repo` — the two rules differ (git `.git` suffix vs `/repos/` prefix). This changes the existing `test_api_prefix_maps_to_api_host_with_no_repo` (which asserted `repo is None`); Task 1 replaces it.
- **`HostLockedEnforcer` is removed** (not kept alongside `GitHubApiEnforcer`). It is a pass-through with no ref policy — the exact placeholder this slice replaces — and leaving it in the tree is a loaded gun (a future route misconfig pointing `api.github.com` at it re-opens the bypass). Its only caller was the dropped api route; its only test is removed in Task 3. If you would rather keep it as dead-but-documented code, say so and I'll leave it (and its test) in place.
- **Classifier returns `bool`** (`True`=permit / `False`=deny) rather than a `"allow"|"deny"` string literal — simpler and matches the `if not classify_...` call site in the enforcer.
- **PATCH vs merge disambiguation** is by exact segment count, not prefix: `PATCH /pulls/{n}` is `rest == ["pulls", n]` (len 2, permitted); `PUT /pulls/{n}/merge` is `rest == ["pulls", n, "merge"]` (len 3, denied). Both are in the test matrix.

---

## Execution Handoff

Plan complete and saved to `docs/plans/2026-07-22-worker-pr-egress.md`. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration. Build each implementer prompt with `mship dispatch --task worker-pr-egress --plan docs/plans/2026-07-22-worker-pr-egress.md --plan-task <N>`.

**2. Inline Execution** — execute tasks in this session using `executing-plans`, batch execution with checkpoints.

Which approach?
