# Mothership daemon provisioning and supervision (#470) — implementation plan

> Spec: `specs/2026-08-16-mship-daemon-lifecycle-470.md` (mship spec `mship-daemon-lifecycle-470`) · GitHub issue: atomikpanda/mothership#470 · Parent: #469.
> Produced by an ultracode workflow (5 codebase readers → 2 independent drafts → judge synthesis → 3 adversarial verifiers; 21 verified findings folded in, incl. the launchd loser-exit-code and lease inode-swap blocker).

# Implementation Plan

## Assumptions

- **Metarepo/cross-repo workspaces (per #472's warning):** the daemon serves **zero** workspaces in v1, so no code in this plan may branch on workspace shape — the guard is structural. All daemon state is **per-OS-user** (`~/.mothership/daemon/`, beside the existing per-machine relay identity, `src/mship/core/relay/keys.py:25-35`), never per-workspace `.mothership/`. Nothing here reads `cwd`, `mothership.yaml`, `ConfigLoader.discover`, or resolves `get_container`'s workspace; the unit has no `WorkingDirectory=` and the daemon must start from anywhere. Workspace addressing — with metarepo workspaces first-class — arrives with #472 through the named seams, as future entries in a list-shaped field, so single-repo bias cannot be baked in here.
- Ops-first: systemd/launchd own restart/backoff; `mshipd` owns singleton-ness, logs, start-history, control socket. No mship-side restart loop.
- Python ≥3.14; `fastapi`, `uvicorn` (`uds=` supported), `httpx` (`HTTPTransport(uds=...)`) already deps. **No new dependencies.**
- Runtime socket: `$XDG_RUNTIME_DIR/mship/daemon.sock`; fallback `~/.mothership/daemon/run/daemon.sock` (0700 dir) when `XDG_RUNTIME_DIR` is unset (macOS, some containers). The daemon and a probing CLI can compute *different* paths when their environments differ (systemd-provided `XDG_RUNTIME_DIR` vs a bare shell), so the lease JSON records `socket_path` and **every probe uses the lease's recorded path**, falling back to the computed path only when no lease exists. Filesystem perms are the auth; no bearer token on the local socket. Remote traffic stays on the #471 tunnel path.
- **Loser/status exit-code policy (cross-OS, decided up front):** launchd has no `SuccessExitStatus` equivalent — `KeepAlive.SuccessfulExit=false` relaunches on *any* nonzero exit every `ThrottleInterval` — so the supervised lease loser exits **0** on both OSes when the holder is confirmed live, and nonzero when the lease is contended-but-dead (supervisor should retry). CLI/status paths never touch the lease flock, so a status probe can never make a starting daemon lose its race.
- `mship serve`, `get_container`, and the DI container are not modified. Core daemon modules raise typed exceptions; only `src/mship/cli/daemon.py` raises `typer.Exit` (avoids the `typer.Exit`-in-core coupling already present in `cli/serve.py:11-50`).

All paths relative to `/home/bailey/development/repos/mship-workspace/mothership`.

## Layout

- `src/mship/core/daemon/` — `paths.py`, `lease.py`, `history.py`, `control.py`, `run.py` (+ `__main__.py`), `units.py`, `supervisor.py`, `status.py`
- `src/mship/cli/daemon.py` — `register(app, get_container)` like every CLI module; wired into `src/mship/cli/__init__.py`
- `pyproject.toml` — add `mshipd = "mship.core.daemon.run:main"` to `[project.scripts]` (one line; `uv tool install` exposes it beside `mship` from the same dist)
- Tests: `tests/core/daemon/test_{paths,lease,history,control,run,units,supervisor,status}.py`, `tests/cli/test_daemon.py`; manual checklist in `docs/daemon.md`

<!-- mship:task id=1 -->
## Task 1 — Daemon paths + single-instance lease

**Failing tests first** — `tests/core/daemon/test_paths.py`:
- `daemon_state_dir(home)` → `<home>/.mothership/daemon`; `daemon_log_dir`, `lease_path`, `start_history_path` derived from it; `daemon_socket_path(env, home)` prefers `$XDG_RUNTIME_DIR/mship/daemon.sock`, falls back under `daemon_state_dir/run/`; parent dirs created 0700. Pure functions taking `home: Path` and `env: Mapping[str, str]` explicitly — no ambient reads (injectable-`home` style of `relay/keys.py:25-35`).

`tests/core/daemon/test_lease.py`:
- `test_acquire_creates_lease_and_holds_flock` — acquire in-process; lease JSON `{pid, started_at, version, socket_path}` at `lease_path`; second acquire in a **child process** returns holder `LeaseInfo` (real multiprocessing, mirroring `tests/core/test_store_concurrency.py`).
- `test_late_arrival_after_write_loses` — winner acquires **and completes its JSON write**, THEN a child process attempts acquire and must lose. This deterministically catches the inode-swap failure mode: any tmp+`os.replace` write would leave the winner's flock on an unlinked inode while the late arrival flocks the fresh file and "wins". (The steady-state case — `daemon run` while the unit is up — is exactly this late arrival.)
- `test_stale_lease_dead_pid_is_reclaimed` — lease with dead pid, no flock held → acquire succeeds.
- `test_pid_reuse_does_not_read_as_running` — lease pid points at a *live but unrelated* process (the test's own parent pid), no flock held → still reclaimed. Encodes the contract: **the held flock is the liveness authority; the recorded pid is diagnostic only** (stronger than `inbox_lease._pid_alive`'s signal-0 probe and the fix #470 demands over `live_runtime_record`'s pattern, `core/relay/runtime.py:106`).
- `test_concurrent_cold_start_converges` — N processes race `try_acquire`; exactly one wins; every loser returns a holder-**or-unknown** result (a loser racing the winner's in-progress write may legitimately read an incomplete record — see loser contract below), never a win.

**Implement** — `src/mship/core/daemon/paths.py` as above. `src/mship/core/daemon/lease.py`: `DaemonLease` — flock idiom from `core/state.py:64 _locked` / `core/inbox_lease.py:49`, but the flock (`LOCK_EX | LOCK_NB` on the lease fd) is **held for the process lifetime**, never released until exit. **Never replace the locked file**: open `lease_path` once with `os.open(path, O_RDWR | O_CREAT, 0o600)`, flock that fd, then write the JSON **through the same fd** (`ftruncate(0)` + write + fsync). The tmp+`os.replace` pattern is explicitly wrong here — `os.replace` swaps the inode, stranding the lifetime flock on the old unlinked inode so every later acquirer flocks the new file and succeeds, voiding the single-instance guard. `try_acquire()` returns `None` on win or the holder's `LeaseInfo`; **loser contract:** on flock failure, retry the record read briefly (a few 10 ms attempts — the winner may still be mid-write through its fd), and if still unreadable return `LeaseInfo(pid=None, ...)` meaning "held by unknown". `lease_common.is_reclaimable` (`core/lease_common.py:18`) is reused only for the crashed-holder diagnostic message, not the liveness decision. The lease JSON doubles as the runtime record — no separate record file.

<!-- /mship:task -->

<!-- mship:task id=2 -->
## Task 2 — Start history + crash-loop detector (OS-agnostic visibility)

**Failing tests first** — `tests/core/daemon/test_history.py`:
- `append_start(history_path, now)` / `append_clean_stop(history_path, now)` append typed entries and trim to the last 20; tolerate missing/corrupt file (start fresh).
- Pure `is_crash_looping(entries, now, window_s=600, threshold=3)` truth table counting only **unclean starts** (starts not preceded by a clean stop): under threshold → False; threshold unclean starts inside window → True; old entries outside window ignored; three operator `restart`s (start/stop/start/stop/start) within the window → **False** (routine restarts must not cry loop).

**Implement** — `src/mship/core/daemon/history.py`. Same 0600 atomic-write pattern as `run_host/store.py:63-81` (safe here — nothing flocks this file). This is the crash-loop detector — daemon-owned so it behaves identically under systemd, launchd, and `daemon run`; no `NRestarts`/`launchctl print` parsing. Status renders the count as "N unclean starts in last 10m", not a bare binary. The clean-stop entry is written by `run.py` when `uvicorn.run` returns normally (graceful SIGTERM shutdown) — no bespoke signal code.

<!-- /mship:task -->

<!-- mship:task id=3 -->
## Task 3 — Control app + version identity + socket probe

**Failing tests first** — `tests/core/daemon/test_control.py` (FastAPI `TestClient`, pattern of `tests/core/test_serve.py`):
- `GET /health` returns `{status: "ok", pid, mship_version, protocol: 1, started_at, uptime_s, socket, capabilities: {serve: false, tunnel: false, registry: false, runner: false}}`.
- `test_version_is_captured_at_start_not_reread` — the app reports the `version` value passed at construction even when `mship.__version__` is monkeypatched afterwards (the upgrade-in-place lie #470 calls out).
- `test_probe_control_socket_never_raises` — probe builds `httpx.Client(transport=httpx.HTTPTransport(uds=...))`, GETs `/health`, returns `None` on any failure — mirrors `probe_health`'s never-raise contract (`core/relay/health.py:15`).

**Implement** — `src/mship/core/daemon/control.py`: `create_control_app(*, started_at, version, socket_path) -> FastAPI` — tiny pure closure factory in the style of `create_app` (`core/serve.py:277`), ~40 lines, one route — plus `probe_control_socket(socket_path, client_factory=...) -> dict | None` (client side of the same socket contract; reused by Task 4's loser path and Task 7's status). `version` is **`mship.__version__` captured once by the caller at process start** — the repo's guarded single source of truth (`src/mship/__init__.py`, pinned to pyproject by `tests/test_version.py`). Do **not** use `topology._mship_version()`/importlib.metadata here: both sides returning "unknown" on absent dist metadata would mask real skew, and it is a private helper of another module (the topology/diagnostics near-duplication is pre-existing — flag, don't refactor). `PROTOCOL = 1` module constant. Each `false` capability carries a one-line comment naming its issue (#471/#472/#473) — these are the seams.

<!-- /mship:task -->

<!-- mship:task id=4 -->
## Task 4 — `mshipd` entrypoint + run loop

**Failing tests first** — `tests/core/daemon/test_run.py`:
- `test_main_acquires_lease_then_serves_socket` — monkeypatch `uvicorn.run` (exact `tests/cli/test_serve.py` capture pattern); assert `uds == daemon_socket_path(...)`, no `host`/`port`, lease held and start-history appended before uvicorn is entered.
- `test_lost_race_with_live_holder_exits_zero` — lease pre-held by a child process whose `/health` answers (probe faked) → `main()` returns **0**, uvicorn never called, log message names the holder pid. Exit 0 is the only status that is supervisor-safe on **both** OSes: launchd's `KeepAlive.SuccessfulExit=false` relaunches on any nonzero exit every `ThrottleInterval=5s` (a permanent hot loop), and under systemd `Restart=on-failure` already skips exit 0. The log line, not the exit code, is the diagnostic.
- `test_lost_race_with_dead_holder_exits_nonzero` — flock held but the recorded socket never answers `/health` (after N short retries) → `main()` returns nonzero so the supervisor retries; a flock held by a non-serving process must never produce a success-coded exit (which would park the unit "inactive-success" with zero daemons and no self-heal).
- `test_stale_socket_file_is_removed_before_bind` — leftover socket from a `kill -9` is unlinked after the lease is won (safe: winning the lease proves no live daemon owns it).
- `test_rotating_log_handler_configured` — logging routed to `daemon_log_dir/daemon.log` via `RotatingFileHandler(maxBytes=5MB, backupCount=3)`, with uvicorn's own loggers (`uvicorn`, `uvicorn.error`) attached to the same handler (`log_config=None`).
- `test_uncaught_exception_lands_in_daemon_log` — `uvicorn.run` monkeypatched to raise; the traceback appears in `daemon.log` before `main` re-raises/returns nonzero (the one artifact needed to diagnose a crash loop; without this a crashing daemon leaves an empty rotated log — stderr goes to journald on Linux and nowhere on macOS).
- `test_broken_import_still_appends_history` — monkeypatch the *deferred* control-app import to raise (the botched-upgrade class: missing dep/syntax error in new code); history was appended and the error logged before the nonzero exit.
- `test_clean_stop_recorded` — `uvicorn.run` returning normally appends a clean-stop entry.
- `test_entrypoint_registered` — parse `pyproject.toml` with `tomllib` and assert `[project.scripts]["mshipd"] == "mship.core.daemon.run:main"` (the `tests/test_version.py` precedent — installed-dist `entry_points()` metadata can be stale vs `pythonpath=["src"]`); plus assert `mship.core.daemon.run.main` is importable and callable.

**Implement** — `src/mship/core/daemon/run.py`, **import-minimal at module top** (stdlib + `paths`/`lease`/`history` only; the FastAPI/uvicorn/control imports are deferred to inside `main()` after the history append, so a broken-upgrade `ImportError` still lands in history and the rotating log). `main() -> int`: configure rotating logs (+ uvicorn loggers, + log-and-re-raise wrapper for uncaught exceptions) → `DaemonLease.try_acquire()`; **loser path:** retry the flock briefly, then `probe_control_socket` at the lease-recorded `socket_path` — holder live → log holder pid, return 0; holder never answers → log contended-but-dead, return 1 → winner: `append_start` → unlink stale socket → deferred imports → `uvicorn.run(create_control_app(...), uds=..., log_config=None)` → on normal return, `append_clean_stop`. SIGTERM: rely on uvicorn's default graceful shutdown — no bespoke signal code. `__main__.py` calls `main()` (`python -m mship.core.daemon` fallback, matching the `python -m mship.ci.version_bump` precedent). Add the `[project.scripts]` line; `tests/test_version.py` untouched.

<!-- /mship:task -->

<!-- mship:task id=5 -->
## Task 5 — Unit/plist rendering + exec resolution (crash-restart policy lives here)

**Failing tests first** — `tests/core/daemon/test_units.py` (rendered to `tmp_path`, then **parsed, not substring-matched** — systemd directives are section-scoped and a directive in the wrong section is silently ignored with only an "Unknown lvalue" journal line, so flat `in` assertions would pass CI while the backoff policy is broken on the host):
- systemd unit parsed with `configparser`: `[Service]` has `ExecStart=<resolved mshipd argv>`, `Restart=on-failure`, `RestartSec=5`; `[Unit]` has `StartLimitIntervalSec=300`, `StartLimitBurst=5`; `[Install]` has `WantedBy=default.target`. No `SuccessExitStatus` (the loser exits 0 — Task 4 — so no mapping is needed and none exists for launchd anyway). **No `WorkingDirectory=`** anywhere (the workspace-agnostic assumption made enforceable as a test).
- launchd plist parsed with `plistlib.loads`: `Label == "com.mothership.daemon"`, `KeepAlive == {"SuccessfulExit": False}`, `ThrottleInterval == 5`, `RunAtLoad is True`, `StandardOutPath`/`StandardErrorPath` under `daemon_log_dir` (last-resort net for output that escapes the logging tree — launchd discards stderr otherwise), `ProgramArguments` matching the same resolution rule.
- `test_execstart_resolves_sibling_first` — a fake venv layout where `Path(sys.executable).parent / "mshipd"` exists → it wins even when `shutil.which` would find a different `mshipd` on PATH (same venv bin dir ⇒ provably same dist; this is exactly the uv-tool-install layout).
- `test_which_fallback_verified_against_sys_prefix` — sibling absent, `which()` returns a path under `sys.prefix` → used; `which()` returns a path *outside* `sys.prefix` (stale uv-tool shim while running `uv run mship` from a checkout — the documented worktree workflow) → `resolve_mshipd_argv` raises, and install surfaces "you are running mship from a dev tree; install the tool first". Baking a worktree venv's `sys.executable` into a persistent unit would make `uv tool install --force` + `mship daemon restart` (the documented deploy step, Task 9) silently deploy nothing.
- sibling and which both unavailable within the CLI's own dist → `<sys.executable> -m mship.core.daemon` (patch at the module namespace, per `tests/core/test_doctor.py`).

**Implement** — `src/mship/core/daemon/units.py`: `resolve_mshipd_argv(which=shutil.which) -> list[str]` (sibling-first → prefix-verified which → `-m` fallback; typed error on unverifiable resolution), `render_systemd_unit(argv) -> str`, `render_launchd_plist(argv, log_dir) -> str`. Heredoc-style constants, following the `scripts/relay-bootstrap.sh:~27` precedent (the repo's only unit-generation prior art). Target paths: `~/.config/systemd/user/mship-daemon.service`, `~/Library/LaunchAgents/com.mothership.daemon.plist`.

<!-- /mship:task -->

<!-- mship:task id=6 -->
## Task 6 — Supervisor adapter (single injectable boundary for systemctl/launchctl/loginctl)

**Failing tests first** — `tests/core/daemon/test_supervisor.py` with a recorder fake for `run_cmd` (the `_run_uvicorn`-style seam documented in `tests/cli/test_relay_enroll_server.py`):
- Linux `install()` issues, in order: write unit file → `systemctl --user daemon-reload` → `systemctl --user enable mship-daemon` → `loginctl enable-linger <user>` → `loginctl show-user <user> --property=Linger`, raising `DaemonSupervisorError` unless the reply is `Linger=yes`.
- `start/stop/restart` → `systemctl --user start|stop|restart mship-daemon`.
- `query()` → parses `systemctl --user show mship-daemon --property=ActiveState,SubState` into a small `SupervisorState` dataclass (`active|failed|absent|unreachable`); parse failures → `absent`-with-warning, bus/connection failures → `unreachable`, never a raise. (Crash-loop detection is Task 2's history file, not `NRestarts` parsing.)
- `linger_state()` → Linux runs `loginctl show-user <user> --property=Linger` and parses to `yes|no|unknown` (any failure → `unknown`); launchd returns `unknown` (not applicable). This is the data source for the status re-warn AC — recorder-fake test for both parses.
- `available()` — **probes the user manager, not the binary**: runs `systemctl --user is-system-running`; any reply (even `degraded`/nonzero status output) → True; a connection/bus error (or no `systemctl` at all) → False. Test the false-positive trap directly: `which("systemctl")` succeeds but every `--user` call fails with "Failed to connect to bus" → `available()` False. A second test: `available()` True but `daemon-reload` later fails with a bus error → `DaemonSupervisorError` whose message names `mship daemon run` as the fallback.
- macOS variants (`sys.platform` monkeypatched): write plist → `launchctl bootstrap user/<uid> <plist>` / `bootout user/<uid>/com.mothership.daemon` / `kickstart -k user/<uid>/com.mothership.daemon` — the **`user/<uid>` domain, not `gui/<uid>`**: gui-domain operations fail over SSH with no GUI session ("Bootstrap failed: 5: Input/output error"), which is exactly the headless provisioning scenario #469/#470 describe. A bootstrap failure is detected and re-raised as `DaemonSupervisorError` explaining the cause. `query()` from `launchctl print user/<uid>/...`, parsed leniently to the same states — an unreachable/erroring `launchctl` maps to `unreachable`, never to `absent` (a running daemon must not render "absent" just because launchctl can't be reached from this session).
- `logs_tail(n)` returns the last N lines across `daemon.log` + rotated siblings (fixture files) — pure Python, no journalctl.

**Implement** — `src/mship/core/daemon/supervisor.py`: `SystemdUserSupervisor` / `LaunchdSupervisor`, both taking `run_cmd: Callable = subprocess.run` and `which: Callable = shutil.which`; `pick_supervisor(platform=sys.platform)` factory. **Every** OS-supervisor invocation in the daemon feature goes through this one boundary.

<!-- /mship:task -->

<!-- mship:task id=7 -->
## Task 7 — Status assembly (skew, crash loop, linger, socket probe)

**Failing tests first** — `tests/core/daemon/test_status.py` (all inputs injected, pattern of `tests/cli/test_status.py`):
- `build_status(supervisor_state, linger, lease_info, health, cli_version, history_entries, now)` composes: pid, running version, uptime, socket path, supervisor `active|failed|absent|unreachable`, `crash_loop` line ("N unclean starts in last 10m", from `is_crash_looping`), `linger: yes|no|unknown` (from `linger_state()`, Task 6) with a warning line when `no`, and seam lines `tunnel: not configured (#471)` / `workspaces: registry pending (#472)` / `runner: not configured (#473)`.
- `test_version_skew_detected` — health reports `0.5.51`, CLI's `mship.__version__` is `0.5.52` → `compatible=False`, "restart required: daemon v0.5.51, CLI v0.5.52". Exact-match policy (CI bumps a patch per merge, `.github/workflows/version-bump.yml`).
- `test_five_renderings` — five distinct renderings: **absent** (no lease record, probe fails, supervisor inactive — a stale lease alone never reads as "already running"); **unresponsive** (lease record present, probe fails); **crash-loop**; **healthy** (probe OK, supervisor active); **healthy-but-unsupervised** (probe OK but supervisor `inactive`/`absent` — the normal result of `mship daemon run` in a shell: render "running outside the supervisor — will not survive logout/reboot; run mship daemon install/start", never plain "healthy", which would pretend persistence exists).
- `test_linger_off_warns` — `linger="no"` → the warning line renders (the re-warn AC's implementing test).
- `test_probe_uses_lease_socket_path` — the lease JSON records a `socket_path` different from what `daemon_socket_path(env, home)` computes in the test env (`XDG_RUNTIME_DIR` mismatch between the daemon's systemd-provided environment and the invoking shell) → the probe hits the **lease's** path; only with no lease at all does status fall back to the computed path. Otherwise a healthy daemon renders "unresponsive" purely from env divergence — an undiagnosable outage when the phone is the only client.
- `test_status_never_touches_the_lease_flock` — the status path performs no flock call on the lease file (assert via a spy on the lease module / absence of any lock acquisition). Rationale: liveness is decided by the socket probe + supervisor state; a status probe that transiently flocks the lease can race a starting daemon into its loser path.

**Implement** — `src/mship/core/daemon/status.py`: `build_status(...) -> DaemonStatus` (dataclass) reusing `probe_control_socket` from `control.py` (Task 3), and `restart_blockers() -> list[str]` returning `[]` with a docstring naming it the #473 recovery gate. The lease file is **read-only JSON diagnostics** on this path — never opened for locking.

<!-- /mship:task -->

<!-- mship:task id=8 -->
## Task 8 — `mship daemon` CLI

**Failing tests first** — `tests/cli/test_daemon.py` (CliRunner against an isolated `typer.Typer()` with `daemon_mod.register(app, lambda required=True: None)`, model `tests/cli/test_relay_enroll_server.py`; monkeypatch `pick_supervisor` to a recording fake):
- `install|start|stop|restart|status|logs|run` all registered; `--help` sane.
- `install` with no reachable supervisor (`available()` False) → exit 1, message contains "mship daemon run" (fail-loud container path).
- `restart` calls `restart_blockers()` first; a monkeypatched non-empty list → refusal with the blocker text and **no** supervisor call (the #473 handoff, testable today).
- `status` renders `build_status` output including the "restart required" line, the unclean-starts line, and the unsupervised warning (fake probes).
- `logs` prints `logs_tail` output; `run` invokes `mship.core.daemon.run.main` directly (monkeypatched; no supervisor interaction) and passes its return through as the exit code.
- Guard test 1: with **no** daemon state anywhere, an ordinary command (`mship status` via `tests/cli/conftest.py` fixtures) still works — pins the "CLI usable without daemon" AC as a stated invariant.
- Guard test 2: `mship daemon status` through the real global `app` **from a directory with no `mothership.yaml`** succeeds — proves no workspace discovery on daemon paths.

**Implement** — `src/mship/cli/daemon.py`: thin Typer sub-app following the house `register(app, get_container)` shape (e.g. `src/mship/cli/serve.py:53`); `get_container` accepted but **never resolved into a workspace** (comment says so — daemon is workspace-agnostic). Wire into the register list in `src/mship/cli/__init__.py`. `typer.Exit(1)` at this layer only; core raises typed exceptions. Output via existing `Output` conventions.

<!-- /mship:task -->

<!-- mship:task id=9 -->
## Task 9 — Docs + manual verification checklist

No test. `docs/daemon.md`: lifecycle commands, why linger is mandatory, log/socket/lease paths, the loser-exits-0 policy and why (launchd semantics), and the **manual/VM checklist** for the OS-contract ACs the suite cannot exercise (per the test-recon boundary): survives SSH disconnect + logout (real linger); returns after `kill -9` within `RestartSec` and after reboot; real `systemd --user`/launchd start — **including `mship daemon install` over SSH to a Mac with no GUI session** (the `user/<uid>` bootstrap path); crash loop trips `start-limit-hit` and `mship daemon status` shows it; upgrade (`uv tool install --force --no-cache <path>`) then `mship daemon restart` runs the new version, with `status` showing skew before and clean after. Document the macOS caveat: reboot-survival on a headless Mac requires a login session (auto-login); a LaunchDaemon is out of scope. Note explicitly that merging does not deploy (the `redeploy-serve.sh` reality) and `mship daemon restart` is the daemon's deploy step. One line in `docs/getting-started.md`: the install now also provides `mshipd`, managed via `mship daemon`, never invoked directly.

Run `mship test` after the final commit (finish-gate evidence staleness, PR #445).

<!-- /mship:task -->

## Reused symbols (no new owners created)

`_locked` flock idiom (`src/mship/core/state.py:64`) and `InboxLease` acquire shape (`src/mship/core/inbox_lease.py:49`) — hardened to lifetime-held flock with same-fd in-place writes (no tmp+replace on the locked file); `is_reclaimable` (`src/mship/core/lease_common.py:18`, diagnostics only); 0600 tmp+replace write (`src/mship/core/run_host/store.py:63-81`) — **history file only**, never the flocked lease; version single source `mship.__version__` (`src/mship/__init__.py`, guarded by `tests/test_version.py`; the `topology`/`diagnostics` importlib probes are pre-existing near-duplicates — flagged, not touched); never-raises health-probe shape (`src/mship/core/relay/health.py:15`); closure app-factory style (`src/mship/core/serve.py:277`); heredoc unit generation precedent (`scripts/relay-bootstrap.sh:~27`); injectable-`home` path style (`src/mship/core/relay/keys.py:25-35`); test patterns: uvicorn monkeypatch (`tests/cli/test_serve.py`), injected-seam isolated Typer app (`tests/cli/test_relay_enroll_server.py`), external-binary faking via `shutil.which` (`tests/core/test_doctor.py`), real-multiprocessing lock correctness (`tests/core/test_store_concurrency.py`), injected-probe status assembly (`tests/cli/test_status.py`), pyproject-parsed-not-metadata assertion (`tests/test_version.py`).

## Explicitly not done here (seams recorded, nothing built)

- No tunnel code touched; `TunnelSupervisor` reuse, startup orphan-tunnel reaping, and one-tunnel-per-host land in #471 behind `capabilities.tunnel`.
- No workspace discovery, no `ConfigLoader` calls, no serve app mounted; #472 fills `capabilities.registry` and makes serve a daemon capability.
- No worker supervision; #473 fills `capabilities.runner` and gives `restart_blockers()` real content.
- No `mship --version`, no log `--follow`, no status `--json`, no auto-start-on-CLI, no daemon-side config file, no journald coupling, no live code reload.