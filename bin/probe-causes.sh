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

JAR=$(ls "$ROOT"/candor-java/build/libs/candor-java-*-all.jar 2>/dev/null | tail -1)
SCAN="$ROOT/candor-rust/target/release/candor-scan"
TSS="$ROOT/candor-ts/scan.mjs"
SWB="$ROOT/candor-swift/.build/release/candor-swift"

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
  local tgt="${tgtover:-$(target_for "$e")}" out rc
  out="$W/out.$e.json"
  # SINK_FIRST arms the sink BEFORE the argv under test. It matters: with the sink appended, a pair that
  # itself contains a value-taking flag swallows `--gate-json`, and the run then exits 2 with no sink ever
  # armed — which is not a defect, it is an argv whose sink specification is the broken part. Arming first
  # makes the property the one SPEC §3.3.1 actually states: the sink was armed, then something went wrong,
  # so the refusal must reach it.
  local pre="" post="--gate-json -"
  [ -n "${SINK_FIRST:-}" ] && { pre="--gate-json -"; post=""; }
  env $envk bash -c "$(declare -f run_engine target_for); JAR='$JAR'; SCAN='$SCAN'; TSS='$TSS'; SWB='$SWB'; run_engine $e '$tgt' $pre $* $post" > "$out" 2>/dev/null; rc=$?
  POSED=$((POSED+1))
  if [ "$rc" != 2 ]; then [ -n "${QUIET:-}" ] || printf "  %-8s %-26s rc=%s (not exit 2 here)\n" "$e" "$lbl" "$rc"; return 0; fi
  if [ ! -s "$out" ]; then printf "  %-8s %-26s ✘ EMPTY STREAM after exit 2\n" "$e" "$lbl"; FAILED=1; return 1; fi
  if ! one_json "$out"; then printf "  %-8s %-26s ✘ NOT ONE DOCUMENT (concatenated?)\n" "$e" "$lbl"; FAILED=1; return 1; fi
  [ -n "${QUIET:-}" ] || printf "  %-8s %-26s ok\n" "$e" "$lbl"
}

# FILE: a pre-seeded GREEN must not survive an exit-2 run. Arming leaves a fail-closed placeholder and
# the refusal replaces it; a surviving `ok:true` is the stale green the whole mechanism exists to stop.
cell_file() { # engine, label, env, extra args…
  local e=$1 lbl=$2 envk=$3; shift 3
  local tgt sink rc; tgt=$(target_for "$e"); sink="$W/sink.$e.json"
  printf '{"spec":"0.27","ok":true,"violations":[]}\n' > "$sink"
  local pre="" post="--gate-json '$sink'"
  [ -n "${SINK_FIRST:-}" ] && { pre="--gate-json '$sink'"; post=""; }
  env $envk bash -c "$(declare -f run_engine target_for); JAR='$JAR'; SCAN='$SCAN'; TSS='$TSS'; SWB='$SWB'; run_engine $e '$tgt' $pre $* $post" >/dev/null 2>&1; rc=$?
  POSED=$((POSED+1))
  if [ "$rc" != 2 ]; then [ -n "${QUIET:-}" ] || printf "  %-8s %-26s rc=%s (not exit 2 here)\n" "$e" "$lbl" "$rc"; return 0; fi
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
echo "── FILE sink: a pre-seeded green must NOT survive an exit-2 run"
for e in "${ENGINES[@]}"; do
  cell_file "$e" "unknown flag"        "X=1" --zzz-not-a-flag
  cell_file "$e" "unreadable policy"   "X=1" --policy "$W/bad.policy"
  cell_file "$e" "unreadable config"   "CANDOR_CONFIG=$W/badcfg"
  cell_file "$e" "engine pin mismatch" "CANDOR_CONFIG=$W/pincfg"
  cell_file "$e" "dep missing"         "CANDOR_DEPS=$W/no-such-dep.json"
done


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
sweep() {
  # `--gate-json` is deliberately NOT in this alphabet: the cells supply the sink, so a pair containing
  # one poses "which of two sinks wins", a real question this harness cannot attribute an answer to. It is
  # named in the NOT-COVERED note rather than answered by accident.
  local toks=(--zzz-not-a-flag --policy --strict --json "$W/bad.policy" "$W/no-such.policy" --out "$W/empty")
  local n=0
  echo
  echo "── COMBINATION SWEEP: ordered pairs from ${#toks[@]} tokens, both sink forms"
  for e in "${ENGINES[@]}"; do
    local before=$FAILED
    for a in "${toks[@]}"; do
      for b in "${toks[@]}"; do
        [ "$a" = "$b" ] && continue
        n=$((n+1))
        QUIET=1 SINK_FIRST=1 cell_stream "$e" "pair ${a##*/} ${b##*/}" "X=1" "" "$a" "$b"
        QUIET=1 SINK_FIRST=1 cell_file   "$e" "pair ${a##*/} ${b##*/}" "X=1"     "$a" "$b"
      done
    done
    if [ "$FAILED" != "$before" ]; then
      printf "  %-8s ✘ the ✘ line(s) above name the pair\n" "$e"
    else
      printf "  %-8s ok across every pair\n" "$e"
    fi
  done
  echo "  $n pair(s) per engine, ×2 sink forms. Pairs that did not exit 2 are outside the property, not passes."
}
[ "${CANDOR_SWEEP:-}" = 1 ] && sweep

echo
echo "probe-causes: $POSED cell(s) posed, $([ "$FAILED" = 0 ] && echo "0 failures" || echo "FAILURES above")"
[ "${CANDOR_SWEEP:-}" = 1 ] || echo "  (cause list only — set CANDOR_SWEEP=1 to add the argv combination sweep)"
# NOT COVERED HERE, and named so none of it is mistaken for covered: the `gate` VERB route (these are all
# the scan route); candor-agents, whose CLI shape differs; and TWO SINKS in one argv (`--gate-json a
# --gate-json b`), which has no stated answer in the spec — see the umbrella BACKLOG.
exit "$FAILED"
