# candor (umbrella) backlog

_Last reviewed 2026-07-16 (floors 0.16→0.18: the callgraph-aware baseline guard, query target validation, and the trust-trio; + the disclosure-refinement track opened from the academic referee pass). Per-engine detail: `candor-java/BACKLOG.md`, `candor-rust/BACKLOG.md`._

## Direction — next strategic bets (family-level)

Correctness and disclosure are well-shored and **cross-engine-verified**: the inherited-into-project silent-pure
vein class was found and closed across all major JVM persistence (candor-java κ batches 24–27) and
confirmed not a shared blind spot; the **real-world corpus campaign (2026-06-22)** fixed the last live
silent-under-reports in every engine, each gated by per-engine probes + the cross-engine conformance
differential. Undirected corpus probing is mined out (multiple consecutive clean rounds). The
deployability gate is shipped end-to-end (AS-EFF-005 ratchet, 006/008/009 policy, 010 containment,
conformance-pinned). The spec advances on a **version LADDER, not lockstep** (Tom, 2026-07-01 — SPEC.md
§"Versioning policy"): the reference engine may lead a minor/additive rung, the floor stays
conformance-pinned over the four code engines, breaking bumps stay lockstep. The ladder has run
eleven full cycles: **0.8** (the `--gate-json` gate verdict), **0.9** (the remedial tool loop), **0.10**
(the canonical query grammar), **0.11** (the surprising-reach surface + corrupt-report loudness),
**0.12** (the gains `origin` field), **0.13** (the `Llm` effect + the `extensions` field / the
candor-swift `privacy/1` sensor extension + `privacy-manifest` verb), **0.14** (the top-level/initializer
unit — a cardinal-sin closure), **0.15** (the coverage envelope — the κ ledger travels with the
report, verdict-preserving verb conditionality — plus host-resolution recall and four corpus-found
soundness fixes), **0.16** (the callgraph-aware baseline guard — a formerly-pure fn turning effectful is a
gain, AS-EFF-005; Unknown-only gains stay advisory), **0.17** (query target validation — `where`/`callers`
fail loud (exit 2) on a typo'd effect or nonexistent fn, never a false empty at exit 0), and **0.18** (the
trust-trio — the `--strict` advisory-verb CI gate on `fix-gate`/`gains`/`unverified` + the surface/`tour`
mostly-Unknown disclosure, both four-way; hardened by a Fable-model code review that caught two latent
cardinal-sin edges: swift's un-gated scan opener, java's single-dash flag swallow). The **floor is now
0.18** (all engines at 0.18.0, conformance-pinned through PARTs 4l/5b/12b/12c, **published + release-verified
live** 2026-07-16: crates.io, npm via the tag-triggered OIDC action with SLSA provenance, gh releases, java
native binaries, the Homebrew tap; `candor outdated` resolves 0.18 on every channel).

**Priority (Tom, 2026-07-01): the agent loop stays the north-star, with the JVM arch gate co-important —
fund both, demote neither.** The **agent edit-time feedback loop** is the cutting-edge, differentiating
bet (effect-aware feedback into a live AI coding loop is novel and hard to copy); the **JVM architecture
gate** is the solid-engineering wedge (proven, deterministic, sellable). This supersedes any reading of
the 2026-06-18 repositioning as *demoting* the agent angle — that made the gate the lead **sales** wedge,
not a reason to stop investing in the agent loop, which stays P0 below.

Value runs in **two parallel tracks**; within each, new work is **surface, not depth** — capability is
mined-out; the spec advances only on the ladder (now at 0.15). **Both tracks' build-outs are complete**:
the arch-gate funnel end-to-end (items 1–3 below), and the agent-loop polish closed 2026-07-14 (the
`candor_activity` MCP + LSP push — no polish items remain). The 2026-07-15 autonomous corpus+audit run
confirmed the engines sound across ~20 real repos (4 real finds, all fixed and shipped in 0.15). What
remains open, by kind: **externally blocked** — the JetBrains Marketplace first-plugin moderation
(uploaded 2026-07-03, still pending 2026-07-15), the lsp4ij catalog PR #1609 (no review yet), the VS Code
Marketplace publisher (needs Tom's Azure DevOps PAT); **Tom's commercial call** — gains productionization
(the hosted watch layer; waitlist buttons live on the site with the sharpened Llm hook, 0 signups as of
2026-07-15); **candidate next bets** — the fingerprint structure-gate (designed,
`fingerprint/STRUCTURE-GATE-DESIGN.md`, not built) and whatever the next planning pass ranks.

### Agent-loop track — the north-star

- **[P0] Agent edit-time blast-radius feedback — ships.** [`integrations/claude-code/`](integrations/claude-code/):
  a Stop hook that scans the agent's turn, diffs effects vs a baseline, and blocks-once with the gained
  effects + blast radius + any policy violation so the agent self-corrects. Both delivery paths ship
  (`candor-review.sh` JVM/bytecode; `candor-review-source.sh` for ts/swift/scan — no build step), sharing
  the exit contract; the delta is computed from the spec report envelope so it's engine-agnostic and
  catches pure→effectful. Agent-visible feedback (the `candor: ✓ checked` notice, `.candor/activity.jsonl`
  stats, the labelled `savings` model) also shipped — see *Recently shipped* and
  [`FEEDBACK-SPEC.md`](integrations/claude-code/FEEDBACK-SPEC.md). _Polish COMPLETE (2026-07-14):_ the
  in-IDE/MCP push shipped both halves same-day (`candor_activity` on candor-mcp + the candor-lsp
  activity tail — AGENT-SURFACE-DESIGN.md P1/P2); `maxHops` + standalone/CI logging closed the same
  week (FEEDBACK-SPEC P2.2/P2.3). No agent-loop polish items remain.

- **The agent-surface sequence (decided by Tom 2026-07-02; design in
  [`integrations/AGENT-SURFACE-DESIGN.md`](integrations/AGENT-SURFACE-DESIGN.md)). Bet 1 — the unified
  `candor-mcp` — SHIPPED same day:** one engine-agnostic MCP server (candor-ts pkg, `candor-mcp` bin)
  serving all four engines' reports, with the gate verdict (resolves the checked-in `.candor/config`
  policy), containment, blindspots, diff, gains + MCP resources (report + policy); verified across all
  four engines' real reports; the rust python server deprecated. On npm since candor-ts 0.8.3
  (current 0.8.7).
  **Bet 2 — `candor-lsp` — P1 SHIPPED (2026-07-02):** CodeLens `⚡ effects · blast radius N` + the live
  gate verdict as diagnostics (config-discovered policy), any engine's report (java bytecode locs verified),
  freshness via report re-reads (watch/stop-hook/build). helix/neovim wire it natively; 9 behavioral tests.
  **The VS Code client SHIPPED 2026-07-10** ([`integrations/vscode/`](integrations/vscode/)): a thin
  `vscode-languageclient` extension bundling the handshake-verified candor-lsp (candor-ts pinned 0.8.8,
  the JetBrains stage→bundle→verify chain in npm-script form), runs the server on VS Code's own Node
  (no system node); `candor-vscode-0.8.8.vsix` packaged + verified FROM the artifact (`test-vscode.sh`:
  pin, LSP lifecycle handshake on the extracted bundle, contents, README drift; path-filtered
  `vscode.yml` CI) and smoke-installed/uninstalled via the real `code` CLI. Sideload the .vsix (works
  in Cursor/Windsurf too); Marketplace publisher setup pending. _Remaining P2 slices:_ the whatif
  code-action (landing in candor-ts — the extension picks it up with the next `candorTsVersion` pin
  bump, no client change), large-repo lens performance (hover provenance shipped 2026-07-02, published
  in candor-ts 0.8.3+). **JetBrains
  slice STAGED (2026-07-02):** (a) an LSP4IJ template for the catalog (install LSP4IJ → pick "Candor"
  → auto npm-install) — **PR OPEN:
  [redhat-developer/lsp4ij#1609](https://github.com/redhat-developer/lsp4ij/pull/1609)** (watch for
  maintainer review); (b) [`integrations/jetbrains/`](integrations/jetbrains/) — **PACKAGED + gated
  (refreshed 2026-07-09):** `./gradlew buildPlugin` (wrapper pinned 9.5.1) → `candor-intellij-0.8.2.zip`
  (sideloadable) against IC 2024.3 + LSP4IJ 0.20.1, embedding the handshake-verified server bundle
  (candor-ts pinned 0.8.7) + the pinned v0.8.6 engine jar (both pins are build-task inputs, and
  `verifyEngineJar` fails the build unless the staged jar self-reports the pin); the JVM freshness
  loop uses the modern ProjectTaskListener API. **Verifier-clean (Compatible × 6 IDE targets, IC-243 →
  IU-262** — it caught the em-dash plugin-name Marketplace blocker); Beaky pluginIcon.svg; a
  path-filtered `jetbrains.yml` CI workflow (build per plugin change + weekly scheduled Plugin
  Verifier). **UPLOADED to the JetBrains Marketplace 2026-07-03 (as 0.8.0; Apache-2.0, tags: static
  analysis / code quality / security; source URL → integrations/jetbrains) — first-plugin moderation
  pending.** On approval: wire `publishPlugin` + the Marketplace token as a repo secret so 0.8.1+ ship
  headlessly; an install-from-disk smoke in a real IDE remains worthwhile whenever convenient.
  **Released engines (as of 2026-07-10, ship wave 2):** candor-ts 0.8.7 (npm), candor-scan 0.8.5 +
  candor-query 0.8.1 (crates.io), candor-java v0.8.6, candor-swift v0.8.5, candor-agents v0.8.1
  (GitHub) — all spec-0.8; plugin 0.8.2 zip staged for Marketplace. Family test standards now
  codified in TESTING.md (coverage measured + every zero-coverage gate surface closed).

- **[P1 — NEW, 2026-07-10] The candor digest — make the silent gate VISIBLE.** Adoption/retention
  problem Tom named: the tool is silent by design (good — never muted), but the OWNER who renews never
  sees it work → "why are we running this?" is easy to ask. Fix is NOT more dev-channel noise — it's a
  separate periodic OWNER-facing digest over the activity log candor already keeps
  (.candor/activity.jsonl + candor-agents stats). Spec: `integrations/DIGEST-SPEC.md`. Leads with the
  catches, closes with "N clean = the product working", ALWAYS carries the coverage/honesty line (what
  candor couldn't see — its own disclosure ethos pointed at itself), counts-not-a-leaderboard,
  aggregate-only (paths stay local, privacy tier = the gate verdict). Build order: **P1 DONE 2026-07-10** — `candor-agents digest` renders CANDOR-REPORT.md (owner narrative, caught-vs-allowed split, always the coverage/honesty line, aggregate-only, 13 tests, 391 total). P2 DONE 2026-07-10 — gate logs outside the agent hook (candor-review*.sh self-log a path-free record via the shared lib.candor_log_activity; no double-log under the hook; +5 tests) + adopt/candor-digest.yml scheduled Action → run summary + committed CANDOR-REPORT.md. "Held the line in CI" is real. P3 DONE 2026-07-10 (delivery complete): (a) jar --gate-json path logs via candor-agents log-gate (path-free record, parity-tested vs the bash writer; opt-in EDIT 5 in adopt/candor.yml) so the pure-jar PR gate feeds the digest; (b) optional Slack push in adopt/candor-digest.yml (CANDOR_SLACK_WEBHOOK-gated, no-op when unset). DEFERRED: the gains dependency line — blocked until a gains monitor produces records (receiver-before-producer = speculative). Was: P1 `candor-agents
  digest` → committed CANDOR-REPORT.md (cheapest, on data that already logs); P2 log CI/standalone runs
  (close the FEEDBACK-SPEC "standalone/CI logging" deferred gap) + a scheduled Action; P3 Slack/email +
  the gains dependency line. Cheapest-first, each step the same rendered text through a different pipe.

- **[SHIPPED — was "later"] IDE inline effects (LSP).** This landed as the `candor-lsp` CodeLens
  (`⚡ effects · blast radius N`) + live gate diagnostics + hover provenance, in VS Code, JetBrains
  (LSP4IJ), helix and neovim — the Bet-2 sequence above. The item predates the ship; kept for the record.

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

3. **Consolidated `.candor/config` file — DONE across all four engines (2026-07-02); normative as
   SPEC.md §3.4.** A checked-in `key value` file replacing the `CANDOR_*` env wiring: shared 7-key
   vocabulary (inert-if-unimplemented, warn-if-unknown), target-anchored discovery (`$CANDOR_CONFIG`
   overrides), precedence CLI → env → config → default, fail-closed when configured-but-unusable.
   Conformance **PART 13** pins discovery/precedence/fail-closed per engine (1/0/2, all four green);
   `candor-init.sh` scaffolds it (policy + baseline wired, never clobbered). An additive amendment
   within 0.8 — configuration, not the wire contract. **First shipped in every engine's 2026-07-02
   release** (ts 0.8.3 / scan 0.8.3 / java v0.8.2 / swift v0.8.2) and carried by every release since
   (wave 2, 2026-07-10: ts 0.8.7 / scan 0.8.5 / query 0.8.1 / java v0.8.6 / swift v0.8.5 /
   agents v0.8.1).

4. **Distribution — CLEARED (2026-07-02).** The proven wedge is now on the site:
   [candor.poly.io/case-studies/](https://candor.poly.io/case-studies/) (the five studies, deployed) and
   the cross-model eval evidence on [candor.poly.io/agents/](https://candor.poly.io/agents/) (verified
   live). Remaining distribution is ongoing marketing, not a backlog item: keep the adopt starter + site
   current as the tools change (the site's engine versions self-update at build; fallbacks refreshed 0.8.x).

### Vocabulary + breadth track (opened 2026-07-14 — Tom: "yes, and privacy")

- **[P1] The `Llm` effect** — design done (candor-spec/LLM-EFFECT-DESIGN.md): a standalone boundary
  effect (the Db precedent) from SDK surfaces + the host literals we already extract; java-led minor
  rung; the sharpest gains/origin alarm ("your dep bump added an LLM call"). DECIDED (Tom 2026-07-14, all
  recommendations accepted). Next: the java reference implementation.
- **[P1] The privacy-sensor cluster** (Location/Camera/Mic/Contacts/Photos/Notify) — design done
  (candor-spec/PRIVACY-EFFECTS-DESIGN.md): swift-led; the product shape is privacy-manifest
  generate/VERIFY from code-level truth. SHIPPED (2026-07-14, code green): the
  privacy/1 SPEC EXTENSION (candor-swift/SPEC-EXTENSION-privacy.md + impl, 183 tests, envelope
  extensions disclosure, PART 4n tolerance pin). Six effects Location/Camera/Mic/Contacts/Photos/
  Notify. spec strings still 0.12 — rides the 0.13 floor bump with Llm. SHIPPED (2026-07-14): the privacy-manifest
  generate/verify verb (candor-swift b9a68a6, 196 tests) — the real-app exhibit is LIVE (pollen's iOS
  Info.plist under-declares NSContactsUsageDescription vs a real ContactsService reach). _Remaining:_
  per-target scoping (whole-tree scan caveat); a public marketing writeup.
- **[P2] Ledger-mined classifier breadth** (data from the 2026-07-14 four-ecosystem sweep):
  rust — mark ratatui/serde_json/serde_yml/toml/regex/sha2/color_eyre reviewed-pure (ratatui alone is
  3,345 disclosed calls across three real repos — the single loudest noise source) and CLASSIFY
  crossterm (terminal I/O) + tracing_subscriber (Log/Fs); jvm — classify the AWS SDK surfaces
  (S3 → Net/Fs, SES → Net; uflexi's top uncovered) + commons-io → Fs; swift — the uncovered list is
  the privacy cluster's fixture set (falls out of P1); ts — sweep came back fully covered.
  Practice: batch by ledger call-count, never speculative.

### New-capability bet — a possible commercial add-on

- **Supply-chain effect diff (productize `gains`).** The `gains` query already computes "effects a
  dependency surface gained across versions." Productized — "your bump of lib X added `Net` to a function
  that was pure" — this is capability-level dependency diffing, distinct from CVE matching, and something
  candor is uniquely placed to do (it already has per-function effects). Net-new (not mined-out); could
  stand as its own wedge / landing page. **Business model (Tom, 2026-07-01): appealing enough to consider as
  candor's first _commercial, closed-source add-on_** — a paid layer over the open `gains` primitive.
  candor's engines are fully open source, so a closed paid layer is a deliberate business-model departure
  (the open engines stay the credibility base; this rides on top), flagged as such.
  **PROTOTYPE — PHASE 0 BUILT 2026-07-10 (`~/git/candor-gains`, local only — NOT a public repo).**
  A version-pair driver (`candor-gains.mjs`) over BOTH ecosystems: npm (`npm pack` → candor-ts
  `--allow-js`) AND the differentiated JVM path (Maven Central jar → candor-java, no bundler noise).
  Tiers the delta — ⚠ boundary capability gained (exit 1,
  gate-able) / △ unresolved surface grew (bundler/dynamic) / · cross-cutting (informative). Two working
  exhibits: a deterministic offline synthetic (`greet` 1.0.0→1.1.0 adds an `https.get` phone-home →
  ⚠ Net in `greet`+`track`, via `./run-demo.sh`) and a REAL true-positive (`node-fetch 2.6.6→2.6.7`, the
  CVE-2022-0235 redirect fix → ⚠ Net in `finalize`/`abortAndFinalize`; control `ms 2.0.0→2.1.3` → clean).
  Prototype findings feeding productization: (1) bundled dist reads as Unknown — prefer un-bundled source;
  (2) `gains` alone is too blunt — it can't tell "a function that shipped PURE now does Net" (the
  attack) from "a new function does Net" (a feature) because reports omit pure fns; the driver fixes
  this by keying existence on the CALLGRAPH (⚠⚠ existing-code-gained vs ⚠ new-function tiers) — a
  candidate improvement to open `gains`/`diff` too **(DONE 2026-07-13, spec 0.12 staged: `gains --json`
  byFunction entries carry `origin: existing|new|unknown` in ALL FOUR engines — swift gained the whole
  verb — keyed on the baseline callgraph, pinned by conformance PART 5b; the driver can now consume
  `origin` instead of computing existence itself)**; (3) adjacent bumps are clean, large spans are
  refactor churn (→ watch releases incrementally); (4) the corpus==cache retains report+callgraph
  (the moat seed); (5) the exit-1 ⚠⚠ alarm is a CI gate / registry-watcher trigger.
  **STRATEGY (Tom, 2026-07-10): run it as a marketing WEDGE, but don't miss a SaaS if one surfaces.**
  The SaaS (if real) is NOT the diff tool (copyable, npm-crowded — Socket owns that) — it's the
  always-on/stateful/compounding layer a CLI structurally can't be: **continuous monitoring over an
  accumulated cross-language effect-history CORPUS**, JVM-first (no incumbent has a head start there).
  Full build spec: `candor-gains/PRODUCT-SPEC.md`. The one architectural commitment made now:
  **the cache and the corpus are the same store** — the wedge retains every scan (exhaust = moat seed;
  cheap now, expensive to retrofit). Phasing with decision gates: **P0 DONE** (JVM/Maven driver + corpus
  store — the differentiated path); **P1 DONE 2026-07-10** — `candor.poly.io/gains/` demand-probe landing
  page (`~/git/web` src/candor/gains, JVM-led exhibits + a "watch, don't just check" waitlist via
  pre-filled labelled GitHub issues, 3 ecosystem variants = the signal; no backend, no third-party;
  third door on the candor index; label `gains-waitlist` on tombaldwin/candor = the count). **GATE 1 NOW
  OPEN (Tom's, evidence-based):** do waitlist issues arrive, and are they JVM/enterprise (defensible →
  build P2) or npm-only (wedge only → stop)? **P2** (only past Gate 1) the live runner + continuous-
  monitoring service on the already-accruing corpus → GATE 2 (the commercial decision, priced to pull).

### Disclosure-refinement track (opened 2026-07-16 — from the academic referee pass)

The 2026-07-16 three-angle referee pass on the "disclosure-oriented effect analysis" write-up (PL-theory,
empirical-SE, industry-practitioner — reports local at `~/candor-paper/REFEREE-REPORTS.md`) surfaced a
cluster of REAL tool improvements, not just paper edits. The unifying thread: candor **already reason-tags
every `Unknown`** (`unknownWhy`: `dispatch:` / `reflect:eval` / `reflect:vm` / `reflect:require` /
`reflect-metadata` / `native:` / `callback:` / `closure` / `unresolved` / `missing-config`) but **nothing
quantifies over the reasons yet**. Make the reason first-class — in the policy language and in the UX — and
several of the reviews' dealbreakers dissolve at once. This is the tool-side of the paper's own §3 fix
(a signature is a `(determined-effects, reasons)` pair): reasons first-class in the model AND the product.

- **[P1] Reason-scoped `Unknown` policies** — **SHIPPED FOUR-WAY (2026-07-17), unreleased on main (targets spec 0.19)**.
  All four engines: `ReasonClass` projection {reflect,dispatch,indirect,native,unresolved,setup}, the
  `deny E Unknown[class…]` parser (`dynamic` alias, `*`/bare = all, A2 under-gating lint), the reason-scoped
  gate eval (fires only on a matching class; unrecorded → `unresolved` conservatively), **the reason CLASS
  propagated TRANSITIVELY at gate-eval time** (a caller inheriting a reflect-caused Unknown fires
  `Unknown[reflect]` — a transitive under-gating gap found+fixed during the port), and the **`reasonClass`
  verdict field** (§3.3; all classes on the fn, on an AS-EFF-006 Unknown denial). **SPEC §6.2 grammar
  written** (⟨0.19⟩). **Conformance**: PART 4 pins the parse (`unknownClasses`) four-way; PART 12 pins a
  representation-agnostic `reasonClass` structural invariant. Per-engine regression tests + four-way
  conformance green. Sibling: the **disclosure-completeness gate** (candor-java `DisclosureCompletenessTest`
  + `DISCLOSURE-COMPLETENESS-DESIGN.md`) shipped alongside. See [[candor-reason-scoped-unknown]].
  The config **`unknown-alias`** key ALSO shipped four-way (2026-07-17): a user-defined
  `.candor/config` `unknown-alias foo = reflect,native` referenced explicitly as `Unknown[foo]`,
  multi-value, discovered by walking up from the policy/scan target, honored by the gate AND the
  config-aware `parsepolicy` (pinned in PART 4 via a checked-in `.candor/config`). A config alias may not
  shadow a built-in and never changes what bare `deny E Unknown` means. **ONLY REMAINING piece of this
  item:** the `setup`-vs-genuine split (a loud scan-time setup diagnostic routing `missing-config`/
  `no-tsconfig` holes to "wire up your config", never a silent gate input; §3 of the design) — a small
  follow-on, not yet built.
  _(orig:)_ `candor-spec/REASON-SCOPED-UNKNOWN-DESIGN.md`.
  `deny Net Unknown[reflect,native,dispatch] domain` fires on the dangerous DYNAMIC reason classes but
  tolerates `Unknown[setup]`/benign `indirect`. The data is already emitted (`unknownWhy`, four-way); the
  design adds a fixed cross-engine **reason-class vocabulary** (`reflect`/`dispatch`/`indirect`/`native`/
  `unresolved`/`setup`) projecting the raw `unknownWhy`, plus the policy grammar filter — bare `deny E
  Unknown` stays `Unknown[*]` (back-compat, soundness-by-default). **Dissolves the industry referee's #1
  dealbreaker**: bare `deny E Unknown` is deny-all-able on DI/reflection-heavy code, so teams disable it;
  reason-scoping makes it shippable. Conformance PART pins reason-scoped verdicts four-way. **Highest
  leverage in this track**: smallest build (reuses existing data), biggest adoption unlock. Tier-2 rung,
  java-leadable. (The SETUP-vs-GENUINE split — routing `missing-config`/`no-tsconfig` to a loud scan-time
  setup diagnostic, never a silent gate input — is §3 of the same doc: it's the same reason-class mechanism,
  so it ships together.)
- **[P1] Completeness manifest — close the `absent ⇒ pure` hole** — DESIGN DONE + REALITY-AUDITED
  (`candor-spec/COMPLETENESS-MANIFEST-DESIGN.md`). The PL referee's finding: a SILENTLY-DROPPED effectful fn
  is indistinguishable from a provably-pure one (both absent from the report). **The 2026-07-16 four-engine
  audit shrank this**: the analyzed universe ALREADY exists — SPEC §2.2's callgraph sidecar records every
  analyzed fn incl. pure leaves (normative, four-way, load-bearing for AS-EFF-005). So the real work is three
  narrower gaps, not a new manifest: **(G1)** surface an `analyzed:{count,digest}` SUMMARY in the report
  envelope so a bare-report/`--gate-json` consumer answers analyzed-pure-vs-never-seen without loading the
  sidecar; **(G2, the sharp one)** a machine-legible `unanalyzed` field in the envelope AND gate verdict —
  parse-failures are disclosed on STDERR + fail the exit code today but are INVISIBLE to a JSON consumer, so
  an agent gets `ok:true` over unanalyzed source (a live machine-consumer cardinal-sin channel worth fixing
  regardless); **(G3)** verify/pin four-way that a truly-isolated pure fn is a callgraph node (ts derives
  nodes from edges → an isolated leaf may be missing — the residual §2.2 hole). Tier-1 additive + a §2.2
  conformance fix; pairs with `candor verify`.
- **[P2] `Net` destination-class refinement — answer the coarse-effects dealbreaker.** `Net` can't tell
  telemetry from exfiltration — the industry referee's hard blocker for anything security-framed. Generalize
  the existing `MODEL_HOSTS` machinery (already classifies `Net`→`Llm` by host): carry a destination CLASS
  on `Net` (`known-telemetry` / `known-partner` / `unknown-host`) from the host literals candor already
  extracts (const-anchored + literal-head resolution, spec 0.14). Unlocks the security use case the tool
  can't currently cash; a natural extension of shipped work. Bigger effort; a real vocabulary rung. Stay
  SOUND — an unresolved host stays bare `Net` (+ `unknown-host` class), never fabricated.
- **[P2] Standing dynamic honesty oracle (`candor verify`).** Productionize the oracle prototype (built
  local, `~/candor-paper/harness/`): run a candor report against a runtime syscall/interposition trace and
  confirm `observed ⊆ inferred ∪ {Unknown}` per executed fn. The empirical referee's RQ3 finding — that
  cross-engine conformance is the WEAKEST check, because shared blind spots hide from agreement (the
  Knight–Leveson result our own soundness log confirmed: write-fmt silent in all four engines) — is an
  argument to lean on the mechanism-INDEPENDENT oracle as a standing CI/soundness gate, not just
  conformance. The differentiator no competitor has: an analysis that checks itself against reality.
  Site-anchored attribution (wrap candor's own claimed direct-effect sites) sidesteps general stack
  unwinding.
- **[P2] `Unknown`-rate / disclosure metric as first-class output.** `candor blindspots --stats`: the
  reason-distribution (how much `Unknown`, by reason class) as a self-diagnostic, so a team can SIZE the
  blind-spot cost before turning on `deny E Unknown`. Cheap; answers the "is disclosure actionable or
  pervasive" question in production; feeds the setup-vs-genuine split.
- **[P3] Blame-tracked `Unknown`.** Join `unknownWhy` + the oracle: when a runtime effect escapes,
  attribute it to THE specific unresolved edge that should have disclosed it ("this `Net` came through the
  `reflect:vm` site at `foo.ts:42`"). Turns the oracle from yes/no into a debugger; the gradual-effects
  BLAME literature (Wadler–Findler lineage) is the formal home. Builds on `candor verify`.

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
    absolute grade; opt-in; **no AS-EFF code / not in conformance**. **AUDITED 2026-07-16 (grounded-and-
    accurate):** the metric §21 matches `candor-fingerprint.mjs:308-309` VERBATIM and `--baseline` (the delta
    the gate consumes) already works — the gate is a THIN layer over real, tested machinery, NOT blocked on
    feasibility or grounding. The `.candor/config`-for-thresholds open question is resolved (config shipped,
    §3.4). So the only real blockers are (1) a decide-or-shelve call and (2) threshold/noise-floor
    calibration — a short EMPIRICAL pass on real repos (run the gate over N recent PR pairs, see what
    `structure` deltas real regressions vs churn produce), not a design problem. Recommendation: it's cheaper
    to build than the "designed twice, never committed" framing implies. **DEFERRED (Tom 2026-07-17): important,
    but parked to focus on the paper + related findings; revisit after that push.** Design is grounded and
    ready — pick it up cold when the slot opens, no re-audit needed.
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

- **candor-ts κ-batch: common CLI-tool packages — ✅ DONE (candor-ts 0.9.2, 2026-07-12).** `which`→Fs,
  `@webpod/ps`→Exec, `envapi`→Fs (member-precise: parse stays pure); zx `useBash`/`usePwsh` now Fs, κ ledger
  7→4. Pure libs (chalk/minimist/depseek) left as honest `invisible` (not curated to a pure claim). 6
  regression tests incl. the parse-pure fabrication guard. Committed+pushed; **not yet published** (npm ships
  with the next candor-ts release, alongside 0.9.1's warning fix). Origin dogfood detail:
- **candor-ts κ-batch: model common CLI-tool packages (from the VALID 0.9 dogfood, 2026-07-12).** Re-scanned
  `zx` WITH deps installed (the honest redo) — the correction held (chalk/bufArrJoin → `invisible`, Unknown
  82→55, all 55 genuine `dispatch:`/`callback:`; Exec/Net/Fs attributed honestly even through the invisible
  `zurk` wrapper via the visible `cp.spawn`; **no cardinal sin**). The one real, source-VERIFIED precision
  gap: a few effectful packages read `invisible` where κ could attribute the effect — **`which`→Fs**
  (isexe/PATH stat; uniform, whole-module safe; broadly used — best ROI), **`@webpod/ps`→Exec** (spawn/exec;
  verify members uniform), **`envapi`→Fs+Env** (readFileSync of `.env` — but MIXED: `parse` is pure, so
  member-specific `load`/`config`/`write`→Fs, NOT whole-module, per the argon2/AWS blanket-grant lesson).
  Optionally curate the obvious-pure ones (`chalk`, `minimist`, `depseek` → pure) to drop invisible noise.
  Rules go in `candor-ts/scan-core.mjs` kappa table; gate with the fabrication probe + re-scan zx (useBash/
  usePwsh should gain Fs) + regression tests. Precision (invisible→attributed), improves `deny Fs`/`deny Exec`
  gate fidelity; baseline-invalidating (⚠). NOT a cardinal sin — the effects are disclosed via `invisible`
  today.


- **0.9 dogfood — RETRACTED precision finding + the real fix + a methodology lesson (2026-07-11/12).** The
  dogfood on real code did its job: it validated the release (candor-scan on xh honest via the κ ledger; the
  `candor fix` remedy on a real xh Net violation was correct + useful) — but its two candor-ts "precision"
  findings (`chalk.grey`→Unknown, `bufArrJoin`→Unknown) turned out to be a **testing artifact**: `zx` was
  scanned on `zx/src` **without `npm install`**, so imports/types didn't resolve → conservative Unknown.
  Proven by controlled fixtures: a *resolvable* uncovered package member-access → `invisible` (κ) not Unknown;
  the exact `bufArrJoin` shape is PURE when the type resolves. candor-ts was already correct; the scope doc
  (`candor-ts/HOF-PRECISION-DESIGN.md`) is **RETRACTED** (correction at its top). **Real fix shipped**:
  candor-ts's "no node_modules → npm install" warning was silent here because it only checked the scan *root*
  (I scanned `src/`) and only counted `dependencies` (chalk is a devDependency) — now walks up to the manifest
  + counts devDependencies + regression test, so an un-installed scan is warned instead of silently reading as
  spurious Unknowns. **Methodology lesson** (see [[feedback-dogfood-proactively]]): always resolve deps
  (`npm install` / build) before scanning a real project — unresolved imports invalidate the results.
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

- **Spec 0.9 — the remedial-loop rung (2026-07-11).** The ladder's second full cycle. 0.9 is a **tier-2
  (pinned-tool-surface) rung** (SPEC.md §"Conformance tiers", new): no report-schema or verdict change — a
  0.8 report and a 0.8 `--gate-json` verdict are byte-identical under 0.9 — but the **remedial tool loop**
  (`fix`/`fix-gate`, `unverified`, and the gate's provable-purity auto-disclosure) is promoted from
  shipped-but-optional into the pinned §3.1/§3.3 contract, so a 0.9-conformant engine MUST carry it. All
  code engines declare `0.9` at **0.9.0** (candor-java, candor-scan+candor-query, candor-ts, candor-swift;
  candor-agents rides behind at 0.9.0), per the convention that release major.minor tracks the spec. The
  **conformance suite now tags every PART tier-1 (interop floor) or tier-2 (tool surface)** — making the
  version trigger unambiguous: a tier-1 change bumps the floor, a tier-2 addition promoted to required does
  too, a patch touches neither. Conformance green four-way (incl. the 0.9 tool parts 12b/12c/12d).
  Committed across all repos; **not yet published** (awaiting an explicit ship — a re-publish of
  candor-query needs candor-classify 0.5.10 out first, the shared-predicate fold's new public API).
- **The measure-and-surface arc (2026-07-11).** A full loop, end to end: (a) the **owner digest** (P1–P3)
  — `candor-agents digest` renders an aggregate protection report over the gate log; the gate now logs
  outside the agent hook (`log-gate`) and delivers on a schedule (candor-agents 0.8.2/0.8.3). (b) **Family
  changelogs + `candor.poly.io/releases`** (link-out) + a standing "always cut a gh release" rule
  (RELEASING.md). (c) A **soundness wave**: ten cardinal-sin fixes across two engines — swift R22–R29 +
  R28 (0.8.7→0.8.10, the accessor + generic + conditional-conformance veins) and rust-scan R30/R31 (0.8.8,
  trait-default + generic-field) — **every FIXABLE silent under-report now closed+gated; the 7 remaining
  (R2–R8) are fundamental syntactic limits.** Validated on real third-party code (swift-argument-parser: no
  fabrication, Env ground-truth-correct) + the kernel oracle. (d) **Cross-model evals**: completeness holds
  tier-flat (~14–15/16, control 0–6, largest lift for the weakest model) and the token saving is consistent
  (~1.37×) from Haiku 4.5 to Fable 5 — pre-registered, 160 agents, blind-judged (`candor-rust/eval/scaled`,
  RESULTS-xmodel + RESULTS-speed-xmodel). The speed A/B is now runnable via subagents (per-agent telemetry
  is exposed). (e) The measured case is **surfaced** at `candor.poly.io/evidence/`. Soundness instrument
  (candor-spec/SOUNDNESS.md) fully updated throughout.

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
