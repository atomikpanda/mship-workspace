---
id: ground-control-notifications-for-needs
title: Ground Control notifications for needs-you messages (self-hosted poll, FCM-ready)
status: dispatched
created_at: '2026-06-30T21:46:31.032896Z'
updated_at: '2026-06-30T21:59:04.593720Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: "Toggle ON + permission granted: a new needs_you message in any connected\
    \ workspace raises a notification within seconds (FGS running) \u2014 title =\
    \ workspace name, body = subject + preview from last_message."
  verdict: approved
- id: ac2
  text: "Tapping the notification opens that conversation, routed through the groundcontrol://thread?workspace=<key>&id=<threadId>\
    \ deep link and DeepLinkResolver (normalized base-URL match \u2192 local connId\
    \ \u2192 thread/{connId}/{threadId})."
  verdict: approved
- id: ac3
  text: A plain (non-needs_you) note and an already-acted-on needs_you do NOT trigger
    a notification; a thread is notified at most once per needs_you episode; after
    the operator acts (needs_you transitions to false) a later needs_you on the same
    thread re-notifies.
  verdict: approved
- id: ac4
  text: The WatchBackstopWorker notifies a new needs_you that landed while the FGS
    was not running (within the periodic cadence), without double-notifying a message
    the FGS already raised.
  verdict: approved
- id: ac5
  text: DeepLinkResolver resolves a known workspace by normalized base URL (with workspace-name
    as fallback) to the correct connId, and routes an unknown workspace to the add-connection
    / existing QR/relay pairing flow rather than crashing.
  verdict: approved
- id: ac6
  text: The global toggle enables/disables the service and worker; POST_NOTIFICATIONS
    is requested on first enable; a denied permission causes the toggle to surface
    a 'permission needed' indication.
  verdict: approved
- id: ac7
  text: The global toggle state and per-(connection, thread) dedup cursor survive
    a device reboot and are re-armed by BootReceiver (WatchService restarted + WatchBackstopWorker
    re-enqueued if toggle is on).
  verdict: approved
- id: ac8
  text: v1 makes NO mothership/server change; the full ground-control JVM unit test
    suite is green.
  verdict: approved
open_questions:
- id: q1
  text: 'Notified-state persistence: DataStore (consistent with ConnectionsRepository,
    small, keyed by connId+threadId) vs a small Room table. Lean DataStore for v1;
    confirm during planning.'
  answer: "Room \u2014 a small table keyed by (connId, threadId) for the notified-state/dedup\
    \ store; preferred over DataStore."
- id: q2
  text: 'WorkManager backstop interval: 15 min (Android minimum, tightest safety net
    when FGS is down) vs a longer interval to save battery. Lean 15 min; confirm during
    planning.'
  answer: "15 min (Android's PeriodicWorkRequest minimum) \u2014 the tightest safety-net\
    \ cadence while the foreground service is down."
non_goals:
- "FCM / any server push \u2014 future FcmTrigger + server-side device-token registry\
  \ + sender in a managed mship serve; v1 is client poll only."
- "https App Links + external inbound links from third-party messaging apps \u2014\
  \ enabled by the custom scheme + DeepLinkResolver built in v1; both require a managed\
  \ mship domain (same future bucket as FCM)."
- "Blocker and spec-approval notifications \u2014 needs_you messages only for v1;\
  \ those notification types have no long-poll endpoint."
- "Plain-note (unseen) notifications \u2014 quiet notes are not notified by design."
- "Per-workspace notification toggles \u2014 global toggle only for v1."
- "iOS \u2014 this is the Android app (minSdk 26, targetSdk 34, compileSdk 34)."
risks:
- 'Android background limits: real-time long-poll requires a foreground service with
  its mandated persistent notification on targetSdk 34; WorkManager floors at ~15
  min. The hybrid design accepts the persistent ''Watching for messages'' notification
  as the cost of real-time delivery, gated behind the toggle.'
- "foregroundServiceType=dataSync is correct for a network long-poll on API 34; Android\
  \ 15 later caps dataSync runtime (~6h/day) \u2014 out of scope at targetSdk 34 but\
  \ must be tracked for a future SDK bump."
- The ?wait=1 long-poll fires on ANY thread change (updated_at), so pollConnectionForNeedsYou
  must filter to new-needs_you-not-already-notified; dedup-on-resolve (not just a
  timestamp cursor) is required so a follow-up note on a still-needs_you thread does
  not re-notify.
- 'Battery/connection: one persistent long-poll per connection with reconnect-with-backoff.
  Acceptable for an opt-in power-user dev tool; FCM later removes the persistent connection.'
- "The notification body uses the thread summary's last_message field (<=120 chars)\
  \ \u2014 no extra fetch is needed, but the content is limited to what the summary\
  \ exposes."
task_slug: ground-control-notifications-for-needs
work_item_id: wi-20260702110439-8988c8c0
---
## Problem

Ground Control surfaces needs_you agent messages on Home only while the app is open. When an agent posts `mship reply --needs-you` it is blocked waiting on the operator, but the operator has no way to learn this without opening the app. mship is self-hosted (not a managed SaaS), so there is no central push server — delivery must run on the Android side over the existing `mship serve` connection. Real notifications are needed now, designed so a future managed layer (FCM push; verified https App Links) drops into clean seams without reworking the v1 poll path. Tracking issue: mothership #248.

## User story

As a Ground Control operator, I want to receive an Android notification whenever an agent posts a needs-you message in any connected workspace, so that I can unblock a waiting agent without having to keep the app open.

## Approach

Hybrid delivery: a foreground service (WatchService, type dataSync) holds a GET /threads?wait=1 long-poll per connection for real-time delivery; a WorkManager periodic job (WatchBackstopWorker, ~15 min floor) backstops gaps caused by Doze, service kill, or post-reboot delay before the service restarts.

A FCM-ready seam separates the trigger layer from the notify layer: a NotificationTrigger interface emits NeedsYouEvent values; v1 PollingTrigger (FGS + Worker) is the sole impl; a future FcmTrigger (FirebaseMessagingService) emits the same event type with no change to NeedsYouNotifier or dedup logic. This lets the managed future (server-side device-token registry, FCM sender, verified https App Links) slot in without reworking the v1 path.

All state is client-side: dedup-on-resolve tracks per-(connection, thread) notified episodes in a persisted store shared by the FGS and Worker. One global toggle gates the feature; POST_NOTIFICATIONS (Android 13+) is requested on first enable.

Deep-linking uses a custom groundcontrol:// URI scheme now, with the DeepLinkResolver and manifest intent-filter already wired to accept future external inbound links (from third-party messaging apps or a managed mship domain) through the same path once https App Links are available. No token ever appears in the URI.

## Architecture

All v1 work is in ground-control (client-only). No mothership change — consumes the existing GET /threads?wait=1 long-poll and the needs_you / last_message / subject / updated_at fields already present on thread summaries.

NeedsYouNotifier — the single notify sink. Accepts a NeedsYouEvent(connId, workspaceName, threadId, subject, preview, updatedAt). Builds and posts an Android notification on channel 'Agent needs you' (heads-up importance; title = workspaceName, body = subject + preview). Constructs a PendingIntent carrying the groundcontrol:// deep-link URI. Owns dedup via a persisted per-(connection, thread) 'notified' store: notify once when a thread first shows needs_you newer than the last-notified mark; do NOT re-notify on follow-up updates while the thread is still needs_you; CLEAR the notified state when a later poll shows needs_you=false (operator acted), so a future needs_you episode re-notifies.

NotificationTrigger interface (FCM-ready seam) — emits NeedsYouEvent values. v1 implementation is PollingTrigger (materialized by WatchService FGS and WatchBackstopWorker). Future FcmTrigger would be a FirebaseMessagingService that parses an FCM data payload into the same NeedsYouEvent and feeds NeedsYouNotifier — no change to the notify or dedup path.

pollConnectionForNeedsYou(conn, cursor, notifiedState) -> List<NeedsYouEvent> — the single shared, unit-testable function used by both pollers (the API client is injected, so it is exercised with a Ktor MockEngine; the implementer may further split the pure filter `selectNewNeedsYou(threads, cursor, notifiedState)` from the fetch). Fetches threads (via SpecApi.listThreadsWait for the FGS long-poll path, one-shot list for the Worker path), then filters to threads where needsYou == true && updatedAt > cursor && not already in the notified store for the current episode. Returns the list of events to raise. Both WatchService and WatchBackstopWorker call this function, ensuring identical filtering and dedup logic.

WatchService — foreground service, foregroundServiceType=dataSync. While the toggle is on, spawns one coroutine per connection that long-polls GET /threads?wait=1 (reusing SpecApi.listThreadsWait), funnels new needs_you events into NeedsYouNotifier, and reconnects with exponential backoff on failure. Posts a low-importance persistent 'Watching for messages' notification on its own separate channel (required by Android for FGS). Started by the toggle flip and by BootReceiver on BOOT_COMPLETED when the toggle is on.

WatchBackstopWorker — WorkManager PeriodicWorkRequest (~15 min, Android's minimum floor). Performs a one-shot poll of each connection (?wait=0), calls pollConnectionForNeedsYou, and passes results to NeedsYouNotifier. Shares the same persisted dedup store as the FGS so the two never double-notify. Enqueued while the toggle is on; cancelled when the toggle is turned off.

Deep-link design — URI scheme: groundcontrol://thread?workspace=<key>&id=<threadId>. <key> is the connection's base URL (URL-encoded; portable across reinstalls), with workspace-name as fallback. NO token or credential ever appears in the URI.

DeepLinkResolver (pure, unit-testable): parses the URI to DeepLinkTarget(workspaceKey, threadId), then resolves against ConnectionsRepository using normalized base-URL match first, then display name. On success → navigate to thread/{connId}/{threadId}. Unknown or unresolvable workspace → route to the existing add-connection / QR/relay pairing flow; never crash.

One path for notifications and future external links: the notification PendingIntent carries the groundcontrol:// URI and the same DeepLinkResolver handles it. When a future external link (from a third-party messaging app or a managed mship domain) arrives via the same manifest intent-filter, it hits the same resolver — no new code path. Security: the custom scheme is interceptable by other apps, but the URI contains no secret; worst case is another app opening Ground Control to a thread view (harmless). An unknown or spoofed workspace key routes safely to add-connection.

## Permissions & lifecycle

POST_NOTIFICATIONS (Android 13+ / API 33+): requested on the first time the user enables the global notifications toggle. If denied, the toggle surfaces a 'permission needed' indication and remains logically off (service and worker are not started).

AndroidManifest.xml additions:
- uses-permission: FOREGROUND_SERVICE
- uses-permission: FOREGROUND_SERVICE_DATA_SYNC
- uses-permission: RECEIVE_BOOT_COMPLETED
- uses-permission: WAKE_LOCK
- <service android:name='.WatchService' android:foregroundServiceType='dataSync' />
- <receiver android:name='.BootReceiver' android:exported='false'><intent-filter><action android:name='android.intent.action.BOOT_COMPLETED'/></intent-filter></receiver>
- Deep-link intent-filter on the main Activity (or a dedicated DeepLinkActivity): scheme=groundcontrol, host=thread (and host=open for future extension); android:autoVerify left false for v1 (custom scheme, no App Links domain).

Reboot re-arming: BootReceiver fires on BOOT_COMPLETED, reads the persisted toggle state, and if on: starts WatchService as a foreground service and re-enqueues WatchBackstopWorker via WorkManager. The dedup cursor and notified-state store are persisted (a small Room table keyed by connId+threadId) so no episode is lost or double-notified across a reboot.

Toggle lifecycle: turning the toggle ON starts WatchService + enqueues WatchBackstopWorker + requests POST_NOTIFICATIONS if not yet granted. Turning it OFF stops WatchService + cancels the WorkManager periodic job. The toggle state is persisted so BootReceiver can restore it.

## Testing

All v1 tests are JVM-only (no emulator required), consistent with the existing ground-control test suite.

pollConnectionForNeedsYou unit tests (Ktor MockEngine + fakes):
- Returns only threads where needsYou=true and updatedAt is newer than the cursor.
- Skips threads already present in the notifiedState store (current episode, not yet cleared).
- Returns an empty list when all threads are already notified or no needs_you is set.
- Correctly re-includes a thread after its notified state has been cleared (needs_you=false episode ended).

NeedsYouNotifier dedup unit tests (fake notification poster + fake notified-state store / in-memory Room):
- Posts exactly one notification per needs_you episode per (connId, threadId) pair.
- Does not post a second notification when a follow-up update arrives while the thread is still needs_you.
- Clears the notified state and posts again when a new needs_you episode starts after needs_you was false.
- FGS and Worker sharing the same store: simulate FGS posting a notification, then run Worker poll — Worker must not re-post.

DeepLinkResolver unit tests (fake ConnectionsRepository):
- Resolves a known workspace by normalized base URL to the correct connId and thread nav target.
- Falls back to display-name match when base-URL normalization does not produce a hit.
- Routes an unknown workspaceKey to the add-connection destination rather than throwing.
- Handles malformed URIs (missing id param, unrecognized host) without crashing.

Framework-bound shells (WatchService FGS and WatchBackstopWorker) are not unit-testable in isolation due to Android framework dependencies. These are verified via `mship capture` integration smoke tests and manual on-device testing: toggle on → agent sends needs_you → notification appears; kill service → WorkManager backstop raises notification within ~15 min; reboot → BootReceiver re-arms and next needs_you notifies.
