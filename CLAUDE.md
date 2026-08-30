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

**Why this line exists, measured 2026-08-26/27.** In one session roughly a third of the mechanisms the
coordinator handed agents were wrong or backwards, while the findings themselves were all real. Every one
was caught by an agent told to attack its brief — a "cardinal sin" that was ⟨0.32⟩ working as designed;
a `.d.ts` hypothesis that was inverted; a suggestion to narrow a blocklist that was unsound; a
union-vs-winner-take-all framing that was wrong for that case. None was caught by the coordinator
re-checking its own reasoning. The instruction converts the coordinator's least reliable habit into
someone else's job, which is the only reason it works.

## Two rules that recur

**One owner per repo, and per shared file.** Three agents sharing `candor-spec` cost a silently-dropped
commit and a killed conformance run. An agent that notices a problem in a repo it does not own should
**report it, not fix it** — that is what makes single-ownership workable rather than a way to drop things.

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
