# candor-java case studies — the architecture gate on real JVM code

Five runs of candor-java against real, third-party JVM projects — no configuration, no annotations, no
source changes. Each is `candor <compiled-classes>` plus, where shown, a short `arch.policy` wired to fail
the build. The point of the set is breadth: two Spring styles, a Kotlin app, a non-Spring framework, and a
library supply-chain audit — and what candor does at the edge of what it models.

| # | Project | Stack | What it shows |
|---|---|---|---|
| 1 | [RealWorld "Conduit"](#1-realworld-conduit--spring-ddd--mybatis) | Spring Boot, DDD, MyBatis | `Db` 100% contained; domain proven I/O-free; gate bites on a real `Rand` decision |
| 2 | [Spring PetClinic](#2-spring-petclinic--spring-data-jpa) | Spring Data JPA | a real cross-layer smell — a presentation `Formatter` reaching the DB |
| 3 | [PetClinic, Kotlin](#3-petclinic-kotlin--language-agnostic) | Kotlin + Spring | same layer map from Kotlin bytecode — the analysis is language-agnostic |
| 4 | [Quarkus + Jakarta Data](#4-quarkus--jakarta-data--hibernate--a-non-spring-framework) | Quarkus, Hibernate | a non-Spring framework: `Db` lands cleanly via the Hibernate-6 / Jakarta-Data model; the rest is disclosed |
| 5 | [gson](#5-gson--a-supply-chain-audit) | library jar | a supply-chain audit: the one non-obvious network call in 386 functions |

All five are reproducible: build the project (JDK 17), then `jbang candor@tombaldwin/candor-java <classes>`.

---

## 1. RealWorld "Conduit" — Spring, DDD + MyBatis

A genuine layered Spring Boot app (93 Java files; `api`/`application`/`core`/`infrastructure`/`graphql`).
candor derived the layer map from bytecode: **`Db` is 100% contained in `infrastructure`**, and the DDD
domain (`io.spring.core`) performs **zero** `Db`/`Net`/`Fs`/`Exec`. The gate then bit on a real
architecture *decision* — all five aggregate roots mint their own IDs with `UUID.randomUUID()`, which a
team practising strict DI would forbid (`deny Rand io.spring.core` → exit 1, all five sites pinned). candor
also named the 13 third-party packages it doesn't model as `invisible` rather than "no effect".

**→ Full write-up: [case-study-realworld-spring.md](./case-study-realworld-spring.md)**

---

## 2. Spring PetClinic — Spring Data JPA

The canonical Spring sample. candor resolves it cleanly — **47 functions, `Db` ×21 + `Clock` ×6, zero
`Unknown`** — and correctly attributes `Db` to the Spring Data repository *interfaces* (no method body;
the implementation is generated at runtime), the same pattern it reads for MyBatis mappers.

```
candor containment cs_pc.json
  effect  contained  layers   owner       ← leaked into
  Db            77%       2    owner (14)  ← vet (4)
```

The interesting result is a real **cross-layer smell** the gate catches:

```
# arch.policy
deny Db org.springframework.samples.petclinic.owner.PetTypeFormatter
```
```
[AS-EFF-006] PetTypeFormatter.parse performs { Db }, forbidden by policy   (exit 1)
```

`PetTypeFormatter` is a Spring **presentation-layer** `Formatter`, yet `parse` reaches the database
directly (it looks up pet types to convert a form field). That is exactly the kind of layering drift an
architecture gate exists to catch — surfaced from the bytecode, pinned to the method, with no annotations.

---

## 3. PetClinic, Kotlin — language-agnostic

The same app rebuilt in Kotlin. candor reads the *compiled* `.class` files, so the source language is
irrelevant: **47 functions, `Db` ×21**, the same repository→controller shape, `Db` 80% contained in the
`owner` layer. The architecture signal survives the language change because the analysis is on bytecode,
not source — one engine covers Java, Kotlin, Scala, and Groovy on the JVM.

---

## 4. Quarkus + Jakarta Data + Hibernate — a non-Spring framework

The Hibernate ORM / Jakarta Data quickstart — deliberately *not* Spring. `FruitRepository` is a
`jakarta.data.repository.CrudRepository` interface, and the REST endpoints in `FruitResource` go through it
into Hibernate's Jakarta-Data-era API (`StatelessSession`, `SelectionQuery`, `MutationQuery`). candor reads
that boundary and `Db` lands on all five endpoints, fully contained:

```
FruitResource.create   inferred=[Db]   invisible=[org.hibernate.exception]
FruitResource.delete   inferred=[Db]   invisible=[org.hibernate.query.criteria]
FruitResource.get      inferred=[Db]   invisible=[org.hibernate.query.criteria, org.hibernate.query.specification]
FruitResource.getSingle inferred=[Db]  invisible=[]
FruitResource.update   inferred=[Db]   invisible=[]

candor containment   Db   100%   1 layer
```

Two things make this the honest study of the set. First, the analysis crosses frameworks — the same engine
that maps Spring Data and MyBatis also models the Jakarta Data / Hibernate-6 persistence path, so `Db`
lands without a single annotation. Second, look at the residual `invisible`: the *pure* criteria-builder
packages (`org.hibernate.query.criteria`, `…specification`) that candor doesn't model are still
**disclosed**, not silently dropped. candor models the I/O it's sure of and names the rest — it never
reports `inferred=[]` ("pure") for a call it hasn't actually understood. A gate built on it is never
silently wrong, even at the edge of what it models.

*(This study drove a real engine change: the Hibernate-6 / Jakarta-Data persistence model was added to
candor-java's κ effect classifier as a direct result of an earlier run of this quickstart, which had
disclosed the whole `org.hibernate` surface as `invisible`. The disclosure contract turned a blind spot
into a worklist.)*

---

## 5. gson — a supply-chain audit

"What does this dependency actually touch?" candor scanned the gson 2.11.0 jar: **386 functions, exactly
one `Net`** —

```
com.google.gson.internal.bind.TypeAdapters$23.read   →  Net
```

`javap` confirms it: that class is `TypeAdapter<java.net.InetAddress>`, and `read` calls
`InetAddress.getByName` — a DNS lookup performed while deserializing JSON. It's a real, non-obvious network
touch in a library most people think of as pure parsing, found with zero fabrication (everything else
resolves to pure or `Unknown` via reflection). That is the supply-chain question candor answers directly:
not "is this library popular" but "what can it reach".

---

*candor-java is the JVM flagship of the candor family — per-method effect disclosure from bytecode, with a
policy DSL that fails the build when the architecture drifts. Install: `jbang candor@tombaldwin/candor-java`.*

**Want this on your repo?** The [`adopt/`](../adopt/) starter has a copy-paste `arch.policy` template and a
GitHub Actions workflow — three steps to the gate running on every push.
