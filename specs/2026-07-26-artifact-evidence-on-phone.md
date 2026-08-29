---
id: artifact-evidence-on-phone
title: 'Artifact evidence the phone can see: capture into review'
status: implemented
created_at: '2026-07-26T00:40:51.822435Z'
updated_at: '2026-07-26T21:32:06.554632Z'
affected_repos:
- mothership
- ground-control
acceptance_criteria:
- id: ac1
  text: Running mship capture --evidence <spec-id>:<ac-id> in a repo with a capture
    target attaches artifact evidence to that criterion in a single command, with
    no separate mship spec evidence call.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  comment: null
- id: ac2
  text: Artifact bytes are stored under .mothership/evidence/<spec-id>/ named by a
    content hash plus the original extension, and the ref persisted on the criterion
    is the bare filename rather than a path. The store is machine-local and gitignored,
    so it works identically in a multi-repo workspace, a monorepo, and a single repo.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  comment: null
- id: ac3
  text: mothership.yaml accepts an evidence_storage key of published, local, or encrypted,
    and when the key is absent evidence inherits the workspace's spec_storage mode,
    mapping committed to published.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  comment: null
- id: ac4
  text: Config load fails with an error naming both keys when evidence_storage is
    more exposed than spec_storage, where exposure orders as committed above encrypted
    above local.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  comment: null
- id: ac5
  text: Under published mode a referenced artifact is committed to an mship-evidence
    orphan branch in the member repo the pull request targets, and only that branch
    is pushed; under local mode nothing is ever published; under encrypted mode the
    artifact is written as ciphertext with an .enc suffix and no plaintext bytes are
    emitted or published.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  comment: null
- id: ac6
  text: 'Publishing never touches a repo''s default branch: the orphan branch shares
    no history with it, mship finish pushes that branch alone, and no commit is created
    on main in any repo.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  comment: null
- id: ac7
  text: A spec whose task spans several repos publishes to each repo that receives
    a pull request, so every PR is self-contained and no reviewer needs read access
    to a sibling repo.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  - kind: commit
    ref: 0c10432bffd72d1090a4036445322e27484a05d0
    note: null
  comment: null
- id: ac8
  text: GET /specs/{spec_id}/evidence/{name}/blob returns the artifact bytes with
    a content-type derived from the extension when called with a valid filename and
    the existing bearer token.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  comment: null
- id: ac9
  text: The blob route returns 404 for any name that resolves outside the spec's evidence
    directory, including relative traversal, an absolute path, and a symlink pointing
    out of the store.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  comment: null
- id: ac10
  text: When an encrypted artifact cannot be decrypted on the responding host, the
    blob route reports the same key-unavailable condition the spec read path already
    reports rather than a generic failure.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  comment: null
- id: ac11
  text: In Ground Control an image artifact renders full-width on the spec detail
    criterion row, and tapping it opens a zoomed view.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  comment: null
- id: ac12
  text: Non-image artifact evidence continues to render as the existing text label,
    and an image artifact whose bytes cannot be fetched renders as that same text
    label rather than a broken image.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  comment: null
- id: ac13
  text: A capture whose evidence attach fails still reports the artifacts it produced
    and exits successfully, emitting a warning rather than an error.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  - kind: commit
    ref: 7a4c603bd1629f002d3222f3bec63b36a9fdb31b
    note: null
  - kind: commit
    ref: a974e109090080dac880e68aea990ac04f652eda
    note: null
  comment: null
- id: ac14
  text: The un-evidenced-criteria warning emitted at a phase transition names mship
    capture --evidence as the remedy for affected repos that define a capture target.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  comment: null
- id: ac15
  text: mship capture --remote --evidence attaches evidence from artifacts produced
    on a mapped run host, indistinguishably from a locally produced capture.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  - kind: commit
    ref: 7a4c603bd1629f002d3222f3bec63b36a9fdb31b
    note: null
  comment: null
- id: ac16
  text: A capture run without --evidence writes only to the existing ephemeral captures
    location, copies nothing into the evidence store, and attaches no evidence to
    any spec.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  comment: null
- id: ac17
  text: "Attached evidence records the revision the capture was taken from, and marks\
    \ it when that revision is not a commit on a branch \u2014 an uncommitted working\
    \ tree or a throwaway run ref \u2014 with Ground Control showing that marker alongside\
    \ the image."
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  comment: null
- id: ac18
  text: Under published storage, the PR body renders an image artifact as an embedded
    image using an absolute raw URL pinned to the orphan-branch commit that contains
    it, verified present at that commit before the URL is emitted, so a reviewer on
    GitHub sees the screenshot rather than a filename.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  comment: null
- id: ac19
  text: "When the artifact cannot be embedded \u2014 local or encrypted storage, a\
    \ push that failed, or a byte not verifiably present at the pinned commit \u2014\
    \ the PR body names the artifact instead of emitting a broken image, and finish\
    \ warns with the reason."
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  - kind: commit
    ref: a9e5d73ce6de4ae0a61a707c8eca25a12ce94d1f
    note: null
  comment: null
- id: ac20
  text: Non-image artifact evidence and the existing test and commit evidence refs
    render in the PR body exactly as they do today.
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/5.ground-control
    note: null
  - kind: test
    ref: test-runs/5.mothership
    note: null
  comment: null
open_questions: []
non_goals:
- Not a gate. The un-evidenced-criteria warning at a phase transition stays a warning;
  artifact evidence informs review and never blocks a transition or an approval.
- Not a general file-upload API. The blob route is read-only and serves only artifacts
  mship itself produced.
- Not uploading artifacts to GitHub's attachment CDN. There is no public API for it,
  so embedding works by publishing bytes to a ref GitHub already serves.
- Not writing to any repo's default branch, and not writing to the workspace repo
  at all. Publication is confined to an orphan branch that shares no history with
  main; the operator's specs, prose, and config are never staged, committed, or pushed
  by this feature.
- No garbage collection of the orphan branch. Published artifacts accumulate there;
  pruning is a deliberate later decision, not something this feature does silently.
- No deletion or garbage collection of evidence bytes in this slice. Nothing deletes
  captures today either; spec archive is the natural future GC point and is left as
  a note.
- No renaming or restructuring of capture's --kind axis, despite it sharing the word
  'kind' with AcceptanceEvidence.kind.
- No cross-host live fetch. One workspace machine's serve does not proxy blob requests
  to another over the relay.
- No change to bare mship capture. The develop-verify-iterate loop keeps its existing
  ephemeral, gitignored output location and gains no new behaviour, cost, or retention
  concern.
- No change to how test and commit evidence kinds are produced, stored, or rendered.
risks:
- 'Under committed mode, binary blobs accumulate monotonically in the workspace git
  repo. Bounded primarily by the rule that only --evidence promotes a capture into
  the store, so growth tracks the number of evidenced criteria rather than the number
  of develop-verify-iterate captures. Further mitigated by content-addressed naming
  (identical re-captures dedupe) and the response size cap, with evidence_storage:
  local as the escape hatch. If it becomes painful the answer is git-lfs or a prune
  command, neither of which changes the ref shape.'
- Evidence captured from an uncommitted tree or a throwaway run ref backs a criterion
  with something that exists on no branch. The provenance marker is what keeps this
  honest; without it a work-in-progress screenshot is indistinguishable from one taken
  at a committed revision, and the evidence loop would quietly overstate what it proves.
- "A ref whose bytes are unavailable \u2014 cleared by doctor's rm -rf hint, or local-mode\
  \ evidence viewed from another machine \u2014 must degrade visibly rather than silently\
  \ resembling a criterion that was never evidenced."
- The evidence ref is attacker-adjacent free text on existing specs. The blob route
  must reject relative traversal, absolute paths, and symlinks escaping the evidence
  directory.
- Storing plaintext artifacts beside an encrypted spec would leak exactly what encryption
  was protecting. The exposure invariant exists to prevent it and must be enforced
  at config load, not merely documented.
- "Evidence is attached after implementation, while the Queue renders specs awaiting\
  \ approval beforehand, so the two never coincide. Any future attempt to surface\
  \ evidence in the Queue should first establish how an implemented spec gets back\
  \ in front of the operator for acceptance \u2014 that is a lifecycle question, not\
  \ a rendering one."
- "PR embedding depends on the evidence commit being pushed to the workspace repo\
  \ before the PR body is rendered. That makes committing specs and evidence load-bearing\
  \ rather than advisory \u2014 and the workspace repo currently accumulates untracked\
  \ specs, so this will be hit. The mitigation is the explicit finish warning plus\
  \ the name-instead-of-broken-image fallback."
- Embedding requires the workspace repo to be readable by whoever reads the PR, which
  for a public repo means the screenshots are public. That is a consequence of choosing
  committed storage rather than a new exposure, but it should be stated where an operator
  decides the storage mode rather than discovered from a PR.
- Copying artifacts into the store on attach introduces a filesystem write into the
  capture path, which must never be able to fail a capture that otherwise succeeded.
task_slug: null
work_item_id: null
clarification_reason: null
prose_verdicts: {}
---
## Problem

The acceptance-criterion evidence loop works for test and commit refs, but the artifact kind never lands. Nothing produces it automatically: mship capture drives the platform target and files screenshots and layout dumps under .mothership/captures/, but it knows nothing about specs, so linking a capture to a criterion is a manual second step that in practice never happens. The phone cannot fetch it: serve has no read route for artifact bytes, and an artifact ref is a path on one machine's disk, which is meaningless to a phone over the relay. And it renders as a string: evidenceLabels formats every evidence kind uniformly as 'kind: ref', so a screenshot appears on the review card as a file path rather than a picture. The result is that a reviewer approving a criterion about visible behaviour is ratifying a claim instead of looking at the outcome. For a workspace whose product is a mobile app, Ground Control currently cannot see itself.

## User story

As the operator reviewing a spec on my phone, I want the screenshot the agent captured to appear next to the acceptance criterion it backs, so that I approve what the app actually looks like rather than a claim that it looks right.

## Approach

Close the loop in three hops, plus one module that owns the path math.

A new core/evidence_store.py owns where artifact bytes live and how a ref resolves back to them. Bytes are stored at .mothership/evidence/<spec-id>/<sha12>.<ext> and the ref persisted on the criterion is the bare filename, not a path. That is deliberate: with a bare filename the resolver has exactly one root to join against, so traversal is prevented by construction rather than by validation. Both the CLI and serve go through this module, so there is a single owner for the location.

Attach becomes one step. mship capture --evidence <spec-id>:<ac-id> runs the capture as it does today, then hashes each discovered artifact, copies it into the store, and attaches it through the existing evidence path as kind=artifact with the capture kind and platform recorded in the note. A run producing both an image and a layout attaches two evidences. Capture's own --kind axis (image|layout) is untouched and stays distinct from AcceptanceEvidence.kind (test|commit|artifact); the two share a word and should not be conflated further.

The store is machine-local and gitignored, and that is a deliberate correction. An earlier design kept bytes in the workspace repo under specs/, which quietly assumed the workspace is a separate metarepo from the product code. mship also supports a monorepo and a single repo, where the workspace root IS the product repo — so that design would have committed screenshots into the product's own history and pushed its main branch as a side effect of opening a pull request. Keeping the store under .mothership/ works identically in all three shapes and assumes nothing about how many git repos exist.

Because the store is local, evidence does not travel by git the way specs do. The phone does not need it to: it fetches bytes from mship serve over the relay, from the machine that captured them. What does need a git-reachable location is the pull request, and that is a separate, explicit step rather than a property of where the file happens to sit.

The two keys cannot be allowed to contradict each other. Ordering the modes by exposure as committed > encrypted > local, evidence may never be more exposed than its spec. The unsafe case is concrete: under an encrypted workspace the prose is ciphertext in git precisely so it cannot be read, and a screenshot reveals exactly what that prose was hiding, so a plaintext PNG beside an encrypted spec breaks the invariant that the writer can never accidentally emit plaintext. That combination is refused at config load with a message naming both keys. The reverse, a local evidence store under an encrypted spec, is more private and is allowed.

serve gains GET /specs/{spec_id}/evidence/{name}/blob, inheriting the app-wide bearer like every other route so that scoped-token work re-scopes them together rather than leaving a divergent one behind. The name is pattern-matched strictly before the filesystem is touched, resolution is realpath-containment-checked against the spec's evidence directory, responses are size-capped and streamed with a content-type derived from the extension, and anything unresolvable returns 404 rather than confirming what exists. Addressing by hashed filename rather than by evidence index matters: indices shift when a spec is re-drafted, filenames do not, which removes a class of stale-link bug at no extra cost.

Ground Control needs no DTO change. A sibling helper to evidenceLabels returns a blob path for image-extension artifacts and null otherwise, used the way isUnverified and evidenceLabels already are. The spec detail criterion row renders the image full width, tap to zoom.

It renders there and deliberately not in the Queue. The Queue is the spec-approval surface, driven by specs in needs_review, and a spec passes through that state once — before dispatch. At Queue time the work has not been done, so no evidence exists to show; rendering images there would be interface for a state the lifecycle cannot produce. The decision made at the Queue swipe is whether these are the right criteria, not whether they were met. The second decision, where evidence is the entire point, happens after implementation: today in the pull request, which is why the PR body work below matters more than it first appears, and in-app it belongs to the Review-Merge cockpit rather than to this spec.

Two capture modes are kept deliberately distinct. Most captures are part of the develop, verify, iterate loop: the agent screenshots the running app, looks at what it built, adjusts, and captures again, many times over. Those are working artifacts. Bare mship capture is unchanged by this spec — it keeps writing to the existing ephemeral, gitignored location under .mothership/captures/, nothing is copied, and no evidence is attached. Only --evidence promotes a capture into the durable, spec-scoped, mode-governed store. That boundary is what keeps the git footprint proportional to the number of criteria being evidenced rather than to the number of iterations an agent needed to get the screen right.

Because the loop mode exists, a promoted capture must say what it was taken from. The evidence note records the revision the capture was made at, and marks the case where that revision is not a real commit — a dirty working tree, or a throwaway scratch ref of the kind exact-copy remote runs synthesize. This matters because the same command serves both modes and only the promoted one makes a durable claim: a screenshot taken from code that exists on no branch is still useful evidence, but a reviewer has to be able to see that is what it is. Ground Control surfaces that marker alongside the thumbnail, so a capture from in-flight work is visibly distinguishable from one taken at a committed revision.

The evidence also reaches the pull request. `build_acceptance_block` (`core/pr.py`) already renders each criterion with its evidence refs, so test and commit refs appear in the PR body today; an artifact ref is a bare filename and means nothing to a reader on GitHub. It is rendered as an embedded image instead.

The mechanism is constrained by something worth stating: GitHub has no public API for uploading an image attachment — the user-attachments CDN the web UI uses is session-authenticated and reachable from neither REST nor gh. An embedded image must therefore already live at a ref GitHub serves. So mship finish publishes the referenced artifacts to an **mship-evidence orphan branch** in the member repo the pull request targets, and the PR body embeds a raw URL pinned to that branch's commit.

An orphan branch is the right shape for three reasons. It shares no history with main, so binaries never enter the default branch's tree and a clone of the product is unaffected. raw.githubusercontent.com serves any ref, so the URL works without special hosting. And every workspace shape has a member repo with a remote, so the mechanism does not depend on a metarepo existing. finish pushes that branch alone — never main, never the workspace repo.

When a task spans several repos, each repo that receives a pull request publishes to its own orphan branch. That keeps every PR self-contained: a reviewer of one repo's PR needs no read access to a sibling, which would otherwise break the moment one member repo is private. The cost is duplicated bytes across repos, which content addressing makes cheap and screenshots make small.

Publication is verified, not assumed. Before emitting any URL, finish confirms the artifact is present at the pinned commit; anything unverified falls back to naming the artifact. A push that fails for any reason — no remote, rejected, offline, credentials uncached — warns and falls back, and never blocks the pull request from opening.

Embeddability remains a consequence of the storage mode rather than a new setting. `local` evidence is never published and `encrypted` evidence is ciphertext, so neither can be embedded; both fall back to naming the artifact, as does any artifact whose publication could not be verified.

Finally, the existing un-evidenced-criteria warning at a phase transition is extended to name capture as the remedy for repos that have a capture target. That reuses a pull mechanism that already fires rather than inventing one, and it stays a warning.

## Architecture

core/evidence_store.py is the single owner of artifact location. It exposes storing an artifact for a spec (hash, copy, return ref) and resolving a ref back to a readable path, and both the capture CLI and the serve blob route go through it. Nothing else computes an evidence path.

The ref is a bare filename by design. Because the resolver joins exactly one root — the spec's own evidence directory — a ref cannot express a location outside that directory at all. Validation still rejects malformed names and realpath-checks containment using the same shape as core/edit_guard.py, but the primary defence is that the data model has no way to say 'elsewhere'.

Addressing is by content hash rather than by evidence index. Evidence indices shift whenever a spec is re-drafted and criteria are renumbered, which is the same identity ambiguity tracked for acceptance criteria generally; a content-hashed filename is stable across that churn. This costs nothing to implement and removes a whole class of stale-link bug.

Mode handling reuses the spec storage writer rather than reimplementing it, so that the guarantee that an encrypted workspace never emits plaintext holds for artifacts by construction rather than by a parallel code path that has to be kept in step.

## Security

Three concerns, each addressed at a boundary.

Traversal: the blob route pattern-matches the requested name before touching the filesystem, resolves only within the spec's evidence directory, and realpath-checks containment so a symlink cannot escape. Unresolvable requests return 404 rather than 403 so the route never confirms what exists.

Exposure: evidence may never be more exposed than the spec it backs. The unsafe combination is an encrypted spec with committed evidence, because a screenshot discloses precisely what the ciphertext prose was written to protect. This is refused at config load with a message naming both keys, rather than silently clamped, so an operator cannot believe they configured something they did not.

Authorization: the blob route inherits the app-wide bearer like every other serve route. That bearer is currently broader than it should be — it grants approval, execution, and token minting together — but diverging here would create a second thing to fix rather than one, so scoping is left to the workspace-wide effort that will re-scope all routes together.

## Testing

evidence_store: round-trip store and resolve; rejection of relative traversal, absolute paths, symlinks escaping the store, and unrecognised extensions; content-hash naming produces identical refs for identical inputs.

Capture: --evidence attaches with kind=artifact and the expected ref; both an image and a layout from one run attach as separate evidences; a store failure warns and leaves the capture successful; --remote attaches from artifacts returned by a run host.

Config: each of the three evidence_storage values loads; an absent key inherits spec_storage; the exposure violation is refused with both key names in the message; per-mode tracking and encryption behave as specified.

serve: the blob route returns bytes and content-type for a valid name, 404 for each traversal shape, 401 without a bearer, and the key-unavailable condition for an undecryptable encrypted artifact.

Ground Control: the image-ref helper returns a path for image extensions and null otherwise, and the unverified and label helpers keep their existing behaviour for non-image kinds. JVM unit tests only, consistent with the workspace's no-emulator constraint.
