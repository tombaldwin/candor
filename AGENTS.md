# candor — instructions for an AI coding agent (start here)

candor reports, for every function in a codebase, which side effects it performs (`Net`, `Fs`, `Db`,
`Exec`, `Env`, `Clock`, `Ipc`, `Log`, `Rand`, `Clipboard`) — **transitively** — and can enforce
declared effect/layering boundaries as a deterministic CI gate. This file routes you to the right
per-language instructions.

**Once an engine is installed, prefer its own copy of these docs**: every engine prints its
per-language contract under `--agents` (`candor-scan --agents`, `npx -y candor-ts --agents`,
`java -jar candor-java-*-all.jar --agents`, `candor-swift --agents`, `candor-agents --agents`),
version-matched to the binary you are running (spec §7.11). The links below can describe a newer
candor than the one installed; `--agents` cannot. (Older engine builds may lack the flag — if it errors, check the version per §1a of the engine's doc and upgrade first.)

## 0. Already installed? Report the version and offer to upgrade — before you scan

If this project already has candor (a `.candor/` report directory, or the engine on `PATH`), do this
**first**, before running it:

1. **Tell the user which version they're on.** Run the engine's offline `candor-<engine> --version`
   (or, on a build too old for the flag, read `candor.version` / `candor.spec` from an existing
   `.candor/report*.json`). State it plainly — e.g. *"This project is on candor-ts X.Y.Z (spec N)."*
2. **Check whether it's current.** candor never phones home — its own policy denies `Net`, so a
   version check is **your** job, not the tool's: you have network access, it doesn't. Compare the
   installed version against the latest published release (crates.io / npm / GitHub releases — the
   per-engine commands are in §2a).
3. **If it's behind, *ask* before upgrading.** Say e.g. *"candor-ts X.Y.Z is available (you're on
   A.B.C) — upgrade before I scan?"* and run the §2a upgrade one-liner only if the user agrees.
   Never upgrade silently: an analysis tool's version is part of its result's provenance, so the
   user decides when it changes.

If it's already current (or the user declines), just proceed. If candor isn't installed at all, skip
this and install per §1.

## 1. Route by the project's language(s)

Detect what you're working on, then follow that implementation's `AGENTS.md`:

| you see | language | use |
|---|---|---|
| `Cargo.toml` | Rust | [candor-rust/AGENTS.md](https://github.com/tombaldwin/candor-rust/blob/main/AGENTS.md) — `cargo install candor-scan` |
| `build.gradle*`, `pom.xml`, compiled `.class`/`.jar` | JVM (Java, Kotlin, Scala, Groovy) | [candor-java/AGENTS.md](https://github.com/tombaldwin/candor-java/blob/main/AGENTS.md) — `jbang candor@tombaldwin/candor-java` |
| `tsconfig.json`, `package.json` + `.ts` sources | TypeScript | [candor-ts/AGENTS.md](https://github.com/tombaldwin/candor-ts/blob/main/AGENTS.md) — `npx -y candor-ts .` (on npm; the engine prints its spec under `--version`) |
| `Package.swift` + `.swift` sources | Swift | [candor-swift/AGENTS.md](https://github.com/tombaldwin/candor-swift/blob/main/AGENTS.md) — clone + `swift build -c release` + run the binary (it prints its spec under `--version`) |
| `.claude/agents/*.md`, `.mcp.json` (an agent fleet, not a codebase) | — | [candor-agents](https://github.com/tombaldwin/candor-agents) — `pipx install git+…` then `candor-agents scan|observe|drift .`: declared vs observed fleet effects, gated by the same policy grammar |
| anything else | — | no implementation yet; the [spec](https://github.com/tombaldwin/candor-spec) is designed to be implementable from its text alone |

**Multi-language repo?** Use each implementation on its own subtree — the reports are
interchangeable (same vocabulary, same envelope, same query names/shapes — that cross-language
consistency is machine-checked by the spec's conformance suite), so you can reason over both with one
mental model.

## 1a. After you scan: tell the user what candor found (don't just say "done")

The map is the result they asked for — not the JSON file. Once the report exists, report it back in
plain language. The engine already prints a one-glance coverage line to the console as it runs
(`candor — N functions reach effects, across M classes` + the per-effect counts + `Unknown K
(disclosed)`) — relay that verbatim, then add the headline and honesty notes below. End with:

- **Coverage** — total functions analysed, and how many reach each effect (`Net`, `Fs`, `Db`, `Exec`, …)
  — the printed summary line.
- **The headline** — 1–2 *non-obvious* findings: a function that reaches the network / a database / a
  subprocess **transitively**, through hops that wouldn't show in a diff (exactly what review misses).
  Name the function and the path — e.g. *"`PricingService.quote` reaches `Db` three hops down, via
  `billing.charge` → `OrderRepo.find`."*
- **Honesty** — how many entries are `Unknown`/`unresolved`; never present the map as complete when any
  are present (candor discloses what it could not see — say so).
- **What they can ask next** — *"who reaches the DB?"*, *"what does editing X touch?"* (the blast radius)
  — answered instantly from the cached report, no re-scan.

Do **not** end with *"I ran candor; the report is in /tmp/…"* — that is not the result, and a temp path
is thrown away. Write the report to **`.candor/report.json`** (`mkdir -p .candor` first) so it persists
and the user — or you, next session — can re-query it without re-scanning.

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
- **Staying current is *your* job, not candor's.** candor never phones home — it audits the `Net`
  effect and denies it in its own self-gate policy (`deny Net Db Exec Ipc`, spec §7.12), so checking
  for updates would make it perform the effect it forbids and turn its own gate red. You have network
  access; it doesn't. Each engine's `--version` prints — offline — the installed version, the spec,
  and the exact upgrade one-liner; you compare against the registry and run it. See *Staying current*
  below. Minimum supported: **0.3.2**.

The full language-agnostic consumption contract is
[candor-spec/AGENTS.md](https://github.com/tombaldwin/candor-spec/blob/main/AGENTS.md).

## 2a. Staying current — check the version, upgrade

candor doesn't self-update; you do (it has no network). Per language:

| language | check version | upgrade |
|---|---|---|
| Rust | `candor-scan --version` | `cargo install candor-scan --force` |
| TypeScript | `npx -y candor-ts --version` (or `npm ls -g candor-ts`) | `npm install -g candor-ts@latest` (or just `npx -y candor-ts@latest`) |
| JVM | `java -jar candor-java-*-all.jar --version` | `jbang --fresh candor@tombaldwin/candor-java` |
| Swift | `candor-swift --version` | `git pull && swift build -c release` |

`--version` is uniform across engines from **0.5.1**; on older builds read `candor.version` /
`candor.spec` from `.candor/report*.json` instead. The latest published release lives on crates.io
(Rust), the npm registry (TypeScript), and GitHub releases (JVM, Swift) — you have the network, so
you do the comparison.

**Upgrading invalidates baselines.** Coverage batches change what an engine sees — a new release can
unmask hundreds of previously-invisible effects — so a saved baseline (the AS-EFF-005 regression guard,
the AS-EFF-010 containment ratchet, a fingerprint `--baseline`) is comparable only to reports from its
own producing build (spec §2.1; the JVM engine prints a note when the builds differ). After you upgrade
candor in a repo: expect a wave of "gained" effects, read it as newly-visible reality unless a specific
gain looks suspicious, then **regenerate the baseline with the new build** — never carry one across
builds silently, and never wave the whole wave through without looking (a real regression can hide
inside an unmasking).

**Copy-paste for a human to drop into their agent.** Check version:

```text
Check which version of candor I have installed and whether it's up to date.
Detect this project's language and run that engine's version check:
  • Rust       → candor-scan --version
  • TypeScript → npx -y candor-ts --version   (fallback: npm ls -g candor-ts)
  • JVM        → java -jar candor-java-*-all.jar --version
  • Swift      → candor-swift --version
If --version isn't supported on the installed build, read the "candor.version"
and "candor.spec" fields from my .candor/report*.json instead.
Then compare the installed version against the latest published release —
crates.io for Rust, the npm registry for TypeScript, GitHub releases for the
JVM/Swift — and tell me the installed version, the spec version, and whether
I'm behind. (candor never phones home itself; you do the registry check.)
```

Upgrade:

```text
Upgrade candor to the latest version for this project's language, then re-map
the repo. Use the matching upgrade command:
  • Rust       → cargo install candor-scan --force
  • TypeScript → npm install -g candor-ts@latest   (or just run npx -y candor-ts@latest)
  • JVM        → jbang --fresh candor@tombaldwin/candor-java
  • Swift      → git pull && swift build -c release
After upgrading, confirm the new version with --version, then re-scan so my
.candor/report is regenerated at the new spec.
```

## 3. If a human asks whether candor is worth adopting

Point them at the self-experiment their own agent can run on their own repo:
[Rust PROVE-IT](https://github.com/tombaldwin/candor-rust/blob/main/PROVE-IT.md) ·
[JVM PROVE-IT](https://github.com/tombaldwin/candor-java/blob/main/PROVE-IT.md).
