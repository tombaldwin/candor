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

# Machine-readable summary trailer for the stop hook (Unknown count, distinct effects, wall-time). Gated on
# CANDOR_EMIT_SUMMARY so standalone callers never see it; the hook sets the flag, reads the line, strips it.
if [ "${CANDOR_EMIT_SUMMARY:-}" = "1" ] && command -v jq >/dev/null 2>&1; then
  _unk=$(jq '[.functions[]?|select(((.inferred//[])|index("Unknown")))]|length' "$CUR" 2>/dev/null || echo 0)
  _eff=$(jq -c '[.functions[]?.inferred[]?]|unique|map(select(.!="Unknown"))' "$CUR" 2>/dev/null || echo '[]')
  printf 'CANDOR_SUMMARY {"unknowns":%s,"effects":%s,"reviewMs":%s}\n' "${_unk:-0}" "${_eff:-[]}" "$((SECONDS*1000))"
fi

# The delta vs the baseline, computed directly from the two spec-0.7 report files (engine-agnostic — the
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

if [ "$gate" -ne 0 ]; then
  # A real policy violation (an AS-EFF line) vs a tool/scan failure that also exits nonzero.
  if grep -qE "AS-EFF" "$SCANLOG"; then
    echo "candor: ARCHITECTURE GATE FAILED — an edit reached a forbidden effect:"
    grep -E "AS-EFF" "$SCANLOG" | sed 's/^/  /'
    [ -n "$delta" ] && { echo "effects this change introduced:"; echo "$delta"; }
    echo "fix: keep the effect out of that layer, or — if intended — update the policy / refresh the baseline."
    exit 1
  fi
  echo "candor-review-source: the scan exited $gate with no policy finding — a scan/setup error, not a violation:"
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
