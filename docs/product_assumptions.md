| axis | options | position | triggers |
| -- | -- | -- | -- |
| repo topology | single / mono / meta | **meta** — the *workspace-under-management* is N repos, independent histories, shipped together | git/*, workspace/*, clone, branch, push |
| credential locus | worker / relay / egress host | **attach-at-relay**; worker never holds the real credential | auth, token, push, credential |
| execution locus | local / disposable cloud worker | **both**; cloud is the priority path | run, dispatch, worker, remote |
| state durability | in-session / durable journal | **journal**; must survive process death | state, journal, persist, resume |
| review surface | terminal / async client | **undecided — flag it** (D1). Disposition rule: *covered* when a plan surfaces/respects the open choice; *not-covered* only when it silently declares one surface canonical | review, approve, verdict, UI |
| agent stream | live stream / journal-backed async | **journal-backed**. Scope: all run output (shell + agent), not agent-session output only | stream, output, follow, log |
| dispatched model | orchestrator-class / weaker | **assume weaker**. N/A unless the plan itself dispatches agent work | (applies whenever the plan dispatches agent work) |
