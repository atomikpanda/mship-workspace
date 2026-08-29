# Relay Directory Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform and validate an entire relay directory before atomically replacing the cached fleet, while preserving auth/outage classifications.

## Assumptions checked

- repo topology — covered: only Ground Control Android changes on PR #77.
- credential locus — covered: relay fleet and host refresh credentials stay in existing DataStore records.
- execution locus — covered: Ktor decodes transport DTOs, a pure transformer canonicalizes/validates, and DataStore performs one accepted replacement.
- state durability — covered: existing `HostConnection` and `WorkspaceConnection` cache formats remain readable; no schema migration.
- review surface — covered: PR #77 with DTO transformer, cache atomicity, and Settings error-classification JVM tests.
- agent stream — covered: one task worker executes transformer, repository integration, and verification tasks in order.
- dispatched model — covered: use the task's configured Mothership implementation model.

**Architecture:** Keep `SpecApi.listHosts` responsible only for decoding `HostsResponse`. A dedicated `RelayDirectoryTransformer` canonicalizes each candidate route once, validates the complete fleet, and either returns a fully usable domain list or throws `InvalidRelayDirectoryException`; only that complete list reaches one generation-checked DataStore replacement.

**Tech Stack:** Kotlin, Ktor, kotlinx.serialization, Android DataStore Preferences, JUnit 4, Ktor MockEngine.

**Spec:** `ground-control-relay-directory-boundary` — `specs/2026-08-21-ground-control-relay-directory-boundary.md`

**Command root:** Run every command from the assigned `relay-directory-errors/ground-control` worktree root. Gradle commands use `(cd android && ./gradlew …)`.

## Global Constraints

- Ground Control Android only; no server payload, wire protocol, backend, cache schema, or other-client changes.
- Candidate route strings with surrounding whitespace are rejected, not repaired.
- Canonicalize each candidate route exactly once at DTO-to-domain transformation and reuse that value downstream.
- Reject the complete authoritative response for malformed hosts, duplicate canonical identities, invalid host-state identity, or unusable routes.
- No cache write occurs before complete transformation succeeds; observers never receive a partial fleet.
- Invalid authoritative data preserves the cached fleet and remains distinct from authentication and outage failures.

---

<!-- mship:task id=1 acs=ac1,ac2,ac3,ac4,ac5,ac6,ac7,ac8,ac9,ac10,ac15,ac17 -->
### Task 1: Add the all-or-nothing DTO transformer

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/dto/Dtos.kt:46-69`
- Create: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/RelayDirectoryTransformer.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/HostConnection.kt:238-328`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/HostLadder.kt:62-65`
- Create: `android/app/src/test/java/com/atomikpanda/groundcontrol/RelayDirectoryTransformerTest.kt`

**Interfaces:**
- Consumes: `HostsResponse`, relay domain, and `normalizedBaseUrl` injected as a canonicalizer for deterministic invocation-count tests.
- Produces: `RelayDirectoryTransformer.transform(response, relayDomain): ValidatedRelayDirectory` and `InvalidRelayDirectoryException`; repository replacement accepts only the wrapper, whose designated construction owner is the transformer.

- [ ] **Step 1: Write complete-fleet transformation tests**

```kotlin
@Test fun canonicalizes_each_valid_route_once_and_reuses_result() {
    val calls = mutableListOf<String>()
    val transformer = RelayDirectoryTransformer { raw ->
        calls += raw
        normalizedBaseUrl(raw)
    }
    val fleet = transformer.transform(validResponse("HTTPS://HOST.TEST/root/"), "relay.test")
    assertEquals(listOf("HTTPS://HOST.TEST/root/"), calls)
    assertEquals("https://host.test/root", fleet.single().publicUrl)
}

@Test fun canonical_equivalent_duplicate_routes_reject_whole_response() {
    val response = HostsResponse(listOf(
        hostInfo(hostId = "h1", publicUrl = "https://HOST.test/root/"),
        hostInfo(hostId = "h2", publicUrl = "https://host.test/root"),
    ))
    assertFailsWith<InvalidRelayDirectoryException> {
        RelayDirectoryTransformer().transform(response, "relay.test")
    }
}

@Test fun supported_pending_state_requires_request_id_and_route_but_not_host_id() {
    val pending = hostInfo(
        hostId = null,
        state = "pending-approval",
        requestId = "request-1",
        publicUrl = "https://pending.relay.test",
    )
    assertEquals("pending:request-1", transformer.transform(HostsResponse(listOf(pending)), "relay.test").hosts.single().hostId)
    assertFailsWith<InvalidRelayDirectoryException> {
        transformer.transform(HostsResponse(listOf(pending.copy(state = "offline"))), "relay.test")
    }
}
```

Add cases for duplicate host IDs, duplicate pending request identities, non-pending missing/blank IDs, both supported pending states (`pending-approval`, `awaiting-enrollment`), missing pending request ID, empty/unusable `public_url`, padded route, malformed/unsupported route, canonical-equivalent route duplicates, and a failure in a later entry after earlier valid entries. `HostInfo` has exactly one route field, `publicUrl`; no synthetic route collection or unowned DTO abstraction is introduced.

- [ ] **Step 2: Run transformer tests and verify RED**

```bash
(cd android && ./gradlew :app:testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.RelayDirectoryTransformerTest')
```

Expected: FAIL because the transformer does not exist and `hostsFrom` mixes conversion with downstream assumptions.

- [ ] **Step 3: Implement the dedicated transformer**

```kotlin
class InvalidRelayDirectoryException(message: String) : IllegalArgumentException(message)

internal data class ValidatedRelayDirectory internal constructor(
    val hosts: List<HostConnection>,
)

internal class RelayDirectoryTransformer(
    private val canonicalize: (String) -> String? = ::normalizedBaseUrl,
) {
    fun transform(response: HostsResponse, relayDomain: String): ValidatedRelayDirectory {
        val identities = mutableSetOf<String>()
        val routes = mutableSetOf<String>()
        val hosts = response.hosts.map { info ->
            val pending = isSupportedPendingHostState(info.state)
            val identity = info.hostId?.takeIf(String::isNotBlank)
                ?: info.requestId?.takeIf { pending && it.isNotBlank() }?.let { "pending:$it" }
                ?: throw InvalidRelayDirectoryException("Relay host identity is missing")
            if (!identities.add(identity)) {
                throw InvalidRelayDirectoryException("Relay host identity is duplicated")
            }
            if (info.publicUrl != info.publicUrl.trim()) {
                throw InvalidRelayDirectoryException("Relay host route contains padding")
            }
            val route = canonicalize(info.publicUrl)
                ?: throw InvalidRelayDirectoryException("Relay host route is unusable")
            if (!routes.add(route)) {
                throw InvalidRelayDirectoryException("Relay host route identity is duplicated")
            }
            HostConnection(
                hostId = identity,
                label = info.label,
                subdomain = info.subdomain,
                publicUrl = route,
                state = info.state,
                refresh = info.refresh,
                relayDomain = relayDomain,
                lastSeen = info.lastSeen,
                runnerState = info.runner?.state,
                requestId = info.requestId,
            )
        }
        return ValidatedRelayDirectory(hosts)
    }
}
```

Move the existing pending-state set from `HostLadder.kt` behind one internal `isSupportedPendingHostState` owner and reuse it in both ladder and transformer; do not restate the values. `HostInfo.publicUrl` is the only relay-directory route field and is required for every row, including pending rows. Pending rows retain the existing persisted `pending:<requestId>` identity until a stable host ID arrives. Preserve canonicalized path roots exactly as `normalizedBaseUrl` defines them. Remove `hostFrom`/`hostsFrom` after callers move. Keep `upsertHost` normalization for local/legacy inputs. Add `replaceValidatedRelayHosts(existing, relayDomain, ValidatedRelayDirectory)`: it replaces that relay's rows by host ID, copies each validated row's `publicUrl` verbatim, and carries only prior operator-owned `labelOverride`/`directUrl`, omitted refresh, contact time, and normalized historical aliases. It must not route the validated row through `upsertHost` or pass its `publicUrl` to `normalizedBaseUrl`.

- [ ] **Step 4: Run transformer tests and verify GREEN**

Run the command from Step 2.

Expected: PASS for all valid/invalid fixtures and exact canonicalizer invocation counts.

- [ ] **Step 5: Commit the boundary transformer**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/data/dto/Dtos.kt android/app/src/main/java/com/atomikpanda/groundcontrol/data/RelayDirectoryTransformer.kt android/app/src/main/java/com/atomikpanda/groundcontrol/data/HostConnection.kt android/app/src/main/java/com/atomikpanda/groundcontrol/data/HostLadder.kt android/app/src/test/java/com/atomikpanda/groundcontrol/RelayDirectoryTransformerTest.kt
git commit -m "feat: validate relay directory at DTO boundary"
mship journal "added one-pass all-or-nothing relay DTO transformer with canonical identity validation; focused tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 acs=ac9,ac10,ac11,ac12,ac13,ac14,ac15,ac16,ac17 -->
### Task 2: Apply only complete transformed fleets

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/MshipClient.kt:695-700`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/HostsRepository.kt:281-365`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/ConnectionsRepository.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/settings/SettingsViewModel.kt:57-101,438-480`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/HostsRepositoryTest.kt`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/SettingsFleetTest.kt`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/HostWorkspacesTest.kt`

**Interfaces:**
- Consumes: decoded `HostsResponse`, one constructor-injected `RelayDirectoryTransformer` in `SettingsViewModel`, and `ValidatedRelayDirectory` at the repository boundary.
- Produces: one generation-checked `HostsRepository.replaceValidatedRelayDirectory` transaction after transformation, plus distinct invalid-data/auth/outage failure mapping.

- [ ] **Step 1: Write cache and classification regressions**

```kotlin
@Test fun nested_transformation_failure_preserves_exact_cached_fleet() = runTest {
    val dataStore = temporaryPreferencesDataStore()
    val repository = HostsRepository(dataStore)
    repository.seedHosts(cachedFleet)
    val emissions = mutableListOf<List<HostConnection>>()
    backgroundScope.launch(start = CoroutineStart.UNDISPATCHED) {
        repository.hosts.collect { emissions += it }
    }
    val vm = viewModel(
        repository = repository,
        response = responseWithValidThenMalformedEntry(),
        transformer = transformer,
    )
    vm.refreshFleetNow().join()
    runCurrent()
    assertEquals(cachedFleet, repository.snapshot())
    assertEquals(listOf(cachedFleet), emissions.distinct())
    assertEquals("Relay returned malformed host data — showing last known hosts", vm.testResult.value)
}

@Test fun valid_authoritative_response_replaces_cache_in_one_observed_snapshot() = runTest {
    val dataStore = temporaryPreferencesDataStore()
    val repository = HostsRepository(dataStore)
    repository.seedHosts(oldFleet)
    val emissions = mutableListOf<List<HostConnection>>()
    backgroundScope.launch(start = CoroutineStart.UNDISPATCHED) {
        repository.hosts.collect { emissions += it }
    }
    val vm = viewModel(repository = repository, response = validResponse)
    vm.refreshFleetNow().join()
    runCurrent()
    assertEquals(listOf(oldFleet, expectedFleet), emissions.distinct())
    assertEquals(expectedFleet, repository.snapshot())
}
```

Use `PreferenceDataStoreFactory.create(scope = backgroundScope, produceFile = temporaryFolder::newFile)` and the real repositories; no spy replacement API is sufficient evidence for atomicity. Add internal `DataStore<Preferences>` constructors to `HostsRepository` and `ConnectionsRepository` while preserving their production context constructors. Define the test `viewModel(...)` factory with those repositories, a `SpecApi` backed by `MockEngine`, a small fake `NotificationsSetting`, the injected transformer, and `testScope = backgroundScope`. `SettingsViewModel` uses `testScope ?: viewModelScope` for every launch/state owner and changes `refreshFleetNow()` to return its `Job`, so `.join()` and `runCurrent()` are deterministic without an Android Main dispatcher. Add a later generation between transform and commit and assert the stale candidate performs no write. Retain tests asserting `AuthException` maps to re-pair without cache mutation and timeout/connectivity maps to outage/unknown state using the existing policy.


- [ ] **Step 2: Run Settings fleet tests and verify RED**

```bash
(cd android && ./gradlew :app:testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.HostsRepositoryTest' --tests 'com.atomikpanda.groundcontrol.SettingsFleetTest')
```

Expected: transport returns a list instead of an intact response or conversion/classification remains split across layers.

- [ ] **Step 3: Wire decode → transform → single replacement**

```kotlin
suspend fun listHosts(relayDomain: String, fleetToken: String): HostsResponse =
    client.get("${enrollBaseUrl(relayDomain)}$HOSTS_PATH") {
        header(FLEET_TOKEN_HEADER, fleetToken)
    }.bodyAfterHostContact()
```

Give `SettingsViewModel` constructor parameters `transformer: RelayDirectoryTransformer = RelayDirectoryTransformer()` and `testScope: CoroutineScope? = null`; thread them through the explicit test factory above. This is the sole production transformation owner. In `refreshFleet`, decode `HostsResponse`, set `entryCount = response.hosts.size`, then call `transformer.transform(response, account.relayDomain)` inside the invalid-authoritative-data branch. Call `hosts.replaceValidatedRelayDirectory(account, candidate, expectedGeneration)` exactly once and only with the complete wrapper. That repository method runs one `DataStore.edit`, rechecks relay account and generation inside the edit, calls only `replaceValidatedRelayHosts` for incoming directory rows, preserves operator fields, replaces the relay fleet, and writes hosts/connections once. Redesign route-ownership generation comparison to accept the validated candidate's exact `hostId → publicUrl` map: use those already-canonical values verbatim for matching updated hosts, while legacy/local previous hosts, direct URLs, connection URLs, historical aliases, and noncandidate hosts still pass through `routeIdentity`. Thus neither merge nor generation accounting invokes `normalizedBaseUrl` on a validated public route. Add an end-to-end Settings test whose injected canonicalizer returns a valid sentinel route that a second normalization would change; assert one canonicalizer call and that the exact sentinel is persisted after the real merge/generation/commit path.

Because `SpecApi.listHosts` now returns `HostsResponse`, update `HostWorkspacesTest.listHosts_reads_the_directory_with_the_fleet_token` to bind `response`, then assert `response.hosts.size`, `response.hosts[0]`, and `response.hosts[1]`. Keep this test transport-only; transformation assertions remain in `RelayDirectoryTransformerTest`.

- [ ] **Step 4: Run Settings fleet tests and verify GREEN**

Run the command from Step 2.

Expected: valid replacement is one observed DataStore snapshot; malformed, absent, null, wrongly typed, nested-invalid, and stale-generation candidates preserve exact cache bytes/state; auth and outage classifications remain unchanged.

- [ ] **Step 5: Commit atomic integration**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/data/MshipClient.kt android/app/src/main/java/com/atomikpanda/groundcontrol/data/HostsRepository.kt android/app/src/main/java/com/atomikpanda/groundcontrol/data/ConnectionsRepository.kt android/app/src/main/java/com/atomikpanda/groundcontrol/ui/settings/SettingsViewModel.kt android/app/src/test/java/com/atomikpanda/groundcontrol/HostsRepositoryTest.kt android/app/src/test/java/com/atomikpanda/groundcontrol/SettingsFleetTest.kt android/app/src/test/java/com/atomikpanda/groundcontrol/HostWorkspacesTest.kt
git commit -m "fix: replace relay cache only after full validation"
mship journal "wired decoded relay response through transformer before one cache replacement; invalid/auth/outage classifications tested" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 acs=ac1,ac2,ac3,ac4,ac5,ac6,ac7,ac8,ac9,ac10,ac11,ac12,ac13,ac14,ac15,ac16,ac17,ac18 -->
### Task 3: Verify compatibility and complete boundary behavior

**Files:**
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/RelayDirectoryTransformerTest.kt`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/SettingsFleetTest.kt`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/HostsRepositoryTest.kt`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/HostWorkspacesTest.kt`
- Modify only if a failing observable contract requires it: production files listed in Tasks 1-2.

**Interfaces:**
- Consumes: completed transport, transformer, and repository boundary.
- Produces: PR #77 task-scoped evidence.

- [ ] **Step 1: Add accepted-wire and old-cache compatibility cases**

Freeze accepted wire fixtures as literal JSON copied unchanged from frozen PR #77 tests, not builders that silently inherit new defaults. Include the frozen HTTPS and path-root forms that already satisfy the approved rules. Add separate explicit valid fixtures for HTTP/LAN with port and both supported pending states with request IDs and valid `public_url`; the frozen pending row without a route remains unchanged as a rejection/compatibility-boundary fixture. Decode with the real configured `Json` and assert the complete expected `HostConnection` values.

```kotlin
@Test fun frozen_valid_wire_fixtures_produce_exact_domain_fleet() {
    val response = frozenJson.decodeFromString<HostsResponse>(FROZEN_VALID_DIRECTORY_JSON)
    val actual = RelayDirectoryTransformer().transform(response, "relay.test")
    assertEquals(FROZEN_EXPECTED_FLEET, actual.hosts)
}

@Test fun old_cached_fleet_survives_failed_new_refresh_without_rewrite() = runTest {
    val encoded = FROZEN_PREVIOUS_ANDROID_CACHE_JSON
    repository.seedEncodedHosts(encoded)
    val vm = viewModel(repository = repository, response = malformedResponse())
    vm.refreshFleetNow().join()
    assertEquals(encoded, repository.rawHostsValue())
    assertEquals(legacyCachedFleet, repository.snapshot())
}
```

Add the transformer-to-repository sentinel test from Task 2: its injected canonicalizer records exactly one call per row and returns a valid route spelling that another normalization would change; the real replacement/generation commit must persist that exact spelling. Add an interceptor-side consumer test proving the persisted path-root URL is used verbatim for a workspace request.

- [ ] **Step 2: Run all boundary tests**

```bash
(cd android && ./gradlew :app:testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.RelayDirectoryTransformerTest' --tests 'com.atomikpanda.groundcontrol.HostsRepositoryTest' --tests 'com.atomikpanda.groundcontrol.SettingsFleetTest' --tests 'com.atomikpanda.groundcontrol.HostWorkspacesTest')
```

Expected: BUILD SUCCESSFUL with valid payload, duplicate, pending/non-pending identity, route, malformed-hosts, nested-failure, atomic replacement, cache preservation, auth, outage, and compatibility coverage.

- [ ] **Step 3: Compile the affected Android module**

```bash
(cd android && ./gradlew :app:compileDebugKotlin)
```

Expected: BUILD SUCCESSFUL; no `hostFrom` or `hostsFrom` callsites remain.

- [ ] **Step 4: Commit compatibility coverage**

```bash
git add android/app/src/test/java/com/atomikpanda/groundcontrol/RelayDirectoryTransformerTest.kt android/app/src/test/java/com/atomikpanda/groundcontrol/SettingsFleetTest.kt android/app/src/test/java/com/atomikpanda/groundcontrol/HostsRepositoryTest.kt android/app/src/test/java/com/atomikpanda/groundcontrol/HostWorkspacesTest.kt
git commit -m "test: verify relay directory compatibility"
```

- [ ] **Step 5: Run Mothership task verification**

```bash
mship test --task relay-directory-errors
mship journal "relay directory boundary complete: one-pass canonical transformation, full-fleet validation, atomic cache replacement, and preserved failure classifications; task suite passing" --action verified
```

Expected: task test passes and records evidence.
<!-- /mship:task -->
