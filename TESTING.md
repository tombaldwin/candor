# TESTING.md — the candor family's test standards

The family-wide rules for how the candor repos (candor-spec, candor-java, candor-rust, candor-ts,
candor-swift, candor-agents, and this umbrella) are tested. The audience is whoever maintains these
repos — today that is mostly AI agents working in waves — so every rule here is **normative and
checkable**, and every one exists because its absence already cost us something (the incident is
named where it helps).

The one-sentence philosophy: **the exit code is the product.** candor is a gate; its correctness
claims are behavioral contracts (exit codes, disclosures, report bytes), and the test suite's job is
to make every contract's regression un-shippable — not to maximize a coverage number.

## 1. Two layers, and what each owns

- **The unit layer** owns pure logic: parsers, scope/literal matchers, classifier table lookups, set
  algebra, SQL/table extraction, name laddering. Direct, in-process, fast. If a piece of pure logic
  can only be tested by spawning the binary, that is a smell — **extract it** (the candor-swift §6.2
  helpers lived spawn-only inside main.swift for months; their CRLF/NBSP subtleties got direct pins
  only after moving to CandorCore).
- **The process layer** owns every user-facing contract: exit codes, stderr disclosures (the κ
  ledger, warnings, fail-closed diagnostics), report/verdict/sidecar bytes, env/config/flag
  handling. Tested by spawning the real binary the user runs, asserting on exit codes and output.
- Neither layer substitutes for the other. New behavior lands with tests **at the layer that owns
  it**; a user-facing contract needs a process test even when its logic is unit-covered.

## 2. The non-negotiable pins

1. **Every documented CLI mode, flag, and env var has at least one behavioral test in the repo's own
   CI.** (candor-java's `checkConformance` — the CANDOR_STRICT gate, three spec-numbered diagnostics
   — shipped for months with zero coverage in any harness. A documented mode with no test is a
   regression waiting to ship silently.)
2. **Every fail-closed path has a negative test** asserting exit 2 and the one-line diagnostic:
   unreadable/missing policy, config, baseline, deps token, unwritable report/verdict path,
   configured-but-empty values. Fail-closed code that is never exercised fails open in practice —
   the 2026-07-09 review found seven such paths across five repos.
3. **Every classifier/κ rule ships with an anti-fabrication twin**: the lookalike (a project type or
   function shadowing the modeled name) must stay pure. Where the rule is a member/verb table, add a
   table-driven positive test so a typo un-classifies loudly (the swift CoreData/NWConnection rows
   were validated once by a corpus sweep and then pinned by nothing).
4. **Every disclosure has an emission-path test.** A disclosure computed but dropped at emission is
   a cardinal sin the computation's tests cannot catch (the deep-engine report writer erased
   `invisible`-carrying pure fns for weeks; the realworld oracle caught it, unit tests never would).
5. **Exit-code contracts are pinned per gate surface**: violation → 1, could-not-evaluate /
   unusable input → 2, clean → 0. The distinction between 1 and 2 is load-bearing (a CI consumer
   treats them differently); tests must assert the exact code, never just "nonzero".

## 3. Cross-engine behavior

- **Engine-local behavior is pinned in-repo; cross-engine *agreement* is pinned in conformance.**
  Never rely on the candor-spec conformance suite as the only coverage for an engine's own behavior:
  an engine-local regression stays green in its own CI until the spec repo's CI happens to run
  (the blindspots/frontier/rewire CLI arms lived in exactly this state).
- **A verdict-affecting change to a spec-numbered behavior is one wave, three artifacts**: the ruling
  recorded in SPEC/SEMANTICS, the implementation in every engine that claims the surface, and a
  conformance row pinning the agreement. Shipping any one without the others reopens the
  written-contract-vs-machine-checked-contract gap (the AS-EFF-008 opaque-case contradiction lived
  for a month because the hardening never flowed back into the text).
- **A bug found in one engine triggers a sweep of the others for the same class before the fix
  ships.** The dangerous case is the shared blind spot cross-engine agreement hides (write-fmt was
  silent in four engines; pure-vs-Unknown was wrong in three).

## 4. Refactors

- **Structural refactors are byte-identity-gated.** Before: capture reports + callgraph/hierarchy
  sidecars + gate verdicts + exit codes over the repo's corpus (minimum: the conformance fixtures +
  the repo's own fixtures; use the big corpora where they exist — candor-java's soundness/lib 330
  jars). After: diff. Identical, or the refactor stops — a refactor that cannot hold byte-identity
  is a behavior change and must say so. (The classify() split was proven with a 19.5M-triple
  differential oracle; the analyze() split over 996 corpus files; the scan/query splits over
  command batteries. This is the standard, not the exception.)
- **Behavior changes never ride refactor commits.** Separate commits, loudly labeled, with a
  baseline-invalidating note when report bytes change (engine upgrades invalidate baselines — the
  fail-closed guard makes a silent report change a broken adopter).

## 5. Suite hygiene

- **Name tests by feature, never by review round or date.** Provenance goes in a docstring
  ("originally review round 12"), not the class name — `Round12FixesTest` made "which test pins the
  Exec cliff?" an archaeology task. (Applied retroactively too: candor-java's `KappaBatchNN` suites
  are being renamed to feature names under this rule.)
- **One shared fixture/compile helper per repo** (candor-java's `TestCompiler` replaced ~15 verbatim
  copies); temp dirs via the framework (`@TempDir` / `mktemp` under trap), never `deleteOnExit`.
- **Hermetic**: no network (vendor stub packages like the fake `node_modules/dep-pkg`); no
  dependence on directory-listing order (the swift fabrication probe flaked for a week on
  `os.listdir` order picking up the hierarchy sidecar), wall-clock, or pipe buffering (line-buffer
  or TTY-wrap spawned output — `swift test` block-buffers on CI; a hung run's log shows nothing).
- **Loud skips, or failure — never silence.** An absent optional engine/tool skips with a printed
  reason; a present-but-broken one FAILS; a missing script FAILS (four generative differentials
  could once be deleted by a rename without a single red line). A suite that shrank silently reads
  as "covered" — the worst state.
- Every suite prints a final pass/fail count; CI gates on exit codes, not output scraping.

## 6. Coverage policy

- **No blanket percentage gate, and 100% is explicitly not the goal.** The last ~10 points are
  defensive error exits, platform-only paths (the native-image supertype loader is untestable on a
  JVM by construction — the native==jar parity gate owns it), and deliberately-unreachable
  conservative arms; covering them means mock-heavy tests that pin implementation, not contract.
  And line coverage cannot touch this project's real failure mode — a *missing* classifier rule has
  no lines to cover; the probes and corpus rounds own that. Since the maintainers are agents, a
  percentage target would also invite exactly the padding it cannot detect.
- **The standard is 100% *accounted-for*.** Every uncovered line is one of three things:
  **contract** (a documented behavior — must gain coverage, no exceptions; the zero-coverage gate
  list must be empty), **defensive/platform** (kept uncovered deliberately — say why when a
  measurement flags it), or **dead** (delete it). When coverage is measured, uncovered lines get
  triaged into those bins; bin one empty is the invariant CI-adjacent reviews hold.
  The zero-coverage-gate list lives as a section in each measurement's SOUNDNESS-LOG entry.
  The triage record lives in the measuring commit's message.
- **When measuring, instrument the children.** The process suites carry 20–30 points of real
  coverage (java 67%→90%, swift 61%→88%, candor-query 32%→67%); a unit-only number must be labeled
  as such. Mechanisms that work here: `NODE_V8_COVERAGE` (inherited by spawnSync children),
  `COVERAGE_PROCESS_START` + a .pth hook, `LLVM_PROFILE_FILE`, the JaCoCo agent via
  `CANDOR_JAVA_OPTS`.
- **Tests shut children down gracefully so coverage flushes**: end stdin and let the process exit;
  a SIGKILL discards the child's coverage (test-lsp's `srv.kill()` made lsp.mjs read 0% while
  actually at 96%).
- **Dead code that coverage reveals is deleted, not tested.**
- Re-measure after structural waves, not continuously — coverage is an instrument we read
  occasionally, the gate list is what CI holds.

## 7. Probes are gates, and probes rot

- Mutation, fabrication, fuzz, and oracle probes run **in CI** — scheduled (weekly) where they are
  too heavy for per-push. A probe that runs only when someone remembers rots invisibly
  (candor-java's mutation probe had decayed to 3/14 caught; the swift fabrication probe was
  broken-flaky for the same reason — neither was in CI).
- **A probe is itself a κ surface**: its anchors name specific code. Re-run and re-anchor after any
  refactor that moves rule text; a probe passing against code it no longer targets is a green lie.

## 8. Bug fixes carry their regression test

- **Every bug fix ships with a test that demonstrably failed before the fix and passes after — in
  the same commit.** "Demonstrably" means it was run against the pre-fix code (trivial in the fix
  workflow: write the pin first, watch it fail, fix, watch it pass), not assumed.
- **The test lives at the layer that owns the broken contract.** A fail-open gets a process-level
  exit-code test; a matcher bug gets a unit pin; a wrong report byte gets a fixture diff. Testing a
  helper when the CLI contract broke leaves the contract unpinned.
- **Pin the class, not just the instance, where a class exists**: the twin fixture (lookalike stays
  pure), the table row, the sibling shapes (batch 26's probe found four more silent-pure frameworks
  by testing the *shape*, not waiting for the next report).
- **Sweep the siblings before shipping** — the same-shape check against the other engines, per §3's
  shared-blind-spot rule.
- **Soundness-class bugs additionally get**: a SOUNDNESS-LOG entry (+ register line for a cardinal
  class), and — when the class is generative — a probe/fuzzer form so the class stays gated, not
  just the instance (the seam→matrix pattern).
- The one escape hatch: a bug that genuinely cannot be pinned by a test (toolchain-environmental,
  CI-only timing) documents why in the commit and adds the nearest structural guard instead — the
  swift CI hang's "test" is the timeout + concurrency-cancel + the NSString-walk rule.

## 9. Operational rules

- **Flakiness is a bug, not weather.** A test or probe that flakes gets fixed or deleted the week
  it flakes — never wrapped in a retry loop (the fabrication probe flaked for a week on
  directory-listing order; the fix was the probe's glob, not a retry).
- **A red scheduled gate is owned, not ambient.** A scheduled probe/oracle that goes red gets
  triaged within the week or the schedule is theater — the deep-engine oracle once sat red from its
  landing and was hiding a real cardinal sin the whole time.
- **Load-bearing doc claims get drift gates.** Any documentation string that makes a checkable
  claim about the artifact — the embedded agent contract's spec version, a README's spec string, a
  version example — gets a gate asserting doc == artifact (the embedded-AGENTS.md==file==binary
  pattern). A self-describing tool whose self-description drifts is worse than none.
- **Generators gitignore their litter the day they land.** Any test, probe, or tool that writes
  files into the repo tree ships with the ignore rule in the same commit — sweep-in-by-`git add -A`
  has happened twice; make it impossible, not careful.
- **Direction, not yet a rule**: extending the mutation-probe pattern (candor-java's
  `mutation_probe`) to the other engines is the right long-term anti-padding guard for
  agent-written tests — worth doing opportunistically, not mandated while the probe ecosystem
  carries the load.

## 10. A new engine's birth certificate

A new engine (the planned C#/Go ports, any future domain engine) joins the family with all of this
on day one — the floor is a checklist, not an aspiration: both test layers (§1); the fail-closed
negative matrix and exact exit codes (§2); anti-fabrication twins for every classifier rule (§2);
κ-ledger emission tests (§2); a fuzzer and a fabrication probe wired into its CI (§7); conformance
suite membership with its rows required-when-present (§3); drift gates on its self-describing
surfaces (§9); and its generated artifacts ignored (§9).

## 11. Ship verification

- **Verify the artifact you ship, from the shipped artifact**: unzip the plugin zip and run the
  inner jar's `--version`; download the release URL; `npm pack` and test the tarball. Never a
  lookalike built from local source (a plugin zip once shipped a startup-crashing server that local
  verification called green).
- **Release automation asserts tag ⇔ version constant** (candor-swift's release.yml is the
  precedent — the engineVersion footgun nearly shipped stale twice before it). Adopt per repo as
  releases become tag-driven.

## Per-repo gates

What to actually run before claiming a change is safe lives with each repo (its AGENTS/README and
CI workflows are the source of truth): candor-java `./gradlew test` + `test/smoke.sh` + soundness
probes; candor-rust `cargo test --workspace` + `tests/integration.sh` + `ci/wrapper-smoke.sh` (+
nightly self-guard); candor-ts `npm test` (unit/behavioral/mcp/lsp/watch/fuzz/probe); candor-swift
`swift test` + `smoke.sh` + `fuzz.py` + `fabrication_probe.py`; candor-agents `test.py` + `fuzz.py`
+ contract regen; umbrella `integrations/*/test-*.sh` + `fingerprint/test-fingerprint.sh`; and the
cross-engine floor, `candor-spec/conformance/run.sh`, after any classifier or gate change.
