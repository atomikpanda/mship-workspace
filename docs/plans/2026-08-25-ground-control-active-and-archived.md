# Ground Control Active and Archived Inboxes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give threads and specs a durable, shared, non-destructive active/archive inbox lifecycle owned by Mothership and rendered as searchable Active/Archived tabs in Ground Control.

## Assumptions checked

- repo topology — covered: coordinated changes span `mothership` for durable state/classification/API and `ground-control` for DTOs, repositories, ViewModels, and Compose surfaces.
- credential locus — N/A: inbox mutations use existing authenticated host/workspace API credentials and introduce no credential type.
- execution locus — covered: classification and mutation ordering execute on each Mothership workspace host; Ground Control is a client of that authority.
- state durability — covered: optional inbox metadata is serialized beside each thread/spec; mutation identities remain durable so retries cannot restart grace periods.
- review surface — covered: Mothership and Ground Control receive separate coordinated PRs from one Mothership task, reviewed in dependency order.
- agent stream — covered: thread attention derives from durable message kinds/cursors already consumed by the receiving-messages loop; inbox actions do not create agent messages.
- dispatched model — covered: task implementers inherit the workspace dispatch model; execution is serialized one anchored task at a time across the shared multi-repo worktrees.

**Architecture:** `mship.core.inbox` owns one precedence-ordered classifier and mutation model used for both threads and specs. Mothership stores inbox metadata and exposes filter/search/action APIs while retaining `all` as the compatibility default; Ground Control requests server-classified Active/Archived data and never re-implements lifecycle rules.

**Tech Stack:** Python 3.14, Pydantic, filesystem stores with `flock`, FastAPI, Kotlin 2.0, Kotlin serialization, coroutines/StateFlow, Jetpack Compose Material 3.

**Spec:** `ground-control-active-and-archived` — `specs/2026-08-25-ground-control-active-and-archived.md`

## Global Constraints

- Inbox visibility never deletes or mutates thread messages, spec content, WorkItems/tasks, or spec lifecycle status.
- Mothership is the sole classifier and mutation-order authority; Ground Control consumes returned state/reason.
- Existing list/search clients that omit `inbox` retain `all` behavior.
- Seven days is exactly `timedelta(days=7)` in UTC; the boundary is archived at elapsed time greater than or equal to seven days.
- Precedence is pinned, thread attention (`awaiting_reply`, needs-you, unanswered decision), latest explicit archive/restore action, restore grace, linked-thread terminal state or spec lifecycle, then unlinked-thread inactivity.
- Mutation identity is required on archive/restore/pin/unpin; duplicate identities within the most recent 256 per item do not change timestamps or outcomes.
- Lifecycle-archived specs may be restored to the inbox for seven days without leaving lifecycle status `archived`.

---

<!-- mship:task id=1 acs=ac1,ac2,ac3,ac4,ac5,ac6,ac7,ac8,ac9,ac10,ac11,ac12,ac13,ac14,ac15,ac16,ac17,ac24 -->
### Task 1: Add durable inbox metadata and the shared classifier

**Files:**
- Create: `mothership/src/mship/core/inbox.py`
- Modify: `mothership/src/mship/core/message.py:42-55`
- Modify: `mothership/src/mship/core/spec.py:57-73`
- Modify: `mothership/src/mship/core/message_store.py:37-137`
- Modify: `mothership/src/mship/core/spec_store.py:48-128`
- Test: `mothership/tests/core/test_inbox.py`
- Test: `mothership/tests/core/test_message_store.py`
- Test: `mothership/tests/core/test_spec_store.py`

**Interfaces:**
- Produces: `InboxMetadata`, `InboxClassification`, `InboxAction`, `InboxArchiveReason`, `classify_thread(...)`, `classify_spec(...)`, `MessageStore.mutate_inbox(...)`, and `SpecStore.mutate_inbox(...)`.
- Consumes: existing `Thread.awaiting_reply`, `Thread.needs_you`, `Thread.needs_decision`, `Thread.updated_at`, `Spec.status`, `Spec.updated_at`, and caller-supplied linked-terminal state/current UTC time.

- [ ] **Step 1: Write classifier tests before implementation**

Create table-driven tests in `tests/core/test_inbox.py` that construct UTC timestamps around one named constant:

```python
SEVEN_DAYS = timedelta(days=7)
NOW = datetime(2026, 8, 25, 12, tzinfo=timezone.utc)
```

Cover every precedence edge from ac1-ac15, including `NOW - SEVEN_DAYS + 1 microsecond` versus the exact boundary, restored lifecycle-archived specs retaining lifecycle status, new thread activity resetting inactivity, and pin/unpin fallback.

- [ ] **Step 2: Run classifier tests and confirm the missing owner fails**

Run:

```bash
uv run pytest -q tests/core/test_inbox.py
```

Expected: collection/import failure because `mship.core.inbox` does not exist.

- [ ] **Step 3: Implement the shared model and pure classifiers**

In `mship.core.inbox`, define:

```python
InboxState = Literal["active", "archived"]
InboxAction = Literal["archive", "restore", "pin", "unpin"]
InboxArchiveReason = Literal[
    "manual", "linked_terminal", "inactive_unlinked",
    "implemented", "lifecycle_archived",
]

class InboxMetadata(BaseModel):
    pinned: bool = False
    manual_archived: bool = False
    restored_at: datetime | None = None
    mutation_ids: dict[str, InboxAction] = Field(default_factory=dict)

class InboxClassification(BaseModel):
    state: InboxState
    archive_reason: InboxArchiveReason | None = None
```

Add `inbox: InboxMetadata = InboxMetadata()` to both `Thread` and `Spec` using `Field(default_factory=InboxMetadata)`. Implement pure classifiers with the Global Constraints precedence. `classify_thread` accepts `linked: bool`, `linked_terminal: bool`, and `now`; `classify_spec` accepts `now`.

- [ ] **Step 4: Run classifier tests to green**

Run `uv run pytest -q tests/core/test_inbox.py` and expect all cases to pass.

- [ ] **Step 5: Add mutation-store tests for idempotency and ordering**

Add tests proving:

- duplicate mutation IDs are no-ops and do not move `restored_at`;
- archive then restore differs from restore then archive according to commit order;
- pin/unpin are durable booleans and preserve manual/restore metadata for fallback;
- stored thread/spec content and lifecycle status remain byte-for-byte/domain-equal apart from inbox metadata;
- unknown action and reused mutation ID with a different action fail loudly.

- [ ] **Step 6: Implement locked store mutations**

Add one helper in `inbox.py`:

```python
def apply_inbox_action(
    metadata: InboxMetadata,
    action: InboxAction,
    mutation_id: str,
    now: datetime,
) -> bool:
    """Mutate in place; return False for an identical retry."""
```

A reused retained ID with a different action raises `ValueError`. Archive sets `manual_archived=True`; restore sets it false and stamps `restored_at`; pin/unpin set `pinned`. Retain the 256 most recent identities in deterministic insertion order and evict the oldest on overflow. State-equivalent actions remain intrinsic no-ops after eviction.

Implement `MessageStore.mutate_inbox` under the existing per-thread `flock`. Add a per-spec lock path and `SpecStore.mutate_inbox` that reads, applies, and saves under one exclusive lock across storage modes.

- [ ] **Step 7: Run focused model/store tests**

Run:

```bash
uv run pytest -q tests/core/test_inbox.py tests/core/test_message_store.py tests/core/test_spec_store.py
```

Expected: pass.

- [ ] **Step 8: Commit and journal Task 1**

```bash
git -C mothership add src/mship/core/inbox.py src/mship/core/message.py src/mship/core/spec.py src/mship/core/message_store.py src/mship/core/spec_store.py tests/core/test_inbox.py tests/core/test_message_store.py tests/core/test_spec_store.py
git -C mothership commit -m "Add durable inbox classification"
mship journal "implemented durable thread/spec inbox classifier and locked idempotent mutations" --task ground-control-active-and-archived --repo mothership --action committed
```
<!-- /mship:task -->

<!-- mship:task id=2 acs=ac6,ac7,ac9,ac10,ac12,ac16,ac17,ac18,ac19,ac20,ac24 -->
### Task 2: Expose filtered/searchable inbox APIs and mutations

**Files:**
- Modify: `mothership/src/mship/core/serve.py:528-577,1211-1309`
- Modify: `mothership/src/mship/core/view/thread_links.py`
- Test: `mothership/tests/core/test_serve.py`
- Test: `mothership/tests/core/test_serve_specs.py`
- Test: `mothership/tests/core/test_message_wait.py`

**Interfaces:**
- Consumes: Task 1 classifier/store interfaces.
- Produces: list query `inbox=active|archived|all`, optional `q`, response fields `inbox_state`, `archive_reason`, `pinned`, and POST action routes for threads/specs.

- [ ] **Step 1: Write API contract tests**

Add tests for:

```text
GET /threads?inbox=active&q=needle
GET /threads?inbox=archived
GET /threads                         # compatibility all
GET /specs?inbox=active&q=needle
GET /specs?inbox=archived
GET /specs                           # compatibility all
POST /threads/{id}/inbox/{archive|restore|pin|unpin}
POST /specs/{id}/inbox/{archive|restore|pin|unpin}
```

Mutation JSON is `{"mutation_id": "stable-client-generated-id"}`. Assert 422 for invalid filters/actions/empty IDs, 404 for missing entities, identical responses for retries, cross-device order behavior, and no content deletion. Long-poll `/threads?wait=1` must apply the requested inbox/search filter to changed results without changing cursor semantics.

- [ ] **Step 2: Run focused API tests and confirm failure**

Run the named serve/message-wait test files; expect missing query parameters/routes/fields.

- [ ] **Step 3: Implement thread terminal resolution once**

Use the existing single WorkItem ownership resolver/index to find a linked item. Derive terminal from the WorkItem's live derived phase (`done`) or all linked tasks being finished/merged according to the existing WorkItem phase owner; never duplicate phase logic inside the inbox classifier. Pass only `linked` and `linked_terminal` into `classify_thread`.

- [ ] **Step 4: Implement list/search payload projection**

Add validated query parameters with `all` default. Classify before filtering, perform case-insensitive search over thread subject/last message and spec id/title, and stamp every summary with `inbox_state`, nullable `archive_reason`, and `pinned`. Locked specs remain visible under `all`; because they cannot be classified without plaintext metadata, mark them active with no reason and exclude them only from explicit archived results.

- [ ] **Step 5: Implement inbox action routes**

Add a Pydantic `InboxMutationBody(mutation_id: str)` with nonblank validation. Route actions through store methods using server receipt UTC time, return the freshly classified full payload, and call existing activity/change notification seams so Ground Control refresh/long-poll observes the durable mutation.

- [ ] **Step 6: Run focused API tests**

Run:

```bash
uv run pytest -q tests/core/test_serve.py tests/core/test_serve_specs.py tests/core/test_message_wait.py
```

Expected: pass.

- [ ] **Step 7: Commit and journal Task 2**

```bash
git -C mothership add src/mship/core/serve.py src/mship/core/view/thread_links.py tests/core/test_serve.py tests/core/test_serve_specs.py tests/core/test_message_wait.py
git -C mothership commit -m "Expose active and archived inbox APIs"
mship journal "added compatible active/archive/search APIs and durable inbox mutations" --task ground-control-active-and-archived --repo mothership --action committed
```
<!-- /mship:task -->

<!-- mship:task id=3 acs=ac18,ac19,ac20,ac23,ac24 -->
### Task 3: Add Ground Control inbox data contracts

**Files:**
- Modify: `ground-control/android/app/src/main/java/com/atomikpanda/groundcontrol/data/dto/ThreadDtos.kt:6-25,46-61`
- Modify: `ground-control/android/app/src/main/java/com/atomikpanda/groundcontrol/data/dto/Dtos.kt:6-14`
- Modify: `ground-control/android/app/src/main/java/com/atomikpanda/groundcontrol/data/MshipClient.kt:580-640`
- Modify: `ground-control/android/app/src/main/java/com/atomikpanda/groundcontrol/data/SpecRepository.kt`
- Modify: `ground-control/android/app/src/main/java/com/atomikpanda/groundcontrol/data/QueueRepository.kt`
- Test: `ground-control/android/app/src/test/java/com/atomikpanda/groundcontrol/ThreadDtosTest.kt`
- Test: `ground-control/android/app/src/test/java/com/atomikpanda/groundcontrol/SpecApiTest.kt`

**Interfaces:**
- Consumes: Task 2 HTTP contract.
- Produces: Kotlin `InboxFilter`, `InboxState`, `InboxAction`, DTO classification fields, filtered list methods, and action methods with caller-provided mutation IDs.

- [ ] **Step 1: Write DTO/client tests**

Test decoding active/archived states and nullable reasons, backwards-compatible defaults for older servers, exact query encoding, and all four mutation paths/bodies for both entity types. Assert the client does not invent classification locally.

- [ ] **Step 2: Run focused Android tests and confirm missing contracts fail**

Run the two named Gradle test classes.

- [ ] **Step 3: Implement DTO enums and compatibility defaults**

Define serializable enums whose wire values are lowercase. New summary fields default to `ACTIVE`, null reason, and false pinned so older hosts remain usable. Full thread/spec records carry the same fields when returned by mutation routes.

- [ ] **Step 4: Implement client/repository operations**

List methods accept filter plus optional query and encode them as URL parameters. Add `mutateThreadInbox` and `mutateSpecInbox` taking action and mutation ID; repositories expose these without generating IDs so ViewModels own one stable ID per user gesture/retry.

- [ ] **Step 5: Run focused data tests**

Run the DTO/API tests and expect pass.

- [ ] **Step 6: Commit and journal Task 3**

```bash
git -C ground-control add android/app/src/main/java/com/atomikpanda/groundcontrol/data android/app/src/test/java/com/atomikpanda/groundcontrol/ThreadDtosTest.kt android/app/src/test/java/com/atomikpanda/groundcontrol/SpecApiTest.kt
git -C ground-control commit -m "Add inbox lifecycle API contracts"
mship journal "added Ground Control active/archive DTOs, filters, search, and mutation clients" --task ground-control-active-and-archived --repo ground-control --action committed
```
<!-- /mship:task -->

<!-- mship:task id=4 acs=ac21,ac22,ac23,ac24 -->
### Task 4: Build searchable Active and Archived tabs

**Files:**
- Modify: `ground-control/android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/MessagesViewModel.kt`
- Modify: `ground-control/android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages/MessagesScreen.kt`
- Modify: `ground-control/android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specs/SpecInboxViewModel.kt`
- Modify: `ground-control/android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specs/SpecInboxScreen.kt`
- Test: `ground-control/android/app/src/test/java/com/atomikpanda/groundcontrol/MessagesViewModelTest.kt`
- Test: `ground-control/android/app/src/test/java/com/atomikpanda/groundcontrol/SpecInboxViewModelTest.kt`

**Interfaces:**
- Consumes: Task 3 repositories/DTOs.
- Produces: `InboxTab.ACTIVE|ARCHIVED`, tab-scoped search state, and optimistic archive/restore/pin/unpin gestures reconciled with server results.

- [ ] **Step 1: Write ViewModel behavior tests**

Cover Active default, switching tabs, search propagation/scoping, one stable UUID mutation identity per action retry, optimistic movement between tabs, server-failure rollback against current state only, pin/unpin, alias-to-canonical connection replacement, and refresh from another device's durable state.

- [ ] **Step 2: Run focused ViewModel tests and confirm failure**

Run `MessagesViewModelTest` and `SpecInboxViewModelTest` filtered to the new cases.

- [ ] **Step 3: Implement ViewModel state and mutations**

Keep the existing unread/needs-you message filter as a secondary filter inside the Active tab. Tab/search changes trigger repository refreshes using server filters. Generate mutation IDs once per action invocation with `UUID.randomUUID().toString()` and reuse that ID inside any retry. Apply optimistic updates by entity ID and roll back only the failed entity into the current tab state, following the existing `SpecInboxViewModel.archiveSpec` concurrent-refresh-safe pattern.

- [ ] **Step 4: Implement Compose tabs, search, and actions**

Use Material 3 primary tabs for Active/Archived and an always-visible search field scoped to the selected tab. Thread/spec rows expose pin/unpin and archive/restore according to the returned state; actions have accessible labels. Empty states distinguish no active items from no archived items and never imply deletion.

- [ ] **Step 5: Run focused UI-state tests**

Run the two ViewModel test classes; expect pass.

- [ ] **Step 6: Commit and journal Task 4**

```bash
git -C ground-control add android/app/src/main/java/com/atomikpanda/groundcontrol/ui/messages android/app/src/main/java/com/atomikpanda/groundcontrol/ui/specs android/app/src/test/java/com/atomikpanda/groundcontrol/MessagesViewModelTest.kt android/app/src/test/java/com/atomikpanda/groundcontrol/SpecInboxViewModelTest.kt
git -C ground-control commit -m "Add active and archived inbox tabs"
mship journal "implemented searchable Active/Archived thread and spec tabs with durable actions" --task ground-control-active-and-archived --repo ground-control --action committed
```
<!-- /mship:task -->

<!-- mship:task id=5 acs=ac17,ac18,ac19,ac20,ac21,ac22,ac23,ac24,ac25 -->
### Task 5: Verify the multi-repo inbox lifecycle

**Files:**
- Modify only if verification exposes a contract defect in Tasks 1-4.
- Test: all changed Mothership and Ground Control test files.

**Interfaces:**
- Consumes: every prior task contract.
- Produces: passing recorded test/build evidence and coordinated PR-ready commits.

- [ ] **Step 1: Run complete Mothership verification**

From the Mothership worktree:

```bash
mship test --repos mothership
mship build --repos mothership
```

Expected: pass with no regressions.

- [ ] **Step 2: Run complete Ground Control verification**

From the Ground Control worktree:

```bash
mship test --repos ground-control
mship build --repos ground-control
source "$HOME/toolchains/android-env.sh" && task lint
```

Expected: pass. If a known coroutine test flakes, diagnose/fix its synchronization; do not retry or suppress it.

- [ ] **Step 3: Exercise the API/UI contract**

Start the current task's Mothership service and Ground Control app through existing task targets. Create representative pinned, attention, terminal-linked, inactive-unlinked, implemented, and lifecycle-archived records; verify server filters/reasons and both Android tabs/search/actions. Confirm restore changes inbox visibility without changing archived spec lifecycle and `all` still returns every record.

- [ ] **Step 4: Run final independent reviews**

Build fresh Mothership reviewer packages after all commits. Review backend classifier/storage/API and Android data/UI separately; fix every valid finding and rerun affected verification once.

- [ ] **Step 5: Record completion and prepare coordinated PRs**

```bash
mship journal "completed active/archive inbox implementation across mothership and ground-control; full tests, builds, lint, API/UI smoke, and reviews passed" --task ground-control-active-and-archived --action verified --test-state pass
```

Use one `mship finish` invocation with a real per-repo Summary/Test plan. Mothership PR lands first because Ground Control consumes its API; record that order in both PR bodies.
<!-- /mship:task -->
