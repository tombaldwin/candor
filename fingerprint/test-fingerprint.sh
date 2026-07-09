#!/usr/bin/env bash
# Regression test for candor-fingerprint — locks the three contracts the README sells:
#   • DETERMINISM: the same logical graph yields byte-identical SVG regardless of the order an engine
#     happens to emit report functions, callgraph keys, or adjacency lists;
#   • --json shape: the metadata fields (effect mix, structure + structure_detail incl. .value) are present
#     and the two scales agree (structure 0–1, structure_detail.value = ×100);
#   • --baseline: the diff block carries from/to/delta for structure and each component.
# Hermetic: an inline fixture report + callgraph; no engine, no network, no rasterizer (SVG/JSON only).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
FP="$HERE/candor-fingerprint.mjs"
command -v node >/dev/null 2>&1 || { echo "SKIP: needs node"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: needs jq"; exit 0; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1"; fi; }

# Fixture: two effect layers + an Unknown + a call cycle (alpha<->beta), so every structure component
# (smear via multi-effect `hub`, unknownShare, tangle, cycleRatio) is exercised, not just zeros.
cat > "$WORK/report.json" <<'JSON'
{"candor":{"spec":"0.8"},"functions":[
  {"fn":"a.alpha","inferred":["Fs"]},
  {"fn":"a.beta","inferred":["Fs"]},
  {"fn":"b.gamma","inferred":["Net"]},
  {"fn":"b.hub","inferred":["Net","Db","Clock"]},
  {"fn":"c.delta","inferred":["Unknown"]}
]}
JSON
cat > "$WORK/report.callgraph.json" <<'JSON'
{"a.alpha":["a.beta"],"a.beta":["a.alpha"],"b.gamma":["c.delta","b.hub"],"b.hub":[],"c.delta":[]}
JSON

# The SAME logical graph, emitted the way a different engine might: functions reversed, callgraph keys
# reversed, adjacency lists reversed.
cat > "$WORK/reversed.json" <<'JSON'
{"candor":{"spec":"0.8"},"functions":[
  {"fn":"c.delta","inferred":["Unknown"]},
  {"fn":"b.hub","inferred":["Net","Db","Clock"]},
  {"fn":"b.gamma","inferred":["Net"]},
  {"fn":"a.beta","inferred":["Fs"]},
  {"fn":"a.alpha","inferred":["Fs"]}
]}
JSON
cat > "$WORK/reversed.callgraph.json" <<'JSON'
{"c.delta":[],"b.hub":[],"b.gamma":["b.hub","c.delta"],"a.beta":["a.alpha"],"a.alpha":["a.beta"]}
JSON

# (a) determinism — byte-identical SVG under reversed input order, and across re-runs.
node "$FP" "$WORK/report.json" --svg "$WORK/fwd.svg" >/dev/null 2>&1; rc1=$?
node "$FP" "$WORK/reversed.json" --svg "$WORK/rev.svg" >/dev/null 2>&1; rc2=$?
node "$FP" "$WORK/report.json" --svg "$WORK/fwd2.svg" >/dev/null 2>&1
ok "renders (exit 0) on both orderings"           '[ "$rc1" = 0 ] && [ "$rc2" = 0 ] && [ -s "$WORK/fwd.svg" ]'
ok "SVG byte-identical under reversed key+adjacency+function order" 'cmp -s "$WORK/fwd.svg" "$WORK/rev.svg"'
ok "SVG byte-identical across re-runs"            'cmp -s "$WORK/fwd.svg" "$WORK/fwd2.svg"'

# (b) --json shape — the fields the README documents, on stdout, no SVG side effect with --no-svg.
J=$(node "$FP" "$WORK/report.json" --json --no-svg 2>/dev/null)
ok "--json is valid JSON"                         'printf "%s" "$J" | jq -e . >/dev/null'
ok "effect mix present (Fs/Net shares)"           'printf "%s" "$J" | jq -e ".effects.Fs > 0 and .effects.Net > 0" >/dev/null'
ok "unknown share present and > 0"                'printf "%s" "$J" | jq -e ".unknown > 0" >/dev/null'
ok "structure is 0..1"                            'printf "%s" "$J" | jq -e ".structure >= 0 and .structure <= 1" >/dev/null'
ok "structure_detail.value = structure ×100"      'printf "%s" "$J" | jq -e "(.structure_detail.value - (.structure*100)) | fabs < 1" >/dev/null'
ok "structure_detail components all present"      'printf "%s" "$J" | jq -e ".structure_detail | has(\"smear\") and has(\"unknown\") and has(\"tangleExcess\") and has(\"cycleRatio\")" >/dev/null'
ok "cycle detected (alpha<->beta) -> cycleRatio>0" 'printf "%s" "$J" | jq -e ".structure_detail.cycleRatio > 0" >/dev/null'
ok "smear counted (hub carries 3 effects)"        'printf "%s" "$J" | jq -e ".structure_detail.smear > 0" >/dev/null'

# (c) --baseline — diff vs a baseline report: one function gains Net, so structure moves and the block
# carries from/to/delta for the headline and every component.
cat > "$WORK/base.json" <<'JSON'
{"candor":{"spec":"0.8"},"functions":[
  {"fn":"a.alpha","inferred":["Fs"]},
  {"fn":"a.beta","inferred":["Fs"]},
  {"fn":"b.gamma","inferred":["Net"]},
  {"fn":"b.hub","inferred":["Net"]},
  {"fn":"c.delta","inferred":["Unknown"]}
]}
JSON
cp "$WORK/report.callgraph.json" "$WORK/base.callgraph.json"
JB=$(node "$FP" "$WORK/report.json" --json --no-svg --baseline "$WORK/base.json" 2>/dev/null)
ok "baseline block present with prefix"           'printf "%s" "$JB" | jq -e ".baseline.prefix | test(\"base\")" >/dev/null'
ok "baseline.structure has from/to/delta"         'printf "%s" "$JB" | jq -e ".baseline.structure | has(\"from\") and has(\"to\") and has(\"delta\")" >/dev/null'
ok "delta = to - from"                            'printf "%s" "$JB" | jq -e "(.baseline.structure.delta - (.baseline.structure.to - .baseline.structure.from)) | fabs < 0.002" >/dev/null'
ok "every component diffed (smear/unknown/tangleExcess/cycleRatio)" 'printf "%s" "$JB" | jq -e ".baseline.components | has(\"smear\") and has(\"unknown\") and has(\"tangleExcess\") and has(\"cycleRatio\")" >/dev/null'
ok "smear regression shows as a positive delta"   'printf "%s" "$JB" | jq -e ".baseline.components.smear.delta > 0" >/dev/null'

echo
echo "test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
