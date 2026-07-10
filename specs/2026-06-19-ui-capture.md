---
id: ui-capture
title: 'mship capture: UI capture as a first-class iteration primitive'
status: implemented
created_at: '2026-06-19T15:40:57.052920Z'
updated_at: '2026-06-21T20:11:23.635443Z'
affected_repos:
- mothership
- ground-control
acceptance_criteria:
- id: ac1
  text: '`mship capture` resolves the active task/worktree and runs the repo''s canonical
    `capture` go-task target (resolvable/overridable per-repo like `test`), in the
    worktree''s repo dir, with `MSHIP_CAPTURE_DIR`, `MSHIP_CAPTURE_PLATFORM`, and
    `MSHIP_CAPTURE_KINDS` set.'
  verdict: approved
- id: ac2
  text: 'A capture produces a bundle of typed artifacts: mship discovers `screen.png`
    as kind `image` and `layout.{xml,json,html}` as kind `layout` in the output dir,
    verifies at least one is non-empty, and reports each as `{kind, path}` (TTY: a
    friendly line per artifact; non-TTY: JSON `{platform, artifacts:[{kind,path}]}`).'
  verdict: approved
- id: ac3
  text: '`--kind image|layout|all` filters requested kinds (default all); `--out <dir>`
    overrides the default output dir; default output dir is `.mothership/captures/<task>/<timestamp>-<platform>/`
    with its parent auto-created.'
  verdict: approved
- id: ac4
  text: '`--platform` is required when the repo exposes more than one platform (from
    repo config, e.g. `capture.platforms`), with a clear error listing the options;
    a repo exposing exactly one platform uses it implicitly; no platform is hard-coded
    as a default.'
  verdict: approved
- id: ac5
  text: 'Error handling: a repo with no `capture` target errors clearly (pointing
    at ground-control as the example); a target that runs but produces no/empty recognized
    artifact errors with the target''s stderr tail; an underlying tool/device failure
    (adb/simctl missing, no device, app not running) surfaces the target''s stderr
    verbatim.'
  verdict: approved
- id: ac6
  text: ground-control defines the Android backend (`image` = adb screencap, `layout`
    = adb uiautomator dump) and the iOS backend (`image` = simctl io booted screenshot;
    `layout` unsupported), declares its available platforms, and these targets are
    guarded by a smoke check asserting they exist with the expected commands.
  verdict: approved
- id: ac7
  text: The `working-with-mothership` skill documents `mship capture` (command reference
    + the UI self-verification dev loop alongside `mship test`).
  verdict: approved
open_questions: []
non_goals:
- "An evidence trail / indexing / latest.json / cross-iteration visual diffing or\
  \ regression detection \u2014 this is an ephemeral iteration primitive, not the\
  \ test-runs evidence model."
- Gating `mship finish` on a capture, or surfacing captures in Ground Control / `mship
  serve`.
- "Booting or managing emulators/simulators/devices \u2014 capture assumes the app\
  \ is already running (that is `mship run`'s job)."
- "Multi-device selection (adb -s / multiple booted sims) \u2014 error on ambiguity\
  \ for v1; add later."
- "The remote-run-machine executor (dev on Linux \u2192 sync/run/capture on a remote\
  \ macOS) \u2014 explicitly a separate future issue; this design only stays compatible\
  \ with it."
- "A browser/web backend \u2014 no web member exists yet; it drops in later as just\
  \ another `task capture` with image+DOM, no mship change."
- "Semantic interpretation of layout dumps or OCR of screenshots \u2014 mship stores\
  \ raw artifacts; the agent reads/interprets them."
risks:
- 'Platform parameterization: ground-control is one repo with android/ios subdirs,
  so capture must route `--platform` to the right target/dir; getting the platforms-available
  + required-when->1 logic wrong would block or mis-target capture.'
- 'Artifact-discovery contract drift: if the Taskfile writes a filename mship''s kind
  map doesn''t recognize, the artifact is silently dropped; mitigate with a clear
  filename convention + the at-least-one-non-empty check erroring loudly when nothing
  recognized is produced.'
- iOS layout has no clean simctl hierarchy dump; declaring it unsupported (rather
  than faking it) avoids a misleading artifact.
- Capturing while no app/device is running yields a target failure; mship must surface
  the target's stderr verbatim rather than a generic error so the cause (no device,
  adb missing, app not launched) is obvious.
task_slug: ui-capture
work_item_id: wi-20260702110439-86cc0812
---
## Problem

Agents building UI — ground-control's Android/iOS Compose/SwiftUI screens, or any future web frontend — are flying blind. They can read source and run unit tests, but they cannot see the *rendered* result, which is exactly where UI work breaks (layout, spacing, wrong text, missing/duplicated elements, broken state). There is no mship primitive to grab the live UI state, so self-verification of UI changes is impossible and iteration is guesswork. mship already treats the test-evidence trail as first-class (`mship test`); there is no analogous way to capture what the UI actually looks like for the agent to inspect.

## User story

As an agent (or human) iterating on a UI in a mothership task, I want a single command that captures the current rendered state of the running app — as a screenshot and/or a structured layout dump — into files I can read, so that I can compare the result against intent and self-correct mid-dev without a human relaying what they see.

## Approach

Add `mship capture`, a lightweight iteration primitive built on the existing go-task delegation model (mirrors `mship test` → `task test`). mship resolves the active task/worktree and the target platform, runs the repo's canonical `capture` go-task target, and reports the produced artifact paths; the agent then Reads them (images are multimodal; layout dumps are text). mship stays completely env-agnostic — each repo's Taskfile owns the platform mechanics (adb/simctl/etc.), so the same target later runs unchanged on a remote host. A capture produces a *bundle* of typed artifacts (not just an image): `image` (screenshot) and/or `layout` (structured rendered state — Android view hierarchy XML, web DOM, etc.), extensible to future kinds with no mship change. Contract: mship hands the target an output directory via `MSHIP_CAPTURE_DIR` plus `MSHIP_CAPTURE_PLATFORM` and `MSHIP_CAPTURE_KINDS`; the target writes conventionally-named files (`screen.png`, `layout.{xml,json,html}`) for the kinds it supports; mship discovers them by that filename map, verifies at least one non-empty artifact exists, and reports each typed path. Capture assumes the app is already running (via `mship run`) and never boots emulators/simulators. ground-control gets the first backends: Android (`image` via `adb exec-out screencap -p`, `layout` via `adb exec-out uiautomator dump`) and iOS (`image` via `xcrun simctl io booted screenshot`; `layout` unsupported for now — the bundle model degrades gracefully).

## Architecture

`mship capture` (cli/capture.py + a thin core/capture.py) reuses the existing task resolver and the executor's canonical-task-name resolution (`repo.tasks.capture`, defaulting to `capture`). core/capture.py is the pure/testable boundary: given a worktree dir, platform, requested kinds, and an output dir, it builds the env (`MSHIP_CAPTURE_DIR`/`MSHIP_CAPTURE_PLATFORM`/`MSHIP_CAPTURE_KINDS`), invokes the go-task target via the existing runner, then discovers artifacts by a kind→filename map (`image`→`screen.png`, `layout`→`layout.{xml,json,html}`) and validates at-least-one-non-empty. The platform set + required-when->1 logic reads from per-repo config (`capture.platforms`). ground-control owns the actual capture commands in its Taskfile (parameterized by platform), so mship never references adb/simctl. This keeps the design env-agnostic and forward-compatible with a future remote executor that runs the same `task capture` on another host.

## Testing

mship unit tests mock the go-task runner (no real device): command resolves repo+platform and passes the correct cwd/target/env; artifact discovery maps `screen.png`→image and `layout.xml`→layout and reports both; `--kind` narrows requested kinds; the ≥1-non-empty-artifact check (write a fake file → pass; empty/none → error); `--platform` required when >1 platform (error lists options) and implicit when exactly one; missing `capture` target errors; default output dir + parent creation; TTY vs JSON output shape. ground-control: a guard test asserts the `capture` (android/ios) targets exist in the Taskfile with the expected adb/simctl commands — no device run. All locally verifiable; no emulator/simulator required for the suite.
