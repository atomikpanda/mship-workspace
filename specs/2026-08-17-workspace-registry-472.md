---
id: workspace-registry-472
title: 'Workspace registry: workspace as an explicit parameter, not ambient state
  (#472)'
status: implemented
created_at: '2026-08-17T01:28:50.932979Z'
updated_at: '2026-08-18T12:25:48.649809Z'
affected_repos:
- mothership
- ground-control
acceptance_criteria:
- id: ac1
  text: 'A scan root containing two valid mothership.yaml workspaces: a newly started
    daemon discovers and serves both without mship workspace add (end-to-end over
    the TCP bind seeded by mship daemon install --scan-root ... --serve HOST:PORT)'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  - kind: test
    ref: test-runs/3.mothership
    note: null
  comment: null
- id: ac2
  text: Scan roots are bounded and configurable; empty config scans nothing; the daemon
    never crawls the filesystem by default
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  - kind: test
    ref: test-runs/3.mothership
    note: null
  comment: null
- id: ac3
  text: Overlapping scan roots, duplicate-listed roots, and roots nested inside another
    root's workspace collapse to one registry entry (resolved-path dedupe + ancestor/descendant
    collapse, outermost wins)
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  - kind: test
    ref: test-runs/3.mothership
    note: null
  comment: null
- id: ac4
  text: .worktrees/ and .mothership/ are mandatory exclusions; a spawned task worktree
    with an inherited tracked mothership.yaml can never register; hand-made linked
    worktrees outside .worktrees/ are detected (.git-is-a-file / marker) and excluded
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  - kind: test
    ref: test-runs/3.mothership
    note: null
  comment: null
- id: ac5
  text: Invalid or unreadable mothership.yaml degrades visibly with the validation
    error; a parseable yaml whose repo paths all do not exist (template/example) degrades
    too; siblings still discover; the scan never aborts and the daemon never crashes
    on a bad candidate
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  - kind: test
    ref: test-runs/3.mothership
    note: null
  comment: null
- id: ac6
  text: The daemon serves at least two workspaces concurrently, addressed by stable
    workspace id in the URL, with distinct per-workspace state and no cross-workspace
    data bleed; degraded ids return 503 with the stored reason, unknown ids 404
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  - kind: test
    ref: test-runs/3.mothership
    note: null
  comment: null
- id: ac7
  text: No daemon serve code path reads cwd or inherited env to determine workspace,
    enforced by BOTH a poison-env/poison-cwd runtime test (decoy set in MSHIP_WORKSPACE;
    every recorded subprocess cwd under the real workspace; PrWatcher sweep driven
    through merge-close reconciliation) AND a static AST sweep over the import-graph-derived
    module set with detector self-tests and a seam allowlist
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  - kind: test
    ref: test-runs/3.mothership
    note: null
  comment: null
- id: ac8
  text: Ground Control lists a host's workspaces from GET /workspaces and selecting
    one by name yields a working derived connection ({host}/workspaces/{id}) with
    identity overrides preserved across re-discovery; old persisted connection JSON
    still deserializes
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  - kind: test
    ref: test-runs/3.mothership
    note: null
  comment: null
- id: ac9
  text: Single-repo, monorepo (git_root children), and metarepo (sibling repos) workspace
    shapes are all exercised in discovery, context-construction, and serve tests
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  - kind: test
    ref: test-runs/3.mothership
    note: null
  comment: null
- id: ac10
  text: 'The same workspace discovered on two hosts yields two independent registry
    entries with no exclusive-ownership semantics (behavior test + docstring pointing
    cross-host arbitration at #473''s claims)'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  - kind: test
    ref: test-runs/3.mothership
    note: null
  comment: null
- id: ac11
  text: 'A registry entry resolves everything #473 needs (path, repos topology, interpreter/venv,
    raw runner: block) with zero cwd or active-venv dependence'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  - kind: test
    ref: test-runs/3.mothership
    note: null
  comment: null
- id: ac12
  text: Rename/move preserves identity via the workspace-id file; a deleted workspace
    degrades to a visible missing entry; a COPIED workspace (duplicate id at two live
    paths) keeps the existing path and surfaces the copy as a degraded duplicate-identity
    entry, order-independently
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  - kind: test
    ref: test-runs/3.mothership
    note: null
  comment: null
- id: ac13
  text: Two workspaces with the same basename or same display name coexist under distinct
    stable ids
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  - kind: test
    ref: test-runs/3.mothership
    note: null
  comment: null
- id: ac14
  text: mship workspace list|add|remove|ignore|refresh exist as override/inspection
    controls; add on a duplicate-identity copy mints a fresh id; refresh works both
    against a live daemon (control socket) and directly against the store when no
    daemon runs
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  - kind: test
    ref: test-runs/3.mothership
    note: null
  comment: null
open_questions: []
non_goals:
- '#471: address-less rendezvous, relay host identity, short-lived host tokens, tunnel-state
  ladder. The ''host it has never had an address for'' half of the GC AC is explicitly
  flagged as #471''s, not claimed closed; pre-#471 phone reachability needs mship
  daemon install --serve on a tailnet/LAN host'
- '#473: worker scheduling, adapter contract, runner: schema semantics - the registry
  stores the raw runner: block opaquely plus runtime/repos so #473 resolves everything
  from the entry'
- 'ShellRunner env purity and a recorded git-identity registry field (once cwd is
  explicit, git resolves identity from each repo''s local config; a recorded field
  can land with #473 if worker env construction needs it)'
- Filesystem watching (v1 = startup scan + explicit refresh, per issue text); centralized
  fleet scheduling; any change to mship serve (stays the cwd-discovered foreground
  dev surface)
- 'GC manual-vs-discovered duplicate connection migration (defers to #471 when the
  manual pairing path disappears; current duplicate behavior is pinned by test + doc
  note)'
risks:
- 'Mounted-sub-app lifespans: Starlette does not run lifespans of mounted apps - mitigated
  by the ASGI-forwarding app cache with an explicit AsyncExitStack lifespan supervisor,
  and a test asserting PrWatchers actually start per sub-app'
- 'Worktree pollutants: spawn materializes tracked mothership.yaml inside .worktrees/<slug>/<repo>/
  - mandatory exclusions plus linked-worktree detection (.git-is-a-file, .mship-workspace
  ancestor marker), tested with real git worktree add both inside and outside .worktrees/'
- Copied workspaces (cp -r backup, cloned VM image) carry the same workspace-id file
  - reconciliation keeps the existing path and surfaces the copy as a visible degraded
  duplicate-identity entry, order-independent, never a silent path flip-flop
- A hand-listed ambient-sweep module set rots - the swept set is derived from the
  import graph with a superset canary, and the sweep is red against today's tree until
  Task 6 lands the fixes
- Env-wins discovery precedence (MSHIP_WORKSPACE) is the likeliest regression class
  - the poison test SETS the decoy in env rather than deleting it
task_slug: null
work_item_id: null
clarification_reason: null
prose_verdicts: {}
---
## Problem

mship serve derives its workspace from the directory it was started in (get_container -> ConfigLoader.discover(cwd)); a phone client has no cd, and the shipped #470 daemon is deliberately workspace-agnostic (capabilities registry/serve = false). There is no stable workspace identity anywhere, no enumeration code, and serve-time ambient reads persist: eight literal cwd=Path('.') sites in core/pr.py (inside every PrWatcher sweep), a cwd-relative shell run on the serve-routed topology probe, an env-read watch interval in serve's lifespan, and MSHIP_WORKSPACE env-wins discovery precedence. #472 makes the workspace an explicit, discovered, addressable parameter.

## User story

As a phone-first operator, I want each host daemon to auto-discover my Mothership workspaces from mothership.yaml under configured scan roots and serve all of them over one workspace-addressed API, so that Ground Control can list a host's workspaces and operate any of them with zero SSH, zero cd, and zero per-workspace registration ceremony.

## Approach

The daemon owns a durable per-host registry at ~/.mothership/daemon/: bounded configured scan roots are scanned for mothership.yaml at startup and on explicit refresh (v1: no filesystem watching); each valid discovery becomes an entry with a stable minted id (never the directory name; persisted to <ws>/.mothership/workspace-id so identity survives moves), path, repos/metarepo topology, runtime metadata (interpreter/venv - never the daemon's own), the raw runner: block for #473, and discovery state (healthy/degraded/missing). Serving N workspaces: a host app with GET /workspaces, POST /workspaces/refresh, and a catch-all /workspaces/{id}/{path} that resolves the id against the registry and forwards via ASGI to a cached lazily built create_app sub-app - one per healthy entry with its own PrWatcher lifespan under an AsyncExitStack supervisor (NOT static app.mount: Starlette neither mutates mount tables on refresh nor runs mounted sub-apps' lifespans, so the PrWatcher would silently never start). Scan roots + optional TCP serve bind seed via mship daemon install --scan-root/--serve into ~/.mothership/daemon/config.yaml. Ambient-state elimination: explicit cwd on PRManager (all eight sites) and the topology probe, watch-interval as a create_app parameter, and a WorkspaceContext factory that builds config/state/log/worktree managers from an explicit config_path with no discovery. Enforcement is double: a poison-env/poison-cwd runtime test (decoy workspace SET in MSHIP_WORKSPACE, not merely absent) plus a static AST sweep whose module set is derived transitively from the serve/host-app import graph (a hand list provably missed serve-reachable modules today) with an explicit allowlist for #471/#473 seams. Ground Control: pair a host once (base URL + host token), list GET /workspaces, select by name, persist a derived WorkspaceConnection with baseUrl {host}/workspaces/{id} - the entire existing GC stack works unchanged because baseUrl is opaque. mship workspace list/add/remove/ignore/refresh are override/inspection controls, not the onboarding path.

## Implementation plan

Built via ultracode (6 readers over mothership + ground-control, 2 independent drafts, judge synthesis, 3 adversarial verifiers - 21 findings folded in; the blocker replaced a hand-listed ambient-sweep set with one derived from the serve import graph). Plan: docs/plans/2026-08-17-workspace-registry-472.md (workspace repo) - 11 TDD tasks: registry model + flock'd store (two-hosts invariant), daemon scan config + install seeding, scanner (prune rule/dedupe/degraded), reconciliation + identity (id file, moves, copies, missing), WorkspaceContext factory (kills the cwd container on daemon paths), ambient audit (PRManager cwd x8 + topology cwd + watch-interval param + both enforcement tests), workspace-addressed host app (ASGI forward + per-entry lifespan supervisor), daemon wiring (startup rescan, capabilities flip, status, end-to-end AC-1), mship workspace CLI, minimal Ground Control list-and-select, docs + deferral close-out. Key decisions: dynamic resolver over app.mount (mounted lifespans never run); scan roots in ~/.mothership/daemon/config.yaml; id-file identity with keep-current-path duplicate rule; derived-import-graph sweep; pair-once host handle for GC pre-#471.
