---
id: ground-control-capture
title: 'Ground Control Capture: quick new-spec capture from the phone'
status: implemented
created_at: '2026-06-22T19:22:14.423326Z'
updated_at: '2026-06-22T21:33:22.212106Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: The Capture tab renders a real form (workspace selector, required Title, optional
    Affected repos, Create button), replacing the placeholder screen.
  verdict: unreviewed
- id: ac2
  text: The workspace selector lists the configured connections; it auto-selects when
    exactly one exists and shows an 'Add a workspace in Settings' empty state (Create
    disabled) when none are configured.
  verdict: unreviewed
- id: ac3
  text: The Create button is disabled while the Title is blank or a create request
    is in flight.
  verdict: unreviewed
- id: ac4
  text: Create calls POST /specs on the selected connection with {title, affected_repos}
    (affected repos comma-split, trimmed, empties dropped); on success the form clears
    and a confirmation shows the returned spec id.
  verdict: unreviewed
- id: ac5
  text: The newly created spec appears in the inbox under the Drafting group after
    a refresh.
  verdict: unreviewed
- id: ac6
  text: 'Errors are surfaced clearly: a 409 id collision shows ''a spec named that
    already exists'', a 401 shows an auth error pointing at Settings, and a network
    failure shows a retryable message.'
  verdict: unreviewed
- id: ac7
  text: SpecApi.createSpec (POST /specs path, request body shape, returns SpecRecord,
    409 -> ApiConflictException) and the CaptureViewModel state machine (no-connections
    empty state, blank-title disables Create, success clears + confirmation, 409 surfaces
    the collision message, multi-connection default selection) are covered with Ktor
    MockEngine unit tests; ./gradlew assembleDebug and testDebugUnitTest are green.
  verdict: unreviewed
open_questions: []
non_goals:
- Voice input / speech-to-text
- "The draft -> agent -> apply authoring flow (POST /specs/{id}/draft and /apply)\
  \ that turns an intent into a full structured spec \u2014 that is the larger Capture\
  \ slice"
- Editing the spec body or acceptance criteria from the phone
- Auto-navigating to the newly created spec's detail screen (the inbox refresh surfaces
  it; navigation is a possible later enhancement)
- "Any mothership / mship serve changes \u2014 POST /specs already exists"
- iOS
- Compose UI / instrumentation / emulator tests
risks:
- "A spec belongs to exactly one workspace, so the workspace selector is required\
  \ when more than one connection is configured; defaulting wrong would create the\
  \ spec in the wrong workspace \u2014 mitigated by auto-selecting only when there\
  \ is exactly one connection and otherwise requiring an explicit pick"
- POST /specs returns 409 on an id collision derived from the title; this must be
  surfaced as a clear message rather than a generic failure
task_slug: ground-control-capture
work_item_id: wi-20260702110439-a0d9a6bb
---
## Problem

Ground Control's Capture tab is still a 'coming soon' placeholder. When an idea strikes away from the desk, there is no way to get it into the system from the phone, so it gets lost or stashed elsewhere. The mship serve API already exposes POST /specs (create a stub spec), so a minimal capture surface is pure Ground Control app work with zero mothership changes. This is the smallest slice that makes the Capture tab real; the richer voice/draft-via-agent authoring flow is a separate later slice.

## User story

As a Mothership operator away from my desk, I want to jot a new spec title (and optionally its affected repos) from my phone and have it land in the inbox, so that an idea is captured and queued for drafting instead of being lost.

## Approach

Replace the Capture PlaceholderScreen with a real CaptureScreen (ui/capture/, MVVM + StateFlow) wired into GroundControlApp's nav in place of PlaceholderScreen("Capture"). The screen is a simple form: a workspace selector (dropdown of the configured WorkspaceConnections from ConnectionsRepository; auto-selected when exactly one exists; an empty state 'Add a workspace in Settings' with Create disabled when none), a required Title field, an optional Affected repos field (comma-separated), and a Create button disabled while Title is blank or a request is in flight. Create calls a new SpecApi.createSpec(conn, title, affectedRepos) -> SpecRecord that POSTs to the selected connection's /specs with a NewSpecBody{title, affected_repos} (repos comma-split, trimmed, empties dropped; id and task_slug omitted so the server derives the slug). On success the form clears and a confirmation shows the created spec id; the new spec appears in the inbox's Drafting group on the next refresh. Errors reuse the existing typed mapping: 409 (id collision) -> 'a spec named that already exists', 401 -> auth error pointing at Settings, network -> a retryable snackbar. Verification is JVM unit tests only (Ktor MockEngine), matching the rest of the app; no emulator.

## Data & ViewModel

Data: add a NewSpecBody DTO {title: String, id: String? = null, @SerialName("affected_repos") affectedRepos: List<String> = emptyList(), @SerialName("task_slug") taskSlug: String? = null} and SpecApi.createSpec(conn, title, affectedRepos): SpecRecord posting to ${conn.baseUrl}/specs with that body and the bearer auth; reuse the existing SpecRecord DTO and mshipDefaults error mapping (401->AuthException, 409->ApiConflictException, etc.). ViewModel: CaptureViewModel(connectionsProvider: () -> List<WorkspaceConnection>, api: SpecApi, testScope: CoroutineScope? = null) exposing StateFlow<CaptureUiState> with fields for the connections list, the selected connection id (defaulted when exactly one), the title and repos input, an inFlight flag, and a transient result/error message; pure helpers for default-selection and blank-title validation are unit-tested. The screen lives in ui/capture/ (CaptureScreen.kt + CaptureViewModel.kt) and is swapped into GroundControlApp's NavHost in place of PlaceholderScreen("Capture").
