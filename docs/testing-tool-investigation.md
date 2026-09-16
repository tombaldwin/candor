# Is candor useful as a TESTING tool?

**Status: MEASURED 2026-09-16.** Started as an open investigation; the measurement is below. The
thesis survived in part and failed in the part that mattered, and the correction is worth more than
the original claim. Nothing here is a commitment.

## The one-line thesis to attack

**candor is a BOUNDARY tool, not a BEHAVIOUR tool.** Most testing questions are behaviour questions,
which is why most of them fit badly. But **test hermeticity is a boundary question wearing testing
clothes**, and it is the one place where candor's central design choice — sound over-approximation with
disclosed unknowns — is a FEATURE rather than a tax.

> **VERDICT (measured, see Findings): HALF RIGHT, and the wrong half is the load-bearing half.**
>
> - *"boundary tool, not behaviour tool"* — **holds.**
> - *"test hermeticity is a boundary question"* — **holds at the API-family level.**
> - *"sound over-approximation is a FEATURE here … a false positive costs a glance"* — **FAILS.**
>   candor's effect vocabulary (`Net`/`Fs`/`Exec`) is one level coarser than the hermeticity question,
>   which is about *destinations* (internet vs loopback, tempdir vs repo). Over 6 Rust workspaces a
>   `deny Net` gate over the test trees fired **293 times** and the true answer to *"which tests need
>   the internet"* was **2**. That is not a glance; it is 291 glances, and it is structural, not a
>   precision bug to be fixed later.
> - **What DID survive is something this document did not name:** candor already computes a census of
>   the *literal boundary constants* a test tree names (`hosts` / `paths` / `cmds` in the report JSON).
>   Over the same 6 workspaces that census is **11 lines**, of which **5 are real findings** a
>   maintainer would not have had. No CLI verb surfaces it. That, not the gate, is the product.

## What already exists — CORRECTED 2026-09-16

The original text said *"tests are excluded by default; `--include-tests` keeps them — so pointing
candor at a test tree is a flag, not a feature"*. **That was written from candor-rust and is true of
candor-rust only.** Measured on the installed binaries (`candor-scan 0.38.1`, `candor-java` spec 0.38,
`candor-swift 0.38.2`, `candor-ts@latest`):

| engine | how you get test code analysed | granularity of the answer |
|---|---|---|
| **rust** | `candor-scan --include-tests` — a real flag, works | per function; **but macro-declared tests are invisible** |
| **java** | **no flag needed** — point it at `build/classes/java/test` | **per method, and per lambda** — the best of the four |
| **ts** | **no flag exists.** Exclusion is a filename/dirname heuristic (`isTestPath`, `scan-core.mjs:11`); you bypass it by pointing the scan at the test dir or file | **collapses to the FILE** on callback-style suites (ava/jest/vitest/mocha) |
| **swift** | **impossible.** A file that `import`s `XCTest` or `Testing` is excluded *"wherever it sits"* (`excluded.class = "test-source"`); `--target <ATestTarget>` excludes the target it just named | n/a |

`test-exclusion` is still pinned four-way by `candor-spec/conformance/run.sh` — what is *not* pinned,
and differs in all four, is whether there is any way to opt back in.

## Findings

Everything below is **MEASURED** on the installed binaries unless a line says INFERRED. No engine was
built; no repo other than this document was modified.

**Corpus and boundaries.** Rust: 6 real workspaces from `~/.candor/corpus/src` — ripgrep, clap, regex,
serde, tokio, hyper — scanned twice each (default, and `--include-tests`), giving **2,797 test-only
function entries**. TypeScript: `got`, `hono`, `zx` from the corpus, plus candor-ts's own tree (the only
JS tree available with `node_modules` present). Java: candor-java's own 161 compiled test classes →
1,500 method entries. Swift: swift-argument-parser plus a synthetic directory. **Most of the numbers
are about Rust.** The TS finding rests on 3 projects, the Java finding on 1, the Swift finding on 2.

---

### Q1 — Is the hermeticity slice real, and is the answer SURPRISING?

**The gate's answer is not surprising. A census of the literal constants is.**

The gate view, on real trees:

```
crate      test fns      Net       Fs     Exec   |  distinct hosts  paths  cmds
ripgrep         441        0       82       15   |        0          2      0
clap            383        0        1       16   |        0          0      0
regex           304        0        7        6   |        0          0      2
serde            42        0        0        0   |        0          0      0
tokio         1,318      120       96       21   |        3          0      3
hyper           309      174        2        0   |        1          0      0
```

`candor-scan . --include-tests --policy 'deny Net'` on hyper exits 1 with **174 violations**; narrowing
the scope to `deny Net tests` gives **118**. Reading that list, a hyper maintainer sees every
integration test and every bench, and shrugs — it is an HTTP library.

The census view is the same data one field over, and it is 11 lines for the whole corpus:

```
tokio   hosts  google.com:80        ← tests/rt_metrics.rs:693 and :711
tokio   hosts  127.0.0.1:8080  127.0.0.1:8000
tokio   cmds   sleep  true  uname
ripgrep paths  /root  /sys
regex   cmds   cargo  git
hyper   hosts  client.read          ← FALSE (see D2)
```

**Five of those eleven lines are real findings, verified against source:**

1. **tokio has two tests that connect to `google.com:80` and `.unwrap()`.**
   `tokio/tests/rt_metrics.rs:693` (`io_driver_fd_count`) and `:711` (`io_driver_ready_count`).
   They are `#[cfg(any(target_os = "linux", target_os = "macos"))]` and they fail without internet.
   This is the "I had no idea" case, in a top-20 crate. **Every other socket literal in tokio's entire
   test tree is loopback** — `grep` over `tokio/tokio/tests` finds 91 × `"127.0.0.1:0"`, 1 × `"[::1]:0"`,
   and these 2.
2. **ripgrep's `ignore` crate has two unit tests that read `/root` and `/sys`** — `walk::tests::no_read_permissions`
   and `walk::tests::same_file_system` (`src/walk.rs:2272`, `:2242`). Both **`return` silently** when the
   path is absent, so on macOS and in most containers they pass by doing nothing. This is the exact class
   of test that gives a false green in a sandbox.
3. **regex-cli's test/benchmark subcommand shells out to `cargo` and `git`** (`cmd/compile_test.rs`).
4. **clap's completion tests require `bash`/`zsh`/`fish`/`elvish` to be installed** — 13 test functions
   reach `Exec` transitively through `common::has_command`, which runs `<shell> --version`.
5. **candor-java's own suite has 18 test methods that read CWD-relative repo paths** —
   `src/main/java` (`SourceHygieneTest`), `build/classes/java/{main,test}` (`Refresh*Test`), `build`
   (`VerifyOracleTest`), and one absolute `/no/such/.candor/config`. Those are the tests that break when
   the suite is run from anywhere but the repo root.

Finding 2 is the one that makes the case, because it is the one `grep` cannot do. ripgrep's test sources
contain 20+ distinct absolute-path string literals (`"/home/andrew/sherlock"`, `"/foo/bar"`,
`"/usr/share/man/man1/ls.1.gz"`, …) and all but two of them are *match patterns*, not filesystem
accesses. candor's `paths` field returns exactly the two that reach an `Fs` call.

**Honest judgement on "surprising".** The signal is a needle in a haystack: the haystack is 300–1,300
flagged entries per repo, the needles are 2–6, and they are surfaced by a report field that no CLI verb
prints. `candor-query where Net` over tokio prints 176 function names and not one host literal.

---

### Q2 — What is the false-positive rate in practice?

**The failure mode the brief expected is NOT the one that bites.** The brief anticipated *"a test that
COULD reach `Net` on a path it never takes"*. Measured, that is rare. What is common is *the effect is
genuinely reached and does not matter for the question*.

**Class A — analysis false positive (effect on a path the test never takes): ~1 in 14.**
Thirteen flagged entries were sampled at random across tokio/hyper/ripgrep/clap and each body was read.
**0 of 13 were class A** — every charged effect is genuinely executed. One further instance was found
opportunistically: `tokio/tests/fs_open_options_windows.rs::open_options_windows_custom_flags` is charged
`Fs` for `OpenOptions::new().custom_flags(…)` inside a `format!("{:?}", …)` assertion that opens nothing —
and the file is `#![cfg(windows)]`, so on this host the test does not run at all. Call it ~7%, with a
sample that small.

**Class B — real effect, benign for hermeticity: the dominant mode, 9 of 13 in the same sample.**
tempdir writes, loopback sockets, UNIX-domain sockets charged `Net`. Quantified directly rather than
sampled:

> tokio + hyper carry **293** `Net`-charged entries in their test trees. Enumerating every socket
> literal in those trees gives 3 non-loopback candidates, of which `google.com:80` (×2) is real and
> hyper's 5 × `"localhost"` are `Request::connect("localhost")` authority strings, not sockets.
> **Against "which tests need network access beyond loopback": 2 true of 293 → 99.3% false positive.**
> **Against "which tests open a socket at all": ~100% true.**

The two questions differ by one level of granularity, and candor's vocabulary sits on the wrong side of
it. `netClass` does not close the gap: **every one of the 350 `Net`-bearing entries in the whole corpus
reads `netClass: ["unknown-host"]`** — `google.com:80` and `127.0.0.1:8080` are classed identically, by
design (the vocabulary is `known-telemetry`/`known-partner`/`unknown-host`, built for egress security).

**Class D — wrong scope.** `--include-tests` also admits `benches/` and `examples/`. Of hyper's 174
`deny Net` violations, 30+ are bench functions, and the sample turned up `examples::send_file::simple_file_send`.
There is no way to ask for tests without benches and examples.

---

### Q3 — How much does `Unknown` dominate test code specifically?

Measured as *"% of entries whose `inferred` contains `Unknown`"*, with the **production code from the
same scan as the control** (this matters — the absolute level is inflated in both columns because the
scans were run without `--deps`):

```
crate      production   test-only      integration files   inline #[cfg(test)]
ripgrep       14.1%       37.6%            26.7%                39.4%
clap          69.1%       32.6%            17.1%                87.1%
regex         51.6%       83.9%            92.8%                80.5%
serde         70.5%       45.2%            45.2%                  —
tokio         63.5%       82.8%            79.0%                97.7%
hyper         12.6%       45.6%            49.0%                38.4%
```

Test code is **more** `Unknown` than production code in 4 of 6 (ripgrep +23pp, regex +32pp, tokio +19pp,
hyper +33pp); less in clap and serde. candor-ts's own harness files: **60.6%** of 241 entries.
candor-java's own test classes: **41.8%** of 1,500.

**The consequence is directional, and this is the useful half of the answer:**

- The **DENY** direction survives `Unknown` cleanly. `deny Net` over a test tree is unaffected — a
  charged effect is charged regardless of how much else is unresolved.
- The **CERTIFY** direction dies. *"These tests are provably hermetic"* is unavailable for 33–84% of
  them, and for 97.7% of tokio's inline unit tests. So the product cannot be "green badge, your suite is
  sandbox-safe". It can only be "here is what I can see".

---

### Q4 — Do the four engines differ here?

**Yes, more than any other question in this document, and it is the strongest single argument against
shipping this as a family feature.** See the corrected table above; the measurements behind it:

**rust — works, with one large hole.** `--include-tests` is a real flag. But candor-scan does not expand
`macro_rules!` invocations, so **macro-declared tests do not exist in the report**: ripgrep declares ~290
tests via `rgtest!(name, |dir, cmd| { … })`, and the report contains **0** of them. `tests/misc.rs` holds
93 `rgtest!` tests and produces **one** report entry (a helper). `#[test] fn` bodies are named normally
(ripgrep 82%, tokio 77%, hyper 80% of source `#[test]` names appear). The 290 missing tests are *absent*,
not claimed pure — but a product that lists "tests that reach `Exec`" would print 15 helpers and omit them.

**java — the best of the four.** No exclusion exists; you point the engine at the compiled test classes.
Granularity is per method *and per lambda* (`…Test.lambda$socketStreamStoredInAFieldChargesNetWhereItIsRead$0`),
because a JUnit test body is a method, not a callback. 161 classes → 1,500 entries.

**ts — no flag, and the granularity collapses.** `isTestPath` is a regex over the path relative to the
scan root, so pointing the scan at the test directory bypasses it (`candor-ts got/test --allow-js` analysed
122 declarations). But a `.test.ts`-suffixed file is excluded even then, and for ava/jest/vitest/mocha the
test body is an *argument* to `test()`, so it gets no entry of its own: **`got/test/http.ts` contains 26
`test(…)` calls and produces exactly one entry, `http.<module>`.** You can answer "which test FILE", never
"which test". The exclusion also leaks in the other direction — see D5.

**swift — cannot be done.** Any file importing `XCTest` or `Testing` is excluded *wherever it sits*
(`excluded.class = "test-source"`), so a bare directory of copied test files is refused with exit 2
("no Swift sources under ."), and renaming them away from `*Tests.swift` does not help. `--target
ArgumentParserEndToEndTests` prints *"scanning 4 target(s) [ArgumentParser, ArgumentParserEndToEndTests,
…], 43 of 76 source file(s)"* and then reports **0** functions from `Tests/` — all 67 excluded. The
refusals are honest (exit 2, disclosed `excluded`), not false clean scans. But the answer is no.

**So: 1 engine does this well, 1 does it with a hole, 1 does it at the wrong granularity, 1 cannot.**

---

### Q5 — What would the smallest honest product be?

**Not a gate. A census, and a reader for report fields that already exist.**

`candor tests <dir>` (or `candor boundary-census --include-tests`) — one verb that:

1. runs the engine's scan with test code included, by whatever mechanism that engine has;
2. prints only the **literal boundary constants reachable from test code**, grouped:
   - `hosts` — egress destinations, with loopback/`::1`/`localhost` folded into one "loopback" line so a
     non-loopback host is visually alone;
   - `paths` — absolute or CWD-relative filesystem literals, with the system temp dir folded out;
   - `cmds` — external command heads;
3. prints, separately and once, the counts it is *not* showing ("1,318 test functions, 120 reach Net,
   96 Fs, 21 Exec") so the census never reads as a completeness claim;
4. names its own blind spots for that engine — on rust: "macro-declared tests are not analysed"; on ts:
   "the unit is the file, not the test".

It exists because every real finding in this investigation came out of those three fields and **no CLI
verb prints them**: `candor-query where Net` over tokio lists 176 function names and zero literals.
Implementation is a reader over the report JSON; no engine change is needed for rust/ts/java.

**What it explicitly does NOT do:**

- **It is not a CI gate.** `deny Net` over a test tree is 99% loopback; wiring that to exit 1 produces a
  gate teams turn off in a week.
- **It does not certify hermeticity.** `Unknown` is 33–84% of test functions; there is no green badge here.
- **It does not work on Swift**, and on TypeScript it answers per file. Say so in the verb's own output,
  not in a doc page.
- **It does not do test selection or coverage joins** (see "slices that look weak", unchanged).

---

### Q6 — The strongest argument AGAINST the whole idea

*Stated properly, in its own voice.*

**`grep` already does 88% of this, and the 12% candor adds is not where the findings are.**

Of the 540 effect-charged test entries across the five Rust workspaces that have any, **473 sit in a file
that already contains a direct charge of that same effect.** A maintainer who runs
`grep -rln 'process::Command\|TcpStream::connect\|fs::write' tests/` gets the same file list. candor's
genuine contribution is the 67 entries (12.4%) whose effect arrives from a helper in a *different* file —
concentrated in exactly two places (clap's `Exec`: 12 of 16; tokio's `Net`: 42 of 120). Everywhere else
it is single digits.

**And the census — the part that produced every real finding — has recall problems nobody has measured.**
Of the 17 `Exec`-charged entries in tokio's `tests/` directory, **0** carry a `cmds` literal, while those
same files contain 10 literal `Command::new("…")` sites that `grep` finds instantly. The builder form
(`let mut cmd = Command::new("bash"); …; cmd.spawn()`) loses the head because the literal and the spawn
are in different statements. The `hosts` census did better on tokio — 4 of the 5 literal connect/resolve
destinations, correctly ignoring all 92 binds — but "4 of 5 on one crate" is not a measured recall figure,
it is an anecdote, and the one line that made the whole investigation look good (`google.com:80`) would
also have been the first hit of `grep -rn '\.com' tokio/tests/`.

**Then the structural objections, any one of which is enough on its own:**

- **The unit of the answer is wrong on half the engines.** On TypeScript — the ecosystem where flaky
  networked tests hurt most — you cannot name a test, only a file. On Rust you lose every macro-declared
  test, which is the idiom table-driven suites use.
- **The question is genuinely dynamic.** "Does this test touch the network *when it runs*" is answered
  exactly, for free, by running the suite under a network namespace, `strace`, or a blocking DNS resolver.
  Those tools give per-test truth with zero false positives, and CI already runs the suite.
- **The market is thin.** A team that cares enough to install a static hermeticity checker is a team that
  can run their suite in a locked-down container once and get a better answer.
- **It is a second product.** candor's line is supply-chain effect boundaries. A test-hygiene census shares
  a report format and nothing else — no policy, no gate, no baseline, no `gains`. It is a demo, not a rung.

**The rebuttal I can actually defend** is narrow: the `/root` and `/sys` finding in ripgrep is one `grep`
cannot produce, because ripgrep's test sources contain 20+ absolute-path literals of which 2 reach an `Fs`
call — and the same shape produced candor-java's 18 CWD-dependent tests. "Which of my string literals
actually reach the boundary" is a real query and candor is the only thing that answers it. Whether that is
a product or a blog post is a judgement call this measurement does not settle.

---

## Defects found (REPORTED, not filed — the coordinator numbers SOUNDNESS rows)

None is a silent under-report; every one is disclosed somewhere in the envelope. Listed in the order they
would cost something.

- **D1 — `candor-scan` excludes a production source file by filename.** `regex-cli/cmd/compile_test.rs`
  is a module of the `regex-cli` **binary**, not test code. The default scan drops it as
  `excluded.class = "test-module"` (*"a `tests.rs`/`*_test.rs` file module is a `#[cfg(test)]` tree…"*),
  and the default report's `cmds` for `regex_cli::main` is `["rustfmt", "ucd-generate"]` where with
  `--include-tests` it is `["cargo", "git", "rustfmt", "ucd-generate"]`. Disclosed (`excluded` count 1),
  effect-level still sound (`Exec` is charged by another path), but the literal surface is narrower than
  the truth by default.
- **D2 — a non-host in `hosts`.** `hyper` reports `hosts: ["client.read"]` on
  `tests::server::http2_keep_alive_count_server_pings` and `…_detects_unresponsive_client`
  (`tests/server.rs:2661`, `:2514`). `client.read` is a method call, not a host. Over-charge direction.
- **D3 — `--include-tests` has no way to mean "tests".** It also admits `benches/` and `examples/`;
  30+ of hyper's 174 `deny Net` violations are benches.
- **D4 — `candor-swift --target <ATestTarget>` names a target its verdict excludes.** stderr says
  *"resolved via Package.swift: scanning 4 target(s) [ArgumentParser, ArgumentParserEndToEndTests,
  ArgumentParserTestHelpers, ArgumentParserToolInfo], 43 of 76 source file(s). This verdict covers that
  closure ONLY"* and the report then contains 0 functions from `Tests/` (67 excluded as `harness-target`).
  The `excluded` array discloses it; the stderr line contradicts it.
- **D5 — candor-ts's test exclusion is filename-shaped, and candor-ts's own repo does not match it.**
  A self-scan of `/Users/tom/git/candor-ts` returns `excluded: []` — `test.mjs` (132 entries),
  `test-unit.mjs`, `test-lsp.mjs`, `test-mcp.mjs`, `fuzz.mjs`, `sensitivity.mjs` and `soundness/` are all
  analysed as production code, because `isTestPath` wants a `test/` **segment** or a `.test.` **infix**.
  241 of the repo's 706 entries are harness.
- **D6 — `Fs` charged where no file is opened.** `tokio`'s `open_options_windows_custom_flags` is charged
  `Fs` for `OpenOptions::new().custom_flags(…)` inside a `format!("{:?}", …)` assertion. Safe direction.
- **D7 — `cmds` loses the head on a builder-chain spawn.** 0 of 17 `Exec`-charged entries in tokio's
  `tests/` carry a `cmds` literal; the files contain 10 literal `Command::new("…")` sites. The pattern
  `let mut cmd = Command::new("bash"); …; cmd.spawn()` separates the literal from the effect site.

## The slices that look weak — unchanged, and now with the reason

- **Test selection / impact analysis** (*"given this diff, which tests must run?"*) wants PRECISION.
  A static over-approximation over-selects by construction, and `Unknown` is 33–84% of test functions
  (measured above, worse than the 20% this document previously cited from `eval/unknownwhy-sweep`).
  You would re-run most of the suite most of the time. The real question is also dynamic.
- **Coverage-shaped questions** (*"which effectful functions have no test?"*) need coverage data joined
  to candor's effect map. candor supplies one half and has no view of the other. An integration, not a
  product.

## How to reproduce

Installed binaries only; nothing was built.

```
candor-scan <crate> --json                    # baseline
candor-scan <crate> --include-tests --json    # test code included; diff the two function sets
candor-java build/classes/java/test --json    # java: no flag, point at the test classes
npx candor-ts <project>/test --allow-js --json # ts: point at the test dir (the flag does not exist)
candor-swift <pkg> --target <TestTarget> --json # swift: still excludes the target it names
```

The census is `jq` over the report: `.functions[] | select(.hosts or .paths or .cmds)`.
Working files from this investigation are in the session scratchpad under `testtool/`, prefixed
`testtool-`.
