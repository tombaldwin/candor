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
| 4 | [Quarkus + Jakarta Data](#4-quarkus--jakarta-data--hibernate--the-edge-of-the-model) | Quarkus, Hibernate | the edge of the model: unmodeled persistence is disclosed `invisible`, never silently "pure" |
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

## 4. Quarkus + Jakarta Data + Hibernate — the edge of the model

The Hibernate ORM / Jakarta Data quickstart — deliberately *not* Spring. `FruitRepository` is a
`jakarta.data.repository.CrudRepository` interface, and the REST endpoints in `FruitResource` go through
it into Hibernate's native API. candor does **not** model Jakarta Data / Hibernate-native persistence (it
models the Spring Data and MyBatis repository patterns). The result is the one that matters most for trust:

```
FruitResource.get    inferred=[]   invisible=[org.hibernate, org.hibernate.query, org.hibernate.query.criteria, …]
FruitResource.create inferred=[]   invisible=[org.hibernate, org.hibernate.exception]
…
candor-java: κ doesn't know 5 packages this code calls into — effects through them are INVISIBLE
(not Unknown): org.hibernate (26 calls), org.hibernate.query.criteria (19), org.hibernate.query (17), …
```

The endpoints' persistence is reported `invisible` — candor states the packages it can't see through and
the call counts — **not** as `inferred=[]` meaning "pure". A gate built on candor is therefore never
silently wrong on a framework candor doesn't fully model: it tells you where its sight ends rather than
asserting "no effect". This run also names a concrete coverage frontier — Jakarta Data / Hibernate-native
is the obvious next persistence pattern to model, alongside Spring Data and MyBatis.

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
