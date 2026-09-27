#!/usr/bin/env bash
# policy-sweep.sh — run the reason-scoped `deny Unknown[...]` family over a roster of jars and emit a
# TSV one arm at a time.  SOUNDNESS R731.
#
#     bash bin/policy-sweep.sh <candor-java-all.jar> <out.tsv> [limit]
#
# WHY THIS EXISTS. A ruling asked for a printed check — *a jar whose `[X]` count equals
# `[X,unresolved]` minus `[unresolved]` in both arms, with `[dispatch,unresolved]` and bare
# `deny Unknown` unchanged, has lost nothing* — so that the next relabel needs no ruling for its
# fontbox.  No instrument in candor, candor-java or candor-spec mentioned `[reflect,unresolved]` or
# `[dispatch,unresolved]` at all: the six-policy sweeps behind SOUNDNESS R683, R712 and R716 were each
# written by their lane and thrown away.
#
# That is R288's shape one level up — the fifteen ad-hoc `ab.py` copies — a MEASUREMENT PROCEDURE with
# no owner, re-derived per lane, whose numbers the register quotes as if they came from an instrument.
# And it matters which way that cuts: those three sweeps agree with each other partly because each lane
# copied the previous lane's spelling, which is agreement between copies rather than confirmation.
#
# THE SWEEP IS HALF THE TOOL.  `bin/policy-sweep-check.py` reads two of these TSVs and prints the
# arithmetic.  They are separate on purpose: the sweep is the slow part and wants caching, the check is
# instant and wants iterating.  The sweep's output IS the input format the ruling had nowhere to live in.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="${1:-}"
OUT="${2:-}"
LIMIT="${3:-25}"
ROSTER="${POLICY_SWEEP_ROSTER:-$HERE/bin/corpus-census-java.tsv}"
CORPUS="${POLICY_SWEEP_CORPUS:-$HOME/.candor/census/java}"

if [ "${1:-}" != "--selftest" ]; then
[ -n "$ENGINE" ] && [ -n "$OUT" ] || {
  echo "usage: policy-sweep.sh <candor-java-all.jar> <out.tsv> [limit]   (or --selftest)"; exit 2; }
[ -f "$ENGINE" ] || { echo "policy-sweep: REFUSING — no engine jar at $ENGINE"; exit 2; }
[ -f "$ROSTER" ] || { echo "policy-sweep: REFUSING — no roster at $ROSTER"; exit 2; }
[ -d "$CORPUS" ] || { echo "policy-sweep: REFUSING — no corpus at $CORPUS. Run bin/corpus-census.sh java"; exit 2; }
if ! bash "$HERE/bin/disk-guard.sh" >/dev/null 2>&1; then
  echo "policy-sweep: REFUSING — disk-guard is unhappy. A full disk fakes an empty result and says neither."
  bash "$HERE/bin/disk-guard.sh"; exit 2
fi
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# THE SIX. The name is the TSV's policy column and `policy-sweep-check.py` keys on it verbatim.
#
# NOT an associative array: macOS ships bash 3.2 and `declare -A` is a bash-4 feature, so the first cut
# of this file died with "bare: unbound variable" on the box it is meant to run on. Parallel plain arrays
# work everywhere, and the selftest below checks they stay the same length — which is the failure mode a
# pair of parallel arrays actually has.
POLICY_NAMES=(bare reflect dispatch unresolved reflect_unresolved dispatch_unresolved)
POLICY_BODIES=(
  "deny Unknown"
  "deny Unknown[reflect]"
  "deny Unknown[dispatch]"
  "deny Unknown[unresolved]"
  "deny Unknown[reflect,unresolved]"
  "deny Unknown[dispatch,unresolved]"
)

if [ "${1:-}" = "--selftest" ]; then
  fail=0
  if [ "${#POLICY_NAMES[@]}" -ne "${#POLICY_BODIES[@]}" ]; then
    echo "  FAIL the two parallel arrays differ in length (${#POLICY_NAMES[@]} vs ${#POLICY_BODIES[@]})"
    echo "       — every policy after the mismatch would be recorded under the WRONG name"
    fail=1
  else
    echo "  ok   the parallel arrays are the same length (${#POLICY_NAMES[@]})"
  fi
  if [ "${#POLICY_NAMES[@]}" -ne 6 ]; then
    echo "  FAIL ${#POLICY_NAMES[@]} policies, want exactly 6 — the check keys on all six by name"; fail=1
  else
    echo "  ok   exactly six policies"
  fi
  # Every body must be a REASON-SCOPED deny the parser accepts, not a string that looks like one: an
  # unparseable policy exits 2, and an exit-2 run recorded as "0 violations" is a jar that lost
  # everything reported as a jar that lost nothing.
  i=0
  while [ "$i" -lt "${#POLICY_BODIES[@]}" ]; do
    case "${POLICY_BODIES[$i]}" in
      "deny Unknown"|"deny Unknown["*"]") ;;
      *) echo "  FAIL policy ${POLICY_NAMES[$i]} is not a deny-Unknown form: ${POLICY_BODIES[$i]}"; fail=1 ;;
    esac
    i=$((i + 1))
  done
  [ "$fail" -eq 0 ] && echo "  ok   every body is a bare or reason-scoped \`deny Unknown\`"
  echo "policy-sweep selftest: $([ "$fail" -eq 0 ] && echo OK || echo FAILED)"
  exit "$fail"
fi

i=0
while [ "$i" -lt "${#POLICY_NAMES[@]}" ]; do
  printf '%s\n' "${POLICY_BODIES[$i]}" > "$TMP/${POLICY_NAMES[$i]}.policy"
  i=$((i + 1))
done

printf 'jar\tpolicy\tviolations\texit\n' > "$OUT"
jars=0; runs=0; refused=0
while IFS=$'\t' read -r coord sha; do
  case "$coord" in ''|\#*) continue ;; esac
  [ "$jars" -ge "$LIMIT" ] && break
  rest="${coord#*:}"; a="${rest%%:*}"; v="${rest##*:}"
  f="$CORPUS/$a-$v.jar"
  [ -f "$f" ] || continue
  jars=$((jars + 1))
  # VERIFY THE JAR IS THE ONE THE ROSTER PINS. `corpus-census.sh` checks this at acquisition, but a sweep
  # runs long after and over whatever is on disk — and a sweep over a drifted or truncated jar is an
  # UNMEASURED jar reported as measured, which is the same failure as recording an exit-2 as 0. The
  # roster's sha1 column exists for exactly this; shellcheck noticing it was unused is what prompted
  # using it rather than silencing the warning.
  actual="$(shasum -a 1 "$f" 2>/dev/null | cut -d' ' -f1)"
  if [ -n "$sha" ] && [ "$actual" != "$sha" ]; then
    for k in "${POLICY_NAMES[@]}"; do
      printf '%s\t%s\tNA\t99\n' "$a-$v" "$k" >> "$OUT"
      refused=$((refused + 1)); runs=$((runs + 1))
    done
    echo "  SHA1 MISMATCH $a-$v — roster pins ${sha:0:12}, on disk ${actual:0:12}. Recorded NA, not swept."
    continue
  fi
  for k in "${POLICY_NAMES[@]}"; do
    java -jar "$ENGINE" "$f" --policy "$TMP/$k.policy" --gate-json "$TMP/g.json" >/dev/null 2>&1
    rc=$?
    n=""
    if [ -f "$TMP/g.json" ]; then
      n="$(python3 -c "
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    v=d.get('violations')
    print(len(v) if isinstance(v,list) else 0)
except Exception:
    print('')
" "$TMP/g.json" 2>/dev/null)"
    fi
    rm -f "$TMP/g.json"
    # A MISSING COUNT IS NOT ZERO. An unreadable policy or a refused scan exits 2, and recording that as
    # "0 violations" is how a sweep reports a jar that lost everything as a jar that lost nothing.
    if [ -z "$n" ]; then
      printf '%s\t%s\tNA\t%s\n' "$a-$v" "$k" "$rc" >> "$OUT"
      refused=$((refused + 1))
    else
      printf '%s\t%s\t%s\t%s\n' "$a-$v" "$k" "$n" "$rc" >> "$OUT"
    fi
    runs=$((runs + 1))
  done
done < "$ROSTER"

echo "policy-sweep: $jars jar(s) x 6 policies = $runs run(s) -> $OUT"
if [ "$refused" -gt 0 ]; then
  echo "  $refused run(s) produced NO COUNT and are recorded as NA, not as 0. A jar the engine refused"
  echo "  has not been measured, and the check treats NA as unmeasured rather than as 'lost nothing'."
fi
[ "$jars" -eq 0 ] && { echo "policy-sweep: REFUSING — 0 jars matched the roster under $CORPUS. An empty"; \
  echo "  sweep would print a clean arithmetic for nothing at all."; exit 2; }
exit 0
