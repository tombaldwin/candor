# candor (umbrella) backlog

_Last reviewed 2026-06-21. Per-engine detail: `candor-java/BACKLOG.md`, `candor-rust/BACKLOG.md`._

## Direction — next strategic bets (family-level)

Correctness/honesty is well-shored and now **cross-engine-verified**: the inherited-into-project
silent-pure vein class (active-record / repository / modeled-base-subclass) was found, closed across all
major JVM persistence (candor-java κ batches 24–27), and confirmed **not** a shared blind spot —
candor-ts/scan disclose `Unknown` for the same shape (SOUNDNESS.md §8.3). The deployability gate is shipped
end-to-end: AS-EFF-005 ratchet, AS-EFF-006/008/009 policy, AS-EFF-010 **containment** + cross-engine
conformance (PART 11). Value now concentrates in:

- **[P0 — north star] Agent edit-time blast-radius feedback.** The `diff` / MCP surface ships; the open
  work is tightening the *delta back to the agent* — a `CANDOR_REVIEW` self-review / Claude Code hook that
  surfaces an edit's gained effects *including the transitive blast radius*. This is where the
  pre-registered eval's decisive lift lives (blast-radius is a reasoning gap, not a cost gap).

- **[adoption] Get the proven wedge in front of users.** The architecture-gate is proven — 5 real-app case
  studies (`docs/`) + a copy-paste `adopt/` starter (policy template + GitHub Action), validated end-to-end
  via jbang. The remaining lift is distribution, not capability: case studies → candor.poly.io; keep the
  adoption starter current.

## fingerprint

- **`--baseline <report>` diff for the structure score.** Report the *change* vs a baseline
  ("structure −0.06 since main; tangleExcess up, driven by these 3 new cycles") rather than an absolute
  number — the deterministic-gate framing, not the vanity-number one. (The A–F letter grade was already
  removed; the 0–1 `structure` value + its four components live under `structure_detail`.)

## Deferred operational (need a publish or maintainer action)

- **Case studies → candor.poly.io** — site deploy has been blocked on the ssh-agent.
- **candor-ts npm republish** — `containment` (added 2026-06-21) isn't on npm yet.
- **candor-swift release cut** — the typed-model alignment (2026-06-21) isn't released.
- **candor-rust CI self-guard nightly ICE** — a rustc nightly bug; direction is the maintainer's call
  (deep-engine maintenance; see candor-rust/BACKLOG.md).
- **Cross-model eval** (planned) — run the scaled-completeness eval across opus/sonnet/haiku/Fable.

## Non-goals (decided — do not build)

- A "candor score" / cross-codebase **grade**. A single composite fights the deterministic-per-function-
  facts positioning (spec §6.1), is gameable, and buries the signal. Keep per-function facts + the
  explainable structure components.
- **Heavier per-engine dev-tooling** (rustfmt gate / `tsc --checkJs` / SwiftLint). Each was evaluated and
  declined with documented reasons; every engine already gates its idiomatic bug-pattern linter
  (clippy `-D warnings` / eslint / Error-Prone + `-Xlint`) plus a warnings-as-errors equivalent.

## Recently shipped (context; older entries pruned from the per-engine files)

- κ persistence coverage (candor-java 0.7.9 / 0.7.10): Hibernate-6 / Jakarta Data, Panache, Micronaut Data,
  Ebean, ActiveJDBC, jOOQ + the general modeled-base-subclass fix; repo pure-`default` fabrication fix;
  declarative HTTP-client interfaces → Net.
- `containment` in the cross-engine conformance differential (PART 11); `containment` added to candor-ts
  (all three query engines now have it; swift via candor-query).
- candor-swift realizes the MODEL.md vocabulary as named types (3 of 4 engines now typed).
- Adoption starter (`adopt/`) + 5 case studies (`docs/`).
