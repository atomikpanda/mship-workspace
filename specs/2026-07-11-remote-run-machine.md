---
id: remote-run-machine
title: 'Remote run machine: execute run/capture/build on relay-brokered remote serves
  via --remote (MOS-191)'
status: implemented
created_at: '2026-07-11T02:13:32.669790Z'
updated_at: '2026-07-11T11:12:39.633783Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: "mship run / capture / build gain a --remote[=<role>] flag selecting a logical\
    \ run-host ROLE (e.g. ios-sim-host). Resolution when the name is omitted: the\
    \ role the target repo declares for that verb (if any), else the sole configured\
    \ role (error if 0 or ambiguous). When set, the verb's go-task target executes\
    \ on the mapped remote \u2014 a mship serve reached over the relay (the remote\
    \ dials OUT, like the phone, so NAT/anywhere works). WITHOUT --remote, behavior\
    \ is byte-for-byte what it is today (local unchanged)."
  verdict: approved
- id: ac2
  text: "TWO-LAYER config, and NO secret ever in mothership.yaml (it's in the public\
    \ repo). mothership.yaml declares only LOGICAL run-host ROLE names (non-secret,\
    \ shareable) \u2014 e.g. run_hosts: [ios-sim-host, android-emu-host] \u2014 and\
    \ OPTIONALLY lets a repo name the role its host-bound verbs need (so `mship capture\
    \ --remote` auto-resolves for that repo). Concrete host connections are NOT here."
  verdict: approved
- id: ac3
  text: "Each machine MAPS a role -> a concrete connection {relay url, bearer token}\
    \ in the gitignored .mothership/run-hosts.yaml (restrictive perms), exactly like\
    \ the serve/relay tokens already live under .mothership/. Env overrides (MSHIP_RUN_HOST_<ROLE>_URL/_TOKEN)\
    \ honored. A `mship run-host` group manages it: add/pair (from the remote's `mship\
    \ serve --relay` pair link/token, or --url/--token), list (url shown, token REDACTED),\
    \ remove. Resolution errors are actionable: a role declared in mothership.yaml\
    \ but not mapped locally prints e.g. 'run: mship run-host add ios-sim-host \u2026\
    '."
  verdict: approved
- id: ac4
  text: New remote-exec endpoints on serve (e.g. POST /exec/{verb} for run|capture|build),
    inheriting serve's existing bearer-auth dependency. Given {task, repos, platform?},
    the endpoint ensures the task's branch worktree exists on the remote (git fetch
    + a worktree for the task, mirroring the local .worktrees model), then runs the
    repo's go-task target with the same env-var contract as local.
  verdict: approved
- id: ac5
  text: "LIVE output streaming: the exec endpoint streams the task's stdout/stderr\
    \ back as it runs (async FastAPI StreamingResponse / chunked transfer over the\
    \ relay's HTTP tunnel \u2014 Caddy+sish already proxy HTTP), and `mship run --remote`\
    \ / build render that output live in the local terminal (real-time logs, not a\
    \ final blob). The remote task's exit code is conveyed to the client."
  verdict: approved
- id: ac6
  text: 'The capture env-var contract is preserved on the remote: MSHIP_CAPTURE_DIR
    (a remote dir), MSHIP_CAPTURE_KINDS, MSHIP_CAPTURE_PLATFORM are set for the remote
    task exactly as locally, so the repo''s go-task capture: target (the iOS simctl
    arm, etc.) runs on the remote and writes artifacts there.'
  verdict: approved
- id: ac7
  text: "Capture artifacts come home: the exec endpoint makes the produced artifacts\
    \ (screen.png / layout.*) fetchable (inline tar stream or a follow-up GET the\
    \ client pulls), and `mship capture --remote` writes them into the LOCAL .mothership/captures/<task|_adhoc>/<UTCts>-<platform>/\
    \ \u2014 exactly where a local capture lands \u2014 so discover_artifacts + the\
    \ local agent Read them unchanged."
  verdict: approved
- id: ac8
  text: "Auth composes with the existing stack: the local box authenticates to the\
    \ remote serve with the remote's bearer token (from the gitignored run-host store)\
    \ \u2014 a workspace-scoped credential, NOT a GitHub token. The remote's OWN git\
    \ fetch uses the remote's git credentials, or the Phase-1 token broker (MOS-226)\
    \ for a credential-less/cloud remote. No GitHub token crosses the wire from the\
    \ local box."
  verdict: approved
- id: ac9
  text: "MOS-203 fold-in: before a remote run materializes/updates the branch, the\
    \ remote checks whether the task branch's base is behind origin and warns (or\
    \ auto-fetches) \u2014 a remote run otherwise makes a stale base invisible (you'd\
    \ silently build old code on the remote)."
  verdict: approved
- id: ac10
  text: 'Clear failure modes, each with a specific message: unknown/ambiguous --remote
    role; role declared but not mapped locally; no run-hosts configured; remote serve
    unreachable via the relay; remote workspace not bootstrapped; branch-materialize
    failure (surfaced with the repo); remote task non-zero exit (exit code + streamed
    output preserved). A dead remote fails fast, not a silent hang.'
  verdict: approved
- id: ac11
  text: "Tests cover: --remote[=role] resolution + repo-declared-role fallback (asserting\
    \ the LOCAL path is unchanged when --remote is absent), the two-layer config (yaml\
    \ roles + gitignored map) incl. redaction, the exec endpoints (mocked task execution\
    \ + streamed output), the branch-materialize step, and the capture artifact round-trip\
    \ \u2014 all against a mocked serve/relay (no real remote or relay). mship test\
    \ passes; no new third-party dependencies."
  verdict: approved
open_questions:
- id: q2
  text: 'Non-capture artifacts: capture pulls its artifact dir home; run/build stream
    stdout/stderr live (ac5). Is streaming enough for run/build, or should they ALSO
    pull produced artifacts (a build output/binary)? The spec assumes stream-only
    for run/build, file-pull for capture.'
  answer: stream only for run/build file pull for capture
- id: q3
  text: "MOS-194 (GC dispatch doesn't notify the running host agent): fold into this\
    \ spec, or keep separate? My recommendation: SEPARATE \u2014 it's a dispatch-notification\
    \ feature (same shape as the MOS-219 watcher). The spec keeps it out; confirm\
    \ or say fold it in."
  answer: separate
non_goals:
- "Direct-ssh transport (rejected \u2014 can't reach a NAT'd remote and doesn't reuse\
  \ the stack)."
- Storing any run-host secret (or concrete url) in mothership.yaml (it's public).
  mothership.yaml holds only logical role names; connections live in the gitignored
  .mothership/ store or env.
- 'Auto-provisioning/bootstrapping the remote: each mapped host is a one-time-bootstrapped
  mship workspace running `mship serve --relay` (operator sets it up; documented).
  v1 assumes it exists and is reachable.'
- 'Syncing .mothership STATE back from the remote: the remote is its own workspace
  (clone-local .mothership); only capture ARTIFACTS + streamed output come home. State
  sync-back is separate (cf. MOS-226 q3).'
- 'Concurrency/queueing of remote runs: v1 does one remote run at a time per host.'
- 'Auto-selecting a remote WITHOUT --remote: the flag is an explicit opt-in (though
  the ROLE within --remote can be auto-resolved from the repo''s declaration).'
risks:
- "Secret handling: no run-host secret may land in the public mothership.yaml. Mitigated\
  \ by the two-layer split \u2014 only logical roles in yaml; connections in the gitignored\
  \ .mothership/ store (restrictive perms) + env; token redacted in `run-host list`;\
  \ never logged."
- Streaming a long-running task's stdout over the relay's HTTP is a new serve capability
  (serve today is request/response + a thread long-poll). Mitigated by an async StreamingResponse
  over the subprocess's stdout, tested with a mocked task; the relay (Caddy + sish)
  already proxies HTTP so chunked streaming rides the existing tunnel.
- 'Remote branch drift: the remote worktree could be stale/dirty. Mitigated by fetch
  + reset/checkout to the task branch each run (the safe local-passive-worktree pattern)
  + the MOS-203 base check.'
- A remote-exec endpoint is a command-execution surface. Mitigated by bearer-auth
  (serve token), scoping to the workspace's own go-task targets (not arbitrary commands),
  audit, and the same trust boundary as the phone driving that serve.
- 'Relay path latency/reliability: a dropped tunnel mid-run loses the stream. Mitigated
  by clear surfacing (not a silent hang); re-running is idempotent for capture.'
task_slug: remote-run-machine
work_item_id: wi-20260711025728-e254bea0
---
## Problem

Some mship verbs are host-bound. iOS capture (`xcrun simctl io booted screenshot`) only runs on macOS; `capture`/`run`/`build` need the device/emulator/simulator to live where the command executes. Today ALL mship execution is local — one Linux dev box — so an operator on Linux cannot exercise iOS capture at all, and can't drive a simulator/emulator that lives on another machine (which may be **somewhere else entirely**, behind NAT).

Two facts make this tractable: (1) every verb funnels through one seam — `ShellRunner` → a go-task target — and mship is **backend-agnostic** (the iOS `simctl` logic lives in the repo's Taskfile `capture:` target keyed on `$MSHIP_CAPTURE_PLATFORM`). (2) We already have a **relay + serve + pairing + token-broker** stack: a machine can run `mship serve --relay`, dial OUT to the relay, and be reached (bearer-auth'd, per-device subdomain) from anywhere — exactly how the phone connects.

## User story

As an operator on a Linux box, I want to run `mship capture --remote` (or `--remote=ios-sim-host`) so a host-bound verb executes on the machine mapped to that role — even one **somewhere else behind NAT** — against the current task's branch, with `mship run`'s logs streaming live to my terminal and capture's `screen.png`/`layout.*` landing in my local `.mothership/captures/…` exactly as a local capture would — with the workspace config sharing only a logical role name and the actual host's credentials kept out of the public `mothership.yaml`.

## Approach

Brainstorm decisions: a general, **multi-host** run-host concept opted into by an explicit **`--remote[=role]`** flag; a **git-based remote workspace** (bootstrapped once, pulls the branch itself, real build env); **relay/serve-brokered** transport (the remote runs `mship serve` reached over the relay — not ssh); **no secrets in `mothership.yaml`**; and a **two-layer role→host indirection**.

### 1. Two-layer run-hosts: logical roles (shared) → local connections (secret)

Because `mothership.yaml` is in the **public** repo, it declares only **logical run-host ROLE names** — shareable, non-secret:

```yaml
run_hosts: [ios-sim-host, android-emu-host]
# and optionally a repo declares the role its host-bound verbs need:
repos:
  ios-app:
    capture: { platforms: [ios], run_host: ios-sim-host }
```

Each machine then **maps** each role to a concrete connection in the **gitignored** `.mothership/run-hosts.yaml` (restrictive perms), like the serve/relay tokens already live under `.mothership/`:

```yaml
ios-sim-host:
  url: https://mac-<6hex>.mship-relay.example.com   # the remote's relay subdomain
  token: <remote serve bearer token>                 # workspace-scoped, never in the public yaml
```

A `mship run-host add|pair|list|remove` group manages the local map (pair from the remote's `mship serve --relay` link/token, or `--url`/`--token`; `list` redacts the token). `--remote[=role]` resolves: explicit role, else the repo's declared role, else the sole one → local connection. A role declared in yaml but not mapped locally errors with an actionable `mship run-host add <role> …` hint. So the same `mothership.yaml` is portable across machines; each dev binds `ios-sim-host` to whatever Mac they have.

### 2. Remote-exec endpoints on serve (+ live streaming)

Add remote-exec endpoints to serve (e.g. `POST /exec/{verb}` for run|capture|build), inheriting serve's bearer dependency. Given `{task, repos, platform?}`, the endpoint: (1) **materializes the branch** on the remote (`git fetch origin` + a worktree for the task, mirroring `.worktrees/<slug>/<repo>`, using the remote's git creds or the Phase-1 broker); (2) **runs the go-task target** via the on-the-remote `ShellRunner` with the capture env-var contract; (3) **streams stdout/stderr live** back (async `StreamingResponse`/chunked over the relay's HTTP tunnel), conveying the exit code. `mship run --remote`/`build --remote` render the stream live in the local terminal.

### 3. Capture artifacts come home

After the remote task writes `screen.png`/`layout.*` into `MSHIP_CAPTURE_DIR`, the endpoint makes them fetchable (inline tar stream or a follow-up `GET`); `mship capture --remote` writes them into the LOCAL `.mothership/captures/<task|_adhoc>/<UTCts>-<platform>/` — the exact local path — so `discover_artifacts` + the local agent see them unchanged.

### 4. Auth (two credentials, both from the existing stack)

(a) The local box authenticates to the remote **serve** with the remote's bearer token (from the gitignored run-host map, like a phone pairing) — workspace-scoped, not a GitHub token. (b) The remote's **git** fetch uses its own credentials or the Phase-1 **token broker** (MOS-226). No GitHub token crosses the wire; no secret is in the public yaml.

### 5. Stale-base safety (MOS-203 fold-in)

Before materializing/updating the branch, the remote checks whether the task branch's base is behind origin and warns / auto-fetches — because a remote run otherwise makes a stale base invisible.

No new third-party deps (reuses FastAPI/httpx); gated on `mship test` with a mocked serve/relay (no real remote or relay in tests).
