# Unknown density — the cross-engine review (2026-06-12)

Tom's question: can we get Unknown density down, and is it a family-wide problem? Measured on each
engine's hardest reference target, with the top `unknownWhy` origins:

| engine | target | Unknown density | dominant origin |
|---|---|---|---|
| Swift | swift-log | 33/33 (100%) | `callback:` ×33 — fn-typed params invoked, call sites pass CLOSURES |
| TS | hono | 270/280 (96%) | middleware genericity (fn-valued params/fields) |
| Rust (scan) | actix-http | 25/33 (75%) | `MessageBody` local-trait dispatch over the 12-impl CHA bound |
| JVM | commons-io | 657/1263 (52%) | reflection (`reflect:` — `Method.invoke` and friends) |

## The structural finding: most of this density is HONEST, not lazy

Every dominant origin above is a §4 case where resolving would mean guessing:

- **Closure-passed callbacks** (Swift/TS): the receiver executes an unaddressable value. The
  family line — drawn three times independently and now enforced by the Swift fuzzer, which went
  14/40 red when a port tried to relax it — is that only ALL-NAMED call sites resolve. The
  closure's effects are charged to its passer (so nothing is *lost*); the receiver's Unknown is
  the honest residue.
- **Reflection** (JVM): irreducible opacity, correctly tagged `reflect:` so consumers can triage.
- **Over-bound CHA** (Rust): a 15-impl trait is genuinely wide dispatch; resolving all 15 would
  smear, per the cross-engine ≤12 bound.

## The reducible slice, per engine (ranked by expected yield)

1. **Swift — protocol-typed FIELDS** (`var handler: LogHandler` — params get CHA, fields don't
   yet). The `dispatch:` origins (4 in swift-log, larger share in vapor). Port the Rust
   trait-fields index. *Shipped this week: accessor units, callback_named (all-named sites),
   try/await peeling, factory returns — each already cut real density.*
2. **JVM — bounded points-to for `Method.invoke` with a literal method name** (a `getMethod("x")`
   literal names its target — resolvable without guessing). Smaller: the `dispatch:` share via
   wider entry-point modeling.
3. **TS — fn-typed FIELD flow** (the callback_named move covers params; fields holding named
   functions assigned once could resolve the same way).
4. **Rust scan — Deref-coercion receivers and generic-parameter fields** (the measured ureq
   residue, needs deeper inference or stays a documented lint-only capability).

## What NOT to do

Do not chase 0%: a framework's genericity (hono's middleware, swift-log's handler indirection) IS
indeterminacy, and the density number on such targets is the trust contract working out loud. The
metric that matters is **wrong-direction errors** (fabrications and silent-pures), which the
fuzzers + conformance hold at zero — density is a precision dial, not a correctness one.
