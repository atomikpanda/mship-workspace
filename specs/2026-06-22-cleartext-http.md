---
id: cleartext-http
title: 'Cleartext HTTP: make non-relay tailnet/LAN workspaces reachable in Ground
  Control'
status: implemented
created_at: '2026-06-22T23:42:17.158240Z'
updated_at: '2026-06-22T23:45:12.932596Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: android/app/src/main/AndroidManifest.xml sets android:usesCleartextTraffic="true"
    on the <application> element.
  verdict: unreviewed
- id: ac2
  text: ./gradlew assembleDebug succeeds.
  verdict: unreviewed
- id: ac3
  text: "Manual smoke test (documented, not automated \u2014 no emulator): a non-relay\
    \ workspace served with `mship serve --host <tailnet-or-lan-ip>` and MSHIP_SERVE_TOKEN,\
    \ paired into Ground Control via QR, loads its specs/tasks instead of showing\
    \ 'unreachable'."
  verdict: unreviewed
- id: ac4
  text: Relay (https) pairing and fetching continue to work unchanged.
  verdict: unreviewed
open_questions: []
non_goals:
- "TLS / HTTPS / self-signed certs / cert-pinning for non-relay serve \u2014 a separate\
  \ deferred spec; the secure-network story stays tailnet (WireGuard-encrypted http)\
  \ + relay (https). This change only unblocks plain http on trusted networks."
- 'A domain-scoped network_security_config (impractical: cleartext can''t be scoped
  to private-IP/CIDR, and pairing resolves to an IP). Could be revisited later if
  pairing moves to Tailscale MagicDNS (*.ts.net) hostnames.'
- Any server / mothership change
- A new unit/instrumentation test (cleartext enforcement isn't unit-testable here;
  build + manual smoke only)
risks:
- 'usesCleartextTraffic="true" permits cleartext to ANY host the app contacts, not
  just workspace endpoints. Mitigated: the app makes no http requests other than to
  the user-configured workspace connections, and the recommended secure setups (tailnet/relay)
  are unaffected. If tighter control is wanted later, switch to a network_security_config
  (e.g. scoped to *.ts.net when pairing via MagicDNS).'
- Reviewers may flag a cleartext-enabled app in store/security scans; this is an intentional,
  documented tradeoff for a self-hosted operator tool used on trusted networks.
task_slug: cleartext-http
work_item_id: wi-20260702110439-8281a402
---
## Problem

Android blocks cleartext HTTP by default for apps targeting API >= 28 (Android 9+). Ground Control targets targetSdk 34 and its AndroidManifest sets no usesCleartextTraffic flag and no network-security config, so the platform default (cleartextTrafficPermitted = false) applies and every http:// request is refused on-device — OkHttp raises 'CLEARTEXT communication to <host> not permitted by network security policy', which the app surfaces as the 'unreachable' chip. Result: relay workspaces (https) work, but non-relay tailnet/LAN workspaces (http://<ip>:47100) are unreachable. This means the just-shipped non-relay QR pairing pairs the connection but can never fetch — the inbox/tasks stay 'unreachable'. Enabling cleartext is the missing piece that makes non-relay actually work end-to-end.

## User story

As an operator who paired a non-relay tailnet/LAN workspace, I want Ground Control to actually connect to it over http, so that the inbox and tasks load instead of showing 'unreachable'.

## Approach

Add android:usesCleartextTraffic="true" to the <application> element in android/app/src/main/AndroidManifest.xml. That opts the app into cleartext HTTP so requests to the user-configured workspace endpoints (tailnet/LAN http) are permitted; relay (https) is unaffected. No new dependency, no functional code change. The flag is chosen over a domain-scoped network_security_config because Android cannot scope cleartext by private-IP/CIDR range, and non-relay pairing resolves to an IP (from the server's advertised host), so a *.ts.net-scoped config would not cover the common IP case — global cleartext is the change that actually fixes it, and the app only ever contacts user-configured workspace endpoints. Verification is build (assembleDebug) plus a manual smoke test against a live non-relay `mship serve`; there is no JVM unit test for this because cleartext enforcement is a runtime Android-platform behavior not exercised by the MockEngine test client.
