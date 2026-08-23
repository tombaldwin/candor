# candor (umbrella) backlog

_Last reviewed 2026-08-09 (**floor 0.27 PUBLISHED** — `release-verify: OK`, every artifact resolved: 4 crates, npm, 7 GitHub releases, brew tap, every pinned URL. The 0.27 cut also closed both data-destroying gate-sink bugs — the `deps` separator mismatch and the dep-DIRECTORY sink guard, each of which overwrote an operator's dep report and exited 0 with `ok: true` in all four engines — and took PART 36 from 3 stream rows to 17. Process lessons in the memory file `candor-027-release-lessons`: rows beat review panels; enumerate TRIGGERABLE causes, not exit sites; when you close a channel ask what OTHER spelling reaches it.) Per-engine detail: `candor-java/BACKLOG.md`, `candor-rust/BACKLOG.md`, and `candor-spec/SCAN-BOUNDARY-WORK-QUEUE.md`._


## CLOSED 2026-08-20 — an fd/stream write through a helper was charged `Net` (R54, candor-ts)

**FIXED.** The carve-out now decides from the receiver's TYPE rather than its spelling, as a denylist:
`Net` is suppressed only when EVERY constituent is a proven non-network stream class from @types/node's
own `tty`/`fs`/`process` typings. Unknown constituent, `any`, a project class of the same name, or a real
`net.Socket` all KEEP the charge. `stream.Writable`/`Readable` are excluded from the safe set because a
real `net.Socket` IS a `stream.Duplex`. Scoped to `Net` alone so a legitimate `Fs` is untouched.

**A/B on execa's real source: six `⚠ performs Net` fixtures and exit 2 become `policy ✓`.** Six
regression cases in `test.mjs`, three of them the under-report controls, written before the fix.

**The three under-report controls did their job, and one of them was itself wrong**: `f.write()` on an
`fs.WriteStream` is not charged `Fs` at all — the `Fs` lands where the stream is OPENED. Measured against
HEAD before changing either side, the answer was identical, so the assertion was wrong rather than the
code. Corrected to the module-level check it should always have been.

**Three implementation facts, each found by measuring rather than reading, each silently suppressing
nothing until found:** an intersection type carries no single symbol (`process.stdout` is
`WriteStream & { fd: 1 }`); the std streams' `WriteStream` is declared in `process.d.ts`, not `tty.d.ts`;
TypeScript names anonymous shapes `__type`, so `!name` does not skip them.

The original entry follows, for the record.

## (original) An fd/stream write reached through a helper is charged `Net`

**MEASURED 2026-08-19** on `execa` under `deny Net`, in the ⟨0.30⟩ blast-radius sweep: every finding in
that project's fixture set is a write to stdout or a file descriptor, charged as **Net**. `fail.js` (whose
whole body is `process.exitCode = 2`) and `delay.js` (`setTimeout`) were named for effects that live in
`noop-*.js`. Cause: `tty.WriteStream` extends `net.Socket`, and the std-stream carve-out fails through one
level of indirection.

**It is 2 of the 31 measured ⟨0.30⟩ flips** — i.e. the only two of that sweep that are NOT justified. The
other 29 are genuine denied effects in unjudged files.

**PRE-EXISTING — ⟨0.30⟩ only made it REACHABLE.** Confirmed by measurement, after a wrong turn worth
recording: published 0.29.1 and the current build charge this IDENTICALLY on a minimal fixture, so the
classifier is unchanged. On execa the flip looks new only because those files are excluded from an
ordinary scan and the peek analyses them — the same answer about DIFFERENT code, not two answers about
the same code. (I briefly concluded the peek fabricated it and that PART 48's twin arm was too weak to
catch that; both were wrong. The peek and an ordinary scan agree given the same file set.)

**THE MECHANISM, located 2026-08-19 — a four-line reproduction, both controls written:**

```js
const pick = fd => (fd === 1 ? process.stdout : createWriteStream(undefined, {fd}));
pick(3).write('hello');          // direct: ["Net"], netClass: ["unknown-host"]   <- the over-charge
process.stdout.write('hello');   // pure                                          <- the direct form
```

The receiver types as `tty.WriteStream | fs.WriteStream`, and **`tty.WriteStream` extends `net.Socket`**,
so resolving `.write` on that union reaches a declaration in the net cluster's typings and `declModule`
answers `net` — which the κ rule charges for every non-constructor member. The direct form never gets
there: its receiver is a property chain rooted at `process`. So the distinction was only ever holding
SYNTACTICALLY, and one level of indirection defeats it.

**The fix is in RECEIVER TYPING** — decide the module from the receiver's own apparent type rather than
from where the resolved member happens to be declared. That is the R48–R53 vein, where the wrong version
under-reports every genuine `Socket.write`. Hence its own change, its own review.

**Both controls are written and currently discriminate** (in `scratchpad/carveout`): the over-charge case
above must LOSE Net, and `pickSock().write(...)` — a real `new Socket()` through the identical
indirection — must KEEP it.

**WHY IT WAS NOT FIXED UNDER THE RELEASE, deliberately.** Narrowing an over-charge is the single move this
family has measured producing silent under-reports — 4 defects in 5 such fixes, and the ⟨0.30⟩ work
reproduced that pattern twice in one day (a false all-clear introduced while fixing a false all-clear).
A classifier narrowing wants its own change, its own fixture pair, and its own review, not a fold-in.

**What the next attempt should do FIRST:** write the UNDER-REPORT control before the fix — a genuine
`net.Socket` write reached through the same indirection, which must still charge Net. The carve-out is a
denylist question (`candor-denylist-over-allowlist`): say which direction it fails in before choosing it.
It is named in the 0.30.0 release notes as a known over-charge, so consumers meeting it are not surprised.

## The ⟨0.30⟩ exit code and per-RUN gate state (candor-rust)

`GATE_VIOLATIONS` is now thread-local rather than a process global, which fixed both the `--gate-json`
sink-dependence and a race that only appeared because `cargo test` runs in parallel threads. Member
aggregation now uses §3.3's precedence instead of `rc.max(code)`, which had let one member's "could not
evaluate" displace another's certain violation (`regex` under `pure`: 198 violations, exit 2).

**Residual:** the state is still ambient rather than threaded through `scan_one`'s signature. Thread-local
is correct only while members are scanned SEQUENTIALLY on one thread (`for d in &dirs`) — the moment
anyone parallelises that loop, cross-member accumulation silently breaks and the symptom will be a wrong
exit code, not a crash. Either thread the state explicitly or pin the sequential assumption with a row.

**PINNED 2026-08-20** (the second half of that choice, not the first): `tests.rs`
`workspace_members_are_scanned_sequentially_because_the_gate_state_is_thread_local` reads the loop region
and fails if `par_iter`/`par_bridge`/`thread::spawn`/`scope(|` appears in it, with a message naming the
remedy. Calibrated by injecting `par_iter` — and the first calibration attempt injected a real
`dirs.par_iter()` call which did NOT COMPILE, so the test never ran and the green proved nothing.
Threading the state explicitly is still the better fix and is still open.

## **`[P1]` A NEW EXIT-2 CAUSE MUST FAIL LOUDLY IF THE ADVISORY SIBLINGS DO NOT SHARE IT** (2026-08-22)

⟨0.32⟩ leaked into FOUR readers of gate state before conformance had them all, and **every one failed
QUIETLY** — which is why none was caught by running the thing and looking at it:

    policy scope matching   `deny Exec app::` silently stopped matching `pkg#app::…`  (a FALSE GREEN
                            introduced by the false-green fix)
    the verdict row         `fn` became the unit KEY, breaking §3.3.1 byte-equality the other way
    reason_classes          `--class dispatch` selected NOTHING, which reads as "nothing to report"
    the advisory verbs      `unverified --strict` exited 0 over a report the gate refused at 2

**THE LAST ONE IS THE ARGUMENT FOR A MECHANISM.** `ReportCompleteness#incomplete()` already carried an
`outOfScope` arm added at ⟨0.30⟩ FOR EXACTLY THIS REASON, with a comment recording that the gate had
moved and the advisory siblings were left behind — *"MEASURED, the gate exited 2 while `unverified
--strict` answered PROVABLY clean at 0 over the same report."* I read that comment WHILE adding the
⟨0.32⟩ arm beside it. The codebase had documented the failure, the fix, and the fact that it recurs,
and it recurred anyway. **A note telling the next person to remember is not a mechanism** — the same
lesson as [[feedback-documented-limitation-is-not-measured]], one level up: a documented RECURRENCE
reads as handled.

⟨0.24⟩ already binds this ("an advisory verb must never be LESS sensitive to incompleteness than the
gate over the same bytes … `unverified`, `fix-gate` and any later sibling"), and R11 asserts the law
over engines. What is missing is a check that fires when a NEW cause is added: something that
enumerates the gate's exit-2 causes and fails unless each is an arm of the shared predicate. The
conformance R11 row catches it only when a generated shape happens to exercise the new cause — it did
here, by luck of the matrix, and four cells is a thin margin to rely on twice.

## ~~**`[P1]` candor-ts: AN UNREADABLE FILE VANISHES FROM EVERY MANIFEST**~~ **CLOSED 2026-08-22**

An unreadable source reached NO manifest and the gate answered `policy ✓` at exit 0 — `unanalyzed`
absent, `excluded: []`, stderr reading "2 analyzed, 1 files" (units from the file that WAS readable;
the other simply gone). MEASURED four-way: rust, java and swift all exit 2 with the file named in
`unanalyzed`, so this was a ts defect against a three-engine norm, not a family gap. Fixed: a root file
with no `SourceFile` is now recorded as `source could not be read`, relative path, matching rust.

**THE PART WORTH KEEPING IS HOW LONG IT TOOK, BECAUSE THE CODE WAS RIGHT ON THE FIRST TRY.** I wrote
this fix, saw it not fire, reverted it; wrote it again, saw it not fire, reverted it again; and filed a
conclusion — *"membership checks pass over the file, the discriminator has to be CONTENT"* — that was
exactly backwards, as guidance for the next attempt.

The fixture was wrong, not the fix. It used `helper.test.ts`, and `fromTsconfig` filters test files out
of the program (`scan.mjs:1389`), so the file was never in `fileNames` and the check had nothing to
find. **A negative result from a broken instrument is indistinguishable from a negative result** — and
I turned two of them into a theory, wrote the theory down as fact, and pointed the next reader at a
discriminator that does not exist.

What settled it: ONE debug print of what `fileNames` actually held at runtime. A minute of measurement
against two rounds of confident reasoning that had it inverted.

**The rule this earns, beside the ones already in [[feedback-measure-directly]]: when a change does not
fire, prove the FIXTURE reaches the code before concluding anything about the code.** Every instance
today had the same shape — `cargo build` reporting success without rebuilding, `swift test` running
zero tests, `cargo test -q` running 51 of 106, a glob matching nothing read as a scan producing
nothing. All of them looked like clean answers.

## **`[P1]` A POLICY SCOPE HAS NO WAY TO SAY "EXACTLY THIS SEGMENT"** — reported from the field, reproduced

Routed in from the ebman CI adoption (candor-scan 0.26.0, tombaldwin/ebman @ 8ca6e31) and REPRODUCED
here on a three-line fixture with **no `app` module in the tree at all**:

    forbid aws -> app       -> exit 1, "reaches into a forbidden layer (via `dep::application_name`)"
    forbid aws -> app::     -> exit 1, identical

**It is not a broken matcher — it is a DESIGNED prefix rule with no escape hatch.** `scope_matches`
(candor-classify/src/policy.rs:663-673) matches the LAST scope segment by `starts_with`, and the doc
comment above it says so deliberately. `name_segments` (:624) splits on `.`/`:` and DROPS EMPTY parts,
so `app::` segments to exactly `["app"]` — writing the separator cannot anchor it, which the reporter
deduced from behaviour without seeing the source.

So a user who wants an exact segment match has NO WAY TO EXPRESS ONE. That is the defect: not the
prefix rule, the absence of an alternative to it.

**THE FIELD COST IS THE POINT, and it is the cardinal sin one level up.** 14 false AS-EFF-009s on
honest AWS SDK calls, so the rule was DELETED from ebman's policy — meaning the genuine `aws -> app`
violation it exists to catch will now never fire. A rule that cries wolf gets removed, and a removed
rule is a silent under-report with no disclosure anywhere. Same shape as
[[candor-oracle-disclosure-recall]]: an alarm nobody trusts is not an alarm.

**Fix shape, and it needs a ruling because it is a contract change:** the reporter suggests matching
only on `P == L` or `P.startsWith(L + "::")`. That would change existing verdicts for anyone relying
on the prefix behaviour (`domain` matching `domain_service`), so it is a rung, not a patch. A cheaper
alternative preserving both: keep prefix as the default and make a TRAILING `::` mean exact-segment —
which is what the reporter already tried, and is the spelling everyone will guess.

Four-way: the same prefix rule is in java's `Policy.scopeMatches` (measured earlier today at
Policy.java:1645). Whatever is decided binds all four.

## **`[P2]` `cargo candor explain <fn>` IGNORES ITS ARGUMENT** — reported from the field

    cargo candor explain util::config_dir              -> dumps aws::eb::clone_env spans
    cargo candor explain ui::shell::draw_shell         -> identical output
    cargo candor explain definitely_not_a_function_xyz -> identical output

Same bytes for two different real functions and for a name that does not exist. Looks like raw lint
spans printed instead of the named function being traced. `policy`, `where` and `path` all behaved
correctly in the same session, so it is isolated to `explain`. NOT yet reproduced here — the report is
against the dylint/cargo-candor front end rather than candor-scan.

**Note the shape**: a verb that answers identically for a nonexistent name is the `path <fn> <typo'd
Effect>` defect again (closed today as PART 61) in a different verb — an argument that binds nothing,
scored as an answer. Worth asking of every verb that takes a name, not just this one.

## `[P3]` `--include-tests` and cfg(test) — a documented caveat, not a bug

With `--include-tests`, 102 ebman test functions report Clipboard; all 102 are the `#[cfg(not(test))]`
arm of a `yank()` helper, i.e. precisely the arm compiled OUT under test. Correct for a syntactic
scanner and safe-direction, but it makes "the test harness reaches no clipboard / no $HOME / no
network" unusable on any codebase using cfg(test) stubs to hold that boundary — which is the standard
way to hold it. A cfg-aware mode or a documented line would save the next person the dead end.

## **`[P1]` SETTLED: THE AMBIGUOUS-EDGE RULE TRADED ONE FALSE GREEN FOR ANOTHER** (2026-08-22)

**MY WORRY WAS THE WRONG CHANNEL, AND THE PREMISE WAS FALSE.** `gate --report` never propagates
EFFECTS: `inferred` is taken off the wire per entry (gate.rs:443) and the only fixpoint is
`propagate_str` over REASON CLASSES (gate.rs:495); `forbid`/`only`/`allow` are refused on this route.
So the dropped edge cannot lose an inherited effect — there was none to lose, before or after. My
effect control could not fire because there was nothing to fire.

**THE SAME DEFECT IS LIVE IN THE REASON CHANNEL:**

    ctrl (a+c)     deny Unknown[dispatch] caller  -> exit 1, row names `caller`
    amb  (a+b+c)   same policy                    -> exit 0, `policy ✓`     THE FLIP

Adding an unrelated report turns a red verdict green — **the exact shape PART 63 exists to forbid.** I
closed one route to it and opened another IN THE SAME COMMIT. The drop is safe only when the caller has
no reason of its own (that case exits 2, withheld); the has-own-reason shape — one callback plus one
ambiguous call — is the common one, and there the caller loses the inherited `dispatch` class while
staying ANSWERABLE through its own, so the filter tolerates.

**THE CORRECT RULE, and it needs no second edge set:** an ambiguous callee name contributes NO EDGE but
MUST contribute `Unknown` + reason class `dispatch` AT THE CALLER'S ENTRY, before the fixpoint — the
existing CONTRIBUTES precedent (gate.rs:474-492). The vocabulary already sanctions it:
`ReasonClass::Dispatch` is defined as *"unresolved virtual/dynamic dispatch, **same-name ambiguity**"*
(policy.rs:28) and `classify` already maps `ambiguous:` to it (policy.rs:91). It closes both flips and
cannot re-open PART 63's green: the contribution lands only on the fn that OWNS the ambiguous edge,
naming evidence the merge itself holds (it saw ≥2 declarers), never a class borrowed from another
function's body.

**AND THE BRANCH I VALIDATED IS DEAD CODE ON REAL REPORTS.** The same-package-first resolution
(gate.rs:446-448) keys on a `#` in the hash — but a real rust hash is a hex `DefPathHash` with no `#`
(candor-report/src/lib.rs:219-221), so the package prefix is ALWAYS empty and only hand-authored
`p#fn` hashes take that branch. **Every fixture I validated against was hand-authored.** The unique-
declarer fallback is what actually runs in production.

**Old vs new, on this axis:** the bare-name join unioned both `helper`s into one node, so every arm
fired — fail-CLOSED here, while being the measured false green on answerability. So the trade is real
and symmetric, and only the entry-contribution rule closes both.

**SAME-REPORT SHAPE TOO:** two same-named units with DIFFERENT hashes inside ONE report lose the edge
identically (1 -> 0 measured), and that shape is plausibly self-produced — gate.rs:272-273 names
cfg-paired fns as "the everyday case" of one name, two units. Two entries sharing one hash are fine
(union, nothing lost).

**PART 63 additions once fixed:** (1) the ctrl/amb pair under `deny Unknown[dispatch] caller`, wanting
`a+c = 1` naming `caller` and `a+b+c = 1` (today 0), with the unscoped-Exec arm kept as the control
that proves propagation is exercised at all; (2) a single-report hex-hash pair wanting 1/1 (today 1/0),
which also covers the dead branch.

**THE PORTS ARE BLOCKED ON THIS.** java and ts were about to copy a rule that trades one cardinal sin
for another, plus a resolution branch that never executes.



rust's merge drops an edge entirely when a cross-package callee NAME is declared by more than one
sibling. The reasoning was that union is unsafe for REASONS — a borrowed reason turns "I cannot say"
into "I checked". **But dropping the edge also drops EFFECT propagation**: a caller no longer inherits
that callee's effects, which is the UNDER-report direction. That would be a false green introduced by
the fix for a false green, in the same commit — the [[feedback-fabrication-fixes-cause-misses]] shape.

If it IS wrong, the answer the argument actually implies is: union the EFFECTS, refuse to union the
REASONS. That is not what is implemented, and it must be settled BEFORE three engines copy it —
finding it after the ports costs four fixes instead of one.

## **`[P1]` THE FALSE GREEN IS LIVE IN java AND ts — CONFIRMED, SITES LOCATED** (2026-08-22)

Measured against conformance PART 63's own fixture, and it reproduces CROSS-ENGINE (rust-shaped
reports gated by java and ts, which §3.1 puts in contract):

    rust   a alone=2   a+b=2    fixed
    java   a alone=2   a+b=0    CARDINAL SIN, live
    ts     a alone=2   a+b=0    CARDINAL SIN, live
    swift  not exercised — needs a swift-shaped fixture

**THE SITES, both keying on bare `fn` with the same "a duplicate key is malformed input" comment rust
carried:**
  · java — `Policy.gateInputFromReport` (Policy.java:984), `String fn = e.fn()` at :993 feeding
    `inferred.merge(fn, …)`, `edges`, `hosts`, `cmds`, … Prerequisite CONFIRMED: `Effector` already
    carries `hash` (Effector.java:32), so the key is available without a format change.
    Note `fix`'s own map (Query.java:4646) uses `put`, not `merge` — a duplicate name OVERWRITES there,
    which is worse than rust's union and wants checking as part of the same pass.
  · ts — `query-core.mjs:787+` concatenating entries across sibling reports, feeding maps keyed by
    `f.fn` (`policy.mjs:53-91`, `:597-604`, `:744-753`).

**THE RECIPE IS RUST'S, INCLUDING ITS FOUR LEAKS.** Land the key→name map first as a VERIFIED NO-OP
(identity display, corpus byte-equal), then switch the key. Rust's fix leaked into four readers and
every one failed QUIETLY: policy scope matching (`deny Exec app::` silently stopped matching
`pkg#app::…` — a false green introduced by the false-green fix), the verdict row (`fn` became the unit
key, breaking §3.3.1 the other way), `reason_classes` (`--class` selected nothing), and the advisory
verbs (`unverified --strict` exited 0 over a report the gate refused at 2). Expect the same four.

**Acceptance is already written**: PART 63 asserts rust and MEASURES java and ts, so a correct port
flips its own row from CONFIRMED DEFECTIVE to OK, and the two skip-baseline lines come out.

## ⟨0.32⟩ THE PORTS — TWO SWIFT HAZARDS AND THE JAVA CLOSER (reviewed 2026-08-22)

**THE RULE'S COST IS CONFINED TO ONE ENGINE, which I had assumed was family-wide and it is not.**
MEASURED: candor-ts and candor-rust PEEK their excluded sources — ts builds a child tsconfig listing
every excluded file with `allowJs: true` (`scan.mjs:6959`), rust recurses `scan_one` over the excluded
set (`scan.rs:2771`) — so those classes come back `peeked: true` and ⟨0.32⟩ cannot fire on them. A ts
fixture with a `.d.ts`, a test file and an out-of-program stray exits 0, both classes peeked. Only an
engine that CANNOT READ the excluded file has the case at all.

  · **`[P1]` swift's `build-output` MUST carry `judgedElsewhere` or every SPM project refuses.**
    `PEEKED_CLASSES` (`main.swift:1805`) excludes `.build/`, so without the producer flag the port turns
    every project with a build directory red on contact. rust's equivalent already carries it.
  · **`[P1]` swift's PLATFORM-PRUNED files never enter `excluded` AT ALL** (`#if os(…)`,
    `main.swift:969-972`) — genuinely unread code disclosed only in prose. A B1-shaped hole sitting
    directly beside the rung that exists to close B1, and nobody had filed it. It is not fixed by
    ⟨0.32⟩: the rule keys on `excluded`, and these files are not in it.

**`[P2]` THE CLOSER FOR JAVA — A SOURCE PEEK.** The other engines escape the cost because their peek
opens what the scan skipped; java's cannot, so `source-without-class` is unpeekable by construction and
fires on any tree with a stray `.java`. MEASURED: candor-java's own repo reports `source-without-class
(71)` of 207 sources — fixtures and samples, i.e. the norm, not a broken build; uflexi 93 of 2237. A
peek that `javac`s the strays into a temp dir and runs java's own classifier turns those `peeked: true`,
returns repo-root scans to 0, and brings `Deploy.java` back as a NAMED `outOfScope` finding rather than
a refusal — which is the answer everyone actually wants.

**THE ARGUMENT AGAINST ⟨0.32⟩ SHIPPING WITHOUT THAT CLOSER, worth keeping because it is the honest
counter-case:** `candor <repo-root> --policy` is the natural first command, and after this rung it
answers INCOMPLETE on effectively every naive JVM invocation, including fully-built clean projects.
A gate that always says "incomplete" on first contact trains people to read exit 2 as noise, or to pin
scans to `build/classes` and stop looking at the one tree where a `Deploy.java` would sit — **B1
re-opens at the WORKFLOW level while the spec stays sound.** Two things soften it and both are measured:
a genuine violation still DOMINATES (uflexi under `deny Exec` exits 1, not 2 — the rung converts false
greens, not real findings), and an unbuilt clone already exited 2 before the rung, so the middle case
now matches both edges rather than inventing a third.

**Also on record: every narrowing of the rule re-opens B1 by construction.** The annoying case and the
filed defect are the SAME SCAN SHAPE — an operator-chosen repo-root scan — distinguishable only by the
content of a file nobody read. An operator-vs-build distinction fails (the motivating scan was
operator-chosen), scope-covered-unread fails (a global `deny` covers everything), and any ratio that
tolerates candor-java's own 71 strays tolerates one hostile file 71 times over.

## ⟨0.32⟩ UNREAD CODE MAKES THE VERDICT INCOMPLETE — java DONE, and the REVIEW MOVED THE DESIGN

Tom's ruling (2026-08-21): code the engine admits it never READ must make the gate INCOMPLETE (exit
2), not pass. Closes B1 and the execa/axios item together — both were `excluded[].peeked == false`
carrying no verdict consequence. ⟨0.30⟩ keys on what the peek FOUND, and a peek that cannot open a
file finds nothing, which is byte-identical to finding it clean.

**candor-java SHIPPED both routes** (scan → exit 2, `gate --report` → exit 2 from the document, and a
compiled-only control still exits 0 on both). `excluded` rides the REPORT, so the report route needs
no target to re-derive it — the constraint that defeated the `net-partner` disclosure.

**THE REVIEW BEFORE PORTING FOUND THE DESIGN DEFECT, which is exactly what it was for.** java carved
out `build-output-archive` — a jar under `build/` is a DERIVED copy of classes the scan already
judged, so failing on it would redden every project that builds one. The carve-out lives in the
CONSUMER as a private name list, and the other engines spell the same concept differently:

    excluded class in the report          java `gate --report`
      build-output          (rust, swift)      exit 2   <- refused
      build-output-archive  (java's own)       exit 0   <- carved out
      build-script          (rust's build.rs)  exit 2   <- correct: real unjudged code that RUNS

**So the same report gated by java and by rust would disagree** — §3.1 route equality one level up,
cross-ENGINE rather than cross-route. Porting as-is would have hard-coded four private tables that
have to be kept in sync by hand, and the failure would surface only when someone gated another
engine's report.

**THE FIX: THE CARVE-OUT MUST RIDE THE DOCUMENT.** The producer knows whether an exclusion class is a
derived duplicate of code it already judged; the consumer must not guess from a name. `excluded[]`
needs that fact as a field (alongside `peeked`), so every consumer applies ONE rule with no table:
*unread AND not-already-judged ⇒ INCOMPLETE*. It also makes the carve-out VISIBLE — an engine
declaring something derived has to say so in the report, which is this family's standard everywhere
else and is the difference between a disclosed decision and a private one.

Note the two classes are genuinely different, so this is not a naming quibble: rust's `build-script`
is `build.rs` — code that RUNS at build time, `Command::new("curl")` and all, and the original B1
filing names it. It must fail closed. `build-output` must not. Only the producer can tell them apart.

**STATE:** java implemented and green (788/0), NOT shippable — a one-engine rung is the divergence
this project exists to prevent. rust/ts/swift + the SPEC clause + a conformance part remain, and
should be built on the document-carried field rather than on java's current name list.

## A TEST THAT REACHES A BRANCH THROUGH INVALID INPUT WILL DEFEND THE BUG (2026-08-21)

Closing the typo'd-effect hole four-way (`path <fn> Fsz` → exit 0 "does not perform Fsz", now exit 2,
conformance PART 61) was a ~10-line fix per engine. **Both CI failures it caused were tests defending
the defect, in two different ways, and neither was caught locally.**

  · **candor-java** — `JsonEmitDeterminismTest` reached the empty-path emit using the effect name
    `"Time"`, which is not a candor effect at all (the vocabulary has `Clock`). It exercised that branch
    THROUGH A TYPO, so the moment `path` started refusing typos the test broke. A known effect the report
    genuinely lacks (`Db`) is the real shape of that case and tests the same thing — launch-stability of
    the empty emit. **Whenever a test reaches a branch with input the program should reject, it has
    become a guard on the acceptance.**
  · **candor-ts** — a row asserting the OLD behaviour ON PURPOSE, as a ⟨0.28⟩ SCOPE boundary: rust,
    java and swift all answered `path: []` at exit 0, so gating it in ts alone would have manufactured a
    fresh one-engine divergence out of one engine's fix. It said exactly that, and said *"when it is
    opened, this row changes deliberately"*. **That is the good case**: the deferred defect was written
    down WITH the condition for revisiting it, so the row flipped instead of being deleted, and the
    scope note turned out to be the pin.

**And the process failure was mine:** the java suite passed 788/0 locally BEFORE the guard went in and
I never re-ran it after. CI caught it. `verify-local.sh` runs CI's union — running it, rather than the
last green suite I happened to remember, is the whole point of it existing.

## A cheap report REFRESH (the uflexi Stop-hook cost)

Field-measured: 3.30s of a 3.51s hook is the scan, re-analysing 2,259 classes when one changed. The
FREQUENCY half is fixed (the hook skips turns where nothing the verdict depends on moved); the first turn
after any edit still pays, and that is the turn the agent waits on.

**Its acceptance test is what keeps it a patch:** a refreshed report must be BYTE-IDENTICAL to a full
scan, `analyzed.digest` included. Key on (engine build id, class CONTENT hash) never mtime; invalidate the
whole cache on an engine change; recompute the closure rather than caching it; full-scan fallback on
anything ambiguous. A stale cache entry read as current is the cardinal sin and would look like a normal
report.

**THE "MEASURE PARSING-VS-CLOSURE FIRST" PRECONDITION IS DISCHARGED — 2026-08-20, AND IT SAYS BUILD IT.**
Measured with `CANDOR_TIMING=1` (opt-in, stderr, added for this and pinned so it cannot reach a document)
over three independent targets:

    target          load+parse   analyze+edges   fixpoint      indexes
    uflexi          215 ms       860 ms (72%)    40 ms (3.4%)  37 ms
    commons-lang3    71 ms       193 ms          5.4 ms (1.9%)  12 ms
    gson             47 ms        96 ms          2.1 ms (1.3%)  14 ms

**The closure does NOT dominate — it is 1.3–3.4%.** The per-class work does: `analyze+edges` is 2–4× the
parse and alone is ~72% of uflexi's analysis, and it runs in a plain `for (ClassNode cn : classes)` loop.
Parse plus analyze is **~90% of the time on every target measured**, and that is exactly the work a
per-class cache skips.

**So the ceiling is quantified rather than hoped for.** On a one-class edit the unavoidable remainder is
the fixpoint (~40 ms), the whole-program indexes (subtype/spring/stream, ~37 ms) and that one class —
call it 80–120 ms against 1200 ms today, so **roughly 10× on this target**, and uflexi is the field case
the item was filed for.

**Two things the numbers change about the design.** The indexes are computed over ALL classes and are
cheap, so they can simply be recomputed — no cache key needed for them, which removes the hardest
invalidation question from the design. And the fixpoint should be recomputed every run as the original
note says, now with a measurement behind it: at 3.4% it is not worth the risk of ever serving a stale one.

**Baseline for any future comparison** (candor-java 0.30.0, uflexi `build/classes`, 2,602 class files /
21,247 units): 1.65 s wall, of which 0.06 s is JVM start. Scaling is near-linear in input size (2× the
files → ~2.3× the time), which independently rules out a runaway closure.


## ⟨0.30⟩ candidate, 2026-08-18 — from the post-release corpus rounds against the PUBLISHED artifacts

- **`[P2]` CLOSED 2026-08-20 — VERIFIED FIXED END-TO-END; this entry was stale.** Both halves are in the
  code and pinned: `Loader.java:834` admits an entry carrying `incomplete` (`!de.effects.isEmpty() ||
  !de.incomplete.isEmpty()`), pinned by `CrossScanBoundaryTest#anEffectLessDepEntrysIncompleteReachesTheCaller`;
  the writer serialises a method whose only signal is the marker, pinned by
  `IncompleteOnlyReachesTheReportTest`. Measured end-to-end through a real chained report:

      dep.Dep.f  inferred[Db] + incomplete[Db]  ->  caller: inferred=['Db'] incomplete=['Db']
      dep.Dep.f  inferred[Db] only              ->  caller: inferred=['Db'] incomplete=None
      dep.Dep.f  incomplete[Db] ONLY            ->  caller: inferred=[]     incomplete=['Db']   <- works

  The third row is the defect this entry was filed for. The caller is reported with an EMPTY `inferred`
  carrying the marker, and the "unexplained `Unknown`" the entry describes does not appear.

  **THE FIXTURE TRAP THAT MADE THIS LOOK BROKEN, worth more than the item.** A dep entry is joined on its
  **`hash`** (`dep/Dep.f()V` — the JVM descriptor form), not on `fn`. An entry injected into a report
  without a `hash` is silently NEVER FOUND: the caller comes back "not reported / claimed pure", which is
  indistinguishable from the defect. My first three attempts reproduced the bug perfectly and were
  measuring nothing — caught only because the CONTROL (`inferred:["Db"]` alone, which is known to
  propagate) also failed, which no real defect could explain. **If a hand-injected dep entry seems to be
  dropped, check the `hash` field before believing it.**

  (original entry follows, for the record)

- **`[P2]` (original) A DEPENDENCY'S `incomplete`-ONLY FUNCTION IS DROPPED BEFORE ITS MARKER CAN PROPAGATE.** Found
  while building the regression row for the java report-writer fix — it is that same defect one layer
  over. `Loader` records a dep entry only `if (!de.effects.isEmpty())`, and the comment there gives a
  real reason: admitting empty entries would make a key that is currently ABSENT resolve as
  present-and-pure, a new purity claim. But an entry carrying `incomplete: ["Db"]` and no effects is not
  a purity claim — it is an UNCERTAINTY claim, and dropping it loses exactly what ⟨0.29⟩ added the
  `for (String eff : d.incomplete)` propagation to carry.

  MEASURED: a real dep report mutated in place so `Dep.f` has `inferred: []` and `incomplete: ["Db"]`,
  chained into a consumer that calls it — the consumer comes back with `incomplete: None`. The
  uncertainty never arrives.

  **ATTEMPTED 2026-08-18 AND REVERTED — the one-clause fix is not the fix.** Widening the gate to
  `!de.effects.isEmpty() || !de.incomplete.isEmpty()` admits the entry and does NOT achieve the goal:
  the consumer still comes back with `incomplete: None`, and an unexplained `Unknown` appears on it that
  was not there before. So there are two separate problems, and the gate is only the first:

    · the ENTRY is dropped (the gate), and
    · something downstream of the join does not carry `d.incomplete` to the caller when the entry has NO
      EFFECTS — the join site itself looks right (`for (String eff : d.incomplete)` at Candor.java:4393),
      and the same marker DOES propagate when an effect accompanies it (measured: a dep entry with
      `inferred:["Fs"]` + `incomplete:["Fs"]` gives the consumer `['Fs']` / `incomplete:['Fs']`).

  So the next attempt starts by answering: where does an effect-less-but-incomplete entry lose its marker
  between `crossDeps` and `surfaceIncomplete`, and where does the new `Unknown` come from? The parser is
  not the problem — `incomplete` is read at Loader.java:781, and `inferred: []` is a clean array that
  correctly yields zero effects.

  **This matters more now than when it was filed:** candor-java's report writer now EMITS exactly this
  shape (a method with `inferred: []` and `incomplete: [Db]`), so the reports this engine produces
  contain entries the chaining path cannot currently carry.

  Controls any fix must keep: a dep entry with NEITHER effects nor incomplete stays absent (no purity
  claim — that is what the existing comment's argument is actually about), and a stale/untrusted dep
  still cannot upgrade a consumer's certainty.

- ~~**`[P2]` THE JAVA `incomplete`-ONLY REPORT FIX HAS NO CI COVERAGE.**~~ **CLOSED 2026-08-18 — `IncompleteOnlyReachesTheReportTest` pins it in gradle, calibrated (fails with the arm removed). The fixture injects the marker; the test header records why every natural producer is unusable.** Original filing: Found by a pre-release reviewer,
  CONFIRMED by reverting: `ReportWriter`'s `incompleteAcc` inclusion arm can be removed and candor-java's
  entire suite stays green (527 passed; the two failures on a full revert belong to the OTHER java fix,
  the default-package stand-in). Its only evidence is a corpus measurement — sqlite-jdbc 3.46.0.0 +
  `check_honesty.py`, calibrated both ways — and `candor/bin/corpus.sh` is not run by any CI workflow.
  (candor-java's CI runs `soundness/dynamic/corpus.sh`, its own RUNTIME oracle, which is a different
  instrument.)

  This is the shape the project has been bitten by repeatedly: an unguarded fix regresses silently, and
  java has already once reintroduced a defect its own file documents. The fix itself is sound and
  disclosure-only (a reviewer confirmed `checkAllowlist` skips fns whose `inferred` lacks the effect, so
  an incomplete-only row cannot flip a `deny`/`allow` verdict).

  WHY NOT SIMPLY WRITE A ROW: the shape needs a method whose ONLY signal is `incomplete` — no effects, no
  entry point, no blindness, no declaring class. Two attempts failed to synthesise it: a runtime-SQL call
  yields Db AND incomplete together, and a hand-written dep report carrying `incomplete: [Db]` with no
  effects did not propagate the marker caller-ward at all (worth investigating separately — a chained
  dep's per-function `incomplete` arguably SHOULD propagate). The real instances came from sqlite-jdbc's
  `declared`/`overdeclared` machinery, which is what needs reverse-engineering to build the fixture.

  Cheapest sound options, in order: (a) wire a targeted step into candor-java CI that fetches sqlite-jdbc
  from Maven Central, scans it, and asserts the two known callers carry `incomplete: [Db]`; (b) make
  `bin/corpus.sh` a release-ladder gate rather than a habit; (c) build the fixture properly once the
  `declared` mechanism is understood.

- **`[P1]` A CHEAP REPORT REFRESH — BUILT 2026-08-21, candor-java, opt-in `CANDOR_REFRESH=<dir>`.
  It works and it is FAR below the projection: 1.48×, not 10×.** Measured on the field case (uflexi,
  2,602 classes) with one class changed: cold 1750 ms → refresh 1184 ms, 2601 of 2602 classes reused.

      cold                        1750 ms
      refresh, 1 class changed    1184 ms      1.48x
      warm, nothing changed       1140 ms

  **THE PROJECTION WAS WRONG, NOT THE IMPLEMENTATION, and the gap is fully accounted for.** "80–120 ms
  against 1200 ms" assumed the only remaining work was the fixpoint, the indexes and the one changed
  class. Two costs it never counted now dominate the warm run: every class is still **PARSED** (255 ms)
  because the whole-program indexes are rebuilt from `ClassNode`s, and the **15 MB cache** costs ~320 ms
  to load and replay. Those two are the whole remaining ladder, and both are now quantified rather than
  guessed — see the open items below.

  **HOW IT WORKS.** Each class is analysed into an OVERLAY whose accumulators start empty, so what it
  leaves behind is exactly that class's delta; the delta is keyed on (engine build, whole-program
  digest, class CONTENT hash) and replayed instead of recomputed. The split runs ALWAYS, not only when
  caching is on, so the cached and uncached routes cannot drift.

  **THE CLASSIFICATION HAZARD, AND THE INVERSION THAT DEFUSES IT.** Splitting ~70 accumulators into
  "shared input" and "per-class output" and getting ONE output wrong in the shared direction means its
  writes reach the master on the priming run, never enter the delta, and vanish on every refresh after —
  a silent under-report in a report that looks entirely normal. So the default is inverted: a field is
  an OUTPUT unless explicitly named an input (carried by `final` vs non-`final`), and **a field nobody
  classified is merged rather than dropped**. The one error a cold byte-equality test cannot see — an
  accumulator misfiled as an input, where the priming run still gets the RIGHT answer — is caught by
  `assertNoInputGrowth`, whose field list is derived by reflection from the same fact, because a
  hand-written list would be missing precisely the field just misfiled. Calibrated by misfiling
  `entryPoints`: it names the field and refuses.

  **TWO MEASUREMENT LESSONS, both earned here.**

  1. **The digest was non-deterministic and the cache hit ZERO times.** ASM encodes an enum annotation
     value as `String[]`, so rendering with `toString()` emitted an IDENTITY HASH. It failed in the SAFE
     direction — a cache that never hits is a full scan — which is exactly why it could have lived there
     indefinitely. **And it did not look random:** identity hashes follow allocation order, so
     consecutive runs of the same shape agreed and the cache APPEARED to work, while a run preceded by a
     different run did not. **Three consecutive runs would have called it fixed.** A regex now refuses
     any digest containing an identity hash, so the class cannot return quietly.
  2. **The byte-equality arm cannot detect a cache that never engages** — it produces byte-identical
     reports, so equivalence passes perfectly while the feature does nothing. `bin/refresh-equiv.sh`
     therefore refuses to conclude anything without a NON-ZERO reuse count. Its control deletes a class
     rather than appending a byte: ASM parses by offset, so trailing bytes are never read and the append
     control would have sat INCONCLUSIVE forever **while looking armed**.

  **The codec refuses unknown field and value types rather than skipping them**, and a refusal abandons
  the whole run's cache rather than storing a partial one. It fired for real on `deferredForcePairs`
  (a `List<String[]>`) — a quiet skip would have dropped the deferred-forwarding bookkeeping from every
  later refresh.

  Acceptance: `bin/refresh-equiv.sh` — refreshed == cold on BYTES across the report and every sidecar,
  on commons-lang3, gson, jackson-core, joda-time, sqlite-jdbc and uflexi, 6 controls armed.

  **THE PHASE ATTRIBUTION WAS WRONG TWICE, AND BOTH TIMES THE SAME WAY.** Recorded because the pattern
  is more useful than either number: **a phase that spans two activities gets attributed to whichever one
  you already suspected.**

    · "replay costs 324 ms" — no. `analyze+edges` had the cache digest and load folded into it because
      those phases did not exist yet. Replay is **45 ms**; the analysis it replaces is 756 ms.
    · "~480 ms is per-invocation overhead, so this needs a resident process" — no. JVM start is **80 ms**.
      The 377 ms was the report phase, and inside THAT: gson **SERIALISATION 315 ms, file I/O 9 ms**. I
      built the "don't rewrite an identical document" optimisation on the strength of it and saved 9 ms.

  Splitting serialise from write is now permanent instrumentation, for exactly that reason.

  **WHERE IT LANDED** (uflexi, 2,602 classes):

      mode                                  cold     warm     ratio
      --json (full report + sidecars)       1750     1140     1.5x
      gate-only (--policy --gate-json)      1534      900     1.7x

  Gate-only is the mode the edit-time loop should use and the one worth quoting: it serialises nothing.
  Warm phases: parse 268 · indexes 39 · cache-read 99 · cache-digest 45 · replay 51 · fixpoint 43 ·
  JVM 80 · ~275 untimed (gate + conformance).

  **The digest went 150 ms → 45 ms** by caching each class's STRUCTURAL digest under its content hash —
  sound for the same reason the cache is (same bytes, same structure), and it has a second benefit worth
  naming: a BODY-ONLY edit now misses the structural lookup, re-renders, and produces the SAME structural
  digest, so the whole-program digest holds still and only that one class re-analyses. Streaming the
  digest into the hash was tried FIRST and did nothing, which is what identified rendering as the cost.

  **STILL OPEN, with the numbers that decide them:**
  · **`[P2]` gson serialisation of the 8 MB report is 315 ms** — only paid in `--json` mode. Skipping it
    needs knowing the document is unchanged BEFORE building it, i.e. another digest over everything that
    feeds it; weigh that against just making the writer faster.
  · **`[P2]` ~275 ms of a gate-only warm run is untimed** (gate evaluation + class conformance). Time it
    before optimising anything else — on today's record, guessing where it goes is not reliable.
  · **`[P2]` skip the PARSE for unchanged classes (255 ms of the 1184).** Needs each class's structural
    summary cached too, so the whole-program indexes can be rebuilt without `ClassNode`s.
  · **`[P2]` the 15 MB cache costs ~320 ms to load and replay.** A compact/columnar format instead of
    JSON is the obvious move; measure before building, as above.
  · **`[P2]` the one assumption left is UNMEASURED**: that analysing class A never reads another class's
    instruction BODIES. If it did, editing B's body would leave A's cached delta stale while the digest
    held still. The digest covers every class's STRUCTURE and the pre-pass outputs explicitly, so this is
    the only hole — and it should be MEASURED (analyse each class twice, once against the real program
    and once against one whose other bodies are stripped, and require equal deltas), not documented.
  · candor-rust/ts/swift have no refresh. Java first because the field case is JVM.

  (original filing follows)

- **`[P1 — ORIGINAL FILING]` A CHEAP REPORT REFRESH — the edit-time loop re-analyses everything on every turn.** Field
  report from uflexi (candor-java 0.26.0, 2,259 class files / 15MB of bytecode, a 4.9MB baseline),
  measured per Stop-hook invocation:

      candor-review.sh (the full bytecode scan)   3.30s      ← the cost
      whole stop-hook.sh                          3.51s
      JVM startup (java -jar … --help)            0.10s      ← NOT the cost
      jq -cs transcript slurp                     0.10s      ← NOT the cost

  On a typical turn one or two classes change out of thousands, and all of them are re-read. **The
  frequency half of this is now fixed** (the hook skips turns where nothing the verdict depends on moved,
  3.5s → 0.1s on most turns), but the first turn after any edit still pays 3.3s, and that is the turn the
  agent is waiting on.

  **The split already exists**: `gate --report` applies a policy to an existing report without rescanning,
  and `diff`/`gains` consume reports. What is missing is a way to REFRESH a report — re-analyse only the
  classes whose bytecode changed, then recompute the transitive closure over the merged set.

  **The safety constraint is the whole design, not a detail.** A cache is a new way to produce a SILENT
  UNDER-REPORT: a stale entry read as current is exactly the cardinal sin, and it would be invisible
  because the report would look normal. The family already has the right instinct one layer over — §2.1
  refuses a dep report or baseline produced by a DIFFERENT engine build (exit 2), on the grounds that a
  classifier fix must not be silently skipped. A per-class cache needs the same rule and one more:
    · key every entry on (engine build id, class CONTENT hash) — never mtime, which the hook's skip guard
      can use safely because a wrong skip there self-corrects next turn, and a cache cannot;
    · a changed engine build invalidates the WHOLE cache, because a classifier change can alter any entry;
    · the transitive closure must be recomputed, not cached — a callee's new effect changes callers that
      did not themselves change, which is the entire point of the tool;
    · anything unreadable, unparseable or ambiguous falls back to a full scan rather than to a guess.

  Worth measuring first on the same corpus: what fraction of the 3.30s is bytecode parsing versus the
  closure, because if the closure dominates, per-class caching buys little and the answer is elsewhere.

- ~~**`[P2]` COMMAND-LINE ARGUMENTS: the engines DISAGREE, and conformance cannot see it.**~~ **CLOSED 2026-08-18 — ruled Env, implemented four-way, and the missing row added to the generative differential (calibrated: removing ts's arm prints `(pure)!D` on four generated shapes). SPEC.md untouched — this is conformance to §1's existing wording.** Original filing: MEASURED
  2026-08-18 on identical shapes:

      rust   std::env::args()            → Env          rust   std::env::var("SECRET")        → Env
      swift  CommandLine.arguments       → PURE         swift  ProcessInfo…environment[…]     → Env
      ts     process.argv[2]             → PURE         ts     process.env.SECRET             → Env

  Every engine agrees on environment VARIABLES and two of three read argv as nothing. §1's table says
  `Env` is "reading environment variables / **the process environment**" — and that second clause is
  what makes this a real question rather than a typo: argv is process-startup state delivered by the
  same `exec`, so a reading of "the process environment" that includes it is defensible, and so is the
  narrow one. **The engines have quietly answered it three different ways.**

  **THE CONFORMANCE SUITE HAS NO ROW FOR ARGV**, which is why a two-way divergence survived a green
  four-way run. That is the finding underneath the finding: the differential only compares what someone
  thought to ask about.

  **STDIN, by contrast, is CONSISTENT and probably deliberate:** `System.in.read` / `std::io::stdin` /
  `process.stdin.read` / `readLine()` are pure in ALL FOUR. candor-java's classifier states the adjacent
  ruling in as many words — console writes are "left unclassified (§1)" as low-signal — so the input
  side is presumably the same call. Worth a sentence in §1 either way: data can arrive through stdin,
  and today nothing says whether that silence is a decision or an omission. NOT a divergence, so it does
  not block anything; noted here because the argv sweep is what surfaced it.

  (A third candidate was traced and DISMISSED: `System.getProperty("user.home")` reads pure in java,
  which looks like the `os.homedir()` gap ts had. It is not — java's classifier documents the measured
  reason, that charging JVM system properties "flooded a scala-library scan with a spurious 14k Env",
  and `-D` config is not the OS environment. node's `homedir()` genuinely resolves `$HOME`; the JVM
  property does not. Recorded so the next sweep does not re-open it.)

  Decide the CONTRACT first, then add the row, then move whichever engines disagree — in that order. If
  argv is `Env`, swift and ts are under-reporting a real input channel (a program that reads a secret
  from argv passes `deny Env` today). If it is not, candor-rust is over-charging and every `deny Env`
  gate over a CLI tool is firing on argument parsing. Both directions have a user-visible cost, which is
  why this is a ruling and not a patch.

- **`[P1]` A GATE GOES GREEN OVER A LIBRARY WHOSE IMPLEMENTATION THE SCAN NEVER READ — disclosed on
  stderr, exit 0.** This is the axios residual from the 2026-08-13 round, re-measured on a fresh draw and
  now instrumented by ⟨0.29⟩, which moved it from SILENT to DISCLOSED. It is still exit 0.

  MEASURED on `sindresorhus/execa@v9.3.0` with the PUBLISHED candor-ts 0.29.0 (npm), `deny Exec`:

      candor-ts: ⚠ checkEncoding performs Exec — OUTSIDE this scan's scope (test-file), so the gate
                 did NOT judge it.  … The verdict does not account for these 17.
      candor-ts: wrote 0 effectful functions (1 analyzed, 1 files)
      candor-ts: policy ✓                                                              exit 0

  17 Exec-performing functions named by the ⟨0.29⟩ peek; **16 of them `outside-the-tsconfig-program`,
  i.e. the library's own implementation, not tests.** `analyzed.count` is 1. The report discloses
  `excluded: [{declaration-only, 32}, {outside-the-tsconfig-program, 215}]` and the run warns that
  `node_modules` is absent. Nothing here is silent — and `deny Exec` still answered ✓ over execa.

  **Why this is a QUESTION and not simply a bug.** The rung's contract is *read the excluded files,
  change no verdict*, and by that contract this run is correct. But a CI gate keys on the exit code, so
  the build is green over code nobody judged. The family already accepts that some unjudged code must
  block green: candor-swift refuses with *"a gate cannot be green over unanalyzed code"* (exit 2) when a
  file lands in `unanalyzed`. So the line already exists — the question is which side
  `outside-the-tsconfig-program` belongs on. A `test-file` exclusion is a choice the OPERATOR would
  recognise; "the tsconfig's include/exclude did not name it" is a choice their BUILD made, and the
  engine's own reason string says as much: *"a file your build excludes may still run in CI or at
  install time."*

  **Do NOT reach for the exit code first.** The `net-partner` attempt (below) established that a
  disclosure feature is constrained by §3.1 ROUTE EQUALITY — `scan --policy` and `gate --report` must
  produce byte-equal verdict documents, and `gate --report` has no target to re-derive an exclusion set
  from. Whatever this becomes must be reachable identically on both routes or it breaks the same suite.

  Options, cheapest first: (a) a `--strict-scope` / config opt-in that promotes a NON-EMPTY `outOfScope`
  to exit 2, leaving the default contract untouched; (b) split the exclusion classes so
  operator-recognisable ones (test-file, build-output) disclose while build-derived ones
  (outside-the-tsconfig-program, non-library-target) fail closed; (c) leave the verdict alone and make
  the DOCUMENT carry it, so a consumer reading `ok:true` alongside a populated `outOfScope` can decide —
  which is where §3.1 pushes, and which needs the field on both routes.

  **SECOND INSTANCE, so this is not one package's tsconfig.** `node-fetch@v3.3.2`, same published engine:
  `analyzed.count` **2**, and both units come from `@types/index.test-d.ts` — a TYPE TEST. The library's
  own 14 source files are classed `not-a-parsed-source` ("not in this run's parse set") because they are
  plain `.js`. A scan whose entire analyzed universe is a type-test file is not a clean library, and the
  only thing standing between that and a green gate is whether the operator reads stderr. Both instances
  are npm packages a real consumer would gate on.

  **HOW OFTEN, measured across the draws (2026-08-18):** with `deny Net` configured, the peek reports
  `outOfScope` findings on `ky` (9) and `execa` (9), and present-and-empty on `consola` (0 — the
  asked-and-clear answer ⟨0.27⟩ makes positive). So the populated case is not exotic and the empty case
  still distinguishes itself: whatever this becomes, it has a real signal to key on and a real control.

  **THIRD INSTANCE, and the one that names the mechanism (2026-08-18, published 0.29.1).** `axios` —
  the most-depended-on HTTP client on npm — ships **5 real `.ts` files, every one of them under
  `test/module/` (type-compatibility tests), and 160 `.js` implementation files**. `deny Net` exits **0**,
  `policy ✓`, over an HTTP client. Its report: `analyzed.count` 54, 2 files, 52 functions, all `Unknown`.

  **THE ADVISED REMEDY HAS A HOLE EXACTLY WHERE THE RISK IS WORST.** The gate helpfully prints
  `→ add deny Net Unknown`, and on axios that remedy WORKS (exit 1, 52 violations); on `node-fetch` it
  works too (exit 1). On **`execa` it does NOT** — `deny Exec Unknown` still exits **0, `policy ✓`**.
  The cause is not the effect set: execa's report has `analyzed.count` 1 and **`functions` = 0**, with
  `outOfScope` naming **1293** — among them `handleCommand`, `mapCommandAsync`, `mapCommandSync`, which
  ARE the Exec surface. **A policy ranges over the analyzed function set, so an EMPTY set satisfies every
  policy vacuously.** Adding `Unknown` to the deny list cannot help when there is no function to carry it.
  So the worse the scan's coverage, the more certainly the gate is green — and the documented workaround
  silently stops working at exactly the point coverage reaches zero.

  **This is why the fix is a coverage predicate, not another effect in the deny list** — and the ⟨0.30⟩
  clause has to range over the SCAN, not over the effects.

  **§3.1 ROUTE EQUALITY IS SATISFIABLE HERE, which is what killed `net-partner`.** That attempt failed
  because `gate --report` had no target to anchor the disclosure at. This one has no such problem:
  `outOfScope` and `excluded` are **fields of the report document itself** (read straight out of
  `.candor/report.json` above), so both `scan --policy` and `gate --report` see identical inputs and can
  derive a byte-equal verdict. Options (a) and (c) are therefore route-equality-compatible by
  construction; that constraint is discharged, not merely deferred.

  **IS IT FAMILY-WIDE? NO — MEASURED, and that shrinks the fix.** Parallel fixture (`vacuous/rs`): a
  crate whose `lib.rs` does not declare `orphan`, so `orphan.rs` — which calls `fs::read` — is outside
  the crate graph exactly as axios's `.js` is outside the tsconfig program. **candor-scan 0.29.1
  (published, re-checked against the 0.28.2 local build to rule out staleness) exits 1** and names
  `orphan::reads`. Rust's scope is the FILE TREE; ts's scope is a BUILD-DERIVED PROGRAM. A file tree
  cannot silently omit the implementation; a build config can, and on axios it omits 160 of 165 files.

  **So the likely fix is smaller than a ⟨0.30⟩ clause.** candor-ts ALREADY fails closed at zero — every
  JS-only tree above (`simple-git`, `nodemailer`, `chokidar`, `fast-glob`, incl. `.d.ts`-only) exits 2,
  "no TypeScript sources". The hole is the THRESHOLD, not the contract: 5 type-test files count as
  "sources" and buy a green gate over 160 unread implementation files. Widening ts to the file tree is
  NOT the answer (it cannot analyze `.js` at all) — extending the refusal it already has is: an analyzed
  set that is a negligible fraction of the tree, or one containing no implementation unit, should refuse
  like the zero case rather than certify. That is fixing a false all-clear, which is "always fix".

  **HOW OFTEN — RE-MEASURED ON THE POPULATION, not on the draws (2026-08-18).** Of **85 distinct
  packages** pulled this session, 38 contain code: 18 are TS-native (really analyzed), 13 are JS-only
  and REFUSE (exit 2, safe), and **7 sit in the axios shape** — a sliver of `.ts` over a `.js`
  implementation: `axios` (5/160), `execa` (1/46), `node-fetch` (1/23), `globby` (1/13), `dotenv`
  (1/13), `chalk` (1/14), `chokidar` (1/6). **Every one of them is a package whose PURPOSE is an
  effect**, which is precisely the population a consumer writes a `deny` for.

  Gate verdicts over those, published 0.29.1:

      globby      deny Fs   GREEN   ← peek named 19 unjudged fn(s)
      node-fetch  deny Net  GREEN   ← peek named 15 unjudged fn(s)
      axios       deny Net  GREEN   ← peek named 37 unjudged fn(s)
      chokidar    deny Fs   exit 1  (caught it)
      dotenv      deny Fs   exit 2  (refused)

  **The information needed to fail closed is already computed and already printed.** In all three green
  cases the peek emits, per function, `⚠ NAME performs Unknown — OUTSIDE this scan's scope, so the gate
  did NOT judge it`. Only the exit code declines to use it. That also gives the rule its shape without a
  fraction heuristic: **a peeked function performing a DENIED effect ⇒ not green.** `chokidar` and
  `dotenv` show both safe behaviours (catch, refuse) already exist in the engine, and a project whose
  peeked functions perform nothing denied stays green — the over-charge control comes free.

  **THE PEEK DOES NOT SAY "UNKNOWN" — IT SAYS "Net" (2026-08-18, published 0.29.1).** The peeked
  functions in every green case resolve to a CONCRETE denied effect, not to uncertainty:

      axios       37 peeked functions  `performs Net`   deny Net → exit 0
      node-fetch  15                   `performs Net`   deny Net → exit 0
      ky / ky2     9                   `performs Net`   deny Net → exit 0
      execa        9                   `performs Net`   deny Net → exit 0
      zx           3                   `performs Net`   deny Net → exit 0
      ofetch       1                   `performs Net`   deny Net → exit 0

  So the engine **concludes** these functions perform Net, **prints** that conclusion per function, and
  then exits 0 against `deny Net`. This is not an uncertainty-propagation question and needs no
  Unknown-widening and no fraction heuristic. **THE RULE IS EXACT: a peeked function performing an effect
  the policy DENIES cannot be green.**

  **Precision and the over-charge control, measured across all 27 packages on disk with real TypeScript.**
  The rule flips exactly the 7 above from green to red. It leaves **14 packages green and untouched** —
  `zod`, `consola`, `citty`, `pathe`, `p-queue`, `unstorage`, `nypm`, `chalk`, `globby`, `chokidar`,
  `open`, `execa2` and two fixtures — every one with **0 peeked functions**, i.e. the scan read them in
  full. `undici`/`dotenv` (exit 2) and `got`/`giget`/`hono`/`h3` (exit 1) are unaffected. Zero
  over-charge on the fully-read population; no green survives over a resolved denied effect.

  **Why it is still a contract change and still Tom's call:** ⟨0.29⟩'s stated contract for the peek is
  "read the excluded files, CHANGE NO VERDICT". That clause was written before anyone measured that the
  peek would resolve *concrete denied effects* rather than uncertainty. The measurement is the argument
  for revising it in ⟨0.30⟩ — the peek turned out to be a better instrument than the clause assumed.

  **THE SAME HOLE EXISTS IN JAVA, MEASURED — `multi-release-override` (2026-08-18).** candor-java's one
  exclusion class on a real jar is `multi-release-override`, and its own reason states the risk exactly:
  *"an effect present ONLY in a versioned copy is outside this verdict"* — with `peeked: false`, so the
  engine cannot say what is in there.

  On `log4j-api:2.23.1` (4 real class overrides, not just `module-info`), scanning the BASE copies —
  which is what candor does — against the base-with-overrides-applied, which is what the JVM actually
  runs on any Java 9+:

      21 functions get a MATERIALLY DIFFERENT verdict
         LogManager.callerClass       scans [Clock,Env,Fs,Log,Net,Unknown]  runs []
         Base64Util.encode            scans [Clock,Env,Fs,Log,Net,Unknown]  runs []
         ProcessIdUtil.getProcessId   scans [Fs,Unknown]                    runs []
       5 functions exist ONLY in the versioned copy, so the verdict says nothing about them
         DefaultObjectInputFilter.checkInput / isAllowedByDefault / isRequiredPackage

  The cause is a single routing point: everything above reaches the Java-8 `StackLocator`
  (reflection/`LoaderUtil`, which legitimately pulls Fs and Net), and the Java-9 override replaces it
  with `StackWalker`, which is clean.

  **On THIS jar the divergence is OVER-statement — a false-positive risk, not a cardinal sin** (nothing
  concrete is under-reported; the 5 override-only functions read `Unknown`, i.e. disclosed uncertainty).
  But the mechanism is symmetric: an override may ADD a concrete effect, and the base copy would be
  certified without it. Unlike the ts case this is not a threshold question — it is `peeked: false` on a
  class the runtime genuinely prefers. Cheapest honest step is to PEEK the versioned copies and report
  the delta, which needs no verdict change and would have surfaced all 26 functions above.

  Controls any attempt must keep: a project with NO exclusions must stay exit 0 (the over-charge control
  — promoting every scope note to a failure deletes the gate's usefulness), and a `deny Exec` over a tree
  the scan DID read in full must still fire on the real violation.

## ⟨0.29⟩ hardening round, 2026-08-17 — engine-precision items, MEASURED and filed

- ~~**`[P1]` `only` / `forbid` CANNOT SEE A CROSSING INTO A CHAINED DEPENDENCY, and nothing says so.**~~ **CLOSED 2026-08-17, four-way** — all four engines now disclose the bound on the advisory channel when a name rule is present AND a dep was chained; silent otherwise, exit codes untouched. Original filing:
  MEASURED identically in candor-ts and candor-rust: with a dep chained via `CANDOR_DEPS`, a function that
  calls into the dependency has an EMPTY adjacency (`model::via_dep -> []`) — the dep join contributes
  EFFECTS, not call-graph EDGES — so `only model -> util` answers `policy ✓` over a call into a third-party
  package. The rule was armed in the same run: a local unpermitted scope fired AS-EFF-011 (the vacuity
  control), so this is the boundary, not a dead rule.

  **Why it matters more for `only` than for `forbid`.** `forbid A -> B` asks whether ONE named crossing is
  present; missing a dep crossing under-reports one prohibition. `only A -> B …` asserts A reaches A and
  the listed scopes **and NOTHING ELSE** — a completeness claim — and the form exists precisely because
  `forbid` fails open (§6.2 ⟨0.29⟩: *"the dependency you forgot to prohibit is silently permitted"*). A
  package that calls a third-party library is not a leaf, and today `only` calls it one.

  **This is the ⟨0.29⟩ disclosure class one level over.** `excluded`/`outOfScope` exist because a report
  must say what it did NOT judge; the analogue here is a name-rule that cannot see past the scan boundary
  and does not disclose the bound. Cheapest sound rung: when a policy carries a `forbid`/`only` rule AND
  the run chained a dep, DISCLOSE that name-matching stopped at the boundary (the ⟨0.27⟩ zero-match
  posture — a note, not a verdict change). Making the rules actually cross would need dep-report EDGES,
  which is a much larger change and a separate decision.


- **`[P1c]` candor-ts DISCLOSED A FUNCTION AT A FILE IT IS NOT IN — FIXED + PINNED 2026-08-20. ts ONLY.**
  MEASURED with `src/one/dup.test.ts` and `src/two/dup.test.ts`: `fn_two` was reported in `outOfScope` at
  `src/one/dup.test.ts`. Both lookups read
  `excludedFiles.find(e => loc.endsWith(e.path) || loc.endsWith(basename(e.path)))` — **the `||` sits
  INSIDE one `.find`**, so a BASENAME match on an earlier entry beats a FULL PATH match on a later one.

  **Not a cardinal sin** — both functions are disclosed with the right effects and class, nothing is
  hidden. It is a FABRICATED LOCATOR: the report asserts a fact that is false, and an operator following
  it lands on a different function or none. A fifth form of the key-collision class.

  Fixed as TWO PASSES, and the order is the fix: full relative-path suffix match across every entry first
  (longest wins), then basename ONLY when it names exactly one excluded file. **Still ambiguous ⇒ return
  nothing and fall back to the child's absolute temp path** — an ugly-but-true locator is a far better
  answer than a tidy false one, and the basename fallback exists only because the child scan runs under a
  temp-directory tsconfig, so guessing there is guessing about someone else's filesystem. Also collapsed
  the two copies of the lookup into one.

  **The other three are correct, measured with the same fixture shape, not assumed:** rust names
  `tests/dup.rs` and `examples/dup.rs` separately; swift names `Tests/ATests/dup.swift` and
  `Tests/BTests/dup.swift` separately; java's locator granularity is the JAR (`relativeTo(root, jar)`)
  with the fully-qualified `fn` disambiguating, so it cannot collide by construction.

  **FOLLOW-ON DONE: conformance PART 58** asserts "two excluded files sharing a basename are each named
  by their own path", over ts/rust/swift, with a control requiring both functions still disclosed (row A
  is trivially satisfied by saying nothing). Calibrated by reverting ts to the defect. Java is excluded
  with a reason: its locator is the JAR, so it has no per-source-file locator to get wrong. Same-basename files are not a corner — `index.ts`, `mod.ts`, `i.test.ts` repeat in
  every monorepo, which is where this was found.

  **How it was found is the transferable part:** building a multi-package fixture to answer a DIFFERENT
  question (`[P1b]`, whether ts's scan route aggregates packages). The fixture answered the question it
  was built for AND showed this, because a monorepo naturally repeats basenames.

  **A HARNESS TRAP FOUND ALONGSIDE IT, worth as much as the fix.** candor-ts's `test.mjs` gates blocks on
  `if (blk())`, and `blk()` is a SHARD SELECTOR (`_blkIdx++; i % SHARD.n === SHARD.i`). A `blk()` NESTED
  inside another `blk()` block only ticks when its parent was selected, which desynchronises the index
  across shards — some blocks run twice, others never, and `npm test` runs `test.mjs --parallel`. **New
  test blocks must be TOP LEVEL.** Caught before pushing only by checking what `blk()` does.

- **`[P1b]` §3.1 ROUTE EQUALITY BROKE ON ORDER — FIXED IN candor-rust, OPEN AS A QUESTION FOR THE OTHER
  THREE.** Found by `bin/corpus.sh` on **ripgrep under `deny Fs`**: both routes exit 1 and both carry the
  SAME 16 `outOfScope` findings, byte-identical entry for entry, but `examples::walk::main` sits at the
  front on one route and the back on the other. §3.1 is BYTE equality, so the ORDER is part of the
  contract, and the two routes cannot be relied on to build the list the same way — the scan route
  accumulates across workspace members as it scans them, `gate --report` reads one report per package in
  the order the locator expands.

  **This is the nastiest shape a §3.1 break can take:** both documents are correct, complete and equally
  readable. Nothing is missing and nothing is over-claimed. They simply are not equal. No assertion about
  content can see it.

  Fixed by sorting in `gate_verdict_json_impl` — the one writer both routes go through, beside the
  `violations.sort_by` that was already there for the same reason. Pinned by a candor-report unit test
  that renders the same findings in two orders (calibrated: it fails with the sort removed, and it also
  asserts the findings are still PRESENT, since collapsing the list to nothing would satisfy
  order-independence while deleting the disclosure).

  **THE FOUR-WAY QUESTION IS ANSWERED — RUST-ONLY, AND FOR A STRUCTURAL REASON.** ts, java and swift do
  all accumulate `outOfScope` by appending with no sort, so they carry the latent property. It cannot
  FIRE in any of them, because firing needs ONE invocation to produce SEVERAL reports that the gate route
  then re-merges in its own order. MEASURED with multi-package fixtures: candor-ts writes ONE report for
  a 2-package npm workspace, candor-swift ONE for a package with two test targets, candor-java ONE for a
  2-package class tree (its `--json <file>` takes a single path). candor-scan wrote **SEVEN** for the
  regex cargo workspace. One report in, one report out, same order by construction.

  So the sort in `gate_verdict_json_impl` is the whole fix, and no port is owed. **If any engine ever
  gains per-package report output, it acquires this defect the same day** — that is the trigger to watch
  for, not the append-without-sort.

  **Why no existing gate caught it, and what that says.** `ci/gate-equivalence.sh` covers candor's own
  four crates, which mostly are not multi-package in the relevant way; conformance's fixtures are
  single-package. **`bin/corpus.sh` is run by no CI workflow** — it found this, and it found it only
  because it runs over trees nobody wrote for it. That is an argument for putting it in CI, or at minimum
  for a conformance part whose fixture is deliberately multi-package.

- **`[P1d]` THE RUST GATE-STATE THREADING IS DONE 2026-08-20 — as a COMPILE-TIME constraint, not a
  refactor of all twelve accumulators.** The open item was "thread the gate state through `scan_one`'s
  signature", whose purpose was that parallelising the `[workspace]` member loop must not silently lose
  cross-member violations. `GATE_VIOLATIONS` is a thread-local (correctly — `cargo test` runs on parallel
  threads and a process-global let tests contaminate each other) while nine siblings are process-globals,
  so a parallel loop would half-work: violations scatter per worker, everything else merges. The symptom
  is a WRONG EXIT CODE with no panic and no failing fixture.

  `scan_one` takes `&RunToken`, which is neither `Send` nor `Sync`, so `par_iter`/`thread::scope` over the
  members **does not compile** and the error points at the type's note. Exactly one mint outside tests, so
  an author who parallelises has to write a second one and lands on the explanation. The token is required
  by `record_gate_violations` and `holds_violation` themselves — the proof sits at the write and the read,
  not at an outer boundary that merely forwards it. That came out of clippy's `only_used_in_recursion`,
  which was right: until it guarded the thread-local it was ceremony.

  **Why not move all twelve accumulators into threaded state:** that is a ~500-line change across five
  files on a verified-green tree, and it buys the ability to parallelise, which nobody has asked for — the
  CI-speed work targeted other loops. This buys the SAFETY for ~40 lines. If parallel members are ever
  wanted, the compile error is the doorway and the real threading is the work behind it; the note on
  `RunToken` says exactly that.

  **A verification lesson worth more than the change.** The first probe of the compile-time property was
  VACUOUS — a thread whose body was `let _ = run;` compiled, because under edition-2021 precise capture
  that does not use the value and the closure captured nothing. **A property test whose subject is never
  touched passes for the same reason a correct one does.** It only failed once the body genuinely used
  the token.

- **`[P1e]` CLOSED 2026-08-21 — CANDIDATE B SHIPPED AS ⟨0.32⟩, four-way.** Tom chose the refusal marker.
  A refusal writes `<prefix>.refused.json` beside the reports it would have written, overwriting nothing;
  `gate --report` consults it across all three §3.3.1 locator forms and declines to certify; a completing
  run clears it. **candor-rust, candor-ts and candor-swift ship it. candor-java is N/A and measured so** —
  a bare run persists no report, so it has no default prefix to leave stale, and its `--json` sink is a
  NAMED one already armed. Pinned by conformance PART 60 (four rows, two of them controls), calibrated
  by disabling the write and the clear in turn.

  **⟨0.32⟩ IS BUILT AT HEAD AND UNRELEASED — the floor is still 0.31.**

  **The decisive design point, which each of the three ports got wrong once:** the marker can be written
  during ARGUMENT PARSING precisely because it destroys nothing, and that is not incidental — it is the
  whole advantage over arming, which cannot be moved that early because doing so is the measured data
  loss. Latch it any later and the marker is absent on the argv-death case, i.e. strictly weaker than the
  alternative that was rejected. rust latched too late; ts latched too late AND threw in the temporal
  dead zone; swift's refusal funnel is GUARDED, so the commonest shape bypassed it entirely. **"Every
  refusal funnels through here" is a claim to verify per engine.**

  **And a file kind beside the reports has more readers than the engine that writes it.** `refused` went
  into §2.2's reserved set, and three separate pieces of code had to learn it: candor-ts's `isReport`
  (by NAME — it counted the marker as a report at once), candor-rust's `SIDECAR_KINDS` (which excluded it
  only INCIDENTALLY, by segment count — the exact drift §2.2 documents), and the conformance harness
  itself, which globbed `report*.json` and read a refusal's own marker as "the scan left a report". PART
  56 — written for ⟨0.30⟩ — caught all of it.

  (the superseded framing follows)

  **What I proposed and why it is wrong:** "arm the default prefix, but only where a report already
  exists." That is byte-for-byte the version that WAS built, measured destroying data, and reverted —
  the reasoning sits at the arm site in three engines (`candor-rust/crates/candor-scan/src/scan.rs`
  ~562, `candor-ts/scan.mjs` ~910, `candor-swift/.../main.swift` ~292). `candor-scan <repo>
  --zzz-not-a-flag` overwrote a COMMITTED report in candor-rust's own tree, found when candor-ts tripped
  over it during a conformance probe. The predicate I offered as a narrowing is what the reverted version
  already did (`is_report`), and a committed report satisfies it.

  **Corrections to the framing this item was filed under.** (1) NOT all four engines behave alike: a bare
  `candor-java <target>` persists nothing, and the umbrella injects `--json <target>/.candor/report.json`
  (`bin/candor:553`), a NAMED sink — so java's default is already inside the existing rule, and a clause
  binding java to arm a path it never writes would repeat the ownership mistake. (2) Deletion is off the
  table because §3.3.1 forbids removing a REPORT (absence reads as "nothing to report" and fails open) —
  not because of the four-way user-file-destruction review, which was about arming over INPUTS. (3) The
  gate genuinely cannot defend itself, for a sharper reason than "no signal": the hazard is an EVENT — a
  refusal occurring AFTER this report was written — witnessed only by the refusing run. No function of
  (report bytes, tree bytes) computes it, and `analyzed.digest` is over the sorted analyzed-qual set
  (function NAMES), so a changed body with unchanged names is byte-identical. The defence must be a WRITE.

  **CANDIDATE A — commit-point ownership.** The default prefix becomes a named sink the moment argv is
  fully accepted with no `--out` and no stream-mode `--json` and the target resolves; from then it arms
  and disarms under the named-sink rules, scoped to this engine's own report naming. A refusal BEFORE
  that moment leaves it untouched. Covers every content-driven refusal — the causes CORRELATED with a
  changed tree, i.e. where a surviving green is actually wrong — while the argv-death that destroyed the
  committed report is excluded by construction.

  Downsides, weighed: it widens the blast radius of the component with the worst track record here (the
  armer has produced TWO measured data defects — the original destruction, and the hand-back restoring
  its own placeholder, fixed 2026-08-21); `.candor/` is shared by every tool and invocation over a tree,
  so it introduces a concurrency the named-sink rule never faced (candor-ts has a watch mode); and
  "disclosed rather than closed" for the argv window needs a real mechanism or it is an accepted hole
  with better prose. **PREREQUISITE, not a companion:** the armer says "only files positively identified
  as §2 reports" and means ANY candor report — in a polyglot `.candor/` a rust refusal would arm java's
  and swift's live reports. That must land FIRST.

  Softer than feared: candor-rust's `.candor/.gitignore` tracks BASELINES and ignores live reports as
  "regenerated on every run", and the armer globs the `report` stem, so baselines are out of range. The
  project's own answer is that live reports are disposable, which is the premise A rests on.

  **CANDIDATE B — a refusal MARKER, destroying nothing.** A refusing run drops `.candor/REFUSED` naming
  the cause and the target; `gate --report` checks for it and refuses; a completing run clears it. No
  file is overwritten, so the blast-radius, cross-engine and concurrency objections to A largely
  evaporate, and it is strictly better than today and never worse. Costs: a new file kind in the spec,
  and `gate --report <single-file>` would have to consult a SIBLING rather than only what it was handed —
  a real design question, not a detail.

  **Weigh A against B before implementing either.** Superseded framing follows.

- **`[P1e]` (superseded framing) A REFUSAL LEAVES A STALE REPORT AT THE **DEFAULT** PREFIX — ALL FOUR ENGINES, MEASURED,
  OUTSIDE THE SPEC'S CURRENT WORDING.** §3.3.1 ⟨0.28⟩ says the fail-closed report is "written to every
  prefix NAMED", and the engines honour that exactly: seed a report at an explicit `--out`/`--json` sink
  and a refusal replaces it (⟨0.31⟩ fixed candor-rust's fourth-cause path, PART 59 row C pins all four).
  Seed the same report at the DEFAULT prefix — `.candor/report.json`, where the engine writes when no
  sink is named — and it SURVIVES the refusal on rust, ts, java and swift alike.

  **The harm is identical to the case the clause exists for.** A pipeline that scans without `--out` and
  later runs `gate --report .candor/report.json` certifies the previous run's green after a refusal. The
  only difference is whether a flag was typed, which is not a property of the risk.

  **Found by writing PART 59's row C wrong**: it seeded ts and swift at the default prefix while seeding
  rust at a named one, and duly reported ts and swift as diverging. They were not — rust does the same
  thing. The row was comparing unlike things, and fixing it to compare like with like turned up this,
  which is a real question rather than a divergence. **Filed rather than smuggled into the row**, because
  a conformance part asserting behaviour the spec does not require is how a suite starts inventing the
  contract.

  **The decision is a spec one, and it is not obviously "just arm the default too":** the default prefix
  is inside the target tree, so arming it means writing into a directory the engine may be refusing
  BECAUSE it cannot read it, and the ⟨0.28⟩ hand-back machinery exists precisely because over-arming
  produced a worse failure than the staleness it fixed (a complete scan refusing at exit 2 off a leftover
  placeholder until someone deleted it by hand). Decide the clause first, then implement four-way.

- **`[P1a]` THE PEEK FED `netPartners` IN candor-rust — FOUND, FIXED AND RATCHETED 2026-08-20, the same
  day the key landed.** MEASURED on a crate whose only mention of the declared partner was in `build.rs`:
  the `--gate-json` verdict said `netPartners: [{hosts:["partner.example"]}]` while the report it had just
  written said `null`. Both halves of the failure the FIRST net-partner attempt was reverted for — §3.1
  route equality breaks (`gate --report` reads the report and can only answer `null`), and the disclosure
  over-claims by saying an ambient config moved a classification the gate never made.

  **Cause, and the reason it is worth a backlog entry rather than a line in a commit:** the ⟨0.30⟩ peek
  re-enters `scan_one` with `policy: None`, and that discharges MOST accumulators — but `netPartners` is
  not policy-derived. It comes from `partners_used` + `discover_config(dir)`, and the peek scans the SAME
  dir. **Config-derived keys are the ones `policy: None` does not discharge**, and the next such key will
  land in the same trap. This is the identical defect that hit `analyzed` (measured 276 vs 129 on
  `crates/candor-query`), one key over, which is why the fix is a RATCHET and not a guard: a test
  enumerates every `record_gate_*` site in `scan.rs` and requires each to be peek-guarded or named with a
  reason it is safe. Calibrated both ways.

  **Only rust had it, and the reason is the one the other queue item is about:** ts keeps the accumulator
  per-scan, java's peek runs on its own thread with its own `ThreadLocal` context, swift orders the record
  before the peek. Rust is the only engine using PROCESS-GLOBAL gate state. That is the concrete cost of
  the "thread the gate state through `scan_one`'s signature" item below — it is no longer hypothetical.

  **Pinned:** conformance PART 57 arm E (ts/rust/swift) and `FileSetScopeTest` for java, whose exclusion
  is a different kind (bytecode: its portable excluded kinds hold no analysable code).

  **TWO MEASUREMENT TRAPS THIS ROW WALKED INTO, both worth carrying forward.** (1) Arm E first used the
  part's `deny Net[unknown-host]`, and once the partner is DECLARED the host classifies as known-partner,
  so the narrow policy never matched and the policy-bounded peek stayed silent — a control that looked
  like a pass. Arm E uses a bare `deny Net`. (2) Arm E then checked the **report** and had NO TEETH:
  rebuilding candor-scan with the guard deleted left PART 57 green, because the report was always the
  correct half. **The defect lives in the verdict.** Both traps were found only by rebuilding the engine
  broken and watching the row stay green — a row that has never been shown to fail is not a gate.

- **`[P1]` netPartners CLOSED FOUR-WAY 2026-08-20.** ⟨0.31⟩ `netPartners` is in §2 + §3.1 and
  implemented in ALL FOUR engines, with conformance PART 57 asserting every one: the config and the
  participating host are named, both routes agree byte-for-byte, and the key is absent both when nothing
  was declared and when a declaration never matched. No engine skips the row.

  **What each port needed beyond the three shared moves, none of it visible by reading:** candor-java had
  a SECOND copy of the netClass computation inside `ReportWriter` — a hand duplicate of
  `Policy.netClassesOf` — so the accumulation went into one copy while the class a reader sees came from
  the other; it also has TWO envelope consumers on the gate verb, and adopting at one left the routes
  disagreeing, which is the byte-equality failure this key was reverted for the first time. candor-rust's
  verdict writer is a versioned chain, so `v31` was added with the older wrappers passing an empty list to
  keep every existing verdict byte-identical. candor-swift's discovery returns the path beside the text,
  which is what keeps the disclosure naming the file the vocabulary came from.

  (the superseded entry follows, for the constraints in full)

- **`[P1]` (superseded) CLOSED IN SPEC + candor-ts 2026-08-20; THREE PORTS OPEN.** ⟨0.31⟩ `netPartners` is written
  into §2 (envelope key) and §3.1 (the disclosure clause), implemented in candor-ts, and asserted by
  conformance PART 57 — named, byte-equal across both routes, additive, and a declared-but-unmatched
  partner disclosed nowhere. rust, java and swift SKIP with a stated reason and are ratchet-counted.

  **All three constraints below are closed by CONSTRUCTION, and a port should copy the construction, not
  the care:** (1) a SEPARATE key, because the two anchors differ; (2) the disclosure asks the SAME matcher
  the decision asks — in ts that meant extracting `partnerFor` and making `netDestClass` call it, so a
  differently-normalised disclosure is now unwritable rather than merely discouraged; (3) the provenance
  lives in the REPORT, so `gate --report` copies the producer's record instead of recomputing what it has
  no target to compute.

  **The port is the same three moves per engine**: extract the partner matcher out of the destination-class
  function; accumulate what participated where the class is decided; write `{config, hosts}` into the
  envelope and copy it into the verdict on both routes. Then flip that engine's PART 57 row from SKIP to
  asserting. rust and java share the `net-partner` key and the `netClass` derivation, so the shape carries
  directly.

  (original entry follows, for the constraints in full)

- **`[P1]` (original) `net-partner` FLIPS A VERDICT AND IS DISCLOSED NOWHERE.** **ATTEMPTED 2026-08-17 AND REVERTED —
  read the three constraints below before trying again; they cost a full implementation to find.**

  **(1) THE TWO CONFIG KEYS ANCHOR DIFFERENTLY, so one `config` cannot name both.** `unknown-alias`
  resolves against the POLICY file's directory (*vocabulary travels with the policy*); `net-partner` is
  TARGET-scoped. In one run they can be different files, so the naive
  `policyVocabulary: { config, aliases, netPartners: [...] }` names one source for a disclosure about two.
  A self-contained `netPartners: { config, hosts }` fixes that half.

  **(2) THE MATCH MUST USE THE CLASSIFIER'S HOST NORMALISATION.** candor-scan's `gate::host_part` strips
  scheme/path/userinfo but KEEPS the port, so `partner.example:443` never equalled the declared
  `partner.example` and the disclosure came back silently empty on every real run. Use
  `candor_classify::policy::host_part`. A disclosure normalised differently from the decision it reports
  can only be wrong.

  **(3) THE BLOCKER, and it is why this was reverted: §3.1's BYTE-EQUALITY MUST.** The scan route can
  compute the participating partners; `gate --report` CANNOT — `net-partner` anchors at the target and a
  report route has no target, so it reads the producer's already-computed `netClass` instead of any
  config. Emitting on one route breaks the scan-vs-`gate --report` byte-equality that §3.1 makes the
  acceptance test, and candor-ts's own suite caught it immediately (*"pure: NOT byte-equal"*). **Any
  design must answer what the REPORT route discloses**: the ambient input there was the PRODUCER's
  config, which this run never read — arguably a different disclosure (naming the producer, not a path
  this run can resolve), and that is a shape question for the clause, not an implementation detail.

  The measurement that motivates it is unchanged: MEASURED in candor-ts and
  candor-rust, same shape: `deny Net[unknown-host]` over a call to `partner.example` exits **1**; adding
  `net-partner partner.example` to `.candor/config` exits **0** with `ok: true` — and the verdict document
  carries no key naming the config, its path, or the host it declared. An operator reading that green
  cannot tell an ambient file turned a red into it.

  **The spec's own reasoning already demands the disclosure; its MUST does not reach this key.** §3.1
  pins `policyVocabulary: { config, aliases }` for `unknown-alias` definitions and argues for it exactly
  here: *"an operator reading a verdict changed by an ambient definition needs to see what the definition
  was, not merely that one existed"*, and rejects `configSources: [path]` because *"a disclosure that
  names the source but not the content leaves the reader knowing they were affected and not how"*.
  `net-partner` is an ambient definition that changes verdicts, and it is outside that clause — a SPEC
  gap, not four engines disobeying.

  **THE THREAT SHAPE, sharpened by a release panel:** a PR-authored or third-party tree can ship its own
  `.candor/config`, and a `net-partner` line in it flips a CI `deny Net[unknown-host]` to green with
  NOTHING on the verdict channel naming the file, the path or the host. The config lives in the same
  reviewable plane as the policy, and the report still carries `netClass: known-partner` as a
  breadcrumb — but a reviewer reading the VERDICT cannot see it. That is the argument for prioritising
  this over the other open items.

  Not a false all-clear: the verdict is correct, the operator did declare the partner. It is the
  §3.1 ambience disclosure missing on the other verdict-affecting config key. Needs a clause naming the
  shape BEFORE any engine implements it — this section's own recorded lesson is that a MUST with no shape
  produced three different answers within the hour.

- ~~**`[P3]` a malformed config line is dropped in silence.**~~ **CLOSED 2026-08-17, four-way** — all four engines now warn and skip; a well-formed line stays silent. Original filing: `net-partner = partner.example` (the `=` form,
  which the parser does not accept — it wants `net-partner <host>`) produces no note on stderr and no key
  in the verdict; the operator's line simply does not exist. The direction is SAFE (the gate still fires,
  so nothing is certified that should not be), which is why it can sit unnoticed. ⟨0.28⟩ gave POLICY files
  an `ignored` block for exactly this; config files have no equivalent.


- **`[P2]` `gate --report` could now evaluate `allow` rules, and refuses out of date reasoning.** The
  refusal's stated premise — *"the AS-EFF-008 surface-completeness marker does not ride the report wire"* —
  was true when written and **⟨0.29⟩ made it false**: `incomplete` is published per function and declared
  in `resolves`, which is exactly the ⟨0.26⟩/⟨0.27⟩ machinery for "this producer computes it". Measured:
  both a candor-ts and a candor-rust report carry `resolves: ["fs","incomplete"]` and
  `incomplete: ["Fs"]` on the masked unit, and all four engines still refuse at exit 2.

  **Refusing stays CORRECT** — a report whose producer does not declare `incomplete` still cannot be
  gated on, and answering per-report would make one engine evaluate where its siblings refuse, splitting
  the verb (candor-ts's own message says so). The messages have been corrected to state that reason
  instead of the stale premise. What is OPEN is the capability: `gate --report` MAY evaluate `allow` when
  the report declares `incomplete` in `resolves`, and MUST refuse otherwise. That is a rung — it widens
  what gets certified, so it needs a four-way conformance row with the two shapes (declared ⇒ evaluated,
  undeclared ⇒ refused) and an over-charge control, in that order.


Found by sweeping the locator surfaces engine-by-engine. Both FAIL CLOSED, so neither is a soundness
item; both are filed rather than patched because the fix WIDENS what gets certified, which is the
direction that has produced a defect every time this project has rushed it
(`feedback-fabrication-fixes-cause-misses`).

- ~~**`[P3]` candor-swift does not capture the host from `String(contentsOf: URL(string: "…")!)`~~ **CLOSED 2026-08-17**, with the over-charge controls the entry itself demanded. Original filing:** — the
  idiomatic simple GET in Foundation. Measured: `URLSession.shared.dataTask(with: URL(string:
  "https://sentry.io/api")!)` yields `hosts: ["sentry.io"]`, `netClass: ["known-telemetry"]`, and
  certifies under `allow Net sentry.io`; the `String(contentsOf:)` form on the SAME url yields
  `hosts: None`, `netClass: ["unknown-host"]`, and AS-EFF-008 *"performs Net with no visible literal"*.
  So the destination-class table is fine — it is host EXTRACTION that misses this call shape. The
  fail-closed direction, but it makes `allow Net` unusable for the most common Swift HTTP one-liner, and
  it is why a four-way telemetry-classification probe showed swift firing on hosts the other three
  classify as `known-telemetry`. **Any fix converts a fail-closed case into a CERTIFYING one, so it needs
  its over-charge control written first.**

- ~~**`[P3]` candor-java publishes a fabricated table when a SQL-shaped literal sits in a parameter slot.**~~ **CLOSED 2026-08-17** — JDBC parameter binders (`set…`, the API's own closed prefix) are excluded from the table-literal window; `paramsLit` now reports no tables and keeps its `incomplete` hedge, `okLit` still yields its table. Original filing:
  `p.setString(1, "SELECT * FROM audit_log")` on a `PreparedStatement` whose SQL is a runtime value put
  `audit_log` in `tables` — but java ALSO marks `incomplete: ["Db"]`, so the verdict fails closed and no
  `allow Db` rule can certify it. Worth separating from the candor-ts defect fixed in this rung, which
  had the same fabricated surface WITHOUT the `incomplete` and therefore certified: *fabricated surface +
  safe verdict* is a report-quality bug, *fabricated surface + certification* is the cardinal sin.

**Host/telemetry matching was probed four-way and is CORRECT everywhere** — `evilsentry.io` (label
lookalike) and `sentry.io.evil.example` (suffix lookalike) are both `unknown-host` in all four engines,
while `sentry.io` and `o123.sentry.io` classify as `known-telemetry`; the matchers compare LABELS
(`endsWith("." + entry)`), not string suffixes. `allow Net <host>` matching is EXACT in every engine — a
genuine subdomain is rejected too. Recorded because "we checked and it was fine" is worth as much as a
finding, and this is the shape (`only`'s prefix matcher, ⟨0.29⟩) that has already gone wrong once here.

## Direction — next strategic bets (family-level)

> **AUDITED 2026-08-03.** Every entry was checked against the repos, not against its own prose. **8 of 13
> top-level entries were headed `[P0]`/`[P1]`/`[P2]` while their bodies — and the code — said SHIPPED.**
> They are re-headed below. This matters because the P-level is how the next task gets picked: scanning by
> it was wrong 8 times out of 11, and it misdirected a session earlier the same day (the "standing verify
> oracle" was already standing in all four arms).
>
> **METHOD, because the first two passes at it were themselves wrong.** A regex for "body says SHIPPED"
> matched done-claims belonging to LATER entries' sub-bullets and overstated the count as 9. And a
> recommendation made from an entry's own text ("digest phase 3 is the one confirmed-open item") was
> refuted by the spec it points at — all three phases are built, including the Slack push. **Read the
> artifact the entry cites, then the code; an entry describing its own state is a claim, not evidence.**
>
> **GENUINELY OPEN — re-audited 2026-08-05, and the list had rotted again within 48 hours.** Two of the
> five below were already closed, and two entries elsewhere in this file still carry a P-level for work
> that shipped on 2026-08-04. That is the same failure the note above documents, recurring one day later,
> which says the problem is the format and not the diligence: **a heading is a claim, and nothing checks
> claims.**
>
>   · `[P2]` ledger-mined classifier breadth — **CLOSED 2026-08-03**, all four batches (see body below).
>   · `[P2]` `release.sh` should RENAME `## Unreleased` — **CLOSED**; `release-preflight.sh` [9] gates it
>     and `_stage_changelogs.py` performs the rename. The entry read "verified — no such handling exists".
>   · `[P1]` the umbrella's per-verb capability table — **the actionable half SHIPPED 2026-08-04** (`431b82d`):
>     the table, the refusal naming the engines that do implement a verb, and capability-aware `--help`.
>     What is left is the optional-in-spec-vocabulary design question the entry itself gates on a customer.
>   · `[P2]` privacy `Health`/`Motion` — **SHIPPED 2026-08-04 as `privacy/2`**, with read/write direction.
>
> STILL OPEN, and these were re-checked against the code:
>   · `[P1]` **value provenance** — filed below at last; two items now wait on it (see the note there).
>   · `[P3]` blame-tracked `Unknown` (needs `candor verify` as a foundation)
>   · `[gate]` structure-delta regression gate — DESIGNED, awaiting a go/no-go
>   · `[adoption]` embeddable fingerprint badge
>   · ~~`[P2]` candor-ts self-gate (no `.candor/policy`, no self-gate step in its CI)~~ — **CLOSED
>     2026-08-13** (`4356162`): `.candor/policy` (`deny Net Db Ipc`), `ci/self-gate.sh`, a CI step, and
>     a `.candor/.gitignore` so the policy is actually tracked (the root ignores `.candor/` wholesale,
>     which would have left CI reading a policy that exists only on the author's machine). Two halves,
>     as candor-java does it, because a policy file cannot say "deny Exec everywhere except these
>     three": the engine under the policy, plus an assertion that the Exec-performing units are exactly
>     the declared self-invocation list — new Exec fails, and so does a declared entry that stops
>     performing Exec. Falsified in all three directions.
>     **What it found first was itself**: `candor-ts . --policy …` analyses ONE file (Cases.ts, the test
>     fixture), because the engine is `.mjs` and that needs `--allow-js` — 38 functions, none of them
>     the engine, and a verdict that reads like an answer. The same shape as the axios finding closed
>     the same day, wearing our own name.
>     **candor-swift: CORRECTED and also closed** (`af7de30`). My first reading — "no `.candor/policy`
>     either, same gap" — was wrong: candor-swift already self-gated, two halves, the same split java uses.
>     What it lacked was a DECLARED policy; the rule lived in a `printf` inside `ci.yml`, so
>     `candor-swift .` in a checkout applied nothing and the boundary existed only in a step nobody
>     reads. Now `.candor/policy` + a `.candor/.gitignore` (the root ignores `.candor/` wholesale in
>     both repos — without it the tracked policy exists only on the author's machine, which is the same
>     failure one layer down). Falsified: an unreadable policy path exits 2 "gate NOT enforced".
>     **All four engines now declare a tracked boundary.**
>
>     · ~~`[P3]` the remaining coarseness, swift only — half (1) excludes *all of* `main.swift`~~ —
>       **CLOSED 2026-08-13** (`023d1f0`), candor-ts's shape ported. The whole engine is now scanned
>       with no file excluded, under `deny Net Db`, plus an assertion that the Exec/Ipc units are
>       exactly the four declared ones. **The policy string got weaker and the gate got stronger** —
>       a policy is only as strong as the scope it is actually evaluated over. MEASURED rather than
>       argued: with an unexplained `Process()` appended to `main.swift`, the new gate exits 1 naming
>       it, and BOTH halves of the old arrangement exit 0.
>
>       Standing lesson, and it generalises past this repo: **an exclusion that buys a green is worth
>       auditing for what it stopped asking.** The excluded file was the one place a subprocess was
>       expected, which is exactly why nobody looked at it again — and it was also the only file where
>       a new one could hide.
>
>     · **SWEPT ALL FOUR ENGINES 2026-08-14 — the vein was in java too** (`e860460`). Its half (1)
>       deleted the whole `io/poly/candor/verify` PACKAGE before scanning, so every class in it sat
>       outside the Exec gate while half (2) asked only about Net/Db/Ipc. Ported to the same shape:
>       whole tool under `deny Net Db Ipc`, Exec declared as exactly `Candor.main` +
>       `verify.VerifyCli.main` (measured — those two are the only Exec in the tree). Decisive
>       falsification: drop `VerifyCli.main` and the gate names it, a method the old arrangement
>       *structurally could not see*. **candor-rust needed nothing** — it scans all four workspace
>       members under `deny Net Db Exec Ipc` with no exemption at all, which was already the strongest
>       form. So: four engines, four tracked policies, and no engine now excludes a file or package
>       from its own gate.
>   · ~~`[P2]` each engine's AGENTS.md should point at the umbrella (none mentions it)~~ — **CLOSED
>     2026-08-13**, all five, with each repo's embedded-copy drift gate re-synced in the same commit
>     (rust ×2 crates, java's jar resource, swift's generated `AgentsDoc.swift`). candor-rust and
>     candor-ts also gained the candor-spec pointer they were missing.
>   · publish-side release-script coverage — real open work currently hidden under a `[FIXED]` heading
>     below: `cargo publish`, the npm OIDC tag, `gh release create` and the Homebrew tap are exercised
>     only by a real release, and neither a dry-run mode nor stubs exist.
> Plus, from the verify entry: promoting candor-rust's or candor-swift's dynamic oracle from a CI harness
> to a user-facing verb — a new feature, not productionization.

> **RE-AUDITED 2026-08-14, method as above: heading, then the artifact, then the code.** Four headings
> were stale — the two I closed on 2026-08-13 (`AGENTS.md`→umbrella, candor-ts self-gate) still read
> `[P2]` in their own entries while the summary above said CLOSED, which is the same drift this note
> documents, committed by the person documenting it. Also re-headed: the `--agents` pipe entry (its open
> half swept clean across all four engines) and the rust-analyzer entry (verified: `rust-toolchain` lists
> the component, with the reasoning inline).
>
> Two entries were re-measured rather than re-read, and both are still real:
>   · `path <fn> <typo'd Effect>` still exits **0** with a confident negative — four-way, wants a rung.
>   · the temp-fixture leak is **46,919** dirs, and candor-ts's `project()` is now named as the dominant
>     single cause (~7,300 and rising, ~1,300 per suite run) — one function, self-contained.
>
> **Still open and genuinely small** (costed, so the next session does not re-derive it):
>   · `[P3]` the clippy-is-advisory line in candor-rust/AGENTS.md — confirmed absent; one paragraph.
>   · `[P2]` candor-ts `project()` cleanup — one function, removes most of the leak's growth.
> **Small-looking but is not**: `path <typo'd Effect>` (four-way rung: spec + PART + four engines).
> **Needs a closer read before costing**: `[P2]` PUSH THE ENGINES BEFORE THE SPEC — `conformance.yml`
> already pins the suite to the latest released spec TAG, which may or may not cover the ordering failure
> the entry measured on 2026-08-10; the entry and the workflow disagree and I did not resolve which is
> right.
> **Needs Tom, not effort**: the structure-delta gate go/no-go, the two ⟨0.28⟩ four-way spec questions,
> and the umbrella's two-tags-per-release decision.



- **[THE PLAN — agreed with Tom 2026-08-15. Phases run in order; D waits for A–C.]**

  **PHASE A — close what is live and wrong. No further release until A1–A6.** All from the max review of
  this session's work; most are defects the session itself introduced.
  **A1–A8 DONE 2026-08-15** (umbrella `b927a41`, `e9d53c0`, `479a7c7`; spec `27fb3f0`). **A9 DONE** (candor-ts `8a30946`).
  Two defects surfaced only by fixing the harness, both now closed: a dead mentions-scan in `spec-bump.sh`
  printed its green "no remaining mentions" ABOVE the probe's ✘ (probe runs first and returns now), and
  the extractor written to replace the run-to-EOF awk range reintroduced run-to-EOF in its own END block
  — caught on the first run by the negative probe that ships beside it. release-test: 62 → 70 assertions.
  · ~~A1~~ `SKIP_LICENSED` licenses `conformance/README.md`, which `must_ledger.py:209` READS — a FALSE
    GREEN in the conformance-reuse gate, shipped today while arguing that direction could only cost a
    wasted run. Not user-facing (`release-preflight.sh` is not installed by brew or npm), so no release
    is needed — but it is our release gate certifying a floor over an unre-run suite.
  · ~~A2~~ `note` is undefined in `release-stage.sh` (0 definitions, called twice) — the operator gets a raw
    shell error in place of the remedy, at the moment the remedy matters.
  · ~~A3~~ the `candor-java/jbang-catalog.json` entry in `SKIP_LICENSED` is dead: `git -C <repo> diff` emits
    repo-relative paths. Fails safe; costs a redundant run every release.
  · ~~A4~~ the CI wait: FALSE RED at the timeout boundary (a repo going green on the last poll is reported
    failed AND green), `fail` double-counted, the 20-minute bound is PER REPO (7 × 20 = 140), and the
    only line explaining the wait goes into `release.sh`'s redirect — a silent terminal for up to hours.
  · ~~A5~~ the stamp records SHAs from a run over a DIRTY tree; the read path refuses dirty, the write path
    does not, so reuse can assert a green for a state the suite never ran against.
  · ~~A6~~ the `Cargo.lock` step calls `ok` on a no-op, breaking release-stage's documented idempotency —
    the exact failure `sub()`'s SAME branch exists to prevent.
  · ~~A7~~ `release-test` cannot reach the Cargo.lock arm (empty fixture workspace) or the spec-bump liveness
    probe (every row passes `--decls-only`, which returns before it) — which is why A2 and A6 survived a
    green harness. A staged site absent from the fixture is an untested site.
  · ~~A8~~ `release.sh`'s step-7 remedy still says "wait for CI before the re-run", which A4 makes false —
    and `release-test` anchors an awk RANGE on that sentence, so correcting it runs the range to EOF and
    feeds the rest of the script into `eval "cat <<EOF"`. Fix the harness first, then the text.
  · ~~A9~~ the ts parallel driver: unbounded EAGAIN spin, no `--parallel` validation (`1e9` reaches
    `Array.from`), and children orphaned on a SIGTERM to the parent. Measured 4 orphans + 69 leaked
    fixture trees, 0/0 after. Two things the review had not seen: the driver's relay had NO EAGAIN arm
    (worse than a spin — the throw killed the parent mid-dump), and the genuine unbounded spin was in
    `contract.mjs`, the `--agents` path an AGENT reads. **SIGTERM alone does not kill a shard** — a JS
    listener replaces the die-disposition and cannot dispatch from 175 blocks of synchronous scans, so
    scratch.mjs's leak-sweeper is what makes the leaking process unkillable, `--parallel` or not.

  **PHASE B — ONE ⟨0.29⟩ rung (Tom's call: single rung), in this order.**
  · ~~**B0**~~ **DONE 2026-08-16** — four-way, `candor-ts 3ad0d8e`+, `candor-rust`, `candor-swift`, spec
    PART 47 extended. The MCP/LSP half and the advisory-verb half both closed; one shared helper per
    engine (`wholePolicyUnanswerable` / `whole_policy_refusals` / `wholePolicyRefusals`) so the next
    report route inherits the rule. **A candor-swift TEST was pinning that engine's divergence from
    the reference** (`ok` present for an `allow`-only policy, where java has always withheld it) —
    that is how the divergence survived. Original scope, for the record:
    **B0 (was: jumps the queue — a LIVE false all-clear on the agent channel).** SPEC §3.1's
    answerability MUST binds every route reading a §2 report, and `candor-ts`'s MCP and LSP servers
    violate it. `mcp.mjs:408` passes the WHOLE policy to `evaluatePolicy`; the CLI sibling at
    `query.mjs:2104` strips `forbid`/`allow` with a comment saying handing them to the matcher "would be
    the very evaluation-on-partial-evidence they are unanswerable FOR". **Measured** driving the real
    `parsePolicy`/`evaluatePolicy`: with no callgraph sidecar (what `loadCallgraph` returns for a
    hand-copied `report.json`) → `violations: 0`, `unevaluated: 0` — a silent green; with a sidecar → it
    EVALUATES the rule and returns an AS-EFF-009 violation. Both outcomes the MUST forbids, no disclosure
    either way. `lsp.mjs:393` is the same shape and reaches VS Code and JetBrains. `bin/candor:1648`
    routes `candor mcp` to candor-ts for **any engine's** report, so this is the family's agent gate.
    Sibling route: the CLI got the ⟨0.24⟩ rule, the two servers did not.
    Same audit: `fix-gate`/`unverified` drop `forbid` silently in rust (`fix.rs:583`, prints
    `ok:true` + "no boundary crossings ✓"), swift (`FixCLI.swift:1299`) and ts; java alone discloses and
    withholds `ok`. Four-way divergence on a report route with no row. **`allow` is `forbid`'s untouched
    sibling** — same MUST at §3.1, and NO conformance row anywhere writes an `allow` rule into a `.pol`
    file, which is precisely the state PART 47 was written to fix.
  · ~~**B0b**~~ **PARTLY DONE 2026-08-16, and the review's numbers did NOT reproduce.** What I measured
    on this machine, and the correction matters more than the fix:
    · **The `--agents` claim was wrong here.** The review reported java `rc=0` silent truncation, swift
      141, rust 101, ts 0-with-a-diagnostic. Into a reader that CLOSES, all four exit 0 silently — macOS
      pipe buffers grow past the 17–24 KiB payloads, so EPIPE never fires and nothing is truncated. Into
      a reader that STALLS holding the pipe open, **all four HANG with no diagnostic, uniformly.** That
      is the residual candor-ts's CHANGELOG already states: a BLOCKING write cannot be bounded from user
      code without going async, and nothing on the `--agents` path makes fd 1 non-blocking. Four-way and
      unresolved — a real item, but not the one that was filed, and not engine-specific.
    · **The `scan.mjs` claim was right and worse than stated. FIXED.** `--json --policy` over 400 files:
      95281 bytes to a file and valid JSON; **65536 through a pipe and a JSONDecodeError**. Now through a
      shared `writeStdoutSync()`, along with `printAgents` and all twelve `emit` sites in query.mjs.
      Rows compare a pipe against a real file. **rust (106781) and swift (116222) are byte-identical
      file-vs-pipe — clean siblings, so this is Node's async stdout, not a family defect.**
    · **java's silent truncation CONFIRMED AND FIXED 2026-08-16.** Shrinking the PIPE (`F_SETPIPE_SZ`
      to 4096) rather than growing the payload is what made it measurable: inside Linux, with a reader
      that closes mid-write, candor-java exited **0 with an EMPTY stderr** while candor-ts on the
      identical setup reported "cut short at 4096 of 24110 bytes". `PrintStream` swallows `IOException`
      and there were ZERO `checkError` calls in `src/main`. Fixed with ONE check at exit — the error
      flag LATCHES, so a shutdown hook covers all ~148 `System.out` sites, and guarding them
      individually is how 147 would have stayed unguarded. Exit 0 kept (`| head` must not be a failure).
      Verified to fire on a bulk report into a closing pipe and stay silent on the same scan to a file.
  · ~~**B0c**~~ **MOSTLY DONE 2026-08-16** (umbrella `2a5fdd8`, candor-rust, candor-ts).
    · **The stager guarded FIVE of the SEVEN repos it edits** — candor-spec and the umbrella, the two a
      release author is most likely to have open, were the two uncovered. Widened; the fixture now
      carries candor-spec as a REAL repo (it was a loose directory, so the changelog helper's
      floor-shaped-heading branch — which exists only for candor-spec — could never be driven through
      the stager). The dirty-tree row now dirties each of three repos and requires the refusal to NAME
      the repo: with the old guard the `candor` row PASSED, because the run failed for an unrelated
      reason and "it refused" was true while "the guard covers it" was not.
    · **`release-preflight.sh` now has executable rows** — five, with `gh` stubbed so [10] is reachable
      without auth or a network. Teeth-verified against reverts of the A3 fix. release-test: 75 → 82.
    · **Both orphaning harnesses closed.** `test-watch.mjs`: 1 orphan measured without a handler, 0
      with. `candor-rust/tests/integration.sh`: zero traps in the whole file, ~180s window.
    · **ALL THREE RESIDUALS CLOSED 2026-08-16.** preflight [11] has six rows behind a stubbed `run.sh`
      (dirty tree writes no stamp, a `conformance/` change defeats the licence, plus two controls);
      `test.mjs`'s private write loop is DELETED in favour of the shared one the contract row already
      drives; `scratch.mjs` covers all eight harnesses (59 sites) with `keepOnFailure` wired in three.
      release-test: 82 → 88.
  · ~~**B0d**~~ **DONE 2026-08-16, and the filing was HALF WRONG.** It said rust/java print the rule while
    ts/swift print a count. Measured across all four first: rust, java AND ts printed it — **candor-swift
    was the only engine that did not**, so a two-engine item was a one-engine item. The rule now rides
    `why` ITSELF rather than a caller's prefix, because candor-ts has SIX printers of those rows and THREE
    print `why` alone (the advisory disclosure, the LSP fix path, and the MCP error — the agent channel),
    where a predicate-style message would have read as a fragment and lost the rule entirely. `allow`
    moved with `forbid`. PART 47's row is strengthened from "the word `forbid` appears" to the RULE TEXT,
    and falsifies. Original statement:
  · **B0d PART 47's remaining gap, deliberately not closed today:** the refusal must "name the rule", and
    rust/java print the rule text while ts/swift print a count. The row asserts only that the word
    `forbid` appears, and says so. Pinning the stronger form needs two engines changed first.

  · **B1 — IN PROGRESS 2026-08-16. Decision made (rung 2 of 4: DISCLOSE + PEEK), see
    candor-spec/FILE-SET-DESIGN.md §5.** State by engine:
    · **candor-rust — BOTH HALVES DONE.** `excluded` (classes + counts + reasons, always emitted) and
      the PEEK (`outOfScope`), implemented as a RECURSIVE `scan_one` with the file selection inverted so
      "same classifier, different file set" is true by construction. Verdict unmoved. Three bounds
      pinned: `deny Exec` finds it, `deny Net` on the same tree says nothing, no policy says nothing and
      OMITS the key. 192 tests in candor-scan, integration 150, clippy clean.
    · **candor-ts — BOTH HALVES DONE.** `excluded` plus the peek, the latter as a child `scan.mjs` over
      a generated tsconfig (the same-binary equivalent of rust's recursion, since this engine is a script
      not a callable function), placed above the report write because the gate block runs after the
      envelope is serialised. Three bounds verified. A peek that cannot run leaves `[]` and never fails
      the gate.
    · **candor-swift — BOTH HALVES DONE.** `excluded` (`manifest`, `harness-target`, `test-source`,
      `outside-the-target-closure`, `build-output`) plus the peek as a CHILD `candor-swift` over the
      parent's own excluded list — this engine's scan is top-level code, not a callable function, so the
      "same classifier" guarantee comes from the same BINARY. The child is handed the LIST rather than
      re-deriving the rules, because `--target` prunes sources far below the walk. Three bounds pinned +
      the control + the ⟨0.21⟩ mirror. Two defects caught in the writing, both by this repo's own guards:
      `waitUntilExit()` (forbidden here — it would have hung every Linux scan with a policy), and a loc
      match comparing the child's RELATIVE path against the parent's ABSOLUTE one, which missed every
      time and silently fell back to the class `excluded`. Self-gate spawn inventory 2 → 3, justified.
    · **candor-java — BOTH HALVES DONE, and its exclusion really is a different kind.** The other three
      make a SCOPE decision among files they can read; this one reads BYTECODE. So `source-without-class`
      is `peeked:false` + a NUDGE (how many sources have no class, how many classes there were, what to
      scan instead), and the peek's real target is `archive-under-the-scan-root` — a jar under the scan
      root is bytecode it reads perfectly well that a `.class`-filtering walk never opens
      (`build/libs/app.jar` beside `build/classes` is the ordinary shape). A recursive `runScan` ON A
      THREAD, because `resetState()` + a thread-local ctx means peeking in-line would destroy the
      analysis whose report it joins. Three java-only rows the others did not need: a qual the gate
      ALREADY judged is never an out-of-scope finding (the same code twice in one repo root); a REFUSED
      policy leaves the key absent, not `[]` (§3.1 answerability binds every producer, not just the
      gate); and the policy parse rides the peek's thread with stderr silenced, because `parsePolicy`
      fills a thread-local rule list AND prints.
    · **`peeked` — THE FIELD THE PORT FORCED, added to all four.** An empty `outOfScope` claims "I read
      the excluded files and none held a denied effect", and it may claim that only about classes it
      actually read. rust and ts are `true` throughout (their peek is the exact complement of their
      scan), which is why the gap was invisible from those two; java cannot read an uncompiled `.java`
      and swift will not read `.build/`. Without it their `[]` certifies files nobody opened — ⟨0.26⟩'s
      partial-manifest failure. **Durable: a flag that is constant in the first two engines you build is
      not thereby a property of the rung.**
    · **N3 IS STILL NOT COVERED, in any of the four**, and now says so in the code: a shell script running
      `curl | sh` under the scan root is invisible. Recording it costs the block its bound
      (FILE-SET-DESIGN §3). Named here so it is a decision rather than a discovery.
    · **THE FIXTURE TRAP, which cost time in ALL FOUR ports.** To test the policy-bound (`deny Net` must
      say nothing about an out-of-scope `Exec`) the excluded file must perform Exec and NOTHING ELSE. The
      obvious fixture — `Command::new("curl")` / `execSync("curl http://…")` / `Runtime.exec("curl …")` —
      is classified Net AS WELL AS Exec, so the `deny Net` row matches legitimately and reads as a broken
      bound. An argument-free `ls` isolates it. Four times now the fixture could not test what it claimed.
    · **THE CLAUSE AND THE PART ARE IN** (candor-spec `c12c349`): SPEC §2 carries `excluded`/`outOfScope`
      + the never-a-second-path rule, and **PART 48** pins all four. Its rows are the BOUNDS, not the
      finding — policy-scoped, policy-bounded, verdict-unmoved, and the `[]` CONTROL — because a part
      asserting only "the warning fires" passes against an engine that reports every file it ever skipped.
      **Falsified five ways on the real harness**, each with its own diagnosis. Two rulings worth carrying
      forward: `class` tokens are ENGINE-CHOSEN (a shared enumeration would force one engine to file its
      exclusion under another's name), and the TWIN arm is how "never a second analysis path" became
      observable at all — no row can read which code path ran, so each engine is asked the same question
      twice (peek vs. ordinary scan of the same code) and the two must agree. That turned a third
      `unenforced` ledger entry into an exercised one.
    · **REMAINING FOR B1: nothing but the RELEASE.** The floor moves at release, not here — every engine
      declaring 0.29, `bin/release.sh`, then `release-verify`. Ship it with whatever else rides 0.29.
    Original statement of the defect:
  · **B1 RE-MEASURED 2026-08-21 AFTER ⟨0.29⟩+⟨0.30⟩ — STILL EXIT 0, AND THE REASON IS NOW EXACT.**
    ⟨0.29⟩ made it DISCLOSED (a stderr line naming the ratio, and an `excluded` entry); ⟨0.30⟩ made a
    non-empty `outOfScope` INCOMPLETE at exit 2. Neither closes it, and the measurement says why:

        excluded:   [{class: "source-without-class", count: 1, peeked: false}]
        outOfScope: []            <- EMPTY, so the ⟨0.30⟩ rule cannot fire
        verdict:    exit 0        <- green, over Runtime.exec("curl http://x | sh")

    **The fail-closed rule is keyed on what the peek FOUND, never on what it admits it COULD NOT READ.**
    candor-java reads bytecode, so the peek is structurally incapable of opening a `.java` source; it
    therefore finds nothing, and nothing-found is byte-identical to clean. The exclusion class says
    `peeked: false` — the engine stating plainly that it did not read these files — and that flag
    carries NO verdict consequence anywhere.

    This is [[candor-unanswerable-key]]'s THREE-ROW RULE applied to the file set: absence under a key
    licenses a claim only if the key COULD have had a body. `peeked: false` is exactly the case where it
    could not.

    **THE SHAPE OF THE FIX, and it is a RUNG not a patch:** an exclusion class with `peeked: false`
    should make the verdict INCOMPLETE (exit 2), for the same reason ⟨0.30⟩ ruled a non-empty
    `outOfScope` does. That turns GREEN GATES RED, which is Tom's ruling to make — ⟨0.30⟩'s equivalent
    was. Constraint from the `net-partner` attempt: whatever this becomes must be reachable identically
    on `scan --policy` and `gate --report`, or §3.1 route equality breaks. `excluded` IS carried in the
    report, so unlike `net-partner` both routes can see it — that is what makes this one tractable.

    **The same question in a second costume** is the execa/axios item below (`deny Exec` green over 16
    unjudged library functions, `outside-the-tsconfig-program`). One ruling should settle both.

    (original filing) `unanalyzed` covers files that FAILED to parse, not files never
    CONSIDERED. `deny Exec` → `policy ✓` over a repo containing `execSync("curl | sh")`; `build.rs`
    running `Command::new("curl")` invisible. **NOW MEASURED IN ALL FOUR (java arm done 2026-08-15).**
    java, pointed at a REPO ROOT (not a classes dir) under `deny Exec`: exit 0, `candor-java: no
    violations`, `analyzed {count: 3}`, **`unanalyzed` absent entirely** — over a tree holding
    `src/com/x/Deploy.java` calling `Runtime.exec("curl … | sh")` (present, never compiled, so no class
    exists) and `scripts/deploy.sh` doing the same. Two files the engine never considered, and the whole
    report says only that 3 things were analyzed. The ⟨0.21⟩ manifest reads as a completeness claim and
    is answering a narrower question — "of the files I chose to open, how many failed" — so the shape is
    the same in java as in the other three, with no advisory to soften it. Highest-value soundness item
    outstanding.
  · ~~**B2**~~ **DONE 2026-08-16, four-way + SPEC §6.2 + conformance PART 49.** Three rulings pinned, each
    of which could have gone the other way: `A -> A` implicit; the walk STOPS at a permitted scope (a
    permitted callee's own deps answer to the rules about IT — descending would demand the transitive
    closure of everything you permit, the same enumeration-that-rots one level down); zero-match measured
    on `from` ALONE, unlike `forbid`'s either-endpoint count. AS-EFF-009 reused rather than a code minted.
    **THE RUNG REINTRODUCED THE DEFECT IT EXISTS TO REMOVE, TWICE**: candor-java and candor-rust each
    DISCLOSED an `only` rule as unanswerable from a report and then EVALUATED it anyway, printing a
    violation beside their own statement that it could not be evaluated. Same shape both times — the
    removal site sits ~50 lines from where the kind is added, and only the one you are editing gets
    updated. **PART 49 was VACUOUS TWICE before it caught the rust one**: an `only`-only policy makes every
    engine refuse before evaluating, and a wholly pure fixture leaves no call graph to walk, so "no
    AS-EFF-009 was drawn" was true however broken the removal was. It needed an answerable `deny` beside
    the rule AND an effect in the tree. Its checker records that the **ts arm still cannot fail** (that
    engine passes an empty call graph on the report route) — four MATCHes are not four equally strong
    arms. The nightly rust engine REFUSES `only` (exit 2) rather than running green. Original statement:
  · B2 the PERMISSION FORM, `only <A> -> <B>…` — A may depend on A and the listed scopes, nothing else.
    **The design argument: `forbid` FAILS OPEN (a dependency you forgot to prohibit is silently
    permitted); `only` FAILS SAFE (one you forgot to permit is a loud violation).** That inverts the
    usual allowlist hazard and makes `only` the form to RECOMMEND for leaf protection, not merely offer.
    `A → A` implicitly permitted, else the segment-prefix rule makes it unusable (measured: the natural
    `forbid a.b.model -> a.b` self-fires at 58). Scan-route only, refused on report routes — EXTENDS
    PART 47 rather than needing a new part. Zero-match must disclose under ⟨0.27⟩.
  · ~~**B3**~~ **DONE 2026-08-16, four-way + SPEC §2 + conformance PART 50 — and it was a CARDINAL SIN,
    not a wire gap.** The filing was right that java and ts were unmeasured. Measured: rust and swift
    publish per-fn `incomplete`; **ts and java computed it internally and published nothing**, so §2's
    chained-JOIN clause ("a join that drops `incomplete` lets a benign literal in the consumer certify
    what the dependency declared uncertifiable") described a join that could not happen. THE HARM, across
    a boundary: a dep whose `Fs` path is a runtime value said nothing; a consumer that ALSO wrote one
    allowed literal joined `paths:["/tmp/lit"]` with no marker, and **`allow Fs /tmp/lit` answered
    `policy ✓`** where rust/swift charge AS-EFF-008 on identical code. In ONE package all four already
    fail closed, which is why nothing local had caught it and why PART 50's row is the CHAINED VERDICT.
    **`Net` was already safe, and that is the tell** — ⟨0.20⟩ gave it a wire form of its own
    (`netClass ∋ unknown-host`), so the one effect anyone had thought about at the boundary was covered
    while Fs/Exec/Db had nothing: the rule was written for the instance that was measured. ts's decision
    to keep the field internal rested on a comment asserting "java/rust keep it out of the report too",
    **which was false for rust and had been false since the field existed**. Original statement:
  · B3 #97 — §2 stated over the INSTANCE rather than the CONDITION. Four-way row required; **java and ts
    are UNMEASURED on `incomplete`, not clean.**
  One rung because all three are §2/§6.2, they share a floor bump, a conformance cycle and a release —
  and this session measured that every release cycle spends its own defect budget.

  **PHASE C — adoption, after B2 so we teach the fail-safe form.**
  · C1 teach the LAYERING gate in the shipped AGENTS.md — today it is taught as a query verb while the
    effects half is taught as a gate (23 mentions vs 0 worked examples), so every adopting agent inherits
    the omission we just found in ourselves. With `only` recommended and the enumeration caveat stated.
  · C2 self-application section in the four engines + candor-spec, with the question attached to ADDING
    A CAPABILITY rather than to memory — the thing that would have caught the layering half.
  · C3 layering policies for rust/ts/swift (java landed 2026-08-15).

  **PHASE D — Java design work. WAITS for A–C (Tom's call).** Fable's Stage 0 oracle (one command +
  report byte-diff) and a LOC/complexity RATCHET first — nothing measures file size today, which is how
  `Candor.java` reached 5,678 lines and `main()` 857 unremarked. Then PIT (it attacks the vacuous-control
  class directly, which is this session's demonstrated enemy), PMD+CPD (CPD finds the sibling-route
  duplication mechanically), ArchUnit, SpotBugs, OpenRewrite — all as ratchets against a recorded
  baseline, never thresholds, or they become noise people learn to ignore. Then Stages 1–6.

- **[P1 — spec/product, found 2026-08-15 by pointing the architecture gate at candor for the first time]
  `forbid A -> B` can state a PROHIBITION but not a PERMISSION, so "this package is a leaf" is
  inexpressible — and the workaround ROTS SILENTLY.** Writing candor-java's own layering policy (the
  first time the family's architecture gate has been aimed at the family) hit this immediately. The
  natural spelling of "the typed model must not reach back into the engine" is
  `forbid io.poly.candor.model -> io.poly.candor` — which SELF-FIRES at 58 violations, because the
  scope is a prefix and `model` sits under it. The only workaround is to enumerate the classes it must
  not touch, which is an ALLOWLIST in the unsafe direction: **a new engine class is not covered by the
  list, and nothing says so.** That is verbatim the hazard [[candor-denylist-over-allowlist]] exists to
  prevent, present in the POLICY LANGUAGE rather than in a classifier.

  Candidate spellings, none evaluated yet: a `only <A> -> <B>…` permission rule; an exclusion on the
  scope (`forbid X -> Y except Z`); or making a prefix scope non-self-matching, which would change the
  meaning of existing rules and needs a rung. **The value of the finding is independent of the fix:**
  every adopter protecting a leaf package today is writing a list that rots the same way, and nothing
  tells them. Four engines, so it wants a rung and a conformance PART.

  How it was missed until now: `containment` is exercised in smoke tests as a query VERB, and
  candor-java's `.candor/policy` was effects-only. The product's two halves were taught and gated
  asymmetrically — see the AGENTS.md work alongside this entry.

- **[MEASURED AND REJECTED 2026-08-15 — do not re-attempt without reading this] Parallelising the
  conformance suite. It works, it is 4.4×, and it is WRONG.** Built as a two-lane runner: 8 expensive
  parts hoisted into a parallel lane, the other 39 left in one ordered sequential run. **331s → 76s.**
  Every one of the 47 declared parts present, every verdict MATCH, the runner's own predicate green.

  **The skip-ratchet caught it.** PART 40's state×verb matrix — in the SEQUENTIAL lane — silently lost
  its per-engine tallies, because parts it depends on were no longer upstream of it. Four tally lines in
  the sequential log, none in the combined one. Coverage quietly reduced, at speed, with every verdict
  saying MATCH. A gate built to detect an un-shipped RUNG is the only thing that saw it.

  **THE MEASUREMENT ERROR IS THE DURABLE PART, and it is subtle enough to make again.** Independence was
  established by running each part alone: 27 produced their suite verdict, 15 died on `set -u`
  (part.sh's INCONCLUSIVE guard), 4 diverged alone, 1 exited 1. That measurement answers *"does part X
  work alone?"* — but the question that licenses hoisting X is *"does REMOVING X change any other
  part?"* Those are different questions. The first is O(n) and feels sufficient; the second is O(n²)
  over 47 parts, and nothing cheaper than it can authorise the split.

  Also measured, so the next attempt starts informed: sequential suite **331s** (an earlier ">600s"
  claim was a tool TIMEOUT misreported as data); 20 of 47 parts are non-hermetic; the dependents cannot
  run as a group (they need the unaddressable ride-along sections 1–6, 11, 12, 17, not each other); the
  expensive parts are the independent-looking ones (61s, 35s, 25s, 22s…) so the theoretical prize is
  real. **The prerequisite is making those 20 parts hermetic** — which would also fix `part.sh` for the
  43% of parts it currently cannot run alone, a daily DX loss. That is the job; parallelism is a
  consequence of it, not a substitute.

  **And the cheaper win is elsewhere:** conformance ran SIX times in the 0.28.1 release, at most two
  over changed inputs. Skipping provably-redundant runs saves ~22 min/release against parallelism's
  ~21 min, with no exposure — a too-conservative skip costs five minutes, a false green costs the
  contract.

- **[CLOSED 2026-08-13 — candor-ts + conformance PART 46] A CALLER OF A BODY-LESS LOCAL DECLARATION READ
  PURE — the corpus round's F1, a cardinal sin, and it had never been written down anywhere but a memory
  file.** `localName` mints a unit for any declaration it can name without asking whether it has a BODY.
  An ambient `declare function`, any member of a local `.d.ts`, an `abstract` member no subclass
  overrides — each got a unit, the call site edged the caller to it, the unit was EMPTY, so the caller
  unioned nothing and was certified pure. `deny Unknown` exited **0** where rust, java and swift all exit
  1 on identical code. On `axios`, whose entire report is 54 `index.d.ts` declarations while its 61 `.js`
  files are never analyzed, the report read `analyzed.count: 54` + `functions: []` + no `unanalyzed` —
  ⟨0.24⟩ **row 2**, the row that tells a consumer to believe it and not hedge — and stderr said "wrote 0
  effectful functions", so BOTH channels read as a clean bill of health. Now 52 of 52 Unknown on both.

  · **THE SIBLING ROUTE, for the fourth recorded time.** The identical shape crossing a PACKAGE boundary
    has been pinned since the scan-boundary work (PART 21; candor-ts's own `boundary:` suite has four
    rows on a chained dep's interface members, abstract members and function-valued property
    signatures). Every one asks about a DEPENDENCY. Nobody asked it of the project's own source. The new
    fixtures sit directly beneath the old ones so the pairing is visible.
  · **Ruled four-way, no spec version moved.** §3's honesty invariant already required the disclosure and
    §4 already defines `native:` as "a boundary to code the engine cannot analyse"; what was missing was
    a ROW. The engines legitimately differ on WHERE the charge lands — java on the DECLARATION unit,
    rust/swift at the EDGE — so PART 46 asserts on the CALLER's transitive set, which is what a gate
    reads, and not on the reason string (§4 makes the class per-language and best-effort). candor-ts
    takes java's shape because it already mints the unit and already forms the edge.
  · **The over-charge control is most of the value, and it is measured.** Charge only where NO LOCAL BODY
    ANSWERS: a base member with a local bodied override is already resolved by the class-CHA. With that
    condition, zod **+0** and hono **+18 → +9**; without it, hono's `EventProcessor` (six abstracts,
    three local subclasses) and zod's `ZodType._parse` get charged. The nine hono flips that remain are
    all true positives (`Deno.mkdir`/`writeFile` Fs, `Deno.upgradeWebSocket`/`FetcherLike.fetch` Net).
    The other trap is the OVERLOAD SET, where N body-less signatures precede the implementation under one
    unit name — the marker mirrors `fns.set`'s last-write-wins or every overloaded function in every
    project becomes unanalysable. Both are fixtures; PART 46 carries the control in all four arms.
  · **Calibrated:** PART 46 re-run with the fix reverted reddens on ts alone.
  · **RESIDUAL, open and deliberately not folded in:** this closes the *"candor cannot see"* channel, not
    the blindness. `deny Unknown` on axios is exit 1 now; **`deny Net` is still exit 0**, because axios's
    effects live in the 61 `.js` files the scan never reads (it read 2). Whether a TS scan whose analyzed
    set is *entirely* declarations should say something stronger than per-function Unknown — an
    `unanalyzed` entry, or a ⟨0.24⟩-row question — is a real open design question and belongs to whoever
    picks up the `.js`-implementation half.

- **[CLOSED 2026-08-14 — the open half swept clean] `--agents` truncated its own contract on a PIPE, and the
  general question it raises is not.** `printAgents` wrote asynchronously and scan.mjs called
  `process.exit(0)` on the next line: **8170 of 23121 characters**, cut mid-sentence, exit 0, nothing on
  stderr. An agent piping `candor-ts --agents` into its context read a third of its own instructions and
  could not tell. Fixed in the printer with a synchronous `fs.writeSync(1, …)` loop, so the next caller
  inherits it, and pinned by two rows that assert the byte count through a pipe. Note the shape: the
  function's header claimed one shared implementation "can never diverge within an install" — and it was
  the CALLERS that diverged (query.mjs drains on the way out, scan.mjs exits), inside the very function
  written to prevent divergence. **The open half — SWEPT 2026-08-13, CLEAN.** All four engines ×
  `--agents`/`--help`/`--version`, pipe byte-count vs file byte-count, 18 cells, zero divergence: rust
  16422/4600/74 + query 16423/5284/76, java 19506/4734/84, swift 21902/6000/116, ts (post-fix) both
  binaries 23384/3093/70. The defect was Node-specific — asynchronous stdout on a pipe plus
  `process.exit` — and the compiled engines flush on the way out.

  **But note WHY the rest of ts is clean, because it is not by construction:** a pipe buffer is 64 KB,
  and only the 23 KB contract is big enough to be caught mid-write. The nine remaining print-then-exit
  sites in scan.mjs/query.mjs emit 3–6 KB of usage/version text, so they fit the buffer and survive by
  SIZE. Any of them that grows past 64 KB truncates silently at exit 0. The printer they share is now
  synchronous, so the durable fix is to route new bulk output through it rather than through
  `console.log` — cheap to honour, and the failure mode if it is not is invisible.

- **[SHIPPED 2026-08-04 — research] Mechanise the formal model in Lean — the MODEL, explicitly not the
  code.** Raised by Tom. `candor-spec/lean/`: **75 tier-A theorems with no axiom dependencies**, 7 bridge
  lemmas, a 147 400-row differential against `reference/policy_model.py`, and CI. Transcribed: §1's lattice
  and policy verbs, §2's transitive rule as a least fixpoint, §3's honesty invariant H, §4's Theorem 1 from
  (A0)–(A3), §5 blame, §8's four escapes, Prop 4 and Prop 6. `check.sh` asserts no `sorry`, two axiom tiers,
  a COMPLETE theorem registry, and the differential — each probed with a planted fault.

  **What it actually bought, against the prediction below that it would "prove the part that has never been
  wrong":** six defects, none of them in the algebra. In the model's own instruments: the Effect vocabulary
  was 7 where the engines are judged in 11; the differential quantified over 22 000 signatures no engine can
  emit; Theorem 1 was stated with plain containment where Definition 3 reads it modulo `⊑ₑ`. In PAPER3:
  Proposition 6's proof and Escape 2 both instantiate on `Db ⊑ₑ Net`, retracted by the Definition 2
  amendment and never propagated — and PAPER1 still carried the un-amended preorder outright, plus an
  evidence claim (the 5432 datapoint) whose verdict flips. All corrected. **The prediction was wrong in a
  specific way worth keeping: the algebra was indeed never wrong, but transcribing it is what made the
  STATEMENTS AROUND it checkable, and that is where everything was.**

  The residual is one item, tracked separately below (Definition 19's per-thread extent). The original
  framing is kept below because its reasoning about scope still governs.

  **REVISED UPWARD 2026-08-03 after asking "how do we prove the SPEC implements the PAPER?" — the answer
  is that we largely do not, and this is the missing link rather than a luxury.** What exists is
  `reference/policy_model.py`: a HAND TRANSCRIPTION of PAPER3 Definitions 1–7, 30–32, 35, 36 and Lemma 2
  into executable Python, which conformance PART 23 runs the engines against. That is real and it earned
  its place (it exists because a shipped engine took `deny Unknown[unresolved]` from REJECT to PASS when a
  call was ADDED — a counterexample to Lemma 2's corollary that no engine-vs-engine differential could
  catch). But note what it is and is not:
    · it checks ENGINES against a TRANSCRIPTION, never the spec text against the paper text;
    · coverage is the POLICY LAYER ONLY — §2's transitive rule, §3's honesty invariant, §4's Theorem 1
      and its A0–A3 antecedents, §5 blame, §7 monotone denial and §8 escapes are untranscribed and
      unchecked; *(all of these are now transcribed — see the SHIPPED note above)*;
    · **the transcription is itself an unverified, trusted artifact** — and it is known to have needed
      correcting (Definitions 33/34 deliberately dropped because they "describe verbs the deployment does
      not have", Proposition 5 rescoped as a result).
  So the theory↔spec link is maintained entirely by humans reading two prose documents side by side.
  `clause_check.py` proves a property cites a real SPEC clause; nothing relates the spec to the PAPER.
  Mechanising therefore does two things I undersold: it REPLACES the hand transcription with a checked
  artifact, and it EXTENDS coverage from the policy layer to the model's core. That reframes the work from
  "proving the part that has never been wrong" to "closing the one link in the theory↔spec↔code chain with
  no machinery at all". Tom's framing (2026-08-03): *these will help tease out any issues with the paper*
  — and the precedent supports it, since the first theory↔spec differential found the THEORY wrong twice.

  **WHAT IT WOULD BUY: the removal of human proof error.** The formal reference (PAPER3, local-only)
  survived four adversarial passes — *two of which existed only because my own repairs were wrong* — and
  the 2026-07-27 theory↔spec differential found the THEORY wrong twice (`pure` 15/256 → 0; `deny Net` on
  `{Db}` 100 rows → 0, both traceable to one sentence in §1 that had propagated into a definition). Those
  are exactly the failures a proof assistant makes impossible. Mechanising §1–§3 and Theorem 1 (the
  disclosure lattice, signatures + the transitive rule, the honesty invariant, monotone denial, policy
  semantics, blame localisation) would retire that class permanently.

  **WHAT IT CANNOT BUY, and this is the reason it is P3 and not P1.** Theorem 1 is CONDITIONAL on four
  antecedents — (A0) enumeration completeness, (A1) disclosure of every unresolved site, (A2) direct
  soundness with a transitively-closed library model, (A3) call-graph soundness modulo disclosure. Those
  are not theorems; they are empirical claims about what a third-party library does and about whether a
  front-end's view of a call matches the runtime's. **Every cardinal sin this project has ever fixed is an
  A0–A3 violation; none has been an error in the algebra.** From 2026-08-03 alone: `super.m()` into a
  chained dep (A3, missing edge), the static read forcing an unseen `<clinit>` (A1/A3), implicit
  stringification of an unscanned type (A1/A3), and the ratatui / tracing_subscriber classifier
  corrections (A2). A full mechanisation would prove, with total rigour, the part that has never been
  wrong. Discharging A0–A3 is the syscall oracle's job and the conformance suite's, which is the right
  division of labour and should stay that way.

  **NO ENGINE REWRITE.** Lean extracts to C; the engines are Rust/Java/TS/Swift, three of them bound to
  ecosystem front-ends (ASM, SwiftSyntax, the TS compiler API) that are the actual source of defects.
  Proving the shipped code would mean rewriting it and would STILL leave an unproven refinement gap
  exactly where the bugs live. Model-only, engines untouched, used as an oracle — which is what the
  self-differential properties already do informally. Natural first targets because they are literally
  theorem-shaped: **P1 split-invariance** and **P4 signature monotonicity**.

  **A LEAN ENGINE: NO — and the reason is worth keeping.** Lean already does candor's job: effects live in
  the type system, `IO` is in the signature. candor's entire value is finding effects a signature does NOT
  declare, so in Lean or Haskell the compiler has already answered the question. The languages where
  candor is valuable are precisely those where ambient authority is invisible. If anything an
  effect-typed language is a REFERENCE ORACLE for testing candor, not a target for it.

  Fits alongside the OOPSLA paper as a side artifact; costs no engine work; do not start it while
  anything on the A0–A3 side is open.

- **[P3 — research, 2026-08-04] The Lean model does not carry Definition 19's PER-THREAD dynamic extent,
  and right now that is a code comment rather than a tracked gap.**

  `Honesty.charged` collects `obs` along `ExecReaches` with no notion of threads. PAPER3 Definition 20
  additionally requires the reached frame to have executed *within `f`'s per-thread dynamic extent*, and
  Definition 19 is explicit that an effect issued on a **different** thread `f` spawned or handed a task to
  is **outside** it. So a `Run` whose `execCall` crossed a thread boundary would be one the paper does not
  sanction, and **nothing in the development would object** — `charged` would silently be too big and H⁺
  correspondingly too strong.

  It is not currently a false theorem: the model has no `spawn`, so there is no cross-thread edge to wrongly
  include. It is an unstated assumption, and it is written where unstated assumptions go to be forgotten —
  in a docstring. **Standing lesson this repeats exactly: a limitation written as a comment reads as
  CONSIDERED, which is what stops it being measured** (candor-swift's parse-error cardinal sin sat behind an
  accurate comment for months).

  **Closing it means modelling Definition 16b's labelled transition system** — `call`/`ret`/`spawn`/`issue`/
  `exit` steps over a per-thread state map `σ : T ⇀ Frame*` — which is the one part of §3 `Frames.lean`
  deliberately did not build. `Frames.lean` models the enclosing CHAIN (the structure Definitions 18–20 and
  Proposition 4 consume) but not the step relation that produces it.

  **Why it is worth more than tidiness, and also why it is P3.** This gap sits on the exact boundary the
  paper itself records as OPEN — Remark 6 and Table 1 row 2, the **thread-pool handoff**: a submitting frame
  performs an ordinary `call` into library code, and the task body later runs on a worker whose stack never
  contained the submitter. PAPER3 says that is "not an omission to be repaired by adding a label; it is the
  *reason* the cross-thread boundary of Definition 19 exists", and that any extension making the handoff an
  edge "would also have to say what `charged` means across it, which is precisely the open design question".
  So mechanising the transition system would not settle the research question — but it would make the
  boundary a hypothesis the theorems carry rather than a sentence in a comment, and it is the natural place
  to state whatever answer that question eventually gets.

  **AND THE ENGINE-SIDE HALF OF THIS BOUNDARY IS TRACKED NOWHERE.** I first wrote this item pointing at "the
  disclosure-refinement track's open row" for cross-thread/task-submission; grepping for it found nothing —
  the only `thread` hits in that track are `thread` meaning workstream. So the cross-thread handoff is a
  named open question in PAPER3 (Remark 6, Table 1 row 2) with **no backlog item on the tool side at all**.
  That is the gap to file next, and it is the larger of the two: what should an engine emit at a
  task-submission site whose body runs on a worker — a disclosure with which reason class, or nothing? The
  Lean gap above is that question seen from the model end; neither should be picked up without the other.

  (Filing that engine-side item is deliberately left as a decision rather than done here: it needs a ruling
  on whether task submission gets its own reason class or rides an existing one, which is Tom's call and
  changes what four engines emit.)

- **[MOSTLY SHIPPED 2026-08-04 `431b82d`; the remainder is customer-gated design — umbrella/spec
  convention, filed 2026-08-03] The umbrella has no notion of WHICH VERBS AN ENGINE
  IMPLEMENTS, and engine-specific verbs are unreachable through it.**

  **MEASURED (counted programmatically — my first hand-count of this got two of three numbers wrong).**
  `bin/candor`'s `QUERY_VERBS` is a flat, engine-agnostic list of **19**; candor-swift's CLI accepts
  **9**; the overlap is **7** (`parsepolicy fix fix-gate unverified tour path gains`). So:

      12 verbs the umbrella ROUTES that candor-swift does not implement
         (show where callers map containment diff reachable impact blindspots whatif rewire agents)
       2 verbs candor-swift HAS that the umbrella cannot route
         (privacy-manifest, gate)

  `engine_present` answers *"is it installed?"*, never *"does it support this?"*. Both directions fail,
  and neither fails HONESTLY:

      candor privacy-manifest      → "unknown action 'privacy-manifest'"   (umbrella doesn't know swift has it)
      candor show <fn>  on Swift   → "candor-swift: no such path: <fn>"    (engine got a verb it lacks and
                                                                            read the FN NAME as a path)

  The second is the worse one: it blames the user's argument for a capability gap, which is the opposite
  of the "failures carry remedies, nothing dead-ends" rule the rest of the CLI follows.

  **WHAT ALREADY EXISTS, so this is narrower than it looks.** SPEC ⟨0.13⟩ has a developed extension
  mechanism for the DATA plane: an ecosystem-specific surface may be led by the motivated engine as a
  `SPEC-EXTENSION-<name>.md` in its own repo; the envelope discloses `"extensions": ["privacy/1"]` *"so a
  consumer can tell an extension effect from a typo"*; there is a promotion path (into the spec when a
  second engine implements it, or direct adoption, whose text becomes the differential's oracle); and the
  governing line is *"An extension never holds the shared floor back and a floor claim never speaks for
  it."* **None of that says anything about VERBS.** The extension mechanism describes the data an engine
  may ADD and is silent on the commands it may add.

  **THE CHEAP FIX (do this first).** A per-verb engine table in `bin/candor` — which verbs each arm
  supports, plus the engine-only ones — so `candor privacy-manifest` routes to swift and `candor show` on
  a Swift project says *"candor-swift does not implement `show`; the engines that do are …"* instead of
  blaming the argument. No wire change, no spec change. This is the same shape as the `candor verify`
  language-arm refusal added 2026-08-03.

  **THE DESIGN QUESTION (do NOT build until it has a customer).** Tom's wider point: should the spec
  define vocabulary/features that are OPTIONAL for engines? **The hazard is exact and it is the one this
  project spent 2026-08-03 removing twice: absence is a claim.** If the spec defines `Health` as optional
  and an engine does not implement it, that engine's silence is ambiguous between *"no health access in
  this code"* and *"I do not look for health"* — precisely the ambiguity ⟨0.26⟩ closed for sidecar keys
  and for the §5 reconciliation trio. So optional-in-spec vocabulary is safe ONLY alongside a positive
  capability declaration; without one it reintroduces the defect at the vocabulary level.
  **⟨0.27⟩ SHIPPED THAT PREREQUISITE for refinement surfaces: `resolves` is the positive declaration**,
  so an absent optional field means "undetermined" only where the surface is declared. The open half is
  now the customer question, not the design one.
  The encouraging half: `extensions: [...]` is ALREADY that shape — a positive declaration of what is
  active — so the manifest would be a generalisation rather than a new concept.
  Counterweights, stated so the decision is made with them in view: it is more machinery on the wire; and
  the spec currently draws a hard line that the FLOOR is what every engine meets, which optional-in-spec
  vocabulary blurs. (Extensions already blur it — but in the engine's own repo, where a consumer is less
  likely to look, which is an argument on both sides.)

- **[SHIPPED 2026-08-04 as `privacy/2`, with read/write direction — filed 2026-08-03] Health and Motion are not in the six-effect cluster, and a
  real health app shows the gap.** privacy/1 covers Location / Camera / Mic / Contacts / Photos / Notify.
  It does NOT model `HKHealthStore` or `CMMotionManager`, so `NSHealthShareUsageDescription`,
  `NSHealthUpdateUsageDescription` and `NSMotionUsageDescription` are invisible to `privacy-manifest`.

  MEASURED on pollen (read-only; scanned a COPY in scratch, the repo was byte-identical afterwards):
  it uses `HKHealthStore` (1 file) and `CMMotionManager` (1 file) and declares keys for both — so **four
  of the nine usage keys across its two Info.plists are outside candor's vocabulary**. A `verify` that
  passes on such an app is silent about them, and an iOS reader would spot that immediately.

  Health/fitness is a whole app category, and the sensors are the ones users care most about. The work is
  the same shape as the original six (candor-swift `SPEC-EXTENSION-privacy.md`: classifier entries + the
  effect → key mapping + fixtures), so this is an extension rather than a design problem. It is also the
  honest prerequisite for the article below if that article uses a health app.

- **[P2 + CONTENT — 2026-08-03] Route `privacy-manifest` through the umbrella, and write it up.**
  **DEMO MATERIAL — pollen, RE-MEASURED PER TARGET 2026-08-04 (candor-swift 0.26.0 built + installed).**
  The 2026-08-03 numbers were from a single whole-codebase scan, which the entry itself flagged as
  candidate-only. Run per target, ONE OF THE TWO DISSOLVES AND THE OTHER GETS MORE INTERESTING:

      whole-codebase → Resources/Info.plist   exit 1  ✗ Mic          ARTIFACT — see below
      macOS target   → Resources/Info.plist   exit 0  ✓ clean (3 effects)
      iOS target     → Apps/PolleniOS/Info.plist exit 1 ✗ Contacts   REAL

  · **The Mic finding was a methodology artifact.** `iOSBlowMonitor` lives only in `Sources/PolleniOS`,
    which the macOS app does not compile. Scanning all targets as one unit charged an iOS-only sensor to
    the macOS plist. Per target the macOS app is clean, and the iOS plist *does* declare Microphone.
  · **The Contacts finding survives, and is the better story.** `ContactsService` is in `Sources/PollenCore`,
    which `PolleniOS` depends on, so the Contacts API is compiled into the iOS binary — while
    `Apps/PolleniOS/Info.plist` declares no `NSContactsUsageDescription`. **Grepping `Sources/PolleniOS`
    for Contacts returns nothing**: the only callers are in `Sources/PollenApp/Views.swift`, the macOS app.
  · **candor's own output distinguishes linked-from-called, if you read it.** The iOS run's reached-by list
    is exactly `ContactsService.isAuthorized, ContactsService.resolve` — the API's own wrappers and no
    callers. The macOS run's is `…, SettingsView.body, …` — a real call site. So the iOS exposure is
    binary-level (the API is linked; Apple scans binaries) rather than a runtime crash path, and the fix is
    either declaring the key or keeping `Contacts.swift` out of the iOS target's module.

  Both runs carry the tool's own hedge: *"verdict is conditional on 15 uncovered modules"*.

  Both plists also carry the tool's own hedge: *"verdict is conditional on 22 uncovered modules"*. That
  line belongs IN the article — a tool that discloses its own blind spots while making a finding is the
  whole pitch, and it pre-empts the obvious "how do I know it saw everything?".
  **The caveat was right and is now discharged** — the per-target run cleared one finding and kept one, so
  the article's spine is *the methodology*, not the count: run it per shipped binary, because scanning a
  monorepo as one unit charges every target with every other target's sensors.
  candor-swift's `privacy-manifest` verb is BUILT and working — verified end to end on a fresh fixture:

      GENERATE  Location → NSLocationWhenInUseUsageDescription (reached by: track)
      VERIFY    key missing   exit 1  ✗ code reaches Location (via track) but Info.plist declares none
                key present   exit 0  ✓ every accessed capability is declared
                corrupt plist exit 2  (fail-loud, never a silent empty answer)

  **The routing gap is CLOSED (2026-08-04):** `candor privacy-manifest` now routes to candor-swift via the
  umbrella's per-verb capability table, and `candor gate` with it. See the capability item above.
  **⚠ THIS ROUTING HALF IS A SUBSET OF the "umbrella has no notion of which verbs an engine implements"
  item above** — `privacy-manifest` is one of the two engine-only verbs that item counts, and building the
  per-verb table there routes it for free. Do NOT do them separately. What is unique to THIS entry is the
  CONTENT half below; the routing is listed here only so the article is not written about a command that
  still fails through the umbrella.

  **WHY IT IS ALSO THE BEST ARTICLE CANDIDATE WE HAVE** (Tom, 2026-08-03 — LinkedIn post or a
  candor.poly.io piece). It is the one feature with a consequence a reader already fears: an App Store
  rejection. The story writes itself and every beat is demonstrable in a terminal:
  · the reach is TRANSITIVE — a `Location` three calls deep through a helper still requires the key, which
    is exactly what grepping your source for `CLLocationManager` will not tell you;
  · the asymmetry is the interesting half — an UNDER-declaration is a rejection (exit 1), an
    OVER-declaration is an unused permission users can see (a warning, exit 0). Most tools do neither;
  · `Notify` maps to NO key, because notifications gate at runtime — a detail that shows the mapping was
    derived from how Apple actually works rather than pattern-matched;
  · it is generate AND verify, so it fits a CI story as well as a one-off audit.
  Needs a real demo app rather than the toy fixture above, and it should say plainly that it is swift-only
  today. Ties to the adoption thread and to `candor.poly.io/case-studies/`.

- **[CLOSED 2026-08-13 — all five engines, drift gates re-synced] No engine's AGENTS.md leads to the umbrella `candor` command.** Each
  engine doc teaches a DIFFERENT command and none mentions the one thing the umbrella README calls *"the
  one thing you install"*:

      candor-rust    `cargo install candor-scan`  → `candor-scan`; Path B adds `cargo candor` + `candor-query`
      candor-ts      `npm i -g candor-ts@latest`  → `candor-ts`, `candor-ts-query`, `candor-ts-mcp`
      candor-java    `jbang candor@tombaldwin/candor-java`
      candor-swift   `swift build -c release` from a clone — no install step at all
      candor-agents  `pipx install git+…`         → `candor-agents`

  So an agent that lands in candor-rust and follows its contract gets a working `candor-scan` and never
  learns the umbrella exists. The near-miss is candor-rust's `cargo candor update` — a CARGO SUBCOMMAND
  that reads almost identically to the umbrella verb and is not it.
  This costs the things the umbrella is FOR: `candor doctor`, `candor verify`'s language routing, and one
  pin for the whole family. Five entry points teaching five command names is also the likeliest source of
  "which one do I actually run?".
  **UNBLOCKED — verified 2026-08-03**: `Formula/candor.rb` is on the tap's `origin/main` (at 0.25.0), so
  `brew install tombaldwin/tap/candor` works for a stranger today. (An older note in my own memory said the
  tap was "built and held unpushed"; that is stale, and I checked before filing rather than repeating it.)
  So this is a docs change only — add a "you probably want the umbrella" pointer near the top of each
  engine's AGENTS.md, keeping the per-engine path for people who genuinely want one engine.

- **[CLOSED 2026-08-13 `4356162`; and the sweep it triggered closed java + swift too] candor-ts does not gate itself.** Three of the four engines run a
  self-gate in CI — candor-rust (`Self-gate (candor on candor)`), candor-java (`Self-gate (candor-java on
  candor-java)`, which proves TWO halves separately because a prefix scope cannot exclude one sub-package
  from a `deny`), and candor-swift (`§7.12 — the engine holds its own boundary`). **candor-ts does not, and
  has no `.candor/policy` at all** where rust and java both do. It is the one repo with a shipping engine
  that could analyse itself and doesn't.
  It also covers the surfaces most likely to acquire an effect by accident — the LSP, the MCP server, the
  `verify` CLI. Same shape as the three that exist: a policy file plus a CI step. candor-java's comment is
  the argument: *"An effect-gate vendor whose own gate is red has no business gating anyone else."*
  NB a self-gate proves "our own code performs no forbidden effect" — it does NOT test the analysis. That
  is the oracle's job, and only candor-rust runs `realworld-oracle` continuously.

- **[FIXED 2026-08-04] The release scripts have no tests.** `bin/release-test.sh` — 29 assertions against a
  throwaway fixture tree of six stub repos, gated in CI by `release-scripts.yml` on any change to `bin/` or
  `scripts/`. Every assertion was probed by re-introducing the defect it exists for and watching exactly one
  fail. It found a TENTH defect while being written: `release-stage.sh`'s header claimed "re-running is a
  no-op that reports already at", and it was false — the callers' patterns match ANY version, so a re-run
  rewrote every site with identical bytes and reported ~14 edits. A run that reports edits when nothing moved
  hides the one release where something did; `sub` now distinguishes matched-but-unchanged from no-match.

  **The residual, stated rather than implied:** the publish calls — `cargo publish`, the npm OIDC tag,
  `gh release create`, the tap — are still exercised only by a real release. They need a dry-run mode or
  stubs, and neither exists. Eight of the nine original defects were on the tested side of that line.

  *(original entry)* **The release scripts have no tests.** `release-stage.sh` now performs
  ~18 edits across six repos and `release-preflight.sh` carries eleven checks, and NOTHING gates either.
  Building the stage script surfaced two real bugs purely by running it: a heredoc nested inside `$(...)`
  is a shell parse hazard, and `\1` immediately followed by `0.26.0` parses as group TEN (`\g<1>` is the
  only safe form). Both were caught by execution, neither by reading.
  A fixture repo tree (six stub repos with the version sites and a CHANGELOG each) plus assertions on the
  staged result would catch that class. The argument for doing it: these scripts now stand between a defect
  and a publish, which is exactly where an untested script is worst.

- **[CLOSED 2026-08-14 `a21967e` — and the filing named the wrong FILE] Local clippy is weaker than CI's, so "clippy clean" locally is not evidence.**
  `clippy 0.1.98` on this machine exits 0 on two adjacent `#[test]`; CI's stable toolchain errors
  (`duplicate-macro-attributes`). That cost a CI round-trip on 2026-08-03 — and the same commit had a
  stranded `#[test]` that SILENTLY DISABLED a liveness test, which local `cargo test` also could not see
  (the total stayed flat because a duplicated attribute registers the test twice).
  Fix is a pinned toolchain for local dev, or a line in AGENTS.md saying local clippy is ADVISORY and CI is
  the authority. Tiny, and it removes a false signal — which is worth more here than its size suggests.

- **NOT backlogged, recorded so they are not re-proposed** (checked 2026-08-03):
  · **candor-agents / candor-spec / the umbrella not self-gating** — no engine analyses Python, Markdown or
    shell. An honest absence, not a gap; filing it would create a permanently-open item. The umbrella's
    `bin/` is the one place in the family that genuinely reaches the network and spawns processes
    (`release.sh`), and nothing could gate it today without a shell engine — worth KNOWING, nothing to do.
  · ~~**A family-wide sweep for version-coupled test assertions**~~ — **REOPENED AND FIXED 2026-08-04.
    The measurement was wrong.** This entry recorded that a sweep found "the only other hits are usage
    strings", so the class was closed as a one-off. The ⟨0.27⟩ floor bump then turned **every repo red**:
    four assertions in candor-agents' own `test.py`, three in candor-java's `smoke.sh`, several in
    candor-rust's cli tests plus its integration script and its doc-drift gate, and README / AGENTS /
    package.json in candor-ts.

    The sharpest instance: candor-agents' `test.py` carries a comment explaining that a version-coupled
    assertion "is the same hand-edit class that cost the 0.25 release" and derives ONE constant — while
    four assertions in the same file hardcoded `"0.26"`. The lesson was written down and not generalised.

    **Fixed by DERIVING, not by re-editing literals**: `_SPEC` from `candor_agents.scan.SPEC`,
    `SPEC_DECLARED` grepped out of `Candor.java` and `candor-report/src/lib.rs`. candor-swift needed no
    change — its `smoke.sh` already derived `$BSPEC` from the binary, which is why it caught its own stale
    README rather than passing. That is the shape the rest now match.

    **What a find-and-replace sweep would have broken**, and why this was fixed by reading each site:
    candor-rust's `tests.rs` builds fixture reports declaring `"spec": "0.26"` — those are INPUTS proving
    an older report still loads, so pinning them to the previous floor is their purpose. A blanket bump
    would have silently deleted a backward-compatibility test.

    **Standing lesson: "I measured it and it was a one-off" is a claim with a shelf life.** The measurement
    was true when taken and false one rung later, because every new assertion is written by someone who has
    not read this entry.

- **[CLOSED 2026-08-03 — as `release-preflight.sh` check [9], and my filing had the MECHANISM wrong]**
  **Work stranded under `## Unreleased` at release time.**
  I filed this as "`release.sh` inserts a heading above `Unreleased` instead of renaming it". It does
  neither: `release.sh` only READS a CHANGELOG, for the GitHub release body. Nothing in the pipeline
  renames the section at all — so it falls to a human, and at 0.25 nobody did, leaving four engine
  CHANGELOGs with shipped work under `## Unreleased` (the v0.25.0 tag contains the commits that wrote
  it). Fixed as a GATE rather than an edit: `release.sh`'s contract is that everything is already
  bumped, committed and pushed — it refuses to run on a dirty tree — so having it rewrite and
  re-commit a changelog mid-publish would contradict its own gate. Preflight is where "is this staged
  correctly" lives, and a gate that NAMES the fix beats a script that silently performs it.
  Fires only when a VERSION is being asserted (content under `## Unreleased` is the normal state
  during development, and failing everyday health checks is how a gate stops being read), ignores a
  QUALIFIED section (candor-rust's `## [Unreleased] (nightly lint)` has its own cadence), and ignores
  an EMPTY one. Verified both ways: 5 repos flagged when cutting 0.26.0, 0 when the section is empty.
  ~~ORIGINAL:~~ Cutting 0.25 left a stale `## Unreleased` heading sitting BELOW the shipped
  `## [0.25.0]` in four engine CHANGELOGs — the `v0.25.0` tag contains the commits that wrote that
  content, so it had shipped while still labelled unreleased. Anyone reading those files after the release
  would have taken shipped work for pending work. Fixed by hand in the 0.26 floor bump; the script still
  has the behaviour. The fix is one step in `release.sh`: rewrite the existing `## [Unreleased]` /
  `## Unreleased` heading to the version being cut, then start a fresh empty one.


Correctness and disclosure are well-shored and **cross-engine-verified**: the inherited-into-project silent-pure
vein class was found and closed across all major JVM persistence (candor-java κ batches 24–27) and
confirmed not a shared blind spot; the **real-world corpus campaign (2026-06-22)** fixed the last live
silent-under-reports in every engine, each gated by per-engine probes + the cross-engine conformance
differential. Undirected corpus probing is mined out (multiple consecutive clean rounds). The
deployability gate is shipped end-to-end (AS-EFF-005 ratchet, 006/008/009 policy, 010 containment,
conformance-pinned). The spec advances on a **version LADDER, not lockstep** (Tom, 2026-07-01 — SPEC.md
§"Versioning policy"): the reference engine may lead a minor/additive rung, the floor stays
conformance-pinned over the four code engines, breaking bumps stay lockstep. The ladder has run
fifteen full cycles: **0.8** (the `--gate-json` gate verdict), **0.9** (the remedial tool loop), **0.10**
(the canonical query grammar), **0.11** (the surprising-reach surface + corrupt-report loudness),
**0.12** (the gains `origin` field), **0.13** (the `Llm` effect + the `extensions` field / the
candor-swift `privacy/1` sensor extension + `privacy-manifest` verb), **0.14** (the top-level/initializer
unit — a cardinal-sin closure), **0.15** (the coverage envelope — the κ ledger travels with the
report, verdict-preserving verb conditionality — plus host-resolution recall and four corpus-found
soundness fixes), **0.16** (the callgraph-aware baseline guard — a formerly-pure fn turning effectful is a
gain, AS-EFF-005; Unknown-only gains stay advisory), **0.17** (query target validation — `where`/`callers`
fail loud (exit 2) on a typo'd effect or nonexistent fn, never a false empty at exit 0), **0.18** (the
trust-trio — the `--strict` advisory-verb CI gate + the surface/`tour` mostly-Unknown disclosure, hardened
by a Fable-model review that caught two latent cardinal-sin edges), **0.19** (reason-scoped `Unknown`
policies — `deny E Unknown[reflect,dispatch,…]` + the transitive reason-class + the `reasonClass` verdict
field; dissolves the DI/reflection deny-all-able dealbreaker), **0.20** (the `Net` destination-class —
`netClass` known-telemetry/known-partner/unknown-host + `deny Net[unknown-host]` + the `blindspots --stats`
reason-distribution), **0.21** (the completeness manifest — report/verdict `analyzed`+`unanalyzed`, a
fail-closed exit-2 incomplete verdict closing a machine-consumer cardinal-sin channel), and **0.23** (the
cross-package interface-dispatch rung — an additive `interfaceUnion` entry gated behind
`CANDOR_WORKSPACE_CHAIN`). The **floor is now 0.23** (all code engines at 0.23.x, **published + release-
verified live**: crates.io, npm via the OIDC/SLSA action, gh releases, java native binaries, the Homebrew
tap). **0.23.1 (2026-07-20, a WITHIN-SPEC patch — spec stays 0.23) is the newest:** an engine-**performance**
sweep (two super-linear cliffs killed family-wide — chaTargets memoize + Surface presort + worklist
fixpoints, all byte-identical-verified; see the versioning-ladder history) plus the `Llm` model-SDK
fabrication fix AND its review-caught silent-under-report correction (a denylist over the sound blanket,
never an allowlist — the denylist-over-allowlist rule); umbrella patched to 0.23.2 to fix a stale
`ENGINE_PIN` that had `candor update` fetching 0.18 engines under a 0.23 umbrella.

**Priority (Tom, 2026-07-01): the agent loop stays the north-star, with the JVM arch gate co-important —
fund both, demote neither.** The **agent edit-time feedback loop** is the cutting-edge, differentiating
bet (effect-aware feedback into a live AI coding loop is novel and hard to copy); the **JVM architecture
gate** is the solid-engineering wedge (proven, deterministic, sellable). This supersedes any reading of
the 2026-06-18 repositioning as *demoting* the agent angle — that made the gate the lead **sales** wedge,
not a reason to stop investing in the agent loop, which stays P0 below.

Value runs in **two parallel tracks**; within each, new *disclosure* capability is largely mined-out and the
spec advances only on the ladder (now at 0.23). Two caveats to "mined-out", learned since: (a) **engine
PERFORMANCE was net-new depth** — the 0.23.1 sweep found and killed two genuine super-linear cliffs (CHA
recomputation, O(V²) fixpoints) the earlier corpus rounds never surfaced, so "capability is mined-out"
never implied "the engines are as good as they get"; and (b) a code review before the 0.23.1 publish caught
a **cardinal sin a fix had just introduced** (an Llm-narrowing allowlist that silently under-reported Spring
AI streaming/embedding) — a reminder that new soundness holes can still be *created*, so the review-before-
ship discipline stays load-bearing. **Both tracks' build-outs are complete**:
the arch-gate funnel end-to-end (items 1–3 below), and the agent-loop polish closed 2026-07-14 (the
`candor_activity` MCP + LSP push — no polish items remain). The 2026-07-15 autonomous corpus+audit run
confirmed the engines sound across ~20 real repos (4 real finds, all fixed and shipped in 0.15). What
remains open, by kind: **externally blocked** — the JetBrains Marketplace first-plugin moderation
(uploaded 2026-07-03, still pending 2026-07-15), the lsp4ij catalog PR #1609 (no review yet), the VS Code
Marketplace publisher (needs Tom's Azure DevOps PAT); **Tom's commercial call** — gains productionization
(the hosted watch layer; waitlist buttons live on the site with the sharpened Llm hook, 0 signups as of
2026-07-15); **candidate next bets** — the fingerprint structure-gate (designed,
`fingerprint/STRUCTURE-GATE-DESIGN.md`, not built) and whatever the next planning pass ranks.

### Agent-loop track — the north-star

- **[SHIPPED — verified 2026-08-03] Agent edit-time blast-radius feedback.** [`integrations/claude-code/`](integrations/claude-code/):
  a Stop hook that scans the agent's turn, diffs effects vs a baseline, and blocks-once with the gained
  effects + blast radius + any policy violation so the agent self-corrects. Both delivery paths ship
  (`candor-review.sh` JVM/bytecode; `candor-review-source.sh` for ts/swift/scan — no build step), sharing
  the exit contract; the delta is computed from the spec report envelope so it's engine-agnostic and
  catches pure→effectful. Agent-visible feedback (the `candor: ✓ checked` notice, `.candor/activity.jsonl`
  stats, the labelled `savings` model) also shipped — see *Recently shipped* and
  [`FEEDBACK-SPEC.md`](integrations/claude-code/FEEDBACK-SPEC.md). _Polish COMPLETE (2026-07-14):_ the
  in-IDE/MCP push shipped both halves same-day (`candor_activity` on candor-mcp + the candor-lsp
  activity tail — AGENT-SURFACE-DESIGN.md P1/P2); `maxHops` + standalone/CI logging closed the same
  week (FEEDBACK-SPEC P2.2/P2.3). No agent-loop polish items remain.

- **The agent-surface sequence (decided by Tom 2026-07-02; design in
  [`integrations/AGENT-SURFACE-DESIGN.md`](integrations/AGENT-SURFACE-DESIGN.md)). Bet 1 — the unified
  `candor-mcp` — SHIPPED same day:** one engine-agnostic MCP server (candor-ts pkg, `candor-mcp` bin)
  serving all four engines' reports, with the gate verdict (resolves the checked-in `.candor/config`
  policy), containment, blindspots, diff, gains + MCP resources (report + policy); verified across all
  four engines' real reports; the rust python server deprecated. On npm since candor-ts 0.8.3
  (current 0.8.7).
  **Bet 2 — `candor-lsp` — P1 SHIPPED (2026-07-02):** CodeLens `⚡ effects · blast radius N` + the live
  gate verdict as diagnostics (config-discovered policy), any engine's report (java bytecode locs verified),
  freshness via report re-reads (watch/stop-hook/build). helix/neovim wire it natively; 9 behavioral tests.
  **The VS Code client SHIPPED 2026-07-10** ([`integrations/vscode/`](integrations/vscode/)): a thin
  `vscode-languageclient` extension bundling the handshake-verified candor-lsp (candor-ts pinned 0.8.8,
  the JetBrains stage→bundle→verify chain in npm-script form), runs the server on VS Code's own Node
  (no system node); `candor-vscode-0.8.8.vsix` packaged + verified FROM the artifact (`test-vscode.sh`:
  pin, LSP lifecycle handshake on the extracted bundle, contents, README drift; path-filtered
  `vscode.yml` CI) and smoke-installed/uninstalled via the real `code` CLI. Sideload the .vsix (works
  in Cursor/Windsurf too); Marketplace publisher setup pending. _Remaining P2 slices:_ the whatif
  code-action (landing in candor-ts — the extension picks it up with the next `candorTsVersion` pin
  bump, no client change), large-repo lens performance (hover provenance shipped 2026-07-02, published
  in candor-ts 0.8.3+). **JetBrains
  slice STAGED (2026-07-02):** (a) an LSP4IJ template for the catalog (install LSP4IJ → pick "Candor"
  → auto npm-install) — **PR OPEN:
  [redhat-developer/lsp4ij#1609](https://github.com/redhat-developer/lsp4ij/pull/1609)** (watch for
  maintainer review); (b) [`integrations/jetbrains/`](integrations/jetbrains/) — **PACKAGED + gated
  (refreshed 2026-07-09):** `./gradlew buildPlugin` (wrapper pinned 9.5.1) → `candor-intellij-0.8.2.zip`
  (sideloadable) against IC 2024.3 + LSP4IJ 0.20.1, embedding the handshake-verified server bundle
  (candor-ts pinned 0.8.7) + the pinned v0.8.6 engine jar (both pins are build-task inputs, and
  `verifyEngineJar` fails the build unless the staged jar self-reports the pin); the JVM freshness
  loop uses the modern ProjectTaskListener API. **Verifier-clean (Compatible × 6 IDE targets, IC-243 →
  IU-262** — it caught the em-dash plugin-name Marketplace blocker); Beaky pluginIcon.svg; a
  path-filtered `jetbrains.yml` CI workflow (build per plugin change + weekly scheduled Plugin
  Verifier). **UPLOADED to the JetBrains Marketplace 2026-07-03 (as 0.8.0; Apache-2.0, tags: static
  analysis / code quality / security; source URL → integrations/jetbrains) — first-plugin moderation
  pending.** On approval: wire `publishPlugin` + the Marketplace token as a repo secret so 0.8.1+ ship
  headlessly; an install-from-disk smoke in a real IDE remains worthwhile whenever convenient.
  **Released engines (as of 2026-07-10, ship wave 2):** candor-ts 0.8.7 (npm), candor-scan 0.8.5 +
  candor-query 0.8.1 (crates.io), candor-java v0.8.6, candor-swift v0.8.5, candor-agents v0.8.1
  (GitHub) — all spec-0.8; plugin 0.8.2 zip staged for Marketplace. Family test standards now
  codified in TESTING.md (coverage measured + every zero-coverage gate surface closed).

- **[SHIPPED — ALL THREE PHASES, verified 2026-08-03 against integrations/DIGEST-SPEC.md] The candor digest — make the silent gate VISIBLE.** Adoption/retention
  problem Tom named: the tool is silent by design (good — never muted), but the OWNER who renews never
  sees it work → "why are we running this?" is easy to ask. Fix is NOT more dev-channel noise — it's a
  separate periodic OWNER-facing digest over the activity log candor already keeps
  (.candor/activity.jsonl + candor-agents stats). Spec: `integrations/DIGEST-SPEC.md`. Leads with the
  catches, closes with "N clean = the product working", ALWAYS carries the coverage/honesty line (what
  candor couldn't see — its own disclosure ethos pointed at itself), counts-not-a-leaderboard,
  aggregate-only (paths stay local, privacy tier = the gate verdict). Build order: **P1 DONE 2026-07-10** — `candor-agents digest` renders CANDOR-REPORT.md (owner narrative, caught-vs-allowed split, always the coverage/honesty line, aggregate-only, 13 tests, 391 total). P2 DONE 2026-07-10 — gate logs outside the agent hook (candor-review*.sh self-log a path-free record via the shared lib.candor_log_activity; no double-log under the hook; +5 tests) + adopt/candor-digest.yml scheduled Action → run summary + committed CANDOR-REPORT.md. "Held the line in CI" is real. P3 DONE 2026-07-10 (delivery complete): (a) jar --gate-json path logs via candor-agents log-gate (path-free record, parity-tested vs the bash writer; opt-in EDIT 5 in adopt/candor.yml) so the pure-jar PR gate feeds the digest; (b) optional Slack push in adopt/candor-digest.yml (CANDOR_SLACK_WEBHOOK-gated, no-op when unset). DEFERRED: the gains dependency line — blocked until a gains monitor produces records (receiver-before-producer = speculative). Was: P1 `candor-agents
  digest` → committed CANDOR-REPORT.md (cheapest, on data that already logs); P2 log CI/standalone runs
  (close the FEEDBACK-SPEC "standalone/CI logging" deferred gap) + a scheduled Action; P3 Slack/email +
  the gains dependency line. Cheapest-first, each step the same rendered text through a different pipe.

- **[SHIPPED — was "later"] IDE inline effects (LSP).** This landed as the `candor-lsp` CodeLens
  (`⚡ effects · blast radius N`) + live gate diagnostics + hover provenance, in VS Code, JetBrains
  (LSP4IJ), helix and neovim — the Bet-2 sequence above. The item predates the ship; kept for the record.

### Arch-gate adoption track — the solid-engineering wedge

One funnel, now **built end-to-end**: `candor-init.sh` writes the policy + baseline + Action → the gate
enforces it → PR-native SARIF surfaces it in review → the live demo shows it running. What shipped
(detail in *Recently shipped*):

1. **PR-native gate surfacing (SARIF) — SHIPPED 2026-07-01/02 + validated in real GitHub Actions.**
   Violations land inline on the PR diff and in the Code-scanning tab on the exact boundary-crossing line,
   via `--gate-json` (spec 0.8) → [`integrations/github/candor-sarif`](integrations/github/candor-sarif) →
   `upload-sarif`. Live example: [`candor-action-demo`](https://github.com/tombaldwin/candor-action-demo).
   _Remaining:_ optional Check-Runs API (only if SARIF rendering proves too coarse); P4 baseline-delta
   **skipped** (GitHub's code-scanning already diffs PR SARIF vs the base branch natively).

2. **Policy inference + one-command init — SHIPPED 2026-07-02.** [`adopt/candor-init`](adopt/candor-init)
   proposes a starter policy from what the code already does (every proposed rule currently passes);
   [`adopt/candor-init.sh`](adopt/candor-init.sh) scaffolds policy + baseline + Action in one command.
   Both hermetically tested, in umbrella CI, documented as the fast start in `adopt/README`.

3. **Consolidated `.candor/config` file — DONE across all four engines (2026-07-02); normative as
   SPEC.md §3.4.** A checked-in `key value` file replacing the `CANDOR_*` env wiring: shared 7-key
   vocabulary (inert-if-unimplemented, warn-if-unknown), target-anchored discovery (`$CANDOR_CONFIG`
   overrides), precedence CLI → env → config → default, fail-closed when configured-but-unusable.
   Conformance **PART 13** pins discovery/precedence/fail-closed per engine (1/0/2, all four green);
   `candor-init.sh` scaffolds it (policy + baseline wired, never clobbered). An additive amendment
   within 0.8 — configuration, not the wire contract. **First shipped in every engine's 2026-07-02
   release** (ts 0.8.3 / scan 0.8.3 / java v0.8.2 / swift v0.8.2) and carried by every release since
   (wave 2, 2026-07-10: ts 0.8.7 / scan 0.8.5 / query 0.8.1 / java v0.8.6 / swift v0.8.5 /
   agents v0.8.1).

4. **Distribution — CLEARED (2026-07-02).** The proven wedge is now on the site:
   [candor.poly.io/case-studies/](https://candor.poly.io/case-studies/) (the five studies, deployed) and
   the cross-model eval evidence on [candor.poly.io/agents/](https://candor.poly.io/agents/) (verified
   live). Remaining distribution is ongoing marketing, not a backlog item: keep the adopt starter + site
   current as the tools change (the site's engine versions self-update at build; fallbacks refreshed 0.8.x).

### Vocabulary + breadth track (opened 2026-07-14 — Tom: "yes, and privacy")

- **[SHIPPED + PUBLISHED as floor 0.13 — verified 2026-08-03] The `Llm` effect** — design done (candor-spec/LLM-EFFECT-DESIGN.md): a standalone boundary
  effect (the Db precedent) from SDK surfaces + the host literals we already extract; java-led minor
  rung; the sharpest gains/origin alarm ("your dep bump added an LLM call"). DECIDED (Tom 2026-07-14, all
  recommendations accepted). Next: the java reference implementation.
- **[SHIPPED 2026-07-14 — verified 2026-08-03] The privacy-sensor cluster** (Location/Camera/Mic/Contacts/Photos/Notify) — design done
  (candor-spec/PRIVACY-EFFECTS-DESIGN.md): swift-led; the product shape is privacy-manifest
  generate/VERIFY from code-level truth. SHIPPED (2026-07-14, code green): the
  privacy/1 SPEC EXTENSION (candor-swift/SPEC-EXTENSION-privacy.md + impl, 183 tests, envelope
  extensions disclosure, PART 4n tolerance pin). Six effects Location/Camera/Mic/Contacts/Photos/
  Notify. spec strings still 0.12 — rides the 0.13 floor bump with Llm. SHIPPED (2026-07-14): the privacy-manifest
  generate/verify verb (candor-swift b9a68a6, 196 tests) — the real-app exhibit is LIVE (pollen's iOS
  Info.plist under-declares NSContactsUsageDescription vs a real ContactsService reach).
  **PER-TARGET SCOPING DONE 2026-08-05** (`candor-swift . --target <name>`, riding 0.27): resolves the
  target's in-package dependency closure from Package.swift and scans exactly those sources, so the
  whole-tree caveat is a flag rather than a hand-built Package.swift per binary. Measured on the real
  app: whole repo → ✗ Mic ✗ Motion against the macOS plist (the artifact); `--target Pollen` → exit 0
  clean at 4 effects; `--target PolleniOS` → exit 1 on Contacts, the finding that survives correct
  methodology. Two soundness bugs found while building it, both in the see-less direction: `.target(
  name:)` inside a `dependencies:` array parsed as a second target DECLARATION (phantom entry with no
  deps, so the closure walk could stop early and drop sources), and a scoped report was joinable as the
  WHOLE package (every unscanned function then a purity claim) — fixed by qualifying the key to
  `<pkg>/<target>#…` so a miss is disclosed. SOUNDNESS-LOG 2026-08-05; the vein was checked in
  candor-rust and candor-ts and is NOT there.
  _Remaining:_ the public writeup — `candor/docs/case-study-privacy-manifest.md` is written, every
  factual claim re-measured against the current engine, and awaiting Tom's publish decision. It needs
  0.27 published first (it documents `--target` and the read/write direction).
- **[P1 — the `unanalyzed` manifest covers files that FAILED, not files never CONSIDERED. MEASURED in
  three engines 2026-08-05.]** A source file inside the package that the engine's file-set rule skips is
  absent from the report AND absent from `unanalyzed` AND absent from the coverage ledger. Under ⟨0.21⟩
  absence from `functions` is a positive purity claim, so this is the cardinal-sin shape at FILE
  granularity — and the ⟨0.21⟩ machinery built to catch exactly this is never fed by the file-set decision.

  Reproduced, each on the tip engines:

  | engine | the skipped file | result |
  |---|---|---|
  | candor-ts | `src/deploy.js` calling `child_process.execSync("curl … \| sh")`, beside one `.ts` file | `deny Exec` → **`policy ✓`, exit 0**; `1 files` analyzed; `unanalyzed: None`; `coverage: null` |
  | candor-rust | `build.rs` running `Command::new("curl")` — the canonical supply-chain vector, executing at BUILD time | `functions: []`, `analyzed.count: 1`, `unanalyzed: None` |
  | candor-swift | `Sources/App/legacy.c` calling `system("curl … \| sh")`, in the scanned target | `analyzed.count: 1`, `unanalyzed: None` |

  **A REVIEW CLAIMED THIS WAS WORSE THAN IT IS, AND THE CORRECTION IS THE USEFUL PART.** A `.js`-ONLY
  package is fail-closed: candor-ts exits **2** with "no TypeScript sources under .". The hole opens only
  once at least one `.ts` file exists — i.e. exactly the mixed/gradual-migration repo that is the norm in
  that ecosystem, and never in the toy case someone would use to sanity-check the tool. Do not file this
  as "candor-ts ignores .js"; it does not, until it has a reason to look like it is working.

  The line is drawn INCONSISTENTLY inside one engine, which is the tell: a `.ts` file that fails to PARSE
  correctly exits 2 with "a gate cannot be green over unanalyzed code", while a file that was never
  considered passes silently. Same package, same invisibility, opposite verdict.

  **The fix is the one already designed:** enumerate the package's source-file universe from the manifest
  and the filesystem (a glob, NOT the import graph — the import graph cannot see a file nothing imports,
  and `build.rs` is reached by cargo, not by `lib.rs`), and put every in-scope file the engine did not
  analyse into `unanalyzed`. Existing ⟨0.21⟩ machinery then makes a configured gate exit 2 with no new
  concept. Separately decide, per engine and explicitly rather than by omission: `build.rs`, `tests/`,
  `examples/`, `.js` under `allowJs`, and non-Swift sources in a Swift target.

  Four engines plus a spec sentence, so it wants a rung and a conformance PART — filed rather than
  patched. **This is the highest-value item on this list**: it is the one class where the product's
  central promise ("never a silent false clean") is measurably untrue on ordinary inputs.

- **[SHIPPED 2026-08-06 — ⟨0.27⟩ SPEC §4, four-way, conformance PART 32] A policy rule that matches ZERO
  functions passed silently, and `unverified` then called the layer "PROVABLY clean".**

  Found by a usability review; reproduced in candor-rust, candor-swift, candor-ts AND candor-java (it did
  not differ). Now DISCLOSED in all four, with the verdict and exit code deliberately unchanged — a
  zero-match rule is legitimate when one policy is shared across repositories. A scopeless `deny` is
  exempt: it binds every function by construction, so it can never be this typo. Kept for the record;
  the original write-up follows. A one-character typo in a LAYER name turned a failing gate green:

      deny Net orders   →  exit 1   (the real layer; a genuine violation)
      deny Net ordrs    →  exit 0   "candor-query gate: policy ✓"
      candor unverified --policy <that>
                        →  "every function in a pure/deny layer is PROVABLY clean (no Unknown holes) ✓"

  **The asymmetry is the tell.** A typo'd EFFECT token is loud — `deny Netz orders` exits 2 with
  "names no known effect (accepted: Clipboard, Clock, Db, …)" and refuses to evaluate. A typo'd LAYER
  token binds nothing and is scored as satisfied. Same file, same rule, opposite treatment.

  This is the cardinal sin at GATE level rather than at report level: not a silent under-report by the
  analyzer, but a silent PASS by the thing users actually act on, wearing a "provably clean"
  endorsement. A team can hold a permanently green gate over a typo and never learn.

  **THE FIX IS DISCLOSURE, NOT REFUSAL, and the spec already says so.** Exit 2 would be wrong: a
  zero-match rule is legitimate when one policy is shared across repos or modules and a layer exists in
  only some of them. But silence is also wrong. ⟨0.24⟩ §3.1 already rules that **an unanswerable
  condition must be DISCLOSED, never scored as a satisfied one** — a rule that binds nothing is exactly
  an unanswerable condition, so this is that rule applied to the policy layer rather than a new concept.
  Minimum: report each rule's match count and name the zero-match rules in the verdict. The
  machine-readable verdict (`--gate-json`) needs it too, or a CI consumer is in the same position.

  Four-engine + spec-text work, so it wants a rung and a conformance PART rather than four local
  patches — that is why it is filed rather than fixed on the spot.

- **[P1 — DESIGNED AND UNBUILT; THREE items now wait on it, across two ecosystems] Value provenance —
  and it has TWO AXES, only one of which was designed.**
  `candor-spec/VALUE-PROVENANCE-DESIGN.md` recovers a value's concrete TYPE (which `newType` reaches a
  call — the primitive for dispatch). Measuring candor-swift against Apple's key list on 2026-08-05
  surfaced a second question that nothing covers: **which CONSTANT is this** — which literal or enum case
  reaches an argument. A `String` is a `String` whichever folder it names, so the type axis cannot answer
  it, and two unrelated features are blocked on the same missing primitive:
    · **five Apple privacy keys** (Desktop/Documents/Downloads/removable/network volumes) — the same
      `FileManager` call needs a different key, or none, depending on a path;
    · **the consumer half of Android permissions** — the same `ContentResolver.query` needs a different
      permission depending on a URI constant, which is why Google annotates *zero* of that surface.
  Designed 2026-08-05: `candor-spec/CONSTANT-PROVENANCE-DESIGN.md`. Key decisions: resolve to path/URI
  **classes** rather than reconstructed strings (a proved prefix decides the class, the unknown tail is
  irrelevant — no string solver); an undetermined value is a **disclosed third state with a count**,
  never charged to every key (fabrication) and never silent (the cardinal sin); a five-rung ladder where
  rungs 1–2 need no dataflow at all. The primitive is FLOOR, the class→key tables stay in the extensions.


  Design: `candor-spec/VALUE-PROVENANCE-DESIGN.md`. Tom's "absolute best product" call (2026-07-19):
  dissolve the source/sink trade-off by recovering a value's CONCRETE ORIGIN across construction and
  fields, interprocedurally — so a report can say not just *this function writes a file* but *it writes
  the file whose path came from here*.

  **FILED 2026-08-05 BY AN AUDIT, AND THE REASON IT WAS MISSING IS THE POINT.** It had a design doc, a
  named priority from Tom, and two items depending on it — and it appeared in no BACKLOG.md in any repo,
  in any form, except as a *sequencing reference inside another entry*. The Android permissions item was
  filed on 2026-08-04 saying "sequence it AFTER value provenance"; the thing it sequenced after did not
  exist as an item. **A dependency was created without filing the dependency.** A P-level scan — which is
  how the next task gets picked, per the audit note at the top of this file — could not see it, and the
  two items pointing at it are both P3, so the whole cluster reads as low priority when the blocking item
  is the high-value one.

  Two independent motivations, which is the strongest signal on this board:
    · the ORIGINAL one — sharper answers everywhere, without trading source fidelity for sink fidelity;
    · **Android permissions** (measured 2026-08-05, see below): the consumer-privacy half of Android's
      API→permission mapping is URI-dispatched through `ContentResolver.query(uri, …)`, so it needs the
      concrete URI constant that reaches the call. That is exactly this feature.

  Nothing here is measured yet beyond the design. First step is to re-read the design against the current
  engines — it predates several rungs (`typeSurface`, the completeness manifest, `resolves`) that may
  change what it needs to carry.

- **[OPEN — P3, and the measurement REFRAMED it: blocked on value provenance, not on a table] An
  Android/JVM analogue of the privacy manifest.**
  Raised by Tom 2026-08-04, off the back of `privacy/2`. The shape transfers exactly: code reaches a
  permission-guarded API → `AndroidManifest.xml` must declare `<uses-permission>` → verify, three outcomes
  (under-declared exit 1 · over-declared ⚠ · unreadable exit 2). It would be a **candor-java extension**
  (`permissions/1`), NOT an extension of `privacy/2` — `NSCameraUsageDescription` and
  `android.permission.CAMERA` are different objects and unifying the vocabularies would fabricate. What is
  shared is the shape, not the terms.

  **THE ONE MEASUREMENT THAT DECIDES WHETHER THIS IS WORTH DOING, and it is an hour's work.** The whole
  case rests on Android publishing the API→permission mapping that Apple does not: the framework annotates
  guarded APIs with `@RequiresPermission("android.permission.CAMERA")`, which is what Android Lint's
  `MissingPermission` consumes. If candor-java reads those, the uncovered set becomes ENUMERABLE — you can
  state which framework methods carry no annotation — instead of a curated table where whatever you forgot
  is silent. That is the difference between a disclosed blind spot and the cardinal sin, and it is the
  weakest part of `privacy/2` (`PRIVACY_SDK_TYPES`, 50 hand-written entries, verified by nothing).

  **MEASURED 2026-08-05** (Tom: "install an android sdk and do the measurement"). SDK installed via
  `brew install --cask android-commandlinetools`, platforms 30 and 36; script kept at
  `scripts/android-permission-coverage.py` because the answer MOVES with API level. The three questions,
  answered:

    1. **`platforms/android-NN/data/annotations.zip` — an XML sidecar, NOT the bytecode.**
       `@RequiresPermission` appears ZERO times in `android.jar` while Nullable/NonNull/Deprecated survive
       on the same classes (LocationManager retains 37 annotation attributes and has no constant-pool entry
       containing "permission"). candor-java is a bytecode engine, so consuming this is a STRING JOIN
       between an ASM method ref and a key like `"android.location.LocationManager android.location.Location
       getLastKnownLocation(java.lang.String)"` — whose generic forms (`java.util.List<…>`) do not appear in
       erased descriptors at all. That join is precisely the key-collision fabrication class this project
       has been bitten by four times. It is doable; it is not free, and it is not the clean read I assumed.
    2. **46% at API 36 (19/41 dangerous), 17% at API 30 — and ~37% once artifacts are removed.** Four of
       the 19 are not real coverage: READ_CONTACTS and WRITE_CONTACTS are annotated ONLY on
       `E2eeContactKeysManager` (an encrypted-contact-keys corner, not how any app reads contacts), and
       ACTIVITY_RECOGNITION and UWB_RANGING only on a `ServiceInfo.FOREGROUND_SERVICE_TYPE_*` CONSTANT,
       which is not a callable API. **The headline number flattered itself and inspecting the sites is what
       showed it.**
    3. **20.1% `conditional=true`, 23.0% anyOf/allOf, 60.6% single-permission and unconditional.** One in
       five carries an explicitly unanswerable condition (up from 6.2% at API 30) — spec 0.24 §3.1 says
       disclose those, never score them, so a fifth of the mapping produces a disclosure and not a verdict.

  **THE FINDING THAT CHANGES THE SHAPE OF THE WORK: there are ZERO `@RequiresPermission` annotations on the
  entire ContentResolver/ContentProvider surface.** Contacts, calendar, call log, SMS content, media and
  storage are not guarded by a distinctly-named method — they are guarded by the CONTENT URI passed as an
  argument. `ContentResolver.query(CalendarContract.Events.CONTENT_URI, …)` needs READ_CALENDAR; the SAME
  method with a different URI needs READ_CONTACTS. No method annotation can express that, which is exactly
  why every one of those permissions is missing from the mapping. Where the annotations DO cluster is the
  system/connectivity surface: bluetooth 144, telephony 125, device-admin 96, wifi 37, location 34.

  **So this is not "another curated table" — it is a VALUE-PROVENANCE problem, and candor already has that
  feature designed and unbuilt** (`candor-spec/VALUE-PROVENANCE-DESIGN.md`, the interprocedural
  value-origin recovery Tom called the "absolute best product" call on 2026-07-19). The Android permission
  gate is a second, independently-motivated application of it: recover which URI constant reaches
  `query()`, and the consumer-privacy half of the mapping falls out. **Sequence it AFTER value provenance,
  not before** — built first, it would cover bluetooth and telephony well and be silent on contacts and
  calendar, which is the wrong half for a privacy story.

  Two further constraints the measurement produced, neither of which I would have guessed:
    · **The mapping is a moving target.** API 30 → 36 went 130 → 922 annotated members, 44 → 187
      permissions, and DROPPED three (BLUETOOTH, BLUETOOTH_ADMIN, READ_EXTERNAL_STORAGE). An
      implementation must read the annotations for the project's OWN compileSdk, never bundle a snapshot.
    · **Lint as an oracle is unconfirmed.** I could not find a URI→permission table in the shipped
      cmdline-tools jars, but those are thin classpath manifests, so that check is INCONCLUSIVE — not
      evidence that Lint lacks one. If Lint does handle content URIs, its mechanism is worth reading before
      building anything.

  **Original filing kept below, because two of its assumptions did not survive** — I expected the
  annotations to be readable from bytecode (they are not) and treated high coverage as the likely case (it
  is 37% and skewed away from the privacy surface).

  **So measure BEFORE designing, and be aware nothing below is measured yet** — there is no Android SDK on
  this machine and no Android corpus (uflexi is a Tomcat webapp; `local.properties` is a plain Gradle
  convention and misled me into thinking otherwise). The questions, in order:
    1. Where do the permission annotations actually live in a CURRENT SDK — `platforms/android-NN/data/
       annotations.zip`, `@RequiresPermission` retained in `android.jar` bytecode, both, neither? I do not
       know, and the packaging has changed over the years. **Do not design around an assumed answer.**
    2. Of the ~30 dangerous permissions, how many are reachable from an ANNOTATED API? High coverage ⇒ this
       is mostly plumbing onto machinery that already exists. Low ⇒ it degenerates into another curated
       table and is far less attractive than it looks.
    3. What fraction of annotations are `anyOf` / `allOf` / `conditional=true`? A `conditional=true` is
       literally spec 0.24 §3.1's unanswerable condition — **disclose it, never score it as a failed one.**

  **Where Android is HARDER than iOS, and where the product probably is.** The effective manifest is MERGED
  from the app plus every AAR dependency, so a library can add a permission you never wrote. Verify against
  the source manifest and both directions break. Verify against the merged one and you get the pass/fail —
  but the answer worth selling is **which permissions came from a dependency, and what code justifies
  them**. That is the declaration-side mirror of the pollen finding (Contacts reaching the iOS binary
  through a shared module), and it is where Lint is weakest: strong intra-module, weak across dependency
  boundaries — exactly where chained dep reports work. Second hazard: `maxSdkVersion` / API-level
  conditionality (`WRITE_EXTERNAL_STORAGE` capped at 28, permissions that changed meaning across levels). A
  verdict that ignores API level is wrong; the same disclose-don't-score rule applies.

  **Where it is EASIER.** Bytecode beats source parsing for reach, so candor-java starts ahead of
  candor-swift. And unlike iOS there is an EXISTING ORACLE — Lint's `MissingPermission` — so this is
  measurable the way the rest of the project is: differential against Lint, expecting agreement
  intra-module and candor finding what Lint cannot across module boundaries. A measured claim, not a
  marketing one.

  **One naming decision this forces, worth taking before a second instance hardcodes it.** "Reach → required
  declaration → verify against a manifest" now has three plausible instances: Info.plist (SHIPPED as
  `candor privacy-manifest`), AndroidManifest.xml, and browser-extension `manifest.json` permissions on
  candor-ts. If the general verb is `candor manifest --verify <file>` with a per-platform vocabulary, then
  `privacy-manifest` wants to become an alias — cheap now, and cheapest of all BEFORE the privacy case study
  is published naming the current verb. See `candor/docs/case-study-privacy-manifest.md` (draft, unpublished).

- **[CLOSED 2026-08-03 — all four batches; see the body for what the source refuted] Ledger-mined classifier breadth** (data from the 2026-07-14 four-ecosystem sweep):
  **BATCH 1 DONE 2026-08-03 (candor-rust `c9b6941`): crossterm + ratatui, both `Ipc`.** And the filing was
  WRONG about ratatui: it said "mark reviewed-pure", but ratatui-0.29.0's `Terminal::draw`/`flush`/`clear`
  end in a backend flush and `backend/` writes to the terminal — marking the crate pure would have claimed
  purity over the one API that writes. Verified against the crate source in the local cargo registry, not
  argued. The render surface (widgets/layout/buffer/style — where the bulk of the 3,345 calls live) IS pure
  and is now covered rather than disclosed. `Ipc` because the tty is a user dialogue channel, the ruling
  dialoguer/console already carry.
  **THE DURABLE LESSON FOR THE REST OF THIS BATCH: calibrating a crate INVERTS the default.** An unmatched
  path stops being a disclosed blind spot and becomes a PURITY CLAIM — so "reviewed-pure" must mean
  *someone read the source*, and every remaining candidate below needs the same treatment ratatui just got.
  **BATCHES 2–4 DONE 2026-08-03 — the item is CLOSED except for one crate.** rust: `REVIEWED_PURE_CRATES`
  (a NEW mechanism — `CALIBRATED_CRATES` requires a live rule, so a pure crate cannot go there) covering
  serde_json / serde_yml / toml / regex / sha2, each checked against its registry source where every
  apparent I/O hit was a doc comment (`32cfb8c`); `tracing_subscriber` → Log + Env (`6916a24`). jvm: S3
  transfers naming a local File → Fs co-emitted beside Net (`9122c64`); commons-io needed NOTHING, it
  already carries the source/sink descriptor stance.
  **THREE OF THE FILING'S CLAIMS DID NOT SURVIVE READING THE SOURCE:** ratatui is not pure,
  tracing_subscriber has no Fs, and commons-io was already done. **`color_eyre` CLOSED 2026-08-03 by fetching and checking it: it is NOT pure** — reads
  RUST_BACKTRACE/RUST_SPANTRACE/COLORBT_SHOW_HIDDEN (Env) and `File::open`s SOURCE FILES to render code
  snippets (Fs, `config.rs:248`). **Four of the filing's claims did not survive the source.** It is also
  deliberately NOT calibrated: the file read sits in `impl fmt::Display for SourceSection`, reached when a
  report is rendered rather than via any named verb, so no rule can match it — and calibrating would turn
  that render path into a purity claim. Its calls stay disclosed. **THE ITEM IS NOW FULLY CLOSED.**
  **THE DURABLE DISTINCTION, needed three times in one batch:** a library moving bytes through a handle
  the CALLER opened is not charged (the caller's `open` carries it) — but `new java.io.File(path)` opens
  nothing, so an SDK that writes it IS the only place the Fs lives. Same-looking shape, opposite ruling,
  decided by what the caller actually does.
  Original filing, kept because the correction is the point: mark
  ratatui/serde_json/serde_yml/toml/regex/sha2/color_eyre reviewed-pure (ratatui alone is
  3,345 disclosed calls across three real repos — the single loudest noise source) and CLASSIFY
  crossterm (terminal I/O) + tracing_subscriber (Log/Fs); jvm — classify the AWS SDK surfaces
  (S3 → Net/Fs, SES → Net; uflexi's top uncovered) + commons-io → Fs; swift — the uncovered list is
  the privacy cluster's fixture set (falls out of P1); ts — sweep came back fully covered.
  Practice: batch by ledger call-count, never speculative.

### New-capability bet — a possible commercial add-on

- **Supply-chain effect diff (productize `gains`).** The `gains` query already computes "effects a
  dependency surface gained across versions." Productized — "your bump of lib X added `Net` to a function
  that was pure" — this is capability-level dependency diffing, distinct from CVE matching, and something
  candor is uniquely placed to do (it already has per-function effects). Net-new (not mined-out); could
  stand as its own wedge / landing page. **Business model (Tom, 2026-07-01): appealing enough to consider as
  candor's first _commercial, closed-source add-on_** — a paid layer over the open `gains` primitive.
  candor's engines are fully open source, so a closed paid layer is a deliberate business-model departure
  (the open engines stay the credibility base; this rides on top), flagged as such.
  **PROTOTYPE — PHASE 0 BUILT 2026-07-10 (`~/git/candor-gains`, local only — NOT a public repo).**
  A version-pair driver (`candor-gains.mjs`) over BOTH ecosystems: npm (`npm pack` → candor-ts
  `--allow-js`) AND the differentiated JVM path (Maven Central jar → candor-java, no bundler noise).
  Tiers the delta — ⚠ boundary capability gained (exit 1,
  gate-able) / △ unresolved surface grew (bundler/dynamic) / · cross-cutting (informative). Two working
  exhibits: a deterministic offline synthetic (`greet` 1.0.0→1.1.0 adds an `https.get` phone-home →
  ⚠ Net in `greet`+`track`, via `./run-demo.sh`) and a REAL true-positive (`node-fetch 2.6.6→2.6.7`, the
  CVE-2022-0235 redirect fix → ⚠ Net in `finalize`/`abortAndFinalize`; control `ms 2.0.0→2.1.3` → clean).
  Prototype findings feeding productization: (1) bundled dist reads as Unknown — prefer un-bundled source;
  (2) `gains` alone is too blunt — it can't tell "a function that shipped PURE now does Net" (the
  attack) from "a new function does Net" (a feature) because reports omit pure fns; the driver fixes
  this by keying existence on the CALLGRAPH (⚠⚠ existing-code-gained vs ⚠ new-function tiers) — a
  candidate improvement to open `gains`/`diff` too **(DONE 2026-07-13, spec 0.12 staged: `gains --json`
  byFunction entries carry `origin: existing|new|unknown` in ALL FOUR engines — swift gained the whole
  verb — keyed on the baseline callgraph, pinned by conformance PART 5b; the driver can now consume
  `origin` instead of computing existence itself)**; (3) adjacent bumps are clean, large spans are
  refactor churn (→ watch releases incrementally); (4) the corpus==cache retains report+callgraph
  (the moat seed); (5) the exit-1 ⚠⚠ alarm is a CI gate / registry-watcher trigger.
  **STRATEGY (Tom, 2026-07-10): run it as a marketing WEDGE, but don't miss a SaaS if one surfaces.**
  The SaaS (if real) is NOT the diff tool (copyable, npm-crowded — Socket owns that) — it's the
  always-on/stateful/compounding layer a CLI structurally can't be: **continuous monitoring over an
  accumulated cross-language effect-history CORPUS**, JVM-first (no incumbent has a head start there).
  Full build spec: `candor-gains/PRODUCT-SPEC.md`. The one architectural commitment made now:
  **the cache and the corpus are the same store** — the wedge retains every scan (exhaust = moat seed;
  cheap now, expensive to retrofit). Phasing with decision gates: **P0 DONE** (JVM/Maven driver + corpus
  store — the differentiated path); **P1 DONE 2026-07-10** — `candor.poly.io/gains/` demand-probe landing
  page (`~/git/web` src/candor/gains, JVM-led exhibits + a "watch, don't just check" waitlist via
  pre-filled labelled GitHub issues, 3 ecosystem variants = the signal; no backend, no third-party;
  third door on the candor index; label `gains-waitlist` on tombaldwin/candor = the count). **GATE 1 NOW
  OPEN (Tom's, evidence-based):** do waitlist issues arrive, and are they JVM/enterprise (defensible →
  build P2) or npm-only (wedge only → stop)? **P2** (only past Gate 1) the live runner + continuous-
  monitoring service on the already-accruing corpus → GATE 2 (the commercial decision, priced to pull).

### Disclosure-refinement track (opened 2026-07-16 — from the academic referee pass)

- **[P2 — needs EVIDENCE, opened 2026-08-07] `PHPickerViewController` probably requires no photo-library
  usage key, and candor says it does.** Found on Kingfisher in a corpus pass.

  `Classifier.swift:464` maps `PHPickerViewController` → `Photos`, and `Photos` requires
  `NSPhotoLibraryUsageDescription`. Kingfisher's iOS demo reaches it via
  `PHPickerResultViewController` and declares that key NOWHERE in the repository — no plist, no
  `INFOPLIST_KEY_`. So either the demo has shipped broken for years, or candor is over-reporting.

  **The strong prior is that candor is wrong**: PHPicker is the out-of-process picker introduced
  precisely so an app can let someone choose photos WITHOUT photo-library authorization, and Apple's own
  page describes it as rendered by the system on top of the app. That is the same shape as the
  `CMMotionManager` over-report fixed 2026-08-06 — an API in a covered framework that does not itself
  require the key.

  **But the evidence that settled CMMotionManager does not transfer, which is why this is recorded and
  not fixed.** That one was decidable because Apple's `NSMotionUsageDescription` page NAMES exactly four
  APIs. The `NSPhotoLibraryUsageDescription` page names none — its JSON contains zero symbol references
  — and neither `PHPickerViewController`'s page nor `PHPickerConfiguration`'s contains a citable
  "requires no authorization" sentence. Fixing a classifier on recollection is how the first
  CMMotionManager mapping got there.

  **What would settle it**: the WWDC20 "Meet the new Photos picker" session, Apple's privacy
  documentation for the picker, or an empirical check (a minimal app using only PHPicker, archived and
  submitted). If confirmed, the fix has the `MotionRaw` shape — a keyless effect, so the REACH is still
  reported and the manifest requirement is not — never dropping the effect, which would trade an
  over-report for silence.

- **[P1 — CARDINAL SIN, re-graded 2026-08-22. WAS filed as a P2 count discrepancy; it is a FALSE GREEN.]
  `gate --report` MERGES MEMBER REPORTS BY BARE `fn`, and SPEC §2.2 already forbids exactly that.**

  **REPRODUCED with matched candor-scan/candor-query 0.31.0:**

      gate --report <a>        -> exit 2   (correctly refuses the scoped rule)
      gate --report <a and b>  -> exit 0   "policy ✓"

  **Adding an unrelated sibling report turns a refusal into a certification.** The filter reads the
  SIBLING's Unknown-class set through the name join, sees a class the rule does not deny, and tolerates.
  The same join was also measured FABRICATING a violation — `a::main` charged with a class it inherits
  from `b::util` purely by name. Needs a foreign or degraded member report to reach (a self-produced
  rust set always carries the callee in `calls`, SPEC.md:1836-1838) — and §3.1 says the verb serves
  exactly those.

  **THE SPEC ALREADY SAYS SO.** SPEC.md:288-290: a consumer *"MUST join across reports by `hash`, never
  by bare `fn` (names may legitimately repeat across packages)"*. candor-query violates it at
  gate.rs:148 + `report_signature` (gate.rs:380-434), which keys NINE accumulators by bare `fn` — its
  own comment calls a duplicate key "malformed input", which is false on a workspace. candor-ts is
  identical (query-core.mjs:787+, policy.mjs:53-91).

  **THE FIX IS OPTION E: key the merge and the fixpoint by entry `hash`**, surface that identity on the
  verdict row, and extend the shared serializer sort — `(rule, detail)` at candor-report/src/lib.rs:1067
  ties between the twin rows, and the two routes insert in different orders, so without it byte-equality
  re-breaks exactly as ⟨0.31⟩'s `outOfScope` did. candor-sarif also fingerprints on `fn|rule|effects`
  (integrations/github/candor-sarif:227-233), so one GitHub alert currently hides the other.

  **THE CONSTRAINT THAT DECIDES THE IMPLEMENTATION, found 2026-08-22 and not in the review.** `hash` is
  `package#fn` (`grep_pcre2#matcher::RegexMatcher::new`), but a report's `calls` array names its callees
  by BARE `fn` (`matcher::RegexMatcherBuilder::build`). So keying the NODES by hash does not key the
  EDGES: the call graph would still join by name one layer down, and the fabrication and the false green
  come back in a form that is harder to see, because the node table would look correct.

  A merge therefore has to resolve each report's `calls` to hashes WITHIN that report — trivial for a
  same-package call, since the package is the report's own — and then decide the case that has no
  answer today: **an edge that LEAVES the package.** Its callee is not in this report, so the name can
  only be matched against sibling reports, and if two siblings both declare that name the edge is
  genuinely ambiguous. That is where the ladder has to be defined, and the safe rung is to DISCLOSE the
  ambiguity and fail closed rather than pick one — picking is what the current code does implicitly.

  Worth noting the current behaviour is not merely unsound, it is unsound in BOTH directions: a
  cross-package edge that happens to resolve to the right sibling works by luck, and one that resolves
  to the wrong same-named function invents a reach. Neither is distinguishable from the outside.

  **PROTOTYPED 2026-08-22 — THE FIX WORKS AND IS NOT A KEY CHANGE. Reverted, with what it taught.**
  Keying the merge by `hash` and resolving each report's `calls` against its own package (falling back
  to a UNIQUE declarer across the set, and leaving an ambiguous cross-package name with NO edge) CLOSED
  the false green: `a` alone exits 2 and `a` beside the sibling now also exits 2, where it had exited 0.

  It broke two other things, and both are the actual work:
  · **`fn` in the verdict row became the KEY.** The gate route emitted
    `regex_cli#cmd::generate::run` where the scan route emits `cmd::generate::run`, so §3.3.1 byte
    equality broke in the other direction. The row needs the DISPLAY name plus identity as a separate
    field, on BOTH routes — which is the half of option E that has to reach the scan route too, not
    only the merge.
  · **`all` also feeds POLICY SCOPE MATCHING**, so hash-keyed names would stop `deny Exec app::`
    matching `pkg#app::…` — a FALSE GREEN introduced by the false-green fix. That is the shape
    [[feedback-fabrication-fixes-cause-misses]] names, caught here only because the byte-equality
    comparison was run immediately.

  So the structure the port needs is (hash, name) PAIRS through the merge: hash for identity and the
  join, name for scope matching and display. Not a key swap.

  **THE OTHER HALF OF WHY UNION IS WRONG, and it is not "names collide".** The measured false green was
  not two functions' effects merging. `a::main` had an `Unknown` with NO reachable reason — UNANSWERABLE,
  so the gate refused. The sibling gave that NAME a reason (`callback:` → class indirect), the filter
  saw {indirect} ∌ dispatch, and tolerated. **Union is safe for EFFECTS and unsafe for REASONS**: adding
  effects can only add violations, but adding a reason converts "I cannot say" into "I checked, it's
  fine". Same shape as [[candor-unanswerable-key]], one level up — which is why an ambiguous edge must
  contribute NOTHING rather than the union of its candidates.

  **THE OBSTACLE, to resolve deliberately:** SPEC.md:1919-1923 classes `hash` as a DECORATION that
  "carr[ies] no claim a verdict reads". Option E requires a verdict to read it. That clause must be
  re-scoped for the multi-report route before E can be implemented honestly.

  **THREE OPTIONS THAT LOOKED REASONABLE AND ARE NOT.** Recorded because each fails for a different
  reason worth remembering:
  · **dedupe in the scan route** — cheap, and leaves the fabricating merge in place.
  · **qualify `fn` with the crate** — does NOT restore per-function identity. MEASURED: one crate with
    an inherent `impl A { fn go }` and an `impl T for A { fn go }` emits TWO entries, both `fn: "A::go"`
    and both `hash: "ti#A::go"`, already unioned by the scan. `fn` is not unique even within ONE report.
  · **put `package` on the verdict row** — my own recommendation, and unsound. It stamps identity on the
    fabricated row rather than preventing it, and it is ill-defined on the REFERENCE engine: candor-java
    emits plural `packages` (one report spans several), so "the report's package" is not single-valued.
    The per-entry `hash` prefix is single-valued in all four.

  (original filing) The ⟨0.24⟩ byte-equality MUST fails on a multi-crate WORKSPACE: two
  same-named violating functions merge into one on the `gate --report` route.

  SPEC §3.3.1 requires `gate --report <it> --policy P` to produce a verdict BYTE-EQUAL to
  `scan --policy P`'s. Measured over 43 real projects (9 rust, 9 ts, 17 swift, 8 java jars): **41 are
  byte-equal**. The two that are not are both cargo WORKSPACES, and both fail the same way:

      rustls   scan 57 violations · gate --report 56    (`main`, present in several binaries)
      zellij   scan 23 violations · gate --report 22    (`commands::web_server_status`)

  The violation SETS are identical; the counts differ because the live scan emits two byte-identical
  rows and the report route emits one. The rows are byte-identical because `fn` carries no crate
  qualifier — so two DISTINCT violating functions in two crates are indistinguishable in the verdict,
  and the report route collapses them.

  **MINIMAL REPRO, 2026-08-21 — it is six lines, not a big project.** The filing rested on rustls and
  zellij, which made it look like something exotic in a large workspace. It is not:

      Cargo.toml   [workspace] members = ["a", "b"]
      a/src/main.rs   fn main() { Command::new("curl")... }
      b/src/main.rs   fn main() { Command::new("curl")... }     # byte-identical

  `deny Exec`: scan emits TWO `main` rows, `gate --report` emits ONE. Both exit 1, so the verdict AGREES
  and only the count differs — which is exactly why it survived: every gate keys on the exit code and
  none on the document. (Same lesson as [[candor-refuse-before-envelope]].) A fixture this small belongs
  in the conformance suite whichever way the ruling goes, because it is the smallest program that can
  tell the two readings apart.

  **Which side is right is the question.** If they are two functions, the report route UNDER-REPORTS the
  number of violating sites — a fix list one short. If the verdict is meant to be a set of violating
  NAMES, the scan route double-counts. Either way the two routes disagree about a real repository, which
  is what the MUST exists to forbid.

  Same shape as [[candor-global-unit-identity]]: same-named units merging because the key is not
  qualified. That one was closed for the report's `functions`; the VERDICT's `fn` was not part of it.

  **Why conformance did not catch it**: every gate fixture is a single crate/package, so the collision
  cannot arise. The differential that found it is a corpus pass, not a fixture — worth a conformance row
  with a two-crate workspace whose crates share a function name.

- **[RESOLVED 2026-08-09, SHIPPED IN 0.27 — opened 2026-08-07] A configured dep that cannot be read: two
  engines refused, two continued. Found by the generative config differential, not by hand.**

  SPEC §2 ⟨0.27⟩ ruled for the refusing arm and all four engines now implement BOTH clauses of the MUST
  ("does not exist OR cannot be read"). rust and ts had shipped only the first; a release panel caught
  it by testing their own changelog claims. Conformance PART 35 rows (d)/(e) pin the second clause — the
  part's title had said "cannot be read" while its three rows only ever posed "not there", which is how
  a half-implementation passed a green suite for a release. Kept for that lesson.

  Measured with a real path dependency, so the fixture is diagnostic (an earlier one was not — a call to
  an undeclared crate is omitted with or without any dep config, which proves nothing):

      dep report chained    → caller `inferred: ["Fs"]`     ← the coverage the operator configured
      same config, report missing:
        java   exit 2   "a configured dep must not silently read pure"
        swift  exit 2
        rust   exit 0   caller `inferred: []` + a COVERAGE DISCLOSURE naming the uncovered dep
                        ("absent from the report, NOT a claim they're pure")
        ts     exit 0   caller absent from `functions`; only "CANDOR_DEPS entry unreadable, skipped"

  **⟨RESOLVED — SPEC §2 ⟨0.27⟩ ruled for the refusing arm, and all four engines now implement it.⟩** The
  measurement above is the state BEFORE that ruling; it is kept because the reasoning is why conformance
  PART 35 exists. rust and ts were corrected on 2026-08-09, when a release panel found they had shipped
  only the "does not exist" clause of a MUST whose sentence also says "or cannot be read" — rows (d) and
  (e) pin the other clause now.

  **Both postures were internally coherent, which is why this needed a ruling rather than a fix.** The
  refusing arm reads a configured-but-unreadable dep as the §6.2 configured-but-unusable case, like a
  policy that vanished. The continuing arm reads it as reduced COVERAGE, which is what the ⟨0.15⟩
  coverage envelope exists to qualify — and rust's disclosure says exactly the right thing. What is not
  defensible is the family disagreeing: one `.candor/config`, four engines, two answers.

  If the ruling goes to DISCLOSURE, ts needs rust's coverage line (its "skipped" note does not qualify
  the absence, so on that engine the caller's `inferred: []` stands unqualified — which IS the cardinal
  sin). If it goes to REFUSAL, rust and ts need java's exit 2. Either way it wants a conformance row:
  nothing in 34 parts covers a configured dep that is not there.

  **Provenance worth keeping**: this came out of `conformance/differential/config_grammar_run.py` on its
  first clean run — 2456 agreed, 90 diverged, 2 signatures, and this was one of them. Hand-written rows
  had not covered it in 34 parts.

- **[P1 — candor-swift, opened 2026-08-09] TWO EXTENSION MEMBERS OF THE SAME TYPE, DECLARED IN
  DIFFERENT MODULES, MERGE INTO ONE UNIT.** Found by `scripts/scope-monotonicity.sh` on a HELD-OUT repo
  (home-assistant/iOS) within minutes of the checker existing — the first thing either the property or
  the held-out corpus produced.

  ```swift
  // Sources/HANetworking/Sources/Guarantee+Additions.swift   (module HANetworking, imports PromiseKit)
  public extension Promise { func asyncValue() async throws -> T { … } }

  // Sources/App/Settings/Notifications/NotificationRateLimitView.swift  (module App, imports Shared)
  private extension Promise { var asyncValue: T { get async throws { … } } }
  ```

  Both key as `Promise.asyncValue`. A whole-repo scan reports ONE entry carrying the union of their
  hedges (`["PromiseKit", "Shared"]`), the accessor's `unitKind`, and the OTHER file's `loc`. A scan
  scoped to a target holding only one reports just that one's. They are two units: different modules,
  different kinds, and the App one is `private`, so it is not visible outside its own file.

  **Direction: FABRICATION, not silence.** A caller of either gets the other's effects, and the `loc`
  misattributes one of them. It does not block a release, and it is PRE-EXISTING — nothing to do with
  the per-file identity rung, which is how the property found it: the two runs disagreed, and the
  disagreement was the engine's, not the scope's.

  **Related, and why this is not a quick fix:** [[candor-global-unit-identity]] records that qualifying
  swift unit names by module was measured and reverted TWICE, because swift's units are keyed by bare
  name and every scoping refinement just changes which colliding declaration wins. This is that vein in
  a new shape — extension members rather than globals or free functions — so it wants the same care:
  measure the collision rate on real corpora before changing the key.

  **⚠ THAT ACCEPTANCE CRITERION IS ALREADY SATISFIED AND THE DEFECT IS UNTOUCHED.** It read
  "`scope-monotonicity.sh` on ha-ios goes from 12 violations to 0". It now reports 0 — because the
  whole-repo identity pass gives the App-module file its `Shared` claim in the UNSCOPED run too, so both
  runs agree and the discrepancy the property keyed on is gone. The merge is still there, verified after
  the change: ONE entry for `Promise.asyncValue` carrying `unitKind: "accessor"` from the App
  declaration and `loc: Sources/HANetworking/…` from the HANetworking one. A property going green
  because its observable vanished is not evidence, which is exactly why an acceptance criterion should
  name the DEFECT and not a symptom.

  **Acceptance, restated**: an unscoped scan of home-assistant/iOS reports TWO entries for
  `Promise.asyncValue` — or one per module — rather than one whose `unitKind` and `loc` come from
  different declarations.

- **[P2 — conformance, opened 2026-08-09] The exit-2 cause matrix is green where it is posed, and the
  unposed cells are now the whole risk.**

  0.27 took PART 36 from 3 stream rows to 17 and every cell it poses is green four-way. What is NOT
  posed, in priority order: **the gate-verb route** for most causes (rows cover the scan route plus
  b4/b5/b6); **candor-agents** for the causes it fails (see the P1 below); and the FILE-sink form of
  several causes where only the stream is posed. The two forms are not interchangeable — measured, an
  engine streamed a refusal correctly for an unreadable config while leaving a previous run's
  `{"ok": true}` on disk, and only a file-sink probe could see it.

  **Method that worked, and should be reused rather than re-derived**: enumerate the causes a user can
  TRIGGER (12), not the exit sites (25 in one engine, 30 in another); run each against both sink forms;
  write the row BEFORE the fix. Every defect that stayed fixed in 0.27 was caught by a row, not by a
  review. See the memory file `candor-027-release-lessons`.

- **[CLOSED 2026-08-10 — candor-agents] ~~Four~~ THREE exit-2 causes left `--gate-json -` EMPTY.**

  Fixed with ONE wrapper at the module entry (`_main_streaming_verdict`) rather than three patched
  sites, because the fourth cause nobody enumerated is the one that matters — measured the same day,
  when a generated argv sweep found an exit-2 cause absent from a hand-written list of twelve. The
  narrower copy inside `main` was removed rather than kept alongside it. Acceptance met in full: eight
  causes emit exactly one parseable refusal, `test.py` still 466/0, and conformance PART 36 gained rows
  (b4)/(b5)/(b6) which were PROVEN to fail against the pre-fix entry before being believed.

  Two things the fix turned up that outlive it: the conformance shim had been importing
  `scan.main` directly while the CLI runs the wrapper, so the agents rows were exercising a different
  program than anyone ships; and the count in this entry's own heading ("Four") disagreed with its own
  table ("three") — the measurement said three. **The heading was a claim, and nothing checked it**,
  which is the failure this file's 2026-08-05 audit note already describes.

  Original entry follows.

- **[was P1 — candor-agents, opened 2026-08-09] Four exit-2 causes leave `--gate-json -` EMPTY.**

  Measured against the other four engines, which all write a refusal document on the same inputs:

  | cause | agents | java / rust / ts / swift |
  |---|---|---|
  | nonexistent fleet path | **empty** | document |
  | unreadable `.candor/config` | **empty** | document |
  | engine pin not satisfied | **empty** | document |
  | unknown flag, valueless flag, unreadable/missing policy | document | document |

  The FILE sink is already correct for these (arming leaves a placeholder and the refusal replaces it —
  fixed earlier today). A stream has no placeholder, so it needs the write, and only the usage-error
  path does it. Two forms of one cause; one covered.

  **Not fixed, and the reason is worth recording.** An attempt tonight routed three of the four and
  broke a passing test: two string replacements matched the SAME site, duplicating a line and leaving a
  `raise` outside its guard, so ANY set `CANDOR_CONFIG` — readable or not — exited 2. Reverted; 466
  tests green. That is the second self-inflicted defect in this file in an hour, both from batch edits
  applied without re-reading the result. Do this one with a single deliberate edit per site and a
  measurement after each.

  **Acceptance**: the four rows above write a parseable refusal document, `python3 test.py` stays at
  466, and a conformance row poses the causes for the agents arm the way PART 36 (b16)/(b17) do for the
  other engines.

- **[SPEC QUESTION — opened 2026-08-09] Does §3.1's "MUST NOT print anything else to a stdout that
  carries a verdict" bind the SCAN route's `--json` too?**

  On the GATE verbs `--json` IS `--gate-json -` — the same document, so naming both is one artifact
  named twice, and that is now pinned by PART 36 (b6)/(b9)/(b10). On the SCAN route `--json` means
  something else entirely: write the REPORT to stdout. So `--json --gate-json -` there puts a report AND
  a verdict on one stream, which the sentence at SPEC.md:1872 appears to forbid.

  **Measured, all four engines, clean scan, `--json --gate-json -`:** rust 374 bytes, ts 353, swift 414,
  java 781 — every one of them TWO documents. This is not a divergence to fix; it is four engines
  agreeing on a reading the spec text does not obviously license.

  **So it is a spec question, and the row was NOT written.** A row asserting "exactly one document"
  would have gone red four-way on a behaviour nobody has argued is wrong; a row asserting the current
  behaviour would have pinned it before deciding whether it is right. Either would have been worse than
  the question. (This is the [[candor-theory-spec-verification]] hazard the other way round: last time a
  theory wrong in the STRICT direction produced a finding shaped like a code defect; here measuring
  first stopped the same mistake reaching a conformance row.)

  **To decide:** either scope the sentence to the gate verbs, where `--json` denotes the verdict — the
  reading the engines have implemented — or rule that the combination is a sink conflict and must be
  refused like a sink over an input, in which case four engines need the refusal and a row can pin it.

- **[SPEC QUESTION — opened 2026-08-09, NOT an engine defect] `coveredPkgs` is scan-global and
  name-keyed, and SPEC §2 rule 3 says it must be.**

  Every other conjunct of the disclosure predicate became per-file during the 0.27 identity rung. This
  one did not, and a review flagged it as "the one door through which a same-named module could be
  certified for a file whose target cannot link it". **It reproduces**, measured on the built engine:

  ```
  Root/Package.swift      declares NO dependencies
  Root/Sources/App/main   import Utils; func ship() { UtilsClient().send() }
  CANDOR_DEPS             a genuine report for an UNRELATED package that happens to be named Utils
  ```

  → `uncovered: []`, `functions: []`. `ship` absent under ⟨0.21⟩ is a purity claim over an unresolved
  SDK call, and one chained report for a package this code does not use produced it.

  **It is nonetheless the SPECIFIED behaviour**, and the engine is right: §2 rule 3 says "a coverage
  disclosure must treat EVERY package a loaded report covers as accounted for, even with zero joins",
  with no qualification about whether the consumer declares the dependency. A gate on "the file's target
  actually names this dependency" was implemented and **reverted**: 31 tests across the chaining suite
  went red, all of them pinning the contract correctly. Four engines implement rule 3 and conformance
  pins it, so changing it unilaterally in one engine would break the four-way suite — this is a spec
  rung or it is nothing.

  **The standing hazard this is an instance of** ([[candor-theory-spec-verification]]): a theory wrong in
  the STRICT direction produces a finding shaped exactly like a real code defect. Check which side the
  contract and the conformance suite are on BEFORE writing the fix; I wrote it first and read the spec
  second.

  **MEASURED 2026-08-09, and the measurement argues AGAINST the rung.** Every package of two real
  repos was scanned and chained, then the whole repo re-scanned:

  | repo | packages chained | files importing a covered package their target does not name |
  |---|---|---|
  | NetNewsWire | 17 | **0** — the strict gate would change nothing here |
  | IceCubesApp | 13 | **3** — `AppAccount`, `Env`, `MediaUI` |

  All three IceCubes cases are in SHIPPING code that builds: `Packages/Account`'s manifest declares
  NetworkClient, Models, StatusKit, Env, DesignSystem, ButtonKit and WrappingHStack, and
  `Sources/Account/AccountsList/AccountsListRow.swift` imports `AppAccount` regardless. So the strict
  gate would have DENIED coverage and disclosed all three — a false disclosure on code that compiles,
  which is reach lost for nothing. Zero gain on one repo, three losses on the other.

  **What shipped instead is the note** (⟨0.27⟩): where a covered package is imported by a file whose
  target does not name it, say so on stderr and change no answer. It found the three IceCubes cases,
  stays silent on NetNewsWire, and stays silent on the declared-dependency control.

  **If it is ever taken up anyway**, the discriminator that works is `declaredNames` (in-package targets plus
  product names, resolved or not) rather than `importable` — a chained dep is usually REMOTE, so it
  resolves to no local sources and is absent from `importable` by construction; gating on that would
  delete the feature rather than narrow it. The measured cost of the strict form is exactly the fixtures
  whose manifests omit the dependency their code imports, i.e. trees that do not compile.

- **[P2 — candor-swift, FOR 0.28, opened 2026-08-08, depends on the P1 below] A WHOLE-REPO scan of an
  `.xcodeproj` repo still names analyzed modules as blind spots, because no `--target` means no resolved
  closure.**

  **Measured** (NetNewsWire at its 2026-08-08 HEAD, whole repo — no `--target` — on branch
  `rung/per-file-module-identity` at `80d3c48`): 32 modules listed uncovered, **14 of them local packages
  whose sources are reported in that same run** — Account, ActivityLog, Articles, ArticlesDatabase,
  CloudKitSync, ErrorLog, HTMLMetadata, Images, RSCore, RSDatabase, RSParser, RSTree, RSWeb, Secrets.
  On main at `430c5ef` the same scan lists 35, so the branch already removes three; the remaining 14 are
  what this entry is for. The line printed about them says their effects are "INVISIBLE to the scan
  (absent from the report, NOT a claim they're pure)", which for those 14 is untrue: their functions are
  in the report. The other 18 are real (WebKit, CloudKit, Sparkle, Zip, the ObjC modules).

  **Test the membership properly.** An earlier count here said 15 and was arrived at by matching the
  module name against a path SEGMENT — which credits `Modules/Account/Sources/Account/CloudKit/` as
  proof that module `CloudKit` was analyzed. That is the same "a directory named like a module is not
  that module" sin the engine was fixed for, committed in the measurement instead of the code. The 14
  above are each confirmed by a `Modules/<name>/Package.swift` that exists AND a reported function whose
  `loc` begins `Modules/<name>/`.
  A list that is half wrong teaches the reader to skim it, and they then skim the 17 — which is how
  over-disclosure becomes under-disclosure without a line of unsound code. Precedent:
  [[candor-scan-guards]], where `net-partner` was reported "ignoring unknown config key" WHILE BEING
  HONOURED — "a FALSE disclosure, worse than a missing one".

  **The plan, and why it is not another inference.** `--target X` already fixes this (NetNewsWire iOS: 14
  uncovered, all true) because the resolver walks that target's local-package closure. The per-target
  evidence that walk needs now EXISTS — `XcodeTargetScope.filesByTarget` and `localPackageDirsByTarget`,
  landed on the branch — so step 3 below is a lookup rather than a new inference. The whole-repo case
  needs the same thing N times, not something new:
  1. enumerate the project's targets — the resolver already does this for the unknown-name refusal
     (8 on NetNewsWire, verified);
  2. resolve each target's scope, which also yields its FILE list and its `localPackageDirs`;
  3. map each analyzed file to its owning Xcode target, and give it that target's importable set.
  Verified premise: the closures genuinely differ per target — NetNewsWire's iOS app resolves 17 local
  packages, its Widget Extension resolves 3 (`RSCore`, `RSParser`, `RSWeb`). So a union over targets
  would be WRONG, and per-target is the whole point.

  **Do NOT take the shortcut of unioning every target's closure.** It is one line and it re-opens the
  class that produced ten silent under-reports: a file in the Widget Extension importing something only
  the app links would be claimed internal on evidence that does not apply to it.

  **A second, closely-related case, found reviewing the branch (2026-08-08), STILL OPEN and re-measured
  at `80d3c48`:** even WITH `--target`, an Xcode target's own module identity can never be claimed,
  because `analyzedModules` and `importable` speak only SwiftPM target names. Measured on
  `firefox-ios --target Client`, whose closure scans ELEVEN Xcode targets: `Storage` is named "INVISIBLE
  to the scan" against 112 imports while **332 of its functions are in that same report**; `Account`
  (20 imports / 3 reported) and `Sync` (2 / 5) the same. Same false
  disclosure, same fix family — the resolver knows each Xcode target's file list, so an Xcode target is
  a module whose sources are exactly those files. Do it in the same pass as the whole-repo case above.

  **A THIRD case — CLOSED 2026-08-08 on the branch (`431c1f6`, hardened by `ef53a2a`).** Kept here
  because the reasoning under it is the template for the two cases above, which are still open. The
  `.xcodeproj` arm's evidence was CLOSURE-keyed while the question is TARGET-keyed.
  `XcodeTargetScope.localPackageDirs` is a flat union over every closure member, and `Driver.analyze`
  gives every ownerless file `exposed(by:)` over all of it — so a file in target T inherits a claim
  justified only by sibling target S's link. Measured on a buildable mixed-dependency shape: App links
  `Lottie.xcframework` (binary, never analyzed) while a sibling embedded framework links a local package
  exposing a target named `Lottie`; App's `import Lottie` went silent on BOTH channels, and the SCOPED
  scan was more silent than the unscoped scan of the same tree — which both scoping headers forbid.

  **Do not patch the manifestation** — and this is what was done. The obvious narrow fix — let a same-name binary in the file's own
  target's frameworks phase refute the claim — covers one shape of a general defect, and patching
  manifestations is what produced six cardinal sins on main. The correct fix is per-target evidence the
  pbxproj already carries: the resolver must record files-by-target and linked-packages-by-target, and
  the driver must ask "what does THIS FILE's target link", not "what did the closure link". That is
  resolver surgery (`XcodeTargets.swift` accumulates both flat today, inside `for tid in closureIds`),
  not a driver tweak.

  Note the scoped NetNewsWire result (14 uncovered, all true) comes from this arm, so it cannot simply
  be dropped: without it an `.xcodeproj` repo claims nothing and every local package it depends on is
  named a blind spot. (An earlier draft wrote that as a "31 → 14 win". 31 does not reproduce against
  today's corpus — the whole-repo figure is 35 on main — and it was a different invocation from the 14.
  A number recorded without its command or its date decays into a claim nobody can check.)

  **What landed, and the two defects found IN the fix** (both by measuring, neither by reading): per-file
  attribution first read each target's files as the GROWTH of a shared set, which credits only whichever
  target ran first wherever two targets compile the same file; and the per-target link list was first the
  DIRECT links, when Xcode puts the whole reachable package graph on a target's import path — that named
  `RSParser`, `Articles` and `CloudKitSync` blind spots across three NetNewsWire targets in a run that had
  read all three. The graph walk is product- and target-granular, because a package-directory-keyed one
  pools the graphs of every product a package vends.

  **Acceptance**: the sixteen-fixture battery in `XcodeTargetScopeTests`, PLUS the two shapes the battery
  provably cannot see — (a) declared-but-not-analyzed (a `.package(path:)` outside the scan; caught only
  by `WorkspaceCacheProcessTests`), and (b) cross-target shadowing (a file in target A importing a module
  only target B links must stay disclosed), which needs a NEW fixture and does not exist yet. Cost check
  required: N target resolutions on a whole-repo scan, firefox-ios being the worst case at ~18.

- **[DONE — candor-swift, SHIPPING IN 0.27, opened + closed 2026-08-08] The κ ledger names local packages
  the scan ANALYZED, because module identity is decided per-SCAN when it is a per-FILE fact.**

  Built on `rung/per-file-module-identity` and merged. Three review rounds found ten defects; the two
  most serious shared one shape — the producer computed the right answer and the CONSUMER flattened it,
  while the producer's own fixture stayed green. Round 3 found no silence at all and gives the reason:
  every name that can be claimed internal has passed `analyzedTargets`, so a module is called internal
  only if a file under that target's real source root was read in this run. Kept below in full, because
  the P2 above is the same problem in the shapes this did not reach. Measured result: IceCubesApp's app
  target 48 → 38 uncovered, all ten names removed having analyzed functions in the same report; the
  other 15 target scans unchanged.

  **The symptom.** A `--target`-scoped NetNewsWire scan lists 31 uncovered modules, among them `RSCore`
  (20 analyzed files in that very report), `Account` (53), `NewsBlur` (7) — saying their effects are
  "INVISIBLE to the scan" and advising the reader to chain dep reports or scan the workspace root to
  close a gap that is already closed. A false disclosure: it prescribes work that does nothing and spends
  the reader's trust in the ledger that carries the REAL blind spots.

  **Why it is not a small fix, stated from measurement.** Closing it means deciding which modules were
  analyzed. Nine review rounds on 2026-08-08 found **ten distinct silent under-reports** in that
  decision, six of them introduced by the fix for the previous one. `internalModules` gates BOTH
  disclosure channels — the ledger and the per-function `invisible` hedge — and `invisible` is the only
  thing between an unresolved call into a blind module and a ⟨0.21⟩ purity claim, so every wrong claim is
  a cardinal sin, not noise. The ten: the package NAME (live on firefox-ios, which is named `Danger` and
  wraps the real `Danger`); any directory under `Sources/`; a commented-out `.target(…)`; a dead hoisted
  `.target(name:)`; a ternary's dead branch; `.testTarget`/`.plugin`/`path:`-relocated declarations read
  as source roots; the first `name:` in a span, which for a computed target name is a DEPENDENCY's
  `.product(name:)`; a nested package's same-named target claiming the root's import; plus a trap on an
  unclosed `.target(` and, the other way, candor-swift flagging its own `CandorCore`.

  **Where it was left (commit `430c5ef`).** BOUNDED, not fixed: a module is internal only when an
  analyzed file lives under a target declared in `rootDir/Package.swift`. That restores containment by
  construction — every claim is a literal root-manifest declaration, and the shipped 0.26 regex matched
  all of those and more — so 0.27 has strictly fewer sins than 0.26. The cost is that the noise is back:
  NetNewsWire returns to 31. **The improvement was withdrawn; the ten fixes shipped.**

  **What the rung actually needs.** Identity must become per-FILE, not per-scan: a module X is internal
  *for file F* when X is declared by a package F's own package can import — i.e. honour the dependency
  graph rather than the filesystem. The per-scan set cannot express that, which is why every attempt to
  approximate it from directory shape produced another sin. Concretely: carry the owning package per
  analyzed file, resolve each package's local dependency edges, and answer `blindModules(for:)` against
  that. The ledger then becomes a union over files rather than a global set.

  **The durable lesson, worth keeping with the item:** deciding a soundness-critical fact from filesystem
  shape has an unbounded number of ways to be wrong, and the way out was not a better heuristic but a
  smaller claim. Sixteen fixtures from those nine rounds live in `candor-swift`'s
  `XcodeTargetScopeTests` and are the acceptance battery for any replacement — a candidate that cannot
  pass all of them is not a candidate.

- **[SPEC + PART LANDED 2026-08-10 — engines pending] A policy that yielded NO RULES is
  indistinguishable from a clean gate IN THE MACHINE CHANNEL, four-way.**

  SPEC ⟨0.28⟩ `70620ef` + conformance PART 38 `aea9cfa` (reference-led, 12 SKIPs, suite OK). The rung:
  a CONFIGURED policy yielding zero rules refuses — exit 2 with the fail-closed document, the
  unreadable-policy posture, using the `unevaluated` whole-policy entry §3.1 already pins. Re-measured
  2026-08-10 four-way and on the `gate --report` VERB (the sibling route has it too). The line-level
  ignore-with-a-warning leniency is untouched; the rung is about what it composes to.

  **The decisive argument, worth keeping**: there is ALREADY a way to say "I am not gating" — do not
  configure a policy — so a configured zero-rule policy is never a legitimate expression of intent. And
  the defect's verdict is byte-identical to the no-gate-configured verdict, which is what makes the
  machine channel unable to tell them apart.

  **CLOSED FOUR-WAY 2026-08-10 — PART 38 is PASS × 12** (three forms × four engines) against fully
  committed state, suite `conformance: OK`, and the control row green everywhere. Scan route: rust
  `960b879`, java `027aaa2`, ts `7d56df4`, swift `5552a36`. **`gate --report` VERB route**: java and ts
  closed both in one commit; rust `d665be3` and swift `bffc868` followed. All unpushed.

  **THE SIBLING-ROUTE HABIT RECURRED, IN THE SAME SESSION THAT WROTE THE SENTENCE.** I measured the verb
  route having this defect, put "Measured on the `gate --report` verb too — a route is not covered by its
  sibling" INTO the spec clause, then implemented rust on the scan route only and briefed three agents
  scan-route-only. Two of the three closed the verb route anyway by reading the spec; one flagged it and
  correctly declined to close it alone (that would have created a fresh divergence). Having the lesson
  written down, and having written that sentence hours earlier, did not prevent it. See
  [[candor-generated-argv-beats-enumeration]].

  Two rows to keep: an `allow`-only and a `forbid`-only policy already refuse on the VERB route for
  their own specific reasons (a report's `calls` graph is effect-relevant; the AS-EFF-008 marker does not
  ride the report wire). Both were confirmed pre-existing by rebuilding the pre-change tree, not reasoned
  about, in rust and swift independently.

  **Named adoption cost**: the empty file and the all-comments file refuse too. Anyone with a committed
  placeholder policy starts getting exit 2; the remedy is to remove the `policy` key. This is the one
  part of the rung that is a judgment call rather than a derivation — scoping it to the readable-non-
  policy case only, and leaving empty files green, is the available alternative if the adoption cost
  proves real.

- **[P1 — SPEC LANDED 2026-08-11, engines pending] A report-consuming verb MUST re-disclose the ⟨0.21⟩
  manifest, and the obligation binds ANSWERS not only verdicts.**

  §2 ⟨0.15⟩ already makes re-disclosure a MUST for `coverage`, and it IS implemented: measured, `gains`
  over a baseline carrying `coverage.uncovered` emits `coverageDelta` naming it. **The same verb, same
  report, same output, drops `unanalyzed` entirely.** The mechanism exists and was pointed at the weaker
  caveat — `coverage` says "I could not see into this dependency", `unanalyzed` says "I could not read
  this file of YOUR OWN CODE", `analyzed.count: 0` says "I judged nothing at all".

  And the scope was narrower than its own argument: the clause binds verbs "whose VERDICT could change",
  but both cases it reasons from are ANSWERS that read as all-clears. Measured over a report declaring
  `unanalyzed`: `show` → `[]`, `where Fs` → `{directly:[],inherited:[]}`, `map` → `{}`, and **`blindspots`
  → `{totalUnknown:0}` — reporting NO BLIND SPOTS out of a report whose manifest names a file it could not
  read.** None hedges.

  SPEC `2cea6fd`. **PART 39 pins it**: half (i) coverage travels (a hard FAIL — it is the live precedent
  the new clause argues from) PASS four-way; half (ii) manifest travels, reference-led, SKIP four-way.
  Engine work is the open half, across ~8 verbs × 4 engines.

  *Third time in SPEC a rule has been stated over the instance rather than the condition (after §3.3.1's
  two ⟨0.24⟩ corrections). The tell each time: the clause's justification is broader than the clause.*

- **[P2 — opened 2026-08-11; RE-VERIFIED LIVE 2026-08-14] `path <real fn> <typo'd Effect>` answers exit 0 in ALL FOUR engines.**
  Re-measured on candor-ts rather than re-read: `path Cases.fs_read Nett` prints **`Cases.fs_read does not
  perform Nett  (inferred: ["Fs"])`** and exits **0**, while a nonexistent FUNCTION on the same report
  correctly exits 2. So the negative answer is confident, well-formed, and about a question that was never
  valid — the control right beside it already behaves correctly, which is what makes this a hole and not a
  design choice.
  Same all-clear-for-a-question-never-posed shape that §17 (1b) pins for `where`/`callers`, and now for
  `impact`/`path` on a nonexistent FUNCTION. A typo'd EFFECT is the remaining hole and it is four-way, so
  it wants its own rung — gating one engine alone would manufacture a divergence. Named in (1b)'s comment
  so it stays measured rather than becoming another untested parenthetical.

- **[CLOSED 2026-08-12 — built as the design said, conformance PART 44] ~~A coverage-gap checker for the
  suite.~~** The measurement stood: inference was 1 true positive to 8 permanent false positives and was
  right not to ship; **declaration** was right and is now `conformance/part_declarations.py`. All 44
  addressable slices plus the preamble carry `# ENGINES:` / `# CONTROLS:`, checked both ways against
  `part.sh --sections` — the one slicing implementation, never a second parser.

  Two things the build got that the design did not anticipate. First, the grammar forces a **four-way
  disposition**: every engine is listed or excluded *with a reason*, so an engine mentioned nowhere
  cannot be written — the PART 39 shape is **unwritable**, not merely detectable. Second, it found four
  live gaps on its first pass, one of them **in a row written the same day**: PART 40 probes only rust
  (java and ts ship all ten read verbs); PART 4n's `tolerant` rows probe three engines under a MATCH line
  claiming "every engine"; PART 8 credits a bare exit 2 with no answering arm; and PART 37's `ti_control`
  ran for rust/ts/swift but not java — asserting java's refusal while never asking whether its guard is
  artifact-shaped or containment-shaped. The last is fixed; the rest are recorded beside their
  declarations.

  Stated limit: the unit is the addressable slice, so a rider driving four engines can mask a headline
  part covering three. PART 4n is the live example, recorded in prose beside its declaration rather than
  left as a silent property of the granularity. 0.06s over 46 slices.

- **[WITHDRAWN 2026-08-21, WRONG — and the way it was wrong is the entry's whole value.] "Every query
  verb exits 0 when it cannot find a report."** Filed and committed on a measurement of the form

      out=$(candor-query "$v" 2>&1 | head -1); rc=$?

  **`$?` after a pipeline is the exit status of the LAST command in it — `head` — which is 0 forever.**
  Every "EXIT 0" in that round was `head` succeeding. Re-measured by running the binary directly and
  reading `$?` with nothing in between: **rust, ts and java all exit 2** on every verb, and the control
  is right too — `where Llm` over a REAL report with no `Llm` exits 0, which is a genuine empty answer
  and not a failure. There is no defect. The engines were correct the whole time.

  This file already carries the rule, from 2026-08-08: **"before reporting a defect found through a
  pipeline, re-run it writing straight to a file — a value that has been through a shell is not the
  engine's output, it is the shell's rendering of it."** That entry is about `echo` mangling a JSON
  string; this is the same rule one field over, applied to the EXIT CODE rather than the output, and it
  cost a filed finding and a commit before the contradiction surfaced.

  **What surfaced it:** candor-swift appearing to exit 0 on a nonexistent path. That would have
  contradicted a refusal shipped hours earlier, and a result that contradicts something just verified is
  worth more suspicion than a result that merely looks bad. **The instrument was wrong, not the engine** —
  which is the same conclusion PART 58 reached about rust and PART 59's row C reached about ts and swift
  on the same day. Three times in one session an apparent divergence was the measurement.

  **Kept rather than deleted**, because a withdrawn finding with its cause on the record is a cheaper
  lesson than the next person re-running the same broken probe.

- **[P2 — THE THIRD ROUTE, opened 2026-08-10] The ADVISORY verbs proceed silently over a zero-rule
  policy.** `whatif`, `fix-gate` and `unverified` share the policy loader with the gate verbs and were
  NOT touched by the ⟨0.28⟩ rung; PART 38 does not probe them. Found by the java arm while implementing
  the rung — the sibling question asked one level further out than the rung itself reached.

  **It probably does NOT get the same answer, and that is why it is its own item.** These verbs are
  ADVISORY: they do not set a gate verdict, so `ok: true` is not on the table and the exit-2 refusal
  posture may be the wrong shape entirely. The likely answer is a DISCLOSURE — `unverified` over a
  zero-rule policy currently calls a layer "PROVABLY clean" on the strength of a policy that asked
  nothing, which is the ⟨0.24⟩ zero-match harm arriving through a third channel. Decide the shape before
  implementing; do not assume the gate verbs' refusal transfers.

  ORIGINAL ENTRY BELOW (the measurement that opened it):

  Measured 2026-08-07 on java, rust, ts and swift. Point `--policy` at an existing file that is not a
  policy — a README, the wrong path in a CI script — and every engine writes

      { "ok": true, "violations": [] }

  which is byte-identical to the verdict of a gate that ran and found nothing. Exit 0. A wrapper reading
  the artifact, which is the consumer this format exists for, cannot tell "your code is clean" from
  "your gate had no rules". The HUMAN channel is fine and this is why it went unnoticed: all four warn
  per line (`ignoring policy rule (unknown rule kind …)`), so the operator watching stderr is told. The
  verdict document is silent.

  **This is PART 32's ruling one level up.** ⟨0.24⟩ §4 says a RULE whose scope binds no function is
  DISCLOSED, never scored as satisfied. A POLICY that contains no rules at all is the same shape and the
  stronger case, and it is currently scored as satisfied.

  **Why it is a rung and not a fix**: the answer is a field in the verdict document — the natural home is
  beside ⟨0.24⟩'s `unevaluated` — and that is a wire-format change, so it wants a version and a
  conformance part rather than four independent additions. Note the ⟨0.26⟩ lesson applies directly: a
  PARTIAL artifact can answer worse than an absent one, so whatever the field is must make the NAIVE
  read (`ok`) safe rather than adding a key only a careful reader consults.

  Two things measured alongside it that are NOT defects, recorded so nobody re-opens them: the per-line
  warning IS emitted by all four (an earlier read of "silent in ts and swift" was a truncated `head -3`),
  and the "nothing hidden — every effect sits where its name says it should" line is the §6.1 containment
  note, printed with no policy at all, not a claim about the gate.

- **[CLOSED FOUR-WAY 2026-08-11 — all unpushed] The stale-document rule binds the REPORT, not just the
  verdict. Tom: "make sure we fix the exit 2 issue in 0.28."**

  **PART 37 is (a)(b)(c)(d)(e) green four-way**; PART 38 PASS×12; PART 39 pins the re-disclosure MUST;
  SEMANTICS gained **C3**. `conformance: OK` on a clean tree with every engine idle.

  Rows: (a) file sink armed · (b) stream sink · (c) a failed run must not touch the DEFAULT prefix —
  a FLOOR that never SKIPs · (d) the §2.2 sidecars go with the armed report, DELETED not emptied ·
  (e) unanswerable reaches the MACHINE channel.

  **Six things this rung cost, each measured and each now pinned** — recorded because the shapes recur:
  1. *Leaving un-overwritten files armed* turned a COMPLETE scan into a permanent exit-2 (a placeholder's
     `unanalyzed` is the ⟨0.21⟩ incompleteness trigger). Fixed by remembering prior bytes and restoring.
  2. *Arming the FIRST `--out`* when the parse loop is last-wins — the real sink stayed stale.
  3. *Arming the DEFAULT prefix* destroyed a COMMITTED report. The rule is "arm a sink the operator
     NAMED"; ⟨0.27⟩ never had to say so because `--gate-json` has no default.
  4. *A suffix denylist over §2.2's SEVEN reserved segments* overwrote `<prefix>.gate.json`, a VERDICT.
     Denylist-over-allowlist is about CLASSIFYING; **for a WRITER it inverts.**
  5. *Identification before the input exemption* lost the disclosure for a non-JSON policy under the prefix.
  6. *Sidecars deleted even when the arm write FAILED*, leaving a stale report with no callgraph.

  **Not one was caught by me.** Two by candor-swift's arm checking its OWN semantics instead of copying the
  reference, one by candor-ts tripping over rust's dirty tree, one by a Fable review citing a clause I had
  not read, one by candor-java seeing a write result rust discarded. **A wrong REFERENCE is worse than a
  wrong one-off: delegation multiplies it before the first check.**

  **Open follow-ons**, all filed below: the machine-channel vein (Class B), the orphaned report, a repeated
  `--out`, candor-agents on both rungs, tightening the origin rule so `{}` is unanswerable by RULE rather
  than by four engines' good judgement, and `path <real fn> <typo'd Effect>` answering exit 0 four-way.

  ORIGINAL ENTRY BELOW (the measurement that opened it):

- **[SUPERSEDED by the entry above] The stale-document rule binds the REPORT, not just the verdict.**

  SPEC ⟨0.28⟩ landed as five MUSTs beside the ⟨0.24⟩ generalisation: arm at parse time, the fail-closed
  report is a manifest-carrying empty under ⟨0.21⟩ Row 1 (`functions: []` + `analyzed.count: 0` +
  `unanalyzed`), the ⟨0.27⟩ (2) input exemption applies, the stream sink writes the same document on any
  exit-2, and it binds `observe` as well as `scan`. Re-measured 2026-08-10 (unknown-flag exit-2 beside
  `--json`) — all four code engines byte-identical on the file sink and 0-bytes on the stream sink; the
  supposed pre-state at 2026-08-06 held.

  **The ⟨0.21⟩-Row-1 shape survived the ⟨0.26⟩ partial-vs-absent test**: `analyzed.count: 0` is the one
  integer ⟨0.24⟩ Row 1 specifically reads as "no claim", so the fail-closed report is a partial artifact
  that consumers already refuse to grant coverage from. No new consumer logic required.

  **STREAM FORM — CLOSED FOUR-WAY 2026-08-10.** PART 37 (b) went from SKIP×4 to PASS×4 on the same
  full-suite `conformance: OK` run, one commit per engine (all unpushed): candor-rust `7e1d8cd`,
  candor-java `b4cd5c5`, candor-ts `0e03f87`, candor-swift `1462bb2`. Each writes the ⟨0.21⟩ Row-1
  fail-closed report to stdout as its only content on any exit-2 when `--json` was requested and stdout
  isn't claimed by `--gate-json -`. Same-shape latch per language: rust `REPORT_STREAM_WRITTEN` /
  java `reportDocEmitted` + shutdown hook / ts `reportStreamWritten` module-scope (with a TDZ hoist fix)
  / swift `reportStreamWritten` module var. Pattern per engine: latch on success, write fail-closed on
  every direct `exit(2)` site plus any shared refusal helper.

  **FILE SINK CLOSED FOUR-WAY 2026-08-10 — PART 37 is (a) PASS×4, (b) PASS×4, (c) PASS×3 + n/a.**
  java `0526584` (`--json <file>`), rust `f439dea`+`35a7c92`+`df64922`, ts `1446a65`+`6493eec`, swift
  `0952cf7`+`add5fa6`. PART 37 was also made surface-aware (`261a93a`) — it had probed `--json <file>`
  on all four, which is a file sink only on java, so three engines were SKIPping a question nobody had
  asked them.

  **The `--out` design question the BACKLOG deferred is settled, and BOTH candidate answers were wrong.**
  Measured: only rust FANS OUT (one report per crate); java/ts/swift write a single report, so the
  multi-file problem exists in one engine. And the "per-package placeholders need set-membership at
  parse time" objection dissolves — the set that matters is the one the PREVIOUS run left, which is
  knowable by globbing. Arming rewrites those to the ⟨0.21⟩ Row-1 placeholder; each member that scans
  overwrites its own.

  **THREE DEFECTS I INTRODUCED WHILE FIXING THIS, all caught downstream rather than by me:**
  1. *Leaving un-overwritten files armed.* Looked like a free fix for the orphan defect; actually made a
     COMPLETE scan refuse exit 2 permanently, because a placeholder's non-empty `unanalyzed` is the
     ⟨0.21⟩ incompleteness trigger. Fixed by remembering prior bytes and handing them back on
     completion. The orphan is now left exactly as found — see its own entry below.
  2. *Arming the FIRST `--out` when the parse loop is last-wins.* `--out p1 --out p2 --zzz-not-a-flag`
     armed p1 and left p2 — the real sink — STALE. Caught by candor-swift's arm, which checked its own
     loop instead of copying the reference.
  3. *Arming the DEFAULT prefix.* Destroyed a COMMITTED report on a run that died in argv parsing —
     found in candor-rust's own tree, which commits reports for six crates. Committed reports/baselines
     are the pattern this project recommends. The rule is "arm a sink the operator NAMED"; ⟨0.27⟩ never
     had to say so because `--gate-json` has no default. **Nothing in the conformance suite could see
     it** (every probe passes an explicit `--out`), so PART 37 row (c) now pins it, never SKIPs, and was
     falsified against a deliberately broken build before landing.

  Durable: a wrong REFERENCE is worse than a wrong one-off — I wrote it, two agents mirrored it
  faithfully, and it was found only when one tripped over rust's dirty tree.

  **Open — sidecars.** `<prefix>.<pkg>.callgraph.json` / `.hierarchy.json` still go stale on exit-2; the
  armer deliberately does not touch them. A live sidecar beside a placeholder report lets a chained
  consumer join yesterday's call graph to today's empty report. Check against §2.2 ⟨0.26⟩'s existing
  sidecar-manifest rules rather than inventing a rule here.

  **Open — candor-agents.** `scan` and `observe` both publish a §2 report shape via `--out` / `--json`.
  Sibling-route rule: neither is covered by the four code engines.

- **[P2 — pre-existing, MEASURED 2026-08-10] An ORPHANED report survives its package being deleted, and
  still sets gate outcomes.** Delete a crate from a workspace and rerun: `<prefix>.<gone>.scan.json`
  survives, byte-shaped exactly like a live report, with nothing saying its source no longer exists —
  and `gate --report <prefix> --policy 'deny Exec'` exits **1** on a function in the deleted crate.

  Direction stated precisely: an orphan only ADDS entries, so for `deny` rules it is fail-CLOSED (a
  false RED, not the cardinal sin). Two sharper variants are unmeasured: a RENAMED crate leaves the old
  report beside the new one so both count, and an orphan inflates any completeness answer over the
  prefix.

  **Deliberately NOT fixed inside the ⟨0.28⟩ arming work**, though arming could have neutralised it for
  free — that attempt is defect 1 above. It needs its own wire answer (delete the file? mark it
  not-in-scan? a prefix can legitimately be shared between projects), and resolving it as a side effect
  of a staleness fix would be deciding it by accident.

- **[P3 — spec question, opened 2026-08-10] Should a repeated `--out` be refused?** ⟨0.28⟩ refuses a
  repeated `--gate-json` on "one run names one sink, and the reader of the losing path cannot tell it
  lost". `--out` names where the report SET goes and is currently silently last-wins in every engine.
  The argument looks like it transfers; do not assume it does — `--out` differs in that it names a
  prefix rather than an artifact. Surfaced by the first-vs-last arming bug (defect 2 above).


- **[P3 — spec rung, 2026-08-04] `execute` as a per-effect KIND: reading a file as CODE rather than data.**

  **Context: the kind mechanism is now proven four-way.** SPEC §2's `fs: read|write` was spec'd long ago
  and implemented in java only — the in-family precedent this line originally claimed for rust was HALF
  FALSE: rust carried `pub fs: Vec<String>` in the wire model with `fs: Vec::new()` hardcoded, never
  populated, which is worse than absent (a present-but-always-empty field says "undetermined" forever
  while wearing a schema that implies support). candor-swift and candor-ts gained it 2026-08-04, and `privacy/2`
  applied the identical contract to a second effect family the same day. So "a per-effect kind, omitted
  rather than guessed" is no longer a proposal — it is a shipped pattern with two instances.

  **The proposal is NOT a universal read/write/execute triad, and the distinction is the whole item.**
  `execute` is meaningful for two effects and meaningless for the rest. Forcing a triad would make an
  engine answer a question that does not apply — and under absence-is-a-claim, an omitted field that
  *cannot* apply is noise rather than information, which is the opposite of what a disclosure format is
  for. The spec already scopes kinds per effect ("applies only when `inferred` contains `Fs`"), so this is
  a per-effect vocabulary decision and should stay one.

  · **`Fs[execute]` — and the interesting reading is NOT the POSIX exec bit** (that is a write). It is
    **code loading**: `dlopen`, a dynamic `require`, a reflective class-load — reading a file as *code*
    rather than as data. Genuinely different risk, and invisible today *as an effect*.
  · **`Db[execute]`** — arbitrary statement execution vs a query. Real, and the shape a "the read model may
    not write" gate wants.
  · **Not** `Clipboard`, `Env`, `Net`, or any privacy sensor. There is no execute there.

  **WHAT MAKES THIS AN UPGRADE RATHER THAN A NEW CLAIM, and it is the strongest argument for it.** Code
  loading is already handled honestly: `dlopen` and friends land as a DISCLOSURE REASON (`native:dlopen`),
  i.e. the engine says "I cannot see past this" and the function carries `Unknown`. So today's answer is
  *undetermined*, not *wrong*. An `execute` kind would move it from "I can't see this" to "this loads
  code" — strictly more information, and the transition is from a disclosed blind spot to a determined
  fact, which is the direction this project is always trying to travel.

  **THE HAZARD, named because it is inherited rather than new.** This is Escape 2's axis (PAPER3 §8): a
  kind or class coarsening is invisible to `H` *and* to `⊑`, so an engine that stops emitting a kind, or
  coarsens one, produces a red→green flip with no back-pressure in any channel. `netClass` already carries
  exactly this cost. The closure is a classification ratchet against baseline, and any kind rung should
  ship with one rather than after it.

- **[P3 — spec rung, 2026-08-04; MECHANISM SETTLED 2026-08-06] Direction (`read`/`write`) for the
  effects beyond `Fs` where it pays.**
  The general half of the same question. **Build it the way ⟨0.27⟩ `fs` ended up, NOT the direct-only
  shape this entry originally prescribed:** kinds TRAVEL the call graph and an undetermined contributor
  SUPPRESSES the whole field (a partial answer reads as the positive claim "writes but never reads"),
  pinned four-way by conformance PART 31 — which found all four engines wrong on its first run,
  including the reference engine propagating without the undetermined guard. The remaining places the
  distinction is worth the wire:

  · **`Clipboard` — and this is the best candidate, because the sensitive direction is the one nobody
    expects.** READING the clipboard is what iOS shows a paste banner for; writing to it is benign. One
    effect covers both today, so `deny Clipboard` cannot express "may write, may not read".
  · **`Db`** — the classic architecture gate: the read model may not write.
  · **`Env`** — reading is ubiquitous, writing is rare and surprising, and the two are worth telling apart
    in a report a human skims.
  · **NOT `Net`** — request/response is bidirectional by nature. The useful refinement there is the
    destination class, which already exists.

  Same discipline in every case: omitted rather than guessed, direct-only (a caller reaching one writer and
  one undetermined-kind callee must not inherit `["write"]` and thereby claim "writes but never reads"),
  and the same Escape 2 ratchet obligation as above.

- **[P3 — engine infra, 2026-08-04] candor-ts has no equivalent of candor-swift's collector-state guard.**
  candor-swift's `NameKeyedStateTests` requires EVERY stored property of `CallCollector` to be classified
  in a `disposition` map — because whether a shadow scope saves, clears or ignores a piece of state is a
  decision, and its docstring records that **seven defects came from that decision being skipped**. It
  caught two additions in one session (`fsKinds`, then `privacyKinds`).

  candor-ts has nothing equivalent, and the same class of mistake there surfaced as a CRASH: a fn record is
  built in four places, an accumulator was added to two, and `rec.fsKinds` was undefined on the other two —
  the scan aborted and the integration suite died on a null report. Loud, and therefore cheap, but loud by
  luck rather than by design. A test asserting every fn-record construction site produces the same key set
  would make it a named assertion instead.


The 2026-07-16 three-angle referee pass on the "disclosure-oriented effect analysis" write-up (PL-theory,
empirical-SE, industry-practitioner — reports local at `~/candor-paper/REFEREE-REPORTS.md`) surfaced a
cluster of REAL tool improvements, not just paper edits. The unifying thread: candor **already reason-tags
every `Unknown`** (`unknownWhy`: `dispatch:` / `reflect:eval` / `reflect:vm` / `reflect:require` /
`reflect-metadata` / `native:` / `callback:` / `closure` / `unresolved` / `missing-config`) but **nothing
quantifies over the reasons yet**. Make the reason first-class — in the policy language and in the UX — and
several of the reviews' dealbreakers dissolve at once. This is the tool-side of the paper's own §3 fix
(a signature is a `(determined-effects, reasons)` pair): reasons first-class in the model AND the product.

**STATUS (2026-07-20): this track is mostly LANDED + PUBLISHED.** Reason-scoped `Unknown` shipped as floor
**0.19**; the `Net` destination-class + `blindspots --stats` as **0.20**; the completeness manifest as
**0.21**. What remains open, and the recommended next pick: **the `candor verify` dynamic honesty oracle**
(below, elevated to [P1 — NEXT]) — the empirical referee's RQ3 point is that cross-engine conformance is
the WEAKEST check (shared blind spots hide from agreement), so a mechanism-INDEPENDENT oracle that checks
the report against a real syscall trace is the highest-leverage remaining soundness work AND the paper's
load-bearing evidence. Blame-tracked `Unknown` [P3] builds on it. The per-item detail below is kept for
provenance; the SHIPPED items are marked in place.

- **[SHIPPED + PUBLISHED, floor 0.19] Reason-scoped `Unknown` policies** — **SHIPPED + PUBLISHED as floor 0.19** (was staged on main 2026-07-17).
  All four engines: `ReasonClass` projection {reflect,dispatch,indirect,native,unresolved,setup}, the
  `deny E Unknown[class…]` parser (`dynamic` alias, `*`/bare = all, A2 under-gating lint), the reason-scoped
  gate eval (fires only on a matching class; unrecorded → `unresolved` conservatively), **the reason CLASS
  propagated TRANSITIVELY at gate-eval time** (a caller inheriting a reflect-caused Unknown fires
  `Unknown[reflect]` — a transitive under-gating gap found+fixed during the port), and the **`reasonClass`
  verdict field** (§3.3; all classes on the fn, on an AS-EFF-006 Unknown denial). **SPEC §6.2 grammar
  written** (⟨0.19⟩). **Conformance**: PART 4 pins the parse (`unknownClasses`) four-way; PART 12 pins a
  representation-agnostic `reasonClass` structural invariant. Per-engine regression tests + four-way
  conformance green. Sibling: the **disclosure-completeness gate** (candor-java `DisclosureCompletenessTest`
  + `DISCLOSURE-COMPLETENESS-DESIGN.md`) shipped alongside. See the reason-scoped-Unknown / Net-class work.
  The config **`unknown-alias`** key ALSO shipped four-way (2026-07-17): a user-defined
  `.candor/config` `unknown-alias foo = reflect,native` referenced explicitly as `Unknown[foo]`,
  multi-value, discovered by walking up from the policy/scan target, honored by the gate AND the
  config-aware `parsepolicy` (pinned in PART 4 via a checked-in `.candor/config`). A config alias may not
  shadow a built-in and never changes what bare `deny E Unknown` means. The **`setup`-vs-genuine split**
  (§3) is **COMPLETE four-way** (2026-07-17) — by two mechanisms: **candor-ts** emits a per-fn `setup` tag
  (`no-node_modules:<pkg>` on a call into a declared-but-uninstalled dep — precise because it *resolves*
  types and npm import specifier == package) + a loud SETUP remediation; **candor-java / -rust / -swift**
  route the mis-config / uncovered-dep case to the κ **coverage ledger** (`invisible` + note), never a
  genuine `Unknown` (java `Candor.java:1364`), so the separation already holds — and a per-fn `setup` tag
  there would be UNSAFE (no clean import→package/module mapping ⇒ mis-tag ⇒ under-gate via `Unknown[dynamic]`
  excluding `setup`), so deliberately not emitted; **candor-swift** adds a SAFE scan-level SETUP *warning*
  (a `Package.swift` declaring deps with no fetched `.build/checkouts` → "run `swift build`"). **The whole
  reason-scoped track is now done** — the only genuine follow-on would be if a future java/swift build-file
  reader made a precise setup tag safe there (not currently worth the under-gating risk).
  _(orig:)_ `candor-spec/REASON-SCOPED-UNKNOWN-DESIGN.md`.
  `deny Net Unknown[reflect,native,dispatch] domain` fires on the dangerous DYNAMIC reason classes but
  tolerates `Unknown[setup]`/benign `indirect`. The data is already emitted (`unknownWhy`, four-way); the
  design adds a fixed cross-engine **reason-class vocabulary** (`reflect`/`dispatch`/`indirect`/`native`/
  `unresolved`/`setup`) projecting the raw `unknownWhy`, plus the policy grammar filter — bare `deny E
  Unknown` stays `Unknown[*]` (back-compat, soundness-by-default). **Dissolves the industry referee's #1
  dealbreaker**: bare `deny E Unknown` is deny-all-able on DI/reflection-heavy code, so teams disable it;
  reason-scoping makes it shippable. Conformance PART pins reason-scoped verdicts four-way. **Highest
  leverage in this track**: smallest build (reuses existing data), biggest adoption unlock. Tier-2 rung,
  java-leadable. (The SETUP-vs-GENUINE split — routing `missing-config`/`no-tsconfig` to a loud scan-time
  setup diagnostic, never a silent gate input — is §3 of the same doc: it's the same reason-class mechanism,
  so it ships together.)
- **[SHIPPED + PUBLISHED, floor 0.21] Completeness manifest — close the `absent ⇒ pure` hole** — **SHIPPED + PUBLISHED as floor 0.21**
  (report/verdict `analyzed`+`unanalyzed`; the fail-closed exit-2 incomplete verdict closed a live
  machine-consumer cardinal-sin channel in java/ts/swift — see the completeness-manifest rung). Original
  framing kept for provenance — DESIGN DONE + REALITY-AUDITED
  (`candor-spec/COMPLETENESS-MANIFEST-DESIGN.md`). The PL referee's finding: a SILENTLY-DROPPED effectful fn
  is indistinguishable from a provably-pure one (both absent from the report). **The 2026-07-16 four-engine
  audit shrank this**: the analyzed universe ALREADY exists — SPEC §2.2's callgraph sidecar records every
  analyzed fn incl. pure leaves (normative, four-way, load-bearing for AS-EFF-005). So the real work is three
  narrower gaps, not a new manifest: **(G1)** surface an `analyzed:{count,digest}` SUMMARY in the report
  envelope so a bare-report/`--gate-json` consumer answers analyzed-pure-vs-never-seen without loading the
  sidecar; **(G2, the sharp one)** a machine-legible `unanalyzed` field in the envelope AND gate verdict —
  parse-failures are disclosed on STDERR + fail the exit code today but are INVISIBLE to a JSON consumer, so
  an agent gets `ok:true` over unanalyzed source (a live machine-consumer cardinal-sin channel worth fixing
  regardless); **(G3)** verify/pin four-way that a truly-isolated pure fn is a callgraph node (ts derives
  nodes from edges → an isolated leaf may be missing — the residual §2.2 hole). Tier-1 additive + a §2.2
  conformance fix; pairs with `candor verify`.
- **[SHIPPED + PUBLISHED, floor 0.20] `Net` destination-class refinement — SHIPPED + PUBLISHED as floor 0.20** (`netClass`
  known-telemetry/known-partner/unknown-host + `deny Net[unknown-host]`, fail-closed on a masked/runtime
  host — see the reason-scoped-Unknown / Net-class work). Original framing kept for provenance — DESIGN DONE
  (`candor-spec/NET-DESTINATION-CLASS-DESIGN.md`, 2026-07-17); answer the coarse-effects dealbreaker. `Net` can't tell
  telemetry from exfiltration — the industry referee's hard blocker for anything security-framed. Generalize
  the existing `MODEL_HOSTS` machinery (already classifies `Net`→`Llm` by host): carry a destination CLASS
  on `Net` (`known-telemetry` / `known-partner` / `unknown-host`) from the host literals candor already
  extracts (const-anchored + literal-head resolution, spec 0.14). Unlocks the security use case the tool
  can't currently cash; a natural extension of shipped work. Bigger effort; a real vocabulary rung. Stay
  SOUND — an unresolved host stays bare `Net` (+ `unknown-host` class), never fabricated.
- **[LARGELY DONE — re-surveyed 2026-08-03; the "productionize" ask has been met in all four arms]
  Standing dynamic honesty oracle (`candor verify`).** The entry below was written 2026-07-20 and asks for
  work that has since shipped. Measured state, per repo, from the workflow files:

      candor-rust   `realworld-oracle.yml` — strace, CONTINUOUS (every push + PR), exits non-zero on a
                    NEW silent under-report. Plus realworld-oracle-deep + disclosure-recall.
      candor-java   ci.yml's dynamic-oracle step — JFR + a leaf-instrumenting `-javaagent`; the file
                    itself says "this makes the runtime oracle a STANDING gate (was manual)".
      candor-ts     ci.yml — transitive-recall battery + the 20-case effect-set oracle; ships a
                    user-facing `candor-ts-verify` CLI.
      candor-swift  ci.yml — recall oracle (non-syscall, macOS) + strace lane (Linux);
                    `confirmatory-corpus.yml` is weekly and REPORTED-not-gated **by design** (a held-out
                    frozen corpus is evidence, not a ratchet — see FROZEN.md).

  **WHAT IS ACTUALLY LEFT is narrower and worth stating precisely: `candor verify` is a user-facing verb
  for the NODE and JAVA arms only.** rust and swift have real dynamic oracles, but as harnesses inside
  their own repos' CI — not as something a user can run on their own project. Until that changes the verb
  should refuse those targets rather than guess, which it now does (`bin/candor`, 2026-08-03): a
  Swift package used to fall through to the NODE arm and be told to "scan the project first (candor-ts
  <dir>)" — a remedy naming the wrong engine for the user's language, which costs a run to discover.
  Promoting either harness to a verb is the remaining work, and it is a new feature rather than
  productionization.

  ~~ORIGINAL ENTRY:~~ Productionize the oracle prototype (built local, `~/candor-paper/harness/`; also runs
  on this Mac via a Docker `rust:latest` + `--cap-add=SYS_PTRACE` strace container — runs via a Docker `--cap-add=SYS_PTRACE` strace container on this Mac;
  candor-java ships the production `io.poly.candor.verify` `-javaagent` (Trace.emit, ~1.0–1.3×) distinct from
  the soundness-corpus harness agent — candor-java ships the production verify `-javaagent`): run a candor report against a runtime
  syscall/interposition trace and confirm `observed ⊆ inferred ∪ {Unknown}` per executed fn. The empirical referee's RQ3 finding — that
  cross-engine conformance is the WEAKEST check, because shared blind spots hide from agreement (the
  Knight–Leveson result our own soundness log confirmed: write-fmt silent in all four engines) — is an
  argument to lean on the mechanism-INDEPENDENT oracle as a standing CI/soundness gate, not just
  conformance. The differentiator no competitor has: an analysis that checks itself against reality.
  Site-anchored attribution (wrap candor's own claimed direct-effect sites) sidesteps general stack
  unwinding.
- **[SHIPPED + PUBLISHED, floor 0.20] `Unknown`-rate / disclosure metric — SHIPPED + PUBLISHED as floor 0.20.** `candor blindspots --stats` (reason-class distribution, sizing) + `--class <c,…>` (drill-down filter), three-way (rust/java/ts), conformance PART 5c. The blindspots half of the design's reason-class integration; `unverified --class` is the small remaining companion. `candor blindspots --stats`: the
  reason-distribution (how much `Unknown`, by reason class) as a self-diagnostic, so a team can SIZE the
  blind-spot cost before turning on `deny E Unknown`. Cheap; answers the "is disclosure actionable or
  pervasive" question in production; feeds the setup-vs-genuine split.
- **[P3] Blame-tracked `Unknown`.** Join `unknownWhy` + the oracle: when a runtime effect escapes,
  attribute it to THE specific unresolved edge that should have disclosed it ("this `Net` came through the
  `reflect:vm` site at `foo.ts:42`"). Turns the oracle from yes/no into a debugger; the gradual-effects
  BLAME literature (Wadler–Findler lineage) is the formal home. Builds on `candor verify`.

## fingerprint

- _Done (2026-06-21):_ **`--baseline <report>` diff** — reports the *change* in the structure descriptor
  vs a baseline (structure delta + per-component smear/unknown/tangleExcess/cycleRatio deltas, the
  direction toward order/chaos), the deterministic-gate framing. (The A–F letter grade was already removed.)

The **structure descriptor** — `structure` `= 1 − (0.30·smear + 0.26·unknownShare + 0.24·tangleExcess +
0.20·min(1, 3·cycleRatio))` (0–1, cycle term saturates; `structure_detail.value` = ×100; exact form + the
attribution decomposition in the design doc), each component exposed — is the
sanctioned "**score of sorts**": an *explainable descriptor*, not a quality grade. No letter, no
pass/fail; a degenerate input reports `structure: null`, not a flattering number (spec §6.1). It differs
from the rejected "candor score" (Non-goals, below) precisely by being **component-transparent and
delta-framed**, not a single opaque headline number. Re-opened 2026-07-01 as an active thread (was
"no items remain") — candidate next steps, none committed:

  - **[gate] structure-delta regression gate — DESIGNED 2026-07-01, decision pending (Tom's go/no-go).**
    Full design in [`fingerprint/STRUCTURE-GATE-DESIGN.md`](fingerprint/STRUCTURE-GATE-DESIGN.md).
    `--baseline` already reports the drift toward chaos; the gate makes it *fail a PR* when `structure`
    regresses past a tolerance, with the drop **attributed** to its component and — v2 — to the functions
    that crossed each line. Same posture as the AS-EFF-005 ratchet: a PR-over-PR **delta**, never an
    absolute grade; opt-in; **no AS-EFF code / not in conformance**. **AUDITED 2026-07-16 (grounded-and-
    accurate):** the metric §21 matches `candor-fingerprint.mjs:308-309` VERBATIM and `--baseline` (the delta
    the gate consumes) already works — the gate is a THIN layer over real, tested machinery, NOT blocked on
    feasibility or grounding. The `.candor/config`-for-thresholds open question is resolved (config shipped,
    §3.4). So the only real blockers are (1) a decide-or-shelve call and (2) threshold/noise-floor
    calibration — a short EMPIRICAL pass on real repos (run the gate over N recent PR pairs, see what
    `structure` deltas real regressions vs churn produce), not a design problem. Recommendation: it's cheaper
    to build than the "designed twice, never committed" framing implies. **DEFERRED (Tom 2026-07-17): important,
    but parked to focus on the paper + related findings; revisit after that push.** Design is grounded and
    ready — pick it up cold when the slot opens, no re-audit needed.
  - **[adoption] embeddable fingerprint badge.** The mark already renders with transparent corners as an
    embeddable badge; surface a "your project's candor fingerprint" artifact (a README badge / a page on
    candor.poly.io) as a low-cost distribution/marketing surface. Ties to the adoption thread above.

## Deferred operational (need a publish or maintainer action)

- **Case studies → candor.poly.io — DONE (2026-07-02).** Live at
  [candor.poly.io/case-studies/](https://candor.poly.io/case-studies/) (all five studies, linked from the
  JVM page; site checks 226 green, pre-deploy review clean).
- **Cross-model eval → candor.poly.io — DONE (verified 2026-07-02, was already live).** The completeness +
  efficiency charts and the eval claims ship on [candor.poly.io/agents/](https://candor.poly.io/agents/) —
  this item was stale. `assets/charts/` (the chart renders + generators) is now committed here as the
  regeneration source for the site copies in `web/static/images/candor/`.
- **candor-rust self-guard baseline drift** — it fired again 2026-06-30 → 2026-07-02 (the deep-engine
  oracle commit `8693315` made the lint's own `check_crate_post` read a benign `Unknown` the Jun-17
  baseline didn't record); baseline refreshed + green (`a63e26b`, recipe: `cargo candor snapshot
  .candor/baseline`). The standing maintainer call from the earlier ICE diagnosis remains: whether the
  guard path should tolerate the same cosmetic nonzero that `snapshot` now does. See candor-rust/BACKLOG.md.

## Housekeeping (small, real, easy to forget)

- **[P2] TWO FOUR-WAY QUESTIONS RAISED BY candor-ts's ⟨0.28⟩ ARM (2026-08-12), both left untouched
  deliberately — fixing either in one engine manufactures a divergence.**

  (i) **`--out X --policy --json` exits 2 with X UNARMED.** `preWantJson` reads the rejected candidate
  value `--json` as the stream mode, so the staleness protection is skipped for that argv and a previous
  run's report is left standing. Same pre-pass/parse-loop disagreement class as the `--policy --out X`
  defect fixed in all four engines this rung, one flag over — and non-destructive, which is why it
  survived the sweep: nothing is written, something merely fails to be protected. The sweep's own
  measurement bias, worth naming.

  (ii) **`scan <unparseable> --gate-json v.json` writes `ok:false, incomplete:true` and exits 0.**
  `--gate-json` alone does not count as "a gate is configured" for the ⟨0.21⟩ incomplete-analysis exit 2.
  Looks deliberate, but the document and the exit code then disagree, and an exit-code-only consumer —
  the CI-step case this format exists for — reads a green. Needs a ruling on whether naming a verdict
  sink is itself a request to gate.

- **[P2] PUSH THE ENGINES BEFORE THE SPEC.** candor-spec's `conformance.yml` checks out the sibling repos
  at their MAIN branches and builds them, so a spec push that adds rows the engines must satisfy will fail
  CI if the engine commits are not already up. Measured 2026-08-10: the spec run checked out the engines at
  15:22 and the fixes landed at 16:19, so the new (b24)/(b25) rows ran against engines without them and
  reported five FAILs that were pure ordering. The run passes on re-run with nothing changed, which is the
  tell — and also the hazard, because "re-run it and it goes green" is exactly what a flaky suite looks
  like. Wanted: either a note in `release-preflight` step [11], or a workflow that pins the sibling SHAs it
  was tested against rather than tracking main.

- **[CLOSED 2026-08-10 — spec 0.28] ~~TWO SINKS IN ONE ARGV has no stated answer.~~**

  Answered by measuring rather than by deciding: three engines took the LAST path and wrote the verdict
  there, one refused, and **all four left the first path exactly as they found it** — a previous run's
  `{"ok": true}` surviving a gate that fired. That made only half of it a real choice. The spec now
  refuses a repeated `--gate-json` and requires the refusal at EVERY path named; two spellings of one
  path stay one sink, and the input exemption outranks the refusal. Shipped five-way, PART 36 (b20a–d),
  and the probe cell that was excluded for being unanswerable now poses it.

  Kept because it is the sharper half: the ts draft ran the input checks against the LAST sink only, so
  `--policy P --gate-json P --gate-json B` DESTROYED the policy — a fix closing one channel by opening
  another, caught only because the check was run against all four engines rather than against itself.

  Original entry follows.

- **[was P2] TWO SINKS IN ONE ARGV has no stated answer.** `--gate-json a --gate-json b`: which file gets the
  verdict, and does the other get anything? Every engine does *something*, and the spec says nothing, so
  today the answer is whatever each parse loop happens to do. Surfaced 2026-08-10 while building the argv
  combination sweep: `--gate-json` had to be removed from the sweep's token alphabet precisely because the
  cells append their own sink, and a pair containing one poses this question rather than the property
  under test. It is named in `bin/probe-causes.sh`'s NOT-COVERED note so it is not mistaken for covered.
  Wanted: a §3.3.1 sentence, then a PART 36 row — probably "the last wins and the earlier ones are still
  armed and refused", but that is a decision, not an observation.

- **[P3] The `gate` VERB route now has the cause list, but not the argv sweep.** ~~Outside the exit-2
  matrix entirely.~~ **Closed the same day it was filed, and it held a defect** — which is the argument
  against ever letting "spot-checked, no known defect" stand in for measured. `bin/probe-causes.sh` poses
  nine causes per engine on the verb route (104 cells total across both routes); an unreadable config
  exited 2 with an EMPTY stream in candor-scan and candor-ts while java and swift wrote the refusal, both
  through a shared config loader sitting below the verb's sink. Fixed in both, pinned by PART 36 (b19).
  Two things the build taught, kept because they generalise: the route needs its own EFFECTFUL fixtures
  (a gate over a clean report exits 0, so every cell would have been "not exit 2 here" — a probe that
  never asks its question), and it needs a CONTROL asserting the gate fires, which is what caught java
  sitting unmeasured because it writes a report only with `--json <file>`. ~~What is left: the argv COMBINATION sweep still runs the scan route only.~~ **Also closed** — the
  sweep is route-agnostic and runs both.

- **[FIXED 2026-08-10 — VERIFIED 2026-08-14: `rust-toolchain` lists the component, with the why] Rust code intelligence needed a rustup component, not a config.** `~/.cargo/bin/rust-analyzer` is
  a shim, candor-rust pins a nightly for the dylint lint, and neither that toolchain nor the default
  stable had the `rust-analyzer` component — so every request failed with `Unknown binary` and the client
  reported it as the server crashing. Both toolchains now have it and `rust-toolchain` lists it. Fixed
  2026-08-10; the end-to-end check through the editor is still pending a fresh session, and an earlier
  `rust-analyzer.toml` that named a different (refuted) cause was deleted rather than left in place.

- **[CLOSED 2026-08-14 — `$TMPDIR` is at ZERO `candor-*` and a full run adds none] candor's own test suites leak temp fixtures — 130,000 of them here.**
  `$TMPDIR` holds **46,919** `candor-*` scratch directories today. The single biggest contributor is
  candor-ts's `project()` helper in `test.mjs` (~7,300 `candor-ts-test-*` and rising): it calls
  `fs.mkdtempSync` per fixture and never removes anything, so one full suite run leaks ~1,300 trees. That
  one function is a self-contained fix — register each dir and unlink them in a `process.on("exit")` —
  and it would take most of the ongoing growth out. The rest (`candor-test*`, `candor-swift-comp*`,
  `candor-ts-gate-*`) are the same shape in other harnesses.

  **DONE for the dominant cause.** `scratch.mjs` registers each tree and sweeps on exit, including on
  SIGINT/SIGTERM (a signal does not run exit handlers — the killed-mid-run case — so it re-raises after
  sweeping). Trees are KEPT when the run FAILED: a failing assertion prints a path into one of them, and
  deleting it on the way out removes the evidence exactly when it is wanted. Measured: a passing
  1,345-test run now leaks **0**, was ~1,300. Both paths probed directly rather than assumed.
  The accumulated backlog was swept too — **48,556 directories older than 24h removed**, $TMPDIR from
  50,494 `candor-*` entries to 1,938 (today's runs, left alone).

  **FINISHED the same day** (`345307d`, candor-swift `9a1e09f`). The "roughly 40 call sites spread
  across harnesses" estimate was wrong, and the CENSUS is what corrected it: every prefix that actually
  ACCUMULATED lived in `test.mjs` — `candor-ts-gate` (2,270), the five `candor-verify-*` seeds, `mutant`,
  `corrupt`, `cgcorrupt` (~140 each). `candor-mcp-*` and `candor-lsp-*` had **2 entries each**, which is
  the signature of a harness that already cleans up. Confirmed by running them rather than inferring:
  test-unit, test-mcp, test-lsp and test-watch each leak 0. So the job was 31 more swaps in ONE file,
  not 40 across six.

  candor-swift had one too, and it is the interesting one: `CompletenessManifestTests.reportFixture`
  was the single fixture helper in that file WITHOUT a `defer` cleanup — because it returns the FILE
  path, so the caller never sees the directory and has nothing to defer on. 11 call sites, 142
  accumulated. Fixed with a `tearDown`; **A/B'd at 10 leaked per run → 0**, 781 tests passing either way.

  **State now: `$TMPDIR` holds ZERO `candor-*` entries, and a full candor-ts suite run adds none.**
  candor-rust's harnesses are still unmeasured — but nothing of theirs appeared in the census, which is
  weak evidence they are clean rather than proof. `$TMPDIR` on this
  machine held 185k entries, of which ~130k were `candor-test*`/`candor-conc*`/`candor-swift-*`
  directories older than a day, left by runs that create a scratch tree and do not remove it (the
  killed-mid-run case is the obvious one, but 130k is not all killed runs). That is not only untidy: it
  made a single `candor-swift privacy-manifest --verify` take **72 seconds**, because a directory
  listing of the plist's ancestor is a listing of `$TMPDIR`. The engine side is fixed (2026-08-07 — no
  checkout ⇒ no ancestor walk, and `contentsOfDirectory(atPath:)` for the marker test), so this is now
  a hygiene item rather than a correctness one. Wanted: every harness that makes a scratch dir removes
  it on exit, including on failure — `defer`/`try/finally`/trap, not a happy-path `rm`.

- **[P2] candor-swift `--target` on an `.xcodeproj` may EXECUTE the repo's `Package.swift`.** When a
  local package's manifest builds its target lists in code (WordPress's `XcodeSupport.products`), the
  structural parser cannot read it and the resolver falls back to `swift package dump-package` — SwiftPM
  running the manifest. That is disclosed in the scope note by name, and it is the only way to resolve
  those repos soundly (the alternative is refusing the scan). But "no project changes, no build, no
  account" is the quickstart's promise, and this path quietly breaks it for an untrusted checkout.
  Wanted: an explicit opt-out (`--no-manifest-exec`, refusing rather than executing) so a reader
  scanning code they did not write can hold the promise. Added 2026-08-07 with the `.xcodeproj` rung.

- **[P2 — two pin mechanisms now exist; consolidate onto one] `adopt/candor.yml` still pins the engine
  in CI YAML (`CANDOR_JAVA_VERSION`), beside the ⟨0.27⟩ `.candor/config` `engine` key that every engine
  ENFORCES.** The YAML variable only chooses which jar to download — nothing checks it against anything,
  which is exactly the decoupling the §3.4 rung exists to end. `candor init` already writes the config
  pin and generates `.candor/run`, which reads it to fetch the jar, so the version appears once. The
  adopt starter should do the same: drop `CANDOR_JAVA_VERSION` and call `.candor/run`. Annotated in the
  file for now (2026-08-06) so nobody reads the two as independent, but an annotation is not a fix and
  a family shipping two competing pin mechanisms indefinitely is the thing to avoid.

- **[FIXED 2026-08-04] `release-stage.sh` stages five engines and left two umbrella sites to be found by a
  downstream refusal.** `release-stage.sh` now bumps UMBRELLA_VERSION and preflight [4] reads it (replayed
  the failure to confirm [4] catches a stale constant); `_stage_changelogs.py` now handles the dated
  heading, idempotently and without reflowing the file. The 0.26 release surfaced both:

  · **`bin/candor`'s `UMBRELLA_VERSION`** is not staged and preflight [4] does not check it, so the umbrella
    declared 0.25.0 while everything around it moved. Only `update-candor.sh` refused ("UMBRELLA_VERSION=
    0.25.0 but tag is 0.26.0") — and the consequence is not cosmetic: the tap formula's sha256 is computed
    over the TAG's tarball, so a tag whose `bin/candor` says 0.25.0 ships a brew umbrella that reports 0.25
    and sets `ENGINE_PIN=0.25.0`, i.e. fetches 0.25 engines under a 0.26 umbrella — verbatim the failure the
    ENGINE_PIN comment records from 0.18-through-0.23. Fixing it required force-moving a published tag.
  · **The umbrella CHANGELOG is DATED, not versioned**, so `_stage_changelogs.py`'s `## Unreleased` rename
    does not apply and its "(unreleased)" marker was left by hand. `release.sh`'s notes extractor now falls
    back for that shape, but nothing STAGES it.

  Both were the same shape: the stager knew about engines and forgot the umbrella is the seventh repo.

- **[FIXED FORWARD 2026-08-04 — one decision left for Tom] The umbrella carried TWO tags per release,
  `v0.26.0` and `0.26.0`.**
  `release.sh` tags `v$VER` like every other repo; it then calls `scripts/update-candor.sh "$VER"`, which
  tags whatever string it is given — and its own usage line says `v0.16.0`. So the bare form is created too,
  with a second GitHub release beside the first. **Pre-existing, not new: 0.25 has the identical pair**, and
  both resolve, so nothing is broken — the tap formula points at the bare tarball and `release-verify`
  checks the `v` one. Not fixed during the 0.26 run because the remedy is deleting published refs, which is
  not a thing to do mid-release.

  **Fixed forward:** `release.sh` now passes `v$VER`, and `update-candor.sh` reuses an existing tag/release
  rather than creating one — so it works both inside release.sh and standalone. The 0.26 tap formula was
  re-pointed at the `v0.26.0` tarball (sha verified against the URL, and the tarball confirmed to carry
  UMBRELLA_VERSION/ENGINE_PIN 0.26.0), and `v0.26.0` is now marked Latest so the releases page shows the
  canonical one. From 0.27 there will be a single tag.

  **DELETED 2026-08-04** (Tom's call): the orphaned `0.26.0` and `0.25.0` bare tags and their GitHub
  releases are gone. Checked first that nothing referenced them, that neither held any asset, and that each
  had a `v`-prefixed counterpart. `0.23.1`/`0.23.2` were deliberately kept — they predate the convention and
  are the SOLE releases for their versions, so they are history rather than duplicates. `release-verify`
  green afterwards and the tap URL still resolves 200.

  Residual, and it is the only one: the tap's git HISTORY contains commits whose formula pointed at the
  deleted tarballs, so `brew install` from a pinned old tap commit would now 404. Accepted.

- **candor-ts κ-batch: common CLI-tool packages — ✅ DONE (candor-ts 0.9.2, 2026-07-12).** `which`→Fs,
  `@webpod/ps`→Exec, `envapi`→Fs (member-precise: parse stays pure); zx `useBash`/`usePwsh` now Fs, κ ledger
  7→4. Pure libs (chalk/minimist/depseek) left as honest `invisible` (not curated to a pure claim). 6
  regression tests incl. the parse-pure fabrication guard. Committed+pushed; **not yet published** (npm ships
  with the next candor-ts release, alongside 0.9.1's warning fix). Origin dogfood detail:
- **candor-ts κ-batch: model common CLI-tool packages (from the VALID 0.9 dogfood, 2026-07-12).** Re-scanned
  `zx` WITH deps installed (the honest redo) — the correction held (chalk/bufArrJoin → `invisible`, Unknown
  82→55, all 55 genuine `dispatch:`/`callback:`; Exec/Net/Fs attributed honestly even through the invisible
  `zurk` wrapper via the visible `cp.spawn`; **no cardinal sin**). The one real, source-VERIFIED precision
  gap: a few effectful packages read `invisible` where κ could attribute the effect — **`which`→Fs**
  (isexe/PATH stat; uniform, whole-module safe; broadly used — best ROI), **`@webpod/ps`→Exec** (spawn/exec;
  verify members uniform), **`envapi`→Fs+Env** (readFileSync of `.env` — but MIXED: `parse` is pure, so
  member-specific `load`/`config`/`write`→Fs, NOT whole-module, per the argon2/AWS blanket-grant lesson).
  Optionally curate the obvious-pure ones (`chalk`, `minimist`, `depseek` → pure) to drop invisible noise.
  Rules go in `candor-ts/scan-core.mjs` kappa table; gate with the fabrication probe + re-scan zx (useBash/
  usePwsh should gain Fs) + regression tests. Precision (invisible→attributed), improves `deny Fs`/`deny Exec`
  gate fidelity; baseline-invalidating (⚠). NOT a cardinal sin — the effects are disclosed via `invisible`
  today.


- **0.9 dogfood — RETRACTED precision finding + the real fix + a methodology lesson (2026-07-11/12).** The
  dogfood on real code did its job: it validated the release (candor-scan on xh honest via the κ ledger; the
  `candor fix` remedy on a real xh Net violation was correct + useful) — but its two candor-ts "precision"
  findings (`chalk.grey`→Unknown, `bufArrJoin`→Unknown) turned out to be a **testing artifact**: `zx` was
  scanned on `zx/src` **without `npm install`**, so imports/types didn't resolve → conservative Unknown.
  Proven by controlled fixtures: a *resolvable* uncovered package member-access → `invisible` (κ) not Unknown;
  the exact `bufArrJoin` shape is PURE when the type resolves. candor-ts was already correct; the scope doc
  (`candor-ts/HOF-PRECISION-DESIGN.md`) is **RETRACTED** (correction at its top). **Real fix shipped**:
  candor-ts's "no node_modules → npm install" warning was silent here because it only checked the scan *root*
  (I scanned `src/`) and only counted `dependencies` (chalk is a devDependency) — now walks up to the manifest
  + counts devDependencies + regression test, so an un-installed scan is warned instead of silently reading as
  spurious Unknowns. **Methodology lesson** (see [[feedback-dogfood-proactively]]): always resolve deps
  (`npm install` / build) before scanning a real project — unresolved imports invalidate the results.
- **`candor-action-demo` workflow drift** — the live demo repo carries a **copy** of `adopt/candor.yml`;
  a change to the adopt starter does not propagate. Re-copy on adopt changes (it has already been
  re-copied twice), or add a sync check.
- **Vendored SARIF schema** — `integrations/github/sarif-2.1.0.schema.json` (from oasis-tcs/sarif-spec)
  powers the reporter's schema gate; it's a frozen standard, but note the provenance if it ever needs a
  refresh.

## Non-goals (decided — do not build)

- A "candor score" / cross-codebase **grade** — a single opaque headline number that ranks codebases.
  It fights the deterministic-per-function-facts positioning (spec §6.1), is gameable, and buries the
  signal. NB this does **not** rule out the fingerprint **structure descriptor** (component-transparent,
  delta-framed, explicitly not a grade — see *fingerprint* above); the non-goal is the opaque ranking
  number, not the explainable descriptor. Keep per-function facts + the explainable structure components.
- **Heavier per-engine dev-tooling** (rustfmt gate / `tsc --checkJs` / SwiftLint). Each was evaluated and
  declined with documented reasons; every engine already gates its idiomatic bug-pattern linter
  (clippy `-D warnings` / eslint / Error-Prone + `-Xlint`) plus a warnings-as-errors equivalent.

## Recently shipped (context; older entries pruned from the per-engine files)

- **Floors 0.19 → 0.23 + the 0.23.1 perf/soundness patch (2026-07-17 → 07-20).** Four ladder cycles plus a
  within-spec patch. **0.19** reason-scoped `Unknown` (the DI/reflection deny-all-able dealbreaker — the
  academic referee's #1); **0.20** the `Net` destination-class + `blindspots --stats`; **0.21** the
  completeness manifest (fail-closed exit-2 incomplete verdict — a machine-consumer cardinal-sin closure);
  **0.23** the cross-package interface-dispatch rung (`interfaceUnion`, `CANDOR_WORKSPACE_CHAIN`-gated so a
  default report stays byte-identical). Then **0.23.1 (2026-07-20)** — a WITHIN-SPEC engine patch: an engine-
  **performance** sweep that killed two super-linear cliffs family-wide (java `chaTargets` memoize +
  `Surface.nearestSource` presort → 3.79× at 4585 classes; worklist `computeFixpoint`/`propagate` in
  java/rust/ts → O(V²)→linear on deep call graphs; swift O(N²) loop-invariant hoist → 8.4× — all
  byte-identical-verified, with one honest revert where the data didn't support it, swift's fixpoint) + the
  `Llm` model-SDK builder/ctor fabrication fix AND its **review-caught silent-under-report correction**
  (a workflow-backed high-effort review before publish caught that the first cut's dispatch *allowlist*
  silently under-reported Spring AI streaming/embedding — re-done as a denylist over the sound blanket;
  the denylist-over-allowlist rule). Umbrella patched to **0.23.2** to fix a stale `ENGINE_PIN` (it had
  lagged at 0.18.0 since the 0.18 ship, so `candor update` fetched 0.18 engines under a 0.23 umbrella;
  `release-preflight` now gates the pin — the umbrella-distribution notes). Published across every channel;
  release-verified live. Full ladder detail in the versioning-ladder history.

- **Spec 0.9 — the remedial-loop rung (2026-07-11).** The ladder's second full cycle. 0.9 is a **tier-2
  (pinned-tool-surface) rung** (SPEC.md §"Conformance tiers", new): no report-schema or verdict change — a
  0.8 report and a 0.8 `--gate-json` verdict are byte-identical under 0.9 — but the **remedial tool loop**
  (`fix`/`fix-gate`, `unverified`, and the gate's provable-purity auto-disclosure) is promoted from
  shipped-but-optional into the pinned §3.1/§3.3 contract, so a 0.9-conformant engine MUST carry it. All
  code engines declare `0.9` at **0.9.0** (candor-java, candor-scan+candor-query, candor-ts, candor-swift;
  candor-agents rides behind at 0.9.0), per the convention that release major.minor tracks the spec. The
  **conformance suite now tags every PART tier-1 (interop floor) or tier-2 (tool surface)** — making the
  version trigger unambiguous: a tier-1 change bumps the floor, a tier-2 addition promoted to required does
  too, a patch touches neither. Conformance green four-way (incl. the 0.9 tool parts 12b/12c/12d).
  Committed across all repos; **not yet published** (awaiting an explicit ship — a re-publish of
  candor-query needs candor-classify 0.5.10 out first, the shared-predicate fold's new public API).
- **The measure-and-surface arc (2026-07-11).** A full loop, end to end: (a) the **owner digest** (P1–P3)
  — `candor-agents digest` renders an aggregate protection report over the gate log; the gate now logs
  outside the agent hook (`log-gate`) and delivers on a schedule (candor-agents 0.8.2/0.8.3). (b) **Family
  changelogs + `candor.poly.io/releases`** (link-out) + a standing "always cut a gh release" rule
  (RELEASING.md). (c) A **soundness wave**: ten cardinal-sin fixes across two engines — swift R22–R29 +
  R28 (0.8.7→0.8.10, the accessor + generic + conditional-conformance veins) and rust-scan R30/R31 (0.8.8,
  trait-default + generic-field) — **every FIXABLE silent under-report now closed+gated; the 7 remaining
  (R2–R8) are fundamental syntactic limits.** Validated on real third-party code (swift-argument-parser: no
  fabrication, Env ground-truth-correct) + the kernel oracle. (d) **Cross-model evals**: completeness holds
  tier-flat (~14–15/16, control 0–6, largest lift for the weakest model) and the token saving is consistent
  (~1.37×) from Haiku 4.5 to Fable 5 — pre-registered, 160 agents, blind-judged (`candor-rust/eval/scaled`,
  RESULTS-xmodel + RESULTS-speed-xmodel). The speed A/B is now runnable via subagents (per-agent telemetry
  is exposed). (e) The measured case is **surfaced** at `candor.poly.io/evidence/`. Soundness instrument
  (candor-spec/SOUNDNESS.md) fully updated throughout.

- **Spec 0.8 + the PR-native gate + the adoption funnel (2026-07-01/02).** The week's arc, end to end:
  (a) **versioning ladder** adopted (minor rungs reference-led, floor conformance-pinned; SPEC.md
  §"Versioning policy") and ran its first full cycle — **spec 0.8** (`--gate-json`, the structured gate
  verdict `{spec, ok, violations:[{rule,fn,effects,detail?}]}` from the same check that sets the exit
  code) shipped across **all four engines and every channel**: candor-java v0.8.0 (GitHub/jbang, Java-17
  bytecode), candor-swift v0.8.0, candor-ts 0.8.0 (npm), candor-scan 0.8.0→**0.8.1** + candor-report 0.5.7
  (crates.io); conformance PART 12 pins the verdict (006+008) across all four; spec tagged `v0.8`.
  (b) **PR-native SARIF surfacing**: `integrations/github/candor-sarif` (report+verdict → SARIF 2.1.0,
  loc→repo-path, codeFlows from `path`, fingerprints incl. effects, OASIS-schema-validated, dogfooded on
  candor-java itself which caught a fingerprint-collision bug) + `adopt/candor.yml` wiring — **validated
  in real GitHub Actions** (candor-action-demo; the E2E caught 3 CI-only bugs: jbang trust, Java-21→17
  bytecode, `actions:read`). (c) **Adoption front-end**: `candor-init` (policy proposed from what the code
  already does) + `candor-init.sh` (one-command scaffold). (d) **`.candor/config`** reference impl in
  candor-java. (e) **Umbrella CI** (`integrations.yml`) gating the reporter/stop-hook/init suites — the
  repo previously had none. (f) A **family CI sweep** fixed stale smoke assertions (java spec-0.8, swift
  stderr/masking wording) + the rust self-guard baseline. (g) **candor-scan 0.8.1**: a critical spec
  review caught the workspace `--gate-json` overwrite (a clean last member masked an earlier violator's
  verdict — `ok:true` beside exit 1, violating §3.3's MUST); fixed by accumulating across members.
  (h) Agent-loop dogfood: the stop-hook block notice now names the cause; `test-stop-hook.sh` locks the
  hook's JSON contract.
- **First-run visibility + install friction (2026-06-25).** All four engines print a one-glance effect
  summary by default; candor-java fails loud with actionable guidance on a missing/unbuilt path. Website:
  a faithful "what you'll see" sample on candor.poly.io. Embedded AGENTS.md copies re-synced + maintainer
  notes added so a doc edit can't silently drift.
- **Real-world corpus campaign + all-engine publish (2026-06-22).** Ran every engine on real OSS; fixed the
  last live silent-under-reports and shipped all four: candor-ts **0.7.5** (npm), candor-scan **0.7.2**
  (crates.io), candor-swift **v0.7.3**, candor-java **v0.7.11** (incl. the Redis→Db reconciliation).
  Decision recorded: wire/HTTP datastores (ES/OpenSearch/Solr/InfluxDB/Couchbase-raw) **stay Net**.
- **Cross-model eval (done 2026-06-22).** Real-world speed + decision-quality A/B across four model tiers
  on two real crates, N=8/arm: control recall climbs with model tier (60%→99%) while **treatment is
  model-invariant at ~100% recall/precision** (one deterministic `candor-query callers`). Results in
  `candor-rust/eval/scaled/` + `.../agentuse/`. _Remaining:_ surface on candor.poly.io (Deferred).
- κ persistence coverage (candor-java 0.7.9 / 0.7.10): Hibernate-6 / Jakarta Data, Panache, Micronaut Data,
  Ebean, ActiveJDBC, jOOQ + the general modeled-base-subclass fix; repo pure-`default` fabrication fix;
  declarative HTTP-client interfaces → Net.
- `containment` in the cross-engine conformance differential (PART 11); adoption starter (`adopt/`) +
  5 case studies (`docs/`); candor-swift realizes the MODEL.md vocabulary as named types.

## CI/release speed — what is left, and what must not be tried

Measured 2026-08-20 (see the candor/candor-spec/candor-rust changelogs for the changes that landed):
release ladder ~30min → ~5-8min; candor-spec conformance 18-19min → 15min; candor-rust ci 9-14min → 6min.

**candor-ts ci (~8min) is the remaining floor and two obvious optimisations are both wrong.**

1. *Parallelise the battery's suites on one runner.* `test.mjs --parallel` (81s local) and
   `test-lsp.mjs` (57s local) are the cost, and running them together would roughly halve the job.
   But `test-lsp.mjs` and `test-watch.mjs` both carry **15-second deadlines**, and a CPU-saturating
   neighbour turns those into a flaky gate. Four minutes is not worth a gate nobody trusts. (The same
   question asked of the conformance generators had the opposite answer — no internal timeouts
   anywhere — which is why those *were* parallelised.)
2. *Split the battery across two CI jobs by suite name.* No contention, so the deadlines are safe —
   but candor-ts's ci.yml runs `npm test` as ONE command on purpose: *"Driving it through the script
   keeps CI in lockstep with `npm test` so a gate added locally can't be silently missing here (the
   probe + mcp/watch suites used to be)."* Enumerating suites in a workflow reintroduces exactly the
   drift that comment closed. And the non-battery steps total ~25s, so there is nothing to win anyway.

What WOULD work: making `npm test` itself cheaper inside the package, or larger runners (paid).

## CLOSED 2026-08-20 — candor-ts's and candor-swift's "no sources" refusal short-circuited the ⟨0.30⟩ peek

**FIXED in candor-ts and candor-swift; pinned by conformance PART 56.** When a policy is configured and
there are excluded files to read, the run continues to the peek and names them; the refusal becomes a
third exit-2 arm beside the ⟨0.21⟩ unanalyzed and ⟨0.30⟩ out-of-scope causes. Verdicts unchanged — exit 2
before, exit 2 after. candor-java is unaffected (a class-directory/jar target has nothing beside it to
peek). **The clean-sibling control earned its place twice**: it caught ts's first attempt answering
`policy ✓` at exit 0 over a tree with zero analyzed files, and then caught the same shape in candor-rust
— see the NEW item below.

Found corpus-testing the PUBLISHED `candor-ts@0.30.0` (not the tree) the night ⟨0.30⟩ shipped.

**Not a cardinal sin** — the verdict is exit 2, fail-closed, and the gate never certifies. It is a
DISCLOSURE divergence: on the same shape, rust names the offending function and ts names nothing.

### Reproduction (30 seconds, no corpus needed)

A declarations-only package whose JavaScript performs the denied effect:

    dtsonly/package.json                {"main":"./distribution/index.js","types":"./distribution/index.d.ts"}
    dtsonly/distribution/index.d.ts     export declare function go(): void;
    dtsonly/distribution/index.js       export function go() { return fetch("https://evil.example/x"); }
    pol.txt                             deny Net

    npx candor-ts@0.30.0 dtsonly --policy pol.txt
    → candor-ts: no TypeScript sources under dtsonly          exit 2, NOTHING named

**Control 1 — the effect is really there.** Same tree, `--allow-js`:

    → [AS-EFF-006] `distribution.index.go` performs { Net }, forbidden by policy   exit 1

**Control 2 — rust, on the analogous shape, DOES name it.** A crate with no `.rs` sources and a
`build.rs` running `curl`, under `deny Exec`:

    → candor-scan: ⚠ build::main performs Exec — OUTSIDE this scan's scope (build-script), so the
                   gate did NOT judge it.   build.rs
    → exit 2, function named

### Why it matters

⟨0.30⟩'s premise is that the peek *resolves a concrete denied effect and names the function* — that is
the measurement the whole rung was justified on. Here the user is told only "no TypeScript sources",
which is accurate and useless. Whether they get names turns on an incidental layout detail: `axios`
ships `index.d.ts` at the package ROOT and gets 13 named findings; `ky` ships its declarations under
`distribution/` and gets a bare refusal. Same situation, different information.

Measured on the real packages: `ky`'s JavaScript gates `policy ✓` under `--allow-js`, so nothing is
hidden *in that case* — but the fixture above shows the path is silent when there IS something to say.

### The fix, and the thing to be careful about

Run the peek before the "no sources" refusal, so the refusal carries `outOfScope` when the excluded
files hold a denied effect. **Write the second fixture first** — a tree with no sources and a CLEAN
sibling must still refuse at exit 2 with an empty peek, or the fix trades a silent refusal for a
fabricated finding ([[feedback-fabrication-fixes-cause-misses]] is the standing warning here).

Check java and swift for the same short-circuit before calling it closed; only ts and rust were
measured.

## WITHDRAWN 2026-08-20 — "candor-rust certifies a tree it read nothing of" was MY error, not a defect

**I filed this as a cardinal-sin-direction defect and it is the SPEC'S RULING.** Recorded in full because
the mistake is more instructive than the finding would have been.

§⟨0.24⟩: `analyzed.count == 0` is *"I judged nothing at all"*, and the harm the spec names is a **deleted
DISCLOSURE, not a moved verdict** — *"verdict-preserving, exit unchanged, the caveat travels"*. candor-rust
has a `gate-equivalence` row called `judged-nothing` that pins exactly this: exit code and verdict document
UNMOVED.

**How it surfaced.** I wrote the fix before reading the contract. It passed its own regression guard (4/4)
and then broke §3.1 ROUTE EQUALITY on the first real check — `scan --policy` exit 2 vs `gate --report`
exit 0 — because the report route follows the ruling. The route-equality check is the only reason this was
caught before it shipped. Reverted.

**The standing hazard, verbatim:** *a theory wrong in the STRICT direction produces a finding shaped
exactly like a real defect — check which side the contract is on FIRST.* I checked the engines against each
other and never checked either against the spec.

### What IS open, and it is a spec question

ts and swift REFUSE this shape (exit 2, declining to produce a judgement at all — as rust does for a target
that does not EXIST); candor-rust judges nothing and discloses (exit 0). Both are defensible under
different clauses, and they are not the same answer. Which convention the family wants is Tom's ruling to
make; PART 56 NAMES the divergence on every run until it is made.

The original text follows, for the record.

Found by PART 56's CLEAN control — the arm written to stop a disclosure fix fabricating findings caught
what looked like a false all-clear in a third engine.

    rsclean/Cargo.toml     [package] name="rsclean" version="0.0.0" edition="2021"
    rsclean/src/           (empty — no .rs sources at all)
    rsclean/build.rs       fn main() { let _ = 1 + 1; }        # clean
    pol.txt                deny Exec

    candor-scan . --policy pol.txt
    → candor-scan: policy ✓ (advisory floor …)      exit 0
    → report: analyzed {count: 0}, functions 0, outOfScope 0

**A green over a tree the engine never read.** candor-ts and candor-swift refuse the same shape at exit 2
(`a gate cannot be green over a tree it did not read`), and candor-rust ALREADY refuses a target that does
not EXIST for precisely this reason — its own comment says "a typo'd path in CI is a PERMANENT GREEN". An
existing path holding nothing analyzable is that same permanent green, one step along.

**A fix was attempted and REVERTED the same night.** Keying the new arm on `gate::GATE_ANALYZED` made a
NORMAL crate with a real `src/lib.rs` exit 2 — the accumulator is not populated on the simple path, so it
is not the "did we read anything" signal it looks like. The right signal needs care; the regression guard
(a normal clean crate must stay 0, a normal violating crate must stay 1) caught it immediately and should
be written before the next attempt.

Until then PART 56 NAMES this divergence on every run rather than asserting it away.

## ⟨0.31⟩ IS BUILT AND HELD — do not publish any engine under `spec: "0.30"`

**Landed 2026-08-20 at HEAD, deliberately NOT released.** The unevaluable-target cause (§3.3's fourth):
a target that exists but holds no file the engine can read is a refusal, exit 2, no report. candor-rust
changed; ts/swift/java already behaved this way un-enumerated. Four-way conformance OK, PART 56 asserts
all three engines asked, MUST ledger classified.

**THE RELEASE HOLD, and why the tooling will not enforce it for you.** rust's change is the one
non-additive cell (0 → 2). A routine candor-rust-only publish would ship it while the published floor
still enumerates THREE exit-2 causes — and `release-preflight` would not object, because conformance is
GREEN (the row pins the new behaviour) and nothing compares an engine's behaviour to the FLOOR's text.
So: **no engine publishes a changed verdict under `spec: "0.30"`.** ⟨0.31⟩ rides the next rung; the
clause and the row sit at HEAD until then, which is how ⟨0.30⟩ itself was built (built four-way and
conformance-pinned while the floor was 0.29).

Two engines' behaviour is unchanged by the hold: ts and swift moved 2 → 2 (disclosure only) and are
patch-safe.
