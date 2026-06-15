---
id: c1-c2-app-shell-and-spec-inbox-mos-154
title: 'Ground Control C1/C2: Android app shell + multi-workspace spec inbox'
status: approved
created_at: '2026-06-15T00:16:06.416854Z'
updated_at: '2026-06-15T00:19:47.426442Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: 'The Android project builds: ./gradlew assembleDebug succeeds via the installed
    toolchain'
  verdict: approved
- id: ac2
  text: 'Unit tests pass: ./gradlew testDebugUnitTest (run via mship test) is green'
  verdict: approved
- id: ac3
  text: App boots to the Specs (inbox) home; all five sections (Specs, Capture, Decisions,
    Tasks, Settings) are reachable via bottom navigation
  verdict: approved
- id: ac4
  text: Settings adds, edits, and removes multiple workspace connections (baseUrl
    + bearer token), persisted across launches; each is validated via GET /health
    which captures the workspace name
  verdict: approved
- id: ac5
  text: The inbox aggregates specs from all configured connections in parallel and
    renders them grouped workspace -> status (Needs review, Ready to dispatch, In
    implementation, Drafting, Done), with empty groups hidden and archived excluded
  verdict: approved
- id: ac6
  text: Each spec row shows title, status, and affected repos; pull-to-refresh re-fetches
    all connections
  verdict: approved
- id: ac7
  text: An unreachable or 401 workspace shows an error chip on its section while reachable
    workspaces still render (partial results)
  verdict: approved
- id: ac8
  text: The status->group mapping has an exhaustive unit test over all 8 spec statuses;
    multi-connection aggregation and per-workspace partial failure are covered with
    Ktor MockEngine tests
  verdict: approved
open_questions: []
non_goals:
- "iOS app (Swift/SwiftUI) \u2014 a separate later C-series task; Android first"
- "Spec detail screen (C4) and review/approve/dispatch actions (C5/C6/C7) \u2014 row\
  \ tap is a no-op placeholder"
- "Real Capture / Decisions / Tasks functionality \u2014 placeholder screens only\
  \ for v0"
- "Instrumented / Compose UI tests and emulator-based testing \u2014 no emulator in\
  \ the environment"
- "The GET /specs affected_repos extension \u2014 a separate small mothership PR,\
  \ not part of this ground-control task"
- "Multi-module / Kotlin Multiplatform split \u2014 single :app module now, package\
  \ boundaries kept so a later split is cheap"
risks:
- 'First-time Gradle/Android build in this freshly-provisioned toolchain may surface
  config issues (mitigated: JDK 17 + SDK 34 installed and verified)'
- 'DataStore is awkward to unit-test on the pure JVM (mitigated: keep persistence
  thin; test pure validation + list serialization, exercise DataStore lightly)'
- Multi-workspace partial-failure UX and parallel aggregation add complexity beyond
  the literal single-endpoint MOS-154/155 acceptance
- App rows depend on GET /specs returning affected_repos, which ships in a separate
  mothership PR; app unit tests use MockEngine sample JSON so the app is not blocked,
  but live data lacks repos until that merges
task_slug: c1-c2-app-shell-and-spec-inbox-mos-154
---
## Problem

Ground Control needs its first real surface: a mobile cockpit where a human reviews and steers specs across their Mothership projects. Today there is no app at all (android/ and ios/ are README stubs), and the human has no way to see what specs exist or what needs their attention without a terminal. The leverage is upstream at the spec level, so the inbox that shows specs by state — across every workspace — is the foundational screen everything else (capture, review, dispatch) hangs off of.

## User story

As a Mothership operator away from my desk, I want to open Ground Control on my phone and see the specs across all my mship workspaces grouped by workspace and by status, so that I can tell at a glance what needs review or dispatch without opening a terminal.

## Approach

Android-first (Kotlin + Jetpack Compose); iOS is deferred to a later C-series task. Single Gradle :app module, MVVM, organized by package: data/ (Ktor Client + kotlinx.serialization with ignoreUnknownKeys, DTOs, repositories, DataStore), ui/ (Compose screens + ViewModels exposing StateFlow), nav/ (Navigation-Compose). Package root com.atomikpanda.groundcontrol; Gradle 8.x via wrapper, AGP 8.5+, Kotlin 2.0, compileSdk 34, minSdk 26.

Multi-workspace from the start. Settings manages a LIST of workspace connections (WorkspaceConnection { id, baseUrl, token, workspaceName }) persisted as a JSON list in DataStore via ConnectionsRepository (add/edit/remove). Adding a connection calls GET /health to validate it and capture its workspace name (the group label). A single Ktor HttpClient is used; each request targets a connection's baseUrl with its bearer token. SpecRepository.listAllSpecs() fans out to every connection in parallel (async) and returns a per-workspace result [{ connection, workspaceName, Result<List<SpecSummary>> }] so one failing workspace never sinks the others.

The inbox (the Specs home screen) groups two levels: top-level workspace sections, each containing status subgroups in actionable order — Needs review (needs_review, needs_clarification), Ready to dispatch (approved), In implementation (dispatched), Drafting (captured, drafting), Done (implemented). archived is excluded; empty groups are hidden. This status->group mapping is pure Kotlin and exhaustively unit-tested. Each row shows title + status + affected repos; pull-to-refresh refreshes all connections. A workspace that is unreachable or returns 401 shows an error chip on its section while reachable workspaces still render (partial results).

App shell: single MainActivity hosting a Compose root with a Scaffold + bottom NavigationBar of five sections — Specs (home), Capture, Decisions, Tasks, Settings. Capture/Decisions/Tasks are placeholder 'Coming soon (C3/C6/C7)' screens, present and navigable only. The top bar surfaces overall connection state. Row tap -> spec detail is out of scope (C4): a no-op placeholder.

Verification is JVM unit tests only (no emulator/system-image in the environment): status->group mapping over all 8 statuses; DTO deserialization of sample /specs JSON including snake_case affected_repos; SpecRepository/ViewModel behavior via Ktor MockEngine (success->grouped state, 401->auth error, network failure->error, empty->empty, multi-connection aggregation, per-workspace partial failure); ConnectionsRepository list (de)serialization and URL/token validation as pure functions. The Taskfile.yml stubs are filled in to run the real Gradle wrapper from android/: setup (write local.properties sdk.dir from ANDROID_HOME), build (./gradlew assembleDebug), test (./gradlew testDebugUnitTest), lint (./gradlew lintDebug ktlintCheck), run (installDebug + adb, best-effort).
