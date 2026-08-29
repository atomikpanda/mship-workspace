---
id: relay-opaque-subdomains
title: 'Relay: opaque keyed-hash subdomains that don''t leak workspace names'
status: implemented
created_at: '2026-07-16T22:26:01.013987Z'
updated_at: '2026-07-17T00:55:10.524470Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: 'The relay subdomain no longer contains the workspace name: the slug is base32(HMAC-SHA256(machine-secret,
    workspace-name)) truncated (~12 chars), DNS-label-safe, and the full `<slug>-<device-id>`
    label is <= 63 chars.'
  verdict: unreviewed
  evidence:
  - kind: commit
    ref: f32630af1abc68e9fc442696fdbe76068155d8f1
    note: 'opaque_slug: base32(HMAC) replaces workspace name in device_subdomain'
  comment: null
- id: ac2
  text: The subdomain is stable across serve restarts (deterministic given the machine-secret
    + workspace name).
  verdict: unreviewed
  evidence:
  - kind: commit
    ref: f32630af1abc68e9fc442696fdbe76068155d8f1
    note: opaque_slug is deterministic given the machine secret
  - kind: test
    ref: test-runs/1.mothership
    note: test_opaque_slug_is_deterministic_and_dns_safe
  comment: null
- id: ac3
  text: The machine-secret is generated once and persisted per machine (file mode
    0600); a machine with no secret yet generates and stores a fresh one.
  verdict: unreviewed
  evidence:
  - kind: commit
    ref: e63b32b2e46c26e779dc2dee6a023a3d4cab1ca2
    note: 'ensure_subdomain_secret: 32 bytes, 0600, O_EXCL, stable'
  comment: null
- id: ac4
  text: '`mship relay whoami <subdomain>` recovers the workspace name by recomputing
    the HMAC over the machine''s known workspaces and matching; a subdomain with no
    match reports ''no match'' (no crash).'
  verdict: unreviewed
  evidence:
  - kind: commit
    ref: 78bf717b1c7b73afc1e00103f8d3a7af9ddd9b1d
    note: mship relay whoami recompute-and-match
  comment: null
- id: ac5
  text: "Two different workspace names produce unrelated slugs, and the slug reveals\
    \ nothing about the name \u2014 an observer without the machine-secret can't derive\
    \ the name (unit-tested)."
  verdict: unreviewed
  evidence:
  - kind: commit
    ref: f32630af1abc68e9fc442696fdbe76068155d8f1
    note: different names -> unrelated slugs; slug hides the name
  - kind: test
    ref: test-runs/1.mothership
    note: test_opaque_slug_hides_the_name
  comment: null
- id: ac6
  text: Upgrading is documented as a one-time re-pair per device (the subdomain changes);
    nothing breaks silently.
  verdict: unreviewed
  evidence:
  - kind: commit
    ref: d54b316a8e5e163a2bfac21c7b7346094c3eb1b2
    note: re-pair migration note on serve --relay + pair output
  comment: null
- id: ac7
  text: The `core/relay/tls_ask.py` subdomain-slug derivation is updated in lockstep
    with `tunnel.py` so the two produce the same opaque slug (no drift), and the pairing
    QR still carries the friendly workspace name for GC display (opacity is on the
    subdomain/URL only).
  verdict: unreviewed
  evidence:
  - kind: commit
    ref: d54b316a8e5e163a2bfac21c7b7346094c3eb1b2
    note: tls_ask.py comment + opaque-subdomain acceptance test
  - kind: commit
    ref: 89ca72808b519f3229a7276faf73961061465995
    note: serve+pair callers derive subdomain in lockstep via shared secret
  comment: null
open_questions: []
non_goals:
- Changing the device-id derivation (already opaque).
- "A cross-machine shared secret \u2014 per-machine is sufficient since subdomains\
  \ are per-machine; shared-secret distribution is out of scope."
- Encrypting anything beyond the subdomain slug (payload is already TLS/relay-tunneled).
risks:
- 'DNS-safety: use lowercase base32 (a-z2-7), strip ''='' padding, and keep the total
  label <= 63 with the device suffix.'
- "Migration breaks existing pairings once \u2014 must be clearly surfaced (re-pair\
  \ each device), not silent."
- 'Secret at rest: store with 0600 perms; losing it changes all this machine''s subdomains
  (a re-pair), which is acceptable.'
task_slug: relay-opaque-subdomains
work_item_id: wi-20260716230513-f9542a05
clarification_reason: null
prose_verdicts: {}
---
## Problem

The relay subdomain is `<workspace-name-slug>-<device-id>` (core/relay/tunnel.py `subdomain_for` + `device_subdomain`). The device-id is already an opaque 6-char sha256, but the workspace-name slug leaks the actual workspace name to the relay host, DNS, and any network observer — an info disclosure.

## User story

As the operator, I want relay subdomains to be opaque — not revealing my workspace names to the relay host or the network — while I can still recover which workspace a subdomain belongs to from my own machine.

## Approach

- **Opaque slug via keyed hash.** Replace the workspace-name slug with `base32(HMAC-SHA256(machine-secret, workspace-name)).lower()` truncated to ~12 chars. base32 lowercase (a-z2-7, no padding) is DNS-label-safe; 12 + the `-<device-id>` suffix (7) = 19 chars, well under the 63 cap. Deterministic → stable across serve restarts; `device_subdomain` becomes `<opaque-slug>-<device-id>` (device-id unchanged).
- **Machine-secret.** A per-machine random secret, generated once and persisted (mode 0600) alongside the relay key / in the state dir. It's the HMAC key: opaque to the relay host + network (they don't have it). Per-machine is sufficient — subdomains are already per-machine via device-id.
- **Decode helper.** `mship relay whoami <subdomain>` recomputes the HMAC over the machine's known workspace names and reports the match (or 'no match'), so the operator can recover a subdomain's workspace.
- **Migration.** Upgrading changes the subdomain (name-based → opaque), so each device re-pairs once. Surface a clear note; no silent breakage.
- **Ground Control is unaffected.** GC connects via the full relay URL from the pairing QR (which also carries the friendly workspace name for display, over the local in-person scan — never the network). So GC keeps showing the real name while the subdomain / DNS / relay host only ever see the opaque slug. GC needs no decode logic.
- **Update the mirror.** `core/relay/tls_ask.py` derives a workspace slug that mirrors `device_subdomain`; update it in lockstep so the two derivations can't drift.
