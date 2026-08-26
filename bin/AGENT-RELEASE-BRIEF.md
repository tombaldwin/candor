# The release-adjacent agent brief

Paste this to any agent working in the candor family **during or near a release** — staging a version,
fixing something the ladder found, or just committing to a repo that is mid-cut. It exists because the
0.33.0 cut took **three aborted `release.sh` runs**, and every abort was a gate correctly catching a
change made by someone who didn't know that gate's contract. Four rules; each cost real time.

## 1. Any commit to a released repo between staging and the tag MUST carry its CHANGELOG line

`release-stage.sh` renames `## Unreleased` to `## [X.Y.Z] — <date>` at staging time. Work then
continues, and it lands **inside that section** — never under a fresh `## Unreleased`. Add the line to
the **existing** version heading.

Why this is not optional: `release.sh` picks the notes to publish by finding the section for the version
being cut. If you open a new `## Unreleased` above it, the version's own section is exactly what it was
at staging — a bug fix, a review-round change, or your commit's own effect goes completely
undocumented — and an **empty** `## Unreleased` makes the picker fall back to the newest section it can
find, which is **the previous release's notes**, published under the new tag. This has actually shipped.
`release-preflight [5b]` (`changelog-lag.sh`) treats every non-doc commit as source and fails a future
release over the gap; don't be its next finding.

## 2. Report findings immediately. Never poll CI.

If you kicked off a CI run (a push, a re-run, a release step), say so and stop. Do not sleep-loop
checking status and report "still waiting" every few minutes — four agents did exactly that on this cut,
burned round trips, and delivered nothing until someone stopped them. Either wait synchronously for the
result and report it once, or hand off and let the caller poll. "Still running" is not a finding.

## 3. Verify AFTER the last edit, not before

A conformance run (or any suite) before `spec-bump.sh` does not license the version bump that follows.
`spec-bump.sh` **rewrites SPEC.md**, and the MUST ledger and conformance rows are keyed by statement
SHA — a clause's identity changes when its text does. Verifying, then editing, then bumping proves
nothing about the state you actually ship. Edit first, bump, *then* verify the tree you are about to
commit.

## 4. One owner per repo, and per shared file

Two agents committing to the same repo — or worse, the same file (`candor-spec/SPEC.md` is the usual
victim) — race. On this family that has cost a silently-dropped commit and a conformance run killed
mid-flight by a concurrent edit. If your task touches a repo or file another agent might also be
touching, say so before you start and confirm who owns it. Don't assume you're alone.

---

Full context for any of these: `TESTING.md` (family test standards), `bin/release-preflight.sh`'s own
comments (each check documents the defect it exists to catch), and the umbrella `CHANGELOG.md`'s dated
entries for the incident history.
