# Changelog — candor (umbrella)

This is the umbrella repo: the **adoption and integration surface** over the engines — the drop-in CI
workflows (`adopt/`), the IDE and agent-loop clients (`integrations/`: GitHub Action, Claude Code hook,
VS Code and JetBrains LSP clients), the effects-fingerprint (`fingerprint/`), and the family docs
(`BACKLOG.md`, `TESTING.md`, the case studies). It is **not a versioned release artifact** — it pins the
engine versions it targets, so this changelog is **dated**, most recent first. Engine contract history lives
in [candor-spec's changelog](https://github.com/tombaldwin/candor-spec/blob/main/CHANGELOG.md); each engine
keeps its own.

## 2026-08-07 — two 0.28 rungs recorded, from measurement rather than design (unreleased)

- **BACKLOG P1: the stale-document rule binds the REPORT, not just the verdict.** A scan that exits 2
  leaves the previous `report.json` byte-identical, and a downstream `gate --report` then goes green over
  a report the failed run never produced. SPEC §3.3.1 ⟨0.24⟩ already says this and no engine implements
  it — the ⟨0.27⟩ arming work closed the hole for the verdict and left the report channel open, one step
  upstream of the gate it had just made fail-closed.
- **BACKLOG P1: a zero-rule policy reads as a clean gate in the machine channel.** `--policy <a README>`
  writes `{"ok": true, "violations": []}` and exits 0 in all four engines — byte-identical to a gate that
  ran and found nothing. The human channel warns per line; the artifact a CI wrapper reads says nothing.
  PART 32's "a rule that binds nothing is disclosed" ruling, one level up.

Both are recorded rather than built: each needs a wire-format field, so each wants a version and a
conformance part rather than four independent additions — and ⟨0.26⟩ already measured that a PARTIAL
artifact can answer worse than an absent one.

- **docs: the privacy-manifest quickstart now says how to pick the right `Info.plist`.** Following the
  page's own instructions on a multi-target repo picked a ShareExtension's plist and printed four
  "missing key" findings that were pure artefact — a reader could reach that state and conclude the tool
  is wrong.

## 2026-08-06 — both 0.27 rungs land four-way, and the backlog catches up (unreleased)

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

## 2026-08-05 — the umbrella becomes usable from nothing (unreleased)

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

## 2026-08-05 — spec 0.27: a producer declares which refinements it computes (released 2026-08-05 as 0.27.0)

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
