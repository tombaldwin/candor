# candor (umbrella) backlog

_Last reviewed 2026-08-05 (floor 0.26 PUBLISHED; **0.27 staged across all six repos and unpublished** — `resolves` + §2 `fs` kinds travelling the call graph, conformance PART 31). Rungs 0.24 CONTRIBUTES/ambiguous, 0.25 ambiguous-join-key-UNIONED, 0.26 sidecar-key-set-is-its-manifest and 0.27 all landed since the previous review line, which still said 0.18→0.23 and was the first thing a new session read. Per-engine detail: `candor-java/BACKLOG.md`, `candor-rust/BACKLOG.md` (**month-stale — see the audit note below**), and — not previously linked from here — `candor-spec/SCAN-BOUNDARY-WORK-QUEUE.md`, which is where candor-ts's and candor-swift's open rows actually live._

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
> **GENUINELY OPEN — re-audited 2026-08-05, and the list had rotted again within 48 hours.** Two of the
> five below were already closed, and two entries elsewhere in this file still carry a P-level for work
> that shipped on 2026-08-04. That is the same failure the note above documents, recurring one day later,
> which says the problem is the format and not the diligence: **a heading is a claim, and nothing checks
> claims.**
>
>   · `[P2]` ledger-mined classifier breadth — **CLOSED 2026-08-03**, all four batches (see body below).
>   · `[P2]` `release.sh` should RENAME `## Unreleased` — **CLOSED**; `release-preflight.sh` [9] gates it
>     and `_stage_changelogs.py` performs the rename. The entry read "verified — no such handling exists".
>   · `[P1]` the umbrella's per-verb capability table — **the actionable half SHIPPED 2026-08-04** (`431b82d`):
>     the table, the refusal naming the engines that do implement a verb, and capability-aware `--help`.
>     What is left is the optional-in-spec-vocabulary design question the entry itself gates on a customer.
>   · `[P2]` privacy `Health`/`Motion` — **SHIPPED 2026-08-04 as `privacy/2`**, with read/write direction.
>
> STILL OPEN, and these were re-checked against the code:
>   · `[P1]` **value provenance** — filed below at last; two items now wait on it (see the note there).
>   · `[P3]` blame-tracked `Unknown` (needs `candor verify` as a foundation)
>   · `[gate]` structure-delta regression gate — DESIGNED, awaiting a go/no-go
>   · `[adoption]` embeddable fingerprint badge
>   · `[P2]` candor-ts self-gate (no `.candor/policy`, no self-gate step in its CI)
>   · `[P2]` each engine's AGENTS.md should point at the umbrella (none mentions it)
>   · publish-side release-script coverage — real open work currently hidden under a `[FIXED]` heading
>     below: `cargo publish`, the npm OIDC tag, `gh release create` and the Homebrew tap are exercised
>     only by a real release, and neither a dry-run mode nor stubs exist.
> Plus, from the verify entry: promoting candor-rust's or candor-swift's dynamic oracle from a CI harness
> to a user-facing verb — a new feature, not productionization.



- **[SHIPPED 2026-08-04 — research] Mechanise the formal model in Lean — the MODEL, explicitly not the
  code.** Raised by Tom. `candor-spec/lean/`: **75 tier-A theorems with no axiom dependencies**, 7 bridge
  lemmas, a 147 400-row differential against `reference/policy_model.py`, and CI. Transcribed: §1's lattice
  and policy verbs, §2's transitive rule as a least fixpoint, §3's honesty invariant H, §4's Theorem 1 from
  (A0)–(A3), §5 blame, §8's four escapes, Prop 4 and Prop 6. `check.sh` asserts no `sorry`, two axiom tiers,
  a COMPLETE theorem registry, and the differential — each probed with a planted fault.

  **What it actually bought, against the prediction below that it would "prove the part that has never been
  wrong":** six defects, none of them in the algebra. In the model's own instruments: the Effect vocabulary
  was 7 where the engines are judged in 11; the differential quantified over 22 000 signatures no engine can
  emit; Theorem 1 was stated with plain containment where Definition 3 reads it modulo `⊑ₑ`. In PAPER3:
  Proposition 6's proof and Escape 2 both instantiate on `Db ⊑ₑ Net`, retracted by the Definition 2
  amendment and never propagated — and PAPER1 still carried the un-amended preorder outright, plus an
  evidence claim (the 5432 datapoint) whose verdict flips. All corrected. **The prediction was wrong in a
  specific way worth keeping: the algebra was indeed never wrong, but transcribing it is what made the
  STATEMENTS AROUND it checkable, and that is where everything was.**

  The residual is one item, tracked separately below (Definition 19's per-thread extent). The original
  framing is kept below because its reasoning about scope still governs.

  **REVISED UPWARD 2026-08-03 after asking "how do we prove the SPEC implements the PAPER?" — the answer
  is that we largely do not, and this is the missing link rather than a luxury.** What exists is
  `reference/policy_model.py`: a HAND TRANSCRIPTION of PAPER3 Definitions 1–7, 30–32, 35, 36 and Lemma 2
  into executable Python, which conformance PART 23 runs the engines against. That is real and it earned
  its place (it exists because a shipped engine took `deny Unknown[unresolved]` from REJECT to PASS when a
  call was ADDED — a counterexample to Lemma 2's corollary that no engine-vs-engine differential could
  catch). But note what it is and is not:
    · it checks ENGINES against a TRANSCRIPTION, never the spec text against the paper text;
    · coverage is the POLICY LAYER ONLY — §2's transitive rule, §3's honesty invariant, §4's Theorem 1
      and its A0–A3 antecedents, §5 blame, §7 monotone denial and §8 escapes are untranscribed and
      unchecked; *(all of these are now transcribed — see the SHIPPED note above)*;
    · **the transcription is itself an unverified, trusted artifact** — and it is known to have needed
      correcting (Definitions 33/34 deliberately dropped because they "describe verbs the deployment does
      not have", Proposition 5 rescoped as a result).
  So the theory↔spec link is maintained entirely by humans reading two prose documents side by side.
  `clause_check.py` proves a property cites a real SPEC clause; nothing relates the spec to the PAPER.
  Mechanising therefore does two things I undersold: it REPLACES the hand transcription with a checked
  artifact, and it EXTENDS coverage from the policy layer to the model's core. That reframes the work from
  "proving the part that has never been wrong" to "closing the one link in the theory↔spec↔code chain with
  no machinery at all". Tom's framing (2026-08-03): *these will help tease out any issues with the paper*
  — and the precedent supports it, since the first theory↔spec differential found the THEORY wrong twice.

  **WHAT IT WOULD BUY: the removal of human proof error.** The formal reference (PAPER3, local-only)
  survived four adversarial passes — *two of which existed only because my own repairs were wrong* — and
  the 2026-07-27 theory↔spec differential found the THEORY wrong twice (`pure` 15/256 → 0; `deny Net` on
  `{Db}` 100 rows → 0, both traceable to one sentence in §1 that had propagated into a definition). Those
  are exactly the failures a proof assistant makes impossible. Mechanising §1–§3 and Theorem 1 (the
  disclosure lattice, signatures + the transitive rule, the honesty invariant, monotone denial, policy
  semantics, blame localisation) would retire that class permanently.

  **WHAT IT CANNOT BUY, and this is the reason it is P3 and not P1.** Theorem 1 is CONDITIONAL on four
  antecedents — (A0) enumeration completeness, (A1) disclosure of every unresolved site, (A2) direct
  soundness with a transitively-closed library model, (A3) call-graph soundness modulo disclosure. Those
  are not theorems; they are empirical claims about what a third-party library does and about whether a
  front-end's view of a call matches the runtime's. **Every cardinal sin this project has ever fixed is an
  A0–A3 violation; none has been an error in the algebra.** From 2026-08-03 alone: `super.m()` into a
  chained dep (A3, missing edge), the static read forcing an unseen `<clinit>` (A1/A3), implicit
  stringification of an unscanned type (A1/A3), and the ratatui / tracing_subscriber classifier
  corrections (A2). A full mechanisation would prove, with total rigour, the part that has never been
  wrong. Discharging A0–A3 is the syscall oracle's job and the conformance suite's, which is the right
  division of labour and should stay that way.

  **NO ENGINE REWRITE.** Lean extracts to C; the engines are Rust/Java/TS/Swift, three of them bound to
  ecosystem front-ends (ASM, SwiftSyntax, the TS compiler API) that are the actual source of defects.
  Proving the shipped code would mean rewriting it and would STILL leave an unproven refinement gap
  exactly where the bugs live. Model-only, engines untouched, used as an oracle — which is what the
  self-differential properties already do informally. Natural first targets because they are literally
  theorem-shaped: **P1 split-invariance** and **P4 signature monotonicity**.

  **A LEAN ENGINE: NO — and the reason is worth keeping.** Lean already does candor's job: effects live in
  the type system, `IO` is in the signature. candor's entire value is finding effects a signature does NOT
  declare, so in Lean or Haskell the compiler has already answered the question. The languages where
  candor is valuable are precisely those where ambient authority is invisible. If anything an
  effect-typed language is a REFERENCE ORACLE for testing candor, not a target for it.

  Fits alongside the OOPSLA paper as a side artifact; costs no engine work; do not start it while
  anything on the A0–A3 side is open.

- **[P3 — research, 2026-08-04] The Lean model does not carry Definition 19's PER-THREAD dynamic extent,
  and right now that is a code comment rather than a tracked gap.**

  `Honesty.charged` collects `obs` along `ExecReaches` with no notion of threads. PAPER3 Definition 20
  additionally requires the reached frame to have executed *within `f`'s per-thread dynamic extent*, and
  Definition 19 is explicit that an effect issued on a **different** thread `f` spawned or handed a task to
  is **outside** it. So a `Run` whose `execCall` crossed a thread boundary would be one the paper does not
  sanction, and **nothing in the development would object** — `charged` would silently be too big and H⁺
  correspondingly too strong.

  It is not currently a false theorem: the model has no `spawn`, so there is no cross-thread edge to wrongly
  include. It is an unstated assumption, and it is written where unstated assumptions go to be forgotten —
  in a docstring. **Standing lesson this repeats exactly: a limitation written as a comment reads as
  CONSIDERED, which is what stops it being measured** (candor-swift's parse-error cardinal sin sat behind an
  accurate comment for months).

  **Closing it means modelling Definition 16b's labelled transition system** — `call`/`ret`/`spawn`/`issue`/
  `exit` steps over a per-thread state map `σ : T ⇀ Frame*` — which is the one part of §3 `Frames.lean`
  deliberately did not build. `Frames.lean` models the enclosing CHAIN (the structure Definitions 18–20 and
  Proposition 4 consume) but not the step relation that produces it.

  **Why it is worth more than tidiness, and also why it is P3.** This gap sits on the exact boundary the
  paper itself records as OPEN — Remark 6 and Table 1 row 2, the **thread-pool handoff**: a submitting frame
  performs an ordinary `call` into library code, and the task body later runs on a worker whose stack never
  contained the submitter. PAPER3 says that is "not an omission to be repaired by adding a label; it is the
  *reason* the cross-thread boundary of Definition 19 exists", and that any extension making the handoff an
  edge "would also have to say what `charged` means across it, which is precisely the open design question".
  So mechanising the transition system would not settle the research question — but it would make the
  boundary a hypothesis the theorems carry rather than a sentence in a comment, and it is the natural place
  to state whatever answer that question eventually gets.

  **AND THE ENGINE-SIDE HALF OF THIS BOUNDARY IS TRACKED NOWHERE.** I first wrote this item pointing at "the
  disclosure-refinement track's open row" for cross-thread/task-submission; grepping for it found nothing —
  the only `thread` hits in that track are `thread` meaning workstream. So the cross-thread handoff is a
  named open question in PAPER3 (Remark 6, Table 1 row 2) with **no backlog item on the tool side at all**.
  That is the gap to file next, and it is the larger of the two: what should an engine emit at a
  task-submission site whose body runs on a worker — a disclosure with which reason class, or nothing? The
  Lean gap above is that question seen from the model end; neither should be picked up without the other.

  (Filing that engine-side item is deliberately left as a decision rather than done here: it needs a ruling
  on whether task submission gets its own reason class or rides an existing one, which is Tom's call and
  changes what four engines emit.)

- **[MOSTLY SHIPPED 2026-08-04 `431b82d`; the remainder is customer-gated design — umbrella/spec
  convention, filed 2026-08-03] The umbrella has no notion of WHICH VERBS AN ENGINE
  IMPLEMENTS, and engine-specific verbs are unreachable through it.**

  **MEASURED (counted programmatically — my first hand-count of this got two of three numbers wrong).**
  `bin/candor`'s `QUERY_VERBS` is a flat, engine-agnostic list of **19**; candor-swift's CLI accepts
  **9**; the overlap is **7** (`parsepolicy fix fix-gate unverified tour path gains`). So:

      12 verbs the umbrella ROUTES that candor-swift does not implement
         (show where callers map containment diff reachable impact blindspots whatif rewire agents)
       2 verbs candor-swift HAS that the umbrella cannot route
         (privacy-manifest, gate)

  `engine_present` answers *"is it installed?"*, never *"does it support this?"*. Both directions fail,
  and neither fails HONESTLY:

      candor privacy-manifest      → "unknown action 'privacy-manifest'"   (umbrella doesn't know swift has it)
      candor show <fn>  on Swift   → "candor-swift: no such path: <fn>"    (engine got a verb it lacks and
                                                                            read the FN NAME as a path)

  The second is the worse one: it blames the user's argument for a capability gap, which is the opposite
  of the "failures carry remedies, nothing dead-ends" rule the rest of the CLI follows.

  **WHAT ALREADY EXISTS, so this is narrower than it looks.** SPEC ⟨0.13⟩ has a developed extension
  mechanism for the DATA plane: an ecosystem-specific surface may be led by the motivated engine as a
  `SPEC-EXTENSION-<name>.md` in its own repo; the envelope discloses `"extensions": ["privacy/1"]` *"so a
  consumer can tell an extension effect from a typo"*; there is a promotion path (into the spec when a
  second engine implements it, or direct adoption, whose text becomes the differential's oracle); and the
  governing line is *"An extension never holds the shared floor back and a floor claim never speaks for
  it."* **None of that says anything about VERBS.** The extension mechanism describes the data an engine
  may ADD and is silent on the commands it may add.

  **THE CHEAP FIX (do this first).** A per-verb engine table in `bin/candor` — which verbs each arm
  supports, plus the engine-only ones — so `candor privacy-manifest` routes to swift and `candor show` on
  a Swift project says *"candor-swift does not implement `show`; the engines that do are …"* instead of
  blaming the argument. No wire change, no spec change. This is the same shape as the `candor verify`
  language-arm refusal added 2026-08-03.

  **THE DESIGN QUESTION (do NOT build until it has a customer).** Tom's wider point: should the spec
  define vocabulary/features that are OPTIONAL for engines? **The hazard is exact and it is the one this
  project spent 2026-08-03 removing twice: absence is a claim.** If the spec defines `Health` as optional
  and an engine does not implement it, that engine's silence is ambiguous between *"no health access in
  this code"* and *"I do not look for health"* — precisely the ambiguity ⟨0.26⟩ closed for sidecar keys
  and for the §5 reconciliation trio. So optional-in-spec vocabulary is safe ONLY alongside a positive
  capability declaration; without one it reintroduces the defect at the vocabulary level.
  **⟨0.27⟩ SHIPPED THAT PREREQUISITE for refinement surfaces: `resolves` is the positive declaration**,
  so an absent optional field means "undetermined" only where the surface is declared. The open half is
  now the customer question, not the design one.
  The encouraging half: `extensions: [...]` is ALREADY that shape — a positive declaration of what is
  active — so the manifest would be a generalisation rather than a new concept.
  Counterweights, stated so the decision is made with them in view: it is more machinery on the wire; and
  the spec currently draws a hard line that the FLOOR is what every engine meets, which optional-in-spec
  vocabulary blurs. (Extensions already blur it — but in the engine's own repo, where a consumer is less
  likely to look, which is an argument on both sides.)

- **[SHIPPED 2026-08-04 as `privacy/2`, with read/write direction — filed 2026-08-03] Health and Motion are not in the six-effect cluster, and a
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
  **DEMO MATERIAL — pollen, RE-MEASURED PER TARGET 2026-08-04 (candor-swift 0.26.0 built + installed).**
  The 2026-08-03 numbers were from a single whole-codebase scan, which the entry itself flagged as
  candidate-only. Run per target, ONE OF THE TWO DISSOLVES AND THE OTHER GETS MORE INTERESTING:

      whole-codebase → Resources/Info.plist   exit 1  ✗ Mic          ARTIFACT — see below
      macOS target   → Resources/Info.plist   exit 0  ✓ clean (3 effects)
      iOS target     → Apps/PolleniOS/Info.plist exit 1 ✗ Contacts   REAL

  · **The Mic finding was a methodology artifact.** `iOSBlowMonitor` lives only in `Sources/PolleniOS`,
    which the macOS app does not compile. Scanning all targets as one unit charged an iOS-only sensor to
    the macOS plist. Per target the macOS app is clean, and the iOS plist *does* declare Microphone.
  · **The Contacts finding survives, and is the better story.** `ContactsService` is in `Sources/PollenCore`,
    which `PolleniOS` depends on, so the Contacts API is compiled into the iOS binary — while
    `Apps/PolleniOS/Info.plist` declares no `NSContactsUsageDescription`. **Grepping `Sources/PolleniOS`
    for Contacts returns nothing**: the only callers are in `Sources/PollenApp/Views.swift`, the macOS app.
  · **candor's own output distinguishes linked-from-called, if you read it.** The iOS run's reached-by list
    is exactly `ContactsService.isAuthorized, ContactsService.resolve` — the API's own wrappers and no
    callers. The macOS run's is `…, SettingsView.body, …` — a real call site. So the iOS exposure is
    binary-level (the API is linked; Apple scans binaries) rather than a runtime crash path, and the fix is
    either declaring the key or keeping `Contacts.swift` out of the iOS target's module.

  Both runs carry the tool's own hedge: *"verdict is conditional on 15 uncovered modules"*.

  Both plists also carry the tool's own hedge: *"verdict is conditional on 22 uncovered modules"*. That
  line belongs IN the article — a tool that discloses its own blind spots while making a finding is the
  whole pitch, and it pre-empts the obvious "how do I know it saw everything?".
  **The caveat was right and is now discharged** — the per-target run cleared one finding and kept one, so
  the article's spine is *the methodology*, not the count: run it per shipped binary, because scanning a
  monorepo as one unit charges every target with every other target's sensors.
  candor-swift's `privacy-manifest` verb is BUILT and working — verified end to end on a fresh fixture:

      GENERATE  Location → NSLocationWhenInUseUsageDescription (reached by: track)
      VERIFY    key missing   exit 1  ✗ code reaches Location (via track) but Info.plist declares none
                key present   exit 0  ✓ every accessed capability is declared
                corrupt plist exit 2  (fail-loud, never a silent empty answer)

  **The routing gap is CLOSED (2026-08-04):** `candor privacy-manifest` now routes to candor-swift via the
  umbrella's per-verb capability table, and `candor gate` with it. See the capability item above.
  **⚠ THIS ROUTING HALF IS A SUBSET OF the "umbrella has no notion of which verbs an engine implements"
  item above** — `privacy-manifest` is one of the two engine-only verbs that item counts, and building the
  per-verb table there routes it for free. Do NOT do them separately. What is unique to THIS entry is the
  CONTENT half below; the routing is listed here only so the article is not written about a command that
  still fails through the umbrella.

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

- **[FIXED 2026-08-04] The release scripts have no tests.** `bin/release-test.sh` — 29 assertions against a
  throwaway fixture tree of six stub repos, gated in CI by `release-scripts.yml` on any change to `bin/` or
  `scripts/`. Every assertion was probed by re-introducing the defect it exists for and watching exactly one
  fail. It found a TENTH defect while being written: `release-stage.sh`'s header claimed "re-running is a
  no-op that reports already at", and it was false — the callers' patterns match ANY version, so a re-run
  rewrote every site with identical bytes and reported ~14 edits. A run that reports edits when nothing moved
  hides the one release where something did; `sub` now distinguishes matched-but-unchanged from no-match.

  **The residual, stated rather than implied:** the publish calls — `cargo publish`, the npm OIDC tag,
  `gh release create`, the tap — are still exercised only by a real release. They need a dry-run mode or
  stubs, and neither exists. Eight of the nine original defects were on the tested side of that line.

  *(original entry)* **The release scripts have no tests.** `release-stage.sh` now performs
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
  · ~~**A family-wide sweep for version-coupled test assertions**~~ — **REOPENED AND FIXED 2026-08-04.
    The measurement was wrong.** This entry recorded that a sweep found "the only other hits are usage
    strings", so the class was closed as a one-off. The ⟨0.27⟩ floor bump then turned **every repo red**:
    four assertions in candor-agents' own `test.py`, three in candor-java's `smoke.sh`, several in
    candor-rust's cli tests plus its integration script and its doc-drift gate, and README / AGENTS /
    package.json in candor-ts.

    The sharpest instance: candor-agents' `test.py` carries a comment explaining that a version-coupled
    assertion "is the same hand-edit class that cost the 0.25 release" and derives ONE constant — while
    four assertions in the same file hardcoded `"0.26"`. The lesson was written down and not generalised.

    **Fixed by DERIVING, not by re-editing literals**: `_SPEC` from `candor_agents.scan.SPEC`,
    `SPEC_DECLARED` grepped out of `Candor.java` and `candor-report/src/lib.rs`. candor-swift needed no
    change — its `smoke.sh` already derived `$BSPEC` from the binary, which is why it caught its own stale
    README rather than passing. That is the shape the rest now match.

    **What a find-and-replace sweep would have broken**, and why this was fixed by reading each site:
    candor-rust's `tests.rs` builds fixture reports declaring `"spec": "0.26"` — those are INPUTS proving
    an older report still loads, so pinning them to the previous floor is their purpose. A blanket bump
    would have silently deleted a backward-compatibility test.

    **Standing lesson: "I measured it and it was a one-off" is a claim with a shelf life.** The measurement
    was true when taken and false one rung later, because every new assertion is written by someone who has
    not read this entry.

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
  Info.plist under-declares NSContactsUsageDescription vs a real ContactsService reach).
  **PER-TARGET SCOPING DONE 2026-08-05** (`candor-swift . --target <name>`, riding 0.27): resolves the
  target's in-package dependency closure from Package.swift and scans exactly those sources, so the
  whole-tree caveat is a flag rather than a hand-built Package.swift per binary. Measured on the real
  app: whole repo → ✗ Mic ✗ Motion against the macOS plist (the artifact); `--target Pollen` → exit 0
  clean at 4 effects; `--target PolleniOS` → exit 1 on Contacts, the finding that survives correct
  methodology. Two soundness bugs found while building it, both in the see-less direction: `.target(
  name:)` inside a `dependencies:` array parsed as a second target DECLARATION (phantom entry with no
  deps, so the closure walk could stop early and drop sources), and a scoped report was joinable as the
  WHOLE package (every unscanned function then a purity claim) — fixed by qualifying the key to
  `<pkg>/<target>#…` so a miss is disclosed. SOUNDNESS-LOG 2026-08-05; the vein was checked in
  candor-rust and candor-ts and is NOT there.
  _Remaining:_ the public writeup — `candor/docs/case-study-privacy-manifest.md` is written, every
  factual claim re-measured against the current engine, and awaiting Tom's publish decision. It needs
  0.27 published first (it documents `--target` and the read/write direction).
- **[P1 — the `unanalyzed` manifest covers files that FAILED, not files never CONSIDERED. MEASURED in
  three engines 2026-08-05.]** A source file inside the package that the engine's file-set rule skips is
  absent from the report AND absent from `unanalyzed` AND absent from the coverage ledger. Under ⟨0.21⟩
  absence from `functions` is a positive purity claim, so this is the cardinal-sin shape at FILE
  granularity — and the ⟨0.21⟩ machinery built to catch exactly this is never fed by the file-set decision.

  Reproduced, each on the tip engines:

  | engine | the skipped file | result |
  |---|---|---|
  | candor-ts | `src/deploy.js` calling `child_process.execSync("curl … \| sh")`, beside one `.ts` file | `deny Exec` → **`policy ✓`, exit 0**; `1 files` analyzed; `unanalyzed: None`; `coverage: null` |
  | candor-rust | `build.rs` running `Command::new("curl")` — the canonical supply-chain vector, executing at BUILD time | `functions: []`, `analyzed.count: 1`, `unanalyzed: None` |
  | candor-swift | `Sources/App/legacy.c` calling `system("curl … \| sh")`, in the scanned target | `analyzed.count: 1`, `unanalyzed: None` |

  **A REVIEW CLAIMED THIS WAS WORSE THAN IT IS, AND THE CORRECTION IS THE USEFUL PART.** A `.js`-ONLY
  package is fail-closed: candor-ts exits **2** with "no TypeScript sources under .". The hole opens only
  once at least one `.ts` file exists — i.e. exactly the mixed/gradual-migration repo that is the norm in
  that ecosystem, and never in the toy case someone would use to sanity-check the tool. Do not file this
  as "candor-ts ignores .js"; it does not, until it has a reason to look like it is working.

  The line is drawn INCONSISTENTLY inside one engine, which is the tell: a `.ts` file that fails to PARSE
  correctly exits 2 with "a gate cannot be green over unanalyzed code", while a file that was never
  considered passes silently. Same package, same invisibility, opposite verdict.

  **The fix is the one already designed:** enumerate the package's source-file universe from the manifest
  and the filesystem (a glob, NOT the import graph — the import graph cannot see a file nothing imports,
  and `build.rs` is reached by cargo, not by `lib.rs`), and put every in-scope file the engine did not
  analyse into `unanalyzed`. Existing ⟨0.21⟩ machinery then makes a configured gate exit 2 with no new
  concept. Separately decide, per engine and explicitly rather than by omission: `build.rs`, `tests/`,
  `examples/`, `.js` under `allowJs`, and non-Swift sources in a Swift target.

  Four engines plus a spec sentence, so it wants a rung and a conformance PART — filed rather than
  patched. **This is the highest-value item on this list**: it is the one class where the product's
  central promise ("never a silent false clean") is measurably untrue on ordinary inputs.

- **[SHIPPED 2026-08-06 — ⟨0.27⟩ SPEC §4, four-way, conformance PART 32] A policy rule that matches ZERO
  functions passed silently, and `unverified` then called the layer "PROVABLY clean".**

  Found by a usability review; reproduced in candor-rust, candor-swift, candor-ts AND candor-java (it did
  not differ). Now DISCLOSED in all four, with the verdict and exit code deliberately unchanged — a
  zero-match rule is legitimate when one policy is shared across repositories. A scopeless `deny` is
  exempt: it binds every function by construction, so it can never be this typo. Kept for the record;
  the original write-up follows. A one-character typo in a LAYER name turned a failing gate green:

      deny Net orders   →  exit 1   (the real layer; a genuine violation)
      deny Net ordrs    →  exit 0   "candor-query gate: policy ✓"
      candor unverified --policy <that>
                        →  "every function in a pure/deny layer is PROVABLY clean (no Unknown holes) ✓"

  **The asymmetry is the tell.** A typo'd EFFECT token is loud — `deny Netz orders` exits 2 with
  "names no known effect (accepted: Clipboard, Clock, Db, …)" and refuses to evaluate. A typo'd LAYER
  token binds nothing and is scored as satisfied. Same file, same rule, opposite treatment.

  This is the cardinal sin at GATE level rather than at report level: not a silent under-report by the
  analyzer, but a silent PASS by the thing users actually act on, wearing a "provably clean"
  endorsement. A team can hold a permanently green gate over a typo and never learn.

  **THE FIX IS DISCLOSURE, NOT REFUSAL, and the spec already says so.** Exit 2 would be wrong: a
  zero-match rule is legitimate when one policy is shared across repos or modules and a layer exists in
  only some of them. But silence is also wrong. ⟨0.24⟩ §3.1 already rules that **an unanswerable
  condition must be DISCLOSED, never scored as a satisfied one** — a rule that binds nothing is exactly
  an unanswerable condition, so this is that rule applied to the policy layer rather than a new concept.
  Minimum: report each rule's match count and name the zero-match rules in the verdict. The
  machine-readable verdict (`--gate-json`) needs it too, or a CI consumer is in the same position.

  Four-engine + spec-text work, so it wants a rung and a conformance PART rather than four local
  patches — that is why it is filed rather than fixed on the spot.

- **[P1 — DESIGNED AND UNBUILT; THREE items now wait on it, across two ecosystems] Value provenance —
  and it has TWO AXES, only one of which was designed.**
  `candor-spec/VALUE-PROVENANCE-DESIGN.md` recovers a value's concrete TYPE (which `newType` reaches a
  call — the primitive for dispatch). Measuring candor-swift against Apple's key list on 2026-08-05
  surfaced a second question that nothing covers: **which CONSTANT is this** — which literal or enum case
  reaches an argument. A `String` is a `String` whichever folder it names, so the type axis cannot answer
  it, and two unrelated features are blocked on the same missing primitive:
    · **five Apple privacy keys** (Desktop/Documents/Downloads/removable/network volumes) — the same
      `FileManager` call needs a different key, or none, depending on a path;
    · **the consumer half of Android permissions** — the same `ContentResolver.query` needs a different
      permission depending on a URI constant, which is why Google annotates *zero* of that surface.
  Designed 2026-08-05: `candor-spec/CONSTANT-PROVENANCE-DESIGN.md`. Key decisions: resolve to path/URI
  **classes** rather than reconstructed strings (a proved prefix decides the class, the unknown tail is
  irrelevant — no string solver); an undetermined value is a **disclosed third state with a count**,
  never charged to every key (fabrication) and never silent (the cardinal sin); a five-rung ladder where
  rungs 1–2 need no dataflow at all. The primitive is FLOOR, the class→key tables stay in the extensions.


  Design: `candor-spec/VALUE-PROVENANCE-DESIGN.md`. Tom's "absolute best product" call (2026-07-19):
  dissolve the source/sink trade-off by recovering a value's CONCRETE ORIGIN across construction and
  fields, interprocedurally — so a report can say not just *this function writes a file* but *it writes
  the file whose path came from here*.

  **FILED 2026-08-05 BY AN AUDIT, AND THE REASON IT WAS MISSING IS THE POINT.** It had a design doc, a
  named priority from Tom, and two items depending on it — and it appeared in no BACKLOG.md in any repo,
  in any form, except as a *sequencing reference inside another entry*. The Android permissions item was
  filed on 2026-08-04 saying "sequence it AFTER value provenance"; the thing it sequenced after did not
  exist as an item. **A dependency was created without filing the dependency.** A P-level scan — which is
  how the next task gets picked, per the audit note at the top of this file — could not see it, and the
  two items pointing at it are both P3, so the whole cluster reads as low priority when the blocking item
  is the high-value one.

  Two independent motivations, which is the strongest signal on this board:
    · the ORIGINAL one — sharper answers everywhere, without trading source fidelity for sink fidelity;
    · **Android permissions** (measured 2026-08-05, see below): the consumer-privacy half of Android's
      API→permission mapping is URI-dispatched through `ContentResolver.query(uri, …)`, so it needs the
      concrete URI constant that reaches the call. That is exactly this feature.

  Nothing here is measured yet beyond the design. First step is to re-read the design against the current
  engines — it predates several rungs (`typeSurface`, the completeness manifest, `resolves`) that may
  change what it needs to carry.

- **[OPEN — P3, and the measurement REFRAMED it: blocked on value provenance, not on a table] An
  Android/JVM analogue of the privacy manifest.**
  Raised by Tom 2026-08-04, off the back of `privacy/2`. The shape transfers exactly: code reaches a
  permission-guarded API → `AndroidManifest.xml` must declare `<uses-permission>` → verify, three outcomes
  (under-declared exit 1 · over-declared ⚠ · unreadable exit 2). It would be a **candor-java extension**
  (`permissions/1`), NOT an extension of `privacy/2` — `NSCameraUsageDescription` and
  `android.permission.CAMERA` are different objects and unifying the vocabularies would fabricate. What is
  shared is the shape, not the terms.

  **THE ONE MEASUREMENT THAT DECIDES WHETHER THIS IS WORTH DOING, and it is an hour's work.** The whole
  case rests on Android publishing the API→permission mapping that Apple does not: the framework annotates
  guarded APIs with `@RequiresPermission("android.permission.CAMERA")`, which is what Android Lint's
  `MissingPermission` consumes. If candor-java reads those, the uncovered set becomes ENUMERABLE — you can
  state which framework methods carry no annotation — instead of a curated table where whatever you forgot
  is silent. That is the difference between a disclosed blind spot and the cardinal sin, and it is the
  weakest part of `privacy/2` (`PRIVACY_SDK_TYPES`, 50 hand-written entries, verified by nothing).

  **MEASURED 2026-08-05** (Tom: "install an android sdk and do the measurement"). SDK installed via
  `brew install --cask android-commandlinetools`, platforms 30 and 36; script kept at
  `scripts/android-permission-coverage.py` because the answer MOVES with API level. The three questions,
  answered:

    1. **`platforms/android-NN/data/annotations.zip` — an XML sidecar, NOT the bytecode.**
       `@RequiresPermission` appears ZERO times in `android.jar` while Nullable/NonNull/Deprecated survive
       on the same classes (LocationManager retains 37 annotation attributes and has no constant-pool entry
       containing "permission"). candor-java is a bytecode engine, so consuming this is a STRING JOIN
       between an ASM method ref and a key like `"android.location.LocationManager android.location.Location
       getLastKnownLocation(java.lang.String)"` — whose generic forms (`java.util.List<…>`) do not appear in
       erased descriptors at all. That join is precisely the key-collision fabrication class this project
       has been bitten by four times. It is doable; it is not free, and it is not the clean read I assumed.
    2. **46% at API 36 (19/41 dangerous), 17% at API 30 — and ~37% once artifacts are removed.** Four of
       the 19 are not real coverage: READ_CONTACTS and WRITE_CONTACTS are annotated ONLY on
       `E2eeContactKeysManager` (an encrypted-contact-keys corner, not how any app reads contacts), and
       ACTIVITY_RECOGNITION and UWB_RANGING only on a `ServiceInfo.FOREGROUND_SERVICE_TYPE_*` CONSTANT,
       which is not a callable API. **The headline number flattered itself and inspecting the sites is what
       showed it.**
    3. **20.1% `conditional=true`, 23.0% anyOf/allOf, 60.6% single-permission and unconditional.** One in
       five carries an explicitly unanswerable condition (up from 6.2% at API 30) — spec 0.24 §3.1 says
       disclose those, never score them, so a fifth of the mapping produces a disclosure and not a verdict.

  **THE FINDING THAT CHANGES THE SHAPE OF THE WORK: there are ZERO `@RequiresPermission` annotations on the
  entire ContentResolver/ContentProvider surface.** Contacts, calendar, call log, SMS content, media and
  storage are not guarded by a distinctly-named method — they are guarded by the CONTENT URI passed as an
  argument. `ContentResolver.query(CalendarContract.Events.CONTENT_URI, …)` needs READ_CALENDAR; the SAME
  method with a different URI needs READ_CONTACTS. No method annotation can express that, which is exactly
  why every one of those permissions is missing from the mapping. Where the annotations DO cluster is the
  system/connectivity surface: bluetooth 144, telephony 125, device-admin 96, wifi 37, location 34.

  **So this is not "another curated table" — it is a VALUE-PROVENANCE problem, and candor already has that
  feature designed and unbuilt** (`candor-spec/VALUE-PROVENANCE-DESIGN.md`, the interprocedural
  value-origin recovery Tom called the "absolute best product" call on 2026-07-19). The Android permission
  gate is a second, independently-motivated application of it: recover which URI constant reaches
  `query()`, and the consumer-privacy half of the mapping falls out. **Sequence it AFTER value provenance,
  not before** — built first, it would cover bluetooth and telephony well and be silent on contacts and
  calendar, which is the wrong half for a privacy story.

  Two further constraints the measurement produced, neither of which I would have guessed:
    · **The mapping is a moving target.** API 30 → 36 went 130 → 922 annotated members, 44 → 187
      permissions, and DROPPED three (BLUETOOTH, BLUETOOTH_ADMIN, READ_EXTERNAL_STORAGE). An
      implementation must read the annotations for the project's OWN compileSdk, never bundle a snapshot.
    · **Lint as an oracle is unconfirmed.** I could not find a URI→permission table in the shipped
      cmdline-tools jars, but those are thin classpath manifests, so that check is INCONCLUSIVE — not
      evidence that Lint lacks one. If Lint does handle content URIs, its mechanism is worth reading before
      building anything.

  **Original filing kept below, because two of its assumptions did not survive** — I expected the
  annotations to be readable from bytecode (they are not) and treated high coverage as the likely case (it
  is 37% and skewed away from the privacy surface).

  **So measure BEFORE designing, and be aware nothing below is measured yet** — there is no Android SDK on
  this machine and no Android corpus (uflexi is a Tomcat webapp; `local.properties` is a plain Gradle
  convention and misled me into thinking otherwise). The questions, in order:
    1. Where do the permission annotations actually live in a CURRENT SDK — `platforms/android-NN/data/
       annotations.zip`, `@RequiresPermission` retained in `android.jar` bytecode, both, neither? I do not
       know, and the packaging has changed over the years. **Do not design around an assumed answer.**
    2. Of the ~30 dangerous permissions, how many are reachable from an ANNOTATED API? High coverage ⇒ this
       is mostly plumbing onto machinery that already exists. Low ⇒ it degenerates into another curated
       table and is far less attractive than it looks.
    3. What fraction of annotations are `anyOf` / `allOf` / `conditional=true`? A `conditional=true` is
       literally spec 0.24 §3.1's unanswerable condition — **disclose it, never score it as a failed one.**

  **Where Android is HARDER than iOS, and where the product probably is.** The effective manifest is MERGED
  from the app plus every AAR dependency, so a library can add a permission you never wrote. Verify against
  the source manifest and both directions break. Verify against the merged one and you get the pass/fail —
  but the answer worth selling is **which permissions came from a dependency, and what code justifies
  them**. That is the declaration-side mirror of the pollen finding (Contacts reaching the iOS binary
  through a shared module), and it is where Lint is weakest: strong intra-module, weak across dependency
  boundaries — exactly where chained dep reports work. Second hazard: `maxSdkVersion` / API-level
  conditionality (`WRITE_EXTERNAL_STORAGE` capped at 28, permissions that changed meaning across levels). A
  verdict that ignores API level is wrong; the same disclose-don't-score rule applies.

  **Where it is EASIER.** Bytecode beats source parsing for reach, so candor-java starts ahead of
  candor-swift. And unlike iOS there is an EXISTING ORACLE — Lint's `MissingPermission` — so this is
  measurable the way the rest of the project is: differential against Lint, expecting agreement
  intra-module and candor finding what Lint cannot across module boundaries. A measured claim, not a
  marketing one.

  **One naming decision this forces, worth taking before a second instance hardcodes it.** "Reach → required
  declaration → verify against a manifest" now has three plausible instances: Info.plist (SHIPPED as
  `candor privacy-manifest`), AndroidManifest.xml, and browser-extension `manifest.json` permissions on
  candor-ts. If the general verb is `candor manifest --verify <file>` with a per-platform vocabulary, then
  `privacy-manifest` wants to become an alias — cheap now, and cheapest of all BEFORE the privacy case study
  is published naming the current verb. See `candor/docs/case-study-privacy-manifest.md` (draft, unpublished).

- **[CLOSED 2026-08-03 — all four batches; see the body for what the source refuted] Ledger-mined classifier breadth** (data from the 2026-07-14 four-ecosystem sweep):
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

- **[P2 — needs EVIDENCE, opened 2026-08-07] `PHPickerViewController` probably requires no photo-library
  usage key, and candor says it does.** Found on Kingfisher in a corpus pass.

  `Classifier.swift:464` maps `PHPickerViewController` → `Photos`, and `Photos` requires
  `NSPhotoLibraryUsageDescription`. Kingfisher's iOS demo reaches it via
  `PHPickerResultViewController` and declares that key NOWHERE in the repository — no plist, no
  `INFOPLIST_KEY_`. So either the demo has shipped broken for years, or candor is over-reporting.

  **The strong prior is that candor is wrong**: PHPicker is the out-of-process picker introduced
  precisely so an app can let someone choose photos WITHOUT photo-library authorization, and Apple's own
  page describes it as rendered by the system on top of the app. That is the same shape as the
  `CMMotionManager` over-report fixed 2026-08-06 — an API in a covered framework that does not itself
  require the key.

  **But the evidence that settled CMMotionManager does not transfer, which is why this is recorded and
  not fixed.** That one was decidable because Apple's `NSMotionUsageDescription` page NAMES exactly four
  APIs. The `NSPhotoLibraryUsageDescription` page names none — its JSON contains zero symbol references
  — and neither `PHPickerViewController`'s page nor `PHPickerConfiguration`'s contains a citable
  "requires no authorization" sentence. Fixing a classifier on recollection is how the first
  CMMotionManager mapping got there.

  **What would settle it**: the WWDC20 "Meet the new Photos picker" session, Apple's privacy
  documentation for the picker, or an empirical check (a minimal app using only PHPicker, archived and
  submitted). If confirmed, the fix has the `MotionRaw` shape — a keyless effect, so the REACH is still
  reported and the manifest requirement is not — never dropping the effect, which would trade an
  over-report for silence.

- **[P2 — opened 2026-08-07] The ⟨0.24⟩ byte-equality MUST fails on a multi-crate WORKSPACE: two
  same-named violating functions merge into one on the `gate --report` route.**

  SPEC §3.3.1 requires `gate --report <it> --policy P` to produce a verdict BYTE-EQUAL to
  `scan --policy P`'s. Measured over 43 real projects (9 rust, 9 ts, 17 swift, 8 java jars): **41 are
  byte-equal**. The two that are not are both cargo WORKSPACES, and both fail the same way:

      rustls   scan 57 violations · gate --report 56    (`main`, present in several binaries)
      zellij   scan 23 violations · gate --report 22    (`commands::web_server_status`)

  The violation SETS are identical; the counts differ because the live scan emits two byte-identical
  rows and the report route emits one. The rows are byte-identical because `fn` carries no crate
  qualifier — so two DISTINCT violating functions in two crates are indistinguishable in the verdict,
  and the report route collapses them.

  **Which side is right is the question.** If they are two functions, the report route UNDER-REPORTS the
  number of violating sites — a fix list one short. If the verdict is meant to be a set of violating
  NAMES, the scan route double-counts. Either way the two routes disagree about a real repository, which
  is what the MUST exists to forbid.

  Same shape as [[candor-global-unit-identity]]: same-named units merging because the key is not
  qualified. That one was closed for the report's `functions`; the VERDICT's `fn` was not part of it.

  **Why conformance did not catch it**: every gate fixture is a single crate/package, so the collision
  cannot arise. The differential that found it is a corpus pass, not a fixture — worth a conformance row
  with a two-crate workspace whose crates share a function name.

- **[P1 — needs a RULING, opened 2026-08-07] A configured dep that cannot be read: two engines refuse,
  two continue. Found by the new generative config differential, not by hand.**

  Measured with a real path dependency, so the fixture is diagnostic (an earlier one was not — a call to
  an undeclared crate is omitted with or without any dep config, which proves nothing):

      dep report chained    → caller `inferred: ["Fs"]`     ← the coverage the operator configured
      same config, report missing:
        java   exit 2   "a configured dep must not silently read pure"
        swift  exit 2
        rust   exit 0   caller `inferred: []` + a COVERAGE DISCLOSURE naming the uncovered dep
                        ("absent from the report, NOT a claim they're pure")
        ts     exit 0   caller absent from `functions`; only "CANDOR_DEPS entry unreadable, skipped"

  **Both postures are internally coherent, which is why this needs a ruling rather than a fix.** The
  refusing arm reads a configured-but-unreadable dep as the §6.2 configured-but-unusable case, like a
  policy that vanished. The continuing arm reads it as reduced COVERAGE, which is what the ⟨0.15⟩
  coverage envelope exists to qualify — and rust's disclosure says exactly the right thing. What is not
  defensible is the family disagreeing: one `.candor/config`, four engines, two answers.

  If the ruling goes to DISCLOSURE, ts needs rust's coverage line (its "skipped" note does not qualify
  the absence, so on that engine the caller's `inferred: []` stands unqualified — which IS the cardinal
  sin). If it goes to REFUSAL, rust and ts need java's exit 2. Either way it wants a conformance row:
  nothing in 34 parts covers a configured dep that is not there.

  **Provenance worth keeping**: this came out of `conformance/differential/config_grammar_run.py` on its
  first clean run — 2456 agreed, 90 diverged, 2 signatures, and this was one of them. Hand-written rows
  had not covered it in 34 parts.

- **[P1 — spec rung, FOR 0.28, opened 2026-08-07] A policy that yielded NO RULES is
  indistinguishable from a clean gate IN THE MACHINE CHANNEL, four-way.**

  Measured 2026-08-07 on java, rust, ts and swift. Point `--policy` at an existing file that is not a
  policy — a README, the wrong path in a CI script — and every engine writes

      { "ok": true, "violations": [] }

  which is byte-identical to the verdict of a gate that ran and found nothing. Exit 0. A wrapper reading
  the artifact, which is the consumer this format exists for, cannot tell "your code is clean" from
  "your gate had no rules". The HUMAN channel is fine and this is why it went unnoticed: all four warn
  per line (`ignoring policy rule (unknown rule kind …)`), so the operator watching stderr is told. The
  verdict document is silent.

  **This is PART 32's ruling one level up.** ⟨0.24⟩ §4 says a RULE whose scope binds no function is
  DISCLOSED, never scored as satisfied. A POLICY that contains no rules at all is the same shape and the
  stronger case, and it is currently scored as satisfied.

  **Why it is a rung and not a fix**: the answer is a field in the verdict document — the natural home is
  beside ⟨0.24⟩'s `unevaluated` — and that is a wire-format change, so it wants a version and a
  conformance part rather than four independent additions. Note the ⟨0.26⟩ lesson applies directly: a
  PARTIAL artifact can answer worse than an absent one, so whatever the field is must make the NAIVE
  read (`ok`) safe rather than adding a key only a careful reader consults.

  Two things measured alongside it that are NOT defects, recorded so nobody re-opens them: the per-line
  warning IS emitted by all four (an earlier read of "silent in ts and swift" was a truncated `head -3`),
  and the "nothing hidden — every effect sits where its name says it should" line is the §6.1 containment
  note, printed with no policy at all, not a claim about the gate.

- **[P1 — spec rung, FOR 0.28, opened 2026-08-06] The stale-document rule binds the REPORT, not just the
  verdict. Tom: "make sure we fix the exit 2 issue in 0.28."**

  SPEC §3.3.1 ⟨0.24⟩ already says it — *"the stale-document rule binds EVERY machine-output path, not
  just `--gate-json`"*, and adds that it is WORSE for `scan --json` — and it is implemented on NO engine.
  Measured 2026-08-06: a scan that exits 2 leaves the previous `report.json` **byte-identical** on disk,
  and a downstream `gate --report <it>` then goes green over a report the failed run never produced. The
  ⟨0.27⟩ arming work closed exactly this hole for the VERDICT and left the report channel open, so the
  supply-chain route is poisoned one step upstream of the gate that was just made fail-closed.

  **Why it is a rung and not a fix, i.e. why it was NOT done for 0.27.** The verdict had an obvious
  fail-closed document to write (`ok:false, refused:true`, no `violations` key). A report has no such
  shape yet: you cannot write "this report refuses" in a wire format whose consumers read `functions`.
  Deleting the path is explicitly rejected by the same section — *"a consumer that treats a missing file
  as 'nothing to report' fails open by a different route."*

  **The shape the answer probably takes**, to be confirmed by measurement, not assumed: ⟨0.21⟩ already
  gives reports an `analyzed`/`unanalyzed` manifest, and a report declaring itself INCOMPLETE already
  grants no coverage when chained (⟨0.26⟩ PART 30 pins the sidecar analogue). So the fail-closed report
  is plausibly one with empty `functions` and an `unanalyzed` that names the refusal — a shape every
  existing consumer already reads correctly, which would make this a rung with no new consumer logic.
  **Check that claim before building it**: the ⟨0.26⟩ lesson was that a PARTIAL artifact answered WORSE
  than an ABSENT one, and that is exactly the risk here.

  **Conformance**: PART 34 pins the verdict sink; this needs its sibling over `--json`/`--out`, seeded
  the same way (write a green report first — a fresh path proves nothing when the failure mode IS the
  stale one), plus the end-to-end row that PART 34 does not have: scan exits 2, then `gate --report`
  over what is left must NOT be green. Also extend PART 34 itself to the `gate` QUERY verbs and to
  candor-agents, which the ⟨0.27⟩ part does not cover (it probes the scan path on four engines only).


- **[P3 — spec rung, 2026-08-04] `execute` as a per-effect KIND: reading a file as CODE rather than data.**

  **Context: the kind mechanism is now proven four-way.** SPEC §2's `fs: read|write` was spec'd long ago
  and implemented in java only — the in-family precedent this line originally claimed for rust was HALF
  FALSE: rust carried `pub fs: Vec<String>` in the wire model with `fs: Vec::new()` hardcoded, never
  populated, which is worse than absent (a present-but-always-empty field says "undetermined" forever
  while wearing a schema that implies support). candor-swift and candor-ts gained it 2026-08-04, and `privacy/2`
  applied the identical contract to a second effect family the same day. So "a per-effect kind, omitted
  rather than guessed" is no longer a proposal — it is a shipped pattern with two instances.

  **The proposal is NOT a universal read/write/execute triad, and the distinction is the whole item.**
  `execute` is meaningful for two effects and meaningless for the rest. Forcing a triad would make an
  engine answer a question that does not apply — and under absence-is-a-claim, an omitted field that
  *cannot* apply is noise rather than information, which is the opposite of what a disclosure format is
  for. The spec already scopes kinds per effect ("applies only when `inferred` contains `Fs`"), so this is
  a per-effect vocabulary decision and should stay one.

  · **`Fs[execute]` — and the interesting reading is NOT the POSIX exec bit** (that is a write). It is
    **code loading**: `dlopen`, a dynamic `require`, a reflective class-load — reading a file as *code*
    rather than as data. Genuinely different risk, and invisible today *as an effect*.
  · **`Db[execute]`** — arbitrary statement execution vs a query. Real, and the shape a "the read model may
    not write" gate wants.
  · **Not** `Clipboard`, `Env`, `Net`, or any privacy sensor. There is no execute there.

  **WHAT MAKES THIS AN UPGRADE RATHER THAN A NEW CLAIM, and it is the strongest argument for it.** Code
  loading is already handled honestly: `dlopen` and friends land as a DISCLOSURE REASON (`native:dlopen`),
  i.e. the engine says "I cannot see past this" and the function carries `Unknown`. So today's answer is
  *undetermined*, not *wrong*. An `execute` kind would move it from "I can't see this" to "this loads
  code" — strictly more information, and the transition is from a disclosed blind spot to a determined
  fact, which is the direction this project is always trying to travel.

  **THE HAZARD, named because it is inherited rather than new.** This is Escape 2's axis (PAPER3 §8): a
  kind or class coarsening is invisible to `H` *and* to `⊑`, so an engine that stops emitting a kind, or
  coarsens one, produces a red→green flip with no back-pressure in any channel. `netClass` already carries
  exactly this cost. The closure is a classification ratchet against baseline, and any kind rung should
  ship with one rather than after it.

- **[P3 — spec rung, 2026-08-04; MECHANISM SETTLED 2026-08-06] Direction (`read`/`write`) for the
  effects beyond `Fs` where it pays.**
  The general half of the same question. **Build it the way ⟨0.27⟩ `fs` ended up, NOT the direct-only
  shape this entry originally prescribed:** kinds TRAVEL the call graph and an undetermined contributor
  SUPPRESSES the whole field (a partial answer reads as the positive claim "writes but never reads"),
  pinned four-way by conformance PART 31 — which found all four engines wrong on its first run,
  including the reference engine propagating without the undetermined guard. The remaining places the
  distinction is worth the wire:

  · **`Clipboard` — and this is the best candidate, because the sensitive direction is the one nobody
    expects.** READING the clipboard is what iOS shows a paste banner for; writing to it is benign. One
    effect covers both today, so `deny Clipboard` cannot express "may write, may not read".
  · **`Db`** — the classic architecture gate: the read model may not write.
  · **`Env`** — reading is ubiquitous, writing is rare and surprising, and the two are worth telling apart
    in a report a human skims.
  · **NOT `Net`** — request/response is bidirectional by nature. The useful refinement there is the
    destination class, which already exists.

  Same discipline in every case: omitted rather than guessed, direct-only (a caller reaching one writer and
  one undetermined-kind callee must not inherit `["write"]` and thereby claim "writes but never reads"),
  and the same Escape 2 ratchet obligation as above.

- **[P3 — engine infra, 2026-08-04] candor-ts has no equivalent of candor-swift's collector-state guard.**
  candor-swift's `NameKeyedStateTests` requires EVERY stored property of `CallCollector` to be classified
  in a `disposition` map — because whether a shadow scope saves, clears or ignores a piece of state is a
  decision, and its docstring records that **seven defects came from that decision being skipped**. It
  caught two additions in one session (`fsKinds`, then `privacyKinds`).

  candor-ts has nothing equivalent, and the same class of mistake there surfaced as a CRASH: a fn record is
  built in four places, an accumulator was added to two, and `rec.fsKinds` was undefined on the other two —
  the scan aborted and the integration suite died on a null report. Loud, and therefore cheap, but loud by
  luck rather than by design. A test asserting every fn-record construction site produces the same key set
  would make it a named assertion instead.


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

- **[P2] candor's own test suites leak temp fixtures — 130,000 of them here.** `$TMPDIR` on this
  machine held 185k entries, of which ~130k were `candor-test*`/`candor-conc*`/`candor-swift-*`
  directories older than a day, left by runs that create a scratch tree and do not remove it (the
  killed-mid-run case is the obvious one, but 130k is not all killed runs). That is not only untidy: it
  made a single `candor-swift privacy-manifest --verify` take **72 seconds**, because a directory
  listing of the plist's ancestor is a listing of `$TMPDIR`. The engine side is fixed (2026-08-07 — no
  checkout ⇒ no ancestor walk, and `contentsOfDirectory(atPath:)` for the marker test), so this is now
  a hygiene item rather than a correctness one. Wanted: every harness that makes a scratch dir removes
  it on exit, including on failure — `defer`/`try/finally`/trap, not a happy-path `rm`.

- **[P2] candor-swift `--target` on an `.xcodeproj` may EXECUTE the repo's `Package.swift`.** When a
  local package's manifest builds its target lists in code (WordPress's `XcodeSupport.products`), the
  structural parser cannot read it and the resolver falls back to `swift package dump-package` — SwiftPM
  running the manifest. That is disclosed in the scope note by name, and it is the only way to resolve
  those repos soundly (the alternative is refusing the scan). But "no project changes, no build, no
  account" is the quickstart's promise, and this path quietly breaks it for an untrusted checkout.
  Wanted: an explicit opt-out (`--no-manifest-exec`, refusing rather than executing) so a reader
  scanning code they did not write can hold the promise. Added 2026-08-07 with the `.xcodeproj` rung.

- **[P2 — two pin mechanisms now exist; consolidate onto one] `adopt/candor.yml` still pins the engine
  in CI YAML (`CANDOR_JAVA_VERSION`), beside the ⟨0.27⟩ `.candor/config` `engine` key that every engine
  ENFORCES.** The YAML variable only chooses which jar to download — nothing checks it against anything,
  which is exactly the decoupling the §3.4 rung exists to end. `candor init` already writes the config
  pin and generates `.candor/run`, which reads it to fetch the jar, so the version appears once. The
  adopt starter should do the same: drop `CANDOR_JAVA_VERSION` and call `.candor/run`. Annotated in the
  file for now (2026-08-06) so nobody reads the two as independent, but an annotation is not a fix and
  a family shipping two competing pin mechanisms indefinitely is the thing to avoid.

- **[FIXED 2026-08-04] `release-stage.sh` stages five engines and left two umbrella sites to be found by a
  downstream refusal.** `release-stage.sh` now bumps UMBRELLA_VERSION and preflight [4] reads it (replayed
  the failure to confirm [4] catches a stale constant); `_stage_changelogs.py` now handles the dated
  heading, idempotently and without reflowing the file. The 0.26 release surfaced both:

  · **`bin/candor`'s `UMBRELLA_VERSION`** is not staged and preflight [4] does not check it, so the umbrella
    declared 0.25.0 while everything around it moved. Only `update-candor.sh` refused ("UMBRELLA_VERSION=
    0.25.0 but tag is 0.26.0") — and the consequence is not cosmetic: the tap formula's sha256 is computed
    over the TAG's tarball, so a tag whose `bin/candor` says 0.25.0 ships a brew umbrella that reports 0.25
    and sets `ENGINE_PIN=0.25.0`, i.e. fetches 0.25 engines under a 0.26 umbrella — verbatim the failure the
    ENGINE_PIN comment records from 0.18-through-0.23. Fixing it required force-moving a published tag.
  · **The umbrella CHANGELOG is DATED, not versioned**, so `_stage_changelogs.py`'s `## Unreleased` rename
    does not apply and its "(unreleased)" marker was left by hand. `release.sh`'s notes extractor now falls
    back for that shape, but nothing STAGES it.

  Both were the same shape: the stager knew about engines and forgot the umbrella is the seventh repo.

- **[FIXED FORWARD 2026-08-04 — one decision left for Tom] The umbrella carried TWO tags per release,
  `v0.26.0` and `0.26.0`.**
  `release.sh` tags `v$VER` like every other repo; it then calls `scripts/update-candor.sh "$VER"`, which
  tags whatever string it is given — and its own usage line says `v0.16.0`. So the bare form is created too,
  with a second GitHub release beside the first. **Pre-existing, not new: 0.25 has the identical pair**, and
  both resolve, so nothing is broken — the tap formula points at the bare tarball and `release-verify`
  checks the `v` one. Not fixed during the 0.26 run because the remedy is deleting published refs, which is
  not a thing to do mid-release.

  **Fixed forward:** `release.sh` now passes `v$VER`, and `update-candor.sh` reuses an existing tag/release
  rather than creating one — so it works both inside release.sh and standalone. The 0.26 tap formula was
  re-pointed at the `v0.26.0` tarball (sha verified against the URL, and the tarball confirmed to carry
  UMBRELLA_VERSION/ENGINE_PIN 0.26.0), and `v0.26.0` is now marked Latest so the releases page shows the
  canonical one. From 0.27 there will be a single tag.

  **DELETED 2026-08-04** (Tom's call): the orphaned `0.26.0` and `0.25.0` bare tags and their GitHub
  releases are gone. Checked first that nothing referenced them, that neither held any asset, and that each
  had a `v`-prefixed counterpart. `0.23.1`/`0.23.2` were deliberately kept — they predate the convention and
  are the SOLE releases for their versions, so they are history rather than duplicates. `release-verify`
  green afterwards and the tap URL still resolves 200.

  Residual, and it is the only one: the tap's git HISTORY contains commits whose formula pointed at the
  deleted tarballs, so `brew install` from a pinned old tap commit would now 404. Accepted.

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
