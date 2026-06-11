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
| [candor-ts](https://github.com/tombaldwin/candor-ts) | the TypeScript engine (young, 0.1.x): project scanning, the policy gate, queries — grown from the spec-derivability proof; third engine in the conformance CI |
| [candor-agents](https://github.com/tombaldwin/candor-agents) | an exploration off programming languages: an AGENT FLEET as an effect graph (agents=units, delegation=edges, tool grants=classified leaves) — queried and policy-gated by the unmodified candor tools |

**AI agent?** Start at [AGENTS.md](AGENTS.md) — it routes you to the right per-language instructions.

**Sceptical?** Good. Each implementation ships a [PROVE-IT](https://github.com/tombaldwin/candor-rust/blob/main/PROVE-IT.md)
self-experiment your own agent runs on your own repo — manual blast-radius trace committed *before*
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
