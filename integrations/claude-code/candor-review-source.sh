#!/usr/bin/env bash
# candor-review-source — the edit-time loop for the SCAN-SOURCE engines (candor-ts / candor-swift /
# candor-scan). Same job as candor-review.sh (scan → diff the GAINED effects + their blast radius vs a
# baseline → surface any architecture-policy violation), but for engines that read SOURCE directly: there
# is NO build step (the Java loop builds classes once per turn; these don't), so this is strictly lighter.
#
#   CANDOR_SCAN     the analyze command for the engine                    (REQUIRED)
#                     ts:    "npx -y candor-ts"          swift: "candor-swift"      rust: "candor-scan"
#   CANDOR_SRC      the source dir to scan                                (default: .)
#   CANDOR_REVIEW_BASELINE  the report to diff against (last-known-good)   (default: .candor/baseline.json)
#   CANDOR_POLICY   an architecture policy file; a violation → exit 1      (optional — see ../../adopt/arch.policy)
#
# Exit 0 = clean · 1 = a policy violation OR a newly-introduced effect · 2 = setup error.
# (Refresh the baseline once a change is intended — copy the current report over it:
#    $CANDOR_SCAN <src> --out .candor/cur && cp "$(ls .candor/cur*.json|grep -ve callgraph -e hierarchy|head -1)" .candor/baseline.json)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
[ -f "$HERE/lib-candor-summary.sh" ] && . "$HERE/lib-candor-summary.sh"
command -v candor_emit_summary >/dev/null 2>&1 || candor_emit_summary() { :; }   # no-op if the lib is absent
command -v candor_log_activity >/dev/null 2>&1 || candor_log_activity() { :; }
SCAN=${CANDOR_SCAN:-}
SRC=${CANDOR_SRC:-.}
BASELINE=${CANDOR_REVIEW_BASELINE:-.candor/baseline.json}
[ -n "$SCAN" ] || { echo "candor-review-source: set CANDOR_SCAN to the engine (e.g. 'npx -y candor-ts' / candor-swift / candor-scan)"; exit 2; }

# Scan into a temp PREFIX (the scan-source engines write <prefix>.<pkg>.json + .callgraph/.hierarchy
# sidecars — naming varies per engine: ts `<prefix>.json`, swift `<prefix>.<pkg>.Swift.json`, scan
# `<prefix>.<member>.scan.json` — so glob the prefix and drop the sidecars). If CANDOR_POLICY is set the
# scan gates inline (every engine honours CANDOR_POLICY → nonzero + an [AS-EFF-…] line on a violation).
PREFIX=$(mktemp); SCANLOG=$(mktemp); rm -f "$PREFIX"   # mktemp makes a file; we want it as a prefix
trap 'rm -f "$PREFIX" "$SCANLOG" "$PREFIX"*' EXIT
$SCAN "$SRC" --out "$PREFIX" >"$SCANLOG" 2>&1; gate=$?
# Report filename varies per engine: ts `<prefix>.json`, swift `<prefix>.<pkg>.Swift.json`, scan
# `<prefix>.<member>.scan.json`. `<prefix>*.json` matches all; drop the .callgraph/.hierarchy sidecars.
CUR=$(ls "$PREFIX"*.json 2>/dev/null | grep -ve callgraph -e hierarchy | head -1)
[ -n "$CUR" ] && [ -s "$CUR" ] || { echo "candor-review-source: scan produced no report — $(tail -1 "$SCANLOG")"; exit 2; }
# CANDOR_SUMMARY trailer — computed always (so a self-logged record is rich), printed only when asked.
SUMMARY=$(CANDOR_EMIT_SUMMARY=1 candor_emit_summary "$CUR")
[ "${CANDOR_EMIT_SUMMARY:-}" = "1" ] && [ -n "$SUMMARY" ] && printf '%s\n' "$SUMMARY"

# The delta vs the baseline, computed directly from the two spec-0.8 report files (engine-agnostic — the
# envelope is standard, so no per-engine query CLI / prefix-vs-file quirks). INTRODUCERS = functions whose
# `direct` set gained an effect (the new sources); BLAST RADIUS = functions whose `inferred` (transitive)
# set gained one. Crucially this catches the dominant case — a function that was PURE (omitted from the
# baseline report) and is now effectful: base treats an absent fn as empty, so its new effects register.
delta=""
if [ ! -f "$BASELINE" ]; then
  echo "candor: no baseline at $BASELINE — can't review the effect DELTA (showing the policy gate only)."
  echo "  establish one from a known-good scan:  $SCAN $SRC --out .candor/base && cp \"\$(ls .candor/base*.json|grep -ve callgraph -e hierarchy|head -1)\" $BASELINE"
else
  delta=$(python3 - "$CUR" "$BASELINE" <<'PY' 2>/dev/null || true
import json, sys
def load(p):
    try: fns = json.load(open(p)).get("functions", [])
    except Exception: return {}, {}
    inf = {f["fn"]: set(f.get("inferred", [])) for f in fns}
    dir_ = {f["fn"]: set(f.get("direct", [])) for f in fns}
    return inf, dir_
cinf, cdir = load(sys.argv[1])
binf, bdir = load(sys.argv[2])
intro = [(fn, sorted(cdir[fn] - bdir.get(fn, set()))) for fn in cdir if cdir[fn] - bdir.get(fn, set())]
blast = [fn for fn in cinf if cinf[fn] - binf.get(fn, set())]
if intro or blast:
    for fn, g in sorted(intro): print(f"  • {fn} introduces {{{', '.join(g)}}}")
    print(f"  blast radius: {len(blast)} function(s) transitively gained an effect")
PY
)
fi
# The graph-depth of the change (shared BFS in lib-candor-summary.sh): how far the furthest gained
# effect sits from its source. Appended to the delta so the agent SEES the propagation depth, and
# parsed into the activity log's maxHops by candor_log_activity.
if [ -n "$delta" ] && command -v candor_max_hops >/dev/null 2>&1; then
  H=$(candor_max_hops "$CUR" "$BASELINE" "$PREFIX"*.callgraph.json)
  [ -n "$H" ] && delta="$delta"$'\n'"  deepest propagation: $H hop(s) from the new source"
fi

# The REMEDY (integrations/FIX-SPEC.md): for each boundary crossing, candor computes the architectural fix
# — where the effect belongs + the hoist refactor — so the loop hands the agent the FIX, not just the
# finding. Needs candor-query (the rust query engine, `fix-gate`); a graceful no-op when it's absent or can't
# read this engine's report shape (today: the candor-scan report; ts/swift/java remedies are FIX-SPEC P3).
remedy=""
QUERY=${CANDOR_QUERY:-candor-query}
if [ "$gate" -ne 0 ] && grep -qE "AS-EFF" "$SCANLOG" && [ -n "${CANDOR_POLICY:-}" ] && command -v "$QUERY" >/dev/null 2>&1; then
  R=$("$QUERY" fix-gate "$PREFIX" "$CANDOR_POLICY" 2>/dev/null)
  case "$R" in *"candor fix — "*) remedy="$R" ;; esac   # a real plan, not the "no crossings" / error line
fi

# One verdict, one exit — body captured so we can print it AND (standalone/CI, not under the hook) self-log.
verdict_body() {
  if [ "$gate" -ne 0 ]; then
    if grep -qE "AS-EFF" "$SCANLOG"; then
      echo "candor: ARCHITECTURE GATE FAILED — an edit reached a forbidden effect:"
      grep -E "AS-EFF" "$SCANLOG" | sed 's/^/  /'
      [ -n "$delta" ] && { echo "effects this change introduced:"; echo "$delta"; }
      [ -n "$remedy" ] && { echo; printf '%s\n' "$remedy"; }
      echo "fix: keep the effect out of that layer, or — if intended — update the policy / refresh the baseline."
      return 1
    fi
    echo "candor-review-source: the scan exited $gate with no policy finding — a scan/setup error, not a violation:"
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
if [ -n "${CANDOR_ACTIVITY_LOG:-}" ] && [ "${CANDOR_ACTIVITY_LOG:-}" != "off" ] && [ -z "${CANDOR_HOOK:-}" ]; then
  candor_log_activity "$rc" "$SUMMARY"$'\n'"$BODY"
fi
exit "$rc"
