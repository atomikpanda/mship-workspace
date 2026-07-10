---
id: ground-control-tasks-tab
title: 'Ground Control Tasks tab: monitor in-flight work (enrich TaskSummary + tasks
  list/detail + journal)'
status: implemented
created_at: '2026-06-22T22:53:35.204285Z'
updated_at: '2026-06-22T23:22:12.291485Z'
affected_repos:
- mothership
- ground-control
acceptance_criteria:
- id: ac1
  text: 'mothership: TaskSummary (and thus GET /tasks and GET /tasks/{slug}) includes
    description, pr_urls ({repo: url}), test_results ({repo: ''pass''|''fail''|''skip''}),
    and depends_on ([upstream_slug]) in addition to its existing fields; build_task_index
    populates them from the Task model and a unit test asserts them.'
  verdict: unreviewed
- id: ac2
  text: 'ground-control: TaskSummary and JournalEntry DTOs deserialize the server
    payloads (including the maps, null/optional fields, and ignoreUnknownKeys); SpecApi/TasksApi
    gains listTasks (GET /tasks), getTask (GET /tasks/{slug}), and getJournal (GET
    /journal/{slug}) with bearer auth and the existing 401/404/409 mapping, covered
    with Ktor MockEngine.'
  verdict: unreviewed
- id: ac3
  text: "The Tasks tab replaces the placeholder and lists tasks aggregated across\
    \ all configured connections, grouped workspace \u2192 Active (finished_at null)\
    \ / Finished, with one unreachable workspace shown as an error chip while the\
    \ others still render (partial results); pull-to-refresh re-fetches."
  verdict: unreviewed
- id: ac4
  text: Each task row shows the description (slug fallback), a phase chip, per-repo
    test status, a blocked indicator when blocked_reason is set, and a PR badge when
    pr_urls is non-empty.
  verdict: unreviewed
- id: ac5
  text: Tapping a task row opens taskDetail/{connectionId}/{slug}; the detail screen
    shows description, phase, branch, affected repos, per-repo test results, blocked
    reason, depends_on, tappable PR links that open in the browser (Compose LocalUriHandler),
    and the journal timeline from GET /journal/{slug}; back returns to the list; pull-to-refresh
    re-syncs.
  verdict: unreviewed
- id: ac6
  text: "Error handling matches the spec screens: 401 \u2192 auth error (Settings\
    \ hint), 404 \u2192 'task no longer available', network \u2192 retry; covered\
    \ by the ViewModel tests."
  verdict: unreviewed
- id: ac7
  text: "Tests: mothership pytest covers the widened build_task_index / serve /tasks\
    \ shape; ground-control covers DTO deserialization, the API calls (paths/auth/error\
    \ mapping) with MockEngine, TasksRepository parallel aggregation + partial failure,\
    \ the Tasks list grouping (workspace \u2192 active/finished, pure function), and\
    \ the Task detail + journal ViewModel state machine. ./gradlew assembleDebug +\
    \ testDebugUnitTest are green and the mothership suite is green."
  verdict: unreviewed
open_questions: []
non_goals:
- "Acting on tasks from the phone (unblock / finish / dispatch-more / retry / phase\
  \ transitions) \u2014 this is a READ-ONLY monitor in v1"
- "Live updates / SSE / websockets \u2014 pull-to-refresh only (consistent with the\
  \ inbox)"
- "A full dependency-graph visualization \u2014 depends_on is shown as a flat list\
  \ of upstream slugs"
- phase_entered_at / 'time in phase' durations, and showing worktree filesystem paths
- Notifications / push (its own later slice)
- iOS; Compose UI / instrumentation / emulator tests
risks:
- TaskSummary is a public API shape consumed by the app; widening it is additive (new
  optional fields) so existing consumers (mship view, etc.) are unaffected, but the
  build_task_index test must assert the new fields and the app DTOs must decode with
  ignoreUnknownKeys for forward-compat.
- Tasks belong to a specific workspace/connection; the list aggregates across connections
  and a tap must carry the connectionId so the detail + journal fetch hit the right
  workspace (same pattern as the spec inbox/detail).
- Per-repo test_results flatten TestResult to a status string (dropping the timestamp);
  that is sufficient for the monitor view and keeps the DTO small.
- Journal can be up to 50 entries with sparse optional fields; the timeline must render
  missing action/test_state/repo/open_question gracefully.
task_slug: ground-control-tasks-tab
work_item_id: wi-20260702110439-94a67250
---
## Problem

Ground Control's loop is one-directional: you can review → approve → dispatch a spec from your phone, which kicks off real work on the host, but then the phone goes blind. There's no way to see whether the dispatched task is running, which phase it's in, whether its tests pass, whether it's blocked waiting on you, or where its PR is. The Tasks tab is still a 'coming soon' placeholder. The server already exposes the reads (GET /tasks, /tasks/{slug}, /journal/{slug}), but its TaskSummary is too thin for a useful monitor — it omits the task description, PR urls, per-repo test results, and dependencies. So this slice both widens TaskSummary (a small mothership change) and builds the Tasks tab (ground-control), closing the dispatch→watch loop.

## User story

As a Mothership operator who just dispatched work from my phone, I want a Tasks tab that shows my in-flight tasks — phase, per-repo test status, blocked reason, and a tap-through to the PR — plus the recent journal, so that I can watch progress and know when something needs me without a terminal.

## Approach

Two repos. (1) mothership: widen TaskSummary (src/mship/core/view/task_index.py) with description (Task.description), pr_urls ({repo: url} from Task.pr_urls), test_results ({repo: 'pass'|'fail'|'skip'} flattened from Task.test_results[repo].status), and depends_on ([upstream_slug] from Task.depends_on); keep all current fields. /tasks and /tasks/{slug} return the widened summary (same shape); /journal/{slug} is unchanged. (2) ground-control: a read-only Tasks tab, MVVM + StateFlow, mirroring the inbox patterns. New DTOs TaskSummary and JournalEntry; extend the API with listTasks (GET /tasks), getTask (GET /tasks/{slug}), getJournal (GET /journal/{slug}) reusing the existing mshipDefaults typed error mapping (401/404/409) and bearer auth. A TasksRepository fans out listTasks across all configured connections in parallel (like SpecRepository.listAllSpecs) so one unreachable workspace never sinks the others. The Tasks list screen replaces PlaceholderScreen('Tasks'): grouped workspace → Active (finished_at null) / Finished, each row showing the description (slug fallback), a phase chip, per-repo test status, a blocked indicator when blocked_reason is set, and a PR badge when pr_urls is non-empty; pull-to-refresh. A row tap navigates taskDetail/{connectionId}/{slug} (reusing the inbox's connectionId carry + connection-resolve). The Task detail screen shows description, phase, branch, affected repos, per-repo test results, tappable PR links (opened in the browser via Compose LocalUriHandler — no new dependency), blocked reason, depends_on (upstream slugs), and the journal timeline from GET /journal/{slug} (each entry: timestamp, message, with action/test_state/repo badges and open_question highlighted); pull-to-refresh + back. Verification is JVM unit tests only (no emulator) on the app and pytest on the server.

## Server enrichment (mothership)

src/mship/core/view/task_index.py: add to the TaskSummary dataclass and its construction in build_task_index: description: str (task.description); pr_urls: dict[str, str] (task.pr_urls); test_results: dict[str, str] (= {repo: tr.status for repo, tr in task.test_results.items()}); depends_on: list[str] (= [e.upstream_slug for e in task.depends_on]). All additive; existing fields (slug, phase, branch, affected_repos, worktrees, finished_at, blocked_reason, created_at, spec_count, orphan, tests_failing) unchanged. Tests in tests/core/view/test_task_index.py (or wherever build_task_index is tested) assert the new fields from a Task that has a description, pr_urls, test_results, and a depends_on edge; the serve /tasks shape test in tests/core/test_serve.py covers the JSON.

## App data + screens (ground-control)

DTOs (data/dto/): TaskSummary(slug, description, status?/phase, branch, @SerialName affected_repos, @SerialName pr_urls: Map<String,String> = emptyMap(), @SerialName test_results: Map<String,String> = emptyMap(), @SerialName blocked_reason: String? = null, @SerialName depends_on: List<String> = emptyList(), @SerialName spec_count: Int = 0, orphan: Boolean = false, @SerialName tests_failing: Boolean = false, @SerialName finished_at: String? = null, @SerialName created_at: String? = null) and JournalEntry(timestamp, message, repo?, action?, @SerialName test_state: String? = null, @SerialName open_question: String? = null, category?, iteration: Int? = null). API: listTasks/getTask/getJournal on the existing SpecApi (or a sibling TasksApi) using the same client + auth + mshipDefaults. TasksRepository.listAllTasks(connections) mirrors SpecRepository.listAllSpecs (parallel async, per-workspace Result). ui/tasks/TasksScreen.kt + TasksViewModel.kt (list, grouped workspace → active/finished via a pure helper; replaces PlaceholderScreen in GroundControlApp's Tasks route) and ui/tasks/TaskDetailScreen.kt + TaskDetailViewModel.kt (taskDetail/{connectionId}/{slug} route; loads getTask + getJournal; PR links via androidx.compose.ui.platform.LocalUriHandler.openUri). Reuse the inbox's connectionId carry + runBlockingSnapshot connection-resolve and the pull-to-refresh pattern. JVM unit tests only; no Compose/instrumentation tests.
