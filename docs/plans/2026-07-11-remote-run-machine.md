# Remote run machine (relay/serve-brokered --remote) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Spec:** `remote-run-machine` (specs/2026-07-11-remote-run-machine.md) — approved. Closes MOS-191 (folds in MOS-203). MOS-194 stays separate (operator-confirmed).

**Goal:** `mship run/capture/build --remote[=<role>]` executes a host-bound verb on a remote mship serve reached over the relay (the remote dials out, so NAT/anywhere works), streaming logs live and pulling capture artifacts home — with logical run-host roles in the public `mothership.yaml` and secrets only in the gitignored `.mothership/`.

**Architecture:** Reuses the whole stack. Client side: `--remote` resolves a role → a local connection and drives the remote's serve over HTTP. Server side: new serve `POST /exec/{verb}` endpoints materialize the branch worktree, run the go-task target (the same backend-agnostic contract), and stream stdout back. Two-layer config: roles (public yaml) → connections (gitignored store).

**Tech Stack:** Python (FastAPI serve, httpx, pytest). Single repo: mothership. **Work from:** `.worktrees/remote-run-machine/mothership`.

**Key references (from the codebase map):**
- Execution seam: `util/shell.py` `ShellRunner` (`run`/`run_task`/`run_streaming`), injected via `container.shell()`. `RepoExecutor` (`core/executor.py`) + `core.capture.run_capture` receive it.
- `run`/`capture`/`build` CLIs: `cli/exec.py` (`run_cmd` ~:307, and `build`), `cli/capture.py` (`capture` ~:22). Capture contract: env vars `MSHIP_CAPTURE_DIR/_KINDS/_PLATFORM`; artifacts land in `.mothership/captures/<task|_adhoc>/<UTCts>-<platform>/` (`cli/capture.py:104-110`); filenames `screen.png`/`layout.*` (`core/capture.py:18-23`).
- Config: `core/config.py` — `WorkspaceConfig` (`run_hosts` slots by `relay`, :148), `RepoConfig` (`capture: CaptureConfig`, :56), `ConfigLoader.load`. `relay/config.py` `RelayConfig` is the dataclass template.
- serve: `core/serve.py` `create_app` — bearer dep `_make_auth_dependency` (auto-applied), `@app.post(...)` closures, `PRManager`/`ShellRunner`/`WorktreeManager`/`state_manager` in scope. FastAPI `StreamingResponse` for live output.
- worktree: `core/worktree.py` `WorktreeManager.spawn` (creates `.worktrees/<slug>/<repo>` off `origin/<base>`); `.mothership/` is clone-local + gitignored.
- pairing/relay: `mship serve --relay` (device subdomain), `relay/pairing.py` build_pair_link / PairLink.parse, `relay/token.py` ensure_serve_token.

---

<!-- mship:task id=1 -->
### Task 1: Two-layer run-host config + resolution

**Files:** `core/config.py` (WorkspaceConfig.run_hosts + repo verb→role); Create `core/run_host/config.py` + `core/run_host/store.py`; Test `tests/core/run_host/`.

- [ ] **Step 1: Failing tests.** `run_hosts: [ios-sim-host]` parses from mothership.yaml into `WorkspaceConfig.run_hosts: list[str]`; a repo can declare a role for a verb (e.g. `capture.run_host` or `repo.run_host`); the gitignored store `.mothership/run-hosts.yaml` loads/saves `role -> {url, token}`; env `MSHIP_RUN_HOST_<ROLE>_URL/_TOKEN` overrides the file; `resolve_run_host(role, repo, config, store)` returns the connection for an explicit role, falls back to the repo-declared role, else the sole configured role, and raises actionable errors for unknown/ambiguous/declared-but-unmapped.

- [ ] **Step 2–4: Implement.**
  - `WorkspaceConfig.run_hosts: list[str] = []` (logical role names, non-secret). Optionally a repo-level/verb-level `run_host: str | None` (start with `RepoConfig.run_host` for simplicity; note capture-specific if needed).
  - `core/run_host/config.py`: `@dataclass(frozen=True) RunHostConnection: url: str; token: str`.
  - `core/run_host/store.py`: load/save `.mothership/run-hosts.yaml` (`{role: {url, token}}`), created with `0o600`; `get(role)` overlays env (`MSHIP_RUN_HOST_<ROLE>_URL/_TOKEN`, role upper-cased with `-`→`_`); a `redacted_list()` (url shown, token masked).
  - `resolve_run_host(role: str | None, *, repo, config, store) -> RunHostConnection`: role = explicit `--remote=role`, else `repo.run_host`, else (len(config.run_hosts)==1 → that one) else error "ambiguous — pass --remote=<role>". If the role isn't in `config.run_hosts` → error "unknown run-host role". If it is but the store has no mapping → error "role '<r>' not mapped on this machine — run: mship run-host add <r> …".

- [ ] **Step 5: Green** (`mship test`). **Commit + journal.**
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: `mship run-host` command group

**Files:** Create `cli/run_host.py`; register in `cli/__init__.py`; Test `tests/cli/test_run_host.py`.

- [ ] **Step 1: Failing tests** (Typer CliRunner): `mship run-host add <role> --url <u> --token <t>` writes the gitignored store (0o600); `run-host add <role> --pair-link "<groundcontrol://… or serve pair link>"` parses url+token via the existing pair-link parser; `run-host list` shows role+url with the token REDACTED; `run-host remove <role>` deletes it. Store file is gitignored (verify it's under `.mothership/`).

- [ ] **Step 2–4: Implement** the `run-host` Typer group backed by the Task 1 store. `add`/`pair` accept either explicit `--url/--token` or a `--pair-link` (reuse `relay/pairing.py` PairLink.parse / build_pair_link semantics — the same {url, token} shape). `list` uses `store.redacted_list()`. Match existing CLI-group registration (mirror `cli/relay.py`).

- [ ] **Step 5: Green** (`mship test`). **Commit + journal.**
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: serve `POST /exec/{verb}` — branch materialize + run + live streaming + MOS-203

**Files:** `core/serve.py` (new endpoint + a helper module `core/remote_exec.py` for the run logic); Test `tests/core/test_serve_exec.py`.

- [ ] **Step 1: Failing tests** (TestClient): `POST /exec/run` (bearer required → 401 without) with `{task, repos}` (a) materializes the task's branch worktree on this workspace (mock WorktreeManager/git), (b) runs the repo's go-task target via a fake ShellRunner, (c) STREAMS the stdout back (assert chunks arrive + the final exit code is conveyed); a non-zero task exit is conveyed (not a 500). `POST /exec/capture` sets the capture env vars. Before materialize, the MOS-203 base-staleness check runs (assert it warns/fetches when base is behind — mock the git state).

- [ ] **Step 2–4: Implement.**
  - `core/remote_exec.py`: `run_verb(verb, task, repos, platform, *, deps) -> AsyncIterator[bytes]` (or a sync generator adapted): ensure the branch worktree (reuse `WorktreeManager`), run `task <target>` via `ShellRunner.run_streaming` in the worktree with the capture env contract (for capture: set `MSHIP_CAPTURE_DIR` to a remote temp dir, `MSHIP_CAPTURE_KINDS`, `MSHIP_CAPTURE_PLATFORM`), and yield stdout/stderr chunks; end with an exit-code marker. Run the MOS-203 base check first (behind origin → warn line into the stream / auto-fetch).
  - `core/serve.py`: `@app.post("/exec/{verb}")` (verb ∈ run|capture|build) returning `StreamingResponse(run_verb(...), media_type="application/octet-stream")` (or `text/event-stream`). Inherits the bearer dep. Validate `verb`; 404 on unknown.
  - Use `asyncio.to_thread`/an async wrapper so the blocking subprocess streams without blocking the loop.

- [ ] **Step 5: Green** (`mship test`). **Commit + journal.**
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: Capture artifact round-trip (serve side)

**Files:** `core/serve.py` / `core/remote_exec.py` (make capture artifacts fetchable); Test `tests/core/test_serve_exec.py`.

- [ ] **Step 1: Failing tests**: after a remote `capture`, the produced `screen.png`/`layout.*` in the remote capture dir are retrievable — either streamed inline as a tar at the end of `/exec/capture`, or via a follow-up `GET /exec/capture/{id}/artifacts` that returns a tar. Assert the tar contains the expected filenames.

- [ ] **Step 2–4: Implement** the artifact-return: after the remote capture task completes, `discover_artifacts` the remote capture dir (reuse `core/capture.py`'s discovery) and stream the files back as a tar (stdlib `tarfile` into the response). Keep it simple: inline tar trailer on `/exec/capture`, OR a short-lived `GET` keyed by a run id — pick the simpler; document the contract for Task 5's client.

- [ ] **Step 5: Green** (`mship test`). **Commit + journal.**
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: Client-side `--remote[=role]` on run/capture/build

**Files:** `cli/exec.py` (run + build), `cli/capture.py`; a client helper `core/remote_client.py`; Test `tests/cli/test_remote_dispatch.py`.

- [ ] **Step 1: Failing tests**: `mship run --remote=ios-sim-host` resolves the role → connection (Task 1), POSTs to `{url}/exec/run` with the bearer, and RENDERS the streamed output live (assert chunks printed); `mship capture --remote` pulls the returned tar into the LOCAL `.mothership/captures/<task|_adhoc>/<UTCts>-<platform>/` (assert files land at the exact local path). Critically: WITHOUT `--remote`, the local path is byte-for-byte unchanged (assert the remote client is never touched). A non-zero remote exit → non-zero local exit.

- [ ] **Step 2–4: Implement.**
  - `core/remote_client.py`: `exec_remote(verb, conn, task, repos, platform) -> int` — httpx streaming GET/POST to `{conn.url}/exec/{verb}` with `Authorization: Bearer {conn.token}`, iterate the response, write chunks to the local terminal live, return the conveyed exit code; for capture, receive the tar and extract into the local captures dir (compute the path exactly as `cli/capture.py:104-110`).
  - Add `--remote` (Optional[str], flag-or-value) to `run`/`build` (`cli/exec.py`) and `capture` (`cli/capture.py`). When set → resolve_run_host + `exec_remote`; when unset → the existing local code path untouched.

- [ ] **Step 5: Green** (`mship test`). **Commit + journal.**
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: Failure modes polish + docs

**Files:** the run_host resolution + client + exec paths (error messages); Create `docs/remote-run.md`; Test the error cases.

- [ ] **Step 1: Failing tests** for each actionable error: unknown/ambiguous `--remote` role; role declared but unmapped (names the `run-host add` fix); remote serve unreachable (connection error → clear "unreachable via relay"); remote workspace not bootstrapped; remote task non-zero (exit + streamed output preserved).

- [ ] **Step 2–4: Implement** the error surfacing across resolve_run_host / exec_remote / the exec endpoint (map connection errors, 4xx/5xx, unbootstrapped remote to specific messages). **Docs `docs/remote-run.md`:** the remote runs `mship serve --relay` (one-time bootstrap); declare logical roles in mothership.yaml; `mship run-host add <role>` from the remote's pair link; `mship run/capture/build --remote[=role]`; the two-credential model; the artifact landing path.

- [ ] **Step 5: Green** (`mship test`). **Commit + journal.**
<!-- /mship:task -->

---

## Self-Review

- **Spec coverage:** ac1 (flag+resolution)→T1+T5; ac2/ac3 (two-layer config, secrets, run-host cmd)→T1+T2; ac4 (exec endpoint + materialize)→T3; ac5 (streaming)→T3+T5; ac6 (capture env contract)→T3; ac7 (artifact round-trip)→T4+T5; ac8 (auth)→T1(token store)+T3(bearer dep)+T5(bearer send); ac9 (MOS-203)→T3; ac10 (failures)→T6; ac11 (tests, no new deps)→every task. ✓
- **Type consistency:** `RunHostConnection{url,token}` (T1) is what `resolve_run_host` returns (T1/T5) and `exec_remote` consumes (T5). The `/exec/{verb}` contract (streamed stdout + exit code + capture tar) is defined in T3/T4 and consumed in T5. The capture-artifact local path is computed identically to `cli/capture.py:104-110` on both the pull side (T5) and the local path (unchanged). ✓
- **Ordering:** T1 (config) → T2 (cmd, uses store) → T3 (serve exec/stream) → T4 (serve artifacts) → T5 (client, uses T1 resolve + T3/T4 contract) → T6 (polish+docs). Single repo, sequential.
- **Out of scope (operator-confirmed):** direct-ssh; run/build artifact-pull (stream-only); MOS-194 (separate); remote auto-provisioning; state sync-back; concurrency.
