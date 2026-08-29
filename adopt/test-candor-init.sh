#!/usr/bin/env bash
# Regression test for candor-init — the proposed-policy generator. Locks the contract:
#   • a fully-PURE layer (present only in the callgraph, no effects in the report) → `pure <layer>`;
#   • an effectful layer → `deny <boundary effects it does NOT reach> <layer>`, never denying what it HAS;
#   • pure-layer detection REQUIRES the callgraph (report omits pure fns) — no callgraph → deny-only + a note;
#   • the Rust `::` separator is handled;
#   • no clear layering → a helpful note, no bogus rules.
# Hermetic: inline fixture report + callgraph JSON; no engine.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
INIT="$HERE/candor-init"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: needs python3"; exit 0; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# report: only EFFECTFUL fns (repo does Fs, web reaches Fs). domain's pure fns are absent (as a real report).
cat > "$WORK/rep.json" <<'JSON'
{"candor":{"spec":"0.8"},"functions":[
  {"fn":"com.shop.repo.OrderRepo.save","inferred":["Fs"]},
  {"fn":"com.shop.web.OrderController.handle","inferred":["Fs"]}
]}
JSON
# callgraph: EVERY fn incl. the pure domain ones (§2.2) — this is what reveals the pure layer.
cat > "$WORK/rep.callgraph.json" <<'JSON'
{"com.shop.domain.Order.total":[],"com.shop.domain.Order.isLarge":[],
 "com.shop.repo.OrderRepo.save":[],"com.shop.web.OrderController.handle":["com.shop.repo.OrderRepo.save"]}
JSON

pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1"; fi; }

OUT=$(python3 "$INIT" "$WORK/rep.json" 2>/dev/null)
ok "pure layer → 'pure com.shop.domain'"        'printf "%s" "$OUT" | grep -qE "^pure com\.shop\.domain\b"'
ok "effectful layer → deny of what it lacks"    'printf "%s" "$OUT" | grep -qE "^deny .*Db.*Net.* com\.shop\.repo\b"'
ok "never denies the effect it HAS (Fs)"        '! printf "%s" "$OUT" | grep -E "^deny[^#]*\bFs\b[^#]* com\.shop\.(repo|web)"'
ok "web (reaches Fs via repo) is a deny layer"  'printf "%s" "$OUT" | grep -qE "^deny .* com\.shop\.web\b"'
ok "header says every rule currently passes"    'printf "%s" "$OUT" | grep -qi "currently PASSES"'

# without the callgraph: the pure layer can NOT be detected (report omits its fns) — deny-only + a note.
OUTNC=$(python3 "$INIT" "$WORK/rep.json" --callgraph /dev/null 2>"$WORK/err")
ok "no callgraph → no 'pure domain' proposal"   '! printf "%s" "$OUTNC" | grep -qE "^pure com\.shop\.domain"'
ok "no callgraph → still proposes deny rules"   'printf "%s" "$OUTNC" | grep -qE "^deny .* com\.shop\.repo"'

# Rust `::` separator.
cat > "$WORK/r2.json" <<'JSON'
{"candor":{"spec":"0.8"},"functions":[{"fn":"app::repo::save","inferred":["Fs"]}]}
JSON
cat > "$WORK/r2.callgraph.json" <<'JSON'
{"app::domain::total":[],"app::repo::save":[]}
JSON
OUT2=$(python3 "$INIT" "$WORK/r2.json" 2>/dev/null)
ok "Rust :: separator → 'pure app.domain'"      'printf "%s" "$OUT2" | grep -qE "^pure app\.domain\b"'

# no layering (all fns at one level) → a note, no rules.
cat > "$WORK/flat.json" <<'JSON'
{"candor":{"spec":"0.8"},"functions":[{"fn":"main.run","inferred":["Fs"]}]}
JSON
cat > "$WORK/flat.callgraph.json" <<'JSON'
{"main.run":[],"main.helper":[]}
JSON
OUTF=$(python3 "$INIT" "$WORK/flat.json" 2>/dev/null)
ok "no clear layering → a helpful note"         'printf "%s" "$OUTF" | grep -qi "no clear layering\|no sub-layers"'
ok "no clear layering → no bogus rules"         '! printf "%s" "$OUTF" | grep -qE "^(pure|deny) "'

# [max-review 11] a layer whose ONLY disclosure is Unknown must NOT be proposed `pure` — the scan-source
# engines flag Unknown under `pure` ("not certifiably pure"), so the rule would fail immediately.
cat > "$WORK/unk.json" <<'JSON'
{"candor":{"spec":"0.8"},"functions":[{"fn":"app.lib.Loader.load","inferred":["Unknown"]}]}
JSON
cat > "$WORK/unk.callgraph.json" <<'JSON'
{"app.lib.Loader.load":[],"app.domain.Order.total":[]}
JSON
OUTU=$(python3 "$INIT" "$WORK/unk.json" 2>/dev/null)
ok "Unknown-only layer gets NO pure rule"        '! printf "%s" "$OUTU" | grep -qE "^pure app\.lib\b"'
ok "Unknown-only layer skip is explained"        'printf "%s" "$OUTU" | grep -q "discloses Unknown"'
ok "the truly-pure sibling still gets pure"      'printf "%s" "$OUTU" | grep -qE "^pure app\.domain\b"'

# [max-review 12] §6.2 scope matching is last-segment-PREFIX: a rule for layer `api` also binds `apiv2`,
# so a prefix-colliding layer must be SKIPPED (with the reason), never proposed.
cat > "$WORK/pfx.json" <<'JSON'
{"candor":{"spec":"0.8"},"functions":[{"fn":"com.shop.apiv2.Client.fetch","inferred":["Net"]}]}
JSON
cat > "$WORK/pfx.callgraph.json" <<'JSON'
{"com.shop.api.Handler.route":[],"com.shop.apiv2.Client.fetch":[]}
JSON
OUTP=$(python3 "$INIT" "$WORK/pfx.json" 2>/dev/null)
ok "prefix-colliding layer gets NO rule"         '! printf "%s" "$OUTP" | grep -qE "^(pure|deny)[^#]* com\.shop\.api( |$)"'
ok "prefix collision is explained"               'printf "%s" "$OUTP" | grep -q "sibling layer"'
ok "the non-prefix sibling (apiv2) still ruled"  'printf "%s" "$OUTP" | grep -qE "^deny .* com\.shop\.apiv2\b"'

# SPEC ⟨0.21⟩/⟨0.28⟩/⟨0.30⟩/⟨0.32⟩: a report whose scan was INCOMPLETE must not have its `pure`/`deny`
# proposals presented as an unqualified "every rule currently passes" — the layer a `pure` rule locks in
# may reach an effect that lives in the unread part. Checked on `incomplete`/`unanalyzed`/`judgedNothing`
# AND directly on `excluded[].peeked`/`outOfScope`, not only the shared flag (a producer can raise one
# without the other). `excluded[].class` is engine-chosen (SPEC §2 ⟨0.29⟩) — exercised under the brand-new
# ⟨0.34⟩ `dispatch-widened` token to prove the class name never decides anything.
cat > "$WORK/increp.json" <<'JSON'
{"candor":{"spec":"0.30"},"functions":[{"fn":"com.shop.repo.OrderRepo.save","inferred":["Fs"]}],
 "incomplete":true,"unanalyzed":[{"path":"src/Weird.java","reason":"malformed bytecode"}]}
JSON
OUTINC=$(python3 "$INIT" "$WORK/increp.json" 2>"$WORK/incerr")
ok "incomplete report: caveat on stderr"          'grep -q "INCOMPLETE" "$WORK/incerr"'
ok "incomplete report: caveat names the file"     'grep -q "1 file(s) candor could not read" "$WORK/incerr"'
ok "incomplete report: caveat also in the header" 'printf "%s" "$OUTINC" | grep -q "INCOMPLETE"'

cat > "$WORK/excrep.json" <<'JSON'
{"candor":{"spec":"0.34"},"functions":[{"fn":"com.shop.repo.OrderRepo.save","inferred":["Fs"]}],
 "excluded":[{"class":"dispatch-widened","count":2,"peeked":false,"reason":"widened dispatch target unread"}]}
JSON
OUTEXC=$(python3 "$INIT" "$WORK/excrep.json" 2>"$WORK/excerr")
ok "unread excluded class ALONE (no incomplete flag) still caveats" 'grep -q "INCOMPLETE" "$WORK/excerr"'
ok "…names the class, whatever it is called"                        'grep -q "dispatch-widened" "$WORK/excerr"'

cat > "$WORK/oosrep.json" <<'JSON'
{"candor":{"spec":"0.33"},"functions":[{"fn":"com.shop.repo.OrderRepo.save","inferred":["Fs"]}],
 "outOfScope":[{"fn":"x.Deploy.run","effects":["Exec"],"class":"build-output"}]}
JSON
OUTOOS=$(python3 "$INIT" "$WORK/oosrep.json" 2>"$WORK/ooserr")
ok "outOfScope ALONE (no incomplete flag) still caveats"            'grep -q "INCOMPLETE" "$WORK/ooserr"'

# OVER-CHARGE CONTROLS: a class the producer DID read (`judgedElsewhere`, same unknown token) and the
# original clean fixture must both stay silent — no caveat anywhere.
cat > "$WORK/peekedrep.json" <<'JSON'
{"candor":{"spec":"0.34"},"functions":[{"fn":"com.shop.repo.OrderRepo.save","inferred":["Fs"]}],
 "excluded":[{"class":"dispatch-widened","count":2,"peeked":true,"judgedElsewhere":true,"reason":"already judged"}]}
JSON
OUTPK=$(python3 "$INIT" "$WORK/peekedrep.json" 2>"$WORK/pkerr")
ok "over-charge: peeked+judgedElsewhere (same unknown class) silent" '! grep -q "INCOMPLETE" "$WORK/pkerr" && ! printf "%s" "$OUTPK" | grep -q "INCOMPLETE"'
ok "over-charge: the original clean fixture stays silent"            '! printf "%s" "$OUT" | grep -q "INCOMPLETE"'

echo
echo "test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
