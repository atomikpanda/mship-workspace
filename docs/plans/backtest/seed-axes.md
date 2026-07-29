# Seed assumptions — the 7 hand-authored rows (backtest source)

These are the seven divergence rows used for the AC-0 backtest. They are the human-authored
source that Wave 1's `SEED_AXES` constant (and Wave 2's L1 store) will mirror. Schema field is
`axis`; the human-facing word everywhere else is `assumption`. `options` is the load-bearing
column (contrastive enumeration), not `position`. `triggers` is **not** an injection filter — it
exists only for L4's deterministic in-code cross-check.

| axis | options | position | triggers |
|------|---------|----------|----------|
| repo topology | single-repo / monorepo / **metarepo** | **metarepo** — N repos, independent histories, shipped together | git/*, workspace/*, clone, branch, push |
| credential locus | worker-held / relay-attached / egress-host | **attach-at-relay** — the worker never holds the real credential | auth, token, push, credential |
| execution locus | local-only / disposable cloud worker | **both** — cloud is the priority path | run, dispatch, worker, remote |
| state durability | in-session / durable journal | **journal** — must survive process death | state, journal, persist, resume |
| review surface | terminal / async client | **undecided — flag it** (D1 open) | review, approve, verdict, UI |
| agent stream | live stream / journal-backed async | **journal-backed** | stream, output, follow, log |
| dispatched model | orchestrator-class / weaker | **assume weaker** (applies to all dispatched work) | — (applies to all dispatched work) |
