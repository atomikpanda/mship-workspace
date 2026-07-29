# Plan: branch + push a git feature across the repo (CANARY — synthesized known-bad)

> Synthesized ground-truth REJECTED plan for the AC-0 backtest. Motivating case from
> atomikpanda/mothership#444: a git feature planned for single-repo and monorepo only,
> silently never raising **metarepo** — mship's core differentiator. Ground-truth: BAD
> (should be flagged not-covered on repo topology). Not a real shipped plan.

**Goal:** Add `mship ship` — create a feature branch, commit the working changes, and push
it to the remote so a PR can be opened.

## Approach

The command operates on the repository in the current working directory. Two layouts are
in scope:

1. **Single-repo:** the common case. Resolve the repo root via `git rev-parse
   --show-toplevel`, create `feature/<slug>` off the default branch, commit, and `git push
   -u origin`.
2. **Monorepo:** the same repository holds multiple projects in subdirectories. We branch
   and push the whole repo exactly as in the single-repo case — the extra projects ride
   along on the one shared history. A path filter lets the commit scope to the touched
   subproject, but the branch and push remain whole-repo.

Because both layouts reduce to "one working tree, one remote, one history," the
implementation is a thin wrapper over `git branch` / `git commit` / `git push` against the
single resolved repo root. Credentials come from the ambient git config / credential
helper on the machine running the command.

## Tasks
1. Resolve the repo root and default branch.
2. Create and check out `feature/<slug>`.
3. Commit the working changes (optional path filter for the monorepo subproject case).
4. `git push -u origin feature/<slug>` and print the PR-create URL.
