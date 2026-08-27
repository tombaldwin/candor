#!/usr/bin/env bash
# THE CORPUS ROUND — every engine over real third-party code, with oracles that need no ground truth.
#
# WHY THIS EXISTS AS A SCRIPT. The 2026-08-13 round was built ad-hoc in a scratchpad and found TWO
# cardinal sins that 40+ conformance parts and every engine's own suite had missed:
#
#   · candor-ts judged callers of BODY-LESS DECLARATIONS pure — `deny Unknown` green where rust/java/
#     swift exit 1, and `deny Net` green on axios, whose entire report turned out to be 54 `.d.ts`
#     declarations while its 61 `.js` implementation files were never analyzed;
#   · candor-swift's `incomplete` did not propagate caller-ward — 8 of 8 callers in Alamofire read
#     CERTAIN off an uncertain callee, where candor-rust propagated 34 of 34.
#
# Neither is reachable from a hand-written fixture, because neither was a case anyone thought to write.
# A round that lives in a scratchpad is a round that gets reconstructed from memory next time, slightly
# differently, which is how a measurement stops being comparable. So: run this before a release.
#
# THIS SCRIPT IS THE AUTOMATED, HERMETIC HALF OF A CORPUS ROUND. For the manual, ad-hoc half it does
# NOT cover — published-artifact testing, cross-arm comparisons, an audit that needs a human/agent
# judgment call about scope — read bin/AGENT-CORPUS-BRIEF.md first. It is the paste-able method doc
# a single night's round was distilled into after finding thirteen cardinal sins this script's two
# oracles could not have caught.
#
# WHAT IT IS NOT. It is NOT `candor-java/eval/corpus-crossorg/run.sh` — that is the paper's PRE-REGISTERED
# RQ1 evidence, hash-pinned to a FROZEN engine, and it aborts on a current build. Leave it frozen. This
# writes only under its own work dir and NEVER under any `eval/` (see the standing rule: do not run a
# WRITING script to answer a READ-ONLY question).
#
# USAGE
#   bin/corpus.sh                 # acquire (once) + scan + oracles
#   bin/corpus.sh --oracles-only  # re-run the oracles over existing artifacts
#   CORPUS_HOME=<dir> bin/corpus.sh
#
# EXIT 0 iff every oracle passed. Findings print as `FINDING:` lines.
set -uo pipefail

HOME_DIR="${CORPUS_HOME:-${TMPDIR:-/tmp}/candor-corpus}"
GIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RS="${CANDOR_RUST:-$GIT_ROOT/candor-rust}/target/debug"
SW="${CANDOR_SWIFT:-$GIT_ROOT/candor-swift}/.build/debug/candor-swift"
TS="${CANDOR_TS:-$GIT_ROOT/candor-ts}"
JAR="${CANDOR_JAR:-$(ls -t "$GIT_ROOT"/candor-java/build/libs/*-all.jar 2>/dev/null | head -1)}"
HONESTY="${CANDOR_SPEC:-$GIT_ROOT/candor-spec}/conformance/check_honesty.py"
SRC="$HOME_DIR/src"; JARS="$HOME_DIR/jars"; OUT="$HOME_DIR/out"; LOG="$HOME_DIR/log"
mkdir -p "$SRC" "$JARS" "$OUT" "$LOG"
findings=0
finding() { echo "  FINDING: $*"; findings=$((findings+1)); }

# ── WHICH ENGINES ARE ACTUALLY HERE ────────────────────────────────────────────────────────────────
# Every engine step below is guarded by a `[ -x … ]`, so a missing engine SKIPS — and the summary said
# `corpus: OK — no findings` either way. Three engines checked and four engines checked printed the same
# line, which is ⟨0.26⟩'s rule exactly: a PARTIAL manifest answers worse than an absent one, because the
# reader cannot tell the difference and has no reason to suspect one.
#
# That was tolerable while this only ran by hand on a machine with all four built. It stops being
# tolerable the moment it runs on a schedule, where nobody is watching the roster — and ubuntu has no
# swift toolchain, so the partial case is the DEFAULT there rather than an accident.
#
# So: the roster is always printed, and `CORPUS_REQUIRE_ALL=1` turns an absence into a failure. Same
# name and same idea as conformance's `CONFORMANCE_REQUIRE_ALL=1`, which exists for the same reason.
# SELF-PROVISION candor-ts's DEPENDENCIES, exactly as `conformance/run.sh` does — the engine imports the
# TypeScript compiler, so a fresh checkout has `scan.mjs` and no way to run it. Putting this HERE rather
# than in the workflow means every caller works: CI, a new machine, a human who just cloned. The first CI
# run of this script failed precisely because the install lived nowhere and the workflow did not know to
# do it.
if [ -f "$TS/package.json" ] && [ ! -d "$TS/node_modules" ]; then
  # `npm ci` when there is a lockfile: it is deterministic and, unlike `npm install`, does NOT rewrite
  # `package-lock.json`. That matters because this may run against somebody's working tree — the first
  # draft used `npm install` and left a modified lockfile behind in candor-ts.
  echo "[engines] installing candor-ts dependencies (first run on this checkout)"
  if [ -f "$TS/package-lock.json" ]; then
    ( cd "$TS" && npm ci --no-fund --no-audit >/dev/null 2>&1 ) || true
  else
    ( cd "$TS" && npm install --no-fund --no-audit >/dev/null 2>&1 ) || true
  fi
fi

# PRESENCE IS NOT CAPABILITY, and this check learned that the hard way on its first CI run. It asked
# `[ -f "$TS/scan.mjs" ]`, the file was there, the roster said `present: rust java ts swift` — and every
# single ts scan returned rc=1, because the workflow had no `npm ci` and the TypeScript compiler the
# engine imports was not installed. `CORPUS_REQUIRE_ALL=1` reported full coverage over an engine that
# could not run a single target: the exact false assurance the flag exists to prevent, produced BY the
# flag. (`verify-local.sh` already carries this lesson for its own ts arm — it asserts the binaries LOAD
# rather than that a file exists.)
#
# So each engine is ASKED something. `--version` is the cheapest question that exercises the real entry
# point: it parses args, loads every module, and answers. An engine that cannot answer it cannot scan.
ask() { "$@" --version >/dev/null 2>&1; }
present=""; absent=""
ask "$RS/candor-scan"        && present="$present rust"  || absent="$absent rust"
{ [ -n "$JAR" ] && [ -f "$JAR" ] && ask java -jar "$JAR"; } \
                             && present="$present java"  || absent="$absent java"
{ [ -f "$TS/scan.mjs" ] && ask node "$TS/scan.mjs"; } \
                             && present="$present ts"    || absent="$absent ts"
ask "$SW"                    && present="$present swift" || absent="$absent swift"
echo "[engines] present:${present:- none}${absent:+   ABSENT:$absent}"
if [ -n "$absent" ] && [ "${CORPUS_REQUIRE_ALL:-0}" = "1" ]; then
  echo "corpus: REFUSING — CORPUS_REQUIRE_ALL=1 and these engines cannot answer \`--version\`:$absent"
  echo "  Not built, or built and unable to START — a missing \`npm ci\` leaves candor-ts's scan.mjs on"
  echo "  disk and unable to load, which is how this roster once reported four engines over three."
  echo "  Build/install them, or drop the flag and read the roster above."
  exit 1
fi
if [ -z "$present" ]; then
  echo "corpus: REFUSING — no engine is built, so every oracle below would pass over nothing"
  exit 1
fi

# ── acquire ────────────────────────────────────────────────────────────────────────────────────────
# TAG-PINNED so a re-run measures the same bytes; shallow; nothing is BUILT. rust/ts/swift scan source,
# and java takes prebuilt jars from Maven Central — a jar target means the round needs no JVM build.
acquire() {
  clone() { [ -d "$SRC/$1" ] && return 0
    git clone -q --depth 1 --branch "$3" "$2" "$SRC/$1" 2>/dev/null && echo "  got $1@$3" || echo "  MISS $1@$3"; }
  clone ripgrep https://github.com/BurntSushi/ripgrep 14.1.1
  clone clap    https://github.com/clap-rs/clap       v4.5.4
  clone serde   https://github.com/serde-rs/serde     v1.0.203
  clone regex   https://github.com/rust-lang/regex    1.10.5
  clone zod     https://github.com/colinhacks/zod     v3.23.8
  clone chalk   https://github.com/chalk/chalk        v5.3.0
  clone hono    https://github.com/honojs/hono        v4.4.6
  # axios is DELIBERATELY in the set: its implementation is `.js` and its typings are `.d.ts`, which is
  # the exact shape that exposed the ts declaration-purity defect. Do not drop it for being "not really
  # TypeScript" — that property is the point.
  clone axios   https://github.com/axios/axios        v1.7.2
  # ⟨0.29⟩ got + zx — added because the ts arm of THIS HARNESS was structurally blind. MEASURED across the
  # four projects above: TWO effect-bearing functions in total, against 1523 Fs in java, 72 in rust and 16
  # in swift. zod and chalk are genuinely near-pure, hono's effects sit behind adapters, and axios is the
  # deliberate `.d.ts` case — so every ts oracle was reporting on almost nothing, and oracle [2] read
  # `unmeasured` for exactly the reason java did until it began publishing `incomplete`: not clean, BLIND.
  #
  # BOTH MUST BE TYPESCRIPT IMPLEMENTATIONS, and the first attempt was not: `execa` looks ideal (it spawns
  # processes with computed commands) and is `index.js` + `lib/**/*.js` behind an `index.d.ts` — so
  # candor-ts analysed ONE unit of it, exactly like axios. A package being written "in TypeScript" on its
  # README is not the same as shipping `.ts` sources, and the corpus is where that difference shows.
  #   got — `source/**/*.ts`, an HTTP client: 217 analyzed, 111 effectful, 21 Net. Gives the ts arm of
  #         oracles [1] and [3] something to be about.
  #   zx  — `src/*.ts`, a shell wrapper: Fs with COMPUTED paths, so it exercises the `incomplete` marker
  #         and callers of incomplete functions — the shape oracle [2] could not see for this engine.
  clone got     https://github.com/sindresorhus/got     v14.4.1
  clone zx      https://github.com/google/zx            8.1.4
  clone swift-argument-parser https://github.com/apple/swift-argument-parser 1.4.0
  clone alamofire             https://github.com/Alamofire/Alamofire         5.9.1
  # ⟨2026-08-21⟩ FOUR TREES ADDED AFTER THE 0.31 CUT, each for a SHAPE the set above lacks — the point of
  # a corpus is code nobody wrote for us, and a set that stops growing stops finding things. The existing
  # twelve had been run clean for several rounds.
  #   tokio     a LARGE cargo workspace (10 member reports). The §3.1 ordering break that ⟨0.31⟩ fixed
  #             needed one invocation producing SEVERAL reports for the gate route to re-merge; ripgrep
  #             has 7 and was the only tree here with that shape at all.
  #   hyper     async Net-heavy rust, and a single-crate counterweight to tokio.
  #   execa     a ts package whose whole purpose is child_process — the densest Exec surface available,
  #             where every other ts entry here is Net- or pure-shaped.
  #   swift-nio a large swift package with many targets, against alamofire's single one.
  clone tokio     https://github.com/tokio-rs/tokio  tokio-1.38.0
  clone hyper     https://github.com/hyperium/hyper  v1.4.0
  clone execa     https://github.com/sindresorhus/execa v9.3.0
  clone swift-nio https://github.com/apple/swift-nio 2.68.0
  local M=https://repo1.maven.org/maven2
  jar() { [ -f "$JARS/$1" ] && return 0; curl -fsSL -o "$JARS/$1" "$2" && echo "  got $1" || echo "  MISS $1"; }
  jar gson.jar          $M/com/google/code/gson/gson/2.11.0/gson-2.11.0.jar
  jar commons-lang3.jar $M/org/apache/commons/commons-lang3/3.14.0/commons-lang3-3.14.0.jar
  jar jackson-core.jar  $M/com/fasterxml/jackson/core/jackson-core/2.17.1/jackson-core-2.17.1.jar
  jar joda-time.jar     $M/joda-time/joda-time/2.12.7/joda-time-2.12.7.jar
  # sqlite-jdbc is DELIBERATELY in the set, and it is the only jar here that produces the shape:
  # a method that is DISCLOSED-INCOMPLETE while carrying NO EFFECT. candor-java computed that
  # uncertainty (the `incompleteAcc` fixpoint) and then DISCARDED it at the report boundary, because the
  # serialization filter admitted a method only for effects / entry-point / blindness / a declaring
  # class. Absence from `functions` means PURE, so two callers read CERTAIN off an uncertain callee and
  # oracle [1] said DISHONEST — the shape that was a cardinal sin in candor-swift on Alamofire. Do not
  # drop this jar for being "another database driver": no other jar in the corpus reaches that filter.
  jar sqlite-jdbc.jar   $M/org/xerial/sqlite-jdbc/3.46.0.0/sqlite-jdbc-3.46.0.0.jar
}

# ── scan ───────────────────────────────────────────────────────────────────────────────────────────
# Produce only. Oracles run afterwards over the artifacts, so a judgement bug cannot silently discard a
# scan that would otherwise have to be re-done.
scan() {
  local rc
  run() { local eng=$1 item=$2; shift 2
    "$@" > "$LOG/$eng.$item.out" 2> "$LOG/$eng.$item.err"; rc=$?
    echo "  $eng/$item rc=$rc"
    # 0 = clean, 1 = a gate fired, 2 = a refusal. Anything else is a crash, and a crash is a finding.
    case "$rc" in 0|1|2) ;; *) finding "$eng/$item exited $rc — not one of {0,1,2}" ;; esac
    grep -qE "panicked|Exception in thread|Traceback|RUST_BACKTRACE|internal error" "$LOG/$eng.$item.err" \
      && finding "$eng/$item stderr carries a crash signature: $(grep -m1 -E 'panicked|Exception in thread|Traceback|internal error' "$LOG/$eng.$item.err" | cut -c1-100)"
  }
  for r in ripgrep clap serde regex tokio hyper; do [ -d "$SRC/$r" ] && run rust "$r" "$RS/candor-scan" "$SRC/$r" --out "$OUT/rust.$r"; done
  # axios exits 2 with "no TypeScript sources" ONLY if its `.d.ts` is excluded; it currently scans. A
  # JS-only tree (express) legitimately refuses at exit 2 — that is candor-ts being right, not a finding,
  # which is why the set holds no JS-only package.
  for t in zod chalk hono axios got zx execa; do [ -d "$SRC/$t" ] && run ts "$t" node "$TS/scan.mjs" "$SRC/$t" --out "$OUT/ts.$t"; done
  for s in swift-argument-parser alamofire swift-nio; do [ -d "$SRC/$s" ] && run swift "$s" "$SW" "$SRC/$s" --out "$OUT/swift.$s"; done
  # java's file sink is `--json <file>`, NOT `--out <prefix>`. Getting this wrong makes all four java
  # rows exit 2 on an unknown flag — which is §6.2 behaving correctly, and reads as an engine defect.
  for j in "$JARS"/*.jar; do [ -f "$j" ] || continue; local n; n=$(basename "$j" .jar)
    run java "$n" java -jar "$JAR" "$j" --json "$OUT/java.$n.json"; done
}

# ── oracles ────────────────────────────────────────────────────────────────────────────────────────
oracles() {
  echo "  [1] honesty invariant — uncertainty must propagate caller-ward"
  local n=0
  for f in "$OUT"/*.json; do
    case "$f" in *.callgraph.json|*.locs.json|*.hierarchy.json) continue;; esac
    [ -s "$f" ] || continue; n=$((n+1))
    python3 "$HONESTY" "$f" >"$LOG/honesty.txt" 2>&1 \
      || finding "honesty: $(basename "$f") — $(grep -m1 '✗' "$LOG/honesty.txt" | sed 's/^ *//' | cut -c1-140)"
  done
  echo "      $n reports checked"
  # LIMIT, stated because a green here is routinely over-read: check_honesty.py catches uncertainty an
  # engine HAD and failed to propagate. It cannot see BLINDNESS — a call or effect never registered — and
  # it called the axios report HONEST while that report was a false all-clear for an HTTP client. Only the
  # cross-engine differential below reaches that class.
  echo "  [2] incomplete-propagation, per engine (rust is the reference: 34/34 on the 2026-08-13 corpus)"
  python3 - "$OUT" <<'PY'
import json,glob,os,sys,collections
OUT=sys.argv[1]
tot=collections.Counter(); callers=collections.Counter(); prop=collections.Counter()
seen=collections.Counter(); dropped=collections.Counter()
for f in sorted(glob.glob(OUT+"/*.json")):
    b=os.path.basename(f)
    if any(x in b for x in (".callgraph.",".locs.",".hierarchy.")): continue
    eng=b.split(".")[0]
    if eng not in ("rust","ts","swift","java"): continue   # a stray file must not invent an engine
    cg=f.rsplit(".json",1)[0]+".callgraph.json"
    # DROPS ARE COUNTED, NOT SWALLOWED. Both `continue`s below used to be silent, so an engine whose
    # sidecars were all missing or unparseable contributed nothing and printed as though it had been
    # asked — the same shape as the skip this file already refuses one oracle down. An engine that
    # produced reports and lost every one of them is UNMEASURED, and the table has to say so.
    if not os.path.exists(cg): dropped[eng]+=1; seen[eng]+=1; continue
    try: d=json.load(open(f)); g=json.load(open(cg))
    except Exception: dropped[eng]+=1; seen[eng]+=1; continue
    seen[eng]+=1
    fns={x.get("fn") or x.get("name"):x for x in d.get("functions",[])}
    inc={k for k,v in fns.items() if v.get("incomplete")}
    tot[eng]+=len(inc)
    for k,edges in g.items():
        if any(e in inc for e in (edges or [])):
            callers[eng]+=1
            if (fns.get(k) or {}).get("incomplete"): prop[eng]+=1
bad=0
for e in sorted(set(tot)|set(callers)|set(seen)):
    note = "" if callers[e]==prop[e] else "  <-- FINDING"
    if callers[e]!=prop[e]: bad=1
    if dropped[e]:
        note += "  [%d/%d report(s) unusable: no or unparseable callgraph sidecar]" % (dropped[e], seen[e])
    # Every report an engine produced was dropped: it is UNMEASURED here, which must not read as a pass.
    if seen[e] and dropped[e] == seen[e]:
        bad=1; note += "  <-- FINDING: this engine was not measured at all"
    # 0 callers is NOT a pass, it is an UNASKED question — say so rather than printing a flattering 0/0.
    state = "unmeasured (no caller of an incomplete fn in this corpus)" if callers[e]==0 else \
            "%d/%d propagated" % (prop[e], callers[e])
    print("      %-7s incomplete=%-4d %s%s" % (e, tot[e], state, note))
sys.exit(1 if bad else 0)
PY
  [ $? -ne 0 ] && finding "an engine does not propagate \`incomplete\` caller-ward (see the table above)"
  echo "  [3] cross-engine: a caller of a BODY-LESS declaration must not read pure"
  # The differential that found the ts defect, as a fixture rather than a corpus scan — the corpus is
  # what made it worth asking, but a 6-line fixture is what makes it re-runnable and unambiguous.
  local P="$HOME_DIR/decl"; rm -rf "$P"; mkdir -p "$P/ts/src" "$P/rust/src" "$P/swift"
  printf 'export declare function fetchIt(u: string): Promise<string>;\n' > "$P/ts/index.d.ts"
  printf 'import { fetchIt } from "../index";\nexport async function caller(): Promise<string> { return await fetchIt("https://x.example.com"); }\n' > "$P/ts/src/app.ts"
  printf '{"name":"c","version":"1.0.0","types":"index.d.ts"}\n' > "$P/ts/package.json"
  printf '{"compilerOptions":{"module":"node16","strict":true,"noEmit":true}}\n' > "$P/ts/tsconfig.json"
  printf 'pub trait Store { fn put(&self, k: &str); }\npub fn caller<S: Store>(s: &S) { s.put("k"); }\n' > "$P/rust/src/lib.rs"
  printf '[package]\nname="c"\nversion="0.1.0"\nedition="2021"\n' > "$P/rust/Cargo.toml"
  printf 'public protocol Store { func put(_ k: String) }\npublic func caller(_ s: Store) { s.put("k") }\n' > "$P/swift/a.swift"
  # java was NOT in this oracle — three engines asked, the fourth, the REFERENCE engine, never. The
  # sibling-route shape this project keeps finding: a rule applied where the work happened and not to the
  # arm beside it. Its body-less declaration is an interface method, the same shape as the Store protocol.
  mkdir -p "$P/java"
  printf 'public interface Store { void put(String k); }\n' > "$P/java/Store.java"
  printf 'public class Caller { public static void caller(Store s) { s.put("k"); } }\n' > "$P/java/Caller.java"
  javac -d "$P/java/classes" "$P/java/Store.java" "$P/java/Caller.java" >/dev/null 2>&1
  printf 'deny Unknown\n' > "$P/pol"
  node "$TS/scan.mjs" "$P/ts" --out "$P/t" >/dev/null 2>&1
  "$RS/candor-scan" "$P/rust" --out "$P/r" >/dev/null 2>&1
  [ -x "$SW" ] && "$SW" "$P/swift" --out "$P/s" >/dev/null 2>&1
  # `deny Unknown` is the gate whose whole purpose is "fail if candor cannot see what this reaches".
  # An engine that cannot see the declaration's body and says nothing exits 0 here; the others exit 1.
  # First report matching a glob, skipping the callgraph sidecar. A glob loop, not `ls | grep`:
  # an unmatched glob stays literal, so the `-e` guard is what makes 'no report' distinguishable
  # from 'a report named callgraph'.
  pick() { local f; for f in "$@"; do case "$f" in *callgraph*) continue;; esac
           [ -e "$f" ] && { printf '%s' "$f"; return 0; }; done; return 0; }
  gate() { local eng=$1 rep=$2; shift 2
    # A MISSING REPORT IS NOT A PASS. This printed "(no report — skipped)" and returned, so an engine
    # whose scan failed — a crash, a flag rename, an empty tree — sailed through the one oracle built to
    # catch its cardinal sin, and the run stayed green. The check that cannot fail is the check that is
    # not there. `[ -x "$SW" ]` above is the legitimate engine-absent skip; this is a present engine that
    # produced nothing.
    [ -s "$rep" ] || { finding "$eng: produced NO report for the body-less-declaration oracle — the check
      could not run, and an unrun check is not a green one"; return; }
    "$@" gate --report "$rep" --policy "$P/pol" >/dev/null 2>&1
    local rc=$?
    # …AND THE SAME RULE ON THE EXIT CODE, which is where this check was still open. The clause above
    # refuses a missing REPORT; four lines later ANY nonzero rc counted as "discloses", so a missing
    # BINARY passed. MEASURED 2026-08-17 running the round against the PUBLISHED artifacts: the tree had
    # candor-scan and not candor-query, the verb never executed, and `rust exit=127 (discloses)` printed
    # beside three engines that had genuinely answered. 127 is `command not found` — the check that could
    # not run, reported as the check that passed, which is the sibling of the defect this block fixes.
    #
    # So the EXPECTATION is now stated positively: exit 1, the gate firing. Every other answer says
    # something different and none of them is this oracle passing — 0 is the cardinal sin, 127 is an
    # engine that never ran, and 2 is "could not evaluate", which is not a false all-clear but is not a
    # disclosure either. All four engines answer 1 on this corpus today, so this tightens onto observed
    # behaviour rather than onto a hope.
    case "$rc" in
      0)   finding "$eng: \`deny Unknown\` is GREEN over a caller of a body-less declaration — it read PURE (cardinal sin; the other engines exit 1)" ;;
      1)   echo "      $eng  exit=1 (discloses)" ;;
      127) finding "$eng: the gate verb could not be RUN (exit 127, command not found) — the check did not
      execute, and an unrun check is not a green one. Check the engine path/build for this arm." ;;
      *)   finding "$eng: the gate answered exit $rc over a caller of a body-less declaration, not the
      expected 1. That is not the cardinal sin, but it is not the disclosure this oracle asserts either —
      read the run before treating it as covered." ;;
    esac; }
  [ -f "$JAR" ] && java -jar "$JAR" "$P/java/classes" --json "$P/j.json" >/dev/null 2>&1
  gate "ts   " "$P/t.json" node "$TS/query.mjs"
  gate "rust " "$(pick "$P"/r.*.scan.json)" "$RS/candor-query"
  [ -x "$SW" ] && gate "swift" "$(pick "$P"/s.*.Swift.json)" "$SW"
  [ -f "$JAR" ] && gate "java " "$P/j.json" java -jar "$JAR"

  # ── [6] SEEDED-VIOLATION SENSITIVITY, ON REAL CODE ─────────────────────────────────────────────
  # Every other oracle here asks whether a report CONTRADICTS itself. None asks the question that
  # matters most: **if a real project performed a denied effect, would this engine say so?** A corpus
  # round that reports nothing is consistent with an engine that reports nothing.
  #
  # So: copy a real crate/package, append ONE function performing a denied effect, and require the gate
  # to name it. The CONTROL is the same tree unseeded — without it, an engine that charges everything
  # passes the seeded arm while being useless, and the control also catches a probe that is matching on
  # a name that was already there.
  #
  # Verified for candor-rust, candor-ts, candor-swift and candor-java at 0.31.0 before this was written;
  # rust and ts run here because they seed cheaply from trees already cloned. The rust arm is the one
  # whose EXIT flips (regex under `deny Net` is 0 unseeded, 1 seeded), so it discriminates on the verdict
  # and not merely on a name appearing.
  echo "  [6] a seeded violation in real code is REPORTED (sensitivity, not just consistency)"
  if [ -x "$RS/candor-scan" ] && [ -d "$SRC/regex" ]; then
    rm -rf "$OUT/seed"; mkdir -p "$OUT/seed"
    cp -R "$SRC/regex" "$OUT/seed/regex" 2>/dev/null
    printf '\npub fn candor_seeded_probe() {\n    let _ = std::net::TcpStream::connect("seeded.example:443");\n}\n' \
      >> "$OUT/seed/regex/src/lib.rs"
    printf 'deny Net\n' > "$OUT/seed/pol"
    "$RS/candor-scan" "$OUT/seed/regex" --policy "$OUT/seed/pol" --out "$OUT/seed/s" >/dev/null 2>&1; sx=$?
    "$RS/candor-scan" "$SRC/regex"      --policy "$OUT/seed/pol" --out "$OUT/seed/c" >/dev/null 2>&1; cx=$?
    python3 - "$OUT/seed" "$sx" "$cx" <<'PY6'
import json, glob, sys
O, sx, cx = sys.argv[1], sys.argv[2], sys.argv[3]
def has(pfx):
    return any("candor_seeded_probe" in fn["fn"]
               for f in glob.glob(f"{O}/{pfx}.*.scan.json") if ".callgraph." not in f and ".hierarchy." not in f
               for fn in (json.load(open(f)).get("functions") or []))
seeded, control = has("s"), has("c")
if not seeded:
    print("      FINDING: a seeded Net call in a real crate was NOT reported — the engine read the tree")
    print("      and did not say what it found, which is the cardinal sin on real code"); sys.exit(1)
if control:
    print("      FINDING: the CONTROL tree also reports the seeded fn — this probe is matching something")
    print("      that was already there, so the seeded arm proves nothing"); sys.exit(1)
if sx == cx:
    print(f"      FINDING: seeding a denied effect did not move the verdict (both exit {sx}) — the gate")
    print("      names the function but does not act on it"); sys.exit(1)
print(f"      rust: seeded exit {sx} vs control exit {cx}; the seeded fn is named only when seeded")
PY6
    [ $? -eq 0 ] || finding "seeded-violation sensitivity: see the rows above"
  else
    echo "      SKIP (needs the rust engine and regex)"
  fi

  # ── [5] CHAINING A DEP REPORT MAY ONLY ADD ─────────────────────────────────────────────────────
  # SPEC §2: a consumer that chains a dependency's report inherits that dependency's effects. So for any
  # function present in BOTH the plain and the chained scan, the chained effect set is a SUPERSET. A
  # function that LOSES an effect when more information arrives is the cardinal sin with extra steps —
  # the run knows more and reports less.
  #
  # Conformance pins this on fixtures (adding a call only ever ADDS). This asks it of a real dependency
  # graph, where the join is doing real work: regex's seven member reports chained into ripgrep move 33
  # functions. That count is also the NON-VACUITY signal and is checked — a run where chaining changes
  # nothing proves the property over an empty set, which is how this oracle would rot silently if the
  # locator or the env var ever stopped being read.
  echo "  [5] chaining a dep report may only ADD (SPEC §2, on a real dependency graph)"
  if [ -x "$RS/candor-scan" ] && [ -d "$SRC/regex" ] && [ -d "$SRC/ripgrep" ]; then
    rm -f "$OUT"/ch.* 2>/dev/null
    "$RS/candor-scan" "$SRC/regex"   --out "$OUT/ch.dep"   >/dev/null 2>&1
    # A glob and a loop, not `ls | grep`: shellcheck SC2010 is a WARNING and CI lints at -S warning, so
    # the pipeline form turns shell-lint red. It is also the correct form — a filename with a newline in
    # it would split the list.
    DEPS_LIST=""
    for _d in "$OUT"/ch.dep.*.scan.json; do
      case "$_d" in *.callgraph.json|*.hierarchy.json|*'*'*) continue ;; esac
      DEPS_LIST="${DEPS_LIST:+$DEPS_LIST,}$_d"
    done
    "$RS/candor-scan" "$SRC/ripgrep" --out "$OUT/ch.plain" >/dev/null 2>&1
    CANDOR_DEPS="$DEPS_LIST" "$RS/candor-scan" "$SRC/ripgrep" --out "$OUT/ch.chained" >/dev/null 2>&1
    python3 - "$OUT" <<'PY5'
import json, glob, sys
O = sys.argv[1]
def load(pfx):
    # UNION, not overwrite. A qualified name can appear in more than one member report, and keying by
    # name with `=` keeps whichever file loaded LAST — so a member that genuinely lost an effect is
    # masked by an intact copy elsewhere. Found while calibrating: stripping an effect from one file
    # produced NO detection, and the same strip applied to both occurrences produced it. An oracle whose
    # failure arm cannot be demonstrated is not an oracle, and this one was one `=` away from silently
    # under-reporting the thing it exists to catch.
    out = {}
    for f in glob.glob(f"{O}/ch.{pfx}.*.scan.json"):
        if ".callgraph." in f or ".hierarchy." in f: continue
        for fn in json.load(open(f)).get("functions") or []:
            out.setdefault(fn["fn"], set()).update(fn.get("inferred") or [])
    return out
a, b = load("plain"), load("chained")
shared = set(a) & set(b)
shrunk = [k for k in shared if a[k] - b[k]]
grew   = [k for k in shared if b[k] - a[k]]
if not shared:
    print("      FINDING: chain-monotonicity compared NOTHING — no shared function between the plain and")
    print("      chained scans, so the property held over an empty set and this oracle proved nothing")
    sys.exit(1)
if not grew:
    print(f"      FINDING: chaining changed NO effect set across {len(shared)} shared function(s) — the")
    print("      dep locator or CANDOR_DEPS is not being read, so this oracle is passing vacuously")
    sys.exit(1)
if shrunk:
    print(f"      FINDING: {len(shrunk)} function(s) LOST an effect when a dep report was chained — more")
    print("      information produced a smaller answer, which is the cardinal sin with extra steps:")
    for k in shrunk[:5]:
        print(f"        {k}: {sorted(a[k])} -> {sorted(b[k])}")
    sys.exit(1)
print(f"      {len(shared)} shared fn(s); chaining grew {len(grew)}, shrank 0")
PY5
    [ $? -eq 0 ] || finding "chain-monotonicity: see the rows above"
  else
    echo "      SKIP (needs the rust engine plus regex and ripgrep)"
  fi

  # ── [4] §3.1 ROUTE EQUALITY, ON CODE WE DID NOT WRITE ───────────────────────────────────────────
  # `ci/gate-equivalence.sh` asserts this already — over candor's OWN four crates, which is where its
  # fixtures could reach. That is exactly where the ⟨0.29⟩ peek defect lived (the nested scan of the
  # excluded set fed the gate's analyzed counter, so `scan --policy` said 276 and its own report said
  # 129), and it is a shape that only appears in trees with real exclusions and multiple packages.
  # Third-party corpus code has both and candor's crates mostly do not: rusqlite ships a `-sys` crate
  # beside the binding, walkdir a bin beside the lib, and each writes ONE REPORT PER PACKAGE.
  #
  # Cheap because the projects are already cloned above. rust only, because it is the engine that has
  # both routes as separate binaries; the same property on the other engines is pinned by conformance.
  echo "  [4] §3.1 route equality on THIRD-PARTY trees (scan --policy ≡ gate --report, byte-level)"
  # TWO counters, not one. `re_ok` alone made "every comparison FAILED" indistinguishable from "no
  # comparison happened": the vacuity guard below fired a fifth, false finding beside four real ones on
  # the calibration run. A guard against measuring nothing must not also fire when the measurement worked
  # and the answer was bad.
  local re_ok=0 re_tried=0
  for pair in ripgrep:Fs clap:Env serde:Unknown regex:Unknown tokio:Fs; do
    local proj="${pair%%:*}" eff="${pair##*:}"
    [ -d "$SRC/$proj" ] || continue
    re_tried=$((re_tried+1))
    printf 'deny %s\n' "$eff" > "$OUT/re.pol"
    rm -f "$OUT/re.a" "$OUT/re.b" "$OUT"/re.rep.*
    "$RS/candor-scan" "$SRC/$proj" --out "$OUT/re.rep" --policy "$OUT/re.pol" --gate-json "$OUT/re.a" >/dev/null 2>&1
    local ra=$?
    "$RS/candor-query" gate --report "$OUT/re.rep" --policy "$OUT/re.pol" --gate-json "$OUT/re.b" >/dev/null 2>&1
    local rb=$?
    if [ ! -s "$OUT/re.a" ] || [ ! -s "$OUT/re.b" ]; then
      finding "route-equality $proj: a --gate-json document was not written (scan $ra, gate $rb) — the
      comparison did not happen, and a comparison that did not happen is not an agreement"
    elif [ "$ra" != "$rb" ]; then
      finding "route-equality $proj: scan --policy exited $ra and gate --report exited $rb over the SAME
      report — two routes into one gate have become two gates (SPEC §3.1)"
    elif ! cmp -s "$OUT/re.a" "$OUT/re.b"; then
      finding "route-equality $proj: verdict documents DIFFER: $(diff "$OUT/re.a" "$OUT/re.b" | head -4 | tr '\n' ' ')"
    else
      re_ok=$((re_ok+1)); echo "      $proj  deny $eff → both routes exit $ra, verdicts byte-equal"
    fi
  done
  [ "$re_tried" = 0 ] && finding "route-equality: NO project was compared — the corpus did not clone, so
      this oracle measured nothing, and printing nothing here would read as agreement"
}

echo "corpus: $HOME_DIR"
# A STALE ARTIFACT MANUFACTURES A FINDING. Caught on this script's first run: `--oracles-only` reported
# swift at 54/55 propagated, which read exactly like a residual defect. It was one report produced BEFORE
# the fix that made the other 54 pass — re-scanning gave 55/55. An oracle is only as current as the bytes
# it reads, and the failure is silent and looks like a result.
#
# Narrow on purpose: artifact-vs-binary mtime, and ONLY in `--oracles-only`, because a full run rescans
# everything and the question cannot arise. A broader "is anything stale" check is what false-positived on
# probe.sh's build→test→commit ordering; this one asks a smaller question with a definite answer.
if [ "${1:-}" = "--oracles-only" ]; then
  stale=0
  for pair in "rust:$RS/candor-scan" "ts:$TS/scan.mjs" "swift:$SW" "java:$JAR"; do
    eng=${pair%%:*}; bin=${pair#*:}; [ -e "$bin" ] || continue
    for a in "$OUT/$eng."*.json; do
      [ -e "$a" ] || continue
      if [ "$a" -ot "$bin" ]; then
        stale=$((stale+1))
        [ "$stale" -le 3 ] && echo "  STALE: $(basename "$a") predates $(basename "$bin")"
      fi
    done
  done
  [ "$stale" -gt 3 ] && echo "  STALE: … and $((stale-3)) more"
  [ "$stale" -gt 0 ] && {
    echo "corpus: REFUSING — artifacts older than the engine that reads them produce findings about the PAST."
    echo "  Remedy: drop --oracles-only. The full run rescans, which is why the question cannot arise there."
    echo "  This IS strict: any engine rebuild invalidates prior artifacts. That is the correct reading —"
    echo "  they were produced by a different binary — and --oracles-only is a convenience, not the gate."
    exit 2; }
fi
if [ "${1:-}" != "--oracles-only" ]; then
  echo "[acquire]"; acquire
  echo "[scan]";    scan
fi
echo "[oracles]"; oracles
echo
if [ "$findings" -eq 0 ]; then echo "corpus: OK — no findings"; exit 0; fi
echo "corpus: $findings FINDING(S) — a finding is a candidate cardinal sin; trace each to ground truth"
echo "  (a corpus finding has been wrong before: reduce every mechanism story to a FIXTURE before filing)"
exit 1
