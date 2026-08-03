# candor (umbrella) backlog

_Last reviewed 2026-07-20 (floors 0.18→0.23: the reason-scoped-Unknown, Net-destination-class, completeness-manifest and cross-package-interface-dispatch rungs all shipped; + a 0.23.1 engine-**performance** + classifier-soundness patch — the disclosure-refinement track is now mostly landed, with the `candor verify` dynamic oracle the standout open item). Per-engine detail: `candor-java/BACKLOG.md`, `candor-rust/BACKLOG.md`._

## Direction — next strategic bets (family-level)

> **AUDITED 2026-08-03.** Every entry was checked against the repos, not against its own prose. **8 of 13
> top-level entries were headed `[P0]`/`[P1]`/`[P2]` while their bodies — and the code — said SHIPPED.**
> They are re-headed below. This matters because the P-level is how the next task gets picked: scanning by
> it was wrong 8 times out of 11, and it misdirected a session earlier the same day (the "standing verify
> oracle" was already standing in all four arms).
>
> **METHOD, because the first two passes at it were themselves wrong.** A regex for "body says SHIPPED"
> matched done-claims belonging to LATER entries' sub-bullets and overstated the count as 9. And a
> recommendation made from an entry's own text ("digest phase 3 is the one confirmed-open item") was
> refuted by the spec it points at — all three phases are built, including the Slack push. **Read the
> artifact the entry cites, then the code; an entry describing its own state is a claim, not evidence.**
>
> **GENUINELY OPEN after the audit** — five items, and only two are code:
>   · `[P2]` `bin/release.sh` should RENAME `## Unreleased` (filed today; verified — no such handling exists)
>   · `[P2]` ledger-mined classifier breadth (per-engine κ classification work, batched by call-count)
>   · `[P3]` blame-tracked `Unknown` (needs `candor verify` as a foundation)
>   · `[gate]` structure-delta regression gate — DESIGNED, awaiting a go/no-go
>   · `[adoption]` embeddable fingerprint badge
> Plus, from the verify entry: promoting candor-rust's or candor-swift's dynamic oracle from a CI harness
> to a user-facing verb — a new feature, not productionization.



- **[P2 — privacy/1 vocabulary, 2026-08-03] Health and Motion are not in the six-effect cluster, and a
  real health app shows the gap.** privacy/1 covers Location / Camera / Mic / Contacts / Photos / Notify.
  It does NOT model `HKHealthStore` or `CMMotionManager`, so `NSHealthShareUsageDescription`,
  `NSHealthUpdateUsageDescription` and `NSMotionUsageDescription` are invisible to `privacy-manifest`.

  MEASURED on pollen (read-only; scanned a COPY in scratch, the repo was byte-identical afterwards):
  it uses `HKHealthStore` (1 file) and `CMMotionManager` (1 file) and declares keys for both — so **four
  of the nine usage keys across its two Info.plists are outside candor's vocabulary**. A `verify` that
  passes on such an app is silent about them, and an iOS reader would spot that immediately.

  Health/fitness is a whole app category, and the sensors are the ones users care most about. The work is
  the same shape as the original six (candor-swift `SPEC-EXTENSION-privacy.md`: classifier entries + the
  effect → key mapping + fixtures), so this is an extension rather than a design problem. It is also the
  honest prerequisite for the article below if that article uses a health app.

- **[P2 + CONTENT — 2026-08-03] Route `privacy-manifest` through the umbrella, and write it up.**
  **DEMO MATERIAL — pollen, measured 2026-08-03.** Scanned a copy of `Sources/ + Apps/ + Resources/` and
  verified against both Info.plists. Two REAL under-declarations, each in a different plist:

      Resources/Info.plist          exit 1  ✗ reaches Mic (iOSBlowMonitor.actuallyStart, …) — no
                                                NSMicrophoneUsageDescription
      Apps/PolleniOS/Info.plist     exit 1  ✗ reaches Contacts (ContactsService.resolve, SettingsView.body,
                                                …) — no NSContactsUsageDescription

  Both plists also carry the tool's own hedge: *"verdict is conditional on 22 uncovered modules"*. That
  line belongs IN the article — a tool that discloses its own blind spots while making a finding is the
  whole pitch, and it pre-empts the obvious "how do I know it saw everything?".
  **CAVEAT the write-up must not skip:** this scan treated the whole codebase as ONE unit, so "reaches" is
  across all targets. A per-TARGET verify (scan only that target's sources) is the correct way to run it
  and may clear one or both. The findings above are CANDIDATE under-declarations until run per target —
  and demonstrating the per-target run is probably the better article anyway.
  candor-swift's `privacy-manifest` verb is BUILT and working — verified end to end on a fresh fixture:

      GENERATE  Location → NSLocationWhenInUseUsageDescription (reached by: track)
      VERIFY    key missing   exit 1  ✗ code reaches Location (via track) but Info.plist declares none
                key present   exit 0  ✓ every accessed capability is declared
                corrupt plist exit 2  (fail-loud, never a silent empty answer)

  **The gap:** it is reachable only as `candor-swift privacy-manifest`. The umbrella does not route it, so
  `candor privacy-manifest` does not work — the same shape as the `candor verify` routing gap fixed in
  `bin/candor` on 2026-08-03. Small: a dispatcher case, swift-only, with the same "no arm for this
  language" refusal the verify routing now uses for rust/swift.

  **WHY IT IS ALSO THE BEST ARTICLE CANDIDATE WE HAVE** (Tom, 2026-08-03 — LinkedIn post or a
  candor.poly.io piece). It is the one feature with a consequence a reader already fears: an App Store
  rejection. The story writes itself and every beat is demonstrable in a terminal:
  · the reach is TRANSITIVE — a `Location` three calls deep through a helper still requires the key, which
    is exactly what grepping your source for `CLLocationManager` will not tell you;
  · the asymmetry is the interesting half — an UNDER-declaration is a rejection (exit 1), an
    OVER-declaration is an unused permission users can see (a warning, exit 0). Most tools do neither;
  · `Notify` maps to NO key, because notifications gate at runtime — a detail that shows the mapping was
    derived from how Apple actually works rather than pattern-matched;
  · it is generate AND verify, so it fits a CI story as well as a one-off audit.
  Needs a real demo app rather than the toy fixture above, and it should say plainly that it is swift-only
  today. Ties to the adoption thread and to `candor.poly.io/case-studies/`.

- **[P2 — onboarding, 2026-08-03] No engine's AGENTS.md leads to the umbrella `candor` command.** Each
  engine doc teaches a DIFFERENT command and none mentions the one thing the umbrella README calls *"the
  one thing you install"*:

      candor-rust    `cargo install candor-scan`  → `candor-scan`; Path B adds `cargo candor` + `candor-query`
      candor-ts      `npm i -g candor-ts@latest`  → `candor-ts`, `candor-ts-query`, `candor-ts-mcp`
      candor-java    `jbang candor@tombaldwin/candor-java`
      candor-swift   `swift build -c release` from a clone — no install step at all
      candor-agents  `pipx install git+…`         → `candor-agents`

  So an agent that lands in candor-rust and follows its contract gets a working `candor-scan` and never
  learns the umbrella exists. The near-miss is candor-rust's `cargo candor update` — a CARGO SUBCOMMAND
  that reads almost identically to the umbrella verb and is not it.
  This costs the things the umbrella is FOR: `candor doctor`, `candor verify`'s language routing, and one
  pin for the whole family. Five entry points teaching five command names is also the likeliest source of
  "which one do I actually run?".
  **UNBLOCKED — verified 2026-08-03**: `Formula/candor.rb` is on the tap's `origin/main` (at 0.25.0), so
  `brew install tombaldwin/tap/candor` works for a stranger today. (An older note in my own memory said the
  tap was "built and held unpushed"; that is stale, and I checked before filing rather than repeating it.)
  So this is a docs change only — add a "you probably want the umbrella" pointer near the top of each
  engine's AGENTS.md, keeping the per-engine path for people who genuinely want one engine.

- **[P2 — self-application, 2026-08-03] candor-ts does not gate itself.** Three of the four engines run a
  self-gate in CI — candor-rust (`Self-gate (candor on candor)`), candor-java (`Self-gate (candor-java on
  candor-java)`, which proves TWO halves separately because a prefix scope cannot exclude one sub-package
  from a `deny`), and candor-swift (`§7.12 — the engine holds its own boundary`). **candor-ts does not, and
  has no `.candor/policy` at all** where rust and java both do. It is the one repo with a shipping engine
  that could analyse itself and doesn't.
  It also covers the surfaces most likely to acquire an effect by accident — the LSP, the MCP server, the
  `verify` CLI. Same shape as the three that exist: a policy file plus a CI step. candor-java's comment is
  the argument: *"An effect-gate vendor whose own gate is red has no business gating anyone else."*
  NB a self-gate proves "our own code performs no forbidden effect" — it does NOT test the analysis. That
  is the oracle's job, and only candor-rust runs `realworld-oracle` continuously.

- **[P2 — release process, 2026-08-03] The release scripts have no tests.** `release-stage.sh` now performs
  ~18 edits across six repos and `release-preflight.sh` carries eleven checks, and NOTHING gates either.
  Building the stage script surfaced two real bugs purely by running it: a heredoc nested inside `$(...)`
  is a shell parse hazard, and `\1` immediately followed by `0.26.0` parses as group TEN (`\g<1>` is the
  only safe form). Both were caught by execution, neither by reading.
  A fixture repo tree (six stub repos with the version sites and a CHANGELOG each) plus assertions on the
  staged result would catch that class. The argument for doing it: these scripts now stand between a defect
  and a publish, which is exactly where an untested script is worst.

- **[P3 — DX, 2026-08-03] Local clippy is weaker than CI's, so "clippy clean" locally is not evidence.**
  `clippy 0.1.98` on this machine exits 0 on two adjacent `#[test]`; CI's stable toolchain errors
  (`duplicate-macro-attributes`). That cost a CI round-trip on 2026-08-03 — and the same commit had a
  stranded `#[test]` that SILENTLY DISABLED a liveness test, which local `cargo test` also could not see
  (the total stayed flat because a duplicated attribute registers the test twice).
  Fix is a pinned toolchain for local dev, or a line in AGENTS.md saying local clippy is ADVISORY and CI is
  the authority. Tiny, and it removes a false signal — which is worth more here than its size suggests.

- **NOT backlogged, recorded so they are not re-proposed** (checked 2026-08-03):
  · **candor-agents / candor-spec / the umbrella not self-gating** — no engine analyses Python, Markdown or
    shell. An honest absence, not a gap; filing it would create a permanently-open item. The umbrella's
    `bin/` is the one place in the family that genuinely reaches the network and spawns processes
    (`release.sh`), and nothing could gate it today without a shell engine — worth KNOWING, nothing to do.
  · **A family-wide sweep for version-coupled test assertions** — proposed after fixing one in candor-agents
    (`startswith("<!-- candor-agents 0.25")`), then MEASURED across all five suites: the only other hits are
    usage strings. It was a one-off, not a class, so the sweep is not worth an entry.

- **[CLOSED 2026-08-03 — as `release-preflight.sh` check [9], and my filing had the MECHANISM wrong]**
  **Work stranded under `## Unreleased` at release time.**
  I filed this as "`release.sh` inserts a heading above `Unreleased` instead of renaming it". It does
  neither: `release.sh` only READS a CHANGELOG, for the GitHub release body. Nothing in the pipeline
  renames the section at all — so it falls to a human, and at 0.25 nobody did, leaving four engine
  CHANGELOGs with shipped work under `## Unreleased` (the v0.25.0 tag contains the commits that wrote
  it). Fixed as a GATE rather than an edit: `release.sh`'s contract is that everything is already
  bumped, committed and pushed — it refuses to run on a dirty tree — so having it rewrite and
  re-commit a changelog mid-publish would contradict its own gate. Preflight is where "is this staged
  correctly" lives, and a gate that NAMES the fix beats a script that silently performs it.
  Fires only when a VERSION is being asserted (content under `## Unreleased` is the normal state
  during development, and failing everyday health checks is how a gate stops being read), ignores a
  QUALIFIED section (candor-rust's `## [Unreleased] (nightly lint)` has its own cadence), and ignores
  an EMPTY one. Verified both ways: 5 repos flagged when cutting 0.26.0, 0 when the section is empty.
  ~~ORIGINAL:~~ Cutting 0.25 left a stale `## Unreleased` heading sitting BELOW the shipped
  `## [0.25.0]` in four engine CHANGELOGs — the `v0.25.0` tag contains the commits that wrote that
  content, so it had shipped while still labelled unreleased. Anyone reading those files after the release
  would have taken shipped work for pending work. Fixed by hand in the 0.26 floor bump; the script still
  has the behaviour. The fix is one step in `release.sh`: rewrite the existing `## [Unreleased]` /
  `## Unreleased` heading to the version being cut, then start a fresh empty one.


Correctness and disclosure are well-shored and **cross-engine-verified**: the inherited-into-project silent-pure
vein class was found and closed across all major JVM persistence (candor-java κ batches 24–27) and
confirmed not a shared blind spot; the **real-world corpus campaign (2026-06-22)** fixed the last live
silent-under-reports in every engine, each gated by per-engine probes + the cross-engine conformance
differential. Undirected corpus probing is mined out (multiple consecutive clean rounds). The
deployability gate is shipped end-to-end (AS-EFF-005 ratchet, 006/008/009 policy, 010 containment,
conformance-pinned). The spec advances on a **version LADDER, not lockstep** (Tom, 2026-07-01 — SPEC.md
§"Versioning policy"): the reference engine may lead a minor/additive rung, the floor stays
conformance-pinned over the four code engines, breaking bumps stay lockstep. The ladder has run
fifteen full cycles: **0.8** (the `--gate-json` gate verdict), **0.9** (the remedial tool loop), **0.10**
(the canonical query grammar), **0.11** (the surprising-reach surface + corrupt-report loudness),
**0.12** (the gains `origin` field), **0.13** (the `Llm` effect + the `extensions` field / the
candor-swift `privacy/1` sensor extension + `privacy-manifest` verb), **0.14** (the top-level/initializer
unit — a cardinal-sin closure), **0.15** (the coverage envelope — the κ ledger travels with the
report, verdict-preserving verb conditionality — plus host-resolution recall and four corpus-found
soundness fixes), **0.16** (the callgraph-aware baseline guard — a formerly-pure fn turning effectful is a
gain, AS-EFF-005; Unknown-only gains stay advisory), **0.17** (query target validation — `where`/`callers`
fail loud (exit 2) on a typo'd effect or nonexistent fn, never a false empty at exit 0), **0.18** (the
trust-trio — the `--strict` advisory-verb CI gate + the surface/`tour` mostly-Unknown disclosure, hardened
by a Fable-model review that caught two latent cardinal-sin edges), **0.19** (reason-scoped `Unknown`
policies — `deny E Unknown[reflect,dispatch,…]` + the transitive reason-class + the `reasonClass` verdict
field; dissolves the DI/reflection deny-all-able dealbreaker), **0.20** (the `Net` destination-class —
`netClass` known-telemetry/known-partner/unknown-host + `deny Net[unknown-host]` + the `blindspots --stats`
reason-distribution), **0.21** (the completeness manifest — report/verdict `analyzed`+`unanalyzed`, a
fail-closed exit-2 incomplete verdict closing a machine-consumer cardinal-sin channel), and **0.23** (the
cross-package interface-dispatch rung — an additive `interfaceUnion` entry gated behind
`CANDOR_WORKSPACE_CHAIN`). The **floor is now 0.23** (all code engines at 0.23.x, **published + release-
verified live**: crates.io, npm via the OIDC/SLSA action, gh releases, java native binaries, the Homebrew
tap). **0.23.1 (2026-07-20, a WITHIN-SPEC patch — spec stays 0.23) is the newest:** an engine-**performance**
sweep (two super-linear cliffs killed family-wide — chaTargets memoize + Surface presort + worklist
fixpoints, all byte-identical-verified; see the versioning-ladder history) plus the `Llm` model-SDK
fabrication fix AND its review-caught silent-under-report correction (a denylist over the sound blanket,
never an allowlist — the denylist-over-allowlist rule); umbrella patched to 0.23.2 to fix a stale
`ENGINE_PIN` that had `candor update` fetching 0.18 engines under a 0.23 umbrella.

**Priority (Tom, 2026-07-01): the agent loop stays the north-star, with the JVM arch gate co-important —
fund both, demote neither.** The **agent edit-time feedback loop** is the cutting-edge, differentiating
bet (effect-aware feedback into a live AI coding loop is novel and hard to copy); the **JVM architecture
gate** is the solid-engineering wedge (proven, deterministic, sellable). This supersedes any reading of
the 2026-06-18 repositioning as *demoting* the agent angle — that made the gate the lead **sales** wedge,
not a reason to stop investing in the agent loop, which stays P0 below.

Value runs in **two parallel tracks**; within each, new *disclosure* capability is largely mined-out and the
spec advances only on the ladder (now at 0.23). Two caveats to "mined-out", learned since: (a) **engine
PERFORMANCE was net-new depth** — the 0.23.1 sweep found and killed two genuine super-linear cliffs (CHA
recomputation, O(V²) fixpoints) the earlier corpus rounds never surfaced, so "capability is mined-out"
never implied "the engines are as good as they get"; and (b) a code review before the 0.23.1 publish caught
a **cardinal sin a fix had just introduced** (an Llm-narrowing allowlist that silently under-reported Spring
AI streaming/embedding) — a reminder that new soundness holes can still be *created*, so the review-before-
ship discipline stays load-bearing. **Both tracks' build-outs are complete**:
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

- **[SHIPPED — verified 2026-08-03] Agent edit-time blast-radius feedback.** [`integrations/claude-code/`](integrations/claude-code/):
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

- **[SHIPPED — ALL THREE PHASES, verified 2026-08-03 against integrations/DIGEST-SPEC.md] The candor digest — make the silent gate VISIBLE.** Adoption/retention
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

- **[SHIPPED + PUBLISHED as floor 0.13 — verified 2026-08-03] The `Llm` effect** — design done (candor-spec/LLM-EFFECT-DESIGN.md): a standalone boundary
  effect (the Db precedent) from SDK surfaces + the host literals we already extract; java-led minor
  rung; the sharpest gains/origin alarm ("your dep bump added an LLM call"). DECIDED (Tom 2026-07-14, all
  recommendations accepted). Next: the java reference implementation.
- **[SHIPPED 2026-07-14 — verified 2026-08-03] The privacy-sensor cluster** (Location/Camera/Mic/Contacts/Photos/Notify) — design done
  (candor-spec/PRIVACY-EFFECTS-DESIGN.md): swift-led; the product shape is privacy-manifest
  generate/VERIFY from code-level truth. SHIPPED (2026-07-14, code green): the
  privacy/1 SPEC EXTENSION (candor-swift/SPEC-EXTENSION-privacy.md + impl, 183 tests, envelope
  extensions disclosure, PART 4n tolerance pin). Six effects Location/Camera/Mic/Contacts/Photos/
  Notify. spec strings still 0.12 — rides the 0.13 floor bump with Llm. SHIPPED (2026-07-14): the privacy-manifest
  generate/verify verb (candor-swift b9a68a6, 196 tests) — the real-app exhibit is LIVE (pollen's iOS
  Info.plist under-declares NSContactsUsageDescription vs a real ContactsService reach). _Remaining:_
  per-target scoping (whole-tree scan caveat); a public marketing writeup.
- **[P2] Ledger-mined classifier breadth** (data from the 2026-07-14 four-ecosystem sweep):
  **BATCH 1 DONE 2026-08-03 (candor-rust `c9b6941`): crossterm + ratatui, both `Ipc`.** And the filing was
  WRONG about ratatui: it said "mark reviewed-pure", but ratatui-0.29.0's `Terminal::draw`/`flush`/`clear`
  end in a backend flush and `backend/` writes to the terminal — marking the crate pure would have claimed
  purity over the one API that writes. Verified against the crate source in the local cargo registry, not
  argued. The render surface (widgets/layout/buffer/style — where the bulk of the 3,345 calls live) IS pure
  and is now covered rather than disclosed. `Ipc` because the tty is a user dialogue channel, the ruling
  dialoguer/console already carry.
  **THE DURABLE LESSON FOR THE REST OF THIS BATCH: calibrating a crate INVERTS the default.** An unmatched
  path stops being a disclosed blind spot and becomes a PURITY CLAIM — so "reviewed-pure" must mean
  *someone read the source*, and every remaining candidate below needs the same treatment ratatui just got.
  **BATCHES 2–4 DONE 2026-08-03 — the item is CLOSED except for one crate.** rust: `REVIEWED_PURE_CRATES`
  (a NEW mechanism — `CALIBRATED_CRATES` requires a live rule, so a pure crate cannot go there) covering
  serde_json / serde_yml / toml / regex / sha2, each checked against its registry source where every
  apparent I/O hit was a doc comment (`32cfb8c`); `tracing_subscriber` → Log + Env (`6916a24`). jvm: S3
  transfers naming a local File → Fs co-emitted beside Net (`9122c64`); commons-io needed NOTHING, it
  already carries the source/sink descriptor stance.
  **THREE OF THE FILING'S CLAIMS DID NOT SURVIVE READING THE SOURCE:** ratatui is not pure,
  tracing_subscriber has no Fs, and commons-io was already done. **`color_eyre` CLOSED 2026-08-03 by fetching and checking it: it is NOT pure** — reads
  RUST_BACKTRACE/RUST_SPANTRACE/COLORBT_SHOW_HIDDEN (Env) and `File::open`s SOURCE FILES to render code
  snippets (Fs, `config.rs:248`). **Four of the filing's claims did not survive the source.** It is also
  deliberately NOT calibrated: the file read sits in `impl fmt::Display for SourceSection`, reached when a
  report is rendered rather than via any named verb, so no rule can match it — and calibrating would turn
  that render path into a purity claim. Its calls stay disclosed. **THE ITEM IS NOW FULLY CLOSED.**
  **THE DURABLE DISTINCTION, needed three times in one batch:** a library moving bytes through a handle
  the CALLER opened is not charged (the caller's `open` carries it) — but `new java.io.File(path)` opens
  nothing, so an SDK that writes it IS the only place the Fs lives. Same-looking shape, opposite ruling,
  decided by what the caller actually does.
  Original filing, kept because the correction is the point: mark
  ratatui/serde_json/serde_yml/toml/regex/sha2/color_eyre reviewed-pure (ratatui alone is
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

**STATUS (2026-07-20): this track is mostly LANDED + PUBLISHED.** Reason-scoped `Unknown` shipped as floor
**0.19**; the `Net` destination-class + `blindspots --stats` as **0.20**; the completeness manifest as
**0.21**. What remains open, and the recommended next pick: **the `candor verify` dynamic honesty oracle**
(below, elevated to [P1 — NEXT]) — the empirical referee's RQ3 point is that cross-engine conformance is
the WEAKEST check (shared blind spots hide from agreement), so a mechanism-INDEPENDENT oracle that checks
the report against a real syscall trace is the highest-leverage remaining soundness work AND the paper's
load-bearing evidence. Blame-tracked `Unknown` [P3] builds on it. The per-item detail below is kept for
provenance; the SHIPPED items are marked in place.

- **[SHIPPED + PUBLISHED, floor 0.19] Reason-scoped `Unknown` policies** — **SHIPPED + PUBLISHED as floor 0.19** (was staged on main 2026-07-17).
  All four engines: `ReasonClass` projection {reflect,dispatch,indirect,native,unresolved,setup}, the
  `deny E Unknown[class…]` parser (`dynamic` alias, `*`/bare = all, A2 under-gating lint), the reason-scoped
  gate eval (fires only on a matching class; unrecorded → `unresolved` conservatively), **the reason CLASS
  propagated TRANSITIVELY at gate-eval time** (a caller inheriting a reflect-caused Unknown fires
  `Unknown[reflect]` — a transitive under-gating gap found+fixed during the port), and the **`reasonClass`
  verdict field** (§3.3; all classes on the fn, on an AS-EFF-006 Unknown denial). **SPEC §6.2 grammar
  written** (⟨0.19⟩). **Conformance**: PART 4 pins the parse (`unknownClasses`) four-way; PART 12 pins a
  representation-agnostic `reasonClass` structural invariant. Per-engine regression tests + four-way
  conformance green. Sibling: the **disclosure-completeness gate** (candor-java `DisclosureCompletenessTest`
  + `DISCLOSURE-COMPLETENESS-DESIGN.md`) shipped alongside. See the reason-scoped-Unknown / Net-class work.
  The config **`unknown-alias`** key ALSO shipped four-way (2026-07-17): a user-defined
  `.candor/config` `unknown-alias foo = reflect,native` referenced explicitly as `Unknown[foo]`,
  multi-value, discovered by walking up from the policy/scan target, honored by the gate AND the
  config-aware `parsepolicy` (pinned in PART 4 via a checked-in `.candor/config`). A config alias may not
  shadow a built-in and never changes what bare `deny E Unknown` means. The **`setup`-vs-genuine split**
  (§3) is **COMPLETE four-way** (2026-07-17) — by two mechanisms: **candor-ts** emits a per-fn `setup` tag
  (`no-node_modules:<pkg>` on a call into a declared-but-uninstalled dep — precise because it *resolves*
  types and npm import specifier == package) + a loud SETUP remediation; **candor-java / -rust / -swift**
  route the mis-config / uncovered-dep case to the κ **coverage ledger** (`invisible` + note), never a
  genuine `Unknown` (java `Candor.java:1364`), so the separation already holds — and a per-fn `setup` tag
  there would be UNSAFE (no clean import→package/module mapping ⇒ mis-tag ⇒ under-gate via `Unknown[dynamic]`
  excluding `setup`), so deliberately not emitted; **candor-swift** adds a SAFE scan-level SETUP *warning*
  (a `Package.swift` declaring deps with no fetched `.build/checkouts` → "run `swift build`"). **The whole
  reason-scoped track is now done** — the only genuine follow-on would be if a future java/swift build-file
  reader made a precise setup tag safe there (not currently worth the under-gating risk).
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
- **[SHIPPED + PUBLISHED, floor 0.21] Completeness manifest — close the `absent ⇒ pure` hole** — **SHIPPED + PUBLISHED as floor 0.21**
  (report/verdict `analyzed`+`unanalyzed`; the fail-closed exit-2 incomplete verdict closed a live
  machine-consumer cardinal-sin channel in java/ts/swift — see the completeness-manifest rung). Original
  framing kept for provenance — DESIGN DONE + REALITY-AUDITED
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
- **[SHIPPED + PUBLISHED, floor 0.20] `Net` destination-class refinement — SHIPPED + PUBLISHED as floor 0.20** (`netClass`
  known-telemetry/known-partner/unknown-host + `deny Net[unknown-host]`, fail-closed on a masked/runtime
  host — see the reason-scoped-Unknown / Net-class work). Original framing kept for provenance — DESIGN DONE
  (`candor-spec/NET-DESTINATION-CLASS-DESIGN.md`, 2026-07-17); answer the coarse-effects dealbreaker. `Net` can't tell
  telemetry from exfiltration — the industry referee's hard blocker for anything security-framed. Generalize
  the existing `MODEL_HOSTS` machinery (already classifies `Net`→`Llm` by host): carry a destination CLASS
  on `Net` (`known-telemetry` / `known-partner` / `unknown-host`) from the host literals candor already
  extracts (const-anchored + literal-head resolution, spec 0.14). Unlocks the security use case the tool
  can't currently cash; a natural extension of shipped work. Bigger effort; a real vocabulary rung. Stay
  SOUND — an unresolved host stays bare `Net` (+ `unknown-host` class), never fabricated.
- **[LARGELY DONE — re-surveyed 2026-08-03; the "productionize" ask has been met in all four arms]
  Standing dynamic honesty oracle (`candor verify`).** The entry below was written 2026-07-20 and asks for
  work that has since shipped. Measured state, per repo, from the workflow files:

      candor-rust   `realworld-oracle.yml` — strace, CONTINUOUS (every push + PR), exits non-zero on a
                    NEW silent under-report. Plus realworld-oracle-deep + disclosure-recall.
      candor-java   ci.yml's dynamic-oracle step — JFR + a leaf-instrumenting `-javaagent`; the file
                    itself says "this makes the runtime oracle a STANDING gate (was manual)".
      candor-ts     ci.yml — transitive-recall battery + the 20-case effect-set oracle; ships a
                    user-facing `candor-ts-verify` CLI.
      candor-swift  ci.yml — recall oracle (non-syscall, macOS) + strace lane (Linux);
                    `confirmatory-corpus.yml` is weekly and REPORTED-not-gated **by design** (a held-out
                    frozen corpus is evidence, not a ratchet — see FROZEN.md).

  **WHAT IS ACTUALLY LEFT is narrower and worth stating precisely: `candor verify` is a user-facing verb
  for the NODE and JAVA arms only.** rust and swift have real dynamic oracles, but as harnesses inside
  their own repos' CI — not as something a user can run on their own project. Until that changes the verb
  should refuse those targets rather than guess, which it now does (`bin/candor`, 2026-08-03): a
  Swift package used to fall through to the NODE arm and be told to "scan the project first (candor-ts
  <dir>)" — a remedy naming the wrong engine for the user's language, which costs a run to discover.
  Promoting either harness to a verb is the remaining work, and it is a new feature rather than
  productionization.

  ~~ORIGINAL ENTRY:~~ Productionize the oracle prototype (built local, `~/candor-paper/harness/`; also runs
  on this Mac via a Docker `rust:latest` + `--cap-add=SYS_PTRACE` strace container — runs via a Docker `--cap-add=SYS_PTRACE` strace container on this Mac;
  candor-java ships the production `io.poly.candor.verify` `-javaagent` (Trace.emit, ~1.0–1.3×) distinct from
  the soundness-corpus harness agent — candor-java ships the production verify `-javaagent`): run a candor report against a runtime
  syscall/interposition trace and confirm `observed ⊆ inferred ∪ {Unknown}` per executed fn. The empirical referee's RQ3 finding — that
  cross-engine conformance is the WEAKEST check, because shared blind spots hide from agreement (the
  Knight–Leveson result our own soundness log confirmed: write-fmt silent in all four engines) — is an
  argument to lean on the mechanism-INDEPENDENT oracle as a standing CI/soundness gate, not just
  conformance. The differentiator no competitor has: an analysis that checks itself against reality.
  Site-anchored attribution (wrap candor's own claimed direct-effect sites) sidesteps general stack
  unwinding.
- **[SHIPPED + PUBLISHED, floor 0.20] `Unknown`-rate / disclosure metric — SHIPPED + PUBLISHED as floor 0.20.** `candor blindspots --stats` (reason-class distribution, sizing) + `--class <c,…>` (drill-down filter), three-way (rust/java/ts), conformance PART 5c. The blindspots half of the design's reason-class integration; `unverified --class` is the small remaining companion. `candor blindspots --stats`: the
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

- **Floors 0.19 → 0.23 + the 0.23.1 perf/soundness patch (2026-07-17 → 07-20).** Four ladder cycles plus a
  within-spec patch. **0.19** reason-scoped `Unknown` (the DI/reflection deny-all-able dealbreaker — the
  academic referee's #1); **0.20** the `Net` destination-class + `blindspots --stats`; **0.21** the
  completeness manifest (fail-closed exit-2 incomplete verdict — a machine-consumer cardinal-sin closure);
  **0.23** the cross-package interface-dispatch rung (`interfaceUnion`, `CANDOR_WORKSPACE_CHAIN`-gated so a
  default report stays byte-identical). Then **0.23.1 (2026-07-20)** — a WITHIN-SPEC engine patch: an engine-
  **performance** sweep that killed two super-linear cliffs family-wide (java `chaTargets` memoize +
  `Surface.nearestSource` presort → 3.79× at 4585 classes; worklist `computeFixpoint`/`propagate` in
  java/rust/ts → O(V²)→linear on deep call graphs; swift O(N²) loop-invariant hoist → 8.4× — all
  byte-identical-verified, with one honest revert where the data didn't support it, swift's fixpoint) + the
  `Llm` model-SDK builder/ctor fabrication fix AND its **review-caught silent-under-report correction**
  (a workflow-backed high-effort review before publish caught that the first cut's dispatch *allowlist*
  silently under-reported Spring AI streaming/embedding — re-done as a denylist over the sound blanket;
  the denylist-over-allowlist rule). Umbrella patched to **0.23.2** to fix a stale `ENGINE_PIN` (it had
  lagged at 0.18.0 since the 0.18 ship, so `candor update` fetched 0.18 engines under a 0.23 umbrella;
  `release-preflight` now gates the pin — the umbrella-distribution notes). Published across every channel;
  release-verified live. Full ladder detail in the versioning-ladder history.

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
