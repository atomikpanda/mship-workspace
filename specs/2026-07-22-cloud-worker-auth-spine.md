---
id: cloud-worker-auth-spine
title: 'Cloud-worker auth spine: attach-at-relay credential egress proxy (Shape 2)'
status: implemented
created_at: '2026-07-22T01:07:08.797700Z'
updated_at: '2026-07-22T09:47:16.026105Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: '[ac1] A worker carrying only a PLACEHOLDER credential (no usable GitHub token
    in its env/process) can clone, fetch, and push to a granted repo THROUGH the relay,
    which attaches the real GitHub App token at egress; a direct attempt to use the
    placeholder against GitHub without the relay fails. (Attach-at-relay: the real
    credential never lands on the worker.)'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: artifact
    ref: 'PR #400; egress proxy attaches App token at egress, worker holds only placeholder
      (test_proxy.py + docs worker config)'
    note: null
  comment: null
- id: ac2
  text: "[ac2] The git smart-HTTP enforcer parses the worker's smart-HTTP request\
    \ and, on a push (receive-pack) to a repo, REJECTS any ref update except the run's\
    \ branch FOR THAT REPO \u2014 where the run's repos and branch name come from\
    \ the per-run relay token's scope ({repos, push_branch}), NOT a hardcoded single\
    \ branch; clone/fetch (upload-pack) pass through. Cross-repo works because one\
    \ per-run token authorizes the SAME run branch across all the run's repos: a worker\
    \ pushes feat/<slug> to each of repos A, B, C under its single token, and a push\
    \ to any other ref, or to a repo outside the run's repos, is refused in every\
    \ repo."
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: artifact
    ref: 'PR #400; GitSmartHttpEnforcer + pktline parser: run-branch-only push, upload-pack
      passes (test_enforce.py, test_pktline.py; runtime-verified)'
    note: null
  comment: null
- id: ac3
  text: '[ac3] The route table maps destination host -> {provider, enforcer} as configuration
    (no hardcoded github.com special-case): github.com -> github-app provider + git-smart-http
    enforcer{push_ref = run_branch}; api.github.com -> github-app provider + a host-locked
    enforcer (repo-scoped token bounds the API surface). Adding a host is a config
    entry.'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: artifact
    ref: 'PR #400; RouteTable host->{provider,enforcer}, path-prefix /gh /api (test_routes.py,
      test_request.py)'
    note: null
  comment: null
- id: ac4
  text: '[ac4] CredentialProvider seam: GitHubAppProvider.resolve(identity, grant,
    request) returns a Credential{value, ttl, attach} by calling resolve_installation
    + mint_installation_token scoped to the grant''s repos, refusing when the request''s
    repo is outside the grant or the repo set is empty. The interface admits a future
    StaticSecretProvider/GitLabProvider without changing the proxy core.'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: artifact
    ref: 'PR #400; GitHubAppProvider wraps resolve_installation+mint_installation_token,
      refuses out-of-grant/empty (test_provider.py)'
    note: null
  comment: null
- id: ac5
  text: '[ac5] Attachment seam: the GitHub credential rides as `Authorization: token
    <value>` host-locked to [github.com, api.github.com]; the proxy refuses to attach
    it to any host outside that list, so a route misconfig cannot leak it elsewhere.'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: artifact
    ref: 'PR #400; host-locked Attachment refuses non-github hosts (test_credential.py;
      runtime-verified)'
    note: null
  comment: null
- id: ac6
  text: '[ac6] Enrollment carries TYPED grants that form the repo CEILING (which repos
    an enrollment may EVER touch): an enrollment''s pubkey identity maps to a persisted,
    queryable list of {provider, scope} grants (v1: [{github-app, {repos:[owner/a,...]}}]).
    `mship relay grant <enrollment-id> --provider github-app --repos owner/a,owner/b`
    sets/updates that typed grant (unknown or unapproved enrollment errors).'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: artifact
    ref: 'PR #400; GrantStore typed enrollment grants (ceiling) + mship relay grant
      (test_grants.py, test_relay_grant.py)'
    note: null
  comment: null
- id: ac7
  text: "[ac10] A PER-RUN relay token carries the run's scope \u2014 {repos: a subset\
    \ of the enrollment's grant, push_branch: the run's branch} \u2014 and is what\
    \ a worker presents; it is issued with the plaintext printed once and only a hash\
    \ persisted (re-issuing rotates; it has an expiry). The git-smart-http enforcer\
    \ reads {repos, push_branch} from this token (ac2), so authorization is per-run\
    \ data, not code. Slice 1 provides the issue path + the scope model + enforcement;\
    \ automated minting at fan-out is Slice 2. A requested repo outside the enrollment\
    \ ceiling, or a push_branch mismatch, is refused."
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: artifact
    ref: 'PR #400; egress-proxy role module verifies run token itself (end-to-end),
      relocatable off-relay (proxy.py, docs)'
    note: null
  comment: null
- id: ac8
  text: '[ac7] The egress-proxy is a distinct module whose worker-facing session logically
    terminates at it (not at the relay as a monolith), and the worker is authenticated
    to the egress-proxy role in a way verifiable end-to-end (not merely ''the relay
    says so''), so relocating the role off the relay (untrusted-relay split) is a
    deployment/wiring change rather than a channel rewrite. Documented with the boundary
    explicit.'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: artifact
    ref: 'PR #400; fail-closed 503 when App creds absent (runtime-verified); Caddy/tls_ask/docker
      wiring'
    note: null
  comment: null
- id: ac9
  text: '[ac8] Fail-closed + deploy wiring: with App creds absent/unreadable the proxy
    refuses to attach and does not forward (no silent downgrade), mirroring serve''s
    refuse-on-unreadable-key; the relay deployment wiring (Caddy route(s), tls_ask_allowed
    entries, and where App creds + the grant store live on the relay host) is provided
    and documented.'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: artifact
    ref: 'PR #400; docs/cloud-worker-auth-spine.md: trust model, north star, fork-not-ladder,
      four seams'
    note: null
  comment: null
- id: ac10
  text: '[ac9] Documentation states the trust model: worker least-trusted -> attach-at-relay
    (Shape 2, co-located); the untrusted-relay 3-role split as the north star (worker
    / blind relay / separate secrets-egress host) reachable as a deployment change;
    Shape 2 vs Shape 3 is a fork not a ladder; seal-to-worker retired; and how the
    four seams admit GitLab / static secrets later with zero worker change.'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/1.mothership
    note: null
  - kind: artifact
    ref: 'PR #400; per-run token {repos subset,push_branch}, plaintext-once/hmac/expiry;
      enforcer reads scope (test_run_token.py)'
    note: null
  comment: null
open_questions: []
non_goals:
- "The untrusted-relay SPLIT deployment (the 3-role north star: worker / blind relay\
  \ / separate secrets-egress host). v1 co-locates all roles on the trusted relay\
  \ but draws the egress-proxy module boundary so the split is later deployment work\
  \ \u2014 the split itself is NOT built now."
- Non-GitHub providers (GitLab/Bitbucket) and non-git static secrets (OpenAI/Stripe
  keys via StaticSecretProvider + bearer enforcer). The four seams are built so these
  are later config + a plugin; the providers themselves are out of v1.
- "Seal-to-worker / HPKE / any deliver-a-token-to-the-worker mechanism \u2014 retired\
  \ by attach-at-relay; explicitly not built."
- The fan-out orchestrator that mints per-run relay tokens and spawns N workers (Slice
  2) and the portable worker image (Slice 3).
- "Auto-merge \u2014 the flow stays review-gated (workers push to a run branch and\
  \ open PRs; nothing merges automatically)."
- "New App-minting crypto \u2014 reuses core/gh_app.py resolve_installation + mint_installation_token;\
  \ v1 adds a relay-side caller + the proxy/enforcer around it."
risks:
- "The git smart-HTTP egress proxy + receive-pack enforcer is the largest net-new\
  \ piece \u2014 the relay today is an ssh -R tunnel (sish) plus a small enroll-app\
  \ HTTP control plane, with no git-wire awareness. Parsing smart-HTTP well enough\
  \ to enforce (not just stamp a header) is real work. Mitigation: v1 scopes enforcement\
  \ to the one load-bearing property (push only to the run branch); clone/fetch pass\
  \ through; unit-test the receive-pack ref-update parse against captured git wire\
  \ samples."
- 'The relay is now on the git data path, so its uptime is the fan-out''s uptime and
  a naive restart mid-run kills in-flight pushes. Mitigation: design for resumable
  pushes and redeploy-without-dropping-live-tunnels; call these out as operational
  requirements (full HA is beyond v1).'
- "App private key + grants live on the relay host (Shape 2, trusted relay). A compromised\
  \ relay can attach tokens within any enrollment's grants \u2014 bounded per-enrollment\
  \ + short-TTL + branch-enforced, but real. Mitigation: this is exactly the trusted-relay\
  \ assumption Shape 2 names; the egress-proxy boundary is drawn so the untrusted-relay\
  \ split removes it later without a rewrite."
- 'The enforcer is the whole security value: a bug that lets a push reach a non-run
  ref, or that attaches a credential to the wrong host, defeats the model. Mitigation:
  pure, unit-tested ref-update allow-check (accept run branch, reject every other
  ref, reject force-update of the run ref if out of policy) and host-locked attachment
  (reject any host not in the Attachment''s hosts[]); fail CLOSED when App creds are
  absent (never forward unauthenticated).'
- 'Typed-grant + per-run-token store is net-new persisted relay state (today approve
  discards the enrollment record, keeping only the pubkey). Corruption/loss = workers
  can''t be authorized until re-granted. Mitigation: atomic writes like the existing
  RequestStore; recoverable by re-running grant.'
task_slug: null
work_item_id: null
clarification_reason: null
prose_verdicts: {}
---
## Problem

Overnight cloud-worker fan-out (#393: 'run these N approved specs overnight in isolated cloud workers, get coordinated cross-repo PRs by morning') is blocked on cross-repo auth. The forcing constraint (from the #393 comments, which supersede the issue body): the WORKER is the least-trusted party — it is disposable AND an LLM agent that can be prompt-injected. Any model where a usable credential lands in the worker's env or process (GH_TOKEN, a locally-decrypted token, a local swap-proxy it can reach) leaves it extractable by an injected agent that can printenv, read files, or route its own requests. Cross-repo forces a GitHub App installation token, which is a bearer: extractable-if-usable by definition and honored by GitHub from any IP (not sender-constrainable). Without confidential-compute hardware (ruled out by 'any managed cloud'), the ONLY way to keep a bearer non-extractable-by-the-agent is to keep it off the worker entirely. Therefore the credential must be attached OFF the worker, at the relay's egress — not minted into the worker. (This retires the seal-to-worker/HPKE idea from the issue body, which only made sense in the now-rejected deliver-a-token-to-the-worker model.)

## User story

As someone fanning out approved specs to disposable, prompt-injectable cloud workers, I want each worker to clone/fetch/push and open cross-repo PRs while carrying only a PLACEHOLDER credential — with the real GitHub App token attached and enforced at the relay egress — so that a compromised or injected worker can never exfiltrate a usable credential and can only push to its own run branch.

## Approach

Attach-at-relay, Shape 2 (all roles co-located on the relay the operator runs). The relay becomes a scoped credential-attaching egress proxy on the git DATA path (not just touched at mint time). A worker's git smart-HTTP traffic (clone/fetch/push) and GitHub API traffic (PR coordination) route through the relay carrying only a placeholder. For each request the relay: (1) authenticates the tunnel against the existing SSH-pubkey enrollment; (2) looks up the enrollment's typed grants — the per-run relay token authorizes exactly those grants; (3) matches the destination host to a route -> {provider, enforcer}; (4) resolves the real credential from the provider (GitHubAppProvider = resolve_installation + mint_installation_token scoped to the grant's repos); (5) ENFORCES via the route's enforcer — for git smart-HTTP, parse the request and reject any push ref-update except the run's working branch (clone/fetch pass); (6) ATTACHES the credential per the Attachment (Authorization: token <value>, host-locked to github.com/api.github.com) and forwards to the provider. Attach and enforce stay glued together because both require the request in plaintext — you cannot branch-scope a push you cannot parse; attaching WITHOUT enforcing spends the whole proxy cost and captures none of the security, so enforcement is the reason we are on the path.

Two layered authorization scopes make cross-repo enforcement work: (a) the ENROLLMENT grant is the repo CEILING — which repos an enrollment may ever touch; (b) the PER-RUN relay token narrows to one run: {repos ⊆ the grant, push_branch = the run's branch}. mship already gives a task ONE branch name (feat/<slug>) that is identical across all the repos the task spans, so 'the run branch' is that task's branch present in each of its repos. The enforcer, on a push to repo X, requires X to be in the per-run token's repos AND the pushed ref to equal the token's push_branch — so a cross-repo worker pushes the same run branch to each of its repos under one token, and nothing else, anywhere. Per-run token minting at fan-out is Slice 2; Slice 1 defines the token scope, an issue path, and the enforcement.

Four seams go in from the start so a later GitLab/Bitbucket provider or a non-git secret (e.g. an OpenAI key) is relay-side config + a plugin, with ZERO worker-side change: (1) CredentialProvider.resolve(identity, grant, request) -> Credential{value, ttl, attach}; v1 ships GitHubAppProvider. (2) Attachment{header, render(value), hosts[]} — decouples HOW a credential rides from WHAT it is, and host-locks it so a route misconfig can't send a credential to the wrong host. (3) Route table: destination host -> {provider, enforcer} as config, so the relay stops special-casing github.com. (4) Enrollment carries TYPED grants: pubkey identity -> [{provider, scope}] (v1: [{github-app, {repos:[...]}}]), each independently revocable; the per-run relay token authorizes exactly the enrollment's grants.

Egress-proxy module boundary drawn now (untrusted-relay north star): build so the worker's secure session logically terminates at the EGRESS-PROXY ROLE, which merely happens to share the relay host today. Then the future untrusted-relay world is a DEPLOYMENT change, not a rewrite: the relay stops terminating and goes back to pure authenticated tunneling, and the egress-proxy role (which is essentially MOS-226's Broker A / the folded App broker in `mship serve`) relocates to its own VPS behind the relay, authenticating the worker end-to-end rather than trusting the relay's word. Shape 2 vs the untrusted-relay split is a FORK, not a ladder — they defend against different adversaries (worker-least-trusted vs relay-operator-least-trusted); v1 is worker-least-trusted (correct: we run the relay, the worker is the disposable injectable thing).

## Architecture

The relay gains a scoped credential-attaching egress proxy. New pieces (mothership, core/relay/* + docker/relay/*):
- Egress proxy: an HTTP(S) proxy on the relay host that terminates the worker's git smart-HTTP + GitHub API requests, applies route -> provider -> enforce -> attach, and forwards to the provider. Built as a distinct 'egress-proxy role' module so it can later move off the relay.
- git-smart-http enforcer: parses the smart-HTTP info/refs + receive-pack POST; permits upload-pack (clone/fetch) and permits receive-pack ONLY for the run branch ref; rejects all other ref updates. Provider-independent (the git wire protocol is the same across GitHub/GitLab/Gitea), so branch-scoping is written once.
- CredentialProvider interface + GitHubAppProvider wrapping core/gh_app.py (resolve_installation -> mint_installation_token(repos=grant.repos)); reads App creds via serve's existing _read_gh_app_creds pattern (MSHIP_GH_APP_ID numeric, MSHIP_GH_APP_KEY = path to .pem, hard error if set-but-unreadable). Credential carries value + ttl + the Attachment to use.
- Attachment: {header name, render(value)->header value, hosts[]}; host-lock enforced at attach time.
- Route table: config mapping destination host -> {provider, enforcer}. v1 seeds github.com and api.github.com.
- Typed-grant store: extend the relay enrollment persistence (today enroll.py RequestStore discards the record on approve, keeping only the pubkey) into a queryable approved-enrollment store keyed by enrollment id, holding hostname + typed grants [{provider, scope}] as the repo ceiling. `mship relay grant` in cli/relay.py writes it.
- Per-run token: a separate record/scope {repos ⊆ grant, push_branch, hash, expiry}, verified by hmac.compare_digest (like ensure_serve_token); the enforcer resolves the presented token to its {repos, push_branch} and checks each pushed ref against push_branch for that repo. Issuing a per-run token is a Slice-1 CLI/test path; Slice 2 automates it at fan-out (the orchestrator knows the run's repos + branch feat/<slug>).
- Deploy: Caddy route(s) fronting the proxy + tls_ask_allowed entries (tls_ask.py allowlist is intentionally tight); App creds env + grant-store dir on the relay container (docker/relay/).

Reuses verbatim: resolve_installation + mint_installation_token (repo-scoped, refuses empty repos) from core/gh_app.py — v1 adds a relay-side caller behind the provider seam, not new token crypto. Relationship to MOS-226 / the fold spec: MOS-226's Broker A (serve-host proxy) and the folded App broker in `mship serve` are essentially the egress-proxy role; v1 stands that role up on the relay with the four seams, and the untrusted-relay split later relocates it (back) to a serve/VPS host behind the relay.

## Security

Trust roles (from #393 comment 2): Worker = least trusted (disposable + prompt-injectable) — sees only a placeholder, never a real credential. Relay/front door = untrusted transport in the north star (v1 trusts it) — in the split it sees only opaque bytes. Secrets-egress host = small trusted core — sees plaintext secrets, does exchange + attach + enforce + provider egress. v1 co-locates relay + egress-proxy + secrets on the one host the operator runs (Shape 2); the module boundary is drawn so the trusted secrets-egress core can later move to its own locked-down host reachable only through the (now-blind) relay — big attack-surface component public + untrusted, small secret-handling core private + trusted (bastion-edge / trusted-core split). Containment rests on: (a) the credential never being on the worker (attach-at-relay); (b) the receive-pack enforcer restricting pushes to the run branch; (c) the App installation token being repo-scoped to the grant (short GitHub TTL); (d) host-locked attachment. Honest limit: this does not eliminate SOME host seeing plaintext (impossible for bearer creds) — it minimizes and isolates it. Security asymmetry to remember for the future StaticSecretProvider: a GitHub App token has built-in mitigations (short TTL, fine scope); a static third-party key (OpenAI) has none, so for those the off-box boundary is the ONLY backstop — the generalization strengthens attach-at-relay, it does not weaken it.

## Testing

Pure/unit: the git-smart-http receive-pack parser + ref-update allow-check (accept a push to the run branch, reject a push to any other ref, reject a disallowed force-update; pass upload-pack) against captured git wire samples; the route table resolution (host -> provider+enforcer, unknown host rejected); GitHubAppProvider.resolve with gh_app mocked (asserts resolve_installation + mint_installation_token called with exactly the grant's repos; refuses out-of-grant repo + empty); the Attachment host-lock (attach to an allowed host, refuse a disallowed host); the typed-grant store (create/read/rotate/expire; per-run token issue + hash + hmac verify accept/reject). Proxy integration (in-process, GitHub mocked at the boundary): a placeholder-carrying push to the run branch is attached + forwarded; a push to another ref is rejected before egress; missing App creds -> fail closed (no forward). No live relay, live GitHub, or real App key in tests — gh_app + the provider egress are mocked at the boundary; git wire behaviour is exercised with recorded pkt-line samples.
