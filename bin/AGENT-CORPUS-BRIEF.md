# The corpus-round agent brief

Paste this to any agent about to run candor over real third-party code — a corpus round, a spot-check
before/after a release, or "does this actually work on a real repo." It exists because a round run the
night of the 0.33.0 cut found **thirteen cardinal sins (silent under-reports) across all four engines,
plus a nine-crate classifier class** — every one against the PUBLISHED artifacts, hours after that same
release passed a three-lens review panel, four-way conformance, CI on seven repos, and URL-resolving
verification. The method that found them lived only in a scratchpad and a prompt. Ten rules; each is a
measured finding from that round or the ones before it, not a style preference.

## 1. Calibrate before trusting any clean result

Seed a violation the policy denies, on the SAME tree, and prove the engine catches it *first*. Without
this, a broken scan and a clean codebase produce the identical output. This was the single
highest-value step every productive agent took that night.

## 2. Scan libraries as a dependency of a hand-written consumer, not standalone

A standalone scan answers "does the engine parse this code"; a consumer crate exercising the library's
real public API answers "does the engine understand how this code is USED" — a different, harder
question. candor-rust's standalone scans found nothing; both of its real findings came from a
hand-written consumer.

## 3. Test PUBLISHED artifacts, not HEAD — and prove it

Prove the binary's **identity** (`--version`) and its **freshness** (`ls -lT`, never `ls -t | head`). A
stale 0.27 jar was once selected by the latter; a swift binary once predated HEAD by one minute and was
used anyway. `--version` may not change between builds, so freshness is timestamp **and** behaviour —
check both.

## 4. A comparison is evidence only if the arms differ in exactly the thing under test

State what was held constant, for every comparison. One finding last round was FALSE because its two
arms differed in two variables (a producing scan with vs. without `--policy`) — it was ⟨0.32⟩ working as
designed, not a bug. Separately: two *mechanisms* that produce the same effect *label* can mask each
other — a java audit nearly misread a working `<clinit>` fold as covering a broken method-join because
both charged `Env`. Prefer distinguishable effects per mechanism under test.

## 5. Include a tree shape the ecosystem's convention hides

Every SPM package excludes `Package.swift`, so no SPM tree ever reaches the zero-exclusion code path —
a bare non-SPM directory found a defect invisible to normal use. Likewise: a package with a minified
`main` beside unminified `.d.ts` files. Ask what shape the *convention* makes unreachable, and include
one.

## 6. "0 violations" is not evidence until the instrument is proven able to fail

`blindspots` once answered "no Unknown sources — every call resolved" over what was actually a silent
filesystem walk that read nothing. A verb's own confidence is not evidence; only a seeded failure the
verb catches is.

## 7. Stop on a cardinal sin and report immediately — but say what you left unexamined

Don't finish the sweep once you've found one; report and hand off. But name, explicitly, what the stop
left unexamined — three rounds of early stops left tails that later rounds found further defects in.

## 8. A clean result is a LEAD, not a conclusion

java looked clean through two full rounds. Asking *why*, with an explicit instruction to attack the
answer, broke it in one attempt. A hypothesis you did not try to break is a guess.

## 9. An audit's boundary must not be drawn around its own trigger

Nearly every audit that night scoped itself to the one pattern in hand and missed the next instance — a
walkdir audit ruled "unique victim, not a class" and cited the `ignore` crate as the sound model;
`ignore` had the identical hole one constructor over, and a later sweep found nine more victims from it.
The one audit that grepped every call site instead of the handful it was handed came back verifiably
clean. Widen the boundary past the trigger before trusting a "no class here" verdict.

**A boundary drawn around a NAME is as bad as one drawn around its trigger.** Measured 2026-08-28: an
audit asked *"is there a `platform-pruned` class?"*, correctly answered no, and filed a completeness
hole — while a generic diff committed nine days earlier was already sweeping those files into
`excluded[]` under a different label. Every literal statement in the entry was true and its conclusion
was false. Grepping for the mechanism you EXPECT cannot see a different mechanism already delivering the
property. **State the property the report must have, then find every route that could produce it** — not
the one you have in mind.

## 10. Findings need a reproduction

If it cannot be minimised, keep the larger reliable repro rather than a small one that only sometimes
fires. A repro that fires 6/10 times will be "unable to reproduce"d by the next reader.

---

## Standing per-engine traps

Not method — recurring, engine-specific gotchas that cost real time every time they resurface:

- **JS truthiness** coerces surprising values (`0`, `""`, `[]` semantics differ from other languages).
- **Foundation bridging** coerces `1`/`0` to `Bool` silently in Swift/Obj-C interop.
- **Gson** coerces types across its (de)serialization boundary without erroring.
- **`cargo build --release` can exit 0 without rebuilding** — check the binary's mtime, not the
  command's exit code.
- **`swift test` reports "0 tests in 0 suites"** on a build failure, not a suite failure — read for
  the zero, not just the exit code.
- **`(0 unexpected)`** in swift/XCTest output counts *crashes*, not *failures* — a crashed run can
  print this and look clean.
- **`$?` after a pipe or command substitution** reports the last command's status, never the one you
  meant to check.
- **A scan run with no `--out`** writes into the repo tree and dirties it — always pass one.

---

Full context: `bin/corpus.sh` (the automated, hermetic corpus harness — this brief is for the manual,
ad-hoc rounds that harness doesn't cover, chiefly published-artifact and cross-arm comparisons),
`TESTING.md` (family test standards), and the umbrella `CHANGELOG.md`'s dated entries for the round
this brief was written from.

## 11. Verify LOCALLY. Treat CI as confirmation, not as the gate.

`bin/verify-local.sh` runs CI's union — every engine's real suite. `candor-spec/conformance/run.sh` runs
the four-way differential. Between them, minutes on this machine answer what a queued runner takes an hour
to. CI's genuinely unique contribution is narrow: the released-artifact arms.

**Do not park waiting for a CI notification.** Half a dozen agents in one session stalled twenty minutes
each on runs for work they had already proven locally, and a GitHub outage once orphaned three runs that
would never start at all (zero jobs, `updated_at == created_at`, uncancellable and undeletable). Run the
local checks, push, say once that CI is in flight, and send your report.

`verify-local.sh` is also **stricter** than CI in at least one place — it caught a changelog lag that
would have aborted the next release at step 0. A local green is worth more than a badge, not less.

This machine (`anya.local`, 12 cores) is dedicated to this work. Long runs are cheap here. Sequence
anything that shares a cache — the cargo registry, `.candor/` — because concurrent agents on one box do
contend, and one round had to pin to pre-drift crate versions after another agent's fetch moved them.

## 12. A cited BACKLOG or SOUNDNESS entry is a snapshot, not a fact — verify it against HEAD

If your brief quotes a backlog entry, a SOUNDNESS row, or a "known" limitation, **check it still holds at
HEAD before you act on it.** These are written once and then trusted, and they go stale silently.

Measured 2026-08-28, in one session: a `[P1]` entry asserting "confirmed still absent from `excluded[]`"
had been closed by a commit dated SIX DAYS BEFORE the review that filed it. A SOUNDNESS row listed a
defect as SILENT/open that the engine had already fixed. A rejection rationale ("a blanket fix would
flood real framework code") had never been measured against any code containing the construct — and when
measured, was true for one framework and entirely false for another.

The cheapest version of this check is a `git log` on the cited file since the entry's date, and one run
of the cited repro against HEAD. Report a stale entry as a finding: **the correction is worth as much as
the fix**, because everything downstream was reasoning from it.

# THE ATTACKS THAT WORK

Rules 1–12 are principles. These are the specific things to *run*. Each one below found real defects on
2026-08-29 — 53 findings, 19 cardinal sins, across four engines, the conformance suite, the CI machinery,
the integrations and the release scripts. Counts are given so you can judge which to reach for first.

## A. The revert test — for a FIX
**Revert the fix. Does any test go red?** If not, the fix is unprotected and reads as covered.

Found 4× in one day, in fixes that had shipped hours earlier. candor-java `a034371` — a ~470-line
cardinal-sin fix — was reverted entirely and **855/855 stayed green**; its commit message described "two
fixtures" and "five controls" that were never committed. candor-swift `7a89dbc` was worse: a test *named*
for the case existed and could not discriminate the fix from its absence, because both its callers landed
on `Unknown` either way.

**A test that passes with AND without the fix is worse than no test, because it reads as coverage.** Prove
the red by actually reverting, not by reasoning.

### A.1 — the revert test does NOT apply to a commit that hardens a TEST
Measured 2026-08-30 on candor-spec. Most of its recent commits harden `mutation-gate.sh`'s own poison
generation rather than fixing a checker. **Reverting a poison-hardening commit and re-running against the
current, already-correct checkers is guaranteed green regardless** — a correct checker rejects weak and
strong poison alike. Applied naively it would have declared NINE commits "protected" on evidence that could
not have said otherwise.
**The inverted form is the real test:** degrade a copy of the checker exactly as the commit describes, then
confirm the OLD poison set wrongly ACCEPTED it and the NEW one CATCHES it. Seconds per bypass via the
extraction helpers, versus eight minutes for a full suite run that proves nothing.

### A.2 — a test inherits the blind spot of the bug report that prompted it
**Three repos, three instances, one night.** This is the audit-boundary rule (§9) applied to FIXTURES.
- **rust**: four calibration tables share one impostor-exemption shape; every fixture drove only `log`, the
  crate the original bug happened to involve. Deleting the guard from the other three left the suite green.
- **swift**: a platform filter whose own comment says "same as the Xcode side". The Xcode side was untested
  AND had no safety net — the file vanished from the scope set with zero disclosure.
- **java**: one CHA exemption with two independent call sites; the second reachable only through a generic
  `Comparable<T>` bridge across a chained dependency.
- **umbrella**: nine untested guards in `release-preflight.sh`, because **every fixture the suite builds is
  internally consistent on exactly the dimensions those checks police** — ~250 rows could never fire them.

**When you fix a bug, ask what ELSE has this shape, and write the fixture for the sibling you were NOT
handed.** A comment saying "same as X" is a direct instruction to go test X.

## B. The unconditional-pass test — for a CHECKER
**Replace the checker's body with `exit 0` / `sys.exit(0)`. Does the suite notice?**

The single highest-yield attack of the day: **13 of 13 standalone conformance checkers survived it**,
including `check_honesty.py` — the family's one cardinal-sin detector, whose own CONTROLS comment read
"none" — and the flagship route-equality check. Cost: minutes per checker.

## C. The guard-deletion test — for a GUARD
**Delete each guard in turn. Does anything go red?** Found a `RS_PY_STREAM_FAILCLOSED` empty-stdin guard
with zero fixture coverage, and several others. Cheap, mechanical, and it distinguishes a guard that is
tested from one that is merely present.

## D. Near-miss poison, never absence poison
**A poison document must be structurally valid and differ from a good one in exactly ONE field's VALUE.**
An absence poison (`{}`) only proves the checker looks at a key — never that it looks at what the key
SAYS. That distinction hid bypasses through three consecutive hardening rounds.

The comparison vocabulary is tiny and closed — identity→truthiness (`is not False` → `not x`), exact
equality→membership/subset/falsy, a dropped `isinstance`, absent-key blindness. **`conformance/mutation_poison_gen.py`
now derives these from each checker's own source**, because hand-authored poison encodes only the
wrongness its author imagined, and four rounds measured that ceiling.

## E. The over-charge control, on REAL code, on ENOUGH of it
Every fix needs the control for the direction it did NOT intend. The best of the day: candor-java's record
fix checked against **388 real third-party jars** (one diff, honest `invisible`, zero fabrication);
candor-rust's peek fix against its own 4 crates under a real policy (77 and 128 findings, zero diffs);
candor-swift against swift-collections' 4,965 units.

**And enough corpora that the choice does not decide the answer.** A three-corpus measurement declared a
fix's over-charge "zero"; a fourth corpus showed +22 rows, and seven showed the true range (0–9.6%).

### E1. WHEN THE EVIDENCE IS A BIG A/B, THE **REMOVALS** ARE THE CLAIM UNDER TEST
A fabrication-fix reports something like `ADDED 2  REMOVED 66  CHANGED 318` and explains the removals as
fabrications correctly excluded. **That explanation is a hypothesis, and it is the one that hides a
cardinal sin**, because a removed row means the engine now certifies that function PURE — absence is the
sin's signature, so a wrong removal and a right one are the same bytes.

Measured 2026-09-01, candor-java. The fix traced **three** of the largest diffs, found them consistent,
and said so honestly. A full audit of all 66 — every row, no sampling — found **73 rows correct and 35 a
second, different cardinal sin**: a field write judged by LINEAR bytecode adjacency when the write was a
control-flow merge, so `this.x = supplied != null ? supplied : defaultLambda;` recorded an arbitrary
caller-supplied callback as the safe default. Four unrelated real libraries, including a public AWS SDK
builder API. `deny Unknown` went exit 1 → exit 0.

So:
- **Audit the removal set in FULL, not a sample.** Tracing the biggest few is not testing the claim; the
  35 bad rows were not the biggest.
- **Ground-truth from `javap`/source, never from candor's own report.** Do not let the engine adjudicate a
  question about the engine.
- **Bucket by MECHANISM, not by count.** "66 removals" is not a finding; "two mechanisms, one correct and
  one a sin" is. A second cause hiding behind the first is what gets missed once the first is found.
- **Report the near-misses.** That audit self-caught and retracted a suspected third mechanism after
  re-checking raw JSON against its own paraphrase, and marked its two weakest rows "spot-checked, not
  proven". An audit that hides its own near-miss has told you nothing about the rest of it.

The mirror of section E: the over-charge control guards the direction the fix did not intend, and **the
A/B's removal column is where the fix's INTENDED direction goes too far.** Both are live at once — the
measured rate here is 4 defects in 5 fabrication-fixes, two of them cardinal sins.

**COUNT HITS ON THE CHANGED BRANCH, OR YOUR ZERO-DIFF MEANS NOTHING.** Before trusting a byte-identical
A/B, prove the corpus can REACH the code you changed. Put a counter in the changed branch, run the A/B,
and **report hits-per-corpus alongside the diff**. Zero hits ⇒ the A/B is SAFETY-ONLY and must be written
down as such **in the row, at the time of writing** — not discovered later.

Measured 2026-09-01, four times: R79, R85, R87 and R92 each ran a full A/B, returned byte-identical, and
only afterwards was it found — by grep, post-hoc — that the corpus contained **zero instances of the
shape**. Three of those were the same four Swift projects, which contain no top-level `public let`/`var`
at all. R84 is the one that did it right: it instrumented the check, *"since an unchanged row is not
evidence the new code ran"*, and that is how its two flagged clusters were settled rather than assumed.

**A zero-diff over a corpus that cannot trigger the change is the most flattering number available and the
least informative.** §E3 already demands a fixture that compiles and runs; this is the same rule one level
out — **demand a corpus that reaches the branch.** When it cannot, the answer is not a bigger corpus, it
is a RECALL HUNT: find real code with the shape, or vendor real declarations into a harness. That method
produced the strongest evidence of the whole session — `deny Fs` exiting 0 over real file deletion in
jamf/Replicator, and `deny Net` exiting 0 over Alamofire's own request path.

**KEY THE DIFF ON EVERY FIELD, NOT JUST `inferred`.** A diff keyed on the effect set alone is blind to
every disclosure channel — `incomplete`, `declared`, `invisible`, `unknownWhy`, `unresolved`, `netClass` —
and those are exactly where fail-closed behaviour lives. Measured 2026-09-01, three times in one day:

- A java whole-day audit reported R86/R87 as contributing "~0 rows". True of `inferred`, and false in
  substance: the real change was `incomplete: None -> ['Fs']` on the ignite-core row that fix was written
  for. In the 41 jars it still had reports for, **110 further rows changed `incomplete` while `inferred`
  stayed identical** — across the other 284 jars, unmeasured.
- A rust audit's narrow diff showed 8 removals with no visible cause; re-reading the FULL record showed
  every one carried `invisible: ["diesel_derives"]` in the pre-image, which is what identified them as a
  precision gain rather than a loss.
- A second rust pass found 0 lost effects on a narrow key and exactly 2 on a broad one — both benign, but
  invisible to the narrow diff.

Run the narrow diff for the headline number if you like; **audit on the wide one.** And say which you
used, because "0 rows changed" means two different things.

**PUT THE NUMBERS IN THE COMMIT MESSAGE.** ADDED/REMOVED/CHANGED, the corpus, the pre-image and how it
was proven pre-fix. An A/B reported only in a transcript is not re-checkable by anyone later, and the
next reader cannot tell a measurement from a claim. Measured 2026-09-01: a later agent read `1abc71d`'s
message, found no A/B in it, and concluded none had been run — the full isolated 325-jar A/B *had* been
run, and it had turned up a real defect instance in `ignite-core`. Both halves of that are findings: the
inference from a silent message was wrong, **and** the evidence really was unrecoverable from the repo.

### E2. RUN `assert-audit.sh` ON YOUR OWN DIFF BEFORE YOU REPORT
    bash bin/assert-audit.sh <repo> <range>

Measured 2026-09-01: four engines shipped ⟨0.35⟩ fixes, **every one carried a comment asserting a
property, and every one of those assertions was false** — ts's "PROVEN — not guessed" (guessed; a
cardinal sin), java's "inert, not wrong" (wrong), rust's "already works" (on one syntax), swift's stated
limit (narrower than the hole). A documented *limitation* at least names a gap; a documented *guarantee*
closes the question AND licenses narrowing a sound over-approximation, so it converts straight into a
silent under-report. In every case the assertion was written by the commit that needed it to be true.

The tool does not judge whether your claim is correct — no grep can. It asks the cheaper question that
would have caught the real one: **you asserted safety; did you add a test in the same change?** It fails
when assertions land with no test file touched anywhere in the range (candor-ts `7ecda11` asserted
"PROVEN" and changed only `scan.mjs` and `CHANGELOG.md` — a changelog is not coverage), and otherwise
prints the assertions as a checklist. **Read that checklist**: those lines are the highest-value ones in
your diff, because the logic gets read and the assertion gets believed.

If you cannot write a fixture that would fail were the claim false, **word it as the assumption it is**.

### E3. A CONTROL THAT ASSERTS AN ABSENCE MUST COMPILE AND RUN FIRST
**Prove the program exists before trusting what the engine says about it.** A control whose fixture cannot
compile is not weak evidence, it is NO evidence: no correct engine could pass it differently, and no
broken one would be caught.

Measured 2026-09-01, candor-swift, three times in one vein:
- `testAmbiguousCrossModuleGlobalNameResolvesNothing` asserts a caller stays absent when two modules
  declare the same public global. That program is a **compile error** in both language modes. No reachable
  input can reach the branch it pins.
- `testNonPublicCrossModuleGlobalDoesNotResolve` asserts a caller stays absent for an `internal` global in
  another module. Also **uncompilable** — a direct cross-module reference to an internal symbol is
  definitionally invisible in Swift.
- **The coordinator re-verified the second one independently, built the same uncompilable fixture, watched
  the caller stay absent, and reported it as a passing control** — on the same day, in the same session,
  as hardening four other instruments for exactly this property.

Two of the four controls that row was accepted on could never have failed. The conclusions happened to be
right; the evidence was empty.

**This bites hardest on absence-shaped assertions, which is most of this project's controls** — "gains
nothing", "stays pure", "does not resolve", "is not charged". The engine omits pure functions by design,
so ABSENCE IS ALSO WHAT A BROKEN ENGINE PRODUCES, and an unreachable fixture makes the two identical.
`swift build` / `javac` / `tsc` / `cargo build` the fixture and RUN it. If it cannot run, the control is
asserting something about nothing — delete it or make it reachable, and say which.

## F. Translate the QUESTION across engines — not the defect
The reusable artefact is never the bug, it is the question that found it.
- swift's peek scope-match sin → asked of the other three → **cardinal sin in ALL THREE**, by a simpler mechanism.
- rust's `Drop` lost in a move-captured closure → asked of swift's `deinit` → **same class, four binder shapes silent**.
- java's `--policy` accepted-and-dropped → **rust and ts identical**.

When one engine yields, immediately ask the other three. Their mechanisms differ; the question does not.

### F1. THE STANDING QUESTION LIST
Measured 2026-09-01: four agents, one per engine, given these seven questions instead of a list of bugs.
**Six findings in one pass, four of them cardinal sins, every one a NEW instance rather than a re-find** —
and the questions came from defects that had just been fixed elsewhere. Ask all seven of any engine; they
are cheap and they keep paying.

1. **Adjacency where the question is control flow.** Does anything decide from a syntactically or
   instruction-adjacent neighbour where the real question is a dataflow merge? *(java R83: a field write
   judged by the preceding bytecode instruction. java R86: a ternary-selected literal captured from
   whichever branch sat adjacent — and that one makes a POSITIVE claim about the wrong destination, which
   is worse than silence.)* Triggers: ternary, if/else, switch, try/catch, loop-carried, `??=`.
2. **A callable target with no body.** Is a named target treated as resolvable without checking it HAS an
   implementation? *(java R84: an abstract method reference accepted as a clean lambda body. rust R89: a
   trait requirement passed as a first-class value, matching no unit and evaporating.)*
3. **Separate implementations of one question that drift.** *(rust R75/R77, then R88 — seven binders were
   hardened for dispatch-typed values and the eighth, the plain unannotated `let`, was not. java R87: two
   root-marker checks, one reading both annotation lists and one reading half.)* Section G is the rule;
   this is how you find where it was broken.
4. **A caller that vanishes when resolution crosses a boundary.** Module, package, crate, classpath,
   re-export, alias, macro. *(swift R79, then R85 one binder shape over.)* **Absence is the sin's
   signature** — an omitted pure function and an omitted effectful one are the same bytes.
5. **A heuristic narrowing a sound over-approximation on an unprovable property.** *(ts R82: a
   `wrap<T>(x: T): T` treated as the identity because the signature said so. The comment said "PROVEN".)*
   `assert-audit.sh` finds the candidates; you still have to read them.
6. **A consumer reading only one shape of a container.** *(ts R82: `.members` but never `.properties`.
   The audit that cleared it asked "does it crash?" instead of "does it still find what it used to?")*
   Enumerate EVERY consumer of an index and diff each against the general path. Print the enumeration.
7. **A key two paths can spell differently.** *(java R80: written `Base#task`, read `Sub#task`. rust: a
   leaf collision that turned reqwest silently pure, invisible to inspection, caught only by the A/B.)*

**Two things that made that pass trustworthy, and both are requirements, not style.** Every finding was
ground-truthed by EXECUTION and measured across **four policy forms** — blanket, `deny Unknown`,
`deny <E> Unknown`, and scoped. They differ, and generalising from one is how a sin gets called a
limitation: several of those six are caught by blanket `deny` only INCIDENTALLY, because the callee is
independently reported, while the caller was never judged at all. And the agents reported what they could
NOT establish — a latent accessor-kind gap nobody could build a compiling exploit for, filed as latent
rather than upgraded to a finding. **An audit that hides its near-misses tells you nothing about the rest
of it.**

## G. Ask the authority — never reimplement it
**Every cardinal sin found on 2026-08-29 traced to code that hand-rolled something already defined
elsewhere.** SwiftPM's manifest selection, cargo's member globs, TOML's grammar, GitHub's push semantics,
a second CHA, a deny-parser `policy.py` already owned. The worst case had TWO hand-rolled paths answering
one question and disagreeing (`Drop` at scope exit vs `drop(x)`).

Every durable fix did the reverse: `swift package dump-package`, the `glob` crate, the `toml` crate,
re-running the engine's own `runScan`. **Where two paths compute the same fact, make them disagree.**

## H. Ask every gate: when a check CANNOT RUN, does that reach the exit code?
Three instruments failed green in one day, and in all three **the detector worked and the aggregator
discarded the detection**. `apply_patch` printed `PATCH-ERROR` into a loop that ignored it — java's weekly
soundness meta-gate went a quarter blind, silently. `gh` failed loudly into a `2>/dev/null`. A checker
extraction failed and produced the same line as a successful catch.

Detection is rarely the failure. **Aggregation is.**

A fourth, 2026-08-30, in the umbrella's own `bin/gate-run.sh` — the tool written that morning *because*
a narrowed gate list had let ten silent under-reports reach main. Its list producer wrote to a
`2>/dev/null` and its exit status was never read, so an unknown repo name produced an **empty list**,
the loop ran zero times, zero failures aggregated to `OK — every gate ran and passed`, exit 0. Separately,
the loop read the gate list on *stdin*, so the first gate that read stdin swallowed every gate below it:
three gates in, `1 gate(s) run, 1 ok`, exit 0. **Ask of any aggregator: what does it print when the thing
it aggregates over is EMPTY?** Zero failures is not zero gates.

## I. Calibrate a NEW instrument by retro-rediscovery
Before trusting a new detector, point it at bugs already found by hand and require it to find them.
`conformance/retro_test.py` rediscovers **15/15** historical bypasses — and that control caught **three
real bugs in the generator** before it passed. An instrument that cannot re-find known defects is not
calibrated, whatever it reports.

## J. Label EXECUTED vs ANALYSIS-ONLY, always, in separate lists
A round reported four checkers "hand-analysed, no passing degenerate found." Executed, **three had real
gaps**, one with zero fixture coverage at all. **"Analysed and found clean" and "attacked and survived"
read identically in a report and mean completely different things.** Never let them share a list.

## K. A claim of correctness suppresses the measurement that would falsify it
Broke FIVE times in one day: *"cannot manufacture a false exemption"* (it could); *"a missed spelling here
is LOUD, not silent"* (it was silent); a gate comment asserting a property the code lacked; a "verified
clean" note that had reasoned from fixtures rather than from the checker; and a commit message claiming a
rewrite it never made.

**Every one read as considered, and that is exactly what stopped it being measured.** When you meet a
comment explaining why something is safe, treat it as the highest-value thing in the file to attack.

### L — run the guard on the OTHER platform

**A guard that only ever executed on the author's OS has never been tested; it has been assumed.**
Measured 2026-08-30, one hour after the test that exposed it was written.

probe.sh read file mtimes as `stat -f %m FILE || stat -c %Y FILE` — the idiomatic BSD-then-GNU
fallback, in a repo whose entire family is developed on macOS and gated on Linux. It is unsound, and
unsound in the direction that hides itself. GNU's `-f` is *filesystem* status, so `%m` is read as a
filesystem to stat: it prints a block/inode dump **for the real file, on stdout**, and only then exits 1
on the bogus argument. So the `||` fires, the GNU form appends a correct epoch, and the capture holds
both. Every downstream comparison died with bash's `integer expected` and the staleness check concluded
the binary was fresh. The scan a few lines below had no fallback at all. (Re-measured under
`ubuntu:latest`: the pre-fix script exits **0** on a binary two years older than its source; the fixed
one exits 3.)

Two properties made it survive: it was **correct on the machine anyone would check it on**, and its
failure mode was a **silent pass**, not an error. Nothing short of executing it elsewhere finds that.

**And the fix's own audit boundary was drawn around its trigger — §9, immediately, in the same file.**
Measured the next morning by grepping the *mechanism* (`stat -f`, `date -r`) rather than re-reading the
file that triggered the audit:
- **`date`, one line lower, inside the same `printf`.** BSD `date -r EPOCH` renders an epoch; GNU `date -r`
  takes a FILE and wants `-d @EPOCH`. So on Linux *both* provenance timestamps rendered empty —
  `built  · newest source  ` — which reads as nothing to report, not as a broken renderer.
- **`bin/candor`'s `doctor` drift check**, an entirely different file, carrying `stat -f '%m'` **and**
  `date -r` with no fallback at all. On Linux the `-gt` errored to stderr and evaluated false, so the
  "installed build is older than your sources" warning **could never fire**. Confirmed by running the
  real dispatcher in Docker, old and new, on one fixture.
- The loud NOTE added *by the fix* for "stat did not yield an integer" sat behind a `|| return 0` that
  returned first — **unreachable by its own stated trigger**. Attack K, on a comment written that hour.

Grepping the mechanism costs one command. Two of these three were in files nobody had thought to look at.

- Ask of any guard: **on which platforms has this branch ever actually run?** CI green is not an
  answer unless a test *drives that branch* — this one had no test at all until the day it broke.
- A fallback chain selected by **exit code** is a trap wherever the failing branch also writes stdout.
  Prefer selecting the form ONCE, by whether it returns the shape you want.
- Docker is enough: `ubuntu:latest`, copy the tree in, run the suite. Environmental failures
  (absent PyYAML, absent siblings, no `gh`) are noise — grep for the assertion you care about by name
  rather than reading the total.

This is the same class as the *teeth only on macOS* row from 2026-08-16. It has now cost twice.

### M — "it drives a real binary" is not a reason a check cannot be attacked

Measured 2026-08-30 on candor-spec, where this misreading cost TWO WAVES of hardening.

The mutation gate's own SCOPE header said the uncovered conformance rows "drive real engine binaries
rather than taking a document directly … a different, larger project". Every part later hardened drives
real binaries. The header was true and irrelevant, which is the dangerous combination.

**A check's verdict does not turn on the expensive thing it invokes. It turns on the comparison
DOWNSTREAM of it** — an `if` chain, a cell checker, an aggregator — and that comparison's entire input
is usually a few exit codes and JSON documents you can supply directly. The engine run is upstream of
the thing you are attacking, so its cost is not your cost.

So when something looks unattackable, separate two questions that get silently merged:
- what does this check RUN? (may be huge, slow, four engines, a full build)
- what does its VERDICT actually read? (nearly always small, and usually argv-shaped)

Only the second one bounds the work. If you cannot answer the second, you have not looked yet.

**The coordinator made the matching error in the same session, one level up.** I told the agent that
three parts all needed "real fixture or stub engineering", having measured that on TWO of them; the
third ran through two already-extractable functions and needed no engine at all. A brief that reports
what it measured can go stale honestly. One that states a conclusion drawn from a sample cannot — and
an agent that believes it will skip exactly the cheap work you sent it to do.
