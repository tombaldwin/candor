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
# Exit 0 = clean · 1 = a policy violation, a newly-introduced effect, OR a fail-closed INCOMPLETE
# analysis (part of the target unread/unjudged — SPEC ⟨0.21⟩/⟨0.28⟩/⟨0.30⟩; a violation could be hiding
# in the unread part, so this blocks rather than being read as a safe-to-ignore setup error) · 2 = a
# genuine build/scan error (no usable report at all).
# (Refresh the baseline once a change is intended:  $CANDOR_CMD <classes> --json .candor/baseline.json)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
[ -f "$HERE/lib-candor-summary.sh" ] && . "$HERE/lib-candor-summary.sh"
command -v candor_emit_summary >/dev/null 2>&1 || candor_emit_summary() { :; }   # no-op if the lib is absent
command -v candor_log_activity >/dev/null 2>&1 || candor_log_activity() { :; }
CANDOR=${CANDOR_CMD:-jbang candor@tombaldwin/candor-java}
CLASSES=${CANDOR_CLASSES:-}
BASELINE=${CANDOR_REVIEW_BASELINE:-.candor/baseline.json}
[ -n "$CLASSES" ] || { echo "candor-review: set CANDOR_CLASSES to the compiled classes dir/jar"; exit 2; }

# mktemp portably (BSD/macOS `-t` treats the arg as a prefix, not a template, and an appended `.json` would
# point at a path mktemp never created → an orphaned temp every run). A bare mktemp + a trap is portable.
CUR=$(mktemp); SCANLOG=$(mktemp)
# `$CUR.callgraph.json` / `.hierarchy.json` sidecars are written beside the report — clean them too.
trap 'rm -f "$CUR" "$CUR".* "$SCANLOG"' EXIT
# One scan (the --json path needs no extension). If CANDOR_POLICY is set it gates inline → nonzero + an
# [AS-EFF-…] line on a violation.
$CANDOR "$CLASSES" --json "$CUR" >"$SCANLOG" 2>&1; gate=$?
[ -s "$CUR" ] || { echo "candor-review: scan produced no report — $(tail -1 "$SCANLOG")"; exit 2; }
# The CANDOR_SUMMARY trailer (Unknown count / effects / wall-time). Compute it ALWAYS so a self-logged
# record carries the rich fields, but PRINT it only when the caller asked (the hook sets CANDOR_EMIT_SUMMARY=1);
# a standalone human run shouldn't see the machine line.
SUMMARY=$(CANDOR_EMIT_SUMMARY=1 candor_emit_summary "$CUR")
[ "${CANDOR_EMIT_SUMMARY:-}" = "1" ] && [ -n "$SUMMARY" ] && printf '%s\n' "$SUMMARY"

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
# The graph-depth of the change (shared BFS in lib-candor-summary.sh) — see candor-review-source.sh.
if [ -n "$delta" ] && command -v candor_max_hops >/dev/null 2>&1; then
  H=$(candor_max_hops "$CUR" "$BASELINE" "$CUR.callgraph.json")
  [ -n "$H" ] && delta="$delta"$'\n'"  deepest propagation: $H hop(s) from the new source"
fi

# The REMEDY (integrations/FIX-SPEC.md): for each boundary crossing, the architectural fix — where the
# effect belongs + the hoist refactor — folded into the block message so the loop hands the agent the FIX,
# not just the finding. candor-java computes it (`fix-gate`) over the report + its callgraph sidecar; a
# graceful no-op when no policy is set. $CANDOR is the same engine that just scanned, so no extra install.
remedy=""
if [ "$gate" -ne 0 ] && grep -qE "AS-EFF" "$SCANLOG" && [ -n "${CANDOR_POLICY:-}" ]; then
  R=$($CANDOR fix-gate "$CUR" "$CANDOR_POLICY" 2>/dev/null)
  case "$R" in *"candor fix — "*) remedy="$R" ;; esac   # a real plan, not the "no crossings" / error line
fi

# One verdict, one exit — the human body is built into a variable so we can print it AND (when run
# standalone/CI, not via the hook) self-log the same record the hook would have written.
verdict_body() {   # echoes the human verdict; returns the exit code
  if [ "$gate" -ne 0 ]; then
    # Distinguish a real policy violation (an AS-EFF line) from a tool/build failure that also exits
    # nonzero — don't mislabel a crash/bad-classpath as an "architecture gate" failure.
    if grep -qE "AS-EFF" "$SCANLOG"; then
      echo "candor: ARCHITECTURE GATE FAILED — an edit reached a forbidden effect:"
      grep -E "AS-EFF" "$SCANLOG" | sed 's/^/  /'
      [ -n "$delta" ] && { echo "effects this change introduced:"; echo "$delta"; }
      [ -n "$remedy" ] && { echo; printf '%s\n' "$remedy"; }
      echo "fix: keep the effect out of that layer, or — if intended — update the policy / refresh the baseline."
      return 1
    fi
    # SPEC ⟨0.21⟩/⟨0.28⟩/⟨0.30⟩: an engine that COULD NOT fully judge the code (part unread/unanalyzed)
    # fails closed — exit 2, same as a genuine build/setup error, and prints no AS-EFF line either (that
    # code is reserved for a CERTAIN violation). Left unhandled, this fell into the branch below and the
    # hook ALLOWED the turn with a "setup error, not blocking" notice — a violation could be sitting
    # exactly in the part the engine admits it never read. Read the wire-pinned keys from the REPORT
    # ($CUR) itself, never scanlog prose (only the JSON keys are a spec contract): `incomplete`,
    # `unanalyzed` (files candor could not read), `judgedNothing` (dependency reports that judged
    # nothing).
    #
    # `excluded[].peeked`/`outOfScope` are checked DIRECTLY here too, not only through `incomplete` —
    # SPEC ⟨0.30⟩/⟨0.32⟩ bind those two keys to suppress the verdict IN THEIR OWN RIGHT, and reading only
    # the shared `incomplete` flag trusts every producer to also raise it alongside them. MEASURED against
    # this file pre-fix: a report carrying `excluded: [{"class": "…", "peeked": false}]` (or a non-empty
    # `outOfScope`) with NO top-level `incomplete` key fell straight through to the "build/scan error, not
    # a violation" branch below — the exact silent-pass shape this whole check exists to close, reached by
    # a spelling this check did not enumerate. `class` is engine-chosen vocabulary (SPEC §2 ⟨0.29⟩) and is
    # never used to decide anything below, only named in the message.
    #
    # A report with NONE of these — a genuine crash/misconfig, no partial analysis to trust — still falls
    # through to the setup-error branch below, unchanged.
    incomplete_info=""
    if command -v jq >/dev/null 2>&1 && [ -s "$CUR" ]; then
      incomplete_info=$(jq -r '
        ([(.excluded // [])[] | select((.peeked != true) and (.judgedElsewhere != true))]) as $unread
        | (.outOfScope // []) as $oos
        | if (.incomplete == true) or ((.unanalyzed // [])|length > 0) or ((.judgedNothing // [])|length > 0)
             or ($unread|length > 0) or ($oos|length > 0)
        then ( (if .incomplete == true then ["  incomplete: true"] else [] end)
               + ((.unanalyzed // []) | map("  unanalyzed: \(.path // .unit // "?") — \(.reason // .why // "no reason given")"))
               + (if (.judgedNothing // [])|length > 0 then ["  judgedNothing: \((.judgedNothing|length)) dependency report(s)"] else [] end)
               + ($unread | map("  excluded (unread): \(.class // "?") — \(.reason // "no reason given")"))
               + (if ($oos|length > 0) then ["  outOfScope: \($oos|length) function(s) outside the scan scope perform an effect this policy denies"] else [] end)
             ) | join("\n")
        else empty end' "$CUR" 2>/dev/null)
    fi
    if [ -n "$incomplete_info" ]; then
      echo "candor: ANALYSIS INCOMPLETE — part of the target was never read or judged, so a violation could be hiding there:"
      printf '%s\n' "$incomplete_info"
      echo "fix: make the unread/unanalyzed part legible to candor (fix the parse/build error, or narrow the scope deliberately), then re-run — this is not a safe-to-ignore setup error."
      return 1
    fi
    echo "candor-review: candor exited $gate with no policy finding — a build/scan error, not a violation:"
    tail -3 "$SCANLOG" | sed 's/^/  /'
    return 2
  fi
  if [ -n "$delta" ]; then
    echo "candor: this change introduced new effects (no policy violation):"
    echo "$delta"
    echo "review them; if intended, refresh the baseline."
    return 1
  fi
  echo "candor: no new effects vs baseline ✓"
  return 0
}
BODY=$(verdict_body); rc=$?
printf '%s\n' "$BODY"
# Self-log ONLY when a log is explicitly configured AND we're not under the hook (which logs itself,
# CANDOR_HOOK=1). A standalone/CI run has no transcript, so `edited` is null → the record is path-free.
if [ -n "${CANDOR_ACTIVITY_LOG:-}" ] && [ "${CANDOR_ACTIVITY_LOG:-}" != "off" ] && [ -z "${CANDOR_HOOK:-}" ]; then
  candor_log_activity "$rc" "$SUMMARY"$'\n'"$BODY"
fi
exit "$rc"
