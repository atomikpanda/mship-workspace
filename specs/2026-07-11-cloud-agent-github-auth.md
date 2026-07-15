---
id: cloud-agent-github-auth
title: "Cloud-agent GitHub auth: runtime token broker (serve-host proxy + relay GitHub\
  \ App) \u2014 MOS-226"
status: implemented
created_at: '2026-07-11T00:00:40.406944Z'
updated_at: '2026-07-11T02:03:46.647123Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: "resolve_token (core/gh_auth.py) gains a runtime broker-pull as a new LOWEST-precedence\
    \ source: precedence becomes --token > GH_TOKEN > GITHUB_TOKEN > broker. When\
    \ no higher source yields a token AND a broker is configured (broker base URL\
    \ + a bearer credential), it fetches GET {broker}/gh-token (passing the repo set\
    \ it needs \u2014 see ac10) with Authorization: Bearer {credential} and returns\
    \ the token. A broker error / timeout / missing config falls through to None (never\
    \ raises), and is logged."
  verdict: approved
- id: ac2
  text: 'Broker A (serve-host proxy): mship serve exposes an authenticated GET /gh-token
    that returns a fresh token by shelling `gh auth token` on the host (via ShellRunner).
    It inherits serve''s existing bearer-auth dependency (no separate auth), and returns
    a clear error (e.g. 503) when gh is absent/unauthenticated rather than a 200 with
    an empty token.'
  verdict: approved
- id: ac3
  text: 'Broker B (relay + GitHub App): a standalone broker service (new module under
    core/relay/, sibling to enroll_app.py, launched by a new `mship relay gh-broker`
    uvicorn command mirroring enroll-server) exposes the SAME authenticated GET /gh-token,
    minting short-lived (~1h) GitHub App installation tokens scoped to the requested
    repo set (see ac10) by signing a JWT from the App id + private key then POST /app/installations/{id}/access_tokens.
    It answers independently of the serve host, so it works while the operator''s
    laptop is asleep.'
  verdict: approved
- id: ac4
  text: 'Relay broker ingress: a new hardened Caddy route in docker/relay/Caddyfile
    (e.g. gh.{domain} -> the broker''s loopback port, method/path allowlist like the
    enroll route) fronts Broker B. The App id + private key are read from the relay''s
    env/secret (docker/relay/.env or keys/, already gitignored) and never leave the
    relay.'
  verdict: approved
- id: ac5
  text: "Both brokers present the IDENTICAL GET /gh-token contract \u2014 bearer-auth'd,\
    \ taking the repo set (see ac10), returning a JSON body with at least {token}\
    \ (plus expires_at when known) \u2014 so resolve_token's single broker-pull works\
    \ against either. The cloud agent selects which broker by its configured broker\
    \ URL (relay for overnight/laptop-independent, serve host for at-machine)."
  verdict: approved
- id: ac6
  text: 'Pluggable, no single point of failure: --token and GH_TOKEN/GITHUB_TOKEN
    remain higher-precedence overrides; a broker that is unconfigured or down falls
    through to those. Broker A works with NO GitHub App at all; the App is only required
    for Broker B.'
  verdict: approved
- id: ac7
  text: 'Audit + scoping: every token mint is logged with a timestamp, requester context,
    and the repo set granted, but NEVER the token value; the GET /gh-token endpoints
    are reachable only with the serve/relay bearer credential; the GitHub App private
    key stays on the relay and is never returned or logged.'
  verdict: approved
- id: ac8
  text: 'Config + docs: the broker base URL and the bearer credential are read from
    env / mothership.yaml by the cloud agent; a fresh cloud container is documented
    to set the serve token + broker URL once-per-environment (no PAT in the routine/prompt/logs)
    and then bootstrap/finish auth automatically.'
  verdict: approved
- id: ac9
  text: The token value is never written to argv or disk (reuse the existing git_cred_args
    env-only helper); everything downstream of resolve_token (git_cred_args, create_pr_via_httpx)
    is unchanged since it is source-agnostic. Any new dependency (JWT signing for
    the App) is added to pyproject; all new/changed code is covered by tests and the
    suite passes via mship test.
  verdict: approved
- id: ac10
  text: "MULTI-REPO SCOPING (mship tasks are routinely cross-repo \u2014 bootstrap\
    \ clones every workspace repo, finish pushes+PRs to every affected repo). A single\
    \ pulled token must authorize the FULL repo set, not one repo. resolve_token passes\
    \ the repo set to the broker (default: all repos in the workspace's mothership.yaml;\
    \ the caller may narrow it). Broker B requests an installation token with `repositories:\
    \ [...]` covering that set; the App must be installed on each, and a repo the\
    \ App can't cover fails the mint with a clear error naming the uncovered repo\
    \ (so the operator knows to install the App there). Broker A's host `gh auth token`\
    \ already spans the user's repos. Net: one pulled token authorizes a cross-repo\
    \ bootstrap + finish."
  verdict: approved
open_questions:
- id: q1
  text: "Broker B credential \u2014 full GitHub App (short-lived, multi-repo-scoped\
    \ installation tokens; needs creating+installing the App on all workspace repos\
    \ and placing its private key on the relay, plus a JWT-signing dep) vs an interim\
    \ relay-held fine-grained short-TTL PAT (simpler, no App setup, but longer-lived/broader).\
    \ The spec assumes the GitHub App for B (its whole value is scoped+expiring tokens,\
    \ and installation tokens give clean multi-repo scoping); confirm, or start B\
    \ on the interim PAT and add the App as a fast-follow."
  answer: 'confirm. it would be good if we could fail fast or have some sort of dry
    run on the token minting to avoid scheduling a task overnight and not having the
    gh app installed on one of the repos. or worse spending ai tokens on code and
    failing to push results '
- id: q2
  text: "OIDC / workload-identity: if the cloud platform (Claude cloud routines) issues\
    \ a per-run OIDC token, the broker could verify it and mint per-run with NO durable\
    \ secret at all \u2014 the ideal. Deferred unless the platform supports it; confirm\
    \ whether it does so we know whether to design for it now."
  answer: You can implement Workload Identity Federation (WIF), which allows your
    cloud workloads and CI/CD pipelines to securely authenticate with the Claude API
    using OpenID Connect (OIDC) tokens instead of long-lived, static API keys.
- id: q3
  text: 'State visibility (separate concern, flagged not owned here): does an unattended
    run''s .mothership WorkItem/journal state sync back to the operator''s workspace,
    or does only the PR make it home? Confirm this is tracked as its own issue rather
    than folded into MOS-226.'
  answer: it is tracked to its own issue
non_goals:
- 'The live mailbox / attended steering: an unattended run parks a needs-decision
  WorkItem (async attention marker in GC''s Home queue) rather than blocking on mship
  ask/inbox wait. Auth is the ONLY always-on requirement; outcomes are the PR + WorkItem/journal
  state.'
- "State/journal sync-back from an unattended run (its own concern \u2014 see q3)."
- 'SSH-key provisioning: the token path is HTTPS-only, per the cloud-auth spec; git@
  remotes keep relying on keys.'
- 'Persistent/global git credential configuration: the credential helper stays per-invocation
  only (per cloud-auth), never written to the user''s gitconfig.'
risks:
- The GitHub App private key on the relay is a high-value secret. Mitigated by gitignore
  (docker/relay/keys/, .env already ignored), env/secret storage, audit logging of
  every mint, and rotation by replacing the key.
- GET /gh-token is a token-minting surface. Mitigated by bearer-auth scoping to the
  serve/relay credential, short-TTL minted tokens narrowed to the requested repo set,
  a Caddy method/path allowlist for Broker B, and mint auditing.
- Multi-repo scoping depends on the App being installed on every workspace repo. Mitigated
  by failing the mint with a clear error naming the uncovered repo (not a silent partial
  token), and by Broker A (host gh token) covering all the user's repos as the no-App
  fallback.
- resolve_token gaining network I/O (the broker fetch) could hang bootstrap/finish.
  Mitigated by a short timeout on the broker call and fall-through to None (then the
  existing fallbacks) on any error.
- GitHub App integration is greenfield (no existing App/JWT code) and adds a signing
  dependency. Mitigated by isolating it in the relay broker module and keeping Broker
  A (no-App, gh auth proxy) as a working fallback path.
task_slug: cloud-agent-github-auth
work_item_id: wi-20260711003102-de2b2f53
---
## Problem

Starting a cloud agent / Claude routine that runs `mship bootstrap` requires a GitHub token in a fresh environment. Today that means **pasting a PAT into the routine's prompt/config** — which leaks it (stored in the routine, logs, agent context) and is long-lived + broadly scoped. The merged cloud-auth work (MOS-187) solved token **usage** — a precedence resolver (`resolve_token`), a per-invocation git credential helper that keeps the token off argv/disk (`git_cred_args`), and a `gh`-independent REST PR path (`create_pr_via_httpx`) — but it explicitly punted **provisioning** ("Token storage, caching, or refresh" is a stated non-goal). This spec is the provisioning half: the cloud agent should **pull a fresh token at runtime**, authenticating with a credential the environment already holds, so nothing long-lived lives in the routine.

Per the operator's decision, v1 builds **both** broker homes behind `resolve_token`: **A** (serve-host proxy) for the zero-setup at-machine path, and **B** (relay + GitHub App) for laptop-independent overnight runs — coexisting as a fallback chain so there's no single point of failure. And because **mship tasks are routinely cross-repo**, a pulled token must authorize the whole repo set, not one repo (see §5).

## User story

As an unattended cloud agent (and the operator who fires it), I want the agent to fetch a fresh, short-lived GitHub token from a broker at run start — using only a credential already injected into its environment (the mship serve bearer token), and scoped to every repo the workspace/task touches — so it can `bootstrap` (clone all repos) and `finish` (push + PR to every affected repo) without any PAT in its prompt, config, or logs, and without the operator's laptop necessarily being awake.

## Approach

The whole cloud-auth design already funnels through one seam: `resolve_token(explicit)` in `core/gh_auth.py`, precedence `--token > GH_TOKEN > GITHUB_TOKEN`. Everything downstream is source-agnostic — `git_cred_args` puts the token in an env-only credential helper, and `create_pr_via_httpx` posts the PR over REST with `Authorization: Bearer <token>`. So the broker only has to **produce a token** (scoped to the right repos); nothing else changes.

### 1. Extend `resolve_token` with a runtime broker-pull

Add a new **lowest-precedence** source: `--token > GH_TOKEN > GITHUB_TOKEN > broker`. When no higher source yields a token and a broker is configured (a base URL + a bearer credential, read from env / `mothership.yaml`), fetch `GET {broker}/gh-token` with `Authorization: Bearer {credential}` (via httpx, short timeout), passing the repo set it needs (§5), and return the token. Any error / timeout / missing config falls through to `None` (never raises) and is logged — so bootstrap/finish degrade to the existing behavior, not a crash. This keeps the two existing call sites (`bootstrap.py:105`, `cli/worktree.py:1148`) unchanged beyond passing through the broker config + repo set.

The credential the cloud agent "already holds" is the **mship serve bearer token** (`MSHIP_SERVE_TOKEN`) — it needs that anyway to reach the workspace API through the relay. The broker exchanges that workspace-scoped credential for a short-lived GitHub token; no GitHub PAT is ever in the environment.

### 2. Broker A — serve-host proxy (zero-setup)

Add an authenticated `GET /gh-token` closure inside `create_app` in `core/serve.py`. It inherits serve's app-wide bearer dependency automatically (`_make_auth_dependency`). It shells `gh auth token` on the host (via `ShellRunner`, the same path `PRManager` uses for `gh`) and returns `{token, expires_at?}`. If `gh` is absent/unauthenticated it returns a clear error (503), not an empty 200. No GitHub App needed — it reuses the host's existing `gh auth`, whose token already spans the user's repos (so multi-repo is inherent for A). Works whenever the serve host is reachable (laptop awake), through the relay tunnel or directly.

### 3. Broker B — relay broker + GitHub App (overnight, laptop-independent)

The relay is pure transport today (sish + Caddy + the loopback enroll-server on `127.0.0.1:47180`); it holds no GitHub credential. Broker B adds a small standalone service co-located there so cloud runs get a token **even when the laptop is asleep**:

- A new FastAPI module under `core/relay/` (sibling to `enroll_app.py`) exposing the same authenticated `GET /gh-token`, launched by a new `mship relay gh-broker` uvicorn command in `cli/relay.py` (mirroring `enroll-server`), bound to a new loopback port.
- It mints **short-lived (~1h) GitHub App installation tokens scoped to the requested repo set** (§5): sign a JWT from the App id + private key, then `POST /app/installations/{id}/access_tokens` with `repositories: [...]` (httpx). This needs a JWT-signing dependency (PyJWT/cryptography) added to `pyproject`.
- A new hardened Caddy route in `docker/relay/Caddyfile` (e.g. `gh.{domain}` → the broker's loopback port, with a method/path allowlist like the `enroll.{domain}` block) provides the public, TLS-terminated ingress.
- The App id + private key are read from the relay's env/secret (`docker/relay/.env` / `keys/`, already gitignored) and never leave the relay.

### 4. Coexistence, config, audit

Both brokers present the identical `GET /gh-token` contract, so `resolve_token`'s single broker-pull works against either — the cloud agent just points its broker URL at the relay (overnight) or the serve host (at-machine), with `--token`/`GH_TOKEN` still available as higher-precedence overrides and a working fallback if a broker is down. Every mint is logged (timestamp + requester + repo set granted, never the token). The endpoints are reachable only with the serve/relay bearer credential; the App key stays on the relay.

### 5. Multi-repo scoping (the crux — mship tasks are cross-repo)

A mship workspace/task routinely spans **several repos**: `mship bootstrap` clones *every* repo in `mothership.yaml`; `mship finish` pushes and opens PRs across *every* affected repo. So a single pulled token must authorize the **whole repo set**, not one repo.

- **The caller supplies the set.** `resolve_token`'s broker-pull passes the repo set to the endpoint (e.g. `GET /gh-token?repos=owner/r1,owner/r2`), defaulting to **all repos in the workspace's `mothership.yaml`** (the agent knows these at bootstrap from the config it's materializing, and at finish from the task's affected repos). The caller may narrow it.
- **Broker B (App):** requests the installation token with `repositories: [<that set>]` — a least-privilege token limited to exactly those repos. The App must be **installed on each**; if a requested repo isn't covered by the installation, the mint **fails with a clear error naming the uncovered repo** (never a silent partial token), so the operator knows to install the App there.
- **Broker A (host gh token):** already spans the user's repos, so the full set is covered inherently; A echoes the granted scope for parity.

Net: one runtime token pull yields a token that authorizes a cross-repo bootstrap (clone all) and a cross-repo finish (push + PR to every affected repo).

No behavior change downstream: `git_cred_args` and `create_pr_via_httpx` are untouched. Gated on `mship test`; the only new dependency is the JWT signer for Broker B.
