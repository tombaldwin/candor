# Changelog — candor (umbrella)

This is the umbrella repo: the **adoption and integration surface** over the engines — the drop-in CI
workflows (`adopt/`), the IDE and agent-loop clients (`integrations/`: GitHub Action, Claude Code hook,
VS Code and JetBrains LSP clients), the effects-fingerprint (`fingerprint/`), and the family docs
(`BACKLOG.md`, `TESTING.md`, the case studies). It is **not a versioned release artifact** — it pins the
engine versions it targets, so this changelog is **dated**, most recent first. Engine contract history lives
in [candor-spec's changelog](https://github.com/tombaldwin/candor-spec/blob/main/CHANGELOG.md); each engine
keeps its own.

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
