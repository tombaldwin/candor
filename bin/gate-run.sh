#!/usr/bin/env bash
# RUN every gate `bin/gates.sh` prints for a repo, and return ONE LINE PER GATE.
#
# `gates.sh` solved "which gates exist". This solves the reason that wasn't enough: running 21 gates
# by hand and reading pages of output is expensive, and the expensive thing is the thing that gets
# quietly narrowed to five. Measured 2026-08-30 — candor-rust shipped ten silent under-reports because
# the five-gate subset I ran happened to exclude `soundness/run.sh`.
#
# Design rules, each from a failure this file exists to prevent:
#   - SERIAL. Concurrent cargo runs on this box contend on the dylint driver and report "build failed
#     under dylint" for every seed: a false negative indistinguishable from a real one.
#   - The verdict is computed from every row and DEFAULTS TO RED, like ci-watch.sh. A summary
#     assembled by hand once said ALL GREEN over a failure.
#   - SKIPPED IS NOT PASSED. A gate that cannot run locally prints SKIP and makes the verdict
#     INCOMPLETE (exit 2), never OK. That is the same fail-closed shape the spec requires of the
#     engines, and the reason is identical: silence must not read as success.
#   - AND NEITHER IS AN EMPTY LIST. Zero gate lines is INCOMPLETE, not OK — see the guard at the
#     bottom, and the measurement in its comment.
#   - EVERY LINE IS ACCOUNTED FOR: run + skipped must equal the number of gate lines gates.sh
#     printed, checked at the end. Dropping a line silently is how a 21-gate list becomes five.
#   - Full output is kept per gate so a red row can be read without re-running the suite.
#
#   bash bin/gate-run.sh candor-rust [--dry-run]
set -uo pipefail
ROOT="${CANDOR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${1:-}"; dry="${2:-}"
[ -n "$repo" ] || { echo "usage: gate-run.sh <repo> [--dry-run]" >&2; exit 2; }
# An unrecognised second argument must not silently mean "not a dry run" and then execute 32 gates
# for real. `--dryrun` is one keystroke from `--dry-run`.
case "$dry" in
  ''|--dry-run) ;;
  *) echo "gate-run: unknown argument '$dry' — usage: gate-run.sh <repo> [--dry-run]" >&2; exit 2 ;;
esac
d="$ROOT/$repo"
[ -d "$d" ] || { echo "gate-run: no such repo: $d" >&2; exit 2; }

LOGS="$(mktemp -d)"
echo "gate-run: $repo — logs in $LOGS"

# Only lines that are runnable gates. Provisioning (apt/cargo install/actions) and shell fragments
# are NAMED as skipped rather than dropped, so the count you see is the count that exists.
# NOT `mapfile`: macOS ships bash 3.2 as /bin/bash and it has no mapfile — this script failed on the
# machine it was written on, which is the same platform-divergence class it exists to catch.
# Only whole single-line `run:` steps (8-space indent). Lines gates.sh marks with `~` were lifted out
# of a multi-line block and are script FRAGMENTS — a `case` arm or a bare assignment run standalone is
# not a gate, and executing it would manufacture failures that mean nothing. They are counted and
# reported as MANUAL so the number you see is the number that exists.
GATELIST="$LOGS/.gates"
RAW="$LOGS/.gates-raw"; ERR="$LOGS/.gates-err"
# gates.sh IS THE DETECTOR; ITS FAILURE MUST REACH THE EXIT CODE (AGENT-CORPUS-BRIEF attack H).
# This was `gates.sh "$repo" 2>/dev/null | sed …` — stderr discarded, exit status never read, and the
# result of an aborted gates.sh (a missing python3, an unknown repo name, a syntax error) is an EMPTY
# gate list that is indistinguishable from a repo with no gates. Both then reached "OK".
CANDOR_ROOT="$ROOT" bash "$HERE/gates.sh" "$repo" >"$RAW" 2>"$ERR"
grc=$?   # read DIRECTLY, not through `if !` — inside an `if ! cmd` body `$?` is the negation's status
if [ "$grc" -ne 0 ]; then
  echo "gate-run: bin/gates.sh FAILED for '$repo' (exit $grc) — the gate LIST could not be produced, so" >&2
  echo "  nothing this tool could print would be a statement about the gates. Its stderr:" >&2
  sed 's/^/    /' "$ERR" >&2
  exit 2
fi
if [ -s "$ERR" ]; then
  echo "gate-run: NOTE — bin/gates.sh exited 0 but wrote to stderr; the list below may be partial:" >&2
  sed 's/^/    /' "$ERR" >&2
fi
# ONE capture, parsed twice by COLUMN: 8 spaces = a gate line, 6 spaces + `~ ` = a block line. The two
# patterns are disjoint by construction (a `~` line's 7th column is `~`, not a space), so a line is
# never both executed and counted as manual, and the accounting check below proves it never lands in
# neither. Running gates.sh twice — as this did — was two chances for the two counts to disagree.
sed -n 's/^        //p' "$RAW" > "$GATELIST"
manual=$(grep -c '^      ~ ' "$RAW")
total=$(grep -c '^        ' "$RAW")

run=0; ok=0; bad=0; skip=0; i=0
while IFS= read -r cmd || [ -n "$cmd" ]; do
  # EVERY LINE IS ACCOUNTED FOR. The first arm below used to `continue` with no counter touched at
  # all, so a matching line was neither run, nor skipped, nor manual — it just left the totals, while
  # this file's own header claimed "the count you see is the count that exists". Silently narrowing
  # the gate set is the exact failure this tool was built to prevent.
  why=""
  case "$cmd" in
    ''|'#'*|'echo '*|'got='*|'case '*|'*'*|'esac'*|'exit '*)
      why="not a runnable gate line" ;;
    # `${{ … }}` is a GitHub expression with no local value. bash calls it a bad substitution and
    # exits 1, which reads as a FAILING GATE: candor-java's `./dist/${{ matrix.asset }} --version`
    # made that repo permanently red for a reason that is not a defect in candor-java.
    *'${{'*)
      why="carries an unexpanded GitHub \${{ }} expression — no local value exists for it" ;;
    *apt-get*|*'cargo +stable install'*|*'cargo install'*|*'gh issue'*|*npm\ ci*|*'brew '*)
      why="provisioning" ;;
    # CI checks out siblings that already exist here. A verification tool must not clone over,
    # push to, or otherwise mutate a working tree it does not own.
    *'git clone'*|*'git push'*|*'git tag'*)
      why="mutates a tree this tool does not own" ;;
  esac
  if [ -n "$why" ]; then
    skip=$((skip+1)); printf '  %-6s %s (%s)\n' "SKIP" "$cmd" "$why"; continue
  fi
  i=$((i+1)); log="$LOGS/$(printf '%02d' "$i").log"
  if [ "$dry" = "--dry-run" ]; then printf '  %-6s %s\n' "WOULD" "$cmd"; run=$((run+1)); continue; fi
  # `</dev/null`: without it the gate inherits THIS LOOP'S stdin, which is the gate list. One gate
  # that reads stdin swallows every gate below it, and the run ends reporting only the gates that
  # survived — a silent narrowing that looks exactly like a short list. The accounting check below
  # catches it if it ever happens anyway.
  ( cd "$d" && eval "$cmd" ) >"$log" 2>&1 </dev/null
  rc=$?
  run=$((run+1))
  if [ "$rc" -eq 0 ]; then ok=$((ok+1)); printf '  \033[32m%-6s\033[0m %s\n' "OK" "$cmd"
  else bad=$((bad+1)); printf '  \033[31m%-6s\033[0m %s  (rc=%s, %s)\n' "FAIL" "$cmd" "$rc" "$log"; fi
done < "$GATELIST"

printf '\n%s: %s gate(s) run, %s ok, %s failed, %s skipped, %s block line(s) not auto-run\n' \
  "$repo" "$run" "$ok" "$bad" "$skip" "$manual"
[ "$manual" -gt 0 ] && printf '  (see `bash bin/gates.sh %s` for the ~ lines — those belong to multi-line steps and need reading)\n' "$repo"

# THE ACCOUNTING CHECK. Every gate line gates.sh printed must have been either run or named as
# skipped. If the two numbers disagree, some gate went missing between the list and the loop and the
# verdict below is about a set nobody chose — so refuse to give one.
if [ "$((run + skip))" -ne "$total" ]; then
  printf 'gate-run: ACCOUNTING BROKEN — gates.sh printed %s gate line(s), but %s were run and %s skipped.\n' \
    "$total" "$run" "$skip" >&2
  printf '  A gate that is neither run nor named is a silent gap in coverage. No verdict.\n' >&2
  exit 2
fi
# A gate list of ZERO is not a pass. `gate-run.sh candor-old` printed "OK — every gate ran and
# passed" and exited 0 over a repo gates.sh had never heard of; so did any repo whose workflows
# directory is missing. Measured 2026-08-30, in the file whose header says green over an unrun gate
# is the thing it exists to stop.
if [ "$total" -eq 0 ] && [ "$manual" -eq 0 ]; then
  echo "gate-run: INCOMPLETE — gates.sh printed NOTHING for '$repo': no gate lines and no block lines." >&2
  echo "  That is not a green repo, it is a repo whose gate list could not be read. Check" >&2
  echo "  \`bash bin/gates.sh $repo\` by hand." >&2
  exit 2
fi
[ "$dry" = "--dry-run" ] && exit 0
if [ "$bad" -gt 0 ]; then echo "gate-run: NOT GREEN — see the FAIL rows above."; exit 1; fi
if [ "$skip" -gt 0 ] || [ "$manual" -gt 0 ]; then
  echo "gate-run: INCOMPLETE — $skip skipped, $manual block line(s) not auto-run. Green over an unrun gate is what this exists to stop."
  exit 2
fi
echo "gate-run: OK — every gate ran and passed."
