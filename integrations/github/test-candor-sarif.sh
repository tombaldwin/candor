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

# fingerprint: a fn that violates two rules for DIFFERENT effects (deny Fs + deny Env on one method) must
# get DISTINCT partialFingerprints — else GitHub's dedup collapses them and hides a real violation.
echo '{"candor":{"spec":"0.8"},"functions":[{"fn":"app.Svc.run","loc":"Svc.java:3","direct":["Fs","Env"],"inferred":["Fs","Env"]}]}' > "$WORK/rfp.json"
echo '{"spec":"0.8","ok":false,"violations":[{"rule":"AS-EFF-006","fn":"app.Svc.run","effects":["Fs"],"detail":"`run` performs { Fs }"},{"rule":"AS-EFF-006","fn":"app.Svc.run","effects":["Env"],"detail":"`run` performs { Env }"}]}' > "$WORK/gfp.json"
OUTF=$(python3 "$SARIF" "$WORK/rfp.json" --gate "$WORK/gfp.json" --src-root src 2>/dev/null)
ok "same fn+rule, diff effect -> distinct fingerprints" '[ "$(printf "%s" "$OUTF" | jq -r "[.runs[0].results[].partialFingerprints.candorViolation]|unique|length")" = 2 ]'

# ⟨0.32⟩ TWO UNITS, ONE NAME. SPEC §2 names this tool: "a consumer that fingerprints on name alone
# silently hides one finding behind another". `fn|rule|effects` collided for two units that differ only
# by package, so GitHub's dedup showed ONE alert for two real violations — downstream of a red gate,
# where the reviewer never learns the second exists. Four rows, and they are the four states this can be
# in: identity on the verdict row, identity only in the report, no identity anywhere, and the honest
# limit. The OVER-CHARGE CONTROL is the row below them — one finding listed twice must still collapse,
# or "never collide" is satisfied by splitting every alert in two on every run.
cat > "$WORK/rid.json" <<'JSON'
{"candor":{"spec":"0.32"},"functions":[
  {"fn":"run","loc":"a/src/lib.rs:3:1","hash":"a#run","direct":["Fs"],"inferred":["Fs"]},
  {"fn":"run","loc":"b/src/lib.rs:7:1","hash":"b#run","direct":["Fs"],"inferred":["Fs"]}
]}
JSON
# [1] the verdict rows CARRY `hash` (⟨0.32⟩'s "a verdict row MUST carry enough identity"): keyed on it.
echo '{"spec":"0.32","ok":false,"violations":[{"rule":"AS-EFF-006","fn":"run","hash":"a#run","effects":["Fs"]},{"rule":"AS-EFF-006","fn":"run","hash":"b#run","effects":["Fs"]}]}' > "$WORK/gid.json"
OUTI=$(python3 "$SARIF" "$WORK/rid.json" --gate "$WORK/gid.json" 2>/dev/null)
ok "two units, one name, row hash -> 2 fingerprints"   '[ "$(printf "%s" "$OUTI" | jq -r "[.runs[0].results[].partialFingerprints.candorViolation]|unique|length")" = 2 ]'
# …and each result gets ITS OWN loc, not a same-named sibling's. A borrowed location is a fabricated one.
ok "…and each row joins its OWN unit's loc"            '[ "$(printf "%s" "$OUTI" | jq -r "[.runs[0].results[].locations[0].physicalLocation.artifactLocation.uri]|sort|join(\",\")")" = "a/src/lib.rs,b/src/lib.rs" ]'
# [2] the rows carry NO identity and the NAME is ambiguous in the report: the old code borrowed
# whichever entry happened to be last. Now the name resolves to nothing, the rows fall back to their own
# `loc`, and they stay distinct.
echo '{"spec":"0.32","ok":false,"violations":[{"rule":"AS-EFF-006","fn":"run","effects":["Fs"],"loc":"a/src/lib.rs:3:1"},{"rule":"AS-EFF-006","fn":"run","effects":["Fs"],"loc":"b/src/lib.rs:7:1"}]}' > "$WORK/gid2.json"
OUTI2=$(python3 "$SARIF" "$WORK/rid.json" --gate "$WORK/gid2.json" 2>/dev/null)
ok "ambiguous name, no row hash -> 2 fingerprints"     '[ "$(printf "%s" "$OUTI2" | jq -r "[.runs[0].results[].partialFingerprints.candorViolation]|unique|length")" = 2 ]'
# [3] THE HONEST LIMIT: ambiguous name, no hash, no loc on either row — nothing can tell them apart, so
# they collapse (as they always did) and the tool SAYS SO on stderr rather than passing it off.
echo '{"candor":{"spec":"0.32"},"functions":[{"fn":"run","hash":"a#run","direct":["Fs"]},{"fn":"run","hash":"b#run","direct":["Fs"]}]}' > "$WORK/rid3.json"
echo '{"spec":"0.32","ok":false,"violations":[{"rule":"AS-EFF-006","fn":"run","effects":["Fs"]},{"rule":"AS-EFF-006","fn":"run","effects":["Fs"]}]}' > "$WORK/gid3.json"
OUTI3=$(python3 "$SARIF" "$WORK/rid3.json" --gate "$WORK/gid3.json" 2>"$WORK/iderr"); rci3=$?
ok "no identity at all -> collapse is DISCLOSED"       '[ "$rci3" = 0 ] && grep -q "names more than one unit" "$WORK/iderr"'
# [4] OVER-CHARGE CONTROL — one unambiguous finding, gated twice (a re-run, a duplicated row): SAME
# fingerprint. A tool that answers "distinct" here would churn every alert on every run and dismissals
# would never stick, which is a worse failure than the one being fixed and passes a naive "no collisions"
# assertion perfectly.
echo '{"candor":{"spec":"0.32"},"functions":[{"fn":"solo","loc":"s.rs:1:1","hash":"s#solo","direct":["Fs"]}]}' > "$WORK/rid4.json"
echo '{"spec":"0.32","ok":false,"violations":[{"rule":"AS-EFF-006","fn":"solo","effects":["Fs"]},{"rule":"AS-EFF-006","fn":"solo","effects":["Fs"]}]}' > "$WORK/gid4.json"
OUTI4=$(python3 "$SARIF" "$WORK/rid4.json" --gate "$WORK/gid4.json" 2>/dev/null)
ok "one finding listed twice still collapses"          '[ "$(printf "%s" "$OUTI4" | jq -r "[.runs[0].results[].partialFingerprints.candorViolation]|unique|length")" = 1 ]'
# [5] DEGRADE SAFELY when the identity field is absent from the report the row points at — a row hash
# that matches nothing must not crash and must not borrow a name-matched entry's decoration.
echo '{"spec":"0.32","ok":false,"violations":[{"rule":"AS-EFF-006","fn":"run","hash":"z#run","effects":["Fs"]}]}' > "$WORK/gid5.json"
OUTI5=$(python3 "$SARIF" "$WORK/rid.json" --gate "$WORK/gid5.json" 2>/dev/null); rci5=$?
ok "unresolvable row hash -> no crash, no borrowed loc" '[ "$rci5" = 0 ] && [ "$(printf "%s" "$OUTI5" | jq -r ".runs[0].results[0].locations|length")" = 0 ]'

# advisory AS-EFF-007 -> level:warning (never a false error alert on a passing gate).
echo '{"spec":"0.8","ok":true,"violations":[{"rule":"AS-EFF-007","fn":"app.domain.Order.checkout","detail":"`checkout` performs { Fs } on caller-derived input"}]}' > "$WORK/adv.json"
OUTA=$(python3 "$SARIF" "$WORK/report.json" --gate "$WORK/adv.json" --src-root src 2>/dev/null)
ok "advisory AS-EFF-007 result is level:warning"   '[ "$(printf "%s" "$OUTA" | jq -r ".runs[0].results[0].level")" = warning ]'
ok "advisory rule metadata is level:warning"       '[ "$(printf "%s" "$OUTA" | jq -r ".runs[0].tool.driver.rules[0].defaultConfiguration.level")" = warning ]'
ok "a gate-failing code stays level:error"         '[ "$(printf "%s" "$OUT" | jq -r ".runs[0].results[0].level")" = error ]'

# crash contract (max-review 28/33/34): "Exit: 0 always" + malformed input degrades, never a traceback.
echo '{"spec":"0.8","ok":false,"violations":[{"rule":"AS-EFF-006","fn":"app.domain.Order.audit","effects":null,"detail":"x"}]}' > "$WORK/nullfx.json"
OUTN=$(python3 "$SARIF" "$WORK/report.json" --gate "$WORK/nullfx.json" 2>/dev/null); rcn=$?
ok "effects:null verdict → no crash, exit 0"       '[ "$rcn" = 0 ] && printf "%s" "$OUTN" | jq -e ".runs[0].results|length==1" >/dev/null'
echo '{"candor":{"spec":"0.8"},"functions":[{"fn":"x.y","loc":42,"direct":["Fs"]}]}' > "$WORK/badloc.json"
echo '{"spec":"0.8","ok":false,"violations":[{"rule":"AS-EFF-006","fn":"x.y","effects":["Fs"]}]}' > "$WORK/badlocg.json"
OUTB=$(python3 "$SARIF" "$WORK/badloc.json" --gate "$WORK/badlocg.json" 2>/dev/null); rcbl=$?
ok "non-string loc → no crash, exit 0"             '[ "$rcbl" = 0 ] && printf "%s" "$OUTB" | jq -e . >/dev/null'
python3 "$SARIF" "$WORK/report.json" --gate "$WORK/gate.json" -o "$WORK/no/such/dir/out.sarif" >/dev/null 2>"$WORK/oerr"; rco=$?
ok "unwritable -o → disclosed on stderr, exit 0"   '[ "$rco" = 0 ] && grep -q "could not write" "$WORK/oerr"'

# clean gate (ok:true, no violations) -> valid SARIF, zero results.
echo '{"spec":"0.7","ok":true,"violations":[]}' > "$WORK/clean.json"
OUTC=$(python3 "$SARIF" "$WORK/report.json" --gate "$WORK/clean.json" 2>/dev/null)
ok "clean gate -> valid, empty results"        'printf "%s" "$OUTC" | jq -e ".runs[0].results|length==0" >/dev/null'

# malformed gate -> no crash, empty-results SARIF, exit 0.
echo 'not json {' > "$WORK/bad.json"
OUTB=$(python3 "$SARIF" "$WORK/report.json" --gate "$WORK/bad.json" 2>/dev/null); rc=$?
ok "malformed gate: exit 0"                    '[ "$rc" = 0 ]'
ok "malformed gate: valid empty SARIF"         'printf "%s" "$OUTB" | jq -e ".runs[0].results|length==0" >/dev/null'

# crash contract, structural malformations: the docstring promises malformed input NEVER crashes —
# each of these produced a traceback (exit 1) before the isinstance guards.
echo '[]' > "$WORK/gate-list.json"                       # gate JSON that is a list, not an object
OUTG=$(python3 "$SARIF" "$WORK/report.json" --gate "$WORK/gate-list.json" 2>"$WORK/glerr"); rcg=$?
ok "gate-is-a-list: exit 0, empty SARIF, disclosed"     '[ "$rcg" = 0 ] && printf "%s" "$OUTG" | jq -e ".runs[0].results|length==0" >/dev/null && grep -q "not a JSON object" "$WORK/glerr"'
# a violation ITEM that is a string — skipped + disclosed; the well-formed sibling still surfaces.
echo '{"spec":"0.8","ok":false,"violations":["oops",{"rule":"AS-EFF-006","fn":"app.domain.Order.audit","effects":["Fs"],"detail":"x"}]}' > "$WORK/gate-strv.json"
OUTS=$(python3 "$SARIF" "$WORK/report.json" --gate "$WORK/gate-strv.json" 2>"$WORK/sverr"); rcs=$?
ok "string violation item: skipped, sibling kept"       '[ "$rcs" = 0 ] && [ "$(printf "%s" "$OUTS" | jq ".runs[0].results|length")" = 1 ] && grep -q "non-object entry" "$WORK/sverr"'
echo '[{"fn":"x.y"}]' > "$WORK/report-list.json"         # report that is a list, not an envelope
OUTR=$(python3 "$SARIF" "$WORK/report-list.json" --gate "$WORK/gate.json" 2>/dev/null); rcr=$?
ok "report-is-a-list: exit 0, violations still emitted" '[ "$rcr" = 0 ] && [ "$(printf "%s" "$OUTR" | jq ".runs[0].results|length")" = 2 ]'
# a non-dict entry in functions — skipped + disclosed; the dict sibling still indexes its loc.
echo '{"candor":{"spec":"0.8"},"functions":["oops",{"fn":"app.domain.Order.checkout","loc":"Order.java:9","direct":["Fs"]}]}' > "$WORK/report-badfns.json"
OUTX=$(python3 "$SARIF" "$WORK/report-badfns.json" --gate "$WORK/gate.json" --src-root src 2>"$WORK/bferr"); rcx=$?
ok "non-dict functions entry: skipped, sibling indexed" '[ "$rcx" = 0 ] && [ "$(printf "%s" "$OUTX" | jq -r ".runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri")" = "src/app/domain/Order.java" ] && grep -q "non-object entry" "$WORK/bferr"'

# SARIF 2.1.0 schema validation against the vendored OASIS schema (the contract GitHub ingests).
# Skips gracefully if `jsonschema` isn't installed — offline, no network.
SCHEMA="$HERE/sarif-2.1.0.schema.json"
if [ -f "$SCHEMA" ] && python3 -c "import jsonschema" 2>/dev/null; then
  python3 "$SARIF" "$WORK/report.json" --gate "$WORK/gate.json" --src-root src -o "$WORK/v.sarif" 2>/dev/null
  if python3 - "$SCHEMA" "$WORK/v.sarif" <<'PY'
import json, sys, jsonschema
schema = json.load(open(sys.argv[1])); doc = json.load(open(sys.argv[2]))
cls = jsonschema.validators.validator_for(schema)
errs = list(cls(schema).iter_errors(doc))
sys.exit(1 if errs else 0)
PY
  then pass=$((pass+1)); echo "  ok   output validates against the SARIF 2.1.0 schema"
  else fail=$((fail+1)); echo "  FAIL output does NOT validate against the SARIF 2.1.0 schema"; fi
else
  echo "  --   SARIF-schema validation skipped (no jsonschema / schema file)"
fi

echo
echo "test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
