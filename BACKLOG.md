# candor (umbrella) backlog

## Direction — next strategic bets (family-level)

Correctness/honesty is well-shored (the 2026-06-17 honesty arc: 4 confidence methods, 6 silent
under-reports fixed, async-HTTP stack calibrated, all shipped). The value now concentrates in two bets,
both cross-engine. Detailed specs live in `candor-rust/BACKLOG.md` (P0 + AS-EFF-006 sections).

- **[P0 — north star] Agent edit-time blast-radius feedback.** Sharpen the *delta back to the agent*:
  the diff / `CANDOR_REVIEW` self-review / MCP / Claude Code hook surface that shows an edit's gained
  effects *including the transitive blast radius*. This is where the pre-registered eval's decisive lift
  lives (blast-radius is a reasoning gap, not a cost gap). Everything that tightens that loop wins.

- **[deployability] Effect-regression CI ratchet (AS-EFF-005) + policy boundaries (AS-EFF-006).** The
  ratchet ("don't regress — fail the PR that makes a parser open a socket") + policy (an effect reached
  *through a helper* is the architectural violation to gate). Low adoption cost, real felt need,
  under-emphasised relative to deployability — promote it.

## fingerprint

- **Drop the letter grade; reframe the structure score as descriptive/relative.** The A–F grade in
  `--json` metadata reads as a quality verdict, which is exactly the "candor score" framing we
  deliberately rejected (a single grade fights candor's deterministic-per-function-facts positioning,
  is gameable, and buries the real signal). Keep the 0–1 `structure` number and its four explainable
  components (smear, unknownShare, tangleExcess, cycleRatio); document it as a structural descriptor,
  not a judgment. The components are the actionable part; the composite is the weakest.

- **`--baseline <report>` diff for the structure score.** Land the metric in candor's deterministic-gate
  wheelhouse instead of the vanity-number one: report the *change* vs a baseline report
  ("structure −0.06 since main; tangleExcess up, driven by these 3 new cycles") rather than an absolute
  grade. Trend/PR-over-PR is the honest, useful framing.
