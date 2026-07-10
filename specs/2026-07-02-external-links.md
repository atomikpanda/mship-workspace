---
id: external-links
title: External links on a WorkItem (MOS-201 v1)
status: implemented
created_at: '2026-07-02T17:49:23.904788Z'
updated_at: '2026-07-02T19:50:59.437910Z'
affected_repos:
- ground-control
acceptance_criteria:
- id: ac1
  text: WorkItemSummary deserializes a payload containing external_links into an externalLinks
    list; a unit test asserts provider/url/title parse, including a blank-title entry.
  verdict: approved
- id: ac2
  text: The link-chip row renders each external link and taps through to its URL,
    in all three cockpit headers (Console, Review, and Done).
  verdict: approved
- id: ac3
  text: When a work item has no external links, the row renders nothing (no empty-header
    artifact).
  verdict: approved
- id: ac4
  text: No server-side or endpoint changes; the app builds (assembleDebug) and existing
    tests still pass (mship test).
  verdict: approved
open_questions: []
non_goals:
- "Adding, editing, or removing links (the write path) \u2014 deferred to MOS-210\
  \ as the shared WorkItem-mutating link primitive."
- "Any mship server or endpoint change \u2014 the server already emits external_links;\
  \ this is read-only on the client."
- Deciding whether a 'follow-up' is another external_links entry or a typed WorkItem->WorkItem
  relation (that is MOS-210's design fork).
risks:
- "A malformed link entry could fail the whole WorkItemSummary parse \u2014 mitigated\
  \ by defaulting provider and title (url required)."
- provider is a server-side closed enum (github/linear/notion/jira/url); kept as a
  plain String on the client to avoid a brittle client enum drifting from the server.
task_slug: external-links
work_item_id: wi-20260702235053-9e40e967
---
## Problem

A WorkItem's external links (github/linear/notion/jira/url upstream associations) are already stored on the model and emitted by the mship server on GET /items and GET /items/{id}, but the Ground Control app silently drops the field — so from an item's cockpit there's no way to jump to its upstream GitHub PR, Linear issue, or Notion doc. The data exists in the model and on the wire; the phone just can't see it.

## User story

As an operator using Ground Control, I want to see a work item's external links as tap-through chips in its cockpit, so that I can jump straight to the upstream PR / issue / doc without leaving the app.

## Approach

Ground-control-only and read-only. (1) Widen the WorkItemSummary DTO to deserialize external_links into an ExternalLink({provider, url, title}) list, with defaulted provider/title so a partial entry can't break the whole parse. (2) Add one shared ExternalLinksRow composable — a wrapping row of tap-through AssistChips (LocalUriHandler.openUri), labelled by the link's title falling back to its provider, rendering nothing when the list is empty. (3) Render that row in the Console, Review, and Done cockpit headers; because all three headers already receive WorkItemSummary, the single DTO change lights up links across every phase an item can be in. No mship/server changes and no new endpoints — the server already emits the field.

## Testing

JVM unit test for external_links deserialization (extends WorkItemApiTest). The composable + header integration are build-verified via assembleDebug + mship test; on-device visual confirmation via mship capture is deferred to the operator (needs a work item that has links, e.g. seeded with `mship item link-url`).
