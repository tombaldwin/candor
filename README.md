# candor

<p align="center"><img src="https://raw.githubusercontent.com/tombaldwin/candor/main/assets/beaky.svg" alt="Beaky, the candor canary" width="180"></p>

**Per-function side-effect audit and architecture-as-code enforcement, for humans, CI, and AI
agents — across languages.** candor knows which functions reach the network, filesystem, a database,
a subprocess — *transitively* — and turns invariants like *"the domain layer does no I/O"* into a
policy that fails the build when an edit breaks them. Its reports and queries are
**cross-language-consistent by machine-checked conformance**, so one mental model (and one agent
prompt) works everywhere.

**Site:** [candor.poly.io](https://candor.poly.io) — the measured case in five minutes: the
exhibits, the pre-registered evals, and the prove-it-on-your-own-repo path.

| repo | what |
|---|---|
| [candor-spec](https://github.com/tombaldwin/candor-spec) | the specification (report format, semantics, policy DSL, conformance suite) — designed to be implementable from its text alone |
| [candor-rust](https://github.com/tombaldwin/candor-rust) | the Rust reference implementation — `cargo install candor-scan` |
| [candor-java](https://github.com/tombaldwin/candor-java) | the JVM implementation (Java, Kotlin, Scala, Groovy — reads bytecode) — `jbang candor@tombaldwin/candor-java` |
| [candor-ts](https://github.com/tombaldwin/candor-ts) | the TypeScript engine (0.4.x, **on npm**: `npx -y candor-ts`): project scanning, the policy gate, queries — grown from the spec-derivability proof; third engine in the conformance CI |
| [candor-swift](https://github.com/tombaldwin/candor-swift) | the Swift engine (young, 0.4-era v0, SwiftSyntax): scanning + the policy gate + the κ ledger — the FOURTH engine, 20/20 on the shared oracle on its first run |
| [candor-agents](https://github.com/tombaldwin/candor-agents) | effect analysis for AGENT FLEETS (pipx-installable): declared (scan) vs observed (transcripts) vs the drift between them — queried and policy-gated by the unmodified candor tools |

**AI agent?** Start at [AGENTS.md](AGENTS.md) — it routes you to the right per-language instructions.

**Sceptical?** Good. Each implementation ships a PROVE-IT self-experiment your own agent runs on
your own repo ([Rust](https://github.com/tombaldwin/candor-rust/blob/main/PROVE-IT.md) ·
[JVM](https://github.com/tombaldwin/candor-java/blob/main/PROVE-IT.md) ·
[TypeScript](https://github.com/tombaldwin/candor-ts/blob/main/PROVE-IT.md)) — manual blast-radius trace committed *before*
the tool runs, every claimed miss verified at a file:line, and the honest negative outcome reported
if candor doesn't help on your codebase. The implementations also hold their own gates: each analyzes
itself in CI under a declared policy (spec §7.12).

## The 30-second pitch

AI-generated code silently crosses architectural boundaries — a network call inside a domain layer, a
DB query in a UI handler. Reviews (human or LLM) catch this probabilistically; candor catches it
**deterministically**: a curated classifier at the I/O boundary, transitive propagation to a fixpoint,
an explicit `Unknown` wherever resolution fails (it never silently under-reports — a contract held by
adversarial fuzzers in CI), and a policy gate over the result. For agents it also answers the
pre-edit question — *"if I add an effect here, what's the blast radius and does it break policy?"* —
in one query ([measured](https://github.com/tombaldwin/candor-rust/blob/main/eval/scaled/RESULTS-speed.md):
~1.8× faster than tracing by hand at equal completeness, and complete where untooled agents report ~6%).

## Effects fingerprint

<p align="center"><img src="assets/fingerprint-example.png" alt="A candor effects fingerprint" width="300"></p>

[`fingerprint/`](fingerprint/) turns any engine's report into a fixed-size, text-free, **deterministic**
abstract mark of a project's effect profile — the effect mix as a colour nebula, effect-propagation
edges as weighted neon threads, and code structure as order-vs-chaos. Same report → same image. It also
emits the DNA as JSON, including a single **structure score** (0–100) composed from the structural
signals candor already computes (effect smear, Unknown opacity, call-graph tangle, cycles). Works
identically across all four engines. See [`fingerprint/README.md`](fingerprint/README.md).
