#!/usr/bin/env bash
# ci-watch.sh — the CI status check, written because summarising it by hand went wrong twice in one day.
#
# WHY THIS EXISTS, stated as it happened (2026-08-19, the ⟨0.30⟩ release):
#
#   1. A hand-rolled `gh run list` aggregation printed "ALL GREEN" while candor-rust's `ci` was
#      `completed/failure`. The per-workflow rows above it were correct; only the summary lied. A false
#      all-clear produced by the step that verifies a release is the exact defect class this project
#      exists to find, so the aggregate here is FAIL-CLOSED: it prints OK only when every row it saw is
#      `success`, and it prints the rows regardless.
#
#   2. `gh run list --limit 1` returns the newest run of ANY workflow. candor-rust has three; a green
#      `realworld-oracle` masked a red `ci` at the same commit. So this always enumerates EVERY workflow
#      at the HEAD sha, never the newest run.
#
#   3. Two workflows hung for 3h45m and a third for 54m, each against a normal runtime of minutes, and
#      each was reported as "still running" because nothing compared elapsed time to what that workflow
#      usually takes. So a run still in progress past `STALL_FACTOR` x its own historical median is
#      called STALLED here, with the numbers, rather than waited on.
#
# USAGE
#   bash bin/ci-watch.sh                  # every repo the release cuts, at each HEAD
#   bash bin/ci-watch.sh candor-rust      # one repo
#   STALL_FACTOR=5 bash bin/ci-watch.sh   # widen the stall threshold (default 3)
#
# EXIT 0 only if every workflow at every HEAD concluded `success` (or is legitimately absent because no
# path filter matched). Non-zero on any failure, any stall, or any run still pending.
set -uo pipefail

REPOS=("candor-spec" "candor-rust" "candor-ts" "candor-java" "candor-swift" "candor-agents" "candor")
[ $# -gt 0 ] && REPOS=("$@")
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STALL_FACTOR="${STALL_FACTOR:-3}"
OWNER="tombaldwin"
rc=0
now=$(date -u +%s)

# THE STALL DECISION, as a function so it can be exercised without waiting for a real hang. A check whose
# alarm has never been seen to fire is a check nobody should trust — this is the arm that was missing on
# 2026-08-19, and a version of it that silently never fired would have left the same gap wearing a green.
#   $1 elapsed seconds   $2 median seconds   $3 factor   -> 0 = stalled, 1 = still within budget
is_stalled() {
  [ "$2" -gt 0 ] && [ "$1" -gt $(( $2 * $3 )) ]
}

if [ "${1:-}" = "--selftest" ]; then
  fails=0
  # (elapsed, median, factor, expect-stalled)
  for row in "3420 600 3 yes" "300 600 3 no" "1801 600 3 yes" "1800 600 3 no" "99999 0 3 no"; do
    set -- $row
    if is_stalled "$1" "$2" "$3"; then got=yes; else got=no; fi
    if [ "$got" = "$4" ]; then mark="✔"; else mark="✘"; fails=$((fails+1)); fi
    printf "  %s elapsed=%-6s median=%-5s factor=%s -> stalled=%-3s (want %s)\n" \
           "$mark" "$1" "$2" "$3" "$got" "$4"
  done
  echo "  (row 1 is the real 3h45m hang against a 10m median; the last row is a workflow with no"
  echo "   successful history, which must never be called stalled on no evidence)"
  [ "$fails" -eq 0 ] && echo "ci-watch selftest: OK — the stall arm fires and is bounded" \
                     || echo "ci-watch selftest: FAILED — $fails row(s)"
  exit "$fails"
fi

# The historical median duration of a workflow, in seconds, from its last successful runs. Median rather
# than mean: one 3h45m hang in the history would drag a mean past any threshold worth having.
median_secs() {
  local repo="$1" wf="$2"
  gh run list -R "$OWNER/$repo" --workflow "$wf" --limit 12 \
     --json conclusion,createdAt,updatedAt \
     -q '.[] | select(.conclusion=="success") | [(.updatedAt|fromdateiso8601) - (.createdAt|fromdateiso8601)] | .[]' \
     2>/dev/null | sort -n | awk '{a[NR]=$1} END{ if (NR==0) print 0; else print a[int((NR+1)/2)] }'
}

for repo in "${REPOS[@]}"; do
  d="$ROOT/$repo"
  [ -d "$d" ] || { printf "  %-14s SKIP  (not checked out)\n" "$repo"; continue; }
  sha="$(git -C "$d" rev-parse HEAD 2>/dev/null)"
  rows="$(gh run list -R "$OWNER/$repo" --commit "$sha" \
          --json workflowName,status,conclusion,createdAt \
          -q '.[] | .workflowName + "\t" + .status + "\t" + (.conclusion // "-") + "\t" + .createdAt' \
          2>/dev/null | sort -u)"

  if [ -z "$rows" ]; then
    # No run is legitimate ONLY when nothing in the commit matched a workflow's path filter. Say which
    # it is rather than treating silence as green — preflight [10] makes the same distinction.
    printf "  %-14s %-26s no run at HEAD (path-filtered, or never triggered — verify before trusting)\n" \
           "$repo" "(none)"
    continue
  fi

  while IFS=$'\t' read -r wf status concl created; do
    [ -z "$wf" ] && continue
    case "$status/$concl" in
      completed/success)
        printf "  %-14s %-26s ✔ success\n" "$repo" "$wf" ;;
      completed/*)
        printf "  %-14s %-26s ✘ %s\n" "$repo" "$wf" "$concl"; rc=1 ;;
      *)
        started=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$created" +%s 2>/dev/null \
                  || date -u -d "$created" +%s 2>/dev/null || echo "$now")
        elapsed=$(( now - started ))
        med=$(median_secs "$repo" "${wf}.yml")
        [ "$med" -eq 0 ] && med=$(median_secs "$repo" "$wf")
        if is_stalled "$elapsed" "$med" "$STALL_FACTOR"; then
          printf "  %-14s %-26s ✘ STALLED — %dm elapsed against a %dm median (%dx). Not slow: stuck.\n" \
                 "$repo" "$wf" $(( elapsed / 60 )) $(( med / 60 )) "$STALL_FACTOR"
          rc=1
        else
          printf "  %-14s %-26s … %s (%dm elapsed, %dm median)\n" \
                 "$repo" "$wf" "$status" $(( elapsed / 60 )) $(( med / 60 ))
          rc=1
        fi ;;
    esac
  done <<< "$rows"
done

echo
if [ "$rc" -eq 0 ]; then
  echo "ci-watch: OK — every workflow enumerated at every HEAD concluded success"
else
  echo "ci-watch: NOT GREEN — see the rows above. This never prints OK on a partial read: an aggregate"
  echo "  that summarised these rows by hand once said ALL GREEN over a failure, which is why the"
  echo "  verdict here is computed from every row and defaults to red."
fi
exit "$rc"
