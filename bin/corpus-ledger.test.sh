#!/usr/bin/env bash
# corpus-ledger.test.sh — calibration for the known-findings ledger in `bin/corpus.sh`.
#
# WHY A NEW CHECK SHIPS WITH ITS CALIBRATION, and why this one in particular. On 2026-09-25 an
# adversarial review found FIVE instrument defects written the same week, every one in the flattering
# direction: a bucketing rule that under-reported the shipping-defect list by 24 rows, its fix creating
# a false closure, a contradiction check that shipped VACUOUS because a heredoc ate a backslash, an
# advisory that reported "32 of 32 dead" because it looked nowhere, and a scope sentence that was false
# on the very case it was written for. Each compiled, ran, and printed something reassuring.
#
# The ledger this file calibrates SUPPRESSES output. That is the most dangerous kind of check to add to
# a suite whose subject is silent under-reporting, so it does not go in uncalibrated.
#
# THIS FILE'S OWN FIRST RUN FOUND TWO DEFECTS, which is the argument for it:
#   · the ledger's first entry cited **R543** — a row that is CLOSED. The finding is owned by R576.
#     Nothing but a check against the register would have caught a plausible, wrong row id.
#   · two of the assertions were VACUOUS: `out=$(finding …)` runs in a COMMAND SUBSTITUTION SUBSHELL,
#     so every counter increment was discarded and the "does not count" assertion passed for the wrong
#     reason. The counter is now driven in this shell, and the FINDING direction is asserted too — a
#     test that only checks the suppressing direction cannot tell a ledger from a `return 0`.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$HERE/bin/corpus.sh"
SPEC="${CANDOR_SPEC:-$(cd "$HERE/.." && pwd)/candor-spec}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Lift the ledger and `finding()` out of corpus.sh WITHOUT running a corpus round. Fail loudly if the
# extraction stops matching: a calibration that silently tests nothing is the thing it exists to prevent.
block="$(sed -n '/^findings=0$/,/^}$/p' "$SRC")"
# MATCH THE ASSIGNMENT, NOT THE NAME. The first version tested for the substring `KNOWN_FINDINGS`,
# which a RENAMED variable (`KNOWN_FINDINGS_RENAMED=`) still satisfies — so the guard passed on a
# corpus.sh with no ledger at all. It failed closed anyway, on the assertions below, but a guard that
# reads stronger than it is gets trusted for what it says rather than what it does.
case "$block" in
  *"KNOWN_FINDINGS='"*finding\(\)*) ;;
  *) echo "corpus-ledger.test: REFUSING — could not extract the ledger from bin/corpus.sh."
     echo "  The markers moved. A calibration that cannot find its subject must not report OK."; exit 2 ;;
esac
eval "$block"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %-46s %s\n' "$1" "$2"; pass=$((pass+1));
          else printf '  FAIL %-46s got=%s want=%s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

SERDE="honesty: rust.serde.serde.scan.json — ✗ de::Visitor::visit_char: reads certain but calls \`de::Visitor::visit_str\` which is Unknown"
SWIFT="honesty: swift.swift-argument-parser.swift-argument-parser.Swift.json — ✗ GenerateManual.generatePages: reads certain but calls \`MDocComponent.ast\` which is Unknown"

# 1 — the two live findings are recognised, and do NOT count.
# KNOWN_SEEN is written by the eval'd finding() and read by the staleness check, so it is
# ASSERTED below rather than silenced — shellcheck was right that nothing here read it, and
# the honest answer to "appears unused" in a calibration is to use it.
findings=0; known_hits=0; KNOWN_SEEN=""
finding "$SERDE" >"$TMP/o"
check "serde finding -> KNOWN R576"          "$(grep -c 'KNOWN (R576)' "$TMP/o")" "1"
finding "$SWIFT" >"$TMP/o"
check "swift finding -> KNOWN R578"          "$(grep -c 'KNOWN (R578)' "$TMP/o")" "1"
check "neither counts as a finding"          "$findings" "0"
check "both counted as known"                "$known_hits" "2"
# The ledger must RECORD which entries fired — the staleness check below reads exactly this.
check "both rows recorded as seen"           "$(echo "$KNOWN_SEEN" | tr -d ' ')" "R576R578"

# 2 — a NEW finding must still fail. Both near-misses matter: the two-field key is what stops a
#     DIFFERENT defect at a known symbol, or the known symbol in another project, being swallowed.
findings=0
finding "honesty: rust.serde.serde.scan.json — ✗ de::Visitor::visit_bytes: reads certain but calls something Unknown" >"$TMP/o"
check "new symbol, same project -> FINDING"  "$(grep -c 'FINDING:' "$TMP/o")" "1"
finding "honesty: rust.regex.regex.scan.json — ✗ de::Visitor::visit_char elsewhere" >"$TMP/o"
check "known symbol, other project -> FINDING" "$(grep -c 'FINDING:' "$TMP/o")" "1"
finding "chaining: 3 function(s) LOST an effect" >"$TMP/o"
check "unrelated oracle -> FINDING"          "$(grep -c 'FINDING:' "$TMP/o")" "1"
check "all three counted"                    "$findings" "3"

# 3 — THE XFAIL RULE: an entry that stops reproducing is a FAILURE, not a quiet win.
stale_for() {
  _s=""
  while IFS='|' read -r _r _a _b; do
    [ -n "$_r" ] || continue
    case " $1 " in *" $_r "*) ;; *) _s="$_s$_r" ;; esac
  done <<K
$KNOWN_FINDINGS
K
  echo "$_s"
}
check "one entry absent -> stale"            "$(stale_for ' R576 ')" "R578"
check "both absent -> both stale"            "$(stale_for ' ')" "R576R578"
check "both present -> not stale"            "$(stale_for ' R576  R578 ')" ""

# 4 — EVERY ENTRY MUST NAME A ROW THAT IS OPEN. The row is the entry's justification, not a
#     cross-reference: an entry citing a closed or absent row is itself the defect, and this is the
#     assertion that caught R543 on the first run.
if [ -f "$SPEC/scripts/soundness-status.py" ]; then
  ids="$(python3 "$SPEC/scripts/soundness-status.py" --ids 2>/dev/null | tr ' ' '\n' | grep -oE '^R[0-9]+' | sort -u)"
  [ -n "$ids" ] || { echo "  FAIL register produced no open ids"; fail=$((fail+1)); }
  while IFS='|' read -r r _a _b; do
    [ -n "$r" ] || continue
    check "entry $r names an OPEN register row"  "$(echo "$ids" | grep -cx "$r")" "1"
  done <<K
$KNOWN_FINDINGS
K
else
  # A CHECK THAT CANNOT RUN MUST NOT REPORT OK. This assertion is the one that caught a ledger entry
  # citing a CLOSED row on the first run; degrading it to a SKIP would quietly retire the only thing
  # standing between the ledger and a plausible, wrong row id.
  echo "corpus-ledger.test: REFUSING — no register at $SPEC, so entries cannot be checked against it."
  echo "  Set CANDOR_SPEC. A skipped cross-check is not a passed one."
  exit 2
fi

echo "corpus-ledger.test: $pass ok, $fail failed"
[ "$fail" -eq 0 ]
