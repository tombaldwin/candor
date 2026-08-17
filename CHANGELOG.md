# Changelog — candor (umbrella)

This is the umbrella repo: the **adoption and integration surface** over the engines — the drop-in CI
workflows (`adopt/`), the IDE and agent-loop clients (`integrations/`: GitHub Action, Claude Code hook,
VS Code and JetBrains LSP clients), the effects-fingerprint (`fingerprint/`), and the family docs
(`BACKLOG.md`, `TESTING.md`, the case studies). It is **not a versioned release artifact** — it pins the
engine versions it targets, so this changelog is **dated**, most recent first. Engine contract history lives
in [candor-spec's changelog](https://github.com/tombaldwin/candor-spec/blob/main/CHANGELOG.md); each engine
keeps its own.

## 2026-08-17 — staging ⟨0.29⟩ / 0.29.0, and the evidence path a test wrote over

- **Post-release corpus rounds against the PUBLISHED artifacts, and one ⟨0.30⟩ candidate filed.** The
  engines were rebuilt from what a user actually gets — `cargo install` from crates.io, `npm install
  candor-ts@0.29.0`, the released jar, the released swift binary — and the standing corpus reproduced the
  local numbers exactly (java 1479/1479, rust 34/34, swift 55/55, ts 2/2). A fresh draw the corpus has
  never seen (reqwest, rusqlite, walkdir, execa, swift-nio, okhttp, commons-io) is clean on the purpose
  oracle: a library must not report zero of the effect it exists to perform. FILED from execa: `deny
  Exec` exits 0 while the ⟨0.29⟩ peek names 17 Exec functions it did not judge, 16 of them the library's
  own implementation — the axios residual, moved by ⟨0.29⟩ from silent to disclosed and still green.

- **`corpus.sh` oracle [3]: an exit code that could not fail, four lines below the fix for the report
  that could not fail.** The block refuses a MISSING REPORT — "an unrun check is not a green one" — and
  then treated ANY nonzero exit as `(discloses)`, so a missing BINARY passed the same check. FOUND by
  running the round against the PUBLISHED 0.29.0 artifacts: that tree had `candor-scan` and not
  `candor-query`, so the verb never executed and `rust exit=127 (discloses)` printed beside three engines
  that had actually answered — and the round said `corpus: OK`. The expectation is now stated positively
  (exit 1 = the gate fires); 0 is the cardinal sin, 127 is an engine that never ran, and anything else is
  reported rather than absorbed. Calibrated: the identical tree that printed OK now reports a finding.
  **The sibling route again — a rule applied where the work happened and not to the line beside it.**

- **`release.sh` step 6 WAITS for npm before it tells you to move the pins.** The pin-bump push is what
  starts the vscode + jetbrains jobs, and those `npm install` the exact `candorTsVersion` they pin —
  while step 2 only pushed the TAG, whose OIDC publish takes minutes. MEASURED TWICE: 0.16.0, and again
  on 0.29.0, where both IDE jobs died at 22:16:42Z on `npm error notarget No matching version found for
  candor-ts@0.29.0` and both went green on a re-run 19 minutes later with nothing changed. The remedy was
  already written down after 0.16 — *let the registries settle first* — but a note only a human can act
  on is a note that gets skipped at the end of a release, so the script waits (10 min, then DIES: the
  next thing it tells you to do is the push that starts those jobs). Skipped on a fixture tree.

- **⟨0.29⟩ / 0.29.0 PUBLISHED, and the cross-repo pins now name it.** `ENGINE_PIN`, `adopt/candor.yml`'s
  `CANDOR_JAVA_VERSION`, `adopt/candor-digest.yml`'s agents pin, and the vscode/jetbrains
  `candorTsVersion`/`candorJavaVersion` all move to 0.29.0 — after the releases existed, never before.
  The java jar URL was RESOLVED before anything pointed at it (HTTP 200, 1141969 bytes, byte-matching the
  release asset): a pin naming a URL is not the URL existing.

- **The VS Code extension version tracks its server pin again (0.16.0 → 0.29.0).** Gate 4 had been red
  since the pin passed 0.16.x; the workflow is path-filtered and last ran on 2026-07-16, so the drift
  surfaced in a single run months later. Bumping it earlier would have pinned a candor-ts not yet on npm
  — the propagation race this file already records — so it moves here, with the pins.

- **`release-stage.sh 0.29.0`** — build versions, rust inter-crate deps, `Cargo.lock`, the gradle
  version, `UMBRELLA_VERSION` → 0.29.0, and each engine's `## Unreleased` renamed to the cut. The spec
  DECLARATIONS moved separately, in their own commit, on their own axis; the cross-repo pins (`adopt/`,
  jbang, `ENGINE_PIN`, the vscode/jetbrains pins) stay at 0.28.2 until the release they name exists.

- **`release-preflight.sh` derives its conformance evidence path from `$ROOT`.** It read a fixed
  `/tmp/rel-conformance.txt`, which `release-test.sh` also writes — as a 36-byte stub, over the path the
  production run reads. A preflight could therefore report a conformance result it had not produced.
  The path is now keyed to the tree it judges, so a fixture run and a real one cannot collide.

## 2026-08-17 — the ⟨0.29⟩ pre-release panel: three oracle holes and a fourth engine nobody asked

- **`bin/corpus.sh` oracle [3] could not fail.** A scan that produced no report printed
  `(no report — skipped)` and returned, so an engine whose scan crashed — a rename, an empty tree, a
  hang — sailed straight through the one oracle built to catch its cardinal sin, and the run stayed
  green. A missing report is a finding now: **an unrun check is not a green one.** The `[ -x "$SW" ]`
  engine-absent skip stays, because "this machine has no swift toolchain" is a different sentence.

- **…and it asked three engines, never java.** The REFERENCE engine was absent from the cross-engine
  body-less-declaration oracle entirely — the sibling-route shape this family keeps finding, where a rule
  is applied where the work happened and not to the arm beside it. Its body-less declaration is an
  interface method, the same shape as the swift protocol already there. It now answers `exit=1
  (discloses)` on the real corpus rather than not being asked.

- **Oracle [2] dropped reports silently.** A report whose `.callgraph.json` sidecar was missing or
  unparseable was skipped with a bare `continue`, so an engine that lost every one of its reports printed
  as though it had been measured. Drops are counted and shown per engine, and an engine with reports and
  zero usable ones is a finding — **unmeasured must not read as passed.**

- **`AS-EFF-011` reaches SARIF.** `integrations/github/candor-sarif` learned the ⟨0.29⟩ `only` violation
  code, so a permission-form violation arrives in a PR as `PermissionScopeExceeded` rather than an
  unmapped rule id.

- **`release-preflight` gained `checkpin` rows for the IDE integrations** (`vscode ts`, `jetbrains ts`,
  `jetbrains jvm`), which had shipped a twelve-rung-old engine with nothing gating it.

- **Corpus round after the panel: 16 projects × 4 engines × 3 oracles, no findings.**

## 2026-08-15 — spec floor 0.28 published, then reviewed and patched to 0.28.1

- **Engine pins moved to 0.28.2** after the patch published. `PIN_ENFORCED_FROM` stays at 0.27.0.

- **0.28.2 — the patch's own patch.** A max-effort review of 0.28.1 found it had reopened the cardinal
  sin it closed, in two shapes: a `declare function` merged with a namespace read PURE (a
  `ts.ModuleDeclaration` has a `.body`), and a caller through a re-declaring intermediate abstract class
  vanished from the report entirely. Both live on npm and crates.io until 0.28.2. **The control guarding
  the second was vacuous** — it passed identically on an engine without the fix. The pattern this file
  recorded yesterday held for a third time: a fix aimed at a defect class is the likeliest place to
  reintroduce it, and its demonstration is where the self-deception lives.

- **`release-preflight` [10] WAITS for in-progress CI instead of failing.** `release.sh` steps 2–3 push
  the release tags, which start candor-ts's OIDC `publish` and candor-swift's `release` — so the very
  next invocation, the one that resumes at step 7, was GUARANTEED to see its own workflows running and
  fail. Waiting rather than ignoring: those runs are the npm publish and the swift release build, and
  cutting the umbrella before they finish points the front door at artifacts that may not exist —
  the same class the ENGINE_PIN guard prevents. Bounded at 20 minutes; `CI_NO_WAIT` for the everyday
  standalone check.

- **[11] reuses a green conformance result when nothing that could change it moved.** A release runs it
  at least twice and ran it SIX times on 0.28.1, at most two over changed inputs — ~330s each.
  The list enumerates what LICENSES a skip (changelogs, pins, docs), and that direction is the safety
  argument: listing what is RELEVANT means forgetting one path skips wrongly and silently, where
  forgetting an irrelevant one merely costs a run you did not need. Note this INVERTS the classifier's
  denylist-over-allowlist rule, because here skipping is the dangerous act. A dirty tree, a missing
  stamp, an uncomputable diff or any unlisted path all force the full run, and a FAILED run deletes the
  stamp so it can never be inherited.


- **Engine pins moved to 0.28.1** after the patch published — `ENGINE_PIN`, `CANDOR_JAVA_VERSION`,
  the candor-agents ref and the jbang `script-ref`. `PIN_ENFORCED_FROM` stays at 0.27.0: it names the
  FIRST release that enforces the §3.4 pin, which is history rather than a current-version field.

- **Floor 0.28 published** — crates ×4, npm with provenance, seven GitHub releases, the Homebrew tap,
  every pinned URL resolving (`release-verify: OK`). Ships the F1 body-less-declaration cardinal-sin
  fix and the ⟨0.28⟩ report-sink arming rung. `bin/candor`'s `ENGINE_PIN` moves with it;
  `PIN_ENFORCED_FROM` does NOT — that names the first release to enforce the §3.4 pin, which is history.

- **Then a review of that work found 19 findings, and 0.28.1 patches them.** The durable one is not any
  single defect: THREE of them were a defect of exactly the class the fix that introduced them was
  targeting — an over-charge guard that over-charged, a liveness check that could not fire in the
  failure mode it was written for, a self-gate built against file-level exclusion that exempted 1.8k
  lines. Each shipped with a passing demonstration that used the easiest shape rather than the weakest
  one. **A fix aimed at a defect class is the most likely place to reintroduce it.**

- **`release-stage.sh` now refreshes `Cargo.lock`.** It bumped the crate manifests and left the lock,
  which records the same member versions — so the first cargo invocation afterwards rewrote it, and if
  that landed after the staging commit (running the suites, or preflight's own conformance build),
  `release.sh` step 0 refused with "candor-rust has uncommitted changes" on a diff the operator had
  already reviewed. `--workspace` moves only the member versions, never dependency resolution, so it
  cannot smuggle a third-party upgrade into a release.

- **And `bin/release-test.sh` caught the fix to `release-stage.sh`.** Teaching the stager to bump
  candor-java's README `## Status` line broke the fixture run — the fixture had no such file, and `bump`
  treats an absent file as a MOVED SITE and refuses, deliberately, so the stage aborted and every later
  assertion failed with it. The fixture now carries the file and asserts the new site, which is the
  difference between a staged site being tested and merely being present. That harness exists because
  nine defects across 0.25 and 0.26 were found by publishing rather than by testing; this is the first
  time it caught one before a release rather than after.

- **`bin/release.sh`'s manual step 6 earned itself.** Step 7 refused to cut the umbrella while
  `ENGINE_PIN` still read 0.27.0 — proceeding would have shipped a 0.28.0 front door that fetches
  0.27.0 engines, with brew hashing that tarball. The script's own warning about the pin commit was
  exact too: `bin/candor`, `adopt/*.yml` and `jbang-catalog.json` count as SOURCE to changelog-lag, so
  a pins-only commit dies at the gate with the engines already published.

## 2026-08-14 — the environment reproduced, the corpus round made re-runnable, and every engine gating itself

- **Engine pins moved to 0.28.0** — `bin/candor`'s `ENGINE_PIN` (the line `candor update` fetches),
  `adopt/candor.yml`'s `CANDOR_JAVA_VERSION` and `adopt/candor-digest.yml`'s candor-agents ref. These
  name PUBLISHED artifacts, so they move after the release exists rather than with the version bump —
  0.24 shipped a jbang pin to a release that did not exist. `PIN_ENFORCED_FROM` deliberately stays at
  0.27.0: it names the FIRST engine release that enforces the §3.4 pin, which is history, not a
  current-version field.

Tooling and hygiene either side of the ⟨0.28⟩ floor publish.

- **`bin/corpus.sh`** — the 2026-08-13 corpus round, as something that re-runs. 15 tag-pinned real
  projects across four engines with oracles that need no ground truth. It exists because that round found
  two cardinal sins nothing else could: neither was reachable from a hand-written fixture, because neither
  was a case anyone had thought to write. Run it before a release.
- **`bin/probe.sh`** — an ad-hoc measurement gets the same treatment as a conformance row, after five
  measurement artifacts in one session versus zero falsified-row errors. Staleness keys on the newest
  SOURCE rather than the HEAD commit.
- **`bin/bootstrap-dev.sh`** — reproduce this environment on a fresh Mac. The script was wrong four times
  on first contact, each time because it checked the state the author HAD rather than the state a fresh
  box has; `dylint-link` is required by every cargo build in candor-rust and was missing from it.
- **…and the liveness guard added for that was ITSELF vacuous — the same defect, one layer up.** It
  asked whether the old version still appeared in candor-spec's CHANGELOG, which stays TRUE when the
  loop dies, so it never fired in the failure mode it was written for; it targeted a file the scan's own
  filter EXCLUDES, so it exercised a path the scan cannot take; and it goes FALSE when bumping a floor
  whose predecessor was never released, failing a clean tree. The scan is now one function and the probe
  calls THAT function on a fixture line that is definitionally a match — the real pipeline, on an input
  whose answer is known. Falsified: with the original `⟨$OLD⟩` bug reintroduced, the old guard stays
  silent and the new one fires. It also no longer reports through `bad`, which counted a broken scan as
  a missed declaration and told the reader the family was SPLIT.
- **`bin/spec-bump.sh`: the remaining-mentions scan reported success over a scan that never ran.**
  `⟨$OLD⟩` unbraced made bash read the multi-byte `⟩` as part of the variable name, so under `set -u`
  every iteration died and step 3 printed a green "no remaining mentions" — hiding the 40-line triage list
  the 0.28 bump needed. Braced, and the step now asserts its own liveness: a scan that finds nothing at
  all fails as broken rather than passing as clean. It also now warns that a floor bump rewords SPEC.md's
  Contents version line, so the MUST ledger will report it unclassified until re-anchored.
- **Every engine's AGENTS.md now points at the umbrella** (all five, with each repo's embedded-copy drift
  gate re-synced in the same commit). An agent landing in one engine repo learned that engine and stopped;
  a polyglot repo scanned with one engine gets a confident answer about one language and nothing that
  says so.
- **The self-gate exclusion vein, swept four-way.** candor-ts had no self-gate at all; candor-swift and
  candor-java had one that carved out the subprocess surface a whole FILE or PACKAGE at a time, leaving
  regions where a new `Process()`/`exec` was caught by nothing. All three now declare the exempt UNITS and
  scan everything else — measured strictly stronger: an unexplained `Process()` added to candor-swift's
  `main.swift` reddens the new gate and passes both halves of the old one. candor-rust needed no change.
  The policy STRING got weaker (`deny Net Db`) while the gate got stronger, which is the point: a policy
  is only as strong as the scope it is actually evaluated over.
- **`bin/corpus.sh` and `bin/probe.sh` were failing the umbrella's own shell-lint**, and had been since
  they landed — nothing surfaced it until release-preflight's CI check ran with an authenticated `gh`.
  Two `ls | grep` pipelines (which turn a non-matching glob into a silent error) replaced with a glob
  loop, and two declared-but-unused locals removed, one of them a positional placeholder callers were
  passing purely to be shifted away.
- **`bin/probe-causes.sh` placeholder verdicts drop their `spec` key** — like the wrapper's, they assert
  REPLACEMENT, so the version was a literal needing a bump every floor.
- **The test-fixture leak is closed** — `$TMPDIR` held 50,494 `candor-*` directories, 96% of them from one
  candor-ts helper that minted a tree per fixture and removed none. Swept, and both candor-ts and
  candor-swift now clean up after themselves (keeping trees when a run FAILED, since that is when their
  paths are printed and wanted). A full suite run now adds zero.

## 2026-08-10 (later) — the release panel, and what it found in the same day's work

A go/no-go panel over the unpublished ⟨0.28⟩ work. Verdict was NO-GO, and the pattern in the findings was
one habit rather than eight mistakes: **the rule was applied where the work was, and never to its sibling
route.** Six behavioural defects, three of them introduced that morning by the very commits that closed
the original ones.

- **⟨0.28⟩ was half-shipped** — the scan CLI in five engines, the `gate --report` verb in none. A gate that
  FIRED left the operator's first named sink publishing a previous run's green. Two lenses found it
  independently, and conformance row (b19) — written that morning — exists because "a route is not covered
  by its sibling".
- **`candor-agents observe` had no sink layer at all**, and three regressions: a duplicate sink naming
  `.candor/config` destroyed it, `candor-query gate` overwrote a `CANDOR_CONFIG` file, and agents put two
  JSON documents on a stream that had carried one.
- **The §3.3.1 input exemption covered the run rather than the path**, so refusing one sink left the others
  publishing whatever they held.
- **`part.sh --check` printed an all-clear having checked nothing** when invoked as `bash part.sh --check`
  — `$0` was a bare name, the id list came back empty, and it reported success at exit 0. In the file
  whose whole purpose is preventing exactly that.
- **PART 36 dropped candor-ts and candor-swift silently** when either was absent, while the agents arm
  printed a note — so every row written that day inherited a green covering fewer engines than it claimed.
- **Two published claims rested on contaminated measurements.** "One engine refused" (in the SPEC's own
  rationale) came from handing that engine a second POSITIONAL and recording its extra-argument refusal as
  a duplicate-sink one; a cited byte count belonged to a different cause. Both corrected against re-runs,
  not deleted.

Everything above is fixed, pinned, and each new row demonstrated failing against the engine with its rule
disabled. The probe's own pair count was 4x (incremented inside the engine loop) and is now counted once.

## 2026-08-10 — the exit-2 cause matrix grows a generator, and it finds a cardinal sin

- **`bin/probe-causes.sh` now GENERATES the argv instead of only listing causes** (`CANDOR_SWEEP=1`): every
  ordered pair from a small token alphabet, against each engine, on both sink forms, on BOTH the scan and
  `gate` verb routes — 888 cells, and it found a cause the twelve-entry hand list did not hold. An extra
  positional was a GREEN GATE in candor-scan (the last positional silently won, so it scanned the other
  tree) and an empty stream in candor-swift. Both fixed; conformance PART 36 (b18).

  Two construction errors are recorded in the file because the first run's findings were all artifacts:
  `--gate-json` was in the alphabet while the cells append their own sink (you cannot arm a sink whose
  specification is the broken part), and the sink was appended AFTER the argv under test, so a
  value-taking flag swallowed it. The real defect only appeared once both were removed.

  And the number that makes "ok across every pair" mean something: cells that actually REACH exit 2 are
  counted separately (799 of 888), and a sweep where that count is zero fails as VACUOUS.
- **The `gate` VERB route gets cells at all.** It had been named as NOT COVERED for a release; naming a gap
  is not measuring it, and it held a defect — an unreadable config left the stream empty in candor-scan and
  candor-ts while java and swift wrote the refusal. The route needs its own EFFECTFUL fixtures (a gate over
  a clean report exits 0, so every cell would be "not exit 2 here" — a probe that never asks its question)
  and a CONTROL asserting the gate fires, which is what caught java sitting unmeasured because it writes a
  report only with `--json <file>`.
- **The engine-pin cell is INVERTED, and that is the point.** Asserting exit 2 for a pin on the gate route
  made all three measured engines look defective; SPEC §3.4 "Scope" had already excluded `gate --report` by
  name. The cell now asserts what the spec requires — the pin must NOT change an evaluator's answer.
- **`just props`, `just conformance-part`, `just conformance-parts-check`** wired in, and `just check` now
  runs the policy-parser properties. The `conformance-part` recipe had been written against an env var
  `run.sh` never read — it would have run the whole 476s suite and looked like it had filtered.

## 2026-08-07 — the 0.27 rungs land four-way, and two 0.28 rungs are recorded (released 2026-08-09 as 0.27.0)

- **Tooling the 0.27 release proved was missing.** `bin/probe-causes.sh` runs the exit-2 cause matrix —
  every cause a user can TRIGGER (12), against every engine, on BOTH sink forms (68 cells) — because
  counting exit SITES is the wrong measure (25 in one engine, 30 in another) and because the two sink
  forms are different properties: one engine streamed a refusal correctly while leaving a previous run's
  `{"ok": true}` on disk. A `justfile` fronts build/test/conformance/probe/lint, starting with the rust
  build, which is `-p candor-scan -p candor-query` and NOT a root `cargo build` — that mistake aged a
  release binary eight days and produced a review finding for a defect that did not exist. And
  `shell-lint.yml` runs ShellCheck over `bin/`, which found three `cd` calls in the PUBLISHING script
  with no `|| exit` — a failed `cd` there runs `cargo publish` from the wrong repository.

- **ENGINE_PIN and the `adopt/` pins move to 0.27.0.** They name published artifacts, so they move
  AFTER the release exists — `release.sh` step 7 refuses until they do, because the umbrella tarball
  carries the pin and Homebrew hashes it: cutting the front door early ships a 0.27.0 installer that
  fetches 0.26.0 engines.

- **`release.sh`'s step-7 remedy no longer garbles itself, and the harness now renders it.** The text
  telling an operator that a pins-only commit dies at changelog-lag put filenames in backticks inside a
  double-quoted string — live command substitution, so it printed "CHANGELOG. ,  and
  jbang-catalog.json all count as SOURCE", losing exactly the three names it exists to give. `bash -n`
  cannot see this: it is valid syntax. This die fires on every release's FIRST pass by design, so it is
  the one message an operator is guaranteed to read. `release-test.sh` now RENDERS the block and asserts
  all three names survive — 59 assertions, and the assertion was checked against an unescaped copy to
  confirm it discriminates.

- **The release machinery could not clear the state it produces, and then broke on its own fix.**
  `_stage_changelogs.py` SKIPPED any repo already carrying a `## [0.27.0]` heading — which is every
  engine, since writing the heading early and letting new work land under a fresh `## Unreleased` above
  it is how this project works. Preflight [9] stayed red on the stranded sections and `release.sh` gates
  on preflight, so the only route left was hand-editing six changelogs, which is what lost three steps on
  0.24. It now FOLDS, and candor-spec is in the loop at last (it was checked by preflight and skipped by
  staging — the repo the rung is AUTHORED in was the one repo staging could not stage).
  - **…and the wrapper died on the new verb.** `release-stage.sh`'s `case` knew `OK`/`SAME` only, so the
    first `FOLD` line hit its `die` arm and the canonical staging run exited RED over edits already
    correctly on disk. The 55-assertion harness could not see it because the fold rows drove the helper
    directly and never the wrapper — a test that bypasses the integration point tests the wrong thing.
    There is now a row that drives the wrapper, on its own copy of the fixture.
  - **The release notes would have read `## Unreleased`.** After a fold, candor-spec's top section is the
    fresh empty heading, and the notes extractor's position fallback picked it up — passing the empty-file
    and whitespace-only guards with one line of camouflage. It now tries the floor-shaped heading first
    and skips an empty Unreleased in the fallback.
  - **The umbrella's SECOND `(unreleased)` heading stayed unreleased.** THREE are live at HEAD (this entry was written when it was two, which is
    itself the reason the count belongs in the code and not in prose — the marking handles all of them);
    one was marked per
    run, so the older section shipped mislabelled inside the tag and a re-run mutated the file although
    the contract says re-running is a no-op. All of them are marked now.
- **…and the harness row added to catch that was green locally for a reason CI does not have.** Every
  commit in `release-test.sh` passes `-c user.email=… -c user.name=…` because a CI runner has NO git
  identity and a bare `git commit` fails there; the two new ones omitted it under a `2>/dev/null`. On the
  runner they failed silently, the copied fixture stayed dirty, `release-stage.sh` correctly refused it,
  and the row blamed the wrapper for its own setup. Green locally / red in CI, reintroduced inside the
  test written to catch an integration gap. The setup is now checked rather than assumed, and the fix was
  verified by reproducing the runner (`HOME=/tmp/nohome GIT_CONFIG_GLOBAL=/dev/null`).
- **A heading claimed a release that does not exist.** `## 2026-08-05 … (released 2026-08-05 as 0.27.0)`
  was written by an aborted staging run on the 5th; no 0.27.0 artifact exists anywhere (npm, crates.io
  and every GitHub release still top out at 0.26.0 — resolved, not assumed). It would have shipped inside
  the v0.27.0 tag with a wrong date, and the `re.sub` that marks headings matches `(unreleased)` only, so
  re-staging could never have corrected it. Back to `(unreleased)`, which is both true and re-stageable.
  The root cause is that staging writes "released" at STAGING time, before anything is published —
  recorded rather than fixed, because moving it would mean a second pass after the publish.
- **The empty-Unreleased skip in the notes extractor knew one spelling.** `## [Unreleased]` — the
  bracketed form this family also writes — slipped past it and published as a one-line release body.
  Unreachable for 0.27.0 (only the umbrella reaches that fallback and it has no Unreleased heading), but
  a one-spelling guard is exactly how the defect it fixes got in.
- **The umbrella release was cut before `ENGINE_PIN` moved.** Steps 3–4 released and tagged the umbrella
  while the pin still named the previous line, and `update-candor.sh` hashes that tag's tarball — so brew
  would ship a 0.27.0 front door whose `candor update` fetches 0.26 engines, invisible until a new
  install runs `candor doctor` and reports spec drift against itself. The v0.26.0 tag sits on the pin-bump
  commit, which says the operator hit this and worked around it by hand. The umbrella now goes LAST,
  behind a guard that refuses unless the pin already names the version being cut — a check, not a comment.

`bin/release-test.sh`: 49 → 57 assertions. Every new group was run against a reverted copy first and
fails there. All of the above was found by a go/no-go review panel, not by the machinery's own tests.

- **Four stray scan artifacts removed from the repo root.** `report.agents.Fleet.*` and
  `report.t-agents.Fleet.*` are output from scans whose working directory happened to be this repo; two
  went in via `git add -A` and two more were already tracked from an earlier review commit. Nothing
  references any of them, and they would have ridden the v0.27.0 tarball the brew formula hashes.

- **`.candor/run` was a SIXTH pin parser, and it had the old grammar** — while its own header says
  "READING THE CONFIG MUST AGREE WITH THE ENGINE THAT READS THE SAME FILE". A junked line qualified for
  another implementation refused the run (reintroducing at the front door the family-wide outage the
  engines had just closed), and conflicting duplicate lines were silently last-wins where every engine
  treats them as malformed. Both aligned. While fixing it, an apostrophe in one of the new awk COMMENTS
  terminated the single-quoted shell string and broke the script at parse time — caught by running it,
  and the edit now asserts the block stays quote-clean.
- **`candor init` in a POLYGLOT repo wrote an unqualified pin** while the comment beside it promised "one
  qualified line per engine, written below" — code that did not exist. It now writes one qualified line
  per detected engine, each naming the version of the engine that actually scanned.
- **`docs/privacy-manifest-quickstart.md`** — turnkey instructions for the Swift privacy manifest,
  written and then FOLLOWED against three shipping open-source apps.

- **`release-verify.sh` verified the release and not the front door.** It derived the `candor update`
  URLs from the version under test, which asks "does v0.27.0 have assets?" — not the question a
  consumer's machine asks, since `candor update` and `candor init` fetch whatever `ENGINE_PIN` says. A
  release that forgot to move the pin therefore published a working version while every install kept
  pulling the old engine, and the verifier passed it. That is the literal 0.18-engines-under-a-0.23-
  umbrella failure. It now READS `ENGINE_PIN` and both `adopt/` pins and fails on a mismatch — proven by
  running it against the current pre-publish tree, where all three are correctly red.
- **Preflight [7] compared a version string and never asked whether the jar exists.** `release.sh` needs
  the file at step 3 — *after* crates.io (unyankable) and the npm tag — so a never-built jar kills a
  publish part-way with artifacts already out. It now asserts the file, proven by moving the jar aside
  and watching the check go red.

- **A four-lens adversarial panel reviewed the whole wave; three of four said DO-NOT-SHIP, and were
  right.** The regression lens said SHIP and is the evidence that matters: before/after binaries built
  in throwaway worktrees, compared on REAL repositories, gave byte-identical reports, verdicts, exit
  codes and stderr across five engines for anyone who has not adopted the new key.
- **Five of the twelve `adopt/candor-run` assertions could not fail** — the conformance PART 13b defect
  class, in glue that ships into consumer repos, written hours after that lesson. The baseline row ran
  `sed` over a config the test itself had written and never invoked the runner; two pin rows asserted
  only a nonzero exit, which cannot tell "read the pin" from "failed to read it"; and two rows used an
  unobtainable pin, so engine resolution exited before the code under test ran. Rewritten around a stub
  engine so all sixteen rows are reachable, and verified by mutation.
- **The Swift adoption path was dead on arrival.** candor-swift's latest release carries no assets, so
  `.candor/run` 404'd with no version that would fix it while `init` called it "the gate as one
  command". The runner now falls back to an installed candor-swift — safe only because the engine
  enforces the pin itself, which is the guarantee the Rust arm lacked before today.
- **`candor init` pinned the wrong engine.** It wrote the umbrella's `ENGINE_PIN` while the baseline
  beside it came from whatever engine was installed — different whenever a developer is ahead of the
  umbrella, which is the normal state between releases. Since engines now enforce the pin, init was
  generating a repo whose first `.candor/run` refuses. It now pins the engine that actually scanned.
- Smaller, all from the same pass: `blast` survived in two README prose lines after only the code fence
  was fixed; the subdir sweep compared a logical `pwd` against a physical one, so under `/tmp` every
  project reported ITSELF as an ungated sibling; a missing `.candor/config` died inside `awk` under
  `set -e` before its own remedy could print; the Bitbucket step had no `cd` for a monorepo; the GitHub
  workflow cached cargo but not the directory the engine installs into.

- **`adopt/candor.yml` now says which pin is which.** It keeps `CANDOR_JAVA_VERSION` (it chooses the jar
  to download) but records that `.candor/config`'s `engine` key is the one every engine ENFORCES, and
  that the YAML variable is checked by nothing. A family shipping two competing pin mechanisms without
  saying so is how the decoupling the §3.4 rung exists to end comes straight back; filed in the backlog
  to consolidate onto `.candor/run`, since an annotation is not a fix.
- **Four stale backlog entries corrected**, each of which would have sent an implementer the wrong way:
  the zero-match P1 is SHIPPED (and java did not differ, which the entry assumed untested); the
  read/write-direction rung must follow ⟨0.27⟩ `fs` — kinds TRAVEL and an undetermined contributor
  SUPPRESSES the field — not the direct-only shape it originally prescribed; the optional-vocabulary
  design question now has its stated prerequisite in `resolves`; and the `execute`-kind entry claimed an
  in-family precedent in rust that was half false (the field was hardcoded empty, never populated).

- **BACKLOG P1: the stale-document rule binds the REPORT, not just the verdict.** A scan that exits 2
  leaves the previous `report.json` byte-identical, and a downstream `gate --report` then goes green over
  a report the failed run never produced. SPEC §3.3.1 ⟨0.24⟩ already says this and no engine implements
  it — the ⟨0.27⟩ arming work closed the hole for the verdict and left the report channel open, one step
  upstream of the gate it had just made fail-closed.
- **BACKLOG P1: a zero-rule policy reads as a clean gate in the machine channel.** `--policy <a README>`
  writes `{"ok": true, "violations": []}` and exits 0 in all four engines — byte-identical to a gate that
  ran and found nothing. The human channel warns per line; the artifact a CI wrapper reads says nothing.
  PART 32's "a rule that binds nothing is disclosed" ruling, one level up.

- **BACKLOG: `PHPickerViewController` probably needs no photo-library key, and candor says it does** —
  a probable false "missing key" on a real project, recorded rather than fixed because Apple's key page
  names no symbols at all, so the evidence that settled the `CMMotionManager` over-report does not
  transfer.
- **BACKLOG: the ⟨0.24⟩ byte-equality MUST fails on a multi-crate workspace.** 41 of 43 real projects
  produce a `gate --report` verdict byte-equal to the scan's; the two that do not are both cargo
  workspaces where two crates share a function name, and the verdict's `fn` carries no crate qualifier,
  so the report route collapses two violating sites into one. Every conformance gate fixture is a single
  package, so the collision cannot arise there.
- **BACKLOG: a configured dep that cannot be read gets two different answers.** java and swift exit 2;
  rust and ts continue at exit 0 — rust qualifying the omission with a coverage disclosure, ts with only
  a "skipped" note. Both postures are coherent; one config with two meanings is not. Found by the new
  generative config differential on its first clean run, in a cell no hand-written conformance row
  covers.

Both format rungs are recorded rather than built: each needs a wire-format field, so each wants a version and a
conformance part rather than four independent additions — and ⟨0.26⟩ already measured that a PARTIAL
artifact can answer worse than an absent one.

- **docs: the privacy-manifest quickstart now says how to pick the right `Info.plist`.** Following the
  page's own instructions on a multi-target repo picked a ShareExtension's plist and printed four
  "missing key" findings that were pure artefact — a reader could reach that state and conclude the tool
  is wrong.

## 2026-08-05 — the umbrella becomes usable from nothing (released 2026-08-09 as 0.27.0)

- **`candor init` now emits the consumer glue, not just the policy** — the three things every adopter
  was hand-rolling per repo. Driven by a real adoption (uflexi), whose hand-written versions of all
  three are what these were written against.
  - **`.candor/run` — the gate as one command, committed with the code**, and the generated CI step
    now CALLS it instead of restating the gate. CI ran one command and a developer ran another, so
    "it passes locally" and "it passes in CI" were two different claims. It also means the engine
    version appears in exactly one place: `.candor/config`'s new `engine` pin (spec §3.4), which the
    runner reads to decide what to fetch. It used to be restated in CI YAML, decoupled from the
    baseline it is married to, with nothing making the two move together.
  - **`.candor/bitbucket-step.yml`** — a paste-ready Pipelines step, deliberately NOT wired in.
    `bitbucket-pipelines.yml` holds every pipeline a repo has, and generating over it would destroy the
    build; the repo that already has one is exactly the repo that cannot afford that. (GitHub Actions
    gets a whole file because its workflows are one-per-file.)
  - **`.candor/README.md`** — what is committed and why, plus an *"use it to investigate, not just to
    gate"* section: `show`/`where`/`callers`/`impact`/`diff` with the moments to reach for them (before
    editing a function, after a refactor, when auditing an effect). It LINKS the concepts rather than
    restating them — a copy in every consumer repo is a copy that goes stale silently. Written to
    `.candor/`, never over the repo's own AGENTS.md or README.md: those belong to the consumer.
- **`candor init` writes the `engine` pin** into `.candor/config`, so the version a repo intends is
  declared in one place. Every engine refuses a mismatched pin (exit 2), pinned by conformance PART 33. Engines already refused a
  baseline whose §2.1 build id differed from the running one — but a build hash is not something a
  consumer can *declare*, and that refusal lives inside the baseline comparison, so a policy-only gate
  had no coupling check at all. A declared pin also tells `.candor/run` and the CI step which engine to
  fetch, which is what collapses the version to one place.
- **Fixed: `init` misread a standalone repo as a monorepo subdirectory under any symlinked path.**
  `git rev-parse --show-toplevel` always answers with the PHYSICAL path while a bare `pwd` answers with
  the logical one, so on macOS (`/tmp` → `/private/tmp`) they never matched. The prefix strip then failed
  too, producing a workflow named `candor--tmp-initdemo.yml` carrying `working-directory: /tmp/initdemo`
  — an absolute path that cannot resolve on a CI runner. Found by running `candor init` in `/tmp`.

- **Adversarial review of the above found six defects in the generated runner, four of them able to
  change or suppress a CI verdict.** Recorded because the shapes recur:
  - **A failing `curl` killed the gate.** `set -euo pipefail` plus `latest=$(curl … | sed …)` meant that
    offline, a DNS timeout, or a rate-limited 403 failed the assignment and `set -e` ended the script
    **before the engine ran** — exit **6**, silently, from the one function whose comment promised it
    could not affect the verdict. Every substitution there now ends in `|| true`.
  - **A failed build exited 1, the POLICY-VIOLATION code**, while the gate had never run. It is 2.
  - **The pin reader disagreed with the engine reading the same file.** `$NF` of the first `engine` line
    took the last token of an inline comment (`engine v0.26.0 # was v0.25.0` fetched **0.25.0**), ignored
    the `<impl>` qualifier, and took the FIRST line where candor-java takes the last. Each silently runs
    the wrong engine. It now strips comments, resolves the qualifier, and refuses what it cannot read.
  - **The Rust arm never enforced the pin at all** — `command -v candor-scan` short-circuited, so any
    version on PATH ran and `$VER` was never consulted. It now checks the version and installs the pinned
    engine into a versioned root rather than over the developer's own binary.
  - **`--regen` could again write a file nothing reads**: the prefix was guessed as `<dir>/baseline`,
    so any renamed baseline got a *different* file written, left the real one stale, and exited 0 while
    printing "unchanged" and "regenerated" together. It now scans to a temp prefix and copies to exactly
    the path the config names, and an unchanged baseline is exit 2 rather than a note.
  - **Engine resolution ran before argument validation**, so refusing a mistyped verb first downloaded an
    engine — and if the pinned one could not be fetched, the refusal never printed.
- **`changelog-lag` greened over an ordinary merge.** Recency was judged by committer DATE, and a feature
  branch's commits land on main *after* the changelog moved while carrying *older* dates — so merged work
  described nowhere read as covered. It now asks the question dates cannot: is there a source commit that
  is not an ancestor of the changelog's last touch? Also: its repo list is an allowlist in a script whose
  header argues against allowlists, so preflight [8] now fails if it drifts from the list the release cuts.
- **`bin/changelog-lag.sh`, wired into preflight as check [5b]: no CHANGELOG may lag its own source.**
  [5] asks whether the file describing this release *mentions* this release — a necessary condition that
  a section cut at staging time passes forever after. `release-stage.sh` renames `## Unreleased` to
  `## [X.Y.Z] — <date>` when the release is cut, work then continues and lands inside it, and the
  narrative stays describing the tree as it stood that morning. The 0.27 sections said "resolves + fs
  kinds" while the release had grown thirty privacy keys, `--target`, `--xml`, a new §2 field and three
  rounds of review fixes; [5] was green throughout. [5b] asks the missing question — did the description
  stop moving while the thing it describes kept going? — and names the commits, so triage is a read.
  It found 33 undocumented commits across seven repos on its first run, which are now written up.
  **Two of its own designs were wrong and both are recorded in the script.** Requiring every source
  commit to touch CHANGELOG.md flagged work that *had* been documented one commit later, and a rule that
  cries wolf is a rule nobody reads. Then listing the directories that hold source went green on seven
  repos while silently skipping two of them — candor-ts ships `.mjs` at the repository root, candor-agents
  ships a python package, and neither name was on the list, so both printed nothing rather than a pass or
  a fail. That is this project's own cardinal sin wearing a shell script, so the set is now a denylist:
  it names what does not ship, and a repo that cannot be measured FAILS rather than vanishing.
- **`gate`, `gains` and `diff` are EXCLUDED from the auto-scan below**, and the exclusion is the point
  rather than an exception to it. `gate --help` says it applies a policy to an *existing* report, and its
  exit 2 means unevaluable — so auto-scanning turned a CI job whose scan step was deleted or misordered
  from a loud exit 2 into a green exit 0. That inverts the fail-closed guarantee the gate exists for, and
  it composed with the zero-match silent green, now closed four-way by the ⟨0.27⟩ §4 rule.
- **A capability refusal now precedes any write.** `candor privacy-manifest` in a Rust project refused —
  after auto-scanning and writing `.candor/`. A usage error must not mutate the working tree.
- **The auto-scan triggers on "no REPORT", not "no `.candor/`".** `candor init` commits `.candor/` and
  gitignores the report, so the one repo shape `init` produces was the shape that got the old lecture
  instead of the scan.
- **`adopt/candor-init` is found in the brew layout too.** It was resolved only as `$tooldir/adopt/…`,
  which exists in a git checkout and not in a brew install, so a brew user got a baseline-only `init` and
  a "policy proposal skipped" line while the formula's caveats promised the full gate. It degraded rather
  than failing, which is why it went unnoticed; `adopt_tool` now runs the same two-layout search the hook
  scripts have always used. Verified in both a real checkout and a simulated brew prefix.
- **Two more copies of the sidecar rule** — the python and grep forms in the status dashboard — learned
  `.locs.`, which makes six and seven copies of a rule the centralising commit claimed to have reduced
  to one.
- **`--target` added to both value-flag skip lists**, so `candor scan --target X .` finds its positional;
  `init` now checks the pinned Swift release actually carries a binary before calling the generated
  workflow ready (it would have 404'd on first run); and `CANDOR_NO_AUTOSCAN`/`CANDOR_NO_AUTOFETCH` are
  documented in `--help` rather than only in source comments.
- **Two commands from nothing: `brew install candor` → an answer.** A verb that needs a report and finds
  none now SCANS first (saying so, and saying it wrote `.candor/`) instead of printing the one command
  the user could have run; an engine that is not installed is fetched at the pinned version from the same
  registries `candor update` uses, announced before the network is touched. `CANDOR_NO_AUTOSCAN=1` and
  `CANDOR_NO_AUTOFETCH=1` restore the refusals for CI that should fail rather than act. Telling someone
  to go and run the only possible next command is a dead end with extra steps.
- **`candor init` generates a Swift CI workflow.** It used to print "the Swift engine needs macOS + a
  source build … so no drop-in workflow is generated" — a dead end inside a generator whose entire job
  is producing a workflow that runs. Now emits a `macos-14` job that curls the released binary, with
  commented lines for `--target` and a per-plist `privacy-manifest --verify`.
- **Swift engine resolution** now checks `~/.candor/bin` as well as PATH, across all six lookup sites
  (scan, query, the availability probe, and three status surfaces) — otherwise a binary `candor update`
  fetched would be invisible to the tool that fetched it.

## 2026-08-05 — spec 0.27: a producer declares which refinements it computes (released 2026-08-09 as 0.27.0)

⟨spec 0.27⟩ the rung: `resolves`, a top-level envelope array naming the optional §2 refinement surfaces
a producer actually computes — so an absent optional field means "undetermined" only when the surface is
declared, and "not computed here" otherwise. Plus §2 `fs` kinds travelling the call graph four-way, with
an undetermined contributor suppressing the field rather than emitting a partial one.

Umbrella-side in this cut:

- **`--help` for a verb the local engine lacks is no longer a dead end.** `candor show --help` in a Swift
  project printed a full page describing a verb candor-swift does not implement. Help now carries the
  same note the refusal does, and stays SILENT when the arm cannot be determined — an empty tree, a mixed
  manifest, or a `.candor` holding two engines' reports, which is the ordinary shape once dep reports are
  chained. `gate` and `privacy-manifest` gained real help text; routing them had only moved the dead end.
- **`spec-bump.sh`** — rehearse a floor bump instead of discovering it in CI. Its `bad()` printed without
  counting, which produced three false greens (a moved declaration site reported "the family is GREEN"
  with one engine still on the old contract); its two siblings in `bin/` both count, and now so does it.
- **`scripts/android-permission-coverage.py`** — measures whether an Android analogue of the privacy
  manifest can read a vendor-published API→permission mapping. It can, for the system surface; the
  ContentResolver surface has zero annotations, so the consumer-privacy half is a value-provenance
  problem. See BACKLOG.md.

## 2026-08-02 — spec 0.26: a sidecar's KEY SET is its manifest (released 2026-08-04 as 0.26.0)

⟨spec 0.26⟩ **§2.2 — an absent type in the hierarchy sidecar is UNANSWERABLE, never "has no supertypes".**
A producer emits a key for every type it indexed (`[]` included); a consumer treats a type absent from a
present sidecar as unanswerable and DISCLOSES rather than dropping. Adds the optional `@unanalyzed`
diagnostic key.

The measurement that made it a format change rather than a consumer patch: with only the sidecar doctored
on a real scan, removing ONE entry dropped a reacher from `callers --include-unknown`, while removing the
sidecar ENTIRELY left the answer correct. **A partial sidecar was worse than an absent one** — and no
consumer can patch around that alone, because without a manifest it cannot tell a producer's silence from
its answer. java and ts behaved identically, which is evidence about the FORMAT rather than either engine.

Engine work in all four: java `78aad6d`, ts `caeda66`, swift `ea3de21`, rust `4cae735`. Pinned by
conformance **PART 30 (P6)** — the property the self-differential family was missing, since P2 and P3
degrade the chained dep REPORT and nothing degraded a SIDECAR.

Engine pin unchanged at 0.25.0: the rung is built and conformance-pinned but not yet published.

## 2026-08-02 — spec 0.25: an ambiguous join key is UNIONED, not dropped (engine pin 0.25.0)

⟨0.25⟩ SPEC §2 chaining rule 1 REVERSED: through 0.24 it prescribed dropping an ambiguous key, which took
the calling function out of `functions` — a ⟨0.21⟩ purity claim over a call the engine had just declared
itself unable to name. All four engines already UNION, and conformance pins it, so an engine conforming to
the 0.24 text would have failed the suite. **No engine work: this is the contract catching up.**
`ENGINE_PIN` moves to 0.25.0 with the floor.

## 2026-08-01 — spec 0.24: contributes, ambiguity, and a gate that can now go red (engine pin 0.24.0)

The family floor moves to **spec 0.24** — all engines at **0.24.0**, `ENGINE_PIN` bumped, so `candor update`
fetches the 0.24 engine line. This changelog had lagged at 0.18 while the pin moved several times beneath
it; the intervening rungs are recorded in
[candor-spec's changelog](https://github.com/tombaldwin/candor-spec/blob/main/CHANGELOG.md), which is the
authoritative contract history.

**CONTRIBUTES**, **`ambiguous:` as a fifth reason kind**, the frontier's **unanswerable-condition rule**,
**`gate --report`**, **locale-independent ordering**, and **`--class` semantics**, pinned four-way by
conformance PARTs 24–27.

**If you run candor in CI, read this one.** This is the first rung that can turn a **green gate red**: a
`--strict` step on `unverified` or `fix-gate` that read green over a report `gate --report` refuses now exits
2. That green was the defect — the advisory verb was reporting a cleaner answer than the gate would have
given over the same evidence, and §3.2 now states the law as a containment: an advisory verb may be **less**
certain than the gate, never **more**. Measured at 0 flips against trusted dependency reports and 36%
against stale ones, so a newly-red step is telling you the reports it read were stale.

**Fixed here, and it affected adopters directly:** `adopt/candor-digest.yml` pinned `candor-agents@v0.23.0`
after a repair of mine that was itself the regression — the pin it "fixed" was correct, and the change
quietly moved every new adopter one release back. It now tracks the release line at `v0.24.0`.

## 2026-07-16 — spec 0.18: the trust-trio (engine pin 0.18.0, umbrella 0.18.0)

The family floor moves to **spec 0.18** — all engines at **0.18.0**, `ENGINE_PIN`/`UMBRELLA_VERSION` bumped.
A pinned-tool-surface rung (no report/verdict change) closing three ways the tool could quietly mislead, each
pinned four-way: the **`--strict` advisory-verb CI gate** (`fix-gate`/`gains`/`unverified` advisory at exit 0,
`--strict` → exit 1 while a finding remains; a typo'd flag rejected loud, never a swallowed disarmed gate),
and the **surface/`tour` mostly-Unknown disclosure** (never "nothing hidden" over a ≥⅓-Unknown graph; a
`tour --json` `unknown: {count, total}` field). Hardened by a Fable-model code review that caught two latent
cardinal-sin edges (swift's un-gated scan opener; java's single-dash flag swallow).

## 2026-07-10 — the owner digest (visibility for the silent gate)

The gate is deliberately silent when nothing is wrong — so nobody sees it working. The **digest** closes
that gap without adding developer-channel noise: an owner-facing protection report over the activity the
gate already logs.

- `integrations/DIGEST-SPEC.md` + the `candor-agents digest` renderer (P1); the gate now logs **outside**
  the agent hook so "held the line in CI" is real (P2, `integrations/claude-code/`); and the whole gate
  feeds it — the pure-jar PR path logs via `candor-agents log-gate`, wired opt-in in `adopt/candor.yml`,
  plus a scheduled `adopt/candor-digest.yml` that renders the report to the run summary, commits it, and
  optionally pushes to Slack (P3). Dogfooded over candor-java's own bytecode; two report-wording fixes fell
  out (shipped as candor-agents 0.8.3).

## 2026-07-10 — the gains supply-chain wedge (prototype)

`candor-gains` (local prototype): a version-pair driver over the `gains` query that flags what a dependency
*upgrade* newly lets it do — the corpus doubles as the cache (a callgraph existence oracle), signal-tiered
(existing-code-gained / new-function / Unknown / cross-cutting). A demand-probe landing page is live at
`candor.poly.io/gains/`.

## 2026-07-10 — the whatif code action reaches both IDE clients

The **VS Code / Cursor / Windsurf** thin LSP client extension shipped; with the JetBrains client (via
LSP4IJ) both IDEs surface the `candor: what if <fn> performed <Effect>?` code action from `candor-lsp`
(candor-ts 0.8.9) — the edit-time blast-radius surface, no client-side analysis code.

## 2026-07-08 … 07-03 — the JetBrains plugin

`candor-intellij` — an LSP4IJ client bundling a pinned, self-refreshing candor-java server, verifier-clean
across 6 IDE targets, its build gating its own embedded server (a verify-server handshake). Uploaded to the
JetBrains Marketplace (0.1.0). Plugin `major.minor` tracks the bundled toolchain's spec.

## 2026-07-09 … earlier — the adoption floor

- **The PR-native gate** — `adopt/candor.yml` runs the engine over compiled bytecode and turns the
  `--gate-json` verdict into **SARIF** (`integrations/github/candor-sarif`), so violations show inline on
  the PR diff and in the Security tab, on the exact line a boundary is crossed. `candor-init.sh` vendors a
  pinned reporter so CI is immune to upstream churn; one pin source drives both the init scan and the gate.
- **`.candor/config`** (SPEC §3.4) supported across the adopt path; the AS-EFF-005 baseline ratchet wired
  into the gate.
- **The effects-fingerprint** (`fingerprint/`) — a deterministic effects-fingerprint SVG, now with a
  hermetic determinism test and CI.
- **The agent-loop** — the Claude Code Stop hook (`integrations/claude-code/`) closes the edit-time
  feedback loop (scan → diff the gained effects + blast radius → block on a violation), with hover
  provenance and the whatif action over LSP.
- **`TESTING.md`** — the family test standards (two layers, fail-closed negative tests, anti-fabrication
  twins, byte-identity-gated refactors, mandatory red-then-green regression tests).

Per-commit detail: the repo's git history and `BACKLOG.md`.
