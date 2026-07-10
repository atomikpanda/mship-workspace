# Thread↔entity navigation (deep-links + related work item) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `threadentity-navigation` (specs/2026-07-09-threadentity-navigation.md) — approved + dispatched. Closes MOS-218 + MOS-223.

**Goal:** Let the operator jump from a chat thread to the work — a server-computed "related work item" card on each thread, and tappable in-app `groundcontrol://` deep-links for native mship entities cited in agent messages.

**Architecture:** Server (mothership) computes thread→WorkItem by inverting the existing WorkItem link graph and auto-linkifies native entity refs in agent message bodies at read time; Ground Control extends its existing `groundcontrol://` deep-link machinery to `item`/`spec`/`task` hosts, adds one shared "open work item" resolver route, intercepts inline link taps in the message renderer, and renders the related-item card. No new third-party deps; both repos gate on `mship test`.

**Tech Stack:** mothership = Python (pydantic models, Starlette-style `serve.py`, pytest). ground-control = Kotlin/Compose (Ktor client, kotlinx.serialization, JUnit JVM unit tests only — no emulator).

**Worktrees (Work from):**
- mothership: `.worktrees/threadentity-navigation/mothership`
- ground-control: `.worktrees/threadentity-navigation/ground-control`

**Precedence rules (single source of truth for the whole plan):**
- thread→item resolution: `thread_ids` match → `spec_id` match → `task_slug` match (first hit wins).
- entity-token kind resolution (ambiguous slug): `item` (wi- id) > `spec` (spec id) > `task` (task slug).
- Only **native mship** tokens are auto-linkified (wi- ids, existing spec ids, existing task slugs). Linear `MOS-###` and GitHub `#NNN` are left as plain text (out of scope per q1/non-goals).

---

<!-- mship:task id=1 -->
### Task 1: [mothership] Thread→WorkItem resolver + expose on `GET /threads/{id}`

**Files:**
- Create: `src/mship/core/view/thread_links.py`
- Test: `tests/core/view/test_thread_links.py`
- Modify: `src/mship/core/serve.py` (the `GET /threads/{thread_id}` handler, ~line 419-424, and any other handler that returns a full `Thread.model_dump` — `POST /threads`, `POST /threads/{id}/messages`, `POST /threads/{id}/seen` — so the detail payload is consistent)

Reuse the inversion pattern from `src/mship/core/workitem_migrate.py:79-86`. Do **not** mutate stored records — this is a read-time computation layered onto the response dict.

- [ ] **Step 1: Write the failing test**

```python
# tests/core/view/test_thread_links.py
from mship.core.view.thread_links import resolve_thread_work_item

class _Item:
    def __init__(self, id, spec_id=None, task_slugs=None, thread_ids=None):
        self.id = id; self.spec_id = spec_id
        self.task_slugs = task_slugs or []; self.thread_ids = thread_ids or []

def test_prefers_explicit_thread_link():
    items = [_Item("wi-a", thread_ids=["t1"]), _Item("wi-b", spec_id="s1")]
    assert resolve_thread_work_item("t1", "s1", None, items) == "wi-a"

def test_falls_back_to_spec_then_task():
    items = [_Item("wi-b", spec_id="s1"), _Item("wi-c", task_slugs=["k1"])]
    assert resolve_thread_work_item("t9", "s1", None, items) == "wi-b"
    assert resolve_thread_work_item("t9", None, "k1", items) == "wi-c"

def test_none_when_no_relation():
    assert resolve_thread_work_item("t9", None, None, [_Item("wi-b", spec_id="s1")]) is None
```

- [ ] **Step 2: Run it and confirm it fails** — `uv run pytest tests/core/view/test_thread_links.py -v` → FAIL (module missing).

- [ ] **Step 3: Implement the resolver**

```python
# src/mship/core/view/thread_links.py
"""Read-time resolution of a thread's related WorkItem (inverts the WorkItem link graph)."""
from __future__ import annotations
from typing import Iterable


def resolve_thread_work_item(
    thread_id: str,
    spec_id: str | None,
    task_slug: str | None,
    items: Iterable,
) -> str | None:
    """Return the id of the WorkItem related to a thread, or None.

    Precedence: explicit thread_ids link > spec_id > task_slug.
    `items` is any iterable of objects with .id/.spec_id/.task_slugs/.thread_ids.
    """
    items = list(items)
    by_thread = {tid: w.id for w in items for tid in w.thread_ids}
    if thread_id in by_thread:
        return by_thread[thread_id]
    if spec_id:
        by_spec = {w.spec_id: w.id for w in items if w.spec_id}
        if spec_id in by_spec:
            return by_spec[spec_id]
    if task_slug:
        by_task = {slug: w.id for w in items for slug in w.task_slugs}
        if task_slug in by_task:
            return by_task[task_slug]
    return None
```

- [ ] **Step 4: Run the test** — `uv run pytest tests/core/view/test_thread_links.py -v` → PASS.

- [ ] **Step 5: Wire into the thread detail payload in `serve.py`**

In each handler that returns a full thread (`GET /threads/{id}`, `POST /threads`, `POST /threads/{id}/messages`, `POST /threads/{id}/seen`), enrich the dumped dict. The WorkItem store + index inputs are already assembled near `_workitem_index` (serve.py:442-448) — reuse `WorkItemStore(...).list()` and, for the compact summary, the same per-id summarize path used by `GET /items/{id}` (serve.py:454-469). Add a small helper inside `serve.py` to avoid repetition:

```python
def _thread_payload(t):  # t: Thread
    data = t.model_dump(mode="json")
    wi_id = resolve_thread_work_item(t.id, t.spec_id, t.task_slug, workitems.list())
    data["work_item_id"] = wi_id
    if wi_id is not None:
        summ = _summarize_item(wi_id)  # reuse the GET /items/{id} summarizer
        data["work_item"] = None if summ is None else {
            "id": summ.id, "title": summ.title, "kind": summ.kind, "phase": summ.phase,
        }
    else:
        data["work_item"] = None
    return data
```

Return `_thread_payload(thread)` from the detail handlers. Leave `GET /threads` list/summary (`_summaries`, serve.py:381-394) **unchanged**.

- [ ] **Step 6: Add a serve-level test** in the existing serve test module (mirror an existing `GET /threads/{id}` test): a thread whose spec_id belongs to a WorkItem returns `work_item_id` + a `work_item` dict with id/title/kind/phase; an unrelated thread returns `work_item_id: null` and `work_item: null`. Run `mship test`.

- [ ] **Step 7: Commit + journal**

```bash
mship journal "thread→workitem resolver + work_item on thread detail payload; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 -->
### Task 2: [mothership] Entity auto-linkifier + apply to agent messages

**Files:**
- Create: `src/mship/core/view/entity_links.py`
- Test: `tests/core/view/test_entity_links.py`
- Modify: `src/mship/core/serve.py` (`_thread_payload` from Task 1 — linkify each agent-role message's `text` in the dumped payload)

This is the correctness-critical piece; test it hard. Pure function, no I/O.

- [ ] **Step 1: Write failing tests** (cover: native ids linkified; label preserved; skip inside existing markdown link, inline code, fenced code; unknown tokens untouched; precedence item>spec>task; word-boundary so substrings of longer words are not matched)

```python
# tests/core/view/test_entity_links.py
from mship.core.view.entity_links import linkify_entities

SETS = dict(item_ids={"wi-20260703022747-5b70a0d2"},
            spec_ids={"gc31", "mos-212-chat"},
            task_slugs={"gc31", "mos-212-chat", "mos-224"})

def L(text): return linkify_entities(text, **SETS)

def test_links_wi_spec_task():
    assert L("see wi-20260703022747-5b70a0d2 now") == \
        "see [wi-20260703022747-5b70a0d2](groundcontrol://item?id=wi-20260703022747-5b70a0d2) now"
    assert L("the mos-224 task") == "the [mos-224](groundcontrol://task?id=mos-224) task"

def test_precedence_item_gt_spec_gt_task():
    # gc31 is both a spec id and a task slug -> spec wins
    assert L("check gc31") == "check [gc31](groundcontrol://spec?id=gc31)"

def test_skips_existing_link_and_code():
    assert L("[gc31](groundcontrol://spec?id=gc31)") == "[gc31](groundcontrol://spec?id=gc31)"
    assert L("run `mos-224` here") == "run `mos-224` here"
    assert L("```\nmos-224\n```") == "```\nmos-224\n```"

def test_unknown_and_substring_untouched():
    assert L("nope-999 and mos-2240 stay") == "nope-999 and mos-2240 stay"

def test_only_first_of_repeats_ok_and_idempotent():
    once = L("gc31 and gc31")
    assert once == "[gc31](groundcontrol://spec?id=gc31) and [gc31](groundcontrol://spec?id=gc31)"
    assert L(once) == once  # idempotent — re-linkify is a no-op
```

- [ ] **Step 2: Run and confirm failure** — `uv run pytest tests/core/view/test_entity_links.py -v`.

- [ ] **Step 3: Implement.** Strategy: split the text into protected spans (fenced code blocks ```` ``` ````, inline code `` ` ``, and existing markdown links `[..](..)`) and unprotected spans; only rewrite unprotected spans. In unprotected spans, tokenize on a word boundary and replace exact matches. Precedence checked per token.

```python
# src/mship/core/view/entity_links.py
"""Read-time auto-linkify of native mship entity refs in message text.

Wraps exact tokens that match a live entity id/slug in a groundcontrol:// markdown
link. Protects existing markdown links, inline code, and fenced code blocks. Only
native mship entities (wi- ids, spec ids, task slugs) — no external refs.
"""
from __future__ import annotations
import re

# token = a run of ref-legal chars, matched on word boundaries so "mos-2240"
# is NOT split into "mos-224". Ref chars: alphanumerics and hyphen.
_TOKEN = re.compile(r"(?<![A-Za-z0-9-])[A-Za-z0-9]+(?:-[A-Za-z0-9]+)+")
# protected spans, matched left-to-right: fenced block, inline code, md link.
_PROTECTED = re.compile(r"```.*?```|`[^`]*`|\[[^\]]*\]\([^)]*\)", re.DOTALL)


def _kind_for(token, item_ids, spec_ids, task_slugs):
    if token in item_ids:
        return "item"
    if token in spec_ids:
        return "spec"
    if token in task_slugs:
        return "task"
    return None


def _linkify_span(text, item_ids, spec_ids, task_slugs):
    def repl(m):
        tok = m.group(0)
        kind = _kind_for(tok, item_ids, spec_ids, task_slugs)
        if kind is None:
            return tok
        return f"[{tok}](groundcontrol://{kind}?id={tok})"
    return _TOKEN.sub(repl, text)


def linkify_entities(text, item_ids, spec_ids, task_slugs):
    out, last = [], 0
    for m in _PROTECTED.finditer(text):
        out.append(_linkify_span(text[last:m.start()], item_ids, spec_ids, task_slugs))
        out.append(m.group(0))  # protected — verbatim
        last = m.end()
    out.append(_linkify_span(text[last:], item_ids, spec_ids, task_slugs))
    return "".join(out)
```

- [ ] **Step 4: Run tests until green** — `uv run pytest tests/core/view/test_entity_links.py -v`. (Note: `wi-<ts>-<hex8>` matches `_TOKEN` because it is alnum-hyphen groups; verify the wi- test passes.)

- [ ] **Step 5: Apply in `serve.py`.** In `_thread_payload`, after `t.model_dump`, build the id/slug sets once (`item_ids = {w.id for w in items}`, `spec_ids` from the spec store, `task_slugs` from state) and rewrite each agent message's text:

```python
    for msg in data.get("messages", []):
        if msg.get("role") == "agent" and msg.get("text"):
            msg["text"] = linkify_entities(msg["text"], item_ids, spec_ids, task_slugs)
```

Human messages are skipped by the `role == "agent"` guard.

- [ ] **Step 6: Serve test** — a thread with an agent message containing a real spec slug returns linkified text; a human message with the same slug is unchanged. `mship test`.

- [ ] **Step 7: Commit + journal**

```bash
mship journal "entity auto-linkifier (native-only, protects code/links) applied to agent messages; tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 -->
### Task 3: [ground-control] DeepLinkResolver: item/spec/task hosts

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/notify/DeepLinkResolver.kt`
- Test: `android/app/src/test/java/com/atomikpanda/groundcontrol/DeepLinkResolverTest.kt`

Mirror the existing `thread` host exactly (workspace matching + query parse). Add three outcomes.

- [ ] **Step 1: Add failing unit tests** in `DeepLinkResolverTest.kt` — `groundcontrol://item?workspace=<ws>&id=wi-x` with a matching connection → `OpenItem(connId, "wi-x")`; same for `spec?...&id=s1` → `OpenSpec` and `task?...&id=k1` → `OpenTask`; a missing `id` → `Ignore`; an unknown host stays `Ignore`.

- [ ] **Step 2: Run — confirm failure** (`OpenItem`/`OpenSpec`/`OpenTask` unresolved). Use the workspace's Android toolchain: `source ~/toolchains/android-env.sh` then `mship test` (JVM unit tests only).

- [ ] **Step 3: Implement.** Add to the `sealed interface DeepLinkOutcome`:

```kotlin
    data class OpenItem(val connectionId: String, val itemId: String) : DeepLinkOutcome
    data class OpenSpec(val connectionId: String, val specId: String) : DeepLinkOutcome
    data class OpenTask(val connectionId: String, val slug: String) : DeepLinkOutcome
```

Refactor `resolve` so the `thread`/`item`/`spec`/`task` hosts share the id+workspace parse and connection match, differing only in the outcome constructed:

```kotlin
        val entityHosts = setOf("thread", "item", "spec", "task")
        if (uri.scheme != "groundcontrol" || uri.host !in entityHosts) return DeepLinkOutcome.Ignore
        val params = parseQuery(uri.rawQuery)
        val id = params["id"]?.takeIf { it.isNotBlank() } ?: return DeepLinkOutcome.Ignore
        val key = params["workspace"]?.takeIf { it.isNotBlank() } ?: return DeepLinkOutcome.Ignore
        // ... existing normKey/match logic ...
        if (match == null) return DeepLinkOutcome.AddConnection(key)
        return when (uri.host) {
            "thread" -> DeepLinkOutcome.OpenThread(match.id, id)
            "item" -> DeepLinkOutcome.OpenItem(match.id, id)
            "spec" -> DeepLinkOutcome.OpenSpec(match.id, id)
            "task" -> DeepLinkOutcome.OpenTask(match.id, id)
            else -> DeepLinkOutcome.Ignore
        }
```

Keep `MainActivity.onNewIntent`'s `when` exhaustive by adding no-op/`pendingThread`-style handling for the new outcomes is **out of scope** (OS-level entry is a non-goal) — but the `when` in MainActivity must still compile: add `is OpenItem, is OpenSpec, is OpenTask -> {}` branches (or a single `else -> {}`), leaving OS-level nav for later.

- [ ] **Step 4: Run tests → green.** `source ~/toolchains/android-env.sh && mship test`.

- [ ] **Step 5: Commit + journal**

```bash
mship journal "DeepLinkResolver handles item/spec/task hosts + outcomes; unit tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 -->
### Task 4: [ground-control] Thread DTO fields + shared "open work item" resolver route

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/data/dto/ThreadDtos.kt` (add fields to `Thread`)
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApp.kt` (add the `item/{connectionId}/{itemId}` resolver composable)
- Test: `android/app/src/test/java/com/atomikpanda/groundcontrol/` (a kotlinx-serialization decode test for the new Thread fields)

- [ ] **Step 1: Add the DTO fields.** In `ThreadDtos.kt`, extend `Thread` (decoder already uses `ignoreUnknownKeys`, so this is backward-compatible):

```kotlin
    @SerialName("work_item_id") val workItemId: String? = null,
    val workItem: WorkItemRef? = null,
```
Add a compact ref type in the same file:
```kotlin
@Serializable
data class WorkItemRef(
    val id: String,
    val title: String = "",
    val kind: String = "",
    val phase: String = "",
)
```
Note the server sends `"work_item"` (snake) — add `@SerialName("work_item")` on the `workItem` field.

- [ ] **Step 2: Failing decode test** — decode a thread JSON blob containing `work_item_id` + a `work_item` object and assert `workItemId` / `workItem?.title` / `workItem?.phase` populate; decode a blob without them and assert both are null. Run `source ~/toolchains/android-env.sh && mship test`.

- [ ] **Step 3: Add the resolver route** in `GroundControlApp.kt` (mirror the `console/...` composable block, ~line 237). The composable loads the item and redirects, replicating `FarmScreen.onOpen` (GroundControlApp.kt:222-231) exactly:

```kotlin
composable(
    route = "item/{connectionId}/{itemId}",
    arguments = listOf(
        navArgument("connectionId") { type = NavType.StringType },
        navArgument("itemId") { type = NavType.StringType },
    ),
) { entry ->
    val connectionId = entry.arguments?.getString("connectionId").orEmpty()
    val itemId = entry.arguments?.getString("itemId").orEmpty()
    val conn = remember(connectionId) { runBlockingSnapshot(connRepo).firstOrNull { it.id == connectionId } }
    // Load once, then redirect by phase, popping this resolver off the back stack.
    LaunchedEffect(connectionId, itemId) {
        if (conn == null) return@LaunchedEffect
        val item = runCatching { SpecApi(defaultHttpClient()).getItem(conn, itemId) }.getOrNull()
            ?: return@LaunchedEffect
        val dest = when {
            item.phase == "in_flight" -> "console/$connectionId/$itemId"
            item.phase == "review" -> "review/$connectionId/$itemId"
            item.phase == "done" -> "done/$connectionId/$itemId"
            item.specId != null -> "specDetail/$connectionId/${item.specId}"
            item.taskSlugs.isNotEmpty() -> "taskDetail/$connectionId/${item.taskSlugs.first()}"
            item.threadIds.isNotEmpty() -> "thread/$connectionId/${item.threadIds.first()}"
            else -> return@LaunchedEffect
        }
        nav.navigate(dest) { popUpTo("item/$connectionId/$itemId") { inclusive = true } }
    }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
}
```
(Use whatever `api`/connection-resolution helper the neighboring composables use — match the existing pattern for constructing `SpecApi`/`api` rather than `defaultHttpClient()` directly if a shared instance exists.)

- [ ] **Step 4: Compile + tests green.** `source ~/toolchains/android-env.sh && mship test`.

- [ ] **Step 5: Commit + journal**

```bash
mship journal "Thread DTO work_item fields + shared item resolver route (phase→cockpit); tests passing" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=5 -->
### Task 5: [ground-control] Intercept groundcontrol:// taps in the message renderer

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/MessageMarkdown.kt`
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/ConversationScreen.kt` (thread `onOpenEntity` callback through `ConversationContentView` → `MessageRow` → `MessageMarkdown`)
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApp.kt` (wire `onOpenEntity` on the `thread/...` composable to nav)
- Create: a small pure parser `EntityLink` + test under `.../ui/messages/` and `src/test/...`

- [ ] **Step 1: Add a failing unit test** for a pure parser: `EntityLink.parse("groundcontrol://item?id=wi-x")` → `("item","wi-x")`; `spec`/`task` likewise; `https://...` → null; `groundcontrol://thread?...` → null (threads handled elsewhere). This keeps the taps-to-nav logic unit-testable without an emulator.

- [ ] **Step 2: Implement `EntityLink.parse`** (host ∈ item/spec/task; extract `id` from query; ignore others). Run `source ~/toolchains/android-env.sh && mship test` → green.

- [ ] **Step 3: Provide a custom `UriHandler`** around the markdown in `MessageMarkdown.kt`. The mikepenz renderer opens links via `LocalUriHandler`; wrap it:

```kotlin
val defaultHandler = LocalUriHandler.current
val handler = remember(onOpenEntity, defaultHandler) {
    object : UriHandler {
        override fun openUri(uri: String) {
            val ref = EntityLink.parse(uri)
            if (ref != null) onOpenEntity(ref.first, ref.second) else defaultHandler.openUri(uri)
        }
    }
}
CompositionLocalProvider(LocalUriHandler provides handler) {
    Markdown(/* existing args */)
}
```
Add an `onOpenEntity: (kind: String, id: String) -> Unit` parameter to `MessageMarkdown` (default `{}` so other callers are unaffected), and thread it from `MessageRow` (ConversationScreen.kt:424-445 agent branch) up through `ConversationContentView`/`ConversationScreen` as a new callback.

- [ ] **Step 4: Wire nav** in `GroundControlApp.kt` on the `thread/{connectionId}/{threadId}` composable (near the existing `onViewSpec`, line 373):

```kotlin
onOpenEntity = { kind, id ->
    when (kind) {
        "item" -> nav.navigate("item/$connectionId/$id")
        "spec" -> nav.navigate("specDetail/$connectionId/$id")
        "task" -> nav.navigate("taskDetail/$connectionId/$id")
    }
},
```
http/https links still fall through to `defaultHandler` (browser) unchanged.

- [ ] **Step 5: Compile + tests green.** `source ~/toolchains/android-env.sh && mship test`.

- [ ] **Step 6: Commit + journal**

```bash
mship journal "inline groundcontrol:// taps route in-app via custom UriHandler; parser unit-tested" --action committed
```
<!-- /mship:task -->

<!-- mship:task id=6 -->
### Task 6: [ground-control] "Related work item" card in ConversationScreen

**Files:**
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/ConversationScreen.kt` (render the card near the View-spec affordance, ~line 222-233)
- Modify: `android/app/src/main/java/com/atomikpanda/groundcontrol/GroundControlApp.kt` (pass an `onOpenWorkItem` callback to the thread composable)

- [ ] **Step 1: Add the card composable.** In `ConversationScreen.kt`, right after the `ActivityStrip`/`View spec →` block, render when `thread.workItem != null`:

```kotlin
thread.workItem?.let { wi ->
    ElevatedCard(
        onClick = { onOpenWorkItem(wi.id) },
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
    ) {
        ListItem(
            headlineContent = { Text(wi.title.ifBlank { wi.id }) },
            overlineContent = { Text("Related work item") },
            supportingContent = { if (wi.phase.isNotBlank()) Text(wi.phase.replace('_', ' ')) },
            trailingContent = { Icon(Icons.AutoMirrored.Filled.ArrowForward, contentDescription = "Open work item") },
        )
    }
}
```
Match the existing screen's spacing/typography; keep it slim so it doesn't crowd the conversation. (Confirm the exact icon import available in the module; fall back to an existing chevron/arrow already used elsewhere.)

- [ ] **Step 2: Thread the callback** — add `onOpenWorkItem: (String) -> Unit` to `ConversationScreen`/`ConversationContentView`, and in `GroundControlApp.kt` wire it on the `thread/...` composable to `nav.navigate("item/$connectionId/$id")` (reuses the Task 4 resolver).

- [ ] **Step 3: Compile + tests green.** `source ~/toolchains/android-env.sh && mship test`. (Card rendering is UI — no emulator test; verify it compiles and the data path from Task 1's payload → DTO → card is coherent.)

- [ ] **Step 4: Commit + journal**

```bash
mship journal "Related work item card on the conversation screen taps through via the item resolver" --action committed
```
<!-- /mship:task -->

---

## Self-Review

- **Spec coverage:** ac1→T1; ac2→T2; ac3→T2; ac4→T2; ac5→T3; ac6→T4; ac7→T5; ac8→T6; ac9→every task runs `mship test`, no new deps. ✓
- **Type consistency:** server emits `work_item_id` + `work_item` {id,title,kind,phase}; GC `Thread.workItemId` + `Thread.workItem: WorkItemRef` decode them (T1↔T4). Deep-link kinds `item|spec|task` are identical in the server linkifier (T2), `DeepLinkResolver` (T3), `EntityLink.parse` (T5), and the nav wiring (T5/T6). ✓
- **Ordering:** mothership contract (T1,T2) lands before GC consumers; GC resolver route (T4) precedes the tap-nav (T5) and card (T6) that use it; DeepLinkResolver (T3) is independent. ✓
- **Toolchain:** GC tasks source `~/toolchains/android-env.sh` and run JVM unit tests only (no emulator), per the workspace constraint.
