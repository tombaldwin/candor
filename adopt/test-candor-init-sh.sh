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
ok "writes .candor/config (policy + baseline)"   'grep -qE "^policy +arch.policy" .candor/config && grep -qE "^baseline" .candor/config'
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

# [max-review 13] a failing proposal STOPS the scaffold: exit 2, no Action dropped, no false "done".
BADMOCK="$WORK/bad-scan"
cat > "$BADMOCK" <<'MOCK'
#!/usr/bin/env bash
out=""; while [ $# -gt 0 ]; do [ "$1" = "--json" ] && { out="$2"; shift; }; shift; done
[ -n "$out" ] || exit 1
echo 'NOT JSON {' > "$out"     # the scan "succeeds" but the report is garbage → candor-init exits 2
MOCK
chmod +x "$BADMOCK"
BADP="$WORK/badproj"; mkdir -p "$BADP/classes"; cd "$BADP"
CANDOR_SCAN_CMD="$BADMOCK" bash "$INIT" classes >"$WORK/badlog" 2>&1; rcb=$?
ok "failed proposal → exit 2"                     '[ "$rcb" = 2 ]'
ok "failed proposal → NO Action dropped"          '[ ! -f .github/workflows/candor.yml ]'
ok "failed proposal → no false done message"      '! grep -q "candor init: done" "$WORK/badlog"'

# [max-review 14] an engine whose file output is `--out <prefix>` (ts/scan/swift — --json is a stdout
# boolean there) is detected via --help and used correctly; the prefix-named report is found by glob.
OUTMOCK="$WORK/out-scan"
cat > "$OUTMOCK" <<'MOCK'
#!/usr/bin/env bash
if [ "$1" = "--help" ]; then echo "usage: mock <dir> [--out <prefix>] [--json]"; exit 0; fi
out=""; while [ $# -gt 0 ]; do [ "$1" = "--out" ] && { out="$2"; shift; }; shift; done
[ -n "$out" ] || exit 1                     # --json <file> would NOT produce a report (the real ts/scan shape)
cat > "$out.mockpkg.scan.json" <<'JSON'
{"candor":{"spec":"0.8"},"functions":[{"fn":"com.shop.repo.Repo.save","inferred":["Fs"]}]}
JSON
cat > "$out.mockpkg.scan.callgraph.json" <<'JSON'
{"com.shop.domain.Order.total":[],"com.shop.repo.Repo.save":[]}
JSON
MOCK
chmod +x "$OUTMOCK"
OUTP="$WORK/outproj"; mkdir -p "$OUTP/classes"; cd "$OUTP"
CANDOR_SCAN_CMD="$OUTMOCK" bash "$INIT" classes >"$WORK/outlog" 2>&1; rco=$?
ok "--out engine detected via --help, scaffold ok" '[ "$rco" = 0 ] && [ -f arch.policy ]'
ok "--out engine: prefix-named report found"       'grep -qE "^pure com\.shop\.domain" arch.policy'

# PIN SKEW: with no CANDOR_SCAN_CMD, the init scan must run the EXACT candor-java release the dropped
# workflow pins (parsed from candor.yml's CANDOR_JAVA_VERSION) — a floating "latest" scan records a
# baseline the pinned, fail-closed Action rejects (exit 2) the moment a newer engine ships. Hermetic:
# a fake `java` on PATH records its argv and writes the canned report; the jar cache is pre-seeded so
# curl is never needed.
PINV=$(sed -nE 's/^[[:space:]]*CANDOR_JAVA_VERSION:[[:space:]]*"?([0-9A-Za-z.+-]+)"?.*$/\1/p' "$HERE/candor.yml" | head -1)
ok "candor.yml carries a parseable engine pin"     '[ -n "$PINV" ]'
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/java" <<'FAKE'
#!/usr/bin/env bash
echo "$@" >> "${JAVA_ARGLOG:?}"
out=""; while [ $# -gt 0 ]; do [ "$1" = "--json" ] && { out="$2"; shift; }; shift; done
[ -n "$out" ] || exit 0     # the --help probe
cat > "$out" <<'JSON'
{"candor":{"spec":"0.8"},"functions":[{"fn":"com.shop.repo.Repo.save","inferred":["Fs"]}]}
JSON
cat > "${out%.json}.callgraph.json" <<'JSON'
{"com.shop.domain.Order.total":[],"com.shop.repo.Repo.save":[]}
JSON
FAKE
chmod +x "$BIN/java"
CACHE="$WORK/jarcache"; mkdir -p "$CACHE"
echo "fake jar" > "$CACHE/candor-java-$PINV-all.jar"   # pre-seeded → no download attempted
PINP="$WORK/pinproj"; mkdir -p "$PINP/classes"; cd "$PINP"
JAVA_ARGLOG="$WORK/java-args" PATH="$BIN:$PATH" CANDOR_JAR_CACHE="$CACHE" bash "$INIT" classes >"$WORK/pinlog" 2>&1; rcp=$?
ok "pinned scan: scaffold succeeds"                '[ "$rcp" = 0 ] && [ -f arch.policy ] && [ -f .candor/baseline.json ]'
ok "pinned scan: runs the workflow's exact jar"    'grep -q -- "-jar $CACHE/candor-java-$PINV-all.jar" "$WORK/java-args"'
ok "pinned scan: says which pin it uses"           'grep -q "candor-java $PINV" "$WORK/pinlog" || grep -q "candor-java-$PINV" "$WORK/pinlog"'
# an EXISTING workflow in the repo wins over the adopt copy (a re-run must match what CI actually runs)
PINP2="$WORK/pinproj2"; mkdir -p "$PINP2/classes" "$PINP2/.github/workflows"; cd "$PINP2"
sed 's/CANDOR_JAVA_VERSION: .*/CANDOR_JAVA_VERSION: 9.9.9/' "$HERE/candor.yml" > .github/workflows/candor.yml
echo "fake jar" > "$CACHE/candor-java-9.9.9-all.jar"
JAVA_ARGLOG="$WORK/java-args2" PATH="$BIN:$PATH" CANDOR_JAR_CACHE="$CACHE" bash "$INIT" classes >/dev/null 2>&1
ok "existing workflow's pin wins over the adopt copy" 'grep -q "candor-java-9.9.9-all.jar" "$WORK/java-args2"'
# an unparseable pin is a clear STOP, not a silent fall-back to a floating engine.
BADHERE="$WORK/badhere"; mkdir -p "$BADHERE"
cp "$INIT" "$HERE/candor-init" "$BADHERE/"
grep -v 'CANDOR_JAVA_VERSION' "$HERE/candor.yml" > "$BADHERE/candor.yml"
NOPINP="$WORK/nopinproj"; mkdir -p "$NOPINP/classes"; cd "$NOPINP"
bash "$BADHERE/candor-init.sh" classes >"$WORK/nopinlog" 2>&1; rcnp=$?
ok "unparseable pin → exit 2"                      '[ "$rcnp" = 2 ]'
ok "unparseable pin → names the fix"               'grep -q "CANDOR_JAVA_VERSION" "$WORK/nopinlog" && grep -q "CANDOR_SCAN_CMD" "$WORK/nopinlog"'

# SARIF vendoring: skipped (partial checkout) → a clear WARNING, never a silent no-op.
ok "vendored SARIF reporter dropped when available" '[ -f "$WORK/proj/.candor/candor-sarif" ]'
cp "$HERE/candor.yml" "$BADHERE/candor.yml"   # restore the pin; badhere still has no ../integrations → vendor skip
VENDP="$WORK/vendproj"; mkdir -p "$VENDP/classes"; cd "$VENDP"
JAVA_ARGLOG="$WORK/java-args3" PATH="$BIN:$PATH" CANDOR_JAR_CACHE="$CACHE" bash "$BADHERE/candor-init.sh" classes >"$WORK/vendlog" 2>&1
ok "vendor skip → prints a WARNING"                'grep -q "WARNING" "$WORK/vendlog" && grep -qi "sarif" "$WORK/vendlog"'

# [max-review 15] a re-run must NOT clobber the ratchet baseline (that would grandfather every
# regression since adoption).
cd "$WORK/proj"
echo '{"marker":"original-baseline"}' > .candor/baseline.json
CANDOR_SCAN_CMD="$MOCK" bash "$INIT" classes >"$WORK/relog" 2>&1
ok "re-run leaves the existing baseline"           'grep -q "original-baseline" .candor/baseline.json'
ok "re-run says the baseline was left"             'grep -q "baseline.json already exists" "$WORK/relog"'
echo '# hand-edited' >> .candor/config
CANDOR_SCAN_CMD="$MOCK" bash "$INIT" classes >/dev/null 2>&1
ok "re-run does NOT clobber .candor/config"        'grep -q "hand-edited" .candor/config'

echo
echo "test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
