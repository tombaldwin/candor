# AGENT-FIX-LANE-BRIEF.md: the standing rules for a lane that changes an engine

Hand this to every lane that commits to an engine repo, beside its own short brief. The short brief names the row
IDs, the defect, the reproduction and the constraints. This file holds what is the same for every lane, so the
short brief does not restate it. Pair it with `bin/AGENT-CORPUS-BRIEF.md` (§E1, §F1) for any classifier change.

The rules come from the 2026-11-18 efficiency plan. On 2026-11-17 four lanes took 2 to 4 review rounds each. Most
rounds chased neighbours that were already silent on the release, and every round re-ran hours of verification.
`candor/CLAUDE.md` "How a lane runs" has the reasoning.

**Stop and report if the premise you were given is wrong.** A hypothesis you did not try to break is a guess. If your
evidence rests on a comparison, state what was held constant. Re-verify each row against HEAD before fixing it:
about one in five rows describes the wrong mechanism.

## 1. Scope

- Fix the rows you were given. File no SOUNDNESS rows. Report anything new UNNUMBERED; the coordinator assigns IDs.
- A pre-existing silence you find NEXT TO your fix is a finding for the report, not part of this lane. Say whether it
  is silent on the last release too. If it is, it goes to a design queue. Fix it here only if your brief says so.
- If an attack matrix came with your brief, it is the acceptance test. Every cell is an executed fixture, and every
  cell reads at least as charged as on the last release and on main.
- Name the direction of each change before quoting any number at it:
  - adding `Unknown` is priced by reach against the bands;
  - removing a charge or a disclosure is priced by accounting for every removal;
  - adding a concrete effect is priced by auditing every new charge.
- Hedges go on the site that loses the effect, with a true reason. Never use a module-wide or producer-wide `Unknown`.
- Prefer a resolution to a hedge.

## 2. Verification, in tiers

| Tier | When | What |
| --- | --- | --- |
| Inner | every iteration and every rework round | the attack matrix or fixtures (executed ground truth, pure twins with unique names), unit tests, the gate flip on code that really performs the effect |
| Final | once, on the final commit | the corpus A/B (`bin/corpus-ab.py`) against main AND the last release, partitioned with a seeded C3 shown to fire; the `calls` lists diffed, not only buckets; the release-bar check (slots a–d); the repo's own gates from `bin/gates.sh <repo>`, names matched character by character |

- Do not re-run the final tier in a rework round unless the rework changed what it measures. Say which tier each
  check in your report belongs to.
- Do NOT run `gate-run.sh`, `conformance/run.sh` or any four-way instrument. They read every engine's working tree,
  and the coordinator runs them at the join.
- A published arm comes from `/Users/tom/candor-pub/<ver>/bin`. Run `shasum -c SHA256SUMS` first. Never use
  `~/.candor/bin`. Swift has no published arm there; take the GitHub release asset.

## 3. Kill switches and tools

- Add a kill switch only if the change is non-additive, meaning it can remove a charge or a disclosure. An additive
  change gets none.
- Use the shared tools: `bin/corpus-ab.py`, `bin/corpus-chained-judge.py` (prove a chained join is live),
  `bin/gates.sh`, `bin/disk-guard.sh`, and `bin/build-at.sh` once it exists. Do not write a new comparator. If the
  toolkit lacks one, say so in the report.
- A build used as evidence names its commit, and its binary sha differs from the other arm's.

## 4. Branch, commit, push

- Work in a worktree on `lane/<name>` at the ABSOLUTE scratch path your brief gives. Prefix your scratch dirs with your
  repo (`rustagent-…`, `swiftagent-…`). Never edit the main checkout. Never `git stash` (the stash ref is shared across
  worktrees).
- Commit unsigned (`GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false git commit …`). Add a
  CHANGELOG line under `## Unreleased`. Bump the cache rev if report bytes change: take the max on main at rebase,
  plus 1.
- Push the branch: `git push -u origin lane/<name>`. Lane branches are public (Tom, 2026-11-23). CI gates them in
  candor-rust, candor-swift, candor-ts and candor-java. candor-spec and the umbrella have no lane trigger, so lanes
  there commit and do not push. **Never merge to `main` and never push `main`.**
- Report the full 40-character head sha. You need not wait for CI; the coordinator reads it.
- Repos are public: no field-client names in code, commits, CHANGELOGs or comments. Say "field case".

## 5. Machine

- Run `bash /Users/tom/git/candor/bin/disk-guard.sh` before every build and corpus run. Use ONE target dir under your
  scratch path. Clean only your own build output.
- RAM is 24 GB, shared. Run `corpus-ab.py` with at most `--jobs 2`, and state your budget.
- Build Gradle with `--no-daemon`; never `--stop` a daemon.
- Guard every `rm -rf` with `${VAR:?}`. Quote heredocs. Never use `pgrep -f`; kill by PID.
- Run long commands in the FOREGROUND. If one is backgrounded, wait on it with the Monitor tool, using a PID or an
  end-marker.

## 6. Report

Write the report where your brief says, or in your final message if that Write is refused. It contains:
- the premise check;
- per row: the mechanism found, the change, and whether it is a resolution or a hedge;
- the matrix or fixture table, with the last-release, main and branch columns;
- the final-tier results, each marked with the claim it supports;
- removals accounted for and new charges audited;
- the gates run, with exit codes;
- the unnumbered findings, each marked "introduced by this lane" or "already silent on <release>";
- the head sha.

No progress messages. The next thing the coordinator should hear from you is the report.
