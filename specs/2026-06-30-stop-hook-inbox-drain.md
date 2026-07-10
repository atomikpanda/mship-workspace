---
id: stop-hook-inbox-drain
title: 'Stop-hook inbox drain: live agent answers phone messages at turn boundaries
  (#239 slice 1)'
status: implemented
created_at: '2026-06-30T10:56:03.747461Z'
updated_at: '2026-06-30T11:47:34.231148Z'
affected_repos:
- mothership
acceptance_criteria:
- id: ac1
  text: '`mship init --install-hooks` installs a `Stop` hook into `.claude/settings.json`
    whose command is `mship _drain`, alongside the existing SessionStart and PreToolUse
    hooks; the install is idempotent, preserves existing hooks, and tolerates a malformed/empty
    settings file.'
  verdict: approved
- id: ac2
  text: When the cwd-resolved workspace's inbox has at least one awaiting thread and
    `stop_hook_active` is not set, `mship _drain` (fed the Stop event JSON on stdin)
    emits `{"decision":"block","reason":...}` whose reason lists every awaiting thread's
    id and pending human text and instructs answering via `mship reply <thread-id>`.
  verdict: approved
- id: ac3
  text: When the inbox is empty, `mship _drain` allows the stop (no block / exit 0).
  verdict: approved
- id: ac4
  text: "When `stop_hook_active` is true, `mship _drain` does not block even if messages\
    \ await (loop safety) \u2014 the turn is allowed to end."
  verdict: approved
- id: ac5
  text: '`mship _drain` reads only the cwd-resolved workspace''s `MessageStore`; run
    outside any workspace it allows the stop (fail-open) and touches no other store.'
  verdict: approved
- id: ac6
  text: '`mship _drain` fails open (allows the stop) on malformed stdin, an unreadable
    store, or any other error.'
  verdict: approved
- id: ac7
  text: Tests (pytest) cover `_drain` (block-when-awaiting incl. multi-thread formatting,
    allow-when-empty, allow-when-stop_hook_active, fail-open cases), `install_stop_hook`
    (fresh install, idempotent, preserves SessionStart/PreToolUse, malformed settings
    tolerated), and the `init --install-hooks` wiring; the full mothership suite is
    green.
  verdict: approved
open_questions: []
non_goals:
- "Waking an idle-but-open session (the agent-backgrounded `mship inbox wait` long-poll\
  \ + read cursor) \u2014 the follow-on slice (#239 Spec 2)."
- "Serve-side auto-dispatch, `claude -p`, or spawning/triggering any new agent session\
  \ \u2014 explicitly out of #239; this slice only feeds the already-running session."
- "Cross-workspace routing \u2014 topology is one `mship serve` + one agent per workspace,\
  \ so routing is structural, not designed here."
- "`task_slug` routing / steering a specific task's agent vs spawning a drafting agent\
  \ \u2014 a later layer."
- "How the agent composes its reply (free-text vs drafting a spec via `mship spec\
  \ draft/apply`) \u2014 that is the agent's job / the capture-as-conversation spec,\
  \ not this trigger."
- "Notifications/push to the phone when a reply lands \u2014 a later slice."
- "A read/seen/answered flag on messages \u2014 this slice relies purely on the derived\
  \ `awaiting_reply`."
risks:
- "Infinite Stop-hook loop if the agent can't clear the inbox \u2014 mitigated by\
  \ the `stop_hook_active` guard (block at most once per stop-chain); unanswered messages\
  \ simply remain awaiting for the next turn boundary."
- "The Stop hook runs on EVERY turn end, so `_drain` must be cheap \u2014 a single\
  \ `MessageStore.list()` read, no network, no heavy work."
- "A blocking Stop hook is disruptive if it fires when the operator wanted the turn\
  \ to just end \u2014 mitigated by blocking only when a real message awaits; an empty\
  \ inbox is a transparent no-op (exit 0)."
- "Workspace mis-resolution could read the wrong store \u2014 mitigated by anchoring\
  \ to the cwd-resolved workspace exactly like `mship inbox`, and failing open (allow\
  \ stop) when no workspace resolves rather than falling back to any other location."
task_slug: stop-hook-inbox-drain
work_item_id: wi-20260702110439-04ac1813
---
## Problem

The message mailbox (spec `message-mailbox`, implemented) is deliberately store-and-forward: a phone message lands in `<workspace>/.mothership/messages/`, but an actively-working agent only sees it if the operator (or the agent) runs `mship inbox`. Issue #239 tracks the deferred trigger layer — letting an agent learn a message is waiting without a human manually polling. This spec is its smallest, highest-value slice: while you are actively working with a live agent, the next turn boundary should auto-drain the inbox and answer, with no manual `mship inbox`. (Waking an idle-but-open session is the follow-on slice; spawning agents / `claude -p` is explicitly out of #239 — agents are turn-based, not daemons, and the topology is one `mship serve` + one agent per workspace, so messages never cross workspaces.)

## User story

As a Mothership operator actively working with a host-side agent, I want a message I send from my phone to be picked up and answered at the agent's next turn boundary automatically, so that I don't have to tell the agent to run `mship inbox`.

## Approach

A Claude Code `Stop` hook drains this workspace's inbox at each turn boundary. Three additive, mothership-only pieces:

1. **`mship _drain`** — a new hidden CLI command (in `src/mship/cli/internal.py`, mirroring `_session-context` and `_journal-commit`). It reads the Stop-hook event JSON from stdin, resolves the workspace from cwd (via the same container/config path as `mship inbox`), and lists awaiting threads (latest message role == `human`) from that workspace's `MessageStore` — reusing the existing `mship inbox` core path so drain and inbox never disagree. Behavior:
   - inbox empty → allow the stop (exit 0, no block).
   - inbox non-empty AND `stop_hook_active` is not set → emit Claude's Stop-hook block JSON `{"decision": "block", "reason": <all awaiting threads formatted: each thread id + its pending human text + an instruction to answer via `mship reply <thread-id> "<text>"`>}`. The agent answers every pending thread, replies (which clears them from the inbox), and the next Stop fires; with the inbox now empty it allows the stop.
   - `stop_hook_active` is true → never block (loop safety): even if messages await, allow the stop; they are caught at the next turn boundary.
   - Fail open on ANY error (not in a workspace, unreadable store, malformed stdin) → allow the stop. A messaging glitch must never trap the agent.
   It injects ALL currently-awaiting threads in a single block so multiple pending messages are handled in one continuation turn.

2. **`install_stop_hook(workspace_root)`** in `src/mship/core/claude_settings.py` — a third caller of the existing event-key-agnostic `_install_hook_entry`, with `event_key="Stop"` and command `mship _drain`. Idempotent; preserves existing hooks; tolerates a malformed settings file (identical contract to the SessionStart and PreToolUse installers).

3. **Init wiring** — `mship init --install-hooks` installs the Stop hook alongside the SessionStart and PreToolUse guard hooks (extend the existing `_install_agent_hooks_with_output` in `src/mship/cli/init.py`).

No read cursor and no long-poll in this slice — awaiting-derivation (latest-message-role) is sufficient for a turn-boundary drain. Workspace isolation is structural and enforced: `_drain` only ever reads the cwd-resolved workspace's store and fails open if it can't resolve one, so a message can only be drained by its own workspace's agent.

## Architecture

`_drain` is a thin stdin/JSON adapter over the existing inbox core: it reuses the same `MessageStore` + awaiting-derivation that `mship inbox` (`src/mship/cli/message.py`, `src/mship/core/message_store.py`, `Thread.awaiting_reply` in `src/mship/core/message.py`) already uses, so the two can never disagree. `install_stop_hook` reuses the event-key-agnostic `_install_hook_entry` in `claude_settings.py` (the same helper behind `install_session_hook` and `install_pretooluse_guard_hook`). Init wiring reuses `_install_agent_hooks_with_output` in `cli/init.py`. The Stop-hook event contract (stdin JSON includes `stop_hook_active`; stdout `{"decision":"block","reason":...}` blocks the stop and feeds the reason to the model; exit 0 / no decision allows it) mirrors how `_guard-edit` already consumes a PreToolUse event and how `_session-context` is invoked by a hook.

## Testing

CLI tests (CliRunner, stdin-fed Stop event JSON) for `_drain`: blocks with a reason naming each awaiting thread when the inbox is non-empty and `stop_hook_active` is false; allows the stop when the inbox is empty; allows the stop when `stop_hook_active` is true even with messages awaiting; fails open (allows) on malformed stdin and outside a workspace. `claude_settings` tests for `install_stop_hook` mirroring the PreToolUse-guard installer tests (fresh install, idempotency, preservation of the other hooks, malformed-settings tolerance). A `cli/init` test asserting `init --install-hooks` writes the `Stop` entry with command `mship _drain`. Use a `MessageStore` seeded under a tmp workspace to drive the awaiting/empty cases.
