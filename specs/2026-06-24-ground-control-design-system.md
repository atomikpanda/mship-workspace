---
id: ground-control-design-system
title: 'Ground Control terminal design system: Dracula-on-near-black theme, dark+light,
  JetBrains Mono'
status: implemented
created_at: '2026-06-24T23:01:28.137118Z'
updated_at: '2026-06-25T13:17:35.940000Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: '`GroundControlTheme` provides CUSTOM dark and light color schemes (not the
    stock `darkColorScheme()`/`lightColorScheme()` defaults), selected by the system
    dark/light setting.'
  verdict: approved
- id: ac2
  text: The palette defines the documented semantic roles (approval, question, blocker,
    error, plus background/surface/divider/text/muted) as named constants for BOTH
    dark and light modes.
  verdict: approved
- id: ac3
  text: "A pure function maps each 'Needs you' item kind to its semantic accent color\
    \ (blocker\u2192orange/amber, question\u2192cyan, approval\u2192green) for the\
    \ active scheme, and is covered by JVM unit tests for both modes."
  verdict: approved
- id: ac4
  text: JetBrains Mono is bundled (with its OFL license) and exposed as a monospace
    typography role; technical tokens (e.g. spec ids, task slugs, branch names, counts,
    workspace ids) render in it on the list screens.
  verdict: approved
- id: ac5
  text: The theme defines custom small-radius Shapes and a Typography, wired through
    `MaterialTheme`, so the whole app inherits the new look.
  verdict: approved
- id: ac6
  text: "On Home, each 'Needs you' row shows its kind's semantic accent, workspace\
    \ chips use distinguishable hues, and the 'unreachable' indicator uses the error\
    \ color \u2014 verified by a successful debug compile and manual smoke."
  verdict: approved
- id: ac7
  text: JVM unit tests cover the semantic color mapping and that both palettes expose
    the documented roles; visual application is verified by `compileDebugKotlin` /
    `assembleDebug` plus manual smoke (no emulator).
  verdict: approved
open_questions:
- id: q1
  text: "Deterministic assignment of the cycled workspace-chip hues \u2014 by stable\
    \ position/index, or a stable hash of the connection id (so a workspace keeps\
    \ its color across sessions)?"
  answer: stable hash
- id: q2
  text: Do any screens need more than semantic-color + mono application in this slice,
    or does inheriting the MaterialTheme suffice for the rest?
  answer: seems fine
- id: q3
  text: Should the bottom nav bar and FAB be explicitly themed (e.g. selected-tab
    neon, FAB accent) or left to MaterialTheme defaults derived from the scheme?
  answer: 'material theme for now '
non_goals:
- A manual in-app dark/light toggle (follow the system setting for now; a toggle is
  a later add)
- Dynamic color / Material-You wallpaper theming
- Bespoke per-screen redesigns beyond applying the system (semantic color + mono +
  the inherited theme)
- New iconography, illustration, or animation/motion design
- Any mothership API or server change
- iOS
risks:
- "Neon-on-near-black can fail WCAG contrast for small text if applied to body copy;\
  \ neon must be reserved for accents/large/iconography, with body text staying #F8F8F2\
  \ / #1E2230 \u2014 needs care per role."
- Light-mode variants of the neons must be re-checked for contrast on white (the dark
  neons are too light), hence the separate contrast-tuned light values.
- "Bundling JetBrains Mono adds a font asset (APK size, correct licensing/attribution\
  \ \u2014 it is OFL, must ship the license)."
- Applying semantic color across existing components risks visual regressions or hard-coded
  colors drifting from the palette; everything should reference the named roles, not
  literals.
task_slug: ground-control-design-system
work_item_id: wi-20260702110439-df4dd8c6
---
## Problem

Ground Control uses the stock Material3 default theme — `darkColorScheme()`/`lightColorScheme()` with no custom color, typography, or shapes — so despite a coherent IA (slice 1) and capture flow (slice 2), it reads as generic and unconsidered. There is no visual identity, and nothing uses color to help the user scan: the 'Needs you' queue's three item kinds (blocker / question / approval) look alike, and technical identifiers (spec ids, task slugs, branches) render in the same prose font as everything else, so they're hard to parse at a glance.

## User story

As someone triaging agent work on my phone, I want a deliberate terminal-style theme where neon color and a monospace font carry meaning, so that I can tell a blocker from a question from an approval at a glance and read identifiers cleanly — and the app feels considered, not stock.

## Approach

Define a real design system and apply it. Direction: terminal/technical, dark-first, neon used functionally (not decoratively); the accents are Dracula's accent hues on a true near-black background (not Dracula's #282A36). Support both dark and light schemes, keyed on `isSystemInDarkTheme()`. Dark: background #0A0E14, surface #12161F, elevated #1A1F2B, divider #2A2F3C, text #F8F8F2, muted #6272A4; semantic neons — approval/ready green #50FA7B, question/your-turn cyan #8BE9FD (also the primary interactive accent), blocker orange #FFB86C, error/unreachable red #FF5555, workspace chips cycle pink #FF79C6 / purple #BD93F9 / cyan / green. Light (same meanings, contrast-tuned): background #F8FAFC, surface #FFFFFF, divider #E2E8F0, text #1E2230, muted #64748B; approval #16A34A, question #0E7490, blocker #B45309, error #DC2626. Typography: system sans for prose; bundled JetBrains Mono exposed as a monospace text style for technical tokens. Shape/density: small corners (6dp cards/chips, 4dp inputs), tighter rows, hairline dividers. Implementation adds `ui/theme/Color.kt` (dark+light palettes as named constants + the semantic role values), `ui/theme/Type.kt` (Typography + the JetBrains Mono FontFamily + a mono style), and `ui/theme/Shape.kt` (small-radius Shapes); `GroundControlTheme` wires custom `lightColorScheme`/`darkColorScheme` + Typography + Shapes into `MaterialTheme`. The per-item-kind accent is a PURE, JVM-testable mapping (mirroring how `NeedsYouItem.UrgencyTier` is a pure value): a function from a `NeedsYouItem` (or its kind) + the active scheme to its accent `Color`, unit-tested for both modes. Then apply: Home 'Needs you' rows use the semantic accent per kind, workspace chips use the cycled hues, the 'unreachable' chip uses the error color, and technical tokens (workspace ids/names, task slugs, spec ids, counts) render in the mono style across the list screens (Home, Tasks, Spec detail, Conversation). Everything else inherits the new `MaterialTheme` automatically. Client-side only; no mothership change.

## Architecture

`ui/theme/Color.kt`: `object` palettes (e.g. `DraculaDark`/`DraculaLight`) holding the role constants, plus a `SemanticColors` data class (approval/question/blocker/error/...) built per scheme, and a pure `accentFor(item: NeedsYouItem, colors: SemanticColors): Color` (or keyed on a kind enum) — pure Kotlin, no Compose runtime needed, JVM-testable. `ui/theme/Type.kt`: a `FontFamily` from the bundled `res/font/jetbrains_mono_*.ttf`, a `Typography` for prose, and a `monoStyle`/mono `TextStyle` for technical tokens. `ui/theme/Shape.kt`: a `Shapes` with small radii. `GroundControlTheme` composes a custom `lightColorScheme(...)` and `darkColorScheme(...)` from the palettes and passes `colorScheme`/`typography`/`shapes` to `MaterialTheme`; a `SemanticColors` is exposed (e.g. via a `CompositionLocal` or derived from `isSystemInDarkTheme()`) so screens read kind-accents without hard-coding. Application touches `HomeScreen` (NeedsYouRow accent + chip hues + error color), and adds mono styling to identifier `Text`s on Home/Tasks/SpecDetail/Conversation; no logic changes to ViewModels/repos.

## Testing

JVM unit tests only (no emulator). Cover: `accentFor` returns the correct role color per item kind in both dark and light `SemanticColors`; both palettes expose every documented role (non-null, and dark != light where intended); the mapping is total over all `NeedsYouItem` kinds. `Color` is `androidx.compose.ui.graphics.Color`, a value class over a `Long` — assert via `.value`/ARGB on the JVM without a device. Visual wiring (MaterialTheme application, mono rendering, density) is verified by `assembleDebug` + manual smoke, consistent with how slices 1-2 handled UI-only changes.
