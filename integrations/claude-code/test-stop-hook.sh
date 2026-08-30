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
  # CANDOR_HOOK_SKIP=0 by default here: every existing row asserts what the hook does when it RUNS the
  # review, and the skip guard would otherwise make the second clean row a no-op. The guard has its own
  # rows below, which turn it back on explicitly. CANDOR_HOOK_STAMP keeps the stamp inside $WORK — without
  # it the suite wrote `.candor/hook-stamp` into whatever directory it was run from.
  OUT=$(printf '%s' "$stdin" | MOCK_CASE="$mc" CANDOR_REVIEW="$MOCK" CANDOR_HOOK_NOTICE="$notice" \
        CANDOR_HOOK_SKIP="${SKIP_GUARD:-0}" CANDOR_HOOK_STAMP="$WORK/stamp" \
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
  | MOCK_CASE=clean CANDOR_REVIEW="$MOCK" CANDOR_HOOK_NOTICE=quiet CANDOR_ACTIVITY_LOG="$LOG" \
    CANDOR_HOOK_SKIP=0 CANDOR_HOOK_STAMP="$WORK/stamp" "$HOOK" >/dev/null 2>&1
ok "activity log appends one clean record"          '[ "$(jq -r .verdict "$LOG" 2>/dev/null)" = clean ]'
ok "activity log record is valid JSON"              'jq -e . "$LOG" >/dev/null 2>&1'

# ── P2: standalone / CI self-logging (candor-review.sh writes the SAME record shape when run outside the
#       hook, so "held the line in CI" is real). Uses a mock ENGINE (CANDOR_CMD), no network.
ENG="$WORK/mock-engine.sh"
cat > "$ENG" <<'ENGEOF'
#!/usr/bin/env bash
if [ "$1" = "diff" ]; then echo '{"changes":[]}'; exit 0; fi
out=""; while [ $# -gt 0 ]; do [ "$1" = "--json" ] && { out=$2; shift; }; shift; done
[ -n "$out" ] && printf '{"candor":{"version":"mock","spec":"0.8"},"functions":[{"fn":"a","inferred":["Log"]}]}' > "$out"
exit 0
ENGEOF
chmod +x "$ENG"
REV="$HERE/candor-review.sh"; CLS="$WORK/classes"; mkdir -p "$CLS"
SLOG="$LOGDIR/gate-log.jsonl"

: > "$SLOG"
CANDOR_CMD="bash $ENG" CANDOR_CLASSES="$CLS" CANDOR_REVIEW_BASELINE=/nonexistent CANDOR_ACTIVITY_LOG="$SLOG" "$REV" >/dev/null 2>&1
ok "review self-logs a record when run standalone with CANDOR_ACTIVITY_LOG"  '[ -s "$SLOG" ] && jq -e . "$SLOG" >/dev/null 2>&1'
ok "the standalone record is PATH-FREE (edited=null — committable/CI-safe)"  '[ "$(jq -r ".edited" "$SLOG" 2>/dev/null)" = null ]'
ok "the standalone record's verdict is clean (no baseline, no delta)"        '[ "$(jq -r ".verdict" "$SLOG" 2>/dev/null)" = clean ]'

: > "$SLOG"
CANDOR_HOOK=1 CANDOR_CMD="bash $ENG" CANDOR_CLASSES="$CLS" CANDOR_REVIEW_BASELINE=/nonexistent CANDOR_ACTIVITY_LOG="$SLOG" "$REV" >/dev/null 2>&1
ok "under the hook (CANDOR_HOOK=1) the review does NOT self-log (no double record)"  '[ ! -s "$SLOG" ]'

: > "$SLOG"
CANDOR_CMD="bash $ENG" CANDOR_CLASSES="$CLS" CANDOR_REVIEW_BASELINE=/nonexistent "$REV" >/dev/null 2>&1
ok "with no CANDOR_ACTIVITY_LOG set, the review writes nothing (opt-in)"      '[ ! -s "$SLOG" ]'

# ── FAIL-CLOSED INCOMPLETENESS (SPEC ⟨0.21⟩/⟨0.28⟩/⟨0.30⟩) must BLOCK, not read as a setup error ──
# candor-review.sh/-source.sh distinguish "a real policy violation" (an AS-EFF line) from "a build/setup
# error" (exit nonzero, no AS-EFF line) — and rc=2 is ALLOWED by the hook ("don't block on a misconfig").
# An engine that fails closed because it could not read/judge part of the target ALSO exits nonzero with
# no AS-EFF line (that code is reserved for a CERTAIN violation) — so before this fix it fell into the
# same "setup error, not blocking" bucket, and a violation could be sitting in exactly the part the
# engine admits it never analysed. The fix reads the WIRE-PINNED keys (`incomplete`/`unanalyzed`/
# `judgedNothing`) from the report the scan DID produce, not scanlog prose — a genuine crash produces no
# such report content and must stay allowed (the over-charge control below).
echo
echo "fail-closed incompleteness (⟨0.21⟩/⟨0.28⟩/⟨0.30⟩):"
INCENG="$WORK/mock-incomplete-engine.sh"
cat > "$INCENG" <<'INCEOF'
#!/usr/bin/env bash
# candor-review.sh (JVM) form: "<classes> --json <out>"
out=""; while [ $# -gt 0 ]; do [ "$1" = "--json" ] && { out=$2; shift; }; shift; done
[ -n "$out" ] && cat > "$out" <<JSON
{"candor":{"version":"mock","spec":"0.30"},"functions":[{"fn":"app.checkout","inferred":["Db"]}],
 "incomplete":true,"unanalyzed":[{"path":"src/Weird.java","reason":"malformed bytecode"}]}
JSON
echo "candor: internal note (not a certain violation)" >&2
exit 2
INCEOF
chmod +x "$INCENG"
OUT=$(CANDOR_CMD="bash $INCENG" CANDOR_CLASSES="$CLS" CANDOR_REVIEW_BASELINE=/nonexistent "$REV" 2>&1); rc=$?
ok "JVM review: an INCOMPLETE report BLOCKS (rc=1, not 2)"        '[ "$rc" = 1 ]'
ok "JVM review: names the incompleteness, not a generic crash"   'printf "%s" "$OUT" | grep -q "ANALYSIS INCOMPLETE"'
ok "JVM review: names the unanalyzed file + reason"              'printf "%s" "$OUT" | grep -q "Weird.java — malformed bytecode"'

INCSCAN="$WORK/mock-incomplete-scan.sh"
cat > "$INCSCAN" <<'INCEOF'
#!/usr/bin/env bash
# candor-review-source.sh form: "<src> --out <prefix>"
prefix="$3"
cat > "$prefix.json" <<JSON
{"candor":{"spec":"0.30"},"functions":[{"fn":"app.checkout","inferred":["Db"]}],
 "incomplete":true,"unanalyzed":[{"path":"src/weird.ts","reason":"parse error"}]}
JSON
echo "candor: internal note (not a certain violation)" >&2
exit 2
INCEOF
chmod +x "$INCSCAN"
SRCREV="$HERE/candor-review-source.sh"
OUT=$(CANDOR_SCAN="bash $INCSCAN" CANDOR_SRC="$WORK" CANDOR_REVIEW_BASELINE=/nonexistent "$SRCREV" 2>&1); rc=$?
ok "source review: an INCOMPLETE report BLOCKS (rc=1, not 2)"    '[ "$rc" = 1 ]'
ok "source review: names the unanalyzed file + reason"           'printf "%s" "$OUT" | grep -q "weird.ts — parse error"'

# end-to-end through the REAL hook (not the MOCK review): the block must actually reach the agent.
OUT=$(printf '{"session_id":"s1","hook_event_name":"Stop"}' \
  | CANDOR_REVIEW="$SRCREV" CANDOR_SCAN="bash $INCSCAN" CANDOR_SRC="$WORK" CANDOR_REVIEW_BASELINE=/nonexistent \
    CANDOR_HOOK_NOTICE=summary CANDOR_HOOK_SKIP=0 CANDOR_ACTIVITY_LOG=off "$HOOK" 2>/dev/null)
ok "…and the STOP HOOK blocks the turn over it (not a silent allow)" '[ "$(printf "%s" "$OUT" | jq -r .decision)" = block ]'

# OVER-CHARGE CONTROL: a genuine crash — no report content claims incompleteness — must stay rc=2/ALLOW.
# This is the case the rc=2 "don't block on a misconfig" contract exists for; the fix must not tax it.
CRASHENG="$WORK/mock-crash-engine.sh"
cat > "$CRASHENG" <<'CRASHEOF'
#!/usr/bin/env bash
out=""; while [ $# -gt 0 ]; do [ "$1" = "--json" ] && { out=$2; shift; }; shift; done
[ -n "$out" ] && printf '{"candor":{"version":"mock","spec":"0.30"},"functions":[{"fn":"a","inferred":["Log"]}]}' > "$out"
echo "candor: internal error: NullPointerException" >&2
exit 2
CRASHEOF
chmod +x "$CRASHENG"
OUT=$(CANDOR_CMD="bash $CRASHENG" CANDOR_CLASSES="$CLS" CANDOR_REVIEW_BASELINE=/nonexistent "$REV" 2>&1); rc=$?
ok "over-charge control: a genuine crash still ALLOWS (rc=2)"    '[ "$rc" = 2 ]'
ok "…and is NOT mislabeled as incomplete"                        '! printf "%s" "$OUT" | grep -q "ANALYSIS INCOMPLETE"'

# ── `excluded[].peeked`/`outOfScope` (SPEC ⟨0.30⟩/⟨0.32⟩) must ALSO block on their OWN, not only through
# the shared `incomplete` flag. MEASURED pre-fix: a report carrying one of these two keys with NO
# top-level `incomplete` fell through to "build/scan error, not a violation" (rc=2, ALLOWED) exactly like
# the genuine crash above — the same silent-pass shape the incomplete/unanalyzed fix closed, reached by a
# spelling that fix did not check. `excluded[].class` is engine-chosen (SPEC §2 ⟨0.29⟩) and must not
# matter — tested here under `widened-target`, an arbitrary unknown class token.
UNREADENG="$WORK/mock-unread-engine.sh"
cat > "$UNREADENG" <<'UNREADEOF'
#!/usr/bin/env bash
out=""; while [ $# -gt 0 ]; do [ "$1" = "--json" ] && { out=$2; shift; }; shift; done
[ -n "$out" ] && cat > "$out" <<JSON
{"candor":{"spec":"0.34"},"functions":[],
 "excluded":[{"class":"widened-target","count":2,"peeked":false,"reason":"widened dispatch target unread"}]}
JSON
exit 2
UNREADEOF
chmod +x "$UNREADENG"
OUT=$(CANDOR_CMD="bash $UNREADENG" CANDOR_CLASSES="$CLS" CANDOR_REVIEW_BASELINE=/nonexistent "$REV" 2>&1); rc=$?
ok "unread excluded class ALONE (no incomplete flag) BLOCKS (rc=1)" '[ "$rc" = 1 ]'
ok "…names the class, whatever it is called"                        'printf "%s" "$OUT" | grep -q "widened-target"'

# GAP 3 (2026-08-30 revert sweep): the row above only ever drove candor-review.sh ($REV). The
# excluded/outOfScope fix landed byte-identically in candor-review-source.sh too (6d91870's own message
# says so), and NOTHING in this file ever invoked $SRCREV with one of these three fixtures — a revert of
# the fix in candor-review-source.sh ALONE stayed green here. Same fixture, source-engine form (`<src>
# --out <prefix>` instead of `<classes> --json <out>`).
UNREADSCAN="$WORK/mock-unread-scan.sh"
cat > "$UNREADSCAN" <<'UNREADSCANEOF'
#!/usr/bin/env bash
prefix="$3"
cat > "$prefix.json" <<JSON
{"candor":{"spec":"0.34"},"functions":[],
 "excluded":[{"class":"widened-target","count":2,"peeked":false,"reason":"widened dispatch target unread"}]}
JSON
exit 2
UNREADSCANEOF
chmod +x "$UNREADSCAN"
OUT=$(CANDOR_SCAN="bash $UNREADSCAN" CANDOR_SRC="$WORK" CANDOR_REVIEW_BASELINE=/nonexistent "$SRCREV" 2>&1); rc=$?
ok "source review: unread excluded class ALONE (no incomplete flag) BLOCKS (rc=1)" '[ "$rc" = 1 ]'
ok "source review: …names the class, whatever it is called"                        'printf "%s" "$OUT" | grep -q "widened-target"'
# …and through the REAL hook, not the direct script — proving the plumbing (CANDOR_REVIEW=$SRCREV) blocks
# the turn over this shape, the same end-to-end check the incomplete/unanalyzed fix already got above.
OUT=$(printf '{"session_id":"s1","hook_event_name":"Stop"}' \
  | CANDOR_REVIEW="$SRCREV" CANDOR_SCAN="bash $UNREADSCAN" CANDOR_SRC="$WORK" CANDOR_REVIEW_BASELINE=/nonexistent \
    CANDOR_HOOK_NOTICE=summary CANDOR_HOOK_SKIP=0 CANDOR_ACTIVITY_LOG=off "$HOOK" 2>/dev/null)
ok "…and the STOP HOOK blocks the turn over an unread excluded class (not a silent allow)" '[ "$(printf "%s" "$OUT" | jq -r .decision)" = block ]'

# `outOfScope[].class` too is engine-chosen — `dispatch-widened` is the brand-new ⟨0.34⟩ token that landed
# in candor-swift/candor-java/candor-ts the same day this round started, and no consumer had seen it
# before this fix.
OOSENG="$WORK/mock-oos-engine.sh"
cat > "$OOSENG" <<'OOSEOF'
#!/usr/bin/env bash
out=""; while [ $# -gt 0 ]; do [ "$1" = "--json" ] && { out=$2; shift; }; shift; done
[ -n "$out" ] && cat > "$out" <<JSON
{"candor":{"spec":"0.34"},"functions":[{"fn":"app.checkout","inferred":["Db"]}],
 "outOfScope":[{"fn":"x.Deploy.run","path":"dist/shipped.js","effects":["Exec"],"class":"dispatch-widened"}]}
JSON
exit 2
OOSEOF
chmod +x "$OOSENG"
OUT=$(CANDOR_CMD="bash $OOSENG" CANDOR_CLASSES="$CLS" CANDOR_REVIEW_BASELINE=/nonexistent "$REV" 2>&1); rc=$?
ok "outOfScope ALONE (no incomplete flag) BLOCKS (rc=1)"            '[ "$rc" = 1 ]'
ok "…names outOfScope in the detail"                                 'printf "%s" "$OUT" | grep -q "outOfScope:"'

# GAP 3, source-engine mirror (see the note above the UNREADSCAN block).
OOSSCAN="$WORK/mock-oos-scan.sh"
cat > "$OOSSCAN" <<'OOSSCANEOF'
#!/usr/bin/env bash
prefix="$3"
cat > "$prefix.json" <<JSON
{"candor":{"spec":"0.34"},"functions":[{"fn":"app.checkout","inferred":["Db"]}],
 "outOfScope":[{"fn":"x.Deploy.run","path":"dist/shipped.js","effects":["Exec"],"class":"dispatch-widened"}]}
JSON
exit 2
OOSSCANEOF
chmod +x "$OOSSCAN"
OUT=$(CANDOR_SCAN="bash $OOSSCAN" CANDOR_SRC="$WORK" CANDOR_REVIEW_BASELINE=/nonexistent "$SRCREV" 2>&1); rc=$?
ok "source review: outOfScope ALONE (no incomplete flag) BLOCKS (rc=1)" '[ "$rc" = 1 ]'
ok "source review: …names outOfScope in the detail"                     'printf "%s" "$OUT" | grep -q "outOfScope:"'

# OVER-CHARGE CONTROL: a class the producer DID read (`judgedElsewhere`, e.g. a derived build-output copy)
# — even under the SAME unknown `widened-target` token — must stay clean. Proves the class name never
# decides anything; only the two booleans do.
PEEKEDENG="$WORK/mock-peeked-engine.sh"
cat > "$PEEKEDENG" <<'PEEKEDEOF'
#!/usr/bin/env bash
out=""; while [ $# -gt 0 ]; do [ "$1" = "--json" ] && { out=$2; shift; }; shift; done
[ -n "$out" ] && cat > "$out" <<JSON
{"candor":{"spec":"0.34"},"functions":[{"fn":"a","inferred":["Log"]}],
 "excluded":[{"class":"widened-target","count":2,"peeked":true,"judgedElsewhere":true,"reason":"already judged"}]}
JSON
exit 0
PEEKEDEOF
chmod +x "$PEEKEDENG"
OUT=$(CANDOR_CMD="bash $PEEKEDENG" CANDOR_CLASSES="$CLS" CANDOR_REVIEW_BASELINE=/nonexistent "$REV" 2>&1); rc=$?
ok "over-charge control: peeked+judgedElsewhere (same unknown class) stays clean (rc=0)" '[ "$rc" = 0 ]'
ok "…and is not flagged incomplete"                                  '! printf "%s" "$OUT" | grep -q "ANALYSIS INCOMPLETE"'

# GAP 3, source-engine mirror (see the note above the UNREADSCAN block) — the over-charge control too.
PEEKEDSCAN="$WORK/mock-peeked-scan.sh"
cat > "$PEEKEDSCAN" <<'PEEKEDSCANEOF'
#!/usr/bin/env bash
prefix="$3"
cat > "$prefix.json" <<JSON
{"candor":{"spec":"0.34"},"functions":[{"fn":"a","inferred":["Log"]}],
 "excluded":[{"class":"widened-target","count":2,"peeked":true,"judgedElsewhere":true,"reason":"already judged"}]}
JSON
exit 0
PEEKEDSCANEOF
chmod +x "$PEEKEDSCAN"
OUT=$(CANDOR_SCAN="bash $PEEKEDSCAN" CANDOR_SRC="$WORK" CANDOR_REVIEW_BASELINE=/nonexistent "$SRCREV" 2>&1); rc=$?
ok "source review over-charge control: peeked+judgedElsewhere (same unknown class) stays clean (rc=0)" '[ "$rc" = 0 ]'
ok "source review: …and is not flagged incomplete"                  '! printf "%s" "$OUT" | grep -q "ANALYSIS INCOMPLETE"'

# ── maxHops: the graph-depth of a change (FEEDBACK-SPEC's last deferred field, unlocked by the 0.11
#    surface machinery). A 2-hop chain (top → mid → leaf) where leaf gains Fs must print "deepest
#    propagation: 2 hop(s)" and land maxHops:2 in the self-logged record. Real candor-scan when
#    present; skipped (not failed) when the binary isn't built.
SCANBIN="$HERE/../../../candor-rust/target/debug/candor-scan"
if [ -x "$SCANBIN" ]; then
  MH="$WORK/mh"; mkdir -p "$MH/src" "$MH/.candor"
  printf '[package]\nname = "mh"\nversion = "0.0.0"\nedition = "2021"\n' > "$MH/Cargo.toml"
  printf 'pub fn top() -> u32 { mid() }\nfn mid() -> u32 { leaf() }\nfn leaf() -> u32 { 7 }\n' > "$MH/src/lib.rs"
  "$SCANBIN" "$MH" --out "$MH/.candor/base" >/dev/null 2>&1
  MHBASE=$(ls "$MH/.candor"/base*.json 2>/dev/null | grep -ve callgraph -e hierarchy | head -1)
  printf 'pub fn top() -> u32 { mid() }\nfn mid() -> u32 { leaf() }\nfn leaf() -> u32 { std::fs::read("/tmp/x").map(|v| v.len() as u32).unwrap_or(7) }\n' > "$MH/src/lib.rs"
  : > "$SLOG"
  OUT=$(CANDOR_SCAN="$SCANBIN" CANDOR_SRC="$MH" CANDOR_REVIEW_BASELINE="$MHBASE" CANDOR_ACTIVITY_LOG="$SLOG" "$HERE/candor-review-source.sh" 2>&1)
  ok "maxHops: the human delta names the propagation depth (2 hops)"  'printf "%s" "$OUT" | grep -q "deepest propagation: 2 hop"'
  ok "maxHops: the self-logged record carries maxHops=2"              '[ "$(jq -r ".maxHops" "$SLOG" 2>/dev/null)" = 2 ]'
  ok "maxHops: blastRadius still logged alongside (3 fns)"            '[ "$(jq -r ".blastRadius" "$SLOG" 2>/dev/null)" = 3 ]'
else
  echo "  skip maxHops fixture (candor-scan not built at $SCANBIN)"
fi

echo
# ── the SKIP GUARD (CANDOR_HOOK_SKIP) ──────────────────────────────────────────────────────────────
# The hook fires every turn and the scan dominates it (3.30s of 3.51s on a 2,259-class project), so a
# turn that changed nothing the verdict depends on must not pay for a rescan. What these rows lock is
# the SAFETY of that, not the speed: the guard may only skip after a run that PASSED, and any movement
# in an input must bring the review back. $SENTINEL records whether the review actually ran.
echo
echo "skip guard:"
SG_STAMP="$WORK/sg-stamp"; SG_TREE="$WORK/sg-tree"; SG_POL="$WORK/sg.policy"
mkdir -p "$SG_TREE"; echo 'x' > "$SG_TREE/a.class"; echo 'deny Net' > "$SG_POL"
sg_run() { # sg_run <MOCK_CASE> -> $OUT, sentinel reset first
  rm -f "$SENTINEL"
  OUT=$(printf '{"session_id":"s1","hook_event_name":"Stop"}' \
    | MOCK_CASE="$1" CANDOR_REVIEW="$MOCK" CANDOR_HOOK_NOTICE=summary CANDOR_ACTIVITY_LOG=off \
      CANDOR_HOOK_SKIP=1 CANDOR_HOOK_STAMP="$SG_STAMP" CANDOR_CLASSES="$SG_TREE" CANDOR_POLICY="$SG_POL" \
      "$HOOK" 2>/dev/null)
}
ran()     { [ -f "$SENTINEL" ]; }
sg_run clean
ok "first turn RUNS the review (no stamp yet)"                    'ran'
ok "…and a passing run writes the stamp"                          '[ -f "$SG_STAMP" ]'
sg_run clean
ok "an unchanged turn SKIPS the review entirely"                  '! ran'
ok "…and still emits valid JSON"                                  'valid_json'
ok "…and says so in summary mode"                                 'printf "%s" "$OUT" | jq -r .systemMessage | grep -q "skipped"'
sleep 1; echo 'y' >> "$SG_TREE/a.class"
sg_run clean
ok "a CHANGED input brings the review back"                       'ran'
sleep 1; echo 'deny Net Fs' > "$SG_POL"
sg_run clean
ok "…a changed POLICY does too (not just the analysed tree)"      'ran'
# THE SAFETY ROW: a failing gate must never stamp, or one violation would be skipped past forever.
# The tree is touched first because that is what a blocking turn looks like — the verdict changed
# BECAUSE something changed. (Without a change the guard skips, which is correct: nothing the verdict
# depends on moved, so the verdict cannot have moved either.)
sleep 1; echo 'z' >> "$SG_TREE/a.class"
sg_run policy
ok "a BLOCKING turn still blocks"                                 'printf "%s" "$OUT" | jq -e ".decision==\"block\"" >/dev/null'
sg_run policy
ok "…and a failing gate NEVER stamps, so the next turn re-runs it" 'ran'
sg_run clean
ok "…still re-running until a turn actually passes"               'ran'
ok "…and only THEN is the stamp refreshed (the next turn skips)"  'sg_run clean; ! ran'
# The engine identity is part of the signature: swapping the command must re-run even if no file moved.
sg_run clean
rm -f "$SENTINEL"
OUT=$(printf '{"session_id":"s1","hook_event_name":"Stop"}' \
  | MOCK_CASE=clean CANDOR_REVIEW="$MOCK" CANDOR_HOOK_NOTICE=summary CANDOR_ACTIVITY_LOG=off \
    CANDOR_HOOK_SKIP=1 CANDOR_HOOK_STAMP="$SG_STAMP" CANDOR_CLASSES="$SG_TREE" CANDOR_POLICY="$SG_POL" \
    CANDOR_CMD='java -jar other.jar' "$HOOK" 2>/dev/null)
ok "a changed ENGINE command re-runs even when no file moved"     'ran'
sg_run clean; rm -f "$SENTINEL"
OUT=$(printf '{"session_id":"s1","hook_event_name":"Stop"}' \
  | MOCK_CASE=clean CANDOR_REVIEW="$MOCK" CANDOR_HOOK_NOTICE=summary CANDOR_ACTIVITY_LOG=off \
    CANDOR_HOOK_SKIP=0 CANDOR_HOOK_STAMP="$SG_STAMP" CANDOR_CLASSES="$SG_TREE" "$HOOK" 2>/dev/null)
ok "CANDOR_HOOK_SKIP=0 disables the guard entirely"               'ran'

# ── the guard's WRONG-SKIP holes, all five found by review and all reproduced before they were closed ──
# Every row here is a case where the guard SKIPPED while a violation sat in the tree. None was covered by
# the rows above, which only ever tested an mtime-advancing edit with the tree env var set.
echo
echo "skip guard — wrong-skip holes:"
# (1) The tree not named at all. candor-review-source.sh defaults its root to `.`, and the README
#     documents that, so this was a legal wiring in which the guard watched NOTHING the engine reads —
#     and it never self-corrected, because no watched input ever moved again.
rm -f "$SENTINEL"; rm -f "$SG_STAMP"
OUT=$(printf '{"session_id":"s1","hook_event_name":"Stop"}' \
  | MOCK_CASE=clean CANDOR_REVIEW="$MOCK" CANDOR_HOOK_NOTICE=summary CANDOR_ACTIVITY_LOG=off \
    CANDOR_HOOK_SKIP=1 CANDOR_HOOK_STAMP="$SG_STAMP" "$HOOK" 2>/dev/null)
ok "with NO tree named (no CANDOR_CLASSES/CANDOR_SRC) the guard REFUSES to skip" 'ran'
# (2) A future-dated stamp switches `find -newer` off for every later edit, and a clock stepping back is
#     enough to cause it (NTP correction, a VM resume, an NFS server whose clock leads).
sg_run clean; touch -A '9999' "$SG_STAMP" 2>/dev/null || touch -d '+1 day' "$SG_STAMP" 2>/dev/null
sg_run clean
ok "a stamp dated in the FUTURE is refused (the -newer test would be dead)"      'ran'
# (3) The policy reached through `.candor/config` (SPEC §3.4) — the checked-in wiring the spec
#     recommends, in which CANDOR_POLICY is never set.
rm -rf "$WORK/cfgproj"; mkdir -p "$WORK/cfgproj/.candor" "$WORK/cfgproj/tree"
echo 'x' > "$WORK/cfgproj/tree/a.class"; echo 'deny Net' > "$WORK/cfgproj/.candor/gate.pol"
printf 'policy .candor/gate.pol\n' > "$WORK/cfgproj/.candor/config"
cfg_run() { rm -f "$SENTINEL"; ( cd "$WORK/cfgproj" && printf '{"session_id":"s1","hook_event_name":"Stop"}' \
  | MOCK_CASE=clean CANDOR_REVIEW="$MOCK" CANDOR_HOOK_NOTICE=quiet CANDOR_ACTIVITY_LOG=off \
    CANDOR_HOOK_SKIP=1 CANDOR_HOOK_STAMP=.candor/st CANDOR_CLASSES=tree "$HOOK" >/dev/null 2>&1 ); }
cfg_run; cfg_run
ok "…an unchanged config-wired project still skips (the guard is not just disabled)" '! ran'
sleep 1; echo 'deny Net Fs Db' > "$WORK/cfgproj/.candor/gate.pol"; cfg_run
ok "editing the policy NAMED BY .candor/config re-runs (CANDOR_POLICY unset)"    'ran'
sleep 1; printf 'policy .candor/gate.pol\nignore x\n' > "$WORK/cfgproj/.candor/config"; cfg_run
ok "…and editing .candor/config itself re-runs"                                  'ran'
# (4) Content that changes without changing size or mtime. Gradle's build cache restores outputs with
#     NORMALIZED CONSTANT timestamps by design, so this is a routine build, not a hostile one.
sg_run clean
sz_before=$(wc -c < "$SG_TREE/a.class")
ref=$(mktemp); touch -r "$SG_TREE/a.class" "$ref"
printf 'q' | dd of="$SG_TREE/a.class" bs=1 seek=0 conv=notrunc 2>/dev/null
touch -r "$ref" "$SG_TREE/a.class"; rm -f "$ref"
ok "the fixture really did keep its size"  "[ \"$sz_before\" = \"$(wc -c < "$SG_TREE/a.class")\" ]"
sg_run clean
ok "a same-SIZE, same-MTIME content change re-runs (a CRC, not du -sk)"          'ran'
# (5) `candor update` swaps the jar under an unchanged CANDOR_CMD string — a new engine detects new
#     things, which is a verdict change with nothing in the tree moving.
JARF="$WORK/engine.jar"; echo 'v1' > "$JARF"
je_run() { rm -f "$SENTINEL"; OUT=$(printf '{"session_id":"s1","hook_event_name":"Stop"}' \
  | MOCK_CASE=clean CANDOR_REVIEW="$MOCK" CANDOR_HOOK_NOTICE=quiet CANDOR_ACTIVITY_LOG=off \
    CANDOR_HOOK_SKIP=1 CANDOR_HOOK_STAMP="$WORK/je-stamp" CANDOR_CLASSES="$SG_TREE" \
    CANDOR_CMD="java -jar $JARF" "$HOOK" 2>/dev/null); }
je_run; je_run
ok "…an unchanged engine still skips"                                            '! ran'
sleep 1; echo 'v2-with-new-detections' > "$JARF"; je_run
ok "replacing the ENGINE JAR re-runs, though CANDOR_CMD is unchanged"            'ran' 

echo "test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
