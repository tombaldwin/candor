# candor — instructions for an AI coding agent (start here)

candor reports, for every function in a codebase, which side effects it performs (`Net`, `Fs`, `Db`,
`Exec`, `Env`, `Clock`, `Ipc`, `Log`, `Rand`, `Clipboard`) — **transitively** — and can enforce
declared effect/layering boundaries as a deterministic CI gate. This file routes you to the right
per-language instructions.

## 1. Route by the project's language(s)

Detect what you're working on, then follow that implementation's `AGENTS.md`:

| you see | language | use |
|---|---|---|
| `Cargo.toml` | Rust | [candor-rust/AGENTS.md](https://github.com/tombaldwin/candor-rust/blob/main/AGENTS.md) — `cargo install candor-scan` |
| `build.gradle*`, `pom.xml`, compiled `.class`/`.jar` | JVM (Java, Kotlin, Scala, Groovy) | [candor-java/AGENTS.md](https://github.com/tombaldwin/candor-java/blob/main/AGENTS.md) — `jbang candor@tombaldwin/candor-java` |
| `tsconfig.json`, `package.json` + `.ts` sources | TypeScript | [candor-ts/AGENTS.md](https://github.com/tombaldwin/candor-ts/blob/main/AGENTS.md) — clone + `node scan.mjs .` (young engine; not on npm — the "minimum 0.3.2" registry rule below doesn't apply to it: clone HEAD, check `candor.spec` = 0.3 in the envelope) |
| `.claude/agents/*.md`, `.mcp.json` (an agent fleet, not a codebase) | — | [candor-agents](https://github.com/tombaldwin/candor-agents) — an exploration: the fleet's tool grants and delegation as an effect graph, gated by the same policy grammar |
| anything else | — | no implementation yet; the [spec](https://github.com/tombaldwin/candor-spec) is designed to be implementable from its text alone |

**Multi-language repo?** Use each implementation on its own subtree — the reports are
interchangeable (same vocabulary, same envelope, same query names/shapes — that cross-language
consistency is machine-checked by the spec's conformance suite), so you can reason over both with one
mental model.

## 2. The universal rules (hold in every language)

- **What a function performs** → its `inferred` (the full transitive effect set).
- **Blast radius of editing a function** — "who is affected if I change X?" → the transitive
  `callers` of X, **not** its `inferred`. Works for a still-pure X — ask *before* the edit.
- **Decide before you edit** → `whatif <fn> <Effect>`: every transitive caller gains the effect,
  crossed with the policy — the gate's verdict without writing code.
- **The trust rule (never skip):** if `unresolved` is true or `Unknown` is in the set, the effect
  list may be incomplete — read the source before relying on it. Never conclude "pure" from an
  unresolved entry. candor is deliberately honest about what it cannot see.
- **Enforcement** is a `CANDOR_POLICY` file (`deny` / `pure` / `allow` / `forbid` — same grammar in
  every language, spec §6.2) that fails the build deterministically.
- **Staying current is *your* job, not candor's.** candor never phones home to check for updates —
  it audits the `Net` effect and denies it in its own policy, so checking would make it perform the
  effect it forbids. You have network access; it doesn't. Compare the installed version against the
  registry yourself and upgrade — the exact one-liners (crates.io for Rust, GitHub releases for the
  JVM) are in each implementation's "Staying current" section. Minimum supported: **0.3.2**.

The full language-agnostic consumption contract is
[candor-spec/AGENTS.md](https://github.com/tombaldwin/candor-spec/blob/main/AGENTS.md).

## 3. If a human asks whether candor is worth adopting

Point them at the self-experiment their own agent can run on their own repo:
[Rust PROVE-IT](https://github.com/tombaldwin/candor-rust/blob/main/PROVE-IT.md) ·
[JVM PROVE-IT](https://github.com/tombaldwin/candor-java/blob/main/PROVE-IT.md).
