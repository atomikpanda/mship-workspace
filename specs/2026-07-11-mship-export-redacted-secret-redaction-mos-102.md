---
id: mship-export-redacted-secret-redaction-mos-102
title: mship export + --redacted secret redaction (MOS-102)
status: dispatched
created_at: '2026-07-11T18:09:01.123685Z'
updated_at: '2026-07-11T18:50:33.600109Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: '`mship export <task>` writes a bundle (default `<task>-export/` directory)
    containing the task''s journal, its bound spec (if any), an associated plan doc
    (if found), the task''s state slice, and per-repo base..branch diffs for its affected
    repos.'
  verdict: approved
- id: ac2
  text: '`--format dir|zip` is supported; `--format dir` is the default when `--format`
    is omitted.'
  verdict: approved
- id: ac3
  text: '`--redacted` replaces every match of each documented pattern with `<REDACTED:kind>`
    (kind identifying which pattern matched) across the bundle''s text artifacts (journal,
    plan, spec, diffs).'
  verdict: approved
- id: ac4
  text: Each documented regex (Stripe live/test keys, GitHub ghp_/gho_/ghu_/ghs_ tokens,
    AWS access key id + nearby aws_secret_access_key value, PEM private key blocks,
    Bearer tokens, .env-style KEY=value secrets) has a dedicated test asserting a
    planted sample secret is replaced with the expected `<REDACTED:kind>` marker.
  verdict: approved
- id: ac5
  text: "Without `--redacted`, `mship export` never modifies artifact contents \u2014\
    \ the bundle is a faithful copy (verified by a test that a planted secret survives\
    \ unredacted export unchanged)."
  verdict: approved
- id: ac6
  text: Binary files encountered while assembling diffs are copied into the bundle
    without being passed through the redaction regexes.
  verdict: approved
- id: ac7
  text: An optional user-configured pattern source (`~/.config/mship/redact.patterns`
    and/or `mothership.yaml#redact.patterns`) is loaded and unioned with the built-in
    patterns when `--redacted` is passed and the source exists; export works unchanged
    when neither is present.
  verdict: approved
- id: ac8
  text: '`mship export` for a task with no bound spec / no matching plan doc / no
    diffs for some repo still succeeds, simply omitting those pieces from the bundle
    (never errors on a missing-but-optional artifact).'
  verdict: approved
open_questions:
- id: q1
  text: Should `export` (bundle assembly) and `--redacted` (redaction pass) ship as
    one PR/slice, or split into two so bundle assembly can land and be reviewed independently
    of the redaction regex set?
  answer: together is fine
- id: q2
  text: Is `--format dir` really the right default, or should `--format zip` be default
    since export's main use case is handing the bundle to someone outside the workspace
    (a single file is easier to share than a directory)?
  answer: zip
- id: q3
  text: 'Exact plan-file discovery rule: is a task-slug-matching filename under `docs/plans/`
    sufficient, or does the task need an explicit `plan_path` reference (Task has
    no such field today) to avoid ambiguous or missed matches?'
  answer: for v1 exact plan discover is okay
- id: q4
  text: Should `aws_secret_access_key` redaction require literal proximity (e.g. same
    line/config block) to an `AKIA...` match, or should it always redact `aws_secret_access_key`
    assignments regardless of a nearby access key id (simpler, also catches secret
    keys stored without their key id)?
  answer: 'no literal proximity '
- id: q5
  text: Does `<REDACTED:kind>` need a stable, documented enum of `kind` values as
    part of the CLI's output contract (for downstream tooling to parse), or is it
    purely a human-legibility string?
  answer: mostly human legibility unless you can think of a reason why
non_goals:
- "ML/entropy-based secret classification \u2014 v1 is deterministic regex only"
- Interactive review of individual redaction matches before they're applied
- "Partial redaction pick-list (e.g. `--redact github,aws`) \u2014 `--redacted` is\
  \ all-or-nothing"
- "Auto-redaction of exports that didn't request it \u2014 redaction is explicit opt-in,\
  \ never a silent default"
- Cross-task redaction history/audit trail (tracking what was redacted across exports
  over time)
risks:
- "Regex-only redaction has false negatives (secret shapes not in the documented list,\
  \ e.g. non-standard/internal tokens) and false positives (text that happens to match\
  \ a pattern but isn't a secret) \u2014 the patterns below are documented precisely\
  \ so users know what is and isn't covered; this is not a general DLP/secrets-scanning\
  \ tool and should be described as such wherever `--redacted` is surfaced."
- Large per-repo diffs (long-lived tasks, big refactors) make regex-scanning + bundle
  assembly slower; the scan needs to stay a linear pass per file rather than something
  pathological (e.g. avoid catastrophic backtracking in the private-key block pattern).
- A private key or multi-line secret split across a diff hunk boundary (context lines
  interspersed with +/- markers) may not match a single-pass regex, under-redacting
  despite `--redacted` being requested.
- "User-configured custom patterns (`redact.patterns`) are arbitrary regexes from\
  \ a file/config \u2014 a malformed or catastrophic pattern there could hang or crash\
  \ export; needs basic validation and/or a timeout, not blind `re.compile`/eval."
task_slug: mship-export-redacted-secret-redaction-mos-102
work_item_id: wi-20260711185033-5cb25a1d
---
## Problem

mship task work produces a scattered set of artifacts — journal entries, a plan/spec doc, per-repo diffs, and task state — that live only inside the local workspace/worktree layout. There is no single command to package those artifacts for someone outside the workspace (a client, a contractor without repo access, a support/escalation thread), so operators hand-assemble files today. Hand-assembly (or even an automated bundle with no safeguards) risks carrying live credentials straight into an external channel: diffs can contain API keys or tokens committed by mistake, journals can contain pasted .env output, etc. mship needs an `export` command that produces a self-contained bundle, plus an opt-in `--redacted` pass that deterministically strips known secret shapes before the bundle leaves the workspace.

## User story

As an operator handing a task's context to someone outside the workspace (a client, a contractor, a support/escalation channel), I want `mship export <task>` to assemble that task's journal, plan, spec, state, and diffs into one bundle, and an opt-in `--redacted` flag that strips well-known secret patterns from the bundle's text artifacts, so that I can share full context externally without hand-auditing every diff for leaked credentials or hand-copying files myself.

## Approach

Add `mothership/src/mship/core/export.py` (bundle assembly + redaction) and `mothership/src/mship/cli/export.py` (the `mship export <task> [--redacted] [--format dir|zip]` command), registered in `cli/__init__.py` alongside the other task-scoped commands. `<task>` resolves the same way every other task-scoped command does (`--task` flag -> `MSHIP_TASK` env -> cwd), consistent with the rest of the CLI.

Bundle assembly reads from sources that already exist rather than inventing new storage: the task's journal via `LogManager.read(slug)` (core/log.py); the task's state slice via `StateManager.load().tasks[slug]` (core/state.py), serialized as-is; the bound spec via the Task's `spec_id` (SpecStore.find_by_id, when set), rendered as its spec markdown; an associated plan doc if one exists under `docs/plans/` (best-effort filename match on the task slug — the exact discovery rule is an open question below); and per-repo diffs computed as `base_branch..branch` for each of the task's `affected_repos`, reusing the base-resolution conventions `mship pr`/`mship close` already rely on (e.g. pr.py's `fetch_remote_branch` / `count_commits_ahead` helpers). Output is written under a bundle directory named `<task>-export/` by default (`--format dir`); `--format zip` zips that same tree instead. Missing pieces (no plan, no bound spec, a repo with no diff) are omitted from the bundle rather than erroring — export should always succeed for whatever artifacts actually exist.

`--redacted` is a second, orthogonal pass applied only to the bundle's TEXT artifacts (journal, plan, spec, diffs) after assembly; binary files (e.g. a binary blob inside a diff) are copied through untouched, never scanned or mangled. Redaction runs each documented regex (see "Redaction patterns (v1)" below) over each text file's contents and replaces matches with `<REDACTED:kind>`. For whole-token patterns (Stripe/GitHub/AWS-access-key/Bearer/PEM blocks) the entire matched token is replaced; for the `.env`-style `KEY=value` pattern only the value portion is replaced (keeping the `KEY=` prefix, e.g. `API_KEY=<REDACTED:env_secret>`) since that is what keeps the artifact's shape legible per the issue's own goal. Redaction is v1-deterministic and regex-only — no entropy/ML classifier, no interactive per-match review, no partial pick-list (`--redact github,aws`); it is all-or-nothing via `--redacted`, and never runs unless that flag is passed (plain `mship export <task>` is a faithful, unredacted copy). An optional user-configured pattern list — `~/.config/mship/redact.patterns` (one regex per line) or a `redact.patterns` list under `mothership.yaml`— is unioned with the built-in patterns when `--redacted` is passed and the source exists, so an operator can add client/customer name patterns without code changes.

## Redaction patterns (v1)

Deterministic, regex-only. Each pattern below documents exactly what `--redacted` catches — anything not matching one of these shapes passes through unredacted.

- Stripe live key: `sk_live_[a-zA-Z0-9]+` → `<REDACTED:stripe_live_key>`
- Stripe test key: `sk_test_[a-zA-Z0-9]+` → `<REDACTED:stripe_test_key>`
- GitHub token: `gh[pousr]_[A-Za-z0-9]{36}` (covers `ghp_`, `gho_`, `ghu_`, `ghs_`) → `<REDACTED:github_token>`
- AWS access key id: `AKIA[0-9A-Z]{16}` → `<REDACTED:aws_access_key_id>`
- AWS secret access key: `(?i)aws_secret_access_key\s*[:=]\s*['"]?([A-Za-z0-9/+=]{40})['"]?` → the value is replaced with `<REDACTED:aws_secret_access_key>` (see open question on required proximity to an `AKIA...` match)
- Private key block: `-----BEGIN [A-Z ]+PRIVATE KEY-----[\s\S]*?-----END [A-Z ]+PRIVATE KEY-----` (whole block, non-greedy) → `<REDACTED:private_key>`
- Bearer token: `Bearer [A-Za-z0-9._\-]+` → `Bearer <REDACTED:bearer_token>` (the scheme word `Bearer` is kept, only the token is replaced, mirroring the `.env` value-only treatment below)
- `.env`-style secret: `(?i)(API_KEY|SECRET|PASSWORD|TOKEN|CREDENTIAL)=\S+` → only the value after `=` is replaced, keeping the key name, e.g. `API_KEY=<REDACTED:env_secret>`
- Optional user patterns: additional regexes from `~/.config/mship/redact.patterns` (one per line) and/or `mothership.yaml#redact.patterns` (a YAML list), unioned with the above and each replaced with `<REDACTED:custom>` (or a name derived from the pattern's config key, if given one) when `--redacted` is passed.

## Bundle contents

`mship export <task>` (or `mship export <task> --redacted`) writes, by default, a directory `<task>-export/` (zipped instead when `--format zip` is given) containing:

- `journal.md` — the task's journal (`LogManager.read(slug)`), rendered in order
- `plan.md` — the associated plan doc under `docs/plans/`, if one is found for the task (omitted if none)
- `spec.md` — the bound spec's rendered markdown, if the task has a `spec_id` (omitted if none)
- `state.json` — the task's state slice (`StateManager.load().tasks[slug]`), serialized as-is
- `diffs/<repo>.diff` — one `base_branch..branch` diff per affected repo (omitted per-repo if there is no diff, e.g. a passive repo or a repo with no commits on the task branch)

Every text file above is a candidate for `--redacted` scanning; binary content inside a diff is copied through unscanned per the risk noted above.
