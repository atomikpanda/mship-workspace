---
id: fold-the-github-app-token-broker-into
title: Fold the GitHub App token broker into mship serve with per-repo installation
  resolution (multi-account cloud auth)
status: approved
created_at: '2026-07-12T00:25:59.649258Z'
updated_at: '2026-07-12T00:42:42.180977Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: With MSHIP_GH_APP_ID + MSHIP_GH_APP_KEY set on the serve host and NO installation
    id configured, `mship serve` GET /gh-token?repos=owner/repoA,owner/repoB returns
    a token scoped to exactly those repos, having resolved the installation from the
    repo owner.
  verdict: approved
- id: ac2
  text: Two workspaces under two different GitHub accounts each obtain a working push
    token from the same serve host and the same single GitHub App, with no per-workspace
    auth config difference.
  verdict: approved
- id: ac3
  text: When App creds are configured but the App is not installed on a requested
    repo's owner, GET /gh-token returns a clear error naming the repo/owner and does
    NOT fall back to `gh auth token`.
  verdict: approved
- id: ac4
  text: With no App creds configured, GET /gh-token still falls back to proxying `gh
    auth token` exactly as Broker A does today.
  verdict: approved
- id: ac5
  text: A /gh-token request whose repos resolve to more than one installation returns
    a hard error explaining that a workspace must be single-account.
  verdict: approved
- id: ac6
  text: The `mship relay gh-broker` command is removed and the Caddy `gh.{RELAY_DOMAIN}`
    route + its tls-ask entry are gone; setting MSHIP_GH_APP_INSTALLATION logs an
    'ignored' warning.
  verdict: approved
- id: ac7
  text: '`mship gh preflight` verifies per-repo coverage against the folded App-backed
    /gh-token (owner/repo) and fails fast naming any uncovered repo.'
  verdict: approved
- id: ac8
  text: "docs/cloud-agent-auth.md is rewritten to describe one broker (serve), App-backed\
    \ when creds are present, multi-account via one App installed per account/org\
    \ \u2014 with no installation id, separate process, or separate route."
  verdict: approved
open_questions: []
non_goals:
- A single mship workspace spanning repos in multiple accounts within one /gh-token
  request (would need a multi-token contract + per-remote credential routing). Each
  workspace stays single-account; a request whose repos resolve to more than one installation
  is a hard error.
- A client-side/local App-minting mode (routine holds the App key and mints without
  a broker). The mint+resolve logic is deliberately identity-store-agnostic so this
  is a cheap future add, but it is out of scope here.
- Changing Broker A's daytime behavior (still proxies `gh auth token` when no App
  creds are set).
- New GitHub App permissions (still only Contents RW + Pull requests RW).
- Any change to token precedence or the in-memory git credential handoff.
risks:
- "Folding token minting into `mship serve` means the same bearer (MSHIP_SERVE_TOKEN)\
  \ that mints gh-tokens can also hit the full serve API. Accepted: the cloud container\
  \ already holds MSHIP_SERVE_TOKEN to run bootstrap/run-next, so it gains no privilege.\
  \ The old separate route only mattered for handing gh-tokens to something that must\
  \ NOT have serve access \u2014 not a supported scenario here."
- 'The App private key lives on the serve host. Mitigated as today: read from a gitignored
  path, never logged or returned, never sent to the cloud box (which only ever receives
  short-lived scoped tokens).'
- Removing `mship relay gh-broker` and the Caddy gh. route is a breaking change for
  any existing Broker B deployment. Pre-1.0, so surfaced via a startup warning + PR/CHANGELOG
  note; MSHIP_GH_APP_INSTALLATION becomes ignored (warns if set).
- Extra GitHub API round-trip per token request to resolve the installation. Mitigated
  by caching the installation id per owner for the serve process lifetime (a workspace
  is single-account, so effectively one lookup).
task_slug: null
work_item_id: null
---
## Problem

Cloud/unattended agent auth today has two separate brokers. Broker A (mship serve's GET /gh-token) proxies the serve host's `gh auth token` — zero setup but single-identity and only while that host is awake. Broker B (the standalone `mship relay gh-broker`) mints GitHub App installation tokens so unattended runs work, but its setup is heavy and confusing: create the App, install it, download the .pem, hardcode MSHIP_GH_APP_INSTALLATION, run a separate process, and add a separate Caddy `gh.{RELAY_DOMAIN}` route. Worse, Broker B is wired to a single hardcoded installation id, and a GitHub App installs per account/org — so one broker only ever covers one account. An operator with repos spread across several GitHub accounts/orgs they own has no clean path: they'd need one broker per account.

## User story

As an operator running mship cloud/unattended agents across repos in several GitHub accounts/orgs I own, I want one small, well-understood auth setup, so that any workspace's agent can push and open PRs without per-account brokers, a hardcoded installation id, or a separate broker process to babysit.

## Approach

Two moves. (1) Per-repo installation resolution: a GitHub App JWT needs only app_id + private_key; the installation id is required only in the final mint URL, and `GET /repos/{owner}/{repo}/installation` resolves the installation for any repo the App is installed on. So drop MSHIP_GH_APP_INSTALLATION entirely and resolve the installation per request from the repo owner — this removes a setup step AND transparently spans every account/org the App is installed on. (2) Fold Broker B into `mship serve`: collapse the two brokers into one endpoint, `mship serve` GET /gh-token. Per request it runs an if/elif ladder — if App creds (app_id + app_key) are configured on the serve host, mint an App installation token scoped to the requested repos (auto-resolving the installation); elif the serve host has a `gh auth token`, proxy it (today's Broker A, unchanged); else return an unauthenticated error. The standalone `mship relay gh-broker` command, the Caddy `gh.{RELAY_DOMAIN}` route, and its tls-ask entry are removed. Cloud sessions keep pointing MSHIP_GH_BROKER_URL at the serve URL (via the relay) they already use plus MSHIP_SERVE_TOKEN — no other secrets in the cloud box. The client (mship.core.gh_auth.resolve_token) sends full owner/repo names in the ?repos= query (owner derived from each repo's mothership.yaml url/default_remote) so serve can resolve the installation; token precedence is unchanged (--token > GH_TOKEN > GITHUB_TOKEN > broker pull). Identity is never silently swapped: if App creds ARE configured but the App is not installed on a requested repo's owner, serve returns a hard error naming the repo (install the App on {owner}) rather than falling through to `gh auth token`.

## Setup after this change

Setup shrinks from a separate process + separate web route + three App env vars to: create the GitHub App (set 'where can this app be installed' to any account) → install it on each account/org you own → drop the .pem on the serve host (gitignored path) → set MSHIP_GH_APP_ID + MSHIP_GH_APP_KEY → run `mship serve --relay`. No installation id, no separate broker process, no separate Caddy route. Cloud sessions/routines still hold only MSHIP_GH_BROKER_URL (the serve/relay URL) + MSHIP_SERVE_TOKEN. `mship gh preflight` confirms the App covers every repo before scheduling an unattended run.

## Architecture

One endpoint: `mship serve` GET /gh-token (bearer-auth'd, same contract as today — returns {token, expires_at, repositories}). Backend selection is per-request and decided ONLY by whether App creds are configured. Installation coverage is NOT part of the branch condition: a configured App that isn't installed on the repo is a hard error inside the App branch, never a fall-through to gh-auth-token.

  if app creds configured:
      installation_id = resolve_installation(app_id, key, owner, repo)   # GET /repos/{owner}/{repo}/installation via App JWT, cached per owner; raises a clear error naming owner/repo if the App isn't installed — NO fallback
      return mint_installation_token(app_id, key, installation_id, repos)  # existing gh_app.py
  elif serve host has `gh auth token`:
      return proxy_gh_auth_token()   # Broker A, unchanged
  else:
      401/404 no auth

New helper (mship.core.gh_app): resolve_installation(...) alongside the existing mint_installation_token(...). serve wires the two together. The standalone gh-broker impl in cli/relay.py and its serve-token/Caddy plumbing are deleted.

## Client changes

mship.core.gh_auth.resolve_token builds ?repos= from full owner/repo names. The owner is derived from each repo's mothership.yaml `url` (or `default_remote` when the url is a bare name). The `gh auth token` fallback path ignores owner/repo (returns the user token), so mixed old/new servers stay compatible. No change to token precedence (--token > GH_TOKEN > GITHUB_TOKEN > broker) or the in-memory git credential helper.

## Security

The powerful, long-lived secret (App private key) stays on the always-on serve host and is never sent to the ephemeral cloud box, which only ever receives ~1h repo-scoped tokens. The key is read from a gitignored path and never logged/returned. Folding minting into serve does not widen the cloud box's privilege: it already holds MSHIP_SERVE_TOKEN. Refusing to mint an unscoped token (repos must be non-empty) is preserved. No silent identity fallback: App-configured-but-not-installed is an error, so a push is always unambiguously the App.

## Testing

Unit: resolve_installation (mock GET /repos/{owner}/{repo}/installation for user- and org-owned repos; 404 -> clear error); mint after resolution with no configured installation id; the if/elif backend selection (App present vs absent); error when App configured but repo uncovered (no fallback); error when repos span >1 installation; owner derivation from url/default_remote. serve: GET /gh-token App path vs gh-auth-token path, bearer enforcement, scoping to requested repos. preflight against the folded endpoint. Regression: Broker A behavior unchanged when no App creds.

## Migration

Pre-1.0, so no compat shim beyond warnings. MSHIP_GH_APP_INSTALLATION is ignored and logs a one-line 'ignored — installation is now auto-resolved' warning if set. `mship relay gh-broker` is removed (invoking it errors with a pointer to `mship serve` + App creds). Relay operators drop the Caddy `gh.{RELAY_DOMAIN}` block and its tls-ask entry; if left in place it simply 404s. Documented in the PR body and the rewritten docs/cloud-agent-auth.md.
