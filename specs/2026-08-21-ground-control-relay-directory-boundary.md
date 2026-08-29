---
id: ground-control-relay-directory-boundary
title: Ground Control relay directory validation boundary
status: implemented
created_at: '2026-08-21T10:25:21.651410Z'
updated_at: '2026-08-25T11:10:28.391298Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: Given a valid relay-directory payload, Ground Control Android canonicalizes
    every route URL once during DTO-to-domain transformation, uses the resulting canonical
    value in the produced domain fleet and cache write, and does not perform another
    canonicalization in downstream domain or persistence processing.
  verdict: approved
  evidence: []
  comment: null
- id: ac2
  text: Given two entries whose identities become equal after URL canonicalization,
    the full authoritative response is rejected as duplicate and no part of that response
    replaces the previously cached fleet.
  verdict: approved
  evidence: []
  comment: null
- id: ac3
  text: Given duplicate required host IDs or any other duplicate identity defined
    by the domain model, the full authoritative response is rejected and the previously
    cached fleet remains unchanged.
  verdict: approved
  evidence: []
  comment: null
- id: ac4
  text: Given a non-pending entry with a missing, null, or empty required host ID,
    transformation fails, the candidate fleet is not published, and the previously
    cached fleet remains available.
  verdict: approved
  evidence: []
  comment: null
- id: ac5
  text: Given an entry in an explicitly supported pending state with no host ID, transformation
    succeeds when all other required fields and routes are valid; the same missing-host
    payload fails when the entry is changed to any non-pending state.
  verdict: approved
  evidence: []
  comment: null
- id: ac6
  text: Given an entry with no routes, only null or empty routes, or no route accepted
    by the supported route validator, the full authoritative response is rejected
    and the cache remains unchanged.
  verdict: approved
  evidence: []
  comment: null
- id: ac7
  text: Given a route with leading or trailing whitespace, the route is rejected rather
    than trimmed or repaired, and the authoritative response does not replace the
    cache.
  verdict: approved
  evidence: []
  comment: null
- id: ac8
  text: Given a syntactically malformed, unsupported, or non-canonicalizable route
    URL, transformation fails before cache replacement and the prior cached fleet
    remains unchanged.
  verdict: approved
  evidence: []
  comment: null
- id: ac9
  text: Given an absent, null, incorrectly typed, or otherwise malformed hosts payload,
    the response is classified as invalid authoritative data and the existing cached
    fleet is preserved.
  verdict: approved
  evidence: []
  comment: null
- id: ac10
  text: Given any nested DTO-to-domain transformation failure after one or more earlier
    entries have transformed successfully, no partial fleet is emitted or cached and
    the complete prior cache contents remain unchanged.
  verdict: approved
  evidence: []
  comment: null
- id: ac11
  text: Given a fully valid authoritative response, the complete transformed fleet
    replaces the previous cached fleet in one successful operation; observers never
    receive a partially transformed intermediate fleet.
  verdict: approved
  evidence: []
  comment: null
- id: ac12
  text: Given invalid authoritative data while a cached fleet exists, users continue
    to receive the cached fleet and the failure is not reported as an authentication
    failure or network outage.
  verdict: approved
  evidence: []
  comment: null
- id: ac13
  text: Given the same authentication failure inputs supported before this change,
    Ground Control Android preserves the existing authentication classification and
    does not reclassify them as invalid authoritative data.
  verdict: approved
  evidence: []
  comment: null
- id: ac14
  text: Given the same timeout, connectivity, and service-outage inputs supported
    before this change, Ground Control Android preserves the existing outage classification
    and does not reclassify them as invalid authoritative data.
  verdict: approved
  evidence: []
  comment: null
- id: ac15
  text: 'Given payload fixtures accepted by the frozen PR #77 head fa91a797 that already
    satisfy the new identity, host-state, host-payload, and route rules, the redesigned
    implementation produces behaviorally equivalent domain fleets without requiring
    a wire-format change.'
  verdict: approved
  evidence: []
  comment: null
- id: ac16
  text: Given a valid fleet cached by the prior Android implementation, the redesigned
    version can read and serve it without destructive migration; a failed subsequent
    directory refresh leaves that cache intact.
  verdict: approved
  evidence: []
  comment: null
- id: ac17
  text: Automated boundary tests cover valid payloads, canonical-equivalent duplicates,
    duplicate host identities, pending and non-pending missing host IDs, missing or
    malformed hosts payloads, absent and unusable routes, padded and malformed routes,
    nested transformation failures, successful atomic replacement, cache preservation,
    and unchanged outage/authentication classifications.
  verdict: approved
  evidence: []
  comment: null
- id: ac18
  text: Repository changes for this task are confined to Ground Control Android; builds
    and tests for the affected Android modules pass without requiring coordinated
    backend or other-client releases.
  verdict: approved
  evidence: []
  comment: null
open_questions: []
non_goals:
- Changing the relay-directory server API, payload schema, or server-side validation
  behavior.
- Modifying iOS, web, backend, or other non-Ground-Control-Android repositories.
- Redesigning authentication, retry, polling, or outage-detection policy beyond preserving
  current classifications.
- Repairing, trimming, guessing, or partially accepting invalid routes or malformed
  host entries.
- Replacing the cache with a partially transformed subset of an authoritative response.
- Introducing a new persistent cache schema or requiring migration of existing valid
  cached fleet records.
- Broad UI redesign or new user-facing error surfaces unrelated to preserving current
  error classifications and cached-fleet behavior.
risks:
- Canonical URL equivalence may reveal duplicates that were previously treated as
  distinct, causing formerly accepted but ambiguous payloads to be rejected.
- An overly strict route parser could reject legacy payloads that are operationally
  valid; compatibility fixtures are required for all currently supported URL forms.
- Incorrect modeling of pending states could either reject legitimate pending entries
  or permit missing host IDs outside the intended exception.
- Validation performed after any cache side effect could still corrupt or clear a
  good fleet; cache replacement must be demonstrably atomic and sequenced after complete
  transformation.
- Error mapping changes could accidentally collapse invalid-data, outage, and authentication
  cases, altering fallback or user-visible behavior.
- Existing cache records produced by older app versions may contain values not created
  by the new boundary; read compatibility must be tested without recanonicalizing
  accepted domain values multiple times.
task_slug: ground-control-relay-directory-boundary
work_item_id: wi-20260821115646-ebc64d18
clarification_reason: null
prose_verdicts:
  approach:
    verdict: approved
    comment: null
  problem:
    verdict: approved
    comment: null
  user_story:
    verdict: approved
    comment: null
  non_goals:
    verdict: approved
    comment: null
  scope_risk:
    verdict: approved
    comment: null
  risks:
    verdict: approved
    comment: null
---
## Problem

PR #77 currently allows relay-directory transport data to cross into the Ground Control Android domain/cache without one explicit, atomic validation boundary. That can admit ambiguous duplicate identities, non-canonical or unusable routes, missing host identity, malformed host collections, and partial transformation results, potentially replacing a previously usable cached fleet with invalid authoritative data. The redesign must make DTO-to-domain conversion the single point where URLs are canonicalized and the complete candidate fleet is validated, while retaining the existing distinction between authentication failures, outages, and invalid authoritative payloads.

## User story

As a Ground Control Android user, I want relay-directory updates to be fully validated before they replace my cached fleet, so that I continue to see a consistent, usable fleet during malformed server responses, outages, or authentication failures.

## Approach

Redesign PR #77 from frozen head fa91a797 around a strict DTO-to-domain boundary in Ground Control Android. Parse the complete relay-directory response into transport DTOs, then perform one all-or-nothing transformation into domain objects before any cache mutation. During this transformation, canonicalize each route URL exactly once and retain that canonical value for identity comparison, validation, domain construction, and persistence; downstream layers must not reparse or recanonicalize it. Reject the entire candidate fleet if the hosts payload is absent, null, malformed, or cannot be transformed; if any identity that must be unique resolves to the same canonical identity; if a non-pending entry lacks its required host ID; if an entry has no usable route; if a route has leading or trailing padding or is otherwise invalid; or if any nested transformation fails. Missing host IDs are permitted only for the explicitly modeled pending state(s), and this exception must be encoded in the domain validation rather than inferred by callers. Build and validate the full domain fleet in memory, then replace the cache atomically only after success. Invalid authoritative data is classified separately from outage and authentication errors and leaves the existing cache intact. Preserve the current externally observed outage/authentication classification and fallback behavior. Limit implementation and migration work to Ground Control Android and preserve compatibility with already valid relay-directory payloads and existing valid cached fleet data; no server or wire-format migration is introduced.

## Architecture

The transport layer owns decoding only. A dedicated relay-directory DTO-to-domain transformer owns canonicalization and complete invariant enforcement. Domain objects receive already canonical, validated route values and do not repeat normalization. The repository/service layer receives either one complete validated fleet or a typed failure; it performs cache replacement only for the successful fleet result. Cache reads and fallback selection remain outside the transformer. Error mapping must retain three distinguishable paths: authentication failure, outage/transport failure, and invalid authoritative data/transformation failure.

## Testing

Use deterministic unit fixtures at the DTO-to-domain boundary and repository-level tests with a pre-populated cache. Spy or injectable canonicalization in tests should verify one invocation per candidate route and no downstream invocation. Repository tests must assert exact cache contents before and after each failure, not merely that a cache API was called. Include compatibility fixtures for all currently supported valid route forms and for cache records written by the prior Android version.

## Migration and Backward Compatibility

This is an Android client boundary migration, not a wire-protocol or persistent-schema migration. Existing valid server payloads continue to work. Existing valid cached fleets remain readable and are not eagerly rewritten solely to adopt the new boundary. Newly fetched data is admitted only through the new all-or-nothing validator. Previously tolerated ambiguous or invalid authoritative payloads may now be rejected by design, with the last valid cache retained. No coordinated rollout with relay-directory services or other clients is required.
