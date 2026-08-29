# Ground Control UI/UX Review — Findings (2026-07-14)

Source: read-only UI/UX review agent over the GC Compose files. Kept for reference when speccing the wins below. File/line refs are against the main `ground-control` checkout at review time.

## Top wins (ranked)
1. **Queue core action is an invisible gesture.** Fling right=approve / left=flag has no on-screen affordance; `CriteriaCard` (QueueScreen.kt:314–331) and `QuestionsCard` (332–336) have no visible approve control; Skip (174) is the most prominent button. Fix: bottom Approve/Request-changes bar on every card; colored "✓ Approve"/"⚑ Flag" drag stamp that fades in with distance (FlingCard 197–246); first-run coach mark.
2. **Whole-spec approve is silent + non-undoable; reject is gated.** `approveAllCurrent`→`removeSpecCardsAdvancing(armUndo=false)` (QueueViewModel.kt:148–159) so snackbar (QueueScreen.kt:111–118) shows nothing on the highest-blast action; fling-left forces typed reason (RejectSheet 425–455). Fix: always confirm whole-spec approval by name; quick confirm on terminal chunk.
3. **Home buries needs-you + never funnels to Queue.** Attention items (HomeScreen.kt:182–184) render below workspace rail (97–128), errors (130–137), browse-all (140–148), threads card (154–160), filter row (161–166); no header/count while "New messages" IS labeled (188–193). Fix: lead with "Needs you · N" + "Review N in Queue →"; demote rail + threads.
4. **Approve tinted question-cyan in Queue+SpecDetail, green on Home.** `primary`=darkQuestion cyan (Theme.kt:12,25); VerdictToggles approved→primary (QueueScreen.kt:392), CriterionRow approved→primary (SpecDetailScreen.kt:190); Home uses semantic green (NeedsYouAccent.kt:12–16). Fix: approve→`LocalSemanticColors.current.approval` (green) everywhere; flag→error (already right).
5. **Spec detail: Approve less friction than Dispatch.** Approve one-tap no confirm (SpecDetailScreen.kt:282); Plan-implementation has ConfirmDialog (298–303); readiness summary bodySmall buried (123–126); "Approve anyway" behind "▾" TextButton (283). Fix: promote summary to colored counter chips; Approve single filled primary + light confirm; Plan-implementation tonal; labeled overflow.

## Quick wins (batchable)
- Approve toggles → semantic green (QueueScreen.kt:392, SpecDetailScreen.kt:190).
- Content descriptions on tier icons (HomeScreen.kt:294, 305 pass null).
- Humanize thread-list timestamps: raw `updatedAt` (MessagesScreen.kt:213) → `relativeTimeAgo` (exists ConversationScreen.kt:385).
- Label "Needs you" section on Home + count.
- Bump muted text contrast: `darkMuted 0xFF6272A4` on `darkSurface 0xFF12161F` ≈3.8:1, below WCAG AA 4.5:1; carries card meta / timestamps / read-state.
- Replace SpecDetail "▾" caret (SpecDetailScreen.kt:283) with labeled overflow.
- Unify request-changes: SpecDetail ReasonDialog (306–325) → shared MultilineComposeInput bottom sheet (Queue RejectSheet / DecisionCard CommentSheet).
- "Recommended" text tag on decision option (DecisionCard.kt:186–193) — currently color-only.

## Per-surface notes
- **Messages:** pinned context chrome (activity strip 226, View-spec 228–237, Related-work-item 241–253) sits outside the LazyColumn, eating the top third on linked threads → make collapsible / move into scroll. Active `DecisionCard` (DecisionCard.kt:85–89) looks like an ordinary agent bubble → accent it (URGENT tier). No per-message timestamps (MessageRow 413–511).
- **Queue:** gesture availability varies silently by card type (`canFlingRight = Prose||Criteria`, 147–151) — DecisionCard/QuestionsCard flung right just spring back. No batch "Approve all" on CriteriaCard. QuestionAnswerRow single-line OutlinedTextField (404–421) vs app multiline idiom.
- **Theme:** `primary` overloaded as question-cyan app-wide (FAB, human bubble, links, approve, jump-to-latest pill). Dynamic-type truncation risk from many `maxLines=1`.

## Proposed spec bundling
- **A:** Queue action affordance + whole-spec approve confirmation (Wins 1+2) — core surface, start here.
- **B:** Verdict-color + accessibility quick wins (Win 4 + contrast + timestamps + icon labels) — one cheap PR.
- **C:** Home leads with needs-you queue (Win 3).
- **D:** Spec-detail readiness + action hierarchy (Win 5).
