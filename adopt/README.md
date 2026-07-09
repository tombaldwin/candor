# Adopt the candor architecture gate (JVM)

Enforce your architecture on every push in three steps. candor-java reads the
effects (`Db`/`Net`/`Fs`/`Exec`/…) of every method from your **compiled bytecode** —
no annotations, no source changes, any JVM language (Java/Kotlin/Scala/Groovy) — and
fails the build when a rule is broken, pointing at the exact method.

This folder has everything you need:

| File | What it is |
|------|------------|
| [`candor-init.sh`](./candor-init.sh) | The one-command scaffold — scan, propose a policy, record the baseline, drop the Action |
| [`candor-init`](./candor-init) | The policy proposer (python3) — usable on its own against any engine's report |
| [`arch.policy`](./arch.policy) | An annotated policy template — copy to your repo root and edit |
| [`candor.yml`](./candor.yml) | A GitHub Actions workflow — copy to `.github/workflows/` |

**Getting it:** clone the umbrella repo (`git clone https://github.com/tombaldwin/candor`) or copy this
`adopt/` folder **plus** `integrations/github/candor-sarif` — `candor-init.sh` reads its sibling files
(`candor-init`, `candor.yml`, the SARIF reporter) and exits 2 without them. **Prerequisites:** a JRE 17+
(to build your project and run the engine), `python3`, `curl`; Node.js instead if you scan with the
TypeScript engine, and for the fingerprint tool.

## 1. Try it locally first

```bash
# build your project so there are .class files (Maven shown; Gradle: ./gradlew classes)
mvn -B compile

# install candor-java once (https://jbang.dev)
curl -Ls https://sh.jbang.dev | bash -s - app setup     # if you don't have jbang

# see the layer map — which layers perform which boundary effects, and how contained they are
jbang candor@tombaldwin/candor-java target/classes --json report.json
jbang candor@tombaldwin/candor-java containment report.json
```

`containment` shows where each boundary effect lives (e.g. `Db 100% — infrastructure`).
That tells you which rules are already true and worth locking in.

## 2. Write your policy — or let candor propose one

**Fastest start — one command.** [`candor-init.sh`](./candor-init.sh) scans your compiled classes, proposes
a starter policy from what your code already does, records a baseline, and drops the GitHub Action:

```bash
mvn -q compile              # (or ./gradlew classes) — candor reads bytecode
./candor-init.sh            # scaffolds the five artifacts below
```

It writes **five artifacts** — commit **all** of them (the AS-EFF-005 regression ratchet bites only when
the baseline is committed):

| Artifact | Role |
|----------|------|
| `arch.policy` | the proposed starter policy — review it first |
| `.candor/baseline.json` | the regression-ratchet baseline |
| `.candor/config` | policy + baseline wiring (spec §3.4) — local runs need no env vars |
| `.candor/candor-sarif` | the vendored SARIF reporter — pinned with your repo, immune to upstream churn |
| `.github/workflows/candor.yml` | the pinned CI gate |

Every rule it proposes *currently passes* (safe to adopt, and it catches future regressions): it finds the
layers that are pure today (`pure com.shop.domain`) and the boundary effects each layer doesn't reach
(`deny Db Net … com.shop.repo`). Review `arch.policy`, keep what matches your intent, delete the rest. It
never clobbers an existing policy or workflow.

**One pin, one engine build.** The scaffold scans with the *exact* candor-java release the dropped
workflow pins (`CANDOR_JAVA_VERSION` in `candor.yml` — the jar is fetched once into `~/.cache/candor`),
so the recorded baseline and the CI gate always come from the same engine build. That matters because the
baseline guard fails **closed** on an engine-build mismatch — a baseline from a floating "latest" scan
would fail your first CI run the moment a newer engine ships. Upgrading stays a deliberate PR: bump the
pin in the workflow, re-scan with it (`candor-init.sh` follows your repo's workflow pin, not the adopt
copy's), review the effect delta, and refresh the baseline in the same PR
(`cp .candor/report.json .candor/baseline.json` — a re-run never clobbers it silently).

**Just the policy** (engine-agnostic — works on a `candor-ts`/`candor-scan`/`candor-swift` report too;
NB the file-output flag differs: candor-java takes `--json <file>`, the scan-source engines take
`--out <prefix>` — their `--json` streams to stdout):

```bash
jbang candor@tombaldwin/candor-java <classes> --json .candor/report.json   # java: report + callgraph
npx -y candor-ts <src> --out .candor/report                               # ts/scan/swift: --out <prefix>
python3 candor-init .candor/report.json --out arch.policy                 # (or the report the glob finds)
```

**Or write it by hand.** Copy [`arch.policy`](./arch.policy) to your repo root and edit the package names.
Start with the one rule that matters most — usually "the domain does no I/O":

```
deny Db Net Fs Exec   com.acme.domain
```

Check it: a violation prints an `AS-EFF-###` line and exits non-zero.

```bash
CANDOR_POLICY=arch.policy jbang candor@tombaldwin/candor-java target/classes
echo "exit: $?"   # 0 = clean, 1 = a rule was broken
```

The rule kinds (full grammar + examples in [`arch.policy`](./arch.policy)):

| Rule | Enforces |
|------|----------|
| `deny <Effect…> <scope>` | a layer must not perform these effects |
| `pure <scope>` | a layer must perform **no** effects |
| `forbid <A> -> <B>` | layer A must not transitively reach layer B |
| `allow <Effect> in <scope> <values…>` | a layer may reach **only** these hosts/commands/paths/tables |

## 3. Wire it into CI

Copy [`candor.yml`](./candor.yml) to `.github/workflows/candor.yml` and edit the three
marked spots (your build command, your compiled-classes directory —
`target/classes` for Maven, `build/classes/java/main` for Gradle — and your source
root) plus, occasionally, the fourth: the pinned engine version (`CANDOR_JAVA_VERSION`).
That's it — every push and pull request now runs the gate, and the architecture
rule fails the build when someone breaks it.

The workflow also writes the violations as **SARIF**, so they surface **inline on the
pull-request diff** and in the repo's **Code-scanning / Security** tab — on the exact line
a boundary is crossed, not just as a red check. (See [`../integrations/github/`](../integrations/github/README.md).)

> **Code scanning is free on public repos; on a private repo it needs GitHub Advanced
> Security.** Without it, the SARIF upload step fails with *"Code scanning is not enabled
> for this repository"* — the gate still runs and fails the check on a violation (exit 1),
> you just don't get the inline annotations.

**See it running:** [`tombaldwin/candor-action-demo`](https://github.com/tombaldwin/candor-action-demo)
is a live, minimal example — a `domain` class that writes a file under a `deny Fs domain` policy. Check its
**Actions** run (the gate failing on the deliberate violation) and **Security → Code scanning**, where the
alert lands on the exact line:
> `AS-EFF-006` · `src/main/java/com/demo/domain/Order.java:11` · `Order.audit` performs `{ Fs }`, forbidden by `deny Fs com.demo.domain`

---

**What candor does when it can't see through a call:** it discloses (`Unknown`, or
`invisible` for an unmodeled library) rather than silently reporting "no effect" — so
a green gate is never silently wrong. See the [case studies](../docs/case-studies.md)
for this running end-to-end on real Spring, Kotlin, and Quarkus apps.
