# Legacy Route Ownership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make legacy credential migration and request rerouting depend on one explicit, unambiguous host/workspace ownership result.

## Assumptions checked

- repo topology — covered: only the `ground-control` Android member changes; the existing PR #72 branch is the implementation branch.
- credential locus — covered: refresh and direct credentials remain in the existing DataStore-backed host/connection records.
- execution locus — covered: parsing is pure Kotlin; repository mutations remain inside DataStore `edit`; request routing remains in the Ktor client interceptor.
- state durability — covered: existing `WorkspaceConnection`, `HostConnection`, and route-ownership generation records remain the durable source of truth.
- review surface — covered: PR #72 plus focused JVM tests for parser, repository, settings refresh, and interceptor behavior.
- agent stream — covered: one task-scoped worker implements the anchored tasks in order and journals every commit.
- dispatched model — covered: use the task's configured Mothership implementation model; no external runtime is required.

**Architecture:** Replace the overlapping `legacyWorkspaceId` and `knownHostsForLegacyConnection` inference paths with one parser returning `Owned`, `Unknown`, or `Ambiguous`. Every repository and interceptor caller supplies the complete candidate host set and performs stored-versus-derived identity agreement before changing credentials, connections, or request URLs.

**Tech Stack:** Kotlin, Android DataStore Preferences, Ktor client interceptors, kotlinx.serialization, JUnit 4, kotlinx-coroutines-test.

**Spec:** `ground-control-ownership-evidence` — `specs/2026-08-21-ground-control-ownership-evidence.md`

**Command root:** Run every command from the assigned `legacy-route-ownership/ground-control` worktree root. Gradle commands use a subshell, `(cd android && ./gradlew …)`, so subsequent Git and Mothership commands remain at the repository root.

## Global Constraints

- Ground Control Android only; no backend, relay protocol, wire-format, or other-client changes.
- Unknown URL bases never become implicit host roots.
- Pathful host roots and complete path-segment boundaries are preserved.
- Duplicate host IDs are rejected before any cache or persisted-state mutation.
- Credential migration and rerouting require unique URL evidence plus agreement with every stored ownership ID that is present.
- Existing persisted records and recognized current/historical routes remain readable without a schema migration.

---

<!-- mship:task id=1 acs=ac1,ac2,ac3,ac4,ac5,ac6,ac18,ac19 -->
### Task 1: Canonical legacy ownership parser

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/WorkspaceConnection.kt:288-377`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/ConnectionsCodecTest.kt`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/HostWorkspacesTest.kt`

**Interfaces:**
- Consumes: `WorkspaceConnection`, `HostConnection.hostBases()`, and `HostConnection.legacyPublicUrls`.
- Produces: `LegacyRouteOwnership`, `LegacyRouteOwnership.Owned(hostId, hostBase, workspaceId)`, and `legacyRouteOwnership(connection, candidateHosts)`.

- [ ] **Step 1: Write parser contract tests**

```kotlin
@Test fun legacy_route_ownership_preserves_pathful_host_root() {
    val host = HostConnection(hostId = "h1", publicUrl = "https://relay.test/gc")
    val conn = WorkspaceConnection("legacy", "https://relay.test/gc/workspaces/ws-1")
    assertEquals(
        LegacyRouteOwnership.Owned("h1", "https://relay.test/gc", "ws-1"),
        legacyRouteOwnership(conn, listOf(host)),
    )
}

@Test fun legacy_route_ownership_rejects_partial_prefix_and_unknown_base() {
    val host = HostConnection(hostId = "h1", publicUrl = "https://relay.test/gc")
    assertEquals(
        LegacyRouteOwnership.Unknown,
        legacyRouteOwnership(
            WorkspaceConnection("legacy", "https://relay.test/gc-admin/workspaces/ws-1"),
            listOf(host),
        ),
    )
}

@Test fun legacy_route_ownership_reports_multiple_valid_claims() {
    val hosts = listOf(
        HostConnection(hostId = "h1", publicUrl = "https://relay.test/gc"),
        HostConnection(hostId = "h2", publicUrl = "https://relay.test/gc"),
    )
    assertEquals(
        LegacyRouteOwnership.Ambiguous,
        legacyRouteOwnership(
            WorkspaceConnection("legacy", "https://relay.test/gc/workspaces/ws-1"),
            hosts,
        ),
    )
}
@Test fun legacy_route_ownership_accepts_recorded_historical_base() {
    val host = HostConnection(
        hostId = "h1",
        publicUrl = "https://current.test/root",
        legacyPublicUrls = listOf("https://old.test/root"),
    )
    assertEquals(
        LegacyRouteOwnership.Owned("h1", "https://old.test/root", "ws-1"),
        legacyRouteOwnership(
            WorkspaceConnection("legacy", "https://old.test/root/workspaces/ws-1"),
            listOf(host),
        ),
    )
}

@Test fun parser_ignores_stored_ids_when_candidate_host_is_absent() {
    val connection = WorkspaceConnection(
        id = "legacy",
        baseUrl = "https://known.test/root/workspaces/ws-1",
        hostId = "h1",
        workspaceId = "ws-1",
    )
    assertEquals(LegacyRouteOwnership.Unknown, legacyRouteOwnership(connection, emptyList()))
}

@Test fun parser_rejects_extra_segments_after_workspace_id() {
    val hostH1 = HostConnection(hostId = "h1", publicUrl = "https://known.test/root")
    val connection = WorkspaceConnection("legacy", "https://known.test/root/workspaces/ws-1/admin")
    assertEquals(LegacyRouteOwnership.Unknown, legacyRouteOwnership(connection, listOf(hostH1)))
}

@Test fun parser_retains_direct_identity_after_host_joins_relay() {
    val relayHost = HostConnection(
        hostId = "h1",
        directUrl = "https://direct.test/root",
        publicUrl = "https://relay.test/root",
        relayDomain = "relay.test",
        refresh = "refresh-token",
    )
    assertEquals(
        LegacyRouteOwnership.Owned("h1", "https://direct.test/root", "ws-1"),
        legacyRouteOwnership(
            WorkspaceConnection("legacy", "https://direct.test/root/workspaces/ws-1"),
            listOf(relayHost),
        ),
    )
}
```

- [ ] **Step 2: Run the parser tests and verify RED**

Run:

```bash
(cd android && ./gradlew :app:testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.ConnectionsCodecTest' --tests 'com.atomikpanda.groundcontrol.HostWorkspacesTest')
```

Expected: FAIL because `LegacyRouteOwnership` and `legacyRouteOwnership` do not exist.

- [ ] **Step 3: Replace split inference with one result type**

```kotlin
internal sealed interface LegacyRouteOwnership {
    data object Unknown : LegacyRouteOwnership
    data object Ambiguous : LegacyRouteOwnership
    data class Owned(
        val hostId: String,
        val hostBase: String,
        val workspaceId: String?,
    ) : LegacyRouteOwnership
}

internal fun legacyRouteOwnership(
    connection: WorkspaceConnection,
    candidateHosts: List<HostConnection>,
): LegacyRouteOwnership {
    val connectionBase = normalizedBaseUrl(connection.baseUrl)
        ?: return LegacyRouteOwnership.Unknown
    val claims = candidateHosts.flatMap { host ->
        if (host.hostId.isBlank()) return@flatMap emptyList()
        (listOfNotNull(host.directUrl, host.publicUrl) + host.legacyPublicUrls)
            .mapNotNull(::normalizedBaseUrl)
            .distinct()
            .mapNotNull { base -> ownershipClaim(connectionBase, host.hostId, base) }
    }.distinct()
    return when (claims.size) {
        0 -> LegacyRouteOwnership.Unknown
        1 -> claims.single()
        else -> LegacyRouteOwnership.Ambiguous
    }
}
```

Implement `ownershipClaim` in the same file using `URI` origin comparison and normalized raw path segments. A claim succeeds only when the connection path is exactly the candidate host-root path, or when its remaining segments are exactly `workspaces/{one nonblank workspaceId}`; sibling prefixes, encoded separators, dot segments, query/fragment-bearing bases, and extra suffix segments return no claim. Return the exact normalized candidate base, including any path root. Ownership candidates include direct, current public, and historical public identities even after relay adoption; `hostBases()` remains only the outbound-route selector. `legacyRouteOwnership` ignores stored `connection.hostId/workspaceId`; those are checked only by the side-effect agreement gate in Task 3. Remove `legacyWorkspaceId`, `knownHostsForLegacyConnection`, `knownHostForLegacyConnection`, and their private matching helpers after all callers move in Task 3.

- [ ] **Step 4: Run the parser tests and verify GREEN**

Run the command from Step 2.

Expected: PASS for current, direct-after-relay-adoption, and historical routes; pathful roots; sibling-prefix collisions; unknown bases; and ambiguous candidates.

- [ ] **Step 5: Commit parser ownership**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/data/WorkspaceConnection.kt android/app/src/test/java/com/atomikpanda/groundcontrol/ConnectionsCodecTest.kt android/app/src/test/java/com/atomikpanda/groundcontrol/HostWorkspacesTest.kt
git commit -m "refactor: centralize legacy route ownership"
mship journal "added canonical legacy route ownership parser; focused parser tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 acs=ac9,ac10,ac11,ac19 -->
### Task 2: Reject duplicate host identities atomically

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/HostConnection.kt:280-328`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/HostsRepository.kt:121-245,281-363`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/HostsRepositoryTest.kt`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/SettingsFleetTest.kt`

**Interfaces:**
- Consumes: relay-directory `HostConnection` candidates and existing `RelayAccountFleet` state.
- Produces: `validateUniqueHostIds(hosts: List<HostConnection>)`, invoked before all four ingress layers: pure directory replacement, repository directory replacement, pure account replacement, and repository account replacement.

- [ ] **Step 1: Write no-mutation duplicate tests**

Reuse `HostsRepositoryTest`'s `TemporaryFolder` and `PreferenceDataStoreFactory`. Add these test-local helpers; they deliberately snapshot raw encoded strings, not reconstructed models:

```kotlin
private val relayDomainKey = stringPreferencesKey("relay_domain")
private val relayFleetTokenKey = stringPreferencesKey("relay_fleet_token")

private data class RawRouteOwnershipState(
    val hostsEncoded: String?,
    val connectionsEncoded: String?,
    val relayDomain: String?,
    val relayFleetToken: String?,
    val generation: Long?,
) {
    val hosts get() = HostsCodec.decode(hostsEncoded.orEmpty())
    val connections get() = ConnectionsCodec.decode(connectionsEncoded.orEmpty())
    val account get() = relayDomain?.let { RelayAccount(it, relayFleetToken.orEmpty()) }
}

private fun relayHost(id: String, url: String, relayDomain: String = "relay.example") =
    HostConnection(hostId = id, publicUrl = url, relayDomain = relayDomain)

private val originalConnection =
    WorkspaceConnection("ws", "https://old.test/workspaces/ws", token = "secret")

private suspend fun seedRouteOwnership(
    dataStore: DataStore<Preferences>,
    account: RelayAccount,
    hosts: List<HostConnection>,
    connections: List<WorkspaceConnection>,
    generation: Long,
) = dataStore.edit {
    it[hostsKey] = HostsCodec.encode(hosts)
    it[connectionsKey] = ConnectionsCodec.encode(connections)
    it[relayDomainKey] = account.relayDomain
    it[relayFleetTokenKey] = account.fleetToken
    it[generationKey] = generation
}

private suspend fun rawRouteOwnershipState(dataStore: DataStore<Preferences>) =
    dataStore.data.first().let {
        RawRouteOwnershipState(
            it[hostsKey], it[connectionsKey], it[relayDomainKey],
            it[relayFleetTokenKey], it[generationKey],
        )
    }

private suspend fun assertIllegalArgument(block: suspend () -> Unit) {
    val error = try { block(); null } catch (caught: Throwable) { caught }
    assertTrue(error is IllegalArgumentException)
}

@Test fun every_directory_ingress_rejects_duplicates_before_mutation() = runTest {
    val duplicates = listOf(relayHost("dup", "https://one.test"), relayHost("dup", "https://two.test"))
    val dataStore = newDataStore("duplicate-directory.preferences_pb", backgroundScope)
    val account = RelayAccount("relay.example", "fleet-token")
    seedRouteOwnership(
        dataStore, account, listOf(relayHost("stable", "https://old.test")),
        listOf(originalConnection), 17L,
    )
    val repository = HostsRepository(dataStore)
    val before = rawRouteOwnershipState(dataStore)
    assertIllegalArgument {
        replaceRelayDirectoryFleet(account.relayDomain, before.hosts, duplicates, before.connections)
    }
    assertIllegalArgument {
        replaceRelayDirectoryFleet(
            account.relayDomain, duplicates,
            listOf(relayHost("stable", "https://new.test")), before.connections,
        )
    }
    assertIllegalArgument {
        repository.replaceFromRelay(account, before.generation!!, duplicates)
    }
    assertEquals(before, rawRouteOwnershipState(dataStore))
}

@Test fun every_account_ingress_rejects_stored_duplicates_before_mutation() = runTest {
    val dataStore = newDataStore("duplicate-account.preferences_pb", backgroundScope)
    val oldAccount = RelayAccount("old.example", "old-token")
    seedRouteOwnership(
        dataStore, oldAccount,
        listOf(
            relayHost("dup", "https://one.test", oldAccount.relayDomain),
            relayHost("dup", "https://two.test", oldAccount.relayDomain),
        ),
        listOf(originalConnection), 23L,
    )
    val repository = HostsRepository(dataStore)
    val before = rawRouteOwnershipState(dataStore)
    val replacement = RelayAccount("new.example", "new-token")
    assertIllegalArgument {
        replaceRelayAccountFleet(before.account, replacement, before.hosts, before.connections)
    }
    assertIllegalArgument { repository.setRelayAccount(replacement) }
    assertEquals(before, rawRouteOwnershipState(dataStore))
}
```

Add direct cases for a duplicate appearing at the beginning/end, duplicated synthetic `pending:<requestId>` identities, and a valid distinct list preserving order.

- [ ] **Step 2: Run duplicate-ingress tests and verify RED**

Run:

```bash
(cd android && ./gradlew :app:testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.HostsRepositoryTest' --tests 'com.atomikpanda.groundcontrol.SettingsFleetTest')
```

Expected: at least one duplicate path mutates or accepts data before rejection.

- [ ] **Step 3: Validate before entering DataStore mutation logic**

```kotlin
internal fun validateUniqueHostIds(hosts: List<HostConnection>) {
    require(hosts.all { it.hostId.isNotBlank() }) { "Host identity is required" }
    require(hosts.map(HostConnection::hostId).distinct().size == hosts.size) {
        "Duplicate host identities cannot establish route ownership"
    }
}
```

Invoke the validator on both `existingHosts` and `replacementHosts` at entry to `replaceRelayDirectoryFleet`; validate every host list consumed by `replaceRelayAccountFleet` as well. `HostsRepository.replaceFromRelay` and `HostsRepository.setRelayAccount` validate incoming candidates before entering `DataStore.edit`, then repeat validation inside the edit after decoding current persisted hosts to defend against concurrent/corrupt input. No code may assign `applied`, write `HOSTS`/`CONNECTIONS`/account fields, advance generation, or reorder a list until every participating host snapshot is validated and pure replacement completes successfully.

- [ ] **Step 4: Run duplicate-ingress tests and verify GREEN**

Run the command from Step 2.

Expected: PASS; raw hosts/connections/account strings, visible ordering, and generation remain byte-for-byte unchanged on every rejection path.

- [ ] **Step 5: Commit ingress validation**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/data/HostConnection.kt android/app/src/main/java/com/atomikpanda/groundcontrol/data/HostsRepository.kt android/app/src/test/java/com/atomikpanda/groundcontrol/HostsRepositoryTest.kt android/app/src/test/java/com/atomikpanda/groundcontrol/SettingsFleetTest.kt
git commit -m "fix: reject duplicate host identity ingress"
mship journal "rejected duplicate directory and account host ids before cache mutation; focused tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 acs=ac7,ac8,ac12,ac13,ac14,ac15,ac16,ac17,ac18,ac19 -->
### Task 3: Enforce evidence agreement at mutation and routing callers

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/WorkspaceConnection.kt:267-486`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/HostsRepository.kt:121-481`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/ConnectionsRepository.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/MshipClient.kt`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/ConnectionsCodecTest.kt`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/HostWorkspacesTest.kt`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/HostsRepositoryTest.kt`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/SettingsFleetTest.kt`

**Interfaces:**
- Consumes: `legacyRouteOwnership(connection, candidateHosts)` from Task 1.
- Produces: one agreement predicate used by credential migration, host refresh reconciliation, and interceptor rerouting.

- [ ] **Step 1: Write mismatch, absent-candidate, and compatibility regressions**

```kotlin
private val oldOwnershipAccount = RelayAccount("old.relay.test", "old-token")
private val newOwnershipAccount = RelayAccount("new.relay.test", "new-token")
private val host1 = HostConnection(
    hostId = "host1",
    publicUrl = "https://host1.test/root",
    relayDomain = oldOwnershipAccount.relayDomain,
    refresh = "refresh-1",
)
private val legacyConnection = WorkspaceConnection(
    id = "legacy",
    baseUrl = "https://host1.test/root/workspaces/ws-1",
    token = "standing-secret",
    directToken = "direct-secret",
)

private fun accountReplacement(
    candidates: List<HostConnection>,
    connection: WorkspaceConnection,
) = replaceRelayAccountFleet(
    oldOwnershipAccount, newOwnershipAccount, candidates, listOf(connection),
)
private fun directoryReplacement(
    existing: List<HostConnection>,
    replacement: List<HostConnection>,
    connection: WorkspaceConnection,
) = replaceRelayDirectoryFleet(
    oldOwnershipAccount.relayDomain, existing, replacement, listOf(connection),
)

@Test fun both_repository_ownership_callers_leave_absent_candidate_untouched() {
    val connection = legacyConnection.copy(hostId = "host1", workspaceId = "ws-1")
    val unrelated = HostConnection(
        hostId = "host2",
        publicUrl = "https://host2.test/root",
        relayDomain = oldOwnershipAccount.relayDomain,
    )
    assertEquals(connection, accountReplacement(listOf(unrelated), connection).connections.single())
    assertEquals(
        connection,
        directoryReplacement(listOf(unrelated), listOf(unrelated), connection).connections.single(),
    )
}

@Test fun stored_host_or_workspace_mismatch_blocks_both_mutation_callers() {
    for (conflict in listOf(
        legacyConnection.copy(hostId = "wrong-host", workspaceId = "ws-1"),
        legacyConnection.copy(hostId = "host1", workspaceId = "wrong-workspace"),
    )) {
        assertEquals(conflict, accountReplacement(listOf(host1), conflict).connections.single())
        assertEquals(
            conflict,
            directoryReplacement(listOf(host1), emptyList(), conflict).connections.single(),
        )
    }
}
```

In `HostWorkspacesTest`, use the existing `hostAwareClient(MockEngine) { candidates }` harness and real `SpecApi`. Capture request URL, Authorization header, and `/host/token` body. Add table-driven cases for empty candidates, non-owning candidates, ambiguous same-base hosts, stored host mismatch, and stored workspace mismatch. Each starts from `https://host1.test/root/workspaces/ws-1`, invokes `markThreadSeen`, and asserts one unchanged final request, no `/host/token`, and no host-refresh bearer. Add a direct-to-relay-adoption case whose relay host retains `directUrl`; it must recognize the direct URL as ownership evidence but select the current relay `hostBases()` route for the outbound request. A historical case starts at `https://old-host1.test/root/workspaces/ws-1` listed in `host1.legacyPublicUrls`, then asserts the token exchange uses `host1.refresh` and the final request is exactly `https://current-host1.test/root/workspaces/ws-1/threads/thread-1/seen`.

Add Settings/DataStore integration variants for absent and conflicting candidates at account replacement and directory refresh. Compare raw encoded connection rows before/after, including `token`, `directToken`, `hostId`, `workspaceId`, `baseUrl`, and legacy alias lists—not only row counts. Run LSP references for `ConnectionsRepository.replaceHost`; because the frozen branch has no caller that can supply the complete host snapshot, remove this unsupported entry point rather than retain its empty-candidate default. If a caller appears during implementation, migrate its API to require and pass the complete candidate-host snapshot, with an unknown/non-owning-candidate no-mutation regression.
- [ ] **Step 2: Run caller tests and verify RED**

Run:

```bash
(cd android && ./gradlew :app:testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.ConnectionsCodecTest' --tests 'com.atomikpanda.groundcontrol.HostWorkspacesTest' --tests 'com.atomikpanda.groundcontrol.HostsRepositoryTest' --tests 'com.atomikpanda.groundcontrol.SettingsFleetTest')
```

Expected: mismatch or unknown-base cases still migrate credentials, remove rows, or reroute requests.

- [ ] **Step 3: Add one stored-evidence agreement rule**

```kotlin
internal fun WorkspaceConnection.agreesWith(evidence: LegacyRouteOwnership.Owned): Boolean =
    (hostId.isNullOrBlank() || hostId == evidence.hostId) &&
        (workspaceId.isNullOrBlank() || workspaceId == evidence.workspaceId)
```

For every account migration, host refresh, and `replaceRelayDirectoryFleet` removal decision, permit mutation only for `Owned` plus `agreesWith`; evaluate each connection against the exact candidate set supplied to that caller. Fill missing IDs only from `Owned`; retain the complete existing row for `Unknown`, `Ambiguous`, or mismatch. Removal of a host from a directory is not enough to delete its connection unless the old connection's route was uniquely owned by that removed host under the pre-replacement candidate snapshot. Remove `ConnectionsRepository.replaceHost` after confirming it has no references; do not preserve an API whose empty candidate default bypasses this gate.

In `MshipClient`, capture one immutable complete host snapshot before request processing, pass it explicitly to `legacyRouteOwnership`, and reroute only an agreeing `Owned` result. Resolve `Owned.hostId` back to exactly one candidate host. `Owned.hostBase` proves historical/current/direct identity and supplies only the workspace suffix; choose the outbound base from that host's current `hostBases()` using existing direct-then-public preference, and build the URL with `workspaceBaseUrl(currentBase, evidence.workspaceId)`. Never send to the historical alias. If resolution is absent/duplicate, stored IDs disagree, workspace evidence is null for a workspace request, or the current host has no usable base, leave URL and auth unchanged. Do not fall back to URL origin, first host, or stored `hostId` alone.

- [ ] **Step 4: Remove obsolete inference paths and run caller tests**

Delete the old wrappers and fallback branches only after `codegraph impact`/LSP references show every repository, Settings, and interceptor caller migrated. Run the command from Step 2.

Expected: PASS; valid current/historical records still migrate and route, while missing, ambiguous, and conflicting evidence remains untouched.

- [ ] **Step 5: Commit agreement enforcement**

```bash
git add android/app/src/main/java/com/atomikpanda/groundcontrol/data/WorkspaceConnection.kt android/app/src/main/java/com/atomikpanda/groundcontrol/data/HostsRepository.kt android/app/src/main/java/com/atomikpanda/groundcontrol/data/ConnectionsRepository.kt android/app/src/main/java/com/atomikpanda/groundcontrol/data/MshipClient.kt android/app/src/test/java/com/atomikpanda/groundcontrol/ConnectionsCodecTest.kt android/app/src/test/java/com/atomikpanda/groundcontrol/HostWorkspacesTest.kt android/app/src/test/java/com/atomikpanda/groundcontrol/HostsRepositoryTest.kt android/app/src/test/java/com/atomikpanda/groundcontrol/SettingsFleetTest.kt
git commit -m "fix: require ownership agreement before rerouting"
mship journal "migrated repository and interceptor callers to canonical ownership evidence; focused tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 acs=ac15,ac16,ac17,ac18,ac19 -->
### Task 4: Verify backward-compatible ownership behavior

**Files:**
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/ConnectionsCodecTest.kt`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/HostWorkspacesTest.kt`
- Modify: `android/app/src/test/java/com/atomikpanda/groundcontrol/HostsRepositoryTest.kt`

**Interfaces:**
- Consumes: completed parser, ingress, repository, and interceptor changes.
- Produces: Mothership test evidence for PR #72.

- [ ] **Step 1: Add frozen compatibility fixtures and run the complete suite**

Freeze these inputs as literal constants in tests rather than rebuilding them through current constructors:

- pre-ownership connection JSON: `[{"id":"legacy","baseUrl":"https://host1.test/root/workspaces/ws-1","token":"standing-secret"}]`; decode it, prove missing ownership fields remain readable, then migrate from unique current-route evidence and assert `hostId=host1`, `workspaceId=ws-1`, current pathful base, `token`, and `directToken` exactly;
- stored-ID current-route row with matching `hostId/workspaceId`, color/glyph overrides, and legacy IDs; assert every unrelated field survives migration;
- historical-route row using `https://old-host1.test/root/workspaces/ws-1` plus a host whose `legacyPublicUrls` contains `https://old-host1.test/root`; assert migration/rerouting targets the current pathful root and keeps the old base only as an alias;
- unknown-base, ambiguous-two-host, host-ID conflict, and workspace-ID conflict rows; assert raw encoded bytes and outbound request URL/auth remain unchanged.

For each accepted current/historical fixture, feed the same decoded connection and host candidates to the repository and interceptor harnesses and assert equal `LegacyRouteOwnership.Owned` values before their side effects.

```bash
(cd android && ./gradlew :app:testDebugUnitTest --tests 'com.atomikpanda.groundcontrol.ConnectionsCodecTest' --tests 'com.atomikpanda.groundcontrol.HostWorkspacesTest' --tests 'com.atomikpanda.groundcontrol.HostsRepositoryTest' --tests 'com.atomikpanda.groundcontrol.SettingsFleetTest')
```

Expected: BUILD SUCCESSFUL.

- [ ] **Step 2: Run the task-scoped suite through Mothership**

```bash
mship test --task legacy-route-ownership
```

Expected: pass with no new failures.

- [ ] **Step 3: Record verification evidence**

```bash
mship journal "ownership redesign complete: canonical evidence, duplicate ingress rejection, agreement-gated migration/routing; task suite passing" --action verified
```
<!-- /mship:task -->
