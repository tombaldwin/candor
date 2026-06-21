#!/usr/bin/env bash
# candor-review — close the edit-time loop: scan the (already-built) classes, diff the effects vs a
# baseline report, and surface the GAINED effects + their transitive blast radius + any architecture-policy
# violation. This is the "delta back to the agent": after an edit, what new effects did it introduce, how
# far do they reach, and did they cross a boundary you forbade? Use it standalone (CI / manual) or via the
# Claude Code Stop hook (stop-hook.sh).
#
#   CANDOR_CLASSES   compiled classes dir or jar to scan            (REQUIRED)
#   CANDOR_REVIEW_BASELINE  the report to diff against (your last-known-good)  (default: .candor/baseline.json)
#   CANDOR_POLICY    an architecture policy file; a violation → exit 1  (optional — see ../../adopt/arch.policy)
#   CANDOR_CMD       the engine                                        (default: jbang candor@tombaldwin/candor-java)
#
# Exit 0 = clean · 1 = a policy violation OR a newly-introduced effect · 2 = setup error.
# (Refresh the baseline once a change is intended:  $CANDOR_CMD <classes> --json .candor/baseline.json)
set -uo pipefail
CANDOR=${CANDOR_CMD:-jbang candor@tombaldwin/candor-java}
CLASSES=${CANDOR_CLASSES:-}
BASELINE=${CANDOR_REVIEW_BASELINE:-.candor/baseline.json}
[ -n "$CLASSES" ] || { echo "candor-review: set CANDOR_CLASSES to the compiled classes dir/jar"; exit 2; }

# mktemp portably (BSD/macOS `-t` treats the arg as a prefix, not a template, and an appended `.json` would
# point at a path mktemp never created → an orphaned temp every run). A bare mktemp + a trap is portable.
CUR=$(mktemp); SCANLOG=$(mktemp)
trap 'rm -f "$CUR" "$SCANLOG"' EXIT
# One scan (the --json path needs no extension). If CANDOR_POLICY is set it gates inline → nonzero + an
# [AS-EFF-…] line on a violation.
$CANDOR "$CLASSES" --json "$CUR" >"$SCANLOG" 2>&1; gate=$?
[ -s "$CUR" ] || { echo "candor-review: scan produced no report — $(tail -1 "$SCANLOG")"; exit 2; }

# The delta vs the baseline: functions that INTRODUCED a new effect (the source) + the blast radius (every
# function that transitively gained an effect, introduced + inherited). candor's `diff` computes both.
delta=""
if [ ! -f "$BASELINE" ]; then
  echo "candor: no baseline at $BASELINE — can't review the effect DELTA (showing the policy gate only)."
  echo "  establish one from your last-known-good build:  ${CANDOR} <classes> --json $BASELINE"
elif true; then
  D=$($CANDOR diff "$CUR" "$BASELINE" --json 2>/dev/null)
  if [ -n "$D" ] && [ "$(printf '%s' "$D" | jq -r '[.changes[]?|select((.introduced|length)>0)]|length' 2>/dev/null || echo 0)" -gt 0 ]; then
    delta=$(printf '%s' "$D" | jq -r '
      ([.changes[]? | select((.introduced|length)>0) | "  • \(.fn) introduces {\(.introduced|join(", "))}"] | .[]),
      "  blast radius: \([.changes[]? | select((.gained|length)>0) | .fn] | length) function(s) transitively gained an effect"' 2>/dev/null)
  fi
fi

if [ "$gate" -ne 0 ]; then
  # Distinguish a real policy violation (an AS-EFF line) from a tool/build failure that also exits nonzero —
  # don't mislabel a crash/bad-classpath as an "architecture gate" failure.
  if grep -qE "AS-EFF" "$SCANLOG"; then
    echo "candor: ARCHITECTURE GATE FAILED — an edit reached a forbidden effect:"
    grep -E "AS-EFF" "$SCANLOG" | sed 's/^/  /'
    [ -n "$delta" ] && { echo "effects this change introduced:"; echo "$delta"; }
    echo "fix: keep the effect out of that layer, or — if intended — update the policy / refresh the baseline."
    exit 1
  fi
  echo "candor-review: candor exited $gate with no policy finding — a build/scan error, not a violation:"
  tail -3 "$SCANLOG" | sed 's/^/  /'
  exit 2
fi
if [ -n "$delta" ]; then
  echo "candor: this change introduced new effects (no policy violation):"
  echo "$delta"
  echo "review them; if intended, refresh the baseline."
  exit 1
fi
echo "candor: no new effects vs baseline ✓"
exit 0
