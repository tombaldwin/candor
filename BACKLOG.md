# candor (umbrella) backlog

_Last reviewed 2026-06-22. Per-engine detail: `candor-java/BACKLOG.md`, `candor-rust/BACKLOG.md`._

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
spec is **stable at 0.7, no 0.8 queued** (a bump requires a new capability across ALL engines +
conformance; none pending). Value now concentrates in:

- **[P0 — north star] Agent edit-time blast-radius feedback.** The `diff` / MCP surface ships, and the
  edit-time delivery loop now ships too: [`integrations/claude-code/`](integrations/claude-code/) — a Stop
  hook (`stop-hook.sh`, script selected by `CANDOR_REVIEW`) that scans the agent's turn, diffs effects vs a
  baseline, and blocks-once with the gained effects + transitive blast radius + any policy violation so the
  agent self-corrects. **Both delivery paths now ship:** `candor-review.sh` (JVM/bytecode, builds once per
  turn) and `candor-review-source.sh` (the scan-source engines ts/swift/scan — no build step), sharing the
  exit contract; the delta is computed from the spec-0.7 report envelope so it's engine-agnostic and catches
  pure→effectful. _Remaining polish:_ a richer in-IDE/MCP push.

- **[adoption] Get the proven wedge in front of users.** The architecture-gate is proven — 5 real-app case
  studies (`docs/`) + a copy-paste `adopt/` starter (policy template + GitHub Action), validated end-to-end
  via jbang. The remaining lift is distribution, not capability: case studies → candor.poly.io; keep the
  adoption starter current.

## fingerprint

- _Done (2026-06-21):_ **`--baseline <report>` diff** — reports the *change* in the structure descriptor
  vs a baseline (structure delta + per-component smear/unknown/tangleExcess/cycleRatio deltas, the
  direction toward order/chaos), the deterministic-gate framing. (The A–F letter grade was already removed.)
  No fingerprint backlog items remain.

## Deferred operational (need a publish or maintainer action)

- **Case studies → candor.poly.io** — site deploy has been blocked on the ssh-agent. _Still open._
- **candor-rust CI self-guard nightly ICE** — a rustc nightly bug; direction is the maintainer's call
  (deep-engine maintenance; see candor-rust/BACKLOG.md).
- **Cross-model eval** (planned) — run the scaled-completeness eval across opus/sonnet/haiku/Fable.
- _Done 2026-06-22:_ ~~candor-ts npm republish (`containment`)~~ — shipped in **candor-ts 0.7.5** (npm).
  ~~candor-swift release cut~~ — shipped as **v0.7.3** (GitHub).

## Non-goals (decided — do not build)

- A "candor score" / cross-codebase **grade**. A single composite fights the deterministic-per-function-
  facts positioning (spec §6.1), is gameable, and buries the signal. Keep per-function facts + the
  explainable structure components.
- **Heavier per-engine dev-tooling** (rustfmt gate / `tsc --checkJs` / SwiftLint). Each was evaluated and
  declined with documented reasons; every engine already gates its idiomatic bug-pattern linter
  (clippy `-D warnings` / eslint / Error-Prone + `-Xlint`) plus a warnings-as-errors equivalent.

## Recently shipped (context; older entries pruned from the per-engine files)

- **Real-world corpus campaign + all-engine publish (2026-06-22).** Ran every engine on real OSS; fixed the
  last live silent-under-reports and shipped all four: candor-ts **0.7.5** (npm — `node:vm`/dynamic-`require`
  → Unknown; `@types/X`→runtime-pkg so curated DB/Net clients fire, e.g. pg→Db with `@types/pg`),
  candor-scan **0.7.2** (crates.io — `Arc`/`Rc`/`Box` + custom `impl Deref` receiver under-reports),
  candor-swift **v0.7.3** (inherited-from-external-conformance Fluent ORM vein → Db, `extension`-shadow,
  `.write(to:)`), candor-java **v0.7.11** (Redis Db reconciliation + `CANDOR_CLOSED_WORLD` + CI/AGENTS.md
  sync). Decision recorded: wire/HTTP datastores (ES/OpenSearch/Solr/InfluxDB/Couchbase-raw) **stay Net** by
  the existing deliberate policy (native-protocol datastores are already Db).
- κ persistence coverage (candor-java 0.7.9 / 0.7.10): Hibernate-6 / Jakarta Data, Panache, Micronaut Data,
  Ebean, ActiveJDBC, jOOQ + the general modeled-base-subclass fix; repo pure-`default` fabrication fix;
  declarative HTTP-client interfaces → Net.
- `containment` in the cross-engine conformance differential (PART 11); `containment` added to candor-ts
  (all three query engines now have it; swift via candor-query).
- candor-swift realizes the MODEL.md vocabulary as named types (3 of 4 engines now typed).
- Adoption starter (`adopt/`) + 5 case studies (`docs/`).
