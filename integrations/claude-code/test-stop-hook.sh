#!/usr/bin/env bash
# Regression test for stop-hook.sh — locks its OUTPUT CONTRACT, the thing Claude Code depends on:
#   • every path emits VALID JSON (a malformed block would fail-OPEN — the gate would silently not fire);
#   • a clean turn ALLOWS (no `.decision`) and shows a ✓ notice in summary / nothing in quiet|off;
#   • a block emits `{"decision":"block", reason, systemMessage}` and the user notice NAMES the cause
#     (the AS-EFF line or the `• fn introduces {E}` introducer — never a dangling "…introduced effects:");
#   • a setup error (rc=2) ALLOWS (doesn't block every turn) and still surfaces via JSON (stderr is invisible);
#   • stop_hook_active=true short-circuits to {} WITHOUT running the review (never loops).
# Hermetic: drives the hook with a MOCK review (no engine, no network) selected via CANDOR_REVIEW.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="$HERE/stop-hook.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: test needs jq"; exit 0; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
SENTINEL="$WORK/review-ran"

# A stand-in review: prints canned text for the requested case and exits with the matching code.
# MOCK_CASE=clean|neweffect|policy|setup ; touches $SENTINEL so we can assert whether the hook ran it.
MOCK="$WORK/mock-review.sh"
cat > "$MOCK" <<MOCK
#!/usr/bin/env bash
touch "$SENTINEL"
[ -n "\${CANDOR_EMIT_SUMMARY:-}" ] && echo 'CANDOR_SUMMARY {"unknowns":0,"effects":["Net"],"reviewMs":12}'
case "\${MOCK_CASE:-clean}" in
  clean)     echo 'candor: no new effects vs baseline ✓'; exit 0 ;;
  neweffect) echo 'candor: this change introduced new effects (no policy violation):'
             echo '  • svc.fetchThing introduces {Net}'
             echo '  blast radius: 1 function(s) transitively gained an effect'; exit 1 ;;
  policy)    echo 'candor: ARCHITECTURE GATE FAILED — an edit reached a forbidden effect:'
             echo '  [AS-EFF-006] \`svc.fetchThing\` performs { Net }, forbidden by policy: \`deny Net\`'; exit 1 ;;
  setup)     echo 'candor-review: scan produced no report'; exit 2 ;;
esac
MOCK
chmod +x "$MOCK"

pass=0; fail=0
run() { # run <MOCK_CASE> <NOTICE> [extra stdin json fields] -> stdout of hook, stored in $OUT
  local mc=$1 notice=$2 extra=${3:-'{}'}
  rm -f "$SENTINEL"
  local stdin; stdin=$(jq -nc --argjson e "$extra" '{session_id:"s1",hook_event_name:"Stop"} + $e')
  OUT=$(printf '%s' "$stdin" | MOCK_CASE="$mc" CANDOR_REVIEW="$MOCK" CANDOR_HOOK_NOTICE="$notice" \
        CANDOR_ACTIVITY_LOG=off "$HOOK" 2>/dev/null)
}
ok()  { if eval "$2"; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1"; echo "       out: $OUT"; fi; }
valid_json() { printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; }

echo "stop-hook contract:"

run clean summary
ok "clean/summary emits valid JSON"                 'valid_json'
ok "clean/summary ALLOWS (no decision)"             '[ "$(printf "%s" "$OUT" | jq -r ".decision // \"none\"")" = none ]'
ok "clean/summary shows the ✓ notice"               'printf "%s" "$OUT" | jq -e ".systemMessage | test(\"no new effects\")" >/dev/null'

run clean quiet
ok "clean/quiet is silent ({} only)"                '[ "$(printf "%s" "$OUT" | jq -c .)" = "{}" ]'
run clean off
ok "clean/off is silent ({} only)"                  '[ "$(printf "%s" "$OUT" | jq -c .)" = "{}" ]'

run neweffect summary
ok "new-effect emits valid JSON"                    'valid_json'
ok "new-effect BLOCKS"                               '[ "$(printf "%s" "$OUT" | jq -r .decision)" = block ]'
ok "new-effect reason carries the verdict"          'printf "%s" "$OUT" | jq -e ".reason | test(\"introduces .Net.\")" >/dev/null'
ok "new-effect notice NAMES the fn (not a stub)"    'printf "%s" "$OUT" | jq -e ".systemMessage | test(\"svc.fetchThing introduces\")" >/dev/null'
ok "new-effect notice does not dangle on a colon"   '[ "$(printf "%s" "$OUT" | jq -r .systemMessage | tail -c2)" != ": " ] && [ "$(printf "%s" "$OUT" | jq -r .systemMessage | grep -c ":$")" = 0 ]'

run policy summary
ok "policy block emits valid JSON"                  'valid_json'
ok "policy block BLOCKS"                             '[ "$(printf "%s" "$OUT" | jq -r .decision)" = block ]'
ok "policy notice surfaces the AS-EFF code"         'printf "%s" "$OUT" | jq -e ".systemMessage | test(\"AS-EFF-006\")" >/dev/null'

run policy quiet
ok "policy block still fires in quiet mode"         '[ "$(printf "%s" "$OUT" | jq -r .decision)" = block ]'
ok "policy quiet: no user systemMessage"            '[ "$(printf "%s" "$OUT" | jq -r ".systemMessage // \"none\"")" = none ]'

run setup summary
ok "setup (rc=2) emits valid JSON"                  'valid_json'
ok "setup ALLOWS (does not block on a misconfig)"   '[ "$(printf "%s" "$OUT" | jq -r ".decision // \"none\"")" = none ]'
ok "setup surfaces via systemMessage"               'printf "%s" "$OUT" | jq -e ".systemMessage | test(\"setup\")" >/dev/null'

# stop_hook_active=true must short-circuit to {} and NOT run the review (else it loops).
run clean summary '{"stop_hook_active":true}'
ok "active guard: emits {}"                         '[ "$(printf "%s" "$OUT" | jq -c .)" = "{}" ]'
ok "active guard: does NOT run the review"          '[ ! -f "$SENTINEL" ]'

# Activity log: a clean turn appends one record with verdict=clean to an EXISTING dir.
LOGDIR="$WORK/.candor"; mkdir -p "$LOGDIR"; LOG="$LOGDIR/activity.jsonl"
printf '%s' "$(jq -nc '{session_id:"s2",hook_event_name:"Stop"}')" \
  | MOCK_CASE=clean CANDOR_REVIEW="$MOCK" CANDOR_HOOK_NOTICE=quiet CANDOR_ACTIVITY_LOG="$LOG" "$HOOK" >/dev/null 2>&1
ok "activity log appends one clean record"          '[ "$(jq -r .verdict "$LOG" 2>/dev/null)" = clean ]'
ok "activity log record is valid JSON"              'jq -e . "$LOG" >/dev/null 2>&1'

echo
echo "test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
