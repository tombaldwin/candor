# candor (umbrella) backlog

_Last reviewed 2026-07-02. Per-engine detail: `candor-java/BACKLOG.md`, `candor-rust/BACKLOG.md`._

## Direction — next strategic bets (family-level)

Correctness/honesty is well-shored and **cross-engine-verified**: the inherited-into-project silent-pure
vein class was found and closed across all major JVM persistence (candor-java κ batches 24–27) and
confirmed not a shared blind spot; the **real-world corpus campaign (2026-06-22)** fixed the last live
silent-under-reports in every engine, each gated by per-engine probes + the cross-engine conformance
differential. Undirected corpus probing is mined out (multiple consecutive clean rounds). The
deployability gate is shipped end-to-end (AS-EFF-005 ratchet, 006/008/009 policy, 010 containment,
conformance-pinned). The spec advances on a **version LADDER, not lockstep** (Tom, 2026-07-01 — SPEC.md
§"Versioning policy"): the reference engine may lead a minor/additive rung, the floor stays
conformance-pinned over the four code engines, breaking bumps stay lockstep. The ladder ran its first
full cycle with **spec 0.8** (the `--gate-json` gate verdict): candor-java led, scan/ts/swift followed,
the **floor rose to 0.8 and all four are published** (2026-07-02, tag `v0.8`; see *Recently shipped*).

**Priority (Tom, 2026-07-01): the agent loop stays the north-star, with the JVM arch gate co-important —
fund both, demote neither.** The **agent edit-time feedback loop** is the cutting-edge, differentiating
bet (effect-aware feedback into a live AI coding loop is novel and hard to copy); the **JVM architecture
gate** is the solid-engineering wedge (proven, deterministic, sellable). This supersedes any reading of
the 2026-06-18 repositioning as *demoting* the agent angle — that made the gate the lead **sales** wedge,
not a reason to stop investing in the agent loop, which stays P0 below.

Value runs in **two parallel tracks**; within each, new work is **surface, not depth** — capability is
mined-out; the spec advances only on the ladder (now at 0.8). The arch-gate track's build-out is
**complete** (items 1–3 below shipped), and the distribution backlog is now **cleared too** (2026-07-02):
both site items resolved — see *Deferred*.

### Agent-loop track — the north-star

- **[P0] Agent edit-time blast-radius feedback — ships.** [`integrations/claude-code/`](integrations/claude-code/):
  a Stop hook that scans the agent's turn, diffs effects vs a baseline, and blocks-once with the gained
  effects + blast radius + any policy violation so the agent self-corrects. Both delivery paths ship
  (`candor-review.sh` JVM/bytecode; `candor-review-source.sh` for ts/swift/scan — no build step), sharing
  the exit contract; the delta is computed from the spec report envelope so it's engine-agnostic and
  catches pure→effectful. Agent-visible feedback (the `candor: ✓ checked` notice, `.candor/activity.jsonl`
  stats, the labelled `savings` model) also shipped — see *Recently shipped* and
  [`FEEDBACK-SPEC.md`](integrations/claude-code/FEEDBACK-SPEC.md). _Remaining polish (deferred):_ `maxHops`
  in the activity log; standalone/CI logging; a richer in-IDE/MCP push.

- **[decision needed] The next agent-loop bet is unscoped.** The track's P0 is done, and what remains is a
  vague "richer in-IDE/MCP push" plus the *later* LSP below — i.e. the stated north-star has **no concrete
  next item** while the arch-gate track absorbed all recent investment. Either (a) scope the LSP with a
  design doc (the way the structure-gate got one), (b) define the MCP push concretely, or (c) state that
  the track is in harvest mode until a new bet emerges. Surfaced by the 2026-07-02 backlog review.

- **[later] IDE inline effects (LSP).** Gutter/inline annotations ("reaches `Db`, 3 hops") turn candor from
  a batch tool into an always-on ambient signal — primarily the agent/dev loop, though the same in-editor
  surface also shows the arch-gate boundary live. Bigger build (a language server, ideally one shared over
  the report envelope); a later bet, listed so it isn't lost. Surfaced 2026-07-01.

### Arch-gate adoption track — the solid-engineering wedge

One funnel, now **built end-to-end**: `candor-init.sh` writes the policy + baseline + Action → the gate
enforces it → PR-native SARIF surfaces it in review → the live demo shows it running. What shipped
(detail in *Recently shipped*):

1. **PR-native gate surfacing (SARIF) — SHIPPED 2026-07-01/02 + validated in real GitHub Actions.**
   Violations land inline on the PR diff and in the Code-scanning tab on the exact boundary-crossing line,
   via `--gate-json` (spec 0.8) → [`integrations/github/candor-sarif`](integrations/github/candor-sarif) →
   `upload-sarif`. Live example: [`candor-action-demo`](https://github.com/tombaldwin/candor-action-demo).
   _Remaining:_ optional Check-Runs API (only if SARIF rendering proves too coarse); P4 baseline-delta
   **skipped** (GitHub's code-scanning already diffs PR SARIF vs the base branch natively).

2. **Policy inference + one-command init — SHIPPED 2026-07-02.** [`adopt/candor-init`](adopt/candor-init)
   proposes a starter policy from what the code already does (every proposed rule currently passes);
   [`adopt/candor-init.sh`](adopt/candor-init.sh) scaffolds policy + baseline + Action in one command.
   Both hermetically tested, in umbrella CI, documented as the fast start in `adopt/README`.

3. **Consolidated `.candor/config` file — reference impl SHIPPED in candor-java (2026-07-02); cross-engine
   roll OPEN.** A checked-in `key value` file (§6.2 lexical) replacing the `CANDOR_*` env wiring; keys map
   1:1 to the env vars; precedence CLI → env → config → default (env still wins for a one-off run); located
   at `.candor/config` or `$CANDOR_CONFIG`. Schema: `candor-spec/proposals/config-file.md`. **Remaining:**
   roll the same parse+precedence to candor-scan/ts/swift; a conformance parse-agreement check (the
   `parsepolicy` pattern); then a normative §config in the spec (not a contract bump — config, not wire) and
   `candor-init.sh` scaffolding it. (NB: the lone `.candor/config` in `candor-rust/eval/minicache` is an
   eval-harness file holding `CANDOR_LIB`, unrelated.)

4. **Distribution — CLEARED (2026-07-02).** The proven wedge is now on the site:
   [candor.poly.io/case-studies/](https://candor.poly.io/case-studies/) (the five studies, deployed) and
   the cross-model eval evidence on [candor.poly.io/agents/](https://candor.poly.io/agents/) (verified
   live). Remaining distribution is ongoing marketing, not a backlog item: keep the adopt starter + site
   current as the tools change (the site's engine versions self-update at build; fallbacks refreshed 0.8.x).

### New-capability bet — a possible commercial add-on

- **Supply-chain effect diff (productize `gains`).** The `gains` query already computes "effects a
  dependency surface gained across versions." Productized — "your bump of lib X added `Net` to a function
  that was pure" — this is capability-level dependency diffing, distinct from CVE matching, and something
  candor is uniquely placed to do (it already has per-function effects). Net-new (not mined-out); could
  stand as its own wedge / landing page. **Business model (Tom, 2026-07-01): appealing enough to consider as
  candor's first _commercial, closed-source add-on_** — a paid layer over the open `gains` primitive.
  candor's engines are fully open source, so a closed paid layer is a deliberate business-model departure
  (the open engines stay the credibility base; this rides on top), flagged as such. Needs a version-pair
  driver + a focused alarm surface over `gains`. No next action scheduled — needs one, or explicit parking.

## fingerprint

- _Done (2026-06-21):_ **`--baseline <report>` diff** — reports the *change* in the structure descriptor
  vs a baseline (structure delta + per-component smear/unknown/tangleExcess/cycleRatio deltas, the
  direction toward order/chaos), the deterministic-gate framing. (The A–F letter grade was already removed.)

The **structure descriptor** — `structure` `= 1 − (0.30·smear + 0.26·unknownShare + 0.24·tangleExcess +
0.20·min(1, 3·cycleRatio))` (0–1, cycle term saturates; `structure_detail.value` = ×100; exact form + the
attribution decomposition in the design doc), each component exposed — is the
sanctioned "**score of sorts**": an *explainable descriptor*, not a quality grade. No letter, no
pass/fail; a degenerate input reports `structure: null`, not a flattering number (spec §6.1). It differs
from the rejected "candor score" (Non-goals, below) precisely by being **component-transparent and
delta-framed**, not a single opaque headline number. Re-opened 2026-07-01 as an active thread (was
"no items remain") — candidate next steps, none committed:

  - **[gate] structure-delta regression gate — DESIGNED 2026-07-01, decision pending (Tom's go/no-go).**
    Full design in [`fingerprint/STRUCTURE-GATE-DESIGN.md`](fingerprint/STRUCTURE-GATE-DESIGN.md).
    `--baseline` already reports the drift toward chaos; the gate makes it *fail a PR* when `structure`
    regresses past a tolerance, with the drop **attributed** to its component and — v2 — to the functions
    that crossed each line. Same posture as the AS-EFF-005 ratchet: a PR-over-PR **delta**, never an
    absolute grade; opt-in; **no AS-EFF code / not in conformance**. Open before build: threshold/min-fns
    calibration (noise floor unknown). NB this thread has now been designed twice without a commit —
    either decide or shelve it with a revisit date.
  - **[adoption] embeddable fingerprint badge.** The mark already renders with transparent corners as an
    embeddable badge; surface a "your project's candor fingerprint" artifact (a README badge / a page on
    candor.poly.io) as a low-cost distribution/marketing surface. Ties to the adoption thread above.

## Deferred operational (need a publish or maintainer action)

- **Case studies → candor.poly.io — DONE (2026-07-02).** Live at
  [candor.poly.io/case-studies/](https://candor.poly.io/case-studies/) (all five studies, linked from the
  JVM page; site checks 226 green, pre-deploy review clean).
- **Cross-model eval → candor.poly.io — DONE (verified 2026-07-02, was already live).** The completeness +
  efficiency charts and the eval claims ship on [candor.poly.io/agents/](https://candor.poly.io/agents/) —
  this item was stale. `assets/charts/` (the chart renders + generators) is now committed here as the
  regeneration source for the site copies in `web/static/images/candor/`.
- **candor-rust self-guard baseline drift** — it fired again 2026-06-30 → 2026-07-02 (the deep-engine
  oracle commit `8693315` made the lint's own `check_crate_post` read a benign `Unknown` the Jun-17
  baseline didn't record); baseline refreshed + green (`a63e26b`, recipe: `cargo candor snapshot
  .candor/baseline`). The standing maintainer call from the earlier ICE diagnosis remains: whether the
  guard path should tolerate the same cosmetic nonzero that `snapshot` now does. See candor-rust/BACKLOG.md.

## Housekeeping (small, real, easy to forget)

- **`candor-action-demo` workflow drift** — the live demo repo carries a **copy** of `adopt/candor.yml`;
  a change to the adopt starter does not propagate. Re-copy on adopt changes (it has already been
  re-copied twice), or add a sync check.
- **Vendored SARIF schema** — `integrations/github/sarif-2.1.0.schema.json` (from oasis-tcs/sarif-spec)
  powers the reporter's schema gate; it's a frozen standard, but note the provenance if it ever needs a
  refresh.

## Non-goals (decided — do not build)

- A "candor score" / cross-codebase **grade** — a single opaque headline number that ranks codebases.
  It fights the deterministic-per-function-facts positioning (spec §6.1), is gameable, and buries the
  signal. NB this does **not** rule out the fingerprint **structure descriptor** (component-transparent,
  delta-framed, explicitly not a grade — see *fingerprint* above); the non-goal is the opaque ranking
  number, not the explainable descriptor. Keep per-function facts + the explainable structure components.
- **Heavier per-engine dev-tooling** (rustfmt gate / `tsc --checkJs` / SwiftLint). Each was evaluated and
  declined with documented reasons; every engine already gates its idiomatic bug-pattern linter
  (clippy `-D warnings` / eslint / Error-Prone + `-Xlint`) plus a warnings-as-errors equivalent.

## Recently shipped (context; older entries pruned from the per-engine files)

- **Spec 0.8 + the PR-native gate + the adoption funnel (2026-07-01/02).** The week's arc, end to end:
  (a) **versioning ladder** adopted (minor rungs reference-led, floor conformance-pinned; SPEC.md
  §"Versioning policy") and ran its first full cycle — **spec 0.8** (`--gate-json`, the structured gate
  verdict `{spec, ok, violations:[{rule,fn,effects,detail?}]}` from the same check that sets the exit
  code) shipped across **all four engines and every channel**: candor-java v0.8.0 (GitHub/jbang, Java-17
  bytecode), candor-swift v0.8.0, candor-ts 0.8.0 (npm), candor-scan 0.8.0→**0.8.1** + candor-report 0.5.7
  (crates.io); conformance PART 12 pins the verdict (006+008) across all four; spec tagged `v0.8`.
  (b) **PR-native SARIF surfacing**: `integrations/github/candor-sarif` (report+verdict → SARIF 2.1.0,
  loc→repo-path, codeFlows from `path`, fingerprints incl. effects, OASIS-schema-validated, dogfooded on
  candor-java itself which caught a fingerprint-collision bug) + `adopt/candor.yml` wiring — **validated
  in real GitHub Actions** (candor-action-demo; the E2E caught 3 CI-only bugs: jbang trust, Java-21→17
  bytecode, `actions:read`). (c) **Adoption front-end**: `candor-init` (policy proposed from what the code
  already does) + `candor-init.sh` (one-command scaffold). (d) **`.candor/config`** reference impl in
  candor-java. (e) **Umbrella CI** (`integrations.yml`) gating the reporter/stop-hook/init suites — the
  repo previously had none. (f) A **family CI sweep** fixed stale smoke assertions (java spec-0.8, swift
  stderr/masking wording) + the rust self-guard baseline. (g) **candor-scan 0.8.1**: a critical spec
  review caught the workspace `--gate-json` overwrite (a clean last member masked an earlier violator's
  verdict — `ok:true` beside exit 1, violating §3.3's MUST); fixed by accumulating across members.
  (h) Agent-loop dogfood: the stop-hook block notice now names the cause; `test-stop-hook.sh` locks the
  hook's JSON contract.
- **First-run visibility + install friction (2026-06-25).** All four engines print a one-glance effect
  summary by default; candor-java fails loud with actionable guidance on a missing/unbuilt path. Website:
  a faithful "what you'll see" sample on candor.poly.io. Embedded AGENTS.md copies re-synced + maintainer
  notes added so a doc edit can't silently drift.
- **Real-world corpus campaign + all-engine publish (2026-06-22).** Ran every engine on real OSS; fixed the
  last live silent-under-reports and shipped all four: candor-ts **0.7.5** (npm), candor-scan **0.7.2**
  (crates.io), candor-swift **v0.7.3**, candor-java **v0.7.11** (incl. the Redis→Db reconciliation).
  Decision recorded: wire/HTTP datastores (ES/OpenSearch/Solr/InfluxDB/Couchbase-raw) **stay Net**.
- **Cross-model eval (done 2026-06-22).** Real-world speed + decision-quality A/B across four model tiers
  on two real crates, N=8/arm: control recall climbs with model tier (60%→99%) while **treatment is
  model-invariant at ~100% recall/precision** (one deterministic `candor-query callers`). Results in
  `candor-rust/eval/scaled/` + `.../agentuse/`. _Remaining:_ surface on candor.poly.io (Deferred).
- κ persistence coverage (candor-java 0.7.9 / 0.7.10): Hibernate-6 / Jakarta Data, Panache, Micronaut Data,
  Ebean, ActiveJDBC, jOOQ + the general modeled-base-subclass fix; repo pure-`default` fabrication fix;
  declarative HTTP-client interfaces → Net.
- `containment` in the cross-engine conformance differential (PART 11); adoption starter (`adopt/`) +
  5 case studies (`docs/`); candor-swift realizes the MODEL.md vocabulary as named types.
