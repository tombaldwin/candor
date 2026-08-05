# Changelog — candor (umbrella)

This is the umbrella repo: the **adoption and integration surface** over the engines — the drop-in CI
workflows (`adopt/`), the IDE and agent-loop clients (`integrations/`: GitHub Action, Claude Code hook,
VS Code and JetBrains LSP clients), the effects-fingerprint (`fingerprint/`), and the family docs
(`BACKLOG.md`, `TESTING.md`, the case studies). It is **not a versioned release artifact** — it pins the
engine versions it targets, so this changelog is **dated**, most recent first. Engine contract history lives
in [candor-spec's changelog](https://github.com/tombaldwin/candor-spec/blob/main/CHANGELOG.md); each engine
keeps its own.



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
