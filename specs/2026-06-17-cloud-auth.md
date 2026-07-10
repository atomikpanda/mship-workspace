---
id: cloud-auth
title: 'Cloud auth: GH_TOKEN passthrough for mship bootstrap and finish'
status: dispatched
created_at: '2026-06-17T23:55:31.855919Z'
updated_at: '2026-06-17T23:58:52.732186Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: resolve_token honors precedence --token > GH_TOKEN > GITHUB_TOKEN and returns
    None when none is set (unit).
  verdict: approved
- id: ac2
  text: git_cred_args returns a github.com-scoped credential helper and carries the
    token only in the returned env dict, never in the args list (unit).
  verdict: approved
- id: ac3
  text: parse_owner_repo returns (owner, repo) for https, https+.git, and SSH (git@github.com:o/r.git)
    URLs and None for non-github/garbage input (unit).
  verdict: approved
- id: ac4
  text: 'create_pr_via_api issues a POST to https://api.github.com/repos/{owner}/{repo}/pulls
    with an Authorization: Bearer header and a {title, head, base, body} payload,
    and returns the PR html_url (unit, httpx transport stubbed).'
  verdict: approved
- id: ac5
  text: mship finish uses gh pr create when gh is usable and falls back to the REST
    path when gh is absent (returncode 127) (unit, ShellRunner mocked).
  verdict: approved
- id: ac6
  text: mship bootstrap splices the credential args onto git clone when a token resolves
    and omits them when none resolves (unit, captured shell command).
  verdict: approved
- id: ac7
  text: With no token and an auth failure, both bootstrap and finish emit the actionable
    error (no raw git traceback) (unit).
  verdict: approved
- id: ac8
  text: --token is accepted by both mship bootstrap and mship finish.
  verdict: approved
- id: ac9
  text: The token never appears in argv or on disk (asserted in the git_cred_args
    unit test).
  verdict: approved
open_questions: []
non_goals:
- "A separate `mship auth` command \u2014 auto-on-first-use plus `--token` covers\
  \ the need."
- "SSH-key provisioning \u2014 the token path is HTTPS-only; SSH (`git@`) remotes\
  \ continue to rely on keys."
- "Persistent or global git credential configuration \u2014 credential helper is spliced\
  \ per-invocation only, never written to the user's gitconfig."
- Token storage, caching, or refresh.
risks:
- 'Credential-helper leakage: mitigated by host-scoping the helper to https://github.com
  and passing the token only via subprocess env (never argv, never disk).'
- 'gh-present detection: relying on returncode 127 to mean ''gh absent'' must not
  misclassify other gh failures; the gh path is only taken when gh is usable, otherwise
  REST is used.'
- REST PR creation differs subtly from `gh pr create` defaults (e.g. draft, maintainer-edit);
  keep the REST payload minimal (title/head/base/body) and document the parity boundary.
- 'Token scope: a token lacking repo scope still fails; the actionable error must
  name the required scope.'
task_slug: cloud-auth
work_item_id: wi-20260702110439-2910c452
---
## Problem

Cloud Claude Code containers have no git credentials and no usable `gh` CLI by default, so mship's two core remote commands fail there. `mship bootstrap` runs `git clone` per member and fails for private repos (no SSH key, no HTTPS creds, no token picked up). `mship finish` runs `git push` + `gh pr create` — push fails without creds and `gh` may not be installed at all. This makes the native workflow (bootstrap → work → finish) non-functional out of the box in exactly the environment mship is designed to orchestrate. It was discovered dogfooding `mship bootstrap` in an overnight cloud routine, which had to fall back to raw git and filed MOS-186/187.

## User story

As an operator running a cloud Claude Code session with a token injected via the environment, I want `mship bootstrap` and `mship finish` to authenticate automatically, so that a cloud agent can clone private members and open PRs using the native mship workflow instead of failing or falling back to raw git.

## Approach

Add GH_TOKEN/GITHUB_TOKEN passthrough that auto-configures auth on first use (no separate command), with `--token` as an explicit override. Token precedence is `--token` > `GH_TOKEN` > `GITHUB_TOKEN`. A new single-purpose module `src/mship/core/gh_auth.py` provides: `resolve_token(explicit)`; `git_cred_args(token)` returning a NON-PERSISTENT, per-invocation `-c credential."https://github.com".helper=<helper>` arg plus a subprocess env dict — the helper reads the token from an env var so the token is never in argv and never written to disk, and the helper is host-scoped to github.com (HTTPS only; SSH `git@` remotes keep using keys); `parse_owner_repo(remote_url)` (pure, handles https/https+.git/ssh); and `create_pr_via_api(token, owner, repo, head, base, title, body)` which POSTs to api.github.com/repos/{owner}/{repo}/pulls with an Authorization: Bearer header via httpx (already a dependency) and returns the PR html_url. `bootstrap` resolves the token and splices the credential args onto each `git clone`; `finish` (`src/mship/core/pr.py`) splices them onto `git push`, and for PR creation branches: when `gh` is present and usable (returncode != 127; gh auto-reads GH_TOKEN) it uses the existing `gh pr create` path unchanged, and when `gh` is absent (returncode 127) it falls back to `create_pr_via_api`, deriving owner/repo from the repo's origin remote. When no token is available and an operation fails with an auth error, both commands emit a clear actionable error (set a repo-scoped token or pass --token) rather than a raw git traceback. Public-repo clones still succeed tokenless.

## Architecture

New module src/mship/core/gh_auth.py owns all token→auth logic as small, independently testable units: resolve_token (precedence), git_cred_args (per-invocation, host-scoped credential helper + token-in-env), parse_owner_repo (pure URL parse), create_pr_via_api (httpx REST). Consumers: src/mship/core/bootstrap.py splices git_cred_args onto the `git clone` in _clone_one; src/mship/core/pr.py uses git_cred_args in push_branch and branches create_pr between the existing gh path and create_pr_via_api based on gh availability (reuse the existing returncode-127 detection in check_gh_available). The finish CLI and bootstrap CLI each gain a --token option threaded through to resolve_token. No persistent state is introduced; the credential helper exists only for the lifetime of each git subprocess.

## Testing

All units are locally verifiable via simulation. Unit tests: resolve_token precedence across --token/GH_TOKEN/GITHUB_TOKEN/none; parse_owner_repo table (https, https+.git, ssh, non-github→None); git_cred_args asserts the helper is scoped to https://github.com and the token is present in the env dict but absent from the args list and from any stringified command; create_pr_via_api via httpx MockTransport asserting request URL, Authorization header, JSON body, and html_url parsing; finish create_pr selects gh when ShellRunner reports gh usable and REST when it reports returncode 127; bootstrap's _clone_one includes the cred args in the captured `git clone` command iff a token is resolved; the no-token auth-failure path surfaces the actionable error string. The single non-local check is a real cloud run: a private clone with and without a token end to end — called out explicitly as cloud verification, not gated in CI.
