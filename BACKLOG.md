# candor (family) backlog

**This file is the plan.** It is short on purpose and is REWRITTEN at every join or release, not appended to.
Last rewritten 2026-10-24, after the v0.40.16 family release and a full audit of the old backlog
(`~/candor-handoff/backlogaudit-0416/`: three audits, a re-measurement on published 0.40.16, Fable's review).

- **What is broken** lives in the register, `candor-spec/SOUNDNESS.md`. This file names the order of work, not
  the detail. Re-derive the counts, do not copy them forward:

      python3 candor-spec/scripts/sin-direction.py --list    # open cardinal sins, by direction
      python3 candor-spec/scripts/soundness-status.py         # open / closed buckets

  At this rewrite (candor-spec `de666b8`): **288 open rows; 52 open cardinal sins** (rust-scan 17, java 16,
  swift 11, ts 7, rust 1); 28 unsettled.
- **How to work** lives in `CLAUDE.md` (method rules) and `bin/AGENT-*-BRIEF.md`. Not here.
- **History.** The backlog as it stood from July to 2026-10-24 is `history/BACKLOG-2026-07-to-09.md`,
  UNCHANGED, with its line numbers intact: any older citation `BACKLOG.md:<N>` means
  `history/BACKLOG-2026-07-to-09.md:<N>`. Its top "THE PLAN" section stopped being the queue on 2026-09-28.
  Do not work from it; mine it.

## 0. The call-target program — the main line of work (Tom: "Go", 2026-10-25)

Most open sins are not separate bugs. A four-engine analysis (`~/candor-handoff/calltarget-analysis/`: each
engine's executed matrix, two prototypes, Fable's synthesis) found the same three defects in every engine:
an implicit call into user code that the engine does not recognise produces no edge and no `Unknown` (an
explicit one always ends in `Unknown`); producers publish dependency keys for only some member kinds; and unit
identity is coarser than the language's. So the work is a staged restructure, not row-by-row fixing. Rounds
(FABLE-SYNTHESIS §3.4; about 6–8 lane-rounds per engine):

1. **Round 1 — SHIPPED in v0.40.17 (2026-10-25)** (`~/candor-handoff/calltarget-round1/`: BRIEF, per-engine
   REPORTs, FABLE-REVIEW, FABLE-RUST-R1429). Matrix silent cases at the caller: java 631 → 537, swift 437 → 328,
   ts 4,006 → 3,316, rust 474 → 398 (rust = typing groundwork, not structural). Open sins 70 → 60. Round-2
   corrections are FABLE-REVIEW §5; cross-engine controls to add first are §3 (consumer-union subtree scoping
   R1436/java `c_ct_unrelated_inh`; a producer over-reach cell; the non-invoking look-alike axis). ts: one target oracle `bodiesFor`
   for every reader. java: `CallTargets.resolve` as the first shared entry point, plus the degraded-sidecar
   disclosure (R1377/R1333). swift: dependency keys for `open` class members and one dependency lookup for
   operators, subscripts, hashing (R1416, R1415). rust: one path-value typing fix (R1426) with the matrix re-cut
   by spelling, plus R400. Spec: rows R1405–R1428, draft site/disclosure and wire clauses, the R764 four-way cell
   and a cross-engine call-target PART.
2. **Round 2:** implicit-site tables generated from each platform's own declarations, behind the site clause.
3. **Round 3:** exact unit identity (removes charges: independent checker over every removal).
4. **Round 4:** producers publish what a consumer needs for generics over std bounds (R974's rung, after a census).

Decisions taken with it (Fable's defaults): price both strictness options of the site clause before choosing;
count before un-deferring R974; java's restructure does not wait for the Phase D split; identity in round 3.
Rule for every lane: a row maps to a matrix cell before it is fixed, and a change is accepted when it retires a
list or a reader. Rows the program subsumes are marked "SUBSUMED by call-target round N" in the register; do not
fix them one at a time.

## 1. Silent under-reports (cardinal sins), by engine

The rows below are the queue as it stood before the program. Rows marked SUBSUMED in the register go through
the program; the rest continue as individual fixes. Each lane re-verifies against HEAD before fixing (about one
in five has a wrong mechanism) and is held to the truth-monotone bar against the LAST RELEASE (`CLAUDE.md`).

- **candor-rust (scan).** R400 (reopened: its fix was reverted in `9889929`, both halves reproduce on 0.40.16);
  R1395 (a chained dependency's effectful `Display` impl reached through a dyn/generic helper); then the 0.40.16
  residue: R1388 (element typing), R1359 (rule-2 `calls` walk), R1373, R1385–R1386, R1390–R1393, the ana2 seed.
  Remaining sins: R1227 R1245 R1246 R1247 R1253 R1257 R1280 R1297 R1308 R1319 R1322 R1323 R1325 R1347.
  Also R1387: an over-charge 0.40.16 itself introduced (not a sin, but shipped).
- **candor-java.** R1394 (a deferred container not bound to a field of its own class: local
  `ThreadLocal.withInitial`, a constructor-parameter field, Kotlin local `by lazy`); R1361/R1362 (fixable
  silent); R1377; R1379. Remaining sins: R1242 R1277 R1316 R1317 R1328 R1329 R1331 R1332 R1333 R1335 R1355.
  Non-sin next: R1372 (a)/(b), CARVE-A exactness.
- **candor-swift.** R1397 (computed property on an `extension Array` has no call edge); R1366; R1374;
  R1380–R1383. Remaining sins: R1249 R1251 R1258 R1271 R1282 R1283 R1284 R1310 R1312.
  Also R1396: same-named extension members from two modules merge, which fails a `deny` on a pure caller.
- **candor-ts.** R1356, R1365 (sins); R1358, R1369. Remaining sins: R1248 R1274 R1296 R1309 R1311.

## 2. A ruling that was never carried out

- **R1398 — swift must CHARGE raw C calls (`unlink`, `symlink`, `system`), not disclose them.** Ruled
  2026-09-03 (`history/BACKLOG-2026-07-to-09.md:8242`). Today swift reports `Unknown`/`native:`, SPEC.md
  (~:5634) still permits that, and conformance PART 79 (`swift-defect-rawc`) pins it. Order: SPEC clause →
  flip the PART 79 arm → swift change. Read R61 and R130 first; the `@_silgen_name` half shares the list.

## 3. Wrong answers that are not silences

- R1399 — candor-agents `scan`/`observe` exit 2 leaves the previous `--out` report in place (⟨0.28⟩ rule;
  PART 37 has no agents arm).
- R1401 — candor-rust: a deleted workspace member's old report still gates; `candor-query gate --report`
  and `candor-scan --policy` disagree on the same tree. Needs the wire decision SPEC.md (~:3605) deferred.
- R1400 — candor-ts: no sources plus an unreadable `--policy` prints a false "no denied effect" message
  (still exits 2).
- R1402 — `cargo candor explain <name>` exits 0 for a name that does not exist.
- R230 — rust callee fabrication, reopened in the audit (R200 widened it); not re-measured on 0.40.16.

## 4. Housekeeping and instruments

- **Pins that adopters actually run:** the SARIF fallback pin in `adopt/candor.yml` (~:103) is `2e8dbc7`
  from July, five fixes behind, and no preflight row checks it; the live `candor-action-demo` pins
  candor-java 0.8.7.
- **Register:** the 17 rows still worded "FIX COMMITTED LOCALLY" (R155, R1223, R1232, R1234, R1236, R1239,
  R1259, R1263, R1265, R1268, R1280, R1281, R1299, R1307, R1320, R1321, R1327) and R1325; then a release step
  that flips "fixed on main" rows to shipped, so this stops depending on memory. R376 (open vs killed) needs a
  judgement.
- **CI:** candor-rust `coverage-gate-refresh` red at `08a53ef` (2026-10-21), uninvestigated.
- **A/B instrument:** move `exclcheck` and a per-report analysed-count check into `bin/` (R1392).
- **Temp-dir leaks:** about 5,000 `candor-*` dirs in `$TMPDIR` (java tests, `candor-scan/tests/cli.rs`,
  `bin/gates.sh`); and stray empty directories in the umbrella root (`0/`, `10.0.0.5`, `CANDOR_R847_ON=1`),
  the shape of a mis-parsed argument becoming a path.
- **Not a register row:** candor-swift executes an untrusted `Package.swift` / `Package@swift-*.swift`
  (`swift package dump-package`) with no opt-out. Security, so it has no SOUNDNESS row; it still needs an owner.
- **Conformance hardening:** 20 parts are confirmed defeatable (`mutation-gate.sh` ~:1320); five generators
  each define their own `_rust_tree`/`ENGINES`.

## 5. Waiting on Tom

Decisions, most consequential first. Each was reduced by Fable from about 28 open questions in the old file;
the rest were settled from SPEC text or earlier rulings (see `FABLE-REVIEW.md` §Q3).

1. **Is rust-deep a product engine or an oracle?** Decides R1404 (boxed-closure Drop), the `is_pure_std_trait`
   allowlist (note on R1304), R456, R760, and the `--help` text that still calls it "the sound gate".
2. **A supported-version / cadence policy for pinned users** (decides the demo and SARIF pins in §4).
3. **Unblock java Phase D** (the `Candor.java` split, 5,678 → 12,899 lines) now, or keep it behind Phase C.
4. **The product bets, as one question:** gains (0 waitlist sign-ups in ~15 weeks), OSV reachability triage,
   the privacy-manifest case study, the fingerprint structure gate. Default: shelve.
5. A review arm on a non-Anthropic model.
6. Paid runners for candor-ts CI.

Needs Tom's hands, not a decision: the VS Code Marketplace PAT; SSH access to the field-case repo; the
JetBrains vendor dashboard (the plugin is not listed 3.5 months after upload); the PAPER3 manuscript corrections.

## 6. Rulings in force (pointers; the text lives where cited)

- Truth-monotone release bar (a)–(d) plus (c′), against the LAST RELEASE — `CLAUDE.md`, 2026-10-07/20/22.
- Disclosure-only changes ship under ~1.5% / decline above ~2.6%, and the three directions — `CLAUDE.md`,
  2026-09-24 and 2026-09-28.
- A release does not re-run what already ran on the same source — `CLAUDE.md`, 2026-10-07.
- UNION over hedge for conditional bindings — ⟨0.38⟩ / PART 89, 2026-09-12.
- Swift raw syscalls are CHARGED — 2026-09-03, **not yet carried out** (R1398).
- Boxed-closure Drop is measured four-way before it is fixed — 2026-08-30, **not yet done** (R1404).
- `min-report-spec` deferred, R55 option (a) — 2026-08-28 (`history/BACKLOG-2026-07-to-09.md` ~:6846, ~:6870).
- S5 (one back half instead of four) declined — 2026-10-20.

## 7. Non-goals (decided — do not build)

- A "candor score" / cross-codebase grade: a single opaque number that ranks codebases. The fingerprint
  structure descriptor (component-transparent, delta-framed) is not ruled out.
- Heavier per-engine dev tooling (rustfmt gate, `tsc --checkJs`, SwiftLint): evaluated and declined; every
  engine already gates its idiomatic linter with warnings as errors.
