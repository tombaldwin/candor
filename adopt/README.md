# Adopt the candor architecture gate (JVM)

Enforce your architecture on every push in three steps. candor-java reads the
effects (`Db`/`Net`/`Fs`/`Exec`/…) of every method from your **compiled bytecode** —
no annotations, no source changes, any JVM language (Java/Kotlin/Scala/Groovy) — and
fails the build when a rule is broken, pointing at the exact method.

This folder has everything you need:

| File | What it is |
|------|------------|
| [`arch.policy`](./arch.policy) | An annotated policy template — copy to your repo root and edit |
| [`candor.yml`](./candor.yml) | A GitHub Actions workflow — copy to `.github/workflows/` |

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

## 2. Write your policy

Copy [`arch.policy`](./arch.policy) to your repo root and edit the package names.
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

Copy [`candor.yml`](./candor.yml) to `.github/workflows/candor.yml` and edit the two
marked spots (your build command and your compiled-classes directory:
`target/classes` for Maven, `build/classes/java/main` for Gradle). That's it — every
push and pull request now runs the gate, and the architecture rule fails the build
when someone breaks it.

---

**What candor does when it can't see through a call:** it discloses (`Unknown`, or
`invisible` for an unmodeled library) rather than silently reporting "no effect" — so
a green gate is never silently wrong. See the [case studies](../docs/case-studies.md)
for this running end-to-end on real Spring, Kotlin, and Quarkus apps.
