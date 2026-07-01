# candor (umbrella) backlog

_Last reviewed 2026-07-01. Per-engine detail: `candor-java/BACKLOG.md`, `candor-rust/BACKLOG.md`._

## Direction — next strategic bets (family-level)

Correctness/honesty is well-shored and now **cross-engine-verified**: the inherited-into-project
silent-pure vein class (active-record / repository / modeled-base-subclass) was found, closed across all
major JVM persistence (candor-java κ batches 24–27), and confirmed **not** a shared blind spot —
candor-ts/scan disclose `Unknown` for the same shape (SOUNDNESS.md §8.3). A **real-world corpus campaign
(2026-06-22)** then ran every engine on real OSS and found + fixed the last live silent-under-reports —
candor-ts `node:vm` / dynamic `require` / **`@types/X`→runtime-pkg mapping** (pg read pure with `@types/pg`
installed); candor-scan **`Arc`/`Rc`/`Box`** + **custom `impl Deref`** receivers; candor-swift the
inherited-from-external-conformance **Fluent ORM vein** + `extension`-shadow — each gated by per-engine
probes + the 14-part conformance differential. **All four engines are now published** with these fixes
(candor-swift v0.7.3, candor-java v0.7.11, candor-scan 0.7.2 → crates.io, candor-ts 0.7.5 → npm). Plus the
Redis Db-vs-Net reconciliation (all Redis clients → Db; candor-java 0.7.11). Undirected corpus probing is
now mined out (multiple consecutive clean rounds). The deployability gate is shipped end-to-end: AS-EFF-005
ratchet, AS-EFF-006/008/009 policy, AS-EFF-010 **containment** + cross-engine conformance (PART 11). The
spec now advances on a **version LADDER, not lockstep** (Tom, 2026-07-01 — SPEC.md §"Versioning policy"):
the reference engine may lead a minor/additive rung, the floor stays conformance-pinned, breaking bumps
stay lockstep. First use: **spec 0.8** (reference-first) — the `--gate-json` gate verdict; **candor-java
0.8.0 declares it** while ts/scan/swift stay on the 0.7 floor and raise to 0.8 as they implement it
(conformance PART 12 is ladder-aware). Value now concentrates in:

**Priority (Tom, 2026-07-01): the agent loop stays the north-star, with the JVM arch gate co-important —
fund both, demote neither.** The **agent edit-time feedback loop** is the cutting-edge, differentiating
bet (effect-aware feedback into a live AI coding loop is novel and hard to copy); the **JVM architecture
gate** is the solid-engineering wedge (proven, deterministic, sellable). This supersedes any reading of
the 2026-06-18 repositioning as *demoting* the agent angle — that made the gate the lead **sales** wedge,
not a reason to stop investing in the agent loop, which stays P0 below.

Value now runs in **two parallel tracks** (see the Priority note above); within each, new work is
**surface, not depth** — capability is mined-out and the spec is stable at 0.7.

### Agent-loop track — the north-star

- **[P0] Agent edit-time blast-radius feedback.** The `diff` / MCP surface ships, and the
  edit-time delivery loop now ships too: [`integrations/claude-code/`](integrations/claude-code/) — a Stop
  hook (`stop-hook.sh`, script selected by `CANDOR_REVIEW`) that scans the agent's turn, diffs effects vs a
  baseline, and blocks-once with the gained effects + transitive blast radius + any policy violation so the
  agent self-corrects. **Both delivery paths now ship:** `candor-review.sh` (JVM/bytecode, builds once per
  turn) and `candor-review-source.sh` (the scan-source engines ts/swift/scan — no build step), sharing the
  exit contract; the delta is computed from the spec-0.7 report envelope so it's engine-agnostic and catches
  pure→effectful. _Remaining polish:_ a richer in-IDE/MCP push.

- **[P0-adjacent] Agent-visible feedback — "candor checked this" + session stats — SHIPPED (2026-06-23/24).**
  The Stop hook was silent on a clean turn (`rc=0 → {}`), so when nothing's wrong the user couldn't tell candor
  ran — invisible help gets uninstalled. All phases built: (A) a per-turn `candor: ✓ checked …` notice via the
  Stop hook's `systemMessage` (`CANDOR_HOOK_NOTICE` = summary|changes|quiet|off); (B) measured session stats
  from `.candor/activity.jsonl` (the hook appends one record per turn — verdict, edited files sourced from the
  transcript, gained effects, blast radius, plus the P2.1 `CANDOR_SUMMARY` trailer's Unknown/effects/wall-time)
  surfaced by `candor-agents stats`; (C) the labelled per-answer/`savings` model (`candor-agents savings` counts
  real candor-query calls in the transcript vs the published 17×/50×/38× benchmark — "model, not measured", no
  fake-precise total). Design + phasing in [`FEEDBACK-SPEC.md`](integrations/claude-code/FEEDBACK-SPEC.md);
  candor-agents suite 234 green. **Dogfood pass 2026-07-01** exercised the loop end-to-end on a live scan-source
  turn and fixed one finding: the block-path user notice was a dangling header (`…introduced new effects:`) —
  now names the cause (the `• fn introduces {E}` introducer or the `AS-EFF` line). Added `test-stop-hook.sh`
  (22 assertions locking the JSON output contract — clean/block/setup × verbosity, the active-guard no-loop,
  activity-log append; previously only ad-hoc-tested). _Remaining (deferred, not P0):_ `maxHops` in the log
  (needs graph depth, not cheap); logging on standalone/CI runs (today hook-side only); a richer in-IDE/MCP push.

- **[later] IDE inline effects (LSP).** Gutter/inline annotations ("reaches `Db`, 3 hops") turn candor from
  a batch tool into an always-on ambient signal — primarily the agent/dev loop, though the same in-editor
  surface also shows the arch-gate boundary live. Bigger build (a language server, ideally one shared over
  the report envelope); a later bet, listed so it isn't lost. Surfaced 2026-07-01.

### Arch-gate adoption track — the solid-engineering wedge (ranked)

One funnel: `candor init` writes the policy + config + Action → PR-native surfacing makes the gate visible
in review → distribution drives teams to it. In priority order:

1. **PR-native gate surfacing (SARIF) — P1–P3 SHIPPED on the JVM flagship (2026-07-01).** The surface where
   architecture gates actually get adopted — **code review** — is now covered: violations land inline on the
   PR diff AND in the Code-scanning / Security tab, on the exact line a boundary is crossed, via **SARIF**
   (table stakes for the enterprise/government buyer). Built: (P0) candor-java `--gate-json` — a structured
   verdict `{spec, ok, violations:[{rule,fn,detail}]}` captured at the one `diag` sink (all AS-EFF codes,
   byte-identical when off, from the same diagnostics that set the exit code so the SARIF can't disagree with
   the gate); (P1) [`integrations/github/candor-sarif`](integrations/github/candor-sarif) — report + verdict →
   SARIF 2.1.0, `loc`→repo-path resolution (bytecode bare-filename rebuilt from the fn package under
   `--src-root`; scan-engine path-locs as-is), `partialFingerprints` dedup, 16-assertion hermetic test;
   (P2) codeFlows from the `path` query (the "how the effect reaches here" hop chain, clickable); (P3)
   `adopt/candor.yml` wiring (`security-events: write` + `--gate-json` + fetch/run `candor-sarif` +
   `upload-sarif`, both `if: always()`). Design + status: [`PR-GATE-DESIGN.md`](integrations/github/PR-GATE-DESIGN.md).
   Doesn't reposition vs Semgrep/CodeQL — SARIF is an output channel; the boundary-vs-pattern differentiation
   is unchanged. **spec 0.8 shipped reference-first** (candor-java 0.8.0 declares it; §3.3 `--gate-json`;
   conformance PART 12 ladder-aware). **Remaining:** roll `--gate-json` to ts/scan/swift (each raises to 0.8,
   floor rises; add sibling `conformance/gate/` fixtures then);
   the Action activates for users on the next candor-java **release** carrying `--gate-json` (currently only
   on candor-java `main`); P4 baseline-delta (`--since-baseline`); optional Check-Runs API (P5). Surfaced 2026-07-01.

2. **Policy inference / `candor init`.** The real barrier to the gate isn't running candor — it's knowing
   *what policy to write*. Have candor read the current structure and **propose** a starter policy from
   what's already true ("your `domain` package performs no I/O today — lock it in as `pure domain`?"), then
   drop a working baseline + GitHub Action. Turns "candor made a map" into "candor gates our PRs" in one
   command — the generative front-end that writes the `.candor/config` + policy below. Surfaced 2026-07-01.

3. **Consolidated `.candor/config` file (not built).** Today candor is configured by environment variables
   (`CANDOR_POLICY`, `CANDOR_BASELINE`, `CANDOR_JSON`, `CANDOR_CLOSED_WORLD`, `CANDOR_DEPS`, `CANDOR_STRICT`,
   `CANDOR_NO_AMBIENT`, …) plus the `.candor/` directory convention (`baseline.json`, the report,
   `.candor/policy`); the only declarative, checked-in file is the policy. A single `.candor/config` could
   hold the policy path, baseline path, report-output prefix, mode flags (closed-world / strict / no-ambient),
   dep-chain paths and host allowlists — so CI becomes "point at the repo" with no env wiring, and the
   configuration travels with the code. Cross-engine: every engine reads `.candor/config`, with env vars
   overriding for one-off runs. Spec touch: define the config schema in candor-spec so all engines agree —
   additive (it's config, not the effect contract), so no contract bump. No schema yet; needs design before
   any engine work. (NB: the lone `.candor/config` in `candor-rust/eval/minicache` is an eval-harness file
   holding `CANDOR_LIB`, unrelated to this.) `candor init` (above) is what writes it. Surfaced 2026-06-22.

4. **Distribution — get the proven wedge in front of users.** The architecture-gate is proven — 5 real-app
   case studies (`docs/`) + a copy-paste `adopt/` starter (policy template + GitHub Action), validated
   end-to-end via jbang. The remaining lift is distribution, not capability: case studies → candor.poly.io
   (now unblocked — see Deferred); keep the adoption starter current.

### New-capability bet — a possible commercial add-on

- **Supply-chain effect diff (productize `gains`).** The `gains` query already computes "effects a
  dependency surface gained across versions." Productized — "your bump of lib X added `Net` to a function
  that was pure" — this is capability-level dependency diffing, distinct from CVE matching, and something
  candor is uniquely placed to do (it already has per-function effects). Net-new (not mined-out); could
  stand as its own wedge / landing page. **Business model (Tom, 2026-07-01): appealing enough to consider as
  candor's first _commercial, closed-source add-on_** — a paid layer over the open `gains` primitive.
  candor's engines are fully open source, so a closed paid layer is a deliberate business-model departure
  (the open engines stay the credibility base; this rides on top), flagged as such. Needs a version-pair
  driver + a focused alarm surface over `gains`.

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

  - **[gate] structure-delta regression gate — DESIGNED 2026-07-01, decision pending.** Full design in
    [`fingerprint/STRUCTURE-GATE-DESIGN.md`](fingerprint/STRUCTURE-GATE-DESIGN.md). `--baseline` already
    reports the drift toward chaos; the gate makes it *fail a PR* when `structure` regresses past a
    tolerance (`--gate --threshold`), with the drop **attributed** to its component (`tangleExcess`/`smear`/
    `cycleRatio`/`unknown`, an exact weighted-sum decomposition) and — v2 — to the specific functions that
    crossed each line. Same posture as the AS-EFF-005 ratchet: a PR-over-PR **delta**, never an absolute
    grade; opt-in, off by default; exit-contract 0/1/2; **no AS-EFF code / not in conformance** (stays a
    fingerprint-tool feature so the sound spec surface isn't diluted by a heuristic composite). Phased
    v1 composite+attribution → v2 per-function pointers → v3 PR-native. Open before build: threshold/
    min-fns need calibration (noise floor unknown); the go/no-go is Tom's — it's the defensible *edge* of
    the score non-goal, not over it.
  - **[adoption] embeddable fingerprint badge.** The mark already renders with transparent corners as an
    embeddable badge; surface a "your project's candor fingerprint" artifact (a README badge / a page on
    candor.poly.io) as a low-cost distribution/marketing surface. Ties to the adoption thread above.

## Deferred operational (need a publish or maintainer action)

- **Case studies → candor.poly.io** — the 5 studies live in `docs/` but aren't on the site yet. The
  earlier ssh-agent deploy blocker is **RESOLVED** (dedicated passphrase-less automation key, 2026-06-24;
  deploys work — e.g. the 2026-06-25 "what you'll see" site update shipped fine). So this is now just
  _to-do_, no longer blocked.
- **candor-rust CI self-guard nightly ICE** — largely superseded: the "ICE" was diagnosed as a *cosmetic*
  rustc shutdown delayed-bug fired *after* candor wrote its complete report, and `cargo candor snapshot`
  was fixed to gate on the report being written (see the Cross-model eval item below). The `guard`/self-
  guard CI path still fails-closed on any nonzero by design. This session's candor-rust `ci` ran fully
  green (2026-06-25), so it isn't currently firing. Remaining call (maintainer's): whether the guard path
  should tolerate the same cosmetic nonzero that `snapshot` now does. See candor-rust/BACKLOG.md.
- **Cross-model eval → candor.poly.io** — the eval itself is **done** (summary moved to *Recently
  shipped*; full results in `candor-rust/eval/scaled/` + `.../agentuse/`). Only the _surface-on-the-site_
  thread is still open — the real-world gradient is strong site evidence and isn't up yet.

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

- **First-run visibility + install friction (2026-06-25).** All four engines now print a one-glance effect
  summary by default (candor-java leads with `candor — N functions reach effects, across M classes` +
  per-effect breakdown + `Unknown K (disclosed)`; ts/scan/swift add a breakdown after the wrote line —
  console-only, reports byte-identical). candor-java now fails loud with actionable guidance on a
  missing/unbuilt/source path (reads bytecode → point at `build/classes` / `target/classes` / a jar)
  instead of silently reporting "0 functions". Website: a faithful "what you'll see" sample now sits under
  the paste box on candor.poly.io. Plus: re-synced the embedded AGENTS.md copies the 0.5→0.7 de-stale left
  stale (candor-java jar resource, candor-rust scan + query, candor-swift generated doc — the drift gates
  run only in CI smoke, so they'd gone red) and added a top-of-file maintainer note to each canonical
  AGENTS.md so a doc edit can't silently drift again.
- **Real-world corpus campaign + all-engine publish (2026-06-22).** Ran every engine on real OSS; fixed the
  last live silent-under-reports and shipped all four: candor-ts **0.7.5** (npm — `node:vm`/dynamic-`require`
  → Unknown; `@types/X`→runtime-pkg so curated DB/Net clients fire, e.g. pg→Db with `@types/pg`),
  candor-scan **0.7.2** (crates.io — `Arc`/`Rc`/`Box` + custom `impl Deref` receiver under-reports),
  candor-swift **v0.7.3** (inherited-from-external-conformance Fluent ORM vein → Db, `extension`-shadow,
  `.write(to:)`), candor-java **v0.7.11** (Redis Db reconciliation + `CANDOR_CLOSED_WORLD` + CI/AGENTS.md
  sync). Decision recorded: wire/HTTP datastores (ES/OpenSearch/Solr/InfluxDB/Couchbase-raw) **stay Net** by
  the existing deliberate policy (native-protocol datastores are already Db).
- **Cross-model eval (done 2026-06-22).** Real-world speed + decision-quality A/B across **Fable 5 / Opus /
  Sonnet / Haiku 4.5** on two real crates (git-delta, 61-fn tree; bottom, 26-fn tree), N=8/arm: control
  recall climbs with model tier (60%→99% on delta) while **treatment is model-invariant at ~100%
  recall/precision every tier** (one deterministic `candor-query callers`). candor's marginal value scales
  with how hard the blast radius is to trace by hand (depth × non-greppability); its report is the
  adjudicated truth on both (delta 61/61, bottom 26/26). Deep-engine `nightly-2026-06-14` port merged to
  candor-rust main (40/40 soundness, delta 61/61 byte-identical); the modern-repo "ICE" fixed (cosmetic
  shutdown delayed-bug — `cargo candor snapshot` gates on report-written). Results in
  `candor-rust/eval/scaled/RESULTS-realworld.md` + `RESULTS-speed-models.md` + `.../agentuse/RESULTS-weak.md`.
  _Remaining:_ surface on candor.poly.io (tracked in Deferred).
- κ persistence coverage (candor-java 0.7.9 / 0.7.10): Hibernate-6 / Jakarta Data, Panache, Micronaut Data,
  Ebean, ActiveJDBC, jOOQ + the general modeled-base-subclass fix; repo pure-`default` fabrication fix;
  declarative HTTP-client interfaces → Net.
- `containment` in the cross-engine conformance differential (PART 11); `containment` added to candor-ts
  (all three query engines now have it; swift via candor-query).
- candor-swift realizes the MODEL.md vocabulary as named types (3 of 4 engines now typed).
- Adoption starter (`adopt/`) + 5 case studies (`docs/`).
