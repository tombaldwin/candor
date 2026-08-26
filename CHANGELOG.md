# Changelog — candor (umbrella)

This is the umbrella repo: the **adoption and integration surface** over the engines — the drop-in CI
workflows (`adopt/`), the IDE and agent-loop clients (`integrations/`: GitHub Action, Claude Code hook,
VS Code and JetBrains LSP clients), the effects-fingerprint (`fingerprint/`), and the family docs
(`BACKLOG.md`, `TESTING.md`, the case studies). It is **not a versioned release artifact** — it pins the
engine versions it targets, so this changelog is **dated**, most recent first. Engine contract history lives
in [candor-spec's changelog](https://github.com/tombaldwin/candor-spec/blob/main/CHANGELOG.md); each engine
keeps its own.

## 2026-08-26 — ⟨0.33⟩ CUT: the floor moves to 0.33, and a stored report has to be re-scanned (released 2026-08-26 as 0.33.0)

- **THE FLOOR MOVES TO 0.33 — `scannedUnder`, and a gate that refuses a peek it did not commission.**
  `excluded[].peeked: true` was only ever true *relative to the deny set the producer held* — ⟨0.29⟩
  bounds the peek to effects that policy DENIES — and the report never recorded what that set was. A
  consumer gating with a different deny set therefore got a definite answer to a question nobody asked,
  and it failed OPEN on `gate --report`: the supply-chain route, past every ⟨0.32⟩ control, because the
  class really was read. The envelope now carries `scannedUnder: { "deny": [ … ] }` under exactly
  `outOfScope`'s emission rule, and a gate whose own expanded deny set is not a subset of it, over a
  report carrying any `peeked: true` class, answers `ok: false`, `incomplete: true`, exit 2. Built
  four-way; conformance PART 69 (and PART 70 for the ⟨0.24⟩ advisory verbs). Contract detail in
  [candor-spec's changelog](https://github.com/tombaldwin/candor-spec/blob/main/CHANGELOG.md).

- **MIGRATION — ⟨0.33⟩ IS NOT ADDITIVE, and the cost is measured, not estimated.** If you gate a
  **STORED** report that a pre-0.33 engine produced — committed to a repo, cached between CI jobs, or
  published by a dependency and gated downstream — expect exit 2. Measured over **32 real third-party
  projects, 67 reports, 402 report×policy pairs, all four engines**, published **0.32.1** binaries as the
  producer against **0.33** HEAD as the consumer: **202 of the 265 pairs that pass today — 76.2% — flip
  to exit 2** with the policy unchanged. It is deterministic rather than statistical: a report carrying
  any `peeked: true` class refuses **202 of 202**, a report carrying none passes **63 of 63**, and **26
  of the 32 projects** have at least one.

  **THE REMEDY: re-scan with a 0.33 engine under the SAME policy the gate applies** — not merely *a*
  policy, which is the loose reading this rung exists to close. It discharges the cost in full: **265 of
  265** pairs green again, no residual tax and nothing to suppress. `adopt/candor.yml` scans, writes
  `--gate-json` and enforces the policy in ONE run — its own comment says so in as many words — so a
  repo that adopted candor through the drop-in workflow is **unaffected**: producer and consumer are
  the same run, so `P ⊆ P` holds by construction. What is affected is the shape `gate --report` exists
  for: a report produced once and gated later, or elsewhere, which is the supply-chain route this rung
  found failing open. Legitimate narrowing is not over-charged either — **62 pairs** whose producer's
  deny set genuinely covers the gate's took **0 refusals**, and over the full cross-policy sweep of
  **918 gates**, **529 refuse correctly and none fails open**.

  **The operators this hits are the ones who followed ⟨0.32⟩'s own remedy** — *scan with the policy* —
  because that is exactly what puts a `peeked: true` class into a report. They migrated one rung ago and
  are being asked to migrate again, for a hole that remedy did not close. The wording was the defect and
  the wording is the fix. It fails **CLOSED**.

- **`bin/spec-bump.sh` now rewrites the doc and packaging literals by machine, and NAMES the pins it
  must not touch.** The spec version was written by hand in 35 claim occurrences across 19 documents in
  the seven repos, in what turned out to be FOUR spellings — the fourth, a version behind a markdown
  link, put candor-swift's README headline outside its own drift gate. Step 1b rewrites them over an
  explicit ALLOWLIST of 21 documents plus SPEC.md's JSON fences (an allowlist because the 0.27 bump
  proved a blanket sweep destructive — candor-rust's `tests.rs` builds fixture reports at the PREVIOUS
  spec as INPUTS — and because an allowlist under-reaches in the safe direction: a doc it forgets is a
  doc the derived gates redden on). Step 1c prints the three deliberate pins with their exact
  before → after and refuses to edit them, and now FAILS when it cannot locate one, because a missing
  pin reads exactly like a satisfied one. Verified by running the bump for real in a disposable clone of
  all seven repos: an independent oracle written from the grammar rather than imported from any engine
  found every declaration and every gated document at 0.33, nothing left at 0.32, and no fixture or
  backward-compatibility input swept.

## 2026-08-25 — the umbrella's own workflows can be run locally, and the ladder has a dress rehearsal (released 2026-08-26 as 0.33.0)

- **`bin/verify-umbrella.sh` — what `bin/verify-local.sh` is for the engines, for this repo.**
  `verify-local.sh` walks the engine repos; nothing ran candor's own three push-triggered workflows, and
  that gap showed three times in one day. An agent ran four commands in a clean worktree and called them
  "the union of what the three workflows run" — `integrations.yml` runs **nine** steps and exactly one of
  those four commands is one of them, so main went red on the push. `release-test.sh` said 148/148 locally while CI said 8 FAILED,
  because local ran against a working tree CI never checks out. And a reproduction on **arm64** Linux
  reported 18 failures where CI reported 2.

- **The step list is DERIVED, never transcribed** (`bin/wf-steps.py`, new). Every `run:` step in
  `.github/workflows/*.yml` is enumerated from the YAML; add a step to a workflow and it runs here with
  no edit to the runner. A hand-kept list of what CI runs drifts from CI by construction, silently, in
  the direction of running less — and its shortfall looks exactly like a pass. Whether GitHub would
  *trigger* a workflow stays `bin/wf-expected.py`'s question, asked rather than re-implemented.

- **What it did NOT run is part of every report**, counted, with a reason each: a scheduled monitor
  (`corpus.yml`, `release-audit.yml`), a job whose `if:` is false for a push, a step needing a secret or
  an unresolvable `${{ }}`, a workflow GitHub's path filter would not start for this commit.

- **It runs a COMMIT, in a throwaway worktree** — the 148/148 case — and prints the sha it validated.

- **`--docker` reproduces the platform, on `linux/amd64` explicitly.** Measured on the commit before
  `0382c91`: all nine `integrations.yml` steps pass on darwin/arm64, and the dispatcher routing contract
  fails on linux/amd64 with `candor-dispatch: 2 FAILED` — the same **two** CI reported, not the eighteen
  an arm64 run produced. A faithless reproduction manufactures work; `--platform linux/amd64` is not
  optional in it.

- **`bin/release-rehearsal.sh <spec> <version>` — the ladder minus publishing, every failure at once.**
  The 0.32.0 cut discovered failures serially: rust CI red → fix → push → wait → swift red → fix → push
  → wait → spec red, then preflight failures over three more rounds, ~10 minutes a loop. Four arms —
  tree state for every repo (`release.sh` step 0 without its `die` on the first), engine suites, the
  umbrella workflows, and `release-preflight` — run concurrently, none short-circuiting another, ending
  in one numbered list. It refuses without both arguments, because a bare `release-preflight.sh` is
  health mode and its `OK` has been quoted as a release gate.

- **And it says what a rehearsal cannot prove**: CI on a pushed commit, registry state, the publish
  calls' network half, and anything downstream of the release existing.

- **`release-scripts.yml`'s `parse every release script` step was VACUOUS, and is fixed.** Found by
  mutating a script the step names and watching the step pass. `set -e` — GitHub's default `run:` shell
  is `bash -e {0}` — does not fire for a command on the LEFT of `&&`, so `bash -n "$f" && echo "  ok  $f"`
  printed `syntax error: unexpected end of file` for `bin/changelog-lag.sh`, the loop carried on, and the
  step's exit status was the last command's. **STEP EXIT CODE: 0.** The gate whose entire job is to
  notice a parse error could not fail on one. It now collects every failure and exits on the count.

- **`bin/wf-expected.py` takes the target branch as `argv[3]` and refuses on a detached HEAD.**
  `rev-parse --abbrev-ref HEAD` answers the literal string `"HEAD"` in a detached checkout: not empty, so
  its `or "main"` fallback never fired, and matching no `branches:` filter. `verify-umbrella` validates
  commits in exactly such a worktree, and its own first green control printed OK having run 2 steps of 23
  — silently dropping three workflows the commit's paths trigger.

- **`verify-umbrella` states its one deliberate divergence from GitHub on every run**: a real job stops at
  its first failed step; this runs every step of the job, because the point is N problems in one pass.

- **`just verify-umbrella`, `just verify-engines`, `just rehearse`** — the recipes, so the commands are
  discoverable rather than remembered.

## 2026-08-25 — `ENGINE_PIN` splits per engine, so a one-engine patch reaches the front door (released 2026-08-26 as 0.33.0)

- **`bin/candor` now carries a per-engine pin beside the family one.** `ENGINE_PIN` was a single value
  read for the candor-java release tag, `cargo install --version`, `npx candor-ts@…` AND the candor-swift
  tag alike — so no value of it said "java 0.32.1, everything else 0.32.0", and 0.32.1 republished five
  engines with no functional change to deliver one candor-java native-image fix. `--only` had already made
  a one-engine CUT expressible; the front door was the last place the lockstep assumption lived.
  `ENGINE_PIN_JAVA` / `_TS` / `_RUST` / `_SWIFT` default to empty, meaning "follow the family line", with a
  `CANDOR_ENGINE_PIN_<ENGINE>` env seam above them.

- **All four engines, not just java** (the backlog entry named java alone). java was special in occasion,
  not in kind: each engine has its own release channel and its own patch case, an asymmetric override
  would have to be redesigned the first time candor-ts or candor-rust needed one, and four symmetric pins
  let the release guard be **one rule over four engines** instead of a special case. candor-agents and
  candor-spec get no pin — the umbrella never installs them.

- **Every consumer of an engine's version moves with its pin**, which is the half that would otherwise be
  worse than no pin at all: the java release tag, jar filename and fallback URLs; the npx invocation on
  all seven ts routes (query, scan, verify, lsp/mcp, hook-run, doctor, `engine_release`); `cargo install
  --version`; the candor-swift asset; the CI workflow `candor init` generates for that language; and
  `update`'s **stale-native version check** — left on the family line it would have DELETED a correctly
  installed patched engine as stale.

- **Default behaviour is byte-identical, measured rather than asserted.** A harness drives 25
  version-bearing strings through the real code paths on the old and the new dispatcher; `candor doctor`,
  `engines`, `update` and `--version` are diffed whole. All identical. That is why every disclosure below
  is gated on divergence existing rather than printed unconditionally.

- **`doctor` and `engines` disclose divergence, and `update` says it before fetching.** Divergence is now
  expressible, so an operator diagnosing "why is my jvm engine a different version from everything else"
  can see it without reading the dispatcher. Silent when nothing diverges.

- **The update-check notice compares each channel to its OWN pin.** Against the family line alone it would
  nag "0.32.2 is available" about the release the machine is already pinned to, which is how a real notice
  stops being read.

- **Fixed while here, in the safe direction and disclosed:** every reader of `~/.candor` picked the jar
  with `ls candor-java*-all.jar | head -1`, and `ls` sorts **ascending** — so with two jars stashed the
  dispatcher ran the OLDEST while `candor update` reported the newest. Already reachable (an update at
  0.31 followed by one at 0.32 leaves both, and `update` removes a stale *native binary* but has never
  removed a stale jar); per-engine pins make two jars an ordinary state. `java_jar()` now takes the pinned
  jar, else the newest by version, glob-driven.

- **The release tooling asks the same question in both places.** `bin/_release_set.sh` gains
  `rs_engine_pin` / `rs_pin_violations`, used by `release-preflight [3]` and `release.sh` step 7 so the
  gate before a cut and the gate during it cannot disagree. The rule: every engine this cut publishes must
  resolve `$VER`; every engine it does not must resolve something else, because `$VER` was never cut for
  it and a pin naming a release nobody made 404s on a user's machine. Family-wide this reduces to the
  `ENGINE_PIN == $VER` check that was always there, **plus one it could not express** — a leftover
  per-engine pin holding one engine behind while the family moves past it.

- **So `--only candor-java,candor` now cuts the umbrella too**, and that is the shape a one-engine patch
  takes end to end. `--only candor-java` alone still leaves the front door where it is and says so, with
  the two-repo form printed as the remedy.

- **`release-verify.sh` builds the java asset URLs from the JAVA pin**, not the family line: under a java
  patch those are different versions, and the family line resolves the assets of the release the patch
  REPLACED while reporting the front door verified. Its `ENGINE_PIN` comparison is directional now —
  behind `$VER` fails, ahead is reported and the run continues — because `release-audit.yml` runs the same
  script weekly with `$VER` derived FROM the family pin, where an engine pinned ahead is the ordinary
  state rather than a fault.

- **Every guard falsified: 18 mutations against the code each row covers**, all caught, run in a
  disposable `git worktree` at the exact commit rather than against a working tree only this machine has.
  Two rows had no teeth on the first pass and both are recorded because the shapes recur: a control that
  grepped the **message text**, which `bad` and `note` print identically, so downgrading a failure to a
  remark left it green (it now asserts the ✘ and that the run does not certify itself); and two `java_jar`
  rows in which the pinned jar was also the newest, so they could not tell the pin from the sort. The
  battery refuses to score a mutation that did not change the file, so a regex matching nothing reads as a
  broken row rather than as a passing one.

- **Two of those rows were then RED on `ubuntu-latest` while green on macOS, and the finding is about the
  suite rather than the pin.** `candor update swift` builds its download URL — the only place it names a
  swift version — inside a branch gated on `Darwin && arm64`, because candor-swift publishes only a
  `macos-arm64` asset. Off that platform it prints "macOS only" and names no version at all, so the two
  rows asserted a string that cannot exist there. `ENGINE_PIN_SWIFT` itself is declared, resolved and
  consumed exactly like the other three — **the four pins stay symmetric and the release guard stays one
  rule over four engines**; the asymmetry is one platform-gated branch that predates them. The rows are
  now `Darwin:arm64` / `Darwin:*` / everything-else, each asserting what that platform actually prints,
  with a **visible SKIP counter** (`candor-dispatch: OK (1 SKIPPED …)`) so a row that cannot be measured
  is never read as one that passed. The swift pin's cross-platform coverage is the generated-CI-workflow
  row, which builds `download/v<swift pin>/candor-swift-macos-arm64` everywhere — verified by mutating
  `ENGINE_PIN_SWIFT` *inside a linux/amd64 container* and confirming the suite still goes red there.

- **The process gap was the inventory, not the checkout.** The verification ran in a disposable worktree
  at the exact commit — right, and it caught two vacuous rows — but it ran four commands described as
  "the union of what CI runs". `integrations.yml` runs **nine** steps, and the dispatcher routing contract
  was not among the four. All nine now run, transcribed from the workflow file rather than from memory,
  on `linux/amd64` to match the runner (an arm64 container reported 18 failures, twelve of them artefacts
  of the wrong architecture — a faithless reproduction is its own trap).

- **NOT SOLVED, and it is the honest residual.** `release-audit.yml`'s weekly npm/crates checks compare
  the registry's newest against a single `$VER` derived from the family pin, so a **ts- or rust-only**
  patch makes that monitor red until the family moves. Pre-existing — a scoped cut already published to
  those registries without moving `ENGINE_PIN` — and not made worse here (a java-only patch is fine,
  since GitHub releases are checked per tag), but per-engine pins make the case likelier and it should
  move to a per-engine comparison next.

## 2026-08-25 — the gates that only ran at release time now run on `main` (released 2026-08-26 as 0.33.0)

- **candor-java's native/jar parity gate and candor-swift's release-configuration build moved off the
  release trigger.** Both are engine-repo changes (candor-java `ebe40af`, candor-swift `8c62b5a`); what
  lands here is the inventory and the ladder's side of it. A gate positioned after the irreversible step
  grades the release, it does not guard it: on v0.32.0 the parity gate correctly withheld two native
  binaries that reported an empty scan at exit 0, but only once v0.32.0 was public, and the repair cost a
  second family cut. Full moved/cannot-move verdict for every release-triggered check across all seven
  repos — three workflows, six checks — in `BACKLOG.md`, along with the falsification (PR #2 on
  candor-java reintroduced the defect; the parity step went red on both legs on a `pull_request` event).
- **`release-preflight` [10] gained the guard for free and its comment now says so.** [10] matches runs
  on the released commit by SHA, not by workflow name, so a `native` run on `main` means [10] already has
  to see a green native parity check on the very commit being cut, before the tag is pushed. It also now
  waits on `native`'s release-event run at the tail of a cut (~4 min); the comment previously named only
  candor-ts's `publish` and candor-swift's `release` as the workflows a tag starts. `release-verify.sh`
  is untouched and still resolves `candor-linux-x64` + `candor-macos-arm64` on the published release —
  the upload still happens on `release: published`, only the *proving* moved.

## 2026-08-25 — release tooling: the only cut it could express, and the notes it published (released 2026-08-25 as 0.32.1)

- **Front-door pins → 0.32.1.** `ENGINE_PIN`, both `adopt/` workflows and the two IDE pins now
  name the release carrying candor-java's native binaries, so `candor update` and Homebrew reach them
  rather than the jar fallback.

candor versions on three axes — the **spec** (a cross-engine contract), the **build id** (per engine),
and crate semver — and SPEC.md's *Versioning policy* says the family moves as a **ladder, not a lockstep
stamp**. `release-preflight.sh` [4] says the same in its own comment: *"a build id is PER-ENGINE by
design … demanding equality DESTROYS the information the build id exists to carry"*.

The scripts said the opposite. `release-verify.sh` demanded a v`$VER` release on **all seven** repos,
`max_version` = `$VER` on four crates and npm at `$VER`; preflight [3] demanded **all seven** cross-repo
pins at `$VER`, including two `candorTsVersion` pins and `candor-agents@v`; `release.sh` published four
crates, tagged npm and cut six GitHub releases unconditionally. Measured against a candor-java-only
0.32.1 tree, `release-verify` reported **19 failures** for a cut that was entirely correct.

That was tooling, not a ruling: candor-swift's and candor-agents' `## [0.29.1]` entries read, verbatim,
**"Family build bump only — no engine changes in this repo"** — two repos republished to say they had
not changed, written by hand only because an empty `## Unreleased` would otherwise have made `release.sh`
publish 0.29.0's notes under a 0.29.1 tag.

**`--only <repos>`** now names the cut set, on all four scripts (`bin/_release_set.sh` is the single
list they share, which is also the root fix for the drift preflight [8] exists to catch). Short forms
`java`/`ts`/`rust`/`swift`/`agents`/`spec`/`umbrella` are accepted; an unknown name and a valueless
`--only` are both **exit 2**, because the two failure modes of a set selector are "cut nothing while
reporting success" and "cut everything, chosen by a typo".

Scoped, the version-shaped checks follow the cut — [3]'s pins by **owner** (each names one engine's
version), [4]'s build constants, [6]'s crate deps, [7]'s java jar, [9]'s `## Unreleased`, [10]'s CI,
and every publish step. Family-wide claims stay family-wide: [1] the declared spec, [2] stale spec
strings, [5]/[5b] the changelogs, [8] the script repo lists, [12] the rung marker, and — deliberately —
**[11] four-way conformance**, because publishing one engine still asserts it agrees with the other
three at the floor, and a one-engine patch is exactly where a divergence gets introduced. Scoping that
would make the cheapest release the least checked.

Out-of-scope checks print `⊘` and are counted separately: a scoped `release-verify` never says "live
everywhere", it names the set, the number of questions it declined and the invocation that answers
them. The bare form is byte-for-byte what it was, which is what `release-audit.yml` runs weekly.

**WHAT A SCOPED CUT STILL CANNOT DO, and it is a real limit.** `bin/candor`'s `ENGINE_PIN` is **one
value for the whole family** — the java release tag, `cargo install --version`, `npx candor-ts@…` and
the swift tag all read it — so no value of it says "java 0.32.1, everything else 0.32.0". A subset cut
therefore publishes engine releases and moves the **per-engine** pins (adopt's `CANDOR_JAVA_VERSION`
and `candor-agents@v`, jbang's script-ref, the IDE plugins' `candorJavaVersion`/`candorTsVersion`) and
leaves the front door alone: `candor update` and Homebrew keep installing the family line until the
family moves. Making that expressible needs a per-engine pin in `bin/candor`, which is a change to the
FRONT DOOR rather than to the release scripts, and is left filed rather than smuggled in here.

`release-verify.sh` also gained `CANDOR_ROOT`, the fixture hook the other three release scripts have
had all along — it was the only one of the four that could not be run against anything but the live
sibling checkouts, so its pin-reading half (where the 0.24 failure lived: a pin naming a release that
did not exist) could only ever be exercised by publishing.

`bin/release-test.sh` gains **27 rows** (section 8) with the publish calls stubbed — `cargo`, `gh`,
`npx`, `npm` and `git push` shimmed on PATH, so `release.sh` runs its real sequence end to end and
nothing leaves the machine. That closes the gap this harness's own header records: *"the publish calls
themselves … cannot be exercised without either a dry-run mode or stubs, and neither exists yet"*.
Every scoped row is paired with a CONTROL proving the check still fails: java's version lagging, the
jar unbuilt, conformance red, and — family-wide — the step-7 `ENGINE_PIN` guard still refusing a
lagging pin and the crates still being published.

Four defects found while proving it, three of them in this work:

- **preflight [8] caught a phantom eighth repo that a COMMENT introduced.** [8] derives the verifier's
  repo list by grepping the quoted `repo:tag` strings out of `release-verify.sh`; a comment I wrote
  containing an example of that exact shape was read as a repo the verifier checks and the publisher
  does not. The check is a text derivation, so anything shaped like the text is part of the list.
- **the emptiness guard would have failed an agents-only cut for being correct.** "No pinned download
  URL" is a failure for a cut that owes an artifact (java, swift); candor-agents ships through
  `pipx install git+…@vX` and candor-rust/candor-ts through crates.io and npm, so an agents-only cut
  resolves nothing by design. A gate that fires on a correct state is one that gets waved through.
- **two of the new harness rows could not fail.** The stub `cargo` wrote to stderr, which `release.sh`
  redirects into a file — so "publishes no crate" and its family-wide control were both asserting over
  text that could never appear. Found by mutating the guard and watching the row stay green.
- **a row's own label executed.** `ok "…keeps its \`## Unreleased\`…"` — backticks inside a
  double-quoted string are live command substitution, which is [7c]'s defect class occurring inside the
  harness that gates it. The label printed with the filename deleted.

### …and an EMPTY `## Unreleased` published the PREVIOUS version's notes under the new tag

`_stage_changelogs.py` skips an empty `## Unreleased` — deliberately, so nothing ships unlabelled — so a
repo with nothing to say got no `## [VERSION]` heading. `release.sh` then fell through to *"the newest
non-empty section"*, which is the previous release's notes, published under the new tag and announced by
a yellow `•` at the end of a long release. The state that reaches it is the ordinary one: a repo with
nothing to say is exactly what a family BUILD BUMP is.

**Measured three times, and papered over each time.** candor-swift's and candor-agents' `## [0.29.1]`
entries read, verbatim, *"Family build bump only — no engine changes in this repo"*, and say in the entry
itself that they were hand-written only because an empty section would otherwise republish the previous
notes. candor-agents hit it again before the 0.32.0 cut, caught by a reviewer reading the script. And
after that cut all seven repos sat with an empty `## Unreleased`, so a family-wide 0.32.1 would have
published 0.32.0's notes under v0.32.1 in **six of them**. The workaround was known, performed by hand,
and undocumented anywhere a script could enforce it — which is the shape that gets skipped at the end of
a long day.

**The asymmetry decides the fix.** Publishing the wrong notes is silent and reaches users, permanently.
Refusing to publish is loud, reaches one operator mid-run, and costs a re-run — `release.sh` steps 1-3
skip whatever already exists. So the fall-through is gone rather than made less likely:

- **`bin/_release_notes.sh`** is now the one program that decides a release body, and it REFUSES rather
  than guesses. `release.sh` calls it; so does preflight, so the gate and the publisher cannot ask
  different questions. Its own header carries the reasoning.
- **The positional "newest section" arm survives for the umbrella alone** — this changelog is dated, not
  versioned, so its notes genuinely are its newest section — and it is fenced a second time: the selected
  heading must carry the stager's `(released … as $VER)` stamp. Without that fence the umbrella keeps the
  whole defect in its own spelling, which nothing had noticed. Naming one repo is an allowlist, and the
  right shape here only because its omissions fail by REFUSING.
- **A version heading with no body is refused too.** GitHub takes the body verbatim, so `## [0.32.1]` and
  nothing else publishes a release whose notes are one line — and for candor-spec a bodyless patch heading
  used to slide onto the floor section below and publish the floor's notes under a patch tag.
- **`release-stage.sh` now STUBS an empty section instead of skipping it**, opening `## [VERSION]` with a
  one-line *"build bump only — no changes recorded in this repo"* entry, and re-prints every stub it wrote
  under its summary because that sentence is a CLAIM and not a version number. The original concern is
  intact — nothing ships unlabelled — but it is answered with a label instead of with silence. The
  umbrella gets the same treatment in its dated spelling. `release-preflight.sh` [5b] remains the check
  that asks whether source moved without the changelog; a stub does not answer it.
- **`release-preflight.sh` [9b]** asserts the complement of [9]: [9] asks whether anything is stranded
  UNDER `## Unreleased`, and certified as clean the exact tree that mis-published. [9b] asks whether the
  version being cut has notes at all.

`bin/release-test.sh` gains **33 rows**. Twelve are MUST-REJECT and six MUST-ACCEPT; every one was pointed
at the pre-fix logic first, where all twelve reject rows went green and five published the literal stale
body, while all six accept rows still passed — which is what says the battery discriminates rather than
merely refuses. A refusal is additionally asserted to write **nothing** to stdout, because `gh release
create -F` reads the file it is handed whatever the exit code said.

One defect found while proving it, and it was in the harness rather than the scripts: **rows 1b staged a
different version into the SHARED fixture and left two repos dirty**, so groups 2 and 3 inherited them.
That was invisible while an empty section was silently skipped and surfaced the moment it was stubbed —
the hazard row 1b2 exists to record, in the rows immediately above it. They now work on their own copy.

## 2026-08-25 — the jar was written as the OTHER platform's branch, so it could never be a fallback

`candor update` fetched this platform's native binary and, on failure, printed
`✘ download failed` and stopped. The jar branch was the `else` for platforms with **no**
native asset, so it was unreachable on the two platforms that have one. At
`ENGINE_PIN=0.32.0` — a release that published the jar and neither native binary, because
the native workflow's parity gate correctly refused an image that reported an empty scan —
that meant `candor update` could not install the JVM engine at all on macOS-arm64 or
linux-x64, and still exited 0.

A native-asset 404 now falls back to the jar for the same tag: same engine, same version,
and it **says so** — that it is not the no-JVM install, that `java` must be on PATH, and it
warns when there is none. Silence there is the worse outcome of the two: a user who
believes they have a no-JVM install and does not finds out on a machine without a JDK.

Three things the fallback deliberately does not do:

- **It does not paper over a corrupt download.** The binary must pass `--version` before it
  is installed at all (`curl -f` only says the bytes arrived; a truncated or wrong-arch
  file arrives with a 200 and then fails to exec, and `run_java` prefers
  `~/.candor/bin/candor-java` over every later tier, so an unusable file installed there
  takes the engine down for every subsequent command). An asset that downloads and will not
  run is a **published, broken** asset — substituting the jar would hide that behind an
  install that looks healthy on every machine of that platform. It stops, names the
  artifact, installs and removes nothing, and prints the flag that takes the jar
  deliberately: `CANDOR_NO_NATIVE=1 candor update jvm`.
- **It does not leave a stale native binary in place.** One from an earlier pin outranks the
  jar in `run_java`, so a fallback that left it would report `$ENGINE_PIN` while every later
  command ran the old engine. Measured on a real 0.31.0 install, not assumed. It is removed
  (and said out loud) unless it is already at the pin.
- **It does not exit 0 on a total failure.** If both routes fail, both causes are named and
  the exit is 1 — an `✘` that scrolls past above a green `doctor` summary is exactly how a
  failed install gets read as a successful one in a script or a CI step.

The jar write also gained the `mkdir -p ~/.candor` it never had. Every jar *reader* (`run_java`,
`doctor`, the status dashboard) looks in `~/.candor`, but the only directory `update` created was
`$CANDOR_CACHE/bin` — the same place only when `CANDOR_CACHE` is unset. Measured: with `CANDOR_CACHE`
pointed elsewhere the fetch dies on `curl: (56) Failure writing output to destination`, so on those
machines the new fallback would have failed in the act of rescuing them.

`bin/candor.test.sh` gained 19 rows covering all four outcomes, network-free:
`CANDOR_JAVA_RELEASE_BASE` serves a fake release over `file://`. Two mutations confirm the
rows discriminate the behaviour rather than the seam — removing the fallback reddens only
the absent-asset and stale-binary rows, removing the `--version` proof reddens only the
unusable-asset ones.

## 2026-08-25 — ⟨0.32⟩ CUT: the floor moves to 0.32

Engines published at 0.32.0 (four rust crates on crates.io, candor-ts on npm with
provenance, GitHub releases for java/swift/agents/rust/ts and candor-spec v0.32).
The front-door pins move with them: `bin/candor` ENGINE_PIN, both adopt/ workflows,
the VS Code and JetBrains integration pins, and jbang's script-ref.

jbang's script-ref carried the tag AND the asset filename; bumping only the tag would
have pinned a URL that 404s. Both moved.

## 2026-08-25 — a night log is a dated record, not a shipped claim (released 2026-08-25 as 0.32.1)

`release-preflight.sh`'s stale-spec-string scan flagged two lines of
`NIGHT-2026-08-21.md`: the engine used that night, and the releases cut that night.
Both are TRUE and must stay true — a night log records what was measured when it was
written, and falsifying it to quiet a scan would destroy the record the file exists to be.

Marking the lines individually was the wrong unit: the file is historical by
construction, so the next night log trips the scan on its first line. `NIGHT-*.md` is
excluded as a class, at BOTH scan sites — the first attempt patched one, asserted a
single occurrence, and left the record neither marked nor excluded.

## 2026-08-25 — the identity is the PAIR, and the fix below reintroduced what it closed (released 2026-08-25 as 0.32.0)

- **⚠ THE SAME HIDE, BY THE OTHER AXIS, INTRODUCED BY THE COMMIT THAT CLOSED IT.** Yesterday's repair
  keyed `partialFingerprints.candorViolation` on the verdict row's `hash`, calling that "the answer".
  candor-ts's `hash` is `<package>#<local tail>` and ts's own commit documents it as NON-UNIQUE — 13
  collisions in one real project, five `handle` methods all keyed `src#handle`. ts's identity is the
  PAIR, `fn` + `hash`. Measured on a three-row verdict: two DISTINCT violations came out with one
  fingerprint, so GitHub shows one alert and the second never surfaces — the precise scenario the SPEC
  clause this action cites describes.

  **And the location was fabricated, not merely shared.** The `by_hash` index was last-one-wins, the one
  shape the docstring ten lines above it explains is worse than useless here, and which it had fixed for
  `by_fn` only: the first row was rendered at the SECOND unit's file. A SARIF alert pointing at the wrong
  file is a fabricated location, not a missing one.

  **The output sweep did not fire, and its blind spot is the general lesson.** It re-keys a tie only when
  the rows sit at DIFFERENT locations — sound only while those locations are the rows' OWN. Both rows
  carried the same BORROWED loc, so the sweep read two distinct findings as one finding listed twice and
  said nothing: the check that exists to catch the hide was blinded by the same defect it was checking
  for. It now also fires when tied rows SAY DIFFERENT THINGS, whatever their locations agree on.

  The fix is the pair, on both halves. The join resolves (`fn`, `hash`) first; failing that a `hash` the
  report holds exactly ONE entry for, which serves a row spelling the name differently; and a COLLIDED
  hash is WITHHELD exactly as a collided name already was, so an unmatched row gets no decoration rather
  than the last-indexed sibling's. The key is the pair too. The cost is churn — a rename re-opens an
  alert — which is the direction to be wrong in: a churned alert is visible and a hidden one is not.
  Eight rows in `test-candor-sarif.sh` (45 assertions), four of which fail against yesterday's action,
  including both over-charge controls: one finding listed twice must still collapse to one alert, and
  must still do it SILENTLY, or the new disclosure fires on every re-run and stops being read.

## 2026-08-24 — ⟨0.32⟩: the SARIF surface stops hiding one finding behind another (released 2026-08-25 as 0.32.0)

- **⚠ THE PR-NATIVE SARIF ACTION FINGERPRINTED ON THE NAME, AND SPEC §2 NAMES IT.** ⟨0.32⟩'s hash-join
  clause ends "a consumer that fingerprints on name alone (candor's own SARIF action did) silently hides
  one finding behind another" — written in the PAST TENSE for a repair that had not happened.
  `integrations/github/candor-sarif` keyed `partialFingerprints.candorViolation` on `fn|rule|effects`, so
  two units that differ only by package — or an inherent method and a trait implementation of the same
  name inside ONE report — produced the identical fingerprint and GitHub's code-scanning dedup collapsed
  them into a single alert.

  This is a silent hide DOWNSTREAM of a red gate, which is why it survived: the check still fails, the
  reviewer is shown one finding, fixes it, and the second violation is never surfaced at all. The gate
  being right does not make the surface right.

  The fix is the same join the spec requires. A verdict row's own `hash` is the identity (SUPERSEDED the
  next day — the identity is the PAIR `fn` + `hash`, because `hash` alone is not unique either; see the
  entry above, which this one's commit is what introduced); failing that,
  the report entry's `hash` when the name resolves to exactly ONE entry; failing that, the row's `loc`;
  and the one case nothing can separate — an ambiguous name with no `hash` and no `loc` anywhere — is
  DISCLOSED on stderr rather than passed off as a fingerprint. A final sweep over the OUTPUT re-keys any
  two results that still tie at different locations, because a multi-report verdict handed the report for
  one member can resolve two rows to the single entry it can see.

  **It degrades safely, deliberately, because the field it wants is not emitted everywhere yet.**
  ⟨0.32⟩ requires a verdict row to carry enough identity to tell two units apart. **All four engines emit
  `hash` on verdict rows as of ⟨0.32⟩** (pinned four-way by conformance PART 68); the degradation below is
  kept for reports produced by an OLDER engine or by hand, which §3.1 says this action must serve. Every rung above works today with no engine change, and a row
  carrying a `hash` that matches nothing in the report is not a crash and does not silently borrow a
  name-matched entry's location.

  **The same borrowing was in the decoration, not only the fingerprint.** The `fn -> loc` and
  `fn -> effects` indexes were last-one-wins, so a violation on one unit could be rendered at a SIBLING'S
  location — a fabricated location, which is worse than an absent one. An ambiguous name now resolves to
  nothing and the decoration is withheld.

  **⚠ CONSEQUENCE FOR EXISTING USERS: dismissed alerts may re-open.** GitHub tracks a code-scanning alert
  by its fingerprint, so changing the fingerprint makes every current alert look new — a dismissal or a
  "fixed" state recorded against the old key does not carry over, and a re-triage pass is expected on the
  first run after this upgrade. There is no way to change the key and keep the history; the alternative is
  keeping a key that hides real findings. Pinned by six rows in `test-candor-sarif.sh`, five of which fail
  against the previous action — including the OVER-CHARGE CONTROL, one finding listed twice, which must
  still collapse (a tool that answers "distinct" there churns every alert on every run and passes a naive
  no-collisions assertion perfectly).

- **⟨0.32⟩ UPGRADE ORDER, for anyone running `adopt/` or their own two-step pipeline: POLICY FIRST, ENGINE
  SECOND.** ⟨0.32⟩ is not additive. If your CI scans in one step and gates the report in a later step:
  FIRST, while still on 0.31, add your policy to the SCAN step (`--policy <file>` / `CANDOR_POLICY`) — the
  same policy the gate step uses; THEN bump the engine pin. Upgrading the engine first makes `gate --report`
  exit 2 over any report produced without a policy on a tree with tests, build scripts, `.d.ts` files or a
  `dist/`, INCLUDING reports archived before the upgrade, which no consumer can repair — they have to be
  re-produced with the policy. The full note, its measurement and the candor-ts one-step caveat are in
  [candor-spec's changelog](https://github.com/tombaldwin/candor-spec/blob/main/CHANGELOG.md).

  **`adopt/candor.yml` needs no change and that was checked, not assumed:** it sets `CANDOR_POLICY:
  arch.policy` on the scan step itself, so it is already a one-step-with-policy pipeline. The hazard is
  for hand-rolled workflows that archive `candor-report.json` in one job and gate it in another.

## 2026-08-20 — ⟨0.31⟩ CUT: the floor moves to 0.31

- **`ci-watch`: "no run at HEAD" cannot fire before GitHub has created the run.** There is a window of
  seconds after a push where the commit is on the remote and no run exists yet. That was reported as a
  hard failure, so `--wait` returned instead of waiting and the summary went red over a healthy push —
  hit twice in one session. Commit age is the proxy, since push time is not observable from here. Outside
  the window the old verdict stands unchanged: a workflow that genuinely never ran is exactly what the
  check exists for, and staying quiet about that would trade a false red for a false green.

- **`ci-watch`: one row per workflow, the newest.** `gh run list --commit` returns EVERY run at that sha,
  and a workflow with a concurrency group leaves superseded ones behind — a re-run, or a dispatch firing
  while another is queued, cancels the older and both come back. The cancelled one read as a hard failure,
  so the script stayed RED at that HEAD however many green runs followed, and `--wait` returned
  immediately because a red row is not waited out. Measured on candor-spec's conformance after a re-run.

  The old `sort -u` made it worse than arbitrary: it sorted rows ALPHABETICALLY, so which duplicate
  survived had nothing to do with which was current. A superseded run is not evidence about anything.
  Calibrated three ways — a newer failure still beats an older success, a cancelled run no longer masks a
  newer success, and two distinct workflows are not collapsed.

- **`probe.sh --concluded <marker>`: did it FINISH, or die before its own verdict?** A long gate prints
  rows as it goes and its verdict at the end. If it dies in the middle you see rows plus a non-zero
  exit — which is exactly what a real failure looks like. The only difference is a line that is not
  there, and an absent line is the hardest thing to notice. `release-preflight` did this for an entire
  release cycle: it aborted at its final check on an unbound variable, after every other check had
  printed, and had never once shown `OK` while its output was being quoted as a verdict.

  Non-zero WITH the marker is a real failure and the subject's exit passes through. Non-zero WITHOUT it
  exits 4 — deliberately outside the range any subject uses — and says the output is a report about the
  command, not a verdict about the thing it checks.

  Five more wrong measurements are recorded in the header, all from one night, and the pattern across
  them is sharper than any single one: **every one was caught by something downstream contradicting it,
  never by re-reading what had been run.** The list now stands at ten.

- **Corpus oracle [6]: a seeded violation in real code is REPORTED.** Every other oracle asks whether a
  report contradicts itself. None asked the question that matters most — *if a real project performed a
  denied effect, would this engine say so?* A corpus round that reports nothing is perfectly consistent
  with an engine that reports nothing.

  So a real crate is copied, one function performing a denied effect is appended, and the gate must name
  it. The control is the same tree unseeded, and it does two jobs: it catches an engine that charges
  everything, and it catches a probe matching a name that was already present. The rust arm discriminates
  on the VERDICT, not just on a name — regex under `deny Net` is exit 0 unseeded and exit 1 seeded.

  Verified across all four engines at 0.31.0 before this was written (rust into regex, ts into zod, swift
  into swift-argument-parser, java into a compiled class); rust and ts seed cheaply from trees already
  cloned, so those run every round.

- **Corpus oracle [5]: chaining a dep report may only ADD.** §2 says a consumer that chains a
  dependency's report inherits its effects, so for any function in both the plain and chained scans the
  chained effect set is a superset. A function that LOSES an effect when more information arrives is the
  cardinal sin with extra steps. Conformance pins this on fixtures; this asks it of a real dependency
  graph — regex's seven member reports chained into ripgrep move 38 of 458 shared functions.

  That count is also the oracle's own non-vacuity signal and is checked: a run where chaining changes
  nothing is REFUSED rather than passed, because it would prove the property over an empty set. Its
  loader unions across member reports instead of overwriting — found while calibrating, where stripping
  an effect from one file produced no detection because an intact copy in a later file replaced it. An
  oracle whose failure arm cannot be demonstrated is not an oracle, and this one was one `=` away from
  silently under-reporting the thing it exists to catch.

- **The corpus grows by four trees, each for a shape the set lacked.** `tokio` is a large cargo
  workspace producing ten member reports — the §3.1 ordering break ⟨0.31⟩ fixed needs one invocation
  producing SEVERAL reports for the gate route to re-merge, and ripgrep was the only tree here with that
  shape at all. `hyper` is async Net-heavy and a single-crate counterweight. `execa` exists to run
  child processes, giving the densest `Exec` surface available where every other ts entry is Net- or
  pure-shaped. `swift-nio` has many targets against alamofire's one. A corpus that stops growing stops
  finding things: the previous twelve had run clean for several rounds.

- **The VS Code extension's own version tracks its server pin.** Its gate requires `version` and
  `candorTsVersion` to agree at major.minor — an extension published as 0.30.x that bundles the 0.31
  server tells a user the wrong thing about what they installed. Bumping the pin without the version
  turned that gate red, which is the gate working.

- **The cross-repo pins move to 0.31.0, after the releases exist.** `ENGINE_PIN`, `adopt/`'s java and
  agents pins, and the vscode + jetbrains pins all name published artifacts, so they move only once those
  artifacts resolve — 0.24 shipped a jbang pin to a release that did not exist, and the string said the
  right thing the whole time. Each was resolved before being written: the jar URL returns 200, the agents
  tag exists and is not a draft, `candor-ts@0.31.0` is on npm, and all four crates list 0.31.0.

- **`release-preflight [12]` was aborting the script rather than passing it.** The check's messages wrote
  `⟨0.$MAXRUNG⟩`, and in a UTF-8 locale bash takes the `⟩` bytes as part of the variable NAME — so it
  looked up an unset `MAXRUNG⟩` and `set -u` killed the run at the last check, after everything above had
  printed and before the summary could. Every preflight this cycle returned a failure code with some ✘
  lines above it, which reads exactly like "those checks failed and the rest passed". It was not a verdict
  at all: `release-preflight: OK` had never once been printed. **A gate that dies one line before its
  conclusion is indistinguishable from a gate that concluded badly, except for a line that is not there.**
  The check had been "calibrated" against a standalone re-implementation of its own logic, which agreed
  with itself perfectly — the anti-pattern `ci-watch.sh` warns about in its own header.

The rung's two halves ship together and differ in kind, which the spec now says out loud rather than
leaving a reader to infer. `netPartners` (§2, §3.1) is **additive** — a new optional key, absent unless an
ambient `net-partner` declaration actually moved a classification. The fourth exit-2 cause (§3.3, an
UNEVALUABLE TARGET) is **not**: a target that exists and holds no file the engine can read was a clean
pass on one engine and is a refusal on all four, so a green that came from a typo'd CI path becomes an
exit 2. That is the direction the change exists to fix, and it is still a verdict that moves — an upgrade
is a decision, not a drop-in.

`UMBRELLA_VERSION` moves to 0.31.0 with the engines. `ENGINE_PIN`, `adopt/`, jbang and the editor
extension pins move AFTER the releases exist, because they name download URLs that do not yet.

## 2026-08-20 — the release ladder, made faster by measuring it

- **The corpus round runs on a schedule now, and refuses a partial one.** `bin/corpus.sh` has found
  defects no other gate could and ran in no workflow at all — it was something someone remembered to
  type. The most recent was a §3.1 route-equality break on ripgrep, which nothing else could see:
  `gate-equivalence` runs over candor's own crates and conformance's fixtures are single-package, so it
  took a cargo workspace nobody wrote for us. Weekly on macOS, because ubuntu has no swift toolchain and
  a three-engine run printed the same summary as a four-engine one — ⟨0.26⟩'s partial manifest, worse
  than an absent one because the reader cannot tell. The roster is printed every run and
  `CORPUS_REQUIRE_ALL=1` turns an absence into a refusal rather than trusting it to be read. A MONITOR,
  not a gate: it does not run on push and cannot block anything, because a corpus finding is a candidate
  cardinal sin someone traces to ground truth, and one has been wrong before.

  **Its first run failed, in the check itself, which is the argument for dispatching rather than trusting
  a schedule.** The roster looked for `scan.mjs` on disk, found it, and reported `present: rust java ts
  swift` — while every ts scan returned rc=1, because nothing had installed the TypeScript compiler the
  engine imports. `CORPUS_REQUIRE_ALL=1` certified full coverage over an engine that could not run one
  target: the exact false assurance the flag exists to prevent, produced by the flag. Each engine is
  ASKED `--version` now — the cheapest question that exercises the real entry point, since it parses
  args, loads every module and answers — and the dependency install lives in the script rather than the
  workflow, the way `conformance/run.sh` does it, so CI, a fresh clone and a human all work. Verified
  green end to end: four engines, 43 reports, all four oracles.

- **`ci-watch`: a failure on an earlier commit is no longer erased by a quiet one on top.** Every check
  in it asked only about HEAD, so a workflow that failed on commit N went invisible the moment a commit
  N+1 landed that its path filter ignores — HEAD legitimately needs no run, the repo prints "no run
  expected ✔", and the red leaves the summary while still being the newest thing that workflow has to
  say. Noticed on a GREEN run: candor's row read "no run expected" directly after a push that did change
  `bin/`, because HEAD was a CHANGELOG-only commit on top of it. That run had passed; nothing would have
  said so if it had not. The newest run of each workflow on main is now checked too, reported only when
  it is not at HEAD so no run gets two verdicts. It also surfaces SCHEDULED workflows, whose failures
  this could never see before — they only ever run on older commits. Calibrated with a `stale-red` fault
  hook, alongside the existing `drop-row`.

- **`wf-expected`: `paths-ignore` was read as a malformed `paths`, making candor-spec a standing false
  red.** The key lookup used `startswith`, so `paths-ignore` matched `paths`, choked on the leftover
  `-ignore`, and marked the workflow unparseable — which fails closed to "required" and reported NO RUN
  AT HEAD on every push, with a real green run sitting beside it. Keys match exactly now, longest first,
  and `paths-ignore` is understood on its own terms: the inverse of `paths`, so a run is skipped only
  when every changed file matches and one unmatched file still demands it.
- **`changelog-lag`: exactly one `## Unreleased` per file.** `release-stage.sh` renames the first, so a
  file holding more ships work still labelled unreleased. candor-rust had three, candor-java and
  candor-swift two each; nothing was checking, and all three would have been cut that way. Scoped to the
  region above the first released version, because flagging settled history is how a check stops being
  read.

- **`release-preflight [12]`: a cut is refused while `SPEC.md` describes a rung above its own version.**
  ⟨0.31⟩ was built four-way and held because one half is non-additive — candor-rust's unevaluable-target
  refusal turns an exit 0 into an exit 2. A routine rust publish would have shipped that flip under a
  floor whose §3.3 enumerates three exit-2 causes, and nothing here would have objected: conformance
  green, CI green, changelogs staged. Every check was asking whether the tree is internally consistent;
  none asked whether it has outgrown the version it declares. Every clause carries a rung marker, so the
  highest marker above the declared `Version` is exactly that condition. It takes no version argument and
  so fires in health mode too — the hold was being carried by a paragraph in `BACKLOG.md`.
- **`ci-watch`: PENDING is its own verdict, and `--wait` polls for the answer.** An in-progress run set
  the failure code, so a healthy four-second-old run printed the same summary as a failure and every use
  against a fresh push meant re-running by hand. Pending is counted separately now and exits 2, so
  `ci-watch || fail` still fails while a caller can tell "not yet answered" from "answered badly". A
  STALLED run stays red, or `--wait` would sit out its own deadline instead of firing the alarm it exists
  for. `--wait` re-execs the snapshot so the waiting and snapshot paths cannot drift, and on expiry it
  prints the snapshot and exits 2: the deadline bounds how long it waits, never what it concludes.

The 0.30.0 cut took **30 minutes wall-clock** (00:42 → 01:12). Two items were 23 of them, and neither
was doing any work that had not already been done.

- **`release-preflight [11]`: the pin bump paid for the whole four-way suite — 11 minutes.** Step 6
  rewrites `integrations/vscode/package.json`, `integrations/jetbrains/gradle.properties` and sometimes
  the release scripts themselves; none were on the conformance-reuse licence, so re-entering `release.sh`
  for step 7 ran the entire suite again. The suite reads none of them — its only `integrations/`
  references are prose about a doc, and it never invokes anything in `bin/`. Now licensed, named
  explicitly rather than licensing `^bin/` or `^integrations/` wholesale, because an unlisted path only
  ever costs a wasted run: the short list is the conservative one. `^conformance/` still overrides every
  licence.
- **CI workflow files were suite input to the licence, and are not.** The suite runs local binaries
  against local fixtures and reads nothing under `.github/` (zero references in run.sh or any generator).
  Whether CI is healthy is `[10]`'s question, asked against the live API. Left unlicensed, a workflow
  edit in any of seven repos bought a full four-way run — the publish-workflow fix below did exactly
  that, ten minutes, while the fix was being measured.
- **candor-ts's `publish.yml` re-ran the full battery over bytes ci.yml had just tested — 12 minutes**,
  on the critical path, since the pin bump waits for npm. Now skipped when a successful ci.yml run exists
  for the same SHA, and run in every other case. (See candor-ts's changelog.)

Together these should take the next cut from ~30 minutes to under 10.

## 2026-08-20 — ⟨0.30⟩ RELEASED; the cross-repo pins move to 0.30.0

- **The floor is 0.30, build 0.30.0.** Four crates on crates.io, `candor-ts@0.30.0` on npm with OIDC
  provenance, GitHub releases across all six engine repos, and the spec at `v0.30`.
- **ENGINE_PIN 0.29.1 → 0.30.0**, with it `adopt/candor.yml`, `adopt/candor-digest.yml`, the VS Code and
  JetBrains plugin pins and candor-java's jbang catalog. They move only AFTER the artifacts exist —
  preflight `[3]` gates that ordering, and it is the check that caught the pin lagging at 0.18.0 through
  0.23.1, shipping 0.18 engines under a 0.23 umbrella.
- **`release.sh`'s npm wait was 10 minutes against a publish that takes 10-15.** `publish.yml` runs the
  full battery before publishing; its last four successful runs took 11, 11, 10 and 15 minutes, so the
  budget lost that race most times and reported a healthy cut as a failure — measured on this one, which
  published normally in 12m. Now 25 minutes. A wait must be sized to the work it waits on.

## 2026-08-19 — ⟨0.30⟩ built four-way, and a review panel found seven blockers in it

- **UMBRELLA_VERSION → 0.30.0** (the brew formula / `--version` row). `ENGINE_PIN` deliberately stays at
  0.29.1: it names a PUBLISHED release line and moves only once 0.30.0 artifacts exist — preflight [3]
  gates that ordering, and it is the check that caught the pin lagging at 0.18.0 through 0.23.1.

- **…and its first real firing was wrong in the other direction.** With the parse repaired, the alarm
  immediately called candor's `shell-lint` STALLED at 55s. Its median is 18s (measured: 16 16 16 17 17 17
  18 18 22 62 77 100), so `3x median` is 54s — a normal run trips it before the runner has finished
  installing shellcheck. A multiplier alone cannot express *stuck* for a job whose whole life is shorter
  than its own startup variance, so the threshold is now `factor x median` **or** `STALL_FLOOR` (300s),
  whichever is larger. The cases this exists for are untouched: the real 3h45m hang against a 10m median
  clears 30m by 7×, and the same short job genuinely stuck at 400s is still caught. Both rows are in
  `--selftest`. Sub-minute durations now print as seconds — `0m elapsed against a 0m median` is what made
  the false alarm read as nonsense rather than as the short-job case it was.

- **The first STALLED the alarm ever reported was real, and it was ours.** `shell-lint` sat 30 minutes
  in `apt-get install shellcheck` — on a job whose successful runs take 16-22 seconds — and the
  `timeout-minutes` added hours earlier killed it, which is the deadline working and also half an hour
  spent learning that. `ubuntu-latest` already ships shellcheck, so the install is now a fallback rather
  than the normal route, the job's deadline is 10 minutes instead of 30, and every remaining network
  install across candor-rust and candor-swift carries a 5-minute **step** deadline: a job-level clock
  bounds a hang at the job's whole budget, and the fetch is the part that hangs.

- **`bin/wf-expected.py` — and the third thing wrong with `ci-watch.sh`: it printed OK over a row that
  said "verify before trusting".** For a docs-only commit the umbrella repo has no run at HEAD, and the
  script said so and then declared the fleet green. The row was honest about not knowing; the verdict was
  not — a fail-open in the one script whose thesis is that a summary must never be greener than its rows.
  The two readings behind those words are "this commit matched no path filter", which is fine, and "a
  workflow that should have run did not", which blocks a release. Neither needs GitHub to answer: the
  workflow files declare their own triggers. This reads them against the commit's changed files and says
  which runs are REQUIRED; `ci-watch.sh` now reds on a required-and-absent run — including the subtler
  case where *other* rows are present, which is the shape that once let a green `realworld-oracle` stand
  in for a red `ci`. Its first two answers were false reds (`publish.yml` and `release.yml`, both
  `on: push: tags`, read as "every push"), so tag and branch filters are handled and both shapes are
  selftest rows. 11 rows, one shared classifier — the selftest had started out re-implementing the
  cascade it was meant to check, which is the mistake being fixed one entry above. `CI_WATCH_FAULT=drop-row`
  drops a real row and the arm goes red, so the alarm has been seen to fire.

- **`ci-watch.sh`'s stall alarm was dead on arrival, and its own selftest could not see it.** Minutes
  after the script landed, a live run showed `0m elapsed` against a run that had started eight minutes
  earlier. `read` collapses consecutive IFS *whitespace* delimiters and tab is whitespace; an
  `in_progress` run carries `conclusion: ""`, which jq's `//` does not replace, so the row arrived with
  two adjacent tabs, they collapsed, `createdAt` fell out of the row, the unparseable date hit a
  `|| echo "$now"` fallback, and elapsed was **0 for every run, always**. The STALLED branch was
  unreachable, and nothing about the output looked wrong. The selftest passed throughout because it
  called `is_stalled()` directly — a copy of the instrument rather than the instrument. Fixed on both
  halves (a unit separator that cannot collapse, and a conclusion never emitted empty), the fallback now
  reports an unreadable start time instead of implying health, and the selftest drives the parse and the
  jq emission. The new arm was run against the old format and fails there.

- **verify-local runs the engines concurrently, and asks changelog-lag before the push.** Measured per
  step: candor-ts `node test.mjs` 298s against 30s/29s/25s/3s for cargo test, gradle, swift and clippy —
  sequential, 77% of the wall clock was one step with four idle engines behind it. Now 306s instead of
  385s, bounded by the slowest engine rather than their sum. And `changelog-lag` (release-preflight
  `[5b]`, ~1 second) is asked here rather than only at preflight: it first spoke tonight *after* CI had
  gone green on six repos, so one missing paragraph cost another commit and another ~19-minute round.

- **…and its ts arm invented a contract, then died on it.** Its first real run reported
  `bin failed: ./verify.mjs`. That bin is present, loads, and works — it takes verbs, so `--version`
  prints a usage error and exits 2. The check had demanded a flag the code never promised, and a red
  nobody can act on is how a real red later gets waved through. The defect this arm exists for is a file
  omitted from `files`, which surfaces as `ERR_MODULE_NOT_FOUND` at startup, so that is what it looks
  for now, on any exit code — verified by hiding `scratch.mjs` in the packed tarball and watching it
  fire. Second bug in the same six lines: `out=$(node …)` under `set -e` killed the step outright,
  because a non-zero exit is data here rather than a failure.

- **verify-local now runs BOTH of candor-rust's clippy legs — it had been running one.** candor-rust pins
  `nightly-2026-06-14` in `rust-toolchain`, so a bare `cargo clippy` runs that nightly, while CI runs the
  pinned nightly over the workspace AND `cargo +stable clippy` over the four stable crates. Different lint
  sets, and the pinned nightly is the OLDER of the two (0.1.98 June vs stable 1.97.1 July). Running only
  the nightly leg passed twice on code CI's stable leg rejected — `unnecessary_map_or`, then
  `collapsible_if` + `manual_contains` — costing a CI round each time.

  **The first diagnosis, written here as fact, was wrong.** I recorded it as a toolchain-AGE gap the
  script could not close by construction. `rustup update stable` answered *"unchanged"*, which ruled that
  out and exposed a MISSING COMMAND — exactly the gap this script exists to close. Calibrated: with the
  rejected shape restored, `clippy (+stable)` fails and `clippy (nightly)` passes.

- **`bin/verify-local.sh` — run what CI runs, before pushing.** `cargo test --workspace` passed twice on
  candor-rust while `cargo clippy --all-targets -- -D warnings` — which is what CI actually runs — failed,
  once on a duplicated `#[allow]` and once on a doc comment left on a `thread_local!`. Both times "the
  suite is green" was true and useless, and the second happened after the first because the lesson lived
  in my head rather than in a command. Each engine's real gate is a different command per language, kept
  in that repo's workflow, and nothing local ran the union; this does. It mirrors CI exactly and does not
  exceed it — no `cargo fmt --check`, because a local gate stricter than CI trains you to ignore it. The
  ts arm executes every declared bin out of a real `npm pack` tarball, which is the only thing that sees
  what a consumer receives.

- **release-preflight [7c] — no commit message in the release range shows shell-substitution damage.**
  Backticks inside a double-quoted commit message are live command substitution; four commit messages
  today were written with build or test output spliced into them where filenames should have been. The
  fix is `git commit -F -` with a quoted heredoc, and this is the check that says when it was not used.
  Narrowed after a false positive on a message that correctly *describes* an earlier corruption.

- **A standing internal-consistency oracle, `bin/selfconsistent.py`.** Every other oracle compares a
  report against something else — another engine, another run, the runtime. This one needs no ground
  truth, so it runs over every report on disk: a `hosts`/`cmds`/`paths`/`tables` literal without its
  effect, `unknownWhy` without Unknown, `direct` ⊄ `inferred`, `analyzed.count` smaller than the
  functions reported from it. `--selftest` builds a report violating each rule and asserts it fires
  (7/7), because a clean sweep from an uncalibrated instrument is the cardinal sin wearing an oracle's
  hat. Swept 2,142 reports across all four engines: zero engine-produced violations.

- **BACKLOG: the green-gate-over-unread-code item is now measured rather than filed.** `deny Net` over
  `axios` exits 0 while the peek names 37 functions it has concluded perform Net; the advised remedy
  (`add deny Net Unknown`) works on axios and node-fetch and FAILS on execa, whose report has zero
  functions — a policy ranges over the analyzed set, so an empty set satisfies every policy vacuously.
  Of 85 packages drawn, 38 have code and 7 sit in that shape, every one effect-purposed. Rust is clean
  here (it scopes to the file tree, not a build-derived program), which is what narrowed the fix.

- **⟨0.30⟩ is built in all four engines and conformance-pinned, and NOT released.** See candor-spec's
  changelog for the rung. A four-lens adversarial review then found seven blockers in it — including a
  `pure` policy silently disarming the rung four-way, an unreadable multi-release override claiming to
  have been read, and the advisory verbs still certifying what the gate now refuses — all fixed, each
  pinned by a conformance arm that was falsified before it was trusted.

## 2026-08-18 — ⟨0.29⟩ / 0.29.1 PUBLISHED, and the npm wait earned itself on its first run

- **Pins → 0.29.1**, after the artifacts they name existed: `ENGINE_PIN`, `adopt/`'s java and agents
  pins, the vscode/jetbrains `candorTsVersion`/`candorJavaVersion`, and candor-java's jbang
  `script-ref`. The jar URL was RESOLVED first (HTTP 200, 1142085 bytes, byte-matching the release
  asset) — a pin naming a URL is not the URL existing.
- **The step-6 npm wait STOPPED the release, correctly.** Added this morning after 0.29.0's pin bump
  raced npm propagation and produced two CI failure emails, it refused to hand over the pin-bump step
  until `candor-ts@0.29.1` was resolvable — and it fired, because `publish.yml` runs the full test
  battery ("a broken build must not reach npm") before publishing, which outlasts the 10-minute budget.
  **The guard was right and its timeout is wrong**: it treated a slow-but-healthy publish as a failure.
  Worth raising to ~20 minutes, or better, keying the wait on the `publish` workflow's own completion
  rather than a fixed clock.

## 2026-08-18 — 0.29.1 staged (a WITHIN-SPEC patch)

- **Build versions → 0.29.1 across the family; the FLOOR stays 0.29.** `SPEC.md` is byte-identical since
  `v0.29`, so nothing in this cut moves a contract — every fix restores conformance to a clause that
  already existed (§3.1 route equality, the propagation invariant, §1's `Env`, the could-not-form-a-key
  rule). `release-stage.sh` deliberately leaves the spec DECLARATIONS alone.
- **candor-swift and candor-agents ship hand-written 0.29.1 sections.** An EMPTY `## Unreleased` is left
  alone by the stager, and `release.sh` then falls through to "the newest non-empty section" — which
  would have published two v0.29.1 releases whose notes describe 0.29.0. Caught by a pre-release
  reviewer; no gate in the ladder catches it today, which is worth fixing in the machinery.

## 2026-08-18 — the Stop hook stops paying for turns that changed nothing

**REVIEWED, and the guard was not safe as first shipped.** A Fable reviewer constructed six wrong-skip
scenarios and reproduced five — two of them categorical, needing no exotic filesystem, just a documented
configuration. All five are closed and pinned by rows; none was covered by the guard's original rows,
which only ever tested an mtime-advancing edit with the tree env var set.

- **The analysed tree was not watched when it was not NAMED.** `candor-review-source.sh` defaults its
  scan root to `.` and the README documents that, so a legal wiring left the guard watching nothing the
  engine reads — and it never self-corrected, because no watched input ever moved again: a PERMANENT
  silent miss, not a one-turn one. The guard now refuses to skip unless `CANDOR_CLASSES`/`CANDOR_SRC`
  names the tree. (The JVM path was protected only by accident: `candor-review.sh` hard-requires
  `CANDOR_CLASSES` and exits 2, which never stamps.)
- **A policy reached through `.candor/config` was invisible** — the checked-in wiring SPEC §3.4
  recommends, in which `CANDOR_POLICY` is never set. Both the config and the policy it names are inputs now.
- **A same-size, same-mtime content change was invisible**: the signature was file-count + `du -sk`, and
  KB rounding hid a rewrite. Not exotic — Gradle's build cache restores outputs with NORMALIZED CONSTANT
  timestamps by design, and `rsync -a` preserves them. Now a CRC over the bytes (tens of ms against a
  3.3s scan).
- **A future-dated stamp disabled the `-newer` test permanently**, so a clock stepping back (NTP, a VM
  resume, an NFS server whose clock leads) silently switched the guard off. A stamp dated after now is refused.
- **`candor update` swapping the jar under an unchanged `CANDOR_CMD` string** changed nothing watched.
  Engine files named in the command are inputs now.

- **The turn boundary was wrong for a human message with ARRAY content** (a pasted image), which is not
  a tool_result and IS a turn boundary. The boundary fell back to the previous turn and reported its
  edits as this turn's — confidently, because an older string message kept `found=true` and suppressed
  the full-file fallback. The test is now "a user entry carrying no tool_result block". And with no
  boundary anywhere the answer is `null` ("couldn't determine"), not every edit in the session.


From a uflexi field report (2,259 classes / 15MB of bytecode, a 4.9MB baseline): the Stop hook fires at
the END OF EVERY TURN, including turns that only write a reply, and cost ~3.5s each — of which **3.30s is
the scan**. Not JVM startup (0.10s), not jq (0.10s). Over a long session that is the difference between a
feedback loop you keep and one you turn off.

- **`stop-hook.sh` skips the scan when nothing the verdict depends on has moved** — the analysed tree, the
  policy, the baseline, the engine command, the review script. If none changed since the last run that
  PASSED, the verdict cannot have changed either. The stamp is written ONLY on rc=0, so a failing gate
  keeps failing every turn until it is dealt with; that is the property that makes the guard safe to leave
  on. Any uncertainty — no stamp, a changed signature, an input that moved — RUNS, because a wrong skip is
  a silent miss. `CANDOR_HOOK_SKIP=0` turns it off. **Both traps the reporter hit are avoided and written
  into the header**: it does not key on `git status --porcelain` (which prints status letters and paths,
  never CONTENT, so re-editing an already-dirty file leaves the signature identical and the gate silently
  never re-runs), and it compares against the STAMP FILE rather than the classes DIRECTORY (whose mtime
  only moves when an entry is added or removed, making `find -newer <dir>` true essentially always).
  Nine rows in `test-stop-hook.sh` lock the safety chain: block → no stamp → keeps re-running → stamps
  only after a turn actually passes.

- **The transcript scan is bounded.** `log_activity` slurped the WHOLE transcript to find the last human
  message — O(session), growing all day, on a hook that runs every turn. It now reads a tail window
  (`CANDOR_HOOK_TRANSCRIPT_TAIL`, default 2000 lines) and falls back to the full file when the window did
  not contain the turn boundary. The fallback is not optional: measured on a 3,000-edit turn the window
  alone reported 2,000 files instead of 3,000 — a wrong boundary, silently. On a 15MB transcript:
  **170ms → 26ms**, and now constant with session length.

- **The stdin contract is documented.** The script already read stdin once, first, into `$input` — that
  part was confirmed rather than changed. What was missing is the warning for WRAPPER authors: stdin is a
  stream, so anything a wrapper runs before the hook (a `./gradlew` call, in the report) drains it, and
  the hook then sees no session id and no transcript. The header now says so and gives the fix.

## 2026-08-18 — the corpus round that found a cardinal-sin-class defect in the REFERENCE engine

- **`bin/monotone.sh` — the MONOTONICITY oracle: resolving more must never certify more.** Scan a TS
  package with `node_modules` absent, install its dependencies, scan again, and compare FUNCTION BY
  FUNCTION. `Unknown → a concrete effect` is refinement; `Unknown → nothing`, or a function vanishing
  from the report, is a candidate silent certification. It exists because candor-ts's shadow guard
  treated `import { fetch } from "node-fetch-native/proxy"` as the project's own `fetch` and withheld
  Net — but ONLY in the better-informed run: with the package absent the same call honestly read
  `Unknown`. A per-package effect count cannot see that; the comparison is what makes it visible.

  **Its header carries the one thing that must not be optimised away.** Most false positives carry
  `unknownWhy: no-node_modules:<pkg>` (globby resolving tsd's `expectType`, consola resolving
  `string-width` — both genuinely pure), so skipping that marker is the obvious noise reduction. The
  `fetch` cardinal sin carried THE SAME MARKER. Signal and noise are indistinguishable by that field:
  the instrument narrows thousands of functions to a handful, and a person traces each. Three of its
  first four hits were true negatives; the fourth was `require.resolve` reading the filesystem.

- **sqlite-jdbc is pinned into the standing corpus, and it is the only jar there that reaches the
  filter.** candor-java's report writer admitted a method for effects / entry-point / blindness / a
  declaring class, and NOT for being disclosed-incomplete — so a method whose only signal was
  uncertainty was omitted, and omission means PURE. Two callers in sqlite-jdbc read CERTAIN off callees
  disclosed `incomplete: [Db]`. Fixed in candor-java; gated here, where TWO oracles catch it
  independently: the honesty invariant, and oracle [2] (java 1708/1710 propagated against the published
  jar, 1713/1713 with the fix). Calibrated both ways before being trusted.

- **Rounds that found nothing, recorded because a negative result is only useful if it is written
  down.** Re-scan determinism: 28 reports byte-identical across all four engines. Purpose oracle over
  two fresh draws (reqwest, rusqlite, walkdir, sled, tempfile, notify, ureq, csv, tar-rs, swift-nio,
  swift-crypto, unstorage, okhttp, commons-io, hikaricp, httpclient, jsoup, commons-compress): every
  library reports the effect it exists to perform. §3.1 route equality byte-equal on ten third-party
  trees. `hyper` reporting zero `Net` is CORRECT — hyper 1.x contains no socket calls, the transport is
  the caller's, and the engine described the code rather than the package name.

## 2026-08-17 — staging ⟨0.29⟩ / 0.29.0, and the evidence path a test wrote over

- **`corpus.sh` gains oracle [4]: §3.1 ROUTE EQUALITY on code we did not write.** `ci/gate-equivalence.sh`
  asserts this already — over candor's OWN four crates, which is as far as its fixtures reach, and which
  is exactly where the ⟨0.29⟩ peek defect lived. Third-party trees have the shape candor's crates mostly
  lack: real exclusions, and MULTIPLE PACKAGES each writing their own report (rusqlite ships a `-sys`
  crate, walkdir a bin beside the lib). Cheap, because the projects are already cloned. CALIBRATED
  against the real defect by reverting the peek guard and re-running: all four projects diverge, and far
  louder than the in-repo fixture did — clap reports `count 3093` against its own report's `1519`, a 2×
  over-claim, where candor-query showed 276 against 129. Its vacuity guard keys on ATTEMPTS, not
  successes: keyed on successes it fired a fifth, FALSE "nothing was compared" finding beside four real
  ones, because every comparison failing looked identical to no comparison happening.

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
