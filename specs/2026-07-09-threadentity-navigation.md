---
id: threadentity-navigation
title: "Thread\u2194entity navigation: deep-links + related work item (MOS-218/MOS-223)"
status: implemented
created_at: '2026-07-09T12:36:33.182207Z'
updated_at: '2026-07-09T16:33:21.307432Z'
affected_repos:
- mothership
- ground-control
acceptance_criteria:
- id: ac1
  text: GET /threads/{id} detail payload includes work_item_id plus a compact work_item
    summary (id, title, kind, phase), computed by inverting the WorkItem link graph
    with precedence thread_ids then spec_id then task_slug; both are null/absent when
    no WorkItem relates to the thread.
  verdict: approved
- id: ac2
  text: 'At read time the thread detail payload auto-linkifies recognized native mship
    references in agent-role message bodies only: wi- ids to item, an exact token
    matching an existing spec id to spec, and an exact token matching an existing
    task slug to task. External references (Linear ids, GitHub PR numbers) are not
    auto-linkified in v1. Human-role messages are returned unchanged.'
  verdict: approved
- id: ac3
  text: Only exact tokens that match a real, existing entity are linked (membership
    against live id/slug sets, never regex-guessing); a reference already inside a
    markdown link, inline code span, or fenced code block is left untouched so hand-written
    links are preserved.
  verdict: approved
- id: ac4
  text: Auto-linkified references render as [label](groundcontrol://{item|spec|task}?id={id})
    markdown links; ambiguous slugs resolve by documented precedence item > spec >
    task.
  verdict: approved
- id: ac5
  text: DeepLinkResolver handles the item, spec, and task hosts, returning OpenItem/OpenSpec/OpenTask
    outcomes whose parsing and workspace matching mirror the existing thread host,
    covered by resolver unit tests.
  verdict: approved
- id: ac6
  text: A shared open-work-item resolver route item/{connectionId}/{itemId} fetches
    the item and redirects by phase (in_flight to console, review to review, done
    to done, else spec/task/thread), mirroring FarmScreen.onOpen; both the related-item
    card and item deep-links route through it.
  verdict: approved
- id: ac7
  text: Tapping a groundcontrol:// link inside a chat message navigates in-app on
    the current connection (item via resolver, spec to specDetail, task to taskDetail);
    http/https links still open in the external browser as today.
  verdict: approved
- id: ac8
  text: ConversationScreen shows a Related work item card near the existing View-spec
    affordance when the thread has a related WorkItem (title + phase, tap opens it
    via the resolver), and shows nothing when there is none.
  verdict: approved
- id: ac9
  text: All existing and new tests pass via mship test in both repos, with no new
    third-party dependencies added.
  verdict: approved
open_questions:
- id: q1
  text: how do we handle linear style ids not being uniform and GitHub pr numbers
    being ambiguous? do we just skip that and keep the links to only mothership content
  answer: "Skip external refs in v1 \u2014 auto-linkify only native mship entities\
    \ (wi- ids, existing spec ids, existing task slugs), which are unambiguous exact-token\
    \ matches against live sets. Linear ids (MOS-###) are non-uniform and only resolvable\
    \ via external_links (which may be missing/incorrect), and GitHub #NNN has no\
    \ repo context, so both are ambiguous \u2014 left as plain text. The WorkItem-jump\
    \ case is still covered by the Slice-A related-item card and by hand-written explicit\
    \ groundcontrol://item?id= links. Auto-resolving Linear ids via external_links\
    \ is a clean fast-follow once we trust that coverage."
non_goals:
- 'OS-level (cold-open) deep-linking of entity links from outside the app: v1 is inline
  in-thread navigation only. Manifest intent-filters for the item/spec/task hosts
  may be added but external entry is not a requirement.'
- Linkifying references inside human-authored messages (human bubbles render plain
  text; agent citations are the v1 target).
- 'Auto-linkifying external references (Linear MOS-### ids, GitHub #NNN PR/issue numbers):
  non-uniform / ambiguous and mapping to external systems rather than in-app screens;
  left as plain text in v1 (hand-written explicit links still work).'
- 'A unified WorkItem detail screen: the resolver reuses the existing phase cockpits
  (console/review/done) and detail screens.'
risks:
- 'Auto-linkify false positives: a short slug (e.g. gc31) could appear in unrelated
  prose. Mitigated by exact-token membership against the real spec-id and task-slug
  sets, never regex-guessing arbitrary words.'
- 'Double-linkify: rewriting text that already contains a groundcontrol:// link would
  nest links. Mitigated by skipping matches inside markdown links, inline code spans,
  and fenced code blocks.'
- 'Serve-time rewrite cost on every thread read. Mitigated: an O(text length) token
  scan against in-memory id/slug sets; thread reads are already per-request and small.'
- Slug ambiguity when a spec and its task share a slug. Mitigated by documented precedence
  (item > spec > task).
task_slug: threadentity-navigation
work_item_id: wi-20260709131056-8933a7e0
---
## Problem

Threads are where the operator converses, but the *work* lives on the WorkItem, spec, and task — and today a thread offers no reliable way to jump to them. The only in-thread jump-off is a "View spec →" button, and only when the thread happens to carry a `spec_id`. Meanwhile agents constantly reference entities in chat ("MOS-223", "the gc31 spec", "wi-20260703…") as inert text, so the operator has to leave the thread and hunt the entity down by hand.

Two gaps: (1) no dependable "this thread's work item" jump-off, and (2) no tappable inline entity references. Both are cheap to close because the server already holds the full link graph (the WorkItem is the hub: `spec_id`, `task_slugs[]`, `thread_ids[]`) with by-id endpoints for every entity, and Ground Control already renders tappable markdown links in agent messages via the mikepenz renderer.

## User story

As the operator reading a thread on my phone, I want the thread's related work item surfaced as a tap-through, and any entity an agent mentions to be a tappable in-app link, so I can jump straight from the conversation to the work without hunting for it.

## Approach

Two slices over existing machinery, sharing one new navigation primitive. Scheme is the **existing** `groundcontrol://` deep-link scheme (hosts `add` and `thread` today; this adds `item`/`spec`/`task`).

### Shared: the "open work item" resolver

A new resolver route `item/{connectionId}/{itemId}` fetches the item (`GET /items/{id}`) and redirects to the right destination by phase, mirroring `FarmScreen.onOpen` exactly: `in_flight`→`console`, `review`→`review`, `done`→`done`, else (inbox/shaping/ready) `specDetail` if `spec_id`, else `taskDetail` if a task slug, else `thread`. Both slices route WorkItems through this one place, so there is a single definition of "open a work item."

### Slice A — MOS-223: related work item (server-computed)

Thread→WorkItem is not stored anywhere; compute it by inverting the WorkItem link graph. The inversion already exists in `core/workitem_migrate.py` (`item_by_spec`, `item_by_task`); add `item_by_thread` (from `thread_ids`) and resolve with precedence **thread_ids → spec_id → task_slug**. Add `work_item_id` plus a compact `work_item` summary (id, title, kind, phase — reuse `_summarize` / the `GET /items/{id}` path) to the `GET /threads/{id}` **detail** payload only (the `/threads` list/summary payload stays unchanged to avoid bloating the inbox).

GC reads the new fields via the existing `ignoreUnknownKeys` decoder (add them to the `Thread` DTO) and renders a slim **"Related work item"** card in `ConversationScreen`, right by the existing "View spec →" affordance, showing the item's title + phase; tapping it opens the item through the shared resolver. Absent when no related item.

### Slice B — MOS-218: inline deep-links (auto-linkify + explicit)

**Server (auto-linkify at read time).** When serializing the thread detail payload, rewrite **agent-role** message bodies, wrapping recognized **native mship** references in `[label](groundcontrol://{kind}?id={id})`:

- `wi-<timestamp>-<hex8>` → `item`
- an exact token matching an existing **spec id** → `spec`
- an exact token matching an existing **task slug** → `task`

Only exact tokens that match a **live** entity are linked (membership against in-memory id/slug sets, never regex-guessing arbitrary words). **External references are intentionally left as plain text in v1** (resolves open question q1): Linear-style ids (e.g. `MOS-###`) are non-uniform and only resolvable via a WorkItem's `external_links` (which may be missing or wrong), and GitHub `#NNN` carries no repo context — both are ambiguous. The WorkItem-jump case is still covered by the Slice-A related-item card and by hand-written explicit `groundcontrol://item?id=…` links; auto-resolving Linear ids is a clean fast-follow once `external_links` coverage is trusted. Matches already inside a markdown link, an inline code span, or a fenced code block are skipped, so hand-written links are preserved. Human messages are untouched. Ambiguous-slug precedence: **item > spec > task**. The rewrite is read-time only — stored message text stays pristine, so history linkifies for free and the scheme can evolve later.

**GC (in-app routing).** `DeepLinkResolver` gains `item`/`spec`/`task` hosts and `OpenItem`/`OpenSpec`/`OpenTask` outcomes; parsing and workspace matching mirror the existing `thread` host and are unit-tested (as in `DeepLinkResolverTest`). The message markdown renderer (`MessageMarkdown`) gets a custom `UriHandler` (provided via `CompositionLocalProvider`) that intercepts `groundcontrol://` taps and navigates in-app on the **current** connection — so no `workspace=` param is required for inline taps (item→resolver, spec→`specDetail`, task→`taskDetail`) — while delegating `http`/`https` links to the platform browser exactly as today.

No new third-party dependencies; both repos gate on `mship test`.
