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
either; read the last row and add one, because the IDs are not dense.

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

**One owner per repo, and per shared file.** Three agents sharing `candor-spec` cost a silently-dropped
commit and a killed conformance run. An agent that notices a problem in a repo it does not own should
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

## The standing checks

Run them; don't re-derive them. `bin/verify-local.sh`, `bin/verify-umbrella.sh` (tests a throwaway
worktree at the **last commit**, so commit first), `bin/ci-watch.sh`, `bin/release-test.sh`,
`conformance/run.sh` and `conformance/part.sh <id>` in `candor-spec`. Re-deriving `ci-watch.sh`'s logic
instead of reading it reintroduced, into a release gate, the exact bug its own comment warns about.
