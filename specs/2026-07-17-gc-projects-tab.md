---
id: gc-projects-tab
title: Ground Control Projects tab + per-workspace color/glyph identity (issue 375)
status: implemented
created_at: '2026-07-17T19:57:37.586609Z'
updated_at: '2026-07-17T22:52:22.423376Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: A new 'Projects' destination appears as a 5th item in the bottom navigation;
    opening it lists one row per connected workspace, each showing the workspace name
    and a colored glyph badge.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: SectionTest 5-route + ProjectsViewModelTest one-row-per-connection; Projects
      tab lists workspaces w/ badge
  comment: null
- id: ac2
  text: 'The auto-derived color is deterministic + stable: the same workspace name
    always maps to the same palette color across app restarts (unit-tested over a
    sample of names), and the default glyph is the name''s first letter uppercased.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: WorkspaceIdentityTest deterministic autoColor + first-letter autoGlyph,
      palette-bounded
  comment: null
- id: ac3
  text: The palette is a curated fixed set whose colors keep the badge glyph legible
    in both light and dark themes (not arbitrary hashed RGB).
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: 'WorkspaceIdentityContrastTest WCAG: white glyph >=3:1 on every swatch,
      curated palette'
  comment: null
- id: ac4
  text: An operator can set a per-workspace color and/or glyph override from the Projects
    tab; the override persists across app restarts (DataStore round-trip) and takes
    precedence over the auto-derived value.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: "ConnectionsCodecTest override round-trip + WorkspaceIdentityTest resolve\
      \ precedence + edit dialog \u2192 setIdentity"
  comment: null
- id: ac5
  text: When a workspace is re-paired (same id/baseUrl), a previously-set override
    is preserved rather than reset to the auto-derived value.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: ConnectionsCodecTest upsert_preserves_prior_override (id + baseUrl match)
  comment: null
- id: ac6
  text: Tapping a Projects row navigates to that workspace's existing detail screen
    (the `workspace/{connectionId}` route), reusing WorkspaceScreen.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: ProjectsViewModelTest row_route_targets workspace/{connectionId}; reuses
      WorkspaceScreen
  comment: null
- id: ac7
  text: "The same reusable WorkspaceBadge (color + glyph) renders wherever a workspace\
    \ is referenced \u2014 at minimum Home needs-you items, Queue cards, and the thread/spec/console\
    \ headers \u2014 via one shared composable."
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: WorkspaceBadge on Home/Queue + thread/spec/console headers via LocalWorkspaceIdentityResolver
  comment: null
- id: ac8
  text: 'Regression guard: Home and Queue continue to aggregate items across ALL workspaces
    (no app-scoping introduced); no mship serve endpoint is added or changed.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: 'ProjectsRegressionTest: VM has no SpecApi/HttpClient, lists all workspaces;
      aggregation unchanged'
  comment: null
open_questions: []
non_goals:
- "App-scoping / filtering: selecting a project does NOT filter Home/Queue/threads\
  \ to one workspace \u2014 cross-workspace aggregation is unchanged (that was explicitly\
  \ deferred)."
- 'Server-side identity: no mship serve change; color/glyph are derived + stored on-device
  only.'
- "A full workspace-management redesign \u2014 this is a directory tab + a consistent\
  \ identity badge, reusing the existing WorkspaceScreen as the per-workspace detail."
- Renaming or re-keying workspaces; the identity is derived from the existing workspaceName.
risks:
- "Color legibility: the palette must stay readable (badge glyph vs background) in\
  \ BOTH light and dark themes \u2014 curate a fixed palette + verify contrast, don't\
  \ hash into arbitrary RGB."
- 'Color collisions: hashing many workspace names into a finite palette can repeat
  colors; keep the palette reasonably large and accept that the glyph/name disambiguate
  on collision. Overrides let the operator break any clash.'
- 'Badge clutter: the badge must be small + consistent so it aids rather than crowds
  dense surfaces (Home items, Queue cards).'
- 'Override persistence across re-pair: re-pairing a workspace replaces its connection
  entry (upsert by id/baseUrl); the prior override must be carried over so a re-pair
  doesn''t silently reset a customized color/glyph.'
- "Bottom nav goes from 4 to 5 tabs \u2014 at Material's practical max; keep labels/icons\
  \ tight so the bar stays clean."
task_slug: gc-projects-tab
work_item_id: wi-20260717200228-f4681d8b
clarification_reason: null
prose_verdicts: {}
---
## Problem

Ground Control aggregates important items across workspaces well, but with many threads/specs/WorkItems spread over several workspaces the operator loses track of which workspace/project they're in — it all blends together into information overload, and workspace chips are the only way to reach a workspace. There's no persistent visual identity per workspace and no dedicated place to see + navigate the list of workspaces (GitHub issue #375).

## User story

As the Ground Control operator juggling several workspaces, I want a Projects tab that lists my workspaces each with a consistent, unique color + glyph — and that same identity shown everywhere a workspace appears — so I always know which project I'm looking at and can jump between them without hunting through chips.

## Approach

Ground Control only, no serve change, no app-scoping (Home/Queue keep aggregating across all workspaces — this is orientation + a directory, not a filter). Three parts. (1) PROJECTS TAB: a new 5th bottom-navigation destination ('Projects', joining Home/Queue/Tasks/Settings in the NavigationBar in GroundControlApp.kt). It lists one row per connected WorkspaceConnection — a colored glyph badge + the workspace name (and, if cheap, a small 'N need you' count). Tapping a row navigates to that workspace's EXISTING detail screen (the `workspace/{connectionId}` route / WorkspaceScreen.kt) — reuse it, don't build a new one. (2) WORKSPACE IDENTITY (auto-derived + override): add a pure helper (e.g. `WorkspaceIdentity`) that derives a STABLE color for a workspace by hashing its name into a curated palette (a fixed set of colors chosen for legibility in BOTH light and dark themes, defined alongside ui/theme/Color.kt) plus a glyph = the name's first letter (uppercased). Add nullable `colorOverride` (e.g. an ARGB/hex string) and `glyphOverride` fields to `WorkspaceConnection` (data/WorkspaceConnection.kt), persisted through the existing ConnectionsCodec/DataStore; when set they take precedence over the auto-derived value, else the auto value is used. The override is editable from the Projects tab (row overflow or a small edit affordance). Preserve an existing override across re-pairing: `upsertConnection` replaces an entry by id/baseUrl, so carry the prior entry's override onto the replacement when the incoming connection doesn't specify one (re-pairing keeps your chosen color/glyph). (3) IDENTITY EVERYWHERE: a single reusable `WorkspaceBadge` composable (colored circle/rounded square with the glyph, sized small) rendered wherever a workspace is referenced — at minimum Home needs-you items (NeedsYouItem.kt), Queue cards, and the thread/spec/console headers — plus the existing workspace chips restyled to use it — so the same identity is consistent across the app. Testable logic (derivation determinism, override precedence, re-pair preservation) lives in pure functions so it is unit-tested without a render.

## Testing

Unit (pure logic, JUnit): WorkspaceIdentity color derivation is deterministic + stable for a fixed sample of names and distributes across the palette; the default glyph is the uppercased first letter; override precedence (override wins over auto, auto used when null); ConnectionsCodec round-trips the new override fields; upsertConnection preserves a prior override when the incoming connection omits it (re-pair). UI/logic: the Projects list produces one row per connection; the WorkspaceBadge renders the resolved (override-or-auto) color+glyph; tapping a row emits navigation to `workspace/{connectionId}`. Contrast: assert palette colors meet a minimum contrast for the glyph in light + dark (or verify via a small helper). Regression: existing Home/Queue aggregation tests still pass unchanged.
