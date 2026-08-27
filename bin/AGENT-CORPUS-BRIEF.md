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
