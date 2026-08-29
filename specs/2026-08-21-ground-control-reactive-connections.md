---
id: ground-control-reactive-connections
title: Ground Control reactive connection subscriptions
status: dispatched
created_at: '2026-08-21T10:25:19.162788Z'
updated_at: '2026-08-21T11:56:36.338464Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: Given a fresh launch while the initial DataStore observation is pending, each
    named connection-dependent surface that is opened renders its Loading behavior
    without blocking UI interaction; when DataStore emits, that same surface transitions
    without an app restart.
  verdict: approved
  evidence: []
  comment: null
- id: ac2
  text: Given DataStore successfully emits an empty connection list, the shared state
    is Ready with an empty list, and Home, Queue, Tasks, and Capture/New Thread render
    their applicable no-connections or unavailable-action behavior instead of an indefinite
    loading indicator.
  verdict: approved
  evidence: []
  comment: null
- id: ac3
  text: Given DataStore emits one or more connections, Home, Queue, Tasks, and Capture/New
    Thread display or use the emitted connections through the shared state and do
    not require a synchronous or blocking DataStore read before becoming interactive.
  verdict: approved
  evidence: []
  comment: null
- id: ac4
  text: Given Home, Queue, Tasks, or Capture/New Thread is currently open, adding
    a connection causes the newly added connection to become available on that open
    surface without navigating away, recreating the activity, or relaunching the app.
  verdict: approved
  evidence: []
  comment: null
- id: ac5
  text: Given Home, Queue, Tasks, or Capture/New Thread is currently open, removing
    a connection causes that connection to disappear from the open surface and prevents
    connection-dependent actions from continuing to use the removed connection, without
    a crash or relaunch.
  verdict: approved
  evidence: []
  comment: null
- id: ac6
  text: Given Home, Queue, Tasks, or Capture/New Thread is currently open, replacing
    the persisted connection list causes the open surface to reflect the replacement
    list, with removed entries absent and replacement entries available, without retaining
    a stale captured provider.
  verdict: approved
  evidence: []
  comment: null
- id: ac7
  text: Given the currently selected or otherwise active connection is removed while
    a named surface is open, that surface moves to its defined no-valid-connection
    behavior and does not execute an action against the removed connection.
  verdict: approved
  evidence: []
  comment: null
- id: ac8
  text: Given DataStore throws while initially reading or subsequently observing connections,
    the shared state becomes Error, the affected UI stops showing Loading, and a visible
    recovery action is presented.
  verdict: approved
  evidence: []
  comment: null
- id: ac9
  text: Given the connection state is Error, activating its recovery action navigates
    the user to Settings through the existing Ground Control Android navigation path.
  verdict: approved
  evidence: []
  comment: null
- id: ac10
  text: Given the user returns from Settings after connection storage becomes readable,
    retry or resumed observation can transition the shared state from Error to Ready
    and the open consumer reflects the recovered list without an app process restart.
  verdict: approved
  evidence: []
  comment: null
- id: ac11
  text: Given a named screen leaves and re-enters the active lifecycle, it stops and
    resumes UI collection appropriately and displays the latest shared connection
    state on return rather than a composition-captured snapshot.
  verdict: approved
  evidence: []
  comment: null
- id: ac12
  text: Given an upgrade from the version based on frozen head b4ba4f14 with existing
    persisted connection records, the redesigned implementation reads those records
    without data loss, forced re-entry, or a DataStore key/schema migration, and presents
    them as Ready.
  verdict: approved
  evidence: []
  comment: null
- id: ac13
  text: Existing deep links, routes, and navigation behavior outside the added Error-to-Settings
    recovery path continue to resolve as before.
  verdict: approved
  evidence: []
  comment: null
- id: ac14
  text: Automated tests cover Loading-to-Ready(non-empty), Loading-to-Ready(empty),
    Loading-to-Error, Error-to-Ready recovery, and Ready-to-Ready add/remove/replace
    transitions for every named consumer or for shared consumer behavior with screen-specific
    integration coverage.
  verdict: approved
  evidence: []
  comment: null
open_questions: []
non_goals:
- Changes outside the Ground Control Android repository or platform.
- Backend, protocol, server, or connection-record schema changes.
- A general redesign of application navigation beyond making the named connection-dependent
  destinations reactive and exposing Settings recovery from the error state.
- Changes to connection creation, editing, validation, or deletion semantics beyond
  propagating their resulting list changes reactively.
- Migration to a different persistence technology or replacement of DataStore.
- Redesign of unrelated screens or UI styling.
risks:
- A StateFlow scoped too narrowly could be recreated during navigation, while one
  scoped too broadly without proper ownership could leak Android or UI references.
- DataStore exceptions can terminate an upstream flow; error handling and recovery
  must ensure consumers receive Error predictably and can observe subsequent valid
  state after recovery.
- Rapid add, remove, or replace operations could expose stale derived selections or
  actions if consumers cache connection objects outside the shared state.
- Removing Compose-captured providers may uncover hidden dependencies on composition
  timing or previous one-shot initialization behavior.
- An active connection can disappear while a dependent screen is open, requiring every
  named consumer to handle the resulting absence without crashing or acting on the
  removed connection.
task_slug: ground-control-reactive-connections
work_item_id: wi-20260821115636-a7d9c9a5
clarification_reason: null
prose_verdicts:
  problem:
    verdict: approved
    comment: null
  user_story:
    verdict: approved
    comment: null
  scope_risk:
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
---
## Problem

PR #74 at frozen head b4ba4f14 does not provide a single lifecycle-stable source of connection state, allowing screens and actions to retain stale connection data through Compose-captured providers, one-time reads, or blocking DataStore access. As a result, open Ground Control Android surfaces may fail to reflect connection additions, removals, or replacements; an empty connection list may be confused with loading; and a DataStore failure may leave the user on an endless spinner with no recovery path.

## User story

As a Ground Control Android user, I want Home, Queue, Tasks, and Capture/New Thread to react consistently to connection-state changes, so that open screens and actions always use current connection data and storage failures lead me to a recoverable Settings path.

## Approach

Redesign PR #74 from frozen head b4ba4f14 under parent task reactive-navigation-connections. Introduce one application/repository-scoped, lifecycle-stable StateFlow for connection state with an explicit sealed model: Loading, Ready(connections), and Error. Ready is emitted for every successfully loaded list, including an empty list; an empty list is never represented as Loading. Build the flow from asynchronous DataStore observation without blocking calls or synchronous reads. Home, Queue, Tasks, and Capture/New Thread collect this StateFlow directly with lifecycle-aware collection and derive their displayed connection choices and connection-dependent actions from the latest emission. Do not pass or retain Compose-captured connection providers. Additions, removals, and whole-list replacements emitted by the data source update already-open consumers without requiring navigation, recreation, or relaunch. DataStore read or collection failures transition to Error and render an actionable route to Settings rather than retaining Loading indefinitely. Preserve the existing persisted connection schema and existing navigation contracts except where these screens must consume the shared reactive state.

## Architecture

The connection state owner must outlive individual composables and navigation destinations and must not hold Activity, Fragment, View, NavController, or composable references. DataStore is observed asynchronously and mapped into exactly three public state variants: Loading, Ready(list), and Error. Consumers collect the same state source with lifecycle awareness and derive transient UI state from the current Ready payload rather than caching providers or connection objects across emissions. Exceptions are converted to Error rather than allowing the upstream collection to leave the public state permanently at Loading.

## Migration and backward compatibility

This is an implementation and state-model migration only. Existing DataStore keys, serialized connection records, and user data remain readable as-is; no destructive migration, reset, or forced connection recreation is permitted. Existing routes remain stable, with the only intentional navigation addition being the recoverable Error-to-Settings path. Work is limited to redesigning PR #74 from frozen head b4ba4f14 under reactive-navigation-connections.

## Testing

Use deterministic fake DataStore or repository emissions to verify all state transitions, including delayed initial reads, empty lists, exceptions, recovery, rapid mutations, and removal of the active connection. Add UI or navigation integration tests for Home, Queue, Tasks, and Capture/New Thread that keep each destination open while the source emits add, remove, and replacement updates. Include an upgrade-compatibility fixture containing pre-change persisted records and verify it reaches Ready without rewriting or discarding those records.
