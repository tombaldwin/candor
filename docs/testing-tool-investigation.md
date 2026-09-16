# Is candor useful as a TESTING tool?

**Status: OPEN INVESTIGATION. Started 2026-09-16.** Nothing here is a commitment, and the honest
outcome may be "no, except for one slice". This document exists so that answer is *measured* rather
than argued — the family's own history says a plausible sentence nobody re-checks is how this project
gets things wrong (R445, R449, and five brief premises in one session).

## The one-line thesis to attack

**candor is a BOUNDARY tool, not a BEHAVIOUR tool.** Most testing questions are behaviour questions,
which is why most of them fit badly. But **test hermeticity is a boundary question wearing testing
clothes**, and it is the one place where candor's central design choice — sound over-approximation with
disclosed unknowns — is a FEATURE rather than a tax.

If that thesis is wrong, this document should say so and why.

## What already exists (verified 2026-09-16, not remembered)

- Tests are **excluded by default**: *"the report describes what the CRATE does, not what its harness
  does (`--include-tests` keeps them)"* — `candor-rust/crates/candor-scan/src/main.rs:31,37`.
- `test-exclusion` is pinned by the four-way conformance suite (`candor-spec/conformance/run.sh`).
- So pointing candor AT a test tree is **a flag, not a feature**. That is the cheap-experiment lever.

## The slice that looks strong — TEST HERMETICITY

*"Which of my unit tests touch the network, the filesystem, or a subprocess?"* is a question teams have
and cannot easily answer. It is the root cause of slow suites, flaky CI, and tests that pass locally and
fail in a sandbox.

Why candor's trade is RIGHT here, rather than merely applicable:
- A hermeticity gate wants **sound over-approximation** — "no test may reach `Net`" must never miss one,
  and a false positive costs a glance. That is the trade the product already makes everywhere.
- **`Unknown` becomes a useful answer**, not noise: *"I cannot prove this test is hermetic"* is exactly
  what you want to know before trusting it in a sandbox. Contrast S4/R443, where `Unknown` in a
  correctness gate is a usability problem.

## The slices that look weak

- **Test selection / impact analysis** (*"given this diff, which tests must run?"*) wants PRECISION.
  A static over-approximation over-selects by construction, and `Unknown` is ~20% of functions in
  closure-heavy code (`eval/unknownwhy-sweep/FINDINGS.md`: 171 of 845). You would re-run most of the
  suite most of the time. The real question is also dynamic — what a test EXECUTES, not what it could
  reach.
- **Coverage-shaped questions** (*"which effectful functions have no test?"*) need coverage data joined
  to candor's effect map. candor supplies one half and has no view of the other. An integration, not a
  product.

## QUESTIONS THIS DOCUMENT MUST ANSWER (the agent's brief)

1. **Is the hermeticity slice real?** Point the existing gate at a real test tree (`--include-tests`
   plus `deny Net`/`deny Fs`/`deny Exec`) on repos we already have. **Is the answer SURPRISING?** If a
   maintainer would look at the list and say "I had no idea", there is something here. If they would
   shrug, there is not.
2. **What is the false-positive rate in practice?** A test that COULD reach `Net` on a path it never
   takes is the failure mode that would sink this. Quantify it on real trees, do not estimate it.
3. **How much does `Unknown` dominate test code specifically?** Test harnesses are closure-heavy
   (assertions, fixtures, mocks). If `Unknown` swamps the answer, the slice dies.
4. **Do the four engines differ here?** java reads bytecode and ts asks the checker; rust and swift are
   syntactic. A feature that only works on two engines is a different proposition.
5. **What would the smallest honest product be?** A verb? A policy template? A doc page? Name it, and
   name what it does NOT do.
6. **What is the strongest argument AGAINST the whole idea?** Make it properly.

## Findings

*(to be filled in by investigation — record what was MEASURED, and mark what was INFERRED)*
