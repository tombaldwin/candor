# candor (umbrella) backlog

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
