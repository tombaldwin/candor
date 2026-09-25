# Working on candor — instructions for Claude

This file is for an agent working **on** the candor family. `AGENTS.md` is a different document, for
agents **using** candor downstream.

## Dispatching agents

Hand every agent the relevant brief, and tell it to attack the premise:

- **Corpus / bug-hunting work** → `bin/AGENT-CORPUS-BRIEF.md`
- **Release work** → `bin/AGENT-RELEASE-BRIEF.md`

And in the prompt, always:

> **Stop and report if the premise you were given is wrong.** A hypothesis you did not try to break is
> a guess. If your evidence rests on a comparison, state what was held constant.

**TELL EACH AGENT ITS SOUNDNESS ROW ID. THREE OUT OF THREE INVENTED A COLLIDING ONE, 2026-09-02.** I
dispatched three fix agents without naming the row IDs I had already filed (R117–R121). Every one picked
its own number and every one collided with a live row: rust chose **R109** (taken — ts `localStorage`),
swift chose **R99** (taken — rust second-spelling), ts chose **R116** (taken — ts `Object.assign`). That
cost three history rewrites across 52 in-tree references, in repos where a wrong ID silently conflates two
unrelated findings in every future `grep`.

It is not the agents' error — **the next free number is not derivable from anything they were given**, and
an agent that must invent an identifier will. So either name the row (*"file this as R124"*) or tell it to
file no row and let the coordinator do it. `grep -c '^| R' candor-spec/SOUNDNESS.md` is not the answer
either, because the IDs are not dense — **and neither is "read the last row and add one", which this
paragraph said until 2026-09-02: rows get appended out of order, and a reviewer measured the last row as
R131 while R132 was already taken.** The rule is the MAXIMUM:

    grep -oE '^\| R[0-9]+' candor-spec/SOUNDNESS.md | grep -oE '[0-9]+' | sort -n | tail -1

While renumbering, note that `sed -i '' 's/X/Y/g' $files` **silently does nothing in zsh** — an unquoted
variable is not word-split, so the whole newline-joined list arrives as one filename. Use a `while read -r`
loop, and verify with *"every differing line contains the ID"*, not with a diffstat.

**Why this line exists, measured 2026-08-26/27.** In one session roughly a third of the mechanisms the
coordinator handed agents were wrong or backwards, while the findings themselves were all real. Every one
was caught by an agent told to attack its brief — a "cardinal sin" that was ⟨0.32⟩ working as designed;
a `.d.ts` hypothesis that was inverted; a suggestion to narrow a blocklist that was unsound; a
union-vs-winner-take-all framing that was wrong for that case. None was caught by the coordinator
re-checking its own reasoning. The instruction converts the coordinator's least reliable habit into
someone else's job, which is the only reason it works.

## Two rules that recur

**ONE OWNER PER REPO IS NOT ENOUGH: `conformance/run.sh` READS EVERY ENGINE'S WORKING TREE.** Measured
2026-08-31. A candor-swift agent ran the four-way suite while candor-rust had an uncommitted fix in its
tree; the suite therefore measured a candor-rust that was not `main`, and the coordinator measuring
candor-rust at the same moment contaminated it back. **Two agents can own different repos and still
corrupt each other's results**, because the shared instrument reads trees, not commits.

`bin/probe.sh` already detects this and says so — *"a conformance run is IN FLIGHT. It reads engines
from their working trees; measuring now, or editing now, contaminates it in both directions. Wait for
it."* That guard is the reason this was caught rather than believed. So: **before dispatching an agent
that will run four-way conformance, make sure every OTHER engine tree is clean and committed** — and
when one is running, do not measure or edit any engine. A four-way result taken over someone else's
work-in-progress is not a measurement of anything that exists.

**AND THE COORDINATOR IS AN AGENT TOO: EDITING `candor-spec` DURING A CONFORMANCE RUN FAKES A LITTER
VERDICT.** Measured 2026-09-23. With all four engine trees clean I started `conformance/run.sh` and, while
it ran, filed rows into `candor-spec/SOUNDNESS.md`. The suite exited **1** with
*"THIS RUN LEFT FILES IN THE REPO — an engine arm is missing its `--out`"*, naming exactly one entry:
` M SOUNDNESS.md`. No engine arm was missing anything. **The guard snapshots the repo before and after
and attributes every difference to the run**, which is right — it cannot tell my edit from an engine
writing a report into the cwd, and the failure it exists to catch (a scan with no `--out` dirties the
tree and makes `release.sh` step 0 refuse) looks identical.

The rule I had already written for agents — *one owner per repo, and the shared instrument reads TREES,
not commits* — applies to the coordinator unchanged, and I am the one most likely to forget it because I
am "only" editing a register while someone else's suite runs. **While `conformance/run.sh` is in flight,
candor-spec is as read-only as any engine.**

Worth noting what made this cheap: the serial re-run. The temptation was to explain the red away as my own
edit and move on — which was even TRUE — but the file's own rule is *do not explain a FAIL by concurrency
until you have failed to reproduce it serially*. The clean re-run cost sixteen minutes and turned a
plausible story into a verdict: `EXIT=0`, 0 FAIL cells, 0 passing xfails, 0 left files.

**`gate-run.sh` IS A SHARED INSTRUMENT TOO — DO NOT RUN FIVE REPOS' GATE LISTS AT ONCE.** Measured
2026-09-11 during the 0.36.1 cut. I dispatched `gate-run.sh` for five repos concurrently and got three
FAILs: two in candor-java's `smoke.sh` (the declared spec string absent from the envelope; a lambda body effect
not reaching its enclosing fn) and one in the umbrella's `release-test.sh`. **All three were false.** Run
serially and alone, the same trees gave `smoke: 547 passed` and `release-test: OK — 471 assertions`.

The mechanism is the conformance rule above, one level down: the umbrella's gate list BUILDS ENGINES, and
`smoke.sh` starts with `./gradlew installDist` and then executes `build/install/candor-java/bin/candor-java`.
A concurrent build rewriting that launcher mid-run produces scattered, non-reproducible failures — not a
crash, just two assertions out of 547 reading wrong. **A FAIL caused by the harness is indistinguishable
from a real one**, which is why R382 was worth fixing in `ci-watch`; the difference is that here the false
verdict lands mid-ladder, where believing it costs a reverted cut.

Note the near-miss in the OTHER direction: the instinct on seeing 2/547 fail is to disbelieve them and
push. What made this safe was reproducing each failure INDIVIDUALLY first — both passed on the same
commit — before anything was attributed to concurrency. **Do not explain a FAIL by concurrency until you
have failed to reproduce it serially.** "Probably a flake" is a guess; the serial re-run costs four minutes.

**One owner per repo, and per shared file.** Three agents sharing `candor-spec` cost a silently-dropped
commit and a killed conformance run. **AND THE COORDINATOR BROKE THIS AGAIN ON 2026-09-25, IN
THE ONE REPO IT OWNS BY HABIT.** I dispatched a lane that owned `candor-spec` and then, while it was
running, filed rows into `SOUNDNESS.md` myself because a DIFFERENT lane had reported and its findings
needed recording. Nothing was lost — the lane's two commits landed first and my edit applied on top —
**but that was luck, not design: had the lane written `SOUNDNESS.md` after my edit, three filed rows
would have vanished with nothing saying so.**

The failure mode is specific and worth naming, because the existing rule did not feel like it applied:
**filing a row is not "working on candor-spec" in the way editing a script is, so it does not trip the
instinct the rule was written for.** It is the same write to the same file. The register is the most
contended file in the family precisely because every lane's output ends up there.

The rule that actually works, since the coordinator will keep needing to file while a spec lane runs:
**when a lane owns `candor-spec`, the coordinator queues rows and files them at the JOIN**, or tells the
lane its row IDs and lets it file them. Both are cheap. What is not cheap is discovering the loss later,
because a dropped row leaves no trace at all — `check_soundness_tables.py` and `soundness-status.py` are
both perfectly happy with a register that is three rows short.

**AND THE MECHANISM IS `git add -A`, WHICH I THEN PROVED IN THE SAME MINUTE BY DOING IT AGAIN.** Having
just written the paragraph above, I committed that very edit with `git add -A` in the UMBRELLA — where a
lane was mid-flight building the chained-census arm — and swept **1,069 lines of its unfinished work**
into a commit whose message was about `CLAUDE.md`. Nothing was lost again, and again that was luck: the
files were half-written, the message described none of them, and the lane would have committed its own
version on top of a snapshot it never made.

So the rule is not a habit of mind, it is a command: **while any lane owns a repo, never `git add -A` in
it — stage the explicit paths you edited.** `git add CLAUDE.md` could not have done this. The recovery,
if it happens anyway, is `git reset --soft HEAD~1` then `git restore --staged <the lane's paths>`, which
moves the index only and leaves the agent's working tree untouched; do NOT `git checkout` those paths,
which would destroy live work.

Worth noting what caught it: `fast-gates.sh` went red on `shellcheck` over a file I did not know existed.
The gate that found a coordinator's ownership violation was a lint on someone else's half-written script. An agent that notices a problem in a repo it does not own should
**report it, not fix it** — that is what makes single-ownership workable rather than a way to drop things.

**THE SCRATCHPAD IS A SHARED INSTRUMENT TOO, AND RECLAIMING DISK MID-WAVE DESTROYS EVIDENCE.** Measured
2026-09-01: with four agents running, I swept ~6G of build output from the shared scratchpad — including
`node_modules` under corpus clones another agent was *mid-A/B* against. It could then verify only 5 of
113 removals against original source and had to say so. The evidence was not in a repo, so
`feedback-evidence-dirs-are-sacred` and every git-level guard were blind to it.

The disk pressure was real and the sweep was necessary — 16G against 4.8G free is the shape that faked
four agents' results earlier the same day. So the rule is not "never reclaim", it is: **clean BEFORE
dispatching a wave, never during one**, and if you must clean mid-wave, delete only paths you created
this turn. `bash bin/disk-guard.sh` before dispatching is a second's work and is the whole point of
having it.

**AND A RELATIVE SCRATCHPAD PATH PUTS THE LITTER IN A REPO.** Measured 2026-09-22: a read-only sweep
agent was told to *"work only under `scratchpad/sweepagent-r534/`"* and did exactly that — **relative to
its cwd, which was `/Users/tom/git/candor`**. It left **203 MB** of reports and fixtures inside the
umbrella repo and reported, correctly by its own lights, that it had written nothing into any repo. It
had no way to know: the path it was given resolved somewhere it never inspected.

`git status` caught it (`?? scratchpad/`), which is the argument for NOT gitignoring that name — an
ignored directory makes the next 203 MB invisible. **Give every agent the ABSOLUTE scratchpad path**, the
one in the environment block, not a bare prefix. The prefix rule above is about COLLISION between agents;
this is about which tree the prefix hangs off, and the two failures are independent.

Worth pairing with the disk rule: 203 MB is not fatal at 56 GB free, but the same brief at 16 GB against
4.8 GB free is the shape that faked four agents' results in one afternoon.

**TWO AGENTS CHOSE THE SAME SCRATCHPAD DIRECTORY NAME AND ONE ATE THE OTHER'S FIXTURE.** Measured
2026-09-15: a candor-rust agent and a candor-swift agent were both working SOUNDNESS **R349** — different
halves, different repos, correctly partitioned — and both created `scratchpad/r349/`. The swift agent
wrote `Main.swift` + `r.json` over the rust agent's directory and its `src/lib.rs` **vanished
mid-measurement**. Nothing was lost permanently because the rust agent noticed and re-created it, but it
noticed by accident.

**One owner per repo does not partition the scratchpad, and the obvious naming convention — name the
directory after the row — is exactly what guarantees the collision**, because a row worked in two engines
is the normal case, not the exception. The shared-instrument rule already covers `conformance/run.sh`,
`gate-run.sh` and disk sweeps; this is the same class in the one place the file did not name.

**The fix is a prefix, and it belongs in the BRIEF rather than in an agent's judgement:** tell every
dispatched agent to prefix ITS OWN scratch paths with its repo — `rustagent-r349/`, `swiftagent-r349/`.
The rust agent adopted that convention itself after the collision; it should not have had to.

**An agent that must invent a shared name will collide, for the same reason one that must invent a row ID
will** — and the row-ID paragraph above is the proof that naming it in the brief is what works.

**An audit's boundary must be stated and justified, and must not be drawn around its own trigger.** Every
audit in that session except one scoped itself to the instance in hand and missed the next one: a
`::clone` exclusion, then a `walkdir` audit that ruled "unique victim, not a class" while citing `ignore`
as the model — and `ignore` had the same hole one constructor over, with nine more found on a proper
sweep. The exception grepped every call site rather than the ones it was handed, and came back verifiably
clean.

**Write the row before the port.** Do not take a behaviour four-way until its SPEC clause and
conformance PART exist. Measured on ⟨0.34⟩ ITEM 1, 2026-08-28: four engines shipped prose citing
"SPEC §2 ⟨0.34⟩" while `grep -c '0\.34' SPEC.md` returned **0**, nothing pinned the behaviour
cross-engine, and rust and ts had already drifted inside that gap on whitespace-padded input. Closing it
took a clause, a PART, and two follow-up engine fixes — all of which the row would have prevented, and
the drift was found by a review panel, which is the expensive way to find it. This is the family's own
"conformance ROWS beat review panels" rule, and the coordinator is the one who broke it.

**A BACKLOG entry is a snapshot; mark what was MEASURED and what was INFERRED.** Three entries were wrong
on 2026-08-28, all written by me, all reading as findings: one classified a false disclosure as a
cardinal sin; one used a class label ("a key assumed unique that isn't") covering only half the failure
modes, which would have sent the audit past the ABSENCE direction that produced the real defect; one
asserted a hole that a commit six days earlier had closed. An entry that says what it measured can go
stale honestly. One that states a conclusion cannot.

**Do not tell agents to "block, not stall" — tell them to run the long command in the FOREGROUND.**
An agent that stops to report "waiting on the suite" ends its turn and costs a resume. Measured
2026-08-28: the instruction "BLOCK, do not stall — poll in a loop inside one turn" was written into this
file, put verbatim into six briefs, and **failed all six times**, every one an agent in candor-spec
waiting on `conformance/run.sh`. An agent that has already backgrounded a job will stall no matter how
the rule is phrased, because by then stopping is the only move it has.

What works is removing the choice: **"run `bash conformance/run.sh` in the foreground and wait for it —
do not background it."** Name the mechanism, not the intention. This is worth remembering as a general
point about these instructions: a rule the agent must remember to APPLY is weaker than one that removes
the option, and a rule that has failed six times is not a rule, it is a note.

**FAILED A SEVENTH TIME, 2026-08-31, and the phrasing above was not the problem.** The brief said "Run
long commands IN THE FOREGROUND and wait — do not background them"; the agent backgrounded a 256-crate
corpus run anyway and ended its turn. **The reason the naming-the-mechanism fix is incomplete: a
foreground `sleep` is BLOCKED by this harness, so once a job is backgrounded an agent has no in-turn way
to wait for it — stopping really is its only move.** So the instruction must also say what to wait
*with*: **the Monitor tool with an until-loop.** Give agents the waiting mechanism up front, not just
the prohibition, or the prohibition is unenforceable the moment they disobey it once.

**AND THE UNTIL-LOOP HAS ITS OWN TRAP: `pgrep -f <pattern>` MATCHES THE WAITING SHELL ITSELF.** Measured
three times on 2026-09-22 — once by me, twice by one agent, which left two loops that could never exit.

    until ! pgrep -f 'release-preflight.sh 0.39 0.39.1' >/dev/null; do sleep 20; done

The waiting shell's own command line CONTAINS that string, so `pgrep -f` finds itself, the condition is
never false, and the loop spins forever. **It is indistinguishable from a slow job** — the thing you are
waiting for may have finished minutes ago. My own instance sat "waiting" on a preflight that had already
exited; the agent's two were still spinning after its process died.

Wait on something that cannot match the waiter: **a PID** (`until ! kill -0 "$pid" 2>/dev/null; do …`)
or **an end-marker the job itself writes** (`until grep -q '=== done ===' "$log"; do …`). If you must
match on a name, exclude yourself: `pgrep -f pat | grep -v "^$$\$"`. This is the same shape as every
other vacuous guard in this file — a check that cannot fail, here a wait that cannot finish.

**THIRTEEN TIMES on 2026-09-01, and the Monitor fix is ALSO incomplete — stop counting the phrasings.**
Every brief that day carried both halves: the prohibition AND the mechanism, verbatim, with the failure
count in it. Thirteen agents stalled anyway. The clincher was the last one, which **armed a Monitor and
then ended its turn to say it would resume when the build landed** — it had the tool, it had the
instruction, it used the tool, and it stopped regardless. So the model is not "the agent doesn't know how
to wait". It is that **an outstanding long job makes reporting-and-stopping feel like a complete turn**,
and no wording of the rule reaches that.

Two things that actually work, both about the RESUME rather than the brief:

- **Say what the next message must contain, not what the agent must not do:** *"Do not send me another
  progress message. The next thing I should hear from you is findings."* Every agent resumed this way
  came back with findings.
- **Budget for it.** Thirteen resumes is roughly one per dispatched agent. Treat a stall as the expected
  cost of a long job, not an anomaly to be designed out — the work still lands, and the resume is cheap
  compared with re-running a corpus.

Keep the prohibition and the mechanism in briefs: they are free, and they make the resume shorter. Just
do not expect them to hold, and do not spend another day rewording them.

**Before pushing a repo, run ITS gates — from a fixed list, not from whatever the agent's report mentioned.**
Measured 2026-08-29: candor-swift's `main` sat RED for FOUR commits while every push was reported green.
I ran `ci/self-gate.sh` for candor-rust every time and never for candor-swift, because I followed each
agent's verification list instead of a per-repo one. The failing gate — `self-gate` — was the one I never
ran. **And I checked CI once that morning, then pushed ~15 more times across seven repos without looking
again**, having spent the day hardening the very tool that would have told me.

The self-gate failure was itself instructive: a fix EXTRACTED an existing subprocess call into a named
helper (so two paths could share one implementation instead of duplicating a spawn — the right call), and
because a named function binds its own unit, the engine's own boundary gate correctly reported a unit its
declaration had never heard of. **The subprocess surface never grew; the declaration was stale.** candor
caught candor, and nobody read it.

**The per-repo list is now printed, not remembered: `bash bin/gates.sh <repo>`** extracts every `run:`
step from that repo's own CI workflows. It exists because the rule above failed a SECOND time on
2026-08-30 — I verified candor-rust against the gate list in an agent's report (which named
`soundness/run_drop.sh`) instead of the repo's own, and the gate I skipped, `soundness/run.sh 60`, was
the red one: TEN silent under-reports reached `main` and had to be reverted. Both times I ran a
NEIGHBOURING gate with a similar name and read its pass as coverage. I had been running five of them.

**How many are there? Do not answer that from this file — run the tool.** This paragraph said "21"
on 2026-08-30, written from memory the same day I built the tool, in the passage whose entire subject
is not trusting memory; a review panel caught it and the real figure was 39. I then corrected it to
"39" and committed — and it was stale within the same push wave, because a commit in that very wave
changed which workflows `gates.sh` selects and the answer became 34. Twice wrong, in opposite ways,
in one day. **The count is a function of HEAD, so print it:**

    bash bin/gates.sh <repo> | grep -c '^        '

**WHEN AGENTS CANNOT RUN THE GATE LIST, THE COORDINATOR RUNS IT — BEFORE THE PUSH, NOT AFTER.** Measured
2026-09-24 on a three-lane wave (candor-rust, candor-java, candor-swift in parallel). `gate-run.sh` is a
shared instrument that a concurrent build makes lie, so all three agents were correctly told not to run
it. I then ran FOUR-WAY CONFORMANCE before pushing and treated that as the gate. It is not: conformance
is a CROSS-ENGINE DIFFERENTIAL and was never going to see a per-repo lint. candor-rust's CI went red on
`cargo +stable clippy` — `expect_fun_call` on two lines of new test code.

**And the agent's "clippy -D warnings passed" was TRUE.** This repo pins a NIGHTLY toolchain, so a bare
`cargo clippy` runs the nightly's lint set; CI runs `+stable`. The lint fires on stable and not on the
pin. Both forms are in `bin/gates.sh candor-rust`, so the repo's own list would have caught it — which
is the whole point of the list being printed rather than remembered.

So the wave shape is: agents run their OWN repo's suite → agents commit, DO NOT push → coordinator runs
`gate-run.sh` for each changed repo SERIALLY → then conformance → then push. Running the three lists
serially afterwards took minutes and came back 31/31, 10/10, 11/11; doing it before the push would have
cost the same minutes and saved a red `main`. **Parallelism buys lanes and costs the one instrument that
catches per-repo regressions; reinstate it at the join, not after the push.**

**So: `git push` is not the end of a verification, it is the start of one.** Re-check CI after a push wave,
and keep a per-repo gate list so the set you run does not drift with whoever last reported to you.

**A full disk fakes a FAIL and fakes an empty result, and says neither.** Measured 2026-08-30: one
session directory reached 26G, the volume hit zero mid-wave, and four agents were left running suites
whose failures were indistinguishable from findings — while the harness could no longer write a
command's own output file, so commands **died before executing and returned nothing**. Do not make this
a habit to remember; `bin/gate-run.sh` now checks `bin/disk-guard.sh` before the first gate and after
**every** one, and latches. The dangerous case is the MID-RUN crossing, not the start: a run that begins
with room and fills halfway puts rows from both sides of the line in one table and does not say which is
which, so a startup-only check is blind to precisely the case that bites. The disk verdict outranks
`NOT GREEN` deliberately — a FAIL after the crossing is not a finding.

When dispatching a wave, the cost is per-agent and concurrent: rust builds, Docker legs and Gradle
daemons are GB each. `bash bin/disk-guard.sh` before dispatching is a second's work.

## When a disclosure-only change ships without asking

**Tom's ruling, 2026-09-24.** A change that ADDS disclosure (`Unknown`) and removes no effects has come
to him four times with the same shape and a different number. It no longer has to, except in the middle.

    A disclosure-only change — REMOVED 0, and REACH measured — SHIPS WITHOUT ASKING when it costs
    under ~1.5% of analysed units AND names the silence it closes. It is DECLINED WITHOUT ASKING
    above ~2.6%. It comes to Tom when it is in between, when the benefit is unclear, or when the
    INSTRUMENT producing the number is new.

**The bands are read off what he has already decided**, not invented: R452 SHIPPED at 1.44% (11,224
rows newly carrying `Unknown`, of 676,572 analysed units); the ⟨0.39⟩ in-crate hedge was DECLINED at
2.60% (18,034 of 694,497 functions); R190(c) was DECLINED at 7.02%. R452's own row already argued this
way — *"1.44% … against the 4.88–7.02% R190(c) priced and DECLINED — which is the comparison that
makes the case"* — so this writes down a practice rather than starting one.

**THE PERCENTAGE IS NOT THE DECISION, AND THREE DATA POINTS ARE NOT A FORMULA.** Four things were
stated as part of the ruling and are the reason it is not arithmetic:

- **The denominators are not comparable.** 1.44% of rust's 676,572 units and 0.87% of java's 48,116
  functions are 9,742 and 419 functions. A small-denominator engine swings on a handful of rows. Quote
  the ABSOLUTE count beside the percentage, always.
- **The rule prices the COST and ignores the BENEFIT, so the benefit must be stated separately.** 2% to
  close a cardinal sin that ships a false `deny Net` pass is worth more than 0.5% to close a cosmetic
  gap. "Names the silence it closes" is the load-bearing clause, not the number.
- **The user-visible cost is GATE FLIPS, not `Unknown` counts.** The percentage is a proxy. If a change
  flips gates on real code, say how many and on what — that outranks the proxy.
- **A NEW INSTRUMENT ESCALATES REGARDLESS.** Both of this session's own errors were instrument errors:
  a hollow corpus that prints 0/0/0 exactly like a safe change, and a check that was vacuous because a
  heredoc ate a backslash. A threshold creates pressure to measure in whatever way lands under it, and
  this family's instruments have repeatedly been wrong in the flattering direction.

Had this existed this morning, R533 would have asked about ONE engine instead of four: java 0.87%,
swift 0 and ts 0 are all below the lower band; only rust's measured 1.71% is in it.

## The standing checks

Run them; don't re-derive them. `bin/verify-local.sh`, `bin/verify-umbrella.sh` (tests a throwaway
worktree at the **last commit**, so commit first), `bin/ci-watch.sh`, `bin/release-test.sh`,
`bin/corpus.sh`, **`bin/corpus-ab.py`**, **`bin/fast-gates.sh`**, `conformance/run.sh` and `conformance/part.sh <id>` in
`candor-spec`.

**AND THERE IS A CHEAP TIER FOR THE UMBRELLA NOW: `bash bin/fast-gates.sh`.** Thirteen gates, ~50s,
none of which builds an engine, an IDE or an npm tree — the umbrella's answer to what
`candor-spec/scripts/doc-gates.sh` already did for the spec. Measured 2026-09-24: I edited ONE
PARAGRAPH of markdown in `bin/AGENT-CORPUS-BRIEF.md`, ran `bin/gate-run.sh candor` per the fixed-list
rule above, and gate 12 of 18 — `./gradlew verifyPlugin` — spent an hour unpacking SEVEN IntelliJ
distributions and took the volume to **121 MiB free**. A docs edit had put every other measurement on
the box at risk through the disk hazard this file documents two sections down.

The lesson is not "skip the gate list". It is that **a rule with no affordable path gets broken, and
then it is not a rule** — the fixed-list rule was sound and the only way to honour it cheaply did not
exist. `fast-gates.sh` names the five heavier gates it does NOT run, at the top of the file, so the
trade is visible rather than discovered after a push; it is never a substitute for
`bin/gate-run.sh candor` before a release, and it refuses outright if `disk-guard.sh` is unhappy.

**AND THE A/B IS ONE OF THEM NOW — `bin/corpus-ab.py`, never a fresh `ab.py`.** Measured 2026-09-07:
fifteen ad-hoc `ab.py`/`ab.mjs` scripts in one session scratchpad, no shared tool, every one keyed on
bare `fn` because it was copied from the last one. That is R288, and it made every ADDED/REMOVED/CHANGED
figure in `SOUNDNESS.md` a lower bound — on the R270 arms, 263 reported against 293 real changed rows.
The point is not that the key was wrong; it is that **an instrument with fifteen copies has no owner, so
a defect found in one of them is not fixed in the other fourteen.** Put the tool in the brief you hand
the agent, and the numbers in the commit message. Re-deriving `ci-watch.sh`'s logic
instead of reading it reintroduced, into a release gate, the exact bug its own comment warns about.
