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

# Flags are parsed BEFORE the repo list is built. Getting this order wrong (measured 2026-08-28) put the
# literal string `--wait` into REPOS as if it were a repo, and the re-exec below then dropped the repo
# list entirely — so `--wait candor-spec candor-rust` silently watched all seven and reported OK over a
# set the caller never asked for. A gate whose SCOPE can differ from its request is fail-open by shape.
WAIT=0
SELFTEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --wait)     WAIT=1; shift ;;
    --selftest) SELFTEST=1; shift ;;
    -*)     echo "ci-watch: unknown flag '$1'" >&2
            echo "usage: ci-watch.sh [--wait] [--selftest] [repo ...]" >&2; exit 64 ;;
    *)      break ;;
  esac
done

DEFAULT_REPOS=("candor-spec" "candor-rust" "candor-ts" "candor-java" "candor-swift" "candor-agents" "candor")
REPOS=("${DEFAULT_REPOS[@]}")
if [ $# -gt 0 ]; then
  # An argument that is not a known repo is a USAGE ERROR, never a silently-enumerated "repo" that then
  # contributes nothing to the verdict. Same reason as above: silence about a name we cannot check reads
  # as a pass. (candor-ux-pass: a bad argument is a usage error, and failures carry remedies.)
  for want in "$@"; do
    ok=0
    for known in "${DEFAULT_REPOS[@]}"; do [ "$want" = "$known" ] && ok=1 && break; done
    if [ "$ok" -eq 0 ]; then
      echo "ci-watch: '$want' is not a candor repo" >&2
      echo "  known: ${DEFAULT_REPOS[*]}" >&2
      exit 64
    fi
  done
  REPOS=("$@")
fi
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
if [ "$WAIT" -eq 1 ]; then
  WAIT_MAX="${CI_WATCH_WAIT_MAX:-1800}"
  deadline=$(( $(date +%s) + WAIT_MAX ))
  while :; do
    # Pass the repo list through. Re-execing bare here is what dropped it (2026-08-28).
    out="$("$0" "${REPOS[@]}")"; st=$?
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

# ── EVERY `gh` CALL IS CHECKED, NOT JUST READ ──────────────────────────────────────────────────────
# All three `gh run list` call sites below used to end in `2>/dev/null` and never looked at $?. `gh`
# failing (rate limit, network blip, an expired token) prints nothing to stdout — the IDENTICAL shape to
# "this workflow genuinely has no runs" or "no earlier run exists" — so a flake and a clean absence read
# as the same thing, and this script (whose whole header claims silence-read-as-pass was eliminated)
# reported OK over a call it never checked. (Adversarial re-review 2026-08-28, finding B3: a stub `gh`
# that failed ONLY the `--branch main` safety-net call still printed
# "ci-watch: OK — every workflow enumerated at every HEAD concluded success", exit 0. Reproduced again
# here before this fix, same output.)
#
# gh_call runs `gh "$@"`, leaves stdout in $GH_OUT and gh's real stderr (never discarded) in $GH_ERR, and
# returns gh's own exit status. Every call site checks that status explicitly and, on failure, prints a
# line naming the repo and the call and forces `rc=1` — a `gh` flake is now a red line, not a blank one.
gh_call() {
  local _err
  _err="$(mktemp "${TMPDIR:-/tmp}/ci-watch-gh.XXXXXX")"
  GH_OUT="$(gh "$@" 2>"$_err")"
  local _st=$?
  GH_ERR="$(cat "$_err")"       # command substitution strips trailing newlines cleanly
  GH_ERR="${GH_ERR//$'\n'/ }"   # collapse any embedded newlines into spaces for a one-line message
  rm -f "$_err"
  return "$_st"
}

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

# THIRD FALSE GREEN, a different external subprocess than the previous two (the argument-parsing bug at
# b8c53a6, the unchecked `gh` calls at 98fe7df): `python3 wf-expected.py "$d" HEAD 2>/dev/null` with $?
# never checked. On a DETACHED HEAD (a release worktree, a rebase in progress) `git rev-parse --abbrev-ref
# HEAD` inside the target repo answers the literal string "HEAD", which matches no `branches:` filter;
# wf-expected.py already refuses exactly that case — exit 2, an explanation on stderr, empty stdout —
# rather than guess. Discarding that stderr and never checking the exit code made an unanswered question
# read as "nothing is required": REQUIRED_BUT_ABSENT never fires, HEAD needs no run, `ci-watch: OK`.
# `verify-umbrella.sh` hit this identical shape and is the model (see its comment beside the same call):
# resolve the branch here rather than trust the callee's fallback, and never `2>/dev/null` a call whose
# only failure mode is one that makes it answer "nothing is required".
#
# A FUNCTION, DEFINED BEFORE --selftest BELOW, so the selftest exercises this exact code against a real
# throwaway detached repo — not a copy of the logic that could drift from it the way the stall alarm once
# sat broken under a selftest that only ever agreed with itself.
#
# Sets: required, wf_failed (0/1), wf_st, wf_branch, wf_branch_note, wf_errmsg. Globals, same convention
# as gh_call's GH_OUT/GH_ERR above — this file has no functions returning structured data another way.
resolve_required() {  # $1 = repo working dir   $2 = repo name (for the branch-note message only)
  local rd="$1" rname="$2" errfile out
  wf_branch="$(git -C "$rd" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  wf_branch_note=""
  if [ -z "$wf_branch" ] || [ "$wf_branch" = "HEAD" ]; then
    wf_branch="main"; wf_branch_note=" (assumed — $rname is on a detached HEAD)"
  fi
  errfile="$(mktemp "${TMPDIR:-/tmp}/ci-watch-wf.XXXXXX")"
  out="$(python3 "$(dirname "${BASH_SOURCE[0]}")/wf-expected.py" "$rd" HEAD "$wf_branch" 2>"$errfile")"
  wf_st=$?
  wf_errmsg="$(cat "$errfile")"; rm -f "$errfile"
  if [ "$wf_st" -ne 0 ]; then
    wf_failed=1
    required=""
  else
    wf_failed=0
    required="$(printf '%s' "$out" | awk -F'\t' '$2=="required"')"
  fi
}

# THE FOURTH CANDIDATE OF THE SAME SHAPE. The review that closed the third false green (above) flagged
# this rather than fixed it: `git rev-parse HEAD` (the sha fed to `--commit`), `2>/dev/null`, exit
# unchecked, filed as "INFERRED, not measured — if it fails, sha is empty". MEASURED before touching
# anything, and the real failure is worse than that guess:
#
#   - An unborn branch (a repo with no commits — every fresh `git init` is in this state, and so is a
#     checkout left behind by an interrupted clone or `git init`) is not a narrow case. On a non-bare
#     unborn branch, `git rev-parse HEAD` exits 128 (checkable) — but it ALSO writes the literal string
#     "HEAD" to stdout before erroring: git's own ambiguous-ref fallback echoes an unresolvable arg back
#     verbatim rather than emitting nothing. On a BARE repo with no commits it is worse still — measured
#     live, `git version 2.50.1 (Apple Git-155)`: exit 0, no stderr at all, stdout "HEAD". Checking `$?`
#     alone, the fix this same file already applies to every other subprocess, would not have caught
#     this one — the exit code says success.
#   - Fed to `gh run list --commit "$sha"`, an empty OR garbage sha is not rejected by `gh` either —
#     measured live against `tombaldwin/candor-rust`: `--commit ""` is silently treated as NO FILTER AT
#     ALL, exit 0, and returns the newest real runs across every commit in the repo's history — genuine,
#     green-looking rows attributed to a HEAD this script never actually resolved. (`--commit HEAD`, the
#     literal echoed string, happens to match no real run in that repo today; that is a fluke of no run
#     ever carrying that literal string as its sha, not a mechanism to rely on.)
#
# `--verify 'HEAD^{commit}'` closes this: it forces git to resolve HEAD to an actual commit OBJECT in
# the object database, not merely a ref string that happens to print something. Measured against every
# shape above plus two more adversarial ones — a `.git` file rewritten to point at a nonexistent gitdir,
# and a DANGLING ref (HEAD -> refs/heads/main -> a sha absent from the object database, where a bare
# `--verify HEAD` alone still resolves and returns that fake sha) — `--verify 'HEAD^{commit}'` is exit
# 128 with empty stdout in every one of them, and byte-identical (same sha, exit 0) on a healthy repo.
#
# A FUNCTION, DEFINED BEFORE --selftest BELOW, same convention as resolve_required(): the selftest
# exercises this exact code against real throwaway repos in each broken shape, not a copy of the logic.
resolve_sha() {  # $1 = repo working dir -> sets sha, sha_failed (0/1), sha_errmsg
  local rd="$1" errfile
  errfile="$(mktemp "${TMPDIR:-/tmp}/ci-watch-sha.XXXXXX")"
  sha="$(git -C "$rd" rev-parse --verify 'HEAD^{commit}' 2>"$errfile")"
  local st=$?
  sha_errmsg="$(cat "$errfile")"; rm -f "$errfile"
  if [ "$st" -ne 0 ] || [ -z "$sha" ]; then
    sha_failed=1
  else
    sha_failed=0
  fi
}

if [ "$SELFTEST" -eq 1 ]; then
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

  # THE gh WRAPPER. B3 (adversarial re-review, 2026-08-28): a `gh` that failed only the earlier-commit
  # safety-net call still printed "OK", exit 0, because that call's stderr was discarded and nothing
  # checked $?. Exercised here with a fake `gh` *function* — same reason the stall arm above is tested
  # against synthetic rows instead of a real hung workflow: an alarm untested by anything but itself is
  # not known to fire.
  echo
  gh() { echo "stub gh failure" >&2; return 7; }
  if gh_call run list -R fake/fake --commit deadbeef; then
    echo "  ✘ gh_call reported success against a gh that exited 7"; fails=$((fails+1))
  elif [ "$GH_ERR" != "stub gh failure" ]; then
    echo "  ✘ gh_call did not surface gh's stderr (got '$GH_ERR')"; fails=$((fails+1))
  else
    echo "  ✔ gh_call surfaces a nonzero gh exit and its real stderr, never silence"
  fi
  unset -f gh

  # THE THIRD FALSE GREEN: resolve_required() over a REAL throwaway repo checked out DETACHED — the exact
  # shape reported live (a release worktree, a rebase in progress), not a synthetic stand-in for it. Before
  # the fix, `python3 wf-expected.py "$d" HEAD 2>/dev/null` on this repo would exit 2 with empty stdout —
  # detached HEAD, no branch argument — and the discarded exit code let that read as "nothing required".
  echo
  _rrt="$(mktemp -d "${TMPDIR:-/tmp}/ci-watch-selftest.XXXXXX")"
  mkdir -p "$_rrt/.github/workflows"
  cat > "$_rrt/.github/workflows/ci.yml" <<'EOF'
name: ci
on:
  push:
    branches: [main]
    paths: ['**']
EOF
  git -C "$_rrt" init -q -b main >/dev/null 2>&1
  git -C "$_rrt" -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1
  git -C "$_rrt" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
  git -C "$_rrt" checkout -q --detach HEAD >/dev/null 2>&1
  resolve_required "$_rrt" "selftest-repo"
  if [ "$wf_failed" -eq 1 ]; then
    echo "  ✘ resolve_required treated a detached HEAD as an unanswerable failure instead of resolving main (wf_st=$wf_st, $wf_errmsg)"
    fails=$((fails+1))
  elif [ -z "$required" ]; then
    echo "  ✘ resolve_required found NOTHING required on a detached HEAD whose only workflow's push/branches/paths"
    echo "    all match — this is the exact false green: an unanswered branch question silently read as 'no'"
    fails=$((fails+1))
  else
    echo "  ✔ resolve_required resolves a detached HEAD to a branch (main) instead of asking wf-expected.py to"
    echo "    guess, and correctly finds \`ci\` required$wf_branch_note"
  fi
  rm -rf "$_rrt"

  # AND A GENUINE FAILURE — of wf-expected.py itself, for any reason, not just the branch question — must
  # still be a hard failure, never folded into an empty (so "nothing required") result. Same style as the
  # gh stub above: replace the external tool with a function so the failure is exercised, not assumed.
  python3() { echo "stub python3 crash" >&2; return 3; }
  resolve_required "/nonexistent-but-irrelevant" "selftest-repo"
  if [ "$wf_failed" -ne 1 ] || [ "$wf_st" != 3 ] || [ "$wf_errmsg" != "stub python3 crash" ] || [ -n "$required" ]; then
    echo "  ✘ resolve_required did not surface a wf-expected.py crash as a hard failure (wf_failed=$wf_failed wf_st=$wf_st wf_errmsg='$wf_errmsg' required='$required')"
    fails=$((fails+1))
  else
    echo "  ✔ resolve_required surfaces a nonzero wf-expected.py exit and its real stderr, never silence"
  fi
  unset -f python3

  # THE FOURTH CANDIDATE: resolve_sha() over REAL throwaway repos in each broken shape measured above —
  # not synthetic stand-ins for them, same reason every other arm in this selftest uses the real thing.
  echo
  _sha_ok="$(mktemp -d "${TMPDIR:-/tmp}/ci-watch-selftest.XXXXXX")"
  git -C "$_sha_ok" init -q -b main >/dev/null 2>&1
  git -C "$_sha_ok" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init >/dev/null 2>&1
  _want_sha="$(git -C "$_sha_ok" rev-parse HEAD)"
  resolve_sha "$_sha_ok"
  if [ "$sha_failed" -ne 0 ] || [ "$sha" != "$_want_sha" ]; then
    echo "  ✘ resolve_sha failed on a healthy repo with a real commit (sha_failed=$sha_failed sha='$sha' want='$_want_sha')"
    fails=$((fails+1))
  else
    echo "  ✔ resolve_sha resolves a healthy repo's HEAD to its real commit sha"
  fi
  rm -rf "$_sha_ok"

  _sha_unborn="$(mktemp -d "${TMPDIR:-/tmp}/ci-watch-selftest.XXXXXX")"
  git -C "$_sha_unborn" init -q -b main >/dev/null 2>&1
  resolve_sha "$_sha_unborn"
  if [ "$sha_failed" -ne 1 ]; then
    echo "  ✘ resolve_sha did not fail on an UNBORN branch (no commits) — a plain \`rev-parse HEAD\` here"
    echo "    exits 128 but still WRITES the literal string \"HEAD\" to stdout, which is exactly the shape"
    echo "    that fed a fabricated value into --commit"
    fails=$((fails+1))
  else
    echo "  ✔ resolve_sha fails closed on an unborn branch (no commits yet)"
  fi
  rm -rf "$_sha_unborn"

  _sha_bare="$(mktemp -d "${TMPDIR:-/tmp}/ci-watch-selftest.XXXXXX")"
  rm -rf "$_sha_bare"; git init -q --bare -b main "$_sha_bare" >/dev/null 2>&1
  resolve_sha "$_sha_bare"
  if [ "$sha_failed" -ne 1 ]; then
    echo "  ✘ resolve_sha did not fail on a BARE repo with no commits — measured live: a plain \`rev-parse"
    echo "    HEAD\` here exits 0 (a clean exit, not just wrong output) and prints \"HEAD\" as if it were a"
    echo "    real sha. \$? alone would have missed this one; --verify HEAD^{commit} is what closes it."
    fails=$((fails+1))
  else
    echo "  ✔ resolve_sha fails closed on a bare repo with no commits (a plain rev-parse exits 0 there)"
  fi
  rm -rf "$_sha_bare"

  resolve_sha "/nonexistent-not-a-repo-$$"
  if [ "$sha_failed" -ne 1 ]; then
    echo "  ✘ resolve_sha did not fail on a path that is not a git repository at all"
    fails=$((fails+1))
  else
    echo "  ✔ resolve_sha fails closed on a path that is not a git repository"
  fi

  echo
  [ "$fails" -eq 0 ] && echo "ci-watch selftest: OK — the stall arm fires, is bounded, its input parses, a gh failure is never silent, neither is a wf-expected.py one, and neither is a HEAD git cannot resolve" \
                     || echo "ci-watch selftest: FAILED — $fails row(s)"
  exit "$fails"
fi

# Durations under a minute printed as "0m" are why the false STALLED above read as nonsense ("0m elapsed
# against a 0m median") instead of as the short-job case it was. Say seconds when it is seconds.
dur() { if [ "$1" -lt 60 ]; then printf "%ds" "$1"; else printf "%dm" $(( $1 / 60 )); fi; }

# The historical median duration of a workflow, in seconds, from its last successful runs. Median rather
# than mean: one 3h45m hang in the history would drag a mean past any threshold worth having.
#
# On a `gh` failure this prints "FAIL:<message>" rather than folding the failure into "0" silently — "0"
# already means something real here (a workflow with no successful history yet, row 5 of the selftest
# above, which must never be called stalled). Collapsing a `gh` flake into that same 0 would have made an
# API blip indistinguishable from "no evidence" and silently disarmed the stall check for exactly the run
# it exists to catch. NOT a global flag: every call site here runs this inside `$(...)`, which forks a
# subshell, and a variable this function set would never reach the caller — it has to ride back in the
# one channel that does, the captured stdout.
median_secs() {
  local repo="$1" wf="$2"
  if gh_call run list -R "$OWNER/$repo" --workflow "$wf" --limit 12 \
             --json conclusion,createdAt,updatedAt \
             -q '.[] | select(.conclusion=="success") | [(.updatedAt|fromdateiso8601) - (.createdAt|fromdateiso8601)] | .[]'; then
    printf '%s' "$GH_OUT" | sort -n | awk '{a[NR]=$1} END{ if (NR==0) print 0; else print a[int((NR+1)/2)] }'
  else
    printf 'FAIL:%s' "$GH_ERR"
  fi
}

for repo in "${REPOS[@]}"; do
  d="$ROOT/$repo"
  [ -d "$d" ] || { printf "  %-14s SKIP  (not checked out)\n" "$repo"; continue; }
  resolve_sha "$d"
  if [ "$sha_failed" -eq 1 ]; then
    # Named and red, never folded into "no run expected" or any other clean-looking branch below — see
    # resolve_sha() above for what this closes (a bare or unborn repo can make a bare `rev-parse HEAD`
    # print "HEAD" with exit 0) and why checking $? on a plain rev-parse would not have been enough.
    printf "  %-14s %-26s ✘ git rev-parse FAILED (cannot resolve HEAD to a commit) — %s\n" "$repo" "(git)" \
           "${sha_errmsg:-no stderr captured}"
    rc=1
    continue
  fi
  # ONE ROW PER WORKFLOW: THE NEWEST. `gh run list --commit` returns EVERY run at that sha, and a
  # workflow with a concurrency group leaves superseded ones behind — a re-run, or a `workflow_dispatch`
  # firing while another is queued, cancels the older and both come back. The cancelled one then reads as
  # a hard failure and this script stays RED at that HEAD for ever, however many green runs follow.
  #
  # MEASURED: re-running candor-spec's conformance after a cross-repo ordering fix left `✘ cancelled`
  # beside `… in_progress`, and `--wait` returned immediately because a red row does not wait. The old
  # `sort -u` made it worse: it sorted rows ALPHABETICALLY, so which duplicate survived was arbitrary.
  #
  # A superseded run is not evidence about anything — the newest run of a workflow at a commit is the
  # only one whose answer is about that commit. `gh` returns newest-first, so the first row per workflow
  # name wins; `awk` keeps insertion order rather than re-sorting.
  if gh_call run list -R "$OWNER/$repo" --commit "$sha" \
             --json workflowName,status,conclusion,createdAt -q "$JQ_ROW"; then
    rows="$(printf '%s' "$GH_OUT" | awk -F"$US" '!seen[$1]++')"
  else
    # A failed call here is not "no runs at HEAD" — it is "HEAD was never checked". Reporting the former
    # over the latter is exactly B3 (adversarial re-review, 2026-08-28): this repo cannot be judged, so it
    # is named as failed and skipped rather than falling into the "no run expected ✔" branch below, which
    # would otherwise print a green line over a call that never ran.
    printf "  %-14s %-26s ✘ gh FAILED (run list --commit) — %s\n" "$repo" "(gh)" \
           "${GH_ERR:-no stderr captured}"
    rc=1
    continue
  fi

  # WHICH WORKFLOWS MUST HAVE RUN, asked of the workflow files rather than of GitHub via resolve_required()
  # (defined above with gh_call and median_secs — see it for the full defect history). Until that existed
  # the script printed "no run at HEAD (path-filtered, or never triggered — verify before trusting)" and
  # then printed OK: honest in the row, fail-OPEN in the verdict, in the one script whose entire thesis is
  # that a summary must never be greener than its rows.
  resolve_required "$d" "$repo"
  if [ "$wf_failed" -eq 1 ]; then
    printf "  %-14s %-26s ✘ wf-expected.py FAILED (exit %s)%s — %s\n" "$repo" "(wf-expected)" "$wf_st" \
           "$wf_branch_note" "${wf_errmsg:-no stderr captured} — cannot tell what CI must run here"
    rc=1
  fi

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
    if [ "$wf_failed" -eq 1 ]; then
      : # already reported above — do not ALSO claim "no run expected" over a question that was never
        # answered; that second, contradictory line is exactly how this defect read as green.
    elif [ -z "$required" ]; then
      printf "  %-14s %-26s ✔ no run expected (no changed file matches any workflow's push trigger)\n" \
             "$repo" "(none)"
    else
      # ⟨2026-08-21⟩ A RUN CANNOT BE MISSING BEFORE GITHUB HAS HAD TIME TO CREATE IT. Immediately after a
      # push there is a window — seconds — where the commit is on the remote and no run exists yet. This
      # branch called that "NO RUN AT HEAD", a hard failure, so `--wait` returned instead of waiting and
      # the summary was red over a perfectly healthy push. Hit twice in one session.
      #
      # Commit age is the proxy: push time is not observable from here, and a commit made moments ago is
      # the case that produces this. Outside the window the old verdict stands unchanged — a workflow
      # that genuinely never ran is exactly what this check exists for, and staying quiet about that
      # would trade a false red for a false green.
      _age=$(( now - $(git -C "$d" log -1 --format=%ct HEAD 2>/dev/null || echo 0) ))
      if [ "$_age" -lt 90 ]; then
        printf "  %-14s %-26s … no run yet (HEAD is %ss old — GitHub has not created it)\n" \
               "$repo" "(none)" "$_age"
        pending=$((pending+1))
      else
        printf "  %-14s %-26s ✘ NO RUN AT HEAD, and these were required:\n" "$repo" "(none)"
        printf "%s\n" "$required" | awk -F'\t' '{printf "      · %s — %s\n", $1, $3}'
        rc=1
      fi
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
        case "$med" in
          FAIL:*)
            # median=0 could mean "no successful history" (fine, is_stalled treats it as never-stalled) OR
            # "gh failed and we never found out" (not fine — a real stall would silently read as ordinary
            # pending, the exact shape of B3). Never guess which; name it and fail closed instead of
            # falling through to the "pending" branch below.
            printf "  %-14s %-26s ✘ gh FAILED (median lookup) — %s — cannot judge stall for this run\n" \
                   "$repo" "$wf" "${med#FAIL:}"
            rc=1; continue ;;
        esac
        if [ "$med" -eq 0 ]; then
          med=$(median_secs "$repo" "$wf")
          case "$med" in
            FAIL:*)
              printf "  %-14s %-26s ✘ gh FAILED (median lookup) — %s — cannot judge stall for this run\n" \
                     "$repo" "$wf" "${med#FAIL:}"
              rc=1; continue ;;
          esac
        fi
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

  # ── A FAILURE ON AN EARLIER COMMIT IS NOT ERASED BY A QUIET ONE ON TOP ────────────────────────────
  # Everything above asks only about HEAD. So a workflow that FAILED on commit N goes invisible the
  # moment a commit N+1 lands that its path filter ignores: HEAD legitimately needs no run, the repo
  # prints "no run expected ✔", and the red is gone from the summary while still being the newest thing
  # that workflow has to say.
  #
  # NOTICED ON A GREEN RUN, not a red one — candor's row read "no run expected" right after a push that
  # did change `bin/`, because HEAD was a CHANGELOG-only commit on top of it. That run happened to have
  # passed. Nothing would have said so if it had not.
  #
  # Only runs the newest run of each workflow is reported, and only when it is NOT at HEAD — anything at
  # HEAD was already judged above, and repeating it would put two verdicts for one run in the summary.
  if gh_call run list -R "$OWNER/$repo" --branch main --limit 40 \
             --json workflowName,status,conclusion,headSha,createdAt \
             -q '.[] | .workflowName + "\u001f" + .status + "\u001f" + (if (.conclusion // "") == "" then "-" else .conclusion end) + "\u001f" + .headSha'; then
    latest="$GH_OUT"
  else
    # Cannot tell "no earlier run exists" from "the call failed" without checking — this IS finding B3
    # (adversarial re-review, 2026-08-28): a stub gh that failed only this call still printed OK, exit 0.
    printf "  %-14s %-26s ✘ gh FAILED (run list --branch main, the earlier-commit safety net) — %s\n" \
           "$repo" "(gh)" "${GH_ERR:-no stderr captured}"
    rc=1
    latest=""
  fi
  # FAULT HOOK, same idea as `drop-row` above: this arm reports only when something upstream is broken,
  # so on a healthy repo it is indistinguishable from a check that does nothing. `stale-red` recolours
  # every completed non-HEAD run as a failure, which is exactly the state this exists to catch.
  if [ "${CI_WATCH_FAULT:-}" = "stale-red" ] && [ -n "$latest" ]; then
    latest="$(printf '%s\n' "$latest" | awk -v US="$US" -F"$US" \
              'NF>=4 {print $1 US "completed" US "failure" US $4}')"
  fi
  seen_wf=""
  while IFS="$US" read -r lwf lstatus lconcl lsha; do
    [ -z "$lwf" ] && continue
    case " $seen_wf " in *" $lwf "*) continue ;; esac   # the list is newest-first: first row wins
    seen_wf="$seen_wf $lwf"
    [ "$lsha" = "$sha" ] && continue                    # already judged against HEAD above
    [ "$lstatus" != "completed" ] && continue           # an older run still going says nothing
    [ "$lconcl" = "success" ] && continue
    printf "  %-14s %-26s ✘ %s at %s — its NEWEST run, on an earlier commit. HEAD needs no run,\n" \
           "$repo" "$lwf" "$lconcl" "$(printf '%s' "$lsha" | cut -c1-7)"
    printf "  %-14s %-26s   so this red would otherwise vanish from the summary.\n" "" ""
    rc=1
  done <<< "$latest"

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
