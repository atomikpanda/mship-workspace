---
id: ci-auto-version-bump-on-merge-via-pr-issue-376
title: CI auto version-bump on merge via PR label (issue 376)
status: dispatched
created_at: '2026-07-19T20:44:17.773772Z'
updated_at: '2026-07-19T21:00:42.353992Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: Given current version 0.5.0, the helper computes 0.5.1 for level patch, 0.6.0
    for level minor (patch digit zeroed), and 1.0.0 for level major (minor and patch
    digits zeroed).
  verdict: approved
  evidence: []
  comment: null
- id: ac2
  text: 'Given a set of PR labels, the helper selects the bump level by precedence
    major > minor > patch: {semver:minor} -> minor, {semver:patch, semver:minor} ->
    minor, {} -> patch (default), {semver:major, semver:patch} -> major.'
  verdict: approved
  evidence: []
  comment: null
- id: ac3
  text: The helper rewrites the version in BOTH pyproject.toml (project.version) and
    src/mship/__init__.py (__version__) to the same new value, leaving every other
    line in each file byte-for-byte unchanged, so the existing tests/test_version.py
    drift guard still passes after a bump.
  verdict: approved
  evidence: []
  comment: null
- id: ac4
  text: A malformed or missing current version line makes the helper exit non-zero
    and leave both files unmodified, rather than writing a corrupt or half-updated
    version.
  verdict: approved
  evidence: []
  comment: null
- id: ac5
  text: 'The workflow file exists at .github/workflows/version-bump.yml, triggers
    on pull_request closed, runs its job only when the PR merged into main, declares
    contents: write permission and a concurrency group, and its bump commit message
    contains [skip ci].'
  verdict: approved
  evidence: []
  comment: null
- id: ac6
  text: On a merged PR the workflow writes the new version to pyproject.toml, commits
    it to main, and creates and pushes an annotated tag named v<new-version> matching
    the bumped version.
  verdict: approved
  evidence: []
  comment: null
open_questions: []
non_goals:
- Publishing to PyPI or any package index
- Generating GitHub Releases, release notes, or a changelog
- Bumping on direct pushes to main (only PR merges bump)
- Pre-release, build-metadata, or non-semver version strings
- Conventional-commit / commit-message parsing (explicitly rejected in favour of the
  PR-label scheme)
risks:
- 'Branch protection on main may reject a push from the default GITHUB_TOKEN; default
  is to use GITHUB_TOKEN with contents: write, and if protection blocks it, switch
  to a PAT or GitHub App token (documented follow-up, not a blocker).'
- Two PRs merged within seconds could race on the version file; mitigated by a workflow
  concurrency group that serializes runs.
- A PR merged with no semver label silently gets a patch bump; this is the documented,
  intended default rather than a failure.
task_slug: ci-auto-version-bump-on-merge-via-pr-issue-376
work_item_id: wi-20260719210042-77e218a2
clarification_reason: null
prose_verdicts: {}
---
## Problem

mothership has no CI at all, and its version is a hand-edited static field that lives in TWO places that must stay in sync: project.version in pyproject.toml and __version__ in src/mship/__init__.py (both currently 0.5.0, with tests/test_version.py guarding that they match). Version bumps are therefore manual, easy to forget, and easy to get half-done (one file updated, not the other), so main can sit at a stale or inconsistent version across several merged PRs and tags drift out of sync with released code.

## User story

As a mothership maintainer, I want the version in pyproject.toml to bump and tag automatically when I merge a PR into main, with the bump size chosen by a label on that PR, so I never hand-edit the version or forget to cut a tag.

## Approach

Add the repo's first GitHub Actions workflow, .github/workflows/version-bump.yml, triggered on pull_request closed and guarded to run only when the PR was actually merged into main (github.event.pull_request.merged == true and base ref main). The workflow reads the merged PR's labels and picks a bump level by precedence semver:major > semver:minor > semver:patch, defaulting to patch when no semver label is present. The version math and the file rewrites live in a small, unit-testable Python module inside the package (src/mship/ci/version_bump.py, importable because pyproject sets pythonpath=src) rather than inline YAML, so the behaviour is covered by pytest and the workflow step is a thin wrapper invoked via python -m mship.ci.version_bump. The helper reads the current version from pyproject.toml (the source of truth), computes the next semver (minor zeroes patch; major zeroes minor and patch), and rewrites the version in BOTH pyproject.toml (project.version) and src/mship/__init__.py (__version__) so the existing tests/test_version.py drift guard keeps passing. The workflow then commits both changed files back to main with a [skip ci] marker in the message, creates and pushes an annotated tag v<new-version>, using contents: write permission and a concurrency group so rapid back-to-back merges serialize instead of racing on the version files. Because the workflow triggers only on PR close (never on push), the bump commit's own push cannot re-trigger it; the [skip ci] marker is belt-and-suspenders.

## Architecture

Two pieces. (1) src/mship/ci/version_bump.py (new src/mship/ci/ package): a dependency-light module with pure functions bump_version(current: str, level: str) -> str and select_level(labels: Iterable[str]) -> str, plus a rewrite_version_files(repo_root, new_version) that does an in-place single-line substitution in both pyproject.toml (project.version) and src/mship/__init__.py (__version__). It exposes a small CLI (argparse, run via python -m mship.ci.version_bump): it reads the PR labels from an arg, reads the current version from pyproject.toml, computes the level and new version, rewrites both files, and prints the new version to stdout for later workflow steps. (2) .github/workflows/version-bump.yml: checkout, set up Python + uv, run the helper to get the new version, configure git identity, commit the two changed files with a '[skip ci] chore: bump version to vX.Y.Z' message, create an annotated tag vX.Y.Z, and push both the commit and the tag to main. Keeping the logic in the importable module (not the YAML) is what makes the acceptance criteria unit-testable.

## Testing

pytest unit tests cover the helper end to end against a temp-dir fixture holding a miniature pyproject.toml + src/mship/__init__.py: bump math for all three levels including digit-zeroing, label precedence and the patch default, in-place rewrite of BOTH files leaving other lines untouched (assert on full file content), that pyproject and __init__ agree afterwards (mirroring the real test_version.py guard), and the loud-failure path for a malformed/absent version line leaving both files unmodified. The workflow YAML itself is validated by a test that parses .github/workflows/version-bump.yml and asserts on its content (trigger, merged+base guard, contents: write, concurrency group, [skip ci] marker, tag step) rather than by executing Actions locally.
