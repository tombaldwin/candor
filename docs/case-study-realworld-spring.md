# Case study: enforcing a real Spring app's architecture, on every push

**App:** [RealWorld "Conduit" Spring backend](https://github.com/gothinkster/spring-boot-realworld-example-app)
— a genuine, layered Spring Boot app (93 Java files; DDD layers `api` / `application` / `core` /
`infrastructure` / `graphql`), not a toy. **Tool:** candor-java, run on the compiled bytecode — **no
configuration, no annotations, no source changes.**

The pitch is "your architecture, enforced on every push, for the JVM." Here is that, end to end, on
someone else's real code.

```
./gradlew compileJava                                   # the app's own build
candor build/classes/java/main --json report.json       # scan the bytecode
candor containment report.json                           # the layer map
CANDOR_POLICY=arch.policy candor build/classes/java/main # the gate (exit 1 on a violation)
```

## 1. The layer map is measured, not asserted

```
candor containment — how well each boundary effect stays in one layer
  effect    contained  layers   owner
  Db            100%       1     infrastructure
  ambient (cross-cutting, not scored): Clock 1L, Rand 1L
```

**`Db` is 100% contained in the `infrastructure` layer** — every database touch is *performed* there, and
every other layer reaches it only *through* that layer. That is the textbook layering signal, and it's a
number candor derived from the bytecode, not a diagram someone drew. (candor "knows" the persistence
pattern: the MyBatis mapper interfaces have no method body, yet their calls are correctly attributed `Db` —
the same way it reads Spring Data repositories.)

## 2. The domain is provably free of I/O

`io.spring.core` — the DDD heart — performs **zero** `Db`/`Net`/`Fs`/`Exec`. The dependency rule ("the
domain depends on infrastructure only through its own interfaces, never reaches for it") is not just a
convention here; candor confirms it holds, and the gate keeps it that way:

```
# arch.policy
deny Db Net Fs Exec io.spring.core   # the domain performs NO I/O
```
→ **passes** (0 violations). A future commit that makes a domain class `new`-up a JDBC connection or open a
socket would flip this red on the pull request.

## 3. The gate bites — on a real, specific finding

Architecture-as-code means *you* choose the rule; candor enforces it and points at the exact code. This
team's domain entities mint their own IDs:

```
# arch.policy (cont.)
deny Rand io.spring.core   # the domain must not self-generate IDs — inject them (determinism / testability)
```
→ **FAILS, exit 1**, pinning every offender:
```
[AS-EFF-006] io.spring.core.article.Article.<init>(String,String,String,List,String)        performs { Rand } …
[AS-EFF-006] io.spring.core.article.Article.<init>(String,String,String,List,String,DateTime) performs { Rand } …
[AS-EFF-006] io.spring.core.article.Tag.<init>(String)                                        performs { Rand } …
[AS-EFF-006] io.spring.core.comment.Comment.<init>(String,String,String)                      performs { Rand } …
[AS-EFF-006] io.spring.core.user.User.<init>(String,String,String,String,String)             performs { Rand } …
```
All five aggregate roots call `UUID.randomUUID()` in their constructors. That is not a *bug* — it's an
architecture **decision**. A team practising strict determinism/DI would forbid it and inject IDs; a team
that's fine with it simply omits the rule. The point is candor turns that decision into a line of policy
the build enforces, and it found all five sites with zero false positives and no source annotations.

## 4. It discloses what it can't see — it never guesses

candor named the 13 third-party packages this app calls that it doesn't model — `graphql.execution`,
`org.joda.time`, `io.jsonwebtoken`, `com.fasterxml.jackson.core`, the Netflix DGS framework — as
**invisible**, not as "no effect". The contract is disclosure: where candor can't resolve a call, it says
so rather than silently reporting "pure".

## Why this matters

No config. No annotations. No source changes. From the compiled jar candor produced a measured layer map,
proved the domain's I/O isolation, enforced two architecture rules with the build failing on a real
violation pinned to exact methods, and disclosed its own blind spots. That is an architecture gate you can
drop into CI on a JVM project today — `candor <classes> ` with a short `arch.policy`, wired to fail the
push when the architecture drifts.

---
*Reproducible: clone the app, `./gradlew compileJava` (JDK 17), then the four commands at the top against
`build/classes/java/main`. candor-java is `jbang candor@tombaldwin/candor-java`.*
