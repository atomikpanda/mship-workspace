---
id: serve-host-management-ui
title: Serve-host management web UI (isolated frontend, Jinja + Tailwind standalone
  CLI)
status: implemented
created_at: '2026-07-25T15:32:11.734451Z'
updated_at: '2026-07-25T19:19:05.755034Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: 'Every frontend artifact (templates, Tailwind input, generated stylesheet,
    build task) lives inside one self-contained package directory, and serve.py''s
    only UI-specific code is a single mount registration (grep-verifiable: no template
    names, asset paths, or UI routes elsewhere in serve)'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac2
  text: "Deleting or disabling the frontend package leaves `mship serve` fully functional\
    \ \u2014 every non-UI endpoint still serves and the test suite still passes \u2014\
    \ proving the frontend is detachable"
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac3
  text: 'Templates render exclusively from the `GET /net/topology` payload: a test
    asserts the template render context contains no keys beyond that payload (no Python
    objects, config objects, or store handles), so an external frontend could produce
    the same page from the endpoint alone'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac4
  text: Authentication is bearer-token-in-header (not cookie/session bound), so a
    future different-origin frontend can authenticate against the same endpoint unchanged
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac5
  text: "`mship serve` serves the console at /ui from the committed templates and\
    \ stylesheet \u2014 installing, running, and testing mship require no Tailwind\
    \ binary, no node/npm, and no build step"
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac6
  text: A go-task target fetches the pinned standalone Tailwind binary into a gitignored
    tools directory and compiles the stylesheet; the binary is absent from git and
    the resolved asset matches the host OS/arch or fails with an explicit message
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac7
  text: A drift check regenerates the stylesheet and fails when the committed copy
    differs, and it runs in CI or a documented task target
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac8
  text: "The console renders the full topology: serve mode and bind, relay subdomain\
    \ and reachability, each run-host role (declared / mapped / reachable) with the\
    \ source of its effective values, the active GitHub auth model, and egress state\
    \ \u2014 each edge showing its status and, when unhealthy, its fix hint"
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac9
  text: For each setup action (enroll a device, approve a request, map a run-host
    role, set a grant ceiling, issue a run token) the console shows the exact command
    pre-filled with that node's real values plus a copy affordance; no privileged
    mutation is performed by the UI
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac10
  text: "No secret material is rendered \u2014 no tokens, keys, or credential contents\
    \ appear even when present in config"
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac11
  text: 'Assets are fully self-contained: no external CDN, font, script, or stylesheet
    requests, verified by asserting the rendered HTML references no off-host URLs'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac12
  text: The console is legible in both light and dark schemes via Tailwind's dark
    variant against prefers-color-scheme
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac13
  text: 'Config-derived values are autoescaped: a test renders a role/hostname containing
    HTML metacharacters and asserts it appears escaped, with no |safe applied to config-derived
    values'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac14
  text: Each rendered page shows the mship version answering the request and the time
    the topology was probed, so a stale page is visible rather than silent
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
- id: ac15
  text: '`mship test --repos mothership` passes; template rendering is unit-tested
    without starting a real server'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/2.mothership
    note: null
  comment: null
open_questions: []
non_goals:
- "Actually publishing or deploying the frontend as a separate artifact now \u2014\
  \ this spec only ensures the extraction is cheap (HTTP-contract-only coupling, single\
  \ mount seam)"
- "Any node/npm dependency or JS bundler \u2014 styling is compiled by the standalone\
  \ Tailwind binary only, and the Tailwind CDN build is excluded because the console\
  \ must work with no internet"
- Committing the Tailwind binary itself (fetched by a task target into a gitignored
  tools dir); only its generated stylesheet is committed
- Requiring the binary or any build step to install, run, or test mship
- "Executing privileged mutations from the UI (approve enrollment, issue run token,\
  \ write run-host tokens) \u2014 deferred until scoped serve tokens (#370) land;\
  \ the UI shows the command instead"
- "A relay-host admin UI \u2014 relay-owner operations run on a different machine;\
  \ that is the acknowledged next slice after this one"
- 'Replacing or duplicating Ground Control: GC remains the operations surface (specs,
  decisions, PRs); this console is setup and topology only'
- "Reimplementing probing in the browser or in templates \u2014 all state comes from\
  \ the topology endpoint"
risks:
- 'Isolation is a discipline that is trivially violated: passing one convenient Python
  object into a template would silently couple the frontend to in-process state and
  quietly kill separability, which is why the template-context restriction is an acceptance
  criterion with a test rather than a convention'
- 'Stylesheet drift: an unregenerated build silently loses classes, hence the regenerate-and-compare
  check'
- 'Platform coverage: the pinned binary differs per OS/arch (linux x64/arm64, musl,
  macOS), so the fetch target must resolve the right asset or fail with a clear message
  rather than half-working'
- 'Serving a UI over the relay widens what the single serve bearer exposes; read-only
  scope limits this but the bearer still gates it, so #370 remains the real fix'
- Server-rendered pages are a point-in-time snapshot; a stale page could misrepresent
  live state, so each render should timestamp itself and offer an obvious refresh
- "Rendering config-derived strings into HTML is an injection surface if autoescaping\
  \ is ever bypassed (no |safe on config values) \u2014 worth an explicit test"
- "Scope creep toward 'management console for everything' \u2014 the topology/setup\
  \ boundary needs to hold or this becomes a second Ground Control"
task_slug: serve-host-management-ui
work_item_id: wi-20260725155623-3df9ebb9
clarification_reason: null
prose_verdicts: {}
---
## Problem

Even with a queryable topology model (spec connectivity-topology-layer), managing mship's connectivity means reading JSON or remembering which of ~15 subcommands applies to the machine you're on. The operator's reference point is Tailscale: a UI that shows the topology at a glance and gives guided flows for adding a node. mship can't copy that shape wholesale — Tailscale has a coordination server that authoritatively knows every node, whereas mship deliberately has none (serves are per-workspace-per-machine, the relay owner's allowlist lives on the relay host, and run-host mappings stay local-only so mothership.yaml remains public and portable). What IS achievable is a per-machine console: the serve host's own view of its topology plus live probes of its edges. It belongs on the serve host rather than in Ground Control for two reasons: setup is inherently machine-local (keys, role->url+token mappings, GitHub App credential paths), and there is a bootstrapping circularity — Ground Control reaches the workspace THROUGH the tunnel being configured, so it cannot help when connectivity is the broken thing. A local UI works before any relay exists. Two forces shape the build: this console is expected to grow (a relay-host admin surface is the acknowledged next slice), and the frontend may eventually ship separately from the Python package — so the frontend must be isolated in a way that makes that extraction cheap rather than a rewrite.

## User story

As an operator, I want a web console on the serve host that shows my connectivity topology and walks me through adding or fixing a node with copyable, context-filled commands, so that I can manage connections without memorizing the CLI surface or hand-assembling commands from docs.

## Approach

Server-rendered Jinja templates on the existing FastAPI serve, styled with Tailwind compiled by the standalone Tailwind CLI binary (verified available as tailwindcss-linux-x64 plus arm64/musl variants as of v4.3.3), so no node/npm enters the project. Server-rendering suits the console's job — render topology, show the next command — without a JS toolchain or stale-bundle failure mode.

Isolation is the load-bearing design constraint, because the frontend may later ship separately. The insight: separability is NOT achieved by which templating technology is used or by tidy directories — it is achieved by making an HTTP contract the ONLY coupling point. Concretely: (1) every frontend artifact (templates, Tailwind input, generated stylesheet, build task) lives in one self-contained package directory, e.g. src/mship/webui/; (2) that package attaches to serve through a single mount seam (one FastAPI sub-router/sub-app registration) so serve.py contains no other UI-specific code and runs normally with the package absent; (3) templates render EXCLUSIVELY from the `GET /net/topology` JSON payload — no Python objects, no config/store access, no in-process shortcuts — so the view layer consumes exactly what an external frontend could fetch; (4) authentication stays bearer-token-in-header rather than cookie/session bound, so a future different-origin frontend authenticates unchanged (CORS becomes a config question, not a redesign). Under those rules the Jinja templates are deliberately disposable: replacing them with a separately-shipped frontend means deleting a directory and pointing the new client at the same endpoint, with zero backend rework.

Build discipline: the pinned Tailwind binary is fetched by a go-task target into a gitignored tools directory (never committed — it is tens of megabytes), while the GENERATED stylesheet IS committed inside the webui package, so installing, running, or testing mship needs neither the binary nor any build step and the wheel stays self-contained. The one hazard the standalone CLI does not remove is drift — adding a utility class without recompiling leaves it silently unstyled — so a check regenerates the stylesheet and fails when the committed copy differs.

Scope of interaction is read-plus-guide, not execute: the console renders each edge's status and fix hint, and for every action (enroll a device, approve a request, map a run-host role, grant a ceiling, issue a run token) it shows the exact command pre-filled with that node's real values plus a copy button. The reason is security: issue #370 means one serve bearer already grants approve + exec + gh-token, so wiring privileged mutations behind that same bearer would turn it into a full admin credential reachable over the relay. In-UI mutations are a follow-on gated on scoped tokens.

## Sequencing

Depends on `connectivity-topology-layer` (its `probe_topology()` model with status codes and fix hints, and the versioned `GET /net/topology` payload that acts as the UI contract). Build order: topology layer -> this console -> (follow-on) relay-host admin surface, and separately scoped serve tokens (#370) which unlocks in-UI mutations. The relay admin UI is out of scope here but is the acknowledged destination, so the topology model and status codes should not assume a single-host world.

## Extraction path if the frontend ships separately

Because the only coupling is the HTTP contract, extraction is: (1) build the new frontend against the versioned `GET /net/topology` payload — the schema version field lets it detect a server mismatch; (2) enable CORS for its origin (a config change, since auth is already a header-borne bearer rather than a same-origin cookie); (3) delete the webui package directory and its mount line, along with the Tailwind task target and drift check if the new frontend owns its own styling. No backend logic moves, because none of it ever lived in the view layer. The Jinja templates are intentionally treated as disposable, which is why no effort is spent making them reusable as a component library.

## Why the generated stylesheet is committed

Committing a build artifact is normally a smell, so the reasoning is explicit: mship installs as a uv tool from git, and users must never need a Tailwind binary to run or test it. Committing the compiled stylesheet keeps the wheel self-contained and the test suite toolchain-free, and the drift check removes the usual downside of committed artifacts (silent staleness) by making a mismatch fail loudly. Only contributors who edit templates need the binary.
