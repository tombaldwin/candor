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
# ── --wait: POLL UNTIL THE ANSWER EXISTS ───────────────────────────────────────────────────────────
# Without this every use of this script against a fresh push is: run it, see PENDING, run it again. That
# hand-polling is a real part of the "waiting more than working" cost, and it is the part a script can do.
#
# It re-execs itself rather than looping the body, so the waiting path and the snapshot path cannot drift
# — there is exactly one implementation of the verdict.
#
# On expiry it prints the last snapshot and exits 2. It must never turn "I got bored" into green: the
# deadline bounds how long this WAITS, not what it CONCLUDES.
if [ "${1:-}" = "--wait" ]; then
  WAIT_MAX="${CI_WATCH_WAIT_MAX:-1800}"
  deadline=$(( $(date +%s) + WAIT_MAX ))
  while :; do
    out="$("$0")"; st=$?
    if [ "$st" -ne 2 ]; then printf '%s\n' "$out"; exit "$st"; fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      printf '%s\n' "$out"
      echo "ci-watch: gave up WAITING after $(( WAIT_MAX / 60 ))m — still pending, and that is not green."
      exit 2
    fi
    sleep "${CI_WATCH_POLL:-20}"
  done
fi

rc=0
pending=0   # runs that have not concluded. Counted apart from rc so PENDING never reads as red.
now=$(date -u +%s)

# THE WIRE FORMAT between `gh` and the loop below. Fields are separated by a UNIT SEPARATOR, not a tab.
#
#   WHY, measured 2026-08-19 minutes after this script was written: `read` collapses consecutive IFS
#   *whitespace* delimiters, and tab is whitespace. A run that is in_progress carries conclusion "" — jq's
#   `//` does not replace an empty string, only null — so the row arrived as `ci<TAB>in_progress<TAB><TAB>
#   2026-…Z`, the two tabs collapsed into one, and `created` came out EMPTY. An empty date fails to parse,
#   the fallback set `started` to now, elapsed was ALWAYS 0, and the stall arm could not fire on any real
#   run. The `--selftest` passed throughout, because it exercised is_stalled() directly: a copy of the
#   instrument, not the instrument. Both halves are fixed here — a separator that cannot collapse AND a
#   conclusion that is never empty — and the selftest now drives the parse itself.
US=$'\037'
JQ_ROW='.[] | .workflowName + "\u001f" + .status + "\u001f" + (if (.conclusion // "") == "" then "-" else .conclusion end) + "\u001f" + .createdAt'

# THE STALL DECISION, as a function so it can be exercised without waiting for a real hang. A check whose
# alarm has never been seen to fire is a check nobody should trust — this is the arm that was missing on
# 2026-08-19, and a version of it that silently never fired would have left the same gap wearing a green.
#
# The threshold is `factor x median` OR `STALL_FLOOR`, WHICHEVER IS LARGER. The floor is not padding: the
# first thing this alarm ever did, once the parse was repaired, was call candor's `shell-lint` STALLED 55
# seconds in. Its median is 18s (measured: 16 16 16 17 17 17 18 18 22 62 77 100), so `3x median` is 54s,
# and a normal run trips it before the runner has finished installing shellcheck. A multiplier alone
# cannot express "stuck" for a job whose whole life is shorter than its own startup variance. 300s still
# fires on everything this exists for: the real 3h45m hang against a 10m median clears 30m by 7x.
#   $1 elapsed seconds   $2 median seconds   $3 factor   -> 0 = stalled, 1 = still within budget
STALL_FLOOR="${STALL_FLOOR:-300}"
is_stalled() {
  [ "$2" -gt 0 ] || return 1
  local threshold=$(( $2 * $3 ))
  [ "$threshold" -lt "$STALL_FLOOR" ] && threshold="$STALL_FLOOR"
  [ "$1" -gt "$threshold" ]
}

if [ "${1:-}" = "--selftest" ]; then
  fails=0
  # (elapsed, median, factor, expect-stalled)
  for row in "3420 600 3 yes" "300 600 3 no" "1801 600 3 yes" "1800 600 3 no" "99999 0 3 no" \
             "55 18 3 no" "400 18 3 yes" "301 100 3 yes" "300 100 3 no"; do
    set -- $row
    if is_stalled "$1" "$2" "$3"; then got=yes; else got=no; fi
    if [ "$got" = "$4" ]; then mark="✔"; else mark="✘"; fails=$((fails+1)); fi
    printf "  %s elapsed=%-6s median=%-5s factor=%s -> stalled=%-3s (want %s)\n" \
           "$mark" "$1" "$2" "$3" "$got" "$4"
  done
  echo "  (row 1 is the real 3h45m hang against a 10m median; row 5 is a workflow with no successful"
  echo "   history, which must never be called stalled on no evidence; row 6 is candor's shell-lint,"
  echo "   which this alarm's very first firing called STALLED at 55s against an 18s median — 3x a"
  echo "   short job is shorter than its own startup variance, which is what STALL_FLOOR=${STALL_FLOOR}s fixes,"
  echo "   and row 7 shows the same workflow genuinely stuck is still caught)"

  # THE ARM THAT WAS MISSING. The rows above exercise the decision; these exercise the PARSE that feeds
  # it, over the exact shape `gh` emits for a run that has not concluded. The first is what the query
  # used to produce (an empty conclusion field) and it is asserted to be UNREACHABLE now; the second is
  # what it produces today. An `elapsed` of 0 on a run started an hour ago is the failure, and it is a
  # SILENT one — every row still printed, the verdict was still red for the right reason, and the stall
  # line simply never appeared.
  echo
  for probe in "empty-conclusion in_progress" "dash-conclusion completed"; do
    set -- $probe
    case "$1" in
      empty-conclusion) row="wf${US}in_progress${US}${US}2026-08-19T19:00:00Z" ;;
      dash-conclusion)  row="wf${US}in_progress${US}-${US}2026-08-19T19:00:00Z" ;;
    esac
    IFS="$US" read -r p_wf p_status p_concl p_created <<< "$row"
    if [ "$p_created" = "2026-08-19T19:00:00Z" ]; then mark="✔"; else mark="✘"; fails=$((fails+1)); fi
    printf "  %s %-18s -> wf=%s status=%s concl=%q created=%q\n" \
           "$mark" "$1" "$p_wf" "$p_status" "$p_concl" "$p_created"
  done
  # And the query itself must never emit an empty conclusion field, whatever `read` would do with it.
  emitted=$(printf '%s' '[{"workflowName":"wf","status":"in_progress","conclusion":"","createdAt":"2026-08-19T19:00:00Z"}]' \
            | jq -r "$JQ_ROW" 2>/dev/null | tr "$US" "|")
  if [ "$emitted" = "wf|in_progress|-|2026-08-19T19:00:00Z" ]; then mark="✔"; else mark="✘"; fails=$((fails+1)); fi
  printf "  %s %-18s -> %s\n" "$mark" "jq empty concl" "$emitted"
  echo "  (an in_progress run has conclusion \"\", not null; jq's // leaves it, and tab-separated it"
  echo "   collapsed and shifted createdAt out of the row — elapsed was 0 for every run, always)"
  echo
  [ "$fails" -eq 0 ] && echo "ci-watch selftest: OK — the stall arm fires, is bounded, and its input parses" \
                     || echo "ci-watch selftest: FAILED — $fails row(s)"
  exit "$fails"
fi

# Durations under a minute printed as "0m" are why the false STALLED above read as nonsense ("0m elapsed
# against a 0m median") instead of as the short-job case it was. Say seconds when it is seconds.
dur() { if [ "$1" -lt 60 ]; then printf "%ds" "$1"; else printf "%dm" $(( $1 / 60 )); fi; }

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
          --json workflowName,status,conclusion,createdAt -q "$JQ_ROW" 2>/dev/null | sort -u)"

  # WHICH WORKFLOWS MUST HAVE RUN, asked of the workflow files rather than of GitHub. Until this existed
  # the script printed "no run at HEAD (path-filtered, or never triggered — verify before trusting)" and
  # then printed OK: honest in the row, fail-OPEN in the verdict, in the one script whose entire thesis is
  # that a summary must never be greener than its rows. The two readings it could not separate are "this
  # commit matched no path filter", which is fine, and "a workflow that should have run did not", which
  # blocks a release. wf-expected.py separates them from the declared triggers.
  required="$(python3 "$(dirname "${BASH_SOURCE[0]}")/wf-expected.py" "$d" HEAD 2>/dev/null \
              | awk -F'\t' '$2=="required"')"

  # FAULT HOOK, the pattern candor-spec's probe_check.py uses on the conformance generators: drop a row
  # that GitHub really returned and the REQUIRED-BUT-ABSENT arm below must go red. Without this the arm
  # is only ever exercised by the reader's selftest, which classifies triggers and never touches the
  # comparison — and an arm whose alarm has not been seen to fire is the defect this script was written
  # about, twice in one evening.
  if [ "${CI_WATCH_FAULT:-}" = "drop-row" ] && [ -n "$rows" ]; then
    echo "  (fault injected: dropping ${repo}'s first row — a REQUIRED BUT ABSENT line must follow)"
    rows="$(printf "%s\n" "$rows" | tail -n +2)"
  fi

  if [ -z "$rows" ]; then
    if [ -z "$required" ]; then
      printf "  %-14s %-26s ✔ no run expected (no changed file matches any workflow's push trigger)\n" \
             "$repo" "(none)"
    else
      printf "  %-14s %-26s ✘ NO RUN AT HEAD, and these were required:\n" "$repo" "(none)"
      printf "%s\n" "$required" | awk -F'\t' '{printf "      · %s — %s\n", $1, $3}'
      rc=1
    fi
    continue
  fi

  while IFS="$US" read -r wf status concl created; do
    [ -z "$wf" ] && continue
    case "$status/$concl" in
      completed/success)
        printf "  %-14s %-26s ✔ success\n" "$repo" "$wf" ;;
      completed/*)
        printf "  %-14s %-26s ✘ %s\n" "$repo" "$wf" "$concl"; rc=1 ;;
      *)
        # NOT `|| echo "$now"`. That fallback is what hid the bug above: it turned "I could not read the
        # start time" into "it started this instant", which reads as healthy and disarms the stall check.
        started=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$created" +%s 2>/dev/null \
                  || date -u -d "$created" +%s 2>/dev/null || echo "")
        if [ -z "$started" ]; then
          printf "  %-14s %-26s ✘ %s, start time UNREADABLE (%s) — the stall check cannot answer here\n" \
                 "$repo" "$wf" "$status" "${created:-empty}"
          rc=1; continue
        fi
        elapsed=$(( now - started ))
        med=$(median_secs "$repo" "${wf}.yml")
        [ "$med" -eq 0 ] && med=$(median_secs "$repo" "$wf")
        if is_stalled "$elapsed" "$med" "$STALL_FACTOR"; then
          printf "  %-14s %-26s ✘ STALLED — %s elapsed against a %s median. Not slow: stuck.\n" \
                 "$repo" "$wf" "$(dur "$elapsed")" "$(dur "$med")"
          rc=1
        else
          printf "  %-14s %-26s … %s (%s elapsed, %s median)\n" \
                 "$repo" "$wf" "$status" "$(dur "$elapsed")" "$(dur "$med")"
          pending=$((pending+1))
        fi ;;
    esac
  done <<< "$rows"

  # And the subtler half: rows exist, but not for every workflow that had to produce one. This is the
  # shape that let a green `realworld-oracle` stand in for a red `ci` — one row present is not the set.
  while IFS=$'\t' read -r req_wf _ req_why; do
    [ -z "$req_wf" ] && continue
    if ! printf "%s" "$rows" | grep -qF "$req_wf$US"; then
      printf "  %-14s %-26s ✘ REQUIRED BUT ABSENT — %s\n" "$repo" "$req_wf" "$req_why"
      rc=1
    fi
  done <<< "$required"
done

echo
if [ "$rc" -eq 0 ] && [ "$pending" -eq 0 ]; then
  echo "ci-watch: OK — every workflow enumerated at every HEAD concluded success"
elif [ "$rc" -eq 0 ]; then
  # PENDING IS NOT GREEN AND IS NOT RED. Collapsing it into red cost a manual re-run on every use — the
  # summary line for a healthy 4-second-old run was identical to the one for a failure. It gets its own
  # exit code so a caller writing `ci-watch || fail` still fails on it (2 is non-zero), while a caller
  # that wants to distinguish "not yet answered" from "answered badly" now can.
  echo "ci-watch: PENDING — $pending run(s) still going, none failed. Re-run, or use --wait."
  rc=2
else
  echo "ci-watch: NOT GREEN — see the rows above. This never prints OK on a partial read: an aggregate"
  echo "  that summarised these rows by hand once said ALL GREEN over a failure, which is why the"
  echo "  verdict here is computed from every row and defaults to red."
fi
exit "$rc"
