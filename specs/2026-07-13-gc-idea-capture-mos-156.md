---
id: gc-idea-capture-mos-156
title: 'Idea capture: text to agent-drafted spec (Ground Control)'
status: implemented
created_at: '2026-07-13T13:09:47.109327Z'
updated_at: '2026-07-13T15:39:34.797376Z'
affected_repos:
- mothership
- ground-control
acceptance_criteria:
- id: ac1
  text: "Ground Control's Capture offers a 'brainstorm into a spec' choice distinct\
    \ from the existing 'quick note' (\u2192 thread) choice."
  verdict: approved
  evidence:
  - kind: commit
    ref: 535cdb9
    note: GC capture kind picker (Quick note vs Brainstorm into a spec); label fix
      fd9bb73
- id: ac2
  text: Choosing it seeds a thread with the idea text and emits a mailbox agent-event
    brainstorm handoff naming the thread and the idea.
  verdict: approved
  evidence:
  - kind: commit
    ref: 925cd82
    note: serve /capture seeds thread + posts agent-event handoff naming thread+idea;
      test_serve_capture
- id: ac3
  text: A host/cloud agent that drains the handoff conducts a brainstorming conversation
    in the thread (clarifying questions the operator answers from the phone) and,
    when the design is settled, produces a spec draft linked to the thread in needs_review.
  verdict: approved
  evidence:
  - kind: commit
    ref: 3bf7d79
    note: handoff instructs brainstorm-in-thread then spec from-thread->apply->needs_review;
      skill note
- id: ac4
  text: The active brainstorm is visible as a thread while it happens; the resulting
    spec appears in the GC inbox's needs_review group.
  verdict: approved
  evidence:
  - kind: commit
    ref: 94987c1
    note: captured idea is a real thread (visible); apply lands spec in needs_review
      inbox group
- id: ac5
  text: "mship serve remains LLM-free (guarded by a test), and the capture\u2192thread\u2192\
    spec pipeline is driver-agnostic \u2014 documented so a future GC-app or serve-side\
    \ LLM driver can drive the same flow without redesign."
  verdict: approved
  evidence:
  - kind: commit
    ref: 9c572ba
    note: LLM-free guard test on capture/draft path; contract carries no host-agent
      assumption
- id: ac6
  text: 'The handoff is idempotent: one capture spawns one brainstorm driver; re-draining
    or re-capturing the same idea does not duplicate the handoff or the driver.'
  verdict: approved
  evidence:
  - kind: commit
    ref: 925cd82
    note: one agent-event per capture; awaiting_agent_event clears on agent non-event
      reply
- id: ac7
  text: If no agent processes the handoff, the captured idea remains a visible thread
    the operator can still open and continue (no lost capture).
  verdict: approved
  evidence:
  - kind: commit
    ref: 94987c1
    note: create_thread persists the idea before the event append; visible thread
      survives no-agent
open_questions: []
non_goals:
- "No LLM on serve and no LLM in the GC app yet \u2014 both deferred. The design must\
  \ NOT preclude a future GC-app-side LLM driver (explicit operator constraint): keep\
  \ the capture\u2192thread\u2192spec contract driver-agnostic."
- "A one-shot text\u2192spec with no brainstorming \u2014 explicitly rejected; the\
  \ brainstorm is the point."
- "The 'refine existing spec' and 'create directive' entry points \u2014 v1 is 'brainstorm\
  \ a new idea \u2192 spec'; the others are follow-ups."
- Voice capture (D1 / MOS-161).
- "Removing the existing quick-note thread capture \u2014 v1 keeps it (as the 'quick\
  \ note' kind) and adds the 'brainstorm into a spec' kind."
- "Auto-dispatch of the drafted spec \u2014 the flow stops at needs_review; approving/dispatching\
  \ stays the operator's action (fed by the Queue tab, MOS-225)."
risks:
- "Needs an agent (driver) available: if none is running, the captured idea remains\
  \ a visible thread until a driver picks it up \u2014 graceful (nothing lost), and\
  \ the cost of keeping serve LLM-free; the unattended/cloud-runner direction mitigates\
  \ it over time."
- 'The brainstorm is multi-turn and async: the operator may not answer immediately,
  so the agent must wait on the thread (not block), and a stalled brainstorm must
  leave a resumable thread, not a broken half-state.'
- 'Idempotency: one capture must spawn one brainstorm driver; re-drain / re-capture
  / an agent crash mid-brainstorm must not spawn duplicate drivers or duplicate handoffs.'
- "Driver-agnostic leakage: keeping the contract truly driver-agnostic requires the\
  \ thread\u2192spec API to expose everything a future non-agent driver (GC-app LLM)\
  \ needs \u2014 the seeded idea, the conversation, a way to emit the spec \u2014\
  \ without host-agent-specific assumptions."
- "Brainstorm quality varies with the driver \u2014 acceptable; the operator reviews\
  \ every spec at needs_review before it goes anywhere."
task_slug: gc-idea-capture-mos-156
work_item_id: wi-20260713134715-b0cd8147
clarification_reason: null
---
## Problem

Capturing intent away from the desk is where mobile is most natural, but a good spec doesn't come from a blob of text piped into a template — it comes from brainstorming: clarifying questions, approaches, scope calls (exactly how the Queue-tab spec got made). A one-shot text→spec skips the very thing that makes a spec good. Today Ground Control's Capture only creates a dead chat thread you must manually promote; nothing brainstorms a captured idea toward a spec, so ideas either sit as loose threads or never become reviewable work.

## User story

As an operator away from my desk, I want to capture an idea on my phone and have an agent brainstorm it with me right there in chat until it's a real spec draft in my inbox, so that I can shape work from my phone the same way I would at my desk — not just dump text into a template.

## Approach

Capture → agent-led brainstorm → spec, agent-in-the-loop so serve stays LLM-free, with a driver-agnostic pipeline (operator decisions 2026-07-13). (1) Capture: GC's Capture offers a 'brainstorm into a spec' choice alongside the existing 'quick note' (→ thread). Submitting an idea seeds a thread with the idea text and posts one mailbox agent-event brainstorm handoff naming the thread + idea. Reuses thread-create + the mailbox. (2) Brainstorm: a host/cloud agent drains the handoff (shipped mship _drain Stop-hook / inbox wait long-poll — MOS-194/#239/MOS-232) and runs the brainstorming flow IN the thread: clarifying questions one at a time over chat, the operator answers from the phone, they converge. This is the brainstorming skill conducted over the mailbox — the exact medium this session uses. (3) Spec: when the design is settled the agent produces the spec draft from the thread (mship spec from-thread / draft+apply), landing it in needs_review linked to the thread; GC's inbox already groups needs_review at the top so it appears with no new inbox UI. (4) Driver-agnostic contract: a 'brainstorm driver' consumes {thread seeded with an idea} and produces {spec in needs_review linked to it}. v1's driver is the host/cloud agent via the mailbox handoff; the endpoint/thread/mailbox/spec-from-thread APIs carry NO host-agent-specific assumption, so a future LLM inside the GC app (deferred) — or a serve-side one — can implement the same contract without a redesign. The spec is created by the driver at the END of the brainstorm (no empty stub floats mid-conversation; the in-progress signal is the live thread). Two repos: mothership (capture endpoint + brainstorm handoff + skill note) and ground-control (capture kind picker + wiring).

## Architecture

Serve (core/serve.py capture-write section + mailbox): a new capture endpoint (e.g. POST /specs/capture) creates a thread seeded with the idea (reusing thread-create) and posts ONE mailbox message of an agent-event kind whose body is the brainstorm handoff (thread id + idea + 'run the brainstorming flow in this thread and produce a spec via spec from-thread'). Returns the thread id. Idempotency keyed on the thread/capture id. No LLM dependency added to serve. The spec is created by the driver at the END of the brainstorm (via spec from-thread/apply) so no empty spec stub floats during the conversation; the in-progress signal is the live thread.

Ground Control (ground-control/android): the Capture entry gains a kind picker — Quick note (today's POST /threads path, unchanged) vs Brainstorm into a spec (new: captureBrainstorm(conn, idea) → the capture endpoint). The brainstorm conversation happens in the existing chat/thread UI; the resulting spec surfaces in the spec inbox.

Driver-agnostic contract (future-proofing): define the brainstorm step as 'a driver turns a seeded thread into a needs_review spec linked to it.' v1 ships one driver — the host/cloud agent triggered by the mailbox handoff, documented in a working-with-mothership skill note. The endpoint/thread/spec APIs carry no host-agent-specific assumption, so a future GC-app LLM or serve-side driver (both deferred) can implement the same contract.

## Testing

Serve: the capture endpoint creates a thread seeded with the idea and posts exactly one agent-event brainstorm handoff naming the thread + idea; a repeat capture/emit is idempotent (no duplicate handoff); a guard test asserts no LLM/model client is imported into the capture path.

Ground Control (JVM unit tests only — no emulator): the capture kind picker routes Quick note → thread-create and Brainstorm into a spec → captureBrainstorm (Ktor MockEngine, correct path + Bearer auth, real-time side-effect assertions per the known fire-and-forget flake); the ViewModel surfaces success/error.

Agent-driver loop: the brainstorm-over-chat + spec from-thread/apply reuses already-shipped, already-tested commands; verified end-to-end by capturing an idea, answering the agent's questions in the thread, and confirming a spec reaches needs_review linked to the thread.
