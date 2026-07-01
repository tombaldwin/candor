# Structure-delta gate — design

Status: **design / not built.** Turns the fingerprint tool's existing `--baseline` diff into an opt-in,
PR-over-PR **regression gate**. It does **not** touch the candor effect contract (candor-spec) and does
**not** get an AS-EFF code — it stays a fingerprint-tool feature (see *Honesty & boundaries*).

## Why

The structure descriptor (`structure`, 0–1, from smear / unknownShare / tangleExcess / cycleRatio) already
has a `--baseline` diff that *reports* the change vs a baseline (`structure −0.06 — drifted toward chaos`).
This makes that report a **gate**: fail a PR when structure regresses past a tolerance, so "getting more
tangled" is caught the way "gained a forbidden effect" is (the AS-EFF-005 baseline ratchet). It's the soft,
whole-shape complement to the hard, per-boundary AS-EFF policy gate.

The bar it must clear: candor deliberately does **not** grade codebases (spec §6.1; the A–F letter was
removed). So the gate must be a **delta ratchet** (PR-over-PR change), never an absolute grade, and must be
**attributed** (name the component *and* the functions that drove the drop) — actionable, not an opaque
number that fails your build.

## The metric it gates (exact — from `candor-fingerprint.mjs`)

```
structure = clamp01( 1 − (0.30·smear + 0.26·unknownShare + 0.24·tangleExcess + 0.20·cycleTerm) )
cycleTerm = min(1, 3·cycleRatio)      # the cycle signal saturates: ~a third of functions in a cycle maxes it
```

Components (all shares candor already computes):
- **smear** — share of functions with ≥3 distinct **non-Unknown** effects (god-functions).
- **unknownShare** — share of effect incidences candor couldn't resolve (analysis opacity).
- **tangleExcess** — `max(0, tangle − 0.4) / 0.6` (call-graph density above a baseline).
- **cycleRatio** — share of functions inside a call cycle (→ `cycleTerm`).

`structure = null` on a **degenerate** input (no effectful functions, empty graph, or zero concrete effects
resolved). The gate treats `null` on *either* side as un-gateable → exit 2, never a pass.

## Attribution — why it isn't an opaque number

Because `structure` is a weighted sum, the drop decomposes **exactly** (in the interior, `structure ∈ (0,1)`;
approximate only at the 0/1 clamp):

```
Δstructure = −( 0.30·Δsmear + 0.26·Δunknown + 0.24·ΔtangleExcess + 0.20·ΔcycleTerm )
```

so each component's **contribution to the drop** is `weight · Δcomponent` (shown in structure points, ×100).
The `--baseline` block already computes every `Δcomponent`; the gate multiplies by the weight and ranks.
NB attribution uses the **saturated** `cycleTerm = min(1, 3·cycleRatio)`, not raw `cycleRatio`, so the
contributions sum to `−Δstructure`. Sample verdict:

```
candor-fingerprint: STRUCTURE REGRESSED — 71 → 66  (−5, tolerance −3)  [gate: fail]
  drivers (of the −5 points):
    tangleExcess  +0.08   →  −1.9   call-graph density up
    cycleRatio    +0.02   →  −1.2   more functions in a call cycle
    smear         +0.03   →  −0.9   more functions doing ≥3 things
    unknown       −0.01   →  +0.3   (improved)
  look at:
    newly ≥3-effect:   app.OrderService.checkout, app.Report.build
    newly in a cycle:  app.A.f ↔ app.B.g
```

The **"look at" pointers** (v2 — see *Phasing*) name the functions that crossed each component's line, by
diffing the two reports' per-function sets:
- **smear** — functions whose non-Unknown effect count went `0..2 → ≥3`.
- **unknown** — functions that newly carry `Unknown`.
- **cycleRatio** — functions newly inside a cycle.
- **tangleExcess** — no clean per-function source (it's a global density); name the nodes with the largest
  fan-in+fan-out increase as a *proxy*, labelled as such.

## CLI

```
candor-fingerprint <report> --baseline <base> --gate [options]
  --threshold <pts>      composite tolerance in structure points (0–100); fail if the drop exceeds it.  default 3
  --component-cap <pts>  also fail if ANY single component's contribution to the drop exceeds this, even when the
                         composite passes — catches a real regression masked by an offsetting improvement.  default off
  --min-fns <n>          skip the gate (exit 0 + note) below n effectful functions: small-repo ratios are too
                         noisy to gate.  default 25
  --gate-json            print the machine verdict to stdout
```

`--gate` requires `--baseline` (error otherwise). Fully deterministic and offline — the structure math
already is; the gate adds no network and no nondeterminism.

## Exit contract (matches `candor-review.sh`: 0 clean / 1 gate / 2 setup)

- **0** — within tolerance, OR structure improved / unchanged, OR **skipped** (fewer than `--min-fns`).
- **1** — structure regressed past `--threshold` (or a component past `--component-cap`).
- **2** — setup: missing/unreadable report or baseline; `structure` null on either side (degenerate — can't
  gate); `--gate` without `--baseline`.

Never a silent pass on a can't-compute: a degenerate or too-small input says so and exits 0 (skip) or 2
(setup) — it never fabricates a verdict.

## `--gate-json`

```json
{ "gate": "structure-delta", "verdict": "fail",
  "structure": { "base": 71, "current": 66, "delta": -5, "threshold": -3 },
  "drivers": [ {"component":"tangleExcess","deltaRaw":0.08,"points":-1.9,"note":"call-graph density up"},
               {"component":"cycleRatio","deltaRaw":0.02,"points":-1.2},
               {"component":"smear","deltaRaw":0.03,"points":-0.9} ],
  "pointers": { "newSmear":["app.OrderService.checkout"], "newUnknown":[], "newCycle":[["app.A.f","app.B.g"]] } }
```

## How it reads in a PR

- **Standalone CI step** (v1) — a job runs `candor-fingerprint <cur> --baseline <main> --gate`; exit 1 fails
  the check, the attributed message is in the log. Drop-in alongside the AS-EFF `examples/candor-guard.yml`.
- **PR-native** (when the GitHub-Check bet lands) — the verdict becomes one section of the candor Check: the
  `−5` headline, the driver breakdown, and the "look at" functions as inline annotations at their def sites.
  The two bets compose — the effect-policy violations are the **hard** failures; the structure delta is a
  **soft** "trending tangled" note (configurable: annotate vs. fail).

## Honesty & boundaries (what keeps it defensible)

- **A trend tripwire, not a proof.** The descriptor is a heuristic composite; the gate flags a PR-over-PR
  *direction*, not a truth about code quality. Framed like `risk` / `blindspots` — a nudge, not a verdict.
- **A delta, never a grade.** It gates the *change* vs a baseline, never an absolute number, and never
  compares across codebases. That is the exact line the §6.1 non-goal draws; the gate stays on the delta side.
- **Off by default, opt-in per repo.** Like the CI guardrail — a team decision, never automatic.
- **Not a spec / AS-EFF gate.** No AS-EFF code, not in the cross-engine conformance differential. The sound
  spec surface (the effect contract) stays free of the heuristic composite; this is a fingerprint-tool
  convenience. The AS-EFF effect policy remains the real architecture gate — the structure gate complements,
  never replaces, it.
- **Gaming.** The composite can be gamed by offsetting a real regression with an unrelated improvement;
  `--component-cap` mitigates by gating each axis too. A determined gamer defeats any heuristic gate — that's
  disclosed, not papered over.
- **Calibration.** The default `--threshold 3` / `--min-fns 25` are starting points, **not** proven — they
  need real-world calibration (precedent: the CHA-12 bound was calibrated on 20 crates). Recommend starting
  loose (`--threshold 5`) and tightening once a repo's normal churn is known.

## Phasing

- **v1 — composite gate + attribution.** `--gate` / `--threshold` / `--component-cap` / `--min-fns` /
  `--gate-json`, the exit contract, and the driver decomposition — all from the deltas the `--baseline` block
  already computes. No new report loading. Turns "structure −5" into "structure −5, mostly tangleExcess."
- **v2 — the "look at" pointers.** Load the baseline report + callgraph in-process (today `--baseline` reads
  only the baseline's *metadata* via a subprocess) and diff the per-function smear/unknown/cycle sets to name
  the functions that moved. This is what makes it actionable, not merely attributed.
- **v3 — PR-native surface.** Fold the verdict into the GitHub Check + inline annotations (depends on the
  PR-native gate bet).

## Open questions

- **Default threshold + min-fns** — need calibration on real repos; the noise floor is unknown.
- **Absolute floor?** Should an already-chaotic repo (structure < ~30) be allowed to regress freely, or is a
  floor useful? A floor edges toward an absolute grade — lean *no*, keep it pure-delta.
- **tangleExcess pointers** — "largest fan-in/out increase" is a proxy, not a true source; useful enough, or
  omit tangle pointers and report only the number?
- **Config** — when `.candor/config` lands, the gate's thresholds belong there (travels with the repo).
