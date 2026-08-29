---
id: ground-control-ownership-evidence
title: Ground Control ownership evidence model
status: implemented
created_at: '2026-08-21T10:25:18.368977Z'
updated_at: '2026-08-25T11:10:18.977965Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: Given a URL under a supplied current host route, the shared parser returns
    the expected hostId and workspaceId evidence for that route.
  verdict: approved
  evidence: []
  comment: null
- id: ac2
  text: Given a URL under a supplied historical host route, the shared parser returns
    the same owning hostId and the expected workspaceId evidence needed to support
    the legacy route.
  verdict: approved
  evidence: []
  comment: null
- id: ac3
  text: Given a supplied host root with a non-root path, parsing a URL beneath that
    path preserves the complete pathful host root and derives identity relative to
    it rather than collapsing it to the URL origin.
  verdict: approved
  evidence: []
  comment: null
- id: ac4
  text: Given candidate roots such as https://example.test/gc and https://example.test/gc-admin,
    a URL matches only on a complete route-path boundary and is not assigned by a
    partial prefix match.
  verdict: approved
  evidence: []
  comment: null
- id: ac5
  text: Given a URL whose base matches none of the caller-supplied current or historical
    routes, the parser returns no ownership evidence and does not synthesize a new
    host root.
  verdict: approved
  evidence: []
  comment: null
- id: ac6
  text: Given more than one supplied candidate route that can validly claim the same
    URL, the parser reports unresolved or ambiguous ownership and neither credential
    migration nor rerouting occurs.
  verdict: approved
  evidence: []
  comment: null
- id: ac7
  text: Repository callers pass an explicit candidate-host set to the canonical parser;
    when the applicable host is absent from that set, repository processing does not
    infer ownership from the URL.
  verdict: approved
  evidence: []
  comment: null
- id: ac8
  text: Interceptor callers pass an explicit candidate-host set to the canonical parser;
    when the applicable host is absent from that set, the interceptor does not reroute
    the request.
  verdict: approved
  evidence: []
  comment: null
- id: ac9
  text: For every relay-directory ingress, input containing duplicate hostId values
    is rejected before any in-memory or persisted cache entry is added, replaced,
    removed, or reordered.
  verdict: approved
  evidence: []
  comment: null
- id: ac10
  text: For every account ingress, input containing duplicate hostId values is rejected
    before any in-memory or persisted cache entry is added, replaced, removed, or
    reordered.
  verdict: approved
  evidence: []
  comment: null
- id: ac11
  text: When duplicate host IDs cause ingress rejection, the previously visible directory/account
    data and associated cache state remain unchanged.
  verdict: approved
  evidence: []
  comment: null
- id: ac12
  text: Credential migration occurs only when URL-derived hostId and workspaceId evidence
    is unique and every corresponding stored ID that is present agrees; any present
    mismatch leaves the original credential records unchanged.
  verdict: approved
  evidence: []
  comment: null
- id: ac13
  text: Request rerouting occurs only when URL-derived hostId and workspaceId evidence
    is unique and every corresponding stored ID that is present agrees; any present
    mismatch leaves the original request destination unchanged.
  verdict: approved
  evidence: []
  comment: null
- id: ac14
  text: Missing legacy stored ownership IDs may be filled or rerouted only from unique
    URL-derived evidence; missing, ambiguous, or conflicting URL-derived evidence
    never triggers best-effort credential migration or rerouting.
  verdict: approved
  evidence: []
  comment: null
- id: ac15
  text: Existing Android data using a recognized current route continues to resolve,
    migrate, and reroute when the route is uniquely owned and stored IDs agree.
  verdict: approved
  evidence: []
  comment: null
- id: ac16
  text: Existing Android data using a recognized historical route continues to resolve,
    migrate, and reroute when the route is uniquely owned and stored IDs agree.
  verdict: approved
  evidence: []
  comment: null
- id: ac17
  text: Existing data using an unknown legacy base, an ambiguous candidate route,
    or conflicting stored ownership is retained without destructive migration and
    is not silently reclassified.
  verdict: approved
  evidence: []
  comment: null
- id: ac18
  text: All ownership derivation paths exercised by the redesigned PR use the single
    canonical parser; tests demonstrate equivalent identity results for repository
    and interceptor callers given the same URL and candidate hosts.
  verdict: approved
  evidence: []
  comment: null
- id: ac19
  text: Automated tests cover current routes, historical routes, pathful roots, path-boundary
    collisions, unknown bases, ambiguous matches, duplicate ingress IDs, stored-versus-derived
    ID mismatches, successful backward-compatible migration, and no-mutation failure
    behavior.
  verdict: approved
  evidence: []
  comment: null
open_questions: []
non_goals:
- Changes to Ground Control platforms other than Android.
- Backend, relay protocol, or server-side route changes.
- Automatic discovery of hosts from arbitrary or unknown URL bases.
- Treating a URL's origin or first path segment as an implicit host root when no supplied
  candidate route matches.
- Migrating or rerouting credentials when ownership evidence is missing, ambiguous,
  or inconsistent.
- A general redesign of account, credential, relay-directory, or cache schemas beyond
  the validation and ownership checks required here.
risks:
- Incomplete current or historical candidate-route data could cause valid legacy URLs
  to remain unresolved and therefore block migration or rerouting.
- Incorrect path-boundary or normalization logic could conflate pathful host roots
  with sibling paths, producing false ownership matches.
- Fail-fast duplicate-host validation may expose previously tolerated malformed relay-directory
  or account data and prevent it from loading until corrected.
- Introducing validation at only some ingress paths could still allow duplicate IDs
  to reach and corrupt cache state.
- Stricter agreement checks may leave some old installations on existing credentials
  or routes when their persisted ownership metadata is incomplete; this is safer than
  guessing but may require recovery handling.
- Behavior may diverge between repository and interceptor flows if they provide different
  candidate-host sets to the shared parser.
task_slug: ground-control-ownership-evidence
work_item_id: wi-20260821115632-0ccb1bf8
clarification_reason: null
prose_verdicts:
  non_goals:
    verdict: approved
    comment: null
  user_story:
    verdict: approved
    comment: null
  risks:
    verdict: approved
    comment: null
  scope_risk:
    verdict: approved
    comment: null
  problem:
    verdict: approved
    comment: null
  approach:
    verdict: approved
    comment: null
---
## Problem

Ground Control Android currently risks assigning legacy relay URLs to the wrong host or workspace when route formats have changed, host roots contain path components, candidate bases are unknown, or relay-directory/account inputs contain duplicate host IDs. A mistaken inference can mutate caches, migrate credentials, or reroute requests across ownership boundaries. PR #72 must therefore be redesigned from frozen head b669c106 so that legacy-route ownership is derived consistently and verified before any state-changing action.

## User story

As a Ground Control Android user with existing relay accounts and credentials, I want legacy URLs to be matched only to verified host and workspace ownership, so that upgrades preserve valid access without migrating credentials or routing traffic to the wrong host.

## Approach

Redesign PR #72 from frozen head b669c106 under parent task legacy-route-ownership. Introduce one canonical parser that derives legacy host/workspace identity by evaluating a URL relative to an explicit caller-supplied set of known current and historical host routes. The parser must compare route origins and path boundaries, preserve pathful host roots, and return no ownership evidence when no candidate base matches; it must never reinterpret an unknown URL base as a host root. Repository and interceptor callers must supply their candidate hosts rather than relying on parser discovery or fallback inference. Validate relay-directory and account collections at every ingress for unique host IDs before mutating any cache or persisted state, and fail the entire ingress operation on duplicates. Before credential migration or request rerouting, require stored hostId/workspaceId values to agree with identity evidence derived from the URL; missing, ambiguous, or conflicting evidence blocks the operation and leaves existing credentials, routing, and caches unchanged. Maintain backward compatibility only for legacy current/historical route forms that can be uniquely attributed to a supplied candidate host and whose derived identity agrees with stored ownership.

## Architecture

Ownership evidence is a value produced only by the canonical legacy-route parser from a URL plus explicit candidate-host metadata containing host IDs and current/historical routes. Parsing is side-effect free. Validation and agreement checks form gates around side effects: ingress uniqueness validation runs before cache mutation, and ownership agreement runs before credential migration or interceptor rerouting. Unknown or ambiguous ownership is represented as failure/no evidence, not as a newly inferred host.

## Migration and backward compatibility

Compatibility is limited to persisted Android accounts and credentials whose URLs match a known current or historical route supplied by the caller. Legacy data remains eligible for migration only when route ownership is unique and both derived identifiers agree with stored hostId/workspaceId. Unrecognized, ambiguous, incomplete, or conflicting records are left in place without credential mutation or rerouting; no cleanup or speculative repair is performed by this change.

## Testing

Use unit tests for parser normalization, route-relative identity derivation, pathful roots, exact path boundaries, current/historical routes, unknown bases, and ambiguity. Use repository and interceptor tests to verify explicit candidate propagation and agreement gates. Use ingress and persistence tests with pre-populated state to prove duplicate host IDs are rejected atomically before cache mutation and that all failed migration/rerouting cases preserve prior state and destinations.
