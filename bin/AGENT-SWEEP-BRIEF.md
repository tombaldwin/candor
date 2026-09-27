# AGENT-SWEEP-BRIEF.md — verifying OPEN SOUNDNESS rows against HEAD

Hand this to any agent whose job is to RE-VERIFY rows rather than fix one. Pair it with
`bin/AGENT-CORPUS-BRIEF.md` (§F1 especially) and the row IDs themselves.

**PROMOTED OUT OF A SCRATCHPAD 2026-09-28.** This brief drove three sweep lanes on 2026-09-27 — 58 rows,
4 closes, 6 mechanisms corrected, several new cardinal sins — and it lived the whole time in a
SESSION-SCOPED scratchpad directory. That is SOUNDNESS R600's class (evidence a reader cannot follow
because the path dies with the session), committed hours after a ratchet was built to stop exactly it.
A brief that produces value is a durable artefact; keep it in the repo.

# Verification sweep — the method (shared by all sweep lanes)

You are RE-VERIFYING open SOUNDNESS rows against HEAD. The register has 134 open rows;
many were filed weeks ago, some have been fixed since and nobody updated the row, some
were filed with a mechanism that was wrong, and some reproduce exactly as written.

**Your deliverable is a per-row VERDICT TABLE, not a fix.** One line per row:
`REPRODUCES` / `FIXED (cite the commit that fixed it, and how you know)` / `PARTLY` /
`MECHANISM WRONG (state the corrected one)` / `RE-SCOPE (say to what)`.

## Rules that are not negotiable

1. **A row is FIXED only when you have measured it at HEAD *and* established the row's
   own claim no longer holds — behaviourally, not by reading a commit message.** The
   java sweep closed R622 only after BUILDING a pre-fix binary and watching the old
   behaviour appear there and not at HEAD. A green suite is not evidence.
2. **Never close a row that still reproduces**, however stale it looks. Re-date it
   instead: report it as `REPRODUCES` with fresh evidence.
3. **Attack the premise.** Roughly a third of the mechanisms in this register were
   wrong when filed, and always in the direction of a plausible half-fix. If the row's
   stated mechanism is wrong, that is a MORE valuable finding than a close — say so and
   state the corrected mechanism with the measurement that settles it.
4. **State what you held constant.** Every comparison needs its control. If the two
   arms differ in more than one thing, it is not a measurement.
5. **Prove the fixture reaches the code before concluding the code is fine.** A fixture
   that never reaches the branch reads exactly like a fixed defect. In this family a
   fixture NAMING CONVENTION once silently disabled the defect it was written to measure
   (all-caps type names, R719).
6. **A gate flip is the currency.** Where a row claims a silent under-report, the proof
   is a `deny <Effect> <unit>` that exits 0 while the program performs the effect —
   and the calibration is the same gate exiting 1 on a control on the SAME tree.
7. **Do not edit any repo but your own.** If you find a problem in another engine or in
   the spec, REPORT it; do not fix it.
8. **Do NOT run `gate-run.sh`, `conformance/run.sh`, or any four-way suite.** They are
   shared instruments and a concurrent build makes them lie. Run your own repo's unit
   suite only. The coordinator runs the gate lists at the join.
9. **Run long commands in the FOREGROUND.** Do not background them. If you do background
   one anyway, wait with the Monitor tool on a **PID** or on an **end-marker the job
   writes** — never `pgrep -f <pattern>`, which matches the waiting shell itself.
10. **File no SOUNDNESS rows.** The coordinator files them. If you find something new,
    describe it fully in your report and the coordinator will assign the ID.
11. Never read `$?` after a pipe. `timeout` does not exist on macOS. Do not `cd`-chain.

## If you fix something

You may land a fix where it is small, provable, and its own calibration is cheap — but
then the fix needs: a test that FAILS without it (drive both directions), a measured
reach (a change nothing reaches is not a fix), and for anything touching the classifier,
an A/B with **`/Users/tom/git/candor/bin/corpus-ab.py`** — never a fresh `ab.py`.
**`/tmp/candor-corpus` is HOLLOW (0 `.rs` files): an A/B over it prints 0/0/0 exactly
like a safely-inert change.** Use the pinned rosters in `candor/bin/corpus-census-*.tsv`.
Commit, DO NOT push.

**Stop and report if the premise you were given is wrong.** A hypothesis you did not try
to break is a guess.

## Instrument facts, verified at 2026-09-27 01:10 — do not re-derive these

- The A/B instrument is **`/Users/tom/git/candor/bin/corpus-ab.py`** and nothing else.
- **`/tmp/candor-corpus` is HOLLOW: 0 `.rs` files, 6 entries.** An A/B over it prints
  ADDED 0 / REMOVED 0 / CHANGED 0 — byte-identical to a safely-inert change. The REAL
  rust corpus is `~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/`, **1,465
  crate directories present locally against a 1,640-crate pinned roster** in
  `candor/bin/corpus-census-rust.tsv` (java: `corpus-census-java.tsv`, 501 artifacts).
  `candor/bin/corpus-census.sh` verifies a roster by sha1 AND by fitness — it has
  caught 16 jars that were sha1-correct with ZERO `.class` files.
- **Any A/B must prove its two arms are DIFFERENT BINARIES** (`shasum` them). Two arms
  that are the same binary print 0/0/0 as well. `corpus-ab.py` refuses this now; do not
  rely on that, state the shasums.
- **CHANGED 0 is not evidence until REACH is measured.** 17,944 analysed units once said
  "inert" and a probe said the code never ran.
- candor-rust pins a **NIGHTLY** toolchain. CI runs `cargo +stable clippy --all-targets
  -- -D warnings`, a DIFFERENT lint set. A bare `cargo clippy` passing tells you nothing
  about CI.
