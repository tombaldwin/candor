#!/usr/bin/env bash
# Regression test for candor-sarif — locks the SARIF 2.1.0 output contract the GitHub upload depends on:
#   • valid JSON, version 2.1.0, one run whose tool is "candor";
#   • each AS-EFF violation → a result with ruleId + level:error + message + partialFingerprints;
#   • loc → repo-relative uri: a BARE bytecode filename (Order.java) is rebuilt from the fn's package
#     under --src-root; a loc that is ALREADY a path (scan engines) is used as-is;
#   • codeFlows appear when a --query-cmd is given (mocked here) and are absent otherwise;
#   • a malformed / empty gate yields an empty-results SARIF, never a crash (never masks the gate).
# Hermetic: inline fixture report/gate JSON + a mock `path` query; no engine, no network.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SARIF="$HERE/candor-sarif"
command -v jq >/dev/null 2>&1 || { echo "SKIP: needs jq"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: needs python3"; exit 0; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# report: a JVM function with a bare-filename loc, and a scan-style one with a path loc.
cat > "$WORK/report.json" <<'JSON'
{"candor":{"spec":"0.7"},"functions":[
  {"fn":"app.domain.Order.audit","loc":"Order.java:6","direct":["Fs"],"inferred":["Fs"]},
  {"fn":"app.domain.Order.checkout","loc":"Order.java:9","direct":[],"inferred":["Fs"]},
  {"fn":"src/lib/net.ts::fetchThing","loc":"src/lib/net.ts:4:1: 4:9","direct":["Net"],"inferred":["Net"]}
]}
JSON

cat > "$WORK/gate.json" <<'JSON'
{"spec":"0.7","ok":false,"violations":[
  {"rule":"AS-EFF-006","fn":"app.domain.Order.checkout","detail":"`app.domain.Order.checkout` performs { Fs }, forbidden by policy (scope `app.domain`): `deny Fs app.domain`"},
  {"rule":"AS-EFF-006","fn":"src/lib/net.ts::fetchThing","detail":"`fetchThing` performs { Net }"}
]}
JSON

# mock query-cmd: `<cmd> path <report> <fn> <effect> --json` -> a two-hop path for checkout, else self.
MOCK="$WORK/mockq"
cat > "$MOCK" <<'MOCK'
#!/usr/bin/env bash
# args: path <report> <fn> <effect> --json
fn="$3"
if [ "$fn" = "app.domain.Order.checkout" ]; then
  echo '{"effect":"Fs","fn":"app.domain.Order.checkout","path":[{"fn":"app.domain.Order.checkout","loc":"Order.java:9","source":false},{"fn":"app.domain.Order.audit","loc":"Order.java:6","source":true}]}'
else
  echo '{"effect":"Net","fn":"'"$fn"'","path":[{"fn":"'"$fn"'","loc":"src/lib/net.ts:4:1: 4:9","source":true}]}'
fi
MOCK
chmod +x "$MOCK"

pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1"; fi; }

OUT=$(python3 "$SARIF" "$WORK/report.json" --gate "$WORK/gate.json" --src-root src 2>/dev/null)
ok "emits valid JSON"                         'printf "%s" "$OUT" | jq -e . >/dev/null'
ok "version is 2.1.0"                         '[ "$(printf "%s" "$OUT" | jq -r .version)" = 2.1.0 ]'
ok "one run, tool is candor"                  '[ "$(printf "%s" "$OUT" | jq -r ".runs[0].tool.driver.name")" = candor ]'
ok "rule AS-EFF-006 present, level error"     'printf "%s" "$OUT" | jq -e ".runs[0].tool.driver.rules[] | select(.id==\"AS-EFF-006\") | .defaultConfiguration.level==\"error\"" >/dev/null'
ok "two results"                              '[ "$(printf "%s" "$OUT" | jq ".runs[0].results|length")" = 2 ]'
ok "result has ruleId + error + fingerprint"  'printf "%s" "$OUT" | jq -e ".runs[0].results[0] | .ruleId==\"AS-EFF-006\" and .level==\"error\" and (.partialFingerprints.candorViolation|type==\"string\")" >/dev/null'
ok "bare loc rebuilt from package + src-root" '[ "$(printf "%s" "$OUT" | jq -r ".runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri")" = "src/app/domain/Order.java" ]'
ok "startLine from loc"                        '[ "$(printf "%s" "$OUT" | jq -r ".runs[0].results[0].locations[0].physicalLocation.region.startLine")" = 9 ]'
ok "path-style loc used as-is (no rebuild)"    '[ "$(printf "%s" "$OUT" | jq -r ".runs[0].results[1].locations[0].physicalLocation.artifactLocation.uri")" = "src/lib/net.ts" ]'
ok "path-style loc keeps column range"         '[ "$(printf "%s" "$OUT" | jq -r ".runs[0].results[1].locations[0].physicalLocation.region.startColumn")" = 1 ]'
ok "no codeFlows without --query-cmd"          '[ "$(printf "%s" "$OUT" | jq "[.runs[0].results[]|select(.codeFlows)]|length")" = 0 ]'

OUTQ=$(python3 "$SARIF" "$WORK/report.json" --gate "$WORK/gate.json" --src-root src --query-cmd "$MOCK" 2>/dev/null)
ok "codeFlows present with --query-cmd"        'printf "%s" "$OUTQ" | jq -e ".runs[0].results[0].codeFlows[0].threadFlows[0].locations|length==2" >/dev/null'
ok "codeFlow traces to the source hop"         'printf "%s" "$OUTQ" | jq -e "[.runs[0].results[0].codeFlows[0].threadFlows[0].locations[].location.message.text] | any(test(\"audit — source\"))" >/dev/null'

# effects: the SARIF uses the verdict's DENIED subset, not the report's (superset) direct set.
cat > "$WORK/report2.json" <<'JSON'
{"candor":{"spec":"0.8"},"functions":[
  {"fn":"app.domain.Order.audit","loc":"Order.java:6","direct":["Clock","Fs"],"inferred":["Clock","Fs"]}
]}
JSON
echo '{"spec":"0.8","ok":false,"violations":[{"rule":"AS-EFF-006","fn":"app.domain.Order.audit","effects":["Fs"],"detail":"`audit` performs { Fs }, forbidden"}]}' > "$WORK/eff.json"
OUTE=$(python3 "$SARIF" "$WORK/report2.json" --gate "$WORK/eff.json" --src-root src 2>/dev/null)
ok "SARIF properties.effects = the denied subset"  '[ "$(printf "%s" "$OUTE" | jq -c ".runs[0].results[0].properties.effects")" = "[\"Fs\"]" ]'
ok "effects is NOT the report superset direct set" '[ "$(printf "%s" "$OUTE" | jq -c ".runs[0].results[0].properties.effects")" != "[\"Clock\",\"Fs\"]" ]'

# an explicit effects:[] (a 009 layer-flow / 003 unresolved) is RESPECTED — the report's direct set must
# NOT leak in as properties.effects, and no codeFlow is traced (there's no single effect).
echo '{"candor":{"spec":"0.8"},"functions":[{"fn":"web.Ctl.handle","loc":"Ctl.java:5","direct":["Clock","Log"],"inferred":["Clock","Log"]}]}' > "$WORK/report3.json"
echo '{"spec":"0.8","ok":false,"violations":[{"rule":"AS-EFF-009","fn":"web.Ctl.handle","effects":[],"detail":"`web.Ctl.handle` reaches into a forbidden layer (via `repo.find`)"}]}' > "$WORK/lf.json"
OUTL=$(python3 "$SARIF" "$WORK/report3.json" --gate "$WORK/lf.json" --src-root src --query-cmd "$MOCK" 2>/dev/null)
ok "explicit effects:[] -> no properties.effects"  '[ "$(printf "%s" "$OUTL" | jq -r ".runs[0].results[0].properties.effects // \"none\"")" = none ]'
ok "explicit effects:[] -> no codeFlow traced"     '[ "$(printf "%s" "$OUTL" | jq -r ".runs[0].results[0].codeFlows // \"none\"")" = none ]'
ok "a verdict OMITTING effects still falls back"   'echo "{\"functions\":[{\"fn\":\"x.y\",\"direct\":[\"Fs\"]}]}" > "$WORK/rr.json"; echo "{\"violations\":[{\"rule\":\"AS-EFF-006\",\"fn\":\"x.y\"}]}" > "$WORK/gg.json"; [ "$(python3 "$SARIF" "$WORK/rr.json" --gate "$WORK/gg.json" 2>/dev/null | jq -c ".runs[0].results[0].properties.effects")" = "[\"Fs\"]" ]'

# advisory AS-EFF-007 -> level:warning (never a false error alert on a passing gate).
echo '{"spec":"0.8","ok":true,"violations":[{"rule":"AS-EFF-007","fn":"app.domain.Order.checkout","detail":"`checkout` performs { Fs } on caller-derived input"}]}' > "$WORK/adv.json"
OUTA=$(python3 "$SARIF" "$WORK/report.json" --gate "$WORK/adv.json" --src-root src 2>/dev/null)
ok "advisory AS-EFF-007 result is level:warning"   '[ "$(printf "%s" "$OUTA" | jq -r ".runs[0].results[0].level")" = warning ]'
ok "advisory rule metadata is level:warning"       '[ "$(printf "%s" "$OUTA" | jq -r ".runs[0].tool.driver.rules[0].defaultConfiguration.level")" = warning ]'
ok "a gate-failing code stays level:error"         '[ "$(printf "%s" "$OUT" | jq -r ".runs[0].results[0].level")" = error ]'

# clean gate (ok:true, no violations) -> valid SARIF, zero results.
echo '{"spec":"0.7","ok":true,"violations":[]}' > "$WORK/clean.json"
OUTC=$(python3 "$SARIF" "$WORK/report.json" --gate "$WORK/clean.json" 2>/dev/null)
ok "clean gate -> valid, empty results"        'printf "%s" "$OUTC" | jq -e ".runs[0].results|length==0" >/dev/null'

# malformed gate -> no crash, empty-results SARIF, exit 0.
echo 'not json {' > "$WORK/bad.json"
OUTB=$(python3 "$SARIF" "$WORK/report.json" --gate "$WORK/bad.json" 2>/dev/null); rc=$?
ok "malformed gate: exit 0"                    '[ "$rc" = 0 ]'
ok "malformed gate: valid empty SARIF"         'printf "%s" "$OUTB" | jq -e ".runs[0].results|length==0" >/dev/null'

echo
echo "test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
