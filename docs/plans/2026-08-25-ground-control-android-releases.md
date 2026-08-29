# Ground Control Automatic Signed Android Releases Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a signed, monotonically versioned Ground Control APK as a GitHub Release after every successful push to `main`, while keeping pull-request verification read-only and secret-free.

## Assumptions checked

- repo topology — covered: one affected repository, `ground-control`; Android sources and Gradle wrapper live under `android/`.
- credential locus — covered: the private JKS and passwords remain outside git in `~/.mothership/keys` and GitHub Actions repository secrets.
- execution locus — covered: verification and release builds run on GitHub-hosted Ubuntu runners with JDK 17 and the Android SDK.
- state durability — covered: the persistent signing-key backup, Git tags, GitHub Releases, APK assets, workflow run number, and Android version metadata carry release state.
- review surface — covered: all tracked changes arrive through a dedicated Ground Control pull request; pull-request CI has read-only permissions.
- agent stream — N/A: this delivery pipeline does not consume or produce an interactive agent event stream.
- dispatched model — covered: one standalone Mothership implementer owns the isolated task and opens the PR; model selection is inherited from workspace dispatch configuration.

**Architecture:** A single GitHub Actions workflow separates an unprivileged `verify` job from a main-only `release` job. Gradle accepts optional version properties and release-signing environment variables; the release job decodes the repository secret into runner-temporary storage, builds and verifies the APK, then uses GitHub CLI to push the tag and create the versioned Release asset.

**Tech Stack:** GitHub Actions, GitHub CLI, Gradle Kotlin DSL, Android Gradle Plugin 8.5.2, Kotlin 2.0.0, JDK 17, Android SDK `apksigner`, JKS RSA-4096 signing.

**Spec:** `ground-control-android-releases` — `specs/2026-08-25-ground-control-android-releases.md`

## Global Constraints

- Pull-request jobs use `contents: read` and never receive Android signing secrets.
- The main-only release job uses `contents: write` solely to create its tag and GitHub Release.
- Android `versionCode` equals `github.run_number`; for run number `N`, `versionName`, tag, release title, and APK asset version equal `0.1.N`.
- Release concurrency is serialized with `cancel-in-progress: false`.
- The signing key is never committed, printed, or placed in subagent context.
- Release publication must stop before tagging when the APK is unsigned or signature verification fails.
- Play Store publishing, iOS distribution, and automatic major/minor inference remain out of scope.

---

<!-- mship:task id=1 acs=ac1,ac2,ac3,ac4,ac5,ac6,ac7,ac8,ac9,ac10,ac11,ac12,ac13,ac14,ac15,ac16,ac17,ac18,ac19,ac20,ac21,ac22,ac23,ac24,ac25 -->
### Task 1: Build the signed GitHub Release pipeline

**Files:**
- Create: `.github/workflows/android.yml`
- Modify: `android/app/build.gradle.kts:1-38`
- Modify: `README.md:27-39`

**Interfaces:**
- Consumes: Gradle properties `versionCode` and `versionName`; environment variables `ANDROID_KEYSTORE_PATH`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_PASSWORD`, and `ANDROID_KEY_ALIAS`; GitHub secret `ANDROID_KEYSTORE_BASE64`; GitHub context `github.run_number`.
- Produces: signed `android/app/build/outputs/apk/release/app-release.apk`, tag/release `v0.1.N`, asset `ground-control-v0.1.N.apk`, and read-only PR verification.

- [ ] **Step 1: Make Android versioning and signing injectable without changing local defaults**

In `android/app/build.gradle.kts`, derive the build metadata once before `android {}`:

```kotlin
val releaseVersionCode = providers.gradleProperty("versionCode").orNull?.toIntOrNull() ?: 1
val releaseVersionName = providers.gradleProperty("versionName").orNull ?: "0.1.0"
val releaseKeystorePath = providers.environmentVariable("ANDROID_KEYSTORE_PATH").orNull
val releaseStorePassword = providers.environmentVariable("ANDROID_KEYSTORE_PASSWORD").orNull
val releaseKeyPassword = providers.environmentVariable("ANDROID_KEY_PASSWORD").orNull
val releaseKeyAlias = providers.environmentVariable("ANDROID_KEY_ALIAS").orNull
val releaseSigningValues = listOf(
    releaseKeystorePath,
    releaseStorePassword,
    releaseKeyPassword,
    releaseKeyAlias,
)
val releaseSigningRequested = releaseSigningValues.any { !it.isNullOrBlank() }
require(!releaseSigningRequested || releaseSigningValues.all { !it.isNullOrBlank() }) {
    "Release signing requires ANDROID_KEYSTORE_PATH, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_PASSWORD, and ANDROID_KEY_ALIAS"
}
```

Use `releaseVersionCode` and `releaseVersionName` in `defaultConfig`. Create a `release` signing config only when all signing values are present, and attach it only to the release build type:

```kotlin
signingConfigs {
    if (releaseSigningRequested) {
        create("release") {
            storeFile = file(releaseKeystorePath!!)
            storePassword = releaseStorePassword
            keyAlias = releaseKeyAlias
            keyPassword = releaseKeyPassword
        }
    }
}

buildTypes {
    release {
        isMinifyEnabled = false
        proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        if (releaseSigningRequested) {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}
```

Do not add secret defaults or a committed keystore path.

- [ ] **Step 2: Smoke-test Gradle defaults before adding the workflow**

Run:

```bash
source "$HOME/toolchains/android-env.sh"
cd android
./gradlew testDebugUnitTest lintDebug assembleDebug --stacktrace
```

Expected: all tasks pass; local debug version remains `versionCode=1`, `versionName=0.1.0`.

- [ ] **Step 3: Create the split verification/release workflow**

Create `.github/workflows/android.yml` with these invariants:

```yaml
name: Android

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: "17"
      - uses: gradle/actions/setup-gradle@v4
      - name: Verify Android app
        working-directory: android
        run: ./gradlew testDebugUnitTest lintDebug assembleDebug --stacktrace

  release:
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    needs: verify
    runs-on: ubuntu-latest
    permissions:
      contents: write
    concurrency:
      group: ground-control-android-release
      cancel-in-progress: false
    env:
      VERSION_CODE: ${{ github.run_number }}
      VERSION_NAME: 0.1.${{ github.run_number }}
      TAG_NAME: v0.1.${{ github.run_number }}
      APK_NAME: ground-control-v0.1.${{ github.run_number }}.apk
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: "17"
      - uses: gradle/actions/setup-gradle@v4
```

Add release steps that:

1. Validate all four signing secrets are non-empty without printing values.
2. Decode `ANDROID_KEYSTORE_BASE64` into `$RUNNER_TEMP/ground-control-release.jks`.
3. Run `assembleRelease` with `-PversionCode="$VERSION_CODE"` and `-PversionName="$VERSION_NAME"`, passing the four signing environment variables only to this step.
4. Copy the output to `$RUNNER_TEMP/$APK_NAME`.
5. Resolve the newest installed Android SDK `apksigner` and run `apksigner verify --verbose --print-certs` before publication.
6. Refuse to overwrite an existing remote tag with the same name.
7. Configure the Git author as `github-actions[bot]`, create/push `$TAG_NAME`, and run:

```bash
gh release create "$TAG_NAME" "$RUNNER_TEMP/$APK_NAME#$APK_NAME" \
  --verify-tag \
  --title "$TAG_NAME" \
  --generate-notes
```

8. Remove the temporary keystore and APK in a final `if: always()` cleanup step.

Set `GH_TOKEN: ${{ github.token }}` only on the publication step. Never expose signing secrets at workflow, PR job, or verification-job scope.

- [ ] **Step 4: Document signing recovery and Obtainium installation**

Extend `README.md` with an `Android releases` section that states:

- every successful main merge publishes `ground-control-v0.1.N.apk` under GitHub Releases;
- Obtainium source URL is `https://github.com/atomikpanda/ground-control` and the APK asset is selected from the latest release;
- all updates must use the same signing certificate;
- the local key and credential backup paths are `~/.mothership/keys/ground-control-release.jks` and `~/.mothership/keys/ground-control-release.env`, both mode `0600`;
- `ANDROID_KEYSTORE_BASE64` is the single-line base64 JKS, while the other three secrets hold the store password, key password, and alias;
- private material must never be committed, logged, sent to pull-request jobs, or copied into agent context.

Include the exact operator commands, using local shell variables rather than literal passwords:

```bash
install -d -m 700 "$HOME/.mothership/keys"
keytool -genkeypair -v \
  -storetype JKS \
  -keystore "$HOME/.mothership/keys/ground-control-release.jks" \
  -alias ground-control \
  -keyalg RSA -keysize 4096 -validity 10000 \
  -dname "CN=Ground Control, O=Atomik Panda" \
  -storepass "$ANDROID_KEYSTORE_PASSWORD" \
  -keypass "$ANDROID_KEY_PASSWORD"
chmod 600 "$HOME/.mothership/keys/ground-control-release.jks" \
  "$HOME/.mothership/keys/ground-control-release.env"
keytool -list -v \
  -keystore "$HOME/.mothership/keys/ground-control-release.jks" \
  -storepass "$ANDROID_KEYSTORE_PASSWORD"
```

- [ ] **Step 5: Prove the signed release contract locally with a disposable key**

Generate a temporary JKS under a `mktemp -d` directory with alias `ground-control-test`, RSA-4096, and non-production passwords. Then run:

```bash
source "$HOME/toolchains/android-env.sh"
cd android
ANDROID_KEYSTORE_PATH="$TMP_KEYSTORE" \
ANDROID_KEYSTORE_PASSWORD="$TMP_STORE_PASSWORD" \
ANDROID_KEY_PASSWORD="$TMP_KEY_PASSWORD" \
ANDROID_KEY_ALIAS="ground-control-test" \
./gradlew assembleRelease \
  -PversionCode=42 \
  -PversionName=0.1.42 \
  --stacktrace
```

Verify the produced APK with the newest `$ANDROID_HOME/build-tools/*/apksigner` and use `apkanalyzer manifest version-code` / `manifest version-name` to confirm `42` and `0.1.42`. Delete the disposable key directory afterward.

- [ ] **Step 6: Run repository verification**

Run from the Ground Control task worktree:

```bash
mship test
mship build
```

Expected: both commands pass. Inspect `.github/workflows/android.yml` with a YAML parser or `actionlint` if installed, and confirm the PR event cannot reach the release job or any signing-secret expression.

- [ ] **Step 7: Commit, journal, and open the standalone PR**

```bash
git add .github/workflows/android.yml android/app/build.gradle.kts README.md
git commit -m "Add signed Android release pipeline"
mship journal "implemented automatic signed Android releases for Obtainium; tests and builds passing" --action committed --test-state pass
```

Use `mship finish` with a PR body that names the signing-secret prerequisite and includes the Gradle smoke results. Do not create an initial GitHub Release from the feature branch; the first release is produced only after the PR merges to `main`.
<!-- /mship:task -->
