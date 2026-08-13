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
  clone swift-argument-parser https://github.com/apple/swift-argument-parser 1.4.0
  clone alamofire             https://github.com/Alamofire/Alamofire         5.9.1
  local M=https://repo1.maven.org/maven2
  jar() { [ -f "$JARS/$1" ] && return 0; curl -fsSL -o "$JARS/$1" "$2" && echo "  got $1" || echo "  MISS $1"; }
  jar gson.jar          $M/com/google/code/gson/gson/2.11.0/gson-2.11.0.jar
  jar commons-lang3.jar $M/org/apache/commons/commons-lang3/3.14.0/commons-lang3-3.14.0.jar
  jar jackson-core.jar  $M/com/fasterxml/jackson/core/jackson-core/2.17.1/jackson-core-2.17.1.jar
  jar joda-time.jar     $M/joda-time/joda-time/2.12.7/joda-time-2.12.7.jar
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
  for r in ripgrep clap serde regex; do [ -d "$SRC/$r" ] && run rust "$r" "$RS/candor-scan" "$SRC/$r" --out "$OUT/rust.$r"; done
  # axios exits 2 with "no TypeScript sources" ONLY if its `.d.ts` is excluded; it currently scans. A
  # JS-only tree (express) legitimately refuses at exit 2 — that is candor-ts being right, not a finding,
  # which is why the set holds no JS-only package.
  for t in zod chalk hono axios; do [ -d "$SRC/$t" ] && run ts "$t" node "$TS/scan.mjs" "$SRC/$t" --out "$OUT/ts.$t"; done
  for s in swift-argument-parser alamofire; do [ -d "$SRC/$s" ] && run swift "$s" "$SW" "$SRC/$s" --out "$OUT/swift.$s"; done
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
for f in sorted(glob.glob(OUT+"/*.json")):
    b=os.path.basename(f)
    if any(x in b for x in (".callgraph.",".locs.",".hierarchy.")): continue
    eng=b.split(".")[0]
    if eng not in ("rust","ts","swift","java"): continue   # a stray file must not invent an engine
    cg=f.rsplit(".json",1)[0]+".callgraph.json"
    if not os.path.exists(cg): continue
    try: d=json.load(open(f)); g=json.load(open(cg))
    except Exception: continue
    fns={x.get("fn") or x.get("name"):x for x in d.get("functions",[])}
    inc={k for k,v in fns.items() if v.get("incomplete")}
    tot[eng]+=len(inc)
    for k,edges in g.items():
        if any(e in inc for e in (edges or [])):
            callers[eng]+=1
            if (fns.get(k) or {}).get("incomplete"): prop[eng]+=1
bad=0
for e in sorted(set(tot)|set(callers)):
    note = "" if callers[e]==prop[e] else "  <-- FINDING"
    if callers[e]!=prop[e]: bad=1
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
  printf 'deny Unknown\n' > "$P/pol"
  node "$TS/scan.mjs" "$P/ts" --out "$P/t" >/dev/null 2>&1
  "$RS/candor-scan" "$P/rust" --out "$P/r" >/dev/null 2>&1
  [ -x "$SW" ] && "$SW" "$P/swift" --out "$P/s" >/dev/null 2>&1
  # `deny Unknown` is the gate whose whole purpose is "fail if candor cannot see what this reaches".
  # An engine that cannot see the declaration's body and says nothing exits 0 here; the others exit 1.
  gate() { local eng=$1 rep=$2 cmd=$3; shift 3
    [ -s "$rep" ] || { echo "      $eng  (no report — skipped)"; return; }
    "$@" gate --report "$rep" --policy "$P/pol" >/dev/null 2>&1
    local rc=$?
    if [ "$rc" = 0 ]; then finding "$eng: \`deny Unknown\` is GREEN over a caller of a body-less declaration — it read PURE (cardinal sin; the other engines exit 1)"
    else echo "      $eng  exit=$rc (discloses)"; fi; }
  gate "ts   " "$P/t.json" x node "$TS/query.mjs"
  gate "rust " "$(ls "$P"/r.*.scan.json 2>/dev/null | grep -v callgraph | head -1)" x "$RS/candor-query"
  [ -x "$SW" ] && gate "swift" "$(ls "$P"/s.*.Swift.json 2>/dev/null | grep -v callgraph | head -1)" x "$SW"
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
