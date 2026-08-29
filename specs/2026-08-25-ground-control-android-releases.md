---
id: ground-control-android-releases
title: Ground Control automatic signed Android releases
status: implemented
created_at: '2026-08-25T02:41:57.630243Z'
updated_at: '2026-08-25T11:18:24.313033Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: A pull request that changes Android source triggers a GitHub Actions Android
    verification job using JDK 17 and Gradle caching.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  comment: null
- id: ac2
  text: The pull-request verification job successfully invokes the Gradle tasks `testDebugUnitTest`,
    `lintDebug`, and `assembleDebug`.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  comment: null
- id: ac3
  text: The pull-request workflow and job declare read-only repository permissions
    and contain no reference that injects `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
    `ANDROID_KEY_PASSWORD`, or `ANDROID_KEY_ALIAS` into the job environment or steps.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  comment: null
- id: ac4
  text: A push to `main` triggers a release workflow that runs Android verification
    before the signed release APK is published.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  comment: null
- id: ac5
  text: For a `main` workflow run whose `github.run_number` is `N`, Gradle builds
    the release with Android `versionCode` equal to integer `N`.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  comment: null
- id: ac6
  text: For a `main` workflow run whose `github.run_number` is `N`, Gradle builds
    the release with Android `versionName` equal to `0.1.N`.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  comment: null
- id: ac7
  text: The release signing configuration reads the keystore, store password, key
    password, and key alias from `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
    `ANDROID_KEY_PASSWORD`, and `ANDROID_KEY_ALIAS`, respectively, without hardcoding
    any secret value in tracked files.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  comment: null
- id: ac8
  text: The `main` release job decodes `ANDROID_KEYSTORE_BASE64` only into an ephemeral
    runner file and removes that file in an always-executed cleanup step.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  comment: null
- id: ac9
  text: The `main` release job runs Gradle task `assembleRelease` using JDK 17 and
    Gradle caching.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  comment: null
- id: ac10
  text: Before any tag or GitHub Release is created, the workflow runs Android SDK
    `apksigner verify` against the produced release APK and stops publication if verification
    fails.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  comment: null
- id: ac11
  text: For a successful `main` workflow run whose `github.run_number` is `N`, the
    repository contains a tag named exactly `v0.1.N`.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  comment: null
- id: ac12
  text: For a successful `main` workflow run whose `github.run_number` is `N`, GitHub
    contains a Release associated with tag `v0.1.N`.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  comment: null
- id: ac13
  text: For a successful `main` workflow run whose `github.run_number` is `N`, the
    corresponding GitHub Release contains exactly one published APK asset named `ground-control-v0.1.N.apk`.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  comment: null
- id: ac14
  text: Release publication uses GitHub-native tooling, such as the GitHub CLI or
    GitHub API authenticated with `GITHUB_TOKEN`, and does not use a third-party GitHub
    Release action.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  comment: null
- id: ac15
  text: 'The release job has `contents: write` permission, while no pull-request job
    has write permission.'
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  comment: null
- id: ac16
  text: Two pushes to `main` that overlap in time enter the same GitHub Actions concurrency
    group, and the later run waits rather than cancelling the earlier run.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  comment: null
- id: ac17
  text: A maintainer can follow the documented setup procedure to generate one RSA-4096
    JKS keystore outside the repository and confirm the keystore reports a 4096-bit
    RSA key.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  comment: null
- id: ac18
  text: The documented setup procedure creates or copies the persistent keystore backup
    beneath `~/.mothership/keys` and includes a verification command that reports
    file mode `0600`.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  comment: null
- id: ac19
  text: Repository history and tracked files contain neither the generated JKS file
    nor plaintext values for any of the four Android signing secrets.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  comment: null
- id: ac20
  text: The repository's GitHub Actions secrets include entries named `ANDROID_KEYSTORE_BASE64`,
    `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_PASSWORD`, and `ANDROID_KEY_ALIAS` before
    the release workflow is enabled for successful publication.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  comment: null
- id: ac21
  text: The existing README identifies the GitHub Releases page as the Android APK
    source and provides steps for adding the `atomikpanda/ground-control` repository
    URL to Obtainium.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  comment: null
- id: ac22
  text: The existing README states that updates require all published APKs to use
    the same persistent signing key.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  comment: null
- id: ac23
  text: The existing README documents the purpose and expected encoding or value of
    each of `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_PASSWORD`,
    and `ANDROID_KEY_ALIAS`.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  comment: null
- id: ac24
  text: The existing README states that signing private material must not be committed
    to the repository, printed in workflow logs, or supplied to pull-request jobs
    or subagent context.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  comment: null
- id: ac25
  text: Installing the APK from one successful GitHub Release and then installing
    the APK from a later successful release is accepted by Android as an update, with
    the later APK reporting both a greater `versionCode` and the same signing certificate.
  verdict: approved
  evidence:
  - kind: test
    ref: test-runs/3.ground-control
    note: null
  comment: null
open_questions: []
non_goals:
- Play Store publishing.
- iOS distribution.
- Automatic major/minor semantic-version inference.
- Committing a signing key.
- Exposing signing secrets to pull-request jobs.
risks:
- Loss of the persistent signing key or its passwords would prevent future APKs from
  updating installations signed by that key; the required mode-`0600` backup mitigates
  this risk.
- Replacing or rotating the signing key would break Obtainium upgrades for existing
  installations unless users uninstall the old app first.
- Incorrect workflow permissions or event scoping could expose secrets or permit writes
  from pull-request jobs; permissions and secret use must be explicitly isolated to
  the `main` release job.
- A failed release after tag creation could leave partial release state; publication
  steps should check for conflicting tags/releases and fail clearly rather than overwrite
  another version.
- The GitHub workflow run number must fit Android's integer `versionCode` range; this
  is not an immediate constraint but is a long-term platform limit.
- Concurrent pushes to `main` could otherwise publish out of order; a non-cancelling
  concurrency group is required to serialize release jobs.
task_slug: null
work_item_id: null
clarification_reason: null
prose_verdicts:
  problem:
    verdict: approved
    comment: null
  user_story:
    verdict: approved
    comment: null
  approach:
    verdict: approved
    comment: null
  non_goals:
    verdict: approved
    comment: null
  risks:
    verdict: approved
    comment: null
  scope_risk:
    verdict: approved
    comment: null
---
## Problem

`atomikpanda/ground-control` does not currently produce signed Android artifacts that Obtainium can install and update from GitHub Releases. The Android app hardcodes `versionCode 1` and `versionName 0.1.0`, has no release signing configuration, and the repository has neither release tags nor GitHub Releases. The repository needs a secure, serialized GitHub Actions pipeline that verifies pull requests without privileged credentials and publishes a monotonically versioned, signature-verified APK after every push to `main`.

## User story

As a Ground Control Android user, I want Obtainium to discover, install, and update a consistently signed APK from this repository's GitHub Releases so that I can receive new Ground Control builds directly from GitHub. As a maintainer, I want pull requests to receive read-only Android verification while pushes to `main` securely create signed, uniquely versioned releases without exposing private signing material.

## Approach

Add GitHub Actions automation and Android Gradle configuration for separate verification and release paths. Pull requests will run on JDK 17 with Gradle caching and execute `testDebugUnitTest`, `lintDebug`, and `assembleDebug` using read-only repository permissions and no signing secrets. Every push to `main` will run verification, derive `versionCode` from `github.run_number`, derive `versionName` as `0.1.<run_number>`, configure release signing from the four approved GitHub Actions secrets, run `assembleRelease`, verify the resulting APK with Android SDK `apksigner`, create tag `v0.1.<run_number>`, and publish a GitHub Release containing `ground-control-v0.1.<run_number>.apk`. Main-branch release jobs will use a shared concurrency group with cancellation disabled so close merges execute serially. Release publication will use GitHub-native tooling, such as the GitHub CLI with the workflow token, rather than a third-party release action. A one-time maintainer procedure will generate a persistent RSA-4096 JKS keystore outside the repository, retain a mode-`0600` backup under `~/.mothership/keys`, and populate `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_PASSWORD`, and `ANDROID_KEY_ALIAS` as GitHub Actions secrets without placing private material in the branch or subagent context. The existing README will document GitHub Release and Obtainium usage plus the signing-secret contract.

## Spec identifier

`ground-control-android-releases`

## Current state

The repository currently has only `.github/workflows/agentic-review.yml`; `android/app/build.gradle.kts` hardcodes `versionCode 1` and `versionName 0.1.0` and has no release signing configuration; no tags or GitHub Releases exist; and `OPENROUTER_API_KEY` is the only existing repository secret.

## Version and artifact contract

For GitHub workflow run number `N`, the Android build uses `versionCode N` and `versionName 0.1.N`; the Git tag and GitHub Release tag are `v0.1.N`; and the release asset is `ground-control-v0.1.N.apk`. The run number is the sole patch-version source and provides monotonically increasing Android versions without major/minor inference.

## Signing-key contract

One persistent RSA-4096 key in JKS format signs every release. It is generated outside the repository, backed up under `~/.mothership/keys` with mode `0600`, and represented in GitHub Actions by a base64-encoded keystore plus separate store-password, key-password, and alias secrets. The keystore and plaintext credentials must never enter Git history, branch content, pull-request execution, logs, artifacts, caches, or subagent context.

## Workflow security boundaries

Pull-request verification is unprivileged and read-only. Signing secrets and `contents: write` are available only to the trusted release job triggered by pushes to `main`. The release job must avoid secret interpolation into command output, must not upload the decoded keystore as an artifact or cache entry, and must clean up ephemeral private files even when a build or publication step fails.

## Release ordering

All `main` release jobs share one concurrency group with `cancel-in-progress: false`. Each queued run retains its own `github.run_number`, and successful runs publish only the tag, release, and APK name derived from that number.
