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

## F. Translate the QUESTION across engines — not the defect
The reusable artefact is never the bug, it is the question that found it.
- swift's peek scope-match sin → asked of the other three → **cardinal sin in ALL THREE**, by a simpler mechanism.
- rust's `Drop` lost in a move-captured closure → asked of swift's `deinit` → **same class, four binder shapes silent**.
- java's `--policy` accepted-and-dropped → **rust and ts identical**.

When one engine yields, immediately ask the other three. Their mechanisms differ; the question does not.

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
both. Every downstream comparison died with `integer expression expected` and the staleness check
concluded the binary was fresh. The scan a few lines below had no fallback at all.

Two properties made it survive: it was **correct on the machine anyone would check it on**, and its
failure mode was a **silent pass**, not an error. Nothing short of executing it elsewhere finds that.

- Ask of any guard: **on which platforms has this branch ever actually run?** CI green is not an
  answer unless a test *drives that branch* — this one had no test at all until the day it broke.
- A fallback chain selected by **exit code** is a trap wherever the failing branch also writes stdout.
  Prefer selecting the form ONCE, by whether it returns the shape you want.
- Docker is enough: `ubuntu:latest`, copy the tree in, run the suite. Environmental failures
  (absent PyYAML, absent siblings, no `gh`) are noise — grep for the assertion you care about by name
  rather than reading the total.

This is the same class as the *teeth only on macOS* row from 2026-08-16. It has now cost twice.
