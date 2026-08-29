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

# [6] ⟨0.32⟩ THE IDENTITY IS THE PAIR, AND `hash` ALONE IS NOT IT. candor-ts's `hash` is
# `<package>#<local tail>` and is DOCUMENTED NON-UNIQUE in ts's own commit — 13 collisions in hono, five
# `handle` all keyed `src#handle`. ts's identity is `fn` + `hash` TOGETHER. Keying on `hash` alone
# reintroduced the exact clause above by the other axis: two DISTINCT units share a fingerprint, GitHub
# shows ONE alert, and the last-one-wins `by_hash` index hands the first row the SECOND one's file — a
# fabricated location, not a missing one. The `by_fn` index already withholds a collided name; `by_hash`
# did not withhold a collided hash.
cat > "$WORK/rcol.json" <<'JSON'
{"candor":{"spec":"0.32"},"functions":[
  {"fn":"src.a.go","loc":"src/a.ts:3:1","hash":"src#go","direct":["Exec"],"inferred":["Exec"]},
  {"fn":"src.b.go","loc":"src/b.ts:7:1","hash":"src#go","direct":["Exec"],"inferred":["Exec"]},
  {"fn":"src.b.other","loc":"src/b.ts:9:1","hash":"src#other","direct":["Exec"],"inferred":["Exec"]}
]}
JSON
cat > "$WORK/gcol.json" <<'JSON'
{"spec":"0.32","ok":false,"violations":[
 {"rule":"AS-EFF-006","fn":"src.a.go","hash":"src#go","effects":["Exec"],"detail":"`src.a.go` performs { Exec }, forbidden by `deny Exec`"},
 {"rule":"AS-EFF-006","fn":"src.b.go","hash":"src#go","effects":["Exec"],"detail":"`src.b.go` performs { Exec }, forbidden by `deny Exec`"},
 {"rule":"AS-EFF-006","fn":"src.b.other","hash":"src#other","effects":["Exec"],"detail":"`src.b.other` performs { Exec }, forbidden by `deny Exec`"}
]}
JSON
OUTP=$(python3 "$SARIF" "$WORK/rcol.json" --gate "$WORK/gcol.json" 2>/dev/null)
ok "a NON-UNIQUE hash still yields one alert per unit" '[ "$(printf "%s" "$OUTP" | jq -r "[.runs[0].results[].partialFingerprints.candorViolation]|unique|length")" = 3 ]'
# …and the location half: the join must resolve the PAIR, so `src.a.go` keeps a/, not the sibling's b/.
ok "…each row keeps its OWN file, none borrowed"       '[ "$(printf "%s" "$OUTP" | jq -r "[.runs[0].results[].locations[0].physicalLocation.artifactLocation.uri]|join(\",\")")" = "src/a.ts,src/b.ts,src/b.ts" ]'
# THE WITHHELD JOIN MUST NOT FALL THROUGH TO SOMETHING WORSE. A row whose (fn, hash) pair matches no
# entry, under a hash the report holds TWO entries for: the hash-only rung must refuse it rather than
# hand back whichever entry it indexed last. No location beats a fabricated one.
echo '{"spec":"0.32","ok":false,"violations":[{"rule":"AS-EFF-006","fn":"src.c.go","hash":"src#go","effects":["Exec"],"detail":"x"}]}' > "$WORK/gcol2.json"
OUTP2=$(python3 "$SARIF" "$WORK/rcol.json" --gate "$WORK/gcol2.json" 2>/dev/null); rcp2=$?
ok "unmatched pair under a collided hash -> no loc"    '[ "$rcp2" = 0 ] && [ "$(printf "%s" "$OUTP2" | jq -r ".runs[0].results[0].locations|length")" = 0 ]'
# …while a hash the report holds exactly ONE entry for still joins one hop later (the ladder's rung 2 is
# not collateral damage of the withhold): a row naming that entry by a DIFFERENT spelling still gets its
# loc, because the identity — not the name — is what resolved it.
echo '{"spec":"0.32","ok":false,"violations":[{"rule":"AS-EFF-006","fn":"other","hash":"src#other","effects":["Exec"],"detail":"x"}]}' > "$WORK/gcol3.json"
OUTP3=$(python3 "$SARIF" "$WORK/rcol.json" --gate "$WORK/gcol3.json" 2>/dev/null)
ok "a UNIQUE hash still joins its entry's loc"         '[ "$(printf "%s" "$OUTP3" | jq -r ".runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri")" = "src/b.ts" ]'
# THE BACKSTOP, AND WHY THE SWEEP MISSED THIS ENTIRELY. The output sweep only re-keys a tie whose rows sit
# at DIFFERENT locations; both rows here were decorated with the SAME borrowed loc, so it read them as one
# finding listed twice and said nothing. Two rows that say DIFFERENT THINGS are not one finding, whatever
# their locations agree on — that must be LOUD even when nothing is left to re-key it by.
echo '{"candor":{"spec":"0.32"},"functions":[{"fn":"go","hash":"src#go","direct":["Exec"]},{"fn":"go","hash":"src#go","direct":["Exec"]}]}' > "$WORK/rcol4.json"
echo '{"spec":"0.32","ok":false,"violations":[{"rule":"AS-EFF-006","fn":"go","hash":"src#go","effects":["Exec"],"detail":"`a.go` performs { Exec }"},{"rule":"AS-EFF-006","fn":"go","hash":"src#go","effects":["Exec"],"detail":"`b.go` performs { Exec }"}]}' > "$WORK/gcol4.json"
OUTP4=$(python3 "$SARIF" "$WORK/rcol4.json" --gate "$WORK/gcol4.json" 2>"$WORK/colerr"); rcp4=$?
ok "indistinguishable rows that DIFFER -> disclosed"   '[ "$rcp4" = 0 ] && grep -q "say different things" "$WORK/colerr"'
# …and the over-charge control for THAT disclosure: the identical duplicate of [4] must stay SILENT, or
# the warning fires on every re-run and stops being read.
python3 "$SARIF" "$WORK/rid4.json" --gate "$WORK/gid4.json" >/dev/null 2>"$WORK/colerr2"
ok "one finding listed twice stays silent"             '[ ! -s "$WORK/colerr2" ]'

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
OUTC=$(python3 "$SARIF" "$WORK/report.json" --gate "$WORK/clean.json" 2>"$WORK/cleanerr")
ok "clean gate -> valid, empty results"        'printf "%s" "$OUTC" | jq -e ".runs[0].results|length==0" >/dev/null'
# OVER-CHARGE CONTROL for the completeness re-disclosure below: a genuinely clean, complete scan must
# get NO invocations key and NO stderr noise — the rung must not tax the common case.
ok "clean gate -> no invocations, silent"      '[ "$(printf "%s" "$OUTC" | jq -r ".runs[0].invocations // \"none\"")" = none ] && [ ! -s "$WORK/cleanerr" ]'

# SPEC ⟨0.24⟩: a REFUSED gate document carries `ok:false, refused:true` and MUST NOT carry a `violations`
# key at all — "an empty array there is precisely the claim it cannot make". Before this fix, reading an
# absent `violations` key as `[]` made a refusal indistinguishable from a clean scan: empty results,
# silent stderr. It must now surface as `results:[]` PLUS a run-level completeness caveat, never a
# location-bearing finding (there is no line to blame — the gate answered nothing).
echo '{"spec":"0.24","ok":false,"refused":true,"reason":"a scoped rule could not be decided"}' > "$WORK/refused.json"
OUTREF=$(python3 "$SARIF" "$WORK/report.json" --gate "$WORK/refused.json" 2>"$WORK/referr"); rcref=$?
ok "refused gate: exit 0, still no results"    '[ "$rcref" = 0 ] && [ "$(printf "%s" "$OUTREF" | jq ".runs[0].results|length")" = 0 ]'
ok "refused gate: NOT silently read as clean"  '[ "$(printf "%s" "$OUTREF" | jq -r ".runs[0].invocations[0].executionSuccessful")" = false ]'
ok "refused gate: names the code CANDOR-REFUSED" 'printf "%s" "$OUTREF" | jq -e ".runs[0].invocations[0].toolExecutionNotifications[0].descriptor.id==\"CANDOR-REFUSED\"" >/dev/null'
ok "refused gate: also disclosed on stderr"    'grep -q "REFUSED to certify" "$WORK/referr"'

# SPEC ⟨0.28⟩: `incomplete:true` (unanalyzed files / a dependency report that judged nothing) is the
# other verdict-preserving MUST — an incomplete gate's `violations:[]` is a real (if partial) answer, so
# `results` stays `[]`, but the caveat must travel rather than evaporate into an indistinguishable "clean".
echo '{"candor":{"spec":"0.28"},"functions":[{"fn":"app.domain.Order.audit","loc":"Order.java:6","direct":["Fs"],"inferred":["Fs"]}],"unanalyzed":[{"path":"src/legacy/Weird.java","reason":"malformed bytecode"}]}' > "$WORK/increport.json"
echo '{"spec":"0.28","ok":false,"incomplete":true,"unanalyzed":[{"path":"src/legacy/Weird.java","reason":"malformed bytecode"}],"violations":[]}' > "$WORK/incgate.json"
OUTINC=$(python3 "$SARIF" "$WORK/increport.json" --gate "$WORK/incgate.json" 2>"$WORK/increrr"); rcinc=$?
ok "incomplete gate: exit 0, results stay []"  '[ "$rcinc" = 0 ] && [ "$(printf "%s" "$OUTINC" | jq ".runs[0].results|length")" = 0 ]'
ok "incomplete gate: flagged, not clean"       '[ "$(printf "%s" "$OUTINC" | jq -r ".runs[0].invocations[0].executionSuccessful")" = false ]'
ok "incomplete gate: names CANDOR-INCOMPLETE"  'printf "%s" "$OUTINC" | jq -e ".runs[0].invocations[0].toolExecutionNotifications[0].descriptor.id==\"CANDOR-INCOMPLETE\"" >/dev/null'
ok "incomplete gate: names the unread file count" 'grep -q "1 file(s)" "$WORK/increrr"'
# a REAL violation found ALONGSIDE incompleteness must still surface as an error result — the caveat is
# additive, never a substitute for a certain finding the gate DID make.
echo '{"spec":"0.28","ok":false,"incomplete":true,"unanalyzed":[{"path":"x","reason":"y"}],"violations":[{"rule":"AS-EFF-006","fn":"app.domain.Order.audit","effects":["Fs"],"detail":"x"}]}' > "$WORK/incgate2.json"
OUTINC2=$(python3 "$SARIF" "$WORK/increport.json" --gate "$WORK/incgate2.json" 2>/dev/null)
ok "incomplete + a real violation: both present"  '[ "$(printf "%s" "$OUTINC2" | jq ".runs[0].results|length")" = 1 ] && [ "$(printf "%s" "$OUTINC2" | jq -r ".runs[0].invocations[0].executionSuccessful")" = false ]'

# SPEC ⟨0.30⟩/⟨0.32⟩: `excluded[].peeked:false` and a non-empty `outOfScope` each suppress `ok`/exit ON
# THEIR OWN — checked here DIRECTLY, not only through the shared `incomplete` flag a producer is expected
# to raise alongside them. A gate that sets `ok:false` and one of these keys WITHOUT `incomplete` (a
# partial ⟨0.32⟩ implementation, a hand-edited or filtered document, a future engine) must not fall back
# to reading `results:[]` as clean. Measured against the pre-fix tool: both produced a byte-identical
# clean empty-results SARIF with no `invocations` and no stderr line.
echo '{"spec":"0.32","ok":false,"violations":[],"excluded":[{"class":"deploy-script","count":1,"peeked":false,"reason":"uncompiled"}]}' > "$WORK/excgate.json"
OUTEXC=$(python3 "$SARIF" "$WORK/report.json" --gate "$WORK/excgate.json" 2>"$WORK/excerr"); rcexc=$?
ok "excluded/peeked:false alone (no incomplete): exit 0, results []" '[ "$rcexc" = 0 ] && [ "$(printf "%s" "$OUTEXC" | jq ".runs[0].results|length")" = 0 ]'
ok "…flagged, not clean"                            '[ "$(printf "%s" "$OUTEXC" | jq -r ".runs[0].invocations[0].executionSuccessful")" = false ]'
ok "…names CANDOR-INCOMPLETE and the class"          'grep -q "deploy-script" "$WORK/excerr"'

echo '{"spec":"0.32","ok":false,"violations":[],"outOfScope":[{"fn":"x.Deploy.run","path":"dist/shipped.js","effects":["Exec"],"class":"build-output"}]}' > "$WORK/oosgate.json"
OUTOOS=$(python3 "$SARIF" "$WORK/report.json" --gate "$WORK/oosgate.json" 2>"$WORK/ooserr"); rcoos=$?
ok "outOfScope alone (no incomplete): exit 0, results []" '[ "$rcoos" = 0 ] && [ "$(printf "%s" "$OUTOOS" | jq ".runs[0].results|length")" = 0 ]'
ok "…flagged, not clean"                            '[ "$(printf "%s" "$OUTOOS" | jq -r ".runs[0].invocations[0].executionSuccessful")" = false ]'
ok "…names CANDOR-INCOMPLETE"                        'printf "%s" "$OUTOOS" | jq -e ".runs[0].invocations[0].toolExecutionNotifications[0].descriptor.id==\"CANDOR-INCOMPLETE\"" >/dev/null'

# `excluded[].class` is engine-chosen vocabulary (SPEC §2 ⟨0.29⟩) and MUST NOT change behaviour — an
# unread class under a brand-new/unknown token (the ⟨0.34⟩ `dispatch-widened` shape) is caught exactly
# like any other, and a PEEKED class (or one marked `judgedElsewhere`) under that SAME unknown token is
# the over-charge control and must stay clean.
echo '{"spec":"0.34","ok":false,"violations":[],"excluded":[{"class":"dispatch-widened","count":2,"peeked":false,"reason":"widened dispatch target unread"}]}' > "$WORK/dwgate.json"
OUTDW=$(python3 "$SARIF" "$WORK/report.json" --gate "$WORK/dwgate.json" 2>"$WORK/dwerr")
ok "unknown excluded class (dispatch-widened): still caught"  'grep -q "dispatch-widened" "$WORK/dwerr"'
echo '{"spec":"0.34","ok":true,"violations":[],"excluded":[{"class":"dispatch-widened","count":2,"peeked":true,"judgedElsewhere":true,"reason":"already judged"}]}' > "$WORK/dwclean.json"
OUTDWC=$(python3 "$SARIF" "$WORK/report.json" --gate "$WORK/dwclean.json" 2>"$WORK/dwcerr")
ok "…peeked+judgedElsewhere under the same unknown class: stays clean" '[ "$(printf "%s" "$OUTDWC" | jq -r ".runs[0].invocations // \"none\"")" = none ] && [ ! -s "$WORK/dwcerr" ]'

# THE BACKSTOP: an `ok:false` gate this tool cannot attribute to ANY recognized cause (not refused, not
# incomplete, not excluded/outOfScope) must still not present its empty `results` as a clean scan — SPEC
# keeps adding causes (⟨0.29⟩ excluded, ⟨0.30⟩ outOfScope, ⟨0.32⟩ peeked, ⟨0.33⟩ scannedUnder…) and a
# boundary drawn around today's enumerated list would miss the next one exactly as it missed these two.
echo '{"spec":"0.34","ok":false,"violations":[]}' > "$WORK/unkgate.json"
OUTUNK=$(python3 "$SARIF" "$WORK/report.json" --gate "$WORK/unkgate.json" 2>"$WORK/unkerr")
ok "ok:false, no recognized cause: still flagged"    '[ "$(printf "%s" "$OUTUNK" | jq -r ".runs[0].invocations[0].executionSuccessful")" = false ]'
ok "…names CANDOR-UNKNOWN-FAIL"                      'printf "%s" "$OUTUNK" | jq -e ".runs[0].invocations[0].toolExecutionNotifications[0].descriptor.id==\"CANDOR-UNKNOWN-FAIL\"" >/dev/null'
# …and the backstop must NEVER fire beside a real violation (results non-empty) — that case already
# discloses itself, and a redundant caveat there would be noise, not a missing signal.
echo '{"spec":"0.34","ok":false,"violations":[{"rule":"AS-EFF-006","fn":"app.domain.Order.checkout","effects":["Fs"],"detail":"x"}]}' > "$WORK/unkgate2.json"
OUTUNK2=$(python3 "$SARIF" "$WORK/report.json" --gate "$WORK/unkgate2.json" 2>"$WORK/unkerr2")
ok "ok:false WITH a real violation: no backstop noise" '[ "$(printf "%s" "$OUTUNK2" | jq ".runs[0].results|length")" = 1 ] && [ ! -s "$WORK/unkerr2" ]'

# OVER-CHARGE CONTROLS for all of the above: `zeroMatch` (⟨0.27⟩, advisory — MUST NOT change ok/exit) and
# a plain clean gate must both stay byte-silent — no invocations, no stderr — through every check above.
echo '{"spec":"0.27","ok":true,"violations":[],"zeroMatch":["deny Net app.typo"]}' > "$WORK/zmgate.json"
OUTZM=$(python3 "$SARIF" "$WORK/report.json" --gate "$WORK/zmgate.json" 2>"$WORK/zmerr")
ok "zeroMatch present, ok:true: no invocations, silent"  '[ "$(printf "%s" "$OUTZM" | jq -r ".runs[0].invocations // \"none\"")" = none ] && [ ! -s "$WORK/zmerr" ]'

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
