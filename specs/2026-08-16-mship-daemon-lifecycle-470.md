---
id: mship-daemon-lifecycle-470
title: Mothership daemon provisioning and supervision (#470)
status: implemented
created_at: '2026-08-16T23:24:45.624987Z'
updated_at: '2026-08-17T00:46:58.936677Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: mship daemon install writes a systemd --user unit (Linux) or LaunchAgent plist
    (macOS) whose exec line resolves the mshipd entrypoint of the same installed distribution
    as the invoking CLI, sibling-first; an unverifiable resolution (dev-tree CLI,
    foreign PATH shim) refuses install with guidance to install the tool first
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac2
  text: Install on Linux runs loginctl enable-linger and verifies Linger=yes, failing
    loudly otherwise; mship daemon status re-warns whenever linger is off
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac3
  text: mship daemon start|stop|restart|status|logs exist and delegate through one
    injectable supervisor seam; mship daemon run runs mshipd in the foreground with
    no supervisor
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac4
  text: With no reachable user manager (probed via systemctl --user is-system-running,
    not binary presence), install fails loudly and names mship daemon run as the fallback
    - it never pretends persistence exists
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac5
  text: 'Single-instance guard: the daemon holds a lifetime flock on its lease file;
    a lease loser with a confirmed-live holder exits 0, a contended-but-dead lease
    exits nonzero, a stale lease is reclaimed even under pid reuse, concurrent cold
    starts converge on exactly one daemon (real-multiprocessing test), and no CLI/status
    path ever acquires the lease flock'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac6
  text: Unit/plist text encodes restart-on-crash with bounded backoff and a visible
    terminal state (Restart=on-failure + RestartSec + StartLimit on systemd; KeepAlive.SuccessfulExit=false
    + ThrottleInterval + StandardOut/ErrorPath on launchd), asserted by parsing the
    rendered files, not substring match; no WorkingDirectory anywhere
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac7
  text: Crash loops are visible in status, computed OS-agnostically from the daemon's
    durable start-history file counting only unclean starts, so routine operator restarts
    do not read as a loop
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac8
  text: 'Logs are durable and rotated under ~/.mothership/daemon/logs/ and capture
    crashes: uvicorn loggers routed into the rotating handler and uncaught-exception
    tracebacks logged before exit; mship daemon logs tails them including rotated
    siblings, no journald dependency'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac9
  text: The daemon reports the version it imported at process start plus a protocol
    integer over its control socket; status compares against the CLI version and prints
    a restart-required line on mismatch (exact-match policy)
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac10
  text: 'mship daemon restart consults a restart_blockers() seam (empty in v1, documented
    as the #473 recovery handoff) and refuses the restart when non-empty'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac11
  text: Ordinary local mship commands work with no daemon present, and mship daemon
    status works from a directory with no mothership.yaml (no workspace discovery
    on any daemon path), both pinned by tests
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
- id: ac12
  text: 'docs/daemon.md ships a manual/VM checklist covering the OS-contract items
    CI cannot exercise: SSH-logout survival via real linger, return after kill -9
    and reboot, headless launchd bootstrap over SSH (user/<uid> domain), crash loop
    tripping start-limit-hit, and upgrade-then-restart moving to the new version'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/4.mothership
    note: null
  comment: null
open_questions: []
non_goals:
- '#471 tunnel: no tunnel code; capabilities.tunnel=false + status line are the seam
  (TunnelSupervisor is the intended engine later)'
- '#472 workspace registry: daemon reads no mothership.yaml, never calls ConfigLoader.discover,
  never reads cwd; serve becomes a daemon capability there'
- '#473 worker supervision: capabilities.runner=false plus the restart_blockers()
  gate that #473 later fills'
- No auto-start-on-local-CLI, no live attach/stream, no embedded serve or TCP bind,
  no log --follow, no status --json, no daemon-side config file, no live code reload
  (process restart is the version boundary)
- 'macOS LaunchDaemon (system domain): out of scope; headless-Mac reboot survival
  requires auto-login, documented as a caveat'
risks:
- Linger silently not sticking would defeat the whole point; mitigated by verifying
  Linger=yes at install and re-warning in status
- Supervisor false-positives in containers (systemctl binary exists, no user manager);
  mitigated by probing systemctl --user is-system-running and failing loudly with
  mship daemon run as fallback
- Baking a worktree venv path into a persistent unit would make future upgrades deploy
  nothing; mitigated by sibling-first entrypoint resolution that refuses install from
  a dev tree
- An upgrade leaves an old daemon running new on-disk code until restart; mitigated
  by version captured at process start + exact-match skew warning in status
- OS-contract behaviors (real linger, reboot, kill -9, launchd bootstrap over SSH)
  cannot run in CI; covered by a documented manual/VM checklist instead
task_slug: null
work_item_id: null
clarification_reason: null
prose_verdicts: {}
---
## Problem

The Mothership host process (mship serve) dies with the shell that started it. On a headless dev VM it is almost never running when the phone needs it, and there is no restart path that doesn't involve SSH. Issue #470: provision and supervise one Mothership daemon process per OS user per host, installed from the same mship package, kept alive by the OS supervisor (systemd --user + linger on Linux, launchd LaunchAgent on macOS), with a pid-reuse-proof single-instance guard, visible crash loops, durable rotated logs, and CLI/daemon version-skew detection.

## User story

As a phone-first operator, I want each dev host to run a supervised always-on Mothership daemon provisioned once via mship daemon install, so that hosts self-heal through logouts, crashes, and reboots and Ground Control never depends on me opening a terminal.

## Approach

mship daemon install renders an OS-user supervisor unit that runs an internal mshipd entrypoint resolved from the SAME installed distribution as the invoking CLI (sibling-first next to sys.executable; a dev-tree CLI refuses install). The v1 daemon is a minimal host control-plane shell: it holds a lifetime flock lease (the held flock is the liveness authority, recorded pid is diagnostic only; written in-place through the locked fd, never tmp+replace), writes rotated logs plus a start-history file that makes crash loops visible OS-agnostically, and answers a unix control socket under XDG_RUNTIME_DIR reporting pid/version/protocol/capabilities. The OS supervisor owns restart/backoff (Restart=on-failure + StartLimit on systemd; KeepAlive.SuccessfulExit=false on launchd) - mship implements no restart loop. A lease loser with a confirmed-live holder exits 0 (the only supervisor-safe loser status on both OSes); a contended-but-dead lease exits nonzero so the supervisor retries. Linger is verified at install and re-warned in status. It serves no workspaces, opens no tunnel, supervises no workers - those are named seams (capabilities flags + a restart_blockers() gate) for #472/#471/#473. All lifecycle commands (install/start/stop/restart/status/logs/run) go through one injectable supervisor adapter (systemctl/launchctl/loginctl), with launchd using the user/<uid> domain so headless SSH provisioning works.

## Implementation plan

Built via ultracode (5 codebase readers, 2 independent drafts, judge synthesis, 3 adversarial verifiers - 21 findings folded back in). Plan: docs/plans/2026-08-16-mship-daemon-lifecycle-470.md (workspace repo) - 9 TDD tasks: paths+lease, start-history/crash-loop detector, control app+version identity, mshipd entrypoint+run loop, unit/plist rendering+exec resolution, supervisor adapter, status assembly, CLI, docs+manual checklist. Reuses existing owners: the state.py/inbox_lease flock idiom (hardened to lifetime-held, same-fd writes), run_host/store atomic-write (history file only), mship.__version__ SSOT, relay/health never-raise probe shape, serve.py closure app-factory.
