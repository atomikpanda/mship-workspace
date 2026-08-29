---
id: spec-storage-visibility-policy
title: 'Spec storage & visibility policy: committed / local / encrypted specs'
status: implemented
created_at: '2026-07-22T16:39:30.137402Z'
updated_at: '2026-07-22T19:03:42.122100Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: '[ac1] A per-workspace `spec_storage` policy in mothership.yaml takes `committed`
    | `local` | `encrypted`, defaulting to `committed` so existing workspaces are
    unchanged; an invalid value fails loud at config load.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: null
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: commit
    ref: 9b5f81b8fa2cdcee27788ab54c01a32597500ea7
    note: null
  - kind: artifact
    ref: PR; spec_storage config field, default committed, invalid fails at load (test_config_spec_storage.py)
    note: null
  comment: null
- id: ac2
  text: "[ac2] All `mship spec` reads/writes (new/draft/apply/show/review/list) go\
    \ through a spec-storage layer that applies the mode transparently \u2014 the\
    \ command UX is identical across modes; only the on-disk representation differs."
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: null
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: commit
    ref: e1aee96004061ee2c9da2194d66697355315943c
    note: null
  - kind: artifact
    ref: PR; all mship spec verbs via _spec_store()/SpecStorage layer (test_spec_storage_cli.py)
    note: null
  comment: null
- id: ac3
  text: '[ac3] `local` mode writes specs/<id>.md plaintext AND ensures it is git-ignored
    (never committed/pushed), while remaining fully readable/usable locally; a spec
    created under local mode does not appear in `git status` as a tracked/committable
    file.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: null
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: commit
    ref: 44af768cc08a20f3b3c58b036b5793ee9d2e59ff
    note: null
  - kind: artifact
    ref: PR; local = plaintext + gitignored + untracked (test_spec_storage.py)
    note: null
  comment: null
- id: ac4
  text: '[ac4] `encrypted` mode persists the spec as ciphertext committed to the repo;
    a reader without the key sees only ciphertext on disk / in the repo, while `mship
    spec show` (with the key) decrypts and renders the normal spec; the plaintext
    is never written to the committed path.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: null
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: commit
    ref: 44af768cc08a20f3b3c58b036b5793ee9d2e59ff
    note: null
  - kind: artifact
    ref: PR; encrypted = ciphertext committed, no plaintext path, show decrypts (test_spec_storage.py;
      runtime-verified)
    note: null
  comment: null
- id: ac5
  text: "[ac5] The key is a single per-workspace Fernet key at `.mothership/spec-key`\
    \ (git-ignored), generated on first encrypted write with a loud 'back this up\
    \ \u2014 losing it loses your encrypted specs' notice; encrypted mode with no\
    \ key present FAILS LOUD rather than writing plaintext."
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: null
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: commit
    ref: 874d6ff3bb0e02e0aad67f8173c629218b2d25f8
    note: null
  - kind: artifact
    ref: PR; Fernet key .mothership/spec-key gitignored + loud gen notice + fail-loud
      no-key (test_spec_key.py)
    note: null
  comment: null
- id: ac6
  text: '[ac6] Switching `spec_storage` between modes migrates existing specs into
    the new representation (committed<->local<->encrypted) via an explicit `mship
    spec` migrate step, removing the old representation (e.g. git rm the plaintext
    when moving to local/encrypted) so no spec is left readable in a mode that should
    hide it.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: null
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: commit
    ref: a5ce5b0c0f06e4cf77dde4115e75325b3aee14bf
    note: null
  - kind: artifact
    ref: PR; migrate-storage re-materializes + git-removes old repr (test_spec_migrate_storage.py)
    note: null
  comment: null
- id: ac7
  text: '[ac7] serve/Ground Control display specs under `encrypted` mode by decrypting
    with the local key; when serve lacks the key it surfaces a clear LOCKED state
    (not ciphertext, not an error).'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: null
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: commit
    ref: 81276d0ffb42839bea0d3a81860b5122b94ef0ab
    note: null
  - kind: artifact
    ref: PR; serve decrypts + LOCKED marker without key (test_serve_spec_locked.py)
    note: null
  comment: null
- id: ac8
  text: '[ac8] Tested end-to-end: round-trip encrypt/decrypt through the storage layer;
    an encrypted-mode write leaves ciphertext (assert the plaintext string is absent
    from the committed file); a no-key holder cannot read an encrypted spec; local
    specs are gitignored + untracked; default mode is committed; each mode-migration
    transition; and fail-loud on encrypted-without-key.'
  verdict: unreviewed
  evidence:
  - kind: test
    ref: test-runs/1.ground-control
    note: null
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: artifact
    ref: PR; security battery + writer-funnel guard + source-scan (test_spec_storage.py)
    note: null
  comment: null
open_questions: []
non_goals:
- "Per-spec or per-recipient keys (the age/recipients option) \u2014 v1 is one per-workspace\
  \ symmetric key; recipients can be a later upgrade."
- "Encrypting artifacts other than specs (implementation plans, journal, code) \u2014\
  \ v1 covers specs; plans are an obvious follow-up but out of scope here."
- "Automated key rotation / escrow \u2014 rotation is 'generate a new key + re-encrypt'\
  \ (documented); no automated rotation or recovery in v1. Losing the key means losing\
  \ encrypted specs (stated plainly)."
- "The cloud-worker DELIVERY mechanics (how a routine gets + decrypts a spec) \u2014\
  \ that is the worker-boot skill; this spec provides the storage + transparent crypto\
  \ that delivery builds on."
- "Encrypting the SPEC on the mship-run-state orphan branch specifically \u2014 v1's\
  \ encrypted mode keeps the encrypted spec IN the repo (committed ciphertext); an\
  \ orphan-branch home for uncommitted/local-spec delivery is a separate worker-boot\
  \ concern."
- "Letting Ground Control AUTHOR encrypted specs (GC has no key) \u2014 GC reads/displays\
  \ (serve decrypts); authoring stays where the key is."
risks:
- "Losing .mothership/spec-key makes every encrypted spec unrecoverable \u2014 there\
  \ is no escrow. Mitigation: state it loudly in docs + the command output when a\
  \ key is first generated; the keyfile is the single thing to back up."
- 'A partial/buggy storage layer could write a spec PLAINTEXT under encrypted mode
  (the exact leak the feature prevents). Mitigation: fail loud when encrypted mode
  has no key (never silently fall back to plaintext); a test asserts an encrypted-mode
  write produces ciphertext on disk (the plaintext must not appear).'
- 'Mode switching that mis-migrates could leave a spec in the wrong representation
  (a plaintext spec left committed after switching to local/encrypted = a leak). Mitigation:
  the migrate step is explicit + tested per transition; switching to local/encrypted
  removes the plaintext committed copy (git rm) as part of migration.'
- "serve/GC decrypting specs sends plaintext over the serve channel \u2014 acceptable\
  \ because that channel is the operator's own trusted device (relay/tailnet), the\
  \ same trust boundary that already carries approve/exec; but a LOCKED state must\
  \ be shown (not ciphertext, not a crash) when serve lacks the key."
- Adding `cryptography` as a direct dep enlarges the install; it is already present
  transitively + widely used, so low risk, but it is a real new pinned dependency.
task_slug: null
work_item_id: null
clarification_reason: null
prose_verdicts: {}
---
## Problem

mship specs are always plaintext markdown files committed to the workspace repo (specs/<id>.md). That's ideal for a team that wants the design record public — but wrong for others: an open-source repo then exposes every spec's problem statement, approach, and acceptance criteria to anyone who can read the repo, and some operators consider a committed spec a leak of design intent. There is currently no way to keep specs private (unreadable by a repo-reader) while still using mship's spec workflow. The choice is also load-bearing for the overnight cloud-worker flow: how a spec is stored determines how it reaches a disposable worker (clone plaintext, be delivered out-of-band, or clone-and-decrypt). So mship needs a per-workspace policy for where specs live and who can read them.

## User story

As an operator whose repo is open-source (or private-by-preference), I want to choose how my mship specs are stored — committed for documentation, kept-local-and-uncommitted, or encrypted-in-the-repo — so that I can use mship's normal spec workflow without leaking my design intent to anyone who can read the repo, while still handing specs to my own agents and cloud workers.

## Approach

A per-workspace `spec_storage` policy in mothership.yaml with three modes, applied TRANSPARENTLY through the spec store so authoring/review/apply/show are identical from the user's side — only how the file is persisted differs:

1. `committed` (default — today's behaviour): specs/<id>.md plaintext, committed + pushed. Public design record.
2. `local`: specs/<id>.md plaintext but git-IGNORED — present + fully usable on the operator's machine, never committed/pushed. Kept for you, absent from the repo/public.
3. `encrypted`: the spec is persisted as CIPHERTEXT and committed to the repo (e.g. specs/<id>.md.enc). It IS in the repo — so it round-trips through clone/pull like any file — but a repo-reader without the key sees only ciphertext. This directly serves the open-source-privacy case AND the cloud-worker case: a worker holding the key clones the repo and decrypts its spec.

All `mship spec` reads/writes (new/draft/apply/show/review/list) go through a spec-storage layer that reads the mode from config and applies it: under `encrypted` it encrypts on write and decrypts on read; under `local` it writes plaintext + ensures the path is gitignored; under `committed` it is exactly today's path. The KEY (operator decision A) is a single per-workspace symmetric key in a git-ignored keyfile `.mothership/spec-key` (a Fernet key), generated on first encrypted write; the operator holds it and injects it into agents/workers the same way the run token is injected (so a cloud worker with the key decrypts specs after cloning). Crypto is Fernet (authenticated symmetric encryption) from `cryptography`, added as an explicit dependency (it is only transitive today). Serve/Ground Control read specs too: under `encrypted`, serve decrypts for display to the operator's (trusted) GC given the local key, and surfaces a clear LOCKED state — never ciphertext, never an error — when the key is absent. Switching modes re-materializes existing specs into the new representation.

## Architecture

A spec-storage layer in core (extend core/spec_store.py or a new core/spec/storage.py): `SpecStorage.read(id)` / `.write(id, text)` resolve the workspace `spec_storage` mode from config and apply it. committed -> today's plaintext path. local -> plaintext write + a gitignore-ensure helper (add specs/<id>.md, or specs/*.md, to the workspace .gitignore). encrypted -> Fernet encrypt on write to specs/<id>.md.enc + decrypt on read. A small key module (core/spec_key.py): load-or-generate `.mothership/spec-key` (32-byte urlsafe Fernet key), gitignore it, loud first-generation notice; a `require_key()` that raises (fail loud) when encrypted mode has no key. All `mship spec` verbs + serve's spec read (core/view/spec_discovery.py / serve /specs) call through the layer. Migration: `mship spec` gains a mode-migrate path (re-materialize every spec into the target mode, git rm the old representation). `cryptography` added to pyproject as a direct dependency. Threat model: privacy is against REPO-readers (public GitHub), NOT the operator's own trusted GC/serve; the key never leaves the operator's control except when the operator injects it into a worker they launched.

## Testing

Pure/unit: the storage layer per mode — committed read/write is byte-identical to today; local write is plaintext + the path is gitignored (assert the gitignore entry + that it's untracked); encrypted write produces ciphertext (assert the plaintext markdown string does NOT appear in the on-disk file) and read with the key round-trips to the original; a read WITHOUT the key fails/does-not-return-plaintext. Key module: load-or-generate creates a gitignored keyfile; require_key raises when absent under encrypted mode. Config: default is committed; an invalid spec_storage value fails at load. Migration: committed->local (plaintext moves out of git), committed->encrypted (plaintext git-removed, ciphertext committed), and back, each leaving exactly one correct representation. serve/GC: with the key, /specs returns decrypted content; without it, a LOCKED marker (no ciphertext leak, no crash). No network; Fernet runs locally; the keyfile lives under tmp_path in tests.
