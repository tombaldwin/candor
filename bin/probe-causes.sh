#!/usr/bin/env bash
# THE EXIT-2 CAUSE MATRIX — every cause a user can TRIGGER, against every engine, on BOTH sink forms.
#
# WHY THIS EXISTS. During the 0.27 release three four-lens review panels found real defects, but every
# one that stayed fixed was caught by a MECHANICAL sweep like this one or by the conformance row written
# from it. A panel finds a defect once; a matrix finds it every time anyone runs it.
#
# COUNT CAUSES, NOT EXIT SITES. candor-ts has 25 `process.exit(2)` sites and candor-swift 30 — but only
# ~12 causes are reachable with a gate sink set. Auditing sites would have wasted the sweep; the short
# list is the one that matters.
#
# BOTH SINK FORMS, ALWAYS. They are different properties and an engine can satisfy one while failing the
# other — measured: candor-swift streamed a refusal correctly for an unreadable config while leaving a
# previous run's `{"ok": true}` on disk. A stream must CARRY the refusal; a file sink must have its
# armed placeholder REPLACED by it, so a pre-seeded green surviving is the failure.
#
# Usage:  bin/probe-causes.sh [engine…]     (default: all four; `agents` is opt-in, see below)
# Exit:   0 all posed cells pass · 1 a cell failed · 2 could not run
set -uo pipefail

ROOT="${CANDOR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
W="$(mktemp -d)"; trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
FAILED=0; POSED=0
# POSED counts cells RUN; ASSERTED counts cells that actually reached exit 2 and therefore had the
# property checked against them. The gap between the two is the whole difference between "56 pairs, all
# fine" and "56 pairs, none of which asked anything" — and only the second number can distinguish them.
ASSERTED=0

JAR=$(ls "$ROOT"/candor-java/build/libs/candor-java-*-all.jar 2>/dev/null | tail -1)
SCAN="$ROOT/candor-rust/target/release/candor-scan"
TSS="$ROOT/candor-ts/scan.mjs"
SWB="$ROOT/candor-swift/.build/release/candor-swift"
QUERY="$ROOT/candor-rust/target/release/candor-query"
TSQ="$ROOT/candor-ts/query.mjs"

# FRESHNESS IS PART OF THE MEASUREMENT. A stale binary produced a review finding for a defect that had
# already been fixed AND one that never existed — `cargo build --release` at the candor-rust ROOT builds
# the dylint lint, not the engines, so that binary silently aged eight days. Say how old each is.
echo "engines under test:"
for p in "$JAR" "$SCAN" "$TSS" "$SWB"; do
  [ -e "$p" ] && printf "  %-58s %s\n" "$(basename "$p")" "$(date -r "$p" '+%Y-%m-%d %H:%M')" \
              || printf "  %-58s MISSING — build it first\n" "$(basename "$p")"
done
echo

# ── fixtures: one clean, VALID target per engine ────────────────────────────────────────────────────
# Contamination produced two convincing false results during the 0.27 work: a leftover `.candor/config`
# made java exit on the dep cause, and a SOURCE directory was handed to an engine that reads BYTECODE.
# Both looked like a clean 3-vs-1 split. Build fresh, and never reuse a tree between causes.
mkfixtures() {
  mkdir -p "$W/ts/src" "$W/rs/src" "$W/sw/Sources/App" "$W/jv/src" "$W/empty"
  printf 'export function f(): void { console.log(1) }\n' > "$W/ts/src/a.ts"
  printf '{"name":"p","version":"1.0.0"}\n' > "$W/ts/package.json"
  printf 'fn main(){println!("x");}\n' > "$W/rs/src/main.rs"
  printf '[package]\nname="p"\nversion="0.1.0"\nedition="2021"\n' > "$W/rs/Cargo.toml"
  printf 'func f() { print(1) }\n' > "$W/sw/Sources/App/main.swift"
  printf '// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name:"P",targets:[.executableTarget(name:"App")])\n' > "$W/sw/Package.swift"
  printf 'public class A { public static void main(String[] a){} }\n' > "$W/jv/src/A.java"
  javac -d "$W/jv/out" "$W/jv/src/A.java" 2>/dev/null || { echo "FAIL: javac unavailable — java cells cannot be posed"; return 1; }
  printf 'deny Fs zzz.matches.nothing\n' > "$W/ok.policy"
  printf 'x\n' > "$W/bad.policy";        chmod 000 "$W/bad.policy"
  printf 'policy /nonexistent\n' > "$W/badcfg"; chmod 000 "$W/badcfg"
  printf 'engine 9.9.9\n' > "$W/pincfg"
  printf 'not json{' > "$W/bad.json"
  printf '{}' > "$W/unread.json";        chmod 000 "$W/unread.json"

  # ── the GATE VERB route needs a report to gate, and a report that VIOLATES ─────────────────────────
  # The scan-route fixtures above are deliberately clean. A gate over a clean report exits 0, and every
  # cell posed against it would be "not exit 2 here" — a probe that never poses its question. So the gate
  # route gets its own effectful trees, and a CONTROL below asserts the gate actually fires on each. That
  # control is not ceremony: PART 34 row (e) exists because a fixture stopped violating and took a whole
  # group of rows silently vacuous with it.
  mkdir -p "$W/gts/src" "$W/grs/src" "$W/gsw/Sources/App" "$W/gjv/src"
  printf "import * as fs from 'fs'\nexport function f(): void { fs.readFileSync('/tmp/x') }\n" > "$W/gts/src/a.ts"
  printf '{"name":"gp","version":"1.0.0"}\n' > "$W/gts/package.json"
  printf 'fn main(){ std::fs::read("/tmp/x").ok(); }\n' > "$W/grs/src/main.rs"
  printf '[package]\nname="gp"\nversion="0.1.0"\nedition="2021"\n' > "$W/grs/Cargo.toml"
  printf 'import Foundation\nfunc f() { _ = FileManager.default.contents(atPath: "/tmp/x") }\n' > "$W/gsw/Sources/App/main.swift"
  printf '// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name:"GP",targets:[.executableTarget(name:"App")])\n' > "$W/gsw/Package.swift"
  printf 'import java.io.*;\npublic class B { public static void main(String[] a) throws Exception { new FileInputStream("/tmp/x"); } }\n' > "$W/gjv/src/B.java"
  javac -d "$W/gjv/out" "$W/gjv/src/B.java" 2>/dev/null || { echo "FAIL: javac could not build the gate-route fixture"; return 1; }
  printf 'deny Fs\n' > "$W/fire.policy"
}
mkfixtures || exit 2

# Each engine's invocation shape, in one place. This is the knowledge the ad-hoc versions of this script
# kept getting wrong: a naive "substitute the last argv element" removed the OUT-DIR for ts and swift,
# which then scanned a VALID tree and "passed" at exit 0 — a vacuous green dressed as a probe.
run_engine() { # engine, target, then extra args
  local e=$1 tgt=$2; shift 2
  case $e in
    java)  java -jar "$JAR" "$tgt" "$@" ;;
    rust)  "$SCAN" "$tgt" "$@" ;;
    ts)    node "$TSS" "$tgt" "$@" ;;
    swift) "$SWB" "$tgt" "$@" ;;
    *) return 127 ;;
  esac
}
target_for() { case $1 in java) echo "$W/jv/out";; rust) echo "$W/rs";; ts) echo "$W/ts";; swift) echo "$W/sw";; esac; }

# THE `gate` VERB IS A SECOND ROUTE TO THE SAME CONTRACT, and until now it had no cells here at all.
# §3.3.1 does not exempt it: a CI job that scans once and gates many times reaches every exit-2 cause
# through this CLI instead, and an engine can satisfy the rule on the scan route while missing it here —
# which is precisely the "two spellings" shape that produced every sink defect in this family.
run_gate() { # engine, report locator, then extra args
  local e=$1 rep=$2; shift 2
  case $e in
    java)  java -jar "$JAR" gate --report "$rep" "$@" ;;
    rust)  "$QUERY" gate --report "$rep" "$@" ;;
    ts)    node "$TSQ" gate --report "$rep" "$@" ;;
    swift) "$SWB" gate --report "$rep" "$@" ;;
    *) return 127 ;;
  esac
}
# WHAT IS SCANNED vs WHAT `--report` IS HANDED are not the same thing, and assuming they were left java
# unmeasured on this whole route: java writes a report only with `--json <file>`, so scanning its tree
# produced nothing to gate and the control reported rc=2. Three engines discover a report from the tree;
# java is handed a file. Stated per engine rather than inferred from one that happened to work.
gate_src_for()    { case $1 in java) echo "$W/gjv/out";;      rust) echo "$W/grs";; ts) echo "$W/gts";; swift) echo "$W/gsw";; esac; }
gate_target_for() { case $1 in java) echo "$W/rep.java.json";; rust) echo "$W/grs";; ts) echo "$W/gts";; swift) echo "$W/gsw";; esac; }
mkgatereport() { # engine — produce the report the gate route reads
  case $1 in
    java) java -jar "$JAR" "$(gate_src_for java)" --json "$(gate_target_for java)" >/dev/null 2>&1 ;;
    *)    run_engine "$1" "$(gate_src_for "$1")" >/dev/null 2>&1 ;;
  esac
}

# One dispatcher so the cells are route-agnostic: they assert a property of the CONTRACT, not of a CLI.
run_probe() { # engine, target, extra…
  local e=$1 tgt=$2; shift 2
  if [ "${ROUTE:-scan}" = gate ]; then run_gate "$e" "$tgt" --policy "$GATE_POLICY" "$@"
  else run_engine "$e" "$tgt" "$@"; fi
}
probe_target_for() {
  if [ "${ROUTE:-scan}" = gate ]; then gate_target_for "$1"; else target_for "$1"; fi
}

one_json() { python3 - "$1" <<'PY'
import json, sys
try:
    json.load(open(sys.argv[1])); sys.exit(0)
except Exception:
    sys.exit(1)
PY
}

# STREAM: exit 2 must leave exactly ONE parseable document as stdout's only content (SPEC §3.1).
# "Some bytes" is not the assertion — a fix once emitted TWO concatenated documents and a byte count
# read as a pass. Parse it.
cell_stream() { # engine, label, env, target-override, extra args…
  local e=$1 lbl=$2 envk=$3 tgtover=$4; shift 4
  local tgt="${tgtover:-$(probe_target_for "$e")}" out rc
  out="$W/out.$e.json"
  # SINK_FIRST arms the sink BEFORE the argv under test. It matters: with the sink appended, a pair that
  # itself contains a value-taking flag swallows `--gate-json`, and the run then exits 2 with no sink ever
  # armed — which is not a defect, it is an argv whose sink specification is the broken part. Arming first
  # makes the property the one SPEC §3.3.1 actually states: the sink was armed, then something went wrong,
  # so the refusal must reach it.
  local pre="" post="--gate-json -"
  [ -n "${SINK_FIRST:-}" ] && { pre="--gate-json -"; post=""; }
  env $envk bash -c "$(declare -f run_engine run_gate run_probe target_for gate_target_for probe_target_for); JAR='$JAR'; SCAN='$SCAN'; TSS='$TSS'; SWB='$SWB'; QUERY='$QUERY'; TSQ='$TSQ'; W='$W'; ROUTE='${ROUTE:-scan}'; GATE_POLICY='${GATE_POLICY:-}'; run_probe $e '$tgt' $pre $* $post" > "$out" 2>/dev/null; rc=$?
  POSED=$((POSED+1))
  if [ "$rc" != 2 ]; then [ -n "${QUIET:-}" ] || printf "  %-8s %-26s rc=%s (not exit 2 here)\n" "$e" "$lbl" "$rc"; return 0; fi
  ASSERTED=$((ASSERTED+1))
  if [ ! -s "$out" ]; then printf "  %-8s %-26s ✘ EMPTY STREAM after exit 2\n" "$e" "$lbl"; FAILED=1; return 1; fi
  if ! one_json "$out"; then printf "  %-8s %-26s ✘ NOT ONE DOCUMENT (concatenated?)\n" "$e" "$lbl"; FAILED=1; return 1; fi
  [ -n "${QUIET:-}" ] || printf "  %-8s %-26s ok\n" "$e" "$lbl"
}

# FILE: a pre-seeded GREEN must not survive an exit-2 run. Arming leaves a fail-closed placeholder and
# the refusal replaces it; a surviving `ok:true` is the stale green the whole mechanism exists to stop.
cell_file() { # engine, label, env, extra args…
  local e=$1 lbl=$2 envk=$3; shift 3
  local tgt sink rc; tgt=$(probe_target_for "$e"); sink="$W/sink.$e.json"
  printf '{"spec":"0.27","ok":true,"violations":[]}\n' > "$sink"
  local pre="" post="--gate-json '$sink'"
  [ -n "${SINK_FIRST:-}" ] && { pre="--gate-json '$sink'"; post=""; }
  env $envk bash -c "$(declare -f run_engine run_gate run_probe target_for gate_target_for probe_target_for); JAR='$JAR'; SCAN='$SCAN'; TSS='$TSS'; SWB='$SWB'; QUERY='$QUERY'; TSQ='$TSQ'; W='$W'; ROUTE='${ROUTE:-scan}'; GATE_POLICY='${GATE_POLICY:-}'; run_probe $e '$tgt' $pre $* $post" >/dev/null 2>&1; rc=$?
  POSED=$((POSED+1))
  if [ "$rc" != 2 ]; then [ -n "${QUIET:-}" ] || printf "  %-8s %-26s rc=%s (not exit 2 here)\n" "$e" "$lbl" "$rc"; return 0; fi
  ASSERTED=$((ASSERTED+1))
  if python3 -c "import json,sys; sys.exit(0 if json.load(open('$sink')).get('ok') is True else 1)" 2>/dev/null; then
    printf "  %-8s %-26s ✘ STALE GREEN survived exit 2\n" "$e" "$lbl"; FAILED=1; return 1
  fi
  [ -n "${QUIET:-}" ] || printf "  %-8s %-26s ok\n" "$e" "$lbl"
}

ENGINES=("${@:-java rust ts swift}"); read -r -a ENGINES <<< "${ENGINES[*]}"

echo "── STREAM sink (--gate-json -): exit 2 must carry exactly one refusal document"
for e in "${ENGINES[@]}"; do
  cell_stream "$e" "unknown flag"        "X=1" "" --zzz-not-a-flag
  cell_stream "$e" "valueless flag"      "X=1" "" --policy
  cell_stream "$e" "nonexistent target"  "X=1" "$W/no-such-target"
  cell_stream "$e" "unreadable policy"   "X=1" "" --policy "$W/bad.policy"
  cell_stream "$e" "missing policy"      "X=1" "" --policy "$W/no-such.policy"
  cell_stream "$e" "unreadable config"   "CANDOR_CONFIG=$W/badcfg" ""
  cell_stream "$e" "missing config"      "CANDOR_CONFIG=$W/no-such-cfg" ""
  cell_stream "$e" "engine pin mismatch" "CANDOR_CONFIG=$W/pincfg" ""
  cell_stream "$e" "empty scan"          "X=1" "$W/empty"
  cell_stream "$e" "dep missing"         "CANDOR_DEPS=$W/no-such-dep.json" ""
  cell_stream "$e" "dep unreadable"      "CANDOR_DEPS=$W/unread.json" ""
  cell_stream "$e" "dep malformed"       "CANDOR_DEPS=$W/bad.json" ""
done

echo
echo "── TWO SINKS IN ONE ARGV (SPEC §3.3.1 ⟨0.28⟩): refused, and EVERY path named gets the refusal"
# The rung this file's own measurement produced. Before it: three engines wrote the verdict to the LAST
# path, one refused, and all four left the FIRST holding a previous run's `{"ok": true}` while the gate
# fired. The losing sink's reader has no way to learn that it lost, so whatever it held is published as
# this run's answer — the ⟨0.27⟩ stale green through a spelling nobody had considered.
for e in "${ENGINES[@]}"; do
  tgt=$(target_for "$e"); a="$W/dup.a.$e.json"; b="$W/dup.b.$e.json"
  printf '{"spec":"0.27","ok":true,"violations":[]}\n' > "$a"; rm -f "$b"
  env X=1 bash -c "$(declare -f run_engine target_for); JAR='$JAR'; SCAN='$SCAN'; TSS='$TSS'; SWB='$SWB'; run_engine $e '$tgt' --gate-json '$a' --gate-json '$b'" >/dev/null 2>&1; rc=$?
  POSED=$((POSED+1))
  if [ "$rc" != 2 ]; then
    printf "  %-8s %-26s ✘ exited %s, not 2 — a run publishes one verdict to one sink\n" "$e" "two sinks" "$rc"; FAILED=1; continue
  fi
  ASSERTED=$((ASSERTED+1))
  if python3 -c "import json,sys; sys.exit(0 if json.load(open('$a')).get('ok') is True else 1)" 2>/dev/null; then
    printf "  %-8s %-26s ✘ the LOSING sink still holds the stale green\n" "$e" "two sinks"; FAILED=1
  elif ! one_json "$a" || [ ! -s "$b" ] || ! one_json "$b"; then
    printf "  %-8s %-26s ✘ not every named sink got a parseable refusal\n" "$e" "two sinks"; FAILED=1
  else
    printf "  %-8s %-26s ok\n" "$e" "two sinks"
  fi
done

echo
echo "── FILE sink: a pre-seeded green must NOT survive an exit-2 run"
for e in "${ENGINES[@]}"; do
  cell_file "$e" "unknown flag"        "X=1" --zzz-not-a-flag
  cell_file "$e" "unreadable policy"   "X=1" --policy "$W/bad.policy"
  cell_file "$e" "unreadable config"   "CANDOR_CONFIG=$W/badcfg"
  cell_file "$e" "engine pin mismatch" "CANDOR_CONFIG=$W/pincfg"
  cell_file "$e" "dep missing"         "CANDOR_DEPS=$W/no-such-dep.json"
done


# ── THE `gate` VERB ROUTE ────────────────────────────────────────────────────────────────────────────
# Everything above reaches the contract through the SCAN CLI. A CI job that scans once and gates many
# times reaches every one of these causes through `gate` instead, and §3.3.1 exempts neither. This was
# named as NOT COVERED in this file for a release; naming a gap is not measuring it.
gate_route() {
  echo
  echo "── gate VERB route: the same causes, reached through the query CLI"
  local runnable=()
  for e in "${ENGINES[@]}"; do
    local tgt rc; tgt=$(gate_target_for "$e")
    mkgatereport "$e"
    # THE CONTROL, and it decides whether this engine is posed at all. A gate over a report that does not
    # violate exits 0, so every cell below would print "not exit 2 here" — a probe that never asks its
    # question, reading as coverage. PART 34 row (e) exists because exactly that happened once.
    run_gate "$e" "$tgt" --policy "$W/fire.policy" >/dev/null 2>&1; rc=$?
    if [ "$rc" = 1 ]; then
      runnable+=("$e")
    else
      printf "  %-8s ✘ CONTROL: the gate did not FIRE on an effectful fixture (rc=%s) — cells SKIPPED, not passed\n" "$e" "$rc"
      FAILED=1
    fi
  done
  [ "${#runnable[@]}" -gt 0 ] || { echo "  no engine posed — nothing here is evidence"; return; }

  # SINK_FIRST on every cell, for the reason the sweep taught: with the sink appended last, a valueless
  # `--policy` swallows `--gate-json` and the run exits 2 having never registered a sink. That is an argv
  # whose sink specification is the broken part, not an engine hiding a refusal.
  local e
  for e in "${runnable[@]}"; do
    ROUTE=gate SINK_FIRST=1 GATE_POLICY="$W/fire.policy" cell_stream "$e" "gate: unknown flag"      "X=1" "" --zzz-not-a-flag
    ROUTE=gate SINK_FIRST=1 GATE_POLICY="$W/fire.policy" cell_stream "$e" "gate: valueless flag"    "X=1" "" --policy
    ROUTE=gate SINK_FIRST=1 GATE_POLICY="$W/fire.policy" cell_stream "$e" "gate: extra positional"  "X=1" "" "$W/empty"
    ROUTE=gate SINK_FIRST=1 GATE_POLICY="$W/bad.policy"  cell_stream "$e" "gate: unreadable policy" "X=1" ""
    ROUTE=gate SINK_FIRST=1 GATE_POLICY="$W/no-such.policy" cell_stream "$e" "gate: missing policy" "X=1" ""
    ROUTE=gate SINK_FIRST=1 GATE_POLICY="$W/fire.policy" cell_stream "$e" "gate: unreadable config" "CANDOR_CONFIG=$W/badcfg" ""
    # THE PIN IS OUT OF SCOPE HERE, BY NAME. SPEC §3.4 "Scope": the pin binds a producer that analyses
    # code and emits a verdict from that analysis, and explicitly NOT "a verb that only reads an EXISTING
    # report (`gate --report`, the §3.1 queries)" — there the engine is an evaluator, not the producer.
    # So the assertion INVERTS: the pin must not change the gate's answer. Written as a positive cell
    # because the first version of this probe asserted exit 2 here and made all three measured engines
    # look defective; the spec had already decided, and my expectation was the thing that was wrong.
    cell_pin_out_of_scope "$e"
    ROUTE=gate SINK_FIRST=1 GATE_POLICY="$W/fire.policy" cell_file   "$e" "gate: unknown flag"      "X=1" --zzz-not-a-flag
    ROUTE=gate SINK_FIRST=1 GATE_POLICY="$W/bad.policy"  cell_file   "$e" "gate: unreadable policy" "X=1"
  done
}
# The pin must NOT reach the evaluator. An engine that "helpfully" enforced it here would break every
# consumer gating a committed report with a pinned config, so this is a real cell, not a formality.
cell_pin_out_of_scope() {
  local e=$1 tgt rc; tgt=$(gate_target_for "$e")
  POSED=$((POSED+1))
  env CANDOR_CONFIG="$W/pincfg" bash -c "$(declare -f run_gate); JAR='$JAR'; QUERY='$QUERY'; TSQ='$TSQ'; SWB='$SWB'; run_gate $e '$tgt' --policy '$W/fire.policy'" >/dev/null 2>&1; rc=$?
  if [ "$rc" = 1 ]; then
    [ -n "${QUIET:-}" ] || printf "  %-8s %-26s ok (pin ignored, as §3.4 Scope requires)\n" "$e" "gate: engine pin"
  else
    printf "  %-8s %-26s ✘ the pin CHANGED the evaluator's answer (rc=%s, want 1) — §3.4 scopes it to producers\n" "$e" "gate: engine pin" "$rc"; FAILED=1
  fi
}

[ "${CANDOR_GATE_ROUTE:-1}" = 1 ] && gate_route

# ── COMBINATION SWEEP (--sweep) ──────────────────────────────────────────────────────────────────────
# The cells above are a hand-written list of causes, so they test exactly the causes someone thought of.
# Every sink defect found during 0.27 was at a COMBINATION rather than at a cause: a refusal that reached
# the stream alone but not when a second flag had already opened a document, a flag that consumed the
# next flag as its value, a `--gate-json -` that behaved differently once `--json` was also present. Two
# tokens is where that lives, so this poses every ordered pair from a small alphabet.
#
# The property is the same one the hand-written cells assert, and it holds for ANY argv: if the run exits
# 2, the stream carries exactly one parseable document, and a pre-seeded green does not survive. Pairs
# that do not exit 2 are not failures — they are simply outside the property, and are counted so the
# summary cannot read as more coverage than it is.
# `--gate-json` is deliberately NOT in either alphabet: the cells supply the sink, so a pair containing
# one poses TWO sinks in one argv. That was an open spec question when this file was written and is now
# answered — ⟨0.28⟩ refuses it, and every path named gets the refusal — but it is still the wrong thing
# for the SWEEP to pose, because the sweep's property is about the sink it armed and a second one changes
# the question. It has its own cell below, and conformance PART 36 (b20) pins it four-way.
SWEEP_SCAN_TOKS=(--zzz-not-a-flag --policy --strict --json "$W/bad.policy" "$W/no-such.policy" --out "$W/empty")
# The gate verb's own surface. `--report` is here because it is the verb's ONE required input and a flag
# that takes a value — the two properties that made `--out` and `--policy` interesting on the scan route.
SWEEP_GATE_TOKS=(--zzz-not-a-flag --policy --report --json "$W/bad.policy" "$W/no-such.policy" "$W/empty")

# One sweep body for both routes, because the property is a property of the CONTRACT and not of a CLI:
# arm the sink, then hand the engine an argv it should reject, and require the refusal to arrive.
sweep_route() { # route label, then the token alphabet
  local route=$1 label=$2; shift 2
  local toks=( "$@" ) n=0 e a b before asserted_at_start=$ASSERTED
  echo
  echo "── COMBINATION SWEEP ($label): ordered pairs from ${#toks[@]} tokens, both sink forms"
  for e in "${ENGINES[@]}"; do
    before=$FAILED
    for a in "${toks[@]}"; do
      for b in "${toks[@]}"; do
        [ "$a" = "$b" ] && continue
        n=$((n+1))
        QUIET=1 SINK_FIRST=1 ROUTE="$route" GATE_POLICY="$W/fire.policy" \
          cell_stream "$e" "pair ${a##*/} ${b##*/}" "X=1" "" "$a" "$b"
        QUIET=1 SINK_FIRST=1 ROUTE="$route" GATE_POLICY="$W/fire.policy" \
          cell_file   "$e" "pair ${a##*/} ${b##*/}" "X=1"     "$a" "$b"
      done
    done
    if [ "$FAILED" != "$before" ]; then
      printf "  %-8s ✘ the ✘ line(s) above name the pair\n" "$e"
    else
      printf "  %-8s ok across every pair\n" "$e"
    fi
  done
  local asked=$(( ASSERTED - asserted_at_start ))
  echo "  $n pair(s) per engine, ×2 sink forms; $asked cell(s) actually reached exit 2 and had the property"
  echo "  checked. The rest are outside it — not passes. A route reporting 0 here proved nothing."
  [ "$asked" -gt 0 ] || { printf "  ✘ VACUOUS: no cell in this sweep exited 2, so \"ok across every pair\" is empty\n"; FAILED=1; }
}

sweep() {
  sweep_route scan "scan CLI" "${SWEEP_SCAN_TOKS[@]}"
  # The gate route's reports were built by `gate_route`; without them every pair here would be posed
  # against a locator that resolves to nothing, which is a different question than the one being asked.
  if [ "${CANDOR_GATE_ROUTE:-1}" = 1 ]; then
    sweep_route gate "gate VERB" "${SWEEP_GATE_TOKS[@]}"
  else
    echo "  gate-route sweep SKIPPED — CANDOR_GATE_ROUTE=0 means no reports were built to gate"
  fi
}
[ "${CANDOR_SWEEP:-}" = 1 ] && sweep

echo
echo "probe-causes: $POSED cell(s) posed, $ASSERTED reached exit 2 and were checked, $([ "$FAILED" = 0 ] && echo "0 failures" || echo "FAILURES above")"
[ "${CANDOR_SWEEP:-}" = 1 ] || echo "  (cause list only — set CANDOR_SWEEP=1 to add the argv combination sweep)"
# NOT COVERED HERE, and named so none of it is mistaken for covered: the `gate` VERB route (these are all
# the scan route, though the `gate` verb now has its own cells above) and candor-agents, whose CLI shape
# differs — see the umbrella BACKLOG. Two sinks in one argv WAS listed here as unanswered; ⟨0.28⟩ answers
# it and the cell above poses it.
exit "$FAILED"
