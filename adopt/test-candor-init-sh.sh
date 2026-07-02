#!/usr/bin/env bash
# Regression test for candor-init.sh — the one-command scaffolder. Locks the contract:
#   • scan → propose arch.policy (with pure/deny rules) + baseline + the GitHub Action, in one run;
#   • NEVER clobbers an existing arch.policy or workflow (writes arch.policy.proposed instead);
#   • fails with guidance when there's no scan target.
# Hermetic: CANDOR_SCAN_CMD points at a MOCK scanner that writes a canned report + callgraph — no engine.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
INIT="$HERE/candor-init.sh"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: needs python3"; exit 0; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# A mock scanner: `mock <target> --json <out>` writes a layered report (repo does Fs; pure domain via the
# callgraph) so the scaffolder has real structure to infer from. Mirrors a candor engine's --json output.
MOCK="$WORK/mock-scan"
cat > "$MOCK" <<'MOCK'
#!/usr/bin/env bash
out=""; while [ $# -gt 0 ]; do [ "$1" = "--json" ] && { out="$2"; shift; }; shift; done
[ -n "$out" ] || exit 1
cat > "$out" <<'JSON'
{"candor":{"spec":"0.8"},"functions":[{"fn":"com.shop.repo.Repo.save","inferred":["Fs"]}]}
JSON
cat > "${out%.json}.callgraph.json" <<'JSON'
{"com.shop.domain.Order.total":[],"com.shop.repo.Repo.save":[]}
JSON
MOCK
chmod +x "$MOCK"

pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1"; fi; }

# fresh project dir with a "classes" target present
PROJ="$WORK/proj"; mkdir -p "$PROJ/classes"; cd "$PROJ"
CANDOR_SCAN_CMD="$MOCK" bash "$INIT" classes >"$WORK/log" 2>&1; rc=$?

ok "exits 0 on a clean scaffold"                '[ "$rc" = 0 ]'
ok "writes arch.policy"                          '[ -f arch.policy ]'
ok "policy proposes pure for the pure layer"     'grep -qE "^pure com\.shop\.domain" arch.policy'
ok "policy proposes deny for the effect layer"   'grep -qE "^deny .* com\.shop\.repo" arch.policy'
ok "writes the ratchet baseline"                 '[ -f .candor/baseline.json ]'
ok "drops the GitHub Action"                     '[ -f .github/workflows/candor.yml ]'
ok "the Action is the candor gate"               'grep -q "candor architecture gate" .github/workflows/candor.yml'

# re-run: must NOT clobber the (hand-edited) arch.policy or the workflow.
echo "pure everything   # hand-edited" > arch.policy
CANDOR_SCAN_CMD="$MOCK" bash "$INIT" classes >/dev/null 2>&1
ok "re-run does NOT clobber arch.policy"          'grep -q "hand-edited" arch.policy'
ok "re-run writes arch.policy.proposed instead"   '[ -f arch.policy.proposed ] && grep -qE "^pure com\.shop\.domain" arch.policy.proposed'

# no scan target → fail with guidance (exit 2).
EMPTY="$WORK/empty"; mkdir -p "$EMPTY"; cd "$EMPTY"
CANDOR_SCAN_CMD="$MOCK" bash "$INIT" >"$WORK/log2" 2>&1; rc2=$?
ok "no target → exit 2"                           '[ "$rc2" = 2 ]'
ok "no target → guidance (build first)"           'grep -qi "build first\|no scan target" "$WORK/log2"'

echo
echo "test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
