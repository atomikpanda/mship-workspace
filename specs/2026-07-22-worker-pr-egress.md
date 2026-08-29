---
id: worker-pr-egress
title: 'Worker PR egress: api.github.com relay route with a PR-creation-only enforcer'
status: implemented
created_at: '2026-07-22T10:09:04.432538Z'
updated_at: '2026-07-22T13:16:37.276646Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: '[ac1] api.github.com is re-added to build_default_routes with the github-app
    provider + a new GitHubApiEnforcer; a worker REST call for a run repo routes through
    the relay and gets the App token attached host-locked (same as the git leg). With
    the route present, an /api/ request no longer 404s as an unknown host.'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: artifact
    ref: 'PR #401; api.github.com route re-added + GitHubApiEnforcer (test_routes.py,
      test_proxy.py)'
    note: null
  comment: null
- id: ac2
  text: '[ac2] An api-path repo extractor pulls owner/repo from /repos/{owner}/{repo}/...
    so the enforcer can scope-check; non-repo API paths (e.g. /user, /rate_limit)
    are recognized as repo-less rather than mis-parsed.'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: artifact
    ref: api-path repo extractor _extract_api_repo (test_request.py)
    note: null
  comment: null
- id: ac3
  text: "[ac3] GitHubApiEnforcer is DEFAULT-DENY: it permits ONLY the allowlist \u2014\
    \ POST /repos/{o}/{r}/pulls, PATCH /repos/{o}/{r}/pulls/{n} (not merge), POST\
    \ /repos/{o}/{r}/issues/{n}/comments, PR review endpoints (reviews / requested_reviewers),\
    \ and GET reads on the run's repos plus safe globals (/rate_limit, /user) \u2014\
    \ and refuses (403) every other method+path."
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: artifact
    ref: default-deny classify_api_request allowlist, 403 else (test_enforce.py; runtime-verified)
    note: null
  comment: null
- id: ac4
  text: '[ac4] It explicitly refuses the dangerous mutations (named + tested), so
    the API leg cannot sidestep the git push-to-run-branch enforcement: PUT /repos/{o}/{r}/pulls/{n}/merge
    (merge a PR), POST /repos/{o}/{r}/merges, POST/PATCH/DELETE /repos/{o}/{r}/git/refs/*,
    and PUT/DELETE /repos/{o}/{r}/contents/*.'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: artifact
    ref: merge/merges/git-refs/contents denied, named+tested (test_enforce.py; runtime-verified)
    note: null
  comment: null
- id: ac5
  text: '[ac5] Every permitted repo-scoped call requires the path''s owner/repo to
    be within the run''s scope.repos; a call for a repo outside the run is refused
    (403), matching the git leg''s containment.'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: artifact
    ref: owner/repo in scope.repos required, out-of-scope 403 (test_enforce.py, test_proxy.py)
    note: null
  comment: null
- id: ac6
  text: '[ac6] The route + enforcer are unit-tested hard: permit each allowlisted
    call; deny merge, merges, git/refs mutation, contents mutation, an out-of-scope
    repo, and an unknown method/path; and the proxy still fails CLOSED on the api
    leg (App creds absent -> 503, never forward).'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: artifact
    ref: 25-case matrix + 5 scope + 4 proxy tests; fail-closed 503 (test_proxy.py)
    note: null
  comment: null
- id: ac7
  text: '[ac7] The api leg needs NO new deployment surface: it rides the existing
    egress subdomain + Caddy block + tls_ask entry via path-prefix routing (/api/
    alongside /gh/); this is verified/documented, and the worker reaches it with the
    same relay config plus a git/API base pointing at the /api/ prefix.'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: artifact
    ref: path-prefix /api/ on existing egress host, no new deploy surface (docs)
    note: null
  comment: null
- id: ac8
  text: "[ac8] Docs updated: the api.github.com leg is back, exactly what it permits\
    \ vs denies, that merge is explicitly forbidden (review-gated \u2014 nothing auto-merges),\
    \ and that this is the deferred worker-API leg from the auth-spine slice, now\
    \ done with a real enforcer."
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: artifact
    ref: docs/cloud-worker-auth-spine.md Section 8 permit/deny + merge-forbidden
    note: null
  comment: null
open_questions: []
non_goals:
- "The fan-out orchestrator that fires routines + mints per-run tokens + collects\
  \ PRs \u2014 Slice 2b."
- The pre-created Claude Code Routine's prompt / environment / setup script (operator-authored,
  one-time).
- Permission-scoping the App installation token itself (e.g. pull_requests:write only).
  v1's boundary is the relay ENFORCER, not the token's permissions; token-permission
  scoping is a possible later hardening.
- The GitHub GraphQL API (/graphql). v1 is REST-only; GraphQL would need its own enforcer
  and is refused (not routed) for now.
- "Merging PRs by anyone (worker or relay) \u2014 the flow is review-gated end to\
  \ end; merge is explicitly denied."
risks:
- 'The allowlist IS the security value: a single dangerous REST endpoint left off
  the deny/allowlist re-opens the very bypass Slice 1 closed. Mitigation: DEFAULT-DENY
  (permit an enumerated allowlist; refuse everything else), plus explicit named-deny
  tests for the known-dangerous endpoints (merge, merges, git/refs, contents), plus
  the per-repo scope check.'
- "The GitHub REST surface is large and evolves; a future GitHub endpoint could offer\
  \ a new mutation path. Mitigation: default-deny means new/unknown endpoints are\
  \ refused by construction, not silently permitted \u2014 the failure mode is 'a\
  \ worker call is blocked' (safe), never 'an unexpected mutation is allowed'."
- PATCH /pulls/{n} can change PR state (e.g. close). Bounded to the run's repos and
  non-destructive to refs/contents; acceptable for v1, noted. Merge (PUT /pulls/{n}/merge)
  is a DIFFERENT path and is explicitly denied.
- 'Path parsing for owner/repo on API URLs must be robust (query strings, trailing
  segments, non-repo paths like /user). Mitigation: a small, unit-tested api-path
  extractor; a repo-less path is only allowed if it is on the safe-global allowlist.'
task_slug: worker-pr-egress
work_item_id: wi-20260722104802-8e8ec5bc
clarification_reason: null
prose_verdicts: {}
---
## Problem

The cloud-worker auth spine (Slice 1, shipped) turned the relay into a credential-attaching egress proxy for the GIT path only. It deliberately DROPPED the api.github.com route because its placeholder enforcer would have let a repo-scoped App token mutate refs/contents via the REST API — sidestepping the git push-to-run-branch enforcement. But the chosen worker model (operator decision B) is that the disposable worker runs the FULL loop, including OPENING its own PR — which is a GitHub REST API call (POST /repos/{owner}/{repo}/pulls). With no api.github.com route, the worker cannot open a PR through the relay, so the fan-out orchestrator (Slice 2b) has nothing to collect. This slice brings the api.github.com route back, but this time behind a REAL default-deny enforcer that permits only PR-creation/management + reads and refuses everything that could mutate refs or contents (or merge a PR) via the API — so the worker can open PRs without the API leg becoming a bypass of the git-leg branch enforcement.

## User story

As a disposable cloud worker that has just pushed its run branch, I want to open (and lightly manage) my own pull request through the relay's api.github.com egress, so that the fan-out delivers coordinated cross-repo PRs — while a compromised or prompt-injected worker still cannot mutate refs/contents or merge anything via the API, because the relay enforces a tight PR-only allowlist.

## Approach

Re-add the api.github.com route to the egress proxy's default route table (github-app provider — same repo-scoped installation token as the git leg; the Attachment already host-locks to [github.com, api.github.com]) paired with a NEW GitHubApiEnforcer. The enforcer is DEFAULT-DENY over the GitHub REST surface: it parses the request method + API path, and permits ONLY a small allowlist — POST /repos/{o}/{r}/pulls (open a PR), PATCH /repos/{o}/{r}/pulls/{n} (update the run's PR body/title; NOT merge), POST /repos/{o}/{r}/issues/{n}/comments and PR review endpoints (comment / request review), and GET reads scoped to the run's repos (plus a couple of safe global reads like /rate_limit, /user). Every OTHER method+path is refused (403). Belt-and-braces, it also explicitly refuses the dangerous mutations even though default-deny already covers them (so they are named + tested): PUT /repos/{o}/{r}/pulls/{n}/merge (merging a PR — nothing auto-merges, the flow stays review-gated), POST /repos/{o}/{r}/merges, POST/PATCH/DELETE /repos/{o}/{r}/git/refs/* (ref mutation), and PUT/DELETE /repos/{o}/{r}/contents/* (content mutation) — these are exactly the ways the API could sidestep the git push-to-run-branch enforcement. Every repo-scoped permitted call also requires the path's owner/repo to be within the run's scope.repos (same containment as the git leg). The api leg rides the SAME egress subdomain + Caddy block as the git leg (path-prefix routing /api/ vs /gh/), so no new Caddy route or tls_ask entry is needed. Reuses the Slice-1 seams verbatim (CredentialProvider / Attachment / RouteTable / EgressRequest); the only net-new code is the api-path repo extractor and GitHubApiEnforcer.

## Architecture

Net-new (mothership, core/relay/egress/*): (1) an api-path repo extractor — in request.py, extract owner/repo for the api host from `/repos/{owner}/{repo}/...` (currently `repo` is None for the api host); recognize repo-less API paths (/user, /rate_limit, /graphql). (2) `GitHubApiEnforcer` in enforce.py implementing the Enforcer protocol: parse method + normalized path -> classify as {permit-repo-scoped, permit-global, deny}; a repo-scoped permit additionally requires owner/repo in grant.scope.repos; everything unclassified -> EnforcementError. The permit table is small + explicit (default-deny). (3) re-add `api.github.com: Route(provider, GitHubApiEnforcer())` to build_default_routes. Reused verbatim: the Attachment already host-locks [github.com, api.github.com]; the proxy's verify->route->enforce->provider->attach->forward pipeline + fail-closed; the github-app provider mints the same repo-scoped installation token. No Caddy/tls_ask change (path-prefix on the existing egress host). The permit/deny classification is a pure function (method, path, scope) -> allow|deny, unit-tested exhaustively.

## Security

The API leg must not become an escape hatch around the git-leg branch enforcement. Two containment layers: (a) the repo-scoped App installation token already bounds every call to the run's repos; (b) the GitHubApiEnforcer default-deny allowlist bounds WHAT can be done in those repos to opening/managing the run's PR + reads — never mutating refs/contents and never merging. Merge is called out specifically: the entire fan-out is review-gated (#393: nothing auto-merges), so PUT /pulls/{n}/merge is denied even though the worker holds a token that technically could merge. Default-deny is the load-bearing choice: unknown/new endpoints are refused, so the safe failure mode is a blocked worker call, never an unexpected mutation.

## Testing

Pure/unit (the classifier + enforcer): PERMIT — POST /repos/o/r/pulls, PATCH /repos/o/r/pulls/1, POST /repos/o/r/issues/1/comments, POST /repos/o/r/pulls/1/reviews, GET /repos/o/r, GET /repos/o/r/pulls, GET /rate_limit; DENY — PUT /repos/o/r/pulls/1/merge, POST /repos/o/r/merges, POST/PATCH/DELETE /repos/o/r/git/refs/heads/x, PUT /repos/o/r/contents/f, DELETE /repos/o/r, an out-of-scope repo (o/other), an unknown path (POST /repos/o/r/deployments), a repo-less non-global (GET /orgs/o). api-path repo extractor: /repos/o/r/pulls -> o/r; /user -> None (global); query strings tolerated. Proxy integration (FastAPI TestClient, gh_app + upstream mocked): a permitted PR-create for an in-scope repo attaches the token + forwards; a merge attempt is 403 before egress; missing App creds -> 503. Route table: api.github.com now resolves to the github-app provider + GitHubApiEnforcer. No live GitHub/relay/App key.
