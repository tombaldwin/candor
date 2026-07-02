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

echo
echo "test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
