# PR-native gate surfacing — GitHub Check + SARIF (design / scope)

Status: **P1–P3 built on the JVM flagship (2026-07-01); spec stays 0.7.** Adoption feature (arch-gate
track #1, "highest leverage"). Does **not** touch the candor effect contract (candor-spec) or any engine's
analysis — it is a **reporter over the spec-0.7 report envelope + a structured gate verdict**, plus Action
wiring. `candor-sarif` + its test + the `adopt/candor.yml` wiring ship; the structured verdict is a
candor-java `--gate-json` **engine feature at spec 0.7** (below). Remaining: roll `--gate-json` to
ts/scan/swift + conformance, then promote to spec 0.8; P4 baseline-delta; optional Check-Runs API.

## Why

candor gates today via a CI **exit code**, the local **Stop hook**, and **CLI queries**. But the surface
where architecture gates actually get adopted — **code review** — isn't covered. A red CI check says
*"something failed"*; it doesn't say *"`OrderService.quote` now reaches `Db`, crossing the domain→infra
boundary you declared, 3 hops via `billing.charge`"* **on the line, in the PR**. Two channels close that:

- **A. Inline PR annotations** — the violation shown on the exact source line in the diff (review-time).
- **B. SARIF → Code-scanning / Security tab** — violations as first-class code-scanning alerts, with
  history, dismissal, and the native Security surface. Table stakes for the enterprise/government buyer.

This is *"enforced on every push"* made visible **on the push**. It does **not** reposition candor vs
Semgrep/CodeQL — SARIF is an output channel; the boundary-vs-pattern differentiation is unchanged.

## The enabling facts (all already in spec 0.7 — nothing new to model)

The report envelope + existing queries already carry everything a reporter needs:

| Need | Source (spec 0.7) |
|---|---|
| Where a violation is (file:line) | `functions[].loc` = `"<file:line:col>"` — **normative, every engine** (§ envelope) |
| The violating function + its rule | the checker's `AS-EFF-…` verdict (006 policy / 008 allowlist / 009 forbid-flow); per-fn `undeclared` = inferred−declared |
| *How* the effect reaches the line | `path <fn> <Effect>` → `{ path:[ { fn, loc, source } ] }` — the shortest chain to the direct source, each hop with its `loc` |
| The blast radius (for the message) | `whatif <fn> <Effect>` → `{ affected, violations:[{fn,rule}], ok }`; `impact` for the caller cone |

**Nice fit:** the `path` hop chain maps directly onto SARIF **`codeFlows`/`threadFlows`** — the format's
native "here's how execution reaches this point" trace. So "3 hops via `billing.charge`" isn't prose in
the message; it's a clickable flow in the Security tab.

## Architecture — a standalone reporter, engine-agnostic

```
  build/scan ─► <report>.json (spec 0.7)  ┐
  policy gate ─► AS-EFF verdict            ├─►  candor-sarif  ─►  candor.sarif ─► upload-sarif ─► PR + Security tab
  (CANDOR_POLICY run, exit 1 on violation) ┘        │
                                    path/whatif queries for codeFlows + blast-radius message
```

The reporter reads the **standard envelope** (not any engine's internals), so one implementation serves
all engines — exactly the backlog's "reads the report envelope so it's engine-agnostic." The hard gate
stays the engine's **exit 1**; SARIF/annotations are a *surfacing* layer laid over it (a failed upload
must never turn a red gate green).

### Where the structured violations come from — RESOLVED: fork B (built)

SARIF needs a **structured** violation list (fn, rule) joined to `loc`. Chosen: **B — a structured gate
dump**, for robustness (no console-line parsing; a single source of truth). Implemented in candor-java as
`--gate-json <file>` → `{ spec, ok, violations:[{rule, fn, detail}] }`.

The capture is the cleanest possible: **every** AS-EFF violation already flows through the one
`Candor.diag(code, format, args…)` sink, and every call site passes the offending entity as `args[0]`. So
`--gate-json` records `{rule: code, fn: args[0], detail: message}` at that single site — all codes, zero
per-checker drift, and from the **same** diagnostics that print and set the exit code, so the SARIF can
never disagree with the gate. `loc` + effects are joined by `fn` from the report envelope in the reporter
(the report already carries them), so the verdict stays minimal. Off by default → byte-identical output
(verified: report + console identical with/without the flag; full JUnit suite green).

This is a candor-java **engine feature at the current spec 0.7** — not a spec change (queries/outputs are
"an interface convenience, not the wire contract", SPEC §3.1; and the versioning policy has the reference
engine lead a capability *before* it's promoted, exactly as `callers --include-unknown` preceded 0.7). It
becomes **spec 0.8** only once ported to ts/scan/swift + conformance-gated.

## SARIF mapping (2.1.0)

- `runs[].tool.driver`: `{ name: "candor", informationUri: https://candor.poly.io, rules: [...] }` — one
  rule object per AS-EFF code encountered (`AS-EFF-006`…), each with `name`, `shortDescription`, `helpUri`
  → the spec section, `defaultConfiguration.level: "error"`.
- `results[]` per violation: `{ ruleId: "AS-EFF-006", level: "error", message: "<fn> reaches {Db},
  crossing the domain→infra boundary (3 hops via billing.charge)", locations: [ physicalLocation from
  loc ], codeFlows: [ from the path query ], partialFingerprints: { candorViolation: hash(fn+rule) } }`.
  `partialFingerprints` give GitHub stable identity so an unchanged violation isn't re-alerted every run.
- `loc` → `physicalLocation`: split `file:line:col: line:col` → `artifactLocation.uri` (repo-relative) +
  `region.{startLine,startColumn,endLine,endColumn}`.

## Action wiring (extends `adopt/candor.yml`)

```yaml
    permissions:
      security-events: write        # required to upload SARIF
      contents: read
    steps:
      # … build + gate as today; the gate writes candor-report.json and exits 1 on a violation …
      - name: candor → SARIF
        if: always()                # surface even when the gate failed (that's the point)
        run: candor-sarif candor-report.json --policy arch.policy > candor.sarif
      - name: upload SARIF
        if: always()
        uses: github/codeql-action/upload-sarif@v3
        with: { sarif_file: candor.sarif }
```

One uploaded SARIF gives **both** surfaces — inline PR-diff annotations *and* the Security tab — with no
Checks-API token dance. (A dedicated Check Run via the Checks API buys richer inline control — grouping,
custom summaries — but needs a token + annotation batching ≤50/run; a *later* enhancement, only if SARIF's
rendering proves too coarse.)

## Decisions to bake in

- **Which violations:** MVP annotates the **current** policy violations (AS-EFF-006/008/009). A second
  mode annotates **only what changed vs baseline** (the AS-EFF-005/010 ratchet — "this PR introduced it"),
  which is the sharper review signal; add it as `--since-baseline` once the base form works.
- **`loc` precision caveat (candor-java):** bytecode line numbers need debug info (`LineNumberTable`,
  present with default `mvn`/`gradle` builds). Without `-g`, degrade to the method's declaring line / file
  top — annotate at file granularity rather than fabricate a line. (Scan-source engines always have exact
  `loc`.) Disclose, don't guess — consistent with the effect contract.
- **Fail-closed:** SARIF write / upload failures are logged but never flip the gate result; the exit-1
  from the engine is the source of truth for pass/fail.

## Phasing

- **P0 — structured gate output (fork B). ✓ built.** candor-java `--gate-json <file>` (captured at the
  `diag` sink; byte-identical when off; JUnit green). *Remaining:* roll to ts/scan/swift + conformance →
  promote to spec 0.8.
- **P1 — the reporter (`candor-sarif`). ✓ built.** `report.json` + `gate.json` → valid SARIF 2.1.0.
  Locations from `loc` (bytecode bare-filename rebuilt from the fn package under `--src-root`; scan-engine
  path-locs used as-is); message from the engine's own `detail`; `partialFingerprints` for stable dedup.
  16-assertion hermetic test (`test-candor-sarif.sh`). Proven end-to-end on a real JVM violation.
- **P2 — codeFlows. ✓ built.** `--query-cmd` → each result carries the `path` hop chain as a SARIF
  `codeFlow` (e.g. `checkout → audit — source`), clickable in the Security tab.
- **P3 — Action wiring. ✓ built.** `adopt/candor.yml` gains `security-events: write`, the `--gate-json`
  output, the `candor-sarif` fetch+run, and `upload-sarif` (both steps `if: always()` so a failed gate
  still surfaces). YAML-validated. Activates for users on the next candor-java release carrying `--gate-json`.
- **P4 — baseline-delta mode.** `--since-baseline` → annotate only violations new vs the ratchet baseline
  (the sharper review signal). Not built.
- **P5 (optional) — Check-Runs API.** A dedicated Check Run for richer inline grouping, only if SARIF's
  rendering proves too coarse. Not built.

## Open questions

- **Reporter home + language.** A standalone script in `integrations/github/` (portable, engine-agnostic
  — Python/Node, matching the Stop-hook shell style) vs a subcommand of an existing tool
  (`candor-agents`, which already post-processes reports)? Leaning standalone in `integrations/github/`.
- **Repo-relative path resolution.** `loc` is engine-relative to the scanned root; SARIF `uri` must be
  repo-relative. Needs a `--src-root` / prefix-strip so annotations land on the right file in the PR.
