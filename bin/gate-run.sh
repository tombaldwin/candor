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
#   - Full output is kept per gate so a red row can be read without re-running the suite.
#
#   bash bin/gate-run.sh candor-rust [--dry-run]
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${1:-}"; dry="${2:-}"
[ -n "$repo" ] || { echo "usage: gate-run.sh <repo> [--dry-run]" >&2; exit 2; }
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
bash "$HERE/gates.sh" "$repo" 2>/dev/null | sed -n 's/^        //p' > "$GATELIST"
manual=$(bash "$HERE/gates.sh" "$repo" 2>/dev/null | grep -c '^      ~ ')

run=0; ok=0; bad=0; skip=0; i=0
while IFS= read -r cmd; do
  case "$cmd" in
    ''|'#'*|'echo '*|'got='*|'case '*|'*'*|'esac'*|'exit '*) continue ;;
    *apt-get*|*'cargo +stable install'*|*'cargo install'*|*'gh issue'*|*npm\ ci*|*'brew '*)
      skip=$((skip+1)); printf '  %-6s %s\n' "SKIP" "$cmd (provisioning)"; continue ;;
    # CI checks out siblings that already exist here. A verification tool must not clone over,
    # push to, or otherwise mutate a working tree it does not own.
    *'git clone'*|*'git push'*|*'git tag'*)
      skip=$((skip+1)); printf '  %-6s %s\n' "SKIP" "$cmd (mutates a tree this tool does not own)"; continue ;;
  esac
  i=$((i+1)); log="$LOGS/$(printf '%02d' "$i").log"
  if [ "$dry" = "--dry-run" ]; then printf '  %-6s %s\n' "WOULD" "$cmd"; run=$((run+1)); continue; fi
  ( cd "$d" && eval "$cmd" ) >"$log" 2>&1
  rc=$?
  run=$((run+1))
  if [ "$rc" -eq 0 ]; then ok=$((ok+1)); printf '  \033[32m%-6s\033[0m %s\n' "OK" "$cmd"
  else bad=$((bad+1)); printf '  \033[31m%-6s\033[0m %s  (rc=%s, %s)\n' "FAIL" "$cmd" "$rc" "$log"; fi
done < "$GATELIST"

printf '\n%s: %s gate(s) run, %s ok, %s failed, %s skipped, %s block line(s) not auto-run\n' \
  "$repo" "$run" "$ok" "$bad" "$skip" "$manual"
[ "$manual" -gt 0 ] && printf '  (see `bash bin/gates.sh %s` for the ~ lines — those belong to multi-line steps and need reading)\n' "$repo"
[ "$dry" = "--dry-run" ] && exit 0
if [ "$bad" -gt 0 ]; then echo "gate-run: NOT GREEN — see the FAIL rows above."; exit 1; fi
if [ "$skip" -gt 0 ] || [ "$manual" -gt 0 ]; then
  echo "gate-run: INCOMPLETE — $skip skipped, $manual block line(s) not auto-run. Green over an unrun gate is what this exists to stop."
  exit 2
fi
echo "gate-run: OK — every gate ran and passed."
