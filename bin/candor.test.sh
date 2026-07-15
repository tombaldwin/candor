#!/usr/bin/env bash
# Hermetic routing test for the `candor` dispatcher. Uses CANDOR_DISPATCH_DRYRUN + fake engine stubs on PATH,
# so it asserts WHICH engine each invocation resolves to without any engine actually installed. No network,
# no builds.  Run:  bash bin/candor.test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
D="$HERE/candor"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export CANDOR_DISPATCH_DRYRUN=1
mkdir -p "$T/fakebin"; for e in candor-query candor-scan candor-ts candor-ts-query candor-swift candor-java; do printf '#!/bin/sh\n' > "$T/fakebin/$e"; chmod +x "$T/fakebin/$e"; done
export PATH="$T/fakebin:$PATH"

fails=0
ok() { # $1 label ; $2 expected-substring ; $3… command
  local label="$1" want="$2"; shift 2
  local got; got="$("$@" 2>&1)"
  if [[ "$got" == *"$want"* ]]; then echo "  ok   $label"; else echo "  FAIL $label"; echo "       want: *$want*"; echo "       got:  $got"; fails=$((fails+1)); fi
}
qdir() { mkdir -p "$T/$1/.candor"; : > "$T/$1/.candor/report.pkg.$2.json"; }
sdir() { mkdir -p "$T/$1"; : > "$T/$1/$2"; }

echo "query routing (by report backend):"
qdir qr scan;  ok "rust report → candor-query"       "WOULD-RUN: candor-query where Net"    bash -c "cd '$T/qr'  && '$D' where Net"
qdir qt JS;    ok "ts report → candor-ts-query"       "WOULD-RUN: candor-ts-query where Net" bash -c "cd '$T/qt'  && '$D' where Net"
qdir qj jvm;   ok "java report → candor-java"         "WOULD-RUN: candor-java path f Net"    bash -c "cd '$T/qj'  && '$D' path f Net"
qdir qs Swift; ok "swift report → candor-swift"       "WOULD-RUN: candor-swift fix-gate"     bash -c "cd '$T/qs'  && '$D' fix-gate --policy p"
qdir ql lib;   ok "rust lint report → candor-query"   "WOULD-RUN: candor-query where Net"    bash -c "cd '$T/ql'  && '$D' where Net"
qdir qx Executable; ok "rust Executable → candor-query" "WOULD-RUN: candor-query show f"    bash -c "cd '$T/qx'  && '$D' show f"

echo "scan routing (by manifest):"
sdir sr Cargo.toml;        ok "Cargo.toml → candor-scan"    "WOULD-RUN: candor-scan"  bash -c "cd '$T/sr' && '$D' scan ."
sdir st package.json;      ok "package.json → candor-ts"    "WOULD-RUN: candor-ts"    bash -c "cd '$T/st' && '$D' ."
sdir sj build.gradle.kts;  ok "gradle → candor-java"        "WOULD-RUN: candor-java"  bash -c "cd '$T/sj' && '$D' scan ."
sdir sm pom.xml;           ok "maven → candor-java"         "WOULD-RUN: candor-java"  bash -c "cd '$T/sm' && '$D' scan ."
sdir sv Package.swift;     ok "Package.swift → candor-swift" "WOULD-RUN: candor-swift" bash -c "cd '$T/sv' && '$D' scan ."

echo "loud failures (never a silent wrong-engine run):"
mkdir -p "$T/amb"; : > "$T/amb/Cargo.toml"; : > "$T/amb/package.json"
ok "polyglot scan → error"      "mixes languages"      bash -c "cd '$T/amb' && '$D' scan ."
mkdir -p "$T/mx/.candor"; : > "$T/mx/.candor/report.a.scan.json"; : > "$T/mx/.candor/report.b.JS.json"
ok "polyglot report → error"    "disambiguate"         bash -c "cd '$T/mx' && '$D' where Net"
ok "no report → error"          "no report"            bash -c "cd '$T' && '$D' where Net"
ok "--report override wins"     "WOULD-RUN: candor-query where Net --report" bash -c "cd /tmp && '$D' where Net --report '$T/qr'"

echo "§3.3.1 locator forms + tour (the scan opener's suggested commands must route):"
# tour is a query verb (was missing from QUERY_VERBS — `candor tour` fell through to SCAN routing and died)
ok "tour routes as a query"     "WOULD-RUN: candor-query tour 5"       bash -c "cd '$T/qr' && '$D' tour 5"
# a --report pointing at a DIRECT .json report file (any basename — not just `report.*`)
: > "$T/loose.pkg.scan.json"
ok "--report <file.json> routes" "WOULD-RUN: candor-query tour --report" bash -c "cd /tmp && '$D' tour --report '$T/loose.pkg.scan.json'"
: > "$T/loosej.pkg.jvm.json"
ok "--report <jvm file> → java" "WOULD-RUN: candor-java where Net"     bash -c "cd /tmp && '$D' where Net --report '$T/loosej.pkg.jvm.json'"
# a --report naming a BARE PREFIX whose basename isn't `report`
ok "--report <bare prefix> routes" "WOULD-RUN: candor-query where Net" bash -c "cd /tmp && '$D' where Net --report '$T/loose'"

echo "max-review regressions (phantom-engine sidecars; the token-less candor-ts report shape):"
# candor-scan's own ledger sidecars must NOT count as engine backends (they made the dispatcher
# refuse a completely standard scan family with "multiple engines' reports").
mkdir -p "$T/scanfam/.candor"
: > "$T/scanfam/.candor/report.demo.scan.json"
: > "$T/scanfam/.candor/report.demo.scan.callgraph.json"
: > "$T/scanfam/.candor/report.calibrated.json"
: > "$T/scanfam/.candor/report.encountered-demo.json"
: > "$T/scanfam/.candor/report.gate.json"
ok "scan family + ledgers → candor-query (not 'multiple engines')" "WOULD-RUN: candor-query where Net" \
   bash -c "cd '$T/scanfam' && '$D' where Net"
# candor-ts writes a TOKEN-LESS primary report (.candor/report.json) — the family glob can't see it.
mkdir -p "$T/tsfam/.candor"
: > "$T/tsfam/.candor/report.json"
: > "$T/tsfam/.candor/report.callgraph.json"
ok "token-less report.json → candor-ts-query" "WOULD-RUN: candor-ts-query tour" \
   bash -c "cd '$T/tsfam' && '$D' tour"
# and a --report pointing directly at a token-less .json file routes to ts too
ok "--report <token-less .json> → candor-ts-query" "WOULD-RUN: candor-ts-query where Net" \
   bash -c "cd /tmp && '$D' where Net --report '$T/tsfam/.candor/report.json'"

echo "max-review r2: token-less files sniff the ENVELOPE (never blind-JS); mixed families disambiguate:"
# a java `--json > baseline.json` direct file (the AGENTS-doc workflow) must route to JAVA, not ts
printf '{"candor":{"version":"abc1234","toolchain":"jdk-21","spec":"0.15"},"functions":[]}' > "$T/baseline.json"
ok "token-less java baseline.json -> candor-java (envelope sniff)" "WOULD-RUN: candor-java where Net" \
   bash -c "cd /tmp && '$D' where Net --report '$T/baseline.json'"
printf '{"candor":{"version":"candor-swift-0.15.0","toolchain":"swiftsyntax","spec":"0.15"},"functions":[]}' > "$T/swbase.json"
ok "token-less swift baseline -> candor-swift (envelope sniff)" "WOULD-RUN: candor-swift where Net" \
   bash -c "cd /tmp && '$D' where Net --report '$T/swbase.json'"
printf '{"meta":{"version":"scan-0.15.0","toolchain":"stable","spec":"0.15"},"functions":[]}' > "$T/rbase.json"
ok "token-less rust baseline -> candor-query (envelope sniff)" "WOULD-RUN: candor-query where Net" \
   bash -c "cd /tmp && '$D' where Net --report '$T/rbase.json'"
# a ts report.json BESIDE a tokened engine's reports must trip the ambiguity check, never be shadowed
mkdir -p "$T/mixed/.candor"
printf '{"candor":{"version":"candor-ts-0.15.0","toolchain":"node-23.0.0","spec":"0.15"},"functions":[]}' > "$T/mixed/.candor/report.json"
: > "$T/mixed/.candor/report.demo.scan.json"
ok "ts report.json beside a scan family -> disambiguate (not silently shadowed)" "disambiguate" \
   bash -c "cd '$T/mixed' && '$D' where Net"

echo "code-review regressions (2026-07-15):"
# want()/token bugs (bare update skipped every engine; `update java` was a no-op) — asserted network-free
# by checking the RESOLVED engine set the update case would fetch, via CANDOR_UPDATE_DRYRUN (prints the
# `want`-selected engines and exits before any curl).
ok "bare update selects all engines" "jvm rust ts swift" \
   bash -c "CANDOR_UPDATE_DRYRUN=1 '$D' update"
ok "update java → the jvm engine (token synonym, not a no-op)" "jvm" \
   bash -c "CANDOR_UPDATE_DRYRUN=1 '$D' update java"
ok "update rust ts → only those" "rust ts" \
   bash -c "CANDOR_UPDATE_DRYRUN=1 '$D' update rust ts"
# bare `candor` on a structurally-corrupt-but-valid-JSON report degrades to 'unreadable', no traceback.
# (DRYRUN doesn't affect the status dashboard — it reads the report directly, no engine needed.)
mkdir -p "$T/corruptshape/.candor"
printf '{"functions":{"a":1},"candor":"nope","coverage":"nope"}' > "$T/corruptshape/.candor/report.json"
notrace="$(cd "$T/corruptshape" && CANDOR_DISPATCH_DRYRUN= "$D" 2>&1)"
if [[ "$notrace" != *Traceback* ]]; then echo "  ok   corrupt-shape report → no python traceback in status"; else echo "  FAIL corrupt-shape traceback"; echo "$notrace"; fails=$((fails+1)); fi
# (init's report iteration is space-safe now — reps is a quoted bash array, not an unquoted string —
# but a real scan is needed to produce reports to iterate, which this DRYRUN harness can't do; that path
# is covered by the manual UX probes instead.)

echo
if [ "$fails" -eq 0 ]; then echo "candor-dispatch: OK"; else echo "candor-dispatch: $fails FAILED"; exit 1; fi
