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

## The standing checks

Run them; don't re-derive them. `bin/verify-local.sh`, `bin/verify-umbrella.sh` (tests a throwaway
worktree at the **last commit**, so commit first), `bin/ci-watch.sh`, `bin/release-test.sh`,
`conformance/run.sh` and `conformance/part.sh <id>` in `candor-spec`. Re-deriving `ci-watch.sh`'s logic
instead of reading it reintroduced, into a release gate, the exact bug its own comment warns about.
