---
id: mship-pair-relay-host
title: 'mship pair: --relay-host option plus auto-discover the running serve relay'
status: implemented
created_at: '2026-07-17T12:24:26.024958Z'
updated_at: '2026-07-18T20:04:59.894241Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: '`mship pair --relay-host <host>` prints a valid `groundcontrol://add?...`
    deep-link plus QR with NO `relay:` block in mothership.yaml (it does not hit the
    current ''No relay configured'' exit at pair.py:35-40).'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green (2761 passed)
  - kind: commit
    ref: 83423e7
    note: null
  comment: null
- id: ac2
  text: With a serve running under `mship serve --relay-host <host>` and no `relay:`
    block, bare `mship pair` auto-discovers that relay from the running serve's runtime
    record and prints the current link plus QR.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green (2761 passed)
  - kind: commit
    ref: 7d26d62
    note: null
  comment: null
- id: ac3
  text: The link `mship pair` prints (URL host, subdomain, and token) is byte-for-byte
    identical to the link the running serve printed for the same workspace.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green (2761 passed)
  - kind: commit
    ref: 5a58b6d
    note: null
  comment: null
- id: ac4
  text: The printed link's token equals the running serve's token (both from `ensure_serve_token`);
    re-pairing after a serve restart that did not rotate the token yields the same
    token.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green (2761 passed)
  - kind: commit
    ref: 3f3f448
    note: null
  comment: null
- id: ac5
  text: "When no relay can be resolved (no `--relay-host`, no `relay:` block, no live\
    \ serve record), `mship pair` exits non-zero with an actionable message that names\
    \ `--relay-host` and the serve \u2014 never a silent, empty, or partial link."
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green (2761 passed)
  - kind: commit
    ref: 83423e7
    note: null
  comment: null
- id: ac6
  text: 'Explicit `--relay-host` overrides both `config.relay.host` and any running-serve
    record (precedence: flag > config > live record).'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green (2761 passed)
  - kind: commit
    ref: ce1cf3d
    note: null
  comment: null
- id: ac7
  text: 'A stale runtime record (serve not running / pid dead) is ignored: `mship
    pair` does not print a link derived from it and falls back to the flag/config
    or the clear error.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green (2761 passed)
  - kind: commit
    ref: 0d53548
    note: null
  comment: null
- id: ac8
  text: 'Existing behavior is preserved: with a `relay:` block in mothership.yaml
    and no flag, `mship pair` behaves exactly as it does today.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: mothership pytest suite green (2761 passed)
  - kind: commit
    ref: 66bbf5a
    note: null
  comment: null
open_questions: []
non_goals:
- Not changing the relay tunnel / enroll mechanism (ssh -R reverse tunnel, sish, per-machine
  pubkey enroll).
- Not changing the opaque-subdomain derivation scheme itself (`device_subdomain`/`device_id`/`relay-subdomain-secret`).
- Not altering serve-token generation, persistence, or rotation semantics (`ensure_serve_token`
  / `.mothership/serve-token`).
- "No phone/Ground Control app changes \u2014 this is a CLI-only fix; the `groundcontrol://add?...`\
  \ link shape is unchanged."
- Not adding a new authenticated serve endpoint (the loopback-query approach is explicitly
  the rejected alternative, not the deliverable).
risks:
- "Multiple serves running: pair must resolve the relay for the RIGHT workspace. Mitigation\
  \ \u2014 the runtime record lives in the per-workspace `.mothership/` resolved from\
  \ `container.config_path()` (same as serve.py:88 / pair.py:43), so it is naturally\
  \ scoped to the cwd's workspace; document that pair operates on the cwd's workspace."
- "Stale record after a crash/stop: auto-discovery must NOT print a link derived from\
  \ a dead serve. Mitigation \u2014 gate the record on pid-liveness and unlink it\
  \ on clean shutdown (serve.py:316-318); on stale/absent record, fall back to the\
  \ flag/config or a clear error rather than a stale link."
- "Silent wrong-host: if a `relay:` block and a `--relay-host` serve disagree, pair\
  \ could print a link to the wrong relay. Mitigation \u2014 fixed precedence (flag\
  \ > config > live record) and warn on a config-vs-live-record mismatch."
- "Host on disk: `.mothership/relay-runtime.json` should be mode 0600 and gitignored\
  \ like `serve-token`; it carries only the relay host (no secret \u2014 the token\
  \ stays in `serve-token`)."
- 'Backward compatibility: existing workspaces that DO have a `relay:` block and run
  bare `mship pair` must behave exactly as today (no regression from the new precedence).'
task_slug: mship-pair-relay-host
work_item_id: wi-20260718041113-fafbe4f3
clarification_reason: null
prose_verdicts:
  problem:
    verdict: approved
    comment: null
  user_story:
    verdict: approved
    comment: null
  approach:
    verdict: approved
    comment: null
  non_goals:
    verdict: approved
    comment: null
---
## Problem

`mship pair` can't build a pairing link when the relay is configured by the serve flag, not mothership.yaml. `mship pair` (src/mship/cli/pair.py:34-40) resolves the relay host ONLY from `config.relay` and hard-exits with "No relay configured. Add a `relay:` block (host) to mothership.yaml..." when that block is absent. But the live serves are started with `mship serve --relay-host mship-relay.atomikpanda.com` (a CLI flag; serve.py:68-73), and mothership.yaml has no `relay:` block, so pair cannot build the `groundcontrol://add?...` deep-link even while a serve is actively tunneling to that relay. Re-pairing a phone after a serve restart/redeploy therefore requires digging the deep-link out of the serve's startup log by hand.

## User story

As an operator re-pairing my phone after a serve restart or redeploy, I want `mship pair` to produce the current pairing QR/link without hand-editing mothership.yaml, so that re-pairing just works even when the relay host was supplied via `mship serve --relay-host <host>` rather than a `relay:` block in mothership.yaml.

## Approach

Root cause (verified in code). `mship pair` (src/mship/cli/pair.py:16-57) reads the relay host ONLY from `config.relay` (pair.py:34 `rc = config.relay`) and hard-exits when it is None (pair.py:35-40) — it has no CLI option. When rc is present it computes the subdomain (pair.py:46) via `device_subdomain(workspace, device_id(relay_public_key(key_path)), secret)`, builds `url = f"https://{subdomain}.{rc.host}"` (pair.py:47), reads the token via `ensure_serve_token(workspace_root)` (pair.py:48), and builds+prints the link (pair.py:49-56). Meanwhile `mship serve --relay-host <host>` (serve.py:68-73) sets `relay_enabled`/`relay_host_override` (serve.py:83-84) and calls `_serve_with_relay`, which at serve.py:197-201 constructs `RelayConfig(host=relay_host_override, ...)` — overriding config.relay.host AND working even when `config.relay is None` (serve.py:200-201). The serve then derives its subdomain (serve.py:234-241) and token (serve.py:212 `ensure_serve_token(workspace_root)`) the SAME way pair does.

Key insight: pair's two host-independent inputs are deterministic from stable local state — the subdomain comes from `~/.mothership/relay_ed25519` + `~/.mothership/relay-subdomain-secret` + the workspace name (none host-dependent), and the token comes from `.mothership/serve-token` via `ensure_serve_token` (token.py:5-19: env `MSHIP_SERVE_TOKEN` > persisted file > generated). So given ONLY the relay host string, pair reconstructs byte-for-byte the same URL + token the running serve printed. The one input pair lacks today is `rc.host`. The serve does NOT persist the relay host anywhere: `_serve_with_relay` only writes `.mothership/relay-tunnel.log` (serve.py:243) and the serve-token file; the `--relay-host` value lives only in the running process argv (serve.py:238's tunnel argv).

Proposed fix (BOTH, auto-discovery primary):
(1) Add a `--relay-host HOST` option to `mship pair` mirroring `mship serve` (serve.py:68-73). When passed, pair builds/substitutes `RelayConfig(host=...)` exactly like `_serve_with_relay` (serve.py:197-201), so it no longer requires a `relay:` block. This is the always-wins explicit override.
(2) PRIMARY — auto-discover the running serve's relay. Have `_serve_with_relay` persist the effective relay host when it starts relaying: write a small per-workspace runtime record alongside the existing tunnel log, e.g. `.mothership/relay-runtime.json` = {host, ssh_port, user, pid, url, workspace} (mode 0600, gitignored like serve-token), written just before `sup.start()` (serve.py:245-246) and unlinked in the `finally` teardown (serve.py:316-318). `mship pair` reads this record and uses its `host` when no `--relay-host` and no `config.relay` are given. Because pair recomputes subdomain+token deterministically, it only strictly NEEDS `host` from the record; `pid`/`url` are for staleness validation. pair skips a record whose `pid` is not alive so it never prints a stale link.
(3) Resolution order in pair: `--relay-host` flag > `config.relay.host` (mothership.yaml — unchanged legacy behavior) > running-serve runtime record (`.mothership/relay-runtime.json`, pid alive) > hard error with an actionable message that names `--relay-host` and points at the serve. Both pair and serve resolve `workspace_root` identically from `container.config_path()` (pair.py:43 / serve.py:88), so the record is naturally scoped to the cwd's workspace.

Alternative considered (asking the local serve): add a loopback endpoint (new `GET /pair`, or reuse `GET /health` at serve.py:352) returning the current link, and have pair query `http://127.0.0.1:<port>` with the bearer token. Rejected as primary because pair would have to guess the port and authenticate; the persisted-record approach needs neither and keeps pair fully offline and deterministic.

Token identity (confirmed this session): the token pair prints IS the serve's token — both call `ensure_serve_token(workspace_root)` (pair.py:48, serve.py:212; token.py:5-19), which prefers env `MSHIP_SERVE_TOKEN`, then the persisted `.mothership/serve-token` file, then a freshly generated one. It stayed UNCHANGED across the opaque-subdomain redeploy — only the subdomain/URL host moved — so auto-discovery only needs to recover the relay host and pair reproduces the exact current link.

## Testing

Unit — resolution order: table-driven cases over the new relay-host resolver covering (flag only), (config only), (live record only), (flag beats config beats record), and (nothing → actionable error). Assert `RelayConfig` substitution works when `config.relay is None`, mirroring `_serve_with_relay` (serve.py:197-201).

Unit — link/token parity: feed pair and serve the same `~/.mothership` relay key + subdomain-secret and the same `.mothership/serve-token`, and assert pair's reconstructed `build_pair_link(url, token, workspace)` output equals the serve's for the same workspace + relay host; assert token equality directly via `ensure_serve_token`.

Unit — runtime record: `_serve_with_relay` writes `.mothership/relay-runtime.json` (mode 0600) before `sup.start()` (serve.py:245-246) and unlinks it in the `finally` teardown (serve.py:316-318). Assert present while 'running', absent after clean shutdown, and that pair ignores a record whose pid is not alive (stale) versus honoring a fresh one.

Manual / e2e: in a workspace with no `relay:` block, start `mship serve --relay-host <host>`; run bare `mship pair` in the same workspace and confirm the printed link equals the serve's printed link (URL, subdomain, token); scan with the Ground Control app to confirm it pairs. Stop the serve and re-run `mship pair` → confirm the clear error (or flag fallback), not a stale link. Re-run with `mship pair --relay-host <host>` explicit and confirm it also works with no serve running and no `relay:` block.
